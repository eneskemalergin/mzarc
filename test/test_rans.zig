const std = @import("std");
const rans = @import("rans");

test "rans round-trips uniform byte distribution" {
    var values: [4096]u8 = undefined;
    for (0..values.len) |idx| values[idx] = @truncate(idx & 0xff);

    const encoded = try rans.encodeAlloc(std.testing.allocator, values[0..]);
    defer std.testing.allocator.free(encoded);

    const decoded = try rans.decodeAlloc(std.testing.allocator, encoded, values.len);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, values[0..], decoded);
    try std.testing.expect(encoded.len > values.len);
}

test "rans round-trips highly skewed data and shrinks it" {
    var values: [8192]u8 = undefined;
    for (0..values.len) |idx| {
        values[idx] = if (idx % 32 == 0) 7 else 3;
    }

    const analysis = rans.analyze(values[0..]);
    const encoded = try rans.encodeAnalyzedAlloc(std.testing.allocator, values[0..], analysis);
    defer std.testing.allocator.free(encoded);

    const decoded = try rans.decodeAlloc(std.testing.allocator, encoded, values.len);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, values[0..], decoded);
    try std.testing.expect(encoded.len < values.len);
}

test "rans round-trips degenerate single-symbol input" {
    var values: [8192]u8 = undefined;
    @memset(&values, 42);

    const encoded = try rans.encodeAlloc(std.testing.allocator, values[0..]);
    defer std.testing.allocator.free(encoded);

    const decoded = try rans.decodeAlloc(std.testing.allocator, encoded, values.len);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, values[0..], decoded);
    try std.testing.expect(encoded.len < values.len);
}

test "rans empty round-trip" {
    const encoded = try rans.encodeAlloc(std.testing.allocator, &[_]u8{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqual(@as(usize, 0), encoded.len);

    const decoded = try rans.decodeAlloc(std.testing.allocator, encoded, 0);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}

test "rans rejects trailing data, truncation, bad freqs, invalid state, and analysis mismatch" {
    const values = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const encoded = try rans.encodeAlloc(std.testing.allocator, values[0..]);
    defer std.testing.allocator.free(encoded);

    const with_trailing = try std.testing.allocator.alloc(u8, encoded.len + 1);
    defer std.testing.allocator.free(with_trailing);
    @memcpy(with_trailing[0..encoded.len], encoded);
    with_trailing[encoded.len] = 0;
    try std.testing.expectError(error.TrailingData, rans.decodeAlloc(std.testing.allocator, with_trailing, values.len));

    // Header-only truncation (freqs + state) exercises mid-decode renorm starvation.
    try std.testing.expect(encoded.len > 516);
    try std.testing.expectError(error.UnexpectedEndOfStream, rans.decodeAlloc(std.testing.allocator, encoded[0..516], values.len));
    try std.testing.expectError(error.UnexpectedEndOfStream, rans.decodeAlloc(std.testing.allocator, encoded[0..8], values.len));

    var bad_freqs = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(bad_freqs);
    @memset(bad_freqs[0..512], 0);
    try std.testing.expectError(error.InvalidFrequencyTable, rans.decodeAlloc(std.testing.allocator, bad_freqs, values.len));

    var bad_state = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(bad_state);
    std.mem.writeInt(u32, bad_state[512..516], 0, .little);
    try std.testing.expectError(error.InvalidState, rans.decodeAlloc(std.testing.allocator, bad_state, values.len));

    const analysis = rans.analyze(values[0..]);
    try std.testing.expectError(error.InvalidAnalysis, rans.encodeAnalyzedAlloc(std.testing.allocator, values[0..4], analysis));
}

test "rans decodeInto matches decodeAlloc" {
    var values: [4096]u8 = undefined;
    for (0..values.len) |idx| values[idx] = if ((idx & 7) == 0) 5 else 9;

    const encoded = try rans.encodeAlloc(std.testing.allocator, values[0..]);
    defer std.testing.allocator.free(encoded);

    const decoded_alloc = try rans.decodeAlloc(std.testing.allocator, encoded, values.len);
    defer std.testing.allocator.free(decoded_alloc);

    var decoded_into: [4096]u8 = undefined;
    try rans.decodeInto(encoded, decoded_into[0..]);

    try std.testing.expectEqualSlices(u8, decoded_alloc, decoded_into[0..]);
}
