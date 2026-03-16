const std = @import("std");
const binary_reader = @import("binary_reader");
const block_v1 = @import("block_v1");

pub const Allocator = std.mem.Allocator;
const io = std.Io.Threaded.global_single_threaded.io();

pub const magic = "MZV1".*;
pub const header_len = 32;
pub const version_major: u16 = 1;
pub const version_minor: u16 = 0;

pub const flag_lossless: u32 = 0b0000_0001;
pub const flag_contains_ms1: u32 = 0b0000_0010;
pub const flag_contains_ms2: u32 = 0b0000_0100;

pub const FileHeader = struct {
    magic_bytes: [4]u8,
    version_major: u16,
    version_minor: u16,
    flags: u32,
    block_size: u16,
    reserved0: u16,
    spectrum_count: u32,
    block_count: u32,
    total_peaks: u64,
};

pub const EncodeOptions = struct {
    block_options: block_v1.EncodeOptions = .{},
    block_size: u16 = 128,
};

pub const BlockInfo = struct {
    offset: usize,
    total_bytes: usize,
    header: block_v1.BlockHeader,
};

pub const Inspection = struct {
    header: FileHeader,
    blocks: []BlockInfo,
    ms1_block_count: usize,
    ms2_block_count: usize,
    ms1_spectra: usize,
    ms2_spectra: usize,
};

fn appendIntLe(list: *std.ArrayList(u8), allocator: Allocator, comptime T: type, value: T) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try list.appendSlice(allocator, &buffer);
}

fn readIntLe(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn parseHeader(bytes: []const u8) !FileHeader {
    if (bytes.len < header_len) return error.UnexpectedEndOfStream;

    const parsed: FileHeader = .{
        .magic_bytes = bytes[0..4].*,
        .version_major = readIntLe(u16, bytes[4..6]),
        .version_minor = readIntLe(u16, bytes[6..8]),
        .flags = readIntLe(u32, bytes[8..12]),
        .block_size = readIntLe(u16, bytes[12..14]),
        .reserved0 = readIntLe(u16, bytes[14..16]),
        .spectrum_count = readIntLe(u32, bytes[16..20]),
        .block_count = readIntLe(u32, bytes[20..24]),
        .total_peaks = readIntLe(u64, bytes[24..32]),
    };

    if (!std.mem.eql(u8, &parsed.magic_bytes, &magic)) return error.InvalidMagic;
    if (parsed.version_major != version_major or parsed.version_minor != version_minor) {
        return error.UnsupportedVersion;
    }

    return parsed;
}

fn writeHeaderInto(bytes: []u8, header: FileHeader) void {
    std.mem.copyForwards(u8, bytes[0..4], &header.magic_bytes);
    std.mem.writeInt(u16, bytes[4..6], header.version_major, .little);
    std.mem.writeInt(u16, bytes[6..8], header.version_minor, .little);
    std.mem.writeInt(u32, bytes[8..12], header.flags, .little);
    std.mem.writeInt(u16, bytes[12..14], header.block_size, .little);
    std.mem.writeInt(u16, bytes[14..16], header.reserved0, .little);
    std.mem.writeInt(u32, bytes[16..20], header.spectrum_count, .little);
    std.mem.writeInt(u32, bytes[20..24], header.block_count, .little);
    std.mem.writeInt(u64, bytes[24..32], header.total_peaks, .little);
}

fn freeSpectrumRefs(allocator: Allocator, spectra: []binary_reader.RawSpectrum) void {
    allocator.free(spectra);
}

fn collectByMsLevel(allocator: Allocator, spectra: []const binary_reader.RawSpectrum, level: u8) ![]binary_reader.RawSpectrum {
    var count: usize = 0;
    for (spectra) |spectrum| {
        if (spectrum.ms_level != 1 and spectrum.ms_level != 2) return error.UnsupportedMsLevel;
        if (spectrum.ms_level == level) count += 1;
    }

    const out = try allocator.alloc(binary_reader.RawSpectrum, count);
    var idx: usize = 0;
    for (spectra) |spectrum| {
        if (spectrum.ms_level == level) {
            out[idx] = spectrum;
            idx += 1;
        }
    }
    return out;
}

fn totalPeaks(spectra: []const binary_reader.RawSpectrum) usize {
    var total: usize = 0;
    for (spectra) |spectrum| total += spectrum.mz.len;
    return total;
}

fn appendStreamBlocks(
    file_bytes: *std.ArrayList(u8),
    allocator: Allocator,
    spectra: []const binary_reader.RawSpectrum,
    options: EncodeOptions,
    block_count: *u32,
) !void {
    if (spectra.len == 0) return;

    var offset: usize = 0;
    while (offset < spectra.len) {
        const end = @min(offset + @as(usize, options.block_size), spectra.len);
        const encoded = try block_v1.encodeBlock(allocator, spectra[offset..end], options.block_options);
        defer allocator.free(encoded);
        try file_bytes.appendSlice(allocator, encoded);
        block_count.* += 1;
        offset = end;
    }
}

pub fn encodeFileAlloc(allocator: Allocator, spectra: []const binary_reader.RawSpectrum, options: EncodeOptions) ![]u8 {
    if (options.block_size == 0) return error.InvalidBlockSize;
    if (spectra.len > std.math.maxInt(u32)) return error.TooManySpectra;

    const ms1 = try collectByMsLevel(allocator, spectra, 1);
    defer freeSpectrumRefs(allocator, ms1);
    const ms2 = try collectByMsLevel(allocator, spectra, 2);
    defer freeSpectrumRefs(allocator, ms2);

    var file_bytes: std.ArrayList(u8) = .empty;
    errdefer file_bytes.deinit(allocator);
    try file_bytes.appendNTimes(allocator, 0, header_len);

    var flags: u32 = 0;
    if (options.block_options.mode == .lossless) flags |= flag_lossless;
    if (ms1.len != 0) flags |= flag_contains_ms1;
    if (ms2.len != 0) flags |= flag_contains_ms2;

    var block_count: u32 = 0;
    try appendStreamBlocks(&file_bytes, allocator, ms1, options, &block_count);
    try appendStreamBlocks(&file_bytes, allocator, ms2, options, &block_count);

    const header: FileHeader = .{
        .magic_bytes = magic,
        .version_major = version_major,
        .version_minor = version_minor,
        .flags = flags,
        .block_size = options.block_size,
        .reserved0 = 0,
        .spectrum_count = @intCast(spectra.len),
        .block_count = block_count,
        .total_peaks = @intCast(totalPeaks(spectra)),
    };
    writeHeaderInto(file_bytes.items[0..header_len], header);

    return file_bytes.toOwnedSlice(allocator);
}

pub fn inspectAlloc(allocator: Allocator, bytes: []const u8) !Inspection {
    const header = try parseHeader(bytes);
    const blocks = try allocator.alloc(BlockInfo, @intCast(header.block_count));
    errdefer allocator.free(blocks);

    var offset: usize = header_len;
    var ms1_block_count: usize = 0;
    var ms2_block_count: usize = 0;
    var ms1_spectra: usize = 0;
    var ms2_spectra: usize = 0;

    for (blocks, 0..) |*block_info, idx| {
        _ = idx;
        if (bytes.len - offset < block_v1.header_len) return error.UnexpectedEndOfStream;
        const block_header = try block_v1.parseHeader(bytes[offset .. offset + block_v1.header_len]);
        const total_bytes = block_v1.header_len + @as(usize, block_header.payload_bytes);
        if (bytes.len - offset < total_bytes) return error.UnexpectedEndOfStream;

        block_info.* = .{
            .offset = offset,
            .total_bytes = total_bytes,
            .header = block_header,
        };

        switch (block_header.ms_level) {
            1 => {
                ms1_block_count += 1;
                ms1_spectra += block_header.spectrum_count;
            },
            2 => {
                ms2_block_count += 1;
                ms2_spectra += block_header.spectrum_count;
            },
            else => return error.UnsupportedMsLevel,
        }

        offset += total_bytes;
    }

    if (offset != bytes.len) return error.TrailingFileData;

    return .{
        .header = header,
        .blocks = blocks,
        .ms1_block_count = ms1_block_count,
        .ms2_block_count = ms2_block_count,
        .ms1_spectra = ms1_spectra,
        .ms2_spectra = ms2_spectra,
    };
}

pub fn freeInspection(allocator: Allocator, inspection: Inspection) void {
    allocator.free(inspection.blocks);
}

pub fn decodeFileAlloc(allocator: Allocator, bytes: []const u8) ![]binary_reader.RawSpectrum {
    const inspection = try inspectAlloc(allocator, bytes);
    defer freeInspection(allocator, inspection);

    const spectra = try allocator.alloc(binary_reader.RawSpectrum, @intCast(inspection.header.spectrum_count));
    errdefer {
        for (spectra[0..]) |spectrum| {
            allocator.free(spectrum.mz);
            allocator.free(spectrum.intensity);
        }
        allocator.free(spectra);
    }

    var spectrum_offset: usize = 0;
    for (inspection.blocks) |block_info| {
        const decoded = try block_v1.decodeBlock(allocator, bytes[block_info.offset .. block_info.offset + block_info.total_bytes]);

        @memcpy(spectra[spectrum_offset .. spectrum_offset + decoded.len], decoded);
        spectrum_offset += decoded.len;
        allocator.free(decoded);
    }

    return spectra;
}

pub fn readFileAlloc(path: []const u8, allocator: Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(std.math.maxInt(usize)));
}

pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

pub fn encodeDumpFile(allocator: Allocator, input_path: []const u8, output_path: []const u8, options: EncodeOptions) !void {
    const spectra = try binary_reader.readBinaryDump(input_path, allocator);
    defer binary_reader.freeSpectra(allocator, spectra);

    const encoded = try encodeFileAlloc(allocator, spectra, options);
    defer allocator.free(encoded);

    try writeFile(output_path, encoded);
}

pub fn decodeToDumpFile(allocator: Allocator, input_path: []const u8, output_path: []const u8) !void {
    const bytes = try readFileAlloc(input_path, allocator);
    defer allocator.free(bytes);

    const spectra = try decodeFileAlloc(allocator, bytes);
    defer binary_reader.freeSpectra(allocator, spectra);

    try binary_reader.writeBinaryDump(output_path, spectra);
}

pub fn inspectFileAlloc(allocator: Allocator, path: []const u8) !Inspection {
    const bytes = try readFileAlloc(path, allocator);
    defer allocator.free(bytes);
    return inspectAlloc(allocator, bytes);
}
