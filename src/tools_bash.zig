// tools_bash.zig — bash / pipes / background jobs. Split from tools.zig.
const std = @import("std");
const util = @import("util.zig");
const activity = @import("activity.zig");
const sandboxmod = @import("sandbox.zig");
const tjson = @import("tools_json.zig");
const tpath = @import("tools_path.zig");

const parseArgs = tjson.parseArgs;
const jstr = tjson.jstr;
const jbool = tjson.jbool;
const resolvePath = tpath.resolvePath;
const rootForSpawn = tpath.rootForSpawn;
const absWorkspace = tpath.absWorkspace;
const artifactDir = tpath.artifactDir;

const MAX_TOOL_OUTPUT = 16 * 1024;

pub const Result = struct {
    content: []const u8,
    is_error: bool = false,
};

fn outsideWorkspace(arena: std.mem.Allocator, path: []const u8) ?Result {
    if (tpath.realInsideRoot(arena, path)) return null;
    return .{ .content = "error: path is outside the workspace", .is_error = true };
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
    /// 超 keep 才建。全文落到磁盘,内存仍只留尾。
    spill_path: ?[]const u8 = null,
    spill: ?std.Io.File = null,
    spilled: bool = false,
};

var bg_live: std.atomic.Value(u32) = .init(0);
const MAX_BG_JOBS: u32 = 8;

const BgJob = struct {
    child: std.process.Child,
    buf: std.array_list.Managed(u8),
    spill_path: []u8,
    command: []u8,
    act: activity.Handle,
};

fn finishBg(job: *BgJob) void {
    job.act.release();
    job.buf.deinit();
    std.heap.page_allocator.free(job.spill_path);
    std.heap.page_allocator.free(job.command);
    std.heap.page_allocator.destroy(job);
    _ = bg_live.fetchSub(1, .monotonic);
}

fn runBgJob(job: *BgJob) void {
    defer finishBg(job);
    const out_fd = if (job.child.stdout) |f| f.handle else return;
    const err_fd = if (job.child.stderr) |f| f.handle else return;
    var state = PipeState{
        .buf = &job.buf,
        .out_fd = out_fd,
        .err_fd = err_fd,
        .keep_bytes = MAX_TOOL_OUTPUT,
        .spill_path = job.spill_path,
    };
    openSpill(&state);
    defer closeSpill(&state);
    defer {
        if (job.child.stdout) |f| f.close(util.io);
        if (job.child.stderr) |f| f.close(util.io);
        job.child.stdout = null;
        job.child.stderr = null;
    }
    _ = pumpPipes(&state, 24 * 60 * 60 * 1000, job.act) catch |err| util.debugCatch("bash.bg.pump", err);
    const term: std.process.Child.Term = job.child.wait(util.io) catch .{ .exited = 1 };
    const code: u8 = switch (term) {
        .exited => |c| c,
        .signal => |s| @intCast(128 + @intFromEnum(s)),
        else => 1,
    };
    var note_buf: [48]u8 = undefined;
    const note = std.fmt.bufPrint(&note_buf, "\n[background exit {d}]\n", .{code}) catch "\n[background exit]\n";
    spillWrite(&state, note);
}

fn startBackground(arena: std.mem.Allocator, child: *std.process.Child, command: []const u8) !Result {
    if (bg_live.load(.monotonic) >= MAX_BG_JOBS) {
        if (child.id) |pid| killGroup(pid);
        child.kill(util.io);
        return .{ .content = "error: too many background bash jobs (max 8); wait for one to finish", .is_error = true };
    }
    const path = makeBashArtifactPath(arena) catch {
        if (child.id) |pid| killGroup(pid);
        child.kill(util.io);
        return .{ .content = "error: cannot allocate background log path", .is_error = true };
    };
    const pa = std.heap.page_allocator;
    const job = pa.create(BgJob) catch {
        if (child.id) |pid| killGroup(pid);
        child.kill(util.io);
        return .{ .content = "error: cannot allocate background job", .is_error = true };
    };
    const spill_copy = pa.dupe(u8, path) catch {
        pa.destroy(job);
        if (child.id) |pid| killGroup(pid);
        child.kill(util.io);
        return .{ .content = "error: cannot copy background log path", .is_error = true };
    };
    const cmd_copy = pa.dupe(u8, command) catch {
        pa.free(spill_copy);
        pa.destroy(job);
        if (child.id) |pid| killGroup(pid);
        child.kill(util.io);
        return .{ .content = "error: cannot copy background command", .is_error = true };
    };
    job.* = .{
        .child = child.*,
        .buf = std.array_list.Managed(u8).init(pa),
        .spill_path = spill_copy,
        .command = cmd_copy,
        .act = activity.begin(.tool, "bash-bg", command, 0),
    };
    child.stdout = null;
    child.stderr = null;
    job.act.detach();
    if (child.id) |p| job.act.setPid(@intCast(p));
    _ = bg_live.fetchAdd(1, .monotonic);
    const th = std.Thread.spawn(.{}, runBgJob, .{job}) catch {
        if (job.child.id) |pid| killGroup(pid);
        job.child.kill(util.io);
        finishBg(job);
        return .{ .content = "error: cannot start background waiter", .is_error = true };
    };
    th.detach();
    var pid_n: i64 = 0;
    if (child.id) |p| pid_n = @intCast(p);
    return .{ .content = try std.fmt.allocPrint(arena, "[background] pid={d}\nlog: {s}\ncommand: {s}\noutput streams to the log; read that file. process is not killed on timeout.", .{ pid_n, job.spill_path, command }) };
}

fn makeBashArtifactPath(arena: std.mem.Allocator) ![]u8 {
    const dir = try util.configDir(arena);
    const artifacts = try util.joinPath(arena, dir, "artifacts");
    const ts = @divTrunc(std.Io.Clock.now(.real, util.io).nanoseconds, std.time.ns_per_ms);
    return std.fmt.allocPrint(arena, "{s}/{d}-bash-{d}.txt", .{ artifacts, ts, std.Thread.getCurrentId() });
}

fn openSpill(state: *PipeState) void {
    const path = state.spill_path orelse return;
    if (state.spill != null) return;
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(util.io, dir) catch |err| {
            util.debugCatch("bash.spill.mkdir", err);
            return;
        };
    }
    const f = std.Io.Dir.cwd().createFile(util.io, path, .{ .exclusive = true, .permissions = @enumFromInt(0o600) }) catch |err| {
        util.debugCatch("bash.spill.create", err);
        return;
    };
    state.spill = f;
    state.spilled = true;
}

fn spillWrite(state: *PipeState, data: []const u8) void {
    const f = if (state.spill) |*file| file else return;
    var wbuf: [4096]u8 = undefined;
    var w = f.writer(util.io, &wbuf);
    const end = f.length(util.io) catch 0;
    w.seekTo(end) catch |err| {
        util.debugCatch("bash.spill.seek", err);
        return;
    };
    w.interface.writeAll(data) catch |err| {
        util.debugCatch("bash.spill", err);
        return;
    };
    w.flush() catch |err| util.debugCatch("bash.spill.flush", err);
}

fn spillChunk(state: *PipeState, existing: []const u8, data: []const u8) void {
    if (state.spill_path == null or state.keep_bytes == 0) return;
    if (state.spill == null) {
        if (existing.len + data.len <= state.keep_bytes) return;
        openSpill(state);
        if (state.spill == null) return;
        spillWrite(state, existing);
    }
    spillWrite(state, data);
}

fn closeSpill(state: *PipeState) void {
    if (state.spill) |*f| {
        f.close(util.io);
        state.spill = null;
    }
}

/// 追加并把 list 压回 `keep` 字节以内(丢头留尾)。
pub fn appendCapped(list: *std.array_list.Managed(u8), data: []const u8, keep: usize) !void {
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
                spillChunk(state, eb.items, chunk[0..n]);
                try appendCapped(eb, chunk[0..n], state.keep_bytes);
                continue;
            }
            spillChunk(state, state.buf.items, "\x1b[2m[stderr]\x1b[0m ");
            try appendCapped(state.buf, "\x1b[2m[stderr]\x1b[0m ", state.keep_bytes);
        } else {
            state.total_out += n;
        }
        spillChunk(state, state.buf.items, chunk[0..n]);
        try appendCapped(state.buf, chunk[0..n], state.keep_bytes);
        if (is_err) {
            spillChunk(state, state.buf.items, "\n");
            try appendCapped(state.buf, "\n", state.keep_bytes);
        }
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
    std.posix.kill(-pid, std.posix.SIG.TERM) catch |err| util.debugCatch("kill.term", err);
    // 给 100ms 优雅退出(刷 stdout、删临时文件),然后强杀
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
    std.posix.kill(-pid, std.posix.SIG.KILL) catch |err| util.debugCatch("kill.kill", err);
}

/// 只杀 activity 表里登记过的 pid,避免误伤无关进程。
pub fn killTracked(pid: std.posix.pid_t) bool {
    if (!activity.hasPid(@intCast(pid))) return false;
    killGroup(pid);
    return true;
}

/// bash: {command, timeout?} → 执行 sh -c,合并输出,超时或取消时杀掉整个进程组。
///
/// 登记进 activity 表:执行期间 TUI 能显示 spinner、耗时与已收字节,
/// Ctrl+C 也能在 100ms 内打断 —— 原先这两件事在命令跑完前都做不到。
pub fn substBraceArgs(arena: std.mem.Allocator, tmpl: []const u8, args_json: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, tmpl, '{') == null) return tmpl;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return error.BadArgs;
    if (parsed != .object) return error.BadArgs;
    var out = std.array_list.Managed(u8).init(arena);
    var i: usize = 0;
    while (i < tmpl.len) {
        if (tmpl[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, tmpl, i + 1, '}') orelse {
                try out.append(tmpl[i]);
                i += 1;
                continue;
            };
            const key = tmpl[i + 1 .. end];
            const v = parsed.object.get(key) orelse return error.MissingArg;
            const raw = switch (v) {
                .string => |s| s,
                .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
                .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
                .bool => |b| if (b) "true" else "false",
                else => return error.BadArgs,
            };
            try out.append('\'');
            for (raw) |c| {
                if (c == '\'') try out.appendSlice("'\"'\"'") else try out.append(c);
            }
            try out.append('\'');
            i = end + 1;
        } else {
            try out.append(tmpl[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice();
}

/// 跑包声明的 shell 工具。`{key}` 从 args JSON 取值并单引号转义。
pub fn runPkgCommand(arena: std.mem.Allocator, command: []const u8, args: []const u8) !Result {
    const expanded = substBraceArgs(arena, command, args) catch |e| {
        return .{ .content = try std.fmt.allocPrint(arena, "pkg tool args: {s}", .{@errorName(e)}), .is_error = true };
    };
    const quoted = util.jsonString(arena, expanded) catch return .{ .content = "pkg tool encode", .is_error = true };
    const wrapped = try std.fmt.allocPrint(arena, "{{\"command\":{s},\"timeout\":30}}", .{quoted});
    return toolBash(arena, wrapped);
}

pub fn pkgToolStub(_: std.mem.Allocator, _: []const u8) !Result {
    return .{ .content = "pkg tool missing payload", .is_error = true };
}

pub fn toolBash(arena: std.mem.Allocator, args: []const u8) !Result {
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
    const background = jbool(v, "background") orelse false;
    const cwd_arg = jstr(v, "cwd");
    if (cwd_arg) |c| {
        if (outsideWorkspace(arena, c)) |err| return err;
    }
    const start_dir: []const u8 = blk: {
        if (cwd_arg) |c| {
            const resolved = resolvePath(arena, c);
            const st = std.Io.Dir.cwd().statFile(util.io, resolved, .{}) catch {
                return .{ .content = try std.fmt.allocPrint(arena, "error: cwd '{s}' not found", .{c}), .is_error = true };
            };
            if (st.kind != .directory) {
                return .{ .content = try std.fmt.allocPrint(arena, "error: cwd '{s}' is not a directory", .{c}), .is_error = true };
            }
            break :blk resolved;
        }
        break :blk rootForSpawn() orelse "";
    };

    // pgid=0:子进程成为新进程组的组长。这样超时/取消时能 kill(-pgid) 收掉
    // 整棵进程树 —— `sh -c "make -j8"` 派生的孙子进程原先会孤儿化,
    // 继续吃 CPU 且没人回收。
    // cwd 取工具根目录(或参数 cwd):命令里的相对路径必须相对**这个目录**。
    // resolvePath 对 bash 无能为力(命令是任意 shell 文本,不是路径参数),
    // 只能靠子进程自己的工作目录。空 = 继承进程 cwd(CLI 模式即如此)。
    const extras = [_][]const u8{artifactDir(arena)};
    const ws = absWorkspace(arena);
    const sandbox_mode = tpath.currentSandbox();
    const argv = blk: {
        if (sandbox_mode == .off) break :blk try sandboxmod.buildArgv(arena, .off, "bwrap", ws, &extras, command, start_dir);
        const art = extras[0];
        if (art.len > 0) std.Io.Dir.cwd().createDirPath(util.io, art) catch |err| util.debugCatch("bash.art.mkdir", err);
        if (sandboxmod.findBwrap()) |bw| {
            break :blk try sandboxmod.buildArgv(arena, sandbox_mode, bw, ws, &extras, command, start_dir);
        }
        if (sandboxmod.landlockAbi() != null) {
            const exe = std.process.executablePathAlloc(util.io, arena) catch {
                return .{ .content = sandboxmod.missingSandboxMsg(arena, sandbox_mode), .is_error = true };
            };
            break :blk try sandboxmod.buildLandlockArgv(arena, exe, sandbox_mode, ws, &extras, command, start_dir);
        }
        return .{ .content = sandboxmod.missingSandboxMsg(arena, sandbox_mode), .is_error = true };
    };
    var child = try std.process.spawn(util.io, .{
        .argv = argv,
        .cwd = if (start_dir.len > 0) .{ .path = start_dir } else .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    const child_pid = child.id;
    const out_fd = child.stdout.?.handle;
    const err_fd = child.stderr.?.handle;
    setNonBlock(out_fd);
    setNonBlock(err_fd);

    if (background) {
        return startBackground(arena, &child, command);
    }

    const act = activity.begin(.tool, "bash", command, timeout_ms);
    defer act.release();

    var buf = std.array_list.Managed(u8).init(arena);
    // err_buf 省略:bash 把 stderr 交错进同一个 buffer,用户要看到执行顺序
    // keep_bytes:边读边丢头部,只留最后 MAX_TOOL_OUTPUT。留全量再截的话,
    // 一条 `find /` 就让 piz 驻留几百 MB 去换 16KB 的结果。
    var state = PipeState{
        .buf = &buf,
        .out_fd = out_fd,
        .err_fd = err_fd,
        .keep_bytes = MAX_TOOL_OUTPUT,
        .spill_path = makeBashArtifactPath(arena) catch null,
    };
    defer closeSpill(&state);
    defer {
        if (child.stdout) |f| f.close(util.io);
        if (child.stderr) |f| f.close(util.io);
    }

    const stopped = try pumpPipes(&state, timeout_ms, act);
    closeSpill(&state);
    const cancelled = stopped and act.cancelled();

    var term: std.process.Child.Term = undefined;
    if (stopped) {
        // 超时/取消也计入全生命周期错误账(工具失败是常见缺陷源)
        util.errLog(arena, "bash", "bash-timeout", std.fmt.allocPrint(arena, "{d}s timeout: {s} (partial {d}B)", .{ @divTrunc(timeout_ms, 1000), command[0..@min(command.len, 200)], @as(u64, @intCast(@min(state.total_out + state.total_err, 99999))) }) catch command);
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
    if (state.spilled and state.spill_path != null) {
        const tail = if (buf.items.len > MAX_TOOL_OUTPUT) buf.items[buf.items.len - MAX_TOOL_OUTPUT ..] else buf.items;
        content = try std.fmt.allocPrint(arena, "[Artifact stored: {s} ({d} bytes)]\n{s}\n...[output truncated at {d} bytes, total {d}; read the artifact file for full content]", .{
            state.spill_path.?,
            streamed,
            tail,
            MAX_TOOL_OUTPUT,
            streamed,
        });
    } else if (buf.items.len > MAX_TOOL_OUTPUT) {
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
