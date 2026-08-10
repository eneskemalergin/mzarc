//! Block encode: metadata, first-peak-split m/z, and lossless or lossy intensity.
//! Scratch must be an arena: temps are not freed individually.

const std = @import("std");
const builtin = @import("builtin");
const binary_reader = @import("binary_reader");
const quantize = @import("quantize");
const bitpack = @import("bitpack");
const common = @import("block_common");
const crc32 = @import("crc32");

pub const Allocator = std.mem.Allocator;

const MzFirstPeakSplit = struct {
    firsts: []u64,
    deltas: []u64,
};

fn mzDomainValue(value: f64, uses_f32: bool, scale_factor: u32) !u64 {
    if (uses_f32) {
        const as_f32: f32 = @floatCast(value);
        return @as(u32, @bitCast(as_f32));
    }
    return try quantize.quantizeMzValue(value, scale_factor);
}

fn flattenMzFirstPeakSplit(allocator: Allocator, spectra: []const binary_reader.RawSpectrum, uses_f32: bool, scale_factor: u32) !MzFirstPeakSplit {
    if (spectra.len == 0) return error.EmptyBlock;

    var first_count: usize = 0;
    var delta_count: usize = 0;
    for (spectra) |spectrum| {
        if (spectrum.mz.len == 0) continue;
        first_count = try std.math.add(usize, first_count, 1);
        delta_count = try std.math.add(usize, delta_count, spectrum.mz.len - 1);
    }

    const firsts = try allocator.alloc(u64, first_count);
    const deltas = try allocator.alloc(u64, delta_count);

    var fi: usize = 0;
    var di: usize = 0;
    for (spectra) |spectrum| {
        if (spectrum.mz.len == 0) continue;
        var previous = try mzDomainValue(spectrum.mz[0], uses_f32, scale_factor);
        firsts[fi] = previous;
        fi += 1;
        for (spectrum.mz[1..]) |value| {
            const cur = try mzDomainValue(value, uses_f32, scale_factor);
            if (cur < previous) return error.NonMonotonicInput;
            deltas[di] = cur - previous;
            previous = cur;
            di += 1;
        }
    }
    if (fi != first_count or di != delta_count) return error.InternalCountMismatch;
    return .{ .firsts = firsts, .deltas = deltas };
}

fn appendMzFirstPeakSplitSection(
    payload: *std.ArrayList(u8),
    tmp: Allocator,
    spectra: []const binary_reader.RawSpectrum,
    options: common.EncodeOptions,
    flags: *u8,
    mz_bit_width: *u8,
    mz_scale_for_header: *u32,
    stats: *common.BlockEncodeStats,
) !void {
    const uses_f32 = options.mode == .lossless and common.allMzExactlyF32(spectra);
    if (uses_f32) {
        flags.* |= common.flag_lossless_mz_f32;
        mz_scale_for_header.* = 0;
    } else {
        mz_scale_for_header.* = if (options.mode == .lossless)
            options.lossless_mz_scale_factor
        else
            options.mz_scale_factor;
    }

    const split = try flattenMzFirstPeakSplit(tmp, spectra, uses_f32, mz_scale_for_header.*);
    const first_size: u8 = if (uses_f32) 4 else 8;
    const first_bytes = try std.math.mul(usize, split.firsts.len, first_size);

    const packed_deltas = try bitpack.packForU64(tmp, split.deltas);
    const delta_candidate = try common.maybeEncodeRansAlloc(tmp, packed_deltas.payload, options.mz_rans_min_gain_percent);
    const delta_stored = delta_candidate.storedBytes();
    const body_len = try std.math.add(usize, try std.math.add(usize, 5, first_bytes), delta_stored);
    if (body_len > std.math.maxInt(u32)) return error.BlockTooLarge;

    mz_bit_width.* = packed_deltas.bit_width;
    stats.mz_raw_bytes = try std.math.add(usize, first_bytes, packed_deltas.payload.len);
    stats.mz_stored_bytes = body_len;
    stats.mz_rans_used = delta_candidate.used();
    stats.mz_estimated_rans_bytes = if (delta_candidate.estimated_total_bytes == 0)
        body_len
    else
        try std.math.add(usize, try std.math.add(usize, 5, first_bytes), delta_candidate.estimated_total_bytes);

    try common.appendIntLe(payload, tmp, u64, packed_deltas.base);
    try common.appendIntLe(payload, tmp, u32, @intCast(body_len));
    if (split.firsts.len > std.math.maxInt(u32)) return error.TooManySpectra;
    try common.appendIntLe(payload, tmp, u32, @intCast(split.firsts.len));
    try payload.append(tmp, first_size);
    if (uses_f32) {
        for (split.firsts) |first| {
            if (first > std.math.maxInt(u32)) return error.Overflow;
            try common.appendIntLe(payload, tmp, u32, @intCast(first));
        }
    } else {
        for (split.firsts) |first| try common.appendIntLe(payload, tmp, u64, first);
    }
    if (delta_candidate.encoded) |rans_payload| {
        flags.* |= common.flag_rans_mz;
        try payload.appendSlice(tmp, rans_payload);
    } else {
        try payload.appendSlice(tmp, packed_deltas.payload);
    }
}

fn buildScanIdDeltas(allocator: Allocator, spectra: []const binary_reader.RawSpectrum) ![]u64 {
    if (spectra.len == 0) return error.EmptyBlock;
    const result = try allocator.alloc(u64, spectra.len);
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
    result[0] = @as(u32, @bitCast(spectra[0].rt_seconds));
    for (spectra[1..], 1..) |spectrum, idx| {
        if (spectrum.rt_seconds < spectra[idx - 1].rt_seconds) return error.NonMonotonicRt;
        const cur_bits: u32 = @bitCast(spectrum.rt_seconds);
        const prev_bits: u32 = @bitCast(spectra[idx - 1].rt_seconds);
        // cur_bits < prev_bits only when prev = -0.0 (0x80000000) and cur = +0.0 (0x00000000).
        // The floats are equal (RT is non-decreasing), so the delta is 0.
        result[idx] = if (cur_bits >= prev_bits) cur_bits - prev_bits else 0;
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

fn appendIntensityMantissas(
    payload: *std.ArrayList(u8),
    allocator: Allocator,
    spectra: []const binary_reader.RawSpectrum,
    mantissa_len: usize,
) !void {
    const mantissas = try payload.addManyAsSlice(allocator, mantissa_len);
    var offset: usize = 0;
    for (spectra) |spectrum| {
        for (spectrum.intensity) |value| {
            const bits: u32 = @bitCast(value);
            mantissas[offset] = @truncate(bits);
            mantissas[offset + 1] = @truncate(bits >> 8);
            mantissas[offset + 2] = @truncate(bits >> 16);
            offset += 3;
        }
    }
    std.debug.assert(offset == mantissas.len);
}

fn writeHeader(list: *std.ArrayList(u8), allocator: Allocator, header: common.BlockHeader) !void {
    var buf: [common.header_len]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], header.spectrum_count, .little);
    buf[2] = header.ms_level;
    buf[3] = header.flags;
    std.mem.writeInt(u32, buf[4..8], header.total_peaks, .little);
    std.mem.writeInt(u32, buf[8..12], header.mz_scale_factor, .little);
    std.mem.writeInt(u16, buf[12..14], header.intensity_quant, .little);
    std.mem.writeInt(u16, buf[14..16], header.intensity_log_scale_lo, .little);
    buf[16] = header.mz_bit_width;
    buf[17] = header.intensity_bit_width;
    std.mem.writeInt(u16, buf[18..20], header.intensity_log_scale_hi, .little);
    std.mem.writeInt(u32, buf[20..24], @bitCast(header.rt_min), .little);
    std.mem.writeInt(u32, buf[24..28], @bitCast(header.rt_max), .little);
    std.mem.writeInt(u32, buf[28..32], header.payload_bytes, .little);
    std.mem.writeInt(u32, buf[32..36], header.decompressed_bytes, .little);
    std.mem.writeInt(u32, buf[36..40], header.checksum, .little);
    try list.appendSlice(allocator, &buf);
}

/// `scratch` must be an arena. Temps are not freed individually; reset or deinit the arena.
pub fn encodeBlockDetailed(allocator: Allocator, scratch: Allocator, spectra: []const binary_reader.RawSpectrum, options: common.EncodeOptions) !common.EncodedBlock {
    if (spectra.len == 0) return error.EmptyBlock;
    if (spectra.len > std.math.maxInt(u16)) return error.TooManySpectra;

    const tmp = scratch;

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

    var intensity_log_scale: f32 = 0.0;
    if (options.mode == .lossy) {
        for (spectra) |spectrum| {
            const candidate = quantize.intensityLogMax(spectrum.intensity);
            if (candidate > intensity_log_scale) intensity_log_scale = candidate;
        }
    }

    var flags: u8 = 0;

    {
        const scan_id_deltas = buildScanIdDeltas(tmp, spectra) catch |err| blk: {
            if (err == error.NonMonotonicScanIds) {
                break :blk null;
            }
            return err;
        };
        if (scan_id_deltas) |deltas| {
            flags |= common.flag_delta_scan_id;
            const pack_result = try bitpack.packForU64(tmp, deltas);
            try payload.append(tmp, pack_result.bit_width);
            try common.appendIntLe(&payload, tmp, u64, pack_result.base);
            if (pack_result.payload.len > std.math.maxInt(u32)) return error.BlockTooLarge;
            try common.appendIntLe(&payload, tmp, u32, @intCast(pack_result.payload.len));
            try payload.appendSlice(tmp, pack_result.payload);
        } else {
            for (spectra) |spectrum| try common.appendIntLe(&payload, tmp, u32, spectrum.scan_id);
        }
    }

    {
        const rt_deltas = buildRtDeltas(tmp, spectra) catch |err| blk: {
            if (err == error.NonMonotonicRt) {
                break :blk null;
            }
            return err;
        };
        if (rt_deltas) |deltas| {
            flags |= common.flag_delta_rt;
            const pack_result = try bitpack.packForU64(tmp, deltas);
            try payload.append(tmp, pack_result.bit_width);
            try common.appendIntLe(&payload, tmp, u64, pack_result.base);
            if (pack_result.payload.len > std.math.maxInt(u32)) return error.BlockTooLarge;
            try common.appendIntLe(&payload, tmp, u32, @intCast(pack_result.payload.len));
            try payload.appendSlice(tmp, pack_result.payload);
        } else {
            for (spectra) |spectrum| try common.appendF32Le(&payload, tmp, spectrum.rt_seconds);
        }
    }

    for (spectra) |spectrum| try common.appendF64Le(&payload, tmp, spectrum.precursor_mz);
    for (spectra) |spectrum| {
        if (spectrum.mz.len > std.math.maxInt(u32)) return error.TooManyPeaks;
        try common.appendIntLe(&payload, tmp, u32, @intCast(spectrum.mz.len));
    }
    var mz_bit_width: u8 = 0;
    var mz_scale_for_header: u32 = options.mz_scale_factor;
    var stats: common.BlockEncodeStats = .{
        .ms_level = ms_level,
        .spectrum_count = spectra.len,
        .total_peaks = total_peaks,
        .mz_raw_bytes = 0,
        .mz_stored_bytes = 0,
        .mz_rans_used = false,
        .mz_estimated_rans_bytes = 0,
        .intensity_raw_f32_bytes = try std.math.mul(usize, total_peaks, @sizeOf(f32)),
        .intensity_base_bytes = 0,
        .intensity_stored_bytes = try std.math.mul(usize, total_peaks, @sizeOf(f32)),
        .intensity_rans_used = false,
        .intensity_estimated_rans_bytes = 0,
        .intensity_mode = .raw_plain,
        .payload_bytes = 0,
    };
    try appendMzFirstPeakSplitSection(
        &payload,
        tmp,
        spectra,
        options,
        &flags,
        &mz_bit_width,
        &mz_scale_for_header,
        &stats,
    );

    var intensity_bit_width: u8 = 0;
    if (options.mode == .lossless) {
        const exp_values = try tmp.alloc(u64, total_peaks);
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
        const mantissa_bytes = try std.math.mul(usize, total_peaks, 3);
        const split_plain_bytes = try std.math.add(usize, 1 + 8 + 4 + packed_exp.payload.len, mantissa_bytes);
        const raw_plain_bytes = try std.math.mul(usize, total_peaks, @sizeOf(f32));
        if (split_plain_bytes < raw_plain_bytes) {
            const encoded_exp = try common.maybeEncodeRansAlloc(tmp, packed_exp.payload, options.intensity_rans_min_gain_percent);
            stats.intensity_raw_f32_bytes = raw_plain_bytes;
            stats.intensity_base_bytes = split_plain_bytes;
            stats.intensity_estimated_rans_bytes = if (encoded_exp.estimated_total_bytes == 0)
                split_plain_bytes
            else
                try std.math.add(usize, 1 + 8 + 4 + encoded_exp.estimated_total_bytes, mantissa_bytes);

            if (encoded_exp.encoded) |buf| {
                stats.intensity_mode = .split_rans;
                stats.intensity_rans_used = true;
                stats.intensity_stored_bytes = try std.math.add(usize, 1 + 8 + 4 + buf.len, mantissa_bytes);
                flags |= common.flag_split_exponent | common.flag_rans_intensity;
                intensity_bit_width = packed_exp.bit_width;
                try payload.append(tmp, packed_exp.bit_width);
                try common.appendIntLe(&payload, tmp, u64, packed_exp.base);
                if (buf.len > std.math.maxInt(u32)) return error.BlockTooLarge;
                try common.appendIntLe(&payload, tmp, u32, @intCast(buf.len));
                try payload.appendSlice(tmp, buf);
                try appendIntensityMantissas(&payload, tmp, spectra, mantissa_bytes);
            } else {
                stats.intensity_mode = .split_plain;
                stats.intensity_stored_bytes = split_plain_bytes;
                flags |= common.flag_split_exponent;
                intensity_bit_width = packed_exp.bit_width;
                try payload.append(tmp, packed_exp.bit_width);
                try common.appendIntLe(&payload, tmp, u64, packed_exp.base);
                if (packed_exp.payload.len > std.math.maxInt(u32)) return error.BlockTooLarge;
                try common.appendIntLe(&payload, tmp, u32, @intCast(packed_exp.payload.len));
                try payload.appendSlice(tmp, packed_exp.payload);
                try appendIntensityMantissas(&payload, tmp, spectra, mantissa_bytes);
            }
        } else {
            flags |= common.flag_lossless_intensity_raw;
            stats.intensity_mode = .raw_plain;
            stats.intensity_base_bytes = raw_plain_bytes;

            var raw_intensity: std.ArrayList(u8) = .empty;
            try appendRawIntensityBytes(&raw_intensity, tmp, spectra);

            const raw_candidate = try common.maybeEncodeRansAlloc(tmp, raw_intensity.items, options.intensity_rans_min_gain_percent);

            stats.intensity_estimated_rans_bytes = if (raw_candidate.estimated_total_bytes == 0)
                raw_plain_bytes
            else
                @sizeOf(u32) + raw_candidate.estimated_total_bytes;

            if (raw_candidate.encoded) |rans_payload| {
                flags |= common.flag_rans_intensity;
                stats.intensity_rans_used = true;
                stats.intensity_stored_bytes = @sizeOf(u32) + rans_payload.len;
                if (rans_payload.len > std.math.maxInt(u32)) return error.BlockTooLarge;
                try common.appendIntLe(&payload, tmp, u32, @intCast(rans_payload.len));
                try payload.appendSlice(tmp, rans_payload);
            } else {
                stats.intensity_stored_bytes = raw_intensity.items.len;
                try payload.appendSlice(tmp, raw_intensity.items);
            }
        }
    } else {
        const quantized_intensity = try flattenIntensityLossyToU64(
            tmp,
            spectra,
            options.intensity_quant,
            intensity_log_scale,
        );

        const packed_intensity = try bitpack.packForU64(tmp, quantized_intensity);

        if (packed_intensity.base > std.math.maxInt(u16)) return error.IntensityOverflow;

        intensity_bit_width = packed_intensity.bit_width;
        stats.intensity_mode = .lossy_plain;
        stats.intensity_raw_f32_bytes = try std.math.mul(usize, total_peaks, @sizeOf(f32));
        stats.intensity_base_bytes = packed_intensity.payload.len + @sizeOf(u16) + @sizeOf(u32);
        try common.appendIntLe(&payload, tmp, u16, @intCast(packed_intensity.base));
        const intensity_candidate = try common.maybeEncodeRansAlloc(tmp, packed_intensity.payload, options.intensity_rans_min_gain_percent);
        stats.intensity_estimated_rans_bytes = if (intensity_candidate.estimated_total_bytes == 0)
            stats.intensity_base_bytes
        else
            @sizeOf(u16) + @sizeOf(u32) + intensity_candidate.estimated_total_bytes;
        if (intensity_candidate.encoded) |rans_payload| {
            flags |= common.flag_rans_intensity;
            stats.intensity_mode = .lossy_rans;
            stats.intensity_rans_used = true;
            stats.intensity_stored_bytes = @sizeOf(u16) + @sizeOf(u32) + rans_payload.len;
            if (rans_payload.len > std.math.maxInt(u32)) return error.BlockTooLarge;
            try common.appendIntLe(&payload, tmp, u32, @intCast(rans_payload.len));
            try payload.appendSlice(tmp, rans_payload);
        } else {
            stats.intensity_stored_bytes = stats.intensity_base_bytes;
            if (packed_intensity.payload.len > std.math.maxInt(u32)) return error.BlockTooLarge;
            try common.appendIntLe(&payload, tmp, u32, @intCast(packed_intensity.payload.len));
            try payload.appendSlice(tmp, packed_intensity.payload);
        }
    }

    const per_spectrum = @sizeOf(u32) + @sizeOf(f32) + @sizeOf(f64) + @sizeOf(u32);
    const per_peak = @sizeOf(f64) + @sizeOf(f32);
    const decompressed_bytes = try std.math.add(
        usize,
        try std.math.mul(usize, spectra.len, per_spectrum),
        try std.math.mul(usize, total_peaks, per_peak),
    );
    if (payload.items.len > std.math.maxInt(u32) or decompressed_bytes > std.math.maxInt(u32)) return error.BlockTooLarge;

    const intensity_scale_bits = common.encodeIntensityLogScale(intensity_log_scale);

    const header: common.BlockHeader = .{
        .spectrum_count = @intCast(spectra.len),
        .ms_level = ms_level,
        .flags = flags,
        .total_peaks = @intCast(total_peaks),
        .mz_scale_factor = mz_scale_for_header,
        .intensity_quant = options.intensity_quant,
        .intensity_log_scale_lo = intensity_scale_bits.low,
        .mz_bit_width = mz_bit_width,
        .intensity_bit_width = intensity_bit_width,
        .intensity_log_scale_hi = intensity_scale_bits.high,
        .rt_min = rt_min,
        .rt_max = rt_max,
        .payload_bytes = @intCast(payload.items.len),
        .decompressed_bytes = @intCast(decompressed_bytes),
        .checksum = crc32.hash(payload.items),
    };

    var block: std.ArrayList(u8) = .empty;
    errdefer block.deinit(allocator);
    try writeHeader(&block, allocator, header);
    try block.appendSlice(allocator, payload.items);
    stats.payload_bytes = payload.items.len;

    return .{
        .bytes = try block.toOwnedSlice(allocator),
        .stats = stats,
    };
}

pub fn encodeBlock(allocator: Allocator, spectra: []const binary_reader.RawSpectrum, options: common.EncodeOptions) ![]u8 {
    var scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    const detailed = try encodeBlockDetailed(allocator, scratch_arena.allocator(), spectra, options);
    return detailed.bytes;
}
