//! Scripted edit sequences that assert *which* queries recomputed after
//! each step — not just that the final output is correct. This is what
//! proves the incremental design (project plan §1.2, §1.3) is real rather
//! than silently falling back to full reanalysis somewhere: every one of
//! these tests would still pass under a naive "reparse everything on every
//! request" implementation if it only checked outputs, so instead they
//! read `Cache.misses` — the number of times a query actually ran its
//! `compute` function — after each scripted step.
//!
//! An integration test against the public `zig_analyzer` module API (not
//! internal file paths), driving a real `Server` through the same
//! `protocol.harness` every other integration test uses — real framed
//! JSON-RPC messages, no shortcuts that call internal APIs the wire
//! protocol wouldn't actually exercise.

const std = @import("std");
const zig_analyzer = @import("zig_analyzer");
const Server = zig_analyzer.server.Server;
const harness = zig_analyzer.protocol.harness;

const testing = std.testing;

test "repeated requests against an unchanged file are cache hits, not recomputes" {
    const gpa = testing.allocator;
    var server: Server = .init(gpa);
    defer server.deinit();

    var r0 = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn helper() void {}\nfn main() void {\n    helper();\n}\n"}}}
    });
    defer r0.deinit();

    // didOpen's own publishDiagnostics pass is the one legitimate parse.
    // It never needs the item tree (diagnostics are Ast-only), so that
    // cache stays untouched until something actually asks for it.
    try testing.expectEqual(@as(usize, 1), server.parse_cache.misses);
    try testing.expectEqual(@as(usize, 0), server.item_tree_cache.misses);

    // Five different requests against the same, unedited file: every one
    // of these must be served from cache, except the very first one that
    // touches the item tree at all.
    var r1 = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///a.zig"},"position":{"line":2,"character":5}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.zig"},"position":{"line":2,"character":5}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///a.zig"}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///a.zig"},"position":{"line":0,"character":4}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.zig"},"position":{"line":0,"character":4}}}
    });
    defer r1.deinit();

    try testing.expectEqual(@as(usize, 1), server.parse_cache.misses);
    try testing.expectEqual(@as(usize, 1), server.item_tree_cache.misses);
}

test "editing file A recomputes only A, no matter how much unrelated activity happens around it" {
    const gpa = testing.allocator;
    var server: Server = .init(gpa);
    defer server.deinit();

    var r0 = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn helper() void {}\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///b.zig","text":"fn other() void {}\n"}}}
    });
    defer r0.deinit();

    // Two files opened: two parses. Neither's item tree has been
    // requested yet — didOpen's diagnostics pass doesn't need one.
    try testing.expectEqual(@as(usize, 2), server.parse_cache.misses);
    try testing.expectEqual(@as(usize, 0), server.item_tree_cache.misses);

    // A barrage of read-only requests against both files. None of these
    // should move the miss counters at all.
    var r1 = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///a.zig"},"position":{"line":0,"character":4}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///b.zig"}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.zig"},"position":{"line":0,"character":4}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///a.zig"}}}
    });
    defer r1.deinit();
    try testing.expectEqual(@as(usize, 2), server.parse_cache.misses);
    try testing.expectEqual(@as(usize, 2), server.item_tree_cache.misses);

    // Edit A three times, each time followed by a hover request (the
    // realistic editor pattern: edit, then ask for fresh info). Each
    // round must recompute A's parse (unconditionally, for diagnostics)
    // and item tree (once something actually asks for it) exactly once —
    // and must never move B's counters, which nothing here touches.
    for (0..3) |i| {
        // No `\n` here: in a regular (non-multiline) Zig string literal
        // `\n` is a real newline escape, which would embed a raw newline
        // byte into the JSON payload below — invalid JSON, silently
        // rejected as a parse error before ever reaching handleDidChange.
        // Zig doesn't require newlines between top-level decls, so this
        // sidesteps the whole escaping question instead of fighting it.
        const text = try std.fmt.allocPrint(gpa, "fn helper() void {{}} const edit_{d} = {d};", .{ i, i });
        defer gpa.free(text);
        const change = try std.fmt.allocPrint(
            gpa,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///a.zig\"}},\"contentChanges\":[{{\"text\":\"{s}\"}}]}}}}",
            .{text},
        );
        defer gpa.free(change);
        const hover = try std.fmt.allocPrint(
            gpa,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"textDocument/hover\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///a.zig\"}},\"position\":{{\"line\":0,\"character\":4}}}}}}",
            .{i},
        );
        defer gpa.free(hover);

        var r = try harness.run(gpa, &server, &.{ change, hover });
        defer r.deinit();

        try testing.expectEqual(@as(usize, 2 + i + 1), server.parse_cache.misses);
        try testing.expectEqual(@as(usize, 2 + i + 1), server.item_tree_cache.misses);
    }

    // B was never edited: still exactly its one original parse and
    // item-tree, even after three edits and four requests elsewhere.
    try testing.expectEqual(@as(usize, 5), server.parse_cache.misses);
    try testing.expectEqual(@as(usize, 5), server.item_tree_cache.misses);
}

test "closing and reopening a file recomputes even with byte-identical text" {
    // This is a deliberate non-optimization, not a bug: didClose evicts
    // the cache entry entirely, so reopening always recomputes even if
    // the text hasn't changed at all. Documented here as a scripted test
    // so a future change to that behavior (e.g. content-hash-based reuse
    // across close/reopen) is a conscious decision, not an accident this
    // suite silently stops noticing.
    const gpa = testing.allocator;
    var server: Server = .init(gpa);
    defer server.deinit();

    var r1 = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn f() void {}\n"}}}
    });
    defer r1.deinit();
    try testing.expectEqual(@as(usize, 1), server.parse_cache.misses);

    var r2 = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///a.zig"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn f() void {}\n"}}}
    });
    defer r2.deinit();
    try testing.expectEqual(@as(usize, 2), server.parse_cache.misses);
}
