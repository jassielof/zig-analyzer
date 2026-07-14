//! GENERATED FILE — do not hand-edit. Vendored from zigtools/lsp-kit's
//! `0.16.x` branch (not `main`, which targets 0.17.0-dev), produced by its
//! `zig build codegen` step against `metaModel.json` (the LSP spec's own
//! machine-readable schema). To regenerate: check out that branch, run
//! `zig build codegen`, and copy `zig-out/lsp_types.zig` here.
//!
//! Type definitions of the Language Server Protocol.
//!
//! These symbols have been "ziggified" to make better use of namespacing and
//! avoid redundancy in names. See the [Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide)
//!
//! Examples:
//!   - `CompletionItem`              has been renamed to `completion.Item`
//!   - `SemanticTokensRangeParams`   has been renamed to `semantic_tokens.Params.Range`
//!   - `WorkspaceFoldersChangeEvent` has been renamed to `workspace.folders.ChangeEvent`
//!   - `CreateFileOptions`           has been renamed to `WorkspaceEdit.CreateFile.Options`
//!
//! Contributions that try to improve symbol names are welcome.
//!
//! To find the new name for each symbol, use the `@import("lsp").types.flat`
//! namespace. This can also be used in place of the "ziggified" symbols if
//! the original names in the LSP specification are preferred.

const std = @import("std");

const types = @This();
const parser = @import("parser");

/// A normal non document URI.
///
/// The URI’s format is defined in https://tools.ietf.org/html/rfc3986
pub const URI = []const u8;

/// The URI of a document.
///
/// The URI’s format is defined in https://tools.ietf.org/html/rfc3986
pub const DocumentUri = []const u8;

/// A JavaScript regular expression; never used
pub const RegExp = []const u8;

pub const LSPAny = std.json.Value;
pub const LSPArray = []LSPAny;
pub const LSPObject = std.json.ArrayHashMap(std.json.Value);

pub const ID = union(enum) {
    /// The LSP specification generally limits numbers to the range `-2^31` to `2^31 - 1`.
    /// A `i64` is used here to cover against implementations that may decide to use larger numeric ranges.
    number: i64,
    string: []const u8,

    pub fn eql(a: ID, b: ID) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        switch (a) {
            .number => return a.number == b.number,
            .string => return std.mem.eql(u8, a.string, b.string),
        }
    }

    test eql {
        const id_number_3: ID = .{ .number = 3 };
        const id_number_7: ID = .{ .number = 7 };
        const id_string_foo: ID = .{ .string = "foo" };
        const id_string_bar: ID = .{ .string = "bar" };
        const id_string_3: ID = .{ .string = "3" };

        try std.testing.expect(id_number_3.eql(id_number_3));
        try std.testing.expect(!id_number_3.eql(id_number_7));

        try std.testing.expect(id_string_foo.eql(id_string_foo));
        try std.testing.expect(!id_string_foo.eql(id_string_bar));

        try std.testing.expect(!id_number_3.eql(id_string_foo));
        try std.testing.expect(!id_number_3.eql(id_string_3));
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!ID {
        switch (try source.peekNextTokenType()) {
            .number => return .{ .number = try std.json.innerParse(i64, allocator, source, options) },
            .string => return .{ .string = try std.json.innerParse([]const u8, allocator, source, options) },
            else => return error.UnexpectedToken,
        }
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!ID {
        _ = allocator;
        _ = options;
        switch (source) {
            .integer => |number| return .{ .number = number },
            .string => |string| return .{ .string = string },
            else => return error.UnexpectedToken,
        }
    }

    pub fn jsonStringify(self: ID, stream: anytype) @TypeOf(stream.*).Error!void {
        switch (self) {
            inline else => |value| try stream.write(value),
        }
    }
};

/// Indicates in which direction a message is sent in the protocol.
pub const MessageDirection = enum {
    client_to_server,
    server_to_client,
    both,
};

test MessageDirection {
    try std.testing.expectEqual(MessageDirection.server_to_client, requests.get("workspace/configuration").?.direction);
    try std.testing.expectEqual(MessageDirection.client_to_server, notifications.get("textDocument/didOpen").?.direction);
    try std.testing.expectEqual(MessageDirection.both, notifications.get("$/cancelRequest").?.direction);
}

pub const getRequestMetadata = @compileError("Removed; Use `requests.get(method)` instead.");
pub const getNotificationMetadata = @compileError("Removed; Use `notifications.get(method)` instead.");

pub const RegistrationMetadata = struct {
    /// A dynamic registration method if it different from the request's method.
    method: ?[]const u8,
    /// registration options if the request supports dynamic registration.
    Options: ?type,
};

/// Represents a LSP notification
pub const NotificationMetadata = struct {
    /// The notification's method name.
    method: []const u8,
    documentation: ?[]const u8,
    /// The direction in which this notification is sent in the protocol.
    direction: MessageDirection,
    /// The parameter type if any.
    Params: ?type,
    registration: RegistrationMetadata,
};

/// Represents a LSP request
pub const RequestMetadata = struct {
    /// The request's method name.
    method: []const u8,
    documentation: ?[]const u8,
    /// The direction in which this request is sent in the protocol.
    direction: MessageDirection,
    /// The parameter type if any.
    Params: ?type,
    /// The result type.
    Result: type,
    /// Partial result type if the request supports partial result reporting.
    PartialResult: ?type,
    /// An optional error data type.
    ErrorData: ?type,
    registration: RegistrationMetadata,
};

pub const request_metadata = @compileError("Removed; Use `requests.values()` instead.");
pub const notification_metadata = @compileError("Removed; Use `notifications.values()` instead.");

/// A set of Request with comptime-known metadata about them.
pub const requests: std.StaticStringMap(RequestMetadata) = types.requests_generated;

/// A set of Notification with comptime-known metadata about them.
pub const notifications: std.StaticStringMap(NotificationMetadata) = types.notifications_generated;

fn testType(comptime T: type) void {
    if (T == void) return;
    if (T == ?void) return;

    const S = struct {
        fn parseFromValue() void {
            _ = std.json.parseFromValue(T, undefined, undefined, undefined) catch unreachable;
        }
        fn innerParse() void {
            var source: std.json.Scanner = undefined;
            _ = std.json.innerParse(T, undefined, &source, undefined) catch unreachable;
        }
        fn stringify() void {
            const value: T = undefined;
            _ = std.json.stringify(value, undefined, std.io.null_writer) catch unreachable;
        }
    };
    _ = &S.parseFromValue;
    _ = &S.innerParse;
    _ = &S.stringify;
}

test {
    for (types.notifications.values()) |metadata| {
        if (metadata.Params) |Params| {
            testType(Params);
        }
    }
    for (types.requests.values()) |metadata| {
        if (metadata.Params) |Params| {
            testType(Params);
        }
        testType(metadata.Result);
        if (metadata.PartialResult) |PartialResult| {
            testType(PartialResult);
        }
        if (metadata.ErrorData) |ErrorData| {
            testType(ErrorData);
        }
    }
}

/// Position in a text document expressed as zero-based line and character
/// offset. Prior to 3.17 the offsets were always based on a UTF-16 string
/// representation. So a string of the form `a𐐀b` the character offset of the
/// character `a` is 0, the character offset of `𐐀` is 1 and the character
/// offset of b is 3 since `𐐀` is represented using two code units in UTF-16.
/// Since 3.17 clients and servers can agree on a different string encoding
/// representation (e.g. UTF-8). The client announces it's supported encoding
/// via the client capability [`general.positionEncodings`](https://microsoft.github.io/language-server-protocol/specifications/specification-current/#clientCapabilities).
/// The value is an array of position encodings the client supports, with
/// decreasing preference (e.g. the encoding at index `0` is the most preferred
/// one). To stay backwards compatible the only mandatory encoding is UTF-16
/// represented via the string `utf-16`. The server can pick one of the
/// encodings offered by the client and signals that encoding back to the
/// client via the initialize result's property
/// [`capabilities.positionEncoding`](https://microsoft.github.io/language-server-protocol/specifications/specification-current/#serverCapabilities). If the string value
/// `utf-16` is missing from the client's capability `general.positionEncodings`
/// servers can safely assume that the client supports UTF-16. If the server
/// omits the position encoding in its initialize result the encoding defaults
/// to the string value `utf-16`. Implementation considerations: since the
/// conversion from one encoding into another requires the content of the
/// file / line the conversion is best done where the file is read which is
/// usually on the server side.
///
/// Positions are line end character agnostic. So you can not specify a position
/// that denotes `\r|\n` or `\n|` where `|` represents the character offset.
///
/// @since 3.17.0 - support for negotiated position encoding.
pub const Position = struct {
    /// Line position in a document (zero-based).
    line: u32,
    /// Character offset on a line in a document (zero-based).
    ///
    /// The meaning of this offset is determined by the negotiated
    /// `PositionEncodingKind`.
    character: u32,

    /// A set of predefined position encoding kinds.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `PositionEncodingKind`
    pub const EncodingKind = union(enum) {
        /// Character offsets count UTF-8 code units (e.g. bytes).
        @"utf-8",
        /// Character offsets count UTF-16 code units.
        ///
        /// This is the default and must always be supported
        /// by servers
        @"utf-16",
        /// Character offsets count UTF-32 code units.
        ///
        /// Implementation note: these are the same as Unicode codepoints,
        /// so this `PositionEncodingKind` may also be used for an
        /// encoding-agnostic representation of character offsets.
        @"utf-32",
        custom_value: []const u8,

        pub const eql = parser.EnumCustomStringValues(@This(), false).eql;
        pub const jsonParse = parser.EnumCustomStringValues(@This(), false).jsonParse;
        pub const jsonParseFromValue = parser.EnumCustomStringValues(@This(), false).jsonParseFromValue;
        pub const jsonStringify = parser.EnumCustomStringValues(@This(), false).jsonStringify;
    };
};

/// A range in a text document expressed as (zero-based) start and end positions.
///
/// If you want to specify a range that contains a line including the line ending
/// character(s) then use an end position denoting the start of the next line.
/// For example:
/// ```ts
/// {
///     start: { line: 5, character: 23 }
///     end : { line 6, character : 0 }
/// }
/// ```
pub const Range = struct {
    /// The range's start position.
    start: Position,
    /// The range's end position.
    end: Position,
};

/// A text edit applicable to a text document.
pub const TextEdit = struct {
    /// The range of the text document to be manipulated. To insert
    /// text into a document create a range where start === end.
    range: Range,
    /// The string to be inserted. For delete operations use an
    /// empty string.
    newText: []const u8,

    /// A special text edit with an additional change annotation.
    ///
    /// @since 3.16.0.
    ///
    /// LSP Specification name: `AnnotatedTextEdit`
    pub const Annotated = struct {
        /// The actual identifier of the change annotation
        annotationId: ChangeAnnotationIdentifier,

        // Extends `TextEdit`
        /// The range of the text document to be manipulated. To insert
        /// text into a document create a range where start === end.
        range: Range,
        /// The string to be inserted. For delete operations use an
        /// empty string.
        newText: []const u8,
    };
};

/// Represents a location inside a resource, such as a line
/// inside a text file.
pub const Location = struct {
    uri: DocumentUri,
    range: Range,
};

/// Represents the connection of two locations. Provides additional metadata over normal {@link Location locations},
/// including an origin range.
pub const LocationLink = struct {
    /// Span of the origin of this link.
    ///
    /// Used as the underlined span for mouse interaction. Defaults to the word range at
    /// the definition position.
    originSelectionRange: ?Range = null,
    /// The target resource identifier of this link.
    targetUri: DocumentUri,
    /// The full target range of this link. If the target for example is a symbol then target range is the
    /// range enclosing this symbol not including leading/trailing whitespace but everything else
    /// like comments. This information is typically used to highlight the range in the editor.
    targetRange: Range,
    /// The range that should be selected and revealed when this link is being followed, e.g the name of a function.
    /// Must be contained by the `targetRange`. See also `DocumentSymbol#range`
    targetSelectionRange: Range,
};

/// A human-readable string that represents a doc-comment.
pub const Documentation = union(enum) {
    string: []const u8,
    markup_content: MarkupContent,

    pub const jsonParse = parser.UnionParser(@This()).jsonParse;
    pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
    pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
};

/// Describes the content type that a client supports in various
/// result literals like `Hover`, `ParameterInfo` or `CompletionItem`.
///
/// Please note that `MarkupKinds` must not start with a `$`. This kinds
/// are reserved for internal usage.
pub const MarkupKind = union(enum) {
    /// Plain text is supported as a content format
    plaintext,
    /// Markdown is supported as a content format
    markdown,
    unknown_value: []const u8,

    pub const eql = parser.EnumCustomStringValues(@This(), false).eql;
    pub const jsonParse = parser.EnumCustomStringValues(@This(), false).jsonParse;
    pub const jsonParseFromValue = parser.EnumCustomStringValues(@This(), false).jsonParseFromValue;
    pub const jsonStringify = parser.EnumCustomStringValues(@This(), false).jsonStringify;
};

/// A `MarkupContent` literal represents a string value which content is interpreted base on its
/// kind flag. Currently the protocol supports `plaintext` and `markdown` as markup kinds.
///
/// If the kind is `markdown` then the value can contain fenced code blocks like in GitHub issues.
/// See https://help.github.com/articles/creating-and-highlighting-code-blocks/#syntax-highlighting
///
/// Here is an example how such a string can be constructed using JavaScript / TypeScript:
/// ```ts
/// let markdown: MarkdownContent = {
///  kind: MarkupKind.Markdown,
///  value: [
///    '# Header',
///    'Some text',
///    '```typescript',
///    'someCode();',
///    '```'
///  ].join('\n')
/// };
/// ```
///
/// *Please Note* that clients might sanitize the return markdown. A client could decide to
/// remove HTML from the markdown to avoid script execution.
pub const MarkupContent = struct {
    /// The type of the Markup
    kind: MarkupKind,
    /// The content itself
    value: []const u8,
};

/// Represents a reference to a command. Provides a title which
/// will be used to represent a command in the UI and, optionally,
/// an array of arguments which will be passed to the command handler
/// function when invoked.
pub const Command = struct {
    /// Title of the command, like `save`.
    title: []const u8,
    /// An optional tooltip.
    ///
    /// @since 3.18.0
    /// @proposed
    tooltip: ?[]const u8 = null,
    /// The identifier of the actual command handler.
    command: []const u8,
    /// Arguments that the command handler should be
    /// invoked with.
    arguments: ?[]const LSPAny = null,
};

/// The glob pattern. Either a string pattern or a relative pattern.
///
/// @since 3.17.0
pub const GlobPattern = union(enum) {
    pattern: Pattern,
    relative_pattern: RelativePattern,

    pub const jsonParse = parser.UnionParser(@This()).jsonParse;
    pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
    pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
};

/// The glob pattern to watch relative to the base path. Glob patterns can have the following syntax:
/// - `*` to match zero or more characters in a path segment
/// - `?` to match on one character in a path segment
/// - `**` to match any number of path segments, including none
/// - `{}` to group conditions (e.g. `**​/*.{ts,js}` matches all TypeScript and JavaScript files)
/// - `[]` to declare a range of characters to match in a path segment (e.g., `example.[0-9]` to match on `example.0`, `example.1`, …)
/// - `[!...]` to negate a range of characters to match in a path segment (e.g., `example.[!0-9]` to match on `example.a`, `example.b`, but not `example.0`)
///
/// @since 3.17.0
pub const Pattern = []const u8;

/// A relative pattern is a helper to construct glob patterns that are matched
/// relatively to a base URI. The common value for a `baseUri` is a workspace
/// folder root, but it can be another absolute URI as well.
///
/// @since 3.17.0
pub const RelativePattern = struct {
    /// A workspace folder or a base URI to which this pattern will be matched
    /// against relatively.
    baseUri: union(enum) {
        workspace_folder: workspace.Folder,
        uri: URI,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    },
    /// The actual glob pattern;
    pattern: Pattern,
};

/// A document selector is the combination of one or many document filters.
///
/// @sample `let sel:DocumentSelector = [{ language: 'typescript' }, { language: 'json', pattern: '**∕tsconfig.json' }]`;
///
/// The use of a string as a document filter is deprecated @since 3.16.0.
pub const DocumentSelector = []const DocumentFilter;

/// Additional information that describes document changes.
///
/// @since 3.16.0
pub const ChangeAnnotation = struct {
    /// A human-readable string describing the actual change. The string
    /// is rendered prominent in the user interface.
    label: []const u8,
    /// A flag which indicates that user confirmation is needed
    /// before applying the change.
    needsConfirmation: ?bool = null,
    /// A human-readable string which is rendered less prominent in
    /// the user interface.
    description: ?[]const u8 = null,
};

/// An identifier to refer to a change annotation stored with a workspace edit.
pub const ChangeAnnotationIdentifier = []const u8;

/// Information about the server
///
/// @since 3.15.0
/// @since 3.18.0 ServerInfo type name added.
pub const ServerInfo = struct {
    /// The name of the server as defined by the server.
    name: []const u8,
    /// The server's version as defined by the server.
    version: ?[]const u8 = null,
};

/// Information about the client
///
/// @since 3.15.0
/// @since 3.18.0 ClientInfo type name added.
pub const ClientInfo = struct {
    /// The name of the client as defined by the client.
    name: []const u8,
    /// The client's version as defined by the client.
    version: ?[]const u8 = null,
};

pub const PartialResultParams = struct {
    /// An optional token that a server can use to report partial results (e.g. streaming) to
    /// the client.
    partialResultToken: ?ProgressToken = null,
};

/// A previous result id in a workspace pull request.
///
/// @since 3.17.0
pub const PreviousResultId = struct {
    /// The URI for which the client knowns a
    /// result id.
    uri: DocumentUri,
    /// The value of the previous result id.
    value: []const u8,
};

pub const ProgressParams = struct {
    /// The progress token provided by the client or server.
    token: ProgressToken,
    /// The progress data.
    value: LSPAny,
};

pub const ProgressToken = union(enum) {
    integer: i32,
    string: []const u8,

    pub const jsonParse = parser.UnionParser(@This()).jsonParse;
    pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
    pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
};

/// Predefined error codes.
pub const ErrorCodes = enum(i32) {
    ParseError = -32700,
    InvalidRequest = -32600,
    MethodNotFound = -32601,
    InvalidParams = -32602,
    InternalError = -32603,
    /// Error code indicating that a server received a notification or
    /// request before the server has received the `initialize` request.
    ServerNotInitialized = -32002,
    UnknownErrorCode = -32001,
    /// Custom Value
    _,

    pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
};

pub const LSPErrorCodes = enum(i32) {
    /// A request failed but it was syntactically correct, e.g the
    /// method name was known and the parameters were valid. The error
    /// message should contain human readable information about why
    /// the request failed.
    ///
    /// @since 3.17.0
    RequestFailed = -32803,
    /// The server cancelled the request. This error code should
    /// only be used for requests that explicitly support being
    /// server cancellable.
    ///
    /// @since 3.17.0
    ServerCancelled = -32802,
    /// The server detected that the content of a document got
    /// modified outside normal conditions. A server should
    /// NOT send this error code if it detects a content change
    /// in it unprocessed messages. The result even computed
    /// on an older state might still be useful for the client.
    ///
    /// If a client decides that a result is not of any use anymore
    /// the client should cancel the request.
    ContentModified = -32801,
    /// The client has canceled a request and a server has detected
    /// the cancel.
    RequestCancelled = -32800,
    /// Custom Value
    _,

    pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
};

/// Value-object describing what options formatting should use.
pub const FormattingOptions = struct {
    /// Size of a tab in spaces.
    tabSize: u32,
    /// Prefer spaces over tabs.
    insertSpaces: bool,
    /// Trim trailing whitespace on a line.
    ///
    /// @since 3.15.0
    trimTrailingWhitespace: ?bool = null,
    /// Insert a newline character at the end of the file if one does not exist.
    ///
    /// @since 3.15.0
    insertFinalNewline: ?bool = null,
    /// Trim all newlines after the final newline at the end of the file.
    ///
    /// @since 3.15.0
    trimFinalNewlines: ?bool = null,
};

/// Defines whether the insert text in a completion item should be interpreted as
/// plain text or a snippet.
pub const InsertTextFormat = enum(u32) {
    /// The primary text to be inserted is treated as a plain string.
    PlainText = 1,
    /// The primary text to be inserted is treated as a snippet.
    ///
    /// A snippet can define tab stops and placeholders with `$1`, `$2`
    /// and `${3:foo}`. `$0` defines the final tab stop, it defaults to
    /// the end of the snippet. Placeholders with equal identifiers are linked,
    /// that is typing in one will update others too.
    ///
    /// See also: https://microsoft.github.io/language-server-protocol/specifications/specification-current/#snippet_syntax
    Snippet = 2,
    /// Unknown Value
    _,

    pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
};

/// How whitespace and indentation is handled during completion
/// item insertion.
///
/// @since 3.16.0
pub const InsertTextMode = enum(u32) {
    /// The insertion or replace strings is taken as it is. If the
    /// value is multi line the lines below the cursor will be
    /// inserted using the indentation defined in the string value.
    /// The client will not apply any kind of adjustments to the
    /// string.
    asIs = 1,
    /// The editor adjusts leading whitespace of new lines so that
    /// they match the indentation up to the cursor of the line for
    /// which the item is accepted.
    ///
    /// Consider a line like this: <2tabs><cursor><3tabs>foo. Accepting a
    /// multi line completion item is indented using 2 tabs and all
    /// following lines inserted will be indented using 2 tabs as well.
    adjustIndentation = 2,
    /// Unknown Value
    _,

    pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
};

/// Represents a color in RGBA space.
pub const Color = struct {
    /// The red component of this color in the range [0-1].
    red: f32,
    /// The green component of this color in the range [0-1].
    green: f32,
    /// The blue component of this color in the range [0-1].
    blue: f32,
    /// The alpha component of this color in the range [0-1].
    alpha: f32,
};

/// A string value used as a snippet is a template which allows to insert text
/// and to control the editor cursor when insertion happens.
///
/// A snippet can define tab stops and placeholders with `$1`, `$2`
/// and `${3:foo}`. `$0` defines the final tab stop, it defaults to
/// the end of the snippet. Variables are defined with `$name` and
/// `${name:default value}`.
///
/// @since 3.18.0
/// @proposed
pub const StringValue = struct {
    /// The kind of string value.
    kind: []const u8 = "snippet",
    /// The snippet string.
    value: []const u8,
};

/// Represents information about programming constructs like variables, classes,
/// interfaces etc.
pub const SymbolInformation = struct {
    /// Indicates if this symbol is deprecated.
    ///
    /// @deprecated Use tags instead
    deprecated: ?bool = null,
    /// The location of this symbol. The location's range is used by a tool
    /// to reveal the location in the editor. If the symbol is selected in the
    /// tool the range's start information is used to position the cursor. So
    /// the range usually spans more than the actual symbol's name and does
    /// normally include things like visibility modifiers.
    ///
    /// The range doesn't have to denote a node range in the sense of an abstract
    /// syntax tree. It can therefore not be used to re-construct a hierarchy of
    /// the symbols.
    location: Location,

    // Extends `BaseSymbolInformation`
    /// The name of this symbol.
    name: []const u8,
    /// The kind of this symbol.
    kind: SymbolKind,
    /// Tags for this symbol.
    ///
    /// @since 3.16.0
    tags: ?[]const SymbolTag = null,
    /// The name of the symbol containing this symbol. This information is for
    /// user interface purposes (e.g. to render a qualifier in the user interface
    /// if necessary). It can't be used to re-infer a hierarchy for the document
    /// symbols.
    containerName: ?[]const u8 = null,
};

/// A symbol kind.
pub const SymbolKind = enum(u32) {
    File = 1,
    Module = 2,
    Namespace = 3,
    Package = 4,
    Class = 5,
    Method = 6,
    Property = 7,
    Field = 8,
    Constructor = 9,
    Enum = 10,
    Interface = 11,
    Function = 12,
    Variable = 13,
    Constant = 14,
    String = 15,
    Number = 16,
    Boolean = 17,
    Array = 18,
    Object = 19,
    Key = 20,
    Null = 21,
    EnumMember = 22,
    Struct = 23,
    Event = 24,
    Operator = 25,
    TypeParameter = 26,
    /// Unknown Value
    _,

    pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
};

/// Symbol tags are extra annotations that tweak the rendering of a symbol.
///
/// @since 3.16
pub const SymbolTag = enum(u32) {
    /// Render a symbol as obsolete, usually using a strike-out.
    Deprecated = 1,
    /// Unknown Value
    _,

    pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
};

pub const InitializedParams = struct {};

/// The data type of the ResponseError if the
/// initialize request fails.
pub const InitializeError = struct {
    /// Indicates whether the client execute the following retry logic:
    /// (1) show the message provided by the ResponseError to the user
    /// (2) user selects retry or cancel
    /// (3) if user selected retry the initialize method is sent again.
    retry: bool,
};

pub const InitializeParams = struct {
    // Extends `_InitializeParams`
    /// The process Id of the parent process that started
    /// the server.
    ///
    /// Is `null` if the process has not been started by another process.
    /// If the parent process is not alive then the server should exit.
    processId: ?i32 = null,
    /// Information about the client
    ///
    /// @since 3.15.0
    clientInfo: ?ClientInfo = null,
    /// The locale the client is currently showing the user interface
    /// in. This must not necessarily be the locale of the operating
    /// system.
    ///
    /// Uses IETF language tags as the value's syntax
    /// (See https://en.wikipedia.org/wiki/IETF_language_tag)
    ///
    /// @since 3.16.0
    locale: ?[]const u8 = null,
    /// The rootPath of the workspace. Is null
    /// if no folder is open.
    ///
    /// @deprecated in favour of rootUri.
    rootPath: ?[]const u8 = null,
    /// The rootUri of the workspace. Is null if no
    /// folder is open. If both `rootPath` and `rootUri` are set
    /// `rootUri` wins.
    ///
    /// @deprecated in favour of workspaceFolders.
    rootUri: ?DocumentUri = null,
    /// The capabilities provided by the client (editor or tool)
    capabilities: ClientCapabilities,
    /// User provided initialization options.
    initializationOptions: ?LSPAny = null,
    /// The initial trace setting. If omitted trace is disabled ('off').
    trace: ?trace.Value = null,

    // Uses mixin `WorkDoneProgressParams`
    /// An optional token that a server can use to report work done progress.
    workDoneToken: ?ProgressToken = null,

    // Extends `WorkspaceFoldersInitializeParams`
    /// The workspace folders configured in the client when the server starts.
    ///
    /// This property is only available if the client supports workspace folders.
    /// It can be `null` if the client supports workspace folders but none are
    /// configured.
    ///
    /// @since 3.6.0
    workspaceFolders: ?[]const workspace.Folder = null,
};

/// The result returned from an initialize request.
pub const InitializeResult = struct {
    /// The capabilities the language server provides.
    capabilities: ServerCapabilities,
    /// Information about the server.
    ///
    /// @since 3.15.0
    serverInfo: ?ServerInfo = null,
};

pub const CancelParams = struct {
    /// The request id to cancel.
    id: types.ID,
};

/// An item to transfer a text document from the client to the
/// server.
///
/// LSP Specification name: `TextDocumentItem`
pub const TextDocument = struct {
    /// The text document's uri.
    uri: DocumentUri,
    /// The text document's language identifier.
    languageId: LanguageKind,
    /// The version number of this document (it will increase after each
    /// change, including undo/redo).
    version: i32,
    /// The content of the opened text document.
    text: []const u8,

    /// Describes textual changes on a text document. A TextDocumentEdit describes all changes
    /// on a document version Si and after they are applied move the document to version Si+1.
    /// So the creator of a TextDocumentEdit doesn't need to sort the array of edits or do any
    /// kind of ordering. However the edits must be non overlapping.
    ///
    /// LSP Specification name: `TextDocumentEdit`
    pub const Edit = struct {
        /// The text document to change.
        textDocument: Identifier.Versioned.Optional,
        /// The edits to be applied.
        ///
        /// @since 3.16.0 - support for AnnotatedTextEdit. This is guarded using a
        /// client capability.
        ///
        /// @since 3.18.0 - support for SnippetTextEdit. This is guarded using a
        /// client capability.
        edits: []const union(enum) {
            text_edit: TextEdit,
            annotated_text_edit: TextEdit.Annotated,
            snippet_text_edit: Snippet,

            pub const jsonParse = parser.UnionParser(@This()).jsonParse;
            pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
            pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
        },

        /// An interactive text edit.
        ///
        /// @since 3.18.0
        /// @proposed
        ///
        /// LSP Specification name: `SnippetTextEdit`
        pub const Snippet = struct {
            /// The range of the text document to be manipulated.
            range: Range,
            /// The snippet to be inserted.
            snippet: StringValue,
            /// The actual identifier of the snippet edit.
            annotationId: ?ChangeAnnotationIdentifier = null,
        };
    };

    /// A literal to identify a text document in the client.
    ///
    /// LSP Specification name: `TextDocumentIdentifier`
    pub const Identifier = struct {
        /// The text document's uri.
        uri: DocumentUri,

        /// A text document identifier to denote a specific version of a text document.
        ///
        /// LSP Specification name: `VersionedTextDocumentIdentifier`
        pub const Versioned = struct {
            /// The version number of this document.
            version: i32,

            // Extends `TextDocumentIdentifier`
            /// The text document's uri.
            uri: DocumentUri,

            /// A text document identifier to optionally denote a specific version of a text document.
            ///
            /// LSP Specification name: `OptionalVersionedTextDocumentIdentifier`
            pub const Optional = struct {
                /// The version number of this document. If a versioned text document identifier
                /// is sent from the server to the client and the file is not open in the editor
                /// (the server has not received an open notification before) the server can send
                /// `null` to indicate that the version is unknown and the content on disk is the
                /// truth (as specified with document content ownership).
                version: ?i32 = null,

                // Extends `TextDocumentIdentifier`
                /// The text document's uri.
                uri: DocumentUri,
            };
        };
    };

    /// The change text document notification's parameters.
    ///
    /// LSP Specification name: `DidChangeTextDocumentParams`
    pub const DidChangeParams = struct {
        /// The document that did change. The version number points
        /// to the version after all provided content changes have
        /// been applied.
        textDocument: Identifier.Versioned,
        /// The actual content changes. The content changes describe single state changes
        /// to the document. So if there are two content changes c1 (at array index 0) and
        /// c2 (at array index 1) for a document in state S then c1 moves the document from
        /// S to S' and c2 from S' to S''. So c1 is computed on the state S and c2 is computed
        /// on the state S'.
        ///
        /// To mirror the content of a document using change events use the following approach:
        /// - start with the same initial content
        /// - apply the 'textDocument/didChange' notifications in the order you receive them.
        /// - apply the `TextDocumentContentChangeEvent`s in a single notification in the order
        ///   you receive them.
        contentChanges: []const ContentChangeEvent,
    };

    /// The parameters sent in a close text document notification
    ///
    /// LSP Specification name: `DidCloseTextDocumentParams`
    pub const DidCloseParams = struct {
        /// The document that was closed.
        textDocument: Identifier,
    };

    /// The parameters sent in an open text document notification
    ///
    /// LSP Specification name: `DidOpenTextDocumentParams`
    pub const DidOpenParams = struct {
        /// The document that was opened.
        textDocument: TextDocument,
    };

    /// The parameters sent in a save text document notification
    ///
    /// LSP Specification name: `DidSaveTextDocumentParams`
    pub const DidSaveParams = struct {
        /// The document that was saved.
        textDocument: Identifier,
        /// Optional the content when saved. Depends on the includeText value
        /// when the save notification was requested.
        text: ?[]const u8 = null,
    };

    /// The parameters sent in a will save text document notification.
    ///
    /// LSP Specification name: `WillSaveTextDocumentParams`
    pub const WillSaveParams = struct {
        /// The document that will be saved.
        textDocument: Identifier,
        /// The 'TextDocumentSaveReason'.
        reason: SaveReason,
    };

    /// Describe options to be used when registered for text document change events.
    ///
    /// LSP Specification name: `TextDocumentChangeRegistrationOptions`
    pub const ChangeRegistrationOptions = struct {
        /// How documents are synced to the server.
        syncKind: SyncKind,

        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,
    };

    /// An event describing a change to a text document. If only a text is provided
    /// it is considered to be the full content of the document.
    ///
    /// LSP Specification name: `TextDocumentContentChangeEvent`
    pub const ContentChangeEvent = union(enum) {
        text_document_content_change_partial: workspace.text_document_content.ChangePartial,
        text_document_content_change_whole_document: workspace.text_document_content.ChangeWholeDocument,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// General text document registration options.
    ///
    /// LSP Specification name: `TextDocumentRegistrationOptions`
    pub const RegistrationOptions = struct {
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,
    };

    /// Represents reasons why a text document is saved.
    ///
    /// LSP Specification name: `TextDocumentSaveReason`
    pub const SaveReason = enum(u32) {
        /// Manually triggered, e.g. by the user pressing save, by starting debugging,
        /// or by an API call.
        Manual = 1,
        /// Automatic after a delay.
        AfterDelay = 2,
        /// When the editor lost focus.
        FocusOut = 3,
        /// Unknown Value
        _,

        pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
    };

    /// Save registration options.
    ///
    /// LSP Specification name: `TextDocumentSaveRegistrationOptions`
    pub const SaveRegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `SaveOptions`
        /// The client is supposed to include the content on save.
        includeText: ?bool = null,
    };

    /// Defines how the host (editor) should sync
    /// document changes to the language server.
    ///
    /// LSP Specification name: `TextDocumentSyncKind`
    pub const SyncKind = enum(u32) {
        /// Documents should not be synced at all.
        None = 0,
        /// Documents are synced by always sending the full content
        /// of the document.
        Full = 1,
        /// Documents are synced by sending the full content on open.
        /// After that only incremental updates to the document are
        /// send.
        Incremental = 2,
        /// Unknown Value
        _,

        pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
    };

    /// LSP Specification name: `TextDocumentSyncOptions`
    pub const SyncOptions = struct {
        /// Open and close notifications are sent to the server. If omitted open close notification should not
        /// be sent.
        openClose: ?bool = null,
        /// Change notifications are sent to the server. See TextDocumentSyncKind.None, TextDocumentSyncKind.Full
        /// and TextDocumentSyncKind.Incremental. If omitted it defaults to TextDocumentSyncKind.None.
        change: ?SyncKind = null,
        /// If present will save notifications are sent to the server. If omitted the notification should not be
        /// sent.
        willSave: ?bool = null,
        /// If present will save wait until requests are sent to the server. If omitted the request should not be
        /// sent.
        willSaveWaitUntil: ?bool = null,
        /// If present save notifications are sent to the server. If omitted the notification should not be
        /// sent.
        save: ?union(enum) {
            bool: bool,
            save_options: SyncSaveOptions,

            pub const jsonParse = parser.UnionParser(@This()).jsonParse;
            pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
            pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
        } = null,
    };

    /// Save options.
    ///
    /// LSP Specification name: `SaveOptions`
    pub const SyncSaveOptions = struct {
        /// The client is supposed to include the content on save.
        includeText: ?bool = null,
    };

    /// Predefined Language kinds
    /// @since 3.18.0
    pub const LanguageKind = union(enum) {
        abap,
        bat,
        bibtex,
        clojure,
        coffeescript,
        c,
        cpp,
        csharp,
        css,
        /// @since 3.18.0
        /// @proposed
        d,
        /// @since 3.18.0
        /// @proposed
        delphi,
        diff,
        dart,
        dockerfile,
        elixir,
        erlang,
        fsharp,
        @"git-commit",
        rebase,
        go,
        groovy,
        handlebars,
        haskell,
        html,
        ini,
        java,
        javascript,
        javascriptreact,
        json,
        latex,
        less,
        lua,
        makefile,
        markdown,
        @"objective-c",
        @"objective-cpp",
        /// @since 3.18.0
        /// @proposed
        pascal,
        perl,
        perl6,
        php,
        powershell,
        jade,
        python,
        r,
        razor,
        ruby,
        rust,
        scss,
        sass,
        scala,
        shaderlab,
        shellscript,
        sql,
        swift,
        typescript,
        typescriptreact,
        tex,
        vb,
        xml,
        xsl,
        yaml,
        custom_value: []const u8,

        pub const eql = parser.EnumCustomStringValues(@This(), false).eql;
        pub const jsonParse = parser.EnumCustomStringValues(@This(), false).jsonParse;
        pub const jsonParseFromValue = parser.EnumCustomStringValues(@This(), false).jsonParseFromValue;
        pub const jsonStringify = parser.EnumCustomStringValues(@This(), false).jsonStringify;
    };
};

/// A notebook document.
///
/// @since 3.17.0
pub const NotebookDocument = struct {
    /// The notebook document's uri.
    uri: URI,
    /// The type of the notebook.
    notebookType: []const u8,
    /// The version number of this document (it will increase after each
    /// change, including undo/redo).
    version: i32,
    /// Additional metadata stored with the notebook
    /// document.
    ///
    /// Note: should always be an object literal (e.g. LSPObject)
    metadata: ?LSPObject = null,
    /// The cells of a notebook.
    cells: []const NotebookCell,

    /// @since 3.18.0
    ///
    /// LSP Specification name: `NotebookCellLanguage`
    pub const CellLanguage = struct {
        language: []const u8,
    };

    /// A change event for a notebook document.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `NotebookDocumentChangeEvent`
    pub const ChangeEvent = struct {
        /// The changed meta data if any.
        ///
        /// Note: should always be an object literal (e.g. LSPObject)
        metadata: ?LSPObject = null,
        /// Changes to cells
        cells: ?CellChanges = null,

        /// Cell changes to a notebook document.
        ///
        /// @since 3.18.0
        ///
        /// LSP Specification name: `NotebookDocumentCellChanges`
        pub const CellChanges = struct {
            /// Changes to the cell structure to add or
            /// remove cells.
            structure: ?CellContent.Structure = null,
            /// Changes to notebook cells properties like its
            /// kind, execution summary or metadata.
            data: ?[]const NotebookCell = null,
            /// Changes to the text content of notebook cells.
            textContent: ?[]const CellContentChanges = null,
        };

        /// Content changes to a cell in a notebook document.
        ///
        /// @since 3.18.0
        ///
        /// LSP Specification name: `NotebookDocumentCellContentChanges`
        pub const CellContentChanges = struct {
            document: TextDocument.Identifier.Versioned,
            changes: []const TextDocument.ContentChangeEvent,
        };

        pub const CellContent = struct {
            /// Structural changes to cells in a notebook document.
            ///
            /// @since 3.18.0
            ///
            /// LSP Specification name: `NotebookDocumentCellChangeStructure`
            pub const Structure = struct {
                /// The change to the cell array.
                array: NotebookCell.ArrayChange,
                /// Additional opened cell text documents.
                didOpen: ?[]const TextDocument = null,
                /// Additional closed cell text documents.
                didClose: ?[]const TextDocument.Identifier = null,
            };
        };
    };

    /// A literal to identify a notebook document in the client.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `NotebookDocumentIdentifier`
    pub const Identifier = struct {
        /// The notebook document's uri.
        uri: URI,

        /// A versioned notebook document identifier.
        ///
        /// @since 3.17.0
        ///
        /// LSP Specification name: `VersionedNotebookDocumentIdentifier`
        pub const Versioned = struct {
            /// The version number of this notebook document.
            version: i32,
            /// The notebook document's uri.
            uri: URI,
        };
    };

    /// Options specific to a notebook plus its cells
    /// to be synced to the server.
    ///
    /// If a selector provides a notebook document
    /// filter but no cell selector all cells of a
    /// matching notebook document will be synced.
    ///
    /// If a selector provides no notebook document
    /// filter but only a cell selector all notebook
    /// document that contain at least one matching
    /// cell will be synced.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `NotebookDocumentSyncOptions`
    pub const SyncOptions = struct {
        /// The notebooks to be synced
        notebookSelector: []const union(enum) {
            notebook_document_filter_with_notebook: FilterWithNotebook,
            notebook_document_filter_with_cells: FilterWithCells,

            pub const jsonParse = parser.UnionParser(@This()).jsonParse;
            pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
            pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
        },
        /// Whether save notification should be forwarded to
        /// the server. Will only be honored if mode === `notebook`.
        save: ?bool = null,

        /// @since 3.18.0
        ///
        /// LSP Specification name: `NotebookDocumentFilterWithCells`
        pub const FilterWithCells = struct {
            /// The notebook to be synced If a string
            /// value is provided it matches against the
            /// notebook type. '*' matches every notebook.
            notebook: ?union(enum) {
                string: []const u8,
                notebook_document_filter: DocumentFilter.Notebook,

                pub const jsonParse = parser.UnionParser(@This()).jsonParse;
                pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
                pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
            } = null,
            /// The cells of the matching notebook to be synced.
            cells: []const CellLanguage,
        };

        /// @since 3.18.0
        ///
        /// LSP Specification name: `NotebookDocumentFilterWithNotebook`
        pub const FilterWithNotebook = struct {
            /// The notebook to be synced If a string
            /// value is provided it matches against the
            /// notebook type. '*' matches every notebook.
            notebook: union(enum) {
                string: []const u8,
                notebook_document_filter: DocumentFilter.Notebook,

                pub const jsonParse = parser.UnionParser(@This()).jsonParse;
                pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
                pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
            },
            /// The cells of the matching notebook to be synced.
            cells: ?[]const CellLanguage = null,
        };
    };

    /// Registration options specific to a notebook.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `NotebookDocumentSyncRegistrationOptions`
    pub const SyncRegistrationOptions = struct {
        // Extends `NotebookDocumentSyncOptions`
        /// The notebooks to be synced
        notebookSelector: []const union(enum) {
            notebook_document_filter_with_notebook: SyncOptions.FilterWithNotebook,
            notebook_document_filter_with_cells: SyncOptions.FilterWithCells,

            pub const jsonParse = parser.UnionParser(@This()).jsonParse;
            pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
            pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
        },
        /// Whether save notification should be forwarded to
        /// the server. Will only be honored if mode === `notebook`.
        save: ?bool = null,

        // Uses mixin `StaticRegistrationOptions`
        /// The id used to register the request. The id can be used to deregister
        /// the request again. See also Registration#id.
        id: ?[]const u8 = null,
    };

    /// The params sent in a change notebook document notification.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `DidChangeNotebookDocumentParams`
    pub const DidChangeParams = struct {
        /// The notebook document that did change. The version number points
        /// to the version after all provided changes have been applied. If
        /// only the text document content of a cell changes the notebook version
        /// doesn't necessarily have to change.
        notebookDocument: Identifier.Versioned,
        /// The actual changes to the notebook document.
        ///
        /// The changes describe single state changes to the notebook document.
        /// So if there are two changes c1 (at array index 0) and c2 (at array
        /// index 1) for a notebook in state S then c1 moves the notebook from
        /// S to S' and c2 from S' to S''. So c1 is computed on the state S and
        /// c2 is computed on the state S'.
        ///
        /// To mirror the content of a notebook using change events use the following approach:
        /// - start with the same initial content
        /// - apply the 'notebookDocument/didChange' notifications in the order you receive them.
        /// - apply the `NotebookChangeEvent`s in a single notification in the order
        ///   you receive them.
        change: ChangeEvent,
    };

    /// The params sent in a close notebook document notification.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `DidCloseNotebookDocumentParams`
    pub const DidCloseParams = struct {
        /// The notebook document that got closed.
        notebookDocument: Identifier,
        /// The text documents that represent the content
        /// of a notebook cell that got closed.
        cellTextDocuments: []const TextDocument.Identifier,
    };

    /// The params sent in an open notebook document notification.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `DidOpenNotebookDocumentParams`
    pub const DidOpenParams = struct {
        /// The notebook document that got opened.
        notebookDocument: NotebookDocument,
        /// The text documents that represent the content
        /// of a notebook cell.
        cellTextDocuments: []const TextDocument,
    };

    /// The params sent in a save notebook document notification.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `DidSaveNotebookDocumentParams`
    pub const DidSaveParams = struct {
        /// The notebook document that got saved.
        notebookDocument: Identifier,
    };
};

/// A notebook cell.
///
/// A cell's document URI must be unique across ALL notebook
/// cells and can therefore be used to uniquely identify a
/// notebook cell or the cell's text document.
///
/// @since 3.17.0
pub const NotebookCell = struct {
    /// The cell's kind
    kind: Kind,
    /// The URI of the cell's text document
    /// content.
    document: DocumentUri,
    /// Additional metadata stored with the cell.
    ///
    /// Note: should always be an object literal (e.g. LSPObject)
    metadata: ?LSPObject = null,
    /// Additional execution summary information
    /// if supported by the client.
    executionSummary: ?ExecutionSummary = null,

    /// A change describing how to move a `NotebookCell`
    /// array from state S to S'.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `NotebookCellArrayChange`
    pub const ArrayChange = struct {
        /// The start oftest of the cell that changed.
        start: u32,
        /// The deleted cells
        deleteCount: u32,
        /// The new cells, if any
        cells: ?[]const NotebookCell = null,
    };

    pub const ExecutionSummary = struct {
        /// A strict monotonically increasing value
        /// indicating the execution order of a cell
        /// inside a notebook.
        executionOrder: u32,
        /// Whether the execution was successful or
        /// not if known by the client.
        success: ?bool = null,
    };

    /// A notebook cell kind.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `NotebookCellKind`
    pub const Kind = enum(u32) {
        /// A markup-cell is formatted source that is used for display.
        Markup = 1,
        /// A code-cell is source code.
        Code = 2,
        /// Unknown Value
        _,

        pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
    };

    /// A notebook cell text document filter denotes a cell text
    /// document by different properties.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `NotebookCellTextDocumentFilter`
    pub const TextDocumentFilter = struct {
        /// A filter that matches against the notebook
        /// containing the notebook cell. If a string
        /// value is provided it matches against the
        /// notebook type. '*' matches every notebook.
        notebook: union(enum) {
            string: []const u8,
            notebook_document_filter: DocumentFilter.Notebook,

            pub const jsonParse = parser.UnionParser(@This()).jsonParse;
            pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
            pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
        },
        /// A language id like `python`.
        ///
        /// Will be matched against the language id of the
        /// notebook cell document. '*' matches every language.
        language: ?[]const u8 = null,
    };
};

/// A document filter describes a top level text document or
/// a notebook cell document.
///
/// @since 3.17.0 - support for NotebookCellTextDocumentFilter.
pub const DocumentFilter = union(enum) {
    text_document_filter: Text,
    notebook_cell_text_document_filter: NotebookCell.TextDocumentFilter,

    /// A document filter denotes a document by different properties like
    /// the {@link TextDocument.languageId language}, the {@link Uri.scheme scheme} of
    /// its resource, or a glob-pattern that is applied to the {@link TextDocument.fileName path}.
    ///
    /// Glob patterns can have the following syntax:
    /// - `*` to match zero or more characters in a path segment
    /// - `?` to match on one character in a path segment
    /// - `**` to match any number of path segments, including none
    /// - `{}` to group sub patterns into an OR expression. (e.g. `**​/*.{ts,js}` matches all TypeScript and JavaScript files)
    /// - `[]` to declare a range of characters to match in a path segment (e.g., `example.[0-9]` to match on `example.0`, `example.1`, …)
    /// - `[!...]` to negate a range of characters to match in a path segment (e.g., `example.[!0-9]` to match on `example.a`, `example.b`, but not `example.0`)
    ///
    /// @sample A language filter that applies to typescript files on disk: `{ language: 'typescript', scheme: 'file' }`
    /// @sample A language filter that applies to all package.json paths: `{ language: 'json', pattern: '**package.json' }`
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `TextDocumentFilter`
    pub const Text = union(enum) {
        text_document_filter_language: Language,
        text_document_filter_scheme: Scheme,
        text_document_filter_pattern: Text.Pattern,

        /// A document filter where `scheme` is required field.
        ///
        /// @since 3.18.0
        ///
        /// LSP Specification name: `TextDocumentFilterScheme`
        pub const Scheme = struct {
            /// A language id, like `typescript`.
            language: ?[]const u8 = null,
            /// A Uri {@link Uri.scheme scheme}, like `file` or `untitled`.
            scheme: []const u8,
            /// A glob pattern, like **​/*.{ts,js}. See TextDocumentFilter for examples.
            ///
            /// @since 3.18.0 - support for relative patterns. Whether clients support
            /// relative patterns depends on the client capability
            /// `textDocuments.filters.relativePatternSupport`.
            pattern: ?GlobPattern = null,
        };

        /// A document filter where `language` is required field.
        ///
        /// @since 3.18.0
        ///
        /// LSP Specification name: `TextDocumentFilterLanguage`
        pub const Language = struct {
            /// A language id, like `typescript`.
            language: []const u8,
            /// A Uri {@link Uri.scheme scheme}, like `file` or `untitled`.
            scheme: ?[]const u8 = null,
            /// A glob pattern, like **​/*.{ts,js}. See TextDocumentFilter for examples.
            ///
            /// @since 3.18.0 - support for relative patterns. Whether clients support
            /// relative patterns depends on the client capability
            /// `textDocuments.filters.relativePatternSupport`.
            pattern: ?GlobPattern = null,
        };

        /// A document filter where `pattern` is required field.
        ///
        /// @since 3.18.0
        ///
        /// LSP Specification name: `TextDocumentFilterPattern`
        pub const Pattern = struct {
            /// A language id, like `typescript`.
            language: ?[]const u8 = null,
            /// A Uri {@link Uri.scheme scheme}, like `file` or `untitled`.
            scheme: ?[]const u8 = null,
            /// A glob pattern, like **​/*.{ts,js}. See TextDocumentFilter for examples.
            ///
            /// @since 3.18.0 - support for relative patterns. Whether clients support
            /// relative patterns depends on the client capability
            /// `textDocuments.filters.relativePatternSupport`.
            pattern: GlobPattern,
        };

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// A notebook document filter denotes a notebook document by
    /// different properties. The properties will be match
    /// against the notebook's URI (same as with documents)
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `NotebookDocumentFilter`
    pub const Notebook = union(enum) {
        notebook_document_filter_notebook_type: NotebookType,
        notebook_document_filter_scheme: Scheme,
        notebook_document_filter_pattern: Notebook.Pattern,

        /// A notebook document filter where `notebookType` is required field.
        ///
        /// @since 3.18.0
        ///
        /// LSP Specification name: `NotebookDocumentFilterNotebookType`
        pub const NotebookType = struct {
            /// The type of the enclosing notebook.
            notebookType: []const u8,
            /// A Uri {@link Uri.scheme scheme}, like `file` or `untitled`.
            scheme: ?[]const u8 = null,
            /// A glob pattern.
            pattern: ?GlobPattern = null,
        };

        /// A notebook document filter where `scheme` is required field.
        ///
        /// @since 3.18.0
        ///
        /// LSP Specification name: `NotebookDocumentFilterScheme`
        pub const Scheme = struct {
            /// The type of the enclosing notebook.
            notebookType: ?[]const u8 = null,
            /// A Uri {@link Uri.scheme scheme}, like `file` or `untitled`.
            scheme: []const u8,
            /// A glob pattern.
            pattern: ?GlobPattern = null,
        };

        /// A notebook document filter where `pattern` is required field.
        ///
        /// @since 3.18.0
        ///
        /// LSP Specification name: `NotebookDocumentFilterPattern`
        pub const Pattern = struct {
            /// The type of the enclosing notebook.
            notebookType: ?[]const u8 = null,
            /// A Uri {@link Uri.scheme scheme}, like `file` or `untitled`.
            scheme: ?[]const u8 = null,
            /// A glob pattern.
            pattern: GlobPattern,
        };

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    pub const jsonParse = parser.UnionParser(@This()).jsonParse;
    pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
    pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
};

/// A workspace edit represents changes to many resources managed in the workspace. The edit
/// should either provide `changes` or `documentChanges`. If documentChanges are present
/// they are preferred over `changes` if the client can handle versioned document edits.
///
/// Since version 3.13.0 a workspace edit can contain resource operations as well. If resource
/// operations are present clients need to execute the operations in the order in which they
/// are provided. So a workspace edit for example can consist of the following two changes:
/// (1) a create file a.txt and (2) a text document edit which insert text into file a.txt.
///
/// An invalid sequence (e.g. (1) delete file a.txt and (2) insert text into file a.txt) will
/// cause failure of the operation. How the client recovers from the failure is described by
/// the client capability: `workspace.workspaceEdit.failureHandling`
pub const WorkspaceEdit = struct {
    /// Holds changes to existing resources.
    changes: ?parser.Map(DocumentUri, []const TextEdit) = null,
    /// Depending on the client capability `workspace.workspaceEdit.resourceOperations` document changes
    /// are either an array of `TextDocumentEdit`s to express changes to n different text documents
    /// where each text document edit addresses a specific version of a text document. Or it can contain
    /// above `TextDocumentEdit`s mixed with create, rename and delete file / folder operations.
    ///
    /// Whether a client supports versioned document edits is expressed via
    /// `workspace.workspaceEdit.documentChanges` client capability.
    ///
    /// If a client neither supports `documentChanges` nor `workspace.workspaceEdit.resourceOperations` then
    /// only plain `TextEdit`s using the `changes` property are supported.
    documentChanges: ?[]const union(enum) {
        text_document_edit: TextDocument.Edit,
        create_file: CreateFile,
        rename_file: RenameFile,
        delete_file: DeleteFile,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    } = null,
    /// A map of change annotations that can be referenced in `AnnotatedTextEdit`s or create, rename and
    /// delete file / folder operations.
    ///
    /// Whether clients honor this property depends on the client capability `workspace.changeAnnotationSupport`.
    ///
    /// @since 3.16.0
    changeAnnotations: ?parser.Map(ChangeAnnotationIdentifier, ChangeAnnotation) = null,

    /// Create file operation.
    pub const CreateFile = struct {
        /// A create
        kind: []const u8 = "create",
        /// The resource to create.
        uri: DocumentUri,
        /// Additional options
        options: ?Options = null,

        // Extends `ResourceOperation`
        /// An optional annotation identifier describing the operation.
        ///
        /// @since 3.16.0
        annotationId: ?ChangeAnnotationIdentifier = null,

        /// Options to create a file.
        ///
        /// LSP Specification name: `CreateFileOptions`
        pub const Options = struct {
            /// Overwrite existing file. Overwrite wins over `ignoreIfExists`
            overwrite: ?bool = null,
            /// Ignore if exists.
            ignoreIfExists: ?bool = null,
        };
    };

    /// Rename file operation
    pub const RenameFile = struct {
        /// A rename
        kind: []const u8 = "rename",
        /// The old (existing) location.
        oldUri: DocumentUri,
        /// The new location.
        newUri: DocumentUri,
        /// Rename options.
        options: ?Options = null,

        // Extends `ResourceOperation`
        /// An optional annotation identifier describing the operation.
        ///
        /// @since 3.16.0
        annotationId: ?ChangeAnnotationIdentifier = null,

        /// Rename file options
        ///
        /// LSP Specification name: `RenameFileOptions`
        pub const Options = struct {
            /// Overwrite target if existing. Overwrite wins over `ignoreIfExists`
            overwrite: ?bool = null,
            /// Ignores if target exists.
            ignoreIfExists: ?bool = null,
        };
    };

    /// Delete file operation
    pub const DeleteFile = struct {
        /// A delete
        kind: []const u8 = "delete",
        /// The file to delete.
        uri: DocumentUri,
        /// Delete options.
        options: ?Options = null,

        // Extends `ResourceOperation`
        /// An optional annotation identifier describing the operation.
        ///
        /// @since 3.16.0
        annotationId: ?ChangeAnnotationIdentifier = null,

        /// Delete file options
        ///
        /// LSP Specification name: `DeleteFileOptions`
        pub const Options = struct {
            /// Delete the content recursively if a folder is denoted.
            recursive: ?bool = null,
            /// Ignore the operation if the file doesn't exist.
            ignoreIfNotExists: ?bool = null,
        };
    };

    /// Additional data about a workspace edit.
    ///
    /// @since 3.18.0
    /// @proposed
    ///
    /// LSP Specification name: `WorkspaceEditMetadata`
    pub const Metadata = struct {
        /// Signal to the editor that this edit is a refactoring.
        isRefactoring: ?bool = null,
    };
};

/// General parameters to register for a notification or to register a provider.
pub const Registration = struct {
    /// The id used to register the request. The id can be used to deregister
    /// the request again.
    id: []const u8,
    /// The method / capability to register for.
    method: []const u8,
    /// Options necessary for the registration.
    registerOptions: ?LSPAny = null,

    /// LSP Specification name: `RegistrationParams`
    pub const Params = struct {
        registrations: []const Registration,
    };
};

/// General parameters to unregister a request or notification.
pub const Unregistration = struct {
    /// The id used to unregister the request or notification. Usually an id
    /// provided during the register request.
    id: []const u8,
    /// The method to unregister for.
    method: []const u8,

    /// LSP Specification name: `UnregistrationParams`
    pub const Params = struct {
        unregisterations: []const Unregistration,
    };
};

pub const trace = struct {
    /// LSP Specification name: `SetTraceParams`
    pub const SetParams = struct {
        value: Value,
    };

    /// LSP Specification name: `TraceValue`
    pub const Value = union(enum) {
        /// Turn tracing off.
        off,
        /// Trace messages only.
        messages,
        /// Verbose message tracing.
        verbose,
        unknown_value: []const u8,

        pub const eql = parser.EnumCustomStringValues(@This(), false).eql;
        pub const jsonParse = parser.EnumCustomStringValues(@This(), false).jsonParse;
        pub const jsonParseFromValue = parser.EnumCustomStringValues(@This(), false).jsonParseFromValue;
        pub const jsonStringify = parser.EnumCustomStringValues(@This(), false).jsonStringify;
    };

    /// LSP Specification name: `LogTraceParams`
    pub const LogParams = struct {
        message: []const u8,
        verbose: ?[]const u8 = null,
    };
};

/// Defines the capabilities provided by the client.
pub const ClientCapabilities = struct {
    /// Workspace specific client capabilities.
    workspace: ?Workspace = null,
    /// Text document specific client capabilities.
    textDocument: ?ClientCapabilities.TextDocument = null,
    /// Capabilities specific to the notebook document support.
    ///
    /// @since 3.17.0
    notebookDocument: ?ClientCapabilities.NotebookDocument = null,
    /// Window specific client capabilities.
    window: ?Window = null,
    /// General client capabilities.
    ///
    /// @since 3.16.0
    general: ?General = null,
    /// Experimental client capabilities.
    experimental: ?LSPAny = null,

    /// Text document specific client capabilities.
    ///
    /// LSP Specification name: `TextDocumentClientCapabilities`
    pub const TextDocument = struct {
        /// Defines which synchronization capabilities the client supports.
        synchronization: ?Sync = null,
        /// Defines which filters the client supports.
        ///
        /// @since 3.18.0
        filters: ?Filter = null,
        /// Capabilities specific to the `textDocument/completion` request.
        completion: ?Completion = null,
        /// Capabilities specific to the `textDocument/hover` request.
        hover: ?ClientCapabilities.TextDocument.Hover = null,
        /// Capabilities specific to the `textDocument/signatureHelp` request.
        signatureHelp: ?ClientCapabilities.TextDocument.SignatureHelp = null,
        /// Capabilities specific to the `textDocument/declaration` request.
        ///
        /// @since 3.14.0
        declaration: ?Declaration = null,
        /// Capabilities specific to the `textDocument/definition` request.
        definition: ?ClientCapabilities.TextDocument.Definition = null,
        /// Capabilities specific to the `textDocument/typeDefinition` request.
        ///
        /// @since 3.6.0
        typeDefinition: ?TypeDefinition = null,
        /// Capabilities specific to the `textDocument/implementation` request.
        ///
        /// @since 3.6.0
        implementation: ?Implementation = null,
        /// Capabilities specific to the `textDocument/references` request.
        references: ?Reference = null,
        /// Capabilities specific to the `textDocument/documentHighlight` request.
        documentHighlight: ?ClientCapabilities.TextDocument.DocumentHighlight = null,
        /// Capabilities specific to the `textDocument/documentSymbol` request.
        documentSymbol: ?ClientCapabilities.TextDocument.DocumentSymbol = null,
        /// Capabilities specific to the `textDocument/codeAction` request.
        codeAction: ?ClientCapabilities.TextDocument.CodeAction = null,
        /// Capabilities specific to the `textDocument/codeLens` request.
        codeLens: ?CodeLens = null,
        /// Capabilities specific to the `textDocument/documentLink` request.
        documentLink: ?ClientCapabilities.TextDocument.DocumentLink = null,
        /// Capabilities specific to the `textDocument/documentColor` and the
        /// `textDocument/colorPresentation` request.
        ///
        /// @since 3.6.0
        colorProvider: ?ClientCapabilities.TextDocument.DocumentColor = null,
        /// Capabilities specific to the `textDocument/formatting` request.
        formatting: ?DocumentFormatting = null,
        /// Capabilities specific to the `textDocument/rangeFormatting` request.
        rangeFormatting: ?DocumentRangeFormatting = null,
        /// Capabilities specific to the `textDocument/onTypeFormatting` request.
        onTypeFormatting: ?DocumentOnTypeFormatting = null,
        /// Capabilities specific to the `textDocument/rename` request.
        rename: ?Rename = null,
        /// Capabilities specific to the `textDocument/foldingRange` request.
        ///
        /// @since 3.10.0
        foldingRange: ?ClientCapabilities.TextDocument.FoldingRange = null,
        /// Capabilities specific to the `textDocument/selectionRange` request.
        ///
        /// @since 3.15.0
        selectionRange: ?ClientCapabilities.TextDocument.SelectionRange = null,
        /// Capabilities specific to the `textDocument/publishDiagnostics` notification.
        publishDiagnostics: ?PublishDiagnostics = null,
        /// Capabilities specific to the various call hierarchy requests.
        ///
        /// @since 3.16.0
        callHierarchy: ?CallHierarchy = null,
        /// Capabilities specific to the various semantic token request.
        ///
        /// @since 3.16.0
        semanticTokens: ?SemanticTokens = null,
        /// Capabilities specific to the `textDocument/linkedEditingRange` request.
        ///
        /// @since 3.16.0
        linkedEditingRange: ?LinkedEditingRange = null,
        /// Client capabilities specific to the `textDocument/moniker` request.
        ///
        /// @since 3.16.0
        moniker: ?ClientCapabilities.TextDocument.Moniker = null,
        /// Capabilities specific to the various type hierarchy requests.
        ///
        /// @since 3.17.0
        typeHierarchy: ?TypeHierarchy = null,
        /// Capabilities specific to the `textDocument/inlineValue` request.
        ///
        /// @since 3.17.0
        inlineValue: ?ClientCapabilities.TextDocument.InlineValue = null,
        /// Capabilities specific to the `textDocument/inlayHint` request.
        ///
        /// @since 3.17.0
        inlayHint: ?ClientCapabilities.TextDocument.InlayHint = null,
        /// Capabilities specific to the diagnostic pull model.
        ///
        /// @since 3.17.0
        diagnostic: ?ClientCapabilities.TextDocument.Diagnostic = null,
        /// Client capabilities specific to inline completions.
        ///
        /// @since 3.18.0
        /// @proposed
        inlineCompletion: ?InlineCompletion = null,

        /// LSP Specification name: `TextDocumentSyncClientCapabilities`
        pub const Sync = struct {
            /// Whether text document synchronization supports dynamic registration.
            dynamicRegistration: ?bool = null,
            /// The client supports sending will save notifications.
            willSave: ?bool = null,
            /// The client supports sending a will save request and
            /// waits for a response providing text edits which will
            /// be applied to the document before it is saved.
            willSaveWaitUntil: ?bool = null,
            /// The client supports did save notifications.
            didSave: ?bool = null,
        };

        /// LSP Specification name: `TextDocumentFilterClientCapabilities`
        pub const Filter = struct {
            /// The client supports Relative Patterns.
            ///
            /// @since 3.18.0
            relativePatternSupport: ?bool = null,
        };

        /// Completion client capabilities
        ///
        /// LSP Specification name: `CompletionClientCapabilities`
        pub const Completion = struct {
            /// Whether completion supports dynamic registration.
            dynamicRegistration: ?bool = null,
            /// The client supports the following `CompletionItem` specific
            /// capabilities.
            completionItem: ?ItemOptions = null,
            completionItemKind: ?ItemKindOptions = null,
            /// Defines how the client handles whitespace and indentation
            /// when accepting a completion item that uses multi line
            /// text in either `insertText` or `textEdit`.
            ///
            /// @since 3.17.0
            insertTextMode: ?InsertTextMode = null,
            /// The client supports to send additional context information for a
            /// `textDocument/completion` request.
            contextSupport: ?bool = null,
            /// The client supports the following `CompletionList` specific
            /// capabilities.
            ///
            /// @since 3.17.0
            completionList: ?ListOptions = null,

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientCompletionItemOptions`
            pub const ItemOptions = struct {
                /// Client supports snippets as insert text.
                ///
                /// A snippet can define tab stops and placeholders with `$1`, `$2`
                /// and `${3:foo}`. `$0` defines the final tab stop, it defaults to
                /// the end of the snippet. Placeholders with equal identifiers are linked,
                /// that is typing in one will update others too.
                snippetSupport: ?bool = null,
                /// Client supports commit characters on a completion item.
                commitCharactersSupport: ?bool = null,
                /// Client supports the following content formats for the documentation
                /// property. The order describes the preferred format of the client.
                documentationFormat: ?[]const MarkupKind = null,
                /// Client supports the deprecated property on a completion item.
                deprecatedSupport: ?bool = null,
                /// Client supports the preselect property on a completion item.
                preselectSupport: ?bool = null,
                /// Client supports the tag property on a completion item. Clients supporting
                /// tags have to handle unknown tags gracefully. Clients especially need to
                /// preserve unknown tags when sending a completion item back to the server in
                /// a resolve call.
                ///
                /// @since 3.15.0
                tagSupport: ?ItemTagOptions = null,
                /// Client support insert replace edit to control different behavior if a
                /// completion item is inserted in the text or should replace text.
                ///
                /// @since 3.16.0
                insertReplaceSupport: ?bool = null,
                /// Indicates which properties a client can resolve lazily on a completion
                /// item. Before version 3.16.0 only the predefined properties `documentation`
                /// and `details` could be resolved lazily.
                ///
                /// @since 3.16.0
                resolveSupport: ?ItemResolveOptions = null,
                /// The client supports the `insertTextMode` property on
                /// a completion item to override the whitespace handling mode
                /// as defined by the client (see `insertTextMode`).
                ///
                /// @since 3.16.0
                insertTextModeSupport: ?ItemInsertTextModeOptions = null,
                /// The client has support for completion item label
                /// details (see also `CompletionItemLabelDetails`).
                ///
                /// @since 3.17.0
                labelDetailsSupport: ?bool = null,
            };

            /// In many cases the items of an actual completion result share the same
            /// value for properties like `commitCharacters` or the range of a text
            /// edit. A completion list can therefore define item defaults which will
            /// be used if a completion item itself doesn't specify the value.
            ///
            /// If a completion list specifies a default value and a completion item
            /// also specifies a corresponding value, the rules for combining these are
            /// defined by `applyKinds` (if the client supports it), defaulting to
            /// ApplyKind.Replace.
            ///
            /// Servers are only allowed to return default values if the client
            /// signals support for this via the `completionList.itemDefaults`
            /// capability.
            ///
            /// @since 3.17.0
            ///
            /// LSP Specification name: `CompletionItemDefaults`
            pub const ItemDefaults = struct {
                /// A default commit character set.
                ///
                /// @since 3.17.0
                commitCharacters: ?[]const []const u8 = null,
                /// A default edit range.
                ///
                /// @since 3.17.0
                editRange: ?EditRange = null,
                /// A default insert text format.
                ///
                /// @since 3.17.0
                insertTextFormat: ?InsertTextFormat = null,
                /// A default insert text mode.
                ///
                /// @since 3.17.0
                insertTextMode: ?InsertTextMode = null,
                /// A default data value.
                ///
                /// @since 3.17.0
                data: ?LSPAny = null,
            };

            /// A default edit range.
            ///
            /// @since 3.17.0
            pub const EditRange = union(enum) {
                range: Range,
                edit_range_with_insert_replace: WithInsertReplace,

                /// Edit range variant that includes ranges for insert and replace operations.
                ///
                /// @since 3.18.0
                ///
                /// LSP Specification name: `EditRangeWithInsertReplace`
                pub const WithInsertReplace = struct {
                    insert: Range,
                    replace: Range,
                };

                pub const jsonParse = parser.UnionParser(@This()).jsonParse;
                pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
                pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
            };

            /// Specifies how fields from a completion item should be combined with those
            /// from `completionList.itemDefaults`.
            ///
            /// If unspecified, all fields will be treated as ApplyKind.Replace.
            ///
            /// If a field's value is ApplyKind.Replace, the value from a completion item (if
            /// provided and not `null`) will always be used instead of the value from
            /// `completionItem.itemDefaults`.
            ///
            /// If a field's value is ApplyKind.Merge, the values will be merged using the rules
            /// defined against each field below.
            ///
            /// Servers are only allowed to return `applyKind` if the client
            /// signals support for this via the `completionList.applyKindSupport`
            /// capability.
            ///
            /// @since 3.18.0
            ///
            /// LSP Specification name: `CompletionItemApplyKinds`
            pub const ItemApplyKinds = struct {
                /// Specifies whether commitCharacters on a completion will replace or be
                /// merged with those in `completionList.itemDefaults.commitCharacters`.
                ///
                /// If ApplyKind.Replace, the commit characters from the completion item will
                /// always be used unless not provided, in which case those from
                /// `completionList.itemDefaults.commitCharacters` will be used. An
                /// empty list can be used if a completion item does not have any commit
                /// characters and also should not use those from
                /// `completionList.itemDefaults.commitCharacters`.
                ///
                /// If ApplyKind.Merge the commitCharacters for the completion will be the
                /// union of all values in both `completionList.itemDefaults.commitCharacters`
                /// and the completion's own `commitCharacters`.
                ///
                /// @since 3.18.0
                commitCharacters: ?ApplyKind = null,
                /// Specifies whether the `data` field on a completion will replace or
                /// be merged with data from `completionList.itemDefaults.data`.
                ///
                /// If ApplyKind.Replace, the data from the completion item will be used if
                /// provided (and not `null`), otherwise
                /// `completionList.itemDefaults.data` will be used. An empty object can
                /// be used if a completion item does not have any data but also should
                /// not use the value from `completionList.itemDefaults.data`.
                ///
                /// If ApplyKind.Merge, a shallow merge will be performed between
                /// `completionList.itemDefaults.data` and the completion's own data
                /// using the following rules:
                ///
                /// - If a completion's `data` field is not provided (or `null`), the
                ///   entire `data` field from `completionList.itemDefaults.data` will be
                ///   used as-is.
                /// - If a completion's `data` field is provided, each field will
                ///   overwrite the field of the same name in
                ///   `completionList.itemDefaults.data` but no merging of nested fields
                ///   within that value will occur.
                ///
                /// @since 3.18.0
                data: ?ApplyKind = null,
            };

            /// @since 3.18.0
            ///
            /// LSP Specification name: `CompletionItemTagOptions`
            pub const ItemTagOptions = struct {
                /// The tags supported by the client.
                valueSet: []const completion.Item.Tag,
            };

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientCompletionItemOptionsKind`
            pub const ItemKindOptions = struct {
                /// The completion item kind values the client supports. When this
                /// property exists the client also guarantees that it will
                /// handle values outside its set gracefully and falls back
                /// to a default value when unknown.
                ///
                /// If this property is not present the client only supports
                /// the completion items kinds from `Text` to `Reference` as defined in
                /// the initial version of the protocol.
                valueSet: ?[]const completion.Item.Kind = null,
            };

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientCompletionItemInsertTextModeOptions`
            pub const ItemInsertTextModeOptions = struct {
                valueSet: []const InsertTextMode,
            };

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientCompletionItemResolveOptions`
            pub const ItemResolveOptions = struct {
                /// The properties that a client can resolve lazily.
                properties: []const []const u8,
            };

            /// The client supports the following `CompletionList` specific
            /// capabilities.
            ///
            /// @since 3.17.0
            ///
            /// LSP Specification name: `CompletionListCapabilities`
            pub const ListOptions = struct {
                /// The client supports the following itemDefaults on
                /// a completion list.
                ///
                /// The value lists the supported property names of the
                /// `CompletionList.itemDefaults` object. If omitted
                /// no properties are supported.
                ///
                /// @since 3.17.0
                itemDefaults: ?[]const []const u8 = null,
                /// Specifies whether the client supports `CompletionList.applyKind` to
                /// indicate how supported values from `completionList.itemDefaults`
                /// and `completion` will be combined.
                ///
                /// If a client supports `applyKind` it must support it for all fields
                /// that it supports that are listed in `CompletionList.applyKind`. This
                /// means when clients add support for new/future fields in completion
                /// items the MUST also support merge for them if those fields are
                /// defined in `CompletionList.applyKind`.
                ///
                /// @since 3.18.0
                applyKindSupport: ?bool = null,
            };

            /// Defines how values from a set of defaults and an individual item will be
            /// merged.
            ///
            /// @since 3.18.0
            pub const ApplyKind = enum(u32) {
                /// The value from the individual item (if provided and not `null`) will be
                /// used instead of the default.
                Replace = 1,
                /// The value from the item will be merged with the default.
                ///
                /// The specific rules for mergeing values are defined against each field
                /// that supports merging.
                Merge = 2,
                /// Unknown Value
                _,

                pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
            };
        };

        /// LSP Specification name: `HoverClientCapabilities`
        pub const Hover = struct {
            /// Whether hover supports dynamic registration.
            dynamicRegistration: ?bool = null,
            /// Client supports the following content formats for the content
            /// property. The order describes the preferred format of the client.
            contentFormat: ?[]const MarkupKind = null,
        };

        /// Client Capabilities for a {@link SignatureHelpRequest}.
        ///
        /// LSP Specification name: `SignatureHelpClientCapabilities`
        pub const SignatureHelp = struct {
            /// Whether signature help supports dynamic registration.
            dynamicRegistration: ?bool = null,
            /// The client supports the following `SignatureInformation`
            /// specific properties.
            signatureInformation: ?InformationOptions = null,
            /// The client supports to send additional context information for a
            /// `textDocument/signatureHelp` request. A client that opts into
            /// contextSupport will also support the `retriggerCharacters` on
            /// `SignatureHelpOptions`.
            ///
            /// @since 3.15.0
            contextSupport: ?bool = null,

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientSignatureInformationOptions`
            pub const InformationOptions = struct {
                /// Client supports the following content formats for the documentation
                /// property. The order describes the preferred format of the client.
                documentationFormat: ?[]const MarkupKind = null,
                /// Client capabilities specific to parameter information.
                parameterInformation: ?ParameterInformationOptions = null,
                /// The client supports the `activeParameter` property on `SignatureInformation`
                /// literal.
                ///
                /// @since 3.16.0
                activeParameterSupport: ?bool = null,
                /// The client supports the `activeParameter` property on
                /// `SignatureHelp`/`SignatureInformation` being set to `null` to
                /// indicate that no parameter should be active.
                ///
                /// @since 3.18.0
                /// @proposed
                noActiveParameterSupport: ?bool = null,
            };

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientSignatureParameterInformationOptions`
            pub const ParameterInformationOptions = struct {
                /// The client supports processing label offsets instead of a
                /// simple label string.
                ///
                /// @since 3.14.0
                labelOffsetSupport: ?bool = null,
            };
        };

        /// @since 3.14.0
        ///
        /// LSP Specification name: `DeclarationClientCapabilities`
        pub const Declaration = struct {
            /// Whether declaration supports dynamic registration. If this is set to `true`
            /// the client supports the new `DeclarationRegistrationOptions` return value
            /// for the corresponding server capability as well.
            dynamicRegistration: ?bool = null,
            /// The client supports additional metadata in the form of declaration links.
            linkSupport: ?bool = null,
        };

        /// Client Capabilities for a {@link DefinitionRequest}.
        ///
        /// LSP Specification name: `DefinitionClientCapabilities`
        pub const Definition = struct {
            /// Whether definition supports dynamic registration.
            dynamicRegistration: ?bool = null,
            /// The client supports additional metadata in the form of definition links.
            ///
            /// @since 3.14.0
            linkSupport: ?bool = null,
        };

        /// Since 3.6.0
        ///
        /// LSP Specification name: `TypeDefinitionClientCapabilities`
        pub const TypeDefinition = struct {
            /// Whether implementation supports dynamic registration. If this is set to `true`
            /// the client supports the new `TypeDefinitionRegistrationOptions` return value
            /// for the corresponding server capability as well.
            dynamicRegistration: ?bool = null,
            /// The client supports additional metadata in the form of definition links.
            ///
            /// Since 3.14.0
            linkSupport: ?bool = null,
        };

        /// @since 3.6.0
        ///
        /// LSP Specification name: `ImplementationClientCapabilities`
        pub const Implementation = struct {
            /// Whether implementation supports dynamic registration. If this is set to `true`
            /// the client supports the new `ImplementationRegistrationOptions` return value
            /// for the corresponding server capability as well.
            dynamicRegistration: ?bool = null,
            /// The client supports additional metadata in the form of definition links.
            ///
            /// @since 3.14.0
            linkSupport: ?bool = null,
        };

        /// Client Capabilities for a {@link ReferencesRequest}.
        ///
        /// LSP Specification name: `ReferenceClientCapabilities`
        pub const Reference = struct {
            /// Whether references supports dynamic registration.
            dynamicRegistration: ?bool = null,
        };

        /// Client Capabilities for a {@link DocumentHighlightRequest}.
        ///
        /// LSP Specification name: `DocumentHighlightClientCapabilities`
        pub const DocumentHighlight = struct {
            /// Whether document highlight supports dynamic registration.
            dynamicRegistration: ?bool = null,
        };

        /// Client Capabilities for a {@link DocumentSymbolRequest}.
        ///
        /// LSP Specification name: `DocumentSymbolClientCapabilities`
        pub const DocumentSymbol = struct {
            /// Whether document symbol supports dynamic registration.
            dynamicRegistration: ?bool = null,
            /// Specific capabilities for the `SymbolKind` in the
            /// `textDocument/documentSymbol` request.
            symbolKind: ?Workspace.Symbol.SymbolKindOptions = null,
            /// The client supports hierarchical document symbols.
            hierarchicalDocumentSymbolSupport: ?bool = null,
            /// The client supports tags on `SymbolInformation`. Tags are supported on
            /// `DocumentSymbol` if `hierarchicalDocumentSymbolSupport` is set to true.
            /// Clients supporting tags have to handle unknown tags gracefully.
            ///
            /// @since 3.16.0
            tagSupport: ?Workspace.Symbol.TagOptions = null,
            /// The client supports an additional label presented in the UI when
            /// registering a document symbol provider.
            ///
            /// @since 3.16.0
            labelSupport: ?bool = null,
        };

        /// The Client Capabilities of a {@link CodeActionRequest}.
        ///
        /// LSP Specification name: `CodeActionClientCapabilities`
        pub const CodeAction = struct {
            /// Whether code action supports dynamic registration.
            dynamicRegistration: ?bool = null,
            /// The client support code action literals of type `CodeAction` as a valid
            /// response of the `textDocument/codeAction` request. If the property is not
            /// set the request can only return `Command` literals.
            ///
            /// @since 3.8.0
            codeActionLiteralSupport: ?LiteralOptions = null,
            /// Whether code action supports the `isPreferred` property.
            ///
            /// @since 3.15.0
            isPreferredSupport: ?bool = null,
            /// Whether code action supports the `disabled` property.
            ///
            /// @since 3.16.0
            disabledSupport: ?bool = null,
            /// Whether code action supports the `data` property which is
            /// preserved between a `textDocument/codeAction` and a
            /// `codeAction/resolve` request.
            ///
            /// @since 3.16.0
            dataSupport: ?bool = null,
            /// Whether the client supports resolving additional code action
            /// properties via a separate `codeAction/resolve` request.
            ///
            /// @since 3.16.0
            resolveSupport: ?ResolveOptions = null,
            /// Whether the client honors the change annotations in
            /// text edits and resource operations returned via the
            /// `CodeAction#edit` property by for example presenting
            /// the workspace edit in the user interface and asking
            /// for confirmation.
            ///
            /// @since 3.16.0
            honorsChangeAnnotations: ?bool = null,
            /// Whether the client supports documentation for a class of
            /// code actions.
            ///
            /// @since 3.18.0
            /// @proposed
            documentationSupport: ?bool = null,
            /// Client supports the tag property on a code action. Clients
            /// supporting tags have to handle unknown tags gracefully.
            ///
            /// @since 3.18.0 - proposed
            tagSupport: ?TagOptions = null,

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientCodeActionLiteralOptions`
            pub const LiteralOptions = struct {
                /// The code action kind is support with the following value
                /// set.
                codeActionKind: KindOptions,
            };

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientCodeActionKindOptions`
            pub const KindOptions = struct {
                /// The code action kind values the client supports. When this
                /// property exists the client also guarantees that it will
                /// handle values outside its set gracefully and falls back
                /// to a default value when unknown.
                valueSet: []const types.CodeAction.Kind,
            };

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientCodeActionResolveOptions`
            pub const ResolveOptions = struct {
                /// The properties that a client can resolve lazily.
                properties: []const []const u8,
            };

            /// @since 3.18.0 - proposed
            ///
            /// LSP Specification name: `CodeActionTagOptions`
            pub const TagOptions = struct {
                /// The tags supported by the client.
                valueSet: []const types.CodeAction.Tag,
            };
        };

        /// The client capabilities  of a {@link CodeLensRequest}.
        ///
        /// LSP Specification name: `CodeLensClientCapabilities`
        pub const CodeLens = struct {
            /// Whether code lens supports dynamic registration.
            dynamicRegistration: ?bool = null,
            /// Whether the client supports resolving additional code lens
            /// properties via a separate `codeLens/resolve` request.
            ///
            /// @since 3.18.0
            resolveSupport: ?ResolveOptions = null,

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientCodeLensResolveOptions`
            pub const ResolveOptions = struct {
                /// The properties that a client can resolve lazily.
                properties: []const []const u8,
            };
        };

        /// The client capabilities of a {@link DocumentLinkRequest}.
        ///
        /// LSP Specification name: `DocumentLinkClientCapabilities`
        pub const DocumentLink = struct {
            /// Whether document link supports dynamic registration.
            dynamicRegistration: ?bool = null,
            /// Whether the client supports the `tooltip` property on `DocumentLink`.
            ///
            /// @since 3.15.0
            tooltipSupport: ?bool = null,
        };

        /// LSP Specification name: `DocumentColorClientCapabilities`
        pub const DocumentColor = struct {
            /// Whether implementation supports dynamic registration. If this is set to `true`
            /// the client supports the new `DocumentColorRegistrationOptions` return value
            /// for the corresponding server capability as well.
            dynamicRegistration: ?bool = null,
        };

        /// Client capabilities of a {@link DocumentFormattingRequest}.
        ///
        /// LSP Specification name: `DocumentFormattingClientCapabilities`
        pub const DocumentFormatting = struct {
            /// Whether formatting supports dynamic registration.
            dynamicRegistration: ?bool = null,
        };

        /// Client capabilities of a {@link DocumentRangeFormattingRequest}.
        ///
        /// LSP Specification name: `DocumentRangeFormattingClientCapabilities`
        pub const DocumentRangeFormatting = struct {
            /// Whether range formatting supports dynamic registration.
            dynamicRegistration: ?bool = null,
            /// Whether the client supports formatting multiple ranges at once.
            ///
            /// @since 3.18.0
            /// @proposed
            rangesSupport: ?bool = null,
        };

        /// Client capabilities of a {@link DocumentOnTypeFormattingRequest}.
        ///
        /// LSP Specification name: `DocumentOnTypeFormattingClientCapabilities`
        pub const DocumentOnTypeFormatting = struct {
            /// Whether on type formatting supports dynamic registration.
            dynamicRegistration: ?bool = null,
        };

        /// LSP Specification name: `RenameClientCapabilities`
        pub const Rename = struct {
            /// Whether rename supports dynamic registration.
            dynamicRegistration: ?bool = null,
            /// Client supports testing for validity of rename operations
            /// before execution.
            ///
            /// @since 3.12.0
            prepareSupport: ?bool = null,
            /// Client supports the default behavior result.
            ///
            /// The value indicates the default behavior used by the
            /// client.
            ///
            /// @since 3.16.0
            prepareSupportDefaultBehavior: ?PrepareSupportDefaultBehavior = null,
            /// Whether the client honors the change annotations in
            /// text edits and resource operations returned via the
            /// rename request's workspace edit by for example presenting
            /// the workspace edit in the user interface and asking
            /// for confirmation.
            ///
            /// @since 3.16.0
            honorsChangeAnnotations: ?bool = null,

            pub const PrepareSupportDefaultBehavior = enum(u32) {
                /// The client's default behavior is to select the identifier
                /// according the to language's syntax rule.
                Identifier = 1,
                /// Unknown Value
                _,

                pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
            };
        };

        /// LSP Specification name: `FoldingRangeClientCapabilities`
        pub const FoldingRange = struct {
            /// Whether implementation supports dynamic registration for folding range
            /// providers. If this is set to `true` the client supports the new
            /// `FoldingRangeRegistrationOptions` return value for the corresponding
            /// server capability as well.
            dynamicRegistration: ?bool = null,
            /// The maximum number of folding ranges that the client prefers to receive
            /// per document. The value serves as a hint, servers are free to follow the
            /// limit.
            rangeLimit: ?u32 = null,
            /// If set, the client signals that it only supports folding complete lines.
            /// If set, client will ignore specified `startCharacter` and `endCharacter`
            /// properties in a FoldingRange.
            lineFoldingOnly: ?bool = null,
            /// Specific options for the folding range kind.
            ///
            /// @since 3.17.0
            foldingRangeKind: ?KindOptions = null,
            /// Specific options for the folding range.
            ///
            /// @since 3.17.0
            foldingRange: ?Options = null,

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientFoldingRangeKindOptions`
            pub const KindOptions = struct {
                /// The folding range kind values the client supports. When this
                /// property exists the client also guarantees that it will
                /// handle values outside its set gracefully and falls back
                /// to a default value when unknown.
                valueSet: ?[]const types.FoldingRange.Kind = null,
            };

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientFoldingRangeOptions`
            pub const Options = struct {
                /// If set, the client signals that it supports setting collapsedText on
                /// folding ranges to display custom labels instead of the default text.
                ///
                /// @since 3.17.0
                collapsedText: ?bool = null,
            };
        };

        /// LSP Specification name: `SelectionRangeClientCapabilities`
        pub const SelectionRange = struct {
            /// Whether implementation supports dynamic registration for selection range providers. If this is set to `true`
            /// the client supports the new `SelectionRangeRegistrationOptions` return value for the corresponding server
            /// capability as well.
            dynamicRegistration: ?bool = null,
        };

        /// The publish diagnostic client capabilities.
        ///
        /// LSP Specification name: `PublishDiagnosticsClientCapabilities`
        pub const PublishDiagnostics = struct {
            /// Whether the client interprets the version property of the
            /// `textDocument/publishDiagnostics` notification's parameter.
            ///
            /// @since 3.15.0
            versionSupport: ?bool = null,

            // Extends `DiagnosticsCapabilities`
            /// Whether the clients accepts diagnostics with related information.
            relatedInformation: ?bool = null,
            /// Client supports the tag property to provide meta data about a diagnostic.
            /// Clients supporting tags have to handle unknown tags gracefully.
            ///
            /// @since 3.15.0
            tagSupport: ?ClientCapabilities.TextDocument.Diagnostic.TagOptions = null,
            /// Client supports a codeDescription property
            ///
            /// @since 3.16.0
            codeDescriptionSupport: ?bool = null,
            /// Whether code action supports the `data` property which is
            /// preserved between a `textDocument/publishDiagnostics` and
            /// `textDocument/codeAction` request.
            ///
            /// @since 3.16.0
            dataSupport: ?bool = null,
        };

        /// @since 3.16.0
        ///
        /// LSP Specification name: `CallHierarchyClientCapabilities`
        pub const CallHierarchy = struct {
            /// Whether implementation supports dynamic registration. If this is set to `true`
            /// the client supports the new `(TextDocumentRegistrationOptions & StaticRegistrationOptions)`
            /// return value for the corresponding server capability as well.
            dynamicRegistration: ?bool = null,
        };

        /// @since 3.16.0
        ///
        /// LSP Specification name: `SemanticTokensClientCapabilities`
        pub const SemanticTokens = struct {
            /// Whether implementation supports dynamic registration. If this is set to `true`
            /// the client supports the new `(TextDocumentRegistrationOptions & StaticRegistrationOptions)`
            /// return value for the corresponding server capability as well.
            dynamicRegistration: ?bool = null,
            /// Which requests the client supports and might send to the server
            /// depending on the server's capability. Please note that clients might not
            /// show semantic tokens or degrade some of the user experience if a range
            /// or full request is advertised by the client but not provided by the
            /// server. If for example the client capability `requests.full` and
            /// `request.range` are both set to true but the server only provides a
            /// range provider the client might not render a minimap correctly or might
            /// even decide to not show any semantic tokens at all.
            requests: RequestOptions,
            /// The token types that the client supports.
            tokenTypes: []const []const u8,
            /// The token modifiers that the client supports.
            tokenModifiers: []const []const u8,
            /// The token formats the clients supports.
            formats: []const Format,
            /// Whether the client supports tokens that can overlap each other.
            overlappingTokenSupport: ?bool = null,
            /// Whether the client supports tokens that can span multiple lines.
            multilineTokenSupport: ?bool = null,
            /// Whether the client allows the server to actively cancel a
            /// semantic token request, e.g. supports returning
            /// LSPErrorCodes.ServerCancelled. If a server does the client
            /// needs to retrigger the request.
            ///
            /// @since 3.17.0
            serverCancelSupport: ?bool = null,
            /// Whether the client uses semantic tokens to augment existing
            /// syntax tokens. If set to `true` client side created syntax
            /// tokens and semantic tokens are both used for colorization. If
            /// set to `false` the client only uses the returned semantic tokens
            /// for colorization.
            ///
            /// If the value is `undefined` then the client behavior is not
            /// specified.
            ///
            /// @since 3.17.0
            augmentsSyntaxTokens: ?bool = null,

            /// LSP Specification name: `TokenFormat`
            pub const Format = union(enum) {
                relative,
                unknown_value: []const u8,

                pub const eql = parser.EnumCustomStringValues(@This(), false).eql;
                pub const jsonParse = parser.EnumCustomStringValues(@This(), false).jsonParse;
                pub const jsonParseFromValue = parser.EnumCustomStringValues(@This(), false).jsonParseFromValue;
                pub const jsonStringify = parser.EnumCustomStringValues(@This(), false).jsonStringify;
            };

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientSemanticTokensRequestOptions`
            pub const RequestOptions = struct {
                /// The client will send the `textDocument/semanticTokens/range` request if
                /// the server provides a corresponding handler.
                range: ?union(enum) {
                    bool: bool,
                    literal_1: struct {},

                    pub const jsonParse = parser.UnionParser(@This()).jsonParse;
                    pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
                    pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
                } = null,
                /// The client will send the `textDocument/semanticTokens/full` request if
                /// the server provides a corresponding handler.
                full: ?union(enum) {
                    bool: bool,
                    client_semantic_tokens_request_full_delta: FullDelta,

                    pub const jsonParse = parser.UnionParser(@This()).jsonParse;
                    pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
                    pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
                } = null,

                /// @since 3.18.0
                ///
                /// LSP Specification name: `ClientSemanticTokensRequestFullDelta`
                pub const FullDelta = struct {
                    /// The client will send the `textDocument/semanticTokens/full/delta` request if
                    /// the server provides a corresponding handler.
                    delta: ?bool = null,
                };
            };
        };

        /// Client capabilities for the linked editing range request.
        ///
        /// @since 3.16.0
        ///
        /// LSP Specification name: `LinkedEditingRangeClientCapabilities`
        pub const LinkedEditingRange = struct {
            /// Whether implementation supports dynamic registration. If this is set to `true`
            /// the client supports the new `(TextDocumentRegistrationOptions & StaticRegistrationOptions)`
            /// return value for the corresponding server capability as well.
            dynamicRegistration: ?bool = null,
        };

        /// Client capabilities specific to the moniker request.
        ///
        /// @since 3.16.0
        ///
        /// LSP Specification name: `MonikerClientCapabilities`
        pub const Moniker = struct {
            /// Whether moniker supports dynamic registration. If this is set to `true`
            /// the client supports the new `MonikerRegistrationOptions` return value
            /// for the corresponding server capability as well.
            dynamicRegistration: ?bool = null,
        };

        /// @since 3.17.0
        ///
        /// LSP Specification name: `TypeHierarchyClientCapabilities`
        pub const TypeHierarchy = struct {
            /// Whether implementation supports dynamic registration. If this is set to `true`
            /// the client supports the new `(TextDocumentRegistrationOptions & StaticRegistrationOptions)`
            /// return value for the corresponding server capability as well.
            dynamicRegistration: ?bool = null,
        };

        /// Client capabilities specific to inline values.
        ///
        /// @since 3.17.0
        ///
        /// LSP Specification name: `InlineValueClientCapabilities`
        pub const InlineValue = struct {
            /// Whether implementation supports dynamic registration for inline value providers.
            dynamicRegistration: ?bool = null,
        };

        /// Inlay hint client capabilities.
        ///
        /// @since 3.17.0
        ///
        /// LSP Specification name: `InlayHintClientCapabilities`
        pub const InlayHint = struct {
            /// Whether inlay hints support dynamic registration.
            dynamicRegistration: ?bool = null,
            /// Indicates which properties a client can resolve lazily on an inlay
            /// hint.
            resolveSupport: ?ResolveOptions = null,

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientInlayHintResolveOptions`
            pub const ResolveOptions = struct {
                /// The properties that a client can resolve lazily.
                properties: []const []const u8,
            };
        };

        /// Client capabilities specific to diagnostic pull requests.
        ///
        /// @since 3.17.0
        ///
        /// LSP Specification name: `DiagnosticClientCapabilities`
        pub const Diagnostic = struct {
            /// Whether implementation supports dynamic registration. If this is set to `true`
            /// the client supports the new `(TextDocumentRegistrationOptions & StaticRegistrationOptions)`
            /// return value for the corresponding server capability as well.
            dynamicRegistration: ?bool = null,
            /// Whether the clients supports related documents for document diagnostic pulls.
            relatedDocumentSupport: ?bool = null,

            // Extends `DiagnosticsCapabilities`
            /// Whether the clients accepts diagnostics with related information.
            relatedInformation: ?bool = null,
            /// Client supports the tag property to provide meta data about a diagnostic.
            /// Clients supporting tags have to handle unknown tags gracefully.
            ///
            /// @since 3.15.0
            tagSupport: ?TagOptions = null,
            /// Client supports a codeDescription property
            ///
            /// @since 3.16.0
            codeDescriptionSupport: ?bool = null,
            /// Whether code action supports the `data` property which is
            /// preserved between a `textDocument/publishDiagnostics` and
            /// `textDocument/codeAction` request.
            ///
            /// @since 3.16.0
            dataSupport: ?bool = null,

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientDiagnosticsTagOptions`
            pub const TagOptions = struct {
                /// The tags supported by the client.
                valueSet: []const types.Diagnostic.Tag,
            };
        };

        /// Client capabilities specific to inline completions.
        ///
        /// @since 3.18.0
        /// @proposed
        ///
        /// LSP Specification name: `InlineCompletionClientCapabilities`
        pub const InlineCompletion = struct {
            /// Whether implementation supports dynamic registration for inline completion providers.
            dynamicRegistration: ?bool = null,
        };
    };

    /// Workspace specific client capabilities.
    ///
    /// LSP Specification name: `WorkspaceClientCapabilities`
    pub const Workspace = struct {
        /// The client supports applying batch edits
        /// to the workspace by supporting the request
        /// 'workspace/applyEdit'
        applyEdit: ?bool = null,
        /// Capabilities specific to `WorkspaceEdit`s.
        workspaceEdit: ?Edit = null,
        /// Capabilities specific to the `workspace/didChangeConfiguration` notification.
        didChangeConfiguration: ?DidChangeConfiguration = null,
        /// Capabilities specific to the `workspace/didChangeWatchedFiles` notification.
        didChangeWatchedFiles: ?DidChangeWatchedFiles = null,
        /// Capabilities specific to the `workspace/symbol` request.
        symbol: ?Symbol = null,
        /// Capabilities specific to the `workspace/executeCommand` request.
        executeCommand: ?ExecuteCommand = null,
        /// The client has support for workspace folders.
        ///
        /// @since 3.6.0
        workspaceFolders: ?bool = null,
        /// The client supports `workspace/configuration` requests.
        ///
        /// @since 3.6.0
        configuration: ?bool = null,
        /// Capabilities specific to the semantic token requests scoped to the
        /// workspace.
        ///
        /// @since 3.16.0.
        semanticTokens: ?SemanticTokens = null,
        /// Capabilities specific to the code lens requests scoped to the
        /// workspace.
        ///
        /// @since 3.16.0.
        codeLens: ?CodeLens = null,
        /// The client has support for file notifications/requests for user operations on files.
        ///
        /// Since 3.16.0
        fileOperations: ?FileOperation = null,
        /// Capabilities specific to the inline values requests scoped to the
        /// workspace.
        ///
        /// @since 3.17.0.
        inlineValue: ?Workspace.InlineValue = null,
        /// Capabilities specific to the inlay hint requests scoped to the
        /// workspace.
        ///
        /// @since 3.17.0.
        inlayHint: ?Workspace.InlayHint = null,
        /// Capabilities specific to the diagnostic requests scoped to the
        /// workspace.
        ///
        /// @since 3.17.0.
        diagnostics: ?Workspace.Diagnostic = null,
        /// Capabilities specific to the folding range requests scoped to the workspace.
        ///
        /// @since 3.18.0
        /// @proposed
        foldingRange: ?Workspace.FoldingRange = null,
        /// Capabilities specific to the `workspace/textDocumentContent` request.
        ///
        /// @since 3.18.0
        /// @proposed
        textDocumentContent: ?TextDocumentContent = null,

        /// LSP Specification name: `WorkspaceEditClientCapabilities`
        pub const Edit = struct {
            /// The client supports versioned document changes in `WorkspaceEdit`s
            documentChanges: ?bool = null,
            /// The resource operations the client supports. Clients should at least
            /// support 'create', 'rename' and 'delete' files and folders.
            ///
            /// @since 3.13.0
            resourceOperations: ?[]const ResourceOperationKind = null,
            /// The failure handling strategy of a client if applying the workspace edit
            /// fails.
            ///
            /// @since 3.13.0
            failureHandling: ?FailureHandlingKind = null,
            /// Whether the client normalizes line endings to the client specific
            /// setting.
            /// If set to `true` the client will normalize line ending characters
            /// in a workspace edit to the client-specified new line
            /// character.
            ///
            /// @since 3.16.0
            normalizesLineEndings: ?bool = null,
            /// Whether the client in general supports change annotations on text edits,
            /// create file, rename file and delete file changes.
            ///
            /// @since 3.16.0
            changeAnnotationSupport: ?ChangeAnnotationsSupportOptions = null,
            /// Whether the client supports `WorkspaceEditMetadata` in `WorkspaceEdit`s.
            ///
            /// @since 3.18.0
            /// @proposed
            metadataSupport: ?bool = null,
            /// Whether the client supports snippets as text edits.
            ///
            /// @since 3.18.0
            /// @proposed
            snippetEditSupport: ?bool = null,

            /// @since 3.18.0
            pub const ChangeAnnotationsSupportOptions = struct {
                /// Whether the client groups edits with equal labels into tree nodes,
                /// for instance all edits labelled with "Changes in Strings" would
                /// be a tree node.
                groupsOnLabel: ?bool = null,
            };

            pub const ResourceOperationKind = union(enum) {
                /// Supports creating new files and folders.
                create,
                /// Supports renaming existing files and folders.
                rename,
                /// Supports deleting existing files and folders.
                delete,
                unknown_value: []const u8,

                pub const eql = parser.EnumCustomStringValues(@This(), false).eql;
                pub const jsonParse = parser.EnumCustomStringValues(@This(), false).jsonParse;
                pub const jsonParseFromValue = parser.EnumCustomStringValues(@This(), false).jsonParseFromValue;
                pub const jsonStringify = parser.EnumCustomStringValues(@This(), false).jsonStringify;
            };

            pub const FailureHandlingKind = union(enum) {
                /// Applying the workspace change is simply aborted if one of the changes provided
                /// fails. All operations executed before the failing operation stay executed.
                abort,
                /// All operations are executed transactional. That means they either all
                /// succeed or no changes at all are applied to the workspace.
                transactional,
                /// If the workspace edit contains only textual file changes they are executed transactional.
                /// If resource changes (create, rename or delete file) are part of the change the failure
                /// handling strategy is abort.
                textOnlyTransactional,
                /// The client tries to undo the operations already executed. But there is no
                /// guarantee that this is succeeding.
                undo,
                unknown_value: []const u8,

                pub const eql = parser.EnumCustomStringValues(@This(), false).eql;
                pub const jsonParse = parser.EnumCustomStringValues(@This(), false).jsonParse;
                pub const jsonParseFromValue = parser.EnumCustomStringValues(@This(), false).jsonParseFromValue;
                pub const jsonStringify = parser.EnumCustomStringValues(@This(), false).jsonStringify;
            };
        };

        /// LSP Specification name: `DidChangeConfigurationClientCapabilities`
        pub const DidChangeConfiguration = struct {
            /// Did change configuration notification supports dynamic registration.
            dynamicRegistration: ?bool = null,
        };

        /// LSP Specification name: `DidChangeWatchedFilesClientCapabilities`
        pub const DidChangeWatchedFiles = struct {
            /// Did change watched files notification supports dynamic registration. Please note
            /// that the current protocol doesn't support static configuration for file changes
            /// from the server side.
            dynamicRegistration: ?bool = null,
            /// Whether the client has support for {@link  RelativePattern relative pattern}
            /// or not.
            ///
            /// @since 3.17.0
            relativePatternSupport: ?bool = null,
        };

        /// Client capabilities for a {@link WorkspaceSymbolRequest}.
        ///
        /// LSP Specification name: `WorkspaceSymbolClientCapabilities`
        pub const Symbol = struct {
            /// Symbol request supports dynamic registration.
            dynamicRegistration: ?bool = null,
            /// Specific capabilities for the `SymbolKind` in the `workspace/symbol` request.
            symbolKind: ?SymbolKindOptions = null,
            /// The client supports tags on `SymbolInformation`.
            /// Clients supporting tags have to handle unknown tags gracefully.
            ///
            /// @since 3.16.0
            tagSupport: ?TagOptions = null,
            /// The client support partial workspace symbols. The client will send the
            /// request `workspaceSymbol/resolve` to the server to resolve additional
            /// properties.
            ///
            /// @since 3.17.0
            resolveSupport: ?ResolveOptions = null,

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientSymbolKindOptions`
            pub const SymbolKindOptions = struct {
                /// The symbol kind values the client supports. When this
                /// property exists the client also guarantees that it will
                /// handle values outside its set gracefully and falls back
                /// to a default value when unknown.
                ///
                /// If this property is not present the client only supports
                /// the symbol kinds from `File` to `Array` as defined in
                /// the initial version of the protocol.
                valueSet: ?[]const SymbolKind = null,
            };

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientSymbolTagOptions`
            pub const TagOptions = struct {
                /// The tags supported by the client.
                valueSet: []const SymbolTag,
            };

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientSymbolResolveOptions`
            pub const ResolveOptions = struct {
                /// The properties that a client can resolve lazily. Usually
                /// `location.range`
                properties: []const []const u8,
            };
        };

        /// The client capabilities of a {@link ExecuteCommandRequest}.
        ///
        /// LSP Specification name: `ExecuteCommandClientCapabilities`
        pub const ExecuteCommand = struct {
            /// Execute command supports dynamic registration.
            dynamicRegistration: ?bool = null,
        };

        /// @since 3.16.0
        ///
        /// LSP Specification name: `SemanticTokensWorkspaceClientCapabilities`
        pub const SemanticTokens = struct {
            /// Whether the client implementation supports a refresh request sent from
            /// the server to the client.
            ///
            /// Note that this event is global and will force the client to refresh all
            /// semantic tokens currently shown. It should be used with absolute care
            /// and is useful for situation where a server for example detects a project
            /// wide change that requires such a calculation.
            refreshSupport: ?bool = null,
        };

        /// @since 3.16.0
        ///
        /// LSP Specification name: `CodeLensWorkspaceClientCapabilities`
        pub const CodeLens = struct {
            /// Whether the client implementation supports a refresh request sent from the
            /// server to the client.
            ///
            /// Note that this event is global and will force the client to refresh all
            /// code lenses currently shown. It should be used with absolute care and is
            /// useful for situation where a server for example detect a project wide
            /// change that requires such a calculation.
            refreshSupport: ?bool = null,
        };

        /// Capabilities relating to events from file operations by the user in the client.
        ///
        /// These events do not come from the file system, they come from user operations
        /// like renaming a file in the UI.
        ///
        /// @since 3.16.0
        ///
        /// LSP Specification name: `FileOperationClientCapabilities`
        pub const FileOperation = struct {
            /// Whether the client supports dynamic registration for file requests/notifications.
            dynamicRegistration: ?bool = null,
            /// The client has support for sending didCreateFiles notifications.
            didCreate: ?bool = null,
            /// The client has support for sending willCreateFiles requests.
            willCreate: ?bool = null,
            /// The client has support for sending didRenameFiles notifications.
            didRename: ?bool = null,
            /// The client has support for sending willRenameFiles requests.
            willRename: ?bool = null,
            /// The client has support for sending didDeleteFiles notifications.
            didDelete: ?bool = null,
            /// The client has support for sending willDeleteFiles requests.
            willDelete: ?bool = null,
        };

        /// Client workspace capabilities specific to inline values.
        ///
        /// @since 3.17.0
        ///
        /// LSP Specification name: `InlineValueWorkspaceClientCapabilities`
        pub const InlineValue = struct {
            /// Whether the client implementation supports a refresh request sent from the
            /// server to the client.
            ///
            /// Note that this event is global and will force the client to refresh all
            /// inline values currently shown. It should be used with absolute care and is
            /// useful for situation where a server for example detects a project wide
            /// change that requires such a calculation.
            refreshSupport: ?bool = null,
        };

        /// Client workspace capabilities specific to inlay hints.
        ///
        /// @since 3.17.0
        ///
        /// LSP Specification name: `InlayHintWorkspaceClientCapabilities`
        pub const InlayHint = struct {
            /// Whether the client implementation supports a refresh request sent from
            /// the server to the client.
            ///
            /// Note that this event is global and will force the client to refresh all
            /// inlay hints currently shown. It should be used with absolute care and
            /// is useful for situation where a server for example detects a project wide
            /// change that requires such a calculation.
            refreshSupport: ?bool = null,
        };

        /// Workspace client capabilities specific to diagnostic pull requests.
        ///
        /// @since 3.17.0
        ///
        /// LSP Specification name: `DiagnosticWorkspaceClientCapabilities`
        pub const Diagnostic = struct {
            /// Whether the client implementation supports a refresh request sent from
            /// the server to the client.
            ///
            /// Note that this event is global and will force the client to refresh all
            /// pulled diagnostics currently shown. It should be used with absolute care and
            /// is useful for situation where a server for example detects a project wide
            /// change that requires such a calculation.
            refreshSupport: ?bool = null,
        };

        /// Client workspace capabilities specific to folding ranges
        ///
        /// @since 3.18.0
        /// @proposed
        ///
        /// LSP Specification name: `FoldingRangeWorkspaceClientCapabilities`
        pub const FoldingRange = struct {
            /// Whether the client implementation supports a refresh request sent from the
            /// server to the client.
            ///
            /// Note that this event is global and will force the client to refresh all
            /// folding ranges currently shown. It should be used with absolute care and is
            /// useful for situation where a server for example detects a project wide
            /// change that requires such a calculation.
            ///
            /// @since 3.18.0
            /// @proposed
            refreshSupport: ?bool = null,
        };

        /// Client capabilities for a text document content provider.
        ///
        /// @since 3.18.0
        /// @proposed
        ///
        /// LSP Specification name: `TextDocumentContentClientCapabilities`
        pub const TextDocumentContent = struct {
            /// Text document content provider supports dynamic registration.
            dynamicRegistration: ?bool = null,
        };
    };

    /// LSP Specification name: `WindowClientCapabilities`
    pub const Window = struct {
        /// It indicates whether the client supports server initiated
        /// progress using the `window/workDoneProgress/create` request.
        ///
        /// The capability also controls Whether client supports handling
        /// of progress notifications. If set servers are allowed to report a
        /// `workDoneProgress` property in the request specific server
        /// capabilities.
        ///
        /// @since 3.15.0
        workDoneProgress: ?bool = null,
        /// Capabilities specific to the showMessage request.
        ///
        /// @since 3.16.0
        showMessage: ?ShowMessageRequest = null,
        /// Capabilities specific to the showDocument request.
        ///
        /// @since 3.16.0
        showDocument: ?ShowDocument = null,

        /// Show message request client capabilities
        ///
        /// LSP Specification name: `ShowMessageRequestClientCapabilities`
        pub const ShowMessageRequest = struct {
            /// Capabilities specific to the `MessageActionItem` type.
            messageActionItem: ?ItemOptions = null,

            /// @since 3.18.0
            ///
            /// LSP Specification name: `ClientShowMessageActionItemOptions`
            pub const ItemOptions = struct {
                /// Whether the client supports additional attributes which
                /// are preserved and send back to the server in the
                /// request's response.
                additionalPropertiesSupport: ?bool = null,
            };
        };

        /// Client capabilities for the showDocument request.
        ///
        /// @since 3.16.0
        ///
        /// LSP Specification name: `ShowDocumentClientCapabilities`
        pub const ShowDocument = struct {
            /// The client has support for the showDocument
            /// request.
            support: bool,
        };
    };

    /// Capabilities specific to the notebook document support.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `NotebookDocumentClientCapabilities`
    pub const NotebookDocument = struct {
        /// Capabilities specific to notebook document synchronization
        ///
        /// @since 3.17.0
        synchronization: Sync,

        /// Notebook specific client capabilities.
        ///
        /// @since 3.17.0
        ///
        /// LSP Specification name: `NotebookDocumentSyncClientCapabilities`
        pub const Sync = struct {
            /// Whether implementation supports dynamic registration. If this is
            /// set to `true` the client supports the new
            /// `(TextDocumentRegistrationOptions & StaticRegistrationOptions)`
            /// return value for the corresponding server capability as well.
            dynamicRegistration: ?bool = null,
            /// The client supports sending execution summary data per cell.
            executionSummarySupport: ?bool = null,
        };
    };

    /// General client capabilities.
    ///
    /// @since 3.16.0
    ///
    /// LSP Specification name: `GeneralClientCapabilities`
    pub const General = struct {
        /// Client capability that signals how the client
        /// handles stale requests (e.g. a request
        /// for which the client will not process the response
        /// anymore since the information is outdated).
        ///
        /// @since 3.17.0
        staleRequestSupport: ?StaleRequestSupportOptions = null,
        /// Client capabilities specific to regular expressions.
        ///
        /// @since 3.16.0
        regularExpressions: ?RegularExpressions = null,
        /// Client capabilities specific to the client's markdown parser.
        ///
        /// @since 3.16.0
        markdown: ?Markdown = null,
        /// The position encodings supported by the client. Client and server
        /// have to agree on the same position encoding to ensure that offsets
        /// (e.g. character position in a line) are interpreted the same on both
        /// sides.
        ///
        /// To keep the protocol backwards compatible the following applies: if
        /// the value 'utf-16' is missing from the array of position encodings
        /// servers can assume that the client supports UTF-16. UTF-16 is
        /// therefore a mandatory encoding.
        ///
        /// If omitted it defaults to ['utf-16'].
        ///
        /// Implementation considerations: since the conversion from one encoding
        /// into another requires the content of the file / line the conversion
        /// is best done where the file is read which is usually on the server
        /// side.
        ///
        /// @since 3.17.0
        positionEncodings: ?[]const Position.EncodingKind = null,

        /// @since 3.18.0
        pub const StaleRequestSupportOptions = struct {
            /// The client will actively cancel the request.
            cancel: bool,
            /// The list of requests for which the client
            /// will retry the request if it receives a
            /// response with error code `ContentModified`
            retryOnContentModified: []const []const u8,
        };

        /// Client capabilities specific to regular expressions.
        ///
        /// @since 3.16.0
        ///
        /// LSP Specification name: `RegularExpressionsClientCapabilities`
        pub const RegularExpressions = struct {
            /// The engine's name.
            engine: EngineKind,
            /// The engine's version.
            version: ?[]const u8 = null,

            /// LSP Specification name: `RegularExpressionEngineKind`
            pub const EngineKind = []const u8;
        };

        /// Client capabilities specific to the used markdown parser.
        ///
        /// @since 3.16.0
        ///
        /// LSP Specification name: `MarkdownClientCapabilities`
        pub const Markdown = struct {
            /// The name of the parser.
            parser: []const u8,
            /// The version of the parser.
            version: ?[]const u8 = null,
            /// A list of HTML tags that the client allows / supports in
            /// Markdown.
            ///
            /// @since 3.17.0
            allowedTags: ?[]const []const u8 = null,
        };
    };
};

/// Defines the capabilities provided by a language
/// server.
pub const ServerCapabilities = struct {
    /// The position encoding the server picked from the encodings offered
    /// by the client via the client capability `general.positionEncodings`.
    ///
    /// If the client didn't provide any position encodings the only valid
    /// value that a server can return is 'utf-16'.
    ///
    /// If omitted it defaults to 'utf-16'.
    ///
    /// @since 3.17.0
    positionEncoding: ?Position.EncodingKind = null,
    /// Defines how text documents are synced. Is either a detailed structure
    /// defining each notification or for backwards compatibility the
    /// TextDocumentSyncKind number.
    textDocumentSync: ?TextDocumentSync = null,
    /// Defines how notebook documents are synced.
    ///
    /// @since 3.17.0
    notebookDocumentSync: ?NotebookDocumentSync = null,
    /// The server provides completion support.
    completionProvider: ?completion.Options = null,
    /// The server provides hover support.
    hoverProvider: ?HoverOptions = null,
    /// The server provides signature help support.
    signatureHelpProvider: ?SignatureHelp.Options = null,
    /// The server provides Goto Declaration support.
    declarationProvider: ?DeclarationOptions = null,
    /// The server provides goto definition support.
    definitionProvider: ?DefinitionOptions = null,
    /// The server provides Goto Type Definition support.
    typeDefinitionProvider: ?TypeDefinitionOptions = null,
    /// The server provides Goto Implementation support.
    implementationProvider: ?ImplementationOptions = null,
    /// The server provides find references support.
    referencesProvider: ?ReferencesOptions = null,
    /// The server provides document highlight support.
    documentHighlightProvider: ?DocumentHighlightOptions = null,
    /// The server provides document symbol support.
    documentSymbolProvider: ?DocumentSymbolOptions = null,
    /// The server provides code actions. CodeActionOptions may only be
    /// specified if the client states that it supports
    /// `codeActionLiteralSupport` in its initial `initialize` request.
    codeActionProvider: ?CodeActionOptions = null,
    /// The server provides code lens.
    codeLensProvider: ?code_lens.Options = null,
    /// The server provides document link support.
    documentLinkProvider: ?DocumentLink.Options = null,
    /// The server provides color provider support.
    colorProvider: ?ColorOptions = null,
    /// The server provides workspace symbol support.
    workspaceSymbolProvider: ?WorkspaceSymbolOptions = null,
    /// The server provides document formatting.
    documentFormattingProvider: ?DocumentFormattingOptions = null,
    /// The server provides document range formatting.
    documentRangeFormattingProvider: ?DocumentRangeFormattingOptions = null,
    /// The server provides document formatting on typing.
    documentOnTypeFormattingProvider: ?DocumentOnTypeFormattingOptions = null,
    /// The server provides rename support. RenameOptions may only be
    /// specified if the client states that it supports
    /// `prepareSupport` in its initial `initialize` request.
    renameProvider: ?RenameOptions = null,
    /// The server provides folding provider support.
    foldingRangeProvider: ?FoldingRangeOptions = null,
    /// The server provides selection range support.
    selectionRangeProvider: ?SelectionRangeOptions = null,
    /// The server provides execute command support.
    executeCommandProvider: ?workspace.execute_command.Options = null,
    /// The server provides call hierarchy support.
    ///
    /// @since 3.16.0
    callHierarchyProvider: ?CallHierarchyOptions = null,
    /// The server provides linked editing range support.
    ///
    /// @since 3.16.0
    linkedEditingRangeProvider: ?LinkedEditingRangeOptions = null,
    /// The server provides semantic tokens support.
    ///
    /// @since 3.16.0
    semanticTokensProvider: ?SemanticTokensOptions = null,
    /// The server provides moniker support.
    ///
    /// @since 3.16.0
    monikerProvider: ?MonikerOptions = null,
    /// The server provides type hierarchy support.
    ///
    /// @since 3.17.0
    typeHierarchyProvider: ?TypeHierarchyOptions = null,
    /// The server provides inline values.
    ///
    /// @since 3.17.0
    inlineValueProvider: ?InlineValueOptions = null,
    /// The server provides inlay hints.
    ///
    /// @since 3.17.0
    inlayHintProvider: ?InlayHintOptions = null,
    /// The server has support for pull model diagnostics.
    ///
    /// @since 3.17.0
    diagnosticProvider: ?DiagnosticOptions = null,
    /// Inline completion options used during static registration.
    ///
    /// @since 3.18.0
    /// @proposed
    inlineCompletionProvider: ?InlineCompletionOptions = null,
    /// Workspace specific server capabilities.
    workspace: ?WorkspaceOptions = null,
    /// Experimental server capabilities.
    experimental: ?LSPAny = null,

    /// Defines how text documents are synced. Is either a detailed structure
    /// defining each notification or for backwards compatibility the
    /// TextDocumentSyncKind number.
    pub const TextDocumentSync = union(enum) {
        text_document_sync_options: TextDocument.SyncOptions,
        text_document_sync_kind: TextDocument.SyncKind,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// Defines how notebook documents are synced.
    ///
    /// @since 3.17.0
    pub const NotebookDocumentSync = union(enum) {
        notebook_document_sync_options: NotebookDocument.SyncOptions,
        notebook_document_sync_registration_options: NotebookDocument.SyncRegistrationOptions,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides hover support.
    pub const HoverOptions = union(enum) {
        bool: bool,
        hover_options: Hover.Options,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides Goto Declaration support.
    pub const DeclarationOptions = union(enum) {
        bool: bool,
        declaration_options: declaration.Options,
        declaration_registration_options: declaration.RegistrationOptions,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides goto definition support.
    pub const DefinitionOptions = union(enum) {
        bool: bool,
        definition_options: Definition.Options,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides Goto Type Definition support.
    pub const TypeDefinitionOptions = union(enum) {
        bool: bool,
        type_definition_options: type_definition.Options,
        type_definition_registration_options: type_definition.RegistrationOptions,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides Goto Implementation support.
    pub const ImplementationOptions = union(enum) {
        bool: bool,
        implementation_options: implementation.Options,
        implementation_registration_options: implementation.RegistrationOptions,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides find references support.
    pub const ReferencesOptions = union(enum) {
        bool: bool,
        reference_options: reference.Options,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides document highlight support.
    pub const DocumentHighlightOptions = union(enum) {
        bool: bool,
        document_highlight_options: DocumentHighlight.Options,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides document symbol support.
    pub const DocumentSymbolOptions = union(enum) {
        bool: bool,
        document_symbol_options: DocumentSymbol.Options,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides code actions. CodeActionOptions may only be
    /// specified if the client states that it supports
    /// `codeActionLiteralSupport` in its initial `initialize` request.
    pub const CodeActionOptions = union(enum) {
        bool: bool,
        code_action_options: CodeAction.Options,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides color provider support.
    pub const ColorOptions = union(enum) {
        bool: bool,
        document_color_options: DocumentColor.Options,
        document_color_registration_options: DocumentColor.RegistrationOptions,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides workspace symbol support.
    pub const WorkspaceSymbolOptions = union(enum) {
        bool: bool,
        workspace_symbol_options: workspace.Symbol.Options,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides document formatting.
    pub const DocumentFormattingOptions = union(enum) {
        bool: bool,
        document_formatting_options: document_formatting.Options,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides document range formatting.
    pub const DocumentRangeFormattingOptions = union(enum) {
        bool: bool,
        document_range_formatting_options: document_range_formatting.Options,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides document formatting on typing.
    pub const DocumentOnTypeFormattingOptions = document_on_type_formatting.Options;

    /// The server provides rename support. RenameOptions may only be
    /// specified if the client states that it supports
    /// `prepareSupport` in its initial `initialize` request.
    pub const RenameOptions = union(enum) {
        bool: bool,
        rename_options: rename.Options,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides folding provider support.
    pub const FoldingRangeOptions = union(enum) {
        bool: bool,
        folding_range_options: FoldingRange.Options,
        folding_range_registration_options: FoldingRange.RegistrationOptions,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides selection range support.
    pub const SelectionRangeOptions = union(enum) {
        bool: bool,
        selection_range_options: SelectionRange.Options,
        selection_range_registration_options: SelectionRange.RegistrationOptions,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides call hierarchy support.
    ///
    /// @since 3.16.0
    pub const CallHierarchyOptions = union(enum) {
        bool: bool,
        call_hierarchy_options: call_hierarchy.Options,
        call_hierarchy_registration_options: call_hierarchy.RegistrationOptions,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides linked editing range support.
    ///
    /// @since 3.16.0
    pub const LinkedEditingRangeOptions = union(enum) {
        bool: bool,
        linked_editing_range_options: linked_editing_range.Options,
        linked_editing_range_registration_options: linked_editing_range.RegistrationOptions,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides semantic tokens support.
    ///
    /// @since 3.16.0
    pub const SemanticTokensOptions = union(enum) {
        semantic_tokens_options: semantic_tokens.Options,
        semantic_tokens_registration_options: semantic_tokens.RegistrationOptions,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides moniker support.
    ///
    /// @since 3.16.0
    pub const MonikerOptions = union(enum) {
        bool: bool,
        moniker_options: Moniker.Options,
        moniker_registration_options: Moniker.RegistrationOptions,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides type hierarchy support.
    ///
    /// @since 3.17.0
    pub const TypeHierarchyOptions = union(enum) {
        bool: bool,
        type_hierarchy_options: type_hierarchy.Options,
        type_hierarchy_registration_options: type_hierarchy.RegistrationOptions,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides inline values.
    ///
    /// @since 3.17.0
    pub const InlineValueOptions = union(enum) {
        bool: bool,
        inline_value_options: InlineValue.Options,
        inline_value_registration_options: InlineValue.RegistrationOptions,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server provides inlay hints.
    ///
    /// @since 3.17.0
    pub const InlayHintOptions = union(enum) {
        bool: bool,
        inlay_hint_options: InlayHint.Options,
        inlay_hint_registration_options: InlayHint.RegistrationOptions,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// The server has support for pull model diagnostics.
    ///
    /// @since 3.17.0
    pub const DiagnosticOptions = union(enum) {
        diagnostic_options: Diagnostic.Options,
        diagnostic_registration_options: Diagnostic.RegistrationOptions,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// Inline completion options used during static registration.
    ///
    /// @since 3.18.0
    /// @proposed
    pub const InlineCompletionOptions = union(enum) {
        bool: bool,
        inline_completion_options: inline_completion.Options,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// Defines workspace specific capabilities of the server.
    ///
    /// @since 3.18.0
    pub const WorkspaceOptions = struct {
        /// The server supports workspace folder.
        ///
        /// @since 3.6.0
        workspaceFolders: ?workspace.folders.ServerCapabilities = null,
        /// The server is interested in notifications/requests for operations on files.
        ///
        /// @since 3.16.0
        fileOperations: ?workspace.file_operation.Options = null,
        /// The server supports the `workspace/textDocumentContent` request.
        ///
        /// @since 3.18.0
        /// @proposed
        textDocumentContent: ?TextDocumentContent = null,

        /// The server supports the `workspace/textDocumentContent` request.
        ///
        /// @since 3.18.0
        /// @proposed
        pub const TextDocumentContent = union(enum) {
            text_document_content_options: workspace.text_document_content.Options,
            text_document_content_registration_options: workspace.text_document_content.RegistrationOptions,

            pub const jsonParse = parser.UnionParser(@This()).jsonParse;
            pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
            pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
        };
    };
};

pub const prepare_rename = struct {
    /// LSP Specification name: `PrepareRenameParams`
    pub const Params = struct {
        // Extends `TextDocumentPositionParams`
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The position inside the text document.
        position: Position,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,
    };

    /// LSP Specification name: `PrepareRenameResult`
    pub const Result = union(enum) {
        range: Range,
        prepare_rename_placeholder: Placeholder,
        prepare_rename_default_behavior: DefaultBehavior,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// @since 3.18.0
    ///
    /// LSP Specification name: `PrepareRenameDefaultBehavior`
    pub const DefaultBehavior = struct {
        defaultBehavior: bool,
    };

    /// @since 3.18.0
    ///
    /// LSP Specification name: `PrepareRenamePlaceholder`
    pub const Placeholder = struct {
        range: Range,
        placeholder: []const u8,
    };
};

pub const rename = struct {
    /// The parameters of a {@link RenameRequest}.
    ///
    /// LSP Specification name: `RenameParams`
    pub const Params = struct {
        /// The document to rename.
        textDocument: TextDocument.Identifier,
        /// The position at which this request was sent.
        position: Position,
        /// The new name of the symbol. If the given name is not valid the
        /// request must return a {@link ResponseError} with an
        /// appropriate message set.
        newName: []const u8,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,
    };

    /// Provider options for a {@link RenameRequest}.
    ///
    /// LSP Specification name: `RenameOptions`
    pub const Options = struct {
        /// Renames should be checked and tested before being executed.
        ///
        /// @since version 3.12.0
        prepareProvider: ?bool = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// Registration options for a {@link RenameRequest}.
    ///
    /// LSP Specification name: `RenameRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `RenameOptions`
        /// Renames should be checked and tested before being executed.
        ///
        /// @since version 3.12.0
        prepareProvider: ?bool = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };
};

pub const reference = struct {
    /// Parameters for a {@link ReferencesRequest}.
    ///
    /// LSP Specification name: `ReferenceParams`
    pub const Params = struct {
        context: Context,

        // Extends `TextDocumentPositionParams`
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The position inside the text document.
        position: Position,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    /// Value-object that contains additional information when
    /// requesting references.
    ///
    /// LSP Specification name: `ReferenceContext`
    pub const Context = struct {
        /// Include the declaration of the current symbol.
        includeDeclaration: bool,
    };

    /// Reference options.
    ///
    /// LSP Specification name: `ReferenceOptions`
    pub const Options = struct {
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// Registration options for a {@link ReferencesRequest}.
    ///
    /// LSP Specification name: `ReferenceRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `ReferenceOptions`
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };
};

pub const call_hierarchy = struct {
    /// Represents an incoming call, e.g. a caller of a method or constructor.
    ///
    /// @since 3.16.0
    ///
    /// LSP Specification name: `CallHierarchyIncomingCall`
    pub const IncomingCall = struct {
        /// The item that makes the call.
        from: Item,
        /// The ranges at which the calls appear. This is relative to the caller
        /// denoted by {@link CallHierarchyIncomingCall.from `this.from`}.
        fromRanges: []const Range,
    };

    /// The parameter of a `callHierarchy/incomingCalls` request.
    ///
    /// @since 3.16.0
    ///
    /// LSP Specification name: `CallHierarchyIncomingCallsParams`
    pub const IncomingCallsParams = struct {
        item: Item,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    /// Represents programming constructs like functions or constructors in the context
    /// of call hierarchy.
    ///
    /// @since 3.16.0
    ///
    /// LSP Specification name: `CallHierarchyItem`
    pub const Item = struct {
        /// The name of this item.
        name: []const u8,
        /// The kind of this item.
        kind: SymbolKind,
        /// Tags for this item.
        tags: ?[]const SymbolTag = null,
        /// More detail for this item, e.g. the signature of a function.
        detail: ?[]const u8 = null,
        /// The resource identifier of this item.
        uri: DocumentUri,
        /// The range enclosing this symbol not including leading/trailing whitespace but everything else, e.g. comments and code.
        range: Range,
        /// The range that should be selected and revealed when this symbol is being picked, e.g. the name of a function.
        /// Must be contained by the {@link CallHierarchyItem.range `range`}.
        selectionRange: Range,
        /// A data entry field that is preserved between a call hierarchy prepare and
        /// incoming calls or outgoing calls requests.
        data: ?LSPAny = null,
    };

    /// Call hierarchy options used during static registration.
    ///
    /// @since 3.16.0
    ///
    /// LSP Specification name: `CallHierarchyOptions`
    pub const Options = struct {
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// Represents an outgoing call, e.g. calling a getter from a method or a method from a constructor etc.
    ///
    /// @since 3.16.0
    ///
    /// LSP Specification name: `CallHierarchyOutgoingCall`
    pub const OutgoingCall = struct {
        /// The item that is called.
        to: Item,
        /// The range at which this item is called. This is the range relative to the caller, e.g the item
        /// passed to {@link CallHierarchyItemProvider.provideCallHierarchyOutgoingCalls `provideCallHierarchyOutgoingCalls`}
        /// and not {@link CallHierarchyOutgoingCall.to `this.to`}.
        fromRanges: []const Range,
    };

    /// The parameter of a `callHierarchy/outgoingCalls` request.
    ///
    /// @since 3.16.0
    ///
    /// LSP Specification name: `CallHierarchyOutgoingCallsParams`
    pub const OutgoingCallsParams = struct {
        item: Item,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    /// The parameter of a `textDocument/prepareCallHierarchy` request.
    ///
    /// @since 3.16.0
    ///
    /// LSP Specification name: `CallHierarchyPrepareParams`
    pub const PrepareParams = struct {
        // Extends `TextDocumentPositionParams`
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The position inside the text document.
        position: Position,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,
    };

    /// Call hierarchy options used during static or dynamic registration.
    ///
    /// @since 3.16.0
    ///
    /// LSP Specification name: `CallHierarchyRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `CallHierarchyOptions`
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,

        // Uses mixin `StaticRegistrationOptions`
        /// The id used to register the request. The id can be used to deregister
        /// the request again. See also Registration#id.
        id: ?[]const u8 = null,
    };
};

/// A code action represents a change that can be performed in code, e.g. to fix a problem or
/// to refactor code.
///
/// A CodeAction must set either `edit` and/or a `command`. If both are supplied, the `edit` is applied first, then the `command` is executed.
pub const CodeAction = struct {
    /// A short, human-readable, title for this code action.
    title: []const u8,
    /// The kind of the code action.
    ///
    /// Used to filter code actions.
    kind: ?Kind = null,
    /// The diagnostics that this code action resolves.
    diagnostics: ?[]const Diagnostic = null,
    /// Marks this as a preferred action. Preferred actions are used by the `auto fix` command and can be targeted
    /// by keybindings.
    ///
    /// A quick fix should be marked preferred if it properly addresses the underlying error.
    /// A refactoring should be marked preferred if it is the most reasonable choice of actions to take.
    ///
    /// @since 3.15.0
    isPreferred: ?bool = null,
    /// Marks that the code action cannot currently be applied.
    ///
    /// Clients should follow the following guidelines regarding disabled code actions:
    ///
    ///   - Disabled code actions are not shown in automatic [lightbulbs](https://code.visualstudio.com/docs/editor/editingevolved#_code-action)
    ///     code action menus.
    ///
    ///   - Disabled actions are shown as faded out in the code action menu when the user requests a more specific type
    ///     of code action, such as refactorings.
    ///
    ///   - If the user has a [keybinding](https://code.visualstudio.com/docs/editor/refactoring#_keybindings-for-code-actions)
    ///     that auto applies a code action and only disabled code actions are returned, the client should show the user an
    ///     error message with `reason` in the editor.
    ///
    /// @since 3.16.0
    disabled: ?Disabled = null,
    /// The workspace edit this code action performs.
    edit: ?WorkspaceEdit = null,
    /// A command this code action executes. If a code action
    /// provides an edit and a command, first the edit is
    /// executed and then the command.
    command: ?Command = null,
    /// A data entry field that is preserved on a code action between
    /// a `textDocument/codeAction` and a `codeAction/resolve` request.
    ///
    /// @since 3.16.0
    data: ?LSPAny = null,
    /// Tags for this code action.
    ///
    /// @since 3.18.0 - proposed
    tags: ?[]const Tag = null,

    /// The parameters of a {@link CodeActionRequest}.
    ///
    /// LSP Specification name: `CodeActionParams`
    pub const Params = struct {
        /// The document in which the command was invoked.
        textDocument: TextDocument.Identifier,
        /// The range for which the command was invoked.
        range: Range,
        /// Context carrying additional information.
        context: Context,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    /// A set of predefined code action kinds
    ///
    /// LSP Specification name: `CodeActionKind`
    pub const Kind = union(enum) {
        /// Empty kind.
        empty,
        /// Base kind for quickfix actions: 'quickfix'
        quickfix,
        /// Base kind for refactoring actions: 'refactor'
        refactor,
        /// Base kind for refactoring extraction actions: 'refactor.extract'
        ///
        /// Example extract actions:
        ///
        /// - Extract method
        /// - Extract function
        /// - Extract variable
        /// - Extract interface from class
        /// - ...
        @"refactor.extract",
        /// Base kind for refactoring inline actions: 'refactor.inline'
        ///
        /// Example inline actions:
        ///
        /// - Inline function
        /// - Inline variable
        /// - Inline constant
        /// - ...
        @"refactor.inline",
        /// Base kind for refactoring move actions: `refactor.move`
        ///
        /// Example move actions:
        ///
        /// - Move a function to a new file
        /// - Move a property between classes
        /// - Move method to base class
        /// - ...
        ///
        /// @since 3.18.0
        /// @proposed
        @"refactor.move",
        /// Base kind for refactoring rewrite actions: 'refactor.rewrite'
        ///
        /// Example rewrite actions:
        ///
        /// - Convert JavaScript function to class
        /// - Add or remove parameter
        /// - Encapsulate field
        /// - Make method static
        /// - Move method to base class
        /// - ...
        @"refactor.rewrite",
        /// Base kind for source actions: `source`
        ///
        /// Source code actions apply to the entire file.
        source,
        /// Base kind for an organize imports source action: `source.organizeImports`
        @"source.organizeImports",
        /// Base kind for auto-fix source actions: `source.fixAll`.
        ///
        /// Fix all actions automatically fix errors that have a clear fix that do not require user input.
        /// They should not suppress errors or perform unsafe fixes such as generating new types or classes.
        ///
        /// @since 3.15.0
        @"source.fixAll",
        /// Base kind for all code actions applying to the entire notebook's scope. CodeActionKinds using
        /// this should always begin with `notebook.`
        ///
        /// @since 3.18.0
        notebook,
        custom_value: []const u8,

        pub const eql = parser.EnumCustomStringValues(@This(), true).eql;
        pub const jsonParse = parser.EnumCustomStringValues(@This(), true).jsonParse;
        pub const jsonParseFromValue = parser.EnumCustomStringValues(@This(), true).jsonParseFromValue;
        pub const jsonStringify = parser.EnumCustomStringValues(@This(), true).jsonStringify;
    };

    /// Captures why the code action is currently disabled.
    ///
    /// @since 3.18.0
    ///
    /// LSP Specification name: `CodeActionDisabled`
    pub const Disabled = struct {
        /// Human readable description of why the code action is currently disabled.
        ///
        /// This is displayed in the code actions UI.
        reason: []const u8,
    };

    /// Code action tags are extra annotations that tweak the behavior of a code action.
    ///
    /// @since 3.18.0 - proposed
    ///
    /// LSP Specification name: `CodeActionTag`
    pub const Tag = enum(u32) {
        /// Marks the code action as LLM-generated.
        LLMGenerated = 1,
        /// Unknown Value
        _,

        pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
    };

    /// Contains additional diagnostic information about the context in which
    /// a {@link CodeActionProvider.provideCodeActions code action} is run.
    ///
    /// LSP Specification name: `CodeActionContext`
    pub const Context = struct {
        /// An array of diagnostics known on the client side overlapping the range provided to the
        /// `textDocument/codeAction` request. They are provided so that the server knows which
        /// errors are currently presented to the user for the given range. There is no guarantee
        /// that these accurately reflect the error state of the resource. The primary parameter
        /// to compute code actions is the provided range.
        diagnostics: []const Diagnostic,
        /// Requested kind of actions to return.
        ///
        /// Actions not of this kind are filtered out by the client before being shown. So servers
        /// can omit computing them.
        only: ?[]const Kind = null,
        /// The reason why code actions were requested.
        ///
        /// @since 3.17.0
        triggerKind: ?TriggerKind = null,
    };

    /// The reason why code actions were requested.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `CodeActionTriggerKind`
    pub const TriggerKind = enum(u32) {
        /// Code actions were explicitly requested by the user or by an extension.
        Invoked = 1,
        /// Code actions were requested automatically.
        ///
        /// This typically happens when current selection in a file changes, but can
        /// also be triggered when file content changes.
        Automatic = 2,
        /// Unknown Value
        _,

        pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
    };

    /// Documentation for a class of code actions.
    ///
    /// @since 3.18.0
    /// @proposed
    ///
    /// LSP Specification name: `CodeActionKindDocumentation`
    pub const KindDocumentation = struct {
        /// The kind of the code action being documented.
        ///
        /// If the kind is generic, such as `CodeActionKind.Refactor`, the documentation will be shown whenever any
        /// refactorings are returned. If the kind if more specific, such as `CodeActionKind.RefactorExtract`, the
        /// documentation will only be shown when extract refactoring code actions are returned.
        kind: Kind,
        /// Command that is ued to display the documentation to the user.
        ///
        /// The title of this documentation code action is taken from {@linkcode Command.title}
        command: Command,
    };

    /// Provider options for a {@link CodeActionRequest}.
    ///
    /// LSP Specification name: `CodeActionOptions`
    pub const Options = struct {
        /// CodeActionKinds that this server may return.
        ///
        /// The list of kinds may be generic, such as `CodeActionKind.Refactor`, or the server
        /// may list out every specific kind they provide.
        codeActionKinds: ?[]const Kind = null,
        /// Static documentation for a class of code actions.
        ///
        /// Documentation from the provider should be shown in the code actions menu if either:
        ///
        /// - Code actions of `kind` are requested by the editor. In this case, the editor will show the documentation that
        ///   most closely matches the requested code action kind. For example, if a provider has documentation for
        ///   both `Refactor` and `RefactorExtract`, when the user requests code actions for `RefactorExtract`,
        ///   the editor will use the documentation for `RefactorExtract` instead of the documentation for `Refactor`.
        ///
        /// - Any code actions of `kind` are returned by the provider.
        ///
        /// At most one documentation entry should be shown per provider.
        ///
        /// @since 3.18.0
        /// @proposed
        documentation: ?[]const KindDocumentation = null,
        /// The server provides support to resolve additional
        /// information for a code action.
        ///
        /// @since 3.16.0
        resolveProvider: ?bool = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    pub const Result = union(enum) {
        command: Command,
        code_action: CodeAction,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// Registration options for a {@link CodeActionRequest}.
    ///
    /// LSP Specification name: `CodeActionRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `CodeActionOptions`
        /// CodeActionKinds that this server may return.
        ///
        /// The list of kinds may be generic, such as `CodeActionKind.Refactor`, or the server
        /// may list out every specific kind they provide.
        codeActionKinds: ?[]const Kind = null,
        /// Static documentation for a class of code actions.
        ///
        /// Documentation from the provider should be shown in the code actions menu if either:
        ///
        /// - Code actions of `kind` are requested by the editor. In this case, the editor will show the documentation that
        ///   most closely matches the requested code action kind. For example, if a provider has documentation for
        ///   both `Refactor` and `RefactorExtract`, when the user requests code actions for `RefactorExtract`,
        ///   the editor will use the documentation for `RefactorExtract` instead of the documentation for `Refactor`.
        ///
        /// - Any code actions of `kind` are returned by the provider.
        ///
        /// At most one documentation entry should be shown per provider.
        ///
        /// @since 3.18.0
        /// @proposed
        documentation: ?[]const KindDocumentation = null,
        /// The server provides support to resolve additional
        /// information for a code action.
        ///
        /// @since 3.16.0
        resolveProvider: ?bool = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };
};

pub const code_lens = struct {
    /// The parameters of a {@link CodeLensRequest}.
    ///
    /// LSP Specification name: `CodeLensParams`
    pub const Params = struct {
        /// The document to request code lens for.
        textDocument: TextDocument.Identifier,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    /// A code lens represents a {@link Command command} that should be shown along with
    /// source text, like the number of references, a way to run tests, etc.
    ///
    /// A code lens is _unresolved_ when no command is associated to it. For performance
    /// reasons the creation of a code lens and resolving should be done in two stages.
    ///
    /// LSP Specification name: `CodeLens`
    pub const Response = struct {
        /// The range in which this code lens is valid. Should only span a single line.
        range: Range,
        /// The command this code lens represents.
        command: ?Command = null,
        /// A data entry field that is preserved on a code lens item between
        /// a {@link CodeLensRequest} and a {@link CodeLensResolveRequest}
        data: ?LSPAny = null,
    };

    /// Code Lens provider options of a {@link CodeLensRequest}.
    ///
    /// LSP Specification name: `CodeLensOptions`
    pub const Options = struct {
        /// Code lens has a resolve provider as well.
        resolveProvider: ?bool = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// Registration options for a {@link CodeLensRequest}.
    ///
    /// LSP Specification name: `CodeLensRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `CodeLensOptions`
        /// Code lens has a resolve provider as well.
        resolveProvider: ?bool = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };
};

pub const completion = struct {
    /// Completion parameters
    ///
    /// LSP Specification name: `CompletionParams`
    pub const Params = struct {
        /// The completion context. This is only available it the client specifies
        /// to send this using the client capability `textDocument.completion.contextSupport === true`
        context: ?Context = null,

        // Extends `TextDocumentPositionParams`
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The position inside the text document.
        position: Position,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    /// Contains additional information about the context in which a completion request is triggered.
    ///
    /// LSP Specification name: `CompletionContext`
    pub const Context = struct {
        /// How the completion was triggered.
        triggerKind: TriggerKind,
        /// The trigger character (a single character) that has trigger code complete.
        /// Is undefined if `triggerKind !== CompletionTriggerKind.TriggerCharacter`
        triggerCharacter: ?[]const u8 = null,
    };

    /// A completion item represents a text snippet that is
    /// proposed to complete text that is being typed.
    ///
    /// LSP Specification name: `CompletionItem`
    pub const Item = struct {
        /// The label of this completion item.
        ///
        /// The label property is also by default the text that
        /// is inserted when selecting this completion.
        ///
        /// If label details are provided the label itself should
        /// be an unqualified name of the completion item.
        label: []const u8,
        /// Additional details for the label
        ///
        /// @since 3.17.0
        labelDetails: ?LabelDetails = null,
        /// The kind of this completion item. Based of the kind
        /// an icon is chosen by the editor.
        kind: ?Kind = null,
        /// Tags for this completion item.
        ///
        /// @since 3.15.0
        tags: ?[]const Tag = null,
        /// A human-readable string with additional information
        /// about this item, like type or symbol information.
        detail: ?[]const u8 = null,
        /// A human-readable string that represents a doc-comment.
        documentation: ?Documentation = null,
        /// Indicates if this item is deprecated.
        /// @deprecated Use `tags` instead.
        deprecated: ?bool = null,
        /// Select this item when showing.
        ///
        /// *Note* that only one completion item can be selected and that the
        /// tool / client decides which item that is. The rule is that the *first*
        /// item of those that match best is selected.
        preselect: ?bool = null,
        /// A string that should be used when comparing this item
        /// with other items. When `falsy` the {@link CompletionItem.label label}
        /// is used.
        sortText: ?[]const u8 = null,
        /// A string that should be used when filtering a set of
        /// completion items. When `falsy` the {@link CompletionItem.label label}
        /// is used.
        filterText: ?[]const u8 = null,
        /// A string that should be inserted into a document when selecting
        /// this completion. When `falsy` the {@link CompletionItem.label label}
        /// is used.
        ///
        /// The `insertText` is subject to interpretation by the client side.
        /// Some tools might not take the string literally. For example
        /// VS Code when code complete is requested in this example
        /// `con<cursor position>` and a completion item with an `insertText` of
        /// `console` is provided it will only insert `sole`. Therefore it is
        /// recommended to use `textEdit` instead since it avoids additional client
        /// side interpretation.
        insertText: ?[]const u8 = null,
        /// The format of the insert text. The format applies to both the
        /// `insertText` property and the `newText` property of a provided
        /// `textEdit`. If omitted defaults to `InsertTextFormat.PlainText`.
        ///
        /// Please note that the insertTextFormat doesn't apply to
        /// `additionalTextEdits`.
        insertTextFormat: ?InsertTextFormat = null,
        /// How whitespace and indentation is handled during completion
        /// item insertion. If not provided the clients default value depends on
        /// the `textDocument.completion.insertTextMode` client capability.
        ///
        /// @since 3.16.0
        insertTextMode: ?InsertTextMode = null,
        /// An {@link TextEdit edit} which is applied to a document when selecting
        /// this completion. When an edit is provided the value of
        /// {@link CompletionItem.insertText insertText} is ignored.
        ///
        /// Most editors support two different operations when accepting a completion
        /// item. One is to insert a completion text and the other is to replace an
        /// existing text with a completion text. Since this can usually not be
        /// predetermined by a server it can report both ranges. Clients need to
        /// signal support for `InsertReplaceEdits` via the
        /// `textDocument.completion.insertReplaceSupport` client capability
        /// property.
        ///
        /// *Note 1:* The text edit's range as well as both ranges from an insert
        /// replace edit must be a [single line] and they must contain the position
        /// at which completion has been requested.
        /// *Note 2:* If an `InsertReplaceEdit` is returned the edit's insert range
        /// must be a prefix of the edit's replace range, that means it must be
        /// contained and starting at the same position.
        ///
        /// @since 3.16.0 additional type `InsertReplaceEdit`
        textEdit: ?Item.TextEdit = null,
        /// The edit text used if the completion item is part of a CompletionList and
        /// CompletionList defines an item default for the text edit range.
        ///
        /// Clients will only honor this property if they opt into completion list
        /// item defaults using the capability `completionList.itemDefaults`.
        ///
        /// If not provided and a list's default range is provided the label
        /// property is used as a text.
        ///
        /// @since 3.17.0
        textEditText: ?[]const u8 = null,
        /// An optional array of additional {@link TextEdit text edits} that are applied when
        /// selecting this completion. Edits must not overlap (including the same insert position)
        /// with the main {@link CompletionItem.textEdit edit} nor with themselves.
        ///
        /// Additional text edits should be used to change text unrelated to the current cursor position
        /// (for example adding an import statement at the top of the file if the completion item will
        /// insert an unqualified type).
        additionalTextEdits: ?[]const types.TextEdit = null,
        /// An optional set of characters that when pressed while this completion is active will accept it first and
        /// then type that character. *Note* that all commit characters should have `length=1` and that superfluous
        /// characters will be ignored.
        commitCharacters: ?[]const []const u8 = null,
        /// An optional {@link Command command} that is executed *after* inserting this completion. *Note* that
        /// additional modifications to the current document should be described with the
        /// {@link CompletionItem.additionalTextEdits additionalTextEdits}-property.
        command: ?Command = null,
        /// A data entry field that is preserved on a completion item between a
        /// {@link CompletionRequest} and a {@link CompletionResolveRequest}.
        data: ?LSPAny = null,

        /// An {@link TextEdit edit} which is applied to a document when selecting
        /// this completion. When an edit is provided the value of
        /// {@link CompletionItem.insertText insertText} is ignored.
        ///
        /// Most editors support two different operations when accepting a completion
        /// item. One is to insert a completion text and the other is to replace an
        /// existing text with a completion text. Since this can usually not be
        /// predetermined by a server it can report both ranges. Clients need to
        /// signal support for `InsertReplaceEdits` via the
        /// `textDocument.completion.insertReplaceSupport` client capability
        /// property.
        ///
        /// *Note 1:* The text edit's range as well as both ranges from an insert
        /// replace edit must be a [single line] and they must contain the position
        /// at which completion has been requested.
        /// *Note 2:* If an `InsertReplaceEdit` is returned the edit's insert range
        /// must be a prefix of the edit's replace range, that means it must be
        /// contained and starting at the same position.
        ///
        /// @since 3.16.0 additional type `InsertReplaceEdit`
        pub const TextEdit = union(enum) {
            text_edit: types.TextEdit,
            insert_replace_edit: InsertReplaceEdit,

            pub const jsonParse = parser.UnionParser(@This()).jsonParse;
            pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
            pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
        };

        /// A special text edit to provide an insert and a replace operation.
        ///
        /// @since 3.16.0
        pub const InsertReplaceEdit = struct {
            /// The string to be inserted.
            newText: []const u8,
            /// The range if the insert is requested
            insert: Range,
            /// The range if the replace is requested.
            replace: Range,
        };

        /// The kind of a completion entry.
        ///
        /// LSP Specification name: `CompletionItemKind`
        pub const Kind = enum(u32) {
            Text = 1,
            Method = 2,
            Function = 3,
            Constructor = 4,
            Field = 5,
            Variable = 6,
            Class = 7,
            Interface = 8,
            Module = 9,
            Property = 10,
            Unit = 11,
            Value = 12,
            Enum = 13,
            Keyword = 14,
            Snippet = 15,
            Color = 16,
            File = 17,
            Reference = 18,
            Folder = 19,
            EnumMember = 20,
            Constant = 21,
            Struct = 22,
            Event = 23,
            Operator = 24,
            TypeParameter = 25,
            /// Unknown Value
            _,

            pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
        };

        /// Additional details for a completion item label.
        ///
        /// @since 3.17.0
        ///
        /// LSP Specification name: `CompletionItemLabelDetails`
        pub const LabelDetails = struct {
            /// An optional string which is rendered less prominently directly after {@link CompletionItem.label label},
            /// without any spacing. Should be used for function signatures and type annotations.
            detail: ?[]const u8 = null,
            /// An optional string which is rendered less prominently after {@link CompletionItem.detail}. Should be used
            /// for fully qualified names and file paths.
            description: ?[]const u8 = null,
        };

        /// Completion item tags are extra annotations that tweak the rendering of a completion
        /// item.
        ///
        /// @since 3.15.0
        ///
        /// LSP Specification name: `CompletionItemTag`
        pub const Tag = enum(u32) {
            /// Render a completion as obsolete, usually using a strike-out.
            Deprecated = 1,
            /// Unknown Value
            _,

            pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
        };
    };

    /// Represents a collection of {@link CompletionItem completion items} to be presented
    /// in the editor.
    ///
    /// LSP Specification name: `CompletionList`
    pub const List = struct {
        /// This list it not complete. Further typing results in recomputing this list.
        ///
        /// Recomputed lists have all their items replaced (not appended) in the
        /// incomplete completion sessions.
        isIncomplete: bool,
        /// In many cases the items of an actual completion result share the same
        /// value for properties like `commitCharacters` or the range of a text
        /// edit. A completion list can therefore define item defaults which will
        /// be used if a completion item itself doesn't specify the value.
        ///
        /// If a completion list specifies a default value and a completion item
        /// also specifies a corresponding value, the rules for combining these are
        /// defined by `applyKinds` (if the client supports it), defaulting to
        /// ApplyKind.Replace.
        ///
        /// Servers are only allowed to return default values if the client
        /// signals support for this via the `completionList.itemDefaults`
        /// capability.
        ///
        /// @since 3.17.0
        itemDefaults: ?ClientCapabilities.TextDocument.Completion.ItemDefaults = null,
        /// Specifies how fields from a completion item should be combined with those
        /// from `completionList.itemDefaults`.
        ///
        /// If unspecified, all fields will be treated as ApplyKind.Replace.
        ///
        /// If a field's value is ApplyKind.Replace, the value from a completion item
        /// (if provided and not `null`) will always be used instead of the value
        /// from `completionItem.itemDefaults`.
        ///
        /// If a field's value is ApplyKind.Merge, the values will be merged using
        /// the rules defined against each field below.
        ///
        /// Servers are only allowed to return `applyKind` if the client
        /// signals support for this via the `completionList.applyKindSupport`
        /// capability.
        ///
        /// @since 3.18.0
        applyKind: ?ClientCapabilities.TextDocument.Completion.ItemApplyKinds = null,
        /// The completion items.
        items: []const Item,
    };

    /// Completion options.
    ///
    /// LSP Specification name: `CompletionOptions`
    pub const Options = struct {
        /// Most tools trigger completion request automatically without explicitly requesting
        /// it using a keyboard shortcut (e.g. Ctrl+Space). Typically they do so when the user
        /// starts to type an identifier. For example if the user types `c` in a JavaScript file
        /// code complete will automatically pop up present `console` besides others as a
        /// completion item. Characters that make up identifiers don't need to be listed here.
        ///
        /// If code complete should automatically be trigger on characters not being valid inside
        /// an identifier (for example `.` in JavaScript) list them in `triggerCharacters`.
        triggerCharacters: ?[]const []const u8 = null,
        /// The list of all possible characters that commit a completion. This field can be used
        /// if clients don't support individual commit characters per completion item. See
        /// `ClientCapabilities.textDocument.completion.completionItem.commitCharactersSupport`
        ///
        /// If a server provides both `allCommitCharacters` and commit characters on an individual
        /// completion item the ones on the completion item win.
        ///
        /// @since 3.2.0
        allCommitCharacters: ?[]const []const u8 = null,
        /// The server provides support to resolve additional
        /// information for a completion item.
        resolveProvider: ?bool = null,
        /// The server supports the following `CompletionItem` specific
        /// capabilities.
        ///
        /// @since 3.17.0
        completionItem: ?ItemOptions = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,

        /// @since 3.18.0
        ///
        /// LSP Specification name: `ServerCompletionItemOptions`
        pub const ItemOptions = struct {
            /// The server has support for completion item label
            /// details (see also `CompletionItemLabelDetails`) when
            /// receiving a completion item in a resolve call.
            ///
            /// @since 3.17.0
            labelDetailsSupport: ?bool = null,
        };
    };

    pub const Result = union(enum) {
        completion_items: []const Item,
        completion_list: List,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// Registration options for a {@link CompletionRequest}.
    ///
    /// LSP Specification name: `CompletionRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `CompletionOptions`
        /// Most tools trigger completion request automatically without explicitly requesting
        /// it using a keyboard shortcut (e.g. Ctrl+Space). Typically they do so when the user
        /// starts to type an identifier. For example if the user types `c` in a JavaScript file
        /// code complete will automatically pop up present `console` besides others as a
        /// completion item. Characters that make up identifiers don't need to be listed here.
        ///
        /// If code complete should automatically be trigger on characters not being valid inside
        /// an identifier (for example `.` in JavaScript) list them in `triggerCharacters`.
        triggerCharacters: ?[]const []const u8 = null,
        /// The list of all possible characters that commit a completion. This field can be used
        /// if clients don't support individual commit characters per completion item. See
        /// `ClientCapabilities.textDocument.completion.completionItem.commitCharactersSupport`
        ///
        /// If a server provides both `allCommitCharacters` and commit characters on an individual
        /// completion item the ones on the completion item win.
        ///
        /// @since 3.2.0
        allCommitCharacters: ?[]const []const u8 = null,
        /// The server provides support to resolve additional
        /// information for a completion item.
        resolveProvider: ?bool = null,
        /// The server supports the following `CompletionItem` specific
        /// capabilities.
        ///
        /// @since 3.17.0
        completionItem: ?Options.ItemOptions = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// How a completion was triggered
    ///
    /// LSP Specification name: `CompletionTriggerKind`
    pub const TriggerKind = enum(u32) {
        /// Completion was triggered by typing an identifier (24x7 code
        /// complete), manual invocation (e.g Ctrl+Space) or via API.
        Invoked = 1,
        /// Completion was triggered by a trigger character specified by
        /// the `triggerCharacters` properties of the `CompletionRegistrationOptions`.
        TriggerCharacter = 2,
        /// Completion was re-triggered as current completion list is incomplete
        TriggerForIncompleteCompletions = 3,
        /// Unknown Value
        _,

        pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
    };
};

/// The definition of a symbol represented as one or many {@link Location locations}.
/// For most programming languages there is only one location at which a symbol is
/// defined.
///
/// Servers should prefer returning `DefinitionLink` over `Definition` if supported
/// by the client.
pub const Definition = union(enum) {
    location: Location,
    locations: []const Location,

    /// Parameters for a {@link DefinitionRequest}.
    ///
    /// LSP Specification name: `DefinitionParams`
    pub const Params = struct {
        // Extends `TextDocumentPositionParams`
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The position inside the text document.
        position: Position,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    /// Information about where a symbol is defined.
    ///
    /// Provides additional metadata over normal {@link Location location} definitions, including the range of
    /// the defining symbol
    ///
    /// LSP Specification name: `DefinitionLink`
    pub const Link = LocationLink;

    /// Server Capabilities for a {@link DefinitionRequest}.
    ///
    /// LSP Specification name: `DefinitionOptions`
    pub const Options = struct {
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    pub const Result = union(enum) {
        definition: Definition,
        definition_links: []const Link,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    pub const PartialResult = union(enum) {
        locations: []const Location,
        definition_links: []const Link,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// Registration options for a {@link DefinitionRequest}.
    ///
    /// LSP Specification name: `DefinitionRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `DefinitionOptions`
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    pub const jsonParse = parser.UnionParser(@This()).jsonParse;
    pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
    pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
};

pub const declaration = struct {
    /// LSP Specification name: `DeclarationParams`
    pub const Params = struct {
        // Extends `TextDocumentPositionParams`
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The position inside the text document.
        position: Position,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    /// LSP Specification name: `DeclarationOptions`
    pub const Options = struct {
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// LSP Specification name: `DeclarationRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `DeclarationOptions`
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,

        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Uses mixin `StaticRegistrationOptions`
        /// The id used to register the request. The id can be used to deregister
        /// the request again. See also Registration#id.
        id: ?[]const u8 = null,
    };
};

pub const implementation = struct {
    /// LSP Specification name: `ImplementationParams`
    pub const Params = struct {
        // Extends `TextDocumentPositionParams`
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The position inside the text document.
        position: Position,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    /// LSP Specification name: `ImplementationOptions`
    pub const Options = struct {
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// LSP Specification name: `ImplementationRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `ImplementationOptions`
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,

        // Uses mixin `StaticRegistrationOptions`
        /// The id used to register the request. The id can be used to deregister
        /// the request again. See also Registration#id.
        id: ?[]const u8 = null,
    };
};

pub const type_definition = struct {
    /// LSP Specification name: `TypeDefinitionParams`
    pub const Params = struct {
        // Extends `TextDocumentPositionParams`
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The position inside the text document.
        position: Position,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    /// LSP Specification name: `TypeDefinitionOptions`
    pub const Options = struct {
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// LSP Specification name: `TypeDefinitionRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `TypeDefinitionOptions`
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,

        // Uses mixin `StaticRegistrationOptions`
        /// The id used to register the request. The id can be used to deregister
        /// the request again. See also Registration#id.
        id: ?[]const u8 = null,
    };
};

/// Represents a diagnostic, such as a compiler error or warning. Diagnostic objects
/// are only valid in the scope of a resource.
pub const Diagnostic = struct {
    /// The range at which the message applies
    range: Range,
    /// The diagnostic's severity. To avoid interpretation mismatches when a
    /// server is used with different clients it is highly recommended that servers
    /// always provide a severity value.
    severity: ?Severity = null,
    /// The diagnostic's code, which usually appear in the user interface.
    code: ?types.ID = null,
    /// An optional property to describe the error code.
    /// Requires the code field (above) to be present/not null.
    ///
    /// @since 3.16.0
    codeDescription: ?CodeDescription = null,
    /// A human-readable string describing the source of this
    /// diagnostic, e.g. 'typescript' or 'super lint'. It usually
    /// appears in the user interface.
    source: ?[]const u8 = null,
    /// The diagnostic's message. It usually appears in the user interface
    message: []const u8,
    /// Additional metadata about the diagnostic.
    ///
    /// @since 3.15.0
    tags: ?[]const Tag = null,
    /// An array of related diagnostic information, e.g. when symbol-names within
    /// a scope collide all definitions can be marked via this property.
    relatedInformation: ?[]const RelatedInformation = null,
    /// A data entry field that is preserved between a `textDocument/publishDiagnostics`
    /// notification and `textDocument/codeAction` request.
    ///
    /// @since 3.16.0
    data: ?LSPAny = null,

    /// Structure to capture a description for an error code.
    ///
    /// @since 3.16.0
    pub const CodeDescription = struct {
        /// An URI to open with more information about the diagnostic error.
        href: URI,
    };

    /// Diagnostic options.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `DiagnosticOptions`
    pub const Options = struct {
        /// An optional identifier under which the diagnostics are
        /// managed by the client.
        identifier: ?[]const u8 = null,
        /// Whether the language has inter file dependencies meaning that
        /// editing code in one file can result in a different diagnostic
        /// set in another file. Inter file dependencies are common for
        /// most programming languages and typically uncommon for linters.
        interFileDependencies: bool,
        /// The server provides support for workspace diagnostics as well.
        workspaceDiagnostics: bool,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// Diagnostic registration options.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `DiagnosticRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `DiagnosticOptions`
        /// An optional identifier under which the diagnostics are
        /// managed by the client.
        identifier: ?[]const u8 = null,
        /// Whether the language has inter file dependencies meaning that
        /// editing code in one file can result in a different diagnostic
        /// set in another file. Inter file dependencies are common for
        /// most programming languages and typically uncommon for linters.
        interFileDependencies: bool,
        /// The server provides support for workspace diagnostics as well.
        workspaceDiagnostics: bool,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,

        // Uses mixin `StaticRegistrationOptions`
        /// The id used to register the request. The id can be used to deregister
        /// the request again. See also Registration#id.
        id: ?[]const u8 = null,
    };

    /// Represents a related message and source code location for a diagnostic. This should be
    /// used to point to code locations that cause or related to a diagnostics, e.g when duplicating
    /// a symbol in a scope.
    ///
    /// LSP Specification name: `DiagnosticRelatedInformation`
    pub const RelatedInformation = struct {
        /// The location of this related diagnostic information.
        location: Location,
        /// The message of this related diagnostic information.
        message: []const u8,
    };

    /// Cancellation data returned from a diagnostic request.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `DiagnosticServerCancellationData`
    pub const ServerCancellationData = struct {
        retriggerRequest: bool,
    };

    /// The diagnostic's severity.
    ///
    /// LSP Specification name: `DiagnosticSeverity`
    pub const Severity = enum(u32) {
        /// Reports an error.
        Error = 1,
        /// Reports a warning.
        Warning = 2,
        /// Reports an information.
        Information = 3,
        /// Reports a hint.
        Hint = 4,
        /// Unknown Value
        _,

        pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
    };

    /// The diagnostic tags.
    ///
    /// @since 3.15.0
    ///
    /// LSP Specification name: `DiagnosticTag`
    pub const Tag = enum(u32) {
        /// Unused or unnecessary code.
        ///
        /// Clients are allowed to render diagnostics with this tag faded out instead of having
        /// an error squiggle.
        Unnecessary = 1,
        /// Deprecated or obsolete code.
        ///
        /// Clients are allowed to rendered diagnostics with this tag strike through.
        Deprecated = 2,
        /// Unknown Value
        _,

        pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
    };
};

pub const publish_diagnostics = struct {
    /// The publish diagnostic notification's parameters.
    ///
    /// LSP Specification name: `PublishDiagnosticsParams`
    pub const Params = struct {
        /// The URI for which diagnostic information is reported.
        uri: DocumentUri,
        /// Optional the version number of the document the diagnostics are published for.
        ///
        /// @since 3.15.0
        version: ?i32 = null,
        /// An array of diagnostic information items.
        diagnostics: []const Diagnostic,
    };
};

pub const ColorPresentation = struct {
    /// The label of this color presentation. It will be shown on the color
    /// picker header. By default this is also the text that is inserted when selecting
    /// this color presentation.
    label: []const u8,
    /// An {@link TextEdit edit} which is applied to a document when selecting
    /// this presentation for the color.  When `falsy` the {@link ColorPresentation.label label}
    /// is used.
    textEdit: ?TextEdit = null,
    /// An optional array of additional {@link TextEdit text edits} that are applied when
    /// selecting this color presentation. Edits must not overlap with the main {@link ColorPresentation.textEdit edit} nor with themselves.
    additionalTextEdits: ?[]const TextEdit = null,

    /// Parameters for a {@link ColorPresentationRequest}.
    ///
    /// LSP Specification name: `ColorPresentationParams`
    pub const Params = struct {
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The color to request presentations for.
        color: Color,
        /// The range where the color would be inserted. Serves as a context.
        range: Range,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };
};

/// Represents a color range from a document.
///
/// LSP Specification name: `ColorInformation`
pub const DocumentColor = struct {
    /// The range in the document where this color appears.
    range: Range,
    /// The actual color value for this color range.
    color: Color,

    /// Parameters for a {@link DocumentColorRequest}.
    ///
    /// LSP Specification name: `DocumentColorParams`
    pub const Params = struct {
        /// The text document.
        textDocument: TextDocument.Identifier,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    /// LSP Specification name: `DocumentColorOptions`
    pub const Options = struct {
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// LSP Specification name: `DocumentColorRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `DocumentColorOptions`
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,

        // Uses mixin `StaticRegistrationOptions`
        /// The id used to register the request. The id can be used to deregister
        /// the request again. See also Registration#id.
        id: ?[]const u8 = null,
    };
};

pub const document_diagnostic = struct {
    /// Parameters of the document diagnostic request.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `DocumentDiagnosticParams`
    pub const Params = struct {
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The additional identifier  provided during registration.
        identifier: ?[]const u8 = null,
        /// The result id of a previous response if provided.
        previousResultId: ?[]const u8 = null,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    /// The result of a document diagnostic pull request. A report can
    /// either be a full report containing all diagnostics for the
    /// requested document or an unchanged report indicating that nothing
    /// has changed in terms of diagnostics in comparison to the last
    /// pull request.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `DocumentDiagnosticReport`
    pub const Report = union(enum) {
        related_full_document_diagnostic_report: Full.Related,
        related_unchanged_document_diagnostic_report: Unchanged.Related,

        /// The document diagnostic report kinds.
        ///
        /// @since 3.17.0
        ///
        /// LSP Specification name: `DocumentDiagnosticReportKind`
        pub const Kind = union(enum) {
            /// A diagnostic report with a full
            /// set of problems.
            full,
            /// A report indicating that the last
            /// returned report is still accurate.
            unchanged,
            unknown_value: []const u8,

            pub const eql = parser.EnumCustomStringValues(@This(), false).eql;
            pub const jsonParse = parser.EnumCustomStringValues(@This(), false).jsonParse;
            pub const jsonParseFromValue = parser.EnumCustomStringValues(@This(), false).jsonParseFromValue;
            pub const jsonStringify = parser.EnumCustomStringValues(@This(), false).jsonStringify;
        };

        /// A partial result for a document diagnostic report.
        ///
        /// @since 3.17.0
        ///
        /// LSP Specification name: `DocumentDiagnosticReportPartialResult`
        pub const PartialResult = struct {
            relatedDocuments: parser.Map(DocumentUri, union(enum) {
                full_document_diagnostic_report: Full,
                unchanged_document_diagnostic_report: Unchanged,

                pub const jsonParse = parser.UnionParser(@This()).jsonParse;
                pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
                pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
            }),
        };

        /// A diagnostic report indicating that the last returned
        /// report is still accurate.
        ///
        /// @since 3.17.0
        ///
        /// LSP Specification name: `UnchangedDocumentDiagnosticReport`
        pub const Unchanged = struct {
            /// A document diagnostic report indicating
            /// no changes to the last result. A server can
            /// only return `unchanged` if result ids are
            /// provided.
            kind: []const u8 = "unchanged",
            /// A result id which will be sent on the next
            /// diagnostic request for the same document.
            resultId: []const u8,

            /// An unchanged diagnostic report with a set of related documents.
            ///
            /// @since 3.17.0
            ///
            /// LSP Specification name: `RelatedUnchangedDocumentDiagnosticReport`
            pub const Related = struct {
                /// Diagnostics of related documents. This information is useful
                /// in programming languages where code in a file A can generate
                /// diagnostics in a file B which A depends on. An example of
                /// such a language is C/C++ where marco definitions in a file
                /// a.cpp and result in errors in a header file b.hpp.
                ///
                /// @since 3.17.0
                relatedDocuments: ?parser.Map(DocumentUri, union(enum) {
                    full_document_diagnostic_report: Full,
                    unchanged_document_diagnostic_report: Unchanged,

                    pub const jsonParse = parser.UnionParser(@This()).jsonParse;
                    pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
                    pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
                }) = null,

                // Extends `UnchangedDocumentDiagnosticReport`
                /// A document diagnostic report indicating
                /// no changes to the last result. A server can
                /// only return `unchanged` if result ids are
                /// provided.
                kind: []const u8 = "unchanged",
                /// A result id which will be sent on the next
                /// diagnostic request for the same document.
                resultId: []const u8,
            };
        };

        /// A diagnostic report with a full set of problems.
        ///
        /// @since 3.17.0
        ///
        /// LSP Specification name: `FullDocumentDiagnosticReport`
        pub const Full = struct {
            /// A full document diagnostic report.
            kind: []const u8 = "full",
            /// An optional result id. If provided it will
            /// be sent on the next diagnostic request for the
            /// same document.
            resultId: ?[]const u8 = null,
            /// The actual items.
            items: []const Diagnostic,

            /// A full diagnostic report with a set of related documents.
            ///
            /// @since 3.17.0
            ///
            /// LSP Specification name: `RelatedFullDocumentDiagnosticReport`
            pub const Related = struct {
                /// Diagnostics of related documents. This information is useful
                /// in programming languages where code in a file A can generate
                /// diagnostics in a file B which A depends on. An example of
                /// such a language is C/C++ where marco definitions in a file
                /// a.cpp and result in errors in a header file b.hpp.
                ///
                /// @since 3.17.0
                relatedDocuments: ?parser.Map(DocumentUri, union(enum) {
                    full_document_diagnostic_report: Full,
                    unchanged_document_diagnostic_report: Unchanged,

                    pub const jsonParse = parser.UnionParser(@This()).jsonParse;
                    pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
                    pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
                }) = null,

                // Extends `FullDocumentDiagnosticReport`
                /// A full document diagnostic report.
                kind: []const u8 = "full",
                /// An optional result id. If provided it will
                /// be sent on the next diagnostic request for the
                /// same document.
                resultId: ?[]const u8 = null,
                /// The actual items.
                items: []const Diagnostic,
            };
        };

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };
};

pub const document_formatting = struct {
    /// The parameters of a {@link DocumentFormattingRequest}.
    ///
    /// LSP Specification name: `DocumentFormattingParams`
    pub const Params = struct {
        /// The document to format.
        textDocument: TextDocument.Identifier,
        /// The format options.
        options: FormattingOptions,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,
    };

    /// Provider options for a {@link DocumentFormattingRequest}.
    ///
    /// LSP Specification name: `DocumentFormattingOptions`
    pub const Options = struct {
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// Registration options for a {@link DocumentFormattingRequest}.
    ///
    /// LSP Specification name: `DocumentFormattingRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `DocumentFormattingOptions`
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };
};

/// A document highlight is a range inside a text document which deserves
/// special attention. Usually a document highlight is visualized by changing
/// the background color of its range.
pub const DocumentHighlight = struct {
    /// The range this highlight applies to.
    range: Range,
    /// The highlight kind, default is {@link DocumentHighlightKind.Text text}.
    kind: ?Kind = null,

    /// Parameters for a {@link DocumentHighlightRequest}.
    ///
    /// LSP Specification name: `DocumentHighlightParams`
    pub const Params = struct {
        // Extends `TextDocumentPositionParams`
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The position inside the text document.
        position: Position,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    /// A document highlight kind.
    ///
    /// LSP Specification name: `DocumentHighlightKind`
    pub const Kind = enum(u32) {
        /// A textual occurrence.
        Text = 1,
        /// Read-access of a symbol, like reading a variable.
        Read = 2,
        /// Write-access of a symbol, like writing to a variable.
        Write = 3,
        /// Unknown Value
        _,

        pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
    };

    /// Provider options for a {@link DocumentHighlightRequest}.
    ///
    /// LSP Specification name: `DocumentHighlightOptions`
    pub const Options = struct {
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// Registration options for a {@link DocumentHighlightRequest}.
    ///
    /// LSP Specification name: `DocumentHighlightRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `DocumentHighlightOptions`
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };
};

/// A document link is a range in a text document that links to an internal or external resource, like another
/// text document or a web site.
pub const DocumentLink = struct {
    /// The range this link applies to.
    range: Range,
    /// The uri this link points to. If missing a resolve request is sent later.
    target: ?URI = null,
    /// The tooltip text when you hover over this link.
    ///
    /// If a tooltip is provided, is will be displayed in a string that includes instructions on how to
    /// trigger the link, such as `{0} (ctrl + click)`. The specific instructions vary depending on OS,
    /// user settings, and localization.
    ///
    /// @since 3.15.0
    tooltip: ?[]const u8 = null,
    /// A data entry field that is preserved on a document link between a
    /// DocumentLinkRequest and a DocumentLinkResolveRequest.
    data: ?LSPAny = null,

    /// The parameters of a {@link DocumentLinkRequest}.
    ///
    /// LSP Specification name: `DocumentLinkParams`
    pub const Params = struct {
        /// The document to provide document links for.
        textDocument: TextDocument.Identifier,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    /// Provider options for a {@link DocumentLinkRequest}.
    ///
    /// LSP Specification name: `DocumentLinkOptions`
    pub const Options = struct {
        /// Document links have a resolve provider as well.
        resolveProvider: ?bool = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// Registration options for a {@link DocumentLinkRequest}.
    ///
    /// LSP Specification name: `DocumentLinkRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `DocumentLinkOptions`
        /// Document links have a resolve provider as well.
        resolveProvider: ?bool = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };
};

pub const document_on_type_formatting = struct {
    /// The parameters of a {@link DocumentOnTypeFormattingRequest}.
    ///
    /// LSP Specification name: `DocumentOnTypeFormattingParams`
    pub const Params = struct {
        /// The document to format.
        textDocument: TextDocument.Identifier,
        /// The position around which the on type formatting should happen.
        /// This is not necessarily the exact position where the character denoted
        /// by the property `ch` got typed.
        position: Position,
        /// The character that has been typed that triggered the formatting
        /// on type request. That is not necessarily the last character that
        /// got inserted into the document since the client could auto insert
        /// characters as well (e.g. like automatic brace completion).
        ch: []const u8,
        /// The formatting options.
        options: FormattingOptions,
    };

    /// Provider options for a {@link DocumentOnTypeFormattingRequest}.
    ///
    /// LSP Specification name: `DocumentOnTypeFormattingOptions`
    pub const Options = struct {
        /// A character on which formatting should be triggered, like `{`.
        firstTriggerCharacter: []const u8,
        /// More trigger characters.
        moreTriggerCharacter: ?[]const []const u8 = null,
    };

    /// Registration options for a {@link DocumentOnTypeFormattingRequest}.
    ///
    /// LSP Specification name: `DocumentOnTypeFormattingRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `DocumentOnTypeFormattingOptions`
        /// A character on which formatting should be triggered, like `{`.
        firstTriggerCharacter: []const u8,
        /// More trigger characters.
        moreTriggerCharacter: ?[]const []const u8 = null,
    };
};

pub const document_range_formatting = struct {
    /// The parameters of a {@link DocumentRangeFormattingRequest}.
    ///
    /// LSP Specification name: `DocumentRangeFormattingParams`
    pub const Params = struct {
        /// The document to format.
        textDocument: TextDocument.Identifier,
        /// The range to format
        range: Range,
        /// The format options
        options: FormattingOptions,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,
    };

    /// Provider options for a {@link DocumentRangeFormattingRequest}.
    ///
    /// LSP Specification name: `DocumentRangeFormattingOptions`
    pub const Options = struct {
        /// Whether the server supports formatting multiple ranges at once.
        ///
        /// @since 3.18.0
        /// @proposed
        rangesSupport: ?bool = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// Registration options for a {@link DocumentRangeFormattingRequest}.
    ///
    /// LSP Specification name: `DocumentRangeFormattingRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `DocumentRangeFormattingOptions`
        /// Whether the server supports formatting multiple ranges at once.
        ///
        /// @since 3.18.0
        /// @proposed
        rangesSupport: ?bool = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };
};

pub const document_ranges_formatting = struct {
    /// The parameters of a {@link DocumentRangesFormattingRequest}.
    ///
    /// @since 3.18.0
    /// @proposed
    ///
    /// LSP Specification name: `DocumentRangesFormattingParams`
    pub const Params = struct {
        /// The document to format.
        textDocument: TextDocument.Identifier,
        /// The ranges to format
        ranges: []const Range,
        /// The format options
        options: FormattingOptions,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,
    };
};

/// Represents programming constructs like variables, classes, interfaces etc.
/// that appear in a document. Document symbols can be hierarchical and they
/// have two ranges: one that encloses its definition and one that points to
/// its most interesting range, e.g. the range of an identifier.
pub const DocumentSymbol = struct {
    /// The name of this symbol. Will be displayed in the user interface and therefore must not be
    /// an empty string or a string only consisting of white spaces.
    name: []const u8,
    /// More detail for this symbol, e.g the signature of a function.
    detail: ?[]const u8 = null,
    /// The kind of this symbol.
    kind: SymbolKind,
    /// Tags for this document symbol.
    ///
    /// @since 3.16.0
    tags: ?[]const SymbolTag = null,
    /// Indicates if this symbol is deprecated.
    ///
    /// @deprecated Use tags instead
    deprecated: ?bool = null,
    /// The range enclosing this symbol not including leading/trailing whitespace but everything else
    /// like comments. This information is typically used to determine if the clients cursor is
    /// inside the symbol to reveal in the symbol in the UI.
    range: Range,
    /// The range that should be selected and revealed when this symbol is being picked, e.g the name of a function.
    /// Must be contained by the `range`.
    selectionRange: Range,
    /// Children of this symbol, e.g. properties of a class.
    children: ?[]const DocumentSymbol = null,

    /// Provider options for a {@link DocumentSymbolRequest}.
    ///
    /// LSP Specification name: `DocumentSymbolOptions`
    pub const Options = struct {
        /// A human-readable string that is shown when multiple outlines trees
        /// are shown for the same document.
        ///
        /// @since 3.16.0
        label: ?[]const u8 = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// Parameters for a {@link DocumentSymbolRequest}.
    ///
    /// LSP Specification name: `DocumentSymbolParams`
    pub const Params = struct {
        /// The text document.
        textDocument: TextDocument.Identifier,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    pub const Result = union(enum) {
        symbol_informations: []const SymbolInformation,
        document_symbols: []const DocumentSymbol,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// Registration options for a {@link DocumentSymbolRequest}.
    ///
    /// LSP Specification name: `DocumentSymbolRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `DocumentSymbolOptions`
        /// A human-readable string that is shown when multiple outlines trees
        /// are shown for the same document.
        ///
        /// @since 3.16.0
        label: ?[]const u8 = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };
};

/// Represents a folding range. To be valid, start and end line must be bigger than zero and smaller
/// than the number of lines in the document. Clients are free to ignore invalid ranges.
pub const FoldingRange = struct {
    /// The zero-based start line of the range to fold. The folded area starts after the line's last character.
    /// To be valid, the end must be zero or larger and smaller than the number of lines in the document.
    startLine: u32,
    /// The zero-based character offset from where the folded range starts. If not defined, defaults to the length of the start line.
    startCharacter: ?u32 = null,
    /// The zero-based end line of the range to fold. The folded area ends with the line's last character.
    /// To be valid, the end must be zero or larger and smaller than the number of lines in the document.
    endLine: u32,
    /// The zero-based character offset before the folded range ends. If not defined, defaults to the length of the end line.
    endCharacter: ?u32 = null,
    /// Describes the kind of the folding range such as 'comment' or 'region'. The kind
    /// is used to categorize folding ranges and used by commands like 'Fold all comments'.
    /// See {@link FoldingRangeKind} for an enumeration of standardized kinds.
    kind: ?Kind = null,
    /// The text that the client should show when the specified range is
    /// collapsed. If not defined or not supported by the client, a default
    /// will be chosen by the client.
    ///
    /// @since 3.17.0
    collapsedText: ?[]const u8 = null,

    /// Parameters for a {@link FoldingRangeRequest}.
    ///
    /// LSP Specification name: `FoldingRangeParams`
    pub const Params = struct {
        /// The text document.
        textDocument: TextDocument.Identifier,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    /// A set of predefined range kinds.
    ///
    /// LSP Specification name: `FoldingRangeKind`
    pub const Kind = union(enum) {
        /// Folding range for a comment
        comment,
        /// Folding range for an import or include
        imports,
        /// Folding range for a region (e.g. `#region`)
        region,
        custom_value: []const u8,

        pub const eql = parser.EnumCustomStringValues(@This(), false).eql;
        pub const jsonParse = parser.EnumCustomStringValues(@This(), false).jsonParse;
        pub const jsonParseFromValue = parser.EnumCustomStringValues(@This(), false).jsonParseFromValue;
        pub const jsonStringify = parser.EnumCustomStringValues(@This(), false).jsonStringify;
    };

    /// LSP Specification name: `FoldingRangeOptions`
    pub const Options = struct {
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// LSP Specification name: `FoldingRangeRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `FoldingRangeOptions`
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,

        // Uses mixin `StaticRegistrationOptions`
        /// The id used to register the request. The id can be used to deregister
        /// the request again. See also Registration#id.
        id: ?[]const u8 = null,
    };
};

/// The result of a hover request.
pub const Hover = struct {
    /// The hover's content
    contents: Contents,
    /// An optional range inside the text document that is used to
    /// visualize the hover, e.g. by changing the background color.
    range: ?Range = null,

    /// Parameters for a {@link HoverRequest}.
    ///
    /// LSP Specification name: `HoverParams`
    pub const Params = struct {
        // Extends `TextDocumentPositionParams`
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The position inside the text document.
        position: Position,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,
    };

    /// The hover's content
    pub const Contents = union(enum) {
        markup_content: MarkupContent,
        marked_string: DeprecatedMarkedString,
        marked_strings: []const DeprecatedMarkedString,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// MarkedString can be used to render human readable text. It is either a markdown string
    /// or a code-block that provides a language and a code snippet. The language identifier
    /// is semantically equal to the optional language identifier in fenced code blocks in GitHub
    /// issues. See https://help.github.com/articles/creating-and-highlighting-code-blocks/#syntax-highlighting
    ///
    /// The pair of a language and a value is an equivalent to markdown:
    /// ```${language}
    /// ${value}
    /// ```
    ///
    /// Note that markdown strings will be sanitized - that means html will be escaped.
    /// @deprecated use MarkupContent instead.
    ///
    /// LSP Specification name: `MarkedString`
    pub const DeprecatedMarkedString = union(enum) {
        string: []const u8,
        marked_string_with_language: WithLanguage,

        /// @since 3.18.0
        /// @deprecated use MarkupContent instead.
        ///
        /// LSP Specification name: `MarkedStringWithLanguage`
        pub const WithLanguage = struct {
            language: []const u8,
            value: []const u8,
        };

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// Hover options.
    ///
    /// LSP Specification name: `HoverOptions`
    pub const Options = struct {
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// Registration options for a {@link HoverRequest}.
    ///
    /// LSP Specification name: `HoverRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `HoverOptions`
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };
};

/// Inlay hint information.
///
/// @since 3.17.0
pub const InlayHint = struct {
    /// The position of this hint.
    ///
    /// If multiple hints have the same position, they will be shown in the order
    /// they appear in the response.
    position: Position,
    /// The label of this hint. A human readable string or an array of
    /// InlayHintLabelPart label parts.
    ///
    /// *Note* that neither the string nor the label part can be empty.
    label: Label,
    /// The kind of this hint. Can be omitted in which case the client
    /// should fall back to a reasonable default.
    kind: ?Kind = null,
    /// Optional text edits that are performed when accepting this inlay hint.
    ///
    /// *Note* that edits are expected to change the document so that the inlay
    /// hint (or its nearest variant) is now part of the document and the inlay
    /// hint itself is now obsolete.
    textEdits: ?[]const TextEdit = null,
    /// The tooltip text when you hover over this item.
    tooltip: ?Documentation = null,
    /// Render padding before the hint.
    ///
    /// Note: Padding should use the editor's background color, not the
    /// background color of the hint itself. That means padding can be used
    /// to visually align/separate an inlay hint.
    paddingLeft: ?bool = null,
    /// Render padding after the hint.
    ///
    /// Note: Padding should use the editor's background color, not the
    /// background color of the hint itself. That means padding can be used
    /// to visually align/separate an inlay hint.
    paddingRight: ?bool = null,
    /// A data entry field that is preserved on an inlay hint between
    /// a `textDocument/inlayHint` and a `inlayHint/resolve` request.
    data: ?LSPAny = null,

    /// A parameter literal used in inlay hint requests.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `InlayHintParams`
    pub const Params = struct {
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The document range for which inlay hints should be computed.
        range: Range,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,
    };

    /// The label of this hint. A human readable string or an array of
    /// InlayHintLabelPart label parts.
    ///
    /// *Note* that neither the string nor the label part can be empty.
    pub const Label = union(enum) {
        string: []const u8,
        inlay_hint_label_parts: []const LabelPart,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// Inlay hint kinds.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `InlayHintKind`
    pub const Kind = enum(u32) {
        /// An inlay hint that for a type annotation.
        Type = 1,
        /// An inlay hint that is for a parameter.
        Parameter = 2,
        /// Unknown Value
        _,

        pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
    };

    /// An inlay hint label part allows for interactive and composite labels
    /// of inlay hints.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `InlayHintLabelPart`
    pub const LabelPart = struct {
        /// The value of this label part.
        value: []const u8,
        /// The tooltip text when you hover over this label part. Depending on
        /// the client capability `inlayHint.resolveSupport` clients might resolve
        /// this property late using the resolve request.
        tooltip: ?Documentation = null,
        /// An optional source code location that represents this
        /// label part.
        ///
        /// The editor will use this location for the hover and for code navigation
        /// features: This part will become a clickable link that resolves to the
        /// definition of the symbol at the given location (not necessarily the
        /// location itself), it shows the hover that shows at the given location,
        /// and it shows a context menu with further code navigation commands.
        ///
        /// Depending on the client capability `inlayHint.resolveSupport` clients
        /// might resolve this property late using the resolve request.
        location: ?Location = null,
        /// An optional command for this label part.
        ///
        /// Depending on the client capability `inlayHint.resolveSupport` clients
        /// might resolve this property late using the resolve request.
        command: ?Command = null,
    };

    /// Inlay hint options used during static registration.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `InlayHintOptions`
    pub const Options = struct {
        /// The server provides support to resolve additional
        /// information for an inlay hint item.
        resolveProvider: ?bool = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// Inlay hint options used during static or dynamic registration.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `InlayHintRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `InlayHintOptions`
        /// The server provides support to resolve additional
        /// information for an inlay hint item.
        resolveProvider: ?bool = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,

        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Uses mixin `StaticRegistrationOptions`
        /// The id used to register the request. The id can be used to deregister
        /// the request again. See also Registration#id.
        id: ?[]const u8 = null,
    };
};

pub const inline_completion = struct {
    /// A parameter literal used in inline completion requests.
    ///
    /// @since 3.18.0
    /// @proposed
    ///
    /// LSP Specification name: `InlineCompletionParams`
    pub const Params = struct {
        /// Additional information about the context in which inline completions were
        /// requested.
        context: Context,

        // Extends `TextDocumentPositionParams`
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The position inside the text document.
        position: Position,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,
    };

    /// An inline completion item represents a text snippet that is proposed inline to complete text that is being typed.
    ///
    /// @since 3.18.0
    /// @proposed
    ///
    /// LSP Specification name: `InlineCompletionItem`
    pub const Item = struct {
        /// The text to replace the range with. Must be set.
        insertText: InsertText,
        /// A text that is used to decide if this inline completion should be shown. When `falsy` the {@link InlineCompletionItem.insertText} is used.
        filterText: ?[]const u8 = null,
        /// The range to replace. Must begin and end on the same line.
        range: ?Range = null,
        /// An optional {@link Command} that is executed *after* inserting this completion.
        command: ?Command = null,

        /// The text to replace the range with. Must be set.
        pub const InsertText = union(enum) {
            string: []const u8,
            string_value: StringValue,

            pub const jsonParse = parser.UnionParser(@This()).jsonParse;
            pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
            pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
        };
    };

    /// Represents a collection of {@link InlineCompletionItem inline completion items} to be presented in the editor.
    ///
    /// @since 3.18.0
    /// @proposed
    ///
    /// LSP Specification name: `InlineCompletionList`
    pub const List = struct {
        /// The inline completion items
        items: []const Item,
    };

    /// Provides information about the context in which an inline completion was requested.
    ///
    /// @since 3.18.0
    /// @proposed
    ///
    /// LSP Specification name: `InlineCompletionContext`
    pub const Context = struct {
        /// Describes how the inline completion was triggered.
        triggerKind: TriggerKind,
        /// Provides information about the currently selected item in the autocomplete widget if it is visible.
        selectedCompletionInfo: ?SelectedCompletionInfo = null,

        /// Describes how an {@link InlineCompletionItemProvider inline completion provider} was triggered.
        ///
        /// @since 3.18.0
        /// @proposed
        ///
        /// LSP Specification name: `InlineCompletionTriggerKind`
        pub const TriggerKind = enum(u32) {
            /// Completion was triggered explicitly by a user gesture.
            Invoked = 1,
            /// Completion was triggered automatically while editing.
            Automatic = 2,
            /// Unknown Value
            _,

            pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
        };

        /// Describes the currently selected completion item.
        ///
        /// @since 3.18.0
        /// @proposed
        pub const SelectedCompletionInfo = struct {
            /// The range that will be replaced if this completion item is accepted.
            range: Range,
            /// The text the range will be replaced with if this completion is accepted.
            text: []const u8,
        };
    };

    /// Inline completion options used during static registration.
    ///
    /// @since 3.18.0
    /// @proposed
    ///
    /// LSP Specification name: `InlineCompletionOptions`
    pub const Options = struct {
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    pub const Result = union(enum) {
        inline_completion_list: List,
        inline_completion_items: []const Item,

        pub const jsonParse = parser.UnionParser(@This()).jsonParse;
        pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
        pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
    };

    /// Inline completion options used during static or dynamic registration.
    ///
    /// @since 3.18.0
    /// @proposed
    ///
    /// LSP Specification name: `InlineCompletionRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `InlineCompletionOptions`
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,

        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Uses mixin `StaticRegistrationOptions`
        /// The id used to register the request. The id can be used to deregister
        /// the request again. See also Registration#id.
        id: ?[]const u8 = null,
    };
};

/// Inline value information can be provided by different means:
/// - directly as a text value (class InlineValueText).
/// - as a name to use for a variable lookup (class InlineValueVariableLookup)
/// - as an evaluatable expression (class InlineValueEvaluatableExpression)
/// The InlineValue types combines all inline value types into one type.
///
/// @since 3.17.0
pub const InlineValue = union(enum) {
    inline_value_text: Text,
    inline_value_variable_lookup: VariableLookup,
    inline_value_evaluatable_expression: EvaluatableExpression,

    /// A parameter literal used in inline value requests.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `InlineValueParams`
    pub const Params = struct {
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The document range for which inline values should be computed.
        range: Range,
        /// Additional information about the context in which inline values were
        /// requested.
        context: Context,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,
    };

    /// Provide inline value as text.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `InlineValueText`
    pub const Text = struct {
        /// The document range for which the inline value applies.
        range: Range,
        /// The text of the inline value.
        text: []const u8,
    };

    /// Provide inline value through a variable lookup.
    /// If only a range is specified, the variable name will be extracted from the underlying document.
    /// An optional variable name can be used to override the extracted name.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `InlineValueVariableLookup`
    pub const VariableLookup = struct {
        /// The document range for which the inline value applies.
        /// The range is used to extract the variable name from the underlying document.
        range: Range,
        /// If specified the name of the variable to look up.
        variableName: ?[]const u8 = null,
        /// How to perform the lookup.
        caseSensitiveLookup: bool,
    };

    /// Provide an inline value through an expression evaluation.
    /// If only a range is specified, the expression will be extracted from the underlying document.
    /// An optional expression can be used to override the extracted expression.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `InlineValueEvaluatableExpression`
    pub const EvaluatableExpression = struct {
        /// The document range for which the inline value applies.
        /// The range is used to extract the evaluatable expression from the underlying document.
        range: Range,
        /// If specified the expression overrides the extracted expression.
        expression: ?[]const u8 = null,
    };

    /// @since 3.17.0
    ///
    /// LSP Specification name: `InlineValueContext`
    pub const Context = struct {
        /// The stack frame (as a DAP Id) where the execution has stopped.
        frameId: i32,
        /// The document range where execution has stopped.
        /// Typically the end position of the range denotes the line where the inline values are shown.
        stoppedLocation: Range,
    };

    /// Inline value options used during static registration.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `InlineValueOptions`
    pub const Options = struct {
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// Inline value options used during static or dynamic registration.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `InlineValueRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `InlineValueOptions`
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,

        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Uses mixin `StaticRegistrationOptions`
        /// The id used to register the request. The id can be used to deregister
        /// the request again. See also Registration#id.
        id: ?[]const u8 = null,
    };

    pub const jsonParse = parser.UnionParser(@This()).jsonParse;
    pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
    pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
};

pub const linked_editing_range = struct {
    /// LSP Specification name: `LinkedEditingRangeParams`
    pub const Params = struct {
        // Extends `TextDocumentPositionParams`
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The position inside the text document.
        position: Position,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,
    };

    /// LSP Specification name: `LinkedEditingRangeOptions`
    pub const Options = struct {
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// LSP Specification name: `LinkedEditingRangeRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `LinkedEditingRangeOptions`
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,

        // Uses mixin `StaticRegistrationOptions`
        /// The id used to register the request. The id can be used to deregister
        /// the request again. See also Registration#id.
        id: ?[]const u8 = null,
    };

    /// The result of a linked editing range request.
    ///
    /// @since 3.16.0
    ///
    /// LSP Specification name: `LinkedEditingRanges`
    pub const Ranges = struct {
        /// A list of ranges that can be edited together. The ranges must have
        /// identical length and contain identical text content. The ranges cannot overlap.
        ranges: []const Range,
        /// An optional word pattern (regular expression) that describes valid contents for
        /// the given ranges. If no pattern is provided, the client configuration's word
        /// pattern will be used.
        wordPattern: ?[]const u8 = null,
    };
};

/// Moniker definition to match LSIF 0.5 moniker definition.
///
/// @since 3.16.0
pub const Moniker = struct {
    /// The scheme of the moniker. For example tsc or .Net
    scheme: []const u8,
    /// The identifier of the moniker. The value is opaque in LSIF however
    /// schema owners are allowed to define the structure if they want.
    identifier: []const u8,
    /// The scope in which the moniker is unique
    unique: UniquenessLevel,
    /// The moniker kind if known.
    kind: ?Kind = null,

    /// LSP Specification name: `MonikerParams`
    pub const Params = struct {
        // Extends `TextDocumentPositionParams`
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The position inside the text document.
        position: Position,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    /// The moniker kind.
    ///
    /// @since 3.16.0
    ///
    /// LSP Specification name: `MonikerKind`
    pub const Kind = union(enum) {
        /// The moniker represent a symbol that is imported into a project
        import,
        /// The moniker represents a symbol that is exported from a project
        @"export",
        /// The moniker represents a symbol that is local to a project (e.g. a local
        /// variable of a function, a class not visible outside the project, ...)
        local,
        unknown_value: []const u8,

        pub const eql = parser.EnumCustomStringValues(@This(), false).eql;
        pub const jsonParse = parser.EnumCustomStringValues(@This(), false).jsonParse;
        pub const jsonParseFromValue = parser.EnumCustomStringValues(@This(), false).jsonParseFromValue;
        pub const jsonStringify = parser.EnumCustomStringValues(@This(), false).jsonStringify;
    };

    /// LSP Specification name: `MonikerOptions`
    pub const Options = struct {
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// LSP Specification name: `MonikerRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `MonikerOptions`
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// Moniker uniqueness level to define scope of the moniker.
    ///
    /// @since 3.16.0
    pub const UniquenessLevel = union(enum) {
        /// The moniker is only unique inside a document
        document,
        /// The moniker is unique inside a project for which a dump got created
        project,
        /// The moniker is unique inside the group to which a project belongs
        group,
        /// The moniker is unique inside the moniker scheme.
        scheme,
        /// The moniker is globally unique
        global,
        unknown_value: []const u8,

        pub const eql = parser.EnumCustomStringValues(@This(), false).eql;
        pub const jsonParse = parser.EnumCustomStringValues(@This(), false).jsonParse;
        pub const jsonParseFromValue = parser.EnumCustomStringValues(@This(), false).jsonParseFromValue;
        pub const jsonStringify = parser.EnumCustomStringValues(@This(), false).jsonStringify;
    };
};

/// A selection range represents a part of a selection hierarchy. A selection range
/// may have a parent selection range that contains it.
pub const SelectionRange = struct {
    /// The {@link Range range} of this selection range.
    range: Range,
    /// The parent selection range containing this range. Therefore `parent.range` must contain `this.range`.
    parent: ?*const SelectionRange = null,

    /// LSP Specification name: `SelectionRangeOptions`
    pub const Options = struct {
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// A parameter literal used in selection range requests.
    ///
    /// LSP Specification name: `SelectionRangeParams`
    pub const Params = struct {
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The positions inside the text document.
        positions: []const Position,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    /// LSP Specification name: `SelectionRangeRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `SelectionRangeOptions`
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,

        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Uses mixin `StaticRegistrationOptions`
        /// The id used to register the request. The id can be used to deregister
        /// the request again. See also Registration#id.
        id: ?[]const u8 = null,
    };
};

pub const semantic_tokens = struct {
    /// @since 3.16.0
    ///
    /// LSP Specification name: `SemanticTokensParams`
    pub const Params = struct {
        /// The text document.
        textDocument: TextDocument.Identifier,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,

        /// @since 3.16.0
        ///
        /// LSP Specification name: `SemanticTokensDeltaParams`
        pub const FullDelta = struct {
            /// The text document.
            textDocument: TextDocument.Identifier,
            /// The result id of a previous response. The result Id can either point to a full response
            /// or a delta response depending on what was received last.
            previousResultId: []const u8,

            // Uses mixin `WorkDoneProgressParams`
            /// An optional token that a server can use to report work done progress.
            workDoneToken: ?ProgressToken = null,

            // Uses mixin `PartialResultParams`
            /// An optional token that a server can use to report partial results (e.g. streaming) to
            /// the client.
            partialResultToken: ?ProgressToken = null,
        };

        /// @since 3.16.0
        ///
        /// LSP Specification name: `SemanticTokensRangeParams`
        pub const Range = struct {
            /// The text document.
            textDocument: TextDocument.Identifier,
            /// The range the semantic tokens are requested for.
            range: types.Range,

            // Uses mixin `WorkDoneProgressParams`
            /// An optional token that a server can use to report work done progress.
            workDoneToken: ?ProgressToken = null,

            // Uses mixin `PartialResultParams`
            /// An optional token that a server can use to report partial results (e.g. streaming) to
            /// the client.
            partialResultToken: ?ProgressToken = null,
        };
    };

    /// @since 3.16.0
    ///
    /// LSP Specification name: `SemanticTokens`
    pub const Result = struct {
        /// An optional result id. If provided and clients support delta updating
        /// the client will include the result id in the next semantic token request.
        /// A server can then instead of computing all semantic tokens again simply
        /// send a delta.
        resultId: ?[]const u8 = null,
        /// The actual tokens.
        data: []const u32,

        /// @since 3.16.0
        ///
        /// LSP Specification name: `SemanticTokensDelta`
        pub const Delta = struct {
            resultId: ?[]const u8 = null,
            /// The semantic token edits to transform a previous result into a new result.
            edits: []const Edit,

            /// @since 3.16.0
            ///
            /// LSP Specification name: `SemanticTokensDeltaPartialResult`
            pub const Partial = struct {
                edits: []const Edit,
            };
        };

        /// @since 3.16.0
        ///
        /// LSP Specification name: `SemanticTokensPartialResult`
        pub const Partial = struct {
            data: []const u32,
        };

        pub const FullDelta = union(enum) {
            semantic_tokens: Result,
            semantic_tokens_delta: Delta,

            pub const Partial = union(enum) {
                semantic_tokens_partial_result: Result.Partial,
                semantic_tokens_delta_partial_result: Delta.Partial,

                pub const jsonParse = parser.UnionParser(@This()).jsonParse;
                pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
                pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
            };

            pub const jsonParse = parser.UnionParser(@This()).jsonParse;
            pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
            pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
        };
    };

    /// A set of predefined token types. This set is not fixed
    /// an clients can specify additional token types via the
    /// corresponding client capabilities.
    ///
    /// @since 3.16.0
    ///
    /// LSP Specification name: `SemanticTokenTypes`
    pub const Type = union(enum) {
        namespace,
        /// Represents a generic type. Acts as a fallback for types which can't be mapped to
        /// a specific type like class or enum.
        type,
        class,
        @"enum",
        interface,
        @"struct",
        typeParameter,
        parameter,
        variable,
        property,
        enumMember,
        event,
        function,
        method,
        macro,
        keyword,
        modifier,
        comment,
        string,
        number,
        regexp,
        operator,
        /// @since 3.17.0
        decorator,
        /// @since 3.18.0
        label,
        custom_value: []const u8,

        pub const eql = parser.EnumCustomStringValues(@This(), false).eql;
        pub const jsonParse = parser.EnumCustomStringValues(@This(), false).jsonParse;
        pub const jsonParseFromValue = parser.EnumCustomStringValues(@This(), false).jsonParseFromValue;
        pub const jsonStringify = parser.EnumCustomStringValues(@This(), false).jsonStringify;
    };

    /// A set of predefined token modifiers. This set is not fixed
    /// an clients can specify additional token types via the
    /// corresponding client capabilities.
    ///
    /// @since 3.16.0
    ///
    /// LSP Specification name: `SemanticTokenModifiers`
    pub const Modifier = union(enum) {
        declaration,
        definition,
        readonly,
        static,
        deprecated,
        abstract,
        async,
        modification,
        documentation,
        defaultLibrary,
        custom_value: []const u8,

        pub const eql = parser.EnumCustomStringValues(@This(), false).eql;
        pub const jsonParse = parser.EnumCustomStringValues(@This(), false).jsonParse;
        pub const jsonParseFromValue = parser.EnumCustomStringValues(@This(), false).jsonParseFromValue;
        pub const jsonStringify = parser.EnumCustomStringValues(@This(), false).jsonStringify;
    };

    /// @since 3.16.0
    ///
    /// LSP Specification name: `SemanticTokensEdit`
    pub const Edit = struct {
        /// The start offset of the edit.
        start: u32,
        /// The count of elements to remove.
        deleteCount: u32,
        /// The elements to insert.
        data: ?[]const u32 = null,
    };

    /// @since 3.16.0
    ///
    /// LSP Specification name: `SemanticTokensOptions`
    pub const Options = struct {
        /// The legend used by the server
        legend: Legend,
        /// Server supports providing semantic tokens for a specific range
        /// of a document.
        range: ?union(enum) {
            bool: bool,
            literal_1: struct {},

            pub const jsonParse = parser.UnionParser(@This()).jsonParse;
            pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
            pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
        } = null,
        /// Server supports providing semantic tokens for a full document.
        full: ?union(enum) {
            bool: bool,
            semantic_tokens_full_delta: FullDelta,

            pub const jsonParse = parser.UnionParser(@This()).jsonParse;
            pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
            pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
        } = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,

        /// @since 3.16.0
        ///
        /// LSP Specification name: `SemanticTokensLegend`
        pub const Legend = struct {
            /// The token types a server uses.
            tokenTypes: []const []const u8,
            /// The token modifiers a server uses.
            tokenModifiers: []const []const u8,
        };

        /// Semantic tokens options to support deltas for full documents
        ///
        /// @since 3.18.0
        ///
        /// LSP Specification name: `SemanticTokensFullDelta`
        pub const FullDelta = struct {
            /// The server supports deltas for full documents.
            delta: ?bool = null,
        };
    };

    /// @since 3.16.0
    ///
    /// LSP Specification name: `SemanticTokensRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `SemanticTokensOptions`
        /// The legend used by the server
        legend: Options.Legend,
        /// Server supports providing semantic tokens for a specific range
        /// of a document.
        range: ?union(enum) {
            bool: bool,
            literal_1: struct {},

            pub const jsonParse = parser.UnionParser(@This()).jsonParse;
            pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
            pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
        } = null,
        /// Server supports providing semantic tokens for a full document.
        full: ?union(enum) {
            bool: bool,
            semantic_tokens_full_delta: Options.FullDelta,

            pub const jsonParse = parser.UnionParser(@This()).jsonParse;
            pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
            pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
        } = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,

        // Uses mixin `StaticRegistrationOptions`
        /// The id used to register the request. The id can be used to deregister
        /// the request again. See also Registration#id.
        id: ?[]const u8 = null,
    };
};

/// Signature help represents the signature of something
/// callable. There can be multiple signature but only one
/// active and only one active parameter.
pub const SignatureHelp = struct {
    /// One or more signatures.
    signatures: []const Signature,
    /// The active signature. If omitted or the value lies outside the
    /// range of `signatures` the value defaults to zero or is ignored if
    /// the `SignatureHelp` has no signatures.
    ///
    /// Whenever possible implementors should make an active decision about
    /// the active signature and shouldn't rely on a default value.
    ///
    /// In future version of the protocol this property might become
    /// mandatory to better express this.
    activeSignature: ?u32 = null,
    /// The active parameter of the active signature.
    ///
    /// If `null`, no parameter of the signature is active (for example a named
    /// argument that does not match any declared parameters). This is only valid
    /// if the client specifies the client capability
    /// `textDocument.signatureHelp.noActiveParameterSupport === true`
    ///
    /// If omitted or the value lies outside the range of
    /// `signatures[activeSignature].parameters` defaults to 0 if the active
    /// signature has parameters.
    ///
    /// If the active signature has no parameters it is ignored.
    ///
    /// In future version of the protocol this property might become
    /// mandatory (but still nullable) to better express the active parameter if
    /// the active signature does have any.
    activeParameter: ?u32 = null,

    /// Additional information about the context in which a signature help request was triggered.
    ///
    /// @since 3.15.0
    ///
    /// LSP Specification name: `SignatureHelpContext`
    pub const Context = struct {
        /// Action that caused signature help to be triggered.
        triggerKind: TriggerKind,
        /// Character that caused signature help to be triggered.
        ///
        /// This is undefined when `triggerKind !== SignatureHelpTriggerKind.TriggerCharacter`
        triggerCharacter: ?[]const u8 = null,
        /// `true` if signature help was already showing when it was triggered.
        ///
        /// Retriggers occurs when the signature help is already active and can be caused by actions such as
        /// typing a trigger character, a cursor move, or document content changes.
        isRetrigger: bool,
        /// The currently active `SignatureHelp`.
        ///
        /// The `activeSignatureHelp` has its `SignatureHelp.activeSignature` field updated based on
        /// the user navigating through available signatures.
        activeSignatureHelp: ?SignatureHelp = null,
    };

    /// Server Capabilities for a {@link SignatureHelpRequest}.
    ///
    /// LSP Specification name: `SignatureHelpOptions`
    pub const Options = struct {
        /// List of characters that trigger signature help automatically.
        triggerCharacters: ?[]const []const u8 = null,
        /// List of characters that re-trigger signature help.
        ///
        /// These trigger characters are only active when signature help is already showing. All trigger characters
        /// are also counted as re-trigger characters.
        ///
        /// @since 3.15.0
        retriggerCharacters: ?[]const []const u8 = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// Parameters for a {@link SignatureHelpRequest}.
    ///
    /// LSP Specification name: `SignatureHelpParams`
    pub const Params = struct {
        /// The signature help context. This is only available if the client specifies
        /// to send this using the client capability `textDocument.signatureHelp.contextSupport === true`
        ///
        /// @since 3.15.0
        context: ?Context = null,

        // Extends `TextDocumentPositionParams`
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The position inside the text document.
        position: Position,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,
    };

    /// Registration options for a {@link SignatureHelpRequest}.
    ///
    /// LSP Specification name: `SignatureHelpRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `SignatureHelpOptions`
        /// List of characters that trigger signature help automatically.
        triggerCharacters: ?[]const []const u8 = null,
        /// List of characters that re-trigger signature help.
        ///
        /// These trigger characters are only active when signature help is already showing. All trigger characters
        /// are also counted as re-trigger characters.
        ///
        /// @since 3.15.0
        retriggerCharacters: ?[]const []const u8 = null,

        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// How a signature help was triggered.
    ///
    /// @since 3.15.0
    ///
    /// LSP Specification name: `SignatureHelpTriggerKind`
    pub const TriggerKind = enum(u32) {
        /// Signature help was invoked manually by the user or by a command.
        Invoked = 1,
        /// Signature help was triggered by a trigger character.
        TriggerCharacter = 2,
        /// Signature help was triggered by the cursor moving or by the document content changing.
        ContentChange = 3,
        /// Unknown Value
        _,

        pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
    };

    /// Represents the signature of something callable. A signature
    /// can have a label, like a function-name, a doc-comment, and
    /// a set of parameters.
    ///
    /// LSP Specification name: `SignatureInformation`
    pub const Signature = struct {
        /// The label of this signature. Will be shown in
        /// the UI.
        label: []const u8,
        /// The human-readable doc-comment of this signature. Will be shown
        /// in the UI but can be omitted.
        documentation: ?Documentation = null,
        /// The parameters of this signature.
        parameters: ?[]const Parameter = null,
        /// The index of the active parameter.
        ///
        /// If `null`, no parameter of the signature is active (for example a named
        /// argument that does not match any declared parameters). This is only valid
        /// if the client specifies the client capability
        /// `textDocument.signatureHelp.noActiveParameterSupport === true`
        ///
        /// If provided (or `null`), this is used in place of
        /// `SignatureHelp.activeParameter`.
        ///
        /// @since 3.16.0
        activeParameter: ?u32 = null,

        /// Represents a parameter of a callable-signature. A parameter can
        /// have a label and a doc-comment.
        ///
        /// LSP Specification name: `ParameterInformation`
        pub const Parameter = struct {
            /// The label of this parameter information.
            ///
            /// Either a string or an inclusive start and exclusive end offsets within its containing
            /// signature label. (see SignatureInformation.label). The offsets are based on a UTF-16
            /// string representation as `Position` and `Range` does.
            ///
            /// To avoid ambiguities a server should use the [start, end] offset value instead of using
            /// a substring. Whether a client support this is controlled via `labelOffsetSupport` client
            /// capability.
            ///
            /// *Note*: a label of type string should be a substring of its containing signature label.
            /// Its intended use case is to highlight the parameter label part in the `SignatureInformation.label`.
            label: Label,
            /// The human-readable doc-comment of this parameter. Will be shown
            /// in the UI but can be omitted.
            documentation: ?Documentation = null,

            /// The label of this parameter information.
            ///
            /// Either a string or an inclusive start and exclusive end offsets within its containing
            /// signature label. (see SignatureInformation.label). The offsets are based on a UTF-16
            /// string representation as `Position` and `Range` does.
            ///
            /// To avoid ambiguities a server should use the [start, end] offset value instead of using
            /// a substring. Whether a client support this is controlled via `labelOffsetSupport` client
            /// capability.
            ///
            /// *Note*: a label of type string should be a substring of its containing signature label.
            /// Its intended use case is to highlight the parameter label part in the `SignatureInformation.label`.
            pub const Label = union(enum) {
                string: []const u8,
                tuple_1: struct { u32, u32 },

                pub const jsonParse = parser.UnionParser(@This()).jsonParse;
                pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
                pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
            };
        };
    };
};

pub const type_hierarchy = struct {
    /// @since 3.17.0
    ///
    /// LSP Specification name: `TypeHierarchyItem`
    pub const Item = struct {
        /// The name of this item.
        name: []const u8,
        /// The kind of this item.
        kind: SymbolKind,
        /// Tags for this item.
        tags: ?[]const SymbolTag = null,
        /// More detail for this item, e.g. the signature of a function.
        detail: ?[]const u8 = null,
        /// The resource identifier of this item.
        uri: DocumentUri,
        /// The range enclosing this symbol not including leading/trailing whitespace
        /// but everything else, e.g. comments and code.
        range: Range,
        /// The range that should be selected and revealed when this symbol is being
        /// picked, e.g. the name of a function. Must be contained by the
        /// {@link TypeHierarchyItem.range `range`}.
        selectionRange: Range,
        /// A data entry field that is preserved between a type hierarchy prepare and
        /// supertypes or subtypes requests. It could also be used to identify the
        /// type hierarchy in the server, helping improve the performance on
        /// resolving supertypes and subtypes.
        data: ?LSPAny = null,
    };

    /// Type hierarchy options used during static registration.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `TypeHierarchyOptions`
    pub const Options = struct {
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,
    };

    /// The parameter of a `textDocument/prepareTypeHierarchy` request.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `TypeHierarchyPrepareParams`
    pub const PrepareParams = struct {
        // Extends `TextDocumentPositionParams`
        /// The text document.
        textDocument: TextDocument.Identifier,
        /// The position inside the text document.
        position: Position,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,
    };

    /// Type hierarchy options used during static or dynamic registration.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `TypeHierarchyRegistrationOptions`
    pub const RegistrationOptions = struct {
        // Extends `TextDocumentRegistrationOptions`
        /// A document selector to identify the scope of the registration. If set to null
        /// the document selector provided on the client side will be used.
        documentSelector: ?DocumentSelector = null,

        // Extends `TypeHierarchyOptions`
        // Uses mixin `WorkDoneProgressOptions`
        workDoneProgress: ?bool = null,

        // Uses mixin `StaticRegistrationOptions`
        /// The id used to register the request. The id can be used to deregister
        /// the request again. See also Registration#id.
        id: ?[]const u8 = null,
    };

    /// The parameter of a `typeHierarchy/subtypes` request.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `TypeHierarchySubtypesParams`
    pub const SubtypesParams = struct {
        item: Item,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };

    /// The parameter of a `typeHierarchy/supertypes` request.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `TypeHierarchySupertypesParams`
    pub const SupertypesParams = struct {
        item: Item,

        // Uses mixin `WorkDoneProgressParams`
        /// An optional token that a server can use to report work done progress.
        workDoneToken: ?ProgressToken = null,

        // Uses mixin `PartialResultParams`
        /// An optional token that a server can use to report partial results (e.g. streaming) to
        /// the client.
        partialResultToken: ?ProgressToken = null,
    };
};

pub const workspace = struct {
    /// A special workspace symbol that supports locations without a range.
    ///
    /// See also SymbolInformation.
    ///
    /// @since 3.17.0
    ///
    /// LSP Specification name: `WorkspaceSymbol`
    pub const Symbol = struct {
        /// The location of the symbol. Whether a server is allowed to
        /// return a location without a range depends on the client
        /// capability `workspace.symbol.resolveSupport`.
        ///
        /// See SymbolInformation#location for more details.
        location: Symbol.Location,
        /// A data entry field that is preserved on a workspace symbol between a
        /// workspace symbol request and a workspace symbol resolve request.
        data: ?LSPAny = null,

        // Extends `BaseSymbolInformation`
        /// The name of this symbol.
        name: []const u8,
        /// The kind of this symbol.
        kind: SymbolKind,
        /// Tags for this symbol.
        ///
        /// @since 3.16.0
        tags: ?[]const SymbolTag = null,
        /// The name of the symbol containing this symbol. This information is for
        /// user interface purposes (e.g. to render a qualifier in the user interface
        /// if necessary). It can't be used to re-infer a hierarchy for the document
        /// symbols.
        containerName: ?[]const u8 = null,

        /// The parameters of a {@link WorkspaceSymbolRequest}.
        ///
        /// LSP Specification name: `WorkspaceSymbolParams`
        pub const Params = struct {
            /// A query string to filter symbols by. Clients may send an empty
            /// string here to request all symbols.
            ///
            /// The `query`-parameter should be interpreted in a *relaxed way* as editors
            /// will apply their own highlighting and scoring on the results. A good rule
            /// of thumb is to match case-insensitive and to simply check that the
            /// characters of *query* appear in their order in a candidate symbol.
            /// Servers shouldn't use prefix, substring, or similar strict matching.
            query: []const u8,

            // Uses mixin `WorkDoneProgressParams`
            /// An optional token that a server can use to report work done progress.
            workDoneToken: ?ProgressToken = null,

            // Uses mixin `PartialResultParams`
            /// An optional token that a server can use to report partial results (e.g. streaming) to
            /// the client.
            partialResultToken: ?ProgressToken = null,
        };

        pub const Result = union(enum) {
            symbol_informations: []const SymbolInformation,
            workspace_symbols: []const Symbol,

            pub const jsonParse = parser.UnionParser(@This()).jsonParse;
            pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
            pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
        };

        /// The location of the symbol. Whether a server is allowed to
        /// return a location without a range depends on the client
        /// capability `workspace.symbol.resolveSupport`.
        ///
        /// See SymbolInformation#location for more details.
        pub const Location = union(enum) {
            location: types.Location,
            location_uri_only: UriOnly,

            /// Location with only uri and does not include range.
            ///
            /// @since 3.18.0
            ///
            /// LSP Specification name: `LocationUriOnly`
            pub const UriOnly = struct {
                uri: DocumentUri,
            };

            pub const jsonParse = parser.UnionParser(@This()).jsonParse;
            pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
            pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
        };

        /// Server capabilities for a {@link WorkspaceSymbolRequest}.
        ///
        /// LSP Specification name: `WorkspaceSymbolOptions`
        pub const Options = struct {
            /// The server provides support to resolve additional
            /// information for a workspace symbol.
            ///
            /// @since 3.17.0
            resolveProvider: ?bool = null,

            // Uses mixin `WorkDoneProgressOptions`
            workDoneProgress: ?bool = null,
        };

        /// Registration options for a {@link WorkspaceSymbolRequest}.
        ///
        /// LSP Specification name: `WorkspaceSymbolRegistrationOptions`
        pub const RegistrationOptions = struct {
            // Extends `WorkspaceSymbolOptions`
            /// The server provides support to resolve additional
            /// information for a workspace symbol.
            ///
            /// @since 3.17.0
            resolveProvider: ?bool = null,

            // Uses mixin `WorkDoneProgressOptions`
            workDoneProgress: ?bool = null,
        };
    };

    pub const configuration = struct {
        /// The parameters of a configuration request.
        ///
        /// LSP Specification name: `ConfigurationParams`
        pub const Params = struct {
            items: []const Item,
        };

        /// LSP Specification name: `ConfigurationItem`
        pub const Item = struct {
            /// The scope to get the configuration section for.
            scopeUri: ?URI = null,
            /// The configuration section asked for.
            section: ?[]const u8 = null,
        };

        pub const did_change = struct {
            /// The parameters of a change configuration notification.
            ///
            /// LSP Specification name: `DidChangeConfigurationParams`
            pub const Params = struct {
                /// The actual changed settings
                settings: LSPAny,
            };

            /// LSP Specification name: `DidChangeConfigurationRegistrationOptions`
            pub const RegistrationOptions = struct {
                section: ?union(enum) {
                    string: []const u8,
                    strings: []const []const u8,

                    pub const jsonParse = parser.UnionParser(@This()).jsonParse;
                    pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
                    pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
                } = null,
            };
        };
    };

    /// A workspace folder inside a client.
    ///
    /// LSP Specification name: `WorkspaceFolder`
    pub const Folder = struct {
        /// The associated URI for this workspace folder.
        uri: URI,
        /// The name of the workspace folder. Used to refer to this
        /// workspace folder in the user interface.
        name: []const u8,
    };

    pub const folders = struct {
        /// The workspace folder change event.
        ///
        /// LSP Specification name: `WorkspaceFoldersChangeEvent`
        pub const ChangeEvent = struct {
            /// The array of added workspace folders
            added: []const Folder,
            /// The array of the removed workspace folders
            removed: []const Folder,
        };

        /// LSP Specification name: `WorkspaceFoldersInitializeParams`
        pub const InitializeParams = struct {
            /// The workspace folders configured in the client when the server starts.
            ///
            /// This property is only available if the client supports workspace folders.
            /// It can be `null` if the client supports workspace folders but none are
            /// configured.
            ///
            /// @since 3.6.0
            workspaceFolders: ?[]const Folder = null,
        };

        /// LSP Specification name: `WorkspaceFoldersServerCapabilities`
        pub const ServerCapabilities = struct {
            /// The server has support for workspace folders
            supported: ?bool = null,
            /// Whether the server wants to receive workspace folder
            /// change notifications.
            ///
            /// If a string is provided the string is treated as an ID
            /// under which the notification is registered on the client
            /// side. The ID can be used to unregister for these events
            /// using the `client/unregisterCapability` request.
            changeNotifications: ?union(enum) {
                string: []const u8,
                bool: bool,

                pub const jsonParse = parser.UnionParser(@This()).jsonParse;
                pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
                pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
            } = null,
        };

        /// The parameters of a `workspace/didChangeWorkspaceFolders` notification.
        ///
        /// LSP Specification name: `DidChangeWorkspaceFoldersParams`
        pub const DidChangeParams = struct {
            /// The actual workspace folder change event.
            event: ChangeEvent,
        };
    };

    pub const file_operation = struct {
        /// A filter to describe in which file operation requests or notifications
        /// the server is interested in receiving.
        ///
        /// @since 3.16.0
        ///
        /// LSP Specification name: `FileOperationFilter`
        pub const Filter = struct {
            /// A Uri scheme like `file` or `untitled`.
            scheme: ?[]const u8 = null,
            /// The actual file operation pattern.
            pattern: Filter.Pattern,

            /// A pattern to describe in which file operation requests or notifications
            /// the server is interested in receiving.
            ///
            /// @since 3.16.0
            ///
            /// LSP Specification name: `FileOperationPattern`
            pub const Pattern = struct {
                /// The glob pattern to match. Glob patterns can have the following syntax:
                /// - `*` to match zero or more characters in a path segment
                /// - `?` to match on one character in a path segment
                /// - `**` to match any number of path segments, including none
                /// - `{}` to group sub patterns into an OR expression. (e.g. `**​/*.{ts,js}` matches all TypeScript and JavaScript files)
                /// - `[]` to declare a range of characters to match in a path segment (e.g., `example.[0-9]` to match on `example.0`, `example.1`, …)
                /// - `[!...]` to negate a range of characters to match in a path segment (e.g., `example.[!0-9]` to match on `example.a`, `example.b`, but not `example.0`)
                glob: []const u8,
                /// Whether to match files or folders with this pattern.
                ///
                /// Matches both if undefined.
                matches: ?PatternKind = null,
                /// Additional options used during matching.
                options: ?PatternOptions = null,

                /// A pattern kind describing if a glob pattern matches a file a folder or
                /// both.
                ///
                /// @since 3.16.0
                ///
                /// LSP Specification name: `FileOperationPatternKind`
                pub const PatternKind = union(enum) {
                    /// The pattern matches a file only.
                    file,
                    /// The pattern matches a folder only.
                    folder,
                    unknown_value: []const u8,

                    pub const eql = parser.EnumCustomStringValues(@This(), false).eql;
                    pub const jsonParse = parser.EnumCustomStringValues(@This(), false).jsonParse;
                    pub const jsonParseFromValue = parser.EnumCustomStringValues(@This(), false).jsonParseFromValue;
                    pub const jsonStringify = parser.EnumCustomStringValues(@This(), false).jsonStringify;
                };

                /// Matching options for the file operation pattern.
                ///
                /// @since 3.16.0
                ///
                /// LSP Specification name: `FileOperationPatternOptions`
                pub const PatternOptions = struct {
                    /// The pattern should be matched ignoring casing.
                    ignoreCase: ?bool = null,
                };
            };
        };

        /// Options for notifications/requests for user operations on files.
        ///
        /// @since 3.16.0
        ///
        /// LSP Specification name: `FileOperationOptions`
        pub const Options = struct {
            /// The server is interested in receiving didCreateFiles notifications.
            didCreate: ?RegistrationOptions = null,
            /// The server is interested in receiving willCreateFiles requests.
            willCreate: ?RegistrationOptions = null,
            /// The server is interested in receiving didRenameFiles notifications.
            didRename: ?RegistrationOptions = null,
            /// The server is interested in receiving willRenameFiles requests.
            willRename: ?RegistrationOptions = null,
            /// The server is interested in receiving didDeleteFiles file notifications.
            didDelete: ?RegistrationOptions = null,
            /// The server is interested in receiving willDeleteFiles file requests.
            willDelete: ?RegistrationOptions = null,
        };

        /// The options to register for file operations.
        ///
        /// @since 3.16.0
        ///
        /// LSP Specification name: `FileOperationRegistrationOptions`
        pub const RegistrationOptions = struct {
            /// The actual filters.
            filters: []const Filter,
        };
    };

    /// The parameters sent in notifications/requests for user-initiated creation of
    /// files.
    ///
    /// @since 3.16.0
    pub const CreateFilesParams = struct {
        /// An array of all files/folders created in this operation.
        files: []const FileCreate,
    };

    /// Represents information on a file/folder create.
    ///
    /// @since 3.16.0
    pub const FileCreate = struct {
        /// A file:// URI for the location of the file/folder being created.
        uri: []const u8,
    };

    /// The parameters sent in notifications/requests for user-initiated renames of
    /// files.
    ///
    /// @since 3.16.0
    pub const RenameFilesParams = struct {
        /// An array of all files/folders renamed in this operation. When a folder is renamed, only
        /// the folder will be included, and not its children.
        files: []const FileRename,
    };

    /// Represents information on a file/folder rename.
    ///
    /// @since 3.16.0
    pub const FileRename = struct {
        /// A file:// URI for the original location of the file/folder being renamed.
        oldUri: []const u8,
        /// A file:// URI for the new location of the file/folder being renamed.
        newUri: []const u8,
    };

    /// The parameters sent in notifications/requests for user-initiated deletes of
    /// files.
    ///
    /// @since 3.16.0
    pub const DeleteFilesParams = struct {
        /// An array of all files/folders deleted in this operation.
        files: []const FileDelete,
    };

    /// Represents information on a file/folder delete.
    ///
    /// @since 3.16.0
    pub const FileDelete = struct {
        /// A file:// URI for the location of the file/folder being deleted.
        uri: []const u8,
    };

    pub const did_change_watched_files = struct {
        /// The watched files change notification's parameters.
        ///
        /// LSP Specification name: `DidChangeWatchedFilesParams`
        pub const Params = struct {
            /// The actual file events.
            changes: []const FileSystemWatcher.Event,
        };

        /// Describe options to be used when registered for text document change events.
        ///
        /// LSP Specification name: `DidChangeWatchedFilesRegistrationOptions`
        pub const RegistrationOptions = struct {
            /// The watchers to register.
            watchers: []const FileSystemWatcher,
        };
    };

    pub const FileSystemWatcher = struct {
        /// The glob pattern to watch. See {@link GlobPattern glob pattern} for more detail.
        ///
        /// @since 3.17.0 support for relative patterns.
        globPattern: GlobPattern,
        /// The kind of events of interest. If omitted it defaults
        /// to WatchKind.Create | WatchKind.Change | WatchKind.Delete
        /// which is 7.
        kind: ?Kind = null,

        /// An event describing a file change.
        ///
        /// LSP Specification name: `FileEvent`
        pub const Event = struct {
            /// The file's uri.
            uri: DocumentUri,
            /// The change type.
            type: ChangeType,
        };

        /// The file event type
        ///
        /// LSP Specification name: `FileChangeType`
        pub const ChangeType = enum(u32) {
            /// The file got created.
            Created = 1,
            /// The file got changed.
            Changed = 2,
            /// The file got deleted.
            Deleted = 3,
            /// Unknown Value
            _,

            pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
        };

        /// LSP Specification name: `WatchKind`
        pub const Kind = enum(u32) {
            /// Interested in create events.
            Create = 1,
            /// Interested in change events
            Change = 2,
            /// Interested in delete events
            Delete = 4,
            /// Custom Value
            _,

            pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
        };
    };

    pub const execute_command = struct {
        /// The parameters of a {@link ExecuteCommandRequest}.
        ///
        /// LSP Specification name: `ExecuteCommandParams`
        pub const Params = struct {
            /// The identifier of the actual command handler.
            command: []const u8,
            /// Arguments that the command should be invoked with.
            arguments: ?[]const LSPAny = null,

            // Uses mixin `WorkDoneProgressParams`
            /// An optional token that a server can use to report work done progress.
            workDoneToken: ?ProgressToken = null,
        };

        /// The server capabilities of a {@link ExecuteCommandRequest}.
        ///
        /// LSP Specification name: `ExecuteCommandOptions`
        pub const Options = struct {
            /// The commands to be executed on the server
            commands: []const []const u8,

            // Uses mixin `WorkDoneProgressOptions`
            workDoneProgress: ?bool = null,
        };

        /// Registration options for a {@link ExecuteCommandRequest}.
        ///
        /// LSP Specification name: `ExecuteCommandRegistrationOptions`
        pub const RegistrationOptions = struct {
            // Extends `ExecuteCommandOptions`
            /// The commands to be executed on the server
            commands: []const []const u8,

            // Uses mixin `WorkDoneProgressOptions`
            workDoneProgress: ?bool = null,
        };
    };

    pub const apply_workspace_edit = struct {
        /// The parameters passed via an apply workspace edit request.
        ///
        /// LSP Specification name: `ApplyWorkspaceEditParams`
        pub const Params = struct {
            /// An optional label of the workspace edit. This label is
            /// presented in the user interface for example on an undo
            /// stack to undo the workspace edit.
            label: ?[]const u8 = null,
            /// The edits to apply.
            edit: WorkspaceEdit,
            /// Additional data about the edit.
            ///
            /// @since 3.18.0
            /// @proposed
            metadata: ?WorkspaceEdit.Metadata = null,
        };

        /// The result returned from the apply workspace edit request.
        ///
        /// @since 3.17 renamed from ApplyWorkspaceEditResponse
        ///
        /// LSP Specification name: `ApplyWorkspaceEditResult`
        pub const Result = struct {
            /// Indicates whether the edit was applied or not.
            applied: bool,
            /// An optional textual description for why the edit was not applied.
            /// This may be used by the server for diagnostic logging or to provide
            /// a suitable error for a request that triggered the edit.
            failureReason: ?[]const u8 = null,
            /// Depending on the client's failure handling strategy `failedChange` might
            /// contain the index of the change that failed. This property is only available
            /// if the client signals a `failureHandlingStrategy` in its client capabilities.
            failedChange: ?u32 = null,
        };
    };

    pub const diagnostic = struct {
        /// Parameters of the workspace diagnostic request.
        ///
        /// @since 3.17.0
        ///
        /// LSP Specification name: `WorkspaceDiagnosticParams`
        pub const Params = struct {
            /// The additional identifier provided during registration.
            identifier: ?[]const u8 = null,
            /// The currently known diagnostic reports with their
            /// previous result ids.
            previousResultIds: []const PreviousResultId,

            // Uses mixin `WorkDoneProgressParams`
            /// An optional token that a server can use to report work done progress.
            workDoneToken: ?ProgressToken = null,

            // Uses mixin `PartialResultParams`
            /// An optional token that a server can use to report partial results (e.g. streaming) to
            /// the client.
            partialResultToken: ?ProgressToken = null,
        };

        /// A workspace diagnostic report.
        ///
        /// @since 3.17.0
        ///
        /// LSP Specification name: `WorkspaceDiagnosticReport`
        pub const Report = struct {
            items: []const Document,

            /// A partial result for a workspace diagnostic report.
            ///
            /// @since 3.17.0
            ///
            /// LSP Specification name: `WorkspaceDiagnosticReportPartialResult`
            pub const PartialResult = struct {
                items: []const Document,
            };

            /// A workspace diagnostic document report.
            ///
            /// @since 3.17.0
            ///
            /// LSP Specification name: `WorkspaceDocumentDiagnosticReport`
            pub const Document = union(enum) {
                workspace_full_document_diagnostic_report: Full,
                workspace_unchanged_document_diagnostic_report: Unchanged,

                /// A full document diagnostic report for a workspace diagnostic result.
                ///
                /// @since 3.17.0
                ///
                /// LSP Specification name: `WorkspaceFullDocumentDiagnosticReport`
                pub const Full = struct {
                    /// The URI for which diagnostic information is reported.
                    uri: DocumentUri,
                    /// The version number for which the diagnostics are reported.
                    /// If the document is not marked as open `null` can be provided.
                    version: ?i32 = null,

                    // Extends `FullDocumentDiagnosticReport`
                    /// A full document diagnostic report.
                    kind: []const u8 = "full",
                    /// An optional result id. If provided it will
                    /// be sent on the next diagnostic request for the
                    /// same document.
                    resultId: ?[]const u8 = null,
                    /// The actual items.
                    items: []const Diagnostic,
                };

                /// An unchanged document diagnostic report for a workspace diagnostic result.
                ///
                /// @since 3.17.0
                ///
                /// LSP Specification name: `WorkspaceUnchangedDocumentDiagnosticReport`
                pub const Unchanged = struct {
                    /// The URI for which diagnostic information is reported.
                    uri: DocumentUri,
                    /// The version number for which the diagnostics are reported.
                    /// If the document is not marked as open `null` can be provided.
                    version: ?i32 = null,

                    // Extends `UnchangedDocumentDiagnosticReport`
                    /// A document diagnostic report indicating
                    /// no changes to the last result. A server can
                    /// only return `unchanged` if result ids are
                    /// provided.
                    kind: []const u8 = "unchanged",
                    /// A result id which will be sent on the next
                    /// diagnostic request for the same document.
                    resultId: []const u8,
                };

                pub const jsonParse = parser.UnionParser(@This()).jsonParse;
                pub const jsonParseFromValue = parser.UnionParser(@This()).jsonParseFromValue;
                pub const jsonStringify = parser.UnionParser(@This()).jsonStringify;
            };
        };
    };

    pub const text_document_content = struct {
        /// Parameters for the `workspace/textDocumentContent` request.
        ///
        /// @since 3.18.0
        /// @proposed
        ///
        /// LSP Specification name: `TextDocumentContentParams`
        pub const Params = struct {
            /// The uri of the text document.
            uri: DocumentUri,
        };

        /// @since 3.18.0
        ///
        /// LSP Specification name: `TextDocumentContentChangePartial`
        pub const ChangePartial = struct {
            /// The range of the document that changed.
            range: Range,
            /// The optional length of the range that got replaced.
            ///
            /// @deprecated use range instead.
            rangeLength: ?u32 = null,
            /// The new text for the provided range.
            text: []const u8,
        };

        /// @since 3.18.0
        ///
        /// LSP Specification name: `TextDocumentContentChangeWholeDocument`
        pub const ChangeWholeDocument = struct {
            /// The new text of the whole document.
            text: []const u8,
        };

        /// Text document content provider options.
        ///
        /// @since 3.18.0
        /// @proposed
        ///
        /// LSP Specification name: `TextDocumentContentOptions`
        pub const Options = struct {
            /// The schemes for which the server provides content.
            schemes: []const []const u8,
        };

        /// Parameters for the `workspace/textDocumentContent/refresh` request.
        ///
        /// @since 3.18.0
        /// @proposed
        ///
        /// LSP Specification name: `TextDocumentContentRefreshParams`
        pub const RefreshParams = struct {
            /// The uri of the text document to refresh.
            uri: DocumentUri,
        };

        /// Text document content provider registration options.
        ///
        /// @since 3.18.0
        /// @proposed
        ///
        /// LSP Specification name: `TextDocumentContentRegistrationOptions`
        pub const RegistrationOptions = struct {
            // Extends `TextDocumentContentOptions`
            /// The schemes for which the server provides content.
            schemes: []const []const u8,

            // Uses mixin `StaticRegistrationOptions`
            /// The id used to register the request. The id can be used to deregister
            /// the request again. See also Registration#id.
            id: ?[]const u8 = null,
        };

        /// Result of the `workspace/textDocumentContent` request.
        ///
        /// @since 3.18.0
        /// @proposed
        ///
        /// LSP Specification name: `TextDocumentContentResult`
        pub const Result = struct {
            /// The text content of the text document. Please note, that the content of
            /// any subsequent open notifications for the text document might differ
            /// from the returned content due to whitespace and line ending
            /// normalizations done on the client
            text: []const u8,
        };
    };
};

pub const window = struct {
    /// The message type
    pub const MessageType = enum(u32) {
        /// An error message.
        Error = 1,
        /// A warning message.
        Warning = 2,
        /// An information message.
        Info = 3,
        /// A log message.
        Log = 4,
        /// A debug message.
        ///
        /// @since 3.18.0
        /// @proposed
        Debug = 5,
        /// Unknown Value
        _,

        pub const jsonStringify = parser.EnumStringifyAsInt(@This()).jsonStringify;
    };

    /// The parameters of a notification message.
    pub const ShowMessageParams = struct {
        /// The message type. See {@link MessageType}
        type: MessageType,
        /// The actual message.
        message: []const u8,
    };

    pub const show_message_request = struct {
        /// LSP Specification name: `ShowMessageRequestParams`
        pub const Params = struct {
            /// The message type. See {@link MessageType}
            type: MessageType,
            /// The actual message.
            message: []const u8,
            /// The message action items to present.
            actions: ?[]const Item = null,
        };

        /// LSP Specification name: `MessageActionItem`
        pub const Item = struct {
            /// A short title like 'Retry', 'Open Log' etc.
            title: []const u8,
        };
    };

    pub const show_document = struct {
        /// Params to show a resource in the UI.
        ///
        /// @since 3.16.0
        ///
        /// LSP Specification name: `ShowDocumentParams`
        pub const Params = struct {
            /// The uri to show.
            uri: URI,
            /// Indicates to show the resource in an external program.
            /// To show, for example, `https://code.visualstudio.com/`
            /// in the default WEB browser set `external` to `true`.
            external: ?bool = null,
            /// An optional property to indicate whether the editor
            /// showing the document should take focus or not.
            /// Clients might ignore this property if an external
            /// program is started.
            takeFocus: ?bool = null,
            /// An optional selection range if the document is a text
            /// document. Clients might ignore the property if an
            /// external program is started or the file is not a text
            /// file.
            selection: ?Range = null,
        };

        /// The result of a showDocument request.
        ///
        /// @since 3.16.0
        ///
        /// LSP Specification name: `ShowDocumentResult`
        pub const Result = struct {
            /// A boolean indicating if the show was successful.
            success: bool,
        };
    };

    /// The log message parameters.
    pub const LogMessageParams = struct {
        /// The message type. See {@link MessageType}
        type: MessageType,
        /// The actual message.
        message: []const u8,
    };

    pub const work_done_progress = struct {
        /// LSP Specification name: `WorkDoneProgressBegin`
        pub const Begin = struct {
            kind: []const u8 = "begin",
            /// Mandatory title of the progress operation. Used to briefly inform about
            /// the kind of operation being performed.
            ///
            /// Examples: "Indexing" or "Linking dependencies".
            title: []const u8,
            /// Controls if a cancel button should show to allow the user to cancel the
            /// long running operation. Clients that don't support cancellation are allowed
            /// to ignore the setting.
            cancellable: ?bool = null,
            /// Optional, more detailed associated progress message. Contains
            /// complementary information to the `title`.
            ///
            /// Examples: "3/25 files", "project/src/module2", "node_modules/some_dep".
            /// If unset, the previous progress message (if any) is still valid.
            message: ?[]const u8 = null,
            /// Optional progress percentage to display (value 100 is considered 100%).
            /// If not provided infinite progress is assumed and clients are allowed
            /// to ignore the `percentage` value in subsequent in report notifications.
            ///
            /// The value should be steadily rising. Clients are free to ignore values
            /// that are not following this rule. The value range is [0, 100].
            percentage: ?u32 = null,
        };

        /// LSP Specification name: `WorkDoneProgressReport`
        pub const Report = struct {
            kind: []const u8 = "report",
            /// Controls enablement state of a cancel button.
            ///
            /// Clients that don't support cancellation or don't support controlling the button's
            /// enablement state are allowed to ignore the property.
            cancellable: ?bool = null,
            /// Optional, more detailed associated progress message. Contains
            /// complementary information to the `title`.
            ///
            /// Examples: "3/25 files", "project/src/module2", "node_modules/some_dep".
            /// If unset, the previous progress message (if any) is still valid.
            message: ?[]const u8 = null,
            /// Optional progress percentage to display (value 100 is considered 100%).
            /// If not provided infinite progress is assumed and clients are allowed
            /// to ignore the `percentage` value in subsequent in report notifications.
            ///
            /// The value should be steadily rising. Clients are free to ignore values
            /// that are not following this rule. The value range is [0, 100]
            percentage: ?u32 = null,
        };

        /// LSP Specification name: `WorkDoneProgressEnd`
        pub const End = struct {
            kind: []const u8 = "end",
            /// Optional, a final message indicating to for example indicate the outcome
            /// of the operation.
            message: ?[]const u8 = null,
        };

        /// LSP Specification name: `WorkDoneProgressParams`
        pub const Params = struct {
            /// An optional token that a server can use to report work done progress.
            workDoneToken: ?ProgressToken = null,
        };

        /// LSP Specification name: `WorkDoneProgressOptions`
        pub const Options = struct {
            workDoneProgress: ?bool = null,
        };

        /// LSP Specification name: `WorkDoneProgressCreateParams`
        pub const CreateParams = struct {
            /// The token to be used to report progress.
            token: ProgressToken,
        };

        /// LSP Specification name: `WorkDoneProgressCancelParams`
        pub const CancelParams = struct {
            /// The token to be used to report progress.
            token: ProgressToken,
        };
    };
};

/// A flat namespace that aliases all LSP types under their original name from the official specification.
pub const flat = struct {
    pub const parser = types.parser;
    pub const URI = types.URI;
    pub const DocumentUri = types.DocumentUri;
    pub const RegExp = types.RegExp;
    pub const LSPAny = types.LSPAny;
    pub const LSPArray = types.LSPArray;
    pub const LSPObject = types.LSPObject;
    pub const ID = types.ID;
    pub const MessageDirection = types.MessageDirection;
    pub const RegistrationMetadata = types.RegistrationMetadata;
    pub const NotificationMetadata = types.NotificationMetadata;
    pub const RequestMetadata = types.RequestMetadata;
    pub const requests = types.requests;
    pub const notifications = types.notifications;

    pub const Color = types.Color;
    pub const Hover = types.Hover;
    pub const Range = types.Range;
    pub const Command = types.Command;
    pub const Moniker = types.Moniker;
    pub const Pattern = types.Pattern;
    pub const CodeLens = types.code_lens.Response;
    pub const Position = types.Position;
    pub const TextEdit = types.TextEdit;
    pub const Location = types.Location;
    pub const InlayHint = types.InlayHint;
    pub const FileEvent = types.workspace.FileSystemWatcher.Event;
    pub const WatchKind = types.workspace.FileSystemWatcher.Kind;
    pub const ApplyKind = types.ClientCapabilities.TextDocument.Completion.ApplyKind;
    pub const SymbolTag = types.SymbolTag;
    pub const Diagnostic = types.Diagnostic;
    pub const CreateFile = types.WorkspaceEdit.CreateFile;
    pub const RenameFile = types.WorkspaceEdit.RenameFile;
    pub const MarkupKind = types.MarkupKind;
    pub const DeleteFile = types.WorkspaceEdit.DeleteFile;
    pub const Definition = types.Definition;
    pub const CodeAction = types.CodeAction;
    pub const FileDelete = types.workspace.FileDelete;
    pub const ServerInfo = types.ServerInfo;
    pub const ClientInfo = types.ClientInfo;
    pub const SymbolKind = types.SymbolKind;
    pub const FileCreate = types.workspace.FileCreate;
    pub const FileRename = types.workspace.FileRename;
    pub const TraceValue = types.trace.Value;
    pub const ErrorCodes = types.ErrorCodes;
    pub const MessageType = types.window.MessageType;
    pub const TokenFormat = types.ClientCapabilities.TextDocument.SemanticTokens.Format;
    pub const Declaration = types.Definition;
    pub const InlineValue = types.InlineValue;
    pub const SaveOptions = types.TextDocument.SyncSaveOptions;
    pub const StringValue = types.StringValue;
    pub const HoverParams = types.Hover.Params;
    pub const GlobPattern = types.GlobPattern;
    pub const MonikerKind = types.Moniker.Kind;
    pub const RenameParams = types.rename.Params;
    pub const LocationLink = types.LocationLink;
    pub const CancelParams = types.CancelParams;
    pub const HoverOptions = types.Hover.Options;
    pub const MarkedString = types.Hover.DeprecatedMarkedString;
    pub const NotebookCell = types.NotebookCell;
    pub const Registration = types.Registration;
    pub const DocumentLink = types.DocumentLink;
    pub const FoldingRange = types.FoldingRange;
    pub const LanguageKind = types.TextDocument.LanguageKind;
    pub const CodeActionTag = types.CodeAction.Tag;
    pub const MarkupContent = types.MarkupContent;
    pub const WorkspaceEdit = types.WorkspaceEdit;
    pub const LSPErrorCodes = types.LSPErrorCodes;
    pub const MonikerParams = types.Moniker.Params;
    pub const SignatureHelp = types.SignatureHelp;
    pub const RenameOptions = types.rename.Options;
    pub const InlayHintKind = types.InlayHint.Kind;
    pub const DiagnosticTag = types.Diagnostic.Tag;
    pub const ProgressToken = types.ProgressToken;
    pub const DocumentFilter = types.DocumentFilter;
    pub const MonikerOptions = types.Moniker.Options;
    pub const SelectionRange = types.SelectionRange;
    pub const Unregistration = types.Unregistration;
    pub const DocumentSymbol = types.DocumentSymbol;
    pub const SetTraceParams = types.trace.SetParams;
    pub const FileChangeType = types.workspace.FileSystemWatcher.ChangeType;
    pub const CompletionItem = types.completion.Item;
    pub const SemanticTokens = types.semantic_tokens.Result;
    pub const InsertTextMode = types.InsertTextMode;
    pub const CodeActionKind = types.CodeAction.Kind;
    pub const CodeLensParams = types.code_lens.Params;
    pub const LogTraceParams = types.trace.LogParams;
    pub const ProgressParams = types.ProgressParams;
    pub const DefinitionLink = types.Definition.Link;
    pub const CompletionList = types.completion.List;
    pub const InlineValueText = types.InlineValue.Text;
    pub const UniquenessLevel = types.Moniker.UniquenessLevel;
    pub const CodeLensOptions = types.code_lens.Options;
    pub const ReferenceParams = types.reference.Params;
    pub const InlayHintParams = types.InlayHint.Params;
    pub const CodeDescription = types.Diagnostic.CodeDescription;
    pub const DeclarationLink = types.Definition.Link;
    pub const SnippetTextEdit = types.TextDocument.Edit.Snippet;
    pub const WorkspaceSymbol = types.workspace.Symbol;
    pub const InitializeError = types.InitializeError;
    pub const RelativePattern = types.RelativePattern;
    pub const LocationUriOnly = types.workspace.Symbol.Location.UriOnly;
    pub const WorkspaceFolder = types.workspace.Folder;
    pub const TextDocumentItem = types.TextDocument;
    pub const InsertTextFormat = types.InsertTextFormat;
    pub const InlayHintOptions = types.InlayHint.Options;
    pub const NotebookDocument = types.NotebookDocument;
    pub const TextDocumentEdit = types.TextDocument.Edit;
    pub const InitializeResult = types.InitializeResult;
    pub const WorkspaceOptions = types.ServerCapabilities.WorkspaceOptions;
    pub const NotebookCellKind = types.NotebookCell.Kind;
    pub const DocumentSelector = types.DocumentSelector;
    pub const ReferenceContext = types.reference.Context;
    pub const ReferenceOptions = types.reference.Options;
    pub const ChangeAnnotation = types.ChangeAnnotation;
    pub const CodeActionParams = types.CodeAction.Params;
    pub const DefinitionParams = types.Definition.Params;
    pub const InitializeParams = types.InitializeParams;
    pub const ExecutionSummary = types.NotebookCell.ExecutionSummary;
    pub const PreviousResultId = types.PreviousResultId;
    pub const CompletionParams = types.completion.Params;
    pub const ColorInformation = types.DocumentColor;
    pub const LogMessageParams = types.window.LogMessageParams;
    pub const FoldingRangeKind = types.FoldingRange.Kind;
    pub const CodeActionContext = types.CodeAction.Context;
    pub const RenameFileOptions = types.WorkspaceEdit.RenameFile.Options;
    pub const MessageActionItem = types.window.show_message_request.Item;
    pub const DeclarationParams = types.declaration.Params;
    pub const DeleteFilesParams = types.workspace.DeleteFilesParams;
    pub const FormattingOptions = types.FormattingOptions;
    pub const CompletionOptions = types.completion.Options;
    pub const CompletionItemTag = types.completion.Item.Tag;
    pub const RenameFilesParams = types.workspace.RenameFilesParams;
    pub const InsertReplaceEdit = types.completion.Item.InsertReplaceEdit;
    pub const ColorPresentation = types.ColorPresentation;
    pub const ShowMessageParams = types.window.ShowMessageParams;
    pub const CreateFilesParams = types.workspace.CreateFilesParams;
    pub const CompletionContext = types.completion.Context;
    pub const DiagnosticOptions = types.Diagnostic.Options;
    pub const DefinitionOptions = types.Definition.Options;
    pub const ConfigurationItem = types.workspace.configuration.Item;
    pub const InlineValueParams = types.InlineValue.Params;
    pub const CodeActionOptions = types.CodeAction.Options;
    pub const FileSystemWatcher = types.workspace.FileSystemWatcher;
    pub const TypeHierarchyItem = types.type_hierarchy.Item;
    pub const AnnotatedTextEdit = types.TextEdit.Annotated;
    pub const DocumentHighlight = types.DocumentHighlight;
    pub const SymbolInformation = types.SymbolInformation;
    pub const CreateFileOptions = types.WorkspaceEdit.CreateFile.Options;
    pub const CallHierarchyItem = types.call_hierarchy.Item;
    pub const DeleteFileOptions = types.WorkspaceEdit.DeleteFile.Options;
    pub const InitializedParams = types.InitializedParams;
    pub const FoldingRangeParams = types.FoldingRange.Params;
    pub const RegistrationParams = types.Registration.Params;
    pub const ShowDocumentParams = types.window.show_document.Params;
    pub const ClientCapabilities = types.ClientCapabilities;
    pub const CompletionItemKind = types.completion.Item.Kind;
    pub const DeclarationOptions = types.declaration.Options;
    pub const InlineValueContext = types.InlineValue.Context;
    pub const ShowDocumentResult = types.window.show_document.Result;
    pub const InlayHintLabelPart = types.InlayHint.LabelPart;
    pub const SemanticTokenTypes = types.semantic_tokens.Type;
    pub const SemanticTokensEdit = types.semantic_tokens.Edit;
    pub const DiagnosticSeverity = types.Diagnostic.Severity;
    pub const CodeActionDisabled = types.CodeAction.Disabled;
    pub const ServerCapabilities = types.ServerCapabilities;
    pub const DocumentLinkParams = types.DocumentLink.Params;
    pub const InlineValueOptions = types.InlineValue.Options;
    pub const TextDocumentFilter = types.DocumentFilter.Text;
    pub const FoldingRangeOptions = types.FoldingRange.Options;
    pub const DocumentColorParams = types.DocumentColor.Params;
    pub const LinkedEditingRanges = types.linked_editing_range.Ranges;
    pub const PartialResultParams = types.PartialResultParams;
    pub const ConfigurationParams = types.workspace.configuration.Params;
    pub const FailureHandlingKind = types.ClientCapabilities.Workspace.Edit.FailureHandlingKind;
    pub const DocumentLinkOptions = types.DocumentLink.Options;
    pub const FileOperationFilter = types.workspace.file_operation.Filter;
    pub const SignatureHelpParams = types.SignatureHelp.Params;
    pub const WorkDoneProgressEnd = types.window.work_done_progress.End;
    pub const SemanticTokensDelta = types.semantic_tokens.Result.Delta;
    pub const PrepareRenameParams = types.prepare_rename.Params;
    pub const PrepareRenameResult = types.prepare_rename.Result;
    pub const FileOperationPattern = types.workspace.file_operation.Filter.Pattern;
    pub const TypeDefinitionParams = types.type_definition.Params;
    pub const UnregistrationParams = types.Unregistration.Params;
    pub const SemanticTokensParams = types.semantic_tokens.Params;
    pub const TextDocumentSyncKind = types.TextDocument.SyncKind;
    pub const NotebookCellLanguage = types.NotebookDocument.CellLanguage;
    pub const CallHierarchyOptions = types.call_hierarchy.Options;
    pub const DocumentSymbolParams = types.DocumentSymbol.Params;
    pub const ParameterInformation = types.SignatureHelp.Signature.Parameter;
    pub const FileOperationOptions = types.workspace.file_operation.Options;
    pub const InlineCompletionItem = types.inline_completion.Item;
    pub const DocumentColorOptions = types.DocumentColor.Options;
    pub const CodeActionTagOptions = types.ClientCapabilities.TextDocument.CodeAction.TagOptions;
    pub const InlineCompletionList = types.inline_completion.List;
    pub const SignatureInformation = types.SignatureHelp.Signature;
    pub const ExecuteCommandParams = types.workspace.execute_command.Params;
    pub const SignatureHelpOptions = types.SignatureHelp.Options;
    pub const SignatureHelpContext = types.SignatureHelp.Context;
    pub const SelectionRangeParams = types.SelectionRange.Params;
    pub const TypeHierarchyOptions = types.type_hierarchy.Options;
    pub const ImplementationParams = types.implementation.Params;
    pub const PositionEncodingKind = types.Position.EncodingKind;
    pub const SemanticTokensLegend = types.semantic_tokens.Options.Legend;
    pub const ImplementationOptions = types.implementation.Options;
    pub const SemanticTokensOptions = types.semantic_tokens.Options;
    pub const TypeDefinitionOptions = types.type_definition.Options;
    pub const ExecuteCommandOptions = types.workspace.execute_command.Options;
    pub const SelectionRangeOptions = types.SelectionRange.Options;
    pub const CompletionTriggerKind = types.completion.TriggerKind;
    pub const DocumentHighlightKind = types.DocumentHighlight.Kind;
    pub const ResourceOperationKind = types.ClientCapabilities.Workspace.Edit.ResourceOperationKind;
    pub const WorkspaceSymbolParams = types.workspace.Symbol.Params;
    pub const WorkspaceEditMetadata = types.WorkspaceEdit.Metadata;
    pub const CodeActionTriggerKind = types.CodeAction.TriggerKind;
    pub const WorkDoneProgressBegin = types.window.work_done_progress.Begin;
    pub const DocumentSymbolOptions = types.DocumentSymbol.Options;
    pub const TextDocumentIdentifier = types.TextDocument.Identifier;
    pub const TextDocumentSaveReason = types.TextDocument.SaveReason;
    pub const SelectedCompletionInfo = types.inline_completion.Context.SelectedCompletionInfo;
    pub const WorkDoneProgressParams = types.window.work_done_progress.Params;
    pub const WorkspaceSymbolOptions = types.workspace.Symbol.Options;
    pub const SemanticTokenModifiers = types.semantic_tokens.Modifier;
    pub const NotebookDocumentFilter = types.DocumentFilter.Notebook;
    pub const CompletionItemDefaults = types.ClientCapabilities.TextDocument.Completion.ItemDefaults;
    pub const ClientSymbolTagOptions = types.ClientCapabilities.Workspace.Symbol.TagOptions;
    pub const WorkDoneProgressReport = types.window.work_done_progress.Report;
    pub const InlineCompletionParams = types.inline_completion.Params;
    pub const NotebookCellArrayChange = types.NotebookCell.ArrayChange;
    pub const WorkDoneProgressOptions = types.window.work_done_progress.Options;
    pub const InlineCompletionContext = types.inline_completion.Context;
    pub const ClientSymbolKindOptions = types.ClientCapabilities.Workspace.Symbol.SymbolKindOptions;
    pub const SemanticTokensFullDelta = types.semantic_tokens.Options.FullDelta;
    pub const InlineCompletionOptions = types.inline_completion.Options;
    pub const TextDocumentSyncOptions = types.TextDocument.SyncOptions;
    pub const ColorPresentationParams = types.ColorPresentation.Params;
    pub const HoverClientCapabilities = types.ClientCapabilities.TextDocument.Hover;
    pub const DocumentHighlightParams = types.DocumentHighlight.Params;
    pub const DocumentDiagnosticReport = types.document_diagnostic.Report;
    pub const PrepareRenamePlaceholder = types.prepare_rename.Placeholder;
    pub const FileOperationPatternKind = types.workspace.file_operation.Filter.Pattern.PatternKind;
    pub const CompletionItemApplyKinds = types.ClientCapabilities.TextDocument.Completion.ItemApplyKinds;
    pub const CompletionItemTagOptions = types.ClientCapabilities.TextDocument.Completion.ItemTagOptions;
    pub const DocumentHighlightOptions = types.DocumentHighlight.Options;
    pub const WindowClientCapabilities = types.ClientCapabilities.Window;
    pub const ApplyWorkspaceEditResult = types.workspace.apply_workspace_edit.Result;
    pub const ApplyWorkspaceEditParams = types.workspace.apply_workspace_edit.Params;
    pub const DocumentDiagnosticParams = types.document_diagnostic.Params;
    pub const TextDocumentFilterScheme = types.DocumentFilter.Text.Scheme;
    pub const RenameClientCapabilities = types.ClientCapabilities.TextDocument.Rename;
    pub const PublishDiagnosticsParams = types.publish_diagnostics.Params;
    pub const ShowMessageRequestParams = types.window.show_message_request.Params;
    pub const MarkedStringWithLanguage = types.Hover.DeprecatedMarkedString.WithLanguage;
    pub const LinkedEditingRangeParams = types.linked_editing_range.Params;
    pub const SignatureHelpTriggerKind = types.SignatureHelp.TriggerKind;
    pub const DocumentFormattingParams = types.document_formatting.Params;
    pub const HoverRegistrationOptions = types.Hover.RegistrationOptions;
    pub const CallHierarchyIncomingCall = types.call_hierarchy.IncomingCall;
    pub const DidSaveTextDocumentParams = types.TextDocument.DidSaveParams;
    pub const TextDocumentContentParams = types.workspace.text_document_content.Params;
    pub const WorkspaceDiagnosticReport = types.workspace.diagnostic.Report;
    pub const TextDocumentFilterPattern = types.DocumentFilter.Text.Pattern;
    pub const WorkspaceDiagnosticParams = types.workspace.diagnostic.Params;
    pub const LinkedEditingRangeOptions = types.linked_editing_range.Options;
    pub const MonikerClientCapabilities = types.ClientCapabilities.TextDocument.Moniker;
    pub const CallHierarchyOutgoingCall = types.call_hierarchy.OutgoingCall;
    pub const TextDocumentContentResult = types.workspace.text_document_content.Result;
    pub const DocumentFormattingOptions = types.document_formatting.Options;
    pub const InlineValueVariableLookup = types.InlineValue.VariableLookup;
    pub const SemanticTokensDeltaParams = types.semantic_tokens.Params.FullDelta;
    pub const GeneralClientCapabilities = types.ClientCapabilities.General;
    pub const ClientFoldingRangeOptions = types.ClientCapabilities.TextDocument.FoldingRange.Options;
    pub const SemanticTokensRangeParams = types.semantic_tokens.Params.Range;
    pub const DidOpenTextDocumentParams = types.TextDocument.DidOpenParams;
    pub const RenameRegistrationOptions = types.rename.RegistrationOptions;
    pub const CodeLensClientCapabilities = types.ClientCapabilities.TextDocument.CodeLens;
    pub const TextDocumentFilterLanguage = types.DocumentFilter.Text.Language;
    pub const DidCloseTextDocumentParams = types.TextDocument.DidCloseParams;
    pub const TypeHierarchyPrepareParams = types.type_hierarchy.PrepareParams;
    pub const ClientSymbolResolveOptions = types.ClientCapabilities.Workspace.Symbol.ResolveOptions;
    pub const WillSaveTextDocumentParams = types.TextDocument.WillSaveParams;
    pub const NotebookDocumentIdentifier = types.NotebookDocument.Identifier;
    pub const EditRangeWithInsertReplace = types.ClientCapabilities.TextDocument.Completion.EditRange.WithInsertReplace;
    pub const TextDocumentContentOptions = types.workspace.text_document_content.Options;
    pub const MarkdownClientCapabilities = types.ClientCapabilities.General.Markdown;
    pub const CompletionListCapabilities = types.ClientCapabilities.TextDocument.Completion.ListOptions;
    pub const MonikerRegistrationOptions = types.Moniker.RegistrationOptions;
    pub const StaleRequestSupportOptions = types.ClientCapabilities.General.StaleRequestSupportOptions;
    pub const CompletionItemLabelDetails = types.completion.Item.LabelDetails;
    pub const ChangeAnnotationIdentifier = types.ChangeAnnotationIdentifier;
    pub const CallHierarchyPrepareParams = types.call_hierarchy.PrepareParams;
    pub const DidChangeWatchedFilesParams = types.workspace.did_change_watched_files.Params;
    pub const TypeHierarchySubtypesParams = types.type_hierarchy.SubtypesParams;
    pub const RegularExpressionEngineKind = types.ClientCapabilities.General.RegularExpressions.EngineKind;
    pub const CodeLensRegistrationOptions = types.code_lens.RegistrationOptions;
    pub const ClientCodeActionKindOptions = types.ClientCapabilities.TextDocument.CodeAction.KindOptions;
    pub const ClientCompletionItemOptions = types.ClientCapabilities.TextDocument.Completion.ItemOptions;
    pub const NotebookDocumentCellChanges = types.NotebookDocument.ChangeEvent.CellChanges;
    pub const InlayHintClientCapabilities = types.ClientCapabilities.TextDocument.InlayHint;
    pub const ReferenceClientCapabilities = types.ClientCapabilities.TextDocument.Reference;
    pub const CodeActionKindDocumentation = types.CodeAction.KindDocumentation;
    pub const NotebookDocumentChangeEvent = types.NotebookDocument.ChangeEvent;
    pub const SemanticTokensPartialResult = types.semantic_tokens.Result.Partial;
    pub const WorkspaceFoldersChangeEvent = types.workspace.folders.ChangeEvent;
    pub const InlineCompletionTriggerKind = types.inline_completion.Context.TriggerKind;
    pub const DidChangeTextDocumentParams = types.TextDocument.DidChangeParams;
    pub const FileOperationPatternOptions = types.workspace.file_operation.Filter.Pattern.PatternOptions;
    pub const ClientDiagnosticsTagOptions = types.ClientCapabilities.TextDocument.Diagnostic.TagOptions;
    pub const NotebookDocumentSyncOptions = types.NotebookDocument.SyncOptions;
    pub const WorkspaceClientCapabilities = types.ClientCapabilities.Workspace;
    pub const ServerCompletionItemOptions = types.completion.Options.ItemOptions;
    pub const FullDocumentDiagnosticReport = types.document_diagnostic.Report.Full;
    pub const PrepareRenameDefaultBehavior = types.prepare_rename.DefaultBehavior;
    pub const DiagnosticClientCapabilities = types.ClientCapabilities.TextDocument.Diagnostic;
    pub const CodeActionClientCapabilities = types.ClientCapabilities.TextDocument.CodeAction;
    pub const DiagnosticRelatedInformation = types.Diagnostic.RelatedInformation;
    pub const ReferenceRegistrationOptions = types.reference.RegistrationOptions;
    pub const WorkDoneProgressCreateParams = types.window.work_done_progress.CreateParams;
    pub const InlayHintRegistrationOptions = types.InlayHint.RegistrationOptions;
    pub const NotebookDocumentFilterScheme = types.DocumentFilter.Notebook.Scheme;
    pub const DocumentDiagnosticReportKind = types.document_diagnostic.Report.Kind;
    pub const DefinitionClientCapabilities = types.ClientCapabilities.TextDocument.Definition;
    pub const ClientCodeLensResolveOptions = types.ClientCapabilities.TextDocument.CodeLens.ResolveOptions;
    pub const WorkDoneProgressCancelParams = types.window.work_done_progress.CancelParams;
    pub const DidChangeConfigurationParams = types.workspace.configuration.did_change.Params;
    pub const CompletionClientCapabilities = types.ClientCapabilities.TextDocument.Completion;
    pub const DocumentRangeFormattingParams = types.document_range_formatting.Params;
    pub const DefinitionRegistrationOptions = types.Definition.RegistrationOptions;
    pub const TypeHierarchySupertypesParams = types.type_hierarchy.SupertypesParams;
    pub const ClientFoldingRangeKindOptions = types.ClientCapabilities.TextDocument.FoldingRange.KindOptions;
    pub const CompletionRegistrationOptions = types.completion.RegistrationOptions;
    pub const PrepareSupportDefaultBehavior = types.ClientCapabilities.TextDocument.Rename.PrepareSupportDefaultBehavior;
    pub const InlineValueClientCapabilities = types.ClientCapabilities.TextDocument.InlineValue;
    pub const ClientInlayHintResolveOptions = types.ClientCapabilities.TextDocument.InlayHint.ResolveOptions;
    pub const DeclarationClientCapabilities = types.ClientCapabilities.TextDocument.Declaration;
    pub const NotebookDocumentFilterPattern = types.DocumentFilter.Notebook.Pattern;
    pub const CodeActionRegistrationOptions = types.CodeAction.RegistrationOptions;
    pub const DidSaveNotebookDocumentParams = types.NotebookDocument.DidSaveParams;
    pub const DiagnosticRegistrationOptions = types.Diagnostic.RegistrationOptions;
    pub const DidOpenNotebookDocumentParams = types.NotebookDocument.DidOpenParams;
    pub const DocumentRangeFormattingOptions = types.document_range_formatting.Options;
    pub const DidCloseNotebookDocumentParams = types.NotebookDocument.DidCloseParams;
    pub const NotebookCellTextDocumentFilter = types.NotebookCell.TextDocumentFilter;
    pub const DocumentRangesFormattingParams = types.document_ranges_formatting.Params;
    pub const DeclarationRegistrationOptions = types.declaration.RegistrationOptions;
    pub const ClientCodeActionLiteralOptions = types.ClientCapabilities.TextDocument.CodeAction.LiteralOptions;
    pub const ClientCodeActionResolveOptions = types.ClientCapabilities.TextDocument.CodeAction.ResolveOptions;
    pub const TextDocumentContentChangeEvent = types.TextDocument.ContentChangeEvent;
    pub const DocumentOnTypeFormattingParams = types.document_on_type_formatting.Params;
    pub const ShowDocumentClientCapabilities = types.ClientCapabilities.Window.ShowDocument;
    pub const InlineValueRegistrationOptions = types.InlineValue.RegistrationOptions;
    pub const DocumentLinkClientCapabilities = types.ClientCapabilities.TextDocument.DocumentLink;
    pub const TextDocumentClientCapabilities = types.ClientCapabilities.TextDocument;
    pub const FoldingRangeClientCapabilities = types.ClientCapabilities.TextDocument.FoldingRange;
    pub const ClientCompletionItemOptionsKind = types.ClientCapabilities.TextDocument.Completion.ItemKindOptions;
    pub const VersionedTextDocumentIdentifier = types.TextDocument.Identifier.Versioned;
    pub const CallHierarchyClientCapabilities = types.ClientCapabilities.TextDocument.CallHierarchy;
    pub const FoldingRangeRegistrationOptions = types.FoldingRange.RegistrationOptions;
    pub const TypeHierarchyClientCapabilities = types.ClientCapabilities.TextDocument.TypeHierarchy;
    pub const DocumentColorClientCapabilities = types.ClientCapabilities.TextDocument.DocumentColor;
    pub const SignatureHelpClientCapabilities = types.ClientCapabilities.TextDocument.SignatureHelp;
    pub const DocumentLinkRegistrationOptions = types.DocumentLink.RegistrationOptions;
    pub const TextDocumentRegistrationOptions = types.TextDocument.RegistrationOptions;
    pub const DidChangeNotebookDocumentParams = types.NotebookDocument.DidChangeParams;
    pub const DidChangeWorkspaceFoldersParams = types.workspace.folders.DidChangeParams;
    pub const DocumentOnTypeFormattingOptions = types.document_on_type_formatting.Options;
    pub const NotebookDocumentFilterWithCells = types.NotebookDocument.SyncOptions.FilterWithCells;
    pub const FileOperationClientCapabilities = types.ClientCapabilities.Workspace.FileOperation;
    pub const WorkspaceEditClientCapabilities = types.ClientCapabilities.Workspace.Edit;
    pub const ChangeAnnotationsSupportOptions = types.ClientCapabilities.Workspace.Edit.ChangeAnnotationsSupportOptions;
    pub const CallHierarchyOutgoingCallsParams = types.call_hierarchy.OutgoingCallsParams;
    pub const ImplementationClientCapabilities = types.ClientCapabilities.TextDocument.Implementation;
    pub const CallHierarchyIncomingCallsParams = types.call_hierarchy.IncomingCallsParams;
    pub const WorkspaceFoldersInitializeParams = types.workspace.folders.InitializeParams;
    pub const FileOperationRegistrationOptions = types.workspace.file_operation.RegistrationOptions;
    pub const ExecuteCommandClientCapabilities = types.ClientCapabilities.Workspace.ExecuteCommand;
    pub const CallHierarchyRegistrationOptions = types.call_hierarchy.RegistrationOptions;
    pub const TypeHierarchyRegistrationOptions = types.type_hierarchy.RegistrationOptions;
    pub const SemanticTokensClientCapabilities = types.ClientCapabilities.TextDocument.SemanticTokens;
    pub const InlineValueEvaluatableExpression = types.InlineValue.EvaluatableExpression;
    pub const SelectionRangeClientCapabilities = types.ClientCapabilities.TextDocument.SelectionRange;
    pub const TextDocumentContentRefreshParams = types.workspace.text_document_content.RefreshParams;
    pub const SignatureHelpRegistrationOptions = types.SignatureHelp.RegistrationOptions;
    pub const TextDocumentContentChangePartial = types.workspace.text_document_content.ChangePartial;
    pub const DocumentSymbolClientCapabilities = types.ClientCapabilities.TextDocument.DocumentSymbol;
    pub const SemanticTokensDeltaPartialResult = types.semantic_tokens.Result.Delta.Partial;
    pub const DocumentColorRegistrationOptions = types.DocumentColor.RegistrationOptions;
    pub const DiagnosticServerCancellationData = types.Diagnostic.ServerCancellationData;
    pub const TypeDefinitionClientCapabilities = types.ClientCapabilities.TextDocument.TypeDefinition;
    pub const TypeDefinitionRegistrationOptions = types.type_definition.RegistrationOptions;
    pub const SemanticTokensRegistrationOptions = types.semantic_tokens.RegistrationOptions;
    pub const ImplementationRegistrationOptions = types.implementation.RegistrationOptions;
    pub const WorkspaceDocumentDiagnosticReport = types.workspace.diagnostic.Report.Document;
    pub const UnchangedDocumentDiagnosticReport = types.document_diagnostic.Report.Unchanged;
    pub const ExecuteCommandRegistrationOptions = types.workspace.execute_command.RegistrationOptions;
    pub const ClientSignatureInformationOptions = types.ClientCapabilities.TextDocument.SignatureHelp.InformationOptions;
    pub const SelectionRangeRegistrationOptions = types.SelectionRange.RegistrationOptions;
    pub const WorkspaceSymbolClientCapabilities = types.ClientCapabilities.Workspace.Symbol;
    pub const DocumentSymbolRegistrationOptions = types.DocumentSymbol.RegistrationOptions;
    pub const ClientSemanticTokensRequestOptions = types.ClientCapabilities.TextDocument.SemanticTokens.RequestOptions;
    pub const NotebookDocumentFilterNotebookType = types.DocumentFilter.Notebook.NotebookType;
    pub const WorkspaceFoldersServerCapabilities = types.workspace.folders.ServerCapabilities;
    pub const ClientShowMessageActionItemOptions = types.ClientCapabilities.Window.ShowMessageRequest.ItemOptions;
    pub const NotebookDocumentClientCapabilities = types.ClientCapabilities.NotebookDocument;
    pub const NotebookDocumentFilterWithNotebook = types.NotebookDocument.SyncOptions.FilterWithNotebook;
    pub const WorkspaceSymbolRegistrationOptions = types.workspace.Symbol.RegistrationOptions;
    pub const ClientCompletionItemResolveOptions = types.ClientCapabilities.TextDocument.Completion.ItemResolveOptions;
    pub const NotebookDocumentCellContentChanges = types.NotebookDocument.ChangeEvent.CellContentChanges;
    pub const InlineCompletionClientCapabilities = types.ClientCapabilities.TextDocument.InlineCompletion;
    pub const TextDocumentSyncClientCapabilities = types.ClientCapabilities.TextDocument.Sync;
    pub const CodeLensWorkspaceClientCapabilities = types.ClientCapabilities.Workspace.CodeLens;
    pub const VersionedNotebookDocumentIdentifier = types.NotebookDocument.Identifier.Versioned;
    pub const NotebookDocumentCellChangeStructure = types.NotebookDocument.ChangeEvent.CellContent.Structure;
    pub const InlineCompletionRegistrationOptions = types.inline_completion.RegistrationOptions;
    pub const DocumentHighlightClientCapabilities = types.ClientCapabilities.TextDocument.DocumentHighlight;
    pub const RelatedFullDocumentDiagnosticReport = types.document_diagnostic.Report.Full.Related;
    pub const TextDocumentSaveRegistrationOptions = types.TextDocument.SaveRegistrationOptions;
    pub const DocumentHighlightRegistrationOptions = types.DocumentHighlight.RegistrationOptions;
    pub const ClientSemanticTokensRequestFullDelta = types.ClientCapabilities.TextDocument.SemanticTokens.RequestOptions.FullDelta;
    pub const LinkedEditingRangeClientCapabilities = types.ClientCapabilities.TextDocument.LinkedEditingRange;
    pub const DocumentFormattingClientCapabilities = types.ClientCapabilities.TextDocument.DocumentFormatting;
    pub const RegularExpressionsClientCapabilities = types.ClientCapabilities.General.RegularExpressions;
    pub const InlayHintWorkspaceClientCapabilities = types.ClientCapabilities.Workspace.InlayHint;
    pub const TextDocumentFilterClientCapabilities = types.ClientCapabilities.TextDocument.Filter;
    pub const ShowMessageRequestClientCapabilities = types.ClientCapabilities.Window.ShowMessageRequest;
    pub const PublishDiagnosticsClientCapabilities = types.ClientCapabilities.TextDocument.PublishDiagnostics;
    pub const DocumentFormattingRegistrationOptions = types.document_formatting.RegistrationOptions;
    pub const TextDocumentChangeRegistrationOptions = types.TextDocument.ChangeRegistrationOptions;
    pub const DocumentDiagnosticReportPartialResult = types.document_diagnostic.Report.PartialResult;
    pub const WorkspaceFullDocumentDiagnosticReport = types.workspace.diagnostic.Report.Document.Full;
    pub const LinkedEditingRangeRegistrationOptions = types.linked_editing_range.RegistrationOptions;
    pub const DiagnosticWorkspaceClientCapabilities = types.ClientCapabilities.Workspace.Diagnostic;
    pub const TextDocumentContentClientCapabilities = types.ClientCapabilities.Workspace.TextDocumentContent;
    pub const InlineValueWorkspaceClientCapabilities = types.ClientCapabilities.Workspace.InlineValue;
    pub const NotebookDocumentSyncClientCapabilities = types.ClientCapabilities.NotebookDocument.Sync;
    pub const TextDocumentContentRegistrationOptions = types.workspace.text_document_content.RegistrationOptions;
    pub const WorkspaceDiagnosticReportPartialResult = types.workspace.diagnostic.Report.PartialResult;
    pub const TextDocumentContentChangeWholeDocument = types.workspace.text_document_content.ChangeWholeDocument;
    pub const OptionalVersionedTextDocumentIdentifier = types.TextDocument.Identifier.Versioned.Optional;
    pub const NotebookDocumentSyncRegistrationOptions = types.NotebookDocument.SyncRegistrationOptions;
    pub const DidChangeWatchedFilesClientCapabilities = types.ClientCapabilities.Workspace.DidChangeWatchedFiles;
    pub const FoldingRangeWorkspaceClientCapabilities = types.ClientCapabilities.Workspace.FoldingRange;
    pub const DidChangeWatchedFilesRegistrationOptions = types.workspace.did_change_watched_files.RegistrationOptions;
    pub const RelatedUnchangedDocumentDiagnosticReport = types.document_diagnostic.Report.Unchanged.Related;
    pub const DidChangeConfigurationClientCapabilities = types.ClientCapabilities.Workspace.DidChangeConfiguration;
    pub const DidChangeConfigurationRegistrationOptions = types.workspace.configuration.did_change.RegistrationOptions;
    pub const DocumentRangeFormattingClientCapabilities = types.ClientCapabilities.TextDocument.DocumentRangeFormatting;
    pub const SemanticTokensWorkspaceClientCapabilities = types.ClientCapabilities.Workspace.SemanticTokens;
    pub const ClientCompletionItemInsertTextModeOptions = types.ClientCapabilities.TextDocument.Completion.ItemInsertTextModeOptions;
    pub const ClientSignatureParameterInformationOptions = types.ClientCapabilities.TextDocument.SignatureHelp.ParameterInformationOptions;
    pub const DocumentOnTypeFormattingClientCapabilities = types.ClientCapabilities.TextDocument.DocumentOnTypeFormatting;
    pub const DocumentRangeFormattingRegistrationOptions = types.document_range_formatting.RegistrationOptions;
    pub const WorkspaceUnchangedDocumentDiagnosticReport = types.workspace.diagnostic.Report.Document.Unchanged;
    pub const DocumentOnTypeFormattingRegistrationOptions = types.document_on_type_formatting.RegistrationOptions;
};

const notifications_generated: std.StaticStringMap(NotificationMetadata) = .initComptime(&.{
    // The `workspace/didChangeWorkspaceFolders` notification is sent from the client to the server when the workspace
    // folder configuration changes.
    .{
        "workspace/didChangeWorkspaceFolders",
        NotificationMetadata{
            .method = "workspace/didChangeWorkspaceFolders",
            .documentation = "The `workspace/didChangeWorkspaceFolders` notification is sent from the client to the server when the workspace\nfolder configuration changes.",
            .direction = .client_to_server,
            .Params = workspace.folders.DidChangeParams,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // The `window/workDoneProgress/cancel` notification is sent from  the client to the server to cancel a progress
    // initiated on the server side.
    .{
        "window/workDoneProgress/cancel",
        NotificationMetadata{
            .method = "window/workDoneProgress/cancel",
            .documentation = "The `window/workDoneProgress/cancel` notification is sent from  the client to the server to cancel a progress\ninitiated on the server side.",
            .direction = .client_to_server,
            .Params = window.work_done_progress.CancelParams,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // The did create files notification is sent from the client to the server when
    // files were created from within the client.
    //
    // @since 3.16.0
    .{
        "workspace/didCreateFiles",
        NotificationMetadata{
            .method = "workspace/didCreateFiles",
            .documentation = "The did create files notification is sent from the client to the server when\nfiles were created from within the client.\n\n@since 3.16.0",
            .direction = .client_to_server,
            .Params = workspace.CreateFilesParams,
            .registration = .{ .method = null, .Options = workspace.file_operation.RegistrationOptions },
        },
    },
    // The did rename files notification is sent from the client to the server when
    // files were renamed from within the client.
    //
    // @since 3.16.0
    .{
        "workspace/didRenameFiles",
        NotificationMetadata{
            .method = "workspace/didRenameFiles",
            .documentation = "The did rename files notification is sent from the client to the server when\nfiles were renamed from within the client.\n\n@since 3.16.0",
            .direction = .client_to_server,
            .Params = workspace.RenameFilesParams,
            .registration = .{ .method = null, .Options = workspace.file_operation.RegistrationOptions },
        },
    },
    // The will delete files request is sent from the client to the server before files are actually
    // deleted as long as the deletion is triggered from within the client.
    //
    // @since 3.16.0
    .{
        "workspace/didDeleteFiles",
        NotificationMetadata{
            .method = "workspace/didDeleteFiles",
            .documentation = "The will delete files request is sent from the client to the server before files are actually\ndeleted as long as the deletion is triggered from within the client.\n\n@since 3.16.0",
            .direction = .client_to_server,
            .Params = workspace.DeleteFilesParams,
            .registration = .{ .method = null, .Options = workspace.file_operation.RegistrationOptions },
        },
    },
    // A notification sent when a notebook opens.
    //
    // @since 3.17.0
    .{
        "notebookDocument/didOpen",
        NotificationMetadata{
            .method = "notebookDocument/didOpen",
            .documentation = "A notification sent when a notebook opens.\n\n@since 3.17.0",
            .direction = .client_to_server,
            .Params = NotebookDocument.DidOpenParams,
            .registration = .{ .method = "notebookDocument/sync", .Options = NotebookDocument.SyncRegistrationOptions },
        },
    },
    .{
        "notebookDocument/didChange",
        NotificationMetadata{
            .method = "notebookDocument/didChange",
            .documentation = null,
            .direction = .client_to_server,
            .Params = NotebookDocument.DidChangeParams,
            .registration = .{ .method = "notebookDocument/sync", .Options = NotebookDocument.SyncRegistrationOptions },
        },
    },
    // A notification sent when a notebook document is saved.
    //
    // @since 3.17.0
    .{
        "notebookDocument/didSave",
        NotificationMetadata{
            .method = "notebookDocument/didSave",
            .documentation = "A notification sent when a notebook document is saved.\n\n@since 3.17.0",
            .direction = .client_to_server,
            .Params = NotebookDocument.DidSaveParams,
            .registration = .{ .method = "notebookDocument/sync", .Options = NotebookDocument.SyncRegistrationOptions },
        },
    },
    // A notification sent when a notebook closes.
    //
    // @since 3.17.0
    .{
        "notebookDocument/didClose",
        NotificationMetadata{
            .method = "notebookDocument/didClose",
            .documentation = "A notification sent when a notebook closes.\n\n@since 3.17.0",
            .direction = .client_to_server,
            .Params = NotebookDocument.DidCloseParams,
            .registration = .{ .method = "notebookDocument/sync", .Options = NotebookDocument.SyncRegistrationOptions },
        },
    },
    // The initialized notification is sent from the client to the
    // server after the client is fully initialized and the server
    // is allowed to send requests from the server to the client.
    .{
        "initialized",
        NotificationMetadata{
            .method = "initialized",
            .documentation = "The initialized notification is sent from the client to the\nserver after the client is fully initialized and the server\nis allowed to send requests from the server to the client.",
            .direction = .client_to_server,
            .Params = InitializedParams,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // The exit event is sent from the client to the server to
    // ask the server to exit its process.
    .{
        "exit",
        NotificationMetadata{
            .method = "exit",
            .documentation = "The exit event is sent from the client to the server to\nask the server to exit its process.",
            .direction = .client_to_server,
            .Params = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // The configuration change notification is sent from the client to the server
    // when the client's configuration has changed. The notification contains
    // the changed configuration as defined by the language client.
    .{
        "workspace/didChangeConfiguration",
        NotificationMetadata{
            .method = "workspace/didChangeConfiguration",
            .documentation = "The configuration change notification is sent from the client to the server\nwhen the client's configuration has changed. The notification contains\nthe changed configuration as defined by the language client.",
            .direction = .client_to_server,
            .Params = workspace.configuration.did_change.Params,
            .registration = .{ .method = null, .Options = workspace.configuration.did_change.RegistrationOptions },
        },
    },
    // The show message notification is sent from a server to a client to ask
    // the client to display a particular message in the user interface.
    .{
        "window/showMessage",
        NotificationMetadata{
            .method = "window/showMessage",
            .documentation = "The show message notification is sent from a server to a client to ask\nthe client to display a particular message in the user interface.",
            .direction = .server_to_client,
            .Params = window.ShowMessageParams,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // The log message notification is sent from the server to the client to ask
    // the client to log a particular message.
    .{
        "window/logMessage",
        NotificationMetadata{
            .method = "window/logMessage",
            .documentation = "The log message notification is sent from the server to the client to ask\nthe client to log a particular message.",
            .direction = .server_to_client,
            .Params = window.LogMessageParams,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // The telemetry event notification is sent from the server to the client to ask
    // the client to log telemetry data.
    .{
        "telemetry/event",
        NotificationMetadata{
            .method = "telemetry/event",
            .documentation = "The telemetry event notification is sent from the server to the client to ask\nthe client to log telemetry data.",
            .direction = .server_to_client,
            .Params = LSPAny,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // The document open notification is sent from the client to the server to signal
    // newly opened text documents. The document's truth is now managed by the client
    // and the server must not try to read the document's truth using the document's
    // uri. Open in this sense means it is managed by the client. It doesn't necessarily
    // mean that its content is presented in an editor. An open notification must not
    // be sent more than once without a corresponding close notification send before.
    // This means open and close notification must be balanced and the max open count
    // is one.
    .{
        "textDocument/didOpen",
        NotificationMetadata{
            .method = "textDocument/didOpen",
            .documentation = "The document open notification is sent from the client to the server to signal\nnewly opened text documents. The document's truth is now managed by the client\nand the server must not try to read the document's truth using the document's\nuri. Open in this sense means it is managed by the client. It doesn't necessarily\nmean that its content is presented in an editor. An open notification must not\nbe sent more than once without a corresponding close notification send before.\nThis means open and close notification must be balanced and the max open count\nis one.",
            .direction = .client_to_server,
            .Params = TextDocument.DidOpenParams,
            .registration = .{ .method = null, .Options = TextDocument.RegistrationOptions },
        },
    },
    // The document change notification is sent from the client to the server to signal
    // changes to a text document.
    .{
        "textDocument/didChange",
        NotificationMetadata{
            .method = "textDocument/didChange",
            .documentation = "The document change notification is sent from the client to the server to signal\nchanges to a text document.",
            .direction = .client_to_server,
            .Params = TextDocument.DidChangeParams,
            .registration = .{ .method = null, .Options = TextDocument.ChangeRegistrationOptions },
        },
    },
    // The document close notification is sent from the client to the server when
    // the document got closed in the client. The document's truth now exists where
    // the document's uri points to (e.g. if the document's uri is a file uri the
    // truth now exists on disk). As with the open notification the close notification
    // is about managing the document's content. Receiving a close notification
    // doesn't mean that the document was open in an editor before. A close
    // notification requires a previous open notification to be sent.
    .{
        "textDocument/didClose",
        NotificationMetadata{
            .method = "textDocument/didClose",
            .documentation = "The document close notification is sent from the client to the server when\nthe document got closed in the client. The document's truth now exists where\nthe document's uri points to (e.g. if the document's uri is a file uri the\ntruth now exists on disk). As with the open notification the close notification\nis about managing the document's content. Receiving a close notification\ndoesn't mean that the document was open in an editor before. A close\nnotification requires a previous open notification to be sent.",
            .direction = .client_to_server,
            .Params = TextDocument.DidCloseParams,
            .registration = .{ .method = null, .Options = TextDocument.RegistrationOptions },
        },
    },
    // The document save notification is sent from the client to the server when
    // the document got saved in the client.
    .{
        "textDocument/didSave",
        NotificationMetadata{
            .method = "textDocument/didSave",
            .documentation = "The document save notification is sent from the client to the server when\nthe document got saved in the client.",
            .direction = .client_to_server,
            .Params = TextDocument.DidSaveParams,
            .registration = .{ .method = null, .Options = TextDocument.SaveRegistrationOptions },
        },
    },
    // A document will save notification is sent from the client to the server before
    // the document is actually saved.
    .{
        "textDocument/willSave",
        NotificationMetadata{
            .method = "textDocument/willSave",
            .documentation = "A document will save notification is sent from the client to the server before\nthe document is actually saved.",
            .direction = .client_to_server,
            .Params = TextDocument.WillSaveParams,
            .registration = .{ .method = null, .Options = TextDocument.RegistrationOptions },
        },
    },
    // The watched files notification is sent from the client to the server when
    // the client detects changes to file watched by the language client.
    .{
        "workspace/didChangeWatchedFiles",
        NotificationMetadata{
            .method = "workspace/didChangeWatchedFiles",
            .documentation = "The watched files notification is sent from the client to the server when\nthe client detects changes to file watched by the language client.",
            .direction = .client_to_server,
            .Params = workspace.did_change_watched_files.Params,
            .registration = .{ .method = null, .Options = workspace.did_change_watched_files.RegistrationOptions },
        },
    },
    // Diagnostics notification are sent from the server to the client to signal
    // results of validation runs.
    .{
        "textDocument/publishDiagnostics",
        NotificationMetadata{
            .method = "textDocument/publishDiagnostics",
            .documentation = "Diagnostics notification are sent from the server to the client to signal\nresults of validation runs.",
            .direction = .server_to_client,
            .Params = publish_diagnostics.Params,
            .registration = .{ .method = null, .Options = null },
        },
    },
    .{
        "$/setTrace",
        NotificationMetadata{
            .method = "$/setTrace",
            .documentation = null,
            .direction = .client_to_server,
            .Params = trace.SetParams,
            .registration = .{ .method = null, .Options = null },
        },
    },
    .{
        "$/logTrace",
        NotificationMetadata{
            .method = "$/logTrace",
            .documentation = null,
            .direction = .server_to_client,
            .Params = trace.LogParams,
            .registration = .{ .method = null, .Options = null },
        },
    },
    .{
        "$/cancelRequest",
        NotificationMetadata{
            .method = "$/cancelRequest",
            .documentation = null,
            .direction = .both,
            .Params = CancelParams,
            .registration = .{ .method = null, .Options = null },
        },
    },
    .{
        "$/progress",
        NotificationMetadata{
            .method = "$/progress",
            .documentation = null,
            .direction = .both,
            .Params = ProgressParams,
            .registration = .{ .method = null, .Options = null },
        },
    },
});

const requests_generated: std.StaticStringMap(RequestMetadata) = .initComptime(&.{
    // A request to resolve the implementation locations of a symbol at a given text
    // document position. The request's parameter is of type {@link TextDocumentPositionParams}
    // the response is of type {@link Definition} or a Thenable that resolves to such.
    .{
        "textDocument/implementation",
        RequestMetadata{
            .method = "textDocument/implementation",
            .documentation = "A request to resolve the implementation locations of a symbol at a given text\ndocument position. The request's parameter is of type {@link TextDocumentPositionParams}\nthe response is of type {@link Definition} or a Thenable that resolves to such.",
            .direction = .client_to_server,
            .Params = implementation.Params,
            .Result = ?Definition.Result,
            .PartialResult = Definition.PartialResult,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = implementation.RegistrationOptions },
        },
    },
    // A request to resolve the type definition locations of a symbol at a given text
    // document position. The request's parameter is of type {@link TextDocumentPositionParams}
    // the response is of type {@link Definition} or a Thenable that resolves to such.
    .{
        "textDocument/typeDefinition",
        RequestMetadata{
            .method = "textDocument/typeDefinition",
            .documentation = "A request to resolve the type definition locations of a symbol at a given text\ndocument position. The request's parameter is of type {@link TextDocumentPositionParams}\nthe response is of type {@link Definition} or a Thenable that resolves to such.",
            .direction = .client_to_server,
            .Params = type_definition.Params,
            .Result = ?Definition.Result,
            .PartialResult = Definition.PartialResult,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = type_definition.RegistrationOptions },
        },
    },
    // The `workspace/workspaceFolders` is sent from the server to the client to fetch the open workspace folders.
    .{
        "workspace/workspaceFolders",
        RequestMetadata{
            .method = "workspace/workspaceFolders",
            .documentation = "The `workspace/workspaceFolders` is sent from the server to the client to fetch the open workspace folders.",
            .direction = .server_to_client,
            .Params = null,
            .Result = ?[]const workspace.Folder,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // The 'workspace/configuration' request is sent from the server to the client to fetch a certain
    // configuration setting.
    //
    // This pull model replaces the old push model were the client signaled configuration change via an
    // event. If the server still needs to react to configuration changes (since the server caches the
    // result of `workspace/configuration` requests) the server should register for an empty configuration
    // change event and empty the cache if such an event is received.
    .{
        "workspace/configuration",
        RequestMetadata{
            .method = "workspace/configuration",
            .documentation = "The 'workspace/configuration' request is sent from the server to the client to fetch a certain\nconfiguration setting.\n\nThis pull model replaces the old push model were the client signaled configuration change via an\nevent. If the server still needs to react to configuration changes (since the server caches the\nresult of `workspace/configuration` requests) the server should register for an empty configuration\nchange event and empty the cache if such an event is received.",
            .direction = .server_to_client,
            .Params = workspace.configuration.Params,
            .Result = []const LSPAny,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // A request to list all color symbols found in a given text document. The request's
    // parameter is of type {@link DocumentColorParams} the
    // response is of type {@link ColorInformation ColorInformation[]} or a Thenable
    // that resolves to such.
    .{
        "textDocument/documentColor",
        RequestMetadata{
            .method = "textDocument/documentColor",
            .documentation = "A request to list all color symbols found in a given text document. The request's\nparameter is of type {@link DocumentColorParams} the\nresponse is of type {@link ColorInformation ColorInformation[]} or a Thenable\nthat resolves to such.",
            .direction = .client_to_server,
            .Params = DocumentColor.Params,
            .Result = []const DocumentColor,
            .PartialResult = []const DocumentColor,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = DocumentColor.RegistrationOptions },
        },
    },
    // A request to list all presentation for a color. The request's
    // parameter is of type {@link ColorPresentationParams} the
    // response is of type {@link ColorInformation ColorInformation[]} or a Thenable
    // that resolves to such.
    .{
        "textDocument/colorPresentation",
        RequestMetadata{
            .method = "textDocument/colorPresentation",
            .documentation = "A request to list all presentation for a color. The request's\nparameter is of type {@link ColorPresentationParams} the\nresponse is of type {@link ColorInformation ColorInformation[]} or a Thenable\nthat resolves to such.",
            .direction = .client_to_server,
            .Params = ColorPresentation.Params,
            .Result = []const ColorPresentation,
            .PartialResult = []const ColorPresentation,
            .ErrorData = null,
            .registration = .{
                .method = null,
                .Options = struct {
                    // And WorkDoneProgressOptions
                    workDoneProgress: ?bool = null,

                    // And TextDocumentRegistrationOptions
                    /// A document selector to identify the scope of the registration. If set to null
                    /// the document selector provided on the client side will be used.
                    documentSelector: ?DocumentSelector = null,
                },
            },
        },
    },
    // A request to provide folding ranges in a document. The request's
    // parameter is of type {@link FoldingRangeParams}, the
    // response is of type {@link FoldingRangeList} or a Thenable
    // that resolves to such.
    .{
        "textDocument/foldingRange",
        RequestMetadata{
            .method = "textDocument/foldingRange",
            .documentation = "A request to provide folding ranges in a document. The request's\nparameter is of type {@link FoldingRangeParams}, the\nresponse is of type {@link FoldingRangeList} or a Thenable\nthat resolves to such.",
            .direction = .client_to_server,
            .Params = FoldingRange.Params,
            .Result = ?[]const FoldingRange,
            .PartialResult = []const FoldingRange,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = FoldingRange.RegistrationOptions },
        },
    },
    // @since 3.18.0
    // @proposed
    .{
        "workspace/foldingRange/refresh",
        RequestMetadata{
            .method = "workspace/foldingRange/refresh",
            .documentation = "@since 3.18.0\n@proposed",
            .direction = .server_to_client,
            .Params = null,
            .Result = ?void,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // A request to resolve the type definition locations of a symbol at a given text
    // document position. The request's parameter is of type {@link TextDocumentPositionParams}
    // the response is of type {@link Declaration} or a typed array of {@link DeclarationLink}
    // or a Thenable that resolves to such.
    .{
        "textDocument/declaration",
        RequestMetadata{
            .method = "textDocument/declaration",
            .documentation = "A request to resolve the type definition locations of a symbol at a given text\ndocument position. The request's parameter is of type {@link TextDocumentPositionParams}\nthe response is of type {@link Declaration} or a typed array of {@link DeclarationLink}\nor a Thenable that resolves to such.",
            .direction = .client_to_server,
            .Params = declaration.Params,
            .Result = ?Definition.Result,
            .PartialResult = Definition.PartialResult,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = declaration.RegistrationOptions },
        },
    },
    // A request to provide selection ranges in a document. The request's
    // parameter is of type {@link SelectionRangeParams}, the
    // response is of type {@link SelectionRange SelectionRange[]} or a Thenable
    // that resolves to such.
    .{
        "textDocument/selectionRange",
        RequestMetadata{
            .method = "textDocument/selectionRange",
            .documentation = "A request to provide selection ranges in a document. The request's\nparameter is of type {@link SelectionRangeParams}, the\nresponse is of type {@link SelectionRange SelectionRange[]} or a Thenable\nthat resolves to such.",
            .direction = .client_to_server,
            .Params = SelectionRange.Params,
            .Result = ?[]const SelectionRange,
            .PartialResult = []const SelectionRange,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = SelectionRange.RegistrationOptions },
        },
    },
    // The `window/workDoneProgress/create` request is sent from the server to the client to initiate progress
    // reporting from the server.
    .{
        "window/workDoneProgress/create",
        RequestMetadata{
            .method = "window/workDoneProgress/create",
            .documentation = "The `window/workDoneProgress/create` request is sent from the server to the client to initiate progress\nreporting from the server.",
            .direction = .server_to_client,
            .Params = window.work_done_progress.CreateParams,
            .Result = ?void,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // A request to result a `CallHierarchyItem` in a document at a given position.
    // Can be used as an input to an incoming or outgoing call hierarchy.
    //
    // @since 3.16.0
    .{
        "textDocument/prepareCallHierarchy",
        RequestMetadata{
            .method = "textDocument/prepareCallHierarchy",
            .documentation = "A request to result a `CallHierarchyItem` in a document at a given position.\nCan be used as an input to an incoming or outgoing call hierarchy.\n\n@since 3.16.0",
            .direction = .client_to_server,
            .Params = call_hierarchy.PrepareParams,
            .Result = ?[]const call_hierarchy.Item,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = call_hierarchy.RegistrationOptions },
        },
    },
    // A request to resolve the incoming calls for a given `CallHierarchyItem`.
    //
    // @since 3.16.0
    .{
        "callHierarchy/incomingCalls",
        RequestMetadata{
            .method = "callHierarchy/incomingCalls",
            .documentation = "A request to resolve the incoming calls for a given `CallHierarchyItem`.\n\n@since 3.16.0",
            .direction = .client_to_server,
            .Params = call_hierarchy.IncomingCallsParams,
            .Result = ?[]const call_hierarchy.IncomingCall,
            .PartialResult = []const call_hierarchy.IncomingCall,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // A request to resolve the outgoing calls for a given `CallHierarchyItem`.
    //
    // @since 3.16.0
    .{
        "callHierarchy/outgoingCalls",
        RequestMetadata{
            .method = "callHierarchy/outgoingCalls",
            .documentation = "A request to resolve the outgoing calls for a given `CallHierarchyItem`.\n\n@since 3.16.0",
            .direction = .client_to_server,
            .Params = call_hierarchy.OutgoingCallsParams,
            .Result = ?[]const call_hierarchy.OutgoingCall,
            .PartialResult = []const call_hierarchy.OutgoingCall,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // @since 3.16.0
    .{
        "textDocument/semanticTokens/full",
        RequestMetadata{
            .method = "textDocument/semanticTokens/full",
            .documentation = "@since 3.16.0",
            .direction = .client_to_server,
            .Params = semantic_tokens.Params,
            .Result = ?semantic_tokens.Result,
            .PartialResult = semantic_tokens.Result.Partial,
            .ErrorData = null,
            .registration = .{ .method = "textDocument/semanticTokens", .Options = semantic_tokens.RegistrationOptions },
        },
    },
    // @since 3.16.0
    .{
        "textDocument/semanticTokens/full/delta",
        RequestMetadata{
            .method = "textDocument/semanticTokens/full/delta",
            .documentation = "@since 3.16.0",
            .direction = .client_to_server,
            .Params = semantic_tokens.Params.FullDelta,
            .Result = ?semantic_tokens.Result.FullDelta,
            .PartialResult = semantic_tokens.Result.FullDelta.Partial,
            .ErrorData = null,
            .registration = .{ .method = "textDocument/semanticTokens", .Options = semantic_tokens.RegistrationOptions },
        },
    },
    // @since 3.16.0
    .{
        "textDocument/semanticTokens/range",
        RequestMetadata{
            .method = "textDocument/semanticTokens/range",
            .documentation = "@since 3.16.0",
            .direction = .client_to_server,
            .Params = semantic_tokens.Params.Range,
            .Result = ?semantic_tokens.Result,
            .PartialResult = semantic_tokens.Result.Partial,
            .ErrorData = null,
            .registration = .{ .method = "textDocument/semanticTokens", .Options = null },
        },
    },
    // @since 3.16.0
    .{
        "workspace/semanticTokens/refresh",
        RequestMetadata{
            .method = "workspace/semanticTokens/refresh",
            .documentation = "@since 3.16.0",
            .direction = .server_to_client,
            .Params = null,
            .Result = ?void,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // A request to show a document. This request might open an
    // external program depending on the value of the URI to open.
    // For example a request to open `https://code.visualstudio.com/`
    // will very likely open the URI in a WEB browser.
    //
    // @since 3.16.0
    .{
        "window/showDocument",
        RequestMetadata{
            .method = "window/showDocument",
            .documentation = "A request to show a document. This request might open an\nexternal program depending on the value of the URI to open.\nFor example a request to open `https://code.visualstudio.com/`\nwill very likely open the URI in a WEB browser.\n\n@since 3.16.0",
            .direction = .server_to_client,
            .Params = window.show_document.Params,
            .Result = window.show_document.Result,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // A request to provide ranges that can be edited together.
    //
    // @since 3.16.0
    .{
        "textDocument/linkedEditingRange",
        RequestMetadata{
            .method = "textDocument/linkedEditingRange",
            .documentation = "A request to provide ranges that can be edited together.\n\n@since 3.16.0",
            .direction = .client_to_server,
            .Params = linked_editing_range.Params,
            .Result = ?linked_editing_range.Ranges,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = linked_editing_range.RegistrationOptions },
        },
    },
    // The will create files request is sent from the client to the server before files are actually
    // created as long as the creation is triggered from within the client.
    //
    // The request can return a `WorkspaceEdit` which will be applied to workspace before the
    // files are created. Hence the `WorkspaceEdit` can not manipulate the content of the file
    // to be created.
    //
    // @since 3.16.0
    .{
        "workspace/willCreateFiles",
        RequestMetadata{
            .method = "workspace/willCreateFiles",
            .documentation = "The will create files request is sent from the client to the server before files are actually\ncreated as long as the creation is triggered from within the client.\n\nThe request can return a `WorkspaceEdit` which will be applied to workspace before the\nfiles are created. Hence the `WorkspaceEdit` can not manipulate the content of the file\nto be created.\n\n@since 3.16.0",
            .direction = .client_to_server,
            .Params = workspace.CreateFilesParams,
            .Result = ?WorkspaceEdit,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = workspace.file_operation.RegistrationOptions },
        },
    },
    // The will rename files request is sent from the client to the server before files are actually
    // renamed as long as the rename is triggered from within the client.
    //
    // @since 3.16.0
    .{
        "workspace/willRenameFiles",
        RequestMetadata{
            .method = "workspace/willRenameFiles",
            .documentation = "The will rename files request is sent from the client to the server before files are actually\nrenamed as long as the rename is triggered from within the client.\n\n@since 3.16.0",
            .direction = .client_to_server,
            .Params = workspace.RenameFilesParams,
            .Result = ?WorkspaceEdit,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = workspace.file_operation.RegistrationOptions },
        },
    },
    // The did delete files notification is sent from the client to the server when
    // files were deleted from within the client.
    //
    // @since 3.16.0
    .{
        "workspace/willDeleteFiles",
        RequestMetadata{
            .method = "workspace/willDeleteFiles",
            .documentation = "The did delete files notification is sent from the client to the server when\nfiles were deleted from within the client.\n\n@since 3.16.0",
            .direction = .client_to_server,
            .Params = workspace.DeleteFilesParams,
            .Result = ?WorkspaceEdit,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = workspace.file_operation.RegistrationOptions },
        },
    },
    // A request to get the moniker of a symbol at a given text document position.
    // The request parameter is of type {@link TextDocumentPositionParams}.
    // The response is of type {@link Moniker Moniker[]} or `null`.
    .{
        "textDocument/moniker",
        RequestMetadata{
            .method = "textDocument/moniker",
            .documentation = "A request to get the moniker of a symbol at a given text document position.\nThe request parameter is of type {@link TextDocumentPositionParams}.\nThe response is of type {@link Moniker Moniker[]} or `null`.",
            .direction = .client_to_server,
            .Params = Moniker.Params,
            .Result = ?[]const Moniker,
            .PartialResult = []const Moniker,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = Moniker.RegistrationOptions },
        },
    },
    // A request to result a `TypeHierarchyItem` in a document at a given position.
    // Can be used as an input to a subtypes or supertypes type hierarchy.
    //
    // @since 3.17.0
    .{
        "textDocument/prepareTypeHierarchy",
        RequestMetadata{
            .method = "textDocument/prepareTypeHierarchy",
            .documentation = "A request to result a `TypeHierarchyItem` in a document at a given position.\nCan be used as an input to a subtypes or supertypes type hierarchy.\n\n@since 3.17.0",
            .direction = .client_to_server,
            .Params = type_hierarchy.PrepareParams,
            .Result = ?[]const type_hierarchy.Item,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = type_hierarchy.RegistrationOptions },
        },
    },
    // A request to resolve the supertypes for a given `TypeHierarchyItem`.
    //
    // @since 3.17.0
    .{
        "typeHierarchy/supertypes",
        RequestMetadata{
            .method = "typeHierarchy/supertypes",
            .documentation = "A request to resolve the supertypes for a given `TypeHierarchyItem`.\n\n@since 3.17.0",
            .direction = .client_to_server,
            .Params = type_hierarchy.SupertypesParams,
            .Result = ?[]const type_hierarchy.Item,
            .PartialResult = []const type_hierarchy.Item,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // A request to resolve the subtypes for a given `TypeHierarchyItem`.
    //
    // @since 3.17.0
    .{
        "typeHierarchy/subtypes",
        RequestMetadata{
            .method = "typeHierarchy/subtypes",
            .documentation = "A request to resolve the subtypes for a given `TypeHierarchyItem`.\n\n@since 3.17.0",
            .direction = .client_to_server,
            .Params = type_hierarchy.SubtypesParams,
            .Result = ?[]const type_hierarchy.Item,
            .PartialResult = []const type_hierarchy.Item,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // A request to provide inline values in a document. The request's parameter is of
    // type {@link InlineValueParams}, the response is of type
    // {@link InlineValue InlineValue[]} or a Thenable that resolves to such.
    //
    // @since 3.17.0
    .{
        "textDocument/inlineValue",
        RequestMetadata{
            .method = "textDocument/inlineValue",
            .documentation = "A request to provide inline values in a document. The request's parameter is of\ntype {@link InlineValueParams}, the response is of type\n{@link InlineValue InlineValue[]} or a Thenable that resolves to such.\n\n@since 3.17.0",
            .direction = .client_to_server,
            .Params = InlineValue.Params,
            .Result = ?[]const InlineValue,
            .PartialResult = []const InlineValue,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = InlineValue.RegistrationOptions },
        },
    },
    // @since 3.17.0
    .{
        "workspace/inlineValue/refresh",
        RequestMetadata{
            .method = "workspace/inlineValue/refresh",
            .documentation = "@since 3.17.0",
            .direction = .server_to_client,
            .Params = null,
            .Result = ?void,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // A request to provide inlay hints in a document. The request's parameter is of
    // type {@link InlayHintsParams}, the response is of type
    // {@link InlayHint InlayHint[]} or a Thenable that resolves to such.
    //
    // @since 3.17.0
    .{
        "textDocument/inlayHint",
        RequestMetadata{
            .method = "textDocument/inlayHint",
            .documentation = "A request to provide inlay hints in a document. The request's parameter is of\ntype {@link InlayHintsParams}, the response is of type\n{@link InlayHint InlayHint[]} or a Thenable that resolves to such.\n\n@since 3.17.0",
            .direction = .client_to_server,
            .Params = InlayHint.Params,
            .Result = ?[]const InlayHint,
            .PartialResult = []const InlayHint,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = InlayHint.RegistrationOptions },
        },
    },
    // A request to resolve additional properties for an inlay hint.
    // The request's parameter is of type {@link InlayHint}, the response is
    // of type {@link InlayHint} or a Thenable that resolves to such.
    //
    // @since 3.17.0
    .{
        "inlayHint/resolve",
        RequestMetadata{
            .method = "inlayHint/resolve",
            .documentation = "A request to resolve additional properties for an inlay hint.\nThe request's parameter is of type {@link InlayHint}, the response is\nof type {@link InlayHint} or a Thenable that resolves to such.\n\n@since 3.17.0",
            .direction = .client_to_server,
            .Params = InlayHint,
            .Result = InlayHint,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // @since 3.17.0
    .{
        "workspace/inlayHint/refresh",
        RequestMetadata{
            .method = "workspace/inlayHint/refresh",
            .documentation = "@since 3.17.0",
            .direction = .server_to_client,
            .Params = null,
            .Result = ?void,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // The document diagnostic request definition.
    //
    // @since 3.17.0
    .{
        "textDocument/diagnostic",
        RequestMetadata{
            .method = "textDocument/diagnostic",
            .documentation = "The document diagnostic request definition.\n\n@since 3.17.0",
            .direction = .client_to_server,
            .Params = document_diagnostic.Params,
            .Result = document_diagnostic.Report,
            .PartialResult = document_diagnostic.Report.PartialResult,
            .ErrorData = Diagnostic.ServerCancellationData,
            .registration = .{ .method = null, .Options = Diagnostic.RegistrationOptions },
        },
    },
    // The workspace diagnostic request definition.
    //
    // @since 3.17.0
    .{
        "workspace/diagnostic",
        RequestMetadata{
            .method = "workspace/diagnostic",
            .documentation = "The workspace diagnostic request definition.\n\n@since 3.17.0",
            .direction = .client_to_server,
            .Params = workspace.diagnostic.Params,
            .Result = workspace.diagnostic.Report,
            .PartialResult = workspace.diagnostic.Report.PartialResult,
            .ErrorData = Diagnostic.ServerCancellationData,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // The diagnostic refresh request definition.
    //
    // @since 3.17.0
    .{
        "workspace/diagnostic/refresh",
        RequestMetadata{
            .method = "workspace/diagnostic/refresh",
            .documentation = "The diagnostic refresh request definition.\n\n@since 3.17.0",
            .direction = .server_to_client,
            .Params = null,
            .Result = ?void,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // A request to provide inline completions in a document. The request's parameter is of
    // type {@link InlineCompletionParams}, the response is of type
    // {@link InlineCompletion InlineCompletion[]} or a Thenable that resolves to such.
    //
    // @since 3.18.0
    // @proposed
    .{
        "textDocument/inlineCompletion",
        RequestMetadata{
            .method = "textDocument/inlineCompletion",
            .documentation = "A request to provide inline completions in a document. The request's parameter is of\ntype {@link InlineCompletionParams}, the response is of type\n{@link InlineCompletion InlineCompletion[]} or a Thenable that resolves to such.\n\n@since 3.18.0\n@proposed",
            .direction = .client_to_server,
            .Params = inline_completion.Params,
            .Result = ?inline_completion.Result,
            .PartialResult = []const inline_completion.Item,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = inline_completion.RegistrationOptions },
        },
    },
    // The `workspace/textDocumentContent` request is sent from the client to the
    // server to request the content of a text document.
    //
    // @since 3.18.0
    // @proposed
    .{
        "workspace/textDocumentContent",
        RequestMetadata{
            .method = "workspace/textDocumentContent",
            .documentation = "The `workspace/textDocumentContent` request is sent from the client to the\nserver to request the content of a text document.\n\n@since 3.18.0\n@proposed",
            .direction = .client_to_server,
            .Params = workspace.text_document_content.Params,
            .Result = workspace.text_document_content.Result,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = workspace.text_document_content.RegistrationOptions },
        },
    },
    // The `workspace/textDocumentContent` request is sent from the server to the client to refresh
    // the content of a specific text document.
    //
    // @since 3.18.0
    // @proposed
    .{
        "workspace/textDocumentContent/refresh",
        RequestMetadata{
            .method = "workspace/textDocumentContent/refresh",
            .documentation = "The `workspace/textDocumentContent` request is sent from the server to the client to refresh\nthe content of a specific text document.\n\n@since 3.18.0\n@proposed",
            .direction = .server_to_client,
            .Params = workspace.text_document_content.RefreshParams,
            .Result = ?void,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // The `client/registerCapability` request is sent from the server to the client to register a new capability
    // handler on the client side.
    .{
        "client/registerCapability",
        RequestMetadata{
            .method = "client/registerCapability",
            .documentation = "The `client/registerCapability` request is sent from the server to the client to register a new capability\nhandler on the client side.",
            .direction = .server_to_client,
            .Params = Registration.Params,
            .Result = ?void,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // The `client/unregisterCapability` request is sent from the server to the client to unregister a previously registered capability
    // handler on the client side.
    .{
        "client/unregisterCapability",
        RequestMetadata{
            .method = "client/unregisterCapability",
            .documentation = "The `client/unregisterCapability` request is sent from the server to the client to unregister a previously registered capability\nhandler on the client side.",
            .direction = .server_to_client,
            .Params = Unregistration.Params,
            .Result = ?void,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // The initialize request is sent from the client to the server.
    // It is sent once as the request after starting up the server.
    // The requests parameter is of type {@link InitializeParams}
    // the response if of type {@link InitializeResult} of a Thenable that
    // resolves to such.
    .{
        "initialize",
        RequestMetadata{
            .method = "initialize",
            .documentation = "The initialize request is sent from the client to the server.\nIt is sent once as the request after starting up the server.\nThe requests parameter is of type {@link InitializeParams}\nthe response if of type {@link InitializeResult} of a Thenable that\nresolves to such.",
            .direction = .client_to_server,
            .Params = InitializeParams,
            .Result = InitializeResult,
            .PartialResult = null,
            .ErrorData = InitializeError,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // A shutdown request is sent from the client to the server.
    // It is sent once when the client decides to shutdown the
    // server. The only notification that is sent after a shutdown request
    // is the exit event.
    .{
        "shutdown",
        RequestMetadata{
            .method = "shutdown",
            .documentation = "A shutdown request is sent from the client to the server.\nIt is sent once when the client decides to shutdown the\nserver. The only notification that is sent after a shutdown request\nis the exit event.",
            .direction = .client_to_server,
            .Params = null,
            .Result = ?void,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // The show message request is sent from the server to the client to show a message
    // and a set of options actions to the user.
    .{
        "window/showMessageRequest",
        RequestMetadata{
            .method = "window/showMessageRequest",
            .documentation = "The show message request is sent from the server to the client to show a message\nand a set of options actions to the user.",
            .direction = .server_to_client,
            .Params = window.show_message_request.Params,
            .Result = ?window.show_message_request.Item,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // A document will save request is sent from the client to the server before
    // the document is actually saved. The request can return an array of TextEdits
    // which will be applied to the text document before it is saved. Please note that
    // clients might drop results if computing the text edits took too long or if a
    // server constantly fails on this request. This is done to keep the save fast and
    // reliable.
    .{
        "textDocument/willSaveWaitUntil",
        RequestMetadata{
            .method = "textDocument/willSaveWaitUntil",
            .documentation = "A document will save request is sent from the client to the server before\nthe document is actually saved. The request can return an array of TextEdits\nwhich will be applied to the text document before it is saved. Please note that\nclients might drop results if computing the text edits took too long or if a\nserver constantly fails on this request. This is done to keep the save fast and\nreliable.",
            .direction = .client_to_server,
            .Params = TextDocument.WillSaveParams,
            .Result = ?[]const TextEdit,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = TextDocument.RegistrationOptions },
        },
    },
    // Request to request completion at a given text document position. The request's
    // parameter is of type {@link TextDocumentPosition} the response
    // is of type {@link CompletionItem CompletionItem[]} or {@link CompletionList}
    // or a Thenable that resolves to such.
    //
    // The request can delay the computation of the {@link CompletionItem.detail `detail`}
    // and {@link CompletionItem.documentation `documentation`} properties to the `completionItem/resolve`
    // request. However, properties that are needed for the initial sorting and filtering, like `sortText`,
    // `filterText`, `insertText`, and `textEdit`, must not be changed during resolve.
    .{
        "textDocument/completion",
        RequestMetadata{
            .method = "textDocument/completion",
            .documentation = "Request to request completion at a given text document position. The request's\nparameter is of type {@link TextDocumentPosition} the response\nis of type {@link CompletionItem CompletionItem[]} or {@link CompletionList}\nor a Thenable that resolves to such.\n\nThe request can delay the computation of the {@link CompletionItem.detail `detail`}\nand {@link CompletionItem.documentation `documentation`} properties to the `completionItem/resolve`\nrequest. However, properties that are needed for the initial sorting and filtering, like `sortText`,\n`filterText`, `insertText`, and `textEdit`, must not be changed during resolve.",
            .direction = .client_to_server,
            .Params = completion.Params,
            .Result = ?completion.Result,
            .PartialResult = []const completion.Item,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = completion.RegistrationOptions },
        },
    },
    // Request to resolve additional information for a given completion item.The request's
    // parameter is of type {@link CompletionItem} the response
    // is of type {@link CompletionItem} or a Thenable that resolves to such.
    .{
        "completionItem/resolve",
        RequestMetadata{
            .method = "completionItem/resolve",
            .documentation = "Request to resolve additional information for a given completion item.The request's\nparameter is of type {@link CompletionItem} the response\nis of type {@link CompletionItem} or a Thenable that resolves to such.",
            .direction = .client_to_server,
            .Params = completion.Item,
            .Result = completion.Item,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // Request to request hover information at a given text document position. The request's
    // parameter is of type {@link TextDocumentPosition} the response is of
    // type {@link Hover} or a Thenable that resolves to such.
    .{
        "textDocument/hover",
        RequestMetadata{
            .method = "textDocument/hover",
            .documentation = "Request to request hover information at a given text document position. The request's\nparameter is of type {@link TextDocumentPosition} the response is of\ntype {@link Hover} or a Thenable that resolves to such.",
            .direction = .client_to_server,
            .Params = Hover.Params,
            .Result = ?Hover,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = Hover.RegistrationOptions },
        },
    },
    .{
        "textDocument/signatureHelp",
        RequestMetadata{
            .method = "textDocument/signatureHelp",
            .documentation = null,
            .direction = .client_to_server,
            .Params = SignatureHelp.Params,
            .Result = ?SignatureHelp,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = SignatureHelp.RegistrationOptions },
        },
    },
    // A request to resolve the definition location of a symbol at a given text
    // document position. The request's parameter is of type {@link TextDocumentPosition}
    // the response is of either type {@link Definition} or a typed array of
    // {@link DefinitionLink} or a Thenable that resolves to such.
    .{
        "textDocument/definition",
        RequestMetadata{
            .method = "textDocument/definition",
            .documentation = "A request to resolve the definition location of a symbol at a given text\ndocument position. The request's parameter is of type {@link TextDocumentPosition}\nthe response is of either type {@link Definition} or a typed array of\n{@link DefinitionLink} or a Thenable that resolves to such.",
            .direction = .client_to_server,
            .Params = Definition.Params,
            .Result = ?Definition.Result,
            .PartialResult = Definition.PartialResult,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = Definition.RegistrationOptions },
        },
    },
    // A request to resolve project-wide references for the symbol denoted
    // by the given text document position. The request's parameter is of
    // type {@link ReferenceParams} the response is of type
    // {@link Location Location[]} or a Thenable that resolves to such.
    .{
        "textDocument/references",
        RequestMetadata{
            .method = "textDocument/references",
            .documentation = "A request to resolve project-wide references for the symbol denoted\nby the given text document position. The request's parameter is of\ntype {@link ReferenceParams} the response is of type\n{@link Location Location[]} or a Thenable that resolves to such.",
            .direction = .client_to_server,
            .Params = reference.Params,
            .Result = ?[]const Location,
            .PartialResult = []const Location,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = reference.RegistrationOptions },
        },
    },
    // Request to resolve a {@link DocumentHighlight} for a given
    // text document position. The request's parameter is of type {@link TextDocumentPosition}
    // the request response is an array of type {@link DocumentHighlight}
    // or a Thenable that resolves to such.
    .{
        "textDocument/documentHighlight",
        RequestMetadata{
            .method = "textDocument/documentHighlight",
            .documentation = "Request to resolve a {@link DocumentHighlight} for a given\ntext document position. The request's parameter is of type {@link TextDocumentPosition}\nthe request response is an array of type {@link DocumentHighlight}\nor a Thenable that resolves to such.",
            .direction = .client_to_server,
            .Params = DocumentHighlight.Params,
            .Result = ?[]const DocumentHighlight,
            .PartialResult = []const DocumentHighlight,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = DocumentHighlight.RegistrationOptions },
        },
    },
    // A request to list all symbols found in a given text document. The request's
    // parameter is of type {@link TextDocumentIdentifier} the
    // response is of type {@link SymbolInformation SymbolInformation[]} or a Thenable
    // that resolves to such.
    .{
        "textDocument/documentSymbol",
        RequestMetadata{
            .method = "textDocument/documentSymbol",
            .documentation = "A request to list all symbols found in a given text document. The request's\nparameter is of type {@link TextDocumentIdentifier} the\nresponse is of type {@link SymbolInformation SymbolInformation[]} or a Thenable\nthat resolves to such.",
            .direction = .client_to_server,
            .Params = DocumentSymbol.Params,
            .Result = ?DocumentSymbol.Result,
            .PartialResult = DocumentSymbol.Result,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = DocumentSymbol.RegistrationOptions },
        },
    },
    // A request to provide commands for the given text document and range.
    .{
        "textDocument/codeAction",
        RequestMetadata{
            .method = "textDocument/codeAction",
            .documentation = "A request to provide commands for the given text document and range.",
            .direction = .client_to_server,
            .Params = CodeAction.Params,
            .Result = ?[]const CodeAction.Result,
            .PartialResult = []const CodeAction.Result,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = CodeAction.RegistrationOptions },
        },
    },
    // Request to resolve additional information for a given code action.The request's
    // parameter is of type {@link CodeAction} the response
    // is of type {@link CodeAction} or a Thenable that resolves to such.
    .{
        "codeAction/resolve",
        RequestMetadata{
            .method = "codeAction/resolve",
            .documentation = "Request to resolve additional information for a given code action.The request's\nparameter is of type {@link CodeAction} the response\nis of type {@link CodeAction} or a Thenable that resolves to such.",
            .direction = .client_to_server,
            .Params = CodeAction,
            .Result = CodeAction,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // A request to list project-wide symbols matching the query string given
    // by the {@link WorkspaceSymbolParams}. The response is
    // of type {@link SymbolInformation SymbolInformation[]} or a Thenable that
    // resolves to such.
    //
    // @since 3.17.0 - support for WorkspaceSymbol in the returned data. Clients
    //  need to advertise support for WorkspaceSymbols via the client capability
    //  `workspace.symbol.resolveSupport`.
    //
    .{
        "workspace/symbol",
        RequestMetadata{
            .method = "workspace/symbol",
            .documentation = "A request to list project-wide symbols matching the query string given\nby the {@link WorkspaceSymbolParams}. The response is\nof type {@link SymbolInformation SymbolInformation[]} or a Thenable that\nresolves to such.\n\n@since 3.17.0 - support for WorkspaceSymbol in the returned data. Clients\n need to advertise support for WorkspaceSymbols via the client capability\n `workspace.symbol.resolveSupport`.\n",
            .direction = .client_to_server,
            .Params = workspace.Symbol.Params,
            .Result = ?workspace.Symbol.Result,
            .PartialResult = workspace.Symbol.Result,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = workspace.Symbol.RegistrationOptions },
        },
    },
    // A request to resolve the range inside the workspace
    // symbol's location.
    //
    // @since 3.17.0
    .{
        "workspaceSymbol/resolve",
        RequestMetadata{
            .method = "workspaceSymbol/resolve",
            .documentation = "A request to resolve the range inside the workspace\nsymbol's location.\n\n@since 3.17.0",
            .direction = .client_to_server,
            .Params = workspace.Symbol,
            .Result = workspace.Symbol,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // A request to provide code lens for the given text document.
    .{
        "textDocument/codeLens",
        RequestMetadata{
            .method = "textDocument/codeLens",
            .documentation = "A request to provide code lens for the given text document.",
            .direction = .client_to_server,
            .Params = code_lens.Params,
            .Result = ?[]const code_lens.Response,
            .PartialResult = []const code_lens.Response,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = code_lens.RegistrationOptions },
        },
    },
    // A request to resolve a command for a given code lens.
    .{
        "codeLens/resolve",
        RequestMetadata{
            .method = "codeLens/resolve",
            .documentation = "A request to resolve a command for a given code lens.",
            .direction = .client_to_server,
            .Params = code_lens.Response,
            .Result = code_lens.Response,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // A request to refresh all code actions
    //
    // @since 3.16.0
    .{
        "workspace/codeLens/refresh",
        RequestMetadata{
            .method = "workspace/codeLens/refresh",
            .documentation = "A request to refresh all code actions\n\n@since 3.16.0",
            .direction = .server_to_client,
            .Params = null,
            .Result = ?void,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // A request to provide document links
    .{
        "textDocument/documentLink",
        RequestMetadata{
            .method = "textDocument/documentLink",
            .documentation = "A request to provide document links",
            .direction = .client_to_server,
            .Params = DocumentLink.Params,
            .Result = ?[]const DocumentLink,
            .PartialResult = []const DocumentLink,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = DocumentLink.RegistrationOptions },
        },
    },
    // Request to resolve additional information for a given document link. The request's
    // parameter is of type {@link DocumentLink} the response
    // is of type {@link DocumentLink} or a Thenable that resolves to such.
    .{
        "documentLink/resolve",
        RequestMetadata{
            .method = "documentLink/resolve",
            .documentation = "Request to resolve additional information for a given document link. The request's\nparameter is of type {@link DocumentLink} the response\nis of type {@link DocumentLink} or a Thenable that resolves to such.",
            .direction = .client_to_server,
            .Params = DocumentLink,
            .Result = DocumentLink,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // A request to format a whole document.
    .{
        "textDocument/formatting",
        RequestMetadata{
            .method = "textDocument/formatting",
            .documentation = "A request to format a whole document.",
            .direction = .client_to_server,
            .Params = document_formatting.Params,
            .Result = ?[]const TextEdit,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = document_formatting.RegistrationOptions },
        },
    },
    // A request to format a range in a document.
    .{
        "textDocument/rangeFormatting",
        RequestMetadata{
            .method = "textDocument/rangeFormatting",
            .documentation = "A request to format a range in a document.",
            .direction = .client_to_server,
            .Params = document_range_formatting.Params,
            .Result = ?[]const TextEdit,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = document_range_formatting.RegistrationOptions },
        },
    },
    // A request to format ranges in a document.
    //
    // @since 3.18.0
    // @proposed
    .{
        "textDocument/rangesFormatting",
        RequestMetadata{
            .method = "textDocument/rangesFormatting",
            .documentation = "A request to format ranges in a document.\n\n@since 3.18.0\n@proposed",
            .direction = .client_to_server,
            .Params = document_ranges_formatting.Params,
            .Result = ?[]const TextEdit,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = document_range_formatting.RegistrationOptions },
        },
    },
    // A request to format a document on type.
    .{
        "textDocument/onTypeFormatting",
        RequestMetadata{
            .method = "textDocument/onTypeFormatting",
            .documentation = "A request to format a document on type.",
            .direction = .client_to_server,
            .Params = document_on_type_formatting.Params,
            .Result = ?[]const TextEdit,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = document_on_type_formatting.RegistrationOptions },
        },
    },
    // A request to rename a symbol.
    .{
        "textDocument/rename",
        RequestMetadata{
            .method = "textDocument/rename",
            .documentation = "A request to rename a symbol.",
            .direction = .client_to_server,
            .Params = rename.Params,
            .Result = ?WorkspaceEdit,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = rename.RegistrationOptions },
        },
    },
    // A request to test and perform the setup necessary for a rename.
    //
    // @since 3.16 - support for default behavior
    .{
        "textDocument/prepareRename",
        RequestMetadata{
            .method = "textDocument/prepareRename",
            .documentation = "A request to test and perform the setup necessary for a rename.\n\n@since 3.16 - support for default behavior",
            .direction = .client_to_server,
            .Params = prepare_rename.Params,
            .Result = ?prepare_rename.Result,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
    // A request send from the client to the server to execute a command. The request might return
    // a workspace edit which the client will apply to the workspace.
    .{
        "workspace/executeCommand",
        RequestMetadata{
            .method = "workspace/executeCommand",
            .documentation = "A request send from the client to the server to execute a command. The request might return\na workspace edit which the client will apply to the workspace.",
            .direction = .client_to_server,
            .Params = workspace.execute_command.Params,
            .Result = ?LSPAny,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = workspace.execute_command.RegistrationOptions },
        },
    },
    // A request sent from the server to the client to modified certain resources.
    .{
        "workspace/applyEdit",
        RequestMetadata{
            .method = "workspace/applyEdit",
            .documentation = "A request sent from the server to the client to modified certain resources.",
            .direction = .server_to_client,
            .Params = workspace.apply_workspace_edit.Params,
            .Result = workspace.apply_workspace_edit.Result,
            .PartialResult = null,
            .ErrorData = null,
            .registration = .{ .method = null, .Options = null },
        },
    },
});
