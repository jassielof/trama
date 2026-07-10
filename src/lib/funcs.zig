//! Built-in template functions and FuncMap registration.

const std = @import("std");
const value_mod = @import("value.zig");
const escape_mod = @import("escape.zig");

const Value = value_mod.Value;

pub const Error = error{
    InvalidExpression,
    MissingField,
    OutOfMemory,
};

/// Builtin / user function: receives pipeline args (previous pipe result is
/// prepended by the executor for `|` stages after the first).
pub const Func = *const fn (allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue;

pub const OwnedValue = struct {
    value: Value,
    /// When set, caller must free this slice (and the value references it).
    owned: ?[]u8 = null,
    /// When set, deep-owned value tree (from clone).
    owned_tree: bool = false,

    pub fn deinit(self: *OwnedValue, allocator: std.mem.Allocator) void {
        if (self.owned) |s| allocator.free(s);
        if (self.owned_tree) {
            self.value.deinitOwned(allocator);
        }
        self.* = .{ .value = .null };
    }
};

pub const FuncMap = struct {
    map: std.StringHashMapUnmanaged(Func) = .empty,

    pub fn deinit(self: *FuncMap, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
    }

    pub fn put(self: *FuncMap, allocator: std.mem.Allocator, name: []const u8, func: Func) !void {
        try self.map.put(allocator, name, func);
    }

    pub fn get(self: *const FuncMap, name: []const u8) ?Func {
        return self.map.get(name);
    }
};

pub fn installBuiltins(map: *FuncMap, allocator: std.mem.Allocator) !void {
    try map.put(allocator, "and", fnAnd);
    try map.put(allocator, "or", fnOr);
    try map.put(allocator, "not", fnNot);
    try map.put(allocator, "eq", fnEq);
    try map.put(allocator, "ne", fnNe);
    try map.put(allocator, "lt", fnLt);
    try map.put(allocator, "le", fnLe);
    try map.put(allocator, "gt", fnGt);
    try map.put(allocator, "ge", fnGe);
    try map.put(allocator, "len", fnLen);
    try map.put(allocator, "index", fnIndex);
    try map.put(allocator, "slice", fnSlice);
    try map.put(allocator, "print", fnPrint);
    try map.put(allocator, "printf", fnPrintf);
    try map.put(allocator, "println", fnPrintln);
    try map.put(allocator, "default", fnDefault);
    try map.put(allocator, "join", fnJoin);
    try map.put(allocator, "anchor", fnAnchor);
    try map.put(allocator, "adoc_escape", fnAdocEscape);
}

fn fnAnd(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    _ = allocator;
    for (args) |a| {
        if (!a.truthy()) return .{ .value = .{ .bool = false } };
    }
    return .{ .value = .{ .bool = true } };
}

fn fnOr(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    _ = allocator;
    for (args) |a| {
        if (a.truthy()) return .{ .value = .{ .bool = true } };
    }
    return .{ .value = .{ .bool = false } };
}

fn fnNot(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    _ = allocator;
    if (args.len != 1) return error.InvalidExpression;
    return .{ .value = .{ .bool = !args[0].truthy() } };
}

fn compareEq(a: Value, b: Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |av| switch (b) {
            .bool => |bv| av == bv,
            else => false,
        },
        .int => |av| switch (b) {
            .int => |bv| av == bv,
            .float => |bv| @as(f64, @floatFromInt(av)) == bv,
            else => false,
        },
        .float => |av| switch (b) {
            .float => |bv| av == bv,
            .int => |bv| av == @as(f64, @floatFromInt(bv)),
            else => false,
        },
        .string => |av| switch (b) {
            .string => |bv| std.mem.eql(u8, av, bv),
            else => false,
        },
        else => false,
    };
}

fn asFloat(v: Value) ?f64 {
    return switch (v) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn fnEq(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    _ = allocator;
    if (args.len < 2) return error.InvalidExpression;
    const first = args[0];
    for (args[1..]) |a| {
        if (!compareEq(first, a)) return .{ .value = .{ .bool = false } };
    }
    return .{ .value = .{ .bool = true } };
}

fn fnNe(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    const eq = try fnEq(allocator, args);
    return .{ .value = .{ .bool = !eq.value.bool } };
}

fn fnLt(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidExpression;
    const a = asFloat(args[0]) orelse return error.InvalidExpression;
    const b = asFloat(args[1]) orelse return error.InvalidExpression;
    return .{ .value = .{ .bool = a < b } };
}

fn fnLe(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidExpression;
    const a = asFloat(args[0]) orelse return error.InvalidExpression;
    const b = asFloat(args[1]) orelse return error.InvalidExpression;
    return .{ .value = .{ .bool = a <= b } };
}

fn fnGt(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidExpression;
    const a = asFloat(args[0]) orelse return error.InvalidExpression;
    const b = asFloat(args[1]) orelse return error.InvalidExpression;
    return .{ .value = .{ .bool = a > b } };
}

fn fnGe(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidExpression;
    const a = asFloat(args[0]) orelse return error.InvalidExpression;
    const b = asFloat(args[1]) orelse return error.InvalidExpression;
    return .{ .value = .{ .bool = a >= b } };
}

fn fnLen(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    _ = allocator;
    if (args.len != 1) return error.InvalidExpression;
    const n: i64 = switch (args[0]) {
        .string => |s| @intCast(s.len),
        .list => |l| @intCast(l.len),
        .object => |o| @intCast(o.len),
        else => return error.InvalidExpression,
    };
    return .{ .value = .{ .int = n } };
}

fn fnIndex(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    _ = allocator;
    if (args.len < 2) return error.InvalidExpression;
    var current = args[0];
    for (args[1..]) |idx_v| {
        const idx: i64 = switch (idx_v) {
            .int => |i| i,
            else => return error.InvalidExpression,
        };
        current = switch (current) {
            .list => |items| blk: {
                if (idx < 0 or idx >= items.len) return error.InvalidExpression;
                break :blk items[@intCast(idx)];
            },
            .string => |s| blk: {
                if (idx < 0 or idx >= s.len) return error.InvalidExpression;
                break :blk Value{ .string = s[@intCast(idx)..][0..1] };
            },
            .object => |fields| blk: {
                // numeric index into object fields
                if (idx < 0 or idx >= fields.len) return error.InvalidExpression;
                break :blk fields[@intCast(idx)].value;
            },
            else => return error.InvalidExpression,
        };
    }
    return .{ .value = current };
}

fn fnSlice(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    if (args.len < 2 or args.len > 3) return error.InvalidExpression;
    const start: i64 = switch (args[1]) {
        .int => |i| i,
        else => return error.InvalidExpression,
    };
    switch (args[0]) {
        .string => |s| {
            const end: i64 = if (args.len == 3) switch (args[2]) {
                .int => |i| i,
                else => return error.InvalidExpression,
            } else @intCast(s.len);
            if (start < 0 or end < start or end > s.len) return error.InvalidExpression;
            const owned = try allocator.dupe(u8, s[@intCast(start)..@intCast(end)]);
            return .{ .value = .{ .string = owned }, .owned = owned };
        },
        .list => |items| {
            const end: i64 = if (args.len == 3) switch (args[2]) {
                .int => |i| i,
                else => return error.InvalidExpression,
            } else @intCast(items.len);
            if (start < 0 or end < start or end > items.len) return error.InvalidExpression;
            // Return a view into existing list (not owned) — fine for template lifetime.
            return .{ .value = .{ .list = items[@intCast(start)..@intCast(end)] } };
        },
        else => return error.InvalidExpression,
    }
}

fn fnPrint(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (args) |a| {
        try value_mod.appendStringified(allocator, &out, a);
    }
    const owned = try out.toOwnedSlice(allocator);
    return .{ .value = .{ .string = owned }, .owned = owned };
}

fn fnPrintln(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (args, 0..) |a, i| {
        if (i != 0) try out.append(allocator, ' ');
        try value_mod.appendStringified(allocator, &out, a);
    }
    try out.append(allocator, '\n');
    const owned = try out.toOwnedSlice(allocator);
    return .{ .value = .{ .string = owned }, .owned = owned };
}

fn fnPrintf(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    if (args.len < 1) return error.InvalidExpression;
    const fmt = switch (args[0]) {
        .string => |s| s,
        else => return error.InvalidExpression,
    };
    // Minimal printf: support %s, %d, %v, %% only.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var arg_i: usize = 1;
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            const spec = fmt[i + 1];
            i += 1;
            if (spec == '%') {
                try out.append(allocator, '%');
                continue;
            }
            if (arg_i >= args.len) return error.InvalidExpression;
            const a = args[arg_i];
            arg_i += 1;
            switch (spec) {
                's', 'v' => try value_mod.appendStringified(allocator, &out, a),
                'd' => switch (a) {
                    .int => |n| try out.print(allocator, "{d}", .{n}),
                    else => try value_mod.appendStringified(allocator, &out, a),
                },
                else => return error.InvalidExpression,
            }
            continue;
        }
        try out.append(allocator, fmt[i]);
    }
    const owned = try out.toOwnedSlice(allocator);
    return .{ .value = .{ .string = owned }, .owned = owned };
}

fn fnDefault(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    _ = allocator;
    if (args.len != 2) return error.InvalidExpression;
    if (args[0].truthy()) return .{ .value = args[0] };
    return .{ .value = args[1] };
}

fn fnJoin(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    if (args.len != 2) return error.InvalidExpression;
    const sep = switch (args[1]) {
        .string => |s| s,
        else => return error.InvalidExpression,
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    switch (args[0]) {
        .list => |items| {
            for (items, 0..) |item, i| {
                if (i != 0) try out.appendSlice(allocator, sep);
                try value_mod.appendStringified(allocator, &out, item);
            }
        },
        else => try value_mod.appendStringified(allocator, &out, args[0]),
    }
    const owned = try out.toOwnedSlice(allocator);
    return .{ .value = .{ .string = owned }, .owned = owned };
}

fn appendSlug(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var previous_dash = false;
    for (text) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            try out.append(allocator, std.ascii.toLower(ch));
            previous_dash = false;
        } else if (!previous_dash) {
            try out.append(allocator, '-');
            previous_dash = true;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        _ = out.pop();
    }
}

fn fnAnchor(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    if (args.len != 1) return error.InvalidExpression;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "cmd-");
    switch (args[0]) {
        .string => |text| try appendSlug(allocator, &out, text),
        else => {
            var tmp: std.ArrayList(u8) = .empty;
            defer tmp.deinit(allocator);
            try value_mod.appendStringified(allocator, &tmp, args[0]);
            try appendSlug(allocator, &out, tmp.items);
        },
    }
    const owned = try out.toOwnedSlice(allocator);
    return .{ .value = .{ .string = owned }, .owned = owned };
}

fn fnAdocEscape(allocator: std.mem.Allocator, args: []const Value) Error!OwnedValue {
    if (args.len != 1) return error.InvalidExpression;
    var stringified: std.ArrayList(u8) = .empty;
    defer stringified.deinit(allocator);
    try value_mod.appendStringified(allocator, &stringified, args[0]);
    var escaped: std.ArrayList(u8) = .empty;
    errdefer escaped.deinit(allocator);
    try escape_mod.escapeAsciiDoc(allocator, &escaped, stringified.items);
    const owned = try escaped.toOwnedSlice(allocator);
    return .{ .value = .{ .string = owned }, .owned = owned };
}
