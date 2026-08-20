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
const runopts = @import("runopts.zig");

const VERSION = "0.1.0";

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
    /// 会话起始时刻(ns,状态栏 t/s)
    start_ns: i128,

    /// 队列消息入队(主线程调用)。失败须告诉用户,否则排队消息会无声消失。
    fn enqueue(self: *App, line: []const u8) bool {
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
    fn dequeue(self: *App) ?[]const u8 {
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

    fn fmtTok(buf: *[16]u8, n: u64) []const u8 {
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

    fn modelLabel(self: *App, buf: *[96]u8) []const u8 {
        var model_seg: []const u8 = self.agent.model;
        if (std.mem.indexOfScalar(u8, model_seg, '-')) |dash| model_seg = model_seg[dash + 1 ..];
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.agent.provider.name, model_seg }) catch self.agent.model;
    }

    fn permsLabel(self: *const App) []const u8 {
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

pub fn showWelcome(app: *App, n_msgs: usize) void {
    _ = n_msgs;
    app.refreshFooter();
}

pub fn replaceSession(app: *App) !void {
    const next = try sessionmod.Session.fresh(app.alloc, app.agent.cwd);
    app.agent.messages.clearRetainingCapacity();
    app.tui.clearScroll();
    app.sess.deinit();
    app.sess.* = next;
}

pub fn showStatusCard(app: *App) void {
    const note = welcomeNote(app.alloc, app.agent.messages.items.len, app.sess.title) catch return;
    defer app.alloc.free(note);
    const session = std.fmt.allocPrint(app.alloc, "{s}  {s}", .{ app.sess.sessionId(), note }) catch return;
    defer app.alloc.free(session);
    const cwd = tildePath(app.alloc, app.agent.cwd) catch return;
    defer app.alloc.free(cwd);
    const ctx = welcomeContext(app.alloc) catch return;
    defer app.alloc.free(ctx);
    const cw = app.agent.ctxWindow();
    const used = app.est_ctx.load(.acquire);
    const pct = if (cw > 0) used * 100 / cw else 0;
    var ub: [16]u8 = undefined;
    var wb: [16]u8 = undefined;
    const meta = app.agent.modelMeta();
    const rates = pricing.lookupAny(app.agent.provider.name, app.agent.model);
    const usage = blk: {
        if (rates) |r| {
            const think = if (meta.reasoning == true) " · think" else "";
            const vis = if (meta.vision == true) " · vis" else "";
            break :blk std.fmt.allocPrint(app.alloc, "{d}%  {s}/{s}  ·  ${d:.2}/{d:.2}{s}{s}", .{
                pct,
                App.fmtTok(&ub, @as(u64, used)),
                App.fmtTok(&wb, @as(u64, cw)),
                r.input,
                r.output,
                think,
                vis,
            }) catch return;
        }
        break :blk std.fmt.allocPrint(app.alloc, "{d}%  {s}/{s}", .{
            pct,
            App.fmtTok(&ub, @as(u64, used)),
            App.fmtTok(&wb, @as(u64, cw)),
        }) catch return;
    };
    defer app.alloc.free(usage);
    const plugs = pluginsmod.enabledOptionalLine(app.alloc, app.agent.plugins) catch "";
    const usage_line = if (plugs.len == 0) usage else (std.fmt.allocPrint(app.alloc, "{s}  ·  {s}", .{ usage, plugs }) catch usage);
    defer if (usage_line.ptr != usage.ptr) app.alloc.free(usage_line);
    var model_buf: [96]u8 = undefined;
    var br_buf: [128]u8 = undefined;
    const branch = cmd_diff.currentBranchBuf(app.agent.cwd, &br_buf) orelse "";
    app.tui.appendStatusCard(.{
        .version = VERSION,
        .model = app.modelLabel(&model_buf),
        .think = tui_mod.thinkLabel(app.tui.think_level),
        .cwd = cwd,
        .branch = branch,
        .session = session,
        .perms = app.permsLabel(),
        .context = ctx,
        .usage = usage_line,
    }) catch |err| util.debugCatch("tui.status", err);
}

pub fn showDoctor(app: *App) void {
    const plugs = pluginsmod.enabledOptionalLine(app.alloc, app.agent.plugins) catch "";
    const sb = sandboxmod.describe(app.alloc, app.cfg.default_sandbox) catch app.cfg.default_sandbox.label();
    const key = app.agent.key orelse "";
    const text = cmd_doctor.format(app.alloc, .{
        .version = VERSION,
        .cwd = app.agent.cwd,
        .provider = app.agent.provider.name,
        .model = app.agent.model,
        .has_key = key.len > 0,
        .think = tui_mod.thinkLabel(app.tui.think_level),
        .approval = app.approval.label(),
        .sandbox_mode = sb,
        .plugins = plugs,
    }) catch return;
    defer app.alloc.free(text);
    tuiNotes(app, "\x1b[2m", text);
}

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

/// 把已载入的会话画进 TUI。续载只把消息给了模型,不画的话 PageUp 没有历史可滚。
pub fn replayTranscript(tui: *tui_mod.Tui, msgs: []const ai.Message) void {
    var pending: [16][]const u8 = undefined;
    var pending_n: usize = 0;
    var pending_i: usize = 0;
    for (msgs) |m| {
        if (std.mem.eql(u8, m.role, "system")) continue;
        if (std.mem.eql(u8, m.role, "user")) {
            if (m.image != null) {
                const shown = if (m.content.len > 0 and !std.mem.eql(u8, m.content, "(image)"))
                    m.content
                else
                    "[image]";
                tuiOk("replay.user.img", tui.appendUser(shown));
            } else if (m.content.len > 0) tuiOk("replay.user", tui.appendUser(m.content));
            continue;
        }
        if (std.mem.eql(u8, m.role, "assistant")) {
            if (m.reasoning) |r| {
                if (r.len > 0) tuiOk("replay.think", tui.appendThink(r));
            }
            if (m.content.len > 0) tuiOk("replay.text", tui.appendText(m.content));
            pending_n = 0;
            pending_i = 0;
            if (m.tool_calls) |tcs| {
                for (tcs) |tc| {
                    if (std.mem.eql(u8, tc.name, "workflow")) {
                        tuiOk("replay.flow", tui.appendWorkflow(tc.args));
                    } else {
                        const preview = toolArgsPreview(tc.args);
                        tuiOk("replay.tool", tui.appendTool(tc.name, preview[0..@min(preview.len, 120)]));
                    }
                    if (pending_n < pending.len) {
                        pending[pending_n] = tc.name;
                        pending_n += 1;
                    }
                }
            }
            tui.bakeThink();
            continue;
        }
        if (std.mem.eql(u8, m.role, "tool")) {
            const name = if (pending_i < pending_n) blk: {
                const n = pending[pending_i];
                pending_i += 1;
                break :blk n;
            } else "";
            tuiOk("replay.toolend", tui.appendToolEnd(name, false, m.content));
        }
    }
    tui.bakeThink();
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
fn toolArgsPreview(args: []const u8) []const u8 {
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
    app.refreshFooter();
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

pub fn redoLast(app: *App) void {
    if (app.last_line.len == 0) {
        tuiNote(app, "\x1b[2m", "nothing to redo");
        return;
    }
    tuiOk("tui.user", app.tui.appendUser(app.last_line));
    spawnWorker(app, app.last_line, false);
}

fn tuiOnRedo(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    redoLast(app);
}

fn tuiOnDoctor(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    showDoctor(app);
}

pub fn showDiff(app: *App) void {
    const text = cmd_diff.format(app.alloc, app.agent.cwd) catch {
        tuiNote(app, "\x1b[31m", "diff failed");
        return;
    };
    defer app.alloc.free(text);
    tuiNotes(app, "\x1b[2m", text);
}

fn tuiOnDiff(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    showDiff(app);
}

pub fn showLog(app: *App, raw: []const u8) void {
    const text = cmd_diff.formatLog(app.alloc, app.agent.cwd, cmd_diff.parseLogCount(raw)) catch {
        tuiNote(app, "\x1b[31m", "log failed");
        return;
    };
    defer app.alloc.free(text);
    tuiNotes(app, "\x1b[2m", text);
}

fn tuiOnLog(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    showLog(app, "");
}

pub fn showJobs(app: *App) void {
    var views: [activity.MAX_SLOTS]activity.View = undefined;
    const n = activity.snapshot(&views);
    if (n == 0) {
        tuiNote(app, "\x1b[2m", "no running jobs");
        return;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var aw = std.Io.Writer.Allocating.init(app.alloc);
        defer aw.deinit();
        if (views[i].pid > 0) tuiOk("jobs.pid", aw.writer.print("pid {d}  ", .{views[i].pid}));
        tuiOk("jobs.line", tui_mod.writeActivityLine(&aw.writer, views[i], 0, 80));
        tuiNote(app, "", aw.written());
    }
}

pub fn showUsage(app: *App) void {
    const uselog = @import("core").usage_log;
    const sum = uselog.summarize(app.alloc, 8) catch {
        tuiNote(app, "\x1b[31m", "cannot read usage.jsonl");
        return;
    };
    var inb: [16]u8 = undefined;
    var outb: [16]u8 = undefined;
    var bw = std.Io.Writer.Allocating.init(app.alloc);
    defer bw.deinit();
    if (sum.usd > 0) {
        bw.writer.print("usage  {d} turns  ↑{s} ↓{s}  ${d:.4}", .{
            sum.lines,
            tui_mod.formatTok(&inb, sum.tok_in),
            tui_mod.formatTok(&outb, sum.tok_out),
            sum.usd,
        }) catch |err| util.debugCatch("usage.usd", err);
    } else {
        bw.writer.print("usage  {d} turns  ↑{s} ↓{s}", .{
            sum.lines,
            tui_mod.formatTok(&inb, sum.tok_in),
            tui_mod.formatTok(&outb, sum.tok_out),
        }) catch |err| util.debugCatch("usage.plain", err);
    }
    tuiNote(app, "\x1b[2m", bw.written());
    if (sum.tail.len > 0) tuiNote(app, "\x1b[2m", sum.tail);
}

pub fn copyLastReply(app: *App) void {
    var last: ?[]const u8 = null;
    var i = app.agent.messages.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, app.agent.messages.items[i].role, "assistant")) {
            last = app.agent.messages.items[i].content;
            break;
        }
    }
    const text = last orelse {
        tuiNote(app, "\x1b[2m", "no assistant message yet");
        return;
    };
    if (copyToClipboard(app.alloc, text)) {
        tuiNote(app, "\x1b[2m", "copied to clipboard");
    } else if (util.writeFile("/tmp/piz-copy.txt", text)) |_| {
        tuiNote(app, "\x1b[2m", "no clipboard tool — saved to /tmp/piz-copy.txt");
    } else |_| {}
}

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

/// 权限询问(worker 线程):构建提示 → 置 pending → 轮询决策。
fn tuiOnRequirePermission(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!bool {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (app.perm.always.load(.acquire)) return true;
    const gate = toolsmod.toolGate(app.approval, name);
    if (gate == .allow) return true;
    if (gate == .deny or app.read_only) return false;
    app.perm.buf.clearRetainingCapacity();
    try app.perm.buf.appendSlice("? ");
    try app.perm.buf.appendSlice(name);
    const preview = toolArgsPreview(args);
    if (preview.len > 0) {
        try app.perm.buf.appendSlice("  ");
        const head = preview[0..@min(preview.len, 120)];
        try app.perm.buf.appendSlice(head);
        if (preview.len > 120) try app.perm.buf.appendSlice("…");
    }
    // 键位在页脚,不在提示里再写一遍。
    app.perm.decision.store(0, .release);
    app.perm.pending.store(true, .release);
    app.perm.slice = app.perm.buf.items;
    app.tui.perm_prompt.store(&app.perm.slice, .release);
    app.tui.dirty.store(true, .release);
    defer {
        app.tui.perm_prompt.store(null, .release);
        app.tui.dirty.store(true, .release);
        app.perm.pending.store(false, .release);
    }
    // 轮询决策(主循环按键应答);Ctrl+C 中止。
    // 必须看 decision / 由按键把 pending 放下 —— 只写 decision 会永远卡住。
    while (app.perm.pending.load(.acquire) and app.perm.decision.load(.acquire) == 0) {
        if (app.abort.load(.acquire)) return false;
        _ = std.Io.sleep(util.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
    }
    return app.perm.decision.load(.acquire) == 1;
}

fn settlePerm(app: *App, allow: bool) void {
    app.perm.decision.store(if (allow) 1 else 2, .release);
    app.perm.pending.store(false, .release);
}

/// 权限按键路由(主循环):y/n/a/s/Ctrl+C。
fn tuiOnPermKey(ctx: ?*anyopaque, key: u8) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    switch (key) {
        'y', 'Y' => settlePerm(app, true),
        'n', 'N', 0x03, 0x1b => settlePerm(app, false),
        'a', 'A' => {
            app.approval = .yolo;
            app.perm.always.store(true, .release);
            settlePerm(app, true);
        },
        's', 'S' => settlePerm(app, false),
        else => {},
    }
}

const WorkerCtx = struct {
    app: *App,
    line: []const u8,
    is_compact: bool = false,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn workerMain(wctx: *WorkerCtx) void {
    const app = wctx.app;
    app.tui.streaming.store(true, .release);
    app.worker_active.store(true, .release);
    defer {
        app.tui.streaming.store(false, .release);
        app.worker_active.store(false, .release);
        wctx.done.store(true, .release);
    }
    // 先处理主消息(可能为 /compact),再循环投递 steering 队列
    var first = true;
    while (true) {
        if (app.abort.load(.acquire)) break;
        var line: ?[]const u8 = null;
        var is_compact = false;
        if (first) {
            line = wctx.line;
            is_compact = wctx.is_compact;
            first = false;
        } else {
            line = app.dequeue();
            if (line == null) break;
            tuiOk("tui.user", app.tui.appendUser(line.?)); // 显示排队消息
        }
        const msg = line.?;
        const n_before = app.agent.messages.items.len;
        var err_msg: ?[]const u8 = null;
        if (is_compact) {
            const summary = app.agent.compact() catch |err| blk: {
                err_msg = @errorName(err);
                break :blk "";
            };
            if (err_msg == null) {
                tuiNote(app, "\x1b[2m", "conversation compacted");
                _ = summary;
            }
        } else {
            const img = app.tui.takePendingImage();
            defer if (img) |im| app.tui.alloc.free(im.data);
            const result = (if (img) |im|
                app.agent.sendWithImage(msg, im.data, im.mime)
            else
                app.agent.send(msg)) catch |err| blk: {
                if (err == error.Aborted) {
                    // 中断:partial 已流式输出,静默收尾(保存增量照常)
                    break :blk ai.RunResult{};
                }
                err_msg = @errorName(err);
                break :blk ai.RunResult{};
            };
            if (result.error_msg) |emsg| err_msg = emsg;
            app.last_usage = result.usage;
            const u = result.usage;
            app.tokens_total += (u.input orelse 0) + (u.output orelse 0) + (u.cache_read orelse 0);
            app.tok_in += u.input orelse 0;
            app.tok_out += u.output orelse 0;
            app.tok_cache_r += u.cache_read orelse 0;
            app.tok_cache_w += u.cache_write orelse 0;
            // 远端 usage.cost 优先;没有再走本地价目。
            if (u.cost) |c| {
                app.cost_usd += c;
            } else if (pricing.lookupAny(app.agent.provider.name, app.agent.model)) |r| {
                app.cost_usd += pricing.turnCost(r, u.input orelse 0, u.output orelse 0, u.cache_read orelse 0, u.cache_write orelse 0);
            }
        }
        if (err_msg) |emsg| {
            var buf = std.array_list.Managed(u8).init(app.alloc);
            defer buf.deinit();
            tuiOk("tui.buf", buf.appendSlice("⚠ "));
            tuiOk("tui.buf", buf.appendSlice(emsg));
            tuiNote(app, "\x1b[31m", buf.items);
        } else {
            // 保存会话增量。失败要提醒(只一次,防刷屏):磁盘满/权限错时
            // 静默吞掉会让用户在重启后丢历史而不自知。
            var save_warned = false;
            for (app.agent.messages.items[n_before..]) |*m| {
                app.sess.saveMessage(m) catch |e| {
                    if (save_warned) continue;
                    save_warned = true;
                    var wbuf = std.array_list.Managed(u8).init(app.alloc);
                    defer wbuf.deinit();
                    tuiOk("tui.wbuf", wbuf.appendSlice("⚠ 会话保存失败("));
                    tuiOk("tui.wbuf", wbuf.appendSlice(@errorName(e)));
                    tuiOk("tui.wbuf", wbuf.appendSlice("),重启后可能丢失 —— 检查磁盘空间与 ~/.piz/sessions 权限"));
                    tuiNote(app, "\x1b[31m", wbuf.items);
                };
            }
        }
        app.agent.aborted.store(false, .release);
        // 发布本轮后的上下文占用:主线程状态栏经它读,不碰活 messages
        app.est_ctx.store(app.agent.estTokens(), .release);
        app.refreshFooter();
        if (err_msg != null) break; // 出错停止投递后续队列
    }
}

/// 复制文本到剪贴板:wl-copy(Wayland) → xclip(X11);均不可用返回 false。
pub fn copyToClipboard(alloc: std.mem.Allocator, text: []const u8) bool {
    const candidates = [_][]const []const u8{
        &.{"wl-copy"},
        &.{ "xclip", "-selection", "clipboard" },
    };
    for (candidates) |argv| {
        var child = std.process.spawn(util.io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch continue;
        defer {
            _ = child.wait(util.io) catch {};
        }
        // 写完必须把 stdin 关掉,否则 wl-copy/xclip 一直等 EOF,child.wait 卡死。
        //
        // 关完要把 handle 置空:`child.wait` 内部还会再关一遍
        // (Threaded.childCleanupPosix → closeFd(stdin.handle)),同一个 fd
        // 关两次拿到 EBADF,std 视为 OS bug —— Debug 构建直接
        // `unreachable`,整个 piz 崩掉。实测 /copy 必崩。
        if (child.stdin) |f| {
            var wbuf: [8192]u8 = undefined;
            var w = f.writer(util.io, &wbuf);
            if (w.interface.writeAll(text)) |_| {
                w.flush() catch {};
            } else |_| {}
            f.close(util.io);
            child.stdin = null;
        }
        return true;
    }
    _ = alloc;
    return false;
}

fn onSubmit(tui: *tui_mod.Tui, line: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(tui.ctx orelse return));
    app.tui.addHistory(line);
    // 斜杠命令
    if (line.len > 0 and line[0] == '/') {
        const cmd = line[1..];
        if (try cmd_slash.dispatch(tui, app, cmd)) return;
        {
            const space = std.mem.indexOfScalar(u8, cmd, ' ');
            const sname = if (space) |sp| cmd[0..sp] else cmd;
            const sargs = if (space) |sp| std.mem.trim(u8, cmd[sp + 1 ..], " ") else "";
            if (pluginsmod.dispatchSlash(app.agent.plugins, app.agent, sname, sargs)) |res_or_err| {
                const text = res_or_err catch {
                    tuiNote(app, "\x1b[31m", "plugin slash failed");
                    return;
                };
                defer app.alloc.free(text);
                tuiNote(app, "", text);
                return;
            }
            // JS 扩展命令(/name [args] → piz.registerCommand)。
            if (jsrt.enabled) {
                var ja = util.Arena.init(app.alloc);
                defer ja.deinit();
                if (jsrt.runCommand(ja.allocator(), sname, sargs)) |out| {
                    if (out.len > 0) tuiNote(app, "", out);
                    return;
                }
            }
        }
        // 未知斜杠命令:尝试 prompt 模板(/name [args])
        if (std.mem.indexOfScalar(u8, cmd, ' ') orelse cmd.len > 0) {
            const space = std.mem.indexOfScalar(u8, cmd, ' ');
            const tname = if (space) |sp| cmd[0..sp] else cmd;
            const targs_part = if (space) |sp| std.mem.trim(u8, cmd[sp + 1 ..], " ") else "";
            if (util.loadTemplate(app.alloc, app.agent.cwd, tname) catch null) |tpl| {
                defer app.alloc.free(tpl);
                // 参数按空格拆分(简化)
                var args = std.array_list.Managed([]const u8).init(app.alloc);
                defer args.deinit();
                var it = std.mem.splitScalar(u8, targs_part, ' ');
                while (it.next()) |a| {
                    if (a.len > 0) try args.append(a);
                }
                const rendered = try util.renderTemplate(app.alloc, tpl, args.items);
                tuiOk("tui.user", app.tui.appendUser(rendered));
                const old = app.last_line;
                app.last_line = app.alloc.dupe(u8, rendered) catch rendered;
                if (old.len > 0 and old.ptr != rendered.ptr) app.alloc.free(old);
                spawnWorker(app, rendered, false);
                return;
            }
        }
        var bw = std.Io.Writer.Allocating.init(app.alloc);
        defer bw.deinit();
        tuiOk("tui.wr", bw.writer.print("unknown command: /{s} (try /help)", .{cmd}));
        tuiNote(app, "\x1b[31m", bw.written());
        return;
    }
    // 正常消息:!cmd 运行并发送;!!cmd 运行不发送;@path 展开文件内容
    if (line.len > 1 and line[0] == '!') {
        const send_to_llm = !(line.len > 1 and line[1] == '!');
        const cmd = if (send_to_llm) line[1..] else line[2..];
        const json_args = std.fmt.allocPrint(app.alloc, "{{\"command\":{s},\"timeout\":30}}", .{util.jsonString(app.alloc, cmd) catch "\"\""}) catch {
            return;
        };
        const res: toolsmod.Result = if (toolsmod.find("bash")) |tb|
            (tb.handler(app.alloc, json_args) catch |err| toolsmod.crashResult(app.alloc, "bash", err))
        else
            .{ .content = "no bash tool", .is_error = true };
        tuiNote(app, if (res.is_error) "\x1b[31m" else "\x1b[2m", res.content);
        if (send_to_llm) {
            const msg = std.fmt.allocPrint(app.alloc, "!{s}\n\nOutput:\n{s}", .{ cmd, res.content }) catch {
                return;
            };
            tuiOk("tui.user", app.tui.appendUser(msg));
            spawnWorker(app, msg, false);
        }
        return;
    }
    const expanded = util.expandRefs(app.alloc, line, app.agent.cwd) catch line;
    const keep_img = keepPendingImage(app);
    if (app.worker_active.load(.acquire)) {
        // worker 忙:入队(steering),轮次间自动投递
        if (!app.enqueue(expanded)) {
            tuiNote(app, "\x1b[31m", "queue failed — message not queued");
            return;
        }
        var bw = std.Io.Writer.Allocating.init(app.alloc);
        defer bw.deinit();
        const head = expanded[0..@min(expanded.len, 72)];
        if (app.queue.items.len == 1)
            tuiOk("tui.wr", bw.writer.print("→ 待发  {s}", .{head}))
        else
            tuiOk("tui.wr", bw.writer.print("→ 待发 {d}  {s}", .{ app.queue.items.len, head }));
        if (keep_img) tuiOk("tui.wr", bw.writer.writeAll("  [image]"));
        tuiNote(app, "\x1b[2m", bw.written());
        return;
    }
    tuiOk("tui.user", app.tui.appendUser(shownUser(app.alloc, expanded, keep_img)));
    maybeAutoTitle(app, expanded);
    {
        var ea = util.Arena.init(app.alloc);
        defer ea.deinit();
        const ealloc = ea.allocator();
        app.events.emit("user_message", std.fmt.allocPrint(ealloc, "\"text\":{s}", .{
            try util.jsonString(ealloc, expanded[0..@min(expanded.len, 500)]),
        }) catch "");
    }
    const old = app.last_line;
    app.last_line = app.alloc.dupe(u8, expanded) catch expanded;
    if (old.len > 0 and old.ptr != expanded.ptr) app.alloc.free(old);
    spawnWorker(app, expanded, false);
}

fn maybeAutoTitle(app: *App, text: []const u8) void {
    if (app.sess.title) |cur| {
        if (cur.len > 0) return;
    }
    const t = sessionmod.deriveTitle(app.alloc, text) orelse return;
    defer app.alloc.free(t);
    app.sess.setTitle(t) catch |err| util.debugCatch("sess.title", err);
    app.refreshFooter();
}

fn keepPendingImage(app: *App) bool {
    if (!app.tui.hasPendingImage()) return false;
    if (app.agent.hasVision()) return true;
    _ = app.tui.takePendingImage();
    tuiNote(app, "\x1b[2m", "image dropped: model has no vision");
    return false;
}

fn shownUser(alloc: std.mem.Allocator, text: []const u8, has_img: bool) []const u8 {
    if (!has_img) return text;
    if (text.len == 0 or std.mem.eql(u8, text, "(image)")) return "[image]";
    return std.fmt.allocPrint(alloc, "{s}  [image]", .{text}) catch text;
}

pub fn spawnWorker(app: *App, line: []const u8, is_compact: bool) void {
    app.agent.think_level = app.tui.think_level;
    const wctx = app.alloc.create(WorkerCtx) catch return;
    wctx.* = .{ .app = app, .line = line, .is_compact = is_compact };
    const thread = std.Thread.spawn(.{}, workerMain, .{wctx}) catch {
        app.alloc.destroy(wctx);
        tuiNote(app, "\x1b[31m", "failed to spawn worker thread");
        return;
    };
    app.worker = thread;
    // 不 join:主循环退出时统一处理
}

/// Ctrl+C:中止当前一轮。
///
/// 三件事都要做,少一件用户就会觉得按了没反应:
///   1. 置 agent 的 aborted 标志 —— 下一个迭代边界停下
///   2. 取消在跑的活动 —— 长命令/退避睡眠在 100ms 内自己退出,不必等边界
///   3. 回一行确认 —— 「取消了 2 个活动」比屏幕毫无变化可信得多
fn onAbort(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    app.abort.store(true, .release);
    app.agent.aborted.store(true, .release);
    const n = activity.cancelAll();
    var buf: [96]u8 = undefined;
    const msg = if (n > 0)
        std.fmt.bufPrint(&buf, "interrupted — cancelling {d} running activity(s)", .{n}) catch "interrupted"
    else
        "interrupted";
    tuiNote(app, "\x1b[2m", msg);
}

/// Ctrl+B:把在跑的活动转后台。
///
/// 「命令卡住能知道后台」的落点。转后台后:命令继续跑到底(不再受墙钟上限约束),
/// Ctrl+C 也不再取消它,活动行标 [bg] 且 spinner 停转。
/// 当前这一轮仍会等它的结果 —— 结果要回给模型,丢掉就等于工具调用无返回,
/// OpenAI 协议下会导致下一轮请求 400。
fn onDetach(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    const n = activity.detachAll();
    var buf: [128]u8 = undefined;
    const msg = if (n > 0)
        std.fmt.bufPrint(&buf, "{d} activity(s) moved to background — no wall-clock limit, Ctrl+C won't cancel them", .{n}) catch "moved to background"
    else
        "nothing running to move to background";
    tuiNote(app, "\x1b[2m", msg);
}

fn tuiOnAbort(ctx: ?*anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    return app.abort.load(.acquire) or app.agent.aborted.load(.acquire);
}

fn isQuit(ctx: ?*anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(ctx orelse return false));
    return app.quit.load(.acquire);
}

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

    showWelcome(&app, loaded.len);
    replayTranscript(&tui, loaded);

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
