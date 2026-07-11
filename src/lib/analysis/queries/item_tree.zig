//! Query: `(uri, revision) -> ItemTree` — a file's stable public shape
//! (top-level declaration names, kinds, and signatures), split out from
//! function bodies.
//!
//! This is the item-tree/body split from the project plan §1.3: a
//! function's body is excluded from its `Item.signature`, so an edit
//! confined to a body produces a structurally `eql` `ItemTree` to the one
//! before the edit. That equality is the precondition later phases
//! (cross-file resolution) need in order to prove that editing a function
//! body in file A never has to invalidate anything in a file that imports
//! A — see the tests below for the single-file half of that proof, and
//! Phase 6 for the cross-file regression test.
//!
//! Only root (file-level) declarations are walked for now; nested
//! container members (e.g. fields of a `struct { ... }` assigned to a
//! top-level `const`) aren't part of this IR yet — that's a refinement
//! for whenever cross-file resolution actually needs to see into them.

const std = @import("std");
const Ast = std.zig.Ast;
const query = @import("../query.zig");

pub const Item = struct {
    /// Owned copy of the declaration's name.
    name: []const u8,
    kind: Kind,
    is_pub: bool,
    /// Owned copy of the declaration's signature source text. For
    /// functions: everything up to (not including) the body block. For
    /// variables/constants: the whole declaration — there's no body to
    /// split out, and the initializer expression is part of the public
    /// shape (e.g. `pub const max_len = 64;`).
    signature: []const u8,

    pub const Kind = enum { function, variable };

    pub fn eql(a: Item, b: Item) bool {
        return a.kind == b.kind and
            a.is_pub == b.is_pub and
            std.mem.eql(u8, a.name, b.name) and
            std.mem.eql(u8, a.signature, b.signature);
    }
};

pub const ItemTree = struct {
    items: []const Item,

    pub fn deinit(self: *ItemTree, gpa: std.mem.Allocator) void {
        for (self.items) |item| {
            gpa.free(item.name);
            gpa.free(item.signature);
        }
        gpa.free(self.items);
        self.* = undefined;
    }

    /// Structural equality: two item trees are equal iff they declare the
    /// same items with the same signatures, in the same order. A body-only
    /// edit must preserve this.
    pub fn eql(a: ItemTree, b: ItemTree) bool {
        if (a.items.len != b.items.len) return false;
        for (a.items, b.items) |x, y| {
            if (!x.eql(y)) return false;
        }
        return true;
    }

    pub fn find(self: ItemTree, name: []const u8) ?Item {
        for (self.items) |item| {
            if (std.mem.eql(u8, item.name, name)) return item;
        }
        return null;
    }
};

fn deinitItemTree(tree: *ItemTree, gpa: std.mem.Allocator) void {
    tree.deinit(gpa);
}

pub const Cache = query.OwningStringCache(ItemTree, deinitItemTree);

fn appendFnItem(gpa: std.mem.Allocator, items: *std.ArrayList(Item), ast: Ast, proto_node: Ast.Node.Index) !void {
    var buf: [1]Ast.Node.Index = undefined;
    const proto = ast.fullFnProto(&buf, proto_node) orelse return;
    const name_token = proto.name_token orelse return;

    try items.append(gpa, .{
        .name = try gpa.dupe(u8, ast.tokenSlice(name_token)),
        .kind = .function,
        .is_pub = proto.visib_token != null,
        .signature = try gpa.dupe(u8, ast.getNodeSource(proto_node)),
    });
}

fn appendVarItem(gpa: std.mem.Allocator, items: *std.ArrayList(Item), ast: Ast, node: Ast.Node.Index) !void {
    const var_decl = ast.fullVarDecl(node) orelse return;
    const name_token = var_decl.ast.mut_token + 1;

    try items.append(gpa, .{
        .name = try gpa.dupe(u8, ast.tokenSlice(name_token)),
        .kind = .variable,
        .is_pub = var_decl.visib_token != null,
        .signature = try gpa.dupe(u8, ast.getNodeSource(node)),
    });
}

pub fn build(gpa: std.mem.Allocator, ast: Ast) !ItemTree {
    var items: std.ArrayList(Item) = .empty;
    errdefer {
        for (items.items) |item| {
            gpa.free(item.name);
            gpa.free(item.signature);
        }
        items.deinit(gpa);
    }

    for (ast.rootDecls()) |node| {
        switch (ast.nodeTag(node)) {
            .fn_decl => {
                const proto_node, _ = ast.nodeData(node).node_and_node;
                try appendFnItem(gpa, &items, ast, proto_node);
            },
            .fn_proto, .fn_proto_one, .fn_proto_simple, .fn_proto_multi => {
                try appendFnItem(gpa, &items, ast, node);
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                try appendVarItem(gpa, &items, ast, node);
            },
            else => {},
        }
    }

    return .{ .items = try items.toOwnedSlice(gpa) };
}

const ComputeCtx = struct {
    gpa: std.mem.Allocator,
    ast: Ast,
};

fn compute(ctx: ComputeCtx) !ItemTree {
    return build(ctx.gpa, ctx.ast);
}

/// Returns the memoized item tree for `uri` at `revision`, building it
/// from `ast` on a cache miss.
pub fn itemTree(
    cache: *Cache,
    gpa: std.mem.Allocator,
    uri: []const u8,
    ast: Ast,
    revision: query.Revision,
) !*ItemTree {
    return cache.getOrCompute(gpa, uri, revision, ComputeCtx{ .gpa = gpa, .ast = ast }, compute);
}

const testing = std.testing;

fn parseForTest(gpa: std.mem.Allocator, source: [:0]const u8) !Ast {
    return Ast.parse(gpa, source, .zig);
}

test "function signature excludes the body" {
    const gpa = testing.allocator;
    var ast = try parseForTest(gpa, "pub fn add(a: i32, b: i32) i32 { return a + b; }\n");
    defer ast.deinit(gpa);

    var tree = try build(gpa, ast);
    defer tree.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), tree.items.len);
    const item = tree.items[0];
    try testing.expectEqualStrings("add", item.name);
    try testing.expectEqual(Item.Kind.function, item.kind);
    try testing.expect(item.is_pub);
    try testing.expectEqualStrings("pub fn add(a: i32, b: i32) i32", item.signature);
    try testing.expect(std.mem.indexOf(u8, item.signature, "return") == null);
}

test "variable declarations are captured with their full text" {
    const gpa = testing.allocator;
    var ast = try parseForTest(gpa, "const max_len = 64;\n");
    defer ast.deinit(gpa);

    var tree = try build(gpa, ast);
    defer tree.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), tree.items.len);
    const item = tree.items[0];
    try testing.expectEqualStrings("max_len", item.name);
    try testing.expectEqual(Item.Kind.variable, item.kind);
    try testing.expect(!item.is_pub);
}

test "a body-only edit produces a structurally equal item tree" {
    const gpa = testing.allocator;
    var ast_a = try parseForTest(gpa, "pub fn add(a: i32, b: i32) i32 { return a + b; }\n");
    defer ast_a.deinit(gpa);
    var ast_b = try parseForTest(gpa, "pub fn add(a: i32, b: i32) i32 { const sum = a + b; return sum; }\n");
    defer ast_b.deinit(gpa);

    var tree_a = try build(gpa, ast_a);
    defer tree_a.deinit(gpa);
    var tree_b = try build(gpa, ast_b);
    defer tree_b.deinit(gpa);

    try testing.expect(tree_a.eql(tree_b));
}

test "a signature edit produces a structurally different item tree" {
    const gpa = testing.allocator;
    var ast_a = try parseForTest(gpa, "pub fn add(a: i32, b: i32) i32 { return a + b; }\n");
    defer ast_a.deinit(gpa);
    var ast_b = try parseForTest(gpa, "pub fn add(a: i64, b: i32) i32 { return a + b; }\n");
    defer ast_b.deinit(gpa);

    var tree_a = try build(gpa, ast_a);
    defer tree_a.deinit(gpa);
    var tree_b = try build(gpa, ast_b);
    defer tree_b.deinit(gpa);

    try testing.expect(!tree_a.eql(tree_b));
}

test "multiple top-level declarations are all captured, in order" {
    const gpa = testing.allocator;
    var ast = try parseForTest(gpa,
        \\const a = 1;
        \\pub fn f() void {}
        \\var b: i32 = 2;
        \\
    );
    defer ast.deinit(gpa);

    var tree = try build(gpa, ast);
    defer tree.deinit(gpa);

    try testing.expectEqual(@as(usize, 3), tree.items.len);
    try testing.expectEqualStrings("a", tree.items[0].name);
    try testing.expectEqualStrings("f", tree.items[1].name);
    try testing.expectEqualStrings("b", tree.items[2].name);
}

test "cache: unrelated key's revision bump does not recompute this file's item tree" {
    const gpa = testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(gpa);

    var ast_a = try parseForTest(gpa, "pub fn f() void {}\n");
    defer ast_a.deinit(gpa);
    var ast_b = try parseForTest(gpa, "pub fn g() void {}\n");
    defer ast_b.deinit(gpa);

    const a_first = try itemTree(&cache, gpa, "file:///a.zig", ast_a, 1);
    _ = try itemTree(&cache, gpa, "file:///b.zig", ast_b, 1);

    const a_second = try itemTree(&cache, gpa, "file:///a.zig", ast_a, 1);
    _ = try itemTree(&cache, gpa, "file:///b.zig", ast_b, 2);

    try testing.expectEqual(a_first, a_second);
}
