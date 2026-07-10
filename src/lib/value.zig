//! Dynamic values for template contexts (struct → object tree).

const std = @import("std");

pub const Field = struct {
    name: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    list: []Value,
    object: []Field,

    pub fn from(allocator: std.mem.Allocator, value: anytype) !Value {
        return fromTyped(allocator, @TypeOf(value), value);
    }

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .list => |items| {
                for (items) |*item| item.deinit(allocator);
                allocator.free(items);
            },
            .object => |fields| {
                for (fields) |*field| field.value.deinit(allocator);
                allocator.free(fields);
            },
            else => {},
        }
        self.* = .null;
    }

    pub fn truthy(self: Value) bool {
        return switch (self) {
            .null => false,
            .bool => |v| v,
            .int => |v| v != 0,
            .float => |v| v != 0,
            .string => |v| v.len != 0,
            .list => |v| v.len != 0,
            .object => |v| v.len != 0,
        };
    }

    pub fn clone(self: Value, allocator: std.mem.Allocator) !Value {
        return switch (self) {
            .null => .null,
            .bool => |v| .{ .bool = v },
            .int => |v| .{ .int = v },
            .float => |v| .{ .float = v },
            .string => |v| .{ .string = try allocator.dupe(u8, v) },
            .list => |items| blk: {
                var out = try allocator.alloc(Value, items.len);
                errdefer allocator.free(out);
                for (items, 0..) |item, i| {
                    out[i] = try item.clone(allocator);
                }
                break :blk .{ .list = out };
            },
            .object => |fields| blk: {
                var out = try allocator.alloc(Field, fields.len);
                errdefer allocator.free(out);
                for (fields, 0..) |field, i| {
                    out[i] = .{
                        .name = try allocator.dupe(u8, field.name),
                        .value = try field.value.clone(allocator),
                    };
                }
                break :blk .{ .object = out };
            },
        };
    }

    /// Deep-free a value produced by `clone` (strings/names owned).
    pub fn deinitOwned(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .list => |items| {
                for (items) |*item| item.deinitOwned(allocator);
                allocator.free(items);
            },
            .object => |fields| {
                for (fields) |*field| {
                    allocator.free(field.name);
                    field.value.deinitOwned(allocator);
                }
                allocator.free(fields);
            },
            else => {},
        }
        self.* = .null;
    }
};

pub fn fromTyped(allocator: std.mem.Allocator, comptime T: type, value: T) !Value {
    const info = @typeInfo(T);
    switch (info) {
        .bool => return .{ .bool = value },
        .int, .comptime_int => return .{ .int = @intCast(value) },
        .float, .comptime_float => return .{ .float = @floatCast(value) },
        .optional => |opt| {
            if (value) |child| return fromTyped(allocator, opt.child, child);
            return .null;
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return .{ .string = value };
            }
            if (ptr.size == .slice) {
                var items = try allocator.alloc(Value, value.len);
                errdefer allocator.free(items);
                for (value, 0..) |item, i| {
                    items[i] = try fromTyped(allocator, ptr.child, item);
                }
                return .{ .list = items };
            }
            if (ptr.size == .one) {
                const child_info = @typeInfo(ptr.child);
                if (child_info == .array) {
                    const arr = child_info.array;
                    if (arr.child == u8) {
                        return .{ .string = value[0..] };
                    }
                    var items = try allocator.alloc(Value, value.len);
                    errdefer allocator.free(items);
                    for (value, 0..) |item, i| {
                        items[i] = try fromTyped(allocator, arr.child, item);
                    }
                    return .{ .list = items };
                }
                return fromTyped(allocator, ptr.child, value.*);
            }
            return .null;
        },
        .array => |arr| {
            if (arr.child == u8) {
                return .{ .string = value[0..] };
            }
            var items = try allocator.alloc(Value, value.len);
            errdefer allocator.free(items);
            for (value, 0..) |item, i| {
                items[i] = try fromTyped(allocator, arr.child, item);
            }
            return .{ .list = items };
        },
        .@"struct" => |st| {
            var fields = try allocator.alloc(Field, st.fields.len);
            errdefer allocator.free(fields);
            inline for (st.fields, 0..) |field, i| {
                fields[i] = .{
                    .name = field.name,
                    .value = try fromTyped(allocator, field.type, @field(value, field.name)),
                };
            }
            return .{ .object = fields };
        },
        .@"enum" => return .{ .string = @tagName(value) },
        else => return .null,
    }
}

pub fn lookupPath(value: *const Value, path: []const u8) ?*const Value {
    if (path.len == 0) return value;

    var current = value;
    var rest = path;
    while (rest.len > 0) {
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
        const name = rest[0..dot];
        if (name.len == 0) return null;
        current = lookupField(current, name) orelse return null;
        rest = if (dot == rest.len) "" else rest[dot + 1 ..];
    }
    return current;
}

pub fn lookupField(value: *const Value, name: []const u8) ?*const Value {
    return switch (value.*) {
        .object => |fields| {
            for (fields) |*field| {
                if (std.mem.eql(u8, field.name, name)) return &field.value;
            }
            return null;
        },
        else => null,
    };
}

pub fn stringify(allocator: std.mem.Allocator, value: Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendStringified(allocator, &out, value);
    return out.toOwnedSlice(allocator);
}

pub fn appendStringified(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: Value) !void {
    switch (value) {
        .null => {},
        .bool => |v| try out.appendSlice(allocator, if (v) "true" else "false"),
        .int => |v| try out.print(allocator, "{d}", .{v}),
        .float => |v| try out.print(allocator, "{d}", .{v}),
        .string => |v| try out.appendSlice(allocator, v),
        .list => |items| {
            for (items, 0..) |item, i| {
                if (i != 0) try out.appendSlice(allocator, ", ");
                try appendStringified(allocator, out, item);
            }
        },
        .object => return error.InvalidExpression,
    }
}
