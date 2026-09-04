// cmd_help.zig — `/help` 清单与排版。从 main.zig 拆出。
const std = @import("std");
const activity = @import("core").activity;
const util = @import("core").util;
const tui_mod = @import("tui");
const slashName = tui_mod.slashName;

pub const USAGE =
    \\piz — pi 的 Zig 重写:极简终端编码 agent
    \\
    \\用法:
    \\  piz [目录] [选项]         交互模式
    \\  piz -p "提示词" [选项]    一次性问答(print 模式)
    \\  echo "提示词" | piz -p
    \\
    \\选项:
    \\  -p, --print      print 模式,流式输出到 stdout
    \\  -m, --model M    指定模型
    \\      --provider P 指定 provider
    \\  -n, --new        新会话(默认行为,每次启动都是新会话)
    \\  -c, --continue   续载最近会话
    \\  -t, --title T    新会话标题
    \\  -r, --read-only  只读:危险工具直接拒
    \\  -x, --execute    全权(默认):工具不询问
    \\      --ask        危险工具先问(Codex on-request)
    \\      --sandbox M  bash OS 隔离:off|workspace|strict
    \\  -i, --input FILE 从文件读提示词(print 模式)
    \\  -s, --session ID  恢复指定会话(id 或 sessions 清单序号;id 见退出提示、/sessions、-a)
    \\  -a, --async       print 模式后台运行,立即返回会话 id 与日志路径
    \\  -o, --output FMT  print 模式输出格式:text|json|jsonl(默认 text)
    \\      --system TEXT 自定义系统提示(替代默认)
    \\      --models     列出可用模型
    \\      --plugin N   开启插件(可重复)
    \\      --no-plugin N 关闭插件(可重复,撤钩/工具/schema)
    \\      --plugins    列出全部内置插件与启用状态
    \\      --           之后的参数不再当选项(提示词以 '-' 开头时用)
    \\  pkg 子命令: piz pkg install <path|git-url|name@repo> [-l] [-y] | piz pkg list | piz pkg update | piz pkg remove <name> [-l]
    \\    (资源包:含 skills/、prompts/ 或 AGENTS.md 的目录;-l 安装到项目 .piz/packages)
    \\    (-y 跳过生命周期钩子确认;包声明的钩子会以 bash -c 执行)
    \\  web 子命令: piz web [--port N] [--no-open] [--token T | --no-token]
    \\    (内置 Web UI;默认 127.0.0.1:5494 + 随机 token,URL 含 #token= 片段)
    \\  login 子命令: piz login [provider] [api-key] | piz login --list
    \\    (写 ~/.piz/auth.json;只收 API key,无 OAuth 订阅登录)
    \\  doctor 子命令: piz doctor
    \\    (体检:配置、沙箱后端、联网搜索、git、AGENTS.md)
    \\  init 子命令: piz init
    \\    (工作区没有 AGENTS.md 时写一份脚手架,已有则不覆盖)
    \\  diff 子命令: piz diff
    \\    (git status -sb 与 diff --stat,不需开启 git-awareness)
    \\  commit 子命令: piz commit [message]
    \\    (只提交已暂存;无说明则预览;不自动 git add)
    \\  log 子命令: piz log [n]
    \\    (git log --oneline,默认 20 条,最多 50)
    \\  branch 子命令: piz branch
    \\    (当前分支与最近本地分支,不切换)
    \\  usage 子命令: piz usage
    \\    (token 台账汇总,与 /usage 同源)
    \\  sessions 子命令: piz sessions
    \\    (本目录的会话清单,与 /sessions 同源)
    \\  plugins 子命令: piz plugins
    \\    (内置插件开关状态,与 /plugins 同源)
    \\  memory 子命令: piz memory
    \\    (查看跨会话 memory.md,与 /memory 同源)
    \\  mcp 子命令: piz mcp
    \\    (列出已配置 MCP server 与工具)
    \\  reload 子命令: piz reload
    \\    (重读 settings.json:主题/授权/沙箱;插件需重启)
    \\  evolve 子命令: piz evolve [task-id]
    \\    (自演化修复:按缺陷报告定位根因、修复,跑绿 build/test 后提交)
    \\  -v, --version    版本
    \\  -h, --help       帮助
    \\
    \\配置:~/.piz/settings.json、auth.json、models.json
    \\环境变量:PIZ_DIR、PIZ_PROVIDER、PIZ_MODEL、<PROVIDER>_API_KEY
    \\
;

pub fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (i + n > max) return s[0..i];
        i += n;
    }
    return s;
}

pub fn welcomeNote(alloc: std.mem.Allocator, n_msgs: usize, title: ?[]const u8) ![]u8 {
    if (n_msgs == 0) return alloc.dupe(u8, "new");
    const raw = title orelse "";
    const t = std.mem.trim(u8, raw, " ");
    if (t.len == 0) return std.fmt.allocPrint(alloc, "continued · {d}", .{n_msgs});
    const cut = utf8Prefix(t, 40);
    return std.fmt.allocPrint(alloc, "continued · {s} · {d}", .{ cut, n_msgs });
}

/// 开场卡下挂的轮换 Tip 池:只写真功能(omp "Tip: Did you know?" 位)。
pub const WELCOME_TIPS = [_][]const u8{
    "piz -c 续载上次会话;piz -s <id> 恢复指定会话(id 见 /sessions)",
    "!cmd 直跑 shell 并把输出喂给模型;!!cmd 只跑不喂",
    "@./path 把文件嵌进提示词,输入 @ 后 Tab 补全路径",
    "/compact 快照压缩上下文,不耗 LLM;/undo 撤上一轮",
    "? 空输入时开快捷键浮层;Ctrl+T 折叠思考,Ctrl+O 折叠工具输出",
    "--sandbox workspace 给 bash 套 OS 隔离;/sandbox 运行中随时切",
    "/export 把整段对话导出成 HTML;/copy 复制上条回复",
    "/resume 弹出本目录会话切换器;/title 给当前会话起名",
};

pub fn tildePath(alloc: std.mem.Allocator, abs: []const u8) ![]u8 {
    const home = util.getEnv("HOME") orelse return alloc.dupe(u8, abs);
    if (home.len > 0 and std.mem.startsWith(u8, abs, home))
        return std.fmt.allocPrint(alloc, "~{s}", .{abs[home.len..]});
    return alloc.dupe(u8, abs);
}

pub fn welcomeContext(alloc: std.mem.Allocator) ![]u8 {
    var w = std.Io.Writer.Allocating.init(alloc);
    errdefer w.deinit();
    var any = false;
    if (std.Io.Dir.cwd().statFile(util.io, "AGENTS.md", .{})) |_| {
        try w.writer.writeAll("AGENTS.md");
        any = true;
    } else |_| {}
    if (util.loadSkillsIndex(alloc)) |idx| {
        defer alloc.free(idx);
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, idx, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "- ")) n += 1;
        }
        if (n > 0) {
            if (any) try w.writer.writeAll(" · ");
            try w.writer.print("{d} skills", .{n});
            any = true;
        }
    } else |_| {}
    if (util.loadMemoryMd(alloc)) |mem| {
        defer alloc.free(mem);
        if (mem.len > 0) {
            if (any) try w.writer.writeAll(" · ");
            try w.writer.writeAll("memory");
            any = true;
        }
    } else |_| {}
    if (!any) try w.writer.writeAll("none");
    return w.toOwnedSlice();
}

pub const HelpItem = tui_mod.SlashItem;

/// `/help` 清单。每个真实存在的命令都必须在这里出现 —— 漏掉的等于没实现。
/// main 有测试盯着这份表与实际分发的一致性。TUI slash picker ranks this table.
pub const SLASH_ITEMS = [_]HelpItem{
    .{ .cmd = "/help", .desc = "list commands" },
    .{ .cmd = "/login", .desc = "provider picker → masked key (or /login p <key>)" },
    .{ .cmd = "/logout", .desc = "clear API key (/logout <p> | --all)" },
    .{ .cmd = "/status", .desc = "session card" },
    .{ .cmd = "/doctor", .desc = "environment health check" },
    .{ .cmd = "/init", .desc = "write AGENTS.md if missing" },
    .{ .cmd = "/diff", .desc = "git status + diffstat" },
    .{ .cmd = "/commit [msg]", .desc = "commit staged files only" },
    .{ .cmd = "/log [n]", .desc = "git log --oneline (default 20)" },
    .{ .cmd = "/branch", .desc = "current and recent git branches" },
    .{ .cmd = "/mcp", .desc = "list MCP servers" },
    .{ .cmd = "/reload", .desc = "reload settings.json" },
    .{ .cmd = "/usage", .desc = "token ledger" },
    .{ .cmd = "/extensions", .desc = "loaded JS extensions" },
    .{ .cmd = "/jobs", .desc = "running / background jobs" },
    .{ .cmd = "/jobs kill <pid>", .desc = "kill a tracked job" },
    .{ .cmd = "/workflow", .desc = "workflow status & output" },
    .{ .cmd = "/find", .desc = "search transcript" },
    .{ .cmd = "/paste", .desc = "attach clipboard image" },
    .{ .cmd = "/refresh", .desc = "fetch /models from providers" },
    .{ .cmd = "/think [lvl]", .desc = "thinking level (picker if empty)" },
    .{ .cmd = "/theme [n]", .desc = "theme (dark|light|auto|name)" },
    .{ .cmd = "/permissions [m]", .desc = "approval (picker if empty)" },
    .{ .cmd = "/sandbox [m]", .desc = "OS sandbox (picker if empty)" },
    .{ .cmd = "/model [m]", .desc = "switch model (picker if empty)" },
    .{ .cmd = "/new", .desc = "new session" },
    .{ .cmd = "/sessions", .desc = "sessions in this dir" },
    .{ .cmd = "/resume [n]", .desc = "switch session (picker if empty)" },
    .{ .cmd = "/title <t>", .desc = "set title" },
    .{ .cmd = "/tree", .desc = "message list" },
    .{ .cmd = "/fork <n>", .desc = "fork from message n" },
    .{ .cmd = "/copy", .desc = "copy last reply" },
    .{ .cmd = "/undo", .desc = "undo last turn" },
    .{ .cmd = "/redo", .desc = "resend last input" },
    .{ .cmd = "/memory", .desc = "cross-session memory" },
    .{ .cmd = "/plugins [on|off name]", .desc = "list or toggle plugins" },
    .{ .cmd = "/pkg", .desc = "installed packages" },
    .{ .cmd = "/compact", .desc = "snapcompact (no LLM)" },
    .{ .cmd = "/fast-compress", .desc = "fast-compress status" },
    .{ .cmd = "/clear", .desc = "clear and start over" },
    .{ .cmd = "/plan <goal>", .desc = "write PLAN.md then run" },
    .{ .cmd = "/queue", .desc = "clear input queue" },
    .{ .cmd = "/export", .desc = "export HTML" },
    .{ .cmd = "/dump", .desc = "copy transcript" },
    .{ .cmd = "/quit", .desc = "quit" },
};

pub const EDIT_ITEMS = [_]HelpItem{
    .{ .cmd = "@./path", .desc = "embed a file" },
    .{ .cmd = "!cmd", .desc = "run shell, send to model" },
    .{ .cmd = "!!cmd", .desc = "run shell, show only" },
    .{ .cmd = "?", .desc = "shortcut overlay when empty" },
    .{ .cmd = "c", .desc = "copy last reply when empty" },
    .{ .cmd = "d", .desc = "doctor when empty" },
    .{ .cmd = "g", .desc = "git diff when empty" },
    .{ .cmd = "l", .desc = "git log when empty" },
    .{ .cmd = "r", .desc = "redo last input when empty" },
    .{ .cmd = "s", .desc = "sandbox picker when empty" },
    .{ .cmd = "j", .desc = "list jobs when empty" },
    .{ .cmd = "w", .desc = "workflow details when empty" },
    .{ .cmd = "u", .desc = "token ledger when empty" },
    .{ .cmd = "Esc", .desc = "abort; empty again edits last" },
    .{ .cmd = "Ctrl+C", .desc = "clear; empty again quits" },
    .{ .cmd = "Ctrl+D", .desc = "empty again quits" },
    .{ .cmd = "Tab", .desc = "queue input while busy" },
    .{ .cmd = "Ctrl+B", .desc = "background while busy" },
    .{ .cmd = "Ctrl+T", .desc = "fold thinking" },
    .{ .cmd = "Ctrl+O", .desc = "fold tool output" },
    .{ .cmd = "PgUp/PgDn", .desc = "scroll transcript" },
    .{ .cmd = "Ctrl+↑/↓", .desc = "scroll a few lines" },
    .{ .cmd = "wheel", .desc = "scroll transcript" },
    .{ .cmd = "Alt+,/.", .desc = "think less / more" },
    .{ .cmd = "Shift+↑/↓", .desc = "think less / more" },
};

fn writeHelpCell(w: *std.Io.Writer, it: HelpItem, cmd_cols: usize, cell_cols: usize, pad_cell: bool) !void {
    try w.writeAll("  ");
    try w.writeAll(it.cmd);
    var used: usize = 2 + activity.displayWidth(it.cmd);
    while (used < 2 + cmd_cols) : (used += 1) try w.writeByte(' ');
    try w.writeAll("\x1b[2m");
    const room = if (cell_cols > used) cell_cols - used else 0;
    const cut = activity.truncateToCols(it.desc, room);
    try w.writeAll(it.desc[0..cut]);
    try w.writeAll("\x1b[0m");
    if (pad_cell) {
        used += activity.displayWidth(it.desc[0..cut]);
        while (used < cell_cols) : (used += 1) try w.writeByte(' ');
    }
}

fn writeHelpSection(w: *std.Io.Writer, title: []const u8, items: []const HelpItem, width: usize) !void {
    try w.print("\x1b[2m{s}\x1b[0m\n", .{title});
    const two = width >= 72;
    const cell: usize = if (two) width / 2 else width;
    const cmd_cols: usize = @min(18, if (cell > 12) cell / 2 else 8);
    var i: usize = 0;
    while (i < items.len) {
        try writeHelpCell(w, items[i], cmd_cols, cell, two and i + 1 < items.len);
        if (two and i + 1 < items.len) {
            try writeHelpCell(w, items[i + 1], cmd_cols, cell, false);
        }
        try w.writeByte('\n');
        i += if (two) 2 else 1;
    }
}

fn writeItemArray(alloc: std.mem.Allocator, w: *std.Io.Writer, items: []const HelpItem, slash_prefix: bool) !void {
    try w.writeByte('[');
    var n: usize = 0;
    for (items, 0..) |it, idx| {
        const stem = if (slash_prefix) slashName(it.cmd) else it.cmd;
        if (slash_prefix) {
            var dup = false;
            for (items[0..idx]) |prev| {
                if (std.mem.eql(u8, slashName(prev.cmd), stem)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
        }
        if (n > 0) try w.writeByte(',');
        n += 1;
        const accepts = std.mem.indexOfScalar(u8, it.cmd, '[') != null or std.mem.indexOfScalar(u8, it.cmd, '<') != null;
        const desc_js = try util.jsonString(alloc, it.desc);
        defer alloc.free(desc_js);
        var nbuf: [40]u8 = undefined;
        const labeled = if (slash_prefix) (std.fmt.bufPrint(&nbuf, "/{s}", .{stem}) catch stem) else it.cmd;
        const name_js = try util.jsonString(alloc, labeled);
        defer alloc.free(name_js);
        try w.print("{{\"name\":{s},\"desc\":{s},\"accepts\":{s}}}", .{
            name_js,
            desc_js,
            if (accepts) "true" else "false",
        });
    }
    try w.writeByte(']');
}

pub fn writeCatalogJson(alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    try writeCatalogJsonExtra(alloc, w, &.{});
}

pub fn writeCatalogJsonExtra(alloc: std.mem.Allocator, w: *std.Io.Writer, extra: []const HelpItem) !void {
    try w.writeAll("{\"commands\":");
    if (extra.len == 0) {
        try writeItemArray(alloc, w, &SLASH_ITEMS, true);
    } else {
        var tmp: [96]HelpItem = undefined;
        const n = @min(SLASH_ITEMS.len + extra.len, tmp.len);
        var i: usize = 0;
        for (SLASH_ITEMS) |it| {
            if (i >= n) break;
            tmp[i] = it;
            i += 1;
        }
        for (extra) |it| {
            if (i >= n) break;
            tmp[i] = it;
            i += 1;
        }
        try writeItemArray(alloc, w, tmp[0..i], true);
    }
    try w.writeAll(",\"keys\":");
    try writeItemArray(alloc, w, &EDIT_ITEMS, false);
    try w.writeByte('}');
}

pub fn formatHelp(alloc: std.mem.Allocator, width: usize) ![]u8 {
    return formatHelpExtra(alloc, width, &.{});
}

pub fn formatHelpExtra(alloc: std.mem.Allocator, width: usize, extra: []const HelpItem) ![]u8 {
    var stw = std.Io.Writer.Allocating.init(alloc);
    defer stw.deinit();
    try writeHelpSection(&stw.writer, "commands", &SLASH_ITEMS, width);
    if (extra.len > 0) {
        try stw.writer.writeByte('\n');
        try writeHelpSection(&stw.writer, "plugin", extra, width);
    }
    try stw.writer.writeByte('\n');
    try writeHelpSection(&stw.writer, "keys", &EDIT_ITEMS, width);
    return stw.toOwnedSlice();
}

test "writeCatalogJson lists unique slash names" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aw = std.Io.Writer.Allocating.init(a);
    defer aw.deinit();
    try writeCatalogJson(a, &aw.writer);
    try t.expect(std.mem.indexOf(u8, aw.written(), "\"/help\"") != null);
    try t.expect(std.mem.indexOf(u8, aw.written(), "\"/pkg\"") != null);
    try t.expect(std.mem.indexOf(u8, aw.written(), "\"/plugins\"") != null);
    const jobs = std.mem.count(u8, aw.written(), "\"/jobs\"");
    try t.expectEqual(@as(usize, 1), jobs);
    try t.expect(std.mem.indexOf(u8, aw.written(), "\"keys\":") != null);
    try t.expect(std.mem.indexOf(u8, aw.written(), "Ctrl+T") != null);
}

test "USAGE lists print web pkg login" {
    const t = std.testing;
    try t.expect(std.mem.indexOf(u8, USAGE, "--print") != null);
    try t.expect(std.mem.indexOf(u8, USAGE, "piz web") != null);
    try t.expect(std.mem.indexOf(u8, USAGE, "piz pkg") != null);
    try t.expect(std.mem.indexOf(u8, USAGE, "piz login") != null);
}
