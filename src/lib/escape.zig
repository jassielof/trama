//! Content escaping for interpolated values (not delimiter syntax).
//!
//! `EscapeMode` selects how `{{ pipeline }}` output is escaped. Delimiters
//! themselves always follow Go-style `{{ }}` syntax.

const std = @import("std");

/// How interpolated (non-`@raw`) values are escaped when written.
pub const EscapeMode = enum {
    none,
    /// Escape `{`, `}`, `<`, `>` for AsciiDoc attribute safety.
    asciidoc,
    html,
    url,
};

pub fn escapeAsciiDoc(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
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

pub fn escapeHtml(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
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

pub fn escapeUrl(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
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

pub fn appendEscaped(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    mode: EscapeMode,
    text: []const u8,
) !void {
    switch (mode) {
        .none => try out.appendSlice(allocator, text),
        .asciidoc => try escapeAsciiDoc(allocator, out, text),
        .html => try escapeHtml(allocator, out, text),
        .url => try escapeUrl(allocator, out, text),
    }
}
