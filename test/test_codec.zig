const std = @import("std");
const binary_reader = @import("binary_reader");
const block = @import("block");
const codec = @import("codec");
const quantize = @import("quantize");

/// Assert every decoded m/z is within 0.001 ppm of the original.
fn checkMzPpm(expected_mz: []const f64, actual_mz: []const f64) !void {
    try std.testing.expectEqual(expected_mz.len, actual_mz.len);
    for (expected_mz, actual_mz) |exp, act| {
        const ppm_error = if (exp == 0.0) @abs(act) else @abs(act - exp) / @abs(exp) * 1e6;
        if (ppm_error > 0.001) {
            std.debug.print("m/z PPM error {d:.6} > 0.001 ppm at expected={d}, actual={d}\n", .{ ppm_error, exp, act });
            return error.TestExpectedEqual;
        }
    }
}

/// Lossless round-trip check: all fields exact, m/z within 0.001 ppm.
fn expectLosslessRoundTrip(expected: []const binary_reader.RawSpectrum, actual: []const binary_reader.RawSpectrum) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |exp, act| {
        try std.testing.expectEqual(exp.scan_id, act.scan_id);
        try std.testing.expectEqual(exp.rt_seconds, act.rt_seconds);
        try std.testing.expectEqual(exp.ms_level, act.ms_level);
        try std.testing.expectEqual(exp.precursor_mz, act.precursor_mz);
        try checkMzPpm(exp.mz, act.mz);
        try std.testing.expectEqualSlices(f32, exp.intensity, act.intensity);
    }
}

const SyntheticCorpus = struct {
    allocator: std.mem.Allocator,
    spectra: []binary_reader.RawSpectrum,

    fn deinit(self: SyntheticCorpus) void {
        binary_reader.freeSpectra(self.allocator, self.spectra);
    }
};

fn expectByteBreakdownSums(inspection: codec.Inspection, encoded_len: usize) !void {
    const bytes = inspection.byte_breakdown;
    const computed_total = bytes.file_header_bytes + bytes.global_order_bytes + bytes.block_header_bytes + bytes.scan_id_bytes + bytes.rt_bytes + bytes.precursor_bytes + bytes.peak_count_bytes + bytes.mz_metadata_bytes + bytes.mz_payload_bytes + bytes.intensity_metadata_bytes + bytes.intensity_payload_bytes;

    try std.testing.expectEqual(encoded_len, bytes.total_bytes);
    try std.testing.expectEqual(encoded_len, computed_total);

    var summed_block_bytes: usize = 0;
    for (inspection.blocks) |block_info| {
        const block_bytes = block_info.byte_breakdown;
        try std.testing.expectEqual(block_info.total_bytes, block_bytes.total_bytes);
        try std.testing.expectEqual(@as(usize, block_info.header.payload_bytes), block_bytes.scan_id_bytes + block_bytes.rt_bytes + block_bytes.precursor_bytes + block_bytes.peak_count_bytes + block_bytes.mz_metadata_bytes + block_bytes.mz_payload_bytes + block_bytes.intensity_metadata_bytes + block_bytes.intensity_payload_bytes);
        summed_block_bytes += block_bytes.total_bytes;
    }

    try std.testing.expectEqual(encoded_len, bytes.file_header_bytes + bytes.global_order_bytes + summed_block_bytes);
}

fn makeSyntheticCorpus(allocator: std.mem.Allocator, spectrum_count: usize) !SyntheticCorpus {
    const spectra = try allocator.alloc(binary_reader.RawSpectrum, spectrum_count);

    var initialized: usize = 0;
    errdefer {
        for (spectra[0..initialized]) |spectrum| {
            allocator.free(spectrum.mz);
            allocator.free(spectrum.intensity);
        }
        allocator.free(spectra);
    }

    for (0..spectrum_count) |idx| {
        const peak_count: usize = if (idx % 5 == 0) 0 else (idx % 4) + 1;
        const mz = try allocator.alloc(f64, peak_count);
        errdefer allocator.free(mz);
        const intensity = try allocator.alloc(f32, peak_count);
        errdefer allocator.free(intensity);

        const base_mz = 100.0 + @as(f64, @floatFromInt(idx * 17));
        for (0..peak_count) |peak_idx| {
            mz[peak_idx] = base_mz + (@as(f64, @floatFromInt(peak_idx)) * 0.125) + (@as(f64, @floatFromInt((idx + peak_idx) % 7)) * 0.00000125);
            intensity[peak_idx] = @floatFromInt(((idx + 1) * (peak_idx + 1) * 11) % 1000);
            if (intensity[peak_idx] == 0.0) intensity[peak_idx] = 0.5;
        }

        spectra[idx] = .{
            .scan_id = @intCast(1000 + idx),
            .rt_seconds = 1.5 + @as(f32, @floatFromInt(idx)) * 0.2,
            .ms_level = if (idx % 2 == 0) 2 else 1,
            .precursor_mz = if (idx % 2 == 0) 400.0 + @as(f64, @floatFromInt(idx)) else 0.0,
            .mz = mz,
            .intensity = intensity,
        };
        initialized += 1;
    }

    return .{ .allocator = allocator, .spectra = spectra };
}

fn makePseudoRandomCorpus(allocator: std.mem.Allocator, seed: u64, spectrum_count: usize, max_peaks: usize) !SyntheticCorpus {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const spectra = try allocator.alloc(binary_reader.RawSpectrum, spectrum_count);

    var initialized: usize = 0;
    errdefer {
        for (spectra[0..initialized]) |spectrum| {
            allocator.free(spectrum.mz);
            allocator.free(spectrum.intensity);
        }
        allocator.free(spectra);
    }

    for (0..spectrum_count) |idx| {
        const peak_count = random.uintAtMost(usize, max_peaks);
        const mz = try allocator.alloc(f64, peak_count);
        errdefer allocator.free(mz);
        const intensity = try allocator.alloc(f32, peak_count);
        errdefer allocator.free(intensity);

        var current_mz = 100.0 + (@as(f64, @floatFromInt(idx)) * 3.5) + (random.float(f64) * 0.25);
        for (0..peak_count) |peak_idx| {
            current_mz += 0.0000005 + (random.float(f64) * 0.35) + (@as(f64, @floatFromInt(peak_idx % 5)) * 0.000000125);
            mz[peak_idx] = current_mz;

            var value = @as(f32, @floatCast(random.float(f64) * 50000.0));
            if ((idx + peak_idx) % 11 == 0) value = 0.0;
            if ((idx + peak_idx) % 17 == 0) value += 0.25;
            intensity[peak_idx] = value;
        }

        const ms_level: u8 = if (idx % 3 == 0 or idx % 5 == 0) 2 else 1;
        spectra[idx] = .{
            .scan_id = @intCast(100_000 + idx),
            .rt_seconds = 0.25 + (@as(f32, @floatFromInt(idx)) * 0.1375),
            .ms_level = ms_level,
            .precursor_mz = if (ms_level == 2) 350.0 + (@as(f64, @floatFromInt(idx % 97)) * 1.75) else 0.0,
            .mz = mz,
            .intensity = intensity,
        };
        initialized += 1;
    }

    return .{ .allocator = allocator, .spectra = spectra };
}

test "codec lossless round-trip preserves original global order" {
    // All m/z values are f32-exact so the round-trip is bit-exact.
    var mz_ms2_a = [_]f64{ 400.0, 401.0 };
    var intensity_ms2_a = [_]f32{ 10.0, 11.0 };
    var mz_ms1 = [_]f64{ 100.0, 100.125, 101.0 };
    var intensity_ms1 = [_]f32{ 1.0, 2.0, 3.0 };
    var mz_ms2_b = [_]f64{500.0};
    var intensity_ms2_b = [_]f32{5.0};

    const input = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 20, .rt_seconds = 2.0, .ms_level = 2, .precursor_mz = 600.1, .mz = mz_ms2_a[0..], .intensity = intensity_ms2_a[0..] },
        .{ .scan_id = 10, .rt_seconds = 1.0, .ms_level = 1, .precursor_mz = 0.0, .mz = mz_ms1[0..], .intensity = intensity_ms1[0..] },
        .{ .scan_id = 21, .rt_seconds = 2.2, .ms_level = 2, .precursor_mz = 600.2, .mz = mz_ms2_b[0..], .intensity = intensity_ms2_b[0..] },
    };

    const encoded = try codec.encodeFileAlloc(std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossless }, .block_size = 2 });
    defer std.testing.allocator.free(encoded);

    const inspection = try codec.inspectAlloc(std.testing.allocator, encoded);
    defer codec.freeInspection(std.testing.allocator, inspection);

    try std.testing.expectEqual(@as(u32, 3), inspection.header.spectrum_count);
    try std.testing.expectEqual(@as(u32, 2), inspection.header.block_count);
    try std.testing.expect((inspection.header.flags & codec.flag_has_global_order) != 0);
    try std.testing.expectEqual(@as(usize, 1), inspection.ms1_block_count);
    try std.testing.expectEqual(@as(usize, 1), inspection.ms2_block_count);

    const decoded = try codec.decodeFileAlloc(std.testing.allocator, encoded, .{});
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, 3), decoded.len);

    try std.testing.expectEqual(@as(u32, 20), decoded[0].scan_id);
    try std.testing.expectEqual(@as(u8, 2), decoded[0].ms_level);
    try std.testing.expectEqualSlices(f64, mz_ms2_a[0..], decoded[0].mz);

    try std.testing.expectEqual(@as(u32, 10), decoded[1].scan_id);
    try std.testing.expectEqual(@as(u8, 1), decoded[1].ms_level);
    try std.testing.expectEqualSlices(f64, mz_ms1[0..], decoded[1].mz);

    try std.testing.expectEqual(@as(u32, 21), decoded[2].scan_id);
    try std.testing.expectEqual(@as(u8, 2), decoded[2].ms_level);
    try std.testing.expectEqualSlices(f64, mz_ms2_b[0..], decoded[2].mz);

    try expectLosslessRoundTrip(&input, decoded);
}

test "codec lossless round-trip preserves order and spectra across many interleaved blocks" {
    const empty_mz = [_]f64{};
    const empty_intensity = [_]f32{};
    // All m/z values are f32-exact so the round-trip is bit-exact.
    var mz_a = [_]f64{ 400.0, 400.125 };
    var intensity_a = [_]f32{ 10.0, 11.0 };
    var mz_b = [_]f64{100.0};
    var intensity_b = [_]f32{1.0};
    var mz_c = [_]f64{ 500.125, 500.25, 500.375 };
    var intensity_c = [_]f32{ 3.0, 4.0, 5.0 };
    var mz_d = [_]f64{ 200.0, 200.25, 201.0 };
    var intensity_d = [_]f32{ 6.0, 7.0, 8.0 };
    var mz_e = [_]f64{ 600.0, 600.25, 601.0, 602.5 };
    var intensity_e = [_]f32{ 0.5, 2.5, 25.0, 250.0 };
    var mz_f = [_]f64{300.0};
    var intensity_f = [_]f32{9.0};

    const input = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 20, .rt_seconds = 2.0, .ms_level = 2, .precursor_mz = 600.1, .mz = mz_a[0..], .intensity = intensity_a[0..] },
        .{ .scan_id = 10, .rt_seconds = 1.0, .ms_level = 1, .precursor_mz = 0.0, .mz = empty_mz[0..], .intensity = empty_intensity[0..] },
        .{ .scan_id = 21, .rt_seconds = 2.1, .ms_level = 2, .precursor_mz = 600.2, .mz = mz_c[0..], .intensity = intensity_c[0..] },
        .{ .scan_id = 11, .rt_seconds = 1.1, .ms_level = 1, .precursor_mz = 0.0, .mz = mz_b[0..], .intensity = intensity_b[0..] },
        .{ .scan_id = 22, .rt_seconds = 2.2, .ms_level = 2, .precursor_mz = 600.3, .mz = mz_e[0..], .intensity = intensity_e[0..] },
        .{ .scan_id = 12, .rt_seconds = 1.2, .ms_level = 1, .precursor_mz = 0.0, .mz = mz_d[0..], .intensity = intensity_d[0..] },
        .{ .scan_id = 23, .rt_seconds = 2.3, .ms_level = 2, .precursor_mz = 600.4, .mz = empty_mz[0..], .intensity = empty_intensity[0..] },
        .{ .scan_id = 13, .rt_seconds = 1.3, .ms_level = 1, .precursor_mz = 0.0, .mz = mz_f[0..], .intensity = intensity_f[0..] },
    };

    const encoded = try codec.encodeFileAlloc(std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossless }, .block_size = 2 });
    defer std.testing.allocator.free(encoded);

    const inspection = try codec.inspectAlloc(std.testing.allocator, encoded);
    defer codec.freeInspection(std.testing.allocator, inspection);

    try std.testing.expectEqual(@as(u32, 8), inspection.header.spectrum_count);
    try std.testing.expectEqual(@as(u32, 4), inspection.header.block_count);
    try std.testing.expectEqual(@as(usize, 2), inspection.ms1_block_count);
    try std.testing.expectEqual(@as(usize, 2), inspection.ms2_block_count);

    const decoded = try codec.decodeFileAlloc(std.testing.allocator, encoded, .{});
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, input.len), decoded.len);
    inline for (input, 0..) |expected, idx| {
        try std.testing.expectEqual(expected.scan_id, decoded[idx].scan_id);
        try std.testing.expectEqual(expected.ms_level, decoded[idx].ms_level);
    }
    try expectLosslessRoundTrip(&input, decoded);
}

test "codec decode rejects invalid global order tables" {
    var mz_ms2 = [_]f64{400.00000125};
    var intensity_ms2 = [_]f32{10.0};
    var mz_ms1 = [_]f64{100.00000125};
    var intensity_ms1 = [_]f32{1.0};

    const input = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 20, .rt_seconds = 2.0, .ms_level = 2, .precursor_mz = 600.1, .mz = mz_ms2[0..], .intensity = intensity_ms2[0..] },
        .{ .scan_id = 10, .rt_seconds = 1.0, .ms_level = 1, .precursor_mz = 0.0, .mz = mz_ms1[0..], .intensity = intensity_ms1[0..] },
    };

    const encoded = try codec.encodeFileAlloc(std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossless }, .block_size = 1 });
    defer std.testing.allocator.free(encoded);

    const tampered = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(tampered);

    const order_offset = codec.header_len;
    std.mem.writeInt(u32, tampered[order_offset..][0..@sizeOf(u32)], 0, .little);
    std.mem.writeInt(u32, tampered[order_offset + @sizeOf(u32) ..][0..@sizeOf(u32)], 0, .little);

    try std.testing.expectError(error.InvalidOrderTable, codec.decodeFileAlloc(std.testing.allocator, tampered, .{}));
}

test "codec inspect rejects invalid magic, unsupported version, trailing data, and unsupported ms level" {
    var mz = [_]f64{ 400.00000125, 401.00000375 };
    var intensity = [_]f32{ 10.0, 11.0 };
    const input = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 20, .rt_seconds = 2.0, .ms_level = 2, .precursor_mz = 600.1, .mz = mz[0..], .intensity = intensity[0..] },
    };

    const encoded = try codec.encodeFileAlloc(std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossless }, .block_size = 1 });
    defer std.testing.allocator.free(encoded);

    const bad_magic = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(bad_magic);
    bad_magic[0] = 'B';
    try std.testing.expectError(error.InvalidMagic, codec.inspectAlloc(std.testing.allocator, bad_magic));

    const bad_version = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(bad_version);
    std.mem.writeInt(u16, bad_version[4..6], codec.version_major + 1, .little);
    try std.testing.expectError(error.UnsupportedVersion, codec.inspectAlloc(std.testing.allocator, bad_version));

    const with_trailing = try std.testing.allocator.alloc(u8, encoded.len + 1);
    defer std.testing.allocator.free(with_trailing);
    @memcpy(with_trailing[0..encoded.len], encoded);
    with_trailing[encoded.len] = 0;
    try std.testing.expectError(error.TrailingFileData, codec.inspectAlloc(std.testing.allocator, with_trailing));

    const bad_ms_level = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(bad_ms_level);
    const block_offset = codec.header_len + @sizeOf(u32) * input.len;
    bad_ms_level[block_offset + 2] = 3;
    try std.testing.expectError(error.UnsupportedMsLevel, codec.inspectAlloc(std.testing.allocator, bad_ms_level));
}

test "codec inspect accepts prior minor version files" {
    var mz = [_]f64{ 123.000000001, 123.000000003, 123.000000004 };
    var intensity = [_]f32{ 10.0, 11.0, 12.0 };
    const input = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 600.0, .mz = mz[0..], .intensity = intensity[0..] },
    };

    const encoded = try codec.encodeFileAlloc(std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossless }, .block_size = 1 });
    defer std.testing.allocator.free(encoded);

    const old_minor = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(old_minor);
    std.mem.writeInt(u16, old_minor[6..8], 0, .little);

    const inspection = try codec.inspectAlloc(std.testing.allocator, old_minor);
    defer codec.freeInspection(std.testing.allocator, inspection);

    try std.testing.expectEqual(@as(u16, 0), inspection.header.version_minor);

    const decoded = try codec.decodeFileAlloc(std.testing.allocator, old_minor, .{});
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);
    try expectLosslessRoundTrip(&input, decoded);
}

test "codec lossless round-trip preserves per-spectrum m/z width blocks" {
    const peak_count = 256;
    const mz_a = try std.testing.allocator.alloc(f64, peak_count);
    defer std.testing.allocator.free(mz_a);
    const mz_b = try std.testing.allocator.alloc(f64, peak_count);
    defer std.testing.allocator.free(mz_b);
    const intensity_a = try std.testing.allocator.alloc(f32, peak_count);
    defer std.testing.allocator.free(intensity_a);
    const intensity_b = try std.testing.allocator.alloc(f32, peak_count);
    defer std.testing.allocator.free(intensity_b);

    var current_a: f64 = 100.000000001;
    var current_b: f64 = 1900.000000001;
    for (0..peak_count) |idx| {
        current_a += if ((idx & 1) == 0) 0.000000001 else 0.000000002;
        current_b += if ((idx & 1) == 0) 0.000000041 else 0.000000059;
        mz_a[idx] = current_a;
        mz_b[idx] = current_b;
        intensity_a[idx] = @floatFromInt(10 + idx);
        intensity_b[idx] = @floatFromInt(20 + idx);
    }

    const input = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 600.0, .mz = mz_a, .intensity = intensity_a },
        .{ .scan_id = 2, .rt_seconds = 1.1, .ms_level = 2, .precursor_mz = 601.0, .mz = mz_b, .intensity = intensity_b },
    };

    const encoded = try codec.encodeFileAlloc(std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossless, .mz_rans_min_gain_percent = 99 }, .block_size = 2 });
    defer std.testing.allocator.free(encoded);

    const inspection = try codec.inspectAlloc(std.testing.allocator, encoded);
    defer codec.freeInspection(std.testing.allocator, inspection);

    try std.testing.expectEqual(@as(u16, codec.version_minor), inspection.header.version_minor);
    try std.testing.expectEqual(@as(usize, 1), inspection.blocks.len);
    try std.testing.expect((inspection.blocks[0].header.flags & block.flag_mz_per_spectrum_bit_widths) != 0);
    try expectByteBreakdownSums(inspection, encoded.len);

    const decoded = try codec.decodeFileAlloc(std.testing.allocator, encoded, .{});
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);
    try expectLosslessRoundTrip(&input, decoded);
}

test "codec inspect rejects truncated order tables and truncated blocks" {
    var mz_ms2 = [_]f64{ 400.00000125, 401.00000375 };
    var intensity_ms2 = [_]f32{ 10.0, 11.0 };
    var mz_ms1 = [_]f64{100.00000125};
    var intensity_ms1 = [_]f32{1.0};
    const input = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 20, .rt_seconds = 2.0, .ms_level = 2, .precursor_mz = 600.1, .mz = mz_ms2[0..], .intensity = intensity_ms2[0..] },
        .{ .scan_id = 10, .rt_seconds = 1.0, .ms_level = 1, .precursor_mz = 0.0, .mz = mz_ms1[0..], .intensity = intensity_ms1[0..] },
    };

    const encoded = try codec.encodeFileAlloc(std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossless }, .block_size = 1 });
    defer std.testing.allocator.free(encoded);

    try std.testing.expectError(
        error.UnexpectedEndOfStream,
        codec.inspectAlloc(std.testing.allocator, encoded[0 .. codec.header_len + @sizeOf(u32) * input.len - 1]),
    );

    try std.testing.expectError(
        error.UnexpectedEndOfStream,
        codec.inspectAlloc(std.testing.allocator, encoded[0 .. encoded.len - 1]),
    );
}

test "codec lossless synthetic corpus round-trips with sub-ppm m/z across many spectra" {
    var corpus = try makeSyntheticCorpus(std.testing.allocator, 24);
    defer corpus.deinit();

    const encoded = try codec.encodeFileAlloc(std.testing.allocator, corpus.spectra, .{ .block_options = .{ .mode = .lossless }, .block_size = 3 });
    defer std.testing.allocator.free(encoded);

    const decoded = try codec.decodeFileAlloc(std.testing.allocator, encoded, .{});
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(corpus.spectra.len, decoded.len);
    try expectLosslessRoundTrip(corpus.spectra, decoded);
}

test "codec lossless pseudo-random corpus round-trips with sub-ppm m/z and accounting matches bytes" {
    var corpus = try makePseudoRandomCorpus(std.testing.allocator, 0x5eed_c0de, 257, 33);
    defer corpus.deinit();

    const encoded = try codec.encodeFileAlloc(std.testing.allocator, corpus.spectra, .{ .block_options = .{ .mode = .lossless }, .block_size = 7 });
    defer std.testing.allocator.free(encoded);

    const inspection = try codec.inspectAlloc(std.testing.allocator, encoded);
    defer codec.freeInspection(std.testing.allocator, inspection);
    try expectByteBreakdownSums(inspection, encoded.len);

    const decoded = try codec.decodeFileAlloc(std.testing.allocator, encoded, .{});
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(corpus.spectra.len, decoded.len);
    try expectLosslessRoundTrip(corpus.spectra, decoded);
}

test "codec lossy synthetic corpus preserves order while bounding m/z and intensity error" {
    var corpus = try makeSyntheticCorpus(std.testing.allocator, 18);
    defer corpus.deinit();

    const encoded = try codec.encodeFileAlloc(std.testing.allocator, corpus.spectra, .{ .block_options = .{ .mode = .lossy, .intensity_quant = 4096 }, .block_size = 4 });
    defer std.testing.allocator.free(encoded);

    const decoded = try codec.decodeFileAlloc(std.testing.allocator, encoded, .{});
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(corpus.spectra.len, decoded.len);
    const mz_tolerance = 1.1 / 500_000.0;
    for (corpus.spectra, decoded) |expected, actual| {
        try std.testing.expectEqual(expected.scan_id, actual.scan_id);
        try std.testing.expectEqual(expected.ms_level, actual.ms_level);
        try std.testing.expectEqual(expected.rt_seconds, actual.rt_seconds);
        try std.testing.expectEqual(expected.precursor_mz, actual.precursor_mz);
        try std.testing.expectEqual(expected.mz.len, actual.mz.len);
        for (expected.mz, actual.mz) |expected_mz, actual_mz| {
            try std.testing.expectApproxEqAbs(expected_mz, actual_mz, mz_tolerance);
        }
        try std.testing.expectEqual(expected.intensity.len, actual.intensity.len);
        for (expected.intensity, actual.intensity) |expected_i, actual_i| {
            if (expected_i == 0.0) {
                try std.testing.expectEqual(@as(f32, 0.0), actual_i);
            } else {
                try std.testing.expectApproxEqRel(expected_i, actual_i, 0.02);
            }
        }
    }
}

test "codec lossy pseudo-random corpus keeps order, bounds error, and reports packed intensity bytes" {
    var corpus = try makePseudoRandomCorpus(std.testing.allocator, 0x0dd_cafe, 193, 29);
    defer corpus.deinit();

    const encoded = try codec.encodeFileAlloc(std.testing.allocator, corpus.spectra, .{ .block_options = .{ .mode = .lossy, .intensity_quant = 4096 }, .block_size = 9 });
    defer std.testing.allocator.free(encoded);

    const inspection = try codec.inspectAlloc(std.testing.allocator, encoded);
    defer codec.freeInspection(std.testing.allocator, inspection);
    try expectByteBreakdownSums(inspection, encoded.len);
    try std.testing.expect(inspection.byte_breakdown.intensity_metadata_bytes > 0);
    try std.testing.expect(inspection.byte_breakdown.intensity_payload_bytes > 0);

    const decoded = try codec.decodeFileAlloc(std.testing.allocator, encoded, .{});
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    const mz_tolerance = 1.1 / 500_000.0;
    for (corpus.spectra, decoded) |expected, actual| {
        try std.testing.expectEqual(expected.scan_id, actual.scan_id);
        try std.testing.expectEqual(expected.ms_level, actual.ms_level);
        try std.testing.expectEqual(expected.rt_seconds, actual.rt_seconds);
        try std.testing.expectEqual(expected.precursor_mz, actual.precursor_mz);
        try std.testing.expectEqual(expected.mz.len, actual.mz.len);
        try std.testing.expectEqual(expected.intensity.len, actual.intensity.len);

        for (expected.mz, actual.mz) |expected_mz, actual_mz| {
            try std.testing.expectApproxEqAbs(expected_mz, actual_mz, mz_tolerance);
        }
        for (expected.intensity, actual.intensity) |expected_i, actual_i| {
            if (expected_i == 0.0) {
                try std.testing.expectEqual(@as(f32, 0.0), actual_i);
            } else {
                try std.testing.expectApproxEqRel(expected_i, actual_i, 0.02);
            }
        }
    }
}

test "codec lossy round-trip keeps counts and flags consistent" {
    var mz_ms1 = [_]f64{ 100.0, 100.5, 101.25 };
    var intensity_ms1 = [_]f32{ 0.5, 10.0, 100.0 };
    var mz_ms2 = [_]f64{ 400.0, 401.0 };
    var intensity_ms2 = [_]f32{ 5.0, 25.0 };

    const input = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 1, .precursor_mz = 0.0, .mz = mz_ms1[0..], .intensity = intensity_ms1[0..] },
        .{ .scan_id = 2, .rt_seconds = 2.0, .ms_level = 2, .precursor_mz = 500.0, .mz = mz_ms2[0..], .intensity = intensity_ms2[0..] },
    };

    const encoded = try codec.encodeFileAlloc(std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossy, .intensity_quant = 4096 }, .block_size = 128 });
    defer std.testing.allocator.free(encoded);

    const inspection = try codec.inspectAlloc(std.testing.allocator, encoded);
    defer codec.freeInspection(std.testing.allocator, inspection);

    try std.testing.expectEqual(@as(u16, 128), inspection.header.block_size);
    try std.testing.expect((inspection.header.flags & codec.flag_lossless) == 0);
    try std.testing.expect((inspection.header.flags & codec.flag_contains_ms1) != 0);
    try std.testing.expect((inspection.header.flags & codec.flag_contains_ms2) != 0);
    try std.testing.expectEqual(@as(u64, 5), inspection.header.total_peaks);
}

test "codec encode rejects block_size of zero" {
    var mz = [_]f64{100.0};
    var intensity = [_]f32{1.0};
    const input = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 1, .precursor_mz = 0.0, .mz = mz[0..], .intensity = intensity[0..] },
    };

    try std.testing.expectError(error.InvalidBlockSize, codec.encodeFileAlloc(std.testing.allocator, &input, .{ .block_size = 0 }));
}

test "empirical error bounds: lossless m/z error ≤ 0.5 / scale_factor" {
    // Build a corpus that covers the full m/z range [50, 6000] with
    // non-f32-exact values to force the fixed-point path.
    var mz_buf: [1024]f64 = undefined;
    var int_buf: [1024]f32 = undefined;
    for (0..1024) |i| {
        mz_buf[i] = 50.0 + @as(f64, @floatFromInt(i)) * (5950.0 / 1023.0) + 0.0000001 * @as(f64, @floatFromInt(i % 7));
        int_buf[i] = @as(f32, @floatFromInt(10 * (i % 100 + 1)));
    }

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 500.0, .mz = mz_buf[0..], .intensity = int_buf[0..] },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless });
    defer std.testing.allocator.free(encoded);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    const max_allowed_error = 0.5 / @as(f64, @floatFromInt(1_000_000_000));
    var max_actual_error: f64 = 0.0;
    for (mz_buf[0..], decoded[0].mz) |orig, got| {
        const err = @abs(got - orig);
        if (err > max_actual_error) max_actual_error = err;
    }

    if (max_actual_error > max_allowed_error) {
        std.debug.print("lossless m/z max error {e:.2} > allowed {e:.2}\n", .{ max_actual_error, max_allowed_error });
        return error.TestExpectedLessThan;
    }
}

test "empirical error bounds: lossy m/z error ≤ 0.5 / scale_factor" {
    var mz_buf: [1024]f64 = undefined;
    var int_buf: [1024]f32 = undefined;
    for (0..1024) |i| {
        mz_buf[i] = 50.0 + @as(f64, @floatFromInt(i)) * (5950.0 / 1023.0) + 0.0000001 * @as(f64, @floatFromInt(i % 7));
        int_buf[i] = @as(f32, @floatFromInt(10 * (i % 100 + 1)));
    }

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 500.0, .mz = mz_buf[0..], .intensity = int_buf[0..] },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossy });
    defer std.testing.allocator.free(encoded);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    const max_allowed_error = 0.5 / @as(f64, @floatFromInt(500_000));
    var max_actual_error: f64 = 0.0;
    for (mz_buf[0..], decoded[0].mz) |orig, got| {
        const err = @abs(got - orig);
        if (err > max_actual_error) max_actual_error = err;
    }

    if (max_actual_error > max_allowed_error) {
        std.debug.print("lossy m/z max error {e:.2} > allowed {e:.2}\n", .{ max_actual_error, max_allowed_error });
        return error.TestExpectedLessThan;
    }
}

test "empirical error bounds: lossy intensity rel error ≤ exp(log_max/quant) - 1" {
    // Sweep intensities from 1.0 to ~1e7 covering >7 decades of dynamic range.
    var mz_buf: [512]f64 = undefined;
    var int_buf: [512]f32 = undefined;
    for (0..512) |i| {
        mz_buf[i] = @as(f64, @floatFromInt(100 + i));
        int_buf[i] = @floatCast(@exp(@as(f64, @floatFromInt(i)) * (16.0 / @as(f64, 512))));
    }

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 500.0, .mz = mz_buf[0..], .intensity = int_buf[0..] },
    };

    const quant_factor: u16 = 16384;
    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossy, .intensity_quant = quant_factor });
    defer std.testing.allocator.free(encoded);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    // Compute theoretical max relative error.
    // The quantization step in log space: Δ = log_max / quant_levels.
    // max_rel_error ≤ exp(Δ) - 1.
    var intensity_log_scale: f32 = 0.0;
    for (int_buf[0..]) |v| {
        const lm = quantize.intensityLogMax(&[_]f32{v});
        if (lm > intensity_log_scale) intensity_log_scale = lm;
    }
    const delta = @as(f64, intensity_log_scale) / @as(f64, @floatFromInt(quant_factor));
    const max_allowed_rel_error = std.math.exp(delta) - 1.0;

    var max_actual_rel_error: f64 = 0.0;
    for (int_buf[0..], decoded[0].intensity) |orig, got| {
        if (orig == 0.0) continue;
        const rel_err = @abs(@as(f64, got) - @as(f64, orig)) / @as(f64, orig);
        if (rel_err > max_actual_rel_error) max_actual_rel_error = rel_err;
    }

    if (max_actual_rel_error > max_allowed_rel_error * 1.01) {
        std.debug.print("lossy intensity max rel error {e:.2} > allowed {e:.2} (delta={e:.2})\n", .{ max_actual_rel_error, max_allowed_rel_error, delta });
        return error.TestExpectedLessThan;
    }
}

test "f32 bit-cast path produces exactly zero m/z error" {
    // Values that are exactly representable as f32 must round-trip with zero error.
    var mz_buf: [100]f64 = undefined;
    var int_buf: [100]f32 = undefined;
    for (0..100) |i| {
        mz_buf[i] = @as(f64, @as(f32, @floatFromInt(100 + i)));
        int_buf[i] = @floatFromInt(i);
    }

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 500.0, .mz = mz_buf[0..], .intensity = int_buf[0..] },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless });
    defer std.testing.allocator.free(encoded);

    const header = try block.parseHeader(encoded);
    try std.testing.expect((header.flags & block.flag_lossless_mz_f32) != 0);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    for (mz_buf[0..], decoded[0].mz) |orig, got| {
        try std.testing.expectEqual(orig, got);
    }
}

test "lossless m/z fixed-point path is used for non-f32 values" {
    // Monotonically increasing values with sub-f32 precision.
    var mz_buf: [50]f64 = undefined;
    var int_buf: [50]f32 = undefined;
    for (0..50) |i| {
        mz_buf[i] = 100.0 + @as(f64, @floatFromInt(i)) * 123.4567890123456789;
        int_buf[i] = @floatFromInt(i);
    }

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 500.0, .mz = mz_buf[0..], .intensity = int_buf[0..] },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless });
    defer std.testing.allocator.free(encoded);

    const header = try block.parseHeader(encoded);
    try std.testing.expect((header.flags & block.flag_lossless_mz_f32) == 0);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    const max_allowed = 0.5 / @as(f64, @floatFromInt(1_000_000_000));
    var max_actual: f64 = 0.0;
    for (mz_buf[0..], decoded[0].mz) |orig, got| {
        const err = @abs(got - orig);
        if (err > max_actual) max_actual = err;
    }

    try std.testing.expect(max_actual <= max_allowed);
}

test "lossy intensity extremes stay within error bound" {
    var mz_buf: [100]f64 = undefined;
    var int_buf: [100]f32 = undefined;
    for (0..100) |i| {
        mz_buf[i] = @as(f64, @floatFromInt(200 + i));
        // Alternating near-zero and near-max intensities to stress error bounds.
        int_buf[i] = if (i % 2 == 0) @as(f32, @floatCast(2.0)) else @as(f32, @floatCast(@exp(@as(f32, @floatFromInt(14 + (i % 5))))));
    }

    const quant_factor: u16 = 16384;
    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 500.0, .mz = mz_buf[0..], .intensity = int_buf[0..] },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossy, .intensity_quant = quant_factor });
    defer std.testing.allocator.free(encoded);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    var log_max: f32 = 0.0;
    for (int_buf[0..]) |v| {
        const lm = quantize.intensityLogMax(&[_]f32{v});
        if (lm > log_max) log_max = lm;
    }
    const delta = @as(f64, log_max) / @as(f64, @floatFromInt(quant_factor));
    const max_allowed = std.math.exp(delta) - 1.0;

    var max_actual: f64 = 0.0;
    for (int_buf[0..], decoded[0].intensity) |orig, got| {
        if (orig == 0.0) continue;
        const rel = @abs(@as(f64, got) - @as(f64, orig)) / @as(f64, orig);
        if (rel > max_actual) max_actual = rel;
    }

    try std.testing.expect(max_actual <= max_allowed * 1.01);
}

test "lossy smallest non-zero intensity has bounded relative error" {
    // Single peak with intensity = smallest non-zero value above zero-cutoff.
    var mz_buf = [_]f64{500.0};
    var int_buf = [_]f32{1.0};

    const quant_factor: u16 = 16384;
    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 500.0, .mz = mz_buf[0..], .intensity = int_buf[0..] },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossy, .intensity_quant = quant_factor });
    defer std.testing.allocator.free(encoded);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    const rel_err = @abs(@as(f64, decoded[0].intensity[0]) - @as(f64, 1.0)) / 1.0;
    const log1p_val = std.math.log1p(@as(f64, 1.0));
    const delta = log1p_val / @as(f64, @floatFromInt(quant_factor));
    const max_allowed = std.math.exp(delta) - 1.0;

    try std.testing.expect(rel_err <= max_allowed * 1.01);
}

test "encodeFileAlloc with zero spectra produces a valid decodable empty file" {
    // The zero-spectrum path was untested. It must not return error.TooManySpectra
    // or any other spurious error, and the round-trip must return an empty slice.
    const empty: []const binary_reader.RawSpectrum = &.{};

    const encoded = try codec.encodeFileAlloc(std.testing.allocator, empty, .{ .block_options = .{ .mode = .lossless }, .block_size = 16 });
    defer std.testing.allocator.free(encoded);

    const inspection = try codec.inspectAlloc(std.testing.allocator, encoded);
    defer codec.freeInspection(std.testing.allocator, inspection);

    try std.testing.expectEqual(@as(u32, 0), inspection.header.spectrum_count);
    try std.testing.expectEqual(@as(u32, 0), inspection.header.block_count);

    const decoded = try codec.decodeFileAlloc(std.testing.allocator, encoded, .{});
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}
