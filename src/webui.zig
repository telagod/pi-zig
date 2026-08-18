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

const OauthKind = enum { openrouter, xai, openai };
const OauthPend = struct {
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
            self.serve(&req, stream.socket.handle) catch return;
            if (!keep) return;
        }
    }

    /// `conn_fd` 只给 SSE 用:长连接需要探测对端是否已关闭。
    fn serve(self: *WebServer, req: *http.Server.Request, conn_fd: std.posix.fd_t) !void {
        const target = req.head.target;
        const method = req.head.method;
        const qmark = std.mem.indexOfScalar(u8, target, '?');
        const path = if (qmark) |i| target[0..i] else target;
        // 静态资源(HTML/JS/CSS)免鉴权(kimi 同:仅 API/WS 需凭证)——否则 splash 无法加载
        const is_static = method == .GET and
            (std.mem.eql(u8, target, "/") or std.mem.startsWith(u8, target, "/?") or
                std.mem.eql(u8, target, "/index.html") or
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
        if (method == .GET and (std.mem.eql(u8, target, "/") or std.mem.startsWith(u8, target, "/?") or std.mem.eql(u8, target, "/index.html"))) {
            try req.respond(INDEX_HTML, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                    .{ .name = "cache-control", .value = "no-store" },
                },
            });
            return;
        }
        if (method == .GET and std.mem.startsWith(u8, target, "/api/plugins/assets/")) {
            const plugin_cwd = if (ws.len > 0) ws else self.opts.project_cwd;
            if (webplugins.readAsset(self.alloc, plugin_cwd, target) catch null) |asset| {
                defer self.alloc.free(asset.data);
                try req.respond(asset.data, .{
                    .status = .ok,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = asset.content_type },
                        .{ .name = "cache-control", .value = "no-cache" },
                        .{ .name = "x-content-type-options", .value = "nosniff" },
                    },
                });
                return;
            }
            try req.respond("not found", .{ .status = .not_found });
            return;
        }
        if (method == .GET and std.mem.startsWith(u8, target, "/api/plugins")) {
            const plugin_cwd = if (ws.len > 0) ws else self.opts.project_cwd;
            const body = webplugins.manifestJson(self.alloc, plugin_cwd) catch "{\"apiVersion\":1,\"plugins\":[]}";
            defer if (!std.mem.eql(u8, body, "{\"apiVersion\":1,\"plugins\":[]}")) self.alloc.free(body);
            try req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "cache-control", .value = "no-store" },
                },
            });
            return;
        }
        if (method == .GET and std.mem.startsWith(u8, target, "/api/state")) {
            const session = querySession(self.alloc, target) catch "default";
            defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
            const body = if (self.state_hook) |f| f(self.state_ctx, ws, session, self.alloc) else self.stateJson();
            try req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        if (method == .GET and std.mem.startsWith(u8, target, "/api/history")) {
            const session = querySession(self.alloc, target) catch "default";
            defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
            const offset = queryUsize(target, "offset", 0);
            var limit = queryUsize(target, "limit", 80);
            if (limit == 0 or limit > 200) limit = 80;
            const body = if (self.history_hook) |f|
                f(self.history_ctx, ws, session, offset, limit, self.alloc)
            else
                "{\"start\":0,\"total\":0,\"history\":[]}";
            try req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        if (method == .GET and std.mem.startsWith(u8, target, "/api/sessions")) {
            const body = if (self.sessions_hook) |f| f(self.sessions_ctx, ws, self.alloc) else "[]";
            try req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/models")) {
            const body = if (self.models_hook) |f| f(self.models_ctx, self.alloc) else "[]";
            try req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        if (method == .POST and std.mem.eql(u8, path, "/api/activity")) {
            var body_buf: [4096]u8 = undefined;
            const reader = req.readerExpectNone(&body_buf);
            const body = reader.allocRemaining(self.alloc, .limited(4096)) catch "";
            const toolsmod = @import("core").tools;
            var killed = false;
            var pid_n: i32 = 0;
            if (std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{})) |root| {
                if (root == .object) {
                    if (root.object.get("kill")) |kv| {
                        pid_n = switch (kv) {
                            .integer => |i| @intCast(i),
                            .float => |f| @intFromFloat(f),
                            .string => |s| std.fmt.parseInt(i32, s, 10) catch 0,
                            else => 0,
                        };
                        if (pid_n > 0) killed = toolsmod.killTracked(@intCast(pid_n));
                    }
                }
            } else |_| {}
            const out = std.fmt.allocPrint(self.alloc, "{{\"ok\":{s},\"pid\":{d}}}", .{ if (killed) "true" else "false", pid_n }) catch "{\"ok\":false}";
            try req.respond(out, .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
            return;
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/activity")) {
            var aw = std.Io.Writer.Allocating.init(self.alloc);
            activity.writeJson(self.alloc, &aw.writer) catch {
                try req.respond("[]", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                return;
            };
            try req.respond(aw.written(), .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/usage")) {
            const uselog = @import("core").usage_log;
            const sum = uselog.summarize(self.alloc, 8) catch uselog.Summary{};
            const body = std.fmt.allocPrint(self.alloc, "{{\"lines\":{d},\"in\":{d},\"out\":{d},\"usd\":{d:.8},\"tail\":{s}}}", .{
                sum.lines,
                sum.tok_in,
                sum.tok_out,
                sum.usd,
                util.jsonString(self.alloc, sum.tail) catch "\"\"",
            }) catch "{\"lines\":0,\"in\":0,\"out\":0,\"usd\":0,\"tail\":\"\"}";
            try req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/help")) {
            const session = querySession(self.alloc, target) catch "default";
            defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
            var extra_buf: [32]cmd_help.HelpItem = undefined;
            const extra_n = if (self.slash_catalog_hook) |f| f(self.slash_ctx, ws, session, extra_buf[0..]) else 0;
            var aw = std.Io.Writer.Allocating.init(self.alloc);
            cmd_help.writeCatalogJsonExtra(self.alloc, &aw.writer, extra_buf[0..extra_n]) catch {
                try req.respond("{\"commands\":[]}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                return;
            };
            try req.respond(aw.written(), .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        if (method == .POST and std.mem.eql(u8, path, "/api/slash")) {
            const session = querySession(self.alloc, target) catch "default";
            defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
            var body_buf: [1024]u8 = undefined;
            const reader = req.readerExpectNone(&body_buf);
            const body = reader.allocRemaining(self.alloc, .limited(4096)) catch "";
            defer if (body.len > 0) self.alloc.free(body);
            const root = std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{}) catch {
                try req.respond("{\"ok\":false,\"error\":\"bad json\"}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                return;
            };
            const name = if (root == .object) (if (root.object.get("name")) |v| (if (v == .string) v.string else "") else "") else "";
            const args = if (root == .object) (if (root.object.get("args")) |v| (if (v == .string) v.string else "") else "") else "";
            if (name.len == 0 or self.slash_hook == null) {
                try req.respond("{\"ok\":false,\"error\":\"unknown command\"}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                return;
            }
            var aw = std.Io.Writer.Allocating.init(self.alloc);
            if (!self.slash_hook.?(self.slash_ctx, ws, session, name, args, &aw.writer)) {
                try req.respond("{\"ok\":false,\"error\":\"unknown command\"}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                return;
            }
            const text_js = util.jsonString(self.alloc, aw.written()) catch "\"\"";
            const resp = std.fmt.allocPrint(self.alloc, "{{\"ok\":true,\"text\":{s}}}", .{text_js}) catch "{\"ok\":true,\"text\":\"\"}";
            try req.respond(resp, .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
            return;
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/packages")) {
            const cwd = if (ws.len > 0) ws else self.opts.project_cwd;
            var aw = std.Io.Writer.Allocating.init(self.alloc);
            pkgsmod.writeListJson(self.alloc, &aw.writer, cwd) catch {
                try req.respond("{\"user\":[],\"project\":[]}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                return;
            };
            try req.respond(aw.written(), .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/config")) {
            const body = if (self.config_hook) |f| (f(self.config_ctx, self.alloc, null) orelse "{}") else "{}";
            try req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        if (method == .POST and std.mem.startsWith(u8, target, "/api/config")) {
            var body_buf: [16 * 1024]u8 = undefined;
            const reader = req.readerExpectNone(&body_buf);
            const body = reader.allocRemaining(self.alloc, .limited(64 * 1024)) catch "";
            defer if (body.len > 0) self.alloc.free(body);
            if (self.config_hook) |f| {
                const out = f(self.config_ctx, self.alloc, if (body.len > 0) body else null) orelse {
                    try req.respond("{\"ok\":false}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                    return;
                };
                try req.respond(out, .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                return;
            }
            try req.respond("{\"ok\":true}", .{ .status = .ok });
            return;
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/events")) {
            return self.serveSSE(req, conn_fd);
        }
        if (method == .POST and std.mem.startsWith(u8, target, "/api/chat")) {
            const session = querySession(self.alloc, target) catch "default";
            defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
            var body_buf: [16 * 1024]u8 = undefined;
            const reader = req.readerExpectNone(&body_buf);
            const body = reader.allocRemaining(self.alloc, .limited(4 * 1024 * 1024)) catch "";
            defer if (body.len > 0) self.alloc.free(body);
            const chat = parseChatBody(self.alloc, body);
            defer if (chat.text.len > 0) self.alloc.free(chat.text);
            defer if (chat.image) |img| self.alloc.free(img);
            if ((chat.text.len > 0 or chat.image != null) and !self.stopping.load(.acquire)) {
                if (self.chat_hook) |f| {
                    if (!f(self.chat_ctx, ws, session, chat.text, chat.image, chat.mime)) {
                        try req.respond("{\"ok\":false,\"error\":\"rejected\"}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                        return;
                    }
                } else {
                    self.hub.push("{{\"type\":\"user_message\",\"text\":{s},\"has_image\":{s}}}", .{ try util.jsonString(self.alloc, chat.text), if (chat.image != null) "true" else "false" });
                    if (!ChatQueue.enqueueEx(session, chat.text, chat.image, chat.mime)) {
                        try req.respond("{\"ok\":false,\"error\":\"queue failed\"}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                        return;
                    }
                }
            }
            try req.respond("{\"ok\":true}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
            return;
        }
        if (method == .POST and std.mem.startsWith(u8, target, "/api/interrupt")) {
            const session = querySession(self.alloc, target) catch "default";
            defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
            if (self.interrupt_hook) |f| f(self.interrupt_ctx, ws, session);
            // 手动响应:0.16 respond 对无 body 的 POST 断言(transfer_encoding/content_length)
            try req.server.out.writeAll("HTTP/1.1 200 OK\r\ncontent-length: 7\r\nconnection: close\r\n\r\n{\"ok\":true}");
            try req.server.out.flush();
            return;
        }
        if (method == .POST and std.mem.eql(u8, path, "/api/approve")) {
            var body_buf: [1024]u8 = undefined;
            const reader = req.readerExpectNone(&body_buf);
            const body = reader.allocRemaining(self.alloc, .limited(4096)) catch "";
            defer if (body.len > 0) self.alloc.free(body);
            const root = std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{}) catch return;
            var id: u32 = 0;
            var allow = false;
            if (root == .object) {
                if (root.object.get("id")) |v| {
                    if (v == .integer) id = @intCast(v.integer);
                }
                if (root.object.get("allow")) |v| {
                    if (v == .bool) allow = v.bool;
                }
            }
            if (id != 0 and PermGate.resolve(id, allow)) {
                self.hub.push("{{\"type\":\"permission_result\",\"id\":{d},\"allow\":{s}}}", .{ id, if (allow) "true" else "false" });
                try req.respond("{\"ok\":true}", .{ .status = .ok });
                return;
            }
            try req.respond("{\"ok\":false,\"error\":\"unknown or already resolved\"}", .{ .status = .ok });
            return;
        }
        if (method == .POST and std.mem.startsWith(u8, target, "/api/mode") and !std.mem.startsWith(u8, target, "/api/model")) {
            const session = querySession(self.alloc, target) catch "default";
            defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
            var mode: ?[]const u8 = null;
            var body_buf: [256]u8 = undefined;
            const reader = req.readerExpectNone(&body_buf);
            const body = reader.allocRemaining(self.alloc, .limited(1024)) catch "";
            defer if (body.len > 0) self.alloc.free(body);
            if (body.len > 0) {
                const root = std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{}) catch null;
                if (root) |r| {
                    if (r == .object) {
                        if (r.object.get("mode")) |v| {
                            if (v == .string) mode = v.string;
                        } else if (r.object.get("auto")) |v| {
                            if (v == .bool) mode = if (v.bool) "yolo" else "ask";
                        }
                    }
                }
            }
            if (self.mode_hook) |f| {
                const cur = f(self.mode_ctx, ws, session, mode) orelse {
                    try req.respond("{\"ok\":false}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                    return;
                };
                const s = if (std.mem.eql(u8, cur, "yolo"))
                    "{\"ok\":true,\"auto\":true,\"mode\":\"yolo\"}"
                else if (std.mem.eql(u8, cur, "ask"))
                    "{\"ok\":true,\"auto\":false,\"mode\":\"ask\"}"
                else
                    "{\"ok\":true,\"auto\":false,\"mode\":\"read-only\"}";
                try req.respond(s, .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                return;
            }
            try req.respond("{\"ok\":true}", .{ .status = .ok });
            return;
        }
        if (method == .POST and std.mem.startsWith(u8, target, "/api/model")) {
            const session = querySession(self.alloc, target) catch "default";
            defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
            var model: ?[]const u8 = null;
            var body_buf: [256]u8 = undefined;
            const reader = req.readerExpectNone(&body_buf);
            const body = reader.allocRemaining(self.alloc, .limited(1024)) catch "";
            defer if (body.len > 0) self.alloc.free(body);
            if (body.len > 0) {
                const root = std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{}) catch null;
                if (root) |r| {
                    if (r == .object) {
                        if (r.object.get("model")) |v| {
                            if (v == .string) model = v.string;
                        }
                    }
                }
            }
            if (self.model_hook) |f| {
                const cur = f(self.model_ctx, ws, session, model) orelse {
                    try req.respond("{\"ok\":false}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                    return;
                };
                const resp = okJson(self.alloc, "model", cur);
                defer if (resp) |j| self.alloc.free(j);
                try req.respond(resp orelse "{\"ok\":true}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                return;
            }
            try req.respond("{\"ok\":true}", .{ .status = .ok });
            return;
        }
        if (method == .POST and std.mem.startsWith(u8, target, "/api/title")) {
            const session = querySession(self.alloc, target) catch "default";
            defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
            var title: ?[]const u8 = null;
            var body_buf: [256]u8 = undefined;
            const reader = req.readerExpectNone(&body_buf);
            const body = reader.allocRemaining(self.alloc, .limited(1024)) catch "";
            defer if (body.len > 0) self.alloc.free(body);
            if (body.len > 0) {
                const root = std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{}) catch null;
                if (root) |r| {
                    if (r == .object) {
                        if (r.object.get("title")) |v| {
                            // 在最外层入口就裁:hook 之后标题会进内存、落盘,
                            // 再往下每一步都不该见到无界值。
                            if (v == .string) title = util.clampUtf8(v.string, sessionmod.MAX_TITLE_BYTES);
                        }
                    }
                }
            }
            if (self.title_hook) |f| {
                const cur = f(self.title_ctx, ws, session, title) orelse {
                    try req.respond("{\"ok\":false}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                    return;
                };
                // 入口已裁过标题,但读路径拿的是磁盘上的旧值 —— 那可能是限长
                // 之前写进去的,所以响应侧也必须不设长度上限。
                const resp = okJson(self.alloc, "title", cur);
                defer if (resp) |j| self.alloc.free(j);
                try req.respond(resp orelse "{\"ok\":true}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                return;
            }
            try req.respond("{\"ok\":true}", .{ .status = .ok });
            return;
        }
        // /api/action?session=&ws= :fork/undo/compact/archive/restore/delete(kimi 式会话动作)
        if (method == .POST and std.mem.startsWith(u8, target, "/api/action")) {
            const aws = queryWs(self.alloc, target) catch "";
            defer if (aws.len > 0) self.alloc.free(aws);
            const session = querySession(self.alloc, target) catch "";
            if (session.len == 0) {
                try req.respond("{\"ok\":false}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                return;
            }
            var body_buf: [16 * 1024]u8 = undefined;
            const reader = req.readerExpectNone(&body_buf);
            const body = reader.allocRemaining(self.alloc, .limited(64 * 1024)) catch "";
            defer if (body.len > 0) self.alloc.free(body);
            var act: []const u8 = "";
            var name: ?[]const u8 = null;
            var count: usize = 0;
            if (std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{})) |root| {
                if (root == .object) {
                    if (root.object.get("act")) |v| {
                        if (v == .string) act = v.string;
                    }
                    if (root.object.get("name")) |v| {
                        if (v == .string) name = v.string;
                    }
                    if (root.object.get("count")) |v| {
                        if (v == .integer and v.integer > 0) count = @intCast(v.integer);
                    }
                }
            } else |_| {}
            if (self.action_hook) |f| {
                const out = f(self.action_ctx, aws, session, act, name, count) orelse {
                    try req.respond("{\"ok\":false}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                    return;
                };
                try req.respond(out, .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                return;
            }
            try req.respond("{\"ok\":false}", .{ .status = .ok });
            return;
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/workspaces")) {
            const body = if (self.workspaces_hook) |f| (f(self.workspaces_ctx, self.alloc, null) orelse "[]") else "[]";
            try req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        if (method == .POST and std.mem.eql(u8, path, "/api/oauth/start")) {
            var body_buf: [4096]u8 = undefined;
            const reader = req.readerExpectNone(&body_buf);
            const body = reader.allocRemaining(self.alloc, .limited(4096)) catch "";
            const out = oauthStart(self, body);
            try req.respond(out, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/oauth/callback")) {
            const html = oauthCallback(self, target);
            try req.respond(html, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
            });
            return;
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/oauth/poll")) {
            const st = queryParam(target, "state") orelse "";
            const out = oauthPoll(self, st);
            try req.respond(out, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/oauth/status")) {
            const st = queryParam(target, "state") orelse "";
            const out = oauthStatus(self, st);
            try req.respond(out, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/image")) {
            const raw = queryParam(target, "name") orelse "";
            const name = if (raw.len == 0) "" else (util.percentDecode(self.alloc, raw) catch raw);
            if (artifactImage(self.alloc, name)) |img| {
                try req.respond(img.data, .{
                    .status = .ok,
                    .extra_headers = &.{ .{ .name = "content-type", .value = img.mime }, .{ .name = "cache-control", .value = "private, max-age=86400" } },
                });
            } else {
                try req.respond("{\"ok\":false}", .{ .status = .not_found, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
            }
            return;
        }
        if (method == .GET and std.mem.eql(u8, path, "/api/artifact")) {
            const raw = queryParam(target, "name") orelse "";
            const name = if (raw.len == 0) "" else (util.percentDecode(self.alloc, raw) catch raw);
            const body = artifactJson(self.alloc, name) orelse "{\"ok\":false,\"error\":\"not found\"}";
            try req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        if (method == .GET and (std.mem.eql(u8, path, "/api/files") or std.mem.startsWith(u8, target, "/api/files?"))) {
            const q_raw = queryParam(target, "q") orelse "";
            const q = if (q_raw.len == 0) "" else (util.percentDecode(self.alloc, q_raw) catch q_raw);
            const root = if (ws.len > 0) ws else ".";
            const body = filesJson(self.alloc, root, q) orelse "{\"ok\":false,\"error\":\"bad path\"}";
            try req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        if (method == .GET and (std.mem.eql(u8, path, "/api/file") or std.mem.startsWith(u8, target, "/api/file?"))) {
            const p_raw = queryParam(target, "path") orelse "";
            const pth = if (p_raw.len == 0) "" else (util.percentDecode(self.alloc, p_raw) catch p_raw);
            const root = if (ws.len > 0) ws else ".";
            const body = fileJson(self.alloc, root, pth) orelse "{\"ok\":false,\"error\":\"bad path\"}";
            try req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        if (method == .POST and std.mem.startsWith(u8, target, "/api/workspaces")) {
            var body_buf: [16 * 1024]u8 = undefined;
            const reader = req.readerExpectNone(&body_buf);
            const body = reader.allocRemaining(self.alloc, .limited(64 * 1024)) catch "";
            defer if (body.len > 0) self.alloc.free(body);
            if (self.workspaces_hook) |f| {
                const out = f(self.workspaces_ctx, self.alloc, if (body.len > 0) body else null) orelse {
                    try req.respond("{\"ok\":false}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                    return;
                };
                try req.respond(out, .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                return;
            }
            try req.respond("{\"ok\":true}", .{ .status = .ok });
            return;
        }
        // 404:手动响应(respond 对无 body POST 断言;此处保持恒稳)
        try req.server.out.writeAll("HTTP/1.1 404 Not Found\r\ncontent-length: 9\r\nconnection: close\r\n\r\nnot found");
        try req.server.out.flush();
    }

    fn jw(comptime where: []const u8, result: anyerror!void) void {
        result catch |err| util.debugCatch(where, err);
    }

    /// /api/state:端口 + 模型 + ctx% + 最近 20 条历史(刷新恢复)。
    fn stateJson(self: *WebServer) []const u8 {
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
fn originOk(port: u16, head: []const u8) bool {
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

test "cross-origin write requests are refused" {
    const t = std.testing;
    const PORT: u16 = 5494;

    // 非浏览器客户端不带 Origin —— 放行。浏览器的 fetch/form 强制带 Origin,
    // 省不掉,所以这条豁免不会被恶意网页利用。
    try t.expect(originOk(PORT, "POST /api/chat HTTP/1.1\r\nhost: x\r\n\r\n"));

    // 本服务自身的页面
    try t.expect(originOk(PORT, "POST / HTTP/1.1\r\norigin: http://127.0.0.1:5494\r\n\r\n"));
    try t.expect(originOk(PORT, "POST / HTTP/1.1\r\norigin: http://localhost:5494\r\n\r\n"));
    try t.expect(originOk(PORT, "POST / HTTP/1.1\r\nOrigin: http://[::1]:5494\r\n\r\n"));

    // 恶意站点
    try t.expect(!originOk(PORT, "POST / HTTP/1.1\r\norigin: https://evil.example.com\r\n\r\n"));
    // 端口是同源判定的一部分 —— 另一个本地端口是另一个源
    try t.expect(!originOk(PORT, "POST / HTTP/1.1\r\norigin: http://localhost:9999\r\n\r\n"));
    // sandbox iframe / file:// 页面
    try t.expect(!originOk(PORT, "POST / HTTP/1.1\r\norigin: null\r\n\r\n"));
    // 前缀相同但主机不同:evil.com 上的 127.0.0.1.evil.com 之类
    try t.expect(!originOk(PORT, "POST / HTTP/1.1\r\norigin: http://127.0.0.1.evil.com\r\n\r\n"));
    // 端口后面挂垃圾,不能被 parseInt 放过
    try t.expect(!originOk(PORT, "POST / HTTP/1.1\r\norigin: http://127.0.0.1:5494.evil.com\r\n\r\n"));
}

test "parseChatText extracts text field" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s1 = try parseChatText(a, "{\"text\":\"hello\"}");
    try t.expectEqualStrings("hello", s1);
    const s2 = try parseChatText(a, "{}");
    try t.expectEqualStrings("", s2);
    const s3 = try parseChatText(a, "not json");
    try t.expectEqualStrings("", s3);
    const s4 = try parseChatText(a, "{\"text\":\"中文&转义\"}");
    const b64 = "aGVsbG8="; // hello
    const body = try std.fmt.allocPrint(a, "{{\"text\":\"hi\",\"image\":\"{s}\",\"mime\":\"image/png\"}}", .{b64});
    const chat = parseChatBody(a, body);
    try t.expectEqualStrings("hi", chat.text);
    try t.expectEqualStrings("image/png", chat.mime);
    try t.expect(chat.image != null);
    try t.expectEqualStrings("hello", chat.image.?);
    try t.expectEqualStrings("中文&转义", s4);
}

/// 按 `&` 切分取查询参数原始值。
///
/// 不能用 `indexOf(rest, "ws=")` —— 那会把 `?foo=1&notws=/etc` 里的 `notws=`
/// 当成 `ws=`。参数名必须是完整的一段,否则任何以目标名结尾的参数都能顶替它,
/// 白名单校验也就跟着被绕过。
fn queryParam(target: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

fn queryUsize(target: []const u8, key: []const u8, fallback: usize) usize {
    const raw = queryParam(target, key) orelse return fallback;
    return std.fmt.parseInt(usize, raw, 10) catch fallback;
}

/// 从 target 提取 ?session= 参数(无则 "default")。
fn querySession(alloc: std.mem.Allocator, target: []const u8) ![]const u8 {
    if (queryParam(target, "session")) |name| {
        if (name.len > 0 and name.len <= 64) return alloc.dupe(u8, name);
    }
    return alloc.dupe(u8, "default");
}

/// 从 target 提取 ?ws= 参数(项目根,percent 解码;无则 "" = 用默认)。
fn queryWs(alloc: std.mem.Allocator, target: []const u8) ![]const u8 {
    if (queryParam(target, "ws")) |name| {
        if (name.len > 0 and name.len <= 512) return util.percentDecode(alloc, name) catch alloc.dupe(u8, name) catch "";
    }
    return "";
}

const filesmod = @import("core").tools_files;
const FileItem = filesmod.FileItem;
const listWorkspaceFiles = filesmod.listWorkspaceFiles;
const normalizeRel = filesmod.normalizeRel;

fn fileJson(alloc: std.mem.Allocator, root: []const u8, raw: []const u8) ?[]u8 {
    if (raw.len == 0 or raw.len > 1024) return null;
    const rel = blk: {
        if (std.fs.path.isAbsolute(raw)) {
            if (!std.mem.startsWith(u8, raw, root)) return null;
            var rest = raw[root.len..];
            if (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) rest = rest[1..];
            const n = normalizeRel(alloc, rest) catch return null;
            break :blk n.rel;
        }
        const n = normalizeRel(alloc, raw) catch return null;
        break :blk n.rel;
    };
    if (rel.len == 0) return null;
    const abs = util.joinPath(alloc, root, rel) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(util.io, abs, alloc, .limited(256 * 1024)) catch return null;
    const path_j = util.jsonString(alloc, rel) catch return null;
    const text_j = util.jsonString(alloc, data) catch return null;
    return std.fmt.allocPrint(alloc, "{{\"ok\":true,\"path\":{s},\"text\":{s}}}", .{ path_j, text_j }) catch null;
}

fn filesJson(alloc: std.mem.Allocator, root: []const u8, q: []const u8) ?[]u8 {
    const items = listWorkspaceFiles(alloc, root, q) catch return null;
    var stw = std.Io.Writer.Allocating.init(alloc);
    const w = &stw.writer;
    w.writeAll("{\"ok\":true,\"items\":[") catch return null;
    for (items, 0..) |it, i| {
        if (i > 0) w.writeAll(",") catch return null;
        const name_j = util.jsonString(alloc, it.name) catch return null;
        const path_j = util.jsonString(alloc, it.path) catch return null;
        if (it.link) |tgt| {
            const link_j = util.jsonString(alloc, tgt) catch return null;
            w.print("{{\"name\":{s},\"path\":{s},\"dir\":{s},\"link\":{s}}}", .{
                name_j,
                path_j,
                if (it.dir) "true" else "false",
                link_j,
            }) catch return null;
        } else {
            w.print("{{\"name\":{s},\"path\":{s},\"dir\":{s}}}", .{
                name_j,
                path_j,
                if (it.dir) "true" else "false",
            }) catch return null;
        }
    }
    w.writeAll("]}") catch return null;
    return stw.toOwnedSlice() catch null;
}

fn safeArtifactName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

fn artifactImage(alloc: std.mem.Allocator, name: []const u8) ?struct { data: []const u8, mime: []const u8 } {
    if (!safeArtifactName(name)) return null;
    if (!std.mem.startsWith(u8, name, "img-")) return null;
    const cfg = util.configDir(alloc) catch return null;
    const dir = util.joinPath(alloc, cfg, "artifacts") catch return null;
    const path = util.joinPath(alloc, dir, name) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(8 * 1024 * 1024)) catch return null;
    const mime: []const u8 = if (std.mem.endsWith(u8, name, ".jpg") or std.mem.endsWith(u8, name, ".jpeg"))
        "image/jpeg"
    else if (std.mem.endsWith(u8, name, ".webp"))
        "image/webp"
    else
        "image/png";
    return .{ .data = data, .mime = mime };
}

fn artifactJson(alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (!safeArtifactName(name)) return null;
    const cfg = util.configDir(alloc) catch return null;
    const dir = util.joinPath(alloc, cfg, "artifacts") catch return null;
    const path = util.joinPath(alloc, dir, name) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(256 * 1024)) catch return null;
    const text_j = util.jsonString(alloc, util.utf8Prefix(data, data.len)) catch return null;
    return std.fmt.allocPrint(alloc, "{{\"ok\":true,\"name\":{s},\"bytes\":{d},\"text\":{s}}}", .{
        util.jsonString(alloc, name) catch "\"\"",
        data.len,
        text_j,
    }) catch null;
}

fn oauthStart(self: *WebServer, body: []const u8) []const u8 {
    const provider = blk: {
        const root = std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{}) catch break :blk "openrouter";
        if (root == .object) {
            if (root.object.get("provider")) |v| {
                if (v == .string) break :blk v.string;
            }
        }
        break :blk "openrouter";
    };
    var kind: OauthKind = .openrouter;
    if (std.mem.eql(u8, provider, "xai")) kind = .xai else if (std.mem.eql(u8, provider, "openai") or std.mem.eql(u8, provider, "codex")) kind = .openai else if (!std.mem.eql(u8, provider, "openrouter")) return "{\"ok\":false,\"error\":\"unsupported\"}";
    var state_buf: [32]u8 = undefined;
    const state = oauth.randomState(&state_buf);
    var pkce: oauth.Pkce = undefined;
    var user_code: []const u8 = "";
    var verify_url: []const u8 = "";
    var device: []const u8 = "";
    if (kind == .openrouter) {
        pkce = oauth.generatePkce();
    } else if (kind == .xai) {
        const d = oauth.xaiStart(self.alloc) catch return "{\"ok\":false,\"error\":\"device\"}";
        user_code = d.user_code;
        verify_url = d.verify_url;
        device = d.device;
    } else {
        const d = oauth.codexStart(self.alloc) catch return "{\"ok\":false,\"error\":\"device\"}";
        user_code = d.user_code;
        verify_url = d.verify_url;
        device = d.device;
    }
    self.oauth_mu.lockUncancelable(util.io);
    defer self.oauth_mu.unlock(util.io);
    var slot: ?*OauthPend = null;
    for (&self.oauth_slots) |*s| {
        if (!s.live or s.done) {
            slot = s;
            break;
        }
    }
    const dest = slot orelse return "{\"ok\":false,\"error\":\"busy\"}";
    dest.* = .{ .live = true, .kind = kind };
    @memcpy(dest.state[0..state.len], state);
    dest.state_n = @intCast(state.len);
    if (kind == .openrouter) dest.verifier = pkce.verifier;
    if (device.len > 0 and device.len <= dest.device.len) {
        @memcpy(dest.device[0..device.len], device);
        dest.device_n = @intCast(device.len);
    }
    const st_j = util.jsonString(self.alloc, state) catch return "{\"ok\":false}";
    if (kind == .openrouter) {
        const cb = std.fmt.allocPrint(self.alloc, "http://127.0.0.1:{d}/api/oauth/callback", .{self.port}) catch return "{\"ok\":false}";
        const url = oauth.openrouterAuthUrl(self.alloc, cb, &pkce.challenge) catch return "{\"ok\":false}";
        const url_j = util.jsonString(self.alloc, url) catch return "{\"ok\":false}";
        return std.fmt.allocPrint(self.alloc, "{{\"ok\":true,\"url\":{s},\"state\":{s}}}", .{ url_j, st_j }) catch "{\"ok\":false}";
    }
    const code_j = util.jsonString(self.alloc, user_code) catch return "{\"ok\":false}";
    const uri_j = util.jsonString(self.alloc, verify_url) catch return "{\"ok\":false}";
    return std.fmt.allocPrint(self.alloc, "{{\"ok\":true,\"state\":{s},\"user_code\":{s},\"verification_uri\":{s}}}", .{ st_j, code_j, uri_j }) catch "{\"ok\":false}";
}

fn oauthPoll(self: *WebServer, state: []const u8) []const u8 {
    const st = if (state.len == 0) return "{\"ok\":false}" else (util.percentDecode(self.alloc, state) catch state);
    self.oauth_mu.lockUncancelable(util.io);
    var found: ?*OauthPend = null;
    for (&self.oauth_slots) |*s| {
        if (s.live and s.state_n > 0 and std.mem.eql(u8, s.state[0..s.state_n], st)) {
            found = s;
            break;
        }
    }
    const slot = found orelse {
        self.oauth_mu.unlock(util.io);
        return "{\"ok\":false,\"done\":true,\"error\":true}";
    };
    if (slot.done) {
        const err = slot.err;
        self.oauth_mu.unlock(util.io);
        return if (err) "{\"ok\":false,\"done\":true,\"error\":true}" else "{\"ok\":true,\"done\":true}";
    }
    if (slot.kind == .openrouter) {
        self.oauth_mu.unlock(util.io);
        return "{\"ok\":true,\"done\":false}";
    }
    const kind = slot.kind;
    const device = slot.device[0..slot.device_n];
    const dev_copy = self.alloc.dupe(u8, device) catch {
        self.oauth_mu.unlock(util.io);
        return "{\"ok\":false}";
    };
    self.oauth_mu.unlock(util.io);
    const polled = if (kind == .xai) oauth.xaiPoll(self.alloc, dev_copy) else oauth.codexPoll(self.alloc, dev_copy);
    const result = polled catch return "{\"ok\":true,\"done\":false}";
    if (result.status == .pending) return "{\"ok\":true,\"done\":false}";
    var saved = false;
    if (result.status == .done) {
        if (result.access) |tok| {
            const name: []const u8 = if (kind == .xai) "xai" else "openai";
            if (self.auth_save_hook) |h| saved = h(self.auth_save_ctx, name, tok);
        }
    }
    self.oauth_mu.lockUncancelable(util.io);
    slot.done = true;
    slot.err = !saved;
    self.oauth_mu.unlock(util.io);
    if (saved) return "{\"ok\":true,\"done\":true}";
    return "{\"ok\":false,\"done\":true,\"error\":true}";
}

fn oauthCallback(self: *WebServer, target: []const u8) []const u8 {
    const fail = "<html><body><p>Sign-in failed. You can close this tab.</p></body></html>";
    const ok_html = "<html><body><p>Signed in. You can close this tab.</p><script>window.close()</script></body></html>";
    const state = queryParam(target, "state") orelse return fail;
    const code = queryParam(target, "code") orelse return fail;
    const st = util.percentDecode(self.alloc, state) catch state;
    const cd = util.percentDecode(self.alloc, code) catch code;
    self.oauth_mu.lockUncancelable(util.io);
    var found: ?*OauthPend = null;
    for (&self.oauth_slots) |*s| {
        if (s.live and s.state_n > 0 and std.mem.eql(u8, s.state[0..s.state_n], st)) {
            found = s;
            break;
        }
    }
    const slot = found orelse {
        self.oauth_mu.unlock(util.io);
        return fail;
    };
    const verifier = slot.verifier;
    self.oauth_mu.unlock(util.io);
    const key = oauth.exchangeOpenrouter(self.alloc, cd, &verifier) catch {
        self.oauth_mu.lockUncancelable(util.io);
        slot.err = true;
        slot.done = true;
        self.oauth_mu.unlock(util.io);
        return fail;
    };
    var saved = false;
    if (self.auth_save_hook) |h| saved = h(self.auth_save_ctx, "openrouter", key);
    self.oauth_mu.lockUncancelable(util.io);
    slot.done = true;
    slot.err = !saved;
    self.oauth_mu.unlock(util.io);
    return if (saved) ok_html else fail;
}

fn oauthStatus(self: *WebServer, state: []const u8) []const u8 {
    const st = if (state.len == 0) return "{\"ok\":false}" else (util.percentDecode(self.alloc, state) catch state);
    self.oauth_mu.lockUncancelable(util.io);
    defer self.oauth_mu.unlock(util.io);
    for (&self.oauth_slots) |*s| {
        if (s.state_n > 0 and std.mem.eql(u8, s.state[0..s.state_n], st)) {
            if (s.err) return "{\"ok\":false,\"done\":true,\"error\":true}";
            if (s.done) return "{\"ok\":true,\"done\":true}";
            return "{\"ok\":true,\"done\":false}";
        }
    }
    return "{\"ok\":false,\"done\":true,\"error\":true}";
}

const ChatBody = struct { text: []const u8, image: ?[]const u8 = null, mime: []const u8 = "" };

fn decodeB64(alloc: std.mem.Allocator, s: []const u8) ?[]u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(s) catch return null;
    if (n == 0 or n > 6 * 1024 * 1024) return null;
    const out = alloc.alloc(u8, n) catch return null;
    dec.decode(out, s) catch {
        alloc.free(out);
        return null;
    };
    return out;
}

fn parseChatBody(alloc: std.mem.Allocator, body: []const u8) ChatBody {
    const empty = ChatBody{ .text = alloc.dupe(u8, "") catch "" };
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{}) catch return empty;
    if (root != .object) return empty;
    var text: []const u8 = "";
    if (root.object.get("text")) |v| {
        if (v == .string) text = alloc.dupe(u8, v.string) catch "";
    }
    var image: ?[]u8 = null;
    var mime: []const u8 = "image/png";
    if (root.object.get("image")) |v| {
        if (v == .string and v.string.len > 0) image = decodeB64(alloc, v.string);
    }
    if (root.object.get("mime")) |v| {
        if (v == .string and v.string.len > 0) mime = v.string;
    }
    return .{ .text = text, .image = image, .mime = mime };
}

fn parseChatText(alloc: std.mem.Allocator, body: []const u8) ![]const u8 {
    return parseChatBody(alloc, body).text;
}

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

test "dequeue returns on per-session stop, not just global shutdown" {
    const t = std.testing;
    try util.testInit();

    // stop 已置位:必须立刻返回 null,不能进 100ms 轮询循环。
    // 没有这条,会话删除后 worker 会在队列上空转到进程结束 ——
    // 实测 24 个会话建删留下 26 个空转线程。
    var stop = std.atomic.Value(bool).init(true);
    const t0 = std.Io.Clock.now(.real, util.io).nanoseconds;
    try t.expect(ChatQueue.dequeue("no-such-session", &stop) == null);
    const spent = std.Io.Clock.now(.real, util.io).nanoseconds - t0;
    try t.expect(spent < 50 * std.time.ns_per_ms);

    // 队列里有本会话的消息时,stop 置位也照样先返回 null ——
    // 已删除的会话不该再消费消息(否则和重建的同名会话抢队列)
    try t.expect(ChatQueue.enqueue("stopped-session", "pending"));
    try t.expect(ChatQueue.dequeue("stopped-session", &stop) == null);

    // stop 未置位时正常取到
    var go = std.atomic.Value(bool).init(false);
    const item = ChatQueue.dequeue("stopped-session", &go);
    try t.expect(item != null);
    try t.expectEqualStrings("pending", item.?.text);
}

test "ChatQueue pending and clear only touch one session" {
    const t = std.testing;
    try util.testInit();
    try t.expect(ChatQueue.enqueue("q-a", "one"));
    try t.expect(ChatQueue.enqueue("q-b", "other"));
    try t.expect(ChatQueue.enqueue("q-a", "two"));
    try t.expectEqual(@as(usize, 2), ChatQueue.pending("q-a"));
    try t.expectEqual(@as(usize, 1), ChatQueue.pending("q-b"));
    try t.expectEqual(@as(usize, 2), ChatQueue.clear("q-a"));
    try t.expectEqual(@as(usize, 0), ChatQueue.pending("q-a"));
    try t.expectEqual(@as(usize, 1), ChatQueue.pending("q-b"));
    try t.expectEqual(@as(usize, 1), ChatQueue.clear("q-b"));
    try t.expectEqual(@as(usize, 0), ChatQueue.pending("q-b"));
}

// ---------- HTTP 层集成测试 ----------
// 上面那些测试都是纯函数级的。真实的 HTTP 行为(状态码、响应头、拒绝时机)
// 只有起真服务打真请求才能验证 —— 之前这一层完全靠手工 curl。

const ITest = struct {
    srv: *WebServer,
    hub: *EventHub,
    thread: std.Thread,
    port: u16,
    alloc: std.mem.Allocator,

    /// `first_port` 只是起点:被占用就往上找。固定端口会在并行跑、
    /// CI、或上一次跑留下残留进程时撞车。
    fn start(alloc: std.mem.Allocator, first_port: u16, hooks: struct {
        title: ?*const fn (ctx: ?*anyopaque, cwd: []const u8, session: []const u8, title: ?[]const u8) ?[]const u8 = null,
        ws_allowed: ?*const fn (ctx: ?*anyopaque, ws: []const u8) bool = null,
        ws_allowed_ctx: ?*anyopaque = null,
    }) !ITest {
        const hub = try alloc.create(EventHub);
        hub.* = EventHub.init(alloc);
        const srv = try alloc.create(WebServer);
        var port = first_port;
        srv.* = while (port < first_port + 40) : (port += 1) {
            break WebServer.start(alloc, .{ .port = port, .no_open = true, .token = null }, hub) catch continue;
        } else return error.NoFreePort;
        srv.title_hook = hooks.title;
        srv.ws_allowed_hook = hooks.ws_allowed;
        srv.ws_allowed_ctx = hooks.ws_allowed_ctx;
        const th = try std.Thread.spawn(.{}, runServer, .{srv});
        return .{ .srv = srv, .hub = hub, .thread = th, .port = srv.port, .alloc = alloc };
    }

    fn runServer(srv: *WebServer) void {
        srv.run() catch |err| util.warn("web server stopped: {s}", .{@errorName(err)});
    }

    fn stop(self: *ITest) void {
        self.srv.stopping.store(true, .release);
        // 先让连接线程收摊:SSE 循环看到 stopping 就退,最多一个轮询周期。
        // 放在 join 之前,这样它们不会在 hub.deinit 之后再碰锁。
        var spins: usize = 0;
        while (self.srv.live_conns.load(.acquire) > 0 and spins < 300) : (spins += 1) {
            std.Io.sleep(util.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch break;
        }
        // accept 阻塞在 listen socket 上,必须来一次连接才让它回到循环条件。
        // 一次不够就再来 —— join 没有超时版本,唤醒失败就是永久挂住,
        // 而挂住的进程会占着测试端口,让后续每一次跑都受影响(踩过)。
        var tries: usize = 0;
        while (tries < 50) : (tries += 1) {
            if (self.srv.stopped.load(.acquire)) break;
            if (net.IpAddress.parseIp4("127.0.0.1", self.port)) |addr| {
                if (addr.connect(util.io, .{ .mode = .stream })) |s| {
                    var c = s;
                    c.close(util.io);
                } else |_| {}
            } else |_| {}
            std.Io.sleep(util.io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch break;
        }
        self.thread.join();
        self.srv.deinit();
        self.hub.deinit();
        self.alloc.destroy(self.srv);
        self.alloc.destroy(self.hub);
    }

    /// 发一个原始请求,返回完整响应文本(调用方 free)。
    fn request(self: *ITest, raw: []const u8) ![]u8 {
        const addr = try net.IpAddress.parseIp4("127.0.0.1", self.port);
        var s = try addr.connect(util.io, .{ .mode = .stream });
        defer s.close(util.io);
        var wbuf: [4096]u8 = undefined;
        var w = s.writer(util.io, &wbuf);
        try w.interface.writeAll(raw);
        try w.interface.flush();
        var rbuf: [8192]u8 = undefined;
        var r = s.reader(util.io, &rbuf);
        // 读到对端关闭或缓冲满;SSE 不会关,所以只在明确期待完整响应时用
        return r.interface.allocRemaining(self.alloc, .limited(1024 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => try self.alloc.dupe(u8, r.interface.buffered()),
            else => return err,
        };
    }

    /// 只读到响应头(SSE 这类不关闭的连接用)。返回持有的连接,调用方负责关。
    fn openStream(self: *ITest, raw: []const u8) !net.Stream {
        const addr = try net.IpAddress.parseIp4("127.0.0.1", self.port);
        var s = try addr.connect(util.io, .{ .mode = .stream });
        var wbuf: [1024]u8 = undefined;
        var w = s.writer(util.io, &wbuf);
        w.interface.writeAll(raw) catch {};
        w.interface.flush() catch {};
        return s;
    }

    fn statusOf(resp: []const u8) []const u8 {
        const eol = std.mem.indexOfAny(u8, resp, "\r\n") orelse resp.len;
        return resp[0..eol];
    }
};

test "http: SSE stream limit answers 503 before writing any 200" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var it = try ITest.start(a, 18631, .{});
    defer it.stop();

    // 占满全部槽位
    var held: [EventHub.MAX_STREAMS]net.Stream = undefined;
    for (&held) |*s| {
        s.* = try it.openStream("GET /api/events HTTP/1.1\r\nhost: x\r\naccept: text/event-stream\r\n\r\n");
    }
    defer for (&held) |*s| s.close(util.io);
    // 等服务端把它们都注册上(每连接一个线程,注册不是同步的)
    var waited: usize = 0;
    while (waited < 200) : (waited += 1) {
        it.hub.mutex.lock(util.io) catch break;
        var n: usize = 0;
        for (&it.hub.conns) |c| {
            if (c != null) n += 1;
        }
        it.hub.mutex.unlock(util.io);
        if (n == EventHub.MAX_STREAMS) break;
        std.Io.sleep(util.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
    }

    // 第 17 个:必须是 503 且带明确原因。旧实现先写 200 头再 register,
    // 满员时直接关流 —— 客户端拿到的 200 空流和「还没事件」无法区分。
    const resp = try it.request("GET /api/events HTTP/1.1\r\nhost: x\r\naccept: text/event-stream\r\n\r\n");
    try t.expect(std.mem.indexOf(u8, ITest.statusOf(resp), "503") != null);
    try t.expect(std.mem.indexOf(u8, resp, "too many event streams") != null);
    try t.expect(std.mem.indexOf(u8, resp, "retry-after") != null);
    // 不能同时出现 200 —— 那说明头写在拒绝之前
    try t.expect(std.mem.indexOf(u8, resp, "200 OK") == null);
}

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

var itest_title_buf: [1024]u8 = undefined;
var itest_title_len: usize = 0;

/// 最小 title hook:存住写入值,读时返回。够验证 HTTP 层的行为。
fn itestTitleHook(_: ?*anyopaque, _: []const u8, _: []const u8, title: ?[]const u8) ?[]const u8 {
    if (title) |tt| {
        const n = @min(tt.len, itest_title_buf.len);
        @memcpy(itest_title_buf[0..n], tt[0..n]);
        itest_title_len = n;
    }
    return itest_title_buf[0..itest_title_len];
}

test "http: an over-long title still gets a complete response" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    itest_title_len = 0;
    var it = try ITest.start(a, 18632, .{ .title = itestTitleHook });
    defer it.stop();

    // 600 字符标题。旧实现用 512 字节栈缓冲拼响应,NoSpaceLeft 冒出 handler,
    // 响应头都没写出去 —— 客户端只看到连接断开,而且读路径走同一段代码,
    // 这个端点在进程余生里每次都断连。
    const long = "L" ** 600;
    const body = try std.fmt.allocPrint(a, "{{\"title\":\"{s}\"}}", .{long});
    const req = try std.fmt.allocPrint(
        a,
        "POST /api/title?session=default HTTP/1.1\r\nhost: x\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    const resp = try it.request(req);
    try t.expect(std.mem.indexOf(u8, ITest.statusOf(resp), "200") != null);

    // 响应体必须是完整可解析的 JSON,标题裁到上限内
    const sep = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.NoBody;
    const json_body = resp[sep + 4 ..];
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json_body, .{});
    try t.expectEqual(true, parsed.object.get("ok").?.bool);
    const got = parsed.object.get("title").?.string;
    try t.expectEqual(@as(usize, sessionmod.MAX_TITLE_BYTES), got.len);
}

test "http: cross-origin write is refused with 403" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var it = try ITest.start(a, 18633, .{ .title = itestTitleHook });
    defer it.stop();

    // 恶意源:即使没开 token 也必须拒绝
    const evil = try it.request(
        "POST /api/title?session=default HTTP/1.1\r\nhost: x\r\norigin: https://evil.example.com\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}",
    );
    try t.expect(std.mem.indexOf(u8, ITest.statusOf(evil), "403") != null);

    // 本服务自己的页面放行
    const own = try std.fmt.allocPrint(
        a,
        "POST /api/title?session=default HTTP/1.1\r\nhost: x\r\norigin: http://127.0.0.1:{d}\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{{}}",
        .{it.port},
    );
    const ok = try it.request(own);
    try t.expect(std.mem.indexOf(u8, ITest.statusOf(ok), "200") != null);
}

test "http: unregistered ws is refused before reaching any handler" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Allow = struct {
        fn only(_: ?*anyopaque, ws: []const u8) bool {
            return std.mem.eql(u8, ws, "/registered");
        }
    };
    var it = try ITest.start(a, 18634, .{ .title = itestTitleHook, .ws_allowed = Allow.only });
    defer it.stop();

    // 未注册的 ws:一个不带凭证的 GET 曾能读出 ~/.piz/models.json 里的 apiKey
    const bad = try it.request("GET /api/plugins/assets/p/web/x?ws=/tmp/attacker HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n");
    try t.expect(std.mem.indexOf(u8, ITest.statusOf(bad), "403") != null);

    // 已注册的 ws 过校验(资源不存在,所以是 404 而非 403 —— 关键是不再被门口拦下)
    const good = try it.request("GET /api/plugins/assets/p/web/x?ws=/registered HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n");
    try t.expect(std.mem.indexOf(u8, ITest.statusOf(good), "403") == null);

    // 空 ws = 用进程默认项目,一律放行
    const empty = try it.request("GET / HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n");
    try t.expect(std.mem.indexOf(u8, ITest.statusOf(empty), "200") != null);

    // 壳页带未注册 ws 仍吐 HTML;API 继续 403
    const page = try it.request("GET /?session=s2&ws=/tmp/attacker HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n");
    try t.expect(std.mem.indexOf(u8, ITest.statusOf(page), "200") != null);
    try t.expect(std.mem.indexOf(u8, page, "<html") != null);
    const api_bad = try it.request("GET /api/state?ws=/tmp/attacker HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n");
    try t.expect(std.mem.indexOf(u8, ITest.statusOf(api_bad), "403") != null);
}

var global_gate: PermGate = .{ .reqs = std.array_list.Managed(PermGate.Req).init(std.heap.page_allocator) };

/// 单页 UI(复刻 kimi web:apps/kimi-web,设计令牌对齐 style.css;纯静态内嵌)。
/// 生成:src/webui.html(独立文件,免 zig 字符串转义)。
const INDEX_HTML = @embedFile("webui.html");

test "query params are split on &, not matched as substrings" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 子串匹配会把 notws= 当成 ws= —— 那样 ws 白名单校验直接被绕过
    try t.expectEqualStrings("", try queryWs(a, "/x?foo=1&notws=/etc"));
    try t.expectEqualStrings("", try queryWs(a, "/x?myws=/etc"));
    try t.expectEqualStrings("/tmp/p", try queryWs(a, "/x?ws=/tmp/p"));
    try t.expectEqualStrings("/tmp/p", try queryWs(a, "/x?foo=1&ws=/tmp/p&bar=2"));
    try t.expectEqualStrings("", try queryWs(a, "/x"));

    // session 同理
    try t.expectEqualStrings("default", try querySession(a, "/x?mysession=evil"));
    try t.expectEqualStrings("s1", try querySession(a, "/x?session=s1"));
    try t.expectEqual(@as(usize, 40), queryUsize("/api/history?offset=40&limit=20", "offset", 0));
    try t.expectEqual(@as(usize, 20), queryUsize("/api/history?offset=40&limit=20", "limit", 80));
    try t.expectEqual(@as(usize, 80), queryUsize("/api/history", "limit", 80));
    try t.expectEqual(@as(usize, 0), queryUsize("/api/history?offset=nope", "offset", 0));
}

fn fileItemNamed(items: []const FileItem, name: []const u8) ?FileItem {
    for (items) |it| if (std.mem.eql(u8, it.name, name)) return it;
    return null;
}

test "listWorkspaceFiles filters by prefix and rejects escape" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(util.io, "src");
    try tmp.dir.createDirPath(util.io, ".git");
    try tmp.dir.writeFile(util.io, .{ .sub_path = "src/webui.zig", .data = "x" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "readme.md", .data = "r" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = ".hidden", .data = "h" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = ".git/config", .data = "g" });
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });

    const root_items = try listWorkspaceFiles(a, tmp_path, "");
    try t.expect(fileItemNamed(root_items, "src") != null);
    try t.expect(fileItemNamed(root_items, "readme.md") != null);
    try t.expect(fileItemNamed(root_items, ".git") == null);
    try t.expect(fileItemNamed(root_items, ".hidden") == null);
    try t.expect(fileItemNamed(root_items, "src").?.dir);
    try t.expect(!fileItemNamed(root_items, "readme.md").?.dir);

    const src_hits = try listWorkspaceFiles(a, tmp_path, "src");
    try t.expectEqual(@as(usize, 1), src_hits.len);
    try t.expectEqualStrings("src", src_hits[0].name);
    try t.expect(src_hits[0].dir);

    const kids = try listWorkspaceFiles(a, tmp_path, "src/");
    try t.expectEqual(@as(usize, 1), kids.len);
    try t.expectEqualStrings("webui.zig", kids[0].name);
    try t.expectEqualStrings("src/webui.zig", kids[0].path);

    const prefix = try listWorkspaceFiles(a, tmp_path, "src/we");
    try t.expectEqual(@as(usize, 1), prefix.len);
    try t.expectEqualStrings("webui.zig", prefix[0].name);

    const hidden = try listWorkspaceFiles(a, tmp_path, ".h");
    try t.expect(fileItemNamed(hidden, ".hidden") != null);

    try t.expectError(error.BadPath, listWorkspaceFiles(a, tmp_path, "../"));
    try t.expectError(error.BadPath, listWorkspaceFiles(a, tmp_path, "/etc"));
    try t.expectError(error.BadPath, listWorkspaceFiles(a, tmp_path, "src/../../etc"));
}

test "artifact name is a basename only" {
    const t = std.testing;
    try t.expect(safeArtifactName("1786-read.txt"));
    try t.expect(!safeArtifactName("../secret"));
    try t.expect(!safeArtifactName("/etc/passwd"));
    try t.expect(!safeArtifactName("a/b"));
    try t.expect(!safeArtifactName(""));
}

test "http: /api/files lists a registered workspace and refuses others" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(util.io, "src");
    try tmp.dir.writeFile(util.io, .{ .sub_path = "src/a.zig", .data = "x" });
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });

    const AllowPath = struct {
        path: []const u8,
        fn only(ctx: ?*anyopaque, ws: []const u8) bool {
            if (ws.len == 0) return true;
            const self: *const @This() = @ptrCast(@alignCast(ctx.?));
            return std.mem.eql(u8, ws, self.path);
        }
    };
    var allow = AllowPath{ .path = tmp_path };

    var it = try ITest.start(a, 18650, .{
        .title = itestTitleHook,
        .ws_allowed = AllowPath.only,
        .ws_allowed_ctx = @ptrCast(&allow),
    });
    defer it.stop();

    const evil = try it.request("GET /api/files?q=&ws=/tmp/evil HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n");
    try t.expect(std.mem.indexOf(u8, evil, "403") != null);

    const req = try std.fmt.allocPrint(a, "GET /api/files?q=src&ws={s} HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n", .{tmp_path});
    const ok = try it.request(req);
    try t.expect(std.mem.indexOf(u8, ok, "200") != null);
    try t.expect(std.mem.indexOf(u8, ok, "\"ok\":true") != null);
    try t.expect(std.mem.indexOf(u8, ok, "src") != null);
    try t.expect(std.mem.indexOf(u8, ok, "\"dir\":true") != null);
}

/// 非空 `?ws=` 是否放行。
///
/// 空 ws = 用进程默认项目，一律放行。非空必须过 hook —— **hook 未接线时拒绝**：
/// 安全校验缺失要 fail-closed，忘记接线只会让功能不可用，不会留下敞口。
fn wsAllowed(
    hook: ?*const fn (ctx: ?*anyopaque, ws: []const u8) bool,
    ctx: ?*anyopaque,
    ws: []const u8,
) bool {
    if (ws.len == 0) return true;
    const f = hook orelse return false;
    return f(ctx, ws);
}

/// 构造 `{"ok":true,"<key>":"<value>"}`,长度不受限。分配失败返回 null。
///
/// 原先两处用 `[512]u8` 栈缓冲 + `try bufPrint`:模型名或标题一长就
/// `error.NoSpaceLeft`,错误冒出 handler,**连响应头都没写出去**,客户端
/// 只看到连接断开 —— 而写操作在这之前已经生效,读路径也走同一段代码,
/// 于是这个端点在进程余生里每次都断连。
fn okJson(alloc: std.mem.Allocator, key: []const u8, value: []const u8) ?[]u8 {
    var w = std.Io.Writer.Allocating.init(alloc);
    defer w.deinit();
    const vj: ?[]u8 = util.jsonString(alloc, value) catch null;
    defer if (vj) |j| alloc.free(j);
    w.writer.print("{{\"ok\":true,\"{s}\":{s}}}", .{ key, vj orelse "\"\"" }) catch return null;
    return w.toOwnedSlice() catch null;
}

test "okJson survives values longer than any fixed buffer" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try t.expectEqualStrings("{\"ok\":true,\"title\":\"hi\"}", okJson(a, "title", "hi").?);

    // 旧实现的栈缓冲是 512 字节,这里远远超过 —— 必须仍然产出完整 JSON
    const long = "L" ** 4096;
    const s = okJson(a, "title", long).?;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, s, .{});
    try t.expect(parsed == .object);
    try t.expectEqual(true, parsed.object.get("ok").?.bool);
    try t.expectEqual(@as(usize, 4096), parsed.object.get("title").?.string.len);

    // 需要转义的内容不能把 JSON 弄坏
    const q = okJson(a, "title", "a\"b\\c\nd").?;
    const pq = try std.json.parseFromSliceLeaky(std.json.Value, a, q, .{});
    try t.expectEqualStrings("a\"b\\c\nd", pq.object.get("title").?.string);
}

test "SSE slots are capped and stale ones get reclaimed" {
    const t = std.testing;
    try util.testInit();
    var hub = EventHub.init(t.allocator);
    defer hub.deinit();

    // 必须用真实时钟:unregister 内部的 trimLocked 拿 Clock.now 判僵死,
    // 传假时间戳会让所有 slot 立刻被当成超时清掉
    const now = std.Io.Clock.now(.real, util.io).nanoseconds;

    // 满员前每次都拿到新 slot,满员后拒绝 —— 拒绝必须发生在 serveSSE
    // 写出 200 头之前,否则客户端拿到的是无法区分的空流
    var slots: [EventHub.MAX_STREAMS]usize = undefined;
    for (&slots) |*s| s.* = hub.register(now).?;
    try t.expect(hub.register(now) == null);

    // 正常注销后立刻可用,且复用同一个 slot 号(游标不漂移)
    hub.unregister(slots[3]);
    try t.expectEqual(slots[3], hub.register(now).?);
    try t.expect(hub.register(now) == null);

    // 非正常断开(关标签页)时 unregister 不会跑,slot 靠 register 回收:
    // 没有这一步,空闲期里 16 个僵死 slot 能让新连接永远注册不上
    try t.expect(hub.register(now + 61 * std.time.ns_per_s) != null);
}

test "unregistered workspace is refused, and a missing hook fails closed" {
    const t = std.testing;
    const Allow = struct {
        fn only(_: ?*anyopaque, ws: []const u8) bool {
            return std.mem.eql(u8, ws, "/registered");
        }
    };

    // 空 ws 用进程默认项目
    try t.expect(wsAllowed(Allow.only, null, ""));
    try t.expect(wsAllowed(null, null, ""));

    // 已注册的放行，没注册的拒绝 —— ws 决定插件包根与 agent 的 cwd，
    // 不校验就等于让请求方任意指定这两样（实测过无 token 读出 apiKey）
    try t.expect(wsAllowed(Allow.only, null, "/registered"));
    try t.expect(!wsAllowed(Allow.only, null, "/tmp/attacker"));

    // hook 没接线 → 拒绝。安全校验缺失必须 fail-closed，
    // 否则一次重构漏掉接线就又敞开了。
    try t.expect(!wsAllowed(null, null, "/registered"));
    try t.expect(!wsAllowed(null, null, "/anything"));
}

test "SyncedArena survives concurrent allocation from many threads" {
    const t = std.testing;
    try util.testInit();
    // 裸 arena 在并发下会损坏;SyncedArena 必须让 8 线程 × 200 次分配全部
    // 拿到正确、互不重叠的内存。这个测试挂在 SyncedArena 上就是要它崩:
    // HTTP 层正是这个模式(每请求拼 JSON)。
    var sa = SyncedArena.init(t.allocator);
    defer sa.deinit();
    const a = sa.allocator();

    const Worker = struct {
        fn run(alloc: std.mem.Allocator, out: *std.atomic.Value(usize)) void {
            var arena = util.Arena.init(alloc);
            defer arena.deinit();
            const aa = arena.allocator();
            var total: usize = 0;
            for (0..200) |i| {
                const s = std.fmt.allocPrint(aa, "w{d}", .{i}) catch continue;
                total += s.len;
            }
            _ = out.fetchAdd(total, .monotonic);
        }
    };
    var sum = std.atomic.Value(usize).init(0);
    var threads: [8]std.Thread = undefined;
    for (&threads) |*th| th.* = try std.Thread.spawn(.{}, Worker.run, .{ a, &sum });
    for (&threads) |th| th.join();
    // 8 线程 × 200 次 × "w" + 最多 3 位数字 ≥ 8*200*2 = 3200
    try t.expect(sum.load(.monotonic) >= 3200);
}

test "artifact image rejects unsafe names" {
    const t = std.testing;
    try t.expect(artifactImage(t.allocator, "../secret.png") == null);
    try t.expect(artifactImage(t.allocator, "bash-1.txt") == null);
    try t.expect(artifactImage(t.allocator, "") == null);
}
