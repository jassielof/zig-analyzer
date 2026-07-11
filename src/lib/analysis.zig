pub const query = @import("analysis/query.zig");
pub const queries = struct {
    pub const parse = @import("analysis/queries/parse.zig");
    pub const item_tree = @import("analysis/queries/item_tree.zig");
    pub const resolve = @import("analysis/queries/resolve.zig");
    pub const imports = @import("analysis/queries/imports.zig");
    pub const semantic_diagnostics = @import("analysis/queries/semantic_diagnostics.zig");
};
