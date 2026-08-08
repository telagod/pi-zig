// httpc.zig — std.http 流式客户端封装:POST JSON,逐行读流(SSE)。
const std = @import("std");
const util = @import("util.zig");
const activity = @import("activity.zig");

pub const Header = std.http.Header;

/// 进程级共享 HTTP 客户端。
///
/// 为什么要共享:agent 的一轮对话会连发多次请求(工具循环上限 24 轮,每轮一次
/// provider 调用)。每次新建 std.http.Client 就是每次新建 TCP + 重做 TLS 握手 ——
/// 实测对 api.deepseek.com 约 220ms/次,8 轮迭代白扔 1.76 秒。复用连接后稳态
/// 降到 70-90ms/次。
///
/// 为什么是全局而非按 Agent 持有:连接池的价值在跨请求存活,而 Agent 可能被
/// 重建(切模型、续会话);且同一 host 的连接对所有 Agent 等价。
///
/// **allocator 必须由池自己拥有,不能借调用方的。** 池的寿命是进程级,而调用方
/// 的 allocator 可能是 arena(e2e 测试就是)或会话级分配器 —— 借来的 allocator
/// 一旦释放,池里的连接就持有悬垂指针,下一次请求在 Client.connectTcp 里段错误。
/// 这是实际踩过的坑,不是理论风险。page_allocator 无状态、进程级有效、线程安全。
///
/// 线程安全:std.http.Client 的连接池自身不保证并发安全,故所有取用走 mutex。
/// 当前 ai.run 只在主循环调用(工具并行不涉及 provider 请求),锁几乎不竞争;
/// 加锁是为了将来真出现并发调用时不会静默损坏连接池。
const ClientPool = struct {
    var mutex: std.Io.Mutex = .init;
    var client: ?std.http.Client = null;

    fn acquire() *std.http.Client {
        if (client == null) {
            client = .{ .allocator = std.heap.page_allocator, .io = util.io };
        }
        return &client.?;
    }

    /// 丢弃整个池(连接层错误后调用:池里可能残留半死连接)。
    /// 下次 acquire 会重建。
    fn reset() void {
        if (client) |*c| c.deinit();
        client = null;
    }
};

/// 释放共享连接池。进程退出前调用(可选:OS 会回收 fd)。
/// 测试里用它清掉跨测试残留的连接。
pub fn deinitPool() void {
    ClientPool.mutex.lockUncancelable(util.io);
    defer ClientPool.mutex.unlock(util.io);
    ClientPool.reset();
}

/// 重试策略。仅用于「连接建立 + 收到响应头」阶段;流式一旦开始就绝不重试。
pub const RetryPolicy = struct {
    enabled: bool = true,
    max_retries: u8 = 3,
    base_delay_ms: u32 = 500,
    /// Retry-After 上限:provider 偶尔给出离谱值(几百秒),不能让 agent 干等。
    max_retry_after_s: u32 = 30,
};

/// 可重试的 HTTP 状态码:限流与服务端瞬时故障。
/// 4xx(除 429)不重试 —— 认证失败、参数错误重试多少次都一样。
pub fn isRetryableStatus(status: u16) bool {
    return switch (status) {
        429, 500, 502, 503, 504 => true,
        else => false,
    };
}

/// 可重试的连接层错误:网络抖动、DNS 瞬时失败、连接被拒/被重置。
/// TLS 证书错误与 URL 解析错误不重试(重试不会让它们变好)。
pub fn isRetryableError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.HostLacksNetworkAddresses,
        error.EndOfStream,
        error.BrokenPipe,
        error.WriteFailed,
        error.ReadFailed,
        => true,
        else => false,
    };
}

/// 解析 Retry-After 头(仅支持秒数形式;HTTP-date 形式忽略)。
/// 返回封顶后的秒数,无效则 null。
pub fn parseRetryAfterSeconds(raw: ?[]const u8, cap_s: u32) ?u32 {
    const v = raw orelse return null;
    const trimmed = std.mem.trim(u8, v, " \t\r\n");
    if (trimmed.len == 0) return null;
    const n = std.fmt.parseInt(u32, trimmed, 10) catch return null;
    return @min(n, cap_s);
}

/// 指数退避延迟:base * 2^attempt,叠加确定性抖动,并封顶。
/// attempt 从 0 起。抖动用 attempt 派生而非随机数 —— 便于测试,且足够打散并发请求。
pub fn computeBackoffMs(policy: RetryPolicy, attempt: u8, retry_after_s: ?u32) u32 {
    if (retry_after_s) |s| return s * 1000;
    const shift: u5 = @intCast(@min(attempt, 10));
    const base = policy.base_delay_ms *| (@as(u32, 1) << shift);
    const jitter = (@as(u32, attempt) * 37) % 250;
    return @min(base + jitter, policy.max_retry_after_s * 1000);
}

/// 中断查询回调:退避等待期间轮询,返回 true 立即放弃重试。
pub const AbortFn = *const fn (ctx: ?*anyopaque) bool;

/// 可中断睡眠:切成 50ms 片轮询 abort,避免长 sleep 吞掉用户的 Ctrl+C。
///
/// 顺带把剩余秒数刷进活动详情 —— 退避最长约 30 秒,一个不动的界面配一句
/// 「backoff 8.0s」不够,用户要看到数字在减少才相信它在推进。
/// 同时响应 activity 层的取消:Ctrl+C 提升世代后这里立刻放弃,
/// 不必等 agent 的 aborted 标志传导过来。
fn sleepInterruptible(total_ms: u32, abort_fn: ?AbortFn, abort_ctx: ?*anyopaque, act: activity.Handle, prefix: []const u8) bool {
    const SLICE_MS = 50;
    var slept: u32 = 0;
    var last_shown: u32 = 0;
    while (slept < total_ms) {
        if (abort_fn) |f| {
            if (f(abort_ctx)) return false;
        }
        if (act.cancelled()) return false;
        // 每 500ms 刷一次倒计时(spinner 帧率是 100ms,刷太勤是噪音)
        const remain = total_ms - slept;
        if (slept == 0 or slept - last_shown >= 500) {
            last_shown = slept;
            var buf: [72]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{s} · retrying in {d}.{d}s", .{ prefix, remain / 1000, (remain % 1000) / 100 }) catch prefix;
            act.detail(s);
        }
        const chunk = @min(SLICE_MS, total_ms - slept);
        _ = std.Io.sleep(util.io, .{ .nanoseconds = @as(u64, chunk) * std.time.ns_per_ms }, .awake) catch return false;
        slept += chunk;
    }
    return true;
}

/// 退避原因的短前缀,拼进活动详情让用户看到「为什么在等」。
/// 写进调用方的栈 buffer:重试路径不该分配,而且这里正处在失败恢复中。
fn backoffReason(buf: []u8, status: u16) []const u8 {
    const reason: []const u8 = switch (status) {
        429 => "rate limited",
        500, 502, 503, 504 => "server error",
        else => "retrying",
    };
    return std.fmt.bufPrint(buf, "HTTP {d} {s}", .{ status, reason }) catch reason;
}

/// 带重试的请求。返回已收到响应头的 Stream。
///
/// **重试窗口严格限定在「连接 + receiveHead + 状态码判定」阶段。**
/// 一旦返回,调用方开始读流并向用户吐 token,就绝不能再重试 —— 否则用户会看到
/// 重复输出。因此本函数内部在拿到不可重试的状态码(含 2xx)后立刻返回。
pub fn requestWithRetry(
    alloc: std.mem.Allocator,
    url: []const u8,
    headers: []const Header,
    body: []const u8,
    policy: RetryPolicy,
    abort_fn: ?AbortFn,
    abort_ctx: ?*anyopaque,
) !*Stream {
    var attempt: u8 = 0;
    // 登记活动:重试 + 退避最长能到约 90 秒,原先这段时间界面完全静止,
    // 用户无法区分「在退避重试」和「网络挂死」。attempt/detail 让它可见。
    const act = activity.begin(.http, "model", "connecting", 0);
    defer act.release();
    while (true) {
        if (abort_fn) |f| {
            if (f(abort_ctx)) return error.Canceled;
        }
        act.attempt(@as(u32, attempt) + 1);
        const maybe_stream = Stream.init(alloc, url, headers, body);
        if (maybe_stream) |stream| {
            const st = stream.status();
            // 成功或不可重试的错误码:直接交给调用方(它会解析 body 里的错误消息)
            if (!isRetryableStatus(st)) return stream;
            if (!policy.enabled or attempt >= policy.max_retries) return stream;
            // 可重试:取 Retry-After 后丢弃这条连接,退避再来
            const ra = parseRetryAfterSeconds(stream.retryAfter(), policy.max_retry_after_s);
            stream.deinit();
            const delay = computeBackoffMs(policy, attempt, ra);
            var rbuf: [40]u8 = undefined;
            if (!sleepInterruptible(delay, abort_fn, abort_ctx, act, backoffReason(&rbuf, st))) return error.Canceled;
            attempt += 1;
            continue;
        } else |err| {
            if (!policy.enabled or attempt >= policy.max_retries or !isRetryableError(err)) return err;
            const delay = computeBackoffMs(policy, attempt, null);
            if (!sleepInterruptible(delay, abort_fn, abort_ctx, act, @errorName(err))) return error.Canceled;
            attempt += 1;
            continue;
        }
    }
}

/// 从原始 head 字节里取某个响应头的值并 dup(0.16 的 Head 无 headers 迭代器)。
/// name 须为小写;比较大小写不敏感。
fn dupeHeaderValue(alloc: std.mem.Allocator, head_bytes: []const u8, name: []const u8) !?[]u8 {
    var it = std.mem.splitSequence(u8, head_bytes, "\r\n");
    _ = it.next(); // 状态行
    while (it.next()) |line| {
        if (line.len == 0) break; // 头结束
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, name)) continue;
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (val.len == 0) return null;
        return try alloc.dupe(u8, val);
    }
    return null;
}

pub const Stream = struct {
    alloc: std.mem.Allocator,
    req: std.http.Client.Request,
    response: std.http.Client.Response,
    /// 从 response head 构建的 body reader(takeDelimiter 等)。
    reader: *std.Io.Reader,
    /// head 指针在 body 流初始化后失效,故 init 时拷贝。
    content_type: ?[]u8,
    /// Retry-After 头(429/503 时 provider 给出的建议等待秒数);同样需 init 时拷贝。
    retry_after: ?[]u8 = null,
    /// body 接口的传输缓冲(必须非空,takeDelimiter 依赖它)
    transfer_buffer: [8192]u8 = undefined,

    pub fn init(alloc: std.mem.Allocator, url: []const u8, headers: []const Header, body: []const u8) !*Stream {
        const self = try alloc.create(Stream);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .req = undefined, .response = undefined, .content_type = null, .retry_after = null, .reader = undefined };

        // 共享 client:连接与 TLS 会话跨请求复用(见 ClientPool 注释)。
        // client 活在全局,不随 Stream 销毁 —— 故无需像从前那样把连接的 client
        // 指针重指到拷贝体(那是 client 在栈上时才有的问题)。
        //
        // 锁持有到函数返回:请求发送与响应头读取都在锁内。这确实会串行化并发
        // 请求,但当前 ai.run 只在主循环调用,无竞争;换来的是绝不会有两个线程
        // 同时动同一个连接池。真要支持并发请求,应改成每 host 一个池 + 细粒度锁。
        ClientPool.mutex.lockUncancelable(util.io);
        const client = ClientPool.acquire();
        defer ClientPool.mutex.unlock(util.io);

        const uri = try std.Uri.parse(url);
        var req = client.request(.POST, uri, .{
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = headers,
            // 复用的前提。false 会让 std 在响应结束后关闭连接。
            .keep_alive = true,
        }) catch |e| {
            // 连接层失败:池里可能残留半死连接,整池丢弃让下次重建。
            ClientPool.reset();
            return e;
        };
        errdefer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        var bw = try req.sendBodyUnflushed(&.{});
        try bw.writer.writeAll(body);
        try bw.end();
        try req.connection.?.flush();

        var redirect_buf: [1024]u8 = undefined;
        const response = try req.receiveHead(&redirect_buf);
        // 必须在 bodyReader 之前拷贝(head 指针其后失效)
        const ct = if (response.head.content_type) |t| try alloc.dupe(u8, t) else null;
        // Retry-After 不在 head 的结构化字段里,从原始 head buffer 里取
        const ra = try dupeHeaderValue(alloc, response.head.bytes, "retry-after");
        self.req = req;
        self.response = response;
        // 关键:receiveHead 返回的 response.request 指向局部 req(栈上),
        // 必须重指向拷贝后的 self.req,否则 reader 悬垂(0.16 语义)。
        self.response.request = &self.req;
        self.content_type = ct;
        self.retry_after = ra;
        // 关键:reader 指针指向 self.req.reader.interface —— self 在堆上,指针稳定
        self.reader = self.response.reader(&self.transfer_buffer);
        return self;
    }

    pub fn status(self: *const Stream) u16 {
        return @intFromEnum(self.response.head.status);
    }

    /// Retry-After 头原始值(init 时拷贝),无该头返回 null。
    pub fn retryAfter(self: *const Stream) ?[]const u8 {
        return self.retry_after;
    }

    /// 打断阻塞中的读(中断用):shutdown 本请求连接的收方向,阻塞读即返 EOF/错误。
    ///
    /// 从前要扫整个连接池,因为 client 是 Stream 私有的;现在 client 共享,
    /// 扫全池会误伤别的请求 —— 直接用 req.connection 精确打断这一条。
    pub fn abortRead(self: *Stream) void {
        if (self.req.connection) |conn| {
            conn.stream_reader.stream.shutdown(util.io, .recv) catch {};
        }
    }

    /// 读一行(不含换行符),EOF 返回 null。
    pub fn readLine(self: *Stream) !?[]u8 {

        // 注意:takeDelimiterExclusive 不消费 delimiter(0.15.2 std 坑),
        // 遇连续 \n 会死循环。改用 takeDelimiter(inclusive, 消费 \n)。
        const raw = (try self.reader.takeDelimiter('\n')) orelse return null;
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        return @as(?[]u8, try self.alloc.dupe(u8, trimmed));
    }

    /// 读取全部响应体。
    pub fn readAll(self: *Stream, max: usize) ![]u8 {
        return self.reader.allocRemaining(self.alloc, .limited(max));
    }

    pub fn deinit(self: *Stream) void {
        if (self.content_type) |ct| self.alloc.free(ct);
        if (self.retry_after) |ra| self.alloc.free(ra);
        // req.deinit 把连接还给共享池(keep_alive=true 且响应读完时),
        // 或在连接已不可复用时关掉它。client 本身不销毁 —— 它是进程级的。
        self.req.deinit();
        self.alloc.destroy(self);
    }
};

/// 简单 SSE 解析:按行消费,返回 data 载荷(累积多行 data:),[DONE] 返回 null。
pub const SseParser = struct {
    stream: *Stream,
    pending: std.array_list.Managed(u8),
    done: bool = false,

    pub fn init(stream: *Stream) SseParser {
        return .{ .stream = stream, .pending = std.array_list.Managed(u8).init(stream.alloc) };
    }

    pub fn deinit(self: *SseParser) void {
        self.pending.deinit();
    }

    /// 返回下一条 data 载荷(不含 "data:" 前缀)。无更多事件返回 null。
    pub fn nextEvent(self: *SseParser) !?[]const u8 {
        while (!self.done) {
            const line = (try self.stream.readLine()) orelse {
                self.done = true;
                if (self.pending.items.len > 0) {
                    const out = try self.stream.alloc.dupe(u8, self.pending.items);
                    self.pending.clearRetainingCapacity();
                    return out;
                }
                return null;
            };
            defer self.stream.alloc.free(line);
            if (line.len == 0) {
                // 空行:事件结束
                if (self.pending.items.len > 0) {
                    const out = try self.stream.alloc.dupe(u8, self.pending.items);
                    self.pending.clearRetainingCapacity();
                    return out;
                }
                continue;
            }
            if (std.mem.startsWith(u8, line, "data:")) {
                var payload = line["data:".len..];
                if (payload.len > 0 and payload[0] == ' ') payload = payload[1..];
                if (std.mem.eql(u8, payload, "[DONE]")) {
                    self.done = true;
                    self.pending.clearRetainingCapacity();
                    return null;
                }
                if (self.pending.items.len > 0) try self.pending.append('\n');
                try self.pending.appendSlice(payload);
            }
            // 其他行(event:, :comment)忽略
        }
        return null;
    }
};

test "retryable status classification" {
    const t = std.testing;
    // 限流与服务端瞬时故障:重试
    for ([_]u16{ 429, 500, 502, 503, 504 }) |s| {
        try t.expect(isRetryableStatus(s));
    }
    // 成功与客户端错误:不重试(认证失败/参数错误重试无意义)
    for ([_]u16{ 200, 201, 204, 400, 401, 403, 404, 409, 422 }) |s| {
        try t.expect(!isRetryableStatus(s));
    }
}

test "retryable error classification" {
    const t = std.testing;
    try t.expect(isRetryableError(error.ConnectionRefused));
    try t.expect(isRetryableError(error.ConnectionResetByPeer));
    try t.expect(isRetryableError(error.TemporaryNameServerFailure));
    // TLS/URL 类错误重试不会变好
    try t.expect(!isRetryableError(error.CertificateBundleLoadFailure));
    try t.expect(!isRetryableError(error.OutOfMemory));
}

test "Retry-After parsing and capping" {
    const t = std.testing;
    try t.expectEqual(@as(?u32, 5), parseRetryAfterSeconds("5", 30));
    try t.expectEqual(@as(?u32, 12), parseRetryAfterSeconds("  12  ", 30));
    // 离谱值必须封顶,否则 agent 会干等几分钟
    try t.expectEqual(@as(?u32, 30), parseRetryAfterSeconds("600", 30));
    // HTTP-date 形式不支持 → null(退回指数退避)
    try t.expectEqual(@as(?u32, null), parseRetryAfterSeconds("Wed, 21 Oct 2015 07:28:00 GMT", 30));
    try t.expectEqual(@as(?u32, null), parseRetryAfterSeconds("", 30));
    try t.expectEqual(@as(?u32, null), parseRetryAfterSeconds(null, 30));
}

test "backoff grows exponentially and respects Retry-After" {
    const t = std.testing;
    const p = RetryPolicy{ .base_delay_ms = 500, .max_retry_after_s = 30 };
    // 指数增长:500 / 1000 / 2000(加上小抖动)
    const d0 = computeBackoffMs(p, 0, null);
    const d1 = computeBackoffMs(p, 1, null);
    const d2 = computeBackoffMs(p, 2, null);
    try t.expect(d0 >= 500 and d0 < 750);
    try t.expect(d1 >= 1000 and d1 < 1250);
    try t.expect(d2 >= 2000 and d2 < 2250);
    try t.expect(d1 > d0 and d2 > d1);
    // Retry-After 优先于计算值
    try t.expectEqual(@as(u32, 7000), computeBackoffMs(p, 0, 7));
    // 高 attempt 不溢出,且被 max_retry_after_s 封顶
    try t.expectEqual(@as(u32, 30_000), computeBackoffMs(p, 20, null));
}

test "header value extraction from raw head bytes" {
    const t = std.testing;
    const head = "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nRetry-After: 3\r\n\r\n";
    const v = try dupeHeaderValue(t.allocator, head, "retry-after");
    try t.expect(v != null);
    defer t.allocator.free(v.?);
    try t.expectEqualStrings("3", v.?);
    // 不存在的头 → null
    const miss = try dupeHeaderValue(t.allocator, head, "x-nope");
    try t.expectEqual(@as(?[]u8, null), miss);
}
