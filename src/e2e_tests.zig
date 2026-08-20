//! e2e_tests.zig —— e2e.zig 的单测主体(14 测试 + 各 mock 助手)。
//! 拆自 e2e.zig;e2e.zig 尾部 test 钩子引回,收集不变。
//! MockState/mockServerMain/DropState/dropServerMain/readFd/writeFd 留在 e2e.zig
//! (pub),因 main 派发的 testXxx 驱动也用;此处只收纯测试专用的 mock。
const std = @import("std");
const util = @import("core").util;
const cfgmod = @import("core").config;
const agentmod = @import("core").agent;
const pluginsmod = @import("core").plugins;
const ai = @import("core").ai;
const httpc = @import("core").httpc;
const mcpmod = @import("core").mcp;
const e2e = @import("e2e.zig");

const MockState = e2e.MockState;
const mockServerMain = e2e.mockServerMain;
const DropState = e2e.DropState;
const dropServerMain = e2e.dropServerMain;
const readFd = e2e.readFd;
const writeFd = e2e.writeFd;

const MOCK_PORT3: u16 = 18523;
const MOCK_PORT4: u16 = 18524;

test "stream cut mid-reply keeps partial text and resumes automatically" {
    const t = std.testing;
    try util.testInit();
    const PORT: u16 = 18527;
    var state = DropState{ .port = PORT };
    const th = try std.Thread.spawn(.{}, dropServerMain, .{&state});
    defer {
        state.stop.store(true, .release);
        th.join();
    }
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 80 * std.time.ns_per_ms }, .awake) catch {};

    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1", .{PORT});
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = base, .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");

    const res = try agent.send("hello");

    // 断流后自动续跑:第二次请求发生了
    try t.expectEqual(@as(usize, 2), state.requests.load(.acquire));
    // 已收到的半句必须进历史 —— 丢了就等于用户眼前那半段回复凭空消失
    try t.expect(state.partial_kept.load(.acquire));
    // 续跑指令必须明确「接着说、别重复」
    try t.expect(state.resume_hinted.load(.acquire));
    // 最终拿到的是续跑后的完整答复,而不是一个错误
    try t.expect(res.error_msg == null);
    try t.expectEqualStrings("RESUMED-OK", res.text);
}

// ---------------------------------------------------------------------
// 空转防线:模型反复发同一个工具调用,piz 必须干预并停下。
// ---------------------------------------------------------------------

const LoopState = struct {
    port: u16,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    requests: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// piz 是否发出了「别再调了,用已有结果作答」的收尾指令
    nudge_seen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// 永远回同一个 tool_call 的 mock —— 复现某些模型拿到结果后不收尾的行为。
fn loopServerMain(state: *LoopState) void {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", state.port) catch return;
    var server = addr.listen(util.io, .{ .reuse_address = true }) catch return;
    defer server.deinit(util.io);
    util.setNonBlock(server.socket.handle);

    var pfds = [_]std.posix.pollfd{.{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    while (!state.stop.load(.acquire)) {
        const n = std.posix.poll(&pfds, 10) catch continue;
        if (n == 0) continue;
        const raw = std.os.linux.accept4(server.socket.handle, null, null, 0o2000000);
        const rc = @as(isize, @bitCast(raw));
        if (rc < 0) continue;
        const fd: std.posix.fd_t = @intCast(rc);
        defer _ = std.os.linux.close(fd);

        var rbuf: [32768]u8 = undefined;
        const got = readFd(fd, &rbuf) catch continue;
        _ = state.requests.fetchAdd(1, .acq_rel);
        if (std.mem.indexOf(u8, rbuf[0..got], "Stop calling tools") != null) {
            state.nudge_seen.store(true, .release);
        }

        // 每次都回同一个 tool_call:同名、同参数。
        // 命令刻意打时间戳 —— 输出每次不同,所以只有**参数级**判据能抓住它。
        // 用 `echo hi` 那种恒定输出的话输出指纹判据也会触发,这条测试就分不清
        // 到底是哪个判据在起作用。
        const body_sse =
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"date +%s%N\\\"}\"}}]},\"finish_reason\":null}]}\n\n" ++
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
            "data: [DONE]\n\n";
        var hbuf: [256]u8 = undefined;
        const head = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{body_sse.len}) catch continue;
        _ = writeFd(fd, head) catch {};
        _ = writeFd(fd, body_sse) catch {};
    }
}

test "identical tool calls in a row are cut off well before the iteration limit" {
    const t = std.testing;
    try util.testInit();
    pluginsmod.resetEnabledForTest();
    const PORT: u16 = 18529;
    var state = LoopState{ .port = PORT };
    const th = try std.Thread.spawn(.{}, loopServerMain, .{&state});
    defer {
        state.stop.store(true, .release);
        th.join();
    }
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 80 * std.time.ns_per_ms }, .awake) catch {};

    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1", .{PORT});
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = base, .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");

    _ = try agent.send("run echo hi");

    // 干预过:发出了收尾指令
    try t.expect(state.nudge_seen.load(.acquire));
    // 远早于 24 轮就停了。阈值 2 → 劝一次 → 再重复 2 轮 → 停,约 6 轮。
    const reqs = state.requests.load(.acquire);
    try t.expect(reqs >= 3); // 至少要观察到重复才判定
    try t.expect(reqs <= 8); // 空转判据应早停,不是无限转
}

// ---------------------------------------------------------------------
// 输出空转:参数每次不同但输出一样,也要被切断。
// ---------------------------------------------------------------------

const VariantState = struct {
    port: u16,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    requests: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    nudge_seen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// 每次回**不同参数**的同名工具调用 —— 复现「换个写法再跑一遍」。
/// 参数比对抓不住这种,只有输出指纹能。
fn variantServerMain(state: *VariantState) void {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", state.port) catch return;
    var server = addr.listen(util.io, .{ .reuse_address = true }) catch return;
    defer server.deinit(util.io);
    util.setNonBlock(server.socket.handle);

    var pfds = [_]std.posix.pollfd{.{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    while (!state.stop.load(.acquire)) {
        const n = std.posix.poll(&pfds, 10) catch continue;
        if (n == 0) continue;
        const raw = std.os.linux.accept4(server.socket.handle, null, null, 0o2000000);
        const rc = @as(isize, @bitCast(raw));
        if (rc < 0) continue;
        const fd: std.posix.fd_t = @intCast(rc);
        defer _ = std.os.linux.close(fd);

        var rbuf: [32768]u8 = undefined;
        const got = readFd(fd, &rbuf) catch continue;
        const req_no = state.requests.fetchAdd(1, .acq_rel) + 1;
        if (std.mem.indexOf(u8, rbuf[0..got], "identical output every time") != null) {
            state.nudge_seen.store(true, .release);
        }

        // 每轮命令写法都不同(重定向、管道、cd 前缀),但都跑同一个 echo,
        // 所以工具输出每次完全一致。
        const variants = [_][]const u8{
            "echo same",
            "echo same 2>&1",
            "sh -c 'echo same'",
            "cd /tmp && echo same",
            "echo same | cat",
            "true; echo same",
        };
        const cmd = variants[@min(req_no - 1, variants.len - 1)];
        var sbuf: [1024]u8 = undefined;
        const sse = std.fmt.bufPrint(&sbuf, "data: {{\"choices\":[{{\"delta\":{{\"tool_calls\":[{{\"index\":0,\"id\":\"c{d}\",\"type\":\"function\",\"function\":{{\"name\":\"bash\",\"arguments\":\"{{\\\"command\\\":\\\"{s}\\\"}}\"}}}}]}},\"finish_reason\":null}}]}}\n\n" ++
            "data: {{\"choices\":[{{\"delta\":{{}},\"finish_reason\":\"tool_calls\"}}]}}\n\n" ++
            "data: [DONE]\n\n", .{ req_no, cmd }) catch continue;
        var hbuf: [256]u8 = undefined;
        const head = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{sse.len}) catch continue;
        _ = writeFd(fd, head) catch {};
        _ = writeFd(fd, sse) catch {};
    }
}

test "different commands that return identical output are also cut off" {
    const t = std.testing;
    try util.testInit();
    pluginsmod.resetEnabledForTest();
    const PORT: u16 = 18531;
    var state = VariantState{ .port = PORT };
    const th = try std.Thread.spawn(.{}, variantServerMain, .{&state});
    defer {
        state.stop.store(true, .release);
        th.join();
    }
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 80 * std.time.ns_per_ms }, .awake) catch {};

    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1", .{PORT});
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = base, .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");

    _ = try agent.send("report the output");

    // 参数每次不同,所以参数级判据不会触发 —— 必须靠输出指纹抓到
    try t.expect(state.nudge_seen.load(.acquire));
    const reqs = state.requests.load(.acquire);
    try t.expect(reqs >= 3);
    try t.expect(reqs <= 9); // 空转判据应早停
}

// ---------------------------------------------------------------------
// 止损切断时不能让用户空手而归:答案在工具输出里,要交出去。
// ---------------------------------------------------------------------

const SalvageState = struct {
    port: u16,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    requests: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

/// 永远只发同一条 tool_call,一个字正文都不发 —— 复现「模型空转也不给结论」。
/// 相同调用会触发空转判据,止损时要把最后一份工具输出交出去。
fn salvageServerMain(state: *SalvageState) void {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", state.port) catch return;
    var server = addr.listen(util.io, .{ .reuse_address = true }) catch return;
    defer server.deinit(util.io);
    util.setNonBlock(server.socket.handle);

    var pfds = [_]std.posix.pollfd{.{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    while (!state.stop.load(.acquire)) {
        const n = std.posix.poll(&pfds, 10) catch continue;
        if (n == 0) continue;
        const raw = std.os.linux.accept4(server.socket.handle, null, null, 0o2000000);
        const rc = @as(isize, @bitCast(raw));
        if (rc < 0) continue;
        const fd: std.posix.fd_t = @intCast(rc);
        defer _ = std.os.linux.close(fd);

        var rbuf: [32768]u8 = undefined;
        _ = readFd(fd, &rbuf) catch continue;
        const req_no = state.requests.fetchAdd(1, .acq_rel) + 1;

        var sbuf: [1024]u8 = undefined;
        const sse = std.fmt.bufPrint(&sbuf, "data: {{\"choices\":[{{\"delta\":{{\"tool_calls\":[{{\"index\":0,\"id\":\"c{d}\",\"type\":\"function\",\"function\":{{\"name\":\"bash\",\"arguments\":\"{{\\\"command\\\":\\\"echo salvage-marker\\\"}}\"}}}}]}},\"finish_reason\":null}}]}}\n\n" ++
            "data: {{\"choices\":[{{\"delta\":{{}},\"finish_reason\":\"tool_calls\"}}]}}\n\n" ++
            "data: [DONE]\n\n", .{req_no}) catch continue;
        var hbuf: [256]u8 = undefined;
        const head = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{sse.len}) catch continue;
        _ = writeFd(fd, head) catch {};
        _ = writeFd(fd, sse) catch {};
    }
}

test "cutoff with no model text hands back the last tool output" {
    const t = std.testing;
    try util.testInit();
    pluginsmod.resetEnabledForTest();
    const PORT: u16 = 18532;
    var state = SalvageState{ .port = PORT };
    const th = try std.Thread.spawn(.{}, salvageServerMain, .{&state});
    defer {
        state.stop.store(true, .release);
        th.join();
    }
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 80 * std.time.ns_per_ms }, .awake) catch {};

    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1", .{PORT});
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = base, .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");

    const res = try agent.send("what does it print");

    // 关键:模型一个字正文都没发,但用户不能拿到空回复 ——
    // 答案在最后一份工具输出里,piz 要把它交出来。
    try t.expect(res.text.len > 0);
    try t.expect(std.mem.indexOf(u8, res.text, "salvage-marker") != null);
    // 必须说清这是原始工具输出,不能让用户误以为模型作过判断
    try t.expect(std.mem.indexOf(u8, res.text, "原始输出") != null);
}

test "salvage never overwrites text the model actually produced" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 模型说了话 —— 原样保留,不许被工具输出顶掉
    var with_text = ai.RunResult{ .text = "the answer is 42" };
    agentmod.salvageTextForTest(a, &with_text, "bash", "raw tool bytes");
    try t.expectEqualStrings("the answer is 42", with_text.text);

    // 模型没说话 —— 用工具输出填补
    var empty = ai.RunResult{};
    agentmod.salvageTextForTest(a, &empty, "bash", "raw tool bytes");
    try t.expect(std.mem.indexOf(u8, empty.text, "raw tool bytes") != null);

    // 工具输出也是空的 —— 不许编造内容
    var both_empty = ai.RunResult{};
    agentmod.salvageTextForTest(a, &both_empty, "bash", "");
    try t.expectEqualStrings("", both_empty.text);
}

// ---------- 并发 provider 请求 ----------

/// 记录并发峰值的最小 mock。每连接一个线程 —— e2e 的主 mock 是串行 accept-handle,
/// 用它测不出串行化(服务端本身就是串行的)。
const ConcState = struct {
    port: u16,
    stop: std.atomic.Value(bool) = .init(false),
    /// 当前同时在处理的请求数
    in_flight: std.atomic.Value(u32) = .init(0),
    /// 见过的最大并发数 —— 这是断言的核心。锁串行化时它永远是 1,
    /// 而这个判据与机器速度无关(时间断言在 CI 上不稳)。
    peak: std.atomic.Value(u32) = .init(0),
    completed: std.atomic.Value(u32) = .init(0),
};

fn concHandle(state: *ConcState, fd: std.posix.fd_t) void {
    var conn = std.Io.net.Stream{ .socket = .{ .handle = fd, .address = undefined } };
    defer conn.close(util.io);

    const now = state.in_flight.fetchAdd(1, .acq_rel) + 1;
    _ = state.peak.fetchMax(now, .acq_rel);
    defer _ = state.in_flight.fetchSub(1, .acq_rel);

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var fin = conn.reader(util.io, &rbuf);
    var fout = conn.writer(util.io, &wbuf);
    var server = std.http.Server.init(&fin.interface, &fout.interface);
    var req = server.receiveHead() catch return;
    var tbuf: [8192]u8 = undefined;
    const reader = req.readerExpectContinue(&tbuf) catch return;
    _ = reader.allocRemaining(state_alloc, .limited(1024 * 1024)) catch return;

    // 停在这里等一小会:所有请求都卡在这段窗口内,峰值才反映真实并发度。
    // 串行化的话每个请求依次进出,峰值恒为 1。
    std.Io.sleep(util.io, .{ .nanoseconds = 120 * std.time.ns_per_ms }, .awake) catch {};

    const body =
        "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    req.respond(body, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
    }) catch return;
    _ = state.completed.fetchAdd(1, .acq_rel);
}

var state_alloc: std.mem.Allocator = undefined;

fn concServerMain(state: *ConcState) void {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", state.port) catch return;
    var server = addr.listen(util.io, .{ .reuse_address = true }) catch return;
    defer server.deinit(util.io);
    util.setNonBlock(server.socket.handle);

    var pfds = [_]std.posix.pollfd{.{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    while (!state.stop.load(.acquire)) {
        const n = std.posix.poll(&pfds, 10) catch continue;
        if (n == 0) continue;
        const raw = std.os.linux.accept4(server.socket.handle, null, null, 0o2000000);
        const rc = @as(isize, @bitCast(raw));
        if (rc < 0) continue;
        const th = std.Thread.spawn(.{}, concHandle, .{ state, @as(std.posix.fd_t, @intCast(rc)) }) catch {
            concHandle(state, @intCast(rc));
            continue;
        };
        th.detach();
    }
}

test "provider requests actually run in parallel and none get corrupted" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    state_alloc = arena.allocator();

    var state = ConcState{ .port = 18711 };
    const server_thread = try std.Thread.spawn(.{}, concServerMain, .{&state});
    defer {
        state.stop.store(true, .release);
        server_thread.join();
    }
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 60 * std.time.ns_per_ms }, .awake) catch {};

    const N = 8;
    const Worker = struct {
        ok: std.atomic.Value(u32) = .init(0),
        bad: std.atomic.Value(u32) = .init(0),
        port: u16,

        fn run(self: *@This()) void {
            var url_buf: [64]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{self.port}) catch return;
            const body = "{\"model\":\"m\",\"messages\":[],\"stream\":true}";
            const s = httpc.Stream.init(std.heap.page_allocator, url, &.{}, body) catch {
                _ = self.bad.fetchAdd(1, .acq_rel);
                return;
            };
            defer s.deinit();
            // 每个响应必须完整:2 个 data 事件 + [DONE]。少一个就说明
            // 两个线程读串了同一个连接。
            var data_events: usize = 0;
            var saw_done = false;
            while (s.readLine() catch null) |line| {
                if (std.mem.startsWith(u8, line, "data: [DONE]")) saw_done = true else if (std.mem.startsWith(u8, line, "data: ")) data_events += 1;
            }
            if (data_events == 2 and saw_done) {
                _ = self.ok.fetchAdd(1, .acq_rel);
            } else {
                _ = self.bad.fetchAdd(1, .acq_rel);
            }
        }
    };
    var w = Worker{ .port = state.port };
    var threads: [N]std.Thread = undefined;
    for (&threads) |*th| th.* = try std.Thread.spawn(.{}, Worker.run, .{&w});
    for (threads) |th| th.join();

    // 全部完整 —— 并发不能损坏连接池
    try t.expectEqual(@as(u32, N), w.ok.load(.acquire));
    try t.expectEqual(@as(u32, 0), w.bad.load(.acquire));

    // 真的并发。ClientPool 的锁曾覆盖整个 Stream.init(建连 + 发请求体 +
    // 收响应头),把并发调用完全串行化:实测 TTFB 300ms 下 160 个请求
    // 48169ms vs 3755ms(12.8 倍)。串行时这个峰值恒为 1。
    try t.expect(state.peak.load(.acquire) > 1);
}

// ---------- 进程内 subagent ----------

/// 专用 mock:第一轮回 task 工具调用,subagent 的请求回 bash 工具调用,
/// 带过工具结果的请求回文本。按请求内容分派而非序号 —— 并行 subagent
/// 的到达顺序不确定。
const SubMock = struct {
    port: u16,
    stop: std.atomic.Value(bool) = .init(false),
    /// 看到的 read_only 子请求数(请求体无 tools 字段)
    ro_requests: std.atomic.Value(u32) = .init(0),
    /// 见过的「要求再委派」的请求数 —— 深度闸门失效时它会失控增长
    nest_requests: std.atomic.Value(u32) = .init(0),
};

var submock_alloc: std.mem.Allocator = undefined;

fn subMockHandle(state: *SubMock, fd: std.posix.fd_t) void {
    var conn = std.Io.net.Stream{ .socket = .{ .handle = fd, .address = undefined } };
    defer conn.close(util.io);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [8 * 1024]u8 = undefined;
    var fin = conn.reader(util.io, &rbuf);
    var fout = conn.writer(util.io, &wbuf);
    var server = std.http.Server.init(&fin.interface, &fout.interface);
    var req = server.receiveHead() catch return;
    var tbuf: [64 * 1024]u8 = undefined;
    const reader = req.readerExpectContinue(&tbuf) catch return;
    const body = reader.allocRemaining(submock_alloc, .limited(4 * 1024 * 1024)) catch return;

    const ran_tool = std.mem.indexOf(u8, body, "\"role\":\"tool\"") != null;
    const wants_task = std.mem.indexOf(u8, body, "SPLIT-ME") != null;
    // 嵌套委派:subagent 收到 NEST-ME 时也要求再委派一层。深度正确递增时
    // 第二层撞上 MAX_TASK_DEPTH 被拒;不递增就会一层层下去。
    const wants_nest = std.mem.indexOf(u8, body, "NEST-ME") != null;
    if (std.mem.indexOf(u8, body, "\"tools\"") == null) {
        _ = state.ro_requests.fetchAdd(1, .acq_rel);
    }
    if (wants_nest and !ran_tool) _ = state.nest_requests.fetchAdd(1, .acq_rel);

    const payload = if (ran_tool)
        "data: {\"choices\":[{\"delta\":{\"content\":\"SUB-DONE\"},\"finish_reason\":null}]}\n\n" ++
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
            "data: [DONE]\n\n"
    else if (wants_task)
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"t1\",\"function\":{\"name\":\"task\",\"arguments\":\"{\\\"tasks\\\":[{\\\"description\\\":\\\"leg one\\\"},{\\\"description\\\":\\\"leg two\\\"}]}\"}}]},\"finish_reason\":null}]}\n\n" ++
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
            "data: [DONE]\n\n"
    else if (wants_nest)
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"n1\",\"function\":{\"name\":\"task\",\"arguments\":\"{\\\"description\\\":\\\"NEST-ME deeper\\\"}\"}}]},\"finish_reason\":null}]}\n\n" ++
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
            "data: [DONE]\n\n"
    else
        // subagent 的第一轮:跑一个真工具,父 agent 才有中间事件可看
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"b1\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"echo inner\\\"}\"}}]},\"finish_reason\":null}]}\n\n" ++
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
            "data: [DONE]\n\n";

    // 必须声明 close:这个 mock 每连接只处理一个请求,而 httpc 的连接池
    // 默认 keep_alive,复用到已关闭的连接就是 HttpConnectionClosing。
    req.respond(payload, .{
        .status = .ok,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
    }) catch return;
}

fn subMockMain(state: *SubMock) void {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", state.port) catch return;
    var server = addr.listen(util.io, .{ .reuse_address = true }) catch return;
    defer server.deinit(util.io);
    util.setNonBlock(server.socket.handle);
    var pfds = [_]std.posix.pollfd{.{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    while (!state.stop.load(.acquire)) {
        const n = std.posix.poll(&pfds, 10) catch continue;
        if (n == 0) continue;
        const raw = std.os.linux.accept4(server.socket.handle, null, null, 0o2000000);
        const rc = @as(isize, @bitCast(raw));
        if (rc < 0) continue;
        // 每连接一线程:并行 subagent 的请求必须能同时处理,串行 accept-handle
        // 会把它们排成队,测出来的是 mock 的极限而不是 piz 的
        const th = std.Thread.spawn(.{}, subMockHandle, .{ state, @as(std.posix.fd_t, @intCast(rc)) }) catch {
            subMockHandle(state, @intCast(rc));
            continue;
        };
        th.detach();
    }
}

/// 收集父 agent 看到的 subagent 事件。
const SubSpy = struct {
    mutex: std.Io.Mutex = .init,
    tool_starts: u32 = 0,
    tool_dones: u32 = 0,
    finished: u32 = 0,
    /// 见过的最大任务序号 —— 每一路都得有自己的编号,否则界面上分不清
    max_idx: usize = 0,

    fn onEvent(ctx: ?*anyopaque, idx: usize, kind: agentmod.SubagentEvent, text: []const u8) anyerror!void {
        _ = text;
        const self: *SubSpy = @ptrCast(@alignCast(ctx.?));
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        self.max_idx = @max(self.max_idx, idx);
        switch (kind) {
            .tool_start => self.tool_starts += 1,
            .tool_done => self.tool_dones += 1,
            .finished => self.finished += 1,
            else => {},
        }
    }
};

test "in-process subagents report progress and inherit the right identity" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    submock_alloc = a;

    var state = SubMock{ .port = 18731 };
    const server_thread = try std.Thread.spawn(.{}, subMockMain, .{&state});
    defer {
        state.stop.store(true, .release);
        server_thread.join();
    }
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 60 * std.time.ns_per_ms }, .awake) catch {};

    var cfg = cfgmod.Config{ .arena = &arena };
    var provs = [_]cfgmod.Provider{.{
        .name = "mock",
        .api = .openai_completions,
        .base_url = "http://127.0.0.1:18731",
        .api_key = "k",
    }};
    cfg.providers = &provs;

    // 父 agent 带 task 工具
    var spy = SubSpy{};
    var parent = try agentmod.Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{
        .plugins = pluginsmod.withEnabled(0, "task-delegation"),
    });
    parent.cbs = .{ .ctx = &spy, .on_subagent = SubSpy.onEvent };

    defer pluginsmod.shutdownAgents();
    const result = try parent.send("SPLIT-ME into two");
    try t.expect(result.error_msg == null);

    // 两路 subagent 都跑完,且父 agent 拿到了最终答复
    var tool_msg: []const u8 = "";
    for (parent.messages.items) |m| {
        if (std.mem.eql(u8, m.role, "tool")) tool_msg = m.content;
    }
    try t.expect(std.mem.indexOf(u8, tool_msg, "2 succeeded") != null);
    try t.expect(std.mem.indexOf(u8, tool_msg, "SUB-DONE") != null);

    // **本次改造的核心:中间过程可见。**
    // 子进程路径下委派是纯黑盒 —— 父 agent join() 干等,只能拿到最终文本。
    // 进程内跑之后 subagent 的每次工具调用都实时转发出来。
    try t.expect(spy.tool_starts >= 2);
    try t.expect(spy.tool_dones >= 2);
    try t.expectEqual(@as(u32, 2), spy.finished);
    // 每一路有自己的序号,否则界面上两路事件混成一团
    try t.expectEqual(@as(usize, 2), spy.max_idx);

    // subagent 没有真的 spawn 进程 —— 它们跑在本进程的线程里。
    // 校验方式:mock 看到的请求里既有带 tools 的(subagent 有工具),
    // 又都来自同一个进程(否则 e2e 里根本连不上这个 mock:
    // 子进程走的是 piz 可执行文件,那需要 API key 与真配置文件)。
    try t.expect(state.ro_requests.load(.acquire) == 0);
}

test "sub-agent identity: depth increments, read-only only tightens" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg = cfgmod.Config{ .arena = &arena };
    var provs = [_]cfgmod.Provider{.{
        .name = "mock",
        .api = .openai_completions,
        .base_url = "http://127.0.0.1:1",
        .api_key = "k",
    }};
    cfg.providers = &provs;

    // 只读父 agent 的 subagent 必然只读 —— 否则委派就是一条提权通道
    const ro_parent = try agentmod.Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{ .read_only = true });
    try t.expect(ro_parent.read_only);

    // 深度是 Agent 字段而非环境变量:进程内 subagent 没有新进程可继承环境
    const deep = try agentmod.Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{ .depth = 1 });
    try t.expectEqual(@as(usize, 1), deep.depth);
    const deeper = try agentmod.Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{ .depth = deep.depth + 1 });
    try t.expectEqual(@as(usize, 2), deeper.depth);

    // 启用集是 per-Agent:一个 Agent 开了插件不会影响另一个
    const with_task = try agentmod.Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{
        .plugins = pluginsmod.withEnabled(0, "task-delegation"),
    });
    const without = try agentmod.Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{ .plugins = 0 });
    try t.expect(pluginsmod.findToolIn(with_task.plugins, "task") != null);
    try t.expect(pluginsmod.findToolIn(without.plugins, "task") == null);
}

test "nested in-process delegation is stopped by the depth gate" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    submock_alloc = a;

    var state = SubMock{ .port = 18732 };
    const server_thread = try std.Thread.spawn(.{}, subMockMain, .{&state});
    defer {
        state.stop.store(true, .release);
        server_thread.join();
    }
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 60 * std.time.ns_per_ms }, .awake) catch {};

    var cfg = cfgmod.Config{ .arena = &arena };
    var provs = [_]cfgmod.Provider{.{
        .name = "mock",
        .api = .openai_completions,
        .base_url = "http://127.0.0.1:18732",
        .api_key = "k",
    }};
    cfg.providers = &provs;

    // 孩子默认不继承 task-delegation,所以再派会被「没有这个工具」拦住。
    // 深度闸门仍在:显式 plugins:["task-delegation"] 时靠 depth 字段封顶。
    // 本测试跑得完本身就是不再无限递归的证据。
    var parent = try agentmod.Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{
        .plugins = pluginsmod.withEnabled(pluginsmod.factorySet(), "task-delegation"),
    });
    defer pluginsmod.shutdownAgents();
    const result = try parent.send("NEST-ME once");
    try t.expect(result.error_msg == null);

    // 有界:每轮工具循环最多派一次,不会指数增长
    try t.expect(state.nest_requests.load(.acquire) <= 64);

    // 顶层派出的那一路必须跑完(闸门只该拦更深的一层,不该让整条委派失败)
    var saw_task_result = false;
    for (parent.messages.items) |m| {
        if (std.mem.eql(u8, m.role, "tool") and std.mem.indexOf(u8, m.content, "=== ") != null) {
            saw_task_result = true;
        }
    }
    try t.expect(saw_task_result);

    // 深度闸门的错误文本本身由 plugins.zig 的单元测试守着 —— 它在 subagent
    // 内部,父 agent 只看到那一路的最终答复。这里守的是「递归会停」。
}

test "read_image compresses and attaches the image to the next request" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    pluginsmod.resetEnabledForTest();
    try t.expect(pluginsmod.enable("vision-input"));
    defer pluginsmod.resetEnabledForTest();

    // 1×1 红色 PNG(69 字节):走 min_dim 放大路径 → 200×200 重编码
    const png = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 0, 0, 3, 1, 1, 0, 201, 254, 146, 239, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130 };
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = "/tmp/piz-img-e2e.png", .data = &png });

    const url_buf = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1/chat/completions", .{MOCK_PORT3});
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = url_buf }};
    var cfg = cfgmod.Config{ .arena = &arena };
    cfg.providers = &provs;
    cfg.default_provider = "mock";
    cfg.default_model = "mock-vision";

    var state = MockState{ .alloc = std.heap.page_allocator, .port = MOCK_PORT3, .vision_mode = true };
    const thread = try std.Thread.spawn(.{}, mockServerMain, .{&state});
    var ready = false;
    for (0..50) |_| {
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", MOCK_PORT3) catch break;
        var s = addr.connect(util.io, .{ .mode = .stream, .protocol = .tcp }) catch {
            _ = std.Io.sleep(util.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
            continue;
        };
        s.close(util.io);
        ready = true;
        break;
    }
    try t.expect(ready);
    defer state.stop.store(true, .release);

    var agent = try agentmod.Agent.initOpts(a, &cfg, "mock", "mock-vision", "/tmp", .{});
    const result = try agent.send("look at /tmp/piz-img-e2e.png and describe it");
    try t.expect(std.mem.indexOf(u8, result.text, "IMG-OK") != null);
    // 第二轮请求体带 data URI 图片附件
    try t.expect(state.req_had_image.load(.acquire));
    try t.expect(state.req_image_data_ok.load(.acquire));
    // 消息历史里有图片消息(附在 user 消息上),且 token 估算计入图片
    var found = false;
    for (agent.messages.items) |m| {
        if (m.image != null) {
            found = true;
            try t.expect(m.image_w >= 200); // 1×1 被放大到 min_dim
        }
    }
    try t.expect(found);
    // 清理:先停服再 join(server 循环看 stop 才退出)
    state.stop.store(true, .release);
    thread.join();
    std.Io.Dir.cwd().deleteFile(util.io, "/tmp/piz-img-e2e.png") catch {};
}

test "Responses API: function_call events and input items round trip" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    pluginsmod.resetEnabledForTest();
    defer pluginsmod.resetEnabledForTest();

    // endpointUrl 会拼 /v1/responses —— base_url 只传主机
    const url_buf = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{MOCK_PORT4});
    var provs = [_]cfgmod.Provider{.{ .name = "mockr", .api = .openai_responses, .base_url = url_buf }};
    var cfg = cfgmod.Config{ .arena = &arena };
    cfg.providers = &provs;
    cfg.default_provider = "mockr";
    cfg.default_model = "mock-model";

    var state = MockState{ .alloc = std.heap.page_allocator, .port = MOCK_PORT4, .responses_mode = true };
    const thread = try std.Thread.spawn(.{}, mockServerMain, .{&state});
    var ready = false;
    for (0..50) |_| {
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", MOCK_PORT4) catch break;
        var s = addr.connect(util.io, .{ .mode = .stream, .protocol = .tcp }) catch {
            _ = std.Io.sleep(util.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
            continue;
        };
        s.close(util.io);
        ready = true;
        break;
    }
    try t.expect(ready);
    defer state.stop.store(true, .release);

    var agent = try agentmod.Agent.initOpts(a, &cfg, "mockr", "mock-model", "/tmp", .{});
    const result = agent.send("run the marker command") catch |e| {
        std.debug.print("send failed: {s} url={s}\n", .{ @errorName(e), url_buf });
        return error.TestUnexpectedResult;
    };
    try t.expect(std.mem.indexOf(u8, result.text, "RESP-OK") != null);
    try t.expect(state.responses_input_ok.load(.acquire));
    try t.expect(state.responses_call_output_ok.load(.acquire));
    state.stop.store(true, .release);
    thread.join();
}

test "mcp: parse tool name (first __ after prefix)" {
    const p = mcpmod.parseToolName("mcp__my_srv__do_it") orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("my_srv", p.server);
    try std.testing.expectEqualStrings("do_it", p.tool);
    try std.testing.expect(mcpmod.parseToolName("bash") == null);
    try std.testing.expect(mcpmod.parseToolName("mcp__only") == null);
}

test "mcp: formatStatus when none configured" {
    const t = std.testing;
    const out = try mcpmod.formatStatus(t.allocator);
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, "no mcp servers") != null);
}

test "mcp: script server roundtrip (stdout streaming + tool dispatch)" {
    try mcpmod.runScriptServerTest(std.testing);
}
