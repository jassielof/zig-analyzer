//! Single-file identifier resolution: function parameters, local
//! `const`/`var` declarations in a function's immediate body, and
//! top-level item-tree entries. Cross-file resolution (via imports) is
//! Phase 6.
//!
//! Local resolution here is intentionally limited to a function's
//! immediate body block — statements nested inside `if`/`while`/`for`/
//! etc. within it aren't walked. Full lexical scope nesting is more than
//! this phase's "single-file resolution" milestone calls for. This is a
//! safe limitation, not a silent-wrong one: it can miss a match it should
//! find, but it never returns the wrong declaration.
//!
//! Not itself cached — it's cheap relative to parsing/item-tree building
//! (a handful of node visits per request), and its inputs (`Ast`,
//! `ItemTree`) are already memoized by their own queries.

const std = @import("std");
const Ast = std.zig.Ast;
const item_tree_mod = @import("item_tree.zig");
const ItemTree = item_tree_mod.ItemTree;

pub const Position = struct { line: u32, character: u32 };

/// A declaration's location within the same file it was resolved in.
pub const Definition = struct {
    line: u32,
    character: u32,
    end_character: u32,
};

/// Byte-offset-based, like `std.zig.Ast.tokenLocation` itself — exact for
/// ASCII source, an approximation of LSP's UTF-16 `character` semantics
/// otherwise. Good enough for identifiers, which are ASCII in practice.
fn positionToOffset(source: []const u8, pos: Position) u32 {
    var line: u32 = 0;
    var i: usize = 0;
    while (line < pos.line) : (line += 1) {
        const nl = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse return @intCast(source.len);
        i = nl + 1;
    }
    return @intCast(@min(source.len, i + pos.character));
}

/// Linear scan over every token; fine at the file sizes this targets for
/// now. Could binary-search `tokenStart` if it ever shows up as hot.
fn identifierTokenAt(ast: Ast, offset: u32) ?Ast.TokenIndex {
    var idx: Ast.TokenIndex = 0;
    while (idx < ast.tokens.len) : (idx += 1) {
        if (ast.tokenTag(idx) != .identifier) continue;
        const start = ast.tokenStart(idx);
        const end = start + ast.tokenSlice(idx).len;
        if (offset >= start and offset < end) return idx;
    }
    return null;
}

fn definitionForToken(ast: Ast, token: Ast.TokenIndex) Definition {
    const loc = ast.tokenLocation(0, token);
    return .{
        .line = @intCast(loc.line),
        .character = @intCast(loc.column),
        .end_character = @intCast(loc.column + ast.tokenSlice(token).len),
    };
}

/// Re-walks root decls for the token position of `name` — cheap (root
/// decls only, no recursion into bodies) and keeps `Item` itself free of
/// position bookkeeping that only resolution needs. Also the entry point
/// for cross-file resolution (Phase 6): the caller resolves `name` against
/// an *imported* file's item tree, then calls this with that file's `Ast`
/// to get a location in it.
fn definitionForRootItem(ast: Ast, name: []const u8) ?Definition {
    for (ast.rootDecls()) |node| {
        switch (ast.nodeTag(node)) {
            .fn_decl, .fn_proto, .fn_proto_one, .fn_proto_simple, .fn_proto_multi => {
                const proto_node = if (ast.nodeTag(node) == .fn_decl)
                    (ast.nodeData(node).node_and_node)[0]
                else
                    node;
                var buf: [1]Ast.Node.Index = undefined;
                const proto = ast.fullFnProto(&buf, proto_node) orelse continue;
                const name_token = proto.name_token orelse continue;
                if (std.mem.eql(u8, ast.tokenSlice(name_token), name)) return definitionForToken(ast, name_token);
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                const var_decl = ast.fullVarDecl(node) orelse continue;
                const name_token = var_decl.ast.mut_token + 1;
                if (std.mem.eql(u8, ast.tokenSlice(name_token), name)) return definitionForToken(ast, name_token);
            },
            else => {},
        }
    }
    return null;
}

/// Finds the identifier token at `pos`, then resolves it: first the
/// enclosing function's parameters and immediate local declarations, then
/// the file's top-level item tree. Returns `null` if there's no
/// identifier at `pos`, or it doesn't resolve to anything this query
/// knows how to find.
pub fn resolveAt(ast: Ast, item_tree: ItemTree, pos: Position) ?Definition {
    const offset = positionToOffset(ast.source, pos);
    const ref_token = identifierTokenAt(ast, offset) orelse return null;
    const name = ast.tokenSlice(ref_token);

    for (ast.rootDecls()) |node| {
        if (ast.nodeTag(node) != .fn_decl) continue;
        const proto_node, const body_node = ast.nodeData(node).node_and_node;

        const body_start = ast.tokenStart(ast.firstToken(body_node));
        const body_end = body_start + ast.getNodeSource(body_node).len;
        if (offset < body_start or offset >= body_end) continue;

        var buf: [1]Ast.Node.Index = undefined;
        if (ast.fullFnProto(&buf, proto_node)) |proto| {
            var it = proto.iterate(&ast);
            while (it.next()) |param| {
                const name_token = param.name_token orelse continue;
                if (std.mem.eql(u8, ast.tokenSlice(name_token), name)) {
                    return definitionForToken(ast, name_token);
                }
            }
        }

        var buf2: [2]Ast.Node.Index = undefined;
        const stmts = ast.blockStatements(&buf2, body_node) orelse &.{};
        for (stmts) |stmt| {
            const var_decl = ast.fullVarDecl(stmt) orelse continue;
            const name_token = var_decl.ast.mut_token + 1;
            if (std.mem.eql(u8, ast.tokenSlice(name_token), name)) {
                return definitionForToken(ast, name_token);
            }
        }

        break; // found the enclosing function; nothing else to check locally
    }

    return resolveTopLevel(ast, item_tree, name);
}

/// Resolves `name` against `item_tree`'s top-level entries, returning its
/// declaration location in `ast` — the same file `item_tree` was built
/// from. Exposed separately from `resolveAt` so cross-file resolution
/// (Phase 6) can call it with an *imported* file's `Ast`/`ItemTree` after
/// following an `@import` binding, without re-deriving `resolveAt`'s
/// local-scope logic for a file it only needs the item tree of.
pub fn resolveTopLevel(ast: Ast, item_tree: ItemTree, name: []const u8) ?Definition {
    if (item_tree.find(name) == null) return null;
    return definitionForRootItem(ast, name);
}

pub const FieldAccess = struct { base: []const u8, field: []const u8 };

/// If the identifier at `pos` is the right-hand side of a simple
/// `base.field` access, returns both names — used for cross-file
/// resolution when `base` is a local import binding
/// (`const base = @import("...")`). Only a single `.` hop is recognized;
/// `a.b.c` resolves at most `b.c` against `b`'s immediate base `a`.
pub fn fieldAccessAt(ast: Ast, pos: Position) ?FieldAccess {
    const offset = positionToOffset(ast.source, pos);
    const field_token = identifierTokenAt(ast, offset) orelse return null;
    if (field_token < 2) return null;
    if (ast.tokenTag(field_token - 1) != .period) return null;
    if (ast.tokenTag(field_token - 2) != .identifier) return null;
    return .{
        .base = ast.tokenSlice(field_token - 2),
        .field = ast.tokenSlice(field_token),
    };
}

const testing = std.testing;
const item_tree_query = @import("item_tree.zig");

fn resolveInSource(gpa: std.mem.Allocator, source: [:0]const u8, pos: Position) !?Definition {
    var ast = try Ast.parse(gpa, source, .zig);
    defer ast.deinit(gpa);

    var tree = try item_tree_query.build(gpa, ast);
    defer tree.deinit(gpa);

    return resolveAt(ast, tree, pos);
}

test "resolves a function parameter used in the body" {
    const gpa = testing.allocator;
    const source = "fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n";
    //                                                     ^ line 1, "a" at character 11
    const def = (try resolveInSource(gpa, source, .{ .line = 1, .character = 11 })).?;
    try testing.expectEqual(@as(u32, 0), def.line);
    // "a" is the first param, right after "fn add(".
    try testing.expectEqual(@as(u32, 7), def.character);
}

test "resolves a local const declared earlier in the same function body" {
    const gpa = testing.allocator;
    const source = "fn f() i32 {\n    const answer = 42;\n    return answer;\n}\n";
    const def = (try resolveInSource(gpa, source, .{ .line = 2, .character = 12 })).?;
    try testing.expectEqual(@as(u32, 1), def.line);
    try testing.expectEqual(@as(u32, 10), def.character); // "    const answer" -> 'a' at col 10
}

test "resolves a reference to a top-level function via the item tree" {
    const gpa = testing.allocator;
    const source = "fn helper() void {}\nfn main() void {\n    helper();\n}\n";
    const def = (try resolveInSource(gpa, source, .{ .line = 2, .character = 5 })).?;
    try testing.expectEqual(@as(u32, 0), def.line);
    try testing.expectEqual(@as(u32, 3), def.character); // "fn helper" -> 'h' at col 3
}

test "returns null for a position with no identifier" {
    const gpa = testing.allocator;
    const source = "fn f() void {}\n";
    const def = try resolveInSource(gpa, source, .{ .line = 0, .character = 0 }); // "f" of "fn" keyword, not identifier
    try testing.expectEqual(@as(?Definition, null), def);
}

test "returns null for an unresolvable identifier" {
    const gpa = testing.allocator;
    const source = "fn f() void {\n    unknown_name;\n}\n";
    const def = try resolveInSource(gpa, source, .{ .line = 1, .character = 6 });
    try testing.expectEqual(@as(?Definition, null), def);
}
