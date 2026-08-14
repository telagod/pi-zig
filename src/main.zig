// main.zig — piz 入口:CLI 解析、交互模式(线程编排)、会话挂载。print/web/pkg 见 cmd_*.zig。
const std = @import("std");
const util = @import("core").util;
const activity = @import("core").activity;
const cfgmod = @import("core").config;
const ai = @import("core").ai;
const agentmod = @import("core").agent;
const sessionmod = @import("core").session;
const toolsmod = @import("core").tools;
const eventsmod = @import("core").events;
const pluginsmod = @import("core").plugins;
const compress = @import("core").compress;
const tui_mod = @import("tui");
const webui_mod = @import("webui.zig");
const cmd_web = @import("cmd_web.zig");
const cmd_print = @import("cmd_print.zig");
const cmd_pkg = @import("cmd_pkg.zig");
const runopts = @import("runopts.zig");

const VERSION = "0.1.0";

const HELP =
    \\piz — pi 的 Zig 重写:极简终端编码 agent
    \\
    \\用法:
    \\  piz [目录] [选项]         交互模式
    \\  piz -p "提示词" [选项]    一次性问答(print 模式)
    \\  echo "提示词" | piz -p
    \\
    \\选项:
    \\  -p, --print      print 模式,流式输出到 stdout
    \\  -m, --model M    指定模型
    \\      --provider P 指定 provider
    \\  -n, --new        新会话(不续载旧会话)
    \\  -c, --continue   续载最近会话(默认行为,显式指明可覆盖 -n 前置)
    \\  -t, --title T    新会话标题
    \\  -r, --read-only  只读模式:不暴露工具
    \\  -x, --execute    工具自动执行,不逐次询问(默认交互模式每次询问)
    \\  -i, --input FILE 从文件读提示词(print 模式)
    \\  -s, --session ID  恢复指定会话(id 见 /sessions 或 -a 输出)
    \\  -a, --async       print 模式后台运行,立即返回会话 id 与日志路径
    \\  -o, --output FMT  print 模式输出格式:text|json|jsonl(默认 text)
    \\      --system TEXT 自定义系统提示(替代默认)
    \\      --models     列出可用模型
    \\      --plugin N   开启插件(可重复)
    \\      --no-plugin N 关闭插件(可重复,撤钩/工具/schema)
    \\      --plugins    列出全部内置插件与启用状态
    \\      --           之后的参数不再当选项(提示词以 '-' 开头时用)
    \\  pkg 子命令: piz pkg install <path> [-l] [-y] | piz pkg list | piz pkg remove <name> [-l]
    \\    (资源包:含 skills/、prompts/ 或 AGENTS.md 的目录;-l 安装到项目 .piz/packages)
    \\    (-y 跳过生命周期钩子确认;包声明的钩子会以 bash -c 执行)
    \\  web 子命令: piz web [--port N] [--no-open] [--token T | --no-token]
    \\    (内置 Web UI;默认 127.0.0.1:5494 + 随机 token,URL 含 #token= 片段)
    \\  -v, --version    版本
    \\  -h, --help       帮助
    \\
    \\配置:~/.piz/settings.json、auth.json、models.json
    \\环境变量:PIZ_DIR、PIZ_PROVIDER、PIZ_MODEL、<PROVIDER>_API_KEY
    \\
;

/// `/help` 输出。每个真实存在的命令都必须在这里出现 —— 漏掉的等于没实现。
/// 下面有测试盯着这份清单与实际分发的一致性。
const SLASH_HELP =
    \\斜杠命令
    \\  /help              列出命令
    \\  /status            刷新状态栏
    \\  /model <m>         切换模型
    \\  /new               新会话
    \\  /sessions          列出本目录会话
    \\  /resume <n>        切到第 n 个会话
    \\  /title <t>         改会话标题
    \\  /tree              消息列表，供 /fork
    \\  /fork <n>          从第 n 条分叉
    \\  /copy              复制最后一条回复
    \\  /undo              撤销上一轮
    \\  /redo              重发上一次输入
    \\  /memory            跨会话记忆
    \\  /compact           压缩上下文
    \\  /shake [images]    裁旧工具输出
    \\  /snap              大段输出打成密图
    \\  /fast-compress     快压状态
    \\  /clear             清空并重开
    \\  /plan <goal>       写 PLAN.md 再执行
    \\  /queue             清空输入队列
    \\  /export            导出 HTML
    \\  /dump              整段会话到剪贴板
    \\  /quit              退出
    \\
    \\编辑
    \\  @./path            把文件贴进消息
    \\  !cmd               跑 shell，输出给模型
    \\  !!cmd              跑 shell，只给你看
    \\  Ctrl+C             取消当前轮
    \\  Ctrl+B             活动转后台
;

// ---------- 交互模式 ----------

const App = struct {
    alloc: std.mem.Allocator,
    tui: *tui_mod.Tui,
    agent: *agentmod.Agent,
    sess: *sessionmod.Session,
    cfg: *cfgmod.Config,
    events: *eventsmod.Bus,
    quit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    abort: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker: ?std.Thread = null,
    model_override: ?[]const u8 = null,
    provider_override: ?[]const u8 = null,
    read_only: bool = false,
    /// 权限状态:worker 询问,主循环应答。
    perm: struct {
        pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// 0=等待 1=允许 2=拒绝
        decision: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
        /// 提示文案缓冲(worker 构建,主循环只读,请求期间常驻)
        buf: std.array_list.Managed(u8),
        /// 提示 slice 快照(TUI 原子指针指向此处)
        slice: []const u8 = "",
        /// 本会话已选 always:后续工具不再询问
        always: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    },
    /// 上一条普通消息(/redo 用)
    last_line: []const u8 = "",
    /// steering 队列:worker 忙时提交的消息排队,轮次间自动投递
    queue: std.array_list.Managed([]const u8),
    queue_mutex: std.Io.Mutex = .init,
    /// worker 存活标志(主线程提交时判断是否排队)
    worker_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_usage: ai.Usage = .{},
    /// 会话累计 token(状态栏 t/s)
    tokens_total: usize = 0,
    /// worker 每轮结束发布的上下文 token 估算(主线程状态栏读它)。
    ///
    /// 主线程不能现场调 estTokens:那会遍历 messages,而 worker 正在 append
    /// (std 的 append 先加 len 后写数据,读侧撞上半写消息会 segfault ——
    /// web 侧实测过同一机制)。worker 与主线程只经这个原子交换。
    est_ctx: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// 会话起始时刻(ns,状态栏 t/s)
    start_ns: i128,

    /// 队列消息入队(主线程调用)。
    fn enqueue(self: *App, line: []const u8) void {
        self.queue_mutex.lock(util.io) catch {};
        defer self.queue_mutex.unlock(util.io);
        self.queue.append(self.alloc.dupe(u8, line) catch return) catch {};
    }

    /// 取队首消息(worker 调用);空返回 null。
    fn dequeue(self: *App) ?[]const u8 {
        self.queue_mutex.lock(util.io) catch {};
        defer self.queue_mutex.unlock(util.io);
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    /// 清空队列。
    fn clearQueue(self: *App) void {
        self.queue_mutex.lock(util.io) catch {};
        defer self.queue_mutex.unlock(util.io);
        for (self.queue.items) |q| self.alloc.free(q);
        self.queue.clearRetainingCapacity();
    }

    /// 极简状态栏(omp minimal preset 分段 × codex 配色纪律):
    /// path(dim) │ git 分支(cyan) ctx%(分级色) model(cyan) · 缓存%(dim) · 标题(dim)
    fn statusLine(self: *App) ![]u8 {
        var stw = std.Io.Writer.Allocating.init(self.alloc);
        defer stw.deinit();
        const w = &stw.writer;
        // path:最后两段缩写
        var path_seg: []const u8 = self.agent.cwd;
        var slash_count: usize = 0;
        var i = self.agent.cwd.len;
        while (i > 0 and slash_count < 2) {
            i -= 1;
            if (self.agent.cwd[i] == '/') slash_count += 1;
        }
        if (slash_count >= 2) path_seg = self.agent.cwd[i + 1 ..];
        try w.print("\x1b[2m{s}\x1b[0m", .{path_seg});
        // git 分支(本地读 .git/HEAD,无子进程)
        if (gitBranch(self.alloc)) |br| {
            defer self.alloc.free(br);
            try w.print(" \x1b[36m{s}\x1b[0m", .{br});
        }
        // ctx%:分级色(绿 <50 / cyan 50-85 / red >85——codex 禁黄)
        const cw = self.agent.ctxWindow();
        // 读 worker 发布的估算值,不现场遍历 messages(见 est_ctx 注释)
        const used = self.est_ctx.load(.acquire);
        const pct = if (cw > 0) used * 100 / cw else 0;
        const pct_col: []const u8 = if (pct > 85) "31" else if (pct > 50) "36" else "32";
        try w.print(" \x1b[{s}m{d}%\x1b[0m", .{ pct_col, pct });
        // model 缩写(去 provider 前缀)
        var model_seg: []const u8 = self.agent.model;
        if (std.mem.indexOfScalar(u8, model_seg, '-')) |dash| model_seg = model_seg[dash + 1 ..];
        try w.print(" \x1b[36m{s}/{s}\x1b[0m", .{ self.agent.provider.name, model_seg });
        // 缓存命中率(dim)。Anthropic 的 input_tokens 不含缓存部分,
        // 故总输入 = input + cache_read + cache_write。
        if (self.last_usage.cache_read) |c| {
            const w_tok = self.last_usage.cache_write orelse 0;
            const total = c + w_tok + (self.last_usage.input orelse 0);
            if (total > 0) {
                if (c > 0) {
                    try w.print(" \x1b[2m· cache {d}%\x1b[0m", .{c * 100 / total});
                } else if (w_tok > 0) {
                    // 刚写入缓存:下一轮才开始省。与「压根没缓存」区分开,
                    // 否则用户看到 cache 0% 会以为配置没生效。
                    try w.print(" \x1b[2m· cache warm\x1b[0m", .{});
                }
            }
        }
        // token 速率 t/s(dim)——omp token_rate 段
        if (self.tokens_total > 0) {
            const now_ns = std.Io.Clock.now(.real, util.io).nanoseconds;
            const elapsed_s = @max(1, @divTrunc(now_ns - self.start_ns, std.time.ns_per_s));
            try w.print(" \x1b[2m· {d} t/s\x1b[0m", .{self.tokens_total / @as(usize, @intCast(elapsed_s))});
        }
        // 压缩次数(cyan,>0 时)——omp context_mgr 段
        if (self.agent.compacts > 0) try w.print(" \x1b[36m⊞{d}\x1b[0m", .{self.agent.compacts});
        if (self.read_only) try w.writeAll(" \x1b[2m· RO\x1b[0m");
        if (self.sess.title) |tt| try w.print(" \x1b[2m· {s}\x1b[0m", .{tt});
        return stw.toOwnedSlice();
    }

    /// 读 .git/HEAD 取分支名(极简,无子进程)。
    fn gitBranch(alloc: std.mem.Allocator) ?[]u8 {
        const head = std.Io.Dir.cwd().readFileAlloc(util.io, ".git/HEAD", alloc, .limited(1024)) catch return null;
        defer alloc.free(head);
        const ref = "ref: refs/heads/";
        if (!std.mem.startsWith(u8, head, ref)) return null;
        const br = std.mem.trim(u8, head[ref.len..], " \r\n");
        return alloc.dupe(u8, br) catch null;
    }

    fn switchModel(self: *App, spec: []const u8) !void {
        // 支持 provider/model 与 model 两种写法
        const ro = self.read_only;
        if (std.mem.indexOfScalar(u8, spec, '/')) |slash| {
            const p = spec[0..slash];
            const m = spec[slash + 1 ..];
            const agent = try agentmod.Agent.initOpts(self.alloc, self.cfg, p, m, self.agent.cwd, .{ .read_only = ro, .depth = self.agent.depth, .plugins = self.agent.plugins });
            self.agent.deinit();
            self.agent.* = agent;
            self.provider_override = p;
            self.model_override = m;
        } else {
            const agent = try agentmod.Agent.initOpts(self.alloc, self.cfg, self.provider_override, spec, self.agent.cwd, .{ .read_only = ro, .depth = self.agent.depth, .plugins = self.agent.plugins });
            self.agent.deinit();
            self.agent.* = agent;
            self.model_override = spec;
        }
    }

    /// 切换会话:载入消息并替换 app.sess。
    fn loadSession(self: *App, sess: sessionmod.Session) !void {
        var s = sess;
        const loaded = try s.loadMessages();
        self.agent.messages.clearRetainingCapacity();
        try self.agent.messages.appendSlice(loaded);
        self.sess.deinit();
        self.sess.* = sess;
    }
};

fn tuiOnText(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    app.tui.appendText(text) catch {};
    if (app.abort.load(.acquire)) return error.Aborted;
}

fn tuiOnReasoning(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    // 思考块:dim 斜体包裹
    var buf = std.array_list.Managed(u8).init(app.alloc);
    defer buf.deinit();
    buf.appendSlice("\x1b[3m") catch {};
    buf.appendSlice(text) catch {};
    buf.appendSlice("\x1b[0m") catch {};
    app.tui.appendText(buf.items) catch {};
    if (app.abort.load(.acquire)) return error.Aborted;
}

/// 工具参数预览:优先抽出 command / path / pattern,别整段 JSON 糊在一行上。
fn toolArgsPreview(args: []const u8) []const u8 {
    const keys = [_][]const u8{ "\"command\":\"", "\"pattern\":\"", "\"query\":\"", "\"path\":\"" };
    for (keys) |k| {
        if (std.mem.indexOf(u8, args, k)) |i| {
            const start = i + k.len;
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
    }
    return args;
}

fn tuiOnToolStart(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    var buf = std.array_list.Managed(u8).init(app.alloc);
    defer buf.deinit();
    buf.appendSlice("\x1b[2m⚙\x1b[0m ") catch {};
    buf.appendSlice(name) catch {};
    const preview = toolArgsPreview(args);
    if (preview.len > 0) {
        buf.appendSlice("  \x1b[2m") catch {};
        const head = preview[0..@min(preview.len, 120)];
        buf.appendSlice(head) catch {};
        if (preview.len > 120) buf.appendSlice("…") catch {};
        buf.appendSlice("\x1b[0m") catch {};
    }
    app.tui.appendLine("", "", buf.items) catch {};
    // 事件 payload 用临时 arena:emit 不接管所有权,jsonString 也各自分配
    var ea = util.Arena.init(app.alloc);
    defer ea.deinit();
    const ealloc = ea.allocator();
    app.events.emit("tool_start", std.fmt.allocPrint(ealloc, "\"tool\":{s},\"args\":{s}", .{
        try util.jsonString(ealloc, name),
        try util.jsonString(ealloc, args[0..@min(args.len, 500)]),
    }) catch return);
}

fn tuiOnToolEnd(ctx: ?*anyopaque, name: []const u8, is_error: bool, summary: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    var buf = std.array_list.Managed(u8).init(app.alloc);
    defer buf.deinit();
    buf.appendSlice(if (is_error) "✗ " else "✓ ") catch {};
    buf.appendSlice(name) catch {};
    // 输出规模:工具产出整体进了模型上下文而用户看不到内容,
    // 至少让他知道这一步吃掉了多少 —— 12KB 和 40B 是完全不同的信号。
    var bb: [24]u8 = undefined;
    buf.appendSlice(" \x1b[2m") catch {};
    buf.appendSlice(activity.formatBytes(&bb, summary.len)) catch {};
    buf.appendSlice("\x1b[0m") catch {};
    app.tui.appendLine("", if (is_error) "\x1b[31m" else "\x1b[32m", buf.items) catch {};
    var ea = util.Arena.init(app.alloc);
    defer ea.deinit();
    const ealloc = ea.allocator();
    app.events.emit("tool_end", std.fmt.allocPrint(ealloc, "\"tool\":{s},\"error\":{s}", .{
        try util.jsonString(ealloc, name),
        if (is_error) "true" else "false",
    }) catch return);
}

fn tuiOnTurnEnd(ctx: ?*anyopaque) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    const st = app.statusLine() catch return;
    app.tui.setStatus("\x1b[0m", st) catch {};
    app.events.emit("turn_end", "");
}

/// 引擎级告知:自愈动作、限额触顶。用 dim 加 `·` 前缀与模型输出区分开 ——
/// 用户要能一眼看出「这是 piz 在说话」而不是模型在说。
fn tuiOnNotice(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    var buf = std.array_list.Managed(u8).init(app.alloc);
    defer buf.deinit();
    buf.appendSlice("· ") catch {};
    buf.appendSlice(text) catch {};
    app.tui.appendLine("", "\x1b[33m", buf.items) catch {};
}

/// subagent 中间事件 → TUI 一行。
///
/// 逐 token 的正文不显示:32 路并行的文本混在一起没人读得懂,而
/// 「3 号在跑 grep」是真进度。委派原先是纯黑盒,界面上只有一个转圈。
fn tuiOnSubagent(ctx: ?*anyopaque, idx: usize, kind: agentmod.SubagentEvent, text: []const u8) anyerror!void {
    switch (kind) {
        .text, .reasoning => return,
        else => {},
    }
    const app: *App = @ptrCast(@alignCast(ctx.?));
    const tag = switch (kind) {
        .tool_start => "⚙",
        .tool_done => "✓",
        .tool_failed => "✗",
        .notice => "·",
        .finished => "▣",
        else => " ",
    };
    // 栈缓冲而非 app.alloc:32 路 subagent 并发调这个回调,而 app.alloc 是
    // ArenaAllocator —— 它不是线程安全的。clampUtf8 保证不切断多字节字符。
    const clipped = util.clampUtf8(text, 100);
    var line: [224]u8 = undefined;
    const s = std.fmt.bufPrint(&line, "[sub {d}] {s} {s}", .{ idx, tag, clipped }) catch return;
    const color = if (kind == .tool_failed) "\x1b[31m" else "\x1b[2m";
    // appendLine 自己有锁(tui.zig),行不会交错
    app.tui.appendLine("", color, s) catch {};
}

/// 权限询问(worker 线程):构建提示 → 置 pending → 轮询决策。
fn tuiOnRequirePermission(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!bool {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (app.perm.always.load(.acquire)) return true;
    if (app.read_only) return false;
    // 构建提示(截断 args)
    app.perm.buf.clearRetainingCapacity();
    try app.perm.buf.appendSlice("? ");
    try app.perm.buf.appendSlice(name);
    try app.perm.buf.appendSlice("  ");
    const head = args[0..@min(args.len, 160)];
    try app.perm.buf.appendSlice(head);
    if (args.len > 160) try app.perm.buf.appendSlice("…");
    try app.perm.buf.appendSlice("\n  \x1b[32m[y]\x1b[0m 允许  \x1b[31m[n]\x1b[0m 拒绝  \x1b[36m[a]\x1b[0m 本会话总是  \x1b[2m[s]\x1b[0m 跳过");
    app.perm.decision.store(0, .release);
    app.perm.pending.store(true, .release);
    app.perm.slice = app.perm.buf.items;
    app.tui.perm_prompt.store(&app.perm.slice, .release);
    app.tui.dirty.store(true, .release);
    defer {
        app.tui.perm_prompt.store(null, .release);
        app.tui.dirty.store(true, .release);
        app.perm.pending.store(false, .release);
    }
    // 轮询决策(主循环按键应答);Ctrl+C 中止
    while (app.perm.pending.load(.acquire)) {
        if (app.abort.load(.acquire)) return false;
        _ = std.Io.sleep(util.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
    }
    return app.perm.decision.load(.acquire) == 1;
}

/// 权限按键路由(主循环):y/n/a/s/Ctrl+C。
fn tuiOnPermKey(ctx: ?*anyopaque, key: u8) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    switch (key) {
        'y' => app.perm.decision.store(1, .release),
        'n', 0x03 => app.perm.decision.store(2, .release),
        'a' => {
            app.perm.always.store(true, .release);
            app.perm.decision.store(1, .release);
        },
        's' => app.perm.decision.store(2, .release),
        else => {},
    }
}

const WorkerCtx = struct {
    app: *App,
    line: []const u8,
    is_compact: bool = false,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn workerMain(wctx: *WorkerCtx) void {
    const app = wctx.app;
    app.tui.streaming.store(true, .release);
    app.worker_active.store(true, .release);
    defer {
        app.tui.streaming.store(false, .release);
        app.worker_active.store(false, .release);
        wctx.done.store(true, .release);
    }
    // 先处理主消息(可能为 /compact),再循环投递 steering 队列
    var first = true;
    while (true) {
        if (app.abort.load(.acquire)) break;
        var line: ?[]const u8 = null;
        var is_compact = false;
        if (first) {
            line = wctx.line;
            is_compact = wctx.is_compact;
            first = false;
        } else {
            line = app.dequeue();
            if (line == null) break;
            app.tui.appendUser(line.?) catch {}; // 显示排队消息
        }
        const msg = line.?;
        const n_before = app.agent.messages.items.len;
        var err_msg: ?[]const u8 = null;
        if (is_compact) {
            const summary = app.agent.compact() catch |err| blk: {
                err_msg = @errorName(err);
                break :blk "";
            };
            if (err_msg == null) {
                app.tui.appendLine("", "\x1b[2m", "📦 conversation compacted") catch {};
                _ = summary;
            }
        } else {
            const result = app.agent.send(msg) catch |err| blk: {
                if (err == error.Aborted) {
                    // 中断:partial 已流式输出,静默收尾(保存增量照常)
                    break :blk ai.RunResult{};
                }
                err_msg = @errorName(err);
                break :blk ai.RunResult{};
            };
            if (result.error_msg) |emsg| err_msg = emsg;
            app.last_usage = result.usage;
            const u = result.usage;
            app.tokens_total += (u.input orelse 0) + (u.output orelse 0) + (u.cache_read orelse 0);
        }
        if (err_msg) |emsg| {
            var buf = std.array_list.Managed(u8).init(app.alloc);
            defer buf.deinit();
            buf.appendSlice("⚠ ") catch {};
            buf.appendSlice(emsg) catch {};
            app.tui.appendLine("", "\x1b[31m", buf.items) catch {};
        } else {
            // 保存会话增量。失败要提醒(只一次,防刷屏):磁盘满/权限错时
            // 静默吞掉会让用户在重启后丢历史而不自知。
            var save_warned = false;
            for (app.agent.messages.items[n_before..]) |*m| {
                app.sess.saveMessage(m) catch |e| {
                    if (save_warned) continue;
                    save_warned = true;
                    var wbuf = std.array_list.Managed(u8).init(app.alloc);
                    defer wbuf.deinit();
                    wbuf.appendSlice("⚠ 会话保存失败(") catch {};
                    wbuf.appendSlice(@errorName(e)) catch {};
                    wbuf.appendSlice("),重启后可能丢失 —— 检查磁盘空间与 ~/.piz/sessions 权限") catch {};
                    app.tui.appendLine("", "\x1b[31m", wbuf.items) catch {};
                };
            }
        }
        app.agent.aborted.store(false, .release);
        // 发布本轮后的上下文占用:主线程状态栏经它读,不碰活 messages
        app.est_ctx.store(app.agent.estTokens(), .release);
        const st = app.statusLine() catch return;
        app.tui.setStatus("\x1b[0m", st) catch {};
        if (err_msg != null) break; // 出错停止投递后续队列
    }
}

/// 复制文本到剪贴板:wl-copy(Wayland) → xclip(X11);均不可用返回 false。
fn copyToClipboard(alloc: std.mem.Allocator, text: []const u8) bool {
    const candidates = [_][]const []const u8{
        &.{"wl-copy"},
        &.{ "xclip", "-selection", "clipboard" },
    };
    for (candidates) |argv| {
        var child = std.process.spawn(util.io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch continue;
        defer {
            _ = child.wait(util.io) catch {};
        }
        // 写完必须把 stdin 关掉,否则 wl-copy/xclip 一直等 EOF,child.wait 卡死。
        //
        // 关完要把 handle 置空:`child.wait` 内部还会再关一遍
        // (Threaded.childCleanupPosix → closeFd(stdin.handle)),同一个 fd
        // 关两次拿到 EBADF,std 视为 OS bug —— Debug 构建直接
        // `unreachable`,整个 piz 崩掉。实测 /copy 必崩。
        if (child.stdin) |f| {
            var wbuf: [8192]u8 = undefined;
            var w = f.writer(util.io, &wbuf);
            if (w.interface.writeAll(text)) |_| {
                w.flush() catch {};
            } else |_| {}
            f.close(util.io);
            child.stdin = null;
        }
        return true;
    }
    _ = alloc;
    return false;
}

fn onSubmit(tui: *tui_mod.Tui, line: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(tui.ctx orelse return));
    app.tui.addHistory(line);
    // 斜杠命令
    if (line.len > 0 and line[0] == '/') {
        const cmd = line[1..];
        if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "exit") or std.mem.eql(u8, cmd, "q")) {
            app.quit.store(true, .release);
            return;
        }
        if (std.mem.eql(u8, cmd, "clear")) {
            app.agent.messages.clearRetainingCapacity();
            app.tui.clearScroll();
            app.sess.deinit();
            app.sess.* = sessionmod.Session.fresh(app.alloc, app.agent.cwd) catch return;
            return;
        }
        if (std.mem.eql(u8, cmd, "new")) {
            // 新会话(带可选标题)
            app.agent.messages.clearRetainingCapacity();
            app.tui.clearScroll();
            app.sess.deinit();
            app.sess.* = sessionmod.Session.fresh(app.alloc, app.agent.cwd) catch return;
            app.tui.appendLine("", "\x1b[2m", "📄 new session started") catch {};
            const st = app.statusLine() catch return;
            app.tui.setStatus("\x1b[32m", st) catch {};
            return;
        }
        if (std.mem.startsWith(u8, cmd, "title ")) {
            const title = std.mem.trim(u8, cmd["title ".len..], " ");
            app.sess.setTitle(title) catch |err| {
                var bw = std.Io.Writer.Allocating.init(app.alloc);
                defer bw.deinit();
                bw.writer.print("set title failed: {s}", .{@errorName(err)}) catch {};
                app.tui.appendLine("", "\x1b[31m", bw.written()) catch {};
                return;
            };
            app.tui.appendLine("", "\x1b[2m", if (title.len > 0) "✎ title set" else "✎ title cleared") catch {};
            const st = app.statusLine() catch return;
            app.tui.setStatus("\x1b[32m", st) catch {};
            return;
        }
        if (std.mem.eql(u8, cmd, "sessions")) {
            const list = sessionmod.Session.list(app.alloc, app.agent.cwd) catch &.{};
            defer for (list) |s| {
                var s2 = s;
                s2.deinit();
            };
            if (list.len == 0) {
                app.tui.appendLine("", "\x1b[2m", "no sessions yet — /new to start one") catch {};
                return;
            }
            var bw = std.Io.Writer.Allocating.init(app.alloc);
            defer bw.deinit();
            bw.writer.print("{d} sessions:\n", .{list.len}) catch {};
            for (list, 0..) |s, i| {
                const ts = std.fs.path.basename(s.path);
                if (std.mem.eql(u8, s.path, app.sess.path)) {
                    bw.writer.print("{d}. {s} (current)", .{ i + 1, ts }) catch {};
                } else {
                    bw.writer.print("{d}. {s}", .{ i + 1, ts }) catch {};
                }
                if (s.title) |tt| bw.writer.print(" — {s}", .{tt}) catch {};
                bw.writer.print("\n", .{}) catch {};
            }
            bw.writer.writeAll("use /resume <n> to switch") catch {};
            app.tui.appendLine("", "\x1b[36m", bw.written()) catch {};
            return;
        }
        if (std.mem.startsWith(u8, cmd, "resume ")) {
            const nstr = std.mem.trim(u8, cmd["resume ".len..], " ");
            const n = std.fmt.parseInt(usize, nstr, 10) catch {
                app.tui.appendLine("", "\x1b[31m", "usage: /resume <n>  (see /sessions)") catch {};
                return;
            };
            const list = sessionmod.Session.list(app.alloc, app.agent.cwd) catch &.{};
            if (n == 0 or n > list.len) {
                for (list) |s| {
                    var s2 = s;
                    s2.deinit();
                }
                app.tui.appendLine("", "\x1b[31m", "no such session") catch {};
                return;
            }
            const target = list[n - 1];
            app.loadSession(target) catch |err| {
                for (list) |s| {
                    var s2 = s;
                    s2.deinit();
                }
                var bw = std.Io.Writer.Allocating.init(app.alloc);
                defer bw.deinit();
                bw.writer.print("resume failed: {s}", .{@errorName(err)}) catch {};
                app.tui.appendLine("", "\x1b[31m", bw.written()) catch {};
                return;
            };
            // target 所有权已移交 app.sess;其余释放
            for (list, 0..) |s, i| {
                if (i != n - 1) {
                    var s2 = s;
                    s2.deinit();
                }
            }
            var bw = std.Io.Writer.Allocating.init(app.alloc);
            defer bw.deinit();
            bw.writer.print("resumed {s}: {d} messages", .{ std.fs.path.basename(app.sess.path), app.agent.messages.items.len }) catch {};
            app.tui.appendLine("", "\x1b[2m", bw.written()) catch {};
            const st = app.statusLine() catch return;
            app.tui.setStatus("\x1b[32m", st) catch {};
            return;
        }
        if (std.mem.eql(u8, cmd, "undo")) {
            if (app.worker_active.load(.acquire)) {
                app.tui.appendLine("", "\x1b[31m", "cannot undo while a turn is running") catch {};
                return;
            }
            if (!app.agent.undo()) {
                app.tui.appendLine("", "\x1b[2m", "nothing to undo") catch {};
                return;
            }
            app.sess.truncate(app.agent.messages.items.len) catch {};
            app.tui.appendLine("", "\x1b[2m", "↶ undone last turn") catch {};
            return;
        }
        if (std.mem.startsWith(u8, cmd, "model ")) {
            const spec = std.mem.trim(u8, cmd["model ".len..], " ");
            if (spec.len == 0) {
                app.tui.appendLine("", "\x1b[31m", "usage: /model <model> or <provider>/<model>") catch {};
                return;
            }
            app.switchModel(spec) catch |err| {
                var bw = std.Io.Writer.Allocating.init(app.alloc);
                defer bw.deinit();
                bw.writer.print("switch model failed: {s}", .{@errorName(err)}) catch {};
                app.tui.appendLine("", "\x1b[31m", bw.written()) catch {};
                return;
            };
            const st = app.statusLine() catch return;
            app.tui.setStatus("\x1b[32m", st) catch {};
            return;
        }
        if (std.mem.eql(u8, cmd, "compact")) {
            app.tui.appendLine("", "\x1b[2m", "compacting conversation…") catch {};
            spawnWorker(app, "", true);
            return;
        }
        if (std.mem.eql(u8, cmd, "shake") or std.mem.startsWith(u8, cmd, "shake ")) {
            if (app.worker_active.load(.acquire)) {
                app.tui.appendLine("", "\x1b[31m", "cannot shake while a turn is running") catch {};
                return;
            }
            const args = if (std.mem.startsWith(u8, cmd, "shake ")) std.mem.trim(u8, cmd["shake ".len..], " ") else "";
            const r = compress.shake(.{
                .alloc = app.alloc,
                .messages = &app.agent.messages,
                .window = app.agent.ctxWindow(),
                .api = app.agent.provider.api,
                .vision = compress.modelHasVision(app.agent.model),
            }, .{ .protect_tokens = 0, .min_savings = 0, .drop_images = std.mem.eql(u8, args, "images") });
            const msg = compress.formatNotice(app.alloc, r) orelse "shake: nothing to elide";
            app.tui.appendLine("", "\x1b[2m", msg) catch {};
            return;
        }
        if (std.mem.eql(u8, cmd, "snap")) {
            if (app.worker_active.load(.acquire)) {
                app.tui.appendLine("", "\x1b[31m", "cannot snap while a turn is running") catch {};
                return;
            }
            const vision = compress.modelHasVision(app.agent.model);
            const r = compress.snap(.{
                .alloc = app.alloc,
                .messages = &app.agent.messages,
                .window = app.agent.ctxWindow(),
                .api = app.agent.provider.api,
                .vision = vision,
            });
            const msg = compress.formatNotice(app.alloc, r) orelse if (!vision)
                "snap: model has no vision"
            else
                "snap: nothing eligible (need large ASCII tool output + vision)";
            app.tui.appendLine("", "\x1b[2m", msg) catch {};
            return;
        }
        if (std.mem.eql(u8, cmd, "fast-compress")) {
            const msg = compress.formatStatus(app.alloc, .{
                .alloc = app.alloc,
                .messages = &app.agent.messages,
                .window = app.agent.ctxWindow(),
                .api = app.agent.provider.api,
                .vision = compress.modelHasVision(app.agent.model),
            });
            app.tui.appendLine("", "\x1b[2m", msg) catch {};
            return;
        }
        if (std.mem.eql(u8, cmd, "redo")) {
            if (app.last_line.len == 0) {
                app.tui.appendLine("", "\x1b[2m", "nothing to redo") catch {};
                return;
            }
            app.tui.appendUser(app.last_line) catch {};
            spawnWorker(app, app.last_line, false);
            return;
        }
        if (std.mem.eql(u8, cmd, "memory")) {
            const mem_path = util.configDir(app.alloc) catch {
                app.tui.appendLine("", "\x1b[31m", "no config dir") catch {};
                return;
            };
            const full = util.joinPath(app.alloc, mem_path, "memory.md") catch {
                app.tui.appendLine("", "\x1b[31m", "cannot build path") catch {};
                return;
            };
            const content = std.Io.Dir.cwd().readFileAlloc(util.io, full, app.alloc, .limited(512 * 1024)) catch {
                app.tui.appendLine("", "\x1b[2m", "memory is empty — /memory set <text> to add") catch {};
                return;
            };
            defer app.alloc.free(content);
            var bw = std.Io.Writer.Allocating.init(app.alloc);
            defer bw.deinit();
            bw.writer.writeAll("🧠 memory.md:\n") catch {};
            bw.writer.writeAll(content[0..@min(content.len, 4000)]) catch {};
            if (content.len > 4000) bw.writer.writeAll("\n…(truncated)") catch {};
            bw.writer.print("\nusage: /memory set <text> | /memory clear", .{}) catch {};
            app.tui.appendLine("", "\x1b[36m", bw.written()) catch {};
            return;
        }
        if (std.mem.startsWith(u8, cmd, "memory set ")) {
            const text = std.mem.trim(u8, cmd["memory set ".len..], " ");
            if (text.len == 0) {
                app.tui.appendLine("", "\x1b[31m", "usage: /memory set <text>") catch {};
                return;
            }
            const mem_path = util.configDir(app.alloc) catch {
                app.tui.appendLine("", "\x1b[31m", "no config dir") catch {};
                return;
            };
            const full = util.joinPath(app.alloc, mem_path, "memory.md") catch {
                app.tui.appendLine("", "\x1b[31m", "cannot build path") catch {};
                return;
            };
            const mline = std.fmt.allocPrint(app.alloc, "{s}\n", .{text}) catch {
                app.tui.appendLine("", "\x1b[31m", "oom") catch {};
                return;
            };
            // 追加(已存在)或新建
            var f = std.Io.Dir.cwd().createFile(util.io, full, .{ .exclusive = true, .permissions = @enumFromInt(0o600) }) catch |err| switch (err) {
                error.PathAlreadyExists => std.Io.Dir.cwd().openFile(util.io, full, .{ .mode = .write_only }) catch {
                    app.tui.appendLine("", "\x1b[31m", "cannot open memory.md") catch {};
                    return;
                },
                else => {
                    app.tui.appendLine("", "\x1b[31m", "cannot create memory.md") catch {};
                    return;
                },
            };
            defer f.close(util.io);
            var wbuf: [1024]u8 = undefined;
            var w = f.writer(util.io, &wbuf);
            w.seekTo(f.length(util.io) catch 0) catch {};
            w.interface.writeAll(mline) catch {};
            w.flush() catch {};
            var bw = std.Io.Writer.Allocating.init(app.alloc);
            defer bw.deinit();
            bw.writer.print("🧠 memory saved: {s}", .{text[0..@min(text.len, 60)]}) catch {};
            app.tui.appendLine("", "\x1b[2m", bw.written()) catch {};
            return;
        }
        if (std.mem.eql(u8, cmd, "memory clear")) {
            const mem_path = util.configDir(app.alloc) catch {
                app.tui.appendLine("", "\x1b[31m", "no config dir") catch {};
                return;
            };
            const full = util.joinPath(app.alloc, mem_path, "memory.md") catch {
                app.tui.appendLine("", "\x1b[31m", "cannot build path") catch {};
                return;
            };
            std.Io.Dir.cwd().deleteFile(util.io, full) catch {};
            app.tui.appendLine("", "\x1b[2m", "🧹 memory cleared") catch {};
            return;
        }
        if (std.mem.startsWith(u8, cmd, "fork ")) {
            const nstr = std.mem.trim(u8, cmd["fork ".len..], " ");
            const n = std.fmt.parseInt(usize, nstr, 10) catch {
                app.tui.appendLine("", "\x1b[31m", "usage: /fork <n>  (see /tree)") catch {};
                return;
            };
            if (n == 0 or n > app.agent.messages.items.len) {
                app.tui.appendLine("", "\x1b[31m", "no such message") catch {};
                return;
            }
            const new_sess = app.sess.fork(n) catch |err| {
                var bw = std.Io.Writer.Allocating.init(app.alloc);
                defer bw.deinit();
                bw.writer.print("fork failed: {s}", .{@errorName(err)}) catch {};
                app.tui.appendLine("", "\x1b[31m", bw.written()) catch {};
                return;
            };
            app.loadSession(new_sess) catch {};
            var bw = std.Io.Writer.Allocating.init(app.alloc);
            defer bw.deinit();
            bw.writer.print("🌿 forked {d} messages → session {s}", .{ n, std.fs.path.basename(app.sess.path) }) catch {};
            app.tui.appendLine("", "\x1b[2m", bw.written()) catch {};
            const st = app.statusLine() catch return;
            app.tui.setStatus("\x1b[32m", st) catch {};
            return;
        }
        if (std.mem.eql(u8, cmd, "tree")) {
            var bw = std.Io.Writer.Allocating.init(app.alloc);
            defer bw.deinit();
            bw.writer.print("{d} messages:\n", .{app.agent.messages.items.len}) catch {};
            for (app.agent.messages.items, 0..) |m, i| {
                const tag: []const u8 = switch (m.role[0]) {
                    'u' => "❯",
                    'a' => "←",
                    't' => "⚙",
                    else => "·",
                };
                const head = m.content[0..@min(m.content.len, 50)];
                bw.writer.print("{d}. {s} {s}\n", .{ i + 1, tag, head }) catch {};
            }
            bw.writer.writeAll("use /fork <n> to branch from a message") catch {};
            app.tui.appendLine("", "\x1b[36m", bw.written()) catch {};
            return;
        }
        if (std.mem.startsWith(u8, cmd, "plan")) {
            // 计划模式:让模型制定计划写入 PLAN.md,随后按计划执行。
            // startsWith:既匹配 /plan(显示用法)也匹配 /plan <goal>。
            const goal = std.mem.trim(u8, cmd["plan".len..], " ");
            if (goal.len == 0) {
                app.tui.appendLine("", "\x1b[31m", "usage: /plan <goal>") catch {};
                return;
            }
            app.tui.appendUser(line) catch {};
            spawnWorker(app, try std.fmt.allocPrint(app.alloc, "Create a detailed step-by-step plan for: {s}. Write the plan to PLAN.md in the project root, then briefly state you are ready to execute it.", .{goal}), false);
            return;
        }
        if (std.mem.eql(u8, cmd, "export") or std.mem.eql(u8, cmd, "dump")) {
            // 导出会话:HTML 文件(/export)或剪贴板文本(/dump)
            const is_export = std.mem.eql(u8, cmd, "export");
            var ww = std.Io.Writer.Allocating.init(app.alloc);
            defer ww.deinit();
            const w = &ww.writer;
            if (is_export) try w.writeAll("<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>piz session</title></head><body>");
            for (app.agent.messages.items) |m| {
                const role = m.role;
                const body = std.mem.replaceOwned(u8, app.alloc, m.content, "&", "&amp;") catch continue;
                defer app.alloc.free(body);
                const esc = std.mem.replaceOwned(u8, app.alloc, body, "<", "&lt;") catch continue;
                defer app.alloc.free(esc);
                if (is_export) {
                    try w.print("<p><b>{s}</b><br><pre>{s}</pre></p>\n", .{ role, esc });
                } else {
                    try w.print("--- {s} ---\n{s}\n", .{ role, esc });
                }
            }
            if (is_export) try w.writeAll("</body></html>\n");
            if (is_export) {
                const fname = "piz-export.html";
                std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = fname, .data = ww.written() }) catch {
                    app.tui.appendLine("", "\x1b[31m", "export failed") catch {};
                    return;
                };
                app.tui.appendLine("", "\x1b[32m", "exported to piz-export.html") catch {};
            } else {
                if (copyToClipboard(app.alloc, ww.written())) {
                    app.tui.appendLine("", "\x1b[32m", "session copied to clipboard") catch {};
                } else {
                    app.tui.appendLine("", "\x1b[31m", "no clipboard tool (wl-copy/xclip); /tmp fallback") catch {};
                    std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = "/tmp/piz-dump.txt", .data = ww.written() }) catch {};
                }
            }
            return;
        }
        if (std.mem.eql(u8, cmd, "copy")) {
            // 最后一条 assistant 消息 → 剪贴板
            var last: ?[]const u8 = null;
            var i = app.agent.messages.items.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, app.agent.messages.items[i].role, "assistant")) {
                    last = app.agent.messages.items[i].content;
                    break;
                }
            }
            const text = last orelse {
                app.tui.appendLine("", "\x1b[2m", "no assistant message yet") catch {};
                return;
            };
            if (copyToClipboard(app.alloc, text)) {
                app.tui.appendLine("", "\x1b[2m", "📋 copied to clipboard") catch {};
            } else {
                // 回退:写临时文件并提示
                if (util.writeFile("/tmp/piz-copy.txt", text)) |_| {
                    app.tui.appendLine("", "\x1b[2m", "📋 no clipboard tool — saved to /tmp/piz-copy.txt") catch {};
                } else |_| {}
            }
            return;
        }
        if (std.mem.eql(u8, cmd, "queue")) {
            if (app.queue.items.len == 0) {
                app.tui.appendLine("", "\x1b[2m", "queue empty") catch {};
                return;
            }
            app.clearQueue();
            app.tui.appendLine("", "\x1b[2m", "🗑 queued messages cleared") catch {};
            return;
        }
        if (std.mem.eql(u8, cmd, "status")) {
            const st = app.statusLine() catch return;
            app.tui.setStatus("\x1b[32m", st) catch {};
            return;
        }
        if (std.mem.eql(u8, cmd, "help")) {
            app.tui.appendLine("", "\x1b[0m", SLASH_HELP) catch {};
            return;
        }
        // 未知斜杠命令:尝试 prompt 模板(/name [args])
        if (std.mem.indexOfScalar(u8, cmd, ' ') orelse cmd.len > 0) {
            const space = std.mem.indexOfScalar(u8, cmd, ' ');
            const tname = if (space) |sp| cmd[0..sp] else cmd;
            const targs_part = if (space) |sp| std.mem.trim(u8, cmd[sp + 1 ..], " ") else "";
            if (util.loadTemplate(app.alloc, app.agent.cwd, tname) catch null) |tpl| {
                defer app.alloc.free(tpl);
                // 参数按空格拆分(简化)
                var args = std.array_list.Managed([]const u8).init(app.alloc);
                defer args.deinit();
                var it = std.mem.splitScalar(u8, targs_part, ' ');
                while (it.next()) |a| {
                    if (a.len > 0) try args.append(a);
                }
                const rendered = try util.renderTemplate(app.alloc, tpl, args.items);
                app.tui.appendUser(rendered) catch {};
                const old = app.last_line;
                app.last_line = app.alloc.dupe(u8, rendered) catch rendered;
                if (old.len > 0 and old.ptr != rendered.ptr) app.alloc.free(old);
                spawnWorker(app, rendered, false);
                return;
            }
        }
        var bw = std.Io.Writer.Allocating.init(app.alloc);
        defer bw.deinit();
        bw.writer.print("unknown command: /{s} (try /help)", .{cmd}) catch {};
        app.tui.appendLine("", "\x1b[31m", bw.written()) catch {};
        return;
    }
    // 正常消息:!cmd 运行并发送;!!cmd 运行不发送;@path 展开文件内容
    if (line.len > 1 and line[0] == '!') {
        const send_to_llm = !(line.len > 1 and line[1] == '!');
        const cmd = if (send_to_llm) line[1..] else line[2..];
        const json_args = std.fmt.allocPrint(app.alloc, "{{\"command\":{s},\"timeout\":30}}", .{util.jsonString(app.alloc, cmd) catch "\"\""}) catch {
            return;
        };
        const res: toolsmod.Result = if (toolsmod.find("bash")) |tb|
            (tb.handler(app.alloc, json_args) catch .{ .content = "tool crashed", .is_error = true })
        else
            .{ .content = "no bash tool", .is_error = true };
        app.tui.appendLine("", if (res.is_error) "\x1b[31m" else "\x1b[2m", res.content) catch {};
        if (send_to_llm) {
            const msg = std.fmt.allocPrint(app.alloc, "!{s}\n\nOutput:\n{s}", .{ cmd, res.content }) catch {
                return;
            };
            app.tui.appendUser(msg) catch {};
            spawnWorker(app, msg, false);
        }
        return;
    }
    const expanded = util.expandRefs(app.alloc, line, app.agent.cwd) catch line;
    if (app.worker_active.load(.acquire)) {
        // worker 忙:入队(steering),轮次间自动投递
        app.enqueue(expanded);
        var bw = std.Io.Writer.Allocating.init(app.alloc);
        defer bw.deinit();
        const head = expanded[0..@min(expanded.len, 72)];
        if (app.queue.items.len == 1)
            bw.writer.print("→ 待发  {s}", .{head}) catch {}
        else
            bw.writer.print("→ 待发 {d}  {s}", .{ app.queue.items.len, head }) catch {};
        app.tui.appendLine("", "\x1b[2m", bw.written()) catch {};
        return;
    }
    app.tui.appendUser(expanded) catch {};
    {
        var ea = util.Arena.init(app.alloc);
        defer ea.deinit();
        const ealloc = ea.allocator();
        app.events.emit("user_message", std.fmt.allocPrint(ealloc, "\"text\":{s}", .{
            try util.jsonString(ealloc, expanded[0..@min(expanded.len, 500)]),
        }) catch "");
    }
    const old = app.last_line;
    app.last_line = app.alloc.dupe(u8, expanded) catch expanded;
    if (old.len > 0 and old.ptr != expanded.ptr) app.alloc.free(old);
    spawnWorker(app, expanded, false);
}

fn spawnWorker(app: *App, line: []const u8, is_compact: bool) void {
    const wctx = app.alloc.create(WorkerCtx) catch return;
    wctx.* = .{ .app = app, .line = line, .is_compact = is_compact };
    const thread = std.Thread.spawn(.{}, workerMain, .{wctx}) catch {
        app.alloc.destroy(wctx);
        app.tui.appendLine("", "\x1b[31m", "failed to spawn worker thread") catch {};
        return;
    };
    app.worker = thread;
    // 不 join:主循环退出时统一处理
}

/// Ctrl+C:中止当前一轮。
///
/// 三件事都要做,少一件用户就会觉得按了没反应:
///   1. 置 agent 的 aborted 标志 —— 下一个迭代边界停下
///   2. 取消在跑的活动 —— 长命令/退避睡眠在 100ms 内自己退出,不必等边界
///   3. 回一行确认 —— 「取消了 2 个活动」比屏幕毫无变化可信得多
fn onAbort(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    app.abort.store(true, .release);
    app.agent.aborted.store(true, .release);
    const n = activity.cancelAll();
    var buf: [96]u8 = undefined;
    const msg = if (n > 0)
        std.fmt.bufPrint(&buf, "interrupted — cancelling {d} running activity(s)", .{n}) catch "interrupted"
    else
        "interrupted";
    app.tui.appendLine("", "\x1b[33m", msg) catch {};
}

/// Ctrl+B:把在跑的活动转后台。
///
/// 「命令卡住能知道后台」的落点。转后台后:命令继续跑到底(不再受墙钟上限约束),
/// Ctrl+C 也不再取消它,活动行标 [bg] 且 spinner 停转。
/// 当前这一轮仍会等它的结果 —— 结果要回给模型,丢掉就等于工具调用无返回,
/// OpenAI 协议下会导致下一轮请求 400。
fn onDetach(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    const n = activity.detachAll();
    var buf: [128]u8 = undefined;
    const msg = if (n > 0)
        std.fmt.bufPrint(&buf, "{d} activity(s) moved to background — no wall-clock limit, Ctrl+C won't cancel them", .{n}) catch "moved to background"
    else
        "nothing running to move to background";
    app.tui.appendLine("", "\x1b[2m", msg) catch {};
}

fn tuiOnAbort(ctx: ?*anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    return app.abort.load(.acquire) or app.agent.aborted.load(.acquire);
}

fn isQuit(ctx: ?*anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(ctx orelse return false));
    return app.quit.load(.acquire);
}

pub const OutputFormat = runopts.OutputFormat;

pub const RunOptions = runopts.RunOptions;

pub fn runInteractive(alloc: std.mem.Allocator, cfg: *cfgmod.Config, cwd: []const u8, opts: RunOptions) !void {
    // 目录切换
    if (!std.mem.eql(u8, cwd, ".")) {
        std.Io.Threaded.chdir(cwd) catch {
            std.debug.print("error: cannot chdir to {s}\n", .{cwd});
            std.process.exit(1);
        };
    }
    const abs_cwd = std.process.currentPathAlloc(util.io, alloc) catch cwd;

    // 会话:指定 id → 恢复;显式新会话/带标题 → fresh;否则续载最新
    var sess = if (opts.session_id) |id| blk: {
        const found = (try sessionmod.Session.findById(alloc, abs_cwd, id)) orelse {
            std.debug.print("piz: session '{s}' not found in {s}\n", .{ id, abs_cwd });
            std.process.exit(1);
        };
        break :blk found;
    } else if (opts.new_session or opts.title != null)
        (try sessionmod.Session.freshTitle(alloc, abs_cwd, opts.title))
    else
        (try sessionmod.Session.findLatest(alloc, abs_cwd)) orelse
            (try sessionmod.Session.fresh(alloc, abs_cwd));

    // agent
    var agent = try agentmod.Agent.initOpts(alloc, cfg, opts.provider_name, opts.model_name, abs_cwd, .{ .read_only = opts.read_only, .system_override = opts.system_override, .depth = pluginsmod.processBaseDepth() });
    if (agent.key == null) {
        var up: [64]u8 = undefined;
        const upname = std.ascii.upperString(up[0..@min(agent.provider.name.len, 63)], agent.provider.name);
        std.debug.print("piz: no API key for provider '{s}'. Set ~/.piz/auth.json, models.json apiKey, or {s}_API_KEY env.\n", .{ agent.provider.name, upname });
        std.process.exit(1);
    }
    const loaded = try sess.loadMessages();
    try agent.messages.appendSlice(loaded);

    // TUI
    var tui = try tui_mod.Tui.init(alloc);
    defer tui.deinit();
    // 声明在 tui.deinit 之后 → LIFO 下先执行:长驻 subagent 先收摊,
    // 之后才还原终端,它们的收尾输出不会打在已经恢复的 shell 上。
    defer pluginsmod.shutdownAgents();
    try tui.enterRaw();
    defer tui.restoreTerminal();

    // 事件总线(扫描包扩展声明)
    var bus = try eventsmod.Bus.init(alloc);
    {
        var ea = util.Arena.init(alloc);
        defer ea.deinit();
        const ealloc = ea.allocator();
        bus.emit("startup", std.fmt.allocPrint(ealloc, "\"cwd\":{s}", .{try util.jsonString(ealloc, abs_cwd)}) catch "");
    }

    var app = App{
        .alloc = alloc,
        .tui = &tui,
        .agent = &agent,
        .sess = &sess,
        .start_ns = std.Io.Clock.now(.real, util.io).nanoseconds,
        .cfg = cfg,
        .events = &bus,
        .read_only = opts.read_only,
        .perm = .{ .buf = std.array_list.Managed(u8).init(alloc) },
        .queue = std.array_list.Managed([]const u8).init(alloc),
    };
    tui.ctx = &app;
    // 接线回调:流式输出 + 工具行 + 权限询问(此前缺失,交互模式流式显示依赖于此)
    agent.cbs = .{
        .ctx = &app,
        .on_text = tuiOnText,
        .on_reasoning = tuiOnReasoning,
        .on_tool_start = tuiOnToolStart,
        .on_tool_end = tuiOnToolEnd,
        .on_turn_end = tuiOnTurnEnd,
        .on_notice = tuiOnNotice,
        .on_subagent = tuiOnSubagent,
        .on_require_permission = tuiOnRequirePermission,
        .on_abort = tuiOnAbort,
    };
    if (opts.execute) app.perm.always.store(true, .release);

    // 启动提示
    var gw = std.Io.Writer.Allocating.init(alloc);
    defer gw.deinit();
    gw.writer.print("piz v{s} · {s}/{s} · {s}\n/help 命令  ·  @./file 贴文件  ·  !cmd 跑 shell  ·  Ctrl+C 取消  ·  Ctrl+B 后台", .{ VERSION, agent.provider.name, agent.model, abs_cwd }) catch {};
    try tui.appendLine("", "\x1b[36m", gw.written());
    const st = try app.statusLine();
    try tui.setStatus("\x1b[0m", st);

    // 会话续载提示
    if (loaded.len > 0) {
        var bw = std.Io.Writer.Allocating.init(alloc);
        defer bw.deinit();
        bw.writer.print("resumed session: {d} messages", .{loaded.len}) catch {};
        try tui.appendLine("", "\x1b[2m", bw.written());
    }

    try tui.run(.{
        .on_submit = onSubmit,
        .is_quit = isQuit,
        .on_abort = onAbort,
        .on_detach = onDetach,
        .on_perm = tuiOnPermKey,
        .ctx = &app,
    });

    // 收尾:shutdown 事件 + 等待工作线程
    bus.emit("shutdown", "");
    if (app.worker) |th| {
        app.abort.store(true, .release);
        app.agent.aborted.store(true, .release);
        th.join();
    }
}

// ---------- CLI ----------

pub fn main(init: std.process.Init) !void {
    util.io = init.io;
    util.environ_map = init.environ_map;

    // 忽略 SIGPIPE
    std.posix.sigaction(std.posix.SIG.PIPE, &.{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 }, null);

    const alloc = init.gpa;

    // 旧目录迁移提示:piz 早期读 ~/.pi/agent,现独立用 ~/.piz。
    // 只在「有旧配置且无新配置」时提示一次,不自动搬 —— 搬动用户配置是破坏性操作。
    if (util.legacyConfigDir(alloc)) |legacy| {
        std.debug.print(
            \\piz: 配置目录已改为 ~/.piz(不再与官方 pi 共用 {s})。
            \\     迁移:cp -r {s} ~/.piz
            \\     或用 PIZ_DIR={s} 继续指向旧目录。
            \\
        , .{ legacy, legacy, legacy });
    }

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // argv[0]
    var print_mode = false;
    var print_prompt: ?[]const u8 = null;
    var input_file: ?[]const u8 = null;
    var opts = RunOptions{};
    var dir: ?[]const u8 = null;
    var prompt_parts = std.array_list.Managed([]const u8).init(alloc);
    var cli_plugins = std.array_list.Managed([]const u8).init(alloc);
    var cli_no_plugins = std.array_list.Managed([]const u8).init(alloc);
    var list_plugins = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print")) {
            print_mode = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            opts.model_name = args.next() orelse {
                std.debug.print("piz: missing value for {s}\n", .{arg});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--provider")) {
            opts.provider_name = args.next() orelse {
                std.debug.print("piz: missing value for --provider\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--new")) {
            opts.new_session = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--continue")) {
            opts.new_session = false;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--read-only")) {
            opts.read_only = true;
        } else if (std.mem.eql(u8, arg, "-x") or std.mem.eql(u8, arg, "--execute")) {
            opts.execute = true;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--title")) {
            opts.title = args.next() orelse {
                std.debug.print("piz: missing value for {s}\n", .{arg});
                std.process.exit(1);
            };
            opts.new_session = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--session")) {
            opts.session_id = args.next() orelse {
                std.debug.print("piz: missing value for {s}\n", .{arg});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--async")) {
            opts.async_run = true;
        } else if (std.mem.eql(u8, arg, "--system")) {
            opts.system_override = args.next() orelse {
                std.debug.print("piz: missing value for {s}\n", .{arg});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--input")) {
            input_file = args.next() orelse {
                std.debug.print("piz: missing value for {s}\n", .{arg});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            const fmt = args.next() orelse {
                std.debug.print("piz: missing value for {s}\n", .{arg});
                std.process.exit(1);
            };
            if (std.mem.eql(u8, fmt, "text")) {
                opts.output_format = .text;
            } else if (std.mem.eql(u8, fmt, "json")) {
                opts.output_format = .json;
            } else if (std.mem.eql(u8, fmt, "jsonl")) {
                opts.output_format = .jsonl;
            } else {
                std.debug.print("piz: unknown output format {s} (text|json|jsonl)\n", .{fmt});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--models")) {
            printModels();
        } else if (std.mem.eql(u8, arg, "--no-plugin")) {
            try cli_no_plugins.append(args.next() orelse {
                std.debug.print("piz: missing value for --no-plugin\n", .{});
                std.process.exit(1);
            });
        } else if (std.mem.eql(u8, arg, "--plugin")) {
            try cli_plugins.append(args.next() orelse {
                std.debug.print("piz: missing value for --plugin\n", .{});
                std.process.exit(1);
            });
        } else if (std.mem.eql(u8, arg, "--plugins")) {
            // 延后到配置加载与 --plugin 应用之后再打印,否则显示的是编译期默认
            // 而不是本次实际生效的状态,会误导用户。
            list_plugins = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            std.debug.print("piz v{s}\n", .{VERSION});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{HELP});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "pkg")) {
            cmd_pkg.runPkgCmd(alloc, &args); // 不返回
        } else if (std.mem.eql(u8, arg, "web")) {
            cmd_web.runWebCmd(alloc, &args); // 不返回
        } else if (std.mem.eql(u8, arg, "--")) {
            // 之后全部当字面量 —— 提示词以 '-' 开头时唯一的写法,
            // 比如 `piz -p -- "-rf 是什么意思"`。少了它这种提问无法输入。
            while (args.next()) |rest| {
                if (print_mode) {
                    try prompt_parts.append(rest);
                } else if (dir == null) {
                    dir = rest;
                } else {
                    std.debug.print("piz: unexpected argument {s}\n", .{rest});
                    std.process.exit(1);
                }
            }
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("piz: unknown option {s}\n{s}", .{ arg, HELP });
            std.process.exit(1);
        } else if (print_mode) {
            try prompt_parts.append(arg);
        } else if (dir == null) {
            dir = arg;
        } else {
            std.debug.print("piz: unexpected argument {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    if (input_file != null and !print_mode) {
        std.debug.print("piz: -i/--input requires -p/--print\n", .{});
        std.process.exit(1);
    }
    if (opts.async_run and !print_mode) {
        std.debug.print("piz: -a/--async requires -p/--print\n", .{});
        std.process.exit(1);
    }

    // print 提示词:输入文件 > 参数 > stdin
    if (print_mode) {
        if (input_file) |fpath| {
            print_prompt = std.Io.Dir.cwd().readFileAlloc(util.io, fpath, alloc, .limited(4 * 1024 * 1024)) catch |err| {
                std.debug.print("piz: cannot read {s}: {s}\n", .{ fpath, @errorName(err) });
                std.process.exit(1);
            };
        } else if (prompt_parts.items.len > 0) {
            var joined = std.array_list.Managed(u8).init(alloc);
            for (prompt_parts.items, 0..) |p, i| {
                if (i > 0) try joined.append(' ');
                try joined.appendSlice(p);
            }
            print_prompt = try joined.toOwnedSlice();
        } else {
            var sbuf: [8192]u8 = undefined;
            var r = std.Io.File.stdin().reader(util.io, &sbuf);
            print_prompt = try r.interface.allocRemaining(alloc, .limited(4 * 1024 * 1024));
        }
    }

    const cwd = dir orelse ".";

    var cfg_arena = util.Arena.init(alloc);
    var cfg = cfgmod.Config{ .arena = &cfg_arena };
    defer cfg.deinit();
    try cfg.load();
    cfg.warnBroken();

    // 插件启用:settings.json 的 plugins 数组,再叠加 --plugin 参数。
    // settings 里的未知名字只警告(配置可能为更新版本写的);CLI 里的直接失败。
    for (cfg.enabled_plugins) |name| {
        if (!pluginsmod.enable(name)) {
            std.debug.print("piz: unknown plugin '{s}' in settings.json (see piz --plugins)\n", .{name});
        }
    }
    for (cli_plugins.items) |name| {
        if (!pluginsmod.enable(name)) {
            std.debug.print("piz: unknown plugin '{s}' (see piz --plugins)\n", .{name});
            std.process.exit(1);
        }
    }
    for (cfg.disabled_plugins) |name| {
        if (!pluginsmod.disable(name)) {
            std.debug.print("piz: unknown plugin '{s}' in settings.json disabled_plugins (see piz --plugins)\n", .{name});
        }
    }
    for (cli_no_plugins.items) |name| {
        if (!pluginsmod.disable(name)) {
            std.debug.print("piz: unknown plugin '{s}' (see piz --plugins)\n", .{name});
            std.process.exit(1);
        }
    }
    // skills 插件按「是否装了技能」自动开启,与 agent 初始化里的逻辑一致,
    // 这样 --plugins 显示的就是真实生效状态。
    if (list_plugins) {
        const idx = util.loadSkillsIndex(alloc) catch "";
        if (idx.len > 0) _ = pluginsmod.enable("skills");
        printPlugins(alloc);
    }

    if (opts.async_run) {
        // 原始 argv(含 argv[0]),runAsync 重建用
        var all_args = std.array_list.Managed([]const u8).init(alloc);
        var ait = std.process.Args.Iterator.init(init.minimal.args);
        while (ait.next()) |a| try all_args.append(a);
        cmd_print.runAsync(alloc, cwd, print_prompt orelse "", all_args.items) catch |e| explainAndExit(e, &cfg, opts);
    } else if (print_mode) {
        cmd_print.runPrint(alloc, &cfg, cwd, print_prompt orelse "", opts) catch |e| explainAndExit(e, &cfg, opts);
    } else {
        runInteractive(alloc, &cfg, cwd, opts) catch |e| explainAndExit(e, &cfg, opts);
        // 交互模式自然退出时直接 exit:避免 DebugAllocator 对进程级分配
        // (environ map、gpa 杂项)的泄漏检查误报(print 模式已如此)。
        std.process.exit(0);
    }
}

/// 把启动期错误翻成人话再退出。
///
/// 原先这些错误直接冒泡出 main,用户看到的是一屏 Zig 调用栈 ——
/// 「UnknownProvider」加十行 std 内部帧,对着它没法判断该改哪个文件。
/// 错误消息要说清**下一步做什么**,不是描述内部状态。
fn explainAndExit(e: anyerror, cfg: *cfgmod.Config, opts: RunOptions) noreturn {
    switch (e) {
        error.UnknownProvider => {
            const want = opts.provider_name orelse util.getEnv("PIZ_PROVIDER") orelse "(default)";
            std.debug.print("piz: unknown provider '{s}'.\n", .{want});
            if (cfg.providers.len == 0) {
                std.debug.print("  No providers are configured. Create ~/.piz/models.json, for example:\n" ++
                    "    {{\"providers\":[{{\"name\":\"deepseek\",\"baseUrl\":\"https://api.deepseek.com\",\"models\":[\"deepseek-chat\"]}}]}}\n" ++
                    "  then put the key in ~/.piz/auth.json or DEEPSEEK_API_KEY.\n", .{});
            } else {
                std.debug.print("  Configured providers:", .{});
                for (cfg.providers) |*p| std.debug.print(" {s}", .{p.name});
                std.debug.print("\n  Pick one with --provider <name> or PIZ_PROVIDER.\n", .{});
            }
        },
        error.FileNotFound => std.debug.print("piz: a required file is missing (check -i path and ~/.piz/models.json)\n", .{}),
        error.OutOfMemory => std.debug.print("piz: out of memory\n", .{}),
        else => std.debug.print("piz: {s}\n", .{@errorName(e)}),
    }
    std.process.exit(1);
}

/// 列出全部内置插件与启用状态(--plugins)。
fn printPlugins(alloc: std.mem.Allocator) void {
    var arena = util.Arena.init(alloc);
    defer arena.deinit();
    const body = pluginsmod.listPlugins(arena.allocator()) catch {
        std.debug.print("piz: cannot list plugins\n", .{});
        std.process.exit(1);
    };
    std.debug.print(
        \\内置插件({d} 个;on = 默认启用或已开启):
        \\{s}
        \\开启方式:piz --plugin <name>  或  ~/.piz/settings.json 的 "plugins": ["name"]
        \\
    , .{ pluginsmod.builtin_plugins.len, body });
    std.process.exit(0);
}

/// 列出全部 provider 与模型(--models)。
fn printModels() void {
    var cfg_arena = util.Arena.init(std.heap.page_allocator);
    var cfg = cfgmod.Config{ .arena = &cfg_arena };
    cfg.load() catch {
        std.debug.print("piz: failed to load config\n", .{});
        std.process.exit(1);
    };
    cfg.warnBroken();
    defer cfg.deinit();
    for (cfg.providers) |p| {
        std.debug.print("{s}:", .{p.name});
        if (p.models.len > 0) {
            for (p.models, 0..) |m, i| {
                if (i > 0) std.debug.print(",", .{});
                std.debug.print(" {s}", .{m});
            }
        } else {
            std.debug.print(" (no model list)", .{});
        }
        std.debug.print("\n", .{});
    }
    std.process.exit(0);
}

test {
    _ = @import("core");
    _ = @import("tui");
    _ = @import("cmd_web.zig");
    _ = cmd_print;
    _ = cmd_pkg;
    // webui 只被 main 引入(HTTP 服务属 app 层,不在 core 库里)。Zig 只收集
    // 显式列出的测试 —— 少了这行,webui.zig 的 test 块一个都不会跑。
    // 用已有的 webui_mod 别名,不能再 @import 一次:同一文件同时属于
    // root 与 core 两个模块会编译失败。
    _ = webui_mod;
}

test "gitBranch reads HEAD" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try std.process.currentPathAlloc(util.io, t.allocator);
    defer {
        std.Io.Threaded.chdir(old_cwd) catch {};
        t.allocator.free(old_cwd);
    }
    const tmp_path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer t.allocator.free(tmp_path);
    std.Io.Threaded.chdir(tmp_path) catch unreachable;
    // 无 git → null
    try t.expect(App.gitBranch(t.allocator) == null);
    // 构造 .git/HEAD
    std.Io.Dir.cwd().createDirPath(util.io, ".git") catch {};
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    const br = App.gitBranch(t.allocator).?;
    defer t.allocator.free(br);
    try t.expectEqualStrings("main", br);
}

test "e2e memory pipeline" {
    try @import("e2e.zig").testMemoryPipeline();
}

test "e2e mock provider full loop" {
    try @import("e2e.zig").testFullLoop();
}

test "e2e task delegation spawns a real sub-agent" {
    try util.testInit();
    var arena = util.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 用构建产物,不是测试进程自身(测试二进制不是 piz)。
    // 产物不存在就跳过 —— `zig build test` 会先建好它。
    const cwd = try std.process.currentPathAlloc(util.io, a);
    const exe = try std.fmt.allocPrint(a, "{s}/zig-out/bin/piz", .{cwd});
    std.Io.Dir.cwd().access(util.io, exe, .{}) catch return error.SkipZigTest;
    try @import("e2e.zig").testTaskDelegation(exe);
}

test "e2e -- passes a dash-leading prompt through" {
    try util.testInit();
    var arena = util.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(util.io, a);
    const exe = try std.fmt.allocPrint(a, "{s}/zig-out/bin/piz", .{cwd});
    std.Io.Dir.cwd().access(util.io, exe, .{}) catch return error.SkipZigTest;
    try @import("e2e.zig").testDashSeparator(exe);
}

test "expandRefs" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 写相对 cwd 的引用文件
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = "ref_test.txt", .data = "FILE-CONTENT" });
    defer std.Io.Dir.cwd().deleteFile(util.io, "ref_test.txt") catch {};
    // @./ref_test.txt 展开
    const r1 = try util.expandRefs(a, "read this @./ref_test.txt please", "");
    try t.expect(std.mem.indexOf(u8, r1, "FILE-CONTENT") != null);
    try t.expect(std.mem.indexOf(u8, r1, "```./ref_test.txt") != null);
    // 普通 @ 保留(邮箱/提及)
    const r2 = try util.expandRefs(a, "mail me @someone now", "");
    try t.expectEqualStrings("mail me @someone now", r2);
    // 不存在路径保留原文
    const r3 = try util.expandRefs(a, "see @./nope.txt end", "");
    try t.expectEqualStrings("see @./nope.txt end", r3);
}

test "copyToClipboard does not double-close the child stdin" {
    try util.testInit();
    var arena = util.Arena.init(std.testing.allocator);
    defer arena.deinit();

    // 回归测试:写完 stdin 后既 close 又让 child.wait 再关一次,
    // 同一 fd 关两次 → EBADF → std 判为 OS bug → Debug 构建 unreachable,
    // 整个 piz 崩在 /copy 上。这里只要求它不 panic。
    //
    // 系统没装 wl-copy/xclip 时返回 false,同样不该崩 —— 两条路径都走一遍。
    _ = copyToClipboard(arena.allocator(), "clipboard round trip\n");
    _ = copyToClipboard(arena.allocator(), "");
}

test "every slash command appears in /help" {
    const t = std.testing;

    // /dump /export /plan /queue 四条一直能用却没在帮助里列出 ——
    // 对用户等于不存在。这里把清单和实际分发绑在一起:
    // 新加命令忘了写进 SLASH_HELP,测试就失败。
    //
    // 命令名取自 onSubmit 里的 `eql(u8, cmd, "…")` / `startsWith(u8, cmd, "… ")`。
    const dispatched = [_][]const u8{
        "help",   "status",  "model",  "new",  "sessions",      "resume",
        "title",  "tree",    "fork",   "copy", "undo",          "redo",
        "memory", "compact", "shake",  "snap", "fast-compress", "clear",
        "plan",   "queue",   "export", "dump", "quit",
    };
    for (dispatched) |cmd| {
        var buf: [32]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buf, "/{s}", .{cmd});
        if (std.mem.indexOf(u8, SLASH_HELP, needle) == null) {
            std.debug.print("命令 /{s} 能用但没在 SLASH_HELP 里\n", .{cmd});
            return error.CommandMissingFromHelp;
        }
    }
    // 别名不单独列(/q /exit 是 /quit 的简写,列出来只是噪音)
    try t.expect(std.mem.indexOf(u8, SLASH_HELP, "/q ") == null);
}

test "toolArgsPreview prefers command path pattern" {
    const t = std.testing;
    try t.expectEqualStrings("zig test", toolArgsPreview("{\"command\":\"zig test\"}"));
    try t.expectEqualStrings("src/main.zig", toolArgsPreview("{\"path\":\"src/main.zig\"}"));
    try t.expectEqualStrings("fn foo", toolArgsPreview("{\"pattern\":\"fn foo\",\"path\":\".\"}"));
    try t.expectEqualStrings("raw", toolArgsPreview("raw"));
}
