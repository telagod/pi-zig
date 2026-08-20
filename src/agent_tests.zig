//! agent_tests.zig —— agent.zig 的单测主体(压缩/估算/并发槽位/系统提示/锁)。
//! 拆自 agent.zig(原净尾 617 行);agent.zig 尾部 test 钩子引回,收集不变。
//! 并发槽位测试直接跑 runToolSlot 线程 —— 符号经 agent.zig 抬 pub 导出。
const std = @import("std");
const util = @import("util.zig");
const cfgmod = @import("config.zig");
const ai = @import("ai.zig");
const toolsmod = @import("tools.zig");
const pluginsmod = @import("plugins.zig");
const agentmod = @import("agent.zig");

const Agent = agentmod.Agent;
const ToolSlot = agentmod.ToolSlot;
const runToolSlot = agentmod.runToolSlot;
const isMutatingTool = agentmod.isMutatingTool;
const collectPaths = agentmod.collectPaths;
const lockPathsFor = agentmod.lockPathsFor;
const MAX_LOCKED_PATHS = agentmod.MAX_LOCKED_PATHS;
const CTX_HARD_PERCENT = agentmod.CTX_HARD_PERCENT;

test "agent init finds provider" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    // 不加载真实配置,直接塞 provider
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    const agent = try Agent.init(a, &cfg, "mock", "m", "/tmp");
    try t.expectEqualStrings("m", agent.model);
    try t.expect(std.mem.indexOf(u8, agent.system_prompt, "piz") != null);
}

test "compaction triggers after hard line" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    var cfg = cfgmod.Config{ .arena = &arena };
    cfg.providers = &provs;
    var agent = try Agent.init(a, &cfg, "mock", "m", "/tmp");

    // 2 条 250KB 摘要占位 + 1 条 user → 500KB+ ≈ 125K token > 85%×128K
    for (0..2) |_| {
        try agent.messages.append(.{ .role = "system", .content = "(Conversation compacted. Summary:)\n" ++ ("s" ** (250 * 1024)) });
    }
    try agent.messages.append(.{ .role = "user", .content = "continue" });
    const w = @as(usize, provs[0].context_window);
    // 入培不定形 system;仍超硬线 → 回合首须 compact
    try t.expect(agent.estTokens() > w * CTX_HARD_PERCENT / 100);
}

test "token estimate does not underreport CJK text" {
    const t = std.testing;
    // 汉字在 UTF-8 下 3 字节,分词器约 1 汉字 1 token。
    // 旧的 chars/4 会把 30 个汉字(90 字节)算成 22 token,真实约 30 —— 低估 27%。
    const zh = "这是一段纯中文文本用来验证上下文预算估算不会低估真实的令牌消耗量啊";
    var cjk: usize = 0;
    var i: usize = 0;
    while (i < zh.len) {
        const n = std.unicode.utf8ByteSequenceLength(zh[i]) catch 1;
        if (n == 3) cjk += 1;
        i += n;
    }
    const est = Agent.estTokensOf(zh);
    const old = zh.len / 4;
    // 新估算至少达到汉字个数(不低估)
    try t.expect(est >= cjk);
    // 旧估算确实低于汉字个数(证明这个修复不是无病呻吟)
    try t.expect(old < cjk);

    // 英文仍按 4 字节/token,不该被这次改动抬高
    const en = "plain ascii text stays at roughly four bytes per token";
    try t.expectEqual(en.len / 4, Agent.estTokensOf(en));
}

test "token estimate handles mixed and multibyte content" {
    const t = std.testing;
    // 中英混排:两部分之和,不该因混排而失真
    const mixed = "修复 keep_alive 之后每轮省下约 100ms";
    const est = Agent.estTokensOf(mixed);
    try t.expect(est > 0);
    // 混排估算应落在「全按 ASCII 算」与「全按宽字符算」之间
    var wide: usize = 0;
    var i: usize = 0;
    while (i < mixed.len) {
        const n = std.unicode.utf8ByteSequenceLength(mixed[i]) catch 1;
        if (n >= 3) wide += 1;
        i += n;
    }
    try t.expect(est >= wide);
    try t.expect(est <= mixed.len);

    // 空串为 0,不 panic
    try t.expectEqual(@as(usize, 0), Agent.estTokensOf(""));
}

test "calibrateEst clamps scale to 2x" {
    const t = std.testing;
    var agent: Agent = undefined;
    agent.est_snap = 100;
    agent.est_scale_num = 1;
    agent.est_scale_den = 1;
    agent.calibrateEst(400);
    try t.expectEqual(@as(usize, 200), agent.est_scale_num);
    try t.expectEqual(@as(usize, 100), agent.est_scale_den);
    agent.est_snap = 100;
    agent.calibrateEst(10);
    try t.expectEqual(@as(usize, 10), agent.est_scale_num);
    try t.expectEqual(@as(usize, 20), agent.est_scale_den);
    // 非法 UTF-8 不 panic(按单字节推进)
    try t.expect(Agent.estTokensOf("\xff\xfe\xfd") <= 3);
}

test "context estimate counts the tool definitions that ship every turn" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    var cfg = cfgmod.Config{ .arena = &arena };
    cfg.providers = &provs;

    // 工具定义每轮全量重发,是上下文的一部分。漏掉它压缩会晚触发、
    // get_context_remaining 会虚报余量。
    const tool_tokens = pluginsmod.toolDefsTokensIn(pluginsmod.defaultSet());
    try t.expect(tool_tokens > 500); // 默认工具集实测约 1024

    var agent = try Agent.init(a, &cfg, "mock", "m", "/tmp");
    const base = agent.estTokens();
    try t.expect(base >= tool_tokens);

    // 只读模式不发工具 → 不该计入
    var ro = try Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{ .read_only = true });
    try t.expect(ro.estTokens() < tool_tokens);

    // 消息增长只加消息那部分,工具那份是恒定项
    try agent.messages.append(.{ .role = "user", .content = "hello" });
    const grown = agent.estTokens();
    try t.expect(grown > base);
    try t.expect(grown - base < 64); // 一条短消息,不该带出第二份工具定义
}

test "compact is instant when nothing new to summarize" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try Agent.init(a, &cfg, "mock", "m", "/tmp");

    // 已有摘要 + 小增量(增量 < 20% 窗口保留预算)→ 全保留,不调模型(秒)
    try agent.messages.append(.{ .role = "system", .content = "(Conversation compacted. Summary:)\nold summary" });
    try agent.messages.append(.{ .role = "user", .content = "small question" });
    const r = try agent.compact();
    try t.expect(std.mem.indexOf(u8, r, "Nothing new") != null);
    try t.expectEqual(@as(usize, 2), agent.messages.items.len); // 历史未动
}

test "compact is mechanical snap without llm" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    var cfg = cfgmod.Config{ .arena = &arena };
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1/v1" }};
    cfg.providers = &provs;
    var agent = try Agent.init(arena.allocator(), &cfg, "mock", "mock-model", "/tmp");
    agent.llm_run = struct {
        fn boom(
            _: std.mem.Allocator,
            _: std.mem.Allocator,
            _: *const cfgmod.Provider,
            _: ?[]const u8,
            _: []const u8,
            _: []const u8,
            _: []const ai.Message,
            _: []const ai.ToolDef,
            _: ai.Options,
        ) anyerror!ai.RunResult {
            return error.UnexpectedLlm;
        }
    }.boom;
    for (0..2) |_| {
        try agent.messages.append(.{ .role = "system", .content = "(Conversation compacted. Summary:)\n" ++ ("s" ** (250 * 1024)) });
    }
    for (0..3) |i| {
        try agent.messages.append(.{ .role = "user", .content = try std.fmt.allocPrint(arena.allocator(), "work item {d} {s}", .{ i, "w" ** (60 * 1024) }) });
    }
    const r = try agent.compact();
    try t.expect(std.mem.indexOf(u8, r, "[Snapcompact]") != null);
    try t.expect(std.mem.indexOf(u8, r, "INTENTS") != null);
    try t.expect(std.mem.indexOf(u8, r, "s" ** 100) == null);
    try t.expect(agent.messages.items.len >= 2);
    try t.expect(std.mem.startsWith(u8, agent.messages.items[0].content, "(Conversation compacted"));
}

test "agent undo" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try Agent.init(a, &cfg, "mock", "m", "/tmp");
    try agent.messages.append(.{ .role = "user", .content = "q1" });
    try agent.messages.append(.{ .role = "assistant", .content = "a1" });
    try agent.messages.append(.{ .role = "user", .content = "q2" });
    try agent.messages.append(.{ .role = "assistant", .content = "a2" });
    try agent.messages.append(.{ .role = "tool", .content = "t2", .tool_call_id = "c" });
    try t.expect(agent.undo());
    try t.expectEqual(@as(usize, 2), agent.messages.items.len);
    try t.expectEqualStrings("a1", agent.messages.items[1].content);
    // 空历史不可撤销
    var agent2 = try Agent.init(a, &cfg, "mock", "m", "/tmp");
    try t.expect(!agent2.undo());
}

test "agent system override" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    const agent = try Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{ .system_override = "You are a custom bot." });
    try t.expectEqualStrings("You are a custom bot.", agent.system_prompt);
    // 不含默认内容
    try t.expect(std.mem.indexOf(u8, agent.system_prompt, "minimal coding agent") == null);
}

test "agent system.md + append + global agents" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    // 全局 AGENTS.md + SYSTEM.md + APPEND_SYSTEM.md
    try tmp.dir.writeFile(util.io, .{ .sub_path = "AGENTS.md", .data = "global rule: be terse\n" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "SYSTEM.md", .data = "CUSTOM SYSTEM\n" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "APPEND_SYSTEM.md", .data = "append note\n" });

    // 全局 AGENTS.md 合并进 loadAgentsMd
    const merged = try util.loadAgentsMd(a);
    try t.expect(std.mem.indexOf(u8, merged, "global rule: be terse") != null);
    try t.expect(std.mem.indexOf(u8, merged, "# AGENTS.md from") != null);

    // SYSTEM.md 替换默认 + APPEND 追加
    var cfg = cfgmod.Config{ .arena = &arena };
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    const agent = try Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{});
    try t.expect(std.mem.indexOf(u8, agent.system_prompt, "CUSTOM SYSTEM") != null);
    try t.expect(std.mem.indexOf(u8, agent.system_prompt, "append note") != null);
    try t.expect(std.mem.indexOf(u8, agent.system_prompt, "minimal coding agent") == null);
}

test "parallel tool slots preserve call order" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try Agent.init(a, &cfg, "mock", "m", "/tmp");

    // 造 5 个 ls 调用(纯读,可无锁并行)。完成顺序不可控,但槽位下标固定,
    // 因此按槽位顺序读结果必然与调用顺序一致 —— 这是模型上下文可复现的前提。
    const calls = [_]ai.ToolCall{
        .{ .id = "c0", .name = "ls", .args = "{\"path\":\"/tmp\",\"limit\":1}" },
        .{ .id = "c1", .name = "ls", .args = "{\"path\":\"/tmp\",\"limit\":2}" },
        .{ .id = "c2", .name = "ls", .args = "{\"path\":\"/tmp\",\"limit\":3}" },
        .{ .id = "c3", .name = "ls", .args = "{\"path\":\"/tmp\",\"limit\":4}" },
        .{ .id = "c4", .name = "ls", .args = "{\"path\":\"/tmp\",\"limit\":5}" },
    };
    const slots = try a.alloc(ToolSlot, calls.len);
    for (calls, 0..) |c, i| {
        slots[i] = .{ .call = c, .agent = &agent, .tool = agent.lookupTool(c.name) };
    }
    var threads: [5]std.Thread = undefined;
    for (slots, 0..) |*s, i| {
        threads[i] = try std.Thread.spawn(.{}, runToolSlot, .{s});
    }
    for (&threads) |th| th.join();

    // 槽位与调用一一对应,且都真的跑了
    for (slots, 0..) |s, i| {
        try t.expectEqualStrings(calls[i].id, s.call.id);
        try t.expect(s.result.content.len > 0);
    }
}

test "per-file lock prevents lost writes under concurrency" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Agent.cwd 设成临时目录 —— 工具的相对路径相对它解析,所以不需要 chdir
    // 进程(那会污染并行跑的其他测试)。这本身也验证了 cwd 隔离:工具落盘的
    // 位置由 Agent.cwd 决定,不看进程 cwd。
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path[0..] });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "shared.txt", .data = "A B" });

    var cfg = cfgmod.Config{ .arena = &arena };
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try Agent.init(a, &cfg, "mock", "m", root);

    // 两个 edit 并发改同一文件的不同片段。无锁时二者会各自读到 "A B",
    // 后写的覆盖前面的,丢掉一次修改;有 per-file 锁则两次修改都保留。
    const calls = [_]ai.ToolCall{
        .{ .id = "e0", .name = "edit", .args = "{\"path\":\"shared.txt\",\"edits\":[{\"oldText\":\"A\",\"newText\":\"AA\"}]}" },
        .{ .id = "e1", .name = "edit", .args = "{\"path\":\"shared.txt\",\"edits\":[{\"oldText\":\"B\",\"newText\":\"BB\"}]}" },
    };
    const slots = try a.alloc(ToolSlot, calls.len);
    for (calls, 0..) |c, i| {
        slots[i] = .{ .call = c, .agent = &agent, .tool = agent.lookupTool(c.name) };
    }
    var threads: [2]std.Thread = undefined;
    for (slots, 0..) |*s, i| {
        threads[i] = try std.Thread.spawn(.{}, runToolSlot, .{s});
    }
    for (&threads) |th| th.join();

    const final = try tmp.dir.readFileAlloc(util.io, "shared.txt", a, .limited(1024));
    // 两次修改都必须落在最终内容里(顺序无关,但都不能丢)
    try t.expectEqualStrings("AA BB", final);
}

test "mutating tool classification and path extraction" {
    const t = std.testing;
    try util.testInit();
    // 写类工具需要加锁
    try t.expect(isMutatingTool("write"));
    try t.expect(isMutatingTool("edit"));
    try t.expect(isMutatingTool("multi_edit"));
    // 读类工具无需加锁,可自由并行
    try t.expect(!isMutatingTool("read"));
    try t.expect(!isMutatingTool("grep"));
    try t.expect(!isMutatingTool("bash"));

    var arena = util.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: [MAX_LOCKED_PATHS][]const u8 = undefined;

    // 单文件工具:顶层 path
    try t.expectEqual(@as(usize, 1), collectPaths(a, "{\"path\":\"src/main.zig\",\"content\":\"x\"}", &out));
    try t.expectEqualStrings("src/main.zig", out[0]);

    // multi_edit:files[].path 全部收集,不再退化为全局锁
    const me =
        \\{"files":[{"path":"a.zig","edits":[]},{"path":"b.zig","edits":[]},{"path":"c.zig","edits":[]}]}
    ;
    try t.expectEqual(@as(usize, 3), collectPaths(a, me, &out));
    try t.expectEqualStrings("a.zig", out[0]);
    try t.expectEqualStrings("c.zig", out[2]);

    // 空 files / 非法 JSON → 0(调用方退化为全局锁)
    try t.expectEqual(@as(usize, 0), collectPaths(a, "{\"files\":[]}", &out));
    try t.expectEqual(@as(usize, 0), collectPaths(a, "not json", &out));
    try t.expectEqual(@as(usize, 0), collectPaths(a, "{}", &out));

    // 超过上限 → 0(宁可整体串行,不要只锁一部分)
    var big = std.array_list.Managed(u8).init(a);
    try big.appendSlice("{\"files\":[");
    for (0..MAX_LOCKED_PATHS + 1) |i| {
        if (i > 0) try big.append(',');
        try big.appendSlice(try std.fmt.allocPrint(a, "{{\"path\":\"f{d}.zig\",\"edits\":[]}}", .{i}));
    }
    try big.appendSlice("]}");
    try t.expectEqual(@as(usize, 0), collectPaths(a, big.items, &out));
}

test "disjoint multi_edit batches do not serialize on a global lock" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: [MAX_LOCKED_PATHS][]const u8 = undefined;

    // 两个 multi_edit 改互不相交的文件集 —— 从前两者都拿不到顶层 path,
    // 双双退化为全局锁而被串行;现在各锁自己那几个文件。
    const b1 = "{\"files\":[{\"path\":\"x1.zig\",\"edits\":[]},{\"path\":\"x2.zig\",\"edits\":[]}]}";
    const b2 = "{\"files\":[{\"path\":\"y1.zig\",\"edits\":[]},{\"path\":\"y2.zig\",\"edits\":[]}]}";
    const n1 = collectPaths(a, b1, &out);
    try t.expectEqual(@as(usize, 2), n1);
    const set1: [2][]const u8 = .{ out[0], out[1] };
    const n2 = collectPaths(a, b2, &out);
    try t.expectEqual(@as(usize, 2), n2);

    // 两个集合不相交 → 不会争同一把锁
    for (set1) |p1| {
        for (out[0..n2]) |p2| {
            try t.expect(!std.mem.eql(u8, p1, p2));
        }
    }
}

test "duplicate paths in one batch are deduped before locking" {
    const t = std.testing;
    try util.testInit();
    var cfg = cfgmod.Config{ .arena = undefined };
    var arena = util.Arena.init(std.testing.allocator);
    defer arena.deinit();
    cfg.arena = &arena;
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try Agent.init(arena.allocator(), &cfg, "mock", "m", "/tmp");

    // 同一路径出现两次:不去重就会对同一把互斥锁连锁两次 → 自锁死。
    // 这个测试若挂,表现是整个测试进程挂住(而非断言失败)。
    const dup = "{\"files\":[{\"path\":\"same.zig\",\"edits\":[]},{\"path\":\"same.zig\",\"edits\":[]}]}";
    var held: [MAX_LOCKED_PATHS]?*std.Io.Mutex = @splat(null);
    const n = lockPathsFor(&agent, dup, &held);
    try t.expectEqual(@as(usize, 1), n); // 两条路径去重成一把锁
    var k = n;
    while (k > 0) {
        k -= 1;
        if (held[k]) |m| m.unlock(util.io);
    }
}

test "concurrent writes to distinct files run in parallel and none is lost" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const base = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, td.sub_path[0..] });
    var agent = try Agent.init(a, &cfg, "mock", "m", base);

    const N = 6;
    // 建 N 个文件,各写不同内容
    var slots: [N]ToolSlot = undefined;
    const tool = toolsmod.find("write") orelse return error.SkipZigTest;
    for (0..N) |i| {
        const p = try std.fmt.allocPrint(a, "{s}/f{d}.txt", .{ base, i });
        const args = try std.fmt.allocPrint(a, "{{\"path\":\"{s}\",\"content\":\"C{d}\"}}", .{ p, i });
        slots[i] = .{
            .call = .{ .id = try std.fmt.allocPrint(a, "c{d}", .{i}), .name = "write", .args = args },
            .agent = &agent,
            .tool = tool,
        };
    }

    // 并发跑:各锁自己的文件,互不阻塞
    var ths: [N]std.Thread = undefined;
    for (0..N) |i| ths[i] = try std.Thread.spawn(.{}, runToolSlot, .{&slots[i]});
    for (&ths) |th| th.join();

    // 每个文件的内容都必须是自己那份 —— 丢写或串写都会在这里暴露
    for (0..N) |i| {
        try t.expect(!slots[i].result.is_error);
        const p = try std.fmt.allocPrint(a, "{s}/f{d}.txt", .{ base, i });
        const want = try std.fmt.allocPrint(a, "C{d}", .{i});
        const got = try std.Io.Dir.cwd().readFileAlloc(util.io, p, a, .limited(64));
        try t.expectEqualStrings(want, got);
    }
}

test "concurrent writes to the same file serialize without losing content" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const cwd_abs2 = try std.process.currentPathAlloc(util.io, a);
    const base2 = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs2, td.sub_path[0..] });
    var agent = try Agent.init(a, &cfg, "mock", "m", base2);
    const p = try std.fmt.allocPrint(a, "{s}/shared.txt", .{base2});

    // 4 个线程写同一文件:锁保证逐个完成,最终内容是其中某一个的完整内容,
    // 绝不能是两次写交错出的混合体。
    const N = 4;
    var slots: [N]ToolSlot = undefined;
    const tool = toolsmod.find("write") orelse return error.SkipZigTest;
    for (0..N) |i| {
        const args = try std.fmt.allocPrint(a, "{{\"path\":\"{s}\",\"content\":\"VALUE-{d}\"}}", .{ p, i });
        slots[i] = .{
            .call = .{ .id = try std.fmt.allocPrint(a, "s{d}", .{i}), .name = "write", .args = args },
            .agent = &agent,
            .tool = tool,
        };
    }
    var ths: [N]std.Thread = undefined;
    for (0..N) |i| ths[i] = try std.Thread.spawn(.{}, runToolSlot, .{&slots[i]});
    for (&ths) |th| th.join();

    try t.expect(!slots[0].result.is_error);
    const got = try std.Io.Dir.cwd().readFileAlloc(util.io, p, a, .limited(64));
    // 必须完整等于某一个写入值(而非交错产物)
    var matched = false;
    for (0..N) |i| {
        const cand = try std.fmt.allocPrint(a, "VALUE-{d}", .{i});
        if (std.mem.eql(u8, got, cand)) matched = true;
    }
    try t.expect(matched);
}

test "tool handler error surfaces the error name" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try Agent.init(a, &cfg, "mock", "m", "/tmp");

    const boom = struct {
        fn handler(_: std.mem.Allocator, _: []const u8) anyerror!toolsmod.Result {
            return error.FileNotFound;
        }
    }.handler;
    const tool = toolsmod.Tool{ .name = "boom", .desc = "boom", .handler = boom };
    var slot = ToolSlot{ .call = .{ .id = "1", .name = "boom", .args = "{}" }, .agent = &agent, .tool = &tool };
    runToolSlot(&slot);
    try t.expect(slot.result.is_error);
    try t.expectEqualStrings("tool crashed (boom): FileNotFound", slot.result.content);

    const boom_ctx = struct {
        fn handler(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!toolsmod.Result {
            return error.AccessDenied;
        }
    }.handler;
    const tool_ctx = toolsmod.Tool{ .name = "boom_ctx", .desc = "boom", .handler = boom, .ctx_handler = boom_ctx };
    var slot_ctx = ToolSlot{ .call = .{ .id = "2", .name = "boom_ctx", .args = "{}" }, .agent = &agent, .tool = &tool_ctx };
    runToolSlot(&slot_ctx);
    try t.expect(slot_ctx.result.is_error);
    try t.expectEqualStrings("tool crashed (boom_ctx): AccessDenied", slot_ctx.result.content);
}

test "ask_user stops the turn without another model call" {
    const t = std.testing;
    try util.testInit();
    pluginsmod.resetEnabledForTest();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try Agent.init(a, &cfg, "mock", "m", "/tmp");
    agent.plugins = pluginsmod.withEnabled(agent.plugins, "elicitation");
    const Hook = struct {
        var calls: usize = 0;
        var noticed: bool = false;
        fn notice(_: ?*anyopaque, text: []const u8) anyerror!void {
            if (std.mem.indexOf(u8, text, "ask_user") != null) noticed = true;
        }
        fn run(
            alloc: std.mem.Allocator,
            _: std.mem.Allocator,
            _: *const cfgmod.Provider,
            _: ?[]const u8,
            _: []const u8,
            _: []const u8,
            _: []const ai.Message,
            _: []const ai.ToolDef,
            _: ai.Options,
        ) anyerror!ai.RunResult {
            calls += 1;
            if (calls > 1) return .{ .text = "should-not-happen" };
            const tcs = try alloc.alloc(ai.ToolCall, 1);
            tcs[0] = .{ .id = "c1", .name = "ask_user", .args = "{\"question\":\"which port?\"}" };
            return .{ .text = "", .tool_calls = tcs };
        }
    };
    Hook.calls = 0;
    Hook.noticed = false;
    agent.cbs = .{ .on_notice = Hook.notice };
    agent.llm_run = Hook.run;
    const r = try agent.send("need a port");
    try t.expectEqual(@as(usize, 1), Hook.calls);
    try t.expect(Hook.noticed);
    try t.expectEqualStrings("which port?", r.text);
    try t.expect(agent.messages.items.len >= 3);
    const last = agent.messages.items[agent.messages.items.len - 1];
    try t.expectEqualStrings("tool", last.role);
    try t.expect(std.mem.indexOf(u8, last.content, "which port?") != null);
}

test "initOpts uses provided think_level instead of config default" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena, .default_think_level = .high };
    var models = [_][]const u8{"m"};
    var metas = [_]cfgmod.ModelMeta{.{ .reasoning = true }};
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k", .models = &models, .model_metas = &metas }};
    cfg.providers = &provs;
    const child = try Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{ .think_level = .low });
    try t.expect(child.think_level == .low);
    const def = try Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{});
    try t.expect(def.think_level == .high);
}
