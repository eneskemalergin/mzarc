const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const PackedU64 = struct {
    base: u64,
    bit_width: u8,
    count: usize,
    payload: []const u8,

    pub fn deinit(self: PackedU64, allocator: Allocator) void {
        allocator.free(self.payload);
    }
};

pub fn requiredBitWidth(value: u64) u8 {
    if (value == 0) return 0;
    return @as(u8, @intCast(@bitSizeOf(u64) - @clz(value)));
}

pub fn packForU64(allocator: Allocator, values: []const u64) !PackedU64 {
    if (values.len == 0) {
        return .{
            .base = 0,
            .bit_width = 0,
            .count = 0,
            .payload = try allocator.alloc(u8, 0),
        };
    }

    var base = values[0];
    var max_offset: u64 = 0;
    for (values) |value| {
        if (value < base) base = value;
    }
    for (values) |value| {
        const offset = value - base;
        if (offset > max_offset) max_offset = offset;
    }

    const bit_width = requiredBitWidth(max_offset);
    const payload_len = if (bit_width == 0) 0 else ((@as(usize, bit_width) * values.len) + 7) / 8;
    var payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    @memset(payload, 0);

    if (bit_width == 0) {
        return .{
            .base = base,
            .bit_width = 0,
            .count = values.len,
            .payload = payload,
        };
    }

    var bit_offset: usize = 0;
    for (values) |value| {
        var remaining = bit_width;
        var current = value - base;

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
        .count = values.len,
        .payload = payload,
    };
}

pub fn unpackForU64(allocator: Allocator, packed_values: PackedU64) ![]u64 {
    const values = try allocator.alloc(u64, packed_values.count);
    errdefer allocator.free(values);

    if (packed_values.count == 0) return values;

    if (packed_values.bit_width == 0) {
        for (values) |*value| {
            value.* = packed_values.base;
        }
        return values;
    }

    var bit_offset: usize = 0;
    for (values) |*value| {
        var offset: u64 = 0;
        var written: u8 = 0;

        while (written < packed_values.bit_width) {
            const bit_index = bit_offset & 7;
            const available_bits = 8 - bit_index;
            const chunk_bits: u8 = @intCast(@min(@as(usize, packed_values.bit_width - written), available_bits));
            const mask = (@as(u64, 1) << @as(u6, @intCast(chunk_bits))) - 1;
            const byte = packed_values.payload[bit_offset / 8];
            const chunk = (@as(u64, byte) >> @as(u6, @intCast(bit_index))) & mask;
            offset |= chunk << @as(u6, @intCast(written));

            bit_offset += chunk_bits;
            written += chunk_bits;
        }

        const sum = @addWithOverflow(packed_values.base, offset);
        if (sum[1] != 0) return error.Overflow;
        value.* = sum[0];
    }

    return values;
}
