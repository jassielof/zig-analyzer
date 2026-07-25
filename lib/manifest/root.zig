//! Documentation for `build.zig.zon` manifest fields.
//!
//! `build.zig.zon.md` is vendored directly from
//! <https://codeberg.org/ziglang/zig/raw/tag/0.16.0/doc/build.zig.zon.md> (run
//! `zig build update-manifest-docs` to refresh it for a new Zig version) - it's already plain
//! Markdown, so unlike the Language Reference no conversion step is needed. Field docs are
//! parsed out of its `###`/`####` headings once, lazily, at runtime.
const std = @import("std");
const builtin = @import("builtin");
const build_zig_zon = @import("build_zig_zon");

const manifest_md = @embedFile("build.zig.zon.md");

const ParsedDocs = struct {
    top_level: std.StringHashMapUnmanaged([]const u8),
    dependency_field: std.StringHashMapUnmanaged([]const u8),
};

/// A `### `name`` or `#### `name`` heading's backtick-quoted field name, or `null` if the
/// heading text isn't of that form (e.g. `## Top-Level Fields`).
fn extractBacktickName(heading_text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, heading_text, &std.ascii.whitespace);
    if (trimmed.len < 2 or trimmed[0] != '`') return null;
    const end = std.mem.indexOfScalarPos(u8, trimmed, 1, '`') orelse return null;
    return trimmed[1..end];
}

fn parseManifestDocs(allocator: std.mem.Allocator, markdown: []const u8) error{OutOfMemory}!ParsedDocs {
    const Heading = struct { level: u8, name: []const u8, line_start: usize, body_start: usize };

    var headings: std.ArrayList(Heading) = .empty;
    defer headings.deinit(allocator);

    var offset: usize = 0;
    while (offset < markdown.len) {
        const line_end = std.mem.indexOfScalarPos(u8, markdown, offset, '\n') orelse markdown.len;
        const line = markdown[offset..line_end];

        var level: u8 = 0;
        while (level < line.len and line[level] == '#') level += 1;
        // Only `###`/`####` headings carry field docs; `#`/`##` are document structure.
        if ((level == 3 or level == 4) and level < line.len and line[level] == ' ') {
            if (extractBacktickName(line[level + 1 ..])) |name| {
                try headings.append(allocator, .{
                    .level = level,
                    .name = name,
                    .line_start = offset,
                    .body_start = @min(line_end + 1, markdown.len),
                });
            }
        }

        offset = if (line_end == markdown.len) markdown.len else line_end + 1;
    }

    var top_level: std.StringHashMapUnmanaged([]const u8) = .empty;
    errdefer top_level.deinit(allocator);
    var dependency_field: std.StringHashMapUnmanaged([]const u8) = .empty;
    errdefer dependency_field.deinit(allocator);

    // `####` headings only carry per-dependency-field docs (`url`/`hash`/`path`/`lazy`) when
    // nested under the top-level `### `dependencies`` section.
    var current_top: []const u8 = "";
    for (headings.items, 0..) |heading, i| {
        const body_end = if (i + 1 < headings.items.len) headings.items[i + 1].line_start else markdown.len;
        const body = std.mem.trim(u8, markdown[heading.body_start..body_end], &std.ascii.whitespace);

        switch (heading.level) {
            3 => {
                try top_level.put(allocator, heading.name, body);
                current_top = heading.name;
            },
            4 => if (std.mem.eql(u8, current_top, "dependencies")) {
                try dependency_field.put(allocator, heading.name, body);
            },
            else => unreachable,
        }
    }

    return .{ .top_level = top_level, .dependency_field = dependency_field };
}

var init_mutex: std.atomic.Mutex = .unlocked;
var parsed: ?ParsedDocs = null;

fn ensureParsed() *const ParsedDocs {
    while (!init_mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
    defer init_mutex.unlock();

    if (parsed == null) {
        parsed = parseManifestDocs(std.heap.smp_allocator, manifest_md) catch @panic("failed to parse embedded build.zig.zon.md");
    }
    return &parsed.?;
}

/// Doc text for a top-level `build.zig.zon` field (`name`, `fingerprint`, `version`,
/// `minimum_zig_version`, `dependencies`, `paths`).
pub fn getTopLevel(field_name: []const u8) ?[]const u8 {
    return ensureParsed().top_level.get(field_name);
}

/// Doc text for a field nested under an individual `dependencies.*` entry (`url`, `hash`,
/// `path`, `lazy`).
pub fn getDependencyField(field_name: []const u8) ?[]const u8 {
    return ensureParsed().dependency_field.get(field_name);
}

test "compiling Zig version matches build.zig.zon's pinned minimum_zig_version" {
    if (!std.mem.eql(u8, build_zig_zon.minimum_zig_version, builtin.zig_version_string)) {
        std.debug.print(
            "lib/manifest/build.zig.zon.md is vendored for Zig {s} (build.zig.zon's minimum_zig_version), but this build is using Zig {s}. Bump minimum_zig_version and run `zig build update-manifest-docs`.\n",
            .{ build_zig_zon.minimum_zig_version, builtin.zig_version_string },
        );
        return error.VendoredManifestDocsStale;
    }
}

test "parses known top-level and dependency fields" {
    try std.testing.expect(getTopLevel("name") != null);
    try std.testing.expect(getTopLevel("dependencies") != null);
    try std.testing.expect(getTopLevel("paths") != null);
    try std.testing.expect(getDependencyField("path") != null);
    try std.testing.expect(getDependencyField("url") != null);
    try std.testing.expect(getTopLevel("not_a_real_field") == null);
}
