// tui_slash.zig — slash 目录排序与查询。从 tui.zig 拆出,避免把键盘选择器
// 和底栏画法搅在同一个 5k 行文件里。
const std = @import("std");

pub const PickerItem = struct {
    label: []const u8,
    hint: []const u8 = "",
    value: []const u8,
};

/// Slash catalog row. `cmd` is `/name` or `/name [args]`; ranking uses the name.
pub const SlashItem = struct {
    cmd: []const u8,
    desc: []const u8,
};

pub const SlashRank = struct {
    item: usize,
    score: u32,
    kind: u8, // 0 prefix, 1 fuzzy subsequence, 2 description keyword
    hl_from: usize,
    hl_len: usize,
};

/// Name token of a slash catalog row (`/model [m]` → `model`).
pub fn slashName(cmd: []const u8) []const u8 {
    var s = cmd;
    if (s.len > 0 and s[0] == '/') s = s[1..];
    if (std.mem.indexOfScalar(u8, s, ' ')) |i| return s[0..i];
    return s;
}

/// Query for the composer slash picker. `null` = not in slash mode (no `/`,
/// or already has arguments after a space).
pub fn slashQuery(input: []const u8) ?[]const u8 {
    if (input.len == 0 or input[0] != '/') return null;
    const rest = input[1..];
    if (std.mem.indexOfScalar(u8, rest, ' ') != null) return null;
    if (std.mem.indexOfScalar(u8, rest, '\n') != null) return null; // 多行草稿不补全
    return rest;
}

fn asciiLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn startsWithInsensitive(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    for (needle, 0..) |c, i| {
        if (asciiLower(hay[i]) != asciiLower(c)) return false;
    }
    return true;
}

pub fn indexOfInsensitive(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > hay.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (startsWithInsensitive(hay[i..], needle)) return i;
    }
    return null;
}

fn fuzzySubseq(hay: []const u8, needle: []const u8) ?struct { from: usize, to: usize } {
    if (needle.len == 0) return .{ .from = 0, .to = 0 };
    var i: usize = 0;
    var first: ?usize = null;
    var last: usize = 0;
    for (hay, 0..) |c, hi| {
        if (i < needle.len and asciiLower(c) == asciiLower(needle[i])) {
            if (first == null) first = hi;
            last = hi + 1;
            i += 1;
        }
    }
    if (i != needle.len) return null;
    return .{ .from = first.?, .to = last };
}

/// Rank slash commands: prefix match > fuzzy subsequence > description keyword.
/// Empty query lists the catalog in table order. Writes into `out`, returns count.
pub fn rankSlash(items: []const SlashItem, query: []const u8, out: []SlashRank) usize {
    var n: usize = 0;
    if (query.len == 0) {
        for (items, 0..) |_, i| {
            if (n >= out.len) break;
            out[n] = .{ .item = i, .score = 0, .kind = 0, .hl_from = 0, .hl_len = 0 };
            n += 1;
        }
        return n;
    }
    for (items, 0..) |it, i| {
        if (n >= out.len) break;
        const name = slashName(it.cmd);
        if (startsWithInsensitive(name, query)) {
            const exact: u32 = if (name.len == query.len) 1000 else 0;
            out[n] = .{
                .item = i,
                .score = 2000 + exact - @as(u32, @intCast(@min(name.len, 500))),
                .kind = 0,
                .hl_from = 0,
                .hl_len = query.len,
            };
            n += 1;
            continue;
        }
        if (fuzzySubseq(name, query)) |span| {
            out[n] = .{
                .item = i,
                .score = 1000 - @as(u32, @intCast(@min(span.to - span.from, 500))),
                .kind = 1,
                .hl_from = span.from,
                .hl_len = span.to - span.from,
            };
            n += 1;
            continue;
        }
        if (indexOfInsensitive(it.desc, query)) |at| {
            out[n] = .{
                .item = i,
                .score = 100,
                .kind = 2,
                .hl_from = at,
                .hl_len = query.len,
            };
            n += 1;
        }
    }
    var a: usize = 0;
    while (a + 1 < n) : (a += 1) {
        var b = a + 1;
        while (b < n) : (b += 1) {
            const less = out[b].kind < out[a].kind or
                (out[b].kind == out[a].kind and out[b].score > out[a].score);
            if (less) {
                const tmp = out[a];
                out[a] = out[b];
                out[b] = tmp;
            }
        }
    }
    return n;
}

/// `/permissions` `/model` `/think` 的键盘选择器。独占输入,不进 composer。
pub const Picker = struct {
    cmd: []u8,
    title: []u8,
    items: []Item,
    sel: usize = 0,
    scroll: usize = 0,

    pub const Item = struct {
        label: []u8,
        hint: []u8,
        value: []u8,
    };

    pub fn init(alloc: std.mem.Allocator, cmd: []const u8, title: []const u8, items: []const PickerItem, selected: usize) !Picker {
        const owned = try alloc.alloc(Item, items.len);
        errdefer alloc.free(owned);
        var n: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < n) : (j += 1) {
                alloc.free(owned[j].label);
                alloc.free(owned[j].hint);
                alloc.free(owned[j].value);
            }
        }
        for (items, 0..) |it, i| {
            const label = try alloc.dupe(u8, it.label);
            errdefer alloc.free(label);
            const hint = try alloc.dupe(u8, it.hint);
            errdefer alloc.free(hint);
            const value = try alloc.dupe(u8, it.value);
            errdefer alloc.free(value);
            owned[i] = .{ .label = label, .hint = hint, .value = value };
            n += 1;
        }
        const cmd_owned = try alloc.dupe(u8, cmd);
        errdefer alloc.free(cmd_owned);
        const title_owned = try alloc.dupe(u8, title);
        errdefer alloc.free(title_owned);
        return .{
            .cmd = cmd_owned,
            .title = title_owned,
            .items = owned,
            .sel = if (items.len == 0) 0 else @min(selected, items.len - 1),
        };
    }

    pub fn deinit(self: *Picker, alloc: std.mem.Allocator) void {
        for (self.items) |it| {
            alloc.free(it.label);
            alloc.free(it.hint);
            alloc.free(it.value);
        }
        alloc.free(self.items);
        alloc.free(self.cmd);
        alloc.free(self.title);
        self.* = undefined;
    }

    pub fn move(self: *Picker, delta: isize) void {
        if (self.items.len == 0) return;
        if (delta < 0) {
            const d: usize = @intCast(-delta);
            self.sel = if (self.sel >= d) self.sel - d else 0;
        } else {
            const d: usize = @intCast(delta);
            self.sel = @min(self.items.len - 1, self.sel + d);
        }
    }

    pub fn confirmLine(self: *const Picker, alloc: std.mem.Allocator) ![]u8 {
        const value = if (self.items.len == 0) "" else self.items[self.sel].value;
        return std.fmt.allocPrint(alloc, "/{s} {s}", .{ self.cmd, value });
    }

    pub fn displayRows(self: *const Picker, height: usize) usize {
        if (self.items.len == 0) return 0;
        return 1 + @min(self.items.len, itemCap(height));
    }

    pub fn window(self: *Picker, height: usize) struct { start: usize, count: usize } {
        const n = self.items.len;
        const cap = itemCap(height);
        if (n <= cap) {
            self.scroll = 0;
            return .{ .start = 0, .count = n };
        }
        var start = self.scroll;
        if (self.sel < start) start = self.sel;
        if (self.sel >= start + cap) start = self.sel + 1 - cap;
        self.scroll = start;
        return .{ .start = start, .count = cap };
    }

    fn itemCap(height: usize) usize {
        return @max(1, height / 3);
    }
};

test "slashName and slashQuery" {
    const t = std.testing;
    try t.expectEqualStrings("model", slashName("/model [m]"));
    try t.expectEqualStrings("help", slashName("/help"));
    try t.expectEqualStrings("st", slashQuery("/st").?);
    try t.expect(slashQuery("/status extra") == null);
    try t.expect(slashQuery("hello") == null);
}
