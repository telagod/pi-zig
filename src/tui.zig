// tui.zig — layered Codex/Claude layout, Zig + ANSI.
//
// Three stacked systems, painted as different weights — not one bullet:
//   A. Chrome: working (dim, ephemeral) / boxed composer / footer under it.
//      Footer packs into one row when it fits (typical width ≥ ~100): model
//      bold, think/ctx/cache labels dim + numbers normal, cwd · session, hint
//      dimmest. Overflow splits: row 1 metrics, row 2 cwd · session + hint.
//      Collapse drops hint → think → cache label → ctx abs → session before
//      cwd. Model is never dropped; cwd is truncated, not omitted.
//   B. Status card: on-demand via /status only — never cell 0 at startup.
//   C. Turn blocks (paint-time, never baked into cell text):
//        user      indent 0, bold, bar ▎ + semantic bg band to screen edge
//                  (theme.userMessageBg, pi-aligned)
//        thought   indent 2, dim italic (Ctrl+T → one `· thought` line)
//        assistant indent 2, normal, no bar; siblings merge
//        tools     indent 4, ▸ bold name + dim preview + status on one line;
//                  title row bg by status (pending/ok/err, pi-aligned); folded
//                  body head + dim `· (N more lines, ctrl+o)` tail
//                  expanded body indent 6 │ / last └
//      One blank between top-level blocks; zero inside a tool group.
//
// A tool is one cell. Folded paint is one tight line; Ctrl+O expands the
// stored body. Slash `/` opens a ranked picker (prefix > fuzzy > desc).
//
// Layout: measure BottomPane first (working + picker + composer + footer),
// transcript gets the remaining rows, pin-to-bottom scroll.
//
// Proven pieces kept: raw mode, alt screen, emergency SIGTERM restore,
// UTF-8 edit, CSI scroll, picker, history file, slash-command keys.
// Mouse: Codex `tui.rs` enter_alt_screen enables 1007 (alternate scroll)
// only — never 1000/1006 button tracking, which steals native drag-select.
const std = @import("std");
const util = @import("core").util;
const activity = @import("core").activity;
const ai = @import("core").ai;
const cfgmod = @import("core").config;

const ANSI_RESET = "\x1b[0m";
const ANSI_BOLD = "\x1b[1m";
const ANSI_DIM = "\x1b[2m";
const ANSI_REV = "\x1b[7m";
const ANSI_ITALIC = "\x1b[3m";

const theme_mod = @import("theme.zig");
const markdown = @import("markdown.zig");
pub const Theme = theme_mod.Theme;
pub const ColorMode = theme_mod.ColorMode;

/// 全局主题。main 启动 /theme 调用 applyTheme;测试默认 dark+256。
pub var theme: Theme = .{};

pub fn applyTheme(name: []const u8) void {
    theme = Theme.resolve(name);
}

/// Codex EnableAlternateScroll — wheel → arrows, drag-select stays native.
const ENTER_ALT_SCROLL = "\x1b[?1007h";
const LEAVE_ALT_SCROLL = "\x1b[?1007l";

/// Codex session header 内宽上限。见 history_cell.rs SESSION_HEADER_MAX_INNER_WIDTH。
pub const CARD_MAX_INNER: usize = 56;

pub const CellKind = enum {
    session_header,
    status_card,
    user,
    think,
    assistant,
    tool,
    tool_end,
    chrome,
};

pub const ToolStatus = enum { running, ok, err };

/// Structured tool turn. Body is stored always; painted only when unfolded.
pub const ToolMeta = struct {
    name: []u8,
    preview: []u8,
    status: ToolStatus = .running,
    bytes: usize = 0,
    lines: usize = 0,
    start_ms: i64 = 0,
    elapsed_ms: i64 = 0,
    folded: bool = true,
    body: std.array_list.Managed(u8),

    fn deinit(self: *ToolMeta, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.preview);
        self.body.deinit();
    }
};

/// One transcript item. `text` never contains paint-time gutters or indent.
pub const Cell = struct {
    kind: CellKind,
    text: std.array_list.Managed(u8),
    color: []const u8 = "",
    card: ?CardFields = null,
    tool: ?ToolMeta = null,
};

pub const CardFields = struct {
    version: []u8,
    model: []u8,
    think: []u8,
    cwd: []u8,
    session: []u8,
    perms: []u8 = &.{},
    context: []u8 = &.{},
    usage: []u8 = &.{},

    fn deinit(self: CardFields, alloc: std.mem.Allocator) void {
        alloc.free(self.version);
        alloc.free(self.model);
        alloc.free(self.think);
        alloc.free(self.cwd);
        alloc.free(self.session);
        alloc.free(self.perms);
        alloc.free(self.context);
        alloc.free(self.usage);
    }
};

pub const SessionInfo = struct {
    version: []const u8,
    model: []const u8,
    think: []const u8,
    cwd: []const u8,
    session: []const u8,
};

pub const StatusInfo = struct {
    version: []const u8,
    model: []const u8,
    think: []const u8,
    cwd: []const u8,
    session: []const u8,
    perms: []const u8,
    context: []const u8,
    usage: []const u8,
};

/// 选择器一行。label 是看见的,value 是确认后拼进斜杠命令的参数。
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

fn indexOfInsensitive(hay: []const u8, needle: []const u8) ?usize {
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

fn slashDisplayRows(input: []const u8, items: []const SlashItem, height: usize) usize {
    const q = slashQuery(input) orelse return 0;
    var ranks: [64]SlashRank = undefined;
    const n = rankSlash(items, q, &ranks);
    if (n == 0) return 0;
    return @min(n, @max(1, height / 3));
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

    /// 标题 + 可见选项行数。选项最多占屏幕三分之一。
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

/// 页脚状态。Codex:瞬时指令盖过环境;空闲空框才出 `? for shortcuts`。
pub const FooterState = struct {
    perm: bool = false,
    picker: bool = false,
    slash: bool = false,
    quit_armed: bool = false,
    esc_armed: bool = false,
    scrolled: bool = false,
    shortcuts: bool = false,
    has_draft: bool = false,
    running: bool = false,
};

/// 底栏左侧提示。perm > picker > slash > quit > esc > shortcuts > scrolled > queue > idle。
pub fn footerHint(s: FooterState) ?[]const u8 {
    if (s.perm) return "y allow  n deny  a always  s skip";
    if (s.picker) return "up/down select  enter confirm  esc cancel";
    if (s.slash) return "up/down select  tab complete  enter run";
    if (s.quit_armed) return "ctrl+c again to quit";
    if (s.esc_armed) return "esc again to edit last";
    if (s.shortcuts) return "? hide shortcuts";
    if (s.scrolled) return "pgup/pgdn to scroll";
    if (s.running and s.has_draft) return "tab to queue";
    if (!s.has_draft) return "? for shortcuts";
    return null;
}

/// Structured footer identity. Painted under the composer, not as a transcript card.
/// `used`/`window` are occupancy (est. tokens in the live context / model window).
/// `cache_read`/`prompt` are last-turn API usage — null means the provider did
/// not report that field. Never invent a hit rate from missing numbers.
pub const FooterIdent = struct {
    model: []const u8 = "",
    think: []const u8 = "",
    cwd: []const u8 = "",
    branch: []const u8 = "",
    session: []const u8 = "",
    /// 会话分项累计(pi 式 ↑↓ R W)
    tok_in: u64 = 0,
    tok_out: u64 = 0,
    tok_cache_w: u64 = 0,
    tok_cache_r: u64 = 0,
    /// 会话累计费用;null 不显 $(pi:仅 cost>0 或订阅显)
    cost: ?f64 = null,
    /// 订阅制 provider(pi 式 (sub) 后缀)
    subscription: bool = false,
    used: usize = 0,
    window: usize = 0,
    cache_read: ?u64 = null,
    prompt: ?u64 = null,
    pct: usize = 0,
    hot: bool = false,
};

pub const FooterRows = struct {
    primary: []u8,
    secondary: []u8,

    pub fn deinit(self: FooterRows, alloc: std.mem.Allocator) void {
        alloc.free(self.primary);
        alloc.free(self.secondary);
    }
};

/// pi 式双行阈值:宽 >= 50 恒双行(行1 cwd (branch),行2 stats/model)。
/// 窄端退化单行挤排,由 formatFooterRows 内 fitSingle 处置。
pub fn footerNeedsTwoRows(ident: FooterIdent, hint: ?[]const u8, width: usize) bool {
    _ = ident;
    _ = hint;
    return width >= 50;
}

/// pi 式双行:行 1 `cwd (branch)` muted,hint 右端 dimmest;
/// 行 2 左 stats(ctx% 随占用变色、R cache),右 `model · think`。
fn formatFooterPi(alloc: std.mem.Allocator, ident: FooterIdent, hint: ?[]const u8, width: usize) !FooterRows {
    const mu = theme.muted();
    const place = if (ident.branch.len > 0)
        try std.fmt.allocPrint(alloc, "{s}{s} ({s}){s}", .{ mu, ident.cwd, ident.branch, ANSI_RESET })
    else
        try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ mu, ident.cwd, ANSI_RESET });
    defer alloc.free(place);
    var row1: []u8 = undefined;
    if (hint) |h| {
        const hint_s = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ ANSI_DIM, h, ANSI_RESET });
        defer alloc.free(hint_s);
        row1 = try layoutFooter(alloc, place, hint_s, width);
    } else {
        row1 = try alloc.dupe(u8, truncateToVisible(place, width));
    }

    var used_buf: [16]u8 = undefined;
    var win_buf: [16]u8 = undefined;
    const pct_ink = theme.fgCtx(ident.pct);
    const pct_end: []const u8 = if (pct_ink.len > 0) ANSI_RESET else "";
    var in_buf: [16]u8 = undefined;
    var out_buf: [16]u8 = undefined;
    var cr_buf: [16]u8 = undefined;
    var cw_buf: [16]u8 = undefined;
    // pi 式 stats:↑in ↓out [R cache] [W cache] + ctx 占用
    var flow: ?[]u8 = null;
    defer if (flow) |f| alloc.free(f);
    if (ident.tok_in > 0 or ident.tok_out > 0) {
        flow = try std.fmt.allocPrint(alloc, "↑{s} ↓{s}", .{ formatTok(&in_buf, ident.tok_in), formatTok(&out_buf, ident.tok_out) });
    }
    var cache: ?[]u8 = null;
    defer if (cache) |c| alloc.free(c);
    if (ident.tok_cache_r > 0 and ident.tok_cache_w > 0) {
        cache = try std.fmt.allocPrint(alloc, " R{s} W{s}", .{ formatTok(&cr_buf, ident.tok_cache_r), formatTok(&cw_buf, ident.tok_cache_w) });
    } else if (ident.tok_cache_r > 0) {
        cache = try std.fmt.allocPrint(alloc, " R{s}", .{formatTok(&cr_buf, ident.tok_cache_r)});
    } else if (ident.tok_cache_w > 0) {
        cache = try std.fmt.allocPrint(alloc, " W{s}", .{formatTok(&cw_buf, ident.tok_cache_w)});
    }
    // CH% 命中率(末轮 cache_read/prompt,pi 式);$ 费用(toFixed(3) 式三位)
    var ch: ?[]u8 = null;
    defer if (ch) |c| alloc.free(c);
    if (ident.cache_read) |cr| {
        if (ident.prompt) |pr| {
            if (cr > 0 and pr > 0) ch = try std.fmt.allocPrint(alloc, " CH{d}%", .{cr * 100 / pr});
        }
    }
    var cost_s: ?[]u8 = null;
    defer if (cost_s) |c| alloc.free(c);
    // pi 式:cost>0 或订阅皆显 $;订阅缀 (sub)
    if (ident.cost != null or ident.subscription) {
        const sub_suffix: []const u8 = if (ident.subscription) " (sub)" else "";
        cost_s = try std.fmt.allocPrint(alloc, " ${d:.3}{s}", .{ ident.cost orelse 0, sub_suffix });
    }
    const extra = flow != null or cache != null or ch != null or cost_s != null;
    const stats = if (extra)
        try std.fmt.allocPrint(alloc, "{s}{s}{s}{s}  {s}ctx {s}{s}{d}%{s} {s}/{s}", .{ flow orelse "", cache orelse "", ch orelse "", cost_s orelse "", ANSI_DIM, ANSI_RESET, pct_ink, ident.pct, pct_end, formatTok(&used_buf, ident.used), formatTok(&win_buf, ident.window) })
    else
        try std.fmt.allocPrint(alloc, "{s}ctx {s}{s}{d}%{s} {s}/{s}", .{ ANSI_DIM, ANSI_RESET, pct_ink, ident.pct, pct_end, formatTok(&used_buf, ident.used), formatTok(&win_buf, ident.window) });
    defer alloc.free(stats);
    const right = if (ident.think.len > 0)
        try std.fmt.allocPrint(alloc, "{s}{s}{s}{s} · {s}", .{ ANSI_BOLD, ident.model, ANSI_RESET, ANSI_DIM, ident.think })
    else
        try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ ANSI_BOLD, ident.model, ANSI_RESET });
    defer alloc.free(right);
    const row2 = try layoutFooter(alloc, stats, right, width);
    return .{ .primary = row1, .secondary = row2 };
}

/// Pack footer facts with single spaces. Prefer one row; split when
/// `two_rows` is set *and* the full pack overflows (cwd · session on row 2).
/// Collapse when forced onto one row: hint, think, cache label, ctx absolute,
/// session; cwd last. Model is never dropped. Below ~40 cols, ellipsize cwd
/// rather than omit it. Labels dim, numbers normal, model bold, hint dimmest.
pub fn formatFooterRows(alloc: std.mem.Allocator, ident: FooterIdent, hint: ?[]const u8, width: usize, two_rows: bool) !FooterRows {
    const hint_s = if (hint) |h|
        try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ ANSI_DIM, h, ANSI_RESET })
    else
        try alloc.dupe(u8, "");
    defer alloc.free(hint_s);
    const model_s = if (ident.model.len == 0)
        try alloc.dupe(u8, "")
    else
        try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ ANSI_BOLD, ident.model, ANSI_RESET });
    defer alloc.free(model_s);
    const think_s = if (ident.think.len == 0)
        try alloc.dupe(u8, "")
    else
        try std.fmt.allocPrint(alloc, "{s}think {s}{s}", .{ ANSI_DIM, ANSI_RESET, ident.think });
    defer alloc.free(think_s);
    const ink: []const u8 = if (ident.hot) "\x1b[31m" else "";
    const ink_end: []const u8 = if (ident.hot) ANSI_RESET else "";
    var ctx_full_buf: [48]u8 = undefined;
    var ctx_pct_buf: [48]u8 = undefined;
    const ctx_full_raw = formatCtx(&ctx_full_buf, ident.used, ident.window, true);
    const ctx_pct_raw = formatCtx(&ctx_pct_buf, ident.used, ident.window, false);
    const ctx_full_nums = if (std.mem.startsWith(u8, ctx_full_raw, "ctx ")) ctx_full_raw[4..] else ctx_full_raw;
    const ctx_pct_nums = if (std.mem.startsWith(u8, ctx_pct_raw, "ctx ")) ctx_pct_raw[4..] else ctx_pct_raw;
    const ctx_full = try std.fmt.allocPrint(alloc, "{s}ctx {s}{s}{s}{s}", .{ ANSI_DIM, ANSI_RESET, ink, ctx_full_nums, ink_end });
    defer alloc.free(ctx_full);
    const ctx_pct = try std.fmt.allocPrint(alloc, "{s}ctx {s}{s}{s}{s}", .{ ANSI_DIM, ANSI_RESET, ink, ctx_pct_nums, ink_end });
    defer alloc.free(ctx_pct);
    var cache_full_buf: [32]u8 = undefined;
    var cache_num_buf: [32]u8 = undefined;
    const cache_full_raw = formatCache(&cache_full_buf, ident.cache_read, ident.prompt, true);
    const cache_num_raw = formatCache(&cache_num_buf, ident.cache_read, ident.prompt, false);
    const cache_full = try styleCacheToken(alloc, cache_full_raw);
    defer alloc.free(cache_full);
    const cache_num = try alloc.dupe(u8, cache_num_raw);
    defer alloc.free(cache_num);
    const place_full = try formatPlace(alloc, ident.cwd, ident.session);
    defer alloc.free(place_full);
    const place_cwd = try formatPlace(alloc, ident.cwd, "");
    defer alloc.free(place_cwd);

    const split = two_rows and footerNeedsTwoRows(ident, hint, width);
    if (split) return formatFooterPi(alloc, ident, hint, width);
    const primary = try fitSingle(alloc, model_s, think_s, ctx_full, ctx_pct, cache_full, cache_num, place_full, place_cwd, ident.cwd, hint_s, width);
    return .{ .primary = primary, .secondary = try alloc.dupe(u8, "") };
}

fn styleCacheToken(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, raw, "cached "))
        return std.fmt.allocPrint(alloc, "{s}cached {s}{s}", .{ ANSI_DIM, ANSI_RESET, raw[7..] });
    if (std.mem.startsWith(u8, raw, "cache "))
        return std.fmt.allocPrint(alloc, "{s}cache {s}{s}", .{ ANSI_DIM, ANSI_RESET, raw[6..] });
    return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ ANSI_DIM, raw, ANSI_RESET });
}

/// Compact token count for the footer (`1.2k`, `128k`, `1M`).
pub fn formatTok(buf: *[16]u8, n: u64) []const u8 {
    if (n >= 1_000_000) {
        const m = n / 1_000_000;
        const frac = (n % 1_000_000) / 100_000;
        if (frac == 0) return std.fmt.bufPrint(buf, "{d}M", .{m}) catch "?";
        return std.fmt.bufPrint(buf, "{d}.{d}M", .{ m, frac }) catch "?";
    }
    if (n >= 1000) {
        const k = n / 1000;
        const frac = (n % 1000) / 100;
        if (frac == 0) return std.fmt.bufPrint(buf, "{d}k", .{k}) catch "?";
        return std.fmt.bufPrint(buf, "{d}.{d}k", .{ k, frac }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch "?";
}

/// Context occupancy. `window == 0` means the model window is unknown.
pub fn formatCtx(buf: *[48]u8, used: usize, window: usize, with_abs: bool) []const u8 {
    if (window == 0) return "ctx —";
    const pct = used * 100 / window;
    if (!with_abs) return std.fmt.bufPrint(buf, "ctx {d}%", .{pct}) catch "ctx —";
    var ub: [16]u8 = undefined;
    var wb: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "ctx {s}/{s} {d}%", .{
        formatTok(&ub, used),
        formatTok(&wb, window),
        pct,
    }) catch "ctx —";
}

/// Last-turn cache. `cache_read == null` is unknown (`cache —`), not 0%.
/// Hit rate is `cache_read / prompt` when both arrived from the API.
pub fn formatCache(buf: *[32]u8, cache_read: ?u64, prompt: ?u64, labeled: bool) []const u8 {
    if (cache_read) |cr| {
        if (prompt) |p| {
            if (p > 0) {
                const pct = cr * 100 / p;
                if (labeled) return std.fmt.bufPrint(buf, "cache {d}%", .{pct}) catch "cache —";
                return std.fmt.bufPrint(buf, "{d}%", .{pct}) catch "—";
            }
        }
        if (cr > 0) {
            var tb: [16]u8 = undefined;
            const t = formatTok(&tb, cr);
            if (labeled) return std.fmt.bufPrint(buf, "cached {s}", .{t}) catch "cache —";
            return std.fmt.bufPrint(buf, "{s}", .{t}) catch "—";
        }
        if (labeled) return "cache 0%";
        return "0%";
    }
    if (labeled) return "cache —";
    return "—";
}

fn formatPlace(alloc: std.mem.Allocator, cwd: []const u8, session: []const u8) ![]u8 {
    if (cwd.len > 0 and session.len > 0)
        return std.fmt.allocPrint(alloc, "{s}{s} · {s}{s}", .{ ANSI_DIM, cwd, session, ANSI_RESET });
    if (session.len > 0)
        return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ ANSI_DIM, session, ANSI_RESET });
    if (cwd.len > 0)
        return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ ANSI_DIM, cwd, ANSI_RESET });
    return alloc.dupe(u8, "");
}

fn joinPacked(alloc: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var buf: [12][]const u8 = undefined;
    var n: usize = 0;
    for (parts) |p| {
        if (p.len == 0) continue;
        if (n >= buf.len) break;
        buf[n] = p;
        n += 1;
    }
    return joinN(alloc, buf[0..n], " ");
}

fn fitPrimary(
    alloc: std.mem.Allocator,
    model_s: []const u8,
    think_s: []const u8,
    ctx_full: []const u8,
    ctx_pct: []const u8,
    cache_full: []const u8,
    cache_num: []const u8,
    width: usize,
) ![]u8 {
    const variants = [_][]const []const u8{
        &.{ model_s, think_s, ctx_full, cache_full },
        &.{ model_s, ctx_full, cache_full },
        &.{ model_s, ctx_full, cache_num },
        &.{ model_s, ctx_pct, cache_num },
        &.{ model_s, ctx_pct },
        &.{model_s},
    };
    for (variants) |parts| {
        const joined = try joinPacked(alloc, parts);
        if (visibleCols(joined) <= width) return joined;
        alloc.free(joined);
    }
    return alloc.dupe(u8, truncateToVisible(model_s, width));
}

fn fitSecondary(alloc: std.mem.Allocator, cwd: []const u8, session: []const u8, hint: []const u8, width: usize) ![]u8 {
    const place_full = try formatPlace(alloc, cwd, session);
    defer alloc.free(place_full);
    const place_cwd = try formatPlace(alloc, cwd, "");
    defer alloc.free(place_cwd);
    const variants = [_][]const []const u8{
        &.{ place_full, hint },
        &.{place_full},
        &.{ place_cwd, hint },
        &.{place_cwd},
    };
    for (variants) |parts| {
        const joined = try joinPacked(alloc, parts);
        if (visibleCols(joined) <= width) return joined;
        alloc.free(joined);
    }
    if (cwd.len > 0 and width > 0) {
        const short = try ellipsizeAlloc(alloc, cwd, width);
        defer alloc.free(short);
        return formatPlace(alloc, short, "");
    }
    if (hint.len > 0) return alloc.dupe(u8, truncateToVisible(hint, width));
    return alloc.dupe(u8, "");
}

fn fitSingle(
    alloc: std.mem.Allocator,
    model_s: []const u8,
    think_s: []const u8,
    ctx_full: []const u8,
    ctx_pct: []const u8,
    cache_full: []const u8,
    cache_num: []const u8,
    place_full: []const u8,
    place_cwd: []const u8,
    cwd: []const u8,
    hint: []const u8,
    width: usize,
) ![]u8 {
    const variants = [_][]const []const u8{
        &.{ model_s, think_s, ctx_full, cache_full, place_full, hint },
        &.{ model_s, think_s, ctx_full, cache_full, place_full },
        &.{ model_s, ctx_full, cache_full, place_full },
        &.{ model_s, ctx_full, cache_num, place_full },
        &.{ model_s, ctx_pct, cache_num, place_full },
        &.{ model_s, ctx_pct, cache_num, place_cwd },
        &.{ model_s, ctx_pct, place_cwd },
        &.{ model_s, place_cwd },
    };
    for (variants) |parts| {
        const joined = try joinPacked(alloc, parts);
        if (visibleCols(joined) <= width) return joined;
        alloc.free(joined);
    }
    if (cwd.len > 0) {
        const model_cols = visibleCols(model_s);
        const gap: usize = if (model_cols > 0) 1 else 0;
        if (model_cols + gap < width) {
            const short = try ellipsizeAlloc(alloc, cwd, width - model_cols - gap);
            defer alloc.free(short);
            const placed = try formatPlace(alloc, short, "");
            defer alloc.free(placed);
            const joined = try joinPacked(alloc, &.{ model_s, placed });
            if (visibleCols(joined) <= width) return joined;
            alloc.free(joined);
        } else if (model_cols == 0) {
            const short = try ellipsizeAlloc(alloc, cwd, width);
            defer alloc.free(short);
            return formatPlace(alloc, short, "");
        }
    }
    return fitPrimary(alloc, model_s, think_s, ctx_full, ctx_pct, cache_full, cache_num, width);
}

/// 左提示 + 右上下文,宽不够先丢右边。
pub fn layoutFooter(alloc: std.mem.Allocator, left: ?[]const u8, right: []const u8, width: usize) ![]u8 {
    const l = left orelse "";
    const lw = visibleCols(l);
    const rw = visibleCols(right);
    if (l.len == 0 and right.len == 0) return alloc.dupe(u8, "");
    if (l.len == 0) {
        if (rw >= width) return alloc.dupe(u8, truncateToVisible(right, width));
        const pad = width - rw;
        var out = try alloc.alloc(u8, pad + right.len);
        @memset(out[0..pad], ' ');
        @memcpy(out[pad..], right);
        return out;
    }
    if (right.len == 0 or lw + 2 + rw > width) {
        const cut = truncateToVisible(l, width);
        return alloc.dupe(u8, cut);
    }
    const pad = width - lw - rw;
    var out = try alloc.alloc(u8, l.len + pad + right.len);
    @memcpy(out[0..l.len], l);
    @memset(out[l.len .. l.len + pad], ' ');
    @memcpy(out[l.len + pad ..], right);
    return out;
}

pub fn cardInner(width: usize) usize {
    if (width < 8) return 0;
    return @min(CARD_MAX_INNER, width - 4);
}

/// Codex session / status 卡:内容按 inner 截断,外框跟内容走。
pub fn formatCard(alloc: std.mem.Allocator, lines: []const []const u8, width: usize) ![]u8 {
    const inner = cardInner(width);
    if (inner == 0) {
        var w = std.Io.Writer.Allocating.init(alloc);
        errdefer w.deinit();
        for (lines, 0..) |line, i| {
            if (i > 0) try w.writer.writeByte('\n');
            try w.writer.writeAll(line);
        }
        return w.toOwnedSlice();
    }
    var w = std.Io.Writer.Allocating.init(alloc);
    errdefer w.deinit();
    try writeCardEdge(&w.writer, "╭", "╮", inner);
    for (lines) |line| {
        try w.writer.writeAll(ANSI_DIM ++ "│ " ++ ANSI_RESET);
        const cut = truncateToVisible(line, inner);
        try w.writer.writeAll(cut);
        var pad = inner - visibleCols(cut);
        while (pad > 0) : (pad -= 1) try w.writer.writeByte(' ');
        try w.writer.writeAll(ANSI_DIM ++ " │" ++ ANSI_RESET ++ "\n");
    }
    try writeCardEdge(&w.writer, "╰", "╯", inner);
    const out = try w.toOwnedSlice();
    if (out.len > 0 and out[out.len - 1] == '\n') {
        const trimmed = try alloc.dupe(u8, out[0 .. out.len - 1]);
        alloc.free(out);
        return trimmed;
    }
    return out;
}

const CARD_HINT = ANSI_DIM ++ "/model  /status" ++ ANSI_RESET;

pub fn formatSessionCard(alloc: std.mem.Allocator, info: SessionInfo, width: usize) ![]u8 {
    const title = try std.fmt.allocPrint(alloc, "{s}>_ {s}{s}piz{s}  {s}(v{s}){s}", .{
        ANSI_DIM, ANSI_RESET, ANSI_BOLD, ANSI_RESET, ANSI_DIM, info.version, ANSI_RESET,
    });
    defer alloc.free(title);
    const model = try std.fmt.allocPrint(alloc, "{s}model:      {s}{s}{s}{s}  {s}{s}{s}", .{
        ANSI_DIM, ANSI_RESET, ANSI_BOLD, info.model, ANSI_RESET, ANSI_DIM, info.think, ANSI_RESET,
    });
    defer alloc.free(model);
    const dir = try std.fmt.allocPrint(alloc, "{s}directory:  {s}{s}", .{ ANSI_DIM, info.cwd, ANSI_RESET });
    defer alloc.free(dir);
    const session = try std.fmt.allocPrint(alloc, "{s}session:    {s}{s}", .{ ANSI_DIM, info.session, ANSI_RESET });
    defer alloc.free(session);
    const lines = [_][]const u8{ title, "", model, dir, session, CARD_HINT };
    return formatCard(alloc, &lines, width);
}

pub fn formatStatusCard(alloc: std.mem.Allocator, info: StatusInfo, width: usize) ![]u8 {
    const title = try std.fmt.allocPrint(alloc, "{s}>_ {s}{s}piz{s}  {s}(v{s}){s}", .{
        ANSI_DIM, ANSI_RESET, ANSI_BOLD, ANSI_RESET, ANSI_DIM, info.version, ANSI_RESET,
    });
    defer alloc.free(title);
    const model = try std.fmt.allocPrint(alloc, "{s}model:       {s}{s}{s}{s}  {s}{s}{s}", .{
        ANSI_DIM, ANSI_RESET, ANSI_BOLD, info.model, ANSI_RESET, ANSI_DIM, info.think, ANSI_RESET,
    });
    defer alloc.free(model);
    const dir = try std.fmt.allocPrint(alloc, "{s}directory:   {s}{s}", .{ ANSI_DIM, info.cwd, ANSI_RESET });
    defer alloc.free(dir);
    const session = try std.fmt.allocPrint(alloc, "{s}session:     {s}{s}", .{ ANSI_DIM, info.session, ANSI_RESET });
    defer alloc.free(session);
    const perms = try std.fmt.allocPrint(alloc, "{s}permissions: {s}{s}", .{ ANSI_DIM, info.perms, ANSI_RESET });
    defer alloc.free(perms);
    const ctx = try std.fmt.allocPrint(alloc, "{s}context:     {s}{s}", .{ ANSI_DIM, info.context, ANSI_RESET });
    defer alloc.free(ctx);
    const usage = try std.fmt.allocPrint(alloc, "{s}usage:       {s}{s}", .{ ANSI_DIM, info.usage, ANSI_RESET });
    defer alloc.free(usage);
    const lines = [_][]const u8{ title, "", model, dir, session, perms, ctx, usage, CARD_HINT };
    return formatCard(alloc, &lines, width);
}

fn writeCardEdge(wr: *std.Io.Writer, left: []const u8, right: []const u8, inner: usize) !void {
    try wr.writeAll(ANSI_DIM);
    try wr.writeAll(left);
    var i: usize = 0;
    while (i < inner + 2) : (i += 1) try wr.writeAll("─");
    try wr.writeAll(right);
    try wr.writeAll(ANSI_RESET ++ "\n");
}

/// skip = 从对话顶裁掉的行数。off=0 钉住底。
pub fn scrollSkip(off: usize, total: usize, view: usize) usize {
    const pin = if (total > view) total - view else 0;
    const o = @min(off, pin);
    return pin - o;
}

/// Working 行数:关=0,开=1 状态 + ≤2 详情。
pub fn workingRows(nact: usize, streaming: bool) usize {
    if (nact == 0 and !streaming) return 0;
    return 1 + @min(nact, 2);
}

/// Composer box display width. Terminals with auto-margin wrap a glyph
/// written in the last column, so the closed box is `cols-1` (never `cols`).
pub fn composerBoxWidth(cols: usize) usize {
    return if (cols > 1) cols - 1 else cols;
}

/// Prefix `│ › ` is 4 cols; plus the right `│` is 5. Inner text fits in the rest.
const COMPOSER_FRAME: usize = 5;

fn composerInnerWidth(boxed: bool, cols: usize) usize {
    if (!boxed) return @max(cols, 2) - 2;
    const box_w = composerBoxWidth(cols);
    return @max(box_w, COMPOSER_FRAME) - COMPOSER_FRAME;
}

fn composerSkip(cursor_row: usize, view_rows: usize) usize {
    if (view_rows == 0) return 0;
    return if (cursor_row + 1 > view_rows) cursor_row + 1 - view_rows else 0;
}

fn composerTopRow(height: usize, bottom: BottomPane) usize {
    return @max(@as(usize, 1), height -| (bottom.footer_rows + bottom.composer_rows) + 1);
}

fn composerInputRow(height: usize, bottom: BottomPane, cursor_row: usize) usize {
    const skip = composerSkip(cursor_row, bottom.comp_inner);
    const top = composerTopRow(height, bottom);
    const vis = cursor_row -| skip;
    return if (bottom.boxed) top + 1 + vis else top;
}

/// 底栏一次量完。对话区拿剩下的行。
pub const BottomPane = struct {
    working_rows: usize = 0,
    perm_rows: usize = 0,
    picker_rows: usize = 0,
    slash_rows: usize = 0,
    composer_rows: usize = 0,
    footer_rows: usize = 0,
    footer_ident_rows: usize = 1,
    boxed: bool = true,
    input_inner: usize = 1,
    comp_inner: usize = 1,

    pub fn height(self: BottomPane) usize {
        return self.working_rows + self.perm_rows + self.picker_rows + self.slash_rows + self.composer_rows + self.footer_rows;
    }
};

pub const Tui = struct {
    alloc: std.mem.Allocator,
    cells: std.array_list.Managed(Cell),
    mutex: std.Io.Mutex = .init,
    dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    input: std.array_list.Managed(u8),
    cursor: usize = 0,
    history: std.array_list.Managed([]const u8),
    hist_idx: ?usize = null,
    orig_tio: std.posix.termios,
    in_fd: std.posix.fd_t,
    out_fd: std.posix.fd_t,
    width: usize = 80,
    height: usize = 24,
    raw: bool = false,
    streaming: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ctx: ?*anyopaque = null,
    perm_prompt: std.atomic.Value(?*const []const u8) = std.atomic.Value(?*const []const u8).init(null),
    status: std.array_list.Managed(u8),
    status_style: []const u8 = ANSI_DIM,
    footer_model: std.array_list.Managed(u8),
    footer_think: std.array_list.Managed(u8),
    footer_cwd: std.array_list.Managed(u8),
    footer_branch: std.array_list.Managed(u8),
    footer_session: std.array_list.Managed(u8),
    footer_used: usize = 0,
    footer_tok_in: u64 = 0,
    footer_tok_out: u64 = 0,
    footer_tok_cache_w: u64 = 0,
    footer_tok_cache_r: u64 = 0,
    footer_cost: ?f64 = null,
    footer_sub: bool = false,
    footer_window: usize = 0,
    footer_cache_read: ?u64 = null,
    footer_prompt: ?u64 = null,
    footer_pct: usize = 0,
    footer_hot: bool = false,
    slash_items: []const SlashItem = &.{},
    slash_sel: usize = 0,
    history_path: []u8,
    think_open: bool = true,
    think_live: bool = false,
    last_think_len: usize = 0,
    think_level: ai.ThinkLevel = .high,
    think_meta: cfgmod.ModelMeta = .{ .reasoning = true },
    quit_arm_ns: i64 = 0,
    quit_arm_key: u8 = 0,
    esc_armed: bool = false,
    picker: ?Picker = null,
    scroll_off: usize = 0,
    last_pin: usize = 0,
    shortcuts_open: bool = false,

    pub fn init(alloc: std.mem.Allocator) !Tui {
        const in_fd = std.posix.STDIN_FILENO;
        const out_fd = std.posix.STDOUT_FILENO;
        const orig_tio = std.posix.tcgetattr(in_fd) catch std.posix.termios{
            .iflag = .{},
            .oflag = .{},
            .cflag = .{},
            .lflag = .{},
            .line = 0,
            .cc = [_]u8{0} ** std.posix.NCCS,
            .ispeed = @enumFromInt(0),
            .ospeed = @enumFromInt(0),
        };
        const hist_path = blk: {
            if (util.configDir(alloc)) |cfg_dir| {
                defer alloc.free(cfg_dir);
                break :blk util.joinPath(alloc, cfg_dir, "history.txt") catch try alloc.dupe(u8, "");
            } else |_| {
                break :blk try alloc.dupe(u8, "");
            }
        };
        var hist = std.array_list.Managed([]const u8).init(alloc);
        if (hist_path.len > 0) if (std.Io.Dir.cwd().readFileAlloc(util.io, hist_path, alloc, .limited(4 * 1024 * 1024))) |content| {
            defer alloc.free(content);
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                if (line.len > 0) try hist.append(try alloc.dupe(u8, line));
                if (hist.items.len >= 2000) break;
            }
        } else |_| {} else {}
        return .{
            .alloc = alloc,
            .cells = std.array_list.Managed(Cell).init(alloc),
            .input = std.array_list.Managed(u8).init(alloc),
            .history = hist,
            .orig_tio = orig_tio,
            .in_fd = in_fd,
            .out_fd = out_fd,
            .status = std.array_list.Managed(u8).init(alloc),
            .footer_model = std.array_list.Managed(u8).init(alloc),
            .footer_think = std.array_list.Managed(u8).init(alloc),
            .footer_cwd = std.array_list.Managed(u8).init(alloc),
            .footer_branch = std.array_list.Managed(u8).init(alloc),
            .footer_session = std.array_list.Managed(u8).init(alloc),
            .history_path = hist_path,
        };
    }

    pub fn deinit(self: *Tui) void {
        self.restoreTerminal();
        self.closePicker();
        self.freeCells();
        self.cells.deinit();
        self.input.deinit();
        for (self.history.items) |line| self.alloc.free(line);
        self.history.deinit();
        self.status.deinit();
        self.footer_model.deinit();
        self.footer_think.deinit();
        self.footer_cwd.deinit();
        self.footer_branch.deinit();
        self.footer_session.deinit();
        self.alloc.free(self.history_path);
    }

    fn freeCells(self: *Tui) void {
        for (self.cells.items) |*c| deinitCell(c, self.alloc);
        self.cells.clearRetainingCapacity();
    }

    pub fn openPicker(self: *Tui, cmd: []const u8, title: []const u8, items: []const PickerItem, selected: usize) !void {
        self.closePicker();
        self.picker = try Picker.init(self.alloc, cmd, title, items, selected);
        self.disarmQuit();
        self.esc_armed = false;
        self.shortcuts_open = false;
        self.dirty.store(true, .release);
    }

    pub fn closePicker(self: *Tui) void {
        if (self.picker) |*p| {
            p.deinit(self.alloc);
            self.picker = null;
            self.dirty.store(true, .release);
        }
    }

    pub fn enterRaw(self: *Tui) !void {
        const tio = std.posix.tcgetattr(self.in_fd) catch {
            self.raw = false;
            return;
        };
        self.orig_tio = tio;
        var raw = tio;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.oflag.OPOST = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(self.in_fd, .NOW, raw);
        self.raw = true;
        self.armEmergencyRestore();
        try self.writeAll("\x1b[?1049h");
        try self.writeAll(ENTER_ALT_SCROLL);
        try self.querySize();
    }

    pub fn restoreTerminal(self: *Tui) void {
        if (self.raw) {
            self.raw = false;
            _ = self.writeAll(LEAVE_ALT_SCROLL ++ "\x1b[?1049l\x1b[0m") catch {};
            _ = std.posix.tcsetattr(self.in_fd, .NOW, self.orig_tio) catch {};
            emergency_tio = null;
        }
    }

    var emergency_fd: std.posix.fd_t = -1;
    var emergency_tio: ?std.posix.termios = null;

    fn emergencyRestore(signo: std.posix.SIG) callconv(.c) void {
        if (emergency_tio) |tio| {
            _ = std.posix.tcsetattr(emergency_fd, .NOW, tio) catch {};
            const seq = LEAVE_ALT_SCROLL ++ "\x1b[?1049l\x1b[0m";
            _ = std.os.linux.write(emergency_fd, seq.ptr, seq.len);
        }
        std.posix.sigaction(signo, &.{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        }, null);
        _ = std.posix.raise(signo) catch {};
    }

    fn armEmergencyRestore(self: *Tui) void {
        emergency_fd = self.in_fd;
        emergency_tio = self.orig_tio;
        const act = std.posix.Sigaction{
            .handler = .{ .handler = emergencyRestore },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        const sigs = [_]@TypeOf(std.posix.SIG.TERM){
            std.posix.SIG.TERM,
            std.posix.SIG.HUP,
            std.posix.SIG.QUIT,
            std.posix.SIG.INT,
        };
        for (sigs) |sig| {
            std.posix.sigaction(sig, &act, null);
        }
    }

    pub fn querySize(self: *Tui) !void {
        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(self.out_fd, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc == 0) {
            self.width = @max(ws.col, 20);
            self.height = @max(ws.row, 5);
        } else {
            self.width = 80;
            self.height = 24;
        }
    }

    pub fn writeAll(self: *Tui, data: []const u8) !void {
        const f = std.Io.File{ .handle = self.out_fd, .flags = .{ .nonblocking = false } };
        var wbuf: [8192]u8 = undefined;
        var w = f.writer(util.io, &wbuf);
        try w.interface.writeAll(data);
        try w.flush();
    }

    fn pushCell(self: *Tui, kind: CellKind) !*Cell {
        try self.cells.append(.{
            .kind = kind,
            .text = std.array_list.Managed(u8).init(self.alloc),
        });
        return &self.cells.items[self.cells.items.len - 1];
    }

    fn lastCell(self: *Tui, kind: CellKind) ?*Cell {
        if (self.cells.items.len == 0) return null;
        const c = &self.cells.items[self.cells.items.len - 1];
        return if (c.kind == kind) c else null;
    }

    /// 原文入库。Markdown / 色带在 paint 时由 styleMd 处理,此处不再剥 ` 以免代码跨度丢失。
    fn appendStyledTo(_: *Tui, buf: *std.array_list.Managed(u8), s: []const u8) !void {
        try buf.appendSlice(s);
    }

    pub fn appendText(self: *Tui, s: []const u8) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        const cell = self.lastCell(.assistant) orelse try self.pushCell(.assistant);
        try self.appendStyledTo(&cell.text, s);
        self.dirty.store(true, .release);
    }

    pub fn appendThink(self: *Tui, s: []const u8) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        const cell = if (self.think_live) self.lastCell(.think) else null;
        const dest = cell orelse blk: {
            self.think_open = true;
            break :blk try self.pushCell(.think);
        };
        self.think_live = true;
        try dest.text.appendSlice(s);
        self.last_think_len = dest.text.items.len;
        self.dirty.store(true, .release);
    }

    pub fn toggleThink(self: *Tui) void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        var any = false;
        for (self.cells.items) |c| {
            if (c.kind == .think and c.text.items.len > 0) any = true;
        }
        if (!any) return;
        self.think_open = !self.think_open;
        self.dirty.store(true, .release);
    }

    /// 关掉当前思考格,下一段思考另起一格。续载每条 assistant 之后要调用。
    pub fn bakeThink(self: *Tui) void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        if (self.lastCell(.think)) |c| {
            self.last_think_len = c.text.items.len;
        }
        self.think_live = false;
        self.dirty.store(true, .release);
    }

    pub fn appendUser(self: *Tui, s: []const u8) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        self.think_live = false;
        const cell = try self.pushCell(.user);
        try self.appendStyledTo(&cell.text, s);
        self.scroll_off = 0;
        self.dirty.store(true, .release);
    }

    pub fn appendLine(self: *Tui, prefix: []const u8, color: []const u8, s: []const u8) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        const cell = try self.pushCell(.chrome);
        cell.color = color;
        try cell.text.appendSlice(prefix);
        try self.appendStyledTo(&cell.text, s);
        self.dirty.store(true, .release);
    }

    /// Start (or add) a running folded tool cell. Parallel tools are siblings.
    pub fn appendTool(self: *Tui, name: []const u8, preview: []const u8) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        const cell = try self.pushCell(.tool);
        const name_d = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(name_d);
        const prev_d = try self.alloc.dupe(u8, preview);
        errdefer self.alloc.free(prev_d);
        if (preview.len > 0) {
            try cell.text.appendSlice(name);
            try cell.text.appendSlice("  ");
            try cell.text.appendSlice(preview);
        } else {
            try cell.text.appendSlice(name);
        }
        cell.tool = .{
            .name = name_d,
            .preview = prev_d,
            .status = .running,
            .start_ms = nowMs(),
            .folded = true,
            .body = std.array_list.Managed(u8).init(self.alloc),
        };
        self.dirty.store(true, .release);
    }

    /// Finish the matching in-flight tool in place. Stays folded; body is stored.
    pub fn appendToolEnd(self: *Tui, name: []const u8, is_error: bool, body: []const u8) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        const cell = self.firstRunningTool(name) orelse try self.pushCell(.tool);
        if (cell.tool == null) {
            const name_d = try self.alloc.dupe(u8, name);
            errdefer self.alloc.free(name_d);
            const prev_d = try self.alloc.dupe(u8, "");
            errdefer self.alloc.free(prev_d);
            try cell.text.appendSlice(name);
            cell.tool = .{
                .name = name_d,
                .preview = prev_d,
                .folded = true,
                .body = std.array_list.Managed(u8).init(self.alloc),
            };
        }
        const tm = &cell.tool.?;
        tm.status = if (is_error) .err else .ok;
        tm.bytes = body.len;
        tm.lines = countContentLines(body);
        const now = nowMs();
        if (tm.start_ms != 0) tm.elapsed_ms = @max(0, now - tm.start_ms);
        tm.body.clearRetainingCapacity();
        try tm.body.appendSlice(body);
        tm.folded = true;
        self.dirty.store(true, .release);
    }

    fn firstRunningTool(self: *Tui, name: []const u8) ?*Cell {
        for (self.cells.items) |*c| {
            if (c.kind != .tool) continue;
            if (c.tool) |*tm| {
                if (tm.status == .running and std.mem.eql(u8, tm.name, name)) return c;
            }
        }
        return null;
    }

    /// Ctrl+O: if any tool is folded, expand all; else fold all. Like Ctrl+T for think.
    pub fn toggleTools(self: *Tui) void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        var any = false;
        var any_folded = false;
        for (self.cells.items) |c| {
            if (c.tool) |tm| {
                any = true;
                if (tm.folded) any_folded = true;
            }
        }
        if (!any) return;
        const next_folded = !any_folded;
        for (self.cells.items) |*c| {
            if (c.tool) |*tm| tm.folded = next_folded;
        }
        self.dirty.store(true, .release);
    }

    fn appendRoleCell(self: *Tui, kind: CellKind, s: []const u8) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        const cell = try self.pushCell(kind);
        try self.appendStyledTo(&cell.text, s);
        self.dirty.store(true, .release);
    }

    pub fn setSessionHeader(self: *Tui, info: SessionInfo) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        const fields = try dupeSession(self.alloc, info);
        errdefer fields.deinit(self.alloc);
        if (self.cells.items.len > 0 and self.cells.items[0].kind == .session_header) {
            if (self.cells.items[0].card) |old| old.deinit(self.alloc);
            self.cells.items[0].card = fields;
        } else {
            try self.cells.insert(0, .{
                .kind = .session_header,
                .text = std.array_list.Managed(u8).init(self.alloc),
                .card = fields,
            });
        }
        self.dirty.store(true, .release);
    }

    pub fn appendStatusCard(self: *Tui, info: StatusInfo) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        const fields = try dupeStatus(self.alloc, info);
        errdefer fields.deinit(self.alloc);
        try self.cells.append(.{
            .kind = .status_card,
            .text = std.array_list.Managed(u8).init(self.alloc),
            .card = fields,
        });
        self.dirty.store(true, .release);
    }

    pub fn setStatus(self: *Tui, style: []const u8, s: []const u8) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        self.status.clearRetainingCapacity();
        self.status_style = style;
        try self.status.appendSlice(s);
        self.dirty.store(true, .release);
    }

    pub fn setFooterIdentity(self: *Tui, ident: FooterIdent) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        self.footer_model.clearRetainingCapacity();
        try self.footer_model.appendSlice(ident.model);
        self.footer_think.clearRetainingCapacity();
        try self.footer_think.appendSlice(ident.think);
        self.footer_cwd.clearRetainingCapacity();
        try self.footer_cwd.appendSlice(ident.cwd);
        self.footer_branch.clearRetainingCapacity();
        try self.footer_branch.appendSlice(ident.branch);
        self.footer_session.clearRetainingCapacity();
        try self.footer_session.appendSlice(ident.session);
        self.footer_used = ident.used;
        self.footer_tok_in = ident.tok_in;
        self.footer_tok_out = ident.tok_out;
        self.footer_tok_cache_w = ident.tok_cache_w;
        self.footer_tok_cache_r = ident.tok_cache_r;
        self.footer_cost = ident.cost;
        self.footer_sub = ident.subscription;
        self.footer_window = ident.window;
        self.footer_cache_read = ident.cache_read;
        self.footer_prompt = ident.prompt;
        self.footer_pct = ident.pct;
        self.footer_hot = ident.hot;
        self.dirty.store(true, .release);
    }

    pub fn clearScroll(self: *Tui) void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        self.freeCells();
        self.think_open = true;
        self.think_live = false;
        self.scroll_off = 0;
        self.dirty.store(true, .release);
    }

    /// 测试用:正文里有没有这段字。不搜 gutter。工具格搜 name / preview / body。
    pub fn contains(self: *const Tui, needle: []const u8) bool {
        for (self.cells.items) |c| {
            if (std.mem.indexOf(u8, c.text.items, needle) != null) return true;
            if (c.tool) |tm| {
                if (std.mem.indexOf(u8, tm.name, needle) != null) return true;
                if (std.mem.indexOf(u8, tm.preview, needle) != null) return true;
                if (std.mem.indexOf(u8, tm.body.items, needle) != null) return true;
            }
            if (c.card) |card| {
                if (std.mem.indexOf(u8, card.session, needle) != null) return true;
                if (std.mem.indexOf(u8, card.model, needle) != null) return true;
                if (std.mem.indexOf(u8, card.cwd, needle) != null) return true;
            }
        }
        return false;
    }

    fn measureBottom(self: *Tui, nact: usize, streaming: bool) BottomPane {
        const w = self.width;
        const h = self.height;
        var perm_rows: usize = 0;
        if (self.perm_prompt.load(.acquire)) |pp| {
            perm_rows = 1;
            for (pp.*) |c| {
                if (c == '\n') perm_rows += 1;
            }
        }
        const picker_rows: usize = if (self.picker) |*p| p.displayRows(h) else 0;
        const slash_rows: usize = if (self.picker == null) slashDisplayRows(self.input.items, self.slash_items, h) else 0;
        const boxed = w >= 8;
        const input_inner = composerInnerWidth(boxed, w);
        const wrap_n = wrapRowCount(self.input.items, input_inner);
        const cap = @max(1, h / 4);
        var comp_inner: usize = if (boxed) @max(1, @min(cap, wrap_n)) else 1;
        const min_inner: usize = 1;
        var working = workingRows(nact, streaming);
        const help_rows: usize = if (self.shortcuts_open) 2 else 0;
        const ident = FooterIdent{
            .model = self.footer_model.items,
            .think = self.footer_think.items,
            .cwd = self.footer_cwd.items,
            .branch = self.footer_branch.items,
            .session = self.footer_session.items,
            .tok_in = self.footer_tok_in,
            .tok_out = self.footer_tok_out,
            .tok_cache_w = self.footer_tok_cache_w,
            .tok_cache_r = self.footer_tok_cache_r,
            .cost = self.footer_cost,
            .subscription = self.footer_sub,
            .used = self.footer_used,
            .window = self.footer_window,
            .cache_read = self.footer_cache_read,
            .prompt = self.footer_prompt,
            .pct = self.footer_pct,
            .hot = self.footer_hot,
        };
        const hint = footerHint(.{
            .perm = self.perm_prompt.load(.acquire) != null,
            .picker = self.picker != null,
            .slash = self.picker == null and slashQuery(self.input.items) != null and self.slash_items.len > 0,
            .quit_armed = self.quit_arm_ns != 0,
            .esc_armed = self.esc_armed,
            .scrolled = self.scroll_off > 0,
            .shortcuts = self.shortcuts_open,
            .has_draft = self.input.items.len > 0,
            .running = streaming,
        });
        var ident_rows: usize = if (footerNeedsTwoRows(ident, hint, w)) 2 else 1;
        const fixed = perm_rows + picker_rows + slash_rows + help_rows;
        const composerOf = struct {
            fn go(is_boxed: bool, inner: usize) usize {
                return if (is_boxed) 2 + inner else 1;
            }
        }.go;
        // Overflow: shrink wrap-grown composer (never below 3), then drop
        // footer row 2 (one-row pack still keeps cwd), then working details.
        // Composer stays a closed box.
        while (working + fixed + composerOf(boxed, comp_inner) + ident_rows > h and comp_inner > min_inner) {
            comp_inner -= 1;
        }
        if (working + fixed + composerOf(boxed, comp_inner) + ident_rows > h and ident_rows > 1) {
            ident_rows = 1;
        }
        while (working + fixed + composerOf(boxed, comp_inner) + ident_rows > h and working > 1) {
            working -= 1;
        }
        const composer_rows = composerOf(boxed, comp_inner);
        return .{
            .working_rows = working,
            .perm_rows = perm_rows,
            .picker_rows = picker_rows,
            .slash_rows = slash_rows,
            .composer_rows = composer_rows,
            .footer_rows = ident_rows + help_rows,
            .footer_ident_rows = ident_rows,
            .boxed = boxed,
            .input_inner = input_inner,
            .comp_inner = comp_inner,
        };
    }

    fn renderFrame(self: *Tui) !void {
        var fw = std.Io.Writer.Allocating.init(self.alloc);
        defer fw.deinit();
        const w = self.width;
        const h = self.height;
        var views: [activity.MAX_SLOTS]activity.View = undefined;
        const nact = activity.snapshot(&views);
        const streaming = self.streaming.load(.acquire);
        const bottom = self.measureBottom(nact, streaming);
        const reserved = bottom.height();
        const scroll_h = if (h > reserved) h - reserved else 1;

        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);

        var cards = std.array_list.Managed([]u8).init(self.alloc);
        defer {
            for (cards.items) |s| self.alloc.free(s);
            cards.deinit();
        }
        for (self.cells.items) |c| {
            if (c.card) |card| {
                const painted = try paintCard(self.alloc, c.kind, card, w);
                try cards.append(painted);
            }
        }

        try fw.writer.writeAll("\x1b[?25l\x1b[H");
        var total_vis: usize = 0;
        var card_i: usize = 0;
        var ci: usize = 0;
        while (ci < self.cells.items.len) : (ci += 1) {
            if (ci > 0 and gapBetween(self.cells.items[ci - 1].kind, self.cells.items[ci].kind)) total_vis += 1;
            const painted = cardSlice(self.cells.items[ci], cards.items, &card_i);
            total_vis += cellRowCount(self.alloc, self.cells.items[ci], painted, self.think_open, w);
        }

        const pin = if (total_vis > scroll_h) total_vis - scroll_h else 0;
        if (self.scroll_off > pin) self.scroll_off = pin;
        self.last_pin = pin;
        var skip = pin - self.scroll_off;
        var emitted: usize = 0;
        card_i = 0;
        ci = 0;
        while (ci < self.cells.items.len) : (ci += 1) {
            if (ci > 0 and gapBetween(self.cells.items[ci - 1].kind, self.cells.items[ci].kind)) {
                if (skip > 0) {
                    skip -= 1;
                } else if (emitted < scroll_h) {
                    try fw.writer.writeAll("\x1b[K\r\n");
                    emitted += 1;
                }
            }
            const painted = cardSlice(self.cells.items[ci], cards.items, &card_i);
            if (emitted >= scroll_h) continue;
            const n = cellRowCount(self.alloc, self.cells.items[ci], painted, self.think_open, w);
            if (skip >= n) {
                skip -= n;
            } else {
                emitted += try emitCell(self.alloc, &fw.writer, self.cells.items[ci], painted, self.think_open, w, skip, scroll_h - emitted);
                skip = 0;
            }
        }
        while (emitted < scroll_h) : (emitted += 1) {
            try fw.writer.writeAll("\x1b[K\r\n");
        }
        if (bottom.working_rows > 0) {
            const frame_ms = @as(i64, @intCast(@divTrunc(std.Io.Clock.now(.awake, util.io).nanoseconds, std.time.ns_per_ms)));
            try writeStatusIndicator(&fw.writer, views[0..nact], streaming, frame_ms, w, bottom.working_rows);
        }
        if (self.perm_prompt.load(.acquire)) |pp| {
            var rest = pp.*;
            while (rest.len > 0) {
                const nl = std.mem.indexOfScalar(u8, rest, '\n');
                const line = if (nl) |n| rest[0..n] else rest;
                rest = if (nl) |n| rest[n + 1 ..] else &.{};
                try writeTrunc(&fw.writer, line, w);
                try fw.writer.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
            }
        }
        if (self.picker) |*p| {
            try writePicker(&fw.writer, p, h, w);
        } else if (slashQuery(self.input.items)) |q| {
            try writeSlashPicker(&fw.writer, self.slash_items, q, &self.slash_sel, h, w);
        }
        const cur = wrapCursor(self.input.items, self.cursor, bottom.input_inner);
        const view_skip = composerSkip(cur.row, bottom.comp_inner);
        if (bottom.boxed) {
            const box_w = composerBoxWidth(w);
            try writeBoxEdge(&fw.writer, "╭", "╮", box_w);
            try emitComposer(&fw.writer, self.input.items, bottom.input_inner, bottom.comp_inner, view_skip);
            try writeBoxEdge(&fw.writer, "╰", "╯", box_w);
        } else {
            try fw.writer.writeAll(ANSI_DIM ++ "› " ++ ANSI_RESET);
            try writeTrunc(&fw.writer, self.input.items, bottom.input_inner);
            try fw.writer.writeAll("\x1b[K\r\n");
        }
        const hint = footerHint(.{
            .perm = self.perm_prompt.load(.acquire) != null,
            .picker = self.picker != null,
            .slash = self.picker == null and slashQuery(self.input.items) != null and self.slash_items.len > 0,
            .quit_armed = self.quit_arm_ns != 0,
            .esc_armed = self.esc_armed,
            .scrolled = self.scroll_off > 0,
            .shortcuts = self.shortcuts_open,
            .has_draft = self.input.items.len > 0,
            .running = streaming or nact > 0,
        });
        const rows = try formatFooterRows(self.alloc, .{
            .model = self.footer_model.items,
            .think = self.footer_think.items,
            .cwd = self.footer_cwd.items,
            .branch = self.footer_branch.items,
            .session = self.footer_session.items,
            .tok_in = self.footer_tok_in,
            .tok_out = self.footer_tok_out,
            .tok_cache_w = self.footer_tok_cache_w,
            .tok_cache_r = self.footer_tok_cache_r,
            .cost = self.footer_cost,
            .subscription = self.footer_sub,
            .used = self.footer_used,
            .window = self.footer_window,
            .cache_read = self.footer_cache_read,
            .prompt = self.footer_prompt,
            .pct = self.footer_pct,
            .hot = self.footer_hot,
        }, hint, w, bottom.footer_ident_rows >= 2);
        defer rows.deinit(self.alloc);
        try fw.writer.writeAll(rows.primary);
        try fw.writer.writeAll(ANSI_RESET ++ "\x1b[K");
        if (bottom.footer_ident_rows >= 2) {
            try fw.writer.writeAll("\r\n");
            try fw.writer.writeAll(rows.secondary);
            try fw.writer.writeAll(ANSI_RESET ++ "\x1b[K");
        }
        if (self.shortcuts_open) {
            try fw.writer.writeAll("\r\n" ++ ANSI_DIM);
            try writeTrunc(&fw.writer, "enter send   tab queue   esc abort   ctrl+c quit", w);
            try fw.writer.writeAll(ANSI_RESET ++ "\x1b[K\r\n" ++ ANSI_DIM);
            try writeTrunc(&fw.writer, "ctrl+t think  ctrl+o tools  /model  /think  /help", w);
            try fw.writer.writeAll(ANSI_RESET ++ "\x1b[K");
        }
        try fw.writer.writeAll("\x1b[J");
        const input_row = composerInputRow(h, bottom, cur.row);
        const col = @max(@as(usize, 1), @min(w, (if (bottom.boxed) COMPOSER_FRAME else 3) + cur.col));
        try fw.writer.print("\x1b[{d};{d}H\x1b[?25h", .{ input_row, col });
        try self.writeAll(try fw.toOwnedSlice());
    }

    pub const Handlers = struct {
        on_submit: *const fn (tui: *Tui, line: []const u8) anyerror!void,
        is_quit: *const fn (ctx: ?*anyopaque) bool,
        on_abort: ?*const fn (ctx: ?*anyopaque) void = null,
        on_detach: ?*const fn (ctx: ?*anyopaque) void = null,
        on_perm: ?*const fn (ctx: ?*anyopaque, key: u8) void = null,
        on_paint: ?*const fn (ctx: ?*anyopaque) void = null,
        on_think: ?*const fn (ctx: ?*anyopaque) void = null,
        ctx: ?*anyopaque = null,
    };

    pub fn run(self: *Tui, h: Handlers) !void {
        const ctx = h.ctx;
        const on_submit = h.on_submit;
        const is_quit = h.is_quit;
        const on_abort = h.on_abort;
        const on_detach = h.on_detach;
        const on_perm = h.on_perm;
        const on_paint = h.on_paint;
        const on_think = h.on_think;
        self.ctx = ctx;
        if (on_paint) |f| f(ctx);
        try self.renderFrame();
        self.dirty.store(false, .release);
        var poll_fds = [_]std.posix.pollfd{.{ .fd = self.in_fd, .events = std.posix.POLL.IN, .revents = 0 }};
        while (true) {
            if (is_quit(ctx)) return;
            const n = std.posix.poll(&poll_fds, 50) catch 0;
            if (n > 0) {
                var buf: [256]u8 = undefined;
                const got = std.posix.read(self.in_fd, &buf) catch 0;
                if (got > 0) {
                    if (self.perm_prompt.load(.acquire) != null) {
                        if (on_perm) |f| {
                            var pi: usize = 0;
                            while (pi < got) : (pi += 1) {
                                const b = buf[pi];
                                switch (b) {
                                    'y', 'Y', 'n', 'N', 'a', 'A', 's', 'S', 0x03 => f(ctx, b),
                                    0x1b => {
                                        if (pi + 1 < got and buf[pi + 1] == '[') continue;
                                        f(ctx, 'n');
                                    },
                                    else => {},
                                }
                            }
                        }
                    } else {
                        const action = try self.handleInput(buf[0..got]);
                        switch (action) {
                            .quit => return,
                            .submit => |line| {
                                try on_submit(self, line);
                            },
                            .abort => {
                                if (on_abort) |f| f(ctx);
                            },
                            .detach => {
                                if (on_detach) |f| f(ctx);
                            },
                            .think => {
                                if (on_think) |f| f(ctx);
                            },
                            .none => {},
                        }
                    }
                }
            }
            if (self.quit_arm_ns != 0) {
                const now = nowNs();
                if (now - self.quit_arm_ns >= std.time.ns_per_s) {
                    self.quit_arm_ns = 0;
                    self.quit_arm_key = 0;
                    self.dirty.store(true, .release);
                }
            }
            const busy = activity.count() > 0 or self.streaming.load(.acquire);
            if (self.dirty.load(.acquire) or busy) {
                if (on_paint) |f| f(ctx);
                try self.renderFrame();
                self.dirty.store(false, .release);
            }
        }
    }

    const Action = union(enum) { none, quit, abort, detach, submit: []const u8, think };

    fn disarmQuit(self: *Tui) void {
        if (self.quit_arm_ns == 0) return;
        self.quit_arm_ns = 0;
        self.quit_arm_key = 0;
        self.dirty.store(true, .release);
    }

    fn armOrQuit(self: *Tui, key: u8) Action {
        const now = nowNs();
        if (self.quit_arm_key == key and self.quit_arm_ns != 0 and now - self.quit_arm_ns < std.time.ns_per_s) {
            self.disarmQuit();
            return .quit;
        }
        self.quit_arm_key = key;
        self.quit_arm_ns = now;
        self.dirty.store(true, .release);
        return .none;
    }

    fn takeSubmit(self: *Tui) !Action {
        if (self.input.items.len == 0) return .none;
        const line = if (self.slashSubmitLine()) |picked|
            picked
        else
            try self.alloc.dupe(u8, self.input.items);
        self.input.clearRetainingCapacity();
        self.cursor = 0;
        self.hist_idx = null;
        self.slash_sel = 0;
        self.disarmQuit();
        self.esc_armed = false;
        self.shortcuts_open = false;
        return .{ .submit = line };
    }

    fn slashSubmitLine(self: *Tui) ?[]u8 {
        const q = slashQuery(self.input.items) orelse return null;
        var ranks: [64]SlashRank = undefined;
        const n = rankSlash(self.slash_items, q, &ranks);
        if (n == 0) return null;
        const sel = @min(self.slash_sel, n - 1);
        const name = slashName(self.slash_items[ranks[sel].item].cmd);
        return std.fmt.allocPrint(self.alloc, "/{s}", .{name}) catch null;
    }

    fn completeSlash(self: *Tui) !void {
        const q = slashQuery(self.input.items) orelse return;
        var ranks: [64]SlashRank = undefined;
        const n = rankSlash(self.slash_items, q, &ranks);
        if (n == 0) return;
        const sel = @min(self.slash_sel, n - 1);
        const name = slashName(self.slash_items[ranks[sel].item].cmd);
        self.input.clearRetainingCapacity();
        try self.input.append('/');
        try self.input.appendSlice(name);
        self.cursor = self.input.items.len;
        self.dirty.store(true, .release);
    }

    fn moveSlash(self: *Tui, delta: isize) void {
        const q = slashQuery(self.input.items) orelse return;
        var ranks: [64]SlashRank = undefined;
        const n = rankSlash(self.slash_items, q, &ranks);
        if (n == 0) return;
        if (delta < 0) {
            const d: usize = @intCast(-delta);
            self.slash_sel = if (self.slash_sel >= d) self.slash_sel - d else 0;
        } else {
            const d: usize = @intCast(delta);
            self.slash_sel = @min(n - 1, self.slash_sel + d);
        }
        self.dirty.store(true, .release);
    }

    fn slashOpen(self: *const Tui) bool {
        return self.picker == null and slashQuery(self.input.items) != null and self.slash_items.len > 0;
    }

    fn handleInput(self: *Tui, bytes: []const u8) !Action {
        if (self.picker != null) return self.handlePickerInput(bytes);
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            const streaming = self.streaming.load(.acquire);

            if (b == 0x1b) {
                if (i + 1 < bytes.len and bytes[i + 1] == '[') {
                    i += 2;
                    var k = i;
                    while (k < bytes.len and (bytes[k] < '@' or bytes[k] > '~')) k += 1;
                    if (k >= bytes.len) break;
                    self.disarmQuit();
                    self.esc_armed = false;
                    const params = bytes[i..k];
                    const final = bytes[k];
                    i = k + 1;
                    if (self.applyMouseScroll(params, final, bytes, &i)) continue;
                    switch (classifyCsi(params, final)) {
                        .up => self.arrowOrWheel(.up, bytes, &i, params, final),
                        .down => self.arrowOrWheel(.down, bytes, &i, params, final),
                        .page_up => self.scrollBy(@intCast(self.pageRows())),
                        .page_down => self.scrollBy(-@as(isize, @intCast(self.pageRows()))),
                        .ctrl_up => self.scrollBy(3),
                        .ctrl_down => self.scrollBy(-3),
                        .shift_up => {
                            self.cycleThink(true);
                            return .think;
                        },
                        .shift_down => {
                            self.cycleThink(false);
                            return .think;
                        },
                        .right => {
                            if (self.cursor < self.input.items.len) {
                                self.cursor += utf8LenAt(self.input.items, self.cursor);
                            }
                            self.dirty.store(true, .release);
                        },
                        .left => {
                            if (self.cursor > 0) self.cursor -= utf8PrevLen(self.input.items, self.cursor);
                            self.dirty.store(true, .release);
                        },
                        .home => {
                            self.cursor = 0;
                            self.dirty.store(true, .release);
                        },
                        .end => {
                            self.cursor = self.input.items.len;
                            self.dirty.store(true, .release);
                        },
                        .delete => {
                            deleteUtf8At(&self.input, self.cursor);
                            self.dirty.store(true, .release);
                        },
                        .other => {},
                    }
                    continue;
                }
                if (i + 1 < bytes.len and bytes[i + 1] == ',') {
                    self.disarmQuit();
                    self.esc_armed = false;
                    self.cycleThink(false);
                    return .think;
                }
                if (i + 1 < bytes.len and bytes[i + 1] == '.') {
                    self.disarmQuit();
                    self.esc_armed = false;
                    self.cycleThink(true);
                    return .think;
                }
                if (streaming) return .abort;
                if (self.input.items.len == 0) {
                    if (self.esc_armed) {
                        self.esc_armed = false;
                        self.historyPrev();
                    } else {
                        self.esc_armed = true;
                        self.dirty.store(true, .release);
                    }
                }
                i += 1;
                continue;
            }

            if (b == 0x03) {
                if (self.input.items.len > 0) {
                    self.input.clearRetainingCapacity();
                    self.cursor = 0;
                    self.disarmQuit();
                    self.esc_armed = false;
                    self.dirty.store(true, .release);
                } else {
                    return self.armOrQuit(0x03);
                }
                i += 1;
                continue;
            }
            if (b == 0x04) {
                if (self.input.items.len == 0) return self.armOrQuit(0x04);
                i += 1;
                continue;
            }
            if (streaming and b == 0x02) return .detach;
            if (b == 0x14) {
                self.toggleThink();
                i += 1;
                continue;
            }
            if (b == 0x0f) {
                self.toggleTools();
                i += 1;
                continue;
            }
            if (b == 0x09) {
                if (streaming) {
                    const act = try self.takeSubmit();
                    if (act != .none) return act;
                } else if (self.slashOpen()) {
                    try self.completeSlash();
                }
                i += 1;
                continue;
            }

            self.disarmQuit();
            self.esc_armed = false;
            if (b != '?') self.shortcuts_open = false;

            switch (b) {
                '\n', '\r' => {
                    const act = try self.takeSubmit();
                    if (act != .none) return act;
                },
                0x02 => {
                    if (self.cursor > 0) self.cursor -= utf8PrevLen(self.input.items, self.cursor);
                    self.dirty.store(true, .release);
                },
                0x06 => {
                    if (self.cursor < self.input.items.len) {
                        self.cursor += utf8LenAt(self.input.items, self.cursor);
                    }
                    self.dirty.store(true, .release);
                },
                0x10 => if (self.slashOpen()) self.moveSlash(-1) else self.historyPrev(),
                0x0e => if (self.slashOpen()) self.moveSlash(1) else self.historyNext(),
                0x08, 0x7f => {
                    deleteUtf8Before(&self.input, &self.cursor);
                    self.dirty.store(true, .release);
                },
                0x01 => {
                    self.cursor = 0;
                    self.dirty.store(true, .release);
                },
                0x05 => {
                    self.cursor = self.input.items.len;
                    self.dirty.store(true, .release);
                },
                0x0b => {
                    self.input.shrinkRetainingCapacity(self.cursor);
                    self.dirty.store(true, .release);
                },
                0x15 => {
                    self.input.clearRetainingCapacity();
                    self.cursor = 0;
                    self.dirty.store(true, .release);
                },
                0x17 => {
                    while (self.cursor > 0 and self.input.items[self.cursor - 1] == ' ') {
                        deleteUtf8Before(&self.input, &self.cursor);
                    }
                    while (self.cursor > 0 and self.input.items[self.cursor - 1] != ' ') {
                        deleteUtf8Before(&self.input, &self.cursor);
                    }
                    self.dirty.store(true, .release);
                },
                0x0c => {
                    self.clearScroll();
                },
                '?' => {
                    if (self.input.items.len == 0 and !streaming) {
                        self.shortcuts_open = !self.shortcuts_open;
                        self.dirty.store(true, .release);
                    } else {
                        if (self.cursor >= self.input.items.len) {
                            try self.input.append('?');
                        } else {
                            try self.input.insert(self.cursor, '?');
                        }
                        self.cursor += 1;
                        self.shortcuts_open = false;
                        self.dirty.store(true, .release);
                    }
                },
                else => {
                    if (b >= 0x20) {
                        const word = std.unicode.utf8ByteSequenceLength(b) catch 1;
                        const avail = @min(word, bytes.len - i);
                        if (self.cursor >= self.input.items.len) {
                            try self.input.appendSlice(bytes[i .. i + avail]);
                        } else {
                            var j: usize = 0;
                            while (j < avail) : (j += 1) {
                                try self.input.insert(self.cursor + j, bytes[i + j]);
                            }
                        }
                        self.cursor += avail;
                        i += avail;
                        self.dirty.store(true, .release);
                        continue;
                    }
                },
            }
            i += 1;
        }
        return .none;
    }

    fn handlePickerInput(self: *Tui, bytes: []const u8) !Action {
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == 0x1b) {
                if (i + 1 < bytes.len and bytes[i + 1] == '[') {
                    i += 2;
                    var k = i;
                    while (k < bytes.len and (bytes[k] < '@' or bytes[k] > '~')) k += 1;
                    if (k >= bytes.len) break;
                    const params = bytes[i..k];
                    const final = bytes[k];
                    i = k + 1;
                    if (self.applyMouseScroll(params, final, bytes, &i)) {
                        self.dirty.store(true, .release);
                        continue;
                    }
                    if (self.picker) |*p| {
                        switch (classifyCsi(params, final)) {
                            .up => {
                                const extra = consumeSameCsi(bytes, &i, params, final);
                                if (extra > 0) {
                                    self.scrollBy(3 * @as(isize, @intCast(1 + extra)));
                                } else p.move(-1);
                            },
                            .down => {
                                const extra = consumeSameCsi(bytes, &i, params, final);
                                if (extra > 0) {
                                    self.scrollBy(-3 * @as(isize, @intCast(1 + extra)));
                                } else p.move(1);
                            },
                            .page_up => self.scrollBy(@intCast(self.pageRows())),
                            .page_down => self.scrollBy(-@as(isize, @intCast(self.pageRows()))),
                            .ctrl_up => self.scrollBy(3),
                            .ctrl_down => self.scrollBy(-3),
                            else => {},
                        }
                    }
                    self.dirty.store(true, .release);
                    continue;
                }
                self.closePicker();
                return .none;
            }
            if (b == 0x03 or b == 0x04) {
                self.closePicker();
                return .none;
            }
            switch (b) {
                '\n', '\r' => return try self.confirmPicker(),
                'k', 'K', 0x10 => if (self.picker) |*p| p.move(-1),
                'j', 'J', 0x0e => if (self.picker) |*p| p.move(1),
                '1'...'9' => {
                    const n: usize = b - '1';
                    if (self.picker) |*p| {
                        if (n < p.items.len) p.sel = n;
                    }
                },
                else => {},
            }
            self.dirty.store(true, .release);
            i += 1;
        }
        return .none;
    }

    fn confirmPicker(self: *Tui) !Action {
        const line = if (self.picker) |*p|
            try p.confirmLine(self.alloc)
        else
            return .none;
        self.closePicker();
        return .{ .submit = line };
    }

    fn pageRows(self: *const Tui) usize {
        return @max(1, self.height / 2);
    }

    /// 1007 alternate-scroll turns the wheel into CSI arrows. A burst in one
    /// read is a wheel; a single arrow is input history (or picker move).
    fn arrowOrWheel(self: *Tui, dir: WheelDir, bytes: []const u8, i: *usize, params: []const u8, final: u8) void {
        const extra = consumeSameCsi(bytes, i, params, final);
        if (extra > 0) {
            const n: isize = @intCast(1 + extra);
            self.scrollBy(if (dir == .up) 3 * n else -3 * n);
            return;
        }
        if (self.slashOpen()) {
            self.moveSlash(if (dir == .up) -1 else 1);
            return;
        }
        if (dir == .up) self.historyPrev() else self.historyNext();
    }

    fn applyMouseScroll(self: *Tui, params: []const u8, final: u8, bytes: []const u8, i: *usize) bool {
        if (sgrWheel(params)) |dir| {
            self.scrollBy(if (dir == .up) 3 else -3);
            return true;
        }
        if (params.len == 0 and final == 'M' and i.* + 3 <= bytes.len) {
            const btn: u16 = bytes[i.*];
            i.* += 3;
            const base = (btn -% 32) & ~@as(u16, 0x1C);
            if (base == 64) self.scrollBy(3);
            if (base == 65) self.scrollBy(-3);
            return true;
        }
        return false;
    }

    fn scrollBy(self: *Tui, delta: isize) void {
        if (delta < 0) {
            const d: usize = @intCast(-delta);
            self.scroll_off = if (self.scroll_off > d) self.scroll_off - d else 0;
        } else {
            self.scroll_off = @min(self.last_pin, self.scroll_off + @as(usize, @intCast(delta)));
        }
        self.dirty.store(true, .release);
    }

    fn cycleThink(self: *Tui, up: bool) void {
        self.think_level = cfgmod.cycleThinkLevel(self.think_meta, self.think_level, up);
        self.dirty.store(true, .release);
    }

    fn historyPrev(self: *Tui) void {
        if (self.history.items.len == 0) return;
        const idx = self.hist_idx orelse self.history.items.len;
        if (idx == 0) return;
        const ni = idx - 1;
        self.hist_idx = ni;
        self.input.clearRetainingCapacity();
        self.input.appendSlice(self.history.items[ni]) catch {};
        self.cursor = self.input.items.len;
        self.dirty.store(true, .release);
    }

    fn historyNext(self: *Tui) void {
        const idx = self.hist_idx orelse return;
        if (idx + 1 >= self.history.items.len) {
            self.hist_idx = null;
            self.input.clearRetainingCapacity();
            self.cursor = 0;
        } else {
            self.hist_idx = idx + 1;
            self.input.clearRetainingCapacity();
            self.input.appendSlice(self.history.items[idx + 1]) catch {};
            self.cursor = self.input.items.len;
        }
        self.dirty.store(true, .release);
    }

    pub fn addHistory(self: *Tui, line: []const u8) void {
        if (line.len == 0) return;
        if (self.history.items.len > 0 and std.mem.eql(u8, self.history.items[self.history.items.len - 1], line)) return;
        self.history.append(self.alloc.dupe(u8, line) catch return) catch return;
        var f = std.Io.Dir.cwd().createFile(util.io, self.history_path, .{ .permissions = @enumFromInt(0o600) }) catch |e| switch (e) {
            error.PathAlreadyExists => std.Io.Dir.cwd().openFile(util.io, self.history_path, .{ .mode = .write_only }) catch null,
            else => null,
        } orelse return;
        defer f.close(util.io);
        var wbuf: [4096]u8 = undefined;
        var wr = f.writer(util.io, &wbuf);
        wr.seekTo(f.length(util.io) catch return) catch return;
        wr.interface.writeAll(line) catch return;
        wr.interface.writeAll("\n") catch return;
        wr.flush() catch return;
    }
};

fn nowNs() i64 {
    return @intCast(std.Io.Clock.now(.real, util.io).nanoseconds);
}

fn nowMs() i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.awake, util.io).nanoseconds, std.time.ns_per_ms));
}

fn deinitCell(cell: *Cell, alloc: std.mem.Allocator) void {
    cell.text.deinit();
    if (cell.card) |card| card.deinit(alloc);
    cell.card = null;
    if (cell.tool) |*tm| tm.deinit(alloc);
    cell.tool = null;
}

fn dupeCard(
    alloc: std.mem.Allocator,
    version: []const u8,
    model: []const u8,
    think: []const u8,
    cwd: []const u8,
    session: []const u8,
    perms: []const u8,
    context: []const u8,
    usage: []const u8,
) !CardFields {
    const v = try alloc.dupe(u8, version);
    errdefer alloc.free(v);
    const m = try alloc.dupe(u8, model);
    errdefer alloc.free(m);
    const th = try alloc.dupe(u8, think);
    errdefer alloc.free(th);
    const d = try alloc.dupe(u8, cwd);
    errdefer alloc.free(d);
    const s = try alloc.dupe(u8, session);
    errdefer alloc.free(s);
    const p = try alloc.dupe(u8, perms);
    errdefer alloc.free(p);
    const c = try alloc.dupe(u8, context);
    errdefer alloc.free(c);
    const u = try alloc.dupe(u8, usage);
    errdefer alloc.free(u);
    return .{ .version = v, .model = m, .think = th, .cwd = d, .session = s, .perms = p, .context = c, .usage = u };
}

fn dupeSession(alloc: std.mem.Allocator, info: SessionInfo) !CardFields {
    return dupeCard(alloc, info.version, info.model, info.think, info.cwd, info.session, "", "", "");
}

fn dupeStatus(alloc: std.mem.Allocator, info: StatusInfo) !CardFields {
    return dupeCard(alloc, info.version, info.model, info.think, info.cwd, info.session, info.perms, info.context, info.usage);
}

fn paintCard(alloc: std.mem.Allocator, kind: CellKind, card: CardFields, width: usize) ![]u8 {
    return switch (kind) {
        .status_card => formatStatusCard(alloc, .{
            .version = card.version,
            .model = card.model,
            .think = card.think,
            .cwd = card.cwd,
            .session = card.session,
            .perms = card.perms,
            .context = card.context,
            .usage = card.usage,
        }, width),
        else => formatSessionCard(alloc, .{
            .version = card.version,
            .model = card.model,
            .think = card.think,
            .cwd = card.cwd,
            .session = card.session,
        }, width),
    };
}

fn cardSlice(cell: Cell, cards: []const []u8, card_i: *usize) []const u8 {
    if (cell.card == null) return "";
    if (card_i.* >= cards.len) return "";
    const s = cards[card_i.*];
    card_i.* += 1;
    return s;
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
fn gapBetween(prev: CellKind, next: CellKind) bool {
    if (next == .tool_end) return false;
    if ((prev == .tool or prev == .tool_end) and next == .tool) return false;
    if (next == .user or prev == .user) return true;
    const a = layerOf(prev);
    const b = layerOf(next);
    return a != .none and b != .none and a != b;
}

fn gutter(kind: CellKind) struct { first: []const u8, rest: []const u8, pad: usize } {
    return switch (kind) {
        // User: full-height bar on every line. No ┌/└ rows.
        .user => .{ .first = ANSI_BOLD ++ "▎ ", .rest = ANSI_BOLD ++ "▎ ", .pad = 2 },
        // Assistant is an open block: indent only, no bar.
        .assistant => .{ .first = "  ", .rest = "  ", .pad = 2 },
        // Think recedes: same indent, dim italic. No extra label row when open.
        .think => .{ .first = ANSI_DIM ++ ANSI_ITALIC ++ "  ", .rest = ANSI_DIM ++ ANSI_ITALIC ++ "  ", .pad = 2 },
        // Tool title: indent 4 + ▸. Status rides on this line.
        .tool => .{ .first = ANSI_DIM ++ "    ▸ " ++ ANSI_RESET, .rest = "      ", .pad = 6 },
        .tool_end => .{ .first = ANSI_DIM ++ "      └ ", .rest = ANSI_DIM ++ "        ", .pad = 8 },
        .session_header, .status_card, .chrome => .{ .first = "", .rest = "", .pad = 0 },
    };
}

fn gutterInner(kind: CellKind, width: usize) usize {
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

fn countContentLines(s: []const u8) usize {
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
    const ink = theme.fgStatus(paintStatus(meta.status));
    const ink_end: []const u8 = if (ink.len > 0) ANSI_RESET else "";
    if (meta.status == .running) {
        return std.fmt.bufPrint(buf, "{s} {s}", .{ outcome, et }) catch outcome;
    }
    return std.fmt.bufPrint(buf, "{s}{s}{s} {s} {d}ln", .{ ink, outcome, ink_end, et, meta.lines }) catch outcome;
}

fn toolTitle(meta: ToolMeta, buf: []u8, now_ms: i64) []const u8 {
    var sb: [64]u8 = undefined;
    const status = formatToolStatus(&sb, meta, now_ms);
    if (meta.preview.len == 0) {
        return std.fmt.bufPrint(buf, "{s}{s}{s}  {s}", .{
            ANSI_BOLD, meta.name, ANSI_RESET, status,
        }) catch meta.name;
    }
    return std.fmt.bufPrint(buf, "{s}{s}{s}  {s}{s}{s}  {s}", .{
        ANSI_BOLD, meta.name, ANSI_RESET, ANSI_DIM, meta.preview, ANSI_RESET, status,
    }) catch meta.name;
}

const TOOL_HEAD_PREFIX = ANSI_DIM ++ "    ▸ " ++ ANSI_RESET;
const TOOL_HEAD_REST = "      ";
const TOOL_BODY_FIRST = ANSI_DIM ++ "      │ ";
const TOOL_BODY_LAST = ANSI_DIM ++ "      └ ";
const TOOL_BODY_REST = ANSI_DIM ++ "        ";
const TOOL_BODY_PAD: usize = 8;

fn toolBodyInner(width: usize) usize {
    return if (width > TOOL_BODY_PAD) width - TOOL_BODY_PAD else 1;
}

fn toolRowCount(meta: ToolMeta, width: usize) usize {
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

fn paintStatus(s: ToolStatus) theme_mod.PaintStatus {
    return switch (s) {
        .running => .running,
        .ok => .ok,
        .err => .err,
    };
}

fn styleMd(alloc: std.mem.Allocator, kind: CellKind, text: []const u8) Styled {
    if (kind != .user and kind != .assistant) return .{ .text = text };
    if (text.len == 0 or theme.mode == .none) return .{ .text = text };
    const painted = markdown.render(alloc, &theme, text) catch return .{ .text = text };
    return .{ .owned = painted, .text = painted };
}

fn userRowCount(text: []const u8, width: usize) usize {
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

fn emitTool(wr: *std.Io.Writer, meta: ToolMeta, width: usize, skip: usize, limit: usize) !usize {
    if (limit == 0) return 0;
    var skipped = skip;
    var emitted: usize = 0;
    var tb: [512]u8 = undefined;
    const title = toolTitle(meta, &tb, nowMs());
    try emitPrefixed(wr, TOOL_HEAD_PREFIX, TOOL_HEAD_REST, title, gutterInner(.tool, width), &skipped, &emitted, limit, theme.bgTool(paintStatus(meta.status)));
    if (meta.folded) {
        // pi 式折叠尾行:体有未尽之行则缀 `· (N more lines, ctrl+o)`
        const view = bodyView(meta.body.items);
        if (view.len > 0) {
            const n = countContentLines(view);
            if (n > 2) {
                var tail_buf: [48]u8 = undefined;
                const tail = std.fmt.bufPrint(&tail_buf, ANSI_DIM ++ "· ({d} more lines, ctrl+o)" ++ ANSI_RESET, .{n - 2}) catch "· (more, ctrl+o)";
                try emitPrefixed(wr, "    ", "    ", tail, width -| 4, &skipped, &emitted, limit, theme.bgTool(paintStatus(meta.status)));
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
            var i: usize = 0;
            while (it.next()) |part| {
                i += 1;
                const first = if (i == nlines) TOOL_BODY_LAST else TOOL_BODY_FIRST;
                try emitPrefixed(wr, first, TOOL_BODY_REST, part, inner, &skipped, &emitted, limit, "");
            }
        }
    }
    return emitted;
}

fn emitUser(wr: *std.Io.Writer, text: []const u8, width: usize, skip: usize, limit: usize) !usize {
    if (limit == 0) return 0;
    var skipped = skip;
    var emitted: usize = 0;
    const g = gutter(.user);
    const inner = gutterInner(.user, width);
    // bg + bold 一并作 band:Markdown 中途 RESET 后 writeReband 复披,行内强调后仍粗
    var band_buf: [48]u8 = undefined;
    const bg = theme.bgUser();
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

fn cellRowCount(alloc: std.mem.Allocator, cell: Cell, painted: []const u8, think_open: bool, width: usize) usize {
    if (cell.kind == .session_header or cell.kind == .status_card) {
        if (painted.len == 0) return 0;
        return countNewlines(painted) + 1;
    }
    const md = styleMd(alloc, cell.kind, cell.text.items);
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

fn emitCell(alloc: std.mem.Allocator, wr: *std.Io.Writer, cell: Cell, painted: []const u8, think_open: bool, width: usize, skip: usize, limit: usize) !usize {
    if (limit == 0) return 0;
    if (cell.kind == .session_header or cell.kind == .status_card) {
        return emitPainted(wr, painted, width, skip, limit);
    }
    const md = styleMd(alloc, cell.kind, cell.text.items);
    defer md.deinit(alloc);
    if (cell.kind == .user) {
        return emitUser(wr, md.text, width, skip, limit);
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
        emitted += try emitWrappedGutter(wr, first_g, g.rest, part, inner, local, limit - emitted, "");
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

fn skipAnsi(s: []const u8, i: usize) usize {
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
fn isWideCp(cp: u21) bool {
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
        0x1F300...0x1F64F => true,
        0x1F900...0x1F9FF => true,
        0x20000...0x3FFFD => true,
        else => false,
    };
}

fn charCols(s: []const u8, i: usize) struct { n: usize, cols: usize } {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    const take = @min(n, s.len - i);
    if (take < n) return .{ .n = take, .cols = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + take]) catch return .{ .n = take, .cols = 1 };
    return .{ .n = take, .cols = if (isWideCp(cp)) 2 else 1 };
}
fn visibleCols(s: []const u8) usize {
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

fn truncateToVisible(s: []const u8, max_cols: usize) []const u8 {
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

fn ellipsizeAlloc(alloc: std.mem.Allocator, s: []const u8, max_cols: usize) ![]u8 {
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

fn joinN(alloc: std.mem.Allocator, parts: []const []const u8, sep: []const u8) ![]u8 {
    var w = std.Io.Writer.Allocating.init(alloc);
    errdefer w.deinit();
    for (parts, 0..) |p, i| {
        if (i > 0) try w.writer.writeAll(sep);
        try w.writer.writeAll(p);
    }
    return w.toOwnedSlice();
}

fn wrapRowCount(line: []const u8, width: usize) usize {
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

const CsiKey = enum { up, down, left, right, home, end, delete, page_up, page_down, shift_up, shift_down, ctrl_up, ctrl_down, other };

fn csiMod(params: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, params, ';')) |i| return params[i + 1 ..];
    return params;
}

fn csiShift(params: []const u8) bool {
    return std.mem.eql(u8, csiMod(params), "2");
}

fn csiCtrl(params: []const u8) bool {
    return std.mem.eql(u8, csiMod(params), "5");
}

const WheelDir = enum { up, down };

fn consumeSameCsi(bytes: []const u8, i: *usize, params: []const u8, final: u8) usize {
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

fn sgrWheel(params: []const u8) ?WheelDir {
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

fn classifyCsi(params: []const u8, final: u8) CsiKey {
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

fn thinkRowCount(buf: []const u8, open: bool, width: usize) usize {
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
        try emitFrameLine(wr, ANSI_DIM ++ ANSI_ITALIC ++ "  · thought" ++ ANSI_RESET, &skipped, &emitted, limit);
        return emitted;
    }
    const g = gutter(.think);
    const inner = gutterInner(.think, width);
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |p| {
        try emitPrefixed(wr, g.first, g.rest, p, inner, &skipped, &emitted, limit, "");
        if (emitted >= limit) return emitted;
    }
    return emitted;
}

fn wrapCursor(s: []const u8, cursor: usize, width: usize) struct { row: usize, col: usize } {
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

fn emitComposer(wr: *std.Io.Writer, input: []const u8, inner: usize, rows: usize, skip: usize) !void {
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

fn paintComposerBox(alloc: std.mem.Allocator, input: []const u8, cols: usize, inner_rows: usize, skip: usize) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    errdefer aw.deinit();
    const box_w = composerBoxWidth(cols);
    const inner = composerInnerWidth(true, cols);
    try writeBoxEdge(&aw.writer, "╭", "╮", box_w);
    try emitComposer(&aw.writer, input, inner, inner_rows, skip);
    try writeBoxEdge(&aw.writer, "╰", "╯", box_w);
    return aw.toOwnedSlice();
}

fn writeHighlighted(wr: *std.Io.Writer, text: []const u8, hl_from: usize, hl_len: usize, width: usize) !void {
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

fn writeSlashPicker(wr: *std.Io.Writer, items: []const SlashItem, query: []const u8, sel: *usize, height: usize, width: usize) !void {
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

fn writePicker(wr: *std.Io.Writer, p: *Picker, height: usize, width: usize) !void {
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

fn writeStatusIndicator(wr: *std.Io.Writer, views: []const activity.View, streaming: bool, frame_ms: i64, width: usize, max_rows: usize) !void {
    _ = streaming;
    if (max_rows == 0) return;
    var elapsed: i64 = 0;
    for (views) |v| {
        if (!v.detached and v.elapsed_ms > elapsed) elapsed = v.elapsed_ms;
    }
    var eb: [24]u8 = undefined;
    const el = activity.formatElapsed(&eb, elapsed);
    try wr.writeAll(ANSI_DIM);
    try wr.writeAll(activity.spinnerFrame(frame_ms));
    try wr.writeAll(ANSI_RESET ++ " Working " ++ ANSI_DIM ++ "(");
    try wr.writeAll(el);
    try wr.writeAll(" • esc to interrupt)" ++ ANSI_RESET ++ "\x1b[K\r\n");
    if (max_rows == 1) return;
    const cap = @min(views.len, @min(@as(usize, 2), max_rows - 1));
    var i: usize = 0;
    while (i < cap) : (i += 1) {
        const v = views[i];
        try wr.writeAll(ANSI_DIM ++ " └ " ++ ANSI_RESET);
        var used: usize = 3;
        try writeTrunc(wr, v.name, if (width > used) width - used else 0);
        used += visibleCols(v.name);
        if (v.detail.len > 0 and used + 3 < width) {
            try wr.writeAll(ANSI_DIM ++ "  ");
            used += 2;
            try writeTrunc(wr, v.detail, width - used);
        }
        try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
    }
}

fn writeBoxEdge(wr: *std.Io.Writer, left: []const u8, right: []const u8, width: usize) !void {
    try wr.writeAll(ANSI_DIM);
    try wr.writeAll(left);
    const dashes = if (width > 2) width - 2 else 0;
    var i: usize = 0;
    while (i < dashes) : (i += 1) try wr.writeAll("─");
    try wr.writeAll(right);
    try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
}

fn writeTrunc(wr: *std.Io.Writer, s: []const u8, width: usize) !void {
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
        .subagent => "agent",
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

fn deleteUtf8Before(buf: *std.array_list.Managed(u8), cursor: *usize) void {
    if (cursor.* == 0 or cursor.* > buf.items.len) return;
    const w = utf8PrevLen(buf.items, cursor.*);
    const start = cursor.* - w;
    var k: usize = 0;
    while (k < w) : (k += 1) {
        _ = buf.orderedRemove(start);
    }
    cursor.* = start;
}

fn deleteUtf8At(buf: *std.array_list.Managed(u8), cursor: usize) void {
    if (cursor >= buf.items.len) return;
    const w = utf8LenAt(buf.items, cursor);
    var k: usize = 0;
    while (k < w) : (k += 1) {
        _ = buf.orderedRemove(cursor);
    }
}

fn utf8PrevLen(s: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0) {
        i -= 1;
        if (s[i] & 0xC0 != 0x80) {
            return pos - i;
        }
    }
    return 1;
}

fn utf8LenAt(s: []const u8, pos: usize) usize {
    if (pos >= s.len) return 1;
    return std.unicode.utf8ByteSequenceLength(s[pos]) catch 1;
}

fn stripForTest(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < s.len) {
        const next = skipAnsi(s, i);
        if (next != i) {
            i = next;
            continue;
        }
        if (s[i] == '\r') {
            i += 1;
            continue;
        }
        try out.append(s[i]);
        i += 1;
    }
    // 色带补白留尾空格:剥码后逐行修剪,免扰纯文断言
    var trimmed = std.array_list.Managed(u8).init(alloc);
    errdefer trimmed.deinit();
    var it = std.mem.splitScalar(u8, out.items, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try trimmed.append('\n');
        first = false;
        try trimmed.appendSlice(std.mem.trimEnd(u8, line, " "));
    }
    out.deinit();
    return trimmed.toOwnedSlice();
}

fn footerPlain(alloc: std.mem.Allocator, ident: FooterIdent, hint: ?[]const u8, width: usize, two_rows: bool) ![]u8 {
    const rows = try formatFooterRows(alloc, ident, hint, width, two_rows);
    defer rows.deinit(alloc);
    const p = try stripForTest(alloc, rows.primary);
    defer alloc.free(p);
    const s = try stripForTest(alloc, rows.secondary);
    defer alloc.free(s);
    if (s.len == 0) return alloc.dupe(u8, p);
    return std.fmt.allocPrint(alloc, "{s}\n{s}", .{ p, s });
}

fn countNonEmptyLines(plain: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, plain, '\n');
    while (it.next()) |line| {
        if (line.len > 0) n += 1;
    }
    return n;
}

fn lineIndent(plain: []const u8, needle: []const u8) ?usize {
    const at = std.mem.indexOf(u8, plain, needle) orelse return null;
    var start = at;
    while (start > 0 and plain[start - 1] != '\n') start -= 1;
    var n: usize = 0;
    while (start + n < plain.len and plain[start + n] == ' ') n += 1;
    return n;
}

test "gutters are unique and not baked into cells" {
    const t = std.testing;
    try t.expect(std.mem.indexOf(u8, gutter(.user).first, "▎") != null);
    try t.expect(std.mem.indexOf(u8, gutter(.user).first, "› ") == null);
    try t.expect(std.mem.indexOf(u8, gutter(.user).first, ANSI_BOLD) != null);
    try t.expect(std.mem.indexOf(u8, gutter(.user).first, ANSI_ITALIC) == null);
    try t.expect(std.mem.indexOf(u8, gutter(.user).first, ANSI_DIM) == null);
    try t.expectEqualStrings("  ", gutter(.assistant).first);
    try t.expect(std.mem.indexOf(u8, gutter(.assistant).first, "▎") == null);
    try t.expect(std.mem.indexOf(u8, gutter(.assistant).first, "┌") == null);
    try t.expect(std.mem.indexOf(u8, gutter(.tool).first, "▸") != null);
    try t.expect(std.mem.indexOf(u8, gutter(.tool).first, "┌") == null);
    try t.expect(gutter(.tool).pad > gutter(.assistant).pad);
    try t.expect(std.mem.indexOf(u8, gutter(.think).first, ANSI_ITALIC) != null);
    try t.expect(std.mem.indexOf(u8, gutter(.think).first, ANSI_DIM) != null);
    try t.expect(std.mem.indexOf(u8, gutter(.tool_end).first, "└ ") != null);
    try t.expectEqual(@as(usize, 2), gutter(.user).pad);
    try t.expectEqual(@as(usize, 2), gutter(.assistant).pad);
    try t.expectEqual(@as(usize, 6), gutter(.tool).pad);
    try t.expectEqual(@as(usize, 8), gutter(.tool_end).pad);
    try t.expectEqual(@as(usize, 0), gutter(.chrome).pad);
    try t.expectEqual(@as(usize, 78), gutterInner(.user, 80));
    try t.expectEqual(@as(usize, 74), gutterInner(.tool, 80));
    try t.expectEqual(@as(usize, 80), gutterInner(.chrome, 80));

    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendUser("hello");
    try ui.appendText("world");
    try ui.appendThink("hmm");
    try ui.appendTool("bash", "ls");
    try ui.appendToolEnd("bash", false, "4B");
    for (ui.cells.items) |c| {
        try t.expect(std.mem.indexOf(u8, c.text.items, "› ") == null);
        try t.expect(std.mem.indexOf(u8, c.text.items, "• ") == null);
        try t.expect(std.mem.indexOf(u8, c.text.items, "└ ") == null);
    }
    try t.expect(ui.cells.items[0].kind == .user);
    try t.expectEqualStrings("hello", ui.cells.items[0].text.items);
    try t.expect(ui.cells.items[1].kind == .assistant);
    try t.expectEqualStrings("world", ui.cells.items[1].text.items);
}

test "mouse modes follow Codex: 1007 not 1000" {
    const t = std.testing;
    try t.expect(std.mem.indexOf(u8, ENTER_ALT_SCROLL, "1007h") != null);
    try t.expect(std.mem.indexOf(u8, ENTER_ALT_SCROLL, "1000") == null);
    try t.expect(std.mem.indexOf(u8, ENTER_ALT_SCROLL, "1006") == null);
    try t.expect(std.mem.indexOf(u8, LEAVE_ALT_SCROLL, "1007l") != null);
}

test "Codex blank-line rhythm between layers" {
    const t = std.testing;
    try t.expect(gapBetween(.session_header, .user));
    try t.expect(gapBetween(.user, .think));
    try t.expect(gapBetween(.user, .assistant));
    try t.expect(gapBetween(.think, .assistant));
    try t.expect(gapBetween(.assistant, .tool));
    try t.expect(gapBetween(.tool_end, .assistant));
    try t.expect(gapBetween(.assistant, .chrome));
    try t.expect(!gapBetween(.tool, .tool_end));
    try t.expect(!gapBetween(.tool, .tool));
    try t.expect(!gapBetween(.tool_end, .tool));
    try t.expect(!gapBetween(.assistant, .assistant));
}

test "painted roles differ by layer" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendUser("hello");
    try ui.appendThink("hmm");
    try ui.appendText("world");
    try ui.appendTool("bash", "ls");
    try ui.appendToolEnd("bash", false, "4B");
    try ui.appendLine("", "\x1b[2m", "notice");

    const out = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(out);
    const plain = try stripForTest(t.allocator, out);
    defer t.allocator.free(plain);

    try t.expect(std.mem.indexOf(u8, plain, "┌ user") == null);
    try t.expect(std.mem.indexOf(u8, plain, "▎ hello") != null);
    try t.expect(std.mem.indexOf(u8, plain, "▎ world") == null);
    try t.expect(std.mem.indexOf(u8, plain, "  thought") == null);
    try t.expect(std.mem.indexOf(u8, plain, "  hmm") != null);
    try t.expect(std.mem.indexOf(u8, plain, "  world") != null);
    try t.expect(std.mem.indexOf(u8, plain, "    ▸ bash  ls") != null);
    try t.expect(std.mem.indexOf(u8, plain, "ok") != null);
    try t.expect(std.mem.indexOf(u8, plain, "▎ hello\n\n  hmm") != null);
    try t.expect(std.mem.indexOf(u8, plain, "  hmm\n\n  world") != null);
    try t.expect(std.mem.indexOf(u8, plain, "  world\n\n    ▸ bash  ls") != null);
    try t.expect(std.mem.indexOf(u8, plain, "notice") != null);

    try t.expectEqual(@as(usize, 0), lineIndent(plain, "hello").?);
    try t.expectEqual(@as(usize, 2), lineIndent(plain, "hmm").?);
    try t.expectEqual(@as(usize, 2), lineIndent(plain, "world").?);
    try t.expectEqual(@as(usize, 4), lineIndent(plain, "bash").?);
    try t.expect(lineIndent(plain, "bash").? > lineIndent(plain, "world").?);

    try t.expect(std.mem.indexOf(u8, gutter(.user).first, ANSI_ITALIC) == null);
    try t.expect(std.mem.indexOf(u8, gutter(.user).first, ANSI_BOLD) != null);
    try t.expect(std.mem.indexOf(u8, gutter(.think).first, ANSI_ITALIC) != null);
    try t.expect(std.mem.indexOf(u8, gutter(.think).first, ANSI_DIM) != null);
    try t.expect(std.mem.indexOf(u8, out, ANSI_ITALIC) != null);
    try t.expect(std.mem.indexOf(u8, out, ANSI_BOLD ++ "▎ ") != null);
    try t.expect(std.mem.indexOf(u8, out, ANSI_BOLD ++ "bash") != null);
    try t.expect(std.mem.indexOf(u8, out, ANSI_DIM ++ "ls") != null);
    try t.expect(std.mem.indexOf(u8, out, ANSI_DIM ++ ANSI_ITALIC) != null);
}

fn paintCellsForTest(alloc: std.mem.Allocator, ui: *Tui, width: usize) ![]u8 {
    var cards = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (cards.items) |s| alloc.free(s);
        cards.deinit();
    }
    for (ui.cells.items) |c| {
        if (c.card) |card| {
            try cards.append(try paintCard(alloc, c.kind, card, width));
        }
    }
    var fw = std.Io.Writer.Allocating.init(alloc);
    errdefer fw.deinit();
    var card_i: usize = 0;
    var ci: usize = 0;
    while (ci < ui.cells.items.len) : (ci += 1) {
        if (ci > 0 and gapBetween(ui.cells.items[ci - 1].kind, ui.cells.items[ci].kind)) {
            try fw.writer.writeAll("\x1b[K\r\n");
        }
        const painted = cardSlice(ui.cells.items[ci], cards.items, &card_i);
        _ = try emitCell(alloc, &fw.writer, ui.cells.items[ci], painted, true, width, 0, 64);
    }
    return fw.toOwnedSlice();
}

test "tool cells default folded with summary, not body" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendTool("read", "src/tui.zig");
    try t.expectEqual(@as(usize, 1), ui.cells.items.len);
    try t.expect(ui.cells.items[0].kind == .tool);
    try t.expect(ui.cells.items[0].tool.?.folded);
    try t.expect(ui.cells.items[0].tool.?.status == .running);

    try ui.appendToolEnd("read", false, "line one\nline two\nSECRET_BODY\n");
    try t.expectEqual(@as(usize, 1), ui.cells.items.len);
    try t.expect(ui.cells.items[0].kind == .tool);
    try t.expect(ui.cells.items[0].kind != .tool_end);
    const meta = ui.cells.items[0].tool.?;
    try t.expect(meta.folded);
    try t.expect(meta.status == .ok);
    try t.expectEqual(@as(usize, 3), meta.lines);
    try t.expectEqualStrings("src/tui.zig", meta.preview);

    const out = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(out);
    const plain = try stripForTest(t.allocator, out);
    defer t.allocator.free(plain);
    try t.expect(std.mem.indexOf(u8, plain, "    ▸ read  src/tui.zig") != null);
    try t.expect(std.mem.indexOf(u8, plain, "ok") != null);
    try t.expect(std.mem.indexOf(u8, plain, "3ln") != null);
    try t.expect(std.mem.indexOf(u8, plain, "SECRET_BODY") == null);
    try t.expect(std.mem.indexOf(u8, plain, "SECRET") == null);
    try t.expect(countNonEmptyLines(plain) <= 2);
}

test "Ctrl+O expands and folds tool body" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendTool("bash", "zig build test");
    try ui.appendToolEnd("bash", false, "ok line\nSECRET_BODY\n");
    try t.expect(ui.cells.items[0].tool.?.folded);

    _ = try ui.handleInput(&.{0x0f});
    try t.expect(!ui.cells.items[0].tool.?.folded);
    const expanded = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(expanded);
    const exp_plain = try stripForTest(t.allocator, expanded);
    defer t.allocator.free(exp_plain);
    try t.expect(std.mem.indexOf(u8, exp_plain, "    ▸ bash  zig build test") != null);
    try t.expect(std.mem.indexOf(u8, exp_plain, "ok") != null);
    try t.expect(std.mem.indexOf(u8, exp_plain, "      │ ok line") != null);
    try t.expect(std.mem.indexOf(u8, exp_plain, "      └ SECRET_BODY") != null);

    ui.toggleTools();
    try t.expect(ui.cells.items[0].tool.?.folded);
    const folded = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(folded);
    const fold_plain = try stripForTest(t.allocator, folded);
    defer t.allocator.free(fold_plain);
    try t.expect(std.mem.indexOf(u8, fold_plain, "SECRET_BODY") == null);
}

test "sibling tools have no user-sized gap" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendUser("do work");
    try ui.appendTool("bash", "ls");
    try ui.appendToolEnd("bash", false, "a\n");
    try ui.appendTool("read", "src/tui.zig");
    try ui.appendToolEnd("read", true, "missing\n");
    try t.expectEqual(@as(usize, 3), ui.cells.items.len);
    try t.expect(!gapBetween(.tool, .tool));
    try t.expect(gapBetween(.user, .tool));

    const out = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(out);
    const plain = try stripForTest(t.allocator, out);
    defer t.allocator.free(plain);
    try t.expect(std.mem.indexOf(u8, plain, "▎ do work\n\n    ▸ bash  ls") != null);
    try t.expect(std.mem.indexOf(u8, plain, "▸ bash  ls") != null);
    try t.expect(std.mem.indexOf(u8, plain, "▸ read  src/tui.zig") != null);
    try t.expect(std.mem.indexOf(u8, plain, "err") != null);
    try t.expect(std.mem.indexOf(u8, plain, "missing") == null);
    try t.expect(std.mem.indexOf(u8, plain, "▸ bash  ls\n\n    ▸ read") == null);
}

test "consumeSameCsi counts a wheel burst" {
    const t = std.testing;
    const burst = "\x1b[A\x1b[A\x1b[A";
    var i: usize = 3;
    try t.expectEqual(@as(usize, 2), consumeSameCsi(burst, &i, "", 'A'));
    try t.expectEqual(@as(usize, burst.len), i);
    var j: usize = 3;
    try t.expectEqual(@as(usize, 0), consumeSameCsi("\x1b[A\x1b[B", &j, "", 'A'));
}

test "utf8 helpers" {
    const t = std.testing;
    const s = "a中b";
    try t.expectEqual(@as(usize, 1), utf8LenAt(s, 0));
    try t.expectEqual(@as(usize, 3), utf8LenAt(s, 1));
    try t.expectEqual(@as(usize, 3), utf8PrevLen(s, 4));
    try t.expectEqual(@as(usize, 1), utf8PrevLen(s, 1));
}

test "backspace deletes one CJK codepoint without OOB" {
    const t = std.testing;
    var buf = std.array_list.Managed(u8).init(t.allocator);
    defer buf.deinit();
    try buf.appendSlice("你好");
    var cursor: usize = buf.items.len;
    deleteUtf8Before(&buf, &cursor);
    try t.expectEqualStrings("你", buf.items);
    try t.expectEqual(@as(usize, 3), cursor);
    deleteUtf8Before(&buf, &cursor);
    try t.expectEqualStrings("", buf.items);
    try t.expectEqual(@as(usize, 0), cursor);
    deleteUtf8Before(&buf, &cursor);
    try t.expectEqual(@as(usize, 0), cursor);
}

test "soft wrap counts CJK columns and does not truncate" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 1), wrapRowCount("hello", 80));
    try t.expectEqual(@as(usize, 2), wrapRowCount("0123456789", 5));
    try t.expectEqual(@as(usize, 1), wrapRowCount("工作目录是哪里啊", 20));
    try t.expectEqual(@as(usize, 2), wrapRowCount("工作目录是哪里啊", 8));
    try t.expectEqual(@as(usize, 1), thinkRowCount("abc", false, 80));
    try t.expectEqual(@as(usize, 1), thinkRowCount("abc", true, 80));
    try t.expect(classifyThink(0) == .off);
    try t.expect(classifyThink(100) == .low);
    try t.expect(classifyThink(800) == .medium);
    try t.expect(classifyThink(4000) == .max);
}

test "CSI shift arrows and delete" {
    const t = std.testing;
    try t.expect(classifyCsi("", 'A') == .up);
    try t.expect(classifyCsi("", 'B') == .down);
    try t.expect(classifyCsi("1;2", 'A') == .shift_up);
    try t.expect(classifyCsi("1;2", 'B') == .shift_down);
    try t.expect(classifyCsi("2", 'A') == .shift_up);
    try t.expect(classifyCsi("3", '~') == .delete);
    try t.expect(classifyCsi("5", '~') == .page_up);
    try t.expect(classifyCsi("6", '~') == .page_down);
    try t.expect(classifyCsi("1;5", 'A') == .ctrl_up);
    try t.expect(classifyCsi("1;5", 'B') == .ctrl_down);
    try t.expect(classifyCsi("", 'H') == .home);
    try t.expect(sgrWheel("<64;10;5") == .up);
    try t.expect(sgrWheel("<65;10;5") == .down);
    try t.expect(sgrWheel("<80;1;1") == .up);
    try t.expect(sgrWheel("<0;1;1") == null);
}

test "footer hint wins over status" {
    const t = std.testing;
    try t.expectEqualStrings("y allow  n deny  a always  s skip", footerHint(.{ .perm = true, .picker = true, .quit_armed = true }).?);
    try t.expectEqualStrings("up/down select  enter confirm  esc cancel", footerHint(.{ .picker = true, .quit_armed = true }).?);
    try t.expectEqualStrings("ctrl+c again to quit", footerHint(.{ .quit_armed = true, .esc_armed = true }).?);
    try t.expectEqualStrings("esc again to edit last", footerHint(.{ .esc_armed = true, .scrolled = true }).?);
    try t.expectEqualStrings("pgup/pgdn to scroll", footerHint(.{ .scrolled = true }).?);
    try t.expectEqualStrings("up/down select  tab complete  enter run", footerHint(.{ .slash = true }).?);
    try t.expectEqualStrings("? for shortcuts", footerHint(.{}).?);
    try t.expectEqualStrings("tab to queue", footerHint(.{ .has_draft = true, .running = true }).?);
    try t.expect(footerHint(.{ .has_draft = true }) == null);
}

test "layoutFooter keeps context on the right" {
    const t = std.testing;
    const a = try layoutFooter(t.allocator, "? for shortcuts", "12%", 24);
    defer t.allocator.free(a);
    try t.expectEqualStrings("? for shortcuts      12%", a);
    const b = try layoutFooter(t.allocator, "? for shortcuts", "12%", 10);
    defer t.allocator.free(b);
    try t.expectEqualStrings("? for shor", b);
    const c = try layoutFooter(t.allocator, null, "12%", 8);
    defer t.allocator.free(c);
    try t.expectEqualStrings("     12%", c);
}

test "footer identity has hierarchy and never drops model" {
    const t = std.testing;
    const ident = FooterIdent{
        .model = "deepseek/v4-flash",
        .think = "max",
        .cwd = "~/桌面",
        .session = "1786748577703",
        .used = 12_000,
        .window = 128_000,
        .cache_read = 7_440,
        .prompt = 12_000,
        .tok_in = 4_700,
        .tok_out = 44,
        .tok_cache_r = 7_440,
        .cost = 0.009,
        .pct = 9,
    };
    const rows = try formatFooterRows(t.allocator, ident, "? for shortcuts", 80, true);
    defer rows.deinit(t.allocator);
    const primary = try stripForTest(t.allocator, rows.primary);
    defer t.allocator.free(primary);
    const secondary = try stripForTest(t.allocator, rows.secondary);
    defer t.allocator.free(secondary);
    // pi 式:行 1 = cwd (+branch),hint 右端;行 2 = stats 左,model · think 右
    try t.expect(std.mem.indexOf(u8, primary, "~/桌面") != null);
    try t.expect(std.mem.indexOf(u8, primary, "? for shortcuts") != null);
    try t.expect(std.mem.indexOf(u8, secondary, "deepseek/v4-flash · max") != null);
    try t.expect(std.mem.indexOf(u8, secondary, "ctx 9% 12k/128k") != null);
    try t.expect(std.mem.indexOf(u8, secondary, "R7.4k") != null);
    try t.expect(std.mem.indexOf(u8, secondary, "↑4.7k ↓44") != null);
    // pi 式:$ 三位小数 + CH 命中率(7440/12000)
    try t.expect(std.mem.indexOf(u8, secondary, "$0.009") != null);
    try t.expect(std.mem.indexOf(u8, secondary, "CH62%") != null);
    try t.expect(std.mem.indexOf(u8, rows.secondary, ANSI_BOLD ++ "deepseek/v4-flash") != null);
    // 宽 >= 50 恒双行,窄端单行
    try t.expect(footerNeedsTwoRows(ident, "? for shortcuts", 80));
    try t.expect(footerNeedsTwoRows(ident, "? for shortcuts", 120));
    try t.expect(!footerNeedsTwoRows(ident, "? for shortcuts", 49));

    const wide_rows = try formatFooterRows(t.allocator, ident, "? for shortcuts", 120, true);
    defer wide_rows.deinit(t.allocator);
    const wide_s = try stripForTest(t.allocator, wide_rows.secondary);
    defer t.allocator.free(wide_s);
    try t.expect(std.mem.indexOf(u8, wide_s, "deepseek/v4-flash") != null);
    try t.expect(std.mem.indexOf(u8, wide_s, "ctx 9% 12k/128k") != null);

    // branch 缀于行 1 cwd 后
    var with_branch = ident;
    with_branch.branch = "main";
    const br_rows = try formatFooterRows(t.allocator, with_branch, null, 80, true);
    defer br_rows.deinit(t.allocator);
    const br_p = try stripForTest(t.allocator, br_rows.primary);
    defer t.allocator.free(br_p);
    try t.expect(std.mem.indexOf(u8, br_p, "~/桌面 (main)") != null);

    // 窄端(<50)退化为单行挤排,model 不弃
    const tight = try formatFooterRows(t.allocator, ident, "? for shortcuts", 18, true);
    defer tight.deinit(t.allocator);
    const tight_p = try stripForTest(t.allocator, tight.primary);
    defer t.allocator.free(tight_p);
    try t.expect(std.mem.indexOf(u8, tight_p, "deepseek") != null);
    try t.expectEqualStrings("", tight.secondary);

    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.setFooterIdentity(with_branch);
    try t.expectEqual(@as(usize, 0), ui.cells.items.len);
    try t.expect(ui.footer_model.items.len > 0);
    try t.expectEqualStrings("main", ui.footer_branch.items);
}

test "footer pi-style: place row 1, stats/model row 2; narrow packs" {
    const t = std.testing;
    const ident = FooterIdent{
        .model = "deepseek/v4-flash",
        .think = "max",
        .cwd = "~/project/pi-zig",
        .session = "1786748577703",
        .used = 12_000,
        .window = 128_000,
        .cache_read = 7_440,
        .prompt = 12_000,
        .tok_in = 4_700,
        .tok_out = 44,
        .tok_cache_r = 7_440,
        .pct = 9,
    };
    const hint = "? for shortcuts";
    const widths = [_]usize{ 80, 120 };
    for (widths) |cols| {
        const plain = try footerPlain(t.allocator, ident, hint, cols, true);
        defer t.allocator.free(plain);
        // pi 式双行:行 1 地点 + hint,行 2 stats + model · think
        try t.expect(std.mem.indexOf(u8, plain, "\n") != null);
        try t.expect(std.mem.indexOf(u8, plain, "~/project/pi-zig") != null);
        try t.expect(std.mem.indexOf(u8, plain, hint) != null);
        try t.expect(std.mem.indexOf(u8, plain, "deepseek/v4-flash · max") != null);
        try t.expect(std.mem.indexOf(u8, plain, "ctx 9% 12k/128k") != null);
    }

    // 窄端打包单行:cwd 与 model 皆在
    const packed90 = try footerPlain(t.allocator, ident, hint, 90, false);
    defer t.allocator.free(packed90);
    try t.expect(std.mem.indexOf(u8, packed90, "\n") == null);
    try t.expect(std.mem.indexOf(u8, packed90, "~/project/pi-zig") != null);
    try t.expect(std.mem.indexOf(u8, packed90, "deepseek/v4-flash") != null);

    const long_ident = FooterIdent{
        .model = "m",
        .cwd = "~/abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz",
        .session = "123",
    };
    const squeezed = try footerPlain(t.allocator, long_ident, hint, 36, true);
    defer t.allocator.free(squeezed);
    try t.expect(std.mem.indexOf(u8, squeezed, "~/") != null);
    try t.expect(std.mem.indexOf(u8, squeezed, "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz") == null);

    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.setFooterIdentity(ident);
    for (widths) |cols| {
        ui.width = cols;
        ui.height = 24;
        const bottom = ui.measureBottom(0, false);
        try t.expect(bottom.composer_rows >= 3);
        try t.expectEqual(composerBoxWidth(cols), if (cols > 1) cols - 1 else cols);
        try t.expectEqual(@as(usize, 2), bottom.footer_ident_rows);
        const painted = try footerPlain(t.allocator, ident, hint, cols, bottom.footer_ident_rows >= 2);
        defer t.allocator.free(painted);
        try t.expect(std.mem.indexOf(u8, painted, "~/project/pi-zig") != null);
    }
}

test "session card renders at paint width" {
    const t = std.testing;
    const info = SessionInfo{
        .version = "0.1.0",
        .model = "deepseek/flash",
        .think = "high",
        .cwd = "~/pi-zig",
        .session = "1786735635034",
    };
    const wide = try formatSessionCard(t.allocator, info, 80);
    defer t.allocator.free(wide);
    const narrow = try formatSessionCard(t.allocator, info, 40);
    defer t.allocator.free(narrow);
    try t.expect(std.mem.indexOf(u8, wide, "╭") != null);
    try t.expect(std.mem.indexOf(u8, wide, "╰") != null);
    try t.expect(std.mem.indexOf(u8, wide, ">_ ") != null);
    try t.expect(std.mem.indexOf(u8, wide, "piz") != null);
    try t.expect(std.mem.indexOf(u8, wide, "model:") != null);
    try t.expect(std.mem.indexOf(u8, wide, "deepseek/flash") != null);
    try t.expect(std.mem.indexOf(u8, wide, "/model") != null);
    try t.expect(std.mem.indexOf(u8, wide, "/status") != null);
    try t.expect(std.mem.indexOf(u8, wide, "1786735635034") != null);
    try t.expect(std.mem.indexOf(u8, wide, ANSI_BOLD ++ "piz") != null);
    try t.expect(std.mem.indexOf(u8, wide, ANSI_BOLD ++ "deepseek/flash") != null);
    const wide_plain = try stripForTest(t.allocator, wide);
    defer t.allocator.free(wide_plain);
    try t.expect(std.mem.indexOf(u8, wide_plain, ">_ piz").? < std.mem.indexOf(u8, wide_plain, "model:").?);
    try t.expect(std.mem.indexOf(u8, wide_plain, "model:").? < std.mem.indexOf(u8, wide_plain, "directory:").?);
    try t.expect(std.mem.indexOf(u8, wide_plain, "session:").? < std.mem.indexOf(u8, wide_plain, "/model").?);
    try t.expect(std.mem.indexOf(u8, narrow, "piz") != null);
    try t.expect(cardInner(80) == 56);
    try t.expect(cardInner(40) == 36);
    try t.expect(wide.len != narrow.len);

    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.setFooterIdentity(.{
        .model = info.model,
        .think = info.think,
        .cwd = info.cwd,
        .session = info.session,
        .pct = 12,
    });
    try t.expectEqual(@as(usize, 0), ui.cells.items.len);
    for (ui.cells.items) |c| try t.expect(c.kind != .session_header);

    try ui.appendUser("hi");
    try ui.appendTool("bash", "ls");
    try ui.appendToolEnd("bash", false, "SECRET_BODY\nmore\n");
    try ui.appendStatusCard(.{
        .version = "0.1.0",
        .model = "deepseek/flash",
        .think = "high",
        .cwd = "~/pi-zig",
        .session = "1786735635034",
        .perms = "yolo",
        .context = "AGENTS.md",
        .usage = "12%",
    });
    try t.expect(ui.cells.items[0].kind == .user);
    try t.expect(ui.cells.items[ui.cells.items.len - 1].kind == .status_card);
    try t.expect(cardInner(80) == 56);
    try t.expect(cardInner(8) > 0);
    try t.expect(cardInner(4) == 0);

    const painted = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(painted);
    const plain = try stripForTest(t.allocator, painted);
    defer t.allocator.free(plain);
    const card_at = std.mem.indexOf(u8, plain, "╭");
    const tool_at = std.mem.indexOf(u8, plain, "    ▸ bash  ls");
    try t.expect(card_at != null);
    try t.expect(tool_at != null);
    try t.expect(tool_at.? < card_at.?);
    try t.expect(std.mem.indexOf(u8, plain, "model:") != null);
    try t.expect(std.mem.indexOf(u8, plain, "deepseek/flash") != null);
    try t.expect(std.mem.indexOf(u8, plain, "1786735635034") != null);
    try t.expect(std.mem.indexOf(u8, plain, "permissions:") != null);
    try t.expect(std.mem.indexOf(u8, plain, "yolo") != null);
    try t.expect(std.mem.indexOf(u8, plain, "SECRET_BODY") == null);

    const idle = ui.measureBottom(0, false);
    try t.expect(idle.composer_rows >= 3);
    try t.expect(idle.footer_rows >= 1);
    try t.expect(idle.height() < 24);
    try t.expectEqual(composerTopRow(24, idle) + idle.composer_rows, 24 -| idle.footer_rows + 1);
    try t.expectEqual(@as(usize, 0), idle.working_rows);
    ui.toggleTools();
    const still = ui.measureBottom(2, true);
    try t.expectEqual(@as(usize, 3), still.working_rows);
    try t.expectEqual(idle.composer_rows, still.composer_rows);
    try t.expectEqual(idle.footer_rows, still.footer_rows);
}

test "working rows are one status plus at most two details" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 0), workingRows(0, false));
    try t.expectEqual(@as(usize, 1), workingRows(0, true));
    try t.expectEqual(@as(usize, 2), workingRows(1, false));
    try t.expectEqual(@as(usize, 3), workingRows(2, true));
    try t.expectEqual(@as(usize, 3), workingRows(8, true));
}

test "wrapCursor follows soft-wrapped composer rows" {
    const t = std.testing;
    const pos = wrapCursor("0123456789", 7, 5);
    try t.expectEqual(@as(usize, 1), pos.row);
    try t.expectEqual(@as(usize, 2), pos.col);
    const home = wrapCursor("hello", 0, 80);
    try t.expectEqual(@as(usize, 0), home.row);
    try t.expectEqual(@as(usize, 0), home.col);
}

test "scrollSkip pins to bottom then walks up" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 10), scrollSkip(0, 20, 10));
    try t.expectEqual(@as(usize, 5), scrollSkip(5, 20, 10));
    try t.expectEqual(@as(usize, 0), scrollSkip(10, 20, 10));
    try t.expectEqual(@as(usize, 0), scrollSkip(99, 20, 10));
    try t.expectEqual(@as(usize, 0), scrollSkip(0, 5, 10));
}

test "joinFit drops trailing segments then truncates" {
    const t = std.testing;
    const parts = [_][]const u8{ "aaa", "bbb", "ccc" };
    const a = try joinFit(t.allocator, &parts, "  ", 13);
    defer t.allocator.free(a);
    try t.expectEqualStrings("aaa  bbb  ccc", a);
    const b = try joinFit(t.allocator, &parts, "  ", 10);
    defer t.allocator.free(b);
    try t.expectEqualStrings("aaa  bbb", b);
    const c = try joinFit(t.allocator, &parts, "  ", 2);
    defer t.allocator.free(c);
    try t.expectEqualStrings("aa", c);
    try t.expectEqual(@as(usize, 2), visibleCols("\x1b[2mab"));
}

test "picker moves, confirms, and stays exclusive" {
    const t = std.testing;
    const items = [_]PickerItem{
        .{ .label = "yolo", .hint = "不询问", .value = "yolo" },
        .{ .label = "ask", .hint = "危险工具先问", .value = "ask" },
        .{ .label = "read-only", .value = "read-only" },
    };
    var p = try Picker.init(t.allocator, "permissions", "授权", &items, 0);
    defer p.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), p.sel);
    p.move(1);
    try t.expectEqual(@as(usize, 1), p.sel);
    p.move(10);
    try t.expectEqual(@as(usize, 2), p.sel);
    p.move(-10);
    try t.expectEqual(@as(usize, 0), p.sel);
    p.sel = 1;
    const line = try p.confirmLine(t.allocator);
    defer t.allocator.free(line);
    try t.expectEqualStrings("/permissions ask", line);
    try t.expectEqual(@as(usize, 4), p.displayRows(24));
    try t.expectEqual(@as(usize, 2), p.displayRows(3));
}

test "bottom pane is reserved before transcript" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    ui.width = 80;
    ui.height = 24;
    const idle = ui.measureBottom(0, false);
    try t.expectEqual(@as(usize, 0), idle.working_rows);
    try t.expectEqual(@as(usize, 3), idle.composer_rows);
    // pi 式:宽 >= 50 恒双行
    try t.expectEqual(@as(usize, 2), idle.footer_rows);
    try t.expectEqual(@as(usize, 2), idle.footer_ident_rows);
    try t.expect(idle.composer_rows >= 3);
    try t.expect(idle.height() < 24);
    const busy = ui.measureBottom(5, true);
    try t.expectEqual(@as(usize, 3), busy.working_rows);
    try t.expect(busy.height() > idle.height());
    try t.expect(busy.composer_rows >= 3);
    ui.shortcuts_open = true;
    const help = ui.measureBottom(0, false);
    try t.expectEqual(@as(usize, 4), help.footer_rows);
    try t.expectEqual(@as(usize, 2), help.footer_ident_rows);
    ui.shortcuts_open = false;
    try ui.setFooterIdentity(.{
        .model = "deepseek/v4-flash",
        .think = "max",
        .cwd = "~/project/pi-zig",
        .session = "1786748577703",
        .used = 12_000,
        .window = 128_000,
        .cache_read = 7_440,
        .prompt = 12_000,
        .tok_in = 4_700,
        .tok_out = 44,
        .tok_cache_r = 7_440,
        .pct = 9,
    });
    const split = ui.measureBottom(0, false);
    try t.expectEqual(@as(usize, 2), split.footer_ident_rows);
    ui.width = 120;
    const wide = ui.measureBottom(0, false);
    try t.expectEqual(@as(usize, 2), wide.footer_ident_rows);
    ui.width = 40;
    const narrow = ui.measureBottom(0, false);
    try t.expectEqual(@as(usize, 1), narrow.footer_ident_rows);
}

test "footer format includes ctx occupancy and cache when usage is set" {
    const t = std.testing;
    var ub: [16]u8 = undefined;
    var cb: [48]u8 = undefined;
    var kb: [32]u8 = undefined;
    try t.expectEqualStrings("1.2k", formatTok(&ub, 1200));
    try t.expectEqualStrings("128k", formatTok(&ub, 128_000));
    try t.expectEqualStrings("ctx 12k/128k 9%", formatCtx(&cb, 12_000, 128_000, true));
    try t.expectEqualStrings("ctx 9%", formatCtx(&cb, 12_000, 128_000, false));
    try t.expectEqualStrings("ctx —", formatCtx(&cb, 0, 0, true));
    try t.expectEqualStrings("cache 62%", formatCache(&kb, 7_440, 12_000, true));
    try t.expectEqualStrings("cached 8.1k", formatCache(&kb, 8100, null, true));
    try t.expectEqualStrings("cache —", formatCache(&kb, null, 100, true));
    try t.expectEqualStrings("—", formatCache(&kb, null, null, false));

    const rows = try formatFooterRows(t.allocator, .{
        .model = "deepseek/v4-flash",
        .think = "max",
        .used = 12_000,
        .window = 128_000,
        .cache_read = 7_440,
        .prompt = 12_000,
        .tok_in = 4_700,
        .tok_out = 44,
        .tok_cache_r = 7_440,
        .pct = 9,
    }, null, 80, true);
    defer rows.deinit(t.allocator);
    const secondary = try stripForTest(t.allocator, rows.secondary);
    defer t.allocator.free(secondary);
    // pi 式:行 2 左 stats 右 model · think
    try t.expect(std.mem.indexOf(u8, secondary, "ctx 9% 12k/128k") != null);
    try t.expect(std.mem.indexOf(u8, secondary, "R7.4k") != null);
    try t.expect(std.mem.indexOf(u8, secondary, "↑4.7k ↓44") != null);
    try t.expect(std.mem.indexOf(u8, secondary, "deepseek/v4-flash · max") != null);

    const unknown = try formatFooterRows(t.allocator, .{
        .model = "x",
        .window = 128_000,
    }, null, 80, true);
    defer unknown.deinit(t.allocator);
    const unk = try stripForTest(t.allocator, unknown.secondary);
    defer t.allocator.free(unk);
    // cache 未知则不缀 R 段
    try t.expect(std.mem.indexOf(u8, unk, " R") == null);
    try t.expect(std.mem.indexOf(u8, unk, "ctx 0% 0/128k") != null);
}

test "slash ranking: prefix then fuzzy then description" {
    const t = std.testing;
    const items = [_]SlashItem{
        .{ .cmd = "/help", .desc = "list commands" },
        .{ .cmd = "/status", .desc = "session model cwd tokens" },
        .{ .cmd = "/model [m]", .desc = "switch model" },
        .{ .cmd = "/memory", .desc = "cross-session memory" },
        .{ .cmd = "/sessions", .desc = "sessions in this dir" },
    };
    var ranks: [8]SlashRank = undefined;
    const st_n = rankSlash(&items, "st", &ranks);
    try t.expect(st_n >= 1);
    try t.expectEqualStrings("status", slashName(items[ranks[0].item].cmd));
    try t.expectEqual(@as(u8, 0), ranks[0].kind);
    var i: usize = 1;
    while (i < st_n) : (i += 1) {
        try t.expect(ranks[i].kind >= ranks[0].kind);
        if (std.mem.eql(u8, slashName(items[ranks[i].item].cmd), "help")) {
            try t.expectEqual(@as(u8, 2), ranks[i].kind);
        }
    }

    const mod_n = rankSlash(&items, "mod", &ranks);
    try t.expect(mod_n >= 1);
    try t.expectEqualStrings("model", slashName(items[ranks[0].item].cmd));

    const all_n = rankSlash(&items, "", &ranks);
    try t.expectEqual(@as(usize, items.len), all_n);
    try t.expectEqualStrings("help", slashName(items[ranks[0].item].cmd));
    try t.expectEqualStrings("sessions", slashName(items[ranks[all_n - 1].item].cmd));

    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    ui.slash_items = &items;
    try ui.input.appendSlice("/st");
    ui.cursor = ui.input.items.len;
    const act = try ui.handleInput("\n");
    try t.expect(act == .submit);
    defer t.allocator.free(act.submit);
    try t.expectEqualStrings("/status", act.submit);

    var ui2 = try Tui.init(t.allocator);
    defer ui2.deinit();
    ui2.slash_items = &items;
    try ui2.input.appendSlice("/mod");
    ui2.cursor = ui2.input.items.len;
    _ = try ui2.handleInput(&.{0x09});
    try t.expectEqualStrings("/model", ui2.input.items);

    var ui3 = try Tui.init(t.allocator);
    defer ui3.deinit();
    ui3.slash_items = &items;
    try ui3.input.appendSlice("/foo");
    ui3.cursor = ui3.input.items.len;
    const unknown = try ui3.handleInput("\n");
    try t.expect(unknown == .submit);
    defer t.allocator.free(unknown.submit);
    try t.expectEqualStrings("/foo", unknown.submit);

    try t.expectEqualStrings("st", slashQuery("/st").?);
    try t.expect(slashQuery("/status extra") == null);
    try t.expect(slashQuery("hello") == null);
}

test "slash empty query lists names and descriptions" {
    const t = std.testing;
    const items = [_]SlashItem{
        .{ .cmd = "/status", .desc = "session model cwd tokens" },
        .{ .cmd = "/model [m]", .desc = "switch model" },
    };
    var ranks: [4]SlashRank = undefined;
    const n = rankSlash(&items, "", &ranks);
    try t.expectEqual(@as(usize, 2), n);
    try t.expect(std.mem.indexOf(u8, items[ranks[0].item].desc, "session") != null);
    try t.expect(std.mem.indexOf(u8, items[ranks[1].item].cmd, "/model") != null);

    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    ui.slash_items = &items;
    try ui.input.append('/');
    ui.width = 80;
    ui.height = 24;
    const bottom = ui.measureBottom(0, false);
    try t.expect(bottom.slash_rows >= 2);
}

fn expectComposerClosed(alloc: std.mem.Allocator, painted: []const u8, cols: usize) !void {
    const t = std.testing;
    const plain = try stripForTest(alloc, painted);
    defer alloc.free(plain);
    try t.expect(plain.len > 0);
    try t.expect(std.mem.startsWith(u8, plain, "╭"));
    var last_line: []const u8 = plain;
    var it = std.mem.splitScalar(u8, plain, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        n += 1;
        last_line = line;
        try t.expect(visibleCols(line) <= cols);
    }
    try t.expect(n >= 3);
    try t.expect(std.mem.startsWith(u8, last_line, "╰"));
}

test "measureBottom keeps a 3-row composer above the footer" {
    const t = std.testing;
    const ident = FooterIdent{
        .model = "deepseek/v4-flash",
        .think = "max",
        .cwd = "~/桌面",
        .session = "1786748577703",
        .used = 12_000,
        .window = 128_000,
        .cache_read = 7_440,
        .prompt = 12_000,
        .tok_in = 4_700,
        .tok_out = 44,
        .tok_cache_r = 7_440,
        .pct = 9,
    };
    const widths = [_]usize{ 80, 120 };
    for (widths) |cols| {
        var ui = try Tui.init(t.allocator);
        defer ui.deinit();
        ui.width = cols;
        ui.height = 24;
        try ui.setFooterIdentity(ident);
        const idle = ui.measureBottom(0, false);
        try t.expect(idle.composer_rows >= 3);
        try t.expect(idle.boxed);
        try t.expect(idle.height() <= 24);
        const top = composerTopRow(24, idle);
        const footer_top = 24 -| idle.footer_rows + 1;
        try t.expectEqual(top + idle.composer_rows, footer_top);
        try t.expect(idle.footer_rows >= 1);

        const busy = ui.measureBottom(5, true);
        try t.expect(busy.composer_rows >= 3);
        try t.expect(busy.height() <= 24);
        const busy_top = composerTopRow(24, busy);
        const busy_footer = 24 -| busy.footer_rows + 1;
        try t.expectEqual(busy_top + busy.composer_rows, busy_footer);
    }
}

test "composer box closes and cursor stays on the inner row" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 1), visibleCols("╭"));
    try t.expectEqual(@as(usize, 1), visibleCols("▎"));
    try t.expectEqual(@as(usize, 1), visibleCols("▸"));
    try t.expectEqual(@as(usize, 1), visibleCols("›"));
    try t.expectEqual(@as(usize, 2), visibleCols("桌"));
    try t.expectEqual(@as(usize, 79), composerBoxWidth(80));
    try t.expectEqual(@as(usize, 119), composerBoxWidth(120));

    const widths = [_]usize{ 80, 120 };
    for (widths) |cols| {
        const empty = try paintComposerBox(t.allocator, "", cols, 1, 0);
        defer t.allocator.free(empty);
        try expectComposerClosed(t.allocator, empty, cols);

        const cjk = try paintComposerBox(t.allocator, "在~/桌面写点东西", cols, 1, 0);
        defer t.allocator.free(cjk);
        try expectComposerClosed(t.allocator, cjk, cols);

        var long_buf: [200]u8 = undefined;
        @memset(&long_buf, 'x');
        const wrapped = try paintComposerBox(t.allocator, &long_buf, cols, 3, 0);
        defer t.allocator.free(wrapped);
        try expectComposerClosed(t.allocator, wrapped, cols);

        var ui = try Tui.init(t.allocator);
        defer ui.deinit();
        ui.width = cols;
        ui.height = 24;
        try ui.setFooterIdentity(.{
            .model = "deepseek/v4-flash",
            .think = "max",
            .cwd = "~/桌面",
            .session = "1786748577703",
        });
        const idle = ui.measureBottom(0, false);
        const cur = wrapCursor(ui.input.items, ui.cursor, idle.input_inner);
        const row = composerInputRow(24, idle, cur.row);
        const top = composerTopRow(24, idle);
        try t.expect(row >= top + 1);
        try t.expect(row <= top + idle.comp_inner);
        try t.expect(row < top + idle.composer_rows);

        try ui.input.appendSlice(&long_buf);
        ui.cursor = ui.input.items.len;
        const grown = ui.measureBottom(0, false);
        const cur2 = wrapCursor(ui.input.items, ui.cursor, grown.input_inner);
        const row2 = composerInputRow(24, grown, cur2.row);
        const top2 = composerTopRow(24, grown);
        try t.expect(grown.composer_rows >= 3);
        try t.expect(row2 >= top2 + 1);
        try t.expect(row2 <= top2 + grown.comp_inner);
    }
}
test "user and tool rows carry semantic bg bands; folded tail" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendUser("帮我看下这个 bug");
    try ui.appendText("某去查日志。");
    try ui.appendTool("read", "src/main.zig");
    try ui.appendToolEnd("read", false, "one\ntwo\nthree\nfour\nfive");
    const out = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(out);
    // user 整行色带 + tool title 状态色带 + 折叠尾行
    try t.expect(std.mem.indexOf(u8, out, theme.bgUser()) != null);
    try t.expect(std.mem.indexOf(u8, out, theme.bgTool(.ok)) != null);
    try t.expect(std.mem.indexOf(u8, out, "3 more lines, ctrl+o") != null);
    const plain = try stripForTest(t.allocator, out);
    defer t.allocator.free(plain);
    try t.expect(std.mem.indexOf(u8, plain, "    · (3 more lines, ctrl+o)") != null);
    // err 态色带
    var ui2 = try Tui.init(t.allocator);
    defer ui2.deinit();
    try ui2.appendTool("bash", "ls");
    try ui2.appendToolEnd("bash", true, "missing\n");
    const out2 = try paintCellsForTest(t.allocator, &ui2, 80);
    defer t.allocator.free(out2);
    try t.expect(std.mem.indexOf(u8, out2, theme.bgTool(.err)) != null);
    // 无色系:无色带、无补白,行为如旧
    const saved = theme;
    defer theme = saved;
    theme = .{ .mode = .none };
    const out3 = try paintCellsForTest(t.allocator, &ui2, 80);
    defer t.allocator.free(out3);
    try t.expect(std.mem.indexOf(u8, out3, "\x1b[48;") == null);
    try t.expect(std.mem.indexOf(u8, out3, "\x1b[31m") != null);
}

test "footer shows (sub) for subscription provider without cost" {
    const t = std.testing;
    const rows = try formatFooterRows(t.allocator, .{
        .model = "codex/gpt-5.4",
        .cwd = "~/x",
        .window = 272_000,
        .subscription = true,
    }, null, 80, true);
    defer rows.deinit(t.allocator);
    const s = try stripForTest(t.allocator, rows.secondary);
    defer t.allocator.free(s);
    // 订阅制:cost 为零亦显 $,缀 (sub)
    try t.expect(std.mem.indexOf(u8, s, "$0.000 (sub)") != null);
}

test "assistant markdown strips markers and uses theme colors" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendText("# Hello\n- item `x`");
    const out = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, theme.fg_md_heading) != null);
    try t.expect(std.mem.indexOf(u8, out, theme.fg_md_code) != null);
    const plain = try stripForTest(t.allocator, out);
    defer t.allocator.free(plain);
    try t.expect(std.mem.indexOf(u8, plain, "Hello") != null);
    try t.expect(std.mem.indexOf(u8, plain, "# Hello") == null);
    try t.expect(std.mem.indexOf(u8, plain, "• item x") != null);
}

test "example theme json loads and paint keeps code color" {
    const t = std.testing;
    var th = Theme{};
    const dark_json = try std.Io.Dir.cwd().readFileAlloc(util.io, "themes/dark.json", t.allocator, .limited(16 * 1024));
    defer t.allocator.free(dark_json);
    try t.expect(theme_mod.applyJson(&th, dark_json));
    try t.expectEqual(@as(u8, 0x34), th.pal.user_bg.r);
    const light_json = try std.Io.Dir.cwd().readFileAlloc(util.io, "themes/light.json", t.allocator, .limited(16 * 1024));
    defer t.allocator.free(light_json);
    var light = Theme{};
    try t.expect(theme_mod.applyJson(&light, light_json));
    try t.expectEqual(@as(u8, 0xe8), light.pal.user_bg.r);

    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendText("- item `xyz`");
    const out = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, theme.fg_md_code) != null);
    const plain = try stripForTest(t.allocator, out);
    defer t.allocator.free(plain);
    try t.expect(std.mem.indexOf(u8, plain, "• item xyz") != null);
}
