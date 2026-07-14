const std = @import("std");
const builtin = @import("builtin");

const version_build = @import("build/version.zig");
const tracy_build = @import("build/tracy.zig");
const lsp_build = @import("build/lsp.zig");
const zig_analyzer_build = @import("build/zig_analyzer.zig");
const release_build = @import("build/release.zig");

const package_version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable;
const minimum_build_zig_version = @import("build.zig.zon").minimum_zig_version;

/// Specify the minimum Zig version that is usable with zig-analyzer.
const minimum_runtime_zig_version = "0.16.0";

const release_targets = [_]std.Target.Query{
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .windows },
    .{ .cpu_arch = .arm, .os_tag = .linux },
    .{ .cpu_arch = .loongarch64, .os_tag = .linux },
    .{ .cpu_arch = .riscv64, .os_tag = .linux },
    .{ .cpu_arch = .x86, .os_tag = .linux },
    .{ .cpu_arch = .x86, .os_tag = .windows },
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

pub fn build(b: *std.Build) !void {
    comptime if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 16) {
        @compileError(std.fmt.comptimePrint(
            \\Your Zig version does not meet the build requirement:
            \\  required Zig version: 0.16.x
            \\  actual   Zig version: {[current_version]s}
            \\
        , .{ .current_version = builtin.zig_version_string }));
    };

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const single_threaded = b.option(bool, "single-threaded", "Build a single threaded Executable");
    const pie = b.option(bool, "pie", "Build a Position Independent Executable");
    const strip = b.option(bool, "strip", "Strip executable");
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match filter") orelse &.{};
    var use_llvm = b.option(bool, "use-llvm", "Use Zig's llvm code backend");

    const resolved_version = version_build.getVersion(b, package_version);

    const build_options = blk: {
        const build_options = b.addOptions();
        build_options.step.name = "zig-analyzer build options";

        build_options.addOption(std.SemanticVersion, "version", resolved_version);
        build_options.addOption([]const u8, "version_string", b.fmt("{f}", .{resolved_version}));
        build_options.addOption([]const u8, "minimum_runtime_zig_version_string", minimum_runtime_zig_version);

        break :blk build_options.createModule();
    };
    const exe_options = blk: {
        const exe_options = b.addOptions();
        exe_options.step.name = "zig-analyzer exe options";

        exe_options.addOption(bool, "enable_failing_allocator", b.option(bool, "enable-failing-allocator", "Whether to use a randomly failing allocator.") orelse false);
        exe_options.addOption(u32, "enable_failing_allocator_likelihood", b.option(u32, "enable-failing-allocator-likelihood", "The chance that an allocation will fail is `1/likelihood`") orelse 256);
        exe_options.addOption(bool, "debug_gpa", b.option(bool, "debug-allocator", "Force the DebugAllocator to be used in all release modes") orelse false);

        break :blk exe_options.createModule();
    };
    const tracy_options, const tracy_enable = blk: {
        const tracy_opts = tracy_build.createTracyOptions(b);
        break :blk .{ tracy_opts.module, tracy_opts.enable };
    };
    // https://github.com/ziglang/zig/issues/25194
    if (tracy_enable and use_llvm == null) use_llvm = true;

    const gen_exe = b.addExecutable(.{
        .name = "zig_analyzer_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("internal/zig_analyzer/tools/config_gen.zig"),
            .target = b.graph.host,
            .single_threaded = true,
        }),
    });

    const version_data_module = blk: {
        const gen_version_data_cmd = b.addRunArtifact(gen_exe);
        const version = if (package_version.pre == null) b.fmt("{f}", .{package_version}) else "master";
        gen_version_data_cmd.addArgs(&.{ "--langref-version", version });

        gen_version_data_cmd.addArg("--langref-path");
        gen_version_data_cmd.addFileArg(b.path("internal/zig_analyzer/tools/langref.html.in"));

        gen_version_data_cmd.addArg("--generate-version-data");
        const version_data_path = gen_version_data_cmd.addOutputFileArg("version_data.zig");

        break :blk b.createModule(.{ .root_source_file = version_data_path });
    };

    { // zig build gen
        const gen_step = b.step("gen", "Regenerate config files");

        const gen_cmd = b.addRunArtifact(gen_exe);
        if (b.args) |args| {
            gen_cmd.addArgs(args);
            gen_step.dependOn(&gen_cmd.step);
        } else {
            const update_source = b.addUpdateSourceFiles();
            gen_cmd.addArg("--generate-config");
            update_source.addCopyFileToSource(gen_cmd.addOutputFileArg("Config.zig"), "internal/zig_analyzer/Config.zig");
            gen_cmd.addArg("--generate-schema");
            update_source.addCopyFileToSource(gen_cmd.addOutputFileArg("schema.json"), "schemas/zls.schema.json");
            gen_step.dependOn(&update_source.step);
        }
    }

    const lsp_types_output_file = lsp_build.runCodegen(b);

    { // zig build release
        var release_artifacts: [release_targets.len]*std.Build.Step.Compile = undefined;
        for (release_targets, &release_artifacts) |target_query, *artifact| {
            const release_target = b.resolveTargetQuery(target_query);

            const lsp_modules = lsp_build.createLspModules(b, lsp_types_output_file, .{
                .target = release_target,
                .optimize = optimize,
            });

            const zig_analyzer_module = zig_analyzer_build.createZigAnalyzerModule(b, .{
                .target = release_target,
                .optimize = optimize,
                .lsp_module = lsp_modules.lsp,
                .tracy_enable = tracy_enable,
                .tracy_options = tracy_options,
                .build_options = build_options,
                .version_data = version_data_module,
            });

            const known_folders_module = b.dependency("known_folders", .{
                .target = release_target,
                .optimize = optimize,
            }).module("known-folders");

            const exe_module = b.createModule(.{
                .root_source_file = b.path("cmd/zig-analyzer/main.zig"),
                .target = release_target,
                .optimize = optimize,
                .single_threaded = single_threaded,
                .pic = pie,
                .strip = strip,
                .imports = &.{
                    .{ .name = "exe_options", .module = exe_options },
                    .{ .name = "known-folders", .module = known_folders_module },
                    .{ .name = "tracy", .module = zig_analyzer_module.import_table.get("tracy").? },
                    .{ .name = "zig_analyzer", .module = zig_analyzer_module },
                },
            });

            artifact.* = b.addExecutable(.{
                .name = "zig-analyzer",
                .root_module = exe_module,
                .max_rss = 2_000_000_000,
                .use_llvm = use_llvm,
                .use_lld = use_llvm,
            });
        }

        release_build.release(b, &release_artifacts, resolved_version, minimum_build_zig_version, minimum_runtime_zig_version);
    }

    const lsp_modules = lsp_build.createLspModules(b, lsp_types_output_file, .{
        .target = target,
        .optimize = optimize,
    });
    lsp_build.addDocsStep(b, lsp_modules.lsp);
    b.modules.put(b.allocator, "lsp", lsp_modules.lsp) catch @panic("OOM");

    const zig_analyzer_module = zig_analyzer_build.createZigAnalyzerModule(b, .{
        .target = target,
        .optimize = optimize,
        .lsp_module = lsp_modules.lsp,
        .tracy_enable = tracy_enable,
        .tracy_options = tracy_options,
        .build_options = build_options,
        .version_data = version_data_module,
    });
    b.modules.put(b.allocator, "zig_analyzer", zig_analyzer_module) catch @panic("OOM");

    const known_folders_module = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    }).module("known-folders");

    const exe_module = b.createModule(.{
        .root_source_file = b.path("cmd/zig-analyzer/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .pic = pie,
        .strip = strip,
        .imports = &.{
            .{ .name = "exe_options", .module = exe_options },
            .{ .name = "known-folders", .module = known_folders_module },
            .{ .name = "tracy", .module = zig_analyzer_module.import_table.get("tracy").? },
            .{ .name = "zig_analyzer", .module = zig_analyzer_module },
        },
    });

    { // zig build
        const exe = b.addExecutable(.{
            .name = "zig-analyzer",
            .root_module = exe_module,
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        b.installArtifact(exe);
    }

    { // zig build check
        const exe_check = b.addExecutable(.{
            .name = "zig-analyzer",
            .root_module = exe_module,
        });

        const check = b.step("check", "Check if zig-analyzer compiles");
        check.dependOn(&exe_check.step);
    }

    { // zig build test
        const test_step = b.step("test", "Run all the tests");

        const src_tests = b.addTest(.{
            .name = "zig_analyzer src test",
            .root_module = zig_analyzer_module,
            .filters = test_filters,
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        test_step.dependOn(&b.addRunArtifact(src_tests).step);

        lsp_build.addLspTests(b, test_step, lsp_modules, test_filters, use_llvm);
    }
}
