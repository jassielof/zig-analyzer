//! `textDocument/semanticTokens` — a complement to (not a replacement
//! for) the client's TextMate grammar, not that the client even needs one
//! for correctness's sake: this exists for the cases regex-based
//! highlighting genuinely can't get right, since it has no notion of
//! resolution. A TextMate grammar highlights any `identifier(` as a call
//! whether or not `identifier` resolves to anything; semantic tokens only
//! mark what this analyzer actually knows to be a function, parameter, or
//! local — a typo'd call site just doesn't light up as one. The grammar
//! stays because it's the only thing highlighting anything before the
//! server has finished parsing, or if the server isn't running at all.
//!
//! Covers declaration sites only for now (function/parameter/variable
//! names at their `fn`/param-list/`const`/`var` token) — not yet
//! reference sites (e.g. `helper` at a call site `helper()`), which would
//! need the same scope-walking `resolve.zig` already does, just for every
//! identifier in the file instead of one. A reasonable next increment,
//! not attempted here.

const std = @import("std");
const Ast = std.zig.Ast;

/// Order here is the LSP `legend.tokenTypes` index each variant encodes
/// to — this array and the client-visible legend in `server.zig` must
/// stay in sync.
pub const TokenType = enum(u32) {
    function,
    parameter,
    variable,
};

pub const TokenModifier = enum(u32) {
    declaration,
    readonly,

    pub fn bit(self: TokenModifier) u32 {
        return @as(u32, 1) << @as(u5, @intCast(@intFromEnum(self)));
    }
};

pub const Token = struct {
    line: u32,
    character: u32,
    length: u32,
    token_type: TokenType,
    modifiers: u32 = 0,
};

fn tokenAt(ast: Ast, token: Ast.TokenIndex, token_type: TokenType, modifiers: u32) Token {
    const loc = ast.tokenLocation(0, token);
    return .{
        .line = @intCast(loc.line),
        .character = @intCast(loc.column),
        .length = @intCast(ast.tokenSlice(token).len),
        .token_type = token_type,
        .modifiers = modifiers,
    };
}

fn isConstDecl(ast: Ast, mut_token: Ast.TokenIndex) bool {
    return std.mem.eql(u8, ast.tokenSlice(mut_token), "const");
}

fn collectFnProtoTokens(
    gpa: std.mem.Allocator,
    ast: Ast,
    proto_node: Ast.Node.Index,
    out: *std.ArrayList(Token),
) !void {
    var buf: [1]Ast.Node.Index = undefined;
    const proto = ast.fullFnProto(&buf, proto_node) orelse return;
    if (proto.name_token) |name_token| {
        try out.append(gpa, tokenAt(ast, name_token, .function, TokenModifier.declaration.bit()));
    }
    var it = proto.iterate(&ast);
    while (it.next()) |param| {
        const name_token = param.name_token orelse continue;
        try out.append(gpa, tokenAt(ast, name_token, .parameter, TokenModifier.declaration.bit()));
    }
}

fn collectVarDeclToken(gpa: std.mem.Allocator, ast: Ast, node: Ast.Node.Index, out: *std.ArrayList(Token)) !void {
    const var_decl = ast.fullVarDecl(node) orelse return;
    const name_token = var_decl.ast.mut_token + 1;
    var modifiers: u32 = TokenModifier.declaration.bit();
    if (isConstDecl(ast, var_decl.ast.mut_token)) modifiers |= TokenModifier.readonly.bit();
    try out.append(gpa, tokenAt(ast, name_token, .variable, modifiers));
}

/// Walks root decls (functions and their immediate-body locals/params,
/// top-level `const`/`var`) and returns every declaration-site token,
/// sorted by position as `textDocument/semanticTokens/full`'s delta
/// encoding requires.
pub fn collect(gpa: std.mem.Allocator, ast: Ast) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(gpa);

    for (ast.rootDecls()) |node| {
        switch (ast.nodeTag(node)) {
            .fn_decl => {
                const proto_node, const body_node = ast.nodeData(node).node_and_node;
                try collectFnProtoTokens(gpa, ast, proto_node, &tokens);

                var buf: [2]Ast.Node.Index = undefined;
                const stmts = ast.blockStatements(&buf, body_node) orelse &.{};
                for (stmts) |stmt| try collectVarDeclToken(gpa, ast, stmt, &tokens);
            },
            .fn_proto, .fn_proto_one, .fn_proto_simple, .fn_proto_multi => {
                try collectFnProtoTokens(gpa, ast, node, &tokens);
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                try collectVarDeclToken(gpa, ast, node, &tokens);
            },
            else => {},
        }
    }

    std.mem.sort(Token, tokens.items, {}, lessThan);
    return tokens.toOwnedSlice(gpa);
}

fn lessThan(_: void, a: Token, b: Token) bool {
    if (a.line != b.line) return a.line < b.line;
    return a.character < b.character;
}

/// LSP's semantic token wire format: 5 u32s per token, each field after
/// the first two expressed as a delta from the previous token
/// (deltaLine, deltaStartChar-if-same-line-else-startChar, length, type,
/// modifiers bitmask). `tokens` must already be position-sorted (as
/// `collect` returns them).
pub fn encode(gpa: std.mem.Allocator, tokens: []const Token) ![]u32 {
    var data: std.ArrayList(u32) = .empty;
    errdefer data.deinit(gpa);
    try data.ensureTotalCapacityPrecise(gpa, tokens.len * 5);

    var prev_line: u32 = 0;
    var prev_char: u32 = 0;
    for (tokens) |t| {
        const delta_line = t.line - prev_line;
        const delta_char = if (delta_line == 0) t.character - prev_char else t.character;
        data.appendSliceAssumeCapacity(&.{
            delta_line,
            delta_char,
            t.length,
            @intFromEnum(t.token_type),
            t.modifiers,
        });
        prev_line = t.line;
        prev_char = t.character;
    }
    return data.toOwnedSlice(gpa);
}

const testing = std.testing;

fn collectInSource(gpa: std.mem.Allocator, source: [:0]const u8) ![]Token {
    var ast = try Ast.parse(gpa, source, .zig);
    defer ast.deinit(gpa);
    return collect(gpa, ast);
}

test "collects a function declaration and its parameters" {
    const gpa = testing.allocator;
    const tokens = try collectInSource(gpa, "fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n");
    defer gpa.free(tokens);

    try testing.expectEqual(@as(usize, 3), tokens.len);
    try testing.expectEqual(TokenType.function, tokens[0].token_type);
    try testing.expectEqual(TokenType.parameter, tokens[1].token_type);
    try testing.expectEqual(TokenType.parameter, tokens[2].token_type);
}

test "marks const locals as readonly, var locals as not" {
    const gpa = testing.allocator;
    const tokens = try collectInSource(gpa, "fn f() void {\n    const a = 1;\n    var b = 2;\n    _ = b;\n}\n");
    defer gpa.free(tokens);

    try testing.expectEqual(@as(usize, 3), tokens.len); // fn name + 2 locals
    try testing.expect(tokens[1].modifiers & TokenModifier.readonly.bit() != 0);
    try testing.expect(tokens[2].modifiers & TokenModifier.readonly.bit() == 0);
}

test "top-level const/var are variable tokens" {
    const gpa = testing.allocator;
    const tokens = try collectInSource(gpa, "const max = 64;\nvar counter: usize = 0;\n");
    defer gpa.free(tokens);

    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectEqual(TokenType.variable, tokens[0].token_type);
    try testing.expectEqual(TokenType.variable, tokens[1].token_type);
}

test "tokens come out position-sorted" {
    const gpa = testing.allocator;
    const tokens = try collectInSource(gpa, "fn a() void {}\nfn b(x: i32) void {\n    _ = x;\n}\nconst c = 1;\n");
    defer gpa.free(tokens);

    for (tokens[1..], 0..) |t, i| {
        try testing.expect(!lessThan({}, t, tokens[i]));
    }
}

test "encode produces delta-relative 5-tuples" {
    const gpa = testing.allocator;
    const tokens = [_]Token{
        .{ .line = 0, .character = 3, .length = 3, .token_type = .function, .modifiers = TokenModifier.declaration.bit() },
        .{ .line = 1, .character = 4, .length = 1, .token_type = .parameter, .modifiers = TokenModifier.declaration.bit() },
    };
    const data = try encode(gpa, &tokens);
    defer gpa.free(data);

    try testing.expectEqualSlices(u32, &.{
        0, 3, 3, @intFromEnum(TokenType.function),  TokenModifier.declaration.bit(),
        1, 4, 1, @intFromEnum(TokenType.parameter), TokenModifier.declaration.bit(),
    }, data);
}
