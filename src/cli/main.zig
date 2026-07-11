//! Entry point. Argument parsing and stdio wiring only — no analysis logic lives here.

const std = @import("std");
const Io = std.Io;

const zig_analyzer = @import("zig_analyzer");
const build_options = zig_analyzer.build_options;

const usage =
    \\Usage: zig-analyzer [options]
    \\
    \\zig-analyzer is a language server for Zig, speaking LSP over stdio.
    \\It's meant to be launched by an editor, not run interactively.
    \\
    \\Options:
    \\  -h, --help     Print this help and exit
    \\  -v, --version  Print the version and exit
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return printAndExit(io, usage);
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            const message = try std.fmt.allocPrint(arena, "zig-analyzer {s}\n", .{build_options.version});
            return printAndExit(io, message);
        }
    }

    var stdin_buffer: [8192]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var server: zig_analyzer.server.Server = .init(gpa);
    defer server.deinit();

    while (!server.should_exit) {
        const body = zig_analyzer.protocol.framing.readMessage(stdin_reader, gpa) catch |err| {
            std.log.err("malformed message framing: {t}", .{err});
            return 1;
        } orelse break; // client closed stdin: clean shutdown
        defer gpa.free(body);

        server.handleMessage(stdout_writer, body) catch |err| {
            std.log.err("failed handling message: {t}", .{err});
        };
        try stdout_writer.flush();
    }

    return server.exit_code;
}

fn printAndExit(io: Io, message: []const u8) !u8 {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    try stdout_writer.writeAll(message);
    try stdout_writer.flush();
    return 0;
}
