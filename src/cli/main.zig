//! Entry point. Argument parsing and stdio wiring only — no analysis logic lives here.

const std = @import("std");
const Io = std.Io;

const zig_analyzer = @import("zig_analyzer");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    _ = args; // TODO: --version, --help

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
