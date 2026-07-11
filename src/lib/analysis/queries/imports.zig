//! Resolves relative `@import("...")` targets from a file's top-level
//! `const`/`var` declarations to the imported file's URI.
//!
//! Only relative file imports (`@import("foo.zig")`, `@import("../x.zig")`)
//! are handled. Named-package imports (`@import("some_pkg")`, resolved via
//! `build.zig.zon`'s module graph — see project plan §1.5/§Phase 6) are a
//! documented gap, not something silently mishandled: `resolveImportUri`
//! returns `null` for them rather than guessing.
//!
//! Not cached — cheap relative to parsing/item-tree building (root decls
//! only, no recursion into bodies), same as `resolve.zig`.

const std = @import("std");
const Ast = std.zig.Ast;

pub const Import = struct {
    /// Owned copy of the local name bound to the import:
    /// `const <name> = @import(...)`.
    name: []const u8,
    /// Owned copy of the resolved absolute URI of the imported file, or
    /// `null` if the import target isn't a relative `.zig` path this
    /// query knows how to resolve.
    uri: ?[]const u8,
};

pub fn freeImports(gpa: std.mem.Allocator, imports: []const Import) void {
    for (imports) |imp| {
        gpa.free(imp.name);
        if (imp.uri) |uri| gpa.free(uri);
    }
    gpa.free(imports);
}

/// Resolves `import_path` (the literal argument to `@import`) against
/// `importer_uri` (the file doing the importing) into the imported file's
/// URI. Treats both as plain `/`-delimited strings — URIs use forward
/// slashes regardless of host OS, so this deliberately doesn't go through
/// `std.fs.path`, which is OS-flavored on Windows.
pub fn resolveImportUri(gpa: std.mem.Allocator, importer_uri: []const u8, import_path: []const u8) !?[]const u8 {
    if (!std.mem.endsWith(u8, import_path, ".zig")) return null; // named package: out of scope

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
/// not a relative file import this query handles).
pub fn findImports(gpa: std.mem.Allocator, ast: Ast, importer_uri: []const u8) ![]const Import {
    var out: std.ArrayList(Import) = .empty;
    errdefer {
        for (out.items) |imp| {
            gpa.free(imp.name);
            if (imp.uri) |uri| gpa.free(uri);
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
        defer gpa.free(path);

        const name_token = var_decl.ast.mut_token + 1;
        const name = try gpa.dupe(u8, ast.tokenSlice(name_token));
        errdefer gpa.free(name);
        const uri = try resolveImportUri(gpa, importer_uri, path);

        try out.append(gpa, .{ .name = name, .uri = uri });
    }

    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "resolveImportUri: sibling file in the same directory" {
    const gpa = testing.allocator;
    const uri = (try resolveImportUri(gpa, "file:///proj/a.zig", "b.zig")).?;
    defer gpa.free(uri);
    try testing.expectEqualStrings("file:///proj/b.zig", uri);
}

test "resolveImportUri: subdirectory" {
    const gpa = testing.allocator;
    const uri = (try resolveImportUri(gpa, "file:///proj/a.zig", "sub/b.zig")).?;
    defer gpa.free(uri);
    try testing.expectEqualStrings("file:///proj/sub/b.zig", uri);
}

test "resolveImportUri: parent directory" {
    const gpa = testing.allocator;
    const uri = (try resolveImportUri(gpa, "file:///proj/sub/a.zig", "../b.zig")).?;
    defer gpa.free(uri);
    try testing.expectEqualStrings("file:///proj/b.zig", uri);
}

test "resolveImportUri: named package import returns null" {
    const gpa = testing.allocator;
    try testing.expectEqual(@as(?[]const u8, null), try resolveImportUri(gpa, "file:///proj/a.zig", "std"));
}

test "findImports: detects a relative import and ignores plain decls" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "const std = @import(\"std\");\nconst helpers = @import(\"helpers.zig\");\nconst x = 1;\n", .zig);
    defer ast.deinit(gpa);

    const imports = try findImports(gpa, ast, "file:///proj/main.zig");
    defer freeImports(gpa, imports);

    try testing.expectEqual(@as(usize, 2), imports.len);

    try testing.expectEqualStrings("std", imports[0].name);
    try testing.expectEqual(@as(?[]const u8, null), imports[0].uri); // named package, unresolved

    try testing.expectEqualStrings("helpers", imports[1].name);
    try testing.expectEqualStrings("file:///proj/helpers.zig", imports[1].uri.?);
}
