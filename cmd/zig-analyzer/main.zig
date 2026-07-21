const std = @import("std");
const zig_builtin = @import("builtin");
const zls = @import("zig_analyzer");
const exe_options = @import("exe_options");
const fangz = @import("fangz");
const vereda = @import("vereda");

const log = std.log.scoped(.main);

pub const std_options: std.Options = .{
    // Always set this to debug to make std.log call into our handler, then control the runtime
    // value in logFn itself
    .log_level = .debug,
    .logFn = logFn,
    .networking = false,
};

/// Log messages with the LSP 'window/logMessage' message.
var log_transport: ?*zls.lsp.Transport = null;
/// Log messages to stderr.
var log_stderr: bool = true;
/// Log messages to the given file.
var log_file: ?std.Io.File = null;
var log_level: std.log.Level = if (zig_builtin.mode == .Debug) .debug else .info;

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [4096]u8 = undefined;
    comptime std.debug.assert(buffer.len >= zls.lsp.minimum_logging_buffer_size);

    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);

    if (log_transport) |transport| {
        const lsp_message_type: zls.lsp.types.window.MessageType = switch (level) {
            .err => .Error,
            .warn => .Warning,
            .info => .Info,
            .debug => .Debug,
        };
        const json_message = zls.lsp.bufPrintLogMessage(&buffer, lsp_message_type, format, args);
        transport.writeJsonMessage(io, json_message) catch |err| switch (err) {
            error.Canceled => unreachable,
            else => {},
        };
    }

    if (@intFromEnum(level) > @intFromEnum(log_level)) return;
    if (!log_stderr and log_file == null) return;

    const level_txt: []const u8 = switch (level) {
        .err => "error",
        .warn => "warn ",
        .info => "info ",
        .debug => "debug",
    };
    const scope_txt: []const u8 = comptime @tagName(scope);

    var writer: std.Io.Writer = .fixed(&buffer);
    const no_space_left = blk: {
        writer.print("{s} ({s:^6}): ", .{ level_txt, scope_txt }) catch break :blk true;
        writer.print(format, args) catch break :blk true;
        writer.writeByte('\n') catch break :blk true;
        break :blk false;
    };
    if (no_space_left) {
        const trailing = "...\n".*;
        writer.undo(trailing.len -| writer.unusedCapacityLen());
        (writer.writableArray(trailing.len) catch unreachable).* = trailing;
    }

    if (log_stderr) {
        const stderr = io.lockStderr(&.{}, null) catch |err| switch (err) {
            error.Canceled => unreachable,
        };
        defer io.unlockStderr();
        stderr.file_writer.interface.writeAll(writer.buffered()) catch {};
    }

    if (log_file) |file| {
        const is_locked = if (file.lock(io, .exclusive)) |_| true else |_| false;
        defer if (is_locked) file.unlock(io);
        if (file.length(io)) |length| {
            file.writePositionalAll(io, writer.buffered(), length) catch {};
        } else |_| {
            // Io currently provides no way to seek to the end of a file. This
            // may clobber logs from other processes.
            file.writeStreamingAll(io, writer.buffered()) catch {};
        }
    }
}

/// Resolves an optional Vereda directory, treating any non-allocation failure (directory not
/// available, home directory unknown, ...) as "not found" rather than propagating it.
fn resolveDirOptional(allocator: std.mem.Allocator, comptime resolver: anytype) error{OutOfMemory}!?[]u8 {
    return resolver(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

fn defaultLogFilePath(allocator: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
    if (zig_builtin.target.os.tag == .wasi) return null;
    const cache_path = try resolveDirOptional(allocator, vereda.dirs.cache) orelse return null;
    defer allocator.free(cache_path);
    return try std.Io.Dir.path.join(allocator, &.{ cache_path, "zig-analyzer", "zig-analyzer.log" });
}

fn createLogFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    override_log_file_path: ?[]const u8,
) error{ Canceled, OutOfMemory }!?struct { std.Io.File, []const u8 } {
    const log_file_path = if (override_log_file_path) |log_file_path|
        try allocator.dupe(u8, log_file_path)
    else
        try defaultLogFilePath(allocator) orelse return null;
    errdefer allocator.free(log_file_path);

    if (std.Io.Dir.path.dirname(log_file_path)) |dirname| {
        std.Io.Dir.cwd().createDirPath(io, dirname) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {},
        };
    }

    const file = std.Io.Dir.cwd().createFile(io, log_file_path, .{ .truncate = false }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            allocator.free(log_file_path);
            return null;
        },
    };
    errdefer file.close(io);

    return .{ file, log_file_path };
}

/// Output format of `zig-analyzer env`
const Env = struct {
    /// The Zig Analyzer version. Guaranteed to be a [semantic version](https://semver.org/).
    ///
    /// The semantic version can have one of the following formats:
    /// - `MAJOR.MINOR.PATCH` is a tagged release of Zig Analyzer
    /// - `MAJOR.MINOR.PATCH-dev.COMMIT_HEIGHT+SHORT_COMMIT_HASH` is a development build of Zig Analyzer
    /// - `MAJOR.MINOR.PATCH-dev` is a development build of Zig Analyzer where the exact version could not be resolved.
    ///
    version: []const u8,
    global_cache_dir: ?[]const u8,
    /// Path to a user-specific configuration directory relative to which configuration files will be searched.
    /// Not `null` unless [Vereda](https://github.com/jassielof/vereda) was unable to resolve a configuration directory.
    config_dir: ?[]const u8,
    /// Path to a `zls.json` config file. Will be resolved by looking inside the configuration directory.
    /// Can be null if no `zls.json` was found in the configuration directory.
    config_file: ?[]const u8,
    /// Path to a `zls.log` file where Zig Analyzer will append logging output. The file may be truncated or cleared.
    /// Not `null` unless [Vereda](https://github.com/jassielof/vereda) was unable to resolve a cache directory.
    log_file: ?[]const u8,
};

fn printEnv(io: std.Io, allocator: std.mem.Allocator) (std.mem.Allocator.Error || std.Io.File.Writer.Error)!void {
    const global_cache_dir = try resolveDirOptional(allocator, vereda.dirs.cache);
    defer if (global_cache_dir) |path| allocator.free(path);

    const zls_global_cache_dir = if (global_cache_dir) |cache_dir| try std.Io.Dir.path.join(allocator, &.{ cache_dir, "zig-analyzer" }) else null;
    defer if (zls_global_cache_dir) |path| allocator.free(path);

    const config_dir = try resolveDirOptional(allocator, vereda.dirs.config);
    defer if (config_dir) |path| allocator.free(path);

    var config_result = try loadConfigFromSystem(io, allocator);
    defer config_result.deinit(allocator);

    const config_file_path: ?[]const u8 = switch (config_result) {
        .success => |config_with_path| config_with_path.path,
        .failure => |payload| blk: {
            const message = try payload.toMessage(allocator) orelse break :blk null;
            defer allocator.free(message);
            log.err("Failed to load configuration options.", .{});
            log.err("{s}", .{message});
            break :blk null;
        },
        .not_found => null,
    };

    const log_file_path = try defaultLogFilePath(allocator);
    defer if (log_file_path) |path| allocator.free(path);

    var buffer: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    const writer = &file_writer.interface;

    const env: Env = .{
        .version = zls.build_options.version_string,
        .global_cache_dir = zls_global_cache_dir,
        .config_dir = config_dir,
        .config_file = config_file_path,
        .log_file = log_file_path,
    };
    std.json.Stringify.value(env, .{ .whitespace = .indent_1 }, writer) catch return file_writer.err.?;
    writer.writeAll("\n") catch return file_writer.err.?;
    writer.flush() catch return file_writer.err.?;
}

const LoadConfigResult = union(enum) {
    success: struct {
        config: zls.Config,
        config_arena: std.heap.ArenaAllocator.State,
        /// file path of the config.json
        path: []const u8,
    },
    failure: struct {
        /// `null` indicates that the error has already been logged
        error_bundle: ?std.zig.ErrorBundle,

        pub fn toMessage(self: @This(), allocator: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
            const error_bundle = self.error_bundle orelse return null;
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            error_bundle.renderToWriter(.{}, &aw.writer) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
            };
            return try aw.toOwnedSlice();
        }
    },
    not_found,

    pub fn deinit(self: *LoadConfigResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .success => |*config_with_path| {
                config_with_path.config_arena.promote(allocator).deinit();
                allocator.free(config_with_path.path);
            },
            .failure => |*payload| {
                if (payload.error_bundle) |*error_bundle| error_bundle.deinit(allocator);
            },
            .not_found => {},
        }
    }
};

fn loadConfigFromFile(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8) error{ Canceled, OutOfMemory }!LoadConfigResult {
    const file_buf = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .not_found,
        error.Canceled, error.OutOfMemory => |e| return e,
        else => {
            log.warn("Error while reading configuration file: {}", .{err});
            return .{ .failure = .{ .error_bundle = null } };
        },
    };
    defer allocator.free(file_buf);

    const parse_options: std.json.ParseOptions = .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    };
    var parse_diagnostics: std.json.Diagnostics = .{};

    var scanner: std.json.Scanner = .initCompleteInput(allocator, file_buf);
    defer scanner.deinit();
    scanner.enableDiagnostics(&parse_diagnostics);

    var arena_allocator: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena_allocator.deinit();

    @setEvalBranchQuota(10000);
    const config = std.json.parseFromTokenSourceLeaky(
        zls.Config,
        arena_allocator.allocator(),
        &scanner,
        parse_options,
    ) catch |err| {
        var eb: std.zig.ErrorBundle.Wip = undefined;
        try eb.init(allocator);
        errdefer eb.deinit();

        const src_path = try eb.addString(file_path);
        const msg = try eb.addString(@errorName(err));

        const src_loc = try eb.addSourceLocation(.{
            .src_path = src_path,
            .line = @intCast(parse_diagnostics.getLine()),
            .column = @intCast(parse_diagnostics.getColumn()),
            .span_start = @intCast(parse_diagnostics.getByteOffset()),
            .span_main = @intCast(parse_diagnostics.getByteOffset()),
            .span_end = @intCast(parse_diagnostics.getByteOffset()),
        });
        try eb.addRootErrorMessage(.{
            .msg = msg,
            .src_loc = src_loc,
        });

        return .{ .failure = .{ .error_bundle = try eb.toOwnedBundle("") } };
    };

    return .{ .success = .{
        .config = config,
        .config_arena = arena_allocator.state,
        .path = try allocator.dupe(u8, file_path),
    } };
}

fn loadConfigFromSystem(io: std.Io, allocator: std.mem.Allocator) error{ Canceled, OutOfMemory }!LoadConfigResult {
    if (zig_builtin.target.os.tag == .wasi) return .not_found;

    const config_dir = try resolveDirOptional(allocator, vereda.dirs.config) orelse return .not_found;
    defer allocator.free(config_dir);

    const config_path = try std.Io.Dir.path.join(allocator, &.{ config_dir, "zls.json" });
    defer allocator.free(config_path);

    return try loadConfigFromFile(io, allocator, config_path);
}

fn loadConfiguration(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: *zls.Server,
    maybe_config_path: ?[]const u8,
) error{ Canceled, OutOfMemory }!void {
    var config_arena: std.heap.ArenaAllocator = .init(allocator);
    defer config_arena.deinit();
    var config: zls.Config = .{};

    blk: {
        var config_result = if (maybe_config_path) |config_path|
            try loadConfigFromFile(io, allocator, config_path)
        else
            try loadConfigFromSystem(io, allocator);
        defer config_result.deinit(allocator);

        switch (config_result) {
            .success => |*config_with_path| {
                log.info("Loaded config:    {s}", .{config_with_path.path});
                config = config_with_path.config;
                config_arena.state = config_with_path.config_arena;
                config_with_path.config_arena = .{};
            },
            .failure => |payload| {
                const message = try payload.toMessage(allocator) orelse break :blk;
                defer allocator.free(message);
                server.showMessage(.Error, "Failed to load configuration options:\n{s}", .{message});
            },
            .not_found => {},
        }
    }

    if (config.global_cache_path == null) blk: {
        if (zig_builtin.target.os.tag == .wasi) {
            // will default to `/cache`
            break :blk;
        }

        const cache_dir_path = try resolveDirOptional(allocator, vereda.dirs.cache) orelse {
            server.showMessage(.Error, "Failed to resolve global cache directory", .{});
            break :blk;
        };
        defer allocator.free(cache_dir_path);

        config.global_cache_path = try std.Io.Dir.path.join(config_arena.allocator(), &.{ cache_dir_path, "zig-analyzer" });
    }

    try server.config_manager.setConfiguration2(.frontend, &config);
}

/// Cross-cutting state shared with Fangz command hooks, which are plain function pointers and
/// therefore cannot close over local state in `main`.
const StartupContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    exe_path: []const u8,
    exit_status: u8 = 0,
};
var startup_context: StartupContext = undefined;

fn runEnvCommand(ctx: *fangz.ParseContext) anyerror!void {
    _ = ctx;
    try printEnv(startup_context.io, startup_context.allocator);
}

fn runServer(ctx: *fangz.ParseContext) anyerror!void {
    const io = startup_context.io;
    const allocator = startup_context.allocator;

    if (zig_builtin.target.os.tag != .wasi and try std.Io.File.stdin().isTty(io)) {
        log.warn("zig-analyzer is not a CLI tool, it communicates over the Language Server Protocol.", .{});
        log.warn("Did you mean to run 'zig-analyzer --help'?", .{});
        log.warn("", .{});
    }

    const config_path = ctx.stringFlag("config-path");
    const cli_log_level = ctx.enumFlag(std.log.Level, "log-level");
    const enable_stderr_logs = ctx.boolFlag("enable-stderr-logs") orelse false;
    const disable_lsp_logs = ctx.boolFlag("disable-lsp-logs") orelse false;

    log_file, const log_file_path = try createLogFile(io, allocator, ctx.stringFlag("log-file")) orelse .{ null, null };
    defer if (log_file_path) |path| allocator.free(path);
    defer if (log_file) |file| {
        file.close(io);
        log_file = null;
    };

    var read_buffer: [256]u8 = undefined;
    var stdio_transport: zls.lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());

    var thread_safe_transport: zls.lsp.ThreadSafeTransport(.{
        .thread_safe_read = false,
        .thread_safe_write = true,
    }) = .init(&stdio_transport.transport);

    const transport: *zls.lsp.Transport = &thread_safe_transport.transport;

    log_transport = if (disable_lsp_logs) null else transport;
    log_stderr = enable_stderr_logs;
    log_level = cli_log_level orelse log_level;
    defer {
        log_transport = null;
        log_stderr = true;
    }

    log.info("Starting Zig Analyzer {s} @ '{s}'", .{ zls.build_options.version_string, startup_context.exe_path });
    if (log_file_path) |path| {
        log.info("Log File:         {s} ({t})", .{ path, log_level });
    } else {
        log.info("Log File:         none", .{});
    }

    var config_manager: zls.configuration.Manager = try .init(io, allocator, startup_context.environ_map);
    defer config_manager.deinit();

    const server: *zls.Server = try .create(.{
        .io = io,
        .allocator = allocator,
        .transport = transport,
        .config_manager = &config_manager,
    });
    defer server.destroy();

    try loadConfiguration(io, allocator, server, config_path);

    try server.loop();

    startup_context.exit_status = switch (server.status) {
        .exiting_failure => 1,
        .exiting_success => 0,
        else => unreachable,
    };
}

pub fn main(init: std.process.Init) !u8 {
    var failing_allocator_state = if (exe_options.enable_failing_allocator) zls.testing.FailingAllocator.init(init.gpa, exe_options.enable_failing_allocator_likelihood) else {};
    const allocator: std.mem.Allocator = if (exe_options.enable_failing_allocator) failing_allocator_state.allocator() else init.gpa;

    var exe_path_it = try init.minimal.args.iterateAllocator(allocator);
    const exe_path = try allocator.dupe(u8, exe_path_it.next() orelse "");
    exe_path_it.deinit();
    defer allocator.free(exe_path);

    startup_context = .{
        .io = init.io,
        .allocator = allocator,
        .environ_map = init.environ_map,
        .exe_path = exe_path,
    };

    var app: fangz.App = try .init(allocator, init.io, .{
        .display_name = "Zig Analyzer",
        .brief = "A non-official language server for Zig",
        .version = zls.build_options.version_string,
    });
    defer app.deinit();
    app.setCompletionsEnabled(false);
    app.setDocsEnabled(false);

    const root_cmd = app.root();
    root_cmd.setHooks(.{ .run = runServer });

    try root_cmd.addFlag(?[]const u8, .{
        .name = "config-path",
        .brief = "Set path to the 'zls.json' configuration file",
        .value_hint = "PATH",
    });
    try root_cmd.addFlag(?[]const u8, .{
        .name = "log-file",
        .brief = "Set path to the 'zls.log' log file",
        .value_hint = "PATH",
    });
    try root_cmd.addFlag(?std.log.Level, .{
        .name = "log-level",
        .brief = "The log level to be used (defaults to 'debug' in debug builds, 'info' otherwise)",
    });
    try root_cmd.addFlag(bool, .{
        .name = "enable-stderr-logs",
        .brief = "Write log messages to stderr",
        .default = false,
    });
    try root_cmd.addFlag(bool, .{
        .name = "disable-lsp-logs",
        .brief = "Disable LSP 'window/logMessage' messages",
        .default = false,
    });

    const env_cmd = try root_cmd.addSubcommand(.{
        .name = "env",
        .brief = "Print config path, log path and version",
    });
    env_cmd.setHooks(.{ .run = runEnvCommand });

    app.executeProcess(init.minimal.args) catch |err| {
        // Fangz already prints a friendly diagnostic for parse errors; avoid also dumping a
        // raw error return trace for user input mistakes.
        if (isFangzParseError(err)) return 1;
        return err;
    };

    return startup_context.exit_status;
}

fn isFangzParseError(err: anyerror) bool {
    const entries = @typeInfo(fangz.Parser.ParseError).error_set orelse return false;
    inline for (entries) |entry| {
        if (err == @field(fangz.Parser.ParseError, entry.name)) return true;
    }
    return false;
}
