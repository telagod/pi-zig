// cmd_web.zig — Web 会话池与 piz web 命令。
const std = @import("std");
const util = @import("core").util;
const pricing = @import("core").pricing;
const cfgmod = @import("core").config;
const sandboxmod = @import("core").sandbox;
const agentmod = @import("core").agent;
const sessionmod = @import("core").session;
const pluginsmod = @import("core").plugins;
const compress = @import("core").compress;
const toolsmod = @import("core").tools;
const jsonx = @import("core").jsonx;
const mcpmod = @import("core").mcp;
const jsrt = @import("core").jsrt;
const webui_mod = @import("webui.zig");
const cmd_help = @import("cmd_help.zig");
const cmd_doctor = @import("cmd_doctor.zig");
const cmd_init = @import("cmd_init.zig");
const cmd_diff = @import("cmd_diff.zig");
const cmd_commit = @import("cmd_commit.zig");

pub fn runWebCmd(alloc: std.mem.Allocator, args: *std.process.Args.Iterator) void {
    var wopts = webui_mod.WebOptions{};
    var no_token = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--port")) {
            const v = args.next() orelse {
                std.debug.print("piz web: missing value for --port\n", .{});
                std.process.exit(1);
            };
            wopts.port = std.fmt.parseInt(u16, v, 10) catch {
                std.debug.print("piz web: bad port {s}\n", .{v});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, a, "--no-open")) {
            wopts.no_open = true;
        } else if (std.mem.eql(u8, a, "--no-token")) {
            no_token = true;
        } else if (std.mem.eql(u8, a, "--token")) {
            wopts.token = args.next() orelse {
                std.debug.print("piz web: missing value for --token\n", .{});
                std.process.exit(1);
            };
        } else {
            std.debug.print("piz web: usage: piz web [--port N] [--no-open] [--token T | --no-token]\n", .{});
            std.process.exit(1);
        }
    }

    // 默认鉴权:未指定 --token 且未 --no-token 时生成随机 token。
    // 绑定 127.0.0.1 只挡住远程,本机恶意网页仍可跨 Origin POST /api/chat 驱动 agent
    // (无 CSRF 防护),故默认必须有凭证;token 经 URL fragment 交给前端存 sessionStorage。
    // 缓冲区留余量:16 字节 hex 是 32 字符,给 64 而非刚好 32 —— 差一个字节就
    // 会让 bufPrint 失败,而失败的后果是鉴权被关掉。
    var token_buf: [64]u8 = undefined;
    if (wopts.token == null and !no_token) {
        var raw: [16]u8 = undefined;
        util.io.random(&raw);
        // fail-closed:凭证生成不了就不启动。旧写法是 `catch null`,
        // 那会静默把 Web UI 变成无鉴权的 bash 执行入口 —— 安全开关不许静默失效。
        wopts.token = std.fmt.bufPrint(&token_buf, "{x}", .{&raw}) catch {
            std.debug.print("piz web: 无法生成访问凭证,已中止启动。\n" ++
                "     需要无鉴权模式请显式加 --no-token(仅限你确认本机没有不可信程序时)。\n", .{});
            std.process.exit(1);
        };
    }

    var arena = util.Arena.init(alloc);
    defer arena.deinit();
    var cfg = cfgmod.Config{ .arena = &arena };
    cfg.load() catch {
        std.debug.print("piz: config load failed\n", .{});
        std.process.exit(1);
    };
    cfg.warnBroken();
    pluginsmod.applyFromConfig(cfg.enabled_plugins, cfg.disabled_plugins);
    const abs_cwd = std.process.currentPathAlloc(util.io, arena.allocator()) catch "";
    wopts.project_cwd = abs_cwd;
    // HTTP 线程会并发分配 SessionPool/WebServer 的 allocator(每请求拼 JSON、
    // 解析 body),裸 arena 会在并发下损坏 —— 必须走带锁的 SyncedArena。
    var sync_arena = webui_mod.SyncedArena.init(alloc);
    defer sync_arena.deinit();
    var agent = agentmod.Agent.initOpts(arena.allocator(), &cfg, null, null, abs_cwd, .{ .depth = pluginsmod.processBaseDepth() }) catch {
        std.debug.print("piz: agent init failed\n", .{});
        std.process.exit(1);
    };
    if (agent.key == null) {
        std.debug.print("piz: no API key for provider '{s}'. Set ~/.piz/auth.json, models.json apiKey, or env.\n", .{agent.provider.name});
        std.process.exit(1);
    }
    @import("core").plugins.injectMemory(&agent);

    // 事件中心用 page_allocator:push 从 HTTP 线程与 worker 线程并发调用,
    // 锁外的 allocPrint 需要线程安全分配器 —— arena 会被并发分配直接踩坏。
    var hub = webui_mod.EventHub.init(std.heap.page_allocator);
    var ws = webui_mod.WebServer.start(sync_arena.allocator(), wopts, &hub) catch |err| {
        std.debug.print("piz web: cannot listen: {t}\n", .{err});
        std.process.exit(1);
    };
    // 打印带 token 的完整 URL:--no-open 或浏览器打开失败时用户需手工复制
    if (wopts.token) |tok| {
        std.debug.print("piz web: http://127.0.0.1:{d}/#token={s}  (Ctrl+C 退出)\n", .{ ws.port, tok });
    } else {
        std.debug.print("piz web: http://127.0.0.1:{d}  (无鉴权 — 本机任意网页可驱动 agent)  (Ctrl+C 退出)\n", .{ws.port});
    }
    ws.openBrowser();

    // 启动信息落盘:发布器(piz evolve --publish)重启 web 时按原参数拉起。
    // 含 pid/token/port/PIZ_DIR;覆盖写,勿删 —— 老进程退场后残留信息无害。
    writeLaunchJson(&cfg, ws.port, wopts.token, abs_cwd) catch |e| util.debugCatch("web.launchjson", e);

    // 会话池:default 会话 + hooks(webui 端点经回调接入)
    var pool = SessionPool{
        .alloc = sync_arena.allocator(),
        .hub = &hub,
        .cfg = &cfg,
        .sessions = std.array_list.Managed(*WebSession).init(arena.allocator()),
        .workspaces = std.array_list.Managed([]const u8).init(arena.allocator()),
    };
    // 迁移旧布局会话 + 注册默认项目
    sessionmod.migrateLegacyWeb(arena.allocator(), abs_cwd);
    pool.workspaces.append(arena.allocator().dupe(u8, abs_cwd) catch "") catch |err| util.debugCatch("pool.ws", err);
    if (pool.getOrCreate("default", abs_cwd) == null) {
        std.debug.print("piz web: session init failed\n", .{});
        std.process.exit(1);
    }
    ws.state_hook = poolStateHook;
    ws.state_ctx = &pool;
    ws.history_hook = poolHistoryHook;
    ws.history_ctx = &pool;
    ws.sessions_hook = poolSessionsHook;
    ws.sessions_ctx = &pool;
    ws.chat_hook = poolChatHook;
    ws.chat_ctx = &pool;
    ws.interrupt_hook = poolInterruptHook;
    ws.interrupt_ctx = &pool;
    ws.slash_hook = poolSlashHook;
    ws.slash_ctx = &pool;
    ws.slash_catalog_hook = poolSlashCatalogHook;
    ws.mode_hook = poolModeHook;
    ws.mode_ctx = &pool;
    ws.models_hook = poolModelsHook;
    ws.models_ctx = &pool;
    ws.model_hook = poolModelHook;
    ws.model_ctx = &pool;
    ws.title_hook = poolTitleHook;
    ws.title_ctx = &pool;
    ws.action_hook = poolActionHook;
    ws.action_ctx = &pool;
    ws.config_hook = poolConfigHook;
    ws.config_ctx = &pool;
    ws.workspaces_hook = poolWorkspacesHook;
    ws.workspaces_ctx = &pool;
    ws.ws_allowed_hook = poolWsAllowed;
    ws.ws_allowed_ctx = &pool;
    ws.auth_save_hook = poolAuthSave;
    ws.auth_save_ctx = &pool;
    // JS 扩展运行时:全局目 + 服务器启动目的 .piz/extensions 一并装入。
    // 引擎单例,扩展全体会话共享;按 workspace 分装后置。
    jsrt.init(alloc);
    if (util.configDir(alloc)) |cd| {
        defer alloc.free(cd);
        pluginsmod.pushGates(alloc, pluginsmod.defaultSet());
        jsrt.loadExtensions(cd, abs_cwd);
    } else |_| {}
    // 启动即同步模型表:bg 纯取(GET /models),合账持 pool.mutex;无阻 listen。
    if (std.Thread.spawn(.{ .stack_size = 1 << 20 }, webModelsSyncThread, .{ pool.alloc, &cfg, &pool }) catch null) |th| th.detach();
    ws.run() catch |err| util.warn("web server stopped: {s}", .{@errorName(err)});
    webui_mod.ChatQueue.shutdown();
    for (pool.sessions.items) |ses| {
        ses.worker.join();
    }
    std.debug.print("\npiz web: bye\n", .{});
}

/// 会话池:每会话独立 Agent/Arena/worker(上限 4,对齐 task 工具)。
pub const WebSession = struct {
    name: []const u8,
    cwd: []const u8,
    qkey: []const u8,
    agent: *agentmod.Agent,
    hub: *webui_mod.EventHub,
    start_ns: i128,
    tokens_total: usize = 0,
    cost_usd: f64 = 0,
    snap_cost_u: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    updated_ns: i128 = 0,
    worker: std.Thread,
    /// 0=yolo 1=ask 2=read_only。默认 yolo。
    approval: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    arena: *util.Arena,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    busy: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    snap_mutex: std.Io.Mutex = .init,
    snap_history: []const u8 = "[]",
    snap_model: []const u8 = "",
    snap_msgs: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    snap_pct: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    snap_used: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    snap_window: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn writeLaunchJson(cfg: *cfgmod.Config, port: u16, token: ?[]const u8, cwd: []const u8) !void {
    const alloc = cfg.allocator();
    const p = try util.joinPath(alloc, try util.configDir(alloc), "web.launch.json");
    const pid = std.os.linux.getpid();
    var w = std.Io.Writer.Allocating.init(alloc);
    defer w.deinit();
    const wr = &w.writer;
    try wr.print("{{\"pid\":{d},\"port\":{d},\"cwd\":{s},\"token\":{s},\"piz_dir\":{s}}}", .{
        pid,
        port,
        try util.jsonString(alloc, cwd),
        if (token) |t| try util.jsonString(alloc, t) else "null",
        try util.jsonString(alloc, try util.configDir(alloc)),
    });
    try util.writeFile(p, try w.toOwnedSlice());
}

fn sessionApproval(ses: *WebSession) cfgmod.ApprovalMode {
    return switch (ses.approval.load(.acquire)) {
        @intFromEnum(cfgmod.ApprovalMode.ask) => .ask,
        @intFromEnum(cfgmod.ApprovalMode.read_only) => .read_only,
        else => .yolo,
    };
}

fn sessionIsYolo(ses: *const WebSession) bool {
    return ses.approval.load(.acquire) == @intFromEnum(cfgmod.ApprovalMode.yolo);
}

fn setSessionApproval(ses: *WebSession, mode: cfgmod.ApprovalMode) void {
    ses.approval.store(@intFromEnum(mode), .release);
}

/// web 启动模型表同步:bg 逐 provider 取(GET /models,独立 arena,快照名/址/钥——
/// upsertProvider 可 append 重排 providers,持指针穿越 HTTP 是 UAF),合账持 pool.mutex
/// 并按名重找。无阻 listen;败者静默计数,末了一行 stderr。
fn webModelsSyncThread(alloc: std.mem.Allocator, cfg: *cfgmod.Config, pool: *SessionPool) void {
    var arena = util.Arena.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Snap = struct { name: []const u8, base: []const u8, key: []const u8 };
    var snaps = std.array_list.Managed(Snap).init(a);
    pool.mutex.lock(util.io) catch {};
    for (cfg.providers) |*p| {
        const key = p.api_key orelse continue;
        snaps.append(.{
            .name = a.dupe(u8, p.name) catch continue,
            .base = a.dupe(u8, p.base_url) catch continue,
            .key = a.dupe(u8, key) catch continue,
        }) catch {};
    }
    pool.mutex.unlock(util.io);
    var ok: usize = 0;
    var added: usize = 0;
    var fail: usize = 0;
    for (snaps.items) |s| {
        const stub = cfgmod.Provider{ .name = s.name, .api = .openai_completions, .base_url = s.base, .api_key = s.key };
        const found = cfgmod.fetchDiscovered(a, &stub) catch {
            fail += 1;
            continue;
        };
        pool.mutex.lock(util.io) catch {};
        for (cfg.providers) |*p| {
            if (!std.mem.eql(u8, p.name, s.name)) continue;
            added += cfgmod.mergeDiscovered(p, alloc, found) catch 0;
            break;
        }
        pool.mutex.unlock(util.io);
        ok += 1;
    }
    if (ok + fail > 0)
        std.debug.print("piz web: 模型表已同步 {d} 供应商,+{d} 模型,{d} 取败\n", .{ ok, added, fail });
}

pub const SessionPool = struct {
    alloc: std.mem.Allocator,
    hub: *webui_mod.EventHub,
    cfg: *cfgmod.Config,
    mutex: std.Io.Mutex = .init,
    sessions: std.array_list.Managed(*WebSession),
    workspaces: std.array_list.Managed([]const u8),

    pub fn getOrCreate(self: *SessionPool, name: []const u8, cwd: []const u8) ?*WebSession {
        self.mutex.lock(util.io) catch return null;
        defer self.mutex.unlock(util.io);
        for (self.sessions.items) |ses| {
            if (std.mem.eql(u8, ses.name, name) and std.mem.eql(u8, ses.cwd, cwd)) return ses;
        }
        if (self.sessions.items.len >= 4) return null;
        const ses_arena = self.alloc.create(util.Arena) catch return null;
        ses_arena.* = util.Arena.init(self.alloc);
        const a = ses_arena.allocator();
        const abs_cwd = a.dupe(u8, cwd) catch return null;
        const agent = a.create(agentmod.Agent) catch return null;
        agent.* = agentmod.Agent.initOpts(a, self.cfg, null, null, abs_cwd, .{ .depth = pluginsmod.processBaseDepth() }) catch return null;
        if (agent.key == null) return null;
        @import("core").plugins.injectMemory(agent);
        var restored_approval: cfgmod.ApprovalMode = self.cfg.default_approval;
        var restored_updated: i128 = 0;
        if (sessionmod.loadWeb(a, abs_cwd, name) catch null) |web_ses| {
            for (web_ses.msgs) |m| {
                agent.messages.append(m) catch |err| util.debugCatch("loadWeb.append", err);
            }
            restored_approval = if (web_ses.auto) .yolo else .ask;
            restored_updated = web_ses.updated;
            if (web_ses.title) |t| agent.title = t;
            if (web_ses.model) |m| {
                if (self.cfg.findModel(m) != null) {
                    agent.switchModel(m) catch |err| util.debugCatch("loadWeb.switchModel", err);
                }
            }
        }
        const ses = a.create(WebSession) catch return null;
        const qkey = std.fmt.allocPrint(a, "{s}\x1f{s}", .{ abs_cwd, name }) catch return null;
        ses.* = .{
            .name = a.dupe(u8, name) catch return null,
            .cwd = abs_cwd,
            .qkey = qkey,
            .agent = agent,
            .hub = self.hub,
            .start_ns = std.Io.Clock.now(.real, util.io).nanoseconds,
            .updated_ns = restored_updated,
            .worker = undefined,
            .approval = std.atomic.Value(u8).init(@intFromEnum(restored_approval)),
            .arena = ses_arena,
        };
        agent.cbs = .{
            .ctx = ses,
            .on_text = webOnText,
            .on_reasoning = webOnReasoning,
            .on_tool_start = webOnToolStart,
            .on_tool_end = webOnToolEnd,
            .on_require_permission = webOnPermission,
            .on_turn_end = webOnTurnEnd,
            .on_abort = webOnAbort,
            .on_connect = webOnConnect,
            .on_subagent = webOnSubagent,
            .on_compact = webOnCompact,
        };
        rebuildSnap(ses);
        ses.worker = std.Thread.spawn(.{}, webWorker, .{ses}) catch return null;
        self.sessions.append(ses) catch return null;
        return ses;
    }

    fn detachAndDestroy(self: *SessionPool, name: []const u8, cwd: []const u8) void {
        var victim: ?*WebSession = null;
        self.mutex.lock(util.io) catch return;
        for (self.sessions.items, 0..) |ses, i| {
            if (std.mem.eql(u8, ses.name, name) and std.mem.eql(u8, ses.cwd, cwd)) {
                victim = self.sessions.swapRemove(i);
                break;
            }
        }
        self.mutex.unlock(util.io);
        const ses = victim orelse return;
        ses.stopping.store(true, .release);
        ses.agent.aborted.store(true, .release);
        ses.worker.join();
        const arena = ses.arena;
        arena.deinit();
        self.alloc.destroy(arena);
    }
};

fn addSessionCost(ses: *WebSession, u: @import("core").ai.Usage) void {
    const add = u.cost orelse blk: {
        const r = pricing.lookupAny(ses.agent.provider.name, ses.agent.model) orelse return;
        break :blk pricing.turnCost(r, u.input orelse 0, u.output orelse 0, u.cache_read orelse 0, u.cache_write orelse 0);
    };
    ses.cost_usd += add;
    const micro: u64 = @intFromFloat(@round(@max(ses.cost_usd, 0) * 1_000_000.0));
    ses.snap_cost_u.store(micro, .release);
}

const ToolMeta = struct { name: []const u8, args: []const u8 };

fn toolMetaFor(msgs: anytype, idx: usize, call_id: ?[]const u8) ToolMeta {
    const id = call_id orelse return .{ .name = "tool", .args = "" };
    var j = idx;
    while (j > 0) {
        j -= 1;
        if (msgs[j].tool_calls) |tcs| {
            for (tcs) |tc| {
                if (std.mem.eql(u8, tc.id, id) and tc.name.len > 0) return .{ .name = tc.name, .args = tc.args };
            }
        }
        if (std.mem.eql(u8, msgs[j].role, "user")) break;
    }
    return .{ .name = "tool", .args = "" };
}

const HIST_KEEP: usize = 80;
const HIST_PAGE_MAX: usize = 200;

fn jw(comptime where: []const u8, result: anyerror!void) void {
    result catch |err| util.debugCatch(where, err);
}

pub fn writeHistoryRange(w: *std.Io.Writer, a: std.mem.Allocator, msgs: []const @import("core").ai.Message, start: usize, end: usize) void {
    jw("hist.ob", w.writeAll("["));
    var first = true;
    var i = start;
    while (i < end and i < msgs.len) : (i += 1) {
        const m = &msgs[i];
        const rsn = if (m.reasoning) |r| r else "";
        if (m.content.len == 0 and rsn.len == 0 and std.mem.eql(u8, m.role, "assistant")) continue;
        if (!first) jw("hist.comma", w.writeAll(","));
        first = false;
        const content = util.utf8Prefix(m.content, 16 * 1024);
        jw("hist.row", w.print("{{\"role\":{s},\"content\":{s}", .{ util.jsonString(a, m.role) catch "\"\"", util.jsonString(a, content) catch "\"\"" }));
        if (content.len < m.content.len) jw("hist.trunc", w.writeAll(",\"truncated\":true"));
        if (rsn.len > 0) {
            jw("hist.rsn", w.print(",\"reasoning\":{s}", .{util.jsonString(a, util.utf8Prefix(rsn, 8 * 1024)) catch "\"\""}));
        }
        if (std.mem.eql(u8, m.role, "tool")) {
            const meta = toolMetaFor(msgs, i, m.tool_call_id);
            jw("hist.tool", w.print(",\"name\":{s},\"args\":{s}", .{ util.jsonString(a, meta.name) catch "\"tool\"", util.jsonString(a, meta.args) catch "\"\"" }));
        }
        if (m.image != null or m.image_file != null) jw("hist.img", w.writeAll(",\"has_image\":true"));
        if (m.image_file) |f| {
            jw("hist.imgf", w.print(",\"image_file\":{s}", .{util.jsonString(a, f) catch "\"\""}));
        } else if (m.image) |img| {
            if (sessionmod.persistImageFile(a, img, m.image_mime)) |f| {
                jw("hist.imgn", w.print(",\"image_file\":{s}", .{util.jsonString(a, f) catch "\"\""}));
            }
        }
        jw("hist.close", w.writeAll("}"));
    }
    jw("hist.cb", w.writeAll("]"));
}

fn rebuildSnap(ses: *WebSession) void {
    const a = ses.agent.alloc;
    const ag = ses.agent;
    var stw = std.Io.Writer.Allocating.init(a);
    defer stw.deinit();
    const w = &stw.writer;
    const msgs = ag.messages.items;
    // jsonl 是真源;snap 只是给页面的窗口,勿再砍成 300 字节让刷新像没存过。
    const hist_start = if (msgs.len > HIST_KEEP) msgs.len - HIST_KEEP else 0;
    writeHistoryRange(w, a, msgs, hist_start, msgs.len);
    const history = stw.toOwnedSlice() catch return;
    const model = a.dupe(u8, ag.model) catch return;
    const cw = ag.ctxWindow();
    const used = ag.estTokens();
    const pct: u32 = @intCast(if (cw > 0) @min(used * 100 / cw, 100) else 0);
    ses.snap_mutex.lock(util.io) catch return;
    ses.snap_history = history;
    ses.snap_model = model;
    ses.snap_pct.store(pct, .release);
    ses.snap_used.store(@intCast(@min(used, std.math.maxInt(u32))), .release);
    ses.snap_window.store(@intCast(@min(cw, std.math.maxInt(u32))), .release);
    ses.snap_msgs.store(@intCast(@min(msgs.len, std.math.maxInt(u32))), .release);
    ses.snap_mutex.unlock(util.io);
}

fn webOnAbort(ctx: ?*anyopaque) bool {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    return s.agent.aborted.load(.acquire);
}
fn webOnConnect(ctx: ?*anyopaque, fd: std.posix.fd_t) void {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    s.agent.cur_stream_fd.store(@intCast(fd), .release);
}

fn poolSessionsHook(ctx: ?*anyopaque, cwd: []const u8, alloc: std.mem.Allocator) []const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    var stw = std.Io.Writer.Allocating.init(alloc);
    defer stw.deinit();
    const w = &stw.writer;
    jw("sess.ob", w.print("[", .{}));
    var first = true;
    pool.mutex.lock(util.io) catch return "[]";
    for (pool.sessions.items) |ses| {
        if (!std.mem.eql(u8, ses.cwd, cwd2)) continue;
        if (!first) jw("sess.comma", w.print(",", .{}));
        first = false;
        ses.snap_mutex.lock(util.io) catch return "[]";
        const snap_model = ses.snap_model;
        ses.snap_mutex.unlock(util.io);
        jw("sess.row", w.print("{{\"name\":{s},\"msgs\":{d},\"pct\":{d},\"model\":{s},\"auto\":{s},\"title\":{s},\"ts\":{d}}}", .{
            util.jsonString(alloc, ses.name) catch "\"\"",
            ses.snap_msgs.load(.acquire),
            ses.snap_pct.load(.acquire),
            util.jsonString(alloc, snap_model) catch "\"\"",
            if (sessionIsYolo(ses)) "true" else "false",
            util.jsonString(alloc, ses.agent.title orelse "") catch "\"\"",
            @divTrunc(ses.updated_ns, std.time.ns_per_ms),
        }));
    }
    pool.mutex.unlock(util.io);
    if (sessionmod.listWebNames(alloc, cwd2) catch null) |disk_names| {
        for (disk_names) |dname| {
            if (std.mem.eql(u8, dname, "default")) continue;
            var in_active = false;
            pool.mutex.lock(util.io) catch continue;
            for (pool.sessions.items) |ses| {
                if (std.mem.eql(u8, ses.name, dname)) {
                    in_active = true;
                    break;
                }
            }
            pool.mutex.unlock(util.io);
            if (in_active) continue;
            var count: usize = 0;
            const dir = sessionmod.webDirPublic(alloc, cwd2) catch continue;
            defer alloc.free(dir);
            const dname_file = std.fmt.allocPrint(alloc, "{s}.jsonl", .{dname}) catch continue;
            defer alloc.free(dname_file);
            const path = util.joinPath(alloc, dir, dname_file) catch continue;
            defer alloc.free(path);
            if (std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(64 * 1024 * 1024))) |content| {
                defer alloc.free(content);
                var meta_model: []const u8 = "";
                var meta_title: []const u8 = "";
                var meta_ts: i128 = 0;
                var lines = std.mem.splitScalar(u8, content, '\n');
                if (lines.next()) |first_line| {
                    if (std.json.parseFromSliceLeaky(std.json.Value, alloc, first_line, .{})) |meta| {
                        if (meta == .object) {
                            if (meta.object.get("model")) |v| {
                                if (v == .string) meta_model = alloc.dupe(u8, v.string) catch "";
                            }
                            if (meta.object.get("title")) |v| {
                                if (v == .string) meta_title = alloc.dupe(u8, v.string) catch "";
                            }
                            if (meta.object.get("updated")) |v| {
                                if (v == .integer) meta_ts = v.integer;
                            }
                        }
                    } else |_| {}
                }
                while (lines.next()) |l| {
                    if (std.mem.trim(u8, l, " \t\r\n").len > 0) count += 1;
                }
                if (!first) jw("sess.dcomma", w.print(",", .{}));
                first = false;
                jw("sess.disk", w.print("{{\"name\":{s},\"msgs\":{d},\"pct\":0,\"model\":{s},\"auto\":true,\"title\":{s},\"ts\":{d},\"disk\":true}}", .{
                    util.jsonString(alloc, dname) catch "\"\"",
                    count,
                    util.jsonString(alloc, meta_model) catch "\"\"",
                    util.jsonString(alloc, meta_title) catch "\"\"",
                    meta_ts,
                }));
            } else |_| {}
        }
        if (sessionmod.listWebArchived(alloc, cwd2) catch null) |arch_names| {
            for (arch_names) |dname| {
                if (!first) jw("sess.acomma", w.print(",", .{}));
                first = false;
                jw("sess.arch", w.print("{{\"name\":{s},\"msgs\":0,\"pct\":0,\"model\":\"\",\"auto\":true,\"title\":\"\",\"ts\":0,\"archived\":true}}", .{
                    util.jsonString(alloc, dname) catch "\"\"",
                }));
            }
        }
    }
    jw("sess.cb", w.print("]", .{}));
    return stw.toOwnedSlice() catch "[]";
}

fn poolStateHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8, alloc: std.mem.Allocator) []const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    var found: ?*WebSession = null;
    pool.mutex.lock(util.io) catch return "{}";
    for (pool.sessions.items) |ses| {
        if (std.mem.eql(u8, ses.name, session) and std.mem.eql(u8, ses.cwd, cwd2)) {
            found = ses;
            break;
        }
    }
    pool.mutex.unlock(util.io);
    const ses = found orelse (pool.getOrCreate(session, cwd2) orelse return "{}");
    ses.snap_mutex.lock(util.io) catch return "{}";
    const snap_history = ses.snap_history;
    const snap_model = ses.snap_model;
    ses.snap_mutex.unlock(util.io);
    var stw = std.Io.Writer.Allocating.init(alloc);
    defer stw.deinit();
    const w = &stw.writer;
    jw("state.head", w.print("{{\"model\":{s},\"auto\":{s},\"mode\":{s},\"title\":{s},\"think\":{s},\"vision\":{s}", .{
        util.jsonString(alloc, snap_model) catch "\"\"",
        if (sessionIsYolo(ses)) "true" else "false",
        util.jsonString(alloc, sessionApproval(ses).label()) catch "\"yolo\"",
        util.jsonString(alloc, ses.agent.title orelse "") catch "\"\"",
        util.jsonString(alloc, ses.agent.think_level.label()) catch "\"\"",
        if (ses.agent.hasVision()) "true" else "false",
    }));
    const cost = @as(f64, @floatFromInt(ses.snap_cost_u.load(.acquire))) / 1_000_000.0;
    const hist_total = ses.snap_msgs.load(.acquire);
    const keep: u32 = HIST_KEEP;
    const hist_start: u32 = if (hist_total > keep) hist_total - keep else 0;
    jw("state.mid", w.print(",\"pct\":{d},\"used\":{d},\"window\":{d},\"cost\":{d:.6},\"running\":{s},\"history\":{s},\"hist_start\":{d},\"hist_total\":{d}", .{
        ses.snap_pct.load(.acquire),
        ses.snap_used.load(.acquire),
        ses.snap_window.load(.acquire),
        cost,
        if (ses.agent.cur_stream_fd.load(.acquire) >= 0) "true" else "false",
        snap_history,
        hist_start,
        hist_total,
    }));
    const raw_base = std.fs.path.basename(cwd2);
    const base = if (raw_base.len > 0) raw_base else cwd2;
    jw("state.ws", w.print(",\"ws\":{s}", .{util.jsonString(alloc, base) catch "\"\""}));
    var br_buf: [128]u8 = undefined;
    if (cmd_diff.currentBranchBuf(cwd2, &br_buf)) |br| {
        jw("state.branch", w.print(",\"branch\":{s}", .{util.jsonString(alloc, br) catch "\"\""}));
    }
    if (cmd_diff.statusBrief(alloc, cwd2)) |st| {
        if (st.ahead > 0) jw("state.ahead", w.print(",\"ahead\":{d}", .{st.ahead}));
        if (st.behind > 0) jw("state.behind", w.print(",\"behind\":{d}", .{st.behind}));
        if (st.changes > 0) jw("state.changes", w.print(",\"changes\":{d}", .{st.changes}));
    }
    jw("state.end", w.writeAll("}"));
    return stw.toOwnedSlice() catch "{}";
}

fn poolHistoryHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8, offset: usize, limit: usize, alloc: std.mem.Allocator) []const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    const cap = if (limit == 0 or limit > HIST_PAGE_MAX) HIST_KEEP else limit;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const loaded = sessionmod.loadWeb(a, cwd2, session) catch return "{\"start\":0,\"total\":0,\"history\":[]}";
    const pack = loaded orelse return "{\"start\":0,\"total\":0,\"history\":[]}";
    const msgs = pack.msgs;
    const start = @min(offset, msgs.len);
    const end = @min(start + cap, msgs.len);
    var stw = std.Io.Writer.Allocating.init(a);
    stw.writer.print("{{\"start\":{d},\"total\":{d},\"history\":", .{ start, msgs.len }) catch return "{\"start\":0,\"total\":0,\"history\":[]}";
    writeHistoryRange(&stw.writer, a, msgs, start, end);
    jw("hist.wrap", stw.writer.writeAll("}"));
    return alloc.dupe(u8, stw.written()) catch "{\"start\":0,\"total\":0,\"history\":[]}";
}

fn webWorker(ses: *WebSession) void {
    while (true) {
        const item = webui_mod.ChatQueue.dequeue(ses.qkey, &ses.stopping) orelse break;
        const keep_img = item.image != null and ses.agent.hasVision();
        const img_file = if (keep_img) sessionmod.persistImageFile(ses.agent.alloc, item.image.?, if (item.mime.len > 0) item.mime else null) else null;
        // keep_img: 模型无 vision 则丢图并通知
        if (item.image != null and !keep_img) {
            ses.hub.push("{{\"type\":\"notice\",\"session\":{s},\"text\":\"image dropped: model has no vision\"}}", .{
                util.jsonString(ses.agent.alloc, ses.name) catch "\"\"",
            });
        }
        ses.hub.push("{{\"type\":\"user_message\",\"session\":{s},\"text\":{s},\"has_image\":{s},\"image_file\":{s}}}", .{
            util.jsonString(ses.agent.alloc, ses.name) catch "\"\"",
            util.jsonString(ses.agent.alloc, item.text) catch "\"\"",
            if (keep_img) "true" else "false",
            util.jsonString(ses.agent.alloc, img_file orelse "") catch "\"\"",
        });
        const text = ses.agent.alloc.dupe(u8, item.text) catch null;
        const img = if (item.image) |im| ses.agent.alloc.dupe(u8, im) catch null else null;
        const mime = if (item.mime.len > 0) ses.agent.alloc.dupe(u8, item.mime) catch "" else "";
        const a = std.heap.page_allocator;
        a.free(item.session);
        if (text != null) a.free(item.text);
        if (item.image) |im| a.free(im);
        if (item.mime.len > 0) a.free(item.mime);
        while (ses.busy.cmpxchgWeak(0, 1, .acq_rel, .acquire) != null) {
            if (ses.stopping.load(.acquire)) break;
            std.Io.sleep(util.io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
        }
        if (ses.stopping.load(.acquire)) break;
        defer ses.busy.store(0, .release);
        ses.agent.aborted.store(false, .release);
        ses.updated_ns = std.Io.Clock.now(.real, util.io).nanoseconds;
        const result = if (img) |im|
            ses.agent.sendWithImage(text orelse item.text, im, mime) catch null
        else
            ses.agent.send(text orelse item.text) catch null;
        if (result) |r| {
            const u = r.usage;
            ses.tokens_total += (u.input orelse 0) + (u.output orelse 0) + (u.cache_read orelse 0);
            ses.agent.last_usage = u;
            addSessionCost(ses, u);
        }
        if (ses.agent.title == null or ses.agent.title.?.len == 0) {
            if (sessionmod.deriveTitle(ses.agent.alloc, text orelse item.text)) |t| {
                ses.agent.title = t;
                ses.hub.push("{{\"type\":\"title\",\"session\":{s},\"title\":{s}}}", .{
                    util.jsonString(ses.agent.alloc, ses.name) catch "\"\"",
                    util.jsonString(ses.agent.alloc, t) catch "\"\"",
                });
            }
        }
        sessionmod.saveWebTs(ses.agent.alloc, ses.cwd, ses.name, ses.agent.model, sessionIsYolo(ses), ses.agent.title, ses.agent.messages.items, ses.updated_ns) catch |err| {
            const msg = std.fmt.allocPrint(ses.agent.alloc, "会话保存失败({s}):本轮内容在重启后会丢失", .{@errorName(err)}) catch "session save failed";
            util.errLog(ses.agent.alloc, "web-save", ses.name, msg);
            ses.hub.push("{{\"type\":\"notice\",\"session\":{s},\"text\":{s}}}", .{ util.jsonString(ses.agent.alloc, ses.name) catch "\"\"", util.jsonString(ses.agent.alloc, msg) catch "\"\"" });
        };
        rebuildSnap(ses);
        ses.hub.push("{{\"type\":\"turn_end\",\"session\":{s}}}", .{util.jsonString(ses.agent.alloc, ses.name) catch "\"\""});
    }
}

fn webOnText(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    s.hub.push("{{\"type\":\"message\",\"session\":{s},\"text\":{s}}}", .{ try util.jsonString(s.agent.alloc, s.name), try util.jsonString(s.agent.alloc, text) });
}
fn webOnReasoning(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    s.hub.push("{{\"type\":\"reasoning\",\"session\":{s},\"text\":{s}}}", .{ try util.jsonString(s.agent.alloc, s.name), try util.jsonString(s.agent.alloc, text) });
}
fn webOnCompact(ctx: ?*anyopaque, summary: []const u8, folded: usize, kept: usize) anyerror!void {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    s.hub.push("{{\"type\":\"checkpoint\",\"session\":{s},\"summary\":{s},\"folded\":{d},\"kept\":{d}}}", .{
        try util.jsonString(s.agent.alloc, s.name),
        try util.jsonString(s.agent.alloc, summary),
        folded,
        kept,
    });
}
fn webOnSubagent(ctx: ?*anyopaque, idx: usize, kind: agentmod.SubagentEvent, text: []const u8) anyerror!void {
    switch (kind) {
        .text, .reasoning => return,
        else => {},
    }
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    const clipped = util.clampUtf8(text, 200);
    s.hub.push("{{\"type\":\"subagent\",\"session\":{s},\"idx\":{d},\"kind\":{s},\"text\":{s}}}", .{
        try util.jsonString(s.agent.alloc, s.name),
        idx,
        try util.jsonString(s.agent.alloc, @tagName(kind)),
        try util.jsonString(s.agent.alloc, clipped),
    });
}
fn webOnToolStart(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!void {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    // workflow 的 args 是 goal+节点数组,整体 JSON 常超 500 字:硬截断会把
    // JSON 切成两半,前端 parseToolArgs 失败 → 工作流卡 nodes/goal 全空
    // (客实测「workflow 显示不正常」)。workflow 发精简 args(id/role/needs/goal),
    // 其余工具保持旧截断。
    var brief: []const u8 = args;
    if (std.mem.eql(u8, name, "workflow")) {
        brief = briefWorkflowArgs(s.agent.alloc, args) catch args;
    }
    const short_args = if (brief.len > 500 and !std.mem.eql(u8, name, "workflow")) brief[0..500] else brief;
    s.hub.push("{{\"type\":\"tool_call\",\"session\":{s},\"name\":{s},\"args\":{s}}}", .{
        try util.jsonString(s.agent.alloc, s.name),
        try util.jsonString(s.agent.alloc, name),
        try util.jsonString(s.agent.alloc, short_args),
    });
}

/// workflow args → 精简 JSON(仅 goal + nodes[id/role/needs])。
fn briefWorkflowArgs(alloc: std.mem.Allocator, args: []const u8) ![]const u8 {
    if (args.len == 0) return args;
    const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, args, .{}) catch return args;
    if (v != .object) return args;
    const goal = jsonx.jsonStr(v, "goal") orelse "";
    const nv = v.object.get("nodes") orelse v.object.get("steps") orelse return args;
    if (nv != .array) return args;
    var w = std.Io.Writer.Allocating.init(alloc);
    defer w.deinit();
    try w.writer.writeAll("{\"goal\":");
    try w.writer.print("{s},\"nodes\":[", .{try util.jsonString(alloc, goal)});
    for (nv.array.items, 0..) |item, i| {
        if (i > 0) try w.writer.writeByte(',');
        if (item != .object) continue;
        const id = jsonx.jsonStr(item, "id") orelse "";
        const role = jsonx.jsonStr(item, "role") orelse "";
        try w.writer.writeAll("{\"id\":");
        try w.writer.print("{s}", .{try util.jsonString(alloc, id)});
        if (role.len > 0) {
            try w.writer.writeAll(",\"role\":");
            try w.writer.print("{s}", .{try util.jsonString(alloc, role)});
        }
        const needs_v = item.object.get("needs") orelse item.object.get("deps");
        if (needs_v) |nm| {
            if (nm == .array) {
                try w.writer.writeAll(",\"needs\":[");
                for (nm.array.items, 0..) |nd, k| {
                    if (k > 0) try w.writer.writeByte(',');
                    if (nd == .string) try w.writer.print("{s}", .{try util.jsonString(alloc, nd.string)});
                }
                try w.writer.writeByte(']');
            }
        }
        try w.writer.writeByte('}');
    }
    try w.writer.writeAll("]}");
    return w.toOwnedSlice() catch args;
}
/// 工具权限:yolo 放行;read-only 拒危险工具;ask → 浏览器确认卡。
fn webOnPermission(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!bool {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    switch (toolsmod.toolGate(sessionApproval(s), name)) {
        .allow => return true,
        .deny => return false,
        .ask => {},
    }
    const id = webui_mod.PermGate.submit(name, args);
    if (id == 0) return false;
    s.hub.push("{{\"type\":\"permission\",\"session\":{s},\"id\":{d},\"name\":{s},\"args\":{s}}}", .{ try util.jsonString(s.agent.alloc, s.name), id, try util.jsonString(s.agent.alloc, name), try util.jsonString(s.agent.alloc, args) });
    return webui_mod.PermGate.waitResult(id);
}
fn webOnToolEnd(ctx: ?*anyopaque, name: []const u8, is_error: bool, summary: []const u8) anyerror!void {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    const short = if (summary.len > 2000) summary[0..2000] else summary;
    s.hub.push("{{\"type\":\"tool_result\",\"session\":{s},\"name\":{s},\"error\":{s},\"summary\":{s}}}", .{ try util.jsonString(s.agent.alloc, s.name), try util.jsonString(s.agent.alloc, name), if (is_error) "true" else "false", try util.jsonString(s.agent.alloc, short) });
}
fn webOnTurnEnd(ctx: ?*anyopaque) anyerror!void {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    s.agent.cur_stream_fd.store(-1, .release);
    const cw = s.agent.ctxWindow();
    const used = s.agent.estTokens();
    const pct = if (cw > 0) @min(used * 100 / cw, 100) else 0;
    var cache_pct: usize = 0;
    if (s.agent.last_usage.cache_read) |cr| {
        const tot = cr + (s.agent.last_usage.cache_write orelse 0) + (s.agent.last_usage.input orelse 0);
        if (tot > 0) cache_pct = cr * 100 / tot;
    }
    const now_ns = std.Io.Clock.now(.real, util.io).nanoseconds;
    const el = @max(1, @divTrunc(now_ns - s.start_ns, std.time.ns_per_s));
    const tps = s.tokens_total / @as(usize, @intCast(el));
    const cost = @as(f64, @floatFromInt(s.snap_cost_u.load(.acquire))) / 1_000_000.0;
    s.hub.push("{{\"type\":\"status\",\"pct\":{d},\"used\":{d},\"window\":{d},\"cost\":{d:.6},\"model\":{s},\"cache\":{d},\"tps\":{d},\"think\":{s}}}", .{
        pct,
        used,
        cw,
        cost,
        try util.jsonString(s.agent.alloc, s.agent.model),
        cache_pct,
        tps,
        try util.jsonString(s.agent.alloc, s.agent.think_level.label()),
    });
}

fn poolInterruptHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8) void {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    pool.mutex.lock(util.io) catch return;
    for (pool.sessions.items) |ses| {
        if (std.mem.eql(u8, ses.name, session) and std.mem.eql(u8, ses.cwd, cwd2)) {
            ses.agent.aborted.store(true, .release);
            const fd = ses.agent.cur_stream_fd.load(.acquire);
            if (fd >= 0) {
                _ = std.posix.system.shutdown(@intCast(fd), 0);
            }
            break;
        }
    }
    pool.mutex.unlock(util.io);
}

fn poolSlashHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8, name: []const u8, args: []const u8, out: *std.Io.Writer) bool {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx orelse return false));
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    const ses = pool.getOrCreate(session, cwd2) orelse return false;
    if (std.mem.eql(u8, name, "doctor")) {
        const plugs = pluginsmod.enabledOptionalLine(ses.agent.alloc, ses.agent.plugins) catch "";
        const sb = sandboxmod.describe(ses.agent.alloc, pool.cfg.default_sandbox) catch pool.cfg.default_sandbox.label();
        const key = ses.agent.key orelse "";
        const text = cmd_doctor.format(ses.agent.alloc, .{
            .version = "0.1.0",
            .cwd = if (cwd2.len > 0) cwd2 else ses.agent.cwd,
            .provider = ses.agent.provider.name,
            .model = ses.agent.model,
            .has_key = key.len > 0,
            .think = "",
            .approval = pool.cfg.default_approval.label(),
            .sandbox_mode = sb,
            .plugins = plugs,
        }) catch return false;
        defer ses.agent.alloc.free(text);
        out.writeAll(text) catch return false;
        return true;
    }
    if (std.mem.eql(u8, name, "reload")) {
        const text = pool.cfg.reloadSettings() catch return false;
        setSessionApproval(ses, pool.cfg.default_approval);
        if (pool.cfg.default_think_level) |lv| {
            ses.agent.think_level = cfgmod.clampThinkLevel(ses.agent.modelMeta(), lv);
        }
        out.writeAll(text) catch return false;
        return true;
    }
    if (std.mem.eql(u8, name, "mcp")) {
        const text = mcpmod.formatStatus(ses.agent.alloc) catch return false;
        defer ses.agent.alloc.free(text);
        out.writeAll(text) catch return false;
        return true;
    }
    if (std.mem.eql(u8, name, "branch")) {
        const root = if (cwd2.len > 0) cwd2 else ses.agent.cwd;
        const text = cmd_diff.formatBranch(ses.agent.alloc, root) catch return false;
        defer ses.agent.alloc.free(text);
        out.writeAll(text) catch return false;
        return true;
    }
    if (std.mem.eql(u8, name, "log")) {
        const root = if (cwd2.len > 0) cwd2 else ses.agent.cwd;
        const text = cmd_diff.formatLog(ses.agent.alloc, root, cmd_diff.parseLogCount(args)) catch return false;
        defer ses.agent.alloc.free(text);
        out.writeAll(text) catch return false;
        return true;
    }
    if (std.mem.eql(u8, name, "commit")) {
        const root = if (cwd2.len > 0) cwd2 else ses.agent.cwd;
        const text = cmd_commit.run(ses.agent.alloc, root, args) catch return false;
        defer ses.agent.alloc.free(text);
        out.writeAll(text) catch return false;
        return true;
    }
    if (std.mem.eql(u8, name, "diff")) {
        const root = if (cwd2.len > 0) cwd2 else ses.agent.cwd;
        const text = cmd_diff.format(ses.agent.alloc, root) catch return false;
        defer ses.agent.alloc.free(text);
        out.writeAll(text) catch return false;
        return true;
    }
    if (std.mem.eql(u8, name, "init")) {
        const root = if (cwd2.len > 0) cwd2 else ses.agent.cwd;
        const text = cmd_init.writeAgents(ses.agent.alloc, root) catch return false;
        defer ses.agent.alloc.free(text);
        out.writeAll(text) catch return false;
        return true;
    }
    const res = pluginsmod.dispatchSlash(ses.agent.plugins, ses.agent, name, args) orelse {
        // JS 扩展命令(注册于 QuickJS 运行时)。
        if (jsrt.enabled) {
            var ja = util.Arena.init(ses.agent.alloc);
            defer ja.deinit();
            if (jsrt.runCommand(ja.allocator(), name, args, ses.agent.jsStatsJson(ja.allocator()))) |text| {
                out.writeAll(text) catch return false;
                return true;
            }
        }
        return false;
    };
    const text = res catch return false;
    defer ses.agent.alloc.free(text);
    out.writeAll(text) catch return false;
    return true;
}

fn poolSlashCatalogHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8, out: []cmd_help.HelpItem) usize {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx orelse return 0));
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    const ses = pool.getOrCreate(session, cwd2) orelse return 0;
    var plug: [32]pluginsmod.SlashCommand = undefined;
    const n = pluginsmod.collectSlash(ses.agent.plugins, &plug);
    var i: usize = 0;
    while (i < n and i < out.len) : (i += 1) {
        out[i] = .{ .cmd = plug[i].name, .desc = plug[i].desc };
    }
    // JS 扩展命令进目录(斜杠补全/help 可见)。
    for (jsrt.jsCommands()) |jc| {
        if (i >= out.len) break;
        out[i] = .{ .cmd = jc.name, .desc = jc.desc };
        i += 1;
    }
    return i;
}

fn poolAuthSave(ctx: ?*anyopaque, provider: []const u8, key: []const u8) bool {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx orelse return false));
    const cfg = pool.cfg;
    cfg.saveAuth(provider, key) catch return false;
    for (cfg.providers) |*p| {
        if (std.mem.eql(u8, p.name, provider)) {
            p.api_key = pool.alloc.dupe(u8, key) catch p.api_key;
        }
    }
    return true;
}

fn poolConfigHook(ctx: ?*anyopaque, alloc: std.mem.Allocator, body: ?[]const u8) ?[]const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const cfg = pool.cfg;
    if (body) |b| {
        const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, b, .{}) catch return null;
        if (root != .object) return null;
        const write_err =
            "{\"error\":\"配置文件有语法错误，已拒绝写入以免覆盖现有内容。" ++
            "请检查 ~/.piz/settings.json 与 ~/.piz/models.json 后重试。\"}";
        if (root.object.get("setDefaultModel")) |v| {
            if (v == .string) {
                cfg.saveSettings(null, v.string) catch return write_err;
                cfg.default_model = cfg.allocator().dupe(u8, v.string) catch return null;
            }
        }
        if (root.object.get("setDefaultProvider")) |v| {
            if (v == .string) {
                cfg.saveSettings(v.string, null) catch return write_err;
                cfg.default_provider = cfg.allocator().dupe(u8, v.string) catch return null;
            }
        }
        if (root.object.get("setDefaultThinkingLevel")) |v| {
            if (v == .string) {
                const level = cfgmod.ThinkLevel.parse(v.string) orelse return null;
                cfg.saveThinkLevel(level) catch return write_err;
                pool.mutex.lock(util.io) catch {};
                for (pool.sessions.items) |ses| {
                    ses.agent.think_level = cfgmod.clampThinkLevel(ses.agent.modelMeta(), level);
                }
                pool.mutex.unlock(util.io);
            }
        }
        if (root.object.get("setAuth")) |v| {
            if (v == .object) {
                const name = if (v.object.get("name")) |n| (if (n == .string) n.string else "") else "";
                const key = if (v.object.get("key")) |n| (if (n == .string) n.string else "") else "";
                if (name.len == 0 or key.len == 0) return null;
                cfg.saveAuth(name, key) catch return write_err;
                for (cfg.providers) |*p| {
                    if (std.mem.eql(u8, p.name, name)) {
                        p.api_key = alloc.dupe(u8, key) catch p.api_key;
                    }
                }
            }
        }
        if (root.object.get("setApprovalMode")) |v| {
            if (v == .string) {
                const mode = cfgmod.ApprovalMode.parse(v.string) orelse return null;
                cfg.saveApprovalMode(mode) catch return write_err;
            }
        }
        if (root.object.get("setSandboxMode")) |v| {
            if (v == .string) {
                const mode = cfgmod.SandboxMode.parse(v.string) orelse return null;
                cfg.saveSandboxMode(mode) catch return write_err;
            }
        }
        if (root.object.get("refreshModels")) |v| {
            const want = switch (v) {
                .bool => |flag| flag,
                .string => |s| std.mem.eql(u8, s, "true"),
                else => false,
            };
            if (want) {
                pool.mutex.lock(util.io) catch {};
                const r = cfgmod.refreshProviders(alloc, cfg.providers);
                pool.mutex.unlock(util.io);
                return std.fmt.allocPrint(alloc, "{{\"ok\":true,\"refreshed\":{d},\"added\":{d},\"fail\":{d}}}", .{ r.ok, r.added, r.fail }) catch "{\"ok\":true}";
            }
        }
        if (root.object.get("upsertProvider")) |v| {
            if (v == .object) {
                const name = if (v.object.get("name")) |n| (if (n == .string) n.string else "") else "";
                const base_url = if (v.object.get("baseUrl")) |n| (if (n == .string) n.string else "") else "";
                if (name.len == 0 or base_url.len == 0) return null;
                const api_str = if (v.object.get("api")) |n| (if (n == .string) n.string else "openai-completions") else "openai-completions";
                const api_key = if (v.object.get("apiKey")) |n| (if (n == .string) n.string else null) else null;
                const api_enum = if (std.mem.eql(u8, api_str, "anthropic-messages"))
                    cfgmod.Api.anthropic_messages
                else if (std.mem.eql(u8, api_str, "openai-responses"))
                    cfgmod.Api.openai_responses
                else
                    cfgmod.Api.openai_completions;
                var models = std.array_list.Managed([]const u8).init(alloc);
                var metas = std.array_list.Managed(cfgmod.ModelMeta).init(alloc);
                var context_window: u32 = 0;
                if (v.object.get("contextWindow")) |cw| {
                    if (cfgmod.parsePositiveU32(cw)) |n| context_window = n;
                }
                if (v.object.get("models")) |ms| {
                    if (ms == .array) {
                        for (ms.array.items) |m| {
                            if (m == .string) {
                                models.append(m.string) catch |err| util.debugCatch("web.models", err);
                                metas.append(.{}) catch |err| util.debugCatch("web.metas", err);
                            } else if (m == .object) {
                                if (m.object.get("id")) |id| {
                                    if (id == .string) {
                                        models.append(id.string) catch |err| util.debugCatch("web.models.id", err);
                                        const meta = cfgmod.parseModelMeta(m.object);
                                        metas.append(meta) catch |err| util.debugCatch("web.metas.id", err);
                                        if (meta.context_window > 0) context_window = @max(context_window, meta.context_window);
                                    }
                                }
                            }
                        }
                    }
                }
                var found = false;
                var existing_models: []const []const u8 = &.{};
                var existing_metas: []const cfgmod.ModelMeta = &.{};
                var existing_cw: u32 = cfgmod.DEFAULT_CONTEXT_WINDOW;
                for (cfg.providers) |*p| {
                    if (std.mem.eql(u8, p.name, name)) {
                        found = true;
                        existing_models = p.models;
                        existing_metas = p.model_metas;
                        existing_cw = p.context_window;
                        break;
                    }
                }
                const has_models_field = v.object.get("models") != null;
                if (context_window == 0) context_window = if (has_models_field) cfgmod.DEFAULT_CONTEXT_WINDOW else existing_cw;
                const merged = cfgmod.Provider{
                    .name = name,
                    .api = api_enum,
                    .base_url = base_url,
                    .api_key = api_key,
                    .models = if (has_models_field) (models.toOwnedSlice() catch &.{}) else existing_models,
                    .model_metas = if (has_models_field) (metas.toOwnedSlice() catch &.{}) else existing_metas,
                    .context_window = context_window,
                };
                if (found) {
                    for (cfg.providers) |*p| {
                        if (std.mem.eql(u8, p.name, name)) {
                            p.base_url = merged.base_url;
                            p.api = merged.api;
                            p.api_key = merged.api_key;
                            p.models = merged.models;
                            p.model_metas = merged.model_metas;
                            p.context_window = merged.context_window;
                            break;
                        }
                    }
                } else {
                    const all = cfg.allocator().alloc(cfgmod.Provider, cfg.providers.len + 1) catch return null;
                    @memcpy(all[0..cfg.providers.len], cfg.providers);
                    all[cfg.providers.len] = merged;
                    cfg.providers = all;
                }
                cfg.saveModels(cfg.providers) catch return write_err;
            }
        }
        if (root.object.get("setPlugin")) |v| {
            if (v == .object) {
                const name = if (v.object.get("name")) |n| (if (n == .string) n.string else "") else "";
                const on = if (v.object.get("enabled")) |e| switch (e) {
                    .bool => |on_flag| on_flag,
                    else => true,
                } else true;
                if (name.len > 0) {
                    cfg.savePluginToggle(name, on, pluginsmod.isFactoryOn(name)) catch return write_err;
                    if (on) {
                        _ = pluginsmod.enable(name);
                    } else {
                        _ = pluginsmod.disable(name);
                    }
                    // 抽离件(jsrt 内嵌)门控重推 + 重扫,开关即刻生效
                    pluginsmod.refreshExtracted(alloc, pluginsmod.defaultSet());
                    pool.mutex.lockUncancelable(util.io);
                    defer pool.mutex.unlock(util.io);
                    for (pool.sessions.items) |ses| {
                        ses.agent.plugins = if (on)
                            pluginsmod.withEnabled(ses.agent.plugins, name)
                        else
                            pluginsmod.withoutEnabled(ses.agent.plugins, name);
                    }
                }
            }
        }
        if (root.object.get("deleteProvider")) |v| {
            if (v == .string) {
                var keep = std.array_list.Managed(cfgmod.Provider).init(alloc);
                for (cfg.providers) |p| {
                    if (!std.mem.eql(u8, p.name, v.string)) keep.append(p) catch |err| util.debugCatch("web.keep", err);
                }
                if (keep.items.len != cfg.providers.len) {
                    cfg.providers = keep.toOwnedSlice() catch cfg.providers;
                    cfg.saveModels(cfg.providers) catch return write_err;
                }
            }
        }
    }
    var stw = std.Io.Writer.Allocating.init(alloc);
    defer stw.deinit();
    const w = &stw.writer;
    jw("cfg.prov", w.writeAll("{\"defaultProvider\":"));
    jw("cfg.provv", w.print("{s}", .{util.jsonString(alloc, cfg.default_provider orelse "") catch "\"\""}));
    jw("cfg.model", w.writeAll(",\"defaultModel\":"));
    jw("cfg.modelv", w.print("{s}", .{util.jsonString(alloc, cfg.default_model orelse "") catch "\"\""}));
    jw("cfg.think", w.writeAll(",\"defaultThinkingLevel\":"));
    jw("cfg.thinkv", w.print("{s}", .{util.jsonString(alloc, if (cfg.default_think_level) |lv| lv.label() else "high") catch "\"\""}));
    jw("cfg.appr", w.writeAll(",\"approvalMode\":"));
    jw("cfg.apprv", w.print("{s}", .{util.jsonString(alloc, cfg.default_approval.label()) catch "\"yolo\""}));
    jw("cfg.sb", w.writeAll(",\"sandboxMode\":"));
    jw("cfg.sbv", w.print("{s}", .{util.jsonString(alloc, cfg.default_sandbox.label()) catch "\"off\""}));
    jw("cfg.sbb", w.writeAll(",\"sandboxBackend\":"));
    jw("cfg.sbbv", w.print("{s}", .{util.jsonString(alloc, sandboxmod.backend().label()) catch "\"none\""}));
    jw("cfg.plist", w.writeAll(",\"providers\":["));
    for (cfg.providers, 0..) |p, i| {
        if (i > 0) jw("cfg.pcomma", w.writeAll(","));
        jw("cfg.prow", w.print("{{\"name\":{s},\"baseUrl\":{s},\"api\":{s},\"hasKey\":{s},\"models\":[", .{
            util.jsonString(alloc, p.name) catch "\"\"",
            util.jsonString(alloc, p.base_url) catch "\"\"",
            util.jsonString(alloc, if (p.api == .anthropic_messages) "anthropic-messages" else "openai-completions") catch "\"\"",
            if (p.api_key != null) "true" else "false",
        }));
        for (p.models, 0..) |m, j| {
            if (j > 0) jw("cfg.mcomma", w.writeAll(","));
            jw("cfg.mid", w.print("{s}", .{util.jsonString(alloc, m) catch "\"\""}));
        }
        jw("cfg.pend", w.writeAll("]}"));
    }
    jw("cfg.plugins", w.writeAll("],\"plugins\":"));
    pluginsmod.writeCatalog(w) catch |err| util.debugCatch("cfg.catalog", err);
    jw("cfg.end", w.writeAll("}"));
    return stw.toOwnedSlice() catch null;
}

fn poolWsAllowed(ctx: ?*anyopaque, ws: []const u8) bool {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    pool.mutex.lock(util.io) catch return false;
    defer pool.mutex.unlock(util.io);
    for (pool.workspaces.items) |w| {
        if (std.mem.eql(u8, w, ws)) return true;
    }
    return false;
}

fn poolWorkspacesHook(ctx: ?*anyopaque, alloc: std.mem.Allocator, body: ?[]const u8) ?[]const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    if (body) |b| {
        const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, b, .{}) catch return null;
        if (root != .object) return null;
        const path = if (root.object.get("root")) |v| (if (v == .string) v.string else null) else null;
        const p = path orelse return null;
        var d = std.Io.Dir.cwd().openDir(util.io, p, .{}) catch return null;
        d.close(util.io);
        pool.mutex.lock(util.io) catch return null;
        for (pool.workspaces.items) |ws| {
            if (std.mem.eql(u8, ws, p)) {
                pool.mutex.unlock(util.io);
                return "[]";
            }
        }
        pool.workspaces.append(pool.alloc.dupe(u8, p) catch {
            pool.mutex.unlock(util.io);
            return null;
        }) catch |err| util.debugCatch("ws.append", err);
        pool.mutex.unlock(util.io);
        std.debug.print("piz web: 已注册项目 {s}\n", .{p});
    }
    var stw = std.Io.Writer.Allocating.init(alloc);
    defer stw.deinit();
    const w = &stw.writer;
    jw("ws.ob", w.writeAll("["));
    pool.mutex.lock(util.io) catch return "[]";
    for (pool.workspaces.items, 0..) |ws, i| {
        if (i > 0) jw("ws.comma", w.writeAll(","));
        const raw_base = std.fs.path.basename(ws);
        const base = if (raw_base.len > 0) raw_base else ws;
        jw("ws.row", w.print("{{\"root\":{s},\"name\":{s}}}", .{
            util.jsonString(alloc, ws) catch "\"\"",
            util.jsonString(alloc, base) catch "\"\"",
        }));
    }
    pool.mutex.unlock(util.io);
    jw("ws.cb", w.writeAll("]"));
    return stw.toOwnedSlice() catch "[]";
}

fn poolModelsHook(ctx: ?*anyopaque, alloc: std.mem.Allocator) []const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    var stw = std.Io.Writer.Allocating.init(alloc);
    defer stw.deinit();
    const w = &stw.writer;
    jw("models.ob", w.writeAll("["));
    const models = pool.cfg.allModels(alloc);
    defer alloc.free(models);
    for (models, 0..) |m, i| {
        if (i > 0) jw("models.comma", w.writeAll(","));
        jw("models.id", w.print("{s}", .{util.jsonString(alloc, m) catch "\"\""}));
    }
    jw("models.cb", w.writeAll("]"));
    return stw.toOwnedSlice() catch "[]";
}

fn poolModelHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8, model: ?[]const u8) ?[]const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    var cur: ?[]const u8 = null;
    pool.mutex.lock(util.io) catch return null;
    for (pool.sessions.items) |ses| {
        if (std.mem.eql(u8, ses.name, session) and std.mem.eql(u8, ses.cwd, cwd2)) {
            if (model) |m| {
                ses.agent.switchModel(m) catch {
                    pool.mutex.unlock(util.io);
                    return null;
                };
                if (ses.busy.cmpxchgWeak(0, 2, .acq_rel, .acquire) == null) {
                    rebuildSnap(ses);
                    ses.busy.store(0, .release);
                }
            }
            cur = ses.agent.model;
            break;
        }
    }
    pool.mutex.unlock(util.io);
    if (cur) |c| return c;
    const ses = pool.getOrCreate(session, cwd2) orelse return null;
    if (model) |m| ses.agent.switchModel(m) catch return null;
    return ses.agent.model;
}

fn poolTitleHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8, title: ?[]const u8) ?[]const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    var cur: ?[]const u8 = null;
    pool.mutex.lock(util.io) catch return null;
    for (pool.sessions.items) |ses| {
        if (std.mem.eql(u8, ses.name, session) and std.mem.eql(u8, ses.cwd, cwd2)) {
            if (title) |t| {
                const trimmed = std.mem.trim(u8, t, " \t");
                ses.agent.title = if (trimmed.len > 0) (std.heap.page_allocator.dupe(u8, trimmed) catch null) else null;
            }
            cur = ses.agent.title;
            break;
        }
    }
    pool.mutex.unlock(util.io);
    if (cur) |c| return c;
    const ses = pool.getOrCreate(session, cwd2) orelse return null;
    if (title) |t| {
        const trimmed = std.mem.trim(u8, t, " \t");
        ses.agent.title = if (trimmed.len > 0) (std.heap.page_allocator.dupe(u8, trimmed) catch null) else null;
    }
    return ses.agent.title;
}

pub fn poolActionHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8, act: []const u8, name: ?[]const u8, count: usize) ?[]const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const alloc = pool.alloc;
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    if (std.mem.eql(u8, act, "archive")) {
        pool.detachAndDestroy(session, cwd2);
        sessionmod.archiveWeb(alloc, cwd2, session) catch |err| {
            util.debugCatch("archiveWeb", err);
            return "{\"ok\":false,\"act\":\"archive\"}";
        };
        return "{\"ok\":true,\"act\":\"archive\"}";
    }
    if (std.mem.eql(u8, act, "restore")) {
        sessionmod.restoreWeb(alloc, cwd2, session) catch |err| {
            util.debugCatch("restoreWeb", err);
            return "{\"ok\":false,\"act\":\"restore\"}";
        };
        return "{\"ok\":true,\"act\":\"restore\"}";
    }
    if (std.mem.eql(u8, act, "delete")) {
        pool.detachAndDestroy(session, cwd2);
        sessionmod.deleteWeb(alloc, cwd2, session) catch |err| {
            util.debugCatch("deleteWeb", err);
            return "{\"ok\":false,\"act\":\"delete\"}";
        };
        return "{\"ok\":true,\"act\":\"delete\"}";
    }
    const ses = pool.getOrCreate(session, cwd2) orelse return null;
    if (std.mem.eql(u8, act, "fork")) {
        if (ses.busy.cmpxchgWeak(0, 2, .acq_rel, .acquire) != null) return "{\"ok\":false,\"act\":\"fork\",\"error\":\"busy\"}";
        defer ses.busy.store(0, .release);
        const new_name = if (name) |n|
            (if (n.len > 0 and sessionmod.webNameOk(n)) n else "")
        else
            "";
        var buf: [48]u8 = undefined;
        const ts = @divTrunc(std.Io.Clock.now(.real, util.io).nanoseconds, std.time.ns_per_ms);
        const rand_name = std.fmt.bufPrint(&buf, "{s}-f{d}", .{ session, ts }) catch session;
        const target = if (new_name.len > 0) new_name else rand_name;
        sessionmod.saveWebTs(alloc, cwd2, target, ses.agent.model, sessionIsYolo(ses), ses.agent.title, ses.agent.messages.items, std.Io.Clock.now(.real, util.io).nanoseconds) catch return null;
        return std.fmt.allocPrint(alloc, "{{\"ok\":true,\"act\":\"fork\",\"name\":{s}}}", .{util.jsonString(alloc, target) catch "\"\""}) catch null;
    }
    if (std.mem.eql(u8, act, "undo")) {
        if (ses.busy.cmpxchgWeak(0, 2, .acq_rel, .acquire) != null) return "{\"ok\":false,\"act\":\"undo\",\"error\":\"busy\"}";
        defer ses.busy.store(0, .release);
        const n = if (count == 0) 1 else count;
        const msgs = ses.agent.messages.items;
        var cut: usize = 0;
        var remain = n;
        while (cut < msgs.len) {
            const i = msgs.len - 1 - cut;
            cut += 1;
            if (std.mem.eql(u8, msgs[i].role, "user")) {
                remain -= 1;
                if (remain == 0) break;
            }
        }
        if (remain > 0) return "{\"ok\":false,\"act\":\"undo\"}";
        if (msgs.len == 0) return "{\"ok\":false,\"act\":\"undo\"}";
        ses.agent.messages.shrinkRetainingCapacity(msgs.len - cut);
        ses.updated_ns = std.Io.Clock.now(.real, util.io).nanoseconds;
        sessionmod.saveWebTs(alloc, cwd2, session, ses.agent.model, sessionIsYolo(ses), ses.agent.title, ses.agent.messages.items, ses.updated_ns) catch |err| {
            util.errLog(alloc, "web-save", session, @errorName(err));
            util.debugCatch("saveWebTs", err);
        };
        rebuildSnap(ses);
        return std.fmt.allocPrint(alloc, "{{\"ok\":true,\"act\":\"undo\",\"msgs\":{d}}}", .{msgs.len - cut}) catch null;
    }
    if (std.mem.eql(u8, act, "compact")) {
        if (ses.busy.cmpxchgWeak(0, 2, .acq_rel, .acquire) != null) return "{\"ok\":false,\"act\":\"compact\",\"error\":\"busy\"}";
        defer ses.busy.store(0, .release);
        _ = ses.agent.compact() catch "";
        rebuildSnap(ses);
        return "{\"ok\":true,\"act\":\"compact\"}";
    }
    if (std.mem.eql(u8, act, "queue")) {
        const n = webui_mod.ChatQueue.clear(ses.qkey);
        return std.fmt.allocPrint(alloc, "{{\"ok\":true,\"act\":\"queue\",\"cleared\":{d}}}", .{n}) catch null;
    }
    if (std.mem.eql(u8, act, "fast-compress")) {
        const msg = compress.formatStatus(alloc, .{
            .alloc = ses.agent.alloc,
            .messages = &ses.agent.messages,
            .window = ses.agent.ctxWindow(),
            .api = ses.agent.provider.api,
            .vision = ses.agent.hasVision(),
        });
        return jsonOkText(alloc, act, msg);
    }
    if (std.mem.eql(u8, act, "copy")) {
        var i = ses.agent.messages.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, ses.agent.messages.items[i].role, "assistant")) {
                return jsonOkText(alloc, act, ses.agent.messages.items[i].content);
            }
        }
        return "{\"ok\":false,\"act\":\"copy\",\"error\":\"empty\"}";
    }
    if (std.mem.eql(u8, act, "tree") or std.mem.eql(u8, act, "export") or std.mem.eql(u8, act, "dump")) {
        return sessionExport(alloc, ses, act);
    }
    if (std.mem.eql(u8, act, "memory") or std.mem.eql(u8, act, "memory-set") or std.mem.eql(u8, act, "memory-clear")) {
        return memoryAct(alloc, act, name);
    }
    return null;
}

fn jsonOkText(alloc: std.mem.Allocator, act: []const u8, text: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(alloc, "{{\"ok\":true,\"act\":{s},\"text\":{s}}}", .{
        util.jsonString(alloc, act) catch "\"\"",
        util.jsonString(alloc, text) catch "\"\"",
    }) catch null;
}

fn sessionExport(alloc: std.mem.Allocator, ses: *WebSession, act: []const u8) ?[]const u8 {
    var ww = std.Io.Writer.Allocating.init(alloc);
    defer ww.deinit();
    const w = &ww.writer;
    const html = std.mem.eql(u8, act, "export");
    if (html) jw("export.html", w.writeAll("<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>piz session</title></head><body>"));
    if (std.mem.eql(u8, act, "tree")) {
        jw("export.n", w.print("{d} messages:\n", .{ses.agent.messages.items.len}));
    }
    for (ses.agent.messages.items, 0..) |m, i| {
        if (std.mem.eql(u8, act, "tree")) {
            const tag: []const u8 = if (m.role.len > 0) switch (m.role[0]) {
                'u' => ">",
                'a' => "<",
                't' => "tool",
                else => "-",
            } else "-";
            const head = m.content[0..@min(m.content.len, 50)];
            jw("export.tree", w.print("{d}. {s} {s}\n", .{ i + 1, tag, head }));
        } else if (html) {
            jw("export.p", w.print("<p><b>{s}</b><br><pre>{s}</pre></p>\n", .{ m.role, htmlEsc(alloc, m.content) }));
        } else {
            jw("export.md", w.print("--- {s} ---\n{s}\n", .{ m.role, m.content }));
        }
    }
    if (html) jw("export.end", w.writeAll("</body></html>\n"));
    if (std.mem.eql(u8, act, "tree")) jw("export.hint", w.writeAll("use /fork <n> to branch from a message"));
    return jsonOkText(alloc, act, ww.written());
}

fn htmlEsc(alloc: std.mem.Allocator, s: []const u8) []const u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    for (s) |c| {
        switch (c) {
            '&' => out.appendSlice("&amp;") catch |err| util.debugCatch("htmlEsc.amp", err),
            '<' => out.appendSlice("&lt;") catch |err| util.debugCatch("htmlEsc.lt", err),
            '>' => out.appendSlice("&gt;") catch |err| util.debugCatch("htmlEsc.gt", err),
            else => out.append(c) catch |err| util.debugCatch("htmlEsc.c", err),
        }
    }
    return out.toOwnedSlice() catch s;
}

fn memoryAct(alloc: std.mem.Allocator, act: []const u8, name: ?[]const u8) ?[]const u8 {
    const mem_path = util.configDir(alloc) catch return "{\"ok\":false,\"act\":\"memory\",\"error\":\"no config dir\"}";
    const full = util.joinPath(alloc, mem_path, "memory.md") catch return "{\"ok\":false,\"act\":\"memory\"}";
    if (std.mem.eql(u8, act, "memory-clear")) {
        std.Io.Dir.cwd().deleteFile(util.io, full) catch |err| util.debugCatch("memory.clear", err);
        return "{\"ok\":true,\"act\":\"memory-clear\"}";
    }
    if (std.mem.eql(u8, act, "memory-set")) {
        const text = std.mem.trim(u8, name orelse "", " ");
        if (text.len == 0) return "{\"ok\":false,\"act\":\"memory-set\",\"error\":\"empty\"}";
        const mline = std.fmt.allocPrint(alloc, "{s}\n", .{text}) catch return "{\"ok\":false,\"act\":\"memory-set\"}";
        var f = std.Io.Dir.cwd().createFile(util.io, full, .{ .exclusive = true, .permissions = @enumFromInt(0o600) }) catch |err| switch (err) {
            error.PathAlreadyExists => std.Io.Dir.cwd().openFile(util.io, full, .{ .mode = .write_only }) catch return "{\"ok\":false,\"act\":\"memory-set\"}",
            else => return "{\"ok\":false,\"act\":\"memory-set\"}",
        };
        defer f.close(util.io);
        var wbuf: [1024]u8 = undefined;
        var w = f.writer(util.io, &wbuf);
        w.seekTo(f.length(util.io) catch 0) catch |err| util.debugCatch("memory-set.seek", err);
        w.interface.writeAll(mline) catch |err| {
            util.debugCatch("memory-set.write", err);
            return "{\"ok\":false,\"act\":\"memory-set\"}";
        };
        w.flush() catch |err| {
            util.debugCatch("memory-set.flush", err);
            return "{\"ok\":false,\"act\":\"memory-set\"}";
        };
        return jsonOkText(alloc, act, text);
    }
    const content = std.Io.Dir.cwd().readFileAlloc(util.io, full, alloc, .limited(512 * 1024)) catch
        return jsonOkText(alloc, "memory", "memory is empty — /memory set <text> to add");
    return jsonOkText(alloc, "memory", content);
}

fn poolModeHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8, mode: ?[]const u8) ?[]const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    const parsed = if (mode) |m| cfgmod.ApprovalMode.parse(m) else null;
    var cur: ?[]const u8 = null;
    pool.mutex.lock(util.io) catch return null;
    for (pool.sessions.items) |ses| {
        if (std.mem.eql(u8, ses.name, session) and std.mem.eql(u8, ses.cwd, cwd2)) {
            if (parsed) |p| setSessionApproval(ses, p);
            cur = sessionApproval(ses).label();
            break;
        }
    }
    pool.mutex.unlock(util.io);
    if (cur) |c| return c;
    const ses = pool.getOrCreate(session, cwd2) orelse return null;
    if (parsed) |p| setSessionApproval(ses, p);
    return sessionApproval(ses).label();
}

fn poolChatHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8, text: []const u8, image: ?[]const u8, mime: []const u8) bool {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    const ses = pool.getOrCreate(session, cwd2) orelse return false;
    const prepared = prepareWebChat(pool.alloc, ses.cwd, text);
    if (prepared.notice) |note| {
        ses.hub.push("{{\"type\":\"notice\",\"session\":{s},\"text\":{s}}}", .{
            util.jsonString(pool.alloc, ses.name) catch "\"\"",
            util.jsonString(pool.alloc, note) catch "\"\"",
        });
    }
    if (prepared.skip) return true;
    if (!webui_mod.ChatQueue.enqueueEx(ses.qkey, prepared.send, image, mime)) return false;
    if (ses.busy.load(.acquire) != 0) {
        ses.hub.push("{{\"type\":\"queued\",\"session\":{s},\"text\":{s},\"n\":{d}}}", .{
            util.jsonString(pool.alloc, ses.name) catch "\"\"",
            util.jsonString(pool.alloc, prepared.send) catch "\"\"",
            webui_mod.ChatQueue.pending(ses.qkey),
        });
    }
    return true;
}

const PreparedChat = struct {
    send: []const u8,
    notice: ?[]const u8 = null,
    skip: bool = false,
};

/// Web 与 TUI 同一套入口:`!cmd` 跑 bash,`!!cmd` 只跑不送模型,`@./path` 嵌文件,`/plan` 写成 PLAN.md。
fn prepareWebChat(alloc: std.mem.Allocator, cwd: []const u8, text: []const u8) PreparedChat {
    if (text.len > 1 and text[0] == '!') {
        const send_to_llm = !(text.len > 1 and text[1] == '!');
        const cmd = if (send_to_llm) text[1..] else text[2..];
        toolsmod.setRoot(cwd);
        defer toolsmod.clearRoot();
        const json_args = std.fmt.allocPrint(alloc, "{{\"command\":{s},\"timeout\":30}}", .{util.jsonString(alloc, cmd) catch "\"\""}) catch {
            return .{ .send = text, .notice = "cannot build bash args", .skip = !send_to_llm };
        };
        const res: toolsmod.Result = if (toolsmod.find("bash")) |tb|
            (tb.handler(alloc, json_args) catch |err| toolsmod.crashResult(alloc, "bash", err))
        else
            .{ .content = "no bash tool", .is_error = true };
        if (!send_to_llm) return .{ .send = text, .notice = res.content, .skip = true };
        const msg = std.fmt.allocPrint(alloc, "!{s}\n\nOutput:\n{s}", .{ cmd, res.content }) catch text;
        return .{ .send = msg, .notice = res.content };
    }
    if (std.mem.startsWith(u8, text, "/plan")) {
        const goal = std.mem.trim(u8, text["/plan".len..], " ");
        if (goal.len == 0) return .{ .send = text, .notice = "usage: /plan <goal>", .skip = true };
        const msg = std.fmt.allocPrint(alloc, "Create a detailed step-by-step plan for: {s}. Write the plan to PLAN.md in the project root, then briefly state you are ready to execute it.", .{goal}) catch text;
        return .{ .send = msg };
    }
    const expanded = util.expandRefs(alloc, text, cwd) catch text;
    return .{ .send = expanded };
}

test {
    // 单测主体在 cmd_web_tests.zig(原 2 测试);引回以保持 zig test 收集。
    _ = @import("cmd_web_tests.zig");
}
