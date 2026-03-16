const std = @import("std");
const delta = @import("delta");

test "delta round-trip preserves monotonic u64 arrays" {
    const input = [_]u64{ 50, 50, 75, 120, 120, 500 };

    const encoded = try delta.deltaEncodeU64(std.testing.allocator, &input);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualSlices(u64, &[_]u64{ 50, 0, 25, 45, 0, 380 }, encoded);

    const decoded = try delta.deltaDecodeU64(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualSlices(u64, &input, decoded);
}

test "delta supports empty and single-element inputs" {
    const empty = [_]u64{};
    const single = [_]u64{123456};

    const encoded_empty = try delta.deltaEncodeU64(std.testing.allocator, &empty);
    defer std.testing.allocator.free(encoded_empty);
    try std.testing.expectEqual(@as(usize, 0), encoded_empty.len);

    const decoded_empty = try delta.deltaDecodeU64(std.testing.allocator, &empty);
    defer std.testing.allocator.free(decoded_empty);
    try std.testing.expectEqual(@as(usize, 0), decoded_empty.len);

    const encoded_single = try delta.deltaEncodeU64(std.testing.allocator, &single);
    defer std.testing.allocator.free(encoded_single);
    try std.testing.expectEqualSlices(u64, &single, encoded_single);

    const decoded_single = try delta.deltaDecodeU64(std.testing.allocator, encoded_single);
    defer std.testing.allocator.free(decoded_single);
    try std.testing.expectEqualSlices(u64, &single, decoded_single);
}

test "delta encoding rejects decreasing input" {
    const input = [_]u64{ 10, 9, 11 };
    try std.testing.expectError(error.NonMonotonicInput, delta.deltaEncodeU64(std.testing.allocator, &input));
}

test "delta decoding rejects overflow" {
    const input = [_]u64{ std.math.maxInt(u64), 1 };
    try std.testing.expectError(error.Overflow, delta.deltaDecodeU64(std.testing.allocator, &input));
}
