// mcp.zig — Model Context Protocol 客户端(stdio 传输)。
//
// 支持:spawn 子进程 MCP server、JSON-RPC 2.0(initialize/tools/list/
// tools/call)、换行分隔帧、同步请求-响应(工具线程内阻塞,带读超时)。
// 不做:SSE/streamable-http 传输、resources/prompts、server 热重载。
//
// 工具命名:mcp__<server>__<tool> —— 避免与内置工具冲突,且一眼可辨来源。
// 并发模型:每个 server 一把互斥锁串行化 call(工具并行线程可能同时打到
// 同一 server;JSON-RPC 请求-响应配对要求串行)。
const std = @import("std");
const util = @import("util.zig");
const toolsmod = @import("tools.zig");
const activity = @import("activity.zig");

/// settings.json 的 mcpServers 项。
pub const ServerConfig = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
};

/// 单个 server 的运行态。
pub const Server = struct {
    cfg: ServerConfig,
    child: ?std.process.Child = null,
    stdin: ?std.Io.File = null,
    stdout: ?std.Io.File = null,
    next_id: u64 = 1,
    /// 串行化 request/response(工具并行线程共用)
    mutex: std.Io.Mutex = .init,
    tools: std.array_list.Managed(Tool) = undefined,
    alive: bool = false,
    /// 启动失败原因(展示用)
    error_msg: []const u8 = "",
};

pub const Tool = struct {
    name: []const u8,
    desc: []const u8,
    /// inputSchema 的 JSON 文本(JSON Schema)
    schema: []const u8,
};

/// 进程级 server 表。启动时填充一次,常驻到进程退出。
pub var servers: std.array_list.Managed(*Server) = undefined;
var servers_inited = false;

/// 确保 server 表就绪(幂等)。start 与测试都经此初始化。
pub fn ensureInit(alloc: std.mem.Allocator) void {
    if (!servers_inited) {
        servers = std.array_list.Managed(*Server).init(alloc);
        servers_inited = true;
    }
}

/// 启动全部配置的 server(进程启动时调一次)。失败的不阻塞:server 记录
/// error_msg,工具调用时报错,其余正常。
pub fn startAll(alloc: std.mem.Allocator, cfgs: []const ServerConfig) !void {
    ensureInit(alloc);
    for (cfgs) |cfg| {
        _ = start(alloc, cfg) catch continue;
    }
}

/// 工具定义列表(agent 组装 tool_defs 时追加)。
pub fn toolDefs(alloc: std.mem.Allocator) !std.array_list.Managed(toolsmod.Tool) {
    var out = std.array_list.Managed(toolsmod.Tool).init(alloc);
    if (!servers_inited) return out;
    for (servers.items) |srv| {
        if (!srv.alive) continue;
        for (srv.tools.items) |t| {
            const full_name = try std.fmt.allocPrint(alloc, "mcp__{s}__{s}", .{ srv.cfg.name, t.name });
            try out.append(.{
                .name = full_name,
                .desc = t.desc,
                .schema = t.schema,
                .handler = stubHandler,
            });
        }
    }
    return out;
}

fn stubHandler(_: std.mem.Allocator, _: []const u8) anyerror!toolsmod.Result {
    return .{ .content = "internal: dispatched through the mcp layer", .is_error = true };
}

/// 工具名是否 mcp 前缀。
pub fn isMcpTool(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "mcp__");
}

/// 拆 mcp__<server>__<tool>。server / tool 名可含单下划线,以第一个 __ 为界。
pub fn parseToolName(name: []const u8) ?struct { server: []const u8, tool: []const u8 } {
    if (!std.mem.startsWith(u8, name, "mcp__")) return null;
    const rest = name["mcp__".len..];
    const sep = std.mem.indexOf(u8, rest, "__") orelse return null;
    if (sep == 0 or sep + 2 >= rest.len) return null;
    return .{ .server = rest[0..sep], .tool = rest[sep + 2 ..] };
}

/// 执行 MCP 工具调用(工具线程内;全程持 server 锁)。
pub fn callTool(alloc: std.mem.Allocator, tool_name: []const u8, args_json: []const u8) !toolsmod.Result {
    if (!servers_inited) return .{ .content = "error: no mcp servers configured", .is_error = true };
    const parts = parseToolName(tool_name) orelse
        return .{ .content = "error: malformed mcp tool name", .is_error = true };
    const srv = findServer(parts.server) orelse
        return .{ .content = try std.fmt.allocPrint(alloc, "error: mcp server '{s}' not running", .{parts.server}), .is_error = true };
    return callServer(srv, alloc, parts.tool, args_json);
}

fn findServer(name: []const u8) ?*Server {
    if (!servers_inited) return null;
    for (servers.items) |s| {
        if (std.mem.eql(u8, s.cfg.name, name)) return s;
    }
    return null;
}

// ---------------------------------------------------------------------------
// 帧读写
// ---------------------------------------------------------------------------

const READ_TIMEOUT_MS = 30_000;

/// 读一行(带 poll 超时)。返回的字节含换行符(已分配,调用方 free)。
fn readLine(alloc: std.mem.Allocator, file: std.Io.File, timeout_ms: u32, act: activity.Handle) !?[]const u8 {
    // 不用 File.Reader:其内部缓冲与 readSliceShort 目标若重叠,或 readVec
    // 试图填满整块 dest,管道上会永久阻塞(超时循环进不去)。与 bash 同策:
    // poll(100ms) + posix.read 只取已到字节。
    var pfds = [_]std.posix.pollfd{.{ .fd = file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    var buf = std.array_list.Managed(u8).init(alloc);
    errdefer buf.deinit();
    var tmp: [4096]u8 = undefined;
    const t0 = std.Io.Clock.now(.awake, util.io).nanoseconds;
    while (true) {
        if (act.cancelled()) return error.Canceled;
        const elapsed: u32 = @intCast(@divTrunc(std.Io.Clock.now(.awake, util.io).nanoseconds - t0, std.time.ns_per_ms));
        if (elapsed >= timeout_ms) {
            if (buf.items.len == 0) return null;
            break;
        }
        pfds[0].revents = 0;
        const remain = @min(timeout_ms - elapsed, 100);
        const rc = std.posix.poll(&pfds, remain) catch return error.ReadTimeout;
        if (rc == 0) continue;
        const n = std.posix.read(file.handle, &tmp) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) {
            if (buf.items.len == 0) return null; // EOF
            break;
        }
        try buf.appendSlice(tmp[0..n]);
        if (std.mem.indexOfScalar(u8, buf.items, '\n') != null) break;
    }
    return try buf.toOwnedSlice();
}

fn writeLine(file: std.Io.File, data: []const u8) !void {
    _ = std.os.linux.write(file.handle, data.ptr, data.len);
    _ = std.os.linux.write(file.handle, "\n", 1);
}

/// 同步往返:发请求,读响应(跳过 notification)。
fn roundTrip(alloc: std.mem.Allocator, self: *Server, method: []const u8, params: ?[]const u8, act: activity.Handle) !std.json.Value {
    const id = self.next_id;
    self.next_id += 1;
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try aw.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\"", .{ id, method });
    if (params) |p| {
        try aw.writer.print(",\"params\":{s}", .{p});
    }
    try aw.writer.writeAll("}");
    try writeLine(self.stdin.?, aw.written());

    while (true) {
        const line = (try readLine(alloc, self.stdout.?, READ_TIMEOUT_MS, act)) orelse return error.NoResponse;
        defer alloc.free(line);
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        const msg = std.json.parseFromSliceLeaky(std.json.Value, alloc, trimmed, .{}) catch continue;
        if (msg != .object) continue;
        // notification:无 id,跳过(如日志/进度通知)
        if (msg.object.get("id") == null) continue;
        const mid = msg.object.get("id").?;
        if (mid == .integer and mid.integer == id) return msg;
        if (mid == .number_string) {
            // 部分 server 回字符串 id —— 我们只发整数 id,不匹配就跳过
        }
    }
}

// ---------------------------------------------------------------------------
// 启动 / 工具发现 / 调用
// ---------------------------------------------------------------------------

/// 启动一个 server:spawn + initialize + tools/list。失败返回 null 并留 error_msg。
pub fn start(alloc: std.mem.Allocator, cfg: ServerConfig) !*Server {
    const srv = try alloc.create(Server);
    srv.* = .{ .cfg = cfg };
    errdefer alloc.destroy(srv);

    var argv = try alloc.alloc([]const u8, 1 + cfg.args.len);
    argv[0] = cfg.command;
    @memcpy(argv[1..], cfg.args);

    const child = std.process.spawn(util.io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch {
        srv.error_msg = try std.fmt.allocPrint(alloc, "cannot spawn '{s}'", .{cfg.command});
        try servers.append(srv);
        return srv;
    };
    srv.child = child;
    srv.stdin = child.stdin;
    srv.stdout = child.stdout;

    // initialize
    const init_params =
        \\{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"piz","version":"0.1.0"}}
    ;
    const init_act = activity.begin(.tool, "mcp_initialize", cfg.name, READ_TIMEOUT_MS);
    defer init_act.release();
    const init_resp = roundTrip(alloc, srv, "initialize", init_params, init_act) catch |e| {
        srv.error_msg = try std.fmt.allocPrint(alloc, "initialize failed: {s}", .{@errorName(e)});
        try servers.append(srv);
        return srv;
    };
    _ = init_resp;
    // initialized 通知(无 id)
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try aw.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    writeLine(srv.stdin.?, aw.written()) catch {};

    // tools/list
    const list_act = activity.begin(.tool, "mcp_tools_list", cfg.name, READ_TIMEOUT_MS);
    defer list_act.release();
    const list_resp = roundTrip(alloc, srv, "tools/list", null, list_act) catch |e| {
        srv.error_msg = try std.fmt.allocPrint(alloc, "tools/list failed: {s}", .{@errorName(e)});
        try servers.append(srv);
        return srv;
    };
    srv.tools = std.array_list.Managed(Tool).init(alloc);
    if (list_resp.object.get("result")) |r| {
        if (r == .object) {
            if (r.object.get("tools")) |ts| {
                if (ts == .array) {
                    for (ts.array.items) |t| {
                        if (t != .object) continue;
                        const tname = if (t.object.get("name")) |n| (if (n == .string) n.string else "") else "";
                        if (tname.len == 0) continue;
                        const tdesc = if (t.object.get("description")) |d| (if (d == .string) d.string else "") else "";
                        // inputSchema → JSON 文本(空 schema 给 {})
                        var sw = std.Io.Writer.Allocating.init(alloc);
                        defer sw.deinit();
                        if (t.object.get("inputSchema")) |sch| {
                            try std.json.Stringify.value(sch, .{}, &sw.writer);
                        } else {
                            try sw.writer.writeAll("{\"type\":\"object\"}");
                        }
                        try srv.tools.append(.{
                            .name = try alloc.dupe(u8, tname),
                            .desc = try alloc.dupe(u8, tdesc),
                            .schema = try sw.toOwnedSlice(),
                        });
                    }
                }
            }
        }
    }
    srv.alive = true;
    try servers.append(srv);
    return srv;
}

/// 调用工具:持锁串行,读超时返回错误。
pub fn callServer(self: *Server, alloc: std.mem.Allocator, tool_name: []const u8, args_json: []const u8) !toolsmod.Result {
    if (!self.alive) return .{ .content = try std.fmt.allocPrint(alloc, "error: mcp server '{s}' is not running: {s}", .{ self.cfg.name, self.error_msg }), .is_error = true };
    // tryLock:不排队 —— 工具并行线程打到同一 server 时,后者立即报 busy
    // (排队会让一个慢 server 卡住整批工具,与「不阻塞」的原则相悖)。
    if (!self.mutex.tryLock()) return .{ .content = try std.fmt.allocPrint(alloc, "error: mcp server '{s}' is busy with another call", .{self.cfg.name}), .is_error = true };
    defer self.mutex.unlock(util.io);

    // 本轮调用的活动:interrupt 经它取消等待(与 bash 工具同策)
    const act = activity.begin(.tool, "mcp_call", tool_name, READ_TIMEOUT_MS);
    defer act.release();

    // arguments 是 JSON 字符串(模型产出);非法 JSON 退化为空对象
    const arg_obj = std.json.parseFromSliceLeaky(std.json.Value, alloc, args_json, .{}) catch null;
    const params = try std.fmt.allocPrint(alloc, "{{\"name\":{s},\"arguments\":{s}}}", .{
        try util.jsonString(alloc, tool_name),
        if (arg_obj != null) args_json else "{}",
    });
    const resp = roundTrip(alloc, self, "tools/call", params, act) catch |e| {
        return .{ .content = try std.fmt.allocPrint(alloc, "error: mcp call failed: {s}", .{@errorName(e)}), .is_error = true };
    };
    if (resp.object.get("error")) |e| {
        if (e == .object) {
            if (e.object.get("message")) |m| {
                if (m == .string) return .{ .content = try std.fmt.allocPrint(alloc, "error: mcp server: {s}", .{m.string}), .is_error = true };
            }
        }
        return .{ .content = "error: mcp server returned an error", .is_error = true };
    }
    const result = resp.object.get("result") orelse
        return .{ .content = "error: mcp call returned no result", .is_error = true };
    if (result != .object) return .{ .content = "error: mcp call result malformed", .is_error = true };
    const is_err = if (result.object.get("isError")) |ie| (ie == .bool and ie.bool) else false;
    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();
    if (result.object.get("content")) |content| {
        if (content == .array) {
            for (content.array.items) |item| {
                if (item != .object) continue;
                const it_t = if (item.object.get("type")) |t| (if (t == .string) t.string else "") else "";
                if (std.mem.eql(u8, it_t, "text")) {
                    if (item.object.get("text")) |tx| {
                        if (tx == .string) try out.writer.writeAll(tx.string);
                    }
                } else {
                    // image/resource 等:给占位说明
                    try out.writer.print("[{s} content]", .{it_t});
                }
            }
        }
    }
    // 结构化输出(部分 server 用 structuredContent)
    if (result.object.get("structuredContent")) |sc| {
        if (out.written().len == 0) {
            try std.json.Stringify.value(sc, .{}, &out.writer);
        }
    }
    const text = if (out.written().len > 0) try out.toOwnedSlice() else "(no content)";
    return .{ .content = text, .is_error = is_err };
}

/// 关闭全部 server(进程退出前)。
pub fn stopAll() void {
    if (!servers_inited) return;
    for (servers.items) |srv| {
        if (srv.child) |c| {
            var cc = c;
            // kill 内部 childCleanupPosix 会关 stdin/stdout 并 wait。
            // 不可先手动 close —— Debug 下二次 close 触发 EBADF unreachable。
            cc.kill(util.io);
            srv.child = null;
        }
        srv.stdin = null;
        srv.stdout = null;
    }
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

pub fn runScriptServerTest(t: anytype) !void {
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 用 python3 -u 模拟 MCP server(无缓冲 stdout:bash 的 echo 对管道全缓冲,
    // 会卡在客户端读侧;真实 server 均行缓冲)。
    const script =
        \\import sys, json
        \\for line in sys.stdin:
        \\    line = line.strip()
        \\    if "initialize" in line:
        \\        print(json.dumps({"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"t","version":"1"}}}), flush=True)
        \\    elif "tools/list" in line:
        \\        print(json.dumps({"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","description":"Echo back","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}]}}), flush=True)
        \\    elif "tools/call" in line:
        \\        print(json.dumps({"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"ECHO-OUT"}]}}), flush=True)
        \\    else:
        \\        print("{}", flush=True)
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(util.io, .{ .sub_path = "mcp-test.py", .data = script });
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const sh_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}/mcp-test.py", .{ cwd_abs, tmp.sub_path });

    ensureInit(a);
    defer {
        stopAll();
        servers.deinit();
        servers_inited = false;
    }
    const srv = try start(a, .{ .name = "test", .command = "python3", .args = &.{ "-u", sh_path } });
    try t.expect(srv.alive);
    try t.expectEqual(@as(usize, 1), srv.tools.items.len);
    try t.expectEqualStrings("echo", srv.tools.items[0].name);
    try t.expect(std.mem.indexOf(u8, srv.tools.items[0].schema, "\"text\"") != null);

    // 工具定义带前缀
    var defs = try toolDefs(a);
    defer defs.deinit();
    try t.expectEqualStrings("mcp__test__echo", defs.items[0].name);

    // 执行
    const res = try callTool(a, "mcp__test__echo", "{\"text\":\"hi\"}");
    try t.expect(std.mem.indexOf(u8, res.content, "ECHO-OUT") != null);
}

// (callServer 被 callTool 直接引用;曾在此放 comptime 强制引用块,
// 实测让 zig 0.16 sema 挂死,移除。)
