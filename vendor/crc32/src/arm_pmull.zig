//! Internal little-endian AArch64 PMULL folding of an uncomplemented raw register.
//!
//! The caller assumes `bytes` addresses `len` readable bytes and PMULL is legal.
//! This function asserts `len >= 64` and `len % 16 == 0`; loads need no alignment.
//! The caller handles partial blocks and complements the result when needed.
//! Hidden visibility keeps the linker entry point private to the package.
//! Test builds evaluate the arithmetic at compile time without exporting the
//! hardware entry point or executing PMULL instructions.

const std = @import("std");
const builtin = @import("builtin");

const X = @Vector(2, u64);
const K1K2: X = .{ 0x0154_442b_d4, 0x01c6_e415_96 };
const K3K4: X = .{ 0x0175_1997_d0, 0x00cc_aa00_9e };
const K5K0: X = .{ 0x0163_cd61_24, 0 };
const POLYNOMIAL: X = .{ 0x01db_7106_41, 0x01f7_0116_41 };
const MASK32: X = .{ 0x0000_0000_ffff_ffff, 0x0000_0000_ffff_ffff };

comptime {
    if (!builtin.is_test)
        @export(&update, .{ .name = "crc32_arm_pmull_update_raw", .visibility = .hidden });
}

fn update(start: u32, bytes: [*]const u8, len: usize) callconv(.c) u32 {
    std.debug.assert(len >= 64);
    std.debug.assert(len % 16 == 0);

    var x1 = loadu(bytes + 0);
    var x2 = loadu(bytes + 16);
    var x3 = loadu(bytes + 32);
    var x4 = loadu(bytes + 48);
    x1[0] ^= start;

    var offset: usize = 64;
    while (offset + 64 <= len) : (offset += 64) {
        const y1 = loadu(bytes + offset + 0);
        const y2 = loadu(bytes + offset + 16);
        const y3 = loadu(bytes + offset + 32);
        const y4 = loadu(bytes + offset + 48);
        const a1 = clmul(x1, K1K2, .low);
        const a2 = clmul(x2, K1K2, .low);
        const a3 = clmul(x3, K1K2, .low);
        const a4 = clmul(x4, K1K2, .low);
        x1 = clmul(x1, K1K2, .high) ^ a1 ^ y1;
        x2 = clmul(x2, K1K2, .high) ^ a2 ^ y2;
        x3 = clmul(x3, K1K2, .high) ^ a3 ^ y3;
        x4 = clmul(x4, K1K2, .high) ^ a4 ^ y4;
    }

    const k16 = K3K4;
    var product = clmul(x1, k16, .low);
    x1 = clmul(x1, k16, .high) ^ x2 ^ product;
    product = clmul(x1, k16, .low);
    x1 = clmul(x1, k16, .high) ^ x3 ^ product;
    product = clmul(x1, k16, .low);
    x1 = clmul(x1, k16, .high) ^ x4 ^ product;

    while (offset < len) : (offset += 16) {
        const next = loadu(bytes + offset);
        product = clmul(x1, k16, .low);
        x1 = clmul(x1, k16, .high) ^ next ^ product;
    }
    return reduce128(x1);
}

const Half = enum { low, high };

inline fn clmul(x: X, y: X, comptime half: Half) X {
    // Compile-time evaluation checks this instruction schedule on non-Arm hosts.
    if (@inComptime()) {
        var a: u128 = x[@intFromEnum(half)];
        var b = y[@intFromEnum(half)];
        var product: u128 = 0;
        while (b != 0) : (b >>= 1) {
            if (b & 1 != 0) product ^= a;
            a <<= 1;
        }
        return @bitCast(product);
    }
    return switch (half) {
        .low => asm ("pmull %[out].1q, %[x].1d, %[y].1d"
            : [out] "=w" (-> X),
            : [x] "w" (x),
              [y] "w" (y),
        ),
        .high => asm ("pmull2 %[out].1q, %[x].2d, %[y].2d"
            : [out] "=w" (-> X),
            : [x] "w" (x),
              [y] "w" (y),
        ),
    };
}

inline fn loadu(pointer: [*]const u8) X {
    const bytes: [16]u8 = pointer[0..16].*;
    return @bitCast(bytes);
}

inline fn shiftRightBytes(value: X, comptime count: u8) X {
    const input: @Vector(16, u8) = @bitCast(value);
    var output: @Vector(16, u8) = @splat(0);
    comptime var index: usize = 0;
    inline while (index + count < 16) : (index += 1) output[index] = input[index + count];
    return @bitCast(output);
}

fn reduce128(input: X) u32 {
    var value = input;
    var product = clmul(value, X{ K3K4[1], 0 }, .low);
    value = shiftRightBytes(value, 8) ^ product;
    product = clmul(value & MASK32, K5K0, .low);
    value = shiftRightBytes(value, 4) ^ product;
    var term = value & MASK32;
    term = clmul(term, X{ POLYNOMIAL[1], 0 }, .low) & MASK32;
    term = clmul(term, POLYNOMIAL, .low);
    value ^= term;
    const words: @Vector(4, u32) = @bitCast(value);
    return words[1];
}

test "[property] - [PMULL folding]: compile-time products agree with the independent CRC" {
    if (builtin.cpu.arch.endian() != .little) return error.SkipZigTest;
    const bytes = comptime block: {
        @setEvalBranchQuota(10_000);
        var buffer: [1040]u8 = undefined;
        for (&buffer, 0..) |*byte, index| byte.* = @truncate(index * 131 + (index >> 7));
        break :block buffer;
    };
    inline for ([_]u32{ 0, 0x1234_5678, 0x8000_0000, 0xffff_ffff }) |start| {
        inline for ([_]usize{ 64, 80, 96, 112, 128, 144, 256, 512, 1040 }) |length| {
            const raw = comptime block: {
                @setEvalBranchQuota(2_000_000);
                break :block update(~start, &bytes, length);
            };
            var reference = std.hash.Crc32.init();
            reference.crc = ~start;
            reference.update(bytes[0..length]);
            try std.testing.expectEqual(reference.final(), ~raw);
        }
    }
}
