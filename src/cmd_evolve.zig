// cmd_evolve.zig —— 自演化执行器。
//
// `piz evolve [--all] [--dry-run] [--limit N]`:
//   1. 读 ~/.piz/evolve/queue.jsonl(前端 /api/evolve/sink 采集的缺陷条目)
//   2. 取 open 条目 → 构造缺陷 prompt → 内置 agent 在仓库根修复
//      (读码 → edit → zig build → zig build test → git commit "evolve: <id> …")
//   3. 后验:git log 有 evolve: 提交 → done;工作区脏而没提交 →
//      `git checkout -- .` 还原,标 failed(自改不许留半成品)
//   4. 回写条目 state/attempts/note/commit
//
// 安全闸:turn_cap=8(agent.zig 回合帽)、attempts 上限 2(同一缺陷至多重试
// 一次)、只提交 evolve: 前缀的提交、无提交则全部还原。

const std = @import("std");
const util = @import("core").util;
const cfgmod = @import("core").config;
const agentmod = @import("core").agent;
const sessionmod = @import("core").session;
const pluginsmod = @import("core").plugins;

const ATTEMPT_MAX: usize = 2;
const TURN_CAP: usize = 12;

const Entry = struct {
    id: []const u8 = "",
    ts: i64 = 0,
    kind: []const u8 = "",
    where: []const u8 = "",
    msg: []const u8 = "",
    stack: []const u8 = "",
    session: []const u8 = "",
    state: []const u8 = "open",
    attempts: usize = 0,
    note: []const u8 = "",
    commit: []const u8 = "",
};

pub fn runEvolve(alloc: std.mem.Allocator, args: *std.process.Args.Iterator) noreturn {
    var all = false;
    var dry = false;
    var limit: usize = 1;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--all")) {
            all = true;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            dry = true;
        } else if (std.mem.eql(u8, a, "--limit")) {
            limit = std.fmt.parseInt(usize, args.next() orelse "3", 10) catch 3;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                \\piz evolve [--all] [--dry-run] [--limit N]
                \\
                \\  采集队列(~/.piz/evolve/queue.jsonl)里的 open 缺陷,交给内置
                \\  agent 在仓库根修复:定位根因 → 改源码 → zig build/test → 绿则
                \\  git commit "evolve: <id> …"。失败自动还原改动并登记。
                \\
                \\  --all      循环处理全部 open(默认只 1 条)
                \\  --dry-run  只打印条目与任务 prompt,不跑 agent
                \\  --limit N  至多 N 条(默认 3)
                \\
            , .{});
            std.process.exit(0);
        } else {
            std.debug.print("piz evolve: unknown arg {s} (see --help)\n", .{a});
            std.process.exit(1);
        }
    }
    if (all) limit = if (limit < 3) 3 else limit;

    const qp = util.evolveQueuePath(alloc) catch {
        std.debug.print("piz evolve: cannot resolve queue path\n", .{});
        std.process.exit(1);
    };
    const data = util.readFile(alloc, qp) catch {
        std.debug.print("piz evolve: queue not found at {s} (nothing collected yet)\n", .{qp});
        std.process.exit(0);
    };
    // 解析全部条目
    var entries = std.array_list.Managed(Entry).init(alloc);
    {
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{}) catch continue;
            if (v != .object) continue;
            const e = Entry{
                .id = jsonStr(v, "id") orelse "",
                .ts = @intCast(jsonInt(v, "ts", 0)),
                .kind = jsonStr(v, "kind") orelse "",
                .where = jsonStr(v, "where") orelse "",
                .msg = jsonStr(v, "msg") orelse "",
                .stack = jsonStr(v, "stack") orelse "",
                .session = jsonStr(v, "session") orelse "",
                .state = jsonStr(v, "state") orelse "open",
                .attempts = jsonInt(v, "attempts", 0),
                .note = jsonStr(v, "note") orelse "",
                .commit = jsonStr(v, "commit") orelse "",
            };
            entries.append(e) catch {};
        }
    }

    var done_n: usize = 0;
    var fail_n: usize = 0;
    var skipped_n: usize = 0;
    var processed: usize = 0;

    for (entries.items) |*e| {
        if (processed >= limit) break;
        // 可处理:done/exhausted 之外全部重试(配额之内)。
        if (std.mem.eql(u8, e.state, "done") or std.mem.eql(u8, e.state, "exhausted")) continue;
        if (e.attempts >= ATTEMPT_MAX) {
            // 配额用尽:标记 exhausted,不再处理
            e.state = "exhausted";
            e.note = "attempt limit reached";
            rewriteQueue(qp, alloc, entries.items) catch {};
            skipped_n += 1;
            continue;
        }
        processed += 1;
        e.attempts += 1;

        // 任务隔离:先把工作区未提交改动(含 untracked)stash 起来,任务跑在
        // 干净基线上 —— 否则 agent 的 git add -A 会把开发中的改动卷进提交,
        // 失败后的还原也会毁掉它们(首版实机踩坑:evolve 自身 checkout -- .
        // 把开发中的 src/main.zig 改动全撤了)。任务结束 pop 回来;冲突时
        // 保留 stash(evolve-<id>)并记入 note。
        const stash_tag = std.fmt.allocPrint(alloc, "evolve-{s}", .{e.id}) catch "evolve";
        // 仅当 stash 列表真正新增条目才算成功(「No local changes」时 push 退出码也是 0)
        const stash_before = gitOut(alloc, ".", &.{ "stash", "list" }) orelse "";
        const stash_code = gitCode(".", &.{ "stash", "push", "-u", "-m", stash_tag });
        const stash_after = gitOut(alloc, ".", &.{ "stash", "list" }) orelse "";
        const stash_ok = stash_code == 0 and !std.mem.eql(u8, stash_before, stash_after);

        const prompt = buildPrompt(alloc, e.*, ".") catch {
            e.state = "failed";
            e.note = "prompt build failed";
            continue;
        };
        std.debug.print("\n=== evolve {s} [{s}] ({s}) ===\n", .{ e.id, e.kind, e.where });
        if (dry) {
            std.debug.print("[dry-run] task prompt:\n{s}\n", .{prompt});
            e.state = "open";
            e.attempts -= 1;
            continue;
        }

        // 跑内置 agent(在当前目录=仓库根)
        _ = runAgentTask(alloc, prompt) catch |err| {
            e.state = "failed";
            e.note = std.fmt.allocPrint(alloc, "agent error: {s}", .{@errorName(err)}) catch "agent error";
            fail_n += 1;
            popStash(alloc, ".", e, stash_ok);
            continue;
        };

        // 后验:有 evolve: 提交?否则还原。
        const last_subj = gitOut(alloc, ".", &.{ "log", "-1", "--format=%s" }) orelse "";
        const last_hash = gitOut(alloc, ".", &.{ "log", "-1", "--format=%H" }) orelse "";
        const has_evolve = std.mem.startsWith(u8, last_subj, "evolve:");
        const dirty = gitOut(alloc, ".", &.{ "status", "--porcelain" }) orelse "";
        if (has_evolve) {
            e.state = "done";
            e.commit = last_hash;
            e.note = "committed";
            done_n += 1;
        } else {
            // 无 evolve 提交:若工作区脏,清理(agent 半途而废)
            if (dirty.len > 0) gitRun(".", &.{ "checkout", "--", "." }) catch {};
            e.state = "failed";
            e.note = "no evolve commit; changes reverted";
            fail_n += 1;
        }
        popStash(alloc, ".", e, stash_ok);
    }

    // 回写(含 exhausted/状态变更)
    rewriteQueue(qp, alloc, entries.items) catch |e| {
        std.debug.print("piz evolve: rewrite failed: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    std.debug.print("\nevolve done: {d} ok, {d} failed, {d} exhausted\n", .{ done_n, fail_n, skipped_n });
    pluginsmod.shutdownAgents();
    std.process.exit(0);
}

/// 内置 agent 无交互跑一条修复任务。仿 runPrint 精简:独立新会话、
/// execute 全权、turn_cap 封顶;输出不进 stdout(安静任务)。
fn runAgentTask(alloc: std.mem.Allocator, prompt: []const u8) !void {
    const abs_cwd = std.process.currentPathAlloc(util.io, alloc) catch ".";
    var cfg_arena = util.Arena.init(alloc);
    var cfg = cfgmod.Config{ .arena = &cfg_arena };
    defer cfg.deinit();
    try cfg.load();
    cfg.warnBroken();

    // 专用会话「evolve.jsonl」:跨任务续载,已探索过的文件/结论不重查(turn 帽内更划算)。
    // Session 结构可直接构造(alloc/path/cwd),绕过 findById 的时间戳命名。
    const cfg_dir = try util.configDir(alloc);
    defer alloc.free(cfg_dir);
    const sess_dir = try util.joinPath(alloc, cfg_dir, "sessions");
    defer alloc.free(sess_dir);
    const slug = try util.cwdSlug(alloc, abs_cwd);
    defer alloc.free(slug);
    const sub = try util.joinPath(alloc, sess_dir, slug);
    defer alloc.free(sub);
    std.Io.Dir.cwd().createDirPath(util.io, sub) catch {};
    const spath = try util.joinPath(alloc, sub, "evolve.jsonl");
    var sess = sessionmod.Session{
        .alloc = alloc,
        .path = spath,
        .cwd = try alloc.dupe(u8, abs_cwd),
    };
    var agent = try agentmod.Agent.initOpts(alloc, &cfg, null, null, abs_cwd, .{
        .read_only = false,
        .depth = pluginsmod.processBaseDepth(),
    });
    agent.turn_cap = TURN_CAP;
    if (agent.key == null) return error.NoApiKey;
    const loaded = try sess.loadMessages();
    try agent.messages.appendSlice(loaded);
    const result = try agent.send(prompt);
    for (agent.messages.items[0..]) |*m| try sess.saveMessage(m);
    if (result.error_msg) |msg| {
        std.debug.print("evolve agent error: {s}\n", .{msg});
        return error.AgentFailed;
    }
}

/// 构造缺陷任务 prompt(dry-run 展示同款)。
fn buildPrompt(alloc: std.mem.Allocator, e: Entry, repo: []const u8) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(alloc);
    defer w.deinit();
    const wr = &w.writer;
    try wr.print(
        \\你是 piz 仓库(路径 {s})的自演化修复任务。前端捕获到一个运行时缺陷,请先定位根因再修复,不要猜测。
        \\
        \\【缺陷报告】
        \\id: {s}
        \\类型: {s}
        \\位置: {s}
        \\错误信息: {s}
        \\
        \\【硬性要求】
        \\1. 先读相关源码定位根因(read 工具;行号前缀勿粘进 edit)
        \\2. 用 edit/write 工具修改源码,禁止用 shell 重定向写文件
        \\3. 验证:仓库根执行 zig build 与 zig build test,报错必须修到绿
        \\4. 全绿后 git add -A && git commit -m "evolve: {s} <一句话概括>"
        \\5. 验证不过:git checkout -- . 还原全部改动,并文字报告失败原因
        \\6. 只改与缺陷直接相关的文件,不顺手重构无关代码
        \\
        \\完成后一段话总结:根因、改动文件、验证结果。
        \\
    , .{ repo, e.id, e.kind, e.where, e.msg, e.id });
    if (e.stack.len > 0) try wr.print("堆栈(截断):\n{s}\n\n", .{e.stack[0..@min(e.stack.len, 1200)]});
    if (e.where.len > 0 and !std.mem.eql(u8, e.where, "window") and !std.mem.eql(u8, e.where, "promise") and !std.mem.eql(u8, e.where, "console.error")) {
        try wr.print("【线索】缺陷位置已定位:{s}。先直接读该文件/该处,勿全局搜索;其余排查时间留给验证。\n\n", .{e.where});
    }
    return w.toOwnedSlice();
}

/// 回写队列:逐行保留,仅替换已解析条目(按 id 匹配)。
fn rewriteQueue(qp: []const u8, alloc: std.mem.Allocator, entries: []Entry) !void {
    const data = util.readFile(alloc, qp) catch return;
    var w = std.Io.Writer.Allocating.init(alloc);
    defer w.deinit();
    const wr = &w.writer;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var matched = false;
        const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{}) catch {
            wr.writeAll(line) catch {};
            wr.writeByte('\n') catch {};
            continue;
        };
        if (v == .object) {
            const id = jsonStr(v, "id") orelse "";
            for (entries) |*e| {
                if (std.mem.eql(u8, e.id, id)) {
                    wr.writeAll(entryLine(alloc, e.*) catch line) catch {};
                    wr.writeByte('\n') catch {};
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) {
            wr.writeAll(line) catch {};
            wr.writeByte('\n') catch {};
        }
    }
    try util.writeFile(qp, w.toOwnedSlice() catch data);
}

fn entryLine(alloc: std.mem.Allocator, e: Entry) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(alloc);
    defer w.deinit();
    const wr = &w.writer;
    try wr.writeAll("{\"id\":");
    try wr.print("{s}", .{try util.jsonString(alloc, e.id)});
    try wr.print(",\"ts\":{d}", .{e.ts});
    try wr.print(",\"kind\":{s}", .{try util.jsonString(alloc, e.kind)});
    try wr.print(",\"where\":{s}", .{try util.jsonString(alloc, e.where)});
    try wr.print(",\"msg\":{s}", .{try util.jsonString(alloc, e.msg)});
    try wr.print(",\"stack\":{s}", .{try util.jsonString(alloc, e.stack)});
    try wr.print(",\"session\":{s}", .{try util.jsonString(alloc, e.session)});
    try wr.print(",\"state\":{s}", .{try util.jsonString(alloc, e.state)});
    try wr.print(",\"attempts\":{d}", .{e.attempts});
    try wr.print(",\"note\":{s}", .{try util.jsonString(alloc, e.note)});
    try wr.print(",\"commit\":{s}}}", .{try util.jsonString(alloc, e.commit)});
    return w.toOwnedSlice();
}

fn jsonStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}
fn jsonInt(v: std.json.Value, key: []const u8, fallback: usize) usize {
    const f = if (v == .object) v.object.get(key) orelse return fallback else return fallback;
    return switch (f) {
        .integer => |n| if (n < 0) fallback else @intCast(n),
        else => fallback,
    };
}

/// 任务后恢复 stash;冲突则保留并记 note。
fn popStash(alloc: std.mem.Allocator, repo: []const u8, e: *Entry, stash_ok: bool) void {
    if (!stash_ok) return;
    if (gitCode(repo, &.{ "stash", "pop" }) != 0) {
        // pop 失败:冲突或 stash 已不在了。保留(不 drop)并提示。
        e.note = if (e.note.len > 0)
            std.fmt.allocPrint(alloc, "{s}; stash kept: evolve-{s}", .{ e.note, e.id }) catch e.note
        else
            std.fmt.allocPrint(alloc, "stash kept: evolve-{s}", .{e.id}) catch e.note;
    }
}

// ---- git 助手(poll+read,输出小;stderr 忽略) ----

/// 跑 git 并返回 stdout(先读尽再 wait,防管道堵)。
fn gitOut(alloc: std.mem.Allocator, repo: []const u8, args: []const []const u8) ?[]u8 {
    const argv = alloc.alloc([]const u8, args.len + 3) catch return null;
    argv[0] = "git";
    argv[1] = "-C";
    argv[2] = repo;
    @memcpy(argv[3..], args);
    var child = std.process.spawn(util.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    if (child.stdout) |f| {
        var tmp: [4096]u8 = undefined;
        // poll 100ms + read 已到字节(与 mcp.readLine 同策,防阻塞)
        while (true) {
            var pfds = [_]std.posix.pollfd{.{ .fd = f.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const rc = std.posix.poll(&pfds, 100) catch break;
            if (rc == 0) continue;
            const n = std.posix.read(f.handle, &tmp) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => break,
            };
            if (n == 0) break;
            out.appendSlice(tmp[0..n]) catch break;
        }
    }
    _ = child.wait(util.io) catch {};
    if (child.stdout) |f| f.close(util.io);
    return if (out.items.len > 0) out.toOwnedSlice() catch null else null;
}

/// 跑 git 并返回退出码(0 = 成功;0xffffffff = spawn 失败)。
fn gitCode(repo: []const u8, args: []const []const u8) u32 {
    const argv = std.heap.page_allocator.alloc([]const u8, args.len + 3) catch return 0xffffffff;
    argv[0] = "git";
    argv[1] = "-C";
    argv[2] = repo;
    @memcpy(argv[3..], args);
    var child = std.process.spawn(util.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return 0xffffffff;
    const term = child.wait(util.io) catch return 0xffffffff;
    return switch (term) {
        .exited => |code| code,
        else => 0xffffffff,
    };
}

/// 跑 git 忽略输出(还原/提交这种动作)。
fn gitRun(repo: []const u8, args: []const []const u8) !void {
    const argv = try std.heap.page_allocator.alloc([]const u8, args.len + 3);
    argv[0] = "git";
    argv[1] = "-C";
    argv[2] = repo;
    @memcpy(argv[3..], args);
    var child = try std.process.spawn(util.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(util.io);
    if (term != .exited) return error.GitFailed;
    if (term.exited != 0) return error.GitFailed;
}
