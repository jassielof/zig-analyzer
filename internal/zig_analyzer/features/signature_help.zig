//! `textDocument/signatureHelp`.

const std = @import("std");
const Io = std.Io;
const Ast = std.zig.Ast;
const jsonrpc = @import("jsonrpc").jsonrpc;
const parse = @import("../analysis/queries/parse.zig");
const item_tree = @import("../analysis/queries/item_tree.zig");
const resolve = @import("../analysis/queries/resolve.zig");
const server_mod = @import("../server.zig");
const Server = server_mod.Server;
const Position = server_mod.Position;

fn resolveCrossFile(
    self: *Server,
    importer_uri: []const u8,
    importer_ast: Ast,
    field_access: resolve.FieldAccess,
) !?Server.CrossFileDefinition {
    const chain = [_][]const u8{ field_access.base, field_access.field };
    return self.resolveFieldChain(importer_uri, importer_ast, &chain);
}

pub fn handleSignatureHelp(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: Position,
    };
    var parsed = std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
        try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid textDocument/signatureHelp params");
        return;
    };
    defer parsed.deinit();

    const uri = parsed.value.textDocument.uri;
    const doc = self.documents.get(uri) orelse {
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
        return;
    };

    const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
    const tree = try item_tree.itemTree(&self.item_tree_cache, self.gpa, uri, parsed_file.ast, doc.revision);
    const pos: resolve.Position = .{ .line = parsed.value.position.line, .character = parsed.value.position.character };

    const ctx = try resolve.callContextAt(self.gpa, parsed_file.ast, pos) orelse {
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
        return;
    };
    const callee_name = parsed_file.ast.tokenSlice(ctx.callee_token);

    var signature: ?[]const u8 = null;
    var owned_sig: ?[]u8 = null;
    defer if (owned_sig) |s| self.gpa.free(s);

    if (tree.find(callee_name)) |item| {
        if (item.kind == .function) signature = item.signature;
    }
    if (signature == null) {
        if (resolve.fieldAccessAtToken(parsed_file.ast, ctx.callee_token)) |fa| {
            if (try resolveCrossFile(self, uri, parsed_file.ast, fa)) |cross| {
                defer self.freeAnyDefinition(cross);
                // Copy out — cross may own a signature backed by a
                // temporary disk AST that freeAnyDefinition releases.
                owned_sig = try self.gpa.dupe(u8, cross.def.signature);
                signature = owned_sig;
            }
        }
    }

    const sig = signature orelse {
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
        return;
    };

    const SignatureInfoResult = struct { label: []const u8 };
    const SignatureHelpResult = struct {
        signatures: []const SignatureInfoResult,
        activeSignature: u32 = 0,
        activeParameter: u32,
    };
    try jsonrpc.writeResult(writer, self.gpa, msg.id.?, SignatureHelpResult{
        .signatures = &.{.{ .label = sig }},
        .activeParameter = ctx.active_parameter,
    });
}
