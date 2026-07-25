//! Builtin function metadata sourced from the Zig Language Reference.
//!
//! `langref.md` is a vendored Markitdown conversion of
//! <https://ziglang.org/documentation/0.16.0/> (run `zig build update-langref` to refresh it
//! for a new Zig version). `tools/config_gen/builtin_serializer.zig` extracts/serializes
//! builtins out of it into `builtins.json` at build time, which is embedded here and parsed
//! once lazily at runtime.
const std = @import("std");
const builtin = @import("builtin");

pub const Builtin = struct {
    pub const Parameter = struct {
        signature: []const u8,
    };

    parameters: []const Parameter,
    return_type: []const u8,
    documentation: []const u8,
    examples: []const []const u8 = &.{},
};

const builtins_json = @import("builtins_embed").json;

var init_mutex: std.atomic.Mutex = .unlocked;
var builtins_parsed: ?std.json.Parsed(std.json.ArrayHashMap(Builtin)) = null;

fn ensureParsed() *const std.StringArrayHashMapUnmanaged(Builtin) {
    while (!init_mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
    defer init_mutex.unlock();

    if (builtins_parsed == null) {
        builtins_parsed = std.json.parseFromSlice(
            std.json.ArrayHashMap(Builtin),
            std.heap.smp_allocator,
            builtins_json,
            .{},
        ) catch @panic("failed to parse embedded builtins.json");
    }
    return &builtins_parsed.?.value.map;
}

/// Lazily-initialized map of builtin name → metadata.
pub fn builtins() *const std.StringArrayHashMapUnmanaged(Builtin) {
    return ensureParsed();
}

pub fn get(name: []const u8) ?Builtin {
    return ensureParsed().get(name);
}

test "vendored langref matches the compiling Zig version" {
    const vendored_version = std.mem.trim(u8, @embedFile("ZIG_VERSION"), &std.ascii.whitespace);
    if (!std.mem.eql(u8, vendored_version, builtin.zig_version_string)) {
        std.debug.print(
            "lib/langref/langref.md was vendored for Zig {s}, but this build is using Zig {s}. Run `zig build update-langref`.\n",
            .{ vendored_version, builtin.zig_version_string },
        );
        return error.VendoredLangrefStale;
    }
}
