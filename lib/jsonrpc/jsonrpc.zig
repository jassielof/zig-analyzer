//! JSON-RPC 2.0 message envelope on top of `std.json`. Deliberately dynamic
//! (`std.json.Value` for `id`/`params`/`result`) rather than a generated
//! typed LSP schema — Phase 1 only needs enough to dispatch by method name
//! and reply; typed params/results get added per-method as each feature
//! lands (see `queries/*.zig` and friends in later phases).

const std = @import("std");
const Io = std.Io;

pub const version = "2.0";

/// A parsed JSON-RPC request or notification. `id` is `null` (the Zig
/// optional, i.e. the field was absent) for notifications, matching the
/// spec's requirement that notifications omit `id` entirely.
pub const Message = struct {
    jsonrpc: []const u8 = "",
    id: ?std.json.Value = null,
    method: []const u8,
    params: std.json.Value = .null,

    pub fn isNotification(self: Message) bool {
        return self.id == null;
    }
};

pub const ParseError = std.json.ParseError(std.json.Scanner) || error{InvalidVersion};

/// Parses `body` as a `Message`. Caller must call `.deinit()` on the
/// result.
pub fn parse(gpa: std.mem.Allocator, body: []const u8) ParseError!std.json.Parsed(Message) {
    var parsed = try std.json.parseFromSlice(Message, gpa, body, .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.jsonrpc, version)) return error.InvalidVersion;
    return parsed;
}

/// Standard JSON-RPC / LSP error codes (JSON-RPC base range plus the LSP
/// extensions actually used by this server so far).
pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    server_not_initialized = -32002,
    _,
};

const ErrorObject = struct {
    code: i32,
    message: []const u8,
};

/// Serializes `{"jsonrpc":"2.0","id":id,"result":result}` and writes it as
/// one framed message to `writer`.
pub fn writeResult(
    writer: *Io.Writer,
    gpa: std.mem.Allocator,
    id: std.json.Value,
    result: anytype,
) !void {
    const Envelope = struct {
        jsonrpc: []const u8 = version,
        id: std.json.Value,
        result: @TypeOf(result),
    };
    try writeEnvelope(writer, gpa, Envelope{ .id = id, .result = result });
}

/// Serializes `{"jsonrpc":"2.0","id":id,"error":{"code":...,"message":...}}`
/// and writes it as one framed message to `writer`.
pub fn writeError(
    writer: *Io.Writer,
    gpa: std.mem.Allocator,
    id: std.json.Value,
    code: ErrorCode,
    message: []const u8,
) !void {
    const Envelope = struct {
        jsonrpc: []const u8 = version,
        id: std.json.Value,
        @"error": ErrorObject,
    };
    try writeEnvelope(writer, gpa, Envelope{
        .id = id,
        .@"error" = .{ .code = @intFromEnum(code), .message = message },
    });
}

/// Serializes `{"jsonrpc":"2.0","method":method,"params":params}` (no
/// `id` — a server-to-client notification, e.g. `publishDiagnostics`) and
/// writes it as one framed message to `writer`.
pub fn writeNotification(
    writer: *Io.Writer,
    gpa: std.mem.Allocator,
    method: []const u8,
    params: anytype,
) !void {
    const Envelope = struct {
        jsonrpc: []const u8 = version,
        method: []const u8,
        params: @TypeOf(params),
    };
    try writeEnvelope(writer, gpa, Envelope{ .method = method, .params = params });
}

const framing = @import("framing.zig");

fn writeEnvelope(writer: *Io.Writer, gpa: std.mem.Allocator, envelope: anytype) !void {
    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try std.json.Stringify.value(envelope, .{}, &body.writer);
    try framing.writeMessage(writer, body.written());
}

test "parse rejects a non-2.0 jsonrpc version" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidVersion,
        parse(gpa, "{\"jsonrpc\":\"1.0\",\"method\":\"initialize\"}"),
    );
}

test "parse distinguishes requests from notifications by id presence" {
    const gpa = std.testing.allocator;

    var request = try parse(gpa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}");
    defer request.deinit();
    try std.testing.expect(!request.value.isNotification());

    var notification = try parse(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}");
    defer notification.deinit();
    try std.testing.expect(notification.value.isNotification());
}

test "writeResult produces a framed, well-formed envelope" {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try writeResult(&out.writer, gpa, .{ .integer = 1 }, .{ .capabilities = .{} });

    var reader: Io.Reader = .fixed(out.written());
    const resp_body = (try framing.readMessage(&reader, gpa)).?;
    defer gpa.free(resp_body);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, resp_body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("id").?.integer);
    try std.testing.expect(parsed.value.object.get("result").?.object.contains("capabilities"));
}

test "writeError produces a framed error envelope" {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try writeError(&out.writer, gpa, .null, .method_not_found, "foo/bar");

    var reader: Io.Reader = .fixed(out.written());
    const resp_body = (try framing.readMessage(&reader, gpa)).?;
    defer gpa.free(resp_body);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, resp_body, .{});
    defer parsed.deinit();
    const err_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32601), err_obj.get("code").?.integer);
    try std.testing.expectEqualStrings("foo/bar", err_obj.get("message").?.string);
}

test "writeNotification produces an envelope with no id" {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try writeNotification(&out.writer, gpa, "textDocument/publishDiagnostics", .{ .uri = "file:///a.zig" });

    var reader: Io.Reader = .fixed(out.written());
    const resp_body = (try framing.readMessage(&reader, gpa)).?;
    defer gpa.free(resp_body);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, resp_body, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.contains("id"));
    try std.testing.expectEqualStrings("textDocument/publishDiagnostics", parsed.value.object.get("method").?.string);
    try std.testing.expectEqualStrings("file:///a.zig", parsed.value.object.get("params").?.object.get("uri").?.string);
}
