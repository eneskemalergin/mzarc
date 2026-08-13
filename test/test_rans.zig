//! rANS round trips, resource bounds, malformed streams, and allocation cleanup.

const std = @import("std");
const rans = @import("rans");

fn checkAllocationFailures(allocator: std.mem.Allocator, values: []const u8) !void {
    const encoded = try rans.encodeAlloc(allocator, values);
    defer allocator.free(encoded);

    const decoded = try rans.decodeAlloc(allocator, encoded, values.len);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, values, decoded);
}

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

test "[unit] - [four-state rANS bytes]: matches a hand-calculated stream" {
    const input = [_]u8{ 0, 1, 2, 3 };
    var expected: [528]u8 = @splat(0);

    // Four equally likely symbols normalize to 1024 and each updates one state without renormalizing.
    for (0..4) |symbol| {
        std.mem.writeInt(u16, expected[symbol * 2 ..][0..2], 1024, .little);
        std.mem.writeInt(
            u32,
            expected[512 + symbol * 4 ..][0..4],
            0x0200_0000 + @as(u32, @intCast(symbol)) * 1024,
            .little,
        );
    }

    const encoded = try rans.encodeAlloc(std.testing.allocator, &input);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &expected, encoded);

    const decoded = try rans.decodeAlloc(std.testing.allocator, &expected, input.len);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, &input, decoded);
}

test "[property] - [rANS resource bound]: encoded output stays within the decoder limit" {
    var values: [4096]u8 = undefined;
    for (&values, 0..) |*value, idx| value.* = @truncate(idx);

    const encoded = try rans.encodeAlloc(std.testing.allocator, &values);
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(encoded.len <= try rans.maxEncodedLen(values.len));
    try std.testing.expectEqual(@as(usize, 0), try rans.maxEncodedLen(0));
    try std.testing.expectError(error.Overflow, rans.maxEncodedLen(std.math.maxInt(usize)));
}

test "[failure] - [rANS stream]: rejects malformed bytes and analysis mismatch" {
    var values: [1024]u8 = undefined;
    for (&values, 0..) |*value, idx| value.* = if (idx % 17 == 0) @truncate(idx) else 9;
    const encoded = try rans.encodeAlloc(std.testing.allocator, values[0..]);
    defer std.testing.allocator.free(encoded);

    const with_trailing = try std.testing.allocator.alloc(u8, encoded.len + 1);
    defer std.testing.allocator.free(with_trailing);
    @memcpy(with_trailing[0..encoded.len], encoded);
    with_trailing[encoded.len] = 0;
    try std.testing.expectError(error.TrailingData, rans.decodeAlloc(std.testing.allocator, with_trailing, values.len));

    // Header-only truncation (freqs + four states) exercises mid-decode renorm starvation.
    try std.testing.expect(encoded.len > 528);
    try std.testing.expectError(error.UnexpectedEndOfStream, rans.decodeAlloc(std.testing.allocator, encoded[0..528], values.len));
    try std.testing.expectError(error.UnexpectedEndOfStream, rans.decodeAlloc(std.testing.allocator, encoded[0..8], values.len));

    var bad_freqs = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(bad_freqs);
    @memset(bad_freqs[0..512], 0);
    try std.testing.expectError(error.InvalidFrequencyTable, rans.decodeAlloc(std.testing.allocator, bad_freqs, values.len));

    var bad_state = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(bad_state);
    for (0..4) |state_index| {
        const state_offset = 512 + state_index * @sizeOf(u32);
        const original_state = bad_state[state_offset..][0..@sizeOf(u32)].*;
        std.mem.writeInt(u32, bad_state[state_offset..][0..@sizeOf(u32)], 0, .little);
        try std.testing.expectError(error.InvalidState, rans.decodeAlloc(std.testing.allocator, bad_state, values.len));
        bad_state[state_offset..][0..@sizeOf(u32)].* = original_state;
    }

    const analysis = rans.analyze(values[0..]);
    try std.testing.expectError(error.InvalidAnalysis, rans.encodeAnalyzedAlloc(std.testing.allocator, values[0..4], analysis));
}

test "[failure] - [rANS final states]: rejects unused state data" {
    const encoded = try rans.encodeAlloc(std.testing.allocator, &[_]u8{7});
    defer std.testing.allocator.free(encoded);
    const corrupted = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(corrupted);

    const second_state_offset = 256 * @sizeOf(u16) + @sizeOf(u32);
    std.mem.writeInt(
        u32,
        corrupted[second_state_offset..][0..@sizeOf(u32)],
        (@as(u32, 1) << 23) + 1,
        .little,
    );
    var decoded: [1]u8 = undefined;
    try std.testing.expectError(error.InvalidState, rans.decodeInto(corrupted, &decoded));
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

test "[failure] - [rANS allocation]: cleans up every induced encode and decode failure" {
    var values: [8192]u8 = undefined;
    for (&values, 0..) |*value, idx| value.* = if (idx % 17 == 0) @truncate(idx) else 9;

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkAllocationFailures,
        .{values[0..]},
    );
}
