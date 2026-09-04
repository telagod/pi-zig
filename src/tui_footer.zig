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

/// 开场欢迎卡(omp home 屏对齐):左 logo + Welcome + 模型,右 Tips + Recent。
pub const RecentSession = struct {
    title: []const u8,
    when: []const u8,
};

pub const WelcomeInfo = struct {
    version: []const u8,
    model: []const u8,
    provider: []const u8,
    recents: []const RecentSession = &.{},
    tip: []const u8 = "",
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

/// Structured footer identity. Painted on the composer top edge (wide) or under
/// it (narrow), never as a transcript card.
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

/// pi 式双行阈值:双行 = 页脚自载 model/ctx(pi 式行1 cwd (branch),行2 stats/model)。
/// >=50 旧约保留(直接调用方);<40 顶边纯线、信息落页脚,也双行;
/// 40..49 拼接带单行。运行期 measureBottom 在 >=40 恒传单行,two_rows 只 <40 为真。
pub fn footerNeedsTwoRows(ident: FooterIdent, hint: ?[]const u8, width: usize) bool {
    _ = ident;
    _ = hint;
    return width >= 50 or width < 40;
}

fn edgeAppend(buf: []u8, len: *usize, s: []const u8) void {
    const n = @min(s.len, buf.len - len.*);
    @memcpy(buf[len.*..][0..n], s);
    len.* += n;
}

/// 顶边一段排版的总列数:"── " + left + (" ── " + mid)? + (" ── " + right)? + " ─"。
fn edgeNeed(left: []const u8, mid: []const u8, right: []const u8) usize {
    var n: usize = 3 + visibleCols(left) + 2;
    if (mid.len > 0) n += 4 + visibleCols(mid);
    if (right.len > 0) n += 4 + visibleCols(right);
    return n;
}

/// composer 顶边信息条(omp 形,piz 化,与页脚同源 FooterIdent):
/// ╭── model · think ── cwd ↳ branch ── $cost · ctx N% (used/window) ──╮
/// 色全走 theme().muted()。box_w < 39(终端 <40 列)纯线,信息留页脚双行;
/// box_w < 59(终端 <60 列)只 model + ctx N%。无成本数据省略 $cost。
/// 降级序:cost → cwd↳branch(先截后弃) → think/sandbox → ctx 绝对量 →
/// 右段全弃 → 截 model;任何宽度都画出闭合盒(不画崩是底线)。
pub fn writeComposerTopEdge(wr: *std.Io.Writer, ident: FooterIdent, box_w: usize) !void {
    const mu = theme().muted();
    if (box_w < 39) {
        try wr.writeAll(ANSI_DIM);
        try wr.writeAll("╭");
        var i: usize = 2;
        while (i < box_w) : (i += 1) try wr.writeAll("─");
        try wr.writeAll("╮");
        try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
        return;
    }
    const budget = box_w - 2; // ╭ ╮ 之间
    const wide = box_w >= 59;
    // 左段:model · think · sandbox(<60 列只 model)
    var left_b: [192]u8 = undefined;
    var ln: usize = 0;
    edgeAppend(&left_b, &ln, ident.model);
    if (wide and ident.think.len > 0) {
        edgeAppend(&left_b, &ln, " · ");
        edgeAppend(&left_b, &ln, ident.think);
    }
    if (wide and ident.sandbox.len > 0) {
        edgeAppend(&left_b, &ln, " · ");
        edgeAppend(&left_b, &ln, ident.sandbox);
    }
    var left: []const u8 = left_b[0..ln];
    // 中段:cwd ↳ branch(仅宽端)
    var mid_b: [192]u8 = undefined;
    var mn: usize = 0;
    if (wide) {
        edgeAppend(&mid_b, &mn, ident.cwd);
        if (ident.branch.len > 0) {
            if (ident.cwd.len > 0) edgeAppend(&mid_b, &mn, " ↳ ");
            edgeAppend(&mid_b, &mn, ident.branch);
        }
    }
    var mid: []const u8 = mid_b[0..mn];
    // 右段:$cost · ctx N% (used/window),窄端起只 ctx N%
    var used_b: [16]u8 = undefined;
    var win_b: [16]u8 = undefined;
    const ctx_ink = if (ident.hot) theme().fg_err else theme().fgCtx(ident.pct);
    const ctx_rst = if (ctx_ink.len > 0) ANSI_RESET else "";
    var ctx_full_b: [96]u8 = undefined;
    const ctx_full: []const u8 = if (ident.window > 0)
        std.fmt.bufPrint(&ctx_full_b, "{s}ctx {d}% ({s}/{s}){s}", .{ ctx_ink, ident.pct, formatTok(&used_b, ident.used), formatTok(&win_b, ident.window), ctx_rst }) catch "ctx —"
    else
        std.fmt.bufPrint(&ctx_full_b, "{s}ctx {d}%{s}", .{ ctx_ink, ident.pct, ctx_rst }) catch "ctx —";
    var ctx_pct_b: [32]u8 = undefined;
    const ctx_pct = std.fmt.bufPrint(&ctx_pct_b, "{s}ctx {d}%{s}", .{ ctx_ink, ident.pct, ctx_rst }) catch "ctx —";
    var cost_b: [64]u8 = undefined;
    var in_b: [16]u8 = undefined;
    var out_b: [16]u8 = undefined;
    const cost_s: []const u8 = if (ident.cost) |c|
        std.fmt.bufPrint(&cost_b, "${d:.2}", .{c}) catch ""
    else if (ident.subscription)
        "(sub)"
    else if (ident.tok_in > 0 or ident.tok_out > 0)
        std.fmt.bufPrint(&cost_b, "↑{s} ↓{s}", .{ formatTok(&in_b, ident.tok_in), formatTok(&out_b, ident.tok_out) }) catch ""
    else
        "";
    var right_full_b: [128]u8 = undefined;
    const right_full: []const u8 = if (cost_s.len > 0)
        std.fmt.bufPrint(&right_full_b, "{s} · {s}", .{ cost_s, ctx_full }) catch ctx_full
    else
        ctx_full;
    var right_pct_b: [64]u8 = undefined;
    const right_pct: []const u8 = if (wide and cost_s.len > 0)
        std.fmt.bufPrint(&right_pct_b, "{s} · {s}", .{ cost_s, ctx_pct }) catch ctx_pct
    else
        ctx_pct;
    var right: []const u8 = if (wide) right_full else ctx_pct;

    // 降级原则(wide 时优先保留 cost 与 model,冗余路径 mid 先截后弃):
    // 1. 优先缩减或丢弃 mid(cwd ↳ branch)
    if (edgeNeed(left, mid, right) > budget and mid.len > 0) {
        const spare = budget -| edgeNeed(left, "", right) -| 4;
        mid = if (spare >= 12) truncateToVisible(mid, spare) else "";
    }
    if (edgeNeed(left, mid, right) > budget and mid.len > 0) mid = "";
    // 2. 空间仍紧,去掉 think/sandbox,只留 model
    if (edgeNeed(left, mid, right) > budget and !std.mem.eql(u8, left, ident.model)) left = ident.model;
    // 3. 空间仍紧,wide 下右侧全量 ctx 降级为简短百分比 ctx,同时尽量保留 cost
    if (edgeNeed(left, mid, right) > budget and wide and !std.mem.eql(u8, right, right_pct)) right = right_pct;
    // 4. 空间若仍不够,wide 下放弃 cost 降为 ctx_full 或 ctx_pct
    if (edgeNeed(left, mid, right) > budget and wide and cost_s.len > 0 and !std.mem.eql(u8, right, ctx_full)) right = ctx_full;
    if (edgeNeed(left, mid, right) > budget and !std.mem.eql(u8, right, ctx_pct)) right = ctx_pct;
    if (edgeNeed(left, mid, right) > budget) right = "";
    if (edgeNeed(left, mid, right) > budget) left = truncateToVisible(left, budget -| 5);

    try wr.writeAll(ANSI_DIM);
    try wr.writeAll("╭");
    try wr.writeAll(mu);
    try wr.writeAll("── ");
    try wr.writeAll(left);
    var used: usize = 3 + visibleCols(left);
    if (mid.len > 0) {
        try wr.writeAll(" ── ");
        try wr.writeAll(mid);
        used += 4 + visibleCols(mid);
    }
    if (right.len > 0) {
        try wr.writeAll(" ── ");
        try wr.writeAll(right);
        try wr.writeAll(mu);
        used += 4 + visibleCols(right);
    }
    try wr.writeAll(" ");
    used += 1;
    while (used < budget) : (used += 1) try wr.writeAll("─");
    try wr.writeAll(ANSI_DIM);
    try wr.writeAll("╮");
    try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
}

/// 单行页脚:左 `cwd (branch) · session` host 身份 muted,右 hint dimmest。
/// 宽端(>=40)model/think/ctx/cost 已在 composer 顶边,此行不重复。
fn formatFooterPlaceRow(alloc: std.mem.Allocator, ident: FooterIdent, hint: ?[]const u8, width: usize) ![]u8 {
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
    if (hint) |h| {
        const hint_s = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ ANSI_DIM, h, ANSI_RESET });
        defer alloc.free(hint_s);
        return layoutFooter(alloc, place, hint_s, width);
    }
    return alloc.dupe(u8, truncateToVisible(place, width));
}

/// pi 式双行:行 1 `cwd (branch) · session` muted,hint 右端 dimmest;
/// 行 2 左 stats(ctx% 随占用变色、R cache),右 `model · think`。
pub fn formatFooterPi(alloc: std.mem.Allocator, ident: FooterIdent, hint: ?[]const u8, width: usize) !FooterRows {
    const row1 = try formatFooterPlaceRow(alloc, ident, hint, width);

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

/// two_rows 且宽度落在双行带(footerNeedsTwoRows)走 pi 式双行;否则单行
/// host 身份 + hint。运行期 measureBottom 只在 <40 列请求双行(顶边纯线,
/// model/ctx 落页脚);>=40 列信息已上 composer 顶边,页脚不重复。
pub fn formatFooterRows(alloc: std.mem.Allocator, ident: FooterIdent, hint: ?[]const u8, width: usize, two_rows: bool) !FooterRows {
    const split = two_rows and footerNeedsTwoRows(ident, hint, width);
    if (split) return formatFooterPi(alloc, ident, hint, width);
    const primary = try formatFooterPlaceRow(alloc, ident, hint, width);
    return .{ .primary = primary, .secondary = try alloc.dupe(u8, "") };
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

/// piz 开场卡 logo:src/logo.svg 的 ink-Z 标记(块元素,14 列 × 5 行)。
pub const WELCOME_LOGO = [_][]const u8{
    "██████████████",
    "         ▄▄█▀▀",
    "     ▄▄█▀▀",
    " ▄▄█▀▀",
    "██████████████",
};

/// 双栏下限:低于 60 列退化为单栏(无右栏),与 omp home 卡降级一致。
pub const WELCOME_WIDE_MIN: usize = 60;
const WELCOME_LEFT_W: usize = 26;
const WELCOME_MAX_RECENTS: usize = 3;

/// 截到 target 列,补 RESET,再按 center 居左/居中补空格。返回 owned。
fn padCardLine(alloc: std.mem.Allocator, raw: []const u8, target: usize, center: bool) ![]u8 {
    const cut = truncateToVisible(raw, target);
    const vis = visibleCols(cut);
    const lead: usize = if (center and vis < target) (target - vis) / 2 else 0;
    var w = std.Io.Writer.Allocating.init(alloc);
    errdefer w.deinit();
    var i: usize = 0;
    while (i < lead) : (i += 1) try w.writer.writeByte(' ');
    try w.writer.writeAll(cut);
    try w.writer.writeAll(ANSI_RESET);
    var pad = target - vis - lead;
    while (pad > 0) : (pad -= 1) try w.writer.writeByte(' ');
    return w.toOwnedSlice();
}

fn writeTitledEdge(wr: *std.Io.Writer, mu: []const u8, left: []const u8, right: []const u8, title: []const u8, inner: usize) !void {
    try wr.writeAll(mu);
    try wr.writeAll(left);
    try wr.writeAll(ANSI_RESET);
    const tcut = truncateToVisible(title, inner);
    try wr.writeAll(tcut);
    const fill = inner - visibleCols(tcut);
    try wr.writeAll(mu);
    var i: usize = 0;
    while (i < fill) : (i += 1) try wr.writeAll("─");
    try wr.writeAll(right);
    try wr.writeAll(ANSI_RESET ++ "\n");
}

/// 底边;junction_at 非空则在那一列放 ┴(双栏分隔落到下沿,同 omp)。
fn writeBottomEdge(wr: *std.Io.Writer, mu: []const u8, inner: usize, junction_at: ?usize) !void {
    try wr.writeAll(mu);
    try wr.writeAll("╰");
    var i: usize = 0;
    while (i < inner) : (i += 1) {
        if (junction_at) |j| {
            if (i == j) {
                try wr.writeAll("┴");
                continue;
            }
        }
        try wr.writeAll("─");
    }
    try wr.writeAll("╯");
    try wr.writeAll(ANSI_RESET ++ "\n");
}

/// 卡下轮换 Tip:dim,超宽硬折行,悬挂缩进对齐 " Tip: " 之后(同 omp)。
fn writeWelcomeTip(wr: *std.Io.Writer, mu: []const u8, tip: []const u8, width: usize) !void {
    if (tip.len == 0) return;
    const limit = if (width > 8) width - 1 else width;
    try wr.writeAll(mu);
    try wr.writeAll(" Tip: ");
    var col: usize = 6;
    var i: usize = 0;
    while (i < tip.len) {
        const ch = measure.charCols(tip, i);
        if (col + ch.cols > limit and i > 0) {
            try wr.writeAll("\n      ");
            col = 6;
        }
        try wr.writeAll(tip[i .. i + ch.n]);
        col += ch.cols;
        i += ch.n;
    }
    try wr.writeAll(ANSI_RESET);
}

/// 开场欢迎卡(omp home 屏):顶边带 piz v<版本>,左栏 logo + Welcome back + 模型,
/// 右栏 Tips + Recent sessions;窄终端单栏;卡下挂一行轮换 Tip。色全走 theme token。
pub fn formatWelcomeCard(alloc: std.mem.Allocator, info: WelcomeInfo, width: usize) ![]u8 {
    const mu = theme().muted();
    // 卡宽跟 composer 盒宽规则(tui.composerBoxWidth):末列触换行,盒宽 cols-1。
    const box_w = if (width > 1) width - 1 else width;
    var w = std.Io.Writer.Allocating.init(alloc);
    errdefer w.deinit();
    if (box_w < 16) {
        // 极窄:画盒必崩,纯文本降级
        try w.writer.print("{s}piz{s} {s}v{s}{s}\n", .{ ANSI_BOLD, ANSI_RESET, mu, info.version, ANSI_RESET });
        try w.writer.print("{s}Welcome back!{s}\n", .{ ANSI_BOLD, ANSI_RESET });
        try w.writer.print("{s}{s}", .{ truncateToVisible(info.model, box_w), ANSI_RESET });
        if (info.provider.len > 0) try w.writer.print(" {s}{s}{s}", .{ mu, truncateToVisible(info.provider, box_w), ANSI_RESET });
        try w.writer.writeByte('\n');
        try writeWelcomeTip(&w.writer, mu, info.tip, box_w);
        const raw0 = try w.toOwnedSlice();
        if (raw0.len > 0 and raw0[raw0.len - 1] == '\n') {
            const trimmed = try alloc.dupe(u8, raw0[0 .. raw0.len - 1]);
            alloc.free(raw0);
            return trimmed;
        }
        return raw0;
    }
    const inner = box_w - 2;
    const wide = width >= WELCOME_WIDE_MIN and inner >= WELCOME_LEFT_W + 14;
    const left_w: usize = if (wide) WELCOME_LEFT_W else inner;
    const right_w: usize = if (wide) inner - left_w - 1 else 0;

    const title = try std.fmt.allocPrint(alloc, "─── {s}piz{s} {s}v{s}{s} ", .{ ANSI_BOLD, ANSI_RESET, mu, info.version, ANSI_RESET });
    defer alloc.free(title);
    try writeTitledEdge(&w.writer, mu, "╭", "╮", title, inner);

    // 左栏:Welcome + logo + 模型/provider(单栏时即全卡内容)
    var left = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (left.items) |s| alloc.free(s);
        left.deinit();
    }
    try left.append(try padCardLine(alloc, "", left_w, false));
    try left.append(try padCardLine(alloc, ANSI_BOLD ++ "Welcome back!", left_w, true));
    try left.append(try padCardLine(alloc, "", left_w, false));
    for (WELCOME_LOGO) |ln| try left.append(try padCardLine(alloc, ln, left_w, true));
    try left.append(try padCardLine(alloc, "", left_w, false));
    const model_b = try std.fmt.allocPrint(alloc, "{s}{s}", .{ ANSI_BOLD, info.model });
    defer alloc.free(model_b);
    try left.append(try padCardLine(alloc, model_b, left_w, true));
    const prov_m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ mu, info.provider });
    defer alloc.free(prov_m);
    try left.append(try padCardLine(alloc, prov_m, left_w, true));

    // 右栏:Tips 常驻;Recent sessions 仅在有历史会话时出
    var right = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (right.items) |s| alloc.free(s);
        right.deinit();
    }
    if (wide) {
        try right.append(try padCardLine(alloc, " " ++ ANSI_BOLD ++ "Tips", right_w, false));
        try right.append(try padCardLine(alloc, " / for commands", right_w, false));
        try right.append(try padCardLine(alloc, " ? for shortcuts", right_w, false));
        try right.append(try padCardLine(alloc, " ! to run bash", right_w, false));
        try right.append(try padCardLine(alloc, " @ to embed files", right_w, false));
        const div = try std.fmt.allocPrint(alloc, " {s}", .{mu});
        defer alloc.free(div);
        var dw = std.Io.Writer.Allocating.init(alloc);
        defer dw.deinit();
        try dw.writer.writeAll(div);
        var di: usize = 1;
        while (di + 1 < right_w) : (di += 1) try dw.writer.writeAll("─");
        const div_s = try dw.toOwnedSlice();
        try right.append(try padCardLine(alloc, div_s, right_w, false));
        alloc.free(div_s);
        if (info.recents.len > 0) {
            try right.append(try padCardLine(alloc, " " ++ ANSI_BOLD ++ "Recent sessions", right_w, false));
            const n = @min(WELCOME_MAX_RECENTS, info.recents.len);
            for (info.recents[0..n]) |r| {
                const entry = try std.fmt.allocPrint(alloc, " {s} {s}({s}){s}", .{ r.title, mu, r.when, ANSI_RESET });
                try right.append(try padCardLine(alloc, entry, right_w, false));
                alloc.free(entry);
            }
        }
    }

    const rows = @max(left.items.len, right.items.len);
    var ri: usize = 0;
    while (ri < rows) : (ri += 1) {
        try w.writer.print("{s}│{s}", .{ mu, ANSI_RESET });
        if (ri < left.items.len) {
            try w.writer.writeAll(left.items[ri]);
        } else {
            var p: usize = 0;
            while (p < left_w) : (p += 1) try w.writer.writeByte(' ');
        }
        if (wide) {
            try w.writer.print("{s}│{s}", .{ mu, ANSI_RESET });
            if (ri < right.items.len) {
                try w.writer.writeAll(right.items[ri]);
            } else {
                var p: usize = 0;
                while (p < right_w) : (p += 1) try w.writer.writeByte(' ');
            }
        }
        try w.writer.print("{s}│{s}\n", .{ mu, ANSI_RESET });
    }
    try writeBottomEdge(&w.writer, mu, inner, if (wide) left_w else null);
    try writeWelcomeTip(&w.writer, mu, info.tip, box_w);

    const out = try w.toOwnedSlice();
    if (out.len > 0 and out[out.len - 1] == '\n') {
        const trimmed = try alloc.dupe(u8, out[0 .. out.len - 1]);
        alloc.free(out);
        return trimmed;
    }
    return out;
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
