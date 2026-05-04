const std = @import("std");
const builtin = @import("builtin");
const binary_reader = @import("binary_reader");
const quantize = @import("quantize");
const bitpack = @import("bitpack");
const rans = @import("rans");
const common = @import("block_common");

pub const Allocator = std.mem.Allocator;

const PerSpectrumMzAnalysis = struct {
    max_bit_width: u8,
    bit_widths: []u8,
    payload_len: usize,

    fn deinit(self: PerSpectrumMzAnalysis, allocator: Allocator) void {
        allocator.free(self.bit_widths);
    }

    fn totalRawBytes(self: PerSpectrumMzAnalysis) usize {
        return self.bit_widths.len + self.payload_len;
    }
};

fn requiredBitWidthAgainstBase(values: []const u64, base: u64) u8 {
    var max_offset: u64 = 0;
    for (values) |value| {
        const offset = value - base;
        if (offset > max_offset) max_offset = offset;
    }
    return bitpack.requiredBitWidth(max_offset);
}

fn packForSliceFixedBase(payload: []u8, values: []const u64, base: u64, bit_width: u8) void {
    @memset(payload, 0);
    if (bit_width == 0 or values.len == 0) return;

    var bit_offset: usize = 0;
    for (values) |value| {
        var remaining = bit_width;
        var current = value - base;

        while (remaining > 0) {
            const bit_index = bit_offset & 7;
            const free_bits = 8 - bit_index;
            const chunk_bits: u8 = @intCast(@min(@as(usize, remaining), free_bits));
            const mask = (@as(u64, 1) << @as(u6, @intCast(chunk_bits))) - 1;
            const chunk = current & mask;
            payload[bit_offset / 8] |= @as(u8, @intCast(chunk << @as(u6, @intCast(bit_index))));

            current >>= @as(u6, @intCast(chunk_bits));
            bit_offset += chunk_bits;
            remaining -= chunk_bits;
        }
    }
}

fn analyzeMzPerSpectrumAlloc(
    allocator: Allocator,
    spectra: []const binary_reader.RawSpectrum,
    mz_values: []const u64,
    base: u64,
) !PerSpectrumMzAnalysis {
    const bit_widths = try allocator.alloc(u8, spectra.len);
    errdefer allocator.free(bit_widths);

    var total_payload_len: usize = 0;
    var max_bit_width: u8 = 0;
    var value_cursor: usize = 0;
    for (spectra, 0..) |spectrum, spectrum_idx| {
        const spectrum_values = mz_values[value_cursor .. value_cursor + spectrum.mz.len];
        const bit_width = requiredBitWidthAgainstBase(spectrum_values, base);
        bit_widths[spectrum_idx] = bit_width;
        total_payload_len += common.packedByteLen(bit_width, spectrum.mz.len);
        if (bit_width > max_bit_width) max_bit_width = bit_width;
        value_cursor += spectrum.mz.len;
    }

    return .{
        .max_bit_width = max_bit_width,
        .bit_widths = bit_widths,
        .payload_len = total_payload_len,
    };
}

fn flattenMzAsF32Bits(allocator: Allocator, spectra: []const binary_reader.RawSpectrum) ![]u64 {
    if (spectra.len == 0) return error.EmptyBlock;
    const total_peaks = try common.totalPeakCount(spectra);
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
    if (spectra.len == 0) return error.EmptyBlock;
    const total_peaks = try common.totalPeakCount(spectra);
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

fn buildScanIdDeltas(allocator: Allocator, spectra: []const binary_reader.RawSpectrum) ![]u64 {
    if (spectra.len == 0) return error.EmptyBlock;
    const result = try allocator.alloc(u64, spectra.len);
    errdefer allocator.free(result);
    result[0] = spectra[0].scan_id;
    for (spectra[1..], 1..) |spectrum, idx| {
        if (spectrum.scan_id < spectra[idx - 1].scan_id) return error.NonMonotonicScanIds;
        result[idx] = spectrum.scan_id - spectra[idx - 1].scan_id;
    }
    return result;
}

fn buildRtDeltas(allocator: Allocator, spectra: []const binary_reader.RawSpectrum) ![]u64 {
    if (spectra.len == 0) return error.EmptyBlock;
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
    const total_peaks = try common.totalPeakCount(spectra);
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

fn appendRawIntensityBytes(payload: *std.ArrayList(u8), a: Allocator, spectra: []const binary_reader.RawSpectrum) !void {
    for (spectra) |spectrum| {
        if (builtin.cpu.arch.endian() == .little) {
            try payload.appendSlice(a, std.mem.sliceAsBytes(spectrum.intensity));
        } else {
            for (spectrum.intensity) |value| try common.appendF32Le(payload, a, value);
        }
    }
}

fn writeHeader(list: *std.ArrayList(u8), allocator: Allocator, header: common.BlockHeader) !void {
    try common.appendIntLe(list, allocator, u16, header.spectrum_count);
    try list.append(allocator, header.ms_level);
    try list.append(allocator, header.flags);
    try common.appendIntLe(list, allocator, u32, header.total_peaks);
    try common.appendIntLe(list, allocator, u32, header.mz_scale_factor);
    try common.appendIntLe(list, allocator, u16, header.intensity_quant);
    try common.appendIntLe(list, allocator, u16, header.reserved0);
    try list.append(allocator, header.mz_bit_width);
    try list.append(allocator, header.intensity_bit_width);
    try common.appendIntLe(list, allocator, u16, header.reserved1);
    try common.appendF32Le(list, allocator, header.rt_min);
    try common.appendF32Le(list, allocator, header.rt_max);
    try common.appendIntLe(list, allocator, u32, header.payload_bytes);
    try common.appendIntLe(list, allocator, u32, header.decompressed_bytes);
    try common.appendIntLe(list, allocator, u32, header.checksum);
}

pub fn encodeBlockDetailed(allocator: Allocator, spectra: []const binary_reader.RawSpectrum, options: common.EncodeOptions) !common.EncodedBlock {
    if (spectra.len == 0) return error.EmptyBlock;
    if (spectra.len > std.math.maxInt(u16)) return error.TooManySpectra;

    var block_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer block_arena.deinit();
    const tmp = block_arena.allocator();

    const ms_level = spectra[0].ms_level;
    var rt_min = spectra[0].rt_seconds;
    var rt_max = spectra[0].rt_seconds;
    for (spectra) |spectrum| {
        if (spectrum.ms_level != ms_level) return error.MixedMsLevel;
        if (spectrum.rt_seconds < rt_min) rt_min = spectrum.rt_seconds;
        if (spectrum.rt_seconds > rt_max) rt_max = spectrum.rt_seconds;
    }

    const total_peaks = try common.totalPeakCount(spectra);
    if (total_peaks > std.math.maxInt(u32)) return error.TooManyPeaks;

    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(tmp);

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
        const scan_id_deltas = buildScanIdDeltas(tmp, spectra) catch |err| blk: {
            if (err == error.NonMonotonicScanIds) {
                break :blk null;
            }
            return err;
        };
        if (scan_id_deltas) |deltas| {
            defer tmp.free(deltas);
            flags |= common.flag_delta_scan_id;
            const pack_result = try bitpack.packForU64(tmp, deltas);
            defer pack_result.deinit(tmp);
            try payload.append(tmp, pack_result.bit_width);
            try common.appendIntLe(&payload, tmp, u64, pack_result.base);
            try common.appendIntLe(&payload, tmp, u32, @intCast(pack_result.payload.len));
            try payload.appendSlice(tmp, pack_result.payload);
        } else {
            for (spectra) |spectrum| try common.appendIntLe(&payload, tmp, u32, spectrum.scan_id);
        }
    }

    // rt_seconds: delta-encode f32 bit patterns when RT is non-decreasing.
    {
        const rt_deltas = buildRtDeltas(tmp, spectra) catch |err| blk: {
            if (err == error.NonMonotonicRt) {
                break :blk null;
            }
            return err;
        };
        if (rt_deltas) |deltas| {
            defer tmp.free(deltas);
            flags |= common.flag_delta_rt;
            const pack_result = try bitpack.packForU64(tmp, deltas);
            defer pack_result.deinit(tmp);
            try payload.append(tmp, pack_result.bit_width);
            try common.appendIntLe(&payload, tmp, u64, pack_result.base);
            try common.appendIntLe(&payload, tmp, u32, @intCast(pack_result.payload.len));
            try payload.appendSlice(tmp, pack_result.payload);
        } else {
            for (spectra) |spectrum| try common.appendF32Le(&payload, tmp, spectrum.rt_seconds);
        }
    }

    for (spectra) |spectrum| try common.appendF64Le(&payload, tmp, spectrum.precursor_mz);
    for (spectra) |spectrum| try common.appendIntLe(&payload, tmp, u32, @intCast(spectrum.mz.len));
    var mz_bit_width: u8 = 0;
    var mz_scale_for_header: u32 = options.mz_scale_factor;
    var stats: common.BlockEncodeStats = .{
        .ms_level = ms_level,
        .spectrum_count = spectra.len,
        .total_peaks = total_peaks,
        .mz_per_spectrum_widths = false,
        .mz_raw_bytes = 0,
        .mz_stored_bytes = 0,
        .mz_rans_used = false,
        .mz_estimated_rans_bytes = 0,
        .intensity_raw_f32_bytes = total_peaks * @sizeOf(f32),
        .intensity_base_bytes = 0,
        .intensity_stored_bytes = total_peaks * @sizeOf(f32),
        .intensity_rans_used = false,
        .intensity_estimated_rans_bytes = 0,
        .intensity_mode = .raw_plain,
        .payload_bytes = 0,
    };
    {
        // Choose the m/z encoding strategy
        const mz_deltas = blk: {
            if (options.mode == .lossless and common.allMzExactlyF32(spectra)) {
                flags |= common.flag_lossless_mz_f32;
                mz_scale_for_header = 0;
                break :blk try flattenMzAsF32Bits(tmp, spectra);
            } else {
                const scale = if (options.mode == .lossless) options.lossless_mz_scale_factor else options.mz_scale_factor;
                mz_scale_for_header = scale;
                break :blk try flattenMzDeltas(tmp, spectra, scale);
            }
        };
        defer tmp.free(mz_deltas);
        const packed_mz = try bitpack.packForU64(tmp, mz_deltas);
        defer packed_mz.deinit(tmp);
        try common.appendIntLe(&payload, tmp, u64, packed_mz.base);
        const block_mz_candidate = try common.maybeEncodeRansAlloc(tmp, packed_mz.payload, options.mz_rans_min_gain_percent);
        defer block_mz_candidate.deinit(tmp);
        var per_spectrum_payload_buf: ?[]u8 = null;
        defer if (per_spectrum_payload_buf) |buf| tmp.free(buf);
        var per_spectrum_candidate: ?common.RansCandidate = null;
        defer if (per_spectrum_candidate) |candidate| candidate.deinit(tmp);

        var selected_payload = packed_mz.payload;
        var selected_stored_bytes = block_mz_candidate.storedBytes();
        var selected_estimated_bytes = if (block_mz_candidate.estimated_total_bytes == 0)
            packed_mz.payload.len
        else
            block_mz_candidate.estimated_total_bytes;
        var selected_rans_used = block_mz_candidate.used();
        var selected_encoded: ?[]const u8 = block_mz_candidate.encoded;
        var selected_bit_widths: ?[]const u8 = null;

        var per_spectrum_analysis = try analyzeMzPerSpectrumAlloc(tmp, spectra, mz_deltas, packed_mz.base);
        defer per_spectrum_analysis.deinit(tmp);

        if (per_spectrum_analysis.totalRawBytes() < packed_mz.payload.len) {
            per_spectrum_payload_buf = try tmp.alloc(u8, per_spectrum_analysis.payload_len);

            var value_cursor: usize = 0;
            var payload_cursor: usize = 0;
            for (spectra, 0..) |spectrum, spectrum_idx| {
                const spectrum_values = mz_deltas[value_cursor .. value_cursor + spectrum.mz.len];
                const bit_width = per_spectrum_analysis.bit_widths[spectrum_idx];
                const spectrum_payload_len = common.packedByteLen(bit_width, spectrum.mz.len);
                packForSliceFixedBase(per_spectrum_payload_buf.?[payload_cursor .. payload_cursor + spectrum_payload_len], spectrum_values, packed_mz.base, bit_width);
                value_cursor += spectrum.mz.len;
                payload_cursor += spectrum_payload_len;
            }

            per_spectrum_candidate = try common.maybeEncodeRansAlloc(tmp, per_spectrum_payload_buf.?, options.mz_rans_min_gain_percent);
            const per_spectrum_stored_bytes = per_spectrum_analysis.bit_widths.len + per_spectrum_candidate.?.storedBytes();
            if (per_spectrum_stored_bytes < selected_stored_bytes) {
                selected_payload = per_spectrum_payload_buf.?;
                selected_stored_bytes = per_spectrum_stored_bytes;
                selected_estimated_bytes = per_spectrum_analysis.bit_widths.len + if (per_spectrum_candidate.?.estimated_total_bytes == 0)
                    per_spectrum_payload_buf.?.len
                else
                    per_spectrum_candidate.?.estimated_total_bytes;
                selected_rans_used = per_spectrum_candidate.?.used();
                selected_encoded = per_spectrum_candidate.?.encoded;
                selected_bit_widths = per_spectrum_analysis.bit_widths;
            }
        }

        mz_bit_width = if (selected_bit_widths != null) per_spectrum_analysis.max_bit_width else packed_mz.bit_width;
        stats.mz_per_spectrum_widths = selected_bit_widths != null;
        stats.mz_raw_bytes = if (selected_bit_widths != null) per_spectrum_analysis.totalRawBytes() else packed_mz.payload.len;
        stats.mz_estimated_rans_bytes = selected_estimated_bytes;
        stats.mz_stored_bytes = selected_stored_bytes;
        stats.mz_rans_used = selected_rans_used;

        const mz_payload_field: usize = if (selected_bit_widths != null) blk: {
            if (selected_stored_bytes < per_spectrum_analysis.bit_widths.len) return error.InvalidMzPayload;
            break :blk selected_stored_bytes - per_spectrum_analysis.bit_widths.len;
        } else selected_stored_bytes;
        try common.appendIntLe(&payload, tmp, u32, @intCast(mz_payload_field));
        if (selected_bit_widths) |bit_widths| {
            flags |= common.flag_mz_per_spectrum_bit_widths;
            try payload.appendSlice(tmp, bit_widths);
        }
        if (selected_encoded) |rans_payload| {
            flags |= common.flag_rans_mz;
            try payload.appendSlice(tmp, rans_payload);
        } else {
            try payload.appendSlice(tmp, selected_payload);
        }
    }

    var intensity_bit_width: u8 = 0;
    if (options.mode == .lossless) {
        const exp_values = try tmp.alloc(u64, total_peaks);
        defer tmp.free(exp_values);
        {
            var i: usize = 0;
            for (spectra) |spectrum| {
                for (spectrum.intensity) |value| {
                    exp_values[i] = (@as(u32, @bitCast(value)) >> 24) & 0xFF;
                    i += 1;
                }
            }
        }
        const packed_exp = try bitpack.packForU64(tmp, exp_values);
        defer packed_exp.deinit(tmp);
        const split_plain_bytes: usize = 1 + 8 + 4 + packed_exp.payload.len + 3 * total_peaks;
        const raw_plain_bytes: usize = total_peaks * @sizeOf(f32);
        if (split_plain_bytes < raw_plain_bytes) {
            const encoded_exp = try common.maybeEncodeRansAlloc(tmp, packed_exp.payload, options.intensity_rans_min_gain_percent);
            defer encoded_exp.deinit(tmp);
            stats.intensity_raw_f32_bytes = raw_plain_bytes;
            stats.intensity_base_bytes = split_plain_bytes;
            stats.intensity_estimated_rans_bytes = if (encoded_exp.estimated_total_bytes == 0)
                split_plain_bytes
            else
                1 + 8 + 4 + encoded_exp.estimated_total_bytes + 3 * total_peaks;

            if (encoded_exp.encoded) |buf| {
                stats.intensity_mode = .split_rans;
                stats.intensity_rans_used = true;
                stats.intensity_stored_bytes = 1 + 8 + 4 + buf.len + 3 * total_peaks;
                flags |= common.flag_split_exponent | common.flag_rans_intensity;
                intensity_bit_width = packed_exp.bit_width;
                try payload.append(tmp, packed_exp.bit_width);
                try common.appendIntLe(&payload, tmp, u64, packed_exp.base);
                try common.appendIntLe(&payload, tmp, u32, @intCast(buf.len));
                try payload.appendSlice(tmp, buf);
                for (spectra) |spectrum| {
                    for (spectrum.intensity) |value| {
                        const bits: u32 = @bitCast(value);
                        try payload.append(tmp, @truncate(bits & 0xFF));
                        try payload.append(tmp, @truncate((bits >> 8) & 0xFF));
                        try payload.append(tmp, @truncate((bits >> 16) & 0xFF));
                    }
                }
            } else {
                stats.intensity_mode = .split_plain;
                stats.intensity_stored_bytes = split_plain_bytes;
                flags |= common.flag_split_exponent;
                intensity_bit_width = packed_exp.bit_width;
                try payload.append(tmp, packed_exp.bit_width);
                try common.appendIntLe(&payload, tmp, u64, packed_exp.base);
                try common.appendIntLe(&payload, tmp, u32, @intCast(packed_exp.payload.len));
                try payload.appendSlice(tmp, packed_exp.payload);
                for (spectra) |spectrum| {
                    for (spectrum.intensity) |value| {
                        const bits: u32 = @bitCast(value);
                        try payload.append(tmp, @truncate(bits & 0xFF));
                        try payload.append(tmp, @truncate((bits >> 8) & 0xFF));
                        try payload.append(tmp, @truncate((bits >> 16) & 0xFF));
                    }
                }
            }
        } else {
            flags |= common.flag_lossless_intensity_raw;
            stats.intensity_mode = .raw_plain;
            stats.intensity_base_bytes = raw_plain_bytes;
            stats.intensity_stored_bytes = raw_plain_bytes;
            try appendRawIntensityBytes(&payload, tmp, spectra);
        }
    } else {
        const quantized_intensity = try flattenIntensityLossyToU64(
            tmp,
            spectra,
            options.intensity_quant,
            intensity_log_scale,
        );
        defer tmp.free(quantized_intensity);

        const packed_intensity = try bitpack.packForU64(tmp, quantized_intensity);
        defer packed_intensity.deinit(tmp);

        if (packed_intensity.base > std.math.maxInt(u16)) return error.IntensityOverflow;

        intensity_bit_width = packed_intensity.bit_width;
        stats.intensity_mode = .lossy_plain;
        stats.intensity_raw_f32_bytes = total_peaks * @sizeOf(f32);
        stats.intensity_base_bytes = packed_intensity.payload.len + @sizeOf(u16) + @sizeOf(u32);
        try common.appendIntLe(&payload, tmp, u16, @intCast(packed_intensity.base));
        const intensity_candidate = try common.maybeEncodeRansAlloc(tmp, packed_intensity.payload, options.intensity_rans_min_gain_percent);
        defer intensity_candidate.deinit(tmp);
        stats.intensity_estimated_rans_bytes = if (intensity_candidate.estimated_total_bytes == 0)
            stats.intensity_base_bytes
        else
            @sizeOf(u16) + @sizeOf(u32) + intensity_candidate.estimated_total_bytes;
        if (intensity_candidate.encoded) |rans_payload| {
            flags |= common.flag_rans_intensity;
            stats.intensity_mode = .lossy_rans;
            stats.intensity_rans_used = true;
            stats.intensity_stored_bytes = @sizeOf(u16) + @sizeOf(u32) + rans_payload.len;
            try common.appendIntLe(&payload, tmp, u32, @intCast(rans_payload.len));
            try payload.appendSlice(tmp, rans_payload);
        } else {
            stats.intensity_stored_bytes = stats.intensity_base_bytes;
            try common.appendIntLe(&payload, tmp, u32, @intCast(packed_intensity.payload.len));
            try payload.appendSlice(tmp, packed_intensity.payload);
        }
    }

    const decompressed_bytes = (@as(usize, spectra.len) * (@sizeOf(u32) + @sizeOf(f32) + @sizeOf(f64) + @sizeOf(u32))) +
        (total_peaks * (@sizeOf(f64) + @sizeOf(f32)));
    if (payload.items.len > std.math.maxInt(u32) or decompressed_bytes > std.math.maxInt(u32)) return error.BlockTooLarge;

    const intensity_scale_bits = common.encodeIntensityLogScale(intensity_log_scale);

    const header: common.BlockHeader = .{
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
    stats.payload_bytes = payload.items.len;
    payload.deinit(tmp);

    return .{
        .bytes = try block.toOwnedSlice(allocator),
        .stats = stats,
    };
}

pub fn encodeBlock(allocator: Allocator, spectra: []const binary_reader.RawSpectrum, options: common.EncodeOptions) ![]u8 {
    const detailed = try encodeBlockDetailed(allocator, spectra, options);
    return detailed.bytes;
}
