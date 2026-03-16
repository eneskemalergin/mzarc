const std = @import("std");
const binary_reader = @import("binary_reader");
const codec_v1 = @import("codec_v1");

test "codec_v1 round-trip preserves spectra within stream order" {
    var mz_ms2_a = [_]f64{ 400.0, 401.0 };
    var intensity_ms2_a = [_]f32{ 10.0, 11.0 };
    var mz_ms1 = [_]f64{ 100.0, 100.000002, 101.0 };
    var intensity_ms1 = [_]f32{ 1.0, 2.0, 3.0 };
    var mz_ms2_b = [_]f64{500.0};
    var intensity_ms2_b = [_]f32{5.0};

    const input = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 20, .rt_seconds = 2.0, .ms_level = 2, .precursor_mz = 600.1, .mz = mz_ms2_a[0..], .intensity = intensity_ms2_a[0..] },
        .{ .scan_id = 10, .rt_seconds = 1.0, .ms_level = 1, .precursor_mz = 0.0, .mz = mz_ms1[0..], .intensity = intensity_ms1[0..] },
        .{ .scan_id = 21, .rt_seconds = 2.2, .ms_level = 2, .precursor_mz = 600.2, .mz = mz_ms2_b[0..], .intensity = intensity_ms2_b[0..] },
    };

    const encoded = try codec_v1.encodeFileAlloc(std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossless }, .block_size = 2 });
    defer std.testing.allocator.free(encoded);

    const inspection = try codec_v1.inspectAlloc(std.testing.allocator, encoded);
    defer codec_v1.freeInspection(std.testing.allocator, inspection);

    try std.testing.expectEqual(@as(u32, 3), inspection.header.spectrum_count);
    try std.testing.expectEqual(@as(u32, 2), inspection.header.block_count);
    try std.testing.expectEqual(@as(usize, 1), inspection.ms1_block_count);
    try std.testing.expectEqual(@as(usize, 1), inspection.ms2_block_count);

    const decoded = try codec_v1.decodeFileAlloc(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, 3), decoded.len);

    try std.testing.expectEqual(@as(u32, 10), decoded[0].scan_id);
    try std.testing.expectEqual(@as(u8, 1), decoded[0].ms_level);
    try std.testing.expectEqualSlices(f64, mz_ms1[0..], decoded[0].mz);

    try std.testing.expectEqual(@as(u32, 20), decoded[1].scan_id);
    try std.testing.expectEqual(@as(u8, 2), decoded[1].ms_level);
    try std.testing.expectEqualSlices(f64, mz_ms2_a[0..], decoded[1].mz);

    try std.testing.expectEqual(@as(u32, 21), decoded[2].scan_id);
    try std.testing.expectEqual(@as(u8, 2), decoded[2].ms_level);
    try std.testing.expectEqualSlices(f64, mz_ms2_b[0..], decoded[2].mz);
}

test "codec_v1 lossy round-trip keeps counts and flags consistent" {
    var mz_ms1 = [_]f64{ 100.0, 100.5, 101.25 };
    var intensity_ms1 = [_]f32{ 0.5, 10.0, 100.0 };
    var mz_ms2 = [_]f64{ 400.0, 401.0 };
    var intensity_ms2 = [_]f32{ 5.0, 25.0 };

    const input = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 1, .precursor_mz = 0.0, .mz = mz_ms1[0..], .intensity = intensity_ms1[0..] },
        .{ .scan_id = 2, .rt_seconds = 2.0, .ms_level = 2, .precursor_mz = 500.0, .mz = mz_ms2[0..], .intensity = intensity_ms2[0..] },
    };

    const encoded = try codec_v1.encodeFileAlloc(std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossy, .intensity_quant = 4096 }, .block_size = 128 });
    defer std.testing.allocator.free(encoded);

    const inspection = try codec_v1.inspectAlloc(std.testing.allocator, encoded);
    defer codec_v1.freeInspection(std.testing.allocator, inspection);

    try std.testing.expectEqual(@as(u16, 128), inspection.header.block_size);
    try std.testing.expect((inspection.header.flags & codec_v1.flag_lossless) == 0);
    try std.testing.expect((inspection.header.flags & codec_v1.flag_contains_ms1) != 0);
    try std.testing.expect((inspection.header.flags & codec_v1.flag_contains_ms2) != 0);
    try std.testing.expectEqual(@as(u64, 5), inspection.header.total_peaks);
}
