const std = @import("std");

const project = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const jsonrpc_mod = b.addModule("jsonrpc", .{
        .root_source_file = b.path("lib/jsonrpc/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Mirrors zigtools/lsp-kit's own module graph (parser <- types <- lsp):
    // `lib/lsp/types.zig` is generated code that imports "parser" by name,
    // and `lib/lsp/offsets.zig` imports "types" by name — both need those
    // as named module imports, not just sibling files, for `@import("parser")`
    // / `@import("types")` inside them to resolve.
    const lsp_parser_mod = b.addModule("lsp_parser", .{
        .root_source_file = b.path("lib/lsp/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lsp_types_mod = b.addModule("lsp_types", .{
        .root_source_file = b.path("lib/lsp/types.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "parser", .module = lsp_parser_mod },
        },
    });
    const lsp_mod = b.addModule("lsp", .{
        .root_source_file = b.path("lib/lsp/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "parser", .module = lsp_parser_mod },
            .{ .name = "types", .module = lsp_types_mod },
        },
    });

    const mod = b.addModule("zig_analyzer", .{
        .root_source_file = b.path("internal/zig_analyzer/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "jsonrpc", .module = jsonrpc_mod },
            .{ .name = "lsp", .module = lsp_mod },
        },
    });

    // Single source of truth for the version string: build.zig.zon.
    // `--version` and the LSP `serverInfo.version` both read this instead
    // of maintaining their own copy that could drift.
    const options = b.addOptions();
    options.addOption([]const u8, "version", project.version);
    mod.addOptions("build_options", options);

    const run_step = b.step("zig-analyzer", "Run the Zig Analyzer CLI");

    const exe = b.addExecutable(.{
        .name = "zig-analyzer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/zig-analyzer/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_analyzer", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);

    const test_step = b.step("test", "Run the test suite");

    const mod_tests = b.addTest(.{
        .name = "Zig Analyzer",
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    test_step.dependOn(&run_mod_tests.step);

    const integration_tests = b.addTest(.{
        .name = "Integration Suite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/suite.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_analyzer", .module = mod },
            },
        }),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration_tests.step);
}
