// tui.zig — Codex layout grammar, Zig + ANSI.
//
// Transcript is a list of typed Cells. Gutters (`› ` / `• ` / `└ `) are
// applied at paint time from Cell.kind — never stored in cell text.
// Session header / status cards store fields and render at the current
// width (not a baked 56-col string).
//
// Layout: measure BottomPane first (working + picker + composer + footer),
// transcript gets the remaining rows, pin-to-bottom scroll.
//
// Bottom pane:
//   Working (Ns • esc to interrupt)   // 1 status + ≤2 └ details
//   picker overlay if open
//   boxed composer (min 3 rows, grows with wrap)
//   footer: hint LEFT, context% RIGHT
//
// Proven pieces kept: raw mode, alt screen, emergency SIGTERM restore,
// UTF-8 edit, CSI/mouse scroll, picker, history file, slash-command keys.
const std = @import("std");
const util = @import("core").util;
const activity = @import("core").activity;
const ai = @import("core").ai;
const cfgmod = @import("core").config;

const ANSI_RESET = "\x1b[0m";
const ANSI_DIM = "\x1b[2m";
const ANSI_REV = "\x1b[7m";
const ANSI_ITALIC = "\x1b[3m";

pub const Style = enum { normal, fence, code };

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

/// One transcript item. `text` never contains `› ` / `• ` / `└ `.
pub const Cell = struct {
    kind: CellKind,
    text: std.array_list.Managed(u8),
    color: []const u8 = "",
    card: ?CardFields = null,
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
    quit_armed: bool = false,
    esc_armed: bool = false,
    scrolled: bool = false,
    shortcuts: bool = false,
    has_draft: bool = false,
    running: bool = false,
};

/// 底栏左侧提示。perm > picker > quit > esc > shortcuts > scrolled > queue > idle。
pub fn footerHint(s: FooterState) ?[]const u8 {
    if (s.perm) return "y allow  n deny  a always  s skip";
    if (s.picker) return "up/down select  enter confirm  esc cancel";
    if (s.quit_armed) return "ctrl+c again to quit";
    if (s.esc_armed) return "esc again to edit last";
    if (s.shortcuts) return "? hide shortcuts";
    if (s.scrolled) return "pgup/pgdn to scroll";
    if (s.running and s.has_draft) return "tab to queue";
    if (!s.has_draft) return "? for shortcuts";
    return null;
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

pub fn formatSessionCard(alloc: std.mem.Allocator, info: SessionInfo, width: usize) ![]u8 {
    const title = try std.fmt.allocPrint(alloc, "\x1b[2m>_ \x1b[0m\x1b[1mpiz\x1b[0m  \x1b[2m(v{s})\x1b[0m", .{info.version});
    defer alloc.free(title);
    const model = try std.fmt.allocPrint(alloc, "\x1b[2mmodel:      \x1b[0m{s}  \x1b[2m{s}  /model\x1b[0m", .{ info.model, info.think });
    defer alloc.free(model);
    const dir = try std.fmt.allocPrint(alloc, "\x1b[2mdirectory:  \x1b[0m{s}", .{info.cwd});
    defer alloc.free(dir);
    const session = try std.fmt.allocPrint(alloc, "\x1b[2msession:    \x1b[0m{s}", .{info.session});
    defer alloc.free(session);
    const lines = [_][]const u8{ title, "", model, dir, session };
    return formatCard(alloc, &lines, width);
}

pub fn formatStatusCard(alloc: std.mem.Allocator, info: StatusInfo, width: usize) ![]u8 {
    const title = try std.fmt.allocPrint(alloc, "\x1b[2m>_ \x1b[0m\x1b[1mpiz\x1b[0m  \x1b[2m(v{s})\x1b[0m", .{info.version});
    defer alloc.free(title);
    const model = try std.fmt.allocPrint(alloc, "\x1b[2mmodel:       \x1b[0m{s}  \x1b[2m{s}\x1b[0m", .{ info.model, info.think });
    defer alloc.free(model);
    const dir = try std.fmt.allocPrint(alloc, "\x1b[2mdirectory:   \x1b[0m{s}", .{info.cwd});
    defer alloc.free(dir);
    const session = try std.fmt.allocPrint(alloc, "\x1b[2msession:     \x1b[0m{s}", .{info.session});
    defer alloc.free(session);
    const perms = try std.fmt.allocPrint(alloc, "\x1b[2mpermissions: \x1b[0m{s}", .{info.perms});
    defer alloc.free(perms);
    const ctx = try std.fmt.allocPrint(alloc, "\x1b[2mcontext:     \x1b[0m{s}", .{info.context});
    defer alloc.free(ctx);
    const usage = try std.fmt.allocPrint(alloc, "\x1b[2musage:       \x1b[0m{s}", .{info.usage});
    defer alloc.free(usage);
    const lines = [_][]const u8{ title, "", model, dir, session, perms, ctx, usage };
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

/// 底栏一次量完。对话区拿剩下的行。
pub const BottomPane = struct {
    working_rows: usize = 0,
    perm_rows: usize = 0,
    picker_rows: usize = 0,
    composer_rows: usize = 0,
    footer_rows: usize = 0,
    boxed: bool = true,
    input_inner: usize = 1,
    comp_inner: usize = 1,

    pub fn height(self: BottomPane) usize {
        return self.working_rows + self.perm_rows + self.picker_rows + self.composer_rows + self.footer_rows;
    }
};

pub const Tui = struct {
    alloc: std.mem.Allocator,
    cells: std.array_list.Managed(Cell),
    mutex: std.Io.Mutex = .init,
    dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    style: Style = .normal,
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
        try self.writeAll("\x1b[?1000h\x1b[?1006h");
        try self.querySize();
    }

    pub fn restoreTerminal(self: *Tui) void {
        if (self.raw) {
            self.raw = false;
            _ = self.writeAll("\x1b[?1006l\x1b[?1000l\x1b[?1049l\x1b[0m") catch {};
            _ = std.posix.tcsetattr(self.in_fd, .NOW, self.orig_tio) catch {};
            emergency_tio = null;
        }
    }

    var emergency_fd: std.posix.fd_t = -1;
    var emergency_tio: ?std.posix.termios = null;

    fn emergencyRestore(signo: std.posix.SIG) callconv(.c) void {
        if (emergency_tio) |tio| {
            _ = std.posix.tcsetattr(emergency_fd, .NOW, tio) catch {};
            const seq = "\x1b[?1006l\x1b[?1000l\x1b[?1049l\x1b[0m";
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

    fn appendStyledTo(self: *Tui, buf: *std.array_list.Managed(u8), s: []const u8) !void {
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            if (c == '\n') {
                try buf.appendSlice(ANSI_RESET);
                try buf.append('\n');
                self.style = .normal;
                i += 1;
                continue;
            }
            if (c == '`') {
                if (self.style == .normal) {
                    try buf.appendSlice(ANSI_DIM);
                    self.style = .code;
                } else if (self.style == .code) {
                    try buf.appendSlice(ANSI_RESET);
                    self.style = .normal;
                } else {
                    try buf.append(c);
                }
                i += 1;
                continue;
            }
            if ((c == '`' or c == '~') and i + 2 < s.len and s[i + 1] == c and s[i + 2] == c) {
                if (self.style == .fence) {
                    try buf.appendSlice(ANSI_RESET);
                    self.style = .normal;
                } else {
                    try buf.appendSlice(ANSI_DIM);
                    self.style = .fence;
                }
                i += 3;
                continue;
            }
            try buf.append(c);
            i += 1;
        }
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
        self.style = .normal;
        self.dirty.store(true, .release);
    }

    pub fn appendUser(self: *Tui, s: []const u8) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        self.think_live = false;
        self.style = .normal;
        const cell = try self.pushCell(.user);
        try self.appendStyledTo(&cell.text, s);
        self.scroll_off = 0;
        self.dirty.store(true, .release);
    }

    pub fn appendLine(self: *Tui, prefix: []const u8, color: []const u8, s: []const u8) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        self.style = .normal;
        const cell = try self.pushCell(.chrome);
        cell.color = color;
        try cell.text.appendSlice(prefix);
        try self.appendStyledTo(&cell.text, s);
        self.dirty.store(true, .release);
    }

    pub fn appendTool(self: *Tui, s: []const u8) !void {
        try self.appendRoleCell(.tool, s);
    }

    pub fn appendToolEnd(self: *Tui, s: []const u8) !void {
        try self.appendRoleCell(.tool_end, s);
    }

    fn appendRoleCell(self: *Tui, kind: CellKind, s: []const u8) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        self.style = .normal;
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

    pub fn clearScroll(self: *Tui) void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        self.freeCells();
        self.style = .normal;
        self.think_open = true;
        self.think_live = false;
        self.scroll_off = 0;
        self.dirty.store(true, .release);
    }

    /// 测试用:正文里有没有这段字。不搜 gutter。
    pub fn contains(self: *const Tui, needle: []const u8) bool {
        for (self.cells.items) |c| {
            if (std.mem.indexOf(u8, c.text.items, needle) != null) return true;
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
        const boxed = w >= 8;
        const input_inner = if (boxed) @max(w, 5) - 5 else @max(w, 2) - 2;
        const wrap_n = wrapRowCount(self.input.items, input_inner);
        const cap = @max(1, h / 4);
        const comp_inner = if (boxed) @max(1, @min(cap, wrap_n)) else 1;
        const composer_rows: usize = if (boxed) 2 + comp_inner else 1;
        const footer_rows: usize = if (self.shortcuts_open) 3 else 1;
        return .{
            .working_rows = workingRows(nact, streaming),
            .perm_rows = perm_rows,
            .picker_rows = picker_rows,
            .composer_rows = composer_rows,
            .footer_rows = footer_rows,
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
            total_vis += cellRowCount(self.cells.items[ci], painted, self.think_open, w);
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
            const n = cellRowCount(self.cells.items[ci], painted, self.think_open, w);
            if (skip >= n) {
                skip -= n;
            } else {
                emitted += try emitCell(&fw.writer, self.cells.items[ci], painted, self.think_open, w, skip, scroll_h - emitted);
                skip = 0;
            }
        }
        while (emitted < scroll_h) : (emitted += 1) {
            try fw.writer.writeAll("\x1b[K\r\n");
        }
        if (bottom.working_rows > 0) {
            const frame_ms = @as(i64, @intCast(@divTrunc(std.Io.Clock.now(.awake, util.io).nanoseconds, std.time.ns_per_ms)));
            try writeStatusIndicator(&fw.writer, views[0..nact], streaming, frame_ms, w);
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
        }
        const cur = wrapCursor(self.input.items, self.cursor, bottom.input_inner);
        if (bottom.boxed) {
            try writeBoxEdge(&fw.writer, "╭", "╮", w);
            try emitComposer(&fw.writer, self.input.items, bottom.input_inner, bottom.comp_inner);
            try writeBoxEdge(&fw.writer, "╰", "╯", w);
        } else {
            try fw.writer.writeAll(ANSI_DIM ++ "› " ++ ANSI_RESET);
            try writeTrunc(&fw.writer, self.input.items, bottom.input_inner);
            try fw.writer.writeAll("\x1b[K\r\n");
        }
        const hint = footerHint(.{
            .perm = self.perm_prompt.load(.acquire) != null,
            .picker = self.picker != null,
            .quit_armed = self.quit_arm_ns != 0,
            .esc_armed = self.esc_armed,
            .scrolled = self.scroll_off > 0,
            .shortcuts = self.shortcuts_open,
            .has_draft = self.input.items.len > 0,
            .running = streaming or nact > 0,
        });
        const transient = self.perm_prompt.load(.acquire) != null or self.picker != null or self.quit_arm_ns != 0 or self.esc_armed;
        const right = if (transient) "" else self.status.items;
        const foot = try layoutFooter(self.alloc, hint, right, w);
        defer self.alloc.free(foot);
        try fw.writer.writeAll(ANSI_DIM);
        try fw.writer.writeAll(foot);
        try fw.writer.writeAll(ANSI_RESET ++ "\x1b[K");
        if (self.shortcuts_open) {
            try fw.writer.writeAll("\r\n" ++ ANSI_DIM);
            try writeTrunc(&fw.writer, "enter send   tab queue   esc abort   ctrl+c quit", w);
            try fw.writer.writeAll(ANSI_RESET ++ "\x1b[K\r\n" ++ ANSI_DIM);
            try writeTrunc(&fw.writer, "/model  /permissions  /think  /help", w);
            try fw.writer.writeAll(ANSI_RESET ++ "\x1b[K");
        }
        try fw.writer.writeAll("\x1b[J");
        const composer_top = @max(@as(usize, 1), h -| (bottom.footer_rows + bottom.composer_rows) + 1);
        const input_row = if (bottom.boxed) composer_top + 1 + cur.row else composer_top;
        const col = @max(@as(usize, 1), @min(w, (if (bottom.boxed) @as(usize, 5) else 3) + cur.col));
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
        const line = try self.alloc.dupe(u8, self.input.items);
        self.input.clearRetainingCapacity();
        self.cursor = 0;
        self.hist_idx = null;
        self.disarmQuit();
        self.esc_armed = false;
        self.shortcuts_open = false;
        return .{ .submit = line };
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
                        .up => self.historyPrev(),
                        .down => self.historyNext(),
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
                    break;
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
            if (b == 0x09) {
                if (streaming) {
                    const act = try self.takeSubmit();
                    if (act != .none) return act;
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
                0x10 => self.historyPrev(),
                0x0e => self.historyNext(),
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
                            .up => p.move(-1),
                            .down => p.move(1),
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

fn deinitCell(cell: *Cell, alloc: std.mem.Allocator) void {
    cell.text.deinit();
    if (cell.card) |card| card.deinit(alloc);
    cell.card = null;
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

fn gapBetween(prev: CellKind, next: CellKind) bool {
    if (next == .user) return true;
    if (next == .think) return prev == .user;
    if (next == .assistant) return prev == .user or prev == .think or prev == .session_header or prev == .status_card;
    if (next == .session_header or next == .status_card) return prev == .assistant or prev == .user or prev == .chrome;
    if (next == .chrome) return prev == .assistant or prev == .user;
    return false;
}

fn gutter(kind: CellKind) struct { first: []const u8, rest: []const u8, pad: usize } {
    return switch (kind) {
        .user => .{ .first = ANSI_DIM ++ "› " ++ ANSI_RESET, .rest = "  ", .pad = 2 },
        .assistant, .tool => .{ .first = ANSI_DIM ++ "• " ++ ANSI_RESET, .rest = "  ", .pad = 2 },
        .think => .{ .first = ANSI_DIM ++ ANSI_ITALIC ++ "• ", .rest = ANSI_DIM ++ ANSI_ITALIC ++ "  ", .pad = 2 },
        .tool_end => .{ .first = ANSI_DIM ++ "  └ " ++ ANSI_RESET, .rest = "    ", .pad = 4 },
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

fn cellRowCount(cell: Cell, painted: []const u8, think_open: bool, width: usize) usize {
    if (cell.kind == .session_header or cell.kind == .status_card) {
        if (painted.len == 0) return 0;
        return countNewlines(painted) + 1;
    }
    if (cell.kind == .think) return thinkRowCount(cell.text.items, think_open, width);
    const inner = gutterInner(cell.kind, width);
    if (cell.text.items.len == 0) return 1;
    var rows: usize = 0;
    var it = std.mem.splitScalar(u8, cell.text.items, '\n');
    while (it.next()) |part| {
        rows += wrapRowCount(part, inner);
    }
    return if (rows == 0) 1 else rows;
}

fn emitCell(wr: *std.Io.Writer, cell: Cell, painted: []const u8, think_open: bool, width: usize, skip: usize, limit: usize) !usize {
    if (limit == 0) return 0;
    if (cell.kind == .session_header or cell.kind == .status_card) {
        return emitPainted(wr, painted, width, skip, limit);
    }
    if (cell.kind == .think) {
        return emitThink(wr, cell.text.items, think_open, width, skip, limit);
    }
    const g = gutter(cell.kind);
    const inner = gutterInner(cell.kind, width);
    if (cell.kind == .chrome and cell.color.len > 0) {
        return emitChrome(wr, cell.color, cell.text.items, inner, skip, limit);
    }
    if (cell.text.items.len == 0) {
        if (skip > 0) return 0;
        try wr.writeAll(g.first);
        try wr.writeAll(ANSI_RESET ++ "\x1b[K\r\n");
        return 1;
    }
    var emitted: usize = 0;
    var skipped: usize = 0;
    var it = std.mem.splitScalar(u8, cell.text.items, '\n');
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
        emitted += try emitWrappedGutter(wr, first_g, g.rest, part, inner, local, limit - emitted);
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
        emitted += try emitWrappedGutter(wr, prefix, prefix, part, width, local, limit - emitted);
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

fn charCols(s: []const u8, i: usize) struct { n: usize, cols: usize } {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    return .{ .n = @min(n, s.len - i), .cols = if (n >= 3) 2 else 1 };
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

fn emitWrappedGutter(wr: *std.Io.Writer, first: []const u8, rest: []const u8, line: []const u8, width: usize, skip: usize, limit: usize) !usize {
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
                try wr.writeAll(if (row == 0) first else rest);
                try wr.writeAll(line[row_from..i]);
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
    try wr.writeAll(if (row == 0) first else rest);
    try wr.writeAll(line[row_from..line.len]);
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
    const inner = @max(width, 3) - 2;
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |p| {
        rows += wrapRowCount(p, inner);
    }
    return if (rows == 0) 1 else rows;
}

fn emitThink(wr: *std.Io.Writer, buf: []const u8, open: bool, width: usize, skip: usize, limit: usize) !usize {
    if (buf.len == 0 or limit == 0) return 0;
    if (!open) {
        if (skip == 0) {
            try wr.writeAll(ANSI_DIM ++ "• thought" ++ ANSI_RESET ++ "\x1b[K\r\n");
            return 1;
        }
        return 0;
    }
    const inner = @max(width, 3) - 2;
    var emitted: usize = 0;
    var skipped: usize = 0;
    var it = std.mem.splitScalar(u8, buf, '\n');
    var first = true;
    while (it.next()) |p| {
        const n = wrapRowCount(p, inner);
        if (skipped + n <= skip) {
            skipped += n;
            first = false;
            continue;
        }
        const local_skip = if (skipped < skip) skip - skipped else 0;
        skipped += n;
        const first_pfx = if (first) ANSI_DIM ++ ANSI_ITALIC ++ "• " else ANSI_DIM ++ ANSI_ITALIC ++ "  ";
        emitted += try emitWrappedGutter(wr, first_pfx, ANSI_DIM ++ ANSI_ITALIC ++ "  ", p, inner, local_skip, limit - emitted);
        first = false;
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

fn emitComposer(wr: *std.Io.Writer, input: []const u8, inner: usize, rows: usize) !void {
    var emitted: usize = 0;
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
            try wr.writeAll(if (emitted == 0) first else rest);
            try wr.writeAll(input[row_from..i]);
            var pad = if (inner > cols) inner - cols else 0;
            while (pad > 0) : (pad -= 1) try wr.writeByte(' ');
            try wr.writeAll(ANSI_DIM ++ "│" ++ ANSI_RESET ++ "\r\n");
            emitted += 1;
            if (emitted == rows) return;
            row_from = i;
            cols = 0;
        }
        cols += ch.cols;
        i += ch.n;
    }
    if (emitted < rows) {
        try wr.writeAll(if (emitted == 0) first else rest);
        try wr.writeAll(input[row_from..input.len]);
        var pad = if (inner > cols) inner - cols else 0;
        while (pad > 0) : (pad -= 1) try wr.writeByte(' ');
        try wr.writeAll(ANSI_DIM ++ "│" ++ ANSI_RESET ++ "\r\n");
        emitted += 1;
    }
    while (emitted < rows) : (emitted += 1) {
        try wr.writeAll(rest);
        var pad = inner;
        while (pad > 0) : (pad -= 1) try wr.writeByte(' ');
        try wr.writeAll(ANSI_DIM ++ "│" ++ ANSI_RESET ++ "\r\n");
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

fn writeStatusIndicator(wr: *std.Io.Writer, views: []const activity.View, streaming: bool, frame_ms: i64, width: usize) !void {
    _ = streaming;
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
    const cap = @min(views.len, 2);
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
    var i: usize = 2;
    while (i < width) : (i += 1) try wr.writeAll("─");
    try wr.writeAll(right);
    try wr.writeAll(ANSI_RESET ++ "\r\n");
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

test "gutters are unique and not baked into cells" {
    const t = std.testing;
    try t.expect(std.mem.indexOf(u8, gutter(.user).first, "› ") != null);
    try t.expect(std.mem.indexOf(u8, gutter(.assistant).first, "• ") != null);
    try t.expect(std.mem.indexOf(u8, gutter(.tool).first, "• ") != null);
    try t.expect(std.mem.indexOf(u8, gutter(.think).first, "• ") != null);
    try t.expect(std.mem.indexOf(u8, gutter(.tool_end).first, "└ ") != null);
    try t.expectEqualStrings("  ", gutter(.assistant).rest);
    try t.expectEqual(@as(usize, 2), gutter(.user).pad);
    try t.expectEqual(@as(usize, 4), gutter(.tool_end).pad);
    try t.expectEqual(@as(usize, 0), gutter(.chrome).pad);
    try t.expectEqual(@as(usize, 78), gutterInner(.user, 80));
    try t.expectEqual(@as(usize, 80), gutterInner(.chrome, 80));

    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendUser("hello");
    try ui.appendText("world");
    try ui.appendThink("hmm");
    try ui.appendTool("bash  ls");
    try ui.appendToolEnd("4B");
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
    try t.expect(std.mem.indexOf(u8, wide, "/model") != null);
    try t.expect(std.mem.indexOf(u8, wide, "1786735635034") != null);
    try t.expect(std.mem.indexOf(u8, narrow, "piz") != null);
    try t.expect(cardInner(80) == 56);
    try t.expect(cardInner(40) == 36);
    try t.expect(wide.len != narrow.len);

    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.setSessionHeader(info);
    try t.expect(ui.cells.items.len == 1);
    try t.expect(ui.cells.items[0].kind == .session_header);
    try t.expectEqual(@as(usize, 0), ui.cells.items[0].text.items.len);
    try t.expect(ui.contains("1786735635034"));
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
    try t.expectEqual(@as(usize, 1), idle.footer_rows);
    try t.expect(idle.height() < 24);
    const busy = ui.measureBottom(5, true);
    try t.expectEqual(@as(usize, 3), busy.working_rows);
    try t.expect(busy.height() > idle.height());
    ui.shortcuts_open = true;
    const help = ui.measureBottom(0, false);
    try t.expectEqual(@as(usize, 3), help.footer_rows);
}
