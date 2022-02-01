const std = @import("std");

const Class = enum(u8) {
    Universal = 0, // 0, 0
    Application = 1, // 0, 1
    ContextSpecific = 2, // 1, 0
    Private = 3, // 1, 1

    // TODO: high numbers (octets start by 11111)
};

const Tag = enum(u8) {
    Integer = 2,
    BitString = 3,
    OctetString = 4,
    Null = 5,
    ObjectIdentifier = 6,
    Sequence = 16, // ordered collection of types
    Set = 17, // unordered collection of types
    PrintableString = 19,
    T61String = 20,
    Ia5String = 22,
    UtcTime = 23,

    // Choice
    // Any
};

pub const BitString = struct {
    buf: []const u8,
    len: usize,
};

pub const nullBytes = [_]u8{ @enumToInt(Tag.Null), 0 };

pub const ObjectIdentifier = struct {
    object_identifier: []const i32,
};

pub const RawValue = struct {
    class: Class,
    tag: Tag,
    is_primitive: bool,
    buf: []const u8,
    full_buf: ?[]const u8,
};

pub const RawContent = struct { raw_content: []const u8 };

// Implicit
// Explicit

// BER:

// Identifier octets
// Length octets
// Content octets
// End of content octets

// Primitive, definite length -> non string types
// Constructed, definite length ->

// Primitive, definite length

// ~
// ~
// ~ Primitive, length defined
// ~
// ~

//
// Identifier octets
//

// Low Tag format (one octet)
// ccpttttt
// c = class
// p = the encoding is primitive
// t = tag

// High tag format (two or more octets)

// 1st - ccp111111
// c = class
// p = the encoding is primitive
// 1 = 1

// 2nd .. - TODO

//
// Length octets
//

// Short form (lengths between 0 and 127) (one octet)
// 0lllllll
// 0 = 0
// l = lenght

// Long definite (lengths between 0 and 2^1008 -1) (two to 127 octets)

// 1st - 1aaaaaaa
// 1 = 1
// a = additional octets

// 2nd .. - Base 256, most significant digit first

// ~
// ~
// ~ Constructed, definite length
// ~
// ~

// As before

// ~
// ~
// ~ Constructed, indefinite length
// ~
// ~

// Length octets (one octet)
// 0x80

// End of content octets (two octets)
// 0x00 0x00

// DER

// If the size is between 0 and 127, use the short form
// If the size is more than 128, use the long form

const Token = union(enum) {
    // Identifier: union(enum) { LowTag: struct {
    //     class: Class,
    //     primitive: bool,
    //     tag: Tag,
    // }, HighTag: struct {
    //     class: Class,
    //     primitive: bool,
    // } },
    // Length: union(enum) {
    //     Short: u8,
    //     Long: struct { additional_octets: u8 },
    // },
    Integer: struct {
        len: usize,

        pub fn slice(self: @This(), buf: []const u8, i: usize) []const u8 {
            return buf[i - self.len .. i];
        }
    },
    ObjectIdentifier: struct {
        len: usize,
        first_values: u8,

        pub fn slice(self: @This(), buf: []const u8, i: usize) []const u8 {
            return buf[i - self.len .. i];
        }
    },
};

const TokenParser = struct {
    const This = @This();

    state: State,
    complete: bool,
    skip_bytes: usize,

    class: ?Class,
    is_primitive: bool,
    tag: ?Tag,
    length: usize,
    length_long_accumulated: usize,

    integer_seen_most_significant_bit: bool,

    pub fn init() This {
        var p: This = undefined;
        p.reset();
        return p;
    }

    pub fn reset(this: *This) void {
        this.state = .Identifier;
        this.complete = false;
        this.skip_bytes = 0;

        this.class = null;
        this.is_primitive = false;
        this.tag = null;

        this.length_long_accumulated = 0;
        this.integer_seen_most_significant_bit = false;
    }

    pub const State = enum {
        Identifier,
        Length,
        Integer,
        ObjectIdentifier,
    };

    pub const Error = error{
        UnknownClass,
        UnknownTag,
    };

    pub fn feed(this: *This, c: u8, token: *?Token) Error!void {
        switch (this.state) {
            .Identifier => {
                // CCxxxxxx
                this.class = std.meta.intToEnum(Class, c >> 6) catch {
                    return error.UnknownClass;
                };

                // xxPxxxxx
                this.is_primitive = c & 0b00100000 == 0b00100000;

                // xxxTTTTTT
                this.tag = std.meta.intToEnum(Tag, c & 0b00011111) catch {
                    return error.UnknownTag;
                };

                this.state = .Length;

                // TODO: High format
            },
            .Length => {
                // Sxxxxxxx
                if (c & 0b10000000 != 0b10000000) {
                    this.length = c & 0b01111111;
                } else {
                    @panic("not supported yet!");
                    // token.* = .{ .Length = .{
                    //     .Long = .{ .additional_octets = c & 0b01111111 },
                    // } };
                }

                switch (this.tag.?) {
                    .Integer => this.state = .Integer,
                    .ObjectIdentifier => this.state = .ObjectIdentifier,
                    else => @panic("unsupported tag"),
                }
            },
            .Integer => {
                if (this.integer_seen_most_significant_bit) {
                    token.* = .{ .Integer = .{ .len = c } };
                    this.skip_bytes = c;
                    this.complete = true;
                } else {
                    this.integer_seen_most_significant_bit = true;
                }
            },
            .ObjectIdentifier => {
                token.* = .{
                    .ObjectIdentifier = .{
                        .len = this.length,
                        .first_values = c,
                    },
                };
                // length - 1, since the first octet has been just read
                this.skip_bytes = this.length - 1;
                this.complete = true;
            },
        }
    }
};

pub const TokenStream = struct {
    const This = @This();

    i: usize,
    buf: []const u8,
    token: ?Token,
    parser: TokenParser,

    pub const Error = TokenParser.Error || error{UnexpectedEndOfAsn1};

    pub fn init(buf: []const u8) This {
        return This{
            .i = 0,
            .buf = buf,
            .parser = TokenParser.init(),
            .token = null,
        };
    }

    pub fn next(this: *This) Error!?Token {
        if (this.token) |token| {
            this.token = null;

            return token;
        }

        var t: ?Token = undefined;

        while (this.i < this.buf.len) {
            try this.parser.feed(this.buf[this.i], &t);
            this.i += 1;
            if (this.parser.skip_bytes != 0) {
                this.i += this.parser.skip_bytes;
                this.parser.skip_bytes = 0;
            }

            if (t) |token| {
                return token;
            }
        }

        if (t) |token| {
            return token;
        } else if (this.parser.complete) {
            return null;
        } else {
            return error.UnexpectedEndOfAsn1;
        }
    }
};

// test "should parse identifiers correctly" {
//     const IdentifierTest = struct {
//         in: []const u8,
//         ok: bool,
//         out: Token,
//     };

//     const identifierTestData = &[_]IdentifierTest{.{
//         .in = &.{0x82},
//         .ok = true,
//         .out = .{ .Identifier = .{ .LowTag = .{
//             .class = .ContextSpecific,
//             .primitive = false,
//             .tag = .Integer,
//         } } },
//     }};

//     for (identifierTestData) |t| {
//         var stream = TokenStream.init(t.in);
//         const token = stream.next() catch |err| {
//             if (t.ok) {
//                 return err;
//             }

//             continue;
//         } orelse {
//             std.debug.print("expecting a token, but none was found!\n", .{});
//             return error.TestExpectedEqual;
//         };

//         try std.testing.expectEqual(t.out, token);
//     }
// }

fn ParseInternalError(comptime T: type) type {
    // `inferred_types` is used to avoid infinite recursion for recursive type definitions.
    const inferred_types = [_]type{};
    return ParseInternalErrorImpl(T, &inferred_types);
}

fn ParseInternalErrorImpl(comptime T: type, comptime inferred_types: []const type) type {
    for (inferred_types) |ty| {
        if (T == ty) return error{};
    }

    // const CommonErrors = error{ UnexpectedEndOfAsn1, UnexpectedToken };

    switch (T) {
        ObjectIdentifier => {
            return error{
                UnexpectedToken,
                AllocatorRequired,
                IdentifierTooLarge,
                IdentifierNotMinimallyEncoded,
                IdentifierTruncated,
            } || std.mem.Allocator.Error || ParseInternalErrorImpl(i32, inferred_types);
        },
        else => {},
    }

    switch (@typeInfo(T)) {
        .Int, .ComptimeInt => {
            return error{ UnexpectedToken, Overflow, IntTooLarge };
        },
        .Struct => {
            return error{};
        },
        else => @compileLog("unsupported type: ", T),
    }
}

// TokenStream.Error || error{UnexpectedToken};

pub const ParseOptions = struct {
    allocator: ?std.mem.Allocator = null,
    skip_identifier: false,
};

fn parseInternal(comptime T: type, token: Token, tokens: *TokenStream, options: ParseOptions) ParseInternalError(T)!T {
    const token = if (!options.skip_identifier) {} else undefined;

    switch (T) {
        ObjectIdentifier => {
            const obj_token = switch (token) {
                .ObjectIdentifier => |obj| obj,
                else => return error.UnexpectedToken,
            };

            const allocator = options.allocator orelse return error.AllocatorRequired;
            // TODO: Allocate only the required bytes
            var s = try allocator.alloc(i32, tokens.buf.len + 1);
            errdefer allocator.free(s);

            // obj_token = 40 * val1 + val2
            // val1 = 0, 1 or 2
            // val2, val == 0 or 1 => 0-39
            // val2, val1 == 1 => <39
            if (obj_token.first_values < 40 * 2) {
                s[0] = std.math.divFloor(u8, obj_token.first_values, 40) catch unreachable;
                s[1] = std.math.rem(u8, obj_token.first_values, 40) catch unreachable;
            } else {
                s[0] = 2;
                s[1] = obj_token.first_values - 40 * 2;
            }

            var i: usize = 1;
            const identifiers = obj_token.slice(tokens.buf, tokens.i);

            var shifted: usize = 0;
            var identifier: i64 = 0;
            for (identifiers) |id| {
                var c = id;

                // Check if the 2nd value uses more than one octet!
                if (i == 1 and shifted == 0) {
                    if (obj_token.first_values & 0b10000000 == 0b10000000) {
                        c = obj_token.first_values;
                    } else {
                        i += 1;
                        continue;
                    }
                }

                // 5 * 7 bits per byte = 35 bits, overflows the i32
                if (shifted == 5) {
                    return error.IdentifierTooLarge;
                }

                if (shifted == 0 and c == 0b10000000) {
                    return error.IdentifierNotMinimallyEncoded;
                }

                identifier <<= 7;
                shifted += 1;

                identifier |= c & 0b01111111;

                // 0xxxxxxx means there's no more octets of this identifier
                if (c & 0b10000000 == 0b00000000) {
                    if (identifier > std.math.maxInt(i32)) {
                        return error.IdentifierTooLarge;
                    }

                    // Since it's val2 value, we need to recalculate it
                    if (i == 1) {
                        s[i] = @intCast(i32, identifier - 40 * 2);
                    } else {
                        s[i] = @intCast(i32, identifier);
                    }

                    i += 1;
                    shifted = 0;
                    identifier = 0;
                }
            }

            if (shifted != 0) {
                return error.IdentifierTruncated;
            }

            return ObjectIdentifier{
                .object_identifier = allocator.resize(s, i) orelse unreachable,
            };
        },
        else => {},
    }

    switch (@typeInfo(T)) {
        .Int, .ComptimeInt => {
            const int_token = switch (token) {
                .Integer => |i| i,
                else => return error.UnexpectedToken,
            };

            const parseInt = struct {
                pub fn parseInt(comptime Int: type, tkn: Token, tkns: *TokenStream) ParseInternalError(T)!T {
                    if (@sizeOf(Int) > @sizeOf(T)) {
                        return error.Overflow;
                    }

                    var slice: [@divExact(@typeInfo(Int).Int.bits, 8)]u8 = undefined;
                    std.mem.copy(u8, slice[0..], tkn.Integer.slice(tkns.buf, tkns.i));

                    return std.mem.readIntBig(Int, &slice);
                }
            };

            switch (int_token.len) {
                1 => return parseInt.parseInt(i8, token, tokens),
                2 => return parseInt.parseInt(i16, token, tokens),
                3 => return parseInt.parseInt(i24, token, tokens),
                4 => return parseInt.parseInt(i32, token, tokens),
                5 => return parseInt.parseInt(i40, token, tokens),
                6 => return parseInt.parseInt(i48, token, tokens),
                7 => return parseInt.parseInt(i56, token, tokens),
                8 => return parseInt.parseInt(i64, token, tokens),
                // TODO: up until i128
                else => return error.IntTooLarge,
            }
        },
        else => @panic("unsupported type!"),
    }
}

pub fn ParseError(comptime T: type) type {
    return ParseInternalError(T) || error{UnexpectedEndOfAsn1} || TokenStream.Error;
}

pub fn parse(comptime T: type, tokens: *TokenStream, options: ParseOptions) ParseError(T)!T {
    const token = (try tokens.next()) orelse return error.UnexpectedEndOfAsn1;
    const r = try parseInternal(T, token, tokens, options);

    return r;
}

pub fn parseFree(comptime T: type, value: T, options: ParseOptions) void {
    switch (@typeInfo(T)) {
        else => {},
    }

    switch (T) {
        ObjectIdentifier => {
            const allocator = options.allocator orelse unreachable;
            allocator.free(value.object_identifier);
        },
        else => @panic("not implemented"),
    }
}

test "parse int" {
    var stream = TokenStream.init(&[_]u8{ 0x02, 0x00, 0x02, 0x02, 0x01, 0x00 });
    const res = try parse(i16, &stream, .{});

    try std.testing.expectEqual(@as(i16, 256), res);
}

test "parse object identifier" {
    const TestParseObjectIdentifier = struct {
        in: []const u8,
        out: []const i32,
        ok: bool,
    };

    const testParseObjectIdentifierData = [_]TestParseObjectIdentifier{
        .{
            .in = &.{ 0x06, 0x06, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d },
            .out = &.{ 1, 2, 840, 113549 },
            .ok = true,
        },
        .{
            .in = &.{},
            .out = &.{},
            .ok = false,
        },
        .{
            .in = &.{ 0x06, 0x01, 0x55 },
            .out = &.{ 2, 5 },
            .ok = true,
        },
        .{
            .in = &.{ 0x06, 0x02, 0x55, 0x02 },
            .out = &.{ 2, 5, 2 },
            .ok = true,
        },
        .{
            .in = &.{ 0x06, 0x04, 0x55, 0x02, 0xc0, 0x00 },
            .out = &.{ 2, 5, 2, 8192 },
            .ok = true,
        },
        .{
            .in = &.{ 0x06, 0x03, 0x81, 0x34, 0x03 },
            .out = &.{ 2, 100, 3 },
            .ok = true,
        },
        .{
            .in = &.{ 0x06, 0x07, 0x55, 0x02, 0xc0, 0x80, 0x80, 0x80, 0x80 },
            .out = &.{},
            .ok = false,
        },
    };

    for (testParseObjectIdentifierData) |t| {
        var stream = TokenStream.init(t.in);
        const res = parse(ObjectIdentifier, &stream, .{ .allocator = std.testing.allocator }) catch |err| {
            std.testing.expect(!t.ok) catch {
                return err;
            };
            continue;
        };
        defer parseFree(ObjectIdentifier, res, .{ .allocator = std.testing.allocator });

        std.testing.expect(t.ok) catch |err| {
            std.debug.print("expecting test to fail, but got: {d}\n", .{res.object_identifier});
            return err;
        };
        std.testing.expect(std.mem.eql(i32, t.out, res.object_identifier)) catch |err| {
            std.debug.print("expecting: {d}\n", .{t.out});
            std.debug.print("found: {d}\n", .{res.object_identifier});

            return err;
        };
    }
}

// test "parse RSA" {
//     var stream = TokenStream.init(&[_]u8{ 0x06, 0x06, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d });
//     const res = try parse(ObjectIdentifier, &stream, .{ .allocator = std.testing.allocator });
//     defer std.testing.allocator.free(res.object_identifier);

//     var expected = [_]i32{ 1, 2, 840, 113549 };

//     try std.testing.expectEqualSlices(i32, expected[0..], res.object_identifier);
// }