//! Trama — Go `text/template`–compatible text renderer for Zig.
//!
//! Delimiters and control syntax follow Go templates. Trama extensions
//! (documented as such, not claimed as Go): `@raw`, AsciiDoc helpers
//! (`anchor`, `adoc_escape`, `join`), and `Options.escape_mode`.

const std = @import("std");

pub const value = @import("value.zig");
pub const escape = @import("escape.zig");
pub const funcs = @import("funcs.zig");
pub const lex = @import("lex.zig");
pub const parse_mod = @import("parse.zig");
pub const exec_mod = @import("exec.zig");

pub const EscapeMode = escape.EscapeMode;
pub const Field = value.Field;
pub const Value = value.Value;
pub const FuncMap = funcs.FuncMap;
pub const Func = funcs.Func;

pub const Options = struct {
    escape_mode: EscapeMode = .none,
    /// Optional extra / overriding functions (looked up before builtins).
    funcs: ?*const FuncMap = null,
};

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

/// Parsed template: parse once, execute many times.
pub const Template = struct {
    tree: parse_mod.Tree,
    builtins: FuncMap,
    allocator: std.mem.Allocator,

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) Error!Template {
        var builtins: FuncMap = .{};
        errdefer builtins.deinit(allocator);
        try funcs.installBuiltins(&builtins, allocator);

        const tree = parse_mod.parse(allocator, source) catch |err| return mapParseErr(err);
        return .{
            .tree = tree,
            .builtins = builtins,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Template) void {
        self.tree.deinit();
        self.builtins.deinit(self.allocator);
    }

    pub fn execute(self: *Template, allocator: std.mem.Allocator, root: *const Value, options: Options) Error![]u8 {
        return exec_mod.execute(
            allocator,
            &self.tree,
            root,
            .{ .escape_mode = options.escape_mode, .funcs = options.funcs },
            &self.builtins,
        ) catch |err| mapExecErr(err);
    }

    pub fn executeStruct(self: *Template, allocator: std.mem.Allocator, context: anytype, options: Options) Error![]u8 {
        var root = try Value.from(allocator, context);
        defer root.deinit(allocator);
        return self.execute(allocator, &root, options);
    }
};

pub fn renderAlloc(
    allocator: std.mem.Allocator,
    template: []const u8,
    context: anytype,
    options: Options,
) Error![]u8 {
    var root = try Value.from(allocator, context);
    defer root.deinit(allocator);
    return renderValueAlloc(allocator, template, &root, options);
}

pub fn renderValueAlloc(
    allocator: std.mem.Allocator,
    template: []const u8,
    root: *const Value,
    options: Options,
) Error![]u8 {
    var tmpl = try Template.parse(allocator, template);
    defer tmpl.deinit();
    return tmpl.execute(allocator, root, options);
}

fn mapParseErr(err: parse_mod.Error) Error {
    return switch (err) {
        error.UnclosedTemplateBlock => error.UnclosedTemplateBlock,
        error.UnclosedComment => error.UnclosedComment,
        error.UnexpectedEnd => error.UnexpectedEnd,
        error.UnexpectedElse => error.UnexpectedElse,
        error.UnexpectedEndBlock => error.UnexpectedEndBlock,
        error.MissingEndBlock => error.MissingEndBlock,
        error.InvalidExpression => error.InvalidExpression,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn mapExecErr(err: exec_mod.Error) Error {
    return switch (err) {
        error.UnclosedTemplateBlock => error.UnclosedTemplateBlock,
        error.UnclosedComment => error.UnclosedComment,
        error.UnexpectedEnd => error.UnexpectedEnd,
        error.UnexpectedElse => error.UnexpectedElse,
        error.UnexpectedEndBlock => error.UnexpectedEndBlock,
        error.MissingEndBlock => error.MissingEndBlock,
        error.MissingField => error.MissingField,
        error.InvalidExpression => error.InvalidExpression,
        error.InvalidRange => error.InvalidRange,
        error.UndefinedTemplate => error.UndefinedTemplate,
        error.BreakOutsideRange => error.BreakOutsideRange,
        error.ContinueOutsideRange => error.ContinueOutsideRange,
        error.OutOfMemory => error.OutOfMemory,
    };
}

comptime {
    std.testing.refAllDecls(@This());
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
