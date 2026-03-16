const std = @import("std");
const builtin = @import("builtin");
const binary_reader = @import("binary_reader");
const quantize = @import("quantize");
const delta = @import("delta");
const bitpack = @import("bitpack");

pub const Allocator = std.mem.Allocator;

pub const Mode = enum {
    lossless,
    lossy,
};

pub const EncodeOptions = struct {
    mode: Mode = .lossless,
    mz_scale_factor: u32 = 500_000,
    intensity_quant: u16 = 4096,
};

pub const BlockHeader = struct {
    spectrum_count: u16,
    ms_level: u8,
    flags: u8,
    total_peaks: u32,
    mz_scale_factor: u32,
    intensity_quant: u16,
    reserved0: u16,
    mz_bit_width: u8,
    intensity_bit_width: u8,
    reserved1: u16,
    rt_min: f32,
    rt_max: f32,
    payload_bytes: u32,
    decompressed_bytes: u32,
    checksum: u32,
};

pub const flag_lossless_intensity_raw: u8 = 0b0000_0001;
pub const header_len = 40;

fn combineU32(low: u16, high: u16) u32 {
    return @as(u32, low) | (@as(u32, high) << 16);
}

fn encodeIntensityLogScale(value: f32) struct { low: u16, high: u16 } {
    const bits = @as(u32, @bitCast(value));
    return .{
        .low = @intCast(bits & 0xffff),
        .high = @intCast((bits >> 16) & 0xffff),
    };
}

fn decodeIntensityLogScale(header: BlockHeader) f32 {
    return @as(f32, @bitCast(combineU32(header.reserved0, header.reserved1)));
}

fn appendIntLe(list: *std.ArrayList(u8), allocator: Allocator, comptime T: type, value: T) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try list.appendSlice(allocator, &buffer);
}

fn appendF32Le(list: *std.ArrayList(u8), allocator: Allocator, value: f32) !void {
    try appendIntLe(list, allocator, u32, @as(u32, @bitCast(value)));
}

fn appendF64Le(list: *std.ArrayList(u8), allocator: Allocator, value: f64) !void {
    try appendIntLe(list, allocator, u64, @as(u64, @bitCast(value)));
}

fn readIntLe(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn readF32Le(bytes: []const u8) f32 {
    return @bitCast(readIntLe(u32, bytes));
}

fn readF64Le(bytes: []const u8) f64 {
    return @bitCast(readIntLe(u64, bytes));
}

pub fn parseHeader(bytes: []const u8) !BlockHeader {
    if (bytes.len < header_len) return error.UnexpectedEndOfStream;

    return .{
        .spectrum_count = readIntLe(u16, bytes[0..2]),
        .ms_level = bytes[2],
        .flags = bytes[3],
        .total_peaks = readIntLe(u32, bytes[4..8]),
        .mz_scale_factor = readIntLe(u32, bytes[8..12]),
        .intensity_quant = readIntLe(u16, bytes[12..14]),
        .reserved0 = readIntLe(u16, bytes[14..16]),
        .mz_bit_width = bytes[16],
        .intensity_bit_width = bytes[17],
        .reserved1 = readIntLe(u16, bytes[18..20]),
        .rt_min = readF32Le(bytes[20..24]),
        .rt_max = readF32Le(bytes[24..28]),
        .payload_bytes = readIntLe(u32, bytes[28..32]),
        .decompressed_bytes = readIntLe(u32, bytes[32..36]),
        .checksum = readIntLe(u32, bytes[36..40]),
    };
}

fn writeHeader(list: *std.ArrayList(u8), allocator: Allocator, header: BlockHeader) !void {
    try appendIntLe(list, allocator, u16, header.spectrum_count);
    try list.append(allocator, header.ms_level);
    try list.append(allocator, header.flags);
    try appendIntLe(list, allocator, u32, header.total_peaks);
    try appendIntLe(list, allocator, u32, header.mz_scale_factor);
    try appendIntLe(list, allocator, u16, header.intensity_quant);
    try appendIntLe(list, allocator, u16, header.reserved0);
    try list.append(allocator, header.mz_bit_width);
    try list.append(allocator, header.intensity_bit_width);
    try appendIntLe(list, allocator, u16, header.reserved1);
    try appendF32Le(list, allocator, header.rt_min);
    try appendF32Le(list, allocator, header.rt_max);
    try appendIntLe(list, allocator, u32, header.payload_bytes);
    try appendIntLe(list, allocator, u32, header.decompressed_bytes);
    try appendIntLe(list, allocator, u32, header.checksum);
}

fn totalPeakCount(spectra: []const binary_reader.RawSpectrum) !usize {
    var total: usize = 0;
    for (spectra) |spectrum| {
        if (spectrum.mz.len != spectrum.intensity.len) return error.MismatchedPeakArrays;
        total += spectrum.mz.len;
    }
    return total;
}

fn flattenMzDeltas(allocator: Allocator, spectra: []const binary_reader.RawSpectrum, scale_factor: u32) ![]u64 {
    const total_peaks = try totalPeakCount(spectra);
    const flat = try allocator.alloc(u64, total_peaks);
    errdefer allocator.free(flat);

    var offset: usize = 0;
    for (spectra) |spectrum| {
        var previous: u64 = 0;
        for (spectrum.mz, 0..) |value, idx| {
            const quantized = try quantize.quantizeMzValue(value, scale_factor);
            if (idx != 0 and quantized < previous) return error.NonMonotonicInput;
            flat[offset] = if (idx == 0) quantized else quantized - previous;
            previous = quantized;
            offset += 1;
        }
    }

    return flat;
}

fn flattenIntensityLossyToU64(
    allocator: Allocator,
    spectra: []const binary_reader.RawSpectrum,
    quant_factor: u16,
    log_max: f32,
) ![]u64 {
    const total_peaks = try totalPeakCount(spectra);
    const flat = try allocator.alloc(u64, total_peaks);
    errdefer allocator.free(flat);

    var offset: usize = 0;
    for (spectra) |spectrum| {
        for (spectrum.intensity) |value| {
            flat[offset] = try quantize.quantizeIntensityValueScaled(value, quant_factor, log_max);
            offset += 1;
        }
    }

    return flat;
}

pub fn encodeBlock(allocator: Allocator, spectra: []const binary_reader.RawSpectrum, options: EncodeOptions) ![]u8 {
    if (spectra.len == 0) return error.EmptyBlock;
    if (spectra.len > std.math.maxInt(u16)) return error.TooManySpectra;

    const ms_level = spectra[0].ms_level;
    var rt_min = spectra[0].rt_seconds;
    var rt_max = spectra[0].rt_seconds;
    for (spectra) |spectrum| {
        if (spectrum.ms_level != ms_level) return error.MixedMsLevel;
        if (spectrum.rt_seconds < rt_min) rt_min = spectrum.rt_seconds;
        if (spectrum.rt_seconds > rt_max) rt_max = spectrum.rt_seconds;
    }

    const total_peaks = try totalPeakCount(spectra);
    if (total_peaks > std.math.maxInt(u32)) return error.TooManyPeaks;

    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(allocator);

    var intensity_log_scale = @as(f32, 0.0);
    if (options.mode == .lossy) {
        for (spectra) |spectrum| {
            const candidate = quantize.intensityLogMax(spectrum.intensity);
            if (candidate > intensity_log_scale) intensity_log_scale = candidate;
        }
    }

    for (spectra) |spectrum| try appendIntLe(&payload, allocator, u32, spectrum.scan_id);
    for (spectra) |spectrum| try appendF32Le(&payload, allocator, spectrum.rt_seconds);
    for (spectra) |spectrum| try appendF64Le(&payload, allocator, spectrum.precursor_mz);
    for (spectra) |spectrum| try appendIntLe(&payload, allocator, u32, @intCast(spectrum.mz.len));

    const mz_deltas = try flattenMzDeltas(allocator, spectra, options.mz_scale_factor);
    defer allocator.free(mz_deltas);
    const packed_mz = try bitpack.packForU64(allocator, mz_deltas);
    defer packed_mz.deinit(allocator);

    try appendIntLe(&payload, allocator, u64, packed_mz.base);
    try appendIntLe(&payload, allocator, u32, @intCast(packed_mz.payload.len));
    try payload.appendSlice(allocator, packed_mz.payload);

    var flags: u8 = 0;
    var intensity_bit_width: u8 = 0;
    if (options.mode == .lossless) {
        flags |= flag_lossless_intensity_raw;
        for (spectra) |spectrum| {
            if (builtin.cpu.arch.endian() == .little) {
                try payload.appendSlice(allocator, std.mem.sliceAsBytes(spectrum.intensity));
            } else {
                for (spectrum.intensity) |value| {
                    try appendF32Le(&payload, allocator, value);
                }
            }
        }
    } else {
        const quantized_intensity = try flattenIntensityLossyToU64(
            allocator,
            spectra,
            options.intensity_quant,
            intensity_log_scale,
        );
        defer allocator.free(quantized_intensity);

        const packed_intensity = try bitpack.packForU64(allocator, quantized_intensity);
        defer packed_intensity.deinit(allocator);

        if (packed_intensity.base > std.math.maxInt(u16)) return error.IntensityOverflow;

        intensity_bit_width = packed_intensity.bit_width;
        try appendIntLe(&payload, allocator, u16, @intCast(packed_intensity.base));
        try appendIntLe(&payload, allocator, u32, @intCast(packed_intensity.payload.len));
        try payload.appendSlice(allocator, packed_intensity.payload);
    }

    const decompressed_bytes = (@as(usize, spectra.len) * (@sizeOf(u32) + @sizeOf(f32) + @sizeOf(f64) + @sizeOf(u32))) +
        (total_peaks * (@sizeOf(f64) + @sizeOf(f32)));
    if (payload.items.len > std.math.maxInt(u32) or decompressed_bytes > std.math.maxInt(u32)) return error.BlockTooLarge;

    const intensity_scale_bits = encodeIntensityLogScale(intensity_log_scale);

    const header: BlockHeader = .{
        .spectrum_count = @intCast(spectra.len),
        .ms_level = ms_level,
        .flags = flags,
        .total_peaks = @intCast(total_peaks),
        .mz_scale_factor = options.mz_scale_factor,
        .intensity_quant = options.intensity_quant,
        .reserved0 = intensity_scale_bits.low,
        .mz_bit_width = packed_mz.bit_width,
        .intensity_bit_width = intensity_bit_width,
        .reserved1 = intensity_scale_bits.high,
        .rt_min = rt_min,
        .rt_max = rt_max,
        .payload_bytes = @intCast(payload.items.len),
        .decompressed_bytes = @intCast(decompressed_bytes),
        .checksum = std.hash.crc.Crc32.hash(payload.items),
    };

    var block: std.ArrayList(u8) = .empty;
    errdefer block.deinit(allocator);
    try writeHeader(&block, allocator, header);
    try block.appendSlice(allocator, payload.items);
    payload.deinit(allocator);

    return block.toOwnedSlice(allocator);
}

pub fn decodeBlock(allocator: Allocator, block_bytes: []const u8) ![]binary_reader.RawSpectrum {
    const header = try parseHeader(block_bytes);
    if (block_bytes.len < header_len + header.payload_bytes) return error.UnexpectedEndOfStream;

    const payload = block_bytes[header_len .. header_len + header.payload_bytes];
    if (std.hash.crc.Crc32.hash(payload) != header.checksum) return error.ChecksumMismatch;

    const spectrum_count = header.spectrum_count;
    const total_peaks = header.total_peaks;
    var offset: usize = 0;

    const scan_ids = try allocator.alloc(u32, spectrum_count);
    defer allocator.free(scan_ids);
    for (scan_ids) |*value| {
        if (payload.len - offset < 4) return error.UnexpectedEndOfStream;
        value.* = readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
    }

    const rt_values = try allocator.alloc(f32, spectrum_count);
    defer allocator.free(rt_values);
    for (rt_values) |*value| {
        if (payload.len - offset < 4) return error.UnexpectedEndOfStream;
        value.* = readF32Le(payload[offset .. offset + 4]);
        offset += 4;
    }

    const precursor_values = try allocator.alloc(f64, spectrum_count);
    defer allocator.free(precursor_values);
    for (precursor_values) |*value| {
        if (payload.len - offset < 8) return error.UnexpectedEndOfStream;
        value.* = readF64Le(payload[offset .. offset + 8]);
        offset += 8;
    }

    const peak_counts = try allocator.alloc(u32, spectrum_count);
    defer allocator.free(peak_counts);
    var computed_total_peaks: usize = 0;
    for (peak_counts) |*value| {
        if (payload.len - offset < 4) return error.UnexpectedEndOfStream;
        value.* = readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        computed_total_peaks += value.*;
    }
    if (computed_total_peaks != total_peaks) return error.InvalidPeakCount;

    if (payload.len - offset < 12) return error.UnexpectedEndOfStream;
    const mz_base = readIntLe(u64, payload[offset .. offset + 8]);
    offset += 8;
    const mz_payload_len = readIntLe(u32, payload[offset .. offset + 4]);
    offset += 4;
    if (payload.len - offset < mz_payload_len) return error.UnexpectedEndOfStream;

    const mz_offsets = try bitpack.unpackForU64(allocator, .{
        .base = mz_base,
        .bit_width = header.mz_bit_width,
        .count = total_peaks,
        .payload = payload[offset .. offset + mz_payload_len],
    });
    defer allocator.free(mz_offsets);
    offset += mz_payload_len;

    const flat_mz = try allocator.alloc(f64, total_peaks);
    defer allocator.free(flat_mz);

    var mz_cursor: usize = 0;
    for (peak_counts) |peak_count| {
        var previous: u64 = 0;
        for (0..peak_count) |local_idx| {
            const delta_value = mz_offsets[mz_cursor + local_idx];
            const absolute = if (local_idx == 0) delta_value else blk: {
                const sum = @addWithOverflow(previous, delta_value);
                if (sum[1] != 0) return error.Overflow;
                break :blk sum[0];
            };
            flat_mz[mz_cursor + local_idx] = try quantize.dequantizeMzValue(absolute, header.mz_scale_factor);
            previous = absolute;
        }
        mz_cursor += peak_count;
    }

    const flat_intensity = try allocator.alloc(f32, total_peaks);
    defer allocator.free(flat_intensity);

    if ((header.flags & flag_lossless_intensity_raw) != 0) {
        const raw_len = total_peaks * @sizeOf(f32);
        if (payload.len - offset < raw_len) return error.UnexpectedEndOfStream;
        if (builtin.cpu.arch.endian() == .little) {
            @memcpy(std.mem.sliceAsBytes(flat_intensity), payload[offset .. offset + raw_len]);
        } else {
            for (flat_intensity, 0..) |*value, idx| {
                const start = offset + (idx * @sizeOf(f32));
                value.* = readF32Le(payload[start .. start + @sizeOf(f32)]);
            }
        }
        offset += raw_len;
    } else {
        if (payload.len - offset < 6) return error.UnexpectedEndOfStream;
        const intensity_base = readIntLe(u16, payload[offset .. offset + 2]);
        offset += 2;
        const intensity_payload_len = readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        if (payload.len - offset < intensity_payload_len) return error.UnexpectedEndOfStream;

        const unpacked = try bitpack.unpackForU64(allocator, .{
            .base = intensity_base,
            .bit_width = header.intensity_bit_width,
            .count = total_peaks,
            .payload = payload[offset .. offset + intensity_payload_len],
        });
        defer allocator.free(unpacked);
        offset += intensity_payload_len;

        const intensity_log_scale = decodeIntensityLogScale(header);

        for (unpacked, 0..) |value, idx| {
            if (value > std.math.maxInt(u16)) return error.IntensityOverflow;
            flat_intensity[idx] = try quantize.dequantizeIntensityValueScaled(@intCast(value), header.intensity_quant, intensity_log_scale);
        }
    }

    if (offset != payload.len) return error.TrailingBlockPayload;

    const spectra = try allocator.alloc(binary_reader.RawSpectrum, spectrum_count);
    errdefer {
        for (spectra[0..]) |spectrum| {
            allocator.free(spectrum.mz);
            allocator.free(spectrum.intensity);
        }
        allocator.free(spectra);
    }

    var flat_offset: usize = 0;
    for (spectra, 0..) |*spectrum, idx| {
        const peak_count = peak_counts[idx];
        const mz = try allocator.alloc(f64, peak_count);
        errdefer allocator.free(mz);
        const intensity = try allocator.alloc(f32, peak_count);
        errdefer allocator.free(intensity);

        @memcpy(mz, flat_mz[flat_offset .. flat_offset + peak_count]);
        @memcpy(intensity, flat_intensity[flat_offset .. flat_offset + peak_count]);
        flat_offset += peak_count;

        spectrum.* = .{
            .scan_id = scan_ids[idx],
            .rt_seconds = rt_values[idx],
            .ms_level = header.ms_level,
            .precursor_mz = precursor_values[idx],
            .mz = mz,
            .intensity = intensity,
        };
    }

    return spectra;
}
