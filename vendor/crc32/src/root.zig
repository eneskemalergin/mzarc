//! CRC-32/ISO-HDLC with a portable table and optional x86-64 and AArch64 kernels.
//!
//! Public checksum words are finalized. A fresh checksum starts at zero; every
//! u32 is a valid continuation word. The library allocates no memory and performs
//! no file I/O. Callers supply the bytes and retain ownership of their slices.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const Backend = enum {
    portable,
    x86_pclmul,
    x86_vpclmul,
    arm_crc,
    arm_pmull,
};

pub fn hash(bytes: []const u8) u32 {
    return update(0, bytes);
}

/// Continues a finalized CRC over exactly `bytes`; empty input preserves any start.
pub fn update(start: u32, bytes: []const u8) u32 {
    if (comptime builtin.cpu.arch == .x86_64 and build_options.accelerated) {
        if (bytes.len < 16) return ~@call(.always_inline, updateTableRaw, .{ ~start, bytes });
        const function = cached_x86_update.load(.monotonic);
        return ~function(~start, bytes.ptr, bytes.len);
    }
    return ~updateRawWithBackend(~start, bytes, backendFor(bytes.len));
}

/// Joins A and B without reading their bytes. `checksum_b` must be `hash(B)` and
/// `length_b` is B's byte length. A may itself continue from any finalized word.
/// Empty B has checksum zero. Work is logarithmic in `length_b`.
pub fn combine(checksum_a: u32, checksum_b: u32, length_b: u64) u32 {
    var contribution = @bitReverse(checksum_a);
    var power: u32 = 0x100;
    var remaining = length_b;
    while (remaining != 0) {
        if (remaining & 1 != 0) contribution = multiplyMod(contribution, power);
        remaining >>= 1;
        if (remaining != 0) power = multiplyMod(power, power);
    }
    return @bitReverse(contribution) ^ checksum_b;
}

/// Reports the path selected for one update of `length` bytes. Specialized paths
/// can still use the table for a short chunk or a final partial block.
pub fn backendFor(length: usize) Backend {
    if (builtin.cpu.arch == .x86_64 and length < 16) return .portable;
    return chooseBackend(cpuFeatures(), length);
}

/// Coalesces short updates in bounded storage and keeps the selected CRC backend.
/// Default initialization starts a fresh CRC; final does not consume the state.
pub const Stream = struct {
    raw: u32 = 0xffff_ffff,
    backend: Backend = .portable,
    selected: bool = false,
    pending: [256]u8 = undefined,
    used: usize = 0,

    pub fn init(start: u32) Stream {
        return .{ .raw = ~start };
    }

    pub fn update(self: *Stream, bytes: []const u8) void {
        if (bytes.len == 0) return;
        if (!self.selected) {
            self.backend = chooseStreamingBackend(cpuFeatures());
            self.selected = true;
        }
        var offset: usize = 0;
        if (self.used != 0) {
            const amount = @min(bytes.len, self.pending.len - self.used);
            copyPending(self.pending[self.used..][0..amount], bytes[0..amount]);
            self.used += amount;
            if (self.used != self.pending.len) return;
            self.raw = updateBufferedRaw(self.raw, &self.pending, self.backend);
            self.used = 0;
            offset = amount;
        }
        const remaining = bytes[offset..];
        if (remaining.len >= 64) {
            self.raw = updateBufferedRaw(self.raw, remaining, self.backend);
        } else if (remaining.len != 0) {
            copyPending(self.pending[0..remaining.len], remaining);
            self.used = remaining.len;
        }
    }

    pub fn final(self: *const Stream) u32 {
        if (self.used == 0) return ~self.raw;
        return ~updateRawWithBackend(self.raw, self.pending[0..self.used], self.backend);
    }
};

inline fn updateBufferedRaw(start: u32, bytes: []const u8, backend: Backend) u32 {
    if (comptime builtin.cpu.arch == .x86_64 and build_options.accelerated) {
        const function = cached_x86_update.load(.monotonic);
        return function(start, bytes.ptr, bytes.len);
    }
    return updateRawWithBackend(start, bytes, backend);
}

inline fn copyPending(destination: []u8, source: []const u8) void {
    if (source.len == 1) {
        destination[0] = source[0];
    } else if (source.len < 16) {
        inline for (.{ 8, 4, 2 }) |width| {
            if (source.len >= width) {
                const last = source.len - width;
                @memcpy(destination[0..width], source[0..width]);
                @memcpy(destination[last..][0..width], source[last..][0..width]);
                return;
            }
        }
    } else {
        @memcpy(destination, source);
    }
}

const NORMAL_POLYNOMIAL: u32 = 0x04c1_1db7;
const REFLECTED_POLYNOMIAL: u32 = 0xedb8_8320;
const TABLE_SLICES = 16;
const TABLES = buildTables();

extern fn crc32_x86_pclmul_update_raw(start: u32, bytes: [*]const u8, len: usize) callconv(.c) u32;
extern fn crc32_x86_vpclmul_update_raw(start: u32, bytes: [*]const u8, len: usize) callconv(.c) u32;
extern fn crc32_arm_crc_update_raw(start: u32, bytes: [*]const u8, len: usize) callconv(.c) u32;
extern fn crc32_arm_pmull_update_raw(start: u32, bytes: [*]const u8, len: usize) callconv(.c) u32;

const X86Update = *const fn (u32, [*]const u8, usize) callconv(.c) u32;
var cached_x86_update: std.atomic.Value(X86Update) = .init(dispatchX86Entry);

fn dispatchX86Entry(start: u32, bytes: [*]const u8, len: usize) callconv(.c) u32 {
    const features = cpuFeatures();
    const function: X86Update = if (features.x86_vpclmul) crc32_x86_vpclmul_update_raw else if (features.x86_pclmul) crc32_x86_pclmul_update_raw else tableEntry;
    cached_x86_update.store(function, .monotonic);
    return function(start, bytes, len);
}

fn tableEntry(start: u32, bytes: [*]const u8, len: usize) callconv(.c) u32 {
    return updateTableRaw(start, bytes[0..len]);
}

var cached_features: std.atomic.Value(u8) = .init(0);

// Bit reversal converts the reflected register to normal polynomial coefficients.
// Multiplying by x^8 then advances one zero byte without complementing the register.
fn multiplyMod(a_input: u32, b_input: u32) u32 {
    var a = a_input;
    var b = b_input;
    var result: u32 = 0;
    while (b != 0) : (b >>= 1) {
        if (b & 1 != 0) result ^= a;
        const carry = a >> 31;
        a = (a << 1) ^ (NORMAL_POLYNOMIAL & (0 -% carry));
    }
    return result;
}

fn cpuFeatures() FeatureBits {
    if (!build_options.accelerated) return .{};
    const cached = cached_features.load(.monotonic);
    if (cached != 0) return FeatureBits.decode(cached - 1);
    const detected = detectFeatures();
    cached_features.store(detected.encode() + 1, .monotonic);
    return detected;
}

const FeatureBits = struct {
    x86_pclmul: bool = false,
    x86_vpclmul: bool = false,
    arm_crc: bool = false,
    arm_pmull: bool = false,

    fn encode(self: FeatureBits) u8 {
        return @as(u8, @intFromBool(self.x86_pclmul)) |
            (@as(u8, @intFromBool(self.x86_vpclmul)) << 1) |
            (@as(u8, @intFromBool(self.arm_crc)) << 2) |
            (@as(u8, @intFromBool(self.arm_pmull)) << 3);
    }

    fn decode(value: u8) FeatureBits {
        return .{
            .x86_pclmul = value & 1 != 0,
            .x86_vpclmul = value & 2 != 0,
            .arm_crc = value & 4 != 0,
            .arm_pmull = value & 8 != 0,
        };
    }
};

fn chooseBackend(features_value: FeatureBits, length: usize) Backend {
    if (comptime builtin.cpu.arch == .x86_64) {
        if (features_value.x86_vpclmul and length >= 16) return .x86_vpclmul;
        if (features_value.x86_pclmul and length >= 16) return .x86_pclmul;
    }
    if (comptime builtin.cpu.arch == .aarch64) {
        if (features_value.arm_pmull and length >= 64) return .arm_pmull;
        if (features_value.arm_crc) return .arm_crc;
    }
    return .portable;
}

fn chooseStreamingBackend(features_value: FeatureBits) Backend {
    if (comptime builtin.cpu.arch == .x86_64) {
        if (features_value.x86_vpclmul) return .x86_vpclmul;
        if (features_value.x86_pclmul) return .x86_pclmul;
    }
    if (comptime builtin.cpu.arch == .aarch64) {
        if (features_value.arm_pmull) return .arm_pmull;
        if (features_value.arm_crc) return .arm_crc;
    }
    return .portable;
}

fn updateRawWithBackend(start: u32, bytes: []const u8, backend: Backend) u32 {
    if (!build_options.accelerated) return updateTableRaw(start, bytes);
    switch (backend) {
        .portable => return updateTableRaw(start, bytes),
        .arm_crc => {
            if (comptime builtin.cpu.arch != .aarch64) return updateTableRaw(start, bytes);
            return crc32_arm_crc_update_raw(start, bytes.ptr, bytes.len);
        },
        .x86_pclmul => {
            if (comptime builtin.cpu.arch != .x86_64) return updateTableRaw(start, bytes);
            return updateX86Raw(start, bytes, crc32_x86_pclmul_update_raw);
        },
        .x86_vpclmul => {
            if (comptime builtin.cpu.arch != .x86_64) return updateTableRaw(start, bytes);
            return updateX86Raw(start, bytes, crc32_x86_vpclmul_update_raw);
        },
        .arm_pmull => {
            if (comptime builtin.cpu.arch != .aarch64) return updateTableRaw(start, bytes);
            if (bytes.len < 64) return updateTableRaw(start, bytes);
            const bulk = bytes.len & ~@as(usize, 15);
            if (bulk < 64) return updateTableRaw(start, bytes);
            const raw = crc32_arm_pmull_update_raw(start, bytes.ptr, bulk);
            return updateTableRaw(raw, bytes[bulk..]);
        },
    }
}

fn updateX86Raw(
    start: u32,
    bytes: []const u8,
    function: *const fn (u32, [*]const u8, usize) callconv(.c) u32,
) u32 {
    if (bytes.len < 16) return updateTableRaw(start, bytes);
    return function(start, bytes.ptr, bytes.len);
}

fn detectFeatures() FeatureBits {
    if (comptime builtin.cpu.arch == .x86_64) return detectX86Features();
    if (comptime builtin.cpu.arch == .aarch64) return detectArmFeatures();
    return .{};
}

const CpuidLeaf = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

fn cpuid(leaf_id: u32, subid: u32) CpuidLeaf {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf_id),
          [_] "{ecx}" (subid),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn xgetbv0() u32 {
    return asm volatile (
        \\xorl %%ecx, %%ecx
        \\xgetbv
        : [_] "={eax}" (-> u32),
        :
        : .{ .ecx = true, .edx = true });
}

fn avxStateEnabled(has_osxsave: bool, has_avx: bool, xcr0: u32) bool {
    return has_osxsave and has_avx and xcr0 & 0x6 == 0x6;
}

fn detectX86Features() FeatureBits {
    const maximum = cpuid(0, 0).eax;
    if (maximum < 1) return .{};
    const leaf1 = cpuid(1, 0);
    const pclmul = leaf1.ecx & (1 << 1) != 0 and leaf1.ecx & (1 << 9) != 0;
    const has_osxsave = leaf1.ecx & (1 << 27) != 0;
    const has_avx = leaf1.ecx & (1 << 28) != 0;
    const xcr0 = if (has_osxsave and has_avx) xgetbv0() else 0;
    const avx_state = avxStateEnabled(has_osxsave, has_avx, xcr0);

    const vpclmul = pclmul and avx_state;

    return .{
        .x86_pclmul = pclmul,
        .x86_vpclmul = vpclmul,
    };
}

fn detectArmFeatures() FeatureBits {
    const compile_crc = std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc);
    const compile_pmull = std.Target.aarch64.featureSetHas(builtin.cpu.features, .crypto);
    if (compile_crc and compile_pmull) {
        return .{
            .arm_crc = compile_crc,
            .arm_pmull = compile_pmull,
        };
    }

    const detected: FeatureBits = switch (builtin.os.tag) {
        .linux => detectArmLinuxFeatures(),
        .windows => .{
            .arm_crc = std.os.windows.IsProcessorFeaturePresent(.ARM_V8_CRC32_INSTRUCTIONS_AVAILABLE),
            .arm_pmull = std.os.windows.IsProcessorFeaturePresent(.ARM_V8_CRYPTO_INSTRUCTIONS_AVAILABLE),
        },
        .macos => .{
            .arm_crc = darwinFeature("hw.optional.arm.FEAT_CRC32", "hw.optional.armv8_crc32"),
            .arm_pmull = darwinFeature("hw.optional.arm.FEAT_PMULL", "hw.optional.armv8_pmull"),
        },
        else => .{},
    };
    return mergeArmFeatures(compile_crc, compile_pmull, detected);
}

fn mergeArmFeatures(compile_crc: bool, compile_pmull: bool, detected: FeatureBits) FeatureBits {
    return .{
        .arm_crc = compile_crc or detected.arm_crc,
        .arm_pmull = compile_pmull or detected.arm_pmull,
    };
}

fn detectArmLinuxFeatures() FeatureBits {
    // Linux AArch64 HWCAP values: PMULL is bit 4 and CRC32 is bit 7.
    const hwcap = std.os.linux.getauxval(std.elf.AT_HWCAP);
    return .{
        .arm_pmull = hwcap & (@as(usize, 1) << 4) != 0,
        .arm_crc = hwcap & (@as(usize, 1) << 7) != 0,
    };
}

fn darwinFeature(primary: [*:0]const u8, fallback: [*:0]const u8) bool {
    var value: c_int = 0;
    var length: usize = @sizeOf(c_int);
    if (std.c.sysctlbyname(primary, &value, &length, null, 0) == 0) return value != 0;
    value = 0;
    length = @sizeOf(c_int);
    if (std.c.sysctlbyname(fallback, &value, &length, null, 0) == 0) return value != 0;
    return false;
}

fn buildTables() [TABLE_SLICES][256]u32 {
    @setEvalBranchQuota(100_000);

    var tables: [TABLE_SLICES][256]u32 = undefined;
    for (0..256) |index| {
        var value: u32 = @intCast(index);
        for (0..8) |_| {
            value = (value >> 1) ^ (REFLECTED_POLYNOMIAL & (0 -% (value & 1)));
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

fn updateTableRaw(start: u32, bytes: []const u8) u32 {
    var crc = start;
    // Tiny calls and empty folding remainders need no wide-table setup.
    if (bytes.len < 4) {
        for (bytes) |byte| {
            crc = TABLES[0][@as(u8, @truncate(crc ^ byte))] ^ (crc >> 8);
        }
        return crc;
    }
    var offset: usize = 0;
    while (bytes.len - offset >= TABLE_SLICES) : (offset += TABLE_SLICES) {
        const low_word = std.mem.readInt(u64, bytes[offset..][0..8], .little);
        const high_word = std.mem.readInt(u64, bytes[offset + 8 ..][0..8], .little);
        const low: u32 = @truncate(low_word);
        const high: u32 = @truncate(low_word >> 32);
        const upper_low: u32 = @truncate(high_word);
        const upper_high: u32 = @truncate(high_word >> 32);
        const mixed = low ^ crc;
        crc = TABLES[15][@as(u8, @truncate(mixed))] ^
            TABLES[14][@as(u8, @truncate(mixed >> 8))] ^
            TABLES[13][@as(u8, @truncate(mixed >> 16))] ^
            TABLES[12][@as(u8, @truncate(mixed >> 24))] ^
            TABLES[11][@as(u8, @truncate(high))] ^
            TABLES[10][@as(u8, @truncate(high >> 8))] ^
            TABLES[9][@as(u8, @truncate(high >> 16))] ^
            TABLES[8][@as(u8, @truncate(high >> 24))] ^
            TABLES[7][@as(u8, @truncate(upper_low))] ^
            TABLES[6][@as(u8, @truncate(upper_low >> 8))] ^
            TABLES[5][@as(u8, @truncate(upper_low >> 16))] ^
            TABLES[4][@as(u8, @truncate(upper_low >> 24))] ^
            TABLES[3][@as(u8, @truncate(upper_high))] ^
            TABLES[2][@as(u8, @truncate(upper_high >> 8))] ^
            TABLES[1][@as(u8, @truncate(upper_high >> 16))] ^
            TABLES[0][@as(u8, @truncate(upper_high >> 24))];
    }
    if (offset == bytes.len) return crc;
    // Reuse the existing slices for partial blocks before the last few bytes.
    inline for (.{ 8, 4 }) |width| {
        if (bytes.len - offset >= width) {
            const word = std.mem.readInt(@Int(.unsigned, width * 8), bytes[offset..][0..width], .little);
            const mixed = word ^ crc;
            crc = 0;
            inline for (0..width) |byte| {
                crc ^= TABLES[width - 1 - byte][@as(u8, @truncate(mixed >> (byte * 8)))];
            }
            offset += width;
        }
    }
    while (offset < bytes.len) : (offset += 1) {
        crc = TABLES[0][@as(u8, @truncate(crc ^ bytes[offset]))] ^ (crc >> 8);
    }
    return crc;
}

fn referenceUpdate(start: u32, bytes: []const u8) u32 {
    var crc = ~start;
    for (bytes) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            crc = if (crc & 1 != 0) (crc >> 1) ^ REFLECTED_POLYNOMIAL else crc >> 1;
        }
    }
    return ~crc;
}

fn checkBackend(backend: Backend) !void {
    var bytes: [4096 + 31]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x1357);
    random.fill(&bytes);
    for ([_]u32{ 0, 0x1234_5678, 0xffff_ffff, 0x8000_0000 }) |start| {
        for (0..32) |offset| {
            const input = bytes[offset..];
            var expected = start;
            for (0..input.len + 1) |length| {
                if (length != 0) expected = referenceUpdate(expected, input[length - 1 .. length]);
                try std.testing.expectEqual(expected, ~updateRawWithBackend(~start, input[0..length], backend));
            }
        }
    }
}

test "[property] - [portable CRC]: every length and offset agrees with the bit recurrence" {
    try checkBackend(.portable);
}

test "[property] - [PCLMUL CRC]: every length and offset agrees with the bit recurrence" {
    if (!cpuFeatures().x86_pclmul) return error.SkipZigTest;
    try checkBackend(.x86_pclmul);
}

test "[property] - [VPCLMUL CRC]: every length and offset agrees with the bit recurrence" {
    if (!cpuFeatures().x86_vpclmul) return error.SkipZigTest;
    try checkBackend(.x86_vpclmul);
}

test "[property] - [Arm CRC]: every length and offset agrees with the bit recurrence" {
    if (!cpuFeatures().arm_crc) return error.SkipZigTest;
    try checkBackend(.arm_crc);
}

test "[property] - [PMULL CRC]: every length and offset agrees with the bit recurrence" {
    if (!cpuFeatures().arm_pmull) return error.SkipZigTest;
    try checkBackend(.arm_pmull);
}

test "[edge] - [CRC reads]: legal backends stay between protected pages" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Inaccessible neighbors expose reads that padded test arrays cannot catch.
    const linux = std.os.linux;
    const page_size = std.heap.pageSize();
    const allocation = linux.mmap(null, page_size * 3, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (linux.errno(allocation) != .SUCCESS) return error.GuardPageAllocationFailed;
    const mapping: [*]u8 = @ptrFromInt(allocation);
    defer if (linux.errno(linux.munmap(mapping, page_size * 3)) != .SUCCESS) @panic("guard page cleanup failed");
    if (linux.errno(linux.mprotect(mapping, page_size, .{})) != .SUCCESS or
        linux.errno(linux.mprotect(mapping + page_size * 2, page_size, .{})) != .SUCCESS)
        return error.GuardPageProtectionFailed;
    const bytes = mapping[page_size .. page_size * 2];
    for (bytes, 0..) |*byte, index| byte.* = @truncate(index * 131 + (index >> 7));
    const features = cpuFeatures();
    const cases = .{
        .{ Backend.portable, true },
        .{ Backend.x86_pclmul, features.x86_pclmul },
        .{ Backend.x86_vpclmul, features.x86_vpclmul },
        .{ Backend.arm_crc, features.arm_crc },
        .{ Backend.arm_pmull, features.arm_pmull },
    };
    inline for (cases) |case| {
        if (case[1]) {
            for ([_]u32{ 0, 0xffff_ffff, 0x1234_5678 }) |start| {
                for (0..258) |length| {
                    for ([_][]const u8{ bytes[0..length], bytes[bytes.len - length ..] }) |input| {
                        try std.testing.expectEqual(referenceUpdate(start, input), ~updateRawWithBackend(~start, input, case[0]));
                        if (case[0] == chooseStreamingBackend(features)) {
                            var stream = Stream.init(start);
                            const split = @min(1, input.len);
                            stream.update(input[0..split]);
                            stream.update(input[split..]);
                            try std.testing.expectEqual(referenceUpdate(start, input), stream.final());
                        }
                    }
                }
                for ([_]usize{ page_size - 17, page_size - 16, page_size - 1, page_size }) |length| {
                    const input = bytes[bytes.len - length ..];
                    try std.testing.expectEqual(referenceUpdate(start, input), ~updateRawWithBackend(~start, input, case[0]));
                }
            }
        }
    }
}

test "[unit] - [CPU selection]: features and input lengths choose eligible paths" {
    for ([_]usize{ 0, 1, 15, 16, 17, 31, 32, 63, 64, 65, 128, 4096 }) |length| {
        try std.testing.expectEqual(.portable, chooseBackend(.{}, length));
        if (builtin.cpu.arch == .x86_64) {
            const legacy = FeatureBits{ .x86_pclmul = true };
            const both = FeatureBits{ .x86_pclmul = true, .x86_vpclmul = true };
            try std.testing.expectEqual(if (length < 16) Backend.portable else .x86_pclmul, chooseBackend(legacy, length));
            try std.testing.expectEqual(if (length < 16) Backend.portable else .x86_vpclmul, chooseBackend(both, length));
            try std.testing.expectEqual(.x86_vpclmul, chooseStreamingBackend(both));
        } else if (builtin.cpu.arch == .aarch64) {
            const crc = FeatureBits{ .arm_crc = true };
            const both = FeatureBits{ .arm_crc = true, .arm_pmull = true };
            try std.testing.expectEqual(.arm_crc, chooseBackend(crc, length));
            try std.testing.expectEqual(if (length < 64) Backend.arm_crc else .arm_pmull, chooseBackend(both, length));
            try std.testing.expectEqual(.arm_pmull, chooseStreamingBackend(both));
        }
    }
    if (!build_options.accelerated) {
        try std.testing.expectEqual(@as(u8, 0), cpuFeatures().encode());
        try std.testing.expectEqual(.portable, backendFor(std.math.maxInt(usize)));
    }
    for (0..16) |value| {
        try std.testing.expectEqual(@as(u8, @intCast(value)), FeatureBits.decode(@intCast(value)).encode());
    }
}

test "[edge] - [stream selection]: empty and one-byte first chunks preserve selection rules" {
    var bytes: [65]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index * 131);
    var stream: Stream = .{};
    stream.update("");
    try std.testing.expect(!stream.selected);
    stream.update(bytes[0..1]);
    try std.testing.expect(stream.selected);
    try std.testing.expectEqual(chooseStreamingBackend(cpuFeatures()), stream.backend);
    stream.update(bytes[1..]);
    try std.testing.expectEqual(referenceUpdate(0, &bytes), stream.final());
}

test "[unit] - [AVX state]: OSXSAVE and both XMM and YMM state are required" {
    for ([_]bool{ false, true }) |osxsave| {
        for ([_]bool{ false, true }) |avx| {
            for (0..8) |xcr0| {
                const expected = osxsave and avx and xcr0 & 6 == 6;
                try std.testing.expectEqual(expected, avxStateEnabled(osxsave, avx, @intCast(xcr0)));
            }
        }
    }
}

test "[regression] - [Arm selection]: one compile-time feature preserves the other runtime feature" {
    const from_crc = mergeArmFeatures(true, false, .{ .arm_pmull = true });
    try std.testing.expect(from_crc.arm_crc and from_crc.arm_pmull);
    const from_pmull = mergeArmFeatures(false, true, .{ .arm_crc = true });
    try std.testing.expect(from_pmull.arm_crc and from_pmull.arm_pmull);
    try std.testing.expectEqual(@as(u8, 0), mergeArmFeatures(false, false, .{}).encode());
}
