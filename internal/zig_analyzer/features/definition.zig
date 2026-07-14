//! `textDocument/definition`. Shares its position→declaration resolution
//! (`Server.resolveRequestPosition`) with `hover.zig` — that and the other
//! genuinely cross-feature helpers (`Server.parseUri`, `Server.AnyDefinition`,
//! `Server.resolveFieldChain`, …) stay on `Server` itself in `../server.zig`
//! rather than living in either file.

const std = @import("std");
const Io = std.Io;
const jsonrpc = @import("jsonrpc").jsonrpc;
const parse = @import("../analysis/queries/parse.zig");
const resolve = @import("../analysis/queries/resolve.zig");
const imports = @import("../analysis/queries/imports.zig");
const server_mod = @import("../server.zig");
const Server = server_mod.Server;
const Position = server_mod.Position;
const Range = server_mod.Range;
const AnyDefinition = Server.AnyDefinition;

const DefinitionParams = struct {
    textDocument: struct { uri: []const u8 },
    position: Position,
};

pub fn handleDefinition(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
    var parsed = std.json.parseFromValue(DefinitionParams, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
        try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid textDocument/definition params");
        return;
    };
    defer parsed.deinit();

    const uri = parsed.value.textDocument.uri;
    const position = parsed.value.position;

    // Prefer the `@import("...")` string itself when the cursor is on
    // it — that was the remaining half of the go-to-definition FIXME
    // (the binding name was already redirected in redirectImportBinding).
    if (try definitionForImportString(self, uri, position)) |any| {
        defer self.freeAnyDefinition(any);
        const origin = try importStringOriginRange(self, uri, position);
        try writeDefinitionResponse(self, writer, msg.id.?, any, origin);
        return;
    }

    const initial = try self.resolveRequestPosition(uri, position) orelse {
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
        return;
    };
    defer self.freeAnyDefinition(initial);

    // `redirectImportBinding` jumps straight into the imported file —
    // right for a bare reference to the binding (`completions` on its
    // own, or its own declaration site), but wrong when the click was
    // on the *base* of a dotted access (`completions` in
    // `completions.Shell`): there, `resolveRequestPosition` already
    // resolved to the local `const completions = @import(...)` line,
    // and that's where a base-of-a-namespace click should stop —
    // matching how e.g. Go's tooling treats `pkg.Symbol`. The field
    // side (`Shell`) is handled separately, by `resolveAt` refusing to
    // bare-match it (see resolve.zig) so it falls through to
    // `resolveFieldChain`'s real cross-file resolution instead.
    const any = if (try isFieldAccessBaseAt(self, uri, position))
        AnyDefinition{ .uri = try self.gpa.dupe(u8, initial.uri), .def = initial.def }
    else
        try redirectImportBinding(self, initial.uri, initial.def);
    defer self.freeAnyDefinition(any);

    const origin = try identifierOriginRange(self, uri, position);
    try writeDefinitionResponse(self, writer, msg.id.?, any, origin);
}

/// The full `"a/b.zig"` path text (quotes excluded) of the
/// `@import(...)` string at `position`, or `null` if `position` isn't
/// inside one — used as `LocationLink.originSelectionRange` so the
/// *entire* path underlines as one span on ctrl+hover, instead of
/// VS Code's default per-word-boundary underline fragmenting it at
/// every `.`/`/` (e.g. "../../Diagnostic.zig" underlining
/// "Diagnostic" and "zig" as two separate spans).
fn importStringOriginRange(self: *Server, uri: []const u8, position: Position) !?Range {
    const doc = self.documents.get(uri) orelse return null;
    const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
    const imports_list = try self.findImportsFor(parsed_file.ast, uri);
    defer imports.freeImports(self.gpa, imports_list);

    const offset = resolve.positionToOffset(parsed_file.ast.source, .{ .line = position.line, .character = position.character });
    const imp = imports.importAtOffset(imports_list, parsed_file.ast, offset) orelse return null;

    const loc = parsed_file.ast.tokenLocation(0, imp.string_token);
    const token_len = parsed_file.ast.tokenSlice(imp.string_token).len;
    return .{
        .start = .{ .line = @intCast(loc.line), .character = @intCast(loc.column + 1) },
        .end = .{ .line = @intCast(loc.line), .character = @intCast(loc.column + token_len - 1) },
    };
}

/// The span of the identifier token at `position`, or `null` if
/// there isn't one — the origin range for an ordinary (non-import-
/// string) go-to-definition.
fn identifierOriginRange(self: *Server, uri: []const u8, position: Position) !?Range {
    const doc = self.documents.get(uri) orelse return null;
    const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
    const offset = resolve.positionToOffset(parsed_file.ast.source, .{ .line = position.line, .character = position.character });
    const tok = resolve.identifierTokenAt(parsed_file.ast, offset) orelse return null;
    const loc = parsed_file.ast.tokenLocation(0, tok);
    const len = parsed_file.ast.tokenSlice(tok).len;
    return .{
        .start = .{ .line = @intCast(loc.line), .character = @intCast(loc.column) },
        .end = .{ .line = @intCast(loc.line), .character = @intCast(loc.column + len) },
    };
}

/// Writes a `textDocument/definition` result as `LocationLink[]` when
/// the client declared `linkSupport` (so `origin` can widen the
/// ctrl+hover underline beyond a single word), or plain `Location`
/// otherwise — `origin` is simply ignored in that case, since
/// `Location` has no field for it.
fn writeDefinitionResponse(self: *Server, writer: *Io.Writer, id: std.json.Value, any: AnyDefinition, origin: ?Range) !void {
    const target_range: Range = .{
        .start = .{ .line = any.def.line, .character = any.def.character },
        .end = .{ .line = any.def.line, .character = any.def.end_character },
    };

    if (self.definition_link_support) {
        const LocationLinkResult = struct {
            originSelectionRange: ?Range = null,
            targetUri: []const u8,
            targetRange: Range,
            targetSelectionRange: Range,
        };
        const links = [_]LocationLinkResult{.{
            .originSelectionRange = origin,
            .targetUri = any.uri,
            .targetRange = target_range,
            .targetSelectionRange = target_range,
        }};
        try jsonrpc.writeResult(writer, self.gpa, id, &links);
        return;
    }

    const LocationResult = struct { uri: []const u8, range: Range };
    try jsonrpc.writeResult(writer, self.gpa, id, LocationResult{ .uri = any.uri, .range = target_range });
}

fn isFieldAccessBaseAt(self: *Server, uri: []const u8, position: Position) !bool {
    const doc = self.documents.get(uri) orelse return false;
    const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
    const offset = resolve.positionToOffset(parsed_file.ast.source, .{ .line = position.line, .character = position.character });
    const tok = resolve.identifierTokenAt(parsed_file.ast, offset) orelse return false;
    return resolve.isFieldAccessBase(parsed_file.ast, tok);
}

/// If `position` is inside an `@import("...")` string literal on a
/// top-level import binding, returns a definition pointing at the
/// start of the imported file (including `std` when `zig_lib_dir` is
/// known). The imported file doesn't need to be open.
fn definitionForImportString(self: *Server, uri: []const u8, position: Position) !?AnyDefinition {
    const doc = self.documents.get(uri) orelse return null;
    const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
    const imports_list = try self.findImportsFor(parsed_file.ast, uri);
    defer imports.freeImports(self.gpa, imports_list);

    const offset = resolve.positionToOffset(parsed_file.ast.source, .{ .line = position.line, .character = position.character });
    const imp = imports.importAtOffset(imports_list, parsed_file.ast, offset) orelse return null;
    const target_uri = imp.uri orelse return null;
    return .{
        .uri = try self.gpa.dupe(u8, target_uri),
        .def = .{ .line = 0, .character = 0, .end_character = 0, .signature = "" },
    };
}

/// If `def` (already resolved, in the file at `uri`) is itself a
/// top-level import binding (`const helpers = @import("helpers.zig");`),
/// returns a `Definition` redirected to the start of the imported file
/// instead of the local `const` line — matches how most editors treat
/// go-to-definition on a module/namespace identifier. The imported
/// file doesn't need to be open/tracked for this: unlike
/// `Server.resolveFieldChain` (which needs the target's content to
/// resolve a specific member), this only needs its URI. Otherwise
/// returns `def` unchanged. Always returns an owned `uri`, matching
/// `Server.resolveRequestPosition`'s contract.
fn redirectImportBinding(self: *Server, uri: []const u8, def: resolve.Definition) !AnyDefinition {
    const parsed = try self.parseUri(uri) orelse return .{ .uri = try self.gpa.dupe(u8, uri), .def = def };
    defer parsed.deinit(self);
    const decl_name = Server.nameOfDefinition(parsed.ast, def);

    const imports_list = try self.findImportsFor(parsed.ast, uri);
    defer imports.freeImports(self.gpa, imports_list);
    for (imports_list) |imp| {
        if (!std.mem.eql(u8, imp.name, decl_name)) continue;
        const target_uri = imp.uri orelse break;
        return .{
            .uri = try self.gpa.dupe(u8, target_uri),
            .def = .{ .line = 0, .character = 0, .end_character = 0, .signature = def.signature },
        };
    }
    return .{ .uri = try self.gpa.dupe(u8, uri), .def = def };
}
