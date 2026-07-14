//! `textDocument/completion` — keywords, item-tree names, and in-scope
//! locals normally; inside an `@import("` string, path/module completions
//! instead (see `../analysis/queries/imports.zig`'s `collectImportCompletions`).

const std = @import("std");
const Io = std.Io;
const jsonrpc = @import("jsonrpc").jsonrpc;
const parse = @import("../analysis/queries/parse.zig");
const item_tree = @import("../analysis/queries/item_tree.zig");
const resolve = @import("../analysis/queries/resolve.zig");
const imports = @import("../analysis/queries/imports.zig");
const server_mod = @import("../server.zig");
const Server = server_mod.Server;
const Position = server_mod.Position;

const DefinitionParams = struct {
    textDocument: struct { uri: []const u8 },
    position: Position,
};

const keywords = [_][]const u8{
    "const",       "var",     "fn",     "pub",      "return",   "if",        "else",
    "while",       "for",     "switch", "struct",   "enum",     "union",     "error",
    "try",         "catch",   "defer",  "errdefer", "break",    "continue",  "comptime",
    "inline",      "export",  "extern", "test",     "null",     "undefined", "true",
    "false",       "and",     "or",     "orelse",   "async",    "await",     "suspend",
    "nosuspend",   "resume",  "packed", "align",    "volatile", "allowzero", "threadlocal",
    "linksection", "noalias", "opaque", "anytype",  "anyframe",
};

pub fn handleCompletion(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
    // LSP `CompletionItemKind`: 3 = Function, 6 = Variable, 14 = Keyword.
    const CompletionItemResult = struct { label: []const u8, kind: u8 };
    var parsed = std.json.parseFromValue(DefinitionParams, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
        try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid textDocument/completion params");
        return;
    };
    defer parsed.deinit();

    const uri = parsed.value.textDocument.uri;

    // Inside an `@import("` string, only module/path completions make
    // sense — keywords and in-scope identifiers would just be noise
    // (and aren't even syntactically valid there).
    if (try writeImportStringCompletions(self, writer, msg.id.?, uri, parsed.value.position)) return;

    var items: std.ArrayList(CompletionItemResult) = .empty;
    defer items.deinit(self.gpa);

    for (keywords) |kw| try items.append(self.gpa, .{ .label = kw, .kind = 14 });

    if (self.documents.get(uri)) |doc| {
        const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
        const tree = try item_tree.itemTree(&self.item_tree_cache, self.gpa, uri, parsed_file.ast, doc.revision);

        for (tree.items) |item| {
            try items.append(self.gpa, .{ .label = item.name, .kind = if (item.kind == .function) @as(u8, 3) else @as(u8, 6) });
        }

        const offset = resolve.positionToOffset(parsed_file.ast.source, .{
            .line = parsed.value.position.line,
            .character = parsed.value.position.character,
        });
        var local_names: std.ArrayList([]const u8) = .empty;
        defer local_names.deinit(self.gpa);
        try resolve.collectLocalScopeNames(self.gpa, parsed_file.ast, offset, &local_names);
        for (local_names.items) |name| try items.append(self.gpa, .{ .label = name, .kind = 6 });
    }

    try jsonrpc.writeResult(writer, self.gpa, msg.id.?, items.items);
}

/// If `position` is inside an `@import("` string, writes a completion
/// response of path/module suggestions and returns `true` (even when
/// there happen to be none — an empty-but-handled result still means
/// "don't fall through to keyword/identifier completions"). Returns
/// `false`, writing nothing, when `position` isn't inside such a
/// string at all.
fn writeImportStringCompletions(self: *Server, writer: *Io.Writer, id: std.json.Value, uri: []const u8, position: Position) !bool {
    const doc = self.documents.get(uri) orelse return false;
    const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
    const offset = resolve.positionToOffset(parsed_file.ast.source, .{ .line = position.line, .character = position.character });
    const prefix = imports.importStringPrefixAt(parsed_file.ast, offset) orelse return false;

    self.ensurePackagesForUri(uri);
    const completions = try imports.collectImportCompletions(self.gpa, self.io, uri, prefix, self.zig_lib_dir, &self.packages);
    defer imports.freeImportCompletions(self.gpa, completions);

    // LSP `CompletionItemKind`: 9 = Module, 17 = File, 19 = Folder.
    const CompletionItemResult = struct { label: []const u8, kind: u8 };
    var items: std.ArrayList(CompletionItemResult) = .empty;
    defer items.deinit(self.gpa);
    for (completions) |c| {
        const kind: u8 = if (c.is_directory) 19 else if (std.mem.endsWith(u8, c.label, ".zig")) 17 else 9;
        try items.append(self.gpa, .{ .label = c.label, .kind = kind });
    }

    try jsonrpc.writeResult(writer, self.gpa, id, items.items);
    return true;
}
