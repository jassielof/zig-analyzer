//! Serializes Zig Language Reference Builtin Functions Markdown into a
//! structured JSON schema consumed by zig-analyzer at runtime.
//!
//! Input: Markdown produced by Markitdown from the rendered Zig docs page
//! (`https://ziglang.org/documentation/<version>/`). Zig extracts the Builtin
//! Functions section, cleans heading decorations, strips figure captions /
//! shell output, and emits JSON keyed by builtin name (`@alignOf`, …).
const std = @import("std");
const builtin = @import("builtin");

pub const Parameter = struct {
    signature: []const u8,
};

pub const Builtin = struct {
    parameters: []const Parameter,
    return_type: []const u8,
    documentation: []const u8,
    examples: []const []const u8 = &.{},
};

const PreprocessError = error{
    OutOfMemory,
    BuiltinFunctionsSectionNotFound,
};

/// Takes a signature without name or leading parenthesis, e.g.
/// `comptime DestType: type, integer: anytype) DestType`
fn extractParametersAndReturnTypeFromSignature(
    allocator: std.mem.Allocator,
    signature: [:0]const u8,
) error{OutOfMemory}!struct { []Parameter, []const u8 } {
    var parameters: std.ArrayList(Parameter) = .empty;
    errdefer parameters.deinit(allocator);

    var tokenizer: std.zig.Tokenizer = .init(signature);
    var argument_start: ?usize = null;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => unreachable,
            .l_paren => {
                var paren_depth: usize = 1;
                while (paren_depth > 0) {
                    switch (tokenizer.next().tag) {
                        .l_paren => paren_depth += 1,
                        .r_paren => paren_depth -= 1,
                        else => {},
                    }
                }
                continue;
            },
            .comma, .r_paren => |tag| {
                if (argument_start) |start| {
                    try parameters.append(allocator, .{
                        .signature = std.mem.trim(u8, signature[start..token.loc.start], &std.ascii.whitespace),
                    });
                }
                argument_start = null;
                if (tag == .r_paren) break;
            },
            else => {
                if (argument_start == null) {
                    argument_start = token.loc.start;
                }
            },
        }
    }

    const return_type = std.mem.trim(u8, signature[tokenizer.index..], &std.ascii.whitespace);
    return .{ try parameters.toOwnedSlice(allocator), return_type };
}

fn isShellLikeCode(code: []const u8) bool {
    const trimmed = std.mem.trim(u8, code, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;
    return trimmed[0] == '$';
}

/// Markitdown leaves HTML `<figcaption>` text as bare prose lines before fences:
/// - `Shell` for shell output figures
/// - `some\_file.zig` / `builtin.CallModifier struct.zig` for Zig source figures
fn isFigureCaptionLine(allocator: std.mem.Allocator, line: []const u8) error{OutOfMemory}!bool {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;
    if (std.mem.eql(u8, trimmed, "Shell")) return true;

    // Unescape Markdown `\_` so `test\_this\_builtin.zig` matches as a filename.
    const unescaped = try std.mem.replaceOwned(u8, allocator, trimmed, "\\_", "_");
    defer allocator.free(unescaped);
    return std.mem.endsWith(u8, unescaped, ".zig");
}

/// Collapse runs of blank lines (keep at most one) and trim edges.
fn normalizeDocumentationWhitespace(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var blank_run: usize = 0;
    var started = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const is_blank = std.mem.trim(u8, line, &std.ascii.whitespace).len == 0;
        if (is_blank) {
            if (!started) continue;
            blank_run += 1;
            continue;
        }
        if (blank_run > 0) {
            try out.append(allocator, '\n');
            blank_run = 0;
        }
        if (started) try out.append(allocator, '\n');
        try out.appendSlice(allocator, line);
        started = true;
    }
    return try out.toOwnedSlice(allocator);
}

fn absolutizeFragmentLinks(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    const normalized = try std.mem.replaceOwned(u8, allocator, text, "\r\n", "\n");
    defer allocator.free(normalized);
    const no_cr = try std.mem.replaceOwned(u8, allocator, normalized, "\r", "");
    defer allocator.free(no_cr);

    const docs_base = try std.fmt.allocPrint(
        allocator,
        "](https://ziglang.org/documentation/{s}/#",
        .{builtin.zig_version_string},
    );
    defer allocator.free(docs_base);
    return std.mem.replaceOwned(u8, allocator, no_cr, "](#", docs_base);
}

fn freeBuiltin(allocator: std.mem.Allocator, value: Builtin) void {
    for (value.parameters) |p| allocator.free(p.signature);
    allocator.free(value.parameters);
    allocator.free(value.return_type);
    allocator.free(value.documentation);
    for (value.examples) |ex| allocator.free(ex);
    allocator.free(value.examples);
}

/// Clean Markitdown heading decorations:
/// `### [@addrSpaceCast](#toc-addrSpaceCast) [§](#addrSpaceCast)` → `### @addrSpaceCast`
fn cleanHeadingLine(allocator: std.mem.Allocator, line: []const u8) error{OutOfMemory}![]u8 {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    var hashes: usize = 0;
    while (hashes < trimmed.len and trimmed[hashes] == '#') hashes += 1;
    if (hashes == 0 or hashes >= trimmed.len or trimmed[hashes] != ' ') {
        return try allocator.dupe(u8, trimmed);
    }

    const rest = std.mem.trim(u8, trimmed[hashes + 1 ..], &std.ascii.whitespace);
    const title = blk: {
        if (rest.len > 0 and rest[0] == '[') {
            if (std.mem.indexOfScalar(u8, rest, ']')) |end| {
                break :blk rest[1..end];
            }
        }
        // Already plain, or unexpected form — strip trailing link decorations.
        var plain = rest;
        if (std.mem.indexOf(u8, plain, " [")) |idx| {
            plain = std.mem.trim(u8, plain[0..idx], &std.ascii.whitespace);
        }
        break :blk plain;
    };

    return try std.fmt.allocPrint(allocator, "{s} {s}", .{ trimmed[0..hashes], title });
}

/// Extract the Builtin Functions section from a full Language Reference Markdown
/// page and normalize headings to plain `##` / `###` form.
fn preprocessLangrefMarkdown(allocator: std.mem.Allocator, full_markdown: []const u8) PreprocessError![]u8 {
    const normalized = try std.mem.replaceOwned(u8, allocator, full_markdown, "\r\n", "\n");
    defer allocator.free(normalized);

    // Find the `## … Builtin Functions …` line.
    var section_start: ?usize = null;
    var search: usize = 0;
    while (search < normalized.len) {
        const line_end = std.mem.indexOfScalar(u8, normalized[search..], '\n') orelse normalized.len - search;
        const line = normalized[search .. search + line_end];
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "##") and !std.mem.startsWith(u8, trimmed, "###") and
            std.mem.indexOf(u8, trimmed, "Builtin Functions") != null)
        {
            section_start = search;
            break;
        }
        if (search + line_end >= normalized.len) break;
        search += line_end + 1;
    }

    const start = section_start orelse return error.BuiltinFunctionsSectionNotFound;

    // Find the next sibling `## ` heading after the section start.
    var section_end = normalized.len;
    search = start;
    var first_line = true;
    while (search < normalized.len) {
        const line_end = std.mem.indexOfScalar(u8, normalized[search..], '\n') orelse normalized.len - search;
        const line = normalized[search .. search + line_end];
        if (!first_line) {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "##") and !std.mem.startsWith(u8, trimmed, "###")) {
                section_end = search;
                break;
            }
        }
        first_line = false;
        if (search + line_end >= normalized.len) break;
        search += line_end + 1;
    }

    const section = normalized[start..section_end];

    // Clean heading lines within the section.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, section, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        const trimmed_start = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed_start, "#")) {
            const cleaned = try cleanHeadingLine(allocator, line);
            defer allocator.free(cleaned);
            try out.appendSlice(allocator, cleaned);
        } else {
            try out.appendSlice(allocator, line);
        }
    }
    return try out.toOwnedSlice(allocator);
}

const SectionParts = struct {
    name: []const u8,
    signature: []const u8,
    documentation: []const u8,
    examples: []const []const u8,
};

fn parseBuiltinSection(allocator: std.mem.Allocator, section: []const u8) error{OutOfMemory}!?SectionParts {
    var lines = std.mem.splitScalar(u8, section, '\n');
    const heading_line = lines.next() orelse return null;
    const name = std.mem.trim(u8, heading_line, &std.ascii.whitespace);
    if (name.len == 0 or name[0] != '@') return null;

    var signature: ?[]const u8 = null;
    errdefer if (signature) |s| allocator.free(s);

    var examples: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (examples.items) |ex| allocator.free(ex);
        examples.deinit(allocator);
    }

    var documentation: std.ArrayList(u8) = .empty;
    errdefer documentation.deinit(allocator);

    var in_fence = false;
    var fence_body: std.ArrayList(u8) = .empty;
    defer fence_body.deinit(allocator);

    while (lines.next()) |line| {
        const trimmed_start = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed_start, "```")) {
            if (!in_fence) {
                in_fence = true;
                fence_body.clearRetainingCapacity();
            } else {
                in_fence = false;
                const code_raw = try allocator.dupe(u8, std.mem.trim(u8, fence_body.items, "\r\n"));
                errdefer allocator.free(code_raw);
                const code = try std.mem.replaceOwned(u8, allocator, code_raw, "\r\n", "\n");
                allocator.free(code_raw);
                errdefer allocator.free(code);
                if (isShellLikeCode(code)) {
                    allocator.free(code);
                } else if (signature == null) {
                    signature = code;
                } else {
                    try examples.append(allocator, code);
                }
            }
            continue;
        }

        if (in_fence) {
            if (fence_body.items.len != 0) try fence_body.append(allocator, '\n');
            try fence_body.appendSlice(allocator, line);
        } else if (try isFigureCaptionLine(allocator, line)) {
            // Drop Markitdown figcaption leftovers (`Shell`, `foo.zig`).
        } else {
            if (documentation.items.len != 0) try documentation.append(allocator, '\n');
            try documentation.appendSlice(allocator, line);
        }
    }

    const sig = signature orelse {
        for (examples.items) |ex| allocator.free(ex);
        examples.deinit(allocator);
        documentation.deinit(allocator);
        return null;
    };

    const doc_raw = std.mem.trim(u8, documentation.items, "\r\n");
    const doc_owned = try normalizeDocumentationWhitespace(allocator, doc_raw);
    documentation.deinit(allocator);

    return .{
        .name = name,
        .signature = sig,
        .documentation = doc_owned,
        .examples = try examples.toOwnedSlice(allocator),
    };
}

fn buildBuiltinFromSection(allocator: std.mem.Allocator, parsed: SectionParts) error{OutOfMemory}!?Builtin {
    if (!std.mem.startsWith(u8, parsed.signature, parsed.name)) return null;

    const after_name = parsed.signature[parsed.name.len..];
    const signature_body = if (after_name.len > 0 and after_name[0] == '(')
        after_name[1..]
    else
        after_name;

    const signature_z = try allocator.dupeSentinel(u8, signature_body, 0);
    defer allocator.free(signature_z);

    const sig1 = try std.mem.replaceOwned(u8, allocator, signature_z, "std.builtin.", "");
    defer allocator.free(sig1);
    const sig2 = try std.mem.replaceOwned(u8, allocator, sig1, "builtin.", "");
    defer allocator.free(sig2);
    const sig2_z = try allocator.dupeSentinel(u8, sig2, 0);
    defer allocator.free(sig2_z);

    const parameters, const return_type = try extractParametersAndReturnTypeFromSignature(allocator, sig2_z);
    defer allocator.free(parameters);

    const owned_params = try allocator.alloc(Parameter, parameters.len);
    errdefer {
        for (owned_params) |p| allocator.free(p.signature);
        allocator.free(owned_params);
    }
    for (parameters, owned_params) |src, *dst| {
        dst.* = .{ .signature = try allocator.dupe(u8, src.signature) };
    }

    const owned_examples = try allocator.alloc([]const u8, parsed.examples.len);
    errdefer {
        for (owned_examples) |ex| allocator.free(ex);
        allocator.free(owned_examples);
    }
    for (parsed.examples, owned_examples) |src, *dst| {
        dst.* = try allocator.dupe(u8, src);
    }

    return .{
        .parameters = owned_params,
        .return_type = try allocator.dupe(u8, return_type),
        .documentation = try absolutizeFragmentLinks(allocator, parsed.documentation),
        .examples = owned_examples,
    };
}

pub fn collectBuiltins(
    allocator: std.mem.Allocator,
    markdown: []const u8,
) error{OutOfMemory}!std.StringArrayHashMapUnmanaged(Builtin) {
    var result: std.StringArrayHashMapUnmanaged(Builtin) = .empty;
    errdefer {
        var it = result.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            freeBuiltin(allocator, entry.value_ptr.*);
        }
        result.deinit(allocator);
    }

    // Locate every `### ` heading that begins a line.
    var search_from: usize = 0;
    while (search_from < markdown.len) {
        const relative = blk: {
            if (search_from == 0 and std.mem.startsWith(u8, markdown, "### ")) break :blk @as(usize, 0);
            if (std.mem.indexOf(u8, markdown[search_from..], "\n### ")) |idx|
                break :blk search_from + idx + 1; // point at `#`
            break;
        };
        const content_start = relative + "### ".len;

        const next_relative = if (std.mem.indexOf(u8, markdown[content_start..], "\n### ")) |idx|
            content_start + idx
        else
            markdown.len;

        const section = markdown[content_start..next_relative];
        if (try parseBuiltinSection(allocator, section)) |parsed| {
            defer {
                allocator.free(parsed.signature);
                allocator.free(parsed.documentation);
                for (parsed.examples) |ex| allocator.free(ex);
                allocator.free(parsed.examples);
            }

            if (try buildBuiltinFromSection(allocator, parsed)) |value| {
                const key = try allocator.dupe(u8, parsed.name);
                const gop = try result.getOrPut(allocator, key);
                if (gop.found_existing) {
                    allocator.free(key);
                    freeBuiltin(allocator, value);
                } else {
                    gop.value_ptr.* = value;
                }
            }
        }

        search_from = next_relative;
    }

    return result;
}

/// Parse Markitdown Language Reference Markdown and write builtins JSON.
pub fn generateBuiltinsJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    output_path: []const u8,
    langref_path: []const u8,
) !void {
    const raw_markdown = try std.Io.Dir.cwd().readFileAlloc(io, langref_path, allocator, .limited(32 * 1024 * 1024));
    defer allocator.free(raw_markdown);

    const markdown = preprocessLangrefMarkdown(allocator, raw_markdown) catch |err| switch (err) {
        error.BuiltinFunctionsSectionNotFound => std.process.fatal(
            "Builtin Functions section not found in '{s}'. Is Markitdown output the Zig Language Reference?",
            .{langref_path},
        ),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(markdown);

    var builtins_map = try collectBuiltins(allocator, markdown);
    defer {
        var it = builtins_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            freeBuiltin(allocator, entry.value_ptr.*);
        }
        builtins_map.deinit(allocator);
    }

    if (builtins_map.count() == 0) {
        std.process.fatal(
            "no builtins extracted from '{s}' (is Markitdown output missing ### @name headings?)",
            .{langref_path},
        );
    }

    const json_map: std.json.ArrayHashMap(Builtin) = .{ .map = builtins_map };

    const out_file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer out_file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_writer = out_file.writer(io, &buffer);
    const writer = &file_writer.interface;

    try std.json.Stringify.value(json_map, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }, writer);
    try writer.writeByte('\n');
    try file_writer.end();
}
