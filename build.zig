const std = @import("std");
const project = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const mod_name = "zig_analyzer";
    const exe_name = "zig-analyzer";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule(mod_name, .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
    });

    // Single source of truth for the version string: build.zig.zon.
    // `--version` and the LSP `serverInfo.version` both read this instead
    // of maintaining their own copy that could drift.
    const options = b.addOptions();
    options.addOption([]const u8, "version", project.version);
    mod.addOptions("build_options", options);

    const run_step = b.step("cli", "Test the CLI");

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = mod_name, .module = mod },
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
        .name = "Zig Analyzer library",
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
                .{ .name = mod_name, .module = mod },
            },
        }),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration_tests.step);
}
