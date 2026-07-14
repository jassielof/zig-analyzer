//! `textDocument/inlayHint` — parameter-name hints (`../analysis/queries/inlay_hints.zig`'s
//! `collect`) and inferred-type hints (its `collectTypeHintsWithResolver`,
//! resolved via `../analysis/queries/resolve_expr.zig`).

const std = @import("std");
const Io = std.Io;
const Ast = std.zig.Ast;
const jsonrpc = @import("jsonrpc").jsonrpc;
const parse = @import("../analysis/queries/parse.zig");
const item_tree = @import("../analysis/queries/item_tree.zig");
const resolve = @import("../analysis/queries/resolve.zig");
const inlay_hints = @import("../analysis/queries/inlay_hints.zig");
const scope_mod = @import("../analysis/queries/scope.zig");
const resolve_expr = @import("../analysis/queries/resolve_expr.zig");
const server_mod = @import("../server.zig");
const Server = server_mod.Server;
const Position = server_mod.Position;
const Range = server_mod.Range;
const AnyDefinition = Server.AnyDefinition;

const InlayLookupCtx = struct {
    server: *Server,
    importer_uri: []const u8,
    importer_ast: Ast,
    tree: item_tree.ItemTree,
    /// Last signature returned from a cross-file lookup (owned).
    owned_sig: ?[]const u8 = null,
};

fn inlayLookupSignature(ctx_ptr: *anyopaque, base: ?[]const u8, name: []const u8, call_offset: u32) ?[]const u8 {
    const ctx: *InlayLookupCtx = @ptrCast(@alignCast(ctx_ptr));
    if (base) |b| {
        const chain = [_][]const u8{ b, name };
        if (ctx.server.resolveFieldChain(ctx.importer_uri, ctx.importer_ast, &chain) catch null) |result| {
            return stashInlaySig(ctx, result);
        }
        // Typed member: `b.addExecutable` where `b: *std.Build`.
        const pos: resolve.Position = offsetToPosition(ctx.importer_ast.source, call_offset);
        if (ctx.server.resolveTypedMemberAccess(ctx.importer_uri, ctx.importer_ast, pos, &chain) catch null) |result| {
            return stashInlaySig(ctx, result);
        }
        return null;
    }
    const item = ctx.tree.find(name) orelse return null;
    if (item.kind != .function) return null;
    return item.signature;
}

fn stashInlaySig(ctx: *InlayLookupCtx, result: AnyDefinition) ?[]const u8 {
    if (ctx.owned_sig) |old| ctx.server.gpa.free(old);
    if (result.signature_owned) {
        ctx.owned_sig = result.def.signature;
        ctx.server.gpa.free(result.uri);
        return ctx.owned_sig;
    }
    const duped = ctx.server.gpa.dupe(u8, result.def.signature) catch {
        ctx.server.freeAnyDefinition(result);
        return null;
    };
    ctx.server.gpa.free(result.uri);
    ctx.owned_sig = duped;
    return duped;
}

fn offsetToPosition(source: []const u8, offset: u32) resolve.Position {
    var line: u32 = 0;
    var line_start: u32 = 0;
    var i: u32 = 0;
    while (i < offset and i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .character = offset -| line_start };
}

pub fn handleInlayHint(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        range: Range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = std.math.maxInt(u32), .character = 0 } },
    };
    var parsed = std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
        try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid textDocument/inlayHint params");
        return;
    };
    defer parsed.deinit();

    if (!self.inlay_hints_enable) {
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as([]const struct { position: Position, label: []const u8 }, &.{}));
        return;
    }

    const uri = parsed.value.textDocument.uri;
    const doc = self.documents.get(uri) orelse {
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as([]const struct { position: Position, label: []const u8 }, &.{}));
        return;
    };

    const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
    const tree = try item_tree.itemTree(&self.item_tree_cache, self.gpa, uri, parsed_file.ast, doc.revision);

    const InlayHintResult = struct {
        position: Position,
        label: []const u8,
        paddingLeft: bool = false,
        paddingRight: bool = false,
        kind: u8 = 2, // Parameter
    };
    var results: std.ArrayList(InlayHintResult) = .empty;
    defer results.deinit(self.gpa);

    // Both hint slices must outlive `results`, which only borrows
    // their labels — freed together, after the write below, rather
    // than at the end of each `if` block.
    var param_hints: []const inlay_hints.Hint = &.{};
    defer inlay_hints.freeHints(self.gpa, param_hints);
    var type_hints: []const inlay_hints.Hint = &.{};
    defer inlay_hints.freeHints(self.gpa, type_hints);

    if (self.inlay_hints_parameter_names) {
        var lookup_ctx: InlayLookupCtx = .{
            .server = self,
            .importer_uri = uri,
            .importer_ast = parsed_file.ast,
            .tree = tree.*,
            .owned_sig = null,
        };
        defer if (lookup_ctx.owned_sig) |s| self.gpa.free(s);

        param_hints = try inlay_hints.collect(self.gpa, parsed_file.ast, tree.*, inlayLookupSignature, &lookup_ctx, .{
            .exclude_single_argument = self.inlay_hints_exclude_single_argument,
        });

        for (param_hints) |h| {
            if (h.line < parsed.value.range.start.line) continue;
            if (h.line > parsed.value.range.end.line) continue;
            try results.append(self.gpa, .{
                .position = .{ .line = h.line, .character = h.character },
                .label = h.label,
            });
        }
    }

    if (self.inlay_hints_types) {
        var type_scratch: Server.TypeScratch = .{ .server = self };
        defer type_scratch.deinit();
        var scopes = try scope_mod.build(self.gpa, parsed_file.ast);
        defer scopes.deinit();
        var expr_ctx = self.makeExprContext(&type_scratch, uri, parsed_file.ast, scopes);
        defer expr_ctx.deinitScratch();

        var infer_ctx: TypeInferCtx = .{ .server = self, .expr = &expr_ctx };
        type_hints = try inlay_hints.collectTypeHintsWithResolver(
            self.gpa,
            parsed_file.ast,
            inferInitTypeLabel,
            &infer_ctx,
        );

        for (type_hints) |h| {
            if (h.line < parsed.value.range.start.line) continue;
            if (h.line > parsed.value.range.end.line) continue;
            try results.append(self.gpa, .{
                .position = .{ .line = h.line, .character = h.character },
                .label = h.label,
                .kind = 1, // Type
            });
        }
    }

    try jsonrpc.writeResult(writer, self.gpa, msg.id.?, results.items);
}

const TypeInferCtx = struct {
    server: *Server,
    expr: *resolve_expr.Context,
};

fn inferInitTypeLabel(ctx_ptr: *anyopaque, init_node: Ast.Node.Index) ?[]const u8 {
    const ctx: *TypeInferCtx = @ptrCast(@alignCast(ctx_ptr));
    const ty = (resolve_expr.resolveValueType(ctx.expr, init_node) catch return null) orelse return null;
    if (ty.data == .unknown) return null;
    // Skip weak/unhelpful labels.
    if (ty.data == .container and ty.data.container.name.len == 0) return null;
    const rendered = ty.allocStringify(ctx.server.gpa) catch return null;
    defer ctx.server.gpa.free(rendered);
    if (rendered.len == 0 or std.mem.eql(u8, rendered, "unknown")) return null;
    return std.fmt.allocPrint(ctx.server.gpa, ": {s}", .{rendered}) catch null;
}
