// 长驻 sub-agent 生命周期。
const std = @import("std");
const agentmod = @import("../agent.zig");
const activity = @import("../activity.zig");
const agentsmod = @import("../agents.zig");
const toolsmod = @import("../tools.zig");
const jsonx = @import("jsonx.zig");
const limits = @import("limits.zig");
const poolmod = @import("../pool.zig");
const childbind = @import("childbind.zig");

const MAX_TASK_DEPTH = limits.MAX_TASK_DEPTH;
const TASK_TIMEOUT_MS = limits.TASK_TIMEOUT_MS;

// =====================================================================
// 长驻 subagent:spawn / wait / send / list / close。
// =====================================================================

/// 会话级注册表。顶层 agent 与它的全部后代共享一份。
///
/// 进程级单例而非挂在 Agent 上:web 模式下多个会话各有自己的 Agent,但
/// subagent 的槽位是**机器资源**,该按进程算。registry 内部按父 agent
/// 指针区分归属(list/close 只能看到自己派的)。
var g_registry: ?agentsmod.Registry = null;
var g_registry_once: std.Io.Mutex = .init;

fn registry() *agentsmod.Registry {
    g_registry_once.lockUncancelable(agentmod.util.io);
    defer g_registry_once.unlock(agentmod.util.io);
    if (g_registry == null) {
        g_registry = agentsmod.Registry.init(std.heap.page_allocator);
    }
    return &g_registry.?;
}

/// 仅供测试:当前打开的 subagent 数。
pub fn agentOpenCountForTest() usize {
    return registry().openCount();
}

/// 进程退出前回收全部 subagent(main 调用)。
pub fn shutdownAgents() void {
    if (g_registry) |*r| {
        r.signalStopAll();
        poolmod.shutdownGlobal();
        r.destroyEntries();
    }
    g_registry = null;
    poolmod.shutdownGlobal();
}

/// 长驻 worker 的事件转发。
const MailCtx = struct {
    reg: *agentsmod.Registry,
    entry: *agentsmod.Entry,
    parent_cbs: agentmod.AgentCallbacks,
    /// 本轮的 activity 句柄(pi-subagents 式「agent · running · tool xxx · 12s」实时详情)
    act: activity.Handle = .none,

    fn toHuman(self: *MailCtx, kind: agentmod.SubagentEvent, text: []const u8) void {
        const f = self.parent_cbs.on_subagent orelse return;
        f(self.parent_cbs.ctx, self.entry.id, kind, text) catch {};
    }

    fn onToolStart(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!void {
        const self: *MailCtx = @ptrCast(@alignCast(ctx.?));
        _ = args;
        self.reg.post(self.entry, .progress, name);
        self.act.detail(name);
        self.toHuman(.tool_start, name);
    }
    fn onToolEnd(ctx: ?*anyopaque, name: []const u8, is_error: bool, summary: []const u8) anyerror!void {
        const self: *MailCtx = @ptrCast(@alignCast(ctx.?));
        _ = summary;
        if (is_error) self.reg.post(self.entry, .progress, name);
        self.act.detail("");
        self.toHuman(if (is_error) .tool_failed else .tool_done, name);
    }
    fn onNotice(ctx: ?*anyopaque, text: []const u8) anyerror!void {
        const self: *MailCtx = @ptrCast(@alignCast(ctx.?));
        self.reg.post(self.entry, .notice, text);
        self.act.detail(text);
        self.toHuman(.notice, text);
    }
    fn onAbort(ctx: ?*anyopaque) bool {
        const self: *MailCtx = @ptrCast(@alignCast(ctx.?));
        return self.entry.stopping.load(.acquire) or self.entry.agent.aborted.load(.acquire);
    }
};

fn runTurn(entry: *agentsmod.Entry) void {
    const reg = registry();
    entry.in_flight.store(true, .release);
    defer entry.in_flight.store(false, .release);

    if (entry.stopping.load(.acquire)) {
        reg.rescheduleOrIdle(entry);
        return;
    }

    var mail = MailCtx{ .reg = reg, .entry = entry, .parent_cbs = entry.parent_cbs };
    entry.agent.cbs = .{
        .ctx = &mail,
        .on_tool_start = MailCtx.onToolStart,
        .on_tool_end = MailCtx.onToolEnd,
        .on_notice = MailCtx.onNotice,
        .on_abort = MailCtx.onAbort,
    };

    const input = reg.takeInput(entry) orelse {
        reg.rescheduleOrIdle(entry);
        return;
    };
    const text = entry.agent.alloc.dupe(u8, input) catch {
        std.heap.page_allocator.free(input);
        reg.post(entry, .failed, "out of memory copying task input");
        entry.turns += 1;
        reg.rescheduleOrIdle(entry);
        return;
    };
    defer std.heap.page_allocator.free(input);
    reg.setStatus(entry, .running);
    entry.agent.aborted.store(false, .release);

    const act = activity.begin(.subagent, entry.name, text, TASK_TIMEOUT_MS);
    mail.act = act;
    const result = entry.agent.send(text) catch |e| {
        act.release();
        if (!entry.stopping.load(.acquire)) {
            if (!reg.hasQueuedInput(entry)) {
                reg.post(entry, .failed, @errorName(e));
                entry.turns += 1;
            }
        }
        reg.rescheduleOrIdle(entry);
        return;
    };
    act.release();
    entry.turns += 1;

    if (result.error_msg) |msg| {
        reg.post(entry, .failed, msg);
    } else {
        const reply = if (result.text.len > 0) result.text else "(no text produced)";
        reg.post(entry, .turn_done, reply);
    }
    reg.rescheduleOrIdle(entry);
}

pub fn toolSpawnAgent(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{});

    if (self.depth >= MAX_TASK_DEPTH) {
        return .{
            .content = try std.fmt.allocPrint(arena, "error: delegation depth limit reached ({d}/{d}); do this yourself instead of delegating further", .{ self.depth, MAX_TASK_DEPTH }),
            .is_error = true,
        };
    }

    const task = jsonx.jsonStr(v, "task") orelse return .{
        .content = "error: spawn_agent requires 'task' — a self-contained description of what the sub-agent should do",
        .is_error = true,
    };
    const name = jsonx.jsonStr(v, "name") orelse "";
    const read_only = if (v == .object) blk: {
        if (v.object.get("read_only")) |r| {
            if (r == .bool) break :blk r.bool;
        }
        break :blk false;
    } else false;
    const fork_context = if (v == .object) blk: {
        if (v.object.get("fork_context")) |f| {
            if (f == .bool) break :blk f.bool;
        }
        break :blk false;
    } else false;

    const want_plugins = jsonx.jsonStrs(arena, v, "plugins") catch |e| return .{
        .content = switch (e) {
            error.EmptyList => "error: plugins must be a non-empty array of plugin names",
            else => "error: plugins must be an array of strings",
        },
        .is_error = true,
    };
    const want_tools = jsonx.jsonStrs(arena, v, "tools") catch |e| return .{
        .content = switch (e) {
            error.EmptyList => "error: tools must be a non-empty array of tool names",
            else => "error: tools must be an array of strings",
        },
        .is_error = true,
    };
    const child_plugins = childbind.resolveSet(self.plugins, want_plugins) catch |e| return .{
        .content = switch (e) {
            error.UnknownPlugin => "error: unknown plugin name in plugins[]",
            error.PluginNotHeld => "error: plugins[] can only keep plugins you already have",
            else => "error: cannot resolve child plugins",
        },
        .is_error = true,
    };
    const child_tools = if (want_tools) |names| childbind.resolveTools(arena, self.plugins, names) catch |e| return .{
        .content = switch (e) {
            error.UnknownTool => "error: unknown tool name in tools[]",
            error.ToolNotHeld => "error: tools[] can only keep tools you already have",
            else => "error: cannot resolve child tools",
        },
        .is_error = true,
    } else &.{};

    const reg = registry();
    const gpa = std.heap.page_allocator;

    const ar = gpa.create(std.heap.ArenaAllocator) catch return .{
        .content = "error: out of memory starting sub-agent",
        .is_error = true,
    };
    ar.* = std.heap.ArenaAllocator.init(gpa);
    const a = ar.allocator();

    const owned_tools = a.alloc([]const u8, child_tools.len) catch {
        ar.deinit();
        gpa.destroy(ar);
        return .{ .content = "error: out of memory starting sub-agent", .is_error = true };
    };
    for (child_tools, owned_tools) |n, *d| {
        d.* = a.dupe(u8, n) catch {
            ar.deinit();
            gpa.destroy(ar);
            return .{ .content = "error: out of memory starting sub-agent", .is_error = true };
        };
    }

    const sub = a.create(agentmod.Agent) catch {
        ar.deinit();
        gpa.destroy(ar);
        return .{ .content = "error: out of memory starting sub-agent", .is_error = true };
    };
    sub.* = agentmod.Agent.initOpts(a, self.cfg, self.provider.name, self.model, self.cwd, .{
        .read_only = self.read_only or read_only,
        .plugins = child_plugins,
        .tool_allow = owned_tools,
        .depth = self.depth + 1,
        .think_level = self.think_level,
    }) catch |e| {
        ar.deinit();
        gpa.destroy(ar);
        return .{
            .content = try std.fmt.allocPrint(arena, "error: cannot start sub-agent: {s}", .{@errorName(e)}),
            .is_error = true,
        };
    };

    if (fork_context) {
        sub.messages.appendSlice(self.messages.items) catch {};
    }

    const entry = a.create(agentsmod.Entry) catch {
        ar.deinit();
        gpa.destroy(ar);
        return .{ .content = "error: out of memory starting sub-agent", .is_error = true };
    };
    entry.* = .{
        .id = 0,
        .name = if (name.len > 0) a.dupe(u8, name) catch "sub" else "sub",
        .task = a.dupe(u8, task) catch task,
        .arena = ar,
        .agent = sub,
        .run_turn = runTurn,
        .status = std.atomic.Value(agentsmod.Status).init(.running),
        .inbox = std.array_list.Managed([]const u8).init(a),
        .mailbox = std.array_list.Managed(agentsmod.Mail).init(a),
        .stopping = std.atomic.Value(bool).init(false),
        .parent_cbs = self.cbs,
    };
    const first = std.heap.page_allocator.dupe(u8, entry.task) catch {
        ar.deinit();
        gpa.destroy(ar);
        return .{ .content = "error: out of memory starting sub-agent", .is_error = true };
    };
    entry.inbox.append(first) catch {
        std.heap.page_allocator.free(first);
        ar.deinit();
        gpa.destroy(ar);
        return .{ .content = "error: out of memory starting sub-agent", .is_error = true };
    };

    const id = reg.register(entry) catch |e| {
        for (entry.inbox.items) |item| std.heap.page_allocator.free(item);
        ar.deinit();
        gpa.destroy(ar);
        return .{
            .content = switch (e) {
                error.AgentLimitReached => try std.fmt.allocPrint(arena, "error: too many open sub-agents ({d}); close_agent the ones you are done with — completed agents still hold a slot", .{agentsmod.MAX_OPEN_AGENTS}),
                else => "error: cannot register sub-agent",
            },
            .is_error = true,
        };
    };

    reg.schedule(entry);

    return .{ .content = try std.fmt.allocPrint(arena, "sub-agent #{d} ({s}) started. It runs in the background — use wait_agent to be told when it has something, read_agent to collect it, send_agent to give it more work, close_agent when done.", .{ id, entry.name }) };
}

pub fn toolWaitAgent(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = ctx;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{}) catch std.json.Value{ .null = {} };
    var timeout_ms: i64 = 60_000;
    if (v == .object) {
        if (v.object.get("timeout_seconds")) |ts| {
            const secs: i64 = switch (ts) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => 60,
            };
            timeout_ms = @max(1_000, @min(secs * 1000, TASK_TIMEOUT_MS));
        }
    }

    const reg = registry();
    if (reg.openCount() == 0) {
        return .{ .content = "no sub-agents are open — spawn_agent first", .is_error = true };
    }

    const act = activity.begin(.tool, "wait_agent", "waiting for sub-agent mail", timeout_ms);
    defer act.release();
    const got = reg.waitMail(timeout_ms, act);

    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    if (!got) {
        try aw.writer.writeAll("timed out with nothing new. Current state:\n");
    } else {
        try aw.writer.writeAll("one or more sub-agents have updates — read_agent to collect:\n");
    }
    try reg.writeList(&aw.writer);
    return .{ .content = try aw.toOwnedSlice() };
}

pub fn toolReadAgent(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = ctx;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{});
    const id = jsonx.jsonInt(v, "id") orelse return .{
        .content = "error: read_agent requires 'id' (from spawn_agent)",
        .is_error = true,
    };

    const reg = registry();
    var mails = std.array_list.Managed(agentsmod.Mail).init(arena);
    reg.drain(@intCast(id), &mails) catch |e| return .{
        .content = try std.fmt.allocPrint(arena, "error: {s} (id {d})", .{ @errorName(e), id }),
        .is_error = true,
    };

    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    var reported: usize = 0;
    var skipped: usize = 0;
    for (mails.items) |m| {
        switch (m.kind) {
            .turn_done, .failed, .notice => {
                if (reported == 0) try aw.writer.print("sub-agent #{d}:\n", .{id});
                try aw.writer.print("[{s}] {s}\n", .{ m.kind.name(), m.text });
                reported += 1;
            },
            .progress => skipped += 1,
        }
    }
    if (reported == 0) {
        const state = reg.stateOf(@intCast(id));
        const hint = switch (state) {
            .running => "it is still working — wait_agent again",
            .idle => "it is idle and has nothing new; give it more work with send_agent, or close_agent",
            .closing, .done => "it has stopped; close_agent to free its slot",
        };
        return .{ .content = try std.fmt.allocPrint(
            arena,
            "sub-agent #{d}: no new result ({d} progress update(s) skipped). {s}.",
            .{ id, skipped, hint },
        ) };
    }
    return .{ .content = try aw.toOwnedSlice() };
}

pub fn toolSendAgent(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = ctx;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{});
    const id = jsonx.jsonInt(v, "id") orelse return .{
        .content = "error: send_agent requires 'id' (from spawn_agent)",
        .is_error = true,
    };
    const message = jsonx.jsonStr(v, "message") orelse return .{
        .content = "error: send_agent requires 'message'",
        .is_error = true,
    };
    const interrupt = if (v == .object) blk: {
        if (v.object.get("interrupt")) |i| {
            if (i == .bool) break :blk i.bool;
        }
        break :blk false;
    } else false;

    registry().send(@intCast(id), message, interrupt) catch |e| return .{
        .content = try std.fmt.allocPrint(arena, "error: {s} (id {d})", .{ @errorName(e), id }),
        .is_error = true,
    };
    return .{ .content = try std.fmt.allocPrint(arena, "sent to sub-agent #{d}{s}", .{
        id,
        if (interrupt) " (interrupting its current turn)" else " (queued behind its current work)",
    }) };
}

pub fn slashAgents(ctx: ?*anyopaque, args: []const u8) anyerror![]const u8 {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx orelse return error.NoAgent));
    var arena = agentmod.util.Arena.init(self.alloc);
    defer arena.deinit();
    const r = try toolListAgents(ctx, arena.allocator(), args);
    return self.alloc.dupe(u8, r.content);
}

pub fn toolListAgents(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = ctx;
    _ = args;
    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    try registry().writeList(&aw.writer);
    return .{ .content = try aw.toOwnedSlice() };
}

pub fn toolCloseAgent(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = ctx;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{});
    const id = jsonx.jsonInt(v, "id") orelse return .{
        .content = "error: close_agent requires 'id' (from spawn_agent)",
        .is_error = true,
    };
    const prev = registry().close(@intCast(id)) catch |e| return .{
        .content = try std.fmt.allocPrint(arena, "error: {s} (id {d})", .{ @errorName(e), id }),
        .is_error = true,
    };
    return .{ .content = try std.fmt.allocPrint(arena, "closed sub-agent #{d} (was {s})", .{ id, prev.name() }) };
}

test "slashAgents lists empty registry" {
    const t = std.testing;
    try agentmod.util.testInit();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = agentmod.cfgmod.Config{ .arena = &arena };
    var provs = [_]agentmod.cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");
    const out = try slashAgents(@ptrCast(&agent), "");
    defer agent.alloc.free(out);
    try t.expect(std.mem.indexOf(u8, out, "no live sub-agents") != null);
}
