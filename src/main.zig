// main.zig — piz 入口:CLI 解析、交互模式(线程编排)、会话挂载。print/web/pkg 见 cmd_*.zig。
const std = @import("std");
const util = @import("core").util;
const jsrt = @import("core").jsrt;
const activity = @import("core").activity;
const cfgmod = @import("core").config;
const sandboxmod = @import("core").sandbox;
const httpc = @import("core").httpc;
const ai = @import("core").ai;
const agentmod = @import("core").agent;
const sessionmod = @import("core").session;
const toolsmod = @import("core").tools;
const mcpmod = @import("core").mcp;
const eventsmod = @import("core").events;
const pluginsmod = @import("core").plugins;
const pkgsmod = @import("core").pkgs;
const compress = @import("core").compress;
const tui_mod = @import("tui");
const pricing = @import("core").pricing;
const webui_mod = @import("webui.zig");
const cmd_web = @import("cmd_web.zig");
const cmd_print = @import("cmd_print.zig");
const cmd_pkg = @import("cmd_pkg.zig");
const cmd_login = @import("cmd_login.zig");
const cmd_help = @import("cmd_help.zig");
const cmd_doctor = @import("cmd_doctor.zig");
const cmd_init = @import("cmd_init.zig");
const cmd_diff = @import("cmd_diff.zig");
const cmd_commit = @import("cmd_commit.zig");
const cmd_slash = @import("cmd_slash.zig");
const app_pickers = @import("app_pickers.zig");
const app_views = @import("app_views.zig");
const app_worker = @import("app_worker.zig");
const runopts = @import("runopts.zig");

pub const VERSION = "0.1.0";

const StatusRow = struct {
    version: []const u8,
    model: []const u8,
    think: []const u8,
    cwd: []const u8,
    session: []const u8,
    perms: []const u8,
    context: []const u8,
    usage: []const u8,
};

fn formatStatusCard(alloc: std.mem.Allocator, row: StatusRow, width: usize) ![]u8 {
    return tui_mod.formatStatusCard(alloc, .{
        .version = row.version,
        .model = row.model,
        .think = row.think,
        .cwd = row.cwd,
        .session = row.session,
        .perms = row.perms,
        .context = row.context,
        .usage = row.usage,
    }, width);
}

const welcomeNote = cmd_help.welcomeNote;
const tildePath = cmd_help.tildePath;
const welcomeContext = cmd_help.welcomeContext;

const HELP = cmd_help.USAGE;

const HelpItem = cmd_help.HelpItem;
const SLASH_ITEMS = cmd_help.SLASH_ITEMS;
const formatHelp = cmd_help.formatHelp;

// ---------- 交互模式 ----------

const ModelSyncItem = struct { prov: *cfgmod.Provider, found: []cfgmod.Discovered };

pub const App = struct {
    alloc: std.mem.Allocator,
    tui: *tui_mod.Tui,
    agent: *agentmod.Agent,
    sess: *sessionmod.Session,
    cfg: *cfgmod.Config,
    events: *eventsmod.Bus,
    slash_names: [32][48]u8 = undefined,
    slash_extra: [32]tui_mod.SlashItem = undefined,
    slash_extra_n: usize = 0,
    slash_merged: [96]tui_mod.SlashItem = undefined,
    slash_merged_n: usize = 0,
    quit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    abort: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker: ?std.Thread = null,
    model_override: ?[]const u8 = null,
    provider_override: ?[]const u8 = null,
    read_only: bool = false,
    /// 当前授权档。默认 yolo;Ask 才弹 TUI 确认。
    approval: cfgmod.ApprovalMode = .yolo,
    /// 权限状态:worker 询问,主循环应答。
    perm: struct {
        pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// 0=等待 1=允许 2=拒绝
        decision: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
        /// 提示文案缓冲(worker 构建,主循环只读,请求期间常驻)
        buf: std.array_list.Managed(u8),
        /// 提示 slice 快照(TUI 原子指针指向此处)
        slice: []const u8 = "",
        /// 本会话已选 always:后续工具不再询问
        always: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    },
    /// 上一条普通消息(/redo 用)
    last_line: []const u8 = "",
    /// steering 队列:worker 忙时提交的消息排队,轮次间自动投递
    queue: std.array_list.Managed([]const u8),
    queue_mutex: std.Io.Mutex = .init,
    /// worker 存活标志(主线程提交时判断是否排队)
    worker_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_usage: ai.Usage = .{},
    /// 会话累计 token(状态栏 t/s)
    tokens_total: usize = 0,
    /// 会话分项累计(页脚 pi 式 ↑↓ R W):入/出/缓存写
    tok_in: u64 = 0,
    tok_out: u64 = 0,
    tok_cache_w: u64 = 0,
    tok_cache_r: u64 = 0,
    /// 会话累计费用(USD,价目命中才累加;未知模型恒 0 不显)
    cost_usd: f64 = 0,
    git_brief: cmd_diff.Brief = .{},
    git_brief_ms: i64 = 0,
    /// worker 每轮结束发布的上下文 token 估算(主线程状态栏读它)。
    ///
    /// 主线程不能现场调 estTokens:那会遍历 messages,而 worker 正在 append
    /// (std 的 append 先加 len 后写数据,读侧撞上半写消息会 segfault ——
    /// web 侧实测过同一机制)。worker 与主线程只经这个原子交换。
    est_ctx: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// 启动模型表同步:bg 线程纯取(cfgmod.fetchDiscovered,独立 arena——
    /// app.alloc 非线程安全),主线程 on_paint 合账。同 worker 隔离律。
    models_sync: struct {
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        mu: std.Io.Mutex = .init,
        arena: ?*util.Arena = null,
        items: []ModelSyncItem = &.{},
        fail: usize = 0,
    } = .{},
    /// 会话起始时刻(ns,状态栏 t/s)
    start_ns: i128,

    /// 队列消息入队(主线程调用)。失败须告诉用户,否则排队消息会无声消失。
    pub fn enqueue(self: *App, line: []const u8) bool {
        self.queue_mutex.lock(util.io) catch |err| {
            util.debugCatch("queue.lock", err);
            return false;
        };
        defer self.queue_mutex.unlock(util.io);
        const copy = self.alloc.dupe(u8, line) catch return false;
        self.queue.append(copy) catch {
            self.alloc.free(copy);
            return false;
        };
        return true;
    }

    /// 取队首消息(worker 调用);空返回 null。
    pub fn dequeue(self: *App) ?[]const u8 {
        self.queue_mutex.lock(util.io) catch |err| {
            util.debugCatch("queue.deq", err);
            return null;
        };
        defer self.queue_mutex.unlock(util.io);
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    /// 清空队列。
    pub fn clearQueue(self: *App) void {
        self.queue_mutex.lock(util.io) catch |err| {
            util.debugCatch("queue.clear", err);
            return;
        };
        defer self.queue_mutex.unlock(util.io);
        for (self.queue.items) |q| self.alloc.free(q);
        self.queue.clearRetainingCapacity();
    }

    pub fn fmtTok(buf: *[16]u8, n: u64) []const u8 {
        if (n >= 1_000_000) {
            const m = n / 1_000_000;
            const frac = (n % 1_000_000) / 100_000;
            if (frac == 0) return std.fmt.bufPrint(buf, "{d}M", .{m}) catch "?";
            return std.fmt.bufPrint(buf, "{d}.{d}M", .{ m, frac }) catch "?";
        }
        if (n >= 1000) return std.fmt.bufPrint(buf, "{d}k", .{n / 1000}) catch "?";
        return std.fmt.bufPrint(buf, "{d}", .{n}) catch "?";
    }

    /// 页脚身份:模型 / 思考档 / 占用 / 缓存 / 目录 / 会话。开场不再画卡片。
    /// Occupancy is `est_ctx / ctxWindow`. Cache is last-turn API usage
    /// (`ai.Usage.cache_read` / `input`) — null stays `cache —`, never faked.
    pub fn refreshFooter(self: *App) void {
        const cwd = tildePath(self.alloc, self.agent.cwd) catch return;
        defer self.alloc.free(cwd);
        const cw = self.agent.ctxWindow();
        const used = self.est_ctx.load(.acquire);
        const pct = if (cw > 0) used * 100 / cw else 0;
        const u = if (self.agent.last_usage.input != null or self.agent.last_usage.cache_read != null)
            self.agent.last_usage
        else
            self.last_usage;
        const br = self.gitBranch();
        defer if (br) |b| self.alloc.free(b);
        var br_label_buf: [160]u8 = undefined;
        const br_label = cmd_diff.formatBranchLabel(&br_label_buf, br orelse "", self.gitBriefCached());
        var model_buf: [96]u8 = undefined;
        self.tui.setFooterIdentity(.{
            .model = self.modelLabel(&model_buf),
            .think = tui_mod.thinkLabel(self.tui.think_level),
            .cwd = cwd,
            .branch = br_label,
            .tok_in = self.tok_in,
            .tok_out = self.tok_out,
            .tok_cache_w = self.tok_cache_w,
            .tok_cache_r = self.tok_cache_r,
            .cost = if (self.cost_usd > 0) self.cost_usd else null,
            .subscription = cfgmod.providerIsSub(self.agent.provider),
            .session = if (self.sess.title) |t| (if (t.len > 0) t else self.sess.sessionId()) else self.sess.sessionId(),
            .used = used,
            .window = cw,
            .cache_read = u.cache_read,
            .prompt = u.input,
            .pct = pct,
            .hot = pct > 85,
            .sandbox = if (self.cfg.default_sandbox != .off)
                (sandboxmod.describe(self.alloc, self.cfg.default_sandbox) catch self.cfg.default_sandbox.label())
            else
                "",
        }) catch |err| util.debugCatch("footer.ident", err);
    }

    pub fn modelLabel(self: *App, buf: *[96]u8) []const u8 {
        var model_seg: []const u8 = self.agent.model;
        if (std.mem.indexOfScalar(u8, model_seg, '-')) |dash| model_seg = model_seg[dash + 1 ..];
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.agent.provider.name, model_seg }) catch self.agent.model;
    }

    pub fn permsLabel(self: *const App) []const u8 {
        const a = switch (self.approval) {
            .yolo => "yolo",
            .ask => "ask",
            .read_only => "read-only",
        };
        const sb = sandboxmod.describe(self.alloc, self.cfg.default_sandbox) catch self.cfg.default_sandbox.label();
        return std.fmt.allocPrint(self.alloc, "{s} · sandbox {s}", .{ a, sb }) catch a;
    }

    /// 读 .git/HEAD 取分支名(极简,无子进程)。
    fn gitBranch(self: *App) ?[]u8 {
        return cmd_diff.currentBranch(self.alloc, self.agent.cwd);
    }

    fn gitBriefCached(self: *App) cmd_diff.Brief {
        const now: i64 = @intCast(@divTrunc(std.Io.Clock.now(.real, util.io).nanoseconds, std.time.ns_per_ms));
        if (self.git_brief_ms != 0 and now - self.git_brief_ms < 2000)
            return self.git_brief;
        self.git_brief = cmd_diff.statusBrief(self.alloc, self.agent.cwd) orelse .{};
        self.git_brief_ms = now;
        return self.git_brief;
    }

    pub fn switchModel(self: *App, spec: []const u8) !void {
        // 支持 provider/model 与 model 两种写法
        const ro = self.read_only;
        if (std.mem.indexOfScalar(u8, spec, '/')) |slash| {
            const p = spec[0..slash];
            const m = spec[slash + 1 ..];
            const agent = try agentmod.Agent.initOpts(self.alloc, self.cfg, p, m, self.agent.cwd, .{ .read_only = ro, .depth = self.agent.depth, .plugins = self.agent.plugins });
            self.agent.deinit();
            self.agent.* = agent;
            self.provider_override = p;
            self.model_override = m;
        } else {
            const agent = try agentmod.Agent.initOpts(self.alloc, self.cfg, self.provider_override, spec, self.agent.cwd, .{ .read_only = ro, .depth = self.agent.depth, .plugins = self.agent.plugins });
            self.agent.deinit();
            self.agent.* = agent;
            self.model_override = spec;
        }
        syncThink(self);
    }

    fn syncThink(self: *App) void {
        const meta = self.agent.modelMeta();
        self.tui.think_meta = meta;
        self.tui.think_level = cfgmod.clampThinkLevel(meta, self.tui.think_level);
        self.agent.think_level = self.tui.think_level;
    }

    /// 切换会话:载入消息并替换 app.sess。
    pub fn loadSession(self: *App, sess: sessionmod.Session) !void {
        var s = sess;
        const loaded = try s.loadMessages();
        self.agent.messages.clearRetainingCapacity();
        try self.agent.messages.appendSlice(loaded);
        self.sess.deinit();
        self.sess.* = sess;
    }
};

pub fn rebuildSlashCatalog(app: *App) void {
    var n: usize = 0;
    for (SLASH_ITEMS) |it| {
        if (n >= app.slash_merged.len) break;
        app.slash_merged[n] = it;
        n += 1;
    }
    var plug: [32]pluginsmod.SlashCommand = undefined;
    const pn = pluginsmod.collectSlash(app.agent.plugins, &plug);
    app.slash_extra_n = 0;
    for (plug[0..pn]) |sc| {
        if (n >= app.slash_merged.len or app.slash_extra_n >= app.slash_extra.len) break;
        const labeled = if (sc.name.len > 0 and sc.name[0] == '/') sc.name else (std.fmt.bufPrint(&app.slash_names[app.slash_extra_n], "/{s}", .{sc.name}) catch continue);
        const item = tui_mod.SlashItem{ .cmd = labeled, .desc = sc.desc };
        app.slash_extra[app.slash_extra_n] = item;
        app.slash_extra_n += 1;
        app.slash_merged[n] = item;
        n += 1;
    }
    app.slash_merged_n = n;
    app.tui.slash_items = app.slash_merged[0..n];
}

// 只读视图群已拆 app_views.zig(评审 P2);再导出保调用点/测试零改。
pub const showWelcome = app_views.showWelcome;
pub const replaceSession = app_views.replaceSession;
pub const showStatusCard = app_views.showStatusCard;
pub const showDoctor = app_views.showDoctor;
pub const replayTranscript = app_views.replayTranscript;
pub const redoLast = app_views.redoLast;
pub const showDiff = app_views.showDiff;
pub const showLog = app_views.showLog;
pub const showJobs = app_views.showJobs;
pub const showUsage = app_views.showUsage;
pub const copyLastReply = app_views.copyLastReply;
pub const copyToClipboard = app_views.copyToClipboard;

// 选择器群已拆 app_pickers.zig(评审 P2);再导出保调用点零改。
pub const persistTheme = app_pickers.persistTheme;
pub const openThemePicker = app_pickers.openThemePicker;
pub const persistThink = app_pickers.persistThink;
pub const applyApproval = app_pickers.applyApproval;
pub const applySandbox = app_pickers.applySandbox;
pub const openSandboxPicker = app_pickers.openSandboxPicker;
pub const openApprovalPicker = app_pickers.openApprovalPicker;
pub const openThinkPicker = app_pickers.openThinkPicker;
pub const refreshProviderModels = app_pickers.refreshProviderModels;
pub const openModelPicker = app_pickers.openModelPicker;
pub const openResumePicker = app_pickers.openResumePicker;

pub fn tuiOk(comptime where: []const u8, result: anyerror!void) void {
    result catch |err| util.debugCatch(where, err);
}

pub fn tuiNote(app: *App, color: []const u8, text: []const u8) void {
    tuiOk("tui.note", app.tui.appendLine("", color, text));
}

pub fn tuiNotes(app: *App, color: []const u8, text: []const u8) void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, text, "\n"), '\n');
    while (it.next()) |ln| tuiNote(app, color, ln);
}

fn tuiOnText(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    tuiOk("stream.text", app.tui.appendText(text));
    if (app.abort.load(.acquire)) return error.Aborted;
}

fn tuiOnReasoning(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    tuiOk("stream.think", app.tui.appendThink(text));
    if (app.abort.load(.acquire)) return error.Aborted;
}

/// 工具参数预览:优先抽出 command / path / pattern,别整段 JSON 糊在一行上。
pub fn toolArgsPreview(args: []const u8) []const u8 {
    const keys = [_][]const u8{ "\"command\":\"", "\"pattern\":\"", "\"query\":\"", "\"path\":\"", "\"goal\":\"" };
    for (keys) |k| {
        if (std.mem.indexOf(u8, args, k)) |i| {
            const start = i + k.len;
            var end = start;
            while (end < args.len) : (end += 1) {
                if (args[end] == '\\') {
                    end += 1;
                    continue;
                }
                if (args[end] == '"') break;
            }
            if (end > start) return args[start..end];
        }
    }
    return args;
}

fn tuiOnToolStart(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (std.mem.eql(u8, name, "workflow")) {
        tuiOk("stream.flow", app.tui.appendWorkflow(args));
    } else {
        const preview = toolArgsPreview(args);
        tuiOk("stream.tool", app.tui.appendTool(name, preview[0..@min(preview.len, 120)]));
    }
    var ea = util.Arena.init(app.alloc);
    defer ea.deinit();
    const ealloc = ea.allocator();
    app.events.emit("tool_start", std.fmt.allocPrint(ealloc, "\"tool\":{s},\"args\":{s}", .{
        try util.jsonString(ealloc, name),
        try util.jsonString(ealloc, args[0..@min(args.len, 500)]),
    }) catch return);
}

fn tuiOnToolEnd(ctx: ?*anyopaque, name: []const u8, is_error: bool, summary: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    tuiOk("stream.toolend", app.tui.appendToolEnd(name, is_error, summary));
    var ea = util.Arena.init(app.alloc);
    defer ea.deinit();
    const ealloc = ea.allocator();
    app.events.emit("tool_end", std.fmt.allocPrint(ealloc, "\"tool\":{s},\"error\":{s}", .{
        try util.jsonString(ealloc, name),
        if (is_error) "true" else "false",
    }) catch return);
}

fn tuiOnPaint(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    if (app.models_sync.done.load(.acquire)) mergeModelsSync(app);
    app.refreshFooter();
}

/// 启动模型表同步的 bg 线程:只取不合(合账归主线程,见 mergeModelsSync)。
fn modelsSyncThread(app: *App) void {
    const slot = std.heap.page_allocator.create(util.Arena) catch return;
    slot.* = util.Arena.init(std.heap.page_allocator);
    const a = slot.allocator();
    var items = std.array_list.Managed(ModelSyncItem).init(a);
    var fail: usize = 0;
    for (app.cfg.providers) |*p| {
        if (p.api_key == null) continue;
        const found = cfgmod.fetchDiscovered(a, p) catch {
            fail += 1;
            continue;
        };
        items.append(.{ .prov = p, .found = found }) catch {};
    }
    app.models_sync.mu.lock(util.io) catch {};
    app.models_sync.arena = slot;
    app.models_sync.items = items.toOwnedSlice() catch &.{};
    app.models_sync.fail = fail;
    app.models_sync.mu.unlock(util.io);
    app.models_sync.done.store(true, .release);
    app.tui.dirty.store(true, .release); // 戳主循环 on_paint
}

/// 主线程合账:mergeDiscovered 进 provider,释 bg arena,加新才报。
fn mergeModelsSync(app: *App) void {
    app.models_sync.done.store(false, .release);
    app.models_sync.mu.lock(util.io) catch {};
    const items = app.models_sync.items;
    const fail = app.models_sync.fail;
    const slot = app.models_sync.arena;
    app.models_sync.items = &.{};
    app.models_sync.fail = 0;
    app.models_sync.arena = null;
    app.models_sync.mu.unlock(util.io);
    var added: usize = 0;
    for (items) |it| {
        added += cfgmod.mergeDiscovered(it.prov, app.alloc, it.found) catch 0;
    }
    if (slot) |s| {
        s.deinit();
        std.heap.page_allocator.destroy(s);
    }
    if (added > 0 or fail > 0) {
        const msg = std.fmt.allocPrint(app.alloc, "模型表已同步: +{d}{s}", .{ added, if (fail > 0) "(有供应商取败)" else "" }) catch return;
        defer app.alloc.free(msg);
        tuiNote(app, "\x1b[2m", msg);
    }
}

fn tuiOnThink(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    app.agent.think_level = app.tui.think_level;
    persistThink(app);
    showWelcome(app, app.agent.messages.items.len);
}

fn tuiOnCopy(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    copyLastReply(app);
}

fn tuiOnSandbox(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    openSandboxPicker(app);
}

fn tuiOnJobs(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    showJobs(app);
}

fn tuiOnUsage(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    showUsage(app);
}

fn tuiOnRedo(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    redoLast(app);
}

fn tuiOnDoctor(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    showDoctor(app);
}

fn tuiOnDiff(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    showDiff(app);
}

fn tuiOnLog(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    showLog(app, "");
}

fn tuiOnTurnEnd(ctx: ?*anyopaque) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    app.refreshFooter();
    app.events.emit("turn_end", "");
}

/// 引擎级告知:自愈动作、限额触顶。用 dim 加 `piz` 前缀与模型输出区分开 ——
/// 用户要能一眼看出「这是 piz 在说话」而不是模型在说。
fn tuiOnNotice(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    var buf = std.array_list.Managed(u8).init(app.alloc);
    defer buf.deinit();
    tuiOk("tui.buf", buf.appendSlice("  piz  "));
    tuiOk("tui.buf", buf.appendSlice(text));
    tuiNote(app, "\x1b[2m", buf.items);
}

/// subagent 中间事件 → TUI 一行。
///
/// 逐 token 的正文不显示:32 路并行的文本混在一起没人读得懂,而
/// 「3 号在跑 grep」是真进度。委派原先是纯黑盒,界面上只有一个转圈。
fn tuiOnSubagent(ctx: ?*anyopaque, idx: usize, kind: agentmod.SubagentEvent, text: []const u8) anyerror!void {
    switch (kind) {
        .text, .reasoning => return,
        else => {},
    }
    const app: *App = @ptrCast(@alignCast(ctx.?));
    const flow_kind = switch (kind) {
        .tool_start => "tool_start",
        .tool_done => "tool_done",
        .tool_failed => "tool_failed",
        .notice => "notice",
        .finished => "finished",
        else => "",
    };
    if (flow_kind.len > 0 and app.tui.applyFlowEvent(idx, flow_kind, text)) return;
    const tag = switch (kind) {
        .tool_start => "tool",
        .tool_done => "ok",
        .tool_failed => "err",
        .notice => "piz",
        .finished => "done",
        else => "-",
    };
    // 栈缓冲而非 app.alloc:32 路 subagent 并发调这个回调,而 app.alloc 是
    // ArenaAllocator —— 它不是线程安全的。clampUtf8 保证不切断多字节字符。
    const clipped = util.clampUtf8(text, 100);
    var line: [224]u8 = undefined;
    const s = std.fmt.bufPrint(&line, "[sub {d}] {s} {s}", .{ idx, tag, clipped }) catch return;
    const color = if (kind == .tool_failed) "\x1b[31m" else "\x1b[2m";
    // appendLine 自己有锁(tui.zig),行不会交错
    tuiNote(app, color, s);
}

// worker/权限/提交群已拆 app_worker.zig(评审 P2 末刀);再导出保接线零改。
const tuiOnRequirePermission = app_worker.tuiOnRequirePermission;
const tuiOnPermKey = app_worker.tuiOnPermKey;
const onSubmit = app_worker.onSubmit;
pub const spawnWorker = app_worker.spawnWorker;
const onAbort = app_worker.onAbort;
const onDetach = app_worker.onDetach;
const tuiOnAbort = app_worker.tuiOnAbort;
const isQuit = app_worker.isQuit;

pub const OutputFormat = runopts.OutputFormat;

pub const RunOptions = runopts.RunOptions;

pub fn runInteractive(alloc: std.mem.Allocator, cfg: *cfgmod.Config, cwd: []const u8, opts: RunOptions) !void {
    // 目录切换
    if (!std.mem.eql(u8, cwd, ".")) {
        std.Io.Threaded.chdir(cwd) catch {
            std.debug.print("error: cannot chdir to {s}\n", .{cwd});
            std.process.exit(1);
        };
    }
    const abs_cwd = std.process.currentPathAlloc(util.io, alloc) catch cwd;
    tui_mod.applyTheme(cfg.theme);

    // 会话:指定 id → 恢复;-c → 续载最新;默认新会话(不带旧上下文开工)
    var sess = if (opts.session_id) |id| blk: {
        const found = (try sessionmod.Session.findById(alloc, abs_cwd, id)) orelse {
            std.debug.print("piz: session '{s}' not found in {s}\n", .{ id, abs_cwd });
            std.process.exit(1);
        };
        break :blk found;
    } else if (opts.title != null)
        (try sessionmod.Session.freshTitle(alloc, abs_cwd, opts.title))
    else if (opts.continue_session)
        (try sessionmod.Session.findLatest(alloc, abs_cwd)) orelse
            (try sessionmod.Session.fresh(alloc, abs_cwd))
    else
        (try sessionmod.Session.fresh(alloc, abs_cwd));

    // agent
    var agent = try agentmod.Agent.initOpts(alloc, cfg, opts.provider_name, opts.model_name, abs_cwd, .{ .read_only = opts.read_only, .system_override = opts.system_override, .depth = pluginsmod.processBaseDepth() });
    if (agent.key == null) {
        var up: [64]u8 = undefined;
        const upname = std.ascii.upperString(up[0..@min(agent.provider.name.len, 63)], agent.provider.name);
        std.debug.print("piz: no API key for provider '{s}'. Set ~/.piz/auth.json, models.json apiKey, or {s}_API_KEY env.\n", .{ agent.provider.name, upname });
        std.process.exit(1);
    }
    const loaded = try sess.loadMessages();
    try agent.messages.appendSlice(loaded);

    // JS 扩展运行时(QuickJS):~/.piz/extensions/*.js + <cwd>/.piz/extensions/*.js。
    // 在进 raw 模式前加载:加载错误可直接打 stderr,不花屏。
    jsrt.notify_cb = extNotify;
    jsrt.init(alloc);
    if (util.configDir(alloc)) |cd| {
        defer alloc.free(cd);
        pluginsmod.pushGates(alloc, pluginsmod.defaultSet());
        jsrt.loadExtensions(cd, abs_cwd);
    } else |_| {}
    if (jsrt.wantsSessionStart()) {
        var ea = util.Arena.init(alloc);
        defer ea.deinit();
        const payload = std.fmt.allocPrint(ea.allocator(), "{{\"cwd\":{s}}}", .{util.jsonString(ea.allocator(), abs_cwd) catch "\"\""}) catch "";
        _ = jsrt.emit(ea.allocator(), "session_start", payload);
    }

    // TUI
    var tui = try tui_mod.Tui.init(alloc);
    defer tui.deinit();
    tui_notify_target = &tui;
    defer tui_notify_target = null;
    if (pending_notify_len > 0) {
        tuiOk("ext.notify", tui.appendLine("", "\x1b[2m", pending_notify_buf[0..pending_notify_len]));
        pending_notify_len = 0;
    }
    // 斜杠补全:内置目录 + JS 扩展命令(有则合并一份长驻切片)。
    if (jsrt.jsCommands().len > 0) {
        const extra = jsrt.jsCommands();
        if (alloc.alloc(tui_mod.SlashItem, SLASH_ITEMS.len + extra.len)) |merged| {
            @memcpy(merged[0..SLASH_ITEMS.len], &SLASH_ITEMS);
            for (extra, 0..) |jc, k| {
                merged[SLASH_ITEMS.len + k] = .{
                    .cmd = std.fmt.allocPrint(alloc, "/{s}", .{jc.name}) catch jc.name,
                    .desc = jc.desc,
                };
            }
            tui.slash_items = merged;
        } else |_| tui.slash_items = &SLASH_ITEMS;
    } else tui.slash_items = &SLASH_ITEMS;
    // 声明在 tui.deinit 之后 → LIFO 下先执行:长驻 subagent 先收摊,
    // 之后才还原终端,它们的收尾输出不会打在已经恢复的 shell 上。
    defer pluginsmod.shutdownAgents();
    try tui.enterRaw();
    defer tui.restoreTerminal();

    // 事件总线(扫描包扩展声明)
    var bus = try eventsmod.Bus.init(alloc);
    {
        var ea = util.Arena.init(alloc);
        defer ea.deinit();
        const ealloc = ea.allocator();
        bus.emit("startup", std.fmt.allocPrint(ealloc, "\"cwd\":{s}", .{try util.jsonString(ealloc, abs_cwd)}) catch "");
    }

    var app = App{
        .alloc = alloc,
        .tui = &tui,
        .agent = &agent,
        .sess = &sess,
        .start_ns = std.Io.Clock.now(.real, util.io).nanoseconds,
        .cfg = cfg,
        .events = &bus,
        .read_only = opts.read_only,
        .approval = blk: {
            var mode = cfg.default_approval;
            if (opts.execute) mode = .yolo;
            if (opts.ask) mode = .ask;
            if (opts.read_only) mode = .read_only;
            break :blk mode;
        },
        .perm = .{ .buf = std.array_list.Managed(u8).init(alloc) },
        .queue = std.array_list.Managed([]const u8).init(alloc),
    };
    tui.ctx = &app;
    if (cfg.default_think_level) |lv| app.tui.think_level = lv;
    app.syncThink();
    rebuildSlashCatalog(&app);
    app.est_ctx.store(agent.estTokens(), .release);
    // 接线回调:流式输出 + 工具行 + 权限询问(此前缺失,交互模式流式显示依赖于此)
    agent.cbs = .{
        .ctx = &app,
        .on_text = tuiOnText,
        .on_reasoning = tuiOnReasoning,
        .on_tool_start = tuiOnToolStart,
        .on_tool_end = tuiOnToolEnd,
        .on_turn_end = tuiOnTurnEnd,
        .on_notice = tuiOnNotice,
        .on_subagent = tuiOnSubagent,
        .on_require_permission = tuiOnRequirePermission,
        .on_abort = tuiOnAbort,
    };
    app.perm.always.store(app.approval == .yolo, .release);

    // 启动即同步模型表:bg 线程纯取(GET /models),主线程 on_paint 合账;
    // 无阻启动(0.63ms 不可毁),无 key 供应商自跳。
    {
        var any_key = false;
        for (cfg.providers) |*p| {
            if (p.api_key != null) {
                any_key = true;
                break;
            }
        }
        if (any_key) {
            if (std.Thread.spawn(.{ .stack_size = 1 << 20 }, modelsSyncThread, .{&app}) catch null) |th| th.detach();
        }
    }

    showWelcome(&app, loaded.len);
    replayTranscript(&tui, loaded);
    if (loaded.len == 0 and opts.session_id == null and !opts.continue_session) {
        // 新会话起手若有旧事可续,注一行引路——「上回会话不见」之惑多起于默认新开
        if (sessionmod.Session.findLatest(alloc, abs_cwd) catch null) |prev| {
            var p = prev;
            defer p.deinit();
            if (!std.mem.eql(u8, p.path, sess.path)) {
                tuiNote(&app, "\x1b[2m", "new session · piz -c 续载上次,/sessions 拣选");
            }
        }
    }

    try tui.run(.{
        .on_submit = onSubmit,
        .is_quit = isQuit,
        .on_abort = onAbort,
        .on_detach = onDetach,
        .on_perm = tuiOnPermKey,
        .on_paint = tuiOnPaint,
        .on_think = tuiOnThink,
        .on_copy = tuiOnCopy,
        .on_sandbox = tuiOnSandbox,
        .on_jobs = tuiOnJobs,
        .on_usage = tuiOnUsage,
        .on_redo = tuiOnRedo,
        .on_doctor = tuiOnDoctor,
        .on_diff = tuiOnDiff,
        .on_log = tuiOnLog,
        .ctx = &app,
    });

    // 收尾:shutdown 事件 + 等待工作线程
    bus.emit("shutdown", "");
    if (app.worker) |th| {
        app.abort.store(true, .release);
        app.agent.aborted.store(true, .release);
        th.join();
    }

    // 先离开备用屏再印,否则提示跟着 alt screen 一起没了。
    tui.restoreTerminal();
    std.debug.print("resume: piz -s {s}\n", .{sess.sessionId()});
}

// ---------- CLI ----------

// ── JS 扩展 notify 桥:TUI 起前先暂存一条,起后落 transcript。──
var tui_notify_target: ?*tui_mod.Tui = null;
var pending_notify_buf: [256]u8 = undefined;
var pending_notify_len: usize = 0;

fn extNotify(msg: []const u8, level: []const u8) void {
    if (tui_notify_target) |t| {
        const style: []const u8 = if (std.mem.eql(u8, level, "error")) "\x1b[31m" else "\x1b[2m";
        tuiOk("ext.notify", t.appendLine("", style, msg));
    } else {
        const n = @min(msg.len, pending_notify_buf.len);
        @memcpy(pending_notify_buf[0..n], msg[0..n]);
        pending_notify_len = n;
    }
}

pub fn main(init: std.process.Init) !void {
    util.io = init.io;
    util.environ_map = init.environ_map;

    // 忽略 SIGPIPE
    std.posix.sigaction(std.posix.SIG.PIPE, &.{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 }, null);

    const alloc = init.gpa;

    // 旧目录迁移提示:piz 早期读 ~/.pi/agent,现独立用 ~/.piz。
    // 只在「有旧配置且无新配置」时提示一次,不自动搬 —— 搬动用户配置是破坏性操作。
    if (util.legacyConfigDir(alloc)) |legacy| {
        std.debug.print(
            \\piz: 配置目录已改为 ~/.piz(不再与官方 pi 共用 {s})。
            \\     迁移:cp -r {s} ~/.piz
            \\     或用 PIZ_DIR={s} 继续指向旧目录。
            \\
        , .{ legacy, legacy, legacy });
    }

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // argv[0]
    var print_mode = false;
    var print_prompt: ?[]const u8 = null;
    var input_file: ?[]const u8 = null;
    var opts = RunOptions{};
    var dir: ?[]const u8 = null;
    var prompt_parts = std.array_list.Managed([]const u8).init(alloc);
    var cli_plugins = std.array_list.Managed([]const u8).init(alloc);
    var cli_no_plugins = std.array_list.Managed([]const u8).init(alloc);
    var list_plugins = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print")) {
            print_mode = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            opts.model_name = args.next() orelse {
                std.debug.print("piz: missing value for {s}\n", .{arg});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--provider")) {
            opts.provider_name = args.next() orelse {
                std.debug.print("piz: missing value for --provider\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--new")) {
            opts.continue_session = false; // 本就是默认,留着兼容旧习惯
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--continue")) {
            opts.continue_session = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--read-only")) {
            opts.read_only = true;
        } else if (std.mem.eql(u8, arg, "-x") or std.mem.eql(u8, arg, "--execute") or std.mem.eql(u8, arg, "--yolo")) {
            opts.execute = true;
        } else if (std.mem.eql(u8, arg, "--ask")) {
            opts.ask = true;
        } else if (std.mem.eql(u8, arg, "--sandbox")) {
            opts.sandbox = args.next() orelse {
                std.debug.print("piz: missing value for --sandbox\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--title")) {
            opts.title = args.next() orelse {
                std.debug.print("piz: missing value for {s}\n", .{arg});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--session")) {
            opts.session_id = args.next() orelse {
                std.debug.print("piz: missing value for {s}\n", .{arg});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--async")) {
            opts.async_run = true;
        } else if (std.mem.eql(u8, arg, "--system")) {
            opts.system_override = args.next() orelse {
                std.debug.print("piz: missing value for {s}\n", .{arg});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--input")) {
            input_file = args.next() orelse {
                std.debug.print("piz: missing value for {s}\n", .{arg});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            const fmt = args.next() orelse {
                std.debug.print("piz: missing value for {s}\n", .{arg});
                std.process.exit(1);
            };
            if (std.mem.eql(u8, fmt, "text")) {
                opts.output_format = .text;
            } else if (std.mem.eql(u8, fmt, "json")) {
                opts.output_format = .json;
            } else if (std.mem.eql(u8, fmt, "jsonl")) {
                opts.output_format = .jsonl;
            } else {
                std.debug.print("piz: unknown output format {s} (text|json|jsonl)\n", .{fmt});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--models")) {
            printModels();
        } else if (std.mem.eql(u8, arg, "--no-plugin")) {
            try cli_no_plugins.append(args.next() orelse {
                std.debug.print("piz: missing value for --no-plugin\n", .{});
                std.process.exit(1);
            });
        } else if (std.mem.eql(u8, arg, "--plugin")) {
            try cli_plugins.append(args.next() orelse {
                std.debug.print("piz: missing value for --plugin\n", .{});
                std.process.exit(1);
            });
        } else if (std.mem.eql(u8, arg, "--plugins")) {
            // 延后到配置加载与 --plugin 应用之后再打印,否则显示的是编译期默认
            // 而不是本次实际生效的状态,会误导用户。
            list_plugins = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            std.debug.print("piz v{s}\n", .{VERSION});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{HELP});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "pkg")) {
            cmd_pkg.runPkgCmd(alloc, &args); // 不返回
        } else if (std.mem.eql(u8, arg, "login")) {
            cmd_login.run(alloc, &args);
            return;
        } else if (std.mem.eql(u8, arg, "reload")) {
            var arena = util.Arena.init(alloc);
            defer arena.deinit();
            var cfg = cfgmod.Config{ .arena = &arena };
            cfg.load() catch {
                std.debug.print("piz: reload failed\n", .{});
                std.process.exit(1);
            };
            const text = cfg.reloadSettings() catch {
                std.debug.print("piz: reload failed\n", .{});
                std.process.exit(1);
            };
            std.debug.print("{s}", .{text});
            if (text.len == 0 or text[text.len - 1] != '\n') std.debug.print("\n", .{});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "mcp")) {
            const text = mcpmod.formatStatus(alloc) catch {
                std.debug.print("piz: mcp failed\n", .{});
                std.process.exit(1);
            };
            std.debug.print("{s}", .{text});
            if (text.len == 0 or text[text.len - 1] != '\n') std.debug.print("\n", .{});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "branch")) {
            const here = std.process.currentPathAlloc(util.io, alloc) catch ".";
            const text = cmd_diff.formatBranch(alloc, here) catch {
                std.debug.print("piz: branch failed\n", .{});
                std.process.exit(1);
            };
            std.debug.print("{s}", .{text});
            if (text.len == 0 or text[text.len - 1] != '\n') std.debug.print("\n", .{});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "log")) {
            const narg = args.next() orelse "";
            const here = std.process.currentPathAlloc(util.io, alloc) catch ".";
            const text = cmd_diff.formatLog(alloc, here, cmd_diff.parseLogCount(narg)) catch {
                std.debug.print("piz: log failed\n", .{});
                std.process.exit(1);
            };
            std.debug.print("{s}", .{text});
            if (text.len == 0 or text[text.len - 1] != '\n') std.debug.print("\n", .{});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "commit")) {
            var parts = std.array_list.Managed([]const u8).init(alloc);
            while (args.next()) |a| parts.append(a) catch {};
            const msg = if (parts.items.len == 0) "" else std.mem.join(alloc, " ", parts.items) catch "";
            const here = std.process.currentPathAlloc(util.io, alloc) catch ".";
            const text = cmd_commit.run(alloc, here, msg) catch {
                std.debug.print("piz: commit failed\n", .{});
                std.process.exit(1);
            };
            std.debug.print("{s}\n", .{text});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "diff")) {
            const here = std.process.currentPathAlloc(util.io, alloc) catch ".";
            const text = cmd_diff.format(alloc, here) catch {
                std.debug.print("piz: diff failed\n", .{});
                std.process.exit(1);
            };
            std.debug.print("{s}", .{text});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "init")) {
            const here = std.process.currentPathAlloc(util.io, alloc) catch ".";
            const text = cmd_init.writeAgents(alloc, here) catch {
                std.debug.print("piz: init failed\n", .{});
                std.process.exit(1);
            };
            std.debug.print("{s}\n", .{text});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "doctor")) {
            const here = std.process.currentPathAlloc(util.io, alloc) catch ".";
            const text = cmd_doctor.format(alloc, .{ .version = VERSION, .cwd = here }) catch {
                std.debug.print("piz: doctor failed\n", .{});
                std.process.exit(1);
            };
            std.debug.print("{s}", .{text});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "usage")) {
            // 与 TUI /usage 同源:usage-ledger 插件落的 ~/.piz/usage.jsonl。
            const uselog = @import("core").usage_log;
            const sum = uselog.summarize(alloc, 8) catch {
                std.debug.print("piz: cannot read usage.jsonl\n", .{});
                std.process.exit(1);
            };
            var inb: [16]u8 = undefined;
            var outb: [16]u8 = undefined;
            if (sum.usd > 0) {
                std.debug.print("usage  {d} turns  ↑{s} ↓{s}  ${d:.4}\n", .{ sum.lines, tui_mod.formatTok(&inb, sum.tok_in), tui_mod.formatTok(&outb, sum.tok_out), sum.usd });
            } else {
                std.debug.print("usage  {d} turns  ↑{s} ↓{s}\n", .{ sum.lines, tui_mod.formatTok(&inb, sum.tok_in), tui_mod.formatTok(&outb, sum.tok_out) });
            }
            if (sum.tail.len > 0) std.debug.print("{s}\n", .{sum.tail});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "sessions")) {
            // 与 TUI /sessions 同源:本目录的会话清单。
            const here = std.process.currentPathAlloc(util.io, alloc) catch ".";
            const list = sessionmod.Session.list(alloc, here) catch &.{};
            defer for (list) |s| {
                var s2 = s;
                s2.deinit();
            };
            if (list.len == 0) {
                std.debug.print("no sessions yet\n", .{});
                std.process.exit(0);
            }
            std.debug.print("{d} sessions:\n", .{list.len});
            const now_ns = std.Io.Clock.now(.real, util.io).nanoseconds;
            for (list, 0..) |s, i| {
                const d = s.describe(alloc, now_ns) catch null;
                defer if (d) |info| info.deinit(alloc);
                const head = if (d) |info| info.headline else s.sessionId();
                const meta = if (d) |info| info.hint else "";
                std.debug.print("{d}. {s}  {s}\n", .{ i + 1, head, meta });
            }
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "plugins")) {
            const text = pluginsmod.listPlugins(alloc) catch {
                std.debug.print("piz: plugins failed\n", .{});
                std.process.exit(1);
            };
            std.debug.print("{s}", .{text});
            if (text.len == 0 or text[text.len - 1] != '\n') std.debug.print("\n", .{});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "build-web")) {
            // webui TS 构建:piz build-web [src_dir] [out] → sucrase 转译拼合出 webui.js
            const src_dir = args.next() orelse "src/webui";
            const out_path = args.next() orelse "src/webui.js";
            const n = @import("build_web.zig").run(alloc, src_dir, out_path) catch {
                std.process.exit(1);
            };
            std.debug.print("build-web: {s} → {s} ({d} bytes)\n", .{ src_dir, out_path, n });
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "memory")) {
            const mem_path = util.configDir(alloc) catch {
                std.debug.print("piz: no config dir\n", .{});
                std.process.exit(1);
            };
            const full = util.joinPath(alloc, mem_path, "memory.md") catch {
                std.debug.print("piz: cannot build path\n", .{});
                std.process.exit(1);
            };
            const content = std.Io.Dir.cwd().readFileAlloc(util.io, full, alloc, .limited(512 * 1024)) catch {
                std.debug.print("memory is empty\n", .{});
                std.process.exit(0);
            };
            std.debug.print("{s}", .{content[0..@min(content.len, 4000)]});
            if (content.len > 4000) std.debug.print("\n…(truncated)", .{});
            if (content.len == 0 or content[@min(content.len, 4000) - 1] != '\n') std.debug.print("\n", .{});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "web")) {
            cmd_web.runWebCmd(alloc, &args); // 不返回
        } else if (std.mem.eql(u8, arg, "sandbox-exec")) {
            sandboxmod.runExec(&args);
        } else if (std.mem.eql(u8, arg, "--")) {
            // 之后全部当字面量 —— 提示词以 '-' 开头时唯一的写法,
            // 比如 `piz -p -- "-rf 是什么意思"`。少了它这种提问无法输入。
            while (args.next()) |rest| {
                if (print_mode) {
                    try prompt_parts.append(rest);
                } else if (dir == null) {
                    dir = rest;
                } else {
                    std.debug.print("piz: unexpected argument {s}\n", .{rest});
                    std.process.exit(1);
                }
            }
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("piz: unknown option {s}\n{s}", .{ arg, HELP });
            std.process.exit(1);
        } else if (print_mode) {
            try prompt_parts.append(arg);
        } else if (dir == null) {
            dir = arg;
        } else {
            std.debug.print("piz: unexpected argument {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    if (input_file != null and !print_mode) {
        std.debug.print("piz: -i/--input requires -p/--print\n", .{});
        std.process.exit(1);
    }
    if (opts.async_run and !print_mode) {
        std.debug.print("piz: -a/--async requires -p/--print\n", .{});
        std.process.exit(1);
    }

    // print 提示词:输入文件 > 参数 > stdin
    if (print_mode) {
        if (input_file) |fpath| {
            print_prompt = std.Io.Dir.cwd().readFileAlloc(util.io, fpath, alloc, .limited(4 * 1024 * 1024)) catch |err| {
                std.debug.print("piz: cannot read {s}: {s}\n", .{ fpath, @errorName(err) });
                std.process.exit(1);
            };
        } else if (prompt_parts.items.len > 0) {
            var joined = std.array_list.Managed(u8).init(alloc);
            for (prompt_parts.items, 0..) |p, i| {
                if (i > 0) try joined.append(' ');
                try joined.appendSlice(p);
            }
            print_prompt = try joined.toOwnedSlice();
        } else {
            var sbuf: [8192]u8 = undefined;
            var r = std.Io.File.stdin().reader(util.io, &sbuf);
            print_prompt = try r.interface.allocRemaining(alloc, .limited(4 * 1024 * 1024));
        }
    }

    const cwd = dir orelse ".";

    var cfg_arena = util.Arena.init(alloc);
    var cfg = cfgmod.Config{ .arena = &cfg_arena };
    defer cfg.deinit();
    try cfg.load();
    cfg.warnBroken();
    if (opts.sandbox) |raw| {
        cfg.default_sandbox = cfgmod.SandboxMode.parse(raw) orelse {
            std.debug.print("piz: unknown --sandbox {s} (off|workspace|strict)\n", .{raw});
            std.process.exit(1);
        };
    }

    // 插件启用:settings.json 的 plugins 数组,再叠加 --plugin 参数。
    // settings 里的未知名字只警告(配置可能为更新版本写的);CLI 里的直接失败。
    for (cfg.enabled_plugins) |name| {
        if (!pluginsmod.enable(name)) {
            std.debug.print("piz: unknown plugin '{s}' in settings.json (see piz --plugins)\n", .{name});
        }
    }
    for (cli_plugins.items) |name| {
        if (!pluginsmod.enable(name)) {
            std.debug.print("piz: unknown plugin '{s}' (see piz --plugins)\n", .{name});
            std.process.exit(1);
        }
    }
    for (cfg.disabled_plugins) |name| {
        if (!pluginsmod.disable(name)) {
            std.debug.print("piz: unknown plugin '{s}' in settings.json disabled_plugins (see piz --plugins)\n", .{name});
        }
    }
    for (cli_no_plugins.items) |name| {
        if (!pluginsmod.disable(name)) {
            std.debug.print("piz: unknown plugin '{s}' (see piz --plugins)\n", .{name});
            std.process.exit(1);
        }
    }
    // skills 插件按「是否装了技能」自动开启,与 agent 初始化里的逻辑一致,
    // 这样 --plugins 显示的就是真实生效状态。
    if (list_plugins) {
        const idx = util.loadSkillsIndex(alloc) catch "";
        if (idx.len > 0) _ = pluginsmod.enable("skills");
        printPlugins(alloc);
    }

    if (opts.async_run) {
        // 原始 argv(含 argv[0]),runAsync 重建用
        var all_args = std.array_list.Managed([]const u8).init(alloc);
        var ait = std.process.Args.Iterator.init(init.minimal.args);
        while (ait.next()) |a| try all_args.append(a);
        cmd_print.runAsync(alloc, cwd, print_prompt orelse "", all_args.items) catch |e| explainAndExit(e, &cfg, opts);
    } else if (print_mode) {
        cmd_print.runPrint(alloc, &cfg, cwd, print_prompt orelse "", opts) catch |e| explainAndExit(e, &cfg, opts);
    } else {
        runInteractive(alloc, &cfg, cwd, opts) catch |e| explainAndExit(e, &cfg, opts);
        // 交互模式自然退出时直接 exit:避免 DebugAllocator 对进程级分配
        // (environ map、gpa 杂项)的泄漏检查误报(print 模式已如此)。
        std.process.exit(0);
    }
}

/// 把启动期错误翻成人话再退出。
///
/// 原先这些错误直接冒泡出 main,用户看到的是一屏 Zig 调用栈 ——
/// 「UnknownProvider」加十行 std 内部帧,对着它没法判断该改哪个文件。
/// 错误消息要说清**下一步做什么**,不是描述内部状态。
fn explainAndExit(e: anyerror, cfg: *cfgmod.Config, opts: RunOptions) noreturn {
    switch (e) {
        error.UnknownProvider => {
            const want = opts.provider_name orelse util.getEnv("PIZ_PROVIDER") orelse "(default)";
            std.debug.print("piz: unknown provider '{s}'.\n", .{want});
            if (cfg.providers.len == 0) {
                std.debug.print("  No providers are configured. Create ~/.piz/models.json, for example:\n" ++
                    "    {{\"providers\":[{{\"name\":\"deepseek\",\"baseUrl\":\"https://api.deepseek.com\",\"models\":[\"deepseek-v4-flash\"]}}]}}\n" ++
                    "  then put the key in ~/.piz/auth.json or DEEPSEEK_API_KEY.\n", .{});
            } else {
                std.debug.print("  Configured providers:", .{});
                for (cfg.providers) |*p| std.debug.print(" {s}", .{p.name});
                std.debug.print("\n  Pick one with --provider <name> or PIZ_PROVIDER.\n", .{});
            }
        },
        error.FileNotFound => std.debug.print("piz: a required file is missing (check -i path and ~/.piz/models.json)\n", .{}),
        error.OutOfMemory => std.debug.print("piz: out of memory\n", .{}),
        else => std.debug.print("piz: {s}\n", .{@errorName(e)}),
    }
    std.process.exit(1);
}

/// 列出全部内置插件与启用状态(--plugins)。
fn printPlugins(alloc: std.mem.Allocator) void {
    var arena = util.Arena.init(alloc);
    defer arena.deinit();
    const body = pluginsmod.listPlugins(arena.allocator()) catch {
        std.debug.print("piz: cannot list plugins\n", .{});
        std.process.exit(1);
    };
    std.debug.print(
        \\内置插件({d} 个;on = 默认启用或已开启):
        \\{s}
        \\开启方式:piz --plugin <name>  或  ~/.piz/settings.json 的 "plugins": ["name"]
        \\
    , .{ pluginsmod.builtin_plugins.len, body });
    const cwd = std.process.currentPathAlloc(util.io, arena.allocator()) catch "";
    const pkg_tools = pkgsmod.loadPkgTools(arena.allocator(), cwd) catch &.{};
    if (pkg_tools.len > 0) {
        std.debug.print("包声明工具:\n", .{});
        for (pkg_tools) |t| std.debug.print("  [pkg] {s}\n", .{t.name});
    }
    std.process.exit(0);
}

/// 列出全部 provider 与模型(--models)。
fn printModels() void {
    var cfg_arena = util.Arena.init(std.heap.page_allocator);
    var cfg = cfgmod.Config{ .arena = &cfg_arena };
    cfg.load() catch {
        std.debug.print("piz: failed to load config\n", .{});
        std.process.exit(1);
    };
    cfg.warnBroken();
    defer cfg.deinit();
    for (cfg.providers) |p| {
        std.debug.print("{s}:", .{p.name});
        if (p.models.len > 0) {
            for (p.models, 0..) |m, i| {
                if (i > 0) std.debug.print(",", .{});
                std.debug.print(" {s}", .{m});
            }
        } else {
            std.debug.print(" (no model list)", .{});
        }
        std.debug.print("\n", .{});
    }
    std.process.exit(0);
}

test {
    _ = @import("core");
    _ = @import("tui");
    _ = @import("cmd_web.zig");
    _ = @import("cmd_doctor.zig");
    _ = @import("cmd_init.zig");
    _ = @import("cmd_diff.zig");
    _ = @import("cmd_commit.zig");
    _ = @import("build_web.zig");
    _ = cmd_print;
    _ = cmd_login;
    _ = cmd_pkg;
    // webui 只被 main 引入(HTTP 服务属 app 层,不在 core 库里)。Zig 只收集
    // 显式列出的测试 —— 少了这行,webui.zig 的 test 块一个都不会跑。
    // 用已有的 webui_mod 别名,不能再 @import 一次:同一文件同时属于
    // root 与 core 两个模块会编译失败。
    _ = webui_mod;
}

test "gitBranch reads HEAD" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try std.process.currentPathAlloc(util.io, t.allocator);
    defer {
        std.Io.Threaded.chdir(old_cwd) catch {};
        t.allocator.free(old_cwd);
    }
    const tmp_path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer t.allocator.free(tmp_path);
    std.Io.Threaded.chdir(tmp_path) catch unreachable;
    try t.expect(cmd_diff.currentBranch(t.allocator, ".") == null);
    std.Io.Dir.cwd().createDirPath(util.io, ".git") catch {};
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    const br = cmd_diff.currentBranch(t.allocator, ".").?;
    defer t.allocator.free(br);
    try t.expectEqualStrings("main", br);
}

test "e2e memory pipeline" {
    try @import("e2e.zig").testMemoryPipeline();
}

test "e2e mock provider full loop" {
    try @import("e2e.zig").testFullLoop();
}

test "e2e task delegation spawns a real sub-agent" {
    try util.testInit();
    var arena = util.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 用构建产物,不是测试进程自身(测试二进制不是 piz)。
    // 产物不存在就跳过 —— `zig build test` 会先建好它。
    const cwd = try std.process.currentPathAlloc(util.io, a);
    const exe = try std.fmt.allocPrint(a, "{s}/zig-out/bin/piz", .{cwd});
    std.Io.Dir.cwd().access(util.io, exe, .{}) catch return error.SkipZigTest;
    try @import("e2e.zig").testTaskDelegation(exe);
}

test "e2e -- passes a dash-leading prompt through" {
    try util.testInit();
    var arena = util.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(util.io, a);
    const exe = try std.fmt.allocPrint(a, "{s}/zig-out/bin/piz", .{cwd});
    std.Io.Dir.cwd().access(util.io, exe, .{}) catch return error.SkipZigTest;
    try @import("e2e.zig").testDashSeparator(exe);
}

test "e2e js extension blocks bash via tool_call" {
    if (!jsrt.enabled) return error.SkipZigTest;
    try util.testInit();
    var arena = util.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(util.io, a);
    const exe = try std.fmt.allocPrint(a, "{s}/zig-out/bin/piz", .{cwd});
    std.Io.Dir.cwd().access(util.io, exe, .{}) catch return error.SkipZigTest;
    try @import("e2e.zig").testJsExtBlocksBash(exe);
}

test "expandRefs" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 写相对 cwd 的引用文件
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = "ref_test.txt", .data = "FILE-CONTENT" });
    defer std.Io.Dir.cwd().deleteFile(util.io, "ref_test.txt") catch {};
    // @./ref_test.txt 展开
    const r1 = try util.expandRefs(a, "read this @./ref_test.txt please", "");
    try t.expect(std.mem.indexOf(u8, r1, "FILE-CONTENT") != null);
    try t.expect(std.mem.indexOf(u8, r1, "```./ref_test.txt") != null);
    // 普通 @ 保留(邮箱/提及)
    const r2 = try util.expandRefs(a, "mail me @someone now", "");
    try t.expectEqualStrings("mail me @someone now", r2);
    // 不存在路径保留原文
    const r3 = try util.expandRefs(a, "see @./nope.txt end", "");
    try t.expectEqualStrings("see @./nope.txt end", r3);
}

test {
    _ = @import("tui");
}

test "copyToClipboard does not double-close the child stdin" {
    try util.testInit();
    var arena = util.Arena.init(std.testing.allocator);
    defer arena.deinit();

    // 回归测试:写完 stdin 后既 close 又让 child.wait 再关一次,
    // 同一 fd 关两次 → EBADF → std 判为 OS bug → Debug 构建 unreachable,
    // 整个 piz 崩在 /copy 上。这里只要求它不 panic。
    //
    // 系统没装 wl-copy/xclip 时返回 false,同样不该崩 —— 两条路径都走一遍。
    _ = copyToClipboard(arena.allocator(), "clipboard round trip\n");
    _ = copyToClipboard(arena.allocator(), "");
}

test "every slash command appears in /help" {
    const t = std.testing;

    // /dump /export /plan /queue 四条一直能用却没在帮助里列出 ——
    // 对用户等于不存在。这里把清单和实际分发绑在一起:
    // 新加命令忘了写进 SLASH_ITEMS,测试就失败。
    //
    // 命令名取自 onSubmit 里的 `eql(u8, cmd, "…")` / `startsWith(u8, cmd, "… ")`。
    const dispatched = [_][]const u8{
        "help",  "status", "doctor", "init", "diff", "commit", "log",    "branch",  "mcp", "reload",  "usage",         "jobs",  "find", "paste", "think",  "theme", "permissions", "sandbox", "model", "refresh", "new", "sessions", "resume",
        "title", "tree",   "fork",   "copy", "undo", "redo",   "memory", "plugins", "pkg", "compact", "fast-compress", "clear", "plan", "queue", "export", "dump",  "quit",
    };
    for (dispatched) |cmd| {
        var found = false;
        for (SLASH_ITEMS) |it| {
            if (it.cmd.len < 2 or it.cmd[0] != '/') continue;
            const rest = it.cmd[1..];
            if (std.mem.eql(u8, rest, cmd) or
                (std.mem.startsWith(u8, rest, cmd) and rest.len > cmd.len and rest[cmd.len] == ' '))
            {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("命令 /{s} 能用但没在 SLASH_ITEMS 里\n", .{cmd});
            return error.CommandMissingFromHelp;
        }
    }
    // 别名不单独列(/q /exit 是 /quit 的简写,列出来只是噪音)
    for (SLASH_ITEMS) |it| {
        try t.expect(!std.mem.eql(u8, it.cmd, "/q"));
    }

    const text = try formatHelp(t.allocator, 80);
    defer t.allocator.free(text);
    for (SLASH_ITEMS) |it| {
        try t.expect(std.mem.indexOf(u8, text, it.cmd) != null);
    }
    try t.expect(std.mem.indexOf(u8, text, "commands") != null);
    try t.expect(std.mem.indexOf(u8, text, "keys") != null);
}

test "status card still builds; welcome is footer not a header cell" {
    const t = std.testing;
    const note = try welcomeNote(t.allocator, 12, "refactor");
    defer t.allocator.free(note);
    try t.expectEqualStrings("continued · refactor · 12", note);
    const fresh = try welcomeNote(t.allocator, 0, null);
    defer t.allocator.free(fresh);
    try t.expectEqualStrings("new", fresh);

    var ui = try tui_mod.Tui.init(t.allocator);
    defer ui.deinit();
    try ui.setFooterIdentity(.{
        .model = "deepseek/flash",
        .think = "high",
        .cwd = "~/pi-zig",
        .session = "1786735635034",
        .used = 0,
        .window = 128_000,
        .pct = 0,
    });
    try t.expectEqual(@as(usize, 0), ui.cells.items.len);
    for (ui.cells.items) |c| try t.expect(c.kind != .session_header);

    const foot = try tui_mod.formatFooterRows(t.allocator, .{
        .model = "deepseek/flash",
        .think = "high",
        .cwd = "~/pi-zig",
        .session = "1786735635034",
        .used = 12_000,
        .window = 128_000,
        .cache_read = 7_440,
        .prompt = 12_000,
        .tok_in = 4_700,
        .tok_out = 44,
        .tok_cache_r = 7_440,
        .pct = 9,
    }, "? for shortcuts", 80, true);
    defer foot.deinit(t.allocator);
    // pi 式双行:行 1 地点,行 2 stats + model
    try t.expect(std.mem.indexOf(u8, foot.primary, "~/pi-zig") != null);
    try t.expect(std.mem.indexOf(u8, foot.primary, "? for shortcuts") != null);
    try t.expect(std.mem.indexOf(u8, foot.secondary, "deepseek/flash") != null);
    try t.expect(std.mem.indexOf(u8, foot.secondary, "ctx ") != null);
    try t.expect(std.mem.indexOf(u8, foot.secondary, "9% 12k/128k") != null);
    // R 与数值间夹 ANSI reset,分查
    try t.expect(std.mem.indexOf(u8, foot.secondary, "R") != null);
    try t.expect(std.mem.indexOf(u8, foot.secondary, "7.4k") != null);
    try t.expect(std.mem.indexOf(u8, foot.secondary, "↑4.7k") != null);

    const card = try formatStatusCard(t.allocator, .{
        .version = "0.1.0",
        .model = "deepseek/flash",
        .think = "high",
        .cwd = "~/pi-zig",
        .session = note,
        .perms = "yolo",
        .context = "AGENTS.md · 2 skills",
        .usage = "12%  1.2k/128k",
    }, 80);
    defer t.allocator.free(card);
    try t.expect(std.mem.indexOf(u8, card, "continued · refactor · 12") != null);
    try t.expect(std.mem.indexOf(u8, card, "model:") != null);
    try t.expect(std.mem.indexOf(u8, card, "deepseek/flash") != null);
    try t.expect(std.mem.indexOf(u8, card, "permissions:") != null);
    try t.expect(std.mem.indexOf(u8, card, "usage:") != null);
    try t.expect(std.mem.indexOf(u8, card, "╭") != null);
}

test "replayTranscript paints user assistant tools" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ui = try tui_mod.Tui.init(alloc);
    defer ui.deinit();
    const calls = [_]ai.ToolCall{.{ .id = "1", .name = "bash", .args = "{\"command\":\"ls\"}" }};
    const msgs = [_]ai.Message{
        .{ .role = "system", .content = "ignore" },
        .{ .role = "user", .content = "list files" },
        .{ .role = "assistant", .content = "running", .reasoning = "think first", .tool_calls = &calls },
        .{ .role = "tool", .content = "a\nb\n" },
        .{ .role = "assistant", .content = "done" },
    };
    replayTranscript(&ui, &msgs);
    try t.expect(ui.contains("list files"));
    try t.expect(ui.contains("running"));
    try t.expect(ui.contains("think first"));
    try t.expect(ui.contains("bash"));
    try t.expect(ui.contains("ls"));
    try t.expect(ui.contains("done"));
    try t.expect(!ui.contains("ignore"));
}

test "toolArgsPreview prefers command path pattern" {
    const t = std.testing;
    try t.expectEqualStrings("zig test", toolArgsPreview("{\"command\":\"zig test\"}"));
    try t.expectEqualStrings("src/main.zig", toolArgsPreview("{\"path\":\"src/main.zig\"}"));
    try t.expectEqualStrings("fn foo", toolArgsPreview("{\"pattern\":\"fn foo\",\"path\":\".\"}"));
    try t.expectEqualStrings("raw", toolArgsPreview("raw"));
}

test "needsConfirm skips read-class tools" {
    const t = std.testing;
    try t.expect(!toolsmod.needsConfirm("ls"));
    try t.expect(!toolsmod.needsConfirm("read"));
    try t.expect(toolsmod.needsConfirm("bash"));
    try t.expect(toolsmod.needsConfirm("write"));
}
