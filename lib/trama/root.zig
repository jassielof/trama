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

test "pipelines and whitespace trim" {
    const ctx = .{ .name = "Ada", .empty = "" };
    const rendered = try renderAlloc(
        std.testing.allocator,
        "Hello, {{- .name -}}!\n{{ .empty | default \"(none)\" }}",
        ctx,
        .{},
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("Hello,Ada!\n(none)", rendered);
}

test "comments are omitted" {
    const rendered = try renderAlloc(
        std.testing.allocator,
        "a{{/* secret */}}b",
        .{},
        .{},
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("ab", rendered);
}

test "else if chain" {
    const ctx = .{ .n = @as(i64, 2) };
    const rendered = try renderAlloc(
        std.testing.allocator,
        "{{ if eq n 1 }}one{{ else if eq n 2 }}two{{ else }}other{{ end }}",
        ctx,
        .{},
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("two", rendered);
}

test "with and variables" {
    const Item = struct { title: []const u8 };
    const ctx = .{ .item = Item{ .title = "Docs" } };
    const rendered = try renderAlloc(
        std.testing.allocator,
        "{{ with .item }}{{ .title }}{{ else }}missing{{ end }}",
        ctx,
        .{},
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("Docs", rendered);
}

test "range with index variables break continue" {
    const ctx = .{ .nums = &[_]i64{ 1, 2, 3, 4 } };
    const rendered = try renderAlloc(
        std.testing.allocator,
        "{{ range $i, $v := .nums }}{{ if eq $i 2 }}{{ break }}{{ end }}{{ if eq $v 2 }}{{ continue }}{{ end }}{{ $v }}{{ end }}",
        ctx,
        .{},
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("1", rendered);
}

test "define and template" {
    const ctx = .{ .name = "Zig" };
    const rendered = try renderAlloc(
        std.testing.allocator,
        "{{ define \"greet\" }}Hi {{ . }}{{ end }}{{ template \"greet\" .name }}",
        ctx,
        .{},
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("Hi Zig", rendered);
}

test "len index not and or" {
    const ctx = .{ .vals = &[_][]const u8{ "a", "b", "c" }, .flag = false };
    const rendered = try renderAlloc(
        std.testing.allocator,
        "{{ len .vals }} {{ index .vals 1 }} {{ if not .flag }}ok{{ end }} {{ if and true true }}y{{ end }}",
        ctx,
        .{},
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("3 b ok y", rendered);
}

test "printf print" {
    const ctx = .{ .n = @as(i64, 7), .s = "x" };
    const rendered = try renderAlloc(
        std.testing.allocator,
        "{{ printf \"%s=%d\" .s .n }}",
        ctx,
        .{},
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("x=7", rendered);
}

test "html and url escape modes" {
    const ctx = .{ .s = "a&b<c>" };
    const html = try renderAlloc(std.testing.allocator, "{{ .s }}", ctx, .{ .escape_mode = .html });
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("a&amp;b&lt;c&gt;", html);

    const url = try renderAlloc(std.testing.allocator, "{{ .s }}", ctx, .{ .escape_mode = .url });
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("a%26b%3Cc%3E", url);
}

test "unclosed action errors" {
    const result = renderAlloc(std.testing.allocator, "hi {{ name", .{ .name = "x" }, .{});
    try std.testing.expectError(error.UnclosedTemplateBlock, result);
}

test "missing end errors" {
    const result = renderAlloc(std.testing.allocator, "{{ if true }}hi", .{}, .{});
    try std.testing.expectError(error.MissingEndBlock, result);
}

test "root dollar path" {
    const Item = struct { name: []const u8 };
    const ctx = .{ .title = "Root", .items = &[_]Item{.{ .name = "a" }} };
    const rendered = try renderAlloc(
        std.testing.allocator,
        "{{ range .items }}{{ $.title }}-{{ .name }}{{ end }}",
        ctx,
        .{},
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("Root-a", rendered);
}
