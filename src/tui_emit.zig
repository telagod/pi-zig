// tui_emit.zig — cell emit / gutters / tool paint. Split from tui.zig.
const std = @import("std");
const util = @import("core").util;
const activity = @import("core").activity;
const ai = @import("core").ai;
const theme_mod = @import("theme.zig");
const markdown = @import("markdown.zig");
const measure = @import("tui_measure.zig");
const draw = @import("tui_draw.zig");
const types = @import("tui_types.zig");

const writeTrunc = draw.writeTrunc;

const CellKind = types.CellKind;
const ToolStatus = types.ToolStatus;
const ToolMeta = types.ToolMeta;
const Cell = types.Cell;

const ANSI_RESET = "\x1b[0m";
const ANSI_BOLD = "\x1b[1m";
const ANSI_DIM = "\x1b[2m";
const ANSI_ITALIC = "\x1b[3m";

var theme_ptr: ?*const theme_mod.Theme = null;
// 主题代数:applyTheme → attachTheme 时递增,让 md 缓存跨主题切换失效。
var theme_epoch: usize = 0;

pub fn attachTheme(t: *const theme_mod.Theme) void {
    theme_ptr = t;
    theme_epoch += 1;
}

fn theme() theme_mod.Theme {
    return if (theme_ptr) |p| p.* else theme_mod.Theme{};
}

var fallback_theme: theme_mod.Theme = .{};

fn theme_mod_ref() *const theme_mod.Theme {
    return theme_ptr orelse &fallback_theme;
}

fn nowMs() i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.awake, util.io).nanoseconds, std.time.ns_per_ms));
}

const Layer = enum { none, user, think, assistant, tool, chrome };

fn layerOf(kind: CellKind) Layer {
    return switch (kind) {
        .user => .user,
        .think => .think,
        .assistant => .assistant,
        .tool, .tool_end => .tool,
        .chrome, .session_header, .status_card => .chrome,
    };
}

/// Codex rhythm: blank before/after user; blank between think ↔ text ↔ tool.
/// Tool end hangs under its tool (no gap); sibling tools stay grouped.
pub fn gapBetween(prev: CellKind, next: CellKind) bool {
    if (next == .tool_end) return false;
    if ((prev == .tool or prev == .tool_end) and next == .tool) return false;
    if (next == .user or prev == .user) return true;
    const a = layerOf(prev);
    const b = layerOf(next);
    return a != .none and b != .none and a != b;
}

pub fn gutter(kind: CellKind) struct { first: []const u8, rest: []const u8, pad: usize } {
    return switch (kind) {
        // User: full-height bar on every line. No ┌/└ rows.
        .user => .{ .first = ANSI_BOLD ++ "▎ ", .rest = ANSI_BOLD ++ "▎ ", .pad = 2 },
        // Assistant is an open block: indent only, no bar.
        .assistant => .{ .first = "  ", .rest = "  ", .pad = 2 },
        // Think recedes behind the answer: supporting column, dim italic ┆.
        .think => .{ .first = ANSI_ITALIC ++ "    ┆ ", .rest = ANSI_ITALIC ++ "    ┆ ", .pad = 6 },
        // Tool title: indent 4 + ▸. Status rides on this line.
        .tool => .{ .first = ANSI_DIM ++ "    ▸ " ++ ANSI_RESET, .rest = "      ", .pad = 6 },
        .tool_end => .{ .first = ANSI_DIM ++ "      └ ", .rest = ANSI_DIM ++ "        ", .pad = 8 },
        .session_header, .status_card, .chrome => .{ .first = "", .rest = "", .pad = 0 },
    };
}

pub fn gutterInner(kind: CellKind, width: usize) usize {
    const pad = gutter(kind).pad;
    return if (width > pad) width - pad else 1;
}

fn countNewlines(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

pub fn countContentLines(s: []const u8) usize {
    if (s.len == 0) return 0;
    var n: usize = 1;
    for (s) |c| {
        if (c == '\n') n += 1;
    }
    if (s[s.len - 1] == '\n') n -= 1;
    return n;
}

fn bodyView(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\n') return s[0 .. s.len - 1];
    return s;
}

fn toolElapsedMs(meta: ToolMeta, now_ms: i64) i64 {
    if (meta.status == .running) {
        if (meta.start_ms == 0) return 0;
        return @max(0, now_ms - meta.start_ms);
    }
    return meta.elapsed_ms;
}

fn formatToolStatus(buf: []u8, meta: ToolMeta, now_ms: i64) []const u8 {
    const outcome: []const u8 = switch (meta.status) {
        .running => "running",
        .ok => "ok",
        .err => "err",
    };
    var eb: [24]u8 = undefined;
    const et = activity.formatElapsed(&eb, toolElapsedMs(meta, now_ms));
    const ink = theme().fgStatus(paintStatus(meta.status));
    const ink_end: []const u8 = if (ink.len > 0) ANSI_RESET else "";
    if (meta.status == .running) {
        return std.fmt.bufPrint(buf, "{s} {s}", .{ outcome, et }) catch outcome;
    }
    return std.fmt.bufPrint(buf, "{s}{s}{s} {s} {d}ln", .{ ink, outcome, ink_end, et, meta.lines }) catch outcome;
}

pub fn flowGoalPreview(args: []const u8) []const u8 {
    const key = "\"goal\":\"";
    if (std.mem.indexOf(u8, args, key)) |i| {
        const start = i + key.len;
        var end = start;
        while (end < args.len) : (end += 1) {
            if (args[end] == '\\') {
                end += 1;
                continue;
            }
            if (args[end] == '"') break;
        }
        if (end > start) return args[start..end];
    }
    return args[0..@min(args.len, 80)];
}

fn toolTitle(meta: ToolMeta, buf: []u8, now_ms: i64) []const u8 {
    var sb: [64]u8 = undefined;
    const status = formatToolStatus(&sb, meta, now_ms);
    if (meta.preview.len == 0) {
        return std.fmt.bufPrint(buf, "{s}{s}{s}  {s}", .{
            ANSI_BOLD, meta.name, ANSI_RESET, status,
        }) catch meta.name;
    }
    return std.fmt.bufPrint(buf, "{s}{s}{s}  {s}{s}{s}{s}  {s}", .{
        ANSI_BOLD, meta.name, ANSI_RESET, ANSI_DIM, ANSI_ITALIC, meta.preview, ANSI_RESET, status,
    }) catch meta.name;
}

const TOOL_HEAD_PREFIX = ANSI_DIM ++ "    ▸ " ++ ANSI_RESET;
const TOOL_HEAD_REST = "      ";
const TOOL_BODY_FIRST = "      │ ";
const TOOL_BODY_LAST = "      └ ";
const TOOL_BODY_REST = "        ";
const TOOL_BODY_PAD: usize = 8;

fn toolBodyInner(width: usize) usize {
    return if (width > TOOL_BODY_PAD) width - TOOL_BODY_PAD else 1;
}

fn isWorkflowTool(meta: ToolMeta) bool {
    return std.mem.eql(u8, meta.name, "workflow");
}

pub fn toolRowCount(meta: ToolMeta, width: usize) usize {
    if (isWorkflowTool(meta)) {
        var rows: usize = 1;
        if (meta.body.items.len > 0) rows += countContentLines(meta.body.items);
        return rows;
    }
    var tb: [512]u8 = undefined;
    const title = toolTitle(meta, &tb, nowMs());
    var rows = wrapRowCount(title, gutterInner(.tool, width));
    if (meta.folded) {
        // 折叠尾行 `· (N more lines, ctrl+o)`
        const view = bodyView(meta.body.items);
        if (view.len > 0 and countContentLines(view) > 2) rows += 1;
        return rows;
    }
    {
        const view = bodyView(meta.body.items);
        if (view.len > 0) {
            const inner = toolBodyInner(width);
            var it = std.mem.splitScalar(u8, view, '\n');
            while (it.next()) |part| {
                rows += wrapRowCount(part, inner);
            }
        }
    }
    return rows;
}

const Styled = struct {
    owned: ?[]u8 = null,
    text: []const u8,
    fn deinit(self: Styled, alloc: std.mem.Allocator) void {
        if (self.owned) |o| alloc.free(o);
    }
};

pub fn paintStatus(s: ToolStatus) theme_mod.PaintStatus {
    return switch (s) {
        .running => .running,
        .ok => .ok,
        .err => .err,
    };
}

/// markdown 渲染缓存:渲染结果钉在 cell 上,指纹 (epoch<<32)|len 不变即复用。
/// 流式一轮从「每帧两次全文渲染」降为「每个新 token 一次增量渲染」。
fn styledCached(alloc: std.mem.Allocator, cell: *Cell) Styled {
    const kind = cell.kind;
    const text = cell.text.items;
    if (kind != .user and kind != .assistant) return .{ .text = text };
    if (text.len == 0 or theme().mode == .none) return .{ .text = text };
    const fp = (theme_epoch << 32) | @as(usize, text.len & 0xFFFF_FFFF);
    if (cell.md_buf != null and cell.md_fp == fp) return .{ .text = cell.md_buf.? };
    const painted = markdown.render(alloc, theme_mod_ref(), text) catch return .{ .text = text };
    if (cell.md_buf) |old| alloc.free(old);
    cell.md_buf = painted;
    cell.md_fp = fp;
    return .{ .text = painted };
}

pub fn userRowCount(text: []const u8, width: usize) usize {
    const inner = gutterInner(.user, width);
    if (text.len == 0) return 1;
    var rows: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |part| {
        rows += wrapRowCount(part, inner);
    }
    return if (rows == 0) 1 else rows;
}

fn emitFrameLine(wr: *std.Io.Writer, line: []const u8, skipped: *usize, emitted: *usize, limit: usize) !void {
    if (emitted.* >= limit) return;
    if (skipped.* > 0) {
        skipped.* -= 1;
        return;
    }
    try wr.writeAll(line);
    try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
    emitted.* += 1;
}

fn emitPrefixed(
    wr: *std.Io.Writer,
    first: []const u8,
    rest: []const u8,
    text: []const u8,
    inner: usize,
    skipped: *usize,
    emitted: *usize,
    limit: usize,
    band: []const u8,
) !void {
    if (emitted.* >= limit) return;
    const n = wrapRowCount(text, inner);
    if (skipped.* >= n) {
        skipped.* -= n;
        return;
    }
    const local = skipped.*;
    skipped.* = 0;
    emitted.* += try emitWrappedGutter(wr, first, rest, text, inner, local, limit - emitted.*, band);
}

fn emitFlow(wr: *std.Io.Writer, meta: ToolMeta, width: usize, skip: usize, limit: usize) !usize {
    if (limit == 0) return 0;
    var skipped = skip;
    var emitted: usize = 0;
    var tb: [512]u8 = undefined;
    const title = toolTitle(meta, &tb, nowMs());
    try emitPrefixed(wr, TOOL_HEAD_PREFIX, TOOL_HEAD_REST, title, gutterInner(.tool, width), &skipped, &emitted, limit, theme().bgTool(paintStatus(meta.status)));
    if (meta.body.items.len == 0) return emitted;
    var it = std.mem.splitScalar(u8, meta.body.items, '\n');
    while (it.next()) |line| {
        if (emitted >= limit) break;
        try emitPrefixed(wr, "      ", "      ", line, width -| 6, &skipped, &emitted, limit, "");
    }
    return emitted;
}

fn emitTool(wr: *std.Io.Writer, meta: ToolMeta, width: usize, skip: usize, limit: usize) !usize {
    if (isWorkflowTool(meta)) return emitFlow(wr, meta, width, skip, limit);
    if (limit == 0) return 0;
    var skipped = skip;
    var emitted: usize = 0;
    var tb: [512]u8 = undefined;
    const title = toolTitle(meta, &tb, nowMs());
    try emitPrefixed(wr, TOOL_HEAD_PREFIX, TOOL_HEAD_REST, title, gutterInner(.tool, width), &skipped, &emitted, limit, theme().bgTool(paintStatus(meta.status)));
    if (meta.folded) {
        // pi 式折叠尾行:体有未尽之行则缀 `· (N more lines, ctrl+o)`
        const view = bodyView(meta.body.items);
        if (view.len > 0) {
            const n = countContentLines(view);
            if (n > 2) {
                var tail_buf: [48]u8 = undefined;
                const tail = std.fmt.bufPrint(&tail_buf, ANSI_DIM ++ "· ({d} more lines, ctrl+o)" ++ ANSI_RESET, .{n - 2}) catch "· (more, ctrl+o)";
                try emitPrefixed(wr, "    ", "    ", tail, width -| 4, &skipped, &emitted, limit, theme().bgTool(paintStatus(meta.status)));
            }
        }
        return emitted;
    }
    {
        const view = bodyView(meta.body.items);
        if (view.len > 0) {
            const inner = toolBodyInner(width);
            const nlines = countContentLines(view);
            var it = std.mem.splitScalar(u8, view, '\n');
            const body_ink: []const u8 = if (meta.status == .err) theme().fg_err else theme().fg_output;
            var i: usize = 0;
            while (it.next()) |part| {
                i += 1;
                const first = if (i == nlines) TOOL_BODY_LAST else TOOL_BODY_FIRST;
                try emitPrefixed(wr, first, TOOL_BODY_REST, part, inner, &skipped, &emitted, limit, body_ink);
            }
        }
    }
    return emitted;
}

fn emitUser(wr: *std.Io.Writer, text: []const u8, width: usize, skip: usize, limit: usize, hl: bool) !usize {
    if (limit == 0) return 0;
    var skipped = skip;
    var emitted: usize = 0;
    const g = gutter(.user);
    const inner = gutterInner(.user, width);
    // bg + bold 一并作 band:Markdown 中途 RESET 后 writeReband 复披,行内强调后仍粗
    var band_buf: [48]u8 = undefined;
    const bg = if (hl) "\x1b[7m" else theme().bgUser();
    const band = blk: {
        if (bg.len == 0 or bg.len + ANSI_BOLD.len > band_buf.len) break :blk bg;
        @memcpy(band_buf[0..bg.len], bg);
        @memcpy(band_buf[bg.len..][0..ANSI_BOLD.len], ANSI_BOLD);
        break :blk band_buf[0 .. bg.len + ANSI_BOLD.len];
    };
    if (text.len == 0) {
        try emitPrefixed(wr, g.first, g.rest, "", inner, &skipped, &emitted, limit, band);
        return emitted;
    }
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |part| {
        try emitPrefixed(wr, g.first, g.rest, part, inner, &skipped, &emitted, limit, band);
    }
    return emitted;
}

pub fn cellRowCount(alloc: std.mem.Allocator, cell: *Cell, painted: []const u8, think_open: bool, width: usize) usize {
    if (cell.kind == .session_header or cell.kind == .status_card) {
        if (painted.len == 0) return 0;
        return countNewlines(painted) + 1;
    }
    const md = styledCached(alloc, cell);
    defer md.deinit(alloc);
    if (cell.kind == .user) return userRowCount(md.text, width);
    if (cell.kind == .think) return thinkRowCount(cell.text.items, think_open, width);
    if (cell.kind == .tool) {
        if (cell.tool) |meta| return toolRowCount(meta, width);
    }
    const inner = gutterInner(cell.kind, width);
    if (md.text.len == 0) return 1;
    var rows: usize = 0;
    var it = std.mem.splitScalar(u8, md.text, '\n');
    while (it.next()) |part| {
        rows += wrapRowCount(part, inner);
    }
    return if (rows == 0) 1 else rows;
}

pub fn emitDocLines(wr: *std.Io.Writer, text: []const u8, skip: *usize, emitted: *usize, limit: usize) !void {
    if (text.len == 0) return;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i < text.len and text[i] != '\n') continue;
        var line = text[start..i];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (i == text.len and line.len == 0) break;
        if (skip.* > 0) {
            skip.* -= 1;
        } else if (emitted.* < limit) {
            try wr.writeAll(line);
            if (emitted.* + 1 < limit) {
                try wr.writeAll("\x1b[K\r\n");
            } else {
                try wr.writeAll("\x1b[K");
            }
            emitted.* += 1;
        }
        start = i + 1;
        if (i == text.len) break;
    }
}

pub fn emitCell(alloc: std.mem.Allocator, wr: *std.Io.Writer, cell: *Cell, painted: []const u8, think_open: bool, width: usize, skip: usize, limit: usize) !usize {
    if (limit == 0) return 0;
    if (cell.kind == .session_header or cell.kind == .status_card) {
        return emitPainted(wr, painted, width, skip, limit);
    }
    const md = styledCached(alloc, cell);
    defer md.deinit(alloc);
    if (cell.kind == .user) {
        return emitUser(wr, md.text, width, skip, limit, cell.hl);
    }
    if (cell.kind == .think) {
        return emitThink(wr, cell.text.items, think_open, width, skip, limit);
    }
    if (cell.kind == .tool) {
        if (cell.tool) |meta| return emitTool(wr, meta, width, skip, limit);
    }
    const g = gutter(cell.kind);
    const inner = gutterInner(cell.kind, width);
    if (cell.kind == .chrome) {
        const color = if (cell.color.len > 0) cell.color else ANSI_DIM;
        return emitChrome(wr, color, cell.text.items, inner, skip, limit);
    }
    if (md.text.len == 0) {
        if (skip > 0) return 0;
        try wr.writeAll(g.first);
        try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
        return 1;
    }
    var emitted: usize = 0;
    var skipped: usize = 0;
    var it = std.mem.splitScalar(u8, md.text, '\n');
    var first = true;
    while (it.next()) |part| {
        const n = wrapRowCount(part, inner);
        if (skipped + n <= skip) {
            skipped += n;
            first = false;
            continue;
        }
        const local = if (skipped < skip) skip - skipped else 0;
        skipped += n;
        const first_g = if (first) g.first else g.rest;
        emitted += try emitWrappedGutter(wr, first_g, g.rest, part, inner, local, limit - emitted, if (cell.hl) "\x1b[7m" else "");
        first = false;
        if (emitted >= limit) return emitted;
    }
    return emitted;
}

fn emitPainted(wr: *std.Io.Writer, painted: []const u8, width: usize, skip: usize, limit: usize) !usize {
    var emitted: usize = 0;
    var skipped: usize = 0;
    var it = std.mem.splitScalar(u8, painted, '\n');
    while (it.next()) |line| {
        if (skipped < skip) {
            skipped += 1;
            continue;
        }
        try writeTrunc(wr, line, width);
        try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
        emitted += 1;
        if (emitted == limit) return emitted;
    }
    return emitted;
}

fn emitChrome(wr: *std.Io.Writer, color: []const u8, text: []const u8, width: usize, skip: usize, limit: usize) !usize {
    var emitted: usize = 0;
    var skipped: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |part| {
        const n = wrapRowCount(part, width);
        if (skipped + n <= skip) {
            skipped += n;
            continue;
        }
        const local = if (skipped < skip) skip - skipped else 0;
        skipped += n;
        const prefix = if (color.len > 0) color else "";
        emitted += try emitWrappedGutter(wr, prefix, prefix, part, width, local, limit - emitted, "");
        if (emitted >= limit) return emitted;
    }
    return emitted;
}

const skipAnsi = measure.skipAnsi;
const charCols = measure.charCols;
const visibleCols = measure.visibleCols;
const truncateToVisible = measure.truncateToVisible;
const ellipsizeAlloc = measure.ellipsizeAlloc;
pub const joinFit = measure.joinFit;
const joinN = measure.joinN;

pub fn wrapRowCount(line: []const u8, width: usize) usize {
    const w = @max(width, 1);
    var rows: usize = 1;
    var cols: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const next = skipAnsi(line, i);
        if (next != i) {
            i = next;
            continue;
        }
        const ch = charCols(line, i);
        if (cols > 0 and cols + ch.cols > w) {
            rows += 1;
            cols = 0;
        }
        cols += ch.cols;
        i += ch.n;
    }
    return rows;
}

/// 写 s,每遇 \x1b[0m 复披 band —— 内部 reset 会剥 bg,须重披。
fn writeReband(wr: *std.Io.Writer, s: []const u8, band: []const u8) !void {
    var off: usize = 0;
    while (std.mem.indexOfPos(u8, s, off, ANSI_RESET)) |idx| {
        try wr.writeAll(s[off .. idx + ANSI_RESET.len]);
        try wr.writeAll(band);
        off = idx + ANSI_RESET.len;
    }
    try wr.writeAll(s[off..]);
}

/// band 非空时:行首披 bg,内容复披,补白至行满再 reset —— 色带达屏缘。
fn emitWrappedGutter(wr: *std.Io.Writer, first: []const u8, rest: []const u8, line: []const u8, width: usize, skip: usize, limit: usize, band: []const u8) !usize {
    if (limit == 0) return 0;
    const w = @max(width, 1);
    var emitted: usize = 0;
    var skipped: usize = 0;
    var cols: usize = 0;
    var row_from: usize = 0;
    var row: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const next = skipAnsi(line, i);
        if (next != i) {
            i = next;
            continue;
        }
        const ch = charCols(line, i);
        if (cols > 0 and cols + ch.cols > w) {
            if (skipped < skip) {
                skipped += 1;
            } else {
                if (band.len > 0) try wr.writeAll(band);
                try wr.writeAll(if (row == 0) first else rest);
                if (band.len > 0) {
                    try writeReband(wr, line[row_from..i], band);
                    var p: usize = cols;
                    while (p < w) : (p += 1) try wr.writeByte(' ');
                } else {
                    try wr.writeAll(line[row_from..i]);
                }
                try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
                emitted += 1;
                if (emitted == limit) return emitted;
            }
            row += 1;
            row_from = i;
            cols = 0;
        }
        cols += ch.cols;
        i += ch.n;
    }
    if (skipped < skip) return emitted;
    if (band.len > 0) try wr.writeAll(band);
    try wr.writeAll(if (row == 0) first else rest);
    if (band.len > 0) {
        try writeReband(wr, line[row_from..line.len], band);
        var p: usize = cols;
        while (p < w) : (p += 1) try wr.writeByte(' ');
    } else {
        try wr.writeAll(line[row_from..line.len]);
    }
    try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
    return emitted + 1;
}

pub const ThinkLevel = ai.ThinkLevel;

pub fn classifyThink(n: usize) ThinkLevel {
    if (n == 0) return .off;
    if (n < 400) return .low;
    if (n < 1500) return .medium;
    if (n < 4000) return .high;
    return .max;
}

pub fn thinkColor(level: ThinkLevel) []const u8 {
    return switch (level) {
        .off => ANSI_DIM,
        .minimal => "\x1b[32m",
        .low => "\x1b[32m",
        .medium => "\x1b[36m",
        .high => "\x1b[36m",
        .xhigh => "\x1b[35m",
        .max => "\x1b[35m",
    };
}

pub fn thinkLabel(level: ThinkLevel) []const u8 {
    return level.label();
}

pub fn thinkRowCount(buf: []const u8, open: bool, width: usize) usize {
    if (buf.len == 0) return 0;
    if (!open) return 1;
    var rows: usize = 0;
    const inner = gutterInner(.think, width);
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |p| {
        rows += wrapRowCount(p, inner);
    }
    return if (rows == 0) 1 else rows;
}

fn emitThink(wr: *std.Io.Writer, buf: []const u8, open: bool, width: usize, skip: usize, limit: usize) !usize {
    if (buf.len == 0 or limit == 0) return 0;
    var skipped = skip;
    var emitted: usize = 0;
    if (!open) {
        var fold_buf: [80]u8 = undefined;
        const fold = std.fmt.bufPrint(&fold_buf, "{s}{s}    ┆ thought{s}", .{ theme().fg_think, ANSI_ITALIC, ANSI_RESET }) catch "    ┆ thought";
        try emitFrameLine(wr, fold, &skipped, &emitted, limit);
        return emitted;
    }
    const g = gutter(.think);
    const inner = gutterInner(.think, width);
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |p| {
        try emitPrefixed(wr, g.first, g.rest, p, inner, &skipped, &emitted, limit, theme().fg_think);
        if (emitted >= limit) return emitted;
    }
    return emitted;
}

pub fn wrapCursor(s: []const u8, cursor: usize, width: usize) struct { row: usize, col: usize } {
    const w = @max(width, 1);
    const end = @min(cursor, s.len);
    var row: usize = 0;
    var cols: usize = 0;
    var i: usize = 0;
    while (i < end) {
        const next = skipAnsi(s, i);
        if (next != i) {
            i = next;
            continue;
        }
        const ch = charCols(s, i);
        if (cols > 0 and cols + ch.cols > w) {
            row += 1;
            cols = 0;
        }
        cols += ch.cols;
        i += ch.n;
    }
    return .{ .row = row, .col = cols };
}

fn writeComposerRow(wr: *std.Io.Writer, prefix: []const u8, slice: []const u8, pad_n: usize) !void {
    try wr.writeAll(prefix);
    try wr.writeAll(slice);
    var pad = pad_n;
    while (pad > 0) : (pad -= 1) try wr.writeByte(' ');
    try wr.writeAll(ANSI_DIM ++ "│" ++ ANSI_RESET ++ "\x1b[K\r\n");
}

pub fn emitComposer(wr: *std.Io.Writer, input: []const u8, inner: usize, rows: usize, skip: usize) !void {
    if (rows == 0) return;
    var emitted: usize = 0;
    var row_i: usize = 0;
    var cols: usize = 0;
    var row_from: usize = 0;
    var i: usize = 0;
    const first = ANSI_DIM ++ "│ › " ++ ANSI_RESET;
    const rest = ANSI_DIM ++ "│   " ++ ANSI_RESET;
    while (i < input.len) {
        const next = skipAnsi(input, i);
        if (next != i) {
            i = next;
            continue;
        }
        const ch = charCols(input, i);
        if (cols > 0 and cols + ch.cols > inner) {
            if (row_i >= skip) {
                try writeComposerRow(wr, if (row_i == 0) first else rest, input[row_from..i], if (inner > cols) inner - cols else 0);
                emitted += 1;
                if (emitted == rows) return;
            }
            row_i += 1;
            row_from = i;
            cols = 0;
        }
        cols += ch.cols;
        i += ch.n;
    }
    if (emitted < rows) {
        if (row_i >= skip) {
            try writeComposerRow(wr, if (row_i == 0) first else rest, input[row_from..input.len], if (inner > cols) inner - cols else 0);
            emitted += 1;
        }
        row_i += 1;
    }
    while (emitted < rows) : (emitted += 1) {
        try writeComposerRow(wr, rest, "", inner);
    }
}

test "styled markdown is cached per cell until text or theme changes" {
    const t = std.testing;
    const a = std.testing.allocator;

    var th = theme_mod.Theme{ .mode = .truecolor };
    th.rebuild();
    attachTheme(&th);

    var cell = Cell{ .kind = .assistant, .text = std.array_list.Managed(u8).init(a) };
    defer cell.text.deinit();
    defer if (cell.md_buf) |b| a.free(b);
    try cell.text.appendSlice("hello **bold**");

    const first = styledCached(a, &cell);
    try t.expect(cell.md_buf != null);
    const buf1 = cell.md_buf.?.ptr;
    // 同指纹:复用同一块缓冲,不重渲染
    const second = styledCached(a, &cell);
    try t.expectEqual(buf1, cell.md_buf.?.ptr);
    try t.expectEqualStrings(first.text, second.text);
    // 文本增长:指纹变,重新渲染
    try cell.text.appendSlice(" world");
    _ = styledCached(a, &cell);
    try t.expect(cell.md_buf.?.len >= first.text.len);
    // 主题切换:epoch 递增,旧缓存作废
    const fp_before = cell.md_fp;
    attachTheme(&th);
    _ = styledCached(a, &cell);
    try t.expect(cell.md_fp != fp_before);
}
