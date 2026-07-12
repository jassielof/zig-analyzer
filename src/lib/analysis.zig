pub const query = @import("analysis/query.zig");
pub const queries = struct {
    pub const parse = @import("analysis/queries/parse.zig");
    pub const item_tree = @import("analysis/queries/item_tree.zig");
    pub const resolve = @import("analysis/queries/resolve.zig");
    pub const imports = @import("analysis/queries/imports.zig");
    pub const packages = @import("analysis/queries/packages.zig");
    pub const doc_comments = @import("analysis/queries/doc_comments.zig");
    pub const inlay_hints = @import("analysis/queries/inlay_hints.zig");
    pub const semantic_diagnostics = @import("analysis/queries/semantic_diagnostics.zig");
    pub const semantic_tokens = @import("analysis/queries/semantic_tokens.zig");
    pub const type_mod = @import("analysis/queries/type.zig");
    pub const scope = @import("analysis/queries/scope.zig");
    pub const containers = @import("analysis/queries/containers.zig");
    pub const generics = @import("analysis/queries/generics.zig");
    pub const resolve_expr = @import("analysis/queries/resolve_expr.zig");
};
