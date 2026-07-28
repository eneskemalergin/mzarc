//! Flat dump V1: little-endian RawSpectrum records.
//! Caller owns spectra from parse/read; free with freeSpectra.

const std = @import("std");
const builtin = @import("builtin");

pub const Allocator = std.mem.Allocator;

pub const RawSpectrum = struct {
    scan_id: u32,
    rt_seconds: f32,
    ms_level: u8,
    precursor_mz: f64,
    mz: []f64,
    intensity: []f32,
};

const record_header_len = 28;
const pad_after_ms_level = [_]u8{ 0, 0, 0 };
const pad_after_peak_count = [_]u8{ 0, 0, 0, 0 };

pub fn freeSpectra(allocator: Allocator, spectra: []RawSpectrum) void {
    for (spectra) |spectrum| {
        allocator.free(spectrum.mz);
        allocator.free(spectrum.intensity);
    }
    allocator.free(spectra);
}

pub fn writeDumpAlloc(allocator: Allocator, spectra: []const RawSpectrum) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    var total_len: usize = 0;
    for (spectra) |spectrum| {
        if (spectrum.mz.len != spectrum.intensity.len) return error.MismatchedPeakArrays;
        if (spectrum.mz.len > std.math.maxInt(u32)) return error.Overflow;
        total_len = try std.math.add(usize, total_len, record_header_len);
        total_len = try std.math.add(usize, total_len, try std.math.mul(usize, spectrum.mz.len, @sizeOf(f64)));
        total_len = try std.math.add(usize, total_len, try std.math.mul(usize, spectrum.intensity.len, @sizeOf(f32)));
    }
    try bytes.ensureTotalCapacityPrecise(allocator, total_len);

    for (spectra) |spectrum| {
        try appendIntLe(&bytes, allocator, u32, spectrum.scan_id);
        try appendIntLe(&bytes, allocator, u32, @bitCast(spectrum.rt_seconds));
        try bytes.append(allocator, spectrum.ms_level);
        try bytes.appendSlice(allocator, &pad_after_ms_level);
        try appendIntLe(&bytes, allocator, u64, @bitCast(spectrum.precursor_mz));
        try appendIntLe(&bytes, allocator, u32, @intCast(spectrum.mz.len));
        try bytes.appendSlice(allocator, &pad_after_peak_count);
        try appendFloatsLe(&bytes, allocator, f64, spectrum.mz);
        try appendFloatsLe(&bytes, allocator, f32, spectrum.intensity);
    }

    return bytes.toOwnedSlice(allocator);
}

pub fn parseDump(bytes: []const u8, allocator: Allocator) ![]RawSpectrum {
    var spectra: std.ArrayList(RawSpectrum) = .empty;
    errdefer {
        for (spectra.items) |spectrum| {
            allocator.free(spectrum.mz);
            allocator.free(spectrum.intensity);
        }
        spectra.deinit(allocator);
    }

    var offset: usize = 0;
    while (offset < bytes.len) {
        if (bytes.len - offset < record_header_len) return error.UnexpectedEndOfStream;

        const scan_id = readIntLe(u32, bytes[offset..][0..4]);
        const rt_seconds_bits = readIntLe(u32, bytes[offset + 4 ..][0..4]);
        const ms_level = bytes[offset + 8];
        const precursor_mz_bits = readIntLe(u64, bytes[offset + 12 ..][0..8]);
        const peak_count = readIntLe(u32, bytes[offset + 20 ..][0..4]);
        offset += record_header_len;

        const mz_bytes_len = try std.math.mul(usize, peak_count, @sizeOf(f64));
        const intensity_bytes_len = try std.math.mul(usize, peak_count, @sizeOf(f32));
        const payload_len = try std.math.add(usize, mz_bytes_len, intensity_bytes_len);
        if (bytes.len - offset < payload_len) return error.UnexpectedEndOfStream;

        // Block-scoped errdefer so ownership transfer into `spectra` does not double-free later.
        try spectra.ensureUnusedCapacity(allocator, 1);
        spectra.appendAssumeCapacity(blk: {
            const mz = try allocator.alloc(f64, peak_count);
            errdefer allocator.free(mz);
            const intensity = try allocator.alloc(f32, peak_count);
            errdefer allocator.free(intensity);

            readFloatsLe(f64, mz, bytes[offset .. offset + mz_bytes_len]);
            offset += mz_bytes_len;
            readFloatsLe(f32, intensity, bytes[offset .. offset + intensity_bytes_len]);
            offset += intensity_bytes_len;

            break :blk .{
                .scan_id = scan_id,
                .rt_seconds = @bitCast(rt_seconds_bits),
                .ms_level = ms_level,
                .precursor_mz = @bitCast(precursor_mz_bits),
                .mz = mz,
                .intensity = intensity,
            };
        });
    }

    return spectra.toOwnedSlice(allocator);
}

pub fn readBinaryDump(io: std.Io, path: []const u8, allocator: Allocator) ![]RawSpectrum {
    var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer file_arena.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, file_arena.allocator(), .limited(std.math.maxInt(usize)));
    return parseDump(bytes, allocator);
}

pub fn writeBinaryDump(io: std.Io, path: []const u8, spectra: []const RawSpectrum, allocator: Allocator) !void {
    const bytes = try writeDumpAlloc(allocator, spectra);
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn appendIntLe(list: *std.ArrayList(u8), allocator: Allocator, comptime T: type, value: T) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try list.appendSlice(allocator, &buffer);
}

fn readIntLe(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn appendFloatsLe(list: *std.ArrayList(u8), allocator: Allocator, comptime T: type, values: []const T) !void {
    if (builtin.cpu.arch.endian() == .little) {
        try list.appendSlice(allocator, std.mem.sliceAsBytes(values));
        return;
    }
    const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
    for (values) |value| {
        try appendIntLe(list, allocator, Int, @bitCast(value));
    }
}

fn readFloatsLe(comptime T: type, dst: []T, src: []const u8) void {
    if (builtin.cpu.arch.endian() == .little) {
        @memcpy(std.mem.sliceAsBytes(dst), src);
        return;
    }
    const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
    for (dst, 0..) |*value, idx| {
        const start = idx * @sizeOf(T);
        value.* = @bitCast(readIntLe(Int, src[start..][0..@sizeOf(T)]));
    }
}
