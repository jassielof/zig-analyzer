//! Extracts Zig doc comments (`///`) and container doc comments (`//!`)
//! from an AST. Adapted from ZLS's helpers of the same name — we only
//! need the token-walking / joining half, not the full type-resolution
//! machinery that hangs off them there.

const std = @import("std");
const Ast = std.zig.Ast;

/// Gets a declaration's doc comments (`///` lines immediately above it).
/// Caller owns returned memory. Returns `null` when there are none.
pub fn getDocComments(allocator: std.mem.Allocator, tree: Ast, node: Ast.Node.Index) error{OutOfMemory}!?[]const u8 {
    const base = tree.nodeMainToken(node);
    switch (tree.nodeTag(node)) {
        .root => return try collectDocComments(allocator, tree, 0, true),
        .fn_proto,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_decl,
        .local_var_decl,
        .global_var_decl,
        .aligned_var_decl,
        .simple_var_decl,
        .container_field_init,
        .container_field_align,
        .container_field,
        => return try getDocCommentsBeforeToken(allocator, tree, base),
        else => {},
    }
    return null;
}

/// Container (`//!`) docs at the top of a file. Caller owns returned memory.
pub fn getContainerDocComments(allocator: std.mem.Allocator, tree: Ast) error{OutOfMemory}!?[]const u8 {
    if (tree.tokens.len == 0) return null;
    if (tree.tokenTag(0) != .container_doc_comment) return null;
    return try collectDocComments(allocator, tree, 0, true);
}

/// `//!` docs for a container node: file root uses token 0; nested
/// `struct`/`enum`/… uses `//!` tokens immediately after the `{`.
pub fn getContainerDocCommentsForNode(
    allocator: std.mem.Allocator,
    tree: Ast,
    container_node: ?Ast.Node.Index,
) error{OutOfMemory}!?[]const u8 {
    if (container_node == null) return try getContainerDocComments(allocator, tree);

    var buf: [2]Ast.Node.Index = undefined;
    const decl = tree.fullContainerDecl(&buf, container_node.?) orelse return null;
    // First token after `{` may be a run of `//!` comments.
    const lbrace = decl.ast.main_token; // often `struct`/`enum`; find `{`
    var idx = lbrace;
    while (idx < tree.tokens.len and tree.tokenTag(idx) != .l_brace) : (idx += 1) {}
    if (idx >= tree.tokens.len) return null;
    idx += 1;
    if (idx >= tree.tokens.len) return null;
    if (tree.tokenTag(idx) != .container_doc_comment) return null;
    return try collectDocComments(allocator, tree, idx, true);
}

pub fn getDocCommentsBeforeToken(allocator: std.mem.Allocator, tree: Ast, base: Ast.TokenIndex) error{OutOfMemory}!?[]const u8 {
    const doc_comment_index = getDocCommentTokenIndex(tree, base) orelse return null;
    return try collectDocComments(allocator, tree, doc_comment_index, false);
}

/// Walks modifiers (`pub`, `export`, …) backward from `base_token` looking
/// for a run of `///` doc-comment tokens. Returns the first (topmost) of
/// that run, or `null` if there isn't one.
pub fn getDocCommentTokenIndex(tree: Ast, base_token: Ast.TokenIndex) ?Ast.TokenIndex {
    var idx = base_token;
    if (idx == 0) return null;
    idx -|= 1;
    if (tree.tokenTag(idx) == .keyword_threadlocal and idx > 0) idx -|= 1;
    if (tree.tokenTag(idx) == .string_literal and idx > 1 and tree.tokenTag(idx -| 1) == .keyword_extern) idx -|= 1;
    if (tree.tokenTag(idx) == .keyword_extern and idx > 0) idx -|= 1;
    if (tree.tokenTag(idx) == .keyword_export and idx > 0) idx -|= 1;
    if (tree.tokenTag(idx) == .keyword_inline and idx > 0) idx -|= 1;
    if (tree.tokenTag(idx) == .identifier and idx > 0) idx -|= 1;
    if (tree.tokenTag(idx) == .keyword_pub and idx > 0) idx -|= 1;

    if (tree.tokenTag(idx) != .doc_comment) return null;
    return while (tree.tokenTag(idx) == .doc_comment) {
        if (idx == 0) break 0;
        idx -|= 1;
    } else idx + 1;
}

pub fn collectDocComments(
    allocator: std.mem.Allocator,
    tree: Ast,
    doc_comments: Ast.TokenIndex,
    container_doc: bool,
) error{OutOfMemory}!?[]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);

    var lines_start_with_space = true;
    var curr_line_tok = doc_comments;
    while (curr_line_tok < tree.tokens.len) : (curr_line_tok += 1) {
        switch (tree.tokenTag(curr_line_tok)) {
            .container_doc_comment => if (!container_doc) break,
            .doc_comment => if (container_doc) break,
            else => break,
        }
        const line = tree.tokenSlice(curr_line_tok)[3..];
        if (!std.mem.startsWith(u8, line, " ")) lines_start_with_space = false;
        try lines.append(allocator, line);
    }
    if (lines.items.len == 0) return null;

    // Matching ZLS: if every non-empty line starts with a space (the
    // conventional `/// foo` form), strip that one leading space so the
    // rendered markdown isn't indented.
    if (lines_start_with_space) {
        for (lines.items, 0..) |line, i| {
            if (line.len >= 1 and line[0] == ' ') {
                lines.items[i] = line[1..];
            }
        }
    }

    return try std.mem.join(allocator, "\n", lines.items);
}

/// Looks up the root declaration named `name` and returns its `///` docs,
/// if any. Convenience for hover: we already have the declaration's name
/// from `Definition`, not its node index.
pub fn getDocCommentsForRootName(allocator: std.mem.Allocator, tree: Ast, name: []const u8) error{OutOfMemory}!?[]const u8 {
    for (tree.rootDecls()) |node| {
        switch (tree.nodeTag(node)) {
            .fn_decl => {
                const proto_node, _ = tree.nodeData(node).node_and_node;
                var buf: [1]Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&buf, proto_node) orelse continue;
                const name_token = proto.name_token orelse continue;
                if (!std.mem.eql(u8, tree.tokenSlice(name_token), name)) continue;
                // Doc comments attach to the `fn_decl` (or its proto);
                // try the decl node first, then the proto.
                if (try getDocComments(allocator, tree, node)) |docs| return docs;
                return try getDocComments(allocator, tree, proto_node);
            },
            .fn_proto, .fn_proto_one, .fn_proto_simple, .fn_proto_multi => {
                var buf: [1]Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&buf, node) orelse continue;
                const name_token = proto.name_token orelse continue;
                if (!std.mem.eql(u8, tree.tokenSlice(name_token), name)) continue;
                return try getDocComments(allocator, tree, node);
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                const var_decl = tree.fullVarDecl(node) orelse continue;
                const name_token = var_decl.ast.mut_token + 1;
                if (!std.mem.eql(u8, tree.tokenSlice(name_token), name)) continue;
                return try getDocComments(allocator, tree, node);
            },
            else => {},
        }
    }
    return null;
}

const testing = std.testing;

test "getDocCommentsForRootName strips the leading space" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa,
        \\/// Adds one.
        \\fn addOne(n: i32) i32 {
        \\    return n + 1;
        \\}
        \\
    , .zig);
    defer ast.deinit(gpa);

    const docs = (try getDocCommentsForRootName(gpa, ast, "addOne")).?;
    defer gpa.free(docs);
    try testing.expectEqualStrings("Adds one.", docs);
}

test "getContainerDocComments joins //! lines" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa,
        \\//! String formatting.
        \\//! And parsing.
        \\
        \\pub const x = 1;
        \\
    , .zig);
    defer ast.deinit(gpa);

    const docs = (try getContainerDocComments(gpa, ast)).?;
    defer gpa.free(docs);
    try testing.expectEqualStrings("String formatting.\nAnd parsing.", docs);
}

test "getContainerDocCommentsForNode reads nested struct //! docs" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa,
        \\//! File docs.
        \\
        \\const Foo = struct {
        \\    //! Foo container docs.
        \\    x: u8,
        \\};
        \\
    , .zig);
    defer ast.deinit(gpa);

    const foo_init = blk: {
        for (ast.rootDecls()) |node| {
            const var_decl = ast.fullVarDecl(node) orelse continue;
            if (!std.mem.eql(u8, ast.tokenSlice(var_decl.ast.mut_token + 1), "Foo")) continue;
            break :blk var_decl.ast.init_node.unwrap().?;
        }
        unreachable;
    };

    const docs = (try getContainerDocCommentsForNode(gpa, ast, foo_init)).?;
    defer gpa.free(docs);
    try testing.expectEqualStrings("Foo container docs.", docs);
}

test "getDocCommentsForRootName returns null without docs" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "fn addOne(n: i32) i32 { return n + 1; }\n", .zig);
    defer ast.deinit(gpa);
    try testing.expectEqual(@as(?[]const u8, null), try getDocCommentsForRootName(gpa, ast, "addOne"));
}
