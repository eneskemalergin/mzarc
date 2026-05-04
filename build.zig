const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const force_scalar = b.option(bool, "force_scalar", "Force scalar code paths (disable SIMD)") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "force_scalar", force_scalar);
    const build_options_module = build_options.createModule();
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
    const rans_module = b.createModule(.{
        .root_source_file = b.path("src/rans.zig"),
        .target = target,
        .optimize = optimize,
    });
    const block_common_module = b.createModule(.{
        .root_source_file = b.path("src/block_common.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_module },
            .{ .name = "binary_reader", .module = binary_reader_module },
            .{ .name = "quantize", .module = quantize_module },
            .{ .name = "bitpack", .module = bitpack_module },
            .{ .name = "rans", .module = rans_module },
        },
    });
    const block_encode_module = b.createModule(.{
        .root_source_file = b.path("src/block_encode.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_module },
            .{ .name = "block_common", .module = block_common_module },
            .{ .name = "binary_reader", .module = binary_reader_module },
            .{ .name = "quantize", .module = quantize_module },
            .{ .name = "bitpack", .module = bitpack_module },
            .{ .name = "rans", .module = rans_module },
        },
    });
    const block_decode_module = b.createModule(.{
        .root_source_file = b.path("src/block_decode.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_module },
            .{ .name = "block_common", .module = block_common_module },
            .{ .name = "binary_reader", .module = binary_reader_module },
            .{ .name = "quantize", .module = quantize_module },
            .{ .name = "bitpack", .module = bitpack_module },
            .{ .name = "rans", .module = rans_module },
        },
    });
    const block_module = b.createModule(.{
        .root_source_file = b.path("src/block.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "block_common", .module = block_common_module },
            .{ .name = "block_encode", .module = block_encode_module },
            .{ .name = "block_decode", .module = block_decode_module },
        },
    });
    const codec_module = b.createModule(.{
        .root_source_file = b.path("src/codec.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "binary_reader", .module = binary_reader_module },
            .{ .name = "block", .module = block_module },
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
                .{ .name = "block", .module = block_module },
                .{ .name = "codec", .module = codec_module },
                .{ .name = "rans", .module = rans_module },
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
        "test/test_rans.zig",
        "test/test_block.zig",
        "test/test_codec.zig",
    };

    const test_step = b.step("test", "Run unit tests");
    for (test_files) |file| {
        const unit_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "build_options", .module = build_options_module },
                    .{ .name = "binary_reader", .module = binary_reader_module },
                    .{ .name = "quantize", .module = quantize_module },
                    .{ .name = "delta", .module = delta_module },
                    .{ .name = "bitpack", .module = bitpack_module },
                    .{ .name = "rans", .module = rans_module },
                    .{ .name = "block", .module = block_module },
                    .{ .name = "codec", .module = codec_module },
                },
            }),
        });

        const run_unit_test = b.addRunArtifact(unit_test);
        test_step.dependOn(&run_unit_test.step);
    }

    // check-fixture: SHA-256 integrity check for test/fixtures/frozen.bin
    const check_fixture_step = b.step("check-fixture", "Verify SHA-256 of test/fixtures/frozen.bin");
    const check_fixture_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        "actual=$(sha256sum test/fixtures/frozen.bin | cut -d' ' -f1); " ++
            "expected=9d5a10167356db7afaa4e6c43832a7ea75a53e84dc74e679a881d5d8cf7cb2c6; " ++
            "if [ \"$actual\" = \"$expected\" ]; then " ++
            "  echo 'PASS test/fixtures/frozen.bin sha256 ok'; " ++
            "else " ++
            "  echo \"FAIL test/fixtures/frozen.bin expected=$expected got=$actual\"; exit 1; " ++
            "fi",
    });
    check_fixture_step.dependOn(&check_fixture_cmd.step);

    // ci: full local CI chain
    //   1. unit tests
    //   2. check-fixture (SHA-256)
    //   3. build + install ReleaseFast binary (done by dependOn install step)
    //   4. encode/decode/validate lossless (frozen.bin)
    //   5. encode/decode/validate lossy (frozen.bin)
    //   6. validate-adversarial (test/adversarial/)
    //   7. check_regression.py
    const ci_step = b.step("ci", "Full local CI: tests + fixture + codec round-trips + adversarial + regression");

    // Stage 4: lossless round-trip on frozen fixture
    const ci_enc_ls = b.addSystemCommand(&.{
        "./zig-out/bin/mzarc", "encode",                     "test/fixtures/frozen.bin",
        "-o",                  "/tmp/mzarc_ci_frozen.mzarc",
    });
    ci_enc_ls.step.dependOn(b.getInstallStep());
    ci_enc_ls.step.dependOn(test_step);
    ci_enc_ls.step.dependOn(check_fixture_step);

    const ci_dec_ls = b.addSystemCommand(&.{
        "./zig-out/bin/mzarc", "decode",                      "/tmp/mzarc_ci_frozen.mzarc",
        "-o",                  "/tmp/mzarc_ci_frozen_rt.bin",
    });
    ci_dec_ls.step.dependOn(&ci_enc_ls.step);

    const ci_val_ls = b.addSystemCommand(&.{
        "./zig-out/bin/mzarc", "validate",
        "test/fixtures/frozen.bin", "/tmp/mzarc_ci_frozen_rt.bin",
        "--mode=lossless",
    });
    ci_val_ls.step.dependOn(&ci_dec_ls.step);

    // Stage 5: lossy round-trip on frozen fixture
    const ci_enc_ly = b.addSystemCommand(&.{
        "./zig-out/bin/mzarc", "encode",                           "test/fixtures/frozen.bin",
        "-o",                  "/tmp/mzarc_ci_frozen_lossy.mzarc", "--lossy",
    });
    ci_enc_ly.step.dependOn(&ci_val_ls.step);

    const ci_dec_ly = b.addSystemCommand(&.{
        "./zig-out/bin/mzarc", "decode",                            "/tmp/mzarc_ci_frozen_lossy.mzarc",
        "-o",                  "/tmp/mzarc_ci_frozen_lossy_rt.bin",
    });
    ci_dec_ly.step.dependOn(&ci_enc_ly.step);

    const ci_val_ly = b.addSystemCommand(&.{
        "./zig-out/bin/mzarc", "validate",
        "test/fixtures/frozen.bin", "/tmp/mzarc_ci_frozen_lossy_rt.bin",
        "--mode=lossy",
    });
    ci_val_ly.step.dependOn(&ci_dec_ly.step);

    // Stage 6: adversarial corpus round-trip
    const ci_adversarial = b.addSystemCommand(&.{
        "./zig-out/bin/mzarc", "validate-adversarial", "test/adversarial/",
    });
    ci_adversarial.step.dependOn(&ci_val_ly.step);

    // Stage 7: size/speed regression check
    const ci_regression = b.addSystemCommand(&.{
        "uv", "run", "python", "tools/check_regression.py",
    });
    ci_regression.step.dependOn(&ci_adversarial.step);

    ci_step.dependOn(&ci_regression.step);
}
