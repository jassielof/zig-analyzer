//! Public module root for zig-analyzer's analysis core.

// TODO: Doc comments aren't being rendered, fix it, the on hover should work for the import, on both sides, from the @import("file|module") side and the `const std` side, on both hovers, each should render the doc comments. for modules, specially on the stdlib, these should be read from the zig's local stdlib, not the web.
// FIXME: Control click to go to references source isn't working.
pub const build_options = @import("build_options");
pub const analysis = @import("analysis.zig");
pub const protocol = @import("protocol.zig");
pub const server = @import("server.zig");
pub const documents = @import("documents.zig");
pub const formatting = @import("formatting.zig");

comptime {
    @import("std").testing.refAllDecls(@This());
}
