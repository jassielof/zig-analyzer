//! `textDocument/hover`. See `definition.zig`'s module doc comment for why
//! the position-resolution helpers this shares with it stay on `Server`
//! rather than living in either file.

const std = @import("std");
const Io = std.Io;
const Ast = std.zig.Ast;
const jsonrpc = @import("jsonrpc").jsonrpc;
const parse = @import("../analysis/queries/parse.zig");
const resolve = @import("../analysis/queries/resolve.zig");
const imports = @import("../analysis/queries/imports.zig");
const doc_comments = @import("../analysis/queries/doc_comments.zig");
const server_mod = @import("../server.zig");
const Server = server_mod.Server;
const Position = server_mod.Position;
const Range = server_mod.Range;
const AnyDefinition = Server.AnyDefinition;

const DefinitionParams = struct {
    textDocument: struct { uri: []const u8 },
    position: Position,
};

pub fn handleHover(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
    var parsed = std.json.parseFromValue(DefinitionParams, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
        try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid textDocument/hover params");
        return;
    };
    defer parsed.deinit();

    const uri = parsed.value.textDocument.uri;
    const position = parsed.value.position;

    // `@import("...")` string hover: show the target file's container
    // docs (`//!`), with a range covering the string literal.
    if (try hoverForImportString(self, uri, position)) |hover| {
        defer {
            self.gpa.free(hover.value);
        }
        const HoverContents = struct { kind: []const u8 = "markdown", value: []const u8 };
        const HoverResult = struct {
            contents: HoverContents,
            range: Range,
        };
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, HoverResult{
            .contents = .{ .value = hover.value },
            .range = hover.range,
        });
        return;
    }

    // `@This()` → enclosing container docs (file `//!` or nested struct).
    if (try hoverForThis(self, uri, position)) |hover| {
        defer self.gpa.free(hover.value);
        const HoverContents = struct { kind: []const u8 = "markdown", value: []const u8 };
        const HoverResult = struct {
            contents: HoverContents,
            range: Range,
        };
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, HoverResult{
            .contents = .{ .value = hover.value },
            .range = hover.range,
        });
        return;
    }

    const any = try self.resolveRequestPosition(uri, position) orelse {
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
        return;
    };
    defer self.freeAnyDefinition(any);

    // Doctest + declaration docs live on the *declaration's* file.
    var doctest: ?[]u8 = null;
    defer if (doctest) |dt| self.gpa.free(dt);
    var docs: ?[]const u8 = null;
    defer if (docs) |d| self.gpa.free(d);

    if (try self.parseUri(any.uri)) |target| {
        defer target.deinit(self);
        const decl_name = Server.nameOfDefinition(target.ast, any.def);
        if (resolve.findDoctest(target.ast, decl_name)) |raw| {
            doctest = try formatDoctestBody(self.gpa, raw);
        }
        // Import re-exports / module namespaces: show the target file's
        // `//!` container docs (`std.fmt` → fmt.zig's header).
        if (std.mem.startsWith(u8, any.def.signature, "@import(")) {
            docs = try doc_comments.getContainerDocComments(self.gpa, target.ast);
        } else if (try containerDocsForImportBinding(self, uri, decl_name)) |container| {
            // Import bindings show the *imported file's* container docs,
            // not (usually nonexistent) docs on the local `const`.
            docs = container;
        } else {
            docs = try doc_comments.getDocCommentsForRootName(self.gpa, target.ast, decl_name);
            // A plain alias (`const Ast = std.zig.Ast;`) usually has
            // no doc comment of its own — fall through to whatever
            // it points at, so hovering the alias shows the same
            // docs as hovering its target does.
            if (docs == null) {
                docs = try aliasedDocComments(self, any.uri, target.ast, decl_name);
            }
        }
    }

    const value = try formatHoverMarkdown(self.gpa, any.def.signature, docs, doctest);
    defer self.gpa.free(value);

    // Hover's range highlights the hovered word in the *current*
    // document. When we resolved cross-file, `any.def` is in the
    // other file — re-derive a range from the request position's
    // identifier instead so the highlight stays local.
    const range = try hoverRangeAt(self, uri, position, any);

    const HoverContents = struct { kind: []const u8 = "markdown", value: []const u8 };
    const HoverResult = struct {
        contents: HoverContents,
        range: Range,
    };
    try jsonrpc.writeResult(writer, self.gpa, msg.id.?, HoverResult{
        .contents = .{ .value = value },
        .range = range,
    });
}

const HoverPayload = struct { value: []u8, range: Range };

fn hoverForThis(self: *Server, uri: []const u8, position: Position) !?HoverPayload {
    const doc = self.documents.get(uri) orelse return null;
    const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
    const offset = resolve.positionToOffset(parsed_file.ast.source, .{ .line = position.line, .character = position.character });
    const tok = resolve.builtinTokenAt(parsed_file.ast, offset) orelse return null;
    if (!std.mem.eql(u8, parsed_file.ast.tokenSlice(tok), "@This")) return null;

    const enc = resolve.enclosingContainerAt(parsed_file.ast, offset);
    var docs: ?[]const u8 = null;
    defer if (docs) |d| self.gpa.free(d);

    docs = try doc_comments.getContainerDocCommentsForNode(self.gpa, parsed_file.ast, enc.container_node);
    // Nested named struct without `//!`: fall back to `///` on `const Foo`.
    if (docs == null) {
        if (enc.owner_node) |owner| {
            docs = try doc_comments.getDocComments(self.gpa, parsed_file.ast, owner);
        }
    }

    const signature = if (enc.owner_name) |n|
        try std.fmt.allocPrint(self.gpa, "{s}", .{n})
    else
        try self.gpa.dupe(u8, "@This()");
    defer self.gpa.free(signature);

    const value = try formatHoverMarkdown(self.gpa, signature, docs, null);
    const loc = parsed_file.ast.tokenLocation(0, tok);
    const token_len = parsed_file.ast.tokenSlice(tok).len;
    return .{
        .value = value,
        .range = .{
            .start = .{ .line = @intCast(loc.line), .character = @intCast(loc.column) },
            .end = .{ .line = @intCast(loc.line), .character = @intCast(loc.column + token_len) },
        },
    };
}

fn hoverForImportString(self: *Server, uri: []const u8, position: Position) !?HoverPayload {
    const doc = self.documents.get(uri) orelse return null;
    const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
    const imports_list = try self.findImportsFor(parsed_file.ast, uri);
    defer imports.freeImports(self.gpa, imports_list);

    const offset = resolve.positionToOffset(parsed_file.ast.source, .{ .line = position.line, .character = position.character });
    const imp = imports.importAtOffset(imports_list, parsed_file.ast, offset) orelse return null;
    const target_uri = imp.uri orelse return null;

    // Excludes the surrounding quote characters — only the path text
    // itself should be part of the range VS Code underlines on
    // ctrl+hover, not the quotes around it. Zig string-literal tokens
    // are always `"..."` (single-line only), so trimming exactly one
    // character off each end is safe.
    const loc = parsed_file.ast.tokenLocation(0, imp.string_token);
    const token_len = parsed_file.ast.tokenSlice(imp.string_token).len;
    const range: Range = .{
        .start = .{ .line = @intCast(loc.line), .character = @intCast(loc.column + 1) },
        .end = .{ .line = @intCast(loc.line), .character = @intCast(loc.column + token_len - 1) },
    };

    const signature = try std.fmt.allocPrint(self.gpa, "@import(\"{s}\")", .{imp.path});
    defer self.gpa.free(signature);

    var docs: ?[]const u8 = null;
    defer if (docs) |d| self.gpa.free(d);
    docs = try containerDocsForUri(self, target_uri);

    const value = try formatHoverMarkdown(self.gpa, signature, docs, null);
    return .{ .value = value, .range = range };
}

/// If `decl_name` in `importer_uri` is an import binding, returns the
/// imported file's `//!` container docs (owned).
fn containerDocsForImportBinding(self: *Server, importer_uri: []const u8, decl_name: []const u8) !?[]const u8 {
    const doc = self.documents.get(importer_uri) orelse return null;
    const parsed_file = try parse.parse(&self.parse_cache, self.gpa, importer_uri, doc.text, doc.revision);
    const imports_list = try self.findImportsFor(parsed_file.ast, importer_uri);
    defer imports.freeImports(self.gpa, imports_list);
    for (imports_list) |imp| {
        if (!std.mem.eql(u8, imp.name, decl_name)) continue;
        const target_uri = imp.uri orelse return null;
        return try containerDocsForUri(self, target_uri);
    }
    return null;
}

/// If `decl_name` in `ast` (the file at `uri`) is a plain alias
/// (`const Ast = std.zig.Ast;` — a dotted chain with no calls) whose
/// base resolves through an import binding, returns the aliased
/// target's own doc comment. This is what lets hovering the alias
/// itself (`const Ast`) show the same docs as hovering what it
/// points at (`std.zig.Ast`) already does via cross-file resolution.
fn aliasedDocComments(self: *Server, uri: []const u8, ast: Ast, decl_name: []const u8) !?[]const u8 {
    const init_node = resolve.rootVarDeclInitNode(ast, decl_name) orelse return null;
    if (!resolve.isPlainFieldAccessChain(ast, init_node)) return null;

    const chain = try resolve.fieldAccessChainFromToken(self.gpa, ast, ast.lastToken(init_node));
    defer self.gpa.free(chain);
    if (chain.len < 2) return null;

    const cross = try self.resolveFieldChain(uri, ast, chain) orelse return null;
    defer self.freeAnyDefinition(cross);

    const target = try self.parseUri(cross.uri) orelse return null;
    defer target.deinit(self);
    const target_name = Server.nameOfDefinition(target.ast, cross.def);
    return try doc_comments.getDocCommentsForRootName(self.gpa, target.ast, target_name);
}

fn containerDocsForUri(self: *Server, target_uri: []const u8) !?[]const u8 {
    const target = try self.parseUri(target_uri) orelse return null;
    defer target.deinit(self);
    return try doc_comments.getContainerDocComments(self.gpa, target.ast);
}

fn hoverRangeAt(self: *Server, uri: []const u8, position: Position, any: AnyDefinition) !Range {
    // Same-file: the definition's own span is the right highlight.
    if (std.mem.eql(u8, uri, any.uri)) {
        return .{
            .start = .{ .line = any.def.line, .character = any.def.character },
            .end = .{ .line = any.def.line, .character = any.def.end_character },
        };
    }
    // Cross-file: highlight the identifier under the cursor in the
    // requesting document instead.
    const doc = self.documents.get(uri) orelse {
        return .{
            .start = position,
            .end = position,
        };
    };
    const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
    const offset = resolve.positionToOffset(parsed_file.ast.source, .{ .line = position.line, .character = position.character });
    // Prefer the field of a `base.field` access when that's what was
    // hovered; otherwise the identifier token at the offset.
    if (resolve.fieldAccessAt(parsed_file.ast, .{ .line = position.line, .character = position.character })) |fa| {
        _ = fa;
        // fieldAccessAt doesn't expose the field token; fall through
        // to the identifier-at-offset scan.
    }
    var idx: Ast.TokenIndex = 0;
    while (idx < parsed_file.ast.tokens.len) : (idx += 1) {
        if (parsed_file.ast.tokenTag(idx) != .identifier) continue;
        const start = parsed_file.ast.tokenStart(idx);
        const slice = parsed_file.ast.tokenSlice(idx);
        const end = start + slice.len;
        if (offset >= start and offset < end) {
            const loc = parsed_file.ast.tokenLocation(0, idx);
            return .{
                .start = .{ .line = @intCast(loc.line), .character = @intCast(loc.column) },
                .end = .{ .line = @intCast(loc.line), .character = @intCast(loc.column + slice.len) },
            };
        }
    }
    return .{ .start = position, .end = position };
}

fn formatHoverMarkdown(
    gpa: std.mem.Allocator,
    signature: []const u8,
    docs: ?[]const u8,
    doctest: ?[]const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.print(gpa,
        \\```zig
        \\{s}
        \\```
    , .{signature});

    if (docs) |d| {
        if (d.len > 0) {
            try out.appendSlice(gpa, "\n\n");
            try out.appendSlice(gpa, d);
        }
    }

    if (doctest) |dt| {
        try out.print(gpa,
            \\
            \\
            \\---
            \\
            \\## Doctest example
            \\
            \\```zig
            \\{s}
            \\```
        , .{dt});
    }

    return try out.toOwnedSlice(gpa);
}

/// `resolve.findDoctest` returns the raw `{ ... }` block source —
/// braces and whatever indentation the `test` block happened to sit
/// at in the source file both included. Strips the braces and
/// dedents by the block's minimum common leading whitespace, so the
/// doctest renders as a clean, left-aligned snippet in hover instead
/// of carrying that indentation along with it.
fn formatDoctestBody(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const inner = if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}')
        trimmed[1 .. trimmed.len - 1]
    else
        trimmed;

    var min_indent: usize = std.math.maxInt(usize);
    var lines = std.mem.splitScalar(u8, inner, '\n');
    while (lines.next()) |line| {
        if (std.mem.trimEnd(u8, line, " \t\r").len == 0) continue; // blank lines don't count
        var indent: usize = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) indent += 1;
        min_indent = @min(min_indent, indent);
    }
    if (min_indent == std.math.maxInt(usize)) min_indent = 0;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    lines = std.mem.splitScalar(u8, inner, '\n');
    var first = true;
    while (lines.next()) |line| {
        const stripped = std.mem.trimEnd(u8, line, " \t\r");
        const dedented = if (stripped.len > min_indent) stripped[min_indent..] else "";
        if (!first) try out.append(gpa, '\n');
        try out.appendSlice(gpa, dedented);
        first = false;
    }

    const result = std.mem.trim(u8, out.items, "\n");
    const owned = try gpa.dupe(u8, result);
    out.deinit(gpa);
    return owned;
}
