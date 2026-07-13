//! Generic type-parameter binding (`ArrayList(u8)` → container with `T=u8`).
//!
//! Tracks comptime/`type` params on type functions and applies them when
//! looking through returned structs. Incomplete vs Zig Sema — prefer miss.

const std = @import("std");
const Ast = std.zig.Ast;
const type_mod = @import("type.zig");
const Type = type_mod.Type;

/// Extract comptime type-parameter names from a function prototype node
/// (`fn ArrayList(comptime T: type) type` → `["T"]`).
pub fn typeParamNames(gpa: std.mem.Allocator, ast: Ast, proto_node: Ast.Node.Index) ![]const []const u8 {
    var buf: [1]Ast.Node.Index = undefined;
    const proto = ast.fullFnProto(&buf, proto_node) orelse return try gpa.alloc([]const u8, 0);

    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);

    var it = proto.iterate(&ast);
    while (it.next()) |param| {
        const name_token = param.name_token orelse continue;
        // Treat `comptime T: type` and bare `T: type` as type params.
        const is_type_param = blk: {
            if (param.anytype_ellipsis3 != null) break :blk false;
            const te = param.type_expr orelse break :blk false;
            break :blk std.mem.eql(u8, ast.getNodeSource(te), "type");
        };
        if (!is_type_param) continue;
        try names.append(gpa, ast.tokenSlice(name_token));
    }
    return try names.toOwnedSlice(gpa);
}

/// Bind `param_names` to `arg_types` into a `BoundParams` (caller owns slices).
pub fn bindParams(
    gpa: std.mem.Allocator,
    param_names: []const []const u8,
    arg_types: []const Type,
) !Type.BoundParams {
    const n = @min(param_names.len, arg_types.len);
    const names = try gpa.alloc([]const u8, n);
    errdefer gpa.free(names);
    const types = try gpa.alloc(Type, n);
    errdefer gpa.free(types);
    for (0..n) |i| {
        names[i] = param_names[i];
        types[i] = arg_types[i];
    }
    return .{ .names = names, .types = types };
}

pub fn freeBoundParams(gpa: std.mem.Allocator, bp: Type.BoundParams) void {
    gpa.free(bp.names);
    gpa.free(bp.types);
}

/// If `fn_decl_node` is a type function whose body is `return SomeStruct`
/// or `return other.TypeFn(...)`, return the returned expression node.
pub fn typeFunctionReturnExpr(ast: Ast, fn_decl_node: Ast.Node.Index) ?Ast.Node.Index {
    if (ast.nodeTag(fn_decl_node) != .fn_decl) return null;
    _, const body = ast.nodeData(fn_decl_node).node_and_node;
    return findReturnExpr(ast, body);
}

fn findReturnExpr(ast: Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    switch (ast.nodeTag(node)) {
        .@"return" => {
            // return <expr>;
            return ast.nodeData(node).opt_node.unwrap();
        },
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            var buf: [2]Ast.Node.Index = undefined;
            const stmts = ast.blockStatements(&buf, node) orelse return null;
            // Prefer last return in the block.
            var result: ?Ast.Node.Index = null;
            for (stmts) |stmt| {
                if (findReturnExpr(ast, stmt)) |r| result = r;
            }
            return result;
        },
        else => return null,
    }
}

/// Substitute bound type params into a type-expression source string
/// (`[]T` + T=u8 → still returns original; full rewrite is best-effort).
pub fn substituteTypeName(source: []const u8, bp: Type.BoundParams) []const u8 {
    // Cheap path: if the whole source is a bound param name, replace it.
    if (bp.get(source)) |t| {
        return switch (t.data) {
            .primitive => |p| p,
            .named => |n| n.name,
            else => source,
        };
    }
    return source;
}

const testing = std.testing;

test "typeParamNames extracts comptime T: type" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa,
        \\pub fn ArrayList(comptime T: type) type {
        \\    return struct { pub fn append(self: *@This(), item: T) void {} };
        \\}
        \\
    , .zig);
    defer ast.deinit(gpa);

    const fn_node = ast.rootDecls()[0];
    const proto, _ = ast.nodeData(fn_node).node_and_node;
    const names = try typeParamNames(gpa, ast, proto);
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("T", names[0]);
}

test "typeFunctionReturnExpr finds returned struct" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa,
        \\pub fn Box(comptime T: type) type {
        \\    return struct {
        \\        value: T,
        \\    };
        \\}
        \\
    , .zig);
    defer ast.deinit(gpa);

    const fn_node = ast.rootDecls()[0];
    const ret = typeFunctionReturnExpr(ast, fn_node).?;
    const tag = ast.nodeTag(ret);
    try testing.expect(tag == .container_decl or tag == .container_decl_trailing or
        tag == .container_decl_two or tag == .container_decl_two_trailing or
        tag == .container_decl_arg or tag == .container_decl_arg_trailing);
}
