// cmd_slash.zig — 内置斜杠命令分发。从 main.zig onSubmit 拆出,行为逐字保留。
// 返回 true = 已处理(含 quit);false = 非内置命令,交回插件/模板/未知路径。
const std = @import("std");
const util = @import("core").util;
const cfgmod = @import("core").config;
const sandboxmod = @import("core").sandbox;
const ai = @import("core").ai;
const sessionmod = @import("core").session;
const toolsmod = @import("core").tools;
const mcpmod = @import("core").mcp;
const pluginsmod = @import("core").plugins;
const pkgsmod = @import("core").pkgs;
const compress = @import("core").compress;
const jsrt = @import("core").jsrt;
const tui_mod = @import("tui");
const cmd_help = @import("cmd_help.zig");
const cmd_init = @import("cmd_init.zig");
const cmd_diff = @import("cmd_diff.zig");
const cmd_commit = @import("cmd_commit.zig");
const main_mod = @import("main.zig");

const App = main_mod.App;
const tuiOk = main_mod.tuiOk;
const tuiNote = main_mod.tuiNote;
const tuiNotes = main_mod.tuiNotes;

/// /extensions:JS 扩展可观测量(装了几个文件/工具/命令,加载错几桩)。
fn showExtensions(app: *App) void {
    if (!jsrt.enabled) {
        tuiNote(app, "\x1b[2m", "js extensions disabled (built without -Dquickjs)");
        return;
    }
    var aw = std.Io.Writer.Allocating.init(app.alloc);
    defer aw.deinit();
    const w = &aw.writer;
    w.print("js extensions: {d} file(s) loaded, {d} error(s)", .{ jsrt.loadedCount(), jsrt.loadErrorCount() }) catch return;
    for (jsrt.jsTools()) |t| w.print("\n  tool     {s} — {s}", .{ t.name, t.desc }) catch return;
    for (jsrt.jsCommands()) |cm| w.print("\n  /{s}  {s}", .{ cm.name, cm.desc }) catch return;
    if (jsrt.jsTools().len == 0 and jsrt.jsCommands().len == 0 and jsrt.loadedCount() > 0)
        w.print("\n  (只挂了事件处理器)\n", .{}) catch return;
    tuiNotes(app, "\x1b[2m", aw.written());
}

pub fn dispatch(tui: *tui_mod.Tui, app: *App, cmd: []const u8) anyerror!bool {
    if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "exit") or std.mem.eql(u8, cmd, "q")) {
        app.quit.store(true, .release);
        return true;
    }
    if (std.mem.eql(u8, cmd, "clear")) {
        main_mod.replaceSession(app) catch {
            tuiNote(app, "\x1b[31m", "cannot start new session");
            return true;
        };
        main_mod.showWelcome(app, 0);
        return true;
    }
    if (std.mem.eql(u8, cmd, "new")) {
        main_mod.replaceSession(app) catch {
            tuiNote(app, "\x1b[31m", "cannot start new session");
            return true;
        };
        main_mod.showWelcome(app, 0);
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "title ")) {
        const title = std.mem.trim(u8, cmd["title ".len..], " ");
        app.sess.setTitle(title) catch |err| {
            var bw = std.Io.Writer.Allocating.init(app.alloc);
            defer bw.deinit();
            tuiOk("tui.wr", bw.writer.print("set title failed: {s}", .{@errorName(err)}));
            tuiNote(app, "\x1b[31m", bw.written());
            return true;
        };
        tuiNote(app, "\x1b[2m", if (title.len > 0) "title set" else "title cleared");
        app.refreshFooter();
        return true;
    }
    if (std.mem.eql(u8, cmd, "sessions")) {
        const list = sessionmod.Session.list(app.alloc, app.agent.cwd) catch &.{};
        defer for (list) |s| {
            var s2 = s;
            s2.deinit();
        };
        if (list.len == 0) {
            tuiNote(app, "\x1b[2m", "no sessions yet — /new to start one");
            return true;
        }
        var bw = std.Io.Writer.Allocating.init(app.alloc);
        defer bw.deinit();
        tuiOk("tui.wr", bw.writer.print("{d} sessions:\n", .{list.len}));
        const now_ns = std.Io.Clock.now(.real, util.io).nanoseconds;
        for (list, 0..) |s, i| {
            const d = s.describe(app.alloc, now_ns) catch null;
            defer if (d) |info| info.deinit(app.alloc);
            const head = if (d) |info| info.headline else s.sessionId();
            const meta = if (d) |info| info.hint else "";
            if (std.mem.eql(u8, s.path, app.sess.path)) {
                tuiOk("tui.wr", bw.writer.print("{d}. {s}  {s}  (current)", .{ i + 1, head, meta }));
            } else {
                tuiOk("tui.wr", bw.writer.print("{d}. {s}  {s}", .{ i + 1, head, meta }));
            }
            tuiOk("tui.wr", bw.writer.print("\n", .{}));
        }
        tuiOk("tui.wr", bw.writer.writeAll("use /resume <n> to switch"));
        tuiNote(app, "\x1b[2m", bw.written());
        return true;
    }
    if (std.mem.eql(u8, cmd, "resume") or std.mem.startsWith(u8, cmd, "resume ")) {
        const nstr = if (std.mem.startsWith(u8, cmd, "resume "))
            std.mem.trim(u8, cmd["resume ".len..], " ")
        else
            "";
        if (nstr.len == 0) {
            main_mod.openResumePicker(app);
            return true;
        }
        const n = std.fmt.parseInt(usize, nstr, 10) catch {
            tuiNote(app, "\x1b[31m", "usage: /resume <n>  (see /sessions)");
            return true;
        };
        const list = sessionmod.Session.list(app.alloc, app.agent.cwd) catch &.{};
        if (n == 0 or n > list.len) {
            for (list) |s| {
                var s2 = s;
                s2.deinit();
            }
            tuiNote(app, "\x1b[31m", "no such session");
            return true;
        }
        const target = list[n - 1];
        app.loadSession(target) catch |err| {
            for (list) |s| {
                var s2 = s;
                s2.deinit();
            }
            var bw = std.Io.Writer.Allocating.init(app.alloc);
            defer bw.deinit();
            tuiOk("tui.wr", bw.writer.print("resume failed: {s}", .{@errorName(err)}));
            tuiNote(app, "\x1b[31m", bw.written());
            return true;
        };
        // target 所有权已移交 app.sess;其余释放
        for (list, 0..) |s, i| {
            if (i != n - 1) {
                var s2 = s;
                s2.deinit();
            }
        }
        app.tui.clearScroll();
        main_mod.showWelcome(app, app.agent.messages.items.len);
        main_mod.replayTranscript(app.tui, app.agent.messages.items);
        return true;
    }
    if (std.mem.eql(u8, cmd, "undo")) {
        if (app.worker_active.load(.acquire)) {
            tuiNote(app, "\x1b[31m", "cannot undo while a turn is running");
            return true;
        }
        if (!app.agent.undo()) {
            tuiNote(app, "\x1b[2m", "nothing to undo");
            return true;
        }
        app.sess.truncate(app.agent.messages.items.len) catch |err| util.debugCatch("sess.truncate", err);
        tuiNote(app, "\x1b[2m", "undone last turn");
        return true;
    }
    if (std.mem.eql(u8, cmd, "model") or std.mem.startsWith(u8, cmd, "model ")) {
        const spec = if (std.mem.startsWith(u8, cmd, "model "))
            std.mem.trim(u8, cmd["model ".len..], " ")
        else
            "";
        if (spec.len == 0) {
            main_mod.openModelPicker(app);
            return true;
        }
        app.switchModel(spec) catch |err| {
            var bw = std.Io.Writer.Allocating.init(app.alloc);
            defer bw.deinit();
            tuiOk("tui.wr", bw.writer.print("switch model failed: {s}", .{@errorName(err)}));
            tuiNote(app, "\x1b[31m", bw.written());
            return true;
        };
        main_mod.showWelcome(app, app.agent.messages.items.len);
        return true;
    }
    if (std.mem.eql(u8, cmd, "compact")) {
        tuiNote(app, "\x1b[2m", "snapcompact…");
        main_mod.spawnWorker(app, "", true);
        return true;
    }
    if (std.mem.eql(u8, cmd, "fast-compress")) {
        const msg = compress.formatStatus(app.alloc, .{
            .alloc = app.alloc,
            .messages = &app.agent.messages,
            .window = app.agent.ctxWindow(),
            .api = app.agent.provider.api,
            .vision = app.agent.hasVision(),
        });
        tuiNote(app, "\x1b[2m", msg);
        return true;
    }
    if (std.mem.eql(u8, cmd, "redo")) {
        main_mod.redoLast(app);
        return true;
    }
    if (std.mem.eql(u8, cmd, "memory")) {
        const mem_path = util.configDir(app.alloc) catch {
            tuiNote(app, "\x1b[31m", "no config dir");
            return true;
        };
        const full = util.joinPath(app.alloc, mem_path, "memory.md") catch {
            tuiNote(app, "\x1b[31m", "cannot build path");
            return true;
        };
        const content = std.Io.Dir.cwd().readFileAlloc(util.io, full, app.alloc, .limited(512 * 1024)) catch {
            tuiNote(app, "\x1b[2m", "memory is empty — /memory set <text> to add");
            return true;
        };
        defer app.alloc.free(content);
        var bw = std.Io.Writer.Allocating.init(app.alloc);
        defer bw.deinit();
        tuiOk("tui.wr", bw.writer.writeAll("🧠 memory.md:\n"));
        tuiOk("tui.wr", bw.writer.writeAll(content[0..@min(content.len, 4000)]));
        if (content.len > 4000) tuiOk("tui.wr", bw.writer.writeAll("\n…(truncated)"));
        tuiOk("tui.wr", bw.writer.print("\nusage: /memory set <text> | /memory clear", .{}));
        tuiNote(app, "\x1b[2m", bw.written());
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "memory set ")) {
        const text = std.mem.trim(u8, cmd["memory set ".len..], " ");
        if (text.len == 0) {
            tuiNote(app, "\x1b[31m", "usage: /memory set <text>");
            return true;
        }
        const mem_path = util.configDir(app.alloc) catch {
            tuiNote(app, "\x1b[31m", "no config dir");
            return true;
        };
        const full = util.joinPath(app.alloc, mem_path, "memory.md") catch {
            tuiNote(app, "\x1b[31m", "cannot build path");
            return true;
        };
        const mline = std.fmt.allocPrint(app.alloc, "{s}\n", .{text}) catch {
            tuiNote(app, "\x1b[31m", "oom");
            return true;
        };
        // 追加(已存在)或新建
        var f = std.Io.Dir.cwd().createFile(util.io, full, .{ .exclusive = true, .permissions = @enumFromInt(0o600) }) catch |err| switch (err) {
            error.PathAlreadyExists => std.Io.Dir.cwd().openFile(util.io, full, .{ .mode = .write_only }) catch {
                tuiNote(app, "\x1b[31m", "cannot open memory.md");
                return true;
            },
            else => {
                tuiNote(app, "\x1b[31m", "cannot create memory.md");
                return true;
            },
        };
        defer f.close(util.io);
        var wbuf: [1024]u8 = undefined;
        var w = f.writer(util.io, &wbuf);
        w.seekTo(f.length(util.io) catch 0) catch |err| util.debugCatch("memory-set.seek", err);
        w.interface.writeAll(mline) catch |err| util.debugCatch("memory-set.write", err);
        w.flush() catch |err| util.debugCatch("memory-set.flush", err);
        var bw = std.Io.Writer.Allocating.init(app.alloc);
        defer bw.deinit();
        tuiOk("tui.wr", bw.writer.print("🧠 memory saved: {s}", .{text[0..@min(text.len, 60)]}));
        tuiNote(app, "\x1b[2m", bw.written());
        return true;
    }
    if (std.mem.eql(u8, cmd, "memory clear")) {
        const mem_path = util.configDir(app.alloc) catch {
            tuiNote(app, "\x1b[31m", "no config dir");
            return true;
        };
        const full = util.joinPath(app.alloc, mem_path, "memory.md") catch {
            tuiNote(app, "\x1b[31m", "cannot build path");
            return true;
        };
        std.Io.Dir.cwd().deleteFile(util.io, full) catch {};
        tuiNote(app, "\x1b[2m", "memory cleared");
        return true;
    }
    if (std.mem.eql(u8, cmd, "plugins") or std.mem.startsWith(u8, cmd, "plugins ")) {
        const rest = std.mem.trim(u8, if (cmd.len > 7) cmd[7..] else "", " ");
        if (rest.len == 0) {
            const body = pluginsmod.listPluginsIn(app.alloc, app.agent.plugins) catch {
                tuiNote(app, "\x1b[31m", "cannot list plugins");
                return true;
            };
            defer app.alloc.free(body);
            var bw = std.Io.Writer.Allocating.init(app.alloc);
            defer bw.deinit();
            tuiOk("tui.wr", bw.writer.writeAll("plugins (this session; next turn):\n"));
            tuiOk("tui.wr", bw.writer.writeAll(body));
            tuiOk("tui.wr", bw.writer.writeAll("usage: /plugins on <name> | /plugins off <name>"));
            tuiNote(app, "\x1b[2m", bw.written());
            return true;
        }
        var it = std.mem.splitScalar(u8, rest, ' ');
        const verb = it.next() orelse "";
        const name = std.mem.trim(u8, it.rest(), " ");
        const on = std.mem.eql(u8, verb, "on");
        const off = std.mem.eql(u8, verb, "off");
        if ((!on and !off) or name.len == 0) {
            tuiNote(app, "\x1b[31m", "usage: /plugins on <name> | /plugins off <name>");
            return true;
        }
        if (!pluginsmod.known(name)) {
            tuiNote(app, "\x1b[31m", "unknown plugin — /plugins");
            return true;
        }
        app.agent.plugins = if (on)
            pluginsmod.withEnabled(app.agent.plugins, name)
        else
            pluginsmod.withoutEnabled(app.agent.plugins, name);
        // 抽离件(jsrt 内嵌)门控重推 + 重扫
        pluginsmod.refreshExtracted(app.alloc, app.agent.plugins);
        if (on) {
            _ = pluginsmod.enable(name);
        } else {
            _ = pluginsmod.disable(name);
        }
        app.cfg.savePluginToggle(name, on, pluginsmod.isFactoryOn(name)) catch |err| util.debugCatch("plugins.save", err);
        main_mod.rebuildSlashCatalog(app);
        var bw = std.Io.Writer.Allocating.init(app.alloc);
        defer bw.deinit();
        tuiOk("tui.wr", bw.writer.print("plugin {s} {s} — next turn", .{ name, if (on) "on" else "off" }));
        tuiNote(app, "\x1b[2m", bw.written());
        return true;
    }
    if (std.mem.eql(u8, cmd, "pkg")) {
        const user = pkgsmod.list(app.alloc, .user, app.agent.cwd) catch &.{};
        const proj = pkgsmod.list(app.alloc, .project, app.agent.cwd) catch &.{};
        var bw = std.Io.Writer.Allocating.init(app.alloc);
        defer bw.deinit();
        tuiOk("pkg.u", bw.writer.print("user packages ({d}):\n", .{user.len}));
        for (user) |p| {
            tuiOk("pkg.ur", bw.writer.print("  {s}  skills:{d} prompts:{d}{s}{s}\n", .{
                p.name,
                p.skills,
                p.prompts,
                if (p.has_agents) " agents:yes" else "",
                if (p.has_web) " web:yes" else "",
            }));
        }
        tuiOk("pkg.p", bw.writer.print("project packages ({d}):\n", .{proj.len}));
        for (proj) |p| {
            tuiOk("pkg.pr", bw.writer.print("  {s}  skills:{d} prompts:{d}{s}{s}\n", .{
                p.name,
                p.skills,
                p.prompts,
                if (p.has_agents) " agents:yes" else "",
                if (p.has_web) " web:yes" else "",
            }));
        }
        if (user.len + proj.len == 0) tuiOk("pkg.none", bw.writer.writeAll("  (none)\n"));
        tuiOk("pkg.hint", bw.writer.writeAll("install: piz pkg install <path> [-l]"));
        tuiNote(app, "\x1b[2m", bw.written());
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "fork ")) {
        const nstr = std.mem.trim(u8, cmd["fork ".len..], " ");
        const n = std.fmt.parseInt(usize, nstr, 10) catch {
            tuiNote(app, "\x1b[31m", "usage: /fork <n>  (see /tree)");
            return true;
        };
        if (n == 0 or n > app.agent.messages.items.len) {
            tuiNote(app, "\x1b[31m", "no such message");
            return true;
        }
        const new_sess = app.sess.fork(n) catch |err| {
            var bw = std.Io.Writer.Allocating.init(app.alloc);
            defer bw.deinit();
            tuiOk("tui.wr", bw.writer.print("fork failed: {s}", .{@errorName(err)}));
            tuiNote(app, "\x1b[31m", bw.written());
            return true;
        };
        app.loadSession(new_sess) catch |err| util.debugCatch("loadSession", err);
        var bw = std.Io.Writer.Allocating.init(app.alloc);
        defer bw.deinit();
        tuiOk("tui.wr", bw.writer.print("forked {d} messages -> session {s}", .{ n, std.fs.path.basename(app.sess.path) }));
        tuiNote(app, "\x1b[2m", bw.written());
        app.refreshFooter();
        return true;
    }
    if (std.mem.eql(u8, cmd, "tree")) {
        var bw = std.Io.Writer.Allocating.init(app.alloc);
        defer bw.deinit();
        tuiOk("tui.wr", bw.writer.print("{d} messages:\n", .{app.agent.messages.items.len}));
        for (app.agent.messages.items, 0..) |m, i| {
            const tag: []const u8 = switch (m.role[0]) {
                'u' => ">",
                'a' => "<",
                't' => "tool",
                else => "-",
            };
            const head = m.content[0..@min(m.content.len, 50)];
            tuiOk("tui.wr", bw.writer.print("{d}. {s} {s}\n", .{ i + 1, tag, head }));
        }
        tuiOk("tui.wr", bw.writer.writeAll("use /fork <n> to branch from a message"));
        tuiNote(app, "\x1b[2m", bw.written());
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "plan")) {
        // 计划模式:让模型制定计划写入 PLAN.md,随后按计划执行。
        // startsWith:既匹配 /plan(显示用法)也匹配 /plan <goal>。
        const goal = std.mem.trim(u8, cmd["plan".len..], " ");
        if (goal.len == 0) {
            tuiNote(app, "\x1b[31m", "usage: /plan <goal>");
            return true;
        }
        const full_line = try std.fmt.allocPrint(app.alloc, "/{s}", .{cmd});
        defer app.alloc.free(full_line);
        tuiOk("tui.user", app.tui.appendUser(full_line));
        main_mod.spawnWorker(app, try std.fmt.allocPrint(app.alloc, "Create a detailed step-by-step plan for: {s}. Write the plan to PLAN.md in the project root, then briefly state you are ready to execute it.", .{goal}), false);
        return true;
    }
    if (std.mem.eql(u8, cmd, "export") or std.mem.eql(u8, cmd, "dump")) {
        // 导出会话:HTML 文件(/export)或剪贴板文本(/dump)
        const is_export = std.mem.eql(u8, cmd, "export");
        var ww = std.Io.Writer.Allocating.init(app.alloc);
        defer ww.deinit();
        const w = &ww.writer;
        if (is_export) try w.writeAll("<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>piz session</title></head><body>");
        for (app.agent.messages.items) |m| {
            const role = m.role;
            const body = std.mem.replaceOwned(u8, app.alloc, m.content, "&", "&amp;") catch continue;
            defer app.alloc.free(body);
            const esc = std.mem.replaceOwned(u8, app.alloc, body, "<", "&lt;") catch continue;
            defer app.alloc.free(esc);
            if (is_export) {
                try w.print("<p><b>{s}</b><br><pre>{s}</pre></p>\n", .{ role, esc });
            } else {
                try w.print("--- {s} ---\n{s}\n", .{ role, esc });
            }
        }
        if (is_export) try w.writeAll("</body></html>\n");
        if (is_export) {
            const fname = "piz-export.html";
            std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = fname, .data = ww.written() }) catch {
                tuiNote(app, "\x1b[31m", "export failed");
                return true;
            };
            tuiNote(app, "\x1b[2m", "exported to piz-export.html");
        } else {
            if (main_mod.copyToClipboard(app.alloc, ww.written())) {
                tuiNote(app, "\x1b[2m", "session copied to clipboard");
            } else {
                tuiNote(app, "\x1b[31m", "no clipboard tool (wl-copy/xclip); /tmp fallback");
                std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = "/tmp/piz-dump.txt", .data = ww.written() }) catch |err| util.debugCatch("dump.file", err);
            }
        }
        return true;
    }
    if (std.mem.eql(u8, cmd, "copy")) {
        main_mod.copyLastReply(app);
        return true;
    }
    if (std.mem.eql(u8, cmd, "queue")) {
        if (app.queue.items.len == 0) {
            tuiNote(app, "\x1b[2m", "queue empty");
            return true;
        }
        app.clearQueue();
        tuiNote(app, "\x1b[2m", "queued messages cleared");
        return true;
    }
    if (std.mem.eql(u8, cmd, "status")) {
        main_mod.showStatusCard(app);
        app.refreshFooter();
        return true;
    }
    if (std.mem.eql(u8, cmd, "doctor")) {
        main_mod.showDoctor(app);
        return true;
    }
    if (std.mem.eql(u8, cmd, "reload")) {
        const text = app.cfg.reloadSettings() catch {
            tuiNote(app, "\x1b[31m", "reload failed");
            return true;
        };
        tui_mod.applyTheme(app.cfg.theme);
        app.approval = app.cfg.default_approval;
        if (app.cfg.default_think_level) |lv| {
            app.tui.think_level = cfgmod.clampThinkLevel(app.agent.modelMeta(), lv);
            app.agent.think_level = app.tui.think_level;
        }
        tuiNotes(app, "\x1b[2m", text);
        // JS 扩展同刷:重置 prelude 注册表后重扫全局目+项目目。
        if (jsrt.enabled) {
            if (util.configDir(app.alloc)) |cd| {
                defer app.alloc.free(cd);
                pluginsmod.pushGates(app.alloc, app.agent.plugins);
                const trusted = app.agent.cfg.isWorkspaceTrusted(app.agent.cwd);
                jsrt.reload(cd, app.agent.cwd, trusted);
                tuiNote(app, "\x1b[2m", "js extensions reloaded");
            } else |_| {}
        }
        return true;
    }
    if (std.mem.eql(u8, cmd, "mcp")) {
        const text = mcpmod.formatStatus(app.alloc) catch {
            tuiNote(app, "\x1b[31m", "mcp failed");
            return true;
        };
        defer app.alloc.free(text);
        tuiNotes(app, "\x1b[2m", text);
        return true;
    }
    if (std.mem.eql(u8, cmd, "branch")) {
        const text = cmd_diff.formatBranch(app.alloc, app.agent.cwd) catch {
            tuiNote(app, "\x1b[31m", "branch failed");
            return true;
        };
        defer app.alloc.free(text);
        tuiNotes(app, "\x1b[2m", text);
        return true;
    }
    if (std.mem.eql(u8, cmd, "log") or std.mem.startsWith(u8, cmd, "log ")) {
        const raw = if (std.mem.startsWith(u8, cmd, "log ")) std.mem.trim(u8, cmd["log ".len..], " ") else "";
        main_mod.showLog(app, raw);
        return true;
    }
    if (std.mem.eql(u8, cmd, "commit") or std.mem.startsWith(u8, cmd, "commit ")) {
        const msg = if (std.mem.startsWith(u8, cmd, "commit ")) std.mem.trim(u8, cmd["commit ".len..], " ") else "";
        const text = cmd_commit.run(app.alloc, app.agent.cwd, msg) catch {
            tuiNote(app, "\x1b[31m", "commit failed");
            return true;
        };
        defer app.alloc.free(text);
        tuiNotes(app, "\x1b[2m", text);
        return true;
    }
    if (std.mem.eql(u8, cmd, "diff")) {
        main_mod.showDiff(app);
        return true;
    }
    if (std.mem.eql(u8, cmd, "init")) {
        const text = cmd_init.writeAgents(app.alloc, app.agent.cwd) catch {
            tuiNote(app, "\x1b[31m", "init failed");
            return true;
        };
        defer app.alloc.free(text);
        tuiNote(app, "\x1b[2m", text);
        return true;
    }
    if (std.mem.eql(u8, cmd, "jobs") or std.mem.startsWith(u8, cmd, "jobs ") or
        std.mem.eql(u8, cmd, "kill") or std.mem.startsWith(u8, cmd, "kill "))
    {
        const rest = if (std.mem.startsWith(u8, cmd, "jobs kill"))
            std.mem.trim(u8, cmd["jobs kill".len..], " ")
        else if (std.mem.startsWith(u8, cmd, "kill "))
            std.mem.trim(u8, cmd["kill ".len..], " ")
        else
            "";
        if (rest.len > 0) {
            const pid = std.fmt.parseInt(std.posix.pid_t, rest, 10) catch {
                tuiNote(app, "\x1b[31m", "usage: /jobs kill <pid>");
                return true;
            };
            if (toolsmod.killTracked(pid)) {
                var bw = std.Io.Writer.Allocating.init(app.alloc);
                defer bw.deinit();
                tuiOk("tui.wr", bw.writer.print("killed pid {d}", .{pid}));
                tuiNote(app, "\x1b[2m", bw.written());
            } else {
                tuiNote(app, "\x1b[31m", "no tracked job with that pid");
            }
            return true;
        }
        main_mod.showJobs(app);
        return true;
    }
    if (std.mem.eql(u8, cmd, "workflow") or std.mem.eql(u8, cmd, "flow")) {
        main_mod.showWorkflow(app);
        return true;
    }
    if (std.mem.eql(u8, cmd, "extensions")) {
        showExtensions(app);
        return true;
    }
    if (std.mem.eql(u8, cmd, "usage")) {
        main_mod.showUsage(app);
        return true;
    }
    if (std.mem.eql(u8, cmd, "paste")) {
        app.tui.pasteClipboard();
        if (app.tui.pending_image != null) {
            tuiNote(app, "\x1b[2m", "image attached — enter to send");
        } else {
            tuiNote(app, "\x1b[2m", "no image on clipboard");
        }
        return true;
    }
    if (std.mem.eql(u8, cmd, "find") or std.mem.startsWith(u8, cmd, "find ")) {
        const q = if (std.mem.startsWith(u8, cmd, "find "))
            std.mem.trim(u8, cmd["find ".len..], " ")
        else
            app.tui.search_q;
        if (q.len == 0) {
            tuiNote(app, "\x1b[2m", "usage: /find <text>");
            return true;
        }
        if (app.tui.findNext(q, false) catch false) {
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "found #{d}: {s}", .{ (app.tui.search_hit orelse 0) + 1, q }) catch "found";
            tuiNote(app, "\x1b[2m", msg);
        } else {
            tuiNote(app, "\x1b[2m", "no match");
        }
        return true;
    }
    if (std.mem.eql(u8, cmd, "refresh")) {
        main_mod.refreshProviderModels(app);
        return true;
    }
    if (std.mem.eql(u8, cmd, "permissions") or std.mem.startsWith(u8, cmd, "permissions ") or
        std.mem.eql(u8, cmd, "approvals") or std.mem.startsWith(u8, cmd, "approvals "))
    {
        const raw = if (std.mem.startsWith(u8, cmd, "permissions "))
            std.mem.trim(u8, cmd["permissions ".len..], " ")
        else if (std.mem.startsWith(u8, cmd, "approvals "))
            std.mem.trim(u8, cmd["approvals ".len..], " ")
        else
            "";
        if (raw.len == 0) {
            main_mod.openApprovalPicker(app);
            return true;
        }
        const mode = cfgmod.ApprovalMode.parse(raw) orelse {
            tuiNote(app, "\x1b[31m", "usage: /permissions yolo|ask|read-only");
            return true;
        };
        main_mod.applyApproval(app, mode);
        var bw = std.Io.Writer.Allocating.init(app.alloc);
        defer bw.deinit();
        tuiOk("tui.wr", bw.writer.print("permissions {s}", .{mode.uiLabel()}));
        tuiNote(app, "\x1b[2m", bw.written());
        app.refreshFooter();
        return true;
    }
    if (std.mem.eql(u8, cmd, "sandbox") or std.mem.startsWith(u8, cmd, "sandbox ")) {
        const raw = if (std.mem.startsWith(u8, cmd, "sandbox "))
            std.mem.trim(u8, cmd["sandbox ".len..], " ")
        else
            "";
        if (raw.len == 0) {
            main_mod.openSandboxPicker(app);
            return true;
        }
        const mode = cfgmod.SandboxMode.parse(raw) orelse {
            tuiNote(app, "\x1b[31m", "usage: /sandbox off|workspace|strict");
            return true;
        };
        main_mod.applySandbox(app, mode);
        const shown = sandboxmod.describe(app.alloc, mode) catch mode.uiLabel();
        tuiNote(app, "\x1b[2m", shown);
        app.refreshFooter();
        return true;
    }
    if (std.mem.eql(u8, cmd, "think") or std.mem.startsWith(u8, cmd, "think ")) {
        const arg = if (std.mem.startsWith(u8, cmd, "think "))
            std.mem.trim(u8, cmd["think ".len..], " ")
        else
            "";
        const meta = app.agent.modelMeta();
        if (arg.len == 0) {
            main_mod.openThinkPicker(app);
            return true;
        }
        const level = ai.ThinkLevel.parse(arg) orelse {
            var bw = std.Io.Writer.Allocating.init(app.alloc);
            defer bw.deinit();
            tuiOk("tui.wr", bw.writer.writeAll("usage: /think "));
            tuiOk("tui.wr", cfgmod.writeSupportedThink(&bw.writer, meta));
            tuiNote(app, "\x1b[31m", bw.written());
            return true;
        };
        const clamped = cfgmod.clampThinkLevel(meta, level);
        app.tui.think_level = clamped;
        app.agent.think_level = clamped;
        main_mod.persistThink(app);
        main_mod.showWelcome(app, app.agent.messages.items.len);
        var bw = std.Io.Writer.Allocating.init(app.alloc);
        defer bw.deinit();
        if (clamped != level)
            tuiOk("tui.wr", bw.writer.print("think {s} (this model has no {s})", .{ tui_mod.thinkLabel(clamped), level.label() }))
        else
            tuiOk("tui.wr", bw.writer.print("think {s}", .{tui_mod.thinkLabel(clamped)}));
        tuiNote(app, "\x1b[2m", bw.written());
        return true;
    }
    if (std.mem.eql(u8, cmd, "theme") or std.mem.startsWith(u8, cmd, "theme ")) {
        const arg = if (std.mem.startsWith(u8, cmd, "theme "))
            std.mem.trim(u8, cmd["theme ".len..], " ")
        else
            "";
        if (arg.len == 0) {
            main_mod.openThemePicker(app);
            return true;
        }
        tui_mod.applyTheme(arg);
        main_mod.persistTheme(app, arg);
        var bw = std.Io.Writer.Allocating.init(app.alloc);
        defer bw.deinit();
        tuiOk("tui.wr", bw.writer.print("theme {s}", .{tui_mod.theme.name}));
        tuiNote(app, "\x1b[2m", bw.written());
        return true;
    }
    if (std.mem.eql(u8, cmd, "login") or std.mem.startsWith(u8, cmd, "login ")) {
        const loginmod = @import("cmd_login.zig");
        const rest = if (std.mem.startsWith(u8, cmd, "login ")) std.mem.trim(u8, cmd["login ".len..], " ") else "";
        // /login:provider 选择器(对齐 piz login 交互流)
        if (rest.len == 0) {
            main_mod.openLoginPicker(app);
            return true;
        }
        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        const name = it.next() orelse "";
        const tail = std.mem.trim(u8, it.rest(), " ");
        // /login <name> --oauth:订阅指路 web
        if (std.mem.eql(u8, tail, "--oauth")) {
            tuiNote(app, "\x1b[2m", "订阅/OAuth 走 piz web → Settings → Account(CLI/TUI 只存 API key)");
            return true;
        }
        // /login <name> [--apikey]:掩码输入;OAuth 可用的先分流凭据方式
        if (tail.len == 0 or std.mem.eql(u8, tail, "--apikey")) {
            if (tail.len == 0 and loginmod.providerOAuth(name)) {
                main_mod.openLoginMethodPicker(app, name);
                return true;
            }
            tuiOk("tui.secret", app.tui.openSecretModal(name));
            return true;
        }
        // /login <name> <key>:一把写(脚本向;密钥不进 history.txt —— onSubmit 已滤)
        main_mod.saveLogin(app, name, tail);
        return true;
    }
    if (std.mem.eql(u8, cmd, "logout") or std.mem.startsWith(u8, cmd, "logout ")) {
        const rest = if (std.mem.startsWith(u8, cmd, "logout ")) std.mem.trim(u8, cmd["logout ".len..], " ") else "";
        if (rest.len == 0) {
            tuiNote(app, "\x1b[2m", "usage: /logout <provider> | /logout --all");
            return true;
        }
        main_mod.logoutLogin(app, rest);
        return true;
    }
    if (std.mem.eql(u8, cmd, "help")) {
        const text = cmd_help.formatHelpExtra(app.alloc, app.tui.width, app.slash_extra[0..app.slash_extra_n]) catch return true;
        defer app.alloc.free(text);
        tuiNote(app, "", text);
        return true;
    }
    _ = tui;
    return false;
}
