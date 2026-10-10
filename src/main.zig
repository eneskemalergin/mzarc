//! CLI: dump, dump-inspect, encode, decode, inspect, validate, validate-adversarial.
//! Prefer `init.io` for I/O; exit codes and verb behavior stay stable.

const std = @import("std");
const binary_reader = @import("binary_reader");
const block = @import("block");
const codec = @import("codec");
const quantize = @import("quantize");
const mzml_dump = @import("mzml_dump.zig");
const source_document = @import("source_document");

const DEFAULT_ENCODE_OPTIONS: block.EncodeOptions = .{};
const LOSSY_MZ_HALF_STEP_DA: f64 = 0.5 / @as(f64, @floatFromInt(DEFAULT_ENCODE_OPTIONS.mz_scale_factor));

fn printStdout(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buf);
    writer.interface.print(fmt, args) catch return;
    writer.interface.flush() catch return;
}

fn printUsage() void {
    std.debug.print(
        "Usage:\n" ++
            "  mzarc dump <input.mzML> -o <output.bin>\n" ++
            "  mzarc dump-inspect <input.bin>\n" ++
            "  mzarc encode <input.bin> -o <output.mzarc> [--lossy] [--intensity-quant <levels>] [--mz-rans-min-gain <pct>] [--intensity-rans-min-gain <pct>] [--verbose-blocks] [--verbose-timing]\n" ++
            "  mzarc encode <input.mzML> -o <output.mzarc> [--lossy]\n" ++
            "  mzarc decode <input.mzarc> -o <output.bin|output.mzML> [--verbose-timing]\n" ++
            "  mzarc inspect <input.mzarc> [--json] [--blocks]\n" ++
            "  mzarc validate <original.bin> <decoded.bin> --mode=lossless|lossy|mzml-lossy [--intensity-quant <levels>]\n" ++
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

    std.sort.pdq(u64, peak_counts, {}, std.sort.asc(u64));
    // Twice the median keeps it exact: an even count averages the two middle values.
    const n = peak_counts.len;
    const median_twice: u64 = if (n == 0) 0 else if (n % 2 == 1) 2 * peak_counts[n / 2] else peak_counts[n / 2 - 1] + peak_counts[n / 2];

    std.debug.print("file: {s}\n", .{path});
    std.debug.print("spectra: {}\n", .{spectra.len});
    std.debug.print("total peaks: {}\n", .{total_peaks});
    std.debug.print("ms1 count: {}\n", .{ms1_count});
    std.debug.print("ms2 count: {}\n", .{ms2_count});
    std.debug.print("zero intensity peaks: {}\n", .{zero_intensity});
    std.debug.print("min peaks per spectrum: {}\n", .{min_peaks});
    std.debug.print("median peaks per spectrum: {}{s}\n", .{ median_twice / 2, if (median_twice % 2 == 1) ".5" else "" });
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

/// Refuses an output that names the input file, because the finished output would replace it.
/// Paths are compared after resolving symbolic links; a missing output cannot be the input.
fn requireDistinctOutput(io: std.Io, input_path: []const u8, output_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var input_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var output_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const input_len = try cwd.realPathFile(io, input_path, &input_buffer);
    const output_len = cwd.realPathFile(io, output_path, &output_buffer) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (std.mem.eql(u8, input_buffer[0..input_len], output_buffer[0..output_len])) {
        std.debug.print("error: output {s} is the input file\n", .{output_path});
        return error.OutputIsInput;
    }
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
    try requireDistinctOutput(io, input_path, output_path);
    if (std.ascii.endsWithIgnoreCase(input_path, ".mzml")) return encodeSourceDocument(io, allocator, input_path, output_path, args[3..]);
    const intensity_quant = try parseOptionalInt(u16, args[3..], "--intensity-quant");
    const mz_rans_min_gain = try parseOptionalInt(u8, args[3..], "--mz-rans-min-gain");
    const intensity_rans_min_gain = try parseOptionalInt(u8, args[3..], "--intensity-rans-min-gain");

    try codec.encodeDumpFile(io, allocator, input_path, output_path, .{
        .block_options = .{
            .mode = if (hasFlag(args[3..], "--lossy")) .lossy else .lossless,
            .intensity_quant = intensity_quant orelse DEFAULT_ENCODE_OPTIONS.intensity_quant,
            .mz_rans_min_gain_percent = mz_rans_min_gain orelse DEFAULT_ENCODE_OPTIONS.mz_rans_min_gain_percent,
            .intensity_rans_min_gain_percent = intensity_rans_min_gain orelse DEFAULT_ENCODE_OPTIONS.intensity_rans_min_gain_percent,
            .verbose_blocks = hasFlag(args[3..], "--verbose-blocks"),
        },
        .verbose_timing = hasFlag(args[3..], "--verbose-timing"),
    });

    std.debug.print("encoded: {s} -> {s}\n", .{ input_path, output_path });
}

/// Encodes a complete mzML document; the Dump V1 tuning options do not apply to it.
fn encodeSourceDocument(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, options: []const [:0]const u8) !void {
    for (options, 0..) |arg, idx| {
        if (std.mem.eql(u8, arg, "--lossy")) continue;
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) continue;
        if (idx > 0 and (std.mem.eql(u8, options[idx - 1], "-o") or std.mem.eql(u8, options[idx - 1], "--output"))) continue;
        std.debug.print("error: {s} does not apply to mzML input\n", .{arg});
        return error.InvalidArguments;
    }
    const summary = if (hasFlag(options, "--lossy"))
        try source_document.encodeLossy(io, allocator, input_path, output_path)
    else
        try source_document.encodeExact(io, allocator, input_path, output_path);
    printStdout(io, "encoded: {s} -> {s}\nmode: {s}\nsource bytes: {d}\narchive bytes: {d}\n", .{
        input_path, output_path, @tagName(summary.mode), summary.source_bytes, summary.archive_bytes,
    });
    if (summary.mode == .lossy) {
        printStdout(io, "arrays coded: {d}\narrays kept exact: {d}\nindex entries corrected: {d}\n", .{
            summary.arrays_coded, summary.arrays_kept, summary.offsets_corrected,
        });
    }
}

/// Whether the file starts with a source-document header; short or unreadable files are not.
fn isSourceDocumentFile(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var header: [codec.header_len]u8 = undefined;
    const got = file.readPositionalAll(io, &header, 0) catch return false;
    return got == header.len and source_document.isSourceDocument(&header);
}

fn commandDecode(io: std.Io, allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 4) return error.InvalidArguments;

    const input_path = args[2];
    const output_path = try parseOutputPath(args[3..]);
    try requireDistinctOutput(io, input_path, output_path);
    if (isSourceDocumentFile(io, input_path)) {
        const summary = try source_document.decode(io, allocator, input_path, output_path);
        printStdout(io, "decoded: {s} -> {s}\nmode: {s}\noutput bytes: {d}\n", .{ input_path, output_path, @tagName(summary.mode), summary.output_bytes });
        return;
    }

    try codec.decodeToDumpFile(io, allocator, input_path, output_path, .{
        .verbose_timing = hasFlag(args[3..], "--verbose-timing"),
    });
    std.debug.print("decoded: {s} -> {s}\n", .{ input_path, output_path });
}

fn printInspectionJson(io: std.Io, path: []const u8, inspection: codec.Inspection) void {
    const header = inspection.header;
    printStdout(io, "{f}\n", .{std.json.fmt(.{
        .file = path,
        .version_major = header.version_major,
        .version_minor = header.version_minor,
        .spectrum_count = header.spectrum_count,
        .block_count = header.block_count,
        .total_peaks = header.total_peaks,
        .block_size = header.block_size,
        .ms1_block_count = inspection.ms1_block_count,
        .ms2_block_count = inspection.ms2_block_count,
        .ms1_spectra = inspection.ms1_spectra,
        .ms2_spectra = inspection.ms2_spectra,
        .byte_breakdown = inspection.byte_breakdown,
    }, .{ .whitespace = .indent_2 })});
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

    if (isSourceDocumentFile(io, input_path)) {
        const info = try source_document.inspect(io, input_path);
        if (json_output) {
            printStdout(io, "{{\"file\":{f},\"kind\":\"source-document\",\"mode\":\"{s}\",\"stream_bytes\":{d},\"archive_bytes\":{d}}}\n", .{
                std.json.fmt(input_path, .{}), @tagName(info.header.mode), info.header.stream_len, info.archive_bytes,
            });
        } else {
            printStdout(io, "file: {s}\nkind: source document\nmode: {s}\nstream bytes: {d}\narchive bytes: {d}\n", .{
                input_path, @tagName(info.header.mode), info.header.stream_len, info.archive_bytes,
            });
        }
        return;
    }

    const inspection = try codec.inspectFileAlloc(io, allocator, input_path);
    defer codec.freeInspection(allocator, inspection);

    if (json_output) {
        printInspectionJson(io, input_path, inspection);
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
    inline for (std.meta.fields(codec.FileByteBreakdown)) |field| {
        const label = comptime blk: {
            var name: [field.name.len]u8 = field.name[0..field.name.len].*;
            std.mem.replaceScalar(u8, &name, '_', ' ');
            break :blk name;
        };
        std.debug.print(label ++ ": {}\n", .{@field(inspection.byte_breakdown, field.name)});
    }

    if (show_blocks) {
        std.debug.print("\n", .{});
        printBlockTable(inspection);
    }
}

fn checkLosslessSpectra(
    io: std.Io,
    orig: []const binary_reader.RawSpectrum,
    dec: []const binary_reader.RawSpectrum,
    verbose: bool,
) bool {
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
        } else printStdout(io, "PASS scan_id_exact\n", .{});

        if (rt_fail_idx) |si| {
            printStdout(io, "FAIL rt_seconds spectrum={} expected={e} got={e}\n", .{ si, orig[si].rt_seconds, dec[si].rt_seconds });
        } else printStdout(io, "PASS rt_seconds_exact\n", .{});

        if (ms_level_fail_idx) |si| {
            printStdout(io, "FAIL ms_level spectrum={} expected={} got={}\n", .{ si, orig[si].ms_level, dec[si].ms_level });
        } else printStdout(io, "PASS ms_level_exact\n", .{});

        if (precursor_fail_idx) |si| {
            printStdout(io, "FAIL precursor_mz spectrum={} expected={d} got={d}\n", .{ si, orig[si].precursor_mz, dec[si].precursor_mz });
        } else printStdout(io, "PASS precursor_mz_exact\n", .{});

        if (peak_count_fail_idx) |si| {
            printStdout(io, "FAIL peak_count spectrum={} expected={} got={}\n", .{ si, orig[si].mz.len, dec[si].mz.len });
        } else printStdout(io, "PASS peak_count_exact\n", .{});

        if (mz_fail) |f| {
            printStdout(io, "FAIL mz_round_trip spectrum={} peak={} expected={d} got={d}\n", .{ f.si, f.pi, f.exp, f.got });
        } else printStdout(io, "PASS mz_round_trip exact\n", .{});

        if (int_fail) |f| {
            printStdout(io, "FAIL intensity_round_trip spectrum={} peak={} expected={e} got={e}\n", .{ f.si, f.pi, f.exp, f.got });
        } else printStdout(io, "PASS intensity_round_trip exact\n", .{});
    }

    return scan_fail_idx == null and rt_fail_idx == null and ms_level_fail_idx == null and
        precursor_fail_idx == null and peak_count_fail_idx == null and
        mz_fail == null and int_fail == null;
}

fn checkLossySpectra(
    io: std.Io,
    orig: []const binary_reader.RawSpectrum,
    dec: []const binary_reader.RawSpectrum,
    intensity_quant: u16,
    // mzML lossy archives keep some arrays exact, so a bit-identical peak value also passes.
    exact_allowed: bool,
    verbose: bool,
) bool {
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

    var peak_count_mismatch = false;
    var numeric_domain_mismatch = false;
    var mz_quantization_mismatch = false;
    var mz_max: f64 = 0.0;
    var intensity_log_max: f64 = 0.0;
    for (orig, dec) |o, d| {
        if (o.mz.len != d.mz.len or o.intensity.len != d.intensity.len or o.mz.len != o.intensity.len) {
            peak_count_mismatch = true;
            break;
        }
        for (o.mz, d.mz, o.intensity, d.intensity) |om, dm, oi, di| {
            const mz_exact = exact_allowed and @as(u64, @bitCast(om)) == @as(u64, @bitCast(dm));
            if (!mz_exact) {
                if (!std.math.isFinite(dm) or dm < 0.0) {
                    numeric_domain_mismatch = true;
                    continue;
                }
                const quantized_mz = quantize.quantizeMzValue(om, DEFAULT_ENCODE_OPTIONS.mz_scale_factor) catch {
                    numeric_domain_mismatch = true;
                    continue;
                };
                const expected_mz = quantize.dequantizeMzValue(quantized_mz, DEFAULT_ENCODE_OPTIONS.mz_scale_factor) catch unreachable;
                if (@as(u64, @bitCast(dm)) != @as(u64, @bitCast(expected_mz))) mz_quantization_mismatch = true;
                mz_max = @max(mz_max, @abs(om - dm));
            }

            if (exact_allowed and @as(u32, @bitCast(oi)) == @as(u32, @bitCast(di))) continue;
            if (!std.math.isFinite(oi) or !std.math.isFinite(di)) {
                numeric_domain_mismatch = true;
                continue;
            }
            if (oi <= 0.0) {
                if (@as(u32, @bitCast(di)) != 0) numeric_domain_mismatch = true;
                continue;
            }
            if (di <= 0.0) {
                numeric_domain_mismatch = true;
                continue;
            }
            const original_log = std.math.log1p(@as(f64, oi));
            const decoded_log = std.math.log1p(@as(f64, di));
            intensity_log_max = @max(intensity_log_max, @abs(original_log - decoded_log));
        }
    }

    if (peak_count_mismatch) {
        if (verbose) printStdout(io, "FAIL peak_count_mismatch\n", .{});
        return false;
    }

    if (numeric_domain_mismatch) {
        if (verbose) printStdout(io, "FAIL numeric_domain\n", .{});
        return false;
    } else if (verbose) printStdout(io, "PASS numeric_domain\n", .{});

    if (mz_quantization_mismatch) {
        if (verbose) printStdout(io, "FAIL mz_quantized_values\n", .{});
        all_pass = false;
    } else if (verbose) {
        printStdout(io, "PASS mz_quantized_values exact\n", .{});
    }
    if (verbose) printStdout(io, "PASS mz_max_observed_error {d:.12} Da (nominal half-step {d:.9} Da plus f64 rounding)\n", .{ mz_max, LOSSY_MZ_HALF_STEP_DA });

    const max_log = std.math.log1p(@as(f64, std.math.floatMax(f32)));
    const stored_max: f32 = @floatCast(max_log);
    const quant: f64 = @floatFromInt(intensity_quant);
    const intensity_log_limit = @max(@as(f64, stored_max) / quant, @abs(max_log - @as(f64, stored_max))) + 1.0 / 8_388_608.0;
    const int_pass = intensity_log_max <= intensity_log_limit;
    if (verbose) {
        if (int_pass)
            printStdout(io, "PASS intensity_log1p_max_error {d:.9} <= {d:.9} (format-wide, Q={})\n", .{ intensity_log_max, intensity_log_limit, intensity_quant })
        else
            printStdout(io, "FAIL intensity_log1p_max_error {d:.9} > {d:.9} (format-wide, Q={})\n", .{ intensity_log_max, intensity_log_limit, intensity_quant });
    }
    if (!int_pass) all_pass = false;

    return all_pass;
}

fn commandValidate(io: std.Io, allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len != 5 and args.len != 7) return error.InvalidArguments;
    const orig_path = args[2];
    const dec_path = args[3];
    const mode_arg = args[4];

    const lossless_mode = std.mem.eql(u8, mode_arg, "--mode=lossless");
    const lossy_mode = std.mem.eql(u8, mode_arg, "--mode=lossy");
    const mzml_lossy_mode = std.mem.eql(u8, mode_arg, "--mode=mzml-lossy");
    if (!lossless_mode and !lossy_mode and !mzml_lossy_mode) return error.InvalidArguments;

    // The mzML lossy profile fixes its level count; only Dump V1 lossy accepts --intensity-quant.
    var intensity_quant = if (mzml_lossy_mode) source_document.intensity_levels else DEFAULT_ENCODE_OPTIONS.intensity_quant;
    if (args.len == 7) {
        if (!lossy_mode or !std.mem.eql(u8, args[5], "--intensity-quant")) return error.InvalidArguments;
        intensity_quant = try std.fmt.parseInt(u16, args[6], 10);
        if (intensity_quant == 0) return error.InvalidQuantFactor;
    }

    const orig = try binary_reader.readBinaryDump(io, orig_path, allocator);
    defer binary_reader.freeSpectra(allocator, orig);
    const dec = try binary_reader.readBinaryDump(io, dec_path, allocator);
    defer binary_reader.freeSpectra(allocator, dec);

    const all_pass = if (lossless_mode)
        checkLosslessSpectra(io, orig, dec, true)
    else
        checkLossySpectra(io, orig, dec, intensity_quant, mzml_lossy_mode, true);

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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        printUsage();
        return;
    }

    if (args.len == 2 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        printUsage();
        return;
    }

    const Command = enum { dump, @"dump-inspect", encode, decode, inspect, validate, @"validate-adversarial" };
    const command = std.meta.stringToEnum(Command, args[1]) orelse {
        printUsage();
        return error.InvalidArguments;
    };
    switch (command) {
        .dump => {
            if (args.len != 5) {
                printUsage();
                return error.InvalidArguments;
            }
            const output_path = try parseOutputPath(args);
            try requireDistinctOutput(io, args[2], output_path);
            const summary = try mzml_dump.dump(io, init.gpa, args[2], output_path);
            printStdout(io, "input: {s}\noutput: {s}\nspectra: {d}\ntotal peaks: {d}\nms1 count: {d}\nms2 count: {d}\noutput bytes: {d}\n", .{
                args[2], output_path, summary.spectra, summary.peaks, summary.ms1, summary.ms2, summary.bytes,
            });
        },
        .@"dump-inspect" => {
            if (args.len != 3) {
                printUsage();
                return error.InvalidArguments;
            }
            try commandDumpInspect(io, init.gpa, args[2]);
        },
        .encode => try commandEncode(io, init.gpa, args),
        .decode => try commandDecode(io, init.gpa, args),
        .inspect => try commandInspect(io, init.gpa, args),
        .validate => try commandValidate(io, init.gpa, args),
        .@"validate-adversarial" => try commandValidateAdversarial(io, init.gpa, args),
    }
}
