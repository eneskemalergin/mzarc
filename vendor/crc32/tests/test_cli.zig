//! Checks the exact executable supplied by the build, including its package version.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const USAGE =
    \\usage: zig-crc32 [--mode streaming|memory] [--chunk N] FILE
    \\       zig-crc32 --version
    \\       zig-crc32 --help
    \\
;

fn expectResult(result: std.process.RunResult, status: u8, stdout: []const u8, stderr: []const u8) !void {
    try std.testing.expectEqual(std.process.Child.Term{ .exited = status }, result.term);
    try std.testing.expectEqualStrings(stdout, result.stdout);
    try std.testing.expectEqualStrings(stderr, result.stderr);
}

fn runCli(allocator: std.mem.Allocator, arguments: []const []const u8) !std.process.RunResult {
    const argv = try allocator.alloc([]const u8, arguments.len + 1);
    defer allocator.free(argv);
    argv[0] = build_options.exe_path;
    @memcpy(argv[1..], arguments);
    return std.process.run(allocator, std.testing.io, .{ .argv = argv });
}

fn writeInput(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8, bytes: []const u8) ![]const u8 {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "[cli] - [zig-crc32]: version identifies the manifest and build mode" {
    const allocator = std.testing.allocator;
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ build_options.exe_path, "--version" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("", result.stderr);
    var recognized = false;
    inline for (.{ "portable", "x86_pclmul", "x86_vpclmul", "arm_crc", "arm_pmull" }) |backend| {
        const expected = "zig-crc32 " ++ build_options.version ++ " optimize=" ++ @tagName(builtin.mode) ++ " backend=" ++ backend ++ "\n";
        recognized = recognized or std.mem.eql(u8, expected, result.stdout);
    }
    try std.testing.expect(recognized);
}

test "[cli] - [zig-crc32]: both file modes emit the exact checksum and supplied path" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var large: [70_000]u8 = undefined;
    for (&large, 0..) |*byte, index| byte.* = @truncate(index * 131 + (index >> 7));
    const cases = [_]struct { bytes: []const u8, checksum: u32 }{
        .{ .bytes = "", .checksum = 0 },
        .{ .bytes = "123456789", .checksum = 0xcbf4_3926 },
        .{ .bytes = &large, .checksum = std.hash.Crc32.hash(&large) },
    };
    for (cases, 0..) |case, index| {
        const name = try std.fmt.allocPrint(allocator, "input with spaces {d}", .{index});
        const path = try writeInput(allocator, &tmp, name, case.bytes);
        const expected = try std.fmt.allocPrint(allocator, "{x:0>8}  {s}\n", .{ case.checksum, path });
        for ([_][]const []const u8{ &.{path}, &.{ "--mode", "memory", path }, &.{ "--chunk", "7", path } }) |args| {
            const result = try runCli(allocator, args);
            try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
            try std.testing.expectEqualStrings(expected, result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        }
    }
}

test "[cli] - [zig-crc32]: streaming chunks cross stack and folding sizes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bytes: [70_000]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index * 131 + (index >> 7));
    const path = try writeInput(allocator, &tmp, "binary", &bytes);
    const expected = try std.fmt.allocPrint(allocator, "{x:0>8}  {s}\n", .{ std.hash.Crc32.hash(&bytes), path });
    for ([_][]const u8{ "1", "7", "16", "31", "32", "33", "64", "65", "4096", "65536", "100000" }) |chunk| {
        const result = try runCli(allocator, &.{ "--mode", "streaming", "--chunk", chunk, path });
        try expectResult(result, 0, expected, "");
    }
}

test "[cli] - [zig-crc32]: help and invalid arguments have exact output and status" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try expectResult(try runCli(allocator, &.{"--help"}), 0, USAGE, "");
    const cases = [_][]const []const u8{
        &.{},
        &.{""},
        &.{"--unknown"},
        &.{"--mode"},
        &.{ "--mode", "unknown", "input" },
        &.{ "--mode", "memory" },
        &.{ "--mode", "memory", "--mode", "memory", "input" },
        &.{"--chunk"},
        &.{ "--chunk", "1" },
        &.{ "--chunk", "1", "--chunk", "1", "input" },
        &.{ "--chunk", "", "input" },
        &.{ "--chunk", "0", "input" },
        &.{ "--chunk", "-1", "input" },
        &.{ "--chunk", "+1", "input" },
        &.{ "--chunk", "1_000", "input" },
        &.{ "--chunk", "1.5", "input" },
        &.{ "--chunk", "18446744073709551616", "input" },
        &.{ "--mode", "memory", "--chunk", "1", "input" },
        &.{ "input", "extra" },
        &.{ "--help", "input" },
        &.{ "--version", "input" },
        &.{ "--help", "--help" },
        &.{ "--version", "--version" },
        &.{ "--help", "--version" },
        &.{ "--help", "--mode", "memory" },
        &.{ "--version", "--chunk", "7" },
        &.{ "--iterations", "1", "input" },
        &.{ "--expected", "cbf43926", "input" },
        &.{ "--mode", "one-shot", "input" },
    };
    for (cases) |args| {
        try expectResult(try runCli(allocator, args), 2, "", USAGE);
    }
}

test "[cli] - [zig-crc32]: missing files and directories report the path and cause" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const missing = try std.fmt.allocPrint(allocator, "{s}/missing", .{directory});
    const cases = [_]struct { path: []const u8, cause: []const u8 }{
        .{ .path = missing, .cause = "no such file" },
        .{ .path = directory, .cause = "is a directory" },
    };
    for (cases) |case| {
        const expected = try std.fmt.allocPrint(allocator, "zig-crc32: {s}: {s}\n", .{ case.path, case.cause });
        for ([_][]const u8{ "streaming", "memory" }) |mode| {
            try expectResult(try runCli(allocator, &.{ "--mode", mode, case.path }), 1, "", expected);
        }
    }
}

test "[cli] - [zig-crc32]: an unallocatable chunk reports failure before reading" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const chunk = try std.fmt.allocPrint(allocator, "{d}", .{std.math.maxInt(usize)});
    try expectResult(try runCli(allocator, &.{ "--chunk", chunk, "input" }), 1, "", "zig-crc32: input: out of memory\n");
}

test "[cli] - [zig-crc32]: escaped filenames occupy one unambiguous output line" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeInput(allocator, &tmp, "line\nreturn\rslash\\", "123456789");
    const expected = try std.fmt.allocPrint(allocator, "\\cbf43926  .zig-cache/tmp/{s}/line\\nreturn\\rslash\\\\\n", .{tmp.sub_path});
    for ([_][]const u8{ "streaming", "memory" }) |mode| {
        try expectResult(try runCli(allocator, &.{ "--mode", mode, path }), 0, expected, "");
    }
}

test "[cli] - [zig-crc32]: a reported-zero proc file is read to EOF in both modes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, "/proc/version", .{});
    defer file.close(std.testing.io);
    try std.testing.expectEqual(@as(u64, 0), (try file.stat(std.testing.io)).size);
    var reader = file.readerStreaming(std.testing.io, &.{});
    const bytes = try reader.interface.allocRemaining(allocator, .limited(4096));
    try std.testing.expect(bytes.len != 0);
    const expected = try std.fmt.allocPrint(allocator, "{x:0>8}  /proc/version\n", .{std.hash.Crc32.hash(bytes)});
    for ([_][]const u8{ "streaming", "memory" }) |mode| {
        try expectResult(try runCli(allocator, &.{ "--mode", mode, "/proc/version" }), 0, expected, "");
    }
}

test "[cli] - [zig-crc32]: finite pipes are read to EOF in both modes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    for ([_][]const u8{ "streaming", "memory" }) |mode| {
        var child = try std.process.spawn(io, .{
            .argv = &.{ build_options.exe_path, "--mode", mode, "/dev/stdin" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        defer child.kill(io);
        try child.stdin.?.writeStreamingAll(io, "1234");
        try child.stdin.?.writeStreamingAll(io, "56789");
        child.stdin.?.close(io);
        child.stdin = null;
        var stdout = child.stdout.?.readerStreaming(io, &.{});
        const output = try stdout.interface.allocRemaining(allocator, .limited(1024));
        defer allocator.free(output);
        var stderr = child.stderr.?.readerStreaming(io, &.{});
        const diagnostic = try stderr.interface.allocRemaining(allocator, .limited(1024));
        defer allocator.free(diagnostic);
        try expectResult(.{ .term = try child.wait(io), .stdout = output, .stderr = diagnostic }, 0, "cbf43926  /dev/stdin\n", "");
    }
}

test "[cli] - [zig-crc32]: checksum help and version fail when stdout cannot be written" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const full = try std.Io.Dir.openFileAbsolute(io, "/dev/full", .{ .mode = .write_only });
    defer full.close(io);
    for ([_][]const u8{ "/dev/null", "--help", "--version" }) |arg| {
        var child = try std.process.spawn(io, .{
            .argv = &.{ build_options.exe_path, arg },
            .stdin = .ignore,
            .stdout = .{ .file = full },
            .stderr = .pipe,
        });
        defer child.kill(io);
        var stderr = child.stderr.?.readerStreaming(io, &.{});
        const diagnostic = try stderr.interface.allocRemaining(allocator, .limited(1024));
        defer allocator.free(diagnostic);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, try child.wait(io));
        const reason = if (std.mem.eql(u8, arg, "--help")) "NoSpaceLeft" else "write failed";
        const expected = try std.fmt.allocPrint(allocator, "zig-crc32: standard output: {s}\n", .{reason});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, diagnostic);
    }
}
