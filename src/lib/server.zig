//! LSP lifecycle: `initialize` / `initialized` / `shutdown` / `exit`. This
//! is transport-agnostic — it only reads/writes JSON-RPC message bodies via
//! `protocol.jsonrpc`, so the same `Server` drives both the real stdio loop
//! (`cli/main.zig`) and the in-process test harness
//! (`protocol/harness.zig`).

const std = @import("std");
const Io = std.Io;
const jsonrpc = @import("protocol/jsonrpc.zig");
const documents = @import("documents.zig");
const parse = @import("analysis/queries/parse.zig");

/// Where the server is in the LSP lifecycle state machine (see the LSP spec's
/// "Basic JSON Structures" / lifecycle section). Method handling depends on
/// this: e.g. any request other than `initialize` sent while `.uninitialized`
/// must be rejected with `ServerNotInitialized`.
pub const Phase = enum {
    uninitialized,
    /// `initialize` request handled; waiting for the `initialized`
    /// notification.
    initializing,
    running,
    /// `shutdown` request handled; only `exit` should follow.
    shutdown_requested,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    phase: Phase = .uninitialized,
    should_exit: bool = false,
    /// Set once `should_exit` is set. Per spec: 0 if `shutdown` was
    /// requested first, 1 otherwise ("unexpected exit").
    exit_code: u8 = 0,
    documents: documents.Store,
    parse_cache: parse.Cache = .{},

    pub fn init(gpa: std.mem.Allocator) Server {
        return .{ .gpa = gpa, .documents = .init(gpa) };
    }

    pub fn deinit(self: *Server) void {
        self.documents.deinit();
        self.parse_cache.deinit(self.gpa);
    }

    /// Dispatches one JSON-RPC message body. Writes a framed response to
    /// `writer` for requests; notifications produce no response.
    pub fn handleMessage(self: *Server, writer: *Io.Writer, body: []const u8) !void {
        var parsed = jsonrpc.parse(self.gpa, body) catch {
            try jsonrpc.writeError(writer, self.gpa, .null, .parse_error, "invalid JSON-RPC message");
            return;
        };
        defer parsed.deinit();
        const msg = parsed.value;

        if (std.mem.eql(u8, msg.method, "initialize")) {
            try self.handleInitialize(writer, msg);
        } else if (std.mem.eql(u8, msg.method, "initialized")) {
            self.handleInitialized(msg);
        } else if (std.mem.eql(u8, msg.method, "shutdown")) {
            try self.handleShutdown(writer, msg);
        } else if (std.mem.eql(u8, msg.method, "exit")) {
            self.handleExit();
        } else if (std.mem.eql(u8, msg.method, "textDocument/didOpen")) {
            self.handleDidOpen(writer, msg) catch |err| std.log.err("textDocument/didOpen: {t}", .{err});
        } else if (std.mem.eql(u8, msg.method, "textDocument/didChange")) {
            self.handleDidChange(writer, msg) catch |err| std.log.err("textDocument/didChange: {t}", .{err});
        } else if (std.mem.eql(u8, msg.method, "textDocument/didClose")) {
            self.handleDidClose(writer, msg) catch |err| std.log.err("textDocument/didClose: {t}", .{err});
        } else if (msg.isNotification()) {
            // Unknown notifications are silently ignored, per spec.
        } else if (self.phase == .uninitialized) {
            try jsonrpc.writeError(writer, self.gpa, msg.id.?, .server_not_initialized, "server not initialized");
        } else {
            try jsonrpc.writeError(writer, self.gpa, msg.id.?, .method_not_found, msg.method);
        }
    }

    fn handleInitialize(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
        if (self.phase != .uninitialized) {
            try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_request, "server already initialized");
            return;
        }
        const InitializeResult = struct {
            capabilities: struct {
                // 1 == TextDocumentSyncKind.Full.
                textDocumentSync: u8 = 1,
            } = .{},
            serverInfo: struct {
                name: []const u8 = "zig-analyzer",
                version: []const u8 = "0.0.0",
            } = .{},
        };
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, InitializeResult{});
        self.phase = .initializing;
    }

    fn handleInitialized(self: *Server, msg: jsonrpc.Message) void {
        _ = msg;
        if (self.phase == .initializing) self.phase = .running;
    }

    fn handleShutdown(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
        if (self.phase == .uninitialized) {
            try jsonrpc.writeError(writer, self.gpa, msg.id.?, .server_not_initialized, "server not initialized");
            return;
        }
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
        self.phase = .shutdown_requested;
    }

    fn handleExit(self: *Server) void {
        self.exit_code = if (self.phase == .shutdown_requested) 0 else 1;
        self.should_exit = true;
    }

    fn handleDidOpen(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
        const Params = struct {
            textDocument: struct {
                uri: []const u8,
                text: []const u8,
            },
        };
        var parsed = try std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try self.documents.open(parsed.value.textDocument.uri, parsed.value.textDocument.text);
        try self.publishDiagnostics(writer, parsed.value.textDocument.uri);
    }

    fn handleDidChange(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
        const Params = struct {
            textDocument: struct {
                uri: []const u8,
            },
            // Full-document sync only: exactly one change with the whole
            // new text, no `range`/`rangeLength`.
            contentChanges: []const struct {
                text: []const u8,
            },
        };
        var parsed = try std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (parsed.value.contentChanges.len == 0) return;
        const text = parsed.value.contentChanges[parsed.value.contentChanges.len - 1].text;
        try self.documents.change(parsed.value.textDocument.uri, text);
        try self.publishDiagnostics(writer, parsed.value.textDocument.uri);
    }

    fn handleDidClose(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
        const Params = struct {
            textDocument: struct {
                uri: []const u8,
            },
        };
        var parsed = try std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const uri = parsed.value.textDocument.uri;
        self.documents.close(uri);
        self.parse_cache.remove(self.gpa, uri);
        // Clear any diagnostics the client is still showing for a file
        // that's no longer open.
        try jsonrpc.writeNotification(writer, self.gpa, "textDocument/publishDiagnostics", .{
            .uri = uri,
            .diagnostics = &[_]Diagnostic{},
        });
    }

    const Position = struct { line: u32, character: u32 };
    const Range = struct { start: Position, end: Position };
    const Diagnostic = struct {
        range: Range,
        severity: u8, // 1 = Error, 4 = Hint (used here for parser notes)
        source: []const u8 = "zig-analyzer",
        message: []const u8,
    };

    /// Reparses `uri` (a cache hit unless its text just changed) and
    /// publishes one `textDocument/publishDiagnostics` notification with
    /// its current syntax errors.
    fn publishDiagnostics(self: *Server, writer: *Io.Writer, uri: []const u8) !void {
        const doc = self.documents.get(uri) orelse return;
        const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
        const ast = parsed_file.ast;

        var diagnostics: std.ArrayList(Diagnostic) = .empty;
        defer {
            for (diagnostics.items) |d| self.gpa.free(d.message);
            diagnostics.deinit(self.gpa);
        }

        for (ast.errors) |err| {
            var message: Io.Writer.Allocating = .init(self.gpa);
            defer message.deinit();
            try ast.renderError(err, &message.writer);

            const loc = ast.tokenLocation(0, err.token);
            const pos: Position = .{ .line = @intCast(loc.line), .character = @intCast(loc.column) };

            try diagnostics.append(self.gpa, .{
                .range = .{ .start = pos, .end = pos },
                .severity = if (err.is_note) 4 else 1,
                .message = try self.gpa.dupe(u8, message.written()),
            });
        }

        try jsonrpc.writeNotification(writer, self.gpa, "textDocument/publishDiagnostics", .{
            .uri = uri,
            .diagnostics = diagnostics.items,
        });
    }
};

const harness = @import("protocol/harness.zig");

test "full handshake: initialize, initialized, shutdown, exit" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa);
    defer server.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
    });
    defer responses.deinit();

    try std.testing.expectEqual(@as(usize, 2), responses.messages.items.len);

    var initialize_result = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer initialize_result.deinit();
    try std.testing.expectEqual(@as(i64, 1), initialize_result.value.object.get("id").?.integer);
    try std.testing.expect(initialize_result.value.object.get("result").?.object.contains("capabilities"));

    var shutdown_result = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[1], .{});
    defer shutdown_result.deinit();
    try std.testing.expectEqual(@as(i64, 2), shutdown_result.value.object.get("id").?.integer);

    try std.testing.expect(server.should_exit);
    try std.testing.expectEqual(@as(u8, 0), server.exit_code);
}

test "exit without shutdown reports a non-zero exit code" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa);
    defer server.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
    });
    defer responses.deinit();

    try std.testing.expect(server.should_exit);
    try std.testing.expectEqual(@as(u8, 1), server.exit_code);
}

test "requests before initialize are rejected with ServerNotInitialized" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa);
    defer server.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"shutdown"}
    });
    defer responses.deinit();

    try std.testing.expectEqual(@as(usize, 1), responses.messages.items.len);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, -32002), parsed.value.object.get("error").?.object.get("code").?.integer);
}

test "unknown method after initialize gets MethodNotFound" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa);
    defer server.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{}}
    });
    defer responses.deinit();

    try std.testing.expectEqual(@as(usize, 2), responses.messages.items.len);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[1], .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, -32601), parsed.value.object.get("error").?.object.get("code").?.integer);
}

test "didOpen tracks the document; didChange replaces its text and bumps its revision" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","languageId":"zig","version":1,"text":"const x = 1;"}}}
    });
    defer opened.deinit();
    // No response to the notification itself, but one server-initiated
    // publishDiagnostics notification (empty, since the source is valid).
    try std.testing.expectEqual(@as(usize, 1), opened.messages.items.len);
    var diag = try std.json.parseFromSlice(std.json.Value, gpa, opened.messages.items[0], .{});
    defer diag.deinit();
    try std.testing.expectEqualStrings("textDocument/publishDiagnostics", diag.value.object.get("method").?.string);
    try std.testing.expectEqual(@as(usize, 0), diag.value.object.get("params").?.object.get("diagnostics").?.array.items.len);

    const after_open = server.documents.get("file:///a.zig").?;
    try std.testing.expectEqualStrings("const x = 1;", after_open.text);
    const revision_after_open = after_open.revision;

    var changed = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.zig","version":2},"contentChanges":[{"text":"const x = 2;"}]}}
    });
    defer changed.deinit();

    const after_change = server.documents.get("file:///a.zig").?;
    try std.testing.expectEqualStrings("const x = 2;", after_change.text);
    try std.testing.expect(after_change.revision != revision_after_open);
}

test "didChange on an unrelated file does not disturb another file's revision" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa);
    defer server.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"a"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///b.zig","text":"b"}}}
    });
    defer responses.deinit();

    const b_before = server.documents.get("file:///b.zig").?.revision;

    var changed = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.zig"},"contentChanges":[{"text":"a2"}]}}
    });
    defer changed.deinit();

    try std.testing.expectEqual(b_before, server.documents.get("file:///b.zig").?.revision);
}

test "didClose stops tracking the document" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"a"}}}
    });
    defer opened.deinit();
    try std.testing.expect(server.documents.get("file:///a.zig") != null);

    var closed = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///a.zig"}}}
    });
    defer closed.deinit();
    try std.testing.expectEqual(@as(?documents.Document, null), server.documents.get("file:///a.zig"));

    // Diagnostics for the now-closed file must be cleared, not left stale.
    try std.testing.expectEqual(@as(usize, 1), closed.messages.items.len);
    var diag = try std.json.parseFromSlice(std.json.Value, gpa, closed.messages.items[0], .{});
    defer diag.deinit();
    try std.testing.expectEqual(@as(usize, 0), diag.value.object.get("params").?.object.get("diagnostics").?.array.items.len);
}

test "opening a file with a syntax error publishes a non-empty diagnostic (the Phase 3 milestone)" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///bad.zig","text":"const x = ;"}}}
    });
    defer opened.deinit();

    try std.testing.expectEqual(@as(usize, 1), opened.messages.items.len);
    var diag = try std.json.parseFromSlice(std.json.Value, gpa, opened.messages.items[0], .{});
    defer diag.deinit();

    const params = diag.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("file:///bad.zig", params.get("uri").?.string);
    const items = params.get("diagnostics").?.array.items;
    try std.testing.expect(items.len > 0);
    try std.testing.expectEqual(@as(i64, 1), items[0].object.get("severity").?.integer);
    try std.testing.expect(items[0].object.get("message").?.string.len > 0);
}

test "editing an unrelated file does not reparse or republish for this one" {
    // Server-level version of the invalidation property `parse.zig` proves
    // at the query layer: didChange on file B must not touch file A's
    // cached parse result.
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"const x = 1;"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///b.zig","text":"const y = 1;"}}}
    });
    defer opened.deinit();

    const a_before = try parse.parse(&server.parse_cache, gpa, "file:///a.zig", server.documents.get("file:///a.zig").?.text, server.documents.get("file:///a.zig").?.revision);

    var changed = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///b.zig"},"contentChanges":[{"text":"const y = 2;"}]}}
    });
    defer changed.deinit();

    const a_after = try parse.parse(&server.parse_cache, gpa, "file:///a.zig", server.documents.get("file:///a.zig").?.text, server.documents.get("file:///a.zig").?.revision);
    try std.testing.expectEqual(a_before, a_after);
}
