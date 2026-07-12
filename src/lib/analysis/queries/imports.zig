//! Resolves `@import("...")` targets from a file's top-level `const`/`var`
//! declarations to the imported file's URI.
//!
//! Relative file imports (`@import("foo.zig")`, `@import("../x.zig")`) are
//! resolved against the importer's URI. `"std"` resolves against Zig's
//! local stdlib when `zig_lib_dir` is known. Other named packages resolve
//! via `packages` (path-based entries from `build.zig.zon`). URL/git
//! deps remain a documented gap — no guessing.
//!
//! Not cached — cheap relative to parsing/item-tree building (root decls
//! only, no recursion into bodies), same as `resolve.zig`.

const std = @import("std");
const Ast = std.zig.Ast;
const uri_util = @import("../../uri.zig");

/// Named-package → root-file URI map (e.g. path deps from `build.zig.zon`).
pub const PackageMap = std.StringHashMapUnmanaged([]const u8);

pub const Import = struct {
    name: []const u8,
    path: []const u8,
    string_token: Ast.TokenIndex,
    uri: ?[]const u8,
};

pub fn freeImports(gpa: std.mem.Allocator, list: []const Import) void {
    for (list) |imp| {
        gpa.free(imp.name);
        gpa.free(imp.path);
        if (imp.uri) |u| gpa.free(u);
    }
    gpa.free(list);
}

pub fn resolveImportUri(
    gpa: std.mem.Allocator,
    importer_uri: []const u8,
    import_path: []const u8,
    zig_lib_dir: ?[]const u8,
    packages: ?*const PackageMap,
) !?[]const u8 {
    if (std.mem.eql(u8, import_path, "std")) {
        const lib_dir = zig_lib_dir orelse return null;
        const std_path = try std.fmt.allocPrint(gpa, "{s}/std/std.zig", .{std.mem.trimEnd(u8, lib_dir, "/\\")});
        defer gpa.free(std_path);
        return try uri_util.fromPath(gpa, std_path);
    }

    if (!std.mem.endsWith(u8, import_path, ".zig")) {
        if (packages) |map| {
            if (map.get(import_path)) |root_uri| {
                return try gpa.dupe(u8, root_uri);
            }
        }
        return null;
    }

    return try resolveRelativeUri(gpa, importer_uri, import_path);
}

pub fn resolveRelativeUri(gpa: std.mem.Allocator, importer_uri: []const u8, import_path: []const u8) ![]u8 {
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

pub fn importArgToken(ast: Ast, node: Ast.Node.Index) ?Ast.TokenIndex {
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

pub fn rootDeclImportPath(gpa: std.mem.Allocator, ast: Ast, name: []const u8) !?[]u8 {
    for (ast.rootDecls()) |node| {
        switch (ast.nodeTag(node)) {
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {},
            else => continue,
        }
        const var_decl = ast.fullVarDecl(node) orelse continue;
        const name_token = var_decl.ast.mut_token + 1;
        if (!std.mem.eql(u8, ast.tokenSlice(name_token), name)) continue;
        const init_node = var_decl.ast.init_node.unwrap() orelse return null;
        const arg_token = importArgToken(ast, init_node) orelse return null;
        return std.zig.string_literal.parseAlloc(gpa, ast.tokenSlice(arg_token)) catch return null;
    }
    return null;
}

pub fn findImports(
    gpa: std.mem.Allocator,
    ast: Ast,
    importer_uri: []const u8,
    zig_lib_dir: ?[]const u8,
    packages: ?*const PackageMap,
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
        const resolved = try resolveImportUri(gpa, importer_uri, path, zig_lib_dir, packages);

        try out.append(gpa, .{
            .name = name,
            .path = path,
            .string_token = arg_token,
            .uri = resolved,
        });
    }

    return out.toOwnedSlice(gpa);
}

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
    const uri = (try resolveImportUri(gpa, "file:///proj/a.zig", "b.zig", null, null)).?;
    defer gpa.free(uri);
    try testing.expectEqualStrings("file:///proj/b.zig", uri);
}

test "resolveImportUri: subdirectory" {
    const gpa = testing.allocator;
    const uri = (try resolveImportUri(gpa, "file:///proj/a.zig", "sub/b.zig", null, null)).?;
    defer gpa.free(uri);
    try testing.expectEqualStrings("file:///proj/sub/b.zig", uri);
}

test "resolveImportUri: parent directory" {
    const gpa = testing.allocator;
    const uri = (try resolveImportUri(gpa, "file:///proj/sub/a.zig", "../b.zig", null, null)).?;
    defer gpa.free(uri);
    try testing.expectEqualStrings("file:///proj/b.zig", uri);
}

test "resolveImportUri: std without zig_lib_dir returns null" {
    const gpa = testing.allocator;
    try testing.expectEqual(@as(?[]const u8, null), try resolveImportUri(gpa, "file:///proj/a.zig", "std", null, null));
}

test "resolveImportUri: std with zig_lib_dir points at std/std.zig" {
    const gpa = testing.allocator;
    const uri = (try resolveImportUri(gpa, "file:///proj/a.zig", "std", "/opt/zig/lib", null)).?;
    defer gpa.free(uri);
    try testing.expect(std.mem.endsWith(u8, uri, "/std/std.zig"));
    try testing.expect(std.mem.startsWith(u8, uri, "file://"));
}

test "resolveImportUri: named package from packages map" {
    const gpa = testing.allocator;
    var packages: PackageMap = .empty;
    defer {
        var it = packages.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        packages.deinit(gpa);
    }
    try packages.put(gpa, try gpa.dupe(u8, "foo"), try gpa.dupe(u8, "file:///proj/deps/foo/root.zig"));
    const uri = (try resolveImportUri(gpa, "file:///proj/a.zig", "foo", null, &packages)).?;
    defer gpa.free(uri);
    try testing.expectEqualStrings("file:///proj/deps/foo/root.zig", uri);
}

test "findImports: detects a relative import and ignores plain decls" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa,
        \\const std = @import("std");
        \\const helpers = @import("helpers.zig");
        \\const x = 1;
        \\
    , .zig);
    defer ast.deinit(gpa);

    const list = try findImports(gpa, ast, "file:///proj/main.zig", null, null);
    defer freeImports(gpa, list);

    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("std", list[0].name);
    try testing.expectEqual(@as(?[]const u8, null), list[0].uri);
    try testing.expectEqualStrings("helpers", list[1].name);
    try testing.expectEqualStrings("file:///proj/helpers.zig", list[1].uri.?);
}

test "rootDeclImportPath finds re-export imports" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa,
        \\pub const fmt = @import("fmt.zig");
        \\
    , .zig);
    defer ast.deinit(gpa);
    const path = (try rootDeclImportPath(gpa, ast, "fmt")).?;
    defer gpa.free(path);
    try testing.expectEqualStrings("fmt.zig", path);
}
