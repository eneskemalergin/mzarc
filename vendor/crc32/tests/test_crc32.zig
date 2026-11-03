//! Public CRC-32 behavior checked against fixed words and an independent bit loop.
//! Private tests own the per-backend length and alignment matrix.

const std = @import("std");
const crc32 = @import("crc32");
const build_options = @import("build_options");

const STARTS = [_]u32{ 0, 1, 0x1234_5678, 0x8000_0000, 0xffff_ffff };

fn reference(start: u32, bytes: []const u8) u32 {
    var raw = ~start;
    for (bytes) |byte| {
        raw ^= byte;
        for (0..8) |_| raw = if (raw & 1 != 0) (raw >> 1) ^ 0xedb8_8320 else raw >> 1;
    }
    return ~raw;
}

fn advanceReference(start: u32, length: u64) u32 {
    var matrix: [32]u32 = undefined;
    for (&matrix, 0..) |*column, bit| {
        var raw = @as(u32, 1) << @intCast(bit);
        for (0..8) |_| raw = if (raw & 1 != 0) (raw >> 1) ^ 0xedb8_8320 else raw >> 1;
        column.* = raw;
    }
    var value = start;
    var remaining = length;
    while (remaining != 0) {
        if (remaining & 1 != 0) value = applyMatrix(matrix, value);
        remaining >>= 1;
        if (remaining == 0) break;
        var squared: [32]u32 = undefined;
        for (&squared, matrix) |*column, original| column.* = applyMatrix(matrix, original);
        matrix = squared;
    }
    return value;
}

fn applyMatrix(matrix: [32]u32, value: u32) u32 {
    var result: u32 = 0;
    for (matrix, 0..) |column, bit| {
        if (value & (@as(u32, 1) << @intCast(bit)) != 0) result ^= column;
    }
    return result;
}

test "[unit] - [hash]: matches fixed CRC-32/ISO-HDLC words" {
    const cases = [_]struct { input: []const u8, expected: u32 }{
        .{ .input = "", .expected = 0 },
        .{ .input = "a", .expected = 0xe8b7_be43 },
        .{ .input = "abc", .expected = 0x3524_41c2 },
        .{ .input = "123456789", .expected = 0xcbf4_3926 },
        .{ .input = "\x00", .expected = 0xd202_ef8d },
        .{ .input = "\xff", .expected = 0xff00_0000 },
        .{ .input = "IEND", .expected = 0xae42_6082 },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, crc32.hash(case.input));
    var bytes: [256]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast(index);
    try std.testing.expectEqual(@as(u32, 0x2905_8c73), crc32.hash(&bytes));
}

test "[property] - [update]: every short split continues any finalized start" {
    var bytes: [257]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x1357_2468);
    random.fill(&bytes);
    for (STARTS) |start| {
        try std.testing.expectEqual(start, crc32.update(start, ""));
        const expected = reference(start, &bytes);
        try std.testing.expectEqual(expected, crc32.update(start, &bytes));
        for (0..bytes.len + 1) |split| {
            const first = crc32.update(start, bytes[0..split]);
            try std.testing.expectEqual(expected, crc32.update(first, bytes[split..]));
            try std.testing.expectEqual(expected, crc32.combine(first, crc32.hash(bytes[split..]), bytes.len - split));
        }
    }
}

test "[property] - [update]: every starting-state bit agrees at block transitions" {
    const bytes = [_]u8{0xff} ** 513;
    for (0..32) |bit| {
        const start = @as(u32, 1) << @intCast(bit);
        for ([_]usize{ 0, 1, 7, 8, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 511, 512, 513 }) |length| {
            try std.testing.expectEqual(reference(start, bytes[0..length]), crc32.update(start, bytes[0..length]));
            try std.testing.expectEqual(reference(~start, bytes[0..length]), crc32.update(~start, bytes[0..length]));
        }
    }
}

test "[property] - [Stream]: arbitrary chunks and repeated final calls preserve continuation" {
    var bytes: [4096 + 31]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x2468_1357);
    random.fill(&bytes);
    const empty: crc32.Stream = .{};
    try std.testing.expectEqual(@as(u32, 0), empty.final());
    for (STARTS) |start| {
        const expected = reference(start, &bytes);
        for ([_]usize{ 1, 2, 7, 8, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 4096, 65536 }) |chunk| {
            var stream = crc32.Stream.init(start);
            try std.testing.expectEqual(start, stream.final());
            var offset: usize = 0;
            while (offset < bytes.len) {
                const end = offset + @min(chunk, bytes.len - offset);
                stream.update(bytes[offset..end]);
                const interim = stream.final();
                stream.update("");
                try std.testing.expectEqual(interim, stream.final());
                offset = end;
            }
            try std.testing.expectEqual(expected, stream.final());
            try std.testing.expectEqual(expected, stream.final());
            stream.update("suffix");
            try std.testing.expectEqual(reference(expected, "suffix"), stream.final());
        }
    }
}

test "[property] - [combine]: joins empty inputs and unequal larger partitions" {
    var bytes: [70_000]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x5a17_32c0);
    random.fill(&bytes);
    for (STARTS) |start| {
        const expected = reference(start, &bytes);
        for ([_]usize{ 0, 1, 15, 32, 64, 129, 4096, 65_535, 65_536, 69_999, 70_000 }) |split| {
            try std.testing.expectEqual(expected, crc32.combine(
                crc32.update(start, bytes[0..split]),
                crc32.hash(bytes[split..]),
                bytes.len - split,
            ));
        }
        try std.testing.expectEqual(start, crc32.combine(start, 0, 0));
    }
    try std.testing.expectEqual(@as(u32, 0xcbf4_3926), crc32.combine(0x9be3_e0a3, 0x131d_a070, 5));
}

test "[edge] - [combine]: large zero runs retain all 64 length bits" {
    // Fixed values were checked with the host zlib-ng crc32_combine64 function.
    const cases = [_]struct { length: u64, zeros: u32, expected: u32 }{
        .{ .length = 0xffff_ffff, .zeros = 0, .expected = 0x3524_41c2 },
        .{ .length = 0x1_0000_0000, .zeros = 0xd202_ef8d, .expected = 0xa75d_6850 },
        .{ .length = 0x1_0000_0001, .zeros = 0x41d9_12ff, .expected = 0xb9ce_e311 },
        .{ .length = (1 << 40) + 17, .zeros = 0xdca9_b915, .expected = 0x8bb3_029e },
        .{ .length = (1 << 63) - 1, .zeros = 0x00f9_3446, .expected = 0xe45f_24e4 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.zeros, ~advanceReference(0xffff_ffff, case.length));
        try std.testing.expectEqual(case.expected, crc32.combine(crc32.hash("abc"), case.zeros, case.length));
    }
    for ([_]u64{ 0, 1, 31, 256, 65_536, 1 << 32, 1 << 63, std.math.maxInt(u64) }) |length| {
        const zeros = ~advanceReference(0xffff_ffff, length);
        for (STARTS) |start| {
            const expected = ~advanceReference(~start, length);
            try std.testing.expectEqual(expected, crc32.combine(start, zeros, length));
        }
    }
}

test "[unit] - [backendFor]: disabled acceleration selects the portable calculation" {
    if (!build_options.accelerated) {
        for ([_]usize{ 0, 1, 32, 64, 128, std.math.maxInt(usize) }) |length|
            try std.testing.expectEqual(.portable, crc32.backendFor(length));
    }
}

test "[fuzz] - [CRC-32]: arbitrary bytes and partitions preserve finalized state" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var buffer: [4096]u8 = undefined;
            const bytes = buffer[0..smith.slice(&buffer)];
            const start = smith.value(u32);
            const split = smith.valueRangeAtMost(u32, 0, @intCast(bytes.len));
            const chunk = smith.valueRangeAtMost(u32, 1, buffer.len);
            const expected = reference(start, bytes);
            try std.testing.expectEqual(reference(0, bytes), crc32.hash(bytes));
            try std.testing.expectEqual(expected, crc32.update(start, bytes));
            const first = crc32.update(start, bytes[0..split]);
            try std.testing.expectEqual(expected, crc32.update(first, bytes[split..]));
            try std.testing.expectEqual(expected, crc32.combine(first, crc32.hash(bytes[split..]), bytes.len - split));
            var stream = crc32.Stream.init(start);
            var offset: usize = 0;
            while (offset < bytes.len) {
                const end = offset + @min(chunk, bytes.len - offset);
                stream.update(bytes[offset..end]);
                stream.update("");
                offset = end;
            }
            try std.testing.expectEqual(expected, stream.final());
        }
    }.run, .{ .corpus = &.{ "123456789", "\xff" ** 70, "\x00\x01\x02\x03" ** 256 } });
}

test "[property] - [Stream]: every intermediate result agrees across retained folds" {
    var bytes: [4097]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x8f0135);
    random.fill(&bytes);
    for (STARTS) |start| {
        for ([_]usize{ 1, 7, 15, 16, 17, 31, 63, 64, 65, 127, 128, 129, 255, 256, 257, 4096 }) |chunk| {
            var stream = crc32.Stream.init(start);
            var expected = start;
            var offset: usize = 0;
            while (offset != bytes.len) {
                const n = @min(chunk, bytes.len - offset);
                const part = bytes[offset..][0..n];
                stream.update(part);
                expected = reference(expected, part);
                try std.testing.expectEqual(expected, stream.final());
                try std.testing.expectEqual(expected, stream.final());
                offset += n;
            }
        }
    }
}
