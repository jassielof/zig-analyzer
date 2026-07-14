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
const lsp = @import("lsp");

pub const Position = struct { line: u32, character: u32 };

/// A declaration's location within the same file it was resolved in,
/// plus the source text describing it — used for hover as well as
/// go-to-definition, since both need to resolve to the same declaration
/// site.
pub const Definition = struct {
    line: u32,
    character: u32,
    end_character: u32,
    /// Borrowed from `Ast.source`. For functions/top-level vars, the
    /// signature (no body) — the same text `item_tree.Item.signature`
    /// holds. For locals, the full declaration statement. For params,
    /// `name: Type`.
    signature: []const u8,
};

/// Converts an LSP `Position` (whose `character` counts UTF-16 code units,
/// per spec — this server doesn't advertise a `positionEncoding`
/// capability, so the client-negotiable alternatives never apply and
/// UTF-16 is always the mandated default) to a byte offset into `source`.
/// Delegates to `lib/lsp`'s vendored `offsets.positionToIndex`, which
/// counts code units correctly for multi-byte UTF-8 content (e.g. a
/// doc comment containing non-ASCII text) — a naive "character count ==
/// byte count" reading would resolve to the wrong byte for any position
/// after such content on the same line.
///
/// Note this only corrects the *incoming* direction. Response ranges
/// built from `Ast.tokenLocation` (used throughout the `features/*.zig`
/// handlers) still report byte-based columns, not UTF-16 code units —
/// the same gap on the way back out. Documented, not silently
/// papered over: fixing that side means wrapping or replacing every
/// `tokenLocation` call site, a larger follow-up left for later.
pub fn positionToOffset(source: []const u8, pos: Position) u32 {
    return @intCast(lsp.offsets.positionToIndex(source, .{ .line = pos.line, .character = pos.character }, .@"utf-16"));
}

/// Linear scan over every token; fine at the file sizes this targets for
/// now. Could binary-search `tokenStart` if it ever shows up as hot.
pub fn identifierTokenAt(ast: Ast, offset: u32) ?Ast.TokenIndex {
    var idx: Ast.TokenIndex = 0;
    while (idx < ast.tokens.len) : (idx += 1) {
        if (ast.tokenTag(idx) != .identifier) continue;
        const start = ast.tokenStart(idx);
        const end = start + ast.tokenSlice(idx).len;
        if (offset >= start and offset < end) return idx;
    }
    return null;
}

/// Like `identifierTokenAt`, but for `.builtin` tokens (`@This`, `@import`, …).
pub fn builtinTokenAt(ast: Ast, offset: u32) ?Ast.TokenIndex {
    var idx: Ast.TokenIndex = 0;
    while (idx < ast.tokens.len) : (idx += 1) {
        if (ast.tokenTag(idx) != .builtin) continue;
        const start = ast.tokenStart(idx);
        const end = start + ast.tokenSlice(idx).len;
        if (offset >= start and offset < end) return idx;
    }
    return null;
}

/// Innermost `struct`/`enum`/`union`/`opaque` whose source range contains
/// `offset`, plus the named `const`/`var` that owns it when nested.
/// `container_node == null` means the file/`@This()` root container.
pub const EnclosingContainer = struct {
    container_node: ?Ast.Node.Index = null,
    owner_node: ?Ast.Node.Index = null,
    owner_name: ?[]const u8 = null,
};

pub fn enclosingContainerAt(ast: Ast, offset: u32) EnclosingContainer {
    var best: EnclosingContainer = .{};
    var best_span: u32 = std.math.maxInt(u32);
    for (ast.rootDecls()) |node| {
        walkEnclosingContainer(ast, node, offset, null, null, &best, &best_span);
    }
    return best;
}

fn walkEnclosingContainer(
    ast: Ast,
    node: Ast.Node.Index,
    offset: u32,
    owner_node: ?Ast.Node.Index,
    owner_name: ?[]const u8,
    best: *EnclosingContainer,
    best_span: *u32,
) void {
    const tag = ast.nodeTag(node);
    if (isContainerDeclTag(tag)) {
        const start = ast.tokenStart(ast.firstToken(node));
        const end: u32 = @intCast(start + ast.getNodeSource(node).len);
        if (offset >= start and offset < end) {
            const span = end - start;
            if (span <= best_span.*) {
                best_span.* = span;
                best.* = .{
                    .container_node = node,
                    .owner_node = owner_node,
                    .owner_name = owner_name,
                };
            }
        }
        var buf: [2]Ast.Node.Index = undefined;
        if (ast.fullContainerDecl(&buf, node)) |decl| {
            for (decl.ast.members) |member| {
                walkEnclosingContainer(ast, member, offset, owner_node, owner_name, best, best_span);
            }
        }
        return;
    }

    switch (tag) {
        .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
            const var_decl = ast.fullVarDecl(node) orelse return;
            const name_token = var_decl.ast.mut_token + 1;
            const name = ast.tokenSlice(name_token);
            if (var_decl.ast.init_node.unwrap()) |init| {
                walkEnclosingContainer(ast, init, offset, node, name, best, best_span);
            }
            if (var_decl.ast.type_node.unwrap()) |tn| {
                walkEnclosingContainer(ast, tn, offset, owner_node, owner_name, best, best_span);
            }
        },
        .fn_decl => {
            _, const body = ast.nodeData(node).node_and_node;
            walkEnclosingContainer(ast, body, offset, owner_node, owner_name, best, best_span);
        },
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            var buf: [2]Ast.Node.Index = undefined;
            const stmts = ast.blockStatements(&buf, node) orelse return;
            for (stmts) |stmt| {
                walkEnclosingContainer(ast, stmt, offset, owner_node, owner_name, best, best_span);
            }
        },
        else => {},
    }
}

fn isContainerDeclTag(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        => true,
        else => false,
    };
}

fn definitionAt(ast: Ast, token: Ast.TokenIndex, signature: []const u8) Definition {
    const loc = ast.tokenLocation(0, token);
    return .{
        .line = @intCast(loc.line),
        .character = @intCast(loc.column),
        .end_character = @intCast(loc.column + ast.tokenSlice(token).len),
        .signature = signature,
    };
}

/// "name: Type", sliced straight from source rather than reconstructed,
/// so it matches whatever the author actually wrote (whitespace and all).
/// Falls back to just the name if there's no type (e.g. `anytype`, or a
/// parse this AST's error recovery couldn't fully make sense of).
fn paramSignature(ast: Ast, name_token: Ast.TokenIndex, type_expr: ?Ast.Node.Index) []const u8 {
    const name_start = ast.tokenStart(name_token);
    const te = type_expr orelse return ast.tokenSlice(name_token);
    const last = ast.lastToken(te);
    const end = ast.tokenStart(last) + ast.tokenSlice(last).len;
    return ast.source[name_start..end];
}

/// Zig's "doctest" convention: `test <ident> { ... }` (an identifier
/// name, not a string) associates that test with the declaration
/// `<ident>` names — as opposed to `test "some string" { ... }`, an
/// ordinary named test with no such association. Returns the matching
/// test's body source (including the enclosing braces), or `null` if
/// `decl_name` has no such test in `ast`.
pub fn findDoctest(ast: Ast, decl_name: []const u8) ?[]const u8 {
    for (ast.rootDecls()) |node| {
        if (ast.nodeTag(node) != .test_decl) continue;
        const name_token_opt, const body_node = ast.nodeData(node).opt_token_and_node;
        const name_token = name_token_opt.unwrap() orelse continue;
        if (ast.tokenTag(name_token) != .identifier) continue; // string-named test, not a doctest
        if (!std.mem.eql(u8, ast.tokenSlice(name_token), decl_name)) continue;
        return ast.getNodeSource(body_node);
    }
    return null;
}

/// Re-walks root decls for the token position of `name` — cheap (root
/// decls only, no recursion into bodies) and keeps `Item` itself free of
/// position bookkeeping that only resolution needs. Also the entry point
/// for cross-file resolution (Phase 6): the caller resolves `name` against
/// an *imported* file's item tree, then calls this with that file's `Ast`
/// to get a location in it.
pub fn definitionForRootItem(ast: Ast, name: []const u8) ?Definition {
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
                if (std.mem.eql(u8, ast.tokenSlice(name_token), name)) {
                    return definitionAt(ast, name_token, ast.getNodeSource(proto_node));
                }
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                const var_decl = ast.fullVarDecl(node) orelse continue;
                const name_token = var_decl.ast.mut_token + 1;
                if (std.mem.eql(u8, ast.tokenSlice(name_token), name)) {
                    return definitionAt(ast, name_token, ast.getNodeSource(node));
                }
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
                    return definitionAt(ast, name_token, paramSignature(ast, name_token, param.type_expr));
                }
            }
        }

        var buf2: [2]Ast.Node.Index = undefined;
        const stmts = ast.blockStatements(&buf2, body_node) orelse &.{};
        for (stmts) |stmt| {
            const var_decl = ast.fullVarDecl(stmt) orelse continue;
            const name_token = var_decl.ast.mut_token + 1;
            if (std.mem.eql(u8, ast.tokenSlice(name_token), name)) {
                return definitionAt(ast, name_token, ast.getNodeSource(stmt));
            }
        }

        break; // found the enclosing function; nothing else to check locally
    }

    // A token that's itself the *field* of a `base.field` access (e.g.
    // `Shell` in `completions.Shell`) is not a bare top-level reference —
    // even when its text happens to match some unrelated top-level name
    // in this file, that match would be a coincidence, not what the
    // access actually refers to. Returning `null` here (rather than a
    // wrong same-file match) lets the caller fall through to cross-file
    // field-access resolution instead, which is what a dotted access
    // like this actually needs. Matches this module's "safe limitation,
    // not silently wrong" policy (see file doc comment).
    if (fieldAccessAtToken(ast, ref_token) != null) return null;

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

/// A reference-site location — like `Definition` but without `signature`,
/// since a reference isn't itself a declaration.
pub const Reference = struct {
    line: u32,
    character: u32,
    end_character: u32,
};

/// Finds every identifier token in `ast` named `target_name` that
/// resolves (via `resolveAt`, the same local-scope-then-item-tree lookup
/// go-to-definition uses) to the exact declaration at
/// `target_line`/`target_character`. This is what makes "find references"
/// safe against false positives from an unrelated same-named local in a
/// different function: each candidate is independently re-resolved and
/// only kept if it points at the same place, rather than a bare text
/// match. The declaration site itself is not included — callers that want
/// it (e.g. rename) already have it from whatever resolved `target_name`
/// in the first place.
pub fn findReferences(
    gpa: std.mem.Allocator,
    ast: Ast,
    item_tree: ItemTree,
    target_name: []const u8,
    target_line: u32,
    target_character: u32,
) ![]Reference {
    var out: std.ArrayList(Reference) = .empty;
    errdefer out.deinit(gpa);

    var idx: Ast.TokenIndex = 0;
    while (idx < ast.tokens.len) : (idx += 1) {
        if (ast.tokenTag(idx) != .identifier) continue;
        if (!std.mem.eql(u8, ast.tokenSlice(idx), target_name)) continue;

        const loc = ast.tokenLocation(0, idx);
        const line: u32 = @intCast(loc.line);
        const character: u32 = @intCast(loc.column);
        if (line == target_line and character == target_character) continue; // the declaration itself

        const pos: Position = .{ .line = line, .character = character };
        const resolved = resolveAt(ast, item_tree, pos) orelse continue;
        if (resolved.line != target_line or resolved.character != target_character) continue;

        try out.append(gpa, .{
            .line = line,
            .character = character,
            .end_character = @intCast(character + target_name.len),
        });
    }

    return out.toOwnedSlice(gpa);
}

pub const FieldAccess = struct { base: []const u8, field: []const u8 };

/// If `field_token` is the right-hand side of a simple `base.field`
/// access, returns both names — used for cross-file resolution when
/// `base` is a local import binding (`const base = @import("...")`).
/// Only a single `.` hop is recognized; `a.b.c` resolves at most `b.c`
/// against `b`'s immediate base `a`.
pub fn fieldAccessAtToken(ast: Ast, field_token: Ast.TokenIndex) ?FieldAccess {
    if (field_token < 2) return null;
    if (ast.tokenTag(field_token - 1) != .period) return null;
    if (ast.tokenTag(field_token - 2) != .identifier) return null;
    return .{
        .base = ast.tokenSlice(field_token - 2),
        .field = ast.tokenSlice(field_token),
    };
}

/// `fieldAccessAtToken`, but starting from a position instead of an
/// already-known token index.
pub fn fieldAccessAt(ast: Ast, pos: Position) ?FieldAccess {
    const offset = positionToOffset(ast.source, pos);
    const field_token = identifierTokenAt(ast, offset) orelse return null;
    return fieldAccessAtToken(ast, field_token);
}

/// True if `token` is the *base* of a `token.field` access — the mirror
/// image of `fieldAccessAtToken`, which detects the field side. Go-to-
/// definition on an import binding used as a namespace (`completions` in
/// `completions.Shell`) needs to tell the two apart: the base should
/// resolve to (and stop at) the local binding, while the field should
/// resolve through it into the imported file.
pub fn isFieldAccessBase(ast: Ast, token: Ast.TokenIndex) bool {
    return token + 2 < ast.tokens.len and
        ast.tokenTag(token + 1) == .period and
        ast.tokenTag(token + 2) == .identifier;
}

/// Walks a dotted access leftward from `tip` (the rightmost identifier
/// token). For `std.debug.print` with `tip` on `print`, returns
/// `["std", "debug", "print"]` (borrowed slices into `ast.source`). A
/// `tip` with no `.identifier` before it yields a one-element chain.
pub fn fieldAccessChainFromToken(gpa: std.mem.Allocator, ast: Ast, tip: Ast.TokenIndex) ![]const []const u8 {
    var tokens: std.ArrayList(Ast.TokenIndex) = .empty;
    defer tokens.deinit(gpa);
    try tokens.append(gpa, tip);

    var cursor = tip;
    while (cursor >= 2) {
        if (ast.tokenTag(cursor - 1) != .period) break;
        if (ast.tokenTag(cursor - 2) != .identifier) break;
        try tokens.append(gpa, cursor - 2);
        cursor -= 2;
    }

    // tokens are tip-first; reverse into outermost-first.
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    var i: usize = tokens.items.len;
    while (i > 0) {
        i -= 1;
        try names.append(gpa, ast.tokenSlice(tokens.items[i]));
    }
    return try names.toOwnedSlice(gpa);
}

/// Walks a dotted access leftward from the identifier under `pos`.
/// For `std.debug.print` with the cursor on `print`, returns
/// `["std", "debug", "print"]` (borrowed slices into `ast.source`).
/// Returns `null` when there's no identifier at `pos`. A bare identifier
/// (no dots) yields a one-element chain.
pub fn fieldAccessChainAt(gpa: std.mem.Allocator, ast: Ast, pos: Position) !?[]const []const u8 {
    const offset = positionToOffset(ast.source, pos);
    const tip = identifierTokenAt(ast, offset) orelse return null;
    return try fieldAccessChainFromToken(gpa, ast, tip);
}

/// True if every token spanning `node` alternates `identifier`, `.`,
/// `identifier`, `.`, ... with nothing else (no calls, indexing, or
/// other syntax) — i.e. `node` is a plain dotted access like `std.zig.Ast`,
/// not something merely shaped like the start of one (`foo().bar`).
pub fn isPlainFieldAccessChain(ast: Ast, node: Ast.Node.Index) bool {
    const first = ast.firstToken(node);
    const last = ast.lastToken(node);
    var idx = first;
    var expect_identifier = true;
    while (idx <= last) : (idx += 1) {
        const want: std.zig.Token.Tag = if (expect_identifier) .identifier else .period;
        if (ast.tokenTag(idx) != want) return false;
        expect_identifier = !expect_identifier;
    }
    return !expect_identifier; // ends on an identifier, not a trailing period
}

/// Finds a top-level `const`/`var` declaration named `name` and returns
/// its initializer node, or `null` if there isn't one or it has none
/// (e.g. an `extern` decl). Used to look through a plain alias
/// (`const Ast = std.zig.Ast;`) to what it actually points at.
pub fn rootVarDeclInitNode(ast: Ast, name: []const u8) ?Ast.Node.Index {
    for (ast.rootDecls()) |node| {
        switch (ast.nodeTag(node)) {
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {},
            else => continue,
        }
        const var_decl = ast.fullVarDecl(node) orelse continue;
        const name_token = var_decl.ast.mut_token + 1;
        if (!std.mem.eql(u8, ast.tokenSlice(name_token), name)) continue;
        return var_decl.ast.init_node.unwrap();
    }
    return null;
}

/// Collects the parameter and immediate-body local variable names in
/// scope at `offset` — the same scope `resolveAt` searches, exposed
/// separately for completions (which want every in-scope name, not a
/// match for one specific one). Appends borrowed slices to `out`.
pub fn collectLocalScopeNames(
    gpa: std.mem.Allocator,
    ast: Ast,
    offset: u32,
    out: *std.ArrayList([]const u8),
) !void {
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
                try out.append(gpa, ast.tokenSlice(name_token));
            }
        }

        var buf2: [2]Ast.Node.Index = undefined;
        const stmts = ast.blockStatements(&buf2, body_node) orelse &.{};
        for (stmts) |stmt| {
            const var_decl = ast.fullVarDecl(stmt) orelse continue;
            try out.append(gpa, ast.tokenSlice(var_decl.ast.mut_token + 1));
        }
        return; // found the enclosing function; nothing else to check
    }
}

pub const CallContext = struct {
    /// The identifier token being called — either the callee directly
    /// (`helper(`) or the field name of a cross-file call
    /// (`helpers.add(`, where this points at `add`; the caller checks
    /// `fieldAccessAtToken` on it to find the `helpers` base).
    callee_token: Ast.TokenIndex,
    /// 0-based index of the argument `pos` falls within, counted by
    /// top-level commas since the call's open paren (nested calls'
    /// commas don't count, tracked via the same paren-depth stack).
    active_parameter: u32,
};

/// Finds the innermost function call `pos` is positioned inside the
/// argument list of, and which argument slot it's in — the two things
/// `textDocument/signatureHelp` needs. Returns `null` if `pos` isn't
/// inside any call's parentheses, or the token immediately before the
/// enclosing `(` isn't an identifier (e.g. it's a grouping paren around
/// an expression, not a call).
pub fn callContextAt(gpa: std.mem.Allocator, ast: Ast, pos: Position) !?CallContext {
    const offset = positionToOffset(ast.source, pos);

    var open_parens: std.ArrayList(Ast.TokenIndex) = .empty;
    defer open_parens.deinit(gpa);
    var comma_counts: std.ArrayList(u32) = .empty;
    defer comma_counts.deinit(gpa);

    var idx: Ast.TokenIndex = 0;
    while (idx < ast.tokens.len and ast.tokenStart(idx) < offset) : (idx += 1) {
        switch (ast.tokenTag(idx)) {
            .l_paren => {
                try open_parens.append(gpa, idx);
                try comma_counts.append(gpa, 0);
            },
            .r_paren => {
                if (open_parens.items.len > 0) {
                    _ = open_parens.pop();
                    _ = comma_counts.pop();
                }
            },
            .comma => {
                if (comma_counts.items.len > 0) comma_counts.items[comma_counts.items.len - 1] += 1;
            },
            else => {},
        }
    }

    if (open_parens.items.len == 0) return null;
    const open_paren = open_parens.items[open_parens.items.len - 1];
    const active_parameter = comma_counts.items[comma_counts.items.len - 1];

    if (open_paren == 0) return null;
    const callee_token = open_paren - 1;
    if (ast.tokenTag(callee_token) != .identifier) return null;

    return .{ .callee_token = callee_token, .active_parameter = active_parameter };
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

test "positionToOffset counts UTF-16 code units, not bytes, for non-ASCII content" {
    // "π" (U+03C0) is 2 bytes in UTF-8 but only 1 UTF-16 code unit — the
    // exact case a naive "character count == byte count" approximation
    // gets wrong. Source: "const π = 1; const y = π;\n" — the second "π"
    // sits at UTF-16 character 23, but byte offset 24 (one byte later,
    // since the first "π" cost 2 bytes but only 1 character).
    const source = "const π = 1; const y = π;\n";
    const offset = positionToOffset(source, .{ .line = 0, .character = 23 });
    try testing.expectEqual(@as(u32, 24), offset);
    try testing.expect(std.mem.startsWith(u8, source[offset..], "π"));
}

test "resolves a function parameter used in the body" {
    const gpa = testing.allocator;
    const source = "fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n";
    //                                                     ^ line 1, "a" at character 11
    const def = (try resolveInSource(gpa, source, .{ .line = 1, .character = 11 })).?;
    try testing.expectEqual(@as(u32, 0), def.line);
    // "a" is the first param, right after "fn add(".
    try testing.expectEqual(@as(u32, 7), def.character);
    try testing.expectEqualStrings("a: i32", def.signature);
}

test "resolves a local const declared earlier in the same function body" {
    const gpa = testing.allocator;
    const source = "fn f() i32 {\n    const answer = 42;\n    return answer;\n}\n";
    const def = (try resolveInSource(gpa, source, .{ .line = 2, .character = 12 })).?;
    try testing.expectEqual(@as(u32, 1), def.line);
    try testing.expectEqual(@as(u32, 10), def.character); // "    const answer" -> 'a' at col 10
    try testing.expectEqualStrings("const answer = 42", def.signature);
}

test "resolves a reference to a top-level function via the item tree" {
    const gpa = testing.allocator;
    const source = "fn helper() void {}\nfn main() void {\n    helper();\n}\n";
    const def = (try resolveInSource(gpa, source, .{ .line = 2, .character = 5 })).?;
    try testing.expectEqual(@as(u32, 0), def.line);
    try testing.expectEqual(@as(u32, 3), def.character); // "fn helper" -> 'h' at col 3
    try testing.expectEqualStrings("fn helper() void", def.signature);
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

test "collectLocalScopeNames finds params and immediate-body locals" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "fn f(a: i32) void {\n    const b = 1;\n    _ = a;\n}\n", .zig);
    defer ast.deinit(gpa);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    // Offset inside the body, at "_ = a;".
    try collectLocalScopeNames(gpa, ast, positionToOffset(ast.source, .{ .line = 2, .character = 4 }), &names);

    try testing.expectEqual(@as(usize, 2), names.items.len);
    try testing.expectEqualStrings("a", names.items[0]);
    try testing.expectEqualStrings("b", names.items[1]);
}

test "findReferences finds every call site of a top-level function" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "fn helper() void {}\nfn a() void {\n    helper();\n}\nfn b() void {\n    helper();\n}\n", .zig);
    defer ast.deinit(gpa);
    var tree = try item_tree_query.build(gpa, ast);
    defer tree.deinit(gpa);

    const refs = try findReferences(gpa, ast, tree, "helper", 0, 3);
    defer gpa.free(refs);

    try testing.expectEqual(@as(usize, 2), refs.len);
    try testing.expectEqual(@as(u32, 2), refs[0].line);
    try testing.expectEqual(@as(u32, 5), refs[1].line);
}

test "findReferences does not cross into an unrelated same-named local" {
    // The false-positive guard findReferences exists for: `x` in `g` is a
    // *different* declaration than the one being searched for in `f`,
    // even though the name matches textually.
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "fn f() void {\n    const x = 1;\n    _ = x;\n}\nfn g() void {\n    const x = 2;\n    _ = x;\n}\n", .zig);
    defer ast.deinit(gpa);
    var tree = try item_tree_query.build(gpa, ast);
    defer tree.deinit(gpa);

    // "x" declared in f, at line 1 character 10.
    const refs = try findReferences(gpa, ast, tree, "x", 1, 10);
    defer gpa.free(refs);

    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqual(@as(u32, 2), refs[0].line); // only the "_ = x;" inside f
}

test "callContextAt finds the active parameter in a single-line call" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\nfn main() void {\n    _ = add(1, 2);\n}\n", .zig);
    defer ast.deinit(gpa);

    // Cursor right after "add(1, " — on the second argument.
    const ctx = (try callContextAt(gpa, ast, .{ .line = 4, .character = 15 })).?;
    try testing.expectEqualStrings("add", ast.tokenSlice(ctx.callee_token));
    try testing.expectEqual(@as(u32, 1), ctx.active_parameter);
}

test "callContextAt ignores commas inside a nested call" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\nfn id(x: i32) i32 {\n    return x;\n}\nfn main() void {\n    _ = add(id(1, 2), 3);\n}\n", .zig);
    defer ast.deinit(gpa);

    // Cursor inside id(1, |2), still argument 0 of the outer add(...).
    const line = "    _ = add(id(1, 2), 3);";
    const col: u32 = @intCast(std.mem.indexOf(u8, line, "2), 3").?);
    const ctx = (try callContextAt(gpa, ast, .{ .line = 7, .character = col })).?;
    try testing.expectEqualStrings("id", ast.tokenSlice(ctx.callee_token));
}

test "callContextAt returns null outside any call" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "fn f() void {}\n", .zig);
    defer ast.deinit(gpa);
    try testing.expectEqual(@as(?CallContext, null), try callContextAt(gpa, ast, .{ .line = 0, .character = 0 }));
}

test "findDoctest matches an identifier-named test to its declaration" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa,
        \\test addOne {
        \\    try std.testing.expectEqual(42, addOne(41));
        \\}
        \\
        \\fn addOne(number: i32) i32 {
        \\    return number + 1;
        \\}
        \\
    , .zig);
    defer ast.deinit(gpa);

    const body = findDoctest(ast, "addOne").?;
    try testing.expect(std.mem.indexOf(u8, body, "expectEqual") != null);
}

test "findDoctest ignores string-named tests" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "test \"addOne works\" {}\nfn addOne(n: i32) i32 { return n + 1; }\n", .zig);
    defer ast.deinit(gpa);
    try testing.expectEqual(@as(?[]const u8, null), findDoctest(ast, "addOne"));
}

test "isFieldAccessBase distinguishes the base from the field of a dotted access" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "const x = completions.Shell;\n", .zig);
    defer ast.deinit(gpa);

    // "completions" is the base; "Shell" is the field; "x" is neither.
    var idx: Ast.TokenIndex = 0;
    var x_token: ?Ast.TokenIndex = null;
    var base_token: ?Ast.TokenIndex = null;
    var field_token: ?Ast.TokenIndex = null;
    while (idx < ast.tokens.len) : (idx += 1) {
        if (ast.tokenTag(idx) != .identifier) continue;
        if (std.mem.eql(u8, ast.tokenSlice(idx), "x")) x_token = idx;
        if (std.mem.eql(u8, ast.tokenSlice(idx), "completions")) base_token = idx;
        if (std.mem.eql(u8, ast.tokenSlice(idx), "Shell")) field_token = idx;
    }

    try testing.expect(isFieldAccessBase(ast, base_token.?));
    try testing.expect(!isFieldAccessBase(ast, field_token.?));
    try testing.expect(!isFieldAccessBase(ast, x_token.?));
}

test "isPlainFieldAccessChain accepts a dotted chain and rejects a call" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "const a = std.zig.Ast;\nconst b = std.zig.Ast.parse(x);\n", .zig);
    defer ast.deinit(gpa);

    const init_a = rootVarDeclInitNode(ast, "a").?;
    try testing.expect(isPlainFieldAccessChain(ast, init_a));

    const init_b = rootVarDeclInitNode(ast, "b").?;
    try testing.expect(!isPlainFieldAccessChain(ast, init_b));
}

test "fieldAccessChainFromToken walks a dotted chain to its outermost base" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "const a = std.zig.Ast;\n", .zig);
    defer ast.deinit(gpa);

    const init_node = rootVarDeclInitNode(ast, "a").?;
    const chain = try fieldAccessChainFromToken(gpa, ast, ast.lastToken(init_node));
    defer gpa.free(chain);

    try testing.expectEqual(@as(usize, 3), chain.len);
    try testing.expectEqualStrings("std", chain[0]);
    try testing.expectEqualStrings("zig", chain[1]);
    try testing.expectEqualStrings("Ast", chain[2]);
}

test "resolveAt does not mismatch a dotted field against an unrelated same-named top-level item" {
    // Regression guard: `Shell` here is the *field* of `completions.Shell`,
    // not a bare reference to the unrelated top-level `Shell` declared
    // below. Matching it anyway (the bug this test guards against) would
    // make go-to-definition redirect back to the very line being edited.
    const gpa = testing.allocator;
    const source = "const completions = @import(\"completions.zig\");\npub const Shell = completions.Shell;\n";
    //              "pub const Shell = completions.Shell;" -> field "Shell" starts at character 30
    var ast = try Ast.parse(gpa, source, .zig);
    defer ast.deinit(gpa);
    var tree = try item_tree_query.build(gpa, ast);
    defer tree.deinit(gpa);

    const def = resolveAt(ast, tree, .{ .line = 1, .character = 30 });
    try testing.expectEqual(@as(?Definition, null), def);
}

test "findDoctest returns null when there's no matching test" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "fn addOne(n: i32) i32 { return n + 1; }\n", .zig);
    defer ast.deinit(gpa);
    try testing.expectEqual(@as(?[]const u8, null), findDoctest(ast, "addOne"));
}
