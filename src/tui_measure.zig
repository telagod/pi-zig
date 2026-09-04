// tui_measure.zig — 可视列宽、ANSI 跳过、截断。从 tui.zig 拆出,
// 底栏与细胞绘制共用,避免再把测宽逻辑复制一份。
const std = @import("std");

pub fn skipAnsi(s: []const u8, i: usize) usize {
    if (i >= s.len or s[i] != 0x1b) return i;
    if (i + 1 < s.len and s[i + 1] == '[') {
        var k = i + 2;
        while (k < s.len and !(s[k] >= '@' and s[k] <= '~')) k += 1;
        return if (k < s.len) k + 1 else s.len;
    }
    return i + 1;
}

/// East Asian Wide / Fullwidth + common emoji. Box drawing, `▎`, `▸`, `›`
/// stay 1 column so gutters and the composer frame do not steal wrap width.
pub fn isWideCp(cp: u21) bool {
    return switch (cp) {
        0x1100...0x115F => true,
        0x2329...0x232A => true,
        0x2E80...0x303E => true,
        0x3040...0xA4CF => true,
        0xAC00...0xD7A3 => true,
        0xF900...0xFAFF => true,
        0xFE10...0xFE19 => true,
        0xFE30...0xFE6F => true,
        0xFF00...0xFF60 => true,
        0xFFE0...0xFFE6 => true,
        0x1F1E6...0x1F1FF => true,
        0x1F300...0x1F6FF => true,
        0x1F900...0x1FAFF => true,
        0x20000...0x3FFFD => true,
        else => false,
    };
}

pub fn charCols(s: []const u8, i: usize) struct { n: usize, cols: usize } {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    const take = @min(n, s.len - i);
    if (take < n) return .{ .n = take, .cols = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + take]) catch return .{ .n = take, .cols = 1 };
    return .{ .n = take, .cols = if (isWideCp(cp)) 2 else 1 };
}

pub fn visibleCols(s: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const next = skipAnsi(s, i);
        if (next != i) {
            i = next;
            continue;
        }
        const ch = charCols(s, i);
        cols += ch.cols;
        i += ch.n;
    }
    return cols;
}

pub fn truncateToVisible(s: []const u8, max_cols: usize) []const u8 {
    var cols: usize = 0;
    var i: usize = 0;
    var last: usize = 0;
    while (i < s.len) {
        const next = skipAnsi(s, i);
        if (next != i) {
            i = next;
            last = i;
            continue;
        }
        const ch = charCols(s, i);
        if (cols + ch.cols > max_cols) return s[0..last];
        cols += ch.cols;
        i += ch.n;
        last = i;
    }
    return s;
}

pub fn ellipsizeAlloc(alloc: std.mem.Allocator, s: []const u8, max_cols: usize) ![]u8 {
    if (max_cols == 0) return alloc.dupe(u8, "");
    if (visibleCols(s) <= max_cols) return alloc.dupe(u8, s);
    if (max_cols == 1) return alloc.dupe(u8, "…");
    const cut = truncateToVisible(s, max_cols - 1);
    return std.fmt.allocPrint(alloc, "{s}…", .{cut});
}

/// 从右往左丢掉段,直到拼起来不超过 width。只剩一段仍超宽就截断。
pub fn joinFit(alloc: std.mem.Allocator, parts: []const []const u8, sep: []const u8, width: usize) ![]u8 {
    var n = parts.len;
    while (n > 0) {
        const joined = try joinN(alloc, parts[0..n], sep);
        const cols = visibleCols(joined);
        if (cols <= width or n == 1) {
            if (cols > width) {
                const cut = truncateToVisible(joined, width);
                const out = try alloc.dupe(u8, cut);
                alloc.free(joined);
                return out;
            }
            return joined;
        }
        alloc.free(joined);
        n -= 1;
    }
    return try alloc.dupe(u8, "");
}

pub fn joinN(alloc: std.mem.Allocator, parts: []const []const u8, sep: []const u8) ![]u8 {
    var w = std.Io.Writer.Allocating.init(alloc);
    errdefer w.deinit();
    for (parts, 0..) |p, i| {
        if (i > 0) try w.writer.writeAll(sep);
        try w.writer.writeAll(p);
    }
    return w.toOwnedSlice();
}

test "visibleCols counts CJK as two and skips ANSI" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 2), visibleCols("中"));
    try t.expectEqual(@as(usize, 1), visibleCols("a"));
    try t.expectEqual(@as(usize, 1), visibleCols("\x1b[31ma\x1b[0m"));
    try t.expectEqualStrings("中", truncateToVisible("中文", 2));
}
