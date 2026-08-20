// cmd_print.zig — print/jsonl 输出与一次性问答。
const std = @import("std");
const util = @import("core").util;
const activity = @import("core").activity;
const cfgmod = @import("core").config;
const ai = @import("core").ai;
const agentmod = @import("core").agent;
const sessionmod = @import("core").session;
const jsrt = @import("core").jsrt;
const pluginsmod = @import("core").plugins;
const eventsmod = @import("core").events;
const runopts = @import("runopts.zig");

pub const RunOptions = runopts.RunOptions;
pub const OutputFormat = runopts.OutputFormat;

const JsonlCtx = struct {
    alloc: std.mem.Allocator,
};

/// JSONL 输出的互斥。
///
/// 两个理由,都由进程内 subagent 引入:
/// 1. 32 路 subagent 并发调 `jsonlEvent` 时,`jctx.alloc` 是 ArenaAllocator ——
///    它不是线程安全的,并发分配会损坏 arena。
/// 2. JSONL 的每行必须完整,交错的半行会让下游解析器直接失败。
var jsonl_mutex: std.Io.Mutex = .init;

fn jstdout(_: std.mem.Allocator, json: []const u8) !void {
    var sbuf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(util.io, &sbuf);
    try w.interface.writeAll(json);
    try w.flush();
}

fn jsonlEvent(alloc: std.mem.Allocator, comptime ty: []const u8, fields: anytype) !void {
    jsonl_mutex.lockUncancelable(util.io);
    defer jsonl_mutex.unlock(util.io);
    var ww = std.Io.Writer.Allocating.init(alloc);
    defer ww.deinit();
    try ww.writer.print("{{\"type\":\"{s}\"", .{ty});
    comptime var i: usize = 0;
    inline while (i < fields.len) : (i += 2) {
        const name = fields[i];
        const value = fields[i + 1];
        try ww.writer.print(",\"{s}\":{s}", .{ name, try util.jsonString(alloc, value) });
    }
    try ww.writer.writeAll("}\n");
    try jstdout(alloc, try ww.toOwnedSlice());
}

fn jsonlOnText(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const jctx: *JsonlCtx = @ptrCast(@alignCast(ctx.?));
    try jsonlEvent(jctx.alloc, "text", .{ "text", text });
}

fn jsonlOnReasoning(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const jctx: *JsonlCtx = @ptrCast(@alignCast(ctx.?));
    try jsonlEvent(jctx.alloc, "reasoning", .{ "text", text });
}

fn jsonlOnToolStart(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!void {
    const jctx: *JsonlCtx = @ptrCast(@alignCast(ctx.?));
    try jsonlEvent(jctx.alloc, "tool_start", .{ "name", name, "args", args });
}

fn jsonlOnToolEnd(ctx: ?*anyopaque, name: []const u8, is_error: bool, summary: []const u8) anyerror!void {
    const jctx: *JsonlCtx = @ptrCast(@alignCast(ctx.?));
    try jsonlEvent(jctx.alloc, "tool_end", .{ "name", name, "error", if (is_error) "true" else "false", "summary", summary });
}

fn printResultJson(alloc: std.mem.Allocator, result: ai.RunResult) !void {
    try jstdout(alloc, try resultJsonAlloc(alloc, result));
}

/// 结果 JSON 序列化(供 print -o json 与测试)。
fn resultJsonAlloc(alloc: std.mem.Allocator, result: ai.RunResult) ![]u8 {
    var ww = std.Io.Writer.Allocating.init(alloc);
    defer ww.deinit();
    try ww.writer.writeAll("{\"text\":");
    try ww.writer.writeAll(try util.jsonString(alloc, result.text));
    try ww.writer.writeAll(",\"reasoning\":");
    try ww.writer.writeAll(try util.jsonString(alloc, result.reasoning));
    try ww.writer.writeAll(",\"tool_calls\":[");
    for (result.tool_calls, 0..) |tc, i| {
        if (i > 0) try ww.writer.writeByte(',');
        try ww.writer.print("{{\"id\":{s},\"name\":{s},\"args\":{s}}}", .{
            try util.jsonString(alloc, tc.id),
            try util.jsonString(alloc, tc.name),
            try util.jsonString(alloc, tc.args),
        });
    }
    try ww.writer.writeAll("],\"usage\":{\"input\":");
    if (result.usage.input) |i| try ww.writer.print("{d}", .{i}) else try ww.writer.writeAll("null");
    try ww.writer.writeAll(",\"output\":");
    if (result.usage.output) |o| try ww.writer.print("{d}", .{o}) else try ww.writer.writeAll("null");
    try ww.writer.writeAll(",\"cache_read\":");
    if (result.usage.cache_read) |c| try ww.writer.print("{d}", .{c}) else try ww.writer.writeAll("null");
    try ww.writer.writeAll(",\"cache_write\":");
    if (result.usage.cache_write) |c| try ww.writer.print("{d}", .{c}) else try ww.writer.writeAll("null");
    try ww.writer.writeAll("},\"error\":");
    if (result.error_msg) |m| try ww.writer.writeAll(try util.jsonString(alloc, m)) else try ww.writer.writeAll("null");
    try ww.writer.writeAll("}\n");
    return ww.toOwnedSlice();
}

test "result json serialization" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const j = try resultJsonAlloc(a, .{
        .text = "hi",
        .reasoning = "th",
        .tool_calls = &.{.{ .id = "c1", .name = "bash", .args = "{}" }},
        .usage = .{ .input = 5, .output = 3 },
    });
    try t.expect(std.mem.indexOf(u8, j, "\"text\":\"hi\"") != null);
    try t.expect(std.mem.indexOf(u8, j, "\"name\":\"bash\"") != null);
    try t.expect(std.mem.indexOf(u8, j, "\"input\":5") != null);
    try t.expect(std.mem.indexOf(u8, j, "\"error\":null") != null);
    // error 路径
    const je = try resultJsonAlloc(a, .{ .text = "", .error_msg = "boom" });
    try t.expect(std.mem.indexOf(u8, je, "\"error\":\"boom\"") != null);
}

pub fn runPrint(alloc: std.mem.Allocator, cfg: *cfgmod.Config, cwd: []const u8, prompt: []const u8, opts: RunOptions) !void {
    const abs_cwd = std.process.currentPathAlloc(util.io, alloc) catch cwd;
    var sess = if (opts.session_id) |id| blk: {
        const found = (try sessionmod.Session.findById(alloc, abs_cwd, id)) orelse {
            std.debug.print("piz: session '{s}' not found in {s}\n", .{ id, abs_cwd });
            std.process.exit(1);
        };
        break :blk found;
    } else (try sessionmod.Session.findLatest(alloc, abs_cwd)) orelse (try sessionmod.Session.fresh(alloc, abs_cwd));
    var agent = try agentmod.Agent.initOpts(alloc, cfg, opts.provider_name, opts.model_name, abs_cwd, .{ .read_only = opts.read_only, .system_override = opts.system_override, .depth = pluginsmod.processBaseDepth() });
    if (agent.key == null) {
        std.debug.print("piz: no API key for provider '{s}'. Set ~/.piz/auth.json, models.json apiKey, or env.\n", .{agent.provider.name});
        std.process.exit(1);
    }
    const loaded = try sess.loadMessages();
    try agent.messages.appendSlice(loaded);

    // JS 扩展运行时(与 TUI 同桥):工具/命令/钩子在打印模式同样生效。
    jsrt.init(alloc);
    jsrt.notify_cb = struct {
        fn f(msg: []const u8, level: []const u8) void {
            std.debug.print("piz ext[{s}]: {s}\n", .{ level, msg });
        }
    }.f;
    if (util.configDir(alloc)) |cd| {
        defer alloc.free(cd);
        pluginsmod.pushGates(alloc, pluginsmod.defaultSet());
        jsrt.loadExtensions(cd, abs_cwd);
    } else |_| {}
    if (jsrt.wantsSessionStart()) {
        var ea = util.Arena.init(alloc);
        defer ea.deinit();
        const payload = std.fmt.allocPrint(ea.allocator(), "{{\"cwd\":{s}}}", .{util.jsonString(ea.allocator(), abs_cwd) catch "\"\""}) catch "";
        _ = jsrt.emit(ea.allocator(), "session_start", payload);
    } else {}

    // 输出模式:jsonl 用事件回调,text 用现有回调,json 静默流式
    var jctx = JsonlCtx{ .alloc = alloc };
    if (opts.output_format == .jsonl) {
        agent.cbs = .{
            .ctx = &jctx,
            .on_text = jsonlOnText,
            .on_reasoning = jsonlOnReasoning,
            .on_tool_start = jsonlOnToolStart,
            .on_tool_end = jsonlOnToolEnd,
            .on_notice = jsonlOnNotice,
            .on_subagent = jsonlOnSubagent,
        };
    } else if (opts.output_format == .text) {
        agent.cbs = .{
            .on_text = printOnText,
            .on_reasoning = printOnReasoning,
            .on_tool_start = printOnToolStart,
            .on_tool_end = printOnToolEnd,
            .on_notice = printOnNotice,
            .on_subagent = printOnSubagent,
        };
    }

    var bus = try eventsmod.Bus.init(alloc);
    {
        var ea = util.Arena.init(alloc);
        defer ea.deinit();
        const ealloc = ea.allocator();
        bus.emit("startup", std.fmt.allocPrint(ealloc, "\"cwd\":{s}", .{try util.jsonString(ealloc, abs_cwd)}) catch "");
    }
    const n_before = agent.messages.items.len;
    const result = try agent.send(prompt);
    // 保存增量
    for (agent.messages.items[n_before..]) |*m| try sess.saveMessage(m);
    bus.emit("turn_end", "");

    if (opts.output_format != .text) {
        if (opts.output_format == .jsonl) {
            try jsonlEvent(alloc, "result", .{
                "text",      result.text,
                "reasoning", result.reasoning,
                "error",     result.error_msg orelse "",
            });
        } else {
            try printResultJson(alloc, result);
        }
    }

    if (result.error_msg) |msg| {
        if (opts.output_format == .text) std.debug.print("error: {s}\n", .{msg});
        pluginsmod.shutdownAgents();
        std.process.exit(1);
    }
    // 工具调用摘要(print 模式工具输出已在工具回调中显示到 stderr)
    var sbuf: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(util.io, &sbuf);
    if (result.usage.input) |i| stderr.interface.print("\n[tokens in: {d}]", .{i}) catch |err| util.debugCatch("print.tok.in", err);
    if (result.usage.output) |o| stderr.interface.print(" [out: {d}]", .{o}) catch |err| util.debugCatch("print.tok.out", err);
    stderr.interface.print("\n", .{}) catch |err| util.debugCatch("print.tok.nl", err);
    // 关掉还开着的长驻 subagent。不关就让它们随进程一起没 —— 它们可能正在
    // 写文件,截断出来的半个文件比没写更糟。
    pluginsmod.shutdownAgents();
    std.process.exit(0);
}

/// print 模式的输出锁。
///
/// 长驻 sub-agent 的进度是从 **worker 线程** 经 on_subagent 回调过来的,与父
/// agent 自己的流式正文并发。下面这些回调都往 stdout/stderr 写,不串起来
/// 就会互相撕碎 —— 实测 stdout 收到 `.corrects`、`|*S|---ton` 这种碎片。
///
/// 一把锁覆盖全部回调:粒度粗但正确。这里是人看的输出路径,不在热路径上。
var out_mutex: std.Io.Mutex = .init;

/// 锁内把整块字节直接写到 fd。
///
/// **不用 `File.writer()`**:那要一块 buffer,而 buffer 要么是每次调用新建的
/// 栈数组(fd 上仍然两个线程各自 flush,顺序无保证),要么是进程级共享的
/// (两个线程直接踩同一块内存)。两种都错。
///
/// `writeAll` 直达 fd:内核对单次写有原子性,锁又保证了调用之间不重叠,
/// 两条通道的输出就不会互相插入。
fn writeLocked(file: std.Io.File, bytes: []const u8) void {
    out_mutex.lockUncancelable(util.io);
    defer out_mutex.unlock(util.io);
    file.writeStreamingAll(util.io, bytes) catch |err| util.debugCatch("print.write", err);
}

fn printOnText(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    _ = ctx;
    writeLocked(std.Io.File.stdout(), text);
}

fn printOnReasoning(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    _ = ctx;
    // 栈缓冲 + 一次成型:格式化在锁外做,锁内只有一次 writeAll。
    // 推理文本逐 token 到达,可能超过缓冲 —— 那就分块写,每块自身完整。
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\x1b[2m{s}\x1b[0m", .{text}) catch {
        // 太长装不下:直接原样写,丢掉暗色包装而不是丢内容
        writeLocked(std.Io.File.stderr(), text);
        return;
    };
    writeLocked(std.Io.File.stderr(), s);
}

fn printOnToolStart(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror!void {
    _ = ctx;
    var buf: [512]u8 = undefined;
    // clampUtf8:args 截断在多字节序列中间会在终端上产出乱码方块
    const clipped = util.clampUtf8(args, 200);
    const s = std.fmt.bufPrint(&buf, "\n\x1b[2m  {s} {s}\x1b[0m\n", .{ name, clipped }) catch return;
    writeLocked(std.Io.File.stderr(), s);
}

fn printOnToolEnd(ctx: ?*anyopaque, name: []const u8, is_error: bool, summary: []const u8) anyerror!void {
    _ = ctx;
    // 带上输出规模:print 模式下工具产出全进了模型上下文,用户一个字看不到,
    // 至少让他知道「这一步吐了 12KB」而不是完全无从判断。
    var bb: [24]u8 = undefined;
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\x1b[{s}m{s} {s}\x1b[0m \x1b[2m{s}\x1b[0m\n", .{
        if (is_error) "31" else "2",
        if (is_error) "err" else "ok",
        name,
        activity.formatBytes(&bb, summary.len),
    }) catch return;
    writeLocked(std.Io.File.stderr(), s);
}

/// 引擎级告知走 stderr:stdout 是给管道下游的答复正文,不能混进这些。
fn printOnNotice(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    _ = ctx;
    var buf: [640]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\x1b[2m  piz  {s}\x1b[0m\n", .{util.clampUtf8(text, 512)}) catch return;
    writeLocked(std.Io.File.stderr(), s);
}

fn jsonlOnNotice(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const jctx: *JsonlCtx = @ptrCast(@alignCast(ctx.?));
    try jsonlEvent(jctx.alloc, "notice", .{ "text", text });
}

/// subagent 中间事件 → stderr 一行。
///
/// 只显示「谁在做什么」不显示内容:32 路并行的正文混在一起没人读得懂,
/// 而「3 号在跑 grep」是真正有用的进度信息。
fn printOnSubagent(ctx: ?*anyopaque, idx: usize, kind: agentmod.SubagentEvent, text: []const u8) anyerror!void {
    _ = ctx;
    // 正文与推理逐 token 到达,一路一行都印会把终端刷爆 —— 只报动作与结束
    switch (kind) {
        .text, .reasoning => return,
        else => {},
    }
    const tag = switch (kind) {
        .tool_start => "tool",
        .tool_done => "ok",
        .tool_failed => "err",
        .notice => "piz",
        .finished => "done",
        else => "-",
    };
    // clampUtf8 而非裸切片:切在多字节序列中间会产出坏字节
    const clipped = util.clampUtf8(text, 120);
    var line: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&line, "\x1b[2m[sub {d}]\x1b[0m {s} {s}\n", .{ idx, tag, clipped }) catch return;
    writeLocked(std.Io.File.stderr(), s);
}

fn jsonlOnSubagent(ctx: ?*anyopaque, idx: usize, kind: agentmod.SubagentEvent, text: []const u8) anyerror!void {
    const jctx: *JsonlCtx = @ptrCast(@alignCast(ctx.?));
    var nb: [24]u8 = undefined;
    const idx_str = std.fmt.bufPrint(&nb, "{d}", .{idx}) catch "0";
    try jsonlEvent(jctx.alloc, "subagent", .{ "task", idx_str, "kind", @tagName(kind), "text", text });
}

test "concurrent print callbacks never interleave a line" {
    const t = std.testing;
    try util.testInit();

    // 长驻 sub-agent 的进度来自 worker 线程,与父 agent 的流式正文并发。
    // 实测症状:stdout 收到 `.corrects`、`|*S|---ton` 这种碎片 —— 两条通道
    // 的字节互相插进对方中间。这里把 writeLocked 顶到同样的并发下,验证
    // 每一次写都完整落地。
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = "concur_out.txt";
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = path, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(util.io, path) catch {};

    var file = try std.Io.Dir.cwd().openFile(util.io, path, .{ .mode = .write_only });
    defer file.close(util.io);

    const Writer = struct {
        f: std.Io.File,
        tag: u8,
        fn run(self: @This()) void {
            var line: [64]u8 = undefined;
            for (0..200) |_| {
                // 每行同一个字符重复 —— 交错会立刻显形为混合字符的行
                @memset(line[0 .. line.len - 1], self.tag);
                line[line.len - 1] = '\n';
                writeLocked(self.f, &line);
            }
        }
    };

    // 三条线程模拟:父 agent 正文 + 两个 subagent 的进度
    var threads: [3]std.Thread = undefined;
    const tags = [_]u8{ 'A', 'B', 'C' };
    for (&threads, tags) |*th, tag| {
        th.* = try std.Thread.spawn(.{}, Writer.run, .{Writer{ .f = file, .tag = tag }});
    }
    for (&threads) |th| th.join();

    const content = try std.Io.Dir.cwd().readFileAlloc(util.io, path, t.allocator, .limited(1 << 20));
    defer t.allocator.free(content);

    var lines: usize = 0;
    var it = std.mem.tokenizeScalar(u8, content, '\n');
    while (it.next()) |line| {
        lines += 1;
        // 每行必须是单一字符重复 —— 混了别的 tag 就是被插进来了
        try t.expectEqual(@as(usize, 63), line.len);
        for (line) |c| try t.expectEqual(line[0], c);
    }
    try t.expectEqual(@as(usize, 600), lines);
}

/// 重建 -a 子进程 argv:去掉 -a/--async,在 `--` 之前插入 -s <id> -n -c。
///
/// `-s` 等必须插在 `--` **之前**:`--` 之后全是字面量,追加到尾部会被
/// 当成提示词的一部分 —— 实测子进程收到的提示词变成
/// `ASYNC-OK -s 1786375593575 -n -c`,会话选项则完全没生效。
fn rebuildAsyncArgv(alloc: std.mem.Allocator, orig_args: []const []const u8, id: []const u8) !std.array_list.Managed([]const u8) {
    var argv = std.array_list.Managed([]const u8).init(alloc);
    errdefer argv.deinit();
    var tail = std.array_list.Managed([]const u8).init(alloc);
    defer tail.deinit();
    var after_dashdash = false;
    for (orig_args) |a| {
        if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "--async")) continue;
        if (after_dashdash) {
            try tail.append(a);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            after_dashdash = true;
            continue;
        }
        try argv.append(a);
    }
    try argv.append("-s");
    try argv.append(id);
    try argv.append("-n");
    try argv.append("-c"); // -s 优先于 -n;-c 覆盖前序 -n(防御)
    if (tail.items.len > 0) {
        try argv.append("--");
        try argv.appendSlice(tail.items);
    }
    return argv;
}

test "async argv inserts session flags before dashdash" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    var argv = try rebuildAsyncArgv(arena.allocator(), &.{ "piz", "-p", "-a", "--", "-rf" }, "42");
    defer argv.deinit();
    try t.expectEqual(@as(usize, 8), argv.items.len);
    try t.expectEqualStrings("piz", argv.items[0]);
    try t.expectEqualStrings("-p", argv.items[1]);
    try t.expectEqualStrings("-s", argv.items[2]);
    try t.expectEqualStrings("42", argv.items[3]);
    try t.expectEqualStrings("-n", argv.items[4]);
    try t.expectEqualStrings("-c", argv.items[5]);
    try t.expectEqualStrings("--", argv.items[6]);
    try t.expectEqualStrings("-rf", argv.items[7]);
}

/// -a 异步:建新会话 → spawn 自身(去 -a,加 -s <id> -n) → 立即返回。
pub fn runAsync(alloc: std.mem.Allocator, cwd: []const u8, prompt: []const u8, orig_args: []const []const u8) !void {
    if (prompt.len == 0) {
        std.debug.print("piz: -a requires a prompt (argument or -i file)\n", .{});
        std.process.exit(1);
    }
    const abs_cwd = std.process.currentPathAlloc(util.io, alloc) catch cwd;
    const sess = try sessionmod.Session.fresh(alloc, abs_cwd);
    const base = std.fs.path.basename(sess.path);
    const id = base[0 .. base.len - ".jsonl".len];

    // 日志:<configDir>/logs/piz-<id>.log
    const cfg_dir = try util.configDir(alloc);
    const logs_dir = try util.joinPath(alloc, cfg_dir, "logs");
    std.Io.Dir.cwd().createDirPath(util.io, logs_dir) catch |err| util.debugCatch("print.logs", err);
    const log_path = try std.fmt.allocPrint(alloc, "{s}/piz-{s}.log", .{ logs_dir, id });
    var logf = try std.Io.Dir.cwd().createFile(util.io, log_path, .{ .truncate = true, .permissions = @enumFromInt(0o600) });
    defer logf.close(util.io);

    var argv = try rebuildAsyncArgv(alloc, orig_args, id);
    defer argv.deinit();

    const child = try std.process.spawn(util.io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .{ .file = logf },
        .stderr = .{ .file = logf },
        .pgid = 0, // 新进程组,脱离终端信号
        .expand_arg0 = .expand,
    });
    _ = child;
    std.debug.print("async: session {s} started — resume with: piz -s {s} -p \"...\"\nlog: {s}\n", .{ id, id, log_path });
    std.process.exit(0);
}
