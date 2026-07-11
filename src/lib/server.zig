//! LSP lifecycle: `initialize` / `initialized` / `shutdown` / `exit`. This
//! is transport-agnostic — it only reads/writes JSON-RPC message bodies via
//! `protocol.jsonrpc`, so the same `Server` drives both the real stdio loop
//! (`cli/main.zig`) and the in-process test harness
//! (`protocol/harness.zig`).

const std = @import("std");
const Io = std.Io;
const Ast = std.zig.Ast;
const build_options = @import("build_options");
const jsonrpc = @import("protocol/jsonrpc.zig");
const documents = @import("documents.zig");
const parse = @import("analysis/queries/parse.zig");
const item_tree = @import("analysis/queries/item_tree.zig");
const resolve = @import("analysis/queries/resolve.zig");
const imports = @import("analysis/queries/imports.zig");
const semantic_diagnostics = @import("analysis/queries/semantic_diagnostics.zig");
const formatting = @import("formatting.zig");
const semantic_tokens = @import("analysis/queries/semantic_tokens.zig");

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
    /// Real OS access (process spawning, currently) for features that
    /// need to shell out — e.g. running a formatter. Everything else in
    /// this struct is transport-agnostic; this is the one exception,
    /// scoped to exactly the handlers that need it.
    io: Io,
    phase: Phase = .uninitialized,
    should_exit: bool = false,
    /// Set once `should_exit` is set. Per spec: 0 if `shutdown` was
    /// requested first, 1 otherwise ("unexpected exit").
    exit_code: u8 = 0,
    documents: documents.Store,
    parse_cache: parse.Cache = .{},
    item_tree_cache: item_tree.Cache = .{},
    formatter_config: formatting.Config = .{},
    /// True once `formatter_config` was replaced with something other
    /// than the struct-literal default above — meaning its strings are
    /// gpa-owned and must be freed on the next replacement or on
    /// `deinit`. The default's strings are literals; nothing to free.
    formatter_config_owned: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: Io) Server {
        return .{ .gpa = gpa, .io = io, .documents = .init(gpa) };
    }

    pub fn deinit(self: *Server) void {
        self.documents.deinit();
        self.parse_cache.deinit(self.gpa);
        self.item_tree_cache.deinit(self.gpa);
        self.freeFormatterConfigIfOwned();
    }

    fn freeFormatterConfigIfOwned(self: *Server) void {
        if (!self.formatter_config_owned) return;
        self.gpa.free(self.formatter_config.command);
        for (self.formatter_config.args) |arg| self.gpa.free(arg);
        self.gpa.free(self.formatter_config.args);
        self.formatter_config_owned = false;
    }

    /// Replaces `formatter_config` with an owned copy of `command`/`args`,
    /// freeing whatever was there before.
    fn setFormatterConfig(self: *Server, command: []const u8, args: []const []const u8) !void {
        const new_command = try self.gpa.dupe(u8, command);
        errdefer self.gpa.free(new_command);

        const new_args = try self.gpa.alloc([]const u8, args.len);
        errdefer self.gpa.free(new_args);
        var filled: usize = 0;
        errdefer for (new_args[0..filled]) |a| self.gpa.free(a);
        for (args) |arg| {
            new_args[filled] = try self.gpa.dupe(u8, arg);
            filled += 1;
        }

        self.freeFormatterConfigIfOwned();
        self.formatter_config = .{ .command = new_command, .args = new_args };
        self.formatter_config_owned = true;
    }

    const FormatterOptions = struct {
        command: ?[]const u8 = null,
        args: ?[]const []const u8 = null,
    };
    const ServerOptions = struct {
        formatter: ?FormatterOptions = null,
    };

    /// Shared by `initialize`'s `initializationOptions` and
    /// `workspace/didChangeConfiguration`'s `settings` — both carry the
    /// same `{ formatter: { command, args } }` shape (see extension.ts).
    fn applyOptions(self: *Server, options_value: std.json.Value) void {
        // Absent options (no `initializationOptions`, or a
        // `didChangeConfiguration` for an unrelated section) is the
        // common case, not a malformed one — a struct type can't parse
        // from JSON `null`, so this must be checked before attempting to
        // parse, not just caught as an error.
        if (options_value == .null) return;

        var parsed = std.json.parseFromValue(ServerOptions, self.gpa, options_value, .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.err("ignoring malformed server options: {t}", .{err});
            return;
        };
        defer parsed.deinit();

        const formatter = parsed.value.formatter orelse return;
        const command = formatter.command orelse "zig";
        const args = formatter.args orelse &[_][]const u8{ "fmt", "--stdin" };
        self.setFormatterConfig(command, args) catch |err| {
            std.log.err("failed to apply formatter config: {t}", .{err});
        };
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
        } else if (std.mem.eql(u8, msg.method, "textDocument/definition")) {
            try self.handleDefinition(writer, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/hover")) {
            try self.handleHover(writer, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/documentSymbol")) {
            try self.handleDocumentSymbol(writer, msg);
        } else if (std.mem.eql(u8, msg.method, "workspace/symbol")) {
            try self.handleWorkspaceSymbol(writer, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/completion")) {
            try self.handleCompletion(writer, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/formatting")) {
            try self.handleFormatting(writer, msg);
        } else if (std.mem.eql(u8, msg.method, "workspace/didChangeConfiguration")) {
            self.handleDidChangeConfiguration(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/semanticTokens/full")) {
            try self.handleSemanticTokensFull(writer, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/references")) {
            try self.handleReferences(writer, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/rename")) {
            try self.handleRename(writer, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/signatureHelp")) {
            try self.handleSignatureHelp(writer, msg);
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

        const Params = struct { initializationOptions: std.json.Value = .null };
        if (std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true })) |parsed| {
            defer parsed.deinit();
            self.applyOptions(parsed.value.initializationOptions);
        } else |err| {
            std.log.err("ignoring malformed initialize params: {t}", .{err});
        }

        const InitializeResult = struct {
            capabilities: struct {
                // 1 == TextDocumentSyncKind.Full.
                textDocumentSync: u8 = 1,
                definitionProvider: bool = true,
                hoverProvider: bool = true,
                documentSymbolProvider: bool = true,
                workspaceSymbolProvider: bool = true,
                completionProvider: struct {} = .{},
                documentFormattingProvider: bool = true,
                semanticTokensProvider: struct {
                    legend: struct {
                        // Order is significant: it's the index each
                        // semantic_tokens.TokenType/TokenModifier variant
                        // encodes to on the wire. Must match that enum's
                        // declaration order exactly.
                        tokenTypes: []const []const u8 = &.{ "function", "parameter", "variable" },
                        tokenModifiers: []const []const u8 = &.{ "declaration", "readonly" },
                    } = .{},
                    full: bool = true,
                } = .{},
                referencesProvider: bool = true,
                renameProvider: bool = true,
                signatureHelpProvider: struct {
                    triggerCharacters: []const []const u8 = &.{ "(", "," },
                } = .{},
            } = .{},
            serverInfo: struct {
                name: []const u8 = "zig-analyzer",
                version: []const u8 = build_options.version,
            } = .{},
        };
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, InitializeResult{});
        self.phase = .initializing;
    }

    fn handleInitialized(self: *Server, msg: jsonrpc.Message) void {
        _ = msg;
        if (self.phase == .initializing) self.phase = .running;
    }

    fn handleDidChangeConfiguration(self: *Server, msg: jsonrpc.Message) void {
        const Params = struct { settings: std.json.Value = .null };
        var parsed = std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.err("ignoring malformed workspace/didChangeConfiguration params: {t}", .{err});
            return;
        };
        defer parsed.deinit();
        self.applyOptions(parsed.value.settings);
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
        self.item_tree_cache.remove(self.gpa, uri);
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

        // Semantic checks run on error-recovered ASTs too in principle,
        // but a file mid-syntax-error is exactly when they're least
        // trustworthy (e.g. a dangling brace can make half the file look
        // like one giant unused local). Only run them once it parses clean.
        if (ast.errors.len == 0) {
            const semantic = try semantic_diagnostics.check(self.gpa, ast);
            defer semantic_diagnostics.freeDiagnostics(self.gpa, semantic);

            for (semantic) |d| {
                try diagnostics.append(self.gpa, .{
                    .range = .{
                        .start = .{ .line = d.line, .character = d.character },
                        .end = .{ .line = d.line, .character = d.end_character },
                    },
                    .severity = @intFromEnum(d.severity),
                    .message = try self.gpa.dupe(u8, d.message),
                });
            }
        }

        try jsonrpc.writeNotification(writer, self.gpa, "textDocument/publishDiagnostics", .{
            .uri = uri,
            .diagnostics = diagnostics.items,
        });
    }

    const DefinitionParams = struct {
        textDocument: struct { uri: []const u8 },
        position: Position,
    };

    fn handleDefinition(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
        var parsed = std.json.parseFromValue(DefinitionParams, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
            try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid textDocument/definition params");
            return;
        };
        defer parsed.deinit();

        const any = try self.resolveRequestPosition(parsed.value.textDocument.uri, parsed.value.position) orelse {
            try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
            return;
        };
        defer self.gpa.free(any.uri);

        const LocationResult = struct { uri: []const u8, range: Range };
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, LocationResult{
            .uri = any.uri,
            .range = .{
                .start = .{ .line = any.def.line, .character = any.def.character },
                .end = .{ .line = any.def.line, .character = any.def.end_character },
            },
        });
    }

    /// `resolve.findDoctest` returns the raw `{ ... }` block source —
    /// braces and whatever indentation the `test` block happened to sit
    /// at in the source file both included. Strips the braces and
    /// dedents by the block's minimum common leading whitespace, so the
    /// doctest renders as a clean, left-aligned snippet in hover instead
    /// of carrying that indentation along with it.
    fn formatDoctestBody(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        const inner = if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}')
            trimmed[1 .. trimmed.len - 1]
        else
            trimmed;

        var min_indent: usize = std.math.maxInt(usize);
        var lines = std.mem.splitScalar(u8, inner, '\n');
        while (lines.next()) |line| {
            if (std.mem.trimEnd(u8, line, " \t\r").len == 0) continue; // blank lines don't count
            var indent: usize = 0;
            while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) indent += 1;
            min_indent = @min(min_indent, indent);
        }
        if (min_indent == std.math.maxInt(usize)) min_indent = 0;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        lines = std.mem.splitScalar(u8, inner, '\n');
        var first = true;
        while (lines.next()) |line| {
            const stripped = std.mem.trimEnd(u8, line, " \t\r");
            const dedented = if (stripped.len > min_indent) stripped[min_indent..] else "";
            if (!first) try out.append(gpa, '\n');
            try out.appendSlice(gpa, dedented);
            first = false;
        }

        const result = std.mem.trim(u8, out.items, "\n");
        const owned = try gpa.dupe(u8, result);
        out.deinit(gpa);
        return owned;
    }

    fn handleHover(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
        var parsed = std.json.parseFromValue(DefinitionParams, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
            try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid textDocument/hover params");
            return;
        };
        defer parsed.deinit();

        const any = try self.resolveRequestPosition(parsed.value.textDocument.uri, parsed.value.position) orelse {
            try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
            return;
        };
        defer self.gpa.free(any.uri);

        // Doctest lookup happens against the *declaration's* file, which
        // for a cross-file hover (`helpers.add`) is the imported file,
        // not the requesting one — re-fetching via the cache is a hit in
        // that case (resolveRequestPosition already parsed it) and a
        // guaranteed hit in the same-file case.
        var doctest: ?[]u8 = null;
        defer if (doctest) |dt| self.gpa.free(dt);
        if (self.documents.get(any.uri)) |target_doc| {
            const target_parsed = try parse.parse(&self.parse_cache, self.gpa, any.uri, target_doc.text, target_doc.revision);
            const decl_name = nameOfDefinition(target_parsed.ast, any.def);
            if (resolve.findDoctest(target_parsed.ast, decl_name)) |raw| {
                doctest = try formatDoctestBody(self.gpa, raw);
            }
        }

        const value = if (doctest) |dt|
            try std.fmt.allocPrint(
                self.gpa,
                \\```zig
                \\{s}
                \\```
                \\
                \\---
                \\
                \\## Doctest example
                \\
                \\```zig
                \\{s}
                \\```
            ,
                .{ any.def.signature, dt },
            )
        else
            try std.fmt.allocPrint(
                self.gpa,
                \\```zig
                \\{s}
                \\```
            ,
                .{any.def.signature},
            );
        defer self.gpa.free(value);

        const HoverContents = struct { kind: []const u8 = "markdown", value: []const u8 };
        const HoverResult = struct {
            contents: HoverContents,
            range: Range,
        };
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, HoverResult{
            .contents = .{ .value = value },
            .range = .{
                .start = .{ .line = any.def.line, .character = any.def.character },
                .end = .{ .line = any.def.line, .character = any.def.end_character },
            },
        });
    }

    const AnyDefinition = struct { uri: []const u8, def: resolve.Definition };

    /// Shared by `textDocument/definition` and `textDocument/hover`: both
    /// need to resolve a position to a declaration, one to show its
    /// location, the other its signature. Tries local resolution first
    /// (params, immediate-body locals, this file's item tree), then
    /// cross-file via `@import` bindings. The returned `uri` is always an
    /// owned copy — same-file or cross-file — so callers have exactly one
    /// ownership rule to follow.
    fn resolveRequestPosition(self: *Server, uri: []const u8, position: Position) !?AnyDefinition {
        const doc = self.documents.get(uri) orelse return null;
        const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
        const tree = try item_tree.itemTree(&self.item_tree_cache, self.gpa, uri, parsed_file.ast, doc.revision);
        const pos: resolve.Position = .{ .line = position.line, .character = position.character };

        if (resolve.resolveAt(parsed_file.ast, tree.*, pos)) |def| {
            return .{ .uri = try self.gpa.dupe(u8, uri), .def = def };
        }
        if (resolve.fieldAccessAt(parsed_file.ast, pos)) |fa| {
            if (try self.resolveCrossFile(uri, parsed_file.ast, fa)) |cross| {
                return cross; // already owns its uri
            }
        }
        return null;
    }

    const CrossFileDefinition = AnyDefinition;

    /// Follows `field_access.base` through `importer_ast`'s `@import`
    /// bindings into the imported file's item tree — reading only that
    /// file's stable public shape, never its body/local resolution (see
    /// project plan §1.3, §Phase 6). Only resolves into files the client
    /// already has open (tracked in `self.documents`): there's no
    /// filesystem access here, so an import target that isn't open in the
    /// editor can't be resolved yet.
    fn resolveCrossFile(
        self: *Server,
        importer_uri: []const u8,
        importer_ast: Ast,
        field_access: resolve.FieldAccess,
    ) !?CrossFileDefinition {
        const imports_list = try imports.findImports(self.gpa, importer_ast, importer_uri);
        defer imports.freeImports(self.gpa, imports_list);

        for (imports_list) |imp| {
            if (!std.mem.eql(u8, imp.name, field_access.base)) continue;
            const target_uri = imp.uri orelse return null;
            const target_doc = self.documents.get(target_uri) orelse return null;

            const target_parsed = try parse.parse(&self.parse_cache, self.gpa, target_uri, target_doc.text, target_doc.revision);
            const target_tree = try item_tree.itemTree(&self.item_tree_cache, self.gpa, target_uri, target_parsed.ast, target_doc.revision);

            const def = resolve.resolveTopLevel(target_parsed.ast, target_tree.*, field_access.field) orelse return null;
            // `target_uri` points into `imports_list`, which this
            // function frees before returning — hand back an owned copy
            // rather than a pointer into memory that's about to be freed.
            return .{ .uri = try self.gpa.dupe(u8, target_uri), .def = def };
        }
        return null;
    }

    // LSP `SymbolKind`: 12 = Function, 13 = Variable.
    fn symbolKind(kind: item_tree.Item.Kind) u8 {
        return switch (kind) {
            .function => 12,
            .variable => 13,
        };
    }

    fn handleDocumentSymbol(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
        const Params = struct { textDocument: struct { uri: []const u8 } };
        var parsed = std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
            try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid textDocument/documentSymbol params");
            return;
        };
        defer parsed.deinit();

        const DocumentSymbolResult = struct { name: []const u8, kind: u8, range: Range, selectionRange: Range };
        var symbols: std.ArrayList(DocumentSymbolResult) = .empty;
        defer symbols.deinit(self.gpa);

        const uri = parsed.value.textDocument.uri;
        if (self.documents.get(uri)) |doc| {
            const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
            const tree = try item_tree.itemTree(&self.item_tree_cache, self.gpa, uri, parsed_file.ast, doc.revision);

            for (tree.items) |item| {
                // First occurrence only: a duplicate-named item (already
                // flagged separately by semantic_diagnostics) would
                // otherwise show the same location twice.
                const def = resolve.definitionForRootItem(parsed_file.ast, item.name) orelse continue;
                const range: Range = .{
                    .start = .{ .line = def.line, .character = def.character },
                    .end = .{ .line = def.line, .character = def.end_character },
                };
                try symbols.append(self.gpa, .{
                    .name = item.name,
                    .kind = symbolKind(item.kind),
                    .range = range,
                    .selectionRange = range,
                });
            }
        }

        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, symbols.items);
    }

    fn handleWorkspaceSymbol(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
        const Params = struct { query: []const u8 = "" };
        var parsed = std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
            try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid workspace/symbol params");
            return;
        };
        defer parsed.deinit();

        const SymbolInformationResult = struct {
            name: []const u8,
            kind: u8,
            location: struct { uri: []const u8, range: Range },
        };
        var symbols: std.ArrayList(SymbolInformationResult) = .empty;
        defer symbols.deinit(self.gpa);

        var it = self.documents.documents.iterator();
        while (it.next()) |entry| {
            const doc_uri = entry.key_ptr.*;
            const doc = entry.value_ptr.*;
            const parsed_file = try parse.parse(&self.parse_cache, self.gpa, doc_uri, doc.text, doc.revision);
            const tree = try item_tree.itemTree(&self.item_tree_cache, self.gpa, doc_uri, parsed_file.ast, doc.revision);

            for (tree.items) |item| {
                if (parsed.value.query.len > 0 and std.mem.indexOf(u8, item.name, parsed.value.query) == null) continue;
                const def = resolve.definitionForRootItem(parsed_file.ast, item.name) orelse continue;
                try symbols.append(self.gpa, .{
                    .name = item.name,
                    .kind = symbolKind(item.kind),
                    .location = .{
                        .uri = doc_uri,
                        .range = .{
                            .start = .{ .line = def.line, .character = def.character },
                            .end = .{ .line = def.line, .character = def.end_character },
                        },
                    },
                });
            }
        }

        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, symbols.items);
    }

    const keywords = [_][]const u8{
        "const",       "var",     "fn",     "pub",      "return",   "if",        "else",
        "while",       "for",     "switch", "struct",   "enum",     "union",     "error",
        "try",         "catch",   "defer",  "errdefer", "break",    "continue",  "comptime",
        "inline",      "export",  "extern", "test",     "null",     "undefined", "true",
        "false",       "and",     "or",     "orelse",   "async",    "await",     "suspend",
        "nosuspend",   "resume",  "packed", "align",    "volatile", "allowzero", "threadlocal",
        "linksection", "noalias", "opaque", "anytype",  "anyframe",
    };

    fn handleCompletion(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
        // LSP `CompletionItemKind`: 3 = Function, 6 = Variable, 14 = Keyword.
        const CompletionItemResult = struct { label: []const u8, kind: u8 };
        var parsed = std.json.parseFromValue(DefinitionParams, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
            try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid textDocument/completion params");
            return;
        };
        defer parsed.deinit();

        var items: std.ArrayList(CompletionItemResult) = .empty;
        defer items.deinit(self.gpa);

        for (keywords) |kw| try items.append(self.gpa, .{ .label = kw, .kind = 14 });

        const uri = parsed.value.textDocument.uri;
        if (self.documents.get(uri)) |doc| {
            const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
            const tree = try item_tree.itemTree(&self.item_tree_cache, self.gpa, uri, parsed_file.ast, doc.revision);

            for (tree.items) |item| {
                try items.append(self.gpa, .{ .label = item.name, .kind = if (item.kind == .function) @as(u8, 3) else @as(u8, 6) });
            }

            const offset = resolve.positionToOffset(parsed_file.ast.source, .{
                .line = parsed.value.position.line,
                .character = parsed.value.position.character,
            });
            var local_names: std.ArrayList([]const u8) = .empty;
            defer local_names.deinit(self.gpa);
            try resolve.collectLocalScopeNames(self.gpa, parsed_file.ast, offset, &local_names);
            for (local_names.items) |name| try items.append(self.gpa, .{ .label = name, .kind = 6 });
        }

        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, items.items);
    }

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

    fn handleFormatting(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
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

    fn handleSemanticTokensFull(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
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

    /// The identifier text at a `Definition`'s own location — re-sliced
    /// from source via its line/character span, since `Definition`
    /// carries a signature (which for functions is more than just the
    /// name) but not the bare name itself.
    fn nameOfDefinition(ast: Ast, def: resolve.Definition) []const u8 {
        const start = resolve.positionToOffset(ast.source, .{ .line = def.line, .character = def.character });
        const end = resolve.positionToOffset(ast.source, .{ .line = def.line, .character = def.end_character });
        return ast.source[start..end];
    }

    fn handleReferences(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
        const Params = struct {
            textDocument: struct { uri: []const u8 },
            position: Position,
            context: struct { includeDeclaration: bool = false } = .{},
        };
        var parsed = std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
            try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid textDocument/references params");
            return;
        };
        defer parsed.deinit();

        const uri = parsed.value.textDocument.uri;
        const doc = self.documents.get(uri) orelse {
            try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
            return;
        };

        const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
        const tree = try item_tree.itemTree(&self.item_tree_cache, self.gpa, uri, parsed_file.ast, doc.revision);
        const pos: resolve.Position = .{ .line = parsed.value.position.line, .character = parsed.value.position.character };

        const def = resolve.resolveAt(parsed_file.ast, tree.*, pos) orelse {
            try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
            return;
        };
        const target_name = nameOfDefinition(parsed_file.ast, def);

        const refs = try resolve.findReferences(self.gpa, parsed_file.ast, tree.*, target_name, def.line, def.character);
        defer self.gpa.free(refs);

        const LocationResult = struct { uri: []const u8, range: Range };
        var results: std.ArrayList(LocationResult) = .empty;
        defer results.deinit(self.gpa);

        if (parsed.value.context.includeDeclaration) {
            try results.append(self.gpa, .{
                .uri = uri,
                .range = .{
                    .start = .{ .line = def.line, .character = def.character },
                    .end = .{ .line = def.line, .character = def.end_character },
                },
            });
        }
        for (refs) |r| {
            try results.append(self.gpa, .{
                .uri = uri,
                .range = .{
                    .start = .{ .line = r.line, .character = r.character },
                    .end = .{ .line = r.line, .character = r.end_character },
                },
            });
        }

        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, results.items);
    }

    fn isValidZigIdentifier(name: []const u8) bool {
        if (name.len == 0) return false;
        if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
        for (name[1..]) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
        }
        // Rejecting keywords too, so a rename can't silently produce
        // invalid code (e.g. renaming a variable to "const").
        return std.zig.Token.getKeyword(name) == null;
    }

    fn handleRename(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
        const Params = struct {
            textDocument: struct { uri: []const u8 },
            position: Position,
            newName: []const u8,
        };
        var parsed = std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
            try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid textDocument/rename params");
            return;
        };
        defer parsed.deinit();

        if (!isValidZigIdentifier(parsed.value.newName)) {
            try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "not a valid Zig identifier");
            return;
        }

        const uri = parsed.value.textDocument.uri;
        const doc = self.documents.get(uri) orelse {
            try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
            return;
        };

        const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
        const tree = try item_tree.itemTree(&self.item_tree_cache, self.gpa, uri, parsed_file.ast, doc.revision);
        const pos: resolve.Position = .{ .line = parsed.value.position.line, .character = parsed.value.position.character };

        const def = resolve.resolveAt(parsed_file.ast, tree.*, pos) orelse {
            try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "nothing to rename at this position");
            return;
        };
        const target_name = nameOfDefinition(parsed_file.ast, def);

        const refs = try resolve.findReferences(self.gpa, parsed_file.ast, tree.*, target_name, def.line, def.character);
        defer self.gpa.free(refs);

        const TextEditResult = struct { range: Range, newText: []const u8 };
        var edits: std.ArrayList(TextEditResult) = .empty;
        defer edits.deinit(self.gpa);

        try edits.append(self.gpa, .{
            .range = .{
                .start = .{ .line = def.line, .character = def.character },
                .end = .{ .line = def.line, .character = def.end_character },
            },
            .newText = parsed.value.newName,
        });
        for (refs) |r| {
            try edits.append(self.gpa, .{
                .range = .{
                    .start = .{ .line = r.line, .character = r.character },
                    .end = .{ .line = r.line, .character = r.end_character },
                },
                .newText = parsed.value.newName,
            });
        }

        // `WorkspaceEdit.changes` is a JSON object keyed by URI, which a
        // comptime-known struct can't represent — this is exactly what
        // `std.json.ArrayHashMap` exists for (see its doc comment).
        const Changes = std.json.ArrayHashMap([]const TextEditResult);
        var changes: Changes = .{};
        defer changes.deinit(self.gpa);
        try changes.map.put(self.gpa, uri, edits.items);

        const WorkspaceEditResult = struct { changes: Changes };
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, WorkspaceEditResult{ .changes = changes });
    }

    fn handleSignatureHelp(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
        const Params = struct {
            textDocument: struct { uri: []const u8 },
            position: Position,
        };
        var parsed = std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch {
            try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_params, "invalid textDocument/signatureHelp params");
            return;
        };
        defer parsed.deinit();

        const uri = parsed.value.textDocument.uri;
        const doc = self.documents.get(uri) orelse {
            try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
            return;
        };

        const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
        const tree = try item_tree.itemTree(&self.item_tree_cache, self.gpa, uri, parsed_file.ast, doc.revision);
        const pos: resolve.Position = .{ .line = parsed.value.position.line, .character = parsed.value.position.character };

        const ctx = try resolve.callContextAt(self.gpa, parsed_file.ast, pos) orelse {
            try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
            return;
        };
        const callee_name = parsed_file.ast.tokenSlice(ctx.callee_token);

        var signature: ?[]const u8 = null;

        if (tree.find(callee_name)) |item| {
            if (item.kind == .function) signature = item.signature;
        }
        if (signature == null) {
            if (resolve.fieldAccessAtToken(parsed_file.ast, ctx.callee_token)) |fa| {
                if (try self.resolveCrossFile(uri, parsed_file.ast, fa)) |cross| {
                    self.gpa.free(cross.uri);
                    // `cross.def.signature` is borrowed from the imported
                    // file's Ast, which stays cached in `self.parse_cache`
                    // for the rest of this synchronous handler — safe to
                    // use directly without copying it out.
                    signature = cross.def.signature;
                }
            }
        }

        const sig = signature orelse {
            try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
            return;
        };

        const SignatureInfoResult = struct { label: []const u8 };
        const SignatureHelpResult = struct {
            signatures: []const SignatureInfoResult,
            activeSignature: u32 = 0,
            activeParameter: u32,
        };
        try jsonrpc.writeResult(writer, self.gpa, msg.id.?, SignatureHelpResult{
            .signatures = &.{.{ .label = sig }},
            .activeParameter = ctx.active_parameter,
        });
    }
};

const harness = @import("protocol/harness.zig");

test "full handshake: initialize, initialized, shutdown, exit" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
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
    var server: Server = .init(gpa, std.testing.io);
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
    var server: Server = .init(gpa, std.testing.io);
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
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/foldingRange","params":{}}
    });
    defer responses.deinit();

    try std.testing.expectEqual(@as(usize, 2), responses.messages.items.len);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[1], .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, -32601), parsed.value.object.get("error").?.object.get("code").?.integer);
}

test "didOpen tracks the document; didChange replaces its text and bumps its revision" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
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
    var server: Server = .init(gpa, std.testing.io);
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
    var server: Server = .init(gpa, std.testing.io);
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
    var server: Server = .init(gpa, std.testing.io);
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
    var server: Server = .init(gpa, std.testing.io);
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

test "textDocument/definition resolves a top-level function reference" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn helper() void {}\nfn main() void {\n    helper();\n}\n"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///a.zig"},"position":{"line":2,"character":5}}}
    });
    defer responses.deinit();

    try std.testing.expectEqual(@as(usize, 1), responses.messages.items.len);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("file:///a.zig", result.get("uri").?.string);
    const range = result.get("range").?.object;
    try std.testing.expectEqual(@as(i64, 0), range.get("start").?.object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 3), range.get("start").?.object.get("character").?.integer);
}

test "textDocument/definition returns null when nothing resolves" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn f() void {\n    unknown_name;\n}\n"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///a.zig"},"position":{"line":1,"character":6}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    try std.testing.expectEqual(std.json.Value.null, parsed.value.object.get("result").?);
}

test "textDocument/definition follows an @import to resolve a cross-file reference" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/helpers.zig","text":"pub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/main.zig","text":"const helpers = @import(\"helpers.zig\");\nfn main() void {\n    _ = helpers.add(1, 2);\n}\n"}}}
    });
    defer opened.deinit();

    // "add" in "helpers.add(1, 2)" is on line 2. "    _ = helpers.add(1, 2);"
    // columns:  0123456789...        "add" starts right after "helpers.".
    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///proj/main.zig"},"position":{"line":2,"character":17}}}
    });
    defer responses.deinit();

    try std.testing.expectEqual(@as(usize, 1), responses.messages.items.len);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("file:///proj/helpers.zig", result.get("uri").?.string);
    const range = result.get("range").?.object;
    try std.testing.expectEqual(@as(i64, 0), range.get("start").?.object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 7), range.get("start").?.object.get("character").?.integer);
}

test "editing an imported file's function body does not recompute the importer's cache (the Phase 6 milestone)" {
    // This is the concrete difference from ZLS's full-reanalysis-per-edit
    // behavior that the whole item-tree/query-cache architecture (project
    // plan §1.2, §1.3) exists to deliver: file B (main.zig) depends on
    // file A (helpers.zig) through a real cross-file reference, proven by
    // resolving it below. Editing A's function body — not its signature —
    // must not touch anything cached for B.
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/helpers.zig","text":"pub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/main.zig","text":"const helpers = @import(\"helpers.zig\");\nfn main() void {\n    _ = helpers.add(1, 2);\n}\n"}}}
    });
    defer opened.deinit();

    // Establish B's cached parse/item-tree entries, and confirm cross-file
    // resolution works before the edit.
    const b_doc_before = server.documents.get("file:///proj/main.zig").?;
    const b_parsed_before = try parse.parse(&server.parse_cache, gpa, "file:///proj/main.zig", b_doc_before.text, b_doc_before.revision);
    const b_tree_before = try item_tree.itemTree(&server.item_tree_cache, gpa, "file:///proj/main.zig", b_parsed_before.ast, b_doc_before.revision);

    var responses_before = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///proj/main.zig"},"position":{"line":2,"character":17}}}
    });
    defer responses_before.deinit();
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses_before.messages.items[0], .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("file:///proj/helpers.zig", parsed.value.object.get("result").?.object.get("uri").?.string);
    }

    // Edit A's body only — same signature, different implementation.
    var changed = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///proj/helpers.zig"},"contentChanges":[{"text":"pub fn add(a: i32, b: i32) i32 {\n    const sum = a + b;\n    return sum;\n}\n"}]}}
    });
    defer changed.deinit();

    // B's own cache entries must be byte-for-byte untouched: same
    // pointers, not just equal values.
    const b_doc_after = server.documents.get("file:///proj/main.zig").?;
    try std.testing.expectEqual(b_doc_before.revision, b_doc_after.revision);
    const b_parsed_after = try parse.parse(&server.parse_cache, gpa, "file:///proj/main.zig", b_doc_after.text, b_doc_after.revision);
    const b_tree_after = try item_tree.itemTree(&server.item_tree_cache, gpa, "file:///proj/main.zig", b_parsed_after.ast, b_doc_after.revision);
    try std.testing.expectEqual(b_parsed_before, b_parsed_after);
    try std.testing.expectEqual(b_tree_before, b_tree_after);

    // And cross-file resolution from B still works correctly afterward,
    // now against A's updated (recomputed) Ast.
    var responses_after = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///proj/main.zig"},"position":{"line":2,"character":17}}}
    });
    defer responses_after.deinit();
    var parsed_after = try std.json.parseFromSlice(std.json.Value, gpa, responses_after.messages.items[0], .{});
    defer parsed_after.deinit();
    try std.testing.expectEqualStrings("file:///proj/helpers.zig", parsed_after.value.object.get("result").?.object.get("uri").?.string);
}

test "publishDiagnostics includes semantic diagnostics for syntactically valid files" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn f() void {\n    const unused = 1;\n}\nfn f() void {}\n"}}}
    });
    defer opened.deinit();

    try std.testing.expectEqual(@as(usize, 1), opened.messages.items.len);
    var diag = try std.json.parseFromSlice(std.json.Value, gpa, opened.messages.items[0], .{});
    defer diag.deinit();

    const items = diag.value.object.get("params").?.object.get("diagnostics").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len); // unused local + duplicate fn

    var saw_warning = false;
    var saw_error = false;
    for (items) |item| {
        const severity = item.object.get("severity").?.integer;
        if (severity == 2) saw_warning = true;
        if (severity == 1) saw_error = true;
    }
    try std.testing.expect(saw_warning);
    try std.testing.expect(saw_error);
}

test "semantic diagnostics are skipped when the file has a syntax error" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn f() void {\n    const unused = ;\n}\n"}}}
    });
    defer opened.deinit();

    var diag = try std.json.parseFromSlice(std.json.Value, gpa, opened.messages.items[0], .{});
    defer diag.deinit();
    const items = diag.value.object.get("params").?.object.get("diagnostics").?.array.items;

    // Only the syntax error itself, not an "unused local" diagnostic
    // riding along on a broken parse.
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expect(std.mem.indexOf(u8, items[0].object.get("message").?.string, "unused") == null);
}

test "textDocument/hover returns a function's signature" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn helper() void {}\nfn main() void {\n    helper();\n}\n"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.zig"},"position":{"line":2,"character":5}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("markdown", result.get("contents").?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("```zig\nfn helper() void\n```", result.get("contents").?.object.get("value").?.string);
}

test "textDocument/hover includes a matching doctest as an Example section" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"test addOne {\n    _ = addOne(41);\n}\n\nfn addOne(number: i32) i32 {\n    return number + 1;\n}\n"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.zig"},"position":{"line":4,"character":4}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const value = parsed.value.object.get("result").?.object.get("contents").?.object.get("value").?.string;
    try std.testing.expect(std.mem.indexOf(u8, value, "fn addOne(number: i32) i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "## Doctest example") != null);
    // The braces and the source file's 4-space body indentation must be
    // stripped: the doctest should appear as a clean, left-aligned
    // "_ = addOne(41);" line, not "{\n    _ = addOne(41);\n}".
    try std.testing.expect(std.mem.indexOf(u8, value, "_ = addOne(41);") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "{\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, value, "    _ = addOne") == null);
}

test "textDocument/documentSymbol lists top-level declarations" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn f() void {}\nconst x = 1;\n"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///a.zig"}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("f", items[0].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 12), items[0].object.get("kind").?.integer); // Function
    try std.testing.expectEqualStrings("x", items[1].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 13), items[1].object.get("kind").?.integer); // Variable
}

test "workspace/symbol searches across all open files" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn findMe() void {}\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///b.zig","text":"const other = 1;\n"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"workspace/symbol","params":{"query":"find"}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("findMe", items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("file:///a.zig", items[0].object.get("location").?.object.get("uri").?.string);
}

test "textDocument/completion offers keywords, top-level items, and in-scope locals" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn helper() void {}\nfn main() void {\n    const local = 1;\n    \n}\n"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///a.zig"},"position":{"line":3,"character":4}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("result").?.array.items;

    var saw_keyword = false;
    var saw_top_level = false;
    var saw_local = false;
    for (items) |item| {
        const label = item.object.get("label").?.string;
        if (std.mem.eql(u8, label, "const")) saw_keyword = true;
        if (std.mem.eql(u8, label, "helper")) saw_top_level = true;
        if (std.mem.eql(u8, label, "local")) saw_local = true;
    }
    try std.testing.expect(saw_keyword);
    try std.testing.expect(saw_top_level);
    try std.testing.expect(saw_local);
}

test "textDocument/formatting formats via the default zig fmt --stdin" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"const x=1;"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///a.zig"},"options":{"tabSize":4,"insertSpaces":true}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const edits = parsed.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), edits.len);
    try std.testing.expectEqualStrings("const x = 1;\n", edits[0].object.get("newText").?.string);
}

test "textDocument/formatting reports an error for unformattable source" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"const x = ;"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///a.zig"},"options":{"tabSize":4,"insertSpaces":true}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.contains("error"));
}

test "initializationOptions can override the formatter command and args" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    // "cmd" here isn't real, but exercises that the override actually
    // takes effect: the default `zig fmt --stdin` would succeed on this
    // valid source, so if the override wasn't applied this'd format
    // cleanly instead of failing to launch.
    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"initializationOptions":{"formatter":{"command":"this-formatter-does-not-exist-anywhere","args":[]}}}}
    });
    defer responses.deinit();

    try std.testing.expectEqualStrings("this-formatter-does-not-exist-anywhere", server.formatter_config.command);
    try std.testing.expectEqual(@as(usize, 0), server.formatter_config.args.len);
    try std.testing.expect(server.formatter_config_owned);
}

test "workspace/didChangeConfiguration updates the formatter live" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    try std.testing.expectEqualStrings("zig", server.formatter_config.command);

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"workspace/didChangeConfiguration","params":{"settings":{"formatter":{"command":"my-custom-formatter","args":["--stdin-mode"]}}}}
    });
    defer responses.deinit();

    try std.testing.expectEqualStrings("my-custom-formatter", server.formatter_config.command);
    try std.testing.expectEqual(@as(usize, 1), server.formatter_config.args.len);
    try std.testing.expectEqualStrings("--stdin-mode", server.formatter_config.args[0]);
}

test "textDocument/semanticTokens/full advertises a legend and returns delta-encoded data" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var init_responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    });
    defer init_responses.deinit();
    var init_parsed = try std.json.parseFromSlice(std.json.Value, gpa, init_responses.messages.items[0], .{});
    defer init_parsed.deinit();
    const legend = init_parsed.value.object.get("result").?.object.get("capabilities").?.object
        .get("semanticTokensProvider").?.object.get("legend").?.object;
    try std.testing.expectEqual(@as(usize, 3), legend.get("tokenTypes").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 2), legend.get("tokenModifiers").?.array.items.len);

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"file:///a.zig"}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const data = parsed.value.object.get("result").?.object.get("data").?.array.items;
    // 3 tokens (fn name + 2 params) * 5 u32s each.
    try std.testing.expectEqual(@as(usize, 15), data.len);
    // First token: function "add" at line 0, character 3, length 3, type 0 (function), modifier bit 0 (declaration).
    try std.testing.expectEqual(@as(i64, 0), data[0].integer);
    try std.testing.expectEqual(@as(i64, 3), data[1].integer);
    try std.testing.expectEqual(@as(i64, 3), data[2].integer);
    try std.testing.expectEqual(@as(i64, 0), data[3].integer);
    try std.testing.expectEqual(@as(i64, 1), data[4].integer);
}

test "textDocument/references finds every call site, excluding the declaration by default" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn helper() void {}\nfn a() void {\n    helper();\n}\nfn b() void {\n    helper();\n}\n"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/references","params":{"textDocument":{"uri":"file:///a.zig"},"position":{"line":0,"character":3},"context":{"includeDeclaration":false}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(i64, 2), items[0].object.get("range").?.object.get("start").?.object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 5), items[1].object.get("range").?.object.get("start").?.object.get("line").?.integer);
}

test "textDocument/references with includeDeclaration adds the declaration site" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn helper() void {}\nfn a() void {\n    helper();\n}\n"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/references","params":{"textDocument":{"uri":"file:///a.zig"},"position":{"line":0,"character":3},"context":{"includeDeclaration":true}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
}

test "textDocument/rename produces a WorkspaceEdit renaming every occurrence" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn helper() void {}\nfn main() void {\n    helper();\n}\n"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///a.zig"},"position":{"line":0,"character":3},"newName":"renamedHelper"}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const changes = parsed.value.object.get("result").?.object.get("changes").?.object;
    const edits = changes.get("file:///a.zig").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), edits.len);
    for (edits) |edit| {
        try std.testing.expectEqualStrings("renamedHelper", edit.object.get("newText").?.string);
    }
}

test "textDocument/rename rejects an invalid identifier" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn helper() void {}\n"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///a.zig"},"position":{"line":0,"character":3},"newName":"3invalid"}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.contains("error"));
}

test "textDocument/signatureHelp reports the signature and active parameter" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\nfn main() void {\n    _ = add(1, 2);\n}\n"}}}
    });
    defer opened.deinit();

    // Cursor right after "add(1, " — on the second argument.
    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":"file:///a.zig"},"position":{"line":4,"character":15}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(i64, 1), result.get("activeParameter").?.integer);
    const signatures = result.get("signatures").?.array.items;
    try std.testing.expectEqualStrings("fn add(a: i32, b: i32) i32", signatures[0].object.get("label").?.string);
}

test "textDocument/signatureHelp works across files via @import" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/helpers.zig","text":"pub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/main.zig","text":"const helpers = @import(\"helpers.zig\");\nfn main() void {\n    _ = helpers.add(1, 2);\n}\n"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":"file:///proj/main.zig"},"position":{"line":2,"character":23}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const signatures = parsed.value.object.get("result").?.object.get("signatures").?.array.items;
    try std.testing.expectEqualStrings("pub fn add(a: i32, b: i32) i32", signatures[0].object.get("label").?.string);
}
