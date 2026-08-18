// tui_keys.zig — CSI 分类、滚轮连发、UTF-8 删字。从 tui.zig 拆出,
// 输入循环只问「这是什么键」,不在此画屏。
const std = @import("std");

pub const CsiKey = enum {
    up,
    down,
    left,
    right,
    home,
    end,
    delete,
    page_up,
    page_down,
    shift_up,
    shift_down,
    ctrl_up,
    ctrl_down,
    other,
};

pub const WheelDir = enum { up, down };

pub fn csiMod(params: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, params, ';')) |i| return params[i + 1 ..];
    return params;
}

pub fn csiShift(params: []const u8) bool {
    return std.mem.eql(u8, csiMod(params), "2");
}

pub fn csiCtrl(params: []const u8) bool {
    return std.mem.eql(u8, csiMod(params), "5");
}

/// 同一 CSI 连发次数(滚轮突发)。推进 i。
pub fn consumeSameCsi(bytes: []const u8, i: *usize, params: []const u8, final: u8) usize {
    var n: usize = 0;
    while (i.* + 2 <= bytes.len and bytes[i.*] == 0x1b and bytes[i.* + 1] == '[') {
        var k = i.* + 2;
        while (k < bytes.len and (bytes[k] < '@' or bytes[k] > '~')) k += 1;
        if (k >= bytes.len) break;
        if (bytes[k] != final or !std.mem.eql(u8, bytes[i.* + 2 .. k], params)) break;
        i.* = k + 1;
        n += 1;
    }
    return n;
}

pub fn sgrWheel(params: []const u8) ?WheelDir {
    if (params.len < 2 or params[0] != '<') return null;
    const rest = params[1..];
    const semi = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
    const btn = std.fmt.parseInt(u16, rest[0..semi], 10) catch return null;
    return switch (btn & ~@as(u16, 0x1C)) {
        64 => .up,
        65 => .down,
        else => null,
    };
}

pub fn classifyCsi(params: []const u8, final: u8) CsiKey {
    const shift = csiShift(params);
    const ctrl = csiCtrl(params);
    return switch (final) {
        'A' => if (shift) .shift_up else if (ctrl) .ctrl_up else .up,
        'B' => if (shift) .shift_down else if (ctrl) .ctrl_down else .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        '~' => blk: {
            if (std.mem.eql(u8, params, "3") or std.mem.startsWith(u8, params, "3;")) break :blk .delete;
            if (std.mem.eql(u8, params, "5") or std.mem.startsWith(u8, params, "5;")) break :blk .page_up;
            if (std.mem.eql(u8, params, "6") or std.mem.startsWith(u8, params, "6;")) break :blk .page_down;
            break :blk .other;
        },
        else => .other,
    };
}

pub fn utf8PrevLen(s: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0) {
        i -= 1;
        if (s[i] & 0xC0 != 0x80) {
            return pos - i;
        }
    }
    return 1;
}

pub fn utf8LenAt(s: []const u8, pos: usize) usize {
    if (pos >= s.len) return 1;
    return std.unicode.utf8ByteSequenceLength(s[pos]) catch 1;
}

pub fn deleteUtf8Before(buf: *std.array_list.Managed(u8), cursor: *usize) void {
    if (cursor.* == 0 or cursor.* > buf.items.len) return;
    const w = utf8PrevLen(buf.items, cursor.*);
    const start = cursor.* - w;
    var k: usize = 0;
    while (k < w) : (k += 1) {
        _ = buf.orderedRemove(start);
    }
    cursor.* = start;
}

pub fn deleteUtf8At(buf: *std.array_list.Managed(u8), cursor: usize) void {
    if (cursor >= buf.items.len) return;
    const w = utf8LenAt(buf.items, cursor);
    var k: usize = 0;
    while (k < w) : (k += 1) {
        _ = buf.orderedRemove(cursor);
    }
}

test "classifyCsi arrows and delete" {
    const t = std.testing;
    try t.expectEqual(CsiKey.up, classifyCsi("", 'A'));
    try t.expectEqual(CsiKey.shift_up, classifyCsi("1;2", 'A'));
    try t.expectEqual(CsiKey.ctrl_down, classifyCsi("1;5", 'B'));
    try t.expectEqual(CsiKey.delete, classifyCsi("3", '~'));
    try t.expectEqual(CsiKey.page_up, classifyCsi("5", '~'));
}

test "utf8PrevLen walks back a CJK scalar" {
    const t = std.testing;
    const s = "中";
    try t.expectEqual(s.len, utf8PrevLen(s, s.len));
    try t.expectEqual(@as(usize, 1), utf8LenAt("a", 0));
}
