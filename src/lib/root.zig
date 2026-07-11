//! Public module root for zig-analyzer's analysis core.

// TODO: There should be a way to render doctests on hover for declarations, for example, assume the following Zig code:
// ```zig
// test addOne {
//     // A test name can also be written using an identifier.
//     // This is a doctest, and serves as documentation for `addOne`.
//     try std.testing.expectEqual(42, addOne(41));
// }

// /// The function `addOne` adds one to the number given as its argument.
// fn addOne(number: i32) i32 {
//     return number + 1;
// }
// ```
// The function addOne() should be able to also show the test as part of its documentation, under a "Doctests" or "Examples" (prefereably, as doctest is internal targeted, not external) section.
pub const build_options = @import("build_options");
pub const analysis = @import("analysis.zig");
pub const protocol = @import("protocol.zig");
pub const server = @import("server.zig");
pub const documents = @import("documents.zig");
pub const formatting = @import("formatting.zig");

comptime {
    @import("std").testing.refAllDecls(@This());
}
