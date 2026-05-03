const std = @import("std");
const binary_reader = @import("binary_reader");
const block = @import("block");

/// Check that every decoded m/z value is within `max_ppm` of the original.
/// The lossless fixed-point path guarantees < 0.001 ppm, so we use 0.001
/// as the assertion threshold here.
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

test "lossless block round-trip preserves aligned spectra exactly" {
    // All m/z values are f32-exact so the f32 bit-cast path is taken.
    var mz_1 = [_]f64{ 100.0, 100.125, 101.5 };
    var intensity_1 = [_]f32{ 10.0, 20.0, 30.0 };
    var mz_2 = [_]f64{ 200.0, 200.25 };
    var intensity_2 = [_]f32{ 5.0, 1.5 };

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 10.0, .ms_level = 2, .precursor_mz = 500.25, .mz = mz_1[0..], .intensity = intensity_1[0..] },
        .{ .scan_id = 2, .rt_seconds = 10.5, .ms_level = 2, .precursor_mz = 500.75, .mz = mz_2[0..], .intensity = intensity_2[0..] },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless });
    defer std.testing.allocator.free(encoded);

    const header = try block.parseHeader(encoded);
    try std.testing.expectEqual(@as(u16, 2), header.spectrum_count);
    try std.testing.expect((header.flags & block.flag_lossless_intensity_raw) != 0);
    // f32-exact data uses the f32 bit-cast path — this flag must be set.
    try std.testing.expect((header.flags & block.flag_lossless_mz_f32) != 0);
    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, spectra.len), decoded.len);
    inline for (spectra, 0..) |expected, idx| {
        const actual = decoded[idx];
        try std.testing.expectEqual(expected.scan_id, actual.scan_id);
        try std.testing.expectEqual(expected.rt_seconds, actual.rt_seconds);
        try std.testing.expectEqual(expected.ms_level, actual.ms_level);
        try std.testing.expectEqual(expected.precursor_mz, actual.precursor_mz);
        try std.testing.expectEqualSlices(f64, expected.mz, actual.mz);
        try std.testing.expectEqualSlices(f32, expected.intensity, actual.intensity);
    }
}

test "lossless block round-trip preserves empty and adversarial spectra exactly" {
    // All m/z values are f32-exact so the f32 bit-cast path is taken.
    const empty_mz = [_]f64{};
    const empty_intensity = [_]f32{};
    var mz_single = [_]f64{123.0};
    var intensity_single = [_]f32{42.0};
    var mz_dense = [_]f64{ 500.0, 500.125, 500.25, 501.0 };
    var intensity_dense = [_]f32{ 0.0, 1.0, 10.0, 1000.0 };
    var mz_tail = [_]f64{ 900.125, 900.25 };
    var intensity_tail = [_]f32{ 7.5, 8.5 };

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 10, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 444.1, .mz = empty_mz[0..], .intensity = empty_intensity[0..] },
        .{ .scan_id = 11, .rt_seconds = 1.1, .ms_level = 2, .precursor_mz = 444.2, .mz = mz_single[0..], .intensity = intensity_single[0..] },
        .{ .scan_id = 12, .rt_seconds = 1.2, .ms_level = 2, .precursor_mz = 444.3, .mz = mz_dense[0..], .intensity = intensity_dense[0..] },
        .{ .scan_id = 13, .rt_seconds = 1.3, .ms_level = 2, .precursor_mz = 444.4, .mz = mz_tail[0..], .intensity = intensity_tail[0..] },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless });
    defer std.testing.allocator.free(encoded);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, spectra.len), decoded.len);
    inline for (spectra, 0..) |expected, idx| {
        const actual = decoded[idx];
        try std.testing.expectEqual(expected.scan_id, actual.scan_id);
        try std.testing.expectEqual(expected.rt_seconds, actual.rt_seconds);
        try std.testing.expectEqual(expected.ms_level, actual.ms_level);
        try std.testing.expectEqual(expected.precursor_mz, actual.precursor_mz);
        try std.testing.expectEqualSlices(f64, expected.mz, actual.mz);
        try std.testing.expectEqualSlices(f32, expected.intensity, actual.intensity);
    }
}

test "block encoding rejects mixed ms levels" {
    var mz_ms1 = [_]f64{100.0};
    var intensity_ms1 = [_]f32{1.0};
    var mz_ms2 = [_]f64{200.0};
    var intensity_ms2 = [_]f32{2.0};

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 1, .precursor_mz = 0.0, .mz = mz_ms1[0..], .intensity = intensity_ms1[0..] },
        .{ .scan_id = 2, .rt_seconds = 2.0, .ms_level = 2, .precursor_mz = 500.0, .mz = mz_ms2[0..], .intensity = intensity_ms2[0..] },
    };

    try std.testing.expectError(error.MixedMsLevel, block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless }));
}

test "lossless block encoding rejects non-monotonic m/z arrays" {
    var mz = [_]f64{ 300.0, 299.5, 301.0 };
    var intensity = [_]f32{ 1.0, 2.0, 3.0 };

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 5, .rt_seconds = 5.0, .ms_level = 1, .precursor_mz = 0.0, .mz = mz[0..], .intensity = intensity[0..] },
    };

    try std.testing.expectError(error.NonMonotonicInput, block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless }));
}

test "block decode rejects checksum corruption" {
    var mz = [_]f64{ 700.00000125, 700.00000375 };
    var intensity = [_]f32{ 8.0, 9.0 };

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 77, .rt_seconds = 7.7, .ms_level = 2, .precursor_mz = 777.7, .mz = mz[0..], .intensity = intensity[0..] },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless });
    defer std.testing.allocator.free(encoded);

    const corrupted = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(corrupted);
    corrupted[block.header_len] ^= 0x01;

    try std.testing.expectError(error.ChecksumMismatch, block.decodeBlock(std.testing.allocator, corrupted));
}

test "block decode rejects mismatched peak totals" {
    var mz = [_]f64{ 700.00000125, 700.00000375 };
    var intensity = [_]f32{ 8.0, 9.0 };

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 77, .rt_seconds = 7.7, .ms_level = 2, .precursor_mz = 777.7, .mz = mz[0..], .intensity = intensity[0..] },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless });
    defer std.testing.allocator.free(encoded);

    const corrupted = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(corrupted);
    std.mem.writeInt(u32, corrupted[4..8], 3, .little);

    try std.testing.expectError(error.InvalidPeakCount, block.decodeBlock(std.testing.allocator, corrupted));
}

test "block decode rejects trailing payload bytes" {
    var mz = [_]f64{ 710.00000125, 710.00000375 };
    var intensity = [_]f32{ 4.0, 5.0 };

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 88, .rt_seconds = 8.8, .ms_level = 2, .precursor_mz = 888.8, .mz = mz[0..], .intensity = intensity[0..] },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless });
    defer std.testing.allocator.free(encoded);

    const extended = try std.testing.allocator.alloc(u8, encoded.len + 1);
    defer std.testing.allocator.free(extended);
    @memcpy(extended[0..encoded.len], encoded);
    extended[encoded.len] = 0;

    const new_payload_len = (encoded.len - block.header_len) + 1;
    std.mem.writeInt(u32, extended[28..32], @intCast(new_payload_len), .little);
    const new_checksum = std.hash.crc.Crc32.hash(extended[block.header_len..]);
    std.mem.writeInt(u32, extended[36..40], new_checksum, .little);

    try std.testing.expectError(error.TrailingBlockPayload, block.decodeBlock(std.testing.allocator, extended));
}

test "lossy block round-trip keeps intensity error bounded" {
    var mz_1 = [_]f64{ 300.0, 300.000002, 301.25 };
    var intensity_1 = [_]f32{ 0.5, 10.0, 250.0 };
    var mz_2 = [_]f64{ 400.0, 401.0, 402.0 };
    var intensity_2 = [_]f32{ 1.0, 50.0, 1000.0 };

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 10, .rt_seconds = 4.0, .ms_level = 1, .precursor_mz = 0.0, .mz = mz_1[0..], .intensity = intensity_1[0..] },
        .{ .scan_id = 11, .rt_seconds = 4.4, .ms_level = 1, .precursor_mz = 0.0, .mz = mz_2[0..], .intensity = intensity_2[0..] },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossy, .intensity_quant = 4096 });
    defer std.testing.allocator.free(encoded);

    const header = try block.parseHeader(encoded);
    try std.testing.expectEqual(@as(u8, 0), header.flags & block.flag_lossless_intensity_raw);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    inline for (spectra, 0..) |expected, spectrum_idx| {
        const actual = decoded[spectrum_idx];
        try std.testing.expectEqualSlices(f64, expected.mz, actual.mz);

        for (0..expected.intensity.len) |peak_idx| {
            try std.testing.expectApproxEqRel(expected.intensity[peak_idx], actual.intensity[peak_idx], 0.01);
        }
    }
}

test "lossy block worst-case intensity error stays below 0.1%" {
    // Build a corpus that exercises many quantization buckets: a wide dynamic
    // range from very low to very high intensity.  With intensity_quant=16384
    // (the production default) the worst-case relative error must stay below
    // 0.1% across all peaks (Phase 1 exit criterion).
    const n = 128;
    var mz_buf: [n]f64 = undefined;
    var int_buf: [n]f32 = undefined;
    for (0..n) |i| {
        mz_buf[i] = 100.0 + @as(f64, @floatFromInt(i)) * 0.125;
        // exponential sweep: 1.0 .. ~1.04e7 covering >7 decades
        int_buf[i] = @floatCast(@exp(@as(f64, @floatFromInt(i)) * (16.0 / @as(f64, n))));
    }

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 0.0, .ms_level = 1, .precursor_mz = 0.0, .mz = mz_buf[0..], .intensity = int_buf[0..] },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossy, .intensity_quant = 16384 });
    defer std.testing.allocator.free(encoded);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    var max_rel_error: f64 = 0.0;
    for (0..n) |i| {
        const orig = @as(f64, int_buf[i]);
        const got = @as(f64, decoded[0].intensity[i]);
        const rel = if (orig == 0.0) @abs(got) else @abs(got - orig) / orig;
        if (rel > max_rel_error) max_rel_error = rel;
    }

    // Phase 1 exit criterion: worst-case relative intensity error < 0.1% (0.001).
    if (max_rel_error >= 0.001) {
        std.debug.print("worst-case intensity rel error {d:.6} >= 0.001 (0.1%)\n", .{max_rel_error});
        return error.TestExpectedLessThan;
    }
}

test "split-exponent: wide-range intensities activate split path and round-trip bit-exact" {
    // 40 peaks cycling through 8 intensity values spanning ~6 decades (2^9..2^28).
    // With 5-bit exponent FOR and the 13-byte overhead, split (158 bytes) < raw (160 bytes),
    // so flag_split_exponent must be set and the round-trip must be bit-exact.
    const intensity_levels = [8]f32{
        512.0,       // 2^9,  biased exp = 136
        4096.0,      // 2^12, biased exp = 139
        32768.0,     // 2^15, biased exp = 142
        262144.0,    // 2^18, biased exp = 145
        2097152.0,   // 2^21, biased exp = 148
        16777216.0,  // 2^24, biased exp = 151
        134217728.0, // 2^27, biased exp = 154
        268435456.0, // 2^28, biased exp = 155
    };
    var mz_buf: [40]f64 = undefined;
    var int_buf: [40]f32 = undefined;
    for (0..40) |i| {
        mz_buf[i] = @as(f64, @floatFromInt(400 + i)); // 400.0 .. 439.0, all f32-exact integers
        int_buf[i] = intensity_levels[i % 8];
    }

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 500.0, .mz = mz_buf[0..], .intensity = int_buf[0..] },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless });
    defer std.testing.allocator.free(encoded);

    const header = try block.parseHeader(encoded);
    // Split-exponent flag must be set; raw flag must NOT be set.
    try std.testing.expect((header.flags & block.flag_split_exponent) != 0);
    try std.testing.expect((header.flags & block.flag_lossless_intensity_raw) == 0);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    // Bit-exact round-trip: every intensity must match exactly.
    try std.testing.expectEqualSlices(f32, int_buf[0..], decoded[0].intensity);
}

test "split-exponent: degenerate small spectrum falls back to raw f32" {
    // 5 peaks all at the same intensity (exponent range = 0, bit_width = 0).
    // split_bytes = 13 + 0 + 3*5 = 28 > raw_bytes = 4*5 = 20 → fallback to raw f32.
    var mz_buf = [_]f64{ 100.0, 200.0, 300.0, 400.0, 500.0 };
    var int_buf = [_]f32{ 1000.0, 1000.0, 1000.0, 1000.0, 1000.0 };

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 300.0, .mz = mz_buf[0..], .intensity = int_buf[0..] },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless });
    defer std.testing.allocator.free(encoded);

    const header = try block.parseHeader(encoded);
    // Dry-run gate must have chosen raw f32 — split flag must NOT be set.
    try std.testing.expect((header.flags & block.flag_split_exponent) == 0);
    try std.testing.expect((header.flags & block.flag_lossless_intensity_raw) != 0);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqualSlices(f32, int_buf[0..], decoded[0].intensity);
}

test "block entropy coding activates on structured m/z and exponent streams" {
    const peak_count = 8192;
    const mz = try std.testing.allocator.alloc(f64, peak_count);
    defer std.testing.allocator.free(mz);
    const intensity = try std.testing.allocator.alloc(f32, peak_count);
    defer std.testing.allocator.free(intensity);

    var current_mz: f64 = 100.0;
    for (0..peak_count) |idx| {
        current_mz += if ((idx & 1) == 0) 0.000000001 else 0.000000002;
        mz[idx] = current_mz;
        const noisy_low_bytes = @as(u32, @truncate((idx *% 2_654_435_761) & 0x00ff_ffff));
        const top_byte: u32 = if ((idx & 1) == 0) 0x44 else 0x45;
        intensity[idx] = @bitCast((top_byte << 24) | noisy_low_bytes);
    }

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 500.0, .mz = mz, .intensity = intensity },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless });
    defer std.testing.allocator.free(encoded);

    const header = try block.parseHeader(encoded);
    try std.testing.expect((header.flags & block.flag_rans_mz) != 0);
    try std.testing.expect((header.flags & block.flag_split_exponent) != 0);
    try std.testing.expect((header.flags & block.flag_rans_intensity) != 0);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try checkMzPpm(mz, decoded[0].mz);
    try std.testing.expectEqualSlices(f32, intensity, decoded[0].intensity);
}

test "block accepts separate mz and intensity rans thresholds" {
    const peak_count = 8192;
    const mz = try std.testing.allocator.alloc(f64, peak_count);
    defer std.testing.allocator.free(mz);
    const intensity = try std.testing.allocator.alloc(f32, peak_count);
    defer std.testing.allocator.free(intensity);

    var current_mz: f64 = 100.0;
    for (0..peak_count) |idx| {
        current_mz += if ((idx & 1) == 0) 0.000000001 else 0.000000002;
        mz[idx] = current_mz;
        const noisy_low_bytes = @as(u32, @truncate((idx *% 2_654_435_761) & 0x00ff_ffff));
        const top_byte: u32 = if ((idx & 1) == 0) 0x44 else 0x45;
        intensity[idx] = @bitCast((top_byte << 24) | noisy_low_bytes);
    }

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 500.0, .mz = mz, .intensity = intensity },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{
        .mode = .lossless,
        .mz_rans_min_gain_percent = 5,
        .intensity_rans_min_gain_percent = 20,
    });
    defer std.testing.allocator.free(encoded);

    const header = try block.parseHeader(encoded);
    try std.testing.expect((header.flags & block.flag_rans_mz) != 0);
    try std.testing.expect((header.flags & block.flag_split_exponent) != 0);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try checkMzPpm(mz, decoded[0].mz);
    try std.testing.expectEqualSlices(f32, intensity, decoded[0].intensity);
}

test "block uses per-spectrum m/z widths when they shrink the payload" {
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
    var current_b: f64 = 1800.000000001;
    for (0..peak_count) |idx| {
        current_a += if ((idx & 1) == 0) 0.000000001 else 0.000000002;
        current_b += if ((idx & 1) == 0) 0.000000041 else 0.000000059;
        mz_a[idx] = current_a;
        mz_b[idx] = current_b;
        intensity_a[idx] = @floatFromInt(100 + idx);
        intensity_b[idx] = @floatFromInt(1000 + idx);
    }

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 500.0, .mz = mz_a, .intensity = intensity_a },
        .{ .scan_id = 2, .rt_seconds = 1.1, .ms_level = 2, .precursor_mz = 501.0, .mz = mz_b, .intensity = intensity_b },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless, .mz_rans_min_gain_percent = 99 });
    defer std.testing.allocator.free(encoded);

    const header = try block.parseHeader(encoded);
    try std.testing.expect((header.flags & block.flag_mz_per_spectrum_bit_widths) != 0);

    const breakdown = try block.inspectBlockByteBreakdown(encoded);
    try std.testing.expect(breakdown.mz_payload_bytes > spectra.len);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, spectra.len), decoded.len);
    try checkMzPpm(mz_a, decoded[0].mz);
    try checkMzPpm(mz_b, decoded[1].mz);
    try std.testing.expectEqualSlices(f32, intensity_a, decoded[0].intensity);
    try std.testing.expectEqualSlices(f32, intensity_b, decoded[1].intensity);
}

test "split-exponent: zero FOR bit-width still activates split when block is large enough" {
    // 20 peaks all at the same intensity (exponent range = 0, bit_width = 0).
    // split_bytes = 13 + 0 + 3*20 = 73 < raw_bytes = 4*20 = 80 → split wins.
    // The zero-length FOR exponent payload exercises the empty-payload code path
    // in both encoder and decoder. This mirrors split_exp_degenerate.bin.
    var mz_buf: [20]f64 = undefined;
    var int_buf: [20]f32 = undefined;
    for (0..20) |i| {
        mz_buf[i] = @as(f64, @floatFromInt(500 + i));
        // All same intensity → biased exponent = 140 (2^13)
        int_buf[i] = 8192.0;
    }

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 300.0, .mz = mz_buf[0..], .intensity = int_buf[0..] },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless });
    defer std.testing.allocator.free(encoded);

    const header = try block.parseHeader(encoded);
    // Split must activate (20 peaks pushes it over the edge).
    try std.testing.expect((header.flags & block.flag_split_exponent) != 0);
    try std.testing.expect((header.flags & block.flag_lossless_intensity_raw) == 0);
    // Zero range → zero-length FOR payload, so rANS on exponent stream
    // is never attempted (raw.len == 0 short-circuits in maybeEncodeRansAlloc).
    try std.testing.expect((header.flags & block.flag_rans_intensity) == 0);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    // Every intensity must reconstruct exactly from base exponent alone.
    try std.testing.expectEqualSlices(f32, int_buf[0..], decoded[0].intensity);
}

test "split-exponent: narrow range with 2 exponent levels activates split and round-trips" {
    // 40 peaks with biased exponents 143 (2^16) and 144 (2^17) only.
    // FOR bit_width = 1; split_bytes = 13 + ceil(1*40/8) + 3*40 = 13 + 5 + 120 = 138.
    // raw_bytes = 4*40 = 160 → split wins by 22 bytes. Mirrors split_exp_narrow.bin.
    var mz_buf: [40]f64 = undefined;
    var int_buf: [40]f32 = undefined;
    for (0..40) |i| {
        mz_buf[i] = @as(f64, @floatFromInt(400 + i));
        // Alternate between biased exponent 143 (65536.0) and 144 (131072.0).
        int_buf[i] = if (i % 2 == 0) @as(f32, 65536.0) else @as(f32, 131072.0);
    }

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 500.0, .mz = mz_buf[0..], .intensity = int_buf[0..] },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless });
    defer std.testing.allocator.free(encoded);

    const header = try block.parseHeader(encoded);
    try std.testing.expect((header.flags & block.flag_split_exponent) != 0);
    try std.testing.expect((header.flags & block.flag_lossless_intensity_raw) == 0);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqualSlices(f32, int_buf[0..], decoded[0].intensity);
}

test "split-exponent: split_plain mode activates when rANS gain is below threshold" {
    // 32 peaks with moderate intensity range (3 exponent levels).
    // Split wins but rANS is suppressed via min_gain_percent = 99.
    // Assert flag_split_exponent is set, flag_rans_intensity is NOT set.
    var mz_buf: [32]f64 = undefined;
    var int_buf: [32]f32 = undefined;
    for (0..32) |i| {
        mz_buf[i] = @as(f64, @floatFromInt(300 + i));
        // Three exponent levels: 2^14 (16384), 2^15 (32768), 2^16 (65536).
        int_buf[i] = switch (i % 3) {
            0 => @as(f32, 16384.0),
            1 => @as(f32, 32768.0),
            else => @as(f32, 65536.0),
        };
    }

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 500.0, .mz = mz_buf[0..], .intensity = int_buf[0..] },
    };

    const encoded = try block.encodeBlock(std.testing.allocator, &spectra, .{
        .mode = .lossless,
        .intensity_rans_min_gain_percent = 99,
    });
    defer std.testing.allocator.free(encoded);

    const header = try block.parseHeader(encoded);
    try std.testing.expect((header.flags & block.flag_split_exponent) != 0);
    try std.testing.expect((header.flags & block.flag_lossless_intensity_raw) == 0);
    // rANS must NOT activate because the gain threshold is too high.
    try std.testing.expect((header.flags & block.flag_rans_intensity) == 0);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqualSlices(f32, int_buf[0..], decoded[0].intensity);
}
