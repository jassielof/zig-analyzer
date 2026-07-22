const std = @import("std");
const builtin = @import("builtin");

const fangz_build = @import("fangz");

const package_version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const resolved_version = getVersion(b, package_version);

    const build_options = blk: {
        const build_options = b.addOptions();
        build_options.step.name = "zig-analyzer build options";

        build_options.addOption(std.SemanticVersion, "version", resolved_version);
        build_options.addOption([]const u8, "version_string", b.fmt("{f}", .{resolved_version}));

        break :blk build_options.createModule();
    };
    const exe_options = blk: {
        const exe_options = b.addOptions();
        exe_options.step.name = "zig-analyzer exe options";

        exe_options.addOption(bool, "enable_failing_allocator", b.option(bool, "enable-failing-allocator", "Whether to use a randomly failing allocator.") orelse false);
        exe_options.addOption(u32, "enable_failing_allocator_likelihood", b.option(u32, "enable-failing-allocator-likelihood", "The chance that an allocation will fail is `1/likelihood`") orelse 256);

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
        // Fetch + convert the rendered Language Reference via Markitdown CLI.
        // Output is cached by the Zig build system keyed on the command line
        // (including the docs URL / compiler version).
        const docs_url = b.fmt("https://ziglang.org/documentation/{s}/", .{builtin.zig_version_string});
        const markitdown = b.addSystemCommand(&.{"uv"});
        markitdown.addArgs(&.{ "run", "markitdown" });
        markitdown.setName("markitdown langref");
        markitdown.addArg("--output");
        const langref_md = markitdown.addOutputFileArg("langref.md");
        markitdown.addArg(docs_url);
        markitdown.expectExitCode(0);

        const gen_builtins_cmd = b.addRunArtifact(gen_exe);
        gen_builtins_cmd.addArg("--langref-path");
        gen_builtins_cmd.addFileArg(langref_md);
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
            update_source.addCopyFileToSource(gen_cmd.addOutputFileArg("schema.json"), "schemas/zig-analyzer.schema.json");
            gen_cmd.addArg("--generate-vscode-config");
            update_source.addCopyFileToSource(gen_cmd.addOutputFileArg("vscode-configuration.json"), "schemas/vscode-configuration.json");
            gen_step.dependOn(&update_source.step);

            const merge_pkg = b.addSystemCommand(&.{ "node", "tools/config_gen/merge_package_json.mjs" });
            merge_pkg.setName("merge package.json settings");
            merge_pkg.step.dependOn(&update_source.step);
            gen_step.dependOn(&merge_pkg.step);
        }
    }

    const lsp_types_output_file = blk: {
        // The LSP metaModel.json (~16k lines) isn't vendored: it's fetched with Zig's own
        // std.http.Client (see tools/fetch_file) and cached by the Zig build system, keyed on
        // the command line (including this URL) - same caching story as the langref fetch above.
        const fetch_exe = b.addExecutable(.{
            .name = "zig_analyzer_fetch_file",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/fetch_file/main.zig"),
                .target = b.graph.host,
                .single_threaded = true,
            }),
        });

        const fetch_meta_model = b.addRunArtifact(fetch_exe);
        fetch_meta_model.setName("fetch LSP metaModel.json");
        fetch_meta_model.addArg("https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/metaModel/metaModel.json");
        const meta_model_json = fetch_meta_model.addOutputFileArg("metaModel.json");

        const codegen_exe = b.addExecutable(.{
            .name = "lsp-codegen",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/lsp_types_gen/main.zig"),
                .target = b.graph.host,
                .single_threaded = true,
            }),
        });
        codegen_exe.root_module.addAnonymousImport("meta-model", .{ .root_source_file = meta_model_json });

        const run_codegen = b.addRunArtifact(codegen_exe);
        const output_file = run_codegen.addOutputFileArg("lsp_types.zig");

        const codegen_step = b.step("codegen", "Install LSP types generated from the meta model");
        codegen_step.dependOn(&b.addInstallFile(output_file, "lsp_types.zig").step);

        break :blk output_file;
    };

    const json_rpc_module = b.createModule(.{
        .root_source_file = b.path("lib/json_rpc/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `lib/lsp/parser.zig` (generic `std.json` (de)serialization helpers: `Map`, `UnionParser`,
    // `EnumCustomStringValues`, `EnumStringifyAsInt`) conceptually belongs to the LSP library, not
    // JSON-RPC - it's used by the LSP protocol type definitions (below) and re-exported as
    // `lsp.parser`, but never by lib/json_rpc. It still has to be its own module rather than a
    // plain relative import from `lib/lsp/root.zig`, though: the *generated* `lsp_types_module`
    // (rooted at `lsp_types_output_file`, which lives outside `lib/lsp/`) can only reach it via a
    // named module import, and Zig doesn't allow a single file to belong to two different modules
    // at once - so `lsp_module` has to import this same module instance too, rather than reaching
    // the file relatively.
    const lsp_parser_module = b.createModule(.{
        .root_source_file = b.path("lib/lsp/parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lsp_types_module = b.createModule(.{
        .root_source_file = lsp_types_output_file,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "parser", .module = lsp_parser_module },
            .{ .name = "json_rpc", .module = json_rpc_module },
        },
    });

    const lsp_module = b.createModule(.{
        .root_source_file = b.path("lib/lsp/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "parser", .module = lsp_parser_module },
            .{ .name = "types", .module = lsp_types_module },
            .{ .name = "json_rpc", .module = json_rpc_module },
        },
    });

    { // zig build lsp-docs
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

    b.modules.put(b.allocator, "lsp", lsp_module) catch @panic("OOM");
    b.modules.put(b.allocator, "json_rpc", json_rpc_module) catch @panic("OOM");

    const dmp_module = b.dependency("dmp", .{
        .target = target,
        .optimize = optimize,
    }).module("dmp");

    const rules_module = b.dependency("docent", .{
        .target = target,
        .optimize = optimize,
    }).module("rules");

    const zig_analyzer_module = b.createModule(.{
        .root_source_file = b.path("internal/zig_analyzer/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dmp", .module = dmp_module },
            .{ .name = "rules", .module = rules_module },
            .{ .name = "lsp", .module = lsp_module },
            .{ .name = "json_rpc", .module = json_rpc_module },
            .{ .name = "build_options", .module = build_options },
            .{ .name = "version_data", .module = version_data_module },
        },
    });

    if (target.result.os.tag == .windows) {
        zig_analyzer_module.linkSystemLibrary("advapi32", .{});
    }

    b.modules.put(b.allocator, "zig_analyzer", zig_analyzer_module) catch @panic("OOM");

    const fangz_module = b.dependency("fangz", .{
        .target = target,
        .optimize = optimize,
    }).module("fangz");

    const vereda_module = b.dependency("vereda", .{
        .target = target,
        .optimize = optimize,
    }).module("vereda");

    const exe_module = b.createModule(.{
        .root_source_file = b.path("cmd/zig-analyzer/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "exe_options", .module = exe_options },
            .{ .name = "fangz", .module = fangz_module },
            .{ .name = "vereda", .module = vereda_module },
            .{ .name = "zig_analyzer", .module = zig_analyzer_module },
            .{ .name = "json_rpc", .module = json_rpc_module },
        },
    });

    { // zig build
        const exe = b.addExecutable(.{
            .name = "zig-analyzer",
            .root_module = exe_module,
        });
        fangz_build.injectMetadata(b, exe, fangz_module);
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
        });
        test_step.dependOn(&b.addRunArtifact(src_tests).step);

        const lsp_tests = b.addTest(.{
            .root_module = lsp_module,
        });

        const json_rpc_tests = b.addTest(.{
            .name = "test json_rpc",
            .root_module = json_rpc_module,
        });

        const lsp_parser_tests = b.addTest(.{
            .name = "test lsp parser",
            .root_module = lsp_parser_module,
        });

        test_step.dependOn(&b.addRunArtifact(lsp_tests).step);
        test_step.dependOn(&b.addRunArtifact(json_rpc_tests).step);
        test_step.dependOn(&b.addRunArtifact(lsp_parser_tests).step);
    }
}

/// Returns `MAJOR.MINOR.PATCH-dev` when `git describe` failed.
fn getVersion(b: *std.Build, base_version: std.SemanticVersion) std.SemanticVersion {
    const version_string = b.option([]const u8, "version-string", "Override the version of this build. Must be a semantic version.");
    if (version_string) |semver_string| {
        return std.SemanticVersion.parse(semver_string) catch |err| {
            std.debug.panic("Expected -Dversion-string={s} to be a semantic version: {}", .{ semver_string, err });
        };
    }

    if (base_version.pre == null) return base_version;

    const argv: []const []const u8 = &.{
        "git", "-C", b.pathFromRoot("."), "--git-dir", ".git", "describe", "--match", "*.*.*", "--tags",
    };
    var code: u8 = undefined;
    const git_describe_untrimmed = b.runAllowFail(argv, &code, .ignore) catch |err| {
        const argv_joined = std.mem.join(b.allocator, " ", argv) catch @panic("OOM");
        std.log.warn(
            \\Failed to run git describe to resolve the version: {}
            \\command: {s}
            \\
            \\Consider passing the -Dversion-string flag to specify the version.
        , .{ err, argv_joined });
        return base_version;
    };

    const git_describe = std.mem.trim(u8, git_describe_untrimmed, " \n\r");

    switch (std.mem.count(u8, git_describe, "-")) {
        0 => {
            // Tagged release version (e.g. 0.10.0).
            return base_version;
        },
        2 => {
            // Untagged development build (e.g. 0.10.0-dev.216+34ce200).
            var it = std.mem.splitScalar(u8, git_describe, '-');
            const tagged_ancestor = it.first();
            const commit_height = it.next().?;
            const commit_id = it.next().?;
            _ = tagged_ancestor;

            return .{
                .major = base_version.major,
                .minor = base_version.minor,
                .patch = base_version.patch,
                .pre = b.fmt("dev.{s}", .{commit_height}),
                .build = if (std.mem.startsWith(u8, commit_id, "g")) commit_id[1..] else commit_id,
            };
        },
        else => {
            std.debug.print("Unexpected 'git describe' output: '{s}'\n", .{git_describe});
            return base_version;
        },
    }
}
