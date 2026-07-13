//! Expression type resolution — the heart of the modular type layer.
//!
//! Resolves annotated params/locals, pointer types, dotted type paths
//! (`std.Build`), field/method access on typed values, and simple generic
//! instantiations (`ArrayList(u8)`). Misses rather than guessing.

const std = @import("std");
const Ast = std.zig.Ast;
const type_mod = @import("type.zig");
const Type = type_mod.Type;
const scope_mod = @import("scope.zig");
const containers = @import("containers.zig");
const generics = @import("generics.zig");
const resolve = @import("resolve.zig");
const imports = @import("imports.zig");

/// Callbacks the server (or tests) provide so this module stays free of
/// document-store / filesystem details.
pub const Context = struct {
    gpa: std.mem.Allocator,
    /// URI of the file `ast` belongs to.
    uri: []const u8,
    ast: Ast,
    scopes: scope_mod.ScopeTree,
    zig_lib_dir: ?[]const u8 = null,
    packages: ?*const imports.PackageMap = null,
    /// Load and parse another file by URI. Returns null if unavailable.
    /// Caller of resolve_expr does not free the AST — loader owns it for
    /// the duration of the request (arena / cache).
    loadFile: *const fn (ctx: *Context, uri: []const u8) ?Ast,
    /// Optional userdata for loadFile implementations.
    userdata: ?*anyopaque = null,

    /// Scratch arena for pointer child types allocated during resolution.
    scratch: std.ArrayList(*Type) = .empty,
    /// Owned URI strings held for the request (import targets, etc.).
    owned_uris: std.ArrayList([]u8) = .empty,
    /// Owned generic bindings held for the request.
    owned_bounds: std.ArrayList(Type.BoundParams) = .empty,

    pub fn deinitScratch(self: *Context) void {
        for (self.scratch.items) |p| self.gpa.destroy(p);
        self.scratch.deinit(self.gpa);
        for (self.owned_uris.items) |u| self.gpa.free(u);
        self.owned_uris.deinit(self.gpa);
        for (self.owned_bounds.items) |bp| {
            generics.freeBoundParams(self.gpa, bp);
        }
        self.owned_bounds.deinit(self.gpa);
    }

    fn allocType(self: *Context, ty: Type) !*Type {
        const p = try self.gpa.create(Type);
        p.* = ty;
        try self.scratch.append(self.gpa, p);
        return p;
    }

    fn holdUri(self: *Context, uri: []const u8) ![]const u8 {
        const duped = try self.gpa.dupe(u8, uri);
        try self.owned_uris.append(self.gpa, duped);
        return duped;
    }

    fn takeUri(self: *Context, owned: []const u8) ![]const u8 {
        // Caller transfers ownership of an allocator-owned slice.
        try self.owned_uris.append(self.gpa, @constCast(owned));
        return owned;
    }

    fn holdBoundParams(self: *Context, bp: Type.BoundParams) !Type.BoundParams {
        try self.owned_bounds.append(self.gpa, bp);
        return bp;
    }
};

pub const MemberResult = struct {
    ty: Type,
    /// Definition location in the member's file.
    uri: []const u8,
    line: u32,
    character: u32,
    end_character: u32,
    signature: []const u8,
};

/// Resolve the type of a type-expression AST node (`*std.Build`, `u8`, …).
pub fn resolveTypeExpr(ctx: *Context, node: Ast.Node.Index) anyerror!?Type {
    const ast = ctx.ast;
    switch (ast.nodeTag(node)) {
        .identifier => {
            const name = ast.tokenSlice(ast.nodeMainToken(node));
            if (isPrimitive(name)) return Type.primitive(name);
            // Look up as a value/type in scope, then as import binding.
            return try resolveIdentType(ctx, name, ast.tokenStart(ast.nodeMainToken(node)), true);
        },
        .field_access => {
            return try resolveFieldAccessType(ctx, node, true);
        },
        .ptr_type, .ptr_type_aligned, .ptr_type_sentinel, .ptr_type_bit_range => {
            const ptr = ast.fullPtrType(node) orelse return null;
            const child = try resolveTypeExpr(ctx, ptr.ast.child_type) orelse Type.unknown();
            const child_ptr = try ctx.allocType(child);
            return .{
                .data = .{ .pointer = .{
                    .child = child_ptr,
                    .is_const = ptr.const_token != null,
                    .size = switch (ptr.size) {
                        .one => .one,
                        .many => .many,
                        .slice => .slice,
                        .c => .c,
                    },
                } },
                .is_type_val = true,
            };
        },
        .optional_type => {
            const child_node = ast.nodeData(node).node;
            const child = try resolveTypeExpr(ctx, child_node) orelse Type.unknown();
            const child_ptr = try ctx.allocType(child);
            return .{ .data = .{ .optional = child_ptr }, .is_type_val = true };
        },
        .call, .call_comma, .call_one, .call_one_comma => {
            return try resolveGenericCall(ctx, node);
        },
        .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
            // `@as(T, value)` → T
            const builtin = ast.tokenSlice(ast.nodeMainToken(node));
            if (!std.mem.eql(u8, builtin, "@as")) return null;
            var buf: [2]Ast.Node.Index = undefined;
            const params = ast.builtinCallParams(&buf, node) orelse return null;
            if (params.len < 1) return null;
            return try resolveTypeExpr(ctx, params[0]);
        },
        else => return null,
    }
}

/// Resolve the type of an expression / value (not necessarily a type expr).
pub fn resolveValueType(ctx: *Context, node: Ast.Node.Index) anyerror!?Type {
    const ast = ctx.ast;
    switch (ast.nodeTag(node)) {
        .identifier => {
            const name = ast.tokenSlice(ast.nodeMainToken(node));
            return try resolveIdentType(ctx, name, ast.tokenStart(ast.nodeMainToken(node)), false);
        },
        .field_access => return try resolveFieldAccessType(ctx, node, false),
        .call, .call_comma, .call_one, .call_one_comma => {
            // `Type.init(...)` / `Type.initCapacity(...)` → instance of Type
            // or return type of the callee.
            return try resolveCallValueType(ctx, node);
        },
        .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
            return try resolveTypeExpr(ctx, node);
        },
        .string_literal => {
            // Approximate `*const [N:0]u8` as a named type for display.
            return Type.named("[:0]const u8", false);
        },
        else => return null,
    }
}

/// Type of the declaration named `name` visible at `offset`.
pub fn resolveIdentType(ctx: *Context, name: []const u8, offset: u32, as_type_val: bool) anyerror!?Type {
    if (isPrimitive(name)) return Type.primitive(name);

    if (ctx.scopes.lookup(offset, name)) |decl| {
        if (decl.type_node) |tn| {
            var ty = try resolveTypeExpr(ctx, tn) orelse Type.unknown();
            ty.is_type_val = as_type_val;
            if (!as_type_val) {
                // Instance of the annotated type.
                ty.is_type_val = false;
            }
            return ty;
        }
        if (decl.init_node) |init| {
            // `const X = std.Build` or `const list = try ArrayList(u8).initCapacity(...)`
            if (as_type_val or decl.kind == .variable) {
                if (try resolveTypeExpr(ctx, init)) |ty| return ty;
            }
            if (try resolveValueType(ctx, init)) |ty| return ty;
        }
        if (decl.kind == .function) {
            return Type.named(name, true);
        }
    }

    // Top-level import binding: `const std = @import("std")`
    if (try resolveImportBindingType(ctx, name)) |ty| return ty;

    return Type.named(name, as_type_val);
}

fn resolveImportBindingType(ctx: *Context, name: []const u8) !?Type {
    const list = try imports.findImports(ctx.gpa, ctx.ast, ctx.uri, ctx.zig_lib_dir, ctx.packages);
    defer imports.freeImports(ctx.gpa, list);
    for (list) |imp| {
        if (!std.mem.eql(u8, imp.name, name)) continue;
        const target = imp.uri orelse return null;
        const held = try ctx.holdUri(target);
        return .{
            .data = .{ .container = .{ .uri = held, .name = "" } },
            .is_type_val = true,
        };
    }
    return null;
}

fn resolveFieldAccessType(ctx: *Context, node: Ast.Node.Index, as_type_val: bool) anyerror!?Type {
    const ast = ctx.ast;
    // field_access: lhs . identifier
    const data = ast.nodeData(node);
    // In Zig 0.16, field_access data is node_and_token
    const lhs, const field_token = data.node_and_token;
    const field_name = ast.tokenSlice(field_token);

    const lhs_ty = if (as_type_val)
        try resolveTypeExpr(ctx, lhs) orelse try resolveValueType(ctx, lhs) orelse return null
    else
        try resolveValueType(ctx, lhs) orelse try resolveTypeExpr(ctx, lhs) orelse return null;

    return try lookupMemberType(ctx, lhs_ty, field_name, as_type_val);
}

/// Look up `field_name` on `base_ty`, returning the member's type.
pub fn lookupMemberType(ctx: *Context, base_ty: Type, field_name: []const u8, as_type_val: bool) anyerror!?Type {
    var container_ty = base_ty.unwrapToValueContainer();
    // Type-val pointer like `*Build` used as namespace — deref for lookup.
    if (container_ty.data == .pointer) {
        if (container_ty.deref()) |inner| container_ty = inner;
    }

    switch (container_ty.data) {
        .container => |c| {
            const file_ast = ctx.loadFile(ctx, c.uri) orelse return null;
            var index = try containers.indexFile(ctx.gpa, file_ast);
            defer index.deinit();
            const member = index.find(field_name) orelse return null;

            if (member.kind == .function) {
                var fn_ty = containers.functionTypeFromMember(member);
                // If this is accessed as a type namespace method returning type…
                if (member.proto_node) |proto| {
                    if (try returnTypeOfProto(ctx, file_ast, proto, c)) |ret| {
                        const rp = try ctx.allocType(ret);
                        fn_ty.data.function.return_type = rp;
                    }
                }
                return fn_ty;
            }
            // Variable / re-export: try to resolve its init as a type.
            if (astVarInit(file_ast, member.node)) |init| {
                // Temporarily swap ast to the loaded file for nested resolve.
                const saved_ast = ctx.ast;
                const saved_uri = ctx.uri;
                ctx.ast = file_ast;
                ctx.uri = c.uri;
                defer {
                    ctx.ast = saved_ast;
                    ctx.uri = saved_uri;
                }
                if (try resolveTypeExpr(ctx, init)) |ty| {
                    var result = ty;
                    result.is_type_val = as_type_val or ty.is_type_val;
                    return result;
                }
                // `@import` re-export
                if (imports.importArgToken(file_ast, init)) |_| {
                    if (try imports.rootDeclImportPath(ctx.gpa, file_ast, member.name)) |rel| {
                        defer ctx.gpa.free(rel);
                        if (try imports.resolveImportUri(ctx.gpa, c.uri, rel, ctx.zig_lib_dir, ctx.packages)) |next| {
                            const held = try ctx.takeUri(next);
                            return .{
                                .data = .{ .container = .{ .uri = held, .name = "" } },
                                .is_type_val = true,
                            };
                        }
                    }
                }
            }
            return Type.named(field_name, as_type_val);
        },
        .named => |n| {
            // Try to resolve named type via imports + field path (`std.Build`).
            if (try resolveNamedToContainer(ctx, n.name)) |cty| {
                return try lookupMemberType(ctx, cty, field_name, as_type_val);
            }
            return Type.named(field_name, as_type_val);
        },
        else => return null,
    }
}

fn astVarInit(ast: Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    const var_decl = ast.fullVarDecl(node) orelse return null;
    return var_decl.ast.init_node.unwrap();
}

fn returnTypeOfProto(ctx: *Context, ast: Ast, proto_node: Ast.Node.Index, container: Type.Container) !?Type {
    _ = container;
    var buf: [1]Ast.Node.Index = undefined;
    const proto = ast.fullFnProto(&buf, proto_node) orelse return null;
    const ret = proto.ast.return_type.unwrap() orelse return null;
    const saved = ctx.ast;
    ctx.ast = ast;
    defer ctx.ast = saved;
    return try resolveTypeExpr(ctx, ret);
}

fn resolveNamedToContainer(ctx: *Context, name: []const u8) anyerror!?Type {
    // Already a full path like std.Build — walk components.
    if (std.mem.indexOfScalar(u8, name, '.')) |_| {
        var it = std.mem.tokenizeScalar(u8, name, '.');
        const first = it.next() orelse return null;
        var ty = try resolveImportBindingType(ctx, first) orelse
            try resolveIdentType(ctx, first, 0, true) orelse return null;
        while (it.next()) |part| {
            ty = try lookupMemberType(ctx, ty, part, true) orelse return null;
        }
        return ty;
    }
    return try resolveImportBindingType(ctx, name);
}

fn resolveTypeCall(ctx: *Context, call_node: Ast.Node.Index) !?Type {
    return try resolveGenericCall(ctx, call_node);
}

fn resolveCallValueType(ctx: *Context, call_node: Ast.Node.Index) anyerror!?Type {
    const ast = ctx.ast;
    var buf: [1]Ast.Node.Index = undefined;
    const full = ast.fullCall(&buf, call_node) orelse return null;

    // `SomeType.init(...)` / `.initCapacity` — if fn_expr is field access
    // on a type, result is instance of that type.
    if (ast.nodeTag(full.ast.fn_expr) == .field_access) {
        const data = ast.nodeData(full.ast.fn_expr);
        const lhs, const field_token = data.node_and_token;
        const method = ast.tokenSlice(field_token);
        if (std.mem.eql(u8, method, "init") or
            std.mem.eql(u8, method, "initCapacity") or
            std.mem.eql(u8, method, "empty"))
        {
            if (try resolveTypeExpr(ctx, lhs)) |ty| {
                var inst = ty;
                inst.is_type_val = false;
                // If ty is a function (type fn already applied), use return.
                if (ty.data == .container) return inst;
                if (ty.data == .function) {
                    if (ty.data.function.return_type) |r| {
                        var out = r.*;
                        out.is_type_val = false;
                        return out;
                    }
                }
                return inst;
            }
            // `ArrayList(u8).initCapacity` — lhs is a call
            if (try resolveTypeExpr(ctx, lhs)) |ty| {
                var inst = ty;
                inst.is_type_val = false;
                return inst;
            }
        }
    }

    // Fallback: resolve callee and use its return type.
    if (try resolveValueType(ctx, full.ast.fn_expr)) |fn_ty| {
        if (fn_ty.data == .function) {
            if (fn_ty.data.function.return_type) |r| return r.*;
        }
    }
    if (try resolveTypeCall(ctx, call_node)) |ty| {
        var inst = ty;
        inst.is_type_val = false;
        return inst;
    }
    return null;
}

/// Resolve a type-function call node into an instantiated container type.
pub fn resolveGenericCall(ctx: *Context, call_node: Ast.Node.Index) anyerror!?Type {
    const ast = ctx.ast;
    var buf: [1]Ast.Node.Index = undefined;
    const full = ast.fullCall(&buf, call_node) orelse return null;

    var arg_types: std.ArrayList(Type) = .empty;
    defer arg_types.deinit(ctx.gpa);
    for (full.ast.params) |param| {
        try arg_types.append(ctx.gpa, try resolveTypeExpr(ctx, param) orelse Type.unknown());
    }

    // Resolve the type function declaration.
    const fn_info = try findTypeFunctionDecl(ctx, full.ast.fn_expr) orelse return null;

    const param_names = try generics.typeParamNames(ctx.gpa, fn_info.ast, fn_info.proto_node);
    defer ctx.gpa.free(param_names);

    const bp = try ctx.holdBoundParams(try generics.bindParams(ctx.gpa, param_names, arg_types.items));
    // bp.names/types are owned for the request via holdBoundParams.

    const ret_expr = generics.typeFunctionReturnExpr(fn_info.ast, fn_info.fn_node) orelse {
        // e.g. `return array_list.Aligned(T, null)` — follow field/call.
        return try followTypeFnReturn(ctx, fn_info, bp, arg_types.items);
    };

    const tag = fn_info.ast.nodeTag(ret_expr);
    if (isContainerDecl(tag)) {
        return .{
            .data = .{
                .container = .{
                    .uri = fn_info.uri,
                    .name = fn_info.name,
                    .bound_params = bp,
                },
            },
            .is_type_val = true,
        };
    }

    // `return other.Aligned(T, null)` etc.
    return try followReturnNode(ctx, fn_info, ret_expr, bp, arg_types.items);
}

const TypeFnDecl = struct {
    uri: []const u8,
    ast: Ast,
    fn_node: Ast.Node.Index,
    proto_node: Ast.Node.Index,
    name: []const u8,
};

fn findTypeFunctionDecl(ctx: *Context, fn_expr: Ast.Node.Index) !?TypeFnDecl {
    const ast = ctx.ast;
    // identifier or field_access ending in the type fn name
    const name: []const u8 = blk: {
        switch (ast.nodeTag(fn_expr)) {
            .identifier => break :blk ast.tokenSlice(ast.nodeMainToken(fn_expr)),
            .field_access => {
                const lhs_ignored, const field_token = ast.nodeData(fn_expr).node_and_token;
                _ = lhs_ignored;
                break :blk ast.tokenSlice(field_token);
            },
            else => return null,
        }
    };

    // Resolve the namespace container for field access.
    var search_uri = ctx.uri;
    var search_ast = ctx.ast;

    if (ast.nodeTag(fn_expr) == .field_access) {
        const lhs, _ = ast.nodeData(fn_expr).node_and_token;
        const ns = try resolveTypeExpr(ctx, lhs) orelse try resolveValueType(ctx, lhs) orelse return null;
        const c = switch (ns.data) {
            .container => |c| c,
            else => return null,
        };
        search_uri = c.uri;
        search_ast = ctx.loadFile(ctx, c.uri) orelse return null;
    }

    var index = try containers.indexFile(ctx.gpa, search_ast);
    defer index.deinit();
    const member = index.find(name) orelse return null;
    if (member.kind != .function) return null;
    const proto = member.proto_node orelse return null;
    return .{
        .uri = search_uri,
        .ast = search_ast,
        .fn_node = member.node,
        .proto_node = proto,
        .name = name,
    };
}

fn followTypeFnReturn(ctx: *Context, fn_info: TypeFnDecl, bp: Type.BoundParams, arg_types: []const Type) !?Type {
    _ = ctx;
    _ = arg_types;
    // Body without a clear return — still attach bound_params to a container at this file.
    return .{
        .data = .{
            .container = .{
                .uri = fn_info.uri,
                .name = fn_info.name,
                .bound_params = bp,
            },
        },
        .is_type_val = true,
    };
}

fn followReturnNode(
    ctx: *Context,
    fn_info: TypeFnDecl,
    ret_expr: Ast.Node.Index,
    bp: Type.BoundParams,
    arg_types: []const Type,
) !?Type {
    _ = arg_types;
    const ast = fn_info.ast;
    const saved_ast = ctx.ast;
    const saved_uri = ctx.uri;
    ctx.ast = ast;
    ctx.uri = fn_info.uri;
    defer {
        ctx.ast = saved_ast;
        ctx.uri = saved_uri;
    }

    // `return array_list.Aligned(T, null)` — resolve call with substituted args.
    if (ast.nodeTag(ret_expr) == .call or ast.nodeTag(ret_expr) == .call_comma or
        ast.nodeTag(ret_expr) == .call_one or ast.nodeTag(ret_expr) == .call_one_comma)
    {
        if (try resolveGenericCall(ctx, ret_expr)) |inner| {
            var result = inner;
            // Prefer outer bound_params if inner has none.
            if (result.data == .container and result.data.container.bound_params.names.len == 0) {
                result.data.container.bound_params = bp;
            }
            return result;
        }
        // Resolve callee field to a type function in another file.
        var buf: [1]Ast.Node.Index = undefined;
        const full = ast.fullCall(&buf, ret_expr) orelse return null;
        if (try findTypeFunctionDecl(ctx, full.ast.fn_expr)) |inner_fn| {
            // Point container at the inner type fn's file; members live in the
            // returned struct of Aligned — use that file's index of the struct
            // inside the type fn body.
            if (generics.typeFunctionReturnExpr(inner_fn.ast, inner_fn.fn_node)) |inner_ret| {
                if (isContainerDecl(inner_fn.ast.nodeTag(inner_ret))) {
                    return .{
                        .data = .{
                            .container = .{
                                .uri = inner_fn.uri,
                                .name = inner_fn.name,
                                .bound_params = bp,
                            },
                        },
                        .is_type_val = true,
                    };
                }
            }
            return .{
                .data = .{
                    .container = .{
                        .uri = inner_fn.uri,
                        .name = inner_fn.name,
                        .bound_params = bp,
                    },
                },
                .is_type_val = true,
            };
        }
    }

    if (try resolveTypeExpr(ctx, ret_expr)) |ty| {
        var result = ty;
        if (result.data == .container) {
            result.data.container.bound_params = bp;
        }
        return result;
    }

    return .{
        .data = .{
            .container = .{
                .uri = fn_info.uri,
                .name = fn_info.name,
                .bound_params = bp,
            },
        },
        .is_type_val = true,
    };
}

fn isContainerDecl(tag: Ast.Node.Tag) bool {
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

fn isPrimitive(name: []const u8) bool {
    const primitives = [_][]const u8{
        "u8",  "u16", "u32", "u64",  "u128", "usize", "i8",    "i16",   "i32",  "i64",
        "i128", "isize", "f16", "f32", "f64",  "f80",  "f128",  "bool",  "void", "type",
        "anytype", "anyframe", "noreturn", "comptime_int", "comptime_float",
    };
    for (primitives) |p| {
        if (std.mem.eql(u8, p, name)) return true;
    }
    return false;
}

/// Resolve `base.field` where `base` is a typed value — for go-to-def / hover.
pub fn resolveMemberAccess(
    ctx: *Context,
    base_name: []const u8,
    field_name: []const u8,
    offset: u32,
) !?MemberResult {
    const base_ty = try resolveIdentType(ctx, base_name, offset, false) orelse return null;
    return try memberResult(ctx, base_ty, field_name);
}

pub fn memberResult(ctx: *Context, base_ty: Type, field_name: []const u8) anyerror!?MemberResult {
    var container_ty = base_ty.unwrapToValueContainer();
    if (container_ty.data == .pointer) {
        if (container_ty.deref()) |inner| container_ty = inner;
    }
    // Named `std.Build` etc.
    if (container_ty.data == .named) {
        container_ty = try resolveNamedToContainer(ctx, container_ty.data.named.name) orelse return null;
    }
    if (container_ty.data != .container) return null;
    const c = container_ty.data.container;

    const file_ast = ctx.loadFile(ctx, c.uri) orelse return null;

    // Prefer indexing a type-function's returned struct when `c.name` is set.
    var index = try indexForContainer(ctx, file_ast, c);
    defer index.deinit();

    const member = index.find(field_name) orelse return null;
    const loc = file_ast.tokenLocation(0, member.name_token);
    return .{
        .ty = containers.functionTypeFromMember(member),
        .uri = c.uri,
        .line = @intCast(loc.line),
        .character = @intCast(loc.column),
        .end_character = @intCast(loc.column + file_ast.tokenSlice(member.name_token).len),
        .signature = member.signature,
    };
}

fn indexForContainer(ctx: *Context, file_ast: Ast, c: Type.Container) !containers.ContainerIndex {
    // If this container came from a type function, try to index the returned struct.
    if (c.name.len > 0) {
        var file_index = try containers.indexFile(ctx.gpa, file_ast);
        defer file_index.deinit();
        if (file_index.find(c.name)) |m| {
            if (m.kind == .function) {
                if (generics.typeFunctionReturnExpr(file_ast, m.node)) |ret| {
                    if (isContainerDecl(file_ast.nodeTag(ret))) {
                        return try containers.indexContainerNode(ctx.gpa, file_ast, ret);
                    }
                }
                // Follow `return other.Aligned(...)` — index Aligned's returned struct.
                if (try indexThroughTypeFnReturn(ctx, file_ast, m.node)) |idx| return idx;
            }
        }
    }
    return try containers.indexFile(ctx.gpa, file_ast);
}

fn indexThroughTypeFnReturn(ctx: *Context, file_ast: Ast, fn_node: Ast.Node.Index) !?containers.ContainerIndex {
    const ret = generics.typeFunctionReturnExpr(file_ast, fn_node) orelse return null;
    if (isContainerDecl(file_ast.nodeTag(ret))) {
        return try containers.indexContainerNode(ctx.gpa, file_ast, ret);
    }
    // call → find type fn in other file
    if (file_ast.nodeTag(ret) != .call and file_ast.nodeTag(ret) != .call_comma and
        file_ast.nodeTag(ret) != .call_one and file_ast.nodeTag(ret) != .call_one_comma)
        return null;

    const saved_ast = ctx.ast;
    const saved_uri = ctx.uri;
    ctx.ast = file_ast;
    defer {
        ctx.ast = saved_ast;
        ctx.uri = saved_uri;
    }

    var buf: [1]Ast.Node.Index = undefined;
    const full = file_ast.fullCall(&buf, ret) orelse return null;
    const inner = try findTypeFunctionDecl(ctx, full.ast.fn_expr) orelse return null;
    if (generics.typeFunctionReturnExpr(inner.ast, inner.fn_node)) |inner_ret| {
        if (isContainerDecl(inner.ast.nodeTag(inner_ret))) {
            return try containers.indexContainerNode(ctx.gpa, inner.ast, inner_ret);
        }
    }
    // Fall back to indexing the whole file (Aligned's methods are inside the fn body struct).
    // Walk Aligned fn body for container_decl.
    return try findStructInTypeFn(ctx.gpa, inner.ast, inner.fn_node);
}

fn findStructInTypeFn(gpa: std.mem.Allocator, ast: Ast, fn_node: Ast.Node.Index) !?containers.ContainerIndex {
    if (generics.typeFunctionReturnExpr(ast, fn_node)) |ret| {
        if (isContainerDecl(ast.nodeTag(ret))) {
            return try containers.indexContainerNode(gpa, ast, ret);
        }
    }
    // Search the function body for any container_decl (Aligned pattern).
    _, const body = ast.nodeData(fn_node).node_and_node;
    if (findFirstContainer(ast, body)) |cnode| {
        return try containers.indexContainerNode(gpa, ast, cnode);
    }
    return null;
}

fn findFirstContainer(ast: Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    if (isContainerDecl(ast.nodeTag(node))) return node;
    switch (ast.nodeTag(node)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            var buf: [2]Ast.Node.Index = undefined;
            const stmts = ast.blockStatements(&buf, node) orelse return null;
            for (stmts) |stmt| {
                if (findFirstContainer(ast, stmt)) |c| return c;
            }
        },
        .@"return" => {
            if (ast.nodeData(node).opt_node.unwrap()) |e| return findFirstContainer(ast, e);
        },
        else => {},
    }
    return null;
}

const testing = std.testing;

// --- tests ---

const TestLoader = struct {
    files: std.StringHashMapUnmanaged(Ast) = .empty,

    fn load(ctx: *Context, uri: []const u8) ?Ast {
        const self: *TestLoader = @ptrCast(@alignCast(ctx.userdata.?));
        return self.files.get(uri);
    }
};

test "annotated param *Build resolves to pointer" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    _ = b;
        \\}
        \\
    , .zig);
    defer ast.deinit(gpa);

    var scopes = try scope_mod.build(gpa, ast);
    defer scopes.deinit();

    var loader: TestLoader = .{};
    defer loader.files.deinit(gpa);

    // Minimal fake Build.zig
    var build_ast = try Ast.parse(gpa,
        \\const Build = @This();
        \\pub fn addExecutable(b: *Build, options: anytype) void {}
        \\
    , .zig);
    defer build_ast.deinit(gpa);
    try loader.files.put(gpa, "file:///std/Build.zig", build_ast);

    var std_ast = try Ast.parse(gpa,
        \\pub const Build = @import("Build.zig");
        \\
    , .zig);
    defer std_ast.deinit(gpa);
    try loader.files.put(gpa, "file:///std/std.zig", std_ast);

    var packages: imports.PackageMap = .empty;
    defer packages.deinit(gpa);

    var ctx: Context = .{
        .gpa = gpa,
        .uri = "file:///build.zig",
        .ast = ast,
        .scopes = scopes,
        .zig_lib_dir = "/std",
        .packages = &packages,
        .loadFile = TestLoader.load,
        .userdata = &loader,
    };
    // Manual std import URI for the test: patch by putting std binding.
    // findImports won't resolve std without zig_lib_dir pointing at real layout.
    // Inject container type directly via scope annotation path:
    // `b: *std.Build` — resolveTypeExpr on the type node needs std.Build.
    // Override: put std import uri manually by using a local alias.
    defer ctx.deinitScratch();

    // Simpler source for this unit test:
    var ast2 = try Ast.parse(gpa,
        \\const Build = @import("Build.zig");
        \\pub fn build(b: *Build) void {
        \\    _ = b;
        \\}
        \\
    , .zig);
    defer ast2.deinit(gpa);
    var scopes2 = try scope_mod.build(gpa, ast2);
    defer scopes2.deinit();
    try loader.files.put(gpa, "file:///Build.zig", build_ast);

    ctx.ast = ast2;
    ctx.scopes = scopes2;
    ctx.uri = "file:///build.zig";

    const offset = blk: {
        var l: u32 = 0;
        var i: usize = 0;
        while (l < 2) : (l += 1) {
            const nl = std.mem.indexOfScalarPos(u8, ast2.source, i, '\n').?;
            i = nl + 1;
        }
        break :blk @as(u32, @intCast(i + 8));
    };

    const ty = try resolveIdentType(&ctx, "b", offset, false) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expect(ty.data == .pointer);
    const child = ty.deref().?;
    // Child may be named Build or container
    const ok = child.data == .named or child.data == .container;
    try testing.expect(ok);
}

test "resolveMemberAccess finds addExecutable on *Build" {
    const gpa = testing.allocator;
    var build_ast = try Ast.parse(gpa,
        \\const Build = @This();
        \\pub fn addExecutable(b: *Build, options: anytype) void {}
        \\
    , .zig);
    defer build_ast.deinit(gpa);

    var ast = try Ast.parse(gpa,
        \\const Build = @import("Build.zig");
        \\pub fn build(b: *Build) void {
        \\    _ = b.addExecutable;
        \\}
        \\
    , .zig);
    defer ast.deinit(gpa);

    var scopes = try scope_mod.build(gpa, ast);
    defer scopes.deinit();

    var loader: TestLoader = .{};
    defer loader.files.deinit(gpa);
    try loader.files.put(gpa, "file:///Build.zig", build_ast);

    var packages: imports.PackageMap = .empty;
    defer packages.deinit(gpa);

    var ctx: Context = .{
        .gpa = gpa,
        .uri = "file:///build.zig",
        .ast = ast,
        .scopes = scopes,
        .packages = &packages,
        .loadFile = TestLoader.load,
        .userdata = &loader,
    };
    defer ctx.deinitScratch();

    const offset = blk: {
        var l: u32 = 0;
        var i: usize = 0;
        while (l < 2) : (l += 1) {
            const nl = std.mem.indexOfScalarPos(u8, ast.source, i, '\n').?;
            i = nl + 1;
        }
        break :blk @as(u32, @intCast(i + 8));
    };

    const member = try resolveMemberAccess(&ctx, "b", "addExecutable", offset) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expect(std.mem.indexOf(u8, member.signature, "addExecutable") != null);
}

test "ArrayList(u8) instance resolves append via bound_params" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa,
        \\pub fn ArrayList(comptime T: type) type {
        \\    return struct {
        \\        pub fn append(self: *@This(), item: T) void {}
        \\    };
        \\}
        \\pub fn main() void {
        \\    var list: ArrayList(u8) = undefined;
        \\    list.append(1);
        \\}
        \\
    , .zig);
    defer ast.deinit(gpa);

    var scopes = try scope_mod.build(gpa, ast);
    defer scopes.deinit();

    var loader: TestLoader = .{};
    defer loader.files.deinit(gpa);
    try loader.files.put(gpa, "file:///main.zig", ast);

    var packages: imports.PackageMap = .empty;
    defer packages.deinit(gpa);

    var ctx: Context = .{
        .gpa = gpa,
        .uri = "file:///main.zig",
        .ast = ast,
        .scopes = scopes,
        .packages = &packages,
        .loadFile = TestLoader.load,
        .userdata = &loader,
    };
    defer ctx.deinitScratch();

    // Offset on `list` in `list.append`
    const offset = blk: {
        var l: u32 = 0;
        var i: usize = 0;
        while (l < 6) : (l += 1) {
            const nl = std.mem.indexOfScalarPos(u8, ast.source, i, '\n').?;
            i = nl + 1;
        }
        break :blk @as(u32, @intCast(i + 4));
    };

    const member = try resolveMemberAccess(&ctx, "list", "append", offset) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expect(std.mem.indexOf(u8, member.signature, "append") != null);
}

test "ArrayList(u8).init local resolves append" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa,
        \\pub fn ArrayList(comptime T: type) type {
        \\    return struct {
        \\        pub fn init() @This() { return .{}; }
        \\        pub fn append(self: *@This(), item: T) void {}
        \\    };
        \\}
        \\pub fn main() void {
        \\    var list = ArrayList(u8).init();
        \\    list.append(1);
        \\}
        \\
    , .zig);
    defer ast.deinit(gpa);

    var scopes = try scope_mod.build(gpa, ast);
    defer scopes.deinit();

    var loader: TestLoader = .{};
    defer loader.files.deinit(gpa);
    try loader.files.put(gpa, "file:///main.zig", ast);

    var packages: imports.PackageMap = .empty;
    defer packages.deinit(gpa);

    var ctx: Context = .{
        .gpa = gpa,
        .uri = "file:///main.zig",
        .ast = ast,
        .scopes = scopes,
        .packages = &packages,
        .loadFile = TestLoader.load,
        .userdata = &loader,
    };
    defer ctx.deinitScratch();

    const offset = blk: {
        var l: u32 = 0;
        var i: usize = 0;
        while (l < 7) : (l += 1) {
            const nl = std.mem.indexOfScalarPos(u8, ast.source, i, '\n').?;
            i = nl + 1;
        }
        break :blk @as(u32, @intCast(i + 4));
    };

    const member = try resolveMemberAccess(&ctx, "list", "append", offset) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expect(std.mem.indexOf(u8, member.signature, "append") != null);
}
