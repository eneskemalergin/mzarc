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

test "FOR bit-packing round-trips adversarial bit widths" {
    const cases = [_]struct {
        values: []const u64,
        expected_bit_width: u8,
    }{
        .{ .values = &[_]u64{ 5, 4, 5, 4, 5 }, .expected_bit_width = 1 },
        .{ .values = &[_]u64{ 100, 227, 163, 191, 150 }, .expected_bit_width = 7 },
        .{ .values = &[_]u64{ 1000, 1255, 1000, 1020 }, .expected_bit_width = 8 },
        .{ .values = &[_]u64{ 5000, 5512, 5000, 5256 }, .expected_bit_width = 10 },
        .{ .values = &[_]u64{ 1 << 40, (1 << 40) + (@as(u64, 1) << 31), (1 << 40) + 17 }, .expected_bit_width = 32 },
        .{ .values = &[_]u64{ 0, (@as(u64, 1) << 63) - 1 }, .expected_bit_width = 63 },
    };

    for (cases) |case| {
        const packed_values = try bitpack.packForU64(std.testing.allocator, case.values);
        defer packed_values.deinit(std.testing.allocator);

        try std.testing.expectEqual(case.expected_bit_width, packed_values.bit_width);

        const unpacked = try bitpack.unpackForU64(std.testing.allocator, packed_values);
        defer std.testing.allocator.free(unpacked);
        try std.testing.expectEqualSlices(u64, case.values, unpacked);
    }
}

test "FOR unpack rejects truncated payload" {
    const packed_values = bitpack.PackedU64{
        .base = 10,
        .bit_width = 9,
        .count = 4,
        .payload = &[_]u8{ 0xaa, 0xbb, 0xcc },
    };

    try std.testing.expectError(error.UnexpectedEndOfStream, bitpack.unpackForU64(std.testing.allocator, packed_values));
}
