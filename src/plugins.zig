// plugins.zig — 内置插件(极简核心之外的可选增强,随二进制编译,零配置)。
// 对齐 pi 的扩展思想:核心 agent 只做增量压缩;增强能力以插件形式挂勾。
// 外部插件走 events.zig(包扩展声明);此处为编译期内置。
const std = @import("std");
const agentmod = @import("agent.zig");
const activity = @import("activity.zig");
const toolsmod = @import("tools.zig");
const aimod = @import("ai.zig");

/// 内置插件定义。
pub const Plugin = struct {
    name: []const u8,
    /// 是否默认启用。false = 可选扩展,需 settings.json 的 `plugins` 数组
    /// 或 `--plugin <name>` 显式开启。
    ///
    /// 极简内核的实际含义:默认暴露给模型的工具越少,模型选错工具的概率越低,
    /// 每轮的 tools 定义也越省 token。场景化能力按需开。
    enabled_by_default: bool = true,
    /// 每轮请求前钩子(可裁剪上下文、注入内容等)。ctx 为 Agent 指针。
    before_turn: ?*const fn (ctx: ?*anyopaque) void = null,
    /// 压缩成功后钩子(跨会话记忆等,复用摘要,零额外模型调用)。
    on_compact: ?*const fn (ctx: ?*anyopaque, summary: []const u8) void = null,
    /// 压缩失败钩子:返回备用模型名(非 null 则用其重试一次)。
    on_compact_failed: ?*const fn (ctx: ?*anyopaque) ?[]const u8 = null,
    /// 工具执行前拦截:返回非 null 消息则跳过执行(命令规范化等)。
    on_tool_before: ?*const fn (ctx: ?*anyopaque, name: []const u8, args: []const u8) ?[]const u8 = null,
    /// 工具结果后处理:返回新内容替换(artifact 外置等)。
    on_tool_result: ?*const fn (ctx: ?*anyopaque, name: []const u8, content: []const u8) ?[]const u8 = null,
    /// 用户消息钩子(elicitation 续跑等)。
    on_user_message: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
    /// 斜杠命令(交互模式 /<name>)。
    slash_commands: []const SlashCommand = &.{},
    /// 插件注册的工具(与核心工具合并暴露给模型)。
    tools: []const toolsmod.Tool = &.{},
};

/// 插件斜杠命令。
pub const SlashCommand = struct {
    name: []const u8,
    desc: []const u8,
    /// ctx = 宿主(如 App),args = 命令参数。
    handler: *const fn (ctx: ?*anyopaque, args: []const u8) anyerror![]const u8,
};

/// 工具输出预剪枝(omp fork 式增强;pi 官方无此机制)。
/// 只裁早期工具输出,占位替换,不碰轮结构:
/// - 保护最新 40K token 的工具输出(尾部倒推)
/// - 可节省 ≥ 20K token 才动手
/// - 不裁 read/skill 类工具结果(模型需要原文)
fn pruneHook(ctx: ?*anyopaque) void {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    const PROTECT_TOKENS = 40 * 1024;
    const MIN_SAVINGS_TOKENS = 20 * 1024;
    // 统一用 Agent.estTokensOf 估算,不再「token × 4 当字节」:
    // 那个换算对中文低估约 25%,会让保护窗口实际比 40K token 小、
    // 也让「够不够 20K 可省」的判断偏保守(该裁的时候不裁)。
    const estTok = agentmod.Agent.estTokensOf;
    // 尾部倒推:累计受保护工具输出,得首个受保护索引
    var protected: usize = 0;
    var first_protected: usize = self.messages.items.len;
    var i = self.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = self.messages.items[i];
        if (!std.mem.eql(u8, m.role, "tool")) continue;
        if (protected >= PROTECT_TOKENS) break;
        protected += estTok(m.content);
        first_protected = i;
    }
    // 可裁量(排除 read/skill 与已裁占位)
    var savings: usize = 0;
    for (0..first_protected) |j| {
        const m = self.messages.items[j];
        if (!std.mem.eql(u8, m.role, "tool")) continue;
        if (isProtectedTool(self, m) or m.content.len == 0) continue;
        savings += estTok(m.content);
    }
    if (savings < MIN_SAVINGS_TOKENS) return;
    // 裁剪:占位替换(注意 items[j] 是值拷贝,须直接索引赋值)
    for (0..first_protected) |j| {
        if (!std.mem.eql(u8, self.messages.items[j].role, "tool")) continue;
        if (isProtectedTool(self, self.messages.items[j]) or self.messages.items[j].content.len == 0) continue;
        self.messages.items[j].content = std.fmt.allocPrint(self.alloc, "[Output truncated - {d} tokens]", .{estTok(self.messages.items[j].content)}) catch continue;
    }
}

/// 工具结果是否受保护(其归属工具名 ∈ {read, skill})。
fn isProtectedTool(self: *agentmod.Agent, m: agentmod.ai.Message) bool {
    const id = m.tool_call_id orelse return false;
    for (self.messages.items) |mm| {
        if (!std.mem.eql(u8, mm.role, "assistant")) continue;
        const tcs = mm.tool_calls orelse continue;
        for (tcs) |tc| {
            if (std.mem.eql(u8, tc.id, id)) {
                return std.mem.eql(u8, tc.name, "read") or std.mem.eql(u8, tc.name, "skill");
            }
        }
    }
    return false;
}

test "command canonicalization blocks dangerous patterns" {
    const t = std.testing;
    try agentmod.util.testInit();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = agentmod.cfgmod.Config{ .arena = &arena };
    var provs = [_]agentmod.cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");
    const blocked = canonicalBlock(&agent, "bash", "sudo rm -rf / --no-preserve-root");
    try t.expect(blocked != null);
    try t.expect(std.mem.indexOf(u8, blocked.?, "blocked") != null);
    const ok = canonicalBlock(&agent, "bash", "ls -la");
    try t.expect(ok == null);
}

test "artifact store externalizes large outputs" {
    const t = std.testing;
    try agentmod.util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(agentmod.util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    defer std.Io.Dir.cwd().deleteTree(agentmod.util.io, tmp_path) catch {};
    try agentmod.util.environ_map.?.put("PIZ_DIR", tmp_path);
    var cfg = agentmod.cfgmod.Config{ .arena = &arena };
    var provs = [_]agentmod.cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");

    // 小输出不处理
    try t.expect(artifactStore(&agent, "bash", "small") == null);
    // 大输出外置:引用含路径与预览
    const big = "x" ** (8 * 1024);
    const ref = artifactStore(&agent, "bash", big).?;
    try t.expect(std.mem.indexOf(u8, ref, "[Artifact stored:") != null);
    try t.expect(std.mem.indexOf(u8, ref, "artifacts") != null);
    // 文件真实存在(路径在 "stored: " 与 " (" 之间)
    const path_start = std.mem.indexOf(u8, ref, "stored: ").? + 8;
    const path_end = std.mem.indexOfScalar(u8, ref[path_start..], ' ').? + path_start;
    const fpath = ref[path_start..path_end];
    const stored = try std.Io.Dir.cwd().readFileAlloc(agentmod.util.io, fpath, a, .limited(64 * 1024));
    try t.expectEqual(big.len, stored.len);
}

test "cross-session memory persists and injects idempotently" {
    const t = std.testing;
    try agentmod.util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 隔离 configDir
    const cwd_abs = try std.process.currentPathAlloc(agentmod.util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    defer std.Io.Dir.cwd().deleteTree(agentmod.util.io, tmp_path) catch {};
    try agentmod.util.environ_map.?.put("PIZ_DIR", tmp_path);

    var cfg = agentmod.cfgmod.Config{ .arena = &arena };
    var provs = [_]agentmod.cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");
    const sys_before = agent.system_prompt.len;

    // 压缩钩子 → 记忆文件
    memoryAppend(&agent, "summary one");
    memoryAppend(&agent, "summary two");

    // 注入:system_prompt 含记忆;幂等(二次注入不重复)
    injectMemory(&agent);
    try t.expect(std.mem.indexOf(u8, agent.system_prompt, "summary two") != null);
    try t.expect(std.mem.indexOf(u8, agent.system_prompt, "## Cross-session memory") != null);
    const once = agent.system_prompt.len;
    injectMemory(&agent);
    try t.expectEqual(once, agent.system_prompt.len);
    try t.expect(agent.system_prompt.len > sys_before);
}

test "task tool delegates to a real sub-process and returns its output" {
    const t = std.testing;
    try agentmod.util.testInit();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg = agentmod.cfgmod.Config{ .arena = &arena };
    var provs = [_]agentmod.cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1/v1" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "mock-model", "/tmp");

    // 缺参数 → 明确错误(不 spawn)
    try t.expect((try toolTask(&agent, a, "{}")).is_error);
    try t.expect((try toolTask(&agent, a, "{\"description\":\"\"}")).is_error);

    // 超过并行上限 → 拒绝,不是静默丢弃
    const many = "{\"tasks\":[{\"description\":\"a\"},{\"description\":\"b\"},{\"description\":\"c\"},{\"description\":\"d\"},{\"description\":\"e\"}]}";
    const over = try toolTask(&agent, a, many);
    try t.expect(over.is_error);
    try t.expect(std.mem.indexOf(u8, over.content, "too many tasks") != null);

    // 深度闸门:子 agent 读同一份 settings.json 也带 task 工具,
    // 不拦就是 fork bomb(每层 ×4)。深度靠环境变量跨进程传。
    const env = agentmod.util.environ_map.?;
    const saved = env.get(DEPTH_ENV);
    defer if (saved) |s| {
        env.put(DEPTH_ENV, s) catch {};
    } else {
        _ = env.swapRemove(DEPTH_ENV);
    };

    try env.put(DEPTH_ENV, "0");
    try t.expectEqual(@as(usize, 0), currentTaskDepth());

    try env.put(DEPTH_ENV, "2");
    try t.expectEqual(@as(usize, 2), currentTaskDepth());
    const deep = try toolTask(&agent, a, "{\"description\":\"go deeper\"}");
    try t.expect(deep.is_error);
    try t.expect(std.mem.indexOf(u8, deep.content, "depth limit") != null);

    // 坏值当 0 处理(不能因为环境被污染就拒绝所有委托)
    try env.put(DEPTH_ENV, "not-a-number");
    try t.expectEqual(@as(usize, 0), currentTaskDepth());
}

test "task slots run in parallel and report per-task failure" {
    const t = std.testing;
    try agentmod.util.testInit();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 直接驱动 TaskSlot:用 sh 替代子 agent,验证并行 + 输出回传 + 失败归因。
    // 真跑 piz 子进程要 API key,测试环境没有。
    var slots = [_]TaskSlot{
        .{ .desc = "ok", .alloc = a, .cwd = "/tmp", .argv = &.{ "sh", "-c", "sleep 0.3; echo DONE-A" } },
        .{ .desc = "ok2", .alloc = a, .cwd = "/tmp", .argv = &.{ "sh", "-c", "sleep 0.3; echo DONE-B" } },
        .{ .desc = "fail", .alloc = a, .cwd = "/tmp", .argv = &.{ "sh", "-c", "echo BOOM >&2; exit 3" } },
    };
    const start = std.Io.Clock.now(.awake, agentmod.util.io).nanoseconds;
    var threads: [3]std.Thread = undefined;
    for (&slots, &threads) |*s, *th| th.* = try std.Thread.spawn(.{}, runTaskSlot, .{s});
    for (threads) |th| th.join();
    const ms = @divTrunc(std.Io.Clock.now(.awake, agentmod.util.io).nanoseconds - start, std.time.ns_per_ms);

    // 两个 0.3s 任务并行:总耗时接近 300ms 而非 600ms
    try t.expect(ms < 550);

    try t.expect(!slots[0].failed);
    try t.expect(std.mem.indexOf(u8, slots[0].output, "DONE-A") != null);
    try t.expect(!slots[1].failed);
    try t.expect(std.mem.indexOf(u8, slots[1].output, "DONE-B") != null);

    // 失败任务:stderr 的诊断必须透出来,否则父 agent 不知道为什么失败
    try t.expect(slots[2].failed);
    try t.expect(std.mem.indexOf(u8, slots[2].err, "BOOM") != null);
}

test "delegation results stay readable and keep partial output from failures" {
    const t = std.testing;
    try agentmod.util.testInit();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var slots = [_]TaskSlot{
        .{ .desc = "survey the parser", .alloc = a, .cwd = "/tmp", .argv = &.{ "sh", "-c", "printf 'line one\\nline two\\n'" } },
        .{ .desc = "check the lexer", .alloc = a, .cwd = "/tmp", .argv = &.{ "sh", "-c", "echo partial-progress; echo WHY >&2; exit 4" } },
    };
    for (&slots) |*s| runTaskSlot(s);

    // 耗时被记下来 —— 模型要能判断哪个子任务慢
    try t.expect(slots[0].elapsed_ms >= 0);

    const out = try formatTaskResults(a, &slots);
    // 多行输出保持多行:JSON 转义会把换行变成 `\n` 字面量,模型得解析两遍
    try t.expect(std.mem.indexOf(u8, out.content, "line one\nline two") != null);
    try t.expect(std.mem.indexOf(u8, out.content, "\\n") == null);
    // 失败任务要标出来并给出原因
    try t.expect(std.mem.indexOf(u8, out.content, "FAILED") != null);
    try t.expect(std.mem.indexOf(u8, out.content, "WHY") != null);
    // 失败前已回传的部分不能丢 —— 子 agent 可能已经查到有用的东西
    try t.expect(std.mem.indexOf(u8, out.content, "partial-progress") != null);
    // 汇总行让模型一眼看到成败比例
    try t.expect(std.mem.indexOf(u8, out.content, "1 succeeded, 1 failed") != null);
    // 部分成功不算工具失败
    try t.expect(!out.is_error);

    // 全失败才算失败
    var all_bad = [_]TaskSlot{
        .{ .desc = "x", .alloc = a, .cwd = "/tmp", .argv = &.{ "sh", "-c", "exit 1" } },
    };
    runTaskSlot(&all_bad[0]);
    const bad = try formatTaskResults(a, &all_bad);
    try t.expect(bad.is_error);
}

test "context budget report separates fixed tool cost from headroom" {
    const t = std.testing;
    try agentmod.util.testInit();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = agentmod.cfgmod.Config{ .arena = &arena };
    var provs = [_]agentmod.cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");

    const r = try toolContextRemaining(@ptrCast(&agent), a, "{}");
    try t.expect(!r.is_error);

    // 用量必须已含工具定义 —— 修前这里报的是不含工具的数,虚报约 1024 token 余量
    try t.expect(std.mem.indexOf(u8, r.content, "fixed tool definitions") != null);
    // 压缩线而非窗口尽头才是模型能用的信号
    try t.expect(std.mem.indexOf(u8, r.content, "Auto-compaction triggers at 85%") != null);
    try t.expect(std.mem.indexOf(u8, r.content, "headroom") != null);

    // 塞满历史 → 余量归零而不是回绕成巨大的数
    const w = @as(usize, provs[0].context_window);
    while (agent.estTokens() < w) {
        try agent.messages.append(.{ .role = "user", .content = "x" ** 4096 });
    }
    const full = try toolContextRemaining(@ptrCast(&agent), a, "{}");
    try t.expect(std.mem.indexOf(u8, full.content, "remaining ~0") != null);
    try t.expect(std.mem.indexOf(u8, full.content, "~0 tokens of headroom") != null);
}

test "sub-agent argv inherits cwd, model and read-only mode" {
    const t = std.testing;
    try agentmod.util.testInit();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg = agentmod.cfgmod.Config{ .arena = &arena };
    var provs = [_]agentmod.cfgmod.Provider{.{ .name = "myprov", .api = .openai_completions, .base_url = "http://127.0.0.1:1/v1" }};
    cfg.providers = &provs;

    // 只读父 agent 不能通过委托绕出写权限
    var ro = try agentmod.Agent.initOpts(a, &cfg, "myprov", "my-model", "/tmp", .{ .read_only = true });
    const argv = try buildTaskArgv(a, &ro, "/proc/self/exe", "do it", false);
    var joined = std.array_list.Managed(u8).init(a);
    for (argv) |x| {
        try joined.appendSlice(x);
        try joined.append(' ');
    }
    const line = joined.items;
    try t.expect(std.mem.indexOf(u8, line, "--provider myprov") != null);
    try t.expect(std.mem.indexOf(u8, line, "-m my-model") != null);
    try t.expect(std.mem.indexOf(u8, line, "-r") != null);
    try t.expect(std.mem.indexOf(u8, line, "-n") != null); // 子 agent 不续载父会话

    // 非只读父 agent 不该传 -r
    var rw = try agentmod.Agent.init(a, &cfg, "myprov", "my-model", "/tmp");
    const argv2 = try buildTaskArgv(a, &rw, "/proc/self/exe", "do it", false);
    var j2 = std.array_list.Managed(u8).init(a);
    for (argv2) |x| {
        try j2.appendSlice(x);
        try j2.append(' ');
    }
    try t.expect(std.mem.indexOf(u8, j2.items, " -r ") == null);

    // 调用方可以**收紧**:可写父 agent 派一个只读子 agent(调研类任务)
    const argv3 = try buildTaskArgv(a, &rw, "/proc/self/exe", "just look", true);
    var j3 = std.array_list.Managed(u8).init(a);
    for (argv3) |x| {
        try j3.appendSlice(x);
        try j3.append(' ');
    }
    try t.expect(std.mem.indexOf(u8, j3.items, " -r ") != null);
}

test "prune plugin trims old tool outputs only" {
    const t = std.testing;
    try agentmod.util.testInit();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = agentmod.cfgmod.Config{ .arena = &arena };
    var provs = [_]agentmod.cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");

    // 旧 bash 轮 ×8(240KB)+ read 轮(30KB,不裁)+ 新 bash 轮(30KB,尾部保护)
    const big = "z" ** (30 * 1024);
    for (0..8) |i| {
        try agent.messages.append(.{ .role = "user", .content = "old q" });
        try agent.messages.append(.{ .role = "assistant", .content = "a", .tool_calls = &.{
            .{ .id = try std.fmt.allocPrint(a, "c_bash{d}", .{i}), .name = "bash", .args = "{}" },
        } });
        try agent.messages.append(.{ .role = "tool", .content = big, .tool_call_id = try std.fmt.allocPrint(a, "c_bash{d}", .{i}) });
    }
    try agent.messages.append(.{ .role = "user", .content = "old read q" });
    try agent.messages.append(.{ .role = "assistant", .content = "a", .tool_calls = &.{
        .{ .id = "c_read1", .name = "read", .args = "{}" },
    } });
    try agent.messages.append(.{ .role = "tool", .content = big, .tool_call_id = "c_read1" });
    try agent.messages.append(.{ .role = "user", .content = "new q" });
    try agent.messages.append(.{ .role = "assistant", .content = "a", .tool_calls = &.{
        .{ .id = "c_bash9", .name = "bash", .args = "{}" },
    } });
    try agent.messages.append(.{ .role = "tool", .content = big, .tool_call_id = "c_bash9" });

    pruneHook(@ptrCast(&agent));
    var found_trunc = false;
    var read_intact = false;
    var recent_intact = false;
    for (agent.messages.items) |m| {
        if (std.mem.eql(u8, m.role, "tool")) {
            if (std.mem.startsWith(u8, m.content, "[Output truncated")) found_trunc = true;
            if (std.mem.eql(u8, m.content, big)) {
                if (std.mem.eql(u8, m.tool_call_id orelse "", "c_read1")) read_intact = true;
                if (std.mem.eql(u8, m.tool_call_id orelse "", "c_bash9")) recent_intact = true;
            }
        }
    }
    try t.expect(found_trunc); // 部分旧 bash 输出被裁
    try t.expect(read_intact); // read 输出不裁
    try t.expect(recent_intact); // 尾部受保护
}

// =====================================================================
// 跨会话记忆插件:复用压缩摘要(零额外模型调用)。
// 压缩后 summary 追加到 <agentDir>/memories/<cwd-slug>.md;
// 新会话启动时 injectMemory 注入最近记忆(幂等,受 token 上限约束)。
// =====================================================================
const MEMORY_HEADER = "## Cross-session memory";
const MEMORY_MAX_CHARS = 8 * 1024; // 注入上限 ≈ 2K token

fn memoryFilePath(alloc: std.mem.Allocator, self: *agentmod.Agent) ![]const u8 {
    const dir = try agentmod.util.configDir(alloc);
    const slug = try agentmod.util.cwdSlug(alloc, self.cwd);
    const dir_path = try std.fs.path.join(alloc, &.{ dir, "memories" });
    std.Io.Dir.cwd().createDirPath(agentmod.util.io, dir_path) catch {};
    defer alloc.free(dir_path);
    return std.fs.path.join(alloc, &.{ dir, "memories", try std.fmt.allocPrint(alloc, "{s}.md", .{slug}) });
}

fn memoryAppend(ctx: ?*anyopaque, summary: []const u8) void {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    const path = memoryFilePath(self.alloc, self) catch return;
    defer self.alloc.free(path);
    var content = std.array_list.Managed(u8).init(self.alloc);
    defer content.deinit();
    const ts = @divTrunc(std.Io.Clock.now(.real, agentmod.util.io).nanoseconds, std.time.ns_per_ms);
    content.appendSlice(std.fmt.allocPrint(self.alloc, "## [{d}] {s}\n{s}\n\n", .{ ts, self.cwd, summary }) catch return) catch return;
    std.Io.Dir.cwd().writeFile(agentmod.util.io, .{ .sub_path = path, .data = content.items }) catch {};
}

/// 启动注入:读本项目记忆,追加到 system_prompt(幂等)。
pub fn injectMemory(self: *agentmod.Agent) void {
    if (std.mem.indexOf(u8, self.system_prompt, MEMORY_HEADER) != null) return; // 已注入
    const path = memoryFilePath(self.alloc, self) catch return;
    defer self.alloc.free(path);
    const content = std.Io.Dir.cwd().readFileAlloc(agentmod.util.io, path, self.alloc, .limited(64 * 1024)) catch return;
    defer self.alloc.free(content);
    if (content.len == 0) return;
    // 最近记忆优先:取尾部 ≤ MEMORY_MAX_CHARS
    const tail = if (content.len > MEMORY_MAX_CHARS) content[content.len - MEMORY_MAX_CHARS ..] else content;
    const new_prompt = std.fmt.allocPrint(self.alloc, "{s}\n\n{s}\n{s}", .{ self.system_prompt, MEMORY_HEADER, tail }) catch return;
    self.alloc.free(self.system_prompt);
    self.system_prompt = new_prompt;
}

/// ctx 工具占位 handler(真正逻辑在 ctx_handler;此路径仅 schema 展示用)。
fn toolCtxStub(_: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = args;
    return .{ .content = "internal: use ctx handler", .is_error = true };
}

// =====================================================================
// 命令规范化插件:危险模式拦截(防误操作)。
// =====================================================================
const DANGEROUS_PATTERNS = [_][]const u8{
    "sudo rm -rf /", "rm -rf / ", "rm -rf /*", "mkfs.", ":(){ :|:& };:", "> /dev/sd", "dd if=/dev/zero of=/dev/sd",
};

fn canonicalBlock(ctx: ?*anyopaque, name: []const u8, args: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, name, "bash")) return null;
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    for (DANGEROUS_PATTERNS) |pat| {
        if (std.mem.indexOf(u8, args, pat) != null) {
            return std.fmt.allocPrint(self.alloc, "error: blocked by command-canonicalization: pattern '{s}' detected. Rewrite the command safely or explain why it is necessary.", .{pat}) catch null;
        }
    }
    return null;
}

// =====================================================================
// 上下文预算查询插件:get_context_remaining 工具。
// =====================================================================
fn toolContextRemaining(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = args;
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    const w = @as(usize, self.provider.context_window);
    const used = self.estTokens();
    const remain = if (used < w) w - used else 0;
    // 报到压缩线的余量,不是报到窗口尽头 —— 模型该知道还能塞多少才会触发压缩,
    // 「离窗口还有多远」对它没有可操作性。
    const limit = w * agentmod.CTX_HARD_PERCENT / 100;
    const until_compact = if (used < limit) limit - used else 0;
    // 工具定义的份额单列:它是恒定开销,模型省不掉,不该让它以为那是可回收的空间。
    const tools_share = if (self.read_only) 0 else toolDefsTokens();
    return .{ .content = try std.fmt.allocPrint(
        arena,
        "Context budget: window {d} tokens, used ~{d} (of which ~{d} is the fixed tool definitions), remaining ~{d}. Auto-compaction triggers at {d}% ({d} tokens) — ~{d} tokens of headroom before that.",
        .{ w, used, tools_share, remain, agentmod.CTX_HARD_PERCENT, limit, until_compact },
    ) };
}

// =====================================================================
// 工件外置插件:大工具输出写文件,上下文只留引用(根治上下文暴增)。
// =====================================================================
const ARTIFACT_THRESHOLD_CHARS = 4 * 1024;

fn artifactStore(ctx: ?*anyopaque, name: []const u8, content: []const u8) ?[]const u8 {
    if (content.len <= ARTIFACT_THRESHOLD_CHARS) return null;
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    const dir = agentmod.util.configDir(self.alloc) catch return null;
    defer self.alloc.free(dir);
    const artifacts_dir = std.fs.path.join(self.alloc, &.{ dir, "artifacts" }) catch return null;
    defer self.alloc.free(artifacts_dir);
    std.Io.Dir.cwd().createDirPath(agentmod.util.io, artifacts_dir) catch {};
    const ts = @divTrunc(std.Io.Clock.now(.real, agentmod.util.io).nanoseconds, std.time.ns_per_ms);
    const fname = std.fmt.allocPrint(self.alloc, "{d}-{s}.txt", .{ ts, name }) catch return null;
    defer self.alloc.free(fname);
    const fpath = std.fs.path.join(self.alloc, &.{ artifacts_dir, fname }) catch return null;
    defer self.alloc.free(fpath);
    std.Io.Dir.cwd().writeFile(agentmod.util.io, .{ .sub_path = fpath, .data = content }) catch return null;
    // 引用替换:预览 + 文件路径(模型可 bash cat 取全量)
    const preview = content[0..@min(content.len, 400)];
    return std.fmt.allocPrint(self.alloc, "[Artifact stored: {s} ({d} bytes)]\n{s}\n...(truncated; read the artifact file for full content)", .{ fpath, content.len, preview }) catch null;
}

// =====================================================================
// git 状态插件:git_status 工具(每轮改动可见性)。
// =====================================================================
fn toolGitStatus(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = ctx;
    _ = args;
    // 极简:git status --short + 最近 diffstat(经 bash 子进程,失败返回提示)
    const status = agentmod.util.execShort(arena, &.{ "git", "status", "--short" }) catch return .{ .content = "not a git repo or git unavailable", .is_error = true };
    const diffstat = agentmod.util.execShort(arena, &.{ "git", "diff", "--stat" }) catch "";
    return .{ .content = try std.fmt.allocPrint(arena, "Git status:\n{s}{s}", .{ status, diffstat }) };
}

// =====================================================================
// web 搜索插件:web_search + fetch_url。
//
// 「路走不通要联网」的落点。两个工具是一对:搜索给线索,取正文才拿到答案 ——
// 只有搜索的话模型看到一堆标题和摘要,还得靠 bash+curl 硬啃 HTML。
// =====================================================================

/// URL 查询串编码。不编码的话「zig 0.16 std.Io」这种带空格的查询直接坏掉,
/// 而带空格恰恰是搜索查询的常态。
fn urlEncode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try aw.writer.writeByte(c);
        } else {
            // 手工两位十六进制:Zig 0.16 的格式串没有零填充语法
            const hex = "0123456789ABCDEF";
            try aw.writer.writeAll(&[_]u8{ '%', hex[c >> 4], hex[c & 0xF] });
        }
    }
    return aw.toOwnedSlice();
}

fn toolWebSearch(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = ctx;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{});
    const q = blk: {
        if (v == .object) {
            if (v.object.get("query")) |qv| {
                if (qv == .string) break :blk qv.string;
            }
        }
        break :blk "";
    };
    if (q.len == 0) return .{ .content = "error: web_search requires 'query'", .is_error = true };

    const endpoint = agentmod.util.getEnv("PIZ_WEB_SEARCH_URL") orelse "";
    if (endpoint.len == 0) {
        // 说清怎么修而不只是说坏了 —— 模型看到这条要能判断「换 bash+curl」
        return .{
            .content = "error: web_search is not configured. Set PIZ_WEB_SEARCH_URL to a JSON search endpoint that takes the query as its last parameter (e.g. http://localhost:8080/search?q= for SearXNG). Until then, use bash with curl for network lookups.",
            .is_error = true,
        };
    }
    const enc = try urlEncode(arena, q);
    const url = try std.fmt.allocPrint(arena, "{s}{s}&format=json", .{ endpoint, enc });
    const raw = agentmod.util.execShortTimeout(arena, &.{ "curl", "-sS", "--max-time", "15", url }, 20) catch
        return .{ .content = "error: search request failed (is the endpoint reachable?)", .is_error = true };
    // 整形成人读的列表:原样回 SearXNG 的 JSON 是几十 KB 的嵌套结构,
    // 模型得自己在里面翻 title/url/content,白烧上下文。
    return .{ .content = try shapeSearchResults(arena, raw, q) };
}

/// 把 SearXNG 的 JSON 压成紧凑列表。解析失败就原样返回 —— 端点可能不是 SearXNG。
fn shapeSearchResults(arena: std.mem.Allocator, raw: []const u8, query: []const u8) ![]const u8 {
    const MAX_RESULTS = 8;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return raw;
    if (root != .object) return raw;
    const results = root.object.get("results") orelse return raw;
    if (results != .array) return raw;

    var aw = std.Io.Writer.Allocating.init(arena);
    try aw.writer.print("Search results for \"{s}\":\n", .{query});
    var n: usize = 0;
    for (results.array.items) |item| {
        if (n >= MAX_RESULTS) break;
        if (item != .object) continue;
        const title = jsonStr(item, "title") orelse continue;
        const url = jsonStr(item, "url") orelse continue;
        const snippet = jsonStr(item, "content") orelse "";
        n += 1;
        try aw.writer.print("\n{d}. {s}\n   {s}\n", .{ n, title, url });
        if (snippet.len > 0) {
            const cut = @min(snippet.len, 300);
            try aw.writer.print("   {s}{s}\n", .{ snippet[0..cut], if (snippet.len > cut) "…" else "" });
        }
    }
    if (n == 0) return try std.fmt.allocPrint(arena, "No results for \"{s}\".", .{query});
    try aw.writer.writeAll("\nUse fetch_url on a result to read its full text.");
    return aw.toOwnedSlice();
}

fn jsonStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    if (f != .string) return null;
    if (f.string.len == 0) return null;
    return f.string;
}

/// fetch_url:取网页正文。
///
/// 没有这个工具,搜索就只是给了一串链接 —— 模型拿不到里面写了什么,
/// 只能退回 bash+curl 然后在原始 HTML 里翻。
fn toolFetchUrl(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = ctx;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{});
    const url = jsonStr(v, "url") orelse return .{ .content = "error: fetch_url requires 'url'", .is_error = true };
    // 只允许 http(s):否则 `file://` 能读本地任意文件,`gopher://` 之类能拿 curl 当跳板
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return .{ .content = "error: fetch_url only accepts http:// or https:// URLs", .is_error = true };
    }
    const act = activity.begin(.tool, "fetch_url", url, 30_000);
    defer act.release();

    const raw = agentmod.util.execShortTimeout(arena, &.{
        "curl", "-sSL",                                      "--max-time", "25", "--max-filesize", "8000000",
        "-H",   "user-agent: Mozilla/5.0 (compatible; piz)", url,
    }, 30) catch return .{ .content = "error: fetch failed (unreachable, timed out, or too large)", .is_error = true };

    const text = try htmlToText(arena, raw);
    if (text.len == 0) return .{ .content = "error: fetched page had no readable text", .is_error = true };
    const LIMIT = 24 * 1024;
    if (text.len > LIMIT) {
        return .{ .content = try std.fmt.allocPrint(arena, "{s}\n\n...[truncated at {d} of {d} chars]", .{ text[0..LIMIT], LIMIT, text.len }) };
    }
    return .{ .content = text };
}

/// HTML 抽正文。不是解析器,是「够用的降噪」:
/// 丢掉 script/style/head 的内容,去标签,解常见实体,压空白。
///
/// 为什么不引第三方 readability:piz 是零依赖项目,而模型对噪声的容忍度
/// 比人高得多 —— 它需要的是「能读到字」,不是排版还原。
fn htmlToText(arena: std.mem.Allocator, html: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(arena);
    var i: usize = 0;
    var last_was_space = true; // 开头不留空白
    while (i < html.len) {
        if (html[i] == '<') {
            // 整块跳过的标签:里面是代码/样式,不是正文。
            // 先求跳转位置再统一处理 —— `inline for` 里的 continue 归属编译期循环,
            // 不能用来跳过外层的 while 迭代。
            const skip_to: ?usize = blk: {
                inline for (.{ "script", "style", "head", "noscript", "svg" }) |tag| {
                    if (matchTagOpen(html, i, tag)) break :blk skipToTagClose(html, i, tag);
                }
                break :blk null;
            };
            if (skip_to) |to| {
                i = to;
                continue;
            }
            // 块级标签转成换行,免得整页挤成一行
            const is_break = matchTagOpen(html, i, "p") or matchTagOpen(html, i, "br") or
                matchTagOpen(html, i, "div") or matchTagOpen(html, i, "li") or
                matchTagOpen(html, i, "tr") or matchTagOpen(html, i, "h1") or
                matchTagOpen(html, i, "h2") or matchTagOpen(html, i, "h3");
            const end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse html.len;
            i = end + 1;
            if (is_break and out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
                try out.append('\n');
                last_was_space = true;
            }
            continue;
        }
        if (html[i] == '&') {
            if (decodeEntity(html, i)) |hit| {
                try out.appendSlice(hit.text);
                i = hit.next;
                last_was_space = false;
                continue;
            }
        }
        const c = html[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            // 压连续空白;换行保留一个(段落感对模型有用)
            if (!last_was_space) {
                try out.append(if (c == '\n') '\n' else ' ');
                last_was_space = true;
            }
            i += 1;
            continue;
        }
        try out.append(c);
        last_was_space = false;
        i += 1;
    }
    return std.mem.trim(u8, out.items, " \t\r\n");
}

fn matchTagOpen(html: []const u8, pos: usize, comptime tag: []const u8) bool {
    if (pos + 1 + tag.len >= html.len) return false;
    if (html[pos] != '<') return false;
    var p = pos + 1;
    if (html[p] == '/') p += 1;
    if (p + tag.len > html.len) return false;
    if (!std.ascii.eqlIgnoreCase(html[p .. p + tag.len], tag)) return false;
    // 标签名后必须是分隔符,否则 `<p>` 会匹配到 `<pre>`
    const after = html[p + tag.len];
    return after == '>' or after == ' ' or after == '\t' or after == '\n' or after == '/' or after == '\r';
}

/// 跳到 `</tag>` 之后。找不到闭合就跳到结尾 —— 残缺 HTML 很常见,不能死循环。
fn skipToTagClose(html: []const u8, pos: usize, comptime tag: []const u8) usize {
    var p = pos + 1;
    while (p < html.len) {
        if (html[p] == '<' and p + 1 < html.len and html[p + 1] == '/' and matchTagOpen(html, p, tag)) {
            return (std.mem.indexOfScalarPos(u8, html, p, '>') orelse html.len - 1) + 1;
        }
        p += 1;
    }
    return html.len;
}

const Entity = struct { text: []const u8, next: usize };

/// 解 HTML 实体。只覆盖真正常见的几个加数字实体 —— 其余原样留着,
/// 模型读得懂 `&hellip;`,为了它引一张几千项的表不值得。
fn decodeEntity(html: []const u8, pos: usize) ?Entity {
    const named = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "&amp;", .text = "&" },
        .{ .name = "&lt;", .text = "<" },
        .{ .name = "&gt;", .text = ">" },
        .{ .name = "&quot;", .text = "\"" },
        .{ .name = "&#39;", .text = "'" },
        .{ .name = "&apos;", .text = "'" },
        .{ .name = "&nbsp;", .text = " " },
        .{ .name = "&mdash;", .text = "—" },
        .{ .name = "&ndash;", .text = "–" },
        .{ .name = "&hellip;", .text = "…" },
    };
    for (named) |e| {
        if (std.mem.startsWith(u8, html[pos..], e.name)) {
            return .{ .text = e.text, .next = pos + e.name.len };
        }
    }
    return null;
}

// =====================================================================
// concept-graph 插件(最小版):压缩摘要中提取事实(decision/constraint/goal 等行)
// 追加到 <configDir>/concepts/<cwd-slug>.md,跨会话项目知识沉淀。
// =====================================================================
const FACT_MARKERS = [_][]const u8{ "decision:", "decided", "constraint:", "goal:", "convention:", "architecture:" };

fn conceptExtract(ctx: ?*anyopaque, summary: []const u8) void {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    var facts = std.array_list.Managed(u8).init(self.alloc);
    defer facts.deinit();
    var lines = std.mem.splitScalar(u8, summary, '\n');
    while (lines.next()) |line| {
        const l = std.mem.trim(u8, line, " \t");
        if (l.len == 0) continue;
        for (FACT_MARKERS) |mk| {
            if (std.ascii.startsWithIgnoreCase(l, mk)) {
                facts.appendSlice(l) catch {};
                facts.appendSlice("\n") catch {};
                break;
            }
        }
    }
    if (facts.items.len == 0) return;
    const dir = agentmod.util.configDir(self.alloc) catch return;
    defer self.alloc.free(dir);
    const slug = agentmod.util.cwdSlug(self.alloc, self.cwd) catch return;
    defer self.alloc.free(slug);
    const concepts_dir = std.fs.path.join(self.alloc, &.{ dir, "concepts" }) catch return;
    defer self.alloc.free(concepts_dir);
    std.Io.Dir.cwd().createDirPath(agentmod.util.io, concepts_dir) catch {};
    const fname = std.fmt.allocPrint(self.alloc, "{s}.md", .{slug}) catch return;
    defer self.alloc.free(fname);
    const fpath = std.fs.path.join(self.alloc, &.{ concepts_dir, fname }) catch return;
    defer self.alloc.free(fpath);
    // 追加(读旧+写新)
    var content = std.array_list.Managed(u8).init(self.alloc);
    defer content.deinit();
    if (std.Io.Dir.cwd().readFileAlloc(agentmod.util.io, fpath, self.alloc, .limited(256 * 1024))) |old| {
        defer self.alloc.free(old);
        content.appendSlice(old) catch {};
    } else |_| {}
    content.appendSlice(facts.items) catch {};
    std.Io.Dir.cwd().writeFile(agentmod.util.io, .{ .sub_path = fpath, .data = content.items }) catch {};
}

// =====================================================================
// elicitation 插件:ask_user 工具——信息不足时向用户提问。
// 极简语义:工具结果强提示模型"已向用户提问,等待回复",模型输出问题后停下。
// =====================================================================
fn toolAskUser(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    _ = self;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{});
    const q = blk: {
        if (v == .object) {
            if (v.object.get("question")) |qv| {
                if (qv == .string) break :blk qv.string;
            }
        }
        break :blk "";
    };
    if (q.len == 0) return .{ .content = "error: ask_user requires 'question'", .is_error = true };
    return .{ .content = try std.fmt.allocPrint(arena, "The user has been asked: {s}\nSTOP and present this question to the user in your reply. Do not guess or continue until the user answers in their next message.", .{q}) };
}

// =====================================================================
// compact 韧性插件:压缩失败时用备用模型重试一次。
// =====================================================================
fn compactFallback(ctx: ?*anyopaque) ?[]const u8 {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    if (self.provider.models.len > 1) return self.provider.models[1];
    return null;
}

// =====================================================================
// 任务编排插件:task 工具——spawn 自身子进程执行委托任务(可并行)。
//
// 子 agent **继承父 agent 的 cwd / provider / model / 只读模式**。不继承的话
// 委托出去的任务在错误的目录、用错误的模型跑 —— web 模式下多会话各自 cwd
// 不同,漏传 cwd 等于让子 agent 随机挑一个目录动手。
//
// 直接抓子进程 stdout 拿最终答复,不走 `-a`:`-a` 多套一层中间进程(它 spawn
// 完孙进程就退出),父 agent 只能拿到一个立刻失效的 pid,对不上任何会话。
// =====================================================================

/// 并行委托上限。子 agent 各自是完整进程(自带上下文窗口与工具集),
/// 比进程内工具调用重得多,所以上限比 MAX_PARALLEL_TOOLS(8)保守。
const MAX_PARALLEL_TASKS = 4;

/// 单个子 agent 回传的输出上限。超出截断——委托的产出应当是结论,
/// 不是原始日志;真需要全文就让子 agent 写文件。
const TASK_OUTPUT_LIMIT = 32 * 1024;

/// 子 agent 墙钟上限。子 agent 自己也会跑工具、也可能卡在等模型,
/// 没有上限的话父 agent 会无限期挂着 —— 而它此刻正占着一个工具执行槽。
const TASK_TIMEOUT_MS = 600_000;

/// 委托深度上限。子 agent 读的是**同一份** settings.json,所以它也带 `task`
/// 工具、也能继续 spawn —— 没有深度限制就是 fork bomb:每层 ×4,而每个
/// piz 进程是几十 MB。深度靠环境变量跨进程传递(唯一可靠的通道)。
const MAX_TASK_DEPTH = 2;
const DEPTH_ENV = "PIZ_TASK_DEPTH";

/// 当前进程的委托深度。顶层 agent = 0。
fn currentTaskDepth() usize {
    const env = agentmod.util.environ_map orelse return 0;
    const v = env.get(DEPTH_ENV) orelse return 0;
    return std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t\r\n"), 10) catch 0;
}

/// 拼子 agent 的 argv。**继承**父 agent 的 provider/model/只读模式:
/// 不继承的话委托出去的任务悄悄换成配置里的默认模型,而只读父 agent
/// 还能借委托绕出写权限。
///
/// `force_read_only` 只能**加**限制不能放宽:调用方可以要求子 agent 只读,
/// 但只读父 agent 的子 agent 必然只读 —— 否则委派就是一条提权通道。
fn buildTaskArgv(
    alloc: std.mem.Allocator,
    self: *agentmod.Agent,
    exe: []const u8,
    desc: []const u8,
    force_read_only: bool,
) ![]const []const u8 {
    var argv = std.array_list.Managed([]const u8).init(alloc);
    // -n:子 agent 开新会话,不续载父会话历史(否则两边同时写一个 jsonl)
    try argv.appendSlice(&.{ exe, "-p", desc, "-n", "--provider", self.provider.name, "-m", self.model });
    if (self.read_only or force_read_only) try argv.append("-r");
    // 交互式父 agent 每次工具调用都问用户;子 agent 没有终端可问,
    // 只能自动执行 —— 这是委托的固有代价,文档里写明。
    try argv.append("-x");
    return argv.toOwnedSlice();
}

/// 一个委托槽:spawn 后由工作线程抽输出 + wait。
const TaskSlot = struct {
    desc: []const u8,
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    /// 子进程环境:父环境 + PIZ_TASK_DEPTH+1(深度靠它跨进程传递)
    environ: ?*const std.process.Environ.Map = null,
    output: []const u8 = "",
    failed: bool = false,
    err: []const u8 = "",
    /// 墙钟耗时(毫秒)。回给模型 —— 它需要知道哪个子任务慢、慢多少,
    /// 才能判断下次是拆得更细还是别委派。
    elapsed_ms: i64 = 0,
};

fn runTaskSlot(slot: *TaskSlot) void {
    const io = agentmod.util.io;
    // 登记活动:委派原先是最长 10 分钟的纯黑盒,父 agent join() 干等,
    // 界面一动不动。登记后 TUI 能显示每个子 agent 的耗时与已回传字节。
    const act = activity.begin(.subagent, "task", slot.desc, TASK_TIMEOUT_MS);
    defer {
        slot.elapsed_ms = act.elapsedMs();
        act.release();
    }

    var child = std.process.spawn(io, .{
        .argv = slot.argv,
        .cwd = .{ .path = slot.cwd },
        .environ_map = slot.environ,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        // 新进程组:子 agent 自己还会 spawn bash,取消时要能整棵树收掉
        .pgid = 0,
    }) catch |e| {
        slot.failed = true;
        slot.err = @errorName(e);
        return;
    };
    const child_pid = child.id;
    const out_fd = child.stdout.?.handle;
    const err_fd = child.stderr.?.handle;
    agentmod.util.setNonBlock(out_fd);
    agentmod.util.setNonBlock(err_fd);

    var out = std.array_list.Managed(u8).init(slot.alloc);
    var errbuf = std.array_list.Managed(u8).init(slot.alloc);
    // stdout/stderr 分流:stdout 是子 agent 的答复,stderr 是诊断。
    var state = toolsmod.PipeState{
        .buf = &out,
        .err_buf = &errbuf,
        .out_fd = out_fd,
        .err_fd = err_fd,
    };
    // 不手动 close:child.wait 内部会关掉这两个 fd。提前 close 会让 wait
    // 撞上 EBADF(在 Debug 下直接 panic)。
    const stopped = toolsmod.pumpPipes(&state, TASK_TIMEOUT_MS, act) catch false;

    if (stopped) {
        const was_cancelled = act.cancelled();
        if (child_pid) |pid| toolsmod.killGroup(pid);
        // `Child.kill` block 到终止并清理资源,之后不能再 wait(会撞 assert)
        child.kill(io);
        slot.failed = true;
        // 区分「用户中断」与「跑超时」:前者不是故障,模型不该重试
        slot.err = if (was_cancelled) "interrupted by user" else "timed out";
        // 已回传的部分保留 —— 子 agent 可能已经给出有用的中间结论
        slot.output = if (out.items.len > TASK_OUTPUT_LIMIT)
            out.items[out.items.len - TASK_OUTPUT_LIMIT ..]
        else
            out.items;
        return;
    }
    const term = child.wait(io) catch |e| {
        slot.failed = true;
        slot.err = @errorName(e);
        return;
    };

    // 输出取**尾部**:子 agent 的结论在最后,截断要砍开头。
    slot.output = if (out.items.len > TASK_OUTPUT_LIMIT)
        out.items[out.items.len - TASK_OUTPUT_LIMIT ..]
    else
        out.items;

    switch (term) {
        .exited => |code| if (code != 0) {
            slot.failed = true;
            // 子 agent 的诊断在 stderr(如缺 API key),必须透出去,
            // 否则父 agent 只看到「失败」,不知道为什么。
            const e = std.mem.trim(u8, errbuf.items, " \t\r\n");
            slot.err = if (e.len > 0) e else "non-zero exit";
        },
        else => {
            slot.failed = true;
            slot.err = "killed or stopped";
        },
    }
}

fn toolTask(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{});

    // 深度闸门:子 agent 读同一份 settings.json,所以它也有 `task` 工具。
    // 不拦就是 fork bomb —— 每层 ×4,每个 piz 进程几十 MB。
    const depth = currentTaskDepth();
    if (depth >= MAX_TASK_DEPTH) {
        return .{
            .content = try std.fmt.allocPrint(
                arena,
                "error: delegation depth limit reached ({d}/{d}); do this task yourself instead of delegating further",
                .{ depth, MAX_TASK_DEPTH },
            ),
            .is_error = true,
        };
    }

    // 支持 {description} 或 {tasks: [{description}, ...]}(并行)。
    // 每个任务带自己的 read_only —— 调研类子 agent 不该有写权限,
    // 而同一次调用里「查一个、改一个」是常见组合。
    const TaskSpec = struct { desc: []const u8, read_only: bool };
    var specs = std.array_list.Managed(TaskSpec).init(arena);
    // 顶层 read_only 作为 tasks[] 各项的默认值
    const top_ro = blk: {
        if (v == .object) {
            if (v.object.get("read_only")) |r| {
                if (r == .bool) break :blk r.bool;
            }
        }
        break :blk false;
    };
    if (v == .object) {
        if (v.object.get("description")) |d| {
            if (d == .string and d.string.len > 0) try specs.append(.{ .desc = d.string, .read_only = top_ro });
        }
        if (v.object.get("tasks")) |ts| {
            if (ts == .array) {
                for (ts.array.items) |t| {
                    if (t != .object) continue;
                    const dd = t.object.get("description") orelse continue;
                    if (dd != .string or dd.string.len == 0) continue;
                    const ro = if (t.object.get("read_only")) |r| (if (r == .bool) r.bool else top_ro) else top_ro;
                    try specs.append(.{ .desc = dd.string, .read_only = ro });
                }
            }
        }
    }
    if (specs.items.len == 0) {
        return .{ .content = "error: task requires a non-empty 'description' or 'tasks[].description'", .is_error = true };
    }
    if (specs.items.len > MAX_PARALLEL_TASKS) {
        return .{
            .content = try std.fmt.allocPrint(arena, "error: too many tasks ({d}); max {d} per call — batch them or run the rest in a follow-up call", .{ specs.items.len, MAX_PARALLEL_TASKS }),
            .is_error = true,
        };
    }

    // 自身可执行文件的**绝对路径**。原来 spawn 裸名 "piz" 靠 PATH 查找,
    // 而 piz 通常不在 PATH 里 —— 实测 error.FileNotFound,委托一次都成功不了。
    const exe = std.process.executablePathAlloc(agentmod.util.io, arena) catch |e| {
        return .{
            .content = try std.fmt.allocPrint(arena, "error: cannot resolve own executable path: {s}", .{@errorName(e)}),
            .is_error = true,
        };
    };

    // 子进程环境 = 父环境 + 深度+1。不能直接改父进程的 environ_map:
    // 那是全局单例,并行的兄弟槽会互相踩。
    var child_env = std.process.Environ.Map.init(arena);
    if (agentmod.util.environ_map) |pe| {
        var it = pe.iterator();
        while (it.next()) |kv| try child_env.put(kv.key_ptr.*, kv.value_ptr.*);
    }
    try child_env.put(DEPTH_ENV, try std.fmt.allocPrint(arena, "{d}", .{depth + 1}));

    const slots = try arena.alloc(TaskSlot, specs.items.len);
    for (slots, specs.items) |*slot, spec| {
        slot.* = .{
            .desc = spec.desc,
            .alloc = arena,
            .argv = try buildTaskArgv(arena, self, exe, spec.desc, spec.read_only),
            .cwd = self.cwd,
            .environ = &child_env,
        };
    }

    // 并行跑。单个任务不开线程,省一次 spawn/join。
    if (slots.len == 1) {
        runTaskSlot(&slots[0]);
    } else {
        const threads = try arena.alloc(?std.Thread, slots.len);
        for (slots, threads) |*slot, *th| {
            th.* = std.Thread.spawn(.{}, runTaskSlot, .{slot}) catch blk: {
                runTaskSlot(slot); // 开不出线程就当场跑,不能静默丢任务
                break :blk null;
            };
        }
        for (threads) |th| if (th) |t| t.join();
    }

    return formatTaskResults(arena, slots);
}

/// 把委派结果拼成给模型看的文本。
///
/// 人读格式而非 JSON:子 agent 的输出是多行文本,JSON 转义会把每个换行变成
/// `\n` 字面量,模型得先解析再还原,白付两次代价。失败任务标 FAILED 并保留
/// 已回传的部分 —— 一个跑挂的子 agent 常常已经查到了有用的东西。
fn formatTaskResults(arena: std.mem.Allocator, slots: []const TaskSlot) !toolsmod.Result {
    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    const writer = &aw.writer;
    var ok: usize = 0;
    for (slots) |slot| {
        if (!slot.failed) ok += 1;
    }

    if (slots.len > 1) {
        try writer.print("Delegated {d} tasks: {d} succeeded, {d} failed.\n", .{ slots.len, ok, slots.len - ok });
    }
    for (slots, 1..) |slot, i| {
        var eb: [24]u8 = undefined;
        const el = activity.formatElapsed(&eb, slot.elapsed_ms);
        const verdict: []const u8 = if (slot.failed) "FAILED" else "ok";
        if (slots.len > 1) {
            try writer.print("\n=== task {d}/{d} ({s}) [{s}] ===\n", .{ i, slots.len, verdict, el });
        } else {
            try writer.print("=== {s} [{s}] ===\n", .{ verdict, el });
        }
        try writer.print("task: {s}\n", .{slot.desc[0..@min(slot.desc.len, 300)]});
        if (slot.failed) {
            try writer.print("error: {s}\n", .{slot.err[0..@min(slot.err.len, 512)]});
            const partial = std.mem.trim(u8, slot.output, " \t\r\n");
            if (partial.len > 0) {
                try writer.print("partial output before failing:\n{s}\n", .{partial});
            }
        } else {
            try writer.print("{s}\n", .{std.mem.trim(u8, slot.output, " \t\r\n")});
        }
    }
    // 全失败才算工具失败:部分成功的结果对模型仍有用。
    return .{ .content = try aw.toOwnedSlice(), .is_error = ok == 0 };
}

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
fn toolTodoWrite(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
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
fn toolTodoRead(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = args;
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    return renderTodos(arena, TodoStore.get(@intFromPtr(self)));
}

// =====================================================================
// lsp 插件:语言服务器桥接(definition / references / hover / rename / diagnostics)。
// 官方 pi 没有这个能力 —— 模型只能靠 grep 猜符号引用,漏掉重命名/re-export/遮蔽。
// 走 LSP over stdio + JSON-RPC。服务器缺失时返回安装提示而非崩溃。
// =====================================================================

/// LSP 请求超时。语言服务器首次索引大仓库可能慢,但绝不能永久阻塞 agent 循环。
const LSP_TIMEOUT_MS: i64 = 15_000;

/// 按文件扩展名选语言服务器。argv[0] 不存在时由调用方给安装提示。
fn lspServerFor(path: []const u8) ?[]const []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".zig")) return &.{"zls"};
    if (std.mem.eql(u8, ext, ".rs")) return &.{"rust-analyzer"};
    if (std.mem.eql(u8, ext, ".py")) return &.{ "pyright-langserver", "--stdio" };
    if (std.mem.eql(u8, ext, ".go")) return &.{"gopls"};
    if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h") or
        std.mem.eql(u8, ext, ".cc") or std.mem.eql(u8, ext, ".cpp") or
        std.mem.eql(u8, ext, ".hpp")) return &.{"clangd"};
    if (std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx") or
        std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".jsx") or
        std.mem.eql(u8, ext, ".mjs")) return &.{ "typescript-language-server", "--stdio" };
    return null;
}

/// LSP 的 languageId(initialize 与 didOpen 都要)。
fn lspLanguageId(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".zig")) return "zig";
    if (std.mem.eql(u8, ext, ".rs")) return "rust";
    if (std.mem.eql(u8, ext, ".py")) return "python";
    if (std.mem.eql(u8, ext, ".go")) return "go";
    if (std.mem.eql(u8, ext, ".ts")) return "typescript";
    if (std.mem.eql(u8, ext, ".tsx")) return "typescriptreact";
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".mjs")) return "javascript";
    if (std.mem.eql(u8, ext, ".jsx")) return "javascriptreact";
    if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h")) return "c";
    return "plaintext";
}

/// 编码一条 JSON-RPC 消息:`Content-Length: N\r\n\r\n<body>`。
fn lspEncodeFrame(alloc: std.mem.Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

/// 从缓冲区头部解出一帧。返回 body 与该帧总长(供调用方推进游标)。
/// 帧不完整返回 null —— 调用方继续读。
const LspFrame = struct { body: []const u8, consumed: usize };

fn lspDecodeFrame(buf: []const u8) ?LspFrame {
    // 头部以空行结束(\r\n\r\n,容忍 \n\n)
    const sep_crlf = std.mem.indexOf(u8, buf, "\r\n\r\n");
    const sep_lf = std.mem.indexOf(u8, buf, "\n\n");
    var head_end: usize = undefined;
    var body_start: usize = undefined;
    if (sep_crlf) |i| {
        // 若 \n\n 更早出现则以它为界(某些服务器不严格用 CRLF)
        if (sep_lf != null and sep_lf.? < i) {
            head_end = sep_lf.?;
            body_start = sep_lf.? + 2;
        } else {
            head_end = i;
            body_start = i + 4;
        }
    } else if (sep_lf) |i| {
        head_end = i;
        body_start = i + 2;
    } else return null; // 头部还没读完

    // 找 Content-Length
    var len: ?usize = null;
    var it = std.mem.splitAny(u8, buf[0..head_end], "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "content-length")) continue;
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        len = std.fmt.parseInt(usize, val, 10) catch null;
    }
    const body_len = len orelse return null; // 无 Content-Length:等更多数据或视为坏帧
    if (buf.len < body_start + body_len) return null; // body 还没读全
    return .{ .body = buf[body_start .. body_start + body_len], .consumed = body_start + body_len };
}

/// 在文件内容里找符号首次出现的位置,返回 0-based (line, character)。
/// 模型给符号名而非行列时用这个 —— 降低调用门槛。
fn lspFindSymbol(content: []const u8, symbol: []const u8) ?struct { line: u32, character: u32 } {
    if (symbol.len == 0) return null;
    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| : (line_no += 1) {
        if (std.mem.indexOf(u8, line, symbol)) |col| {
            return .{ .line = line_no, .character = @intCast(col) };
        }
    }
    return null;
}

/// 把绝对路径转成 file:// URI(百分号编码空格等)。
fn lspPathToUri(alloc: std.mem.Allocator, abs_path: []const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try aw.writer.writeAll("file://");
    for (abs_path) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '/', '-', '_', '.', '~' => try aw.writer.writeByte(c),
            else => try aw.writer.print("%{X:0>2}", .{c}),
        }
    }
    return aw.toOwnedSlice();
}

/// file:// URI 转回路径(解百分号编码)。非 file:// 原样返回。
fn lspUriToPath(alloc: std.mem.Allocator, uri: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return alloc.dupe(u8, uri);
    const raw = uri["file://".len..];
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '%' and i + 2 < raw.len) {
            const hi = std.fmt.charToDigit(raw[i + 1], 16) catch {
                try aw.writer.writeByte(raw[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(raw[i + 2], 16) catch {
                try aw.writer.writeByte(raw[i]);
                i += 1;
                continue;
            };
            try aw.writer.writeByte(hi * 16 + lo);
            i += 3;
            continue;
        }
        try aw.writer.writeByte(raw[i]);
        i += 1;
    }
    return aw.toOwnedSlice();
}

/// 一次 LSP 会话:spawn 服务器 → initialize → didOpen → 目标请求 → shutdown。
/// 每次工具调用起一个新进程。不缓存服务器 —— 简单、无状态泄漏,代价是首次索引开销。
const LspSession = struct {
    child: std.process.Child,
    arena: std.mem.Allocator,
    buf: std.array_list.Managed(u8),
    next_id: i64 = 1,
    deadline_ns: i96,

    fn start(arena: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !LspSession {
        _ = cwd;
        const child = try std.process.spawn(agentmod.util.io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        if (child.stdout) |f| agentmod.util.setNonBlock(f.handle);
        return .{
            .child = child,
            .arena = arena,
            .buf = std.array_list.Managed(u8).init(arena),
            .deadline_ns = std.Io.Clock.now(.awake, agentmod.util.io).nanoseconds +
                @as(i96, LSP_TIMEOUT_MS) * std.time.ns_per_ms,
        };
    }

    /// 结束会话:发 shutdown/exit(尽力),然后杀进程收尸。
    /// 注意:`kill` 自己会关闭并清理 stdin/stdout,这里**不能**再手动 close ——
    /// 否则 double close,std 会在 Debug 下 panic(EBADF use-after-free)。
    fn deinit(self: *LspSession) void {
        self.send("{\"jsonrpc\":\"2.0\",\"id\":9999,\"method\":\"shutdown\"}") catch {};
        self.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}") catch {};
        // 不等自然退出:某些服务器收到 exit 后仍挂着,直接 kill 更可靠。
        // kill 内部做 childCleanupPosix,关掉全部管道并 wait 收尸。
        self.child.kill(agentmod.util.io);
    }

    fn send(self: *LspSession, body: []const u8) !void {
        const frame = try lspEncodeFrame(self.arena, body);
        const stdin = self.child.stdin orelse return error.NoStdin;
        var wbuf: [4096]u8 = undefined;
        var w = stdin.writer(agentmod.util.io, &wbuf);
        try w.interface.writeAll(frame);
        try w.flush();
    }

    /// 读到一条 id 匹配的响应。通知与其他 id 的响应被跳过。
    /// 超时返回 error.LspTimeout —— 绝不无限等。
    fn awaitResponse(self: *LspSession, want_id: i64) ![]const u8 {
        const stdout = self.child.stdout orelse return error.NoStdout;
        var chunk: [8192]u8 = undefined;
        var cursor: usize = 0;
        while (true) {
            // 先尝试从已有缓冲里解帧
            while (lspDecodeFrame(self.buf.items[cursor..])) |frame| {
                cursor += frame.consumed;
                const root = std.json.parseFromSliceLeaky(std.json.Value, self.arena, frame.body, .{}) catch continue;
                if (root != .object) continue;
                const id = root.object.get("id") orelse continue; // 通知,无 id
                const got: i64 = switch (id) {
                    .integer => |i| i,
                    .float => |f| @intFromFloat(f),
                    else => continue,
                };
                if (got != want_id) continue;
                return frame.body;
            }
            if (std.Io.Clock.now(.awake, agentmod.util.io).nanoseconds > self.deadline_ns) return error.LspTimeout;
            // 读更多
            var pfd = [_]std.posix.pollfd{.{ .fd = stdout.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const n = std.posix.poll(&pfd, 100) catch 0;
            if (n == 0) continue;
            const got = std.posix.read(stdout.handle, &chunk) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return error.LspReadFailed,
            };
            if (got == 0) return error.LspClosed; // 服务器退出
            try self.buf.appendSlice(chunk[0..got]);
        }
    }

    /// 发一个请求并等它的响应。返回响应体 JSON。
    fn request(self: *LspSession, method: []const u8, params_json: []const u8) ![]const u8 {
        const id = self.next_id;
        self.next_id += 1;
        const body = try std.fmt.allocPrint(
            self.arena,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
            .{ id, method, params_json },
        );
        try self.send(body);
        return self.awaitResponse(id);
    }

    fn notify(self: *LspSession, method: []const u8, params_json: []const u8) !void {
        const body = try std.fmt.allocPrint(
            self.arena,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}",
            .{ method, params_json },
        );
        try self.send(body);
    }
};

/// 把 LSP 的 Location / Location[] / LocationLink[] 渲染成 path:line:col 清单。
fn lspRenderLocations(arena: std.mem.Allocator, result: std.json.Value, writer: *std.Io.Writer) !usize {
    var n: usize = 0;
    const items: []const std.json.Value = switch (result) {
        .array => |a| a.items,
        .object => blk: {
            const one = try arena.alloc(std.json.Value, 1);
            one[0] = result;
            break :blk one;
        },
        else => return 0,
    };
    for (items) |loc| {
        if (loc != .object) continue;
        // Location 用 uri+range;LocationLink 用 targetUri+targetRange
        const uri_v = loc.object.get("uri") orelse loc.object.get("targetUri") orelse continue;
        if (uri_v != .string) continue;
        const range_v = loc.object.get("range") orelse loc.object.get("targetRange") orelse continue;
        if (range_v != .object) continue;
        const start = range_v.object.get("start") orelse continue;
        if (start != .object) continue;
        const line = if (start.object.get("line")) |l| (if (l == .integer) l.integer else 0) else 0;
        const ch = if (start.object.get("character")) |c| (if (c == .integer) c.integer else 0) else 0;
        const path = try lspUriToPath(arena, uri_v.string);
        // LSP 行列是 0-based,展示成 1-based 与编辑器一致
        try writer.print("{s}:{d}:{d}\n", .{ path, line + 1, ch + 1 });
        n += 1;
    }
    return n;
}

/// lsp 工具主体。
fn toolLsp(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{}) catch
        return .{ .content = "error: invalid JSON arguments", .is_error = true };
    if (v != .object) return .{ .content = "error: arguments must be an object", .is_error = true };

    const action = blk: {
        const a = v.object.get("action") orelse break :blk "";
        break :blk if (a == .string) a.string else "";
    };
    if (action.len == 0) return .{ .content = "error: missing 'action' (definition | references | hover | rename | diagnostics)", .is_error = true };
    const file = blk: {
        const f = v.object.get("file") orelse break :blk "";
        break :blk if (f == .string) f.string else "";
    };
    if (file.len == 0) return .{ .content = "error: missing 'file'", .is_error = true };

    const argv = lspServerFor(file) orelse return .{
        .content = try std.fmt.allocPrint(arena, "error: no language server mapped for '{s}'. Supported: .zig(zls) .rs(rust-analyzer) .py(pyright-langserver) .go(gopls) .ts/.js(typescript-language-server) .c/.cpp(clangd)", .{std.fs.path.extension(file)}),
        .is_error = true,
    };

    // 读文件:既要 didOpen 的内容,也用于 symbol 定位
    const content = std.Io.Dir.cwd().readFileAlloc(agentmod.util.io, file, arena, .limited(8 * 1024 * 1024)) catch |err|
        return .{ .content = try std.fmt.allocPrint(arena, "error reading {s}: {s}", .{ file, @errorName(err) }), .is_error = true };

    // 定位:优先显式 line/character,否则按 symbol 搜首次出现
    var line: u32 = 0;
    var character: u32 = 0;
    const needs_pos = !std.mem.eql(u8, action, "diagnostics");
    if (needs_pos) {
        if (v.object.get("line")) |l| {
            const raw: i64 = switch (l) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => 1,
            };
            line = @intCast(@max(0, raw - 1)); // 入参 1-based → LSP 0-based
            if (v.object.get("character")) |c| {
                const rc: i64 = switch (c) {
                    .integer => |i| i,
                    .float => |f| @intFromFloat(f),
                    else => 1,
                };
                character = @intCast(@max(0, rc - 1));
            }
        } else if (v.object.get("symbol")) |s| {
            if (s != .string or s.string.len == 0) return .{ .content = "error: 'symbol' must be a non-empty string", .is_error = true };
            const found = lspFindSymbol(content, s.string) orelse return .{
                .content = try std.fmt.allocPrint(arena, "error: symbol '{s}' not found in {s}", .{ s.string, file }),
                .is_error = true,
            };
            line = found.line;
            character = found.character;
        } else {
            return .{ .content = "error: need 'symbol' or 'line' to locate the position", .is_error = true };
        }
    }

    var session = LspSession.start(arena, argv, self.cwd) catch
        return .{
            .content = try std.fmt.allocPrint(arena, "error: cannot start language server '{s}' — is it installed and on PATH?", .{argv[0]}),
            .is_error = true,
        };
    defer session.deinit();

    const abs_file = if (std.fs.path.isAbsolute(file)) try arena.dupe(u8, file) else try agentmod.util.joinPath(arena, self.cwd, file);
    const file_uri = try lspPathToUri(arena, abs_file);
    const root_uri = try lspPathToUri(arena, self.cwd);

    // initialize:声明最小能力集
    const init_params = try std.fmt.allocPrint(arena,
        \\{{"processId":null,"rootUri":"{s}","capabilities":{{"textDocument":{{"definition":{{"linkSupport":true}},"references":{{}},"hover":{{"contentFormat":["plaintext","markdown"]}},"rename":{{}},"publishDiagnostics":{{}}}}}},"workspaceFolders":null}}
    , .{root_uri});
    _ = session.request("initialize", init_params) catch |err|
        return .{
            .content = try std.fmt.allocPrint(arena, "error: language server '{s}' handshake failed: {s}", .{ argv[0], @errorName(err) }),
            .is_error = true,
        };
    session.notify("initialized", "{}") catch {};

    // didOpen:把文件内容喂进去(服务器不必自己读盘,也支持未保存内容)
    var text_json = std.Io.Writer.Allocating.init(arena);
    defer text_json.deinit();
    try std.json.Stringify.value(content, .{}, &text_json.writer);
    const open_params = try std.fmt.allocPrint(arena,
        \\{{"textDocument":{{"uri":"{s}","languageId":"{s}","version":1,"text":{s}}}}}
    , .{ file_uri, lspLanguageId(file), text_json.written() });
    session.notify("textDocument/didOpen", open_params) catch {};

    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    const pos_params = try std.fmt.allocPrint(arena,
        \\{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}}}}
    , .{ file_uri, line, character });

    if (std.mem.eql(u8, action, "definition") or std.mem.eql(u8, action, "references") or std.mem.eql(u8, action, "implementation") or std.mem.eql(u8, action, "type_definition")) {
        const method = if (std.mem.eql(u8, action, "definition"))
            "textDocument/definition"
        else if (std.mem.eql(u8, action, "references"))
            "textDocument/references"
        else if (std.mem.eql(u8, action, "implementation"))
            "textDocument/implementation"
        else
            "textDocument/typeDefinition";
        const params = if (std.mem.eql(u8, action, "references"))
            try std.fmt.allocPrint(arena,
                \\{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}},"context":{{"includeDeclaration":true}}}}
            , .{ file_uri, line, character })
        else
            pos_params;
        const resp = session.request(method, params) catch |err|
            return lspError(arena, argv[0], action, err);
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, resp, .{}) catch
            return .{ .content = "error: language server returned invalid JSON", .is_error = true };
        if (root == .object) {
            if (root.object.get("error")) |e| return lspServerError(arena, e);
        }
        const result = if (root == .object) (root.object.get("result") orelse std.json.Value{ .null = {} }) else std.json.Value{ .null = {} };
        const n = try lspRenderLocations(arena, result, &aw.writer);
        if (n == 0) return .{ .content = try std.fmt.allocPrint(arena, "no {s} found at {s}:{d}:{d}", .{ action, file, line + 1, character + 1 }) };
        return toolsmod.capped(arena, aw.written(), "lsp", aw.written().len);
    }

    if (std.mem.eql(u8, action, "hover")) {
        const resp = session.request("textDocument/hover", pos_params) catch |err|
            return lspError(arena, argv[0], action, err);
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, resp, .{}) catch
            return .{ .content = "error: language server returned invalid JSON", .is_error = true };
        if (root == .object) {
            if (root.object.get("error")) |e| return lspServerError(arena, e);
        }
        const result = if (root == .object) (root.object.get("result") orelse std.json.Value{ .null = {} }) else std.json.Value{ .null = {} };
        if (result != .object) return .{ .content = try std.fmt.allocPrint(arena, "no hover info at {s}:{d}:{d}", .{ file, line + 1, character + 1 }) };
        const contents = result.object.get("contents") orelse return .{ .content = "no hover info" };
        // contents 可能是 string / {value} / MarkedString[]
        switch (contents) {
            .string => |s| try aw.writer.writeAll(s),
            .object => |o| {
                if (o.get("value")) |val| {
                    if (val == .string) try aw.writer.writeAll(val.string);
                }
            },
            .array => |a| for (a.items) |item| {
                switch (item) {
                    .string => |s| try aw.writer.print("{s}\n", .{s}),
                    .object => |o| if (o.get("value")) |val| {
                        if (val == .string) try aw.writer.print("{s}\n", .{val.string});
                    },
                    else => {},
                }
            },
            else => {},
        }
        if (aw.written().len == 0) return .{ .content = "no hover info" };
        return toolsmod.capped(arena, aw.written(), "lsp", aw.written().len);
    }

    if (std.mem.eql(u8, action, "rename")) {
        const new_name = blk: {
            const nn = v.object.get("new_name") orelse break :blk "";
            break :blk if (nn == .string) nn.string else "";
        };
        if (new_name.len == 0) return .{ .content = "error: rename needs 'new_name'", .is_error = true };
        const params = try std.fmt.allocPrint(arena,
            \\{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}},"newName":"{s}"}}
        , .{ file_uri, line, character, new_name });
        const resp = session.request("textDocument/rename", params) catch |err|
            return lspError(arena, argv[0], action, err);
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, resp, .{}) catch
            return .{ .content = "error: language server returned invalid JSON", .is_error = true };
        if (root == .object) {
            if (root.object.get("error")) |e| return lspServerError(arena, e);
        }
        const result = if (root == .object) (root.object.get("result") orelse std.json.Value{ .null = {} }) else std.json.Value{ .null = {} };
        if (result != .object) return .{ .content = "rename produced no edits", .is_error = true };
        // 只报告将改动的位置,不落盘 —— 落盘要走 edit 工具以便过权限门与写锁
        try aw.writer.print("rename '{s}' would touch:\n", .{new_name});
        var total: usize = 0;
        if (result.object.get("changes")) |changes| {
            if (changes == .object) {
                var it = changes.object.iterator();
                while (it.next()) |entry| {
                    const path = try lspUriToPath(arena, entry.key_ptr.*);
                    const edits = entry.value_ptr.*;
                    if (edits != .array) continue;
                    try aw.writer.print("  {s}: {d} edits\n", .{ path, edits.array.items.len });
                    total += edits.array.items.len;
                }
            }
        }
        if (result.object.get("documentChanges")) |dc| {
            if (dc == .array) {
                for (dc.array.items) |item| {
                    if (item != .object) continue;
                    const td = item.object.get("textDocument") orelse continue;
                    if (td != .object) continue;
                    const uri_v = td.object.get("uri") orelse continue;
                    if (uri_v != .string) continue;
                    const edits = item.object.get("edits") orelse continue;
                    if (edits != .array) continue;
                    const path = try lspUriToPath(arena, uri_v.string);
                    try aw.writer.print("  {s}: {d} edits\n", .{ path, edits.array.items.len });
                    total += edits.array.items.len;
                }
            }
        }
        if (total == 0) return .{ .content = "rename produced no edits (symbol may not be renameable here)" };
        try aw.writer.writeAll("\nApply them with the edit or multi_edit tool — lsp does not write files.\n");
        return toolsmod.capped(arena, aw.written(), "lsp", aw.written().len);
    }

    if (std.mem.eql(u8, action, "diagnostics")) {
        // 诊断是服务器主动推的通知,没有请求可等。发一个 hover 当同步栅栏,
        // 让服务器有机会完成分析并把 publishDiagnostics 推过来。
        _ = session.request("textDocument/hover", try std.fmt.allocPrint(arena,
            \\{{"textDocument":{{"uri":"{s}"}},"position":{{"line":0,"character":0}}}}
        , .{file_uri})) catch {};
        var count: usize = 0;
        var cursor: usize = 0;
        while (lspDecodeFrame(session.buf.items[cursor..])) |frame| {
            cursor += frame.consumed;
            const root = std.json.parseFromSliceLeaky(std.json.Value, arena, frame.body, .{}) catch continue;
            if (root != .object) continue;
            const m = root.object.get("method") orelse continue;
            if (m != .string or !std.mem.eql(u8, m.string, "textDocument/publishDiagnostics")) continue;
            const params = root.object.get("params") orelse continue;
            if (params != .object) continue;
            const diags = params.object.get("diagnostics") orelse continue;
            if (diags != .array) continue;
            for (diags.array.items) |d| {
                if (d != .object) continue;
                const rng = d.object.get("range") orelse continue;
                if (rng != .object) continue;
                const start = rng.object.get("start") orelse continue;
                if (start != .object) continue;
                const dl = if (start.object.get("line")) |x| (if (x == .integer) x.integer else 0) else 0;
                const dc = if (start.object.get("character")) |x| (if (x == .integer) x.integer else 0) else 0;
                const sev = if (d.object.get("severity")) |x| (if (x == .integer) x.integer else 0) else 0;
                const label = switch (sev) {
                    1 => "error",
                    2 => "warning",
                    3 => "info",
                    4 => "hint",
                    else => "diag",
                };
                const msg = if (d.object.get("message")) |x| (if (x == .string) x.string else "") else "";
                try aw.writer.print("{s}:{d}:{d}: {s}: {s}\n", .{ file, dl + 1, dc + 1, label, msg });
                count += 1;
            }
        }
        if (count == 0) return .{ .content = try std.fmt.allocPrint(arena, "no diagnostics reported for {s}", .{file}) };
        return toolsmod.capped(arena, aw.written(), "lsp", aw.written().len);
    }

    return .{
        .content = try std.fmt.allocPrint(arena, "error: unknown action '{s}'. Use definition | references | hover | rename | diagnostics | implementation | type_definition", .{action}),
        .is_error = true,
    };
}

/// 传输层失败的统一提示(超时/服务器崩了)。
fn lspError(arena: std.mem.Allocator, server: []const u8, action: []const u8, err: anyerror) toolsmod.Result {
    const hint = switch (err) {
        error.LspTimeout => "the server may still be indexing a large project; retry, or narrow the request",
        error.LspClosed => "the server exited unexpectedly; check that it runs standalone in this project",
        else => "check that the server works standalone in this project",
    };
    return .{
        .content = std.fmt.allocPrint(arena, "error: {s} {s} failed ({s}) — {s}", .{ server, action, @errorName(err), hint }) catch "error: lsp request failed",
        .is_error = true,
    };
}

/// 服务器返回的 JSON-RPC error 对象。
fn lspServerError(arena: std.mem.Allocator, e: std.json.Value) toolsmod.Result {
    var msg: []const u8 = "unknown error";
    if (e == .object) {
        if (e.object.get("message")) |m| {
            if (m == .string) msg = m.string;
        }
    }
    return .{
        .content = std.fmt.allocPrint(arena, "error: language server reported: {s}", .{msg}) catch "error: language server reported an error",
        .is_error = true,
    };
}

/// 内置插件表。
///
/// 分两类:
/// - **默认启用**:上下文管理与安全类。不开就退化(上下文爆掉、危险命令直通),
///   它们不给模型加工具,只挂钩子,零 token 成本。
/// - **默认关闭**(`enabled_by_default = false`):场景化工具。每个都会往每轮请求的
///   tools 数组里加条目 —— 不用的时候是纯 token 浪费,还增加模型选错工具的概率。
///   用 settings.json 的 `plugins` 数组或 `--plugin <name>` 开启。
pub const builtin_plugins = [_]Plugin{
    // ---- 默认启用:只挂钩子,不加工具 ----
    .{ .name = "tool-output-pruner", .before_turn = pruneHook },
    .{ .name = "cross-session-memory", .on_compact = memoryAppend },
    .{ .name = "command-canonicalization", .on_tool_before = canonicalBlock },
    .{ .name = "artifact-store", .on_tool_result = artifactStore },
    .{ .name = "compact-resilience", .on_compact_failed = compactFallback },
    .{ .name = "concept-graph", .on_compact = conceptExtract },

    // ---- 默认关闭:按需开启的场景化工具 ----
    .{ .name = "skills", .enabled_by_default = false, .tools = &.{
        .{
            .name = "skill",
            .desc = "Load a skill's SKILL.md content by name. Skill names are listed in the system prompt.",
            .schema =
            \\{"type":"object","properties":{"name":{"type":"string","description":"Skill name as listed in the skills index."}},"required":["name"]}
            ,
            .handler = toolsmod.toolSkill,
        },
    } },
    .{ .name = "context-budget", .enabled_by_default = false, .tools = &.{
        .{
            .name = "get_context_remaining",
            .desc = "Report remaining context budget in tokens.",
            .schema = toolsmod.EMPTY_SCHEMA,
            .handler = toolCtxStub,
            .ctx_handler = toolContextRemaining,
        },
    } },
    .{ .name = "git-awareness", .enabled_by_default = false, .tools = &.{
        .{
            .name = "git_status",
            .desc = "Show git status and diff stat for the working tree.",
            .schema = toolsmod.EMPTY_SCHEMA,
            .handler = toolCtxStub,
            .ctx_handler = toolGitStatus,
        },
    } },
    .{ .name = "web-search", .enabled_by_default = false, .tools = &.{
        .{
            .name = "web_search",
            .desc = "Search the web when local information is insufficient or possibly out of date. Returns a ranked list of titles, URLs and snippets; follow up with fetch_url to read a result in full. Requires PIZ_WEB_SEARCH_URL.",
            .schema =
            \\{"type":"object","properties":{"query":{"type":"string","description":"Search query."}},"required":["query"]}
            ,
            .handler = toolCtxStub,
            .ctx_handler = toolWebSearch,
        },
        .{
            .name = "fetch_url",
            .desc = "Fetch a web page or plain-text URL and return its readable text with markup stripped. Use it to read documentation, changelogs, issues or search results in full.",
            .schema =
            \\{"type":"object","properties":{"url":{"type":"string","description":"http:// or https:// URL to fetch."}},"required":["url"]}
            ,
            .handler = toolCtxStub,
            .ctx_handler = toolFetchUrl,
        },
    } },
    .{ .name = "elicitation", .enabled_by_default = false, .tools = &.{
        .{
            .name = "ask_user",
            .desc = "Ask the user a clarifying question when information is insufficient to proceed.",
            .schema =
            \\{"type":"object","properties":{"question":{"type":"string","description":"Question to ask the user."}},"required":["question"]}
            ,
            .handler = toolCtxStub,
            .ctx_handler = toolAskUser,
        },
    } },
    .{ .name = "task-delegation", .enabled_by_default = false, .tools = &.{
        .{
            .name = "task",
            .desc = "Delegate a self-contained task to a sub-agent and wait for its answer. Sub-agents inherit this session's directory and model but start with no conversation history, so each description must be complete on its own. Pass 'tasks' to run up to 4 in parallel; prefer that over sequential calls for independent work.",
            .schema =
            \\{"type":"object","properties":{"description":{"type":"string","description":"A single self-contained task, including all context the sub-agent needs."},"read_only":{"type":"boolean","description":"Run the sub-agent without write tools. Use it for investigation and review so a sub-agent cannot change files while you are still deciding."},"tasks":{"type":"array","description":"Independent tasks to run in parallel (max 4).","items":{"type":"object","properties":{"description":{"type":"string","description":"A single self-contained task."},"read_only":{"type":"boolean","description":"Run this sub-agent without write tools."}},"required":["description"]}}}}
            ,
            .handler = toolCtxStub,
            .ctx_handler = toolTask,
        },
    } },
    .{ .name = "todo", .enabled_by_default = false, .tools = &.{
        .{
            .name = "todo_write",
            .desc = "Replace the task list for this session. Use it to plan multi-step work and mark progress as you go; call it again with the full updated list after each step.",
            .schema =
            \\{"type":"object","properties":{"items":{"type":"array","description":"Full task list, replacing the previous one.","items":{"type":"object","properties":{"content":{"type":"string","description":"Task description, 5-10 words."},"status":{"type":"string","enum":["pending","in_progress","completed"],"description":"Task state."}},"required":["content","status"]}}},"required":["items"]}
            ,
            .handler = toolCtxStub,
            .ctx_handler = toolTodoWrite,
        },
        .{
            .name = "todo_read",
            .desc = "Read the current task list for this session.",
            .schema = toolsmod.EMPTY_SCHEMA,
            .handler = toolCtxStub,
            .ctx_handler = toolTodoRead,
        },
    } },
    .{ .name = "lsp", .enabled_by_default = false, .tools = &.{
        .{
            .name = "lsp",
            .desc = "Query a language server for code intelligence: definition, references, hover, rename impact, diagnostics. Prefer this over grep for symbol work — it follows shadowing, re-exports and cross-file usages that text search misses. Give 'symbol' to locate by name, or 'line'/'character' for an exact position.",
            .schema =
            \\{"type":"object","properties":{"action":{"type":"string","enum":["definition","references","hover","rename","diagnostics","implementation","type_definition"],"description":"Query to run."},"file":{"type":"string","description":"File path; its extension selects the language server."},"symbol":{"type":"string","description":"Symbol name to locate; first occurrence in the file is used."},"line":{"type":"integer","description":"1-based line number, alternative to symbol."},"character":{"type":"integer","description":"1-based column, used with line."},"new_name":{"type":"string","description":"Required for action=rename."}},"required":["action","file"]}
            ,
            .handler = toolCtxStub,
            .ctx_handler = toolLsp,
        },
    } },
};

/// 运行时插件启用集。默认按 `enabled_by_default`;
/// `enable` 追加开启项(来自 settings.json 的 `plugins` 或 `--plugin`)。
/// 进程级单例:插件表本身是编译期常量,启用与否是启动期决策。
var extra_enabled: [builtin_plugins.len]bool = @splat(false);

/// 按名开启一个可选插件。未知名字返回 false(调用方给提示)。
pub fn enable(name: []const u8) bool {
    for (&builtin_plugins, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) {
            extra_enabled[i] = true;
            return true;
        }
    }
    return false;
}

/// 该插件当前是否启用。
fn isEnabled(idx: usize) bool {
    return builtin_plugins[idx].enabled_by_default or extra_enabled[idx];
}

/// 某个插件工具当前是否可用。
///
/// 系统提示用它决定该不该教模型用某个工具 —— 讲一个不存在的工具比不讲更糟:
/// 模型会去调,拿到 unknown tool,然后浪费一轮重新想办法。
pub fn isToolEnabled(tool_name: []const u8) bool {
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabled(i)) continue;
        for (p.tools) |*t| {
            if (std.mem.eql(u8, t.name, tool_name)) return true;
        }
    }
    return false;
}

/// 全部插件名与启用状态(供 --plugins 列表与错误提示)。
pub fn listPlugins(arena: std.mem.Allocator) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    for (&builtin_plugins, 0..) |p, i| {
        const mark = if (isEnabled(i)) "on " else "off";
        try aw.writer.print("  [{s}] {s}", .{ mark, p.name });
        if (p.tools.len > 0) {
            try aw.writer.writeAll("  tools:");
            for (p.tools) |*t| try aw.writer.print(" {s}", .{t.name});
        }
        try aw.writer.writeByte('\n');
    }
    return aw.toOwnedSlice();
}

/// 仅供测试:重置运行时启用集,避免测试间互相污染(启用集是进程级单例)。
pub fn resetEnabledForTest() void {
    extra_enabled = @splat(false);
}

/// 运行全部启用插件的 before_turn 钩子(agent 每轮请求前调用)。
pub fn runBeforeTurn(ctx: ?*anyopaque) void {
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabled(i)) continue;
        if (p.before_turn) |h| h(ctx);
    }
}

/// 工具执行前拦截:返回拦截消息或 null。
pub fn runToolBefore(ctx: ?*anyopaque, name: []const u8, args: []const u8) ?[]const u8 {
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabled(i)) continue;
        if (p.on_tool_before) |h| {
            if (h(ctx, name, args)) |msg| return msg;
        }
    }
    return null;
}

/// 工具结果后处理:返回替换内容或 null。
pub fn runToolAfter(ctx: ?*anyopaque, name: []const u8, content: []const u8) ?[]const u8 {
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabled(i)) continue;
        if (p.on_tool_result) |h| {
            if (h(ctx, name, content)) |nc| return nc;
        }
    }
    return null;
}

/// 压缩失败:返回备用模型名或 null。
pub fn compactFallbackModel(ctx: ?*anyopaque) ?[]const u8 {
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabled(i)) continue;
        if (p.on_compact_failed) |h| {
            if (h(ctx)) |m| return m;
        }
    }
    return null;
}

/// 压缩成功后调用(跨会话记忆等)。
pub fn runAfterCompact(ctx: ?*anyopaque, summary: []const u8) void {
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabled(i)) continue;
        if (p.on_compact) |h| h(ctx, summary);
    }
}

/// 查工具:核心表 + 已启用插件的工具。
/// 禁用插件的工具查不到 —— 与 appendToolDefs 一致,否则模型能调到没声明的工具。
pub fn findTool(name: []const u8) ?*const toolsmod.Tool {
    if (toolsmod.find(name)) |t| return t;
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabled(i)) continue;
        for (p.tools) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
    }
    return null;
}

/// 汇总工具定义(核心表 + 已启用插件)到 out,供 ai.run 的 tools 参数。
/// 单一真相源:新增插件工具自动带上其 JSON Schema,无需改此函数。
pub fn appendToolDefs(out: *std.array_list.Managed(aimod.ToolDef)) !void {
    for (&toolsmod.tools) |*t| {
        try out.append(.{ .name = t.name, .desc = t.desc, .schema = t.schema });
    }
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabled(i)) continue;
        for (p.tools) |*t| {
            try out.append(.{ .name = t.name, .desc = t.desc, .schema = t.schema });
        }
    }
}

/// 工具定义的 token 估算(与 `appendToolDefs` 同一套口径,不分配)。
///
/// 上下文预算必须算这一段:工具定义**每轮都全量重发**,实测默认工具集就是
/// 1024 token。漏掉它会让压缩晚触发、也让 `get_context_remaining` 虚报余量。
/// 单独一个函数而非复用 `appendToolDefs`:预算估算在热路径上被反复调用,
/// 不该为了数几个字符去分配一个 list。
pub fn toolDefsTokens() usize {
    var n: usize = 0;
    for (&toolsmod.tools) |*t| n += defTokens(t.name, t.desc, t.schema);
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabled(i)) continue;
        for (p.tools) |*t| n += defTokens(t.name, t.desc, t.schema);
    }
    return n;
}

fn defTokens(name: []const u8, desc: []const u8, schema: []const u8) usize {
    const est = agentmod.Agent.estTokensOf;
    // +8:每个工具定义的 JSON 包装开销(type/function/name/description/parameters 键)
    return est(name) + est(desc) + est(schema) + 8;
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

test "all plugin tools ship a parseable schema" {
    const t = std.testing;
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 契约:插件工具的 schema 必须是合法 JSON object 且 type=object,
    // 否则 provider 会以 400 拒绝整个请求(空 schema 已由 EMPTY_SCHEMA 覆盖)。
    for (&builtin_plugins) |p| {
        for (p.tools) |*tool| {
            try t.expect(tool.schema.len > 0); // 插件工具不允许留空
            const v = try std.json.parseFromSliceLeaky(std.json.Value, a, tool.schema, .{});
            try t.expect(v == .object);
            const ty = v.object.get("type") orelse return error.SchemaMissingType;
            try t.expectEqualStrings("object", ty.string);
        }
    }
}

test "optional plugins are gated out of the default tool set" {
    const t = std.testing;
    resetEnabledForTest();
    defer resetEnabledForTest();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 默认工具集 = 核心表,不含任何插件工具。
    // 极简内核的可验证形式:每轮请求的 tools 数组只有真正必需的那几个。
    var defs = std.array_list.Managed(aimod.ToolDef).init(a);
    try appendToolDefs(&defs);
    try t.expectEqual(toolsmod.tools.len, defs.items.len);
    for (defs.items) |d| {
        try t.expect(toolsmod.find(d.name) != null);
    }
    // 关键:禁用插件的工具查不到 —— 否则模型能调到没在 tools 里声明的工具
    try t.expect(findTool("lsp") == null);
    try t.expect(findTool("todo_write") == null);
    try t.expect(findTool("git_status") == null);
    // 核心工具始终在
    try t.expect(findTool("read") != null);
    try t.expect(findTool("grep") != null);

    // 开一个插件:它的工具立刻可见
    try t.expect(enable("lsp"));
    try t.expect(findTool("lsp") != null);
    var defs2 = std.array_list.Managed(aimod.ToolDef).init(a);
    try appendToolDefs(&defs2);
    try t.expectEqual(toolsmod.tools.len + 1, defs2.items.len);
    // 其他插件仍然关着
    try t.expect(findTool("todo_write") == null);

    // 多工具插件一次性全开
    try t.expect(enable("todo"));
    try t.expect(findTool("todo_write") != null);
    try t.expect(findTool("todo_read") != null);

    // 未知插件名返回 false,不 panic
    try t.expect(!enable("nonexistent-plugin"));
}

test "default-on plugins register no tools" {
    const t = std.testing;
    // 默认启用的插件只挂钩子,不加工具 —— 这是它们能默认开的前提:零 token 成本。
    for (&builtin_plugins) |p| {
        if (!p.enabled_by_default) continue;
        try t.expectEqual(@as(usize, 0), p.tools.len);
    }
    // 反过来:带工具的插件必须默认关
    for (&builtin_plugins) |p| {
        if (p.tools.len == 0) continue;
        try t.expect(!p.enabled_by_default);
    }
}

test "listPlugins reflects enable state" {
    const t = std.testing;
    resetEnabledForTest();
    defer resetEnabledForTest();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try listPlugins(a);
    try t.expect(std.mem.indexOf(u8, before, "[off] lsp") != null);
    try t.expect(std.mem.indexOf(u8, before, "[on ] tool-output-pruner") != null);

    _ = enable("lsp");
    const after = try listPlugins(a);
    try t.expect(std.mem.indexOf(u8, after, "[on ] lsp") != null);
    // 工具名也列出来,便于用户知道开了什么
    try t.expect(std.mem.indexOf(u8, after, "tools: lsp") != null);
}

test "lsp frame encode and decode roundtrip" {
    const t = std.testing;
    const a = std.testing.allocator;
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}";
    const frame = try lspEncodeFrame(a, body);
    defer a.free(frame);
    try t.expect(std.mem.startsWith(u8, frame, "Content-Length: 38\r\n\r\n"));

    const decoded = lspDecodeFrame(frame) orelse return error.DecodeFailed;
    try t.expectEqualStrings(body, decoded.body);
    try t.expectEqual(frame.len, decoded.consumed);
}

test "lsp frame decoder handles partial and stacked frames" {
    const t = std.testing;
    // 头部未读完 → null(等更多数据),不能误判为坏帧
    try t.expect(lspDecodeFrame("Content-Length: 10") == null);
    // body 未读全 → null
    try t.expect(lspDecodeFrame("Content-Length: 10\r\n\r\nshort") == null);
    // 无 Content-Length → null,不 panic
    try t.expect(lspDecodeFrame("X-Foo: bar\r\n\r\n{}") == null);

    // 连续两帧:解出第一帧后按 consumed 推进能拿到第二帧
    const two = "Content-Length: 2\r\n\r\n{}Content-Length: 4\r\n\r\n[1,]";
    const f1 = lspDecodeFrame(two) orelse return error.DecodeFailed;
    try t.expectEqualStrings("{}", f1.body);
    const f2 = lspDecodeFrame(two[f1.consumed..]) orelse return error.DecodeFailed;
    try t.expectEqualStrings("[1,]", f2.body);

    // 容忍 LF-only 分隔(部分服务器不严格用 CRLF)
    const lf = "Content-Length: 2\n\n{}";
    const f3 = lspDecodeFrame(lf) orelse return error.DecodeFailed;
    try t.expectEqualStrings("{}", f3.body);
}

test "lsp server mapping by extension" {
    const t = std.testing;
    try t.expectEqualStrings("zls", lspServerFor("src/main.zig").?[0]);
    try t.expectEqualStrings("rust-analyzer", lspServerFor("src/lib.rs").?[0]);
    try t.expectEqualStrings("gopls", lspServerFor("main.go").?[0]);
    try t.expectEqualStrings("clangd", lspServerFor("a.cpp").?[0]);
    // 带 --stdio 参数的服务器
    const ts = lspServerFor("app.tsx").?;
    try t.expectEqualStrings("typescript-language-server", ts[0]);
    try t.expectEqualStrings("--stdio", ts[1]);
    const py = lspServerFor("main.py").?;
    try t.expectEqualStrings("pyright-langserver", py[0]);
    try t.expectEqualStrings("--stdio", py[1]);
    // 未知扩展名 → null(调用方给可操作提示)
    try t.expect(lspServerFor("notes.txt") == null);
    try t.expect(lspServerFor("Makefile") == null);

    // languageId 映射
    try t.expectEqualStrings("zig", lspLanguageId("a.zig"));
    try t.expectEqualStrings("typescriptreact", lspLanguageId("a.tsx"));
    try t.expectEqualStrings("plaintext", lspLanguageId("a.txt"));
}

test "lsp uri conversion roundtrip" {
    const t = std.testing;
    const a = std.testing.allocator;
    const uri = try lspPathToUri(a, "/home/u/my project/a.zig");
    defer a.free(uri);
    // 空格必须编码,否则服务器解析失败
    try t.expectEqualStrings("file:///home/u/my%20project/a.zig", uri);

    const back = try lspUriToPath(a, uri);
    defer a.free(back);
    try t.expectEqualStrings("/home/u/my project/a.zig", back);

    // 非 file:// 原样返回
    const other = try lspUriToPath(a, "untitled:foo");
    defer a.free(other);
    try t.expectEqualStrings("untitled:foo", other);
}

test "lsp symbol location is zero-based" {
    const t = std.testing;
    const content = "const a = 1;\nfn target() void {}\n";
    const pos = lspFindSymbol(content, "target") orelse return error.NotFound;
    // 第 2 行(0-based=1),列 3(0-based),"fn " 之后
    try t.expectEqual(@as(u32, 1), pos.line);
    try t.expectEqual(@as(u32, 3), pos.character);
    // 找不到 → null
    try t.expect(lspFindSymbol(content, "nonexistent") == null);
    try t.expect(lspFindSymbol(content, "") == null);
}

test "lsp tool fails gracefully without a server" {
    const t = std.testing;
    try agentmod.util.testInit();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = agentmod.cfgmod.Config{ .arena = &arena };
    var provs = [_]agentmod.cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");

    // 缺 action / file → 明确错误
    const e1 = try toolLsp(@ptrCast(&agent), a, "{}");
    try t.expect(e1.is_error);
    try t.expect(std.mem.indexOf(u8, e1.content, "action") != null);
    const e2 = try toolLsp(@ptrCast(&agent), a, "{\"action\":\"definition\"}");
    try t.expect(e2.is_error);
    try t.expect(std.mem.indexOf(u8, e2.content, "file") != null);

    // 不支持的扩展名 → 列出支持范围,不 crash
    const e3 = try toolLsp(@ptrCast(&agent), a, "{\"action\":\"definition\",\"file\":\"notes.txt\",\"symbol\":\"x\"}");
    try t.expect(e3.is_error);
    try t.expect(std.mem.indexOf(u8, e3.content, "no language server mapped") != null);

    // 文件不存在 → 读文件错误(在 spawn 之前失败,不留孤儿进程)
    const e4 = try toolLsp(@ptrCast(&agent), a, "{\"action\":\"definition\",\"file\":\"/nonexistent/x.zig\",\"symbol\":\"y\"}");
    try t.expect(e4.is_error);
    try t.expect(std.mem.indexOf(u8, e4.content, "error reading") != null);

    // 未知 action → 列出合法值
    const tmp_dir = std.testing.tmpDir(.{});
    var td = tmp_dir;
    defer td.cleanup();
    try td.dir.writeFile(agentmod.util.io, .{ .sub_path = "x.zig", .data = "const x = 1;\n" });
    const tmppath = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/x.zig", .{td.sub_path[0..]});
    const e5 = try toolLsp(@ptrCast(&agent), a, try std.fmt.allocPrint(a, "{{\"action\":\"bogus\",\"file\":\"{s}\",\"symbol\":\"x\"}}", .{tmppath}));
    try t.expect(e5.is_error);
    // 未知 action 在定位之后才判定,所以要么报 action 非法,要么报服务器不可用(zls 未装)
    try t.expect(std.mem.indexOf(u8, e5.content, "unknown action") != null or
        std.mem.indexOf(u8, e5.content, "cannot start language server") != null);
}

test "html to text strips markup, scripts and entities" {
    const t = std.testing;
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // script/style 的**内容**必须整块丢掉,否则模型收到一堆 JS 当正文读
    const got = try htmlToText(a, "<html><head><style>.x{color:red}</style>" ++
        "<script>var s = \"<p>fake</p>\";</script></head>" ++
        "<body><h1>Title &amp; more</h1><p>Body&nbsp;text.</p>" ++
        "<ul><li>one</li><li>two</li></ul></body></html>");
    try t.expect(std.mem.indexOf(u8, got, "color:red") == null);
    try t.expect(std.mem.indexOf(u8, got, "var s") == null);
    try t.expect(std.mem.indexOf(u8, got, "fake") == null);
    try t.expect(std.mem.indexOf(u8, got, "Title & more") != null);
    try t.expect(std.mem.indexOf(u8, got, "Body text.") != null);
    // 块级标签换行,免得整页挤成一行
    try t.expect(std.mem.indexOf(u8, got, "one\ntwo") != null);

    // `<p>` 的匹配不能误伤 `<pre>` —— 标签名后必须是分隔符
    const pre = try htmlToText(a, "<pre>keep this</pre>");
    try t.expectEqualStrings("keep this", pre);

    // 残缺 HTML(未闭合的 script)不能死循环,也不能把后面全吞掉
    const broken = try htmlToText(a, "<p>before</p><script>oops");
    try t.expect(std.mem.indexOf(u8, broken, "before") != null);
    try t.expect(std.mem.indexOf(u8, broken, "oops") == null);

    // 空输入与纯标签
    try t.expectEqualStrings("", try htmlToText(a, ""));
    try t.expectEqualStrings("", try htmlToText(a, "<div></div>"));
}

test "url encoding survives spaces and non-ascii queries" {
    const t = std.testing;
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 带空格是搜索查询的常态 —— 不编码整个请求就坏了
    try t.expectEqualStrings("zig%200.16%20std.Io", try urlEncode(a, "zig 0.16 std.Io"));
    // & 和 = 必须编码,否则会被当成额外的查询参数
    try t.expectEqualStrings("a%26b%3Dc", try urlEncode(a, "a&b=c"));
    // 非 ASCII 按字节百分号编码
    try t.expectEqualStrings("%E4%B8%AD", try urlEncode(a, "中"));
    // unreserved 字符原样保留
    try t.expectEqualStrings("a-b_c.d~e", try urlEncode(a, "a-b_c.d~e"));
}

test "search results are shaped into a compact list" {
    const t = std.testing;
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw =
        \\{"results":[
        \\{"title":"Zig 0.16 release notes","url":"https://ziglang.org/download/0.16.0/release-notes.html","content":"std.Io is now explicit."},
        \\{"title":"No URL here"},
        \\{"title":"Second","url":"https://example.com/2","content":""}
        \\]}
    ;
    const got = try shapeSearchResults(a, raw, "zig 0.16");
    try t.expect(std.mem.indexOf(u8, got, "Zig 0.16 release notes") != null);
    try t.expect(std.mem.indexOf(u8, got, "std.Io is now explicit.") != null);
    // 缺 url 的条目跳过 —— 给模型一个点不进去的结果没意义
    try t.expect(std.mem.indexOf(u8, got, "No URL here") == null);
    // 编号连续:跳过的那条不能留下空号
    try t.expect(std.mem.indexOf(u8, got, "2. Second") != null);
    // 指路 fetch_url,否则模型拿到链接不知道能读
    try t.expect(std.mem.indexOf(u8, got, "fetch_url") != null);

    // 非 SearXNG 端点(解析不出 results):原样透传而不是报错
    const passthru = try shapeSearchResults(a, "not json at all", "q");
    try t.expectEqualStrings("not json at all", passthru);

    // 零结果要说清楚,别回一个只有表头的空列表
    const empty = try shapeSearchResults(a, "{\"results\":[]}", "nothing");
    try t.expect(std.mem.indexOf(u8, empty, "No results") != null);
}
