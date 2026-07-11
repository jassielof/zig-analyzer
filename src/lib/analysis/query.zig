//! Generic memoized-query mechanism.
//!
//! Every analysis pass (parse, item-tree, resolve, ...) is a pure function
//! wrapped in a `Cache(Key, Value, Context)`. On edit, callers bump a file's
//! revision and mark it possibly-stale; nothing recomputes until a query is
//! actually requested, and even then a query short-circuits if its cached
//! entry's revision already matches the current revision (red-green check).
//!
//! This module intentionally has no knowledge of `Ast`, URIs, or any other
//! concrete analysis type — those live in `queries/*.zig` and build on top
//! of this.

const std = @import("std");

/// Monotonically increasing revision counter. There is one global counter;
/// individual inputs (e.g. a file's text) record the revision at which they
/// last changed, and cache entries record the revision at which they were
/// last computed. A query is stale if its recorded revision is behind the
/// revision of any input it depends on.
pub const Revision = u64;

pub const RevisionCounter = struct {
    current: Revision = 0,

    /// Advance to a new revision and return it. Called once per edit that
    /// invalidates some input (e.g. a `didChange` for a given URI).
    pub fn bump(self: *RevisionCounter) Revision {
        self.current += 1;
        return self.current;
    }
};

/// A memoized cache from `Key` to `Value`, keyed additionally on the
/// revision at which the value was computed.
///
/// This is the "trivial hashmap + revision counter" version: a cache hit
/// requires the stored revision to exactly match the revision passed to
/// `getOrCompute`. Later phases (once queries have real, per-input
/// dependency edges) can refine this into a true red-green check that
/// re-verifies dependencies instead of blanket-invalidating on any bump —
/// but every query is written against this interface from the start so
/// that refinement doesn't require touching call sites.
pub fn Cache(comptime Key: type, comptime Value: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            value: Value,
            revision: Revision,
        };

        const Map = std.HashMapUnmanaged(Key, Entry, Context, std.hash_map.default_max_load_percentage);

        map: Map = .empty,

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.map.deinit(gpa);
        }

        /// Return the cached value for `key` if it was computed at exactly
        /// `revision`, without invoking `compute`.
        pub fn peek(self: *const Self, key: Key, revision: Revision) ?Value {
            const entry = self.map.get(key) orelse return null;
            if (entry.revision != revision) return null;
            return entry.value;
        }

        /// Return the cached value for `key` if still fresh at `revision`;
        /// otherwise call `compute(ctx)`, store the result under
        /// `revision`, and return it.
        ///
        /// `compute` must be a function (or closure-like struct method)
        /// producing `Value`; it is only invoked on a cache miss.
        pub fn getOrCompute(
            self: *Self,
            gpa: std.mem.Allocator,
            key: Key,
            revision: Revision,
            ctx: anytype,
            comptime compute: fn (@TypeOf(ctx)) Value,
        ) !Value {
            if (self.peek(key, revision)) |cached| return cached;
            const value = compute(ctx);
            try self.map.put(gpa, key, .{ .value = value, .revision = revision });
            return value;
        }

        /// Drop the cached entry for `key`, if any. A future `getOrCompute`
        /// will recompute unconditionally.
        pub fn invalidate(self: *Self, key: Key) void {
            _ = self.map.remove(key);
        }

        pub fn count(self: *const Self) usize {
            return self.map.count();
        }
    };
}

/// Convenience alias for the common case of a `[]const u8` key (e.g. a
/// document URI).
pub fn StringKeyedCache(comptime Value: type) type {
    return Cache([]const u8, Value, std.hash_map.StringContext);
}

/// A cache variant for queries whose `Value` owns resources needing
/// explicit cleanup (e.g. `std.zig.Ast`, which must be `.deinit(gpa)`'d)
/// rather than the trivial by-value `Cache` above. Also duplicates the key
/// on insert, since callers typically pass a URI borrowed from
/// `documents.Store`, which can free its own copy (on `didClose`)
/// independently of this cache's lifetime.
///
/// `deinitValue` is called on a stale entry's old value right before it's
/// replaced, and on every remaining entry when the cache itself is
/// deinitialized.
pub fn OwningStringCache(comptime Value: type, comptime deinitValue: fn (*Value, std.mem.Allocator) void) type {
    return struct {
        const Self = @This();

        const Entry = struct {
            value: Value,
            revision: Revision,
        };

        map: std.StringHashMapUnmanaged(Entry) = .empty,

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            var it = self.map.iterator();
            while (it.next()) |entry| {
                gpa.free(entry.key_ptr.*);
                deinitValue(&entry.value_ptr.value, gpa);
            }
            self.map.deinit(gpa);
            self.* = undefined;
        }

        /// Returns a pointer to the cached value if it was computed at
        /// exactly `revision`. The pointer is valid until the next call
        /// that might evict `key` (a miss in `getOrCompute`, or `remove`).
        pub fn peek(self: *Self, key: []const u8, revision: Revision) ?*Value {
            const entry = self.map.getPtr(key) orelse return null;
            if (entry.revision != revision) return null;
            return &entry.value;
        }

        /// Return a pointer to the cached value for `key` if still fresh
        /// at `revision`; otherwise call `compute(ctx)`, deinit and
        /// replace any stale value under `key`, and return a pointer to
        /// the new one.
        pub fn getOrCompute(
            self: *Self,
            gpa: std.mem.Allocator,
            key: []const u8,
            revision: Revision,
            ctx: anytype,
            comptime compute: fn (@TypeOf(ctx)) anyerror!Value,
        ) !*Value {
            if (self.peek(key, revision)) |cached| return cached;

            var value = try compute(ctx);
            errdefer deinitValue(&value, gpa);

            const gop = try self.map.getOrPut(gpa, key);
            if (gop.found_existing) {
                deinitValue(&gop.value_ptr.value, gpa);
            } else {
                gop.key_ptr.* = try gpa.dupe(u8, key);
            }
            gop.value_ptr.* = .{ .value = value, .revision = revision };
            return &gop.value_ptr.value;
        }

        /// Drop and deinit the cached entry for `key`, if any (e.g. on
        /// `textDocument/didClose`).
        pub fn remove(self: *Self, gpa: std.mem.Allocator, key: []const u8) void {
            if (self.map.fetchRemove(key)) |kv| {
                gpa.free(kv.key);
                var v = kv.value;
                deinitValue(&v.value, gpa);
            }
        }

        pub fn count(self: *const Self) usize {
            return self.map.count();
        }
    };
}

test "getOrCompute misses then hits at the same revision" {
    const gpa = std.testing.allocator;

    var calls: usize = 0;
    const Ctx = struct { calls: *usize };

    var cache: Cache(u32, u32, std.hash_map.AutoContext(u32)) = .{};
    defer cache.deinit(gpa);

    const compute = struct {
        fn run(ctx: Ctx) u32 {
            ctx.calls.* += 1;
            return 42;
        }
    }.run;

    const a = try cache.getOrCompute(gpa, 1, 5, Ctx{ .calls = &calls }, compute);
    const b = try cache.getOrCompute(gpa, 1, 5, Ctx{ .calls = &calls }, compute);

    try std.testing.expectEqual(@as(u32, 42), a);
    try std.testing.expectEqual(@as(u32, 42), b);
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "getOrCompute recomputes once the revision advances" {
    const gpa = std.testing.allocator;

    var calls: usize = 0;
    const Ctx = struct { calls: *usize };

    var cache: Cache(u32, u32, std.hash_map.AutoContext(u32)) = .{};
    defer cache.deinit(gpa);

    const compute = struct {
        fn run(ctx: Ctx) u32 {
            ctx.calls.* += 1;
            return 42;
        }
    }.run;

    _ = try cache.getOrCompute(gpa, 1, 5, Ctx{ .calls = &calls }, compute);
    _ = try cache.getOrCompute(gpa, 1, 6, Ctx{ .calls = &calls }, compute);

    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "unrelated key's revision bump does not invalidate this key's cache entry" {
    // This is the property the whole incremental design depends on: editing
    // file B must not force file A's cached query to recompute. Modeled
    // here with two independent keys sharing one cache.
    const gpa = std.testing.allocator;

    var calls_a: usize = 0;
    var calls_b: usize = 0;
    const Ctx = struct { calls: *usize };

    var cache: StringKeyedCache(u32) = .{};
    defer cache.deinit(gpa);

    const compute = struct {
        fn run(ctx: Ctx) u32 {
            ctx.calls.* += 1;
            return 1;
        }
    }.run;

    // Both files computed at revision 1.
    _ = try cache.getOrCompute(gpa, "file_a.zig", 1, Ctx{ .calls = &calls_a }, compute);
    _ = try cache.getOrCompute(gpa, "file_b.zig", 1, Ctx{ .calls = &calls_b }, compute);

    // file_b.zig changes; only its revision advances to 2. file_a.zig is
    // still queried at revision 1 and must hit the cache.
    _ = try cache.getOrCompute(gpa, "file_a.zig", 1, Ctx{ .calls = &calls_a }, compute);
    _ = try cache.getOrCompute(gpa, "file_b.zig", 2, Ctx{ .calls = &calls_b }, compute);

    try std.testing.expectEqual(@as(usize, 1), calls_a);
    try std.testing.expectEqual(@as(usize, 2), calls_b);
}

test "invalidate forces a recompute on next access" {
    const gpa = std.testing.allocator;

    var calls: usize = 0;
    const Ctx = struct { calls: *usize };

    var cache: Cache(u32, u32, std.hash_map.AutoContext(u32)) = .{};
    defer cache.deinit(gpa);

    const compute = struct {
        fn run(ctx: Ctx) u32 {
            ctx.calls.* += 1;
            return 42;
        }
    }.run;

    _ = try cache.getOrCompute(gpa, 1, 5, Ctx{ .calls = &calls }, compute);
    cache.invalidate(1);
    _ = try cache.getOrCompute(gpa, 1, 5, Ctx{ .calls = &calls }, compute);

    try std.testing.expectEqual(@as(usize, 2), calls);
}

const OwnedResource = struct {
    payload: []u8,
    live: *usize,

    fn deinit(self: *OwnedResource, gpa: std.mem.Allocator) void {
        gpa.free(self.payload);
        self.live.* -= 1;
    }
};

test "OwningStringCache: recompute on revision bump deinits the stale value" {
    const gpa = std.testing.allocator;
    var live: usize = 0;
    const Ctx = struct { gpa: std.mem.Allocator, live: *usize };

    var cache: OwningStringCache(OwnedResource, OwnedResource.deinit) = .{};
    defer cache.deinit(gpa);

    const compute = struct {
        fn run(ctx: Ctx) !OwnedResource {
            ctx.live.* += 1;
            return .{ .payload = try ctx.gpa.dupe(u8, "hello"), .live = ctx.live };
        }
    }.run;

    _ = try cache.getOrCompute(gpa, "a.zig", 1, Ctx{ .gpa = gpa, .live = &live }, compute);
    try std.testing.expectEqual(@as(usize, 1), live);

    // Revision bump: old value must be deinitialized, not merely dropped.
    _ = try cache.getOrCompute(gpa, "a.zig", 2, Ctx{ .gpa = gpa, .live = &live }, compute);
    try std.testing.expectEqual(@as(usize, 1), live);
}

test "OwningStringCache: unrelated key's revision bump does not recompute this key" {
    const gpa = std.testing.allocator;
    var live: usize = 0;
    var calls_a: usize = 0;
    var calls_b: usize = 0;
    const Ctx = struct { gpa: std.mem.Allocator, live: *usize, calls: *usize };

    var cache: OwningStringCache(OwnedResource, OwnedResource.deinit) = .{};
    defer cache.deinit(gpa);

    const compute = struct {
        fn run(ctx: Ctx) !OwnedResource {
            ctx.calls.* += 1;
            ctx.live.* += 1;
            return .{ .payload = try ctx.gpa.dupe(u8, "x"), .live = ctx.live };
        }
    }.run;

    _ = try cache.getOrCompute(gpa, "a.zig", 1, Ctx{ .gpa = gpa, .live = &live, .calls = &calls_a }, compute);
    _ = try cache.getOrCompute(gpa, "b.zig", 1, Ctx{ .gpa = gpa, .live = &live, .calls = &calls_b }, compute);

    _ = try cache.getOrCompute(gpa, "a.zig", 1, Ctx{ .gpa = gpa, .live = &live, .calls = &calls_a }, compute);
    _ = try cache.getOrCompute(gpa, "b.zig", 2, Ctx{ .gpa = gpa, .live = &live, .calls = &calls_b }, compute);

    try std.testing.expectEqual(@as(usize, 1), calls_a);
    try std.testing.expectEqual(@as(usize, 2), calls_b);
}

test "OwningStringCache: remove deinits and drops the entry" {
    const gpa = std.testing.allocator;
    var live: usize = 0;
    const Ctx = struct { gpa: std.mem.Allocator, live: *usize };

    var cache: OwningStringCache(OwnedResource, OwnedResource.deinit) = .{};
    defer cache.deinit(gpa);

    const compute = struct {
        fn run(ctx: Ctx) !OwnedResource {
            ctx.live.* += 1;
            return .{ .payload = try ctx.gpa.dupe(u8, "x"), .live = ctx.live };
        }
    }.run;

    _ = try cache.getOrCompute(gpa, "a.zig", 1, Ctx{ .gpa = gpa, .live = &live }, compute);
    try std.testing.expectEqual(@as(usize, 1), live);

    cache.remove(gpa, "a.zig");
    try std.testing.expectEqual(@as(usize, 0), live);
    try std.testing.expectEqual(@as(?*OwnedResource, null), cache.peek("a.zig", 1));
}

test "OwningStringCache: deinit releases every remaining entry" {
    const gpa = std.testing.allocator;
    var live: usize = 0;
    const Ctx = struct { gpa: std.mem.Allocator, live: *usize };

    var cache: OwningStringCache(OwnedResource, OwnedResource.deinit) = .{};

    const compute = struct {
        fn run(ctx: Ctx) !OwnedResource {
            ctx.live.* += 1;
            return .{ .payload = try ctx.gpa.dupe(u8, "x"), .live = ctx.live };
        }
    }.run;

    _ = try cache.getOrCompute(gpa, "a.zig", 1, Ctx{ .gpa = gpa, .live = &live }, compute);
    _ = try cache.getOrCompute(gpa, "b.zig", 1, Ctx{ .gpa = gpa, .live = &live }, compute);
    try std.testing.expectEqual(@as(usize, 2), live);

    cache.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), live);
}
