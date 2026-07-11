//! Runs an external formatter over a document's text and returns the
//! formatted result. Defaults to `zig fmt --stdin`, but the command and
//! args are configurable (see `Config`) — the std formatter is zero-config,
//! but not everyone wants it (e.g. a different `zig` toolchain, or a
//! wrapper that also runs a linter), so this doesn't hardcode it.
//!
//! The configured formatter must follow the same contract `zig fmt
//! --stdin` does:
//!   1. Read the entire document from stdin.
//!   2. Write the fully formatted result to stdout.
//!   3. Exit 0 on success.
//!
//! A nonzero exit or any stderr output is treated as a formatting
//! failure and the original text is left untouched — this module never
//! applies a partial or ambiguous result.

const std = @import("std");
const Io = std.Io;

pub const Config = struct {
    command: []const u8 = "zig",
    args: []const []const u8 = &.{ "fmt", "--stdin" },
};

pub const Result = union(enum) {
    /// Owned. The formatted document text.
    formatted: []u8,
    /// Owned. Why formatting failed — the formatter's own stderr if it
    /// produced any, otherwise a synthesized message (e.g. "command not
    /// found").
    failure: []u8,

    pub fn deinit(self: Result, gpa: std.mem.Allocator) void {
        switch (self) {
            .formatted => |s| gpa.free(s),
            .failure => |s| gpa.free(s),
        }
    }
};

fn writeStdinThread(file: Io.File, io: Io, source: []const u8) void {
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(file, io, &buffer);
    // Best-effort: if the formatter exits early (e.g. rejects malformed
    // input immediately) this may fail with a broken-pipe-style error.
    // That's fine — the formatter's exit code/stderr is the real signal,
    // read back on the main path below.
    writer.interface.writeAll(source) catch return;
    writer.interface.flush() catch return;
}

/// Runs `config.command config.args...` with `source` piped to its stdin
/// on a dedicated thread (so a formatter that starts writing output
/// before it's finished reading input — or vice versa — can't deadlock
/// against this process reading/writing on a single thread), and
/// collects stdout/stderr.
pub fn format(gpa: std.mem.Allocator, io: Io, config: Config, source: []const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, config.command);
    try argv.appendSlice(gpa, config.args);

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(
            gpa,
            "failed to start formatter \"{s}\": {t}",
            .{ config.command, err },
        ) };
    };
    defer child.kill(io);

    const stdin_file = child.stdin.?;
    child.stdin = null; // ownership moves to the writer thread, which closes it
    const write_thread = try std.Thread.spawn(.{}, writeStdinThread, .{ stdin_file, io, source });
    defer write_thread.join();

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(io);

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer gpa.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);
    errdefer gpa.free(stderr_slice);

    const exited_cleanly = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };

    if (!exited_cleanly or stderr_slice.len > 0) {
        gpa.free(stdout_slice);
        if (stderr_slice.len > 0) return .{ .failure = stderr_slice };
        gpa.free(stderr_slice);
        return .{ .failure = try std.fmt.allocPrint(gpa, "formatter exited with {f}", .{TermFormatter{ .term = term }}) };
    }

    gpa.free(stderr_slice);
    return .{ .formatted = stdout_slice };
}

const TermFormatter = struct {
    term: std.process.Child.Term,

    pub fn format(self: TermFormatter, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self.term) {
            .exited => |code| try writer.print("exit code {d}", .{code}),
            // `std.posix.SIG` is `void` on some targets (e.g. Windows,
            // which has no POSIX signals) and a real enum on others —
            // `{any}` handles both without needing to know which.
            .signal => |sig| try writer.print("signal {any}", .{sig}),
            .stopped => |sig| try writer.print("stopped by signal {any}", .{sig}),
            .unknown => |code| try writer.print("unknown status {d}", .{code}),
        }
    }
};

const testing = std.testing;

test "formats valid source through the real zig fmt --stdin" {
    const gpa = testing.allocator;
    var result = try format(gpa, testing.io, .{}, "const x=1;");
    defer result.deinit(gpa);

    switch (result) {
        .formatted => |text| try testing.expectEqualStrings("const x = 1;\n", text),
        .failure => |msg| {
            std.debug.print("unexpected formatter failure: {s}\n", .{msg});
            return error.UnexpectedFailure;
        },
    }
}

test "reports failure for unformattable source instead of returning garbage" {
    const gpa = testing.allocator;
    var result = try format(gpa, testing.io, .{}, "const x = ;");
    defer result.deinit(gpa);

    switch (result) {
        .formatted => return error.ExpectedFailure,
        .failure => |msg| try testing.expect(msg.len > 0),
    }
}

test "reports a clear failure when the configured command doesn't exist" {
    const gpa = testing.allocator;
    var result = try format(gpa, testing.io, .{ .command = "this-formatter-does-not-exist-anywhere", .args = &.{} }, "const x = 1;");
    defer result.deinit(gpa);

    switch (result) {
        .formatted => return error.ExpectedFailure,
        .failure => |msg| try testing.expect(msg.len > 0),
    }
}
