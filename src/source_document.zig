//! Source-document archives (format 1.0, section 11): a complete mzML document in `.mzarc`.
//! Exact mode stores the source bytes in one zlib stream. Lossy mode stores a record stream:
//! untouched source spans, eligible spectrum arrays as compact codes (profile 1), and
//! placeholders for `encodedLength`, index offsets, `indexListOffset`, and `fileChecksum`, which
//! decode rebuilds for the new byte positions. Both decode through one forward pass.

const std = @import("std");
const mzml = @import("zmz").mzml;
const crc32 = @import("crc32");
const quantize = @import("quantize");
const codec = @import("codec");

const Allocator = std.mem.Allocator;
const zlib = mzml.zlib;
const Primitive = @FieldType(mzml.model.Encoding, "primitive");
const Pipeline = @FieldType(mzml.model.Encoding, "pipeline");

pub const flag_source_document: u32 = 1 << 4;
const mzml_namespace = "http://psi.hupo.org/ms/mzml";
const codec_zlib: u16 = 1;
const profile_exact: u16 = 0;
const profile_lossy_1: u16 = 1;

const mz_scale: u32 = 500_000;
pub const intensity_levels: u16 = 16_384;

// Limits: one array's decoded values, the raw span held before an array, parameter groups kept
// from the header, element positions, and how far a source index value may sit before its element.
const max_array_bytes = 8 * 1024 * 1024;
const max_array_values = max_array_bytes / @sizeOf(f64);
const max_held_raw = 1024 * 1024;
const max_groups = 4096;
const max_positions = 1_000_000;
const max_offset_slack = 64;

const Tag = enum(u8) {
    end = 0,
    raw = 1,
    array = 2,
    encoded_length = 3,
    mark = 4,
    index_list_mark = 5,
    offset = 6,
    index_list_offset = 7,
    file_checksum = 8,
};

const Kind = enum(u8) { mz = 1, intensity = 2 };
const MzLayout = enum(u8) { absolute = 0, delta = 1 };

pub const Mode = enum { exact, lossy };

pub const Header = struct {
    mode: Mode,
    stream_len: u64,
    stream_crc: u32,

    pub fn encode(self: Header) [codec.header_len]u8 {
        var bytes: [codec.header_len]u8 = @splat(0);
        bytes[0..4].* = codec.magic;
        std.mem.writeInt(u16, bytes[4..6], codec.version_major, .little);
        std.mem.writeInt(u16, bytes[6..8], codec.version_minor, .little);
        const lossless: u32 = if (self.mode == .exact) codec.flag_lossless else 0;
        std.mem.writeInt(u32, bytes[8..12], flag_source_document | lossless, .little);
        std.mem.writeInt(u16, bytes[12..14], codec_zlib, .little);
        std.mem.writeInt(u16, bytes[14..16], if (self.mode == .exact) profile_exact else profile_lossy_1, .little);
        std.mem.writeInt(u32, bytes[16..20], self.stream_crc, .little);
        std.mem.writeInt(u64, bytes[24..32], self.stream_len, .little);
        return bytes;
    }

    pub fn decode(bytes: *const [codec.header_len]u8) !Header {
        if (!std.mem.eql(u8, bytes[0..4], &codec.magic)) return error.InvalidMagic;
        if (std.mem.readInt(u16, bytes[4..6], .little) != codec.version_major or
            std.mem.readInt(u16, bytes[6..8], .little) != codec.version_minor) return error.UnsupportedVersion;
        const flags = std.mem.readInt(u32, bytes[8..12], .little);
        if (flags & ~(flag_source_document | codec.flag_lossless) != 0 or flags & flag_source_document == 0) return error.InvalidFlags;
        const mode: Mode = if (flags & codec.flag_lossless != 0) .exact else .lossy;
        if (std.mem.readInt(u16, bytes[12..14], .little) != codec_zlib) return error.UnsupportedCodec;
        const profile = std.mem.readInt(u16, bytes[14..16], .little);
        if (profile != if (mode == .exact) profile_exact else profile_lossy_1) return error.UnsupportedProfile;
        if (std.mem.readInt(u32, bytes[20..24], .little) != 0) return error.NonzeroReserved;
        return .{
            .mode = mode,
            .stream_crc = std.mem.readInt(u32, bytes[16..20], .little),
            .stream_len = std.mem.readInt(u64, bytes[24..32], .little),
        };
    }
};

/// Whether a `.mzarc` header announces a source-document archive.
pub fn isSourceDocument(bytes: *const [codec.header_len]u8) bool {
    return std.mem.eql(u8, bytes[0..4], &codec.magic) and
        std.mem.readInt(u32, bytes[8..12], .little) & flag_source_document != 0;
}

pub const Summary = struct {
    mode: Mode,
    source_bytes: u64 = 0,
    archive_bytes: u64 = 0,
    output_bytes: u64 = 0,
    arrays_coded: u64 = 0,
    arrays_kept: u64 = 0,
    /// Source index entries that pointed into the whitespace before their element.
    offsets_corrected: u64 = 0,
};

// ---------------------------------------------------------------------------------------------
// Shared stream plumbing

/// A writer that counts and CRCs the bytes it forwards to the compressor.
const StreamHasher = struct {
    interface: std.Io.Writer,
    next: *std.Io.Writer,
    crc: crc32.Stream = .init(0),
    length: u64 = 0,

    fn init(next: *std.Io.Writer, buffer: []u8) StreamHasher {
        return .{ .next = next, .interface = .{ .buffer = buffer, .vtable = &.{ .drain = drain } } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *StreamHasher = @alignCast(@fieldParentPtr("interface", w));
        try self.forward(w.buffered());
        w.end = 0;
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.forward(bytes);
            written += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try self.forward(last);
        return written + last.len * splat;
    }

    fn forward(self: *StreamHasher, bytes: []const u8) std.Io.Writer.Error!void {
        self.crc.update(bytes);
        self.length += bytes.len;
        try self.next.writeAll(bytes);
    }
};

/// Opens the destination and a hashed zlib stream behind the reserved header.
const ArchiveWriter = struct {
    atomic: std.Io.File.Atomic,
    file_buffer: [64 * 1024]u8 = undefined,
    file_writer: std.Io.File.Writer = undefined,
    compressor: zlib.Compressor,
    stream_buffer: [64 * 1024]u8 = undefined,
    stream: StreamHasher = undefined,

    fn open(self: *ArchiveWriter, io: std.Io, allocator: Allocator, path: []const u8) !void {
        self.atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
        errdefer self.atomic.deinit(io);
        self.compressor = try zlib.Compressor.init(allocator, .dense);
        errdefer self.compressor.deinit();
        self.file_writer = self.atomic.file.writer(io, &self.file_buffer);
        try self.file_writer.interface.writeAll(&@as([codec.header_len]u8, @splat(0)));
        const compressed = try self.compressor.startWriter(&self.file_writer.interface);
        self.stream = .init(compressed, &self.stream_buffer);
    }

    fn deinit(self: *ArchiveWriter, io: std.Io) void {
        self.compressor.deinit();
        self.atomic.deinit(io);
    }

    fn finish(self: *ArchiveWriter, io: std.Io, mode: Mode) !u64 {
        try self.stream.interface.flush();
        try self.compressor.finishWriter();
        try self.file_writer.interface.flush();
        const header: Header = .{ .mode = mode, .stream_len = self.stream.length, .stream_crc = self.stream.crc.final() };
        try self.atomic.file.writePositionalAll(io, &header.encode(), 0);
        try self.atomic.replace(io);
        return self.file_writer.pos;
    }
};

// ---------------------------------------------------------------------------------------------
// Encode

pub fn encodeExact(io: std.Io, allocator: Allocator, input_path: []const u8, output_path: []const u8) !Summary {
    const input_file = try std.Io.Dir.cwd().openFile(io, input_path, .{});
    defer input_file.close(io);
    var input_buffer: [64 * 1024]u8 = undefined;
    var input = input_file.reader(io, &input_buffer);

    var archive: ArchiveWriter = undefined;
    try archive.open(io, allocator, output_path);
    defer archive.deinit(io);
    var source_bytes: u64 = 0;
    while (true) {
        const chunk = input.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try archive.stream.interface.writeAll(chunk);
        source_bytes += chunk.len;
        input.interface.toss(chunk.len);
    }
    const archive_bytes = try archive.finish(io, .exact);
    return .{ .mode = .exact, .source_bytes = source_bytes, .archive_bytes = archive_bytes };
}

/// What one parameter group or one binary array declares about its array.
const Terms = struct {
    primitive: ?Primitive = null,
    pipeline: ?Pipeline = null,
    role: ?Kind = null,
    other_role: bool = false,
    unsupported: bool = false,

    fn add(self: *Terms, accession: []const u8) void {
        if (mzml.model.encodingTerm(accession)) |declared| switch (declared) {
            .primitive => |p| self.primitive = p,
            .compression => |c| self.pipeline = c,
            .unsupported => self.unsupported = true,
        } else if (std.mem.eql(u8, accession, "MS:1000514")) {
            self.role = .mz;
        } else if (std.mem.eql(u8, accession, "MS:1000515")) {
            self.role = .intensity;
        } else if (isOtherArrayType(accession)) {
            self.other_role = true;
        }
    }

    fn merge(self: *Terms, other: Terms) void {
        if (other.primitive) |p| self.primitive = p;
        if (other.pipeline) |p| self.pipeline = p;
        if (other.role) |r| self.role = r;
        self.other_role = self.other_role or other.other_role;
        self.unsupported = self.unsupported or other.unsupported;
    }
};

// Array-type terms other than m/z and intensity; such an array stays raw.
fn isOtherArrayType(accession: []const u8) bool {
    const others = [_][]const u8{
        "MS:1000516", "MS:1000517", "MS:1000595", "MS:1000617", "MS:1000786", "MS:1000820",
        "MS:1000821", "MS:1000822", "MS:1002477", "MS:1002478", "MS:1002529", "MS:1002530",
        "MS:1002742", "MS:1002743", "MS:1002744", "MS:1002745", "MS:1002893", "MS:1003006",
        "MS:1003007", "MS:1003008",
    };
    for (others) |other| if (std.mem.eql(u8, accession, other)) return true;
    return false;
}

const Span = struct { start: u64, end: u64 };

const LossyEncoder = struct {
    allocator: Allocator,
    io: std.Io,
    source: std.Io.File,
    out: *std.Io.Writer,
    copied: u64 = 0,
    copy_buffer: [64 * 1024]u8 = undefined,
    positions: std.ArrayList(u64) = .empty,
    index_list_position: ?u64 = null,
    groups: std.StringHashMapUnmanaged(Terms) = .empty,
    summary: Summary = .{ .mode = .lossy },

    fn deinit(self: *LossyEncoder) void {
        self.positions.deinit(self.allocator);
        var keys = self.groups.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.groups.deinit(self.allocator);
    }

    fn tag(self: *LossyEncoder, value: Tag) !void {
        try self.out.writeByte(@intFromEnum(value));
    }

    /// Emits the source bytes from the last copied position to `end` as one raw record.
    fn rawTo(self: *LossyEncoder, end: u64) !void {
        if (end < self.copied) return error.SpanOrder;
        if (end == self.copied) return;
        try self.tag(.raw);
        try self.out.writeInt(u64, end - self.copied, .little);
        while (self.copied < end) {
            const want: usize = @intCast(@min(self.copy_buffer.len, end - self.copied));
            const got = try self.source.readPositionalAll(self.io, self.copy_buffer[0..want], self.copied);
            if (got != want) return error.UnexpectedEndOfStream;
            try self.out.writeAll(self.copy_buffer[0..want]);
            self.copied += want;
        }
    }

    fn readSource(self: *LossyEncoder, buffer: []u8, span: Span) ![]u8 {
        const len = std.math.cast(usize, span.end - span.start) orelse return error.TagTooLong;
        if (len > buffer.len) return error.TagTooLong;
        const got = try self.source.readPositionalAll(self.io, buffer[0..len], span.start);
        if (got != len) return error.UnexpectedEndOfStream;
        return buffer[0..len];
    }

    /// Whether a source index value names `position`: exactly, or at most `max_offset_slack` bytes
    /// before it with only XML whitespace in between.
    fn resolve(self: *LossyEncoder, value: u64, position: u64) !bool {
        if (value == position) return true;
        if (value > position or position - value > max_offset_slack) return false;
        var buffer: [max_offset_slack]u8 = undefined;
        const gap = try self.readSource(&buffer, .{ .start = value, .end = position });
        for (gap) |c| if (c != ' ' and c != '\t' and c != '\r' and c != '\n') return false;
        self.summary.offsets_corrected += 1;
        return true;
    }
};

/// Finds the digits of `name="..."` in a raw start tag; the span is relative to the tag.
pub fn attributeDigits(tag: []const u8, name: []const u8) ?struct { start: usize, end: usize } {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, tag, from, name)) |at| {
        from = at + name.len;
        // The name stands alone: whitespace before it, optional whitespace and `=` after it.
        if (at == 0 or !std.ascii.isWhitespace(tag[at - 1])) continue;
        var i = at + name.len;
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) i += 1;
        if (i >= tag.len or tag[i] != '=') continue;
        i += 1;
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) i += 1;
        if (i >= tag.len or (tag[i] != '"' and tag[i] != '\'')) return null;
        const quote = tag[i];
        const start = i + 1;
        var end = start;
        while (end < tag.len and std.ascii.isDigit(tag[end])) end += 1;
        if (end == start or end >= tag.len or tag[end] != quote) return null;
        return .{ .start = start, .end = end };
    }
    return null;
}

/// The decimal value inside a text event and the span of its digits, ignoring XML whitespace.
pub fn textDigits(text: []const u8, start: u64, end: u64) ?struct { value: u64, start: u64, end: u64 } {
    if (end - start != text.len) return null;
    var first: usize = 0;
    while (first < text.len and std.ascii.isWhitespace(text[first])) first += 1;
    var last = text.len;
    while (last > first and std.ascii.isWhitespace(text[last - 1])) last -= 1;
    if (last == first) return null;
    for (text[first..last]) |c| if (!std.ascii.isDigit(c)) return null;
    const value = std.fmt.parseInt(u64, text[first..last], 10) catch return null;
    return .{ .value = value, .start = start + first, .end = start + last };
}

/// Text runs of one element for `DecodedArrays.decodeArrayText`, recording their span.
const TextSource = struct {
    events: *mzml.Events,
    span: ?Span = null,

    pub fn next(self: *TextSource) !?[]const u8 {
        const event = (try self.events.next()) orelse return error.UnexpectedEnd;
        switch (event.data) {
            .text => |text| {
                if (self.span) |*s| s.end = event.span.end else self.span = .{ .start = event.span.start, .end = event.span.end };
                return text.bytes;
            },
            .end_element => return null,
            .start_element => return error.UnexpectedElement,
        }
    }

    fn skip(self: *TextSource) !void {
        while (try self.next()) |_| {}
    }
};

const Coded = union(Kind) {
    mz: []u64,
    intensity: struct { log_max: f32, codes: []u16 },
};

/// Codes an eligible array, or returns null when a value falls outside lossy profile 1.
fn codeArray(allocator: Allocator, kind: Kind, values: mzml.arrays.Values) !?Coded {
    switch (kind) {
        .mz => {
            const source = switch (values) {
                .float64 => |v| v,
                else => return null,
            };
            const codes = try allocator.alloc(u64, source.len);
            for (source, codes) |value, *code| {
                code.* = quantize.quantizeMzValue(value, mz_scale) catch {
                    allocator.free(codes);
                    return null;
                };
            }
            return .{ .mz = codes };
        },
        .intensity => {
            const count = switch (values) {
                inline else => |v| v.len,
            };
            const narrow = try allocator.alloc(f32, count);
            defer allocator.free(narrow);
            switch (values) {
                .float32 => |v| @memcpy(narrow, v),
                .float64 => |v| for (v, narrow) |value, *out| {
                    out.* = @floatCast(value);
                },
                else => return null,
            }
            // Level 0 decodes to zero, so a negative value would lose its sign; such arrays stay raw.
            for (narrow) |value| if (!std.math.isFinite(value) or value < 0) return null;
            const log_max = quantize.intensityLogMax(narrow);
            const codes = try allocator.alloc(u16, narrow.len);
            errdefer allocator.free(codes);
            for (narrow, codes) |value, *code| code.* = try quantize.quantizeIntensityValueScaled(value, intensity_levels, log_max);
            return .{ .intensity = .{ .log_max = log_max, .codes = codes } };
        },
    }
}

fn freeCoded(allocator: Allocator, coded: Coded) void {
    switch (coded) {
        .mz => |codes| allocator.free(codes),
        .intensity => |i| allocator.free(i.codes),
    }
}

fn writeArrayRecord(out: *std.Io.Writer, coded: Coded, primitive: Primitive, pipeline: Pipeline) !void {
    try out.writeByte(@intFromEnum(Tag.array));
    try out.writeByte(@intFromEnum(@as(Kind, coded)));
    try out.writeByte(if (primitive == .float64) 1 else 0);
    try out.writeByte(if (pipeline == .zlib) 1 else 0);
    switch (coded) {
        .mz => |codes| {
            try out.writeInt(u32, @intCast(codes.len), .little);
            var increasing = true;
            for (1..codes.len) |i| increasing = increasing and codes[i] >= codes[i - 1];
            try out.writeByte(@intFromEnum(if (increasing) MzLayout.delta else MzLayout.absolute));
            if (increasing) {
                var previous: u64 = 0;
                for (codes) |code| {
                    var delta = code - previous;
                    while (delta >= 0x80) : (delta >>= 7) try out.writeByte(@as(u8, @truncate(delta)) | 0x80);
                    try out.writeByte(@truncate(delta));
                    previous = code;
                }
            } else {
                for (codes) |code| try out.writeInt(u64, code, .little);
            }
        },
        .intensity => |i| {
            try out.writeInt(u32, @intCast(i.codes.len), .little);
            try out.writeInt(u32, @bitCast(i.log_max), .little);
            for (i.codes) |code| try out.writeInt(u16, code, .little);
        },
    }
}

/// Which lossy profile an array falls under, or null when it stays raw.
fn eligible(in_spectrum: bool, terms: Terms, length: ?usize) ?Kind {
    if (!in_spectrum or terms.unsupported or terms.other_role) return null;
    const kind = terms.role orelse return null;
    const primitive = terms.primitive orelse return null;
    const pipeline = terms.pipeline orelse return null;
    if (pipeline != .none and pipeline != .zlib) return null;
    const count = length orelse return null;
    if (count == 0 or count > max_array_values) return null;
    return switch (kind) {
        // f32 m/z already sits on a grid finer than the lossy one, so it stays exact.
        .mz => if (primitive == .float64) .mz else null,
        .intensity => if (primitive == .float32 or primitive == .float64) .intensity else null,
    };
}

/// Lossy records splice ASCII digits and Base64 into source bytes, so the source must use an
/// ASCII-compatible encoding. UTF-16 shows itself in the first bytes: a byte-order mark, or a zero
/// byte beside the document's first `<`.
fn requireAsciiCompatible(io: std.Io, file: std.Io.File) !void {
    var head: [2]u8 = undefined;
    if (try file.readPositionalAll(io, &head, 0) < head.len) return;
    if ((head[0] == 0xFE and head[1] == 0xFF) or (head[0] == 0xFF and head[1] == 0xFE) or
        head[0] == 0 or head[1] == 0) return error.UnsupportedEncoding;
}

fn orderU64(key: u64, item: u64) std.math.Order {
    return std.math.order(key, item);
}

fn sha1Hex(sha: *mzml.sha1.Sha1) [40]u8 {
    const digest = sha.finalResult();
    var hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;
    return hex;
}

fn verifySourceChecksum(io: std.Io, file: std.Io.File, prefix_len: u64, hex: []const u8) !void {
    var sha: mzml.sha1.Sha1 = .{};
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < prefix_len) {
        const want: usize = @intCast(@min(buffer.len, prefix_len - offset));
        const got = try file.readPositionalAll(io, buffer[0..want], offset);
        if (got != want) return error.UnexpectedEndOfStream;
        sha.update(buffer[0..want]);
        offset += want;
    }
    if (!std.ascii.eqlIgnoreCase(&sha1Hex(&sha), hex)) return error.SourceChecksumMismatch;
}

pub fn encodeLossy(io: std.Io, allocator: Allocator, input_path: []const u8, output_path: []const u8) !Summary {
    const cwd = std.Io.Dir.cwd();
    const events_file = try cwd.openFile(io, input_path, .{});
    defer events_file.close(io);
    const source_file = try cwd.openFile(io, input_path, .{});
    defer source_file.close(io);
    const source_len = try source_file.length(io);
    try requireAsciiCompatible(io, source_file);
    var input_buffer: [64 * 1024]u8 = undefined;
    var input = events_file.reader(io, &input_buffer);

    var archive: ArchiveWriter = undefined;
    try archive.open(io, allocator, output_path);
    defer archive.deinit(io);

    var encoder: LossyEncoder = .{ .allocator = allocator, .io = io, .source = source_file, .out = &archive.stream.interface };
    defer encoder.deinit();
    var events = try mzml.Events.init(allocator, &input.interface, .{});
    defer events.deinit();
    errdefer if (events.diagnostic()) |report| std.debug.print("{s}: {f}\n", .{ input_path, report });
    var decoded = mzml.DecodedArrays.init(allocator, .{ .array_bytes = max_array_bytes, .record_array_bytes = max_array_bytes });
    defer decoded.deinit();

    var tag_buffer: [64 * 1024]u8 = undefined;
    var in_spectrum = false;
    var default_length: ?usize = null;
    var group_id: ?[]u8 = null;
    defer if (group_id) |id| allocator.free(id);
    var group_terms: Terms = .{};
    // `fixed` marks an array that must stay raw whatever its terms say.
    var array: ?struct { terms: Terms, length: ?usize, encoded_length: ?Span, fixed: bool } = null;
    var element: enum { none, offset, index_list_offset, file_checksum } = .none;

    while (try events.next()) |event| switch (event.data) {
        .start_element => |start| {
            const local = start.name.expanded.local;
            const span: Span = .{ .start = event.span.start, .end = event.span.end };
            if (std.mem.eql(u8, local, "mzML")) {
                // Drafts before 1.0 use their own namespace, array terms, and index layouts; lossy
                // mode supports the mzML 1.x namespace only.
                const namespace = start.name.expanded.namespace_uri orelse return error.UnsupportedVersion;
                if (!std.mem.eql(u8, namespace, mzml_namespace)) return error.UnsupportedVersion;
                if (start.attribute(null, "version")) |version| {
                    if (std.mem.startsWith(u8, version.value, "0.")) return error.UnsupportedVersion;
                }
            } else if (std.mem.eql(u8, local, "spectrum") or std.mem.eql(u8, local, "chromatogram")) {
                try encoder.rawTo(span.start);
                try encoder.tag(.mark);
                if (encoder.positions.items.len == max_positions) return error.TooManyRecords;
                try encoder.positions.append(allocator, span.start);
                in_spectrum = std.mem.eql(u8, local, "spectrum");
                default_length = null;
                if (start.attribute(null, "defaultArrayLength")) |a| default_length = std.fmt.parseInt(usize, a.value, 10) catch null;
            } else if (std.mem.eql(u8, local, "referenceableParamGroup")) {
                const id = (start.attribute(null, "id") orelse return error.MissingGroupId).value;
                if (group_id) |old| allocator.free(old);
                group_id = try allocator.dupe(u8, id);
                group_terms = .{};
            } else if (std.mem.eql(u8, local, "binaryDataArray")) {
                var length: ?usize = default_length;
                if (start.attribute(null, "arrayLength")) |a| length = std.fmt.parseInt(usize, a.value, 10) catch null;
                var encoded_length: ?Span = null;
                var fixed = false;
                if (start.attribute(null, "encodedLength") != null) {
                    // A value that is not plain digits cannot be rebuilt, so the array stays raw.
                    const raw = try encoder.readSource(&tag_buffer, span);
                    if (attributeDigits(raw, "encodedLength")) |d| {
                        encoded_length = .{ .start = span.start + d.start, .end = span.start + d.end };
                    } else fixed = true;
                }
                array = .{ .terms = .{}, .length = length, .encoded_length = encoded_length, .fixed = fixed };
            } else if (std.mem.eql(u8, local, "cvParam")) {
                const accession = (start.attribute(null, "accession") orelse continue).value;
                if (array) |*a| a.terms.add(accession) else if (group_id != null) group_terms.add(accession);
            } else if (std.mem.eql(u8, local, "referenceableParamGroupRef")) {
                if (array) |*a| {
                    const ref = (start.attribute(null, "ref") orelse return error.MissingGroupRef).value;
                    a.terms.merge(encoder.groups.get(ref) orelse return error.UnknownGroup);
                }
            } else if (std.mem.eql(u8, local, "binary")) {
                const a = array orelse return error.UnexpectedElement;
                if (start.empty_element_syntax) continue;
                var text: TextSource = .{ .events = &events };
                const kind = (if (a.fixed) null else eligible(in_spectrum, a.terms, a.length)) orelse {
                    try text.skip();
                    encoder.summary.arrays_kept += 1;
                    continue;
                };
                const values = try decoded.decodeArrayText(.{ .primitive = a.terms.primitive.?, .pipeline = a.terms.pipeline.? }, a.length.?, &text);
                const text_span = text.span orelse {
                    encoder.summary.arrays_kept += 1;
                    continue;
                };
                const coded = (try codeArray(allocator, kind, values)) orelse {
                    encoder.summary.arrays_kept += 1;
                    continue;
                };
                defer freeCoded(allocator, coded);
                if (a.encoded_length) |digits| {
                    if (text_span.start - digits.end > max_held_raw) {
                        encoder.summary.arrays_kept += 1;
                        continue;
                    }
                    try encoder.rawTo(digits.start);
                    try encoder.tag(.encoded_length);
                    encoder.copied = digits.end;
                }
                try encoder.rawTo(text_span.start);
                try writeArrayRecord(encoder.out, coded, a.terms.primitive.?, a.terms.pipeline.?);
                encoder.copied = text_span.end;
                encoder.summary.arrays_coded += 1;
            } else if (std.mem.eql(u8, local, "indexList")) {
                try encoder.rawTo(span.start);
                try encoder.tag(.index_list_mark);
                encoder.index_list_position = span.start;
            } else if (std.mem.eql(u8, local, "offset")) {
                element = .offset;
            } else if (std.mem.eql(u8, local, "indexListOffset")) {
                element = .index_list_offset;
            } else if (std.mem.eql(u8, local, "fileChecksum")) {
                element = .file_checksum;
            }
        },
        .end_element => |end| {
            const local = end.name.expanded.local;
            if (std.mem.eql(u8, local, "binaryDataArray")) {
                array = null;
            } else if (std.mem.eql(u8, local, "referenceableParamGroup")) {
                const id = group_id orelse continue;
                if (encoder.groups.count() == max_groups) return error.TooManyGroups;
                const entry = try encoder.groups.getOrPut(allocator, id);
                if (entry.found_existing) return error.DuplicateGroup;
                entry.value_ptr.* = group_terms;
                group_id = null;
            } else if (std.mem.eql(u8, local, "spectrum") or std.mem.eql(u8, local, "chromatogram")) {
                in_spectrum = false;
            }
            element = .none;
        },
        .text => |text| switch (element) {
            .none => {},
            .offset => {
                const digits = textDigits(text.bytes, event.span.start, event.span.end) orelse return error.InvalidOffset;
                const ordinal = std.sort.lowerBound(u64, encoder.positions.items, digits.value, orderU64);
                if (ordinal == encoder.positions.items.len or !try encoder.resolve(digits.value, encoder.positions.items[ordinal]))
                    return error.SourceOffsetMismatch;
                try encoder.rawTo(digits.start);
                try encoder.tag(.offset);
                try encoder.out.writeInt(u32, @intCast(ordinal), .little);
                encoder.copied = digits.end;
            },
            .index_list_offset => {
                const digits = textDigits(text.bytes, event.span.start, event.span.end) orelse return error.InvalidOffset;
                const position = encoder.index_list_position orelse return error.SourceIndexListOffsetMismatch;
                if (!try encoder.resolve(digits.value, position)) return error.SourceIndexListOffsetMismatch;
                try encoder.rawTo(digits.start);
                try encoder.tag(.index_list_offset);
                encoder.copied = digits.end;
            },
            .file_checksum => {
                if (event.span.end - event.span.start != text.bytes.len) return error.InvalidChecksum;
                const hex = std.mem.trim(u8, text.bytes, " \t\r\n");
                if (hex.len != 40) return error.InvalidChecksum;
                const hex_start = event.span.start + (std.mem.indexOf(u8, text.bytes, hex) orelse unreachable);
                try verifySourceChecksum(io, source_file, hex_start, hex);
                try encoder.rawTo(hex_start);
                try encoder.tag(.file_checksum);
                encoder.copied = hex_start + hex.len;
            },
        },
    };
    try encoder.rawTo(source_len);
    try encoder.tag(.end);
    var summary = encoder.summary;
    summary.source_bytes = source_len;
    summary.archive_bytes = try archive.finish(io, .lossy);
    return summary;
}

// ---------------------------------------------------------------------------------------------
// Decode

/// Reads the decompressed stream with a CRC over everything read.
const StreamReader = struct {
    decompressor: *zlib.Decompressor,
    window: [64 * 1024]u8 = undefined,
    pending: []const u8 = &.{},
    crc: crc32.Stream = .init(0),
    length: u64 = 0,
    finished: bool = false,

    fn fill(self: *StreamReader) !void {
        if (self.pending.len != 0 or self.finished) return;
        if (try self.decompressor.read(&self.window)) |bytes| self.pending = bytes else self.finished = true;
    }

    /// Up to `len` next bytes; empty only at the end of the stream.
    fn take(self: *StreamReader, len: usize) ![]const u8 {
        try self.fill();
        const n = @min(len, self.pending.len);
        const bytes = self.pending[0..n];
        self.pending = self.pending[n..];
        self.crc.update(bytes);
        self.length += n;
        return bytes;
    }

    fn readExact(self: *StreamReader, out: []u8) !void {
        var filled: usize = 0;
        while (filled < out.len) {
            const bytes = try self.take(out.len - filled);
            if (bytes.len == 0) return error.TruncatedStream;
            @memcpy(out[filled..][0..bytes.len], bytes);
            filled += bytes.len;
        }
    }

    fn readInt(self: *StreamReader, comptime T: type) !T {
        var bytes: [@sizeOf(T)]u8 = undefined;
        try self.readExact(&bytes);
        return std.mem.readInt(T, &bytes, .little);
    }

    fn readLeb128(self: *StreamReader) !u64 {
        var value: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const byte = try self.readInt(u8);
            if (shift == 63 and byte > 1) return error.InvalidRecord;
            value |= @as(u64, byte & 0x7F) << shift;
            if (byte & 0x80 == 0) return value;
            if (shift == 63) return error.InvalidRecord;
            shift += 7;
        }
    }

    fn atEnd(self: *StreamReader) !bool {
        try self.fill();
        return self.pending.len == 0;
    }
};

/// The rebuilt document: counts bytes and hashes them for the file checksum.
const Output = struct {
    writer: *std.Io.Writer,
    position: u64 = 0,
    sha: mzml.sha1.Sha1 = .{},

    fn write(self: *Output, bytes: []const u8) !void {
        try self.writer.writeAll(bytes);
        self.sha.update(bytes);
        self.position += bytes.len;
    }

    fn digits(self: *Output, value: u64) !void {
        var buffer: [24]u8 = undefined;
        try self.write(std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable);
    }
};

// An empty level slot: all-ones bits are a NaN, which dequantization never returns.
const unset_level: u32 = 0xFFFF_FFFF;

const ArrayDecoder = struct {
    allocator: Allocator,
    encoder: mzml.arrays.Encoder,
    values64: std.ArrayList(f64) = .empty,
    values32: std.ArrayList(f32) = .empty,
    text: std.ArrayList(u8) = .empty,
    // Every peak at one level decodes to the same value, so each array computes each level once.
    // Only the slots an array filled are reset afterwards, so a short array costs only its length.
    levels: [intensity_levels + 1]u32 = @splat(unset_level),
    filled: std.ArrayList(u16) = .empty,

    fn deinit(self: *ArrayDecoder) void {
        self.encoder.deinit();
        self.values64.deinit(self.allocator);
        self.values32.deinit(self.allocator);
        self.text.deinit(self.allocator);
        self.filled.deinit(self.allocator);
    }

    /// Reads one array record after its tag and returns its Base64 text.
    fn read(self: *ArrayDecoder, stream: *StreamReader) ![]const u8 {
        const kind = std.enums.fromInt(Kind, try stream.readInt(u8)) orelse return error.InvalidRecord;
        const primitive: Primitive = switch (try stream.readInt(u8)) {
            0 => .float32,
            1 => .float64,
            else => return error.InvalidRecord,
        };
        const pipeline: Pipeline = switch (try stream.readInt(u8)) {
            0 => .none,
            1 => .zlib,
            else => return error.InvalidRecord,
        };
        const count = try stream.readInt(u32);
        if (count == 0 or count > max_array_values) return error.InvalidRecord;
        self.encoder.reset();
        const wire = switch (kind) {
            .mz => blk: {
                if (primitive != .float64) return error.InvalidRecord;
                try self.values64.resize(self.allocator, count);
                const layout = std.enums.fromInt(MzLayout, try stream.readInt(u8)) orelse return error.InvalidRecord;
                var previous: u64 = 0;
                for (self.values64.items) |*value| {
                    const code = switch (layout) {
                        .absolute => try stream.readInt(u64),
                        .delta => std.math.add(u64, previous, try stream.readLeb128()) catch return error.InvalidRecord,
                    };
                    previous = code;
                    value.* = try quantize.dequantizeMzValue(code, mz_scale);
                }
                break :blk try self.encoder.encode(f64, self.values64.items, .{ .pipeline = pipeline });
            },
            .intensity => blk: {
                const log_max: f32 = @bitCast(try stream.readInt(u32));
                try self.values32.resize(self.allocator, count);
                defer {
                    for (self.filled.items) |code| self.levels[code] = unset_level;
                    self.filled.clearRetainingCapacity();
                }
                for (self.values32.items) |*value| {
                    const code = try stream.readInt(u16);
                    if (code > intensity_levels) return error.InvalidRecord;
                    if (self.levels[code] == unset_level) {
                        self.levels[code] = @bitCast(try quantize.dequantizeIntensityValueScaled(code, intensity_levels, log_max));
                        try self.filled.append(self.allocator, code);
                    }
                    value.* = @bitCast(self.levels[code]);
                }
                if (primitive == .float32) break :blk try self.encoder.encode(f32, self.values32.items, .{ .pipeline = pipeline });
                try self.values64.resize(self.allocator, count);
                for (self.values32.items, self.values64.items) |narrow, *wide| wide.* = narrow;
                break :blk try self.encoder.encode(f64, self.values64.items, .{ .pipeline = pipeline });
            },
        };
        try self.text.resize(self.allocator, try mzml.base64.encodedSize(wire.len));
        return mzml.base64.encode(self.text.items, wire);
    }
};

/// Reads a source-document header from an open archive, checking the payload length.
fn openArchive(io: std.Io, file: std.Io.File, reader: *std.Io.File.Reader) !Header {
    var bytes: [codec.header_len]u8 = undefined;
    reader.interface.readSliceAll(&bytes) catch |err| switch (err) {
        error.EndOfStream => return error.UnexpectedEndOfStream,
        else => return err,
    };
    const header = try Header.decode(&bytes);
    if (try file.length(io) == codec.header_len) return error.UnexpectedEndOfStream;
    return header;
}

pub fn decode(io: std.Io, allocator: Allocator, input_path: []const u8, output_path: []const u8) !Summary {
    const cwd = std.Io.Dir.cwd();
    const input_file = try cwd.openFile(io, input_path, .{});
    defer input_file.close(io);
    var input_buffer: [64 * 1024]u8 = undefined;
    var input = input_file.reader(io, &input_buffer);
    const header = try openArchive(io, input_file, &input);

    var atomic = try cwd.createFileAtomic(io, output_path, .{ .replace = true });
    defer atomic.deinit(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer = atomic.file.writer(io, &file_buffer);
    var output: Output = .{ .writer = &file_writer.interface };

    var decompressor = try zlib.Decompressor.init(allocator);
    defer decompressor.deinit();
    decompressor.startReader(&input.interface);
    var stream: StreamReader = .{ .decompressor = &decompressor };

    switch (header.mode) {
        .exact => while (true) {
            const bytes = try stream.take(64 * 1024);
            if (bytes.len == 0) break;
            try file_writer.interface.writeAll(bytes);
            output.position += bytes.len;
        },
        .lossy => try decodeRecords(allocator, &stream, &output),
    }
    if (!try stream.atEnd()) return error.TrailingRecords;
    if (input.interface.peekByte()) |_| return error.TrailingFileData else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    if (stream.length != header.stream_len) return error.StreamLengthMismatch;
    if (stream.crc.final() != header.stream_crc) return error.StreamChecksumMismatch;
    try file_writer.interface.flush();
    try atomic.replace(io);
    return .{ .mode = header.mode, .archive_bytes = try input_file.length(io), .output_bytes = output.position };
}

fn decodeRecords(allocator: Allocator, stream: *StreamReader, output: *Output) !void {
    var arrays: ArrayDecoder = .{ .allocator = allocator, .encoder = .init(allocator, .fast) };
    defer arrays.deinit();
    var held: std.ArrayList(u8) = .empty;
    defer held.deinit(allocator);
    var positions: std.ArrayList(u64) = .empty;
    defer positions.deinit(allocator);
    var index_list: ?u64 = null;

    while (true) {
        const tag = std.enums.fromInt(Tag, try stream.readInt(u8)) orelse return error.InvalidRecord;
        switch (tag) {
            .end => return,
            .raw => {
                var remaining = try stream.readInt(u64);
                while (remaining > 0) {
                    const bytes = try stream.take(@intCast(@min(remaining, 64 * 1024)));
                    if (bytes.len == 0) return error.TruncatedStream;
                    try output.write(bytes);
                    remaining -= bytes.len;
                }
            },
            .array => try output.write(try arrays.read(stream)),
            .encoded_length => {
                // The digits precede the array text, so hold the raw span between them.
                if (std.enums.fromInt(Tag, try stream.readInt(u8)) != .raw) return error.InvalidRecord;
                const len = try stream.readInt(u64);
                if (len > max_held_raw) return error.InvalidRecord;
                try held.resize(allocator, @intCast(len));
                try stream.readExact(held.items);
                if (std.enums.fromInt(Tag, try stream.readInt(u8)) != .array) return error.InvalidRecord;
                const text = try arrays.read(stream);
                try output.digits(text.len);
                try output.write(held.items);
                try output.write(text);
            },
            .mark => {
                if (positions.items.len == max_positions) return error.InvalidRecord;
                try positions.append(allocator, output.position);
            },
            .index_list_mark => index_list = output.position,
            .offset => {
                const ordinal = try stream.readInt(u32);
                if (ordinal >= positions.items.len) return error.InvalidRecord;
                try output.digits(positions.items[ordinal]);
            },
            .index_list_offset => try output.digits(index_list orelse return error.InvalidRecord),
            .file_checksum => try output.write(&sha1Hex(&output.sha)),
        }
    }
}

/// Reads a source-document header for inspection.
pub fn inspect(io: std.Io, path: []const u8) !struct { header: Header, archive_bytes: u64 } {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [codec.header_len]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return .{ .header = try openArchive(io, file, &reader), .archive_bytes = try file.length(io) };
}
