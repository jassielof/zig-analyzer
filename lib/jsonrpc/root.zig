//! JSON-RPC 2.0: message envelope + `Content-Length` framing. No LSP
//! knowledge — this is the reusable transport layer any JSON-RPC-based
//! protocol could sit on top of; LSP-specific types live in `lib/lsp`.

pub const framing = @import("framing.zig");
pub const jsonrpc = @import("jsonrpc.zig");
