// tui.zig — 极简交互终端:raw mode、alt screen、流式渲染、行编辑、历史、斜杠命令。
// 设计取舍:无分页滚动、无鼠标、无补全——保持内核最小。
const std = @import("std");
const util = @import("core").util;
const activity = @import("core").activity;

const ANSI_RESET = "\x1b[0m";
const ANSI_DIM = "\x1b[2m";
const ANSI_BOLD = "\x1b[1m";
const ANSI_YELLOW = "\x1b[33m";
const ANSI_CYAN = "\x1b[36m";
const ANSI_GREEN = "\x1b[32m";
const ANSI_RED = "\x1b[31m";

pub const Style = enum { normal, fence, code };

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
        };
        try t.line_starts.append(0);
        return t;
    }

    pub fn deinit(self: *Tui) void {
        self.restoreTerminal();
        self.text.deinit();
        self.line_starts.deinit();
        self.input.deinit();
        self.history.deinit();
        self.status.deinit();
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
                    try self.text.appendSlice(ANSI_CYAN); // codex 纪律:避免黄,inline code 用状态色
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
        try self.appendStyledLocked(s);
        self.dirty.store(true, .release);
    }

    pub fn appendUser(self: *Tui, s: []const u8) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        try self.text.appendSlice(ANSI_GREEN);
        try self.text.appendSlice("❯ ");
        try self.text.appendSlice(ANSI_RESET);
        try self.text.appendSlice(ANSI_BOLD);
        try self.appendStyledLocked(s);
        try self.text.appendSlice(ANSI_RESET);
        if (self.text.items.len > 0 and self.text.items[self.text.items.len - 1] != '\n') {
            try self.text.append('\n');
            try self.line_starts.append(self.text.items.len);
        }
        self.dirty.store(true, .release);
    }

    pub fn appendLine(self: *Tui, prefix: []const u8, color: []const u8, s: []const u8) !void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
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
        // 滚动区 = h - 2(状态行 + 输入行) - 活动行
        const reserved = 2 + nact;
        const scroll_h = if (h > reserved) h - reserved else 1;

        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        const nlines = self.line_starts.items.len;
        const start = if (nlines > scroll_h) nlines - scroll_h else 0;

        try fw.writer.writeAll("\x1b[H\x1b[2J");
        var i = start;
        while (i < nlines) : (i += 1) {
            const from = self.line_starts.items[i];
            const to = if (i + 1 < nlines) self.line_starts.items[i + 1] else self.text.items.len;
            const line = self.text.items[from..to];
            // 行截断(按字符,忽略 ANSI 码计数以简化;超长截字节)
            var end: usize = line.len;
            var cols: usize = 0;
            var j: usize = 0;
            while (j < line.len) {
                if (line[j] == 0x1b) {
                    // 跳过 ANSI 序列
                    if (j + 1 < line.len and line[j + 1] == '[') {
                        var k = j + 2;
                        while (k < line.len and !((line[k] >= '@' and line[k] <= '~'))) k += 1;
                        j = k + 1;
                        continue;
                    }
                    j += 1;
                    continue;
                }
                if (cols >= w) {
                    end = j;
                    break;
                }
                cols += 1;
                j += 1;
            }
            try fw.writer.writeAll(line[0..end]);
            try fw.writer.writeAll("\r\n");
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
        // 状态行:按可视宽度截断(跳过 ANSI 序列,与消息行一致)
        try fw.writer.writeAll(ANSI_RESET);
        try fw.writer.writeAll(self.status_style);
        var scol: usize = 0;
        var sj: usize = 0;
        const sdata = self.status.items;
        while (sj < sdata.len and scol < w) {
            if (sdata[sj] == 0x1b) {
                if (sj + 1 < sdata.len and sdata[sj + 1] == '[') {
                    var k = sj + 2;
                    while (k < sdata.len and !(sdata[k] >= '@' and sdata[k] <= '~')) k += 1;
                    sj = k + 1;
                    continue;
                }
                sj += 1;
                continue;
            }
            scol += 1;
            sj += 1;
        }
        try fw.writer.writeAll(sdata[0..sj]);
        try fw.writer.writeAll(ANSI_RESET);
        try fw.writer.writeAll("\r\n");
        // 权限提示行(若有)
        if (self.perm_prompt.load(.acquire)) |pp| {
            const ps = pp.*;
            try fw.writer.writeAll(ANSI_CYAN); // 权限提示=状态指示色
            try fw.writer.writeAll(ps[0..@min(ps.len, w)]);
            try fw.writer.writeAll(ANSI_RESET);
            try fw.writer.writeAll("\r\n");
        }
        // 输入行
        try fw.writer.writeAll(ANSI_GREEN);
        try fw.writer.writeAll("❯ ");
        try fw.writer.writeAll(ANSI_RESET);
        try fw.writer.writeAll(self.input.items);
        try fw.writer.print("\x1b[{d};{d}H", .{ h, 2 + self.cursor });
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
                            for (buf[0..got]) |b| {
                                switch (b) {
                                    'y', 'n', 'a', 's', 0x03 => f(ctx, b),
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
                            .none => {},
                        }
                    }
                }
            }
            // 有活动在跑时按 spinner 帧率重绘,而不是只等 dirty。
            // dirty 只在有新文本时置位 —— 一条 300 秒的 bash 期间没人碰它,
            // 屏幕会像素级静止,用户无法区分「在干活」和「挂死了」。
            const busy = activity.count() > 0;
            if (self.dirty.load(.acquire) or busy) {
                try self.renderFrame();
                self.dirty.store(false, .release);
            }
        }
    }

    const Action = union(enum) { none, quit, abort, detach, submit: []const u8 };

    fn handleInput(self: *Tui, bytes: []const u8) !Action {
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (self.streaming.load(.acquire)) {
                // 流式/工具执行期间只认两个键:
                //   Ctrl+C 中止,Ctrl+B 把在跑的活动转后台。
                // 不能等用户敲 `/bg` + 回车 —— 整行输入在这个阶段是被吞掉的,
                // 而「命令卡住了想让它后台跑」正是最需要即时响应的时刻。
                if (b == 0x03) return .abort;
                if (b == 0x02) return .detach;
                i += 1;
                continue;
            }
            switch (b) {
                0x03 => { // Ctrl+C:清空输入
                    self.input.clearRetainingCapacity();
                    self.cursor = 0;
                    self.dirty.store(true, .release);
                },
                0x04 => { // Ctrl+D:退出
                    if (self.input.items.len == 0) return .quit;
                },
                '\n', '\r' => {
                    if (self.input.items.len == 0) {
                        i += 1;
                        continue;
                    }
                    const line = try self.alloc.dupe(u8, self.input.items);
                    self.input.clearRetainingCapacity();
                    self.cursor = 0;
                    self.hist_idx = null;
                    return .{ .submit = line };
                },
                0x7f => { // backspace
                    if (self.cursor > 0) {
                        const w = utf8PrevLen(self.input.items, self.cursor);
                        _ = self.input.orderedRemove(self.cursor - 1);
                        for (0..w - 1) |_| _ = self.input.orderedRemove(self.cursor - 1);
                        self.cursor -= w;
                        self.dirty.store(true, .release);
                    }
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
                        _ = self.input.orderedRemove(self.cursor - 1);
                        self.cursor -= 1;
                    }
                    while (self.cursor > 0 and self.input.items[self.cursor - 1] != ' ') {
                        _ = self.input.orderedRemove(self.cursor - 1);
                        self.cursor -= 1;
                    }
                    self.dirty.store(true, .release);
                },
                0x0c => { // Ctrl+L 清屏
                    self.clearScroll();
                },
                0x1b => { // ESC 序列
                    if (i + 1 < bytes.len and bytes[i + 1] == '[') {
                        i += 2;
                        if (i >= bytes.len) break;
                        switch (bytes[i]) {
                            'A' => self.historyPrev(),
                            'B' => self.historyNext(),
                            'C' => {
                                if (self.cursor < self.input.items.len) {
                                    self.cursor += utf8LenAt(self.input.items, self.cursor);
                                }
                                self.dirty.store(true, .release);
                            },
                            'D' => {
                                if (self.cursor > 0) self.cursor -= utf8PrevLen(self.input.items, self.cursor);
                                self.dirty.store(true, .release);
                            },
                            'H' => {
                                self.cursor = 0;
                                self.dirty.store(true, .release);
                            },
                            'F' => {
                                self.cursor = self.input.items.len;
                                self.dirty.store(true, .release);
                            },
                            '3' => { // delete
                                if (i + 1 < bytes.len and bytes[i + 1] == '~') {
                                    if (self.cursor < self.input.items.len) {
                                        _ = self.input.orderedRemove(self.cursor);
                                    }
                                    self.dirty.store(true, .release);
                                }
                            },
                            else => {},
                        }
                        break; // 序列已消费
                    }
                    // 孤立 ESC:忽略
                    i += 1;
                    continue;
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
        try wr.writeAll(ANSI_CYAN);
        try wr.writeAll(activity.spinnerFrame(frame_ms));
        try wr.writeAll(ANSI_RESET ++ " ");
    }
    used += 2;

    const label: []const u8 = switch (v.kind) {
        .tool => v.name,
        .http => "model",
        .subagent => "agent",
    };
    try wr.writeAll(ANSI_BOLD);
    try wr.writeAll(label);
    try wr.writeAll(ANSI_RESET);
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
        try wr.writeAll("  " ++ ANSI_GREEN);
        try wr.writeAll(bs);
        try wr.writeAll(ANSI_RESET);
        used += 2 + bs.len;
    }

    // 重试次数:退避等待期间最需要的信息,否则用户以为网络挂了
    if (v.attempt > 1) {
        var ab: [24]u8 = undefined;
        const as = std.fmt.bufPrint(&ab, "  retry {d}", .{v.attempt - 1}) catch "";
        try wr.writeAll(ANSI_YELLOW);
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
