// todo 清单。
const std = @import("std");
const agentmod = @import("../agent.zig");
const toolsmod = @import("../tools.zig");
const jsonx = @import("jsonx.zig");

// =====================================================================
// todo 插件:结构化计划。官方 pi 明确不做 to-dos(设计声明),这是升级版差异点。
// 让模型自己维护多步任务进度,避免长任务中途漏步。
// 状态按 Agent 指针隔离(多会话/web 多标签并发安全),存活到进程结束。
// 条目有稳定 id,可 merge 局部更新;bind 可挂到 workflow 节点。
// =====================================================================
const TodoStatus = enum { pending, in_progress, completed };

const TodoItem = struct {
    id: []const u8,
    content: []const u8,
    status: TodoStatus,
    bind: []const u8 = "",
};

const TodoStore = struct {
    /// key = Agent 指针地址。不用全局单例:web 模式下多会话并发,单例会互相踩。
    /// 表本身用 page_allocator:测试里 Agent.alloc 是短命 arena,不能拿来挂 hashmap。
    var lists: ?std.AutoHashMap(usize, Bucket) = null;
    var mutex: std.Io.Mutex = .init;

    const Bucket = struct {
        alloc: std.mem.Allocator,
        items: []TodoItem,
    };

    fn freeItems(alloc: std.mem.Allocator, items: []TodoItem) void {
        for (items) |it| {
            alloc.free(it.id);
            alloc.free(it.content);
            if (it.bind.len > 0) alloc.free(it.bind);
        }
        alloc.free(items);
    }

    fn mapPtr() *std.AutoHashMap(usize, Bucket) {
        if (lists == null) {
            lists = std.AutoHashMap(usize, Bucket).init(std.heap.page_allocator);
        }
        return &lists.?;
    }

    /// 全量替换某 agent 的列表。旧列表连同其字符串一并释放。
    fn put(alloc: std.mem.Allocator, key: usize, items: []TodoItem) !void {
        mutex.lockUncancelable(agentmod.util.io);
        defer mutex.unlock(agentmod.util.io);
        var map = mapPtr();
        if (map.fetchRemove(key)) |old| {
            freeItems(old.value.alloc, old.value.items);
        }
        try map.put(key, .{ .alloc = alloc, .items = items });
    }

    fn resetForTest() void {
        mutex.lockUncancelable(agentmod.util.io);
        defer mutex.unlock(agentmod.util.io);
        if (lists) |*map| map.clearRetainingCapacity();
    }

    fn get(key: usize) []const TodoItem {
        mutex.lockUncancelable(agentmod.util.io);
        defer mutex.unlock(agentmod.util.io);
        if (lists == null) return &.{};
        const b = lists.?.get(key) orelse return &.{};
        return b.items;
    }

    fn snapshot(alloc: std.mem.Allocator, key: usize) ![]TodoItem {
        mutex.lockUncancelable(agentmod.util.io);
        defer mutex.unlock(agentmod.util.io);
        const src = if (lists) |m| (if (m.get(key)) |b| b.items else &.{}) else &.{};
        const out = try alloc.alloc(TodoItem, src.len);
        for (src, out) |it, *d| {
            d.* = .{
                .id = try alloc.dupe(u8, it.id),
                .content = try alloc.dupe(u8, it.content),
                .status = it.status,
                .bind = if (it.bind.len > 0) try alloc.dupe(u8, it.bind) else "",
            };
        }
        return out;
    }
};

fn statusGlyph(s: TodoStatus) []const u8 {
    return switch (s) {
        .pending => "[ ]",
        .in_progress => "[>]",
        .completed => "[x]",
    };
}

fn parseStatus(raw: []const u8) ?TodoStatus {
    if (std.mem.eql(u8, raw, "completed")) return .completed;
    if (std.mem.eql(u8, raw, "in_progress")) return .in_progress;
    if (std.mem.eql(u8, raw, "pending")) return .pending;
    return null;
}

fn nextAutoId(arena: std.mem.Allocator, items: []const TodoItem) ![]const u8 {
    var max: usize = 0;
    for (items) |it| {
        if (it.id.len >= 2 and it.id[0] == 't') {
            if (std.fmt.parseInt(usize, it.id[1..], 10)) |n| {
                if (n > max) max = n;
            } else |_| {}
        }
    }
    return std.fmt.allocPrint(arena, "t{d}", .{max + 1});
}

fn findId(items: []const TodoItem, id: []const u8) ?usize {
    for (items, 0..) |it, i| {
        if (std.mem.eql(u8, it.id, id)) return i;
    }
    return null;
}

fn renderTodos(arena: std.mem.Allocator, items: []const TodoItem) !toolsmod.Result {
    if (items.len == 0) return .{ .content = "todo list is empty" };
    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    var done: usize = 0;
    for (items) |it| {
        if (it.status == .completed) done += 1;
        try aw.writer.print("{s} {s}", .{ statusGlyph(it.status), it.content });
        if (it.bind.len > 0) try aw.writer.print("  @{s}", .{it.bind});
        try aw.writer.writeByte('\n');
    }
    try aw.writer.print("({d}/{d} done)", .{ done, items.len });
    return .{ .content = try arena.dupe(u8, aw.written()) };
}

fn parseIncoming(arena: std.mem.Allocator, obj: std.json.Value) !union(enum) {
    ok: struct { id: []const u8, content: []const u8, status: ?TodoStatus, bind: ?[]const u8 },
    fail: []const u8,
} {
    if (obj != .object) return .{ .fail = "error: each item must be an object" };
    const content = jsonx.jsonStr(obj, "content") orelse "";
    const id = jsonx.jsonStr(obj, "id") orelse "";
    var status: ?TodoStatus = null;
    if (jsonx.jsonStr(obj, "status")) |raw| {
        status = parseStatus(raw) orelse return .{
            .fail = try std.fmt.allocPrint(arena, "error: bad status '{s}'; use pending | in_progress | completed", .{raw}),
        };
    }
    const bind = jsonx.jsonStr(obj, "bind");
    return .{ .ok = .{ .id = id, .content = content, .status = status, .bind = bind } };
}

fn ownItem(alloc: std.mem.Allocator, id: []const u8, content: []const u8, status: TodoStatus, bind: []const u8) !TodoItem {
    return .{
        .id = try alloc.dupe(u8, id),
        .content = try alloc.dupe(u8, content),
        .status = status,
        .bind = if (bind.len > 0) try alloc.dupe(u8, bind) else "",
    };
}

/// todo_write: {items, mode?} — replace 全量替换;merge 按 id 补丁。
pub fn toolTodoWrite(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{}) catch
        return .{ .content = "error: invalid JSON arguments", .is_error = true };
    if (v != .object) return .{ .content = "error: arguments must be an object", .is_error = true };
    const arr = v.object.get("items") orelse
        return .{ .content = "error: missing 'items' array", .is_error = true };
    if (arr != .array) return .{ .content = "error: 'items' must be an array", .is_error = true };

    const mode_raw = jsonx.jsonStr(v, "mode") orelse "replace";
    const merge = if (std.mem.eql(u8, mode_raw, "merge"))
        true
    else if (std.mem.eql(u8, mode_raw, "replace"))
        false
    else
        return .{ .content = "error: mode must be replace | merge", .is_error = true };

    const alloc = self.alloc;
    const key = @intFromPtr(self);

    if (merge) {
        var cur = try TodoStore.snapshot(arena, key);
        for (arr.array.items) |e| {
            const parsed = try parseIncoming(arena, e);
            const inc = switch (parsed) {
                .fail => |m| return .{ .content = m, .is_error = true },
                .ok => |x| x,
            };
            if (inc.id.len > 0) {
                if (findId(cur, inc.id)) |idx| {
                    if (inc.content.len > 0) cur[idx].content = inc.content;
                    if (inc.status) |st| cur[idx].status = st;
                    if (inc.bind) |b| cur[idx].bind = b;
                    continue;
                }
            }
            if (inc.content.len == 0)
                return .{ .content = "error: new item missing 'content'", .is_error = true };
            const id = if (inc.id.len > 0) inc.id else try nextAutoId(arena, cur);
            if (findId(cur, id) != null)
                return .{ .content = try std.fmt.allocPrint(arena, "error: duplicate id '{s}'", .{id}), .is_error = true };
            var next = try arena.alloc(TodoItem, cur.len + 1);
            @memcpy(next[0..cur.len], cur);
            next[cur.len] = .{
                .id = id,
                .content = inc.content,
                .status = inc.status orelse .pending,
                .bind = inc.bind orelse "",
            };
            cur = next;
        }
        const owned = try alloc.alloc(TodoItem, cur.len);
        var n: usize = 0;
        errdefer {
            for (owned[0..n]) |it| {
                alloc.free(it.id);
                alloc.free(it.content);
                if (it.bind.len > 0) alloc.free(it.bind);
            }
            alloc.free(owned);
        }
        for (cur, owned) |it, *d| {
            d.* = try ownItem(alloc, it.id, it.content, it.status, it.bind);
            n += 1;
        }
        try TodoStore.put(alloc, key, owned);
        return renderTodos(arena, owned);
    }

    const items = try alloc.alloc(TodoItem, arr.array.items.len);
    var n: usize = 0;
    errdefer {
        for (items[0..n]) |it| {
            alloc.free(it.id);
            alloc.free(it.content);
            if (it.bind.len > 0) alloc.free(it.bind);
        }
        alloc.free(items);
    }
    for (arr.array.items) |e| {
        const parsed = try parseIncoming(arena, e);
        const inc = switch (parsed) {
            .fail => |m| return .{ .content = m, .is_error = true },
            .ok => |x| x,
        };
        if (inc.content.len == 0)
            return .{ .content = "error: item 'content' must be a non-empty string", .is_error = true };
        const st = inc.status orelse .pending;
        var id = inc.id;
        if (id.len == 0) id = try std.fmt.allocPrint(arena, "t{d}", .{n + 1});
        if (findId(items[0..n], id) != null)
            return .{ .content = try std.fmt.allocPrint(arena, "error: duplicate id '{s}'", .{id}), .is_error = true };
        items[n] = try ownItem(alloc, id, inc.content, st, inc.bind orelse "");
        n += 1;
    }
    try TodoStore.put(alloc, key, items);
    return renderTodos(arena, items);
}

/// todo_read: 无参 — 返回当前列表。
pub fn slashTodo(ctx: ?*anyopaque, args: []const u8) anyerror![]const u8 {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx orelse return error.NoAgent));
    var arena = agentmod.util.Arena.init(self.alloc);
    defer arena.deinit();
    const r = try toolTodoRead(ctx, arena.allocator(), args);
    return self.alloc.dupe(u8, r.content);
}

pub fn toolTodoRead(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = args;
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    return renderTodos(arena, TodoStore.get(@intFromPtr(self)));
}

test "todo list roundtrip and per-agent isolation" {
    const t = std.testing;
    TodoStore.resetForTest();
    try agentmod.util.testInit();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = agentmod.cfgmod.Config{ .arena = &arena };
    var provs = [_]agentmod.cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent1 = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");
    var agent2 = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");

    const empty = try toolTodoRead(@ptrCast(&agent1), a, "{}");
    try t.expect(std.mem.indexOf(u8, empty.content, "empty") != null);

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

    const other = try toolTodoRead(@ptrCast(&agent2), a, "{}");
    try t.expect(std.mem.indexOf(u8, other.content, "empty") != null);

    const w2 = try toolTodoWrite(@ptrCast(&agent1), a,
        \\{"items":[{"content":"ship it","status":"pending"}]}
    );
    try t.expect(std.mem.indexOf(u8, w2.content, "ship it") != null);
    try t.expect(std.mem.indexOf(u8, w2.content, "fix bug") == null);
    try t.expect(std.mem.indexOf(u8, w2.content, "(0/1 done)") != null);

    const bad = try toolTodoWrite(@ptrCast(&agent1), a,
        \\{"items":[{"content":"x","status":"nonsense"}]}
    );
    try t.expect(bad.is_error);
    try t.expect(std.mem.indexOf(u8, bad.content, "pending | in_progress | completed") != null);

    const bad2 = try toolTodoWrite(@ptrCast(&agent1), a, "{}");
    try t.expect(bad2.is_error);
    const bad3 = try toolTodoWrite(@ptrCast(&agent1), a, "not json");
    try t.expect(bad3.is_error);
}

test "todo merge by id and bind to workflow node" {
    const t = std.testing;
    TodoStore.resetForTest();
    try agentmod.util.testInit();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = agentmod.cfgmod.Config{ .arena = &arena };
    var provs = [_]agentmod.cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");

    const w = try toolTodoWrite(@ptrCast(&agent), a,
        \\{"items":[{"id":"scan","content":"scan repo","status":"in_progress","bind":"recon"},
        \\          {"id":"impl","content":"implement","status":"pending","bind":"impl"}]}
    );
    try t.expect(!w.is_error);
    try t.expect(std.mem.indexOf(u8, w.content, "@recon") != null);
    try t.expect(std.mem.indexOf(u8, w.content, "@impl") != null);

    const m = try toolTodoWrite(@ptrCast(&agent), a,
        \\{"mode":"merge","items":[{"id":"scan","status":"completed"},{"content":"review","bind":"review"}]}
    );
    try t.expect(!m.is_error);
    try t.expect(std.mem.indexOf(u8, m.content, "[x] scan repo") != null);
    try t.expect(std.mem.indexOf(u8, m.content, "[ ] implement") != null);
    try t.expect(std.mem.indexOf(u8, m.content, "[ ] review") != null);
    try t.expect(std.mem.indexOf(u8, m.content, "@review") != null);
    try t.expect(std.mem.indexOf(u8, m.content, "(1/3 done)") != null);
}
