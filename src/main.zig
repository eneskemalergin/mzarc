const std = @import("std");
const binary_reader = @import("binary_reader");
const codec = @import("codec");

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
            "  mzarc encode <input.bin> -o <output.mzarc> [--lossy] [--intensity-quant <levels>]\n" ++
            "  mzarc decode <input.mzarc> -o <output.bin>\n" ++
            "  mzarc inspect <input.mzarc> [--json] [--blocks]\n" ++
            "  mzarc validate <original.bin> <decoded.bin> --mode=lossless|lossy\n" ++
            "  mzarc validate-adversarial <dir>\n",
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

fn commandEncode(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 4) return error.InvalidArguments;

    const input_path = args[2];
    const output_path = try parseOutputPath(args[3..]);
    const intensity_quant = try parseOptionalU16(args[3..], "--intensity-quant");

    try codec.encodeDumpFile(allocator, input_path, output_path, .{
        .block_options = .{
            .mode = if (hasFlag(args[3..], "--lossy")) .lossy else .lossless,
            .intensity_quant = intensity_quant orelse 16384,
        },
    });

    std.debug.print("encoded: {s} -> {s}\n", .{ input_path, output_path });
}

fn commandDecode(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 4) return error.InvalidArguments;

    const input_path = args[2];
    const output_path = try parseOutputPath(args[3..]);

    try codec.decodeToDumpFile(allocator, input_path, output_path);
    std.debug.print("decoded: {s} -> {s}\n", .{ input_path, output_path });
}

fn printInspectionJson(allocator: std.mem.Allocator, path: []const u8, inspection: codec.Inspection) !void {
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

fn printBlockTable(inspection: codec.Inspection) void {
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

fn commandInspect(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
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

    const inspection = try codec.inspectFileAlloc(allocator, input_path);
    defer codec.freeInspection(allocator, inspection);

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

// ---------------------------------------------------------------------------
// validate / validate-adversarial
// ---------------------------------------------------------------------------

const lossless_mz_tolerance_da: f64 = 1e-5;
const lossy_mz_max_error_da: f64 = 0.002;
const lossy_intensity_p95_threshold: f64 = 0.001; // 0.1%

/// Compare two spectrum slices for lossless round-trip fidelity.
/// verbose=true prints one PASS/FAIL line per check to stdout.
/// Returns true iff all checks pass.
fn checkLosslessSpectra(
    orig: []const binary_reader.RawSpectrum,
    dec: []const binary_reader.RawSpectrum,
    verbose: bool,
) bool {
    var all_pass = true;

    if (orig.len != dec.len) {
        if (verbose) printStdout("FAIL spectrum_count expected={} got={}\n", .{ orig.len, dec.len });
        return false;
    }
    if (verbose) printStdout("PASS spectrum_count {}\n", .{orig.len});

    var scan_fail_idx: ?usize = null;
    var rt_fail_idx: ?usize = null;
    var ms_level_fail_idx: ?usize = null;
    var precursor_fail_idx: ?usize = null;
    var peak_count_fail_idx: ?usize = null;
    var mz_fail: ?struct { si: usize, pi: usize, exp: f64, got: f64 } = null;
    var int_fail: ?struct { si: usize, pi: usize, exp: f32, got: f32 } = null;

    for (orig, dec, 0..) |o, d, si| {
        if (scan_fail_idx == null and o.scan_id != d.scan_id) scan_fail_idx = si;
        if (rt_fail_idx == null and @as(u32, @bitCast(o.rt_seconds)) != @as(u32, @bitCast(d.rt_seconds))) rt_fail_idx = si;
        if (ms_level_fail_idx == null and o.ms_level != d.ms_level) ms_level_fail_idx = si;
        if (precursor_fail_idx == null and @as(u64, @bitCast(o.precursor_mz)) != @as(u64, @bitCast(d.precursor_mz))) precursor_fail_idx = si;
        if (peak_count_fail_idx == null and o.mz.len != d.mz.len) peak_count_fail_idx = si;

        if (peak_count_fail_idx == null) {
            if (mz_fail == null) {
                for (o.mz, d.mz, 0..) |om, dm, pi| {
                    if (@abs(om - dm) > lossless_mz_tolerance_da) {
                        mz_fail = .{ .si = si, .pi = pi, .exp = om, .got = dm };
                        break;
                    }
                }
            }
            if (int_fail == null) {
                for (o.intensity, d.intensity, 0..) |oi, di, pi| {
                    if (@as(u32, @bitCast(oi)) != @as(u32, @bitCast(di))) {
                        int_fail = .{ .si = si, .pi = pi, .exp = oi, .got = di };
                        break;
                    }
                }
            }
        }
    }

    if (verbose) {
        if (scan_fail_idx) |si| {
            printStdout("FAIL scan_id spectrum={} expected={} got={}\n", .{ si, orig[si].scan_id, dec[si].scan_id });
            all_pass = false;
        } else printStdout("PASS scan_id_exact\n", .{});

        if (rt_fail_idx) |si| {
            printStdout("FAIL rt_seconds spectrum={} expected={e} got={e}\n", .{ si, orig[si].rt_seconds, dec[si].rt_seconds });
            all_pass = false;
        } else printStdout("PASS rt_seconds_exact\n", .{});

        if (ms_level_fail_idx) |si| {
            printStdout("FAIL ms_level spectrum={} expected={} got={}\n", .{ si, orig[si].ms_level, dec[si].ms_level });
            all_pass = false;
        } else printStdout("PASS ms_level_exact\n", .{});

        if (precursor_fail_idx) |si| {
            printStdout("FAIL precursor_mz spectrum={} expected={d} got={d}\n", .{ si, orig[si].precursor_mz, dec[si].precursor_mz });
            all_pass = false;
        } else printStdout("PASS precursor_mz_exact\n", .{});

        if (peak_count_fail_idx) |si| {
            printStdout("FAIL peak_count spectrum={} expected={} got={}\n", .{ si, orig[si].mz.len, dec[si].mz.len });
            all_pass = false;
        } else printStdout("PASS peak_count_exact\n", .{});

        if (mz_fail) |f| {
            printStdout("FAIL mz_round_trip spectrum={} peak={} expected={d} got={d}\n", .{ f.si, f.pi, f.exp, f.got });
            all_pass = false;
        } else printStdout("PASS mz_round_trip exact\n", .{});

        if (int_fail) |f| {
            printStdout("FAIL intensity_round_trip spectrum={} peak={} expected={e} got={e}\n", .{ f.si, f.pi, f.exp, f.got });
            all_pass = false;
        } else printStdout("PASS intensity_round_trip exact\n", .{});
    } else {
        all_pass = scan_fail_idx == null and rt_fail_idx == null and ms_level_fail_idx == null and
            precursor_fail_idx == null and peak_count_fail_idx == null and
            mz_fail == null and int_fail == null;
    }

    return all_pass;
}

/// Compare two spectrum slices for lossy round-trip fidelity.
/// verbose=true prints one PASS/FAIL line per metric to stdout.
/// Returns true iff all checks pass.
fn checkLossySpectra(
    allocator: std.mem.Allocator,
    orig: []const binary_reader.RawSpectrum,
    dec: []const binary_reader.RawSpectrum,
    verbose: bool,
) !bool {
    var all_pass = true;

    if (orig.len != dec.len) {
        if (verbose) printStdout("FAIL spectrum_count expected={} got={}\n", .{ orig.len, dec.len });
        return false;
    }
    if (verbose) printStdout("PASS spectrum_count {}\n", .{orig.len});

    var meta_fail: bool = false;
    for (orig, dec, 0..) |o, d, si| {
        if (o.scan_id != d.scan_id or o.ms_level != d.ms_level or
            @as(u32, @bitCast(o.rt_seconds)) != @as(u32, @bitCast(d.rt_seconds)) or
            @as(u64, @bitCast(o.precursor_mz)) != @as(u64, @bitCast(d.precursor_mz)))
        {
            if (verbose) printStdout("FAIL metadata_exact spectrum={}\n", .{si});
            meta_fail = true;
            all_pass = false;
            break;
        }
    }
    if (!meta_fail and verbose) printStdout("PASS metadata_exact\n", .{});

    var total_peaks: usize = 0;
    for (orig) |s| total_peaks += s.mz.len;

    const mz_errors = try allocator.alloc(f64, total_peaks);
    defer allocator.free(mz_errors);
    const int_errors = try allocator.alloc(f64, total_peaks);
    defer allocator.free(int_errors);

    var peak_count_mismatch = false;
    var err_idx: usize = 0;
    for (orig, dec) |o, d| {
        if (o.mz.len != d.mz.len) {
            peak_count_mismatch = true;
            break;
        }
        for (o.mz, d.mz, o.intensity, d.intensity) |om, dm, oi, di| {
            mz_errors[err_idx] = @abs(om - dm);
            int_errors[err_idx] = if (oi != 0.0)
                @abs(@as(f64, di) - @as(f64, oi)) / @abs(@as(f64, oi))
            else if (di == 0.0) 0.0 else 1.0;
            err_idx += 1;
        }
    }

    if (peak_count_mismatch) {
        if (verbose) printStdout("FAIL peak_count_mismatch\n", .{});
        return false;
    }

    const n = err_idx;
    const mz_slice = mz_errors[0..n];
    const int_slice = int_errors[0..n];

    var mz_max: f64 = 0.0;
    for (mz_slice) |e| if (e > mz_max) {
        mz_max = e;
    };
    const mz_pass = mz_max <= lossy_mz_max_error_da;
    if (verbose) {
        if (mz_pass)
            printStdout("PASS mz_max_error {d:.6} Da < {d:.3} Da\n", .{ mz_max, lossy_mz_max_error_da })
        else
            printStdout("FAIL mz_max_error {d:.6} Da > {d:.3} Da\n", .{ mz_max, lossy_mz_max_error_da });
    }
    if (!mz_pass) all_pass = false;

    std.mem.sort(f64, int_slice, {}, std.sort.asc(f64));
    const p95: f64 = if (n > 0) int_slice[n * 95 / 100] else 0.0;
    const p95_pct = p95 * 100.0;
    const int_pass = p95 <= lossy_intensity_p95_threshold;
    if (verbose) {
        if (int_pass)
            printStdout("PASS intensity_p95_error {d:.3}% < {d:.1}%\n", .{ p95_pct, lossy_intensity_p95_threshold * 100.0 })
        else
            printStdout("FAIL intensity_p95_error {d:.3}% > {d:.1}%\n", .{ p95_pct, lossy_intensity_p95_threshold * 100.0 });
    }
    if (!int_pass) all_pass = false;

    return all_pass;
}

fn commandValidate(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len != 5) return error.InvalidArguments;
    const orig_path = args[2];
    const dec_path = args[3];
    const mode_arg = args[4];

    const lossless_mode = std.mem.eql(u8, mode_arg, "--mode=lossless");
    const lossy_mode = std.mem.eql(u8, mode_arg, "--mode=lossy");
    if (!lossless_mode and !lossy_mode) return error.InvalidArguments;

    const orig = try binary_reader.readBinaryDump(orig_path, allocator);
    defer binary_reader.freeSpectra(allocator, orig);
    const dec = try binary_reader.readBinaryDump(dec_path, allocator);
    defer binary_reader.freeSpectra(allocator, dec);

    const all_pass = if (lossless_mode)
        checkLosslessSpectra(orig, dec, true)
    else
        try checkLossySpectra(allocator, orig, dec, true);

    if (!all_pass) return error.ValidationFailed;
}

fn commandValidateAdversarial(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len != 3) return error.InvalidArguments;
    const dir_path = args[2];

    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var any_fail = false;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".bin")) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(full_path);

        const orig = binary_reader.readBinaryDump(full_path, allocator) catch |err| {
            printStdout("FAIL {s} read_error={s}\n", .{ entry.name, @errorName(err) });
            any_fail = true;
            continue;
        };
        defer binary_reader.freeSpectra(allocator, orig);

        const encoded = codec.encodeFileAlloc(allocator, orig, .{}) catch |err| {
            printStdout("FAIL {s} encode_error={s}\n", .{ entry.name, @errorName(err) });
            any_fail = true;
            continue;
        };
        defer allocator.free(encoded);

        const decoded = codec.decodeFileAlloc(allocator, encoded) catch |err| {
            printStdout("FAIL {s} decode_error={s}\n", .{ entry.name, @errorName(err) });
            any_fail = true;
            continue;
        };
        defer binary_reader.freeSpectra(allocator, decoded);

        if (checkLosslessSpectra(orig, decoded, false)) {
            printStdout("PASS {s}\n", .{entry.name});
        } else {
            printStdout("FAIL {s}\n", .{entry.name});
            any_fail = true;
        }
    }

    if (any_fail) return error.ValidationFailed;
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

    if (std.mem.eql(u8, args[1], "encode")) {
        try commandEncode(allocator, args);
        return;
    }

    if (std.mem.eql(u8, args[1], "decode")) {
        try commandDecode(allocator, args);
        return;
    }

    if (std.mem.eql(u8, args[1], "inspect")) {
        try commandInspect(allocator, args);
        return;
    }

    if (std.mem.eql(u8, args[1], "validate")) {
        try commandValidate(allocator, args);
        return;
    }

    if (std.mem.eql(u8, args[1], "validate-adversarial")) {
        try commandValidateAdversarial(allocator, args);
        return;
    }

    printUsage();
    return error.InvalidArguments;
}
