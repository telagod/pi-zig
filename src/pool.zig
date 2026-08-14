// pool.zig — 固定 worker 池。subagent 入队,不每人占一条 OS 线程。
const std = @import("std");
const util = @import("util.zig");

/// 同时在跑的 subagent 轮次上限。入队可以更多;闲着的 agent 不占线程。
pub const WORKER_COUNT = 8;

pub const Job = struct {
    run: *const fn (*anyopaque) void,
    ctx: *anyopaque,
};

pub const Pool = struct {
    mutex: std.Io.Mutex = .init,
    jobs: std.array_list.Managed(Job),
    jobs_live: bool = true,
    threads: [WORKER_COUNT]?std.Thread = @splat(null),
    started: bool = false,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sem: std.Io.Semaphore = .{},

    pub fn init(alloc: std.mem.Allocator) Pool {
        return .{ .jobs = std.array_list.Managed(Job).init(alloc) };
    }

    pub fn start(self: *Pool) !void {
        if (self.started) return;
        if (self.stopping.load(.acquire)) return error.PoolStopped;
        self.started = true;
        errdefer self.shutdown();
        for (&self.threads) |*th| {
            th.* = try std.Thread.spawn(.{}, worker, .{self});
        }
    }

    pub fn enqueue(self: *Pool, job: Job) !void {
        if (self.stopping.load(.acquire)) return error.PoolStopped;
        try self.start();
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        if (self.stopping.load(.acquire)) return error.PoolStopped;
        try self.jobs.append(job);
        self.sem.post(util.io);
    }

    fn take(self: *Pool) ?Job {
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        if (self.jobs.items.len == 0) return null;
        return self.jobs.orderedRemove(0);
    }

    fn worker(self: *Pool) void {
        while (true) {
            self.sem.waitUncancelable(util.io);
            if (self.stopping.load(.acquire)) {
                if (self.take()) |job| {
                    job.run(job.ctx);
                    continue;
                }
                return;
            }
            if (self.take()) |job| job.run(job.ctx);
        }
    }

    pub fn shutdown(self: *Pool) void {
        self.stopping.store(true, .release);
        if (self.started) {
            for (0..WORKER_COUNT) |_| self.sem.post(util.io);
            for (&self.threads) |th| if (th) |t| t.join();
            self.threads = @splat(null);
            self.started = false;
        }
        if (self.jobs_live) {
            self.jobs.deinit();
            self.jobs_live = false;
        }
    }
};

var g_pool: ?Pool = null;
var g_once: std.Io.Mutex = .init;

/// 进程级池。长驻 agent 与 task 槽共用。
pub fn global() *Pool {
    g_once.lockUncancelable(util.io);
    defer g_once.unlock(util.io);
    if (g_pool == null) {
        g_pool = Pool.init(std.heap.page_allocator);
    }
    return &g_pool.?;
}

pub fn shutdownGlobal() void {
    // 不持 g_once 去 join:worker 收尾会调 global() 入队,锁住就是死锁。
    g_once.lockUncancelable(util.io);
    if (g_pool == null) {
        g_once.unlock(util.io);
        return;
    }
    g_once.unlock(util.io);
    g_pool.?.shutdown();
    g_once.lockUncancelable(util.io);
    defer g_once.unlock(util.io);
    g_pool = null;
}

test "pool runs jobs and shutdown joins" {
    const t = std.testing;
    try util.testInit();
    var p = Pool.init(t.allocator);
    var hits = std.atomic.Value(usize).init(0);
    const S = struct {
        fn bump(ctx: *anyopaque) void {
            const n: *std.atomic.Value(usize) = @ptrCast(@alignCast(ctx));
            _ = n.fetchAdd(1, .acq_rel);
        }
    };
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        try p.enqueue(.{ .run = S.bump, .ctx = @ptrCast(&hits) });
    }
    const start = std.Io.Clock.now(.awake, util.io).nanoseconds;
    while (hits.load(.acquire) < 16) {
        const spent = std.Io.Clock.now(.awake, util.io).nanoseconds - start;
        if (@divTrunc(spent, std.time.ns_per_ms) > 2_000) break;
        std.Io.sleep(util.io, .{ .nanoseconds = 5 * std.time.ns_per_ms }, .awake) catch break;
    }
    try t.expectEqual(@as(usize, 16), hits.load(.acquire));
    p.shutdown();
}
