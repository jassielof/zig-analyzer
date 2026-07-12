//! Resolves `@import("...")` targets from a file's top-level `const`/`var`
//! declarations to the imported file's URI.
//!
//! Relative file imports (`@import("foo.zig")`, `@import("../x.zig")`) are
//! resolved against the importer's URI. The special `std` package is
//! resolved against Zig's local stdlib when `zig_lib_dir` is known (from
//! `zig env`) — never fetched from the web. Other named-package imports
//! (`@import("some_pkg")`, resolved via `build.zig.zon`'s module graph —
//! see project plan §1.5/§Phase 6) remain a documented gap:
//! `resolveImportUri` returns `null` for them rather than guessing.
//!
//! Not cached — cheap relative to parsing/item-tree building (root decls
//! only, no recursion into bodies), same as `resolve.zig`.

const std = @import("std");
const Ast = std.zig.Ast;
const uri_util = @import("../../uri.zig");

pub const Import = struct {
    /// Owned copy of the local name bound to the import:
    /// `const <name> = @import(...)`.
    name: []const u8,
    /// Owned copy of the raw import path (`"helpers.zig"` / `"std"`),
    /// without quotes.
    path: []const u8,
    /// Token index of the string-literal argument — used by hover /
    /// go-to-definition when the cursor is on the `"..."` itself.
    string_token: Ast.TokenIndex,
    /// Owned copy of the resolved absolute URI of the imported file, or
    /// `null` if the import target isn't something this query knows how
    /// to resolve (named package other than `std`, or `std` without a
    /// known `zig_lib_dir`).
    uri: ?[]const u8,
};

pub fn freeImports(gpa: std.mem.Allocator, imports: []const Import) void {
    for (imports) |imp| {
        gpa.free(imp.name);
        gpa.free(imp.path);
        if (imp.uri) |u| gpa.free(u);
    }
    gpa.free(imports);
}

/// Resolves `import_path` (the literal argument to `@import`) into the
/// imported file's URI. Relative `.zig` paths are resolved against
/// `importer_uri`; `"std"` is resolved against `zig_lib_dir` when
/// provided. Treats URIs as plain `/`-delimited strings — they use
/// forward slashes regardless of host OS, so this deliberately doesn't
/// go through `std.fs.path`, which is OS-flavored on Windows.
pub fn resolveImportUri(
    gpa: std.mem.Allocator,
    importer_uri: []const u8,
    import_path: []const u8,
    zig_lib_dir: ?[]const u8,
) !?[]const u8 {
    if (std.mem.eql(u8, import_path, "std")) {
        const lib_dir = zig_lib_dir orelse return null;
        // Join with `/` regardless of host OS — `uri.fromPath` normalizes
        // separators for the URI form, and mixing `std.fs.path.join`'s
        // native seps with a posix-looking `lib_dir` (as in tests) is messy.
        const std_path = try std.fmt.allocPrint(gpa, "{s}/std/std.zig", .{std.mem.trimEnd(u8, lib_dir, "/\\")});
        defer gpa.free(std_path);
        return try uri_util.fromPath(gpa, std_path);
    }

    if (!std.mem.endsWith(u8, import_path, ".zig")) return null; // other named packages: out of scope

    const dir = if (std.mem.lastIndexOfScalar(u8, importer_uri, '/')) |i|
        importer_uri[0..i]
    else
        importer_uri;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);
    try result.appendSlice(gpa, dir);

    var it = std.mem.tokenizeScalar(u8, import_path, '/');
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (std.mem.lastIndexOfScalar(u8, result.items, '/')) |i| {
                result.shrinkRetainingCapacity(i);
            }
            continue;
        }
        try result.append(gpa, '/');
        try result.appendSlice(gpa, segment);
    }

    return try result.toOwnedSlice(gpa);
}

/// If `node` is `@import("literal")`, returns the raw (still-quoted)
/// string literal token text of the argument.
fn importArgToken(ast: Ast, node: Ast.Node.Index) ?Ast.TokenIndex {
    switch (ast.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
        else => return null,
    }
    if (!std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(node)), "@import")) return null;

    var buf: [2]Ast.Node.Index = undefined;
    const params = ast.builtinCallParams(&buf, node) orelse return null;
    if (params.len != 1) return null;
    if (ast.nodeTag(params[0]) != .string_literal) return null;
    return ast.nodeMainToken(params[0]);
}

/// Finds every `const <name> = @import("path");`-shaped top-level
/// declaration and resolves each import path to a URI (or `null` if it's
/// not something this query handles).
pub fn findImports(
    gpa: std.mem.Allocator,
    ast: Ast,
    importer_uri: []const u8,
    zig_lib_dir: ?[]const u8,
) ![]const Import {
    var out: std.ArrayList(Import) = .empty;
    errdefer {
        for (out.items) |imp| {
            gpa.free(imp.name);
            gpa.free(imp.path);
            if (imp.uri) |u| gpa.free(u);
        }
        out.deinit(gpa);
    }

    for (ast.rootDecls()) |node| {
        switch (ast.nodeTag(node)) {
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {},
            else => continue,
        }
        const var_decl = ast.fullVarDecl(node) orelse continue;
        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        const arg_token = importArgToken(ast, init_node) orelse continue;

        const path = std.zig.string_literal.parseAlloc(gpa, ast.tokenSlice(arg_token)) catch continue;
        errdefer gpa.free(path);

        const name_token = var_decl.ast.mut_token + 1;
        const name = try gpa.dupe(u8, ast.tokenSlice(name_token));
        errdefer gpa.free(name);
        const resolved = try resolveImportUri(gpa, importer_uri, path, zig_lib_dir);

        try out.append(gpa, .{
            .name = name,
            .path = path,
            .string_token = arg_token,
            .uri = resolved,
        });
    }

    return out.toOwnedSlice(gpa);
}

/// If `offset` falls inside an `@import("...")` string literal that is
/// the initializer of a top-level import binding, returns that binding.
/// Used so go-to-definition / hover on the `"..."` itself (not just the
/// `const name`) resolve to the imported file.
pub fn importAtOffset(imports_list: []const Import, ast: Ast, offset: u32) ?Import {
    for (imports_list) |imp| {
        const start = ast.tokenStart(imp.string_token);
        const end = start + ast.tokenSlice(imp.string_token).len;
        if (offset >= start and offset < end) return imp;
    }
    return null;
}

const testing = std.testing;

test "resolveImportUri: sibling file in the same directory" {
    const gpa = testing.allocator;
    const uri = (try resolveImportUri(gpa, "file:///proj/a.zig", "b.zig", null)).?;
    defer gpa.free(uri);
    try testing.expectEqualStrings("file:///proj/b.zig", uri);
}

test "resolveImportUri: subdirectory" {
    const gpa = testing.allocator;
    const uri = (try resolveImportUri(gpa, "file:///proj/a.zig", "sub/b.zig", null)).?;
    defer gpa.free(uri);
    try testing.expectEqualStrings("file:///proj/sub/b.zig", uri);
}

test "resolveImportUri: parent directory" {
    const gpa = testing.allocator;
    const uri = (try resolveImportUri(gpa, "file:///proj/sub/a.zig", "../b.zig", null)).?;
    defer gpa.free(uri);
    try testing.expectEqualStrings("file:///proj/b.zig", uri);
}

test "resolveImportUri: std without zig_lib_dir returns null" {
    const gpa = testing.allocator;
    try testing.expectEqual(@as(?[]const u8, null), try resolveImportUri(gpa, "file:///proj/a.zig", "std", null));
}

test "resolveImportUri: std with zig_lib_dir points at std/std.zig" {
    const gpa = testing.allocator;
    const uri = (try resolveImportUri(gpa, "file:///proj/a.zig", "std", "/opt/zig/lib")).?;
    defer gpa.free(uri);
    // fromPath lowercases nothing here (posix-style absolute); just check the suffix.
    try testing.expect(std.mem.endsWith(u8, uri, "/std/std.zig"));
    try testing.expect(std.mem.startsWith(u8, uri, "file://"));
}

test "findImports: detects a relative import and ignores plain decls" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "const std = @import(\"std\");\nconst helpers = @import(\"helpers.zig\");\nconst x = 1;\n", .zig);
    defer ast.deinit(gpa);

    const list = try findImports(gpa, ast, "file:///proj/main.zig", null);
    defer freeImports(gpa, list);

    try testing.expectEqual(@as(usize, 2), list.len);

    try testing.expectEqualStrings("std", list[0].name);
    try testing.expectEqualStrings("std", list[0].path);
    try testing.expectEqual(@as(?[]const u8, null), list[0].uri); // no zig_lib_dir

    try testing.expectEqualStrings("helpers", list[1].name);
    try testing.expectEqualStrings("helpers.zig", list[1].path);
    try testing.expectEqualStrings("file:///proj/helpers.zig", list[1].uri.?);
}
