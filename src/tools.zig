// tools.zig — pi 核心四工具:read / write / edit / bash。
const std = @import("std");
const util = @import("util.zig");
const activity = @import("activity.zig");

pub const MAX_TOOL_OUTPUT = 16 * 1024;

pub const Result = struct {
    content: []const u8, // 给模型看的内容(arena 所有)
    is_error: bool = false,
};

fn jstr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const val = v.object.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

/// 取整数字段:接受 JSON integer,以及模型常误发的 float/字符串数字。
fn jint(v: std.json.Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const val = v.object.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// 取布尔字段:接受 JSON bool,以及模型常误发的 "true"/"false" 字符串。
fn jbool(v: std.json.Value, key: []const u8) ?bool {
    if (v != .object) return null;
    const val = v.object.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        .string => |s| if (std.mem.eql(u8, s, "true")) true else if (std.mem.eql(u8, s, "false")) false else null,
        else => null,
    };
}

fn parseArgs(arena: std.mem.Allocator, args: []const u8) !std.json.Value {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{}) catch return error.BadArgs;
    return root;
}

/// read: {path, offset?, limit?} → 文件内容(offset/limit 给定时返回 1-based 行区间)
fn toolRead(arena: std.mem.Allocator, args: []const u8) !Result {
    const v = try parseArgs(arena, args);
    const path = jstr(v, "path") orelse return .{ .content = "error: missing 'path' argument", .is_error = true };
    const content = std.Io.Dir.cwd().readFileAlloc(util.io, path, arena, .limited(16 * 1024 * 1024)) catch |err| {
        return .{ .content = try std.fmt.allocPrint(arena, "error reading {s}: {s}", .{ path, @errorName(err) }), .is_error = true };
    };
    const offset = jint(v, "offset");
    const limit = jint(v, "limit");
    // 行区间切片:offset 1-based(缺省 1),limit 缺省到文件尾
    if (offset != null or limit != null) {
        const start_line: usize = if (offset) |o| (if (o < 1) 1 else @intCast(o)) else 1;
        const max_lines: ?usize = if (limit) |l| (if (l < 1) 0 else @as(usize, @intCast(l))) else null;
        var it = std.mem.splitScalar(u8, content, '\n');
        var aw = std.Io.Writer.Allocating.init(arena);
        defer aw.deinit();
        var line_no: usize = 0;
        var emitted: usize = 0;
        var found = false;
        while (it.next()) |line| {
            line_no += 1;
            if (line_no < start_line) continue;
            if (max_lines) |m| {
                if (emitted >= m) break;
            }
            found = true;
            if (emitted > 0) try aw.writer.writeByte('\n');
            try aw.writer.writeAll(line);
            emitted += 1;
        }
        if (!found) return .{
            .content = try std.fmt.allocPrint(arena, "error: offset {d} is past end of {s} ({d} lines)", .{ start_line, path, line_no }),
            .is_error = true,
        };
        return capped(arena, aw.written(), path, content.len);
    }
    return capped(arena, content, path, content.len);
}

/// 工具输出上限裁剪(保头部,信息量最高)。插件工具亦复用。
pub fn capped(arena: std.mem.Allocator, body: []const u8, path: []const u8, total: usize) !Result {
    if (body.len <= MAX_TOOL_OUTPUT) return .{ .content = try arena.dupe(u8, body) };
    return .{ .content = try std.fmt.allocPrint(arena, "{s}\n...[{s} truncated at {d} bytes, total {d}]...", .{
        body[0..MAX_TOOL_OUTPUT],
        path,
        MAX_TOOL_OUTPUT,
        total,
    }) };
}

/// write: {path, content} → 写文件
fn toolWrite(arena: std.mem.Allocator, args: []const u8) !Result {
    const v = try parseArgs(arena, args);
    const path = jstr(v, "path") orelse return .{ .content = "error: missing 'path' argument", .is_error = true };
    const content = jstr(v, "content") orelse "";
    if (std.fs.path.dirname(path)) |d| {
        if (d.len > 0) std.Io.Dir.cwd().createDirPath(util.io, d) catch {};
    }
    std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = path, .data = content }) catch |err| {
        return .{ .content = try std.fmt.allocPrint(arena, "error writing {s}: {s}", .{ path, @errorName(err) }), .is_error = true };
    };
    // 输出带 diff 块(+ 行,限 40 行;web diff 卡渲染用)
    var diff = std.array_list.Managed(u8).init(arena);
    const head = try std.fmt.allocPrint(arena, "wrote {d} bytes to {s}\n--- {s}\n+++ {s}\n", .{ content.len, path, path, path });
    try diff.appendSlice(head);
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |ln| : (n += 1) {
        if (n >= 40) {
            try diff.appendSlice("... (truncated)\n");
            break;
        }
        try diff.appendSlice("+");
        try diff.appendSlice(ln);
        try diff.appendSlice("\n");
    }
    return .{ .content = try diff.toOwnedSlice() };
}

/// edit: {path, edits: [{oldText, newText}]} → 精确替换,0/多匹配即报错
fn toolEdit(arena: std.mem.Allocator, args: []const u8) !Result {
    const v = try parseArgs(arena, args);
    const path = jstr(v, "path") orelse return .{ .content = "error: missing 'path' argument", .is_error = true };
    const edits = v.object.get("edits") orelse return .{ .content = "error: missing 'edits' array", .is_error = true };
    if (edits != .array or edits.array.items.len == 0) {
        return .{ .content = "error: 'edits' must be a non-empty array", .is_error = true };
    }
    const orig = std.Io.Dir.cwd().readFileAlloc(util.io, path, arena, .limited(64 * 1024 * 1024)) catch |err| {
        return .{ .content = try std.fmt.allocPrint(arena, "error reading {s}: {s}", .{ path, @errorName(err) }), .is_error = true };
    };
    var buf = std.array_list.Managed(u8).init(arena);
    try buf.appendSlice(orig);
    for (edits.array.items, 0..) |e, i| {
        if (e != .object) return .{ .content = "error: edit entry must be an object", .is_error = true };
        const old_text = jstr(e, "oldText") orelse return .{ .content = "error: edit missing oldText", .is_error = true };
        const new_text = jstr(e, "newText") orelse "";
        // 统计匹配次数
        var count: usize = 0;
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, buf.items, idx, old_text)) |found| {
            count += 1;
            idx = found + old_text.len;
        }
        if (count == 0) {
            return .{ .content = try std.fmt.allocPrint(arena, "error: edit {d}: oldText not found in {s}", .{ i + 1, path }), .is_error = true };
        }
        if (count > 1) {
            return .{ .content = try std.fmt.allocPrint(arena, "error: edit {d}: oldText matches {d} times in {s}, must be unique", .{ i + 1, count, path }), .is_error = true };
        }
        const pos = std.mem.indexOf(u8, buf.items, old_text).?;
        // 替换:原地挪动
        if (new_text.len == old_text.len) {
            @memcpy(buf.items[pos .. pos + new_text.len], new_text);
        } else if (new_text.len > old_text.len) {
            try buf.resize(buf.items.len + (new_text.len - old_text.len));
            std.mem.copyBackwards(u8, buf.items[pos + new_text.len ..], buf.items[pos + old_text.len .. buf.items.len - (new_text.len - old_text.len)]);
            @memcpy(buf.items[pos .. pos + new_text.len], new_text);
        } else {
            std.mem.copyForwards(u8, buf.items[pos + new_text.len ..], buf.items[pos + old_text.len ..]);
            try buf.resize(buf.items.len - (old_text.len - new_text.len));
            @memcpy(buf.items[pos .. pos + new_text.len], new_text);
        }
    }
    std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = path, .data = buf.items }) catch |err| {
        return .{ .content = try std.fmt.allocPrint(arena, "error writing {s}: {s}", .{ path, @errorName(err) }), .is_error = true };
    };
    // 输出带 diff 块(-old/+new 行,限 40 行;web diff 卡渲染用)
    var diff = std.array_list.Managed(u8).init(arena);
    const head = try std.fmt.allocPrint(arena, "edited {s}: {d} replacements\n--- {s}\n+++ {s}\n", .{ path, edits.array.items.len, path, path });
    try diff.appendSlice(head);
    var n: usize = 0;
    for (edits.array.items) |e| {
        const old_text = jstr(e, "oldText") orelse "";
        const new_text = jstr(e, "newText") orelse "";
        var ol = std.mem.splitScalar(u8, old_text, '\n');
        while (ol.next()) |ln| : (n += 1) {
            if (n >= 40) break;
            try diff.appendSlice("-");
            try diff.appendSlice(ln);
            try diff.appendSlice("\n");
        }
        var nl = std.mem.splitScalar(u8, new_text, '\n');
        while (nl.next()) |ln| : (n += 1) {
            if (n >= 40) break;
            try diff.appendSlice("+");
            try diff.appendSlice(ln);
            try diff.appendSlice("\n");
        }
        if (n >= 40) {
            try diff.appendSlice("... (truncated)\n");
            break;
        }
    }
    return .{ .content = try diff.toOwnedSlice() };
}

fn setNonBlock(fd: std.posix.fd_t) void {
    util.setNonBlock(fd);
}

/// 双管道抽水状态。`err_buf` 为 null 时 stderr 混入 `buf` 并加 `[stderr]` 前缀
/// (bash 工具:用户要看到交错的输出);非 null 时分流
/// (task 工具:stdout 是子 agent 的答复,stderr 是诊断,混一起没法区分)。
pub const PipeState = struct {
    buf: *std.array_list.Managed(u8),
    err_buf: ?*std.array_list.Managed(u8) = null,
    out_fd: std.posix.fd_t,
    err_fd: std.posix.fd_t,
    out_eof: bool = false,
    err_eof: bool = false,
    /// 缓冲保留的字节上限(只留尾部)。0 = 不限。
    ///
    /// 两个消费者最后都只取尾部(bash 见 toolBash 的截断、task 见 runTaskSlot),
    /// 但原先是全量收完再截:一个吐 500MB 的子进程让父进程驻留 473MB(实测),
    /// 最后只用 16KB。N 个并行 subagent 就是 N 倍。
    keep_bytes: usize = 0,
    /// 实际流过的总字节数(含已丢弃的)。截断提示要报真实总量。
    total_out: usize = 0,
    total_err: usize = 0,
};

/// 追加并把 list 压回 `keep` 字节以内(丢头留尾)。
fn appendCapped(list: *std.array_list.Managed(u8), data: []const u8, keep: usize) !void {
    try list.appendSlice(data);
    if (keep == 0 or list.items.len <= keep) return;
    // 留出余量再裁,避免每个 chunk 都触发一次 memmove:超过 2 倍才压回。
    if (list.items.len < keep * 2) return;
    const drop = list.items.len - keep;
    std.mem.copyForwards(u8, list.items[0..keep], list.items[drop..]);
    list.shrinkRetainingCapacity(keep);
}

fn drainPipe(state: *PipeState, fd: std.posix.fd_t, is_err: bool) !void {
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &chunk) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (n == 0) {
            if (is_err) {
                state.err_eof = true;
            } else {
                state.out_eof = true;
            }
            break;
        }
        if (is_err) {
            state.total_err += n;
            if (state.err_buf) |eb| {
                try appendCapped(eb, chunk[0..n], state.keep_bytes);
                continue;
            }
            try appendCapped(state.buf, "\x1b[2m[stderr]\x1b[0m ", state.keep_bytes);
        } else {
            state.total_out += n;
        }
        try appendCapped(state.buf, chunk[0..n], state.keep_bytes);
        if (is_err) try appendCapped(state.buf, "\n", state.keep_bytes);
    }
}

/// 抽干子进程的两个管道直到双 EOF 或超时。返回是否超时。
/// 调用方负责 spawn、close、wait/kill —— 这里只管搬字节。
///
/// 用 poll 而非阻塞读:一个管道满/空不能拖住另一个,否则子进程写 stderr
/// 写满管道缓冲后就阻塞,而我们还在等 stdout,双方僵死。
///
/// `act` 是活动登记句柄:每 100ms 的 poll 唤醒都上报已搬字节数并检查取消。
/// 这是「用户看得到在干活」和「Ctrl+C 能打断长命令」两件事的落点 ——
/// 没有它,一条 300 秒的命令期间界面是完全静止的,Ctrl+C 也要等到迭代边界才生效。
/// 返回值区分不出超时与取消,调用方用 `act.cancelled()` 判断。
pub fn pumpPipes(state: *PipeState, timeout_ms: i64, act: activity.Handle) !bool {
    const fds = [_]std.posix.pollfd{
        .{ .fd = state.out_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = state.err_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const start = std.Io.Clock.now(.awake, util.io).nanoseconds;
    while (true) {
        if (state.out_eof and state.err_eof) return false;
        // 取消优先于超时:用户按了 Ctrl+C 就不该再等命令自己结束。
        // 已转后台的活动不受取消影响 —— 那正是「转后台」的意思。
        if (act.cancelled() and !act.isDetached()) return true;
        act.progress(state.buf.items.len);
        var pfds = fds;
        const n = std.posix.poll(&pfds, 100) catch |err| switch (err) {
            error.SystemResources => {
                // 极少数平台 poll 不可用:退化为轮询
                try drainPipe(state, state.out_fd, false);
                try drainPipe(state, state.err_fd, true);
                if (state.out_eof and state.err_eof) return false;
                _ = std.Io.sleep(util.io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
                continue;
            },
            else => return err,
        };
        if (n == 0) {
            // 转后台的命令不再受墙钟上限约束:用户已经明确表示要让它跑完。
            if (act.isDetached()) continue;
            if (std.Io.Clock.now(.awake, util.io).nanoseconds - start > timeout_ms * std.time.ns_per_ms) return true;
            continue;
        }
        for (&pfds) |*p| {
            if (p.revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) == 0) continue;
            if (p.fd == state.out_fd) {
                try drainPipe(state, state.out_fd, false);
            } else if (p.fd == state.err_fd) {
                try drainPipe(state, state.err_fd, true);
            }
        }
    }
}

/// 杀掉以 `pid` 为组长的整个进程组。
///
/// 必要而非优化:`sh -c "make -j8"` 里真正吃 CPU 的是 make 派生的编译进程。
/// 只 kill 直接子进程(sh)的话,那些孙子进程会被 init 收养后继续跑到底 ——
/// 用户以为命令停了,机器却还在满载。先 TERM 给收拾的机会,再 KILL 兜底。
pub fn killGroup(pid: std.posix.pid_t) void {
    std.posix.kill(-pid, std.posix.SIG.TERM) catch {};
    // 给 100ms 优雅退出(刷 stdout、删临时文件),然后强杀
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
    std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
}

/// bash: {command, timeout?} → 执行 sh -c,合并输出,超时或取消时杀掉整个进程组。
///
/// 登记进 activity 表:执行期间 TUI 能显示 spinner、耗时与已收字节,
/// Ctrl+C 也能在 100ms 内打断 —— 原先这两件事在命令跑完前都做不到。
fn toolBash(arena: std.mem.Allocator, args: []const u8) !Result {
    const v = try parseArgs(arena, args);
    const command = jstr(v, "command") orelse return .{ .content = "error: missing 'command' argument", .is_error = true };
    var timeout_ms: i64 = 30_000;
    if (v.object.get("timeout")) |t| {
        if (t == .integer) {
            timeout_ms = @intCast(t.integer * 1000);
        } else if (t == .float) {
            timeout_ms = @intFromFloat(t.float * 1000);
        }
    }
    timeout_ms = @max(@min(timeout_ms, 300_000), 1_000);

    // pgid=0:子进程成为新进程组的组长。这样超时/取消时能 kill(-pgid) 收掉
    // 整棵进程树 —— `sh -c "make -j8"` 派生的孙子进程原先会孤儿化,
    // 继续吃 CPU 且没人回收。
    var child = try std.process.spawn(util.io, .{
        .argv = &.{ "sh", "-c", command },
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    const child_pid = child.id;
    const out_fd = child.stdout.?.handle;
    const err_fd = child.stderr.?.handle;
    // 非阻塞
    setNonBlock(out_fd);
    setNonBlock(err_fd);

    const act = activity.begin(.tool, "bash", command, timeout_ms);
    defer act.release();

    var buf = std.array_list.Managed(u8).init(arena);
    // err_buf 省略:bash 把 stderr 交错进同一个 buffer,用户要看到执行顺序
    // keep_bytes:边读边丢头部,只留最后 MAX_TOOL_OUTPUT。留全量再截的话,
    // 一条 `find /` 就让 piz 驻留几百 MB 去换 16KB 的结果。
    var state = PipeState{ .buf = &buf, .out_fd = out_fd, .err_fd = err_fd, .keep_bytes = MAX_TOOL_OUTPUT };
    defer {
        if (child.stdout) |f| f.close(util.io);
        if (child.stderr) |f| f.close(util.io);
    }

    const stopped = try pumpPipes(&state, timeout_ms, act);
    const cancelled = stopped and act.cancelled();

    var term: std.process.Child.Term = undefined;
    if (stopped) {
        // 先给整个进程组发信号收掉孙子进程,再 child.kill 收直接子进程。
        if (child_pid) |pid| killGroup(pid);
        // `Child.kill` 自己会 block 到终止并清理资源,之后 `child.id` 为 null ——
        // 再调 `wait` 会撞 assert。所以这里直接构造 term(128+SIGKILL)。
        child.kill(util.io);
        term = .{ .exited = 137 };
        if (cancelled) {
            var eb: [24]u8 = undefined;
            try buf.appendSlice(try std.fmt.allocPrint(arena, "\n[interrupted by user after {s}; process group killed. Partial output above is what ran.]", .{activity.formatElapsed(&eb, act.elapsedMs())}));
        } else {
            try buf.appendSlice(try std.fmt.allocPrint(arena, "\n[tool timed out after {d}s, process group killed. Partial output above is what ran — rerun with a larger `timeout` if it needs longer.]", .{@divTrunc(timeout_ms, 1000)}));
        }
    } else {
        term = child.wait(util.io) catch blk: {
            break :blk .{ .exited = 1 };
        };
    }

    // 截断。总量取 state 累计的真实字节数 —— buf 已经被 drain 阶段裁过,
    // 用它的长度会把「输出了 500MB」报成「输出了 32KB」。
    const streamed = state.total_out + state.total_err;
    var content: []u8 = undefined;
    if (buf.items.len > MAX_TOOL_OUTPUT) {
        content = try std.fmt.allocPrint(arena, "{s}\n...[output truncated at {d} bytes, total {d}]...", .{
            buf.items[buf.items.len - MAX_TOOL_OUTPUT ..],
            MAX_TOOL_OUTPUT,
            streamed,
        });
    } else {
        content = try arena.dupe(u8, buf.items);
    }

    const code: u8 = switch (term) {
        .exited => |c| c,
        .signal => |s| @intCast(128 + @intFromEnum(s)),
        else => 1,
    };
    const exit_note = if (code == 0)
        try std.fmt.allocPrint(arena, "\n[exit code 0]", .{})
    else
        try std.fmt.allocPrint(arena, "\n[exit code {d}]", .{code});
    const full = try std.fmt.allocPrint(arena, "{s}{s}", .{ content, exit_note });
    return .{ .content = full, .is_error = code != 0 };
}

/// skill: {name} → 读取 <configDir>/skills/<name>/SKILL.md 内容。
/// 由 skills 插件注册(仅装了技能时才需要),故导出。
pub fn toolSkill(arena: std.mem.Allocator, args: []const u8) !Result {
    const v = try parseArgs(arena, args);
    const name = jstr(v, "name") orelse return .{ .content = "error: missing 'name' argument", .is_error = true };
    // 防目录穿越:只允许字母数字-_
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) {
            return .{ .content = "error: invalid skill name", .is_error = true };
        }
    }
    const cfg_dir = util.configDir(arena) catch return .{ .content = "error: no config dir", .is_error = true };
    const path = try std.fmt.allocPrint(arena, "{s}/skills/{s}/SKILL.md", .{ cfg_dir, name });
    const content = std.Io.Dir.cwd().readFileAlloc(util.io, path, arena, .limited(256 * 1024)) catch |err| {
        return .{ .content = try std.fmt.allocPrint(arena, "error reading skill '{s}': {s}", .{ name, @errorName(err) }), .is_error = true };
    };
    return .{ .content = try std.fmt.allocPrint(arena, "# Skill {s}\n\n{s}", .{ name, content }) };
}

pub const Tool = struct {
    name: []const u8,
    desc: []const u8,
    /// 参数 JSON Schema(编译期字面量;发给 provider 作 input_schema/parameters)。
    /// 空串 = 无参数工具,序列化时退化为 {"type":"object","properties":{}}。
    schema: []const u8 = "",
    handler: *const fn (arena: std.mem.Allocator, args: []const u8) anyerror!Result,
    /// 插件工具:带宿主上下文(Agent 指针)的处理器。
    ctx_handler: ?*const fn (ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!Result = null,
};

/// 无参数工具的空 schema。
pub const EMPTY_SCHEMA = "{\"type\":\"object\",\"properties\":{}}";

// =====================================================================
// 搜索基础设施:glob 匹配 + 最小正则引擎 + 目录遍历(零外部依赖,不 spawn rg/fd)
// =====================================================================

/// 搜索时始终跳过的目录(构建产物与 VCS 元数据,搜它们只会污染结果)。
const SKIP_DIRS = [_][]const u8{
    ".git",   "zig-out",     ".zig-cache",    "node_modules", "target",
    "dist",   "__pycache__", ".venv",         "venv",         ".next",
    "vendor", ".mypy_cache", ".pytest_cache",
};

fn isSkippedDir(name: []const u8) bool {
    for (SKIP_DIRS) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

/// glob 匹配(支持 `*` `?` `**`)。`*` 不跨 `/`,`**` 跨任意层级。
/// 递归实现,pattern 与 name 都短,无回溯爆炸风险。
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    // `**/` 前缀:匹配任意层级(含零层)
    if (std.mem.startsWith(u8, pattern, "**/")) {
        const rest = pattern[3..];
        if (globMatch(rest, name)) return true;
        var i: usize = 0;
        while (i < name.len) : (i += 1) {
            if (name[i] == '/' and globMatch(rest, name[i + 1 ..])) return true;
        }
        return false;
    }
    if (pattern.len == 0) return name.len == 0;
    switch (pattern[0]) {
        '*' => {
            // `**` 不带斜杠:退化为跨层级通配
            const cross = pattern.len > 1 and pattern[1] == '*';
            const rest = if (cross) pattern[2..] else pattern[1..];
            if (globMatch(rest, name)) return true;
            var i: usize = 0;
            while (i < name.len) : (i += 1) {
                if (!cross and name[i] == '/') break; // 单星不跨目录分隔
                if (globMatch(rest, name[i + 1 ..])) return true;
            }
            return false;
        },
        '?' => {
            if (name.len == 0 or name[0] == '/') return false;
            return globMatch(pattern[1..], name[1..]);
        },
        else => {
            if (name.len == 0 or name[0] != pattern[0]) return false;
            return globMatch(pattern[1..], name[1..]);
        },
    }
}

/// 最小正则引擎。支持:字符类 `[abc]` `[a-z]` `[^x]`、`.`、`*` `+` `?`、
/// 锚 `^` `$`、转义 `\.` `\d` `\w` `\s`(及大写取反)。
/// 不支持:分组、选择 `|`、回溯引用、懒惰量词 —— 这些留给模型用 bash 调 rg。
/// 设计取舍:单遍回溯匹配,单行长度设上限防指数爆炸。
const Regex = struct {
    pattern: []const u8,
    ignore_case: bool,

    /// 单行长度上限:超长行(压缩产物、base64)跳过,防病态回溯。
    const MAX_LINE = 4096;

    fn init(pattern: []const u8, ignore_case: bool) !Regex {
        // 预校验:字符类必须闭合,转义不能悬空
        var i: usize = 0;
        while (i < pattern.len) : (i += 1) {
            switch (pattern[i]) {
                '\\' => {
                    if (i + 1 >= pattern.len) return error.TrailingBackslash;
                    i += 1;
                },
                '[' => {
                    const close = findClassEnd(pattern, i) orelse return error.UnclosedCharClass;
                    i = close;
                },
                else => {},
            }
        }
        return .{ .pattern = pattern, .ignore_case = ignore_case };
    }

    /// 找字符类结束的 `]` 下标。首字符 `]` 视为字面量(POSIX 惯例)。
    fn findClassEnd(p: []const u8, open: usize) ?usize {
        var i = open + 1;
        if (i < p.len and p[i] == '^') i += 1;
        if (i < p.len and p[i] == ']') i += 1; // 首个 ] 是字面量
        while (i < p.len) : (i += 1) {
            if (p[i] == '\\') {
                i += 1;
                continue;
            }
            if (p[i] == ']') return i;
        }
        return null;
    }

    fn fold(self: Regex, c: u8) u8 {
        return if (self.ignore_case) std.ascii.toLower(c) else c;
    }

    /// 转义类匹配:\d \w \s 及大写取反。
    fn matchEscape(esc: u8, c: u8) bool {
        return switch (esc) {
            'd' => std.ascii.isDigit(c),
            'D' => !std.ascii.isDigit(c),
            'w' => std.ascii.isAlphanumeric(c) or c == '_',
            'W' => !(std.ascii.isAlphanumeric(c) or c == '_'),
            's' => std.ascii.isWhitespace(c),
            'S' => !std.ascii.isWhitespace(c),
            'n' => c == '\n',
            't' => c == '\t',
            'r' => c == '\r',
            else => esc == c, // \. \* \[ 等:字面量
        };
    }

    /// 字符类匹配。返回是否命中。
    fn matchClass(self: Regex, p: []const u8, open: usize, close: usize, c: u8) bool {
        var i = open + 1;
        var negate = false;
        if (i < close and p[i] == '^') {
            negate = true;
            i += 1;
        }
        const cf = self.fold(c);
        var hit = false;
        while (i < close) : (i += 1) {
            if (p[i] == '\\' and i + 1 < close) {
                if (matchEscape(p[i + 1], c)) hit = true;
                i += 1;
                continue;
            }
            // 区间 a-z(`-` 在末尾时是字面量)
            if (i + 2 < close and p[i + 1] == '-') {
                const lo = self.fold(p[i]);
                const hi = self.fold(p[i + 2]);
                if (cf >= lo and cf <= hi) hit = true;
                i += 2;
                continue;
            }
            if (self.fold(p[i]) == cf) hit = true;
        }
        return hit != negate;
    }

    /// 单元素长度(用于量词跳过):转义 2、字符类到 `]`、其余 1。
    fn atomLen(self: Regex, p: []const u8, i: usize) usize {
        _ = self;
        if (p[i] == '\\') return 2;
        if (p[i] == '[') {
            if (findClassEnd(p, i)) |close| return close - i + 1;
        }
        return 1;
    }

    /// 单元素与单字符是否匹配。
    fn atomMatches(self: Regex, p: []const u8, i: usize, c: u8) bool {
        if (p[i] == '\\') return matchEscape(p[i + 1], c);
        if (p[i] == '[') {
            if (findClassEnd(p, i)) |close| return self.matchClass(p, i, close, c);
            return false;
        }
        if (p[i] == '.') return c != '\n';
        return self.fold(p[i]) == self.fold(c);
    }

    /// 从 text 任意位置起找匹配。返回是否命中。
    fn search(self: Regex, text: []const u8) bool {
        if (text.len > MAX_LINE) return false; // 超长行跳过
        if (self.pattern.len > 0 and self.pattern[0] == '^') {
            return self.matchHere(self.pattern[1..], text, 0);
        }
        var start: usize = 0;
        while (start <= text.len) : (start += 1) {
            if (self.matchHere(self.pattern, text, start)) return true;
        }
        return false;
    }

    /// 从 text[pos] 起匹配 p。回溯实现。
    fn matchHere(self: Regex, p: []const u8, text: []const u8, pos: usize) bool {
        if (p.len == 0) return true;
        if (p.len == 1 and p[0] == '$') return pos == text.len;
        const alen = self.atomLen(p, 0);
        // 量词:紧跟单元素之后
        if (p.len > alen) {
            const q = p[alen];
            if (q == '*' or q == '+' or q == '?') {
                const rest = p[alen + 1 ..];
                const min: usize = if (q == '+') 1 else 0;
                const max: usize = if (q == '?') 1 else text.len - pos;
                // 贪婪:先吃最多,再逐步回退
                var n: usize = 0;
                while (n < max and pos + n < text.len and self.atomMatches(p, 0, text[pos + n])) n += 1;
                while (n + 1 > min) : (n -= 1) {
                    if (self.matchHere(rest, text, pos + n)) return true;
                    if (n == 0) break;
                }
                return min == 0 and self.matchHere(rest, text, pos);
            }
        }
        if (pos >= text.len) return false;
        if (!self.atomMatches(p, 0, text[pos])) return false;
        return self.matchHere(p[alen..], text, pos + 1);
    }
};

/// 二进制探测:前 8KB 含 NUL 即认为二进制(与 git 同策略)。
fn looksBinary(data: []const u8) bool {
    const head = data[0..@min(data.len, 8192)];
    return std.mem.indexOfScalar(u8, head, 0) != null;
}

/// 递归收集文件相对路径到 out。跳过 SKIP_DIRS 与符号链接。
/// rel 为相对 root 的前缀(顶层为 "")。depth 防御异常深的树。
fn collectFiles(
    alloc: std.mem.Allocator,
    out: *std.array_list.Managed([]const u8),
    root: []const u8,
    rel: []const u8,
    limit: usize,
    depth: u8,
) !void {
    if (out.items.len >= limit or depth > 32) return;
    const abs = if (rel.len == 0) root else try util.joinPath(alloc, root, rel);
    var dir = std.Io.Dir.cwd().openDir(util.io, abs, .{ .iterate = true }) catch return;
    defer dir.close(util.io);
    var it = dir.iterate();
    while (it.next(util.io) catch null) |entry| {
        if (out.items.len >= limit) return;
        if (entry.kind == .directory) {
            if (isSkippedDir(entry.name)) continue;
            const child = try util.joinPath(alloc, rel, entry.name);
            try collectFiles(alloc, out, root, child, limit, depth + 1);
        } else if (entry.kind == .file) {
            try out.append(try util.joinPath(alloc, rel, entry.name));
        }
    }
}

/// grep: {pattern, path?, glob?, ignoreCase?, literal?, context?, limit?}
/// 纯 Zig 实现:literal 走子串匹配,否则走最小正则引擎。
fn toolGrep(arena: std.mem.Allocator, args: []const u8) !Result {
    const v = try parseArgs(arena, args);
    const pattern = jstr(v, "pattern") orelse return .{ .content = "error: missing 'pattern' argument", .is_error = true };
    if (pattern.len == 0) return .{ .content = "error: 'pattern' must not be empty", .is_error = true };
    const root = jstr(v, "path") orelse ".";
    const glob = jstr(v, "glob");
    const ignore_case = jbool(v, "ignoreCase") orelse false;
    const literal = jbool(v, "literal") orelse false;
    const ctx_lines: usize = if (jint(v, "context")) |c| @intCast(@max(0, @min(c, 10))) else 0;
    const limit: usize = if (jint(v, "limit")) |l| @intCast(@max(1, @min(l, 2000))) else 200;

    var re: ?Regex = null;
    if (!literal) {
        re = Regex.init(pattern, ignore_case) catch |err| {
            return .{
                .content = try std.fmt.allocPrint(arena, "error: bad pattern '{s}': {s}. Supported: char classes, . * + ? ^ $, escapes \\d \\w \\s. Not supported: groups, alternation |. Use literal=true for plain text.", .{ pattern, @errorName(err) }),
                .is_error = true,
            };
        };
    }

    // 候选文件:单文件直接用,目录则递归收集
    var files = std.array_list.Managed([]const u8).init(arena);
    const single = blk: {
        var d = std.Io.Dir.cwd().openDir(util.io, root, .{}) catch break :blk true;
        d.close(util.io);
        break :blk false;
    };
    if (single) {
        try files.append(root);
    } else {
        // 收集上限放宽,glob 过滤后才是真正的搜索集
        try collectFiles(arena, &files, root, "", 20000, 0);
    }

    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    var hits: usize = 0;
    var scanned: usize = 0;
    var truncated = false;

    for (files.items) |rel| {
        if (hits >= limit) {
            truncated = true;
            break;
        }
        if (glob) |g| {
            // glob 同时试全路径与 basename(模型常写 "*.zig" 期望匹配任意层级)
            if (!globMatch(g, rel) and !globMatch(g, std.fs.path.basename(rel))) continue;
        }
        const full = if (single) rel else try util.joinPath(arena, root, rel);
        const data = std.Io.Dir.cwd().readFileAlloc(util.io, full, arena, .limited(8 * 1024 * 1024)) catch continue;
        if (looksBinary(data)) continue;
        scanned += 1;

        // 行切分后逐行匹配;context 需要回看,故先物化行数组
        var lines = std.array_list.Managed([]const u8).init(arena);
        var lit = std.mem.splitScalar(u8, data, '\n');
        while (lit.next()) |ln| try lines.append(ln);

        var last_printed: ?usize = null;
        for (lines.items, 0..) |line, idx| {
            if (hits >= limit) {
                truncated = true;
                break;
            }
            const matched = if (literal)
                (if (ignore_case) asciiContainsIgnoreCase(line, pattern) else std.mem.indexOf(u8, line, pattern) != null)
            else
                re.?.search(line);
            if (!matched) continue;

            // 上下文前置行(用 `-` 分隔符,仿 GNU grep)
            if (ctx_lines > 0) {
                const from = if (idx >= ctx_lines) idx - ctx_lines else 0;
                var c = from;
                while (c < idx) : (c += 1) {
                    if (last_printed) |lp| {
                        if (c <= lp) continue;
                    }
                    try aw.writer.print("{s}-{d}-{s}\n", .{ full, c + 1, lines.items[c] });
                    last_printed = c;
                }
            }
            try aw.writer.print("{s}:{d}:{s}\n", .{ full, idx + 1, line });
            last_printed = idx;
            hits += 1;
            // 上下文后置行
            if (ctx_lines > 0) {
                var c = idx + 1;
                const to = @min(idx + ctx_lines, lines.items.len - 1);
                while (c <= to) : (c += 1) {
                    try aw.writer.print("{s}-{d}-{s}\n", .{ full, c + 1, lines.items[c] });
                    last_printed = c;
                }
            }
        }
    }

    if (hits == 0) {
        return .{ .content = try std.fmt.allocPrint(arena, "no matches for '{s}' in {s} ({d} files scanned)", .{ pattern, root, scanned }) };
    }
    if (truncated) {
        try aw.writer.print("...[stopped at {d} matches; narrow the pattern or raise limit]...\n", .{limit});
    }
    return capped(arena, aw.written(), "grep", aw.written().len);
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return needle.len == 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// find: {pattern, path?, limit?} — glob 匹配文件路径,递归。
fn toolFind(arena: std.mem.Allocator, args: []const u8) !Result {
    const v = try parseArgs(arena, args);
    const pattern = jstr(v, "pattern") orelse return .{ .content = "error: missing 'pattern' argument", .is_error = true };
    const root = jstr(v, "path") orelse ".";
    const limit: usize = if (jint(v, "limit")) |l| @intCast(@max(1, @min(l, 2000))) else 200;

    var files = std.array_list.Managed([]const u8).init(arena);
    try collectFiles(arena, &files, root, "", 20000, 0);

    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    var n: usize = 0;
    for (files.items) |rel| {
        if (n >= limit) break;
        // 同时试全路径与 basename:模型写 "*.zig" 通常想匹配任意层级
        if (!globMatch(pattern, rel) and !globMatch(pattern, std.fs.path.basename(rel))) continue;
        const full = try util.joinPath(arena, root, rel);
        try aw.writer.print("{s}\n", .{full});
        n += 1;
    }
    if (n == 0) {
        return .{ .content = try std.fmt.allocPrint(arena, "no files matching '{s}' under {s}", .{ pattern, root }) };
    }
    if (n >= limit) try aw.writer.print("...[stopped at {d} results]...\n", .{limit});
    return capped(arena, aw.written(), "find", aw.written().len);
}

/// ls: {path?, limit?} — 列目录条目,目录优先按名排序。
fn toolLs(arena: std.mem.Allocator, args: []const u8) !Result {
    const v = try parseArgs(arena, args);
    const path = jstr(v, "path") orelse ".";
    const limit: usize = if (jint(v, "limit")) |l| @intCast(@max(1, @min(l, 2000))) else 200;

    var dir = std.Io.Dir.cwd().openDir(util.io, path, .{ .iterate = true }) catch |err| {
        return .{ .content = try std.fmt.allocPrint(arena, "error listing {s}: {s}", .{ path, @errorName(err) }), .is_error = true };
    };
    defer dir.close(util.io);

    const Entry = struct { name: []const u8, is_dir: bool, size: u64 };
    var entries = std.array_list.Managed(Entry).init(arena);
    var it = dir.iterate();
    while (it.next(util.io) catch null) |e| {
        var size: u64 = 0;
        if (e.kind == .file) {
            const full = try util.joinPath(arena, path, e.name);
            if (std.Io.Dir.cwd().statFile(util.io, full, .{})) |st| {
                size = st.size;
            } else |_| {}
        }
        try entries.append(.{
            .name = try arena.dupe(u8, e.name),
            .is_dir = e.kind == .directory,
            .size = size,
        });
    }
    // 目录优先,同类按名字典序
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            if (a.is_dir != b.is_dir) return a.is_dir;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    try aw.writer.print("{s}/ ({d} entries)\n", .{ path, entries.items.len });
    for (entries.items, 0..) |e, i| {
        if (i >= limit) {
            try aw.writer.print("...[stopped at {d} entries]...\n", .{limit});
            break;
        }
        if (e.is_dir) {
            try aw.writer.print("  {s}/\n", .{e.name});
        } else {
            try aw.writer.print("  {s}  {d}B\n", .{ e.name, e.size });
        }
    }
    return capped(arena, aw.written(), "ls", aw.written().len);
}

/// multi_edit: {files: [{path, edits: [{oldText, newText}]}]}
/// 跨文件批量编辑,**原子语义**:先全量 dry-run 校验,任一失败则一个字节都不写。
/// 这是它相对多次单 edit 调用的核心价值 —— 避免改一半留下不一致的工作树。
fn toolMultiEdit(arena: std.mem.Allocator, args: []const u8) !Result {
    const v = try parseArgs(arena, args);
    const files = v.object.get("files") orelse return .{ .content = "error: missing 'files' array", .is_error = true };
    if (files != .array or files.array.items.len == 0) {
        return .{ .content = "error: 'files' must be a non-empty array", .is_error = true };
    }

    // 阶段一:全量校验并算出每个文件的最终内容(只在内存里,不落盘)
    const Pending = struct { path: []const u8, content: []const u8, n_edits: usize };
    var pending = std.array_list.Managed(Pending).init(arena);
    for (files.array.items) |f| {
        if (f != .object) return .{ .content = "error: files entry must be an object", .is_error = true };
        const path = jstr(f, "path") orelse return .{ .content = "error: files entry missing 'path'", .is_error = true };
        const edits = f.object.get("edits") orelse return .{
            .content = try std.fmt.allocPrint(arena, "error: {s}: missing 'edits' array", .{path}),
            .is_error = true,
        };
        if (edits != .array or edits.array.items.len == 0) return .{
            .content = try std.fmt.allocPrint(arena, "error: {s}: 'edits' must be a non-empty array", .{path}),
            .is_error = true,
        };
        const orig = std.Io.Dir.cwd().readFileAlloc(util.io, path, arena, .limited(64 * 1024 * 1024)) catch |err| {
            return .{
                .content = try std.fmt.allocPrint(arena, "error reading {s}: {s} — nothing was written", .{ path, @errorName(err) }),
                .is_error = true,
            };
        };
        var buf = std.array_list.Managed(u8).init(arena);
        try buf.appendSlice(orig);
        for (edits.array.items, 0..) |e, ei| {
            if (e != .object) return .{
                .content = try std.fmt.allocPrint(arena, "error: {s} edit[{d}]: must be an object — nothing was written", .{ path, ei }),
                .is_error = true,
            };
            const old_text = jstr(e, "oldText") orelse return .{
                .content = try std.fmt.allocPrint(arena, "error: {s} edit[{d}]: missing oldText — nothing was written", .{ path, ei }),
                .is_error = true,
            };
            const new_text = jstr(e, "newText") orelse "";
            if (old_text.len == 0) return .{
                .content = try std.fmt.allocPrint(arena, "error: {s} edit[{d}]: oldText must not be empty — nothing was written", .{ path, ei }),
                .is_error = true,
            };
            // 唯一匹配校验(与 edit 工具同契约)
            var count: usize = 0;
            var idx: usize = 0;
            while (std.mem.indexOfPos(u8, buf.items, idx, old_text)) |found| {
                count += 1;
                idx = found + old_text.len;
            }
            if (count != 1) return .{
                .content = try std.fmt.allocPrint(arena, "error: {s} edit[{d}]: oldText matched {d} times, need exactly 1 — nothing was written", .{ path, ei, count }),
                .is_error = true,
            };
            const at = std.mem.indexOf(u8, buf.items, old_text).?;
            var next = std.array_list.Managed(u8).init(arena);
            try next.appendSlice(buf.items[0..at]);
            try next.appendSlice(new_text);
            try next.appendSlice(buf.items[at + old_text.len ..]);
            buf = next;
        }
        try pending.append(.{ .path = path, .content = buf.items, .n_edits = edits.array.items.len });
    }

    // 阶段二:全部校验通过,逐个落盘
    for (pending.items) |p| {
        std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = p.path, .data = p.content }) catch |err| {
            return .{
                .content = try std.fmt.allocPrint(arena, "error writing {s}: {s} — earlier files in this batch were already written", .{ p.path, @errorName(err) }),
                .is_error = true,
            };
        };
    }

    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    try aw.writer.print("edited {d} files:\n", .{pending.items.len});
    for (pending.items) |p| {
        try aw.writer.print("  {s}: {d} replacements\n", .{ p.path, p.n_edits });
    }
    return capped(arena, aw.written(), "multi_edit", aw.written().len);
}

pub const tools = [_]Tool{
    .{
        .name = "read",
        .desc = "Read a file. Returns the full text, or a line-range slice when offset/limit are given.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"File path to read."},"offset":{"type":"integer","description":"1-based line number to start from."},"limit":{"type":"integer","description":"Maximum number of lines to return."}},"required":["path"]}
        ,
        .handler = toolRead,
    },
    .{
        .name = "write",
        .desc = "Write a file, creating parent directories. RULE: use this tool for all file writes — never mutate files through shell scripts or spawned processes.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"File path to write."},"content":{"type":"string","description":"Full file contents."}},"required":["path","content"]}
        ,
        .handler = toolWrite,
    },
    .{
        .name = "edit",
        .desc = "Replace exact oldText with newText in a file. Each oldText must match exactly once. RULE: always mutate source files with this built-in tool — external scripting is for analysis/validation only, never for editing source.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"File path to edit."},"edits":{"type":"array","description":"Edits applied in order.","items":{"type":"object","properties":{"oldText":{"type":"string","description":"Exact text to replace; must occur exactly once."},"newText":{"type":"string","description":"Replacement text."}},"required":["oldText","newText"]}}},"required":["path","edits"]}
        ,
        .handler = toolEdit,
    },
    .{
        .name = "bash",
        .desc = "Run a shell command. RULE: do not use shell to modify source files — use the built-in write/edit tools instead; bash is for inspection, builds, and tests.",
        .schema =
        \\{"type":"object","properties":{"command":{"type":"string","description":"Shell command to run."},"timeout":{"type":"integer","description":"Timeout in seconds (default 30)."}},"required":["command"]}
        ,
        .handler = toolBash,
    },
    .{
        .name = "grep",
        .desc = "Search file contents by regex (or literal text). Prefer this over shelling out to grep/rg: it returns structured path:line:match output, skips build dirs and binaries, and caps result count.",
        .schema =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"Regex pattern. Supports char classes [a-z], . * + ? ^ $, escapes \\d \\w \\s. No groups or alternation."},"path":{"type":"string","description":"File or directory to search (default '.')."},"glob":{"type":"string","description":"Filter files by glob, e.g. '*.zig' or 'src/**/*.ts'."},"ignoreCase":{"type":"boolean","description":"Case-insensitive match."},"literal":{"type":"boolean","description":"Treat pattern as plain text instead of regex."},"context":{"type":"integer","description":"Context lines around each match (0-10)."},"limit":{"type":"integer","description":"Max matches to return (default 200)."}},"required":["pattern"]}
        ,
        .handler = toolGrep,
    },
    .{
        .name = "find",
        .desc = "Find files by glob pattern, recursively. Prefer this over shelling out to find/fd.",
        .schema =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern, e.g. '*.zig' or 'src/**/*.test.ts'. Matched against both the relative path and the basename."},"path":{"type":"string","description":"Directory to search from (default '.')."},"limit":{"type":"integer","description":"Max results (default 200)."}},"required":["pattern"]}
        ,
        .handler = toolFind,
    },
    .{
        .name = "ls",
        .desc = "List directory entries; directories first, files with byte sizes.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Directory to list (default '.')."},"limit":{"type":"integer","description":"Max entries (default 200)."}},"required":[]}
        ,
        .handler = toolLs,
    },
    .{
        .name = "multi_edit",
        .desc = "Edit several files in one atomic batch. All edits are validated first; if any oldText fails to match exactly once, nothing is written. Use this for refactors that must not leave the tree half-changed.",
        .schema =
        \\{"type":"object","properties":{"files":{"type":"array","description":"Files to edit.","items":{"type":"object","properties":{"path":{"type":"string","description":"File path."},"edits":{"type":"array","description":"Edits applied in order.","items":{"type":"object","properties":{"oldText":{"type":"string","description":"Exact text to replace; must occur exactly once."},"newText":{"type":"string","description":"Replacement text."}},"required":["oldText","newText"]}}},"required":["path","edits"]}}},"required":["files"]}
        ,
        .handler = toolMultiEdit,
    },
};

pub fn find(name: []const u8) ?*const Tool {
    for (&tools) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

test "edit tool" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;
    try dir.writeFile(util.io, .{ .sub_path = "a.txt", .data = "hello world hello" });
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 进入临时目录,使 cwd 相对路径生效
    const tmppath = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const old_cwd = try std.process.currentPathAlloc(util.io, a);
    std.Io.Threaded.chdir(tmppath) catch unreachable;
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    // 多匹配 → 错误
    const r1 = try toolEdit(a, "{\"path\":\"a.txt\",\"edits\":[{\"oldText\":\"hello\",\"newText\":\"bye\"}]}");
    try t.expect(r1.is_error);
    try t.expect(std.mem.indexOf(u8, r1.content, "matches 2 times") != null);

    // 精确匹配
    const r2 = try toolEdit(a, "{\"path\":\"a.txt\",\"edits\":[{\"oldText\":\"world\",\"newText\":\"zig\"}]}");
    try t.expect(!r2.is_error);
    const content = try std.Io.Dir.cwd().readFileAlloc(util.io, "a.txt", a, .limited(1024));
    try t.expectEqualStrings("hello zig hello", content);

    // 不存在 → 错误
    const r3 = try toolEdit(a, "{\"path\":\"nope.txt\",\"edits\":[{\"oldText\":\"x\",\"newText\":\"y\"}]}");
    try t.expect(r3.is_error);

    // 输出含 diff 块(web diff 卡数据源)
    try t.expect(std.mem.indexOf(u8, r2.content, "--- a.txt") != null);
    try t.expect(std.mem.indexOf(u8, r2.content, "+++ a.txt") != null);
    try t.expect(std.mem.indexOf(u8, r2.content, "-world") != null);
    try t.expect(std.mem.indexOf(u8, r2.content, "+zig") != null);
}

test "globMatch semantics" {
    const t = std.testing;
    // 单星不跨目录分隔
    try t.expect(globMatch("*.zig", "main.zig"));
    try t.expect(!globMatch("*.zig", "src/main.zig"));
    try t.expect(globMatch("src/*.zig", "src/main.zig"));
    // ** 跨任意层级(含零层)
    try t.expect(globMatch("**/*.zig", "main.zig"));
    try t.expect(globMatch("**/*.zig", "src/deep/main.zig"));
    try t.expect(globMatch("src/**/*.ts", "src/a/b/c.ts"));
    // ? 单字符,不吃分隔符
    try t.expect(globMatch("a?c.txt", "abc.txt"));
    try t.expect(!globMatch("a?c.txt", "a/c.txt"));
    // 全字面量
    try t.expect(globMatch("build.zig", "build.zig"));
    try t.expect(!globMatch("build.zig", "build.zon"));
}

test "mini regex engine" {
    const t = std.testing;
    // 字符类与区间
    var re = try Regex.init("[a-c]at", false);
    try t.expect(re.search("the bat sat"));
    try t.expect(!re.search("the mat"));
    // 取反类
    re = try Regex.init("[^0-9]x", false);
    try t.expect(re.search("ax"));
    try t.expect(!re.search("1x"));
    // 量词
    re = try Regex.init("ab*c", false);
    try t.expect(re.search("ac"));
    try t.expect(re.search("abbbc"));
    re = try Regex.init("ab+c", false);
    try t.expect(!re.search("ac"));
    try t.expect(re.search("abc"));
    re = try Regex.init("ab?c", false);
    try t.expect(re.search("ac"));
    try t.expect(re.search("abc"));
    // 锚
    re = try Regex.init("^fn ", false);
    try t.expect(re.search("fn main() void {"));
    try t.expect(!re.search("  fn main"));
    re = try Regex.init("\\{$", false);
    try t.expect(re.search("fn main() void {"));
    try t.expect(!re.search("fn main() void { }"));
    // 转义类
    re = try Regex.init("\\d\\d\\d", false);
    try t.expect(re.search("abc 123"));
    try t.expect(!re.search("ab 12"));
    re = try Regex.init("\\w+_test", false);
    try t.expect(re.search("my_test"));
    // 转义字面量:\. 只匹配真的点
    re = try Regex.init("a\\.b", false);
    try t.expect(re.search("a.b"));
    try t.expect(!re.search("axb"));
    // 大小写不敏感
    re = try Regex.init("hello", true);
    try t.expect(re.search("HELLO world"));
    // 非法 pattern 报错而非 crash
    try t.expectError(error.UnclosedCharClass, Regex.init("[abc", false));
    try t.expectError(error.TrailingBackslash, Regex.init("abc\\", false));
}

test "grep find ls tools over a real tree" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;
    try dir.createDirPath(util.io, "src");
    try dir.createDirPath(util.io, ".git");
    try dir.writeFile(util.io, .{ .sub_path = "src/a.zig", .data = "const x = 1;\nfn hello() void {}\n" });
    try dir.writeFile(util.io, .{ .sub_path = "src/b.txt", .data = "hello there\n" });
    // .git 下的命中必须被跳过,否则搜索结果会被 VCS 元数据污染
    try dir.writeFile(util.io, .{ .sub_path = ".git/config", .data = "hello from git\n" });
    // 二进制文件必须被跳过
    try dir.writeFile(util.io, .{ .sub_path = "bin.dat", .data = "hello\x00\x01binary" });

    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmppath = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const old_cwd = try std.process.currentPathAlloc(util.io, a);
    std.Io.Threaded.chdir(tmppath) catch unreachable;
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    // grep:命中两个文本文件,跳过 .git 与二进制
    const g = try toolGrep(a, "{\"pattern\":\"hello\"}");
    try t.expect(!g.is_error);
    try t.expect(std.mem.indexOf(u8, g.content, "src/a.zig:2:") != null);
    try t.expect(std.mem.indexOf(u8, g.content, "src/b.txt:1:") != null);
    try t.expect(std.mem.indexOf(u8, g.content, ".git") == null);
    try t.expect(std.mem.indexOf(u8, g.content, "bin.dat") == null);

    // grep + glob 过滤
    const g2 = try toolGrep(a, "{\"pattern\":\"hello\",\"glob\":\"*.zig\"}");
    try t.expect(std.mem.indexOf(u8, g2.content, "src/a.zig") != null);
    try t.expect(std.mem.indexOf(u8, g2.content, "b.txt") == null);

    // grep literal:正则元字符按字面量处理
    const g3 = try toolGrep(a, "{\"pattern\":\"x = 1;\",\"literal\":true}");
    try t.expect(std.mem.indexOf(u8, g3.content, "src/a.zig:1:") != null);

    // grep 无命中:不是错误,是空结果
    const g4 = try toolGrep(a, "{\"pattern\":\"nonexistent_zzz\"}");
    try t.expect(!g4.is_error);
    try t.expect(std.mem.indexOf(u8, g4.content, "no matches") != null);

    // grep 坏 pattern:报错且给出可操作提示
    const g5 = try toolGrep(a, "{\"pattern\":\"[unclosed\"}");
    try t.expect(g5.is_error);
    try t.expect(std.mem.indexOf(u8, g5.content, "literal=true") != null);

    // find:glob 匹配路径
    const f = try toolFind(a, "{\"pattern\":\"*.zig\"}");
    try t.expect(!f.is_error);
    try t.expect(std.mem.indexOf(u8, f.content, "a.zig") != null);
    try t.expect(std.mem.indexOf(u8, f.content, "b.txt") == null);

    // ls:目录优先,带大小
    const l = try toolLs(a, "{}");
    try t.expect(!l.is_error);
    try t.expect(std.mem.indexOf(u8, l.content, "src/") != null);
    try t.expect(std.mem.indexOf(u8, l.content, "bin.dat") != null);

    // ls 不存在的目录 → 错误
    const l2 = try toolLs(a, "{\"path\":\"nope\"}");
    try t.expect(l2.is_error);
}

test "multi_edit is atomic: failure leaves files untouched" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;
    try dir.writeFile(util.io, .{ .sub_path = "one.txt", .data = "alpha beta" });
    try dir.writeFile(util.io, .{ .sub_path = "two.txt", .data = "gamma delta" });

    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmppath = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const old_cwd = try std.process.currentPathAlloc(util.io, a);
    std.Io.Threaded.chdir(tmppath) catch unreachable;
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    // 第二个文件的 edit 匹配不到 → 整批必须回滚(第一个文件也不能被写)
    const bad = try toolMultiEdit(a,
        \\{"files":[{"path":"one.txt","edits":[{"oldText":"alpha","newText":"ALPHA"}]},
        \\          {"path":"two.txt","edits":[{"oldText":"nonexistent","newText":"X"}]}]}
    );
    try t.expect(bad.is_error);
    try t.expect(std.mem.indexOf(u8, bad.content, "nothing was written") != null);
    // 关键断言:磁盘上第一个文件未被改动
    const c1 = try std.Io.Dir.cwd().readFileAlloc(util.io, "one.txt", a, .limited(1024));
    try t.expectEqualStrings("alpha beta", c1);

    // 全部合法 → 都写入
    const ok = try toolMultiEdit(a,
        \\{"files":[{"path":"one.txt","edits":[{"oldText":"alpha","newText":"ALPHA"}]},
        \\          {"path":"two.txt","edits":[{"oldText":"gamma","newText":"GAMMA"}]}]}
    );
    try t.expect(!ok.is_error);
    const c2 = try std.Io.Dir.cwd().readFileAlloc(util.io, "one.txt", a, .limited(1024));
    try t.expectEqualStrings("ALPHA beta", c2);
    const c3 = try std.Io.Dir.cwd().readFileAlloc(util.io, "two.txt", a, .limited(1024));
    try t.expectEqualStrings("GAMMA delta", c3);

    // 同一文件多条 edit 顺序应用
    const seq = try toolMultiEdit(a,
        \\{"files":[{"path":"two.txt","edits":[{"oldText":"GAMMA","newText":"g"},{"oldText":"delta","newText":"d"}]}]}
    );
    try t.expect(!seq.is_error);
    const c4 = try std.Io.Dir.cwd().readFileAlloc(util.io, "two.txt", a, .limited(1024));
    try t.expectEqualStrings("g d", c4);
}

test "read offset and limit slice lines" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(util.io, .{ .sub_path = "n.txt", .data = "l1\nl2\nl3\nl4\nl5\n" });

    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmppath = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const old_cwd = try std.process.currentPathAlloc(util.io, a);
    std.Io.Threaded.chdir(tmppath) catch unreachable;
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    // offset 是 1-based
    const r1 = try toolRead(a, "{\"path\":\"n.txt\",\"offset\":2,\"limit\":2}");
    try t.expect(!r1.is_error);
    try t.expectEqualStrings("l2\nl3", r1.content);
    // 只给 limit → 从首行起
    const r2 = try toolRead(a, "{\"path\":\"n.txt\",\"limit\":1}");
    try t.expectEqualStrings("l1", r2.content);
    // offset 越界 → 明确报错而非空内容
    const r3 = try toolRead(a, "{\"path\":\"n.txt\",\"offset\":99}");
    try t.expect(r3.is_error);
    try t.expect(std.mem.indexOf(u8, r3.content, "past end") != null);
    // 不给 offset/limit → 全文
    const r4 = try toolRead(a, "{\"path\":\"n.txt\"}");
    try t.expectEqualStrings("l1\nl2\nl3\nl4\nl5\n", r4.content);
}

test "write tool emits diff block" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmppath = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const old_cwd = try std.process.currentPathAlloc(util.io, a);
    std.Io.Threaded.chdir(tmppath) catch unreachable;
    defer std.Io.Threaded.chdir(old_cwd) catch {};
    const r = try toolWrite(a, "{\"path\":\"b.txt\",\"content\":\"x\\ny\\n\"}");
    try t.expect(!r.is_error);
    try t.expect(std.mem.indexOf(u8, r.content, "--- b.txt") != null);
    try t.expect(std.mem.indexOf(u8, r.content, "+x") != null);
    try t.expect(std.mem.indexOf(u8, r.content, "+y") != null);
}

test "read truncates large files" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmppath = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const old_cwd = try std.process.currentPathAlloc(util.io, a);
    std.Io.Threaded.chdir(tmppath) catch unreachable;
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    // 20KB 文件:输出应截断在 MAX_TOOL_OUTPUT 内且带标记
    try tmp.dir.writeFile(util.io, .{ .sub_path = "big.txt", .data = "x" ** (20 * 1024) });
    const r = try toolRead(a, "{\"path\":\"big.txt\"}");
    try t.expect(!r.is_error);
    try t.expect(r.content.len <= MAX_TOOL_OUTPUT + 128);
    try t.expect(std.mem.indexOf(u8, r.content, "truncated at") != null);
}

test "read/write tools" {
    const t = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 必须切进临时目录:工具收的是相对路径,不 chdir 的话 sub/b.txt 会落在
    // 仓库根上,留下一个每次跑测试都重建的脏文件。
    const tmppath = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const old_cwd = try std.process.currentPathAlloc(util.io, a);
    std.Io.Threaded.chdir(tmppath) catch unreachable;
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    // 父目录不存在时 write 应自己建出来
    const rw = try toolWrite(a, "{\"path\":\"sub/b.txt\",\"content\":\"data\"}");
    try t.expect(!rw.is_error);
    const rr = try toolRead(a, "{\"path\":\"sub/b.txt\"}");
    try t.expect(!rr.is_error);
    try t.expectEqualStrings("data", rr.content);
}

test "bash tool" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try toolBash(a, "{\"command\":\"echo hello; echo err >&2\"}");
    try t.expect(!r.is_error);
    try t.expect(std.mem.indexOf(u8, r.content, "hello") != null);
    try t.expect(std.mem.indexOf(u8, r.content, "err") != null);
    try t.expect(std.mem.indexOf(u8, r.content, "exit code 0") != null);

    const r2 = try toolBash(a, "{\"command\":\"exit 3\"}");
    try t.expect(r2.is_error);
    try t.expect(std.mem.indexOf(u8, r2.content, "exit code 3") != null);
}

test "appendCapped keeps the tail and never grows past 2x the window" {
    const t = std.testing;
    var list = std.array_list.Managed(u8).init(t.allocator);
    defer list.deinit();

    // keep=0 表示不限
    try appendCapped(&list, "abc", 0);
    try t.expectEqualStrings("abc", list.items);
    list.clearRetainingCapacity();

    // 窗口内原样保留
    try appendCapped(&list, "hello", 10);
    try t.expectEqualStrings("hello", list.items);

    // 灌 1000 个 chunk,每个 64 字节 = 64KB 流量,窗口 100 字节。
    // 关键不变量:缓冲永不超过 2×窗口 —— 这是内存有界的全部依据。
    // 原先无界追加:一个吐 500MB 的子进程让父进程驻留 473MB(实测)。
    list.clearRetainingCapacity();
    var i: usize = 0;
    var max_seen: usize = 0;
    while (i < 1000) : (i += 1) {
        var chunk: [64]u8 = undefined;
        @memset(&chunk, @intCast('a' + (i % 26)));
        try appendCapped(&list, &chunk, 100);
        max_seen = @max(max_seen, list.items.len);
    }
    try t.expect(max_seen <= 200);

    // 保的是尾部:最后一个 chunk 的内容必须在
    const last: u8 = @intCast('a' + (999 % 26));
    try t.expectEqual(last, list.items[list.items.len - 1]);
}

test "bash reports the true byte total after dropping the head" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 输出远超 MAX_TOOL_OUTPUT。截断提示里的 total 必须是真实流量,
    // 不是被裁后的缓冲长度 —— 否则「输出了 5MB」会报成「输出了 16KB」,
    // 模型据此判断要不要换个更窄的命令重跑。
    const r = try toolBash(a, "{\"command\":\"head -c 5000000 /dev/zero | tr '\\\\0' x\",\"timeout\":60}");
    try t.expect(!r.is_error);
    try t.expect(std.mem.indexOf(u8, r.content, "truncated at") != null);

    const marker = "total ";
    const pos = std.mem.indexOf(u8, r.content, marker).?;
    var end = pos + marker.len;
    while (end < r.content.len and r.content[end] >= '0' and r.content[end] <= '9') end += 1;
    const total = try std.fmt.parseInt(usize, r.content[pos + marker.len .. end], 10);
    try t.expect(total >= 5_000_000);

    // 交给模型的内容本身仍然受限
    try t.expect(r.content.len < MAX_TOOL_OUTPUT * 2);
}

test "skill tool" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 注:Environ.Map.put 覆盖时 free 旧值,恢复旧值会 UAF——测试内只覆盖不恢复
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    tmp.dir.createDirPath(util.io, "skills/rev") catch {};
    try tmp.dir.writeFile(util.io, .{ .sub_path = "skills/rev/SKILL.md", .data = "name: rev\ndescription: reverse engineering\n" });
    const r = try toolSkill(a, "{\"name\":\"rev\"}");
    try t.expect(!r.is_error);
    try t.expect(std.mem.indexOf(u8, r.content, "reverse engineering") != null);
    // 非法名
    const bad = try toolSkill(a, "{\"name\":\"../evil\"}");
    try t.expect(bad.is_error);
    // 不存在
    const nf = try toolSkill(a, "{\"name\":\"nope\"}");
    try t.expect(nf.is_error);
}
