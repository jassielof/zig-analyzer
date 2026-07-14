//! LSP lifecycle: `initialize` / `initialized` / `shutdown` / `exit`. This
//! is transport-agnostic — it only reads/writes JSON-RPC message bodies via
//! `protocol.jsonrpc`, so the same `Server` drives both the real stdio loop
//! (`cli/main.zig`) and the in-process test harness
//! (`protocol/harness.zig`).

const std = @import("std");
const Io = std.Io;
const Ast = std.zig.Ast;
const build_options = @import("build_options");
const jsonrpc = @import("jsonrpc").jsonrpc;
const documents = @import("documents.zig");
const parse = @import("analysis/queries/parse.zig");
const item_tree = @import("analysis/queries/item_tree.zig");
const resolve = @import("analysis/queries/resolve.zig");
const imports = @import("analysis/queries/imports.zig");
const packages_mod = @import("analysis/queries/packages.zig");
const formatting = @import("formatting.zig");
const uri_util = @import("uri.zig");
const scope_mod = @import("analysis/queries/scope.zig");
const resolve_expr = @import("analysis/queries/resolve_expr.zig");
const lifecycle = @import("features/lifecycle.zig");
const sync = @import("features/sync.zig");
const symbol = @import("features/symbol.zig");
const format_feature = @import("features/format.zig");
const semantic_tokens_feature = @import("features/semantic_tokens.zig");
const completion_feature = @import("features/completion.zig");
const references_feature = @import("features/references.zig");
const rename_feature = @import("features/rename.zig");
const code_lens_feature = @import("features/code_lens.zig");
const definition_feature = @import("features/definition.zig");
const hover_feature = @import("features/hover.zig");
const signature_help_feature = @import("features/signature_help.zig");
const inlay_hint_feature = @import("features/inlay_hint.zig");

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

// Shared LSP response-shape types, used across nearly every `features/*.zig`
// handler — hoisted out of `Server` (module-level, not struct-nested) so
// they're referenced the same way (`server.Position`) from any file.
pub const Position = struct { line: u32, character: u32 };
pub const Range = struct { start: Position, end: Position };

pub const Server = struct {
    // Zig struct fields have no privacy modifier (only `fn`/`const`/`var`
    // declarations do) — every field below is already reachable from
    // `features/*.zig` handler files given a `*Server`. Only *methods*
    // called cross-file need an explicit `pub`.
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
    /// Path to the `zig` executable used for `zig env` (stdlib discovery)
    /// and as the default formatter command. Owned when set via options;
    /// otherwise the `"zig"` literal.
    zig_exe: []const u8 = "zig",
    zig_exe_owned: bool = false,
    /// Absolute path to Zig's `lib/` directory, discovered via `zig env`.
    /// Used to resolve `@import("std")` to the local stdlib. Owned.
    zig_lib_dir: ?[]const u8 = null,
    /// Zig's global package cache (`…/zig`), from `zig env`. Owned.
    zig_global_cache_dir: ?[]const u8 = null,
    /// Path-based packages from workspace `build.zig.zon` files. Owned keys/values.
    packages: packages_mod.PackageMap = .empty,
    /// Whether any workspace root currently has a `build.zig` (build-script
    /// mode). False means freestanding: relative/`std` imports only.
    workspace_has_build_zig: bool = false,
    /// Inlay hint settings (mirrored from VS Code `zigAnalyzer.inlayHints.*`).
    inlay_hints_enable: bool = true,
    inlay_hints_parameter_names: bool = true,
    inlay_hints_exclude_single_argument: bool = true,
    inlay_hints_types: bool = true,
    /// Whether the client can accept `LocationLink[]` (with a wider
    /// `originSelectionRange`) instead of plain `Location[]` for
    /// `textDocument/definition` — from the client's declared
    /// `capabilities.textDocument.definition.linkSupport`. Needed so an
    /// `@import("a/b.zig")` string's whole path underlines as one span
    /// on ctrl+hover, not per word-boundary fragment.
    definition_link_support: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: Io) Server {
        return .{ .gpa = gpa, .io = io, .documents = .init(gpa) };
    }

    pub fn deinit(self: *Server) void {
        self.documents.deinit();
        self.parse_cache.deinit(self.gpa);
        self.item_tree_cache.deinit(self.gpa);
        self.freeFormatterConfigIfOwned();
        if (self.zig_exe_owned) self.gpa.free(self.zig_exe);
        if (self.zig_lib_dir) |d| self.gpa.free(d);
        if (self.zig_global_cache_dir) |d| self.gpa.free(d);
        packages_mod.clearPackages(self.gpa, &self.packages);
        self.packages.deinit(self.gpa);
    }

    pub fn findImportsFor(self: *Server, ast: Ast, importer_uri: []const u8) ![]const imports.Import {
        self.ensurePackagesForUri(importer_uri);
        return imports.findImports(self.gpa, ast, importer_uri, self.zig_lib_dir, &self.packages);
    }

    pub fn freeFormatterConfigIfOwned(self: *Server) void {
        if (!self.formatter_config_owned) return;
        self.gpa.free(self.formatter_config.command);
        for (self.formatter_config.args) |arg| self.gpa.free(arg);
        self.gpa.free(self.formatter_config.args);
        self.formatter_config_owned = false;
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
            try lifecycle.handleInitialize(self, writer, msg);
        } else if (std.mem.eql(u8, msg.method, "initialized")) {
            lifecycle.handleInitialized(self, msg);
        } else if (std.mem.eql(u8, msg.method, "shutdown")) {
            try lifecycle.handleShutdown(self, writer, msg);
        } else if (std.mem.eql(u8, msg.method, "exit")) {
            lifecycle.handleExit(self);
        } else if (std.mem.eql(u8, msg.method, "textDocument/didOpen")) {
            sync.handleDidOpen(self, writer, msg) catch |err| std.log.err("textDocument/didOpen: {t}", .{err});
        } else if (std.mem.eql(u8, msg.method, "textDocument/didChange")) {
            sync.handleDidChange(self, writer, msg) catch |err| std.log.err("textDocument/didChange: {t}", .{err});
        } else if (std.mem.eql(u8, msg.method, "textDocument/didClose")) {
            sync.handleDidClose(self, writer, msg) catch |err| std.log.err("textDocument/didClose: {t}", .{err});
        } else if (std.mem.eql(u8, msg.method, "textDocument/definition")) {
            try definition_feature.handleDefinition(self, writer, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/hover")) {
            try hover_feature.handleHover(self, writer, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/documentSymbol")) {
            try symbol.handleDocumentSymbol(self, writer, msg);
        } else if (std.mem.eql(u8, msg.method, "workspace/symbol")) {
            try symbol.handleWorkspaceSymbol(self, writer, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/completion")) {
            try completion_feature.handleCompletion(self, writer, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/formatting")) {
            try format_feature.handleFormatting(self, writer, msg);
        } else if (std.mem.eql(u8, msg.method, "workspace/didChangeConfiguration")) {
            lifecycle.handleDidChangeConfiguration(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/semanticTokens/full")) {
            try semantic_tokens_feature.handleSemanticTokensFull(self, writer, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/references")) {
            try references_feature.handleReferences(self, writer, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/rename")) {
            try rename_feature.handleRename(self, writer, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/signatureHelp")) {
            try signature_help_feature.handleSignatureHelp(self, writer, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/codeLens")) {
            try code_lens_feature.handleCodeLens(self, writer, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/inlayHint")) {
            try inlay_hint_feature.handleInlayHint(self, writer, msg);
        } else if (msg.isNotification()) {
            // Unknown notifications are silently ignored, per spec.
        } else if (self.phase == .uninitialized) {
            try jsonrpc.writeError(writer, self.gpa, msg.id.?, .server_not_initialized, "server not initialized");
        } else {
            try jsonrpc.writeError(writer, self.gpa, msg.id.?, .method_not_found, msg.method);
        }
    }

    /// If packages aren't loaded yet (e.g. initialize had no workspace
    /// folders), discover them by walking up from this file's directory.
    pub fn ensurePackagesForUri(self: *Server, uri: []const u8) void {
        if (self.packages.count() > 0 or self.workspace_has_build_zig) return;
        const path = uri_util.toFsPath(self.gpa, uri) catch return;
        defer self.gpa.free(path);
        if (packages_mod.loadDepsWalkingUpFromFile(self.gpa, self.io, path, self.zig_global_cache_dir, &self.packages)) |_| {
            self.workspace_has_build_zig = self.packages.count() > 0 or
                packages_mod.fileHasAncestorBuildZig(self.io, path);
        } else |err| {
            std.log.err("failed to load packages near {s}: {t}", .{ path, err });
        }
    }

    pub const ParsedUri = struct {
        ast: Ast,
        /// When non-null, `ast` was parsed from a freshly-read disk file
        /// (not the document store / parse cache) and must be freed.
        owned_source: ?[:0]u8 = null,
        owned_ast: bool = false,

        pub fn deinit(self: ParsedUri, server: *Server) void {
            if (self.owned_ast) {
                var ast = self.ast;
                ast.deinit(server.gpa);
            }
            if (self.owned_source) |s| server.gpa.free(s);
        }
    };

    /// Returns a parsed AST for `target_uri`: from the open-document
    /// cache when the client has it open, otherwise by reading the file
    /// from disk (needed for stdlib / closed relative imports).
    pub fn parseUri(self: *Server, target_uri: []const u8) !?ParsedUri {
        if (self.documents.get(target_uri)) |doc| {
            const parsed_file = try parse.parse(&self.parse_cache, self.gpa, target_uri, doc.text, doc.revision);
            return .{ .ast = parsed_file.ast };
        }

        const path = uri_util.toFsPath(self.gpa, target_uri) catch return null;
        defer self.gpa.free(path);

        var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return null;
        defer file.close(self.io);

        var read_buf: [4096]u8 = undefined;
        var file_reader: Io.File.Reader = .init(file, self.io, &read_buf);
        const source = std.zig.readSourceFileToEndAlloc(self.gpa, &file_reader) catch return null;
        errdefer self.gpa.free(source);

        const ast = try Ast.parse(self.gpa, source, .zig);
        return .{ .ast = ast, .owned_source = source, .owned_ast = true };
    }

    pub const AnyDefinition = struct {
        uri: []const u8,
        def: resolve.Definition,
        /// When true, `def.signature` was allocated with `gpa` and must be freed
        /// with `freeAnyDefinition`. Cross-file disk resolves own their signature
        /// because the underlying AST is freed before the result is used.
        signature_owned: bool = false,
    };

    pub fn freeAnyDefinition(self: *Server, any: AnyDefinition) void {
        self.gpa.free(any.uri);
        if (any.signature_owned) self.gpa.free(any.def.signature);
    }

    /// Shared by `textDocument/definition` and `textDocument/hover`: both
    /// need to resolve a position to a declaration, one to show its
    /// location, the other its signature. Tries local resolution first
    /// (params, immediate-body locals, this file's item tree), then
    /// cross-file via `@import` bindings and dotted field chains
    /// (`std.fmt`, `std.debug.print`). The returned `uri` is always an
    /// owned copy — same-file or cross-file — so callers have exactly one
    /// ownership rule to follow.
    pub fn resolveRequestPosition(self: *Server, uri: []const u8, position: Position) !?AnyDefinition {
        const doc = self.documents.get(uri) orelse return null;
        const parsed_file = try parse.parse(&self.parse_cache, self.gpa, uri, doc.text, doc.revision);
        const tree = try item_tree.itemTree(&self.item_tree_cache, self.gpa, uri, parsed_file.ast, doc.revision);
        const pos: resolve.Position = .{ .line = position.line, .character = position.character };

        // `@This()` → enclosing container (file root or nested named struct).
        if (try self.resolveThisAt(uri, parsed_file.ast, pos)) |def| {
            return def;
        }

        if (resolve.resolveAt(parsed_file.ast, tree.*, pos)) |def| {
            return .{ .uri = try self.gpa.dupe(u8, uri), .def = def };
        }

        // Prefer a full dotted chain so `std.debug.print` and `std.fmt`
        // resolve through re-exports, including into closed stdlib files.
        if (try resolve.fieldAccessChainAt(self.gpa, parsed_file.ast, pos)) |chain| {
            defer self.gpa.free(chain);
            if (chain.len >= 2) {
                if (try self.resolveFieldChain(uri, parsed_file.ast, chain)) |cross| {
                    return cross;
                }
                // Typed member access: `b.addExecutable` where `b: *std.Build`,
                // or `list.append` where `list` is an ArrayList instance.
                if (try self.resolveTypedMemberAccess(uri, parsed_file.ast, pos, chain)) |cross| {
                    return cross;
                }
            }
        }
        return null;
    }

    fn resolveThisAt(self: *Server, uri: []const u8, ast: Ast, pos: resolve.Position) !?AnyDefinition {
        const offset = resolve.positionToOffset(ast.source, pos);
        const tok = resolve.builtinTokenAt(ast, offset) orelse return null;
        if (!std.mem.eql(u8, ast.tokenSlice(tok), "@This")) return null;

        const enc = resolve.enclosingContainerAt(ast, offset);
        if (enc.owner_node) |owner| {
            const var_decl = ast.fullVarDecl(owner) orelse return null;
            const name_token = var_decl.ast.mut_token + 1;
            const loc = ast.tokenLocation(0, name_token);
            const name = ast.tokenSlice(name_token);
            return .{
                .uri = try self.gpa.dupe(u8, uri),
                .def = .{
                    .line = @intCast(loc.line),
                    .character = @intCast(loc.column),
                    .end_character = @intCast(loc.column + name.len),
                    .signature = try self.gpa.dupe(u8, name),
                },
                .signature_owned = true,
            };
        }

        // File-level `@This()` → start of file / container docs.
        return .{
            .uri = try self.gpa.dupe(u8, uri),
            .def = .{
                .line = 0,
                .character = 0,
                .end_character = 0,
                .signature = try self.gpa.dupe(u8, "@This()"),
            },
            .signature_owned = true,
        };
    }

    /// Request-local scratch for typed resolution (keeps disk ASTs alive).
    pub const TypeScratch = struct {
        server: *Server,
        loaded: std.ArrayList(ParsedUri) = .empty,

        pub fn deinit(self: *TypeScratch) void {
            for (self.loaded.items) |p| p.deinit(self.server);
            self.loaded.deinit(self.server.gpa);
        }

        fn loadFile(ctx: *resolve_expr.Context, target_uri: []const u8) ?Ast {
            const scratch: *TypeScratch = @ptrCast(@alignCast(ctx.userdata.?));
            const server = scratch.server;
            if (server.documents.get(target_uri)) |doc| {
                const parsed = parse.parse(&server.parse_cache, server.gpa, target_uri, doc.text, doc.revision) catch return null;
                return parsed.ast;
            }
            const parsed = (server.parseUri(target_uri) catch return null) orelse return null;
            if (parsed.owned_ast) {
                scratch.loaded.append(server.gpa, parsed) catch {
                    parsed.deinit(server);
                    return null;
                };
                return parsed.ast;
            }
            return parsed.ast;
        }
    };

    pub fn makeExprContext(
        self: *Server,
        scratch: *TypeScratch,
        uri: []const u8,
        ast: Ast,
        scopes: scope_mod.ScopeTree,
    ) resolve_expr.Context {
        return .{
            .gpa = self.gpa,
            .uri = uri,
            .ast = ast,
            .scopes = scopes,
            .zig_lib_dir = self.zig_lib_dir,
            .packages = &self.packages,
            .loadFile = TypeScratch.loadFile,
            .userdata = scratch,
        };
    }

    /// `base.field` where `base` has a resolved type (param annotation,
    /// generic instance, …).
    pub fn resolveTypedMemberAccess(
        self: *Server,
        uri: []const u8,
        ast: Ast,
        pos: resolve.Position,
        chain: []const []const u8,
    ) !?AnyDefinition {
        if (chain.len < 2) return null;

        var scopes = try scope_mod.build(self.gpa, ast);
        defer scopes.deinit();

        var scratch: TypeScratch = .{ .server = self };
        defer scratch.deinit();

        var ctx = self.makeExprContext(&scratch, uri, ast, scopes);
        defer ctx.deinitScratch();

        const offset = resolve.positionToOffset(ast.source, pos);

        // Multi-hop: resolve types left-to-right, then member-lookup the tip.
        // For `b.addExecutable`, chain is [b, addExecutable].
        // For `list.append`, chain is [list, append].
        if (chain.len == 2) {
            const member = try resolve_expr.resolveMemberAccess(&ctx, chain[0], chain[1], offset) orelse return null;
            const sig = try self.gpa.dupe(u8, member.signature);
            return .{
                .uri = try self.gpa.dupe(u8, member.uri),
                .def = .{
                    .line = member.line,
                    .character = member.character,
                    .end_character = member.end_character,
                    .signature = sig,
                },
                .signature_owned = true,
            };
        }

        // Longer chains: type-resolve through intermediate hops as type vals,
        // then member-lookup the last field on the resulting type.
        var ty = try resolve_expr.resolveIdentType(&ctx, chain[0], offset, false) orelse return null;
        var i: usize = 1;
        while (i + 1 < chain.len) : (i += 1) {
            ty = try resolve_expr.lookupMemberType(&ctx, ty, chain[i], true) orelse return null;
        }
        const member = try resolve_expr.memberResult(&ctx, ty, chain[chain.len - 1]) orelse return null;
        const sig = try self.gpa.dupe(u8, member.signature);
        return .{
            .uri = try self.gpa.dupe(u8, member.uri),
            .def = .{
                .line = member.line,
                .character = member.character,
                .end_character = member.end_character,
                .signature = sig,
            },
            .signature_owned = true,
        };
    }

    pub const CrossFileDefinition = AnyDefinition;

    /// Walks `chain` (outermost→innermost, e.g. `["std","debug","print"]`)
    /// starting from an `@import` binding in `importer_ast`. Intermediate
    /// hops that are themselves `@import("…")` re-exports are followed into
    /// the imported file (loaded from disk when not open). The final name
    /// resolves to a top-level definition in the file reached.
    pub fn resolveFieldChain(
        self: *Server,
        importer_uri: []const u8,
        importer_ast: Ast,
        chain: []const []const u8,
    ) !?CrossFileDefinition {
        if (chain.len < 2) return null;

        const imports_list = try self.findImportsFor(importer_ast, importer_uri);
        defer imports.freeImports(self.gpa, imports_list);

        var current_uri: ?[]const u8 = null;
        for (imports_list) |imp| {
            if (!std.mem.eql(u8, imp.name, chain[0])) continue;
            current_uri = imp.uri;
            break;
        }
        var owned_uri: []const u8 = try self.gpa.dupe(u8, current_uri orelse return null);
        var uri_consumed = false;
        defer if (!uri_consumed) self.gpa.free(owned_uri);

        var hop: usize = 1;
        while (hop < chain.len) : (hop += 1) {
            const name = chain[hop];
            const parsed = try self.parseUri(owned_uri) orelse return null;
            defer parsed.deinit(self);

            // Last hop: resolve the definition (and optionally follow a
            // final re-export for go-to-def / hover on module namespaces).
            if (hop + 1 == chain.len) {
                if (try imports.rootDeclImportPath(self.gpa, parsed.ast, name)) |rel| {
                    defer self.gpa.free(rel);
                    const next = (try imports.resolveImportUri(self.gpa, owned_uri, rel, self.zig_lib_dir, &self.packages)) orelse return null;
                    errdefer self.gpa.free(next);
                    const sig = try std.fmt.allocPrint(self.gpa, "@import(\"{s}\")", .{rel});
                    self.gpa.free(owned_uri);
                    owned_uri = next;
                    uri_consumed = true;
                    return .{
                        .uri = owned_uri,
                        .def = .{ .line = 0, .character = 0, .end_character = 0, .signature = sig },
                        .signature_owned = true,
                    };
                }

                var tree = try item_tree.build(self.gpa, parsed.ast);
                defer tree.deinit(self.gpa);
                const def = resolve.resolveTopLevel(parsed.ast, tree, name) orelse return null;
                // Definition borrows signature from the AST — copy it before
                // `parsed` is deinited.
                const sig = try self.gpa.dupe(u8, def.signature);
                uri_consumed = true;
                return .{
                    .uri = owned_uri,
                    .def = .{
                        .line = def.line,
                        .character = def.character,
                        .end_character = def.end_character,
                        .signature = sig,
                    },
                    .signature_owned = true,
                };
            }

            // Intermediate hop must be an `@import` re-export.
            const rel = (try imports.rootDeclImportPath(self.gpa, parsed.ast, name)) orelse return null;
            defer self.gpa.free(rel);
            const next = (try imports.resolveImportUri(self.gpa, owned_uri, rel, self.zig_lib_dir, &self.packages)) orelse return null;
            self.gpa.free(owned_uri);
            owned_uri = next;
        }
        return null;
    }

    /// Follows a single `base.field` access for callers that still use
    /// `FieldAccess` (signature help / inlay). Delegates to the chain walker.
    /// The identifier text at a `Definition`'s own location — re-sliced
    /// from source via its line/character span, since `Definition`
    /// carries a signature (which for functions is more than just the
    /// name) but not the bare name itself.
    pub fn nameOfDefinition(ast: Ast, def: resolve.Definition) []const u8 {
        const start = resolve.positionToOffset(ast.source, .{ .line = def.line, .character = def.character });
        const end = resolve.positionToOffset(ast.source, .{ .line = def.line, .character = def.end_character });
        return ast.source[start..end];
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
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","languageId":"zig","version":1,"text":"pub const x = 1;"}}}
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
    try std.testing.expectEqualStrings("pub const x = 1;", after_open.text);
    const revision_after_open = after_open.revision;

    var changed = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.zig","version":2},"contentChanges":[{"text":"pub const x = 2;"}]}}
    });
    defer changed.deinit();

    const after_change = server.documents.get("file:///a.zig").?;
    try std.testing.expectEqualStrings("pub const x = 2;", after_change.text);
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

test "textDocument/definition returns a LocationLink spanning the whole import path when the client supports it" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var init_responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"capabilities":{"textDocument":{"definition":{"linkSupport":true}}}}}
    });
    defer init_responses.deinit();
    try std.testing.expect(server.definition_link_support);

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/commands/check.zig","text":"pub fn run() void {}\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/main.zig","text":"const check_command = @import(\"commands/check.zig\");\n"}}}
    });
    defer opened.deinit();

    // Cursor on "check" inside "commands/check.zig" — mid-path, the exact
    // spot that used to underline only "check" and "zig" as two separate
    // word fragments instead of the whole path.
    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///proj/main.zig"},"position":{"line":0,"character":42}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const links = parsed.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), links.len);
    const link = links[0].object;
    try std.testing.expectEqualStrings("file:///proj/commands/check.zig", link.get("targetUri").?.string);

    const origin = link.get("originSelectionRange").?.object;
    const start_char = origin.get("start").?.object.get("character").?.integer;
    const end_char = origin.get("end").?.object.get("character").?.integer;
    try std.testing.expectEqual(@as(i64, "commands/check.zig".len), end_char - start_char); // whole path, not one word
}

test "textDocument/definition on an import binding's declaration redirects to the imported file" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/helpers.zig","text":"pub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/main.zig","text":"const helpers = @import(\"helpers.zig\");\nfn main() void {\n    _ = helpers.add(1, 2);\n}\n"}}}
    });
    defer opened.deinit();

    // "helpers" in "const helpers = @import(...)" itself, at character 6.
    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///proj/main.zig"},"position":{"line":0,"character":8}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("file:///proj/helpers.zig", result.get("uri").?.string);
    try std.testing.expectEqual(@as(i64, 0), result.get("range").?.object.get("start").?.object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 0), result.get("range").?.object.get("start").?.object.get("character").?.integer);
}

test "textDocument/definition on a bare later use of an import binding redirects to the imported file" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/helpers.zig","text":"pub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/main.zig","text":"const helpers = @import(\"helpers.zig\");\nfn main() void {\n    _ = helpers;\n}\n"}}}
    });
    defer opened.deinit();

    // "helpers" in "_ = helpers;" — a bare reference, not the base of a
    // dotted access, so it redirects straight into the imported file.
    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///proj/main.zig"},"position":{"line":2,"character":9}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("file:///proj/helpers.zig", result.get("uri").?.string);
}

test "textDocument/definition on the base of a dotted access stops at the local import binding" {
    // The base of `helpers.add(...)` isn't itself a further-resolvable
    // reference the way its field (`add`) is — clicking it should show
    // where `helpers` is bound in *this* file, matching how e.g. Go
    // tooling treats `pkg.Symbol`: clicking `pkg` goes to the import,
    // clicking `Symbol` goes to its real declaration.
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/helpers.zig","text":"pub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/main.zig","text":"const helpers = @import(\"helpers.zig\");\nfn main() void {\n    _ = helpers.add(1, 2);\n}\n"}}}
    });
    defer opened.deinit();

    // "helpers" in "helpers.add(1, 2)" (not "add" itself), at character 10.
    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///proj/main.zig"},"position":{"line":2,"character":10}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("file:///proj/main.zig", result.get("uri").?.string);
    const range = result.get("range").?.object;
    try std.testing.expectEqual(@as(i64, 0), range.get("start").?.object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 6), range.get("start").?.object.get("character").?.integer);
}

test "textDocument/definition on a field of a dotted import access resolves into the imported file" {
    // The other half of the same distinction: `Shell` (the field) in
    // `completions.Shell` should resolve through the `completions`
    // binding into its *real* declaration in the imported file, not the
    // local re-export line that happens to share its name.
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/completions.zig","text":"pub const Shell = enum { bash, zsh, fish };\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/main.zig","text":"const completions = @import(\"completions.zig\");\npub const Shell = completions.Shell;\n"}}}
    });
    defer opened.deinit();

    // "Shell" field in "completions.Shell", at character 30.
    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///proj/main.zig"},"position":{"line":1,"character":30}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("file:///proj/completions.zig", result.get("uri").?.string);
    const range = result.get("range").?.object;
    try std.testing.expectEqual(@as(i64, 0), range.get("start").?.object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 10), range.get("start").?.object.get("character").?.integer); // "pub const Shell" -> 'S' at col 10
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

    var saw_hint = false;
    var saw_error = false;
    for (items) |item| {
        const severity = item.object.get("severity").?.integer;
        if (severity == 4) saw_hint = true; // unused → Hint + Unnecessary tag
        if (severity == 1) saw_error = true;
    }
    try std.testing.expect(saw_hint);
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

test "textDocument/hover includes /// doc comments" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"/// Adds one to a number.\nfn addOne(n: i32) i32 {\n    return n + 1;\n}\nfn main() void {\n    _ = addOne(1);\n}\n"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.zig"},"position":{"line":5,"character":9}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const value = parsed.value.object.get("result").?.object.get("contents").?.object.get("value").?.string;
    try std.testing.expect(std.mem.indexOf(u8, value, "fn addOne(n: i32) i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "Adds one to a number.") != null);
}

test "textDocument/hover on import binding shows container docs" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/helpers.zig","text":"//! Math helpers.\n\npub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/main.zig","text":"const helpers = @import(\"helpers.zig\");\nfn main() void {\n    _ = helpers.add(1, 2);\n}\n"}}}
    });
    defer opened.deinit();

    // Hover the binding name `helpers` on the const line.
    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///proj/main.zig"},"position":{"line":0,"character":8}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const value = parsed.value.object.get("result").?.object.get("contents").?.object.get("value").?.string;
    try std.testing.expect(std.mem.indexOf(u8, value, "Math helpers.") != null);

    // Hover the `"helpers.zig"` string itself.
    var responses2 = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///proj/main.zig"},"position":{"line":0,"character":28}}}
    });
    defer responses2.deinit();

    var parsed2 = try std.json.parseFromSlice(std.json.Value, gpa, responses2.messages.items[0], .{});
    defer parsed2.deinit();
    const value2 = parsed2.value.object.get("result").?.object.get("contents").?.object.get("value").?.string;
    try std.testing.expect(std.mem.indexOf(u8, value2, "@import(\"helpers.zig\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, value2, "Math helpers.") != null);
}

test "textDocument/definition on import string jumps to the imported file" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/helpers.zig","text":"pub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/main.zig","text":"const helpers = @import(\"helpers.zig\");\n"}}}
    });
    defer opened.deinit();

    // Cursor on the 'h' of "helpers.zig" inside the string literal.
    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///proj/main.zig"},"position":{"line":0,"character":26}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("file:///proj/helpers.zig", result.get("uri").?.string);
    try std.testing.expectEqual(@as(i64, 0), result.get("range").?.object.get("start").?.object.get("line").?.integer);
}

test "textDocument/hover on @import(\"std\") uses local stdlib docs" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    // Discover zig_lib_dir via `zig env`.
    var init_responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    });
    defer init_responses.deinit();
    try std.testing.expect(server.zig_lib_dir != null);

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/main.zig","text":"const std = @import(\"std\");\n"}}}
    });
    defer opened.deinit();

    // Hover the "std" string inside @import("std").
    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///proj/main.zig"},"position":{"line":0,"character":22}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    // std.zig itself may not have //! docs; the hover must at least
    // resolve and show the @import signature rather than returning null.
    const result = parsed.value.object.get("result");
    try std.testing.expect(result != null and result.? != .null);
    const value = result.?.object.get("contents").?.object.get("value").?.string;
    try std.testing.expect(std.mem.indexOf(u8, value, "@import(\"std\")") != null);

    // Go-to-definition on the string must land in the local stdlib.
    var def_responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///proj/main.zig"},"position":{"line":0,"character":22}}}
    });
    defer def_responses.deinit();
    var def_parsed = try std.json.parseFromSlice(std.json.Value, gpa, def_responses.messages.items[0], .{});
    defer def_parsed.deinit();
    const def_uri = def_parsed.value.object.get("result").?.object.get("uri").?.string;
    try std.testing.expect(std.mem.indexOf(u8, def_uri, "/std/std.zig") != null);
    try std.testing.expect(std.mem.startsWith(u8, def_uri, "file://"));
}

test "textDocument/hover on std.fmt shows stdlib container docs from disk" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var init_responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    });
    defer init_responses.deinit();
    try std.testing.expect(server.zig_lib_dir != null);

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/main.zig","text":"const std = @import(\"std\");\nfn main() void {\n    _ = std.fmt;\n}\n"}}}
    });
    defer opened.deinit();

    // Hover `fmt` in `std.fmt` — fmt.zig is not open; must load from disk
    // and follow `pub const fmt = @import("fmt.zig")`.
    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///proj/main.zig"},"position":{"line":2,"character":13}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result");
    try std.testing.expect(result != null and result.? != .null);
    const value = result.?.object.get("contents").?.object.get("value").?.string;
    try std.testing.expect(std.mem.indexOf(u8, value, "String formatting and parsing.") != null);
}

test "textDocument/hover on a plain alias shows the aliased target's doc comment" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/target.zig","text":"/// Real doc.\npub const Real = struct {};\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/main.zig","text":"const target = @import(\"target.zig\");\nconst Alias = target.Real;\n"}}}
    });
    defer opened.deinit();

    // Hovering "Alias" itself — the alias line has no doc comment of its
    // own — should still show "Real doc." via the aliased target.
    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///proj/main.zig"},"position":{"line":1,"character":7}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result");
    try std.testing.expect(result != null and result.? != .null);
    const value = result.?.object.get("contents").?.object.get("value").?.string;
    try std.testing.expect(std.mem.indexOf(u8, value, "Real doc.") != null);
}

test "textDocument/hover on an @import string excludes the surrounding quotes from its range" {
    // No `documentLinkProvider` (neither zls nor zigscient implement it —
    // its persistent underline styling was exactly the "always
    // underlined, even the quotes" bug this range covers instead):
    // go-to-definition + hover already handle `@import("...")` strings,
    // and VS Code's ctrl+hover underline is driven by the position a
    // definition/hover request resolves at, not a link decoration.
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/commands/check.zig","text":"//! Check command.\n\npub fn run() void {}\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/main.zig","text":"const check_command = @import(\"commands/check.zig\");\n"}}}
    });
    defer opened.deinit();

    // Hover on the string shows the target's container docs — no trailing
    // markdown link (it rendered poorly for relative/long stdlib paths
    // and wasn't useful over go-to-definition, which already works here).
    var hover_responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///proj/main.zig"},"position":{"line":0,"character":35}}}
    });
    defer hover_responses.deinit();
    var hover_parsed = try std.json.parseFromSlice(std.json.Value, gpa, hover_responses.messages.items[0], .{});
    defer hover_parsed.deinit();
    const result = hover_parsed.value.object.get("result").?.object;
    const hover_value = result.get("contents").?.object.get("value").?.string;
    try std.testing.expect(std.mem.indexOf(u8, hover_value, "Check command.") != null);
    try std.testing.expect(std.mem.indexOf(u8, hover_value, "](") == null); // no markdown link

    // Range covers exactly `commands/check.zig` (19 chars) — not the
    // quotes on either side.
    const range = result.get("range").?.object;
    try std.testing.expectEqual(@as(i64, 0), range.get("start").?.object.get("line").?.integer);
    const start_char = range.get("start").?.object.get("character").?.integer;
    const end_char = range.get("end").?.object.get("character").?.integer;
    try std.testing.expectEqual(@as(i64, "commands/check.zig".len), end_char - start_char);
    try std.testing.expectEqual(@as(i64, 31), start_char); // just past the opening quote
}

test "textDocument/inlayHint respects enable=false" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();
    server.inlay_hints_enable = false;

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\nfn main() void {\n    _ = add(1, 2);\n}\n"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/inlayHint","params":{"textDocument":{"uri":"file:///a.zig"},"range":{"start":{"line":0,"character":0},"end":{"line":10,"character":0}}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("result").?.array.items.len);
}

test "textDocument/codeLens reports reference counts" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn helper() void {}\nfn a() void {\n    helper();\n}\nfn b() void {\n    helper();\n}\n"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/codeLens","params":{"textDocument":{"uri":"file:///a.zig"}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const lenses = parsed.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), lenses.len); // helper, a, b

    var found_helper = false;
    for (lenses) |lens| {
        const title = lens.object.get("command").?.object.get("title").?.string;
        if (std.mem.eql(u8, title, "2 references")) found_helper = true;
    }
    try std.testing.expect(found_helper);
}

test "textDocument/inlayHint shows parameter names at call sites" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\nfn main() void {\n    _ = add(1, 2);\n}\n"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/inlayHint","params":{"textDocument":{"uri":"file:///a.zig"},"range":{"start":{"line":0,"character":0},"end":{"line":10,"character":0}}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const hints = parsed.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), hints.len);
    try std.testing.expectEqualStrings("a: ", hints[0].object.get("label").?.string);
    try std.testing.expectEqualStrings("b: ", hints[1].object.get("label").?.string);
}

test "textDocument/inlayHint suppresses a hint when the argument is already named like the parameter" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"fn visit(tree: i32, extra: i32) void {\n    _ = tree;\n    _ = extra;\n}\nfn main() void {\n    const tree = 1;\n    visit(tree, 2);\n}\n"}}}
    });
    defer opened.deinit();

    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/inlayHint","params":{"textDocument":{"uri":"file:///a.zig"},"range":{"start":{"line":0,"character":0},"end":{"line":10,"character":0}}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const hints = parsed.value.object.get("result").?.array.items;
    // Param "tree: " suppressed (arg already named tree); type inlay on
    // `const tree = 1`; param "extra: " on the second arg.
    try std.testing.expectEqual(@as(usize, 2), hints.len);
    var saw_extra = false;
    var saw_type = false;
    for (hints) |h| {
        const label = h.object.get("label").?.string;
        if (std.mem.eql(u8, label, "extra: ")) saw_extra = true;
        if (std.mem.eql(u8, label, ": comptime_int")) saw_type = true;
    }
    try std.testing.expect(saw_extra);
    try std.testing.expect(saw_type);
}

test "unused import is published with the Unnecessary diagnostic tag" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"const std = @import(\"std\");\n"}}}
    });
    defer opened.deinit();

    var diag = try std.json.parseFromSlice(std.json.Value, gpa, opened.messages.items[0], .{});
    defer diag.deinit();
    const items = diag.value.object.get("params").?.object.get("diagnostics").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expect(std.mem.indexOf(u8, items[0].object.get("message").?.string, "unused import") != null);
    const tags = items[0].object.get("tags").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), tags.len);
    try std.testing.expectEqual(@as(i64, 1), tags[0].integer); // Unnecessary
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

test "textDocument/completion inside an @import string suggests std and named packages, not keywords" {
    const gpa = std.testing.allocator;
    var server: Server = .init(gpa, std.testing.io);
    defer server.deinit();
    server.zig_lib_dir = try gpa.dupe(u8, "/opt/zig/lib");

    var opened = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.zig","text":"const x = @import(\"st\");\n"}}}
    });
    defer opened.deinit();

    // Cursor right after "st", inside the still-open string.
    var responses = try harness.run(gpa, &server, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///a.zig"},"position":{"line":0,"character":21}}}
    });
    defer responses.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, responses.messages.items[0], .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("result").?.array.items;

    var saw_std = false;
    for (items) |item| {
        const label = item.object.get("label").?.string;
        try std.testing.expect(!std.mem.eql(u8, label, "const")); // no keywords inside the string
        if (std.mem.eql(u8, label, "std")) {
            saw_std = true;
            try std.testing.expectEqual(@as(i64, 9), item.object.get("kind").?.integer); // Module
        }
    }
    try std.testing.expect(saw_std);
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
