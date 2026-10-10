//! Dump V1 from mzML on zmz: the same records as tools/mzml_dump.py, without Python.
//! Spectra in source order; peaks sorted by m/z (stable) when the source is not.
//! `binary_reader.writeRecord` owns the record bytes.

const std = @import("std");
const mzml = @import("zmz").mzml;
const binary_reader = @import("binary_reader");

pub const Summary = struct {
    spectra: usize = 0,
    peaks: usize = 0,
    ms1: usize = 0,
    ms2: usize = 0,
    bytes: u64 = 0,
};

const MZ = mzml.model.Terms.MZ_ARRAY;
const INTENSITY = mzml.model.Terms.INTENSITY_ARRAY;

fn selectArray(_: ?*anyopaque, view: mzml.StreamReader.Selection) mzml.model.MetadataError!mzml.StreamReader.Payload {
    if (try view.node.parameter(view.groups, MZ) != null) return .retain;
    if (try view.node.parameter(view.groups, INTENSITY) != null) return .retain;
    return .skip;
}

fn selectRecord(_: ?*anyopaque, view: mzml.StreamReader.Selection) mzml.model.MetadataError!mzml.StreamReader.Payload {
    return if (view.node.kind == .spectrum) .retain else .skip;
}

pub fn dump(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !Summary {
    const input_file = try std.Io.Dir.cwd().openFile(io, input_path, .{});
    defer input_file.close(io);
    var input_buffer: [64 * 1024]u8 = undefined;
    var input = input_file.reader(io, &input_buffer);
    var reader = try mzml.StreamReader.init(allocator, &input.interface, .{
        .array_selector = .{ .select = selectArray, .select_record = selectRecord },
    });
    defer reader.deinit();
    errdefer if (reader.diagnostic()) |report| std.debug.print("{s}: {f}\n", .{ input_path, report });
    const header = try reader.readHeader();
    // Numpress decodes to f64; like pyteomics, values return to their declared precision.
    var decoded = mzml.DecodedArrays.init(allocator, .{ .numpress_precision = .declared });
    defer decoded.deinit();

    // A failed dump leaves an existing destination unchanged, as encode and decode do.
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, output_path, .{ .replace = true });
    defer atomic.deinit(io);
    var output_buffer: [64 * 1024]u8 = undefined;
    var output = atomic.file.writer(io, &output_buffer);
    const out = &output.interface;

    var mz: std.ArrayList(f64) = .empty;
    defer mz.deinit(allocator);
    var intensity: std.ArrayList(f32) = .empty;
    defer intensity.deinit(allocator);
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(allocator);

    var summary: Summary = .{};
    while (try reader.nextDecodedRecord(&decoded)) |record| {
        if (record.node.kind != .spectrum) continue;
        mz.clearRetainingCapacity();
        intensity.clearRetainingCapacity();
        for (0..decoded.len()) |position| {
            const array = decoded.get(position).?;
            const is_mz = array.role == .mz;
            switch (array.values) {
                inline else => |values| for (values) |value| {
                    const wide: f64 = if (@typeInfo(@TypeOf(value)) == .float) @floatCast(value) else @floatFromInt(value);
                    if (is_mz) try mz.append(allocator, wide) else try intensity.append(allocator, @floatCast(wide));
                },
            }
        }
        if (mz.items.len != intensity.items.len) return error.MismatchedPeakArrays;

        const ms_level = try record.msLevel(header.groups) orelse 0;
        try sortByMz(allocator, &order, mz.items, intensity.items);
        try binary_reader.writeRecord(out, .{
            .scan_id = try scanId(record),
            .rt_seconds = @floatCast(try retentionSeconds(record, header.groups)),
            .ms_level = std.math.cast(u8, ms_level) orelse return error.MsLevelOutOfRange,
            .precursor_mz = if (ms_level > 1) precursorMz(record, header.groups) else 0,
            .mz = mz.items,
            .intensity = intensity.items,
        });

        summary.bytes += 28 + 12 * mz.items.len;
        summary.spectra += 1;
        summary.peaks += mz.items.len;
        if (ms_level == 1) summary.ms1 += 1;
        if (ms_level == 2) summary.ms2 += 1;
    }
    try out.flush();
    try atomic.replace(io);
    return summary;
}

// The number after the first "scan=" that has digits, else the record's index.
fn scanId(record: mzml.model.Record) !u32 {
    var rest = record.id;
    while (std.mem.indexOf(u8, rest, "scan=")) |at| {
        rest = rest[at + "scan=".len ..];
        var digits: usize = 0;
        while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
        if (digits != 0) return std.fmt.parseInt(u32, rest[0..digits], 10);
    }
    const index = record.index orelse return error.MissingScanId;
    return std.math.cast(u32, index) orelse error.Overflow;
}

fn retentionSeconds(record: mzml.model.Record, groups: []const mzml.cv.Group) !f64 {
    if (record.scans().len == 0) return 0;
    const time = try record.scans()[0].scanStartTime(groups) orelse return 0;
    const unit = time.parameter.unit.name orelse return time.value;
    const minutes = std.mem.eql(u8, unit, "minute") or std.mem.eql(u8, unit, "minutes") or std.mem.eql(u8, unit, "min");
    return if (minutes) time.value * 60 else time.value;
}

fn precursorMz(record: mzml.model.Record, groups: []const mzml.cv.Group) f64 {
    if (record.precursors().len == 0) return 0;
    const ions = record.precursors()[0].selectedIons() catch return 0;
    if (ions.len == 0) return 0;
    const values = ions[0].selectedIonValues(groups) catch return 0;
    return if (values.mz) |mz| mz.value else 0;
}

// Stable sort by m/z, as numpy's mergesort argsort, only when the values are out of order.
fn sortByMz(allocator: std.mem.Allocator, order: *std.ArrayList(u32), mz: []f64, intensity: []f32) !void {
    if (mz.len < 2) return;
    var sorted = true;
    for (1..mz.len) |i| sorted = sorted and mz[i - 1] <= mz[i];
    if (sorted) return;
    order.clearRetainingCapacity();
    for (0..mz.len) |i| try order.append(allocator, @intCast(i));
    std.sort.block(u32, order.items, mz, struct {
        fn lessThan(values: []f64, a: u32, b: u32) bool {
            const x = values[a];
            const y = values[b];
            return x < y or (!std.math.isNan(x) and std.math.isNan(y));
        }
    }.lessThan);
    const mz_copy = try allocator.dupe(f64, mz);
    defer allocator.free(mz_copy);
    const intensity_copy = try allocator.dupe(f32, intensity);
    defer allocator.free(intensity_copy);
    for (order.items, 0..) |source, i| {
        mz[i] = mz_copy[source];
        intensity[i] = intensity_copy[source];
    }
}
