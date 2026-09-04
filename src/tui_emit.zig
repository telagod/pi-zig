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
const ANSI_YELLOW = "\x1b[33m";
const ANSI_CYAN = "\x1b[36m";

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

fn formatToolStatus(buf: []u8, meta: ToolMeta, now_ms: i64, frame_ms: i64) []const u8 {
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
        // pi 式:卡内转圈(⠋ Running...);帧取 now_ms 同参,与活动区同速
        return std.fmt.bufPrint(buf, "{s}{s} {s}", .{ activity.spinnerFrame(frame_ms), outcome, et }) catch outcome;
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
    const status = formatToolStatus(&sb, meta, now_ms, now_ms);
    if (meta.preview.len == 0) {
        return std.fmt.bufPrint(buf, "{s}{s}{s}  {s}", .{
            ANSI_BOLD, meta.name, ANSI_RESET, status,
        }) catch meta.name;
    }
    return std.fmt.bufPrint(buf, "{s}{s}{s}  {s}{s}{s}{s}  {s}", .{
        ANSI_BOLD, meta.name, ANSI_RESET, ANSI_DIM, ANSI_ITALIC, meta.preview, ANSI_RESET, status,
    }) catch meta.name;
}

pub fn toolGroupTitle(cells: []const Cell, buf: []u8) []const u8 {
    if (cells.len == 0) return "";
    var count: usize = 0;
    var err_count: usize = 0;
    var total_elapsed: i64 = 0;

    const MaxDistinct = 6;
    var names: [MaxDistinct][]const u8 = undefined;
    var name_counts: [MaxDistinct]usize = [_]usize{0} ** MaxDistinct;
    var n_distinct: usize = 0;

    for (cells) |c| {
        const tm = c.tool orelse continue;
        count += 1;
        if (tm.status == .err) err_count += 1;
        total_elapsed += tm.elapsed_ms;

        var found = false;
        for (names[0..n_distinct], 0..) |n, i| {
            if (std.mem.eql(u8, n, tm.name)) {
                name_counts[i] += 1;
                found = true;
                break;
            }
        }
        if (!found and n_distinct < MaxDistinct) {
            names[n_distinct] = tm.name;
            name_counts[n_distinct] = 1;
            n_distinct += 1;
        }
    }

    var breakdown_buf: [128]u8 = undefined;
    var b_len: usize = 0;
    for (names[0..n_distinct], 0..) |name, i| {
        if (b_len > 0 and b_len + 2 < breakdown_buf.len) {
            breakdown_buf[b_len] = ',';
            breakdown_buf[b_len + 1] = ' ';
            b_len += 2;
        }
        const cnt = name_counts[i];
        const piece = if (cnt > 1)
            std.fmt.bufPrint(breakdown_buf[b_len..], "{d} {s}", .{ cnt, name }) catch break
        else
            std.fmt.bufPrint(breakdown_buf[b_len..], "{s}", .{name}) catch break;
        b_len += piece.len;
    }
    const breakdown = breakdown_buf[0..b_len];

    var eb: [24]u8 = undefined;
    const et = activity.formatElapsed(&eb, total_elapsed);

    var status_buf: [64]u8 = undefined;
    const status = if (err_count > 0) blk: {
        const ink = theme().fgStatus(.err);
        break :blk std.fmt.bufPrint(&status_buf, "{s}{d}/{d} ok, {d} err{s} {s}", .{
            ink, count - err_count, count, err_count, if (ink.len > 0) ANSI_RESET else "", et,
        }) catch "err";
    } else blk: {
        const ink = theme().fgStatus(.ok);
        break :blk std.fmt.bufPrint(&status_buf, "{s}ok{s} {s}", .{
            ink, if (ink.len > 0) ANSI_RESET else "", et,
        }) catch "ok";
    };

    if (breakdown.len > 0) {
        return std.fmt.bufPrint(buf, "{s}{d} commands{s} ({s})  {s}  {s}[Ctrl+O]{s}", .{
            ANSI_BOLD, count, ANSI_RESET, breakdown, status, ANSI_DIM, ANSI_RESET,
        }) catch "commands";
    } else {
        return std.fmt.bufPrint(buf, "{s}{d} commands{s}  {s}  {s}[Ctrl+O]{s}", .{
            ANSI_BOLD, count, ANSI_RESET, status, ANSI_DIM, ANSI_RESET,
        }) catch "commands";
    }
}

pub fn toolGroupRowCount(cells: []const Cell, width: usize) usize {
    if (cells.len == 0) return 0;
    var tb: [384]u8 = undefined;
    const title = toolGroupTitle(cells, &tb);
    return wrapRowCount(title, gutterInner(.tool, width));
}

pub fn emitToolGroup(wr: *std.Io.Writer, cells: []const Cell, width: usize, skip: usize, limit: usize) !usize {
    if (limit == 0 or cells.len == 0) return 0;
    var tb: [384]u8 = undefined;
    const title = toolGroupTitle(cells, &tb);
    var has_err = false;
    for (cells) |c| {
        if (c.tool) |tm| {
            if (tm.status == .err) {
                has_err = true;
                break;
            }
        }
    }
    const st: ToolStatus = if (has_err) .err else .ok;
    var skipped = skip;
    var emitted: usize = 0;
    try emitPrefixed(wr, TOOL_HEAD_PREFIX, TOOL_HEAD_REST, title, gutterInner(.tool, width), &skipped, &emitted, limit, theme().bgTool(paintStatus(st)));
    return emitted;
}

const TOOL_HEAD_PREFIX = ANSI_DIM ++ "    ▸ " ++ ANSI_RESET;
const TOOL_HEAD_REST = "      ";
const TOOL_BODY_FIRST = "      │ ";
const TOOL_BODY_LAST = "      └ ";
const TOOL_BODY_REST = "        ";
const TOOL_BODY_PAD: usize = 8;

// —— boxed 展开卡(omp 形):╭─ 顶边 / │ 正文 │ / ╰─ 底边。
// 折叠一行与窄屏(<40 列)维持旧 gutter 形;workflow/todo 特例逻辑不动。
const TOOL_BOX_MIN_WIDTH: usize = 40;
const TOOL_BOX_BODY_MAX: usize = 20;

fn toolBodyInner(width: usize) usize {
    return if (width > TOOL_BODY_PAD) width - TOOL_BODY_PAD else 1;
}

/// 盒宽跟 composerBoxWidth 规则(cols-1:auto-margin 终端末列触换行)。
/// tui_*.zig 不回引 tui.zig(向下单向),规则就地镜像。
fn toolBoxWidth(width: usize) usize {
    return if (width > 1) width - 1 else width;
}

/// "│ " + " │" 占 4 列,余为正文。
fn toolBoxInner(box_w: usize) usize {
    return if (box_w > 4) box_w - 4 else 1;
}

/// 展开且够宽 → boxed;折叠/窄屏 → 旧 gutter 形。
fn toolBoxed(meta: ToolMeta, width: usize) bool {
    return !meta.folded and width >= TOOL_BOX_MIN_WIDTH;
}

/// 边框随状态色:ok/err 用状态色,running 退 muted(转圈本身已在状态段)。
fn toolBorderInk(status: ToolStatus) []const u8 {
    const t = theme();
    return switch (status) {
        .running => t.muted(),
        .ok, .err => t.fgStatus(paintStatus(status)),
    };
}

pub fn isWorkflowTool(meta: ToolMeta) bool {
    return std.mem.eql(u8, meta.name, "workflow");
}

fn isTodoTool(meta: ToolMeta) bool {
    return std.mem.eql(u8, meta.name, "todo_write") or std.mem.eql(u8, meta.name, "todo_read");
}

/// todo 工具卡行分型(web 端 todoHtml 的 TUI 等价物)。
/// `[x] #id text @bind` → `✓ #id text @bind`(完成 dim);`[>]`→`▶`;`[ ]`→`○`;
/// `(N/M done)` 页脚 dim。JS 输出保持 [ ]/[x] 前缀(web 正则依赖),此处仅换色换字。
const SAN_TODO = 160;
fn todoLine(input: []const u8, out: *[SAN_TODO]u8) []const u8 {
    var n: usize = 0;
    var start: usize = 0;
    var ink: []const u8 = "";
    var glyph: []const u8 = "";
    if (std.mem.startsWith(u8, input, "[x] ")) {
        start = 4;
        ink = ANSI_DIM;
        glyph = "\u{2713}";
    } else if (std.mem.startsWith(u8, input, "[>] ")) {
        start = 4;
        ink = ANSI_YELLOW;
        glyph = "\u{25B6}";
    } else if (std.mem.startsWith(u8, input, "[ ] ")) {
        start = 4;
        ink = ANSI_DIM;
        glyph = "\u{25CB}";
    }
    for (ink) |c| {
        out[n] = c;
        n += 1;
    }
    for (glyph) |c| {
        out[n] = c;
        n += 1;
    }
    if (start > 0) {
        out[n] = ' ';
        n += 1;
    }
    // 主体:扫到尾部 @bind(JS 输出 "  @id")则其后转青色
    var cy: usize = 0;
    for (input[start..]) |c| {
        if (n >= SAN_TODO - 12) break;
        if (cy == 0 and c == '@') {
            for (ANSI_CYAN) |x| {
                out[n] = x;
                n += 1;
            }
            cy = 1;
        }
        out[n] = c;
        n += 1;
    }
    out[n] = 0x1b;
    n += 1;
    out[n] = '0';
    n += 1;
    out[n] = 'm';
    n += 1;
    return out[0..n];
}

/// boxed 卡行数:顶边 1 + 正文(超 20 行截断 + 「… (N more lines)」尾行)+ 底边 1。
/// 计数与 emitToolBoxed 同规则(todo 行不换形再计,沿用旧 gutter 的口径)。
fn toolBoxRowCount(meta: ToolMeta, width: usize) usize {
    const inner = toolBoxInner(toolBoxWidth(width));
    var rows: usize = 2; // 顶边 + 底边
    const view = bodyView(meta.body.items);
    if (view.len == 0) return rows;
    const n = countContentLines(view);
    var it = std.mem.splitScalar(u8, view, '\n');
    var i: usize = 0;
    while (it.next()) |part| {
        i += 1;
        if (n > TOOL_BOX_BODY_MAX and i == TOOL_BOX_BODY_MAX) {
            rows += 1; // 截断尾行
            break;
        }
        rows += wrapRowCount(part, inner);
    }
    return rows;
}

pub fn toolRowCount(meta: ToolMeta, width: usize) usize {
    if (isWorkflowTool(meta)) {
        var rows: usize = 1;
        if (meta.body.items.len > 0) rows += countContentLines(meta.body.items);
        return rows;
    }
    if (toolBoxed(meta, width)) return toolBoxRowCount(meta, width);
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

/// 顶边:`╭─ name · preview ─── status ─╮`(name 粗体,preview dim 斜体,
/// status 带 ok/err 色 + 耗时 + Nln;running 态卡内转圈 ⠋ 走 formatToolStatus)。
/// 可见宽恒为 box_w:preview 超长截断(缀 …),名字过长也截,中缝至少 1  dash。
fn paintBoxTop(buf: []u8, meta: ToolMeta, box_w: usize, now_ms: i64) []const u8 {
    var wr = std.Io.Writer.fixed(buf);
    paintBoxTopInto(&wr, meta, box_w, now_ms) catch {
        // 超宽终端撑爆缓冲:退化为纯名字(调用侧照样成 row,不画崩)
        return meta.name;
    };
    return wr.buffered();
}

fn paintBoxTopInto(wr: *std.Io.Writer, meta: ToolMeta, box_w: usize, now_ms: i64) !void {
    const border = toolBorderInk(meta.status);
    var sb: [64]u8 = undefined;
    const status = formatToolStatus(&sb, meta, now_ms, now_ms);
    const svis = visibleCols(status);
    const name = truncateToVisible(meta.name, box_w -| 9 -| svis);
    const nvis = visibleCols(name);
    // preview 预算:╭─ (3) + name + 「 · 」(3) + 缝(1)+fill(1)+缝(1) + status + 「 ─╮」(3)
    var preview: []const u8 = "";
    var cut = false;
    const pvis_max = box_w -| 12 -| nvis -| svis;
    if (meta.preview.len > 0 and pvis_max >= 6) {
        preview = truncateToVisible(meta.preview, pvis_max - 1);
        cut = preview.len != meta.preview.len;
    }
    const pvis = if (preview.len > 0) visibleCols(preview) + @intFromBool(cut) else 0;
    const used = 3 + nvis + (if (pvis > 0) 3 + pvis else 0) + 2 + svis + 3;
    // 预算(name/preview 截断)保证 used ≤ box_w-1,故 fill ≥ 1(中缝至少 1 dash)
    const fill = box_w -| used;
    try wr.writeAll(border);
    try wr.writeAll("╭─ ");
    try wr.writeAll(ANSI_RESET ++ ANSI_BOLD);
    try wr.writeAll(name);
    try wr.writeAll(ANSI_RESET);
    if (pvis > 0) {
        try wr.writeAll(" " ++ ANSI_DIM ++ ANSI_ITALIC ++ "· ");
        try wr.writeAll(preview);
        if (cut) try wr.writeAll("…");
        try wr.writeAll(ANSI_RESET);
    }
    try wr.writeAll(border);
    try wr.writeByte(' ');
    var f = fill;
    while (f > 1) : (f -= 1) try wr.writeAll("─");
    try wr.writeAll("─ ");
    try wr.writeAll(ANSI_RESET);
    try wr.writeAll(status);
    try wr.writeAll(border);
    try wr.writeAll(" ─╮" ++ ANSI_RESET);
}

/// 底边:`╰─ Wall 0.4s · 8ln ─╯`(meta dim,虚线补满)。
fn paintBoxBottom(buf: []u8, meta: ToolMeta, box_w: usize, now_ms: i64) []const u8 {
    var wr = std.Io.Writer.fixed(buf);
    paintBoxBottomInto(&wr, meta, box_w, now_ms) catch return "╰";
    return wr.buffered();
}

fn paintBoxBottomInto(wr: *std.Io.Writer, meta: ToolMeta, box_w: usize, now_ms: i64) !void {
    const border = toolBorderInk(meta.status);
    var eb: [24]u8 = undefined;
    const et = activity.formatElapsed(&eb, toolElapsedMs(meta, now_ms));
    var mb: [48]u8 = undefined;
    const mtext = std.fmt.bufPrint(&mb, "Wall {s} · {d}ln", .{ et, meta.lines }) catch "Wall ?";
    const mvis = visibleCols(mtext);
    const fill = box_w -| 6 -| mvis; // ╰─ (3) + meta + 「 ─」(2) + ╯(1)
    try wr.writeAll(border);
    try wr.writeAll("╰─ ");
    try wr.writeAll(ANSI_RESET ++ ANSI_DIM);
    try wr.writeAll(mtext);
    try wr.writeAll(ANSI_RESET);
    try wr.writeAll(border);
    try wr.writeAll(" ─");
    var f = fill -| 1; // 「 ─」已写 1 根
    while (f > 0) : (f -= 1) try wr.writeAll("─");
    try wr.writeAll("╯" ++ ANSI_RESET);
}

/// 整框行(顶/底边)落屏:可见宽 box_w,band 非空时补白至屏宽(色带达屏缘)。
fn emitBoxFrame(wr: *std.Io.Writer, band: []const u8, row: []const u8, width: usize, skipped: *usize, emitted: *usize, limit: usize) !void {
    if (emitted.* >= limit) return;
    if (skipped.* > 0) {
        skipped.* -= 1;
        return;
    }
    if (band.len > 0) try wr.writeAll(band);
    try wr.writeAll(row);
    try wr.writeAll(ANSI_RESET);
    if (band.len > 0) {
        var p = visibleCols(row);
        while (p < width) : (p += 1) try wr.writeByte(' ');
    }
    try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
    emitted.* += 1;
}

/// 正文一行(已按 inner 折好的一个 chunk):`│ chunk…pad │`,
/// reband = band+ink,chunk 内部 RESET 后复披(todo 换形行尾自带 RESET)。
fn writeBoxBodyRow(wr: *std.Io.Writer, border: []const u8, reband: []const u8, band: []const u8, chunk: []const u8, cols: usize, inner: usize, width: usize, box_w: usize) !void {
    if (band.len > 0) try wr.writeAll(band);
    try wr.writeAll(border);
    try wr.writeAll("│ ");
    try wr.writeAll(ANSI_RESET);
    if (reband.len > 0) try wr.writeAll(reband);
    try writeReband(wr, chunk, reband);
    try wr.writeAll(ANSI_RESET);
    if (band.len > 0) try wr.writeAll(band);
    var p = cols;
    while (p < inner) : (p += 1) try wr.writeByte(' ');
    try wr.writeAll(border);
    try wr.writeAll(" │" ++ ANSI_RESET);
    if (band.len > 0) {
        var q = box_w;
        while (q < width) : (q += 1) try wr.writeByte(' ');
    }
    try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
}

/// emitWrappedGutter 的 boxed 版:软折规则一致(同 wrapRowCount),每行收右边框。
fn emitBoxWrapped(wr: *std.Io.Writer, border: []const u8, ink: []const u8, band: []const u8, line: []const u8, inner: usize, width: usize, box_w: usize, skip: usize, limit: usize) !usize {
    if (limit == 0) return 0;
    const w = @max(inner, 1);
    var emitted: usize = 0;
    var skipped: usize = 0;
    var cols: usize = 0;
    var row_from: usize = 0;
    var i: usize = 0;
    var rb_buf: [64]u8 = undefined;
    var reband: []const u8 = ink;
    if (band.len > 0 and band.len + ink.len <= rb_buf.len) {
        @memcpy(rb_buf[0..band.len], band);
        @memcpy(rb_buf[band.len..][0..ink.len], ink);
        reband = rb_buf[0 .. band.len + ink.len];
    }
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
                try writeBoxBodyRow(wr, border, reband, band, line[row_from..i], cols, w, width, box_w);
                emitted += 1;
                if (emitted == limit) return emitted;
            }
            row_from = i;
            cols = 0;
        }
        cols += ch.cols;
        i += ch.n;
    }
    if (skipped < skip) return emitted;
    try writeBoxBodyRow(wr, border, reband, band, line[row_from..line.len], cols, w, width, box_w);
    return emitted + 1;
}

/// boxed 展开卡:╭─ 顶边 / │ 正文 │(超 20 行截断)/ ╰─ 底边。
fn emitToolBoxed(wr: *std.Io.Writer, meta: ToolMeta, width: usize, skip: usize, limit: usize) !usize {
    if (limit == 0) return 0;
    var skipped = skip;
    var emitted: usize = 0;
    const now = nowMs();
    const box_w = toolBoxWidth(width);
    const inner = toolBoxInner(box_w);
    const band = theme().bgTool(paintStatus(meta.status));
    const border = toolBorderInk(meta.status);
    {
        var top_buf: [4096]u8 = undefined;
        const top = paintBoxTop(&top_buf, meta, box_w, now);
        try emitBoxFrame(wr, band, top, width, &skipped, &emitted, limit);
    }
    const view = bodyView(meta.body.items);
    if (view.len > 0) {
        const n = countContentLines(view);
        const body_ink: []const u8 = if (meta.status == .err) theme().fg_err else theme().fg_output;
        const todo = isTodoTool(meta);
        var it = std.mem.splitScalar(u8, view, '\n');
        var i: usize = 0;
        while (it.next()) |part| {
            if (emitted >= limit) break;
            i += 1;
            if (n > TOOL_BOX_BODY_MAX and i == TOOL_BOX_BODY_MAX) {
                // 截断尾行:`… (N more lines)`(dim)
                var tail_buf: [64]u8 = undefined;
                const tail = std.fmt.bufPrint(&tail_buf, "… ({d} more lines)", .{n - TOOL_BOX_BODY_MAX + 1}) catch "… (more lines)";
                if (skipped > 0) {
                    skipped -= 1;
                } else {
                    try writeBoxBodyRow(wr, border, ANSI_DIM, band, tail, visibleCols(tail), inner, width, box_w);
                    emitted += 1;
                }
                break;
            }
            var tb2: [SAN_TODO]u8 = undefined;
            const line: []const u8 = if (todo) todoLine(part, &tb2) else part;
            const nrows = wrapRowCount(line, inner);
            if (skipped >= nrows) {
                skipped -= nrows;
                continue;
            }
            const local = skipped;
            skipped = 0;
            emitted += try emitBoxWrapped(wr, border, body_ink, band, line, inner, width, box_w, local, limit - emitted);
        }
    }
    {
        var bot_buf: [2048]u8 = undefined;
        const bot = paintBoxBottom(&bot_buf, meta, box_w, now);
        try emitBoxFrame(wr, band, bot, width, &skipped, &emitted, limit);
    }
    return emitted;
}

fn emitTool(wr: *std.Io.Writer, meta: ToolMeta, width: usize, skip: usize, limit: usize) !usize {
    if (isWorkflowTool(meta)) return emitFlow(wr, meta, width, skip, limit);
    if (limit == 0) return 0;
    if (toolBoxed(meta, width)) return emitToolBoxed(wr, meta, width, skip, limit);
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
            const todo = isTodoTool(meta);
            var i: usize = 0;
            while (it.next()) |part| {
                i += 1;
                const first = if (i == nlines) TOOL_BODY_LAST else TOOL_BODY_FIRST;
                var tb2: [SAN_TODO]u8 = undefined;
                const line: []const u8 = if (todo) todoLine(part, &tb2) else part;
                try emitPrefixed(wr, first, TOOL_BODY_REST, line, inner, &skipped, &emitted, limit, body_ink);
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
        if (line[i] == '\n') { // 硬断:多行草稿(Alt+Enter/bracketed paste)
            rows += 1;
            cols = 0;
            i += 1;
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
        const fold = std.fmt.bufPrint(&fold_buf, "{s}{s}    ┆ thought · [Ctrl+T]{s}", .{ theme().fg_think, ANSI_ITALIC, ANSI_RESET }) catch "    ┆ thought · [Ctrl+T]";
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
        if (s[i] == '\n') { // 硬断;cursor 停在 \n 上 = 上一行尾,不往下推
            row += 1;
            cols = 0;
            i += 1;
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
        if (input[i] == '\n') { // 硬断:换行符本身不上屏,空行也占一行
            if (row_i >= skip) {
                try writeComposerRow(wr, if (row_i == 0) first else rest, input[row_from..i], if (inner > cols) inner - cols else 0);
                emitted += 1;
                if (emitted == rows) return;
            }
            row_i += 1;
            i += 1;
            row_from = i;
            cols = 0;
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
    // th 是栈变量,测试结束即销毁;theme_ptr 不得挂空(后续测试读 theme 会踩
    // 死栈:垃圾 ink 长度把 formatToolStatus 的 bufPrint 撑爆,s3 只剩 "ok")。
    attachTheme(&fallback_theme);
}

/// 多行草稿内纵向移动:同列(显示格)移到上/下一可视行;行短则钉行尾。
/// delta ±1;超界返回原 cursor。软绕行与硬换行同法。
pub fn wrapMoveVertical(s: []const u8, cursor: usize, width: usize, delta: isize) usize {
    const w = @max(width, 1);
    const cur = wrapCursor(s, cursor, w);
    const target: usize = if (delta < 0) cur.row -| @as(usize, @intCast(-delta)) else cur.row + @as(usize, @intCast(delta));
    if (target == cur.row) return cursor;
    var row: usize = 0;
    var cols: usize = 0;
    var i: usize = 0;
    while (i <= s.len) {
        if (row == target) {
            if (cols >= cur.col) return i;
            if (i >= s.len) return s.len;
            if (s[i] == '\n') return i; // 钉行尾
            const ch = charCols(s, i);
            if (cols > 0 and cols + ch.cols > w) return i; // 本可视行尽
            cols += ch.cols;
            i += ch.n;
            continue;
        }
        if (i >= s.len) return s.len;
        if (s[i] == '\n') {
            row += 1;
            cols = 0;
            i += 1;
            continue;
        }
        const ch = charCols(s, i);
        if (cols > 0 and cols + ch.cols > w) {
            row += 1;
            cols = 0;
            continue; // 软绕不消耗 i
        }
        cols += ch.cols;
        i += ch.n;
    }
    return s.len;
}

test "wrap hard-breaks on newline (multiline composer)" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 2), wrapRowCount("ab\ncd", 80));
    try t.expectEqual(@as(usize, 3), wrapRowCount("a\n\nb", 80)); // 空行也占行
    try t.expectEqual(@as(usize, 2), wrapRowCount("ab\n", 80)); // 尾换行 = 新空行
    const cur = wrapCursor("ab\ncd", 3, 80);
    try t.expectEqual(@as(usize, 1), cur.row);
    try t.expectEqual(@as(usize, 0), cur.col);
    const on_nl = wrapCursor("ab\ncd", 2, 80);
    try t.expectEqual(@as(usize, 0), on_nl.row); // 停在 \n 上 = 上行尾
    try t.expectEqual(@as(usize, 2), on_nl.col);
    // 窄宽硬断优先于软绕:"ab\ncdefgh" w=3 → ab / cde / fgh = 3
    try t.expectEqual(@as(usize, 3), wrapRowCount("ab\ncdefgh", 3));
}

test "wrapMoveVertical: 同列跨行/钉行尾/超界不动" {
    const t = std.testing;
    const s = "ab\ncdef\ng";
    // 行1 col1(idx 4) → 行0 col1 = idx 1
    try t.expectEqual(@as(usize, 1), wrapMoveVertical(s, 4, 80, -1));
    // 行0 col1(idx 1) → 行1 col1 = idx 4
    try t.expectEqual(@as(usize, 4), wrapMoveVertical(s, 1, 80, 1));
    // 行1 col3(idx 6) → 行2 只有 1 字符 → 钉行尾 = 'g' 之后 = s.len
    try t.expectEqual(s.len, wrapMoveVertical(s, 6, 80, 1));
    // 顶行再上 → 原处
    try t.expectEqual(@as(usize, 1), wrapMoveVertical(s, 1, 80, -1));
    // 底行再下 → 文末
    try t.expectEqual(s.len, wrapMoveVertical(s, 7, 80, 1));
    // 中间行短行: "ab\nx\ncd" 行0 col1(idx1) ↓ → 行1 col1 = 'x' 之后 idx 4
    try t.expectEqual(@as(usize, 4), wrapMoveVertical("ab\nx\ncd", 1, 80, 1));
    // 软绕行: "abcdef" w=3 → 两行 abC/def;idx 5(行1 col2)↑ → idx 2
    try t.expectEqual(@as(usize, 2), wrapMoveVertical("abcdef", 5, 3, -1));
}

test "emitComposer splits hard lines" {
    const t = std.testing;
    var aw = std.Io.Writer.Allocating.init(t.allocator);
    defer aw.deinit();
    try emitComposer(&aw.writer, "l1\nl2", 20, 2, 0);
    const out = aw.written();
    try t.expect(std.mem.indexOf(u8, out, "l1") != null);
    try t.expect(std.mem.indexOf(u8, out, "l2") != null);
    // skip=1 只见第二行
    var aw2 = std.Io.Writer.Allocating.init(t.allocator);
    defer aw2.deinit();
    try emitComposer(&aw2.writer, "l1\nl2", 20, 1, 1);
    try t.expect(std.mem.indexOf(u8, aw2.written(), "l1") == null);
    try t.expect(std.mem.indexOf(u8, aw2.written(), "l2") != null);
}

test "formatToolStatus: running spinner vs settled" {
    const t = std.testing;
    const el: []u8 = &.{};
    const body = std.array_list.Managed(u8).init(t.allocator);
    defer body.deinit();
    const running = ToolMeta{ .name = el, .preview = el, .status = .running, .start_ms = 123000, .bytes = 0, .lines = 0, .elapsed_ms = 0, .folded = true, .body = body };
    var b1: [64]u8 = undefined;
    // 同一毫秒戳 → 同一帧;不同戳 → 帧在变(⠋ 族)
    const s1 = formatToolStatus(&b1, running, 123900, 123900);
    try t.expect(std.mem.indexOf(u8, s1, "running") != null);
    try t.expect(std.mem.indexOf(u8, s1, "0.9s") != null);
    const frame1 = s1[0..3];
    var b2: [64]u8 = undefined;
    const s2 = formatToolStatus(&b2, running, 124000, 124000);
    try t.expect(!std.mem.eql(u8, frame1, s2[0..3]));
    const settled = ToolMeta{ .name = el, .preview = el, .status = .ok, .bytes = 0, .lines = 5, .elapsed_ms = 100, .folded = true, .body = body };
    var b3: [64]u8 = undefined;
    const s3 = formatToolStatus(&b3, settled, 0, 0);
    try t.expect(std.mem.indexOf(u8, s3, "ok") != null);
    try t.expect(std.mem.indexOf(u8, s3, "0.1s") != null);
    try t.expect(std.mem.indexOf(u8, s3, "5ln") != null);
}
