//! In-memory document store: `uri -> (text, revision)`. This is the hook
//! the query cache (`analysis/query.zig`) keys off of — every `didChange`
//! bumps the affected URI's revision, and nothing else's.
//!
//! Full-document sync only for now (see project plan §Phase 2); incremental
//! sync is a later-phase upgrade once the query layer is proven.

const std = @import("std");
const query = @import("analysis/query.zig");

pub const Document = struct {
    /// Owned, null-terminated copy of the full document text.
    /// Null-terminated because `std.zig.Ast.parse` (and the rest of the
    /// `std.zig` tokenizer/parser ecosystem) requires `[:0]const u8`.
    text: [:0]u8,
    revision: query.Revision,
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    revisions: query.RevisionCounter = .{},
    documents: std.StringHashMapUnmanaged(Document) = .empty,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Store) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.text);
        }
        self.documents.deinit(self.gpa);
        self.* = undefined;
    }

    /// `textDocument/didOpen`. Copies `uri` and `text`; the caller retains
    /// ownership of both. Bumps the URI to a fresh revision.
    pub fn open(self: *Store, uri: []const u8, text: []const u8) !void {
        const owned_text = try self.gpa.dupeZ(u8, text);
        errdefer self.gpa.free(owned_text);
        const revision = self.revisions.bump();

        const gop = try self.documents.getOrPut(self.gpa, uri);
        if (gop.found_existing) {
            self.gpa.free(gop.value_ptr.text);
        } else {
            gop.key_ptr.* = try self.gpa.dupe(u8, uri);
        }
        gop.value_ptr.* = .{ .text = owned_text, .revision = revision };
    }

    /// `textDocument/didChange` under full-document sync: replaces the
    /// entire text and bumps this URI's revision. Every other URI's
    /// revision is untouched — that's the whole point.
    pub fn change(self: *Store, uri: []const u8, text: []const u8) !void {
        const entry = self.documents.getPtr(uri) orelse return error.UnknownDocument;
        const owned_text = try self.gpa.dupeZ(u8, text);
        self.gpa.free(entry.text);
        entry.text = owned_text;
        entry.revision = self.revisions.bump();
    }

    /// `textDocument/didClose`. Silently does nothing if `uri` isn't
    /// tracked (a client sending an out-of-order close is a client bug,
    /// not something worth surfacing as a server error).
    pub fn close(self: *Store, uri: []const u8) void {
        if (self.documents.fetchRemove(uri)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value.text);
        }
    }

    pub fn get(self: *const Store, uri: []const u8) ?Document {
        return self.documents.get(uri);
    }
};

test "open then get returns the tracked text and a revision" {
    const gpa = std.testing.allocator;
    var store: Store = .init(gpa);
    defer store.deinit();

    try store.open("file:///a.zig", "const x = 1;");

    const doc = store.get("file:///a.zig").?;
    try std.testing.expectEqualStrings("const x = 1;", doc.text);
    try std.testing.expectEqual(@as(query.Revision, 1), doc.revision);
}

test "change replaces text and bumps only that URI's revision" {
    const gpa = std.testing.allocator;
    var store: Store = .init(gpa);
    defer store.deinit();

    try store.open("file:///a.zig", "const x = 1;");
    try store.open("file:///b.zig", "const y = 2;");

    const a_before = store.get("file:///a.zig").?.revision;
    const b_before = store.get("file:///b.zig").?.revision;

    try store.change("file:///a.zig", "const x = 2;");

    const a_after = store.get("file:///a.zig").?;
    const b_after = store.get("file:///b.zig").?;

    try std.testing.expectEqualStrings("const x = 2;", a_after.text);
    try std.testing.expect(a_after.revision != a_before);
    try std.testing.expectEqual(b_before, b_after.revision);
}

test "change on an unknown URI errors" {
    const gpa = std.testing.allocator;
    var store: Store = .init(gpa);
    defer store.deinit();

    try std.testing.expectError(error.UnknownDocument, store.change("file:///missing.zig", "x"));
}

test "close stops tracking the document" {
    const gpa = std.testing.allocator;
    var store: Store = .init(gpa);
    defer store.deinit();

    try store.open("file:///a.zig", "const x = 1;");
    store.close("file:///a.zig");

    try std.testing.expectEqual(@as(?Document, null), store.get("file:///a.zig"));
}

test "close on an unknown URI is a no-op" {
    const gpa = std.testing.allocator;
    var store: Store = .init(gpa);
    defer store.deinit();

    store.close("file:///never-opened.zig");
}

test "reopening a still-open URI replaces text without leaking" {
    const gpa = std.testing.allocator;
    var store: Store = .init(gpa);
    defer store.deinit();

    try store.open("file:///a.zig", "first");
    try store.open("file:///a.zig", "second");

    try std.testing.expectEqualStrings("second", store.get("file:///a.zig").?.text);
}
