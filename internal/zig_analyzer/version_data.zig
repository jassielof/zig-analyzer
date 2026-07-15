//! Builtin function metadata sourced from the Zig Language Reference.
//!
//! The structured data lives in a generated `builtins.json` (produced by
//! `tools/config_gen/builtin_serializer.zig` from `tools/config_gen/langref.md`)
//! which is embedded via `--embed-dir` at build time and parsed once lazily.
const std = @import("std");

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
