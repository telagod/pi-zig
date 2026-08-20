// agent.zig — 工具循环编排:消息组装、AGENTS.md、空转止损、压缩、上下文裁剪。
const std = @import("std");
pub const util = @import("util.zig");
pub const ai = @import("ai.zig");
pub const cfgmod = @import("config.zig");
const toolsmod = @import("tools.zig");
const pluginsmod = @import("plugins.zig");
const jsrt = @import("jsrt.zig");
const pricing = @import("pricing.zig");
const pkgsmod = @import("pkgs.zig");
const compress = @import("compress.zig");
const seams = @import("seams.zig");
const httpcmod = @import("httpc.zig");
const imgxmod = @import("imgx.zig");
const sessionmod = @import("session.zig");

/// 消息列表的预分配容量。
///
/// 跨线程读安全契约:worker 线程 append 消息的同时,HTTP/主线程会无锁读
/// `messages.items`(web 的 /api/state、/api/sessions,CLI 状态栏)。
/// 唯一的危险是 append 触发 realloc —— 旧 buffer 被 free,读者拿到悬垂指针。
/// 预分配后 append 只写 `items[len]` 再 `len += 1`(先写数据后加 len),
/// items 指针永不移动、读者拿到的每条消息都完整。
///
/// 8192 条 ≈ 数千轮对话,而 85% 窗口硬线在这之前早就触发 compact
/// (compact 只 clear 不缩小容量),所以容量耗尽在实际上不可达。
const MESSAGES_PRECAP = 8192;

/// 新建消息列表(预分配容量,见 MESSAGES_PRECAP 的并发契约)。
fn newMsgList(alloc: std.mem.Allocator) !std.array_list.Managed(ai.Message) {
    var msgs = std.array_list.Managed(ai.Message).init(alloc);
    try msgs.ensureTotalCapacity(MESSAGES_PRECAP);
    return msgs;
}
/// 极简核心:单档——总 token 超 85% 窗口 → compact(密图秒压,增量边界 + cut point)。
/// 增强能力(工具输出预剪枝等)由内置插件承担(plugins.zig)。
pub const CTX_HARD_PERCENT = 85;
/// compact 时保留的最近消息预算(窗口 20%)
pub const CTX_KEEP_PERCENT = 20;
/// 同一 assistant 消息内并行执行的工具上限。
/// 官方 pi 默认并行;串行会让「一次读 5 个文件」的延迟成倍。
pub const MAX_PARALLEL_TOOLS = 8;

/// 流中途断线后自动续跑的次数上限。
///
/// 断线重连和「模型自己说完」是两件事:重连是把被网络切断的**同一次**回复
/// 接上,不是重新提问。2 次足够覆盖真实抖动;再多说明链路坏了,
/// 继续重连只是把同一个错误重复三遍,还每次都烧一遍上下文。
pub const MAX_STREAM_RESUMES = 2;

/// 连续多少轮发出**完全相同**的工具调用后判定为空转。
///
/// 2 = 第三次发起同一批调用时干预。合法的重试几乎总会改参数(换路径、
/// 加超时、换命令),原封不动重发三次说明模型没在用结果。
const MAX_REPEAT_ROUNDS = 2;
const MAX_FAKE_CALL_RETRIES = 2;

/// 模型把工具调用写成正文时用的标记。都是各家的特殊 token 漏成了字面文本,
/// 正常回答里不会出现。`｜` 是 U+FF5C 全角竖线,不是 ASCII `|`。
pub const textToolCallMarker = ai.textToolCallMarker;

/// 同一工具拿到**完全相同的输出**多少次后判定为空转。
///
/// 比参数比对更管得住实际情况:实测模型会把 `./x.sh | tail -1` 换成
/// `./x.sh 2>&1 | tail -n 1` 再换成 `cd d && ./x.sh | tail -1` —— 参数每次不同,
/// 拿到的输出一模一样,18 次调用里 5 次是同一份结果。
///
/// 3 次:允许一次手滑重试,第三次拿到同一份输出还不收尾就是在打转。
/// 合法用法不会撞上 —— 逐个读文件输出各不相同,轮询等状态输出会变。
const MAX_SAME_OUTPUT = 3;

/// 一次工具结果的指纹:工具名 + 输出内容。
///
/// 只用来判断「和上次一样吗」,不需要抗碰撞,所以用 Wyhash 而不是加密哈希。
/// 存 hash 而非全文:工具输出可能 16KB,留几份原文纯属白占内存。
/// 工具名混进去 —— 两个不同工具恰好返回同样内容不算重复。
fn outputFingerprint(name: []const u8, content: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(name);
    h.update(content);
    return h.final();
}

/// 两批工具调用是否完全相同(名字与参数逐个一致)。
/// 空批不算相同 —— 那是「还没调过」,不是重复。
fn sameToolCalls(a: []const ai.ToolCall, b: []const ai.ToolCall) bool {
    if (a.len == 0 or a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name)) return false;
        if (!std.mem.eql(u8, x.args, y.args)) return false;
    }
    return true;
}

/// 会改文件的工具:并行时对同一路径必须互斥。
/// 否则两个工具各读到同一份旧内容、各自计算,后写的覆盖前面的(丢写)。
pub fn isMutatingTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "write") or
        std.mem.eql(u8, name, "edit") or
        std.mem.eql(u8, name, "multi_edit");
}

/// per-file 写锁注册表。粒度为「args 里的 path 字符串」。
/// 取不到路径的写类工具退化为抢全局锁(保守但绝不丢写)。
///
/// **注册表自己拥有 allocator,不借调用方的。** 它的寿命是进程级(锁必须在
/// 同一路径的后续写操作里还认得出来),而调用方的 allocator 可能是 arena 或
/// 会话级的 —— 借来的一旦释放,hashmap 的 header 就悬垂,下次 get 直接段错误。
/// page_allocator 无状态、进程级有效。条目数受工作集文件数限制,不会无界增长。
const FileLocks = struct {
    var registry_mutex: std.Io.Mutex = .init;
    var registry: ?std.StringHashMap(*std.Io.Mutex) = null;
    var fallback: std.Io.Mutex = .init;

    /// 取某路径的锁(首次访问时创建)。
    fn get(path: []const u8) *std.Io.Mutex {
        const gpa = std.heap.page_allocator;
        registry_mutex.lockUncancelable(util.io);
        defer registry_mutex.unlock(util.io);
        if (registry == null) {
            registry = std.StringHashMap(*std.Io.Mutex).init(gpa);
        }
        var reg = &registry.?;
        if (reg.get(path)) |m| return m;
        const m = gpa.create(std.Io.Mutex) catch return &fallback;
        m.* = .init;
        const key = gpa.dupe(u8, path) catch return &fallback;
        reg.put(key, m) catch return &fallback;
        return m;
    }
};

/// 一个工具调用的执行槽。preflight 填好后交给工作线程,结果原地写回。
pub const ToolSlot = struct {
    call: ai.ToolCall,
    agent: *Agent,
    tool: ?*const toolsmod.Tool = null,
    result: toolsmod.Result = .{ .content = "", .is_error = false },
    /// preflight 已定案(权限拒绝/未知工具/被插件拦截),无需执行。
    done: bool = false,
};

/// 工作线程主体:执行一个工具调用。
/// 写类工具按路径加锁;读类工具无锁并行。
pub fn runToolSlot(slot: *ToolSlot) void {
    const self = slot.agent;
    const t = slot.tool orelse return;

    // 写类工具:按它实际要改的文件加锁,防丢写。
    // 最多同时持有 MAX_LOCKED_PATHS 把锁;超出或解析失败时退化为全局锁。
    var held: [MAX_LOCKED_PATHS]?*std.Io.Mutex = @splat(null);
    var held_n: usize = 0;
    if (isMutatingTool(slot.call.name)) {
        held_n = lockPathsFor(self, slot.call.args, &held);
    }
    defer {
        // 逆序释放(与获取顺序相反,惯例;互斥锁本身不要求)
        var k = held_n;
        while (k > 0) {
            k -= 1;
            if (held[k]) |m| m.unlock(util.io);
        }
    }

    // 工具 handler 用 agent 的 allocator。std 的 GPA/DebugAllocator 是线程安全的,
    // 但 handler 内部不得触碰 Agent 可变状态 —— 现有 ctx_handler 只读 provider/usage。
    //
    // 工具根目录走 thread-local:核心工具的签名里没有 Agent(它们用无 ctx 的
    // `handler`),而相对路径必须相对**这个 Agent 的 cwd** 而不是进程 cwd。
    // web 模式多 workspace 下这是实际的数据损坏:会话声明在 projB,
    // `write out.txt` 落进 projA(实测复现过)。
    toolsmod.setRoot(self.cwd);
    toolsmod.setSandbox(self.cfg.default_sandbox);
    seams.setFs(self.fs);
    defer toolsmod.clearRoot();
    defer toolsmod.clearSandbox();
    // JS 扩展钩子:tool_call 可拦截(block),tool_result 可改写({replace},如 artifact 外置)。
    // 桥全程互斥;无处理器时缓存旗标直接短路,不进 JS。
    var js_arena_inst = std.heap.ArenaAllocator.init(self.alloc);
    defer js_arena_inst.deinit();
    const ja = js_arena_inst.allocator();
    if (jsrt.emitToolCall(ja, slot.call.name, slot.call.args)) |reason| {
        slot.result = .{ .content = self.alloc.dupe(u8, reason) catch "blocked by js extension", .is_error = true };
        return;
    }
    if (t.payload.len > 0) {
        slot.result = toolsmod.runPkgCommand(self.alloc, t.payload, slot.call.args) catch |err| toolsmod.crashResult(self.alloc, slot.call.name, err);
    } else if (jsrt.enabled and t.ctx_handler == jsrt.toolEntryMarker) {
        // JS 注册工具:名字从 call 取(ctx_handler 不带名),全程互斥序列化。
        // 携 context 快照供 piz.contextStats()(scratch arena 即弃)。
        var sa = std.heap.ArenaAllocator.init(self.alloc);
        defer sa.deinit();
        slot.result = jsrt.runJsTool(self.alloc, slot.call.name, slot.call.args, self.jsStatsJson(sa.allocator())) catch |err| toolsmod.crashResult(self.alloc, slot.call.name, err);
    } else if (t.ctx_handler) |h| {
        slot.result = h(@ptrCast(self), self.alloc, slot.call.args) catch |err| toolsmod.crashResult(self.alloc, slot.call.name, err);
    } else {
        slot.result = t.handler(self.alloc, slot.call.args) catch |err| toolsmod.crashResult(self.alloc, slot.call.name, err);
    }
    if (jsrt.emitToolResult(ja, slot.call.name, slot.result.content)) |repl| {
        slot.result.content = self.alloc.dupe(u8, repl) catch slot.result.content;
    }
}
/// 限流包装:等到有名额才执行,完成后归还。
///
/// 为什么不用「一批 8 个、join 完再开下一批」:那样一批里最慢的会拖住整批,
/// 快的线程结束后名额空着也不补人。实测 9 个各 100ms 的工具,分批要 202ms,
/// 流水线只要 102ms。信号量让「一个完成立刻补下一个」,没有批边界。
fn runToolSlotGated(slot: *ToolSlot, sem: *std.Io.Semaphore) void {
    sem.waitUncancelable(util.io);
    defer sem.post(util.io);
    runToolSlot(slot);
}

/// 单次工具调用最多按路径加锁的文件数。
/// 超过就退化为全局锁 —— 一次改这么多文件的批次,串行化的代价可以接受,
/// 而无上限持锁会让锁数组无法放在栈上。
pub const MAX_LOCKED_PATHS = 16;

/// 为一次写类工具调用获取所需的全部文件锁,返回持锁数量。
///
/// 死锁避免:多把锁按路径字典序依次获取。所有线程用同一个顺序,
/// 就不会出现「A 持 x 等 y、B 持 y 等 x」的环。这是加多锁的必要条件,
/// 不是优化 —— 少了它,两个 multi_edit 撞上重叠文件集就会永久互等。
pub fn lockPathsFor(self: *Agent, args: []const u8, out: *[MAX_LOCKED_PATHS]?*std.Io.Mutex) usize {
    var arena = util.Arena.init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var paths: [MAX_LOCKED_PATHS][]const u8 = undefined;
    const n = collectPaths(a, args, &paths);
    if (n == 0) {
        // 解析不出任何路径(args 非法、或路径数超上限):全局锁最保守
        FileLocks.fallback.lockUncancelable(util.io);
        out[0] = &FileLocks.fallback;
        return 1;
    }

    // 字典序排序 + 去重(同一文件在 multi_edit 里出现两次时不能重复加锁 —— 会自锁死)
    std.mem.sort([]const u8, paths[0..n], {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);

    var held: usize = 0;
    for (paths[0..n], 0..) |p, i| {
        if (i > 0 and std.mem.eql(u8, p, paths[i - 1])) continue; // 去重
        const m = FileLocks.get(p);
        m.lockUncancelable(util.io);
        out[held] = m;
        held += 1;
    }
    return held;
}

/// 从工具 args 里收集所有要写的路径。
/// - 顶层 `path`(write / edit):1 个
/// - 顶层 `files[].path`(multi_edit):N 个
///
/// 返回收集到的数量;0 表示无法确定(调用方退化为全局锁)。
/// 超过 MAX_LOCKED_PATHS 也返回 0 —— 宁可整体串行,不要只锁一部分(那等于没锁)。
pub fn collectPaths(a: std.mem.Allocator, args: []const u8, out: *[MAX_LOCKED_PATHS][]const u8) usize {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, args, .{}) catch return 0;
    if (v != .object) return 0;

    if (v.object.get("path")) |p| {
        if (p == .string and p.string.len > 0) {
            out[0] = p.string;
            return 1;
        }
    }
    // multi_edit:files 数组里每个元素的 path
    if (v.object.get("files")) |fs| {
        if (fs != .array) return 0;
        if (fs.array.items.len > MAX_LOCKED_PATHS) return 0;
        var n: usize = 0;
        for (fs.array.items) |it| {
            if (it != .object) continue;
            const p = it.object.get("path") orelse continue;
            if (p != .string or p.string.len == 0) continue;
            out[n] = p.string;
            n += 1;
        }
        return n;
    }
    return 0;
}

/// subagent 事件类型(父 agent 侧决定怎么展示)。
pub const SubagentEvent = enum {
    text,
    reasoning,
    tool_start,
    tool_done,
    tool_failed,
    notice,
    /// 这一路委派结束(text 是最终答复的首行或错误原因)
    finished,
};

pub const AgentCallbacks = struct {
    ctx: ?*anyopaque = null,
    on_text: ?*const fn (ctx: ?*anyopaque, text: []const u8) anyerror!void = null,
    on_reasoning: ?*const fn (ctx: ?*anyopaque, text: []const u8) anyerror!void = null,
    on_tool_start: ?*const fn (ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!void = null,
    on_tool_end: ?*const fn (ctx: ?*anyopaque, name: []const u8, is_error: bool, summary: []const u8) anyerror!void = null,
    /// 工具执行前权限询问;返回 true 放行,false 拒绝(以 declined 消息回模型)。
    /// null = 一律放行(print 模式 / 测试默认)。
    on_require_permission: ?*const fn (ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!bool = null,
    /// 返回 true 表示取消(线程退出时用)
    on_turn_end: ?*const fn (ctx: ?*anyopaque) anyerror!void = null,
    /// 请求中止:ai.run 流式检查点每 chunk 判定(读 agent.aborted);
    /// 返回 true 时中断当前轮并保留 partial 文本。
    on_abort: ?*const fn (ctx: ?*anyopaque) bool = null,
    /// 流建立后通知(存 cur_stream,供中断 shutdown 打断阻塞读)
    on_connect: ?*const fn (ctx: ?*anyopaque, stream: *httpcmod.Stream) void = null,
    /// 系统级告知:自愈动作、限额触顶等「agent 替用户做了什么」的说明。
    ///
    /// 独立于 on_text:那是模型的话,这是引擎的话。混在一起用户分不清
    /// 「模型说链路断了」和「引擎发现链路断了正在重连」—— 后者才需要
    /// 用户知道 piz 仍在推进,而不是卡住了。
    on_notice: ?*const fn (ctx: ?*anyopaque, text: []const u8) anyerror!void = null,
    /// subagent 的中间事件(进程内委派)。`idx` 是任务序号(1 起)。
    ///
    /// 子进程路径下委派是纯黑盒:父 agent join() 干等,只能拿到最终文本。
    /// 进程内跑之后 subagent 的每个 delta、每次工具调用都能实时透出来 ——
    /// 用户看得见「3 号在跑 grep」而不是只有一个转圈。
    on_subagent: ?*const fn (ctx: ?*anyopaque, idx: usize, kind: SubagentEvent, text: []const u8) anyerror!void = null,
};

/// 止损切断时模型往往一个字正文都没产出 —— 但答案通常就在最后一份工具输出里。
///
/// 不产出正文就返回,等于让用户空手而归:print 模式的 stdout 是零字节,
/// 管道下游(`piz -p … | jq`)直接拿到空输入。所以把那份输出交出去,
/// 并说清它是**原始工具输出**而非模型的总结 —— 不能让用户误以为模型作过判断。
///
/// 只在 result.text 为空时填补。模型自己说了话就用它的。
fn askUserQuestion(alloc: std.mem.Allocator, args: []const u8) []const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, args, .{}) catch return "";
    if (v != .object) return "";
    const qv = v.object.get("question") orelse return "";
    if (qv != .string) return "";
    return qv.string;
}

fn salvageText(
    alloc: std.mem.Allocator,
    result: *ai.RunResult,
    tool_name: []const u8,
    output: []const u8,
    cbs: AgentCallbacks,
) void {
    if (result.text.len > 0 or output.len == 0) return;
    const text = std.fmt.allocPrint(
        alloc,
        "(模型未给出结论,以下是最后一次 {s} 的原始输出)\n\n{s}",
        .{ tool_name, output },
    ) catch return;
    result.text = text;
    if (cbs.on_text) |f| f(cbs.ctx, text) catch |err| util.debugCatch("on_text.salvage", err);
}

/// 测试入口:不带回调地跑 salvageText,只验它对 result.text 的取舍。
pub fn salvageTextForTest(
    alloc: std.mem.Allocator,
    result: *ai.RunResult,
    tool_name: []const u8,
    output: []const u8,
) void {
    salvageText(alloc, result, tool_name, output, .{});
}

pub const Agent = struct {
    alloc: std.mem.Allocator,
    cfg: *cfgmod.Config,
    provider: *const cfgmod.Provider,
    model: []const u8,
    key: ?[]const u8,
    url: []u8,
    cwd: []const u8,
    messages: std.array_list.Managed(ai.Message),
    system_prompt: []const u8,
    /// 会话标题(web UI 展示;kimi /title 式);null = 未命名
    title: ?[]const u8 = null,
    /// 最近一轮请求的真实 usage(压缩决策依据;null = 无数据)
    last_usage: ai.Usage = .{},
    est_snap: usize = 0,
    est_scale_num: usize = 1,
    est_scale_den: usize = 1,
    pkg_tools: []toolsmod.Tool = &.{},
    pkg_tools_loaded: bool = false,
    /// 成功压缩次数(状态栏 ⊞N)
    compacts: usize = 0,
    /// 只读模式:不暴露工具,工具调用一律拒绝。
    read_only: bool = false,
    /// 本 Agent 的插件启用集(位掩码)。
    ///
    /// 从前是 plugins.zig 的进程级单例。进程内并行跑多个 Agent 时那不成立:
    /// 一个 Agent 开了 skills 会让所有 Agent 都看到 skill 工具,而只读的
    /// 调研 subagent 更不该因为兄弟 agent 的设置拿到写工具。
    plugins: pluginsmod.EnabledSet = 0,
    /// 非空则只暴露这些工具名。空 = 启用集里的全部。只能收紧。
    tool_allow: []const []const u8 = &.{},
    /// 能力缝:默认本地 fs / ai.run / findToolIn。测试或沙箱可替换。
    fs: *const seams.Fs = &seams.local_fs,
    llm_run: seams.LlmRun = seams.defaultLlmRun,
    find_tool: *const fn (pluginsmod.EnabledSet, []const u8) ?*const toolsmod.Tool = pluginsmod.findToolIn,
    /// 委派深度。顶层 agent = 0,它派出的 subagent = 1。
    ///
    /// 从前只能靠 PIZ_TASK_DEPTH 环境变量跨进程传 —— 进程内 subagent 没有
    /// 新进程可继承环境,深度必须是 Agent 自己的字段。
    depth: usize = 0,
    cbs: AgentCallbacks = .{},
    /// 思考强度。TUI /think 与 Alt+,/. 改它,下一轮请求带上。
    think_level: ai.ThinkLevel = .high,
    /// 流被取消(如 Ctrl+C)
    aborted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 当前活跃 provider 流的 socket fd(-1 = 无)。
    ///
    /// 从前是 `?*httpc.Stream` 指针:interrupt 来自 HTTP 线程、Stream 活在
    /// worker 线程的栈上,send 返回后指针悬垂,读旧值再 abortRead 就是 UAF。
    /// fd 由 on_connect 存入(经 Stream.fd())、turn 结束置 -1;interrupt 线程
    /// 对它 shutdown(.recv) 打断阻塞读 —— fd 复用误伤的代价只是一次断连。
    cur_stream_fd: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),

    pub fn init(alloc: std.mem.Allocator, cfg: *cfgmod.Config, provider_name: ?[]const u8, model_name: ?[]const u8, cwd: []const u8) !Agent {
        return initOpts(alloc, cfg, provider_name, model_name, cwd, .{});
    }

    pub const InitOptions = struct {
        read_only: bool = false,
        /// 自定义系统提示(--system):替换默认提示(AGENTS.md/memory/skills 一并省略)
        system_override: ?[]const u8 = null,
        /// 插件启用集。null = 用进程默认集(CLI/web 的常规路径)。
        /// subagent 显式传:它的启用集独立于父 agent 与兄弟 agent。
        plugins: ?pluginsmod.EnabledSet = null,
        /// 委派深度。顶层 = 0;subagent 传父深度 + 1。
        depth: usize = 0,
        /// 子 agent 的工具白名单。空 = 不额外收紧。
        tool_allow: []const []const u8 = &.{},
        /// 思考等级。null = 配置默认。子 agent 传父的 think_level,才不会被配置默认打回高档。
        think_level: ?cfgmod.ThinkLevel = null,
    };

    pub fn initOpts(alloc: std.mem.Allocator, cfg: *cfgmod.Config, provider_name: ?[]const u8, model_name: ?[]const u8, cwd: []const u8, opts: InitOptions) !Agent {
        _ = pluginsmod.defaultSet();
        const resolved = try cfg.resolve(provider_name, model_name);
        const url = try cfg.endpointUrl(resolved.provider);
        const think0 = cfgmod.clampThinkLevel(
            cfgmod.metaFor(resolved.provider, resolved.model),
            opts.think_level orelse (cfg.default_think_level orelse .high),
        );
        // 启用集:调用方给了就用它,否则拷进程默认集。之后只改这个副本 ——
        // 从前 initOpts 里的 enable("skills") 改的是全局,会污染别的 Agent。
        var enabled = opts.plugins orelse pluginsmod.defaultSet();
        // 系统提示:环境 + AGENTS.md + memory.md + skills 索引
        var spw = std.Io.Writer.Allocating.init(alloc);
        defer spw.deinit();
        try spw.writer.print(
            \\You are piz, a minimal coding agent running in a terminal.
            \\You do the work directly with your tools: read, write, edit, bash.
            \\Be concise. Act, don't chat. When done, state what you did in one short line.
            \\read() prefixes each line with a line number. Never copy those prefixes into edit oldText/newText.
            \\Working directory: {s}
            \\
            \\
        , .{cwd});
        if (cfg.default_sandbox != .off) {
            try spw.writer.print(
                \\OS sandbox: bash is confined to this working directory{s}.
                \\Writes outside it via the shell will fail. Use write/edit for source files.
                \\
                \\
            , .{if (cfg.default_sandbox == .strict) " and has no network" else ""});
        }
        if (opts.read_only) {
            // 光说 "no tools" 不够:紧随其后的 "Keep going" 会推着模型
            // 自己想办法,于是它开始用**文本格式**伪造工具调用
            // (实测 deepseek 吐 `<||DSML||tool_calls>` 标记),这些原样
            // 打到 stdout,用户看到一堆标记而不是答复。必须明确禁止。
            try spw.writer.writeAll(
                \\READ-ONLY MODE: you have no tools at all. You cannot read files, run
                \\commands, or search. Answer only from the conversation and your own knowledge.
                \\Never emit tool calls in any form, including text or markup that imitates
                \\a tool call. If answering needs information you were not given, say plainly
                \\what you would need instead of pretending to look it up.
                \\
            );
        }
        // 推进准则:模型遇阻时的默认动作。没有这段它倾向于停下来问用户,
        // 而用户想要的是「自己想办法往前走」。
        try spw.writer.writeAll(
            \\# Keep going
            \\Work the problem to a finished state before you reply. When something blocks you,
            \\try another angle instead of stopping: read more of the code, check the error text,
            \\test a smaller case. Say you are stuck only after you have actually tried.
            \\A tool failure is information, not a dead end — read the message and adjust.
            \\
            \\
        );
        // 联网准则:仅在工具真的可用时才说,否则是在教模型用不存在的东西
        // (web-search 已抽离:内置表查不到时看 JS 门控侧)
        if (pluginsmod.exposesTool(enabled, opts.tool_allow, "web_search") or pluginsmod.exposesTool(enabled, opts.tool_allow, "fetch_url") or jsrt.findTool("web_search") != null) {
            try spw.writer.writeAll(
                \\# When local information runs out
                \\Your knowledge has a cutoff and this machine may not have the answer.
                \\Search the web when a question turns on a library version, a recent release,
                \\an API you are unsure about, or an error you do not recognise — then fetch_url
                \\the promising result and read it. Prefer checking over guessing.
                \\
                \\
            );
        }
        // 委派准则:同上,只在 task 工具可用时说
        if (pluginsmod.exposesTool(enabled, opts.tool_allow, "task")) {
            try spw.writer.writeAll(
                \\# Delegating
                \\Use task to farm out independent, self-contained pieces of work and run them
                \\in parallel — separate files to survey, separate questions to answer.
                \\Give each one everything it needs: it starts with no memory of this conversation.
                \\Use workflow when later steps need earlier output: name the nodes, set needs, cite {id}.
                \\Roles: scout / planner / reviewer / worker. Keep the plan and the final judgement yourself; delegate the legwork.
                \\
                \\
            );
        }
        const agents_md = util.loadAgentsMd(alloc) catch "";
        if (agents_md.len > 0) {
            try spw.writer.writeAll(agents_md);
            try spw.writer.writeByte('\n');
        }
        const memory_md = util.loadMemoryMd(alloc) catch "";
        if (memory_md.len > 0) {
            try spw.writer.writeAll("# Persistent memory (memory.md)\n");
            try spw.writer.writeAll(memory_md);
            try spw.writer.writeByte('\n');
        }
        const skills_idx = util.loadSkillsIndex(alloc) catch "";
        if (skills_idx.len > 0) {
            // 装了技能才自动开 skills 插件(暴露 skill 工具)。
            // 没装技能时暴露它是纯浪费:模型多一个永远无结果的工具。
            // 只开本 Agent 的:从前调 pluginsmod.enable 改的是进程全局,
            // 一个装了 skills 的 Agent 会让所有 Agent 都看到 skill 工具。
            if (opts.tool_allow.len == 0 or pluginsmod.exposesTool(pluginsmod.withEnabled(enabled, "skills"), opts.tool_allow, "skill")) {
                enabled = pluginsmod.withEnabled(enabled, "skills");
            }
            try spw.writer.writeAll("# Available skills (use the skill tool to load one)\n");
            try spw.writer.writeAll(skills_idx);
            try spw.writer.writeByte('\n');
        }
        // --system 覆盖:直接用自定义提示(不含 AGENTS.md/memory/skills)
        if (opts.system_override) |so| {
            var spw2 = std.Io.Writer.Allocating.init(alloc);
            defer spw2.deinit();
            try spw2.writer.writeAll(so);
            // APPEND_SYSTEM.md 仍追加
            const append_md = util.appendSystemMd(alloc, cwd) catch "";
            if (append_md.len > 0) {
                try spw2.writer.writeByte('\n');
                try spw2.writer.writeAll(append_md);
            }
            return .{
                .alloc = alloc,
                .cfg = cfg,
                .provider = resolved.provider,
                .model = resolved.model,
                .key = resolved.key,
                .url = url,
                .cwd = cwd,
                .messages = try newMsgList(alloc),
                .system_prompt = try spw2.toOwnedSlice(),
                .read_only = opts.read_only,
                .plugins = enabled,
                .tool_allow = opts.tool_allow,
                .depth = opts.depth,
                .think_level = think0,
            };
        }
        // SYSTEM.md(项目 .pi/SYSTEM.md 优先,其次全局)替换默认提示
        if (try util.systemMdPath(alloc, cwd)) |sys_path| {
            if (std.Io.Dir.cwd().readFileAlloc(util.io, sys_path, alloc, .limited(512 * 1024))) |content| {
                var spw2 = std.Io.Writer.Allocating.init(alloc);
                defer spw2.deinit();
                try spw2.writer.writeAll(content);
                const append_md = util.appendSystemMd(alloc, cwd) catch "";
                if (append_md.len > 0) {
                    try spw2.writer.writeByte('\n');
                    try spw2.writer.writeAll(append_md);
                }
                return .{
                    .alloc = alloc,
                    .cfg = cfg,
                    .provider = resolved.provider,
                    .model = resolved.model,
                    .key = resolved.key,
                    .url = url,
                    .cwd = cwd,
                    .messages = try newMsgList(alloc),
                    .system_prompt = try spw2.toOwnedSlice(),
                    .read_only = opts.read_only,
                    .plugins = enabled,
                    .tool_allow = opts.tool_allow,
                    .depth = opts.depth,
                    .think_level = think0,
                };
            } else |_| {}
        }
        // 默认提示 + APPEND_SYSTEM.md 追加
        const append_md = util.appendSystemMd(alloc, cwd) catch "";
        if (append_md.len > 0) {
            try spw.writer.writeByte('\n');
            try spw.writer.writeAll(append_md);
        }
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .provider = resolved.provider,
            .model = resolved.model,
            .key = resolved.key,
            .url = url,
            .cwd = cwd,
            .messages = try newMsgList(alloc),
            .system_prompt = try spw.toOwnedSlice(),
            .read_only = opts.read_only,
            .plugins = enabled,
            .tool_allow = opts.tool_allow,
            .depth = opts.depth,
            .think_level = think0,
        };
    }

    pub fn deinit(self: *Agent) void {
        self.messages.deinit();
    }

    /// 本 Agent 当前能调的工具。只读或白名单未列则没有。
    fn ensurePkgTools(self: *Agent) void {
        if (self.pkg_tools_loaded) return;
        self.pkg_tools_loaded = true;
        if (self.read_only) return;
        self.pkg_tools = pkgsmod.loadPkgTools(self.alloc, self.cwd) catch &.{};
    }

    pub fn lookupTool(self: *const Agent, name: []const u8) ?*const toolsmod.Tool {
        if (self.read_only) return null;
        if (pluginsmod.exposesTool(self.plugins, self.tool_allow, name)) {
            if (self.find_tool(self.plugins, name)) |t| return t;
        }
        if (self.tool_allow.len > 0) {
            var ok = false;
            for (self.tool_allow) |n| {
                if (std.mem.eql(u8, n, name)) {
                    ok = true;
                    break;
                }
            }
            if (!ok) return null;
        }
        for (self.pkg_tools) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        // JS 扩展工具:最后兜底(同名内置/插件优先)。
        if (jsrt.findTool(name)) |t| return t;
        return null;
    }

    /// 切换模型(per-session;kimi /model 式):按模型名找 provider,更新 provider/model/key/url。
    pub fn switchModel(self: *Agent, model_name: []const u8) !void {
        const p = self.cfg.findModel(model_name) orelse return error.UnknownModel;
        const resolved = try self.cfg.resolve(p.name, model_name);
        self.provider = resolved.provider;
        self.model = resolved.model;
        self.key = resolved.key;
        // url 用 page_allocator:switchModel 可能从 HTTP 线程调用(web UI),
        // 而 self.alloc(会话 arena)是 worker 线程的常驻分配器 —— 两个线程
        // 并发分配同一个 arena 会损坏它。旧 url 留在 arena 不 free,
        // 每次切换泄漏约百字节,可忽略。
        self.url = try std.heap.page_allocator.dupe(u8, try self.cfg.endpointUrl(resolved.provider));
        self.think_level = cfgmod.clampThinkLevel(self.modelMeta(), self.think_level);
    }

    /// 设置会话标题(null 清除)。
    pub fn setTitle(self: *Agent, title: ?[]const u8) void {
        self.title = title;
    }

    /// 上下文字节数(不是 token —— 要 token 用 estTokens)。
    /// 保留此函数是因为 web UI 与状态栏也要显示原始体量。
    pub fn totalChars(self: *const Agent) usize {
        var n: usize = self.system_prompt.len;
        for (self.messages.items) |m| n += m.content.len + 64;
        return n;
    }

    /// 估算上下文的 token 数。
    ///
    /// 从前各处都写 `totalChars() / 4`,即「4 字节 = 1 token」。这对英文成立,
    /// 对中文严重低估:汉字在 UTF-8 下占 3 字节,而分词器大致 1 汉字 ≈ 1 token,
    /// 所以真实消耗是 chars/3 而非 chars/4 —— 估算只有真实值的约 0.77 倍。
    ///
    /// 后果不是浪费窗口,是请求失败:128K 窗口下,`chars/4 > 85%` 这个触发条件
    /// 换算到真实 token 已是窗口的 141%,provider 早就以超窗拒绝了,compact
    /// 根本等不到触发。中文对话是本项目的常态,不是边缘情况。
    ///
    /// 现在按 UTF-8 序列长度分别计权:
    /// - 1 字节(ASCII):4 字节/token
    /// - 2 字节(拉丁扩展、希腊、西里尔):约 2 字节/token
    /// - 3 字节(CJK、日文、韩文):1 字符/token,即 3 字节/token
    /// - 4 字节(emoji、罕用字):约 1 字符/token
    ///
    /// 仍是估算,但对中英混排都不会低估到危险区间。宁可略高:高了只是早压缩一点,
    /// 低了会把请求打到 provider 那里被拒。
    ///
    /// **算的范围 = 一次请求真正发出去的全部内容**:系统提示 + 全部消息 +
    /// 工具定义。工具定义曾被漏掉,那是恒定 1024 token 的低估(默认工具集),
    /// 让压缩点从 85% 后移到 85.8%、预算查询虚报同样多的余量。
    /// 所选模型的上下文窗口:模型级配置优先,否则 provider 默认。
    /// 同 provider 下 64K/200K/1M 模型并存,压缩硬线、图片规格、
    /// 预算查询都按它 —— 不再 provider 一刀切。
    pub fn ctxWindow(self: *const Agent) usize {
        return cfgmod.windowFor(self.provider, self.model);
    }

    pub fn modelMeta(self: *const Agent) cfgmod.ModelMeta {
        return cfgmod.metaFor(self.provider, self.model);
    }

    fn llmOpts(self: *const Agent, extra: ai.Options) ai.Options {
        var o = extra;
        const meta = self.modelMeta();
        o.think_level = cfgmod.clampThinkLevel(meta, self.think_level);
        o.think_map = meta.think_map;
        o.reasoning = meta.reasoning orelse false;
        o.compat = cfgmod.resolveCompat(self.provider, self.model);
        o.thinking_budgets = self.cfg.thinking_budgets;
        o.max_output = meta.max_output;
        o.cache_retention = self.cfg.cache_retention;
        // 环境变量优先于 settings(对齐上游 PI_CACHE_RETENTION)。
        if (util.getEnv("PIZ_CACHE_RETENTION")) |s| {
            if (cfgmod.CacheRetention.parse(s)) |r| o.cache_retention = r;
        }
        return o;
    }

    pub fn hasVision(self: *const Agent) bool {
        return @import("compress.zig").hasVision(self.provider, self.model);
    }

    fn estTokensUnscaled(self: *const Agent) usize {
        var n: usize = estTokensOf(self.system_prompt);
        for (self.messages.items) |m| {
            // +16:每条消息的角色/包装开销(role、分隔符、tool_call_id 等)
            n += estTokensOf(m.content) + 16;
            // 图片消息按 provider 视觉计费规则估算(尺寸存于消息,不重复解码)
            if (m.image != null) n += imgxmod.estImageTokens(m.image_w, m.image_h, self.provider.api, @intCast(self.ctxWindow()));
        }
        // 工具定义每轮都全量重发,是上下文的一部分 —— 实测默认工具集 1024 token。
        // 漏掉它压缩就会晚触发,预算查询也会虚报余量。只读模式不发工具。
        if (!self.read_only) n += pluginsmod.toolDefsTokensFiltered(self.plugins, self.tool_allow);
        if (!self.read_only) {
            for (self.pkg_tools) |t| n += estTokensOf(t.name) + estTokensOf(t.desc) + estTokensOf(t.schema) + 8;
        }
        return n;
    }

    pub fn estTokens(self: *const Agent) usize {
        const raw = self.estTokensUnscaled();
        if (self.est_scale_den == 0) return raw;
        return raw * self.est_scale_num / self.est_scale_den;
    }

    pub fn calibrateEst(self: *Agent, actual_in: u64) void {
        if (self.est_snap == 0 or actual_in == 0) return;
        var num: usize = std.math.cast(usize, actual_in) orelse return;
        var den = self.est_snap;
        if (num > den * 2) num = den * 2;
        if (den > num * 2) den = @max(num * 2, 1);
        self.est_scale_num = @max(num, 1);
        self.est_scale_den = den;
    }

    /// 单段文本的 token 估算。按 UTF-8 序列长度分档计权。
    pub fn estTokensOf(text: []const u8) usize {
        return util.estTokensUtf8(text);
    }

    /// JS 调用方的 context 快照(context-budget 等)。数字口径与原 plugins.zig 版一致。
    pub fn jsStatsJson(self: *Agent, arena: std.mem.Allocator) []const u8 {
        const w = self.ctxWindow();
        const used = self.estTokens();
        const remain = if (used < w) w - used else 0;
        const limit = w * CTX_HARD_PERCENT / 100;
        const until_compact = if (used < limit) limit - used else 0;
        const tools_share = if (self.read_only) 0 else pluginsmod.toolDefsTokensIn(self.plugins);
        return std.json.Stringify.valueAlloc(arena, .{
            .window = w,
            .used = used,
            .tools_share = tools_share,
            .remaining = remain,
            .hard_pct = CTX_HARD_PERCENT,
            .limit = limit,
            .until_compact = until_compact,
        }, .{}) catch return "";
    }

    /// 追加用户消息并跑完一轮(含工具循环)。
    fn emitTurnEnd(self: *Agent) !void {
        pluginsmod.runAfterTurn(@ptrCast(self));
        if (self.cbs.on_turn_end) |f| try f(self.cbs.ctx);
        // JS 扩展 agent_end:最后一条 assistant 正文(可空)。scratch arena 即弃,
        // 勿用 self.alloc(长寿 arena,每回合 8KB 起步会滚雪球)。
        if (jsrt.enabled) {
            var text: []const u8 = "";
            var i = self.messages.items.len;
            while (i > 0) {
                i -= 1;
                const m = self.messages.items[i];
                if (std.mem.eql(u8, m.role, "assistant") and m.content.len > 0) {
                    text = m.content;
                    break;
                }
            }
            var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer scratch.deinit();
            const sa = scratch.allocator();
            const u = self.last_usage;
            const inp = u.input orelse 0;
            const outp = u.output orelse 0;
            const cr = u.cache_read orelse 0;
            const cw = u.cache_write orelse 0;
            jsrt.emitAgentEnd(sa, .{
                .text = text,
                .model = self.model,
                .cwd = self.cwd,
                .config_dir = util.configDir(sa) catch "",
                .ts = @intCast(@divTrunc(std.Io.Clock.now(.real, util.io).nanoseconds, std.time.ns_per_s)),
                .has_usage = u.input != null or u.output != null,
                .in = inp,
                .out = outp,
                .cr = cr,
                .cw = cw,
                .usd = if (pricing.lookupAny(self.provider.name, self.model)) |r| pricing.turnCost(r, inp, outp, cr, cw) else 0,
            });
        }
    }

    pub fn send(self: *Agent, user_text: []const u8) !ai.RunResult {
        return self.sendWithImage(user_text, null, "");
    }

    pub fn sendWithImage(self: *Agent, user_text: []const u8, image: ?[]const u8, mime_hint: []const u8) !ai.RunResult {
        const text0 = pluginsmod.runUserMessage(@ptrCast(self), user_text) orelse user_text;
        const text = if (text0.len > 0) text0 else if (image != null) "(image)" else text0;
        if (image) |raw| {
            if (raw.len > 0 and self.hasVision()) {
                const max_dim = imgxmod.maxDimForContext(@intCast(self.ctxWindow()), self.provider.api);
                if (imgxmod.process(self.alloc, raw, .{ .max_dim = max_dim })) |out| {
                    try self.messages.append(.{
                        .role = "user",
                        .content = text,
                        .image = out.data,
                        .image_mime = if (out.mime.len > 0) out.mime else mime_hint,
                        .image_w = out.w,
                        .image_h = out.h,
                        .image_file = sessionmod.persistImageFile(self.alloc, out.data, if (out.mime.len > 0) out.mime else mime_hint),
                    });
                    return self.continueTurn();
                } else |_| {}
            }
        }
        try self.messages.append(.{ .role = "user", .content = text });
        return self.continueTurn();
    }

    /// 基于现有历史继续(用于会话续载后提问)。
    pub fn continueTurn(self: *Agent) !ai.RunResult {
        // 极简核心:插件钩子(prune/shake/snap)→ 85% 硬线 → 密图折页
        pluginsmod.runBeforeTurn(@ptrCast(self));
        const w0 = self.ctxWindow();
        if (self.estTokens() > w0 * CTX_HARD_PERCENT / 100) {
            // 压缩失败不能吞:吞了下一轮就会因超窗撞 provider 400,
            // 而用户看到的报错跟真实原因(压缩失败)毫无关系,无从下手。
            //
            // 靠 `compacts` 计数判定成功与否,不解析返回字符串 ——
            // compact() 成功时返回摘要文本、失败时返回错误文本,两者都是 []const u8,
            // 只有计数是可靠的信号。
            const before = self.compacts;
            const outcome = self.compact() catch |e| @errorName(e);
            if (self.compacts == before) {
                // 没推进 = 没压缩成功。但「无事可总结」也不推进,那不是失败。
                const nothing_to_do = std.mem.startsWith(u8, outcome, "(Nothing new");
                if (!nothing_to_do) {
                    if (self.cbs.on_notice) |f| {
                        var nb: [220]u8 = undefined;
                        const msg = std.fmt.bufPrint(&nb, "auto-compaction failed ({s}) — context is over budget and the next request may be rejected; try /compact or /new", .{outcome[0..@min(outcome.len, 100)]}) catch "auto-compaction failed — context is over budget";
                        f(self.cbs.ctx, msg) catch |err| util.debugCatch("on_notice.compact", err);
                    }
                }
            }
        }
        var last_result = ai.RunResult{};
        // 断线续跑计数:一轮之内累计,不因迭代推进而重置。
        var stream_retries: usize = 0;
        // 窗况脚注每回合只在首个工具批盖一次(turn 节点)。
        var turn_footered = false;
        // 空转检测有两个判据:调用完全相同(参数级),或成功输出完全相同(结果级)。
        // 后者管得宽 —— 模型常换个写法重跑同一件事,参数每次不同、输出一模一样。
        var last_calls: []const ai.ToolCall = &.{};
        var repeat_rounds: usize = 0;
        var last_output_fp: u64 = 0;
        var same_output_count: usize = 0;
        // 最后一份成功的工具输出。止损切断时模型往往一个字正文都没产出,
        // 而答案其实就在这份输出里 —— 扣着它等于让用户空手而归
        // (print 模式下 stdout 是零字节,管道下游直接拿到空输入)。
        var last_good_output: []const u8 = "";
        var last_good_tool: []const u8 = "";
        // 已经劝过一次收尾。两个判据共用 —— 劝两次就是同一个死循环换形状。
        var nudged_once = false;
        // 模型把工具调用写成正文的重试次数。给 2 次:一次纠正通常够,
        // 再多就是这个模型在这个模式下压不住,该把实情告诉用户。
        var fake_call_retries: usize = 0;
        // 无步数帽。pi 也没有。空转由相同调用 / 相同输出两条判据收,用户 Esc 中止。
        while (true) {
            if (self.aborted.load(.acquire)) return error.Aborted;
            // 组装完整消息(system 在前)
            var all = std.array_list.Managed(ai.Message).init(self.alloc);
            defer all.deinit();
            try all.append(.{ .role = "system", .content = self.system_prompt });
            for (self.messages.items) |m| try compress.appendForRequest(&all, m);

            // 工具定义(核心 + 插件;带真 JSON Schema)
            var tool_defs = std.array_list.Managed(ai.ToolDef).init(self.alloc);
            defer tool_defs.deinit();
            self.ensurePkgTools();
            if (!self.read_only) try pluginsmod.appendToolDefsFiltered(self.plugins, self.tool_allow, &tool_defs);
            if (!self.read_only) try jsrt.appendToolDefs(self.tool_allow, &tool_defs);
            if (!self.read_only) {
                for (self.pkg_tools) |t| {
                    if (self.tool_allow.len > 0) {
                        var ok = false;
                        for (self.tool_allow) |n| {
                            if (std.mem.eql(u8, n, t.name)) {
                                ok = true;
                                break;
                            }
                        }
                        if (!ok) continue;
                    }
                    try tool_defs.append(.{ .name = t.name, .desc = t.desc, .schema = t.schema });
                }
            }

            const cbs = ai.Callbacks{
                .ctx = self.cbs.ctx,
                .on_text = self.cbs.on_text,
                .on_reasoning = self.cbs.on_reasoning,
                // 不转发 on_tool_start 给 ai 层:preflight 里已经报过一次,
                // 那里的时机才对(过了权限与插件拦截)。
                .on_abort = self.cbs.on_abort,
                .on_connect = self.cbs.on_connect,
            };
            // 可变:断流重连额度用尽时要就地填 error_msg 说明「上面这段不完整」
            self.est_snap = self.estTokensUnscaled();
            var result = try self.llm_run(
                self.alloc,
                self.alloc,
                self.provider,
                self.key,
                self.url,
                self.model,
                all.items,
                tool_defs.items,
                self.llmOpts(.{ .callbacks = cbs, .cache_key = self.cwd }),
            );
            if (result.aborted) {
                // 中断:保留已生成 partial 文本,结束本轮(不再执行工具)
                if (result.text.len > 0) {
                    try self.messages.append(.{
                        .role = "assistant",
                        .content = result.text,
                        .reasoning = if (result.reasoning.len > 0) result.reasoning else null,
                        .thinking_signature = if (result.thinking_signature.len > 0) result.thinking_signature else null,
                        .thinking_redacted = result.thinking_redacted,
                    });
                }
                self.cur_stream_fd.store(-1, .release);
                try self.emitTurnEnd();
                return error.Aborted;
            }
            last_result = result;
            if (result.usage.input != null or result.usage.output != null or result.usage.cache_read != null) {
                self.last_usage = result.usage; // 供下一轮/下次 continueTurn 决策
                if (result.usage.input) |inp| self.calibrateEst(inp);
            }
            if (result.error_msg != null) {
                return result;
            }
            if (result.tool_calls.len == 0 and result.text.len == 0) {
                result.text = try self.alloc.dupe(u8, "(empty reply — try again or /model)");
            }
            // 记录 assistant 消息
            try self.messages.append(.{
                .role = "assistant",
                .content = result.text,
                .tool_calls = if (result.tool_calls.len > 0) result.tool_calls else null,
                .reasoning = if (result.reasoning.len > 0) result.reasoning else null,
                .thinking_signature = if (result.thinking_signature.len > 0) result.thinking_signature else null,
                .thinking_redacted = result.thinking_redacted,
            });

            // 流中途断了(网络抖动,非用户中止)。partial 已经存进历史,
            // 现在自动续跑一轮让模型接着说完 —— 这是「能自愈」最直接的一条:
            // 原先这里整轮失败,用户看着半句话愣住,得自己再问一遍。
            //
            // 上限 2 次:再多就是链路真的坏了,继续重连只是把同一个错误
            // 重复三遍。计数不重置 —— 一轮之内累计。
            if (result.stream_interrupted) |why| {
                if (stream_retries < MAX_STREAM_RESUMES) {
                    stream_retries += 1;
                    if (self.cbs.on_notice) |f| {
                        var nb: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&nb, "connection dropped mid-reply ({s}) — resuming ({d}/{d})", .{ why, stream_retries, MAX_STREAM_RESUMES }) catch "connection dropped — resuming";
                        f(self.cbs.ctx, msg) catch |err| util.debugCatch("on_notice.resume", err);
                    }
                    try self.messages.append(.{
                        .role = "user",
                        .content = "(Your previous reply was cut off by a network interruption. Continue from exactly where it stopped. Do not repeat what you already said, do not apologize, do not restart.)",
                    });
                    continue;
                }
                // 重连额度用尽:把已有内容交出去,并说明它不完整
                result.error_msg = try std.fmt.allocPrint(self.alloc, "connection kept dropping mid-reply ({s}); the reply above is incomplete", .{why});
                try self.emitTurnEnd();
                return result;
            }

            // 文本形式的工具调用:模型没走 tool_calls 字段,而是把调用当正文吐出来
            // (deepseek 漏 `<||DSML||...>` 特殊标记,｜是 U+FF5C 全角竖线)。
            //
            // 只读模式最容易触发 —— 一个工具定义都没发,模型又被要求"想办法
            // 往前走",于是自己造一套格式。这些标记原样打到 stdout,用户看到
            // 一堆标记而不是答复。加强 system prompt 完全无效(实测 3/3 仍漏),
            // 因为格式是模型训练里烧进去的。
            //
            // 处理方式和空转检测一致:告诉它这不算调用,让它重答一次。
            if (result.tool_calls.len == 0 and textToolCallMarker(result.text) != null) {
                if (fake_call_retries < MAX_FAKE_CALL_RETRIES) {
                    fake_call_retries += 1;
                    if (self.cbs.on_notice) |f| {
                        var nb: [160]u8 = undefined;
                        const msg = std.fmt.bufPrint(&nb, "the model wrote a tool call as text instead of calling a tool — asking it to answer directly ({d}/{d})", .{ fake_call_retries, MAX_FAKE_CALL_RETRIES }) catch "the model faked a tool call as text — retrying";
                        f(self.cbs.ctx, msg) catch |err| util.debugCatch("on_notice.fake_call", err);
                    }
                    try self.messages.append(.{
                        .role = "user",
                        .content = if (self.read_only)
                            "(That was not a tool call — it printed as literal text. You have no tools in this mode. Answer directly from what you already know, or say what information you would need.)"
                        else
                            "(That was not a tool call — it printed as literal text. Use the real tool-calling interface, or answer directly.)",
                    });
                    continue;
                }
                // 额度用尽:标记清楚,不要把标记当答复交出去
                result.error_msg = "the model kept writing tool calls as text instead of calling tools; the reply above is not usable";
                try self.emitTurnEnd();
                return result;
            }
            if (result.tool_calls.len == 0) {
                try self.emitTurnEnd();
                return result;
            }

            // 空转检测:模型反复发同一批工具调用。
            //
            // 实测某些模型拿到工具结果后不收尾,原样重发同一个调用,
            // 把一轮全烧在一条 `echo hi` 上 —— 请求体、tool_call_id、结果回传
            // 全都正确,是模型侧行为。piz 拦不住它想调什么,但可以在结果里
            // 直说「你在重复」,并在连续多轮后停下。
            const same_as_last = sameToolCalls(last_calls, result.tool_calls);
            if (same_as_last) {
                repeat_rounds += 1;
            } else {
                repeat_rounds = 0;
            }
            last_calls = result.tool_calls;
            if (repeat_rounds >= MAX_REPEAT_ROUNDS) {
                if (!nudged_once) {
                    // 第一次:劝它收尾。模型往往只是没意识到结果已经拿到了。
                    nudged_once = true;
                    if (self.cbs.on_notice) |f| {
                        var nb: [200]u8 = undefined;
                        const msg = std.fmt.bufPrint(&nb, "the model called {s} with identical arguments {d} times — telling it to use the result it already has", .{ result.tool_calls[0].name, repeat_rounds + 1 }) catch "the model kept repeating one tool call — nudging it to answer";
                        f(self.cbs.ctx, msg) catch |err| util.debugCatch("on_notice.repeat", err);
                    }
                    try self.messages.append(.{
                        .role = "user",
                        .content = "(You have called the same tool with the same arguments several times and the result has not changed. Stop calling tools. Answer now using the results already above.)",
                    });
                    repeat_rounds = 0;
                    last_calls = &.{};
                    continue;
                }
                // 劝过还在重复:这是死循环换了个形状,停下并把已有内容交出去。
                if (self.cbs.on_notice) |f| {
                    var nb: [220]u8 = undefined;
                    const msg = std.fmt.bufPrint(&nb, "stopped: the model kept repeating {s} even after being told to stop — the tool results above are correct, the model is not using them", .{result.tool_calls[0].name}) catch "stopped: the model would not stop repeating one tool call";
                    f(self.cbs.ctx, msg) catch |err| util.debugCatch("on_notice.repeat_stop", err);
                }
                salvageText(self.alloc, &result, last_good_tool, last_good_output, self.cbs);
                try self.emitTurnEnd();
                return result;
            }

            // 执行工具
            // ---- 工具执行:串行 preflight(权限/拦截)→ 并行执行 → 按原序写回 ----
            // 顺序保证:模型看到的 tool 结果顺序必须与它发出的 tool_calls 顺序一致,
            // 否则同一对话重放会得到不同上下文。故并行只作用于执行阶段。
            const n = result.tool_calls.len;
            const slots = try self.alloc.alloc(ToolSlot, n);
            defer self.alloc.free(slots);

            // 阶段一:串行 preflight。权限询问要跟用户交互,并行弹多个提示会灾难;
            // 插件前置拦截也在此串行跑(它可能读写 Agent 状态)。
            for (result.tool_calls, 0..) |tc, i| {
                slots[i] = .{ .call = tc, .agent = self };
                if (self.cbs.on_tool_start) |f| {
                    _ = f(self.cbs.ctx, tc.name, tc.args) catch |err| util.debugCatch("on_tool_start", err);
                }
                if (self.cbs.on_require_permission) |perm| {
                    const allowed = perm(self.cbs.ctx, tc.name, tc.args) catch true;
                    if (!allowed) {
                        slots[i].done = true;
                        slots[i].result = .{
                            .content = "error: user declined permission for this tool call — do not retry it, adjust your approach or answer directly.",
                            .is_error = true,
                        };
                        continue;
                    }
                }
                const tool = self.lookupTool(tc.name);
                if (tool == null) {
                    slots[i].done = true;
                    slots[i].result = if (self.read_only) .{
                        .content = "error: read-only mode — tool calls are disabled. Answer without modifying anything.",
                        .is_error = true,
                    } else .{
                        .content = try std.fmt.allocPrint(self.alloc, "error: unknown tool '{s}'. Available: read, write, edit, multi_edit, bash, grep, find, ls, skill", .{tc.name}),
                        .is_error = true,
                    };
                    continue;
                }
                if (pluginsmod.runToolBefore(@ptrCast(self), tc.name, tc.args)) |block_msg| {
                    slots[i].done = true;
                    slots[i].result = .{ .content = block_msg, .is_error = true };
                    continue;
                }
                slots[i].tool = tool;
            }

            // 阶段二:并行执行未定案的工具。
            //
            // 全部一次性 spawn,用信号量把同时在跑的数量压在 MAX_PARALLEL_TOOLS。
            // 相比「8 个一批、join 完再开下一批」,这里没有批边界 —— 任一线程结束
            // 立刻放行下一个,慢工具不再拖住后面所有人。
            var sem: std.Io.Semaphore = .{ .permits = MAX_PARALLEL_TOOLS };
            const threads = try self.alloc.alloc(?std.Thread, n);
            defer self.alloc.free(threads);
            @memset(threads, null);
            for (0..n) |i| {
                if (slots[i].done) continue;
                threads[i] = std.Thread.spawn(.{}, runToolSlotGated, .{ &slots[i], &sem }) catch {
                    // spawn 失败:就地同步跑,不因线程耗尽丢工具调用。
                    // 不过信号量 —— 同步执行本身就是最强的限流。
                    runToolSlot(&slots[i]);
                    continue;
                };
            }
            for (threads) |maybe_th| {
                if (maybe_th) |th| th.join();
            }

            // 阶段三:按原序回调 + 写回历史。此处单线程,插件后处理与 messages 追加都安全。
            for (slots) |*slot| {
                var tres = slot.result;
                if (!tres.is_error and slot.tool != null) {
                    if (pluginsmod.runToolAfter(@ptrCast(self), slot.call.name, tres.content)) |new_content| {
                        tres.content = new_content;
                    }
                }
                // 入境定形:大结果进门即裁(密图+摘录 / 仅摘录),此后永不改。
                // 已送前缀不动,prompt cache 前缀才稳;回溯裁旧消息会整段炸 cache。
                var content = tres.content;
                var snap_image: ?[]const u8 = null;
                var snap_w: u32 = 0;
                var snap_h: u32 = 0;
                var shaped = false;
                if (!tres.is_error) {
                    const ing = compress.shapeIngress(self.alloc, content, .{
                        .vision = self.hasVision(),
                        .api = self.provider.api,
                        .tool_name = slot.call.name,
                        .window = self.ctxWindow(),
                    }) catch compress.Ingress{ .text = content };
                    if (ing.changed) {
                        content = ing.text;
                        snap_image = ing.image;
                        snap_w = ing.width;
                        snap_h = ing.height;
                        shaped = true;
                        if (ing.tokens_saved > 0) {
                            if (self.cbs.on_notice) |f| {
                                var nb: [96]u8 = undefined;
                                const msg = std.fmt.bufPrint(&nb, "fast-compress: ingress snap −{d} tok", .{ing.tokens_saved}) catch "fast-compress: ingress snap";
                                f(self.cbs.ctx, msg) catch |err| util.debugCatch("on_notice.ingress", err);
                            }
                        }
                    }
                }
                // 输出指纹:同一份成功输出被反复拿到,说明模型没在用它。
                // 只看成功的 —— 错误反复相同是模型在试错,用户 Esc 可停。
                // 指纹打在定稿文本上(不含脚注,脚注带水位每轮都变)。
                if (!tres.is_error) {
                    const fp = outputFingerprint(slot.call.name, content);
                    if (fp == last_output_fp) {
                        same_output_count += 1;
                    } else {
                        last_output_fp = fp;
                        same_output_count = 1;
                    }
                    // content 挂在本轮 arena 上,活到 send() 返回,够止损时引用。
                    last_good_output = content;
                    last_good_tool = slot.call.name;
                }
                // 窗况脚注:只在任务节点盖(回合首个工具批/入境定形/硬线),不条条都盖。
                {
                    const w = self.ctxWindow();
                    const used = self.estTokens();
                    const pct = if (w > 0) used * 100 / w else 0;
                    const node: ?compress.TaskNode = if (pct >= CTX_HARD_PERCENT)
                        .hard
                    else if (shaped)
                        .ingress
                    else if (!turn_footered)
                        .turn
                    else
                        null;
                    if (node) |nd| {
                        if (nd == .turn) turn_footered = true;
                        const foot = compress.usageFooter(self.alloc, pct, used, w, nd) catch "";
                        if (foot.len > 0) content = std.fmt.allocPrint(self.alloc, "{s}{s}", .{ content, foot }) catch content;
                    }
                }
                if (self.cbs.on_tool_end) |f| {
                    // 全量 content 给回调(web diff 卡/JSONL 需要完整输出;各调用方自行截断)
                    _ = f(self.cbs.ctx, slot.call.name, tres.is_error, content) catch |err| util.debugCatch("on_tool_end", err);
                }
                try self.messages.append(.{
                    .role = "tool",
                    .content = content,
                    .tool_call_id = slot.call.id,
                });
                // 入境密图与工具产出图片一样挂成 user 消息(协议:image block 只能在
                // user/assistant 消息上;tool 消息是纯文本)。
                if (snap_image) |img| {
                    if (self.hasVision()) {
                        try self.messages.append(.{
                            .role = "user",
                            .content = "[Snapcompact frame — dense pixel text of the shaped tool output]",
                            .image = img,
                            .image_mime = "image/png",
                            .image_w = snap_w,
                            .image_h = snap_h,
                            .image_file = sessionmod.persistImageFile(self.alloc, img, "image/png"),
                        });
                    }
                }
                // 工具产出的图片附件挂成 user 消息(协议:image block 只能在
                // user/assistant 消息上;tool 消息是纯文本)。data 由工具 dupe
                // 到会话 arena,这里只引指针,安全。
                if (tres.images) |imgs| {
                    if (!self.hasVision()) continue;
                    for (imgs) |im| {
                        try self.messages.append(.{
                            .role = "user",
                            .content = im.note,
                            .image = im.data,
                            .image_mime = im.mime,
                            .image_w = im.w,
                            .image_h = im.h,
                            .image_file = sessionmod.persistImageFile(self.alloc, im.data, im.mime),
                        });
                    }
                }
            }
            // ask_user 是真停:工具已回执,不再把问题送回模型让它「自行决定」。
            // 用户下一条消息才是答案。
            var asked_user = false;
            var asked_q: []const u8 = "";
            for (slots) |slot| {
                if (!slot.result.is_error and std.mem.eql(u8, slot.call.name, "ask_user")) {
                    asked_user = true;
                    asked_q = askUserQuestion(self.alloc, slot.call.args);
                    break;
                }
            }
            if (asked_user) {
                if (self.cbs.on_notice) |f| {
                    f(self.cbs.ctx, "ask_user: waiting for your next message") catch |err| util.debugCatch("on_notice.ask_user", err);
                }
                if (result.text.len == 0) {
                    result.text = if (asked_q.len > 0)
                        try std.fmt.allocPrint(self.alloc, "{s}", .{asked_q})
                    else
                        try self.alloc.dupe(u8, "Waiting for your answer.");
                }
                try self.emitTurnEnd();
                return result;
            }
            // 工具批次结束后跑一次 before_turn 钩子(它会改 messages,不能在并行区跑)
            pluginsmod.runBeforeTurn(@ptrCast(self));
            // 会话可在此落盘,但 after_turn 只在整轮结束时跑,免得用量记两遍。
            if (self.cbs.on_turn_end) |f| try f(self.cbs.ctx);

            // 输出空转:同一份成功输出被拿到第 MAX_SAME_OUTPUT 次。
            // 比参数比对管得宽 —— 模型常把命令换个写法再跑,参数每次不同、
            // 输出一模一样。这时它需要的是「停下来用结果」而不是再试一种写法。
            if (same_output_count >= MAX_SAME_OUTPUT) {
                same_output_count = 0;
                if (!nudged_once) {
                    nudged_once = true;
                    if (self.cbs.on_notice) |f| {
                        f(self.cbs.ctx, "the same tool output came back 3 times — telling the model to answer from what it has") catch |err| util.debugCatch("on_notice.same_output", err);
                    }
                    try self.messages.append(.{
                        .role = "user",
                        .content = "(You have run different variants of the same command and received identical output every time. The output above is the answer. Stop calling tools and reply now.)",
                    });
                    continue;
                }
                if (self.cbs.on_notice) |f| {
                    f(self.cbs.ctx, "stopped: the model kept re-running commands that return the same output — the results above are correct") catch |err| util.debugCatch("on_notice.same_output_stop", err);
                }
                salvageText(self.alloc, &last_result, last_good_tool, last_good_output, self.cbs);
                try self.emitTurnEnd();
                return last_result;
            }
        }
    }

    /// 撤销最近一轮:删除最后一条 user 消息及其后所有消息。
    /// 返回是否有可撤销内容。
    pub fn undo(self: *Agent) bool {
        var idx: ?usize = null;
        var i = self.messages.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.messages.items[i].role, "user")) {
                idx = i;
                break;
            }
        }
        const at = idx orelse return false;
        self.messages.shrinkRetainingCapacity(at);
        return true;
    }

    /// 压缩历史:密图 + 摘录替换被裁段,不调模型。
    pub fn compact(self: *Agent) ![]const u8 {
        // 折页切点(不调模型):
        // - 只折上次压缩后的增量(boundary = 最后一个旧摘要之后)
        // - 增量 ≤ 保留预算(20% 窗口)则全保留
        // - 切点只落在 user/assistant,不切断 tool 对
        const w = self.ctxWindow();
        // 保留预算按 token 算,不再是「token × 4 当字节」—— 后者对中文会把
        // 20% 的窗口预算缩成实际约 15%,压缩后保留的上下文比设计的少。
        const keep_tokens = w * CTX_KEEP_PERCENT / 100;
        var boundary: usize = 0;
        for (self.messages.items, 0..) |m, idx| {
            if (std.mem.startsWith(u8, m.content, "(Conversation compacted")) boundary = idx + 1;
        }
        var cut: usize = boundary; // 首个保留消息索引
        var acc: usize = 0;
        var over = false;
        var j = self.messages.items.len;
        while (j > boundary) {
            j -= 1;
            acc += estTokensOf(self.messages.items[j].content) + 16;
            if (acc > keep_tokens) {
                over = true;
                break;
            }
            if (std.mem.eql(u8, self.messages.items[j].role, "user") or std.mem.eql(u8, self.messages.items[j].role, "assistant")) cut = j;
        }
        if (!over) cut = boundary; // 增量在预算内:全保留
        // 增量全保留(无可总结的新内容):不调模型——真"秒"路径(对齐 omp "No prior history.")
        var has_content = false;
        for (self.messages.items[0..cut]) |m| {
            if (!std.mem.startsWith(u8, m.content, "(Conversation compacted")) {
                has_content = true;
                break;
            }
        }
        if (!has_content) return "(Nothing new to summarize; recent context already kept.)";

        const fold = try compress.compactHistory(self.alloc, self.messages.items[0..cut], self.provider.api, self.hasVision());
        self.compacts += 1;
        var keep = std.array_list.Managed(ai.Message).init(self.alloc);
        defer keep.deinit();
        for (self.messages.items[cut..]) |m| {
            if (std.mem.startsWith(u8, m.content, "(Conversation compacted")) continue;
            try keep.append(m);
        }
        self.messages.clearRetainingCapacity();
        try self.messages.append(.{
            .role = "system",
            .content = try std.fmt.allocPrint(self.alloc, "(Conversation compacted. Summary:)\n{s}", .{fold.summary}),
        });
        if (fold.image) |img| {
            try self.messages.append(.{
                .role = "user",
                .content = "[Snapcompact frame]",
                .image = img,
                .image_mime = "image/png",
                .image_w = fold.width,
                .image_h = fold.height,
                .image_file = sessionmod.persistImageFile(self.alloc, img, "image/png"),
            });
        }
        try self.messages.appendSlice(keep.items);
        pluginsmod.runAfterCompact(@ptrCast(self), fold.summary);
        // JS 扩展 compact 事件(跨会话记忆/概念图已抽为内嵌件)
        if (jsrt.enabled) {
            var ca = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer ca.deinit();
            jsrt.emitCompact(ca.allocator(), fold.summary, self.cwd);
        }
        return fold.summary;
    }
};

test {
    // 单测主体在 agent_tests.zig(原净尾 617 行);引回以保持 zig test 收集。
    _ = @import("agent_tests.zig");
}
