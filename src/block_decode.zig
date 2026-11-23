//! Block decode and byte-breakdown inspection.
//! Scratch must be an arena: temps are not freed individually. Fail closed on truncation, checksum, and overflow.

const std = @import("std");
const builtin = @import("builtin");
const binary_reader = @import("binary_reader");
const quantize = @import("quantize");
const bitpack = @import("bitpack");
const rans = @import("rans");
const common = @import("block_common");
const crc32 = @import("crc32");

const Allocator = std.mem.Allocator;
const MzDomain = common.MzDomain;

fn decodeFlatMzOne(raw: u64, domain: MzDomain, scale_factor: u32) !f64 {
    if (domain == .lossless_f32 and raw > std.math.maxInt(u32)) return error.InvalidMz;
    const value: f64 = switch (domain) {
        .lossless_f32 => @as(f64, @as(f32, @bitCast(@as(u32, @truncate(raw))))),
        .lossless_f64 => @bitCast(raw),
        .lossy_fixed => return quantize.dequantizeMzValue(raw, scale_factor),
    };
    if (!std.math.isFinite(value) or value < 0.0) return error.InvalidMz;
    if (value == 0.0 and @as(u64, @bitCast(value)) != 0) return error.InvalidMz;
    return value;
}

fn validateRtBounds(values: []const f32, header: common.BlockHeader) !void {
    var rt_min = values[0];
    var rt_max = values[0];
    for (values) |value| {
        if (value < rt_min) rt_min = value;
        if (value > rt_max) rt_max = value;
    }
    if (@as(u32, @bitCast(rt_min)) != @as(u32, @bitCast(header.rt_min)) or
        @as(u32, @bitCast(rt_max)) != @as(u32, @bitCast(header.rt_max)))
    {
        return error.RtBoundsMismatch;
    }
}

fn copyF32Le(dst: []f32, src: []const u8) void {
    if (builtin.cpu.arch.endian() == .little) {
        @memcpy(std.mem.sliceAsBytes(dst), src);
        return;
    }
    for (dst, 0..) |*value, idx| {
        const start = idx * @sizeOf(f32);
        value.* = common.readF32Le(src[start .. start + @sizeOf(f32)]);
    }
}

fn countNonEmptySpectra(peak_counts: []const u32) usize {
    var n: usize = 0;
    for (peak_counts) |peak_count| {
        if (peak_count != 0) n += 1;
    }
    return n;
}

fn countDeltas(peak_counts: []const u32) !usize {
    var n: usize = 0;
    for (peak_counts) |peak_count| {
        if (peak_count == 0) continue;
        n = try std.math.add(usize, n, peak_count - 1);
    }
    return n;
}

fn countDeltaGroups(peak_counts: []const u32) usize {
    var n: usize = 0;
    for (peak_counts) |peak_count| {
        if (peak_count >= 2) n += 1;
    }
    return n;
}

/// Reads a scan-id or retention-time column as u32 values; retention times are their f32 bits.
fn readU32Column(scratch: Allocator, payload: []const u8, offset: *usize, out: []u32, delta: bool) !void {
    const len = try common.u32ColumnLen(payload, offset.*, out.len, delta);
    const column = payload[offset.*..][0..len];
    offset.* += len;
    if (!delta) {
        for (out, 0..) |*value, idx| value.* = common.readIntLe(u32, column[idx * @sizeOf(u32) ..]);
        return;
    }
    const deltas = try bitpack.unpackForU64(scratch, .{
        .base = common.readIntLe(u64, column[1..9]),
        .bit_width = column[0],
        .count = out.len,
        .payload = column[common.column_header_len..],
    });
    var running: u32 = 0;
    for (out, deltas) |*value, step| {
        if (step > std.math.maxInt(u32)) return error.Overflow;
        running = std.math.add(u32, running, @intCast(step)) catch return error.Overflow;
        value.* = running;
    }
}

/// The FOR bytes an m/z section stores, rANS-decoded when the block says so.
fn mzForBytes(scratch: Allocator, stored: []const u8, expected_len: usize, flags: u8) ![]const u8 {
    if ((flags & common.flag_rans_mz) == 0) {
        if (stored.len != expected_len) return error.InvalidMzPayload;
        return stored;
    }
    if (expected_len == 0) return error.InvalidMzPayload;
    if (stored.len > try rans.maxEncodedLen(expected_len)) return error.BlockResourceLimit;
    const decoded = try scratch.alloc(u8, expected_len);
    try rans.decodeInto(stored, decoded);
    return decoded;
}

/// The FOR bytes an intensity section stores, rANS-decoded when the block says so.
fn intensityForBytes(scratch: Allocator, stored: []const u8, expected_len: usize, flags: u8) ![]const u8 {
    if ((flags & common.flag_rans_intensity) != 0) {
        if (stored.len > try rans.maxEncodedLen(expected_len)) return error.BlockResourceLimit;
        return rans.decodeAlloc(scratch, stored, expected_len);
    }
    if (stored.len < expected_len) return error.UnexpectedEndOfStream;
    if (stored.len != expected_len) return error.InvalidIntensityPayload;
    return stored;
}

fn decodeExactF64Groups(
    spectra: []binary_reader.RawSpectrum,
    peak_counts: []const u32,
    body: []const u8,
    header_and_firsts: usize,
    base: u64,
    bit_width: u8,
    flags: u8,
    scratch: Allocator,
) !void {
    if (base != 0 or bit_width != 0) return error.InvalidMzPayload;
    if (body.len - header_and_firsts < @sizeOf(u32)) return error.UnexpectedEndOfStream;
    const group_count = common.readIntLe(u32, body[header_and_firsts..][0..@sizeOf(u32)]);
    if (group_count != countDeltaGroups(peak_counts)) return error.InvalidMzPayload;
    const group_metadata_bytes = try std.math.mul(
        usize,
        group_count,
        @sizeOf(u8) + @sizeOf(u64),
    );
    const group_metadata_offset = try std.math.add(usize, header_and_firsts, @sizeOf(u32));
    const payload_offset = try std.math.add(usize, group_metadata_offset, group_metadata_bytes);
    if (body.len < payload_offset) return error.UnexpectedEndOfStream;

    var expected_for_len: usize = 0;
    var group_cursor: usize = 0;
    for (peak_counts) |peak_count| {
        if (peak_count < 2) continue;
        const metadata_offset = group_metadata_offset +
            group_cursor * (@sizeOf(u8) + @sizeOf(u64));
        const width = body[metadata_offset];
        if (width > 64) return error.InvalidBitWidth;
        expected_for_len = try std.math.add(
            usize,
            expected_for_len,
            try common.packedByteLen(width, peak_count - 1),
        );
        group_cursor += 1;
    }
    std.debug.assert(group_cursor == group_count);

    const for_bytes = try mzForBytes(scratch, body[payload_offset..], expected_for_len, flags);

    var first_cursor: usize = 0;
    group_cursor = 0;
    var packed_cursor: usize = 0;
    for (spectra, peak_counts) |spectrum, peak_count| {
        if (peak_count == 0) continue;
        const first_offset = 5 + first_cursor * @sizeOf(u64);
        var previous = common.readIntLe(u64, body[first_offset..][0..@sizeOf(u64)]);
        spectrum.mz[0] = try decodeFlatMzOne(previous, .lossless_f64, 0);
        first_cursor += 1;
        if (peak_count == 1) continue;

        const metadata_offset = group_metadata_offset +
            group_cursor * (@sizeOf(u8) + @sizeOf(u64));
        const width = body[metadata_offset];
        const group_base = common.readIntLe(
            u64,
            body[metadata_offset + 1 ..][0..@sizeOf(u64)],
        );
        const group_len = try common.packedByteLen(width, peak_count - 1);
        try bitpack.validatePayload(
            for_bytes[packed_cursor .. packed_cursor + group_len],
            width,
            peak_count - 1,
        );
        var bit_offset = packed_cursor * 8;
        var peak_index: usize = 1;
        while (peak_index < peak_count) : (peak_index += 1) {
            const delta = try bitpack.unpackNextForValue(
                for_bytes,
                width,
                &bit_offset,
                group_base,
            );
            previous = try std.math.add(u64, previous, delta);
            spectrum.mz[peak_index] = try decodeFlatMzOne(previous, .lossless_f64, 0);
        }
        packed_cursor += group_len;
        group_cursor += 1;
    }
    if (first_cursor != countNonEmptySpectra(peak_counts) or
        group_cursor != group_count or packed_cursor != for_bytes.len)
    {
        return error.InvalidMzPayload;
    }
}

fn decodeMzFirstPeakSplit(
    spectra: []binary_reader.RawSpectrum,
    peak_counts: []const u32,
    body: []const u8,
    bit_width: u8,
    base: u64,
    domain: MzDomain,
    scale_factor: u32,
    flags: u8,
    scratch: Allocator,
) !void {
    if (bit_width > 64) return error.InvalidBitWidth;
    if (body.len < 5) return error.UnexpectedEndOfStream;

    const first_count = common.readIntLe(u32, body[0..4]);
    const first_size = body[4];
    if (first_size != 4 and first_size != 8) return error.InvalidFirstSize;
    if (domain == .lossless_f32 and first_size != 4) return error.InvalidFirstSize;
    if (domain != .lossless_f32 and first_size != 8) return error.InvalidFirstSize;
    if (first_count != countNonEmptySpectra(peak_counts)) return error.InvalidFirstCount;

    const first_bytes = try std.math.mul(usize, first_count, first_size);
    const header_and_firsts = try std.math.add(usize, 5, first_bytes);
    if (body.len < header_and_firsts) return error.UnexpectedEndOfStream;

    if (domain == .lossless_f64) {
        return decodeExactF64Groups(
            spectra,
            peak_counts,
            body,
            header_and_firsts,
            base,
            bit_width,
            flags,
            scratch,
        );
    }

    const delta_count = try countDeltas(peak_counts);
    const delta_payload = body[header_and_firsts..];

    if (delta_count == 0) {
        if ((flags & common.flag_rans_mz) != 0) return error.InvalidMzPayload;
        if (bit_width != 0) return error.InvalidMzPayload;
        if (base != 0) return error.InvalidMzPayload;
        if (delta_payload.len != 0) return error.TrailingBlockPayload;
    }

    const expected_for_len = try common.packedByteLen(bit_width, delta_count);
    const for_bytes = try mzForBytes(scratch, delta_payload, expected_for_len, flags);
    try bitpack.validatePayload(for_bytes, bit_width, delta_count);

    var bit_offset: usize = 0;
    var first_cursor: usize = 0;
    for (spectra, peak_counts) |spectrum, peak_count| {
        if (peak_count == 0) continue;

        const first_off = try std.math.add(usize, 5, try std.math.mul(usize, first_cursor, first_size));
        const first_raw: u64 = if (first_size == 4)
            common.readIntLe(u32, body[first_off .. first_off + 4])
        else
            common.readIntLe(u64, body[first_off .. first_off + 8]);
        first_cursor += 1;

        spectrum.mz[0] = try decodeFlatMzOne(first_raw, domain, scale_factor);
        var previous = first_raw;

        var i: usize = 1;
        while (i < peak_count) : (i += 1) {
            const delta = try bitpack.unpackNextForValue(for_bytes, bit_width, &bit_offset, base);
            const sum = @addWithOverflow(previous, delta);
            if (sum[1] != 0) return error.Overflow;
            spectrum.mz[i] = try decodeFlatMzOne(sum[0], domain, scale_factor);
            previous = sum[0];
        }
    }
}

pub fn verifyBlockChecksum(block_bytes: []const u8) !void {
    const block = try common.parseBlock(block_bytes);
    if (crc32.hash(block.payload) != block.header.checksum) return error.ChecksumMismatch;
}

pub fn decodeBlock(allocator: Allocator, block_bytes: []const u8) ![]binary_reader.RawSpectrum {
    var scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    return decodeBlockWithScratch(allocator, scratch_arena.allocator(), block_bytes);
}

/// `scratch` must be an arena. Temps are not freed individually; reset or deinit the arena.
pub fn decodeBlockWithScratch(allocator: Allocator, scratch: Allocator, block_bytes: []const u8) ![]binary_reader.RawSpectrum {
    const block = try common.parseBlock(block_bytes);
    const header = block.header;
    const payload = block.payload;
    if (crc32.hash(payload) != header.checksum) return error.ChecksumMismatch;

    const tmp = scratch;
    const spectrum_count = header.spectrum_count;
    const total_peaks: usize = header.total_peaks;
    var offset: usize = 0;

    const scan_ids = try allocator.alloc(u32, spectrum_count);
    defer allocator.free(scan_ids);
    try readU32Column(tmp, payload, &offset, scan_ids, (header.flags & common.flag_delta_scan_id) != 0);

    const rt_bits = try allocator.alloc(u32, spectrum_count);
    defer allocator.free(rt_bits);
    try readU32Column(tmp, payload, &offset, rt_bits, (header.flags & common.flag_delta_rt) != 0);
    const rt_values: []const f32 = @ptrCast(rt_bits);
    try validateRtBounds(rt_values, header);

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
        computed_total_peaks = try std.math.add(usize, computed_total_peaks, value.*);
    }
    if (computed_total_peaks != total_peaks) return error.InvalidPeakCount;

    const spectra = try allocator.alloc(binary_reader.RawSpectrum, spectrum_count);
    var initialized: usize = 0;
    errdefer {
        for (spectra[0..initialized]) |spectrum| {
            allocator.free(spectrum.mz);
            allocator.free(spectrum.intensity);
        }
        allocator.free(spectra);
    }
    for (spectra, 0..) |*spectrum, idx| {
        const peak_count = peak_counts[idx];
        spectrum.* = blk: {
            const mz = try allocator.alloc(f64, peak_count);
            errdefer allocator.free(mz);
            const intensity = try allocator.alloc(f32, peak_count);
            errdefer allocator.free(intensity);
            break :blk .{
                .scan_id = scan_ids[idx],
                .rt_seconds = rt_values[idx],
                .ms_level = header.ms_level,
                .precursor_mz = precursor_values[idx],
                .mz = mz,
                .intensity = intensity,
            };
        };
        initialized += 1;
    }

    {
        if (payload.len - offset < 12) return error.UnexpectedEndOfStream;
        const mz_base = common.readIntLe(u64, payload[offset .. offset + 8]);
        offset += 8;
        const mz_payload_len = common.readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;

        if (payload.len - offset < mz_payload_len) return error.UnexpectedEndOfStream;
        try decodeMzFirstPeakSplit(
            spectra,
            peak_counts,
            payload[offset .. offset + mz_payload_len],
            header.mz_bit_width,
            mz_base,
            MzDomain.fromFlags(header.flags),
            header.mz_scale_factor,
            header.flags,
            tmp,
        );
        offset += mz_payload_len;
    }

    const intensity_raw_bytes = try std.math.mul(usize, total_peaks, @sizeOf(f32));
    const rans_intensity = (header.flags & common.flag_rans_intensity) != 0;

    if ((header.flags & common.flag_lossless_intensity_raw) != 0) {
        var stored_len = intensity_raw_bytes;
        if (rans_intensity) {
            if (payload.len - offset < 4) return error.UnexpectedEndOfStream;
            stored_len = common.readIntLe(u32, payload[offset .. offset + 4]);
            offset += 4;
            if (stored_len > try rans.maxEncodedLen(intensity_raw_bytes)) return error.BlockResourceLimit;
        }
        if (payload.len - offset < stored_len) return error.UnexpectedEndOfStream;
        const stored = payload[offset .. offset + stored_len];
        const raw = if (rans_intensity) try rans.decodeAlloc(tmp, stored, intensity_raw_bytes) else stored;
        var intensity_offset: usize = 0;
        for (spectra) |spectrum| {
            const next = intensity_offset + spectrum.intensity.len * @sizeOf(f32);
            copyF32Le(spectrum.intensity, raw[intensity_offset..next]);
            intensity_offset = next;
        }
        offset += stored_len;
    } else if ((header.flags & common.flag_split_exponent) != 0) {
        if (payload.len - offset < 13) return error.UnexpectedEndOfStream;
        const exp_bit_width = payload[offset];
        offset += 1;
        const exp_base = common.readIntLe(u64, payload[offset .. offset + 8]);
        offset += 8;
        const exp_payload_len = common.readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        if (payload.len - offset < exp_payload_len) return error.UnexpectedEndOfStream;

        if (exp_bit_width != header.intensity_bit_width or exp_bit_width > 8) {
            return error.InvalidBitWidth;
        }
        if (exp_base > std.math.maxInt(u8)) return error.IntensityOverflow;
        const expected_exp_len = try common.packedByteLen(exp_bit_width, total_peaks);
        const exp_payload_bytes = try intensityForBytes(tmp, payload[offset .. offset + exp_payload_len], expected_exp_len, header.flags);

        const exp_unpacked = try bitpack.unpackForU64(tmp, .{
            .base = exp_base,
            .bit_width = exp_bit_width,
            .count = total_peaks,
            .payload = exp_payload_bytes,
        });
        offset += exp_payload_len;
        const mantissa_len = try std.math.mul(usize, total_peaks, 3);
        if (payload.len - offset < mantissa_len) return error.UnexpectedEndOfStream;
        var intensity_index: usize = 0;
        for (spectra) |spectrum| {
            for (spectrum.intensity) |*value| {
                const b0 = payload[offset + intensity_index * 3];
                const b1 = payload[offset + intensity_index * 3 + 1];
                const b2 = payload[offset + intensity_index * 3 + 2];
                if (exp_unpacked[intensity_index] > std.math.maxInt(u8)) {
                    return error.IntensityOverflow;
                }
                const exp_byte: u8 = @intCast(exp_unpacked[intensity_index]);
                const bits: u32 = (@as(u32, exp_byte) << 24) |
                    (@as(u32, b2) << 16) | (@as(u32, b1) << 8) | b0;
                value.* = @bitCast(bits);
                intensity_index += 1;
            }
        }
        offset += mantissa_len;
    } else {
        if (payload.len - offset < 6) return error.UnexpectedEndOfStream;
        const intensity_base = common.readIntLe(u16, payload[offset .. offset + 2]);
        offset += 2;
        const intensity_payload_len = common.readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        if (payload.len - offset < intensity_payload_len) return error.UnexpectedEndOfStream;

        const expected_intensity_len = try common.packedByteLen(header.intensity_bit_width, total_peaks);
        const intensity_payload_bytes = try intensityForBytes(tmp, payload[offset .. offset + intensity_payload_len], expected_intensity_len, header.flags);

        const unpacked = try bitpack.unpackForU64(tmp, .{
            .base = intensity_base,
            .bit_width = header.intensity_bit_width,
            .count = total_peaks,
            .payload = intensity_payload_bytes,
        });
        offset += intensity_payload_len;

        const intensity_log_scale = common.decodeIntensityLogScale(header);
        // Every peak at one level decodes to the same value, so expm1 runs once per level used.
        // An all-ones slot is unset: it is a NaN, which dequantization never returns.
        const unset_level: u32 = 0xFFFF_FFFF;
        const levels = try tmp.alloc(u32, @as(usize, header.intensity_quant) + 1);
        @memset(levels, unset_level);
        var intensity_index: usize = 0;
        for (spectra) |spectrum| {
            for (spectrum.intensity) |*intensity| {
                const value = unpacked[intensity_index];
                if (value > header.intensity_quant) return error.IntensityOverflow;
                const slot = &levels[@intCast(value)];
                if (slot.* == unset_level) {
                    slot.* = @bitCast(try quantize.dequantizeIntensityValueScaled(@intCast(value), header.intensity_quant, intensity_log_scale));
                }
                intensity.* = @bitCast(slot.*);
                intensity_index += 1;
            }
        }
    }

    if (offset != payload.len) return error.TrailingBlockPayload;

    return spectra;
}

/// Checks a stored section length against its FOR length: a rANS stream must hold at least its
/// header and stay within `rans.maxEncodedLen`; a plain section must match exactly.
fn checkStoredLen(section: enum { mz, intensity }, stored_len: usize, expected_len: usize, rans_coded: bool) !void {
    if (rans_coded) {
        if (expected_len == 0) return if (section == .mz) error.InvalidMzPayload else error.InvalidBlockFlags;
        if (stored_len < rans.encoded_header_bytes) return error.UnexpectedEndOfStream;
        if (stored_len > try rans.maxEncodedLen(expected_len)) return error.BlockResourceLimit;
    } else {
        if (stored_len < expected_len) return error.UnexpectedEndOfStream;
        if (stored_len != expected_len) return if (section == .mz) error.InvalidMzPayload else error.InvalidIntensityPayload;
    }
}

pub fn inspectBlockByteBreakdown(block_bytes: []const u8) !common.BlockByteBreakdown {
    const block = try common.parseBlock(block_bytes);
    const header = block.header;
    const payload = block.payload;
    const spectrum_count: usize = header.spectrum_count;
    const total_peaks: usize = header.total_peaks;
    const rans_intensity = (header.flags & common.flag_rans_intensity) != 0;

    var offset: usize = 0;
    const scan_id_bytes = try common.u32ColumnLen(payload, offset, spectrum_count, (header.flags & common.flag_delta_scan_id) != 0);
    offset += scan_id_bytes;
    const rt_bytes = try common.u32ColumnLen(payload, offset, spectrum_count, (header.flags & common.flag_delta_rt) != 0);
    offset += rt_bytes;

    const precursor_bytes = spectrum_count * @sizeOf(f64);
    const peak_count_bytes = spectrum_count * @sizeOf(u32);
    if (payload.len - offset < precursor_bytes + peak_count_bytes) return error.UnexpectedEndOfStream;

    var peak_count_storage: [common.MAX_BLOCK_SPECTRA]u32 = undefined;
    const peak_counts = peak_count_storage[0..spectrum_count];
    var computed_total_peaks: usize = 0;
    for (0..spectrum_count) |idx| {
        const start = offset + precursor_bytes + (idx * @sizeOf(u32));
        const peak_count = common.readIntLe(u32, payload[start .. start + @sizeOf(u32)]);
        peak_counts[idx] = peak_count;
        computed_total_peaks = try std.math.add(usize, computed_total_peaks, peak_count);
    }
    if (computed_total_peaks != total_peaks) return error.InvalidPeakCount;
    offset += precursor_bytes + peak_count_bytes;

    const mz_metadata_bytes = @sizeOf(u64) + @sizeOf(u32);
    if (payload.len - offset < mz_metadata_bytes) return error.UnexpectedEndOfStream;
    const mz_base = common.readIntLe(u64, payload[offset .. offset + @sizeOf(u64)]);
    offset += @sizeOf(u64);
    const mz_payload_bytes = common.readIntLe(u32, payload[offset .. offset + @sizeOf(u32)]);
    offset += @sizeOf(u32);
    if (payload.len - offset < mz_payload_bytes) return error.UnexpectedEndOfStream;
    const mz_body = payload[offset .. offset + mz_payload_bytes];
    if (mz_body.len < 5) return error.UnexpectedEndOfStream;
    const first_count = common.readIntLe(u32, mz_body[0..4]);
    const first_size = mz_body[4];
    const exact_f32 = (header.flags & common.flag_lossless_mz_f32) != 0;
    if (first_size != (if (exact_f32) @as(u8, 4) else @as(u8, 8))) {
        return error.InvalidFirstSize;
    }
    if (first_count != countNonEmptySpectra(peak_counts)) return error.InvalidFirstCount;
    const first_bytes = try std.math.mul(usize, first_count, first_size);
    var mz_stored_offset = try std.math.add(usize, 5, first_bytes);
    if (mz_body.len < mz_stored_offset) return error.UnexpectedEndOfStream;

    var expected_mz_for_len: usize = 0;
    if ((header.flags & common.flag_lossless_mz_f64) != 0) {
        if (mz_base != 0 or header.mz_bit_width != 0) return error.InvalidMzPayload;
        if (mz_body.len - mz_stored_offset < @sizeOf(u32)) return error.UnexpectedEndOfStream;
        const group_count = common.readIntLe(u32, mz_body[mz_stored_offset..][0..4]);
        if (group_count != countDeltaGroups(peak_counts)) return error.InvalidMzPayload;
        mz_stored_offset += @sizeOf(u32);
        const group_metadata_len = try std.math.mul(usize, group_count, 9);
        if (mz_body.len - mz_stored_offset < group_metadata_len) return error.UnexpectedEndOfStream;
        var group_index: usize = 0;
        for (peak_counts) |peak_count| {
            if (peak_count < 2) continue;
            const width = mz_body[mz_stored_offset + group_index * 9];
            if (width > 64) return error.InvalidBitWidth;
            expected_mz_for_len = try std.math.add(
                usize,
                expected_mz_for_len,
                try common.packedByteLen(width, peak_count - 1),
            );
            group_index += 1;
        }
        mz_stored_offset += group_metadata_len;
    } else {
        const delta_count = try countDeltas(peak_counts);
        expected_mz_for_len = try common.packedByteLen(header.mz_bit_width, delta_count);
        if (delta_count == 0 and (mz_base != 0 or header.mz_bit_width != 0)) {
            return error.InvalidMzPayload;
        }
    }
    try checkStoredLen(.mz, mz_body.len - mz_stored_offset, expected_mz_for_len, (header.flags & common.flag_rans_mz) != 0);
    offset += mz_payload_bytes;

    var intensity_metadata_bytes: usize = 0;
    var intensity_payload_bytes: usize = 0;
    if ((header.flags & common.flag_lossless_intensity_raw) != 0) {
        const raw_bytes = try std.math.mul(usize, total_peaks, @sizeOf(f32));
        intensity_payload_bytes = raw_bytes;
        if (rans_intensity) {
            intensity_metadata_bytes = @sizeOf(u32);
            if (payload.len - offset < intensity_metadata_bytes) return error.UnexpectedEndOfStream;
            intensity_payload_bytes = common.readIntLe(u32, payload[offset .. offset + @sizeOf(u32)]);
            offset += @sizeOf(u32);
            try checkStoredLen(.intensity, intensity_payload_bytes, raw_bytes, true);
        }
        if (payload.len - offset < intensity_payload_bytes) return error.UnexpectedEndOfStream;
        offset += intensity_payload_bytes;
    } else if ((header.flags & common.flag_split_exponent) != 0) {
        if (payload.len - offset < 13) return error.UnexpectedEndOfStream;
        const width = payload[offset];
        if (width != header.intensity_bit_width or width > 8) return error.InvalidBitWidth;
        offset += 1;
        const base = common.readIntLe(u64, payload[offset .. offset + 8]);
        if (base > std.math.maxInt(u8)) return error.IntensityOverflow;
        offset += 8;
        const exp_packed_len = common.readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        const expected_len = try common.packedByteLen(width, total_peaks);
        try checkStoredLen(.intensity, exp_packed_len, expected_len, rans_intensity);
        if (payload.len - offset < exp_packed_len) return error.UnexpectedEndOfStream;
        offset += exp_packed_len;
        const mantissa_len = try std.math.mul(usize, total_peaks, 3);
        if (payload.len - offset < mantissa_len) return error.UnexpectedEndOfStream;
        offset += mantissa_len;
        intensity_metadata_bytes = 1 + 8 + 4;
        intensity_payload_bytes = exp_packed_len + mantissa_len;
    } else {
        intensity_metadata_bytes = @sizeOf(u16) + @sizeOf(u32);
        if (payload.len - offset < intensity_metadata_bytes) return error.UnexpectedEndOfStream;
        const base = common.readIntLe(u16, payload[offset .. offset + @sizeOf(u16)]);
        if (base > header.intensity_quant) return error.IntensityOverflow;
        offset += @sizeOf(u16);
        intensity_payload_bytes = common.readIntLe(u32, payload[offset .. offset + @sizeOf(u32)]);
        offset += @sizeOf(u32);
        const expected_len = try common.packedByteLen(header.intensity_bit_width, total_peaks);
        try checkStoredLen(.intensity, intensity_payload_bytes, expected_len, rans_intensity);
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
