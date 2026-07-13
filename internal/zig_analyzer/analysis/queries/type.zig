//! Semantic type ADT for expression resolution.
//!
//! Deliberately smaller than ZLS's `Type`: enough for annotated params,
//! pointer unwrap, container member lookup, and generic `bound_params`
//! (e.g. `ArrayList(u8)`). Prefer "miss" over inventing a wrong type.

const std = @import("std");

/// A resolved type. Strings are borrowed from AST source or owned arenas
/// depending on the producer — callers that need longevity must dupe.
pub const Type = struct {
    data: Data,
    /// When true, this names a type value (`std.Build`, `u8`) rather than
    /// an instance (`b: *std.Build`).
    is_type_val: bool = false,

    pub const Data = union(enum) {
        /// Unresolved / opaque — we know a name but not its shape yet.
        named: Named,
        /// `*T` / `[*]T` / `[]T` simplified to a single pointer-ish wrapper.
        pointer: Pointer,
        /// Optional `?T`.
        optional: *Type,
        /// Error union `E!T` — we only keep the payload for now.
        error_union: *Type,
        /// A function type (for callables found as members).
        function: Function,
        /// A file-level or struct container we can look members up in.
        container: Container,
        /// Primitive / builtin we don't need to open a file for.
        primitive: []const u8,
        /// `anytype` / unknown.
        unknown: void,
    };

    pub const Named = struct {
        /// Dotted or simple name as written (`std.Build`, `Build`, `u8`).
        name: []const u8,
    };

    pub const Pointer = struct {
        child: *Type,
        is_const: bool = false,
        size: Size = .one,

        pub const Size = enum { one, many, slice, c };
    };

    pub const Function = struct {
        /// Borrowed signature source (`fn addExecutable(b: *Build, ...) *Step.Compile`).
        signature: []const u8,
        /// Decl name token location helpers — file URI owned by caller context.
        name: []const u8,
        /// First parameter type when known (for method detection).
        first_param: ?*Type = null,
        /// Return type when known.
        return_type: ?*Type = null,
    };

    pub const Container = struct {
        /// `file://…` URI of the file that defines this container. Owned by
        /// the analysis arena / caller — not freed by `Type`.
        uri: []const u8,
        /// Empty for file/`@This()` containers; otherwise the const name
        /// holding a `struct {…}` if we tracked one.
        name: []const u8 = "",
        /// Generic substitutions (`T` → `u8`). Keys are param names.
        bound_params: BoundParams = .{},
    };

    pub const BoundParams = struct {
        /// Parallel arrays kept small; typical generics have 1–3 params.
        names: []const []const u8 = &.{},
        types: []const Type = &.{},

        pub fn get(self: BoundParams, name: []const u8) ?Type {
            for (self.names, self.types) |n, t| {
                if (std.mem.eql(u8, n, name)) return t;
            }
            return null;
        }
    };

    pub fn primitive(name: []const u8) Type {
        return .{ .data = .{ .primitive = name }, .is_type_val = true };
    }

    pub fn named(name: []const u8, is_type_val: bool) Type {
        return .{ .data = .{ .named = .{ .name = name } }, .is_type_val = is_type_val };
    }

    pub fn unknown() Type {
        return .{ .data = .unknown };
    }

    /// Strip one layer of pointer, if any.
    pub fn deref(self: Type) ?Type {
        return switch (self.data) {
            .pointer => |p| p.child.*,
            else => null,
        };
    }

    /// Unwrap optional / error-union payload once each, then optional deref.
    pub fn unwrapToValueContainer(self: Type) Type {
        var t = self;
        if (t.data == .optional) t = t.data.optional.*;
        if (t.data == .error_union) t = t.data.error_union.*;
        if (t.deref()) |inner| {
            if (!inner.is_type_val) return inner;
        }
        return t;
    }

    pub fn stringify(self: Type, buf: []u8) []const u8 {
        return switch (self.data) {
            .named => |n| n.name,
            .primitive => |p| p,
            .pointer => |p| blk: {
                const inner = p.child.stringify(buf[1..]);
                buf[0] = '*';
                @memcpy(buf[1..][0..inner.len], inner);
                break :blk buf[0 .. 1 + inner.len];
            },
            .optional => |c| blk: {
                const inner = c.stringify(buf[1..]);
                buf[0] = '?';
                @memcpy(buf[1..][0..inner.len], inner);
                break :blk buf[0 .. 1 + inner.len];
            },
            .error_union => |c| c.stringify(buf),
            .function => |f| f.name,
            .container => |c| if (c.name.len > 0) c.name else "struct",
            .unknown => "unknown",
        };
    }

    /// Owned `Type` display string (e.g. `*Module`). Caller frees.
    pub fn allocStringify(self: Type, gpa: std.mem.Allocator) ![]u8 {
        var buf: [256]u8 = undefined;
        const s = self.stringify(&buf);
        return try gpa.dupe(u8, s);
    }
};

const testing = std.testing;

test "pointer deref yields child" {
    var child = Type.named("Build", true);
    const ptr: Type = .{
        .data = .{ .pointer = .{ .child = &child } },
        .is_type_val = false,
    };
    const d = ptr.deref().?;
    try testing.expect(d.data == .named);
    try testing.expectEqualStrings("Build", d.data.named.name);
}

test "bound_params get" {
    const u8_ty = Type.primitive("u8");
    const bp: Type.BoundParams = .{
        .names = &.{"T"},
        .types = &.{u8_ty},
    };
    try testing.expectEqualStrings("u8", bp.get("T").?.data.primitive);
    try testing.expect(bp.get("U") == null);
}
