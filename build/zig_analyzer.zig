const std = @import("std");

pub fn createZigAnalyzerModule(
    b: *std.Build,
    options: struct {
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        lsp_module: *std.Build.Module,
        build_options: *std.Build.Module,
        version_data: *std.Build.Module,
    },
) *std.Build.Module {
    const dmp_module = b.dependency("dmp", .{
        .target = options.target,
        .optimize = options.optimize,
    }).module("dmp");

    const zig_analyzer_module = b.createModule(.{
        .root_source_file = b.path("internal/zig_analyzer/root.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{
            .{ .name = "dmp", .module = dmp_module },
            .{ .name = "lsp", .module = options.lsp_module },
            .{ .name = "build_options", .module = options.build_options },
            .{ .name = "version_data", .module = options.version_data },
        },
    });

    if (options.target.result.os.tag == .windows) {
        zig_analyzer_module.linkSystemLibrary("advapi32", .{});
    }

    return zig_analyzer_module;
}
