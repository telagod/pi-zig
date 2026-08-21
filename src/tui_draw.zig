// tui_draw.zig — 截断写入、选择器、活动行。从 tui.zig 拆出绘制层。
const std = @import("std");
const activity = @import("core").activity;
const util = @import("core").util;
const slash = @import("tui_slash.zig");
const measure = @import("tui_measure.zig");

const ANSI_RESET = "\x1b[0m";
const ANSI_BOLD = "\x1b[1m";
const ANSI_DIM = "\x1b[2m";
const ANSI_REV = "\x1b[7m";

const visibleCols = measure.visibleCols;
const skipAnsi = measure.skipAnsi;
const charCols = measure.charCols;

const filesmod = @import("core").tools_files;
const SlashItem = slash.SlashItem;
const SlashRank = slash.SlashRank;
const Picker = slash.Picker;
const slashName = slash.slashName;
const rankSlash = slash.rankSlash;

pub fn writeHighlighted(wr: *std.Io.Writer, text: []const u8, hl_from: usize, hl_len: usize, width: usize) !void {
    if (hl_len == 0 or hl_from >= text.len) {
        try writeTrunc(wr, text, width);
        return;
    }
    const to = @min(text.len, hl_from + hl_len);
    if (hl_from > 0) try writeTrunc(wr, text[0..hl_from], width);
    const used = visibleCols(text[0..hl_from]);
    if (used >= width) return;
    try wr.writeAll("\x1b[4m");
    try writeTrunc(wr, text[hl_from..to], width - used);
    try wr.writeAll("\x1b[24m");
    const used2 = used + visibleCols(text[hl_from..to]);
    if (used2 < width and to < text.len) {
        try writeTrunc(wr, text[to..], width - used2);
    }
}

pub fn writeSlashPicker(wr: *std.Io.Writer, items: []const SlashItem, query: []const u8, sel: *usize, height: usize, width: usize) !void {
    var ranks: [64]SlashRank = undefined;
    const n = rankSlash(items, query, &ranks);
    if (n == 0) return;
    if (sel.* >= n) sel.* = n - 1;
    const cap = @min(n, @max(1, height / 3));
    const start: usize = if (sel.* < cap) 0 else sel.* + 1 - cap;
    var pi: usize = start;
    while (pi < start + cap) : (pi += 1) {
        const rank = ranks[pi];
        const it = items[rank.item];
        const name = slashName(it.cmd);
        const selected = pi == sel.*;
        if (selected) {
            try wr.writeAll(ANSI_DIM ++ "› " ++ ANSI_RESET ++ ANSI_REV ++ ANSI_BOLD);
        } else {
            try wr.writeAll("  " ++ ANSI_BOLD);
        }
        try wr.writeAll("/");
        var used: usize = 3;
        if (rank.kind != 2) {
            try writeHighlighted(wr, name, rank.hl_from, rank.hl_len, if (width > used) width - used else 0);
        } else {
            try writeTrunc(wr, name, if (width > used) width - used else 0);
        }
        used += 1 + visibleCols(name);
        try wr.writeAll(ANSI_RESET);
        if (it.desc.len > 0 and used + 2 < width) {
            try wr.writeAll(if (selected) ANSI_REV ++ ANSI_DIM ++ " " else ANSI_DIM ++ " ");
            used += 1;
            if (rank.kind == 2) {
                try writeHighlighted(wr, it.desc, rank.hl_from, rank.hl_len, width - used);
            } else {
                try writeTrunc(wr, it.desc, width - used);
            }
        }
        try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
    }
}

pub fn writeFilePicker(wr: *std.Io.Writer, items: []const filesmod.FileItem, sel: *usize, height: usize, width: usize) !void {
    if (items.len == 0) {
        try wr.writeAll(ANSI_DIM);
        try writeTrunc(wr, "no files — hidden or no match", width);
        try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
        return;
    }
    if (sel.* >= items.len) sel.* = items.len - 1;
    const cap = @min(items.len, @max(1, height / 3));
    const start: usize = if (sel.* < cap) 0 else sel.* + 1 - cap;
    var pi: usize = start;
    while (pi < start + cap) : (pi += 1) {
        const it = items[pi];
        const selected = pi == sel.*;
        if (selected) {
            try wr.writeAll(ANSI_DIM ++ "› " ++ ANSI_RESET ++ ANSI_REV ++ ANSI_BOLD);
        } else {
            try wr.writeAll("  " ++ ANSI_BOLD);
        }
        try wr.writeAll("@./");
        var used: usize = 5;
        try writeTrunc(wr, it.path, if (width > used) width - used else 0);
        used += visibleCols(it.path);
        if (it.link) |tgt| {
            const arrow = " -> ";
            if (used + arrow.len < width) {
                try wr.writeAll(if (selected) ANSI_REV ++ ANSI_DIM else ANSI_DIM);
                try wr.writeAll(arrow);
                used += arrow.len;
                try writeTrunc(wr, tgt, if (width > used) width - used else 0);
                used += visibleCols(tgt);
            }
        }
        try wr.writeAll(ANSI_RESET);
        const tag: []const u8 = if (it.link != null) " link" else if (it.dir) " dir" else " file";
        if (used + tag.len < width) {
            try wr.writeAll(if (selected) ANSI_REV ++ ANSI_DIM else ANSI_DIM);
            try wr.writeAll(tag);
        }
        try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
    }
}

pub fn writePicker(wr: *std.Io.Writer, p: *Picker, height: usize, width: usize) !void {
    const win = p.window(height);
    try wr.writeAll(ANSI_DIM);
    try writeTrunc(wr, p.title, width);
    try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
    var pi: usize = win.start;
    while (pi < win.start + win.count) : (pi += 1) {
        const it = p.items[pi];
        const selected = pi == p.sel;
        if (selected) {
            try wr.writeAll(ANSI_DIM ++ "› " ++ ANSI_RESET ++ ANSI_REV);
        } else {
            try wr.writeAll(ANSI_DIM ++ "  ");
        }
        var used: usize = 2;
        try writeTrunc(wr, it.label, if (width > used) width - used else 0);
        used += visibleCols(it.label);
        if (it.hint.len > 0 and used + 3 < width) {
            try wr.writeAll("  ");
            used += 2;
            try writeTrunc(wr, it.hint, width - used);
        }
        try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
    }
}

const SAN_CAP = 96;
/// 摘要行防御:换行/制表/控制符折叠为单行空格(activity detail 输入可能带 \n,
/// 直接写出会把一行撑成两行并挤乱底部布局)。完整剥离 ANSI 转义序列
/// (含 \x1b[2m 这类:仅剥 0x1b 会留下字面 "[2m")。UTF-8 边界安全。
fn inlineSan(buf: *[SAN_CAP]u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var esc = false;
    for (s) |c| {
        if (esc) {
            if (c == 0x1b) continue;
            if (c >= 0x40 and c <= 0x7E) esc = false;
            continue;
        }
        if (c == 0x1b) {
            esc = true;
            continue;
        }
        const ch: u8 = switch (c) {
            '\n', '\r', '\t' => ' ',
            else => c,
        };
        if (ch == ' ') {
            if (n == 0 or buf[n - 1] == ' ') continue;
        }
        if (n >= SAN_CAP - 3) break;
        buf[n] = ch;
        n += 1;
    }
    return buf[0..util.utf8SafeEnd(buf[0..n])];
}

pub fn writeStatusIndicator(wr: *std.Io.Writer, views: []const activity.View, streaming: bool, frame_ms: i64, width: usize, max_rows: usize) !void {
    _ = streaming;
    if (max_rows == 0) return;
    var san_buf: [SAN_CAP]u8 = undefined;
    // pi 式单行状态:⠋ Working · 12s · esc to interrupt(全 muted,无详情子行)
    var elapsed: i64 = 0;
    var retry_n: u32 = 0;
    for (views) |v| {
        if (v.detached) continue;
        if (v.elapsed_ms > elapsed) elapsed = v.elapsed_ms;
        if (v.attempt > retry_n) retry_n = v.attempt;
    }
    var eb: [24]u8 = undefined;
    const el = activity.formatElapsed(&eb, elapsed);
    try wr.writeAll(ANSI_DIM);
    try wr.writeAll(activity.spinnerFrame(frame_ms));
    try wr.writeAll(" Working · ");
    try wr.writeAll(el);
    if (retry_n > 1) {
        var rb: [16]u8 = undefined;
        const rs = std.fmt.bufPrint(&rb, " · retry {d}", .{retry_n - 1}) catch "";
        try wr.writeAll(rs);
    }
    try wr.writeAll(" · esc to interrupt");
    try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
    if (max_rows == 1) return;
    // pi-subagents 插件式摘要行:● agent · tool bash · 12s,最多 2 行;
    // 超出折叠为「… +N more」(查看走 j /jobs)。工具/http 不单列(卡里已见)。
    var sub_total: usize = 0;
    for (views) |v| {
        if (v.kind == .subagent) sub_total += 1;
    }
    const sub_cap = @min(sub_total, 2);
    var shown: usize = 0;
    for (views) |v| {
        if (v.kind != .subagent) continue;
        if (shown >= sub_cap) break;
        try wr.writeAll(ANSI_DIM ++ "● " ++ ANSI_RESET);
        var used: usize = 2;
        const name_c = inlineSan(&san_buf, v.name);
        try writeTrunc(wr, name_c, if (width > used) width - used else 0);
        used += visibleCols(name_c);
        if (v.detail.len > 0 and used + 3 < width) {
            const det_c = inlineSan(&san_buf, v.detail);
            try wr.writeAll(ANSI_DIM ++ " · ");
            used += 3;
            try writeTrunc(wr, det_c, width - used);
        }
        const eln = activity.formatElapsed(&eb, v.elapsed_ms);
        if (used + 1 + eln.len < width) {
            try wr.writeAll(ANSI_DIM ++ " · ");
            try wr.writeAll(eln);
            try wr.writeAll(ANSI_RESET);
        } else {
            try wr.writeAll(ANSI_RESET);
        }
        try wr.writeAll("\x1b[K\r\n");
        shown += 1;
    }
    if (sub_total > shown) {
        var nb: [48]u8 = undefined;
        const more = std.fmt.bufPrint(&nb, "  … +{d} more · j 查看", .{sub_total - shown}) catch "  … more";
        try wr.writeAll(ANSI_DIM);
        try writeTrunc(wr, more, width);
        try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
    }
}

pub fn writeBoxEdge(wr: *std.Io.Writer, left: []const u8, right: []const u8, width: usize) !void {
    try wr.writeAll(ANSI_DIM);
    try wr.writeAll(left);
    const dashes = if (width > 2) width - 2 else 0;
    var i: usize = 0;
    while (i < dashes) : (i += 1) try wr.writeAll("─");
    try wr.writeAll(right);
    try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
}

pub fn writeTrunc(wr: *std.Io.Writer, s: []const u8, width: usize) !void {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len and cols < width) {
        const next = skipAnsi(s, i);
        if (next != i) {
            try wr.writeAll(s[i..next]);
            i = next;
            continue;
        }
        const ch = charCols(s, i);
        if (cols + ch.cols > width) break;
        try wr.writeAll(s[i .. i + ch.n]);
        cols += ch.cols;
        i += ch.n;
    }
}

pub fn writeActivityLine(wr: *std.Io.Writer, v: activity.View, frame_ms: i64, width: usize) !void {
    var used: usize = 0;
    if (v.detached) {
        try wr.writeAll(ANSI_DIM ++ "~" ++ ANSI_RESET ++ " ");
    } else {
        try wr.writeAll(ANSI_DIM);
        try wr.writeAll(activity.spinnerFrame(frame_ms));
        try wr.writeAll(ANSI_RESET ++ " ");
    }
    used += 2;

    const label: []const u8 = switch (v.kind) {
        .tool => v.name,
        .http => "model",
        // subagent 的 name 已是真名(entry.name),不再写死 "agent"
        .subagent => v.name,
    };
    try wr.writeAll(label);
    used += label.len;

    var eb: [24]u8 = undefined;
    const el = activity.formatElapsed(&eb, v.elapsed_ms);
    try wr.writeAll(" " ++ ANSI_DIM);
    try wr.writeAll(el);
    used += 1 + el.len;
    if (v.limit_ms > 0 and !v.detached) {
        var lb: [24]u8 = undefined;
        const lim = activity.formatLimit(&lb, v.limit_ms);
        try wr.writeAll("/");
        try wr.writeAll(lim);
        used += 1 + lim.len;
    }
    try wr.writeAll(ANSI_RESET);

    if (v.bytes > 0) {
        var bb: [24]u8 = undefined;
        const bs = activity.formatBytes(&bb, v.bytes);
        try wr.writeAll("  " ++ ANSI_DIM);
        try wr.writeAll(bs);
        try wr.writeAll(ANSI_RESET);
        used += 2 + bs.len;
    }

    if (v.attempt > 1) {
        var ab: [24]u8 = undefined;
        const as = std.fmt.bufPrint(&ab, "  retry {d}", .{v.attempt - 1}) catch "";
        try wr.writeAll(ANSI_DIM);
        try wr.writeAll(as);
        try wr.writeAll(ANSI_RESET);
        used += as.len;
    }

    if (v.detached) {
        try wr.writeAll(ANSI_DIM ++ "  [bg]" ++ ANSI_RESET);
        used += 6;
    }

    if (v.detail.len > 0 and used + 3 < width) {
        const room = width - used - 3;
        try wr.writeAll("  " ++ ANSI_DIM);
        const cut = activity.truncateToCols(v.detail, room);
        try wr.writeAll(v.detail[0..cut]);
        if (cut < v.detail.len) try wr.writeAll("…");
        try wr.writeAll(ANSI_RESET);
    }
}
