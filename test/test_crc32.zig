//! CRC32 known-vector, differential, boundary, and alignment checks.

const std = @import("std");
const crc32 = @import("crc32");

fn expectMatchesStandard(bytes: []const u8) !void {
    try std.testing.expectEqual(std.hash.crc.Crc32.hash(bytes), crc32.hash(bytes));
}

test "[unit] - [CRC32]: matches known vectors" {
    try std.testing.expectEqual(@as(u32, 0), crc32.hash(""));
    try std.testing.expectEqual(@as(u32, 0xcbf4_3926), crc32.hash("123456789"));
}

test "[property] - [CRC32]: matches standard across lengths and alignments" {
    var data: [4104]u8 = undefined;
    var state: u32 = 0x6d7a_9e31;
    for (&data) |*byte| {
        state = state *% 1_664_525 +% 1_013_904_223;
        byte.* = @truncate(state >> 24);
    }

    for (0..8) |alignment| {
        for (0..80) |len| try expectMatchesStandard(data[alignment..][0..len]);
        for ([_]usize{ 127, 128, 129, 255, 256, 257, 1023, 1024, 1025, 4096 }) |len| {
            try expectMatchesStandard(data[alignment..][0..len]);
        }
    }
}

test "[property] - [CRC32]: matches standard for repeated bytes" {
    var data: [4096]u8 = undefined;
    for ([_]u8{ 0x00, 0x01, 0x7f, 0x80, 0xff }) |byte| {
        @memset(&data, byte);
        try expectMatchesStandard(&data);
    }
}
