// Reference: https://luca.ntop.org/Teaching/Appunti/asn1.html

const std = @import("std");
const big = std.math.big;
const builtin = @import("builtin");
const mem = std.mem;

const Parser = @import("Parser.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Tag = enum(u5) {
    integer = 2,
    bit_string = 3,
    octet_string = 4,
    null = 5,
    object_identifier = 6,
    sequence = 16,
    set = 17,
    _,
};

// TODO:
// 1. Differ between bit string, octect string, sequence of and set of
// 2. Differ between sequence and set
// 3. Allow CHOICE (union)
// 4. Allow OBJECT IDENTIFIER (int slice?)
pub fn parse(comptime T: type, parser: *Parser) !T {
    const parser_cursor_start = parser.cursor;
    errdefer parser.cursor = parser_cursor_start;

    if (T == Value) {
        return Value.parseOne(parser);
    }

    switch (@typeInfo(T)) {
        .Int => {
            const val = try Value.parseOne(parser);
            const int_val = try val.asInteger();

            return int_val.toFixed(T);
        },
        .Pointer => |ptr_info| {
            if (ptr_info.size != .Slice) @compileError("Pointer types must be slices");

            switch (ptr_info.child) {
                u8 => {
                    const val = try Value.parseOne(parser);
                    const octet_string_val = try val.asOctetString();

                    return @constCast(octet_string_val.bytes);
                },
                else => @compileError("Not a supported type"),
            }
        },
        .Array => |arr_info| {
            const slice_val = try parse([]arr_info.child, parser);
            if (slice_val.len != arr_info.len) return error.WrongArrayLength;

            var arr: T = undefined;
            @memcpy(&arr, slice_val);

            return arr;
        },
        .Struct => |st_info| {
            const val = try Value.parseOne(parser);
            const seq = try val.asSequence();
            var seq_parser = Parser{ .input = seq.bytes };

            var ret_val: T = undefined;
            inline for (st_info.fields) |field| {
                // Optional are only allowed inside structured types so we must test this here.
                switch (@typeInfo(field.type)) {
                    .Optional => |opt_info| {
                        @field(ret_val, field.name) = parse(opt_info.child, &seq_parser) catch blk: {
                            break :blk null;
                        };
                    },
                    else => {
                        @field(ret_val, field.name) = try parse(field.type, &seq_parser);
                    },
                }
            }

            return ret_val;
        },
        else => @compileError("Not a supported type"),
    }
}

pub const Value = union(enum) {
    integer: Integer,
    bit_string: BitString,
    octet_string: OctetString,
    null,
    object_identifier: ObjectIdentifier,
    sequence: Sequence,
    set: Set,
    custom: Custom,

    pub const Integer = struct {
        bytes: []const u8,

        pub fn toFixed(self: Integer, comptime IntT: type) !IntT {
            const type_info = @typeInfo(IntT).Int;
            if (type_info.signedness != .signed) @compileError("Must be a signed int type");
            if (type_info.bits / 8 < self.bytes.len) return error.IntTypeTooSmall;

            var val = mem.readVarInt(IntT, self.bytes, .big);

            // If we got a negative number we must extend the sign bit
            // TODO: find a better algorithm.
            if (self.bytes[0] & 0x80 == 0x80) {
                const num_bits = self.bytes.len * 8;
                for (num_bits..type_info.bits) |b| {
                    val = val | (@as(IntT, 1) << @intCast(b));
                }
            }

            return val;
        }
    };

    pub const BitString = struct {
        bytes: []const u8,

        pub fn unusedBitsCount(self: BitString) u8 {
            if (self.bytes.len == 0) return 0;
            return self.bytes[0];
        }

        pub fn string(self: BitString) []const u8 {
            if (self.bytes.len <= 1) return &.{};
            return self.bytes[1..];
        }
    };

    pub const OctetString = struct {
        bytes: []const u8,
    };

    pub const ObjectIdentifier = struct {
        bytes: []const u8,
    };

    pub const Sequence = struct {
        bytes: []const u8,

        pub fn iterator(self: Sequence) ValueIterator {
            return ValueIterator.init(self.bytes);
        }
    };

    pub const Set = struct {
        bytes: []const u8,

        pub fn iterator(self: Set) ValueIterator {
            return ValueIterator.init(self.bytes);
        }
    };

    pub const Custom = struct {
        // TODO: Tags can be much larger than this but we still don't support
        // high tag numbers.
        tag: u8,
        bytes: []const u8,
    };

    pub fn parseOne(p: *Parser) !Value {
        const tag_byte = try p.parseAny();
        if (tag_byte == 0x1F) {
            return error.HighTagNumberNotSupported;
        }
        const tag: Tag = @enumFromInt(tag_byte & 0x1F);

        const length_byte = try p.parseAny();
        var length: usize = undefined;
        if (length_byte & 0x80 == 0x80) {
            const max_octets_count = @sizeOf(usize);
            const octets_count: u8 = length_byte & 0x7F;

            // TODO: In the future we should allow bigger lengths but IDK.
            if (octets_count > max_octets_count) return error.LengthTooBig;

            var length_octets: [max_octets_count]u8 = .{0} ** max_octets_count;
            for (0..octets_count) |i| {
                // Length octects in big endian order
                length_octets[max_octets_count - octets_count + i] = try p.parseAny();
            }

            length = mem.readInt(usize, &length_octets, .big);
        } else {
            length = @intCast(length_byte);
        }

        const bytes = try p.parseAnyN(length);

        const val: Value = switch (tag) {
            .integer => .{ .integer = .{ .bytes = bytes } },
            .bit_string => .{ .bit_string = .{ .bytes = bytes } },
            .octet_string => .{ .octet_string = .{ .bytes = bytes } },
            .null => .null,
            .object_identifier => .{ .object_identifier = .{ .bytes = bytes } },
            .sequence => .{ .sequence = .{ .bytes = bytes } },
            .set => .{ .set = .{ .bytes = bytes } },
            _ => .{ .custom = .{ .tag = @intFromEnum(tag), .bytes = bytes } },
        };

        return val;
    }

    pub fn isNull(self: Value) bool {
        return self == .null;
    }

    pub fn asInteger(self: Value) !Integer {
        switch (self) {
            .integer => |i| return i,
            else => return error.Cast,
        }
    }

    pub fn asBitString(self: Value) !BitString {
        switch (self) {
            .bit_string => |s| return s,
            else => return error.Cast,
        }
    }

    pub fn asOctetString(self: Value) !OctetString {
        switch (self) {
            .octet_string => |s| return s,
            else => return error.Cast,
        }
    }

    pub fn asObjectIdentifier(self: Value) !ObjectIdentifier {
        switch (self) {
            .object_identifier => |oid| return oid,
            else => return error.Cast,
        }
    }

    pub fn asSequence(self: Value) !Sequence {
        switch (self) {
            .sequence => |s| return s,
            else => return error.Cast,
        }
    }

    pub fn asSet(self: Value) !Set {
        switch (self) {
            .set => |s| return s,
            else => return error.Cast,
        }
    }
};

pub const ValueIterator = struct {
    parser: Parser,

    pub fn init(bytes: []const u8) ValueIterator {
        return .{ .parser = .{ .input = bytes } };
    }

    pub fn next(self: *ValueIterator) !?Value {
        if (self.parser.peek() == null) return null;
        return try Value.parseOne(&self.parser);
    }
};

test "parse" {
    // int
    var p = Parser{ .input = &.{ @intFromEnum(Tag.integer), 1, 3 } };
    try std.testing.expectEqual(@as(i32, 3), try parse(i32, &p));

    // octet string
    p = .{ .input = &.{ @intFromEnum(Tag.octet_string), 5, 1, 2, 3, 4, 5 } };
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, try parse([]const u8, &p));

    // Struct (sequence with optional)
    const TestT = struct {
        i: i32,
        o: ?i16,
        s: []const u8,
    };

    // when optional value is not included in the sequence
    p = .{ .input = &.{ @intFromEnum(Tag.sequence), 8, @intFromEnum(Tag.integer), 1, 5, @intFromEnum(Tag.octet_string), 3, 1, 2, 3 } };
    try std.testing.expectEqualDeep(TestT{ .i = 5, .s = &.{ 1, 2, 3 }, .o = null }, try parse(TestT, &p));

    // with optional value included in the sequence
    p = .{ .input = &.{ @intFromEnum(Tag.sequence), 11, @intFromEnum(Tag.integer), 1, 5, @intFromEnum(Tag.integer), 1, 0xF5, @intFromEnum(Tag.octet_string), 3, 1, 2, 3 } };
    try std.testing.expectEqualDeep(TestT{ .i = 5, .s = &.{ 1, 2, 3 }, .o = -11 }, try parse(TestT, &p));
}

test "Value.parse" {
    const input = [_]u8{ @intFromEnum(Tag.integer), 2, 1, 3 };
    var p = Parser{ .input = &input };

    try std.testing.expectEqualDeep(Value{ .integer = .{ .bytes = input[2..] } }, Value.parseOne(&p));
}

test "Integer.toFixed" {
    const test_cases = [_]struct { val: Value.Integer, expected: i32 }{
        .{ .val = .{ .bytes = &.{1} }, .expected = 1 },
        .{ .val = .{ .bytes = &.{ 0, 0x80 } }, .expected = 128 },
        .{ .val = .{ .bytes = &.{0x80} }, .expected = -128 },
        .{ .val = .{ .bytes = &.{ 0xFF, 0x7F } }, .expected = -129 },
    };

    for (test_cases) |test_case| {
        try std.testing.expectEqual(test_case.expected, try test_case.val.toFixed(i32));
    }
}

test "ValueIterator" {
    var input = [_]u8{
        @intFromEnum(Tag.sequence),
        undefined,
        @intFromEnum(Tag.integer),
        2,
        1,
        2,
        @intFromEnum(Tag.null),
        0,
        @intFromEnum(Tag.octet_string),
        2,
        97,
        98,
    };
    input[1] = @intCast(input[2..].len);

    const expected = [_]Value{
        .{ .integer = .{ .bytes = input[4..6] } },
        .null,
        .{ .octet_string = .{ .bytes = input[10..12] } },
    };

    var parser = Parser{ .input = &input };
    const val = try Value.parseOne(&parser);
    const seq = try val.asSequence();

    var iter = seq.iterator();
    var i: usize = 0;
    while (try iter.next()) |elem_val| : (i += 1) {
        try std.testing.expectEqualDeep(expected[i], elem_val);
    }
}
