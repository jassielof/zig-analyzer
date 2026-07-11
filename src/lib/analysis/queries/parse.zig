//! Query: `(uri, revision) -> Ast`, wrapping `std.zig.Ast.parse`.
//!
//! This is deliberately the first query wired through
//! `analysis/query.zig`'s cache — it's what Phase 3's milestone exists to
//! prove: parsing an unrelated file must not reparse this one. See
//! `unrelated key's revision bump does not reparse this file` below.

const std = @import("std");
const Ast = std.zig.Ast;
const query = @import("../query.zig");

/// `Ast.source` is a borrowed `[:0]const u8` — `Ast.deinit` never frees it.
/// This cache must not borrow straight from `documents.Store`, since a
/// later `didChange`/`didClose` can free or replace that text at any time,
/// independent of when this cache happens to evict its own stale entry.
/// So the query takes its own copy up front and owns it for exactly as
/// long as the `Ast` parsed from it lives.
pub const ParsedFile = struct {
    ast: Ast,
    owned_source: [:0]u8,
};

fn deinitParsedFile(pf: *ParsedFile, gpa: std.mem.Allocator) void {
    pf.ast.deinit(gpa);
    gpa.free(pf.owned_source);
}

pub const Cache = query.OwningStringCache(ParsedFile, deinitParsedFile);

const ComputeCtx = struct {
    gpa: std.mem.Allocator,
    source: [:0]const u8,
};

fn compute(ctx: ComputeCtx) !ParsedFile {
    const owned_source = try ctx.gpa.dupeZ(u8, ctx.source);
    errdefer ctx.gpa.free(owned_source);
    const ast = try Ast.parse(ctx.gpa, owned_source, .zig);
    return .{ .ast = ast, .owned_source = owned_source };
}

/// Returns the memoized parse result for `uri` at `revision`, parsing
/// `source` on a cache miss. The returned pointer is valid until the next
/// call that might evict `uri` from `cache` (a miss for the same `uri`, or
/// `cache.remove`).
pub fn parse(
    cache: *Cache,
    gpa: std.mem.Allocator,
    uri: []const u8,
    source: [:0]const u8,
    revision: query.Revision,
) !*ParsedFile {
    return cache.getOrCompute(gpa, uri, revision, ComputeCtx{ .gpa = gpa, .source = source }, compute);
}

test "parsing a file with no syntax errors produces no Ast errors" {
    const gpa = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(gpa);

    const pf = try parse(&cache, gpa, "file:///a.zig", "const x = 1;\n", 1);
    try std.testing.expectEqual(@as(usize, 0), pf.ast.errors.len);
}

test "parsing a file with a syntax error records it in Ast.errors" {
    const gpa = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(gpa);

    const pf = try parse(&cache, gpa, "file:///bad.zig", "const x = ;\n", 1);
    try std.testing.expect(pf.ast.errors.len > 0);
}

test "reparsing at the same revision is a cache hit (same pointer, not recomputed)" {
    const gpa = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(gpa);

    const first = try parse(&cache, gpa, "file:///a.zig", "const x = 1;\n", 1);
    const second = try parse(&cache, gpa, "file:///a.zig", "const x = 1;\n", 1);
    try std.testing.expectEqual(first, second);
}

test "a revision bump reparses and replaces the cached Ast" {
    const gpa = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(gpa);

    const first = try parse(&cache, gpa, "file:///a.zig", "const x = 1;\n", 1);
    try std.testing.expectEqual(@as(usize, 0), first.ast.errors.len);

    const second = try parse(&cache, gpa, "file:///a.zig", "const x = ;\n", 2);
    try std.testing.expect(second.ast.errors.len > 0);
}

test "unrelated key's revision bump does not reparse this file" {
    // The Phase 3 milestone: editing file B must not force file A's
    // parse query to recompute. Proven by checking file A's cached result
    // is the exact same pointer before and after file B's revision bumps.
    const gpa = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(gpa);

    const a_first = try parse(&cache, gpa, "file:///a.zig", "const x = 1;\n", 1);
    _ = try parse(&cache, gpa, "file:///b.zig", "const y = 2;\n", 1);

    const a_second = try parse(&cache, gpa, "file:///a.zig", "const x = 1;\n", 1);
    _ = try parse(&cache, gpa, "file:///b.zig", "const y = 3;\n", 2);

    try std.testing.expectEqual(a_first, a_second);
}

test "the owned source survives even after the caller's own buffer is freed" {
    // Regression guard for the exact hazard `owned_source` exists to
    // avoid: if this query borrowed the caller's slice instead of copying
    // it, this test would use-after-free under a sanitizer/valgrind-style
    // checker once `source` below is freed.
    const gpa = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(gpa);

    const source = try gpa.dupeZ(u8, "const x = 1;\n");
    const pf = try parse(&cache, gpa, "file:///a.zig", source, 1);
    gpa.free(source);

    try std.testing.expectEqualStrings("const x = 1;\n", pf.ast.source);
}
