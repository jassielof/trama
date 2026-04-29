const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

pub const EscapeMode = enum {
    none,
    asciidoc,
    html,
    url,
};

pub const Options = struct {
    escape_mode: EscapeMode = .none,
};

pub const Error = error{
    UnclosedTemplateBlock,
    UnexpectedEnd,
    UnexpectedElse,
    UnexpectedEndBlock,
    MissingEndBlock,
    MissingField,
    InvalidExpression,
    InvalidRange,
    OutOfMemory,
};

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

    fn truthy(self: Value) bool {
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
};

pub fn renderAlloc(
    allocator: std.mem.Allocator,
    template: []const u8,
    context: anytype,
    options: Options,
) ![]u8 {
    var root = try Value.from(allocator, context);
    defer root.deinit(allocator);
    return renderValueAlloc(allocator, template, &root, options);
}

pub fn renderValueAlloc(
    allocator: std.mem.Allocator,
    template: []const u8,
    root: *const Value,
    options: Options,
) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, template.len);
    errdefer out.deinit(allocator);

    var renderer = Renderer{
        .allocator = allocator,
        .template = template,
        .root = root,
        .options = options,
        .out = &out,
    };
    try renderer.renderSection(0, template.len, root);

    return out.toOwnedSlice(allocator);
}

fn fromTyped(allocator: std.mem.Allocator, comptime T: type, value: T) !Value {
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

const EvalResult = struct {
    value: Value,
    owned: ?[]u8 = null,

    fn deinit(self: EvalResult, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| allocator.free(owned);
    }
};

const Block = struct {
    else_tag_start: ?usize = null,
    else_content_start: ?usize = null,
    end_tag_start: usize,
    end_after: usize,
};

const Renderer = struct {
    allocator: std.mem.Allocator,
    template: []const u8,
    root: *const Value,
    options: Options,
    out: *std.ArrayList(u8),

    fn renderSection(self: *Renderer, start: usize, end: usize, current: *const Value) Error!void {
        var cursor = start;
        while (cursor < end) {
            const open_rel = std.mem.indexOf(u8, self.template[cursor..end], "{{") orelse {
                try self.appendRaw(self.template[cursor..end]);
                return;
            };
            const open = cursor + open_rel;
            try self.appendRaw(self.template[cursor..open]);

            const close = std.mem.indexOf(u8, self.template[open + 2 .. end], "}}") orelse return error.UnclosedTemplateBlock;
            const tag_end = open + 2 + close;
            const tag = trim(self.template[open + 2 .. tag_end]);

            if (std.mem.startsWith(u8, tag, "if ")) {
                const expr = trim(tag[3..]);
                const block = try self.findBlock(tag_end + 2, end);
                const condition = try self.eval(expr, current);
                defer condition.deinit(self.allocator);

                if (condition.value.truthy()) {
                    try self.renderSection(tag_end + 2, block.else_tag_start orelse block.end_tag_start, current);
                } else if (block.else_content_start) |else_start| {
                    try self.renderSection(else_start, block.end_tag_start, current);
                }
                cursor = block.end_after;
                continue;
            }

            if (std.mem.startsWith(u8, tag, "range ")) {
                const expr = trim(tag[6..]);
                const block = try self.findBlock(tag_end + 2, end);
                const collection = try self.eval(expr, current);
                defer collection.deinit(self.allocator);

                switch (collection.value) {
                    .list => |items| {
                        if (items.len == 0 and block.else_content_start != null) {
                            try self.renderSection(block.else_content_start.?, block.end_tag_start, current);
                        } else {
                            for (items) |*item| {
                                try self.renderSection(tag_end + 2, block.else_tag_start orelse block.end_tag_start, item);
                            }
                        }
                    },
                    else => return error.InvalidRange,
                }
                cursor = block.end_after;
                continue;
            }

            if (std.mem.eql(u8, tag, "else")) return error.UnexpectedElse;
            if (std.mem.eql(u8, tag, "end")) return error.UnexpectedEndBlock;

            var raw = false;
            var expr = tag;
            if (std.mem.startsWith(u8, expr, "@raw ")) {
                raw = true;
                expr = trim(expr[5..]);
            }

            const result = try self.eval(expr, current);
            defer result.deinit(self.allocator);
            try self.appendValue(result.value, raw);
            cursor = tag_end + 2;
        }
    }

    fn findBlock(self: *Renderer, start: usize, limit: usize) Error!Block {
        var cursor = start;
        var depth: usize = 0;
        while (cursor < limit) {
            const open_rel = std.mem.indexOf(u8, self.template[cursor..limit], "{{") orelse return error.MissingEndBlock;
            const open = cursor + open_rel;
            const close_rel = std.mem.indexOf(u8, self.template[open + 2 .. limit], "}}") orelse return error.UnclosedTemplateBlock;
            const tag_end = open + 2 + close_rel;
            const tag = trim(self.template[open + 2 .. tag_end]);

            if (std.mem.startsWith(u8, tag, "if ") or std.mem.startsWith(u8, tag, "range ")) {
                depth += 1;
            } else if (std.mem.eql(u8, tag, "end")) {
                if (depth == 0) {
                    return .{ .end_tag_start = open, .end_after = tag_end + 2 };
                }
                depth -= 1;
            } else if (std.mem.eql(u8, tag, "else") and depth == 0) {
                const tail = try self.findBlock(tag_end + 2, limit);
                return .{
                    .else_tag_start = open,
                    .else_content_start = tag_end + 2,
                    .end_tag_start = tail.end_tag_start,
                    .end_after = tail.end_after,
                };
            }

            cursor = tag_end + 2;
        }
        return error.MissingEndBlock;
    }

    fn eval(self: *Renderer, expr: []const u8, current: *const Value) Error!EvalResult {
        if (expr.len == 0) return error.InvalidExpression;

        var iter = TokenIterator.init(expr);
        const head = iter.next() orelse return error.InvalidExpression;
        const rest = trim(expr[head.end..]);

        if (rest.len > 0 and std.mem.eql(u8, head.value, "default")) return self.evalDefault(rest, current);
        if (rest.len > 0 and std.mem.eql(u8, head.value, "join")) return self.evalJoin(rest, current);
        if (rest.len > 0 and std.mem.eql(u8, head.value, "anchor")) return self.evalAnchor(rest, current);
        if (rest.len > 0 and std.mem.eql(u8, head.value, "adoc_escape")) return self.evalAdocEscape(rest, current);

        if (head.quoted and rest.len == 0) return .{ .value = .{ .string = head.value } };
        if (!head.quoted and rest.len == 0) {
            if (std.mem.eql(u8, head.value, "true")) return .{ .value = .{ .bool = true } };
            if (std.mem.eql(u8, head.value, "false")) return .{ .value = .{ .bool = false } };
            return .{ .value = (try self.resolve(head.value, current)).* };
        }
        return error.InvalidExpression;
    }

    fn evalDefault(self: *Renderer, expr: []const u8, current: *const Value) Error!EvalResult {
        var iter = TokenIterator.init(expr);
        const primary = iter.next() orelse return error.InvalidExpression;
        const fallback = iter.next() orelse return error.InvalidExpression;
        if (iter.next() != null) return error.InvalidExpression;

        const primary_value = if (primary.quoted)
            Value{ .string = primary.value }
        else
            (try self.resolve(primary.value, current)).*;
        if (primary_value.truthy()) return .{ .value = primary_value };

        if (fallback.quoted) return .{ .value = .{ .string = fallback.value } };
        return .{ .value = (try self.resolve(fallback.value, current)).* };
    }

    fn evalJoin(self: *Renderer, expr: []const u8, current: *const Value) Error!EvalResult {
        var iter = TokenIterator.init(expr);
        const list_expr = iter.next() orelse return error.InvalidExpression;
        const separator = iter.next() orelse return error.InvalidExpression;
        if (iter.next() != null) return error.InvalidExpression;

        const list_value = if (list_expr.quoted)
            Value{ .string = list_expr.value }
        else
            (try self.resolve(list_expr.value, current)).*;

        var out = try std.ArrayList(u8).initCapacity(self.allocator, 64);
        errdefer out.deinit(self.allocator);
        switch (list_value) {
            .list => |items| {
                for (items, 0..) |item, i| {
                    if (i != 0) try out.appendSlice(self.allocator, separator.value);
                    try self.appendStringified(&out, item);
                }
            },
            else => try self.appendStringified(&out, list_value),
        }

        const owned = try out.toOwnedSlice(self.allocator);
        return .{ .value = .{ .string = owned }, .owned = owned };
    }

    fn evalAnchor(self: *Renderer, expr: []const u8, current: *const Value) Error!EvalResult {
        var iter = TokenIterator.init(expr);
        const path = iter.next() orelse return error.InvalidExpression;
        if (iter.next() != null) return error.InvalidExpression;

        const value = if (path.quoted) Value{ .string = path.value } else (try self.resolve(path.value, current)).*;
        var out = try std.ArrayList(u8).initCapacity(self.allocator, 32);
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "cmd-");
        switch (value) {
            .string => |text| try appendSlug(self.allocator, &out, text),
            else => {
                var tmp = try std.ArrayList(u8).initCapacity(self.allocator, 32);
                defer tmp.deinit(self.allocator);
                try self.appendStringified(&tmp, value);
                try appendSlug(self.allocator, &out, tmp.items);
            },
        }
        const owned = try out.toOwnedSlice(self.allocator);
        return .{ .value = .{ .string = owned }, .owned = owned };
    }

    fn evalAdocEscape(self: *Renderer, expr: []const u8, current: *const Value) Error!EvalResult {
        const value = try self.eval(expr, current);
        defer value.deinit(self.allocator);
        var stringified = try std.ArrayList(u8).initCapacity(self.allocator, 64);
        defer stringified.deinit(self.allocator);
        try self.appendStringified(&stringified, value.value);

        var escaped = try std.ArrayList(u8).initCapacity(self.allocator, stringified.items.len);
        errdefer escaped.deinit(self.allocator);
        try escapeAsciiDoc(self.allocator, &escaped, stringified.items);
        const owned = try escaped.toOwnedSlice(self.allocator);
        return .{ .value = .{ .string = owned }, .owned = owned };
    }

    fn resolve(self: *Renderer, path: []const u8, current: *const Value) Error!*const Value {
        if (std.mem.eql(u8, path, ".")) return current;
        if (std.mem.eql(u8, path, "$")) return self.root;
        if (std.mem.startsWith(u8, path, "$.")) {
            return lookupPath(self.root, path[2..]) orelse error.MissingField;
        }
        if (std.mem.startsWith(u8, path, ".")) {
            return lookupPath(current, path[1..]) orelse error.MissingField;
        }
        if (lookupPath(current, path)) |value| return value;
        return lookupPath(self.root, path) orelse error.MissingField;
    }

    fn appendValue(self: *Renderer, value: Value, raw: bool) Error!void {
        var rendered = try std.ArrayList(u8).initCapacity(self.allocator, 32);
        defer rendered.deinit(self.allocator);
        try self.appendStringified(&rendered, value);

        if (raw or self.options.escape_mode == .none) {
            try self.appendRaw(rendered.items);
            return;
        }
        switch (self.options.escape_mode) {
            .none => try self.appendRaw(rendered.items),
            .asciidoc => try escapeAsciiDoc(self.allocator, self.out, rendered.items),
            .html => try escapeHtml(self.allocator, self.out, rendered.items),
            .url => try escapeUrl(self.allocator, self.out, rendered.items),
        }
    }

    fn appendStringified(self: *Renderer, out: *std.ArrayList(u8), value: Value) Error!void {
        switch (value) {
            .null => {},
            .bool => |v| try out.appendSlice(self.allocator, if (v) "true" else "false"),
            .int => |v| try out.print(self.allocator, "{}", .{v}),
            .float => |v| try out.print(self.allocator, "{d}", .{v}),
            .string => |v| try out.appendSlice(self.allocator, v),
            .list => |items| {
                for (items, 0..) |item, i| {
                    if (i != 0) try out.appendSlice(self.allocator, ", ");
                    try self.appendStringified(out, item);
                }
            },
            .object => return error.InvalidExpression,
        }
    }

    fn appendRaw(self: *Renderer, text: []const u8) Error!void {
        try self.out.appendSlice(self.allocator, text);
    }
};

const Token = struct {
    value: []const u8,
    end: usize,
    quoted: bool = false,
};

const TokenIterator = struct {
    input: []const u8,
    index: usize = 0,

    fn init(input: []const u8) TokenIterator {
        return .{ .input = trim(input) };
    }

    fn next(self: *TokenIterator) ?Token {
        while (self.index < self.input.len and std.ascii.isWhitespace(self.input[self.index])) {
            self.index += 1;
        }
        if (self.index >= self.input.len) return null;

        const start = self.index;
        if (self.input[start] == '"') {
            self.index += 1;
            const value_start = self.index;
            while (self.index < self.input.len and self.input[self.index] != '"') {
                self.index += 1;
            }
            if (self.index >= self.input.len) return null;
            const value = self.input[value_start..self.index];
            self.index += 1;
            return .{ .value = value, .end = self.index, .quoted = true };
        }

        while (self.index < self.input.len and !std.ascii.isWhitespace(self.input[self.index])) {
            self.index += 1;
        }
        return .{ .value = self.input[start..self.index], .end = self.index };
    }
};

fn lookupPath(value: *const Value, path: []const u8) ?*const Value {
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

fn lookupField(value: *const Value, name: []const u8) ?*const Value {
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

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
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

fn escapeAsciiDoc(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '{', '}', '<', '>' => {
                try out.append(allocator, '\\');
                try out.append(allocator, ch);
            },
            else => try out.append(allocator, ch),
        }
    }
}

fn escapeHtml(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&#39;"),
            else => try out.append(allocator, ch),
        }
    }
}

fn escapeUrl(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (text) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[ch >> 4]);
            try out.append(allocator, hex[ch & 0x0f]);
        }
    }
}

comptime {
    refAllDecls(@This());
}

test "interpolates fields and escapes asciidoc braces" {
    const ctx = .{ .name = "docent", .description = "Use {app-name}" };
    const rendered = try renderAlloc(std.testing.allocator, "{{ name }}: {{ description }}", ctx, .{ .escape_mode = .asciidoc });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("docent: Use \\{app-name\\}", rendered);
}

test "supports conditionals ranges current item and raw output" {
    const Item = struct { name: []const u8 };
    const ctx = .{
        .items = &[_]Item{ .{ .name = "one" }, .{ .name = "two" } },
        .markup = "`trusted`",
    };
    const rendered = try renderAlloc(
        std.testing.allocator,
        "{{ if items }}{{ range items }}{{ .name }} {{ end }}{{ else }}empty{{ end }}{{ @raw markup }}",
        ctx,
        .{ .escape_mode = .asciidoc },
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("one two `trusted`", rendered);
}

test "supports default join and anchors" {
    const ctx = .{
        .missing = "",
        .values = &[_][]const u8{ "pretty", "json" },
        .path = "docent docs",
    };
    const rendered = try renderAlloc(
        std.testing.allocator,
        "{{ default missing \"-\" }} {{ join values \", \" }} {{ anchor path }}",
        ctx,
        .{},
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("- pretty, json cmd-docent-docs", rendered);
}
