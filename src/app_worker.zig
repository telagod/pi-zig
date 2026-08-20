//! app_worker.zig —— TUI 回合执行群:权限闸、worker 线程、提交路由、中止/转后台。
//! 拆自 main.zig(评审 P2 末刀)。皆经 main_mod 取 App 与工具函数;
//! main.zig 以 const 再导出,回调接线与 cmd_slash 调用点零改动。
//!
//! 并发纪律:workerMain 跑独立线程,与主循环经原子量(streaming/worker_active/
//! abort/perm.*)与 TUI 内部锁通信;权限闸由 worker 线程阻塞轮询、主循环按键
//! 应答(tuiOnPermKey)。
const std = @import("std");
const util = @import("core").util;
const jsrt = @import("core").jsrt;
const activity = @import("core").activity;
const ai = @import("core").ai;
const sessionmod = @import("core").session;
const toolsmod = @import("core").tools;
const pluginsmod = @import("core").plugins;
const pricing = @import("core").pricing;
const tui_mod = @import("tui");
const cmd_slash = @import("cmd_slash.zig");
const main_mod = @import("main.zig");

const App = main_mod.App;
const tuiOk = main_mod.tuiOk;
const tuiNote = main_mod.tuiNote;

pub fn tuiOnRequirePermission(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!bool {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (app.perm.always.load(.acquire)) return true;
    const gate = toolsmod.toolGate(app.approval, name);
    if (gate == .allow) return true;
    if (gate == .deny or app.read_only) return false;
    app.perm.buf.clearRetainingCapacity();
    try app.perm.buf.appendSlice("? ");
    try app.perm.buf.appendSlice(name);
    const preview = main_mod.toolArgsPreview(args);
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
pub fn tuiOnPermKey(ctx: ?*anyopaque, key: u8) void {
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

pub const WorkerCtx = struct {
    app: *App,
    line: []const u8,
    is_compact: bool = false,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub fn workerMain(wctx: *WorkerCtx) void {
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

pub fn onSubmit(tui: *tui_mod.Tui, line: []const u8) anyerror!void {
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
                if (jsrt.runCommand(ja.allocator(), sname, sargs, app.agent.jsStatsJson(ja.allocator()))) |out| {
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
pub fn onAbort(ctx: ?*anyopaque) void {
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
pub fn onDetach(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    const n = activity.detachAll();
    var buf: [128]u8 = undefined;
    const msg = if (n > 0)
        std.fmt.bufPrint(&buf, "{d} activity(s) moved to background — no wall-clock limit, Ctrl+C won't cancel them", .{n}) catch "moved to background"
    else
        "nothing running to move to background";
    tuiNote(app, "\x1b[2m", msg);
}

pub fn tuiOnAbort(ctx: ?*anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    return app.abort.load(.acquire) or app.agent.aborted.load(.acquire);
}

pub fn isQuit(ctx: ?*anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(ctx orelse return false));
    return app.quit.load(.acquire);
}
