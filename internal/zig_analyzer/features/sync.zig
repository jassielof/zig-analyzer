//! `textDocument/didOpen` / `didChange` / `didClose` — full-document sync
//! (no `range`/`rangeLength`, exactly one whole-text change per
//! `didChange`) — plus the `publishDiagnostics` notification both `didOpen`
//! and `didChange` trigger after reparsing.

const std = @import("std");
const Io = std.Io;
const jsonrpc = @import("jsonrpc").jsonrpc;
const parse = @import("../analysis/queries/parse.zig");
const semantic_diagnostics = @import("../analysis/queries/semantic_diagnostics.zig");
const server_mod = @import("../server.zig");
const Server = server_mod.Server;
const Position = server_mod.Position;
const Range = server_mod.Range;

const Diagnostic = struct {
    range: Range,
    severity: u8, // 1 = Error, 4 = Hint (used here for parser notes)
    source: []const u8 = "zig-analyzer",
    message: []const u8,
    /// LSP DiagnosticTag values; `1` = Unnecessary (dims in the editor).
    tags: []const u32 = &.{},
};

pub fn handleDidOpen(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
    const Params = struct {
        textDocument: struct {
            uri: []const u8,
            text: []const u8,
        },
    };
    var parsed = try std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try self.documents.open(parsed.value.textDocument.uri, parsed.value.textDocument.text);
    try publishDiagnostics(self, writer, parsed.value.textDocument.uri);
}

pub fn handleDidChange(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
    const Params = struct {
        textDocument: struct {
            uri: []const u8,
        },
        // Full-document sync only: exactly one change with the whole
        // new text, no `range`/`rangeLength`.
        contentChanges: []const struct {
            text: []const u8,
        },
    };
    var parsed = try std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.contentChanges.len == 0) return;
    const text = parsed.value.contentChanges[parsed.value.contentChanges.len - 1].text;
    try self.documents.change(parsed.value.textDocument.uri, text);
    try publishDiagnostics(self, writer, parsed.value.textDocument.uri);
}

pub fn handleDidClose(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
    const Params = struct {
        textDocument: struct {
            uri: []const u8,
        },
    };
    var parsed = try std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const uri = parsed.value.textDocument.uri;
    self.documents.close(uri);
    self.parse_cache.remove(self.gpa, uri);
    self.item_tree_cache.remove(self.gpa, uri);
    // Clear any diagnostics the client is still showing for a file
    // that's no longer open.
    try jsonrpc.writeNotification(writer, self.gpa, "textDocument/publishDiagnostics", .{
        .uri = uri,
        .diagnostics = &[_]Diagnostic{},
    });
}

/// Reparses `uri` (a cache hit unless its text just changed) and
/// publishes one `textDocument/publishDiagnostics` notification with
/// its current syntax errors.
fn publishDiagnostics(self: *Server, writer: *Io.Writer, uri: []const u8) !void {
    const doc = self.documents.get(uri) orelse return;
    const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
    const ast = parsed_file.ast;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |d| self.gpa.free(d.message);
        diagnostics.deinit(self.gpa);
    }

    for (ast.errors) |err| {
        var message: Io.Writer.Allocating = .init(self.gpa);
        defer message.deinit();
        try ast.renderError(err, &message.writer);

        const loc = ast.tokenLocation(0, err.token);
        const pos: Position = .{ .line = @intCast(loc.line), .character = @intCast(loc.column) };

        try diagnostics.append(self.gpa, .{
            .range = .{ .start = pos, .end = pos },
            .severity = if (err.is_note) 4 else 1,
            .message = try self.gpa.dupe(u8, message.written()),
        });
    }

    // Semantic checks run on error-recovered ASTs too in principle,
    // but a file mid-syntax-error is exactly when they're least
    // trustworthy (e.g. a dangling brace can make half the file look
    // like one giant unused local). Only run them once it parses clean.
    if (ast.errors.len == 0) {
        const semantic = try semantic_diagnostics.check(self.gpa, ast);
        defer semantic_diagnostics.freeDiagnostics(self.gpa, semantic);

        for (semantic) |d| {
            try diagnostics.append(self.gpa, .{
                .range = .{
                    .start = .{ .line = d.line, .character = d.character },
                    .end = .{ .line = d.line, .character = d.end_character },
                },
                .severity = @intFromEnum(d.severity),
                .message = try self.gpa.dupe(u8, d.message),
                .tags = d.tags,
            });
        }
    }

    try jsonrpc.writeNotification(writer, self.gpa, "textDocument/publishDiagnostics", .{
        .uri = uri,
        .diagnostics = diagnostics.items,
    });
}
