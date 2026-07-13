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

/// Detects whether `offset` sits inside the string-literal argument of an
/// `@import(` call, returning the raw text typed so far (unquoted). Token-
/// based rather than AST-node-based, so it works for the still-
/// unterminated string a completion request fires against mid-typing
/// (`@import("st|` — no closing quote yet), which the tokenizer emits as
/// `.invalid` rather than `.string_literal` (see `Tokenizer.state.string_literal`
/// in the standard library: unterminated strings become `.invalid` at
/// end-of-line/EOF, not a different flavor of string token).
pub fn importStringPrefixAt(ast: Ast, offset: u32) ?[]const u8 {
    var idx: Ast.TokenIndex = 0;
    while (idx < ast.tokens.len) : (idx += 1) {
        const tag = ast.tokenTag(idx);
        if (tag != .string_literal and tag != .invalid) continue;

        const start = ast.tokenStart(idx);
        const slice = ast.tokenSlice(idx);
        if (slice.len == 0 or slice[0] != '"') continue; // not a string token
        const end = start + slice.len;
        if (offset < start or offset > end) continue;

        if (idx < 2) return null;
        if (ast.tokenTag(idx - 1) != .l_paren) return null;
        if (ast.tokenTag(idx - 2) != .builtin) return null;
        if (!std.mem.eql(u8, ast.tokenSlice(idx - 2), "@import")) return null;

        const content_start = start + 1; // past the opening quote
        if (offset <= content_start) return "";
        // A closing quote, if typed already, ends the content early.
        const has_closing_quote = slice.len >= 2 and slice[slice.len - 1] == '"';
        const content_end_max = if (has_closing_quote) end - 1 else end;
        const content_end = @min(offset, content_end_max);
        if (content_end <= content_start) return "";
        return ast.source[content_start..content_end];
    }
    return null;
}

pub const ImportCompletion = struct {
    /// Owned. Text to insert in place of the typed prefix — a bare name
    /// (`"std"`, a package name) or a path segment (`"helpers.zig"`,
    /// `"sub/"` for a directory, trailing slash included so triggering
    /// completion again immediately lists that directory's contents).
    label: []const u8,
    is_directory: bool,
};

pub fn freeImportCompletions(gpa: std.mem.Allocator, items: []const ImportCompletion) void {
    for (items) |c| gpa.free(c.label);
    gpa.free(items);
}

/// Suggests completions for the partial text inside an `@import("` string:
/// `"std"` (when `zig_lib_dir` is known), named packages from `packages`
/// (`build.zig.zon` path/URL dependencies), and relative `.zig`
/// files/subdirectories under `importer_uri`'s own directory. `prefix` is
/// `importStringPrefixAt`'s output — raw, unquoted, possibly containing
/// `/` for a path already partially typed.
pub fn collectImportCompletions(
    gpa: std.mem.Allocator,
    io: std.Io,
    importer_uri: []const u8,
    prefix: []const u8,
    zig_lib_dir: ?[]const u8,
    packages: ?*const PackageMap,
) ![]ImportCompletion {
    var out: std.ArrayList(ImportCompletion) = .empty;
    errdefer {
        for (out.items) |c| gpa.free(c.label);
        out.deinit(gpa);
    }

    // "std" and named packages are single-segment names, not paths — only
    // offer them before the first `/` of the typed prefix.
    if (std.mem.indexOfScalar(u8, prefix, '/') == null) {
        if (zig_lib_dir != null and std.mem.startsWith(u8, "std", prefix)) {
            try out.append(gpa, .{ .label = try gpa.dupe(u8, "std"), .is_directory = false });
        }
        if (packages) |map| {
            var it = map.iterator();
            while (it.next()) |entry| {
                if (!std.mem.startsWith(u8, entry.key_ptr.*, prefix)) continue;
                try out.append(gpa, .{ .label = try gpa.dupe(u8, entry.key_ptr.*), .is_directory = false });
            }
        }
    }

    // Relative filesystem entries: split `prefix` into the already-typed
    // subdirectory portion and the base-name filter for the final segment.
    const importer_path = uri_util.toFsPath(gpa, importer_uri) catch return try out.toOwnedSlice(gpa);
    defer gpa.free(importer_path);
    const importer_dir = std.fs.path.dirname(importer_path) orelse importer_path;

    const last_slash = std.mem.lastIndexOfScalar(u8, prefix, '/');
    const sub_dir = if (last_slash) |i| prefix[0..i] else "";
    const base_filter = if (last_slash) |i| prefix[i + 1 ..] else prefix;

    const list_dir_path = if (sub_dir.len == 0)
        try gpa.dupe(u8, importer_dir)
    else
        try std.fs.path.join(gpa, &.{ importer_dir, sub_dir });
    defer gpa.free(list_dir_path);

    var dir = std.Io.Dir.cwd().openDir(io, list_dir_path, .{ .iterate = true }) catch return try out.toOwnedSlice(gpa);
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, base_filter)) continue;
        switch (entry.kind) {
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                try out.append(gpa, .{ .label = try gpa.dupe(u8, entry.name), .is_directory = false });
            },
            .directory => {
                const with_slash = try std.fmt.allocPrint(gpa, "{s}/", .{entry.name});
                try out.append(gpa, .{ .label = with_slash, .is_directory = true });
            },
            else => {},
        }
    }

    return try out.toOwnedSlice(gpa);
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

test "importStringPrefixAt finds the typed prefix of an unterminated @import string" {
    const gpa = testing.allocator;
    // `@import("st` — the string is still unterminated (no closing `"`),
    // which is exactly the state a completion request fires in mid-typing.
    var ast = try Ast.parse(gpa, "const x = @import(\"st", .zig);
    defer ast.deinit(gpa);

    // Offset at the very end of the source, right after "st".
    const prefix = importStringPrefixAt(ast, @intCast(ast.source.len)).?;
    try testing.expectEqualStrings("st", prefix);
}

test "importStringPrefixAt works on an already-closed string too" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "const x = @import(\"std\");\n", .zig);
    defer ast.deinit(gpa);

    // Cursor right after "st", before the closing quote.
    const offset: u32 = @intCast(std.mem.indexOf(u8, ast.source, "std").? + 2);
    const prefix = importStringPrefixAt(ast, offset).?;
    try testing.expectEqualStrings("st", prefix);
}

test "importStringPrefixAt returns null outside any @import call" {
    const gpa = testing.allocator;
    var ast = try Ast.parse(gpa, "const x = \"not an import\";\n", .zig);
    defer ast.deinit(gpa);

    const offset: u32 = @intCast(std.mem.indexOf(u8, ast.source, "not").?);
    try testing.expectEqual(@as(?[]const u8, null), importStringPrefixAt(ast, offset));
}

test "collectImportCompletions suggests std and matching packages" {
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
    try packages.put(gpa, try gpa.dupe(u8, "stanza"), try gpa.dupe(u8, "file:///proj/deps/stanza/root.zig"));
    try packages.put(gpa, try gpa.dupe(u8, "known_folders"), try gpa.dupe(u8, "file:///proj/deps/known_folders/root.zig"));

    // A nonexistent importer directory: filesystem listing no-ops, but
    // std/package suggestions (which don't touch disk) still work.
    const items = try collectImportCompletions(gpa, testing.io, "file:///does/not/exist/main.zig", "st", "/opt/zig/lib", &packages);
    defer freeImportCompletions(gpa, items);

    var found_std = false;
    var found_stanza = false;
    for (items) |item| {
        if (std.mem.eql(u8, item.label, "std")) found_std = true;
        if (std.mem.eql(u8, item.label, "stanza")) found_stanza = true;
        try testing.expect(!std.mem.eql(u8, item.label, "known_folders")); // doesn't match "st" prefix
    }
    try testing.expect(found_std);
    try testing.expect(found_stanza);
}

test "collectImportCompletions lists sibling .zig files and subdirectories" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    (tmp.dir.createFile(testing.io, "helpers.zig", .{}) catch unreachable).close(testing.io);
    (tmp.dir.createFile(testing.io, "notes.txt", .{}) catch unreachable).close(testing.io);
    try tmp.dir.createDir(testing.io, "sub", .default_dir);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &path_buf);
    const abs_dir = path_buf[0..len];

    const importer_path = try std.fs.path.join(gpa, &.{ abs_dir, "main.zig" });
    defer gpa.free(importer_path);
    const importer_uri = try @import("../../uri.zig").fromPath(gpa, importer_path);
    defer gpa.free(importer_uri);

    const items = try collectImportCompletions(gpa, testing.io, importer_uri, "", null, null);
    defer freeImportCompletions(gpa, items);

    var found_helpers = false;
    var found_sub = false;
    for (items) |item| {
        if (std.mem.eql(u8, item.label, "helpers.zig")) found_helpers = true;
        if (std.mem.eql(u8, item.label, "sub/")) found_sub = true;
        try testing.expect(!std.mem.eql(u8, item.label, "notes.txt")); // not .zig, not a dir
    }
    try testing.expect(found_helpers);
    try testing.expect(found_sub);
}
