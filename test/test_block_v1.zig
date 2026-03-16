const std = @import("std");
const binary_reader = @import("binary_reader");
const block_v1 = @import("block_v1");

test "lossless block round-trip preserves aligned spectra exactly" {
    var mz_1 = [_]f64{ 100.0, 100.00000125, 101.500000375 };
    var intensity_1 = [_]f32{ 10.0, 20.0, 30.0 };
    var mz_2 = [_]f64{ 200.0, 200.0000035 };
    var intensity_2 = [_]f32{ 5.0, 1.5 };

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 10.0, .ms_level = 2, .precursor_mz = 500.25, .mz = mz_1[0..], .intensity = intensity_1[0..] },
        .{ .scan_id = 2, .rt_seconds = 10.5, .ms_level = 2, .precursor_mz = 500.75, .mz = mz_2[0..], .intensity = intensity_2[0..] },
    };

    const encoded = try block_v1.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless });
    defer std.testing.allocator.free(encoded);

    const header = try block_v1.parseHeader(encoded);
    try std.testing.expectEqual(@as(u16, 2), header.spectrum_count);
    try std.testing.expect((header.flags & block_v1.flag_lossless_intensity_raw) != 0);
    try std.testing.expect((header.flags & block_v1.flag_lossless_mz_raw) != 0);
    try std.testing.expect((header.flags & block_v1.flag_lossless_mz_xor) != 0);

    const decoded = try block_v1.decodeBlock(std.testing.allocator, encoded);
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
    const empty_mz = [_]f64{};
    const empty_intensity = [_]f32{};
    var mz_single = [_]f64{123.00000125};
    var intensity_single = [_]f32{42.0};
    var mz_dense = [_]f64{ 500.00000125, 500.0000015, 500.00000375, 501.000000125 };
    var intensity_dense = [_]f32{ 0.0, 1.0, 10.0, 1000.0 };
    var mz_tail = [_]f64{ 900.125000125, 900.1250005 };
    var intensity_tail = [_]f32{ 7.5, 8.5 };

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 10, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 444.1, .mz = empty_mz[0..], .intensity = empty_intensity[0..] },
        .{ .scan_id = 11, .rt_seconds = 1.1, .ms_level = 2, .precursor_mz = 444.2, .mz = mz_single[0..], .intensity = intensity_single[0..] },
        .{ .scan_id = 12, .rt_seconds = 1.2, .ms_level = 2, .precursor_mz = 444.3, .mz = mz_dense[0..], .intensity = intensity_dense[0..] },
        .{ .scan_id = 13, .rt_seconds = 1.3, .ms_level = 2, .precursor_mz = 444.4, .mz = mz_tail[0..], .intensity = intensity_tail[0..] },
    };

    const encoded = try block_v1.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless });
    defer std.testing.allocator.free(encoded);

    const decoded = try block_v1.decodeBlock(std.testing.allocator, encoded);
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

    try std.testing.expectError(error.MixedMsLevel, block_v1.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless }));
}

test "lossless block encoding rejects non-monotonic m/z arrays" {
    var mz = [_]f64{ 300.0, 299.5, 301.0 };
    var intensity = [_]f32{ 1.0, 2.0, 3.0 };

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 5, .rt_seconds = 5.0, .ms_level = 1, .precursor_mz = 0.0, .mz = mz[0..], .intensity = intensity[0..] },
    };

    try std.testing.expectError(error.NonMonotonicInput, block_v1.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless }));
}

test "block decode rejects checksum corruption" {
    var mz = [_]f64{ 700.00000125, 700.00000375 };
    var intensity = [_]f32{ 8.0, 9.0 };

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 77, .rt_seconds = 7.7, .ms_level = 2, .precursor_mz = 777.7, .mz = mz[0..], .intensity = intensity[0..] },
    };

    const encoded = try block_v1.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless });
    defer std.testing.allocator.free(encoded);

    const corrupted = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(corrupted);
    corrupted[block_v1.header_len] ^= 0x01;

    try std.testing.expectError(error.ChecksumMismatch, block_v1.decodeBlock(std.testing.allocator, corrupted));
}

test "block decode rejects mismatched peak totals" {
    var mz = [_]f64{ 700.00000125, 700.00000375 };
    var intensity = [_]f32{ 8.0, 9.0 };

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 77, .rt_seconds = 7.7, .ms_level = 2, .precursor_mz = 777.7, .mz = mz[0..], .intensity = intensity[0..] },
    };

    const encoded = try block_v1.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless });
    defer std.testing.allocator.free(encoded);

    const corrupted = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(corrupted);
    std.mem.writeInt(u32, corrupted[4..8], 3, .little);

    try std.testing.expectError(error.InvalidPeakCount, block_v1.decodeBlock(std.testing.allocator, corrupted));
}

test "block decode rejects trailing payload bytes" {
    var mz = [_]f64{ 710.00000125, 710.00000375 };
    var intensity = [_]f32{ 4.0, 5.0 };

    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 88, .rt_seconds = 8.8, .ms_level = 2, .precursor_mz = 888.8, .mz = mz[0..], .intensity = intensity[0..] },
    };

    const encoded = try block_v1.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossless });
    defer std.testing.allocator.free(encoded);

    const extended = try std.testing.allocator.alloc(u8, encoded.len + 1);
    defer std.testing.allocator.free(extended);
    @memcpy(extended[0..encoded.len], encoded);
    extended[encoded.len] = 0;

    const new_payload_len = (encoded.len - block_v1.header_len) + 1;
    std.mem.writeInt(u32, extended[28..32], @intCast(new_payload_len), .little);
    const new_checksum = std.hash.crc.Crc32.hash(extended[block_v1.header_len..]);
    std.mem.writeInt(u32, extended[36..40], new_checksum, .little);

    try std.testing.expectError(error.TrailingBlockPayload, block_v1.decodeBlock(std.testing.allocator, extended));
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

    const encoded = try block_v1.encodeBlock(std.testing.allocator, &spectra, .{ .mode = .lossy, .intensity_quant = 4096 });
    defer std.testing.allocator.free(encoded);

    const header = try block_v1.parseHeader(encoded);
    try std.testing.expectEqual(@as(u8, 0), header.flags & block_v1.flag_lossless_intensity_raw);

    const decoded = try block_v1.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    inline for (spectra, 0..) |expected, spectrum_idx| {
        const actual = decoded[spectrum_idx];
        try std.testing.expectEqualSlices(f64, expected.mz, actual.mz);

        for (0..expected.intensity.len) |peak_idx| {
            try std.testing.expectApproxEqRel(expected.intensity[peak_idx], actual.intensity[peak_idx], 0.01);
        }
    }
}
