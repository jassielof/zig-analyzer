//! Index a file's look-up-able members (functions + consts) for type-based
//! field/method resolution. Builds on the same root-decl walk as
//! `item_tree`, but keeps AST node handles so go-to-def can jump precisely.

const std = @import("std");
const Ast = std.zig.Ast;
const type_mod = @import("type.zig");
const Type = type_mod.Type;

pub const MemberKind = enum { function, field, variable };

pub const Member = struct {
    name: []const u8,
    kind: MemberKind,
    name_token: Ast.TokenIndex,
    node: Ast.Node.Index,
    /// Function prototype node when `kind == .function`.
    proto_node: ?Ast.Node.Index = null,
    /// Borrowed signature / decl source.
    signature: []const u8,
    is_pub: bool,
};

pub const ContainerIndex = struct {
    members: []const Member,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *ContainerIndex) void {
        self.gpa.free(self.members);
        self.* = undefined;
    }

    pub fn find(self: ContainerIndex, name: []const u8) ?Member {
        for (self.members) |m| {
            if (std.mem.eql(u8, m.name, name)) return m;
        }
        return null;
    }
};

/// Index top-level declarations of `ast` (file/`@This()` container).
pub fn indexFile(gpa: std.mem.Allocator, ast: Ast) !ContainerIndex {
    var out: std.ArrayList(Member) = .empty;
    errdefer out.deinit(gpa);

    for (ast.rootDecls()) |node| {
        try appendMember(gpa, &out, ast, node);
    }
    return .{ .members = try out.toOwnedSlice(gpa), .gpa = gpa };
}

/// Index declarations inside a `struct`/`enum`/`union` container node.
pub fn indexContainerNode(gpa: std.mem.Allocator, ast: Ast, container_node: Ast.Node.Index) !ContainerIndex {
    var out: std.ArrayList(Member) = .empty;
    errdefer out.deinit(gpa);

    var buf: [2]Ast.Node.Index = undefined;
    const decl = ast.fullContainerDecl(&buf, container_node) orelse
        return .{ .members = try out.toOwnedSlice(gpa), .gpa = gpa };

    for (decl.ast.members) |node| {
        try appendMember(gpa, &out, ast, node);
    }
    return .{ .members = try out.toOwnedSlice(gpa), .gpa = gpa };
}

fn appendMember(gpa: std.mem.Allocator, out: *std.ArrayList(Member), ast: Ast, node: Ast.Node.Index) !void {
    switch (ast.nodeTag(node)) {
        .fn_decl => {
            const proto_node, _ = ast.nodeData(node).node_and_node;
            var buf: [1]Ast.Node.Index = undefined;
            const proto = ast.fullFnProto(&buf, proto_node) orelse return;
            const name_token = proto.name_token orelse return;
            try out.append(gpa, .{
                .name = ast.tokenSlice(name_token),
                .kind = .function,
                .name_token = name_token,
                .node = node,
                .proto_node = proto_node,
                .signature = ast.getNodeSource(proto_node),
                .is_pub = proto.visib_token != null,
            });
        },
        .fn_proto, .fn_proto_one, .fn_proto_simple, .fn_proto_multi => {
            var buf: [1]Ast.Node.Index = undefined;
            const proto = ast.fullFnProto(&buf, node) orelse return;
            const name_token = proto.name_token orelse return;
            try out.append(gpa, .{
                .name = ast.tokenSlice(name_token),
                .kind = .function,
                .name_token = name_token,
                .node = node,
                .proto_node = node,
                .signature = ast.getNodeSource(node),
                .is_pub = proto.visib_token != null,
            });
        },
        .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
            const var_decl = ast.fullVarDecl(node) orelse return;
            const name_token = var_decl.ast.mut_token + 1;
            try out.append(gpa, .{
                .name = ast.tokenSlice(name_token),
                .kind = .variable,
                .name_token = name_token,
                .node = node,
                .signature = ast.getNodeSource(node),
                .is_pub = var_decl.visib_token != null,
            });
        },
        .container_field_init, .container_field_align, .container_field => {
            const field = ast.fullContainerField(node) orelse return;
            const name_token = field.ast.main_token;
            if (ast.tokenTag(name_token) != .identifier) return;
            try out.append(gpa, .{
                .name = ast.tokenSlice(name_token),
                .kind = .field,
                .name_token = name_token,
                .node = node,
                .signature = ast.getNodeSource(node),
                .is_pub = true,
            });
        },
        else => {},
    }
}

/// True when `fn_signature` looks like a method on `self_type_name`
/// (first param is `self: *Self`, `b: *Build`, etc.).
pub fn firstParamMatchesInstance(signature: []const u8, self_type_name: []const u8) bool {
    const lparen = std.mem.indexOfScalar(u8, signature, '(') orelse return false;
    const rparen = std.mem.indexOfScalar(u8, signature[lparen..], ')') orelse return false;
    const inside = std.mem.trim(u8, signature[lparen + 1 .. lparen + rparen], " \t\n\r");
    if (inside.len == 0) return false;

    const first = if (std.mem.indexOfScalar(u8, inside, ',')) |c|
        std.mem.trim(u8, inside[0..c], " \t\n\r")
    else
        inside;

    // `b: *Build`, `self: *Self`, `self: Self`
    const colon = std.mem.indexOfScalar(u8, first, ':') orelse return false;
    var ty = std.mem.trim(u8, first[colon + 1 ..], " \t");
    while (std.mem.startsWith(u8, ty, "*") or std.mem.startsWith(u8, ty, "const ")) {
        if (std.mem.startsWith(u8, ty, "*")) ty = std.mem.trim(u8, ty[1..], " \t");
        if (std.mem.startsWith(u8, ty, "const ")) ty = std.mem.trim(u8, ty["const ".len..], " \t");
    }
    // Match last path segment: `*std.Build` → `Build`, or exact.
    if (std.mem.eql(u8, ty, self_type_name)) return true;
    if (std.mem.lastIndexOfScalar(u8, ty, '.')) |dot| {
        return std.mem.eql(u8, ty[dot + 1 ..], self_type_name);
    }
    // `@This()` containers often use `Self` or the file's logical name.
    if (std.mem.eql(u8, ty, "Self") or std.mem.eql(u8, ty, "@This()")) return true;
    return false;
}

/// Build a `Type.function` from a member, attaching a best-effort first-param type name.
pub fn functionTypeFromMember(member: Member) Type {
    return .{
        .data = .{
            .function = .{
                .signature = member.signature,
                .name = member.name,
            },
        },
        .is_type_val = false,
    };
}

const testing = std.testing;

test "indexFile finds Build-like methods" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa,
        \\const Build = @This();
        \\pub fn addExecutable(b: *Build, options: anytype) void {}
        \\pub fn step(b: *Build, name: []const u8) void {}
        \\
    , .zig);
    defer ast.deinit(gpa);

    var index = try indexFile(gpa, ast);
    defer index.deinit();

    try testing.expect(index.find("addExecutable") != null);
    try testing.expect(index.find("step") != null);
    try testing.expect(firstParamMatchesInstance(index.find("addExecutable").?.signature, "Build"));
}
