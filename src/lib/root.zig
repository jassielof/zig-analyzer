//! Public module root for zig-analyzer's analysis core.

// TODO: Doc comments aren't being rendered, fix it, the on hover should work for the import, on both sides, from the @import("file|module") side and the `const std` side, on both hovers, each should render the doc comments. for modules, specially on the stdlib, these should be read from the zig's local stdlib, not the web.
// FIXME: Control click to go to references source isn't working properly, it works vaguely, on a single file it'll redirect me from its use to its declaration, but for say, imports, the identifier string for the module, it should redirect me correctly to the source.
// TODO: Add reference counter for functions, structs, enums, etc, as code lenses.
// TODO: Add inlay hints, for function parameters, inferred types, etc.
// TODO: Add unused code detection, Zig itself is set to throw compile errors on unused code, currently it's only for unused values (and function paramters), but will eventually be for imports, functions, structs, etc. Until then, these should be dimmed and marked as unused.
pub const build_options = @import("build_options");
pub const analysis = @import("analysis.zig");
pub const protocol = @import("protocol.zig");
pub const server = @import("server.zig");
pub const documents = @import("documents.zig");
pub const formatting = @import("formatting.zig");

comptime {
    @import("std").testing.refAllDecls(@This());
}
