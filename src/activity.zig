// activity.zig — 进程级「现在正在干什么」登记表。
//
// 为什么需要它:piz 原先只有「工具开始」「工具结束」两个瞬间的回调,中间是虚空。
// 一条 300 秒的 bash、一次 90 秒的 HTTP 退避重试、一个 10 分钟的子 agent 委派,
// 用户看到的都是同一帧静止画面 —— 没有任何办法区分「在干活」和「挂死了」。
//
// 一张登记表同时解决四件事:
//   1. TUI 定时读它,渲染 spinner + 计时 + 字节进度(看得到在干活)
//   2. Ctrl+C 提升 cancel 世代,深层循环(pumpPipes、退避 sleep)自己发现后退出
//   3. 并行活动各占一个槽位,8 个同名 `read` 也能分辨
//   4. 超时的长命令可以转后台:槽位标记 detached,前台不再等它
//
// 无锁:槽位是固定数组,登记用 CAS 抢占。名称/详情写进定长 buffer,靠 `active`
// 的 release/acquire 顺序保证读端看到的是写完的内容。渲染绝不能去拿锁 ——
// 那会让 UI 线程被工具线程拖住,正是这个模块要消灭的病。
const std = @import("std");
const util = @import("util.zig");

/// 槽位数 = MAX_PARALLEL_TOOLS(8) + 委派并发(32) + HTTP/余量。
/// 满了仍会登记(句柄自带 gen/start_ms,取消与耗时照常),只是不显示 ——
/// 少一行显示可以接受,为此阻塞工具执行不行。
///
/// plugins.zig 有 comptime 断言挡住「提了 MAX_PARALLEL_TASKS 忘了提这里」。
/// 每个槽位约 200 字节静态数组,48 个不到 10KB,不值得为省这点动态分配。
pub const MAX_SLOTS = 48;

pub const Kind = enum(u8) {
    tool,
    /// 模型请求(含重试与退避等待)。
    http,
    /// 委派出去的子 agent 进程。
    subagent,
};

pub const NAME_CAP = 24; // 最长工具名 get_context_remaining = 21
pub const DETAIL_CAP = 72;

const Slot = struct {
    /// 槽位已被占用(写内容**前**置位,防两个线程抢同一槽)。
    claimed: std.atomic.Value(bool) = .init(false),
    /// 内容已写完、对读端可见(写内容**后**置位)。渲染只看这个。
    active: std.atomic.Value(bool) = .init(false),
    kind: std.atomic.Value(u8) = .init(0),
    start_ms: std.atomic.Value(i64) = .init(0),
    /// 已搬运字节数(bash 输出、子 agent 输出)。0 = 不适用。
    bytes: std.atomic.Value(u64) = .init(0),
    /// 第几次尝试(HTTP 重试)。0 = 不显示。
    attempt: std.atomic.Value(u32) = .init(0),
    /// 墙钟上限(毫秒),用于显示「12s/30s」。0 = 无上限。
    limit_ms: std.atomic.Value(i64) = .init(0),
    /// 已转后台:前台不再等待,活动仍在跑。
    detached: std.atomic.Value(bool) = .init(false),
    /// 子进程 pid(bash 后台)。0 = 无。
    pid: std.atomic.Value(i32) = .init(0),
    /// 登记时的 cancel 世代。世代被提升即表示这个活动该停。
    gen: std.atomic.Value(u32) = .init(0),
    name_len: std.atomic.Value(u8) = .init(0),
    detail_len: std.atomic.Value(u8) = .init(0),
    name_buf: [NAME_CAP]u8 = @splat(0),
    detail_buf: [DETAIL_CAP]u8 = @splat(0),
};

var slots: [MAX_SLOTS]Slot = @splat(.{});

/// 取消世代。Ctrl+C 提升它 —— 只取消当时在跑的活动,之后新起的不受影响,
/// 否则用户中断一次就得重启进程。
var cancel_gen: std.atomic.Value(u32) = .init(0);

fn nowMs() i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.awake, util.io).nanoseconds, std.time.ns_per_ms));
}

/// 活动句柄。没抢到槽位时是 `none` —— 显示类方法(progress/attempt/detail)
/// 变空操作,但 `cancelled()` 与 `elapsedMs()` **照常工作**。
///
/// 这两个不能依赖槽位:调用方靠 `cancelled()` 决定要不要中止(pumpPipes 就是
/// 这么做的),槽位满员时返回 false 意味着 Ctrl+C 对这个活动完全无效 —— 一个
/// 委派出去的 subagent 会跑满 10 分钟超时。`elapsedMs()` 返回 0 则让模型
/// 以为任务瞬间完成。所以 gen 和 start_ms 都存在句柄自身里。
pub const Handle = struct {
    idx: usize = MAX_SLOTS,
    gen: u32 = 0,
    /// 句柄自带的开始时间,与槽位无关。0 = 未登记(Handle.none 的默认值)。
    start_ms: i64 = 0,

    pub const none = Handle{};

    /// 更新已搬运字节数(显示用)。
    pub fn progress(self: Handle, bytes: u64) void {
        if (self.idx >= MAX_SLOTS) return;
        slots[self.idx].bytes.store(bytes, .monotonic);
    }

    /// 更新尝试次数(HTTP 重试第几次)。
    pub fn attempt(self: Handle, n: u32) void {
        if (self.idx >= MAX_SLOTS) return;
        slots[self.idx].attempt.store(n, .monotonic);
    }

    /// 覆盖详情文字(阶段变化,如「retrying in 2s」)。
    /// 按 UTF-8 边界截断:曾硬切 DETAIL_CAP 字节,把 CJK 切在序列中间,
    /// 渲染端出「调�」坏字。
    pub fn detail(self: Handle, text: []const u8) void {
        if (self.idx >= MAX_SLOTS) return;
        const s = &slots[self.idx];
        const raw = std.mem.trim(u8, text, " \t\r");
        const n = util.clampUtf8(raw, DETAIL_CAP).len;
        @memcpy(s.detail_buf[0..n], raw[0..n]);
        s.detail_len.store(@intCast(n), .release);
    }

    /// 是否被取消(Ctrl+C 提升了世代)。深层循环靠它主动退出。
    ///
    /// 不看槽位:`gen` 在句柄里,槽位满员的活动同样要能被 Ctrl+C 停下。
    /// `Handle.none`(gen=0,start_ms=0)是唯一例外 —— 它从未登记过,
    /// 没有"被取消"可言。
    pub fn cancelled(self: Handle) bool {
        if (self.start_ms == 0) return false;
        return cancel_gen.load(.acquire) != self.gen;
    }

    /// 是否已被转后台。
    ///
    /// 这个确实依赖槽位:detachAll 只扫槽位,没有槽位就不可能被转后台。
    /// 保守返回 false —— 意味着它仍受 Ctrl+C 和墙钟上限约束,是安全的方向。
    pub fn isDetached(self: Handle) bool {
        if (self.idx >= MAX_SLOTS) return false;
        return slots[self.idx].detached.load(.acquire);
    }

    pub fn setPid(self: Handle, pid: i32) void {
        if (self.idx >= MAX_SLOTS) return;
        slots[self.idx].pid.store(pid, .release);
    }

    /// 单槽转后台。模型要 `background:true` 时只卸这一条,不动别的工具。
    pub fn detach(self: Handle) void {
        if (self.idx >= MAX_SLOTS) return;
        slots[self.idx].detached.store(true, .release);
    }

    /// 墙钟耗时。同样不看槽位 —— 回给模型的耗时不能因为槽位满就变成 0,
    /// 那会让它以为委派出去的任务瞬间完成。
    pub fn elapsedMs(self: Handle) i64 {
        if (self.start_ms == 0) return 0;
        return @max(0, nowMs() - self.start_ms);
    }

    pub fn release(self: Handle) void {
        if (self.idx >= MAX_SLOTS) return;
        // 先撤可见性,再放占位 —— 反过来的话另一个线程可能抢到槽并写内容,
        // 而渲染端还认为这里是上一个活动。
        slots[self.idx].active.store(false, .release);
        slots[self.idx].claimed.store(false, .release);
    }
};

/// 登记一个活动。`limit_ms` 为 0 表示无墙钟上限。
///
/// 抢不到槽位时返回一个**无槽句柄**:显示类方法变空操作,但取消与耗时
/// 照常工作。以前这里返回 `Handle.none`,于是溢出的活动既不响应 Ctrl+C
/// 也报告 0 耗时 —— 并发一旦超过 MAX_SLOTS 就成了正确性问题。
pub fn begin(kind: Kind, name: []const u8, det_in: []const u8, limit_ms: i64) Handle {
    const started = nowMs();
    const g = cancel_gen.load(.acquire);
    for (&slots, 0..) |*s, i| {
        // `claimed` 只做占位:CAS 成功即独占这个槽,但此刻内容还是上一次的残留。
        if (s.claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) continue;
        const nn = util.clampUtf8(name, NAME_CAP).len;
        @memcpy(s.name_buf[0..nn], name[0..nn]);
        s.name_len.store(@intCast(nn), .monotonic);
        const det = std.mem.trim(u8, det_in, " \t\r");
        const dn = util.clampUtf8(det, DETAIL_CAP).len;
        @memcpy(s.detail_buf[0..dn], det[0..dn]);
        s.detail_len.store(@intCast(dn), .monotonic);
        s.kind.store(@intFromEnum(kind), .monotonic);
        s.start_ms.store(started, .monotonic);
        s.bytes.store(0, .monotonic);
        s.attempt.store(0, .monotonic);
        s.limit_ms.store(limit_ms, .monotonic);
        s.detached.store(false, .monotonic);
        s.pid.store(0, .monotonic);
        s.gen.store(g, .monotonic);
        // 内容齐了才对读端可见。两个标志而非一个:占位必须在写之前(否则两个
        // 线程抢同一槽),发布必须在写之后(否则渲染读到 start_ms=0,
        // 算出来的耗时是整个系统启动时长)。
        s.active.store(true, .release);
        return .{ .idx = i, .gen = g, .start_ms = started };
    }
    // 无槽:不显示,但仍可取消、仍报告真实耗时
    return .{ .idx = MAX_SLOTS, .gen = g, .start_ms = started };
}

/// 取消当前全部在跑的活动(Ctrl+C)。返回被取消的活动数。
pub fn cancelAll() usize {
    var n: usize = 0;
    for (&slots) |*s| {
        if (s.active.load(.acquire) and !s.detached.load(.acquire)) n += 1;
    }
    _ = cancel_gen.fetchAdd(1, .acq_rel);
    return n;
}

/// 把当前全部在跑的活动转后台:它们继续跑,但不再被 Ctrl+C 取消,
/// 前台也不再显示为「等待中」。返回转后台的活动数。
pub fn detachAll() usize {
    var n: usize = 0;
    for (&slots) |*s| {
        if (!s.active.load(.acquire)) continue;
        if (s.detached.load(.acquire)) continue;
        s.detached.store(true, .release);
        n += 1;
    }
    return n;
}

/// 当前在跑的活动数(含已转后台的)。
pub fn count() usize {
    var n: usize = 0;
    for (&slots) |*s| {
        if (s.active.load(.acquire)) n += 1;
    }
    return n;
}

/// 一个活动的快照,供渲染使用。
pub const View = struct {
    kind: Kind,
    name: []const u8,
    detail: []const u8,
    elapsed_ms: i64,
    bytes: u64,
    attempt: u32,
    limit_ms: i64,
    detached: bool,
    pid: i32 = 0,
};

/// 把当前活动快照到 `out`,返回填充数量。
/// 名称/详情指向槽位内部 buffer —— 只在本次渲染内有效,不要留存。
pub fn snapshot(out: []View) usize {
    var n: usize = 0;
    // `now` 取一次给所有槽位用,保证同一帧里各行的耗时基准一致。
    // 代价是槽位可能在取时之后才登记 —— 那会算出负数,钳到 0。
    const now = nowMs();
    for (&slots) |*s| {
        if (n >= out.len) break;
        if (!s.active.load(.acquire)) continue;
        const nl = s.name_len.load(.acquire);
        const dl = s.detail_len.load(.acquire);
        const started = s.start_ms.load(.monotonic);
        out[n] = .{
            .kind = @enumFromInt(s.kind.load(.monotonic)),
            .name = s.name_buf[0..nl],
            .detail = s.detail_buf[0..dl],
            .elapsed_ms = @max(0, now - started),
            .bytes = s.bytes.load(.monotonic),
            .attempt = s.attempt.load(.monotonic),
            .limit_ms = s.limit_ms.load(.monotonic),
            .detached = s.detached.load(.acquire),
            .pid = s.pid.load(.acquire),
        };
        n += 1;
    }
    return n;
}

/// 活动表的 JSON 数组。name/detail 立刻拷进输出,不挂槽位指针。
pub fn writeJson(alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var views: [MAX_SLOTS]View = undefined;
    const n = snapshot(&views);
    try w.writeAll("[");
    for (views[0..n], 0..) |v, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"kind\":\"{s}\",\"name\":{s},\"detail\":{s},\"ms\":{d},\"bytes\":{d},\"attempt\":{d},\"limit_ms\":{d},\"detached\":{s},\"pid\":{d}}}", .{
            @tagName(v.kind),
            util.jsonString(alloc, v.name) catch "\"\"",
            util.jsonString(alloc, v.detail) catch "\"\"",
            v.elapsed_ms,
            v.bytes,
            v.attempt,
            v.limit_ms,
            if (v.detached) "true" else "false",
            v.pid,
        });
    }
    try w.writeAll("]");
}

/// 测试与新会话用:清空全部槽位。
pub fn reset() void {
    for (&slots) |*s| {
        s.active.store(false, .release);
        s.claimed.store(false, .release);
        s.detached.store(false, .monotonic);
        s.pid.store(0, .monotonic);
    }
    cancel_gen.store(0, .release);
}

/// 该 pid 是否是当前登记的活动。只杀表内进程,避免 /jobs kill 误伤无关进程。
pub fn hasPid(pid: i32) bool {
    if (pid <= 0) return false;
    for (&slots) |*s| {
        if (s.active.load(.acquire) and s.pid.load(.acquire) == pid) return true;
    }
    return false;
}

/// 人读的耗时:短的给一位小数,长的给分秒。
/// 定长输出进调用方的 buffer,不分配 —— 渲染路径每 100ms 走一次。
pub fn formatElapsed(buf: []u8, ms: i64) []const u8 {
    const s = @divTrunc(ms, 1000);
    if (s < 10) {
        return std.fmt.bufPrint(buf, "{d}.{d}s", .{ s, @divTrunc(@mod(ms, 1000), 100) }) catch "?";
    }
    if (s < 60) return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "?";
    // 秒位手工补零:Zig 0.16 的格式串不再支持 `{d:0>2}` 这类填充语法
    const secs = @mod(s, 60);
    const pad: []const u8 = if (secs < 10) "0" else "";
    return std.fmt.bufPrint(buf, "{d}m{s}{d}s", .{ @divTrunc(s, 60), pad, secs }) catch "?";
}

/// 人读的字节数。
pub fn formatBytes(buf: []u8, n: u64) []const u8 {
    if (n < 1024) return std.fmt.bufPrint(buf, "{d}B", .{n}) catch "?";
    if (n < 1024 * 1024) return std.fmt.bufPrint(buf, "{d}.{d}KB", .{ n / 1024, (n % 1024) * 10 / 1024 }) catch "?";
    return std.fmt.bufPrint(buf, "{d}.{d}MB", .{ n / (1024 * 1024), (n % (1024 * 1024)) * 10 / (1024 * 1024) }) catch "?";
}

/// 墙钟上限的紧凑写法:整分钟省掉秒位(`10m` 而非 `10m00s`)。
/// 它出现在「12s/30s」的分母位置,是参考值而非精确读数,秒位纯噪音。
pub fn formatLimit(buf: []u8, ms: i64) []const u8 {
    const s = @divTrunc(ms, 1000);
    if (s >= 60 and @mod(s, 60) == 0) return std.fmt.bufPrint(buf, "{d}m", .{@divTrunc(s, 60)}) catch "?";
    return formatElapsed(buf, ms);
}

/// 文本的终端显示列数。CJK/全角字符占 2 列,其余占 1 列。
///
/// 必要而非讲究:活动行按剩余宽度截断详情,而详情常是中文任务描述。
/// 按字节算会让中文行只用掉三分之一屏幕就以为满了,按字符算又会溢出换行
/// 把布局撑破 —— 两者都错。
pub fn displayWidth(text: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (len >= 3) {
            // 3-4 字节:CJK、假名、全角标点、emoji —— 终端里都是双宽
            cols += 2;
        } else {
            cols += 1;
        }
        i += len;
    }
    return cols;
}

/// 把 `text` 截到最多 `max_cols` 显示列,返回可安全输出的字节数。
/// 永不切开 UTF-8 序列。
pub fn truncateToCols(text: []const u8, max_cols: usize) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const cw: usize = if (len >= 3) 2 else 1;
        if (cols + cw > max_cols) return i;
        cols += cw;
        i += len;
    }
    return i;
}

/// spinner 一帧。用 braille:等宽、任何终端都不会撑破布局。
pub fn spinnerFrame(ms: i64) []const u8 {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    const idx: usize = @intCast(@mod(@divTrunc(ms, 100), frames.len));
    return frames[idx];
}

test "activity slots register, snapshot and release" {
    const t = std.testing;
    try util.testInit();
    reset();
    defer reset();

    try t.expectEqual(@as(usize, 0), count());

    const h1 = begin(.tool, "bash", "npm install", 30_000);
    const h2 = begin(.tool, "read", "src/main.zig", 0);
    try t.expectEqual(@as(usize, 2), count());

    h1.progress(4096);
    var views: [MAX_SLOTS]View = undefined;
    const n = snapshot(&views);
    try t.expectEqual(@as(usize, 2), n);

    // 名称与详情原样可读 —— 并行同名工具靠 detail 区分
    var found_bash = false;
    for (views[0..n]) |v| {
        if (std.mem.eql(u8, v.name, "bash")) {
            found_bash = true;
            try t.expectEqualStrings("npm install", v.detail);
            try t.expectEqual(@as(u64, 4096), v.bytes);
            try t.expectEqual(@as(i64, 30_000), v.limit_ms);
        }
    }
    try t.expect(found_bash);

    h1.release();
    try t.expectEqual(@as(usize, 1), count());
    h2.release();
    try t.expectEqual(@as(usize, 0), count());
}

test "cancel generation stops running activities but not later ones" {
    const t = std.testing;
    try util.testInit();
    reset();
    defer reset();

    const h = begin(.tool, "bash", "sleep 300", 300_000);
    try t.expect(!h.cancelled());

    // Ctrl+C:当时在跑的被取消
    try t.expectEqual(@as(usize, 1), cancelAll());
    try t.expect(h.cancelled());

    // 之后新起的活动不受影响 —— 否则中断一次就得重启进程
    const h2 = begin(.tool, "bash", "echo ok", 30_000);
    try t.expect(!h2.cancelled());
    h.release();
    h2.release();
}

test "detached activities survive cancel" {
    const t = std.testing;
    try util.testInit();
    reset();
    defer reset();

    const h = begin(.tool, "bash", "long build", 300_000);
    h.detach();
    try t.expect(h.isDetached());
    try t.expectEqual(@as(usize, 0), detachAll());

    // 转后台后不再被 Ctrl+C 计入,也不被取消
    try t.expectEqual(@as(usize, 0), cancelAll());
    h.release();
}

test "slot exhaustion keeps cancel and elapsed working" {
    const t = std.testing;
    try util.testInit();
    reset();
    defer reset();

    var hs: [MAX_SLOTS]Handle = undefined;
    for (&hs) |*h| h.* = begin(.tool, "x", "", 0);
    const overflow = begin(.tool, "y", "", 0);
    try t.expectEqual(@as(usize, MAX_SLOTS), overflow.idx);

    // 显示类方法静默无效(没有槽位可写),但不能崩
    overflow.progress(999);
    overflow.detail("ignored");
    overflow.attempt(3);
    try t.expectEqual(@as(usize, MAX_SLOTS), count()); // 溢出的那个不出现在快照里

    // 取消必须照常生效。返回 false 的话 pumpPipes 永远不中止 ——
    // 一个委派出去的 subagent 会跑满 TASK_TIMEOUT_MS(10 分钟),
    // 用户按 Ctrl+C 完全没反应。
    try t.expect(!overflow.cancelled());
    _ = cancelAll();
    try t.expect(overflow.cancelled());
    for (hs) |h| try t.expect(h.cancelled());

    // 耗时也必须真实:报 0 会让模型以为委派的任务瞬间完成
    try t.expect(overflow.elapsedMs() >= 0);
    try t.expectEqual(@as(usize, MAX_SLOTS), overflow.idx);

    // 从未登记的句柄仍是纯空操作 —— 它没有"被取消"可言
    const never = Handle.none;
    try t.expect(!never.cancelled());
    try t.expectEqual(@as(i64, 0), never.elapsedMs());

    overflow.release();
    for (hs) |h| h.release();
    try t.expectEqual(@as(usize, 0), count());
}

test "elapsed and bytes format for humans" {
    const t = std.testing;
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("1.2s", formatElapsed(&buf, 1234));
    try t.expectEqualStrings("42s", formatElapsed(&buf, 42_000));
    try t.expectEqualStrings("2m05s", formatElapsed(&buf, 125_000));
    try t.expectEqualStrings("512B", formatBytes(&buf, 512));
    try t.expectEqualStrings("4.0KB", formatBytes(&buf, 4096));
    try t.expectEqualStrings("1.5MB", formatBytes(&buf, 1024 * 1024 * 3 / 2));
}

test "writeJson lists active jobs" {
    const t = std.testing;
    try util.testInit();
    reset();
    defer reset();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const h = begin(.tool, "bash-bg", "echo hi", 0);
    h.detach();
    h.setPid(4242);
    defer h.release();
    var aw = std.Io.Writer.Allocating.init(arena.allocator());
    try writeJson(arena.allocator(), &aw.writer);
    try t.expect(std.mem.indexOf(u8, aw.written(), "\"name\":\"bash-bg\"") != null);
    try t.expect(std.mem.indexOf(u8, aw.written(), "\"detached\":true") != null);
    try t.expect(std.mem.indexOf(u8, aw.written(), "\"pid\":4242") != null);
    try t.expect(hasPid(4242));
    try t.expect(!hasPid(1));
}

test "concurrent begin never publishes a half-written slot" {
    const t = std.testing;
    try util.testInit();
    reset();
    defer reset();

    // 这条测试守的是一个真实咬过人的 bug:`active` 原先既做占位又做发布,
    // 于是渲染端能在 `start_ms` 还是 0 的瞬间读到槽位,算出的耗时是
    // 「系统启动至今」—— 屏幕上显示一条刚起的命令已经跑了 1m07s。
    const Worker = struct {
        fn churn(stop: *std.atomic.Value(bool)) void {
            while (!stop.load(.acquire)) {
                const h = begin(.tool, "bash", "sleep 1", 30_000);
                h.progress(128);
                h.release();
            }
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*th| th.* = try std.Thread.spawn(.{}, Worker.churn, .{&stop});

    // 反复快照,任何一条已发布的活动都必须内容完整
    var views: [MAX_SLOTS]View = undefined;
    var checked: usize = 0;
    var round: usize = 0;
    while (round < 2000) : (round += 1) {
        const n = snapshot(&views);
        for (views[0..n]) |v| {
            checked += 1;
            // 耗时不能是「系统启动至今」—— 这些活动都是刚起的
            try t.expect(v.elapsed_ms >= 0);
            try t.expect(v.elapsed_ms < 60_000);
            // 名称必须是写完的,不能是空或残留
            try t.expectEqualStrings("bash", v.name);
            try t.expectEqual(@as(i64, 30_000), v.limit_ms);
        }
    }
    stop.store(true, .release);
    for (&threads) |*th| th.join();
    // 确认真的观察到了活动,不是空跑
    try t.expect(checked > 0);
}
