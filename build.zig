const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const binary_reader_module = b.createModule(.{
        .root_source_file = b.path("src/binary_reader.zig"),
        .target = target,
        .optimize = optimize,
    });
    const quantize_module = b.createModule(.{
        .root_source_file = b.path("src/quantize.zig"),
        .target = target,
        .optimize = optimize,
    });
    const delta_module = b.createModule(.{
        .root_source_file = b.path("src/delta.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bitpack_module = b.createModule(.{
        .root_source_file = b.path("src/bitpack.zig"),
        .target = target,
        .optimize = optimize,
    });
    const block_v1_module = b.createModule(.{
        .root_source_file = b.path("src/block_v1.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "binary_reader", .module = binary_reader_module },
            .{ .name = "quantize", .module = quantize_module },
            .{ .name = "delta", .module = delta_module },
            .{ .name = "bitpack", .module = bitpack_module },
        },
    });
    const codec_v1_module = b.createModule(.{
        .root_source_file = b.path("src/codec_v1.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "binary_reader", .module = binary_reader_module },
            .{ .name = "block_v1", .module = block_v1_module },
        },
    });

    const exe = b.addExecutable(.{
        .name = "mzarc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "binary_reader", .module = binary_reader_module },
                .{ .name = "codec_v1", .module = codec_v1_module },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the mzarc CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const test_files = [_][]const u8{
        "test/test_binary_reader.zig",
        "test/test_quantize.zig",
        "test/test_delta.zig",
        "test/test_bitpack.zig",
        "test/test_block_v1.zig",
        "test/test_codec_v1.zig",
    };

    const test_step = b.step("test", "Run unit tests");
    for (test_files) |file| {
        const unit_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "binary_reader", .module = binary_reader_module },
                    .{ .name = "quantize", .module = quantize_module },
                    .{ .name = "delta", .module = delta_module },
                    .{ .name = "bitpack", .module = bitpack_module },
                    .{ .name = "block_v1", .module = block_v1_module },
                    .{ .name = "codec_v1", .module = codec_v1_module },
                },
            }),
        });

        const run_unit_test = b.addRunArtifact(unit_test);
        test_step.dependOn(&run_unit_test.step);
    }
}
