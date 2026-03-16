const std = @import("std");
const binary_reader = @import("binary_reader");

test "binary dump round-trip preserves spectra" {
    var mz_1 = [_]f64{ 100.0, 101.5, 150.25 };
    var intensity_1 = [_]f32{ 10.0, 20.0, 30.0 };
    var mz_2 = [_]f64{ 200.0, 250.0 };
    var intensity_2 = [_]f32{ 1.5, 0.0 };

    const spectra = [_]binary_reader.RawSpectrum{
        .{
            .scan_id = 42,
            .rt_seconds = 12.5,
            .ms_level = 1,
            .precursor_mz = 0.0,
            .mz = mz_1[0..],
            .intensity = intensity_1[0..],
        },
        .{
            .scan_id = 43,
            .rt_seconds = 13.25,
            .ms_level = 2,
            .precursor_mz = 555.5,
            .mz = mz_2[0..],
            .intensity = intensity_2[0..],
        },
    };

    const dump_bytes = try binary_reader.writeDumpAlloc(std.testing.allocator, &spectra);
    defer std.testing.allocator.free(dump_bytes);

    const loaded = try binary_reader.parseDump(dump_bytes, std.testing.allocator);
    defer binary_reader.freeSpectra(std.testing.allocator, loaded);

    try std.testing.expectEqual(@as(usize, spectra.len), loaded.len);

    inline for (spectra, 0..) |expected, idx| {
        const actual = loaded[idx];
        try std.testing.expectEqual(expected.scan_id, actual.scan_id);
        try std.testing.expectEqual(expected.rt_seconds, actual.rt_seconds);
        try std.testing.expectEqual(expected.ms_level, actual.ms_level);
        try std.testing.expectEqual(expected.precursor_mz, actual.precursor_mz);
        try std.testing.expectEqualSlices(f64, expected.mz, actual.mz);
        try std.testing.expectEqualSlices(f32, expected.intensity, actual.intensity);
    }
}

test "binary dump supports empty spectra" {
    const empty_mz = [_]f64{};
    const empty_intensity = [_]f32{};

    const spectra = [_]binary_reader.RawSpectrum{
        .{
            .scan_id = 99,
            .rt_seconds = 1.0,
            .ms_level = 2,
            .precursor_mz = 444.0,
            .mz = empty_mz[0..],
            .intensity = empty_intensity[0..],
        },
    };

    const dump_bytes = try binary_reader.writeDumpAlloc(std.testing.allocator, &spectra);
    defer std.testing.allocator.free(dump_bytes);

    const loaded = try binary_reader.parseDump(dump_bytes, std.testing.allocator);
    defer binary_reader.freeSpectra(std.testing.allocator, loaded);

    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqual(@as(usize, 0), loaded[0].mz.len);
    try std.testing.expectEqual(@as(usize, 0), loaded[0].intensity.len);
}
