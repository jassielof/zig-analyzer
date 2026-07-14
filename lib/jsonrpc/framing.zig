//! `Content-Length`-based message framing shared by every LSP transport
//! (stdio today; other transports later reuse this unchanged). Knows
//! nothing about JSON-RPC semantics — it only moves opaque message bodies.

const std = @import("std");
const Io = std.Io;

pub const ReadError = std.mem.Allocator.Error || error{
    /// The reader closed mid-body: some headers (including a valid
    /// Content-Length) were seen, but the stream ended before the blank
    /// line or the body bytes it promised arrived.
    UnexpectedEndOfStream,
    /// The stream ended before the body promised by a valid Content-Length
    /// header was fully delivered.
    EndOfStream,
    ReadFailed,
    MissingContentLength,
    InvalidContentLength,
    InvalidHeader,
};

/// Reads one `Content-Length`-framed message from `reader` and returns its
/// body, allocated with `gpa`. Caller owns the returned slice.
///
/// Returns `null` when the stream ends cleanly before any new message
/// starts — the normal way an LSP client signals it is done (closing
/// stdin).
pub fn readMessage(reader: *Io.Reader, gpa: std.mem.Allocator) ReadError!?[]u8 {
    var content_length: ?usize = null;
    var header_lines: usize = 0;

    while (true) {
        // `takeDelimiter` (unlike `takeDelimiterExclusive`) advances the
        // seek position *past* the delimiter, which is what lets the next
        // call see the following line instead of re-observing the same
        // `\n`. It signals "no more data" via `null` rather than an error.
        const line = (reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.InvalidHeader,
            error.ReadFailed => return error.ReadFailed,
        }) orelse {
            if (header_lines == 0) return null;
            return error.UnexpectedEndOfStream;
        };
        header_lines += 1;

        // Header lines are terminated `\r\n`; tolerate a bare `\n` too.
        const header = if (line.len > 0 and line[line.len - 1] == '\r')
            line[0 .. line.len - 1]
        else
            line;

        if (header.len == 0) break; // blank line: end of header block

        const colon = std.mem.indexOfScalar(u8, header, ':') orelse return error.InvalidHeader;
        const name = std.mem.trim(u8, header[0..colon], " \t");
        const value = std.mem.trim(u8, header[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
        }
        // Other headers (e.g. Content-Type) are accepted and ignored.
    }

    const len = content_length orelse return error.MissingContentLength;
    return try reader.readAlloc(gpa, len);
}

/// Writes `body` (a complete JSON document) as one `Content-Length`-framed
/// message to `writer`. Does not flush.
pub fn writeMessage(writer: *Io.Writer, body: []const u8) Io.Writer.Error!void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
}

test "write then read round-trips a body" {
    const gpa = std.testing.allocator;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeMessage(&out.writer, "{\"hello\":\"world\"}");

    var reader: Io.Reader = .fixed(out.written());
    const body = (try readMessage(&reader, gpa)).?;
    defer gpa.free(body);

    try std.testing.expectEqualStrings("{\"hello\":\"world\"}", body);
}

test "reads consecutive messages back to back" {
    const gpa = std.testing.allocator;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeMessage(&out.writer, "\"one\"");
    try writeMessage(&out.writer, "\"two\"");

    var reader: Io.Reader = .fixed(out.written());

    const first = (try readMessage(&reader, gpa)).?;
    defer gpa.free(first);
    try std.testing.expectEqualStrings("\"one\"", first);

    const second = (try readMessage(&reader, gpa)).?;
    defer gpa.free(second);
    try std.testing.expectEqualStrings("\"two\"", second);

    try std.testing.expectEqual(@as(?[]u8, null), try readMessage(&reader, gpa));
}

test "ignores unrelated headers and is case-insensitive" {
    const gpa = std.testing.allocator;
    const raw = "content-type: application/vscode-jsonrpc; charset=utf-8\r\n" ++
        "Content-Length: 4\r\n\r\n" ++
        "\"ok\"";

    var reader: Io.Reader = .fixed(raw);
    const body = (try readMessage(&reader, gpa)).?;
    defer gpa.free(body);
    try std.testing.expectEqualStrings("\"ok\"", body);
}

test "clean EOF before any message returns null" {
    const gpa = std.testing.allocator;
    var reader: Io.Reader = .fixed("");
    try std.testing.expectEqual(@as(?[]u8, null), try readMessage(&reader, gpa));
}

test "missing Content-Length header is an error" {
    const gpa = std.testing.allocator;
    var reader: Io.Reader = .fixed("X-Custom: 1\r\n\r\n");
    try std.testing.expectError(error.MissingContentLength, readMessage(&reader, gpa));
}

test "closing mid-header-block is unexpected EOF, not a clean shutdown" {
    const gpa = std.testing.allocator;
    var reader: Io.Reader = .fixed("Content-Length: 10\r\n");
    try std.testing.expectError(error.UnexpectedEndOfStream, readMessage(&reader, gpa));
}

test "closing mid-body is an error, not a truncated message" {
    const gpa = std.testing.allocator;
    var reader: Io.Reader = .fixed("Content-Length: 10\r\n\r\nabc");
    try std.testing.expectError(error.EndOfStream, readMessage(&reader, gpa));
}
