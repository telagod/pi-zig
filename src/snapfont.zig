//! snapfont.zig — omp 同款密图字库。
//!
//! 主字 X.org misc-fixed 8x13(拉丁/盒线/半角假名);CJK/假名/韩文走 16x16
//! 点阵,占两格。塑形按家:Anthropic `11on16`,OpenAI 系 `8on22`(宽取 1024,
//! 贴 512px tile,不照搬 omp 的 1568 —— 那边按对话整段计费)。
const std = @import("std");
const cfgmod = @import("config.zig");
const imgx = @import("imgx.zig");

const font8 = @embedFile("font8x13.bin");
const fontcjk = @embedFile("snapcjk.bin");

pub const GLYPH_W: u32 = 8;
pub const GLYPH_H: u32 = 13;
pub const CJK_PX: u32 = 16;

const PAPER = [4]u8{ 0xF7, 0xF4, 0xEC, 0xFF };
const INK = [4]u8{ 0x1A, 0x18, 0x14, 0xFF };

pub const Shape = struct {
    name: []const u8,
    cell_w: u32,
    cell_h: u32,
    cols: u32,
    frame_w: u32,
    frame_h: u32,
};

pub const Frame = struct {
    rgba: []u8,
    w: u32,
    h: u32,
    rows: u32,
};

pub fn resolveShape(api: cfgmod.Api) Shape {
    return switch (api) {
        .anthropic_messages => .{
            .name = "11on16",
            .cell_w = 11,
            .cell_h = 16,
            .cols = 142,
            .frame_w = 142 * 11,
            .frame_h = 1568,
        },
        // 8x13 字画在 8x22 格(加行距)。宽 1024=两块 OpenAI tile,比 omp 1568
        // 少两块横 tile,大段 tool 输出才过得了 15% 省额。
        .openai_completions, .openai_responses => .{
            .name = "8on22",
            .cell_w = 8,
            .cell_h = 22,
            .cols = 128,
            .frame_w = 1024,
            .frame_h = 1540,
        },
    };
}

pub fn isWide(cp: u21) bool {
    return switch (cp) {
        0x1100...0x115F => true,
        0x2329...0x232A => true,
        0x2E80...0xA4CF => true,
        0xAC00...0xD7A3 => true,
        0xF900...0xFAFF => true,
        0xFE10...0xFE19 => true,
        0xFE30...0xFE6F => true,
        0xFF00...0xFF60 => true,
        0xFFE0...0xFFE6 => true,
        0x1F300...0x1FAFF => true,
        else => false,
    };
}

pub fn cellsOf(cp: u21) u32 {
    return if (isWide(cp)) 2 else 1;
}

pub fn maxRows(text_tok: usize, excerpt_tok: usize, shape: Shape, api: cfgmod.Api, window: usize) u32 {
    const keep = text_tok * 85 / 100;
    if (keep <= excerpt_tok) return 0;
    const budget = keep - excerpt_tok;
    const hard = shape.frame_h / shape.cell_h;
    if (hard == 0) return 0;
    const win: u32 = @intCast(@min(window, std.math.maxInt(u32)));
    var lo: u32 = 0;
    var hi: u32 = hard;
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2;
        const tok = imgx.estImageTokens(shape.frame_w, mid * shape.cell_h, api, win);
        if (tok <= budget) lo = mid else hi = mid - 1;
    }
    return lo;
}

pub fn wrap(alloc: std.mem.Allocator, text: []const u8, cols: u32) ![][]const u8 {
    var rows = std.array_list.Managed([]const u8).init(alloc);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            try rows.append(text[i..i]);
            i += 1;
            continue;
        }
        const start = i;
        var used: u32 = 0;
        while (i < text.len and text[i] != '\n') {
            const seq = utf8At(text, i);
            const w = cellsOf(seq.cp);
            if (used > 0 and used + w > cols) break;
            used += w;
            i += seq.len;
        }
        try rows.append(text[start..i]);
        if (i < text.len and text[i] == '\n') i += 1;
    }
    return try rows.toOwnedSlice();
}

pub fn raster(alloc: std.mem.Allocator, text: []const u8, shape: Shape, max_rows: u32) !?Frame {
    if (max_rows == 0) return null;
    const lines = try wrap(alloc, text, shape.cols);
    defer alloc.free(lines);
    if (lines.len == 0) return null;
    const rows: u32 = @intCast(@min(lines.len, max_rows));
    const w = shape.frame_w;
    const h = rows * shape.cell_h;
    const rgba = try alloc.alloc(u8, @as(usize, w) * h * 4);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) put(rgba, w, x, y, PAPER);
    }
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        blitLine(rgba, w, lines[r], r * shape.cell_h, shape);
    }
    return .{ .rgba = rgba, .w = w, .h = h, .rows = rows };
}

const Seq = struct { cp: u21, len: usize };

fn utf8At(text: []const u8, i: usize) Seq {
    const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return .{ .cp = text[i], .len = 1 };
    if (i + n > text.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(text[i..][0..n]) catch return .{ .cp = 0xFFFD, .len = n };
    return .{ .cp = cp, .len = n };
}

fn blitLine(rgba: []u8, stride: u32, line: []const u8, y: u32, shape: Shape) void {
    var col: u32 = 0;
    var i: usize = 0;
    while (i < line.len) {
        const seq = utf8At(line, i);
        const wcells = cellsOf(seq.cp);
        if (col + wcells > shape.cols) break;
        const x = col * shape.cell_w;
        if (wcells == 2) {
            if (lookupCjk(seq.cp)) |bits| {
                blitCjk(rgba, stride, x, y, bits, shape);
            } else {
                blitBox(rgba, stride, x, y, shape.cell_w * 2, shape.cell_h);
            }
        } else if (lookup8(seq.cp)) |rows| {
            blit8(rgba, stride, x, y, rows, shape);
        } else {
            blitBox(rgba, stride, x, y, shape.cell_w, shape.cell_h);
        }
        col += wcells;
        i += seq.len;
    }
}

fn blit8(rgba: []u8, stride: u32, x: u32, y: u32, rows: [13]u8, shape: Shape) void {
    const ox: u32 = 0;
    const oy: u32 = if (shape.cell_h > GLYPH_H) (shape.cell_h - GLYPH_H) / 2 else 0;
    var r: u32 = 0;
    while (r < GLYPH_H) : (r += 1) {
        const bits = rows[r];
        var c: u32 = 0;
        while (c < GLYPH_W) : (c += 1) {
            if ((bits >> @intCast(7 - c)) & 1 == 0) continue;
            put(rgba, stride, x + ox + c, y + oy + r, INK);
        }
    }
}

fn blitCjk(rgba: []u8, stride: u32, x: u32, y: u32, bits: []const u8, shape: Shape) void {
    const box_w = shape.cell_w * 2;
    const ox: u32 = if (box_w > CJK_PX) (box_w - CJK_PX) / 2 else 0;
    const oy: u32 = if (shape.cell_h > CJK_PX) (shape.cell_h - CJK_PX) / 2 else 0;
    var r: u32 = 0;
    while (r < CJK_PX) : (r += 1) {
        const hi = bits[r * 2];
        const lo = bits[r * 2 + 1];
        const row: u16 = (@as(u16, hi) << 8) | lo;
        var c: u32 = 0;
        while (c < CJK_PX) : (c += 1) {
            if ((row >> @intCast(15 - c)) & 1 == 0) continue;
            put(rgba, stride, x + ox + c, y + oy + r, INK);
        }
    }
}

fn blitBox(rgba: []u8, stride: u32, x: u32, y: u32, bw: u32, bh: u32) void {
    if (bw < 3 or bh < 3) return;
    var c: u32 = 1;
    while (c + 1 < bw) : (c += 1) {
        put(rgba, stride, x + c, y + 1, INK);
        put(rgba, stride, x + c, y + bh - 2, INK);
    }
    var r: u32 = 1;
    while (r + 1 < bh) : (r += 1) {
        put(rgba, stride, x + 1, y + r, INK);
        put(rgba, stride, x + bw - 2, y + r, INK);
    }
}

fn put(rgba: []u8, stride: u32, x: u32, y: u32, px: [4]u8) void {
    if (x >= stride) return;
    const i = (@as(usize, y) * stride + x) * 4;
    if (i + 4 > rgba.len) return;
    rgba[i..][0..4].* = px;
}

fn u32le(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}

fn findCp(blob: []const u8, cps_off: usize, count: u32, cp: u32) ?u32 {
    var lo: u32 = 0;
    var hi: u32 = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const got = u32le(blob, cps_off + @as(usize, mid) * 4);
        if (got == cp) return mid;
        if (got < cp) lo = mid + 1 else hi = mid;
    }
    return null;
}

pub fn lookup8(cp: u21) ?[13]u8 {
    if (font8.len < 12 or !std.mem.eql(u8, font8[0..5], "F8X13")) return null;
    const count = u32le(font8, 8);
    const cps_off: usize = 12;
    const bits_off = cps_off + @as(usize, count) * 4;
    const idx = findCp(font8, cps_off, count, cp) orelse return null;
    const src = font8[bits_off + @as(usize, idx) * 13 ..][0..13];
    var out: [13]u8 = undefined;
    @memcpy(&out, src);
    return out;
}

pub fn lookupCjk(cp: u21) ?[]const u8 {
    if (fontcjk.len < 16 or !std.mem.eql(u8, fontcjk[0..8], "SNAPCJK1")) return null;
    const count = u32le(fontcjk, 12);
    const cps_off: usize = 16;
    const bits_off = cps_off + @as(usize, count) * 4;
    const idx = findCp(fontcjk, cps_off, count, cp) orelse return null;
    const start = bits_off + @as(usize, idx) * 32;
    if (start + 32 > fontcjk.len) return null;
    return fontcjk[start .. start + 32];
}

test "8x13 contains ASCII and box drawing" {
    const t = std.testing;
    try t.expect(lookup8('A') != null);
    try t.expect(lookup8('g') != null);
    try t.expect(lookup8(0x2502) != null);
    try t.expect(lookup8(0x2588) != null);
    const a = lookup8('A').?;
    var ink: u32 = 0;
    for (a) |row| ink += @popCount(row);
    try t.expect(ink > 8);
}

test "cjk bitmap has 中" {
    const t = std.testing;
    const bits = lookupCjk(0x4E2D) orelse return error.MissingZhong;
    var ink: u32 = 0;
    for (bits) |b| ink += @popCount(b);
    try t.expect(ink > 20);
}

test "shapes follow provider pitch" {
    const t = std.testing;
    const cl = resolveShape(.anthropic_messages);
    try t.expectEqualStrings("11on16", cl.name);
    try t.expectEqual(@as(u32, 11), cl.cell_w);
    try t.expectEqual(@as(u32, 16), cl.cell_h);
    const oa = resolveShape(.openai_completions);
    try t.expectEqualStrings("8on22", oa.name);
    try t.expectEqual(@as(u32, 8), oa.cell_w);
    try t.expectEqual(@as(u32, 22), oa.cell_h);
    try t.expectEqual(oa.frame_w, oa.cols * oa.cell_w);
}

test "wrap counts CJK as two cells" {
    const t = std.testing;
    const rows = try wrap(t.allocator, "中A文", 3);
    defer t.allocator.free(rows);
    try t.expectEqual(@as(usize, 2), rows.len);
    try t.expectEqualStrings("中A", rows[0]);
    try t.expectEqualStrings("文", rows[1]);
}

test "raster hugs height and uses shape width" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const shape = resolveShape(.openai_completions);
    const frame = (try raster(arena.allocator(), "fn main() void {}\n中文\n", shape, 8)) orelse return error.Empty;
    try t.expectEqual(shape.frame_w, frame.w);
    try t.expectEqual(frame.rows * shape.cell_h, frame.h);
    try t.expect(frame.rows >= 2);
    try t.expect(frame.rgba.len == @as(usize, frame.w) * frame.h * 4);
}
