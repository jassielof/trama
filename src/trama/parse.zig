//! Parse lexed chunks into a Go-compatible template AST.

const std = @import("std");
const lex = @import("lex.zig");

pub const Error = error{
    UnclosedTemplateBlock,
    UnclosedComment,
    UnexpectedEnd,
    UnexpectedElse,
    UnexpectedEndBlock,
    MissingEndBlock,
    InvalidExpression,
    OutOfMemory,
};

pub const PipeCmd = struct {
    /// Function name, or empty when this is a field/literal/variable arg-only command.
    name: []const u8 = "",
    /// Arguments (field paths, literals, variables). For field access the first arg holds the path.
    args: []Arg,
};

pub const Arg = union(enum) {
    field: []const u8, // path like "name", ".name", "$.x", "$var", "."
    string: []const u8,
    int: i64,
    bool: bool,
    variable: []const u8, // "$x" without evaluating path — name without '$' for user vars; "" means root `$`
};

pub const Pipeline = struct {
    cmds: []PipeCmd,
    /// Optional declaration: `$x :=` or `$i, $v :=` before the pipeline.
    decl: ?Decl = null,
};

pub const Decl = struct {
    names: [][]const u8, // without '$'
    assign: bool, // true for `=`, false for `:=`
};

pub const Node = union(enum) {
    text: []const u8,
    action: ActionNode,
    if_node: IfNode,
    range: RangeNode,
    with: WithNode,
    template_call: TemplateCall,
    break_cmd,
    continue_cmd,
};

pub const ActionNode = struct {
    pipe: Pipeline,
    raw: bool = false,
};

pub const IfArm = struct {
    pipe: Pipeline,
    body: []Node,
};

pub const IfNode = struct {
    arms: []IfArm,
    else_body: []Node,
};

pub const RangeNode = struct {
    pipe: Pipeline,
    body: []Node,
    else_body: []Node,
};

pub const WithNode = struct {
    pipe: Pipeline,
    body: []Node,
    else_body: []Node,
};

pub const TemplateCall = struct {
    name: []const u8,
    pipe: ?Pipeline = null,
};

pub const Define = struct {
    name: []const u8,
    body: []Node,
};

pub const Tree = struct {
    allocator: std.mem.Allocator,
    root: []Node,
    defines: std.StringHashMapUnmanaged([]Node) = .empty,
    /// Owned chunk list from lexer.
    chunks: []lex.Chunk,
    /// Arena-like lists of owned node slices for deinit.
    owned_nodes: std.ArrayList([]Node) = .empty,
    owned_args: std.ArrayList([]Arg) = .empty,
    owned_cmds: std.ArrayList([]PipeCmd) = .empty,
    owned_arms: std.ArrayList([]IfArm) = .empty,
    owned_decl_names: std.ArrayList([][]const u8) = .empty,

    pub fn deinit(self: *Tree) void {
        var it = self.defines.iterator();
        while (it.next()) |e| {
            // bodies freed via owned_nodes
            _ = e;
        }
        self.defines.deinit(self.allocator);
        for (self.owned_nodes.items) |slice| self.allocator.free(slice);
        self.owned_nodes.deinit(self.allocator);
        for (self.owned_args.items) |slice| self.allocator.free(slice);
        self.owned_args.deinit(self.allocator);
        for (self.owned_cmds.items) |slice| self.allocator.free(slice);
        self.owned_cmds.deinit(self.allocator);
        for (self.owned_arms.items) |slice| self.allocator.free(slice);
        self.owned_arms.deinit(self.allocator);
        for (self.owned_decl_names.items) |slice| self.allocator.free(slice);
        self.owned_decl_names.deinit(self.allocator);
        self.allocator.free(self.chunks);
        self.* = undefined;
    }
};

const Parser = struct {
    tree: *Tree,
    chunks: []lex.Chunk,
    index: usize = 0,

    fn parse(self: *Parser) Error![]Node {
        return self.parseList(null);
    }

    /// Parse until `end` or EOF. `until` is "end" for nested blocks.
    fn parseList(self: *Parser, until: ?[]const u8) Error![]Node {
        var nodes: std.ArrayList(Node) = .empty;
        errdefer nodes.deinit(self.tree.allocator);

        while (self.index < self.chunks.len) {
            const chunk = self.chunks[self.index];
            switch (chunk) {
                .text => |t| {
                    self.index += 1;
                    if (t.len > 0) try nodes.append(self.tree.allocator, .{ .text = t });
                },
                .comment => {
                    self.index += 1;
                },
                .action => |a| {
                    const kind = classifyAction(a.body);
                    if (until != null and (std.mem.eql(u8, kind.keyword, "end") or
                        std.mem.eql(u8, kind.keyword, "else") or
                        std.mem.startsWith(u8, kind.keyword, "else if")))
                    {
                        break;
                    }
                    if (std.mem.eql(u8, kind.keyword, "end")) {
                        return error.UnexpectedEndBlock;
                    }
                    if (std.mem.eql(u8, kind.keyword, "else") or std.mem.startsWith(u8, kind.keyword, "else if")) {
                        return error.UnexpectedElse;
                    }

                    self.index += 1;

                    if (std.mem.eql(u8, kind.keyword, "if")) {
                        try nodes.append(self.tree.allocator, .{ .if_node = try self.parseIf(kind.rest) });
                    } else if (std.mem.eql(u8, kind.keyword, "range")) {
                        try nodes.append(self.tree.allocator, .{ .range = try self.parseRange(kind.rest) });
                    } else if (std.mem.eql(u8, kind.keyword, "with")) {
                        try nodes.append(self.tree.allocator, .{ .with = try self.parseWith(kind.rest) });
                    } else if (std.mem.eql(u8, kind.keyword, "define")) {
                        const def = try self.parseDefine(kind.rest);
                        try self.tree.defines.put(self.tree.allocator, def.name, def.body);
                    } else if (std.mem.eql(u8, kind.keyword, "template")) {
                        try nodes.append(self.tree.allocator, .{ .template_call = try self.parseTemplateCall(kind.rest) });
                    } else if (std.mem.eql(u8, kind.keyword, "block")) {
                        // {{block "name" pipeline}} ... {{end}} — define + execute
                        const call = try self.parseBlock(kind.rest);
                        try nodes.append(self.tree.allocator, .{ .template_call = call });
                    } else if (std.mem.eql(u8, kind.keyword, "break")) {
                        try nodes.append(self.tree.allocator, .break_cmd);
                    } else if (std.mem.eql(u8, kind.keyword, "continue")) {
                        try nodes.append(self.tree.allocator, .continue_cmd);
                    } else {
                        var raw = false;
                        var body = a.body;
                        if (std.mem.startsWith(u8, body, "@raw ")) {
                            raw = true;
                            body = std.mem.trim(u8, body[5..], " \t");
                        }
                        const pipe = try self.parsePipeline(body);
                        try nodes.append(self.tree.allocator, .{ .action = .{ .pipe = pipe, .raw = raw } });
                    }
                },
            }
        }

        if (until != null and self.index >= self.chunks.len) {
            return error.MissingEndBlock;
        }

        const slice = try nodes.toOwnedSlice(self.tree.allocator);
        try self.tree.owned_nodes.append(self.tree.allocator, slice);
        return slice;
    }

    fn expectEnd(self: *Parser) Error!void {
        if (self.index >= self.chunks.len) return error.MissingEndBlock;
        const chunk = self.chunks[self.index];
        if (chunk != .action) return error.MissingEndBlock;
        const kind = classifyAction(chunk.action.body);
        if (!std.mem.eql(u8, kind.keyword, "end")) return error.MissingEndBlock;
        self.index += 1;
    }

    fn peekActionKeyword(self: *Parser) ?[]const u8 {
        if (self.index >= self.chunks.len) return null;
        return switch (self.chunks[self.index]) {
            .action => |a| classifyAction(a.body).keyword,
            else => null,
        };
    }

    fn parseIf(self: *Parser, first_rest: []const u8) Error!IfNode {
        var arms: std.ArrayList(IfArm) = .empty;
        errdefer arms.deinit(self.tree.allocator);

        var rest = first_rest;
        while (true) {
            const pipe = try self.parsePipeline(rest);
            const body = try self.parseList("end");
            try arms.append(self.tree.allocator, .{ .pipe = pipe, .body = body });

            const kw = self.peekActionKeyword() orelse return error.MissingEndBlock;
            if (std.mem.eql(u8, kw, "end")) {
                try self.expectEnd();
                const arms_slice = try arms.toOwnedSlice(self.tree.allocator);
                try self.tree.owned_arms.append(self.tree.allocator, arms_slice);
                return .{ .arms = arms_slice, .else_body = &.{} };
            }
            if (std.mem.eql(u8, kw, "else if")) {
                const else_chunk = self.chunks[self.index];
                self.index += 1;
                rest = classifyAction(else_chunk.action.body).rest;
                continue;
            }
            if (std.mem.eql(u8, kw, "else")) {
                self.index += 1;
                const else_body = try self.parseList("end");
                try self.expectEnd();
                const arms_slice = try arms.toOwnedSlice(self.tree.allocator);
                try self.tree.owned_arms.append(self.tree.allocator, arms_slice);
                return .{ .arms = arms_slice, .else_body = else_body };
            }
            return error.MissingEndBlock;
        }
    }

    fn parseRange(self: *Parser, rest: []const u8) Error!RangeNode {
        const pipe = try self.parsePipeline(rest);
        const body = try self.parseList("end");
        var else_body: []Node = &.{};
        const kw = self.peekActionKeyword() orelse return error.MissingEndBlock;
        if (std.mem.eql(u8, kw, "else")) {
            self.index += 1;
            else_body = try self.parseList("end");
        }
        try self.expectEnd();
        return .{ .pipe = pipe, .body = body, .else_body = else_body };
    }

    fn parseWith(self: *Parser, rest: []const u8) Error!WithNode {
        const pipe = try self.parsePipeline(rest);
        const body = try self.parseList("end");
        var else_body: []Node = &.{};
        const kw = self.peekActionKeyword() orelse return error.MissingEndBlock;
        if (std.mem.eql(u8, kw, "else")) {
            self.index += 1;
            else_body = try self.parseList("end");
        }
        try self.expectEnd();
        return .{ .pipe = pipe, .body = body, .else_body = else_body };
    }

    fn parseDefine(self: *Parser, rest: []const u8) Error!Define {
        const name = try parseQuotedName(rest);
        const body = try self.parseList("end");
        try self.expectEnd();
        return .{ .name = name, .body = body };
    }

    fn parseTemplateCall(self: *Parser, rest: []const u8) Error!TemplateCall {
        var iter = ActionTokenizer.init(rest);
        const name_tok = iter.next() orelse return error.InvalidExpression;
        if (!name_tok.quoted) return error.InvalidExpression;
        const rem = std.mem.trim(u8, rest[name_tok.end..], " \t");
        if (rem.len == 0) return .{ .name = name_tok.value, .pipe = null };
        return .{ .name = name_tok.value, .pipe = try parsePipelineStatic(self.tree, rem) };
    }

    fn parseBlock(self: *Parser, rest: []const u8) Error!TemplateCall {
        var iter = ActionTokenizer.init(rest);
        const name_tok = iter.next() orelse return error.InvalidExpression;
        if (!name_tok.quoted) return error.InvalidExpression;
        const rem = std.mem.trim(u8, rest[name_tok.end..], " \t");
        const pipe = if (rem.len == 0) null else try parsePipelineStatic(self.tree, rem);
        const body = try self.parseList("end");
        try self.expectEnd();
        try self.tree.defines.put(self.tree.allocator, name_tok.value, body);
        return .{ .name = name_tok.value, .pipe = pipe };
    }

    fn parsePipeline(self: *Parser, src: []const u8) Error!Pipeline {
        return parsePipelineStatic(self.tree, src);
    }
};

const ActionKind = struct {
    keyword: []const u8,
    rest: []const u8,
};

fn classifyAction(body: []const u8) ActionKind {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "end")) return .{ .keyword = "end", .rest = "" };
    if (std.mem.eql(u8, trimmed, "else")) return .{ .keyword = "else", .rest = "" };
    if (std.mem.eql(u8, trimmed, "break")) return .{ .keyword = "break", .rest = "" };
    if (std.mem.eql(u8, trimmed, "continue")) return .{ .keyword = "continue", .rest = "" };
    if (std.mem.startsWith(u8, trimmed, "else if")) {
        return .{ .keyword = "else if", .rest = std.mem.trim(u8, trimmed["else if".len..], " \t") };
    }

    const keywords = [_][]const u8{ "if", "range", "with", "define", "template", "block" };
    for (keywords) |kw| {
        if (std.mem.eql(u8, trimmed, kw)) return .{ .keyword = kw, .rest = "" };
        if (trimmed.len > kw.len and std.mem.startsWith(u8, trimmed, kw) and trimmed[kw.len] == ' ') {
            return .{ .keyword = kw, .rest = std.mem.trim(u8, trimmed[kw.len + 1 ..], " \t") };
        }
    }
    return .{ .keyword = "", .rest = trimmed };
}

fn parseQuotedName(rest: []const u8) Error![]const u8 {
    var iter = ActionTokenizer.init(rest);
    const tok = iter.next() orelse return error.InvalidExpression;
    if (!tok.quoted) return error.InvalidExpression;
    if (iter.next() != null) return error.InvalidExpression;
    return tok.value;
}

fn parsePipelineStatic(tree: *Tree, src: []const u8) Error!Pipeline {
    var s = std.mem.trim(u8, src, " \t\r\n");
    if (s.len == 0) return error.InvalidExpression;

    var decl: ?Decl = null;

    // Detect `$x :=` / `$x =` / `$i, $v :=`
    if (s[0] == '$') {
        if (try tryParseDecl(tree, s)) |parsed| {
            decl = parsed.decl;
            s = parsed.rest;
        }
    }

    var cmds: std.ArrayList(PipeCmd) = .empty;
    errdefer cmds.deinit(tree.allocator);

    var pipe_parts = std.mem.splitScalar(u8, s, '|');
    while (pipe_parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) return error.InvalidExpression;
        try cmds.append(tree.allocator, try parseCommand(tree, part));
    }

    const cmds_slice = try cmds.toOwnedSlice(tree.allocator);
    try tree.owned_cmds.append(tree.allocator, cmds_slice);
    return .{ .cmds = cmds_slice, .decl = decl };
}

const DeclParse = struct {
    decl: Decl,
    rest: []const u8,
};

fn tryParseDecl(tree: *Tree, s: []const u8) Error!?DeclParse {
    const AssignOp = struct { idx: usize, len: usize, assign: bool };
    var assign_op: ?AssignOp = null;
    if (std.mem.indexOf(u8, s, ":=")) |i| {
        assign_op = .{ .idx = i, .len = 2, .assign = false };
    } else {
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] == '=' and (i + 1 >= s.len or s[i + 1] != '=')) {
                assign_op = .{ .idx = i, .len = 1, .assign = true };
                break;
            }
        }
    }
    const op = assign_op orelse return null;

    const left = std.mem.trim(u8, s[0..op.idx], " \t");
    const right = std.mem.trim(u8, s[op.idx + op.len ..], " \t");
    if (right.len == 0) return null;

    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(tree.allocator);
    var parts = std.mem.splitScalar(u8, left, ',');
    while (parts.next()) |p| {
        const t = std.mem.trim(u8, p, " \t");
        if (t.len < 1 or t[0] != '$') return null;
        try names.append(tree.allocator, t[1..]);
    }
    if (names.items.len == 0 or names.items.len > 2) return null;

    const names_slice = try names.toOwnedSlice(tree.allocator);
    try tree.owned_decl_names.append(tree.allocator, names_slice);
    return .{
        .decl = .{ .names = names_slice, .assign = op.assign },
        .rest = right,
    };
}

fn parseCommand(tree: *Tree, part: []const u8) Error!PipeCmd {
    var iter = ActionTokenizer.init(part);
    var args: std.ArrayList(Arg) = .empty;
    errdefer args.deinit(tree.allocator);

    const first = iter.next() orelse return error.InvalidExpression;

    // Function call: ident followed by more tokens, and first is not a path/literal-only
    // Go: `.Field` is field; `func arg` is function; `field` alone may be field lookup.
    // Heuristic matching old trama + Go:
    // - If first is quoted/number/bool/path starting with . or $ → field/literal command (name="")
    // - If first is bare ident and there are more args → function
    // - If first is bare ident alone → field path (legacy trama: `name`)

    if (first.quoted) {
        try args.append(tree.allocator, .{ .string = first.value });
        while (iter.next()) |tok| {
            try args.append(tree.allocator, try tokenToArg(tok));
        }
        // string alone is literal; with more args treat first as... invalid in Go unless function
        // In Go `"x"` alone is a string constant command.
        const args_slice = try args.toOwnedSlice(tree.allocator);
        try tree.owned_args.append(tree.allocator, args_slice);
        if (args_slice.len == 1) {
            return .{ .name = "", .args = args_slice };
        }
        // `"fmt" arg` isn't valid Go — treat as invalid
        return error.InvalidExpression;
    }

    if (first.kind == .number) {
        try args.append(tree.allocator, .{ .int = first.int_value });
        if (iter.next() != null) return error.InvalidExpression;
        const args_slice = try args.toOwnedSlice(tree.allocator);
        try tree.owned_args.append(tree.allocator, args_slice);
        return .{ .name = "", .args = args_slice };
    }

    if (first.kind == .bool_lit) {
        try args.append(tree.allocator, .{ .bool = first.bool_value });
        if (iter.next() != null) return error.InvalidExpression;
        const args_slice = try args.toOwnedSlice(tree.allocator);
        try tree.owned_args.append(tree.allocator, args_slice);
        return .{ .name = "", .args = args_slice };
    }

    // Path or function name
    const is_path = first.value[0] == '.' or first.value[0] == '$' or std.mem.eql(u8, first.value, ".");
    const second = iter.peek();

    if (is_path or second == null) {
        // Field / variable reference
        try args.append(tree.allocator, try tokenToArg(first));
        if (iter.next() != null) {
            // `.Foo bar` — in Go this is method call; we don't support methods — error
            // Actually `.Foo` with args would be method. Skip: error.
            return error.InvalidExpression;
        }
        const args_slice = try args.toOwnedSlice(tree.allocator);
        try tree.owned_args.append(tree.allocator, args_slice);
        return .{ .name = "", .args = args_slice };
    }

    // Function: name + args
    const fname = first.value;
    while (iter.next()) |tok| {
        try args.append(tree.allocator, try tokenToArg(tok));
    }
    const args_slice = try args.toOwnedSlice(tree.allocator);
    try tree.owned_args.append(tree.allocator, args_slice);
    return .{ .name = fname, .args = args_slice };
}

fn tokenToArg(tok: ActionToken) Error!Arg {
    return switch (tok.kind) {
        .string => .{ .string = tok.value },
        .number => .{ .int = tok.int_value },
        .bool_lit => .{ .bool = tok.bool_value },
        .ident => blk: {
            if (tok.value[0] == '$') {
                if (tok.value.len == 1) break :blk Arg{ .variable = "" }; // root `$`
                if (tok.value.len > 1 and tok.value[1] == '.') {
                    break :blk Arg{ .field = tok.value }; // `$.path`
                }
                break :blk Arg{ .variable = tok.value[1..] };
            }
            break :blk Arg{ .field = tok.value };
        },
    };
}

const TokenKind = enum { ident, string, number, bool_lit };

const ActionToken = struct {
    value: []const u8,
    end: usize,
    quoted: bool = false,
    kind: TokenKind = .ident,
    int_value: i64 = 0,
    bool_value: bool = false,
};

const ActionTokenizer = struct {
    input: []const u8,
    index: usize = 0,

    fn init(input: []const u8) ActionTokenizer {
        return .{ .input = std.mem.trim(u8, input, " \t\r\n") };
    }

    fn peek(self: *ActionTokenizer) ?ActionToken {
        const saved = self.index;
        const tok = self.next();
        self.index = saved;
        return tok;
    }

    fn next(self: *ActionTokenizer) ?ActionToken {
        while (self.index < self.input.len and std.ascii.isWhitespace(self.input[self.index])) {
            self.index += 1;
        }
        if (self.index >= self.input.len) return null;

        const start = self.index;
        if (self.input[start] == '"') {
            self.index += 1;
            const value_start = self.index;
            while (self.index < self.input.len and self.input[self.index] != '"') {
                if (self.input[self.index] == '\\' and self.index + 1 < self.input.len) {
                    self.index += 2;
                    continue;
                }
                self.index += 1;
            }
            if (self.index >= self.input.len) return null;
            const value = self.input[value_start..self.index];
            self.index += 1;
            return .{ .value = value, .end = self.index, .quoted = true, .kind = .string };
        }

        // number
        if (self.input[start] == '-' or std.ascii.isDigit(self.input[start])) {
            if (self.input[start] == '-' and (start + 1 >= self.input.len or !std.ascii.isDigit(self.input[start + 1]))) {
                // not a number
            } else {
                self.index += 1;
                while (self.index < self.input.len and std.ascii.isDigit(self.input[self.index])) {
                    self.index += 1;
                }
                const num_str = self.input[start..self.index];
                const n = std.fmt.parseInt(i64, num_str, 10) catch {
                    self.index = start;
                    // fall through to ident
                    return self.nextIdent(start);
                };
                return .{ .value = num_str, .end = self.index, .kind = .number, .int_value = n };
            }
        }

        return self.nextIdent(start);
    }

    fn nextIdent(self: *ActionTokenizer, start: usize) ?ActionToken {
        self.index = start;
        while (self.index < self.input.len and !std.ascii.isWhitespace(self.input[self.index]) and self.input[self.index] != '|') {
            self.index += 1;
        }
        const value = self.input[start..self.index];
        if (value.len == 0) return null;
        if (std.mem.eql(u8, value, "true")) {
            return .{ .value = value, .end = self.index, .kind = .bool_lit, .bool_value = true };
        }
        if (std.mem.eql(u8, value, "false")) {
            return .{ .value = value, .end = self.index, .kind = .bool_lit, .bool_value = false };
        }
        return .{ .value = value, .end = self.index, .kind = .ident };
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) Error!Tree {
    const chunks = lex.scan(allocator, source) catch |err| switch (err) {
        error.UnclosedTemplateBlock => return error.UnclosedTemplateBlock,
        error.UnclosedComment => return error.UnclosedComment,
        error.OutOfMemory => return error.OutOfMemory,
    };

    var tree = Tree{
        .allocator = allocator,
        .root = &.{},
        .chunks = chunks,
    };
    errdefer tree.deinit();

    var parser = Parser{ .tree = &tree, .chunks = chunks };
    tree.root = try parser.parse();
    if (parser.index != chunks.len) {
        // leftover end/else
        return error.UnexpectedEnd;
    }
    return tree;
}
