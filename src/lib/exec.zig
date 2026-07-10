//! Execute a parsed template tree against a Value context.

const std = @import("std");
const value_mod = @import("value.zig");
const escape_mod = @import("escape.zig");
const funcs = @import("funcs.zig");
const parse = @import("parse.zig");

const Value = value_mod.Value;
const OwnedValue = funcs.OwnedValue;

pub const Error = error{
    UnclosedTemplateBlock,
    UnclosedComment,
    UnexpectedEnd,
    UnexpectedElse,
    UnexpectedEndBlock,
    MissingEndBlock,
    MissingField,
    InvalidExpression,
    InvalidRange,
    UndefinedTemplate,
    BreakOutsideRange,
    ContinueOutsideRange,
    OutOfMemory,
};

pub const Options = struct {
    escape_mode: escape_mod.EscapeMode = .none,
    funcs: ?*const funcs.FuncMap = null,
};

const Control = enum { none, break_loop, continue_loop };

const VarEntry = struct {
    name: []const u8,
    value: Value,
};

const Executor = struct {
    allocator: std.mem.Allocator,
    tree: *const parse.Tree,
    root: *const Value,
    options: Options,
    out: *std.ArrayList(u8),
    builtins: *const funcs.FuncMap,
    vars: std.ArrayList(VarEntry),
    range_depth: usize = 0,

    fn execNodes(self: *Executor, nodes: []const parse.Node, dot: *const Value) Error!Control {
        for (nodes) |node| {
            const c = try self.execNode(node, dot);
            if (c != .none) return c;
        }
        return .none;
    }

    fn execNode(self: *Executor, node: parse.Node, dot: *const Value) Error!Control {
        switch (node) {
            .text => |t| {
                try self.out.appendSlice(self.allocator, t);
                return .none;
            },
            .action => |a| {
                var result = try self.evalPipeline(a.pipe, dot);
                defer result.deinit(self.allocator);
                // Go: `{{$x := pipeline}}` assigns without printing.
                if (a.pipe.decl != null) return .none;
                try self.writeValue(result.value, a.raw);
                return .none;
            },
            .if_node => |iff| {
                for (iff.arms) |arm| {
                    var cond = try self.evalPipeline(arm.pipe, dot);
                    defer cond.deinit(self.allocator);
                    if (cond.value.truthy()) {
                        return self.execNodes(arm.body, dot);
                    }
                }
                return self.execNodes(iff.else_body, dot);
            },
            .range => |rng| {
                // Decl binds loop variables; evaluate collection without applying decl.
                var coll = try self.evalPipelineCore(rng.pipe, dot, true);
                defer coll.deinit(self.allocator);
                switch (coll.value) {
                    .list => |items| {
                        if (items.len == 0) {
                            return self.execNodes(rng.else_body, dot);
                        }
                        self.range_depth += 1;
                        defer self.range_depth -= 1;
                        for (items, 0..) |*item, i| {
                            const var_mark = self.vars.items.len;
                            defer self.vars.shrinkRetainingCapacity(var_mark);
                            if (rng.pipe.decl) |decl| {
                                if (decl.names.len == 2) {
                                    try self.setVar(decl.names[0], .{ .int = @intCast(i) }, decl.assign);
                                    try self.setVar(decl.names[1], item.*, decl.assign);
                                } else if (decl.names.len == 1) {
                                    try self.setVar(decl.names[0], item.*, decl.assign);
                                }
                            }
                            const c = try self.execNodes(rng.body, item);
                            switch (c) {
                                .break_loop => break,
                                .continue_loop => continue,
                                .none => {},
                            }
                        }
                        return .none;
                    },
                    else => return error.InvalidRange,
                }
            },
            .with => |w| {
                var val = try self.evalPipeline(w.pipe, dot);
                defer val.deinit(self.allocator);
                if (val.value.truthy()) {
                    return self.execNodes(w.body, &val.value);
                }
                return self.execNodes(w.else_body, dot);
            },
            .template_call => |tc| {
                const body = self.tree.defines.get(tc.name) orelse return error.UndefinedTemplate;
                var new_dot = dot;
                var owned: ?OwnedValue = null;
                defer if (owned) |*o| o.deinit(self.allocator);
                if (tc.pipe) |pipe| {
                    owned = try self.evalPipeline(pipe, dot);
                    new_dot = &owned.?.value;
                }
                return self.execNodes(body, new_dot);
            },
            .break_cmd => {
                if (self.range_depth == 0) return error.BreakOutsideRange;
                return .break_loop;
            },
            .continue_cmd => {
                if (self.range_depth == 0) return error.ContinueOutsideRange;
                return .continue_loop;
            },
        }
    }

    fn setVar(self: *Executor, name: []const u8, val: Value, assign: bool) !void {
        if (assign) {
            var i: usize = self.vars.items.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, self.vars.items[i].name, name)) {
                    self.vars.items[i].value = val;
                    return;
                }
            }
            return error.MissingField; // assign to undefined
        }
        try self.vars.append(self.allocator, .{ .name = name, .value = val });
    }

    fn lookupVar(self: *Executor, name: []const u8) ?*const Value {
        var i: usize = self.vars.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.vars.items[i].name, name)) {
                return &self.vars.items[i].value;
            }
        }
        return null;
    }

    fn evalPipeline(self: *Executor, pipe: parse.Pipeline, dot: *const Value) Error!OwnedValue {
        const final = try self.evalPipelineCore(pipe, dot, false);
        if (pipe.decl) |decl| {
            if (decl.names.len == 1) {
                try self.setVar(decl.names[0], final.value, decl.assign);
            }
        }
        return final;
    }

    fn evalPipelineCore(self: *Executor, pipe: parse.Pipeline, dot: *const Value, _: bool) Error!OwnedValue {
        if (pipe.cmds.len == 0) return error.InvalidExpression;

        var current: OwnedValue = .{ .value = .null };
        var have = false;

        for (pipe.cmds, 0..) |cmd, ci| {
            const next = try self.evalCommand(cmd, dot, if (have) current.value else null, ci > 0);
            if (have) current.deinit(self.allocator);
            current = next;
            have = true;
        }
        return current;
    }

    fn evalCommand(
        self: *Executor,
        cmd: parse.PipeCmd,
        dot: *const Value,
        pipe_in: ?Value,
        is_pipe_stage: bool,
    ) Error!OwnedValue {
        if (cmd.name.len == 0) {
            // Literal / field
            if (cmd.args.len != 1) return error.InvalidExpression;
            if (is_pipe_stage) return error.InvalidExpression;
            return .{ .value = try self.evalArg(cmd.args[0], dot) };
        }

        // Function call
        const func = self.lookupFunc(cmd.name) orelse return error.InvalidExpression;

        var args_buf: std.ArrayList(Value) = .empty;
        defer args_buf.deinit(self.allocator);

        if (is_pipe_stage) {
            if (pipe_in) |v| try args_buf.append(self.allocator, v);
        }
        for (cmd.args) |a| {
            try args_buf.append(self.allocator, try self.evalArg(a, dot));
        }

        return func(self.allocator, args_buf.items) catch |err| switch (err) {
            error.InvalidExpression => error.InvalidExpression,
            error.MissingField => error.MissingField,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn lookupFunc(self: *Executor, name: []const u8) ?funcs.Func {
        if (self.options.funcs) |m| {
            if (m.get(name)) |f| return f;
        }
        return self.builtins.get(name);
    }

    fn evalArg(self: *Executor, arg: parse.Arg, dot: *const Value) Error!Value {
        return switch (arg) {
            .string => |s| .{ .string = s },
            .int => |n| .{ .int = n },
            .bool => |b| .{ .bool = b },
            .variable => |name| blk: {
                if (name.len == 0) break :blk self.root.*; // `$`
                break :blk (self.lookupVar(name) orelse return error.MissingField).*;
            },
            .field => |path| (try self.resolve(path, dot)).*,
        };
    }

    fn resolve(self: *Executor, path: []const u8, current: *const Value) Error!*const Value {
        if (std.mem.eql(u8, path, ".")) return current;
        if (std.mem.eql(u8, path, "$")) return self.root;
        if (std.mem.startsWith(u8, path, "$.")) {
            return value_mod.lookupPath(self.root, path[2..]) orelse error.MissingField;
        }
        // `$var` as field path shouldn't happen — variables use Arg.variable
        if (path.len > 0 and path[0] == '$') {
            const name = path[1..];
            return self.lookupVar(name) orelse error.MissingField;
        }
        if (std.mem.startsWith(u8, path, ".")) {
            return value_mod.lookupPath(current, path[1..]) orelse error.MissingField;
        }
        if (value_mod.lookupPath(current, path)) |v| return v;
        return value_mod.lookupPath(self.root, path) orelse error.MissingField;
    }

    fn writeValue(self: *Executor, value: Value, raw: bool) Error!void {
        var rendered: std.ArrayList(u8) = .empty;
        defer rendered.deinit(self.allocator);
        value_mod.appendStringified(self.allocator, &rendered, value) catch |err| switch (err) {
            error.InvalidExpression => return error.InvalidExpression,
            error.OutOfMemory => return error.OutOfMemory,
        };

        if (raw or self.options.escape_mode == .none) {
            try self.out.appendSlice(self.allocator, rendered.items);
            return;
        }
        escape_mod.appendEscaped(self.allocator, self.out, self.options.escape_mode, rendered.items) catch return error.OutOfMemory;
    }
};

pub fn execute(
    allocator: std.mem.Allocator,
    tree: *const parse.Tree,
    root: *const Value,
    options: Options,
    builtins: *const funcs.FuncMap,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var ex = Executor{
        .allocator = allocator,
        .tree = tree,
        .root = root,
        .options = options,
        .out = &out,
        .builtins = builtins,
        .vars = .empty,
    };
    defer ex.vars.deinit(allocator);

    _ = try ex.execNodes(tree.root, root);
    return out.toOwnedSlice(allocator);
}
