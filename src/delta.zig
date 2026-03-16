const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub fn deltaEncodeU64(allocator: Allocator, values: []const u64) ![]u64 {
    var out = try allocator.alloc(u64, values.len);
    errdefer allocator.free(out);

    if (values.len == 0) return out;

    out[0] = values[0];
    var previous = values[0];
    for (values[1..], 1..) |value, idx| {
        if (value < previous) return error.NonMonotonicInput;
        out[idx] = value - previous;
        previous = value;
    }

    return out;
}

pub fn deltaDecodeU64(allocator: Allocator, deltas: []const u64) ![]u64 {
    var out = try allocator.alloc(u64, deltas.len);
    errdefer allocator.free(out);

    if (deltas.len == 0) return out;

    out[0] = deltas[0];
    var previous = out[0];
    for (deltas[1..], 1..) |delta, idx| {
        const sum = @addWithOverflow(previous, delta);
        if (sum[1] != 0) return error.Overflow;
        out[idx] = sum[0];
        previous = out[idx];
    }

    return out;
}
