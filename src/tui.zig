// tui.zig — layered Codex/Claude layout, Zig + ANSI.
//
// Three stacked systems, painted as different weights — not one bullet:
//   A. Chrome: working (dim, ephemeral) / boxed composer / footer under it.
//      Footer packs into one row when it fits (typical width ≥ ~100): model
//      bold, think/ctx/cache labels dim + numbers normal, cwd · session, hint
//      dimmest. Overflow splits: row 1 metrics, row 2 cwd · session + hint.
//      Collapse drops hint → think → cache label → ctx abs → session before
//      cwd. Model is never dropped; cwd is truncated, not omitted.
//   B. Cards: bare `piz` paints a boxed welcome card (logo + tips + recent
//      sessions) as cell 0, scrolling up with the conversation (omp home);
//      `piz -c/-s` uses the session header; status card is on-demand /status.
//   C. Turn blocks (paint-time, never baked into cell text):
//        user      indent 0, bold, bar ▎ + bg — the request
//        assistant indent 2, normal, no bar — the answer
//        thought   indent 4, ┆ dim italic (Ctrl+T → `┆ thought`)
//        tools     indent 4, ▸ bold name + dim preview + status bg
//                  output indent 6 │ / └ dim; err output uses error ink
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
pub const ANSI_BOLD = "\x1b[1m";
pub const ANSI_DIM = "\x1b[2m";
const ANSI_REV = "\x1b[7m";
pub const ANSI_ITALIC = "\x1b[3m";

const theme_mod = @import("theme.zig");
const markdown = @import("markdown.zig");
const slash = @import("tui_slash.zig");
const measure = @import("tui_measure.zig");
const footer = @import("tui_footer.zig");
const keys = @import("tui_keys.zig");
const draw = @import("tui_draw.zig");
const filesmod = @import("core").tools_files;
const types = @import("tui_types.zig");
const emit = @import("tui_emit.zig");
const tui_flow = @import("tui_flow.zig");
const tui_input = @import("tui_input.zig");
pub const Theme = theme_mod.Theme;
pub const ColorMode = theme_mod.ColorMode;

/// 全局主题。main 启动 /theme 调用 applyTheme;测试默认 dark+256。
pub var theme: Theme = .{};

pub fn applyTheme(name: []const u8) void {
    theme = Theme.resolve(name);
    // resolve() 的色码切片指向临时 store;赋值后再 rebuild,钉到全局 store。
    theme.rebuild();
    footer.attachTheme(&theme);
    emit.attachTheme(&theme);
}

/// Codex EnableAlternateScroll — wheel → arrows, drag-select stays native.
pub const ENTER_ALT_SCROLL = "\x1b[?1007h";
pub const LEAVE_ALT_SCROLL = "\x1b[?1007l";

/// Codex session header 内宽上限。见 history_cell.rs SESSION_HEADER_MAX_INNER_WIDTH。
pub const CARD_MAX_INNER = footer.CARD_MAX_INNER;

pub const CellKind = types.CellKind;
pub const ToolStatus = types.ToolStatus;
pub const ToolMeta = types.ToolMeta;

const FlowSt = tui_flow.FlowSt;

const FlowNode = tui_flow.FlowNode;

pub const Cell = types.Cell;
pub const CardFields = types.CardFields;

const gapBetween = emit.gapBetween;
const gutter = emit.gutter;
const toolRowCount = emit.toolRowCount;
const wrapRowCount = emit.wrapRowCount;
const emitCell = emit.emitCell;
const emitComposer = emit.emitComposer;
const emitDocLines = emit.emitDocLines;
const classifyThink = emit.classifyThink;
const thinkColor = emit.thinkColor;
pub const thinkLabel = emit.thinkLabel;
const countContentLines = emit.countContentLines;
const flowGoalPreview = emit.flowGoalPreview;
const wrapCursor = emit.wrapCursor;
const cellRowCount = emit.cellRowCount;
const gutterInner = emit.gutterInner;
const thinkRowCount = emit.thinkRowCount;
const joinFit = measure.joinFit;

const CsiKey = keys.CsiKey;
const WheelDir = keys.WheelDir;
const consumeSameCsi = keys.consumeSameCsi;
const sgrWheel = keys.sgrWheel;
const classifyCsi = keys.classifyCsi;

pub const SessionInfo = footer.SessionInfo;
pub const StatusInfo = footer.StatusInfo;
pub const RecentSession = footer.RecentSession;
pub const WelcomeInfo = footer.WelcomeInfo;

/// 选择器一行。label 是看见的,value 是确认后拼进斜杠命令的参数。
pub const PickerItem = slash.PickerItem;
pub const SlashItem = slash.SlashItem;
pub const SlashRank = slash.SlashRank;
pub const Picker = slash.Picker;
pub const slashName = slash.slashName;
pub const slashQuery = slash.slashQuery;
pub const rankSlash = slash.rankSlash;
const indexOfInsensitive = slash.indexOfInsensitive;

fn slashDisplayRows(input: []const u8, items: []const SlashItem, height: usize) usize {
    const q = slashQuery(input) orelse return 0;
    var ranks: [64]SlashRank = undefined;
    const n = rankSlash(items, q, &ranks);
    if (n == 0) return 0;
    return @min(n, @max(1, height / 3));
}

pub const FooterState = footer.FooterState;

pub const footerHint = footer.footerHint;

pub const FooterIdent = footer.FooterIdent;
pub const FooterRows = footer.FooterRows;
pub const footerNeedsTwoRows = footer.footerNeedsTwoRows;
pub const formatFooterRows = footer.formatFooterRows;
pub const formatTok = footer.formatTok;
pub const formatCtx = footer.formatCtx;
pub const formatCache = footer.formatCache;
pub const layoutFooter = footer.layoutFooter;
pub const cardInner = footer.cardInner;
pub const formatCard = footer.formatCard;
pub const formatSessionCard = footer.formatSessionCard;
pub const formatStatusCard = footer.formatStatusCard;
pub const formatWelcomeCard = footer.formatWelcomeCard;

/// skip = 从对话顶裁掉的行数。off=0 钉住底。
pub fn scrollSkip(off: usize, total: usize, view: usize) usize {
    const pin = if (total > view) total - view else 0;
    const o = @min(off, pin);
    return pin - o;
}

/// Working 行数:关=0,开=1 状态行 + ≤2 行 subagent 摘要 + 溢出 1 行折叠(pi-subagents 插件式)。
/// 工具/http 活动不占行(卡里已见);subagent 无卡,才在此报。
pub fn workingRows(nact: usize, streaming: bool, subagents: usize) usize {
    if (nact == 0 and !streaming) return 0;
    const rows: usize = 1 + @min(subagents, 2);
    const extra: usize = if (subagents > 2) 1 else 0;
    return rows + extra;
}

pub fn subagentCount(views: []const activity.View) usize {
    var n: usize = 0;
    for (views) |v| {
        if (v.kind == .subagent) n += 1;
    }
    return n;
}

/// Composer box display width. Terminals with auto-margin wrap a glyph
/// written in the last column, so the closed box is `cols-1` (never `cols`).
pub fn composerBoxWidth(cols: usize) usize {
    return if (cols > 1) cols - 1 else cols;
}

/// Prefix `│ › ` is 4 cols; plus the right `│` is 5. Inner text fits in the rest.
const COMPOSER_FRAME: usize = 5;

pub fn composerInnerWidth(boxed: bool, cols: usize) usize {
    if (!boxed) return @max(cols, 2) - 2;
    const box_w = composerBoxWidth(cols);
    return @max(box_w, COMPOSER_FRAME) - COMPOSER_FRAME;
}

fn composerSkip(cursor_row: usize, view_rows: usize) usize {
    if (view_rows == 0) return 0;
    return if (cursor_row + 1 > view_rows) cursor_row + 1 - view_rows else 0;
}

/// 文档流里 composer 顶行(1-based)。nvis=已画消息行,skip=0 时即屏上顶行。
pub fn composerTopRow(nvis: usize, bottom: BottomPane) usize {
    return nvis + bottom.working_rows + bottom.perm_rows + bottom.picker_rows + bottom.slash_rows + 1;
}

pub fn composerInputRow(top: usize, bottom: BottomPane, cursor_row: usize) usize {
    if (top == 0) return 1;
    const skip = composerSkip(cursor_row, bottom.comp_inner);
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
    file_arena: *std.heap.ArenaAllocator = undefined,
    file_items: []const filesmod.FileItem = &.{},
    file_sel: usize = 0,
    file_q_hash: u64 = 0,
    history_path: []u8,
    think_open: bool = true,
    flow_nodes: std.ArrayListUnmanaged(FlowNode) = .empty,
    flow_goal: []u8 = &.{},
    flow_active: bool = false,
    think_live: bool = false,
    last_think_len: usize = 0,
    think_level: ai.ThinkLevel = .high,
    think_meta: cfgmod.ModelMeta = .{ .reasoning = true },
    quit_arm_ns: i64 = 0,
    quit_arm_key: u8 = 0,
    esc_armed: bool = false,
    /// bracketed paste(ESC[200~ ... ESC[201~)进行中:字节原样入草稿,\n 不提交。
    paste_mode: bool = false,
    picker: ?Picker = null,
    scroll_off: usize = 0,
    search_q: []u8 = &.{},
    search_hit: ?usize = null,
    /// 裁掉的细胞正文,供 /find 继续搜。
    find_log: std.array_list.Managed([]u8),
    pending_image: ?[]u8 = null,
    pending_mime: []const u8 = "",
    last_pin: usize = 0,
    /// 1-based 屏上行号,0=composer 滚出视口。
    composer_screen_row: usize = 0,
    shortcuts_open: bool = false,

    pub fn init(alloc: std.mem.Allocator) !Tui {
        footer.attachTheme(&theme);
        emit.attachTheme(&theme);
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
                if (line.len > 0) try hist.append(try histUnescape(alloc, line));
                if (hist.items.len >= 2000) break;
            }
        } else |_| {} else {}
        const file_arena = try alloc.create(std.heap.ArenaAllocator);
        file_arena.* = std.heap.ArenaAllocator.init(alloc);
        return .{
            .alloc = alloc,
            .cells = std.array_list.Managed(Cell).init(alloc),
            .find_log = std.array_list.Managed([]u8).init(alloc),
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
            .file_arena = file_arena,
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
        self.file_arena.deinit();
        self.alloc.destroy(self.file_arena);
        self.alloc.free(self.history_path);
        if (self.search_q.len > 0) self.alloc.free(self.search_q);
        for (self.find_log.items) |s| self.alloc.free(s);
        self.find_log.deinit();
        if (self.pending_image) |img| self.alloc.free(img);
        tui_flow.resetFlow(self);
        self.flow_nodes.deinit(self.alloc);
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
        try self.writeAll("\x1b[?1049h\x1b[?2004h"); // 1049=备用屏,2004=bracketed paste
        try self.writeAll(ENTER_ALT_SCROLL);
        try self.querySize();
    }

    pub fn restoreTerminal(self: *Tui) void {
        if (self.raw) {
            self.raw = false;
            _ = self.writeAll("\x1b[?2004l" ++ LEAVE_ALT_SCROLL ++ "\x1b[?1049l\x1b[0m") catch {};
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
        self.pruneCells();
        try self.cells.append(.{
            .kind = kind,
            .text = std.array_list.Managed(u8).init(self.alloc),
        });
        return &self.cells.items[self.cells.items.len - 1];
    }

    /// 长会话封顶。保留开场会话卡,一次丢掉一截以免每条都搬。
    fn pruneCells(self: *Tui) void {
        const cap: usize = 400;
        if (self.cells.items.len < cap) return;
        const keep_header = self.cells.items.len > 0 and self.cells.items[0].kind == .session_header;
        const start: usize = if (keep_header) 1 else 0;
        const drop = @min(self.cells.items.len - start, (self.cells.items.len - cap) + 48);
        if (drop == 0) return;
        var i: usize = 0;
        while (i < drop) : (i += 1) {
            const txt = self.cells.items[start + i].text.items;
            if (txt.len > 0) {
                const keep: usize = 2000;
                const slice = txt[0..@min(txt.len, keep)];
                if (self.alloc.dupe(u8, slice)) |copy| {
                    if (self.find_log.items.len >= 2000) {
                        self.alloc.free(self.find_log.items[0]);
                        _ = self.find_log.orderedRemove(0);
                    }
                    self.find_log.append(copy) catch self.alloc.free(copy);
                } else |_| {}
            }
            deinitCell(&self.cells.items[start + i], self.alloc);
        }
        const remain = self.cells.items[start + drop ..];
        std.mem.copyForwards(Cell, self.cells.items[start..][0..remain.len], remain);
        self.cells.items.len = start + remain.len;
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
        if (std.mem.eql(u8, name, "workflow")) {
            tui_flow.loadFlowFromOut(self, body);
            self.flow_active = false;
            tui_flow.paintFlowInto(self, tm);
            return;
        }
        tm.body.clearRetainingCapacity();
        try tm.body.appendSlice(body);
        // todo 卡默认展开:列表短,折叠先遮内容(与 web 端 todo-view 一致)
        tm.folded = !(std.mem.eql(u8, name, "todo_write") or std.mem.eql(u8, name, "todo_read"));
        self.dirty.store(true, .release);
    }

    pub fn firstRunningTool(self: *Tui, name: []const u8) ?*Cell {
        for (self.cells.items) |*c| {
            if (c.kind != .tool) continue;
            if (c.tool) |*tm| {
                if (tm.status == .running and std.mem.eql(u8, tm.name, name)) return c;
            }
        }
        return null;
    }

    pub fn appendWorkflow(self: *Tui, args: []const u8) !void {
        return tui_flow.appendWorkflow(self, args);
    }

    pub fn applyFlowEvent(self: *Tui, idx: usize, kind: []const u8, text: []const u8) bool {
        return tui_flow.applyFlowEvent(self, idx, kind, text);
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
            invalidatePaint(&self.cells.items[0], self.alloc);
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

    /// 裸 piz 开场欢迎卡(omp home 屏):占 cells 0 号位,随对话上滚留存。
    /// 续载会话仍走 setSessionHeader;二者同 kind,后写覆盖先写。
    pub fn setWelcomeHeader(self: *Tui, info: WelcomeInfo) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        const fields = try dupeWelcome(self.alloc, info);
        errdefer fields.deinit(self.alloc);
        if (self.cells.items.len > 0 and self.cells.items[0].kind == .session_header) {
            if (self.cells.items[0].card) |old| old.deinit(self.alloc);
            invalidatePaint(&self.cells.items[0], self.alloc);
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

    pub fn measureBottom(self: *Tui, nact: usize, streaming: bool, views: []const activity.View) BottomPane {
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
        tui_input.ensureAtFiles(self);
        const slash_rows: usize = if (self.picker == null) slashDisplayRows(self.input.items, self.slash_items, h) else 0;
        const file_rows: usize = if (self.picker == null and filesmod.atQuery(self.input.items) != null)
            if (self.file_items.len == 0) 1 else @min(self.file_items.len, @max(@as(usize, 1), h / 3))
        else
            0;
        const boxed = w >= 8;
        const input_inner = composerInnerWidth(boxed, w);
        const wrap_n = wrapRowCount(self.input.items, input_inner);
        const cap = @max(1, h / 4);
        var comp_inner: usize = if (boxed) @max(1, @min(cap, wrap_n)) else 1;
        const min_inner: usize = 1;
        var working = workingRows(nact, streaming, subagentCount(views));
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
            .slash = self.picker == null and (slashQuery(self.input.items) != null and self.slash_items.len > 0 or filesmod.atQuery(self.input.items) != null),
            .quit_armed = self.quit_arm_ns != 0,
            .esc_armed = self.esc_armed,
            .scrolled = self.scroll_off > 0,
            .shortcuts = self.shortcuts_open,
            .has_draft = self.input.items.len > 0,
            .running = streaming,
            .image = self.pending_image != null,
        });
        var ident_rows: usize = if (footerNeedsTwoRows(ident, hint, w)) 2 else 1;
        const fixed = perm_rows + picker_rows + slash_rows + file_rows + help_rows;
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
            .slash_rows = slash_rows + file_rows,
            .composer_rows = composer_rows,
            .footer_rows = ident_rows + help_rows,
            .footer_ident_rows = ident_rows,
            .boxed = boxed,
            .input_inner = input_inner,
            .comp_inner = comp_inner,
        };
    }

    pub fn ensurePainted(self: *Tui, width: usize) !void {
        for (self.cells.items) |*c| {
            if (c.card) |card| {
                if (c.card_buf != null and c.card_w == width) continue;
                if (c.card_buf) |old| self.alloc.free(old);
                c.card_buf = try paintCard(self.alloc, c.kind, card, width);
                c.card_w = width;
                c.row_valid = false;
            }
        }
    }

    fn renderFrame(self: *Tui) !void {
        var fw = std.Io.Writer.Allocating.init(self.alloc);
        defer fw.deinit();
        const w = self.width;
        const h = self.height;
        var views: [activity.MAX_SLOTS]activity.View = undefined;
        const nact = activity.snapshot(&views);
        const streaming = self.streaming.load(.acquire);
        const bottom = self.measureBottom(nact, streaming, views[0..nact]);
        const composer_block = bottom.height();
        const scroll_h = if (h > 0) h else 1;

        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);

        try self.ensurePainted(w);

        try fw.writer.writeAll("\x1b[?25l\x1b[H");
        var total_vis: usize = 0;
        var ci: usize = 0;
        while (ci < self.cells.items.len) : (ci += 1) {
            if (ci > 0 and gapBetween(self.cells.items[ci - 1].kind, self.cells.items[ci].kind)) total_vis += 1;
            const painted = paintedOf(self.cells.items[ci]);
            total_vis += cellRowCountCached(self.alloc, &self.cells.items[ci], painted, self.think_open, w);
        }
        total_vis += composer_block;
        // composer+footer 跟消息同一份文档,整屏可滚。
        const pin = if (total_vis > scroll_h) total_vis - scroll_h else 0;
        // pi 式:文档短于窗口时,顶部留白、composer/footer 貼底(而非顶置)。
        // 用户上滚(scroll_off>0)时不加留白,保持原顶置滚动语义。
        const top_gap: usize = if (self.scroll_off == 0 and total_vis < scroll_h) scroll_h - total_vis else 0;
        if (self.scroll_off > pin) self.scroll_off = pin;
        self.last_pin = pin;
        var skip = pin - self.scroll_off;
        var emitted: usize = 0;
        var cell_aw = std.Io.Writer.Allocating.init(self.alloc);
        defer cell_aw.deinit();
        ci = 0;
        while (ci < self.cells.items.len) : (ci += 1) {
            if (ci > 0 and gapBetween(self.cells.items[ci - 1].kind, self.cells.items[ci].kind)) {
                if (skip > 0) {
                    skip -= 1;
                } else if (emitted < scroll_h) {
                    try cell_aw.writer.writeAll("\x1b[K\r\n");
                    emitted += 1;
                }
            }
            const painted = paintedOf(self.cells.items[ci]);
            if (emitted >= scroll_h) continue;
            const n = cellRowCountCached(self.alloc, &self.cells.items[ci], painted, self.think_open, w);
            if (skip >= n) {
                skip -= n;
            } else {
                emitted += try emitCell(self.alloc, &cell_aw.writer, &self.cells.items[ci], painted, self.think_open, w, skip, scroll_h - emitted);
                skip = 0;
            }
        }
        const nvis_doc = total_vis - composer_block;
        const prefix_rows = bottom.working_rows + bottom.perm_rows + bottom.picker_rows + bottom.slash_rows;
        const composer_doc = nvis_doc + prefix_rows;
        const doc_skip = pin - self.scroll_off;
        self.composer_screen_row = if (composer_doc >= doc_skip) row_blk: {
            const row = composer_doc - doc_skip + top_gap + 1;
            break :row_blk if (row > 0 and row <= scroll_h) row else 0;
        } else 0;

        var block_aw = std.Io.Writer.Allocating.init(self.alloc);
        defer block_aw.deinit();
        if (bottom.working_rows > 0) {
            const frame_ms = @as(i64, @intCast(@divTrunc(std.Io.Clock.now(.awake, util.io).nanoseconds, std.time.ns_per_ms)));
            try writeStatusIndicator(&block_aw.writer, views[0..nact], streaming, frame_ms, w, bottom.working_rows);
        }
        if (self.perm_prompt.load(.acquire)) |pp| {
            var rest = pp.*;
            while (rest.len > 0) {
                const nl = std.mem.indexOfScalar(u8, rest, '\n');
                const line = if (nl) |n| rest[0..n] else rest;
                rest = if (nl) |n| rest[n + 1 ..] else &.{};
                try writeTrunc(&block_aw.writer, line, w);
                try block_aw.writer.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
            }
        }
        if (self.picker) |*p| {
            try writePicker(&block_aw.writer, p, h, w);
        } else if (filesmod.atQuery(self.input.items) != null) {
            try writeFilePicker(&block_aw.writer, self.file_items, &self.file_sel, h, w);
        } else if (slashQuery(self.input.items)) |q| {
            try writeSlashPicker(&block_aw.writer, self.slash_items, q, &self.slash_sel, h, w);
        }
        const cur = wrapCursor(self.input.items, self.cursor, bottom.input_inner);
        const view_skip = composerSkip(cur.row, bottom.comp_inner);
        if (bottom.boxed) {
            const box_w = composerBoxWidth(w);
            try writeBoxEdge(&block_aw.writer, "╭", "╮", box_w);
            try emitComposer(&block_aw.writer, self.input.items, bottom.input_inner, bottom.comp_inner, view_skip);
            try writeBoxEdge(&block_aw.writer, "╰", "╯", box_w);
        } else {
            try block_aw.writer.writeAll(ANSI_DIM ++ "› " ++ ANSI_RESET);
            try writeTrunc(&block_aw.writer, self.input.items, bottom.input_inner);
            try block_aw.writer.writeAll("\x1b[K\r\n");
        }
        const hint = footerHint(.{
            .perm = self.perm_prompt.load(.acquire) != null,
            .picker = self.picker != null,
            .slash = self.picker == null and (slashQuery(self.input.items) != null and self.slash_items.len > 0 or filesmod.atQuery(self.input.items) != null),
            .quit_armed = self.quit_arm_ns != 0,
            .esc_armed = self.esc_armed,
            .scrolled = self.scroll_off > 0,
            .shortcuts = self.shortcuts_open,
            .has_draft = self.input.items.len > 0,
            .running = streaming or nact > 0,
            .image = self.pending_image != null,
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
        try block_aw.writer.writeAll(rows.primary);
        try block_aw.writer.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
        if (bottom.footer_ident_rows >= 2) {
            try block_aw.writer.writeAll(rows.secondary);
            try block_aw.writer.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
        }
        if (self.shortcuts_open) {
            try block_aw.writer.writeAll(ANSI_DIM);
            try writeTrunc(&block_aw.writer, "enter send   tab queue   esc abort   ctrl+c quit", w);
            try block_aw.writer.writeAll(ANSI_RESET ++ "\x1b[K\r\n" ++ ANSI_DIM);
            try writeTrunc(&block_aw.writer, "c copy  d doctor  g diff  l log  r redo  s sandbox  j jobs  u usage  ctrl+v paste  /help", w);
            try block_aw.writer.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
        }
        var out_e: usize = 0;
        var cell_skip: usize = 0;
        for (0..top_gap) |_| {
            try fw.writer.writeAll("\x1b[K\r\n");
            out_e += 1;
        }
        try emitDocLines(&fw.writer, cell_aw.written(), &cell_skip, &out_e, scroll_h);
        try emitDocLines(&fw.writer, block_aw.written(), &skip, &out_e, scroll_h);
        while (out_e < scroll_h) : (out_e += 1) {
            if (out_e + 1 < scroll_h) {
                try fw.writer.writeAll("\x1b[K\r\n");
            } else {
                try fw.writer.writeAll("\x1b[K");
            }
        }
        try fw.writer.writeAll("\x1b[J");
        if (self.composer_screen_row == 0) {
            try fw.writer.writeAll("\x1b[?25l");
        } else {
            const input_row = composerInputRow(self.composer_screen_row, bottom, cur.row);
            const col = @max(@as(usize, 1), @min(w, (if (bottom.boxed) COMPOSER_FRAME else 3) + cur.col));
            try fw.writer.print("\x1b[{d};{d}H\x1b[?25h", .{ input_row, col });
        }
        try self.writeAll(try fw.toOwnedSlice());
    }

    pub const Handlers = struct {
        on_submit: *const fn (tui: *Tui, line: []const u8) anyerror!void,
        is_quit: *const fn (ctx: ?*anyopaque) bool,
        on_abort: ?*const fn (ctx: ?*anyopaque) void = null,
        on_detach: ?*const fn (ctx: ?*anyopaque) void = null,
        on_perm: ?*const fn (ctx: ?*anyopaque, key: u8) void = null,
        on_paint: ?*const fn (ctx: ?*anyopaque) void = null,
        /// 每轮 poll 后无条件回调(50ms):后台完成件在此消费,不依赖 dirty 渲染
        on_tick: ?*const fn (ctx: ?*anyopaque) void = null,
        on_think: ?*const fn (ctx: ?*anyopaque) void = null,
        on_copy: ?*const fn (ctx: ?*anyopaque) void = null,
        on_sandbox: ?*const fn (ctx: ?*anyopaque) void = null,
        on_jobs: ?*const fn (ctx: ?*anyopaque) void = null,
        on_usage: ?*const fn (ctx: ?*anyopaque) void = null,
        on_redo: ?*const fn (ctx: ?*anyopaque) void = null,
        on_doctor: ?*const fn (ctx: ?*anyopaque) void = null,
        on_diff: ?*const fn (ctx: ?*anyopaque) void = null,
        on_log: ?*const fn (ctx: ?*anyopaque) void = null,
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
        const on_tick = h.on_tick;
        const on_think = h.on_think;
        const on_copy = h.on_copy;
        const on_sandbox = h.on_sandbox;
        const on_jobs = h.on_jobs;
        const on_usage = h.on_usage;
        const on_redo = h.on_redo;
        const on_doctor = h.on_doctor;
        const on_diff = h.on_diff;
        const on_log = h.on_log;
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
                            .copy => {
                                if (on_copy) |f| f(ctx);
                            },
                            .sandbox => {
                                if (on_sandbox) |f| f(ctx);
                            },
                            .jobs => {
                                if (on_jobs) |f| f(ctx);
                            },
                            .usage => {
                                if (on_usage) |f| f(ctx);
                            },
                            .redo => {
                                if (on_redo) |f| f(ctx);
                            },
                            .doctor => {
                                if (on_doctor) |f| f(ctx);
                            },
                            .diff => {
                                if (on_diff) |f| f(ctx);
                            },
                            .log => {
                                if (on_log) |f| f(ctx);
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
            if (on_tick) |f| f(ctx);
            if (self.dirty.load(.acquire) or busy) {
                if (on_paint) |f| f(ctx);
                try self.renderFrame();
                self.dirty.store(false, .release);
            }
        }
    }

    const Action = tui_input.Action;

    pub fn disarmQuit(self: *Tui) void {
        if (self.quit_arm_ns == 0) return;
        self.quit_arm_ns = 0;
        self.quit_arm_key = 0;
        self.dirty.store(true, .release);
    }

    pub fn pasteClipboard(self: *Tui) void {
        tui_input.pasteClipboard(self);
    }

    pub fn hasPendingImage(self: *const Tui) bool {
        return tui_input.hasPendingImage(self);
    }

    pub fn takePendingImage(self: *Tui) ?tui_input.PendingImage {
        return tui_input.takePendingImage(self);
    }

    pub fn handleInput(self: *Tui, bytes: []const u8) !Action {
        return tui_input.handleInput(self, bytes);
    }

    pub fn scrollBy(self: *Tui, delta: isize) void {
        if (delta < 0) {
            const d: usize = @intCast(-delta);
            self.scroll_off = if (self.scroll_off > d) self.scroll_off - d else 0;
        } else {
            self.scroll_off = @min(self.last_pin, self.scroll_off + @as(usize, @intCast(delta)));
        }
        self.dirty.store(true, .release);
    }

    fn estimateCellRows(cell: Cell, width: usize) usize {
        if (cell.kind == .tool) {
            if (cell.tool) |tm| return toolRowCount(tm, width);
        }
        return @max(1, wrapRowCount(cell.text.items, @max(width, 8) - 4));
    }

    fn cellMatches(cell: Cell, q: []const u8) bool {
        if (indexOfInsensitive(cell.text.items, q) != null) return true;
        if (cell.tool) |tm| {
            if (indexOfInsensitive(tm.name, q) != null) return true;
            if (indexOfInsensitive(tm.preview, q) != null) return true;
            if (indexOfInsensitive(tm.body.items, q) != null) return true;
        }
        return false;
    }

    fn scrollToCell(self: *Tui, idx: usize) void {
        var row: usize = 0;
        var prev: CellKind = .chrome;
        for (self.cells.items[0..idx]) |c| {
            if (gapBetween(prev, c.kind)) row += 1;
            row += estimateCellRows(c, self.width);
            prev = c.kind;
        }
        if (idx < self.cells.items.len and gapBetween(prev, self.cells.items[idx].kind)) row += 1;
        const pin = self.last_pin;
        self.scroll_off = if (row >= pin) 0 else pin - row;
        self.dirty.store(true, .release);
    }

    /// 在对话块里搜。同查询再调一次则下一条;绕回。
    pub fn findNext(self: *Tui, query: []const u8, reverse: bool) !bool {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        const q = std.mem.trim(u8, query, " \t");
        if (q.len == 0) return false;
        if (self.search_q.len == 0 or !util.eqlIgnoreCase(self.search_q, q)) {
            const d = try self.alloc.dupe(u8, q);
            if (self.search_q.len > 0) self.alloc.free(self.search_q);
            self.search_q = d;
            self.search_hit = null;
        }
        const n = self.cells.items.len;
        if (n == 0) return false;
        const start: usize = self.search_hit orelse if (reverse) 0 else n - 1;
        var i = start;
        var stepped: usize = 0;
        while (stepped < n) {
            if (reverse) {
                i = if (i == 0) n - 1 else i - 1;
            } else {
                i = if (i + 1 >= n) 0 else i + 1;
            }
            stepped += 1;
            if (cellMatches(self.cells.items[i], self.search_q)) {
                if (self.search_hit) |old| self.cells.items[old].hl = false;
                self.cells.items[i].hl = true;
                self.search_hit = i;
                self.scrollToCell(i);
                return true;
            }
        }
        for (self.find_log.items) |s| {
            if (indexOfInsensitive(s, self.search_q) != null) {
                self.status.clearRetainingCapacity();
                self.status.appendSlice("match in pruned history") catch |err| util.debugCatch("tui.find.status", err);
                self.dirty.store(true, .release);
                return true;
            }
        }
        return false;
    }

    pub fn cycleThink(self: *Tui, up: bool) void {
        self.think_level = cfgmod.cycleThinkLevel(self.think_meta, self.think_level, up);
        self.dirty.store(true, .release);
    }

    pub fn historyPrev(self: *Tui) void {
        if (self.history.items.len == 0) return;
        const idx = self.hist_idx orelse self.history.items.len;
        if (idx == 0) return;
        const ni = idx - 1;
        self.hist_idx = ni;
        self.input.clearRetainingCapacity();
        self.input.appendSlice(self.history.items[ni]) catch |err| util.debugCatch("tui.hist.up", err);
        self.cursor = self.input.items.len;
        self.dirty.store(true, .release);
    }

    pub fn historyNext(self: *Tui) void {
        const idx = self.hist_idx orelse return;
        if (idx + 1 >= self.history.items.len) {
            self.hist_idx = null;
            self.input.clearRetainingCapacity();
            self.cursor = 0;
        } else {
            self.hist_idx = idx + 1;
            self.input.clearRetainingCapacity();
            self.input.appendSlice(self.history.items[idx + 1]) catch |err| util.debugCatch("tui.hist.down", err);
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
        // 多行草稿:落盘前 \n → \\n 转义,读回再解(单行条目不受影响;
        // 代价:含字面 "\n" 两字符的旧条目读回会变真换行,仅影响历史回看,记录在案)。
        var esc: ?[]u8 = null;
        defer if (esc) |e| self.alloc.free(e);
        var out = line;
        if (std.mem.indexOfScalar(u8, line, '\n') != null) {
            esc = histEscape(self.alloc, line) catch return;
            out = esc.?;
        }
        wr.interface.writeAll(out) catch return;
        wr.interface.writeAll("\n") catch return;
        wr.flush() catch return;
    }
};

pub fn nowNs() i64 {
    return @intCast(std.Io.Clock.now(.real, util.io).nanoseconds);
}

/// 历史落盘转义:\n → \\n(不碰反斜杠,见 addHistory 注释)。
pub fn histEscape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    for (s) |ch| {
        if (ch == '\n') try out.appendSlice("\\n") else try out.append(ch);
    }
    return out.toOwnedSlice();
}

/// 读回解转义:\\n → \n(无条件;旧文件不含此序列者原样)。
pub fn histUnescape(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, s, "\\n") == null) return alloc.dupe(u8, s);
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '\\' and s[i + 1] == 'n') {
            try out.append('\n');
            i += 2;
        } else {
            try out.append(s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice();
}

fn nowMs() i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.awake, util.io).nanoseconds, std.time.ns_per_ms));
}

fn invalidatePaint(cell: *Cell, alloc: std.mem.Allocator) void {
    if (cell.card_buf) |buf| alloc.free(buf);
    cell.card_buf = null;
    cell.card_w = 0;
    if (cell.md_buf) |buf| alloc.free(buf);
    cell.md_buf = null;
    cell.md_fp = 0;
    cell.row_valid = false;
}

fn deinitCell(cell: *Cell, alloc: std.mem.Allocator) void {
    cell.text.deinit();
    if (cell.card) |card| card.deinit(alloc);
    cell.card = null;
    if (cell.tool) |*tm| tm.deinit(alloc);
    cell.tool = null;
    invalidatePaint(cell, alloc);
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

fn dupeWelcome(alloc: std.mem.Allocator, info: WelcomeInfo) !CardFields {
    var fields = try dupeCard(alloc, info.version, info.model, "", "", "", "", "", "");
    errdefer fields.deinit(alloc);
    const provider = try alloc.dupe(u8, info.provider);
    errdefer alloc.free(provider);
    const tip = try alloc.dupe(u8, info.tip);
    errdefer alloc.free(tip);
    const recents = try alloc.alloc(types.RecentField, info.recents.len);
    var n: usize = 0;
    errdefer {
        for (recents[0..n]) |r| {
            alloc.free(r.title);
            alloc.free(r.when);
        }
        alloc.free(recents);
    }
    for (info.recents) |r| {
        const t = try alloc.dupe(u8, r.title);
        errdefer alloc.free(t);
        recents[n] = .{ .title = t, .when = try alloc.dupe(u8, r.when) };
        n += 1;
    }
    fields.welcome = .{ .provider = provider, .recents = recents, .tip = tip };
    return fields;
}

fn dupeStatus(alloc: std.mem.Allocator, info: StatusInfo) !CardFields {
    return dupeCard(alloc, info.version, info.model, info.think, info.cwd, info.session, info.perms, info.context, info.usage);
}

fn paintCard(alloc: std.mem.Allocator, kind: CellKind, card: CardFields, width: usize) ![]u8 {
    if (card.welcome) |wc| {
        const recents = try alloc.alloc(RecentSession, wc.recents.len);
        defer alloc.free(recents);
        for (wc.recents, 0..) |r, i| recents[i] = .{ .title = r.title, .when = r.when };
        return formatWelcomeCard(alloc, .{
            .version = card.version,
            .model = card.model,
            .provider = wc.provider,
            .recents = recents,
            .tip = wc.tip,
        }, width);
    }
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

pub fn paintedOf(cell: Cell) []const u8 {
    return cell.card_buf orelse "";
}

fn cellFingerprint(cell: Cell) usize {
    var n = cell.text.items.len;
    if (cell.tool) |tm| n += tm.body.items.len + tm.preview.len + @intFromBool(tm.folded);
    if (cell.hl) n += 1;
    return n;
}

pub fn cellRowCountCached(alloc: std.mem.Allocator, cell: *Cell, painted: []const u8, think_open: bool, width: usize) usize {
    const fp = cellFingerprint(cell.*);
    if (cell.row_valid and cell.row_w == width and cell.row_think == think_open and cell.row_fp == fp) {
        return cell.row_n;
    }
    const n = cellRowCount(alloc, cell, painted, think_open, width);
    cell.row_n = n;
    cell.row_w = width;
    cell.row_think = think_open;
    cell.row_fp = fp;
    cell.row_valid = true;
    return n;
}

const writeHighlighted = draw.writeHighlighted;
const writeSlashPicker = draw.writeSlashPicker;
const writeFilePicker = draw.writeFilePicker;
const writePicker = draw.writePicker;
const writeStatusIndicator = draw.writeStatusIndicator;
const writeBoxEdge = draw.writeBoxEdge;
const writeTrunc = draw.writeTrunc;
const skipAnsi = measure.skipAnsi;
const charCols = measure.charCols;
const visibleCols = measure.visibleCols;
pub const writeActivityLine = draw.writeActivityLine;

const deleteUtf8Before = keys.deleteUtf8Before;
const deleteUtf8At = keys.deleteUtf8At;
const utf8PrevLen = keys.utf8PrevLen;
const utf8LenAt = keys.utf8LenAt;

test {
    // 单测主体在 tui_tests.zig(原 38 测试 + 绘制助手);引回以保持 zig test 收集。
    _ = @import("tui_tests.zig");
}
