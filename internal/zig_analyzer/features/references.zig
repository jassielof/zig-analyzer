//! `textDocument/references` — same-file only (see `resolve.findReferences`'s
//! own doc comment for why cross-file isn't attempted here).

const std = @import("std");
const Io = std.Io;
const jsonrpc = @import("jsonrpc").jsonrpc;
const parse = @import("../analysis/queries/parse.zig");
const item_tree = @import("../analysis/queries/item_tree.zig");
const resolve = @import("../analysis/queries/resolve.zig");
const server_mod = @import("../server.zig");
const Server = server_mod.Server;
const Position = server_mod.Position;
const Range = server_mod.Range;

pub fn handleReferences(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: Position,
        context: struct { includeDeclaration: bool = false } = .{},
    };
    var parsed = std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
        try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid textDocument/references params");
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

    const def = resolve.resolveAt(parsed_file.ast, tree.*, pos) orelse {
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
        return;
    };
    const target_name = Server.nameOfDefinition(parsed_file.ast, def);

    const refs = try resolve.findReferences(self.gpa, parsed_file.ast, tree.*, target_name, def.line, def.character);
    defer self.gpa.free(refs);

    const LocationResult = struct { uri: []const u8, range: Range };
    var results: std.ArrayList(LocationResult) = .empty;
    defer results.deinit(self.gpa);

    if (parsed.value.context.includeDeclaration) {
        try results.append(self.gpa, .{
            .uri = uri,
            .range = .{
                .start = .{ .line = def.line, .character = def.character },
                .end = .{ .line = def.line, .character = def.end_character },
            },
        });
    }
    for (refs) |r| {
        try results.append(self.gpa, .{
            .uri = uri,
            .range = .{
                .start = .{ .line = r.line, .character = r.character },
                .end = .{ .line = r.line, .character = r.end_character },
            },
        });
    }

    try jsonrpc.writeResult(writer, self.gpa, msg.id.?, results.items);
}
