//! Builds the single-threaded mzarc CLI and its local correctness gates.
//!
//! Debug uses the native CPU and keeps symbols. ReleaseFast uses the architecture baseline and strips symbols.

const std = @import("std");

const FROZEN_SHA256 = "9d5a10167356db7afaa4e6c43832a7ea75a53e84dc74e679a881d5d8cf7cb2c6";
const FROZEN_BIN = "test/fixtures/frozen.bin";

pub fn build(b: *std.Build) void {
    switch (b.release_mode) {
        .safe, .small => std.process.fatal(
            "mzarc supports only Debug and ReleaseFast; use --release=fast",
            .{},
        ),
        else => {},
    }

    const host = b.graph.host;
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const release = optimize == .ReleaseFast;
    var release_query = host.query;
    release_query.cpu_model = .baseline;
    const release_target = b.resolveTargetQuery(release_query);
    const target = if (release) release_target else host;

    // --- Codec modules ---

    const binary_reader_module = b.createModule(.{
        .root_source_file = b.path("src/binary_reader.zig"),
    });
    const quantize_module = b.createModule(.{
        .root_source_file = b.path("src/quantize.zig"),
    });
    const bitpack_module = b.createModule(.{
        .root_source_file = b.path("src/bitpack.zig"),
    });
    const rans_module = b.createModule(.{
        .root_source_file = b.path("src/rans.zig"),
    });
    const crc32_module = b.createModule(.{
        .root_source_file = b.path("src/crc32.zig"),
    });
    const block_common_module = b.createModule(.{
        .root_source_file = b.path("src/block_common.zig"),
        .imports = &.{
            .{ .name = "binary_reader", .module = binary_reader_module },
            .{ .name = "rans", .module = rans_module },
        },
    });
    const block_encode_module = b.createModule(.{
        .root_source_file = b.path("src/block_encode.zig"),
        .imports = &.{
            .{ .name = "block_common", .module = block_common_module },
            .{ .name = "binary_reader", .module = binary_reader_module },
            .{ .name = "quantize", .module = quantize_module },
            .{ .name = "bitpack", .module = bitpack_module },
            .{ .name = "crc32", .module = crc32_module },
        },
    });
    const block_decode_module = b.createModule(.{
        .root_source_file = b.path("src/block_decode.zig"),
        .imports = &.{
            .{ .name = "block_common", .module = block_common_module },
            .{ .name = "binary_reader", .module = binary_reader_module },
            .{ .name = "quantize", .module = quantize_module },
            .{ .name = "bitpack", .module = bitpack_module },
            .{ .name = "rans", .module = rans_module },
            .{ .name = "crc32", .module = crc32_module },
        },
    });
    const block_module = b.createModule(.{
        .root_source_file = b.path("src/block.zig"),
        .imports = &.{
            .{ .name = "block_common", .module = block_common_module },
            .{ .name = "block_encode", .module = block_encode_module },
            .{ .name = "block_decode", .module = block_decode_module },
        },
    });
    const codec_module = b.createModule(.{
        .root_source_file = b.path("src/codec.zig"),
        .imports = &.{
            .{ .name = "binary_reader", .module = binary_reader_module },
            .{ .name = "block", .module = block_module },
        },
    });

    // --- CLI ---

    const mzarc_cli = b.addExecutable(.{
        .name = "mzarc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .strip = release,
            .omit_frame_pointer = false,
            .imports = &.{
                .{ .name = "binary_reader", .module = binary_reader_module },
                .{ .name = "block", .module = block_module },
                .{ .name = "codec", .module = codec_module },
                .{ .name = "quantize", .module = quantize_module },
                .{ .name = "rans", .module = rans_module },
            },
        }),
    });
    b.installArtifact(mzarc_cli);

    // --- Verification ---

    const test_roots = [_][]const u8{
        "test/test_binary_reader.zig",
        "test/test_quantize.zig",
        "test/test_bitpack.zig",
        "test/test_rans.zig",
        "test/test_crc32.zig",
        "src/crc32.zig",
        "test/test_block.zig",
        "test/test_codec.zig",
    };
    const test_step = b.step("test", "Run unit tests");
    for (test_roots) |test_root| {
        const test_suite = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_root),
                .target = target,
                .optimize = optimize,
                .single_threaded = true,
                .imports = &.{
                    .{ .name = "binary_reader", .module = binary_reader_module },
                    .{ .name = "quantize", .module = quantize_module },
                    .{ .name = "bitpack", .module = bitpack_module },
                    .{ .name = "rans", .module = rans_module },
                    .{ .name = "crc32", .module = crc32_module },
                    .{ .name = "block", .module = block_module },
                    .{ .name = "codec", .module = codec_module },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(test_suite).step);
    }

    const fixture_digest_command =
        "actual=$( (command -v sha256sum >/dev/null && sha256sum " ++
        FROZEN_BIN ++ " || shasum -a 256 " ++ FROZEN_BIN ++
        ") | awk '{print $1}' ); " ++
        "expected=" ++ FROZEN_SHA256 ++ "; " ++
        "if [ \"$actual\" = \"$expected\" ]; then echo 'PASS " ++
        FROZEN_BIN ++ " sha256 ok'; " ++
        "else echo \"FAIL " ++ FROZEN_BIN ++
        " expected=$expected got=$actual\"; exit 1; fi";
    const check_fixture_cmd = b.addSystemCommand(&.{
        "sh",
        "-c",
        fixture_digest_command,
    });
    check_fixture_cmd.addFileInput(b.path(FROZEN_BIN));
    b.step(
        "check-fixture",
        "Verify SHA-256 of test/fixtures/frozen.bin",
    ).dependOn(&check_fixture_cmd.step);

    const smoke_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/smoke_test.sh",
        "--mzarc",
        b.getInstallPath(.bin, "mzarc"),
    });
    smoke_cmd.step.dependOn(b.getInstallStep());
    smoke_cmd.step.dependOn(test_step);
    smoke_cmd.step.dependOn(&check_fixture_cmd.step);
    b.step("ci", "Run tests, fixture integrity, and CLI smoke checks").dependOn(&smoke_cmd.step);
}
