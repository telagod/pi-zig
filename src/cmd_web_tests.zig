//! cmd_web_tests.zig —— cmd_web.zig 的单测主体(2 测试)。
//! 拆自 cmd_web.zig;cmd_web.zig 尾部 test 钩子引回,收集不变。
const std = @import("std");
const util = @import("core").util;
const cfgmod = @import("core").config;
const agentmod = @import("core").agent;
const webui_mod = @import("webui.zig");
const cmd_web = @import("cmd_web.zig");

const WebSession = cmd_web.WebSession;
const SessionPool = cmd_web.SessionPool;
const poolActionHook = cmd_web.poolActionHook;
const writeHistoryRange = cmd_web.writeHistoryRange;

test "web undo/compact are rejected while the worker turn is running" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;

    var hub = webui_mod.EventHub.init(a);
    var pool = SessionPool{ .alloc = a, .hub = &hub, .cfg = &cfg, .sessions = std.array_list.Managed(*WebSession).init(a), .workspaces = std.array_list.Managed([]const u8).init(a) };
    const agent = try a.create(agentmod.Agent);
    agent.* = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");
    const ses_arena = try a.create(util.Arena);
    ses_arena.* = util.Arena.init(a);
    const sa = ses_arena.allocator();
    const ses = try sa.create(WebSession);
    ses.* = .{
        .name = "s1",
        .cwd = "/tmp",
        .qkey = "q",
        .agent = agent,
        .hub = &hub,
        .start_ns = 0,
        .worker = undefined,
        .arena = ses_arena,
    };
    try pool.sessions.append(ses);

    ses.busy.store(1, .release);
    const busy_undo = poolActionHook(&pool, "/tmp", "s1", "undo", null, 1) orelse return error.Fail;
    try t.expect(std.mem.indexOf(u8, busy_undo, "\"error\":\"busy\"") != null);
    const busy_compact = poolActionHook(&pool, "/tmp", "s1", "compact", null, 0) orelse return error.Fail;
    try t.expect(std.mem.indexOf(u8, busy_compact, "\"error\":\"busy\"") != null);
    const busy_fork = poolActionHook(&pool, "/tmp", "s1", "fork", null, 0) orelse return error.Fail;
    try t.expect(std.mem.indexOf(u8, busy_fork, "\"error\":\"busy\"") != null);

    ses.busy.store(0, .release);
    const idle_undo = poolActionHook(&pool, "/tmp", "s1", "undo", null, 1) orelse return error.Fail;
    try t.expect(std.mem.indexOf(u8, idle_undo, "\"error\":\"busy\"") == null);
    ses.busy.store(2, .release);
    const busy2 = poolActionHook(&pool, "/tmp", "s1", "undo", null, 1) orelse return error.Fail;
    try t.expect(std.mem.indexOf(u8, busy2, "\"error\":\"busy\"") != null);
    ses.busy.store(0, .release);

    const tree = poolActionHook(&pool, "/tmp", "s1", "tree", null, 0) orelse return error.Fail;
    try t.expect(std.mem.indexOf(u8, tree, "\"ok\":true") != null);
    const q = poolActionHook(&pool, "/tmp", "s1", "queue", null, 0) orelse return error.Fail;
    try t.expect(std.mem.indexOf(u8, q, "\"act\":\"queue\"") != null);
    const copy_empty = poolActionHook(&pool, "/tmp", "s1", "copy", null, 0) orelse return error.Fail;
    try t.expect(std.mem.indexOf(u8, copy_empty, "\"ok\":false") != null);
}

test "writeHistoryRange pages a slice" {
    const t = std.testing;
    const ai = @import("core").ai;
    const msgs = [_]ai.Message{
        .{ .role = "user", .content = "one" },
        .{ .role = "assistant", .content = "two" },
        .{ .role = "user", .content = "three" },
        .{ .role = "assistant", .content = "four" },
    };
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var stw = std.Io.Writer.Allocating.init(t.allocator);
    defer stw.deinit();
    writeHistoryRange(&stw.writer, arena.allocator(), &msgs, 1, 3);
    const out = stw.written();
    try t.expect(std.mem.indexOf(u8, out, "two") != null);
    try t.expect(std.mem.indexOf(u8, out, "three") != null);
    try t.expect(std.mem.indexOf(u8, out, "one") == null);
    try t.expect(std.mem.indexOf(u8, out, "four") == null);
}
