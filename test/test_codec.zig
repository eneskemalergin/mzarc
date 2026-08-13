//! Exercises `.mzarc` layout, version rejection, fidelity, and file orchestration.

const std = @import("std");
const binary_reader = @import("binary_reader");
const block = @import("block");
const codec = @import("codec");
const quantize = @import("quantize");

const KNOWN_MZARC = [_]u8{
    0x4d, 0x5a, 0x41, 0x52, 0x01, 0x00, 0x00, 0x00,
    0x0b, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x39,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x80, 0x3f,
    0x3f, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00,
    0xe6, 0x91, 0xc5, 0xc1, 0x00, 0x01, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x80, 0x3f, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x04, 0x00, 0x00, 0xc8, 0x42, 0x00,
    0x00, 0x20, 0x41,
};

const KNOWN_MZARC_FUZZ_CORPUS = [_]u8{ @intCast(KNOWN_MZARC.len), 0x00, 0x00, 0x00 } ++ KNOWN_MZARC;

fn tmpPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], name });
}

fn expectFileContents(path: []const u8, expected: []const u8) !void {
    const actual = try codec.readFileAlloc(std.testing.io, path, std.testing.allocator);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

fn expectMzBits(expected_mz: []const f64, actual_mz: []const f64) !void {
    try std.testing.expectEqual(expected_mz.len, actual_mz.len);
    for (expected_mz, actual_mz) |expected, actual| {
        try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(actual)));
    }
}

fn expectLosslessRoundTrip(expected: []const binary_reader.RawSpectrum, actual: []const binary_reader.RawSpectrum) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |exp, act| {
        try std.testing.expectEqual(exp.scan_id, act.scan_id);
        try std.testing.expectEqual(
            @as(u32, @bitCast(exp.rt_seconds)),
            @as(u32, @bitCast(act.rt_seconds)),
        );
        try std.testing.expectEqual(exp.ms_level, act.ms_level);
        try std.testing.expectEqual(
            @as(u64, @bitCast(exp.precursor_mz)),
            @as(u64, @bitCast(act.precursor_mz)),
        );
        try expectMzBits(exp.mz, act.mz);
        try std.testing.expectEqual(exp.intensity.len, act.intensity.len);
        for (exp.intensity, act.intensity) |expected_intensity, actual_intensity| {
            try std.testing.expectEqual(
                @as(u32, @bitCast(expected_intensity)),
                @as(u32, @bitCast(actual_intensity)),
            );
        }
    }
}

fn fuzzInspectMzarc(_: void, smith: *std.testing.Smith) !void {
    var storage: [256]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const inspection = codec.inspectAlloc(std.testing.allocator, storage[0..len]) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    codec.freeInspection(std.testing.allocator, inspection);
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

test "[integration] - [format 1.0 bytes]: matches a hand-written archive" {
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

    const written = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, &spectra, .{
        .block_options = .{ .mode = .lossless },
        .block_size = 1,
    });
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualSlices(u8, &KNOWN_MZARC, written);

    const inspection = try codec.inspectAlloc(std.testing.allocator, &KNOWN_MZARC);
    defer codec.freeInspection(std.testing.allocator, inspection);
    try std.testing.expectEqual(@as(u16, 1), inspection.header.version_major);
    try std.testing.expectEqual(@as(u16, 0), inspection.header.version_minor);
    try std.testing.expectEqual(@as(u32, 1), inspection.header.spectrum_count);
    try std.testing.expectEqual(@as(u32, 1), inspection.header.block_count);
    try std.testing.expectEqual(@as(u64, 1), inspection.header.total_peaks);

    const decoded = try codec.decodeFileAlloc(std.testing.io, std.testing.allocator, &KNOWN_MZARC, .{});
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);
    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqual(@as(u32, 1), decoded[0].scan_id);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 1.0))), @as(u32, @bitCast(decoded[0].rt_seconds)));
    try std.testing.expectEqual(@as(u8, 1), decoded[0].ms_level);
    try std.testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(decoded[0].precursor_mz)));
    try expectMzBits(&mz, decoded[0].mz);
    try std.testing.expectEqualSlices(f32, &intensity, decoded[0].intensity);
}

test "[failure] - [format 1.0 truncation]: rejects every proper prefix" {
    for (0..KNOWN_MZARC.len) |len| {
        try std.testing.expectError(
            error.UnexpectedEndOfStream,
            codec.inspectAlloc(std.testing.allocator, KNOWN_MZARC[0..len]),
        );
    }
}

test "[fuzz] - [.mzarc inspector]: handles bounded arbitrary bytes without leaking" {
    try std.testing.fuzz({}, fuzzInspectMzarc, .{
        .corpus = &.{&KNOWN_MZARC_FUZZ_CORPUS},
    });
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

    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossless }, .block_size = 2 });
    defer std.testing.allocator.free(encoded);

    const inspection = try codec.inspectAlloc(std.testing.allocator, encoded);
    defer codec.freeInspection(std.testing.allocator, inspection);

    try std.testing.expectEqual(@as(u32, 3), inspection.header.spectrum_count);
    try std.testing.expectEqual(@as(u32, 2), inspection.header.block_count);
    try std.testing.expect((inspection.header.flags & codec.flag_has_global_order) != 0);
    try std.testing.expectEqual(@as(usize, 1), inspection.ms1_block_count);
    try std.testing.expectEqual(@as(usize, 1), inspection.ms2_block_count);

    const decoded = try codec.decodeFileAlloc(std.testing.io, std.testing.allocator, encoded, .{});
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

    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossless }, .block_size = 2 });
    defer std.testing.allocator.free(encoded);

    const inspection = try codec.inspectAlloc(std.testing.allocator, encoded);
    defer codec.freeInspection(std.testing.allocator, inspection);

    try std.testing.expectEqual(@as(u32, 8), inspection.header.spectrum_count);
    try std.testing.expectEqual(@as(u32, 4), inspection.header.block_count);
    try std.testing.expectEqual(@as(usize, 2), inspection.ms1_block_count);
    try std.testing.expectEqual(@as(usize, 2), inspection.ms2_block_count);

    const decoded = try codec.decodeFileAlloc(std.testing.io, std.testing.allocator, encoded, .{});
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, input.len), decoded.len);
    inline for (input, 0..) |expected, idx| {
        try std.testing.expectEqual(expected.scan_id, decoded[idx].scan_id);
        try std.testing.expectEqual(expected.ms_level, decoded[idx].ms_level);
    }
    try expectLosslessRoundTrip(&input, decoded);
}

test "[failure] - [global order table]: inspector and decoder reject duplicates" {
    var mz_ms2 = [_]f64{400.00000125};
    var intensity_ms2 = [_]f32{10.0};
    var mz_ms1 = [_]f64{100.00000125};
    var intensity_ms1 = [_]f32{1.0};

    const input = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 20, .rt_seconds = 2.0, .ms_level = 2, .precursor_mz = 600.1, .mz = mz_ms2[0..], .intensity = intensity_ms2[0..] },
        .{ .scan_id = 10, .rt_seconds = 1.0, .ms_level = 1, .precursor_mz = 0.0, .mz = mz_ms1[0..], .intensity = intensity_ms1[0..] },
    };

    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossless }, .block_size = 1 });
    defer std.testing.allocator.free(encoded);

    const tampered = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(tampered);

    const order_offset = codec.header_len;
    std.mem.writeInt(u32, tampered[order_offset..][0..@sizeOf(u32)], 0, .little);
    std.mem.writeInt(u32, tampered[order_offset + @sizeOf(u32) ..][0..@sizeOf(u32)], 0, .little);

    try std.testing.expectError(
        error.InvalidOrderTable,
        codec.inspectAlloc(std.testing.allocator, tampered),
    );
    try std.testing.expectError(error.InvalidOrderTable, codec.decodeFileAlloc(std.testing.io, std.testing.allocator, tampered, .{}));
}

test "[failure] - [.mzarc totals]: rejects spectrum counts that disagree with blocks" {
    var mz_a = [_]f64{100.00000125};
    var intensity_a = [_]f32{1.0};
    var mz_b = [_]f64{200.00000125};
    var intensity_b = [_]f32{2.0};
    const input = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 10, .rt_seconds = 1.0, .ms_level = 1, .precursor_mz = 0.0, .mz = mz_a[0..], .intensity = intensity_a[0..] },
        .{ .scan_id = 11, .rt_seconds = 2.0, .ms_level = 1, .precursor_mz = 0.0, .mz = mz_b[0..], .intensity = intensity_b[0..] },
    };

    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossless }, .block_size = 2 });
    defer std.testing.allocator.free(encoded);

    const blocks = encoded[codec.header_len + @sizeOf(u32) * input.len ..];

    var inflated: std.ArrayList(u8) = .empty;
    defer inflated.deinit(std.testing.allocator);
    try inflated.appendSlice(std.testing.allocator, encoded[0..codec.header_len]);
    std.mem.writeInt(u32, inflated.items[16..20], 3, .little);
    var inflated_order: [12]u8 = undefined;
    std.mem.writeInt(u32, inflated_order[0..4], 0, .little);
    std.mem.writeInt(u32, inflated_order[4..8], 1, .little);
    std.mem.writeInt(u32, inflated_order[8..12], 2, .little);
    try inflated.appendSlice(std.testing.allocator, &inflated_order);
    try inflated.appendSlice(std.testing.allocator, blocks);
    try std.testing.expectError(error.FileCountMismatch, codec.decodeFileAlloc(std.testing.io, std.testing.allocator, inflated.items, .{}));

    var deflated: std.ArrayList(u8) = .empty;
    defer deflated.deinit(std.testing.allocator);
    try deflated.appendSlice(std.testing.allocator, encoded[0..codec.header_len]);
    std.mem.writeInt(u32, deflated.items[16..20], 1, .little);
    var deflated_order: [4]u8 = undefined;
    std.mem.writeInt(u32, deflated_order[0..4], 0, .little);
    try deflated.appendSlice(std.testing.allocator, &deflated_order);
    try deflated.appendSlice(std.testing.allocator, blocks);
    try std.testing.expectError(error.FileCountMismatch, codec.decodeFileAlloc(std.testing.io, std.testing.allocator, deflated.items, .{}));
}

test "[failure] - [.mzarc reader]: rejects invalid metadata and trailing data" {
    var mz = [_]f64{ 400.00000125, 401.00000375 };
    var intensity = [_]f32{ 10.0, 11.0 };
    const input = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 20, .rt_seconds = 2.0, .ms_level = 2, .precursor_mz = 600.1, .mz = mz[0..], .intensity = intensity[0..] },
    };

    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossless }, .block_size = 1 });
    defer std.testing.allocator.free(encoded);

    const bad_magic = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(bad_magic);
    bad_magic[0] = 'B';
    try std.testing.expectError(error.InvalidMagic, codec.inspectAlloc(std.testing.allocator, bad_magic));

    const bad_version = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(bad_version);
    std.mem.writeInt(u16, bad_version[4..6], codec.version_major + 1, .little);
    try std.testing.expectError(error.UnsupportedVersion, codec.inspectAlloc(std.testing.allocator, bad_version));

    const future_minor = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(future_minor);
    std.mem.writeInt(u16, future_minor[6..8], codec.version_minor + 1, .little);
    try std.testing.expectError(error.UnsupportedVersion, codec.inspectAlloc(std.testing.allocator, future_minor));

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

test "[failure] - [.mzarc header fields]: rejects reserved and inconsistent values" {
    var mz = [_]f64{100.0};
    var intensity = [_]f32{1.0};
    const input = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 500.0, .mz = &mz, .intensity = &intensity },
        .{ .scan_id = 2, .rt_seconds = 2.0, .ms_level = 2, .precursor_mz = 501.0, .mz = &mz, .intensity = &intensity },
    };
    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, &input, .{
        .block_size = 2,
    });
    defer std.testing.allocator.free(encoded);

    const unknown_flags = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(unknown_flags);
    const flags = std.mem.readInt(u32, unknown_flags[8..12], .little);
    std.mem.writeInt(u32, unknown_flags[8..12], flags | (@as(u32, 1) << 31), .little);
    try std.testing.expectError(
        error.UnsupportedFileFlags,
        codec.inspectAlloc(std.testing.allocator, unknown_flags),
    );

    const nonzero_reserved = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(nonzero_reserved);
    std.mem.writeInt(u16, nonzero_reserved[14..16], 1, .little);
    try std.testing.expectError(
        error.NonzeroReserved,
        codec.inspectAlloc(std.testing.allocator, nonzero_reserved),
    );

    const wrong_contents = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(wrong_contents);
    std.mem.writeInt(u32, wrong_contents[8..12], flags & ~codec.flag_contains_ms2, .little);
    try std.testing.expectError(
        error.FileFlagsMismatch,
        codec.inspectAlloc(std.testing.allocator, wrong_contents),
    );

    const wrong_mode = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(wrong_mode);
    std.mem.writeInt(u32, wrong_mode[8..12], flags & ~codec.flag_lossless, .little);
    try std.testing.expectError(
        error.FileFlagsMismatch,
        codec.inspectAlloc(std.testing.allocator, wrong_mode),
    );

    const too_small_block_size = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(too_small_block_size);
    std.mem.writeInt(u16, too_small_block_size[12..14], 1, .little);
    try std.testing.expectError(
        error.InvalidBlockSize,
        codec.inspectAlloc(std.testing.allocator, too_small_block_size),
    );
}

test "[failure] - [.mzarc inspector]: verifies block checksums" {
    var mz = [_]f64{100.0};
    var intensity = [_]f32{1.0};
    const input = [_]binary_reader.RawSpectrum{.{
        .scan_id = 1,
        .rt_seconds = 1.0,
        .ms_level = 1,
        .precursor_mz = 0.0,
        .mz = &mz,
        .intensity = &intensity,
    }};
    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, &input, .{});
    defer std.testing.allocator.free(encoded);
    const corrupted = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(corrupted);
    corrupted[corrupted.len - 1] ^= 1;

    try std.testing.expectError(
        error.ChecksumMismatch,
        codec.inspectAlloc(std.testing.allocator, corrupted),
    );
}

test "[failure] - [.mzarc inspector]: rejects malformed encoded values" {
    var mz = [_]f64{100.0};
    var intensity = [_]f32{1.0};
    const input = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 1, .precursor_mz = 0.0, .mz = &mz, .intensity = &intensity },
        .{ .scan_id = 3, .rt_seconds = 2.0, .ms_level = 1, .precursor_mz = 0.0, .mz = &mz, .intensity = &intensity },
    };
    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, &input, .{
        .block_size = 2,
    });
    defer std.testing.allocator.free(encoded);
    const corrupted = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(corrupted);

    const block_offset = codec.header_len + input.len * @sizeOf(u32);
    const scan_payload_offset = block_offset + block.header_len + 1 + @sizeOf(u64) + @sizeOf(u32);
    try std.testing.expectEqual(@as(u8, 1), corrupted[block_offset + block.header_len]);
    corrupted[scan_payload_offset] |= 0b1000_0000;
    const payload = corrupted[block_offset + block.header_len ..];
    std.mem.writeInt(
        u32,
        corrupted[block_offset + 36 ..][0..@sizeOf(u32)],
        std.hash.crc.Crc32.hash(payload),
        .little,
    );

    try std.testing.expectError(
        error.NonzeroPadding,
        codec.inspectAlloc(std.testing.allocator, corrupted),
    );
}

test "[failure] - [.mzarc reader]: rejects file counts before allocation" {
    var mz = [_]f64{100.0};
    var intensity = [_]f32{1.0};
    const input = [_]binary_reader.RawSpectrum{.{
        .scan_id = 1,
        .rt_seconds = 1.0,
        .ms_level = 2,
        .precursor_mz = 500.0,
        .mz = &mz,
        .intensity = &intensity,
    }};
    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, &input, .{});
    defer std.testing.allocator.free(encoded);

    const too_many_spectra = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(too_many_spectra);
    std.mem.writeInt(u32, too_many_spectra[16..20], codec.MAX_FILE_SPECTRA + 1, .little);
    try std.testing.expectError(
        error.FileResourceLimit,
        codec.inspectAlloc(std.testing.failing_allocator, too_many_spectra),
    );

    const too_many_blocks = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(too_many_blocks);
    std.mem.writeInt(u32, too_many_blocks[20..24], codec.MAX_FILE_BLOCKS + 1, .little);
    try std.testing.expectError(
        error.FileResourceLimit,
        codec.inspectAlloc(std.testing.failing_allocator, too_many_blocks),
    );

    const more_blocks_than_spectra = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(more_blocks_than_spectra);
    std.mem.writeInt(u32, more_blocks_than_spectra[20..24], 2, .little);
    try std.testing.expectError(
        error.BlockCountMismatch,
        codec.inspectAlloc(std.testing.failing_allocator, more_blocks_than_spectra),
    );

    const no_blocks = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(no_blocks);
    std.mem.writeInt(u32, no_blocks[20..24], 0, .little);
    try std.testing.expectError(
        error.BlockCountMismatch,
        codec.inspectAlloc(std.testing.failing_allocator, no_blocks),
    );

    const impossible_peaks = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(impossible_peaks);
    std.mem.writeInt(u64, impossible_peaks[24..32], block.MAX_BLOCK_PEAKS + 1, .little);
    try std.testing.expectError(
        error.FileResourceLimit,
        codec.inspectAlloc(std.testing.failing_allocator, impossible_peaks),
    );
}

test "[failure] - [.mzarc reader]: rejects declared totals that disagree with blocks" {
    var mz = [_]f64{100.0};
    var intensity = [_]f32{1.0};
    const input = [_]binary_reader.RawSpectrum{.{
        .scan_id = 1,
        .rt_seconds = 1.0,
        .ms_level = 2,
        .precursor_mz = 500.0,
        .mz = &mz,
        .intensity = &intensity,
    }};
    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, &input, .{});
    defer std.testing.allocator.free(encoded);

    const wrong_peaks = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(wrong_peaks);
    std.mem.writeInt(u64, wrong_peaks[24..32], 2, .little);
    try std.testing.expectError(
        error.FileCountMismatch,
        codec.inspectAlloc(std.testing.allocator, wrong_peaks),
    );
}

test "[integration] - [.mzarc writer]: writes format 1.0 in both modes" {
    var mz = [_]f64{ 123.0, 124.0 };
    var intensity = [_]f32{ 10.0, 11.0 };
    const input = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 2, .precursor_mz = 600.0, .mz = mz[0..], .intensity = intensity[0..] },
    };

    const lossless = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossless }, .block_size = 1 });
    defer std.testing.allocator.free(lossless);
    const lossy = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossy }, .block_size = 1 });
    defer std.testing.allocator.free(lossy);

    const lossless_insp = try codec.inspectAlloc(std.testing.allocator, lossless);
    defer codec.freeInspection(std.testing.allocator, lossless_insp);
    const lossy_insp = try codec.inspectAlloc(std.testing.allocator, lossy);
    defer codec.freeInspection(std.testing.allocator, lossy_insp);

    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, lossless[4..6], .little));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, lossless[6..8], .little));
    try std.testing.expectEqual(@as(u16, 1), lossless_insp.header.version_major);
    try std.testing.expectEqual(@as(u16, 0), lossless_insp.header.version_minor);
    try std.testing.expectEqual(@as(u16, 1), lossy_insp.header.version_major);
    try std.testing.expectEqual(@as(u16, 0), lossy_insp.header.version_minor);
    try std.testing.expect((lossless_insp.header.flags & codec.flag_lossless) != 0);
    try std.testing.expect((lossy_insp.header.flags & codec.flag_lossless) == 0);
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

    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossless }, .block_size = 1 });
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

test "[property] - [lossless codec]: preserves exact m/z across many spectra" {
    var corpus = try makeSyntheticCorpus(std.testing.allocator, 24);
    defer corpus.deinit();

    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, corpus.spectra, .{ .block_options = .{ .mode = .lossless }, .block_size = 3 });
    defer std.testing.allocator.free(encoded);

    const decoded = try codec.decodeFileAlloc(std.testing.io, std.testing.allocator, encoded, .{});
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(corpus.spectra.len, decoded.len);
    try expectLosslessRoundTrip(corpus.spectra, decoded);
}

test "[property] - [lossless codec]: preserves exact m/z and byte accounting" {
    var corpus = try makePseudoRandomCorpus(std.testing.allocator, 0x5eed_c0de, 257, 33);
    defer corpus.deinit();

    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, corpus.spectra, .{ .block_options = .{ .mode = .lossless }, .block_size = 7 });
    defer std.testing.allocator.free(encoded);

    const inspection = try codec.inspectAlloc(std.testing.allocator, encoded);
    defer codec.freeInspection(std.testing.allocator, inspection);
    try expectByteBreakdownSums(inspection, encoded.len);

    const decoded = try codec.decodeFileAlloc(std.testing.io, std.testing.allocator, encoded, .{});
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(corpus.spectra.len, decoded.len);
    try expectLosslessRoundTrip(corpus.spectra, decoded);
}

test "codec lossy synthetic corpus preserves order while bounding m/z and intensity error" {
    var corpus = try makeSyntheticCorpus(std.testing.allocator, 18);
    defer corpus.deinit();

    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, corpus.spectra, .{ .block_options = .{ .mode = .lossy, .intensity_quant = 4096 }, .block_size = 4 });
    defer std.testing.allocator.free(encoded);

    const decoded = try codec.decodeFileAlloc(std.testing.io, std.testing.allocator, encoded, .{});
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

    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, corpus.spectra, .{ .block_options = .{ .mode = .lossy, .intensity_quant = 4096 }, .block_size = 9 });
    defer std.testing.allocator.free(encoded);

    const inspection = try codec.inspectAlloc(std.testing.allocator, encoded);
    defer codec.freeInspection(std.testing.allocator, inspection);
    try expectByteBreakdownSums(inspection, encoded.len);
    try std.testing.expect(inspection.byte_breakdown.intensity_metadata_bytes > 0);
    try std.testing.expect(inspection.byte_breakdown.intensity_payload_bytes > 0);

    const decoded = try codec.decodeFileAlloc(std.testing.io, std.testing.allocator, encoded, .{});
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

    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, &input, .{ .block_options = .{ .mode = .lossy, .intensity_quant = 4096 }, .block_size = 128 });
    defer std.testing.allocator.free(encoded);

    const inspection = try codec.inspectAlloc(std.testing.allocator, encoded);
    defer codec.freeInspection(std.testing.allocator, inspection);

    try std.testing.expectEqual(@as(u16, 128), inspection.header.block_size);
    try std.testing.expect((inspection.header.flags & codec.flag_lossless) == 0);
    try std.testing.expect((inspection.header.flags & codec.flag_contains_ms1) != 0);
    try std.testing.expect((inspection.header.flags & codec.flag_contains_ms2) != 0);
    try std.testing.expectEqual(@as(u64, 5), inspection.header.total_peaks);
}

test "[failure] - [codec block size]: rejects zero and values above the fixed limit" {
    var mz = [_]f64{100.0};
    var intensity = [_]f32{1.0};
    const input = [_]binary_reader.RawSpectrum{
        .{ .scan_id = 1, .rt_seconds = 1.0, .ms_level = 1, .precursor_mz = 0.0, .mz = mz[0..], .intensity = intensity[0..] },
    };

    try std.testing.expectError(error.InvalidBlockSize, codec.encodeFileAlloc(std.testing.io, std.testing.allocator, &input, .{ .block_size = 0 }));
    try std.testing.expectError(
        error.InvalidBlockSize,
        codec.encodeFileAlloc(std.testing.io, std.testing.allocator, &input, .{ .block_size = block.MAX_BLOCK_SPECTRA + 1 }),
    );
}

test "[integration] - [codec file path]: matches allocating path for format 1.0" {
    var corpus = try makeSyntheticCorpus(std.testing.allocator, 24);
    defer corpus.deinit();
    const dump = try binary_reader.writeDumpAlloc(std.testing.allocator, corpus.spectra);
    defer std.testing.allocator.free(dump);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = dump });
    const input_path = try tmpPath(std.testing.allocator, &tmp, "input.bin");
    defer std.testing.allocator.free(input_path);
    const archive_path = try tmpPath(std.testing.allocator, &tmp, "output.mzarc");
    defer std.testing.allocator.free(archive_path);
    const dump_path = try tmpPath(std.testing.allocator, &tmp, "decoded.bin");
    defer std.testing.allocator.free(dump_path);

    const options: codec.EncodeOptions = .{ .block_options = .{ .mode = .lossless }, .block_size = 3 };
    const expected_archive = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, corpus.spectra, options);
    defer std.testing.allocator.free(expected_archive);
    try codec.encodeDumpFile(std.testing.io, std.testing.allocator, input_path, archive_path, options);
    const actual_archive = try codec.readFileAlloc(std.testing.io, archive_path, std.testing.allocator);
    defer std.testing.allocator.free(actual_archive);
    try std.testing.expectEqualSlices(u8, expected_archive, actual_archive);

    const expected_spectra = try codec.decodeFileAlloc(std.testing.io, std.testing.allocator, expected_archive, .{});
    defer binary_reader.freeSpectra(std.testing.allocator, expected_spectra);
    const expected_dump = try binary_reader.writeDumpAlloc(std.testing.allocator, expected_spectra);
    defer std.testing.allocator.free(expected_dump);
    try codec.decodeToDumpFile(std.testing.io, std.testing.allocator, archive_path, dump_path, .{});
    const actual_dump = try codec.readFileAlloc(std.testing.io, dump_path, std.testing.allocator);
    defer std.testing.allocator.free(actual_dump);
    try std.testing.expectEqualSlices(u8, expected_dump, actual_dump);
}

test "[integration] - [.mzarc writer]: emits deterministic bytes" {
    var corpus = try makeSyntheticCorpus(std.testing.allocator, 24);
    defer corpus.deinit();
    const dump = try binary_reader.writeDumpAlloc(std.testing.allocator, corpus.spectra);
    defer std.testing.allocator.free(dump);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = dump });
    const input_path = try tmpPath(std.testing.allocator, &tmp, "input.bin");
    defer std.testing.allocator.free(input_path);
    const first_path = try tmpPath(std.testing.allocator, &tmp, "first.mzarc");
    defer std.testing.allocator.free(first_path);
    const second_path = try tmpPath(std.testing.allocator, &tmp, "second.mzarc");
    defer std.testing.allocator.free(second_path);

    const options: codec.EncodeOptions = .{
        .block_options = .{ .mode = .lossless },
        .block_size = 3,
    };
    try codec.encodeDumpFile(std.testing.io, std.testing.allocator, input_path, first_path, options);
    try codec.encodeDumpFile(std.testing.io, std.testing.allocator, input_path, second_path, options);
    const first = try codec.readFileAlloc(std.testing.io, first_path, std.testing.allocator);
    defer std.testing.allocator.free(first);
    const second = try codec.readFileAlloc(std.testing.io, second_path, std.testing.allocator);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualSlices(u8, first, second);
}

test "[integration] - [codec file path]: preserves payloads across reader refill boundaries" {
    const peak_count = 2049;
    const mz = try std.testing.allocator.alloc(f64, peak_count);
    defer std.testing.allocator.free(mz);
    const intensity = try std.testing.allocator.alloc(f32, peak_count);
    defer std.testing.allocator.free(intensity);
    for (mz, intensity, 0..) |*mz_value, *intensity_value, idx| {
        mz_value.* = 100.0 + @as(f64, @floatFromInt(idx)) * 0.125;
        intensity_value.* = @floatFromInt(idx % 1024);
    }
    const spectra = [_]binary_reader.RawSpectrum{.{
        .scan_id = 1,
        .rt_seconds = 1.0,
        .ms_level = 2,
        .precursor_mz = 500.0,
        .mz = mz,
        .intensity = intensity,
    }};
    const dump = try binary_reader.writeDumpAlloc(std.testing.allocator, &spectra);
    defer std.testing.allocator.free(dump);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = dump });
    const input_path = try tmpPath(std.testing.allocator, &tmp, "input.bin");
    defer std.testing.allocator.free(input_path);
    const archive_path = try tmpPath(std.testing.allocator, &tmp, "output.mzarc");
    defer std.testing.allocator.free(archive_path);
    const dump_path = try tmpPath(std.testing.allocator, &tmp, "decoded.bin");
    defer std.testing.allocator.free(dump_path);

    const options: codec.EncodeOptions = .{
        .block_options = .{ .mode = .lossless },
        .block_size = 1,
    };
    const expected_archive = try codec.encodeFileAlloc(
        std.testing.io,
        std.testing.allocator,
        &spectra,
        options,
    );
    defer std.testing.allocator.free(expected_archive);
    try codec.encodeDumpFile(std.testing.io, std.testing.allocator, input_path, archive_path, options);
    const actual_archive = try codec.readFileAlloc(std.testing.io, archive_path, std.testing.allocator);
    defer std.testing.allocator.free(actual_archive);
    try std.testing.expectEqualSlices(u8, expected_archive, actual_archive);

    try codec.decodeToDumpFile(std.testing.io, std.testing.allocator, archive_path, dump_path, .{});
    const actual_dump = try codec.readFileAlloc(std.testing.io, dump_path, std.testing.allocator);
    defer std.testing.allocator.free(actual_dump);
    try std.testing.expectEqualSlices(u8, dump, actual_dump);
}

test "[integration] - [lossless Dump V1]: preserves every accepted record byte" {
    var mz_a = [_]f64{ 100.0, 101.0 };
    var intensity_a = [_]f32{
        @bitCast(@as(u32, 0x8000_0000)),
        @bitCast(@as(u32, 0x7fc0_1234)),
    };
    var mz_b = [_]f64{200.0000000001};
    var intensity_b = [_]f32{@bitCast(@as(u32, 0xff80_0000))};
    const spectra = [_]binary_reader.RawSpectrum{
        .{
            .scan_id = 1,
            .rt_seconds = -0.0,
            .ms_level = 2,
            .precursor_mz = @bitCast(@as(u64, 0x7ff8_0000_0000_1234)),
            .mz = &mz_a,
            .intensity = &intensity_a,
        },
        .{
            .scan_id = std.math.maxInt(u32),
            .rt_seconds = 0.0,
            .ms_level = 2,
            .precursor_mz = @bitCast(@as(u64, 0x8000_0000_0000_0000)),
            .mz = &mz_b,
            .intensity = &intensity_b,
        },
    };
    const dump = try binary_reader.writeDumpAlloc(std.testing.allocator, &spectra);
    defer std.testing.allocator.free(dump);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = dump });
    const input_path = try tmpPath(std.testing.allocator, &tmp, "input.bin");
    defer std.testing.allocator.free(input_path);
    const archive_path = try tmpPath(std.testing.allocator, &tmp, "output.mzarc");
    defer std.testing.allocator.free(archive_path);
    const output_path = try tmpPath(std.testing.allocator, &tmp, "output.bin");
    defer std.testing.allocator.free(output_path);

    try codec.encodeDumpFile(std.testing.io, std.testing.allocator, input_path, archive_path, .{});
    try codec.decodeToDumpFile(std.testing.io, std.testing.allocator, archive_path, output_path, .{});
    try expectFileContents(output_path, dump);
}

test "[integration] - [.mzarc reader]: accepts archives without a global order table" {
    var corpus = try makeSyntheticCorpus(std.testing.allocator, 24);
    defer corpus.deinit();
    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, corpus.spectra, .{
        .block_options = .{ .mode = .lossless },
        .block_size = 3,
    });
    defer std.testing.allocator.free(encoded);

    const order_len = corpus.spectra.len * @sizeOf(u32);
    const without_order = try std.testing.allocator.alloc(u8, encoded.len - order_len);
    defer std.testing.allocator.free(without_order);
    @memcpy(without_order[0..codec.header_len], encoded[0..codec.header_len]);
    const flags = std.mem.readInt(u32, without_order[8..12], .little) & ~codec.flag_has_global_order;
    std.mem.writeInt(u32, without_order[8..12], flags, .little);
    @memcpy(without_order[codec.header_len..], encoded[codec.header_len + order_len ..]);

    const expected_spectra = try codec.decodeFileAlloc(std.testing.io, std.testing.allocator, without_order, .{});
    defer binary_reader.freeSpectra(std.testing.allocator, expected_spectra);
    const expected_dump = try binary_reader.writeDumpAlloc(std.testing.allocator, expected_spectra);
    defer std.testing.allocator.free(expected_dump);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzarc", .data = without_order });
    const input_path = try tmpPath(std.testing.allocator, &tmp, "input.mzarc");
    defer std.testing.allocator.free(input_path);
    const output_path = try tmpPath(std.testing.allocator, &tmp, "output.bin");
    defer std.testing.allocator.free(output_path);
    try codec.decodeToDumpFile(std.testing.io, std.testing.allocator, input_path, output_path, .{});
    const actual_dump = try codec.readFileAlloc(std.testing.io, output_path, std.testing.allocator);
    defer std.testing.allocator.free(actual_dump);
    try std.testing.expectEqualSlices(u8, expected_dump, actual_dump);
}

test "[integration] - [codec file path]: rejects hostile input and preserves destinations" {
    var corpus = try makeSyntheticCorpus(std.testing.allocator, 8);
    defer corpus.deinit();
    const dump = try binary_reader.writeDumpAlloc(std.testing.allocator, corpus.spectra);
    defer std.testing.allocator.free(dump);
    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, corpus.spectra, .{
        .block_options = .{ .mode = .lossless },
        .block_size = 3,
    });
    defer std.testing.allocator.free(encoded);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input_path = try tmpPath(std.testing.allocator, &tmp, "input.bin");
    defer std.testing.allocator.free(input_path);
    const output_path = try tmpPath(std.testing.allocator, &tmp, "output.bin");
    defer std.testing.allocator.free(output_path);
    const sentinel = "existing destination";

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = dump[0 .. dump.len - 1] });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "output.bin", .data = sentinel });
    try std.testing.expectError(error.UnexpectedEndOfStream, codec.encodeDumpFile(std.testing.io, std.testing.allocator, input_path, output_path, .{}));
    try expectFileContents(output_path, sentinel);

    var invalid_mz = [_]f64{-0.0};
    var invalid_intensity = [_]f32{1.0};
    const invalid_spectra = [_]binary_reader.RawSpectrum{.{
        .scan_id = 1,
        .rt_seconds = 1.0,
        .ms_level = 1,
        .precursor_mz = 0.0,
        .mz = &invalid_mz,
        .intensity = &invalid_intensity,
    }};
    const invalid_dump = try binary_reader.writeDumpAlloc(std.testing.allocator, &invalid_spectra);
    defer std.testing.allocator.free(invalid_dump);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = invalid_dump });
    try std.testing.expectError(
        error.InvalidMz,
        codec.encodeDumpFile(std.testing.io, std.testing.allocator, input_path, output_path, .{}),
    );
    try expectFileContents(output_path, sentinel);

    const corrupt = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(corrupt);
    corrupt[corrupt.len - 1] ^= 1;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = corrupt });
    try std.testing.expectError(error.ChecksumMismatch, codec.decodeToDumpFile(std.testing.io, std.testing.allocator, input_path, output_path, .{}));
    try expectFileContents(output_path, sentinel);

    const invalid_order = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(invalid_order);
    @memcpy(invalid_order[codec.header_len + @sizeOf(u32) ..][0..@sizeOf(u32)], invalid_order[codec.header_len..][0..@sizeOf(u32)]);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = invalid_order });
    try std.testing.expectError(error.InvalidOrderTable, codec.decodeToDumpFile(std.testing.io, std.testing.allocator, input_path, output_path, .{}));
    try expectFileContents(output_path, sentinel);

    const bad_block = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(bad_block);
    bad_block[codec.header_len + corpus.spectra.len * @sizeOf(u32) + 2] = 3;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = bad_block });
    try std.testing.expectError(error.UnsupportedMsLevel, codec.decodeToDumpFile(std.testing.io, std.testing.allocator, input_path, output_path, .{}));
    try expectFileContents(output_path, sentinel);

    const with_trailing = try std.testing.allocator.alloc(u8, encoded.len + 1);
    defer std.testing.allocator.free(with_trailing);
    @memcpy(with_trailing[0..encoded.len], encoded);
    with_trailing[encoded.len] = 0;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = with_trailing });
    try std.testing.expectError(error.TrailingFileData, codec.decodeToDumpFile(std.testing.io, std.testing.allocator, input_path, output_path, .{}));
    try expectFileContents(output_path, sentinel);

    var max_count_header = encoded[0..codec.header_len].*;
    const max_count_flags = std.mem.readInt(u32, max_count_header[8..12], .little) & ~codec.flag_has_global_order;
    std.mem.writeInt(u32, max_count_header[8..12], max_count_flags, .little);
    std.mem.writeInt(u32, max_count_header[16..20], codec.MAX_FILE_SPECTRA, .little);
    std.mem.writeInt(u32, max_count_header[20..24], codec.MAX_FILE_BLOCKS, .little);
    std.mem.writeInt(u64, max_count_header[24..32], 0, .little);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = &max_count_header });
    try std.testing.expectError(
        error.UnexpectedEndOfStream,
        codec.decodeToDumpFile(std.testing.io, std.testing.failing_allocator, input_path, output_path, .{}),
    );
    try expectFileContents(output_path, sentinel);

    var hostile_header: [codec.header_len]u8 = undefined;
    @memcpy(&hostile_header, encoded[0..codec.header_len]);
    std.mem.writeInt(u32, hostile_header[16..20], std.math.maxInt(u32), .little);
    std.mem.writeInt(u32, hostile_header[20..24], 0, .little);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = &hostile_header });
    try std.testing.expectError(error.FileResourceLimit, codec.decodeToDumpFile(std.testing.io, std.testing.allocator, input_path, output_path, .{}));
    try expectFileContents(output_path, sentinel);

    const block_offset = codec.header_len + corpus.spectra.len * @sizeOf(u32);
    const oversized_archive = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(oversized_archive);
    std.mem.writeInt(u32, oversized_archive[block_offset + 4 ..][0..4], @intCast(block.MAX_BLOCK_PEAKS + 1), .little);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = oversized_archive });
    try std.testing.expectError(
        error.BlockResourceLimit,
        codec.decodeToDumpFile(std.testing.io, std.testing.allocator, input_path, output_path, .{}),
    );
    try expectFileContents(output_path, sentinel);

    var oversized_dump_header: [28]u8 = @splat(0);
    oversized_dump_header[8] = 1;
    std.mem.writeInt(u32, oversized_dump_header[20..24], @intCast(block.MAX_BLOCK_PEAKS + 1), .little);
    {
        const oversized_dump = try tmp.dir.createFile(std.testing.io, "input.bin", .{});
        defer oversized_dump.close(std.testing.io);
        try oversized_dump.writePositionalAll(std.testing.io, &oversized_dump_header, 0);
        const dump_bytes = 28 + 12 * @as(u64, block.MAX_BLOCK_PEAKS + 1);
        try oversized_dump.setLength(std.testing.io, dump_bytes);
    }
    try std.testing.expectError(
        error.BlockResourceLimit,
        codec.encodeDumpFile(std.testing.io, std.testing.allocator, input_path, output_path, .{}),
    );
    try expectFileContents(output_path, sentinel);

    const late_failure = try std.testing.allocator.dupe(u8, &KNOWN_MZARC);
    defer std.testing.allocator.free(late_failure);
    const known_block_offset = codec.header_len + @sizeOf(u32);
    const known_block = late_failure[known_block_offset..];
    const breakdown = try block.inspectBlockByteBreakdown(known_block);
    const mz_section_offset = known_block_offset + block.header_len + breakdown.scan_id_bytes +
        breakdown.rt_bytes + breakdown.precursor_bytes + breakdown.peak_count_bytes;
    const first_mz_offset = mz_section_offset + @sizeOf(u64) + @sizeOf(u32) + @sizeOf(u32) + 1;
    std.mem.writeInt(u32, late_failure[first_mz_offset..][0..@sizeOf(u32)], @bitCast(@as(f32, -0.0)), .little);
    const payload = late_failure[known_block_offset + block.header_len ..];
    std.mem.writeInt(
        u32,
        late_failure[known_block_offset + 36 ..][0..@sizeOf(u32)],
        std.hash.crc.Crc32.hash(payload),
        .little,
    );
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = late_failure });
    try std.testing.expectError(
        error.InvalidMz,
        codec.decodeToDumpFile(std.testing.io, std.testing.allocator, input_path, output_path, .{}),
    );
    try expectFileContents(output_path, sentinel);
}

test "[property] - [lossless m/z]: preserves non-f32 values bit for bit" {
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

    try expectMzBits(&mz_buf, decoded[0].mz);
}

test "empirical error bounds: representative lossy m/z values stay within the nominal half-step" {
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

test "[integration] - [lossless m/z]: uses exact f64 layout for non-f32 values" {
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
    try std.testing.expect((header.flags & block.flag_lossless_mz_f64) != 0);

    const decoded = try block.decodeBlock(std.testing.allocator, encoded);
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try expectMzBits(&mz_buf, decoded[0].mz);
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

test "lossy unit intensity has bounded relative error" {
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

test "[edge] - [.mzarc writer]: emits a valid empty archive" {
    const empty: []const binary_reader.RawSpectrum = &.{};

    const encoded = try codec.encodeFileAlloc(std.testing.io, std.testing.allocator, empty, .{ .block_options = .{ .mode = .lossless }, .block_size = 16 });
    defer std.testing.allocator.free(encoded);

    const inspection = try codec.inspectAlloc(std.testing.allocator, encoded);
    defer codec.freeInspection(std.testing.allocator, inspection);

    try std.testing.expectEqual(@as(u32, 0), inspection.header.spectrum_count);
    try std.testing.expectEqual(@as(u32, 0), inspection.header.block_count);

    const decoded = try codec.decodeFileAlloc(std.testing.io, std.testing.allocator, encoded, .{});
    defer binary_reader.freeSpectra(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}
