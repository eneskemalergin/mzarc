//! Exercises Dump V1 round trips, malformed input, and bounded indexing.

const std = @import("std");
const binary_reader = @import("binary_reader");

const KNOWN_DUMP_V1 = [_]u8{
    0x01, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x80, 0x3f,
    0x01, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x59, 0x40,
    0x00, 0x00, 0x20, 0x41,
};

test "[integration] - [dump V1 bytes]: matches a hand-written record" {
    var mz = [_]f64{100.0};
    var intensity = [_]f32{10.0};
    const spectra = [_]binary_reader.RawSpectrum{.{
        .scan_id = 1,
        .rt_seconds = 1.0,
        .ms_level = 1,
        .precursor_mz = 0.0,
        .mz = &mz,
        .intensity = &intensity,
    }};

    const written = try binary_reader.writeDumpAlloc(std.testing.allocator, &spectra);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualSlices(u8, &KNOWN_DUMP_V1, written);

    const parsed = try binary_reader.parseDump(&KNOWN_DUMP_V1, std.testing.allocator);
    defer binary_reader.freeSpectra(std.testing.allocator, parsed);
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqual(@as(u32, 1), parsed[0].scan_id);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 1.0))), @as(u32, @bitCast(parsed[0].rt_seconds)));
    try std.testing.expectEqual(@as(u8, 1), parsed[0].ms_level);
    try std.testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(parsed[0].precursor_mz)));
    try std.testing.expectEqualSlices(f64, &mz, parsed[0].mz);
    try std.testing.expectEqualSlices(f32, &intensity, parsed[0].intensity);
}

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

test "binary dump parser rejects truncated payloads" {
    var mz = [_]f64{ 100.0, 100.00000125 };
    var intensity = [_]f32{ 1.0, 2.0 };

    const spectra = [_]binary_reader.RawSpectrum{
        .{
            .scan_id = 7,
            .rt_seconds = 3.5,
            .ms_level = 1,
            .precursor_mz = 0.0,
            .mz = mz[0..],
            .intensity = intensity[0..],
        },
    };

    const dump_bytes = try binary_reader.writeDumpAlloc(std.testing.allocator, &spectra);
    defer std.testing.allocator.free(dump_bytes);

    try std.testing.expectError(
        error.UnexpectedEndOfStream,
        binary_reader.parseDump(dump_bytes[0 .. dump_bytes.len - 1], std.testing.allocator),
    );
}

test "binary dump writer rejects mismatched peak arrays" {
    var mz = [_]f64{ 100.0, 101.0 };
    var intensity = [_]f32{1.0};

    const spectra = [_]binary_reader.RawSpectrum{
        .{
            .scan_id = 1,
            .rt_seconds = 0.0,
            .ms_level = 1,
            .precursor_mz = 0.0,
            .mz = mz[0..],
            .intensity = intensity[0..],
        },
    };

    try std.testing.expectError(
        error.MismatchedPeakArrays,
        binary_reader.writeDumpAlloc(std.testing.allocator, &spectra),
    );
}

test "[failure] - [dump V1 index]: stops at the caller spectrum limit" {
    var empty_mz: [0]f64 = .{};
    var empty_intensity: [0]f32 = .{};
    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 1, .precursor_mz = 0.0, .mz = &empty_mz, .intensity = &empty_intensity },
        .{ .scan_id = 2, .rt_seconds = 2.0, .ms_level = 1, .precursor_mz = 0.0, .mz = &empty_mz, .intensity = &empty_intensity },
        .{ .scan_id = 3, .rt_seconds = 3.0, .ms_level = 1, .precursor_mz = 0.0, .mz = &empty_mz, .intensity = &empty_intensity },
    };
    const dump = try binary_reader.writeDumpAlloc(std.testing.allocator, &spectra);
    defer std.testing.allocator.free(dump);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input = try tmp.dir.createFile(std.testing.io, "input.bin", .{ .read = true });
    defer input.close(std.testing.io);
    try input.writePositionalAll(std.testing.io, dump, 0);

    try std.testing.expectError(
        error.FileResourceLimit,
        binary_reader.scanFile(std.testing.allocator, std.testing.io, input, 2),
    );
}

test "[failure] - [Dump V1 reserved bytes]: rejects nonzero record padding" {
    var mz = [_]f64{100.0};
    var intensity = [_]f32{1.0};
    const spectra = [_]binary_reader.RawSpectrum{.{
        .scan_id = 1,
        .rt_seconds = 1.0,
        .ms_level = 1,
        .precursor_mz = 0.0,
        .mz = &mz,
        .intensity = &intensity,
    }};
    const dump = try binary_reader.writeDumpAlloc(std.testing.allocator, &spectra);
    defer std.testing.allocator.free(dump);

    const bad_first_padding = try std.testing.allocator.dupe(u8, dump);
    defer std.testing.allocator.free(bad_first_padding);
    bad_first_padding[9] = 1;
    try std.testing.expectError(
        error.NonzeroReserved,
        binary_reader.parseDump(bad_first_padding, std.testing.allocator),
    );

    const bad_second_padding = try std.testing.allocator.dupe(u8, dump);
    defer std.testing.allocator.free(bad_second_padding);
    bad_second_padding[24] = 1;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input = try tmp.dir.createFile(std.testing.io, "input.bin", .{ .read = true });
    defer input.close(std.testing.io);
    try input.writePositionalAll(std.testing.io, bad_second_padding, 0);
    try std.testing.expectError(
        error.NonzeroReserved,
        binary_reader.scanFile(std.testing.allocator, std.testing.io, input, 1),
    );
}

fn streamRecords(bytes: []const u8, max_peaks: usize) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = bytes });
    const file = try tmp.dir.openFile(std.testing.io, "input.bin", .{});
    defer file.close(std.testing.io);

    var buffer: [16]u8 = undefined;
    var records = binary_reader.RecordReader.init(std.testing.io, file, &buffer, max_peaks);
    defer records.deinit(std.testing.allocator);
    while (try records.next(std.testing.allocator)) |_| {}
}

fn countedRecords(bytes: []const u8, max_records: usize, max_peaks: usize) !usize {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = bytes });
    const file = try tmp.dir.openFile(std.testing.io, "input.bin", .{});
    defer file.close(std.testing.io);
    return binary_reader.countRecords(std.testing.io, file, max_records, max_peaks);
}

test "[integration] - [dump V1 record reader]: streams the records parseDump returns" {
    var mz_a = [_]f64{ 100.0, 100.5, std.math.inf(f64) };
    var intensity_a = [_]f32{ 1.0, -0.0, std.math.nan(f32) };
    var empty_mz: [0]f64 = .{};
    var empty_intensity: [0]f32 = .{};
    var mz_b = [_]f64{250.25};
    var intensity_b = [_]f32{7.5};
    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 3, .rt_seconds = -0.0, .ms_level = 3, .precursor_mz = 0.0, .mz = &mz_a, .intensity = &intensity_a },
        .{ .scan_id = 1, .rt_seconds = 2.0, .ms_level = 1, .precursor_mz = 0.0, .mz = &empty_mz, .intensity = &empty_intensity },
        .{ .scan_id = 2, .rt_seconds = 3.0, .ms_level = 2, .precursor_mz = 412.5, .mz = &mz_b, .intensity = &intensity_b },
    };
    const dump = try binary_reader.writeDumpAlloc(std.testing.allocator, &spectra);
    defer std.testing.allocator.free(dump);
    const expected = try binary_reader.parseDump(dump, std.testing.allocator);
    defer binary_reader.freeSpectra(std.testing.allocator, expected);

    try std.testing.expectEqual(@as(usize, spectra.len), try countedRecords(dump, spectra.len, 3));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = dump });
    const file = try tmp.dir.openFile(std.testing.io, "input.bin", .{});
    defer file.close(std.testing.io);
    // A buffer smaller than one record makes every record cross a refill.
    var buffer: [16]u8 = undefined;
    var records = binary_reader.RecordReader.init(std.testing.io, file, &buffer, 3);
    defer records.deinit(std.testing.allocator);
    for (expected) |want| {
        const got = (try records.next(std.testing.allocator)).?;
        try std.testing.expectEqual(want.scan_id, got.scan_id);
        try std.testing.expectEqual(@as(u32, @bitCast(want.rt_seconds)), @as(u32, @bitCast(got.rt_seconds)));
        try std.testing.expectEqual(want.ms_level, got.ms_level);
        try std.testing.expectEqual(@as(u64, @bitCast(want.precursor_mz)), @as(u64, @bitCast(got.precursor_mz)));
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(want.mz), std.mem.sliceAsBytes(got.mz));
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(want.intensity), std.mem.sliceAsBytes(got.intensity));
    }
    try std.testing.expectEqual(@as(?binary_reader.RawSpectrum, null), try records.next(std.testing.allocator));
}

test "[failure] - [dump V1 record reader]: rejects truncation, reserved bytes, and limits" {
    var mz_a = [_]f64{ 100.0, 101.0 };
    var intensity_a = [_]f32{ 1.0, 2.0 };
    var mz_b = [_]f64{200.0};
    var intensity_b = [_]f32{3.0};
    const spectra = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 1, .precursor_mz = 0.0, .mz = &mz_a, .intensity = &intensity_a },
        .{ .scan_id = 2, .rt_seconds = 2.0, .ms_level = 2, .precursor_mz = 300.0, .mz = &mz_b, .intensity = &intensity_b },
    };
    const dump = try binary_reader.writeDumpAlloc(std.testing.allocator, &spectra);
    defer std.testing.allocator.free(dump);
    const first_record_len: usize = @intCast(try binary_reader.recordLen(2));

    for (1..dump.len) |len| {
        if (len == first_record_len) continue;
        try std.testing.expectError(error.UnexpectedEndOfStream, countedRecords(dump[0..len], 2, 2));
        try std.testing.expectError(error.UnexpectedEndOfStream, streamRecords(dump[0..len], 2));
    }

    const reserved = try std.testing.allocator.dupe(u8, dump);
    defer std.testing.allocator.free(reserved);
    reserved[first_record_len + 25] = 1;
    try std.testing.expectError(error.NonzeroReserved, countedRecords(reserved, 2, 2));
    try std.testing.expectError(error.NonzeroReserved, streamRecords(reserved, 2));

    try std.testing.expectError(error.BlockResourceLimit, countedRecords(dump, 2, 1));
    try std.testing.expectError(error.BlockResourceLimit, streamRecords(dump, 1));
    try std.testing.expectError(error.FileResourceLimit, countedRecords(dump, 1, 2));
}
