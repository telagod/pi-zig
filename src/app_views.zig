//! app_views.zig —— TUI 只读视图群(欢迎/状态卡/doctor/diff/log/jobs/usage/
//! 回放/复制)。拆自 main.zig(评审 P2)。皆经 main_mod 取 App 与 note 三件套;
//! main.zig 以 pub const 再导出,调用点与测试零改动。
const std = @import("std");
const util = @import("core").util;
const ai = @import("core").ai;
const activity = @import("core").activity;
const pluginsmod = @import("core").plugins;
const sessionmod = @import("core").session;
const sandboxmod = @import("core").sandbox;
const pricing = @import("core").pricing;
const tui_mod = @import("tui");
const cmd_diff = @import("cmd_diff.zig");
const cmd_doctor = @import("cmd_doctor.zig");
const cmd_help = @import("cmd_help.zig");
const main_mod = @import("main.zig");

const App = main_mod.App;
const tuiOk = main_mod.tuiOk;
const tuiNote = main_mod.tuiNote;
const tuiNotes = main_mod.tuiNotes;
const VERSION = main_mod.VERSION;
const welcomeNote = cmd_help.welcomeNote;
const tildePath = cmd_help.tildePath;
const welcomeContext = cmd_help.welcomeContext;

pub fn showWelcome(app: *App, n_msgs: usize) void {
    app.refreshFooter();
    // 裸 piz(新会话、无历史)开场画欢迎卡:cells 0 号位,随对话上滚(omp home 屏)。
    // 幂等:已画过/已有任何 cell 就只刷页脚(tuiOnThink 等后续调用走这里)。
    if (n_msgs != 0 or app.tui.cells.items.len != 0) return;
    const now_ns = std.Io.Clock.now(.real, util.io).nanoseconds;
    var recents_buf: [3]tui_mod.RecentSession = undefined;
    var descs: [3]?sessionmod.Session.Describe = .{ null, null, null };
    defer for (descs) |d| {
        if (d) |dd| {
            var d2 = dd;
            d2.deinit(app.alloc);
        }
    };
    var n_recents: usize = 0;
    const list = sessionmod.Session.list(app.alloc, app.agent.cwd) catch &.{};
    defer for (list) |s| {
        var s2 = s;
        s2.deinit();
    };
    for (list) |s| {
        if (n_recents >= recents_buf.len) break;
        if (std.mem.eql(u8, s.path, app.sess.path)) continue; // 当前空会话不上榜
        const d = s.describe(app.alloc, now_ns) catch continue;
        descs[n_recents] = d;
        recents_buf[n_recents] = .{ .title = d.headline, .when = d.hint };
        n_recents += 1;
    }
    const secs = @as(usize, @intCast(@max(0, @divTrunc(now_ns, std.time.ns_per_s))));
    const tip = cmd_help.WELCOME_TIPS[secs % cmd_help.WELCOME_TIPS.len];
    app.tui.setWelcomeHeader(.{
        .version = VERSION,
        .model = app.agent.model,
        .provider = app.agent.provider.name,
        .recents = recents_buf[0..n_recents],
        .tip = tip,
    }) catch |err| util.debugCatch("tui.welcome", err);
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
                        const preview = main_mod.toolArgsPreview(tc.args);
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

pub fn redoLast(app: *App) void {
    if (app.last_line.len == 0) {
        tuiNote(app, "\x1b[2m", "nothing to redo");
        return;
    }
    tuiOk("tui.user", app.tui.appendUser(app.last_line));
    main_mod.spawnWorker(app, app.last_line, false);
}

pub fn showDiff(app: *App) void {
    const text = cmd_diff.format(app.alloc, app.agent.cwd) catch {
        tuiNote(app, "\x1b[31m", "diff failed");
        return;
    };
    defer app.alloc.free(text);
    tuiNotes(app, "\x1b[2m", text);
}

pub fn showLog(app: *App, raw: []const u8) void {
    const text = cmd_diff.formatLog(app.alloc, app.agent.cwd, cmd_diff.parseLogCount(raw)) catch {
        tuiNote(app, "\x1b[31m", "log failed");
        return;
    };
    defer app.alloc.free(text);
    tuiNotes(app, "\x1b[2m", text);
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
        if (views[i].detail.len > 0) {
            var dw = std.Io.Writer.Allocating.init(app.alloc);
            defer dw.deinit();
            dw.writer.print("    \x1b[2m↳ {s}\x1b[0m", .{views[i].detail}) catch {};
            tuiNote(app, "", dw.written());
        }
    }
}

pub fn showWorkflow(app: *App) void {
    app.tui.mutex.lock(util.io) catch {};
    defer app.tui.mutex.unlock(util.io);

    const goal = app.tui.flow_goal;
    const nodes = app.tui.flow_nodes.items;
    const last_out = app.tui.flow_last_out.items;

    if (nodes.len == 0 and last_out.len == 0) {
        var found: ?*tui_mod.ToolMeta = null;
        var i = app.tui.cells.items.len;
        while (i > 0) {
            i -= 1;
            const c = &app.tui.cells.items[i];
            if (c.kind == .tool and c.tool != null and std.mem.eql(u8, c.tool.?.name, "workflow")) {
                found = &c.tool.?;
                break;
            }
        }
        if (found == null) {
            tuiNote(app, "\x1b[2m", "no workflow has run in this session");
            return;
        }
        const tm = found.?;
        var hw = std.Io.Writer.Allocating.init(app.alloc);
        defer hw.deinit();
        hw.writer.print("workflow: {s}", .{tm.preview}) catch {};
        tuiNote(app, "\x1b[1m", hw.written());
        if (tm.body.items.len > 0) {
            tuiNotes(app, "", tm.body.items);
        }
        return;
    }

    var hw = std.Io.Writer.Allocating.init(app.alloc);
    defer hw.deinit();
    if (goal.len > 0) {
        hw.writer.print("workflow: {s} ({d} nodes)", .{ goal, nodes.len }) catch {};
    } else {
        hw.writer.print("workflow: ({d} nodes)", .{nodes.len}) catch {};
    }
    tuiNote(app, "\x1b[1m", hw.written());

    for (nodes) |n| {
        var nw = std.Io.Writer.Allocating.init(app.alloc);
        defer nw.deinit();
        const mark = switch (n.st) {
            .wait => "○",
            .run => "\x1b[33m●\x1b[0m",
            .ok => "\x1b[32m●\x1b[0m",
            .fail => "\x1b[31m●\x1b[0m",
            .skip => "\x1b[2m·\x1b[0m",
        };
        nw.writer.print("  {s} {s}", .{ mark, n.id }) catch {};
        if (n.role.len > 0) nw.writer.print("  \x1b[2m({s})\x1b[0m", .{n.role}) catch {};
        if (n.last.len > 0) nw.writer.print("  \x1b[2m↳ {s}\x1b[0m", .{n.last}) catch {};
        tuiNote(app, "", nw.written());
    }

    if (last_out.len > 0) {
        tuiNote(app, "\x1b[2m", "--- details & output ---");
        tuiNotes(app, "", last_out);
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
