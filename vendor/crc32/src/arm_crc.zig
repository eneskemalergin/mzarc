//! Internal AArch64 CRC instruction path for an uncomplemented raw register.
//!
//! The caller assumes `bytes` addresses `len` readable bytes and CRC instructions
//! are available. Any byte length is accepted. Loads interpret the bytes as
//! little-endian words. The caller complements the final register when needed.
//! Hidden visibility keeps the linker entry point private to the package.

const std = @import("std");

comptime {
    @export(&update, .{ .name = "crc32_arm_crc_update_raw", .visibility = .hidden });
}

fn update(start: u32, bytes: [*]const u8, len: usize) callconv(.c) u32 {
    var value = start;
    var offset: usize = 0;

    while (len - offset >= 8) : (offset += 8) {
        const word = std.mem.readInt(u64, bytes[offset..][0..8], .little);
        value = asm ("crc32x w0, w1, %[word]"
            : [result] "={w0}" (-> u32),
            : [previous] "{w1}" (value),
              [word] "{w2}" (word),
        );
    }
    while (len - offset >= 4) : (offset += 4) {
        const word = std.mem.readInt(u32, bytes[offset..][0..4], .little);
        value = asm ("crc32w w0, w1, w2"
            : [result] "={w0}" (-> u32),
            : [previous] "{w1}" (value),
              [word] "{x2}" (@as(u64, word)),
        );
    }
    while (len - offset >= 2) : (offset += 2) {
        const word = std.mem.readInt(u16, bytes[offset..][0..2], .little);
        value = asm ("crc32h w0, w1, w2"
            : [result] "={w0}" (-> u32),
            : [previous] "{w1}" (value),
              [word] "{x2}" (@as(u64, word)),
        );
    }
    while (offset < len) : (offset += 1) {
        value = asm ("crc32b w0, w1, w2"
            : [result] "={w0}" (-> u32),
            : [previous] "{w1}" (value),
              [byte] "{x2}" (@as(u64, bytes[offset])),
        );
    }
    return value;
}
