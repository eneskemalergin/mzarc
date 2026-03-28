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

    const encoded = try rans.encodeAlloc(std.testing.allocator, values[0..]);
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

test "rans rejects trailing data" {
    const values = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const encoded = try rans.encodeAlloc(std.testing.allocator, values[0..]);
    defer std.testing.allocator.free(encoded);

    const with_trailing = try std.testing.allocator.alloc(u8, encoded.len + 1);
    defer std.testing.allocator.free(with_trailing);
    @memcpy(with_trailing[0..encoded.len], encoded);
    with_trailing[encoded.len] = 0;

    try std.testing.expectError(error.TrailingData, rans.decodeAlloc(std.testing.allocator, with_trailing, values.len));
}