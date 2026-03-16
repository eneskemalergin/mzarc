const std = @import("std");
const binary_reader = @import("binary_reader");
const block_v1 = @import("block_v1");

test "lossless block round-trip preserves aligned spectra exactly" {
    var mz_1 = [_]f64{ 100.0, 100.000002, 101.5 };
    var intensity_1 = [_]f32{ 10.0, 20.0, 30.0 };
    var mz_2 = [_]f64{ 200.0, 200.000004 };
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
