//! Source-document archives: hand-built archives, header rejection, fixture round trips,
//! damaged archives, and the source index slack rule.

const std = @import("std");
const codec = @import("codec");
const quantize = @import("quantize");
const source_document = @import("source_document");

const fixture = "test/fixtures/small.mzML";

fn pathIn(tmp: *std.testing.TmpDir, buffer: []u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, name });
}

/// A zlib stream (RFC 1950) holding `data` in stored deflate blocks, written by hand.
fn storedZlib(out: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    try out.appendSlice(allocator, &.{ 0x78, 0x01 });
    var rest = data;
    while (true) {
        const n: u16 = @intCast(@min(rest.len, 65535));
        const final: u8 = if (n == rest.len) 1 else 0;
        try out.append(allocator, final);
        var lengths: [4]u8 = undefined;
        std.mem.writeInt(u16, lengths[0..2], n, .little);
        std.mem.writeInt(u16, lengths[2..4], ~n, .little);
        try out.appendSlice(allocator, &lengths);
        try out.appendSlice(allocator, rest[0..n]);
        rest = rest[n..];
        if (final == 1) break;
    }
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(data), .big);
    try out.appendSlice(allocator, &adler);
}

/// A complete archive, header written field by field from the specification.
fn handArchive(allocator: std.mem.Allocator, flags: u32, profile: u16, stream: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var header: [32]u8 = @splat(0);
    header[0..4].* = "MZAR".*;
    std.mem.writeInt(u16, header[4..6], 1, .little);
    std.mem.writeInt(u16, header[6..8], 0, .little);
    std.mem.writeInt(u32, header[8..12], flags, .little);
    std.mem.writeInt(u16, header[12..14], 1, .little);
    std.mem.writeInt(u16, header[14..16], profile, .little);
    std.mem.writeInt(u32, header[16..20], std.hash.crc.Crc32.hash(stream), .little);
    std.mem.writeInt(u64, header[24..32], stream.len, .little);
    try out.appendSlice(allocator, &header);
    try storedZlib(&out, allocator, stream);
    return out.toOwnedSlice(allocator);
}

fn decodeBytes(tmp: *std.testing.TmpDir, archive: []const u8) ![]u8 {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "arc", .data = archive });
    _ = try source_document.decode(std.testing.io, std.testing.allocator, try pathIn(tmp, &a, "arc"), try pathIn(tmp, &b, "out"));
    return tmp.dir.readFileAlloc(std.testing.io, "out", std.testing.allocator, .unlimited);
}

test "[integration] - [source-document exact]: decodes a hand-built archive to its source bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "<?xml version=\"1.0\"?>\n<mzML><!-- kept --></mzML>\n";
    const archive = try handArchive(std.testing.allocator, source_document.flag_source_document | codec.flag_lossless, 0, source);
    defer std.testing.allocator.free(archive);

    const decoded = try decodeBytes(&tmp, archive);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(source, decoded);
}

test "[integration] - [source-document lossy]: decodes a hand-built record stream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const log_max: f32 = 2.0;
    const levels = [_]u16{ 0, 8192, 16384 };

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);
    const head = "<a>";
    try stream.append(allocator, 1);
    try stream.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u64, head.len)));
    try stream.appendSlice(allocator, head);
    try stream.append(allocator, 4); // element mark at output position 3
    try stream.append(allocator, 1);
    try stream.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u64, 3)));
    try stream.appendSlice(allocator, "<b>");
    try stream.appendSlice(allocator, &.{ 2, 2, 0, 0 }); // array: intensity, f32, no compression
    try stream.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, levels.len)));
    try stream.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @bitCast(log_max)))));
    for (levels) |level| try stream.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, level)));
    try stream.append(allocator, 5); // index list mark
    try stream.append(allocator, 1);
    try stream.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u64, 1)));
    try stream.appendSlice(allocator, "|");
    try stream.append(allocator, 6); // offset of element 0
    try stream.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, 0)));
    try stream.append(allocator, 7); // index list offset
    try stream.append(allocator, 0);
    const archive = try handArchive(allocator, source_document.flag_source_document, 1, stream.items);
    defer allocator.free(archive);

    // Independent expectation: the lossy intensity reconstruction expm1(level / Q * L), little-endian f32, Base64.
    var values: [levels.len]f32 = undefined;
    for (levels, &values) |level, *value| {
        value.* = if (level == 0) 0 else @floatCast(std.math.expm1(@as(f64, @floatFromInt(level)) / 16384.0 * @as(f64, log_max)));
    }
    var raw: [levels.len * 4]u8 = undefined;
    for (values, 0..) |value, i| std.mem.writeInt(u32, raw[i * 4 ..][0..4], @bitCast(value), .little);
    var text: [16]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&text, &raw);
    var expected_buffer: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "<a><b>{s}|3{d}", .{ encoded, 3 + 3 + encoded.len });

    const decoded = try decodeBytes(&tmp, archive);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings(expected, decoded);
}

fn appendRawRecord(stream: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try stream.append(allocator, 1);
    try stream.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u64, bytes.len)));
    try stream.appendSlice(allocator, bytes);
}

test "[regression] - [source-document lossy]: rebuilds every fileChecksum from the bytes before it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);
    try appendRawRecord(&stream, allocator, "<first>");
    try stream.append(allocator, 8);
    try appendRawRecord(&stream, allocator, "</first><second>");
    try stream.append(allocator, 8);
    try appendRawRecord(&stream, allocator, "</second>");
    try stream.append(allocator, 0);
    const archive = try handArchive(allocator, source_document.flag_source_document, 1, stream.items);
    defer allocator.free(archive);

    // Independent expectation: each checksum is the standard-library SHA-1 of every output byte before it.
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    for ([_][]const u8{ "<first>", "</first><second>" }) |raw| {
        try expected.appendSlice(allocator, raw);
        var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        std.crypto.hash.Sha1.hash(expected.items, &digest, .{});
        var hex: [40]u8 = undefined;
        _ = try std.fmt.bufPrint(&hex, "{x}", .{&digest});
        try expected.appendSlice(allocator, &hex);
    }
    try expected.appendSlice(allocator, "</second>");

    const decoded = try decodeBytes(&tmp, archive);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings(expected.items, decoded);
}

test "[failure] - [source-document header]: rejects every invalid field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const flags = source_document.flag_source_document | codec.flag_lossless;
    const good = try handArchive(std.testing.allocator, flags, 0, "x");
    defer std.testing.allocator.free(good);
    const cases = [_]struct { index: usize, value: u8 }{
        .{ .index = 0, .value = 'X' }, // magic
        .{ .index = 4, .value = 2 }, // major version
        .{ .index = 6, .value = 1 }, // minor version
        .{ .index = 8, .value = 0x13 }, // unknown flag bit
        .{ .index = 8, .value = 0x10 }, // lossy flag with the exact profile
        .{ .index = 12, .value = 2 }, // codec
        .{ .index = 14, .value = 1 }, // profile
        .{ .index = 16, .value = good[16] ^ 1 }, // stream CRC
        .{ .index = 20, .value = 1 }, // reserved
        .{ .index = 24, .value = 2 }, // stream length
    };
    var bad: [64]u8 = undefined;
    for (cases) |case| {
        @memcpy(bad[0..good.len], good);
        bad[case.index] = case.value;
        if (decodeBytes(&tmp, bad[0..good.len])) |out| {
            std.testing.allocator.free(out);
            std.debug.print("accepted header byte {d} = {d}\n", .{ case.index, case.value });
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "[property] - [source-document exact]: round trips the fixture byte for byte" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const summary = try source_document.encodeExact(std.testing.io, std.testing.allocator, fixture, try pathIn(&tmp, &a, "arc"));
    try std.testing.expectEqual(source_document.Mode.exact, summary.mode);
    _ = try source_document.decode(std.testing.io, std.testing.allocator, try pathIn(&tmp, &a, "arc"), try pathIn(&tmp, &b, "out"));
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(source);
    const output = try tmp.dir.readFileAlloc(std.testing.io, "out", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualSlices(u8, source, output);
}

test "[integration] - [source-document lossy]: keeps every byte outside the spectrum arrays" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const summary = try source_document.encodeLossy(std.testing.io, std.testing.allocator, fixture, try pathIn(&tmp, &a, "arc"));
    try std.testing.expect(summary.arrays_coded > 0);
    _ = try source_document.decode(std.testing.io, std.testing.allocator, try pathIn(&tmp, &a, "arc"), try pathIn(&tmp, &b, "out"));
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(source);
    const output = try tmp.dir.readFileAlloc(std.testing.io, "out", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(output);
    const first = std.mem.indexOf(u8, source, "<spectrum ").?;
    try std.testing.expectEqualStrings(source[0..first], output[0..first]);
    try std.testing.expect(std.mem.endsWith(u8, output, source[std.mem.lastIndexOf(u8, source, "</spectrumList>").?..]));
}

const Damage = struct { len: usize, index: ?usize };

/// Every proper prefix, one flipped byte in each header field and across the payload, and one
/// trailing byte. Each case must be rejected.
fn damageCases(allocator: std.mem.Allocator, archive_len: usize) !std.ArrayList(Damage) {
    var cases: std.ArrayList(Damage) = .empty;
    errdefer cases.deinit(allocator);
    for (0..archive_len) |len| try cases.append(allocator, .{ .len = len, .index = null });
    for ([_]usize{ 0, 8, 12, 14, 16, 20, 24, 36, archive_len / 2, archive_len - 1 }) |index| {
        try cases.append(allocator, .{ .len = archive_len, .index = index });
    }
    try cases.append(allocator, .{ .len = archive_len + 1, .index = archive_len });
    return cases;
}

/// Writes `archive` damaged as `case` to `bad` in `tmp`.
fn writeDamaged(tmp: *std.testing.TmpDir, damaged: []u8, archive: []const u8, case: Damage) !void {
    @memcpy(damaged[0..archive.len], archive);
    damaged[archive.len] = 0;
    if (case.index) |index| damaged[index] ^= 0x41;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad", .data = damaged[0..case.len] });
}

test "[failure] - [source-document decode]: rejects damaged archives and keeps the destination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    _ = try source_document.encodeLossy(std.testing.io, std.testing.allocator, fixture, try pathIn(&tmp, &a, "arc"));
    const archive = try tmp.dir.readFileAlloc(std.testing.io, "arc", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(archive);
    const damaged = try std.testing.allocator.alloc(u8, archive.len + 1);
    defer std.testing.allocator.free(damaged);
    var cases = try damageCases(std.testing.allocator, archive.len);
    defer cases.deinit(std.testing.allocator);

    for (cases.items) |case| {
        try writeDamaged(&tmp, damaged, archive, case);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "out", .data = "keep" });
        if (source_document.decode(std.testing.io, std.testing.allocator, try pathIn(&tmp, &a, "bad"), try pathIn(&tmp, &b, "out"))) |_| {
            std.debug.print("accepted damaged archive: length {d}, byte {?d}\n", .{ case.len, case.index });
            return error.TestUnexpectedResult;
        } else |_| {}
        const kept = try tmp.dir.readFileAlloc(std.testing.io, "out", std.testing.allocator, .unlimited);
        defer std.testing.allocator.free(kept);
        try std.testing.expectEqualStrings("keep", kept);
    }
}

test "[failure] - [source-document inspect]: rejects every damaged archive in both modes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a: [256]u8 = undefined;

    for ([_]source_document.Mode{ .exact, .lossy }) |mode| {
        const path = try pathIn(&tmp, &a, "arc");
        _ = switch (mode) {
            .exact => try source_document.encodeExact(std.testing.io, std.testing.allocator, fixture, path),
            .lossy => try source_document.encodeLossy(std.testing.io, std.testing.allocator, fixture, path),
        };
        const archive = try tmp.dir.readFileAlloc(std.testing.io, "arc", std.testing.allocator, .unlimited);
        defer std.testing.allocator.free(archive);
        const damaged = try std.testing.allocator.alloc(u8, archive.len + 1);
        defer std.testing.allocator.free(damaged);
        var cases = try damageCases(std.testing.allocator, archive.len);
        defer cases.deinit(std.testing.allocator);

        for (cases.items) |case| {
            try writeDamaged(&tmp, damaged, archive, case);
            if (source_document.inspect(std.testing.io, std.testing.allocator, try pathIn(&tmp, &a, "bad"))) |_| {
                std.debug.print("inspect accepted damaged {s} archive: length {d}, byte {?d}\n", .{ @tagName(mode), case.len, case.index });
                return error.TestUnexpectedResult;
            } else |_| {}
        }
    }
}

test "[integration] - [source-document inspect]: reports the document length that decode writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;

    for ([_]source_document.Mode{ .exact, .lossy }) |mode| {
        const archive_path = try pathIn(&tmp, &a, "arc");
        _ = switch (mode) {
            .exact => try source_document.encodeExact(std.testing.io, std.testing.allocator, fixture, archive_path),
            .lossy => try source_document.encodeLossy(std.testing.io, std.testing.allocator, fixture, archive_path),
        };
        const decoded = try source_document.decode(std.testing.io, std.testing.allocator, archive_path, try pathIn(&tmp, &b, "out"));
        const info = try source_document.inspect(std.testing.io, std.testing.allocator, archive_path);

        try std.testing.expectEqual(mode, info.header.mode);
        try std.testing.expectEqual(decoded.output_bytes, info.output_bytes);
        try std.testing.expectEqual(decoded.archive_bytes, info.archive_bytes);
    }
}

fn indexedDocument(buffer: []u8, offset_shift: i64, list_shift: i64) ![]const u8 {
    const body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<indexedmzML xmlns=\"http://psi.hupo.org/ms/mzml\">\n<mzML xmlns=\"http://psi.hupo.org/ms/mzml\" version=\"1.1.0\"><run id=\"r\"><spectrumList count=\"1\">\n   <spectrum index=\"0\" id=\"scan=1\" defaultArrayLength=\"0\"></spectrum>\n</spectrumList></run></mzML>\n";
    const spectrum: i64 = @intCast(std.mem.indexOf(u8, body, "<spectrum ").?);
    const list: i64 = @intCast(body.len);
    return std.fmt.bufPrint(buffer, "{s}<indexList count=\"1\"><index name=\"spectrum\"><offset idRef=\"scan=1\">{d}</offset></index></indexList>\n<indexListOffset>{d}</indexListOffset>\n</indexedmzML>\n", .{ body, spectrum + offset_shift, list + list_shift });
}

test "[edge] - [source-document lossy]: accepts index entries that point into the whitespace before their element" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var doc: [1024]u8 = undefined;
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "in", .data = try indexedDocument(&doc, -3, -1) });
    const summary = try source_document.encodeLossy(std.testing.io, std.testing.allocator, try pathIn(&tmp, &a, "in"), try pathIn(&tmp, &b, "arc"));
    try std.testing.expectEqual(@as(u64, 2), summary.offsets_corrected);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "in", .data = try indexedDocument(&doc, 1, 0) });
    try std.testing.expectError(error.SourceOffsetMismatch, source_document.encodeLossy(std.testing.io, std.testing.allocator, try pathIn(&tmp, &a, "in"), try pathIn(&tmp, &b, "arc")));
}

test "[unit] - [source-document lossy]: finds attribute and text digits exactly" {
    const tag = "<binaryDataArray arrayLength=\"4\" encodedLength = '123'>";
    const d = source_document.attributeDigits(tag, "encodedLength").?;
    try std.testing.expectEqualStrings("123", tag[d.start..d.end]);
    try std.testing.expect(source_document.attributeDigits("<a xencodedLength=\"1\">", "encodedLength") == null);
    try std.testing.expect(source_document.attributeDigits("<a encodedLength=\"\">", "encodedLength") == null);
    const t = source_document.textDigits(" 42\n", 100, 104).?;
    try std.testing.expectEqual(@as(u64, 42), t.value);
    try std.testing.expectEqual(@as(u64, 101), t.start);
    try std.testing.expectEqual(@as(u64, 103), t.end);
    try std.testing.expect(source_document.textDigits("4x", 0, 2) == null);
}

test "[regression] - [source-document lossy]: keeps an array raw when its encodedLength is not plain digits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    // One intensity array (f32, no compression) whose encodedLength value has a leading space.
    var values: [2]f32 = .{ 10.0, 20.0 };
    var text: [16]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&text, std.mem.sliceAsBytes(&values));
    var doc: [1024]u8 = undefined;
    const source = try std.fmt.bufPrint(&doc, "<?xml version=\"1.0\"?>\n<mzML xmlns=\"http://psi.hupo.org/ms/mzml\" version=\"1.1.0\"><run id=\"r\"><spectrumList count=\"1\"><spectrum index=\"0\" id=\"scan=1\" defaultArrayLength=\"2\"><binaryDataArrayList count=\"1\"><binaryDataArray encodedLength=\" {d}\"><cvParam cvRef=\"MS\" accession=\"MS:1000521\" name=\"32-bit float\"/><cvParam cvRef=\"MS\" accession=\"MS:1000576\" name=\"no compression\"/><cvParam cvRef=\"MS\" accession=\"MS:1000515\" name=\"intensity array\"/><binary>{s}</binary></binaryDataArray></binaryDataArrayList></spectrum></spectrumList></run></mzML>\n", .{ encoded.len, encoded });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "in", .data = source });

    const summary = try source_document.encodeLossy(std.testing.io, std.testing.allocator, try pathIn(&tmp, &a, "in"), try pathIn(&tmp, &b, "arc"));
    try std.testing.expectEqual(@as(u64, 0), summary.arrays_coded);
    try std.testing.expectEqual(@as(u64, 1), summary.arrays_kept);
    _ = try source_document.decode(std.testing.io, std.testing.allocator, try pathIn(&tmp, &b, "arc"), try pathIn(&tmp, &a, "out"));
    const output = try tmp.dir.readFileAlloc(std.testing.io, "out", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(source, output);
}

test "[failure] - [source-document lossy]: rejects UTF-16 sources, which exact mode still stores" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const text = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><mzML/>";
    var utf16: [2 + 2 * text.len]u8 = undefined;
    utf16[0..2].* = .{ 0xFF, 0xFE };
    for (text, 0..) |c, i| utf16[2 + 2 * i ..][0..2].* = .{ c, 0 };
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "in", .data = &utf16 });
    try std.testing.expectError(error.UnsupportedEncoding, source_document.encodeLossy(std.testing.io, std.testing.allocator, try pathIn(&tmp, &a, "in"), try pathIn(&tmp, &b, "arc")));

    // Without a byte-order mark the zero byte beside the first `<` gives UTF-16 away.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "in", .data = utf16[2..] });
    try std.testing.expectError(error.UnsupportedEncoding, source_document.encodeLossy(std.testing.io, std.testing.allocator, try pathIn(&tmp, &a, "in"), try pathIn(&tmp, &b, "arc")));

    _ = try source_document.encodeExact(std.testing.io, std.testing.allocator, try pathIn(&tmp, &a, "in"), try pathIn(&tmp, &b, "arc"));
    _ = try source_document.decode(std.testing.io, std.testing.allocator, try pathIn(&tmp, &b, "arc"), try pathIn(&tmp, &a, "out"));
    const restored = try tmp.dir.readFileAlloc(std.testing.io, "out", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualSlices(u8, utf16[2..], restored);
}

fn oneArrayDocument(buffer: []u8, text: []u8, values: []const f32, encoded_length: []const u8) ![]const u8 {
    const encoded = std.base64.standard.Encoder.encode(text, std.mem.sliceAsBytes(values));
    var length_buffer: [16]u8 = undefined;
    const length = if (encoded_length.len != 0) encoded_length else try std.fmt.bufPrint(&length_buffer, "{d}", .{encoded.len});
    return std.fmt.bufPrint(buffer, "<?xml version=\"1.0\"?>\n<mzML xmlns=\"http://psi.hupo.org/ms/mzml\" version=\"1.1.0\"><run id=\"r\"><spectrumList count=\"1\"><spectrum index=\"0\" id=\"scan=1\" defaultArrayLength=\"{d}\"><binaryDataArrayList count=\"1\"><binaryDataArray encodedLength=\"{s}\"><cvParam cvRef=\"MS\" accession=\"MS:1000521\" name=\"32-bit float\"/><cvParam cvRef=\"MS\" accession=\"MS:1000576\" name=\"no compression\"/><cvParam cvRef=\"MS\" accession=\"MS:1000515\" name=\"intensity array\"/><binary>{s}</binary></binaryDataArray></binaryDataArrayList></spectrum></spectrumList></run></mzML>\n", .{ values.len, length, encoded });
}

test "[regression] - [source-document lossy]: keeps an intensity array with a negative value raw" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    var doc: [1024]u8 = undefined;
    var text: [64]u8 = undefined;
    const source = try oneArrayDocument(&doc, &text, &.{ 10.0, -2.5, 30.0 }, "");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "in", .data = source });

    const summary = try source_document.encodeLossy(std.testing.io, std.testing.allocator, try pathIn(&tmp, &a, "in"), try pathIn(&tmp, &b, "arc"));
    try std.testing.expectEqual(@as(u64, 0), summary.arrays_coded);
    _ = try source_document.decode(std.testing.io, std.testing.allocator, try pathIn(&tmp, &b, "arc"), try pathIn(&tmp, &a, "out"));
    const output = try tmp.dir.readFileAlloc(std.testing.io, "out", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(source, output);
}

test "[failure] - [source-document lossy]: rejects mzML drafts before 1.0" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "in", .data = "<?xml version=\"1.0\"?>\n<mzML xmlns=\"http://psi.hupo.org/schema_revision/mzML_0.99.1\" version=\"0.99.1\"></mzML>\n" });
    try std.testing.expectError(error.UnsupportedVersion, source_document.encodeLossy(std.testing.io, std.testing.allocator, try pathIn(&tmp, &a, "in"), try pathIn(&tmp, &b, "arc")));

    // A draft namespace without a version attribute is rejected too.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "in", .data = "<?xml version=\"1.0\"?>\n<mzML xmlns=\"http://psi.hupo.org/schema_revision/mzML_0.99.10\"></mzML>\n" });
    try std.testing.expectError(error.UnsupportedVersion, source_document.encodeLossy(std.testing.io, std.testing.allocator, try pathIn(&tmp, &a, "in"), try pathIn(&tmp, &b, "arc")));
}

/// One m/z record stream: the array record alone, between two raw spans, with the given layout byte.
fn mzRecordStream(allocator: std.mem.Allocator, stream: *std.ArrayList(u8), layout: u8, codes: []const u64) !void {
    try stream.append(allocator, 1);
    try stream.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u64, 3)));
    try stream.appendSlice(allocator, "<b>");
    try stream.appendSlice(allocator, &.{ 2, 1, 1, 0 }); // array: m/z, f64, no compression
    try stream.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(codes.len))));
    try stream.append(allocator, layout);
    for (codes) |code| try stream.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u64, code)));
    try stream.append(allocator, 0);
}

test "[integration] - [source-document lossy]: rounds flagged m/z arrays to f32 and leaves others alone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const codes = [_]u64{ 50_049_999, 150_000_123 };

    for ([_]u8{ 0x00, 0x02 }) |layout| {
        var stream: std.ArrayList(u8) = .empty;
        defer stream.deinit(allocator);
        try mzRecordStream(allocator, &stream, layout, &codes);
        const archive = try handArchive(allocator, source_document.flag_source_document, 1, stream.items);
        defer allocator.free(archive);

        // Independent expectation: code / 500000 in f64, rounded to f32 when the f32 bit is set.
        var raw: [codes.len * 8]u8 = undefined;
        for (codes, 0..) |code, i| {
            var value = @as(f64, @floatFromInt(code)) / 500000.0;
            if (layout & 0x02 != 0) value = @as(f32, @floatCast(value));
            std.mem.writeInt(u64, raw[i * 8 ..][0..8], @bitCast(value), .little);
        }
        var text: [32]u8 = undefined;
        var expected_buffer: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buffer, "<b>{s}", .{std.base64.standard.Encoder.encode(&text, &raw)});

        const decoded = try decodeBytes(&tmp, archive);
        defer allocator.free(decoded);
        try std.testing.expectEqualStrings(expected, decoded);
    }

    // Bits other than the layout and the f32 flag are reserved.
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);
    try mzRecordStream(allocator, &stream, 0x04, &codes);
    const archive = try handArchive(allocator, source_document.flag_source_document, 1, stream.items);
    defer allocator.free(archive);
    try std.testing.expectError(error.InvalidRecord, decodeBytes(&tmp, archive));
}

fn mzDocument(buffer: []u8, text: []u8, values: []const f64) ![]const u8 {
    const encoded = std.base64.standard.Encoder.encode(text, std.mem.sliceAsBytes(values));
    return std.fmt.bufPrint(buffer, "<?xml version=\"1.0\"?>\n<mzML xmlns=\"http://psi.hupo.org/ms/mzml\" version=\"1.1.0\"><run id=\"r\"><spectrumList count=\"1\"><spectrum index=\"0\" id=\"scan=1\" defaultArrayLength=\"{d}\"><binaryDataArrayList count=\"1\"><binaryDataArray encodedLength=\"{d}\"><cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/><cvParam cvRef=\"MS\" accession=\"MS:1000576\" name=\"no compression\"/><cvParam cvRef=\"MS\" accession=\"MS:1000514\" name=\"m/z array\"/><binary>{s}</binary></binaryDataArray></binaryDataArrayList></spectrum></spectrumList></run></mzML>\n", .{ values.len, encoded.len, encoded });
}

test "[property] - [source-document lossy]: restores f32-valued m/z exactly and quantizes other m/z" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    var doc: [2048]u8 = undefined;
    var text: [256]u8 = undefined;

    // Values an instrument wrote as f32 and the document stores as f64.
    const f32_values = [_]f64{ @as(f32, 100.1), @as(f32, 445.12003), @as(f32, 1999.9876) };
    const source = try mzDocument(&doc, &text, &f32_values);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "in", .data = source });
    var summary = try source_document.encodeLossy(std.testing.io, std.testing.allocator, try pathIn(&tmp, &a, "in"), try pathIn(&tmp, &b, "arc"));
    try std.testing.expectEqual(@as(u64, 1), summary.arrays_coded);
    _ = try source_document.decode(std.testing.io, std.testing.allocator, try pathIn(&tmp, &b, "arc"), try pathIn(&tmp, &a, "out"));
    const restored = try tmp.dir.readFileAlloc(std.testing.io, "out", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(source, restored);

    // A value with more than f32 precision keeps the quantized reconstruction.
    const f64_values = [_]f64{ 100.1, 445.123456789 };
    const quantized = try mzDocument(&doc, &text, &f64_values);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "in", .data = quantized });
    summary = try source_document.encodeLossy(std.testing.io, std.testing.allocator, try pathIn(&tmp, &a, "in"), try pathIn(&tmp, &b, "arc"));
    try std.testing.expectEqual(@as(u64, 1), summary.arrays_coded);
    _ = try source_document.decode(std.testing.io, std.testing.allocator, try pathIn(&tmp, &b, "arc"), try pathIn(&tmp, &a, "out"));
    const output = try tmp.dir.readFileAlloc(std.testing.io, "out", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(output);
    var expected_values: [f64_values.len]f64 = undefined;
    for (f64_values, &expected_values) |value, *expected| {
        expected.* = try quantize.dequantizeMzValue(try quantize.quantizeMzValue(value, 500_000), 500_000);
    }
    var expected_doc: [2048]u8 = undefined;
    var expected_text: [256]u8 = undefined;
    try std.testing.expectEqualStrings(try mzDocument(&expected_doc, &expected_text, &expected_values), output);
}
