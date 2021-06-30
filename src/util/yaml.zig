const std = @import("std");
const yaml = @import("yaml");

const c = @cImport({
    @cInclude("yaml.h");
});
const u = @import("./index.zig");

//
//

const Array = []const []const u8;

pub const Stream = struct {
    docs: []const Document,
};

pub const Document = struct {
    mapping: Mapping,
};

pub const Item = union(enum) {
    event: Token,
    kv: Key,
    mapping: Mapping,
    sequence: Sequence,
    document: Document,
    string: []const u8,
    stream: Stream,

    pub fn format(self: Item, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
        try writer.writeAll("Item{");
        switch (self) {
            .event => {
                try std.fmt.format(writer, "{s}", .{@tagName(self.event.type)});
            },
            .kv, .document => {
                unreachable;
            },
            .mapping => {
                try std.fmt.format(writer, "{}", .{self.mapping});
            },
            .sequence => {
                try writer.writeAll("[ ");
                for (self.sequence) |it| {
                    try std.fmt.format(writer, "{}, ", .{it});
                }
                try writer.writeAll("]");
            },
            .string => {
                try std.fmt.format(writer, "{s}", .{self.string});
            },
        }
        try writer.writeAll("}");
    }
};

pub const Sequence = []const Item;

pub const Key = struct {
    key: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    string: []const u8,
    mapping: Mapping,
    sequence: Sequence,

    pub fn format(self: Value, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
        try writer.writeAll("Value{");
        switch (self) {
            .string => {
                try std.fmt.format(writer, "{s}", .{self.string});
            },
            .mapping => {
                try std.fmt.format(writer, "{}", .{self.mapping});
            },
            .sequence => {
                try writer.writeAll("[ ");
                for (self.sequence) |it| {
                    try std.fmt.format(writer, "{}, ", .{it});
                }
                try writer.writeAll("]");
            },
        }
        try writer.writeAll("}");
    }
};

pub const Mapping = struct {
    items: []const Key,

    pub fn get(self: Mapping, k: []const u8) ?Value {
        for (self.items) |item| {
            if (std.mem.eql(u8, item.key, k)) {
                return item.value;
            }
        }
        return null;
    }

    pub fn get_string(self: Mapping, k: []const u8) []const u8 {
        return if (self.get(k)) |v| v.string else "";
    }

    pub fn get_string_array(self: Mapping, alloc: *std.mem.Allocator, k: []const u8) ![][]const u8 {
        const list = &std.ArrayList([]const u8).init(alloc);
        defer list.deinit();
        if (self.get(k)) |val| {
            if (val == .sequence) {
                for (val.sequence) |item, i| {
                    if (item != .string) {
                        continue;
                    }
                    try list.append(item.string);
                }
            }
        }
        return list.toOwnedSlice();
    }

    pub fn format(self: Mapping, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
        try writer.writeAll("{ ");
        for (self.items) |it| {
            try std.fmt.format(writer, "{s}: ", .{it.key});
            try std.fmt.format(writer, "{}, ", .{it.value});
        }
        try writer.writeAll("}");
    }
};

pub const Token = c.yaml_event_t;
pub const TokenList = []const Token;

pub const EventType = enum(c_uint) {
    none = @as(c_uint, c.YAML_NO_EVENT),
    stream_start = @as(c_uint, c.YAML_STREAM_START_EVENT),
    stream_end = @as(c_uint, c.YAML_STREAM_END_EVENT),
    document_start = @as(c_uint, c.YAML_DOCUMENT_START_EVENT),
    document_end = @as(c_uint, c.YAML_DOCUMENT_END_EVENT),
    alias = @as(c_uint, c.YAML_ALIAS_EVENT),
    scalar = @as(c_uint, c.YAML_SCALAR_EVENT),
    sequence_start = @as(c_uint, c.YAML_SEQUENCE_START_EVENT),
    sequence_end = @as(c_uint, c.YAML_SEQUENCE_END_EVENT),
    mapping_start = @as(c_uint, c.YAML_MAPPING_START_EVENT),
    mapping_end = @as(c_uint, c.YAML_MAPPING_END_EVENT),
};

//
//

pub fn parse(alloc: *std.mem.Allocator, input: []const u8) !Document {
    var parser: c.yaml_parser_t = undefined;
    _ = c.yaml_parser_initialize(&parser);

    const lines = try u.split(input, "\n");

    _ = c.yaml_parser_set_input_string(&parser, input.ptr, input.len);

    const all_events = &std.ArrayList(Token).init(alloc);
    var event: Token = undefined;
    while (true) {
        const p = c.yaml_parser_parse(&parser, &event);
        if (p == 0) {
            break;
        }

        const et = event.type;
        try all_events.append(event);
        c.yaml_event_delete(&event);

        if (et == c.YAML_STREAM_END_EVENT) {
            break;
        }
    }

    c.yaml_parser_delete(&parser);

    const p = &Parser{
        .alloc = alloc,
        .tokens = all_events.items,
        .lines = lines,
        .index = 0,
    };
    const stream = try p.parse();
    return stream.docs[0];
}

pub const Parser = struct {
    alloc: *std.mem.Allocator,
    tokens: TokenList,
    lines: Array,
    index: usize,

    pub fn parse(self: *Parser) !Stream {
        const item = try parse_item(self, null);
        return item.stream;
    }

    fn next(self: *Parser) ?Token {
        if (self.index >= self.tokens.len) {
            return null;
        }
        defer self.index += 1;
        return self.tokens[self.index];
    }
};

pub const Error =
    std.mem.Allocator.Error ||
    error{YamlUnexpectedToken};

fn parse_item(p: *Parser, start: ?Token) Error!Item {
    const tok = start orelse p.next();
    return switch (@intToEnum(EventType, tok.?.type)) {
        .stream_start => Item{ .stream = try parse_stream(p) },
        .document_start => Item{ .document = try parse_document(p) },
        .mapping_start => Item{ .mapping = try parse_mapping(p) },
        .sequence_start => Item{ .sequence = try parse_sequence(p) },
        .scalar => Item{ .string = get_event_string(tok.?, p.lines) },
        else => unreachable,
    };
}

fn parse_stream(p: *Parser) Error!Stream {
    const res = &std.ArrayList(Document).init(p.alloc);
    defer res.deinit();

    while (true) {
        const tok = p.next();
        if (@intToEnum(EventType, tok.?.type) == .stream_end) {
            return Stream{ .docs = res.toOwnedSlice() };
        }
        if (@intToEnum(EventType, tok.?.type) != .document_start) {
            return error.YamlUnexpectedToken;
        }
        const item = try parse_item(p, tok);
        try res.append(item.document);
    }
}

fn parse_document(p: *Parser) Error!Document {
    const tok = p.next();
    if (@intToEnum(EventType, tok.?.type) != .mapping_start) {
        return error.YamlUnexpectedToken;
    }
    const item = try parse_item(p, tok);

    if (@intToEnum(EventType, p.next().?.type) != .document_end) {
        return error.YamlUnexpectedToken;
    }
    return Document{ .mapping = item.mapping };
}

fn parse_mapping(p: *Parser) Error!Mapping {
    const res = &std.ArrayList(Key).init(p.alloc);
    defer res.deinit();

    while (true) {
        const tok = p.next();
        if (@intToEnum(EventType, tok.?.type) == .mapping_end) {
            return Mapping{ .items = res.toOwnedSlice() };
        }
        if (@intToEnum(EventType, tok.?.type) != .scalar) {
            return error.YamlUnexpectedToken;
        }
        try res.append(Key{
            .key = get_event_string(tok.?, p.lines),
            .value = try parse_value(p),
        });
    }
}

fn parse_value(p: *Parser) Error!Value {
    const item = try parse_item(p, null);
    return switch (item) {
        .mapping => |x| Value{ .mapping = x },
        .sequence => |x| Value{ .sequence = x },
        .string => |x| Value{ .string = x },
        else => unreachable,
    };
}

fn parse_sequence(p: *Parser) Error!Sequence {
    const res = &std.ArrayList(Item).init(p.alloc);
    defer res.deinit();

    while (true) {
        const tok = p.next();
        if (@intToEnum(EventType, tok.?.type) == .sequence_end) {
            return res.toOwnedSlice();
        }
        try res.append(try parse_item(p, tok));
    }
}

fn get_event_string(event: Token, lines: Array) []const u8 {
    const sm = event.start_mark;
    const em = event.end_mark;
    return lines[sm.line][sm.column..em.column];
}
