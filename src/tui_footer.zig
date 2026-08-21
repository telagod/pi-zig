// tui_footer.zig — 底栏、session/status 卡。从 tui.zig 拆出,
// 测宽走 tui_measure,色走 theme(由 tui.applyTheme attach)。
const std = @import("std");
const theme_mod = @import("theme.zig");
const measure = @import("tui_measure.zig");

const ANSI_RESET = "\x1b[0m";
const ANSI_BOLD = "\x1b[1m";
const ANSI_DIM = "\x1b[2m";

const visibleCols = measure.visibleCols;
const truncateToVisible = measure.truncateToVisible;
const ellipsizeAlloc = measure.ellipsizeAlloc;
const joinN = measure.joinN;

var theme_ptr: ?*const theme_mod.Theme = null;

pub fn attachTheme(t: *const theme_mod.Theme) void {
    theme_ptr = t;
}

fn theme() theme_mod.Theme {
    return if (theme_ptr) |p| p.* else .{};
}

pub const CARD_MAX_INNER: usize = 56;

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
    branch: []const u8 = "",
    session: []const u8,
    perms: []const u8,
    context: []const u8,
    usage: []const u8,
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
    image: bool = false,
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
    if (s.image) return "img attached  enter send  ctrl+v replace";
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
    /// 非空才画,例如 workspace / strict。off 不占栏。
    sandbox: []const u8 = "",
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

/// pi 式双行:行 1 `cwd (branch) · session` muted,hint 右端 dimmest;
/// 行 2 左 stats(ctx% 随占用变色、R cache),右 `model · think`。
fn formatFooterPi(alloc: std.mem.Allocator, ident: FooterIdent, hint: ?[]const u8, width: usize) !FooterRows {
    const mu = theme().muted();
    // pi 式:`pwd (branch) • session`;session 非空才挂在 cwd 后
    const place = if (ident.branch.len > 0 and ident.session.len > 0)
        try std.fmt.allocPrint(alloc, "  {s}{s}{s} {s}({s}){s} · {s}{s}{s}", .{ ANSI_DIM, ident.cwd, ANSI_RESET, mu, ident.branch, ANSI_RESET, ANSI_DIM, ident.session, ANSI_RESET })
    else if (ident.branch.len > 0)
        try std.fmt.allocPrint(alloc, "  {s}{s}{s} {s}({s}){s}", .{ ANSI_DIM, ident.cwd, ANSI_RESET, mu, ident.branch, ANSI_RESET })
    else if (ident.session.len > 0)
        try std.fmt.allocPrint(alloc, "  {s}{s}{s} · {s}{s}{s}", .{ ANSI_DIM, ident.cwd, ANSI_RESET, ANSI_DIM, ident.session, ANSI_RESET })
    else
        try std.fmt.allocPrint(alloc, "  {s}{s}{s}", .{ ANSI_DIM, ident.cwd, ANSI_RESET });
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
    const pct_ink = theme().fgCtx(ident.pct);
    const pct_end: []const u8 = if (pct_ink.len > 0) ANSI_RESET else "";
    var in_buf: [16]u8 = undefined;
    var out_buf: [16]u8 = undefined;
    var cr_buf: [16]u8 = undefined;
    var cw_buf: [16]u8 = undefined;
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
    var ch: ?[]u8 = null;
    defer if (ch) |c| alloc.free(c);
    if (ident.cache_read) |cr| {
        if (ident.prompt) |pr| {
            if (cr > 0 and pr > 0) ch = try std.fmt.allocPrint(alloc, " CH{d}%", .{cr * 100 / pr});
        }
    }
    var cost_s: ?[]u8 = null;
    defer if (cost_s) |c| alloc.free(c);
    if (ident.cost != null or ident.subscription) {
        const sub_suffix: []const u8 = if (ident.subscription) " (sub)" else "";
        cost_s = try std.fmt.allocPrint(alloc, " ${d:.3}{s}", .{ ident.cost orelse 0, sub_suffix });
    }
    const sep = ANSI_DIM ++ "  ·  " ++ ANSI_RESET;
    // cache+CH 与 cost 分仓:降级时 cache/CH 先弃,cost 留到最后一级
    var cache_ch = std.ArrayList(u8).empty;
    defer cache_ch.deinit(alloc);
    if (cache) |c| try cache_ch.appendSlice(alloc, std.mem.trimStart(u8, c, " "));
    if (ch) |c| {
        if (cache_ch.items.len > 0) try cache_ch.append(alloc, ' ');
        try cache_ch.appendSlice(alloc, std.mem.trimStart(u8, c, " "));
    }
    var econ = std.ArrayList(u8).empty;
    defer econ.deinit(alloc);
    if (cache_ch.items.len > 0) try econ.appendSlice(alloc, cache_ch.items);
    if (cost_s) |c| {
        if (econ.items.len > 0) try econ.append(alloc, ' ');
        try econ.appendSlice(alloc, std.mem.trimStart(u8, c, " "));
    }
    const ctx_s = try std.fmt.allocPrint(alloc, "{s}ctx {s}{s}{d}%{s} {s}/{s}", .{ ANSI_DIM, ANSI_RESET, pct_ink, ident.pct, pct_end, formatTok(&used_buf, ident.used), formatTok(&win_buf, ident.window) });
    defer alloc.free(ctx_s);
    var stats_b = std.ArrayList(u8).empty;
    errdefer stats_b.deinit(alloc);
    try stats_b.appendSlice(alloc, "  ");
    var need_sep = false;
    if (flow) |f| {
        try stats_b.appendSlice(alloc, f);
        need_sep = true;
    }
    if (econ.items.len > 0) {
        if (need_sep) try stats_b.appendSlice(alloc, sep);
        try stats_b.appendSlice(alloc, ANSI_DIM);
        try stats_b.appendSlice(alloc, econ.items);
        try stats_b.appendSlice(alloc, ANSI_RESET);
        need_sep = true;
    }
    if (need_sep) try stats_b.appendSlice(alloc, sep);
    try stats_b.appendSlice(alloc, ctx_s);
    const stats = try stats_b.toOwnedSlice(alloc);
    defer alloc.free(stats);
    const right = if (ident.think.len > 0 and ident.sandbox.len > 0)
        try std.fmt.allocPrint(alloc, "{s}{s}{s}{s} · {s} · {s}", .{ ANSI_DIM, ident.model, ANSI_RESET, ANSI_DIM, ident.think, ident.sandbox })
    else if (ident.think.len > 0)
        try std.fmt.allocPrint(alloc, "{s}{s}{s}{s} · {s}", .{ ANSI_DIM, ident.model, ANSI_RESET, ANSI_DIM, ident.think })
    else if (ident.sandbox.len > 0)
        try std.fmt.allocPrint(alloc, "{s}{s}{s}{s} · {s}", .{ ANSI_DIM, ident.model, ANSI_RESET, ANSI_DIM, ident.sandbox })
    else
        try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ ANSI_DIM, ident.model, ANSI_RESET });
    defer alloc.free(right);
    // 溢出降级:模型名永不丢,usage 明细按 cache/CH → flow → cost 顺序弃——
    // 曾一刀切丢 econ 全段,客之 $ 花费随 cache 俱没。
    var stats_use = stats;
    // 降级串须活到 layoutFooter 之后:if 块内 defer 块尾即焚,曾致 UAF 乱码($e[2m)
    var slim_keep: ?[]u8 = null;
    defer if (slim_keep) |s| alloc.free(s);
    if (visibleCols(stats) + 2 + visibleCols(right) > width) {
        var slim = std.ArrayList(u8).empty;
        defer slim.deinit(alloc);
        const need_sep0 = flow != null or cost_s != null;
        try slim.appendSlice(alloc, "  ");
        if (flow) |f| try slim.appendSlice(alloc, f);
        // 第 1 级:去 cache/CH,保 cost 与 flow
        if (cost_s) |c| {
            if (flow != null) try slim.appendSlice(alloc, sep);
            try slim.appendSlice(alloc, ANSI_DIM);
            try slim.appendSlice(alloc, std.mem.trimStart(u8, c, " "));
            try slim.appendSlice(alloc, ANSI_RESET);
        }
        if (need_sep0) try slim.appendSlice(alloc, sep);
        try slim.appendSlice(alloc, ctx_s);
        slim_keep = try slim.toOwnedSlice(alloc);
        stats_use = slim_keep.?;
        if (visibleCols(stats_use) + 2 + visibleCols(right) > width and flow != null) {
            // 第 2 级:再去 flow,保 cost
            slim.clearRetainingCapacity();
            try slim.appendSlice(alloc, "  ");
            if (cost_s) |c| {
                try slim.appendSlice(alloc, ANSI_DIM);
                try slim.appendSlice(alloc, std.mem.trimStart(u8, c, " "));
                try slim.appendSlice(alloc, ANSI_RESET);
                try slim.appendSlice(alloc, sep);
            }
            try slim.appendSlice(alloc, ctx_s);
            alloc.free(slim_keep.?);
            slim_keep = try slim.toOwnedSlice(alloc);
            stats_use = slim_keep.?;
        }
        if (visibleCols(stats_use) + 2 + visibleCols(right) > width) stats_use = ctx_s;
    }
    const row2 = try layoutFooter(alloc, stats_use, right, width);
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
        // pi 式:footer 一色全 dim,model 不另加粗(识别凭据靠位置,不靠色)
        try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ ANSI_DIM, ident.model, ANSI_RESET });
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
/// 百分比一位小数(pi 式 `0.8%`):0.79% 曾被整数除法截成 0%,「百分比不显示」
pub fn formatCtx(buf: *[48]u8, used: usize, window: usize, with_abs: bool) []const u8 {
    if (window == 0) return "ctx —";
    const pct: f64 = @as(f64, @floatFromInt(used)) * 100.0 / @as(f64, @floatFromInt(window));
    if (!with_abs) return std.fmt.bufPrint(buf, "ctx {d:.1}%", .{pct}) catch "ctx —";
    var ub: [16]u8 = undefined;
    var wb: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "ctx {s}/{s} {d:.1}%", .{
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
    const lines = [_][]const u8{ title, "", model, dir, session, "", CARD_HINT };
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
    const dir = if (info.branch.len > 0)
        try std.fmt.allocPrint(alloc, "{s}directory:   {s}{s} {s}({s}){s}", .{ ANSI_DIM, info.cwd, ANSI_RESET, ANSI_DIM, info.branch, ANSI_RESET })
    else
        try std.fmt.allocPrint(alloc, "{s}directory:   {s}{s}", .{ ANSI_DIM, info.cwd, ANSI_RESET });
    defer alloc.free(dir);
    const session = try std.fmt.allocPrint(alloc, "{s}session:     {s}{s}", .{ ANSI_DIM, info.session, ANSI_RESET });
    defer alloc.free(session);
    const perms = try std.fmt.allocPrint(alloc, "{s}permissions: {s}{s}", .{ ANSI_DIM, info.perms, ANSI_RESET });
    defer alloc.free(perms);
    const ctx = try std.fmt.allocPrint(alloc, "{s}context:     {s}{s}", .{ ANSI_DIM, info.context, ANSI_RESET });
    defer alloc.free(ctx);
    const usage = try std.fmt.allocPrint(alloc, "{s}usage:       {s}{s}", .{ ANSI_DIM, info.usage, ANSI_RESET });
    defer alloc.free(usage);
    const lines = [_][]const u8{ title, "", model, dir, session, perms, "", ctx, usage, CARD_HINT };
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

test "footer paints sandbox when set" {
    const t = std.testing;
    const rows = try formatFooterRows(t.allocator, .{
        .model = "m",
        .cwd = "~/p",
        .sandbox = "workspace",
        .used = 1,
        .window = 100,
    }, null, 80, true);
    defer rows.deinit(t.allocator);
    try t.expect(std.mem.indexOf(u8, rows.secondary, "workspace") != null);
}
