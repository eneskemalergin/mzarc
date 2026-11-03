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

const usage =
    "Usage:\n" ++
    "  mzarc dump <input.mzML> -o <output.bin>\n" ++
    "  mzarc dump-inspect <input.bin>\n" ++
    "  mzarc encode <input.bin> -o <output.mzarc> [--lossy] [--intensity-quant <levels>] [--mz-rans-min-gain <pct>] [--intensity-rans-min-gain <pct>] [--verbose-blocks] [--verbose-timing]\n" ++
    "  mzarc encode <input.mzML> -o <output.mzarc> [--lossy]\n" ++
    "  mzarc decode <input.mzarc> -o <output.bin|output.mzML> [--verbose-timing]\n" ++
    "  mzarc inspect <input.mzarc> [--json] [--blocks]\n" ++
    "  mzarc validate <original.bin> <decoded.bin> --mode=lossless|lossy|mzml-lossy [--intensity-quant <levels>]\n" ++
    "  mzarc validate-adversarial <dir>\n";

fn printUsage() void {
    std.debug.print(usage, .{});
}

/// Reads the dump one record at a time; only the peak counts (4 bytes per spectrum, at most
/// `codec.MAX_FILE_SPECTRA` of them) stay for the median.
fn commandDumpInspect(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var records = binary_reader.RecordReader.init(io, file, &read_buffer, block.MAX_BLOCK_PEAKS);
    defer records.deinit(allocator);

    var total_peaks: u64 = 0;
    var ms1_count: u64 = 0;
    var ms2_count: u64 = 0;
    var zero_intensity: u64 = 0;

    var peak_counts: std.ArrayList(u32) = .empty;
    defer peak_counts.deinit(allocator);

    while (try records.next(allocator)) |spectrum| {
        if (peak_counts.items.len == codec.MAX_FILE_SPECTRA) return error.FileResourceLimit;
        try peak_counts.append(allocator, @intCast(spectrum.mz.len));
        total_peaks = try std.math.add(u64, total_peaks, spectrum.mz.len);
        switch (spectrum.ms_level) {
            1 => ms1_count += 1,
            2 => ms2_count += 1,
            else => {},
        }
        for (spectrum.intensity) |v| {
            if (v == 0.0) zero_intensity += 1;
        }
    }

    std.sort.pdq(u32, peak_counts.items, {}, std.sort.asc(u32));
    // Twice the median keeps it exact: an even count averages the two middle values.
    const counts = peak_counts.items;
    const n = counts.len;
    const min_peaks: u64 = if (n == 0) 0 else counts[0];
    const max_peaks: u64 = if (n == 0) 0 else counts[n - 1];
    const median_twice: u64 = if (n == 0) 0 else if (n % 2 == 1) 2 * @as(u64, counts[n / 2]) else @as(u64, counts[n / 2 - 1]) + counts[n / 2];

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;
    try out.print("file: {s}\n", .{path});
    try out.print("spectra: {}\n", .{n});
    try out.print("total peaks: {}\n", .{total_peaks});
    try out.print("ms1 count: {}\n", .{ms1_count});
    try out.print("ms2 count: {}\n", .{ms2_count});
    try out.print("zero intensity peaks: {}\n", .{zero_intensity});
    try out.print("min peaks per spectrum: {}\n", .{min_peaks});
    try out.print("median peaks per spectrum: {}{s}\n", .{ median_twice / 2, if (median_twice % 2 == 1) ".5" else "" });
    try out.print("max peaks per spectrum: {}\n", .{max_peaks});
    try out.flush();
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

    printStdout(io, "encoded: {s} -> {s}\n", .{ input_path, output_path });
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
    printStdout(io, "decoded: {s} -> {s}\n", .{ input_path, output_path });
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

fn printBlockTable(out: *std.Io.Writer, inspection: codec.Inspection) !void {
    try out.print("{s:>6}  {s:>5}  {s:>6}  {s:>8}  {s:>6}  {s:>9}  {s:>9}  {s:>9}\n", .{
        "idx", "level", "nspec", "npeaks", "mz_bw", "int_bw", "mz_bytes", "int_bytes",
    });
    for (inspection.blocks, 0..) |block_info, idx| {
        const h = block_info.header;
        const b = block_info.byte_breakdown;
        try out.print("{:>6}  {:>5}  {:>6}  {:>8}  {:>6}  {:>9}  {:>9}  {:>9}\n", .{
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

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;
    try out.print("file: {s}\n", .{input_path});
    try out.print("version: {}.{}\n", .{ inspection.header.version_major, inspection.header.version_minor });
    try out.print("spectra: {}\n", .{inspection.header.spectrum_count});
    try out.print("blocks: {}\n", .{inspection.header.block_count});
    try out.print("total peaks: {}\n", .{inspection.header.total_peaks});
    try out.print("block size: {}\n", .{inspection.header.block_size});
    try out.print("ms1 blocks: {}\n", .{inspection.ms1_block_count});
    try out.print("ms2 blocks: {}\n", .{inspection.ms2_block_count});
    try out.print("ms1 spectra: {}\n", .{inspection.ms1_spectra});
    try out.print("ms2 spectra: {}\n", .{inspection.ms2_spectra});
    inline for (std.meta.fields(codec.FileByteBreakdown)) |field| {
        const label = comptime blk: {
            var name: [field.name.len]u8 = field.name[0..field.name.len].*;
            std.mem.replaceScalar(u8, &name, '_', ' ');
            break :blk name;
        };
        try out.print(label ++ ": {}\n", .{@field(inspection.byte_breakdown, field.name)});
    }

    if (show_blocks) {
        try out.writeByte('\n');
        try printBlockTable(out, inspection);
    }
    try out.flush();
}

fn Mismatch(comptime T: type) type {
    return struct { spectrum: usize, expected: T, got: T };
}

fn PeakMismatch(comptime T: type) type {
    return struct { spectrum: usize, peak: usize, expected: T, got: T };
}

/// Prints the spectrum-count line and reports whether both sides hold the same count.
fn checkSpectrumCount(io: std.Io, expected: usize, got: usize, verbose: bool) bool {
    if (expected != got) {
        if (verbose) printStdout(io, "FAIL spectrum_count expected={} got={}\n", .{ expected, got });
        return false;
    }
    if (verbose) printStdout(io, "PASS spectrum_count {}\n", .{expected});
    return true;
}

/// The lossless comparison, fed one spectrum pair at a time. It keeps the first failure of each
/// field, so the report needs no spectrum held.
const LosslessCheck = struct {
    index: usize = 0,
    scan_id: ?Mismatch(u32) = null,
    rt_seconds: ?Mismatch(f32) = null,
    ms_level: ?Mismatch(u8) = null,
    precursor_mz: ?Mismatch(f64) = null,
    peak_count: ?Mismatch(usize) = null,
    mz: ?PeakMismatch(f64) = null,
    intensity: ?PeakMismatch(f32) = null,

    fn add(self: *LosslessCheck, o: binary_reader.RawSpectrum, d: binary_reader.RawSpectrum) void {
        const si = self.index;
        self.index += 1;
        if (self.scan_id == null and o.scan_id != d.scan_id) {
            self.scan_id = .{ .spectrum = si, .expected = o.scan_id, .got = d.scan_id };
        }
        if (self.rt_seconds == null and @as(u32, @bitCast(o.rt_seconds)) != @as(u32, @bitCast(d.rt_seconds))) {
            self.rt_seconds = .{ .spectrum = si, .expected = o.rt_seconds, .got = d.rt_seconds };
        }
        if (self.ms_level == null and o.ms_level != d.ms_level) {
            self.ms_level = .{ .spectrum = si, .expected = o.ms_level, .got = d.ms_level };
        }
        if (self.precursor_mz == null and @as(u64, @bitCast(o.precursor_mz)) != @as(u64, @bitCast(d.precursor_mz))) {
            self.precursor_mz = .{ .spectrum = si, .expected = o.precursor_mz, .got = d.precursor_mz };
        }
        if (self.peak_count == null and (o.mz.len != d.mz.len or o.intensity.len != d.intensity.len or o.mz.len != o.intensity.len)) {
            self.peak_count = .{ .spectrum = si, .expected = o.mz.len, .got = d.mz.len };
        }
        // Peak values are compared only while every spectrum so far had matching counts.
        if (self.peak_count != null) return;
        if (self.mz == null) {
            for (o.mz, d.mz, 0..) |om, dm, pi| {
                if (@as(u64, @bitCast(om)) != @as(u64, @bitCast(dm))) {
                    self.mz = .{ .spectrum = si, .peak = pi, .expected = om, .got = dm };
                    break;
                }
            }
        }
        if (self.intensity == null) {
            for (o.intensity, d.intensity, 0..) |oi, di, pi| {
                if (@as(u32, @bitCast(oi)) != @as(u32, @bitCast(di))) {
                    self.intensity = .{ .spectrum = si, .peak = pi, .expected = oi, .got = di };
                    break;
                }
            }
        }
    }

    fn passed(self: LosslessCheck) bool {
        return self.scan_id == null and self.rt_seconds == null and self.ms_level == null and
            self.precursor_mz == null and self.peak_count == null and self.mz == null and
            self.intensity == null;
    }

    fn print(self: LosslessCheck, io: std.Io) void {
        if (self.scan_id) |f| {
            printStdout(io, "FAIL scan_id spectrum={} expected={} got={}\n", .{ f.spectrum, f.expected, f.got });
        } else printStdout(io, "PASS scan_id_exact\n", .{});

        if (self.rt_seconds) |f| {
            printStdout(io, "FAIL rt_seconds spectrum={} expected={e} got={e}\n", .{ f.spectrum, f.expected, f.got });
        } else printStdout(io, "PASS rt_seconds_exact\n", .{});

        if (self.ms_level) |f| {
            printStdout(io, "FAIL ms_level spectrum={} expected={} got={}\n", .{ f.spectrum, f.expected, f.got });
        } else printStdout(io, "PASS ms_level_exact\n", .{});

        if (self.precursor_mz) |f| {
            printStdout(io, "FAIL precursor_mz spectrum={} expected={d} got={d}\n", .{ f.spectrum, f.expected, f.got });
        } else printStdout(io, "PASS precursor_mz_exact\n", .{});

        if (self.peak_count) |f| {
            printStdout(io, "FAIL peak_count spectrum={} expected={} got={}\n", .{ f.spectrum, f.expected, f.got });
        } else printStdout(io, "PASS peak_count_exact\n", .{});

        if (self.mz) |f| {
            printStdout(io, "FAIL mz_round_trip spectrum={} peak={} expected={d} got={d}\n", .{ f.spectrum, f.peak, f.expected, f.got });
        } else printStdout(io, "PASS mz_round_trip exact\n", .{});

        if (self.intensity) |f| {
            printStdout(io, "FAIL intensity_round_trip spectrum={} peak={} expected={e} got={e}\n", .{ f.spectrum, f.peak, f.expected, f.got });
        } else printStdout(io, "PASS intensity_round_trip exact\n", .{});
    }
};

/// The lossy comparison, fed one spectrum pair at a time.
const LossyCheck = struct {
    /// mzML lossy archives keep some arrays exact, so a bit-identical peak value also passes.
    exact_allowed: bool,
    index: usize = 0,
    metadata_fail: ?usize = null,
    peak_count_mismatch: bool = false,
    numeric_domain_mismatch: bool = false,
    mz_quantization_mismatch: bool = false,
    mz_max: f64 = 0.0,
    intensity_log_max: f64 = 0.0,

    fn add(self: *LossyCheck, o: binary_reader.RawSpectrum, d: binary_reader.RawSpectrum) void {
        const si = self.index;
        self.index += 1;
        if (self.metadata_fail == null and (o.scan_id != d.scan_id or o.ms_level != d.ms_level or
            @as(u32, @bitCast(o.rt_seconds)) != @as(u32, @bitCast(d.rt_seconds)) or
            @as(u64, @bitCast(o.precursor_mz)) != @as(u64, @bitCast(d.precursor_mz))))
        {
            self.metadata_fail = si;
        }
        // The first peak-count mismatch ends the peak checks; the report fails on it alone.
        if (self.peak_count_mismatch) return;
        if (o.mz.len != d.mz.len or o.intensity.len != d.intensity.len or o.mz.len != o.intensity.len) {
            self.peak_count_mismatch = true;
            return;
        }
        for (o.mz, d.mz, o.intensity, d.intensity) |om, dm, oi, di| self.addPeak(om, dm, oi, di);
    }

    fn addPeak(self: *LossyCheck, om: f64, dm: f64, oi: f32, di: f32) void {
        const mz_exact = self.exact_allowed and @as(u64, @bitCast(om)) == @as(u64, @bitCast(dm));
        if (!mz_exact) {
            if (!std.math.isFinite(dm) or dm < 0.0) {
                self.numeric_domain_mismatch = true;
                return;
            }
            const quantized_mz = quantize.quantizeMzValue(om, DEFAULT_ENCODE_OPTIONS.mz_scale_factor) catch {
                self.numeric_domain_mismatch = true;
                return;
            };
            const expected_mz = quantize.dequantizeMzValue(quantized_mz, DEFAULT_ENCODE_OPTIONS.mz_scale_factor) catch unreachable;
            if (@as(u64, @bitCast(dm)) != @as(u64, @bitCast(expected_mz))) self.mz_quantization_mismatch = true;
            self.mz_max = @max(self.mz_max, @abs(om - dm));
        }

        if (self.exact_allowed and @as(u32, @bitCast(oi)) == @as(u32, @bitCast(di))) return;
        if (!std.math.isFinite(oi) or !std.math.isFinite(di)) {
            self.numeric_domain_mismatch = true;
            return;
        }
        if (oi <= 0.0) {
            if (@as(u32, @bitCast(di)) != 0) self.numeric_domain_mismatch = true;
            return;
        }
        if (di <= 0.0) {
            self.numeric_domain_mismatch = true;
            return;
        }
        const original_log = std.math.log1p(@as(f64, oi));
        const decoded_log = std.math.log1p(@as(f64, di));
        self.intensity_log_max = @max(self.intensity_log_max, @abs(original_log - decoded_log));
    }

    fn report(self: LossyCheck, io: std.Io, intensity_quant: u16) bool {
        var all_pass = true;
        if (self.metadata_fail) |si| {
            printStdout(io, "FAIL metadata_exact spectrum={}\n", .{si});
            all_pass = false;
        } else printStdout(io, "PASS metadata_exact\n", .{});

        if (self.peak_count_mismatch) {
            printStdout(io, "FAIL peak_count_mismatch\n", .{});
            return false;
        }

        if (self.numeric_domain_mismatch) {
            printStdout(io, "FAIL numeric_domain\n", .{});
            return false;
        } else printStdout(io, "PASS numeric_domain\n", .{});

        if (self.mz_quantization_mismatch) {
            printStdout(io, "FAIL mz_quantized_values\n", .{});
            all_pass = false;
        } else printStdout(io, "PASS mz_quantized_values exact\n", .{});
        printStdout(io, "PASS mz_max_observed_error {d:.12} Da (nominal half-step {d:.9} Da plus f64 rounding)\n", .{ self.mz_max, LOSSY_MZ_HALF_STEP_DA });

        const max_log = std.math.log1p(@as(f64, std.math.floatMax(f32)));
        const stored_max: f32 = @floatCast(max_log);
        const quant: f64 = @floatFromInt(intensity_quant);
        const intensity_log_limit = @max(@as(f64, stored_max) / quant, @abs(max_log - @as(f64, stored_max))) + 1.0 / 8_388_608.0;
        if (self.intensity_log_max <= intensity_log_limit) {
            printStdout(io, "PASS intensity_log1p_max_error {d:.9} <= {d:.9} (format-wide, Q={})\n", .{ self.intensity_log_max, intensity_log_limit, intensity_quant });
        } else {
            printStdout(io, "FAIL intensity_log1p_max_error {d:.9} > {d:.9} (format-wide, Q={})\n", .{ self.intensity_log_max, intensity_log_limit, intensity_quant });
            all_pass = false;
        }
        return all_pass;
    }
};

/// Feeds every record pair to `check`. The counts already matched, so a side that ends early
/// or late changed while it was read.
fn compareRecords(
    allocator: std.mem.Allocator,
    orig: *binary_reader.RecordReader,
    dec: *binary_reader.RecordReader,
    check: anytype,
) !void {
    while (try orig.next(allocator)) |o| {
        const d = (try dec.next(allocator)) orelse return error.UnexpectedEndOfStream;
        check.add(o, d);
    }
    if (try dec.next(allocator) != null) return error.TrailingData;
}

/// Compares two dumps record by record; both are checked whole for structure first, so a
/// malformed dump prints nothing. Holds one record of each side at a time.
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

    const cwd = std.Io.Dir.cwd();
    const orig_file = try cwd.openFile(io, orig_path, .{});
    defer orig_file.close(io);
    const orig_count = try binary_reader.countRecords(io, orig_file, codec.MAX_FILE_SPECTRA, block.MAX_BLOCK_PEAKS);
    const dec_file = try cwd.openFile(io, dec_path, .{});
    defer dec_file.close(io);
    const dec_count = try binary_reader.countRecords(io, dec_file, codec.MAX_FILE_SPECTRA, block.MAX_BLOCK_PEAKS);
    if (!checkSpectrumCount(io, orig_count, dec_count, true)) return error.ValidationFailed;

    var orig_buffer: [64 * 1024]u8 = undefined;
    var orig = binary_reader.RecordReader.init(io, orig_file, &orig_buffer, block.MAX_BLOCK_PEAKS);
    defer orig.deinit(allocator);
    var dec_buffer: [64 * 1024]u8 = undefined;
    var dec = binary_reader.RecordReader.init(io, dec_file, &dec_buffer, block.MAX_BLOCK_PEAKS);
    defer dec.deinit(allocator);

    const all_pass = if (lossless_mode) blk: {
        var check: LosslessCheck = .{};
        try compareRecords(allocator, &orig, &dec, &check);
        check.print(io);
        break :blk check.passed();
    } else blk: {
        var check: LossyCheck = .{ .exact_allowed = mzml_lossy_mode };
        try compareRecords(allocator, &orig, &dec, &check);
        break :blk check.report(io, intensity_quant);
    };

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

        var check: LosslessCheck = .{};
        const same_count = checkSpectrumCount(io, orig.len, decoded.len, false);
        if (same_count) for (orig, decoded) |o, d| check.add(o, d);
        if (same_count and check.passed()) {
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
        printStdout(io, usage, .{});
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
