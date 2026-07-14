//! In-process fake-client test harness. Frames requests exactly as a real
//! stdio transport would, runs them through a `Server`, and parses the
//! framed responses back out — so tests exercise the same
//! `framing.readMessage`/`writeMessage` code path production traffic does,
//! not a shortcut that calls `Server.handleMessage` with bare bytes.
//!
//! This is protocol-level test infra reused by every later phase, not just
//! Phase 1's handshake tests.

const std = @import("std");
const Io = std.Io;
const framing = @import("jsonrpc").framing;
const Server = @import("../server.zig").Server;

pub const Responses = struct {
    gpa: std.mem.Allocator,
    /// Raw (unframed) JSON body of each response the server wrote, in the
    /// order it wrote them.
    messages: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Responses) void {
        for (self.messages.items) |m| self.gpa.free(m);
        self.messages.deinit(self.gpa);
        self.* = undefined;
    }
};

/// Feeds `requests` (each an unframed JSON-RPC body) through `server` in
/// order and collects every framed response body it writes back.
pub fn run(gpa: std.mem.Allocator, server: *Server, requests: []const []const u8) !Responses {
    var input: Io.Writer.Allocating = .init(gpa);
    defer input.deinit();
    for (requests) |body| try framing.writeMessage(&input.writer, body);

    var in_reader: Io.Reader = .fixed(input.written());
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    while (try framing.readMessage(&in_reader, gpa)) |body| {
        defer gpa.free(body);
        try server.handleMessage(&out.writer, body);
    }

    var responses: Responses = .{ .gpa = gpa };
    errdefer responses.deinit();

    var out_reader: Io.Reader = .fixed(out.written());
    while (try framing.readMessage(&out_reader, gpa)) |body| {
        try responses.messages.append(gpa, body);
    }
    return responses;
}

test "run collects zero responses for pure notifications" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    var responses = try run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"initialized"}
    });
    defer responses.deinit();
    try std.testing.expectEqual(@as(usize, 0), responses.messages.items.len);
}
