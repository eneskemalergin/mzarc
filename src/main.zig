const std = @import("std");
const binary_reader = @import("binary_reader");
const codec_v1 = @import("codec_v1");

/// Write `bytes` to stdout (fd 1) using the raw Linux syscall.
/// Errors are silently ignored — if stdout is closed, there is nothing useful
/// we can do from a CLI tool perspective.
fn writeStdout(bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const written = std.os.linux.write(1, remaining.ptr, remaining.len);
        if (@as(isize, @bitCast(written)) <= 0) break;
        remaining = remaining[@intCast(written)..];
    }
}

/// Print a formatted string to stdout.  `buf` is a scratch buffer for
/// formatting; pass a stack-allocated array like `var buf: [512]u8 = undefined`.
fn printStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch {
        // Message too long for stack buffer — fall back to a heap allocation on
        // the arena backing the process.  This should be rare.
        return;
    };
    writeStdout(s);
}

fn printUsage() void {
    std.debug.print(
        "Usage:\n" ++
            "  mzarc dump-inspect <input.bin>\n" ++
            "  mzarc encode-v1 <input.bin> -o <output.mzv1> [--lossy] [--intensity-quant <levels>]\n" ++
            "  mzarc decode-v1 <input.mzv1> -o <output.bin>\n" ++
            "  mzarc inspect-v1 <input.mzv1> [--json] [--blocks]\n",
        .{},
    );
}

fn commandDumpInspect(allocator: std.mem.Allocator, path: []const u8) !void {
    const spectra = try binary_reader.readBinaryDump(path, allocator);
    defer binary_reader.freeSpectra(allocator, spectra);

    var total_peaks: u64 = 0;
    var ms1_count: u64 = 0;
    var ms2_count: u64 = 0;
    for (spectra) |spectrum| {
        total_peaks += spectrum.mz.len;
        switch (spectrum.ms_level) {
            1 => ms1_count += 1,
            2 => ms2_count += 1,
            else => {},
        }
    }

    std.debug.print("file: {s}\n", .{path});
    std.debug.print("spectra: {}\n", .{spectra.len});
    std.debug.print("total peaks: {}\n", .{total_peaks});
    std.debug.print("ms1 count: {}\n", .{ms1_count});
    std.debug.print("ms2 count: {}\n", .{ms2_count});
}

fn parseOutputPath(args: []const [:0]const u8) ![]const u8 {
    if (args.len < 2) return error.InvalidArguments;

    for (0..args.len - 1) |idx| {
        if (std.mem.eql(u8, args[idx], "-o") or std.mem.eql(u8, args[idx], "--output")) {
            return args[idx + 1];
        }
    }

    return error.InvalidArguments;
}

fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

fn parseOptionalU16(args: []const [:0]const u8, flag: []const u8) !?u16 {
    if (args.len < 2) return null;

    for (0..args.len - 1) |idx| {
        if (std.mem.eql(u8, args[idx], flag)) {
            return try std.fmt.parseInt(u16, args[idx + 1], 10);
        }
    }

    return null;
}

fn commandEncodeV1(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 4) return error.InvalidArguments;

    const input_path = args[2];
    const output_path = try parseOutputPath(args[3..]);
    const intensity_quant = try parseOptionalU16(args[3..], "--intensity-quant");

    try codec_v1.encodeDumpFile(allocator, input_path, output_path, .{
        .block_options = .{
            .mode = if (hasFlag(args[3..], "--lossy")) .lossy else .lossless,
            .intensity_quant = intensity_quant orelse 16384,
        },
    });

    std.debug.print("encoded: {s} -> {s}\n", .{ input_path, output_path });
}

fn commandDecodeV1(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 4) return error.InvalidArguments;

    const input_path = args[2];
    const output_path = try parseOutputPath(args[3..]);

    try codec_v1.decodeToDumpFile(allocator, input_path, output_path);
    std.debug.print("decoded: {s} -> {s}\n", .{ input_path, output_path });
}

fn printInspectionJson(allocator: std.mem.Allocator, path: []const u8, inspection: codec_v1.Inspection) !void {
    const bytes = inspection.byte_breakdown;
    const json_str = try std.fmt.allocPrint(
        allocator,
        "{{\n" ++
            "  \"file\": \"{s}\",\n" ++
            "  \"version_major\": {},\n" ++
            "  \"version_minor\": {},\n" ++
            "  \"spectrum_count\": {},\n" ++
            "  \"block_count\": {},\n" ++
            "  \"total_peaks\": {},\n" ++
            "  \"block_size\": {},\n" ++
            "  \"ms1_block_count\": {},\n" ++
            "  \"ms2_block_count\": {},\n" ++
            "  \"ms1_spectra\": {},\n" ++
            "  \"ms2_spectra\": {},\n" ++
            "  \"byte_breakdown\": {{\n" ++
            "    \"file_header_bytes\": {},\n" ++
            "    \"global_order_bytes\": {},\n" ++
            "    \"block_header_bytes\": {},\n" ++
            "    \"scan_id_bytes\": {},\n" ++
            "    \"rt_bytes\": {},\n" ++
            "    \"precursor_bytes\": {},\n" ++
            "    \"peak_count_bytes\": {},\n" ++
            "    \"mz_metadata_bytes\": {},\n" ++
            "    \"mz_payload_bytes\": {},\n" ++
            "    \"intensity_metadata_bytes\": {},\n" ++
            "    \"intensity_payload_bytes\": {},\n" ++
            "    \"total_bytes\": {}\n" ++
            "  }}\n" ++
            "}}\n",
        .{
            path,
            inspection.header.version_major,
            inspection.header.version_minor,
            inspection.header.spectrum_count,
            inspection.header.block_count,
            inspection.header.total_peaks,
            inspection.header.block_size,
            inspection.ms1_block_count,
            inspection.ms2_block_count,
            inspection.ms1_spectra,
            inspection.ms2_spectra,
            bytes.file_header_bytes,
            bytes.global_order_bytes,
            bytes.block_header_bytes,
            bytes.scan_id_bytes,
            bytes.rt_bytes,
            bytes.precursor_bytes,
            bytes.peak_count_bytes,
            bytes.mz_metadata_bytes,
            bytes.mz_payload_bytes,
            bytes.intensity_metadata_bytes,
            bytes.intensity_payload_bytes,
            bytes.total_bytes,
        },
    );
    defer allocator.free(json_str);
    writeStdout(json_str);
}

fn printBlockTable(inspection: codec_v1.Inspection) void {
    std.debug.print("{s:>6}  {s:>5}  {s:>6}  {s:>8}  {s:>6}  {s:>9}  {s:>9}  {s:>9}\n", .{
        "idx", "level", "nspec", "npeaks", "mz_bw", "int_bw", "mz_bytes", "int_bytes",
    });
    for (inspection.blocks, 0..) |block_info, idx| {
        const h = block_info.header;
        const b = block_info.byte_breakdown;
        std.debug.print("{:>6}  {:>5}  {:>6}  {:>8}  {:>6}  {:>9}  {:>9}  {:>9}\n", .{
            idx,
            h.ms_level,
            h.spectrum_count,
            h.total_peaks,
            h.mz_bit_width,
            h.intensity_bit_width,
            b.mz_payload_bytes,
            b.intensity_payload_bytes,
        });
    }
}

fn commandInspectV1(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 3) return error.InvalidArguments;

    var path: ?[]const u8 = null;
    var json_output = false;
    var show_blocks = false;
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--blocks")) {
            show_blocks = true;
        } else if (path == null) {
            path = arg;
        } else {
            return error.InvalidArguments;
        }
    }
    if (path == null) return error.InvalidArguments;
    const input_path = path.?;

    const inspection = try codec_v1.inspectFileAlloc(allocator, input_path);
    defer codec_v1.freeInspection(allocator, inspection);

    if (json_output) {
        try printInspectionJson(allocator, input_path, inspection);
        return;
    }

    std.debug.print("file: {s}\n", .{input_path});
    std.debug.print("version: {}.{}\n", .{ inspection.header.version_major, inspection.header.version_minor });
    std.debug.print("spectra: {}\n", .{inspection.header.spectrum_count});
    std.debug.print("blocks: {}\n", .{inspection.header.block_count});
    std.debug.print("total peaks: {}\n", .{inspection.header.total_peaks});
    std.debug.print("block size: {}\n", .{inspection.header.block_size});
    std.debug.print("ms1 blocks: {}\n", .{inspection.ms1_block_count});
    std.debug.print("ms2 blocks: {}\n", .{inspection.ms2_block_count});
    std.debug.print("ms1 spectra: {}\n", .{inspection.ms1_spectra});
    std.debug.print("ms2 spectra: {}\n", .{inspection.ms2_spectra});
    std.debug.print("file header bytes: {}\n", .{inspection.byte_breakdown.file_header_bytes});
    std.debug.print("global order bytes: {}\n", .{inspection.byte_breakdown.global_order_bytes});
    std.debug.print("block header bytes: {}\n", .{inspection.byte_breakdown.block_header_bytes});
    std.debug.print("scan id bytes: {}\n", .{inspection.byte_breakdown.scan_id_bytes});
    std.debug.print("rt bytes: {}\n", .{inspection.byte_breakdown.rt_bytes});
    std.debug.print("precursor bytes: {}\n", .{inspection.byte_breakdown.precursor_bytes});
    std.debug.print("peak count bytes: {}\n", .{inspection.byte_breakdown.peak_count_bytes});
    std.debug.print("mz metadata bytes: {}\n", .{inspection.byte_breakdown.mz_metadata_bytes});
    std.debug.print("mz payload bytes: {}\n", .{inspection.byte_breakdown.mz_payload_bytes});
    std.debug.print("intensity metadata bytes: {}\n", .{inspection.byte_breakdown.intensity_metadata_bytes});
    std.debug.print("intensity payload bytes: {}\n", .{inspection.byte_breakdown.intensity_payload_bytes});
    std.debug.print("total bytes: {}\n", .{inspection.byte_breakdown.total_bytes});

    if (show_blocks) {
        std.debug.print("\n", .{});
        printBlockTable(inspection);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, args[1], "dump-inspect")) {
        if (args.len != 3) {
            printUsage();
            return error.InvalidArguments;
        }
        try commandDumpInspect(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, args[1], "encode-v1")) {
        try commandEncodeV1(allocator, args);
        return;
    }

    if (std.mem.eql(u8, args[1], "decode-v1")) {
        try commandDecodeV1(allocator, args);
        return;
    }

    if (std.mem.eql(u8, args[1], "inspect-v1")) {
        try commandInspectV1(allocator, args);
        return;
    }

    printUsage();
    return error.InvalidArguments;
}
