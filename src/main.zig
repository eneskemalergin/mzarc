const std = @import("std");
const binary_reader = @import("binary_reader");

fn printUsage() void {
    std.debug.print(
        "Usage:\n" ++
            "  mzarc dump-inspect <input.bin>\n" ++
            "  mzarc encode-v1 <input.bin> -o <output.mzv1>   (not implemented yet)\n" ++
            "  mzarc decode-v1 <input.mzv1> -o <output.bin>   (not implemented yet)\n" ++
            "  mzarc inspect-v1 <input.mzv1>                  (not implemented yet)\n",
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

    if (std.mem.eql(u8, args[1], "encode-v1") or
        std.mem.eql(u8, args[1], "decode-v1") or
        std.mem.eql(u8, args[1], "inspect-v1"))
    {
        std.debug.print("Command not implemented yet.\n", .{});
        return;
    }

    printUsage();
    return error.InvalidArguments;
}
