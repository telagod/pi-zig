// cmd_web.zig — Web 会话池与 piz web 命令。
const std = @import("std");
const util = @import("core").util;
const cfgmod = @import("core").config;
const agentmod = @import("core").agent;
const sessionmod = @import("core").session;
const pluginsmod = @import("core").plugins;
const compress = @import("core").compress;
const toolsmod = @import("core").tools;
const webui_mod = @import("webui.zig");

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
    pool.workspaces.append(arena.allocator().dupe(u8, abs_cwd) catch "") catch {};
    if (pool.getOrCreate("default", abs_cwd) == null) {
        std.debug.print("piz web: session init failed\n", .{});
        std.process.exit(1);
    }
    ws.state_hook = poolStateHook;
    ws.state_ctx = &pool;
    ws.sessions_hook = poolSessionsHook;
    ws.sessions_ctx = &pool;
    ws.chat_hook = poolChatHook;
    ws.chat_ctx = &pool;
    ws.interrupt_hook = poolInterruptHook;
    ws.interrupt_ctx = &pool;
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
    ws.run() catch {};
    webui_mod.ChatQueue.shutdown();
    for (pool.sessions.items) |ses| {
        ses.worker.join();
    }
    std.debug.print("\npiz web: bye\n", .{});
}

/// 会话池:每会话独立 Agent/Arena/worker(上限 4,对齐 task 工具)。
const WebSession = struct {
    name: []const u8,
    cwd: []const u8,
    qkey: []const u8,
    agent: *agentmod.Agent,
    hub: *webui_mod.EventHub,
    start_ns: i128,
    tokens_total: usize = 0,
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
};

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

const SessionPool = struct {
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
                agent.messages.append(m) catch {};
            }
            restored_approval = if (web_ses.auto) .yolo else .ask;
            restored_updated = web_ses.updated;
            if (web_ses.title) |t| agent.title = t;
            if (web_ses.model) |m| {
                if (self.cfg.findModel(m) != null) {
                    agent.switchModel(m) catch {};
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

fn rebuildSnap(ses: *WebSession) void {
    const a = ses.agent.alloc;
    const ag = ses.agent;
    var stw = std.Io.Writer.Allocating.init(a);
    defer stw.deinit();
    const w = &stw.writer;
    w.writeAll("[") catch {};
    const msgs = ag.messages.items;
    const hist_start = if (msgs.len > 20) msgs.len - 20 else 0;
    var first = true;
    var i = hist_start;
    while (i < msgs.len) : (i += 1) {
        const m = &msgs[i];
        if (m.content.len == 0 and std.mem.eql(u8, m.role, "assistant")) continue;
        if (!first) w.writeAll(",") catch {};
        first = false;
        const content = if (m.content.len > 300) m.content[0..300] else m.content;
        w.print("{{\"role\":{s},\"content\":{s}}}", .{ util.jsonString(a, m.role) catch "\"\"", util.jsonString(a, content) catch "\"\"" }) catch {};
    }
    w.writeAll("]") catch {};
    const history = stw.toOwnedSlice() catch return;
    const model = a.dupe(u8, ag.model) catch return;
    const cw = ag.ctxWindow();
    const used = ag.estTokens();
    const pct: u32 = @intCast(if (cw > 0) @min(used * 100 / cw, 10000) else 0);
    ses.snap_mutex.lock(util.io) catch return;
    ses.snap_history = history;
    ses.snap_model = model;
    ses.snap_pct.store(pct, .release);
    ses.snap_msgs.store(@intCast(@min(msgs.len, std.math.maxInt(u32))), .release);
    ses.snap_mutex.unlock(util.io);
}

fn webOnAbort(ctx: ?*anyopaque) bool {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    return s.agent.aborted.load(.acquire);
}
fn webOnConnect(ctx: ?*anyopaque, stream: *@import("core").httpc.Stream) void {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    s.agent.cur_stream_fd.store(stream.fd() orelse -1, .release);
}

fn poolSessionsHook(ctx: ?*anyopaque, cwd: []const u8, alloc: std.mem.Allocator) []const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    var stw = std.Io.Writer.Allocating.init(alloc);
    defer stw.deinit();
    const w = &stw.writer;
    w.print("[", .{}) catch {};
    var first = true;
    pool.mutex.lock(util.io) catch return "[]";
    for (pool.sessions.items) |ses| {
        if (!std.mem.eql(u8, ses.cwd, cwd2)) continue;
        if (!first) w.print(",", .{}) catch {};
        first = false;
        ses.snap_mutex.lock(util.io) catch return "[]";
        const snap_model = ses.snap_model;
        ses.snap_mutex.unlock(util.io);
        w.print("{{\"name\":{s},\"msgs\":{d},\"pct\":{d},\"model\":{s},\"auto\":{s},\"title\":{s},\"ts\":{d}}}", .{
            util.jsonString(alloc, ses.name) catch "\"\"",
            ses.snap_msgs.load(.acquire),
            ses.snap_pct.load(.acquire),
            util.jsonString(alloc, snap_model) catch "\"\"",
            if (sessionIsYolo(ses)) "true" else "false",
            util.jsonString(alloc, ses.agent.title orelse "") catch "\"\"",
            @divTrunc(ses.updated_ns, std.time.ns_per_ms),
        }) catch {};
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
                if (!first) w.print(",", .{}) catch {};
                first = false;
                w.print("{{\"name\":{s},\"msgs\":{d},\"pct\":0,\"model\":{s},\"auto\":true,\"title\":{s},\"ts\":{d},\"disk\":true}}", .{
                    util.jsonString(alloc, dname) catch "\"\"",
                    count,
                    util.jsonString(alloc, meta_model) catch "\"\"",
                    util.jsonString(alloc, meta_title) catch "\"\"",
                    meta_ts,
                }) catch {};
            } else |_| {}
        }
        if (sessionmod.listWebArchived(alloc, cwd2) catch null) |arch_names| {
            for (arch_names) |dname| {
                if (!first) w.print(",", .{}) catch {};
                first = false;
                w.print("{{\"name\":{s},\"msgs\":0,\"pct\":0,\"model\":\"\",\"auto\":true,\"title\":\"\",\"ts\":0,\"archived\":true}}", .{
                    util.jsonString(alloc, dname) catch "\"\"",
                }) catch {};
            }
        }
    }
    w.print("]", .{}) catch {};
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
    w.print("{{\"model\":{s},\"auto\":{s},\"mode\":{s},\"title\":{s},\"think\":{s}", .{
        util.jsonString(alloc, snap_model) catch "\"\"",
        if (sessionIsYolo(ses)) "true" else "false",
        util.jsonString(alloc, sessionApproval(ses).label()) catch "\"yolo\"",
        util.jsonString(alloc, ses.agent.title orelse "") catch "\"\"",
        util.jsonString(alloc, ses.agent.think_level.label()) catch "\"\"",
    }) catch {};
    w.print(",\"pct\":{d},\"running\":{s},\"history\":{s}", .{
        ses.snap_pct.load(.acquire),
        if (ses.agent.cur_stream_fd.load(.acquire) >= 0) "true" else "false",
        snap_history,
    }) catch {};
    const raw_base = std.fs.path.basename(cwd2);
    const base = if (raw_base.len > 0) raw_base else cwd2;
    w.print(",\"ws\":{s}", .{util.jsonString(alloc, base) catch "\"\""}) catch {};
    w.writeAll("}") catch {};
    return stw.toOwnedSlice() catch "{}";
}

fn webWorker(ses: *WebSession) void {
    while (true) {
        const item = webui_mod.ChatQueue.dequeue(ses.qkey, &ses.stopping) orelse break;
        ses.hub.push("{{\"type\":\"user_message\",\"session\":{s},\"text\":{s}}}", .{
            util.jsonString(ses.agent.alloc, ses.name) catch "\"\"",
            util.jsonString(ses.agent.alloc, item.text) catch "\"\"",
        });
        const text = ses.agent.alloc.dupe(u8, item.text) catch null;
        const a = std.heap.page_allocator;
        a.free(item.session);
        if (text != null) a.free(item.text);
        while (ses.busy.cmpxchgWeak(0, 1, .acq_rel, .acquire) != null) {
            if (ses.stopping.load(.acquire)) break;
            std.Io.sleep(util.io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
        }
        if (ses.stopping.load(.acquire)) break;
        defer ses.busy.store(0, .release);
        ses.agent.aborted.store(false, .release);
        ses.updated_ns = std.Io.Clock.now(.real, util.io).nanoseconds;
        const result = ses.agent.send(text orelse item.text) catch null;
        if (result) |r| {
            const u = r.usage;
            ses.tokens_total += (u.input orelse 0) + (u.output orelse 0) + (u.cache_read orelse 0);
            ses.agent.last_usage = u;
        }
        sessionmod.saveWebTs(ses.agent.alloc, ses.cwd, ses.name, ses.agent.model, sessionIsYolo(ses), ses.agent.title, ses.agent.messages.items, ses.updated_ns) catch |err| {
            const msg = std.fmt.allocPrint(ses.agent.alloc, "会话保存失败({s}):本轮内容在重启后会丢失", .{@errorName(err)}) catch "session save failed";
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
fn webOnToolStart(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!void {
    const s: *WebSession = @ptrCast(@alignCast(ctx.?));
    const short_args = if (args.len > 500) args[0..500] else args;
    s.hub.push("{{\"type\":\"tool_call\",\"session\":{s},\"name\":{s},\"args\":{s}}}", .{ try util.jsonString(s.agent.alloc, s.name), try util.jsonString(s.agent.alloc, name), try util.jsonString(s.agent.alloc, short_args) });
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
    const pct = if (cw > 0) used * 100 / cw else 0;
    var cache_pct: usize = 0;
    if (s.agent.last_usage.cache_read) |cr| {
        const tot = cr + (s.agent.last_usage.cache_write orelse 0) + (s.agent.last_usage.input orelse 0);
        if (tot > 0) cache_pct = cr * 100 / tot;
    }
    const now_ns = std.Io.Clock.now(.real, util.io).nanoseconds;
    const el = @max(1, @divTrunc(now_ns - s.start_ns, std.time.ns_per_s));
    const tps = s.tokens_total / @as(usize, @intCast(el));
    s.hub.push("{{\"type\":\"status\",\"pct\":{d},\"model\":{s},\"cache\":{d},\"tps\":{d},\"think\":{s}}}", .{
        pct,
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
                                models.append(m.string) catch {};
                                metas.append(.{}) catch {};
                            } else if (m == .object) {
                                if (m.object.get("id")) |id| {
                                    if (id == .string) {
                                        models.append(id.string) catch {};
                                        const meta = cfgmod.parseModelMeta(m.object);
                                        metas.append(meta) catch {};
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
        if (root.object.get("deleteProvider")) |v| {
            if (v == .string) {
                var keep = std.array_list.Managed(cfgmod.Provider).init(alloc);
                for (cfg.providers) |p| {
                    if (!std.mem.eql(u8, p.name, v.string)) keep.append(p) catch {};
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
    w.writeAll("{\"defaultProvider\":") catch {};
    w.print("{s}", .{util.jsonString(alloc, cfg.default_provider orelse "") catch "\"\""}) catch {};
    w.writeAll(",\"defaultModel\":") catch {};
    w.print("{s}", .{util.jsonString(alloc, cfg.default_model orelse "") catch "\"\""}) catch {};
    w.writeAll(",\"defaultThinkingLevel\":") catch {};
    w.print("{s}", .{util.jsonString(alloc, if (cfg.default_think_level) |lv| lv.label() else "high") catch "\"\""}) catch {};
    w.writeAll(",\"providers\":[") catch {};
    for (cfg.providers, 0..) |p, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.print("{{\"name\":{s},\"baseUrl\":{s},\"api\":{s},\"hasKey\":{s},\"models\":[", .{
            util.jsonString(alloc, p.name) catch "\"\"",
            util.jsonString(alloc, p.base_url) catch "\"\"",
            util.jsonString(alloc, if (p.api == .anthropic_messages) "anthropic-messages" else "openai-completions") catch "\"\"",
            if (p.api_key != null) "true" else "false",
        }) catch {};
        for (p.models, 0..) |m, j| {
            if (j > 0) w.writeAll(",") catch {};
            w.print("{s}", .{util.jsonString(alloc, m) catch "\"\""}) catch {};
        }
        w.writeAll("]}") catch {};
    }
    w.writeAll("]}") catch {};
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
        }) catch {};
        pool.mutex.unlock(util.io);
        std.debug.print("piz web: 已注册项目 {s}\n", .{p});
    }
    var stw = std.Io.Writer.Allocating.init(alloc);
    defer stw.deinit();
    const w = &stw.writer;
    w.writeAll("[") catch {};
    pool.mutex.lock(util.io) catch return "[]";
    for (pool.workspaces.items, 0..) |ws, i| {
        if (i > 0) w.writeAll(",") catch {};
        const raw_base = std.fs.path.basename(ws);
        const base = if (raw_base.len > 0) raw_base else ws;
        w.print("{{\"root\":{s},\"name\":{s}}}", .{
            util.jsonString(alloc, ws) catch "\"\"",
            util.jsonString(alloc, base) catch "\"\"",
        }) catch {};
    }
    pool.mutex.unlock(util.io);
    w.writeAll("]") catch {};
    return stw.toOwnedSlice() catch "[]";
}

fn poolModelsHook(ctx: ?*anyopaque, alloc: std.mem.Allocator) []const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    var stw = std.Io.Writer.Allocating.init(alloc);
    defer stw.deinit();
    const w = &stw.writer;
    w.writeAll("[") catch {};
    const models = pool.cfg.allModels(alloc);
    defer alloc.free(models);
    for (models, 0..) |m, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.print("{s}", .{util.jsonString(alloc, m) catch "\"\""}) catch {};
    }
    w.writeAll("]") catch {};
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

fn poolActionHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8, act: []const u8, name: ?[]const u8, count: usize) ?[]const u8 {
    const pool: *SessionPool = @ptrCast(@alignCast(ctx.?));
    const alloc = pool.alloc;
    const cwd2 = if (cwd.len > 0) cwd else (if (pool.workspaces.items.len > 0) pool.workspaces.items[0] else "");
    if (std.mem.eql(u8, act, "archive")) {
        pool.detachAndDestroy(session, cwd2);
        sessionmod.archiveWeb(alloc, cwd2, session) catch {};
        return "{\"ok\":true,\"act\":\"archive\"}";
    }
    if (std.mem.eql(u8, act, "restore")) {
        sessionmod.restoreWeb(alloc, cwd2, session) catch {};
        return "{\"ok\":true,\"act\":\"restore\"}";
    }
    if (std.mem.eql(u8, act, "delete")) {
        pool.detachAndDestroy(session, cwd2);
        sessionmod.deleteWeb(alloc, cwd2, session) catch {};
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
        sessionmod.saveWebTs(alloc, cwd2, session, ses.agent.model, sessionIsYolo(ses), ses.agent.title, ses.agent.messages.items, ses.updated_ns) catch {};
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
    if (std.mem.eql(u8, act, "shake") or std.mem.eql(u8, act, "shake-images") or std.mem.eql(u8, act, "snap")) {
        if (ses.busy.cmpxchgWeak(0, 2, .acq_rel, .acquire) != null) return "{\"ok\":false,\"error\":\"busy\"}";
        defer ses.busy.store(0, .release);
        const drop_images = std.mem.eql(u8, act, "shake-images") or (name != null and std.mem.eql(u8, name.?, "images"));
        const in = compress.Input{
            .alloc = ses.agent.alloc,
            .messages = &ses.agent.messages,
            .window = ses.agent.ctxWindow(),
            .api = ses.agent.provider.api,
            .vision = ses.agent.hasVision(),
        };
        const r = if (std.mem.eql(u8, act, "snap"))
            compress.snap(in)
        else
            compress.shake(in, .{ .protect_tokens = 0, .min_savings = 0, .drop_images = drop_images });
        rebuildSnap(ses);
        return std.fmt.allocPrint(alloc, "{{\"ok\":true,\"act\":\"{s}\",\"saved\":{d}}}", .{ act, r.tokens_saved }) catch null;
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
    if (html) w.writeAll("<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>piz session</title></head><body>") catch {};
    if (std.mem.eql(u8, act, "tree")) {
        w.print("{d} messages:\n", .{ses.agent.messages.items.len}) catch {};
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
            w.print("{d}. {s} {s}\n", .{ i + 1, tag, head }) catch {};
        } else if (html) {
            w.print("<p><b>{s}</b><br><pre>{s}</pre></p>\n", .{ m.role, htmlEsc(alloc, m.content) }) catch {};
        } else {
            w.print("--- {s} ---\n{s}\n", .{ m.role, m.content }) catch {};
        }
    }
    if (html) w.writeAll("</body></html>\n") catch {};
    if (std.mem.eql(u8, act, "tree")) w.writeAll("use /fork <n> to branch from a message") catch {};
    return jsonOkText(alloc, act, ww.written());
}

fn htmlEsc(alloc: std.mem.Allocator, s: []const u8) []const u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    for (s) |c| {
        switch (c) {
            '&' => out.appendSlice("&amp;") catch {},
            '<' => out.appendSlice("&lt;") catch {},
            '>' => out.appendSlice("&gt;") catch {},
            else => out.append(c) catch {},
        }
    }
    return out.toOwnedSlice() catch s;
}

fn memoryAct(alloc: std.mem.Allocator, act: []const u8, name: ?[]const u8) ?[]const u8 {
    const mem_path = util.configDir(alloc) catch return "{\"ok\":false,\"act\":\"memory\",\"error\":\"no config dir\"}";
    const full = util.joinPath(alloc, mem_path, "memory.md") catch return "{\"ok\":false,\"act\":\"memory\"}";
    if (std.mem.eql(u8, act, "memory-clear")) {
        std.Io.Dir.cwd().deleteFile(util.io, full) catch {};
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
        w.seekTo(f.length(util.io) catch 0) catch {};
        w.interface.writeAll(mline) catch {};
        w.flush() catch {};
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

fn poolChatHook(ctx: ?*anyopaque, cwd: []const u8, session: []const u8, text: []const u8) bool {
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
    webui_mod.ChatQueue.enqueue(ses.qkey, prepared.send);
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
            (tb.handler(alloc, json_args) catch .{ .content = "tool crashed", .is_error = true })
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
