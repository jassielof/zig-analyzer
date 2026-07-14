//! `textDocument/codeLens` — a "N references" lens above every top-level
//! declaration. zls doesn't have this; keep it working.

const std = @import("std");
const Io = std.Io;
const jsonrpc = @import("jsonrpc").jsonrpc;
const parse = @import("../analysis/queries/parse.zig");
const item_tree = @import("../analysis/queries/item_tree.zig");
const resolve = @import("../analysis/queries/resolve.zig");
const server_mod = @import("../server.zig");
const Server = server_mod.Server;
const Range = server_mod.Range;

pub fn handleCodeLens(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
    const Params = struct { textDocument: struct { uri: []const u8 } };
    var parsed = std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
        try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid textDocument/codeLens params");
        return;
    };
    defer parsed.deinit();

    const uri = parsed.value.textDocument.uri;
    const doc = self.documents.get(uri) orelse {
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, &[_]u8{});
        return;
    };

    const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
    const tree = try item_tree.itemTree(&self.item_tree_cache, self.gpa, uri, parsed_file.ast, doc.revision);

    const CodeLensResult = struct {
        range: Range,
        command: struct { title: []const u8, command: []const u8 = "" },
    };
    var lenses: std.ArrayList(CodeLensResult) = .empty;
    defer {
        for (lenses.items) |l| self.gpa.free(l.command.title);
        lenses.deinit(self.gpa);
    }

    for (tree.items) |item| {
        const def = resolve.definitionForRootItem(parsed_file.ast, item.name) orelse continue;
        const refs = try resolve.findReferences(self.gpa, parsed_file.ast, tree.*, item.name, def.line, def.character);
        defer self.gpa.free(refs);

        const title = if (refs.len == 1)
            try self.gpa.dupe(u8, "1 reference")
        else
            try std.fmt.allocPrint(self.gpa, "{d} references", .{refs.len});

        try lenses.append(self.gpa, .{
            .range = .{
                .start = .{ .line = def.line, .character = def.character },
                .end = .{ .line = def.line, .character = def.end_character },
            },
            .command = .{ .title = title },
        });
    }

    try jsonrpc.writeResult(writer, self.gpa, msg.id.?, lenses.items);
}
