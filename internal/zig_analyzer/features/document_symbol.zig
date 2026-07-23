//! The document_symbol namespace implementats [`textDocument/documentSymbol`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_documentSymbol).

const std = @import("std");
const Ast = std.zig.Ast;

const types = @import("lsp").types;
const offsets = @import("../offsets.zig");
const ast = @import("../ast.zig");
const analysis = @import("../analysis.zig");
const DocumentStore = @import("../DocumentStore.zig");

/// Caps how many alias hops (`const foo = bar.baz;` where `bar` is itself a resolved import) get chased when classifying a declaration. Bounds cost and rules out cycles.
const max_alias_depth = 3;

const Symbol = struct {
    name_token: Ast.TokenIndex,
    /// Overrides the name derived from `name_token` (`tokenNameMaybeQuotes`) - used for ZON array
    /// elements, which have no name token of their own (just a positional index).
    name_override: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    kind: types.SymbolKind,
    loc: offsets.Loc,
    selection_loc: offsets.Loc,
    children: std.ArrayList(Symbol),
};

/// Returns the string literal argument of `@import("...")`, or null if `node` isn't a single-argument `@import` call. Only the direct whole-file case; `@import(...).Member` isn't handled here since knowing what `Member` actually is needs real type resolution, not a shallow AST check.
fn importedFilePath(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    if (!ast.isBuiltinCall(tree, node)) return null;
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) return null;

    var buffer: [2]Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&buffer, node) orelse return null;
    if (params.len != 1) return null;
    if (tree.nodeTag(params[0]) != .string_literal) return null;

    const raw = tree.tokenSlice(tree.nodeMainToken(params[0]));
    if (raw.len < 2) return null;
    return raw[1 .. raw.len - 1];
}

/// True when `node` is the builtin call `@This()` (no arguments) - it names whatever container encloses it, not a declaration or file elsewhere.
fn isThisCall(tree: *const Ast, node: Ast.Node.Index) bool {
    if (!ast.isBuiltinCall(tree, node)) return false;
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@This")) return false;

    var buffer: [2]Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&buffer, node) orelse return false;
    return params.len == 0;
}

/// True when `container` (a `container_decl`-ish node, or `.root` for the file scope) declares at least one field, as opposed to only declarations - the same "field-less container is a namespace" convention used elsewhere (e.g. docent's `identifier_case` naming-convention rule).
fn containerHasFields(tree: *const Ast, container: Ast.Node.Index) bool {
    if (tree.nodeTag(container) == .root) {
        for (tree.rootDecls()) |decl| {
            if (tree.fullContainerField(decl) != null) return true;
        }
        return false;
    }

    var buffer: [2]Ast.Node.Index = undefined;
    const decl = tree.fullContainerDecl(&buffer, container) orelse return false;
    for (decl.ast.members) |member| {
        if (tree.fullContainerField(member) != null) return true;
    }
    return false;
}

/// Symbol kind for a container declaration's own keyword (`struct`, `union`, `enum`, `opaque`).
/// Field-less struct/opaque containers are namespaces, matching `containerHasFields`.
fn containerDeclSymbolKind(tree: *const Ast, container: Ast.full.ContainerDecl) types.SymbolKind {
    return switch (tree.tokenTag(container.ast.main_token)) {
        .keyword_enum => .Enum,
        .keyword_union => .Struct, // LSP has no dedicated "union" kind.
        .keyword_struct, .keyword_opaque => if (containerHasFieldsFull(tree, container)) .Struct else .Namespace,
        else => .Struct,
    };
}

fn containerHasFieldsFull(tree: *const Ast, container: Ast.full.ContainerDecl) bool {
    for (container.ast.members) |member| {
        if (tree.fullContainerField(member) != null) return true;
    }
    return false;
}

/// Resolves a relative `.zig` `@import(...)` string to its target handle. Returns null for anything that isn't a same-module file import (a named module/dependency like `@import("std")`, or a `.zon` data file) or that can't be resolved.
fn resolveRelativeImportHandle(
    document_store: *DocumentStore,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    import_str: []const u8,
) error{ Canceled, OutOfMemory }!?*DocumentStore.Handle {
    if (!std.mem.endsWith(u8, import_str, ".zig")) return null;
    const result = try document_store.uriFromImportStr(arena, handle, import_str);
    const uri = switch (result) {
        .one => |uri| uri,
        .none, .many => return null,
    };
    return try document_store.getOrLoadHandle(uri);
}

/// Finds a top-level `const`/`var`/`fn` declaration named `name`, returning its declaration node (the `fn_decl` node, or the `var_decl` node).
fn findTopLevelDecl(tree: *const Ast, name: []const u8) ?Ast.Node.Index {
    for (tree.rootDecls()) |decl| {
        switch (tree.nodeTag(decl)) {
            .fn_decl => {
                var buffer: [1]Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&buffer, decl) orelse continue;
                const name_token = proto.name_token orelse continue;
                if (std.mem.eql(u8, tree.tokenSlice(name_token), name)) return decl;
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                const var_decl = tree.fullVarDecl(decl) orelse continue;
                if (std.mem.eql(u8, tree.tokenSlice(var_decl.ast.mut_token + 1), name)) return decl;
            },
            else => {},
        }
    }
    return null;
}

/// Classifies a resolved top-level declaration node (`fn_decl` or `var_decl`) - the target found at the end of an alias chain.
fn classifyTopLevelDecl(
    document_store: *DocumentStore,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    decl_node: Ast.Node.Index,
    depth: u8,
) error{ Canceled, OutOfMemory }!types.SymbolKind {
    const tree = &handle.tree;
    if (tree.nodeTag(decl_node) == .fn_decl) return .Function;

    const var_decl = tree.fullVarDecl(decl_node) orelse return .Constant;
    if (tree.tokenTag(tree.nodeMainToken(decl_node)) != .keyword_const) return .Variable;
    const init_node = var_decl.ast.init_node.unwrap() orelse return .Constant;

    return try classifyConstInit(document_store, arena, handle, init_node, .root, depth);
}

/// Classifies what a `const` declaration's initializer actually declares: a container literal, an error set, a same-module file import, `@This()`, or (up to `depth` hops) a plain alias into one of those (`const foo = bar.baz;` where `bar` is itself a resolved import). Falls back to `.Constant` for anything it can't resolve cheaply - deeper/dynamic aliases need real type inference, which belongs in hover/goto-definition, not a whole-file outline request.
fn classifyConstInit(
    document_store: *DocumentStore,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    init_node: Ast.Node.Index,
    parent_container: Ast.Node.Index,
    depth: u8,
) error{ Canceled, OutOfMemory }!types.SymbolKind {
    const tree = &handle.tree;

    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&buffer, init_node)) |container_decl| {
        return containerDeclSymbolKind(tree, container_decl);
    }
    if (tree.nodeTag(init_node) == .error_set_decl) return .Enum;

    if (importedFilePath(tree, init_node)) |import_str| {
        const target = try resolveRelativeImportHandle(document_store, arena, handle, import_str) orelse
            return .Module; // named module/dependency (e.g. `std`), or a `.zon` data file.
        return if (containerHasFields(&target.tree, .root)) .Struct else .Namespace;
    }

    if (isThisCall(tree, init_node)) {
        return if (containerHasFields(tree, parent_container)) .Struct else .Namespace;
    }

    if (depth > 0 and tree.nodeTag(init_node) == .field_access) {
        const lhs, const field_token = tree.nodeData(init_node).node_and_token;
        const base_token = ast.identifierTokenFromIdentifierNode(tree, lhs) orelse return .Constant;
        const base_decl = findTopLevelDecl(tree, tree.tokenSlice(base_token)) orelse return .Constant;
        const base_var_decl = tree.fullVarDecl(base_decl) orelse return .Constant;
        const base_init = base_var_decl.ast.init_node.unwrap() orelse return .Constant;
        const import_str = importedFilePath(tree, base_init) orelse return .Constant;
        const target = try resolveRelativeImportHandle(document_store, arena, handle, import_str) orelse return .Constant;

        const member_decl = findTopLevelDecl(&target.tree, tree.tokenSlice(field_token)) orelse return .Constant;
        return try classifyTopLevelDecl(document_store, arena, target, member_decl, depth - 1);
    }

    return .Constant;
}

pub fn tokenNameMaybeQuotes(tree: *const Ast, token: Ast.TokenIndex) []const u8 {
    const token_slice = tree.tokenSlice(token);
    switch (tree.tokenTag(token)) {
        .identifier => return token_slice,
        .string_literal => {
            const name = token_slice[1 .. token_slice.len - 1];
            const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
            // LSP spec requires that a symbol name not be empty or consisting only of whitespace, don't trim the quotes in that case so there's something to present.
            // Leading and trailing whitespace might cause ambiguity depending on how the client shows symbols so compensate for that as well
            if (name.len == 0 or name.len != trimmed.len)
                return token_slice;

            return name;
        },
        else => unreachable,
    }
}

/// A `.zon` file's entire content is a single expression - a primitive literal, or an anonymous
/// struct/tuple literal (`.{ ... }`) whose fields/elements can themselves nest more of the same.
/// There's no top-level declaration list to walk like a `.zig` file has, and no `@import`/`@This`/
/// aliasing to resolve (ZON is pure data, similar to JSON) - just this literal's own shape.
///
/// Classification mirrors how editors already outline JSON: a value's own `SymbolKind` describes
/// what *kind of value* it is, not what it's stored as -
///   - struct-init (`.{ .a = 1, .b = 2 }`, named fields) -> `.Object`, one child per field
///   - array-init (`.{ 1, 2, 3 }`, positional elements, ZON's "anonymous tuple literal") ->
///     `.Array`, one child per element, named by its index (there's no source text to name it)
///   - `.number_literal` -> `.Number`; `.string_literal`/`.multiline_string_literal`/`.char_literal`
///     -> `.String`; `.enum_literal` (`.foo`) -> `.EnumMember`
///   - the bare identifiers `true`/`false` -> `.Boolean`; `null` -> `.Null`; `inf`/`nan` -> `.Number`
///     (ZON's boolean/null/nan/inf literals all parse as plain `.identifier` nodes - there's no
///     dedicated node tag for them, so recognizing them means comparing the token text directly,
///     same as `std.zig.ZonGen` does when lowering these same nodes for real evaluation)
///   - anything else -> `.Constant` (shouldn't be reachable for valid ZON, but harmless fallback)
fn classifyZonValue(
    arena: std.mem.Allocator,
    tree: *const Ast,
    node: Ast.Node.Index,
) error{OutOfMemory}!struct {
    kind: types.SymbolKind,
    detail: ?[]const u8,
    children: std.ArrayList(Symbol),
} {
    var buffer: [2]Ast.Node.Index = undefined;

    if (tree.fullStructInit(&buffer, node)) |struct_init| {
        var children: std.ArrayList(Symbol) = .empty;
        try collectZonStructFields(arena, tree, struct_init, &children);
        return .{ .kind = .Object, .detail = null, .children = children };
    }
    if (tree.fullArrayInit(&buffer, node)) |array_init| {
        var children: std.ArrayList(Symbol) = .empty;
        try collectZonArrayElements(arena, tree, array_init, &children);
        return .{ .kind = .Array, .detail = null, .children = children };
    }

    // The full source span, not just the first token: an enum literal's first token is the
    // punctuation `.`, not the identifier after it (`nodeMainToken` is), and this stays correct
    // regardless of how many tokens a value spans (e.g. a negated number literal).
    const detail = offsets.locToSlice(tree.source, offsets.nodeToLoc(tree, node));
    const identifier_text = tree.tokenSlice(tree.nodeMainToken(node));
    const kind: types.SymbolKind = switch (tree.nodeTag(node)) {
        .number_literal => .Number,
        .string_literal, .multiline_string_literal, .char_literal => .String,
        .enum_literal => .EnumMember,
        .identifier => blk: {
            if (std.mem.eql(u8, identifier_text, "true") or std.mem.eql(u8, identifier_text, "false")) break :blk .Boolean;
            if (std.mem.eql(u8, identifier_text, "null")) break :blk .Null;
            if (std.mem.eql(u8, identifier_text, "inf") or std.mem.eql(u8, identifier_text, "nan")) break :blk .Number;
            break :blk .Constant;
        },
        else => .Constant,
    };
    return .{ .kind = kind, .detail = detail, .children = .empty };
}

/// Appends a `Symbol` for every named field of a ZON struct-init - reusing the exact same
/// "there's no dedicated field node, walk back two tokens from the value" trick as
/// `DocumentScope.zig`'s `walkZonStructInitFields`, since ZON struct-init fields have no AST node
/// of their own to name them by.
fn collectZonStructFields(
    arena: std.mem.Allocator,
    tree: *const Ast,
    struct_init: Ast.full.StructInit,
    out: *std.ArrayList(Symbol),
) error{OutOfMemory}!void {
    for (struct_init.ast.fields) |value_node| {
        const name_token = tree.firstToken(value_node) - 2;
        if (tree.tokenTag(name_token) != .identifier) continue;

        const classified = try classifyZonValue(arena, tree, value_node);
        const selection_loc = offsets.tokenToLoc(tree, name_token);
        try out.append(arena, .{
            .name_token = name_token,
            .detail = classified.detail,
            .kind = classified.kind,
            // The field name (`selection_loc`) comes before the value in source, so the full
            // range has to span both - a range covering only the value wouldn't contain it.
            .loc = offsets.locMerge(selection_loc, offsets.nodeToLoc(tree, value_node)),
            .selection_loc = selection_loc,
            .children = classified.children,
        });
    }
}

/// Appends a `Symbol` for every element of a ZON array-init, named by its positional index since
/// array elements have no name of their own.
fn collectZonArrayElements(
    arena: std.mem.Allocator,
    tree: *const Ast,
    array_init: Ast.full.ArrayInit,
    out: *std.ArrayList(Symbol),
) error{OutOfMemory}!void {
    for (array_init.ast.elements, 0..) |element_node, index| {
        const classified = try classifyZonValue(arena, tree, element_node);
        try out.append(arena, .{
            .name_token = tree.firstToken(element_node),
            .name_override = try std.fmt.allocPrint(arena, "{d}", .{index}),
            .detail = classified.detail,
            .kind = classified.kind,
            .loc = offsets.nodeToLoc(tree, element_node),
            .selection_loc = offsets.nodeToLoc(tree, element_node),
            .children = classified.children,
        });
    }
}

fn getZonDocumentSymbols(
    arena: std.mem.Allocator,
    tree: *const Ast,
    encoding: offsets.Encoding,
) error{OutOfMemory}![]types.DocumentSymbol {
    // A bare scalar root (e.g. a lone string literal, which is valid ZON) classifies as a leaf
    // with no children - nothing to outline, so this naturally returns an empty symbol list.
    const classified = try classifyZonValue(arena, tree, tree.nodeData(.root).node);

    var total_symbol_count: usize = 0;
    countSymbolsRecursive(classified.children.items, &total_symbol_count);

    return try convertSymbols(arena, tree, classified.children.items, total_symbol_count, encoding);
}

fn countSymbolsRecursive(symbols: []const Symbol, total: *usize) void {
    total.* += symbols.len;
    for (symbols) |symbol| countSymbolsRecursive(symbol.children.items, total);
}

pub fn getDocumentSymbols(
    arena: std.mem.Allocator,
    document_store: *DocumentStore,
    handle: *DocumentStore.Handle,
    encoding: offsets.Encoding,
) error{ Canceled, OutOfMemory }![]types.DocumentSymbol {
    const tree = &handle.tree;
    if (tree.mode == .zon) return try getZonDocumentSymbols(arena, tree, encoding);

    var symbols: std.ArrayList(Symbol) = .empty;
    var total_symbol_count: usize = 0;

    const StackEntry = struct {
        current_symbols: *std.ArrayList(Symbol),
        last_var_decl_name_token: Ast.OptionalTokenIndex,
        parent_container: Ast.Node.Index,
    };
    var stack: std.ArrayList(StackEntry) = try .initCapacity(arena, 16);
    stack.appendAssumeCapacity(.{
        .current_symbols = &symbols,
        .last_var_decl_name_token = .none,
        .parent_container = .root,
    });

    var walker: ast.Walker = try .init(arena, tree, .root);
    defer walker.deinit(arena);
    while (try walker.next(arena, tree)) |event| {
        const node = switch (event) {
            .open => |node| node,
            .close => {
                stack.items.len -= 1;
                continue;
            },
        };

        try stack.append(arena, stack.getLast());
        const stack_entry: *StackEntry = &stack.items[stack.items.len - 1];

        const symbol: Symbol = switch (tree.nodeTag(node)) {
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            => blk: {
                if (!ast.isContainer(tree, walker.parentNode())) continue;

                const var_decl = tree.fullVarDecl(node).?;
                const var_decl_name_token = var_decl.ast.mut_token + 1;

                stack_entry.last_var_decl_name_token = .fromToken(var_decl_name_token);

                const kind: types.SymbolKind = kind: {
                    // `var` is never a container/module alias worth reclassifying.
                    if (tree.tokenTag(tree.nodeMainToken(node)) != .keyword_const) break :kind .Variable;

                    const init_node = var_decl.ast.init_node.unwrap() orelse break :kind .Constant;

                    break :kind try classifyConstInit(
                        document_store,
                        arena,
                        handle,
                        init_node,
                        stack_entry.parent_container,
                        max_alias_depth,
                    );
                };

                break :blk .{
                    .name_token = var_decl_name_token,
                    .detail = null,
                    .kind = kind,
                    .loc = offsets.nodeToLoc(tree, node),
                    .selection_loc = offsets.tokenToLoc(tree, var_decl_name_token),
                    .children = .empty,
                };
            },

            .test_decl => blk: {
                const test_name_token = tree.nodeData(node).opt_token_and_node[0].unwrap() orelse continue;

                break :blk .{
                    .name_token = test_name_token,
                    .kind = .Method, // there is no SymbolKind that represents a tests
                    .loc = offsets.nodeToLoc(tree, node),
                    .selection_loc = offsets.tokenToLoc(tree, test_name_token),
                    .children = .empty,
                };
            },

            .fn_proto,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto_simple,
            .fn_decl,
            => |tag| blk: {
                if (tag != .fn_decl and tree.nodeTag(walker.parentNode()) == .fn_decl) continue;
                var buffer: [1]Ast.Node.Index = undefined;
                const fn_info = tree.fullFnProto(&buffer, node).?;
                const name_token = fn_info.name_token orelse continue;

                break :blk .{
                    .name_token = name_token,
                    .detail = analysis.getFunctionSignature(tree, fn_info),
                    .kind = .Function,
                    .loc = offsets.nodeToLoc(tree, node),
                    .selection_loc = offsets.tokenToLoc(tree, name_token),
                    .children = .empty,
                };
            },

            .container_field_init,
            .container_field_align,
            .container_field,
            => blk: {
                const container_kind = switch (tree.nodeTag(stack_entry.parent_container)) {
                    .root => .keyword_struct,
                    .container_decl,
                    .container_decl_trailing,
                    .container_decl_arg,
                    .container_decl_arg_trailing,
                    .container_decl_two,
                    .container_decl_two_trailing,
                    => tree.tokenTag(tree.nodeMainToken(stack_entry.parent_container)),
                    .tagged_union,
                    .tagged_union_trailing,
                    .tagged_union_enum_tag,
                    .tagged_union_enum_tag_trailing,
                    .tagged_union_two,
                    .tagged_union_two_trailing,
                    => .keyword_union,
                    else => unreachable,
                };

                const kind: types.SymbolKind = switch (container_kind) {
                    .keyword_struct => .Field,
                    .keyword_union => .Field,
                    .keyword_enum => .EnumMember,
                    .keyword_opaque => continue,
                    else => unreachable,
                };

                var container_field = tree.fullContainerField(node).?;
                switch (container_kind) {
                    .keyword_struct => {},
                    .keyword_enum, .keyword_union => container_field.convertToNonTupleLike(tree),
                    else => unreachable,
                }
                if (container_field.ast.tuple_like) continue;

                const decl_name_token = container_field.ast.main_token;

                if (tree.tokenTag(decl_name_token) != .identifier) {
                    _ = ast.identifierTokenFromIdentifierNode; // possibly related
                    continue;
                }

                const guessed_container_name = if (stack_entry.last_var_decl_name_token.unwrap()) |name_token|
                    offsets.identifierTokenToNameSlice(tree, name_token)
                else
                    null;

                break :blk .{
                    .name_token = decl_name_token,
                    .detail = guessed_container_name,
                    .kind = kind,
                    .loc = offsets.nodeToLoc(tree, node),
                    .selection_loc = offsets.tokenToLoc(tree, decl_name_token),
                    .children = .empty,
                };
            },
            .container_decl,
            .container_decl_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            => {
                stack_entry.parent_container = node;
                continue;
            },
            else => continue,
        };

        switch (tree.tokenTag(symbol.name_token)) {
            .identifier, .string_literal => {},
            else => unreachable,
        }

        try stack_entry.current_symbols.append(arena, symbol);
        stack_entry.current_symbols = &stack_entry.current_symbols.items[stack_entry.current_symbols.items.len - 1].children;
        total_symbol_count += 1;
    }

    std.debug.assert(stack.items.len == 0);

    return try convertSymbols(
        arena,
        tree,
        symbols.items,
        total_symbol_count,
        encoding,
    );
}

/// converts `Symbol` to `types.DocumentSymbol`.
fn convertSymbols(
    arena: std.mem.Allocator,
    tree: *const Ast,
    root_symbols: []const Symbol,
    total_symbol_count: usize,
    encoding: offsets.Encoding,
) error{OutOfMemory}![]types.DocumentSymbol {
    var symbol_buffer: std.ArrayList(types.DocumentSymbol) = .empty;
    try symbol_buffer.ensureTotalCapacityPrecise(arena, total_symbol_count);

    // instead of converting every `offsets.Loc` to `types.Range` by calling `offsets.locToRange` we instead store a mapping from source indices to their desired position, sort them by their source index and then iterate through them which avoids having to re-iterate through the source file to find out the line number
    var mappings: std.ArrayList(offsets.multiple.IndexToPositionMapping) = .empty;
    try mappings.ensureTotalCapacityPrecise(arena, total_symbol_count * 4);

    const root_document_symbols = symbol_buffer.addManyAsSliceAssumeCapacity(root_symbols.len);

    var queue: std.ArrayList(struct { []const Symbol, []types.DocumentSymbol }) = .empty;
    try queue.append(arena, .{ root_symbols, root_document_symbols });

    while (queue.pop()) |item| {
        const symbols, const document_symbols = item;
        for (symbols, document_symbols) |symbol, *document_symbol| {
            const symbol_children = symbol.children.items;
            const document_symbol_children = symbol_buffer.addManyAsSliceAssumeCapacity(symbol_children.len);
            try queue.append(arena, .{ symbol.children.items, document_symbol_children });

            document_symbol.* = .{
                .name = symbol.name_override orelse tokenNameMaybeQuotes(tree, symbol.name_token),
                .detail = symbol.detail,
                .kind = symbol.kind,
                // will be set later through the mapping below
                .range = undefined,
                .selectionRange = undefined,
                .children = document_symbol_children,
            };
            mappings.appendSliceAssumeCapacity(&.{
                .{ .output = &document_symbol.range.start, .source_index = symbol.loc.start },
                .{ .output = &document_symbol.selectionRange.start, .source_index = symbol.selection_loc.start },
                .{ .output = &document_symbol.selectionRange.end, .source_index = symbol.selection_loc.end },
                .{ .output = &document_symbol.range.end, .source_index = symbol.loc.end },
            });
        }
    }
    std.debug.assert(symbol_buffer.items.len == total_symbol_count);

    offsets.multiple.indexToPositionWithMappings(tree.source, mappings.items, encoding);

    return root_document_symbols;
}
