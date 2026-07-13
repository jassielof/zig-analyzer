//! Minimal `file://` URI ↔ filesystem path conversion.
//!
//! Deliberately smaller than ZLS's `Uri.zig`: only what we need to open a
//! source file from an LSP URI (or build a URI for the local stdlib after
//! `zig env`). Percent-encoding is best-effort for common path characters;
//! Windows drive letters are lowercased to match VS Code's usual form.

const std = @import("std");
const builtin = @import("builtin");

/// Converts a filesystem path to a `file://` URI. Caller owns the result.
pub fn fromPath(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return fromPathWithOs(gpa, path, builtin.os.tag == .windows);
}

fn fromPathWithOs(gpa: std.mem.Allocator, path: []const u8, comptime is_windows: bool) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "file://");
    if (!(is_windows and path.len >= 2 and isSep(is_windows, path[0]) and isSep(is_windows, path[1]))) {
        // Non-UNC: ensure the authority-separator slash before the path.
        if (!std.mem.startsWith(u8, path, "/")) try buf.append(gpa, '/');
    }

    var value = path;
    if (is_windows and path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') {
        try buf.append(gpa, std.ascii.toLower(path[0]));
        value = value[1..];
    }

    for (value) |c| {
        if (is_windows and c == '\\') {
            try buf.append(gpa, '/');
            continue;
        }
        if (isPathChar(c)) {
            try buf.append(gpa, c);
        } else {
            try buf.print(gpa, "%{X:0>2}", .{c});
        }
    }
    return try buf.toOwnedSlice(gpa);
}

/// Converts a `file://` URI to a filesystem path. Caller owns the result.
pub fn toFsPath(gpa: std.mem.Allocator, uri: []const u8) ![]u8 {
    return toFsPathWithOs(gpa, uri, builtin.os.tag == .windows);
}

fn toFsPathWithOs(gpa: std.mem.Allocator, uri: []const u8, comptime is_windows: bool) ![]u8 {
    const parsed = std.Uri.parse(uri) catch return error.InvalidUri;
    if (!std.mem.eql(u8, parsed.scheme, "file")) return error.UnsupportedScheme;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    // Decode percent-encoding into `buf`.
    var path = parsed.path.percent_encoded;
    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '%' and i + 2 < path.len) {
            const hi = std.fmt.parseInt(u8, path[i + 1 .. i + 2], 16) catch {
                try buf.append(gpa, path[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.parseInt(u8, path[i + 2 .. i + 3], 16) catch {
                try buf.append(gpa, path[i]);
                i += 1;
                continue;
            };
            try buf.append(gpa, (hi << 4) | lo);
            i += 3;
            continue;
        }
        try buf.append(gpa, path[i]);
        i += 1;
    }

    if (is_windows) {
        // `file:///c:/foo` → path `/c:/foo` → strip leading slash before drive.
        // Keep forward slashes: Windows file APIs accept them, and this
        // matches the round-trip form `fromPath` produces.
        if (buf.items.len >= 3 and buf.items[0] == '/' and std.ascii.isAlphabetic(buf.items[1]) and buf.items[2] == ':') {
            const owned = try gpa.dupe(u8, buf.items[1..]);
            buf.deinit(gpa);
            return owned;
        }
    }

    return try buf.toOwnedSlice(gpa);
}

fn isSep(comptime is_windows: bool, c: u8) bool {
    return c == '/' or (is_windows and c == '\\');
}

fn isPathChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/', '@', ':' => true,
        else => false,
    };
}

const testing = std.testing;

test "fromPath (posix-style absolute)" {
    const uri = try fromPathWithOs(testing.allocator, "/home/main.zig", false);
    defer testing.allocator.free(uri);
    try testing.expectEqualStrings("file:///home/main.zig", uri);
}

test "fromPath (windows drive)" {
    const uri = try fromPathWithOs(testing.allocator, "C:\\Users\\x\\main.zig", true);
    defer testing.allocator.free(uri);
    try testing.expectEqualStrings("file:///c:/Users/x/main.zig", uri);
}

test "toFsPath (windows drive)" {
    const path = try toFsPathWithOs(testing.allocator, "file:///c:/Users/x/main.zig", true);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("c:/Users/x/main.zig", path);
}

test "toFsPath (posix)" {
    const path = try toFsPathWithOs(testing.allocator, "file:///home/main.zig", false);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/home/main.zig", path);
}
