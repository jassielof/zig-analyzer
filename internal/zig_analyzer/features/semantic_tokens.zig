//! `textDocument/semanticTokens/full` — collects and LSP-encodes semantic
//! tokens via `../analysis/queries/semantic_tokens.zig`.

const std = @import("std");
const Io = std.Io;
const jsonrpc = @import("jsonrpc").jsonrpc;
const parse = @import("../analysis/queries/parse.zig");
const semantic_tokens = @import("../analysis/queries/semantic_tokens.zig");
const Server = @import("../server.zig").Server;

pub fn handleSemanticTokensFull(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
    const Params = struct { textDocument: struct { uri: []const u8 } };
    var parsed = std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
        try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid textDocument/semanticTokens/full params");
        return;
    };
    defer parsed.deinit();

    const uri = parsed.value.textDocument.uri;
    const doc = self.documents.get(uri) orelse {
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
        return;
    };

    const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);

    const tokens = try semantic_tokens.collect(self.gpa, parsed_file.ast);
    defer self.gpa.free(tokens);

    const data = try semantic_tokens.encode(self.gpa, tokens);
    defer self.gpa.free(data);

    const SemanticTokensResult = struct { data: []const u32 };
    try jsonrpc.writeResult(writer, self.gpa, msg.id.?, SemanticTokensResult{ .data = data });
}
