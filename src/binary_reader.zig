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

pub const DumpEntry = struct {
    payload_offset: u64,
    precursor_bits: u64,
    scan_id: u32,
    rt_bits: u32,
    peak_count: u32,
    ms_level: u8,
};

pub const DumpIndex = struct {
    entries: []DumpEntry,
    total_peaks: u64,
    ms1_count: usize,
    ms2_count: usize,

    pub fn deinit(self: DumpIndex, allocator: Allocator) void {
        allocator.free(self.entries);
    }
};

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

fn checkedAddU64(a: u64, b: u64) !u64 {
    return std.math.add(u64, a, b);
}

fn checkedMulU64(a: u64, b: u64) !u64 {
    return std.math.mul(u64, a, b);
}

fn readExactAt(file: std.Io.File, io: std.Io, bytes: []u8, offset: u64) !void {
    if (try file.readPositionalAll(io, bytes, offset) != bytes.len) return error.UnexpectedEndOfStream;
}

/// Scan Dump V1 structure without retaining peak arrays. Caller owns `entries`.
pub fn scanFile(allocator: Allocator, io: std.Io, file: std.Io.File) !DumpIndex {
    const file_size = (try file.stat(io)).size;
    var entries: std.ArrayList(DumpEntry) = .empty;
    errdefer entries.deinit(allocator);

    var total_peaks: u64 = 0;
    var ms1_count: usize = 0;
    var ms2_count: usize = 0;
    var has_unsupported_ms_level = false;
    var offset: u64 = 0;
    while (offset < file_size) {
        if (file_size - offset < record_header_len) return error.UnexpectedEndOfStream;

        var header: [record_header_len]u8 = undefined;
        try readExactAt(file, io, &header, offset);
        const peak_count = readIntLe(u32, header[20..24]);
        const payload_bytes = try checkedMulU64(peak_count, @sizeOf(f64) + @sizeOf(f32));
        const payload_offset = try checkedAddU64(offset, record_header_len);
        const next_offset = try checkedAddU64(payload_offset, payload_bytes);
        if (next_offset > file_size) return error.UnexpectedEndOfStream;

        if (entries.items.len == std.math.maxInt(u32)) return error.TooManySpectra;
        const ms_level = header[8];
        switch (ms_level) {
            1 => ms1_count += 1,
            2 => ms2_count += 1,
            else => has_unsupported_ms_level = true,
        }
        total_peaks = try checkedAddU64(total_peaks, peak_count);
        try entries.append(allocator, .{
            .payload_offset = payload_offset,
            .precursor_bits = readIntLe(u64, header[12..20]),
            .scan_id = readIntLe(u32, header[0..4]),
            .rt_bits = readIntLe(u32, header[4..8]),
            .peak_count = peak_count,
            .ms_level = ms_level,
        });
        offset = next_offset;
    }
    if (has_unsupported_ms_level) return error.UnsupportedMsLevel;

    return .{
        .entries = try entries.toOwnedSlice(allocator),
        .total_peaks = total_peaks,
        .ms1_count = ms1_count,
        .ms2_count = ms2_count,
    };
}

fn readExact(reader: *std.Io.File.Reader, bytes: []u8) !void {
    reader.interface.readSliceAll(bytes) catch |err| switch (err) {
        error.EndOfStream => return error.UnexpectedEndOfStream,
        error.ReadFailed => return reader.err orelse error.InputOutput,
    };
}

fn readFloatSlice(
    scratch: Allocator,
    comptime T: type,
    reader: *std.Io.File.Reader,
    values: []T,
) !void {
    if (builtin.cpu.arch.endian() == .little) {
        try readExact(reader, std.mem.sliceAsBytes(values));
        return;
    }

    const bytes = try scratch.alloc(u8, try std.math.mul(usize, values.len, @sizeOf(T)));
    try readExact(reader, bytes);
    readFloatsLe(T, values, bytes);
}

/// Returned peak slices belong to `scratch`, which must outlive the active block.
pub fn readSpectrumAt(
    scratch: Allocator,
    reader: *std.Io.File.Reader,
    entry: DumpEntry,
) !RawSpectrum {
    try reader.seekTo(entry.payload_offset);
    const mz = try scratch.alloc(f64, entry.peak_count);
    const intensity = try scratch.alloc(f32, entry.peak_count);
    try readFloatSlice(scratch, f64, reader, mz);
    try readFloatSlice(scratch, f32, reader, intensity);
    return .{
        .scan_id = entry.scan_id,
        .rt_seconds = @bitCast(entry.rt_bits),
        .ms_level = entry.ms_level,
        .precursor_mz = @bitCast(entry.precursor_bits),
        .mz = mz,
        .intensity = intensity,
    };
}

/// Return the serialized Dump V1 length for one spectrum.
pub fn recordLen(peak_count: u32) !u64 {
    return checkedAddU64(record_header_len, try checkedMulU64(peak_count, @sizeOf(f64) + @sizeOf(f32)));
}

fn floatBytesLe(scratch: Allocator, comptime T: type, values: []const T) ![]const u8 {
    if (builtin.cpu.arch.endian() == .little) return std.mem.sliceAsBytes(values);

    const bytes = try scratch.alloc(u8, try std.math.mul(usize, values.len, @sizeOf(T)));
    const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
    for (values, 0..) |value, idx| {
        const start = idx * @sizeOf(T);
        std.mem.writeInt(Int, bytes[start..][0..@sizeOf(T)], @bitCast(value), .little);
    }
    return bytes;
}

fn writeVectorsAll(file: std.Io.File, io: std.Io, vectors: *const [3][]const u8, offset: u64) !void {
    var vector_index: usize = 0;
    var vector_offset: usize = 0;
    var file_offset = offset;
    while (vector_index < vectors.len) {
        while (vector_index < vectors.len and vector_offset == vectors[vector_index].len) {
            vector_index += 1;
            vector_offset = 0;
        }
        if (vector_index == vectors.len) break;

        var active: [3][]const u8 = undefined;
        var active_len: usize = 0;
        active[active_len] = vectors[vector_index][vector_offset..];
        active_len += 1;
        for (vectors[vector_index + 1 ..]) |vector| {
            if (vector.len == 0) continue;
            active[active_len] = vector;
            active_len += 1;
        }

        var remaining = try file.writePositional(io, active[0..active_len], file_offset);
        if (remaining == 0) return error.WriteZero;
        file_offset = try checkedAddU64(file_offset, remaining);
        while (remaining != 0) {
            const available = vectors[vector_index].len - vector_offset;
            if (remaining < available) {
                vector_offset += remaining;
                remaining = 0;
            } else {
                remaining -= available;
                vector_index += 1;
                vector_offset = 0;
                while (vector_index < vectors.len and vectors[vector_index].len == 0) vector_index += 1;
            }
        }
    }
}

/// Write one spectrum at its final Dump V1 offset. `scratch` is block-scoped.
pub fn writeSpectrumAt(scratch: Allocator, io: std.Io, file: std.Io.File, spectrum: RawSpectrum, offset: u64) !void {
    if (spectrum.mz.len != spectrum.intensity.len) return error.MismatchedPeakArrays;
    if (spectrum.mz.len > std.math.maxInt(u32)) return error.Overflow;

    var header: [record_header_len]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], spectrum.scan_id, .little);
    std.mem.writeInt(u32, header[4..8], @bitCast(spectrum.rt_seconds), .little);
    header[8] = spectrum.ms_level;
    std.mem.writeInt(u64, header[12..20], @bitCast(spectrum.precursor_mz), .little);
    std.mem.writeInt(u32, header[20..24], @intCast(spectrum.mz.len), .little);
    const mz_bytes = try floatBytesLe(scratch, f64, spectrum.mz);
    const intensity_bytes = try floatBytesLe(scratch, f32, spectrum.intensity);
    try writeVectorsAll(file, io, &.{ &header, mz_bytes, intensity_bytes }, offset);
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
