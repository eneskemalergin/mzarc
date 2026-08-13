//! CLI: dump-inspect, encode, decode, inspect, validate, benchmark-rans-core.
//! Prefer `init.io` for I/O; exit codes and verb behavior stay stable.

const std = @import("std");
const binary_reader = @import("binary_reader");
const block = @import("block");
const codec = @import("codec");
const rans = @import("rans");

fn writeStdout(io: std.Io, bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch return;
}

fn printStdout(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buf);
    writer.interface.print(fmt, args) catch return;
    writer.interface.flush() catch return;
}

fn printUsage() void {
    std.debug.print(
        "Usage:\n" ++
            "  mzarc dump-inspect <input.bin>\n" ++
            "  mzarc encode <input.bin> -o <output.mzarc> [--lossy] [--intensity-quant <levels>] [--mz-rans-min-gain <pct>] [--intensity-rans-min-gain <pct>] [--verbose-blocks] [--verbose-timing]\n" ++
            "  mzarc decode <input.mzarc> -o <output.bin> [--verbose-timing]\n" ++
            "  mzarc inspect <input.mzarc> [--json] [--blocks]\n" ++
            "  mzarc benchmark-rans-core <input.mzarc> [--repeats <n>]\n" ++
            "  mzarc validate <original.bin> <decoded.bin> --mode=lossless|lossy\n" ++
            "  mzarc validate-adversarial <dir>\n",
        .{},
    );
}

fn commandDumpInspect(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const spectra = try binary_reader.readBinaryDump(io, path, allocator);
    defer binary_reader.freeSpectra(allocator, spectra);

    var total_peaks: u64 = 0;
    var ms1_count: u64 = 0;
    var ms2_count: u64 = 0;
    var zero_intensity: u64 = 0;
    var min_peaks: u64 = if (spectra.len > 0) std.math.maxInt(u64) else 0;
    var max_peaks: u64 = 0;

    const peak_counts = try allocator.alloc(u64, spectra.len);
    defer allocator.free(peak_counts);

    for (spectra, 0..) |spectrum, i| {
        const n: u64 = spectrum.mz.len;
        total_peaks = try std.math.add(u64, total_peaks, n);
        peak_counts[i] = n;
        if (n < min_peaks) min_peaks = n;
        if (n > max_peaks) max_peaks = n;
        switch (spectrum.ms_level) {
            1 => ms1_count += 1,
            2 => ms2_count += 1,
            else => {},
        }
        for (spectrum.intensity) |v| {
            if (v == 0.0) zero_intensity += 1;
        }
    }

    std.mem.sort(u64, peak_counts, {}, std.sort.asc(u64));
    const median_peaks: u64 = if (spectra.len > 0) peak_counts[spectra.len / 2] else 0;

    std.debug.print("file: {s}\n", .{path});
    std.debug.print("spectra: {}\n", .{spectra.len});
    std.debug.print("total peaks: {}\n", .{total_peaks});
    std.debug.print("ms1 count: {}\n", .{ms1_count});
    std.debug.print("ms2 count: {}\n", .{ms2_count});
    std.debug.print("zero intensity peaks: {}\n", .{zero_intensity});
    std.debug.print("min peaks per spectrum: {}\n", .{min_peaks});
    std.debug.print("median peaks per spectrum: {}\n", .{median_peaks});
    std.debug.print("max peaks per spectrum: {}\n", .{max_peaks});
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

fn parseOptionalInt(comptime T: type, args: []const [:0]const u8, flag: []const u8) !?T {
    for (args, 0..) |arg, idx| {
        if (!std.mem.eql(u8, arg, flag)) continue;
        if (idx + 1 >= args.len) return error.InvalidArguments;
        return try std.fmt.parseInt(T, args[idx + 1], 10);
    }
    return null;
}

fn commandEncode(io: std.Io, allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 4) return error.InvalidArguments;

    const input_path = args[2];
    const output_path = try parseOutputPath(args[3..]);
    const intensity_quant = try parseOptionalInt(u16, args[3..], "--intensity-quant");
    const mz_rans_min_gain = try parseOptionalInt(u8, args[3..], "--mz-rans-min-gain");
    const intensity_rans_min_gain = try parseOptionalInt(u8, args[3..], "--intensity-rans-min-gain");

    try codec.encodeDumpFile(io, allocator, input_path, output_path, .{
        .block_options = .{
            .mode = if (hasFlag(args[3..], "--lossy")) .lossy else .lossless,
            .intensity_quant = intensity_quant orelse 16384,
            .mz_rans_min_gain_percent = mz_rans_min_gain orelse 5,
            .intensity_rans_min_gain_percent = intensity_rans_min_gain orelse 12,
            .verbose_blocks = hasFlag(args[3..], "--verbose-blocks"),
        },
        .verbose_timing = hasFlag(args[3..], "--verbose-timing"),
    });

    std.debug.print("encoded: {s} -> {s}\n", .{ input_path, output_path });
}

fn commandDecode(io: std.Io, allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 4) return error.InvalidArguments;

    const input_path = args[2];
    const output_path = try parseOutputPath(args[3..]);

    try codec.decodeToDumpFile(io, allocator, input_path, output_path, .{
        .verbose_timing = hasFlag(args[3..], "--verbose-timing"),
    });
    std.debug.print("decoded: {s} -> {s}\n", .{ input_path, output_path });
}

fn printInspectionJson(io: std.Io, allocator: std.mem.Allocator, path: []const u8, inspection: codec.Inspection) !void {
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
    writeStdout(io, json_str);
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

fn commandInspect(io: std.Io, allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
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

    const inspection = try codec.inspectFileAlloc(io, allocator, input_path);
    defer codec.freeInspection(allocator, inspection);

    if (json_output) {
        try printInspectionJson(io, allocator, input_path, inspection);
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

const lossy_mz_max_error_da: f64 = 0.002;
const lossy_intensity_p95_threshold: f64 = 0.001; // 0.1%

fn checkLosslessSpectra(
    io: std.Io,
    orig: []const binary_reader.RawSpectrum,
    dec: []const binary_reader.RawSpectrum,
    verbose: bool,
) bool {
    var all_pass = true;

    if (orig.len != dec.len) {
        if (verbose) printStdout(io, "FAIL spectrum_count expected={} got={}\n", .{ orig.len, dec.len });
        return false;
    }
    if (verbose) printStdout(io, "PASS spectrum_count {}\n", .{orig.len});

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
        if (peak_count_fail_idx == null and (o.mz.len != d.mz.len or o.intensity.len != d.intensity.len or o.mz.len != o.intensity.len))
            peak_count_fail_idx = si;

        if (peak_count_fail_idx == null) {
            if (mz_fail == null) {
                for (o.mz, d.mz, 0..) |om, dm, pi| {
                    if (@as(u64, @bitCast(om)) != @as(u64, @bitCast(dm))) {
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
            printStdout(io, "FAIL scan_id spectrum={} expected={} got={}\n", .{ si, orig[si].scan_id, dec[si].scan_id });
            all_pass = false;
        } else printStdout(io, "PASS scan_id_exact\n", .{});

        if (rt_fail_idx) |si| {
            printStdout(io, "FAIL rt_seconds spectrum={} expected={e} got={e}\n", .{ si, orig[si].rt_seconds, dec[si].rt_seconds });
            all_pass = false;
        } else printStdout(io, "PASS rt_seconds_exact\n", .{});

        if (ms_level_fail_idx) |si| {
            printStdout(io, "FAIL ms_level spectrum={} expected={} got={}\n", .{ si, orig[si].ms_level, dec[si].ms_level });
            all_pass = false;
        } else printStdout(io, "PASS ms_level_exact\n", .{});

        if (precursor_fail_idx) |si| {
            printStdout(io, "FAIL precursor_mz spectrum={} expected={d} got={d}\n", .{ si, orig[si].precursor_mz, dec[si].precursor_mz });
            all_pass = false;
        } else printStdout(io, "PASS precursor_mz_exact\n", .{});

        if (peak_count_fail_idx) |si| {
            printStdout(io, "FAIL peak_count spectrum={} expected={} got={}\n", .{ si, orig[si].mz.len, dec[si].mz.len });
            all_pass = false;
        } else printStdout(io, "PASS peak_count_exact\n", .{});

        if (mz_fail) |f| {
            printStdout(io, "FAIL mz_round_trip spectrum={} peak={} expected={d} got={d}\n", .{ f.si, f.pi, f.exp, f.got });
            all_pass = false;
        } else printStdout(io, "PASS mz_round_trip exact\n", .{});

        if (int_fail) |f| {
            printStdout(io, "FAIL intensity_round_trip spectrum={} peak={} expected={e} got={e}\n", .{ f.si, f.pi, f.exp, f.got });
            all_pass = false;
        } else printStdout(io, "PASS intensity_round_trip exact\n", .{});
    } else {
        all_pass = scan_fail_idx == null and rt_fail_idx == null and ms_level_fail_idx == null and
            precursor_fail_idx == null and peak_count_fail_idx == null and
            mz_fail == null and int_fail == null;
    }

    return all_pass;
}

fn checkLossySpectra(
    io: std.Io,
    allocator: std.mem.Allocator,
    orig: []const binary_reader.RawSpectrum,
    dec: []const binary_reader.RawSpectrum,
    verbose: bool,
) !bool {
    var all_pass = true;

    if (orig.len != dec.len) {
        if (verbose) printStdout(io, "FAIL spectrum_count expected={} got={}\n", .{ orig.len, dec.len });
        return false;
    }
    if (verbose) printStdout(io, "PASS spectrum_count {}\n", .{orig.len});

    var meta_fail: bool = false;
    for (orig, dec, 0..) |o, d, si| {
        if (o.scan_id != d.scan_id or o.ms_level != d.ms_level or
            @as(u32, @bitCast(o.rt_seconds)) != @as(u32, @bitCast(d.rt_seconds)) or
            @as(u64, @bitCast(o.precursor_mz)) != @as(u64, @bitCast(d.precursor_mz)))
        {
            if (verbose) printStdout(io, "FAIL metadata_exact spectrum={}\n", .{si});
            meta_fail = true;
            all_pass = false;
            break;
        }
    }
    if (!meta_fail and verbose) printStdout(io, "PASS metadata_exact\n", .{});

    var total_peaks: usize = 0;
    for (orig) |s| total_peaks = try std.math.add(usize, total_peaks, s.mz.len);

    const mz_errors = try allocator.alloc(f64, total_peaks);
    defer allocator.free(mz_errors);
    const int_errors = try allocator.alloc(f64, total_peaks);
    defer allocator.free(int_errors);

    var peak_count_mismatch = false;
    var err_idx: usize = 0;
    for (orig, dec) |o, d| {
        if (o.mz.len != d.mz.len or o.intensity.len != d.intensity.len or o.mz.len != o.intensity.len) {
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
        if (verbose) printStdout(io, "FAIL peak_count_mismatch\n", .{});
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
            printStdout(io, "PASS mz_max_error {d:.6} Da < {d:.3} Da\n", .{ mz_max, lossy_mz_max_error_da })
        else
            printStdout(io, "FAIL mz_max_error {d:.6} Da > {d:.3} Da\n", .{ mz_max, lossy_mz_max_error_da });
    }
    if (!mz_pass) all_pass = false;

    std.mem.sort(f64, int_slice, {}, std.sort.asc(f64));
    const p95: f64 = if (n > 0) int_slice[n * 95 / 100] else 0.0;
    const p95_pct = p95 * 100.0;
    const int_pass = p95 <= lossy_intensity_p95_threshold;
    if (verbose) {
        if (int_pass)
            printStdout(io, "PASS intensity_p95_error {d:.3}% < {d:.1}%\n", .{ p95_pct, lossy_intensity_p95_threshold * 100.0 })
        else
            printStdout(io, "FAIL intensity_p95_error {d:.3}% > {d:.1}%\n", .{ p95_pct, lossy_intensity_p95_threshold * 100.0 });
    }
    if (!int_pass) all_pass = false;

    return all_pass;
}

fn commandValidate(io: std.Io, allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len != 5) return error.InvalidArguments;
    const orig_path = args[2];
    const dec_path = args[3];
    const mode_arg = args[4];

    const lossless_mode = std.mem.eql(u8, mode_arg, "--mode=lossless");
    const lossy_mode = std.mem.eql(u8, mode_arg, "--mode=lossy");
    if (!lossless_mode and !lossy_mode) return error.InvalidArguments;

    const orig = try binary_reader.readBinaryDump(io, orig_path, allocator);
    defer binary_reader.freeSpectra(allocator, orig);
    const dec = try binary_reader.readBinaryDump(io, dec_path, allocator);
    defer binary_reader.freeSpectra(allocator, dec);

    const all_pass = if (lossless_mode)
        checkLosslessSpectra(io, orig, dec, true)
    else
        try checkLossySpectra(io, allocator, orig, dec, true);

    if (!all_pass) return error.ValidationFailed;
}

fn commandValidateAdversarial(io: std.Io, allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len != 3) return error.InvalidArguments;
    const dir_path = args[2];

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var any_fail = false;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".bin")) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(full_path);

        const orig = binary_reader.readBinaryDump(io, full_path, allocator) catch |err| {
            printStdout(io, "FAIL {s} read_error={s}\n", .{ entry.name, @errorName(err) });
            any_fail = true;
            continue;
        };
        defer binary_reader.freeSpectra(allocator, orig);

        const encoded = codec.encodeFileAlloc(io, allocator, orig, .{}) catch |err| {
            printStdout(io, "FAIL {s} encode_error={s}\n", .{ entry.name, @errorName(err) });
            any_fail = true;
            continue;
        };
        defer allocator.free(encoded);

        const decoded = codec.decodeFileAlloc(io, allocator, encoded, .{}) catch |err| {
            printStdout(io, "FAIL {s} decode_error={s}\n", .{ entry.name, @errorName(err) });
            any_fail = true;
            continue;
        };
        defer binary_reader.freeSpectra(allocator, decoded);

        if (checkLosslessSpectra(io, orig, decoded, false)) {
            printStdout(io, "PASS {s}\n", .{entry.name});
        } else {
            printStdout(io, "FAIL {s}\n", .{entry.name});
            any_fail = true;
        }
    }

    if (any_fail) return error.ValidationFailed;
}

const RansSection = struct {
    encoded: []const u8,
    raw: []u8,
};

const RansCoreBenchmark = struct {
    section_count: usize,
    encoded_bytes: usize,
    raw_bytes: usize,
    encode_runs_ns: []u64,
    decode_runs_ns: []u64,
};

fn readIntLe(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn requireBytes(payload: []const u8, offset: usize, need_len: usize) !void {
    if (payload.len -| offset < need_len) return error.UnexpectedEndOfStream;
}

fn collectRansSections(
    allocator: std.mem.Allocator,
    block_bytes: []const u8,
    header: block.BlockHeader,
    mz_sections: *std.ArrayList(RansSection),
    exponent_sections: *std.ArrayList(RansSection),
) !void {
    if (block_bytes.len < try std.math.add(usize, block.header_len, header.payload_bytes)) return error.UnexpectedEndOfStream;
    const payload = block_bytes[block.header_len .. block.header_len + header.payload_bytes];
    const spectrum_count = @as(usize, header.spectrum_count);
    const total_peaks = @as(usize, header.total_peaks);
    var offset: usize = 0;

    if ((header.flags & block.flag_delta_scan_id) != 0) {
        try requireBytes(payload, offset, 1 + 8 + 4);
        offset += 1 + 8;
        const pack_len = readIntLe(u32, payload[offset .. offset + 4]);
        offset = try std.math.add(usize, offset, try std.math.add(usize, 4, pack_len));
    } else {
        offset = try std.math.add(usize, offset, try std.math.mul(usize, spectrum_count, @sizeOf(u32)));
    }

    if ((header.flags & block.flag_delta_rt) != 0) {
        try requireBytes(payload, offset, 1 + 8 + 4);
        offset += 1 + 8;
        const pack_len = readIntLe(u32, payload[offset .. offset + 4]);
        offset = try std.math.add(usize, offset, try std.math.add(usize, 4, pack_len));
    } else {
        offset = try std.math.add(usize, offset, try std.math.mul(usize, spectrum_count, @sizeOf(f32)));
    }

    offset = try std.math.add(usize, offset, try std.math.mul(usize, spectrum_count, @sizeOf(f64)));
    try requireBytes(payload, offset, try std.math.mul(usize, spectrum_count, @sizeOf(u32)));
    const peak_counts = try allocator.alloc(u32, spectrum_count);
    defer allocator.free(peak_counts);
    var delta_count: usize = 0;
    for (peak_counts, 0..) |*value, idx| {
        const start = try std.math.add(usize, offset, try std.math.mul(usize, idx, @sizeOf(u32)));
        value.* = readIntLe(u32, payload[start .. start + @sizeOf(u32)]);
        if (value.* > 0) delta_count = try std.math.add(usize, delta_count, value.* - 1);
    }
    offset = try std.math.add(usize, offset, try std.math.mul(usize, spectrum_count, @sizeOf(u32)));

    try requireBytes(payload, offset, @sizeOf(u64) + 4);
    offset += @sizeOf(u64);
    const mz_payload_len = readIntLe(u32, payload[offset .. offset + 4]);
    offset += 4;

    try requireBytes(payload, offset, mz_payload_len);
    if ((header.flags & block.flag_rans_mz) != 0) {
        try requireBytes(payload, offset, 5);
        const first_count = readIntLe(u32, payload[offset .. offset + 4]);
        const first_size = payload[offset + 4];
        if (first_size != 4 and first_size != 8) return error.InvalidFirstSize;
        const first_bytes = try std.math.mul(usize, first_count, first_size);
        var encoded_offset = try std.math.add(usize, 5, first_bytes);
        if (mz_payload_len < encoded_offset) return error.UnexpectedEndOfStream;
        var raw_len = try block.packedByteLen(header.mz_bit_width, delta_count);
        if ((header.flags & block.flag_lossless_mz_f64) != 0) {
            if (mz_payload_len - encoded_offset < @sizeOf(u32)) {
                return error.UnexpectedEndOfStream;
            }
            const group_count = readIntLe(
                u32,
                payload[offset + encoded_offset ..][0..@sizeOf(u32)],
            );
            encoded_offset += @sizeOf(u32);
            const metadata_len = try std.math.mul(
                usize,
                group_count,
                @sizeOf(u8) + @sizeOf(u64),
            );
            if (mz_payload_len - encoded_offset < metadata_len) {
                return error.UnexpectedEndOfStream;
            }
            raw_len = 0;
            var group_cursor: usize = 0;
            for (peak_counts) |peak_count| {
                if (peak_count < 2) continue;
                if (group_cursor >= group_count) return error.InvalidMzPayload;
                const metadata_offset = offset + encoded_offset +
                    group_cursor * (@sizeOf(u8) + @sizeOf(u64));
                const width = payload[metadata_offset];
                raw_len = try std.math.add(
                    usize,
                    raw_len,
                    try block.packedByteLen(width, peak_count - 1),
                );
                group_cursor += 1;
            }
            if (group_cursor != group_count) return error.InvalidMzPayload;
            encoded_offset += metadata_len;
        }
        const encoded = payload[offset + encoded_offset .. offset + mz_payload_len];
        const raw = try rans.decodeAlloc(allocator, encoded, raw_len);
        mz_sections.append(allocator, .{ .encoded = encoded, .raw = raw }) catch |err| {
            allocator.free(raw);
            return err;
        };
    }
    offset = try std.math.add(usize, offset, mz_payload_len);

    if ((header.flags & block.flag_lossless_intensity_raw) != 0) {
        if ((header.flags & block.flag_rans_intensity) != 0) {
            try requireBytes(payload, offset, 4);
            const encoded_len = readIntLe(u32, payload[offset .. offset + 4]);
            offset = try std.math.add(usize, offset, try std.math.add(usize, 4, encoded_len));
        } else {
            offset = try std.math.add(usize, offset, try std.math.mul(usize, total_peaks, @sizeOf(f32)));
        }
    } else if ((header.flags & block.flag_split_exponent) != 0) {
        try requireBytes(payload, offset, 1 + 8 + 4);
        const exp_bit_width = payload[offset];
        offset += 1 + 8;
        const exp_payload_len = readIntLe(u32, payload[offset .. offset + 4]);
        offset += 4;
        try requireBytes(payload, offset, exp_payload_len);
        if ((header.flags & block.flag_rans_intensity) != 0) {
            const encoded = payload[offset .. offset + exp_payload_len];
            const raw = try rans.decodeAlloc(allocator, encoded, try block.packedByteLen(exp_bit_width, total_peaks));
            exponent_sections.append(allocator, .{ .encoded = encoded, .raw = raw }) catch |err| {
                allocator.free(raw);
                return err;
            };
        }
        offset = try std.math.add(usize, offset, exp_payload_len);
        offset = try std.math.add(usize, offset, try std.math.mul(usize, total_peaks, 3));
    } else {
        try requireBytes(payload, offset, @sizeOf(u16) + 4);
        offset += @sizeOf(u16);
        const intensity_payload_len = readIntLe(u32, payload[offset .. offset + 4]);
        offset = try std.math.add(usize, offset, try std.math.add(usize, 4, intensity_payload_len));
    }

    if (offset != payload.len) return error.TrailingBlockPayload;
}

fn freeRansSections(allocator: std.mem.Allocator, sections: []const RansSection) void {
    for (sections) |section| allocator.free(section.raw);
}

fn benchmarkRansSections(
    io: std.Io,
    bench_allocator: std.mem.Allocator,
    sections: []const RansSection,
    repeats: u32,
) !RansCoreBenchmark {
    const encode_runs_ns = try bench_allocator.alloc(u64, repeats);
    errdefer bench_allocator.free(encode_runs_ns);
    const decode_runs_ns = try bench_allocator.alloc(u64, repeats);
    errdefer bench_allocator.free(decode_runs_ns);

    var encoded_bytes: usize = 0;
    var raw_bytes: usize = 0;
    for (sections) |section| {
        encoded_bytes = try std.math.add(usize, encoded_bytes, section.encoded.len);
        raw_bytes = try std.math.add(usize, raw_bytes, section.raw.len);
    }

    for (0..repeats) |repeat_idx| {
        const encode_start = monotonicNs(io);
        for (sections) |section| {
            const encoded = try rans.encodeAlloc(bench_allocator, section.raw);
            defer bench_allocator.free(encoded);
            if (encoded.len == 0 and section.raw.len != 0) return error.InvalidBenchmark;
        }
        encode_runs_ns[repeat_idx] = monotonicNs(io) - encode_start;

        const decode_start = monotonicNs(io);
        for (sections) |section| {
            const out = try bench_allocator.alloc(u8, section.raw.len);
            defer bench_allocator.free(out);
            try rans.decodeInto(section.encoded, out);
            if (!std.mem.eql(u8, out, section.raw)) return error.InvalidBenchmark;
        }
        decode_runs_ns[repeat_idx] = monotonicNs(io) - decode_start;
    }

    return .{
        .section_count = sections.len,
        .encoded_bytes = encoded_bytes,
        .raw_bytes = raw_bytes,
        .encode_runs_ns = encode_runs_ns,
        .decode_runs_ns = decode_runs_ns,
    };
}

fn meanNs(values: []const u64) f64 {
    if (values.len == 0) return 0.0;
    var total: f64 = 0.0;
    for (values) |value| total += @as(f64, @floatFromInt(value));
    return total / @as(f64, @floatFromInt(values.len));
}

fn monotonicNs(io: std.Io) u64 {
    return @truncate(@as(u96, @bitCast(std.Io.Clock.now(.awake, io).nanoseconds)));
}

fn printRunArray(allocator: std.mem.Allocator, values: []const u64) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.append(allocator, '[');
    for (values, 0..) |value, idx| {
        if (idx != 0) try list.appendSlice(allocator, ", ");
        const ns_text = try std.fmt.allocPrint(allocator, "{d:.6}", .{@as(f64, @floatFromInt(value)) / 1_000_000_000.0});
        defer allocator.free(ns_text);
        try list.appendSlice(allocator, ns_text);
    }
    try list.append(allocator, ']');
    return list.toOwnedSlice(allocator);
}

fn commandBenchmarkRansCore(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
) !void {
    if (args.len < 3) return error.InvalidArguments;
    const repeats = try parseOptionalInt(u32, args[2..], "--repeats") orelse 5;

    var path: ?[]const u8 = null;
    var idx: usize = 0;
    const tail = args[2..];
    while (idx < tail.len) : (idx += 1) {
        const arg = tail[idx];
        if (std.mem.eql(u8, arg, "--repeats")) {
            idx += 1;
            continue;
        }
        if (path != null or std.mem.startsWith(u8, arg, "--")) return error.InvalidArguments;
        path = arg;
    }
    if (path == null) return error.InvalidArguments;

    const bytes = try codec.readFileAlloc(io, path.?, allocator);
    defer allocator.free(bytes);
    const inspection = try codec.inspectAlloc(allocator, bytes);
    defer codec.freeInspection(allocator, inspection);

    var mz_sections: std.ArrayList(RansSection) = .empty;
    defer {
        freeRansSections(allocator, mz_sections.items);
        mz_sections.deinit(allocator);
    }
    var exponent_sections: std.ArrayList(RansSection) = .empty;
    defer {
        freeRansSections(allocator, exponent_sections.items);
        exponent_sections.deinit(allocator);
    }

    for (inspection.blocks) |block_info| {
        const end = try std.math.add(usize, block_info.offset, block_info.total_bytes);
        if (end > bytes.len) return error.UnexpectedEndOfStream;
        try collectRansSections(
            allocator,
            bytes[block_info.offset..end],
            block_info.header,
            &mz_sections,
            &exponent_sections,
        );
    }

    const mz_benchmark = try benchmarkRansSections(io, allocator, mz_sections.items, repeats);
    defer {
        allocator.free(mz_benchmark.encode_runs_ns);
        allocator.free(mz_benchmark.decode_runs_ns);
    }
    const exponent_benchmark = try benchmarkRansSections(io, allocator, exponent_sections.items, repeats);
    defer {
        allocator.free(exponent_benchmark.encode_runs_ns);
        allocator.free(exponent_benchmark.decode_runs_ns);
    }

    const mz_encode_runs = try printRunArray(allocator, mz_benchmark.encode_runs_ns);
    defer allocator.free(mz_encode_runs);
    const mz_decode_runs = try printRunArray(allocator, mz_benchmark.decode_runs_ns);
    defer allocator.free(mz_decode_runs);
    const exp_encode_runs = try printRunArray(allocator, exponent_benchmark.encode_runs_ns);
    defer allocator.free(exp_encode_runs);
    const exp_decode_runs = try printRunArray(allocator, exponent_benchmark.decode_runs_ns);
    defer allocator.free(exp_decode_runs);

    const json_str = try std.fmt.allocPrint(
        allocator,
        "{{\n" ++
            "  \"file\": \"{s}\",\n" ++
            "  \"repeats\": {},\n" ++
            "  \"mz\": {{\n" ++
            "    \"sections\": {},\n" ++
            "    \"encoded_bytes\": {},\n" ++
            "    \"raw_bytes\": {},\n" ++
            "    \"encode_runs_seconds\": {s},\n" ++
            "    \"decode_runs_seconds\": {s},\n" ++
            "    \"encode_mean_seconds\": {d:.6},\n" ++
            "    \"decode_mean_seconds\": {d:.6}\n" ++
            "  }},\n" ++
            "  \"exponent\": {{\n" ++
            "    \"sections\": {},\n" ++
            "    \"encoded_bytes\": {},\n" ++
            "    \"raw_bytes\": {},\n" ++
            "    \"encode_runs_seconds\": {s},\n" ++
            "    \"decode_runs_seconds\": {s},\n" ++
            "    \"encode_mean_seconds\": {d:.6},\n" ++
            "    \"decode_mean_seconds\": {d:.6}\n" ++
            "  }}\n" ++
            "}}\n",
        .{
            path.?,
            repeats,
            mz_benchmark.section_count,
            mz_benchmark.encoded_bytes,
            mz_benchmark.raw_bytes,
            mz_encode_runs,
            mz_decode_runs,
            meanNs(mz_benchmark.encode_runs_ns) / 1_000_000_000.0,
            meanNs(mz_benchmark.decode_runs_ns) / 1_000_000_000.0,
            exponent_benchmark.section_count,
            exponent_benchmark.encoded_bytes,
            exponent_benchmark.raw_bytes,
            exp_encode_runs,
            exp_decode_runs,
            meanNs(exponent_benchmark.encode_runs_ns) / 1_000_000_000.0,
            meanNs(exponent_benchmark.decode_runs_ns) / 1_000_000_000.0,
        },
    );
    defer allocator.free(json_str);
    writeStdout(io, json_str);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, args[1], "dump-inspect")) {
        if (args.len != 3) {
            printUsage();
            return error.InvalidArguments;
        }
        try commandDumpInspect(io, init.gpa, args[2]);
        return;
    }

    if (std.mem.eql(u8, args[1], "encode")) {
        try commandEncode(io, init.gpa, args);
        return;
    }

    if (std.mem.eql(u8, args[1], "decode")) {
        try commandDecode(io, init.gpa, args);
        return;
    }

    if (std.mem.eql(u8, args[1], "inspect")) {
        try commandInspect(io, init.gpa, args);
        return;
    }

    if (std.mem.eql(u8, args[1], "benchmark-rans-core")) {
        try commandBenchmarkRansCore(io, init.gpa, args);
        return;
    }

    if (std.mem.eql(u8, args[1], "validate")) {
        try commandValidate(io, init.gpa, args);
        return;
    }

    if (std.mem.eql(u8, args[1], "validate-adversarial")) {
        try commandValidateAdversarial(io, init.gpa, args);
        return;
    }

    printUsage();
    return error.InvalidArguments;
}
