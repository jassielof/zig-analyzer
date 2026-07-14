//! LSP-specific types and utilities on top of `lib/jsonrpc`'s transport
//! layer: generated request/response/notification structs from the LSP
//! spec's `metaModel.json` (`types`, vendored from zigtools/lsp-kit — see
//! its own doc comment for how to regenerate), and position/encoding
//! conversion (`offsets`).

// `types` is a *named* import (not a relative file import), matching how
// `offsets.zig` itself refers to it (`@import("types")`) — both must
// resolve to the exact same module-graph node (see build.zig's
// `lsp_types_mod`), or Zig would treat them as two distinct, incompatible
// copies of the same types despite being structurally identical.
pub const types = @import("types");
pub const offsets = @import("offsets.zig");
