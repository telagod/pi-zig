//! 轻量 Markdown → ANSI,对齐 pi Markdown 组件的常用块:
//! 标题 / 围栏代码 / 缩进代码 / 引用 / 列表 / 横线 /
//! 行内 `code` **bold** __bold__ *italic* _italic_ ~~strike~~ [link](url) 与 \ 转义。
//! 围栏内浅着色:注释 / 字符串。剥标记;换行数与源大致相同。

const std = @import("std");
const Theme = @import("theme.zig").Theme;

const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const ITALIC = "\x1b[3m";
const STRIKE = "\x1b[9m";

pub fn render(alloc: std.mem.Allocator, t: *const Theme, src: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    var in_fence = false;
    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append('\n');
        first = false;
        if (isFence(line)) {
            in_fence = !in_fence;
            try writeStyled(&out, t.fg_md_code_border, std.mem.trim(u8, line, " \t"));
            continue;
        }
        if (in_fence) {
            try writeCodeLine(&out, t, line);
            continue;
        }
        if (indentCodeOf(line)) |code| {
            try writeStyled(&out, t.fg_md_code_block, code);
            continue;
        }
        if (isHr(line)) {
            try writeStyled(&out, t.fg_md_hr, "───");
            continue;
        }
        if (headingOf(line)) |h| {
            try out.appendSlice(BOLD);
            if (t.fg_md_heading.len > 0) try out.appendSlice(t.fg_md_heading);
            try writeInline(&out, t, h);
            try out.appendSlice(RESET);
            continue;
        }
        if (quoteOf(line)) |q| {
            try out.appendSlice(t.fg_md_quote_border);
            try out.appendSlice("│ ");
            try out.appendSlice(RESET ++ ITALIC);
            if (t.fg_md_quote.len > 0) try out.appendSlice(t.fg_md_quote);
            try writeInline(&out, t, q);
            try out.appendSlice(RESET);
            continue;
        }
        if (listOf(line)) |l| {
            try out.appendSlice(l.indent);
            try writeStyled(&out, t.fg_md_list, l.bullet);
            try out.append(' ');
            try writeInline(&out, t, l.text);
            continue;
        }
        try writeInline(&out, t, line);
    }
    return out.toOwnedSlice();
}

fn writeStyled(out: *std.array_list.Managed(u8), ink: []const u8, s: []const u8) !void {
    if (ink.len > 0) try out.appendSlice(ink);
    try out.appendSlice(s);
    if (ink.len > 0) try out.appendSlice(RESET);
}

fn isFence(line: []const u8) bool {
    const s = std.mem.trimStart(u8, line, " \t");
    return std.mem.startsWith(u8, s, "```") or std.mem.startsWith(u8, s, "~~~");
}

fn isHr(line: []const u8) bool {
    const s = std.mem.trim(u8, line, " \t");
    if (s.len < 3) return false;
    const c = s[0];
    if (c != '-' and c != '*' and c != '_') return false;
    for (s) |ch| {
        if (ch != c and ch != ' ' and ch != '\t') return false;
    }
    var n: usize = 0;
    for (s) |ch| {
        if (ch == c) n += 1;
    }
    return n >= 3;
}

fn headingOf(line: []const u8) ?[]const u8 {
    const s = std.mem.trimStart(u8, line, " \t");
    var i: usize = 0;
    while (i < s.len and s[i] == '#' and i < 6) i += 1;
    if (i == 0 or i >= s.len or s[i] != ' ') return null;
    return std.mem.trim(u8, s[i + 1 ..], " \t");
}

fn quoteOf(line: []const u8) ?[]const u8 {
    const s = std.mem.trimStart(u8, line, " \t");
    if (s.len == 0 or s[0] != '>') return null;
    var rest = s[1..];
    if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    return rest;
}

const ListBits = struct { indent: []const u8, bullet: []const u8, text: []const u8 };

fn listOf(line: []const u8) ?ListBits {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len) return null;
    const indent = line[0..i];
    if (line[i] == '-' or line[i] == '*' or line[i] == '+') {
        if (i + 1 >= line.len or line[i + 1] != ' ') return null;
        return .{ .indent = indent, .bullet = "•", .text = line[i + 2 ..] };
    }
    var j = i;
    while (j < line.len and line[j] >= '0' and line[j] <= '9') j += 1;
    if (j == i or j >= line.len or line[j] != '.') return null;
    if (j + 1 >= line.len or line[j + 1] != ' ') return null;
    return .{ .indent = indent, .bullet = line[i .. j + 1], .text = line[j + 2 ..] };
}

fn indentCodeOf(line: []const u8) ?[]const u8 {
    if (line.len >= 1 and line[0] == '\t') return line[1..];
    if (line.len >= 4 and std.mem.eql(u8, line[0..4], "    ")) return line[4..];
    return null;
}

fn writeCodeLine(out: *std.array_list.Managed(u8), t: *const Theme, line: []const u8) !void {
    const trim = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, trim, "//") or std.mem.startsWith(u8, trim, "#") or
        std.mem.startsWith(u8, trim, "--") or std.mem.startsWith(u8, trim, ";"))
    {
        try writeStyled(out, t.fg_md_code_border, line);
        return;
    }
    if (t.fg_md_code_block.len > 0) try out.appendSlice(t.fg_md_code_block);
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '"' or c == '\'') {
            const end = std.mem.indexOfScalarPos(u8, line, i + 1, c) orelse line.len - 1;
            if (t.fg_md_code.len > 0) {
                try out.appendSlice(RESET);
                try writeStyled(out, t.fg_md_code, line[i .. end + 1]);
                if (t.fg_md_code_block.len > 0) try out.appendSlice(t.fg_md_code_block);
            } else {
                try out.appendSlice(line[i .. end + 1]);
            }
            i = end + 1;
            continue;
        }
        try out.append(c);
        i += 1;
    }
    if (t.fg_md_code_block.len > 0) try out.appendSlice(RESET);
}

fn wordish(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn writeInline(out: *std.array_list.Managed(u8), t: *const Theme, line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '\\' and i + 1 < line.len) {
            try out.append(line[i + 1]);
            i += 2;
            continue;
        }
        if (line[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '`')) |end| {
                try writeStyled(out, t.fg_md_code, line[i + 1 .. end]);
                i = end + 1;
                continue;
            }
        }
        if (i + 1 < line.len and line[i] == '~' and line[i + 1] == '~') {
            if (findClose(line, i + 2, "~~")) |end| {
                try out.appendSlice(STRIKE);
                try writeInline(out, t, line[i + 2 .. end]);
                try out.appendSlice(RESET);
                i = end + 2;
                continue;
            }
        }
        if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '*') {
            if (findClose(line, i + 2, "**")) |end| {
                try out.appendSlice(BOLD);
                try writeInline(out, t, line[i + 2 .. end]);
                try out.appendSlice(RESET);
                i = end + 2;
                continue;
            }
        }
        if (i + 1 < line.len and line[i] == '_' and line[i + 1] == '_') {
            if (findClose(line, i + 2, "__")) |end| {
                try out.appendSlice(BOLD);
                try writeInline(out, t, line[i + 2 .. end]);
                try out.appendSlice(RESET);
                i = end + 2;
                continue;
            }
        }
        if (line[i] == '*') {
            if (findClose(line, i + 1, "*")) |end| {
                try out.appendSlice(ITALIC);
                try writeInline(out, t, line[i + 1 .. end]);
                try out.appendSlice(RESET);
                i = end + 1;
                continue;
            }
        }
        if (line[i] == '_' and (i == 0 or !wordish(line[i - 1]))) {
            if (findClose(line, i + 1, "_")) |end| {
                if (end + 1 >= line.len or !wordish(line[end + 1])) {
                    try out.appendSlice(ITALIC);
                    try writeInline(out, t, line[i + 1 .. end]);
                    try out.appendSlice(RESET);
                    i = end + 1;
                    continue;
                }
            }
        }
        if (line[i] == '[') {
            if (parseLink(line, i)) |lk| {
                try writeStyled(out, t.fg_md_link, lk.text);
                if (lk.url.len > 0) {
                    try out.append(' ');
                    try writeStyled(out, t.fg_md_link_url, lk.url);
                }
                i = lk.next;
                continue;
            }
        }
        try out.append(line[i]);
        i += 1;
    }
}

fn findClose(s: []const u8, from: usize, delim: []const u8) ?usize {
    var i = from;
    while (i + delim.len <= s.len) : (i += 1) {
        if (std.mem.eql(u8, s[i .. i + delim.len], delim)) return i;
    }
    return null;
}

const Link = struct { text: []const u8, url: []const u8, next: usize };

fn parseLink(s: []const u8, at: usize) ?Link {
    const close = std.mem.indexOfScalarPos(u8, s, at + 1, ']') orelse return null;
    if (close + 1 >= s.len or s[close + 1] != '(') return null;
    const end = std.mem.indexOfScalarPos(u8, s, close + 2, ')') orelse return null;
    return .{ .text = s[at + 1 .. close], .url = s[close + 2 .. end], .next = end + 1 };
}

fn stripAnsi(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and (s[i] < 0x40 or s[i] > 0x7e)) i += 1;
            if (i < s.len) i += 1;
            continue;
        }
        try out.append(s[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

test "markdown heading list code link" {
    const t = std.testing;
    const th = Theme{};
    const src =
        \\# Title
        \\- item `code`
        \\**bold** and *em*
        \\[pi](https://x)
        \\```
        \\fn x() {}
        \\```
        \\---
        \\> quote
    ;
    const painted = try render(t.allocator, &th, src);
    defer t.allocator.free(painted);
    const plain = try stripAnsi(t.allocator, painted);
    defer t.allocator.free(plain);
    try t.expect(std.mem.indexOf(u8, plain, "Title") != null);
    try t.expect(std.mem.indexOf(u8, plain, "# Title") == null);
    try t.expect(std.mem.indexOf(u8, plain, "• item code") != null);
    try t.expect(std.mem.indexOf(u8, plain, "bold and em") != null);
    try t.expect(std.mem.indexOf(u8, plain, "pi https://x") != null);
    try t.expect(std.mem.indexOf(u8, plain, "fn x() {}") != null);
    try t.expect(std.mem.indexOf(u8, plain, "───") != null);
    try t.expect(std.mem.indexOf(u8, plain, "│ quote") != null);
    try t.expect(std.mem.indexOf(u8, painted, th.fg_md_heading) != null);
    try t.expect(std.mem.indexOf(u8, painted, th.fg_md_code) != null);
}

test "markdown strike underscore escape indent fence comment" {
    const t = std.testing;
    const th = Theme{};
    const src =
        \\~~gone~~ __heavy__ _soft_ foo_bar
        \\\*star\`tick
        \\    indented
        \\```
        \\// comment
        \\x = "hi"
        \\```
    ;
    const painted = try render(t.allocator, &th, src);
    defer t.allocator.free(painted);
    const plain = try stripAnsi(t.allocator, painted);
    defer t.allocator.free(plain);
    try t.expect(std.mem.indexOf(u8, plain, "gone") != null);
    try t.expect(std.mem.indexOf(u8, plain, "~~") == null);
    try t.expect(std.mem.indexOf(u8, plain, "heavy") != null);
    try t.expect(std.mem.indexOf(u8, plain, "soft") != null);
    try t.expect(std.mem.indexOf(u8, plain, "foo_bar") != null); // 标识符下划线不拆
    try t.expect(std.mem.indexOf(u8, plain, "*star`tick") != null);
    try t.expect(std.mem.indexOf(u8, plain, "indented") != null);
    try t.expect(std.mem.indexOf(u8, painted, STRIKE) != null);
    try t.expect(std.mem.indexOf(u8, painted, th.fg_md_code_border) != null); // 注释
    try t.expect(std.mem.indexOf(u8, painted, th.fg_md_code) != null); // 字符串
}

test "markdown heading with inline code" {
    const t = std.testing;
    const th = Theme{};
    const src = "## Header with `code_sym` and **bold**";
    const painted = try render(t.allocator, &th, src);
    defer t.allocator.free(painted);
    const plain = try stripAnsi(t.allocator, painted);
    defer t.allocator.free(plain);
    try t.expect(std.mem.indexOf(u8, plain, "Header with code_sym and bold") != null);
    try t.expect(std.mem.indexOf(u8, painted, th.fg_md_code) != null);
}
