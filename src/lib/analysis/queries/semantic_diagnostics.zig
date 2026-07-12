//! Structurally-derivable semantic diagnostics: duplicate top-level
//! declarations, unused locals, unused private top-level decls, and
//! unused imports. Unused findings carry LSP's `Unnecessary` tag so
//! editors dim them. Not cached — cheap relative to parsing/item-tree
//! building, same as `resolve.zig`/`imports.zig`.
//!
//! "Unresolved identifier" diagnostics (also named in the project plan's
//! Phase 7 scope) are deliberately deferred, not silently skipped: doing
//! it without a high false-positive rate needs scope-modeling this
//! analyzer doesn't have yet. Concretely, payload captures
//! (`if (x) |v| {}`, `while (it.next()) |item| {}`, `foo() catch |err|
//! {}`) are pervasive in idiomatic Zig and aren't locals `resolve.zig`
//! currently tracks (it only understands `const`/`var` statements), so a
//! naive "does this identifier resolve to anything known" check would
//! flag them constantly. A diagnostic that's wrong on ordinary code is
//! worse than no diagnostic.

const std = @import("std");
const Ast = std.zig.Ast;

pub const Severity = enum(u8) { err = 1, warning = 2, information = 3, hint = 4 };

/// LSP `DiagnosticTag`: `Unnecessary = 1` dims the range in editors.
pub const Tag = enum(u32) { unnecessary = 1 };

pub const Diagnostic = struct {
    line: u32,
    character: u32,
    end_character: u32,
    severity: Severity,
    /// Owned.
    message: []const u8,
    /// Optional LSP diagnostic tags (e.g. Unnecessary for unused code).
    /// Not owned — points at a static slice when set.
    tags: []const u32 = &.{},
};

pub fn freeDiagnostics(gpa: std.mem.Allocator, diags: []const Diagnostic) void {
    for (diags) |d| gpa.free(d.message);
    gpa.free(diags);
}

const TokenLoc = struct { line: u32, character: u32, end_character: u32 };

fn locationOf(ast: Ast, token: Ast.TokenIndex) TokenLoc {
    const loc = ast.tokenLocation(0, token);
    return .{
        .line = @intCast(loc.line),
        .character = @intCast(loc.column),
        .end_character = @intCast(loc.column + ast.tokenSlice(token).len),
    };
}

/// The name token of a root-level fn/var declaration, or `null` if `node`
/// isn't one (mirrors `item_tree.build`'s classification).
fn declNameToken(ast: Ast, node: Ast.Node.Index) ?Ast.TokenIndex {
    return switch (ast.nodeTag(node)) {
        .fn_decl, .fn_proto, .fn_proto_one, .fn_proto_simple, .fn_proto_multi => blk: {
            const proto_node = if (ast.nodeTag(node) == .fn_decl)
                (ast.nodeData(node).node_and_node)[0]
            else
                node;
            var buf: [1]Ast.Node.Index = undefined;
            const proto = ast.fullFnProto(&buf, proto_node) orelse break :blk null;
            break :blk proto.name_token;
        },
        .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => blk: {
            const var_decl = ast.fullVarDecl(node) orelse break :blk null;
            break :blk var_decl.ast.mut_token + 1;
        },
        else => null,
    };
}

/// Flags a top-level declaration whose name was already declared earlier
/// in the same file.
fn checkDuplicateDeclarations(gpa: std.mem.Allocator, ast: Ast, out: *std.ArrayList(Diagnostic)) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);

    for (ast.rootDecls()) |node| {
        const name_token = declNameToken(ast, node) orelse continue;
        const name = ast.tokenSlice(name_token);

        const gop = try seen.getOrPut(gpa, name);
        if (gop.found_existing) {
            const loc = locationOf(ast, name_token);
            try out.append(gpa, .{
                .line = loc.line,
                .character = loc.character,
                .end_character = loc.end_character,
                .severity = .err,
                .message = try std.fmt.allocPrint(gpa, "duplicate declaration of '{s}'", .{name}),
            });
        }
    }
}

/// Flags a `const`/`var` declared directly in a function's immediate body
/// (same scope boundary `resolve.zig` uses) whose name never appears
/// again anywhere later in that function. Names starting with `_` are the
/// conventional intentional-discard marker and are never flagged.
fn checkUnusedLocals(gpa: std.mem.Allocator, ast: Ast, out: *std.ArrayList(Diagnostic)) !void {
    for (ast.rootDecls()) |node| {
        if (ast.nodeTag(node) != .fn_decl) continue;
        const body_node = (ast.nodeData(node).node_and_node)[1];

        var buf: [2]Ast.Node.Index = undefined;
        const stmts = ast.blockStatements(&buf, body_node) orelse continue;

        const body_start = ast.tokenStart(ast.firstToken(body_node));
        const body_end = body_start + ast.getNodeSource(body_node).len;

        for (stmts) |stmt| {
            const var_decl = ast.fullVarDecl(stmt) orelse continue;
            const name_token = var_decl.ast.mut_token + 1;
            const name = ast.tokenSlice(name_token);
            if (name.len > 0 and name[0] == '_') continue;

            var used = false;
            var idx: Ast.TokenIndex = name_token + 1;
            while (idx < ast.tokens.len) : (idx += 1) {
                const start = ast.tokenStart(idx);
                if (start >= body_end) break;
                if (start < body_start) continue;
                if (ast.tokenTag(idx) == .identifier and std.mem.eql(u8, ast.tokenSlice(idx), name)) {
                    used = true;
                    break;
                }
            }

            if (!used) {
                const loc = locationOf(ast, name_token);
                try out.append(gpa, .{
                    .line = loc.line,
                    .character = loc.character,
                    .end_character = loc.end_character,
                    .severity = .hint,
                    .message = try std.fmt.allocPrint(gpa, "unused local variable '{s}'", .{name}),
                    .tags = &.{@intFromEnum(Tag.unnecessary)},
                });
            }
        }
    }
}

/// Flags a non-`pub` top-level function/const whose name never appears
/// again in the file. `pub` declarations are skipped — they may be used
/// from other files we haven't analyzed. Names starting with `_` are the
/// conventional intentional-discard marker. Import bindings are handled
/// separately by `checkUnusedImports` so their messages can say so.
fn checkUnusedPrivateDecls(gpa: std.mem.Allocator, ast: Ast, out: *std.ArrayList(Diagnostic)) !void {
    for (ast.rootDecls()) |node| {
        const name_token = declNameToken(ast, node) orelse continue;
        const name = ast.tokenSlice(name_token);
        if (name.len > 0 and name[0] == '_') continue;

        const is_pub = switch (ast.nodeTag(node)) {
            .fn_decl => blk: {
                const proto_node, _ = ast.nodeData(node).node_and_node;
                var buf: [1]Ast.Node.Index = undefined;
                const proto = ast.fullFnProto(&buf, proto_node) orelse break :blk false;
                break :blk proto.visib_token != null;
            },
            .fn_proto, .fn_proto_one, .fn_proto_simple, .fn_proto_multi => blk: {
                var buf: [1]Ast.Node.Index = undefined;
                const proto = ast.fullFnProto(&buf, node) orelse break :blk false;
                break :blk proto.visib_token != null;
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => blk: {
                const var_decl = ast.fullVarDecl(node) orelse break :blk false;
                break :blk var_decl.visib_token != null;
            },
            else => false,
        };
        if (is_pub) continue;

        // Skip import bindings — `checkUnusedImports` covers them.
        if (isImportBinding(ast, node)) continue;

        if (!nameUsedElsewhere(ast, name, name_token)) {
            const loc = locationOf(ast, name_token);
            const kind: []const u8 = switch (ast.nodeTag(node)) {
                .fn_decl, .fn_proto, .fn_proto_one, .fn_proto_simple, .fn_proto_multi => "function",
                else => "declaration",
            };
            try out.append(gpa, .{
                .line = loc.line,
                .character = loc.character,
                .end_character = loc.end_character,
                .severity = .hint,
                .message = try std.fmt.allocPrint(gpa, "unused {s} '{s}'", .{ kind, name }),
                .tags = &.{@intFromEnum(Tag.unnecessary)},
            });
        }
    }
}

fn isImportBinding(ast: Ast, node: Ast.Node.Index) bool {
    switch (ast.nodeTag(node)) {
        .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {},
        else => return false,
    }
    const var_decl = ast.fullVarDecl(node) orelse return false;
    const init_node = var_decl.ast.init_node.unwrap() orelse return false;
    switch (ast.nodeTag(init_node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
        else => return false,
    }
    return std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(init_node)), "@import");
}

fn checkUnusedImports(gpa: std.mem.Allocator, ast: Ast, out: *std.ArrayList(Diagnostic)) !void {
    for (ast.rootDecls()) |node| {
        if (!isImportBinding(ast, node)) continue;
        const name_token = declNameToken(ast, node) orelse continue;
        const name = ast.tokenSlice(name_token);
        if (name.len > 0 and name[0] == '_') continue;

        if (!nameUsedElsewhere(ast, name, name_token)) {
            const loc = locationOf(ast, name_token);
            try out.append(gpa, .{
                .line = loc.line,
                .character = loc.character,
                .end_character = loc.end_character,
                .severity = .hint,
                .message = try std.fmt.allocPrint(gpa, "unused import '{s}'", .{name}),
                .tags = &.{@intFromEnum(Tag.unnecessary)},
            });
        }
    }
}

fn nameUsedElsewhere(ast: Ast, name: []const u8, decl_token: Ast.TokenIndex) bool {
    var idx: Ast.TokenIndex = 0;
    while (idx < ast.tokens.len) : (idx += 1) {
        if (idx == decl_token) continue;
        if (ast.tokenTag(idx) != .identifier) continue;
        if (std.mem.eql(u8, ast.tokenSlice(idx), name)) return true;
    }
    return false;
}

/// Runs every structural check and returns the combined diagnostics.
/// Caller owns the result; free with `freeDiagnostics`.
pub fn check(gpa: std.mem.Allocator, ast: Ast) ![]const Diagnostic {
    var out: std.ArrayList(Diagnostic) = .empty;
    errdefer {
        for (out.items) |d| gpa.free(d.message);
        out.deinit(gpa);
    }

    try checkDuplicateDeclarations(gpa, ast, &out);
    try checkUnusedLocals(gpa, ast, &out);
    try checkUnusedPrivateDecls(gpa, ast, &out);
    try checkUnusedImports(gpa, ast, &out);

    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

fn checkSource(gpa: std.mem.Allocator, source: [:0]const u8) ![]const Diagnostic {
    var ast = try Ast.parse(gpa, source, .zig);
    defer ast.deinit(gpa);
    return check(gpa, ast);
}

test "flags a duplicate top-level function declaration" {
    const gpa = testing.allocator;
    const diags = try checkSource(gpa, "fn f() void {}\nfn f() void {}\n");
    defer freeDiagnostics(gpa, diags);

    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(@as(u32, 1), diags[0].line);
    try testing.expect(std.mem.indexOf(u8, diags[0].message, "'f'") != null);
}

test "flags a duplicate top-level const declaration" {
    const gpa = testing.allocator;
    const diags = try checkSource(gpa, "const x = 1;\nconst x = 2;\n");
    defer freeDiagnostics(gpa, diags);

    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Severity.err, diags[0].severity);
}

test "no diagnostics for distinctly-named declarations" {
    const gpa = testing.allocator;
    const diags = try checkSource(gpa, "pub fn f() void {}\npub fn g() void {}\npub const x = 1;\n");
    defer freeDiagnostics(gpa, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "flags an unused local variable" {
    const gpa = testing.allocator;
    const diags = try checkSource(gpa, "pub fn f() void {\n    const unused = 1;\n}\n");
    defer freeDiagnostics(gpa, diags);

    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Severity.hint, diags[0].severity);
    try testing.expect(std.mem.indexOf(u8, diags[0].message, "'unused'") != null);
    try testing.expectEqual(@as(usize, 1), diags[0].tags.len);
    try testing.expectEqual(@as(u32, 1), diags[0].tags[0]); // Unnecessary
}

test "does not flag a local variable that's used later in the function" {
    const gpa = testing.allocator;
    const diags = try checkSource(gpa, "pub fn f() i32 {\n    const x = 1;\n    return x;\n}\n");
    defer freeDiagnostics(gpa, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "does not flag a local used only inside a nested block" {
    // Regression guard for the exact false-positive risk this module's
    // doc comment describes: unused-local scanning must search the whole
    // function body, not just its immediate statements, or this would
    // wrongly flag `x`.
    const gpa = testing.allocator;
    const diags = try checkSource(gpa, "pub fn f() void {\n    const x = 1;\n    if (true) {\n        _ = x;\n    }\n}\n");
    defer freeDiagnostics(gpa, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "does not flag a discard-named local" {
    const gpa = testing.allocator;
    const diags = try checkSource(gpa, "pub fn f() void {\n    const _unused = 1;\n}\n");
    defer freeDiagnostics(gpa, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "function parameters are never flagged as unused locals" {
    const gpa = testing.allocator;
    const diags = try checkSource(gpa, "pub fn f(unused_param: i32) void {}\n");
    defer freeDiagnostics(gpa, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "flags an unused private function" {
    const gpa = testing.allocator;
    const diags = try checkSource(gpa, "fn unused() void {}\npub fn main() void {}\n");
    defer freeDiagnostics(gpa, diags);

    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expect(std.mem.indexOf(u8, diags[0].message, "unused function") != null);
    try testing.expectEqual(@as(u32, 1), diags[0].tags[0]);
}

test "does not flag a pub function as unused" {
    const gpa = testing.allocator;
    const diags = try checkSource(gpa, "pub fn usedElsewhere() void {}\n");
    defer freeDiagnostics(gpa, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "flags an unused import" {
    const gpa = testing.allocator;
    const diags = try checkSource(gpa, "const std = @import(\"std\");\n");
    defer freeDiagnostics(gpa, diags);

    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expect(std.mem.indexOf(u8, diags[0].message, "unused import") != null);
}

test "does not flag an import that's used" {
    const gpa = testing.allocator;
    const diags = try checkSource(gpa, "const std = @import(\"std\");\ntest \"t\" {\n    _ = std;\n}\n");
    defer freeDiagnostics(gpa, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}
