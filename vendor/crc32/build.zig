//! Exports the CRC-32 module and builds the command, tests, and source package.

const std = @import("std");

const PACKAGE = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_model = .baseline },
    });
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug information from the installed command");
    const accelerated = b.option(
        bool,
        "accelerated",
        "Link CPU-specific CRC objects; false forces portable CRC even with a native CPU target",
    ) orelse true;

    const options = b.addOptions();
    options.addOption(bool, "accelerated", accelerated);
    const options_module = options.createModule();

    const crc_module = b.addModule("crc32", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    crc_module.addImport("build_options", options_module);
    if (accelerated) {
        if (target.result.os.tag == .macos and target.result.cpu.arch == .aarch64)
            crc_module.link_libc = true;
        addTargetBackends(b, crc_module, target, optimize);
    }

    const cli_options = b.addOptions();
    cli_options.addOption([]const u8, "version", PACKAGE.version);
    const exe = b.addExecutable(.{
        .name = "zig-crc32",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip orelse (optimize == .ReleaseFast),
            .imports = &.{
                .{ .name = "crc32", .module = crc_module },
                .{ .name = "build_options", .module = cli_options.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the CRC-32 command");
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_crc32.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "crc32", .module = crc_module },
                .{ .name = "build_options", .module = options_module },
            },
        }),
    });
    const backend_tests = b.addTest(.{ .root_module = crc_module });
    const folding_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/arm_pmull.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const cli_test_options = b.addOptions();
    cli_test_options.addOptionPath("exe_path", exe.getEmittedBin());
    cli_test_options.addOption([]const u8, "version", PACKAGE.version);
    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "build_options", .module = cli_test_options.createModule() }},
        }),
    });
    const test_step = b.step("test", "Run CRC-32 library, backend, and command tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(backend_tests).step);
    test_step.dependOn(&b.addRunArtifact(folding_tests).step);
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);

    const check_step = b.step("check", "Compile the command and tests without running them");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&tests.step);
    check_step.dependOn(&backend_tests.step);
    check_step.dependOn(&folding_tests.step);
    check_step.dependOn(&cli_tests.step);

    const source_name = b.fmt("crc32-{s}-source", .{PACKAGE.version});
    const source_files = b.addWriteFiles();
    inline for (PACKAGE.paths) |path| {
        _ = source_files.addCopyFile(b.path(path), b.fmt("{s}/{s}", .{ source_name, path }));
    }
    const archive = b.addSystemCommand(&.{ "tar", "-czf" });
    const archive_name = b.fmt("{s}.tar.gz", .{source_name});
    const archive_file = archive.addOutputFileArg(archive_name);
    archive.addArg("-C");
    archive.addDirectoryArg(source_files.getDirectory());
    archive.addArg(source_name);
    const install_archive = b.addInstallFileWithDir(archive_file, .prefix, archive_name);
    b.step("source", "Package the declared Zig source files").dependOn(&install_archive.step);
}

fn addTargetBackends(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    switch (target.result.cpu.arch) {
        .x86_64 => {
            var pclmul_query = target.query;
            pclmul_query.cpu_model = .baseline;
            pclmul_query.cpu_features_add = .empty;
            pclmul_query.cpu_features_sub = .empty;
            pclmul_query.cpu_features_add.addFeatureSet(std.Target.x86.featureSet(&.{ .pclmul, .ssse3 }));
            const pclmul_target = b.resolveTargetQuery(pclmul_query);
            const pclmul = b.addObject(.{
                .name = "crc32_x86_pclmul",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/x86_pclmul.zig"),
                    .target = pclmul_target,
                    .optimize = optimize,
                }),
                .use_llvm = true,
            });
            module.addObject(pclmul);

            var vpclmul_query = target.query;
            // VEX.128 needs PCLMUL and AVX; no wide VPCLMUL instruction is used.
            vpclmul_query.cpu_model = .baseline;
            vpclmul_query.cpu_features_add = .empty;
            vpclmul_query.cpu_features_sub = .empty;
            vpclmul_query.cpu_features_add.addFeatureSet(std.Target.x86.featureSet(&.{ .pclmul, .avx, .ssse3 }));
            const vpclmul_target = b.resolveTargetQuery(vpclmul_query);
            const vpclmul = b.addObject(.{
                .name = "crc32_x86_vpclmul",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/x86_vpclmul.zig"),
                    .target = vpclmul_target,
                    .optimize = optimize,
                }),
                .use_llvm = true,
            });
            module.addObject(vpclmul);
        },
        .aarch64 => {
            var crc_query = target.query;
            crc_query.cpu_model = .baseline;
            crc_query.cpu_features_add = .empty;
            crc_query.cpu_features_sub = .empty;
            crc_query.cpu_features_add.addFeatureSet(std.Target.aarch64.featureSet(&.{.crc}));
            const crc_target = b.resolveTargetQuery(crc_query);
            const crc = b.addObject(.{
                .name = "crc32_arm_crc",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/arm_crc.zig"),
                    .target = crc_target,
                    .optimize = optimize,
                }),
                .use_llvm = true,
            });
            module.addObject(crc);

            var pmull_query = target.query;
            pmull_query.cpu_model = .baseline;
            pmull_query.cpu_features_add = .empty;
            pmull_query.cpu_features_sub = .empty;
            pmull_query.cpu_features_add.addFeatureSet(std.Target.aarch64.featureSet(&.{.crypto}));
            const pmull_target = b.resolveTargetQuery(pmull_query);
            const pmull = b.addObject(.{
                .name = "crc32_arm_pmull",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/arm_pmull.zig"),
                    .target = pmull_target,
                    .optimize = optimize,
                }),
                .use_llvm = true,
            });
            module.addObject(pmull);
        },
        else => {},
    }
}
