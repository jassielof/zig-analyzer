//! `textDocument/documentSymbol` and `workspace/symbol` — both walk a
//! file's item tree into the same `SymbolKind` numbering, which is why
//! they share this one file rather than being split further.

const std = @import("std");
const Io = std.Io;
const jsonrpc = @import("jsonrpc").jsonrpc;
const parse = @import("../analysis/queries/parse.zig");
const item_tree = @import("../analysis/queries/item_tree.zig");
const resolve = @import("../analysis/queries/resolve.zig");
const server_mod = @import("../server.zig");
const Server = server_mod.Server;
const Range = server_mod.Range;

// LSP `SymbolKind`: 12 = Function, 13 = Variable.
fn symbolKind(kind: item_tree.Item.Kind) u8 {
    return switch (kind) {
        .function => 12,
        .variable => 13,
    };
}

pub fn handleDocumentSymbol(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
    const Params = struct { textDocument: struct { uri: []const u8 } };
    var parsed = std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
        try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid textDocument/documentSymbol params");
        return;
    };
    defer parsed.deinit();

    const DocumentSymbolResult = struct { name: []const u8, kind: u8, range: Range, selectionRange: Range };
    var symbols: std.ArrayList(DocumentSymbolResult) = .empty;
    defer symbols.deinit(self.gpa);

    const uri = parsed.value.textDocument.uri;
    if (self.documents.get(uri)) |doc| {
        const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
        const tree = try item_tree.itemTree(&self.item_tree_cache, self.gpa, uri, parsed_file.ast, doc.revision);

        for (tree.items) |item| {
            // First occurrence only: a duplicate-named item (already
            // flagged separately by semantic_diagnostics) would
            // otherwise show the same location twice.
            const def = resolve.definitionForRootItem(parsed_file.ast, item.name) orelse continue;
            const range: Range = .{
                .start = .{ .line = def.line, .character = def.character },
                .end = .{ .line = def.line, .character = def.end_character },
            };
            try symbols.append(self.gpa, .{
                .name = item.name,
                .kind = symbolKind(item.kind),
                .range = range,
                .selectionRange = range,
            });
        }
    }

    try jsonrpc.writeResult(writer, self.gpa, msg.id.?, symbols.items);
}

pub fn handleWorkspaceSymbol(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
    const Params = struct { query: []const u8 = "" };
    var parsed = std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
        try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid workspace/symbol params");
        return;
    };
    defer parsed.deinit();

    const SymbolInformationResult = struct {
        name: []const u8,
        kind: u8,
        location: struct { uri: []const u8, range: Range },
    };
    var symbols: std.ArrayList(SymbolInformationResult) = .empty;
    defer symbols.deinit(self.gpa);

    var it = self.documents.documents.iterator();
    while (it.next()) |entry| {
        const doc_uri = entry.key_ptr.*;
        const doc = entry.value_ptr.*;
        const parsed_file = try parse.parse(&self.parse_cache, self.gpa, doc_uri, doc.text, doc.revision);
        const tree = try item_tree.itemTree(&self.item_tree_cache, self.gpa, doc_uri, parsed_file.ast, doc.revision);

        for (tree.items) |item| {
            if (parsed.value.query.len > 0 and std.mem.indexOf(u8, item.name, parsed.value.query) == null) continue;
            const def = resolve.definitionForRootItem(parsed_file.ast, item.name) orelse continue;
            try symbols.append(self.gpa, .{
                .name = item.name,
                .kind = symbolKind(item.kind),
                .location = .{
                    .uri = doc_uri,
                    .range = .{
                        .start = .{ .line = def.line, .character = def.character },
                        .end = .{ .line = def.line, .character = def.end_character },
                    },
                },
            });
        }
    }

    try jsonrpc.writeResult(writer, self.gpa, msg.id.?, symbols.items);
}
