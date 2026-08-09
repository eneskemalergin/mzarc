//! `.mzarc` file header, global order table, and block orchestration.
//! Fail closed on bad magic/version, truncation, and order-table corruption.
//! Block scratch arenas are reset, not individually freed.

const std = @import("std");
const binary_reader = @import("binary_reader");
const block = @import("block");

pub const Allocator = std.mem.Allocator;

fn monotonicNs(io: std.Io) u64 {
    return @truncate(@as(u96, @bitCast(std.Io.Clock.now(.awake, io).nanoseconds)));
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn nsPct(part: u64, total: u64) f64 {
    if (total == 0) return 0.0;
    return @as(f64, @floatFromInt(part)) * 100.0 / @as(f64, @floatFromInt(total));
}

pub const magic = "MZAR".*;
pub const header_len = 32;
pub const version_major: u16 = 1;
pub const version_minor: u16 = 3;

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
    verbose_timing: bool = false,
};

pub const DecodeOptions = struct {
    verbose_timing: bool = false,
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

fn mzLayoutLabel(stats: block.BlockEncodeStats) []const u8 {
    return if (stats.mz_per_spectrum_widths) "per-spectrum" else "block";
}

fn maybePrintBlockStats(block_index: u32, stats: block.BlockEncodeStats, options: EncodeOptions) void {
    if (!options.block_options.verbose_blocks) return;
    std.debug.print(
        "[block {} ms{}] peaks={} nspec={} mz layout={s} rans={s} raw={} stored={} gain={d:.2}% est={} intensity mode={s} rans={s} base={} stored={} raw_f32={} gain={d:.2}% est={} payload={}\n",
        .{
            block_index,
            stats.ms_level,
            stats.total_peaks,
            stats.spectrum_count,
            mzLayoutLabel(stats),
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

fn emptyFileByteBreakdown(order_bytes: usize) !FileByteBreakdown {
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
        .total_bytes = try std.math.add(usize, header_len, order_bytes),
    };
}

fn addBlockBytes(total: *FileByteBreakdown, block_bytes: block.BlockByteBreakdown) !void {
    total.block_header_bytes = try std.math.add(usize, total.block_header_bytes, block_bytes.header_bytes);
    total.scan_id_bytes = try std.math.add(usize, total.scan_id_bytes, block_bytes.scan_id_bytes);
    total.rt_bytes = try std.math.add(usize, total.rt_bytes, block_bytes.rt_bytes);
    total.precursor_bytes = try std.math.add(usize, total.precursor_bytes, block_bytes.precursor_bytes);
    total.peak_count_bytes = try std.math.add(usize, total.peak_count_bytes, block_bytes.peak_count_bytes);
    total.mz_metadata_bytes = try std.math.add(usize, total.mz_metadata_bytes, block_bytes.mz_metadata_bytes);
    total.mz_payload_bytes = try std.math.add(usize, total.mz_payload_bytes, block_bytes.mz_payload_bytes);
    total.intensity_metadata_bytes = try std.math.add(usize, total.intensity_metadata_bytes, block_bytes.intensity_metadata_bytes);
    total.intensity_payload_bytes = try std.math.add(usize, total.intensity_payload_bytes, block_bytes.intensity_payload_bytes);
    total.total_bytes = try std.math.add(usize, total.total_bytes, block_bytes.total_bytes);
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

fn writeOrderEntry(bytes: []u8, entry_index: usize, value: u32) !void {
    const start = try std.math.mul(usize, entry_index, @sizeOf(u32));
    std.mem.writeInt(u32, bytes[start..][0..@sizeOf(u32)], value, .little);
}

fn readOrderEntry(bytes: []const u8, entry_index: usize) !u32 {
    const start = try std.math.mul(usize, entry_index, @sizeOf(u32));
    return readIntLe(u32, bytes[start .. start + @sizeOf(u32)]);
}

fn globalOrderTableLen(spectrum_count: u32) !usize {
    return try std.math.mul(usize, spectrum_count, @sizeOf(u32));
}

fn blocksOffset(header: FileHeader, bytes: []const u8) !usize {
    var offset: usize = header_len;
    if ((header.flags & flag_has_global_order) != 0) {
        const order_len = try globalOrderTableLen(header.spectrum_count);
        if (bytes.len - offset < order_len) return error.UnexpectedEndOfStream;
        offset = try std.math.add(usize, offset, order_len);
    }
    return offset;
}

fn readValidatedGlobalOrderAlloc(allocator: Allocator, header: FileHeader, bytes: []const u8) ![]u32 {
    const order_len = try globalOrderTableLen(header.spectrum_count);
    const order_bytes = bytes[header_len .. header_len + order_len];
    const order = try allocator.alloc(u32, header.spectrum_count);
    errdefer allocator.free(order);

    const seen = try allocator.alloc(bool, header.spectrum_count);
    defer allocator.free(seen);
    @memset(seen, false);

    for (0..order.len) |file_index| {
        const original_index = try readOrderEntry(order_bytes, file_index);
        if (original_index >= order.len or seen[original_index]) return error.InvalidOrderTable;
        seen[original_index] = true;
        order[file_index] = original_index;
    }

    return order;
}

fn totalPeaks(spectra: []const binary_reader.RawSpectrum) !u64 {
    var total: u64 = 0;
    for (spectra) |spectrum| {
        total = try std.math.add(u64, total, spectrum.mz.len);
    }
    return total;
}

fn writeVersionMinor(options: EncodeOptions) u16 {
    if (options.block_options.file_version_minor) |v| return v;
    return version_minor;
}

fn flushBlock(
    file_bytes: *std.ArrayList(u8),
    allocator: Allocator,
    scratch_arena: *std.heap.ArenaAllocator,
    spectra: []const binary_reader.RawSpectrum,
    options: EncodeOptions,
    block_count: *u32,
) !void {
    var block_options = options.block_options;
    if (block_options.file_version_minor == null) {
        block_options.file_version_minor = writeVersionMinor(options);
    }
    const encoded = try block.encodeBlockDetailed(allocator, scratch_arena.allocator(), spectra, block_options);
    defer encoded.deinit(allocator);
    _ = scratch_arena.reset(.retain_capacity);
    maybePrintBlockStats(block_count.*, encoded.stats, options);
    try file_bytes.appendSlice(allocator, encoded.bytes);
    block_count.* += 1;
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

    var scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_arena.deinit();

    var used: usize = 0;
    for (spectra, 0..) |spectrum, spectrum_index| {
        if (spectrum.ms_level == level) {
            block_spectra[used] = spectrum;
            order_entries[order_cursor.*] = @intCast(spectrum_index);
            used += 1;
            matched += 1;
            order_cursor.* += 1;

            if (used == block_capacity) {
                try flushBlock(file_bytes, allocator, &scratch_arena, block_spectra[0..used], options, block_count);
                used = 0;
            }
        }
    }

    if (used != 0) {
        try flushBlock(file_bytes, allocator, &scratch_arena, block_spectra[0..used], options, block_count);
    }

    return matched;
}

pub fn encodeFileAlloc(io: std.Io, allocator: Allocator, spectra: []const binary_reader.RawSpectrum, options: EncodeOptions) ![]u8 {
    if (options.block_size == 0) return error.InvalidBlockSize;
    if (spectra.len > std.math.maxInt(u32)) return error.TooManySpectra;

    const t0 = monotonicNs(io);

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
    const order_len = try globalOrderTableLen(@intCast(spectra.len));
    const header_and_order = try std.math.add(usize, header_len, order_len);
    try file_bytes.appendNTimes(allocator, 0, header_and_order);
    const order_entries = try allocator.alloc(u32, spectra.len);
    defer allocator.free(order_entries);

    var flags: u32 = 0;
    if (options.block_options.mode == .lossless) flags |= flag_lossless;
    if (ms1_count != 0) flags |= flag_contains_ms1;
    if (ms2_count != 0) flags |= flag_contains_ms2;
    flags |= flag_has_global_order;

    const t1 = monotonicNs(io);

    var block_count: u32 = 0;
    var order_cursor: usize = 0;
    _ = try appendFilteredStreamBlocks(&file_bytes, allocator, spectra, 1, options, order_entries, &order_cursor, &block_count);
    const t2 = monotonicNs(io);
    _ = try appendFilteredStreamBlocks(&file_bytes, allocator, spectra, 2, options, order_entries, &order_cursor, &block_count);
    const t3 = monotonicNs(io);

    if (order_cursor != spectra.len) return error.InvalidOrderTable;

    const order_bytes = file_bytes.items[header_len .. header_len + order_len];
    for (order_entries, 0..) |entry, entry_index| try writeOrderEntry(order_bytes, entry_index, entry);

    const header: FileHeader = .{
        .magic_bytes = magic,
        .version_major = version_major,
        .version_minor = writeVersionMinor(options),
        .flags = flags,
        .block_size = options.block_size,
        .reserved0 = 0,
        .spectrum_count = @intCast(spectra.len),
        .block_count = block_count,
        .total_peaks = try totalPeaks(spectra),
    };
    writeHeaderInto(file_bytes.items[0..header_len], header);
    const result = try file_bytes.toOwnedSlice(allocator);

    if (options.verbose_timing) {
        const t4 = monotonicNs(io);
        const total_ns = t4 - t0;
        const setup_ns = t1 - t0;
        const ms1_ns = t2 - t1;
        const ms2_ns = t3 - t2;
        const finalize_ns = t4 - t3;
        std.debug.print(
            "[encode timing] setup={d:.2}ms  ms1_blocks={d:.2}ms  ms2_blocks={d:.2}ms  finalize={d:.2}ms  total={d:.2}ms\n" ++
                "[encode timing] setup={d:.1}%  ms1_blocks={d:.1}%  ms2_blocks={d:.1}%  finalize={d:.1}%\n",
            .{
                nsToMs(setup_ns),          nsToMs(ms1_ns),          nsToMs(ms2_ns),          nsToMs(finalize_ns),          nsToMs(total_ns),
                nsPct(setup_ns, total_ns), nsPct(ms1_ns, total_ns), nsPct(ms2_ns, total_ns), nsPct(finalize_ns, total_ns),
            },
        );
    }

    return result;
}

pub fn inspectAlloc(allocator: Allocator, bytes: []const u8) !Inspection {
    const header = try parseHeader(bytes);
    const blocks = try allocator.alloc(BlockInfo, header.block_count);
    errdefer allocator.free(blocks);

    const initial_offset = try blocksOffset(header, bytes);
    var offset = initial_offset;
    var ms1_block_count: usize = 0;
    var ms2_block_count: usize = 0;
    var ms1_spectra: usize = 0;
    var ms2_spectra: usize = 0;
    var byte_breakdown = try emptyFileByteBreakdown(initial_offset - header_len);

    for (blocks) |*block_info| {
        if (bytes.len - offset < block.header_len) return error.UnexpectedEndOfStream;
        const block_header = try block.parseHeader(bytes[offset .. offset + block.header_len]);
        const total_bytes = try std.math.add(usize, block.header_len, block_header.payload_bytes);
        if (bytes.len - offset < total_bytes) return error.UnexpectedEndOfStream;
        const block_breakdown = try block.inspectBlockByteBreakdown(bytes[offset .. offset + total_bytes]);

        block_info.* = .{
            .offset = offset,
            .total_bytes = total_bytes,
            .header = block_header,
            .byte_breakdown = block_breakdown,
        };
        try addBlockBytes(&byte_breakdown, block_breakdown);

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

        offset = try std.math.add(usize, offset, total_bytes);
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

pub fn decodeFileAlloc(io: std.Io, allocator: Allocator, bytes: []const u8, options: DecodeOptions) ![]binary_reader.RawSpectrum {
    const t0 = monotonicNs(io);

    const inspection = try inspectAlloc(allocator, bytes);
    defer freeInspection(allocator, inspection);

    const global_order = if ((inspection.header.flags & flag_has_global_order) != 0)
        try readValidatedGlobalOrderAlloc(allocator, inspection.header, bytes)
    else
        null;
    defer if (global_order) |order| allocator.free(order);

    const t1 = monotonicNs(io);

    const spectra = try allocator.alloc(binary_reader.RawSpectrum, inspection.header.spectrum_count);
    var initialized: usize = 0;
    var spectra_owned = true;
    errdefer {
        if (spectra_owned) {
            for (spectra[0..initialized]) |spectrum| {
                allocator.free(spectrum.mz);
                allocator.free(spectrum.intensity);
            }
            allocator.free(spectra);
        }
    }

    var spectrum_offset: usize = 0;
    var decode_scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer decode_scratch_arena.deinit();
    for (inspection.blocks) |block_info| {
        const decoded = try block.decodeBlockWithScratch(
            allocator,
            decode_scratch_arena.allocator(),
            bytes[block_info.offset .. block_info.offset + block_info.total_bytes],
            inspection.header.version_minor,
        );
        _ = decode_scratch_arena.reset(.retain_capacity);

        const next = try std.math.add(usize, spectrum_offset, decoded.len);
        if (next > spectra.len) {
            for (decoded) |spectrum| {
                allocator.free(spectrum.mz);
                allocator.free(spectrum.intensity);
            }
            allocator.free(decoded);
            return error.SpectrumCountMismatch;
        }
        @memcpy(spectra[spectrum_offset..next], decoded);
        spectrum_offset = next;
        initialized = spectrum_offset;
        allocator.free(decoded);
    }
    if (spectrum_offset != spectra.len) return error.SpectrumCountMismatch;

    const t2 = monotonicNs(io);

    if (global_order == null) {
        if (options.verbose_timing) {
            const total_ns = t2 - t0;
            const setup_ns = t1 - t0;
            const blocks_ns = t2 - t1;
            std.debug.print(
                "[decode timing] setup={d:.2}ms  block_loop={d:.2}ms  reorder=0.00ms  total={d:.2}ms\n" ++
                    "[decode timing] setup={d:.1}%  block_loop={d:.1}%  reorder=0.0%\n",
                .{
                    nsToMs(setup_ns),          nsToMs(blocks_ns),          nsToMs(total_ns),
                    nsPct(setup_ns, total_ns), nsPct(blocks_ns, total_ns),
                },
            );
        }
        spectra_owned = false;
        return spectra;
    }

    const reordered = try allocator.alloc(binary_reader.RawSpectrum, spectra.len);
    for (global_order.?, 0..) |original_index, file_index| {
        reordered[original_index] = spectra[file_index];
    }
    spectra_owned = false;
    allocator.free(spectra);

    if (options.verbose_timing) {
        const t3 = monotonicNs(io);
        const total_ns = t3 - t0;
        const setup_ns = t1 - t0;
        const blocks_ns = t2 - t1;
        const reorder_ns = t3 - t2;
        std.debug.print(
            "[decode timing] setup={d:.2}ms  block_loop={d:.2}ms  reorder={d:.2}ms  total={d:.2}ms\n" ++
                "[decode timing] setup={d:.1}%  block_loop={d:.1}%  reorder={d:.1}%\n",
            .{
                nsToMs(setup_ns),          nsToMs(blocks_ns),          nsToMs(reorder_ns),          nsToMs(total_ns),
                nsPct(setup_ns, total_ns), nsPct(blocks_ns, total_ns), nsPct(reorder_ns, total_ns),
            },
        );
    }

    return reordered;
}

pub fn readFileAlloc(io: std.Io, path: []const u8, allocator: Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(std.math.maxInt(usize)));
}

pub fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

const ArchiveBlock = struct {
    offset: u64,
    total_bytes: u64,
};

const ArchiveFileIndex = struct {
    header: FileHeader,
    order: []u32,
    blocks: []ArchiveBlock,
    record_offsets: []u64,
    output_bytes: u64,

    fn deinit(self: ArchiveFileIndex, allocator: Allocator) void {
        allocator.free(self.order);
        allocator.free(self.blocks);
        allocator.free(self.record_offsets);
    }
};

fn readExactAt(file: std.Io.File, io: std.Io, bytes: []u8, offset: u64) !void {
    if (try file.readPositionalAll(io, bytes, offset) != bytes.len) return error.UnexpectedEndOfStream;
}

fn addU64(a: u64, b: u64) !u64 {
    return std.math.add(u64, a, b);
}

fn streamBlockCount(spectrum_count: usize, block_size: usize) !usize {
    if (spectrum_count == 0) return 0;
    return (try std.math.add(usize, spectrum_count, block_size - 1)) / block_size;
}

fn writeOrderPrefix(prefix: []u8, entries: []const binary_reader.DumpEntry) !void {
    var cursor: usize = header_len;
    inline for (.{ @as(u8, 1), @as(u8, 2) }) |level| {
        for (entries, 0..) |entry, original_index| {
            if (entry.ms_level != level) continue;
            try writeOrderEntry(prefix[header_len..], (cursor - header_len) / @sizeOf(u32), @intCast(original_index));
            cursor = try std.math.add(usize, cursor, @sizeOf(u32));
        }
    }
    if (cursor != prefix.len) return error.InvalidOrderTable;
}

fn encodeBlockToFile(
    io: std.Io,
    output: std.Io.File,
    arena: *std.heap.ArenaAllocator,
    spectra: []const binary_reader.RawSpectrum,
    options: EncodeOptions,
    block_index: u32,
    file_offset: *u64,
) !void {
    var block_options = options.block_options;
    if (block_options.file_version_minor == null) block_options.file_version_minor = writeVersionMinor(options);
    const encoded = try block.encodeBlockDetailed(arena.allocator(), arena.allocator(), spectra, block_options);
    maybePrintBlockStats(block_index, encoded.stats, options);
    try output.writePositionalAll(io, encoded.bytes, file_offset.*);
    file_offset.* = try addU64(file_offset.*, encoded.bytes.len);
}

fn encodeLevelToFile(
    allocator: Allocator,
    io: std.Io,
    input: std.Io.File,
    output: std.Io.File,
    index: binary_reader.DumpIndex,
    level: u8,
    options: EncodeOptions,
    first_block_index: u32,
    file_offset: *u64,
) !u32 {
    const block_capacity: usize = options.block_size;
    const block_spectra = try allocator.alloc(binary_reader.RawSpectrum, block_capacity);
    defer allocator.free(block_spectra);

    var block_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer block_arena.deinit();

    var block_count: u32 = 0;
    var used: usize = 0;
    for (index.entries) |entry| {
        if (entry.ms_level != level) continue;
        block_spectra[used] = try binary_reader.readSpectrumAt(block_arena.allocator(), io, input, entry);
        used += 1;
        if (used != block_capacity) continue;

        try encodeBlockToFile(io, output, &block_arena, block_spectra[0..used], options, try std.math.add(u32, first_block_index, block_count), file_offset);
        block_count = try std.math.add(u32, block_count, 1);
        used = 0;
        _ = block_arena.reset(.retain_capacity);
    }

    if (used != 0) {
        try encodeBlockToFile(io, output, &block_arena, block_spectra[0..used], options, try std.math.add(u32, first_block_index, block_count), file_offset);
        block_count = try std.math.add(u32, block_count, 1);
    }
    return block_count;
}

pub fn encodeDumpFile(io: std.Io, allocator: Allocator, input_path: []const u8, output_path: []const u8, options: EncodeOptions) !void {
    if (options.block_size == 0) return error.InvalidBlockSize;
    const t0 = monotonicNs(io);
    const cwd = std.Io.Dir.cwd();
    const input = try cwd.openFile(io, input_path, .{});
    defer input.close(io);

    const index = try binary_reader.scanFile(allocator, io, input);
    defer index.deinit(allocator);
    const block_size: usize = options.block_size;
    const expected_blocks = try std.math.add(
        usize,
        try streamBlockCount(index.ms1_count, block_size),
        try streamBlockCount(index.ms2_count, block_size),
    );
    if (expected_blocks > std.math.maxInt(u32)) return error.TooManyBlocks;

    const order_len = try globalOrderTableLen(@intCast(index.entries.len));
    const prefix_len = try std.math.add(usize, header_len, order_len);
    const prefix = try allocator.alloc(u8, prefix_len);
    defer allocator.free(prefix);

    var flags: u32 = flag_has_global_order;
    if (options.block_options.mode == .lossless) flags |= flag_lossless;
    if (index.ms1_count != 0) flags |= flag_contains_ms1;
    if (index.ms2_count != 0) flags |= flag_contains_ms2;
    writeHeaderInto(prefix[0..header_len], .{
        .magic_bytes = magic,
        .version_major = version_major,
        .version_minor = writeVersionMinor(options),
        .flags = flags,
        .block_size = options.block_size,
        .reserved0 = 0,
        .spectrum_count = @intCast(index.entries.len),
        .block_count = @intCast(expected_blocks),
        .total_peaks = index.total_peaks,
    });
    try writeOrderPrefix(prefix, index.entries);

    var atomic = try cwd.createFileAtomic(io, output_path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, prefix, 0);
    const t1 = monotonicNs(io);

    var file_offset: u64 = prefix.len;
    const ms1_blocks = try encodeLevelToFile(allocator, io, input, atomic.file, index, 1, options, 0, &file_offset);
    const t2 = monotonicNs(io);
    const ms2_blocks = try encodeLevelToFile(allocator, io, input, atomic.file, index, 2, options, ms1_blocks, &file_offset);
    const t3 = monotonicNs(io);
    const actual_blocks = try std.math.add(u32, ms1_blocks, ms2_blocks);
    if (actual_blocks != expected_blocks) return error.BlockCountMismatch;
    try atomic.replace(io);

    if (options.verbose_timing) {
        const t4 = monotonicNs(io);
        const total_ns = t4 - t0;
        const setup_ns = t1 - t0;
        const ms1_ns = t2 - t1;
        const ms2_ns = t3 - t2;
        const finalize_ns = t4 - t3;
        std.debug.print(
            "[encode timing] setup={d:.2}ms  ms1_blocks={d:.2}ms  ms2_blocks={d:.2}ms  finalize={d:.2}ms  total={d:.2}ms\n" ++
                "[encode timing] setup={d:.1}%  ms1_blocks={d:.1}%  ms2_blocks={d:.1}%  finalize={d:.1}%\n",
            .{
                nsToMs(setup_ns),          nsToMs(ms1_ns),          nsToMs(ms2_ns),          nsToMs(finalize_ns),          nsToMs(total_ns),
                nsPct(setup_ns, total_ns), nsPct(ms1_ns, total_ns), nsPct(ms2_ns, total_ns), nsPct(finalize_ns, total_ns),
            },
        );
    }
}

fn skipMetadataSection(bytes: []const u8, offset: *usize, compressed: bool, spectrum_count: u16) !void {
    if (!compressed) {
        const section_len = try std.math.mul(usize, spectrum_count, @sizeOf(u32));
        if (bytes.len - offset.* < section_len) return error.UnexpectedEndOfStream;
        offset.* += section_len;
        return;
    }
    if (bytes.len - offset.* < 13) return error.UnexpectedEndOfStream;
    const packed_len = readIntLe(u32, bytes[offset.* + 9 .. offset.* + 13]);
    const section_len = try std.math.add(usize, 13, packed_len);
    if (bytes.len - offset.* < section_len) return error.UnexpectedEndOfStream;
    offset.* += section_len;
}

fn appendBlockPeakCounts(
    allocator: Allocator,
    counts: *std.ArrayList(u32),
    block_bytes: []const u8,
    block_header: block.BlockHeader,
) !void {
    const payload = block_bytes[block.header_len..];
    var offset: usize = 0;
    try skipMetadataSection(payload, &offset, (block_header.flags & block.flag_delta_scan_id) != 0, block_header.spectrum_count);
    try skipMetadataSection(payload, &offset, (block_header.flags & block.flag_delta_rt) != 0, block_header.spectrum_count);
    const precursor_len = try std.math.mul(usize, block_header.spectrum_count, @sizeOf(f64));
    if (payload.len - offset < precursor_len) return error.UnexpectedEndOfStream;
    offset += precursor_len;
    const count_len = try std.math.mul(usize, block_header.spectrum_count, @sizeOf(u32));
    if (payload.len - offset < count_len) return error.UnexpectedEndOfStream;
    try counts.ensureUnusedCapacity(allocator, block_header.spectrum_count);
    for (0..block_header.spectrum_count) |idx| {
        counts.appendAssumeCapacity(readIntLe(u32, payload[offset + idx * @sizeOf(u32) ..][0..@sizeOf(u32)]));
    }
}

fn readArchiveOrder(
    allocator: Allocator,
    io: std.Io,
    input: std.Io.File,
    header: FileHeader,
    order_len: usize,
) ![]u32 {
    const order = try allocator.alloc(u32, header.spectrum_count);
    errdefer allocator.free(order);
    if ((header.flags & flag_has_global_order) == 0) {
        for (order, 0..) |*entry, idx| entry.* = @intCast(idx);
        return order;
    }

    const raw = try allocator.alloc(u8, order_len);
    defer allocator.free(raw);
    try readExactAt(input, io, raw, header_len);
    const seen = try allocator.alloc(bool, header.spectrum_count);
    defer allocator.free(seen);
    @memset(seen, false);
    for (order, 0..) |*entry, file_index| {
        const original_index = readIntLe(u32, raw[file_index * @sizeOf(u32) ..][0..@sizeOf(u32)]);
        if (original_index >= order.len or seen[original_index]) return error.InvalidOrderTable;
        seen[original_index] = true;
        entry.* = original_index;
    }
    return order;
}

fn scanArchiveFile(allocator: Allocator, io: std.Io, input: std.Io.File) !ArchiveFileIndex {
    const file_size = (try input.stat(io)).size;
    var header_bytes: [header_len]u8 = undefined;
    try readExactAt(input, io, &header_bytes, 0);
    const header = try parseHeader(&header_bytes);

    const order_len = if ((header.flags & flag_has_global_order) != 0)
        try globalOrderTableLen(header.spectrum_count)
    else
        0;
    var offset = try addU64(header_len, order_len);
    if (offset > file_size) return error.UnexpectedEndOfStream;

    var blocks: std.ArrayList(ArchiveBlock) = .empty;
    errdefer blocks.deinit(allocator);
    var peak_counts: std.ArrayList(u32) = .empty;
    defer peak_counts.deinit(allocator);
    var scan_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scan_arena.deinit();

    for (0..header.block_count) |_| {
        if (offset > file_size or file_size - offset < block.header_len) return error.UnexpectedEndOfStream;
        var block_header_bytes: [block.header_len]u8 = undefined;
        try readExactAt(input, io, &block_header_bytes, offset);
        const block_header = try block.parseHeader(&block_header_bytes);
        const total_bytes = try addU64(block.header_len, block_header.payload_bytes);
        if (total_bytes > file_size - offset) return error.UnexpectedEndOfStream;
        if (total_bytes > std.math.maxInt(usize)) return error.Overflow;

        const bytes = try scan_arena.allocator().alloc(u8, @intCast(total_bytes));
        try readExactAt(input, io, bytes, offset);
        _ = try block.inspectBlockByteBreakdown(bytes);
        switch (block_header.ms_level) {
            1, 2 => {},
            else => return error.UnsupportedMsLevel,
        }
        try appendBlockPeakCounts(allocator, &peak_counts, bytes, block_header);
        try blocks.append(allocator, .{ .offset = offset, .total_bytes = total_bytes });
        offset = try addU64(offset, total_bytes);
        _ = scan_arena.reset(.retain_capacity);
    }
    if (offset != file_size) return error.TrailingFileData;

    if ((header.flags & flag_has_global_order) == 0 and peak_counts.items.len != header.spectrum_count) {
        return error.SpectrumCountMismatch;
    }
    const order = try readArchiveOrder(allocator, io, input, header, order_len);
    errdefer allocator.free(order);
    if (peak_counts.items.len != order.len) return error.SpectrumCountMismatch;

    const record_offsets = try allocator.alloc(u64, order.len);
    errdefer allocator.free(record_offsets);
    for (peak_counts.items, 0..) |peak_count, file_index| {
        record_offsets[order[file_index]] = try binary_reader.recordLen(peak_count);
    }
    var output_bytes: u64 = 0;
    for (record_offsets) |*record_offset| {
        const record_len = record_offset.*;
        record_offset.* = output_bytes;
        output_bytes = try addU64(output_bytes, record_len);
    }
    return .{
        .header = header,
        .order = order,
        .blocks = try blocks.toOwnedSlice(allocator),
        .record_offsets = record_offsets,
        .output_bytes = output_bytes,
    };
}

pub fn decodeToDumpFile(io: std.Io, allocator: Allocator, input_path: []const u8, output_path: []const u8, options: DecodeOptions) !void {
    const t0 = monotonicNs(io);
    const cwd = std.Io.Dir.cwd();
    const input = try cwd.openFile(io, input_path, .{});
    defer input.close(io);
    const index = try scanArchiveFile(allocator, io, input);
    defer index.deinit(allocator);

    var atomic = try cwd.createFileAtomic(io, output_path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.setLength(io, index.output_bytes);
    const t1 = monotonicNs(io);

    var block_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer block_arena.deinit();
    var file_index: usize = 0;
    for (index.blocks) |entry| {
        if (entry.total_bytes > std.math.maxInt(usize)) return error.Overflow;
        const block_bytes = try block_arena.allocator().alloc(u8, @intCast(entry.total_bytes));
        try readExactAt(input, io, block_bytes, entry.offset);
        const decoded = try block.decodeBlockWithScratch(block_arena.allocator(), block_arena.allocator(), block_bytes, index.header.version_minor);
        for (decoded) |spectrum| {
            if (file_index >= index.order.len) return error.SpectrumCountMismatch;
            try binary_reader.writeSpectrumAt(block_arena.allocator(), io, atomic.file, spectrum, index.record_offsets[index.order[file_index]]);
            file_index += 1;
        }
        _ = block_arena.reset(.retain_capacity);
    }
    if (file_index != index.order.len) return error.SpectrumCountMismatch;
    const t2 = monotonicNs(io);
    try atomic.replace(io);

    if (options.verbose_timing) {
        const t3 = monotonicNs(io);
        const total_ns = t3 - t0;
        const setup_ns = t1 - t0;
        const blocks_ns = t2 - t1;
        const finalize_ns = t3 - t2;
        std.debug.print(
            "[decode timing] setup={d:.2}ms  block_loop={d:.2}ms  reorder={d:.2}ms  total={d:.2}ms\n" ++
                "[decode timing] setup={d:.1}%  block_loop={d:.1}%  reorder={d:.1}%\n",
            .{
                nsToMs(setup_ns),          nsToMs(blocks_ns),          nsToMs(finalize_ns),          nsToMs(total_ns),
                nsPct(setup_ns, total_ns), nsPct(blocks_ns, total_ns), nsPct(finalize_ns, total_ns),
            },
        );
    }
}

pub fn inspectFileAlloc(io: std.Io, allocator: Allocator, path: []const u8) !Inspection {
    const bytes = try readFileAlloc(io, path, allocator);
    defer allocator.free(bytes);
    return inspectAlloc(allocator, bytes);
}
