//! Transport-agnostic [JSON-RPC 2.0](https://www.jsonrpc.org/specification) message types,
//! Base Protocol (`Content-Length`) framing, and a pluggable `Transport` abstraction.
//!
//! This module has no knowledge of the Language Server Protocol; it only implements the
//! generic JSON-RPC envelope and wire framing that LSP (and other JSON-RPC based protocols)
//! are built on top of. See `lsp` for the LSP-specific layer built on top of this module.

const std = @import("std");

/// A JSON-RPC request/response id: either a number or a string.
///
/// This is also reused by the LSP-generated `types` module (`types.ID`), since the LSP
/// specification's id types are defined identically to plain JSON-RPC ids.
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

/// See https://www.jsonrpc.org/specification
pub const JsonRPCMessage = union(enum) {
    request: Request,
    notification: Notification,
    response: Response,

    pub const ID = json_rpc.ID;

    pub const Request = struct {
        comptime jsonrpc: []const u8 = "2.0",
        /// The request id.
        id: json_rpc.ID,
        /// The method to be invoked.
        method: []const u8,
        /// The requests's params. The `std.json.Value` can only be `.null`, `.array` or `.object`.
        ///
        /// `params == null` means that the was no `"params"` field. `params == .null` means that the `"params"` field was set to `null`.
        params: ?std.json.Value,
    };

    pub const Notification = struct {
        comptime jsonrpc: []const u8 = "2.0",
        /// The method to be invoked.
        method: []const u8,
        /// The notification's params. The `std.json.Value` can only be `.null`, `.array` or `.object`.
        ///
        /// `params == null` means that the was no `"params"` field. `params == .null` means that the `"params"` field was set to `null`.
        params: ?std.json.Value,
    };

    pub const Response = struct {
        comptime jsonrpc: []const u8 = "2.0",
        /// The request id.
        ///
        /// It must be the same as the value of the `id` member in the `Request` object.
        /// If there was an error in detecting the id in the `Request` object (e.g. `Error.Code.parse_error`/`Error.Code.invalid_request`), it must be `null`.
        id: ?json_rpc.ID,
        result_or_error: union(enum) {
            /// The result of a request.
            result: ?std.json.Value,
            /// The error object in case a request fails.
            @"error": Error,
        },

        pub const Error = struct {
            /// A number indicating the error type that occurred.
            code: Code,
            /// A string providing a short description of the error.
            message: []const u8,
            /// A primitive or structured value that contains additional
            /// information about the error. Can be omitted.
            data: ?std.json.Value = null,

            /// The error codes from and including -32768 to -32000 are reserved for pre-defined errors. Any code within this range, but not defined explicitly below is reserved for future use.
            ///
            /// The remainder of the space is available for application defined errors.
            pub const Code = enum(i64) {
                /// Invalid JSON was received by the server. An error occurred on the server while parsing the JSON text.
                parse_error = -32700,
                /// The JSON sent is not a valid Request object.
                invalid_request = -32600,
                /// The method does not exist / is not available.
                method_not_found = -32601,
                /// Invalid method parameter(s).
                invalid_params = -32602,
                /// Internal JSON-RPC error.
                internal_error = -32603,

                /// -32000 to -32099 are reserved for implementation-defined server-errors.
                _,

                pub fn jsonStringify(code: Code, stream: anytype) @TypeOf(stream.*).Error!void {
                    try stream.write(@intFromEnum(code));
                }
            };
        };

        pub fn jsonStringify(response: Response, stream: anytype) @TypeOf(stream.*).Error!void {
            try stream.beginObject();

            try stream.objectField("jsonrpc");
            try stream.write("2.0");

            if (response.id) |id| {
                try stream.objectField("id");
                try stream.write(id);
            } else if (stream.options.emit_null_optional_fields) {
                try stream.objectField("id");
                try stream.write(null);
            }

            switch (response.result_or_error) {
                inline else => |value, tag| {
                    try stream.objectField(@tagName(tag));
                    try stream.write(value);
                },
            }

            try stream.endObject();
        }

        pub const jsonParse = {};
        pub const jsonParseFromValue = {};
    };

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!JsonRPCMessage {
        if (try source.next() != .object_begin)
            return error.UnexpectedToken;

        var fields: Fields = .{};

        while (true) {
            const field_name = blk: {
                const name_token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
                const maybe_field_name = switch (name_token) {
                    .string, .allocated_string => |slice| std.meta.stringToEnum(std.meta.FieldEnum(Fields), slice),
                    .object_end => break, // No more fields.
                    else => return error.UnexpectedToken,
                };

                switch (name_token) {
                    .string => {},
                    .allocated_string => |slice| allocator.free(slice),
                    else => unreachable,
                }

                break :blk maybe_field_name orelse {
                    if (options.ignore_unknown_fields) {
                        try source.skipValue();
                        continue;
                    } else {
                        return error.UnknownField;
                    }
                };
            };

            // check for contradicting fields
            switch (field_name) {
                .jsonrpc => {},
                .id => {},
                .method, .params => {
                    const is_result_set = if (fields.result) |result| result != .null else false;
                    if (is_result_set or fields.@"error" != null) {
                        return error.UnexpectedToken;
                    }
                },
                .result => {
                    if (fields.@"error" != null) {
                        // Allows { "error": {...}, "result": null }
                        switch (try source.peekNextTokenType()) {
                            .null => {
                                std.debug.assert(try source.next() == .null);
                                continue;
                            },
                            else => return error.UnexpectedToken,
                        }
                    }
                },
                .@"error" => {
                    const is_result_set = if (fields.result) |result| result != .null else false;
                    if (is_result_set) {
                        return error.UnexpectedToken;
                    }
                },
            }

            switch (field_name) {
                inline else => |comptime_field_name| {
                    if (comptime_field_name == field_name) {
                        if (@field(fields, @tagName(comptime_field_name))) |_| {
                            switch (options.duplicate_field_behavior) {
                                .use_first => {
                                    _ = try Fields.parse(comptime_field_name, allocator, source, options);
                                    continue;
                                },
                                .@"error" => return error.DuplicateField,
                                .use_last => {},
                            }
                        }
                        @field(fields, @tagName(comptime_field_name)) = try Fields.parse(comptime_field_name, allocator, source, options);
                    }
                },
            }
        }

        return try fields.toMessage();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) std.json.ParseFromValueError!JsonRPCMessage {
        if (source != .object) return error.UnexpectedToken;

        var fields: Fields = .{};

        for (source.object.keys(), source.object.values()) |field_name, field_source| {
            inline for (std.meta.fields(Fields)) |field| {
                const field_enum = comptime @field(std.meta.FieldEnum(Fields), field.name);
                if (std.mem.eql(u8, field.name, field_name)) {
                    @field(fields, field.name) = try Fields.parseFromValue(field_enum, allocator, field_source, options);
                    break;
                }
            } else {
                // Didn't match anything.
                if (!options.ignore_unknown_fields)
                    return error.UnknownField;
            }
        }

        return try fields.toMessage();
    }

    pub fn jsonStringify(message: JsonRPCMessage, stream: anytype) @TypeOf(stream.*).Error!void {
        switch (message) {
            inline else => |item| try stream.write(item),
        }
    }

    /// Method names that begin with the word rpc followed by a period character (U+002E or ASCII 46) are reserved for rpc-internal methods and extensions and MUST NOT be used for anything else.
    pub fn isReservedMethodName(name: []const u8) bool {
        return std.mem.startsWith(u8, name, "rpc.");
    }

    test isReservedMethodName {
        try std.testing.expect(isReservedMethodName("rpc.foo"));
        try std.testing.expect(!isReservedMethodName("textDocument/completion"));
    }

    /// Exposed so that other parsers (e.g. `lsp.Message`'s incremental parser) can reuse the same
    /// field-name enum via `std.meta.FieldEnum(JsonRPCMessage.Fields)` without duplicating it.
    pub const Fields = struct {
        jsonrpc: ?[]const u8 = null,
        method: ?[]const u8 = null,
        id: ?json_rpc.ID = null,
        params: ?std.json.Value = null,
        result: ?std.json.Value = null,
        @"error": ?Response.Error = null,

        fn parse(
            comptime field: std.meta.FieldEnum(@This()),
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!@FieldType(@This(), @tagName(field)) {
            return switch (field) {
                .jsonrpc, .method => try std.json.innerParse([]const u8, allocator, source, options),
                .id => try std.json.innerParse(?JsonRPCMessage.ID, allocator, source, options),
                .params => switch (try source.peekNextTokenType()) {
                    .null => {
                        std.debug.assert(try source.next() == .null);
                        return .null;
                    },
                    .object_begin, .array_begin => try std.json.Value.jsonParse(allocator, source, options),
                    else => return error.UnexpectedToken, // "params" field must be null/object/array
                },
                .result => try std.json.Value.jsonParse(allocator, source, options),
                .@"error" => try std.json.innerParse(Response.Error, allocator, source, options),
            };
        }

        fn parseFromValue(
            comptime field: std.meta.FieldEnum(@This()),
            allocator: std.mem.Allocator,
            source: std.json.Value,
            options: std.json.ParseOptions,
        ) std.json.ParseFromValueError!@FieldType(@This(), @tagName(field)) {
            return switch (field) {
                .jsonrpc, .method => try std.json.innerParseFromValue([]const u8, allocator, source, options),
                .id => try std.json.innerParseFromValue(?JsonRPCMessage.ID, allocator, source, options),
                .params => switch (source) {
                    .null, .object, .array => source,
                    else => return error.UnexpectedToken, // "params" field must be null/object/array
                },
                .result => source,
                .@"error" => try std.json.innerParseFromValue(Response.Error, allocator, source, options),
            };
        }

        fn toMessage(self: Fields) !JsonRPCMessage {
            const jsonrpc = self.jsonrpc orelse
                return error.MissingField;
            if (!std.mem.eql(u8, jsonrpc, "2.0"))
                return error.UnexpectedToken; // the "jsonrpc" field must be "2.0"

            if (self.method) |method_val| {
                if (self.result != null or self.@"error" != null) {
                    return error.UnexpectedToken; // the "method" field indicates a request or notification which can't have the "result" or "error" field
                }
                if (self.params) |params_val| {
                    switch (params_val) {
                        .null, .object, .array => {},
                        else => unreachable,
                    }
                }

                if (self.id) |id_val| {
                    return .{
                        .request = .{
                            .method = method_val,
                            .params = self.params,
                            .id = id_val,
                        },
                    };
                } else {
                    return .{
                        .notification = .{
                            .method = method_val,
                            .params = self.params,
                        },
                    };
                }
            } else {
                if (self.@"error" != null) {
                    const is_result_set = if (self.result) |result| result != .null else false;
                    if (is_result_set)
                        return error.UnexpectedToken; // the "result" and "error" fields can't both be set
                } else {
                    const is_result_set = self.result != null;
                    if (!is_result_set)
                        return error.MissingField;
                }

                return .{
                    .response = .{
                        .id = self.id,
                        .result_or_error = if (self.@"error") |err|
                            .{ .@"error" = err }
                        else
                            .{ .result = self.result },
                    },
                };
            }
        }
    };

    test {
        try testParseExpectedError(
            \\5
        ,
            error.UnexpectedToken,
            error.UnexpectedToken,
            .{},
        );
        try testParseExpectedError(
            \\{}
        ,
            error.MissingField,
            error.MissingField,
            .{},
        );
        try testParseExpectedError(
            \\{"method": "foo", "params": null}
        ,
            error.MissingField,
            error.MissingField,
            .{},
        );
        try testParseExpectedError(
            \\{"jsonrpc": "1.0", "method": "foo", "params": null}
        ,
            error.UnexpectedToken,
            error.UnexpectedToken,
            .{},
        );
        try testParseExpectedError(
            \\{
        ,
            error.UnexpectedEndOfInput,
            error.UnexpectedToken,
            .{},
        );
    }

    test Request {
        try testParse(
            \\{"jsonrpc": "2.0", "id": 1, "method": "Die", "params": null}
        , .{
            .request = .{
                .id = .{ .number = 1 },
                .method = "Die",
                .params = .null,
            },
        }, .{});
        try testParse(
            \\{"id": "Würde", "method": "des", "params": null, "jsonrpc": "2.0"}
        , .{
            .request = .{
                .id = .{ .string = "Würde" },
                .method = "des",
                .params = .null,
            },
        }, .{});
        try testParse(
            \\{"method": "ist", "params": {}, "jsonrpc": "2.0", "id": "Menschen"}
        , .{
            .request = .{
                .id = .{ .string = "Menschen" },
                .method = "ist",
                .params = .{ .object = undefined },
            },
        }, .{});
        try testParse(
            \\{"method": ".", "jsonrpc": "2.0", "id": "unantastbar"}
        , .{
            .request = .{
                .id = .{ .string = "unantastbar" },
                .method = ".",
                .params = null,
            },
        }, .{});
    }

    test Notification {
        try testParse(
            \\{"jsonrpc": "2.0", "method": "foo", "params": null}
        , .{
            .notification = .{
                .method = "foo",
                .params = .null,
            },
        }, .{});
        try testParse(
            \\{"method": "bar", "params": null, "jsonrpc": "2.0"}
        , .{
            .notification = .{
                .method = "bar",
                .params = .null,
            },
        }, .{});
        try testParse(
            \\{"params": [], "method": "baz", "jsonrpc": "2.0"}
        , .{
            .notification = .{
                .method = "baz",
                .params = .{ .array = undefined },
            },
        }, .{});
        try testParse(
            \\{"method": "booze?", "jsonrpc": "2.0"}
        , .{
            .notification = .{
                .method = "booze?",
                .params = null,
            },
        }, .{});
    }

    test "Notification allow setting the 'id' field to null" {
        try testParse(
            \\{"jsonrpc": "2.0", "id": null, "method": "foo", "params": null}
        , .{
            .notification = .{
                .method = "foo",
                .params = .null,
            },
        }, .{});
    }

    test Response {
        try testParse(
            \\{"jsonrpc": "2.0", "id": 1, "result": null}
        , .{ .response = .{
            .id = .{ .number = 1 },
            .result_or_error = .{ .result = .null },
        } }, .{});

        try testParseExpectedError(
            \\{"jsonrpc": "2.0", "id": 1}
        ,
            error.MissingField,
            error.MissingField,
            .{},
        );

        // TODO this should be `.data = .null`
        try testParse(
            \\{"id": "id", "jsonrpc": "2.0", "result": null, "error": {"code": 3, "message": "foo", "data": null}}
        , .{ .response = .{
            .id = .{ .string = "id" },
            .result_or_error = .{ .@"error" = .{ .code = @enumFromInt(3), .message = "foo", .data = null } },
        } }, .{});
        try testParse(
            \\{"id": "id", "jsonrpc": "2.0", "error": {"code": 42, "message": "bar", "data": true}}
        , .{ .response = .{
            .id = .{ .string = "id" },
            .result_or_error = .{ .@"error" = .{ .code = @enumFromInt(42), .message = "bar", .data = .{ .bool = true } } },
        } }, .{});
        try testParse(
            \\{"id": "id", "jsonrpc": "2.0", "error": {"code": 42, "message": "bar"}, "result": null}
        , .{ .response = .{
            .id = .{ .string = "id" },
            .result_or_error = .{ .@"error" = .{ .code = @enumFromInt(42), .message = "bar", .data = null } },
        } }, .{});
    }

    test "validate that the 'params' is null/array/object" {
        // null
        try testParse(
            \\{"jsonrpc": "2.0", "id": 1, "method": "foo", "params": null}
        , .{ .request = .{
            .id = .{ .number = 1 },
            .method = "foo",
            .params = .null,
        } }, .{});
        try testParse(
            \\{"jsonrpc": "2.0", "id": 1, "method": "foo"}
        , .{ .request = .{
            .id = .{ .number = 1 },
            .method = "foo",
            .params = null,
        } }, .{});

        // bool
        try testParseExpectedError(
            \\{"jsonrpc": "2.0", "id": 1, "method": "foo", "params": true}
        ,
            error.UnexpectedToken,
            error.UnexpectedToken,
            .{},
        );

        // integer
        try testParseExpectedError(
            \\{"jsonrpc": "2.0", "id": 1, "method": "foo", "params": 5}
        ,
            error.UnexpectedToken,
            error.UnexpectedToken,
            .{},
        );

        // float
        try testParseExpectedError(
            \\{"jsonrpc": "2.0", "id": 1, "method": "foo", "params": 4.2}
        ,
            error.UnexpectedToken,
            error.UnexpectedToken,
            .{},
        );

        // string
        try testParseExpectedError(
            \\{"jsonrpc": "2.0", "id": 1, "method": "foo", "params": "bar"}
        ,
            error.UnexpectedToken,
            error.UnexpectedToken,
            .{},
        );

        // array
        try testParse(
            \\{"jsonrpc": "2.0", "id": 1, "method": "foo", "params": []}
        , .{ .request = .{
            .id = .{ .number = 1 },
            .method = "foo",
            .params = .{ .array = undefined },
        } }, .{});

        // object
        try testParse(
            \\{"jsonrpc": "2.0", "id": 1, "method": "foo", "params": {}}
        , .{ .request = .{
            .id = .{ .number = 1 },
            .method = "foo",
            .params = .{ .object = undefined },
        } }, .{});
    }

    test "escaped field name" {
        try testParse(
            \\{"jsonrpc": "2.0", "method": "foo", "params": null}
        , .{
            .notification = .{
                .method = "foo",
                .params = .null,
            },
        }, .{});
    }

    test "duplicate_field_behavior" {
        try testParseExpectedError(
            \\{"jsonrpc": "2.0", "jsonrpc": "2.0", "method": "foo", "params": null}
        ,
            error.DuplicateField,
            error.DuplicateField,
            .{},
        );

        try testParse(
            \\{"jsonrpc": "2.0", "jsonrpc": "1.0", "method": "foo", "params": null}
        ,
            .{ .notification = .{ .method = "foo", .params = .null } },
            .{ .duplicate_field_behavior = .use_first },
        );
        try testParseExpectedError(
            \\{"jsonrpc": "2.0", "jsonrpc": "1.0", "method": "foo", "params": null}
        ,
            error.UnexpectedToken,
            error.UnexpectedToken,
            .{ .duplicate_field_behavior = .use_last },
        );

        try testParseExpectedError(
            \\{"jsonrpc": "1.0", "jsonrpc": "2.0", "method": "bar", "params": null}
        ,
            error.UnexpectedToken,
            error.UnexpectedToken,
            .{ .duplicate_field_behavior = .use_first },
        );
        try testParse(
            \\{"jsonrpc": "1.0", "jsonrpc": "2.0", "method": "bar", "params": null}
        ,
            .{ .notification = .{ .method = "bar", .params = .null } },
            .{ .duplicate_field_behavior = .use_last },
        );
    }

    test "ignore_unknown_fields" {
        try testParse(
            \\{"jsonrpc": "2.0", "id": 1, "other": null, "method": "foo", "params": null, "extra": "."}
        , .{
            .request = .{
                .id = .{ .number = 1 },
                .method = "foo",
                .params = .null,
            },
        }, .{ .ignore_unknown_fields = true });
        try testParse(
            \\{"other": "", "jsonrpc": "2.0", "extra": {}, "method": "bar"}
        , .{
            .notification = .{
                .method = "bar",
                .params = null,
            },
        }, .{ .ignore_unknown_fields = true });
        try testParseExpectedError(
            \\{"jsonrpc": "2.0", "id": 1, "other": null, ".": "Sie", "params": {}, "extra": {}}
        ,
            error.UnknownField,
            error.UnknownField,
            .{ .ignore_unknown_fields = false },
        );
    }

    test "emit_null_optional_fields" {
        try std.testing.expectFmt(
            \\{"jsonrpc":"2.0","method":"exit"}
        , "{f}", .{std.json.fmt(JsonRPCMessage{ .notification = .{ .method = "exit", .params = null } }, .{ .emit_null_optional_fields = false })});
        try std.testing.expectFmt(
            \\{"jsonrpc":"2.0","method":"exit","params":null}
        , "{f}", .{std.json.fmt(JsonRPCMessage{ .notification = .{ .method = "exit", .params = null } }, .{ .emit_null_optional_fields = true })});
        try std.testing.expectFmt(
            \\{"jsonrpc":"2.0","method":"exit","params":null}
        , "{f}", .{std.json.fmt(JsonRPCMessage{ .notification = .{ .method = "exit", .params = .null } }, .{ .emit_null_optional_fields = false })});
        try std.testing.expectFmt(
            \\{"jsonrpc":"2.0","method":"exit","params":null}
        , "{f}", .{std.json.fmt(JsonRPCMessage{ .notification = .{ .method = "exit", .params = .null } }, .{ .emit_null_optional_fields = true })});

        try std.testing.expectFmt(
            \\{"jsonrpc":"2.0","result":null}
        , "{f}", .{std.json.fmt(JsonRPCMessage{ .response = .{ .id = null, .result_or_error = .{ .result = null } } }, .{ .emit_null_optional_fields = false })});
        try std.testing.expectFmt(
            \\{"jsonrpc":"2.0","id":null,"result":null}
        , "{f}", .{std.json.fmt(JsonRPCMessage{ .response = .{ .id = null, .result_or_error = .{ .result = null } } }, .{ .emit_null_optional_fields = true })});
    }

    fn testParse(message: []const u8, expected: JsonRPCMessage, parse_options: std.json.ParseOptions) !void {
        const allocator = std.testing.allocator;

        const parsed_from_slice = try std.json.parseFromSlice(JsonRPCMessage, allocator, message, parse_options);
        defer parsed_from_slice.deinit();

        const parsed_value = try std.json.parseFromSlice(std.json.Value, allocator, message, parse_options);
        defer parsed_value.deinit();

        const parsed_from_value = try std.json.parseFromValue(JsonRPCMessage, allocator, parsed_value.value, parse_options);
        defer parsed_from_value.deinit();

        const from_slice_stringified = try std.json.Stringify.valueAlloc(allocator, parsed_from_slice.value, .{ .whitespace = .indent_2 });
        defer allocator.free(from_slice_stringified);

        const from_value_stringified = try std.json.Stringify.valueAlloc(allocator, parsed_from_value.value, .{ .whitespace = .indent_2 });
        defer allocator.free(from_value_stringified);

        if (!std.mem.eql(u8, from_slice_stringified, from_value_stringified)) {
            std.debug.print(
                \\
                \\====== std.json.parseFromSlice: ======
                \\{s}
                \\====== std.json.parseFromValue: ======
                \\{s}
                \\======================================\
                \\
            , .{ from_slice_stringified, from_value_stringified });
            return error.TestExpectedEqual;
        }

        try expectEqual(parsed_from_slice.value, parsed_from_value.value);
        try expectEqual(parsed_from_slice.value, expected);
        try expectEqual(parsed_from_value.value, expected);
    }

    fn testParseExpectedError(
        message: []const u8,
        expected_parse_error: std.json.ParseError(std.json.Scanner),
        expected_parse_from_value_error: std.json.ParseFromValueError,
        parse_options: std.json.ParseOptions,
    ) !void {
        const allocator = std.testing.allocator;

        try std.testing.expectError(expected_parse_error, std.json.parseFromSlice(JsonRPCMessage, allocator, message, parse_options));

        const parsed_value = std.json.parseFromSlice(std.json.Value, allocator, message, parse_options) catch |err| {
            try std.testing.expectEqual(expected_parse_error, err);
            return;
        };
        defer parsed_value.deinit();

        try std.testing.expectError(expected_parse_from_value_error, std.json.parseFromValue(JsonRPCMessage, allocator, parsed_value.value, parse_options));
    }

    fn expectEqual(a: JsonRPCMessage, b: JsonRPCMessage) !void {
        try std.testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
        switch (a) {
            .request => {
                try std.testing.expectEqualDeep(a.request.id, b.request.id);
                try std.testing.expectEqualStrings(a.request.method, b.request.method);

                // this only a shallow equality check
                try std.testing.expectEqual(a.request.params == null, b.request.params == null);
                if (a.request.params != null) {
                    try std.testing.expectEqual(std.meta.activeTag(a.request.params.?), std.meta.activeTag(b.request.params.?));
                }
            },
            .notification => {
                try std.testing.expectEqualStrings(a.notification.method, b.notification.method);

                // this only a shallow equality check
                try std.testing.expectEqual(a.notification.params == null, b.notification.params == null);
                if (a.notification.params != null) {
                    try std.testing.expectEqual(std.meta.activeTag(a.notification.params.?), std.meta.activeTag(b.notification.params.?));
                }
            },
            .response => {
                try std.testing.expectEqualDeep(a.response.id, b.response.id);
                try std.testing.expectEqual(std.meta.activeTag(a.response.result_or_error), std.meta.activeTag(b.response.result_or_error));

                switch (a.response.result_or_error) {
                    .result => {
                        // this only a shallow equality check
                        try std.testing.expectEqual(a.response.result_or_error.result == null, b.response.result_or_error.result == null);
                        if (a.response.result_or_error.result != null) {
                            try std.testing.expectEqual(std.meta.activeTag(a.response.result_or_error.result.?), std.meta.activeTag(b.response.result_or_error.result.?));
                        }
                    },
                    .@"error" => {
                        try std.testing.expectEqualDeep(a.response.result_or_error.@"error", b.response.result_or_error.@"error");
                    },
                }
            },
        }
    }
};

pub fn TypedJsonRPCRequest(
    /// Must serialize to a JSON Array, JSON Object or JSON null.
    comptime Params: type,
) type {
    return struct {
        comptime jsonrpc: []const u8 = "2.0",
        /// The request id.
        id: JsonRPCMessage.ID,
        /// The method to be invoked.
        method: []const u8,
        /// The requests's params. `params == null` means means no `"params"` field.
        params: ?Params,

        pub fn jsonStringify(request: @This(), stream: anytype) @TypeOf(stream.*).Error!void {
            try stream.beginObject();

            try stream.objectField("jsonrpc");
            try stream.write("2.0");

            try stream.objectField("id");
            try stream.write(request.id);

            try stream.objectField("method");
            try stream.write(request.method);

            if (request.params) |params| {
                try stream.objectField("params");
                switch (@TypeOf(params)) {
                    void,
                    ?void,
                    => try stream.write(null),
                    else => try stream.write(params),
                }
            } else if (stream.options.emit_null_optional_fields) {
                try stream.objectField("params");
                try stream.write(null);
            }

            try stream.endObject();
        }
    };
}

test TypedJsonRPCRequest {
    const Request = TypedJsonRPCRequest(bool);

    try std.testing.expectFmt(
        \\{"jsonrpc":"2.0","id":42,"method":"name","params":null}
    , "{f}", .{std.json.fmt(Request{ .id = .{ .number = 42 }, .method = "name", .params = null }, .{})});
    try std.testing.expectFmt(
        \\{"jsonrpc":"2.0","id":"42","method":"name"}
    , "{f}", .{std.json.fmt(Request{ .id = .{ .string = "42" }, .method = "name", .params = null }, .{ .emit_null_optional_fields = false })});
    try std.testing.expectFmt(
        \\{"jsonrpc":"2.0","id":42,"method":"name","params":true}
    , "{f}", .{std.json.fmt(Request{ .id = .{ .number = 42 }, .method = "name", .params = true }, .{})});
}

pub fn TypedJsonRPCNotification(
    /// Must serialize to a JSON Array, JSON Object or JSON null.
    comptime Params: type,
) type {
    return struct {
        comptime jsonrpc: []const u8 = "2.0",
        /// The method to be invoked.
        method: []const u8,
        /// The requests's params. `params == null` means means no `"params"` field.
        params: ?Params,

        pub fn jsonStringify(notification: @This(), stream: anytype) @TypeOf(stream.*).Error!void {
            try stream.beginObject();

            try stream.objectField("jsonrpc");
            try stream.write("2.0");

            try stream.objectField("method");
            try stream.write(notification.method);

            if (notification.params) |params| {
                try stream.objectField("params");
                switch (@TypeOf(params)) {
                    void,
                    ?void,
                    => try stream.write(null),
                    else => try stream.write(params),
                }
            } else if (stream.options.emit_null_optional_fields) {
                try stream.objectField("params");
                try stream.write(null);
            }

            try stream.endObject();
        }
    };
}

test TypedJsonRPCNotification {
    const Notification = TypedJsonRPCNotification(bool);

    try std.testing.expectFmt(
        \\{"jsonrpc":"2.0","method":"name","params":null}
    , "{f}", .{std.json.fmt(Notification{ .method = "name", .params = null }, .{})});
    try std.testing.expectFmt(
        \\{"jsonrpc":"2.0","method":"name"}
    , "{f}", .{std.json.fmt(Notification{ .method = "name", .params = null }, .{ .emit_null_optional_fields = false })});
    try std.testing.expectFmt(
        \\{"jsonrpc":"2.0","method":"name","params":true}
    , "{f}", .{std.json.fmt(Notification{ .method = "name", .params = true }, .{})});
}

pub fn TypedJsonRPCResponse(
    /// Must serialize to a JSON Array, JSON Object or JSON null.
    comptime Result: type,
) type {
    return struct {
        /// The request id.
        ///
        /// It must be the same as the value of the `id` member in the `Request` object.
        /// If there was an error in detecting the id in the `Request` object (e.g. `Error.Code.parse_error`/`Error.Code.invalid_request`), it must be `null`.
        id: ?JsonRPCMessage.ID,
        result_or_error: union(enum) {
            /// The result of a request.
            result: Result,
            /// The error object in case a request fails.
            @"error": JsonRPCMessage.Response.Error,
        },

        pub const jsonParse = {};
        pub const jsonParseFromValue = {};

        pub fn jsonStringify(response: @This(), stream: anytype) @TypeOf(stream.*).Error!void {
            try stream.beginObject();

            try stream.objectField("jsonrpc");
            try stream.write("2.0");

            try stream.objectField("id");
            try stream.write(response.id);

            switch (response.result_or_error) {
                inline else => |value, tag| {
                    try stream.objectField(@tagName(tag));
                    switch (@TypeOf(value)) {
                        void, ?void => try stream.write(null),
                        else => try stream.write(value),
                    }
                },
            }

            try stream.endObject();
        }
    };
}

test TypedJsonRPCResponse {
    const Response = TypedJsonRPCResponse(bool);

    try std.testing.expectFmt(
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"message","data":null}}
    , "{f}", .{std.json.fmt(Response{
        .id = null,
        .result_or_error = .{ .@"error" = .{ .code = .invalid_request, .message = "message", .data = .null } },
    }, .{})});
    try std.testing.expectFmt(
        \\{"jsonrpc":"2.0","id":5,"result":true}
    , "{f}", .{std.json.fmt(Response{
        .id = .{ .number = 5 },
        .result_or_error = .{ .result = true },
    }, .{})});
}

/// A minimal non-allocating parser for the LSP Base Protocol Header Part.
///
/// See https://microsoft.github.io/language-server-protocol/specifications/specification-current/#headerPart
pub const BaseProtocolHeader = struct {
    content_length: usize,

    pub const minimum_reader_buffer_size: usize = 128;

    pub const ParseError = error{
        EndOfStream,
        /// The message is longer than `std.math.maxInt(usize)`.
        OversizedMessage,
        /// The header field is longer than buffer size of the `std.Io.Reader` which is at least `minimum_reader_buffer_size`.
        OversizedHeaderField,
        /// The header is missing the mandatory `Content-Length` field.
        MissingContentLength,
        /// The header field `Content-Length` has been specified multiple times.
        DuplicateContentLength,
        /// The header field value of `Content-Length` is not a valid unsigned integer.
        InvalidContentLength,
        /// The header is ill-formed.
        InvalidHeaderField,
    };

    /// The maximum parsable header field length is controlled by `reader.buffer.len`.
    /// Asserts that `reader.buffer.len >= minimum_reader_buffer_size`.
    pub fn parse(reader: *std.Io.Reader) (std.Io.Reader.Error || ParseError)!BaseProtocolHeader {
        std.debug.assert(@import("builtin").is_test or reader.buffer.len >= minimum_reader_buffer_size);
        var content_length: ?usize = null;

        while (true) {
            var header = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.StreamTooLong => return error.OversizedHeaderField,
                else => |e| return e,
            };
            if (!std.mem.endsWith(u8, header, "\r\n")) return error.InvalidHeaderField;
            header.len -= "\r\n".len;

            if (header.len == 0) break;

            const colon_index = std.mem.find(u8, header, ": ") orelse return error.InvalidHeaderField;

            const header_name = header[0..colon_index];
            const header_value = header[colon_index + 2 ..];

            if (!std.ascii.eqlIgnoreCase(header_name, "content-length")) continue;
            if (content_length != null) return error.DuplicateContentLength;

            content_length = std.fmt.parseUnsigned(usize, header_value, 10) catch |err| switch (err) {
                error.Overflow => return error.OversizedMessage,
                error.InvalidCharacter => return error.InvalidContentLength,
            };
        }

        return .{
            .content_length = content_length orelse return error.MissingContentLength,
        };
    }

    test parse {
        try expectParseError("", error.EndOfStream);
        try expectParseError("\n", error.InvalidHeaderField);
        try expectParseError("\n\r", error.InvalidHeaderField);
        try expectParseError("\r", error.EndOfStream);
        try expectParseError("\r\n", error.MissingContentLength);
        try expectParseError("\r\n\r\n", error.MissingContentLength);

        try expectParseError("content-length: 32\r\n", error.EndOfStream);
        try expectParseError("content-length: \r\n\r\n", error.InvalidContentLength);
        try expectParseError("content-length 32\r\n\r\n", error.InvalidHeaderField);
        try expectParseError("content-length:32\r\n\r\n", error.InvalidHeaderField);
        try expectParseError("contentLength: 32\r\n\r\n", error.MissingContentLength);
        try expectParseError("content-length: 32\r\ncontent-length: 32\r\n\r\n", error.DuplicateContentLength);
        try expectParseError("content-length: abababababab\r\n\r\n", error.InvalidContentLength);
        try expectParseError("content-length: : 32\r\n\r\n", error.InvalidContentLength);
        try expectParseError("content-length: 9999999999999999999999999999999999\r\n\r\n", error.OversizedMessage);

        try expectParse("content-length: 32\r\n\r\n", .{ .content_length = 32 });
        try expectParse("Content-Length: 32\r\n\r\n", .{ .content_length = 32 });

        try expectParse("content-type: whatever\r\nContent-Length: 666\r\n\r\n", .{ .content_length = 666 });
        try expectParse("Content-Type: impostor\r\ncontent-length: 42\r\n\r\n", .{ .content_length = 42 });
    }

    test "parse with oversized header field" {
        const stream = struct {
            fn stream(_: *std.Io.Reader, w: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
                return try w.write("a");
            }
        }.stream;

        var buffer: [128]u8 = @splat(0);
        var reader: std.Io.Reader = .{
            .vtable = &.{
                .stream = &stream,
                .discard = undefined,
            },
            .buffer = &buffer,
            .end = buffer.len,
            .seek = 0,
        };
        try std.testing.expectError(error.OversizedHeaderField, parse(&reader));
    }

    pub fn format(header: BaseProtocolHeader, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Content-Length: {d}\r\n\r\n", .{header.content_length});
    }

    test format {
        try std.testing.expectFmt("Content-Length: 0\r\n\r\n", "{f}", .{BaseProtocolHeader{ .content_length = 0 }});
        try std.testing.expectFmt("Content-Length: 42\r\n\r\n", "{f}", .{BaseProtocolHeader{ .content_length = 42 }});
        try std.testing.expectFmt("Content-Length: 4294967295\r\n\r\n", "{f}", .{BaseProtocolHeader{ .content_length = std.math.maxInt(u32) }});
        if (@sizeOf(usize) == @sizeOf(u64)) {
            try std.testing.expectFmt("Content-Length: 18446744073709551615\r\n\r\n", "{f}", .{BaseProtocolHeader{ .content_length = std.math.maxInt(usize) }});
        }
    }

    fn expectParse(input: []const u8, expected_header: BaseProtocolHeader) !void {
        var reader: std.Io.Reader = .fixed(input);
        const actual_header = try parse(&reader);
        try std.testing.expectEqual(expected_header.content_length, actual_header.content_length);
    }

    fn expectParseError(input: []const u8, expected_error: ParseError) !void {
        var buffer: [128]u8 = undefined;
        var reader: std.Io.Reader = .fixed(&buffer);
        reader.end = input.len;
        @memcpy(buffer[0..input.len], input);

        try std.testing.expectError(expected_error, parse(&reader));
    }
};

pub const TestingTransport = if (!@import("builtin").is_test) @compileError("Use 'std.Io.Reader.fixed' or 'std.Io.Writer.Allocating' instead.");
pub const TransportOverStdio = if (!@import("builtin").is_test) @compileError("Use 'Transport.Stdio' instead.");
pub const AnyTransport = if (!@import("builtin").is_test) @compileError("Use 'Transport' instead.");

const json_rpc = @This();

pub const Transport = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        readJsonMessage: *const fn (transport: *Transport, io: std.Io, allocator: std.mem.Allocator) ReadError![]u8,
        writeJsonMessage: *const fn (transport: *Transport, io: std.Io, json_message: []const u8) WriteError!void,
    };

    pub const ReadError = std.Io.File.Reader.Error || error{EndOfStream} || BaseProtocolHeader.ParseError || std.mem.Allocator.Error;
    pub const WriteError = std.Io.File.Writer.Error;

    pub const Stdio = struct {
        transport: Transport,
        reader: std.Io.Reader,
        read_from: std.Io.File,
        write_to: std.Io.File,

        pub fn init(
            /// See `BaseProtocolHeader.parse`
            read_buffer: []u8,
            read_from: std.Io.File,
            write_to: std.Io.File,
        ) Stdio {
            return .{
                .transport = .{
                    .vtable = &.{
                        .readJsonMessage = &Stdio.readJsonMessage,
                        .writeJsonMessage = &Stdio.writeJsonMessage,
                    },
                },
                .reader = std.Io.File.Reader.initInterface(read_buffer),
                .read_from = read_from,
                .write_to = write_to,
            };
        }

        fn readJsonMessage(transport: *Transport, io: std.Io, allocator: std.mem.Allocator) ReadError![]u8 {
            const stdio: *Stdio = @fieldParentPtr("transport", transport);
            var file_reader: std.Io.File.Reader = .initStreaming(stdio.read_from, io, stdio.reader.buffer);
            file_reader.interface = stdio.reader;
            defer stdio.reader = file_reader.interface;
            return json_rpc.readJsonMessage(&file_reader.interface, allocator) catch |err| switch (err) {
                error.ReadFailed => return file_reader.err.?,
                else => |e| return e,
            };
        }

        fn writeJsonMessage(transport: *Transport, io: std.Io, json_message: []const u8) WriteError!void {
            const stdio: *Stdio = @fieldParentPtr("transport", transport);
            var file_writer: std.Io.File.Writer = .initStreaming(stdio.write_to, io, &.{});
            json_rpc.writeJsonMessage(&file_writer.interface, json_message) catch |err| switch (err) {
                error.WriteFailed => return file_writer.err.?,
            };
        }
    };

    /// Consider using `readJsonMessageUncancelable` to avoid `error.Canceled` being returned.
    pub fn readJsonMessage(transport: *Transport, io: std.Io, allocator: std.mem.Allocator) ReadError![]u8 {
        return try transport.vtable.readJsonMessage(transport, io, allocator);
    }

    pub fn readJsonMessageUncancelable(transport: *Transport, io: std.Io, allocator: std.mem.Allocator) !void {
        const old_cancel_protect = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(old_cancel_protect);
        return Transport.readJsonMessage(transport, io, allocator) catch |err| switch (err) {
            error.Canceled => unreachable,
            else => |e| return e,
        };
    }

    /// Consider using `writeJsonMessageUncancelable` to avoid `error.Canceled` being returned.
    pub fn writeJsonMessage(transport: *Transport, io: std.Io, json_message: []const u8) WriteError!void {
        return try transport.vtable.writeJsonMessage(transport, io, json_message);
    }

    pub fn writeJsonMessageUncancelable(transport: *Transport, io: std.Io, json_message: []const u8) !void {
        const old_cancel_protect = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(old_cancel_protect);
        Transport.writeJsonMessage(transport, io, json_message) catch |err| switch (err) {
            error.Canceled => unreachable,
            else => |e| return e,
        };
    }

    pub fn writeRequest(
        transport: *Transport,
        io: std.Io,
        allocator: std.mem.Allocator,
        id: JsonRPCMessage.ID,
        method: []const u8,
        comptime Params: type,
        params: Params,
        options: std.json.Stringify.Options,
    ) (WriteError || std.mem.Allocator.Error)!void {
        const request: TypedJsonRPCRequest(Params) = .{
            .id = id,
            .method = method,
            .params = params,
        };
        const json_message = try std.json.Stringify.valueAlloc(allocator, request, options);
        defer allocator.free(json_message);
        try transport.writeJsonMessage(io, json_message);
    }

    pub fn writeNotification(
        transport: *Transport,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        comptime Params: type,
        params: Params,
        options: std.json.Stringify.Options,
    ) (WriteError || std.mem.Allocator.Error)!void {
        const request: TypedJsonRPCNotification(Params) = .{
            .method = method,
            .params = params,
        };
        const json_message = try std.json.Stringify.valueAlloc(allocator, request, options);
        defer allocator.free(json_message);
        try transport.writeJsonMessage(io, json_message);
    }

    pub fn writeResponse(
        transport: *Transport,
        io: std.Io,
        allocator: std.mem.Allocator,
        id: ?JsonRPCMessage.ID,
        comptime Result: type,
        result: Result,
        options: std.json.Stringify.Options,
    ) (WriteError || std.mem.Allocator.Error)!void {
        const request: TypedJsonRPCResponse(Result) = .{
            .id = id,
            .result_or_error = .{ .result = result },
        };
        const json_message = try std.json.Stringify.valueAlloc(allocator, request, options);
        defer allocator.free(json_message);
        try transport.writeJsonMessage(io, json_message);
    }

    pub fn writeErrorResponse(
        transport: *Transport,
        io: std.Io,
        allocator: std.mem.Allocator,
        id: ?JsonRPCMessage.ID,
        err: JsonRPCMessage.Response.Error,
        options: std.json.Stringify.Options,
    ) (WriteError || std.mem.Allocator.Error)!void {
        const request: TypedJsonRPCResponse(void) = .{
            .id = id,
            .result_or_error = .{ .@"error" = err },
        };
        const json_message = try std.json.Stringify.valueAlloc(allocator, request, options);
        defer allocator.free(json_message);
        try transport.writeJsonMessage(io, json_message);
    }
};

pub const ThreadSafeTransportConfig = struct {
    /// Makes `readJsonMessage` thread-safe.
    thread_safe_read: bool,
    /// Makes `writeJsonMessage` thread-safe.
    thread_safe_write: bool,
    MutexType: type = std.Io.Mutex,
};

/// Wraps a non-thread-safe transport and makes it thread-safe.
pub fn ThreadSafeTransport(config: ThreadSafeTransportConfig) type {
    return struct {
        transport: Transport,
        child_transport: *Transport,
        in_mutex: @TypeOf(in_mutex_init) = in_mutex_init,
        out_mutex: @TypeOf(out_mutex_init) = out_mutex_init,

        // Is there any better name of this?
        const Self = @This();

        pub fn init(child_transport: *Transport) Self {
            return .{
                .transport = .{
                    .vtable = &.{
                        .readJsonMessage = Self.readJsonMessage,
                        .writeJsonMessage = Self.writeJsonMessage,
                    },
                },
                .child_transport = child_transport,
            };
        }

        pub fn readJsonMessage(transport: *Transport, io: std.Io, allocator: std.mem.Allocator) Transport.ReadError![]u8 {
            const self: *Self = @fieldParentPtr("transport", transport);

            try self.in_mutex.lock(io);
            defer self.in_mutex.unlock(io);

            return try self.child_transport.readJsonMessage(io, allocator);
        }

        pub fn writeJsonMessage(transport: *Transport, io: std.Io, json_message: []const u8) Transport.WriteError!void {
            const self: *Self = @fieldParentPtr("transport", transport);

            try self.out_mutex.lock(io);
            defer self.out_mutex.unlock(io);

            return try self.child_transport.writeJsonMessage(io, json_message);
        }

        const in_mutex_init = if (config.thread_safe_read)
            config.MutexType.init
        else
            DummyMutex{};

        const out_mutex_init = if (config.thread_safe_write)
            config.MutexType.init
        else
            DummyMutex{};

        const DummyMutex = struct {
            pub fn lock(_: *DummyMutex, _: std.Io) !void {}
            pub fn unlock(_: *DummyMutex, _: std.Io) void {}
        };
    };
}

pub fn readJsonMessage(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
) (std.Io.Reader.Error || std.mem.Allocator.Error || BaseProtocolHeader.ParseError)![]u8 {
    const header: BaseProtocolHeader = try .parse(reader);
    return try reader.readAlloc(allocator, header.content_length);
}

test readJsonMessage {
    var reader: std.Io.Reader = .fixed("Content-Length: 2\r\n\r\n{}");

    const json_message = try readJsonMessage(&reader, std.testing.allocator);
    defer std.testing.allocator.free(json_message);

    try std.testing.expectEqualStrings("{}", json_message);
}

pub fn writeJsonMessage(writer: *std.Io.Writer, json_message: []const u8) std.Io.Writer.Error!void {
    const header: BaseProtocolHeader = .{ .content_length = json_message.len };
    var buffer: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buffer, "{f}", .{header}) catch unreachable;
    var data: [2][]const u8 = .{ prefix, json_message };
    try writer.writeVecAll(&data);
    try writer.flush();
}

test writeJsonMessage {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeJsonMessage(&aw.writer, "{}");
    try std.testing.expectEqualStrings("Content-Length: 2\r\n\r\n{}", aw.written());
}

pub fn writeRequest(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    id: JsonRPCMessage.ID,
    method: []const u8,
    comptime Params: type,
    params: Params,
    options: std.json.Stringify.Options,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    const request: TypedJsonRPCRequest(Params) = .{
        .id = id,
        .method = method,
        .params = params,
    };
    const json_message = try std.json.Stringify.valueAlloc(allocator, request, options);
    defer allocator.free(json_message);
    try writeJsonMessage(writer, json_message);
}

test writeRequest {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeRequest(
        &aw.writer,
        std.testing.allocator,
        .{ .number = 0 },
        "my/method",
        void,
        {},
        .{ .whitespace = .indent_2 },
    );

    try std.testing.expectEqualStrings("Content-Length: 76\r\n\r\n" ++
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 0,
        \\  "method": "my/method",
        \\  "params": null
        \\}
    , aw.written());
}

pub fn writeNotification(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    method: []const u8,
    comptime Params: type,
    params: Params,
    options: std.json.Stringify.Options,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    const request: TypedJsonRPCNotification(Params) = .{
        .method = method,
        .params = params,
    };
    const json_message = try std.json.Stringify.valueAlloc(allocator, request, options);
    defer allocator.free(json_message);
    try writeJsonMessage(writer, json_message);
}

test writeNotification {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeNotification(
        &aw.writer,
        std.testing.allocator,
        "my/method",
        void,
        {},
        .{ .whitespace = .indent_2 },
    );

    try std.testing.expectEqualStrings("Content-Length: 65\r\n\r\n" ++
        \\{
        \\  "jsonrpc": "2.0",
        \\  "method": "my/method",
        \\  "params": null
        \\}
    , aw.written());
}

pub fn writeResponse(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    id: ?JsonRPCMessage.ID,
    comptime Result: type,
    result: Result,
    options: std.json.Stringify.Options,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    const request: TypedJsonRPCResponse(Result) = .{
        .id = id,
        .result_or_error = .{ .result = result },
    };
    const json_message = try std.json.Stringify.valueAlloc(allocator, request, options);
    defer allocator.free(json_message);
    try writeJsonMessage(writer, json_message);
}

test writeResponse {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeResponse(
        &aw.writer,
        std.testing.allocator,
        .{ .number = 0 },
        void,
        {},
        .{ .whitespace = .indent_2 },
    );

    try std.testing.expectEqualStrings("Content-Length: 51\r\n\r\n" ++
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 0,
        \\  "result": null
        \\}
    , aw.written());
}

pub fn writeErrorResponse(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    id: ?JsonRPCMessage.ID,
    err: JsonRPCMessage.Response.Error,
    options: std.json.Stringify.Options,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    const request: TypedJsonRPCResponse(void) = .{
        .id = id,
        .result_or_error = .{ .@"error" = err },
    };
    const json_message = try std.json.Stringify.valueAlloc(allocator, request, options);
    defer allocator.free(json_message);
    try writeJsonMessage(writer, json_message);
}

test writeErrorResponse {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeErrorResponse(
        &aw.writer,
        std.testing.allocator,
        null,
        .{ .code = .internal_error, .message = "my message" },
        .{ .whitespace = .indent_2 },
    );

    try std.testing.expectEqualStrings("Content-Length: 120\r\n\r\n" ++
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": null,
        \\  "error": {
        \\    "code": -32603,
        \\    "message": "my message",
        \\    "data": null
        \\  }
        \\}
    , aw.written());
}
