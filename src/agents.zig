// agents.zig — 会话级 subagent 注册表:长驻 agent + 邮箱。
//
// 为什么不是"派出去 join 等结果":那样委派是个黑盒,父 agent 只能在全部跑完时
// 拿到一坨文本。发现某一路方向错了也没法纠正 —— 只能等它烧完一整轮再重派。
//
// 改成 codex 的模型(读 codex-rs/core/src/tools/handlers/multi_agents/ 得来):
//   spawn  → 立即返回 id,不等
//   wait   → 等**任意**agent 有邮件,只说"谁有更新",不返回内容
//   send   → 往正在跑的 agent 发消息;interrupt=true 打断当前轮立即处理
//   list   → 列出活着的 agent 与状态
//   close  → 关掉并回收槽位(跑完 ≠ 释放,得显式关)
//
// 邮箱而非回调:父 agent 决定何时取、取什么。回调是"推",父 agent 正在自己的
// 工具循环里没法处理;邮箱是"拉",取的时机由它自己定。
const std = @import("std");
const agentmod = @import("agent.zig");
const util = @import("util.zig");
const activity = @import("activity.zig");

/// 会话内同时打开的 subagent 上限。
///
/// 跑完不等于释放 —— 和 codex 一样,completed 的 agent 仍占槽位直到 close。
/// 这是有意的:父 agent 可能还要 send_input 让它继续,提前回收就丢了上下文。
/// 32 与 task 工具的批量上限对齐(那条路径实测整树 299MB / 33 进程)。
pub const MAX_OPEN_AGENTS = 32;

/// 单个 agent 的邮箱容量。满了丢**最旧**的 —— 父 agent 关心的是最新进展,
/// 而不是三轮前的某次工具调用。
const MAILBOX_CAP = 64;

/// 一条邮件的正文上限。逐 token 的正文会被聚合,但工具输出可能很长。
const MAIL_TEXT_CAP = 2 * 1024;

/// agent 生命周期状态。
pub const Status = enum(u8) {
    /// 正在跑一轮
    running,
    /// 跑完了,等下一次输入(长驻的意义所在)
    idle,
    /// 收到 close,worker 正在退出
    closing,
    /// worker 已退出
    done,

    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .running => "running",
            .idle => "idle",
            .closing => "closing",
            .done => "done",
        };
    }
};

/// 邮件类型。父 agent 靠它判断该不该打断自己去处理。
pub const MailKind = enum {
    /// 一轮跑完,text 是最终答复
    turn_done,
    /// 工具调用开始/结束(进度)
    progress,
    /// 引擎告知(自愈、重试)
    notice,
    /// 出错了,text 是原因
    failed,

    pub fn name(self: MailKind) []const u8 {
        return switch (self) {
            .turn_done => "turn_done",
            .progress => "progress",
            .notice => "notice",
            .failed => "failed",
        };
    }
};

pub const Mail = struct {
    kind: MailKind,
    /// 指向 agent 自己的 arena,活到 close 为止
    text: []const u8,
    at_ms: i64,
};

/// 一个长驻 subagent。
pub const Entry = struct {
    id: usize,
    /// 模型给的名字(便于它自己记住派了谁做什么);空则用 "sub<id>"
    name: []const u8,
    /// 首个任务描述,list_agents 里显示
    task: []const u8,
    /// 本 agent 独占的 arena。**它自己、它的历史、它的邮件都在里面** ——
    /// close 时整个回收,不必逐个 free。
    arena: *std.heap.ArenaAllocator,
    agent: *agentmod.Agent,
    worker: std.Thread,

    // ---- 以下字段跨线程访问,全部原子或持 registry 锁 ----
    status: std.atomic.Value(Status),
    /// 待处理输入队列(FIFO;interrupt 插队首)
    inbox: std.array_list.Managed([]const u8),
    /// 派出它的父 agent 的回调(值拷贝)。
    ///
    /// 拷贝而非存父 agent 指针:父 agent 可能先结束(它跑完一轮回复用户,而
    /// 长驻 agent 还在跑)。回调里的 ctx 指向 App / JsonlCtx,那些活到进程
    /// 结束,所以借用安全。
    parent_cbs: agentmod.AgentCallbacks = .{},
    /// 产出的邮件
    mailbox: std.array_list.Managed(Mail),
    /// 父 agent 已读到的位置 —— wait 只报"有没有新的"
    read_cursor: usize = 0,
    /// 请 worker 退出
    stopping: std.atomic.Value(bool),
    /// 累计跑过的轮数(list_agents 显示)
    turns: usize = 0,
};

/// 会话级注册表。一个 piz 进程一份(顶层 agent 与它的全部后代共享)。
pub const Registry = struct {
    alloc: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    entries: std.array_list.Managed(*Entry),
    next_id: usize = 1,
    /// 任意 agent 投递邮件时递增 —— wait 靠它判断"有没有新东西",
    /// 不必逐个扫邮箱。
    mail_gen: std.atomic.Value(u64),

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{
            .alloc = alloc,
            .entries = std.array_list.Managed(*Entry).init(alloc),
            .mail_gen = std.atomic.Value(u64).init(0),
        };
    }

    /// 关掉全部 agent 并回收。进程退出前调用。
    pub fn deinit(self: *Registry) void {
        // 先全部置停,再逐个 join —— 反过来的话第一个 join 要等它自己超时
        self.mutex.lockUncancelable(util.io);
        for (self.entries.items) |e| {
            e.stopping.store(true, .release);
            e.agent.aborted.store(true, .release);
        }
        const snapshot = self.entries.toOwnedSlice() catch &.{};
        self.mutex.unlock(util.io);

        for (snapshot) |e| {
            e.worker.join();
            const ar = e.arena;
            ar.deinit();
            self.alloc.destroy(ar);
        }
        if (snapshot.len > 0) self.alloc.free(snapshot);
        self.entries.deinit();
    }

    /// 当前打开的 agent 数(含 idle/done —— 跑完不等于释放)。
    pub fn openCount(self: *Registry) usize {
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        return self.entries.items.len;
    }

    /// 按 id 找。调用方须持锁,或者只在锁内使用返回值。
    fn findLocked(self: *Registry, id: usize) ?*Entry {
        for (self.entries.items) |e| {
            if (e.id == id) return e;
        }
        return null;
    }

    /// 登记一个新 agent。槽位满返回 error.AgentLimitReached。
    ///
    /// 只做登记与槽位核算 —— Agent 的构造、worker 的启动由调用方完成,
    /// 因为那需要父 agent 的配置,而 registry 不该知道那些。
    pub fn register(self: *Registry, e: *Entry) !usize {
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        if (self.entries.items.len >= MAX_OPEN_AGENTS) return error.AgentLimitReached;
        e.id = self.next_id;
        self.next_id += 1;
        try self.entries.append(e);
        return e.id;
    }

    /// 投递一封邮件(worker 线程调用)。
    ///
    /// 满了丢最旧的:父 agent 关心最新进展,三轮前的某次工具调用没有价值。
    pub fn post(self: *Registry, e: *Entry, kind: MailKind, text: []const u8) void {
        const a = e.arena.allocator();
        const clipped = util.clampUtf8(text, MAIL_TEXT_CAP);
        const owned = a.dupe(u8, clipped) catch return;
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        if (e.mailbox.items.len >= MAILBOX_CAP) {
            _ = e.mailbox.orderedRemove(0);
            if (e.read_cursor > 0) e.read_cursor -= 1;
        }
        e.mailbox.append(.{
            .kind = kind,
            .text = owned,
            .at_ms = @intCast(@divTrunc(std.Io.Clock.now(.real, util.io).nanoseconds, std.time.ns_per_ms)),
        }) catch return;
        _ = self.mail_gen.fetchAdd(1, .acq_rel);
    }

    /// 追加输入。`interrupt` 为真时打断当前轮并插到队首。
    pub fn send(self: *Registry, id: usize, text: []const u8, interrupt: bool) !void {
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        const e = self.findLocked(id) orelse return error.NoSuchAgent;
        if (e.status.load(.acquire) == .done) return error.AgentClosed;
        // dupe 到 page_allocator 而非 entry arena:send 从父线程调用,而 entry
        // arena 是 worker 线程的常驻分配器(消息、邮件、agent 自身都在上面)。
        // 两个线程并发分配同一个 arena = 数据损坏。worker 消费后负责 free。
        const owned = try std.heap.page_allocator.dupe(u8, text);
        errdefer std.heap.page_allocator.free(owned);
        if (interrupt) {
            try e.inbox.insert(0, owned);
            // 打断当前轮:ai.run 的流式检查点读这个标志。worker 跑完这一轮
            // 会看到队首是新输入,直接接着做。
            e.agent.aborted.store(true, .release);
        } else {
            try e.inbox.append(owned);
        }
    }

    /// 取出未读邮件(父 agent 调用)。返回的切片在 entry 的 arena 上,
    /// 活到 close 为止。
    pub fn drain(self: *Registry, id: usize, out: *std.array_list.Managed(Mail)) !void {
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        const e = self.findLocked(id) orelse return error.NoSuchAgent;
        while (e.read_cursor < e.mailbox.items.len) : (e.read_cursor += 1) {
            try out.append(e.mailbox.items[e.read_cursor]);
        }
    }

    /// 有没有 agent 有未读邮件(含 progress)。`list_agents` 的计数用它。
    pub fn hasUnread(self: *Registry) bool {
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        for (self.entries.items) |e| {
            if (e.read_cursor < e.mailbox.items.len) return true;
        }
        return false;
    }

    /// 有没有 agent 产出了**结果**(turn_done / failed / notice)。
    ///
    /// wait 只该被结果唤醒。progress 是给人看的进度,拿它唤醒父 agent 等于
    /// 让它为了「子 agent 在跑 bash」白烧一整轮 —— codex 同样只在子 agent
    /// 终态时才投递给父 agent。
    pub fn hasResult(self: *Registry) bool {
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        for (self.entries.items) |e| {
            var i = e.read_cursor;
            while (i < e.mailbox.items.len) : (i += 1) {
                if (e.mailbox.items[i].kind != .progress) return true;
            }
        }
        return false;
    }

    /// 等到有结果或超时。返回是否等到了。
    ///
    /// 轮询而非条件变量:100ms 的粒度对"等模型跑完一轮"完全够用,
    /// 而条件变量要在锁语义上和 interrupt 路径纠缠。
    pub fn waitMail(self: *Registry, timeout_ms: i64, act: activity.Handle) bool {
        const start = std.Io.Clock.now(.awake, util.io).nanoseconds;
        while (true) {
            if (self.hasResult()) return true;
            // 用户 Ctrl+C 时立刻返回 —— 别让父 agent 卡在等子 agent 上
            if (act.cancelled()) return false;
            // 全都不在跑也没有排队输入 —— 再等也不会有新结果
            if (self.allSettled()) return self.hasResult();
            const spent = std.Io.Clock.now(.awake, util.io).nanoseconds - start;
            if (@divTrunc(spent, std.time.ns_per_ms) >= timeout_ms) return false;
            std.Io.sleep(util.io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch return false;
        }
    }

    /// 全部 agent 都不在跑且没有待处理输入 —— 再等也不会有新结果。
    fn allSettled(self: *Registry) bool {
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        for (self.entries.items) |e| {
            if (e.status.load(.acquire) == .running) return false;
            if (e.inbox.items.len > 0) return false;
        }
        return true;
    }

    /// 某个 agent 的状态。未知 id 当作已结束 —— 调用方据此给出正确提示。
    pub fn stateOf(self: *Registry, id: usize) Status {
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        const e = self.findLocked(id) orelse return .done;
        return e.status.load(.acquire);
    }

    /// 状态快照(list_agents 用)。写进调用方给的 writer,不分配。
    pub fn writeList(self: *Registry, w: *std.Io.Writer) !void {
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        if (self.entries.items.len == 0) {
            try w.writeAll("no live sub-agents\n");
            return;
        }
        for (self.entries.items) |e| {
            const unread = e.mailbox.items.len - e.read_cursor;
            try w.print("#{d} {s} [{s}] turns={d} unread={d} queued={d}\n  task: {s}\n", .{
                e.id,
                e.name,
                e.status.load(.acquire).name(),
                e.turns,
                unread,
                e.inbox.items.len,
                util.clampUtf8(e.task, 120),
            });
        }
    }

    /// 该 agent 还有待处理输入吗(worker 判断"被 interrupt 打断"用)。
    pub fn hasQueuedInput(self: *Registry, e: *Entry) bool {
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        return e.inbox.items.len > 0;
    }

    /// 关掉一个 agent 并回收它的 arena。返回关闭前的状态。
    pub fn close(self: *Registry, id: usize) !Status {
        self.mutex.lockUncancelable(util.io);
        var victim: ?*Entry = null;
        var idx: usize = 0;
        for (self.entries.items, 0..) |e, i| {
            if (e.id == id) {
                victim = e;
                idx = i;
                break;
            }
        }
        if (victim == null) {
            self.mutex.unlock(util.io);
            return error.NoSuchAgent;
        }
        const e = victim.?;
        const prev = e.status.load(.acquire);
        _ = self.entries.orderedRemove(idx);
        e.stopping.store(true, .release);
        e.agent.aborted.store(true, .release);
        // 锁外 join:worker 可能正跑一轮(几十秒),持锁等会把整个注册表冻住
        self.mutex.unlock(util.io);

        e.worker.join();
        const ar = e.arena;
        ar.deinit();
        self.alloc.destroy(ar);
        return prev;
    }

    /// 取下一条输入(worker 调用)。没有就返回 null。
    pub fn takeInput(self: *Registry, e: *Entry) ?[]const u8 {
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        if (e.inbox.items.len == 0) return null;
        return e.inbox.orderedRemove(0);
    }

    pub fn setStatus(self: *Registry, e: *Entry, s: Status) void {
        _ = self;
        e.status.store(s, .release);
    }
};

/// 测试用:造一个不带 worker 的 entry,只验 registry 的账本逻辑。
fn testEntry(a: std.mem.Allocator, cfg: *agentmod.cfgmod.Config, name: []const u8) !*Entry {
    const ar = try a.create(std.heap.ArenaAllocator);
    ar.* = std.heap.ArenaAllocator.init(a);
    const ag = try a.create(agentmod.Agent);
    ag.* = try agentmod.Agent.initOpts(ar.allocator(), cfg, "mock", "m", "/tmp", .{ .plugins = 0 });
    const e = try a.create(Entry);
    e.* = .{
        .id = 0,
        .name = name,
        .task = "survey the parser",
        .arena = ar,
        .agent = ag,
        .worker = undefined,
        .status = std.atomic.Value(Status).init(.idle),
        .inbox = std.array_list.Managed([]const u8).init(a),
        .mailbox = std.array_list.Managed(Mail).init(a),
        .stopping = std.atomic.Value(bool).init(false),
    };
    return e;
}

fn testCfg(arena: *util.Arena, provs: *[1]agentmod.cfgmod.Provider) agentmod.cfgmod.Config {
    provs[0] = .{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" };
    var cfg = agentmod.cfgmod.Config{ .arena = arena };
    cfg.providers = provs;
    return cfg;
}

test "registry lifecycle: register, mail, drain, close" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var reg = Registry.init(a);
    // 不调 reg.deinit():这个测试不起真 worker,join 会挂
    var provs: [1]agentmod.cfgmod.Provider = undefined;
    var cfg = testCfg(&arena, &provs);

    const e = try testEntry(a, &cfg, "scout");
    defer e.arena.deinit();
    const id = try reg.register(e);
    try t.expectEqual(@as(usize, 1), id);
    try t.expectEqual(@as(usize, 1), reg.openCount());

    // 邮箱:投递后有未读,drain 之后没有 —— 游标推进而非删除,
    // 这样 list_agents 仍能显示历史条数
    try t.expect(!reg.hasUnread());
    reg.post(e, .progress, "running grep");
    reg.post(e, .turn_done, "found 3 matches");
    try t.expect(reg.hasUnread());

    var got = std.array_list.Managed(Mail).init(a);
    try reg.drain(id, &got);
    try t.expectEqual(@as(usize, 2), got.items.len);
    try t.expectEqual(MailKind.progress, got.items[0].kind);
    try t.expectEqualStrings("found 3 matches", got.items[1].text);
    try t.expect(!reg.hasUnread());

    // 追加输入:普通排队,interrupt 插队首
    try reg.send(id, "second question", false);
    try reg.send(id, "urgent", true);
    try t.expectEqual(@as(usize, 2), e.inbox.items.len);
    try t.expectEqualStrings("urgent", e.inbox.items[0]);
    // interrupt 同时置了中断标志,worker 才能打断当前轮
    try t.expect(e.agent.aborted.load(.acquire));

    // takeInput 是 FIFO
    try t.expectEqualStrings("urgent", reg.takeInput(e).?);
    try t.expectEqualStrings("second question", reg.takeInput(e).?);
    try t.expect(reg.takeInput(e) == null);

    // 未知 id 不崩
    try t.expectError(error.NoSuchAgent, reg.send(999, "x", false));
    try t.expectError(error.NoSuchAgent, reg.close(999));
}

test "mailbox drops the oldest when full, cursor stays valid" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var reg = Registry.init(a);
    var provs: [1]agentmod.cfgmod.Provider = undefined;
    var cfg = testCfg(&arena, &provs);
    const e = try testEntry(a, &cfg, "x");
    defer e.arena.deinit();
    _ = try reg.register(e);

    // 灌满再多灌:容量不能被突破,否则一个话多的 subagent 能吃光内存
    var i: usize = 0;
    while (i < MAILBOX_CAP + 20) : (i += 1) {
        reg.post(e, .progress, "m");
    }
    try t.expectEqual(MAILBOX_CAP, e.mailbox.items.len);

    // 丢头之后游标仍指向合法位置(不能越界,也不能把已读的又读一遍)
    try t.expect(e.read_cursor <= e.mailbox.items.len);
    var got = std.array_list.Managed(Mail).init(a);
    try reg.drain(e.id, &got);
    try t.expect(got.items.len <= MAILBOX_CAP);
    try t.expect(!reg.hasUnread());
}

test "wait is woken by results, not by progress" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var reg = Registry.init(a);
    var provs: [1]agentmod.cfgmod.Provider = undefined;
    var cfg = testCfg(&arena, &provs);
    const e = try testEntry(a, &cfg, "scout");
    defer e.arena.deinit();
    const id = try reg.register(e);

    // progress 算"未读"(list_agents 的计数要用),但**不算结果**。
    // 拿 progress 唤醒父 agent 等于让它为「子 agent 在跑 bash」白烧一整轮 ——
    // codex 同样只在子 agent 终态时才投递给父 agent。
    reg.post(e, .progress, "bash");
    reg.post(e, .progress, "grep");
    try t.expect(reg.hasUnread());
    try t.expect(!reg.hasResult());

    // 终态才算结果
    reg.post(e, .turn_done, "found it");
    try t.expect(reg.hasResult());

    // 读走之后两者都归零
    var got = std.array_list.Managed(Mail).init(a);
    try reg.drain(id, &got);
    try t.expectEqual(@as(usize, 3), got.items.len);
    try t.expect(!reg.hasResult());
    try t.expect(!reg.hasUnread());

    // failed 也是结果 —— 出错了父 agent 必须醒过来
    reg.post(e, .failed, "provider refused");
    try t.expect(reg.hasResult());
}

test "waitMail returns immediately when nothing can produce more" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var reg = Registry.init(a);
    var provs: [1]agentmod.cfgmod.Provider = undefined;
    var cfg = testCfg(&arena, &provs);
    const e = try testEntry(a, &cfg, "scout");
    defer e.arena.deinit();
    _ = try reg.register(e);

    // agent 是 idle 且没有排队输入 —— 再等也不会有新结果,必须立刻返回。
    // 不这样的话父 agent 会为一个已经空了的 agent 干等满超时。
    e.status.store(.idle, .release);
    const t0 = std.Io.Clock.now(.awake, util.io).nanoseconds;
    const got = reg.waitMail(30_000, activity.Handle.none);
    const spent_ms = @divTrunc(std.Io.Clock.now(.awake, util.io).nanoseconds - t0, std.time.ns_per_ms);
    try t.expect(!got);
    try t.expect(spent_ms < 1_000);

    // 有排队输入时不能提前返回:worker 迟早会跑它,结果还在路上
    try reg.send(e.id, "more work", false);
    const t1 = std.Io.Clock.now(.awake, util.io).nanoseconds;
    _ = reg.waitMail(300, activity.Handle.none);
    const waited = @divTrunc(std.Io.Clock.now(.awake, util.io).nanoseconds - t1, std.time.ns_per_ms);
    try t.expect(waited >= 250);
}
