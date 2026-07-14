//! `textDocument/formatting` — delegates the actual formatting to the
//! configured external formatter (see `../formatting.zig`), then wraps
//! its output as a single whole-document `TextEdit`.

const std = @import("std");
const Io = std.Io;
const jsonrpc = @import("jsonrpc").jsonrpc;
const formatting = @import("../formatting.zig");
const server_mod = @import("../server.zig");
const Server = server_mod.Server;
const Range = server_mod.Range;

/// The last line/character of `text`, byte-based like the rest of
/// this server's position handling — used to build a
/// whole-document-replacing `TextEdit` range.
fn endOfDocument(text: []const u8) struct { u32, u32 } {
    var line: u32 = 0;
    var line_start: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ line, @intCast(text.len - line_start) };
}

pub fn handleFormatting(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
    const Params = struct { textDocument: struct { uri: []const u8 } };
    var parsed = std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
        try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid textDocument/formatting params");
        return;
    };
    defer parsed.deinit();

    const uri = parsed.value.textDocument.uri;
    const doc = self.documents.get(uri) orelse {
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
        return;
    };

    var result = formatting.format(self.gpa, self.io, self.formatter_config, doc.text) catch |err| {
        try jsonrpc.writeError(writer, self.gpa, msg.id.?, .internal_error, @errorName(err));
        return;
    };
    defer result.deinit(self.gpa);

    switch (result) {
        .failure => |message| {
            try jsonrpc.writeError(writer, self.gpa, msg.id.?, .internal_error, message);
        },
        .formatted => |text| {
            // Full-document replace: simplest always-correct edit,
            // and matches this server's full-document sync (no
            // finer-grained diffing needed to compute it).
            const end_line, const end_character = endOfDocument(doc.text);
            const TextEditResult = struct { range: Range, newText: []const u8 };
            const edits = [_]TextEditResult{.{
                .range = .{
                    .start = .{ .line = 0, .character = 0 },
                    .end = .{ .line = end_line, .character = end_character },
                },
                .newText = text,
            }};
            try jsonrpc.writeResult(writer, self.gpa, msg.id.?, &edits);
        },
    }
}
