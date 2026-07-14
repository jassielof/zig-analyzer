const std = @import("std");

pub const Options = struct {
    module: *std.Build.Module,
    enable: bool,
};

pub fn createTracyOptions(b: *std.Build) Options {
    const tracy_options = b.addOptions();
    tracy_options.step.name = "tracy options";

    const enable = b.option(bool, "enable-tracy", "Whether tracy should be enabled.") orelse false;
    const enable_allocation = b.option(bool, "enable-tracy-allocation", "Enable using TracyAllocator to monitor allocations.") orelse enable;
    const enable_callstack = b.option(bool, "enable-tracy-callstack", "Enable callstack graphs.") orelse enable;
    if (!enable) std.debug.assert(!enable_allocation and !enable_callstack);

    tracy_options.addOption(bool, "enable", enable);
    tracy_options.addOption(bool, "enable_allocation", enable and enable_allocation);
    tracy_options.addOption(bool, "enable_callstack", enable and enable_callstack);

    return .{ .module = tracy_options.createModule(), .enable = enable };
}

pub fn createTracyModule(
    b: *std.Build,
    options: struct {
        root_source_file: std.Build.LazyPath,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        enable: bool,
        tracy_options: *std.Build.Module,
    },
) *std.Build.Module {
    const tracy_module = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{
            .{ .name = "options", .module = options.tracy_options },
        },
        .link_libc = options.enable,
        .link_libcpp = options.enable,
        .sanitize_c = .off,
    });
    if (!options.enable) return tracy_module;

    const tracy_dependency = b.lazyDependency("tracy", .{
        .target = options.target,
        .optimize = options.optimize,
    }) orelse return tracy_module;

    tracy_module.addCMacro("TRACY_ENABLE", "1");
    tracy_module.addIncludePath(tracy_dependency.path(""));
    tracy_module.addCSourceFile(.{
        .file = tracy_dependency.path("public/TracyClient.cpp"),
    });

    if (options.target.result.os.tag == .windows) {
        tracy_module.linkSystemLibrary("dbghelp", .{});
        tracy_module.linkSystemLibrary("ws2_32", .{});
    }

    return tracy_module;
}
