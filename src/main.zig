const std = @import("std");
const binary_reader = @import("binary_reader");
const codec_v1 = @import("codec_v1");

fn printUsage() void {
    std.debug.print(
        "Usage:\n" ++
            "  mzarc dump-inspect <input.bin>\n" ++
            "  mzarc encode-v1 <input.bin> -o <output.mzv1> [--lossy] [--intensity-quant <levels>]\n" ++
            "  mzarc decode-v1 <input.mzv1> -o <output.bin>\n" ++
            "  mzarc inspect-v1 <input.mzv1>\n",
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
            .intensity_quant = intensity_quant orelse 4096,
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

fn commandInspectV1(allocator: std.mem.Allocator, path: []const u8) !void {
    const inspection = try codec_v1.inspectFileAlloc(allocator, path);
    defer codec_v1.freeInspection(allocator, inspection);

    std.debug.print("file: {s}\n", .{path});
    std.debug.print("version: {}.{}\n", .{ inspection.header.version_major, inspection.header.version_minor });
    std.debug.print("spectra: {}\n", .{inspection.header.spectrum_count});
    std.debug.print("blocks: {}\n", .{inspection.header.block_count});
    std.debug.print("total peaks: {}\n", .{inspection.header.total_peaks});
    std.debug.print("block size: {}\n", .{inspection.header.block_size});
    std.debug.print("ms1 blocks: {}\n", .{inspection.ms1_block_count});
    std.debug.print("ms2 blocks: {}\n", .{inspection.ms2_block_count});
    std.debug.print("ms1 spectra: {}\n", .{inspection.ms1_spectra});
    std.debug.print("ms2 spectra: {}\n", .{inspection.ms2_spectra});
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
        if (args.len != 3) {
            printUsage();
            return error.InvalidArguments;
        }
        try commandInspectV1(allocator, args[2]);
        return;
    }

    printUsage();
    return error.InvalidArguments;
}
