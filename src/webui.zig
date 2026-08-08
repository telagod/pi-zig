// webui.zig — 内置 Web UI(对齐 kimi web / grok --web):单进程本地 HTTP 服务 + SSE + 单页。
//   piz web [--port N] [--no-open] [--token T]
//   默认 127.0.0.1:5494(占用自动 +1,范围 5494-5503);--token 启用 Bearer 认证。
//   端点:GET /(单页) GET /api/events(SSE) GET /api/state POST /api/chat POST /api/interrupt
const std = @import("std");
const util = @import("core").util;
const agentmod = @import("core").agent;
const webplugins = @import("core").webplugins;
const sessionmod = @import("core").session;
const http = std.http;
const net = std.Io.net;

pub const WebOptions = struct {
    port: u16 = 0, // 0 = 从 5494 起自动找可用端口
    no_open: bool = false,
    token: ?[]const u8 = null,
    project_cwd: ?[]const u8 = null,
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

pub const WebServer = struct {
    alloc: std.mem.Allocator,
    opts: WebOptions,
    hub: *EventHub,
    agent: ?*agentmod.Agent = null,
    /// 会话池回调(main 实现):state 数据 / chat 入队(返回 false 拒绝);cwd = 项目根
    state_hook: ?*const fn (ctx: ?*anyopaque, cwd: []const u8, session: []const u8, alloc: std.mem.Allocator) []const u8 = null,
    state_ctx: ?*anyopaque = null,
    chat_hook: ?*const fn (ctx: ?*anyopaque, cwd: []const u8, session: []const u8, text: []const u8) bool = null,
    chat_ctx: ?*anyopaque = null,
    /// 会话列表 hook(main 实现):返回 JSON 数组 [{name,msgs}] (按 cwd 过滤)
    sessions_hook: ?*const fn (ctx: ?*anyopaque, cwd: []const u8, alloc: std.mem.Allocator) []const u8 = null,
    sessions_ctx: ?*anyopaque = null,
    /// 中断 hook(main 实现):中止指定会话当前轮
    interrupt_hook: ?*const fn (ctx: ?*anyopaque, cwd: []const u8, session: []const u8) void = null,
    interrupt_ctx: ?*anyopaque = null,
    /// 审批模式 hook(auto=null 读):返回当前模式或 null(会话不存在)
    mode_hook: ?*const fn (ctx: ?*anyopaque, cwd: []const u8, session: []const u8, auto: ?bool) ?bool = null,
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
    tcp: net.Server,
    port: u16,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 在处理中的连接数。每连接一个 OS 线程 + 12KB 栈缓冲,没有上限时
    /// 本机一个循环 connect 就能把线程耗光,agent 随之停摆。
    live_conns: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// 并发连接上限。SSE 长连接占满 MAX_STREAMS(16)后还留足余量给普通请求。
    pub const MAX_CONNS = 64;
    /// 单个请求头的读超时。连上不发数据的连接会永久占住一个线程 --
    /// 本机 slowloris 只需 MAX_CONNS 个这样的连接。
    const READ_TIMEOUT_S = 30;

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
        while (!self.stopping.load(.acquire)) {
            const stream = self.tcp.accept(util.io) catch |err| switch (err) {
                error.Canceled => return,
                else => continue,
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
        // 读超时:没有它,连上却不发数据的连接会永久占住这个线程。
        // std.Io.net.Stream 在 0.16 没有超时 API,只能走 setsockopt。
        // SSE 靠 30s 心跳写出保活,读方向本来就空闲,超时不影响它。
        const tv = std.posix.timeval{ .sec = READ_TIMEOUT_S, .usec = 0 };
        std.posix.setsockopt(
            stream.socket.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&tv),
        ) catch {};
        var send_buf: [4096]u8 = undefined;
        var recv_buf: [8192]u8 = undefined;
        var cr = stream.reader(util.io, &recv_buf);
        var cw = stream.writer(util.io, &send_buf);
        var server: http.Server = .init(&cr.interface, &cw.interface);
        while (true) {
            var req = server.receiveHead() catch return;
            self.serve(&req, stream.socket.handle) catch return;
        }
    }

    /// `conn_fd` 只给 SSE 用:长连接需要探测对端是否已关闭。
    fn serve(self: *WebServer, req: *http.Server.Request, conn_fd: std.posix.fd_t) !void {
        const target = req.head.target;
        const method = req.head.method;
        // 静态资源(HTML/JS/CSS)免鉴权(kimi 同:仅 API/WS 需凭证)——否则 splash 无法加载
        const is_static = method == .GET and
            (std.mem.eql(u8, target, "/") or std.mem.startsWith(u8, target, "/?") or
                std.mem.eql(u8, target, "/index.html") or
                std.mem.startsWith(u8, target, "/api/plugins/assets/"));
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
        if (!wsAllowed(self.ws_allowed_hook, self.ws_allowed_ctx, ws)) {
            try req.respond("unknown workspace", .{ .status = .forbidden });
            return;
        }
        if (method == .GET and (std.mem.eql(u8, target, "/") or std.mem.startsWith(u8, target, "/?") or std.mem.eql(u8, target, "/index.html"))) {
            try req.respond(INDEX_HTML, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
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
        if (method == .GET and std.mem.startsWith(u8, target, "/api/sessions")) {
            const body = if (self.sessions_hook) |f| f(self.sessions_ctx, ws, self.alloc) else "[]";
            try req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        if (method == .GET and std.mem.eql(u8, target, "/api/models")) {
            const body = if (self.models_hook) |f| f(self.models_ctx, self.alloc) else "[]";
            try req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        if (method == .GET and std.mem.eql(u8, target, "/api/config")) {
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
        if (method == .GET and std.mem.eql(u8, target, "/api/events")) {
            return self.serveSSE(req, conn_fd);
        }
        if (method == .POST and std.mem.startsWith(u8, target, "/api/chat")) {
            const session = querySession(self.alloc, target) catch "default";
            defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
            var body_buf: [16 * 1024]u8 = undefined;
            const reader = req.readerExpectNone(&body_buf);
            const body = reader.allocRemaining(self.alloc, .limited(64 * 1024)) catch "";
            defer if (body.len > 0) self.alloc.free(body);
            const text = parseChatText(self.alloc, body) catch "";
            defer if (text.len > 0) self.alloc.free(text);
            if (text.len > 0 and !self.stopping.load(.acquire)) {
                if (self.chat_hook) |f| {
                    if (!f(self.chat_ctx, ws, session, text)) {
                        try req.respond("{\"ok\":false,\"error\":\"session limit\"}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                        return;
                    }
                } else {
                    self.hub.push("{{\"type\":\"user_message\",\"text\":{s}}}", .{try util.jsonString(self.alloc, text)});
                    ChatQueue.enqueue(session, text);
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
        if (method == .POST and std.mem.eql(u8, target, "/api/approve")) {
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
            var auto: ?bool = null;
            var body_buf: [256]u8 = undefined;
            const reader = req.readerExpectNone(&body_buf);
            const body = reader.allocRemaining(self.alloc, .limited(1024)) catch "";
            defer if (body.len > 0) self.alloc.free(body);
            if (body.len > 0) {
                const root = std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{}) catch null;
                if (root) |r| {
                    if (r == .object) {
                        if (r.object.get("auto")) |v| {
                            if (v == .bool) auto = v.bool;
                        }
                    }
                }
            }
            if (self.mode_hook) |f| {
                const cur = f(self.mode_ctx, ws, session, auto) orelse {
                    try req.respond("{\"ok\":false}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                    return;
                };
                // auto 是 JSON 布尔(无引号),不能走 okJson —— 那会变成字符串
                // 而破坏前端的 === true 判断。输出只有两种,直接选,不用格式化。
                const s = if (cur) "{\"ok\":true,\"auto\":true}" else "{\"ok\":true,\"auto\":false}";
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
        if (method == .GET and std.mem.eql(u8, target, "/api/workspaces")) {
            const body = if (self.workspaces_hook) |f| (f(self.workspaces_ctx, self.alloc, null) orelse "[]") else "[]";
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

    /// /api/state:端口 + 模型 + ctx% + 最近 20 条历史(刷新恢复)。
    fn stateJson(self: *WebServer) []const u8 {
        const a = self.alloc;
        var stw = std.Io.Writer.Allocating.init(a);
        defer stw.deinit();
        const w = &stw.writer;
        w.print("{{\"port\":{d}", .{self.port}) catch {};
        if (self.agent) |ag| {
            w.print(",\"model\":{s}", .{util.jsonString(a, ag.model) catch "\"\""}) catch {};
            const cw = @as(usize, ag.provider.context_window);
            const used = ag.estTokens();
            const pct = if (cw > 0) used * 100 / cw else 0;
            w.print(",\"pct\":{d}", .{pct}) catch {};
            // 历史:最近 20 条(user/assistant/工具摘要),内容截 300
            w.writeAll(",\"history\":[") catch {};
            const msgs = ag.messages.items;
            const hist_start = if (msgs.len > 20) msgs.len - 20 else 0;
            var first = true;
            var i = hist_start;
            while (i < msgs.len) : (i += 1) {
                const m = &msgs[i];
                if (!first) w.writeAll(",") catch {};
                first = false;
                const content = if (m.content.len > 300) m.content[0..300] else m.content;
                w.print("{{\"role\":{s},\"content\":{s}}}", .{ util.jsonString(a, m.role) catch "\"\"", util.jsonString(a, content) catch "\"\"" }) catch {};
            }
            w.writeAll("]") catch {};
        }
        w.writeAll("}") catch {};
        return stw.toOwnedSlice() catch "{}";
    }

    /// SSE 长连接:手动原始响应(0.16 BodyWriter.flush 有字节滞留问题),
    /// 头即 flush;轮询转发 hub 事件 + 30s 心跳;上报消费位置供 hub 裁头。
    /// 转发在锁内(事件短、本地回环;锁外转发会与 push 的裁头竞态导致漏事件)。
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
            return;
        };
        defer self.hub.unregister(slot);
        try out.print("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncache-control: no-cache\r\nconnection: close\r\n\r\n", .{});
        try out.flush();
        // 新连接从当前尾部开始(state 已承担历史重放;从头重放会与 state 重复渲染)
        var cursor: usize = 0;
        {
            self.hub.mutex.lock(util.io) catch return;
            cursor = self.hub.events.items.len;
            self.hub.mutex.unlock(util.io);
        }
        var idle: usize = 0;
        while (!self.stopping.load(.acquire)) {
            self.hub.mutex.lock(util.io) catch return;
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
                if (util.peerClosed(conn_fd)) return;
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

fn parseChatText(alloc: std.mem.Allocator, body: []const u8) ![]const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{}) catch return alloc.dupe(u8, "");
    if (root == .object) {
        if (root.object.get("text")) |v| {
            if (v == .string) return alloc.dupe(u8, v.string);
        }
    }
    return alloc.dupe(u8, "");
}

/// 消息队列(server 线程入队,各 session worker 按名消费)。
pub const ChatQueue = struct {
    pub const Item = struct { session: []const u8, text: []const u8 };
    mutex: std.Io.Mutex = .init,
    items: std.array_list.Managed(Item),
    shutting_down: bool = false,

    pub fn enqueue(session: []const u8, text: []const u8) void {
        // 调用方(HTTP 线程)可能随后 free 入参——入队须 dupe(page_allocator)
        const alloc = std.heap.page_allocator;
        const s_dup = alloc.dupe(u8, session) catch return;
        const t_dup = alloc.dupe(u8, text) catch return;
        global.mutex.lock(util.io) catch return;
        global.items.append(.{ .session = s_dup, .text = t_dup }) catch {
            alloc.free(s_dup);
            alloc.free(t_dup);
        };
        global.mutex.unlock(util.io);
    }
    /// 轮询取本 session 消息(100ms);shutdown 后返回 null。
    pub fn dequeue(session: []const u8) ?Item {
        while (!global.shutting_down) {
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
