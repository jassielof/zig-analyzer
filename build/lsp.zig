const std = @import("std");

pub const Modules = struct {
    lsp: *std.Build.Module,
    json_rpc: *std.Build.Module,
    parser: *std.Build.Module,
    types: *std.Build.Module,
};

/// Runs the LSP types codegen (from lsp-kit's metaModel.json) once. The resulting
/// `lsp_types.zig` file is target-independent and can be reused for every
/// `createLspModules` call.
pub fn runCodegen(b: *std.Build) std.Build.LazyPath {
    const codegen_exe = b.addExecutable(.{
        .name = "lsp-codegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/lsp_types_gen/main.zig"),
            .target = b.graph.host,
            .single_threaded = true,
        }),
    });
    // The metaModel.json file should be removed once https://github.com/ziglang/zig/issues/17895 has been resolved.
    codegen_exe.root_module.addAnonymousImport("meta-model", .{ .root_source_file = b.path("lib/lsp/metaModel.json") });

    const run_codegen = b.addRunArtifact(codegen_exe);
    const lsp_types_output_file = run_codegen.addOutputFileArg("lsp_types.zig");

    const codegen_step = b.step("codegen", "Install LSP types generated from the meta model");
    codegen_step.dependOn(&b.addInstallFile(lsp_types_output_file, "lsp_types.zig").step);

    return lsp_types_output_file;
}

/// Builds the `lib/lsp` module graph (lsp, json-rpc, lsp-parser, lsp-types) for a specific target/optimize.
pub fn createLspModules(
    b: *std.Build,
    lsp_types_output_file: std.Build.LazyPath,
    options: struct {
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    },
) Modules {
    const json_rpc_module = b.createModule(.{
        .root_source_file = b.path("lib/json_rpc/root.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });

    const lsp_parser_module = b.createModule(.{
        .root_source_file = b.path("lib/lsp/parser.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });

    const lsp_types_module = b.createModule(.{
        .root_source_file = lsp_types_output_file,
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{
            .{ .name = "parser", .module = lsp_parser_module },
            .{ .name = "json_rpc", .module = json_rpc_module },
        },
    });

    const lsp_module = b.createModule(.{
        .root_source_file = b.path("lib/lsp/root.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{
            .{ .name = "parser", .module = lsp_parser_module },
            .{ .name = "types", .module = lsp_types_module },
            .{ .name = "json_rpc", .module = json_rpc_module },
        },
    });

    return .{ .lsp = lsp_module, .json_rpc = json_rpc_module, .parser = lsp_parser_module, .types = lsp_types_module };
}

/// Registers a `lsp-docs` step that generates and installs documentation for the lsp module.
pub fn addDocsStep(b: *std.Build, lsp_module: *std.Build.Module) void {
    const autodoc_exe = b.addObject(.{
        .name = "lsp",
        .root_module = lsp_module,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = autodoc_exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "doc/lsp",
    });

    const docs_step = b.step("lsp-docs", "Generate and install documentation for the lsp module");
    docs_step.dependOn(&install_docs.step);
}

pub fn addLspTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    modules: Modules,
) void {
    const lsp_tests = b.addTest(.{
        .root_module = modules.lsp,
    });

    const json_rpc_tests = b.addTest(.{
        .name = "test json_rpc",
        .root_module = modules.json_rpc,
    });

    const lsp_parser_tests = b.addTest(.{
        .name = "test lsp parser",
        .root_module = modules.parser,
    });

    test_step.dependOn(&b.addRunArtifact(lsp_tests).step);
    test_step.dependOn(&b.addRunArtifact(json_rpc_tests).step);
    test_step.dependOn(&b.addRunArtifact(lsp_parser_tests).step);
}
