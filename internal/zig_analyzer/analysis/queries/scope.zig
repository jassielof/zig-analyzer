//! Lexical scope tree for a single Zig file.
//!
//! Smaller cousin of ZLS's `DocumentScope`: tracks function params, locals
//! (including nested blocks), and top-level decls so name lookup and
//! annotated-type resolution can see past "immediate body only".

const std = @import("std");
const Ast = std.zig.Ast;

pub const DeclKind = enum {
    parameter,
    local,
    function,
    variable,
};

pub const Decl = struct {
    name: []const u8,
    kind: DeclKind,
    /// Name token.
    name_token: Ast.TokenIndex,
    /// Enclosing AST node (fn proto param, var decl, fn decl, …).
    node: Ast.Node.Index,
    /// Type-expression node when the decl is annotated (`b: *std.Build`).
    type_node: ?Ast.Node.Index = null,
    /// Initializer expression node when present.
    init_node: ?Ast.Node.Index = null,
};

pub const ScopeKind = enum {
    file,
    function,
    block,
};

pub const Scope = struct {
    kind: ScopeKind,
    /// Byte range this scope covers in `ast.source`.
    start: u32,
    end: u32,
    parent: ?u32 = null,
    decls: []const Decl,
};

pub const ScopeTree = struct {
    scopes: []const Scope,
    /// Arena-like: all decl name slices borrow `ast.source`; only the
    /// arrays themselves are owned.
    gpa: std.mem.Allocator,

    pub fn deinit(self: *ScopeTree) void {
        for (self.scopes) |sc| {
            self.gpa.free(sc.decls);
        }
        self.gpa.free(self.scopes);
        self.* = undefined;
    }

    /// Innermost scope whose range contains `offset`.
    pub fn scopeAt(self: ScopeTree, offset: u32) ?u32 {
        var best: ?u32 = null;
        var best_span: u32 = std.math.maxInt(u32);
        for (self.scopes, 0..) |sc, i| {
            if (offset < sc.start or offset >= sc.end) continue;
            const span = sc.end - sc.start;
            if (span <= best_span) {
                best_span = span;
                best = @intCast(i);
            }
        }
        return best;
    }

    /// Look up `name` walking from the innermost scope at `offset` outward.
    pub fn lookup(self: ScopeTree, offset: u32, name: []const u8) ?Decl {
        var idx = self.scopeAt(offset) orelse return self.lookupInScope(0, name);
        while (true) {
            if (self.lookupInScope(idx, name)) |d| return d;
            const parent = self.scopes[idx].parent orelse break;
            idx = parent;
        }
        return null;
    }

    fn lookupInScope(self: ScopeTree, scope_index: u32, name: []const u8) ?Decl {
        for (self.scopes[scope_index].decls) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }
};

pub fn build(gpa: std.mem.Allocator, ast: Ast) !ScopeTree {
    var scopes: std.ArrayList(Scope) = .empty;
    errdefer {
        for (scopes.items) |sc| gpa.free(sc.decls);
        scopes.deinit(gpa);
    }

    // File scope — top-level decls.
    var file_decls: std.ArrayList(Decl) = .empty;
    errdefer file_decls.deinit(gpa);

    for (ast.rootDecls()) |node| {
        try appendRootDecl(gpa, &file_decls, ast, node);
    }

    const file_scope_index: u32 = 0;
    try scopes.append(gpa, .{
        .kind = .file,
        .start = 0,
        .end = @intCast(ast.source.len),
        .parent = null,
        .decls = try file_decls.toOwnedSlice(gpa),
    });

    for (ast.rootDecls()) |node| {
        if (ast.nodeTag(node) != .fn_decl) continue;
        try walkFnDecl(gpa, &scopes, ast, node, file_scope_index);
    }

    return .{ .scopes = try scopes.toOwnedSlice(gpa), .gpa = gpa };
}

fn appendRootDecl(gpa: std.mem.Allocator, decls: *std.ArrayList(Decl), ast: Ast, node: Ast.Node.Index) !void {
    switch (ast.nodeTag(node)) {
        .fn_decl => {
            const proto_node, _ = ast.nodeData(node).node_and_node;
            var buf: [1]Ast.Node.Index = undefined;
            const proto = ast.fullFnProto(&buf, proto_node) orelse return;
            const name_token = proto.name_token orelse return;
            try decls.append(gpa, .{
                .name = ast.tokenSlice(name_token),
                .kind = .function,
                .name_token = name_token,
                .node = node,
                .type_node = null,
                .init_node = null,
            });
        },
        .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
            const var_decl = ast.fullVarDecl(node) orelse return;
            const name_token = var_decl.ast.mut_token + 1;
            try decls.append(gpa, .{
                .name = ast.tokenSlice(name_token),
                .kind = .variable,
                .name_token = name_token,
                .node = node,
                .type_node = var_decl.ast.type_node.unwrap(),
                .init_node = var_decl.ast.init_node.unwrap(),
            });
        },
        else => {},
    }
}

fn walkFnDecl(
    gpa: std.mem.Allocator,
    scopes: *std.ArrayList(Scope),
    ast: Ast,
    node: Ast.Node.Index,
    parent: u32,
) !void {
    const proto_node, const body_node = ast.nodeData(node).node_and_node;
    const body_start = ast.tokenStart(ast.firstToken(body_node));
    const body_end: u32 = @intCast(body_start + ast.getNodeSource(body_node).len);

    var fn_decls: std.ArrayList(Decl) = .empty;
    errdefer fn_decls.deinit(gpa);

    var buf: [1]Ast.Node.Index = undefined;
    if (ast.fullFnProto(&buf, proto_node)) |proto| {
        var it = proto.iterate(&ast);
        while (it.next()) |param| {
            const name_token = param.name_token orelse continue;
            try fn_decls.append(gpa, .{
                .name = ast.tokenSlice(name_token),
                .kind = .parameter,
                .name_token = name_token,
                .node = proto_node,
                .type_node = param.type_expr,
                .init_node = null,
            });
        }
    }

    const fn_index: u32 = @intCast(scopes.items.len);
    try scopes.append(gpa, .{
        .kind = .function,
        .start = body_start,
        .end = body_end,
        .parent = parent,
        .decls = try fn_decls.toOwnedSlice(gpa),
    });

    try walkBlock(gpa, scopes, ast, body_node, fn_index);
}

fn walkBlock(
    gpa: std.mem.Allocator,
    scopes: *std.ArrayList(Scope),
    ast: Ast,
    block_node: Ast.Node.Index,
    parent: u32,
) std.mem.Allocator.Error!void {
    var buf: [2]Ast.Node.Index = undefined;
    const stmts = ast.blockStatements(&buf, block_node) orelse return;

    var block_decls: std.ArrayList(Decl) = .empty;
    errdefer block_decls.deinit(gpa);

    for (stmts) |stmt| {
        if (ast.fullVarDecl(stmt)) |var_decl| {
            const name_token = var_decl.ast.mut_token + 1;
            try block_decls.append(gpa, .{
                .name = ast.tokenSlice(name_token),
                .kind = .local,
                .name_token = name_token,
                .node = stmt,
                .type_node = var_decl.ast.type_node.unwrap(),
                .init_node = var_decl.ast.init_node.unwrap(),
            });
        }
        // Recurse into nested blocks (if/while/for bodies, bare blocks).
        try walkNested(gpa, scopes, ast, stmt, parent);
    }

    if (block_decls.items.len == 0) {
        block_decls.deinit(gpa);
        return;
    }

    // Locals visible across the whole parent function/block range for
    // simplicity (Zig's actual scoping is statement-order; good enough
    // for lookup-at-offset of names that exist).
    const parent_scope = scopes.items[parent];
    try scopes.append(gpa, .{
        .kind = .block,
        .start = parent_scope.start,
        .end = parent_scope.end,
        .parent = parent,
        .decls = try block_decls.toOwnedSlice(gpa),
    });
}

fn walkNested(
    gpa: std.mem.Allocator,
    scopes: *std.ArrayList(Scope),
    ast: Ast,
    node: Ast.Node.Index,
    parent: u32,
) std.mem.Allocator.Error!void {
    switch (ast.nodeTag(node)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            const start = ast.tokenStart(ast.firstToken(node));
            const end: u32 = @intCast(start + ast.getNodeSource(node).len);
            const block_index: u32 = @intCast(scopes.items.len);
            try scopes.append(gpa, .{
                .kind = .block,
                .start = start,
                .end = end,
                .parent = parent,
                .decls = try gpa.alloc(Decl, 0),
            });
            try walkBlock(gpa, scopes, ast, node, block_index);
        },
        .@"if", .if_simple => {
            const full = ast.fullIf(node) orelse return;
            try walkNested(gpa, scopes, ast, full.ast.then_expr, parent);
            if (full.ast.else_expr.unwrap()) |e| try walkNested(gpa, scopes, ast, e, parent);
        },
        .while_simple, .while_cont, .@"while" => {
            const full = ast.fullWhile(node) orelse return;
            try walkNested(gpa, scopes, ast, full.ast.then_expr, parent);
            if (full.ast.else_expr.unwrap()) |e| try walkNested(gpa, scopes, ast, e, parent);
        },
        .for_simple, .@"for" => {
            const full = ast.fullFor(node) orelse return;
            try walkNested(gpa, scopes, ast, full.ast.then_expr, parent);
            if (full.ast.else_expr.unwrap()) |e| try walkNested(gpa, scopes, ast, e, parent);
        },
        else => {},
    }
}

const testing = std.testing;

fn parse(gpa: std.mem.Allocator, src: [:0]const u8) !Ast {
    return Ast.parse(gpa, src, .zig);
}

test "scope finds function parameter" {
    const gpa = testing.allocator;
    var ast = try parse(gpa,
        \\pub fn build(b: *std.Build) void {
        \\    _ = b;
        \\}
        \\
    );
    defer ast.deinit(gpa);

    var tree = try build(gpa, ast);
    defer tree.deinit();

    // Offset inside the function body.
    const offset = resolveOffset(ast.source, 1, 8);
    const decl = tree.lookup(offset, "b").?;
    try testing.expect(decl.kind == .parameter);
    try testing.expect(decl.type_node != null);
}

test "scope finds nested block local" {
    const gpa = testing.allocator;
    var ast = try parse(gpa,
        \\fn main() void {
        \\    if (true) {
        \\        const inner = 1;
        \\        _ = inner;
        \\    }
        \\}
        \\
    );
    defer ast.deinit(gpa);

    var tree = try build(gpa, ast);
    defer tree.deinit();

    const offset = resolveOffset(ast.source, 3, 12);
    const decl = tree.lookup(offset, "inner").?;
    try testing.expect(decl.kind == .local);
}

fn resolveOffset(source: []const u8, line: u32, character: u32) u32 {
    var l: u32 = 0;
    var i: usize = 0;
    while (l < line) : (l += 1) {
        const nl = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse return @intCast(source.len);
        i = nl + 1;
    }
    return @intCast(@min(source.len, i + character));
}
