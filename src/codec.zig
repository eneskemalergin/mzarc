const std = @import("std");
const binary_reader = @import("binary_reader");
const block = @import("block");

pub const Allocator = std.mem.Allocator;
const io = std.Io.Threaded.global_single_threaded.io();

pub const magic = "MZAR".*;
pub const header_len = 32;
pub const version_major: u16 = 1;
pub const version_minor: u16 = 1;

pub const flag_lossless: u32 = 0b0000_0001;
pub const flag_contains_ms1: u32 = 0b0000_0010;
pub const flag_contains_ms2: u32 = 0b0000_0100;
pub const flag_has_global_order: u32 = 0b0000_1000;

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
    block_options: block.EncodeOptions = .{},
    block_size: u16 = 128,
};

pub const BlockInfo = struct {
    offset: usize,
    total_bytes: usize,
    header: block.BlockHeader,
    byte_breakdown: block.BlockByteBreakdown,
};

fn percentGain(raw_bytes: usize, stored_bytes: usize) f64 {
    if (raw_bytes == 0 or stored_bytes >= raw_bytes) return 0.0;
    return (1.0 - (@as(f64, @floatFromInt(stored_bytes)) / @as(f64, @floatFromInt(raw_bytes)))) * 100.0;
}

fn intensityModeLabel(mode: block.IntensityEncodingMode) []const u8 {
    return switch (mode) {
        .raw_plain => "raw",
        .split_plain => "split",
        .split_rans => "split+rANS",
        .lossy_plain => "lossy",
        .lossy_rans => "lossy+rANS",
    };
}

fn maybePrintBlockStats(block_index: u32, stats: block.BlockEncodeStats, options: EncodeOptions) void {
    if (!options.block_options.verbose_blocks) return;
    std.debug.print(
        "[block {} ms{}] peaks={} nspec={} mz rans={s} raw={} stored={} gain={d:.2}% est={} intensity mode={s} rans={s} base={} stored={} raw_f32={} gain={d:.2}% est={} payload={}\n",
        .{
            block_index,
            stats.ms_level,
            stats.total_peaks,
            stats.spectrum_count,
            if (stats.mz_rans_used) "yes" else "no",
            stats.mz_raw_bytes,
            stats.mz_stored_bytes,
            percentGain(stats.mz_raw_bytes, stats.mz_stored_bytes),
            stats.mz_estimated_rans_bytes,
            intensityModeLabel(stats.intensity_mode),
            if (stats.intensity_rans_used) "yes" else "no",
            stats.intensity_base_bytes,
            stats.intensity_stored_bytes,
            stats.intensity_raw_f32_bytes,
            percentGain(stats.intensity_base_bytes, stats.intensity_stored_bytes),
            stats.intensity_estimated_rans_bytes,
            stats.payload_bytes,
        },
    );
}

pub const FileByteBreakdown = struct {
    file_header_bytes: usize,
    global_order_bytes: usize,
    block_header_bytes: usize,
    scan_id_bytes: usize,
    rt_bytes: usize,
    precursor_bytes: usize,
    peak_count_bytes: usize,
    mz_metadata_bytes: usize,
    mz_payload_bytes: usize,
    intensity_metadata_bytes: usize,
    intensity_payload_bytes: usize,
    total_bytes: usize,
};

pub const Inspection = struct {
    header: FileHeader,
    blocks: []BlockInfo,
    ms1_block_count: usize,
    ms2_block_count: usize,
    ms1_spectra: usize,
    ms2_spectra: usize,
    byte_breakdown: FileByteBreakdown,
};

fn emptyFileByteBreakdown(order_bytes: usize) FileByteBreakdown {
    return .{
        .file_header_bytes = header_len,
        .global_order_bytes = order_bytes,
        .block_header_bytes = 0,
        .scan_id_bytes = 0,
        .rt_bytes = 0,
        .precursor_bytes = 0,
        .peak_count_bytes = 0,
        .mz_metadata_bytes = 0,
        .mz_payload_bytes = 0,
        .intensity_metadata_bytes = 0,
        .intensity_payload_bytes = 0,
        .total_bytes = header_len + order_bytes,
    };
}

fn addBlockBytes(total: *FileByteBreakdown, block_bytes: block.BlockByteBreakdown) void {
    total.block_header_bytes += block_bytes.header_bytes;
    total.scan_id_bytes += block_bytes.scan_id_bytes;
    total.rt_bytes += block_bytes.rt_bytes;
    total.precursor_bytes += block_bytes.precursor_bytes;
    total.peak_count_bytes += block_bytes.peak_count_bytes;
    total.mz_metadata_bytes += block_bytes.mz_metadata_bytes;
    total.mz_payload_bytes += block_bytes.mz_payload_bytes;
    total.intensity_metadata_bytes += block_bytes.intensity_metadata_bytes;
    total.intensity_payload_bytes += block_bytes.intensity_payload_bytes;
    total.total_bytes += block_bytes.total_bytes;
}

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
    if (parsed.version_major != version_major or parsed.version_minor > version_minor) {
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

fn writeOrderEntry(bytes: []u8, entry_index: usize, value: u32) void {
    const start = entry_index * @sizeOf(u32);
    std.mem.writeInt(u32, bytes[start..][0..@sizeOf(u32)], value, .little);
}

fn readOrderEntry(bytes: []const u8, entry_index: usize) u32 {
    const start = entry_index * @sizeOf(u32);
    return readIntLe(u32, bytes[start .. start + @sizeOf(u32)]);
}

fn globalOrderTableLen(spectrum_count: u32) usize {
    return @as(usize, spectrum_count) * @sizeOf(u32);
}

fn blocksOffset(header: FileHeader, bytes: []const u8) !usize {
    var offset: usize = header_len;
    if ((header.flags & flag_has_global_order) != 0) {
        const order_len = globalOrderTableLen(header.spectrum_count);
        if (bytes.len - offset < order_len) return error.UnexpectedEndOfStream;
        offset += order_len;
    }
    return offset;
}

fn readValidatedGlobalOrderAlloc(allocator: Allocator, header: FileHeader, bytes: []const u8) ![]u32 {
    const order_len = globalOrderTableLen(header.spectrum_count);
    const order_bytes = bytes[header_len .. header_len + order_len];
    const order = try allocator.alloc(u32, header.spectrum_count);
    errdefer allocator.free(order);

    const seen = try allocator.alloc(bool, header.spectrum_count);
    defer allocator.free(seen);
    @memset(seen, false);

    for (0..order.len) |file_index| {
        const original_index = readOrderEntry(order_bytes, file_index);
        if (original_index >= order.len or seen[original_index]) return error.InvalidOrderTable;
        seen[original_index] = true;
        order[file_index] = original_index;
    }

    return order;
}

fn totalPeaks(spectra: []const binary_reader.RawSpectrum) usize {
    var total: usize = 0;
    for (spectra) |spectrum| total += spectrum.mz.len;
    return total;
}

fn appendFilteredStreamBlocks(
    file_bytes: *std.ArrayList(u8),
    allocator: Allocator,
    spectra: []const binary_reader.RawSpectrum,
    level: u8,
    options: EncodeOptions,
    order_entries: []u32,
    order_cursor: *usize,
    block_count: *u32,
) !usize {
    const block_capacity = @as(usize, options.block_size);
    var matched: usize = 0;
    const block_spectra = try allocator.alloc(binary_reader.RawSpectrum, block_capacity);
    defer allocator.free(block_spectra);

    var used: usize = 0;
    for (spectra, 0..) |spectrum, spectrum_index| {
        if (spectrum.ms_level == level) {
            block_spectra[used] = spectrum;
            order_entries[order_cursor.*] = @intCast(spectrum_index);
            used += 1;
            matched += 1;
            order_cursor.* += 1;

            if (used == block_capacity) {
                const encoded = try block.encodeBlockDetailed(allocator, block_spectra[0..used], options.block_options);
                defer encoded.deinit(allocator);
                maybePrintBlockStats(block_count.*, encoded.stats, options);
                try file_bytes.appendSlice(allocator, encoded.bytes);
                block_count.* += 1;
                used = 0;
            }
        }
    }

    if (used != 0) {
        const encoded = try block.encodeBlockDetailed(allocator, block_spectra[0..used], options.block_options);
        defer encoded.deinit(allocator);
        maybePrintBlockStats(block_count.*, encoded.stats, options);
        try file_bytes.appendSlice(allocator, encoded.bytes);
        block_count.* += 1;
    }

    return matched;
}

pub fn encodeFileAlloc(allocator: Allocator, spectra: []const binary_reader.RawSpectrum, options: EncodeOptions) ![]u8 {
    if (options.block_size == 0) return error.InvalidBlockSize;
    if (spectra.len > std.math.maxInt(u32)) return error.TooManySpectra;

    var ms1_count: usize = 0;
    var ms2_count: usize = 0;
    for (spectra) |spectrum| {
        switch (spectrum.ms_level) {
            1 => ms1_count += 1,
            2 => ms2_count += 1,
            else => return error.UnsupportedMsLevel,
        }
    }

    var file_bytes: std.ArrayList(u8) = .empty;
    errdefer file_bytes.deinit(allocator);
    const order_len = globalOrderTableLen(@intCast(spectra.len));
    try file_bytes.appendNTimes(allocator, 0, header_len + order_len);
    const order_entries = try allocator.alloc(u32, spectra.len);
    defer allocator.free(order_entries);

    var flags: u32 = 0;
    if (options.block_options.mode == .lossless) flags |= flag_lossless;
    if (ms1_count != 0) flags |= flag_contains_ms1;
    if (ms2_count != 0) flags |= flag_contains_ms2;
    flags |= flag_has_global_order;

    var block_count: u32 = 0;
    var order_cursor: usize = 0;
    _ = try appendFilteredStreamBlocks(&file_bytes, allocator, spectra, 1, options, order_entries, &order_cursor, &block_count);
    _ = try appendFilteredStreamBlocks(&file_bytes, allocator, spectra, 2, options, order_entries, &order_cursor, &block_count);
    if (order_cursor != spectra.len) return error.InvalidOrderTable;

    const order_bytes = file_bytes.items[header_len .. header_len + order_len];
    for (order_entries, 0..) |entry, entry_index| writeOrderEntry(order_bytes, entry_index, entry);

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

    const initial_offset = try blocksOffset(header, bytes);
    var offset = initial_offset;
    var ms1_block_count: usize = 0;
    var ms2_block_count: usize = 0;
    var ms1_spectra: usize = 0;
    var ms2_spectra: usize = 0;
    var byte_breakdown = emptyFileByteBreakdown(initial_offset - header_len);

    for (blocks, 0..) |*block_info, idx| {
        _ = idx;
        if (bytes.len - offset < block.header_len) return error.UnexpectedEndOfStream;
        const block_header = try block.parseHeader(bytes[offset .. offset + block.header_len]);
        const total_bytes = block.header_len + @as(usize, block_header.payload_bytes);
        if (bytes.len - offset < total_bytes) return error.UnexpectedEndOfStream;
        const block_breakdown = try block.inspectBlockByteBreakdown(bytes[offset .. offset + total_bytes]);

        block_info.* = .{
            .offset = offset,
            .total_bytes = total_bytes,
            .header = block_header,
            .byte_breakdown = block_breakdown,
        };
        addBlockBytes(&byte_breakdown, block_breakdown);

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
        .byte_breakdown = byte_breakdown,
    };
}

pub fn freeInspection(allocator: Allocator, inspection: Inspection) void {
    allocator.free(inspection.blocks);
}

pub fn decodeFileAlloc(allocator: Allocator, bytes: []const u8) ![]binary_reader.RawSpectrum {
    const inspection = try inspectAlloc(allocator, bytes);
    defer freeInspection(allocator, inspection);

    const global_order = if ((inspection.header.flags & flag_has_global_order) != 0)
        try readValidatedGlobalOrderAlloc(allocator, inspection.header, bytes)
    else
        null;
    defer if (global_order) |order| allocator.free(order);

    const spectra = try allocator.alloc(binary_reader.RawSpectrum, @intCast(inspection.header.spectrum_count));
    var initialized: usize = 0;
    errdefer {
        for (spectra[0..initialized]) |spectrum| {
            allocator.free(spectrum.mz);
            allocator.free(spectrum.intensity);
        }
        allocator.free(spectra);
    }

    var spectrum_offset: usize = 0;
    for (inspection.blocks) |block_info| {
        const decoded = try block.decodeBlock(allocator, bytes[block_info.offset .. block_info.offset + block_info.total_bytes]);

        @memcpy(spectra[spectrum_offset .. spectrum_offset + decoded.len], decoded);
        spectrum_offset += decoded.len;
        initialized = spectrum_offset;
        allocator.free(decoded);
    }

    if (global_order == null) return spectra;

    const reordered = try allocator.alloc(binary_reader.RawSpectrum, spectra.len);
    for (global_order.?, 0..) |original_index, file_index| {
        reordered[original_index] = spectra[file_index];
    }
    allocator.free(spectra);
    return reordered;
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
