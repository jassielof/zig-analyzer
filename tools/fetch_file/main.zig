//! Downloads a URL and writes the response body to a file. Used by the build
//! system to fetch build-time inputs (e.g. the LSP metaModel.json) with Zig's
//! own HTTP client instead of shelling out to curl/wget.
const std = @import("std");

pub fn main(init: std.process.Init.Minimal) !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var arg_it = try init.args.iterateAllocator(gpa);
    defer arg_it.deinit();
    _ = arg_it.skip(); // skip self exe

    const url = arg_it.next() orelse std.process.fatal("first argument must be the URL to fetch", .{});
    const out_file_path = arg_it.next() orelse std.process.fatal("second argument must be the output file path", .{});

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var response: std.Io.Writer.Allocating = .init(gpa);
    defer response.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &response.writer,
    });
    if (result.status != .ok) {
        std.log.err("GET {s} failed: HTTP {d}", .{ url, @intFromEnum(result.status) });
        return 1;
    }

    std.Io.Dir.cwd().createDirPath(io, std.Io.Dir.path.dirname(out_file_path) orelse ".") catch {};

    var out_file = try std.Io.Dir.cwd().createFile(io, out_file_path, .{});
    defer out_file.close(io);
    try out_file.writeStreamingAll(io, response.written());

    return 0;
}
