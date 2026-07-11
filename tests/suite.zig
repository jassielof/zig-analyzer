//! Integration test suite root. Tests here exercise the public
//! `zig_analyzer` module API end-to-end (real `Server` + `protocol.harness`
//! driving real framed JSON-RPC), as opposed to `src/lib/**`'s unit tests,
//! which test individual queries/modules in isolation.

test {
    _ = @import("invalid.zig");
}
