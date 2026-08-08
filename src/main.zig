// main.zig — piz 入口:CLI 解析、交互模式(线程编排)、print 模式、会话挂载。
const std = @import("std");
const util = @import("core").util;
const activity = @import("core").activity;
const cfgmod = @import("core").config;
const ai = @import("core").ai;
const agentmod = @import("core").agent;
const sessionmod = @import("core").session;
const toolsmod = @import("core").tools;
const pkgsmod = @import("core").pkgs;
const eventsmod = @import("core").events;
const pluginsmod = @import("core").plugins;
const tui_mod = @import("tui");
const webui_mod = @import("webui.zig");

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
    \\      --plugin N   开启可选插件(可重复)
    \\      --plugins    列出全部内置插件与启用状态
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
        const cw = @as(usize, self.agent.provider.context_window);
        const used = self.agent.estTokens();
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
            const agent = try agentmod.Agent.initOpts(self.alloc, self.cfg, p, m, self.agent.cwd, .{ .read_only = ro });
            self.agent.deinit();
            self.agent.* = agent;
            self.provider_override = p;
            self.model_override = m;
        } else {
            const agent = try agentmod.Agent.initOpts(self.alloc, self.cfg, self.provider_override, spec, self.agent.cwd, .{ .read_only = ro });
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

fn tuiOnToolStart(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    var buf = std.array_list.Managed(u8).init(app.alloc);
    defer buf.deinit();
    buf.appendSlice("⚙ ") catch {};
    buf.appendSlice(name) catch {};
    buf.appendSlice(" ") catch {};
    const head = args[0..@min(args.len, 120)];
    buf.appendSlice(head) catch {};
    if (args.len > 120) buf.appendSlice("…") catch {};
    app.tui.appendLine("", "\x1b[36m", buf.items) catch {};
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
    app.tui.setStatus("\x1b[2m", st) catch {};
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

/// 权限询问(worker 线程):构建提示 → 置 pending → 轮询决策。
fn tuiOnRequirePermission(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!bool {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (app.perm.always.load(.acquire)) return true;
    if (app.read_only) return false;
    // 构建提示(截断 args)
    app.perm.buf.clearRetainingCapacity();
    try app.perm.buf.appendSlice("⛔ run ");
    try app.perm.buf.appendSlice(name);
    try app.perm.buf.append(' ');
    const head = args[0..@min(args.len, 160)];
    try app.perm.buf.appendSlice(head);
    if (args.len > 160) try app.perm.buf.appendSlice("…");
    try app.perm.buf.appendSlice("   [y]es [n]o [a]lways [s]kip");
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
            // 保存会话增量
            for (app.agent.messages.items[n_before..]) |*m| {
                app.sess.saveMessage(m) catch {};
            }
        }
        app.agent.aborted.store(false, .release);
        const st = app.statusLine() catch return;
        app.tui.setStatus("\x1b[2m", st) catch {};
        if (err_msg != null) break; // 出错停止投递后续队列
    }
}

/// pkg 子命令:install <path> [-l] | list | remove <name> [-l]
/// piz web:内置 Web UI(对齐 kimi web / grok --web)。
/// 默认 127.0.0.1:5494(占用自动 +1,范围 5494-5503),自动开浏览器。
/// 认证:默认生成随机 token 并写进打开的 URL fragment(前端存 sessionStorage);
///   --token T 指定固定 token;--no-token 显式关闭(仅信任的单用户本机场景)。
///   不鉴权时任何本机进程/恶意网页都能驱动 agent 在你的仓库里跑 bash,故默认开启。
fn runWebCmd(alloc: std.mem.Allocator, args: *std.process.Args.Iterator) void {
    var wopts = webui_mod.WebOptions{};
    var no_token = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--port")) {
            const v = args.next() orelse {
                std.debug.print("piz web: missing value for --port\n", .{});
                std.process.exit(1);
            };
            wopts.port = std.fmt.parseInt(u16, v, 10) catch {
                std.debug.print("piz web: bad port {s}\n", .{v});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, a, "--no-open")) {
            wopts.no_open = true;
        } else if (std.mem.eql(u8, a, "--no-token")) {
            no_token = true;
        } else if (std.mem.eql(u8, a, "--token")) {
            wopts.token = args.next() orelse {
                std.debug.print("piz web: missing value for --token\n", .{});
                std.process.exit(1);
            };
        } else {
            std.debug.print("piz web: usage: piz web [--port N] [--no-open] [--token T | --no-token]\n", .{});
            std.process.exit(1);
        }
    }

    // 默认鉴权:未指定 --token 且未 --no-token 时生成随机 token。
    // 绑定 127.0.0.1 只挡住远程,本机恶意网页仍可跨 Origin POST /api/chat 驱动 agent
    // (无 CSRF 防护),故默认必须有凭证;token 经 URL fragment 交给前端存 sessionStorage。
    // 缓冲区留余量:16 字节 hex 是 32 字符,给 64 而非刚好 32 —— 差一个字节就
    // 会让 bufPrint 失败,而失败的后果是鉴权被关掉。
    var token_buf: [64]u8 = undefined;
    if (wopts.token == null and !no_token) {
        var raw: [16]u8 = undefined;
        util.io.random(&raw);
        // fail-closed:凭证生成不了就不启动。旧写法是 `catch null`,
        // 那会静默把 Web UI 变成无鉴权的 bash 执行入口 —— 安全开关不许静默失效。
        wopts.token = std.fmt.bufPrint(&token_buf, "{x}", .{&raw}) catch {
            std.debug.print("piz web: 无法生成访问凭证,已中止启动。\n" ++
                "     需要无鉴权模式请显式加 --no-token(仅限你确认本机没有不可信程序时)。\n", .{});
            std.process.exit(1);
        };
    }

    var arena = util.Arena.init(alloc);
    defer arena.deinit();
    var cfg = cfgmod.Config{ .arena = &arena };
    cfg.load() catch {
        std.debug.print("piz: config load failed\n", .{});
        std.process.exit(1);
    };
    warnBrokenConfig(&cfg);
    const abs_cwd = std.process.currentPathAlloc(util.io, arena.allocator()) catch "";
    wopts.project_cwd = abs_cwd;
    var agent = agentmod.Agent.initOpts(arena.allocator(), &cfg, null, null, abs_cwd, .{}) catch {
        std.debug.print("piz: agent init failed\n", .{});
        std.process.exit(1);
    };
    if (agent.key == null) {
        std.debug.print("piz: no API key for provider '{s}'. Set ~/.piz/auth.json, models.json apiKey, or env.\n", .{agent.provider.name});
        std.process.exit(1);
    }
    @import("core").plugins.injectMemory(&agent);

    var hub = webui_mod.EventHub.init(arena.allocator());
    var ws = webui_mod.WebServer.start(arena.allocator(), wopts, &hub) catch |err| {
        std.debug.print("piz web: cannot listen: {t}\n", .{err});
        std.process.exit(1);
    };
    // 打印带 token 的完整 URL:--no-open 或浏览器打开失败时用户需手工复制
    if (wopts.token) |tok| {
        std.debug.print("piz web: http://127.0.0.1:{d}/#token={s}  (Ctrl+C 退出)\n", .{ ws.port, tok });
    } else {
        std.debug.print("piz web: http://127.0.0.1:{d}  (无鉴权 — 本机任意网页可驱动 agent)  (Ctrl+C 退出)\n", .{ws.port});
    }
    ws.openBrowser();

    // 会话池:default 会话 + hooks(webui 端点经回调接入)
    var pool = SessionPool{
        .alloc = arena.allocator(),
        .hub = &hub,
        .cfg = &cfg,
        .sessions = std.array_list.Managed(*WebSession).init(arena.allocator()),
        .workspaces = std.array_list.Managed([]const u8).init(arena.allocator()),
    };
    // 迁移旧布局会话 + 注册默认项目
    sessionmod.migrateLegacyWeb(arena.allocator(), abs_cwd);
    pool.workspaces.append(arena.allocator().dupe(u8, abs_cwd) catch "") catch {};
    if (pool.getOrCreate("default", abs_cwd) == null) {
        std.debug.print("piz web: session init failed\n", .{});
        std.process.exit(1);
    }
    ws.state_hook = poolStateHook;
    ws.state_ctx = &pool;
    ws.sessions_hook = poolSessionsHook;
    ws.sessions_ctx = &pool;
    ws.chat_hook = poolChatHook;
    ws.chat_ctx = &pool;
    ws.interrupt_hook = poolInterruptHook;
    ws.interrupt_ctx = &pool;
    ws.mode_hook = poolModeHook;
    ws.mode_ctx = &pool;
    ws.models_hook = poolModelsHook;
    ws.models_ctx = &pool;
    ws.model_hook = poolModelHook;
    ws.model_ctx = &pool;
    ws.title_hook = poolTitleHook;
    ws.title_ctx = &pool;
    ws.action_hook = poolActionHook;
    ws.action_ctx = &pool;
    ws.config_hook = poolConfigHook;
    ws.config_ctx = &pool;
    ws.workspaces_hook = poolWorkspacesHook;
    ws.workspaces_ctx = &pool;
    ws.ws_allowed_hook = poolWsAllowed;
    ws.ws_allowed_ctx = &pool;
    ws.run() catch {};
    webui_mod.ChatQueue.shutdown();
    for (pool.sessions.items) |ses| {
        ses.worker.join();
    }
    std.debug.print("\npiz web: bye\n", .{});
}

/// 会话池:每会话独立 Agent/Arena/worker(上限 4,对齐 task 工具)。
const WebSession = struct {
    name: []const u8,
    cwd: []const u8, // 项目根(workspace)
    qkey: []const u8, // ChatQueue 键:cwd+name(防跨项目同名冲突)
    agent: *agentmod.Agent,
    hub: *webui_mod.EventHub,
    start_ns: i128,
    tokens_total: usize = 0,
    updated_ns: i128 = 0, // 最后活动时间(列表显示)
    worker: std.Thread,
    /// 审批模式:true=自动放行,false=浏览器确认(per-tab)
    mode: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
};

const SessionPool = struct {
    alloc: std.mem.Allocator,
    hub: *webui_mod.EventHub,
    cfg: *cfgmod.Config,
    mutex: std.Io.Mutex = .init,
    sessions: std.array_list.Managed(*WebSession),
    /// 已注册项目根(workspaces;初始含进程 cwd)
    workspaces: std.array_list.Managed([]const u8),

    pub fn getOrCreate(self: *SessionPool, name: []const u8, cwd: []const u8) ?*WebSession {
        self.mutex.lock(util.io) catch return null;
        defer self.mutex.unlock(util.io);
        for (self.sessions.items) |ses| {
            if (std.mem.eql(u8, ses.name, name) and std.mem.eql(u8, ses.cwd, cwd)) return ses;
        }
        if (self.sessions.items.len >= 4) return null;
        // arena 必须驻留堆(allocator 指向结构体;局部 var 悬垂)
        const ses_arena = self.alloc.create(util.Arena) catch return null;
        ses_arena.* = util.Arena.init(self.alloc);
        const a = ses_arena.allocator();
        const abs_cwd = a.dupe(u8, cwd) catch return null;
        // agent 须驻留(值悬垂:getOrCreate 返回后栈失效)
        const agent = a.create(agentmod.Agent) catch return null;
        agent.* = agentmod.Agent.initOpts(a, self.cfg, null, null, abs_cwd, .{}) catch return null;
        if (agent.key == null) return null;
        @import("core").plugins.injectMemory(agent);
        // 会话持久化:磁盘有则恢复历史消息/模式/标题
        var restored_auto = true;
        var restored_updated: i128 = 0;
        if (sessionmod.loadWeb(a, abs_cwd, name) catch null) |web_ses| {
            for (web_ses.msgs) |m| {
                agent.messages.append(m) catch {};
            }
            restored_auto = web_ses.auto;
            restored_updated = web_ses.updated;
            if (web_ses.title) |t| agent.title = t;
            // 恢复磁盘模型(仍在可用列表则切换)
            if (web_ses.model) |m| {
                if (self.cfg.findModel(m) != null) {
                    agent.switchModel(m) catch {};
                }
            }
        }
        const ses = a.create(WebSession) catch return null;
        const qkey = std.fmt.allocPrint(a, "{s}\x1f{s}", .{ abs_cwd, name }) catch return null;
        ses.* = .{
            .name = a.dupe(u8, name) catch return null,
            .cwd = abs_cwd,
            .qkey = qkey,
            .agent = agent,
            .hub = self.hub,
            .start_ns = std.Io.Clock.now(.real, util.io).nanoseconds,
            .updated_ns = restored_updated,
            .worker = undefined,
            .mode = std.atomic.Value(bool).init(restored_auto),
        };
        agent.cbs = .{
            .ctx = ses,
            .on_text = webOnText,
            .on_reasoning = webOnReasoning,
            .on_tool_start = webOnToolStart,
            .on_tool_end = webOnToolEnd,
            .on_require_permission = webOnPermission,
            .on_turn_end = webOnTurnEnd,
            .on_abort = webOnAbort,
            .on_connect = webOnConnect,
        };
        ses.worker = std.Thread.spawn(.{}, webWorker, .{ses}) catch return null;
        self.sessions.append(ses) catch return null;
        return ses;
    }
};

fn webOnAbort(ctx: ?*anyopaque) bool {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    return s.agent.aborted.load(.acquire);
}
fn webOnConnect(ctx: ?*anyopaque, stream: *@import("core").httpc.Stream) void {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    s.agent.cur_stream = stream;
}

/// /api/sessions hook:活跃会话列表(name + 消息数)。
fn poolSessionsHook(ctx: ?*anyopaque, cwd: []const u8, alloc: std.mem.Allocator) []const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    var stw = std.Io.Writer.Allocating.init(alloc);
    defer stw.deinit();
    const w = &stw.writer;
    w.print("[", .{}) catch {};
    var first = true;
    pool.mutex.lock(util.io) catch return "[]";
    for (pool.sessions.items) |ses| {
        if (!std.mem.eql(u8, ses.cwd, cwd2)) continue;
        if (!first) w.print(",", .{}) catch {};
        first = false;
        const ag = ses.agent;
        const cw = @as(usize, ag.provider.context_window);
        const used = ag.estTokens();
        const pct = if (cw > 0) used * 100 / cw else 0;
        w.print("{{\"name\":{s},\"msgs\":{d},\"pct\":{d},\"model\":{s},\"auto\":{s},\"title\":{s},\"ts\":{d}}}", .{
            util.jsonString(alloc, ses.name) catch "\"\"",
            ag.messages.items.len,
            pct,
            util.jsonString(alloc, ag.model) catch "\"\"",
            if (ses.mode.load(.acquire)) "true" else "false",
            util.jsonString(alloc, ag.title orelse "") catch "\"\"",
            @divTrunc(ses.updated_ns, std.time.ns_per_ms),
        }) catch {};
    }
    pool.mutex.unlock(util.io);
    // 磁盘上的 web 会话(重启后未激活的)也列出
    if (sessionmod.listWebNames(alloc, cwd2) catch null) |disk_names| {
        for (disk_names) |dname| {
            if (std.mem.eql(u8, dname, "default")) continue;
            var in_active = false;
            pool.mutex.lock(util.io) catch continue;
            for (pool.sessions.items) |ses| {
                if (std.mem.eql(u8, ses.name, dname)) {
                    in_active = true;
                    break;
                }
            }
            pool.mutex.unlock(util.io);
            if (in_active) continue;
            // 计数:读文件数非空行(meta 除外)
            var count: usize = 0;
            const dir = sessionmod.webDirPublic(alloc, cwd2) catch continue;
            defer alloc.free(dir);
            const dname_file = std.fmt.allocPrint(alloc, "{s}.jsonl", .{dname}) catch continue;
            defer alloc.free(dname_file);
            const path = util.joinPath(alloc, dir, dname_file) catch continue;
            defer alloc.free(path);
            if (std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(64 * 1024 * 1024))) |content| {
                defer alloc.free(content);
                var meta_model: []const u8 = "";
                var meta_title: []const u8 = "";
                var meta_ts: i128 = 0;
                var lines = std.mem.splitScalar(u8, content, '\n');
                if (lines.next()) |first_line| {
                    if (std.mem.indexOf(u8, first_line, "\"model\":\"")) |p| {
                        const start = p + 9;
                        if (std.mem.indexOfScalar(u8, first_line[start..], '"')) |q| {
                            meta_model = alloc.dupe(u8, first_line[start .. start + q]) catch "";
                        }
                    }
                    if (std.mem.indexOf(u8, first_line, "\"title\":\"")) |p| {
                        const start = p + 9;
                        if (std.mem.indexOfScalar(u8, first_line[start..], '"')) |q| {
                            meta_title = alloc.dupe(u8, first_line[start .. start + q]) catch "";
                        }
                    }
                    if (std.mem.indexOf(u8, first_line, "\"updated\":")) |p| {
                        const rest = first_line[p + 10 ..];
                        var e: usize = 0;
                        while (e < rest.len and rest[e] >= '0' and rest[e] <= '9') e += 1;
                        if (e > 0) meta_ts = std.fmt.parseInt(i128, rest[0..e], 10) catch 0;
                    }
                }
                while (lines.next()) |l| {
                    if (std.mem.trim(u8, l, " \t\r\n").len > 0) count += 1;
                }
                w.print("{{\"name\":{s},\"msgs\":{d},\"pct\":0,\"model\":{s},\"auto\":true,\"title\":{s},\"ts\":{d},\"disk\":true}}", .{
                    util.jsonString(alloc, dname) catch "\"\"",
                    count,
                    util.jsonString(alloc, meta_model) catch "\"\"",
                    util.jsonString(alloc, meta_title) catch "\"\"",
                    meta_ts,
                }) catch {};
            } else |_| {}
        }
        // 归档会话(列表尾部,前端分区显示)
        if (sessionmod.listWebArchived(alloc, cwd2) catch null) |arch_names| {
            for (arch_names) |dname| {
                if (!first) w.print(",", .{}) catch {};
                first = false;
                w.print("{{\"name\":{s},\"msgs\":0,\"pct\":0,\"model\":\"\",\"auto\":true,\"title\":\"\",\"ts\":0,\"archived\":true}}", .{
                    util.jsonString(alloc, dname) catch "\"\"",
                }) catch {};
            }
        }
    }
    w.print("]", .{}) catch {};
    return stw.toOwnedSlice() catch "[]";
}

/// /api/state hook:按 session 返回 agent 状态与历史。
fn poolStateHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8, alloc: std.mem.Allocator) []const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    var found: ?*WebSession = null;
    pool.mutex.lock(util.io) catch return "{}";
    for (pool.sessions.items) |ses| {
        if (std.mem.eql(u8, ses.name, session) and std.mem.eql(u8, ses.cwd, cwd2)) {
            found = ses;
            break;
        }
    }
    pool.mutex.unlock(util.io);
    const ses = found orelse (pool.getOrCreate(session, cwd2) orelse return "{}");
    var stw = std.Io.Writer.Allocating.init(alloc);
    defer stw.deinit();
    const w = &stw.writer;
    const ag = ses.agent;
    w.print("{{\"model\":{s},\"auto\":{s},\"title\":{s}", .{ util.jsonString(alloc, ag.model) catch "\"\"", if (ses.mode.load(.acquire)) "true" else "false", util.jsonString(alloc, ag.title orelse "") catch "\"\"" }) catch {};
    const cw = @as(usize, ag.provider.context_window);
    const used = ag.estTokens();
    const pct = if (cw > 0) used * 100 / cw else 0;
    w.print(",\"pct\":{d},\"running\":{s},\"history\":[", .{ pct, if (ag.cur_stream != null) "true" else "false" }) catch {};
    const msgs = ag.messages.items;
    const hist_start = if (msgs.len > 20) msgs.len - 20 else 0;
    var first = true;
    var i = hist_start;
    while (i < msgs.len) : (i += 1) {
        const m = &msgs[i];
        // 空文本 assistant(纯工具调用回合)不渲染,工具经 tool 卡体现
        if (m.content.len == 0 and std.mem.eql(u8, m.role, "assistant")) continue;
        if (!first) w.writeAll(",") catch {};
        first = false;
        const content = if (m.content.len > 300) m.content[0..300] else m.content;
        w.print("{{\"role\":{s},\"content\":{s}}}", .{ util.jsonString(alloc, m.role) catch "\"\"", util.jsonString(alloc, content) catch "\"\"" }) catch {};
    }
    w.writeAll("]}") catch {};
    return stw.toOwnedSlice() catch "{}";
}

fn webWorker(ses: *WebSession) void {
    while (true) {
        const item = webui_mod.ChatQueue.dequeue(ses.qkey) orelse break;
        // 新消息清除上一轮残留的中断标志
        ses.agent.aborted.store(false, .release);
        ses.updated_ns = std.Io.Clock.now(.real, util.io).nanoseconds;
        const result = ses.agent.send(item.text) catch null;
        if (result) |r| {
            const u = r.usage;
            ses.tokens_total += (u.input orelse 0) + (u.output orelse 0) + (u.cache_read orelse 0);
            ses.agent.last_usage = u;
        }
        // 持久化:全量重写(消息 + model + 审批模式 + 标题)
        sessionmod.saveWebTs(ses.agent.alloc, ses.cwd, ses.name, ses.agent.model, ses.mode.load(.acquire), ses.agent.title, ses.agent.messages.items, ses.updated_ns) catch {};
        ses.hub.push("{{\"type\":\"turn_end\",\"session\":{s}}}", .{util.jsonString(ses.agent.alloc, ses.name) catch "\"\""});
    }
}

fn webOnText(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    s.hub.push("{{\"type\":\"message\",\"session\":{s},\"text\":{s}}}", .{ try util.jsonString(s.agent.alloc, s.name), try util.jsonString(s.agent.alloc, text) });
}
fn webOnReasoning(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    s.hub.push("{{\"type\":\"reasoning\",\"session\":{s},\"text\":{s}}}", .{ try util.jsonString(s.agent.alloc, s.name), try util.jsonString(s.agent.alloc, text) });
}
fn webOnToolStart(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!void {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    const short_args = if (args.len > 500) args[0..500] else args;
    s.hub.push("{{\"type\":\"tool_call\",\"session\":{s},\"name\":{s},\"args\":{s}}}", .{ try util.jsonString(s.agent.alloc, s.name), try util.jsonString(s.agent.alloc, name), try util.jsonString(s.agent.alloc, short_args) });
}
/// 工具权限:auto 放行;manual → 浏览器确认卡 + 轮询结果(超时拒绝)。
fn webOnPermission(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!bool {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    if (s.mode.load(.acquire)) return true;
    const id = webui_mod.PermGate.submit(name, args);
    if (id == 0) return false;
    s.hub.push("{{\"type\":\"permission\",\"session\":{s},\"id\":{d},\"name\":{s},\"args\":{s}}}", .{ try util.jsonString(s.agent.alloc, s.name), id, try util.jsonString(s.agent.alloc, name), try util.jsonString(s.agent.alloc, args) });
    return webui_mod.PermGate.waitResult(id);
}
fn webOnToolEnd(ctx: ?*anyopaque, name: []const u8, is_error: bool, summary: []const u8) anyerror!void {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    const short = if (summary.len > 2000) summary[0..2000] else summary;
    s.hub.push("{{\"type\":\"tool_result\",\"session\":{s},\"name\":{s},\"error\":{s},\"summary\":{s}}}", .{ try util.jsonString(s.agent.alloc, s.name), try util.jsonString(s.agent.alloc, name), if (is_error) "true" else "false", try util.jsonString(s.agent.alloc, short) });
}
fn webOnTurnEnd(ctx: ?*anyopaque) anyerror!void {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    s.agent.cur_stream = null; // 回合结束:running 标志复位
    // 状态栏数据(ctx%/model/cache/tps)——全局(无 session)
    const cw = @as(usize, s.agent.provider.context_window);
    const used = s.agent.estTokens();
    const pct = if (cw > 0) used * 100 / cw else 0;
    var cache_pct: usize = 0;
    if (s.agent.last_usage.cache_read) |cr| {
        // Anthropic 的 input_tokens 不含缓存部分,总输入要把读写都加回来
        const tot = cr + (s.agent.last_usage.cache_write orelse 0) + (s.agent.last_usage.input orelse 0);
        if (tot > 0) cache_pct = cr * 100 / tot;
    }
    const now_ns = std.Io.Clock.now(.real, util.io).nanoseconds;
    const el = @max(1, @divTrunc(now_ns - s.start_ns, std.time.ns_per_s));
    const tps = s.tokens_total / @as(usize, @intCast(el));
    s.hub.push("{{\"type\":\"status\",\"pct\":{d},\"model\":{s},\"cache\":{d},\"tps\":{d}}}", .{ pct, try util.jsonString(s.agent.alloc, s.agent.model), cache_pct, tps });
}

fn poolInterruptHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8) void {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    pool.mutex.lock(util.io) catch return;
    for (pool.sessions.items) |ses| {
        if (std.mem.eql(u8, ses.name, session) and std.mem.eql(u8, ses.cwd, cwd2)) {
            ses.agent.aborted.store(true, .release);
            // 打断阻塞中的 provider 读(读错误由 on_abort 判定转中止,保留 partial)
            if (ses.agent.cur_stream) |st| st.abortRead();
            break;
        }
    }
    pool.mutex.unlock(util.io);
}

/// /api/config hook:GET(读配置)→"{}";POST 写。返回配置 JSON 或 null。
fn poolConfigHook(ctx: ?*anyopaque, alloc: std.mem.Allocator, body: ?[]const u8) ?[]const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const cfg = pool.cfg;
    if (body) |b| {
        const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, b, .{}) catch return null;
        if (root != .object) return null;
        // 配置落盘失败要说出来。静默失败最坏:用户点了保存、界面照旧,
        // 以为存上了。ConfigUnparseable 意味着磁盘上的配置有语法错误 ——
        // piz 拒绝覆盖它(否则 apiKey 全丢),但必须告诉用户去修哪个文件。
        const write_err =
            "{\"error\":\"配置文件有语法错误，已拒绝写入以免覆盖现有内容。" ++
            "请检查 ~/.piz/settings.json 与 ~/.piz/models.json 后重试。\"}";
        // setDefaultModel / setDefaultProvider
        if (root.object.get("setDefaultModel")) |v| {
            if (v == .string) {
                cfg.saveSettings(null, v.string) catch return write_err;
                cfg.default_model = cfg.allocator().dupe(u8, v.string) catch return null;
            }
        }
        if (root.object.get("setDefaultProvider")) |v| {
            if (v == .string) {
                cfg.saveSettings(v.string, null) catch return write_err;
                cfg.default_provider = cfg.allocator().dupe(u8, v.string) catch return null;
            }
        }
        // upsertProvider: {name, baseUrl, api?, apiKey?, models?}
        if (root.object.get("upsertProvider")) |v| {
            if (v == .object) {
                const name = if (v.object.get("name")) |n| (if (n == .string) n.string else "") else "";
                const base_url = if (v.object.get("baseUrl")) |n| (if (n == .string) n.string else "") else "";
                if (name.len == 0 or base_url.len == 0) return null;
                const api_str = if (v.object.get("api")) |n| (if (n == .string) n.string else "openai-completions") else "openai-completions";
                const api_key = if (v.object.get("apiKey")) |n| (if (n == .string) n.string else null) else null;
                var models = std.array_list.Managed([]const u8).init(alloc);
                if (v.object.get("models")) |ms| {
                    if (ms == .array) {
                        for (ms.array.items) |m| {
                            if (m == .string) models.append(m.string) catch {};
                        }
                    }
                }
                // 合并现有 provider(未提供的字段保留)
                var found = false;
                var existing_models: []const []const u8 = &.{};
                var existing_cw: u32 = 128 * 1024;
                for (cfg.providers) |*p| {
                    if (std.mem.eql(u8, p.name, name)) {
                        found = true;
                        existing_models = p.models;
                        existing_cw = p.context_window;
                        break;
                    }
                }
                // models 未提供时保留现有
                const has_models_field = v.object.get("models") != null;
                const merged = cfgmod.Provider{
                    .name = name,
                    .api = if (std.mem.eql(u8, api_str, "anthropic-messages")) .anthropic_messages else .openai_completions,
                    .base_url = base_url,
                    .api_key = api_key,
                    .models = if (has_models_field) (models.toOwnedSlice() catch &.{}) else existing_models,
                    .context_window = if (has_models_field) 128 * 1024 else existing_cw,
                };
                if (found) {
                    // 更新现有(内存 + 落盘走全量)
                    for (cfg.providers) |*p| {
                        if (std.mem.eql(u8, p.name, name)) {
                            p.base_url = merged.base_url;
                            p.api = merged.api;
                            p.api_key = merged.api_key;
                            p.models = merged.models;
                            break;
                        }
                    }
                } else {
                    const all = cfg.allocator().alloc(cfgmod.Provider, cfg.providers.len + 1) catch return null;
                    @memcpy(all[0..cfg.providers.len], cfg.providers);
                    all[cfg.providers.len] = merged;
                    cfg.providers = all;
                }
                cfg.saveModels(cfg.providers) catch return write_err;
            }
        }
        // deleteProvider: name
        if (root.object.get("deleteProvider")) |v| {
            if (v == .string) {
                var keep = std.array_list.Managed(cfgmod.Provider).init(alloc);
                for (cfg.providers) |p| {
                    if (!std.mem.eql(u8, p.name, v.string)) keep.append(p) catch {};
                }
                if (keep.items.len != cfg.providers.len) {
                    cfg.providers = keep.toOwnedSlice() catch cfg.providers;
                    cfg.saveModels(cfg.providers) catch return write_err;
                }
            }
        }
    }
    // 输出配置(密钥脱敏)
    var stw = std.Io.Writer.Allocating.init(alloc);
    defer stw.deinit();
    const w = &stw.writer;
    w.writeAll("{\"defaultProvider\":") catch {};
    w.print("{s}", .{util.jsonString(alloc, cfg.default_provider orelse "") catch "\"\""}) catch {};
    w.writeAll(",\"defaultModel\":") catch {};
    w.print("{s}", .{util.jsonString(alloc, cfg.default_model orelse "") catch "\"\""}) catch {};
    w.writeAll(",\"providers\":[") catch {};
    for (cfg.providers, 0..) |p, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.print("{{\"name\":{s},\"baseUrl\":{s},\"api\":{s},\"hasKey\":{s},\"models\":[", .{
            util.jsonString(alloc, p.name) catch "\"\"",
            util.jsonString(alloc, p.base_url) catch "\"\"",
            util.jsonString(alloc, if (p.api == .anthropic_messages) "anthropic-messages" else "openai-completions") catch "\"\"",
            if (p.api_key != null) "true" else "false",
        }) catch {};
        for (p.models, 0..) |m, j| {
            if (j > 0) w.writeAll(",") catch {};
            w.print("{s}", .{util.jsonString(alloc, m) catch "\"\""}) catch {};
        }
        w.writeAll("]}") catch {};
    }
    w.writeAll("]}") catch {};
    return stw.toOwnedSlice() catch null;
}

/// `?ws=` 是否是已注册项目。
///
/// 精确字符串比对,不做 realpath 归一化:前端传回的 ws 就是注册时返回的原值,
/// 所以一致;而归一化会引入新的失败模式(目录被删就校验不了)。比对偏严不偏松 ——
/// 不在列表里就拒,这是安全校验该有的方向。
fn poolWsAllowed(ctx: ?*anyopaque, ws: []const u8) bool {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    pool.mutex.lock(util.io) catch return false;
    defer pool.mutex.unlock(util.io);
    for (pool.workspaces.items) |w| {
        if (std.mem.eql(u8, w, ws)) return true;
    }
    return false;
}

/// /api/workspaces hook:body=null 读列表;非 null {"root":...} 注册。返回 JSON 或 null。
fn poolWorkspacesHook(ctx: ?*anyopaque, alloc: std.mem.Allocator, body: ?[]const u8) ?[]const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    if (body) |b| {
        const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, b, .{}) catch return null;
        if (root != .object) return null;
        const path = if (root.object.get("root")) |v| (if (v == .string) v.string else null) else null;
        const p = path orelse return null;
        // 校验目录存在
        var d = std.Io.Dir.cwd().openDir(util.io, p, .{}) catch return null;
        d.close(util.io);
        pool.mutex.lock(util.io) catch return null;
        for (pool.workspaces.items) |ws| {
            if (std.mem.eql(u8, ws, p)) {
                pool.mutex.unlock(util.io);
                return "[]";
            }
        }
        pool.workspaces.append(pool.alloc.dupe(u8, p) catch {
            pool.mutex.unlock(util.io);
            return null;
        }) catch {};
        pool.mutex.unlock(util.io);
    }
    var stw = std.Io.Writer.Allocating.init(alloc);
    defer stw.deinit();
    const w = &stw.writer;
    w.writeAll("[") catch {};
    pool.mutex.lock(util.io) catch return "[]";
    for (pool.workspaces.items, 0..) |ws, i| {
        if (i > 0) w.writeAll(",") catch {};
        const base = std.fs.path.basename(ws);
        w.print("{{\"root\":{s},\"name\":{s}}}", .{
            util.jsonString(alloc, ws) catch "\"\"",
            util.jsonString(alloc, base) catch "\"\"",
        }) catch {};
    }
    pool.mutex.unlock(util.io);
    w.writeAll("]") catch {};
    return stw.toOwnedSlice() catch "[]";
}
fn poolModelsHook(ctx: ?*anyopaque, alloc: std.mem.Allocator) []const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    var stw = std.Io.Writer.Allocating.init(alloc);
    defer stw.deinit();
    const w = &stw.writer;
    w.writeAll("[") catch {};
    const models = pool.cfg.allModels(alloc);
    defer alloc.free(models);
    for (models, 0..) |m, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.print("{s}", .{util.jsonString(alloc, m) catch "\"\""}) catch {};
    }
    w.writeAll("]") catch {};
    return stw.toOwnedSlice() catch "[]";
}

/// /api/model hook:切换会话模型;返回当前模型或 null。会话不存在则惰性创建。
fn poolModelHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8, model: ?[]const u8) ?[]const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    var cur: ?[]const u8 = null;
    pool.mutex.lock(util.io) catch return null;
    for (pool.sessions.items) |ses| {
        if (std.mem.eql(u8, ses.name, session) and std.mem.eql(u8, ses.cwd, cwd2)) {
            if (model) |m| {
                ses.agent.switchModel(m) catch {
                    pool.mutex.unlock(util.io);
                    return null;
                };
            }
            cur = ses.agent.model;
            break;
        }
    }
    pool.mutex.unlock(util.io);
    if (cur) |c| return c;
    const ses = pool.getOrCreate(session, cwd2) orelse return null;
    if (model) |m| ses.agent.switchModel(m) catch return null;
    return ses.agent.model;
}

/// /api/title hook:设置会话标题;返回当前标题。会话不存在则惰性创建。
fn poolTitleHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8, title: ?[]const u8) ?[]const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    var cur: ?[]const u8 = null;
    pool.mutex.lock(util.io) catch return null;
    for (pool.sessions.items) |ses| {
        if (std.mem.eql(u8, ses.name, session) and std.mem.eql(u8, ses.cwd, cwd2)) {
            if (title) |t| {
                const trimmed = std.mem.trim(u8, t, " \t");
                ses.agent.title = if (trimmed.len > 0) (ses.agent.alloc.dupe(u8, trimmed) catch null) else null;
            }
            cur = ses.agent.title;
            break;
        }
    }
    pool.mutex.unlock(util.io);
    if (cur) |c| return c;
    const ses = pool.getOrCreate(session, cwd2) orelse return null;
    if (title) |t| {
        const trimmed = std.mem.trim(u8, t, " \t");
        ses.agent.title = if (trimmed.len > 0) (ses.agent.alloc.dupe(u8, trimmed) catch null) else null;
    }
    return ses.agent.title;
}

/// /api/action hook:kimi 式会话动作(fork/undo/compact/archive/restore/delete)。
/// 返回动作结果 JSON(新会话名/新消息数/ok)或 null(失败)。
fn poolActionHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8, act: []const u8, name: ?[]const u8, count: usize) ?[]const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const alloc = pool.alloc;
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    if (std.mem.eql(u8, act, "archive")) {
        // 从内存摘除 + 文件移入 archive/
        pool.mutex.lock(util.io) catch return null;
        for (pool.sessions.items, 0..) |ses, i| {
            if (std.mem.eql(u8, ses.name, session) and std.mem.eql(u8, ses.cwd, cwd2)) {
                _ = pool.sessions.swapRemove(i);
                break;
            }
        }
        pool.mutex.unlock(util.io);
        sessionmod.archiveWeb(alloc, cwd2, session) catch {};
        return "{\"ok\":true,\"act\":\"archive\"}";
    }
    if (std.mem.eql(u8, act, "restore")) {
        sessionmod.restoreWeb(alloc, cwd2, session) catch {};
        return "{\"ok\":true,\"act\":\"restore\"}";
    }
    if (std.mem.eql(u8, act, "delete")) {
        pool.mutex.lock(util.io) catch return null;
        for (pool.sessions.items, 0..) |ses, i| {
            if (std.mem.eql(u8, ses.name, session) and std.mem.eql(u8, ses.cwd, cwd2)) {
                _ = pool.sessions.swapRemove(i);
                break;
            }
        }
        pool.mutex.unlock(util.io);
        sessionmod.deleteWeb(alloc, cwd2, session) catch {};
        return "{\"ok\":true,\"act\":\"delete\"}";
    }
    // fork/undo/compact 需要活跃会话
    const ses = pool.getOrCreate(session, cwd2) orelse return null;
    if (std.mem.eql(u8, act, "fork")) {
        // 派生:复制消息 + 模型/模式/标题到新会话
        const new_name = if (name) |n|
            (if (n.len > 0 and sessionmod.webNameOk(n)) n else "")
        else
            "";
        var buf: [48]u8 = undefined;
        const ts = @divTrunc(std.Io.Clock.now(.real, util.io).nanoseconds, std.time.ns_per_ms);
        const rand_name = std.fmt.bufPrint(&buf, "{s}-f{d}", .{ session, ts }) catch session;
        const target = if (new_name.len > 0) new_name else rand_name;
        sessionmod.saveWebTs(alloc, cwd2, target, ses.agent.model, ses.mode.load(.acquire), ses.agent.title, ses.agent.messages.items, std.Io.Clock.now(.real, util.io).nanoseconds) catch return null;
        const out = std.fmt.allocPrint(alloc, "{{\"ok\":true,\"act\":\"fork\",\"name\":{s}}}", .{util.jsonString(alloc, target) catch "\"\""}) catch return null;
        return out;
    }
    if (std.mem.eql(u8, act, "undo")) {
        // 删最后 count 个回合(到第 count 个 user 消息为止)
        const n = if (count == 0) 1 else count;
        const msgs = ses.agent.messages.items;
        var cut: usize = 0;
        var remain = n;
        while (cut < msgs.len) {
            const i = msgs.len - 1 - cut;
            cut += 1;
            if (std.mem.eql(u8, msgs[i].role, "user")) {
                remain -= 1;
                if (remain == 0) break;
            }
        }
        if (remain > 0) return "{\"ok\":false,\"act\":\"undo\"}";
        if (msgs.len == 0) return "{\"ok\":false,\"act\":\"undo\"}";
        ses.agent.messages.shrinkRetainingCapacity(msgs.len - cut);
        ses.updated_ns = std.Io.Clock.now(.real, util.io).nanoseconds;
        sessionmod.saveWebTs(alloc, cwd2, session, ses.agent.model, ses.mode.load(.acquire), ses.agent.title, ses.agent.messages.items, ses.updated_ns) catch {};
        return std.fmt.allocPrint(alloc, "{{\"ok\":true,\"act\":\"undo\",\"msgs\":{d}}}", .{msgs.len - cut}) catch null;
    }
    if (std.mem.eql(u8, act, "compact")) {
        _ = ses.agent.compact() catch "";
        return "{\"ok\":true,\"act\":\"compact\"}";
    }
    return null;
}

/// /api/mode hook:auto=null 读,非 null 写;返回当前模式。会话不存在则惰性创建。
fn poolModeHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8, auto: ?bool) ?bool {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    var cur: ?bool = null;
    pool.mutex.lock(util.io) catch return null;
    for (pool.sessions.items) |ses| {
        if (std.mem.eql(u8, ses.name, session) and std.mem.eql(u8, ses.cwd, cwd2)) {
            if (auto) |a| ses.mode.store(a, .release);
            cur = ses.mode.load(.acquire);
            break;
        }
    }
    pool.mutex.unlock(util.io);
    if (cur) |c| return c;
    // 会话不存在:惰性创建(getOrCreate 自持锁,须先释放)
    const ses = pool.getOrCreate(session, cwd2) orelse return null;
    if (auto) |a| ses.mode.store(a, .release);
    return ses.mode.load(.acquire);
}

/// /api/chat hook:getOrCreate 会话 + 入队 + user_message 事件。
fn poolChatHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8, text: []const u8) bool {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    const ses = pool.getOrCreate(session, cwd2) orelse return false;
    ses.hub.push("{{\"type\":\"user_message\",\"session\":{s},\"text\":{s}}}", .{ util.jsonString(pool.alloc, ses.name) catch "\"\"", util.jsonString(pool.alloc, text) catch "\"\"" });
    webui_mod.ChatQueue.enqueue(ses.qkey, text);
    return true;
}
fn runPkgCmd(alloc: std.mem.Allocator, args: *std.process.Args.Iterator) void {
    const sub = args.next() orelse {
        std.debug.print("piz pkg: usage: install <path> [-l] | list | remove <name> [-l]\n", .{});
        std.process.exit(1);
    };
    const proj_cwd = std.process.currentPathAlloc(util.io, alloc) catch null;
    if (std.mem.eql(u8, sub, "list")) {
        const user = pkgsmod.list(alloc, .user, proj_cwd) catch &.{};
        const proj = pkgsmod.list(alloc, .project, proj_cwd) catch &.{};
        std.debug.print("user packages ({d}):\n", .{user.len});
        for (user) |p| {
            std.debug.print("  {s}  skills:{d} prompts:{d}{s}{s}\n", .{ p.name, p.skills, p.prompts, if (p.has_agents) " agents:yes" else "", if (p.has_web) " web:yes" else "" });
        }
        std.debug.print("project packages ({d}):\n", .{proj.len});
        for (proj) |p| {
            std.debug.print("  {s}  skills:{d} prompts:{d}{s}{s}\n", .{ p.name, p.skills, p.prompts, if (p.has_agents) " agents:yes" else "", if (p.has_web) " web:yes" else "" });
        }
        if (user.len + proj.len == 0) std.debug.print("  (none)\n", .{});
        std.process.exit(0);
    }
    if (std.mem.eql(u8, sub, "install")) {
        const src = args.next() orelse {
            std.debug.print("piz pkg install: usage: piz pkg install <path> [-l] [-y]\n", .{});
            std.process.exit(1);
        };
        var scope = pkgsmod.Scope.user;
        var assume_yes = false;
        while (args.next()) |extra| {
            if (std.mem.eql(u8, extra, "-l") or std.mem.eql(u8, extra, "--local")) {
                scope = .project;
            } else if (std.mem.eql(u8, extra, "-y") or std.mem.eql(u8, extra, "--yes")) {
                assume_yes = true;
            } else {
                std.debug.print("piz pkg install: unknown option {s}\n", .{extra});
                std.process.exit(1);
            }
        }
        // 包声明的 events 钩子会在 agent 生命周期各点跑 `bash -c <command>`,
        // startup 钩子在下次启动时立刻执行。装包因此等于授权本机命令执行 ——
        // 装之前必须让用户看见到底授权了什么。
        //
        // 本地源在这里问(拒绝就直接不装);git 源此刻还没 clone,见下面装后那一步。
        const local_src: ?[]const u8 = switch (pkgsmod.detectSource(src)) {
            .path => |p| p,
            .git => null,
        };
        if (local_src) |p| {
            if (!confirmPkgHooks(alloc, p, "继续安装?", assume_yes)) {
                std.debug.print("piz pkg install: 已取消。\n", .{});
                std.process.exit(1);
            }
        }
        const dest = pkgsmod.install(alloc, src, scope, proj_cwd) catch |err| {
            std.debug.print("piz pkg install: failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        // git 源在上一步还没 clone,只能装完再看(本地源已经问过,那时 hooks
        // 已确认,这里 declaredHooks 会再列一次 —— 所以只对 git 源做)。
        // 用户拒绝就删掉:钩子要到下次启动才跑,此刻撤销来得及。
        if (local_src == null and !confirmPkgHooks(alloc, dest, "保留这个包?", assume_yes)) {
            std.Io.Dir.cwd().deleteTree(util.io, dest) catch |err| {
                std.debug.print("piz pkg install: 已取消,但删除 {s} 失败({s})——请手动删除。\n", .{ dest, @errorName(err) });
                std.process.exit(1);
            };
            std.debug.print("piz pkg install: 已取消,已移除 {s}。\n", .{dest});
            std.process.exit(1);
        }
        std.debug.print("installed {s} → {s}\n", .{ src, dest });
        std.process.exit(0);
    }
    if (std.mem.eql(u8, sub, "update")) {
        var scope = pkgsmod.Scope.user;
        if (args.next()) |extra| {
            if (std.mem.eql(u8, extra, "-l") or std.mem.eql(u8, extra, "--local")) {
                scope = .project;
            } else {
                std.debug.print("piz pkg update: unknown option {s}\n", .{extra});
                std.process.exit(1);
            }
        }
        const n = pkgsmod.update(alloc, scope, proj_cwd) catch |err| {
            std.debug.print("piz pkg update: failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        std.debug.print("updated {d} packages\n", .{n});
        std.process.exit(0);
    }
    if (std.mem.eql(u8, sub, "remove")) {
        const name = args.next() orelse {
            std.debug.print("piz pkg remove: usage: piz pkg remove <name> [-l]\n", .{});
            std.process.exit(1);
        };
        var scope = pkgsmod.Scope.user;
        if (args.next()) |extra| {
            if (std.mem.eql(u8, extra, "-l") or std.mem.eql(u8, extra, "--local")) {
                scope = .project;
            } else {
                std.debug.print("piz pkg remove: unknown option {s}\n", .{extra});
                std.process.exit(1);
            }
        }
        pkgsmod.remove(alloc, name, scope, proj_cwd) catch |err| {
            std.debug.print("piz pkg remove: failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        std.debug.print("removed {s}\n", .{name});
        std.process.exit(0);
    }
    std.debug.print("piz pkg: unknown subcommand {s}\n", .{sub});
    std.process.exit(1);
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
        if (child.stdin) |f| {
            var wbuf: [8192]u8 = undefined;
            var w = f.writer(util.io, &wbuf);
            if (w.interface.writeAll(text)) |_| {
                w.flush() catch {};
            } else |_| {}
            f.close(util.io);
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
            if (app.worker != null) {
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
        if (std.mem.eql(u8, cmd, "plan")) {
            // 计划模式:让模型制定计划写入 PLAN.md,随后按计划执行
            const goal = line[5..];
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
            app.tui.appendLine("", "\x1b[36m", "/help /status /model <m> /new /sessions /resume <n> /title <t> /tree /fork <n> /copy /undo /redo /memory /compact /clear /quit") catch {};
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
    const expanded = expandRefs(app.alloc, line) catch line;
    if (app.worker_active.load(.acquire)) {
        // worker 忙:入队(steering),轮次间自动投递
        app.enqueue(expanded);
        var bw = std.Io.Writer.Allocating.init(app.alloc);
        defer bw.deinit();
        bw.writer.print("⏳ queued ({d} pending) — /queue to clear", .{app.queue.items.len}) catch {};
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

/// 展开行内 @path 引用(仅限 @/、@./、@../ 前缀,防误伤);文件嵌入 ``` 代码块,截断 8KB。
fn expandRefs(alloc: std.mem.Allocator, line: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    var i: usize = 0;
    while (i < line.len) {
        const is_path_ref = line[i] == '@' and i + 1 < line.len and
            (line[i + 1] == '/' or
                (line[i + 1] == '.' and i + 2 < line.len and (line[i + 2] == '/' or line[i + 2] == '.')));
        if (is_path_ref) {
            var j = i + 1;
            while (j < line.len and !std.ascii.isWhitespace(line[j])) j += 1;
            const path = line[i + 1 .. j];
            const content = std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(8 * 1024)) catch {
                try out.append('@');
                i += 1;
                continue;
            };
            defer alloc.free(content);
            try out.appendSlice("\n```");
            try out.appendSlice(path);
            try out.appendSlice("\n");
            try out.appendSlice(content);
            if (content.len >= 8 * 1024) try out.appendSlice("\n…(truncated)");
            try out.appendSlice("```\n");
            i = j;
            continue;
        }
        try out.append(line[i]);
        i += 1;
    }
    return out.toOwnedSlice();
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

pub const OutputFormat = enum { text, json, jsonl };

pub const RunOptions = struct {
    provider_name: ?[]const u8 = null,
    model_name: ?[]const u8 = null,
    read_only: bool = false,
    /// -x:工具自动执行,不询问
    execute: bool = false,
    new_session: bool = false,
    title: ?[]const u8 = null,
    output_format: OutputFormat = .text,
    /// -s:恢复指定会话(id 为文件名去 .jsonl)
    session_id: ?[]const u8 = null,
    /// -a:异步后台运行(仅 print 模式)
    async_run: bool = false,
    /// --system:自定义系统提示
    system_override: ?[]const u8 = null,
};

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
    var agent = try agentmod.Agent.initOpts(alloc, cfg, opts.provider_name, opts.model_name, abs_cwd, .{ .read_only = opts.read_only, .system_override = opts.system_override });
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
        .on_require_permission = tuiOnRequirePermission,
        .on_abort = tuiOnAbort,
    };
    if (opts.execute) app.perm.always.store(true, .release);

    // 启动提示
    var gw = std.Io.Writer.Allocating.init(alloc);
    defer gw.deinit();
    gw.writer.print("piz v{s} — pi 的 Zig 重写 · {s}/{s} · {s}\n/help 查看命令", .{ VERSION, agent.provider.name, agent.model, abs_cwd }) catch {};
    try tui.appendLine("", "\x1b[36m", gw.written());
    const st = try app.statusLine();
    try tui.setStatus("\x1b[2m", st);

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

// ---------- print 模式 ----------

const JsonlCtx = struct {
    alloc: std.mem.Allocator,
};

fn jstdout(_: std.mem.Allocator, json: []const u8) !void {
    var sbuf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(util.io, &sbuf);
    try w.interface.writeAll(json);
    try w.flush();
}

fn jsonlEvent(alloc: std.mem.Allocator, comptime ty: []const u8, fields: anytype) !void {
    var ww = std.Io.Writer.Allocating.init(alloc);
    defer ww.deinit();
    try ww.writer.print("{{\"type\":\"{s}\"", .{ty});
    comptime var i: usize = 0;
    inline while (i < fields.len) : (i += 2) {
        const name = fields[i];
        const value = fields[i + 1];
        try ww.writer.print(",\"{s}\":{s}", .{ name, try util.jsonString(alloc, value) });
    }
    try ww.writer.writeAll("}\n");
    try jstdout(alloc, try ww.toOwnedSlice());
}

fn jsonlOnText(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const jctx: *JsonlCtx = @ptrCast(@alignCast(ctx.?));
    try jsonlEvent(jctx.alloc, "text", .{ "text", text });
}

fn jsonlOnReasoning(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const jctx: *JsonlCtx = @ptrCast(@alignCast(ctx.?));
    try jsonlEvent(jctx.alloc, "reasoning", .{ "text", text });
}

fn jsonlOnToolStart(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!void {
    const jctx: *JsonlCtx = @ptrCast(@alignCast(ctx.?));
    try jsonlEvent(jctx.alloc, "tool_start", .{ "name", name, "args", args });
}

fn jsonlOnToolEnd(ctx: ?*anyopaque, name: []const u8, is_error: bool, summary: []const u8) anyerror!void {
    const jctx: *JsonlCtx = @ptrCast(@alignCast(ctx.?));
    try jsonlEvent(jctx.alloc, "tool_end", .{ "name", name, "error", if (is_error) "true" else "false", "summary", summary });
}

fn printResultJson(alloc: std.mem.Allocator, result: ai.RunResult) !void {
    try jstdout(alloc, try resultJsonAlloc(alloc, result));
}

/// 结果 JSON 序列化(供 print -o json 与测试)。
fn resultJsonAlloc(alloc: std.mem.Allocator, result: ai.RunResult) ![]u8 {
    var ww = std.Io.Writer.Allocating.init(alloc);
    defer ww.deinit();
    try ww.writer.writeAll("{\"text\":");
    try ww.writer.writeAll(try util.jsonString(alloc, result.text));
    try ww.writer.writeAll(",\"reasoning\":");
    try ww.writer.writeAll(try util.jsonString(alloc, result.reasoning));
    try ww.writer.writeAll(",\"tool_calls\":[");
    for (result.tool_calls, 0..) |tc, i| {
        if (i > 0) try ww.writer.writeByte(',');
        try ww.writer.print("{{\"id\":{s},\"name\":{s},\"args\":{s}}}", .{
            try util.jsonString(alloc, tc.id),
            try util.jsonString(alloc, tc.name),
            try util.jsonString(alloc, tc.args),
        });
    }
    try ww.writer.writeAll("],\"usage\":{\"input\":");
    if (result.usage.input) |i| try ww.writer.print("{d}", .{i}) else try ww.writer.writeAll("null");
    try ww.writer.writeAll(",\"output\":");
    if (result.usage.output) |o| try ww.writer.print("{d}", .{o}) else try ww.writer.writeAll("null");
    try ww.writer.writeAll(",\"cache_read\":");
    if (result.usage.cache_read) |c| try ww.writer.print("{d}", .{c}) else try ww.writer.writeAll("null");
    try ww.writer.writeAll(",\"cache_write\":");
    if (result.usage.cache_write) |c| try ww.writer.print("{d}", .{c}) else try ww.writer.writeAll("null");
    try ww.writer.writeAll("},\"error\":");
    if (result.error_msg) |m| try ww.writer.writeAll(try util.jsonString(alloc, m)) else try ww.writer.writeAll("null");
    try ww.writer.writeAll("}\n");
    return ww.toOwnedSlice();
}

test "result json serialization" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const j = try resultJsonAlloc(a, .{
        .text = "hi",
        .reasoning = "th",
        .tool_calls = &.{.{ .id = "c1", .name = "bash", .args = "{}" }},
        .usage = .{ .input = 5, .output = 3 },
    });
    try t.expect(std.mem.indexOf(u8, j, "\"text\":\"hi\"") != null);
    try t.expect(std.mem.indexOf(u8, j, "\"name\":\"bash\"") != null);
    try t.expect(std.mem.indexOf(u8, j, "\"input\":5") != null);
    try t.expect(std.mem.indexOf(u8, j, "\"error\":null") != null);
    // error 路径
    const je = try resultJsonAlloc(a, .{ .text = "", .error_msg = "boom" });
    try t.expect(std.mem.indexOf(u8, je, "\"error\":\"boom\"") != null);
}

pub fn runPrint(alloc: std.mem.Allocator, cfg: *cfgmod.Config, cwd: []const u8, prompt: []const u8, opts: RunOptions) !void {
    const abs_cwd = std.process.currentPathAlloc(util.io, alloc) catch cwd;
    var sess = if (opts.session_id) |id| blk: {
        const found = (try sessionmod.Session.findById(alloc, abs_cwd, id)) orelse {
            std.debug.print("piz: session '{s}' not found in {s}\n", .{ id, abs_cwd });
            std.process.exit(1);
        };
        break :blk found;
    } else (try sessionmod.Session.findLatest(alloc, abs_cwd)) orelse (try sessionmod.Session.fresh(alloc, abs_cwd));
    var agent = try agentmod.Agent.initOpts(alloc, cfg, opts.provider_name, opts.model_name, abs_cwd, .{ .read_only = opts.read_only, .system_override = opts.system_override });
    if (agent.key == null) {
        std.debug.print("piz: no API key for provider '{s}'. Set ~/.piz/auth.json, models.json apiKey, or env.\n", .{agent.provider.name});
        std.process.exit(1);
    }
    const loaded = try sess.loadMessages();
    try agent.messages.appendSlice(loaded);

    // 输出模式:jsonl 用事件回调,text 用现有回调,json 静默流式
    var jctx = JsonlCtx{ .alloc = alloc };
    if (opts.output_format == .jsonl) {
        agent.cbs = .{
            .ctx = &jctx,
            .on_text = jsonlOnText,
            .on_reasoning = jsonlOnReasoning,
            .on_tool_start = jsonlOnToolStart,
            .on_tool_end = jsonlOnToolEnd,
            .on_notice = jsonlOnNotice,
        };
    } else if (opts.output_format == .text) {
        agent.cbs = .{
            .on_text = printOnText,
            .on_reasoning = printOnReasoning,
            .on_tool_start = printOnToolStart,
            .on_tool_end = printOnToolEnd,
            .on_notice = printOnNotice,
        };
    }

    var bus = try eventsmod.Bus.init(alloc);
    {
        var ea = util.Arena.init(alloc);
        defer ea.deinit();
        const ealloc = ea.allocator();
        bus.emit("startup", std.fmt.allocPrint(ealloc, "\"cwd\":{s}", .{try util.jsonString(ealloc, abs_cwd)}) catch "");
    }
    const n_before = agent.messages.items.len;
    const result = try agent.send(prompt);
    // 保存增量
    for (agent.messages.items[n_before..]) |*m| try sess.saveMessage(m);
    bus.emit("turn_end", "");

    if (opts.output_format != .text) {
        if (opts.output_format == .jsonl) {
            try jsonlEvent(alloc, "result", .{
                "text",      result.text,
                "reasoning", result.reasoning,
                "error",     result.error_msg orelse "",
            });
        } else {
            try printResultJson(alloc, result);
        }
    }

    if (result.error_msg) |msg| {
        if (opts.output_format == .text) std.debug.print("error: {s}\n", .{msg});
        std.process.exit(1);
    }
    // 工具调用摘要(print 模式工具输出已在工具回调中显示到 stderr)
    var sbuf: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(util.io, &sbuf);
    if (result.usage.input) |i| stderr.interface.print("\n[tokens in: {d}]", .{i}) catch {};
    if (result.usage.output) |o| stderr.interface.print(" [out: {d}]", .{o}) catch {};
    stderr.interface.print("\n", .{}) catch {};
    std.process.exit(0);
}

fn printOnText(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    _ = ctx;
    var sbuf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(util.io, &sbuf);
    try w.interface.writeAll(text);
    try w.flush();
}

var reason_buf: [512]u8 = undefined;
fn printOnReasoning(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    _ = ctx;
    var w = std.Io.File.stderr().writer(util.io, &reason_buf);
    w.interface.print("\x1b[2m{s}\x1b[0m", .{text}) catch {};
    w.flush() catch {};
}

var tool_buf: [512]u8 = undefined;
fn printOnToolStart(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!void {
    _ = ctx;
    var w = std.Io.File.stderr().writer(util.io, &tool_buf);
    w.interface.print("\n\x1b[36m⚙ {s} {s}\x1b[0m\n", .{ name, args[0..@min(args.len, 200)] }) catch {};
    w.flush() catch {};
}

var toolend_buf: [512]u8 = undefined;
fn printOnToolEnd(ctx: ?*anyopaque, name: []const u8, is_error: bool, summary: []const u8) anyerror!void {
    _ = ctx;
    var w = std.Io.File.stderr().writer(util.io, &toolend_buf);
    // 带上输出规模:print 模式下工具产出全进了模型上下文,用户一个字看不到,
    // 至少让他知道「这一步吐了 12KB」而不是完全无从判断。
    var bb: [24]u8 = undefined;
    w.interface.print("\x1b[{s}m{s} {s}\x1b[0m \x1b[2m{s}\x1b[0m\n", .{
        if (is_error) "31" else "32",
        if (is_error) "✗" else "✓",
        name,
        activity.formatBytes(&bb, summary.len),
    }) catch {};
    w.flush() catch {};
}

/// 确认包目录声明的 events 钩子。返回 true 表示可以继续。
///
/// 包里的 `extensions.events` 会由 events.Bus 以 `bash -c` 执行,`startup` 钩子
/// 在下次启动时立刻跑 —— 装包等于授权本机命令执行。没有钩子的包直接放行
/// (大多数包如此),有钩子就把命令原文列出来让用户看。
///
/// stdin 不是终端时(脚本、管道)拒绝而非默认同意:静默授权任意命令执行
/// 比让脚本报错糟得多。需要非交互装包就显式加 `-y`。
///
/// 两个调用时机:本地源在拷贝**之前**问(干净,不用回滚);git 源那时还没 clone、
/// 拿不到 pkg.json,只能装完再问,拒绝时由调用方删掉包目录 —— 钩子要到下次启动
/// 才跑,此刻撤销仍然来得及。
fn confirmPkgHooks(alloc: std.mem.Allocator, pkg_dir: []const u8, prompt: []const u8, assume_yes: bool) bool {
    const hooks = pkgsmod.declaredHooks(alloc, pkg_dir) catch return true;
    if (hooks.len == 0) return true;

    std.debug.print("\n这个包声明了 {d} 个生命周期钩子,会以 `bash -c` 执行:\n\n", .{hooks.len});
    for (hooks) |h| {
        std.debug.print("  [{s}] {s}\n", .{ h.event, h.command });
    }
    std.debug.print("\n其中 startup 钩子会在下次启动 piz 时立刻运行。\n", .{});
    if (assume_yes) {
        std.debug.print("(-y 已指定,继续)\n\n", .{});
        return true;
    }
    if (!util.stdinIsTty()) {
        std.debug.print("stdin 不是终端,无法确认。确认要装请加 -y。\n", .{});
        return false;
    }
    std.debug.print("{s} [y/N] ", .{prompt});
    var buf: [16]u8 = undefined;
    const line = util.readLineStdin(&buf) orelse return false;
    const ans = std.mem.trim(u8, line, " \t\r\n");
    return std.mem.eql(u8, ans, "y") or std.mem.eql(u8, ans, "Y") or std.mem.eql(u8, ans, "yes");
}

var notice_buf: [512]u8 = undefined;
/// 引擎级告知走 stderr:stdout 是给管道下游的答复正文,不能混进这些。
fn printOnNotice(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    _ = ctx;
    var w = std.Io.File.stderr().writer(util.io, &notice_buf);
    w.interface.print("\x1b[33m· {s}\x1b[0m\n", .{text}) catch {};
    w.flush() catch {};
}

fn jsonlOnNotice(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const jctx: *JsonlCtx = @ptrCast(@alignCast(ctx.?));
    try jsonlEvent(jctx.alloc, "notice", .{ "text", text });
}

/// 配置文件解析失败时提示用户。
///
/// 语法坏了的配置会被当成不存在,于是用户看到的是「unknown provider」这类
/// 下游症状,猜不到是自己的 JSON 少了个逗号。走 stderr:stdout 留给管道下游。
fn warnBrokenConfig(cfg: *cfgmod.Config) void {
    for (cfg.broken_files) |name| {
        std.debug.print(
            "piz: ~/.piz/{s} 有语法错误,已按「不存在」处理。修好它才会生效。\n",
            .{name},
        );
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
            runPkgCmd(alloc, &args); // 不返回
        } else if (std.mem.eql(u8, arg, "web")) {
            runWebCmd(alloc, &args); // 不返回
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
    warnBrokenConfig(&cfg);

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
        runAsync(alloc, cwd, print_prompt orelse "", all_args.items) catch |e| explainAndExit(e, &cfg, opts);
    } else if (print_mode) {
        runPrint(alloc, &cfg, cwd, print_prompt orelse "", opts) catch |e| explainAndExit(e, &cfg, opts);
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

/// -a 异步:建新会话 → spawn 自身(去 -a,加 -s <id> -n) → 立即返回。
fn runAsync(alloc: std.mem.Allocator, cwd: []const u8, prompt: []const u8, orig_args: []const []const u8) !void {
    if (prompt.len == 0) {
        std.debug.print("piz: -a requires a prompt (argument or -i file)\n", .{});
        std.process.exit(1);
    }
    const abs_cwd = std.process.currentPathAlloc(util.io, alloc) catch cwd;
    const sess = try sessionmod.Session.fresh(alloc, abs_cwd);
    const base = std.fs.path.basename(sess.path);
    const id = base[0 .. base.len - ".jsonl".len];

    // 日志:<configDir>/logs/piz-<id>.log
    const cfg_dir = try util.configDir(alloc);
    const logs_dir = try util.joinPath(alloc, cfg_dir, "logs");
    std.Io.Dir.cwd().createDirPath(util.io, logs_dir) catch {};
    const log_path = try std.fmt.allocPrint(alloc, "{s}/piz-{s}.log", .{ logs_dir, id });
    var logf = try std.Io.Dir.cwd().createFile(util.io, log_path, .{ .truncate = true, .permissions = @enumFromInt(0o600) });
    defer logf.close(util.io);

    // 重建 argv:原参数(含 argv[0])去 -a/--async,尾部加 -s <id> -n(确保子进程写此会话)
    var argv = std.array_list.Managed([]const u8).init(alloc);
    defer argv.deinit();
    for (orig_args) |a| {
        if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "--async")) continue;
        try argv.append(a);
    }
    try argv.append("-s");
    try argv.append(id);
    try argv.append("-n");
    try argv.append("-c"); // -s 优先于 -n;-c 覆盖前序 -n(防御)

    const child = try std.process.spawn(util.io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .{ .file = logf },
        .stderr = .{ .file = logf },
        .pgid = 0, // 新进程组,脱离终端信号
        .expand_arg0 = .expand,
    });
    _ = child;
    std.debug.print("async: session {s} started — resume with: piz -s {s} -p \"...\"\nlog: {s}\n", .{ id, id, log_path });
    std.process.exit(0);
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
    warnBrokenConfig(&cfg);
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
    const r1 = try expandRefs(a, "read this @./ref_test.txt please");
    try t.expect(std.mem.indexOf(u8, r1, "FILE-CONTENT") != null);
    try t.expect(std.mem.indexOf(u8, r1, "```./ref_test.txt") != null);
    // 普通 @ 保留(邮箱/提及)
    const r2 = try expandRefs(a, "mail me @someone now");
    try t.expectEqualStrings("mail me @someone now", r2);
    // 不存在路径保留原文
    const r3 = try expandRefs(a, "see @./nope.txt end");
    try t.expectEqualStrings("see @./nope.txt end", r3);
}
