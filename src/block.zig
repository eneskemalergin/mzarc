const std = @import("std");
const builtin = @import("builtin");
const binary_reader = @import("binary_reader");
const quantize = @import("quantize");
const bitpack = @import("bitpack");

pub const Allocator = std.mem.Allocator;

pub const Mode = enum {
    lossless,
    lossy,
};

pub const EncodeOptions = struct {
    mode: Mode = .lossless,
    /// Fixed-point scale used in lossy mode for m/z quantization.
    mz_scale_factor: u32 = 500_000,
    /// Fixed-point scale used in lossless mode.  High enough that round-trip
    /// error is < 0.001 ppm across the full MS mass range.
    lossless_mz_scale_factor: u32 = 1_000_000_000,
    intensity_quant: u16 = 16384,
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

pub const BlockByteBreakdown = struct {
    header_bytes: usize,
    scan_id_bytes: usize,
    rt_bytes: usize,
    precursor_bytes: usize,
    peak_count_bytes: usize,
    mz_metadata_bytes: usize,
    mz_payload_bytes: usize,
    intensity_metadata_bytes: usize,
    intensity_payload_bytes: usize,
    total_bytes: usize,
};

pub const flag_lossless_intensity_raw: u8 = 0b0000_0001;
/// Lossless intensity stored as split exponent + raw mantissa.
/// The f32 exponent byte (bits 23..30) is FOR-packed; bytes 0..2 are stored raw.
/// Mutually exclusive with flag_lossless_intensity_raw.
/// Bit 2 (0b0000_0100) is used; bits 1, 6, 7 remain free.
pub const flag_split_exponent: u8 = 0b0000_0100;
/// m/z stored as f32 bit patterns, delta-encoded as u32.  Guarantees bit-exact
/// round-trips for values that are already f32-precision (every real instrument
/// produces f32 natively; mzML just widens to f64).
pub const flag_lossless_mz_f32: u8 = 0b0000_1000;
/// scan_id array is delta-encoded (base + packed deltas) rather than stored raw.
pub const flag_delta_scan_id: u8 = 0b0001_0000;
/// rt_seconds array is stored as delta-encoded f32 bit patterns (positive,
/// monotonically increasing) rather than raw f32 values.
pub const flag_delta_rt: u8 = 0b0010_0000;
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

/// Returns true when every m/z value in `spectra` is exactly representable as
/// an IEEE-754 single-precision float.  Instruments produce f32 natively;
/// mzML widens to f64 with trailing zero mantissa bits, so this is true for
/// the vast majority of real data.
fn allMzExactlyF32(spectra: []const binary_reader.RawSpectrum) bool {
    for (spectra) |spectrum| {
        for (spectrum.mz) |value| {
            if (@as(f64, @as(f32, @floatCast(value))) != value) return false;
        }
    }
    return true;
}

/// Flatten m/z arrays from all spectra into a single packed delta array using
/// f32 bit-cast encoding.  Each value is cast to f32, reinterpreted as u32,
/// then delta-encoded within its spectrum (previous resets to 0 at each new
/// spectrum).  Caller must verify `allMzExactlyF32` first.
fn flattenMzAsF32Bits(allocator: Allocator, spectra: []const binary_reader.RawSpectrum) ![]u64 {
    const total_peaks = try totalPeakCount(spectra);
    const flat = try allocator.alloc(u64, total_peaks);
    errdefer allocator.free(flat);

    var offset: usize = 0;
    for (spectra) |spectrum| {
        var previous: u32 = 0;
        for (spectrum.mz, 0..) |value, idx| {
            const as_f32: f32 = @floatCast(value);
            const bits: u32 = @bitCast(as_f32);
            if (idx != 0 and bits < previous) return error.NonMonotonicInput;
            flat[offset] = if (idx == 0) bits else bits - previous;
            previous = bits;
            offset += 1;
        }
    }

    return flat;
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

/// Build a delta array for scan IDs: first element is `spectra[0].scan_id`,
/// subsequent elements are the positive differences.  Scan IDs from real
/// instruments always increase by 1-2 per scan, so deltas fit in 1-2 bits.
fn buildScanIdDeltas(allocator: Allocator, spectra: []const binary_reader.RawSpectrum) ![]u64 {
    const result = try allocator.alloc(u64, spectra.len);
    errdefer allocator.free(result);
    result[0] = spectra[0].scan_id;
    for (spectra[1..], 1..) |spectrum, idx| {
        if (spectrum.scan_id < spectra[idx - 1].scan_id) return error.NonMonotonicScanIds;
        result[idx] = spectrum.scan_id - spectra[idx - 1].scan_id;
    }
    return result;
}

/// Build a delta array for RT values encoded as f32 bit-patterns.  Positive
/// IEEE-754 floats have the property that their u32 bit representations are
/// monotonically ordered, so integer delta-encoding and FOR bit-packing works
/// directly without any loss of precision.
fn buildRtDeltas(allocator: Allocator, spectra: []const binary_reader.RawSpectrum) ![]u64 {
    const result = try allocator.alloc(u64, spectra.len);
    errdefer allocator.free(result);
    result[0] = @as(u32, @bitCast(spectra[0].rt_seconds));
    for (spectra[1..], 1..) |spectrum, idx| {
        const cur_bits: u32 = @bitCast(spectrum.rt_seconds);
        const prev_bits: u32 = @bitCast(spectra[idx - 1].rt_seconds);
        if (cur_bits < prev_bits) return error.NonMonotonicRt;
        result[idx] = cur_bits - prev_bits;
    }
    return result;
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

    var flags: u8 = 0;

    // scan_id: delta-encode with bitpack if monotonically non-decreasing.
    {
        const scan_id_deltas = buildScanIdDeltas(allocator, spectra) catch |err| blk: {
            if (err == error.NonMonotonicScanIds) {
                // Fall back to raw encoding
                break :blk null;
            }
            return err;
        };
        if (scan_id_deltas) |deltas| {
            defer allocator.free(deltas);
            flags |= flag_delta_scan_id;
            const pack_result = try bitpack.packForU64(allocator, deltas);
            defer pack_result.deinit(allocator);
            try payload.append(allocator, pack_result.bit_width);
            try appendIntLe(&payload, allocator, u64, pack_result.base);
            try appendIntLe(&payload, allocator, u32, @intCast(pack_result.payload.len));
            try payload.appendSlice(allocator, pack_result.payload);
        } else {
            for (spectra) |spectrum| try appendIntLe(&payload, allocator, u32, spectrum.scan_id);
        }
    }

    // rt_seconds: delta-encode f32 bit patterns when RT is non-decreasing.
    {
        const rt_deltas = buildRtDeltas(allocator, spectra) catch |err| blk: {
            if (err == error.NonMonotonicRt) {
                break :blk null;
            }
            return err;
        };
        if (rt_deltas) |deltas| {
            defer allocator.free(deltas);
            flags |= flag_delta_rt;
            const pack_result = try bitpack.packForU64(allocator, deltas);
            defer pack_result.deinit(allocator);
            try payload.append(allocator, pack_result.bit_width);
            try appendIntLe(&payload, allocator, u64, pack_result.base);
            try appendIntLe(&payload, allocator, u32, @intCast(pack_result.payload.len));
            try payload.appendSlice(allocator, pack_result.payload);
        } else {
            for (spectra) |spectrum| try appendF32Le(&payload, allocator, spectrum.rt_seconds);
        }
    }

    for (spectra) |spectrum| try appendF64Le(&payload, allocator, spectrum.precursor_mz);
    for (spectra) |spectrum| try appendIntLe(&payload, allocator, u32, @intCast(spectrum.mz.len));
    var mz_bit_width: u8 = 0;
    var mz_scale_for_header: u32 = options.mz_scale_factor;
    {
        // Choose the m/z encoding strategy:
        //   lossless + all values are f32-exact → f32 bit-cast delta (bit-exact round-trip)
        //   lossless + non-f32 data             → high-scale fixed-point delta (< 0.001 ppm)
        //   lossy                               → lower fixed-point scale set by caller
        const mz_deltas = blk: {
            if (options.mode == .lossless and allMzExactlyF32(spectra)) {
                flags |= flag_lossless_mz_f32;
                mz_scale_for_header = 0; // not used; signal that f32 path was taken
                break :blk try flattenMzAsF32Bits(allocator, spectra);
            } else {
                const scale = if (options.mode == .lossless) options.lossless_mz_scale_factor else options.mz_scale_factor;
                mz_scale_for_header = scale;
                break :blk try flattenMzDeltas(allocator, spectra, scale);
            }
        };
        defer allocator.free(mz_deltas);
        const packed_mz = try bitpack.packForU64(allocator, mz_deltas);
        defer packed_mz.deinit(allocator);
        mz_bit_width = packed_mz.bit_width;
        try appendIntLe(&payload, allocator, u64, packed_mz.base);
        try appendIntLe(&payload, allocator, u32, @intCast(packed_mz.payload.len));
        try payload.appendSlice(allocator, packed_mz.payload);
    }

    var intensity_bit_width: u8 = 0;
    if (options.mode == .lossless) {
        // Dry-run: compare split-exponent layout vs raw f32 and use whichever is smaller.
        // Split layout: [bw:1][base:8][payload_len:4][exp_payload][mantissa: 3*total_peaks]
        const exp_values = try allocator.alloc(u64, total_peaks);
        defer allocator.free(exp_values);
        {
            var i: usize = 0;
            for (spectra) |spectrum| {
                for (spectrum.intensity) |value| {
                    exp_values[i] = (@as(u32, @bitCast(value)) >> 24) & 0xFF;
                    i += 1;
                }
            }
        }
        const packed_exp = try bitpack.packForU64(allocator, exp_values);
        defer packed_exp.deinit(allocator);
        const split_bytes: usize = 1 + 8 + 4 + packed_exp.payload.len + 3 * total_peaks;
        const raw_bytes: usize = 4 * total_peaks;
        if (split_bytes < raw_bytes) {
            // Split-exponent wins: FOR-pack the exponent stream, store mantissa raw.
            flags |= flag_split_exponent;
            intensity_bit_width = packed_exp.bit_width;
            try payload.append(allocator, packed_exp.bit_width);
            try appendIntLe(&payload, allocator, u64, packed_exp.base);
            try appendIntLe(&payload, allocator, u32, @intCast(packed_exp.payload.len));
            try payload.appendSlice(allocator, packed_exp.payload);
            for (spectra) |spectrum| {
                for (spectrum.intensity) |value| {
                    const bits: u32 = @bitCast(value);
                    try payload.append(allocator, @truncate(bits & 0xFF));
                    try payload.append(allocator, @truncate((bits >> 8) & 0xFF));
                    try payload.append(allocator, @truncate((bits >> 16) & 0xFF));
                }
            }
        } else {
            // Fall back to raw f32 (compat path, v0.1.1 behaviour).
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
        .mz_scale_factor = mz_scale_for_header,
        .intensity_quant = options.intensity_quant,
        .reserved0 = intensity_scale_bits.low,
        .mz_bit_width = mz_bit_width,
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
    if ((header.flags & flag_delta_scan_id) != 0) {
        if (payload.len - offset < 13) return error.UnexpectedEndOfStream;
        const bit_width = payload[offset];
        offset += 1;
        const base = readIntLe(u64, payload[offset .. offset + 8]);
        offset += 8;
        const pack_len = readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        if (payload.len - offset < pack_len) return error.UnexpectedEndOfStream;
        const unpacked = try bitpack.unpackForU64(allocator, .{
            .base = base,
            .bit_width = bit_width,
            .count = spectrum_count,
            .payload = payload[offset .. offset + pack_len],
        });
        defer allocator.free(unpacked);
        offset += pack_len;
        var running: u32 = 0;
        for (scan_ids, 0..) |*value, idx| {
            running +%= @truncate(unpacked[idx]);
            value.* = running;
        }
    } else {
        for (scan_ids) |*value| {
            if (payload.len - offset < 4) return error.UnexpectedEndOfStream;
            value.* = readIntLe(u32, payload[offset .. offset + 4]);
            offset += 4;
        }
    }

    const rt_values = try allocator.alloc(f32, spectrum_count);
    defer allocator.free(rt_values);
    if ((header.flags & flag_delta_rt) != 0) {
        if (payload.len - offset < 13) return error.UnexpectedEndOfStream;
        const bit_width = payload[offset];
        offset += 1;
        const base = readIntLe(u64, payload[offset .. offset + 8]);
        offset += 8;
        const pack_len = readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        if (payload.len - offset < pack_len) return error.UnexpectedEndOfStream;
        const unpacked = try bitpack.unpackForU64(allocator, .{
            .base = base,
            .bit_width = bit_width,
            .count = spectrum_count,
            .payload = payload[offset .. offset + pack_len],
        });
        defer allocator.free(unpacked);
        offset += pack_len;
        var running_bits: u32 = 0;
        for (rt_values, 0..) |*value, idx| {
            running_bits +%= @truncate(unpacked[idx]);
            value.* = @bitCast(running_bits);
        }
    } else {
        for (rt_values) |*value| {
            if (payload.len - offset < 4) return error.UnexpectedEndOfStream;
            value.* = readF32Le(payload[offset .. offset + 4]);
            offset += 4;
        }
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

    const flat_mz = try allocator.alloc(f64, total_peaks);
    defer allocator.free(flat_mz);

    const mz_uses_f32 = (header.flags & flag_lossless_mz_f32) != 0;
    {
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
                flat_mz[mz_cursor + local_idx] = if (mz_uses_f32)
                    @as(f64, @as(f32, @bitCast(@as(u32, @truncate(absolute)))))
                else
                    try quantize.dequantizeMzValue(absolute, header.mz_scale_factor);
                previous = absolute;
            }
            mz_cursor += peak_count;
        }
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
    } else if ((header.flags & flag_split_exponent) != 0) {
        // Split-exponent decode: reconstruct f32 from FOR-packed exponent + raw 3-byte mantissa.
        if (payload.len - offset < 13) return error.UnexpectedEndOfStream;
        const exp_bit_width = payload[offset];
        offset += 1;
        const exp_base = readIntLe(u64, payload[offset .. offset + 8]);
        offset += 8;
        const exp_payload_len = readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        if (payload.len - offset < exp_payload_len) return error.UnexpectedEndOfStream;
        const exp_unpacked = try bitpack.unpackForU64(allocator, .{
            .base = exp_base,
            .bit_width = exp_bit_width,
            .count = total_peaks,
            .payload = payload[offset .. offset + exp_payload_len],
        });
        defer allocator.free(exp_unpacked);
        offset += exp_payload_len;
        const mantissa_len = total_peaks * 3;
        if (payload.len - offset < mantissa_len) return error.UnexpectedEndOfStream;
        for (flat_intensity, 0..) |*value, idx| {
            const b0 = payload[offset + idx * 3];
            const b1 = payload[offset + idx * 3 + 1];
            const b2 = payload[offset + idx * 3 + 2];
            const exp_byte: u8 = @truncate(exp_unpacked[idx]);
            const bits: u32 = (@as(u32, exp_byte) << 24) |
                (@as(u32, b2) << 16) | (@as(u32, b1) << 8) | b0;
            value.* = @bitCast(bits);
        }
        offset += mantissa_len;
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
    var initialized: usize = 0;
    errdefer {
        for (spectra[0..initialized]) |spectrum| {
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
        initialized += 1;
    }

    return spectra;
}

pub fn inspectBlockByteBreakdown(block_bytes: []const u8) !BlockByteBreakdown {
    const header = try parseHeader(block_bytes);
    if (block_bytes.len < header_len + header.payload_bytes) return error.UnexpectedEndOfStream;

    const payload = block_bytes[header_len .. header_len + header.payload_bytes];
    const spectrum_count = @as(usize, header.spectrum_count);
    const total_peaks = @as(usize, header.total_peaks);

    var offset: usize = 0;

    // scan_id section
    var scan_id_bytes: usize = 0;
    if ((header.flags & flag_delta_scan_id) != 0) {
        if (payload.len - offset < 13) return error.UnexpectedEndOfStream;
        offset += 1; // bit_width byte
        offset += 8; // base u64
        const pack_len = readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        if (payload.len - offset < pack_len) return error.UnexpectedEndOfStream;
        offset += pack_len;
        scan_id_bytes = 1 + 8 + 4 + pack_len;
    } else {
        scan_id_bytes = spectrum_count * @sizeOf(u32);
        if (payload.len - offset < scan_id_bytes) return error.UnexpectedEndOfStream;
        offset += scan_id_bytes;
    }

    // rt section
    var rt_bytes: usize = 0;
    if ((header.flags & flag_delta_rt) != 0) {
        if (payload.len - offset < 13) return error.UnexpectedEndOfStream;
        offset += 1; // bit_width byte
        offset += 8; // base u64
        const pack_len = readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        if (payload.len - offset < pack_len) return error.UnexpectedEndOfStream;
        offset += pack_len;
        rt_bytes = 1 + 8 + 4 + pack_len;
    } else {
        rt_bytes = spectrum_count * @sizeOf(f32);
        if (payload.len - offset < rt_bytes) return error.UnexpectedEndOfStream;
        offset += rt_bytes;
    }

    // precursor and peak_count sections (always fixed-width)
    const precursor_bytes = spectrum_count * @sizeOf(f64);
    const peak_count_bytes = spectrum_count * @sizeOf(u32);
    if (payload.len - offset < precursor_bytes + peak_count_bytes) return error.UnexpectedEndOfStream;

    var computed_total_peaks: usize = 0;
    for (0..spectrum_count) |idx| {
        const start = offset + precursor_bytes + (idx * @sizeOf(u32));
        const peak_count = readIntLe(u32, payload[start .. start + @sizeOf(u32)]);
        computed_total_peaks += peak_count;
    }
    if (computed_total_peaks != total_peaks) return error.InvalidPeakCount;
    offset += precursor_bytes + peak_count_bytes;

    const mz_metadata_bytes = @sizeOf(u64) + @sizeOf(u32);
    if (payload.len - offset < mz_metadata_bytes) return error.UnexpectedEndOfStream;
    _ = readIntLe(u64, payload[offset .. offset + @sizeOf(u64)]);
    offset += @sizeOf(u64);
    const mz_packed_payload_bytes = readIntLe(u32, payload[offset .. offset + @sizeOf(u32)]);
    offset += @sizeOf(u32);
    if (payload.len - offset < mz_packed_payload_bytes) return error.UnexpectedEndOfStream;
    offset += mz_packed_payload_bytes;
    const mz_payload_bytes = mz_packed_payload_bytes;

    var intensity_metadata_bytes: usize = 0;
    var intensity_payload_bytes: usize = 0;
    if ((header.flags & flag_lossless_intensity_raw) != 0) {
        intensity_payload_bytes = total_peaks * @sizeOf(f32);
        if (payload.len - offset < intensity_payload_bytes) return error.UnexpectedEndOfStream;
        offset += intensity_payload_bytes;
    } else if ((header.flags & flag_split_exponent) != 0) {
        if (payload.len - offset < 13) return error.UnexpectedEndOfStream;
        offset += 1; // bit_width byte
        offset += 8; // base u64
        const exp_packed_len = readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        if (payload.len - offset < exp_packed_len) return error.UnexpectedEndOfStream;
        offset += exp_packed_len;
        const mantissa_len = total_peaks * 3;
        if (payload.len - offset < mantissa_len) return error.UnexpectedEndOfStream;
        offset += mantissa_len;
        intensity_metadata_bytes = 1 + 8 + 4; // bw + base + payload_len field
        intensity_payload_bytes = exp_packed_len + mantissa_len;
    } else {
        intensity_metadata_bytes = @sizeOf(u16) + @sizeOf(u32);
        if (payload.len - offset < intensity_metadata_bytes) return error.UnexpectedEndOfStream;
        _ = readIntLe(u16, payload[offset .. offset + @sizeOf(u16)]);
        offset += @sizeOf(u16);
        intensity_payload_bytes = readIntLe(u32, payload[offset .. offset + @sizeOf(u32)]);
        offset += @sizeOf(u32);
        if (payload.len - offset < intensity_payload_bytes) return error.UnexpectedEndOfStream;
        offset += intensity_payload_bytes;
    }

    if (offset != payload.len) return error.TrailingBlockPayload;

    return .{
        .header_bytes = header_len,
        .scan_id_bytes = scan_id_bytes,
        .rt_bytes = rt_bytes,
        .precursor_bytes = precursor_bytes,
        .peak_count_bytes = peak_count_bytes,
        .mz_metadata_bytes = mz_metadata_bytes,
        .mz_payload_bytes = mz_payload_bytes,
        .intensity_metadata_bytes = intensity_metadata_bytes,
        .intensity_payload_bytes = intensity_payload_bytes,
        .total_bytes = header_len + payload.len,
    };
}
