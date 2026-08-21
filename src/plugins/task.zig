// task-delegation:阻塞派生子 agent。
const std = @import("std");
const agentmod = @import("../agent.zig");
const activity = @import("../activity.zig");
const util = @import("../util.zig");
const toolsmod = @import("../tools.zig");
const limits = @import("limits.zig");
const jsonx = @import("jsonx.zig");
const childbind = @import("childbind.zig");
const poolmod = @import("../pool.zig");

const MAX_PARALLEL_TASKS = limits.MAX_PARALLEL_TASKS;
const MAX_PARALLEL_TASKS_NESTED = limits.MAX_PARALLEL_TASKS_NESTED;
const TASK_OUTPUT_LIMIT = limits.TASK_OUTPUT_LIMIT;
const TASK_TIMEOUT_MS = limits.TASK_TIMEOUT_MS;
const MAX_TASK_DEPTH = limits.MAX_TASK_DEPTH;
const DEPTH_ENV = limits.DEPTH_ENV;
const SPAWN_ENV = limits.SPAWN_ENV;
const parallelLimitAt = limits.parallelLimitAt;

pub fn processBaseDepth() usize {
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
    try argv.appendSlice(&.{ exe, "-p", "-n", "--provider", self.provider.name, "-m", self.model });
    if (self.read_only or force_read_only) try argv.append("-r");
    // 交互式父 agent 每次工具调用都问用户;子 agent 没有终端可问,
    // 只能自动执行 —— 这是委托的固有代价,文档里写明。
    try argv.append("-x");
    // desc 走 `--` 之后:任务描述以 '-' 开头(比如 "-r 选项做什么用?")
    // 否则会被子进程当成选项,直接 "unknown option" 退出。
    try argv.append("--");
    try argv.append(desc);
    return argv.toOwnedSlice();
}

/// 一个委托槽。两种执行路径共用它:
/// - 进程内(默认):在本进程建一个 Agent 跑,中间事件实时转发给父 agent
/// - 子进程(`PIZ_TASK_SPAWN=1`):spawn piz -p,只能拿到最终文本
const TaskSlot = struct {
    desc: []const u8,
    /// **本槽独占**的分配器。
    ///
    /// 不能共用 toolTask 的 arena:32 个槽在各自线程里跑,而 ArenaAllocator
    /// 不是线程安全的 —— 并发分配会直接损坏它。每槽一个 arena,由 toolTask
    /// 在读完结果后统一回收。
    arena: *std.heap.ArenaAllocator,
    alloc: std.mem.Allocator,
    cwd: []const u8,
    /// 本槽的序号(1 起),事件转发时告诉父 agent 是哪个子任务
    idx: usize = 0,
    /// 活动名(workflow 传节点 id;空则 "task N")
    name: []const u8 = "",
    /// 摘要源(workflow 传节点 task;空则用 desc 首段)
    brief: []const u8 = "",    read_only: bool = false,
    child_plugins: u16 = 0,
    tool_allow: []const []const u8 = &.{},

    // ---- 进程内路径 ----
    /// 父 agent:借它的 cfg / provider / model / 启用集 / 回调
    parent: ?*agentmod.Agent = null,

    // ---- 子进程路径 ----
    argv: []const []const u8 = &.{},
    /// 子进程环境:父环境 + PIZ_TASK_DEPTH+1(深度靠它跨进程传递)
    environ: ?*const std.process.Environ.Map = null,

    output: []const u8 = "",
    failed: bool = false,
    err: []const u8 = "",
    /// 墙钟耗时(毫秒)。回给模型 —— 它需要知道哪个子任务慢、慢多少,
    /// 才能判断下次是拆得更细还是别委派。
    elapsed_ms: i64 = 0,
};

/// 事件转发上下文:把 subagent 的回调翻译成父 agent 的 `on_subagent`。
const ForwardCtx = struct {
    slot: *TaskSlot,
    parent: *agentmod.Agent,
    act: activity.Handle = .none,

    fn emit(self: *ForwardCtx, kind: agentmod.SubagentEvent, text: []const u8) void {
        const f = self.parent.cbs.on_subagent orelse return;
        f(self.parent.cbs.ctx, self.slot.idx, kind, text) catch {};
    }
    fn onText(ctx: ?*anyopaque, text: []const u8) anyerror!void {
        const self: *ForwardCtx = @ptrCast(@alignCast(ctx.?));
        self.emit(.text, text);
    }
    fn onReasoning(ctx: ?*anyopaque, text: []const u8) anyerror!void {
        const self: *ForwardCtx = @ptrCast(@alignCast(ctx.?));
        self.emit(.reasoning, text);
    }
    fn onToolStart(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!void {
        const self: *ForwardCtx = @ptrCast(@alignCast(ctx.?));
        _ = args;
        self.act.detail(name);
        self.emit(.tool_start, name);
    }
    fn onToolEnd(ctx: ?*anyopaque, name: []const u8, is_error: bool, summary: []const u8) anyerror!void {
        const self: *ForwardCtx = @ptrCast(@alignCast(ctx.?));
        _ = summary;
        self.act.detail("");
        self.emit(if (is_error) .tool_failed else .tool_done, name);
    }
    fn onNotice(ctx: ?*anyopaque, text: []const u8) anyerror!void {
        const self: *ForwardCtx = @ptrCast(@alignCast(ctx.?));
        self.act.detail(text);
        self.emit(.notice, text);
    }
    /// subagent 跟着父 agent 一起被 Ctrl+C 中断
    fn onAbort(ctx: ?*anyopaque) bool {
        const self: *ForwardCtx = @ptrCast(@alignCast(ctx.?));
        return self.parent.aborted.load(.acquire);
    }
};

/// 首行(结束事件的摘要:多行答复在界面上只显示一行)。
fn firstLine(text: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    const nl = std.mem.indexOfScalar(u8, t, '\n') orelse return t;
    return t[0..nl];
}

/// 详情用:整段任务描述里的换行与控制符都会打乱摘要行(实测断行+乱码),
/// 折成一行空格。
fn oneLineOf(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    var buf: [activity.DETAIL_CAP]u8 = undefined;
    var n: usize = 0;
    for (t) |c| {
        if (c == '\n' or c == '\r' or c == '\t') {
            if (n == 0 or buf[n - 1] == ' ') continue;
            buf[n] = ' ';
            n += 1;
        } else if (c >= 0x20) {
            buf[n] = c;
            n += 1;
        }
        if (n >= activity.DETAIL_CAP - 1) break;
    }
    return agentmod.util.clampUtf8(buf[0..n], activity.DETAIL_CAP);
}

/// 跑一个委托槽。有 `parent` 就走进程内,否则 spawn 子进程。
fn runTaskSlot(slot: *TaskSlot) void {
    // 登记活动:委派原先是最长 10 分钟的纯黑盒,父 agent join() 干等,
    // 界面一动不动。登记后 TUI 能显示每个子 agent 的耗时与已回传字节。
    // 名用节点/序号,detail 用首行折叠(整段 desc 曾带换行+长文,摘要行断行乱码)
    var namebuf: [24]u8 = undefined;
    const name = if (slot.name.len > 0)
        slot.name
    else blk: {
        const s = std.fmt.bufPrint(&namebuf, "task {d}", .{slot.idx}) catch "task";
        break :blk s;
    };
    const act = activity.begin(.subagent, name, oneLineOf(if (slot.brief.len > 0) slot.brief else slot.desc), TASK_TIMEOUT_MS);
    defer {
        slot.elapsed_ms = act.elapsedMs();
        act.release();
        // 结束事件放这里 —— 两条执行路径都覆盖,且失败路径也发得出去。
        if (slot.parent) |p| {
            if (p.cbs.on_subagent) |f| {
                const summary = if (slot.failed) slot.err else slot.output;
                f(p.cbs.ctx, slot.idx, .finished, firstLine(summary)) catch {};
            }
        }
    }

    if (slot.parent) |parent| {
        runTaskInProcess(slot, parent, act);
        return;
    }
    runTaskSpawned(slot, act);
}

/// 进程内跑 subagent。
///
/// 比 spawn 快在省掉进程启动 + 配置重读 + 连接池重建;更重要的是**中间过程
/// 可见**:subagent 的每个 delta、每次工具调用都实时转发给父 agent,
/// 而子进程路径只能在结束时拿到一坨文本。
fn runTaskInProcess(slot: *TaskSlot, parent: *agentmod.Agent, act: activity.Handle) void {
    // 独立 arena:subagent 的历史与工具输出跟它一起回收,不进父 agent 的
    // 分配器(那是会话级的,长跑下只增不减)。
    var arena = agentmod.util.Arena.init(slot.alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var fwd = ForwardCtx{ .slot = slot, .parent = parent, .act = act };

    // 继承 provider / model / cwd / 启用集与只读位;深度 +1。
    // read_only 只能加不能减 —— 只读父 agent 的 subagent 必然只读,
    // 否则委派就是一条提权通道。
    var sub = agentmod.Agent.initOpts(a, parent.cfg, parent.provider.name, parent.model, parent.cwd, .{
        .read_only = parent.read_only or slot.read_only,
        .plugins = slot.child_plugins,
        .tool_allow = slot.tool_allow,
        .depth = parent.depth + 1,
        .think_level = parent.think_level,
    }) catch |e| {
        slot.failed = true;
        slot.err = std.fmt.allocPrint(slot.alloc, "cannot start sub-agent: {s}", .{@errorName(e)}) catch "cannot start sub-agent";
        return;
    };
    sub.cbs = .{
        .ctx = &fwd,
        .on_text = ForwardCtx.onText,
        .on_reasoning = ForwardCtx.onReasoning,
        .on_tool_start = ForwardCtx.onToolStart,
        .on_tool_end = ForwardCtx.onToolEnd,
        .on_notice = ForwardCtx.onNotice,
        .on_abort = ForwardCtx.onAbort,
    };

    const result = sub.send(slot.desc) catch |e| {
        // Ctrl+C 与真故障要分开:前者不是错误,模型不该重试
        const cancelled = act.cancelled() or parent.aborted.load(.acquire);
        slot.failed = true;
        slot.err = if (cancelled)
            "interrupted by user"
        else
            std.fmt.allocPrint(slot.alloc, "{s}", .{@errorName(e)}) catch "sub-agent failed";
        // 已产出的部分留着 —— 一个跑挂的 subagent 常常已经查到了有用的东西
        slot.output = lastAssistantText(slot.alloc, &sub);
        return;
    };

    // 输出必须拷进 slot.alloc:arena 在函数返回时就没了
    const text = if (result.text.len > 0) result.text else lastToolOutput(&sub);
    slot.output = copyTail(slot.alloc, text);
    if (result.error_msg) |msg| {
        slot.failed = true;
        slot.err = slot.alloc.dupe(u8, msg) catch "sub-agent reported an error";
    }
}

/// 取最后一条 assistant 正文(中断时留下的 partial)。
fn lastAssistantText(alloc: std.mem.Allocator, sub: *agentmod.Agent) []const u8 {
    var i = sub.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = sub.messages.items[i];
        if (std.mem.eql(u8, m.role, "assistant") and m.content.len > 0) return copyTail(alloc, m.content);
    }
    return "";
}

/// 模型一个字正文都没产出时,答案通常在最后一份工具输出里。
fn lastToolOutput(sub: *agentmod.Agent) []const u8 {
    var i = sub.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = sub.messages.items[i];
        if (std.mem.eql(u8, m.role, "tool") and m.content.len > 0) return m.content;
    }
    return "";
}

/// 拷尾部 TASK_OUTPUT_LIMIT 字节 —— 结论在最后。
fn copyTail(alloc: std.mem.Allocator, text: []const u8) []const u8 {
    const tail = if (text.len > TASK_OUTPUT_LIMIT) text[text.len - TASK_OUTPUT_LIMIT ..] else text;
    return alloc.dupe(u8, tail) catch "";
}

/// spawn 子进程跑 subagent(`PIZ_TASK_SPAWN=1` 的逃生通道)。
fn runTaskSpawned(slot: *TaskSlot, act: activity.Handle) void {
    const io = agentmod.util.io;
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
    // keep_bytes:边读边丢头部。原先全量收完再截到 TASK_OUTPUT_LIMIT ——
    // 一个吐 500MB 的子 agent 让父进程驻留 473MB(实测)去换 32KB 结论,
    // 而 subagent 是并行的,N 个就是 N 倍。
    var state = toolsmod.PipeState{
        .buf = &out,
        .err_buf = &errbuf,
        .out_fd = out_fd,
        .err_fd = err_fd,
        .keep_bytes = TASK_OUTPUT_LIMIT,
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

pub fn toolTask(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{});

    // 深度闸门:subagent 也有 `task` 工具(读同一份 settings.json,或直接
    // 继承父 agent 的启用集),不拦就是 fork bomb —— 并发是乘起来的。
    // 深度取 Agent 字段而非环境变量:进程内 subagent 没有新进程可继承环境。
    const depth = self.depth;
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
    const TaskSpec = struct {
        desc: []const u8,
        read_only: bool,
        plugins: ?[]const []const u8 = null,
        tools: ?[]const []const u8 = null,
    };
    var specs = std.array_list.Managed(TaskSpec).init(arena);
    const top_ro = blk: {
        if (v == .object) {
            if (v.object.get("read_only")) |r| {
                if (r == .bool) break :blk r.bool;
            }
        }
        break :blk false;
    };
    const top_plugins = jsonx.jsonStrs(arena, v, "plugins") catch {
        return .{ .content = "error: plugins must be a non-empty array of plugin names", .is_error = true };
    };
    const top_tools = jsonx.jsonStrs(arena, v, "tools") catch {
        return .{ .content = "error: tools must be a non-empty array of tool names", .is_error = true };
    };
    if (v == .object) {
        if (v.object.get("description")) |d| {
            if (d == .string and d.string.len > 0) try specs.append(.{ .desc = d.string, .read_only = top_ro, .plugins = top_plugins, .tools = top_tools });
        }
        if (v.object.get("tasks")) |ts| {
            if (ts == .array) {
                for (ts.array.items) |item| {
                    if (item != .object) continue;
                    const dd = item.object.get("description") orelse continue;
                    if (dd != .string or dd.string.len == 0) continue;
                    const ro = if (item.object.get("read_only")) |r| (if (r == .bool) r.bool else top_ro) else top_ro;
                    const p = jsonx.jsonStrs(arena, item, "plugins") catch {
                        return .{ .content = "error: tasks[].plugins must be a non-empty array of plugin names", .is_error = true };
                    };
                    const tls = jsonx.jsonStrs(arena, item, "tools") catch {
                        return .{ .content = "error: tasks[].tools must be a non-empty array of tool names", .is_error = true };
                    };
                    try specs.append(.{ .desc = dd.string, .read_only = ro, .plugins = p orelse top_plugins, .tools = tls orelse top_tools });
                }
            }
        }
    }
    if (specs.items.len == 0) {
        return .{ .content = "error: task requires a non-empty 'description' or 'tasks[].description'", .is_error = true };
    }
    // 上限按深度取:并发是乘起来的,嵌套层不能再拿顶层的 32。
    const limit = parallelLimitAt(depth);
    if (specs.items.len > limit) {
        return .{
            .content = try std.fmt.allocPrint(arena, "error: too many tasks ({d}); max {d} per call at delegation depth {d} — batch them or run the rest in a follow-up call", .{ specs.items.len, limit, depth }),
            .is_error = true,
        };
    }

    // 执行路径:默认进程内。`PIZ_TASK_SPAWN=1` 切回 spawn 子进程 ——
    // 进程内共享地址空间,subagent 里的 panic 会拖垮整个 piz,留个逃生通道。
    const spawn_mode = blk: {
        const env = agentmod.util.environ_map orelse break :blk false;
        const flag = env.get(SPAWN_ENV) orelse break :blk false;
        break :blk !(flag.len == 0 or std.mem.eql(u8, flag, "0"));
    };

    const slots = try arena.alloc(TaskSlot, specs.items.len);
    // 每槽一个独立 arena:槽在各自线程里跑,共用一个 ArenaAllocator 会并发
    // 损坏它。底层内存从父 arena 借,读完结果统一释放。
    const slot_arenas = try arena.alloc(std.heap.ArenaAllocator, specs.items.len);
    for (slot_arenas) |*sa| sa.* = std.heap.ArenaAllocator.init(arena);
    defer for (slot_arenas) |*sa| sa.deinit();

    if (!spawn_mode) {
        for (slots, slot_arenas, specs.items, 1..) |*slot, *sa, spec, i| {
            const child_plugins = childbind.resolveSet(self.plugins, spec.plugins) catch |e| return .{
                .content = switch (e) {
                    error.UnknownPlugin => "error: unknown plugin name in plugins[]",
                    error.PluginNotHeld => "error: plugins[] can only keep plugins you already have",
                    else => "error: cannot resolve child plugins",
                },
                .is_error = true,
            };
            const raw_tools = if (spec.tools) |names| childbind.resolveTools(sa.allocator(), self.plugins, names) catch |e| return .{
                .content = switch (e) {
                    error.UnknownTool => "error: unknown tool name in tools[]",
                    error.ToolNotHeld => "error: tools[] can only keep tools you already have",
                    else => "error: cannot resolve child tools",
                },
                .is_error = true,
            } else &.{};
            slot.* = .{
                .desc = spec.desc,
                .arena = sa,
                .alloc = sa.allocator(),
                .cwd = self.cwd,
                .idx = i,
                .read_only = spec.read_only,
                .child_plugins = child_plugins,
                .tool_allow = raw_tools,
                .parent = self,
            };
        }
    } else {
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
        const child_env = try arena.create(std.process.Environ.Map);
        child_env.* = std.process.Environ.Map.init(arena);
        if (agentmod.util.environ_map) |pe| {
            var it = pe.iterator();
            while (it.next()) |kv| try child_env.put(kv.key_ptr.*, kv.value_ptr.*);
        }
        try child_env.put(DEPTH_ENV, try std.fmt.allocPrint(arena, "{d}", .{depth + 1}));

        for (slots, slot_arenas, specs.items, 1..) |*slot, *sa, spec, i| {
            slot.* = .{
                .desc = spec.desc,
                .arena = sa,
                .alloc = sa.allocator(),
                .cwd = self.cwd,
                .idx = i,
                .read_only = spec.read_only,
                .argv = try buildTaskArgv(arena, self, exe, spec.desc, spec.read_only),
                .environ = child_env,
            };
        }
    }

    try runTasks(slots, arena);
    return formatTaskResults(arena, slots);
}

fn runTasks(slots: []TaskSlot, arena: std.mem.Allocator) !void {
    if (slots.len == 1) {
        runTaskSlot(&slots[0]);
        return;
    }
    const TaskJob = struct {
        slot: *TaskSlot,
        left: *std.atomic.Value(usize),
        fn run(ptr: *anyopaque) void {
            const job: *@This() = @ptrCast(@alignCast(ptr));
            runTaskSlot(job.slot);
            _ = job.left.fetchSub(1, .acq_rel);
        }
    };
    var left = std.atomic.Value(usize).init(slots.len);
    const jobs = try arena.alloc(TaskJob, slots.len);
    for (slots, jobs) |*slot, *job| {
        job.* = .{ .slot = slot, .left = &left };
        poolmod.global().enqueue(.{ .run = TaskJob.run, .ctx = @ptrCast(job) }) catch {
            TaskJob.run(@ptrCast(job));
        };
    }
    while (left.load(.acquire) > 0) {
        std.Io.sleep(agentmod.util.io, .{ .nanoseconds = 5 * std.time.ns_per_ms }, .awake) catch break;
    }
}

/// 供 workflow 等同一路径复用的任务描述。
pub const Spec = struct {
    desc: []const u8,
    read_only: bool = false,
    plugins: ?[]const []const u8 = null,
    tools: ?[]const []const u8 = null,
    /// 0 = 按本批序号。workflow 传入 DAG 下标 + 1,好让前端把事件对上节点。
    idx: usize = 0,
    /// 活动名(UI 摘要行显示;workflow 传节点 id)
    name: []const u8 = "",
    /// 摘要文字(UI 详情;workflow 传节点 task 原文,省略 role 模板)
    brief: []const u8 = "",
};

pub const RunOut = struct {
    desc: []const u8,
    output: []const u8,
    err: []const u8,
    failed: bool,
    elapsed_ms: i64,
};

/// 跑一批独立任务。绑定失败返回 fail 字符串,否则跑完返回结果。
/// 输出拷到 caller arena,槽 arena 在返回前回收。
pub fn runSpecs(self: *agentmod.Agent, arena: std.mem.Allocator, specs: []const Spec) !union(enum) {
    done: []RunOut,
    fail: []const u8,
} {
    if (specs.len == 0) return .{ .fail = "error: no task given" };
    const slot_arenas = try arena.alloc(std.heap.ArenaAllocator, specs.len);
    for (slot_arenas) |*sa| sa.* = .init(self.alloc);
    defer for (slot_arenas) |*sa| sa.deinit();

    const slots = try arena.alloc(TaskSlot, specs.len);
    for (slots, slot_arenas, specs, 1..) |*slot, *sa, spec, i| {
        const child_plugins = childbind.resolveSet(self.plugins, spec.plugins) catch |e| return .{
            .fail = switch (e) {
                error.UnknownPlugin => "error: unknown plugin name in plugins[]",
                error.PluginNotHeld => "error: plugins[] can only keep plugins you already have",
                else => "error: cannot resolve child plugins",
            },
        };
        const raw_tools = if (spec.tools) |names| childbind.resolveTools(sa.allocator(), self.plugins, names) catch |e| return .{
            .fail = switch (e) {
                error.UnknownTool => "error: unknown tool name in tools[]",
                error.ToolNotHeld => "error: tools[] can only keep tools you already have",
                else => "error: cannot resolve child tools",
            },
        } else &.{};
        slot.* = .{
            .desc = spec.desc,
            .arena = sa,
            .alloc = sa.allocator(),
            .cwd = self.cwd,
            .idx = if (spec.idx > 0) spec.idx else i,
            .name = spec.name,
            .brief = spec.brief,
            .read_only = spec.read_only,
            .child_plugins = child_plugins,
            .tool_allow = raw_tools,
            .parent = self,
        };
    }
    try runTasks(slots, arena);
    const out = try arena.alloc(RunOut, slots.len);
    for (slots, out) |s, *o| {
        o.* = .{
            .desc = try arena.dupe(u8, s.desc),
            .output = try arena.dupe(u8, s.output),
            .err = try arena.dupe(u8, s.err),
            .failed = s.failed,
            .elapsed_ms = s.elapsed_ms,
        };
    }
    return .{ .done = out };
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

    // 孩子掩码只能收紧:未知名、空数组、父集没有的插件/工具都得响
    const bad_plug = try toolTask(&agent, a, "{\"description\":\"x\",\"plugins\":[\"no-such\"]}");
    try t.expect(bad_plug.is_error);
    try t.expect(std.mem.indexOf(u8, bad_plug.content, "unknown plugin") != null);
    const empty_tools = try toolTask(&agent, a, "{\"description\":\"x\",\"tools\":[]}");
    try t.expect(empty_tools.is_error);
    try t.expect(std.mem.indexOf(u8, empty_tools.content, "non-empty") != null);
    const unknown_tool = try toolTask(&agent, a, "{\"description\":\"x\",\"tools\":[\"nope\"]}");
    try t.expect(unknown_tool.is_error);
    try t.expect(std.mem.indexOf(u8, unknown_tool.content, "unknown tool") != null);
    const not_held = try toolTask(&agent, a, "{\"description\":\"x\",\"plugins\":[\"task-delegation\"]}");
    try t.expect(not_held.is_error);
    try t.expect(std.mem.indexOf(u8, not_held.content, "already have") != null);

    // 超过并行上限 → 拒绝,不是静默丢弃。任务数从常量派生 ——
    // 硬编码的话每次调整上限都要跟着改测试,而忘了改就变成「测试通过但
    // 其实没测到拒绝路径」。
    var many = std.array_list.Managed(u8).init(a);
    try many.appendSlice("{\"tasks\":[");
    for (0..MAX_PARALLEL_TASKS + 1) |i| {
        if (i > 0) try many.appendSlice(",");
        try many.appendSlice(try std.fmt.allocPrint(a, "{{\"description\":\"t{d}\"}}", .{i}));
    }
    try many.appendSlice("]}");
    const over = try toolTask(&agent, a, many.items);
    try t.expect(over.is_error);
    try t.expect(std.mem.indexOf(u8, over.content, "too many tasks") != null);

    // 正好在上限上不该被拒(只验参数校验,不真 spawn 那么多进程:
    // 这里用空 description 让它在 spawn 之前就返回参数错误)
    try t.expect(std.mem.indexOf(u8, (try toolTask(&agent, a, "{\"tasks\":[]}")).content, "non-empty") != null);

    // 深度闸门:subagent 也带 task 工具,不拦就是 fork bomb(并发按层相乘)。
    // 深度现在是 Agent 字段 —— 进程内 subagent 没有新进程可继承环境变量。
    agent.depth = MAX_TASK_DEPTH;
    const deep = try toolTask(&agent, a, "{\"description\":\"go deeper\"}");
    try t.expect(deep.is_error);
    try t.expect(std.mem.indexOf(u8, deep.content, "depth limit") != null);
    agent.depth = 0;

    // 环境变量只做**进程基准**:本进程被别的 piz spawn 起来时,顶层 agent
    // 的起始深度从这里读。两条路径在 processBaseDepth 汇合。
    const env = agentmod.util.environ_map.?;
    const saved = env.get(DEPTH_ENV);
    defer if (saved) |s| {
        env.put(DEPTH_ENV, s) catch {};
    } else {
        _ = env.swapRemove(DEPTH_ENV);
    };
    try env.put(DEPTH_ENV, "0");
    try t.expectEqual(@as(usize, 0), processBaseDepth());
    try env.put(DEPTH_ENV, "2");
    try t.expectEqual(@as(usize, 2), processBaseDepth());
    // 坏值当 0 处理(不能因为环境被污染就拒绝所有委托)
    try env.put(DEPTH_ENV, "not-a-number");
    try t.expectEqual(@as(usize, 0), processBaseDepth());
    // 关键:环境变量不再直接决定闸门 —— agent.depth 才是
    try env.put(DEPTH_ENV, "9");
    agent.depth = 0;
    const still_ok = try toolTask(&agent, a, "{\"tasks\":[]}");
    try t.expect(std.mem.indexOf(u8, still_ok.content, "depth limit") == null);

    // 嵌套层的并行上限必须远小于顶层 —— 并发是**乘起来**的:
    // 顶层 32 × 嵌套 32 × 深度 2 = 1056 个 piz 进程 ≈ 9GB,足够打死机器。
    try t.expectEqual(@as(usize, MAX_PARALLEL_TASKS), parallelLimitAt(0));
    try t.expectEqual(@as(usize, MAX_PARALLEL_TASKS_NESTED), parallelLimitAt(1));
    try t.expect(MAX_PARALLEL_TASKS_NESTED < MAX_PARALLEL_TASKS);
    // 最坏进程数要有个能算清的上界(顶层 + 顶层×嵌套)
    try t.expect(MAX_PARALLEL_TASKS + MAX_PARALLEL_TASKS * MAX_PARALLEL_TASKS_NESTED <= 256);

    // 深度 1 时,超过嵌套上限就该被拒 —— 顶层的 32 在这里不适用
    agent.depth = 1;
    var nested = std.array_list.Managed(u8).init(a);
    try nested.appendSlice("{\"tasks\":[");
    for (0..MAX_PARALLEL_TASKS_NESTED + 1) |i| {
        if (i > 0) try nested.appendSlice(",");
        try nested.appendSlice(try std.fmt.allocPrint(a, "{{\"description\":\"n{d}\"}}", .{i}));
    }
    try nested.appendSlice("]}");
    const over_nested = try toolTask(&agent, a, nested.items);
    try t.expect(over_nested.is_error);
    try t.expect(std.mem.indexOf(u8, over_nested.content, "too many tasks") != null);
    // 错误里要点明是哪一层的上限,否则模型不知道为什么同样的调用在顶层能过
    try t.expect(std.mem.indexOf(u8, over_nested.content, "depth 1") != null);
}

test "task slots run in parallel and report per-task failure" {
    const t = std.testing;
    try agentmod.util.testInit();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 直接驱动 TaskSlot:用 sh 替代子 agent,验证并行 + 输出回传 + 失败归因。
    // 真跑 piz 子进程要 API key,测试环境没有。
    // 每槽独立 arena:它们在各自线程里跑,共用一个会并发损坏
    var sa = [_]std.heap.ArenaAllocator{
        std.heap.ArenaAllocator.init(a), std.heap.ArenaAllocator.init(a), std.heap.ArenaAllocator.init(a),
    };
    defer for (&sa) |*x| x.deinit();
    var slots = [_]TaskSlot{
        .{ .desc = "ok", .arena = &sa[0], .alloc = sa[0].allocator(), .cwd = "/tmp", .argv = &.{ "sh", "-c", "sleep 0.3; echo DONE-A" } },
        .{ .desc = "ok2", .arena = &sa[1], .alloc = sa[1].allocator(), .cwd = "/tmp", .argv = &.{ "sh", "-c", "sleep 0.3; echo DONE-B" } },
        .{ .desc = "fail", .arena = &sa[2], .alloc = sa[2].allocator(), .cwd = "/tmp", .argv = &.{ "sh", "-c", "echo BOOM >&2; exit 3" } },
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

    var sa2 = [_]std.heap.ArenaAllocator{
        std.heap.ArenaAllocator.init(a), std.heap.ArenaAllocator.init(a),
    };
    defer for (&sa2) |*x| x.deinit();
    var slots = [_]TaskSlot{
        .{ .desc = "survey the parser", .arena = &sa2[0], .alloc = sa2[0].allocator(), .cwd = "/tmp", .argv = &.{ "sh", "-c", "printf 'line one\\nline two\\n'" } },
        .{ .desc = "check the lexer", .arena = &sa2[1], .alloc = sa2[1].allocator(), .cwd = "/tmp", .argv = &.{ "sh", "-c", "echo partial-progress; echo WHY >&2; exit 4" } },
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
    var sa3 = std.heap.ArenaAllocator.init(a);
    defer sa3.deinit();
    var all_bad = [_]TaskSlot{
        .{ .desc = "x", .arena = &sa3, .alloc = sa3.allocator(), .cwd = "/tmp", .argv = &.{ "sh", "-c", "exit 1" } },
    };
    runTaskSlot(&all_bad[0]);
    const bad = try formatTaskResults(a, &all_bad);
    try t.expect(bad.is_error);
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

    // desc 必须排在 `--` 之后,且 `--` 之后只有 desc。
    // 否则以 '-' 开头的任务描述会被子进程当选项,直接 unknown option 退出。
    const argv4 = try buildTaskArgv(a, &rw, "/proc/self/exe", "-r what does it do", false);
    try t.expectEqualStrings("--", argv4[argv4.len - 2]);
    try t.expectEqualStrings("-r what does it do", argv4[argv4.len - 1]);
    // 描述里的 "-r" 不能被误当成只读开关:`--` 之前不该出现 -r
    for (argv4[0 .. argv4.len - 2]) |x| try t.expect(!std.mem.eql(u8, x, "-r"));
}
