//! `textDocument/rename` — same-file only, same reason as `references.zig`.

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

fn isValidZigIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    // Rejecting keywords too, so a rename can't silently produce
    // invalid code (e.g. renaming a variable to "const").
    return std.zig.Token.getKeyword(name) == null;
}

pub fn handleRename(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: Position,
        newName: []const u8,
    };
    var parsed = std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
        try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid textDocument/rename params");
        return;
    };
    defer parsed.deinit();

    if (!isValidZigIdentifier(parsed.value.newName)) {
        try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "not a valid Zig identifier");
        return;
    }

    const uri = parsed.value.textDocument.uri;
    const doc = self.documents.get(uri) orelse {
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
        return;
    };

    const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
    const tree = try item_tree.itemTree(&self.item_tree_cache, self.gpa, uri, parsed_file.ast, doc.revision);
    const pos: resolve.Position = .{ .line = parsed.value.position.line, .character = parsed.value.position.character };

    const def = resolve.resolveAt(parsed_file.ast, tree.*, pos) orelse {
        try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "nothing to rename at this position");
        return;
    };
    const target_name = Server.nameOfDefinition(parsed_file.ast, def);

    const refs = try resolve.findReferences(self.gpa, parsed_file.ast, tree.*, target_name, def.line, def.character);
    defer self.gpa.free(refs);

    const TextEditResult = struct { range: Range, newText: []const u8 };
    var edits: std.ArrayList(TextEditResult) = .empty;
    defer edits.deinit(self.gpa);

    try edits.append(self.gpa, .{
        .range = .{
            .start = .{ .line = def.line, .character = def.character },
            .end = .{ .line = def.line, .character = def.end_character },
        },
        .newText = parsed.value.newName,
    });
    for (refs) |r| {
        try edits.append(self.gpa, .{
            .range = .{
                .start = .{ .line = r.line, .character = r.character },
                .end = .{ .line = r.line, .character = r.end_character },
            },
            .newText = parsed.value.newName,
        });
    }

    // `WorkspaceEdit.changes` is a JSON object keyed by URI, which a
    // comptime-known struct can't represent — this is exactly what
    // `std.json.ArrayHashMap` exists for (see its doc comment).
    const Changes = std.json.ArrayHashMap([]const TextEditResult);
    var changes: Changes = .{};
    defer changes.deinit(self.gpa);
    try changes.map.put(self.gpa, uri, edits.items);

    const WorkspaceEditResult = struct { changes: Changes };
    try jsonrpc.writeResult(writer, self.gpa, msg.id.?, WorkspaceEditResult{ .changes = changes });
}
