//! webui_tests.zig —— webui.zig 的单测主体(纯函数级 + HTTP 集成)。
//! 拆自 webui.zig(17 测试 + ITest 等助手);webui.zig 尾部 test 钩子引回,收集不变。
const std = @import("std");
const util = @import("core").util;
const sessionmod = @import("core").session;
const http = std.http;
const net = std.Io.net;
const webui = @import("webui.zig");
const routes = @import("webui_routes.zig");
const filesmod = @import("core").tools_files;

const SyncedArena = webui.SyncedArena;
const EventHub = webui.EventHub;
const WebServer = webui.WebServer;
const ChatQueue = webui.ChatQueue;
const originOk = webui.originOk;
const hostOk = webui.hostOk;
const wsAllowed = webui.wsAllowed;
const queryUsize = routes.queryUsize;
const querySession = routes.querySession;
const queryWs = routes.queryWs;
const okJson = routes.okJson;
const safeArtifactName = routes.safeArtifactName;
const artifactImage = routes.artifactImage;
const parseChatBody = routes.parseChatBody;
const parseChatText = routes.parseChatText;
const FileItem = filesmod.FileItem;
const listWorkspaceFiles = filesmod.listWorkspaceFiles;

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

test "hostOk rejects external host and allows loopback" {
    const t = std.testing;
    const PORT: u16 = 5494;

    // 缺失 Host 头(HTTP/1.0 客户端)放行
    try t.expect(hostOk(PORT, "GET / HTTP/1.0\r\n\r\n"));

    // 合法 loopback 与端口
    try t.expect(hostOk(PORT, "GET / HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n"));
    try t.expect(hostOk(PORT, "GET / HTTP/1.1\r\nHost: 127.0.0.1:5494\r\n\r\n"));
    try t.expect(hostOk(PORT, "GET / HTTP/1.1\r\nhost: localhost\r\n\r\n"));
    try t.expect(hostOk(PORT, "GET / HTTP/1.1\r\nhost: localhost:5494\r\n\r\n"));
    try t.expect(hostOk(PORT, "GET / HTTP/1.1\r\nhost: [::1]\r\n\r\n"));
    try t.expect(hostOk(PORT, "GET / HTTP/1.1\r\nhost: [::1]:5494\r\n\r\n"));

    // 端口不匹配
    try t.expect(!hostOk(PORT, "GET / HTTP/1.1\r\nhost: 127.0.0.1:9999\r\n\r\n"));
    try t.expect(!hostOk(PORT, "GET / HTTP/1.1\r\nhost: localhost:80\r\n\r\n"));

    // DNS Rebinding 外部域名
    try t.expect(!hostOk(PORT, "GET / HTTP/1.1\r\nhost: attacker.com\r\n\r\n"));
    try t.expect(!hostOk(PORT, "GET / HTTP/1.1\r\nhost: attacker.com:5494\r\n\r\n"));
    try t.expect(!hostOk(PORT, "GET / HTTP/1.1\r\nhost: evil.localhost.com\r\n\r\n"));
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
        s.* = try it.openStream("GET /api/events HTTP/1.1\r\nhost: 127.0.0.1\r\naccept: text/event-stream\r\n\r\n");
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
    const resp = try it.request("GET /api/events HTTP/1.1\r\nhost: 127.0.0.1\r\naccept: text/event-stream\r\n\r\n");
    try t.expect(std.mem.indexOf(u8, ITest.statusOf(resp), "503") != null);
    try t.expect(std.mem.indexOf(u8, resp, "too many event streams") != null);
    try t.expect(std.mem.indexOf(u8, resp, "retry-after") != null);
    // 不能同时出现 200 —— 那说明头写在拒绝之前
    try t.expect(std.mem.indexOf(u8, resp, "200 OK") == null);
}

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
        "POST /api/title?session=default HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}",
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
        "POST /api/title?session=default HTTP/1.1\r\nhost: 127.0.0.1\r\norigin: https://evil.example.com\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}",
    );
    try t.expect(std.mem.indexOf(u8, ITest.statusOf(evil), "403") != null);

    // 本服务自己的页面放行
    const own = try std.fmt.allocPrint(
        a,
        "POST /api/title?session=default HTTP/1.1\r\nhost: 127.0.0.1\r\norigin: http://127.0.0.1:{d}\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{{}}",
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
    const bad = try it.request("GET /api/plugins/assets/p/web/x?ws=/tmp/attacker HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n");
    try t.expect(std.mem.indexOf(u8, ITest.statusOf(bad), "403") != null);

    // 已注册的 ws 过校验(资源不存在,所以是 404 而非 403 —— 关键是不再被门口拦下)
    const good = try it.request("GET /api/plugins/assets/p/web/x?ws=/registered HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n");
    try t.expect(std.mem.indexOf(u8, ITest.statusOf(good), "403") == null);

    // 空 ws = 用进程默认项目,一律放行
    const empty = try it.request("GET / HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n");
    try t.expect(std.mem.indexOf(u8, ITest.statusOf(empty), "200") != null);

    // 壳页带未注册 ws 仍吐 HTML;API 继续 403
    const page = try it.request("GET /?session=s2&ws=/tmp/attacker HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n");
    try t.expect(std.mem.indexOf(u8, ITest.statusOf(page), "200") != null);
    try t.expect(std.mem.indexOf(u8, page, "<html") != null);
    const api_bad = try it.request("GET /api/state?ws=/tmp/attacker HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n");
    try t.expect(std.mem.indexOf(u8, ITest.statusOf(api_bad), "403") != null);
}

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

    const evil = try it.request("GET /api/files?q=&ws=/tmp/evil HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n");
    try t.expect(std.mem.indexOf(u8, evil, "403") != null);

    const req = try std.fmt.allocPrint(a, "GET /api/files?q=src&ws={s} HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n", .{tmp_path});
    const ok = try it.request(req);
    try t.expect(std.mem.indexOf(u8, ok, "200") != null);
    try t.expect(std.mem.indexOf(u8, ok, "\"ok\":true") != null);
    try t.expect(std.mem.indexOf(u8, ok, "src") != null);
    try t.expect(std.mem.indexOf(u8, ok, "\"dir\":true") != null);
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
