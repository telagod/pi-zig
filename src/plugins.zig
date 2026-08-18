// plugins.zig — 内置插件:合同、出厂表、启用集、钩子分发。
// 实现按域分居 src/plugins/。子文件不得回引本文件。
const std = @import("std");
const agentmod = @import("agent.zig");
const toolsmod = @import("tools.zig");
const aimod = @import("ai.zig");

const api = @import("plugins/api.zig");
const hookmod = @import("plugins/hooks.zig");
const extras = @import("plugins/extras.zig");
const web = @import("plugins/web.zig");
const todo = @import("plugins/todo.zig");
const agentsplug = @import("plugins/agents.zig");
const taskmod = @import("plugins/task.zig");
const workflowmod = @import("plugins/workflow.zig");
const lspmod = @import("plugins/lsp.zig");
const childbind = @import("plugins/childbind.zig");

pub const BeforeChain = api.BeforeChain;
pub const AfterChain = api.AfterChain;
pub const Plugin = api.Plugin;
pub const SlashCommand = api.SlashCommand;

pub const injectMemory = hookmod.injectMemory;
pub const processBaseDepth = taskmod.processBaseDepth;
pub const shutdownAgents = agentsplug.shutdownAgents;
pub const agentOpenCountForTest = agentsplug.agentOpenCountForTest;

// Plugin 合同已迁至 plugins/api.zig。

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

// 跨会话记忆已迁至 plugins/hooks.zig

/// ctx 工具占位 handler(真正逻辑在 ctx_handler;此路径仅 schema 展示用)。
fn toolCtxStub(_: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = args;
    return .{ .content = "internal: use ctx handler", .is_error = true };
}

// =====================================================================
// 上下文预算查询插件:get_context_remaining 工具。
// =====================================================================
fn toolContextRemaining(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = args;
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    const w = self.ctxWindow();
    const used = self.estTokens();
    const remain = if (used < w) w - used else 0;
    // 报到压缩线的余量,不是报到窗口尽头 —— 模型该知道还能塞多少才会触发压缩,
    // 「离窗口还有多远」对它没有可操作性。
    const limit = w * agentmod.CTX_HARD_PERCENT / 100;
    const until_compact = if (used < limit) limit - used else 0;
    // 工具定义的份额单列:它是恒定开销,模型省不掉,不该让它以为那是可回收的空间。
    const tools_share = if (self.read_only) 0 else toolDefsTokensIn(self.plugins);
    return .{ .content = try std.fmt.allocPrint(
        arena,
        "Context budget: window {d} tokens, used ~{d} (of which ~{d} is the fixed tool definitions), remaining ~{d}. Auto-compaction triggers at {d}% ({d} tokens) — ~{d} tokens of headroom before that.",
        .{ w, used, tools_share, remain, agentmod.CTX_HARD_PERCENT, limit, until_compact },
    ) };
}

fn slashContext(ctx: ?*anyopaque, args: []const u8) anyerror![]const u8 {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx orelse return error.NoAgent));
    var arena = agentmod.util.Arena.init(self.alloc);
    defer arena.deinit();
    const r = try toolContextRemaining(ctx, arena.allocator(), args);
    return self.alloc.dupe(u8, r.content);
}

fn slashSkills(ctx: ?*anyopaque, args: []const u8) anyerror![]const u8 {
    _ = args;
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx orelse return error.NoAgent));
    const idx = agentmod.util.loadSkillsIndex(self.alloc) catch return self.alloc.dupe(u8, "no skills");
    if (idx.len == 0) {
        self.alloc.free(idx);
        return self.alloc.dupe(u8, "no skills");
    }
    return idx;
}

// 实现按域分居 src/plugins/。

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
    .{ .name = "cross-session-memory", .on_compact = hookmod.memoryAppend },
    .{ .name = "command-canonicalization", .on_tool_before = hookmod.canonicalBlock },
    .{ .name = "artifact-store", .on_tool_result = hookmod.artifactStoreHook },
    .{ .name = "compact-resilience", .on_compact_failed = hookmod.compactFallback },
    .{ .name = "concept-graph", .on_compact = hookmod.conceptExtract },
    .{ .name = "vision-input", .enabled_by_default = false, .tools = &.{
        .{
            .name = "read_image",
            .desc = "Read an image file and attach it to the conversation so a vision-capable model can see it. The image is automatically resized and recompressed to fit the provider's vision budget (no size math needed). Use this whenever the user asks about or references an image, screenshot, chart, or diagram.",
            .schema =
            \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the image file (PNG, JPEG, GIF, WebP, BMP)."}},"required":["path"]}
            ,
            .handler = toolCtxStub,
            .ctx_handler = extras.toolReadImage,
        },
    } },

    // ---- 默认关闭:按需开启的场景化工具 ----
    .{ .name = "skills", .enabled_by_default = false, .slash_commands = &.{
        .{ .name = "skills", .desc = "list available skills", .handler = slashSkills },
    }, .tools = &.{
        .{
            .name = "skill",
            .desc = "Load a skill's SKILL.md content by name. Skill names are listed in the system prompt.",
            .schema =
            \\{"type":"object","properties":{"name":{"type":"string","description":"Skill name as listed in the skills index."}},"required":["name"]}
            ,
            .handler = toolsmod.toolSkill,
        },
    } },
    .{ .name = "context-budget", .enabled_by_default = false, .slash_commands = &.{
        .{ .name = "context", .desc = "context budget remaining", .handler = slashContext },
    }, .tools = &.{
        .{
            .name = "get_context_remaining",
            .desc = "Report remaining context budget in tokens.",
            .schema = toolsmod.EMPTY_SCHEMA,
            .handler = toolCtxStub,
            .ctx_handler = toolContextRemaining,
        },
    } },
    .{ .name = "git-awareness", .enabled_by_default = false, .slash_commands = &.{
        .{ .name = "git", .desc = "git status + diffstat", .handler = extras.slashGit },
    }, .tools = &.{
        .{
            .name = "git_status",
            .desc = "Show git status and diff stat for the working tree.",
            .schema = toolsmod.EMPTY_SCHEMA,
            .handler = toolCtxStub,
            .ctx_handler = extras.toolGitStatus,
        },
    } },
    .{ .name = "web-search", .enabled_by_default = false, .slash_commands = &.{
        .{ .name = "web", .desc = "web search status or /web <query>", .handler = web.slashWeb },
    }, .tools = &.{
        .{
            .name = "web_search",
            .desc = "Search the web when local information is insufficient or possibly out of date. Returns a ranked list of titles, URLs and snippets; follow up with fetch_url to read a result in full. Requires PIZ_WEB_SEARCH_URL.",
            .schema =
            \\{"type":"object","properties":{"query":{"type":"string","description":"Search query."}},"required":["query"]}
            ,
            .handler = toolCtxStub,
            .ctx_handler = web.toolWebSearch,
        },
        .{
            .name = "fetch_url",
            .desc = "Fetch a web page or plain-text URL and return its readable text with markup stripped. Use it to read documentation, changelogs, issues or search results in full.",
            .schema =
            \\{"type":"object","properties":{"url":{"type":"string","description":"http:// or https:// URL to fetch."}},"required":["url"]}
            ,
            .handler = toolCtxStub,
            .ctx_handler = web.toolFetchUrl,
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
            .ctx_handler = extras.toolAskUser,
        },
    } },
    .{ .name = "task-delegation", .enabled_by_default = false, .slash_commands = &.{
        .{ .name = "agents", .desc = "list live sub-agents", .handler = agentsplug.slashAgents },
    }, .tools = &.{
        .{
            .name = "task",
            .desc = "Delegate self-contained work to sub-agents and wait for all of them to finish. Sub-agents inherit this session's directory and model but start with no conversation history, so each description must be complete on its own. They do not inherit task/spawn_agent unless you pass plugins:[\"task-delegation\"]. Pass tools:[\"read\",\"grep\"] to give a child only those tools. Pass 'tasks' to queue up to 32 (8 run at once). Use this when you just want the answers; use spawn_agent instead when you want to keep working while they run, or may need to redirect them.",
            .schema =
            \\{"type":"object","properties":{"description":{"type":"string","description":"A single self-contained task, including all context the sub-agent needs."},"read_only":{"type":"boolean","description":"Give the sub-agent NO tools at all — it can only reason from the task text you provide. It cannot read files, run commands or search. Leave this off for investigation: a sub-agent that cannot read cannot investigate."},"plugins":{"type":"array","items":{"type":"string"},"description":"Plugin names the child may keep, intersected with yours. Omit to inherit yours minus task-delegation."},"tools":{"type":"array","items":{"type":"string"},"description":"Exact tool names the child may use (read, grep, …). Omit for all tools in its plugin set. Cannot grant a tool you do not have."},"tasks":{"type":"array","description":"Independent tasks to run in parallel (max 32 queued at top level, 4 inside a sub-agent; 8 run at once).","items":{"type":"object","properties":{"description":{"type":"string","description":"A single self-contained task."},"read_only":{"type":"boolean","description":"Give this sub-agent no tools at all; it can only reason from its task text."},"plugins":{"type":"array","items":{"type":"string"},"description":"Plugin names this child may keep."},"tools":{"type":"array","items":{"type":"string"},"description":"Exact tool names this child may use."}},"required":["description"]}}}}
            ,
            .handler = toolCtxStub,
            .ctx_handler = taskmod.toolTask,
        },
        .{
            .name = "workflow",
            .desc = "Run a DAG of named sub-agents. Independent nodes run together; a node starts when every id in needs has finished. Later tasks splice earlier output with {id}. Roles scout/planner/reviewer get a read-oriented tool set if you omit tools; worker inherits yours. A failed node skips its dependents instead of burning more tokens. Use this when steps depend on each other; use task when they do not.",
            .schema =
            \\{"type":"object","properties":{"goal":{"type":"string","description":"One-line label for this workflow."},"fail_fast":{"type":"boolean","description":"If true, skip remaining waves after any node fails. Default false: independent branches keep running."},"nodes":{"type":"array","description":"Named DAG nodes. A node runs when every id in needs has finished. Later tasks may cite earlier output as {id}.","items":{"type":"object","properties":{"id":{"type":"string","description":"Node name. Letters, digits, _ or -. Cited later as {id}."},"task":{"type":"string","description":"Self-contained work. Use {other_id} to splice that node's output."},"role":{"type":"string","enum":["scout","planner","reviewer","worker"],"description":"scout/planner/reviewer get a read-oriented tool set if you omit tools. worker inherits yours."},"needs":{"type":"array","items":{"type":"string"},"description":"Node ids that must finish first."},"read_only":{"type":"boolean"},"plugins":{"type":"array","items":{"type":"string"}},"tools":{"type":"array","items":{"type":"string"}}},"required":["id","task"]}}},"required":["nodes"]}
            ,
            .handler = toolCtxStub,
            .ctx_handler = workflowmod.toolWorkflow,
        },
        .{
            .name = "spawn_agent",
            .desc = "Start a background sub-agent and return immediately with its id. Unlike task, this does not block: you keep working while it runs, can send it more instructions mid-flight, and collect its output when you are ready. Follow up with wait_agent, read_agent, send_agent and close_agent. Prefer this for long investigations, or when its findings may change what you ask it next. It does not inherit task/spawn_agent unless you pass plugins:[\"task-delegation\"]. Pass tools to narrow what it can call.",
            .schema =
            \\{"type":"object","properties":{"task":{"type":"string","description":"Self-contained description of what the sub-agent should do. It starts with no memory of this conversation unless fork_context is set."},"name":{"type":"string","description":"Short label for this sub-agent, shown in list_agents."},"read_only":{"type":"boolean","description":"Give it NO tools at all — it can only reason from the task text. It cannot read files or run commands, so leave this off whenever it needs to look at anything."},"fork_context":{"type":"boolean","description":"Copy this conversation's history into the sub-agent. Use it when the task only makes sense given what was already discussed; leave it off otherwise to save tokens."},"plugins":{"type":"array","items":{"type":"string"},"description":"Plugin names it may keep, intersected with yours. Omit to inherit yours minus task-delegation."},"tools":{"type":"array","items":{"type":"string"},"description":"Exact tool names it may use. Omit for all tools in its plugin set."}},"required":["task"]}
            ,
            .handler = toolCtxStub,
            .ctx_handler = agentsplug.toolSpawnAgent,
        },
        .{
            .name = "wait_agent",
            .desc = "Block until any background sub-agent has something new, or the timeout expires. Returns which agents have updates and their status, not the content — call read_agent to collect it. Returns early once every agent is idle, so it will not sit through the full timeout when there is nothing left to wait for.",
            .schema =
            \\{"type":"object","properties":{"timeout_seconds":{"type":"integer","description":"How long to wait before giving up. Default 60, capped at 600."}}}
            ,
            .handler = toolCtxStub,
            .ctx_handler = agentsplug.toolWaitAgent,
        },
        .{
            .name = "read_agent",
            .desc = "Collect a background sub-agent's unread updates: finished turns, failures, and which tools it ran. Each update is returned once — the read position advances.",
            .schema =
            \\{"type":"object","properties":{"id":{"type":"integer","description":"Sub-agent id from spawn_agent."}},"required":["id"]}
            ,
            .handler = toolCtxStub,
            .ctx_handler = agentsplug.toolReadAgent,
        },
        .{
            .name = "send_agent",
            .desc = "Give a background sub-agent more work. By default the message is queued behind what it is currently doing; set interrupt to abandon its current turn and handle your message right away. Use interrupt when its findings so far already tell you it is going the wrong way.",
            .schema =
            \\{"type":"object","properties":{"id":{"type":"integer","description":"Sub-agent id from spawn_agent."},"message":{"type":"string","description":"What it should do next. It keeps the context of its earlier turns."},"interrupt":{"type":"boolean","description":"True abandons its current turn and handles this immediately; false or omitted queues it."}},"required":["id","message"]}
            ,
            .handler = toolCtxStub,
            .ctx_handler = agentsplug.toolSendAgent,
        },
        .{
            .name = "list_agents",
            .desc = "List background sub-agents with their status, how many turns they have run, unread updates and queued input.",
            .schema = toolsmod.EMPTY_SCHEMA,
            .handler = toolCtxStub,
            .ctx_handler = agentsplug.toolListAgents,
        },
        .{
            .name = "close_agent",
            .desc = "Shut down a background sub-agent and free its slot. Finished agents keep holding a slot until closed, so close them once you have collected what you need.",
            .schema =
            \\{"type":"object","properties":{"id":{"type":"integer","description":"Sub-agent id from spawn_agent."}},"required":["id"]}
            ,
            .handler = toolCtxStub,
            .ctx_handler = agentsplug.toolCloseAgent,
        },
    } },
    .{ .name = "todo", .enabled_by_default = false, .slash_commands = &.{
        .{ .name = "todo", .desc = "list session todos", .handler = todo.slashTodo },
    }, .tools = &.{
        .{
            .name = "todo_write",
            .desc = "Update the task list for this session. Default mode replace swaps the whole list. mode merge updates items with the same id and appends new ones, so you do not have to resend finished work. Optional bind attaches an item to a workflow node id.",
            .schema =
            \\{"type":"object","properties":{"mode":{"type":"string","enum":["replace","merge"],"description":"replace (default) swaps the list. merge updates matching ids and appends the rest."},"items":{"type":"array","description":"Task items. On replace this is the full list. On merge, matching id updates fields; new id appends.","items":{"type":"object","properties":{"id":{"type":"string","description":"Stable item id. Assigned as t1, t2, … if omitted."},"content":{"type":"string","description":"Task description, 5-10 words."},"status":{"type":"string","enum":["pending","in_progress","completed"],"description":"Task state."},"bind":{"type":"string","description":"Optional workflow node id this item tracks."}},"required":["content"]}}},"required":["items"]}
            ,
            .handler = toolCtxStub,
            .ctx_handler = todo.toolTodoWrite,
        },
        .{
            .name = "todo_read",
            .desc = "Read the current task list for this session.",
            .schema = toolsmod.EMPTY_SCHEMA,
            .handler = toolCtxStub,
            .ctx_handler = todo.toolTodoRead,
        },
    } },
    .{ .name = "lsp", .enabled_by_default = false, .slash_commands = &.{
        .{ .name = "lsp", .desc = "language servers on PATH", .handler = lspmod.slashLsp },
    }, .tools = &.{
        .{
            .name = "lsp",
            .desc = "Query a language server for code intelligence: definition, references, hover, rename impact, diagnostics. Prefer this over grep for symbol work — it follows shadowing, re-exports and cross-file usages that text search misses. Give 'symbol' to locate by name, or 'line'/'character' for an exact position.",
            .schema =
            \\{"type":"object","properties":{"action":{"type":"string","enum":["definition","references","hover","rename","diagnostics","implementation","type_definition"],"description":"Query to run."},"file":{"type":"string","description":"File path; its extension selects the language server."},"symbol":{"type":"string","description":"Symbol name to locate; first occurrence in the file is used."},"line":{"type":"integer","description":"1-based line number, alternative to symbol."},"character":{"type":"integer","description":"1-based column, used with line."},"new_name":{"type":"string","description":"Required for action=rename."}},"required":["action","file"]}
            ,
            .handler = toolCtxStub,
            .ctx_handler = lspmod.toolLsp,
        },
    } },
    .{ .name = "usage-ledger", .after_turn = hookmod.usageLedgerHook },
};

/// 插件启用集的位掩码类型(15 个内置插件)。
pub const EnabledSet = u16;

comptime {
    if (builtin_plugins.len > @bitSizeOf(EnabledSet)) {
        @compileError("插件数超过 EnabledSet 的位宽,把它换成更宽的整型");
    }
}

/// 出厂启用集:`enabled_by_default` 的位。进程默认集以此为初值,
/// `disable` 可关掉默认开的插件(可逆:关 = 撤钩 + 撤工具 + 撤 schema)。
pub fn factorySet() EnabledSet {
    var set: EnabledSet = 0;
    for (&builtin_plugins, 0..) |p, i| {
        if (p.enabled_by_default) set |= maskOf(i);
    }
    return set;
}

/// **进程默认**启用集。`--plugin` / `--no-plugin` 与 settings.json 写它,
/// 新建 Agent 时作为初值拷进 `Agent.plugins`。
///
/// 为什么不再是唯一真相:进程内并行跑多个 Agent 时,一个 Agent 开了 skills
/// 就会让所有 Agent 都看到 skill 工具。subagent 尤其不能这样 —— 它可能是
/// 只读的调研 agent,却因为兄弟 agent 的设置拿到了写工具。
var default_enabled: EnabledSet = 0;
var default_inited: bool = false;

fn ensureDefault() void {
    if (default_inited) return;
    default_enabled = factorySet();
    default_inited = true;
    childbind.child_set = childSet;
    childbind.tool_allow = childToolAllow;
}

comptime {
    // task-delegation 是 childbind 未绑定回退的锚点,按名查,不写死下标。
    var found = false;
    for (builtin_plugins) |p| {
        if (std.mem.eql(u8, p.name, "task-delegation")) found = true;
    }
    if (!found) @compileError("task-delegation 插件丢失,childbind 的未绑定回退靠它");
}

/// 按名开启一个插件(改进程默认集)。未知名字返回 false(调用方给提示)。
pub fn enable(name: []const u8) bool {
    ensureDefault();
    for (&builtin_plugins, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) {
            default_enabled |= maskOf(i);
            return true;
        }
    }
    return false;
}

/// 按名关闭一个插件。关 = 撤钩、撤工具、撤 schema。未知名字返回 false。
pub fn disable(name: []const u8) bool {
    ensureDefault();
    for (&builtin_plugins, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) {
            default_enabled &= ~maskOf(i);
            return true;
        }
    }
    return false;
}

fn maskOf(idx: usize) EnabledSet {
    return @as(EnabledSet, 1) << @intCast(idx);
}

/// 进程默认启用集 —— 新 Agent 的初值。
pub fn defaultSet() EnabledSet {
    ensureDefault();
    return default_enabled;
}

/// settings.json 的 plugins / disabled_plugins 落到进程默认集。
pub fn applyFromConfig(enabled: []const []const u8, disabled: []const []const u8) void {
    for (enabled) |name| _ = enable(name);
    for (disabled) |name| _ = disable(name);
}

pub fn isFactoryOn(name: []const u8) bool {
    for (builtin_plugins) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.enabled_by_default;
    }
    return false;
}

pub fn isOn(name: []const u8) bool {
    for (&builtin_plugins, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) return isEnabledIn(defaultSet(), i);
    }
    return false;
}

/// 给 Web 设置页用的插件清单。
pub fn writeCatalog(w: *std.Io.Writer) !void {
    try w.writeAll("[");
    for (builtin_plugins, 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"name\":\"{s}\",\"enabled\":{s},\"optional\":{s}}}", .{
            p.name,
            if (isEnabledIn(defaultSet(), i)) "true" else "false",
            if (p.enabled_by_default) "false" else "true",
        });
    }
    try w.writeAll("]");
}

/// 在一个启用集上开启某个插件,返回新集合。未知名字原样返回。
pub fn withEnabled(set: EnabledSet, name: []const u8) EnabledSet {
    for (&builtin_plugins, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) return set | maskOf(i);
    }
    return set;
}

/// 从某份启用集关掉一个插件。未知名字原样返回。
pub fn withoutEnabled(set: EnabledSet, name: []const u8) EnabledSet {
    for (&builtin_plugins, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) return set & ~maskOf(i);
    }
    return set;
}

/// 子 agent 的启用集:继承父集,默认摘掉 `task-delegation`。
///
/// 孩子不该默认再付 8 个委派工具的 schema,也不该默认能再派。
/// `want` 为 null = 这个默认;非 null = 与父集求交(只能收紧)。
/// 无工具的钩子插件始终从父集保留 —— `plugins: ["lsp"]` 是加工具,不是关快压。
pub fn childSet(parent: EnabledSet, want: ?[]const []const u8) !EnabledSet {
    var hooks: EnabledSet = 0;
    for (&builtin_plugins, 0..) |p, i| {
        if (p.tools.len != 0) continue;
        if (isEnabledIn(parent, i)) hooks |= maskOf(i);
    }
    if (want) |names| {
        var set = hooks;
        for (names) |n| {
            const bit = bitOf(n) orelse return error.UnknownPlugin;
            if (parent & bit == 0) return error.PluginNotHeld;
            set |= bit;
        }
        return set;
    }
    return withoutEnabled(parent, "task-delegation");
}

fn bitOf(name: []const u8) ?EnabledSet {
    for (&builtin_plugins, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) return maskOf(i);
    }
    return null;
}

fn nameIn(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// 已知工具名(核心表或任一插件)。
pub fn knownToolName(name: []const u8) bool {
    if (toolsmod.find(name) != null) return true;
    for (&builtin_plugins) |p| {
        for (p.tools) |*t| {
            if (std.mem.eql(u8, t.name, name)) return true;
        }
    }
    return false;
}

/// 父 agent 当前能用的工具,孩子才能要。
pub fn parentHoldsTool(parent: EnabledSet, name: []const u8) bool {
    return findToolIn(parent, name) != null;
}

/// 启用集 + 可选工具白名单是否暴露该工具。
pub fn exposesTool(set: EnabledSet, allow: []const []const u8, name: []const u8) bool {
    if (allow.len > 0 and !nameIn(allow, name)) return false;
    return findToolIn(set, name) != null;
}

/// 校验 `tools` 白名单:每项已知,且父集能用。返回 arena 上的拷贝。
pub fn childToolAllow(arena: std.mem.Allocator, parent: EnabledSet, names: []const []const u8) ![]const []const u8 {
    for (names) |n| {
        if (!knownToolName(n)) return error.UnknownTool;
        if (!parentHoldsTool(parent, n)) return error.ToolNotHeld;
    }
    const out = try arena.alloc([]const u8, names.len);
    for (names, out) |n, *d| d.* = try arena.dupe(u8, n);
    return out;
}

/// 该插件在给定启用集下是否可用。
/// 从 hook 的 ctx(总是 Agent 指针)取它的启用集。ctx 为 null 时退回进程默认集
/// —— 只有测试会那样调。
fn setOfCtx(ctx: ?*anyopaque) EnabledSet {
    const c = ctx orelse return defaultSet();
    const agent: *agentmod.Agent = @ptrCast(@alignCast(c));
    return agent.plugins;
}

fn isEnabledIn(set: EnabledSet, idx: usize) bool {
    return (set & maskOf(idx)) != 0;
}

/// 某个插件工具当前是否可用。
///
/// 系统提示用它决定该不该教模型用某个工具 —— 讲一个不存在的工具比不讲更糟:
/// 模型会去调,拿到 unknown tool,然后浪费一轮重新想办法。
pub fn isToolEnabledIn(set: EnabledSet, tool_name: []const u8) bool {
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabledIn(set, i)) continue;
        for (p.tools) |*t| {
            if (std.mem.eql(u8, t.name, tool_name)) return true;
        }
    }
    return false;
}

pub fn known(name: []const u8) bool {
    return bitOf(name) != null;
}

/// 全部插件名与启用状态(供 --plugins 列表、/plugins、错误提示)。
pub fn listPluginsIn(arena: std.mem.Allocator, set: EnabledSet) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    for (&builtin_plugins, 0..) |p, i| {
        const mark = if (isEnabledIn(set, i)) "on " else "off";
        try aw.writer.print("  [{s}] {s}", .{ mark, p.name });
        if (p.tools.len > 0) {
            try aw.writer.writeAll("  tools:");
            for (p.tools) |*t| try aw.writer.print(" {s}", .{t.name});
        }
        try aw.writer.writeByte('\n');
    }
    return aw.toOwnedSlice();
}

/// 进程默认启用集的清单。
pub fn listPlugins(arena: std.mem.Allocator) ![]const u8 {
    return listPluginsIn(arena, defaultSet());
}

/// 已启用插件注册的斜杠命令(按 builtin 声明序)。
pub fn collectSlash(set: EnabledSet, out: []SlashCommand) usize {
    var n: usize = 0;
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabledIn(set, i)) continue;
        for (p.slash_commands) |sc| {
            if (n >= out.len) return n;
            out[n] = sc;
            n += 1;
        }
    }
    return n;
}

fn slashStem(name: []const u8) []const u8 {
    if (name.len > 0 and name[0] == '/') return name[1..];
    return name;
}

/// 按名分发插件斜杠。未命中返回 null;命中则返回 handler 结果。
pub fn dispatchSlash(set: EnabledSet, ctx: ?*anyopaque, name: []const u8, args: []const u8) ?anyerror![]const u8 {
    const want = slashStem(name);
    var buf: [32]SlashCommand = undefined;
    const n = collectSlash(set, &buf);
    for (buf[0..n]) |sc| {
        if (std.mem.eql(u8, slashStem(sc.name), want)) return sc.handler(ctx, args);
    }
    return null;
}

/// 已开的非默认插件名,空格分隔。供 /status 一行展示。
pub fn enabledOptionalLine(arena: std.mem.Allocator, set: EnabledSet) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    var first = true;
    for (&builtin_plugins, 0..) |p, i| {
        if (p.enabled_by_default) continue;
        if (!isEnabledIn(set, i)) continue;
        if (!first) try aw.writer.writeByte(' ');
        first = false;
        try aw.writer.writeAll(p.name);
    }
    return aw.toOwnedSlice();
}

/// 仅供测试:重置运行时启用集,避免测试间互相污染(启用集是进程级单例)。
pub fn resetEnabledForTest() void {
    default_enabled = factorySet();
    default_inited = true;
}

/// 运行全部启用插件的 before_turn 钩子(agent 每轮请求前调用)。
pub fn runBeforeTurn(ctx: ?*anyopaque) void {
    const set = setOfCtx(ctx);
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabledIn(set, i)) continue;
        if (p.before_turn) |h| h(ctx);
    }
}

/// 用户消息提交:启用插件按声明序看,第一个非 null 替换进模型的文本。
pub fn runUserMessage(ctx: ?*anyopaque, text: []const u8) ?[]const u8 {
    const set = setOfCtx(ctx);
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabledIn(set, i)) continue;
        if (p.on_user_message) |h| {
            if (h(ctx, text)) |rewritten| return rewritten;
        }
    }
    return null;
}

/// 一轮结束:启用插件按声明序跑 after_turn。
pub fn runAfterTurn(ctx: ?*anyopaque) void {
    const set = setOfCtx(ctx);
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabledIn(set, i)) continue;
        if (p.after_turn) |h| h(ctx);
    }
}

/// 工具执行前 waterfall:须 next() 才放行。返回拦截消息或 null。
pub fn runToolBefore(ctx: ?*anyopaque, name: []const u8, args: []const u8) ?[]const u8 {
    const set = setOfCtx(ctx);
    var buf: [builtin_plugins.len]?*const fn (*BeforeChain) ?[]const u8 = undefined;
    var n: usize = 0;
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabledIn(set, i)) continue;
        if (p.on_tool_before) |h| {
            buf[n] = h;
            n += 1;
        }
    }
    var chain = BeforeChain{ .ctx = ctx, .name = name, .args = args, .hooks = buf[0..n] };
    return chain.next();
}

/// 工具结果 waterfall:须 next() 才放行。返回替换内容或 null。
pub fn runToolAfter(ctx: ?*anyopaque, name: []const u8, content: []const u8) ?[]const u8 {
    const set = setOfCtx(ctx);
    var buf: [builtin_plugins.len]?*const fn (*AfterChain) ?[]const u8 = undefined;
    var n: usize = 0;
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabledIn(set, i)) continue;
        if (p.on_tool_result) |h| {
            buf[n] = h;
            n += 1;
        }
    }
    var chain = AfterChain{ .ctx = ctx, .name = name, .content = content, .hooks = buf[0..n] };
    return chain.next();
}

test "tool before chain skips later hook when earlier omits next" {
    const t = std.testing;
    const S = struct {
        var later: usize = 0;
        fn deny(chain: *BeforeChain) ?[]const u8 {
            _ = chain;
            return "blocked";
        }
        fn laterHook(chain: *BeforeChain) ?[]const u8 {
            later += 1;
            return chain.next();
        }
    };
    S.later = 0;
    const hooks = [_]*const fn (*BeforeChain) ?[]const u8{ S.deny, S.laterHook };
    var opt: [2]?*const fn (*BeforeChain) ?[]const u8 = .{ hooks[0], hooks[1] };
    var chain = BeforeChain{ .ctx = null, .name = "bash", .args = "x", .hooks = &opt };
    const msg = chain.next();
    try t.expectEqualStrings("blocked", msg.?);
    try t.expectEqual(@as(usize, 0), S.later);
}

test "tool before chain later hook runs only if earlier calls next" {
    const t = std.testing;
    const S = struct {
        var later: usize = 0;
        fn pass(chain: *BeforeChain) ?[]const u8 {
            return chain.next();
        }
        fn laterDeny(chain: *BeforeChain) ?[]const u8 {
            _ = chain;
            later += 1;
            return "later-block";
        }
    };
    S.later = 0;
    var opt: [2]?*const fn (*BeforeChain) ?[]const u8 = .{ S.pass, S.laterDeny };
    var chain = BeforeChain{ .ctx = null, .name = "bash", .args = "x", .hooks = &opt };
    const msg = chain.next();
    try t.expectEqualStrings("later-block", msg.?);
    try t.expectEqual(@as(usize, 1), S.later);
}

test "tool after chain can wrap inner rewrite" {
    const t = std.testing;
    const S = struct {
        fn inner(chain: *AfterChain) ?[]const u8 {
            _ = chain.next();
            return "inner";
        }
        fn outer(chain: *AfterChain) ?[]const u8 {
            const r = chain.next() orelse chain.content;
            if (std.mem.eql(u8, r, "inner")) return "wrapped:inner";
            return r;
        }
    };
    var opt: [2]?*const fn (*AfterChain) ?[]const u8 = .{ S.outer, S.inner };
    var chain = AfterChain{ .ctx = null, .name = "bash", .content = "raw", .hooks = &opt };
    try t.expectEqualStrings("wrapped:inner", chain.next().?);
}

/// 压缩失败:返回备用模型名或 null。
pub fn compactFallbackModel(ctx: ?*anyopaque) ?[]const u8 {
    const set = setOfCtx(ctx);
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabledIn(set, i)) continue;
        if (p.on_compact_failed) |h| {
            if (h(ctx)) |m| return m;
        }
    }
    return null;
}

/// 压缩成功后调用(跨会话记忆等)。
pub fn runAfterCompact(ctx: ?*anyopaque, summary: []const u8) void {
    const set = setOfCtx(ctx);
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabledIn(set, i)) continue;
        if (p.on_compact) |h| h(ctx, summary);
    }
}

/// 查工具:核心表 + 已启用插件的工具。
/// 禁用插件的工具查不到 —— 与 appendToolDefs 一致,否则模型能调到没声明的工具。
pub fn findToolIn(set: EnabledSet, name: []const u8) ?*const toolsmod.Tool {
    if (toolsmod.find(name)) |t| return t;
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabledIn(set, i)) continue;
        for (p.tools) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
    }
    return null;
}

/// 汇总工具定义(核心表 + 已启用插件)到 out,供 ai.run 的 tools 参数。
/// 单一真相源:新增插件工具自动带上其 JSON Schema,无需改此函数。
pub fn appendToolDefsIn(set: EnabledSet, out: *std.array_list.Managed(aimod.ToolDef)) !void {
    try appendToolDefsFiltered(set, &.{}, out);
}

/// 按启用集与可选白名单汇总工具定义。`allow` 空 = 不额外收紧。
pub fn appendToolDefsFiltered(set: EnabledSet, allow: []const []const u8, out: *std.array_list.Managed(aimod.ToolDef)) !void {
    for (&toolsmod.tools) |*t| {
        if (allow.len > 0 and !nameIn(allow, t.name)) continue;
        try out.append(.{ .name = t.name, .desc = t.desc, .schema = t.schema });
    }
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabledIn(set, i)) continue;
        for (p.tools) |*t| {
            if (allow.len > 0 and !nameIn(allow, t.name)) continue;
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
pub fn toolDefsTokensIn(set: EnabledSet) usize {
    return toolDefsTokensFiltered(set, &.{});
}

/// 与 `appendToolDefsFiltered` 同一口径的 token 估算,不分配。
pub fn toolDefsTokensFiltered(set: EnabledSet, allow: []const []const u8) usize {
    var n: usize = 0;
    for (&toolsmod.tools) |*t| {
        if (allow.len > 0 and !nameIn(allow, t.name)) continue;
        n += defTokens(t.name, t.desc, t.schema);
    }
    for (&builtin_plugins, 0..) |p, i| {
        if (!isEnabledIn(set, i)) continue;
        for (p.tools) |*t| {
            if (allow.len > 0 and !nameIn(allow, t.name)) continue;
            n += defTokens(t.name, t.desc, t.schema);
        }
    }
    return n;
}

fn defTokens(name: []const u8, desc: []const u8, schema: []const u8) usize {
    const est = agentmod.Agent.estTokensOf;
    // +8:每个工具定义的 JSON 包装开销(type/function/name/description/parameters 键)
    return est(name) + est(desc) + est(schema) + 8;
}

// todo 测已迁 plugins/todo.zig

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

test "optional plugins are gated per agent, not process-wide" {
    const t = std.testing;
    resetEnabledForTest();
    defer resetEnabledForTest();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 默认工具集 = 核心表,不含任何插件工具。
    // 极简内核的可验证形式:每轮请求的 tools 数组只有真正必需的那几个。
    const bare: EnabledSet = 0;
    var defs = std.array_list.Managed(aimod.ToolDef).init(a);
    try appendToolDefsIn(bare, &defs);
    try t.expectEqual(toolsmod.tools.len, defs.items.len);
    for (&toolsmod.tools, defs.items) |*core, d| {
        try t.expectEqualStrings(core.name, d.name);
        try t.expectEqualStrings(core.desc, d.desc);
        try t.expectEqualStrings(core.schema, d.schema);
    }
    // 出厂启用集也不许往默认前缀里塞插件工具 —— 那是 prompt cache 的稳定区
    var factory_defs = std.array_list.Managed(aimod.ToolDef).init(a);
    try appendToolDefsIn(factorySet(), &factory_defs);
    try t.expectEqual(toolsmod.tools.len, factory_defs.items.len);
    for (&toolsmod.tools, factory_defs.items) |*core, d| {
        try t.expectEqualStrings(core.name, d.name);
        try t.expectEqualStrings(core.desc, d.desc);
        try t.expectEqualStrings(core.schema, d.schema);
    }
    // 关键:禁用插件的工具查不到 —— 否则模型能调到没在 tools 里声明的工具
    try t.expect(findToolIn(bare, "lsp") == null);
    try t.expect(findToolIn(bare, "todo_write") == null);
    try t.expect(findToolIn(bare, "git_status") == null);
    // 核心工具始终在
    try t.expect(findToolIn(bare, "read") != null);
    try t.expect(findToolIn(bare, "grep") != null);

    // 开一个插件:它的工具在**这个集合**里可见
    const with_lsp = withEnabled(bare, "lsp");
    try t.expect(findToolIn(with_lsp, "lsp") != null);
    var defs2 = std.array_list.Managed(aimod.ToolDef).init(a);
    try appendToolDefsIn(with_lsp, &defs2);
    try t.expectEqual(toolsmod.tools.len + 1, defs2.items.len);
    // 其他插件仍然关着
    try t.expect(findToolIn(with_lsp, "todo_write") == null);

    // 多工具插件一次性全开
    const with_todo = withEnabled(with_lsp, "todo");
    try t.expect(findToolIn(with_todo, "todo_write") != null);
    try t.expect(findToolIn(with_todo, "todo_read") != null);

    // **本次改动的核心契约:启用集互不影响。**
    // 从前是进程级单例 —— 一个 Agent 开了 lsp,所有 Agent 都能调 lsp,
    // 而只读的调研 subagent 更不该因为兄弟 agent 的设置拿到别的工具。
    try t.expect(findToolIn(bare, "lsp") == null);
    try t.expect(findToolIn(with_lsp, "todo_write") == null);
    try t.expect(findToolIn(with_todo, "lsp") != null);

    // token 估算也跟着集合走 —— 上下文预算必须按本 Agent 的工具集算
    try t.expect(toolDefsTokensIn(with_todo) > toolDefsTokensIn(bare));

    // 子 agent 默认摘掉委派插件:否则每路孩子都付 8 个工具的 schema
    const parent_full = withEnabled(factorySet(), "task-delegation");
    const child_default = try childSet(parent_full, null);
    try t.expect(findToolIn(parent_full, "task") != null);
    try t.expect(findToolIn(child_default, "task") == null);
    try t.expect(findToolIn(child_default, "read") != null);
    // 钩子插件仍在(零 token)
    try t.expect((child_default & factorySet()) == factorySet());
    // 显式要回委派:只能从父集收,不能凭空开
    const child_nested = try childSet(parent_full, &.{"task-delegation"});
    try t.expect(findToolIn(child_nested, "task") != null);
    try t.expectError(error.UnknownPlugin, childSet(parent_full, &.{"no-such"}));
    try t.expectError(error.PluginNotHeld, childSet(factorySet(), &.{"task-delegation"}));
    // 工具白名单只能收紧
    const allow = try childToolAllow(a, parent_full, &.{ "read", "grep" });
    try t.expectEqual(@as(usize, 2), allow.len);
    try t.expect(exposesTool(child_default, allow, "read"));
    try t.expect(!exposesTool(child_default, allow, "write"));
    try t.expectError(error.UnknownTool, childToolAllow(a, parent_full, &.{"nope"}));
    try t.expectError(error.ToolNotHeld, childToolAllow(a, bare, &.{"lsp"}));

    var defs_allow = std.array_list.Managed(aimod.ToolDef).init(a);
    try appendToolDefsFiltered(child_default, allow, &defs_allow);
    try t.expectEqual(@as(usize, 2), defs_allow.items.len);
    try t.expect(toolDefsTokensFiltered(child_default, allow) < toolDefsTokensIn(child_default));

    // 进程默认集只影响新建 Agent 的初值
    try t.expectEqual(factorySet(), defaultSet());
    try t.expect(enable("lsp"));
    try t.expect(findToolIn(defaultSet(), "lsp") != null);
    try t.expect(disable("lsp"));
    try t.expect(findToolIn(defaultSet(), "lsp") == null);
    // 已有的集合不受进程默认集变化影响
    try t.expect(findToolIn(bare, "lsp") == null);
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
    try t.expect(std.mem.indexOf(u8, before, "[on ] cross-session-memory") != null);

    _ = enable("lsp");
    const after = try listPlugins(a);
    try t.expect(std.mem.indexOf(u8, after, "[on ] lsp") != null);
    // 工具名也列出来,便于用户知道开了什么
    try t.expect(std.mem.indexOf(u8, after, "tools: lsp") != null);
    const none = try enabledOptionalLine(a, factorySet());
    try t.expectEqual(@as(usize, 0), none.len);
    const some = try enabledOptionalLine(a, withEnabled(factorySet(), "lsp"));
    try t.expect(std.mem.indexOf(u8, some, "lsp") != null);
    try t.expect(std.mem.indexOf(u8, some, "cross-session-memory") == null);
}

test "applyFromConfig and catalog expose optional workflow plugin" {
    const t = std.testing;
    resetEnabledForTest();
    defer resetEnabledForTest();
    try t.expect(!isOn("task-delegation"));
    applyFromConfig(&.{ "task-delegation", "todo" }, &.{});
    try t.expect(isOn("task-delegation"));
    try t.expect(isOn("todo"));
    try t.expect(!isFactoryOn("task-delegation"));
    var aw = std.Io.Writer.Allocating.init(t.allocator);
    defer aw.deinit();
    try writeCatalog(&aw.writer);
    try t.expect(std.mem.indexOf(u8, aw.written(), "\"name\":\"task-delegation\"") != null);
    try t.expect(std.mem.indexOf(u8, aw.written(), "\"enabled\":true") != null);
}

test "disable withdraws tools hooks and schema" {
    const t = std.testing;
    resetEnabledForTest();
    defer resetEnabledForTest();

    try t.expect(!disable("no-such-plugin"));
    try t.expect(enable("lsp"));
    try t.expect(findToolIn(defaultSet(), "lsp") != null);
    try t.expect(disable("lsp"));
    try t.expect(findToolIn(defaultSet(), "lsp") == null);
    var defs = std.array_list.Managed(aimod.ToolDef).init(t.allocator);
    defer defs.deinit();
    try appendToolDefsIn(defaultSet(), &defs);
    for (defs.items) |d| try t.expect(!std.mem.eql(u8, d.name, "lsp"));

    try agentmod.util.testInit();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = agentmod.cfgmod.Config{ .arena = &arena };
    var provs = [_]agentmod.cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");
    agent.plugins = withoutEnabled(factorySet(), "command-canonicalization");
    try t.expect(runToolBefore(&agent, "bash", "sudo rm -rf / --no-preserve-root") == null);
    agent.plugins = factorySet();
    try t.expect(runToolBefore(&agent, "bash", "sudo rm -rf / --no-preserve-root") != null);
    try t.expect(runUserMessage(&agent, "hi") == null);
    runAfterTurn(&agent);
}

test "read handler plus after-chain keeps file body" {
    const t = std.testing;
    try agentmod.util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(agentmod.util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    const body = "x" ** (8 * 1024) ++ "\n// marker-read-ok\n";
    try tmp.dir.writeFile(agentmod.util.io, .{ .sub_path = "big.zig", .data = body });
    try agentmod.util.environ_map.?.put("PIZ_DIR", tmp_path);

    var cfg = agentmod.cfgmod.Config{ .arena = &arena };
    var provs = [_]agentmod.cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", tmp_path);

    const read_tool = toolsmod.find("read") orelse return error.TestUnexpectedResult;
    toolsmod.setRoot(tmp_path);
    defer toolsmod.clearRoot();
    const result = try read_tool.handler(a, "{\"path\":\"big.zig\"}");
    try t.expect(!result.is_error);
    try t.expect(std.mem.indexOf(u8, result.content, "marker-read-ok") != null);
    try t.expect(result.content.len > 4096);

    try t.expect(runToolAfter(@ptrCast(&agent), "read", result.content) == null);

    const bash_rw = runToolAfter(@ptrCast(&agent), "bash", "y" ** (8 * 1024));
    try t.expect(bash_rw != null);
    try t.expect(std.mem.indexOf(u8, bash_rw.?, "[Artifact stored:") != null);
}

test "collectSlash lists todo when enabled" {
    const t = std.testing;
    var off: [4]SlashCommand = undefined;
    try t.expectEqual(@as(usize, 0), collectSlash(0, &off));
    const set = withEnabled(withEnabled(withEnabled(withEnabled(withEnabled(withEnabled(withEnabled(0, "todo"), "skills"), "context-budget"), "git-awareness"), "lsp"), "web-search"), "task-delegation");
    var buf: [8]SlashCommand = undefined;
    const n = collectSlash(set, &buf);
    try t.expectEqual(@as(usize, 7), n);
    try t.expectEqualStrings("skills", buf[0].name);
    try t.expectEqualStrings("context", buf[1].name);
    try t.expectEqualStrings("git", buf[2].name);
    try t.expectEqualStrings("web", buf[3].name);
    try t.expectEqualStrings("agents", buf[4].name);
    try t.expectEqualStrings("todo", buf[5].name);
    try t.expectEqualStrings("lsp", buf[6].name);
    try t.expect(dispatchSlash(0, null, "todo", "") == null);
    try t.expect(dispatchSlash(0, null, "web", "") == null);
    try t.expect(dispatchSlash(0, null, "agents", "") == null);
}

// lsp 测已迁 plugins/lsp.zig

test {
    _ = @import("plugins/childbind.zig");
    _ = @import("plugins/api.zig");
    _ = @import("plugins/jsonx.zig");
    _ = @import("plugins/hooks.zig");
    _ = @import("plugins/extras.zig");
    _ = @import("plugins/web.zig");
    _ = @import("plugins/todo.zig");
    _ = @import("plugins/limits.zig");
    _ = @import("plugins/task.zig");
    _ = @import("plugins/agents.zig");
    _ = @import("plugins/lsp.zig");
}
