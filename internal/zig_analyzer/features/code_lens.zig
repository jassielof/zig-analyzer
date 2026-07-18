//! Implementation of [`textDocument/codeLens`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_codeLens)
//!
//! Provides:
//! - Reference-count lenses on top-level declarations
//! - Build-step lenses in `build.zig` (`zig build` / `zig build <step>`)
//!
//! Build-step lenses use the command `zigAnalyzer.executeBuild` with arguments
//! `[stepName: ?string, workspaceFolderUri: ?string]`. Clients (including non–VS Code
//! editors) should register a handler for that command to make the lenses actionable.

const std = @import("std");
const Ast = std.zig.Ast;

const Server = @import("../Server.zig");
const DocumentStore = @import("../DocumentStore.zig");
const Analyser = @import("../analysis.zig");
const lsp = @import("lsp");
const types = lsp.types;
const Uri = @import("../Uri.zig");
const offsets = @import("../offsets.zig");
const references = @import("references.zig");

pub fn codeLensHandler(
    server: *Server,
    arena: std.mem.Allocator,
    request: types.code_lens.Params,
) Server.Error!?[]types.code_lens.Response {
    const document_uri = Uri.parse(arena, request.textDocument.uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParams,
    };
    const handle = server.document_store.getHandle(document_uri) orelse return null;
    if (handle.tree.mode == .zon) return null;
    if (handle.tree.errors.len != 0) return null;

    var lenses: std.ArrayList(types.code_lens.Response) = .empty;

    if (isBuildZig(handle.uri.raw)) {
        try collectBuildStepLenses(arena, handle, server.offset_encoding, &lenses);
    }

    if (server.config_manager.config.enable_reference_code_lenses) {
        try collectReferenceLenses(server, arena, handle, &lenses);
    }

    return lenses.items;
}

fn isBuildZig(uri_raw: []const u8) bool {
    return std.mem.endsWith(u8, uri_raw, "/build.zig") or std.mem.endsWith(u8, uri_raw, "\\build.zig");
}

fn collectReferenceLenses(
    server: *Server,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    lenses: *std.ArrayList(types.code_lens.Response),
) Server.Error!void {
    var analyser = server.initAnalyser(arena, handle);
    defer analyser.deinit();

    for (handle.tree.rootDecls()) |node| {
        const decl = declFromRootNode(handle, node) orelse continue;
        const name = offsets.identifierTokenToNameSlice(&handle.tree, decl.nameToken());
        if (std.mem.eql(u8, name, "main")) continue;
        // Avoid double lenses on `fn build` in build.zig (build-step lens already covers it).
        if (isBuildZig(handle.uri.raw) and std.mem.eql(u8, name, "build")) continue;

        const locs = try references.collectSymbolReferences(
            &analyser,
            decl,
            handle,
            server.offset_encoding,
        );
        const count = locs.items.len;
        const title = try std.fmt.allocPrint(
            arena,
            "{d} reference{s}",
            .{ count, if (count == 1) "" else "s" },
        );

        try lenses.append(arena, .{
            .range = offsets.tokenToRange(&handle.tree, decl.nameToken(), server.offset_encoding),
            .command = .{
                .title = title,
                .command = "",
            },
        });
    }
}

fn collectBuildStepLenses(
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    encoding: offsets.Encoding,
    lenses: *std.ArrayList(types.code_lens.Response),
) error{OutOfMemory}!void {
    const tree = &handle.tree;
    const folder_uri = workspaceFolderUri(arena, handle.uri.raw);

    for (tree.rootDecls()) |node| {
        var buf: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf, node)) |fn_proto| {
            const name_token = fn_proto.name_token orelse continue;
            const name = offsets.identifierTokenToNameSlice(tree, name_token);
            if (!std.mem.eql(u8, name, "build")) continue;

            try lenses.append(arena, .{
                .range = offsets.tokenToRange(tree, name_token, encoding),
                .command = .{
                    .title = "zig build",
                    .command = "zigAnalyzer.executeBuild",
                    .arguments = try buildExecuteArgs(arena, null, folder_uri),
                },
            });
        }
    }

    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        const step = parseStepCall(tree, node) orelse continue;
        try lenses.append(arena, .{
            .range = offsets.tokenToRange(tree, step.name_token, encoding),
            .command = .{
                .title = try std.fmt.allocPrint(arena, "zig build {s}", .{step.name}),
                .command = "zigAnalyzer.executeBuild",
                .arguments = try buildExecuteArgs(arena, step.name, folder_uri),
            },
        });
    }
}

const StepCall = struct {
    name: []const u8,
    name_token: Ast.TokenIndex,
};

/// Matches `b.step("name", …)` / `builder.step("name", …)`.
fn parseStepCall(tree: *const Ast, node: Ast.Node.Index) ?StepCall {
    var buf: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buf, node) orelse return null;
    if (call.ast.params.len == 0) return null;

    // callee must be `*.step`
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const field_token = tree.nodeData(call.ast.fn_expr).node_and_token[1];
    if (!std.mem.eql(u8, tree.tokenSlice(field_token), "step")) return null;

    const name_node = call.ast.params[0];
    if (tree.nodeTag(name_node) != .string_literal) return null;
    const name_token = tree.nodeMainToken(name_node);
    const literal = tree.tokenSlice(name_token);
    if (literal.len < 2) return null;
    return .{
        .name = literal[1 .. literal.len - 1],
        .name_token = name_token,
    };
}

fn workspaceFolderUri(arena: std.mem.Allocator, document_uri: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, document_uri, '/') orelse return null;
    return arena.dupe(u8, document_uri[0..slash]) catch null;
}

fn buildExecuteArgs(
    arena: std.mem.Allocator,
    step_name: ?[]const u8,
    folder_uri: ?[]const u8,
) error{OutOfMemory}![]const types.LSPAny {
    var args: std.ArrayList(types.LSPAny) = try .initCapacity(arena, 2);
    if (step_name) |name| {
        args.appendAssumeCapacity(.{ .string = name });
    } else {
        args.appendAssumeCapacity(.null);
    }
    if (folder_uri) |uri| {
        args.appendAssumeCapacity(.{ .string = uri });
    } else {
        args.appendAssumeCapacity(.null);
    }
    return args.items;
}

fn declFromRootNode(handle: *DocumentStore.Handle, node: Ast.Node.Index) ?Analyser.DeclWithHandle {
    const tree = &handle.tree;
    switch (tree.nodeTag(node)) {
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_decl,
        => {
            var buf: [1]Ast.Node.Index = undefined;
            if (tree.fullFnProto(&buf, node)) |fn_proto| {
                if (fn_proto.name_token == null) return null;
            }
            return .{ .decl = .{ .ast_node = node }, .handle = handle };
        },
        else => return null,
    }
}
