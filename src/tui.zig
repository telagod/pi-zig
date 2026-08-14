// tui.zig — 极简交互终端:raw mode、alt screen、流式渲染、行编辑、历史、斜杠命令。
// 设计取舍:无分页滚动、无鼠标、无补全——保持内核最小。
// 布局跟 Codex:对话软换行,思考是可折叠块,输入跟在对话后面而不是钉死在屏幕底。
// /permissions /model /think 无参数时弹出选择器(↑↓ Enter Esc),不走补全。
// 底栏一行:指令提示(退出/Esc/选择器/授权)替换状态,不另占一行。
const std = @import("std");
const util = @import("core").util;
const activity = @import("core").activity;
const ai = @import("core").ai;
const cfgmod = @import("core").config;

const ANSI_RESET = "\x1b[0m";
const ANSI_DIM = "\x1b[2m";

pub const Style = enum { normal, fence, code };

/// 对话块。用来在用户 / 思考 / 正文 / 工具之间留空，而不是把所有字糊成一段。
pub const Block = enum { none, user, think, text, chrome };

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

/// 底栏指令优先于状态。perm > picker > quit > esc。
pub fn footerHint(perm: bool, picker: bool, quit_armed: bool, esc_armed: bool) ?[]const u8 {
    if (perm) return "y 允许  n 拒绝  a 全权  s 会话";
    if (picker) return "↑↓ 选择  Enter 确认  Esc 取消";
    if (quit_armed) return "再按一次退出";
    if (esc_armed) return "再按 Esc 编辑上一条";
    return null;
}

pub const Tui = struct {
    alloc: std.mem.Allocator,
    // --- 渲染缓冲 ---
    text: std.array_list.Managed(u8),
    line_starts: std.array_list.Managed(usize),
    mutex: std.Io.Mutex = .init,
    dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    style: Style = .normal,
    // --- 输入 ---
    input: std.array_list.Managed(u8),
    cursor: usize = 0,
    history: std.array_list.Managed([]const u8),
    hist_idx: ?usize = null,
    // --- 终端 ---
    orig_tio: std.posix.termios,
    in_fd: std.posix.fd_t,
    out_fd: std.posix.fd_t,
    width: usize = 80,
    height: usize = 24,
    raw: bool = false,
    // --- 状态 ---
    streaming: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ctx: ?*anyopaque = null,
    /// 权限询问提示行(工作线程写入,指向稳定的 slice 变量;主循环只读)
    perm_prompt: std.atomic.Value(?*const []const u8) = std.atomic.Value(?*const []const u8).init(null),
    status: std.array_list.Managed(u8),
    status_style: []const u8 = ANSI_DIM,
    history_path: []u8,
    block: Block = .none,
    think_buf: std.array_list.Managed(u8),
    /// 思考插在这条 line_starts 下标之前。之后追加的正文在思考下面。
    think_at: ?usize = null,
    think_open: bool = true,
    last_think_len: usize = 0,
    /// 用户选的思考等级。状态栏 ◇ 显示它,不是按思考字数猜。
    think_level: ai.ThinkLevel = .high,
    think_meta: cfgmod.ModelMeta = .{ .reasoning = true },
    /// Codex:空 composer 上 Ctrl+C/D 先武装 1 秒,再按同一键才退出。
    quit_arm_ns: i64 = 0,
    quit_arm_key: u8 = 0,
    /// Codex:空 composer 上 Esc 武装,再按 Esc 把上一条载回输入框。
    esc_armed: bool = false,
    /// 斜杠命令弹出的选择器。有值时键盘不进 composer。
    picker: ?Picker = null,

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
        // 历史文件
        const cfg_dir = try util.configDir(alloc);
        const hist_path = try util.joinPath(alloc, cfg_dir, "history.txt");
        var hist = std.array_list.Managed([]const u8).init(alloc);
        if (std.Io.Dir.cwd().readFileAlloc(util.io, hist_path, alloc, .limited(4 * 1024 * 1024))) |content| {
            defer alloc.free(content);
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                if (line.len > 0) try hist.append(try alloc.dupe(u8, line));
                if (hist.items.len >= 2000) break;
            }
        } else |_| {}
        var t = Tui{
            .alloc = alloc,
            .text = std.array_list.Managed(u8).init(alloc),
            .line_starts = std.array_list.Managed(usize).init(alloc),
            .input = std.array_list.Managed(u8).init(alloc),
            .history = hist,
            .orig_tio = orig_tio,
            .in_fd = in_fd,
            .out_fd = out_fd,
            .status = std.array_list.Managed(u8).init(alloc),
            .history_path = hist_path,
            .think_buf = std.array_list.Managed(u8).init(alloc),
        };
        try t.line_starts.append(0);
        return t;
    }

    pub fn deinit(self: *Tui) void {
        self.restoreTerminal();
        self.closePicker();
        self.text.deinit();
        self.line_starts.deinit();
        self.input.deinit();
        self.history.deinit();
        self.status.deinit();
        self.think_buf.deinit();
    }

    pub fn openPicker(self: *Tui, cmd: []const u8, title: []const u8, items: []const PickerItem, selected: usize) !void {
        self.closePicker();
        self.picker = try Picker.init(self.alloc, cmd, title, items, selected);
        self.disarmQuit();
        self.esc_armed = false;
        self.dirty.store(true, .release);
    }

    pub fn closePicker(self: *Tui) void {
        if (self.picker) |*p| {
            p.deinit(self.alloc);
            self.picker = null;
            self.dirty.store(true, .release);
        }
    }

    // ---------- 终端控制 ----------

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
        try self.writeAll("\x1b[?1049h"); // alt screen
        try self.querySize();
    }

    pub fn restoreTerminal(self: *Tui) void {
        if (self.raw) {
            self.raw = false;
            _ = self.writeAll("\x1b[?1049l\x1b[0m") catch {};
            _ = std.posix.tcsetattr(self.in_fd, .NOW, self.orig_tio) catch {};
            // 正常恢复完就解除急救:之后再收到信号不该对已复位的终端二次写入
            emergency_tio = null;
        }
    }

    // ---------- 信号安全的终端急救 ----------
    //
    // restoreTerminal 靠 defer 调用,而 defer 只在正常控制流上跑。外部 `kill <pid>`、
    // 关终端窗口(SIGHUP)、系统关机、supervisor 停服务发来的 SIGTERM 走内核默认动作,
    // 进程直接死掉,defer 一个都不执行 —— 终端被留在 raw mode,用户 shell 从此
    // 没有回显和行编辑,只能 `reset`。实测确认可触发。
    //
    // 所以把恢复所需的最小状态放在全局,由信号处理器直接用裸 syscall 复位。
    // 处理器里只做这一件事:终端是唯一「不救就会伤到用户」的资源,刷会话/释放内存
    // 都不是 async-signal-safe,放进来只会换一种死法。
    var emergency_fd: std.posix.fd_t = -1;
    var emergency_tio: ?std.posix.termios = null;

    // 0.16:handler 参数是 SIG 枚举而非 i32,`std.posix.write` 已移除
    // (裸 fd 写走 std.os.linux.write)。两处都踩过。
    fn emergencyRestore(signo: std.posix.SIG) callconv(.c) void {
        if (emergency_tio) |tio| {
            _ = std.posix.tcsetattr(emergency_fd, .NOW, tio) catch {};
            // 退出 alt screen + 复位属性,否则用户看到的是一屏残留
            const seq = "\x1b[?1049l\x1b[0m";
            _ = std.os.linux.write(emergency_fd, seq.ptr, seq.len);
        }
        // 恢复默认动作后重发:退出码保持 128+signo,waitpid 的调用方能正确判断死因。
        // 这里不能直接 exit —— 那会把「被 SIGTERM 杀掉」伪装成正常退出。
        std.posix.sigaction(signo, &.{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        }, null);
        _ = std.posix.raise(signo) catch {};
    }

    /// 注册终端急救处理器。enterRaw 成功后调用。
    fn armEmergencyRestore(self: *Tui) void {
        emergency_fd = self.in_fd;
        emergency_tio = self.orig_tio;
        const act = std.posix.Sigaction{
            .handler = .{ .handler = emergencyRestore },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        // raw mode 关了 ISIG,交互式 Ctrl+C 走应用层字节 0x03 不经这里;
        // 但外部 `kill -INT` 仍会送真信号进来,所以 INT 也要接。
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

    // ---------- 文本追加(工作线程调用,持锁) ----------

    fn ensureNlLocked(self: *Tui) !void {
        if (self.text.items.len == 0) return;
        if (self.text.items[self.text.items.len - 1] != '\n') {
            try self.text.append('\n');
            try self.line_starts.append(self.text.items.len);
        }
    }

    fn beginBlockLocked(self: *Tui, to: Block) !void {
        if (self.block == to) return;
        const from = self.block;
        try self.ensureNlLocked();
        const gap = from != .none and switch (to) {
            .user => true,
            .think => from == .user,
            .text => from == .user or from == .think or from == .chrome,
            .chrome, .none => false,
        };
        if (gap) {
            try self.text.append('\n');
            try self.line_starts.append(self.text.items.len);
        }
        self.block = to;
    }

    fn appendStyledLocked(self: *Tui, s: []const u8) !void {
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            if (c == '\n') {
                try self.text.appendSlice(ANSI_RESET);
                try self.text.append('\n');
                try self.line_starts.append(self.text.items.len);
                self.style = .normal;
                i += 1;
                continue;
            }
            if (c == '`') {
                if (self.style == .normal) {
                    try self.text.appendSlice(ANSI_DIM);
                    self.style = .code;
                } else if (self.style == .code) {
                    try self.text.appendSlice(ANSI_RESET);
                    self.style = .normal;
                } else {
                    try self.text.append(c);
                }
                i += 1;
                continue;
            }
            // 代码围栏:行首 ``` 或 ~~~
            if ((c == '`' or c == '~') and i + 2 < s.len and s[i + 1] == c and s[i + 2] == c) {
                if (self.style == .fence) {
                    try self.text.appendSlice(ANSI_RESET);
                    self.style = .normal;
                } else {
                    try self.text.appendSlice(ANSI_DIM);
                    self.style = .fence;
                }
                i += 3;
                continue;
            }
            try self.text.append(c);
            i += 1;
        }
    }

    pub fn appendText(self: *Tui, s: []const u8) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        try self.beginBlockLocked(.text);
        try self.appendStyledLocked(s);
        self.dirty.store(true, .release);
    }

    /// 思考进独立缓冲,渲染时按折叠/展开画。默认展开,Ctrl+T 切换。
    pub fn appendThink(self: *Tui, s: []const u8) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        if (self.think_buf.items.len == 0) {
            try self.ensureNlLocked();
            try self.beginBlockLocked(.think);
            self.think_at = self.line_starts.items.len;
            self.think_open = true;
        }
        try self.think_buf.appendSlice(s);
        self.last_think_len = self.think_buf.items.len;
        self.dirty.store(true, .release);
    }

    pub fn toggleThink(self: *Tui) void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        if (self.think_buf.items.len == 0) return;
        self.think_open = !self.think_open;
        self.dirty.store(true, .release);
    }

    fn bakeThinkLocked(self: *Tui) !void {
        if (self.think_buf.items.len == 0) return;
        self.last_think_len = self.think_buf.items.len;
        var baked = std.array_list.Managed(u8).init(self.alloc);
        defer baked.deinit();
        try baked.appendSlice(ANSI_DIM);
        try baked.appendSlice("  v 思考\n");
        try baked.appendSlice(self.think_buf.items);
        if (baked.items[baked.items.len - 1] != '\n') try baked.append('\n');
        try baked.appendSlice(ANSI_RESET);
        const at = if (self.think_at) |idx|
            if (idx < self.line_starts.items.len) self.line_starts.items[idx] else self.text.items.len
        else
            self.text.items.len;
        try self.text.insertSlice(at, baked.items);
        try rebuildLineStarts(&self.line_starts, self.text.items);
        self.think_buf.clearRetainingCapacity();
        self.think_at = null;
    }

    pub fn appendUser(self: *Tui, s: []const u8) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        try self.bakeThinkLocked();
        try self.beginBlockLocked(.user);
        try self.text.appendSlice(ANSI_DIM);
        try self.text.appendSlice("❯ ");
        try self.text.appendSlice(ANSI_RESET);
        try self.appendStyledLocked(s);
        try self.text.appendSlice(ANSI_RESET);
        try self.ensureNlLocked();
        self.dirty.store(true, .release);
    }

    pub fn appendLine(self: *Tui, prefix: []const u8, color: []const u8, s: []const u8) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        try self.beginBlockLocked(.chrome);
        try self.text.appendSlice(color);
        try self.text.appendSlice(prefix);
        try self.text.appendSlice(ANSI_RESET);
        try self.appendStyledLocked(s);
        try self.text.appendSlice(ANSI_RESET);
        try self.text.append('\n');
        try self.line_starts.append(self.text.items.len);
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
        self.text.clearRetainingCapacity();
        self.line_starts.clearRetainingCapacity();
        self.line_starts.append(0) catch {};
        self.style = .normal;
        self.block = .none;
        self.think_buf.clearRetainingCapacity();
        self.think_at = null;
        self.think_open = true;
        self.dirty.store(true, .release);
    }

    // ---------- 渲染 ----------

    fn renderFrame(self: *Tui) !void {
        var fw = std.Io.Writer.Allocating.init(self.alloc);
        defer fw.deinit();
        const w = self.width;
        const h = self.height;
        // 活动快照先取:活动行要占屏幕行数,滚动区高度得先把它们扣掉,
        // 否则活动一多就把消息挤出屏幕外。
        var views: [activity.MAX_SLOTS]activity.View = undefined;
        var nact = activity.snapshot(&views);
        // 活动行最多占屏幕的三分之一 —— 8 个并行工具不该淹掉对话内容
        const act_cap = @max(1, h / 3);
        if (nact > act_cap) nact = act_cap;
        // 底栏只留状态;输入跟在对话后面。内容太长时滚窗口吃掉上沿。
        var perm_lines: usize = 0;
        if (self.perm_prompt.load(.acquire)) |pp| {
            perm_lines = 1;
            for (pp.*) |c| {
                if (c == '\n') perm_lines += 1;
            }
        }
        const picker_rows: usize = if (self.picker) |*p| p.displayRows(h) else 0;
        // 底栏永远一行:指令提示替换状态,不另占一行。
        const footer_rows: usize = 1;
        const reserved = 1 + footer_rows + nact + perm_lines + picker_rows;
        const scroll_h = if (h > reserved) h - reserved else 1;

        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        const nlines = self.line_starts.items.len;

        try fw.writer.writeAll("\x1b[H\x1b[2J\x1b[?25h");
        var total_vis: usize = 0;
        var li: usize = 0;
        while (li < nlines) : (li += 1) {
            if (self.think_at == li) total_vis += thinkRowCount(self.think_buf.items, self.think_open, w);
            total_vis += wrapRowCount(lineSlice(self.text.items, self.line_starts.items, li), w);
        }
        if (self.think_at == nlines) total_vis += thinkRowCount(self.think_buf.items, self.think_open, w);

        var skip = if (total_vis > scroll_h) total_vis - scroll_h else 0;
        var emitted: usize = 0;
        li = 0;
        while (li < nlines) : (li += 1) {
            if (self.think_at == li) {
                const n = thinkRowCount(self.think_buf.items, self.think_open, w);
                if (skip >= n) {
                    skip -= n;
                } else {
                    emitted += try emitThink(&fw.writer, self.think_buf.items, self.think_open, w, skip, scroll_h - emitted);
                    skip = 0;
                }
            }
            const line = lineSlice(self.text.items, self.line_starts.items, li);
            const n = wrapRowCount(line, w);
            if (skip >= n) {
                skip -= n;
            } else {
                emitted += try emitWrapped(&fw.writer, line, w, skip, scroll_h - emitted);
                skip = 0;
            }
        }
        if (self.think_at == nlines) {
            const n = thinkRowCount(self.think_buf.items, self.think_open, w);
            if (skip >= n) {
                skip -= n;
            } else {
                emitted += try emitThink(&fw.writer, self.think_buf.items, self.think_open, w, skip, scroll_h - emitted);
            }
        }
        // 活动行:每个在跑的工具/请求/子 agent 一行,带 spinner + 耗时 + 进度。
        // 放在状态栏之上,紧贴输入区 —— 用户视线本来就在这里。
        if (nact > 0) {
            const frame_ms = @as(i64, @intCast(@divTrunc(std.Io.Clock.now(.awake, util.io).nanoseconds, std.time.ns_per_ms)));
            for (views[0..nact]) |v| {
                try fw.writer.writeAll(ANSI_RESET);
                try writeActivityLine(&fw.writer, v, frame_ms, w);
                try fw.writer.writeAll("\r\n");
            }
        }
        // 权限提示行(若有)
        if (self.perm_prompt.load(.acquire)) |pp| {
            var rest = pp.*;
            while (rest.len > 0) {
                const nl = std.mem.indexOfScalar(u8, rest, '\n');
                const line = if (nl) |n| rest[0..n] else rest;
                rest = if (nl) |n| rest[n + 1 ..] else &.{};
                try fw.writer.writeAll(line[0..@min(line.len, w)]);
                try fw.writer.writeAll(ANSI_RESET);
                try fw.writer.writeAll("\r\n");
            }
        }
        if (self.picker) |*p| {
            const win = p.window(h);
            try fw.writer.writeAll(ANSI_DIM);
            try writeTrunc(&fw.writer, p.title, w);
            try fw.writer.writeAll(ANSI_RESET ++ "\r\n");
            var pi: usize = win.start;
            while (pi < win.start + win.count) : (pi += 1) {
                const it = p.items[pi];
                const selected = pi == p.sel;
                if (selected) {
                    try fw.writer.writeAll("> ");
                } else {
                    try fw.writer.writeAll(ANSI_DIM ++ "  ");
                }
                var used: usize = 2;
                const label_room = if (w > used) w - used else 0;
                try writeTrunc(&fw.writer, it.label, label_room);
                used += visibleCols(it.label);
                if (it.hint.len > 0 and used + 3 < w) {
                    try fw.writer.writeAll(ANSI_DIM ++ "  ");
                    used += 2;
                    try writeTrunc(&fw.writer, it.hint, w - used);
                }
                try fw.writer.writeAll(ANSI_RESET ++ "\r\n");
            }
        }
        try fw.writer.writeAll(ANSI_DIM ++ "❯ " ++ ANSI_RESET);
        try fw.writer.writeAll(self.input.items);
        try fw.writer.writeAll("\x1b[K\r\n");
        try fw.writer.writeAll(ANSI_RESET);
        const hint = footerHint(
            self.perm_prompt.load(.acquire) != null,
            self.picker != null,
            self.quit_arm_ns != 0,
            self.esc_armed,
        );
        if (hint) |msg| {
            try fw.writer.writeAll(ANSI_DIM);
            try writeTrunc(&fw.writer, msg, w);
            try fw.writer.writeAll(ANSI_RESET);
        } else {
            try fw.writer.writeAll(self.status_style);
            try writeTrunc(&fw.writer, self.status.items, w);
            try fw.writer.writeAll(ANSI_RESET);
        }
        const input_row = @max(@as(usize, 1), @min(h -| 1, 1 + emitted + nact + perm_lines + picker_rows));
        const typed = activity.displayWidth(self.input.items[0..@min(self.cursor, self.input.items.len)]);
        const col = @max(@as(usize, 1), @min(w, 3 + typed));
        try fw.writer.print("\x1b[{d};{d}H", .{ input_row, col });
        try self.writeAll(try fw.toOwnedSlice());
    }

    /// 主循环的回调集。
    pub const Handlers = struct {
        /// 收到整行输入。
        on_submit: *const fn (tui: *Tui, line: []const u8) anyerror!void,
        /// 返回 true 时退出主循环。
        is_quit: *const fn (ctx: ?*anyopaque) bool,
        /// 流式/工具执行期间 Ctrl+C。
        on_abort: ?*const fn (ctx: ?*anyopaque) void = null,
        /// 流式/工具执行期间 Ctrl+B:把在跑的活动转后台。
        on_detach: ?*const fn (ctx: ?*anyopaque) void = null,
        /// 权限提示激活期间的按键(y/n/a/s/Ctrl+C)。
        on_perm: ?*const fn (ctx: ?*anyopaque, key: u8) void = null,
        /// 每帧重绘前刷新状态(思考长度、速率会变)。
        on_paint: ?*const fn (ctx: ?*anyopaque) void = null,
        /// 思考等级被快捷键改过:App 把 tui.think_level 抄到 agent。
        on_think: ?*const fn (ctx: ?*anyopaque) void = null,
        ctx: ?*anyopaque = null,
    };

    /// 主循环:轮询 stdin 与活动状态。
    /// 50ms 一圈 —— 既是输入延迟上限,也是 spinner 的重绘节拍。
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
        var poll_fds = [_]std.posix.pollfd{.{ .fd = self.in_fd, .events = std.posix.POLL.IN, .revents = 0 }};
        while (true) {
            if (is_quit(ctx)) return;
            const n = std.posix.poll(&poll_fds, 50) catch 0;
            if (n > 0) {
                var buf: [256]u8 = undefined;
                const got = std.posix.read(self.in_fd, &buf) catch 0;
                if (got > 0) {
                    // 权限提示激活:y/n/a/s 直接路由,其余忽略
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
            // 有活动在跑时按 spinner 帧率重绘,而不是只等 dirty。
            // dirty 只在有新文本时置位 —— 一条 300 秒的 bash 期间没人碰它,
            // 屏幕会像素级静止,用户无法区分「在干活」和「挂死了」。
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

    /// Codex 空 composer:第一次武装并提示,1 秒内再按同一键才退出。
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
                    switch (classifyCsi(params, final)) {
                        .up => self.historyPrev(),
                        .down => self.historyNext(),
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
                // 孤立 Esc = Codex interrupt_turn;空闲空行再按一次载回上一条
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

            switch (b) {
                '\n', '\r' => {
                    const act = try self.takeSubmit();
                    if (act != .none) return act;
                },
                0x02 => { // Ctrl+B:空闲时左移(emacs/Codex);忙碌已在上面转后台
                    if (self.cursor > 0) self.cursor -= utf8PrevLen(self.input.items, self.cursor);
                    self.dirty.store(true, .release);
                },
                0x06 => { // Ctrl+F 右移
                    if (self.cursor < self.input.items.len) {
                        self.cursor += utf8LenAt(self.input.items, self.cursor);
                    }
                    self.dirty.store(true, .release);
                },
                0x10 => self.historyPrev(), // Ctrl+P
                0x0e => self.historyNext(), // Ctrl+N
                0x08, 0x7f => { // BS / DEL:按码点删,不能逐字节 —— 中文 3 字节时旧写法会 OOB 崩掉
                    deleteUtf8Before(&self.input, &self.cursor);
                    self.dirty.store(true, .release);
                },
                0x01 => { // Ctrl+A
                    self.cursor = 0;
                    self.dirty.store(true, .release);
                },
                0x05 => { // Ctrl+E
                    self.cursor = self.input.items.len;
                    self.dirty.store(true, .release);
                },
                0x0b => { // Ctrl+K kill to end
                    self.input.shrinkRetainingCapacity(self.cursor);
                    self.dirty.store(true, .release);
                },
                0x15 => { // Ctrl+U kill line
                    self.input.clearRetainingCapacity();
                    self.cursor = 0;
                    self.dirty.store(true, .release);
                },
                0x17 => { // Ctrl+W kill word
                    while (self.cursor > 0 and self.input.items[self.cursor - 1] == ' ') {
                        deleteUtf8Before(&self.input, &self.cursor);
                    }
                    while (self.cursor > 0 and self.input.items[self.cursor - 1] != ' ') {
                        deleteUtf8Before(&self.input, &self.cursor);
                    }
                    self.dirty.store(true, .release);
                },
                0x0c => { // Ctrl+L 清屏
                    self.clearScroll();
                },
                else => {
                    if (b >= 0x20) {
                        const w = std.unicode.utf8ByteSequenceLength(b) catch 1;
                        // 截断到可用字节
                        const avail = @min(w, bytes.len - i);
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
                    if (self.picker) |*p| {
                        switch (classifyCsi(params, final)) {
                            .up => p.move(-1),
                            .down => p.move(1),
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
        // 追加到文件
        var f = std.Io.Dir.cwd().createFile(util.io, self.history_path, .{ .permissions = @enumFromInt(0o600) }) catch |e| switch (e) {
            error.PathAlreadyExists => std.Io.Dir.cwd().openFile(util.io, self.history_path, .{ .mode = .write_only }) catch null,
            else => null,
        } orelse return;
        defer f.close(util.io);
        var wbuf: [4096]u8 = undefined;
        var w = f.writer(util.io, &wbuf);
        w.seekTo(f.length(util.io) catch return) catch return;
        w.interface.writeAll(line) catch return;
        w.interface.writeAll("\n") catch return;
        w.flush() catch return;
    }
};

fn nowNs() i64 {
    return @intCast(std.Io.Clock.now(.real, util.io).nanoseconds);
}

fn lineSlice(text: []const u8, starts: []const usize, i: usize) []const u8 {
    const from = starts[i];
    const to = if (i + 1 < starts.len) starts[i + 1] else text.len;
    var line = text[from..to];
    while (line.len > 0 and (line[line.len - 1] == '\n' or line[line.len - 1] == '\r')) {
        line = line[0 .. line.len - 1];
    }
    return line;
}

fn rebuildLineStarts(starts: *std.array_list.Managed(usize), text: []const u8) !void {
    starts.clearRetainingCapacity();
    try starts.append(0);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n' and i + 1 < text.len) try starts.append(i + 1);
    }
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

fn emitWrappedPrefixed(wr: *std.Io.Writer, prefix: []const u8, line: []const u8, width: usize, skip: usize, limit: usize) !usize {
    if (limit == 0) return 0;
    const w = @max(width, 1);
    var emitted: usize = 0;
    var skipped: usize = 0;
    var cols: usize = 0;
    var row_from: usize = 0;
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
                try wr.writeAll(prefix);
                try wr.writeAll(line[row_from..i]);
                try wr.writeAll(ANSI_RESET ++ "\r\n");
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
    try wr.writeAll(prefix);
    try wr.writeAll(line[row_from..line.len]);
    try wr.writeAll(ANSI_RESET ++ "\r\n");
    return emitted + 1;
}

fn emitWrapped(wr: *std.Io.Writer, line: []const u8, width: usize, skip: usize, limit: usize) !usize {
    return emitWrappedPrefixed(wr, "", line, width, skip, limit);
}

const CsiKey = enum { up, down, left, right, home, end, delete, shift_up, shift_down, other };

fn csiShift(params: []const u8) bool {
    if (std.mem.lastIndexOfScalar(u8, params, ';')) |i| {
        return std.mem.eql(u8, params[i + 1 ..], "2");
    }
    return std.mem.eql(u8, params, "2");
}

fn classifyCsi(params: []const u8, final: u8) CsiKey {
    const shift = csiShift(params);
    return switch (final) {
        'A' => if (shift) .shift_up else .up,
        'B' => if (shift) .shift_down else .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        '~' => if (std.mem.eql(u8, params, "3")) .delete else .other,
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
    var rows: usize = 1;
    const inner = @max(width, 3) - 2;
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |p| {
        rows += wrapRowCount(p, inner);
    }
    return rows;
}

fn emitThink(wr: *std.Io.Writer, buf: []const u8, open: bool, width: usize, skip: usize, limit: usize) !usize {
    if (buf.len == 0 or limit == 0) return 0;
    var emitted: usize = 0;
    var skipped: usize = 0;
    const level = classifyThink(buf.len);
    const header: []const u8 = if (open) "  v 思考  ^T" else "  > 思考了一下  ^T";
    if (skipped < skip) {
        skipped += 1;
    } else {
        try wr.writeAll(thinkColor(level));
        try wr.writeAll(header);
        try wr.writeAll(ANSI_RESET);
        try wr.writeAll("\r\n");
        emitted += 1;
        if (emitted == limit or !open) return emitted;
    }
    if (!open) return emitted;
    const inner = @max(width, 3) - 2;
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |p| {
        const n = wrapRowCount(p, inner);
        if (skipped + n <= skip) {
            skipped += n;
            continue;
        }
        const local_skip = if (skipped < skip) skip - skipped else 0;
        skipped += n;
        emitted += try emitWrappedPrefixed(wr, ANSI_DIM ++ "  ", p, inner, local_skip, limit - emitted);
        if (emitted >= limit) return emitted;
    }
    return emitted;
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

/// 渲染一行活动。形如:
///   ⠹ bash  12.4s/30s  4.2KB  npm install --legacy-peer-deps
///   ⠹ task  1m05s/10m  2 running  refactor the parser
///   ⠹ model 3.1s  retry 2/3 · waiting 4s
///
/// 顺序是刻意的:spinner 让眼睛知道「在动」,耗时紧跟其后回答「多久了」,
/// 再往后才是身份细节。宽度不够时砍详情,绝不砍 spinner 和耗时。
pub fn writeActivityLine(wr: *std.Io.Writer, v: activity.View, frame_ms: i64, width: usize) !void {
    var used: usize = 0;
    // spinner:转后台的活动不转 —— 它不再占用前台注意力
    if (v.detached) {
        try wr.writeAll(ANSI_DIM ++ "⏻" ++ ANSI_RESET ++ " ");
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

    // 耗时 / 上限。上限存在时显示分母,让用户知道还有多久会被杀。
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

    // 已搬字节:证明命令真的在产出,不是卡在某个系统调用上
    if (v.bytes > 0) {
        var bb: [24]u8 = undefined;
        const bs = activity.formatBytes(&bb, v.bytes);
        try wr.writeAll("  " ++ ANSI_DIM);
        try wr.writeAll(bs);
        try wr.writeAll(ANSI_RESET);
        used += 2 + bs.len;
    }

    // 重试次数:退避等待期间最需要的信息,否则用户以为网络挂了
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

    // 详情放最后,按剩余**显示列**截断 —— 中文任务描述按字节算会白留三分之二屏幕
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
    // 中文双宽:10 个字在宽度 10 上正好一行,宽度 8 上两行
    try t.expectEqual(@as(usize, 1), wrapRowCount("工作目录是哪里啊", 20));
    try t.expectEqual(@as(usize, 2), wrapRowCount("工作目录是哪里啊", 8));
    try t.expectEqual(@as(usize, 1), thinkRowCount("abc", false, 80));
    try t.expectEqual(@as(usize, 2), thinkRowCount("abc", true, 80));
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
    try t.expect(classifyCsi("", 'H') == .home);
}

test "footer hint wins over status" {
    const t = std.testing;
    try t.expectEqualStrings("y 允许  n 拒绝  a 全权  s 会话", footerHint(true, true, true, true).?);
    try t.expectEqualStrings("↑↓ 选择  Enter 确认  Esc 取消", footerHint(false, true, true, true).?);
    try t.expectEqualStrings("再按一次退出", footerHint(false, false, true, true).?);
    try t.expectEqualStrings("再按 Esc 编辑上一条", footerHint(false, false, false, true).?);
    try t.expect(footerHint(false, false, false, false) == null);
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
        .{ .label = "⚡ yolo", .hint = "不询问", .value = "yolo" },
        .{ .label = "? ask", .hint = "危险工具先问", .value = "ask" },
        .{ .label = "⊘ read-only", .value = "read-only" },
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
