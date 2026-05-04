const std = @import("std");
const builtin = @import("builtin");

pub const Allocator = std.mem.Allocator;
const io = std.Io.Threaded.global_single_threaded.io();

pub const RawSpectrum = struct {
    scan_id: u32,
    rt_seconds: f32,
    ms_level: u8,
    precursor_mz: f64,
    mz: []f64,
    intensity: []f32,
};

const record_padding_1 = [_]u8{ 0, 0, 0 };
const record_padding_2 = [_]u8{ 0, 0, 0, 0 };
const record_header_len = 28;

pub fn freeSpectra(allocator: Allocator, spectra: []RawSpectrum) void {
    for (spectra) |spectrum| {
        allocator.free(spectrum.mz);
        allocator.free(spectrum.intensity);
    }
    allocator.free(spectra);
}

fn appendIntLe(list: *std.ArrayList(u8), allocator: Allocator, comptime T: type, value: T) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try list.appendSlice(allocator, &buffer);
}

pub fn writeDumpAlloc(allocator: Allocator, spectra: []const RawSpectrum) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    var total_len: usize = 0;
    for (spectra) |spectrum| {
        total_len += record_header_len;
        total_len += std.mem.sliceAsBytes(spectrum.mz).len;
        total_len += std.mem.sliceAsBytes(spectrum.intensity).len;
    }
    try bytes.ensureTotalCapacityPrecise(allocator, total_len);

    for (spectra) |spectrum| {
        try appendIntLe(&bytes, allocator, u32, spectrum.scan_id);
        try appendIntLe(&bytes, allocator, u32, @as(u32, @bitCast(spectrum.rt_seconds)));
        try bytes.append(allocator, spectrum.ms_level);
        try bytes.appendSlice(allocator, &record_padding_1);
        try appendIntLe(&bytes, allocator, u64, @as(u64, @bitCast(spectrum.precursor_mz)));
        try appendIntLe(&bytes, allocator, u32, @intCast(spectrum.mz.len));
        try bytes.appendSlice(allocator, &record_padding_2);

        if (builtin.cpu.arch.endian() == .little) {
            try bytes.appendSlice(allocator, std.mem.sliceAsBytes(spectrum.mz));
            try bytes.appendSlice(allocator, std.mem.sliceAsBytes(spectrum.intensity));
        } else {
            for (spectrum.mz) |mz_value| {
                try appendIntLe(&bytes, allocator, u64, @as(u64, @bitCast(mz_value)));
            }

            for (spectrum.intensity) |intensity_value| {
                try appendIntLe(&bytes, allocator, u32, @as(u32, @bitCast(intensity_value)));
            }
        }
    }

    return bytes.toOwnedSlice(allocator);
}

fn readIntLe(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
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
    while (true) {
        if (offset == bytes.len) break;
        if (bytes.len - offset < record_header_len) return error.UnexpectedEndOfStream;

        const scan_id = readIntLe(u32, bytes[offset..][0..4]);
        const rt_seconds_bits = readIntLe(u32, bytes[offset + 4 ..][0..4]);
        const ms_level = bytes[offset + 8];
        const precursor_mz_bits = readIntLe(u64, bytes[offset + 12 ..][0..8]);
        const peak_count = readIntLe(u32, bytes[offset + 20 ..][0..4]);
        offset += record_header_len;

        const mz_bytes_len: usize = @as(usize, peak_count) * @sizeOf(f64);
        const intensity_bytes_len: usize = @as(usize, peak_count) * @sizeOf(f32);
        if (bytes.len - offset < mz_bytes_len + intensity_bytes_len) return error.UnexpectedEndOfStream;

        const mz = try allocator.alloc(f64, peak_count);
        errdefer allocator.free(mz);

        const intensity = try allocator.alloc(f32, peak_count);
        errdefer allocator.free(intensity);

        if (builtin.cpu.arch.endian() == .little) {
            @memcpy(std.mem.sliceAsBytes(mz), bytes[offset .. offset + mz_bytes_len]);
        } else {
            for (mz, 0..) |*mz_value, idx| {
                const start = offset + (idx * @sizeOf(f64));
                const bits = readIntLe(u64, bytes[start..][0..@sizeOf(f64)]);
                mz_value.* = @bitCast(bits);
            }
        }
        offset += mz_bytes_len;

        if (builtin.cpu.arch.endian() == .little) {
            @memcpy(std.mem.sliceAsBytes(intensity), bytes[offset .. offset + intensity_bytes_len]);
        } else {
            for (intensity, 0..) |*intensity_value, idx| {
                const start = offset + (idx * @sizeOf(f32));
                const bits = readIntLe(u32, bytes[start..][0..@sizeOf(f32)]);
                intensity_value.* = @bitCast(bits);
            }
        }
        offset += intensity_bytes_len;

        try spectra.append(allocator, .{
            .scan_id = scan_id,
            .rt_seconds = @bitCast(rt_seconds_bits),
            .ms_level = ms_level,
            .precursor_mz = @bitCast(precursor_mz_bits),
            .mz = mz,
            .intensity = intensity,
        });
    }

    return spectra.toOwnedSlice(allocator);
}

pub fn readBinaryDump(path: []const u8, allocator: Allocator) ![]RawSpectrum {
    var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer file_arena.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, file_arena.allocator(), .limited(std.math.maxInt(usize)));
    return parseDump(bytes, allocator);
}

pub fn writeBinaryDump(path: []const u8, spectra: []const RawSpectrum, allocator: Allocator) !void {
    const bytes = try writeDumpAlloc(allocator, spectra);
    defer allocator.free(bytes);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = bytes,
    });
}
