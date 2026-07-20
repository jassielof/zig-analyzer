//! This script takes care of the following tasks:
//!
//! - generate `internal/zig_analyzer/Config.zig`
//! - generate `schemas/zig-analyzer.schema.json`
//! - generate `schemas/vscode-configuration.json` (`zigAnalyzer.*` VS Code properties)
//! - generate metadata about Zig's builtins (from Markitdown Language Reference Markdown)
const std = @import("std");
const builtin_serializer = @import("builtin_serializer.zig");

const ConfigOption = struct {
    /// Name of config option
    name: []const u8,
    /// (used in doc comments & schema.json)
    description: []const u8,
    /// zig type in string form. e.g "u32", "[]const u8", "?usize"
    type: []const u8,
    /// if the zig type should be an enum, this should contain
    /// a list of enum values and `type`
    /// If this is set, the value `type` should to be `enum`
    @"enum": ?[]const []const u8 = null,
    /// used in Config.zig as the default initializer
    default: std.json.Value,
    /// Relative key under `zigAnalyzer.` for VS Code (e.g. `formatter.command`).
    /// When null, derived by camelCasing `name`.
    vscode: ?[]const u8 = null,
    /// VS Code configuration scope. Defaults to `resource`.
    vscode_scope: ?[]const u8 = null,
    /// Skip emitting a VS Code property for this option.
    vscode_skip: bool = false,

    fn getTypescriptType(self: ConfigOption) error{UnsupportedType}![]const u8 {
        std.debug.assert(self.type.len != 0);
        const ty = self.type[@intFromBool(self.type[0] == '?')..];
        return if (std.mem.eql(u8, ty, "[]const []const u8"))
            "array"
        else if (std.mem.eql(u8, ty, "[]const u8"))
            "string"
        else if (std.mem.eql(u8, ty, "bool"))
            "boolean"
        else if (std.mem.eql(u8, ty, "usize"))
            "integer"
        else if (std.mem.eql(u8, ty, "enum"))
            "string"
        else
            error.UnsupportedType;
    }

    fn formatZigType(config: ConfigOption, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (config.@"enum") |enum_members| {
            try writer.writeAll("enum {\n");
            for (enum_members) |member_name| {
                try writer.print("    {s},\n", .{member_name});
            }
            std.debug.assert(enum_members.len > 1);
            try writer.writeByte('}');
            return;
        }
        try writer.writeAll(config.type);
    }

    fn fmtZigType(self: ConfigOption) std.fmt.Alt(ConfigOption, formatZigType) {
        return .{ .data = self };
    }

    fn formatDefaultValue(config: ConfigOption, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (config.default == .array) {
            try writer.writeAll("&.{");
            for (config.default.array.items, 0..) |item, i| {
                if (i != 0) try writer.writeByte(',');
                std.json.Stringify.value(item, .{}, writer) catch |err| return @errorCast(err);
            }
            try writer.writeByte('}');
            return;
        }
        if (config.@"enum" != null) {
            try writer.print(".{s}", .{config.default.string});
            return;
        }
        std.json.Stringify.value(config.default, .{}, writer) catch |err| return @errorCast(err);
    }

    fn fmtDefaultValue(self: ConfigOption) std.fmt.Alt(ConfigOption, formatDefaultValue) {
        return .{ .data = self };
    }

    fn vscodeRelativeKey(self: ConfigOption, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        if (self.vscode) |key| return try allocator.dupe(u8, key);
        return try snakeCaseToCamelCase(allocator, self.name);
    }
};

const Config = struct {
    options: []ConfigOption,
};

const Schema = struct {
    @"$schema": []const u8 = "http://json-schema.org/draft-04/schema",
    title: []const u8 = "Zig Analyzer Config",
    description: []const u8 = "Configuration file for zig-analyzer",
    type: []const u8 = "object",
    properties: std.json.ArrayHashMap(SchemaEntry),
};

const SchemaEntry = struct {
    description: []const u8,
    type: []const u8,
    items: ?struct { type: []const u8 } = null,
    @"enum": ?[]const []const u8 = null,
    default: std.json.Value,
};

const FormatDocs = struct {
    text: []const u8,
    comment_kind: CommentKind,

    const CommentKind = enum {
        normal,
        doc,
        top_level,
    };

    fn render(ctx: FormatDocs, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const prefix = switch (ctx.comment_kind) {
            .normal => "// ",
            .doc => "/// ",
            .top_level => "//! ",
        };
        var i: usize = 0;
        var iterator = std.mem.splitScalar(u8, ctx.text, '\n');
        while (iterator.next()) |line| : (i += 1) {
            if (i != 0) try writer.writeByte('\n');
            try writer.print("{s}{s}", .{ prefix, line });
        }
    }
};

fn fmtDocs(text: []const u8, comment_kind: FormatDocs.CommentKind) std.fmt.Alt(FormatDocs, FormatDocs.render) {
    return .{ .data = .{ .text = text, .comment_kind = comment_kind } };
}

fn generateConfigFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    config: Config,
    path: []const u8,
) (std.Io.Dir.WriteFileError || std.mem.Allocator.Error)!void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    aw.writer.writeAll(
        \\//! DO NOT EDIT
        \\//! Configuration options for zig-analyzer.
        \\//! If you want to add a config option edit
        \\//! tools/config_gen/config.json
        \\//! GENERATED BY tools/config_gen/main.zig
        \\
    ) catch return error.OutOfMemory;

    for (config.options) |option| {
        aw.writer.print(
            \\
            \\{f}
            \\{f}: {f} = {f},
            \\
        , .{
            fmtDocs(std.mem.trim(u8, option.description, &std.ascii.whitespace), .doc),
            std.zig.fmtId(std.mem.trim(u8, option.name, &std.ascii.whitespace)),
            option.fmtZigType(),
            option.fmtDefaultValue(),
        }) catch return error.OutOfMemory;
    }

    aw.writer.writeAll(
        \\
        \\// DO NOT EDIT
        \\
    ) catch return error.OutOfMemory;

    const source_unformatted = try aw.toOwnedSliceSentinel(0);
    defer allocator.free(source_unformatted);

    var tree: std.zig.Ast = try .parse(allocator, source_unformatted, .zig);
    defer tree.deinit(allocator);
    std.debug.assert(tree.errors.len == 0);

    const source = try tree.renderAlloc(allocator);
    defer allocator.free(source);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = source,
    });
}

fn generateSchemaFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    config: Config,
    path: []const u8,
) !void {
    const schema_file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer schema_file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_writer = schema_file.writer(io, &buffer);
    const writer = &file_writer.interface;

    var schema: Schema = .{ .properties = .{} };
    defer schema.properties.map.deinit(allocator);

    try schema.properties.map.ensureTotalCapacity(allocator, @intCast(config.options.len));

    for (config.options) |option| {
        schema.properties.map.putAssumeCapacityNoClobber(option.name, .{
            .description = option.description,
            .type = try option.getTypescriptType(),
            .items = if (std.mem.eql(u8, option.type, "[]const []const u8")) .{ .type = "string" } else null,
            .@"enum" = option.@"enum",
            .default = option.default,
        });
    }

    try std.json.Stringify.value(schema, .{
        .whitespace = .indent_4,
        .emit_null_optional_fields = false,
    }, writer);

    try writer.writeByte('\n');
    try file_writer.end();
}

const ConfigurationProperty = struct {
    scope: []const u8 = "resource",
    type: []const u8,
    description: []const u8,
    markdownDescription: ?[]const u8 = null,
    @"enum": ?[]const []const u8 = null,
    format: ?[]const u8 = null,
    default: ?std.json.Value = null,
    items: ?struct { type: []const u8 } = null,
};

fn generateVSCodeConfigFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    config: Config,
    path: []const u8,
) !void {
    var config_file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer config_file.close(io);

    var configuration: std.json.ArrayHashMap(ConfigurationProperty) = .{};
    defer {
        for (configuration.map.keys()) |name| allocator.free(name);
        configuration.map.deinit(allocator);
    }

    try configuration.map.ensureTotalCapacity(allocator, @intCast(config.options.len + 3));

    // Client-only settings (not LSP Config fields).
    configuration.map.putAssumeCapacityNoClobber(try allocator.dupe(u8, "zigAnalyzer.serverPath"), .{
        .scope = "machine-overridable",
        .type = "string",
        .description = "Path to the zig-analyzer executable. If empty, the extension looks for `zig-analyzer` on PATH.",
        .default = .{ .string = "" },
        .format = "path",
    });
    configuration.map.putAssumeCapacityNoClobber(try allocator.dupe(u8, "zigAnalyzer.trace.server"), .{
        .scope = "window",
        .type = "string",
        .@"enum" = &.{ "off", "messages", "verbose" },
        .description = "Traces the communication between VS Code and the zig-analyzer language server.",
        .default = .{ .string = "off" },
    });
    configuration.map.putAssumeCapacityNoClobber(try allocator.dupe(u8, "zigAnalyzer.inlayHints.enable"), .{
        .scope = "resource",
        .type = "boolean",
        .description = "Master switch for zig-analyzer inlay hints. When false, all inlay hint categories are disabled.",
        .default = .{ .bool = true },
    });

    for (config.options) |option| {
        if (option.vscode_skip) continue;

        const relative = try option.vscodeRelativeKey(allocator);
        defer allocator.free(relative);

        const full_name = try std.fmt.allocPrint(allocator, "zigAnalyzer.{s}", .{relative});
        errdefer allocator.free(full_name);

        const default: ?std.json.Value = if (std.mem.eql(u8, option.name, "enable_build_on_save"))
            .null
        else if (option.default != .null)
            option.default
        else
            null;

        const is_array = std.mem.eql(u8, option.type, "[]const []const u8");
        const is_path = std.mem.indexOf(u8, option.name, "path") != null or
            std.mem.eql(u8, option.name, "formatter_command") or
            std.mem.eql(u8, option.name, "zig_exe_path");

        configuration.map.putAssumeCapacityNoClobber(full_name, .{
            .scope = option.vscode_scope orelse "resource",
            .type = try option.getTypescriptType(),
            .description = option.description,
            .@"enum" = option.@"enum",
            .format = if (is_path) "path" else null,
            .default = default,
            .items = if (is_array) .{ .type = "string" } else null,
        });
    }

    var buffer: [4096]u8 = undefined;
    var file_writer = config_file.writer(io, &buffer);
    const writer = &file_writer.interface;

    try std.json.Stringify.value(configuration, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }, writer);
    try file_writer.end();
}

fn snakeCaseToCamelCase(allocator: std.mem.Allocator, str: []const u8) error{OutOfMemory}![]u8 {
    const underscore_count = std.mem.count(u8, str, "_");
    var result = try allocator.alloc(u8, str.len - underscore_count);
    var i: usize = 0;
    var j: usize = 0;
    while (i < str.len) : (i += 1) {
        if (str[i] != '_') {
            result[j] = str[i];
            j += 1;
            continue;
        }
        if (i + 1 < str.len and 'a' <= str[i + 1] and str[i + 1] <= 'z') {
            result[j] = std.ascii.toUpper(str[i + 1]);
            i += 1;
            j += 1;
        }
    }
    return result;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var args_it = try init.args.iterateAllocator(gpa);
    defer args_it.deinit();
    _ = args_it.skip();

    var config_path: ?[]const u8 = null;
    var schema_path: ?[]const u8 = null;
    var vscode_config_path: ?[]const u8 = null;
    var builtins_json_path: ?[]const u8 = null;
    var langref_path: ?[]const u8 = null;

    while (args_it.next()) |argname| {
        if (std.mem.eql(u8, argname, "--help")) {
            try std.Io.File.stdout().writeStreamingAll(io,
                \\Usage: zig build gen -- [command]
                \\
                \\Commands:
                \\  --help                             Prints this message
                \\  --generate-vscode-config [path]    Output zigAnalyzer.* VS Code configuration properties
                \\  --generate-config [path]           Output Config.zig (see internal/zig_analyzer/Config.zig)
                \\  --generate-schema [path]           Output JSON schema (see schemas/zig-analyzer.schema.json)
                \\  --generate-builtins-json [path]    Output builtins JSON from Markitdown langref Markdown
                \\  --langref-path [path]              Input langref Markdown (Markitdown output)
                \\
            );
            return std.process.cleanExit(io);
        } else if (std.mem.eql(u8, argname, "--generate-config")) {
            config_path = args_it.next() orelse {
                std.process.fatal("Expected output path after --generate-config argument.\n", .{});
            };
        } else if (std.mem.eql(u8, argname, "--generate-schema")) {
            schema_path = args_it.next() orelse {
                std.process.fatal("Expected output path after --generate-schema argument.\n", .{});
            };
        } else if (std.mem.eql(u8, argname, "--generate-vscode-config")) {
            vscode_config_path = args_it.next() orelse {
                std.process.fatal("Expected output path after --generate-vscode-config argument.\n", .{});
            };
        } else if (std.mem.eql(u8, argname, "--generate-builtins-json")) {
            builtins_json_path = args_it.next() orelse {
                std.process.fatal("Expected output path after --generate-builtins-json argument.\n", .{});
            };
        } else if (std.mem.eql(u8, argname, "--langref-path")) {
            langref_path = args_it.next() orelse {
                std.process.fatal("Expected input path after --langref-path argument.\n", .{});
            };
        } else {
            std.process.fatal("Unrecognized argument '{s}'.\n", .{argname});
        }
    }

    const config_json = try std.json.parseFromSlice(Config, gpa, @embedFile("config.json"), .{
        .ignore_unknown_fields = false,
    });
    defer config_json.deinit();
    const config = config_json.value;

    if (config_path) |output_path| {
        try generateConfigFile(io, gpa, config, output_path);
    }
    if (schema_path) |output_path| {
        try generateSchemaFile(io, gpa, config, output_path);
    }
    if (vscode_config_path) |output_path| {
        try generateVSCodeConfigFile(io, gpa, config, output_path);
    }
    if (builtins_json_path) |output_path| {
        try builtin_serializer.generateBuiltinsJson(
            io,
            gpa,
            output_path,
            langref_path orelse std.process.fatal("--generate-builtins-json requires --langref-path to be specified", .{}),
        );
    }
}
