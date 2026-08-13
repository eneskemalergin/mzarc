//! FOR bit-pack/unpack for u64 residuals.
//! Wire payload is little-endian; pack and unpack must match bit-exactly.
//! Unpack assembles residuals word-at-a-time (u64 when width<=57, else u128).

const std = @import("std");

const Allocator = std.mem.Allocator;

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
    return @intCast(@bitSizeOf(u64) - @clz(value));
}

pub fn packedByteLen(bit_width: u8, count: usize) !usize {
    if (bit_width == 0 or count == 0) return 0;
    const bits = try std.math.mul(usize, bit_width, count);
    return (try std.math.add(usize, bits, 7)) / 8;
}

pub fn validatePayload(payload: []const u8, bit_width: u8, count: usize) !void {
    if (bit_width > 64) return error.InvalidBitWidth;
    const expected_len = try packedByteLen(bit_width, count);
    if (payload.len < expected_len) return error.UnexpectedEndOfStream;
    if (payload.len != expected_len) return error.TrailingData;
    if (expected_len == 0) return;

    const used_bits = try std.math.mul(usize, bit_width, count);
    const final_bits = used_bits & 7;
    if (final_bits == 0) return;
    const used_mask = (@as(u8, 1) << @as(u3, @intCast(final_bits))) - 1;
    if ((payload[expected_len - 1] & ~used_mask) != 0) return error.NonzeroPadding;
}

/// Appends one value to a zero-initialized FOR payload whose base and width
/// were established by an earlier pass.
pub fn packNextForValue(
    payload: []u8,
    bit_width: u8,
    bit_offset: *usize,
    base: u64,
    value: u64,
) void {
    std.debug.assert(bit_width <= 64);
    std.debug.assert(value >= base);
    const current_value = value - base;
    std.debug.assert(requiredBitWidth(current_value) <= bit_width);
    std.debug.assert(bit_offset.* <= std.math.maxInt(usize) - @as(usize, bit_width));
    const final_bit_offset = bit_offset.* + bit_width;
    const required_bytes = final_bit_offset / 8 + @intFromBool((final_bit_offset & 7) != 0);
    std.debug.assert(payload.len >= required_bytes);

    var remaining = bit_width;
    var current = current_value;
    while (remaining > 0) {
        const bit_index = bit_offset.* & 7;
        const free_bits = 8 - bit_index;
        const chunk_bits: u8 = @intCast(@min(@as(usize, remaining), free_bits));
        const mask = (@as(u64, 1) << @as(u6, @intCast(chunk_bits))) - 1;
        const chunk = current & mask;
        payload[bit_offset.* / 8] |= @as(u8, @intCast(chunk << @as(u6, @intCast(bit_index))));
        current >>= @as(u6, @intCast(chunk_bits));
        bit_offset.* += chunk_bits;
        remaining -= chunk_bits;
    }
}

fn packForUnsigned(comptime T: type, allocator: Allocator, values: []const T) !PackedU64 {
    if (values.len == 0) {
        return .{
            .base = 0,
            .bit_width = 0,
            .count = 0,
            .payload = try allocator.alloc(u8, 0),
        };
    }

    var base = values[0];
    var max_value = values[0];
    for (values[1..]) |value| {
        base = @min(base, value);
        max_value = @max(max_value, value);
    }

    const base_u64: u64 = base;
    const bit_width = requiredBitWidth(@as(u64, max_value) - base_u64);
    const payload_len = try packedByteLen(bit_width, values.len);
    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    @memset(payload, 0);

    if (bit_width != 0) {
        var bit_offset: usize = 0;
        for (values) |value| {
            packNextForValue(payload, bit_width, &bit_offset, base_u64, value);
        }
    }

    return .{
        .base = base_u64,
        .bit_width = bit_width,
        .count = values.len,
        .payload = payload,
    };
}

pub fn packForU64(allocator: Allocator, values: []const u64) !PackedU64 {
    return packForUnsigned(u64, allocator, values);
}

pub fn packForU16(allocator: Allocator, values: []const u16) !PackedU64 {
    return packForUnsigned(u16, allocator, values);
}

pub fn unpackForU64(allocator: Allocator, packed_values: PackedU64) ![]u64 {
    try validatePayload(packed_values.payload, packed_values.bit_width, packed_values.count);

    const values = try allocator.alloc(u64, packed_values.count);
    errdefer allocator.free(values);
    if (packed_values.count == 0) return values;

    if (packed_values.bit_width == 0) {
        @memset(values, packed_values.base);
        return values;
    }

    var bit_offset: usize = 0;
    for (values) |*value| {
        value.* = try readWordAccum(packed_values.payload, packed_values.bit_width, bit_offset, packed_values.base);
        bit_offset += packed_values.bit_width;
    }
    return values;
}

/// One FOR value from `payload` at `bit_offset` (advanced by `bit_width`). Same wire as `unpackForU64`.
pub fn unpackNextForValue(payload: []const u8, bit_width: u8, bit_offset: *usize, base: u64) !u64 {
    if (bit_width == 0) return base;
    if (bit_width > 64) return error.InvalidBitWidth;

    const value = try readWordAccum(payload, bit_width, bit_offset.*, base);
    bit_offset.* += bit_width;
    return value;
}

fn readWordAccum(payload: []const u8, bit_width: u8, bit_offset: usize, base: u64) !u64 {
    if (bit_width <= 57) {
        return readWordAccumU64(payload, bit_width, bit_offset, base);
    }
    return readWordAccumU128(payload, bit_width, bit_offset, base);
}

fn readWordAccumU64(payload: []const u8, bit_width: u8, bit_offset: usize, base: u64) !u64 {
    const mask = (@as(u64, 1) << @as(u6, @intCast(bit_width))) - 1;
    const byte_i = bit_offset / 8;
    const bit_i: u6 = @intCast(bit_offset & 7);
    const need = @as(usize, bit_width) + bit_i;
    const bytes_needed = (need + 7) / 8;

    var acc: u64 = 0;
    var b: usize = 0;
    while (b < bytes_needed) : (b += 1) {
        acc |= @as(u64, payload[byte_i + b]) << @as(u6, @intCast(b * 8));
    }

    const offset = (acc >> bit_i) & mask;
    const sum = @addWithOverflow(base, offset);
    if (sum[1] != 0) return error.Overflow;
    return sum[0];
}

fn readWordAccumU128(payload: []const u8, bit_width: u8, bit_offset: usize, base: u64) !u64 {
    const mask: u64 = if (bit_width == 64)
        std.math.maxInt(u64)
    else
        (@as(u64, 1) << @as(u6, @intCast(bit_width))) - 1;

    const byte_i = bit_offset / 8;
    const bit_i: u6 = @intCast(bit_offset & 7);
    const need = @as(usize, bit_width) + bit_i;
    const bytes_needed = (need + 7) / 8;

    var acc: u128 = 0;
    var b: usize = 0;
    while (b < bytes_needed) : (b += 1) {
        acc |= @as(u128, payload[byte_i + b]) << @as(u7, @intCast(b * 8));
    }

    const offset: u64 = @truncate((acc >> bit_i) & @as(u128, mask));
    const sum = @addWithOverflow(base, offset);
    if (sum[1] != 0) return error.Overflow;
    return sum[0];
}
