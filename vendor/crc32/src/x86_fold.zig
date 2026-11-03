//! 128-bit CRC folding shared by the legacy and VEX x86 objects.

const std = @import("std");

const NORMAL_POLYNOMIAL: u64 = 0x1_04c1_1db7;
const WIDE_LANES: usize = 8;
const MID_LANES: usize = 4;
const SHORT_LANES: usize = 2;

const Block = @Vector(2, u64);
const STEP_128 = stepKey(1);
const REDUCTION_KEYS: Block = .{
    @bitReverse(polynomialQuotient(95)),
    reflectPolynomial(NORMAL_POLYNOMIAL),
};

/// Continues an uncomplemented register over little-endian blocks. The folding
/// loop asserts a length of at least 16 bytes. The caller
/// assumes the selected PCLMUL instruction form is legal on the executing CPU.
pub fn updateRaw(comptime use_vpclmul: bool, start: u32, bytes: []const u8) u32 {
    if (bytes.len >= WIDE_LANES * 16) {
        if (bytes.len >= 1024) return @call(.never_inline, updateChorba, .{ use_vpclmul, start, bytes });
        return updatePclmul(use_vpclmul, WIDE_LANES, start, bytes);
    }
    if (bytes.len >= MID_LANES * 16) return updatePclmul(use_vpclmul, MID_LANES, start, bytes);
    if (bytes.len >= 32) return updatePclmul(use_vpclmul, SHORT_LANES, start, bytes);
    return updatePclmul(use_vpclmul, 1, start, bytes);
}

fn readBlock(bytes: []const u8, offset: *usize) Block {
    const block: Block = @bitCast(bytes[offset.*..][0..16].*);
    offset.* += 16;
    return block;
}

const MultiplyPart = enum {
    low_low,
    high_high,
    low_high,
    high_low,
};

inline fn carrylessMultiply(
    value: Block,
    key: Block,
    comptime part: MultiplyPart,
    comptime use_vpclmul: bool,
) Block {
    const immediate: u8 = switch (part) {
        .low_low => 0x00,
        .high_high => 0x11,
        .low_high => 0x10,
        .high_low => 0x01,
    };
    if (comptime use_vpclmul) {
        return switch (immediate) {
            0x00 => asm ("vpclmulqdq $0x00, %[key], %[value], %[out]"
                : [out] "=x" (-> Block),
                : [value] "x" (value),
                  [key] "x" (key),
            ),
            0x01 => asm ("vpclmulqdq $0x01, %[key], %[value], %[out]"
                : [out] "=x" (-> Block),
                : [value] "x" (value),
                  [key] "x" (key),
            ),
            0x10 => asm ("vpclmulqdq $0x10, %[key], %[value], %[out]"
                : [out] "=x" (-> Block),
                : [value] "x" (value),
                  [key] "x" (key),
            ),
            0x11 => asm ("vpclmulqdq $0x11, %[key], %[value], %[out]"
                : [out] "=x" (-> Block),
                : [value] "x" (value),
                  [key] "x" (key),
            ),
            else => unreachable,
        };
    }
    return switch (immediate) {
        0x00 => asm ("pclmulqdq $0x00, %[key], %[value]"
            : [value] "=x" (-> Block),
            : [input] "0" (value),
              [key] "x" (key),
        ),
        0x01 => asm ("pclmulqdq $0x01, %[key], %[value]"
            : [value] "=x" (-> Block),
            : [input] "0" (value),
              [key] "x" (key),
        ),
        0x10 => asm ("pclmulqdq $0x10, %[key], %[value]"
            : [value] "=x" (-> Block),
            : [input] "0" (value),
              [key] "x" (key),
        ),
        0x11 => asm ("pclmulqdq $0x11, %[key], %[value]"
            : [value] "=x" (-> Block),
            : [input] "0" (value),
              [key] "x" (key),
        ),
        else => unreachable,
    };
}

inline fn xorProducts(comptime use_vpclmul: bool, value: Block, key: Block) Block {
    return carrylessMultiply(value, key, .low_low, use_vpclmul) ^
        carrylessMultiply(value, key, .high_high, use_vpclmul);
}

inline fn foldBlock(comptime use_vpclmul: bool, value: Block, next: Block, key: Block) Block {
    return next ^ xorProducts(use_vpclmul, value, key);
}

inline fn combineLane(comptime use_vpclmul: bool, value: Block, key: Block) Block {
    return carrylessMultiply(value, key, .low_high, use_vpclmul) ^
        carrylessMultiply(value, key, .high_low, use_vpclmul);
}

inline fn discardLowBytes(value: Block, comptime count: u5) Block {
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

fn finishReduction(comptime use_vpclmul: bool, value: Block) u32 {
    const folded = carrylessMultiply(value, STEP_128, .low_high, use_vpclmul) ^ discardLowBytes(value, 8);
    const quotient = carrylessMultiply(folded, REDUCTION_KEYS, .low_low, use_vpclmul);
    const product = carrylessMultiply(quotient, REDUCTION_KEYS, .low_high, use_vpclmul);
    const words: @Vector(4, u32) = @bitCast(folded ^ product);
    return words[2];
}

fn updatePclmul(comptime use_vpclmul: bool, comptime lane_count: usize, start: u32, bytes: []const u8) u32 {
    std.debug.assert(bytes.len >= lane_count * 16);

    var offset: usize = 0;
    var states: [lane_count]Block = undefined;
    const group_key: Block = comptime stepKey(lane_count);
    inline for (0..lane_count) |lane| {
        states[lane] = readBlock(bytes, &offset);
    }
    states[0] ^= Block{ @as(u64, start), 0 };

    while (bytes.len - offset >= lane_count * 16) {
        inline for (0..lane_count) |lane| {
            states[lane] = foldBlock(use_vpclmul, states[lane], readBlock(bytes, &offset), group_key);
        }
    }

    var value = states[lane_count - 1];
    inline for (0..lane_count - 1) |lane| {
        value ^= combineLane(use_vpclmul, states[lane], comptime crossLaneKey(lane_count - 1 - lane));
    }

    while (bytes.len - offset >= 16) {
        value = foldBlock(use_vpclmul, value, readBlock(bytes, &offset), STEP_128);
    }
    if (offset != bytes.len) value = foldTail(use_vpclmul, value, bytes[bytes.len - 16 ..][0..16].*, bytes.len - offset);
    return finishReduction(use_vpclmul, value);
}

// G(x)^128 is divisible by G(x). Its coefficient distances give whole-vector
// XORs that remove eight input blocks while preserving the polynomial remainder.
// This follows Russell's Chorba identity; offsets are derived from our polynomial.
fn chorbaTap(comptime distance: usize) bool {
    if (distance > 32) return false;
    return NORMAL_POLYNOMIAL & (@as(u64, 1) << @intCast(32 - distance)) != 0;
}

fn updateChorba(comptime vex: bool, start: u32, bytes: []const u8) u32 {
    @setEvalBranchQuota(100_000);
    var offset: usize = 0;
    var states: [4]Block = undefined;
    inline for (0..4) |lane| states[lane] = readBlock(bytes, &offset);
    states[0] ^= Block{ @as(u64, start), 0 };

    while (bytes.len - offset >= 640) {
        var removed: [8]Block = undefined;
        inline for (0..8) |i| {
            removed[i] = readBlock(bytes, &offset);
            inline for (0..i) |previous| {
                if (comptime chorbaTap(i - previous)) removed[i] ^= removed[previous];
            }
        }
        inline for (0..8) |group| {
            const key = comptime stepKey(if (group == 0) 12 else 4);
            inline for (0..4) |lane| {
                var next = readBlock(bytes, &offset);
                inline for (0..8) |i| {
                    if (comptime chorbaTap(8 + group * 4 + lane - i)) next ^= removed[i];
                }
                states[lane] = foldBlock(vex, states[lane], next, key);
            }
        }
    }
    while (bytes.len - offset >= 64) {
        inline for (0..4) |lane| {
            states[lane] = foldBlock(vex, states[lane], readBlock(bytes, &offset), comptime stepKey(4));
        }
    }
    var value = states[3];
    inline for (0..3) |lane| value ^= combineLane(vex, states[lane], comptime crossLaneKey(3 - lane));
    while (bytes.len - offset >= 16) value = foldBlock(vex, value, readBlock(bytes, &offset), STEP_128);
    if (offset != bytes.len) value = foldTail(vex, value, bytes[bytes.len - 16 ..][0..16].*, bytes.len - offset);
    return finishReduction(vex, value);
}

const SHIFTS = [_]u8{0x80} ** 16 ++ [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } ++ [_]u8{0x80} ** 16;

inline fn shuffleBytes(comptime vex: bool, value: Block, mask: @Vector(16, u8)) Block {
    if (comptime vex) {
        return asm ("vpshufb %[mask], %[value], %[out]"
            : [out] "=x" (-> Block),
            : [value] "x" (value),
              [mask] "x" (mask),
        );
    }
    return asm ("pshufb %[mask], %[value]"
        : [value] "=x" (-> Block),
        : [input] "0" (value),
          [mask] "x" (mask),
    );
}

fn foldTail(comptime vex: bool, value: Block, last: [16]u8, count: usize) Block {
    const left_mask: @Vector(16, u8) = SHIFTS[count..][0..16].*;
    const right_mask: @Vector(16, u8) = SHIFTS[count + 16 ..][0..16].*;
    const prefix = shuffleBytes(vex, value, left_mask);
    const suffix: @Vector(16, u8) = @bitCast(shuffleBytes(vex, value, right_mask));
    const joined = @select(u8, right_mask > @as(@Vector(16, u8), @splat(127)), @as(@Vector(16, u8), last), suffix);
    return foldBlock(vex, prefix, @bitCast(joined), STEP_128);
}

fn gf2MultiplyMod(a_input: u64, b_input: u64) u64 {
    var a = a_input;
    var b = b_input;
    var result: u64 = 0;
    while (b != 0) : (b >>= 1) {
        if ((b & 1) != 0) result ^= a;
        a <<= 1;
        if ((a & (@as(u64, 1) << 32)) != 0) a ^= NORMAL_POLYNOMIAL;
    }
    return result;
}

fn xPower(comptime exponent: usize) u64 {
    @setEvalBranchQuota(100_000);
    var result: u64 = 1;
    var factor: u64 = 2;
    var remaining = exponent;
    while (remaining != 0) : (remaining >>= 1) {
        if ((remaining & 1) != 0) result = gf2MultiplyMod(result, factor);
        factor = gf2MultiplyMod(factor, factor);
    }
    return result;
}

fn reflectPolynomial(value: u64) u64 {
    var result: u64 = 0;
    for (0..33) |bit| result = (result << 1) | ((value >> @intCast(bit)) & 1);
    return result;
}

fn polynomialQuotient(comptime exponent: usize) u64 {
    var remainder: u128 = @as(u128, 1) << @intCast(exponent);
    var quotient: u64 = 0;
    var bit = exponent - 32;
    while (true) : (bit -= 1) {
        const pivot = @as(u128, 1) << @intCast(bit + 32);
        if (remainder & pivot != 0) {
            quotient |= @as(u64, 1) << @intCast(bit);
            remainder ^= @as(u128, NORMAL_POLYNOMIAL) << @intCast(bit);
        }
        if (bit == 0) break;
    }
    return quotient;
}

fn reflectedPower(comptime exponent: usize) u64 {
    return @bitReverse(@as(u32, @intCast(xPower(exponent))));
}

fn stepKey(comptime blocks: usize) Block {
    return .{
        reflectedPower(blocks * 128 + 31),
        reflectedPower(blocks * 128 - 33),
    };
}

fn crossLaneKey(comptime distance: usize) Block {
    return .{
        reflectedPower(distance * 128 - 33),
        reflectedPower(distance * 128 + 31),
    };
}
