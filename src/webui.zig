// webui.zig — 内置 Web UI(对齐 kimi web / grok --web):单进程本地 HTTP 服务 + SSE + 单页。
//   piz web [--port N] [--no-open] [--token T]
//   默认 127.0.0.1:5494(占用自动 +1,范围 5494-5503);--token 启用 Bearer 认证。
//   端点:GET /(单页) GET /api/events(SSE) GET /api/state GET /api/activity GET /api/usage POST /api/chat POST /api/interrupt
const std = @import("std");
const util = @import("core").util;
const oauth = @import("core").oauth;
const agentmod = @import("core").agent;
const webplugins = @import("core").webplugins;
const sessionmod = @import("core").session;
const activity = @import("core").activity;
const pkgsmod = @import("core").pkgs;
const cmd_help = @import("cmd_help.zig");
const routes = @import("webui_routes.zig");
const http = std.http;
const net = std.Io.net;

pub const WebOptions = struct {
    port: u16 = 0, // 0 = 从 5494 起自动找可用端口
    no_open: bool = false,
    token: ?[]const u8 = null,
    project_cwd: ?[]const u8 = null,
};

/// 带锁的 arena:多线程并发分配安全。
///
/// WebServer.alloc 与 SessionPool.alloc 会被**多个 HTTP 线程并发分配**
/// (每个请求都在上面拼 JSON、解析 body),而裸 ArenaAllocator 不是线程安全的
/// —— 实测两路并发 chat 直接把进程打崩。包装一层互斥锁后,arena 的
/// 「进程活到退出、免逐条 free」语义保留,并发安全也拿到。
/// 锁粒度粗但可接受:本地 UI 的分配频率远够不上争锁。
pub const SyncedArena = struct {
    mutex: std.Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,

    pub fn init(child: std.mem.Allocator) SyncedArena {
        return .{ .arena = std.heap.ArenaAllocator.init(child) };
    }

    pub fn deinit(self: *SyncedArena) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *SyncedArena) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .remap = remapFn,
                .free = freeFn,
            },
        };
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *SyncedArena = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        // 注意 inner.ptr 是 &self.arena,不是 ctx —— vtable 函数需要 arena 对象
        // 的地址,传 SyncedArena 的地址会被按 ArenaAllocator 解引用(UB)。
        const inner = self.arena.allocator();
        return inner.vtable.alloc(inner.ptr, len, alignment, ret_addr);
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *SyncedArena = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        const inner = self.arena.allocator();
        return inner.vtable.resize(inner.ptr, memory, alignment, new_len, ret_addr);
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *SyncedArena = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        const inner = self.arena.allocator();
        return inner.vtable.remap(inner.ptr, memory, alignment, new_len, ret_addr);
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *SyncedArena = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        const inner = self.arena.allocator();
        inner.vtable.free(inner.ptr, memory, alignment, ret_addr);
    }
};

/// 全局事件(SSE 转发用);agent worker 生产,SSE 连接线程消费。
/// 裁剪:每连接上报已消费位置,所有连接都消费过的头部事件即释放(防无限积累)。
pub const EventHub = struct {
    /// 并发 SSE 连接上限。每个浏览器标签页占一个;满员时新连接收 503 而不是
    /// 空流。slot 固定不复用索引,防事件游标漂移。
    pub const MAX_STREAMS = 16;

    const Conn = struct {
        cursor: usize = 0,
        last_seen_ns: i128 = 0,
    };
    mutex: std.Io.Mutex = .init,
    events: std.array_list.Managed([]const u8), // 预组装 JSON 行(alloc)
    conns: [MAX_STREAMS]?Conn = .{null} ** MAX_STREAMS,

    pub fn init(alloc: std.mem.Allocator) EventHub {
        return .{ .events = std.array_list.Managed([]const u8).init(alloc) };
    }
    pub fn deinit(self: *EventHub) void {
        self.mutex.lock(util.io) catch {};
        defer self.mutex.unlock(util.io);
        for (self.events.items) |e| self.events.allocator.free(e);
        self.events.deinit();
    }
    /// 注册 SSE 连接,返回固定 slot;满员返 null。
    ///
    /// 先收僵死 slot:连接非正常断开(关标签页、杀浏览器)时 unregister 不会跑,
    /// slot 要等下一次 push 才被心跳超时回收。没有 push 的空闲期里,16 个
    /// 僵死 slot 就能让新连接一直注册不上。
    pub fn register(self: *EventHub, now_ns: i128) ?usize {
        self.mutex.lock(util.io) catch return null;
        defer self.mutex.unlock(util.io);
        for (&self.conns) |*c| {
            const st = c.* orelse continue;
            if (now_ns - st.last_seen_ns > 60 * std.time.ns_per_s) c.* = null;
        }
        for (&self.conns, 0..) |*c, i| {
            if (c.* == null) {
                c.* = .{ .last_seen_ns = now_ns };
                return i;
            }
        }
        return null;
    }
    pub fn unregister(self: *EventHub, slot: usize) void {
        self.mutex.lock(util.io) catch return;
        defer self.mutex.unlock(util.io);
        if (slot < self.conns.len) self.conns[slot] = null;
        _ = self.trimLocked();
    }
    /// 追加事件(SSE 连接按 100ms 轮询转发)。调用者须已持锁。返回裁掉的事件数。
    fn trimLocked(self: *EventHub) usize {
        const now = std.Io.Clock.now(.real, util.io).nanoseconds;
        var m: usize = std.math.maxInt(usize);
        var live = false;
        for (&self.conns) |*c| {
            const st = c.* orelse continue;
            if (now - st.last_seen_ns > 60 * std.time.ns_per_s) {
                c.* = null; // 连接已断开(心跳超时)
                continue;
            }
            live = true;
            m = @min(m, st.cursor);
        }
        if (!live or m == 0) return 0;
        if (m >= self.events.items.len) {
            for (self.events.items) |e| self.events.allocator.free(e);
            self.events.clearRetainingCapacity();
        } else {
            for (self.events.items[0..m]) |e| self.events.allocator.free(e);
            const rest = self.events.items.len - m;
            std.mem.copyForwards([]const u8, self.events.items[0..rest], self.events.items[m..]);
            self.events.shrinkRetainingCapacity(rest);
        }
        for (&self.conns) |*c| {
            if (c.*) |*st| st.cursor -= m;
        }
        return m;
    }
    /// 追加事件。
    pub fn push(self: *EventHub, comptime fmt: []const u8, args: anytype) void {
        const alloc = self.events.allocator;
        const line = std.fmt.allocPrint(alloc, fmt, args) catch return;
        self.mutex.lock(util.io) catch return;
        self.events.append(line) catch alloc.free(line);
        _ = self.trimLocked();
        self.mutex.unlock(util.io);
    }
};

pub const OauthKind = enum { openrouter, xai, openai };
pub const OauthPend = struct {
    state: [32]u8 = undefined,
    state_n: u8 = 0,
    verifier: [43]u8 = undefined,
    device: [255]u8 = undefined,
    device_n: u8 = 0,
    kind: OauthKind = .openrouter,
    live: bool = false,
    done: bool = false,
    err: bool = false,
};

pub const WebServer = struct {
    alloc: std.mem.Allocator,
    opts: WebOptions,
    hub: *EventHub,
    agent: ?*agentmod.Agent = null,
    /// 会话池回调(main 实现):state 数据 / chat 入队(返回 false 拒绝);cwd = 项目根
    state_hook: ?*const fn (ctx: ?*anyopaque, cwd: []const u8, session: []const u8, alloc: std.mem.Allocator) []const u8 = null,
    history_hook: ?*const fn (ctx: ?*anyopaque, cwd: []const u8, session: []const u8, offset: usize, limit: usize, alloc: std.mem.Allocator) []const u8 = null,
    history_ctx: ?*anyopaque = null,
    state_ctx: ?*anyopaque = null,
    chat_hook: ?*const fn (ctx: ?*anyopaque, cwd: []const u8, session: []const u8, text: []const u8, image: ?[]const u8, mime: []const u8) bool = null,
    chat_ctx: ?*anyopaque = null,
    /// 会话列表 hook(main 实现):返回 JSON 数组 [{name,msgs}] (按 cwd 过滤)
    sessions_hook: ?*const fn (ctx: ?*anyopaque, cwd: []const u8, alloc: std.mem.Allocator) []const u8 = null,
    sessions_ctx: ?*anyopaque = null,
    /// 中断 hook(main 实现):中止指定会话当前轮
    interrupt_hook: ?*const fn (ctx: ?*anyopaque, cwd: []const u8, session: []const u8) void = null,
    interrupt_ctx: ?*anyopaque = null,
    /// 插件斜杠:写入纯文本则已处理;返回 false 表示未注册。
    slash_hook: ?*const fn (ctx: ?*anyopaque, cwd: []const u8, session: []const u8, name: []const u8, args: []const u8, out: *std.Io.Writer) bool = null,
    slash_ctx: ?*anyopaque = null,
    /// 当前会话插件斜杠目录(供 /api/help)。
    slash_catalog_hook: ?*const fn (ctx: ?*anyopaque, cwd: []const u8, session: []const u8, out: []cmd_help.HelpItem) usize = null,
    /// 审批模式 hook(auto=null 读):返回当前模式或 null(会话不存在)
    mode_hook: ?*const fn (ctx: ?*anyopaque, cwd: []const u8, session: []const u8, mode: ?[]const u8) ?[]const u8 = null,
    mode_ctx: ?*anyopaque = null,
    /// 模型列表 hook:可用模型 JSON 数组
    models_hook: ?*const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator) []const u8 = null,
    models_ctx: ?*anyopaque = null,
    /// 模型切换 hook(model=null 读):返回当前模型或 null
    model_hook: ?*const fn (ctx: ?*anyopaque, cwd: []const u8, session: []const u8, model: ?[]const u8) ?[]const u8 = null,
    model_ctx: ?*anyopaque = null,
    /// 标题 hook(title=null 读):返回当前标题或 null
    title_hook: ?*const fn (ctx: ?*anyopaque, cwd: []const u8, session: []const u8, title: ?[]const u8) ?[]const u8 = null,
    action_hook: ?*const fn (ctx: ?*anyopaque, cwd: []const u8, session: []const u8, act: []const u8, name: ?[]const u8, count: usize) ?[]const u8 = null,
    title_ctx: ?*anyopaque = null,
    action_ctx: ?*anyopaque = null,
    /// 配置 hook(body=null 读):返回配置 JSON 或 null
    config_hook: ?*const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator, body: ?[]const u8) ?[]const u8 = null,
    config_ctx: ?*anyopaque = null,
    /// 项目 hook(body=null 读):返回 workspaces JSON 或 null
    workspaces_hook: ?*const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator, body: ?[]const u8) ?[]const u8 = null,
    workspaces_ctx: ?*anyopaque = null,
    /// `?ws=` 是否指向已注册项目。
    ///
    /// 没有这道校验时 `ws` 是完全不受约束的:攻击者在任意可写目录伪造
    /// `<ws>/.piz/packages/p/web/...`,一个**不带 token** 的
    /// `GET /api/plugins/assets/p/web/leak?ws=/tmp/x` 就能读出 ~/.piz/models.json
    /// 里的 apiKey(实测复现过);已认证请求还能把 agent 的 cwd 指到 /etc。
    ///
    /// 未接线时一律拒绝非空 ws —— 安全校验缺失要 fail-closed,
    /// 忘记接线只会让功能不可用,不会留下敞口。
    ws_allowed_hook: ?*const fn (ctx: ?*anyopaque, ws: []const u8) bool = null,
    ws_allowed_ctx: ?*anyopaque = null,
    auth_save_hook: ?*const fn (ctx: ?*anyopaque, provider: []const u8, key: []const u8) bool = null,
    auth_save_ctx: ?*anyopaque = null,
    oauth_mu: std.Io.Mutex = .init,
    oauth_slots: [8]OauthPend = [_]OauthPend{.{}} ** 8,
    tcp: net.Server,
    port: u16,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// accept 循环已退出。停机方靠它知道「不用再唤醒了」——
    /// std.Thread.join 没有超时版本,盲等就是永久挂住。
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 在处理中的连接数。每连接一个 OS 线程 + 12KB 栈缓冲,没有上限时
    /// 本机一个循环 connect 就能把线程耗光,agent 随之停摆。
    live_conns: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// 并发连接上限。SSE 长连接占满 MAX_STREAMS(16)后还留足余量给普通请求。
    pub const MAX_CONNS = 64;

    pub fn start(alloc: std.mem.Allocator, opts: WebOptions, hub: *EventHub) !WebServer {
        // 端口:默认 5494-5503 自动试(对齐 kimi web)
        var port: u16 = if (opts.port != 0) opts.port else 5494;
        var tcp: ?net.Server = null;
        while (tcp == null) {
            const addr = net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
            // 先探活再 listen:reuse_address 在 Linux 上连带开 SO_REUSEPORT,
            // 两个实例能同绑一端口、内核轮流分发连接 —— 后启动的 token 在前一个
            // 进程上全部 401,表现为「启动带的 token 进不了 webui」。
            // 试连成功 = 已有监听者:显式端口直接报 PortBusy,自动模式跳下一端口。
            if (net.IpAddress.parseIp4("127.0.0.1", port)) |probe| {
                if (probe.connect(util.io, .{ .mode = .stream })) |s| {
                    var c = s;
                    c.close(util.io);
                    if (opts.port != 0) return error.PortBusy;
                    if (port >= 5503) return error.PortBusy;
                    port += 1;
                    continue;
                } else |_| {}
            } else |_| {}
            tcp = addr.listen(util.io, .{ .reuse_address = true }) catch |err| blk: {
                if (opts.port != 0) return err;
                if (port >= 5503) return err;
                port += 1;
                break :blk null;
            };
        }
        return .{ .alloc = alloc, .opts = opts, .hub = hub, .tcp = tcp.?, .port = port };
    }

    pub fn deinit(self: *WebServer) void {
        self.tcp.deinit(util.io);
    }

    /// accept 循环(阻塞,主线程);每连接 spawn 一个处理线程,上限 MAX_CONNS。
    pub fn run(self: *WebServer) !void {
        defer self.stopped.store(true, .release);
        while (!self.stopping.load(.acquire)) {
            const stream = self.tcp.accept(util.io) catch |err| switch (err) {
                error.Canceled => return,
                // 监听 socket 坏掉(被关、fd 耗尽)时 continue 会变成忙等 spin。
                // 让出一次 CPU 再回到循环条件 —— stopping 已置位就干净退出。
                else => {
                    if (self.stopping.load(.acquire)) return;
                    std.Io.sleep(util.io, .{ .nanoseconds = 5 * std.time.ns_per_ms }, .awake) catch {};
                    continue;
                },
            };
            // 满员就立刻关掉:队列里排着不如让客户端明确失败并退避。
            // 计数在 spawn 前加,避免 accept 快于线程启动时冲过上限。
            if (self.live_conns.fetchAdd(1, .acq_rel) >= MAX_CONNS) {
                _ = self.live_conns.fetchSub(1, .acq_rel);
                var over = stream;
                over.close(util.io);
                continue;
            }
            const th = std.Thread.spawn(.{}, handleConn, .{ self, stream }) catch {
                _ = self.live_conns.fetchSub(1, .acq_rel);
                var failed = stream;
                failed.close(util.io);
                continue;
            };
            th.detach();
        }
    }

    fn handleConn(self: *WebServer, stream: net.Stream) void {
        var copy = stream;
        defer {
            copy.close(util.io);
            _ = self.live_conns.fetchSub(1, .acq_rel);
        }
        // 没有请求头读超时 —— 试过 setsockopt(SO_RCVTIMEO),不能用:
        // std.Io.Threaded 假定所有 fd 都是阻塞的(它自己管调度),超时让 recv
        // 返回 EAGAIN,而 Threaded 把 EAGAIN 当 programmer bug —— Debug 构建
        // 直接 panic(实测),ReleaseFast 下静默转 error.Unexpected。
        //
        // 真要做就得靠看门狗线程 shutdown(fd, SHUT_RD) 把阻塞的 recv 变成
        // 干净的 EOF。没做:服务绑 127.0.0.1,能占住连接的攻击者已经在本机
        // 执行代码,那时他直接读 ~/.piz/models.json 就有 apiKey,占 64 个连接
        // 是他最不划算的选择。MAX_CONNS 已经挡住了线程耗尽。
        var send_buf: [4096]u8 = undefined;
        var recv_buf: [8192]u8 = undefined;
        var cr = stream.reader(util.io, &recv_buf);
        var cw = stream.writer(util.io, &send_buf);
        var server: http.Server = .init(&cr.interface, &cw.interface);
        while (true) {
            var req = server.receiveHead() catch return;
            // HTTP/1.1 要求收到 `Connection: close` 后关闭连接。不关的话客户端
            // 读到 EOF 才停的那类读法(allocRemaining 之类)会永久阻塞 ——
            // 浏览器自己会关所以看不出来,别的客户端就挂住。
            const keep = req.head.keep_alive;
            self.serve(&req, stream.socket.handle) catch |err| {
                util.errLog(self.alloc, "web-http", req.head.target, @errorName(err));
                return;
            };
            if (!keep) return;
        }
    }

    /// `conn_fd` 只给 SSE 用:长连接需要探测对端是否已关闭。
    fn serve(self: *WebServer, req: *http.Server.Request, conn_fd: std.posix.fd_t) !void {
        const target = req.head.target;
        const method = req.head.method;
        const qmark = std.mem.indexOfScalar(u8, target, '?');
        const path = if (qmark) |i| target[0..i] else target;
        // Host 头校验:防御 DNS Rebinding 攻击
        if (!hostOk(self.port, req.head_buffer)) {
            try req.respond("invalid host header", .{ .status = .bad_request });
            return;
        }
        // 静态资源(HTML/JS/CSS)免鉴权(kimi 同:仅 API/WS 需凭证)——否则 splash 无法加载
        const is_static = method == .GET and
            (std.mem.eql(u8, target, "/") or std.mem.startsWith(u8, target, "/?") or
                std.mem.eql(u8, target, "/index.html") or
                std.mem.eql(u8, path, "/app.css") or
                std.mem.eql(u8, path, "/app.js") or
                std.mem.startsWith(u8, target, "/api/plugins/assets/") or
                std.mem.eql(u8, path, "/api/oauth/callback"));
        if (!is_static) {
            const auth_ok = blk: {
                if (self.opts.token) |tok| {
                    // 0.16 Head 无 headers 迭代器;直接在原始 head buffer 里查
                    const pos = std.ascii.indexOfIgnoreCase(req.head_buffer, "authorization:") orelse break :blk false;
                    const rest = req.head_buffer[pos..];
                    const want = std.fmt.allocPrint(self.alloc, "Bearer {s}", .{tok}) catch break :blk false;
                    defer self.alloc.free(want);
                    break :blk std.mem.indexOf(u8, rest, want) != null;
                }
                break :blk true;
            };
            if (!auth_ok) {
                try req.respond("unauthorized", .{ .status = .unauthorized });
                return;
            }
        }
        // 跨源写请求一律拒绝(CSRF 纵深防御)。
        //
        // 绑定 127.0.0.1 只挡远程,挡不住本机浏览器里的恶意页面 —— 它能向
        // localhost 发 POST。默认的随机 token 是第一道防线(存 sessionStorage,
        // 跨源页面读不到),但 --no-token 模式下就没有防线了,而且 token 一旦
        // 因 XSS 或用户误贴 URL 泄漏,Origin 校验是仅剩的一道。
        //
        // 只校验写方法:GET 静态资源必须放行,否则页面加载不了。
        // 无 Origin 头的放行 —— 那是 curl / 原生客户端;浏览器的 fetch 与 form
        // 提交都强制带 Origin,省不掉,所以这条豁免不会被网页利用。
        if (method != .GET and method != .HEAD) {
            if (!originOk(self.port, req.head_buffer)) {
                try req.respond("cross-origin request refused", .{ .status = .forbidden });
                return;
            }
        }
        // 项目根(?ws=;空 = main 侧默认)。
        //
        // 非空的 ws 必须是已注册项目。它决定插件包根与 agent 的 cwd,不校验就等于
        // 让请求方任意指定这两样 —— 实测过一个不带 token 的
        // GET /api/plugins/assets/p/web/leak?ws=/tmp/x 能读出 apiKey。
        // 在这里统一拦掉,所有下游用法(assets/manifest/chat/state/title/action)一次盖住。
        const ws = queryWs(self.alloc, target) catch "";
        defer if (ws.len > 0) self.alloc.free(ws);
        const serve_html = method == .GET and (std.mem.eql(u8, target, "/") or
            std.mem.startsWith(u8, target, "/?") or
            std.mem.eql(u8, target, "/index.html") or
            std.mem.startsWith(u8, target, "/index.html?") or
            std.mem.eql(u8, path, "/api/oauth/callback"));
        if (!serve_html and !wsAllowed(self.ws_allowed_hook, self.ws_allowed_ctx, ws)) {
            try req.respond("unknown workspace", .{ .status = .forbidden });
            return;
        }
        // 路由体在 webui_routes.zig;顺序即原 if-链顺序,先匹配先赢。
        if (method == .GET and (std.mem.eql(u8, target, "/") or std.mem.startsWith(u8, target, "/?") or std.mem.eql(u8, target, "/index.html"))) {
            return routes.indexHtml(self, req);
        }
        if (method == .GET and (std.mem.eql(u8, path, "/app.css") or std.mem.eql(u8, path, "/app.js"))) {
            return routes.staticAsset(self, req, path);
        }
        if (method == .GET and std.mem.startsWith(u8, target, "/api/plugins/assets/")) {
            return routes.pluginsAssets(self, req, target, ws);
        }
        if (method == .GET and std.mem.startsWith(u8, target, "/api/plugins")) {
            return routes.plugins(self, req, ws);
        }
        if (method == .GET and std.mem.startsWith(u8, target, "/api/state")) {
            return routes.stateGet(self, req, target, ws);
        }
        if (method == .GET and std.mem.startsWith(u8, target, "/api/history")) {
            return routes.history(self, req, target, ws);
        }
        if (method == .GET and std.mem.startsWith(u8, target, "/api/sessions")) {
            return routes.sessions(self, req, ws);
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/models")) {
            return routes.models(self, req);
        }
        if (method == .POST and std.mem.eql(u8, path, "/api/activity")) {
            return routes.activityPost(self, req);
        }
        if (method == .POST and std.mem.eql(u8, path, "/api/evolve/sink")) {
            return routes.evolveSink(self, req);
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/evolve/queue")) {
            return routes.evolveQueue(self, req);
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/activity")) {
            return routes.activityGet(self, req);
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/usage")) {
            return routes.usage(self, req);
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/help")) {
            return routes.help(self, req, target, ws);
        }
        if (method == .POST and std.mem.eql(u8, path, "/api/slash")) {
            return routes.slash(self, req, target, ws);
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/packages")) {
            return routes.packages(self, req, ws);
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/config")) {
            return routes.configGet(self, req);
        }
        if (method == .POST and std.mem.startsWith(u8, target, "/api/config")) {
            return routes.configPost(self, req);
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/events")) {
            return self.serveSSE(req, conn_fd);
        }
        if (method == .POST and std.mem.startsWith(u8, target, "/api/chat")) {
            return routes.chatPost(self, req, target, ws);
        }
        if (method == .POST and std.mem.startsWith(u8, target, "/api/interrupt")) {
            return routes.interrupt(self, req, target, ws);
        }
        if (method == .POST and std.mem.eql(u8, path, "/api/approve")) {
            return routes.approve(self, req);
        }
        if (method == .POST and std.mem.startsWith(u8, target, "/api/mode") and !std.mem.startsWith(u8, target, "/api/model")) {
            return routes.modePost(self, req, target, ws);
        }
        if (method == .POST and std.mem.startsWith(u8, target, "/api/model")) {
            return routes.modelPost(self, req, target, ws);
        }
        if (method == .POST and std.mem.startsWith(u8, target, "/api/title")) {
            return routes.titlePost(self, req, target, ws);
        }
        // /api/action?session=&ws= :fork/undo/compact/archive/restore/delete(kimi 式会话动作)
        if (method == .POST and std.mem.startsWith(u8, target, "/api/action")) {
            return routes.action(self, req, target);
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/workspaces")) {
            return routes.workspacesGet(self, req);
        }
        if (method == .POST and std.mem.eql(u8, path, "/api/oauth/start")) {
            return routes.oauthStartRoute(self, req);
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/oauth/callback")) {
            return routes.oauthCallbackRoute(self, req, target);
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/oauth/poll")) {
            return routes.oauthPollRoute(self, req, target);
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/oauth/status")) {
            return routes.oauthStatusRoute(self, req, target);
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/image")) {
            return routes.imageGet(self, req, target);
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/artifact")) {
            return routes.artifact(self, req, target);
        }
        if (method == .GET and (std.mem.eql(u8, path, "/api/files") or std.mem.startsWith(u8, target, "/api/files?"))) {
            return routes.files(self, req, target, ws);
        }
        if (method == .GET and (std.mem.eql(u8, path, "/api/file") or std.mem.startsWith(u8, target, "/api/file?"))) {
            return routes.file(self, req, target, ws);
        }
        if (method == .POST and std.mem.startsWith(u8, target, "/api/workspaces")) {
            return routes.workspacesPost(self, req);
        }

        // 404:手动响应(respond 对无 body POST 断言;此处保持恒稳)
        // 404:手动响应(respond 对无 body POST 断言;此处保持恒稳)
        try req.server.out.writeAll("HTTP/1.1 404 Not Found\r\ncontent-length: 9\r\nconnection: close\r\n\r\nnot found");
        try req.server.out.flush();
    }

    fn jw(comptime where: []const u8, result: anyerror!void) void {
        result catch |err| util.debugCatch(where, err);
    }

    /// /api/state:端口 + 模型 + ctx% + 最近 20 条历史(刷新恢复)。
    pub fn stateJson(self: *WebServer) []const u8 {
        const a = self.alloc;
        var stw = std.Io.Writer.Allocating.init(a);
        defer stw.deinit();
        const w = &stw.writer;
        jw("state.port", w.print("{{\"port\":{d}", .{self.port}));
        if (self.agent) |ag| {
            jw("state.model", w.print(",\"model\":{s}", .{util.jsonString(a, ag.model) catch "\"\""}));
            const cw = ag.ctxWindow();
            const used = ag.estTokens();
            const pct = if (cw > 0) used * 100 / cw else 0;
            jw("state.pct", w.print(",\"pct\":{d}", .{pct}));
            // 历史:最近 20 条(user/assistant/工具摘要),内容截 300
            jw("state.hist", w.writeAll(",\"history\":["));
            const msgs = ag.messages.items;
            const hist_start = if (msgs.len > 20) msgs.len - 20 else 0;
            var first = true;
            var i = hist_start;
            while (i < msgs.len) : (i += 1) {
                const m = &msgs[i];
                if (!first) jw("state.comma", w.writeAll(","));
                first = false;
                const content = if (m.content.len > 300) m.content[0..300] else m.content;
                jw("state.row", w.print("{{\"role\":{s},\"content\":{s}}}", .{ util.jsonString(a, m.role) catch "\"\"", util.jsonString(a, content) catch "\"\"" }));
            }
            jw("state.cb", w.writeAll("]"));
        }
        jw("state.end", w.writeAll("}"));
        return stw.toOwnedSlice() catch "{}";
    }

    /// SSE 长连接:手动原始响应(0.16 BodyWriter.flush 有字节滞留问题),
    /// 头即 flush;轮询转发 hub 事件 + 30s 心跳;上报消费位置供 hub 裁头。
    /// 转发在锁内(事件短、本地回环;锁外转发会与 push 的裁头竞态导致漏事件)。
    /// 结束后连接必须关闭 —— 两条路径都声明了 `connection: close`。
    /// 返回 `error.ConnectionDone` 让 handleConn 走 defer 关掉:承诺了 close
    /// 却继续 receiveHead 的话,客户端永远读不到 EOF,`allocRemaining`
    /// 之类的读法会永久阻塞。
    fn serveSSE(self: *WebServer, req: *http.Server.Request, conn_fd: std.posix.fd_t) !void {
        const out = req.server.out;
        // 必须先抢 slot 再写头:反过来客户端会拿到 200 + 空 event-stream,
        // 和「连上了但还没事件」完全无法区分,只能干等。
        const slot = self.hub.register(std.Io.Clock.now(.real, util.io).nanoseconds) orelse {
            const body = std.fmt.comptimePrint("{{\"error\":\"too many event streams\",\"limit\":{d}}}", .{EventHub.MAX_STREAMS});
            try out.print(
                "HTTP/1.1 503 Service Unavailable\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nretry-after: 5\r\nconnection: close\r\n\r\n{s}",
                .{ body.len, body },
            );
            try out.flush();
            return error.ConnectionDone;
        };
        defer self.hub.unregister(slot);
        try out.print("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncache-control: no-cache\r\nconnection: close\r\n\r\n", .{});
        try out.flush();
        // 新连接从当前尾部开始(state 已承担历史重放;从头重放会与 state 重复渲染)
        var cursor: usize = 0;
        {
            self.hub.mutex.lock(util.io) catch return error.ConnectionDone;
            cursor = self.hub.events.items.len;
            self.hub.mutex.unlock(util.io);
        }
        var idle: usize = 0;
        while (!self.stopping.load(.acquire)) {
            self.hub.mutex.lock(util.io) catch return error.ConnectionDone;
            if (self.hub.conns[slot]) |*st| {
                st.cursor = cursor;
                st.last_seen_ns = std.Io.Clock.now(.real, util.io).nanoseconds;
            }
            // 裁掉所有连接已消费的头部;本连接索引同步平移
            cursor -= self.hub.trimLocked();
            const len = self.hub.events.items.len;
            if (cursor >= len) {
                self.hub.mutex.unlock(util.io);
                // 关标签页不会让写立刻失败(第一次写进内核缓冲就算成功),
                // 靠心跳发现要等两个周期 —— 期间 16 个槽位里的一个白占着。
                // peek 探测在对端 close 后立刻返回 EOF。
                if (util.peerClosed(conn_fd)) return error.ConnectionDone;
                idle += 1;
                if (idle % 150 == 0) { // 30s 心跳
                    try out.writeAll(": ping\n\n");
                    try out.flush();
                }
                std.Io.sleep(util.io, .{ .nanoseconds = 200 * std.time.ns_per_ms }, .awake) catch {};
                continue;
            }
            idle = 0;
            while (cursor < len) {
                try out.print("data: {s}\n\n", .{self.hub.events.items[cursor]});
                cursor += 1;
            }
            if (self.hub.conns[slot]) |*st| st.cursor = cursor;
            self.hub.mutex.unlock(util.io);
            try out.flush();
        }
        // 循环退出(服务停止 / 对端已关)——连接也到此为止
        return error.ConnectionDone;
    }

    /// 打开浏览器(仅本地;失败静默)。--token 时 URL 带 #token= 片段(前端读取后 scrub)。
    pub fn openBrowser(self: *WebServer) void {
        if (self.opts.no_open) return;
        const url = if (self.opts.token) |tok|
            std.fmt.allocPrint(self.alloc, "http://127.0.0.1:{d}/#token={s}", .{ self.port, tok }) catch return
        else
            std.fmt.allocPrint(self.alloc, "http://127.0.0.1:{d}", .{self.port}) catch return;
        defer self.alloc.free(url);
        const cmd = std.fmt.allocPrint(self.alloc, "xdg-open {s} >/dev/null 2>&1 &", .{url}) catch return;
        defer self.alloc.free(cmd);
        var child = std.process.spawn(util.io, .{
            .argv = &.{ "sh", "-c", cmd },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return;
        _ = child.wait(util.io) catch {};
    }
};
/// Origin 是否属于本服务自身。无 Origin 头 = 非浏览器客户端,放行。
///
/// 只认 127.0.0.1 / localhost / [::1] 加本服务实际端口 —— `http://localhost:9999`
/// 是另一个源,不能放过(端口是同源判定的一部分)。
pub fn originOk(port: u16, head: []const u8) bool {
    const pos = std.ascii.indexOfIgnoreCase(head, "origin:") orelse return true;
    var rest = head[pos + "origin:".len ..];
    const eol = std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
    rest = std.mem.trim(u8, rest[0..eol], " \t");
    // 白名单式:只有精确匹配「本机主机名 + 本服务端口」才放行,其余全落到末尾的
    // return false —— 空 Origin、`null`(sandbox iframe / file:// 页面)、
    // 任意外部站点都走这条。不需要为它们单独判断。
    for ([_][]const u8{ "http://127.0.0.1:", "http://localhost:", "http://[::1]:" }) |prefix| {
        if (std.mem.startsWith(u8, rest, prefix)) {
            const port_str = rest[prefix.len..];
            const p = std.fmt.parseInt(u16, port_str, 10) catch continue;
            if (p == port) return true;
        }
    }
    return false;
}

/// Host 是否属于本服务允许的本地目标。防御 DNS Rebinding 攻击。
/// 无 Host 头(如极端 HTTP/1.0 客户端)放行。
/// 仅允许 localhost / 127.0.0.1 / [::1] 及其匹配的端口。
pub fn hostOk(port: u16, head: []const u8) bool {
    const pos = blk: {
        if (std.ascii.startsWithIgnoreCase(head, "host:")) break :blk 0;
        if (std.ascii.indexOfIgnoreCase(head, "\nhost:")) |p| break :blk p + 1;
        return true;
    };
    var rest = head[pos + "host:".len ..];
    const eol = std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
    rest = std.mem.trim(u8, rest[0..eol], " \t");
    if (rest.len == 0) return true;

    for ([_][]const u8{ "127.0.0.1", "localhost", "[::1]" }) |h| {
        if (std.ascii.eqlIgnoreCase(rest, h)) return true;
        if (rest.len > h.len and rest[h.len] == ':' and std.ascii.startsWithIgnoreCase(rest, h)) {
            const port_str = rest[h.len + 1 ..];
            const p = std.fmt.parseInt(u16, port_str, 10) catch continue;
            if (p == port) return true;
        }
    }
    return false;
}

// 路由 helpers 已移 webui_routes.zig;此处为测试留别名。
const queryParam = routes.queryParam;
const queryUsize = routes.queryUsize;
const querySession = routes.querySession;
const queryWs = routes.queryWs;
const okJson = routes.okJson;
const fileJson = routes.fileJson;
const filesJson = routes.filesJson;
const safeArtifactName = routes.safeArtifactName;
const artifactImage = routes.artifactImage;
const artifactJson = routes.artifactJson;
const parseChatBody = routes.parseChatBody;
const parseChatText = routes.parseChatText;
const filesmod = @import("core").tools_files;
const FileItem = filesmod.FileItem;
const listWorkspaceFiles = filesmod.listWorkspaceFiles;
const normalizeRel = filesmod.normalizeRel;

/// 消息队列(server 线程入队,各 session worker 按名消费)。
pub const ChatQueue = struct {
    pub const Item = struct { session: []const u8, text: []const u8, image: ?[]const u8 = null, mime: []const u8 = "" };
    mutex: std.Io.Mutex = .init,
    items: std.array_list.Managed(Item),
    shutting_down: bool = false,

    pub fn enqueue(session: []const u8, text: []const u8) bool {
        return enqueueEx(session, text, null, "");
    }
    pub fn enqueueEx(session: []const u8, text: []const u8, image: ?[]const u8, mime: []const u8) bool {
        // 调用方(HTTP 线程)可能随后 free 入参——入队须 dupe(page_allocator)
        const alloc = std.heap.page_allocator;
        const s_dup = alloc.dupe(u8, session) catch return false;
        const t_dup = alloc.dupe(u8, text) catch {
            alloc.free(s_dup);
            return false;
        };
        const img_dup = if (image) |im| alloc.dupe(u8, im) catch {
            alloc.free(s_dup);
            alloc.free(t_dup);
            return false;
        } else null;
        const mime_dup = if (mime.len > 0) alloc.dupe(u8, mime) catch {
            alloc.free(s_dup);
            alloc.free(t_dup);
            if (img_dup) |im| alloc.free(im);
            return false;
        } else "";
        global.mutex.lock(util.io) catch |err| {
            util.debugCatch("webq.lock", err);
            alloc.free(s_dup);
            alloc.free(t_dup);
            if (img_dup) |im| alloc.free(im);
            if (mime_dup.len > 0) alloc.free(mime_dup);
            return false;
        };
        global.items.append(.{ .session = s_dup, .text = t_dup, .image = img_dup, .mime = mime_dup }) catch {
            alloc.free(s_dup);
            alloc.free(t_dup);
            if (img_dup) |im| alloc.free(im);
            if (mime_dup.len > 0) alloc.free(mime_dup);
            global.mutex.unlock(util.io);
            return false;
        };
        global.mutex.unlock(util.io);
        return true;
    }
    /// 轮询取本 session 消息(100ms);全局 shutdown 或本会话 `stop` 置位后返回 null。
    ///
    /// `stop` 不可省:会话被删除时 worker 必须能退出。只看全局标志的话线程会在
    /// 队列上空转到进程结束 —— 实测建删三轮 3 个会话就留下 9 个空转线程。
    pub fn dequeue(session: []const u8, stop: *std.atomic.Value(bool)) ?Item {
        while (!global.shutting_down and !stop.load(.acquire)) {
            global.mutex.lock(util.io) catch return null;
            for (global.items.items, 0..) |it, i| {
                if (std.mem.eql(u8, it.session, session)) {
                    const item = global.items.orderedRemove(i);
                    global.mutex.unlock(util.io);
                    return item;
                }
            }
            global.mutex.unlock(util.io);
            std.Io.sleep(util.io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
        }
        return null;
    }
    pub fn shutdown() void {
        global.mutex.lock(util.io) catch {};
        global.shutting_down = true;
        global.mutex.unlock(util.io);
    }

    pub fn pending(session: []const u8) usize {
        global.mutex.lock(util.io) catch return 0;
        defer global.mutex.unlock(util.io);
        var n: usize = 0;
        for (global.items.items) |it| {
            if (std.mem.eql(u8, it.session, session)) n += 1;
        }
        return n;
    }

    /// 丢掉本会话还没被 worker 取走的消息,返回清掉的条数。
    pub fn clear(session: []const u8) usize {
        const alloc = std.heap.page_allocator;
        global.mutex.lock(util.io) catch return 0;
        defer global.mutex.unlock(util.io);
        var n: usize = 0;
        var i: usize = 0;
        while (i < global.items.items.len) {
            if (std.mem.eql(u8, global.items.items[i].session, session)) {
                const removed = global.items.orderedRemove(i);
                alloc.free(removed.session);
                alloc.free(removed.text);
                n += 1;
            } else {
                i += 1;
            }
        }
        return n;
    }
};

var global: ChatQueue = .{ .items = std.array_list.Managed(ChatQueue.Item).init(std.heap.page_allocator) };

/// 权限闸:manual 模式下工具请求等待浏览器审批。
/// submit 返回 id;resolve 由 /api/approve 调用;waitResult 轮询(超时 5min → false)。
pub const PermGate = struct {
    pub const Req = struct {
        id: u32,
        name: []const u8,
        args: []const u8,
        granted: bool,
        done: bool,
        created_ns: i128,
    };
    mutex: std.Io.Mutex = .init,
    next_id: u32 = 1,
    reqs: std.array_list.Managed(Req),
    /// true = 自动放行(默认)
    auto_mode: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    pub fn setMode(auto: bool) void {
        global_gate.auto_mode.store(auto, .release);
    }
    pub fn isAuto() bool {
        return global_gate.auto_mode.load(.acquire);
    }

    /// 删除已完成或超龄(>10min)的请求,防止 reqs 无限积累。调用者须已持锁。
    fn pruneLocked(self: *PermGate) void {
        const now = std.Io.Clock.now(.real, util.io).nanoseconds;
        var i: usize = 0;
        while (i < self.reqs.items.len) {
            const r = &self.reqs.items[i];
            if (r.done or now - r.created_ns > 10 * 60 * std.time.ns_per_s) {
                _ = self.reqs.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn submit(name: []const u8, args: []const u8) u32 {
        global_gate.mutex.lock(util.io) catch return 0;
        defer global_gate.mutex.unlock(util.io);
        const id = global_gate.next_id;
        global_gate.next_id += 1;
        global_gate.reqs.append(.{
            .id = id,
            .name = name,
            .args = args,
            .granted = false,
            .done = false,
            .created_ns = std.Io.Clock.now(.real, util.io).nanoseconds,
        }) catch return 0;
        return id;
    }
    pub fn resolve(id: u32, allow: bool) bool {
        global_gate.mutex.lock(util.io) catch return false;
        defer global_gate.mutex.unlock(util.io);
        for (global_gate.reqs.items) |*r| {
            if (r.id == id and !r.done) {
                r.granted = allow;
                r.done = true;
                return true;
            }
        }
        return false;
    }
    /// 轮询等待结果(200ms;5min 超时 → false);完成后即移除请求(防积累)。
    pub fn waitResult(id: u32) bool {
        const deadline = std.Io.Clock.now(.real, util.io).nanoseconds + 300 * std.time.ns_per_s;
        while (std.Io.Clock.now(.real, util.io).nanoseconds < deadline) {
            global_gate.mutex.lock(util.io) catch return false;
            for (global_gate.reqs.items, 0..) |*r, i| {
                if (r.id == id and r.done) {
                    const g = r.granted;
                    _ = global_gate.reqs.swapRemove(i);
                    global_gate.mutex.unlock(util.io);
                    return g;
                }
            }
            global_gate.pruneLocked();
            global_gate.mutex.unlock(util.io);
            std.Io.sleep(util.io, .{ .nanoseconds = 200 * std.time.ns_per_ms }, .awake) catch {};
        }
        return false;
    }
};

var global_gate: PermGate = .{ .reqs = std.array_list.Managed(PermGate.Req).init(std.heap.page_allocator) };

/// 单页 UI(复刻 kimi web:apps/kimi-web,设计令牌对齐 style.css;纯静态内嵌)。
/// 生成:src/webui.html + webui.css + webui.js(独立文件,免 zig 字符串转义)。
pub const INDEX_HTML = @embedFile("webui.html");
pub const APP_CSS = @embedFile("webui.css");
pub const APP_JS = @embedFile("webui.js");

/// 非空 `?ws=` 是否放行。
///
/// 空 ws = 用进程默认项目，一律放行。非空必须过 hook —— **hook 未接线时拒绝**：
/// 安全校验缺失要 fail-closed，忘记接线只会让功能不可用，不会留下敞口。
pub fn wsAllowed(
    hook: ?*const fn (ctx: ?*anyopaque, ws: []const u8) bool,
    ctx: ?*anyopaque,
    ws: []const u8,
) bool {
    if (ws.len == 0) return true;
    const f = hook orelse return false;
    return f(ctx, ws);
}

test {
    // 单测主体在 webui_tests.zig(原 17 测试 + ITest 等);引回以保持 zig test 收集。
    _ = @import("webui_tests.zig");
}
