//! Public module root for zig-analyzer's analysis core.

pub const analysis = struct {
    pub const query = @import("analysis/query.zig");
    pub const queries = struct {
        pub const parse = @import("analysis/queries/parse.zig");
        pub const item_tree = @import("analysis/queries/item_tree.zig");
        pub const resolve = @import("analysis/queries/resolve.zig");
        pub const imports = @import("analysis/queries/imports.zig");
        pub const semantic_diagnostics = @import("analysis/queries/semantic_diagnostics.zig");
    };
};

pub const protocol = struct {
    pub const framing = @import("protocol/framing.zig");
    pub const jsonrpc = @import("protocol/jsonrpc.zig");
    pub const harness = @import("protocol/harness.zig");
};

pub const server = @import("server.zig");
pub const documents = @import("documents.zig");

test {
    _ = analysis.query;
    _ = analysis.queries.parse;
    _ = analysis.queries.item_tree;
    _ = analysis.queries.resolve;
    _ = analysis.queries.imports;
    _ = analysis.queries.semantic_diagnostics;
    _ = protocol.framing;
    _ = protocol.jsonrpc;
    _ = protocol.harness;
    _ = server;
    _ = documents;
}
