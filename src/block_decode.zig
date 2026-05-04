const std = @import("std");
const builtin = @import("builtin");
const binary_reader = @import("binary_reader");
const quantize = @import("quantize");
const bitpack = @import("bitpack");
const rans = @import("rans");
const common = @import("block_common");

pub const Allocator = std.mem.Allocator;

fn unpackNextForValue(payload: []const u8, bit_width: u8, bit_offset: *usize, base: u64) !u64 {
    if (bit_width == 0) return base;

    var offset_value: u64 = 0;
    var written: u8 = 0;

    while (written < bit_width) {
        const bit_index = bit_offset.* & 7;
        const available_bits = 8 - bit_index;
        const chunk_bits: u8 = @intCast(@min(@as(usize, bit_width - written), available_bits));
        const mask = (@as(u64, 1) << @as(u6, @intCast(chunk_bits))) - 1;
        const byte = payload[bit_offset.* / 8];
        const chunk = (@as(u64, byte) >> @as(u6, @intCast(bit_index))) & mask;
        offset_value |= chunk << @as(u6, @intCast(written));

        bit_offset.* += chunk_bits;
        written += chunk_bits;
    }

    const sum = @addWithOverflow(base, offset_value);
    if (sum[1] != 0) return error.Overflow;
    return sum[0];
}

fn decodeFlatMzOne(raw: u64, uses_f32: bool, scale_factor: u32) !f64 {
    if (uses_f32) return @as(f64, @as(f32, @bitCast(@as(u32, @truncate(raw)))));
    return quantize.dequantizeMzValue(raw, scale_factor);
}

fn decodeFlatMzBlockLevel(
    flat_mz: []f64,
    peak_counts: []const u32,
    payload: []const u8,
    bit_width: u8,
    base: u64,
    uses_f32: bool,
    scale_factor: u32,
) !void {
    const required_payload_len = common.packedByteLen(bit_width, flat_mz.len);
    if (payload.len < required_payload_len) return error.UnexpectedEndOfStream;

    var bit_offset: usize = 0;
    var mz_cursor: usize = 0;
    for (peak_counts) |peak_count| {
        if (peak_count == 0) continue;

        const first = try unpackNextForValue(payload, bit_width, &bit_offset, base);
        flat_mz[mz_cursor] = try decodeFlatMzOne(first, uses_f32, scale_factor);
        var previous = first;

        var i: u32 = 1;
        while (i < peak_count) : (i += 1) {
            const delta = try unpackNextForValue(payload, bit_width, &bit_offset, base);
            const sum = @addWithOverflow(previous, delta);
            if (sum[1] != 0) return error.Overflow;
            flat_mz[mz_cursor + i] = try decodeFlatMzOne(sum[0], uses_f32, scale_factor);
            previous = sum[0];
        }

        mz_cursor += peak_count;
    }
}

fn decodeFlatMzPerSpectrum(
    flat_mz: []f64,
    peak_counts: []const u32,
    bit_widths: []const u8,
    payload: []const u8,
    base: u64,
    uses_f32: bool,
    scale_factor: u32,
) !void {
    const required_payload_len = try common.perSpectrumPayloadLen(bit_widths, peak_counts);
    if (payload.len < required_payload_len) return error.UnexpectedEndOfStream;

    var payload_cursor: usize = 0;
    var mz_cursor: usize = 0;
    for (peak_counts, 0..) |peak_count, spectrum_idx| {
        if (peak_count == 0) continue;

        const spectrum_bit_width = bit_widths[spectrum_idx];
        const spectrum_payload_len = common.packedByteLen(spectrum_bit_width, peak_count);
        if (payload.len - payload_cursor < spectrum_payload_len) return error.UnexpectedEndOfStream;

        const spectrum_payload = payload[payload_cursor .. payload_cursor + spectrum_payload_len];
        var spectrum_bit_offset: usize = 0;

        const first = try unpackNextForValue(spectrum_payload, spectrum_bit_width, &spectrum_bit_offset, base);
        flat_mz[mz_cursor] = try decodeFlatMzOne(first, uses_f32, scale_factor);
        var previous = first;

        var i: u32 = 1;
        while (i < peak_count) : (i += 1) {
            const delta = try unpackNextForValue(spectrum_payload, spectrum_bit_width, &spectrum_bit_offset, base);
            const sum = @addWithOverflow(previous, delta);
            if (sum[1] != 0) return error.Overflow;
            flat_mz[mz_cursor + i] = try decodeFlatMzOne(sum[0], uses_f32, scale_factor);
            previous = sum[0];
        }

        mz_cursor += peak_count;
        payload_cursor += spectrum_payload_len;
    }
}

fn decodeFlatMzFromPackedForPayload(
    flat_mz: []f64,
    peak_counts: []const u32,
    payload: []const u8,
    bit_width: u8,
    per_spectrum_bit_widths: ?[]const u8,
    base: u64,
    uses_f32: bool,
    scale_factor: u32,
) !void {
    if (per_spectrum_bit_widths) |widths| {
        return decodeFlatMzPerSpectrum(flat_mz, peak_counts, widths, payload, base, uses_f32, scale_factor);
    }
    return decodeFlatMzBlockLevel(flat_mz, peak_counts, payload, bit_width, base, uses_f32, scale_factor);
}

pub fn parseHeader(bytes: []const u8) !common.BlockHeader {
    if (bytes.len < common.header_len) return error.UnexpectedEndOfStream;

    return .{
        .spectrum_count = common.readIntLe(u16, bytes[0..2]),
        .ms_level = bytes[2],
        .flags = bytes[3],
        .total_peaks = common.readIntLe(u32, bytes[4..8]),
        .mz_scale_factor = common.readIntLe(u32, bytes[8..12]),
        .intensity_quant = common.readIntLe(u16, bytes[12..14]),
        .reserved0 = common.readIntLe(u16, bytes[14..16]),
        .mz_bit_width = bytes[16],
        .intensity_bit_width = bytes[17],
        .reserved1 = common.readIntLe(u16, bytes[18..20]),
        .rt_min = common.readF32Le(bytes[20..24]),
        .rt_max = common.readF32Le(bytes[24..28]),
        .payload_bytes = common.readIntLe(u32, bytes[28..32]),
        .decompressed_bytes = common.readIntLe(u32, bytes[32..36]),
        .checksum = common.readIntLe(u32, bytes[36..40]),
    };
}

pub fn decodeBlock(allocator: Allocator, block_bytes: []const u8) ![]binary_reader.RawSpectrum {
    const header = try parseHeader(block_bytes);
    if (block_bytes.len < common.header_len + header.payload_bytes) return error.UnexpectedEndOfStream;

    var block_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer block_arena.deinit();
    const tmp = block_arena.allocator();

    const payload = block_bytes[common.header_len .. common.header_len + header.payload_bytes];
    if (std.hash.crc.Crc32.hash(payload) != header.checksum) return error.ChecksumMismatch;

    const spectrum_count = header.spectrum_count;
    const total_peaks = header.total_peaks;
    var offset: usize = 0;

    const scan_ids = try allocator.alloc(u32, spectrum_count);
    defer allocator.free(scan_ids);
    if ((header.flags & common.flag_delta_scan_id) != 0) {
        if (payload.len - offset < 13) return error.UnexpectedEndOfStream;
        const bit_width = payload[offset];
        offset += 1;
        const base = common.readIntLe(u64, payload[offset .. offset + 8]);
        offset += 8;
        const pack_len = common.readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        if (payload.len - offset < pack_len) return error.UnexpectedEndOfStream;
        const unpacked = try bitpack.unpackForU64(tmp, .{
            .base = base,
            .bit_width = bit_width,
            .count = spectrum_count,
            .payload = payload[offset .. offset + pack_len],
        });
        defer tmp.free(unpacked);
        offset += pack_len;
        var running: u32 = 0;
        for (scan_ids, 0..) |*value, idx| {
            if (unpacked[idx] > std.math.maxInt(u32)) return error.Overflow;
            const sum = @addWithOverflow(running, @as(u32, @intCast(unpacked[idx])));
            if (sum[1] != 0) return error.Overflow;
            running = sum[0];
            value.* = running;
        }
    } else {
        for (scan_ids) |*value| {
            if (payload.len - offset < 4) return error.UnexpectedEndOfStream;
            value.* = common.readIntLe(u32, payload[offset .. offset + 4]);
            offset += 4;
        }
    }

    const rt_values = try allocator.alloc(f32, spectrum_count);
    defer allocator.free(rt_values);
    if ((header.flags & common.flag_delta_rt) != 0) {
        if (payload.len - offset < 13) return error.UnexpectedEndOfStream;
        const bit_width = payload[offset];
        offset += 1;
        const base = common.readIntLe(u64, payload[offset .. offset + 8]);
        offset += 8;
        const pack_len = common.readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        if (payload.len - offset < pack_len) return error.UnexpectedEndOfStream;
        const unpacked = try bitpack.unpackForU64(tmp, .{
            .base = base,
            .bit_width = bit_width,
            .count = spectrum_count,
            .payload = payload[offset .. offset + pack_len],
        });
        defer tmp.free(unpacked);
        offset += pack_len;
        var running_bits: u32 = 0;
        for (rt_values, 0..) |*value, idx| {
            if (unpacked[idx] > std.math.maxInt(u32)) return error.Overflow;
            const sum_bits = @addWithOverflow(running_bits, @as(u32, @intCast(unpacked[idx])));
            if (sum_bits[1] != 0) return error.Overflow;
            running_bits = sum_bits[0];
            value.* = @bitCast(running_bits);
        }
    } else {
        for (rt_values) |*value| {
            if (payload.len - offset < 4) return error.UnexpectedEndOfStream;
            value.* = common.readF32Le(payload[offset .. offset + 4]);
            offset += 4;
        }
    }

    const precursor_values = try allocator.alloc(f64, spectrum_count);
    defer allocator.free(precursor_values);
    for (precursor_values) |*value| {
        if (payload.len - offset < 8) return error.UnexpectedEndOfStream;
        value.* = common.readF64Le(payload[offset .. offset + 8]);
        offset += 8;
    }

    const peak_counts = try allocator.alloc(u32, spectrum_count);
    defer allocator.free(peak_counts);
    var computed_total_peaks: usize = 0;
    for (peak_counts) |*value| {
        if (payload.len - offset < 4) return error.UnexpectedEndOfStream;
        value.* = common.readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        computed_total_peaks += value.*;
    }
    if (computed_total_peaks != total_peaks) return error.InvalidPeakCount;

    const flat_mz = try tmp.alloc(f64, total_peaks);
    defer tmp.free(flat_mz);

    const mz_uses_f32 = (header.flags & common.flag_lossless_mz_f32) != 0;
    {
        if (payload.len - offset < 12) return error.UnexpectedEndOfStream;
        const mz_base = common.readIntLe(u64, payload[offset .. offset + 8]);
        offset += 8;
        const mz_payload_len = common.readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        const mz_per_spectrum_bit_widths = if ((header.flags & common.flag_mz_per_spectrum_bit_widths) != 0) blk: {
            if (payload.len - offset < spectrum_count) return error.UnexpectedEndOfStream;
            const widths = payload[offset .. offset + spectrum_count];
            offset += spectrum_count;
            break :blk widths;
        } else null;
        if (payload.len - offset < mz_payload_len) return error.UnexpectedEndOfStream;

        var mz_rans_payload: ?[]u8 = null;
        defer if (mz_rans_payload) |buf| tmp.free(buf);
        const mz_payload_bytes = if ((header.flags & common.flag_rans_mz) != 0) blk: {
            const decoded_len = if (mz_per_spectrum_bit_widths) |widths|
                try common.perSpectrumPayloadLen(widths, peak_counts)
            else
                common.packedByteLen(header.mz_bit_width, total_peaks);
            mz_rans_payload = try tmp.alloc(u8, decoded_len);
            try rans.decodeInto(payload[offset .. offset + mz_payload_len], mz_rans_payload.?);
            break :blk mz_rans_payload.?;
        } else payload[offset .. offset + mz_payload_len];

        try decodeFlatMzFromPackedForPayload(
            flat_mz,
            peak_counts,
            mz_payload_bytes,
            header.mz_bit_width,
            mz_per_spectrum_bit_widths,
            mz_base,
            mz_uses_f32,
            header.mz_scale_factor,
        );
        offset += mz_payload_len;
    }

    const flat_intensity = try tmp.alloc(f32, total_peaks);
    defer tmp.free(flat_intensity);

    if ((header.flags & common.flag_lossless_intensity_raw) != 0) {
        if ((header.flags & common.flag_rans_intensity) != 0) {
            if (payload.len - offset < 4) return error.UnexpectedEndOfStream;
            const encoded_len = common.readIntLe(u32, payload[offset .. offset + 4]);
            offset += 4;
            if (payload.len - offset < encoded_len) return error.UnexpectedEndOfStream;
            const decoded_bytes = try rans.decodeAlloc(tmp, payload[offset .. offset + encoded_len], total_peaks * @sizeOf(f32));
            defer tmp.free(decoded_bytes);
            if (builtin.cpu.arch.endian() == .little) {
                @memcpy(std.mem.sliceAsBytes(flat_intensity), decoded_bytes);
            } else {
                for (flat_intensity, 0..) |*value, idx| {
                    const start = idx * @sizeOf(f32);
                    value.* = common.readF32Le(decoded_bytes[start .. start + @sizeOf(f32)]);
                }
            }
            offset += encoded_len;
        } else {
            const raw_len = total_peaks * @sizeOf(f32);
            if (payload.len - offset < raw_len) return error.UnexpectedEndOfStream;
            if (builtin.cpu.arch.endian() == .little) {
                @memcpy(std.mem.sliceAsBytes(flat_intensity), payload[offset .. offset + raw_len]);
            } else {
                for (flat_intensity, 0..) |*value, idx| {
                    const start = offset + (idx * @sizeOf(f32));
                    value.* = common.readF32Le(payload[start .. start + @sizeOf(f32)]);
                }
            }
            offset += raw_len;
        }
    } else if ((header.flags & common.flag_split_exponent) != 0) {
        if (payload.len - offset < 13) return error.UnexpectedEndOfStream;
        const exp_bit_width = payload[offset];
        offset += 1;
        const exp_base = common.readIntLe(u64, payload[offset .. offset + 8]);
        offset += 8;
        const exp_payload_len = common.readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        if (payload.len - offset < exp_payload_len) return error.UnexpectedEndOfStream;

        var exp_rans_payload: ?[]u8 = null;
        defer if (exp_rans_payload) |buf| tmp.free(buf);
        const exp_payload_bytes = if ((header.flags & common.flag_rans_intensity) != 0) blk: {
            exp_rans_payload = try rans.decodeAlloc(tmp, payload[offset .. offset + exp_payload_len], common.packedByteLen(exp_bit_width, total_peaks));
            break :blk exp_rans_payload.?;
        } else payload[offset .. offset + exp_payload_len];

        const exp_unpacked = try bitpack.unpackForU64(tmp, .{
            .base = exp_base,
            .bit_width = exp_bit_width,
            .count = total_peaks,
            .payload = exp_payload_bytes,
        });
        defer tmp.free(exp_unpacked);
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
        const intensity_base = common.readIntLe(u16, payload[offset .. offset + 2]);
        offset += 2;
        const intensity_payload_len = common.readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        if (payload.len - offset < intensity_payload_len) return error.UnexpectedEndOfStream;

        var intensity_rans_payload: ?[]u8 = null;
        defer if (intensity_rans_payload) |buf| tmp.free(buf);
        const intensity_payload_bytes = if ((header.flags & common.flag_rans_intensity) != 0) blk: {
            intensity_rans_payload = try rans.decodeAlloc(tmp, payload[offset .. offset + intensity_payload_len], common.packedByteLen(header.intensity_bit_width, total_peaks));
            break :blk intensity_rans_payload.?;
        } else payload[offset .. offset + intensity_payload_len];

        const unpacked = try bitpack.unpackForU64(tmp, .{
            .base = intensity_base,
            .bit_width = header.intensity_bit_width,
            .count = total_peaks,
            .payload = intensity_payload_bytes,
        });
        defer tmp.free(unpacked);
        offset += intensity_payload_len;

        const intensity_log_scale = common.decodeIntensityLogScale(header);

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

pub fn inspectBlockByteBreakdown(block_bytes: []const u8) !common.BlockByteBreakdown {
    const header = try parseHeader(block_bytes);
    if (block_bytes.len < common.header_len + header.payload_bytes) return error.UnexpectedEndOfStream;

    const payload = block_bytes[common.header_len .. common.header_len + header.payload_bytes];
    const spectrum_count = @as(usize, header.spectrum_count);
    const total_peaks = @as(usize, header.total_peaks);

    var offset: usize = 0;

    var scan_id_bytes: usize = 0;
    if ((header.flags & common.flag_delta_scan_id) != 0) {
        if (payload.len - offset < 13) return error.UnexpectedEndOfStream;
        offset += 1; // bit_width byte
        offset += 8; // base u64
        const pack_len = common.readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        if (payload.len - offset < pack_len) return error.UnexpectedEndOfStream;
        offset += pack_len;
        scan_id_bytes = 1 + 8 + 4 + pack_len;
    } else {
        scan_id_bytes = spectrum_count * @sizeOf(u32);
        if (payload.len - offset < scan_id_bytes) return error.UnexpectedEndOfStream;
        offset += scan_id_bytes;
    }

    var rt_bytes: usize = 0;
    if ((header.flags & common.flag_delta_rt) != 0) {
        if (payload.len - offset < 13) return error.UnexpectedEndOfStream;
        offset += 1;
        offset += 8;
        const pack_len = common.readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        if (payload.len - offset < pack_len) return error.UnexpectedEndOfStream;
        offset += pack_len;
        rt_bytes = 1 + 8 + 4 + pack_len;
    } else {
        rt_bytes = spectrum_count * @sizeOf(f32);
        if (payload.len - offset < rt_bytes) return error.UnexpectedEndOfStream;
        offset += rt_bytes;
    }

    const precursor_bytes = spectrum_count * @sizeOf(f64);
    const peak_count_bytes = spectrum_count * @sizeOf(u32);
    if (payload.len - offset < precursor_bytes + peak_count_bytes) return error.UnexpectedEndOfStream;

    var computed_total_peaks: usize = 0;
    for (0..spectrum_count) |idx| {
        const start = offset + precursor_bytes + (idx * @sizeOf(u32));
        const peak_count = common.readIntLe(u32, payload[start .. start + @sizeOf(u32)]);
        computed_total_peaks += peak_count;
    }
    if (computed_total_peaks != total_peaks) return error.InvalidPeakCount;
    offset += precursor_bytes + peak_count_bytes;

    const mz_metadata_bytes = @sizeOf(u64) + @sizeOf(u32);
    if (payload.len - offset < mz_metadata_bytes) return error.UnexpectedEndOfStream;
    _ = common.readIntLe(u64, payload[offset .. offset + @sizeOf(u64)]);
    offset += @sizeOf(u64);
    const mz_packed_payload_bytes = common.readIntLe(u32, payload[offset .. offset + @sizeOf(u32)]);
    offset += @sizeOf(u32);
    const mz_width_bytes = if ((header.flags & common.flag_mz_per_spectrum_bit_widths) != 0) spectrum_count else 0;
    if (payload.len - offset < mz_width_bytes) return error.UnexpectedEndOfStream;
    offset += mz_width_bytes;
    if (payload.len - offset < mz_packed_payload_bytes) return error.UnexpectedEndOfStream;
    offset += mz_packed_payload_bytes;
    const mz_payload_bytes = mz_width_bytes + mz_packed_payload_bytes;

    var intensity_metadata_bytes: usize = 0;
    var intensity_payload_bytes: usize = 0;
    if ((header.flags & common.flag_lossless_intensity_raw) != 0) {
        if ((header.flags & common.flag_rans_intensity) != 0) {
            intensity_metadata_bytes = @sizeOf(u32);
            if (payload.len - offset < intensity_metadata_bytes) return error.UnexpectedEndOfStream;
            intensity_payload_bytes = common.readIntLe(u32, payload[offset .. offset + @sizeOf(u32)]);
            offset += @sizeOf(u32);
            if (payload.len - offset < intensity_payload_bytes) return error.UnexpectedEndOfStream;
            offset += intensity_payload_bytes;
        } else {
            intensity_payload_bytes = total_peaks * @sizeOf(f32);
            if (payload.len - offset < intensity_payload_bytes) return error.UnexpectedEndOfStream;
            offset += intensity_payload_bytes;
        }
    } else if ((header.flags & common.flag_split_exponent) != 0) {
        if (payload.len - offset < 13) return error.UnexpectedEndOfStream;
        offset += 1;
        offset += 8;
        const exp_packed_len = common.readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        if (payload.len - offset < exp_packed_len) return error.UnexpectedEndOfStream;
        offset += exp_packed_len;
        const mantissa_len = total_peaks * 3;
        if (payload.len - offset < mantissa_len) return error.UnexpectedEndOfStream;
        offset += mantissa_len;
        intensity_metadata_bytes = 1 + 8 + 4;
        intensity_payload_bytes = exp_packed_len + mantissa_len;
    } else {
        intensity_metadata_bytes = @sizeOf(u16) + @sizeOf(u32);
        if (payload.len - offset < intensity_metadata_bytes) return error.UnexpectedEndOfStream;
        _ = common.readIntLe(u16, payload[offset .. offset + @sizeOf(u16)]);
        offset += @sizeOf(u16);
        intensity_payload_bytes = common.readIntLe(u32, payload[offset .. offset + @sizeOf(u32)]);
        offset += @sizeOf(u32);
        if (payload.len - offset < intensity_payload_bytes) return error.UnexpectedEndOfStream;
        offset += intensity_payload_bytes;
    }

    if (offset != payload.len) return error.TrailingBlockPayload;

    return .{
        .header_bytes = common.header_len,
        .scan_id_bytes = scan_id_bytes,
        .rt_bytes = rt_bytes,
        .precursor_bytes = precursor_bytes,
        .peak_count_bytes = peak_count_bytes,
        .mz_metadata_bytes = mz_metadata_bytes,
        .mz_payload_bytes = mz_payload_bytes,
        .intensity_metadata_bytes = intensity_metadata_bytes,
        .intensity_payload_bytes = intensity_payload_bytes,
        .total_bytes = common.header_len + payload.len,
    };
}
