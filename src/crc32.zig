//! CRC-32/ISO-HDLC with portable and runtime-selected x86-64 paths.

const std = @import("std");
const builtin = @import("builtin");

const POLYNOMIAL: u32 = 0xedb8_8320;
const FOLD_MIN_BYTES = 128;
const SLICES = 8;
const TABLES = buildTables();

/// Return CRC-32/ISO-HDLC for `bytes`.
pub fn hash(bytes: []const u8) u32 {
    if (bytes.len >= FOLD_MIN_BYTES) {
        if (comptime builtin.cpu.arch == .x86_64) {
            if (X86Crc32.isSupported()) return X86Crc32.hash(bytes);
        }
    }
    return hashPortableFrom(0, bytes);
}

fn hashPortableFrom(start: u32, bytes: []const u8) u32 {
    var crc = ~start;
    var offset: usize = 0;
    while (bytes.len - offset >= SLICES) : (offset += SLICES) {
        const word = std.mem.readInt(u64, bytes[offset..][0..SLICES], .little);
        const low: u32 = @truncate(word);
        const high: u32 = @truncate(word >> 32);
        const mixed = low ^ crc;
        crc = TABLES[7][@as(u8, @truncate(mixed))] ^
            TABLES[6][@as(u8, @truncate(mixed >> 8))] ^
            TABLES[5][@as(u8, @truncate(mixed >> 16))] ^
            TABLES[4][@as(u8, @truncate(mixed >> 24))] ^
            TABLES[3][@as(u8, @truncate(high))] ^
            TABLES[2][@as(u8, @truncate(high >> 8))] ^
            TABLES[1][@as(u8, @truncate(high >> 16))] ^
            TABLES[0][@as(u8, @truncate(high >> 24))];
    }
    while (offset < bytes.len) : (offset += 1) {
        crc = TABLES[0][@as(u8, @truncate(crc ^ bytes[offset]))] ^ (crc >> 8);
    }
    return ~crc;
}

fn buildTables() [SLICES][256]u32 {
    @setEvalBranchQuota(100_000);

    var tables: [SLICES][256]u32 = undefined;
    for (0..256) |index| {
        var value: u32 = @intCast(index);
        for (0..8) |_| {
            value = (value >> 1) ^ (POLYNOMIAL & (0 -% (value & 1)));
        }
        tables[0][index] = value;
    }
    for (1..tables.len) |slice| {
        for (0..256) |index| {
            const previous = tables[slice - 1][index];
            tables[slice][index] = tables[0][@as(u8, @truncate(previous))] ^ (previous >> 8);
        }
    }
    return tables;
}

// The folding schedule and constants are adapted from crc32fast 1.5.0 under MIT.
// See LICENSES/crc32fast-MIT.txt.
const X86Crc32 = struct {
    const Block = @Vector(2, u64);
    const Selector = enum {
        low_low,
        high_high,
        low_high,
    };

    fn isSupported() bool {
        const ecx = asm volatile (
            \\movl $1, %%eax
            \\xorl %%ecx, %%ecx
            \\cpuid
            : [ecx] "={ecx}" (-> u32),
            :
            : .{ .rax = true, .rbx = true, .rdx = true });
        return ecx & (1 << 1) != 0;
    }

    fn hash(bytes: []const u8) u32 {
        std.debug.assert(bytes.len >= FOLD_MIN_BYTES);

        var offset: usize = 0;
        var x3 = readBlock(bytes, &offset);
        var x2 = readBlock(bytes, &offset);
        var x1 = readBlock(bytes, &offset);
        var x0 = readBlock(bytes, &offset);
        x3 ^= Block{ std.math.maxInt(u32), 0 };

        const k1k2 = Block{ 0x1_5444_2bd4, 0x1_c6e4_1596 };
        while (bytes.len - offset >= 64) {
            x3 = reduce128(x3, readBlock(bytes, &offset), k1k2);
            x2 = reduce128(x2, readBlock(bytes, &offset), k1k2);
            x1 = reduce128(x1, readBlock(bytes, &offset), k1k2);
            x0 = reduce128(x0, readBlock(bytes, &offset), k1k2);
        }

        const k3k4 = Block{ 0x1_7519_97d0, 0x0_ccaa_009e };
        var x = reduce128(x3, x2, k3k4);
        x = reduce128(x, x1, k3k4);
        x = reduce128(x, x0, k3k4);
        while (bytes.len - offset >= 16) {
            x = reduce128(x, readBlock(bytes, &offset), k3k4);
        }

        x = clmul(x, k3k4, .low_high) ^ shiftRightBytes(x, 8);
        x = clmul(
            x & Block{ 0xffff_ffff, 0 },
            Block{ 0x1_63cd_6124, 0 },
            .low_low,
        ) ^ shiftRightBytes(x, 4);

        const reduction = Block{ 0x1_db71_0641, 0x1_f701_1641 };
        const t1 = clmul(x & Block{ 0xffff_ffff, 0 }, reduction, .low_high);
        const t2 = clmul(t1 & Block{ 0xffff_ffff, 0 }, reduction, .low_low);
        const words: @Vector(4, u32) = @bitCast(x ^ t2);
        return hashPortableFrom(~words[1], bytes[offset..]);
    }

    fn readBlock(bytes: []const u8, offset: *usize) Block {
        const block: Block = @bitCast(bytes[offset.*..][0..16].*);
        offset.* += 16;
        return block;
    }

    fn reduce128(value: Block, next: Block, keys: Block) Block {
        return next ^ clmul(value, keys, .low_low) ^ clmul(value, keys, .high_high);
    }

    fn clmul(value: Block, key: Block, comptime selector: Selector) Block {
        return switch (selector) {
            .low_low => asm (
                \\pclmulqdq $0x00, %[key], %[value]
                : [value] "=x" (-> Block),
                : [input] "0" (value),
                  [key] "x" (key),
            ),
            .high_high => asm (
                \\pclmulqdq $0x11, %[key], %[value]
                : [value] "=x" (-> Block),
                : [input] "0" (value),
                  [key] "x" (key),
            ),
            .low_high => asm (
                \\pclmulqdq $0x10, %[key], %[value]
                : [value] "=x" (-> Block),
                : [input] "0" (value),
                  [key] "x" (key),
            ),
        };
    }

    fn shiftRightBytes(value: Block, comptime count: u5) Block {
        return switch (count) {
            4 => @bitCast(@shuffle(
                u32,
                @as(@Vector(4, u32), @bitCast(value)),
                @as(@Vector(4, u32), @splat(0)),
                @as(@Vector(4, i32), .{ 1, 2, 3, -1 }),
            )),
            8 => @shuffle(
                u64,
                value,
                @as(Block, @splat(0)),
                @as(@Vector(2, i32), .{ 1, -1 }),
            ),
            else => @compileError("unsupported byte shift"),
        };
    }
};

// --- Tests ---

test "[property] - [CRC32 portable]: matches the standard implementation" {
    var storage: [521]u8 = undefined;
    for (&storage, 0..) |*byte, index| byte.* = @truncate(index *% 73 +% 19);

    for (0..16) |alignment| {
        const input = storage[alignment..];
        try std.testing.expectEqual(std.hash.crc.Crc32.hash(input), hashPortableFrom(0, input));
    }
}

test "[property] - [CRC32 PCLMUL]: matches portable folding boundaries" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    if (!X86Crc32.isSupported()) return error.SkipZigTest;

    var storage: [545]u8 = undefined;
    for (&storage, 0..) |*byte, index| byte.* = @truncate(index *% 73 +% 19);

    for (0..16) |alignment| {
        for (0..storage.len - alignment + 1) |length| {
            const input = storage[alignment..][0..length];
            const expected = hashPortableFrom(0, input);
            const actual = if (input.len >= FOLD_MIN_BYTES)
                X86Crc32.hash(input)
            else
                hash(input);
            try std.testing.expectEqual(expected, actual);
        }
    }
}
