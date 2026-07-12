//! Resolves named packages from `build.zig.zon` to a root `.zig` URI.
//!
//! Supports:
//! - `.path` dependencies (relative to the workspace / package that owns the zon)
//! - `.url` + `.hash` dependencies under `{global_cache}/p/{hash}` (Zig's
//!   package cache; works for both legacy `1220…` and `name-semver-hash` forms)
//!
//! The module root for a Zig package is ultimately wired in `build.zig`
//! (`addImport` / `addModule`). Without a build runner we guess from the
//! package's `build.zig` (`root_source_file = b.path(...)`), its `.paths`
//! list, and common layouts (`src/root.zig`, `{name}.zig`, …).

const std = @import("std");
const uri_util = @import("../../uri.zig");
const imports = @import("imports.zig");

pub const PackageMap = imports.PackageMap;

/// How a workspace root is analyzed for packages / modules.
pub const WorkspaceMode = enum {
    /// Has `build.zig` (and optionally `build.zig.zon`).
    build_script,
    /// No build script — relative `@import` and `std` only.
    freestanding,
};

/// True when `workspace_root_path/build.zig` exists on disk.
pub fn hasBuildZig(io: std.Io, workspace_root_path: []const u8) bool {
    const build_path = std.fs.path.join(std.heap.page_allocator, &.{ workspace_root_path, "build.zig" }) catch return false;
    defer std.heap.page_allocator.free(build_path);
    return fileExists(io, build_path);
}

pub fn detectWorkspaceMode(io: std.Io, workspace_root_path: []const u8) WorkspaceMode {
    return if (hasBuildZig(io, workspace_root_path)) .build_script else .freestanding;
}

/// Walks parents of `file_path` looking for a `build.zig`.
pub fn fileHasAncestorBuildZig(io: std.Io, file_path: []const u8) bool {
    var dir = std.heap.page_allocator.dupe(u8, std.fs.path.dirname(file_path) orelse file_path) catch return false;
    defer std.heap.page_allocator.free(dir);
    while (true) {
        if (hasBuildZig(io, dir)) return true;
        const parent = std.fs.path.dirname(dir) orelse return false;
        if (std.mem.eql(u8, parent, dir)) return false;
        const next = std.heap.page_allocator.dupe(u8, parent) catch return false;
        std.heap.page_allocator.free(dir);
        dir = next;
    }
}

/// Clears and frees every entry in `map`.
pub fn clearPackages(gpa: std.mem.Allocator, map: *PackageMap) void {
    var it = map.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        gpa.free(e.value_ptr.*);
    }
    map.clearRetainingCapacity();
}

/// Reads `build.zig.zon` under `workspace_root_path` and inserts deps into
/// `out`. Existing entries with the same name are kept (first wins).
/// `global_cache_dir` is required to resolve URL/hash deps; path deps work
/// without it. Also registers modules `build.zig` creates entirely on its
/// own via `b.addModule("name", .{ .root_source_file = b.path("…") })` —
/// these have no `build.zig.zon` entry at all (purely local module
/// aliasing), so they're handled independently of whether a zon file
/// exists or parses.
pub fn loadDepsFromWorkspace(
    gpa: std.mem.Allocator,
    io: std.Io,
    workspace_root_path: []const u8,
    global_cache_dir: ?[]const u8,
    out: *PackageMap,
) !void {
    // Prefer import names from this workspace's `build.zig` `addImport("…")`
    // when present; fall back to the zon dependency key.
    const import_names = try parseAddImportNames(gpa, io, workspace_root_path);
    defer {
        for (import_names) |n| gpa.free(n);
        gpa.free(import_names);
    }

    try loadAddModuleRootsFromBuildZig(gpa, io, workspace_root_path, out);

    const zon_path = try std.fs.path.join(gpa, &.{ workspace_root_path, "build.zig.zon" });
    defer gpa.free(zon_path);

    const source = readFileAlloc(gpa, io, zon_path) catch return;
    defer gpa.free(source);

    const deps = try parseDependencies(gpa, source);
    defer {
        for (deps) |d| {
            gpa.free(d.name);
            if (d.rel_path) |p| gpa.free(p);
            if (d.hash) |h| gpa.free(h);
        }
        gpa.free(deps);
    }

    for (deps) |dep| {
        const pkg_dir = (try resolveDepDir(gpa, io, workspace_root_path, global_cache_dir, dep)) orelse continue;
        defer gpa.free(pkg_dir);

        const root_fs = (try findPackageRootFile(gpa, io, pkg_dir, dep.name)) orelse continue;
        defer gpa.free(root_fs);

        const root_uri = try uri_util.fromPath(gpa, root_fs);
        defer gpa.free(root_uri);

        // Register under the zon key…
        try putPackage(gpa, out, dep.name, root_uri);

        // …and under any `addImport("name", …)` that likely refers to it
        // (same name is the common case; also alias when names match
        // ignoring `-`/`_`).
        for (import_names) |imp_name| {
            if (std.mem.eql(u8, imp_name, dep.name) or namesLooselyEqual(imp_name, dep.name)) {
                try putPackage(gpa, out, imp_name, root_uri);
            }
        }
    }
}

const AddModuleRoot = struct { name: []u8, rel_path: []u8 };

/// Finds `b.addModule("name", .{ ... .root_source_file = b.path("rel") ... })`
/// calls in `workspace_root_path`'s `build.zig` and registers each as a
/// package directly — these are modules the build script defines and
/// wires up entirely on its own (`exe.root_module.addImport("name", mod)`),
/// with no corresponding `build.zig.zon` dependency to correlate against.
fn loadAddModuleRootsFromBuildZig(gpa: std.mem.Allocator, io: std.Io, workspace_root_path: []const u8, out: *PackageMap) !void {
    const build_path = try std.fs.path.join(gpa, &.{ workspace_root_path, "build.zig" });
    defer gpa.free(build_path);
    const source = readFileAlloc(gpa, io, build_path) catch return;
    defer gpa.free(source);

    const roots = try parseAddModuleRoots(gpa, source);
    defer {
        for (roots) |r| {
            gpa.free(r.name);
            gpa.free(r.rel_path);
        }
        gpa.free(roots);
    }

    for (roots) |r| {
        const full = std.fs.path.resolve(gpa, &.{ workspace_root_path, r.rel_path }) catch continue;
        defer gpa.free(full);
        if (!fileExists(io, full)) continue;
        const root_uri = try uri_util.fromPath(gpa, full);
        defer gpa.free(root_uri);
        try putPackage(gpa, out, r.name, root_uri);
    }
}

fn parseAddModuleRoots(gpa: std.mem.Allocator, source: []const u8) ![]AddModuleRoot {
    var out: std.ArrayList(AddModuleRoot) = .empty;
    errdefer {
        for (out.items) |r| {
            gpa.free(r.name);
            gpa.free(r.rel_path);
        }
        out.deinit(gpa);
    }

    const needle = "addModule(";
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, source, start, needle)) |idx| {
        const open_paren = idx + needle.len - 1;
        var i = open_paren + 1;
        while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\n' or source[i] == '\r')) : (i += 1) {}

        if (i >= source.len or source[i] != '"') {
            start = idx + needle.len;
            continue;
        }
        i += 1;
        const name_start = i;
        while (i < source.len and source[i] != '"') : (i += 1) {}
        if (i >= source.len) break;
        const name = source[name_start..i];

        const close_paren = findMatchingParen(source, open_paren) orelse break;
        start = close_paren + 1;

        const call_body = source[open_paren + 1 .. close_paren];
        const rel = extractRootSourceFilePath(call_body) orelse continue;

        try out.append(gpa, .{ .name = try gpa.dupe(u8, name), .rel_path = try gpa.dupe(u8, rel) });
    }

    return out.toOwnedSlice(gpa);
}

/// `.root_source_file = b.path("rel")` (or `.path("rel")`) within an
/// `addModule`/`addExecutable`/`createModule` call's body.
fn extractRootSourceFilePath(call_body: []const u8) ?[]const u8 {
    const key = "root_source_file";
    const key_idx = std.mem.indexOf(u8, call_body, key) orelse return null;
    const marker = "path(\"";
    const path_idx = std.mem.indexOfPos(u8, call_body, key_idx + key.len, marker) orelse return null;
    const rel_start = path_idx + marker.len;
    const rel_end = std.mem.indexOfScalarPos(u8, call_body, rel_start, '"') orelse return null;
    const rel = call_body[rel_start..rel_end];
    if (!std.mem.endsWith(u8, rel, ".zig")) return null;
    return rel;
}

fn findMatchingParen(source: []const u8, open_index: usize) ?usize {
    if (open_index >= source.len or source[open_index] != '(') return null;
    var depth: i32 = 0;
    var i = open_index;
    var in_string = false;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (in_string) {
            if (c == '\\' and i + 1 < source.len) {
                i += 1;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Walks parent directories of `file_path` looking for `build.zig` or
/// `build.zig.zon` and loads packages from the first package root found.
/// No-op if `out` already has entries (workspace-folder load already succeeded).
pub fn loadDepsWalkingUpFromFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    global_cache_dir: ?[]const u8,
    out: *PackageMap,
) !void {
    if (out.count() > 0) return;

    var dir = try gpa.dupe(u8, std.fs.path.dirname(file_path) orelse file_path);
    defer gpa.free(dir);

    while (true) {
        const zon_path = try std.fs.path.join(gpa, &.{ dir, "build.zig.zon" });
        defer gpa.free(zon_path);
        const build_path = try std.fs.path.join(gpa, &.{ dir, "build.zig" });
        defer gpa.free(build_path);
        if (fileExists(io, zon_path) or fileExists(io, build_path)) {
            try loadDepsFromWorkspace(gpa, io, dir, global_cache_dir, out);
            return;
        }
        const parent = std.fs.path.dirname(dir) orelse return;
        if (std.mem.eql(u8, parent, dir)) return;
        const next = try gpa.dupe(u8, parent);
        gpa.free(dir);
        dir = next;
    }
}

fn putPackage(gpa: std.mem.Allocator, out: *PackageMap, name: []const u8, root_uri: []const u8) !void {
    if (out.contains(name)) return;
    const name_owned = try gpa.dupe(u8, name);
    errdefer gpa.free(name_owned);
    const uri_owned = try gpa.dupe(u8, root_uri);
    errdefer gpa.free(uri_owned);
    try out.put(gpa, name_owned, uri_owned);
}

fn namesLooselyEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) {
        // fangz vs fang_z won't match length; only normalize `-`/`_`
    }
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const na: u8 = if (ca == '-') '_' else ca;
        const nb: u8 = if (cb == '-') '_' else cb;
        if (na != nb) return false;
    }
    return true;
}

const Dep = struct {
    name: []u8,
    rel_path: ?[]u8 = null,
    hash: ?[]u8 = null,
};

fn parseDependencies(gpa: std.mem.Allocator, source: []const u8) ![]Dep {
    var out: std.ArrayList(Dep) = .empty;
    errdefer {
        for (out.items) |d| {
            gpa.free(d.name);
            if (d.rel_path) |p| gpa.free(p);
            if (d.hash) |h| gpa.free(h);
        }
        out.deinit(gpa);
    }

    const deps_key = ".dependencies";
    const deps_start = std.mem.indexOf(u8, source, deps_key) orelse return try out.toOwnedSlice(gpa);
    var i = deps_start + deps_key.len;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\n' or source[i] == '\r' or source[i] == '=')) : (i += 1) {}
    if (i >= source.len or source[i] != '.') return try out.toOwnedSlice(gpa);
    if (i + 1 >= source.len or source[i + 1] != '{') return try out.toOwnedSlice(gpa);
    i += 2;

    const deps_body_start = i;
    const deps_body_end = findMatchingBrace(source, deps_body_start - 1) orelse return try out.toOwnedSlice(gpa);
    const body = source[deps_body_start..deps_body_end];

    var j: usize = 0;
    while (j < body.len) {
        while (j < body.len) {
            if (body[j] == ' ' or body[j] == '\t' or body[j] == '\n' or body[j] == '\r' or body[j] == ',') {
                j += 1;
                continue;
            }
            if (body[j] == '/' and j + 1 < body.len and body[j + 1] == '/') {
                while (j < body.len and body[j] != '\n') j += 1;
                continue;
            }
            break;
        }
        if (j >= body.len) break;

        if (body[j] != '.') {
            j += 1;
            continue;
        }
        j += 1;
        const name_start = j;
        while (j < body.len and isIdentChar(body[j])) j += 1;
        if (j == name_start) continue;
        const name = body[name_start..j];

        while (j < body.len and (body[j] == ' ' or body[j] == '\t' or body[j] == '\n' or body[j] == '\r')) j += 1;
        if (j >= body.len or body[j] != '=') continue;
        j += 1;
        while (j < body.len and (body[j] == ' ' or body[j] == '\t' or body[j] == '\n' or body[j] == '\r')) j += 1;
        if (j + 1 >= body.len or body[j] != '.' or body[j + 1] != '{') continue;
        const entry_open = j + 1;
        const entry_close = findMatchingBrace(body, entry_open) orelse break;
        const entry = body[entry_open + 1 .. entry_close];
        j = entry_close + 1;

        const path = extractQuotedField(entry, ".path");
        const hash = extractQuotedField(entry, ".hash");
        if (path == null and hash == null) continue;

        try out.append(gpa, .{
            .name = try gpa.dupe(u8, name),
            .rel_path = if (path) |p| try gpa.dupe(u8, p) else null,
            .hash = if (hash) |h| try gpa.dupe(u8, h) else null,
        });
    }

    return try out.toOwnedSlice(gpa);
}

fn extractQuotedField(entry: []const u8, key: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, entry, key) orelse return null;
    var i = idx + key.len;
    while (i < entry.len and (entry[i] == ' ' or entry[i] == '\t' or entry[i] == '\n' or entry[i] == '\r' or entry[i] == '=')) : (i += 1) {}
    if (i >= entry.len or entry[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < entry.len and entry[i] != '"') : (i += 1) {}
    if (i >= entry.len) return null;
    return entry[start..i];
}

fn resolveDepDir(
    gpa: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    global_cache_dir: ?[]const u8,
    dep: Dep,
) !?[]u8 {
    if (dep.rel_path) |rel| {
        const dir = try std.fs.path.resolve(gpa, &.{ workspace_root, rel });
        if (dirExists(io, dir)) return dir;
        gpa.free(dir);
    }
    if (dep.hash) |hash| {
        const cache = global_cache_dir orelse return null;
        const dir = try std.fs.path.join(gpa, &.{ cache, "p", hash });
        if (dirExists(io, dir)) return dir;
        gpa.free(dir);
    }
    return null;
}

fn parseAddImportNames(gpa: std.mem.Allocator, io: std.Io, workspace_root: []const u8) ![][]u8 {
    const build_path = try std.fs.path.join(gpa, &.{ workspace_root, "build.zig" });
    defer gpa.free(build_path);
    const source = readFileAlloc(gpa, io, build_path) catch return try gpa.alloc([]u8, 0);
    defer gpa.free(source);

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }

    const needle = "addImport(";
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, source, start, needle)) |idx| {
        var i = idx + needle.len;
        while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\n' or source[i] == '\r')) : (i += 1) {}
        if (i >= source.len or source[i] != '"') {
            start = idx + needle.len;
            continue;
        }
        i += 1;
        const name_start = i;
        while (i < source.len and source[i] != '"') : (i += 1) {}
        if (i >= source.len) break;
        const name = source[name_start..i];
        if (name.len > 0) try out.append(gpa, try gpa.dupe(u8, name));
        start = i + 1;
    }
    return try out.toOwnedSlice(gpa);
}

fn findMatchingBrace(source: []const u8, open_index: usize) ?usize {
    if (open_index >= source.len or source[open_index] != '{') return null;
    var depth: i32 = 0;
    var i = open_index;
    var in_string = false;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (in_string) {
            if (c == '\\' and i + 1 < source.len) {
                i += 1;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn isIdentChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => false,
    };
}

fn findPackageRootFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    pkg_dir: []const u8,
    package_name: []const u8,
) !?[]u8 {
    // Prefer `root_source_file = b.path("…")` from the package's build.zig.
    if (try rootSourceFromBuildZig(gpa, io, pkg_dir)) |p| return p;

    // Prefer an explicit `.zig` entry from the dependency's own zon `.paths`.
    if (try zigFileFromPackageZon(gpa, io, pkg_dir)) |p| return p;

    const dashed = try std.mem.replaceOwned(u8, gpa, package_name, "_", "-");
    defer gpa.free(dashed);

    const candidates = [_][]const u8{
        "src/root.zig",
        "root.zig",
        "src/main.zig",
        "src/lib.zig",
    };

    for (candidates) |rel| {
        if (try existingFile(gpa, io, pkg_dir, rel)) |p| return p;
    }

    inline for (.{ "{s}.zig", "src/{s}.zig" }) |fmt| {
        const rel_a = try std.fmt.allocPrint(gpa, fmt, .{package_name});
        defer gpa.free(rel_a);
        if (try existingFile(gpa, io, pkg_dir, rel_a)) |p| return p;

        if (!std.mem.eql(u8, dashed, package_name)) {
            const rel_b = try std.fmt.allocPrint(gpa, fmt, .{dashed});
            defer gpa.free(rel_b);
            if (try existingFile(gpa, io, pkg_dir, rel_b)) |p| return p;
        }
    }

    return null;
}

fn rootSourceFromBuildZig(gpa: std.mem.Allocator, io: std.Io, pkg_dir: []const u8) !?[]u8 {
    const build_path = try std.fs.path.join(gpa, &.{ pkg_dir, "build.zig" });
    defer gpa.free(build_path);
    const source = readFileAlloc(gpa, io, build_path) catch return null;
    defer gpa.free(source);

    // Match `root_source_file = b.path("rel")` / `b.path("rel")` near addModule.
    const markers = [_][]const u8{ "root_source_file", "b.path(\"", ".path(\"" };
    for (markers) |marker| {
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, source, start, marker)) |idx| {
            var i = idx + marker.len;
            if (std.mem.eql(u8, marker, "root_source_file")) {
                while (i < source.len and source[i] != '"') : (i += 1) {}
                if (i >= source.len) break;
                i += 1;
            }
            const rel_start = i;
            while (i < source.len and source[i] != '"') : (i += 1) {}
            if (i >= source.len) break;
            const rel = source[rel_start..i];
            if (std.mem.endsWith(u8, rel, ".zig")) {
                if (try existingFile(gpa, io, pkg_dir, rel)) |p| return p;
            }
            start = i + 1;
        }
    }
    return null;
}

fn zigFileFromPackageZon(gpa: std.mem.Allocator, io: std.Io, pkg_dir: []const u8) !?[]u8 {
    const zon_path = try std.fs.path.join(gpa, &.{ pkg_dir, "build.zig.zon" });
    defer gpa.free(zon_path);
    const source = readFileAlloc(gpa, io, zon_path) catch return null;
    defer gpa.free(source);

    const paths_key = ".paths";
    const paths_idx = std.mem.indexOf(u8, source, paths_key) orelse return null;
    var i = paths_idx + paths_key.len;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\n' or source[i] == '\r' or source[i] == '=')) : (i += 1) {}
    if (i >= source.len or source[i] != '.') return null;
    if (i + 1 >= source.len or source[i + 1] != '{') return null;
    const open = i + 1;
    const close = findMatchingBrace(source, open) orelse return null;
    const body = source[open + 1 .. close];

    var best: ?[]u8 = null;
    errdefer if (best) |b| gpa.free(b);

    var j: usize = 0;
    while (j < body.len) : (j += 1) {
        if (body[j] != '"') continue;
        j += 1;
        const start = j;
        while (j < body.len and body[j] != '"') : (j += 1) {}
        if (j >= body.len) break;
        const entry = body[start..j];
        if (std.mem.eql(u8, entry, "build.zig") or std.mem.eql(u8, entry, "build.zig.zon")) continue;

        if (std.mem.endsWith(u8, entry, ".zig")) {
            const is_nested = std.mem.indexOfScalar(u8, entry, '/') != null or std.mem.indexOfScalar(u8, entry, '\\') != null;
            if (best == null or !is_nested) {
                if (best) |b| gpa.free(b);
                best = try existingFile(gpa, io, pkg_dir, entry);
                if (best != null and !is_nested) return best;
            }
            continue;
        }

        // Directory entries in `.paths` (e.g. `"src"`) — try common roots.
        if (entry.len > 0 and !std.mem.eql(u8, entry, "")) {
            for ([_][]const u8{ "root.zig", "main.zig", "lib.zig" }) |leaf| {
                const rel = try std.fs.path.join(gpa, &.{ entry, leaf });
                defer gpa.free(rel);
                if (try existingFile(gpa, io, pkg_dir, rel)) |p| {
                    if (best) |b| gpa.free(b);
                    return p;
                }
            }
        }
    }
    return best;
}

fn existingFile(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, rel: []const u8) !?[]u8 {
    const full = try std.fs.path.resolve(gpa, &.{ dir, rel });
    errdefer gpa.free(full);
    if (!fileExists(io, full)) {
        gpa.free(full);
        return null;
    }
    return full;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// Returns `[:0]u8`, not `[]u8`: `std.zig.readSourceFileToEndAlloc`
/// allocates one extra sentinel byte beyond `.len`, which `Allocator.free`
/// only accounts for when the slice's *type* still carries the `:0` —
/// silently widening to `[]u8` here would make every `gpa.free(source)`
/// at a call site free one byte less than was actually allocated
/// (harmless in release modes, a hard `DebugAllocator` corruption error
/// in debug/test builds).
fn readFileAlloc(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var file_reader: std.Io.File.Reader = .init(file, io, &read_buf);
    return try std.zig.readSourceFileToEndAlloc(gpa, &file_reader);
}

const testing = std.testing;

test "parseDependencies finds path and hash entries" {
    const gpa = testing.allocator;
    const source =
        \\.{
        \\    .name = .demo,
        \\    .dependencies = .{
        \\        .foo = .{
        \\            .path = "vendor/foo",
        \\        },
        \\        .bar = .{
        \\            .url = "https://example.com/bar.tar.gz",
        \\            .hash = "1220aabb",
        \\        },
        \\        .baz = .{ .path = "../baz" },
        \\    },
        \\}
    ;
    const deps = try parseDependencies(gpa, source);
    defer {
        for (deps) |d| {
            gpa.free(d.name);
            if (d.rel_path) |p| gpa.free(p);
            if (d.hash) |h| gpa.free(h);
        }
        gpa.free(deps);
    }
    try testing.expectEqual(@as(usize, 3), deps.len);
    try testing.expectEqualStrings("foo", deps[0].name);
    try testing.expectEqualStrings("vendor/foo", deps[0].rel_path.?);
    try testing.expect(deps[0].hash == null);
    try testing.expectEqualStrings("bar", deps[1].name);
    try testing.expectEqualStrings("1220aabb", deps[1].hash.?);
    try testing.expect(deps[1].rel_path == null);
    try testing.expectEqualStrings("baz", deps[2].name);
}

test "namesLooselyEqual treats dash and underscore as equal" {
    try testing.expect(namesLooselyEqual("known_folders", "known-folders"));
    try testing.expect(!namesLooselyEqual("foo", "bar"));
}

test "parseAddModuleRoots finds a purely-local addModule with no zon dependency" {
    const gpa = testing.allocator;
    const source =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const doc_comment_mod = b.addModule("doc_comment", .{
        \\        .root_source_file = b.path("src/doc_comment.zig"),
        \\    });
        \\    _ = doc_comment_mod;
        \\}
    ;
    const roots = try parseAddModuleRoots(gpa, source);
    defer {
        for (roots) |r| {
            gpa.free(r.name);
            gpa.free(r.rel_path);
        }
        gpa.free(roots);
    }

    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqualStrings("doc_comment", roots[0].name);
    try testing.expectEqualStrings("src/doc_comment.zig", roots[0].rel_path);
}

test "parseAddModuleRoots ignores an addModule call with no root_source_file" {
    const gpa = testing.allocator;
    const source =
        \\pub fn build(b: *std.Build) void {
        \\    _ = b.addModule("late_bound", .{});
        \\}
    ;
    const roots = try parseAddModuleRoots(gpa, source);
    defer gpa.free(roots);
    try testing.expectEqual(@as(usize, 0), roots.len);
}

test "loadDepsFromWorkspace registers a build.zig-only addModule even with no build.zig.zon" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "src", .default_dir);
    (tmp.dir.createFile(testing.io, "src/doc_comment.zig", .{}) catch unreachable).close(testing.io);

    {
        var f = try tmp.dir.createFile(testing.io, "build.zig", .{});
        defer f.close(testing.io);
        var buf: [256]u8 = undefined;
        var writer = f.writer(testing.io, &buf);
        try writer.interface.writeAll(
            \\pub fn build(b: *std.Build) void {
            \\    _ = b.addModule("doc_comment", .{
            \\        .root_source_file = b.path("src/doc_comment.zig"),
            \\    });
            \\}
        );
        try writer.interface.flush();
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &path_buf);
    const abs_dir = path_buf[0..len];

    var packages: PackageMap = .empty;
    defer clearPackagesAndDeinit(gpa, &packages);
    try loadDepsFromWorkspace(gpa, testing.io, abs_dir, null, &packages);

    const root_uri = packages.get("doc_comment").?;
    try testing.expect(std.mem.endsWith(u8, root_uri, "src/doc_comment.zig"));
}

fn clearPackagesAndDeinit(gpa: std.mem.Allocator, map: *PackageMap) void {
    clearPackages(gpa, map);
    map.deinit(gpa);
}
