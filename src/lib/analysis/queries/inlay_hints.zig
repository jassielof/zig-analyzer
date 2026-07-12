//! Parameter-name inlay hints at call sites.
//!
//! For each `callee(arg0, arg1, ...)` where `callee` resolves to a
//! known function with named parameters, emits a hint of the form
//! `name:` immediately before each argument. Skips arguments that are
//! already written as `name: value` (Zig's named-argument syntax) so we
//! don't double-label them. Does not attempt inferred-type hints — that
//! needs type analysis this analyzer doesn't have yet.

const std = @import("std");
const Ast = std.zig.Ast;
const item_tree_mod = @import("item_tree.zig");
const ItemTree = item_tree_mod.ItemTree;
const resolve = @import("resolve.zig");

pub const Hint = struct {
    line: u32,
    character: u32,
    /// Owned. Typically `"name: "`.
    label: []const u8,
};

pub fn freeHints(gpa: std.mem.Allocator, hints: []const Hint) void {
    for (hints) |h| gpa.free(h.label);
    gpa.free(hints);
}

/// Extracts parameter names from a function's signature source
/// (`fn foo(a: i32, b: bool) void` → `["a", "b"]`). Owned slices;
/// caller frees each name and the slice.
pub fn paramNamesFromSignature(gpa: std.mem.Allocator, signature: []const u8) ![]const []const u8 {
    const lparen = std.mem.indexOfScalar(u8, signature, '(') orelse return try gpa.alloc([]const u8, 0);
    const rparen = std.mem.lastIndexOfScalar(u8, signature, ')') orelse return try gpa.alloc([]const u8, 0);
    if (rparen <= lparen + 1) return try gpa.alloc([]const u8, 0);

    const inside = signature[lparen + 1 .. rparen];
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }

    var depth: i32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= inside.len) : (i += 1) {
        const at_end = i == inside.len;
        const c: u8 = if (at_end) ',' else inside[i];
        switch (c) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            ',' => if (depth == 0) {
                const part = std.mem.trim(u8, inside[start..i], " \t\n\r");
                if (part.len > 0) {
                    if (paramNameOf(part)) |name| {
                        try names.append(gpa, try gpa.dupe(u8, name));
                    }
                }
                start = i + 1;
            },
            else => {},
        }
    }

    return try names.toOwnedSlice(gpa);
}

fn paramNameOf(part: []const u8) ?[]const u8 {
    // `a: i32`, `a: anytype`, `comptime a: type`, `anytype` (unnamed)
    var rest = std.mem.trim(u8, part, " \t");
    for ([_][]const u8{ "comptime ", "noalias ", "anytype" }) |prefix| {
        if (std.mem.startsWith(u8, rest, prefix)) {
            if (std.mem.eql(u8, prefix, "anytype") and rest.len == prefix.len) return null;
            rest = std.mem.trimStart(u8, rest[prefix.len..], " \t");
        }
    }
    if (std.mem.eql(u8, rest, "anytype")) return null;
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const name = std.mem.trim(u8, rest[0..colon], " \t");
    if (name.len == 0) return null;
    return name;
}

pub const CollectOptions = struct {
    /// When true, skip calls that have exactly one argument (ZLS default).
    exclude_single_argument: bool = true,
};

/// Collects parameter-name inlay hints for every resolvable call in `ast`.
/// `lookupSignature` returns a function's signature source for a callee
/// name (and optional `base.field` access), or `null` if unknown.
pub fn collect(
    gpa: std.mem.Allocator,
    ast: Ast,
    item_tree: ItemTree,
    lookupSignature: *const fn (ctx: *anyopaque, base: ?[]const u8, name: []const u8) ?[]const u8,
    lookup_ctx: *anyopaque,
    options: CollectOptions,
) ![]const Hint {
    _ = item_tree; // reserved for future local-resolution of callees

    var out: std.ArrayList(Hint) = .empty;
    errdefer {
        for (out.items) |h| gpa.free(h.label);
        out.deinit(gpa);
    }

    var idx: Ast.TokenIndex = 0;
    while (idx + 1 < ast.tokens.len) : (idx += 1) {
        if (ast.tokenTag(idx) != .identifier) continue;
        if (ast.tokenTag(idx + 1) != .l_paren) continue;

        const callee_token = idx;
        const open_paren = idx + 1;
        const callee_name = ast.tokenSlice(callee_token);

        // Skip if this identifier is a declaration name (`fn foo(`).
        if (callee_token > 0 and ast.tokenTag(callee_token - 1) == .keyword_fn) continue;

        const fa = resolve.fieldAccessAtToken(ast, callee_token);
        const signature = if (fa) |f|
            lookupSignature(lookup_ctx, f.base, f.field)
        else
            lookupSignature(lookup_ctx, null, callee_name);
        const sig = signature orelse continue;

        const names = try paramNamesFromSignature(gpa, sig);
        defer {
            for (names) |n| gpa.free(n);
            gpa.free(names);
        }
        if (names.len == 0) continue;

        var arg_starts: std.ArrayList(Ast.TokenIndex) = .empty;
        defer arg_starts.deinit(gpa);

        var depth: i32 = 0;
        var arg_start_token: ?Ast.TokenIndex = null;
        var t = open_paren;
        while (t < ast.tokens.len) : (t += 1) {
            switch (ast.tokenTag(t)) {
                .l_paren, .l_bracket, .l_brace => depth += 1,
                .r_paren, .r_bracket, .r_brace => {
                    depth -= 1;
                    if (depth == 0 and ast.tokenTag(t) == .r_paren) {
                        if (arg_start_token) |start| try arg_starts.append(gpa, start);
                        break;
                    }
                },
                .comma => if (depth == 1) {
                    if (arg_start_token) |start| try arg_starts.append(gpa, start);
                    arg_start_token = null;
                },
                else => {
                    if (depth == 1 and arg_start_token == null and t > open_paren) {
                        arg_start_token = t;
                    }
                },
            }
        }

        if (options.exclude_single_argument and arg_starts.items.len == 1) continue;

        for (arg_starts.items, 0..) |start, arg_i| {
            if (arg_i >= names.len) break;
            try maybeAppendHint(gpa, ast, &out, start, names[arg_i]);
        }
    }

    return try out.toOwnedSlice(gpa);
}

fn maybeAppendHint(
    gpa: std.mem.Allocator,
    ast: Ast,
    out: *std.ArrayList(Hint),
    arg_start: Ast.TokenIndex,
    name: []const u8,
) !void {
    // Skip if the argument already uses named syntax: `name: expr`.
    if (arg_start + 1 < ast.tokens.len and
        ast.tokenTag(arg_start) == .identifier and
        ast.tokenTag(arg_start + 1) == .colon and
        std.mem.eql(u8, ast.tokenSlice(arg_start), name))
    {
        return;
    }

    const loc = ast.tokenLocation(0, arg_start);
    try out.append(gpa, .{
        .line = @intCast(loc.line),
        .character = @intCast(loc.column),
        .label = try std.fmt.allocPrint(gpa, "{s}: ", .{name}),
    });
}

const testing = std.testing;

test "paramNamesFromSignature extracts plain names" {
    const gpa = testing.allocator;
    const names = try paramNamesFromSignature(gpa, "fn add(a: i32, b: i32) i32");
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("a", names[0]);
    try testing.expectEqualStrings("b", names[1]);
}

test "paramNamesFromSignature skips bare anytype" {
    const gpa = testing.allocator;
    const names = try paramNamesFromSignature(gpa, "fn id(anytype) @TypeOf(x)");
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 0), names.len);
}
