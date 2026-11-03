//! Checksums one file in memory or through a bounded streaming buffer.
//!
//! Successful output is an eight-digit CRC, two spaces, and the supplied path.
//! Paths containing a backslash, newline, or carriage return use a leading
//! backslash before the CRC and escaped path bytes. Usage errors exit 2;
//! input, allocation, and output errors exit 1.

const std = @import("std");
const builtin = @import("builtin");
const crc32 = @import("crc32");
const build_options = @import("build_options");

pub const std_options: std.Options = .{
    .signal_stack_size = if (std.debug.default_enable_segfault_handler)
        (std.Options{}).signal_stack_size
    else
        null,
};

const Io = std.Io;
const STREAM_BUFFER_SIZE: usize = 64 * 1024;
const USAGE =
    \\usage: zig-crc32 [--mode streaming|memory] [--chunk N] FILE
    \\       zig-crc32 --version
    \\       zig-crc32 --help
    \\
;

pub fn main(init: std.process.Init.Minimal) u8 {
    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const allocator = std.heap.page_allocator;
    var args = std.process.Args.Iterator.initAllocator(init.args, allocator) catch |err|
        return fail(io, "arguments", err);
    defer args.deinit();
    _ = args.next();

    const command = parseArgs(&args) catch {
        Io.File.stderr().writeStreamingAll(io, USAGE) catch {};
        return 2;
    };
    switch (command) {
        .help => {
            Io.File.stdout().writeStreamingAll(io, USAGE) catch |err|
                return fail(io, "standard output", err);
        },
        .version => {
            var buffer: [128]u8 = undefined;
            var stdout = Io.File.stdout().writer(io, &buffer);
            stdout.interface.print("zig-crc32 {s} optimize={t} backend={t}\n", .{
                build_options.version,
                builtin.mode,
                crc32.backendFor(std.math.maxInt(usize)),
            }) catch |err| return fail(io, "standard output", err);
            stdout.interface.flush() catch |err| return fail(io, "standard output", err);
        },
        .run => |request| {
            const checksum = switch (request.mode) {
                .streaming => checksumStreaming(allocator, io, request.path, request.chunk_size),
                .memory => checksumMemory(allocator, io, request.path),
            } catch |err| return fail(io, request.path, err);
            var buffer: [256]u8 = undefined;
            var stdout = Io.File.stdout().writer(io, &buffer);
            writeResult(&stdout.interface, checksum, request.path) catch |err|
                return fail(io, "standard output", err);
            stdout.interface.flush() catch |err| return fail(io, "standard output", err);
        },
    }
    return 0;
}

const Mode = enum { streaming, memory };
const Request = struct { mode: Mode, chunk_size: usize, path: []const u8 };
const Command = union(enum) { help, version, run: Request };

fn parseArgs(args: *std.process.Args.Iterator) error{InvalidArguments}!Command {
    var mode: ?Mode = null;
    var chunk_size: ?usize = null;
    var path: ?[]const u8 = null;
    var special: ?Command = null;
    var count: usize = 0;
    while (args.next()) |arg| : (count += 1) {
        if (std.mem.eql(u8, arg, "--help")) {
            special = .help;
        } else if (std.mem.eql(u8, arg, "--version")) {
            special = .version;
        } else if (std.mem.eql(u8, arg, "--mode")) {
            if (mode != null) return error.InvalidArguments;
            mode = std.meta.stringToEnum(Mode, args.next() orelse return error.InvalidArguments) orelse
                return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--chunk")) {
            if (chunk_size != null) return error.InvalidArguments;
            chunk_size = try parseChunk(args.next() orelse return error.InvalidArguments);
        } else if (arg.len == 0 or arg[0] == '-' or path != null) {
            return error.InvalidArguments;
        } else {
            path = arg;
        }
    }
    if (special) |selected| return if (count == 1) selected else error.InvalidArguments;
    const selected_mode = mode orelse .streaming;
    if (chunk_size != null and selected_mode != .streaming) return error.InvalidArguments;
    return .{ .run = .{
        .mode = selected_mode,
        .chunk_size = chunk_size orelse STREAM_BUFFER_SIZE,
        .path = path orelse return error.InvalidArguments,
    } };
}

fn parseChunk(text: []const u8) error{InvalidArguments}!usize {
    if (text.len == 0) return error.InvalidArguments;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidArguments;
    const value = std.fmt.parseInt(usize, text, 10) catch return error.InvalidArguments;
    return if (value == 0) error.InvalidArguments else value;
}

fn checksumStreaming(allocator: std.mem.Allocator, io: Io, path: []const u8, chunk_size: usize) !u32 {
    var stack_buffer: [STREAM_BUFFER_SIZE]u8 = undefined;
    const heap_buffer = if (chunk_size > stack_buffer.len) try allocator.alloc(u8, chunk_size) else null;
    defer if (heap_buffer) |buffer| allocator.free(buffer);
    const buffer = heap_buffer orelse stack_buffer[0..chunk_size];
    const file = try openInput(io, path);
    defer file.close(io);
    var stream: crc32.Stream = .{};
    while (true) {
        const amount = file.readStreaming(io, &.{buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        stream.update(buffer[0..amount]);
    }
    return stream.final();
}

fn checksumMemory(allocator: std.mem.Allocator, io: Io, path: []const u8) !u32 {
    const file = try openInput(io, path);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind == .file and stat.size != 0) {
        const length = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
        const bytes = try allocator.alloc(u8, length);
        defer allocator.free(bytes);
        const amount = try file.readPositionalAll(io, bytes, 0);
        if (amount != length) return error.InputChanged;
        return crc32.hash(bytes);
    }
    var reader = file.readerStreaming(io, &.{});
    const bytes = reader.interface.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => return err,
    };
    defer allocator.free(bytes);
    return crc32.hash(bytes);
}

fn openInput(io: Io, path: []const u8) !Io.File {
    const file = if (std.fs.path.isAbsolute(path))
        try Io.Dir.openFileAbsolute(io, path, .{})
    else
        try Io.Dir.cwd().openFile(io, path, .{});
    errdefer file.close(io);
    if ((try file.stat(io)).kind == .directory) return error.IsDir;
    return file;
}

fn writeResult(writer: *Io.Writer, checksum: u32, path: []const u8) !void {
    const escaped = std.mem.indexOfAny(u8, path, "\\\n\r") != null;
    if (escaped) try writer.writeByte('\\');
    try writer.print("{x:0>8}  ", .{checksum});
    if (escaped) {
        for (path) |byte| {
            switch (byte) {
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                else => try writer.writeByte(byte),
            }
        }
    } else {
        try writer.writeAll(path);
    }
    try writer.writeByte('\n');
}

fn fail(io: Io, subject: []const u8, err: anyerror) u8 {
    @branchHint(.cold);
    const reason = switch (err) {
        error.FileNotFound => "no such file",
        error.IsDir => "is a directory",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.OutOfMemory => "out of memory",
        error.FileTooBig => "file too large for memory mode",
        error.InputChanged => "file ended before its recorded size",
        error.WriteFailed => "write failed",
        error.BrokenPipe => "broken pipe",
        else => @errorName(err),
    };
    var buffer: [512]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buffer);
    stderr.interface.print("zig-crc32: {s}: {s}\n", .{ subject, reason }) catch {};
    stderr.interface.flush() catch {};
    return 1;
}
