const std = @import("std");
const bitpack = @import("bitpack");

test "required bit width matches simple cases" {
    try std.testing.expectEqual(@as(u8, 0), bitpack.requiredBitWidth(0));
    try std.testing.expectEqual(@as(u8, 1), bitpack.requiredBitWidth(1));
    try std.testing.expectEqual(@as(u8, 2), bitpack.requiredBitWidth(2));
    try std.testing.expectEqual(@as(u8, 2), bitpack.requiredBitWidth(3));
    try std.testing.expectEqual(@as(u8, 8), bitpack.requiredBitWidth(255));
}

test "FOR bit-packing round-trips mixed values" {
    const input = [_]u64{ 1000, 1001, 1004, 1010, 1050, 2048 };

    const packed_values = try bitpack.packForU64(std.testing.allocator, &input);
    defer packed_values.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 1000), packed_values.base);
    try std.testing.expect(packed_values.bit_width > 0);

    const unpacked = try bitpack.unpackForU64(std.testing.allocator, packed_values);
    defer std.testing.allocator.free(unpacked);

    try std.testing.expectEqualSlices(u64, &input, unpacked);
}

test "FOR bit-packing handles empty input" {
    const input = [_]u64{};

    const packed_values = try bitpack.packForU64(std.testing.allocator, &input);
    defer packed_values.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), packed_values.count);
    try std.testing.expectEqual(@as(usize, 0), packed_values.payload.len);

    const unpacked = try bitpack.unpackForU64(std.testing.allocator, packed_values);
    defer std.testing.allocator.free(unpacked);

    try std.testing.expectEqual(@as(usize, 0), unpacked.len);
}

test "FOR bit-packing collapses constant arrays to zero-bit payload" {
    const input = [_]u64{ 77, 77, 77, 77 };

    const packed_values = try bitpack.packForU64(std.testing.allocator, &input);
    defer packed_values.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 77), packed_values.base);
    try std.testing.expectEqual(@as(u8, 0), packed_values.bit_width);
    try std.testing.expectEqual(@as(usize, 0), packed_values.payload.len);

    const unpacked = try bitpack.unpackForU64(std.testing.allocator, packed_values);
    defer std.testing.allocator.free(unpacked);

    try std.testing.expectEqualSlices(u64, &input, unpacked);
}
