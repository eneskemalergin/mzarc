//! FOR packing, malformed payloads, and scalar differential checks.

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
        .{ .values = &[_]u64{ 0, std.math.maxInt(u64) }, .expected_bit_width = 64 },
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

fn expectScalarPackMatches(values: []const u64) !void {
    const reference = try bitpack.packForU64(std.testing.allocator, values);
    defer reference.deinit(std.testing.allocator);

    const payload_len = try bitpack.packedByteLen(reference.bit_width, values.len);
    const payload = try std.testing.allocator.alloc(u8, payload_len);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0);

    var bit_offset: usize = 0;
    for (values) |value| {
        bitpack.packNextForValue(payload, reference.bit_width, &bit_offset, reference.base, value);
    }

    try std.testing.expectEqual(reference.payload.len, payload.len);
    try std.testing.expectEqualSlices(u8, reference.payload, payload);
}

fn expectU16PackMatches(values: []const u16) !void {
    const widened = try std.testing.allocator.alloc(u64, values.len);
    defer std.testing.allocator.free(widened);
    for (values, widened) |value, *wide| wide.* = value;

    const reference = try bitpack.packForU64(std.testing.allocator, widened);
    defer reference.deinit(std.testing.allocator);
    const candidate = try bitpack.packForU16(std.testing.allocator, values);
    defer candidate.deinit(std.testing.allocator);

    try std.testing.expectEqual(reference.base, candidate.base);
    try std.testing.expectEqual(reference.bit_width, candidate.bit_width);
    try std.testing.expectEqual(reference.count, candidate.count);
    try std.testing.expectEqualSlices(u8, reference.payload, candidate.payload);
}

test "[unit] - [FOR packing]: scalar writes match u64 packing" {
    try expectScalarPackMatches(&.{});
    try expectScalarPackMatches(&.{ 77, 77, 77, 77 });
    try expectScalarPackMatches(&.{ 0, std.math.maxInt(u64) });
    try expectScalarPackMatches(&.{ 0, 1, 7, 255, 65_535, 1_000_000_000 });
    try expectScalarPackMatches(&.{ 1_000_000_000, 65_535, 255, 7, 1, 0 });

    const f32_values = [_]f32{ 0.0, -0.0, 1.0, -1.0, std.math.inf(f32), -std.math.inf(f32) };
    var f32_exponents: [f32_values.len]u64 = undefined;
    for (f32_values, &f32_exponents) |value, *exponent| {
        exponent.* = @as(u32, @bitCast(value)) >> 24;
    }
    try expectScalarPackMatches(&f32_exponents);

    var generated: [257]u64 = undefined;
    var state: u64 = 0x4d5a_4152_3400_0001;
    for (&generated) |*value| {
        state = state *% 6_364_136_223_846_793_005 +% 1_442_695_040_888_963_407;
        value.* = state & 0x0000_ffff_ffff_ffff;
    }
    try expectScalarPackMatches(&generated);
}

test "[unit] - [FOR packing]: u16 input matches widened u64 packing" {
    try expectU16PackMatches(&.{});
    try expectU16PackMatches(&.{ 4096, 4096, 4096 });
    try expectU16PackMatches(&.{ 0, std.math.maxInt(u16) });
    try expectU16PackMatches(&.{ 0, 1, 17, 255, 4096, 16_384, 65_535 });
    try expectU16PackMatches(&.{ 65_535, 16_384, 4096, 255, 17, 1, 0 });

    var generated: [257]u16 = undefined;
    var state: u32 = 0x3400_0001;
    for (&generated) |*value| {
        state = state *% 1_664_525 +% 1_013_904_223;
        value.* = @truncate(state);
    }
    try expectU16PackMatches(&generated);
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

test "FOR unpack rejects base plus offset overflow" {
    const packed_values = bitpack.PackedU64{
        .base = std.math.maxInt(u64),
        .bit_width = 1,
        .count = 1,
        .payload = &[_]u8{0x01},
    };

    try std.testing.expectError(error.Overflow, bitpack.unpackForU64(std.testing.allocator, packed_values));
}

test "FOR unpack rejects bit_width above 64" {
    const packed_values = bitpack.PackedU64{
        .base = 0,
        .bit_width = 65,
        .count = 1,
        .payload = &[_]u8{0} ** 9,
    };

    try std.testing.expectError(error.InvalidBitWidth, bitpack.unpackForU64(std.testing.allocator, packed_values));
}

test "[failure] - [FOR padding]: rejects nonzero unused bits" {
    const packed_values = bitpack.PackedU64{
        .base = 0,
        .bit_width = 1,
        .count = 1,
        .payload = &[_]u8{0b1000_0001},
    };

    try std.testing.expectError(
        error.NonzeroPadding,
        bitpack.unpackForU64(std.testing.allocator, packed_values),
    );
}

fn unpackBitByBitRef(allocator: std.mem.Allocator, packed_values: bitpack.PackedU64) ![]u64 {
    const values = try allocator.alloc(u64, packed_values.count);
    errdefer allocator.free(values);
    var bit_offset: usize = 0;
    for (values) |*value| {
        value.* = try unpackBitByBitNext(packed_values.payload, packed_values.bit_width, &bit_offset, packed_values.base);
    }
    return values;
}

fn unpackBitByBitNext(payload: []const u8, bit_width: u8, bit_offset: *usize, base: u64) !u64 {
    var offset: u64 = 0;
    var written: u8 = 0;
    while (written < bit_width) {
        const bit_index = bit_offset.* & 7;
        const available_bits = 8 - bit_index;
        const chunk_bits: u8 = @intCast(@min(@as(usize, bit_width - written), available_bits));
        const mask = (@as(u64, 1) << @as(u6, @intCast(chunk_bits))) - 1;
        const byte = payload[bit_offset.* / 8];
        const chunk = (@as(u64, byte) >> @as(u6, @intCast(bit_index))) & mask;
        offset |= chunk << @as(u6, @intCast(written));
        bit_offset.* += chunk_bits;
        written += chunk_bits;
    }
    const sum = @addWithOverflow(base, offset);
    if (sum[1] != 0) return error.Overflow;
    return sum[0];
}

fn packFixedWidth(allocator: std.mem.Allocator, base: u64, bit_width: u8, residuals: []const u64) !bitpack.PackedU64 {
    const bits = try std.math.mul(usize, bit_width, residuals.len);
    const payload_len = (try std.math.add(usize, bits, 7)) / 8;
    var payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    @memset(payload, 0);
    var bit_offset: usize = 0;
    for (residuals) |residual| {
        var remaining = bit_width;
        var current = residual;
        while (remaining > 0) {
            const bit_index = bit_offset & 7;
            const free_bits = 8 - bit_index;
            const chunk_bits: u8 = @intCast(@min(@as(usize, remaining), free_bits));
            const mask = (@as(u64, 1) << @as(u6, @intCast(chunk_bits))) - 1;
            const chunk = current & mask;
            payload[bit_offset / 8] |= @as(u8, @intCast(chunk << @as(u6, @intCast(bit_index))));
            current >>= @as(u6, @intCast(chunk_bits));
            bit_offset += chunk_bits;
            remaining -= chunk_bits;
        }
    }
    return .{
        .base = base,
        .bit_width = bit_width,
        .count = residuals.len,
        .payload = payload,
    };
}

test "FOR word unpack matches bit-by-bit reference across widths" {
    var width: u8 = 1;
    while (width <= 64) : (width += 1) {
        const count: usize = 17;
        var residuals: [17]u64 = undefined;
        const max_off: u64 = if (width == 64) std.math.maxInt(u64) else (@as(u64, 1) << @as(u6, @intCast(width))) - 1;
        for (&residuals, 0..) |*r, i| {
            if (width == 64) {
                r.* = @as(u64, @intCast(i)) *% 0x9e3779b97f4a7c15;
            } else {
                r.* = @as(u64, @intCast(i * 3 + 1)) & max_off;
            }
        }
        residuals[0] = 0;
        residuals[count - 1] = max_off;

        const packed_values = try packFixedWidth(std.testing.allocator, 0, width, &residuals);
        defer packed_values.deinit(std.testing.allocator);

        const word = try bitpack.unpackForU64(std.testing.allocator, packed_values);
        defer std.testing.allocator.free(word);
        const ref = try unpackBitByBitRef(std.testing.allocator, packed_values);
        defer std.testing.allocator.free(ref);
        try std.testing.expectEqualSlices(u64, ref, word);

        var bit_offset: usize = 0;
        for (ref) |expected| {
            const got = try bitpack.unpackNextForValue(packed_values.payload, width, &bit_offset, 0);
            try std.testing.expectEqual(expected, got);
        }
    }
}
