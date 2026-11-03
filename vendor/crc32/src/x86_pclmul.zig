//! Internal PCLMUL entry point for the reflected raw CRC register.
//!
//! The caller assumes `bytes` addresses `len` readable bytes on an eligible CPU.
//! The folding code asserts `len >= 16`. Loads are unaligned
//! little-endian blocks; the kernel handles partial blocks without reading outside the slice.
//! PCLMUL and SSSE3 are required. The VEX entry also needs AVX with OS-enabled XMM/YMM state.
//! Hidden visibility keeps this linker entry point out of the public library API.

const fold = @import("x86_fold.zig");

comptime {
    @export(&update, .{ .name = "crc32_x86_pclmul_update_raw", .visibility = .hidden });
}

fn update(start: u32, bytes: [*]const u8, len: usize) callconv(.c) u32 {
    return fold.updateRaw(false, start, bytes[0..len]);
}
