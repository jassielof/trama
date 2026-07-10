const std = @import("std");
const trama = @import("trama");

comptime {
    std.testing.refAllDecls(@This());
}

const Case = struct {
    name: []const u8,
    template: []const u8,
    // Context encoded as simple structs via inline tests below
};

test "pipelines and whitespace trim" {
    const ctx = .{ .name = "Ada", .empty = "" };
    const rendered = try trama.renderAlloc(
        std.testing.allocator,
        "Hello, {{- .name -}}!\n{{ .empty | default \"(none)\" }}",
        ctx,
        .{},
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("Hello,Ada!\n(none)", rendered);
}

test "comments are omitted" {
    const rendered = try trama.renderAlloc(
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
    const rendered = try trama.renderAlloc(
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
    const rendered = try trama.renderAlloc(
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
    const rendered = try trama.renderAlloc(
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
    const rendered = try trama.renderAlloc(
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
    const rendered = try trama.renderAlloc(
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
    const rendered = try trama.renderAlloc(
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
    const html = try trama.renderAlloc(std.testing.allocator, "{{ .s }}", ctx, .{ .escape_mode = .html });
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("a&amp;b&lt;c&gt;", html);

    const url = try trama.renderAlloc(std.testing.allocator, "{{ .s }}", ctx, .{ .escape_mode = .url });
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("a%26b%3Cc%3E", url);
}

test "unclosed action errors" {
    const result = trama.renderAlloc(std.testing.allocator, "hi {{ name", .{ .name = "x" }, .{});
    try std.testing.expectError(error.UnclosedTemplateBlock, result);
}

test "missing end errors" {
    const result = trama.renderAlloc(std.testing.allocator, "{{ if true }}hi", .{}, .{});
    try std.testing.expectError(error.MissingEndBlock, result);
}

test "root dollar path" {
    const Item = struct { name: []const u8 };
    const ctx = .{ .title = "Root", .items = &[_]Item{.{ .name = "a" }} };
    const rendered = try trama.renderAlloc(
        std.testing.allocator,
        "{{ range .items }}{{ $.title }}-{{ .name }}{{ end }}",
        ctx,
        .{},
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("Root-a", rendered);
}
