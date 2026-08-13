//! Block encode: metadata, first-peak-split m/z, and lossless or lossy intensity.
//! Scratch must be an arena: temps are not freed individually.

const std = @import("std");
const builtin = @import("builtin");
const binary_reader = @import("binary_reader");
const quantize = @import("quantize");
const bitpack = @import("bitpack");
const common = @import("block_common");
const crc32 = @import("crc32");

const Allocator = std.mem.Allocator;

const MzFirstPeakSplit = struct {
    firsts: []u64,
    deltas: []u64,
};

const MzPackedDeltas = struct {
    base: u64,
    bit_width: u8,
    payload: []const u8,
    group_bases: []const u64,
    group_widths: []const u8,
};

const MzDomain = enum {
    lossy_fixed,
    lossless_f32,
    lossless_f64,
};

fn validateLosslessMz(value: f64) !void {
    if (!std.math.isFinite(value) or value < 0.0) return error.InvalidMz;
    if (value == 0.0 and @as(u64, @bitCast(value)) != 0) return error.InvalidMz;
}

fn mzDomainValue(value: f64, domain: MzDomain, scale_factor: u32) !u64 {
    switch (domain) {
        .lossless_f32 => {
            try validateLosslessMz(value);
            const as_f32: f32 = @floatCast(value);
            return @as(u32, @bitCast(as_f32));
        },
        .lossless_f64 => {
            try validateLosslessMz(value);
            return @bitCast(value);
        },
        .lossy_fixed => {},
    }
    return try quantize.quantizeMzValue(value, scale_factor);
}

fn flattenMzFirstPeakSplit(
    allocator: Allocator,
    spectra: []const binary_reader.RawSpectrum,
    domain: MzDomain,
    scale_factor: u32,
) !MzFirstPeakSplit {
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
        var previous = try mzDomainValue(spectrum.mz[0], domain, scale_factor);
        firsts[fi] = previous;
        fi += 1;
        for (spectrum.mz[1..]) |value| {
            const cur = try mzDomainValue(value, domain, scale_factor);
            if (cur < previous) return error.NonMonotonicInput;
            deltas[di] = cur - previous;
            previous = cur;
            di += 1;
        }
    }
    if (fi != first_count or di != delta_count) return error.InternalCountMismatch;
    return .{ .firsts = firsts, .deltas = deltas };
}

fn packMzPerSpectrum(
    allocator: Allocator,
    spectra: []const binary_reader.RawSpectrum,
    deltas: []const u64,
) !MzPackedDeltas {
    var group_count: usize = 0;
    for (spectra) |spectrum| {
        if (spectrum.mz.len >= 2) group_count += 1;
    }
    const bases = try allocator.alloc(u64, group_count);
    const widths = try allocator.alloc(u8, group_count);

    var delta_cursor: usize = 0;
    var group_cursor: usize = 0;
    var payload_len: usize = 0;
    for (spectra) |spectrum| {
        const count = spectrum.mz.len -| 1;
        if (count == 0) continue;
        const values = deltas[delta_cursor .. delta_cursor + count];
        var min_value = values[0];
        var max_value = values[0];
        for (values[1..]) |value| {
            min_value = @min(min_value, value);
            max_value = @max(max_value, value);
        }
        bases[group_cursor] = min_value;
        widths[group_cursor] = bitpack.requiredBitWidth(max_value - min_value);
        payload_len = try std.math.add(
            usize,
            payload_len,
            try bitpack.packedByteLen(widths[group_cursor], count),
        );
        delta_cursor += count;
        group_cursor += 1;
    }
    std.debug.assert(delta_cursor == deltas.len);
    std.debug.assert(group_cursor == group_count);

    const payload = try allocator.alloc(u8, payload_len);
    @memset(payload, 0);
    delta_cursor = 0;
    group_cursor = 0;
    var payload_cursor: usize = 0;
    for (spectra) |spectrum| {
        const count = spectrum.mz.len -| 1;
        if (count == 0) continue;
        const group_len = try bitpack.packedByteLen(widths[group_cursor], count);
        var bit_offset: usize = 0;
        for (deltas[delta_cursor .. delta_cursor + count]) |value| {
            bitpack.packNextForValue(
                payload[payload_cursor .. payload_cursor + group_len],
                widths[group_cursor],
                &bit_offset,
                bases[group_cursor],
                value,
            );
        }
        delta_cursor += count;
        payload_cursor += group_len;
        group_cursor += 1;
    }
    std.debug.assert(delta_cursor == deltas.len);
    std.debug.assert(payload_cursor == payload.len);
    return .{
        .base = 0,
        .bit_width = 0,
        .payload = payload,
        .group_bases = bases,
        .group_widths = widths,
    };
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
    const domain: MzDomain = if (options.mode == .lossy)
        .lossy_fixed
    else if (common.allMzExactlyF32(spectra))
        .lossless_f32
    else
        .lossless_f64;
    switch (domain) {
        .lossless_f32 => flags.* |= common.flag_lossless_mz_f32,
        .lossless_f64 => flags.* |= common.flag_lossless_mz_f64,
        .lossy_fixed => {},
    }
    mz_scale_for_header.* = if (domain == .lossy_fixed) options.mz_scale_factor else 0;

    const split = try flattenMzFirstPeakSplit(tmp, spectra, domain, mz_scale_for_header.*);
    const first_size: u8 = if (domain == .lossless_f32) 4 else 8;
    const first_bytes = try std.math.mul(usize, split.firsts.len, first_size);

    const packed_deltas: MzPackedDeltas = if (domain == .lossless_f64)
        try packMzPerSpectrum(tmp, spectra, split.deltas)
    else blk: {
        const packed_values = try bitpack.packForU64(tmp, split.deltas);
        break :blk .{
            .base = packed_values.base,
            .bit_width = packed_values.bit_width,
            .payload = packed_values.payload,
            .group_bases = &.{},
            .group_widths = &.{},
        };
    };
    const group_metadata_bytes = if (domain == .lossless_f64)
        try std.math.add(
            usize,
            @sizeOf(u32),
            try std.math.mul(
                usize,
                packed_deltas.group_bases.len,
                @sizeOf(u64) + @sizeOf(u8),
            ),
        )
    else
        0;
    const delta_candidate = try common.maybeEncodeRansAlloc(tmp, packed_deltas.payload, options.mz_rans_min_gain_percent);
    const delta_stored = delta_candidate.storedBytes();
    const body_metadata = try std.math.add(
        usize,
        try std.math.add(usize, 5, first_bytes),
        group_metadata_bytes,
    );
    const body_len = try std.math.add(usize, body_metadata, delta_stored);
    if (body_len > std.math.maxInt(u32)) return error.BlockTooLarge;

    mz_bit_width.* = packed_deltas.bit_width;
    stats.mz_raw_bytes = try std.math.add(
        usize,
        first_bytes,
        try std.math.add(usize, group_metadata_bytes, packed_deltas.payload.len),
    );
    stats.mz_stored_bytes = body_len;
    stats.mz_rans_used = delta_candidate.used();
    stats.mz_estimated_rans_bytes = if (delta_candidate.estimated_total_bytes == 0)
        body_len
    else
        try std.math.add(usize, body_metadata, delta_candidate.estimated_total_bytes);

    try common.appendIntLe(payload, tmp, u64, packed_deltas.base);
    try common.appendIntLe(payload, tmp, u32, @intCast(body_len));
    if (split.firsts.len > std.math.maxInt(u32)) return error.TooManySpectra;
    try common.appendIntLe(payload, tmp, u32, @intCast(split.firsts.len));
    try payload.append(tmp, first_size);
    if (domain == .lossless_f32) {
        for (split.firsts) |first| {
            if (first > std.math.maxInt(u32)) return error.Overflow;
            try common.appendIntLe(payload, tmp, u32, @intCast(first));
        }
    } else {
        for (split.firsts) |first| try common.appendIntLe(payload, tmp, u64, first);
    }
    if (domain == .lossless_f64) {
        try common.appendIntLe(payload, tmp, u32, @intCast(packed_deltas.group_bases.len));
        for (packed_deltas.group_bases, packed_deltas.group_widths) |base, width| {
            try payload.append(tmp, width);
            try common.appendIntLe(payload, tmp, u64, base);
        }
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
        const cur_bits: u32 = @bitCast(spectrum.rt_seconds);
        const prev_bits: u32 = @bitCast(spectra[idx - 1].rt_seconds);
        if (cur_bits < prev_bits) return error.NonMonotonicRt;
        result[idx] = cur_bits - prev_bits;
    }
    return result;
}

fn flattenIntensityLossyToU16(
    allocator: Allocator,
    spectra: []const binary_reader.RawSpectrum,
    quant_factor: u16,
    log_max: f32,
) ![]u16 {
    const total_peaks = try common.totalPeakCount(spectra);
    const flat = try allocator.alloc(u16, total_peaks);

    var offset: usize = 0;
    for (spectra) |spectrum| {
        for (spectrum.intensity) |value| {
            flat[offset] = try quantize.quantizeIntensityValueScaled(value, quant_factor, log_max);
            offset += 1;
        }
    }

    return flat;
}

fn intensityExponent(value: f32) u8 {
    return @truncate(@as(u32, @bitCast(value)) >> 24);
}

fn packIntensityExponents(
    allocator: Allocator,
    spectra: []const binary_reader.RawSpectrum,
    total_peaks: usize,
) !bitpack.PackedU64 {
    if (total_peaks == 0) return bitpack.packForU64(allocator, &.{});

    var base: u8 = std.math.maxInt(u8);
    var max_value: u8 = 0;
    for (spectra) |spectrum| {
        for (spectrum.intensity) |value| {
            const exponent = intensityExponent(value);
            base = @min(base, exponent);
            max_value = @max(max_value, exponent);
        }
    }

    const bit_width = bitpack.requiredBitWidth(@as(u64, max_value) - base);
    const payload_len = try bitpack.packedByteLen(bit_width, total_peaks);
    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    @memset(payload, 0);

    var bit_offset: usize = 0;
    for (spectra) |spectrum| {
        for (spectrum.intensity) |value| {
            bitpack.packNextForValue(payload, bit_width, &bit_offset, base, intensityExponent(value));
        }
    }
    std.debug.assert(bit_offset == @as(usize, bit_width) * total_peaks);

    return .{
        .base = base,
        .bit_width = bit_width,
        .count = total_peaks,
        .payload = payload,
    };
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
    if (options.mode == .lossy and options.mz_scale_factor == 0) {
        return error.InvalidScaleFactor;
    }
    if (options.mode == .lossy and options.intensity_quant == 0) {
        return error.InvalidQuantFactor;
    }

    const tmp = scratch;

    const ms_level = spectra[0].ms_level;
    if (ms_level != 1 and ms_level != 2) return error.UnsupportedMsLevel;
    var rt_min = spectra[0].rt_seconds;
    var rt_max = spectra[0].rt_seconds;
    for (spectra) |spectrum| {
        if (spectrum.ms_level != ms_level) return error.MixedMsLevel;
        if (spectrum.rt_seconds < rt_min) rt_min = spectrum.rt_seconds;
        if (spectrum.rt_seconds > rt_max) rt_max = spectrum.rt_seconds;
    }

    const total_peaks = try common.totalPeakCount(spectra);
    try common.validateBlockCounts(spectra.len, total_peaks);

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
        const packed_exp = try packIntensityExponents(tmp, spectra, total_peaks);
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
        const quantized_intensity = try flattenIntensityLossyToU16(
            tmp,
            spectra,
            options.intensity_quant,
            intensity_log_scale,
        );

        const packed_intensity = try bitpack.packForU16(tmp, quantized_intensity);

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

    const decompressed_bytes = try common.logicalBlockBytes(spectra.len, total_peaks);
    const payload_limit = try common.maxBlockPayloadBytes(spectra.len, total_peaks);
    if (payload.items.len > payload_limit or payload.items.len > std.math.maxInt(u32) or
        decompressed_bytes > std.math.maxInt(u32)) return error.BlockResourceLimit;

    const intensity_scale_bits = common.encodeIntensityLogScale(intensity_log_scale);

    const header: common.BlockHeader = .{
        .spectrum_count = @intCast(spectra.len),
        .ms_level = ms_level,
        .flags = flags,
        .total_peaks = @intCast(total_peaks),
        .mz_scale_factor = mz_scale_for_header,
        .intensity_quant = if (options.mode == .lossy) options.intensity_quant else 0,
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
