//! `initialize` / `initialized` / `shutdown` / `exit` lifecycle, plus the
//! `initializationOptions`/`workspace/didChangeConfiguration` settings
//! parsing shared between the first two.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const jsonrpc = @import("jsonrpc").jsonrpc;
const packages_mod = @import("../analysis/queries/packages.zig");
const uri_util = @import("../uri.zig");
const Server = @import("../server.zig").Server;

const FormatterOptions = struct {
    command: ?[]const u8 = null,
    args: ?[]const []const u8 = null,
};
const InlayHintsOptions = struct {
    enable: ?bool = null,
    parameterNames: ?bool = null,
    excludeSingleArgument: ?bool = null,
    types: ?bool = null,
};
const ServerOptions = struct {
    formatter: ?FormatterOptions = null,
    /// Path to the `zig` executable (same setting the VS Code
    /// extension exposes as `zigAnalyzer.zigPath`). Used to run
    /// `zig env` so `@import("std")` resolves against the local
    /// stdlib rather than anything on the web.
    zigPath: ?[]const u8 = null,
    inlayHints: ?InlayHintsOptions = null,
};

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

/// Shared by `initialize`'s `initializationOptions` and
/// `workspace/didChangeConfiguration`'s `settings` — both carry the
/// same `{ formatter, zigPath, inlayHints }` shape (see extension.ts).
pub fn applyOptions(self: *Server, options_value: std.json.Value) void {
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

    if (parsed.value.zigPath) |path| {
        if (path.len > 0) setZigExe(self, path) catch |err| {
            std.log.err("failed to apply zigPath: {t}", .{err});
        };
    }

    if (parsed.value.inlayHints) |ih| {
        if (ih.enable) |v| self.inlay_hints_enable = v;
        if (ih.parameterNames) |v| self.inlay_hints_parameter_names = v;
        if (ih.excludeSingleArgument) |v| self.inlay_hints_exclude_single_argument = v;
        if (ih.types) |v| self.inlay_hints_types = v;
    }

    if (parsed.value.formatter) |formatter| {
        const command = formatter.command orelse "zig";
        const args = formatter.args orelse &[_][]const u8{ "fmt", "--stdin" };
        setFormatterConfig(self, command, args) catch |err| {
            std.log.err("failed to apply formatter config: {t}", .{err});
        };
    }
    discoverZigLibDir(self);
}

fn setZigExe(self: *Server, path: []const u8) !void {
    const owned = try self.gpa.dupe(u8, path);
    if (self.zig_exe_owned) self.gpa.free(self.zig_exe);
    self.zig_exe = owned;
    self.zig_exe_owned = true;
}

/// Runs `zig env` and caches `lib_dir`. Best-effort: failure leaves
/// `zig_lib_dir` as-is (or null), so `@import("std")` simply stays
/// unresolved rather than breaking the server.
pub fn discoverZigLibDir(self: *Server) void {
    const result = std.process.run(self.gpa, self.io, .{
        .argv = &.{ self.zig_exe, "env" },
    }) catch |err| {
        std.log.err("failed to run '{s} env': {t}", .{ self.zig_exe, err });
        return;
    };
    defer {
        self.gpa.free(result.stdout);
        self.gpa.free(result.stderr);
    }

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.log.err("'{s} env' exited unsuccessfully", .{self.zig_exe});
        return;
    }

    const Env = struct {
        lib_dir: ?[]const u8 = null,
        global_cache_dir: ?[]const u8 = null,
    };
    const source = self.gpa.dupeZ(u8, result.stdout) catch return;
    defer self.gpa.free(source);

    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(self.gpa);
    const env = std.zon.parse.fromSliceAlloc(Env, self.gpa, source, &diag, .{ .ignore_unknown_fields = true }) catch |err| {
        std.log.err("failed to parse '{s} env' output: {t}", .{ self.zig_exe, err });
        return;
    };
    defer std.zon.parse.free(self.gpa, env);

    if (env.lib_dir) |lib_dir| {
        const owned = self.gpa.dupe(u8, lib_dir) catch return;
        if (self.zig_lib_dir) |old| self.gpa.free(old);
        self.zig_lib_dir = owned;
    }
    if (env.global_cache_dir) |cache_dir| {
        const owned = self.gpa.dupe(u8, cache_dir) catch return;
        if (self.zig_global_cache_dir) |old| self.gpa.free(old);
        self.zig_global_cache_dir = owned;
    }
}

pub fn handleInitialize(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
    if (self.phase != .uninitialized) {
        try jsonrpc.writeError(writer, self.gpa, msg.id.?, .invalid_request, "server already initialized");
        return;
    }

    const ClientCapabilities = struct {
        textDocument: ?struct {
            definition: ?struct {
                linkSupport: ?bool = null,
            } = null,
        } = null,
    };
    const Params = struct {
        initializationOptions: std.json.Value = .null,
        workspaceFolders: ?[]const WorkspaceFolder = null,
        rootUri: ?[]const u8 = null,
        capabilities: ClientCapabilities = .{},
    };
    if (std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true })) |parsed| {
        defer parsed.deinit();
        applyOptions(self, parsed.value.initializationOptions);
        // Need lib + package-cache dirs before resolving zon deps.
        if (self.zig_lib_dir == null or self.zig_global_cache_dir == null) discoverZigLibDir(self);
        reloadPackagesFromFolders(self, parsed.value.workspaceFolders, parsed.value.rootUri);
        self.definition_link_support = if (parsed.value.capabilities.textDocument) |td|
            if (td.definition) |def| (def.linkSupport orelse false) else false
        else
            false;
    } else |err| {
        std.log.err("ignoring malformed initialize params: {t}", .{err});
        if (self.zig_lib_dir == null) discoverZigLibDir(self);
    }
    // Even with no initializationOptions, try to find the local
    // stdlib via whatever `zig` is on PATH — needed for
    // `@import("std")` hover/definition.
    if (self.zig_lib_dir == null) discoverZigLibDir(self);

    const InitializeResult = struct {
        capabilities: struct {
            // 1 == TextDocumentSyncKind.Full.
            textDocumentSync: u8 = 1,
            definitionProvider: bool = true,
            hoverProvider: bool = true,
            documentSymbolProvider: bool = true,
            workspaceSymbolProvider: bool = true,
            completionProvider: struct {
                // Fires completion again on '/' so typing a path
                // segment (`sub/` inside `@import("sub/`) immediately
                // lists that subdirectory, matching how it behaves
                // after any other identifier character.
                triggerCharacters: []const []const u8 = &.{"/"},
            } = .{},
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
            codeLensProvider: struct {} = .{},
            inlayHintProvider: bool = true,
        } = .{},
        serverInfo: struct {
            name: []const u8 = "zig-analyzer",
            version: []const u8 = build_options.version,
        } = .{},
    };
    try jsonrpc.writeResult(writer, self.gpa, msg.id.?, InitializeResult{});
    self.phase = .initializing;
}

const WorkspaceFolder = struct { uri: []const u8, name: []const u8 = "" };

fn reloadPackagesFromFolders(
    self: *Server,
    folders: ?[]const WorkspaceFolder,
    root_uri: ?[]const u8,
) void {
    packages_mod.clearPackages(self.gpa, &self.packages);
    self.workspace_has_build_zig = false;

    if (folders) |list| {
        for (list) |folder| {
            const path = uri_util.toFsPath(self.gpa, folder.uri) catch continue;
            defer self.gpa.free(path);
            const mode = packages_mod.detectWorkspaceMode(self.io, path);
            if (mode == .build_script) self.workspace_has_build_zig = true;
            if (mode == .freestanding) continue;
            packages_mod.loadDepsFromWorkspace(self.gpa, self.io, path, self.zig_global_cache_dir, &self.packages) catch |err| {
                std.log.err("failed to load path deps from {s}: {t}", .{ path, err });
            };
        }
        return;
    }

    if (root_uri) |uri| {
        const path = uri_util.toFsPath(self.gpa, uri) catch return;
        defer self.gpa.free(path);
        const mode = packages_mod.detectWorkspaceMode(self.io, path);
        if (mode == .build_script) self.workspace_has_build_zig = true;
        if (mode == .freestanding) return;
        packages_mod.loadDepsFromWorkspace(self.gpa, self.io, path, self.zig_global_cache_dir, &self.packages) catch |err| {
            std.log.err("failed to load path deps from {s}: {t}", .{ path, err });
        };
    }
}

pub fn handleInitialized(self: *Server, msg: jsonrpc.Message) void {
    _ = msg;
    if (self.phase == .initializing) self.phase = .running;
}

pub fn handleDidChangeConfiguration(self: *Server, msg: jsonrpc.Message) void {
    const Params = struct { settings: std.json.Value = .null };
    var parsed = std.json.parseFromValue(Params, self.gpa, msg.params, .{ .ignore_unknown_fields = true }) catch |err| {
        std.log.err("ignoring malformed workspace/didChangeConfiguration params: {t}", .{err});
        return;
    };
    defer parsed.deinit();
    applyOptions(self, parsed.value.settings);
}

pub fn handleShutdown(self: *Server, writer: *Io.Writer, msg: jsonrpc.Message) !void {
    if (self.phase == .uninitialized) {
        try jsonrpc.writeError(writer, self.gpa, msg.id.?, .server_not_initialized, "server not initialized");
        return;
    }
    try jsonrpc.writeResult(writer, self.gpa, msg.id.?, @as(?u8, null));
    self.phase = .shutdown_requested;
}

pub fn handleExit(self: *Server) void {
    self.exit_code = if (self.phase == .shutdown_requested) 0 else 1;
    self.should_exit = true;
}
