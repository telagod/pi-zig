// todo 清单。
const std = @import("std");
const agentmod = @import("../agent.zig");
const toolsmod = @import("../tools.zig");

// =====================================================================
// todo 插件:结构化计划。官方 pi 明确不做 to-dos(设计声明),这是升级版差异点。
// 让模型自己维护多步任务进度,避免长任务中途漏步。
// 状态按 Agent 指针隔离(多会话/web 多标签并发安全),存活到进程结束。
// =====================================================================
const TodoStatus = enum { pending, in_progress, completed };

const TodoItem = struct {
    content: []const u8,
    status: TodoStatus,
};

const TodoStore = struct {
    /// key = Agent 指针地址。不用全局单例:web 模式下多会话并发,单例会互相踩。
    var lists: ?std.AutoHashMap(usize, []TodoItem) = null;
    var mutex: std.Io.Mutex = .init;
    var store_alloc: ?std.mem.Allocator = null;

    /// 全量替换某 agent 的列表。旧列表连同其字符串一并释放。
    fn put(alloc: std.mem.Allocator, key: usize, items: []TodoItem) !void {
        mutex.lockUncancelable(agentmod.util.io);
        defer mutex.unlock(agentmod.util.io);
        if (lists == null) {
            lists = std.AutoHashMap(usize, []TodoItem).init(alloc);
            store_alloc = alloc;
        }
        var map = &lists.?;
        if (map.fetchRemove(key)) |old| {
            for (old.value) |it| alloc.free(it.content);
            alloc.free(old.value);
        }
        try map.put(key, items);
    }

    fn get(key: usize) []const TodoItem {
        mutex.lockUncancelable(agentmod.util.io);
        defer mutex.unlock(agentmod.util.io);
        if (lists == null) return &.{};
        return lists.?.get(key) orelse &.{};
    }
};

fn statusGlyph(s: TodoStatus) []const u8 {
    return switch (s) {
        .pending => "[ ]",
        .in_progress => "[>]",
        .completed => "[x]",
    };
}

fn renderTodos(arena: std.mem.Allocator, items: []const TodoItem) !toolsmod.Result {
    if (items.len == 0) return .{ .content = "todo list is empty" };
    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    var done: usize = 0;
    for (items) |it| {
        if (it.status == .completed) done += 1;
        try aw.writer.print("{s} {s}\n", .{ statusGlyph(it.status), it.content });
    }
    try aw.writer.print("({d}/{d} done)", .{ done, items.len });
    return .{ .content = try arena.dupe(u8, aw.written()) };
}

/// todo_write: {items: [{content, status}]} — 全量替换当前列表。
pub fn toolTodoWrite(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{}) catch
        return .{ .content = "error: invalid JSON arguments", .is_error = true };
    if (v != .object) return .{ .content = "error: arguments must be an object", .is_error = true };
    const arr = v.object.get("items") orelse
        return .{ .content = "error: missing 'items' array", .is_error = true };
    if (arr != .array) return .{ .content = "error: 'items' must be an array", .is_error = true };

    // 存储用 agent 的长生命周期 allocator(不能用 arena —— 它每轮释放)
    const alloc = self.alloc;
    const items = try alloc.alloc(TodoItem, arr.array.items.len);
    var n: usize = 0;
    errdefer {
        for (items[0..n]) |it| alloc.free(it.content);
        alloc.free(items);
    }
    for (arr.array.items) |e| {
        if (e != .object) return .{ .content = "error: each item must be an object", .is_error = true };
        const c = e.object.get("content") orelse
            return .{ .content = "error: item missing 'content'", .is_error = true };
        if (c != .string or c.string.len == 0)
            return .{ .content = "error: item 'content' must be a non-empty string", .is_error = true };
        const st_raw = if (e.object.get("status")) |s| (if (s == .string) s.string else "pending") else "pending";
        const st: TodoStatus = if (std.mem.eql(u8, st_raw, "completed"))
            .completed
        else if (std.mem.eql(u8, st_raw, "in_progress"))
            .in_progress
        else if (std.mem.eql(u8, st_raw, "pending"))
            .pending
        else
            return .{
                .content = try std.fmt.allocPrint(arena, "error: bad status '{s}'; use pending | in_progress | completed", .{st_raw}),
                .is_error = true,
            };
        items[n] = .{ .content = try alloc.dupe(u8, c.string), .status = st };
        n += 1;
    }
    try TodoStore.put(alloc, @intFromPtr(self), items);
    return renderTodos(arena, items);
}

/// todo_read: 无参 — 返回当前列表。
pub fn toolTodoRead(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = args;
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    return renderTodos(arena, TodoStore.get(@intFromPtr(self)));
}

test "todo list roundtrip and per-agent isolation" {
    const t = std.testing;
    try agentmod.util.testInit();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = agentmod.cfgmod.Config{ .arena = &arena };
    var provs = [_]agentmod.cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent1 = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");
    var agent2 = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");

    // 空列表可读
    const empty = try toolTodoRead(@ptrCast(&agent1), a, "{}");
    try t.expect(std.mem.indexOf(u8, empty.content, "empty") != null);

    // 写入后可读回,状态字形正确
    const w = try toolTodoWrite(@ptrCast(&agent1), a,
        \\{"items":[{"content":"scan repo","status":"completed"},
        \\          {"content":"fix bug","status":"in_progress"},
        \\          {"content":"run tests","status":"pending"}]}
    );
    try t.expect(!w.is_error);
    try t.expect(std.mem.indexOf(u8, w.content, "[x] scan repo") != null);
    try t.expect(std.mem.indexOf(u8, w.content, "[>] fix bug") != null);
    try t.expect(std.mem.indexOf(u8, w.content, "[ ] run tests") != null);
    try t.expect(std.mem.indexOf(u8, w.content, "(1/3 done)") != null);

    const r = try toolTodoRead(@ptrCast(&agent1), a, "{}");
    try t.expect(std.mem.indexOf(u8, r.content, "[>] fix bug") != null);

    // 关键:另一个 agent 的列表不受影响(web 多会话并发安全)
    const other = try toolTodoRead(@ptrCast(&agent2), a, "{}");
    try t.expect(std.mem.indexOf(u8, other.content, "empty") != null);

    // 全量替换语义:旧条目不残留
    const w2 = try toolTodoWrite(@ptrCast(&agent1), a,
        \\{"items":[{"content":"ship it","status":"pending"}]}
    );
    try t.expect(std.mem.indexOf(u8, w2.content, "ship it") != null);
    try t.expect(std.mem.indexOf(u8, w2.content, "fix bug") == null);
    try t.expect(std.mem.indexOf(u8, w2.content, "(0/1 done)") != null);

    // 非法 status 明确报错而非静默当 pending
    const bad = try toolTodoWrite(@ptrCast(&agent1), a,
        \\{"items":[{"content":"x","status":"nonsense"}]}
    );
    try t.expect(bad.is_error);
    try t.expect(std.mem.indexOf(u8, bad.content, "pending | in_progress | completed") != null);

    // 缺 items / 非法 JSON 报错
    const bad2 = try toolTodoWrite(@ptrCast(&agent1), a, "{}");
    try t.expect(bad2.is_error);
    const bad3 = try toolTodoWrite(@ptrCast(&agent1), a, "not json");
    try t.expect(bad3.is_error);
}
