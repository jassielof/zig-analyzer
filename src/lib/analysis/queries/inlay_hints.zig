//! Parameter-name inlay hints at call sites, and a narrow slice of
//! inferred-type hints for `const`/`var` declarations.
//!
//! For each `callee(arg0, arg1, ...)` where `callee` resolves to a
//! known function with named parameters, emits a hint of the form
//! `name:` immediately before each argument. Skips arguments that are
//! already written as `name: value` (Zig's named-argument syntax), or
//! that are themselves a bare identifier already named like the
//! parameter (`visit(tree)` where the parameter is also `tree`) — either
//! way the hint would just repeat text already on screen.
//!
//! General inferred-type hints need real type inference this analyzer
//! doesn't have. But a declaration initialized directly with a literal
//! (`const x = "hello";`) doesn't need any — the type is determined by
//! the literal's own syntax, no analysis required. `collectTypeHints`
//! covers exactly that narrow, unambiguous case (string literals for
//! now), not general expressions.

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

/// Collects inferred-type hints for `const`/`var` declarations that have
/// no explicit type annotation and are initialized directly with a
/// literal this module knows how to name the type of (currently: string
/// literals, whose type is `*const [N:0]u8`). Covers top-level
/// declarations and the immediate body of each function — the same scope
/// boundary `resolve.zig`'s local resolution uses.
pub fn collectTypeHints(gpa: std.mem.Allocator, ast: Ast) ![]const Hint {
    var out: std.ArrayList(Hint) = .empty;
    errdefer {
        for (out.items) |h| gpa.free(h.label);
        out.deinit(gpa);
    }

    for (ast.rootDecls()) |node| {
        try maybeCollectVarDeclTypeHint(gpa, ast, node, &out);
        if (ast.nodeTag(node) != .fn_decl) continue;
        const body_node = (ast.nodeData(node).node_and_node)[1];
        var buf: [2]Ast.Node.Index = undefined;
        const stmts = ast.blockStatements(&buf, body_node) orelse continue;
        for (stmts) |stmt| try maybeCollectVarDeclTypeHint(gpa, ast, stmt, &out);
    }

    return out.toOwnedSlice(gpa);
}

fn maybeCollectVarDeclTypeHint(gpa: std.mem.Allocator, ast: Ast, node: Ast.Node.Index, out: *std.ArrayList(Hint)) !void {
    switch (ast.nodeTag(node)) {
        .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {},
        else => return,
    }
    const var_decl = ast.fullVarDecl(node) orelse return;
    if (var_decl.ast.type_node.unwrap() != null) return; // already annotated
    const init_node = var_decl.ast.init_node.unwrap() orelse return;
    const label = (try inferredTypeLabel(gpa, ast, init_node)) orelse return;
    errdefer gpa.free(label);

    const name_token = var_decl.ast.mut_token + 1;
    const loc = ast.tokenLocation(0, name_token);
    try out.append(gpa, .{
        .line = @intCast(loc.line),
        .character = @intCast(loc.column + ast.tokenSlice(name_token).len),
        .label = label,
    });
}

/// Owned type-annotation text (e.g. `": *const [5:0]u8"`), or `null` when
/// `init_node` isn't a literal kind this module infers the type of.
fn inferredTypeLabel(gpa: std.mem.Allocator, ast: Ast, init_node: Ast.Node.Index) !?[]u8 {
    if (ast.nodeTag(init_node) != .string_literal) return null;
    const raw = ast.tokenSlice(ast.nodeMainToken(init_node));
    const decoded = std.zig.string_literal.parseAlloc(gpa, raw) catch return null;
    defer gpa.free(decoded);
    return try std.fmt.allocPrint(gpa, ": *const [{d}:0]u8", .{decoded.len});
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
    lookupSignature: *const fn (ctx: *anyopaque, base: ?[]const u8, name: []const u8, call_offset: u32) ?[]const u8,
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

        const Arg = struct { start: Ast.TokenIndex, end: Ast.TokenIndex };
        var arg_starts: std.ArrayList(Arg) = .empty;
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
                        if (arg_start_token) |start| try arg_starts.append(gpa, .{ .start = start, .end = t - 1 });
                        break;
                    }
                },
                .comma => if (depth == 1) {
                    if (arg_start_token) |start| try arg_starts.append(gpa, .{ .start = start, .end = t - 1 });
                    arg_start_token = null;
                },
                else => {
                    if (depth == 1 and arg_start_token == null and t > open_paren) {
                        arg_start_token = t;
                    }
                },
            }
        }

        // Build-style: single `.{}` arg — prefer field-name hints over `options:`.
        if (options.exclude_single_argument and arg_starts.items.len == 1) {
            if (isStructLiteralStart(ast, arg_starts.items[0].start)) {
                try appendStructLiteralFieldNameHints(gpa, ast, &out, arg_starts.items[0].start, arg_starts.items[0].end);
            }
            continue;
        }

        const call_offset = ast.tokenStart(callee_token);
        const fa = resolve.fieldAccessAtToken(ast, callee_token);
        const signature = if (fa) |f|
            lookupSignature(lookup_ctx, f.base, f.field, call_offset)
        else
            lookupSignature(lookup_ctx, null, callee_name, call_offset);
        const sig = signature orelse continue;

        const names = try paramNamesFromSignature(gpa, sig);
        defer {
            for (names) |n| gpa.free(n);
            gpa.free(names);
        }
        if (names.len == 0) continue;

        for (arg_starts.items, 0..) |arg, arg_i| {
            if (arg_i >= names.len) break;
            try maybeAppendHint(gpa, ast, &out, arg.start, arg.end, names[arg_i]);
        }
    }

    return try out.toOwnedSlice(gpa);
}

fn isStructLiteralStart(ast: Ast, start: Ast.TokenIndex) bool {
    // `.{}` or `T{}` — period then l_brace, or identifier then l_brace.
    if (start + 1 >= ast.tokens.len) return false;
    if (ast.tokenTag(start) == .period and ast.tokenTag(start + 1) == .l_brace) return true;
    if (ast.tokenTag(start) == .identifier and ast.tokenTag(start + 1) == .l_brace) return true;
    return false;
}

/// Field-name hints before each value in a `.{}` / `T{}` literal
/// (`.name = <hint "name: ">value`). Skips when the value is already a bare
/// identifier matching the field (`.name = name`).
fn appendStructLiteralFieldNameHints(
    gpa: std.mem.Allocator,
    ast: Ast,
    out: *std.ArrayList(Hint),
    start: Ast.TokenIndex,
    end: Ast.TokenIndex,
) !void {
    var t = start;
    while (t <= end and t + 2 < ast.tokens.len) : (t += 1) {
        // `. field_name = value`
        if (ast.tokenTag(t) != .period) continue;
        if (ast.tokenTag(t + 1) != .identifier) continue;
        if (ast.tokenTag(t + 2) != .equal) continue;

        const field_name = ast.tokenSlice(t + 1);
        const value_token = t + 3;
        if (value_token > end) break;

        // Skip `.name = name`
        if (ast.tokenTag(value_token) == .identifier and
            std.mem.eql(u8, ast.tokenSlice(value_token), field_name))
        {
            continue;
        }

        const loc = ast.tokenLocation(0, value_token);
        try out.append(gpa, .{
            .line = @intCast(loc.line),
            .character = @intCast(loc.column),
            .label = try std.fmt.allocPrint(gpa, "{s}: ", .{field_name}),
        });
    }
}

fn maybeAppendHint(
    gpa: std.mem.Allocator,
    ast: Ast,
    out: *std.ArrayList(Hint),
    arg_start: Ast.TokenIndex,
    arg_end: Ast.TokenIndex,
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

    // Skip if the whole argument is a single bare identifier already
    // named after the parameter (`add(tree)` where the parameter is also
    // `tree`) — the hint would just repeat what's already on screen
    // (`tree: tree`), matching rust-analyzer/clangd's convention.
    if (arg_start == arg_end and
        ast.tokenTag(arg_start) == .identifier and
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

test "collectTypeHints infers a string literal's type for an unannotated top-level const" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "pub const prose_title = \"Missing doc comment\";\n", .zig);
    defer ast.deinit(gpa);

    const hints = try collectTypeHints(gpa, ast);
    defer freeHints(gpa, hints);

    try testing.expectEqual(@as(usize, 1), hints.len);
    try testing.expectEqual(@as(u32, 0), hints[0].line);
    try testing.expectEqualStrings(": *const [19:0]u8", hints[0].label); // "Missing doc comment" is 19 bytes
}

test "collectTypeHints skips a declaration that already has a type annotation" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "const x: []const u8 = \"hi\";\n", .zig);
    defer ast.deinit(gpa);

    const hints = try collectTypeHints(gpa, ast);
    defer freeHints(gpa, hints);
    try testing.expectEqual(@as(usize, 0), hints.len);
}

test "collectTypeHints finds a local string const inside a function body" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "fn f() void {\n    const greeting = \"hi\";\n    _ = greeting;\n}\n", .zig);
    defer ast.deinit(gpa);

    const hints = try collectTypeHints(gpa, ast);
    defer freeHints(gpa, hints);
    try testing.expectEqual(@as(usize, 1), hints.len);
    try testing.expectEqualStrings(": *const [2:0]u8", hints[0].label);
}

fn testLookupSig(_: *anyopaque, _: ?[]const u8, _: []const u8, _: u32) ?[]const u8 {
    return "fn addExecutable(b: *Build, options: anytype) void";
}

test "collect emits field-name hints for single struct-literal arg" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa,
        \\fn build(b: *Build) void {
        \\    b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = mod,
        \\    });
        \\}
        \\
    , .zig);
    defer ast.deinit(gpa);

    var tree = try item_tree_mod.build(gpa, ast);
    defer tree.deinit(gpa);

    var dummy: u8 = 0;
    const hints = try collect(gpa, ast, tree, testLookupSig, &dummy, .{ .exclude_single_argument = true });
    defer freeHints(gpa, hints);

    try testing.expect(hints.len >= 2);
    try testing.expectEqualStrings("name: ", hints[0].label);
    try testing.expectEqualStrings("root_module: ", hints[1].label);
}
