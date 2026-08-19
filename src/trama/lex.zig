//! Outer template lexer: text spans, comments, and action bodies with trim flags.

const std = @import("std");

pub const Error = error{
    UnclosedTemplateBlock,
    UnclosedComment,
    OutOfMemory,
};

/// A top-level template piece before AST parsing of action bodies.
pub const Chunk = union(enum) {
    text: []const u8,
    /// Action body without surrounding `{{`/`}}`; trim flags apply to adjacent text.
    action: ActionChunk,
    comment: void,
};

pub const ActionChunk = struct {
    body: []const u8,
    trim_left: bool,
    trim_right: bool,
    /// Byte offset of `{{` in the source (for errors).
    start: usize,
};

pub fn scan(allocator: std.mem.Allocator, source: []const u8) Error![]Chunk {
    var chunks: std.ArrayList(Chunk) = .empty;
    errdefer chunks.deinit(allocator);

    var i: usize = 0;
    while (i < source.len) {
        const open = std.mem.indexOfPos(u8, source, i, "{{") orelse {
            try chunks.append(allocator, .{ .text = source[i..] });
            break;
        };
        if (open > i) {
            try chunks.append(allocator, .{ .text = source[i..open] });
        }

        // Comment: {{/* ... */}}
        if (open + 4 <= source.len and std.mem.eql(u8, source[open .. open + 4], "{{/*")) {
            const close = std.mem.indexOfPos(u8, source, open + 4, "*/}}") orelse return error.UnclosedComment;
            try chunks.append(allocator, .comment);
            i = close + 4;
            continue;
        }

        var trim_left = false;
        var body_start = open + 2;
        if (body_start < source.len and source[body_start] == '-') {
            trim_left = true;
            body_start += 1;
        }

        const close = std.mem.indexOfPos(u8, source, body_start, "}}") orelse return error.UnclosedTemplateBlock;
        var body_end = close;
        var trim_right = false;
        if (body_end > body_start and source[body_end - 1] == '-') {
            trim_right = true;
            body_end -= 1;
        }

        const body = std.mem.trim(u8, source[body_start..body_end], " \t\r\n");
        try chunks.append(allocator, .{ .action = .{
            .body = body,
            .trim_left = trim_left,
            .trim_right = trim_right,
            .start = open,
        } });
        i = close + 2;
    }

    applyTrim(chunks.items);
    return chunks.toOwnedSlice(allocator);
}

fn applyTrim(chunks: []Chunk) void {
    var i: usize = 0;
    while (i < chunks.len) : (i += 1) {
        switch (chunks[i]) {
            .action => |a| {
                if (a.trim_left and i > 0) {
                    if (chunks[i - 1] == .text) {
                        chunks[i - 1].text = trimRightSpace(chunks[i - 1].text);
                    }
                }
                if (a.trim_right and i + 1 < chunks.len) {
                    if (chunks[i + 1] == .text) {
                        chunks[i + 1].text = trimLeftSpace(chunks[i + 1].text);
                    }
                }
            },
            .comment => {
                // Comments also trim adjacent whitespace when using {{- /* */ -}} via action path;
                // bare {{/* */}} does not trim (Go behavior).
            },
            .text => {},
        }
    }
}

fn trimLeftSpace(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and std.ascii.isWhitespace(s[i])) : (i += 1) {}
    return s[i..];
}

fn trimRightSpace(s: []const u8) []const u8 {
    var i: usize = s.len;
    while (i > 0 and std.ascii.isWhitespace(s[i - 1])) : (i -= 1) {}
    return s[0..i];
}
