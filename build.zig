const std = @import("std");
const builtin = @import("builtin");

const lsp_build = @import("build/lsp.zig");
const version_build = @import("build/version.zig");
const zig_analyzer_build = @import("build/zig_analyzer.zig");

const package_version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_llvm: ?bool = null;

    const resolved_version = version_build.getVersion(b, package_version);

    const build_options = blk: {
        const build_options = b.addOptions();
        build_options.step.name = "zig-analyzer build options";

        build_options.addOption(std.SemanticVersion, "version", resolved_version);
        build_options.addOption([]const u8, "version_string", b.fmt("{f}", .{resolved_version}));
        build_options.addOption([]const u8, "minimum_runtime_zig_version_string", builtin.zig_version_string);

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
    const gen_exe = b.addExecutable(.{
        .name = "zig_analyzer_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/config_gen/main.zig"),
            .target = b.graph.host,
            .single_threaded = true,
        }),
    });

    const version_data_module = blk: {
        const gen_builtins_cmd = b.addRunArtifact(gen_exe);

        gen_builtins_cmd.addArg("--langref-path");
        gen_builtins_cmd.addFileArg(b.path("tools/config_gen/langref.md"));

        gen_builtins_cmd.addArg("--generate-builtins-json");
        const builtins_json_path = gen_builtins_cmd.addOutputFileArg("builtins.json");

        // Place builtins.json next to a tiny Zig wrapper so `@embedFile` resolves
        // relative to that generated source (more reliable than `--embed-dir` alone).
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(builtins_json_path, "builtins.json");
        const embed_src = wf.add(
            "builtins_embed.zig",
            \\//! DO NOT EDIT
            \\pub const json: []const u8 = @embedFile("builtins.json");
            \\
            ,
        );

        const module = b.createModule(.{
            .root_source_file = b.path("internal/zig_analyzer/version_data.zig"),
            .imports = &.{
                .{
                    .name = "builtins_embed",
                    .module = b.createModule(.{ .root_source_file = embed_src }),
                },
            },
        });
        break :blk module;
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
        .imports = &.{
            .{ .name = "exe_options", .module = exe_options },
            .{ .name = "known-folders", .module = known_folders_module },
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
        const test_step = b.step("test", "Run the test suite");

        const src_tests = b.addTest(.{
            .name = "zig_analyzer src test",
            .root_module = zig_analyzer_module,
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        test_step.dependOn(&b.addRunArtifact(src_tests).step);

        lsp_build.addLspTests(b, test_step, lsp_modules, use_llvm);
    }
}
