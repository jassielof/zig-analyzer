//! Public module root for zig-analyzer's analysis core.

pub const build_options = @import("build_options");
pub const analysis = @import("analysis.zig");
pub const protocol = @import("protocol.zig");
pub const server = @import("server.zig");
pub const documents = @import("documents.zig");
pub const formatting = @import("formatting.zig");
pub const uri = @import("uri.zig");

comptime {
    @import("std").testing.refAllDecls(@This());
}
