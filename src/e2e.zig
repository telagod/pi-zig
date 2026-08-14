// e2e.zig — 端到端测试:内嵌 mock OpenAI provider,全链路验证
// 提示词 → 流式 → tool_call → 工具执行 → 第二轮 → 最终答。
const std = @import("std");
const util = @import("core").util;
const cfgmod = @import("core").config;
const agentmod = @import("core").agent;
const pluginsmod = @import("core").plugins;
const ai = @import("core").ai;
const toolsmod = @import("core").tools;
const activity = @import("core").activity;
const httpc = @import("core").httpc;
const mcpmod = @import("core").mcp;

const MOCK_PORT: u16 = 18521;
const MOCK_PORT2: u16 = 18522;
const MOCK_PORT3: u16 = 18523;
const MOCK_PORT4: u16 = 18524;

const MockState = struct {
    alloc: std.mem.Allocator,
    port: u16 = MOCK_PORT,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    requests: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    req2_had_tool: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    req3_no_tools: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    req5_had_declined: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 视觉 e2e:第二轮请求体里是否带 image_url 附件
    req_had_image: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 视觉 e2e:请求里 image block 是否带 data: 前缀与 base64 数据
    req_image_data_ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 视觉模式:第一轮回 read_image 工具调用
    vision_mode: bool = false,
    /// Responses API 模式:第一轮回 function_call 事件流
    responses_mode: bool = false,
    /// Responses e2e:请求体是否 input items 语义(非 messages 数组)
    responses_input_ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Responses e2e:第二轮请求是否带 function_call_output
    responses_call_output_ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    req6_was_compact: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 请求体里 tools 是否排在 messages 之前(缓存前缀稳定性:静态部分在前)
    tools_before_messages: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn sseEvent(alloc: std.mem.Allocator, data_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "data: {s}\n\n", .{data_json});
}

fn mockServerMain(state: *MockState) void {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", state.port) catch return;
    var server = addr.listen(util.io, .{ .reuse_address = true }) catch return;
    defer server.deinit(util.io);
    util.setNonBlock(server.socket.handle);

    // poll 轮询可读 + 系统 accept4(Threaded 的 netAccept 视 EAGAIN 为 bug,
    // 非阻塞 fd 只能绕过 vtable 直调 syscall;负返回值即 -errno)
    var pfds = [_]std.posix.pollfd{.{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    while (!state.stop.load(.acquire)) {
        const n = std.posix.poll(&pfds, 10) catch continue;
        if (n == 0) continue;
        const raw = std.os.linux.accept4(server.socket.handle, null, null, 0o2000000); // SOCK_CLOEXEC
        const rc = @as(isize, @bitCast(raw));
        if (rc < 0) continue;
        var conn = std.Io.net.Stream{ .socket = .{ .handle = @intCast(rc), .address = undefined } };
        defer conn.close(util.io);
        _ = handleRequest(state, &conn) catch {};
    }
}

fn handleRequest(state: *MockState, conn: *std.Io.net.Stream) !void {
    const alloc = state.alloc;
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var fin = conn.reader(util.io, &rbuf);
    var fout = conn.writer(util.io, &wbuf);
    var server = std.http.Server.init(&fin.interface, &fout.interface);
    var req = try server.receiveHead();
    var tbuf: [8192]u8 = undefined;
    const reader = try req.readerExpectContinue(&tbuf);
    const body = try reader.allocRemaining(alloc, .limited(4 * 1024 * 1024));
    defer alloc.free(body);
    const req_no = state.requests.fetchAdd(1, .monotonic) + 1;

    // 统一入口:任何请求带压缩指令即标记并回摘要(压缩可能发生在任意轮次——首轮 85% 即触发)
    var resp: []u8 = undefined;
    // 缓存前缀稳定性:tools(每轮不变)必须排在 messages(每轮追加)之前。
    // 在真实请求路径上验证,比只测序列化函数更实在。
    if (std.mem.indexOf(u8, body, "\"tools\":[")) |it| {
        if (std.mem.indexOf(u8, body, "\"messages\":[")) |im| {
            if (it < im) state.tools_before_messages.store(true, .release);
        }
    }
    if (std.mem.indexOf(u8, body, "Compress the conversation") != null) {
        state.req6_was_compact.store(true, .release);
        var buf = std.array_list.Managed(u8).init(alloc);
        defer buf.deinit();
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{\"content\":\"summarized.\"},\"finish_reason\":null}]}"));
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}"));
        try buf.appendSlice("data: [DONE]\n\n");
        resp = try buf.toOwnedSlice();
    } else if (std.mem.indexOf(u8, body, "data:image/") != null and std.mem.indexOf(u8, body, "base64,") != null) {
        // 视觉 e2e:请求体带图(openai 协议 image_url data URI)。
        state.req_had_image.store(true, .release);
        if (std.mem.indexOf(u8, body, "\"image_url\"") != null) {
            state.req_image_data_ok.store(true, .release);
        }
        var buf = std.array_list.Managed(u8).init(alloc);
        defer buf.deinit();
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{\"content\":\"IMG-OK\"},\"finish_reason\":null}]}"));
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1}}"));
        try buf.appendSlice("data: [DONE]\n\n");
        resp = try buf.toOwnedSlice();
    } else if (state.responses_mode) {
        if (req_no == 1) {
            // 请求体语义检查:Responses 用 input/instructions 而非 messages
            if (std.mem.indexOf(u8, body, "\"input\":[") != null and std.mem.indexOf(u8, body, "\"instructions\":") != null) {
                state.responses_input_ok.store(true, .release);
            }
            var buf = std.array_list.Managed(u8).init(alloc);
            defer buf.deinit();
            try buf.appendSlice(try sseEvent(alloc, "{\"type\":\"response.created\",\"response\":{}}"));
            try buf.appendSlice(try sseEvent(alloc, "{\"type\":\"response.output_text.delta\",\"delta\":\"Let me run \"}"));
            try buf.appendSlice(try sseEvent(alloc, "{\"type\":\"response.output_text.delta\",\"delta\":\"a command.\"}"));
            try buf.appendSlice(try sseEvent(alloc, "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"call_id\":\"fc_1\",\"name\":\"bash\"}}"));
            try buf.appendSlice(try sseEvent(alloc, "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\\\"command\\\":\\\"echo resp-marker\\\"}\"}"));
            try buf.appendSlice(try sseEvent(alloc, "{\"type\":\"response.function_call_arguments.done\",\"arguments\":\"{\\\"command\\\":\\\"echo resp-marker\\\"}\"}"));
            try buf.appendSlice(try sseEvent(alloc, "{\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":100,\"output_tokens\":10,\"input_tokens_details\":{\"cached_tokens\":90}}}}"));
            try buf.appendSlice("data: [DONE]\n\n");
            resp = try buf.toOwnedSlice();
        } else {
            if (std.mem.indexOf(u8, body, "\"function_call_output\"") != null and std.mem.indexOf(u8, body, "resp-marker") != null) {
                state.responses_call_output_ok.store(true, .release);
            }
            var buf = std.array_list.Managed(u8).init(alloc);
            defer buf.deinit();
            try buf.appendSlice(try sseEvent(alloc, "{\"type\":\"response.output_text.delta\",\"delta\":\"RESP-OK\"}"));
            try buf.appendSlice(try sseEvent(alloc, "{\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":50,\"output_tokens\":5}}}"));
            try buf.appendSlice("data: [DONE]\n\n");
            resp = try buf.toOwnedSlice();
        }
    } else if (state.vision_mode and req_no == 1) {
        // 视觉 e2e 第一轮:read_image 工具调用(路径由测试写好)
        var buf = std.array_list.Managed(u8).init(alloc);
        defer buf.deinit();
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{\"content\":\"Let me look. \"},\"finish_reason\":null}]}"));
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_img1\",\"function\":{\"name\":\"read_image\",\"arguments\":\"\"}}]},\"finish_reason\":null}]}"));
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"path\\\":\\\"/tmp/piz-img-e2e.png\\\"}\"}}]},\"finish_reason\":null}]}"));
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5}}"));
        try buf.appendSlice("data: [DONE]\n\n");
        resp = try buf.toOwnedSlice();
    } else if (req_no == 1) {
        // 第一轮:文本 + bash 工具调用
        var buf = std.array_list.Managed(u8).init(alloc);
        defer buf.deinit();
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{\"content\":\"Let me check. \"},\"finish_reason\":null}]}"));
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"bash\",\"arguments\":\"\"}}]},\"finish_reason\":null}]}"));
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"command\\\":\\\"echo piz-e2e-marker\\\"}\"}}]},\"finish_reason\":null}]}"));
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5}}"));
        try buf.appendSlice("data: [DONE]\n\n");
        resp = try buf.toOwnedSlice();
    } else if (req_no == 3) {
        // 第三轮:read-only 请求,应无 tools 字段
        if (std.mem.indexOf(u8, body, "\"tools\"") == null) {
            state.req3_no_tools.store(true, .release);
        }
        var buf = std.array_list.Managed(u8).init(alloc);
        defer buf.deinit();
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{\"content\":\"RO-OK \"},\"finish_reason\":null}]}"));
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1}}"));
        try buf.appendSlice("data: [DONE]\n\n");
        resp = try buf.toOwnedSlice();
    } else if (req_no == 4) {
        // 第四轮:返回工具调用,验证权限拒绝路径
        var buf = std.array_list.Managed(u8).init(alloc);
        defer buf.deinit();
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_4\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"echo piz-e2e-marker\\\"}\"}}]},\"finish_reason\":null}]}"));
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}"));
        try buf.appendSlice("data: [DONE]\n\n");
        resp = try buf.toOwnedSlice();
    } else if (req_no == 5) {
        // 第五轮:检查 declined 消息,回最终答
        if (std.mem.indexOf(u8, body, "declined") != null) {
            state.req5_had_declined.store(true, .release);
        }
        var buf = std.array_list.Managed(u8).init(alloc);
        defer buf.deinit();
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{\"content\":\"DENY-OK\"},\"finish_reason\":null}]}"));
        // usage:40000 token、缓存命中 0 → 命中率 0% < 30% 且 > 窗口 15%(默认 128K)→ 下一轮触发缓存感知压缩
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":40000,\"completion_tokens\":100,\"prompt_cache_hit_tokens\":0}}"));
        try buf.appendSlice("data: [DONE]\n\n");
        resp = try buf.toOwnedSlice();
    } else if (req_no == 6) {
        // 第六轮:自动 compaction 的总结请求
        if (std.mem.indexOf(u8, body, "Compress the conversation") != null) {
            state.req6_was_compact.store(true, .release);
        }
        var buf = std.array_list.Managed(u8).init(alloc);
        defer buf.deinit();
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{\"content\":\"summarized.\"},\"finish_reason\":null}]}"));
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"));
        try buf.appendSlice("data: [DONE]\n\n");
        resp = try buf.toOwnedSlice();
    } else if (req_no == 7) {
        // 第七轮:compact 后的正常请求
        var buf = std.array_list.Managed(u8).init(alloc);
        defer buf.deinit();
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{\"content\":\"COMPACT-OK\"},\"finish_reason\":null}]}"));
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"));
        try buf.appendSlice("data: [DONE]\n\n");
        resp = try buf.toOwnedSlice();
    } else {
        // 第二轮:检查 tool 消息,回最终答案
        if (std.mem.indexOf(u8, body, "\"role\":\"tool\"") != null) {
            state.req2_had_tool.store(true, .release);
        }
        var buf = std.array_list.Managed(u8).init(alloc);
        defer buf.deinit();
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{\"content\":\"E2E-OK \"},\"finish_reason\":null}]}"));
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{\"content\":\"tool worked\"},\"finish_reason\":null}]}"));
        try buf.appendSlice(try sseEvent(alloc, "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":8}}"));
        try buf.appendSlice("data: [DONE]\n\n");
        resp = try buf.toOwnedSlice();
    }
    defer alloc.free(resp);
    try req.respond(resp, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
        .keep_alive = false,
    });
}

/// 完整链路:e2e 测试。
/// 记忆管线端到端:压缩摘要 → 写入 memories/*.md → 新会话注入 system_prompt(幂等)。
pub fn testMemoryPipeline() !void {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 隔离 configDir(记忆文件落 <tmp>/memories/<cwd-slug>.md)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });

    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    // 手工 provider 指向 mock(记忆管线只用 compact,summary 来自硬线自动触发的模型压缩)
    const url_buf = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1/chat/completions", .{MOCK_PORT2});
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = url_buf }};
    var cfg = cfgmod.Config{ .arena = &arena };
    cfg.providers = &provs;
    cfg.default_provider = "mock";
    cfg.default_model = "mock-model";

    var state = MockState{ .alloc = std.heap.page_allocator, .port = MOCK_PORT2 };
    const thread = try std.Thread.spawn(.{}, mockServerMain, .{&state});
    var ready = false;
    for (0..50) |_| {
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", MOCK_PORT2) catch break;
        var s = addr.connect(util.io, .{ .mode = .stream, .protocol = .tcp }) catch {
            _ = std.Io.sleep(util.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
            continue;
        };
        s.close(util.io);
        ready = true;
        break;
    }
    try t.expect(ready);
    defer state.stop.store(true, .release);

    // 会话 A:塞大消息触发自动压缩(摘要 = mock 第 6 轮 "summarized.")。
    // 压缩成功 → cross-session-memory 插件把摘要追加到 memories/<cwd-slug>.md。
    var agentA = try agentmod.Agent.initOpts(a, &cfg, "mock", "mock-model", "/tmp", .{});
    for (0..2) |_| {
        try agentA.messages.append(.{ .role = "system", .content = "(Conversation compacted. Summary:)\n" ++ ("s" ** (250 * 1024)) });
    }
    for (0..3) |i| {
        try agentA.messages.append(.{ .role = "user", .content = try std.fmt.allocPrint(a, "work item {d} {s}", .{ i, "w" ** (60 * 1024) }) });
    }
    _ = try agentA.send("continue");
    try t.expect(state.req6_was_compact.load(.acquire));
    // 记忆文件已生成且含摘要
    const slug = try util.cwdSlug(a, "/tmp");
    const mem_name = try std.fmt.allocPrint(a, "{s}.md", .{slug});
    const mem_path = try std.fs.path.join(a, &.{ tmp_path, "memories", mem_name });
    const stored = try std.Io.Dir.cwd().readFileAlloc(util.io, mem_path, a, .limited(64 * 1024));
    try t.expect(std.mem.indexOf(u8, stored, "summarized") != null);

    // 会话 B:同一 cwd 的新会话 → 启动注入;另一 cwd 不注入。
    var agentB = try agentmod.Agent.initOpts(a, &cfg, "mock", "mock-model", "/tmp", .{});
    pluginsmod.injectMemory(&agentB);
    try t.expect(std.mem.indexOf(u8, agentB.system_prompt, "## Cross-session memory") != null);
    try t.expect(std.mem.indexOf(u8, agentB.system_prompt, "summarized") != null);
    // 幂等:二次注入不重复
    const sys_len = agentB.system_prompt.len;
    pluginsmod.injectMemory(&agentB);
    try t.expectEqual(sys_len, agentB.system_prompt.len);

    // 异目录会话不注入
    var agentC = try agentmod.Agent.initOpts(a, &cfg, "mock", "mock-model", "/elsewhere", .{});
    pluginsmod.injectMemory(&agentC);
    try t.expect(std.mem.indexOf(u8, agentC.system_prompt, "## Cross-session memory") == null);

    // 清理:停服 join 后显式删(server 线程用单线程 util.io,不 join 则 deleteTree 并发竞态)
    state.stop.store(true, .release);
    thread.join();
    std.Io.Dir.cwd().deleteTree(util.io, tmp_path) catch {};
}

pub fn testFullLoop() !void {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var state = MockState{ .alloc = std.heap.page_allocator };
    const thread = try std.Thread.spawn(.{}, mockServerMain, .{&state});
    // 等服务器就绪
    var ready = false;
    for (0..50) |_| {
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", MOCK_PORT) catch break;
        var s = addr.connect(util.io, .{ .mode = .stream, .protocol = .tcp }) catch {
            _ = std.Io.sleep(util.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
            continue;
        };
        s.close(util.io);
        ready = true;
        break;
    }
    try t.expect(ready);

    // 手工构建 provider 指向 mock
    const url_buf = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1/chat/completions", .{MOCK_PORT});
    _ = &url_buf;
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = url_buf }};
    var cfg = cfgmod.Config{ .arena = &arena };
    cfg.providers = &provs;
    cfg.default_provider = "mock";
    cfg.default_model = "mock-model";

    var agent = try agentmod.Agent.init(a, &cfg, "mock", "mock-model", "/tmp");
    const result = try agent.send("E2E prompt");
    try t.expect(result.error_msg == null);
    try t.expect(std.mem.indexOf(u8, result.text, "E2E-OK") != null);
    try t.expect(std.mem.indexOf(u8, result.text, "tool worked") != null);
    // 工具真实执行:会话中应有 tool 消息且含输出
    var tool_found = false;
    for (agent.messages.items) |m| {
        if (std.mem.eql(u8, m.role, "tool") and std.mem.indexOf(u8, m.content, "piz-e2e-marker") != null) {
            tool_found = true;
        }
    }
    // 缓存前缀:tools 在 messages 之前(静态部分在前,尾部追加不破坏前缀)
    try t.expect(state.tools_before_messages.load(.acquire));
    try t.expect(tool_found);
    try t.expect(state.req2_had_tool.load(.acquire));

    // read-only agent:请求体无 tools,模型可正常回复
    var ro_agent = try agentmod.Agent.initOpts(a, &cfg, "mock", "mock-model", "/tmp", .{ .read_only = true });
    const ro_result = try ro_agent.send("read only test");
    try t.expect(ro_result.error_msg == null);
    try t.expect(std.mem.indexOf(u8, ro_result.text, "RO-OK") != null);
    try t.expect(state.req3_no_tools.load(.acquire));

    // 权限拒绝:回调返回 false → 工具不执行,模型收到 declined 消息
    var deny_agent = try agentmod.Agent.initOpts(a, &cfg, "mock", "mock-model", "/tmp", .{});
    deny_agent.cbs = .{
        .on_require_permission = struct {
            fn deny(_: ?*anyopaque, _: []const u8, _: []const u8) anyerror!bool {
                return false;
            }
        }.deny,
    };
    const deny_result = try deny_agent.send("run the tool");
    try t.expect(deny_result.error_msg == null);
    try t.expect(std.mem.indexOf(u8, deny_result.text, "DENY-OK") != null);
    try t.expect(state.req5_had_declined.load(.acquire));
    // 工具未真正执行:消息流中无工具输出 marker
    for (deny_agent.messages.items) |m| {
        try t.expect(std.mem.indexOf(u8, m.content, "piz-e2e-marker") == null);
    }

    // 自动 compaction:塞大消息触发 → 总结请求 → 后续正常
    var comp_agent = try agentmod.Agent.initOpts(a, &cfg, "mock", "mock-model", "/tmp", .{});
    // 迭代压缩场景:2 条 250KB 旧摘要 + 3 条 60KB 新 user(增量 180KB > 保留预算 102.4K 字符)
    // → 增量部分可总结:cut 落在倒数第 2 条 user 之后 → 调模型压缩(只总结旧摘要+第 1 条 user)
    for (0..2) |_| {
        try comp_agent.messages.append(.{ .role = "system", .content = "(Conversation compacted. Summary:)\n" ++ ("s" ** (250 * 1024)) });
    }
    for (0..3) |i| {
        try comp_agent.messages.append(.{ .role = "user", .content = try std.fmt.allocPrint(a, "work item {d} {s}", .{ i, "w" ** (60 * 1024) }) });
    }
    const comp_result = try comp_agent.send("continue");
    try t.expect(comp_result.error_msg == null);
    try t.expect(std.mem.indexOf(u8, comp_result.text, "COMPACT-OK") != null);
    try t.expect(state.req6_was_compact.load(.acquire));
    // compact 后:summary 置前 + 保留最近消息(codex 式),随后模型回复
    try t.expect(comp_agent.messages.items.len >= 3);
    // summary 存在(可能被 trim 占位前插),最近消息保留
    var found_summary = false;
    for (comp_agent.messages.items) |m| {
        if (std.mem.indexOf(u8, m.content, "summarized") != null) found_summary = true;
    }
    try t.expect(found_summary);
    try t.expectEqualStrings("assistant", comp_agent.messages.items[comp_agent.messages.items.len - 1].role);
    try t.expect(std.mem.indexOf(u8, comp_agent.messages.items[comp_agent.messages.items.len - 1].content, "COMPACT-OK") != null);

    state.stop.store(true, .release);
    thread.join();
    state.stop.store(false, .release);
}

/// 委托链路的端到端验证:**真实 piz 子进程** + mock provider,抓 stdout。
///
/// 这条链路上曾有两个 bug,都只有真跑子进程才暴露:
///   1. spawn 用裸名 "piz" 靠 PATH 查找 —— piz 通常不在 PATH,error.FileNotFound。
///   2. 委托结果靠 `-a` 的 stdout 回传,但 `-a` 把会话 id 打在 stderr。
/// 所以这里必须验证「答复确实从子进程 stdout 出来」,而不是只测参数解析。
pub fn testTaskDelegation(exe_path: []const u8) !void {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const PORT: u16 = 18523;

    // 子进程的配置目录:models.json 把 provider 指向 mock server
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const cfg_dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    const models = try std.fmt.allocPrint(a,
        \\{{"providers":{{"mock":{{"baseUrl":"http://127.0.0.1:{d}/v1","apiKey":"k","api":"openai-completions","models":["mock-model"]}}}}}}
    , .{PORT});
    try tmp.dir.writeFile(util.io, .{ .sub_path = "models.json", .data = models });

    var state = MockState{ .alloc = std.heap.page_allocator, .port = PORT };
    const thread = try std.Thread.spawn(.{}, mockServerMain, .{&state});
    defer {
        state.stop.store(true, .release);
        thread.join();
        state.stop.store(false, .release);
    }
    var ready = false;
    for (0..100) |_| {
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", PORT) catch break;
        var s = addr.connect(util.io, .{ .mode = .stream, .protocol = .tcp }) catch {
            _ = std.Io.sleep(util.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
            continue;
        };
        s.close(util.io);
        ready = true;
        break;
    }
    try t.expect(ready);

    // 真跑一个 piz 子进程,和 buildTaskArgv 拼的一样
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var it = util.environ_map.?.iterator();
    while (it.next()) |kv| try env.put(kv.key_ptr.*, kv.value_ptr.*);
    try env.put("PIZ_DIR", cfg_dir);

    var child = try std.process.spawn(util.io, .{
        .argv = &.{ exe_path, "-p", "delegate me", "-n", "--provider", "mock", "-m", "mock-model", "-x" },
        .cwd = .{ .path = "/tmp" },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    util.setNonBlock(child.stdout.?.handle);
    util.setNonBlock(child.stderr.?.handle);
    var out = std.array_list.Managed(u8).init(a);
    var errbuf = std.array_list.Managed(u8).init(a);
    var pipes = toolsmod.PipeState{
        .buf = &out,
        .err_buf = &errbuf,
        .out_fd = child.stdout.?.handle,
        .err_fd = child.stderr.?.handle,
    };
    const timed_out = try toolsmod.pumpPipes(&pipes, 60_000, activity.Handle.none);
    try t.expect(!timed_out);
    const term = try child.wait(util.io);

    // 子进程正常退出,**答复在 stdout**(不是 stderr)——委托能拿到东西的前提
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    try t.expect(out.items.len > 0);
    // mock 首轮回 "Let me check. " + bash 工具调用,第二轮回最终答复
    try t.expect(std.mem.indexOf(u8, out.items, "Let me check") != null);
}

/// `--` 之后的参数必须当字面量。没有它,任何以 '-' 开头的提示词都无法输入:
/// argv 解析会把 `-rf ...` 当未知选项直接退出。这里真跑子进程验证。
pub fn testDashSeparator(exe_path: []const u8) !void {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const PORT: u16 = 18527;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const cfg_dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    const models = try std.fmt.allocPrint(a,
        \\{{"providers":{{"mock":{{"baseUrl":"http://127.0.0.1:{d}/v1","apiKey":"k","api":"openai-completions","models":["mock-model"]}}}}}}
    , .{PORT});
    try tmp.dir.writeFile(util.io, .{ .sub_path = "models.json", .data = models });

    var state = MockState{ .alloc = std.heap.page_allocator, .port = PORT };
    const thread = try std.Thread.spawn(.{}, mockServerMain, .{&state});
    defer {
        state.stop.store(true, .release);
        thread.join();
        state.stop.store(false, .release);
    }
    var ready = false;
    for (0..100) |_| {
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", PORT) catch break;
        var s = addr.connect(util.io, .{ .mode = .stream, .protocol = .tcp }) catch {
            _ = std.Io.sleep(util.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
            continue;
        };
        s.close(util.io);
        ready = true;
        break;
    }
    try t.expect(ready);

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var it = util.environ_map.?.iterator();
    while (it.next()) |kv| try env.put(kv.key_ptr.*, kv.value_ptr.*);
    try env.put("PIZ_DIR", cfg_dir);

    // 提示词以 '-' 开头 —— 不走 `--` 就会被当成选项
    var child = try std.process.spawn(util.io, .{
        .argv = &.{ exe_path, "-p", "-n", "-x", "--provider", "mock", "-m", "mock-model", "--", "-rf what does it mean" },
        .cwd = .{ .path = "/tmp" },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    util.setNonBlock(child.stdout.?.handle);
    util.setNonBlock(child.stderr.?.handle);
    var out = std.array_list.Managed(u8).init(a);
    var errbuf = std.array_list.Managed(u8).init(a);
    var pipes = toolsmod.PipeState{
        .buf = &out,
        .err_buf = &errbuf,
        .out_fd = child.stdout.?.handle,
        .err_fd = child.stderr.?.handle,
    };
    const timed_out = try toolsmod.pumpPipes(&pipes, 60_000, activity.Handle.none);
    try t.expect(!timed_out);
    const term = try child.wait(util.io);

    // 正常退出,不是 "unknown option" 的 exit(1)
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    try t.expect(std.mem.indexOf(u8, errbuf.items, "unknown option") == null);
    try t.expect(std.mem.indexOf(u8, out.items, "Let me check") != null);
}

// ---------------------------------------------------------------------
// 断流自愈:连接读到一半断掉,piz 应保住已收内容并自动续跑说完。
// ---------------------------------------------------------------------

const DropState = struct {
    port: u16,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    requests: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// 第二次请求里是否带上了「被截断,接着说」的续跑指令
    resume_hinted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 第二次请求里是否带上了第一次收到的那半句(partial 进了历史)
    partial_kept: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// 裸 fd 读写:Zig 0.16 的 std.posix 不再暴露 read/write,
/// 而这个 mock 必须绕过所有缓冲层才能在响应写到一半时精确断开。
fn readFd(fd: std.posix.fd_t, buf: []u8) !usize {
    const rc = @as(isize, @bitCast(std.os.linux.read(fd, buf.ptr, buf.len)));
    if (rc < 0) return error.ReadFailed;
    return @intCast(rc);
}

fn writeFd(fd: std.posix.fd_t, bytes: []const u8) !usize {
    const rc = @as(isize, @bitCast(std.os.linux.write(fd, bytes.ptr, bytes.len)));
    if (rc < 0) return error.WriteFailed;
    return @intCast(rc);
}

/// 故意中途断流的 mock:第一次请求写半个 SSE 就关 socket,第二次正常回完。
///
/// 直接操作裸 socket 而不用 std.http.Server:必须在响应写到一半时真的
/// 关掉连接,让客户端的 SSE 解析器撞上读错误 —— 这是网络抖动的真实形态,
/// 返回一个 5xx 状态码模拟不出来(那走的是重试路径,不是断流路径)。
fn dropServerMain(state: *DropState) void {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", state.port) catch return;
    var server = addr.listen(util.io, .{ .reuse_address = true }) catch return;
    defer server.deinit(util.io);
    util.setNonBlock(server.socket.handle);

    var pfds = [_]std.posix.pollfd{.{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    while (!state.stop.load(.acquire)) {
        const n = std.posix.poll(&pfds, 10) catch continue;
        if (n == 0) continue;
        const raw = std.os.linux.accept4(server.socket.handle, null, null, 0o2000000);
        const rc = @as(isize, @bitCast(raw));
        if (rc < 0) continue;
        const fd: std.posix.fd_t = @intCast(rc);
        defer _ = std.os.linux.close(fd);

        // 读完请求头 + body(只要能看到 body 内容用于断言即可)
        var rbuf: [16384]u8 = undefined;
        const got = readFd(fd, &rbuf) catch continue;
        const req_no = state.requests.fetchAdd(1, .acq_rel) + 1;
        const body = rbuf[0..got];
        if (req_no == 2) {
            if (std.mem.indexOf(u8, body, "cut off by a network interruption") != null) {
                state.resume_hinted.store(true, .release);
            }
            if (std.mem.indexOf(u8, body, "HALF-") != null) {
                state.partial_kept.store(true, .release);
            }
        }

        if (req_no == 1) {
            // 写 header + 一个 content chunk,然后**不写 [DONE] 直接断开**
            const head = "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n";
            _ = writeFd(fd, head) catch {};
            // chunked 编码的一个块:size CRLF data CRLF
            const ev = "data: {\"choices\":[{\"delta\":{\"content\":\"HALF-\"},\"finish_reason\":null}]}\n\n";
            var szbuf: [16]u8 = undefined;
            const sz = std.fmt.bufPrint(&szbuf, "{x}\r\n", .{ev.len}) catch continue;
            _ = writeFd(fd, sz) catch {};
            _ = writeFd(fd, ev) catch {};
            _ = writeFd(fd, "\r\n") catch {};
            // 不发结束块、不发 [DONE] —— close 让客户端读到意外的流结束
            continue;
        }
        // 第二次:正常回完
        const body_sse =
            "data: {\"choices\":[{\"delta\":{\"content\":\"RESUMED-OK\"},\"finish_reason\":null}]}\n\n" ++
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":8}}\n\n" ++
            "data: [DONE]\n\n";
        var hbuf: [256]u8 = undefined;
        const head2 = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{body_sse.len}) catch continue;
        _ = writeFd(fd, head2) catch {};
        _ = writeFd(fd, body_sse) catch {};
    }
}

test "stream cut mid-reply keeps partial text and resumes automatically" {
    const t = std.testing;
    try util.testInit();
    const PORT: u16 = 18527;
    var state = DropState{ .port = PORT };
    const th = try std.Thread.spawn(.{}, dropServerMain, .{&state});
    defer {
        state.stop.store(true, .release);
        th.join();
    }
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 80 * std.time.ns_per_ms }, .awake) catch {};

    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1", .{PORT});
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = base, .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");

    const res = try agent.send("hello");

    // 断流后自动续跑:第二次请求发生了
    try t.expectEqual(@as(usize, 2), state.requests.load(.acquire));
    // 已收到的半句必须进历史 —— 丢了就等于用户眼前那半段回复凭空消失
    try t.expect(state.partial_kept.load(.acquire));
    // 续跑指令必须明确「接着说、别重复」
    try t.expect(state.resume_hinted.load(.acquire));
    // 最终拿到的是续跑后的完整答复,而不是一个错误
    try t.expect(res.error_msg == null);
    try t.expectEqualStrings("RESUMED-OK", res.text);
}

// ---------------------------------------------------------------------
// 空转防线:模型反复发同一个工具调用,piz 必须干预并停下。
// ---------------------------------------------------------------------

const LoopState = struct {
    port: u16,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    requests: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// piz 是否发出了「别再调了,用已有结果作答」的收尾指令
    nudge_seen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// 永远回同一个 tool_call 的 mock —— 复现某些模型拿到结果后不收尾的行为。
fn loopServerMain(state: *LoopState) void {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", state.port) catch return;
    var server = addr.listen(util.io, .{ .reuse_address = true }) catch return;
    defer server.deinit(util.io);
    util.setNonBlock(server.socket.handle);

    var pfds = [_]std.posix.pollfd{.{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    while (!state.stop.load(.acquire)) {
        const n = std.posix.poll(&pfds, 10) catch continue;
        if (n == 0) continue;
        const raw = std.os.linux.accept4(server.socket.handle, null, null, 0o2000000);
        const rc = @as(isize, @bitCast(raw));
        if (rc < 0) continue;
        const fd: std.posix.fd_t = @intCast(rc);
        defer _ = std.os.linux.close(fd);

        var rbuf: [32768]u8 = undefined;
        const got = readFd(fd, &rbuf) catch continue;
        _ = state.requests.fetchAdd(1, .acq_rel);
        if (std.mem.indexOf(u8, rbuf[0..got], "Stop calling tools") != null) {
            state.nudge_seen.store(true, .release);
        }

        // 每次都回同一个 tool_call:同名、同参数。
        // 命令刻意打时间戳 —— 输出每次不同,所以只有**参数级**判据能抓住它。
        // 用 `echo hi` 那种恒定输出的话输出指纹判据也会触发,这条测试就分不清
        // 到底是哪个判据在起作用。
        const body_sse =
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"date +%s%N\\\"}\"}}]},\"finish_reason\":null}]}\n\n" ++
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
            "data: [DONE]\n\n";
        var hbuf: [256]u8 = undefined;
        const head = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{body_sse.len}) catch continue;
        _ = writeFd(fd, head) catch {};
        _ = writeFd(fd, body_sse) catch {};
    }
}

test "identical tool calls in a row are cut off well before the iteration limit" {
    const t = std.testing;
    try util.testInit();
    pluginsmod.resetEnabledForTest();
    const PORT: u16 = 18529;
    var state = LoopState{ .port = PORT };
    const th = try std.Thread.spawn(.{}, loopServerMain, .{&state});
    defer {
        state.stop.store(true, .release);
        th.join();
    }
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 80 * std.time.ns_per_ms }, .awake) catch {};

    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1", .{PORT});
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = base, .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");

    _ = try agent.send("run echo hi");

    // 干预过:发出了收尾指令
    try t.expect(state.nudge_seen.load(.acquire));
    // 远早于 24 轮就停了。阈值 2 → 劝一次 → 再重复 2 轮 → 停,约 6 轮。
    const reqs = state.requests.load(.acquire);
    try t.expect(reqs >= 3); // 至少要观察到重复才判定
    try t.expect(reqs <= 8); // 关键:不是烧到 MAX_TOOL_ITER=24
}

// ---------------------------------------------------------------------
// 输出空转:参数每次不同但输出一样,也要被切断。
// ---------------------------------------------------------------------

const VariantState = struct {
    port: u16,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    requests: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    nudge_seen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// 每次回**不同参数**的同名工具调用 —— 复现「换个写法再跑一遍」。
/// 参数比对抓不住这种,只有输出指纹能。
fn variantServerMain(state: *VariantState) void {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", state.port) catch return;
    var server = addr.listen(util.io, .{ .reuse_address = true }) catch return;
    defer server.deinit(util.io);
    util.setNonBlock(server.socket.handle);

    var pfds = [_]std.posix.pollfd{.{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    while (!state.stop.load(.acquire)) {
        const n = std.posix.poll(&pfds, 10) catch continue;
        if (n == 0) continue;
        const raw = std.os.linux.accept4(server.socket.handle, null, null, 0o2000000);
        const rc = @as(isize, @bitCast(raw));
        if (rc < 0) continue;
        const fd: std.posix.fd_t = @intCast(rc);
        defer _ = std.os.linux.close(fd);

        var rbuf: [32768]u8 = undefined;
        const got = readFd(fd, &rbuf) catch continue;
        const req_no = state.requests.fetchAdd(1, .acq_rel) + 1;
        if (std.mem.indexOf(u8, rbuf[0..got], "identical output every time") != null) {
            state.nudge_seen.store(true, .release);
        }

        // 每轮命令写法都不同(重定向、管道、cd 前缀),但都跑同一个 echo,
        // 所以工具输出每次完全一致。
        const variants = [_][]const u8{
            "echo same",
            "echo same 2>&1",
            "sh -c 'echo same'",
            "cd /tmp && echo same",
            "echo same | cat",
            "true; echo same",
        };
        const cmd = variants[@min(req_no - 1, variants.len - 1)];
        var sbuf: [1024]u8 = undefined;
        const sse = std.fmt.bufPrint(&sbuf, "data: {{\"choices\":[{{\"delta\":{{\"tool_calls\":[{{\"index\":0,\"id\":\"c{d}\",\"type\":\"function\",\"function\":{{\"name\":\"bash\",\"arguments\":\"{{\\\"command\\\":\\\"{s}\\\"}}\"}}}}]}},\"finish_reason\":null}}]}}\n\n" ++
            "data: {{\"choices\":[{{\"delta\":{{}},\"finish_reason\":\"tool_calls\"}}]}}\n\n" ++
            "data: [DONE]\n\n", .{ req_no, cmd }) catch continue;
        var hbuf: [256]u8 = undefined;
        const head = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{sse.len}) catch continue;
        _ = writeFd(fd, head) catch {};
        _ = writeFd(fd, sse) catch {};
    }
}

test "different commands that return identical output are also cut off" {
    const t = std.testing;
    try util.testInit();
    pluginsmod.resetEnabledForTest();
    const PORT: u16 = 18531;
    var state = VariantState{ .port = PORT };
    const th = try std.Thread.spawn(.{}, variantServerMain, .{&state});
    defer {
        state.stop.store(true, .release);
        th.join();
    }
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 80 * std.time.ns_per_ms }, .awake) catch {};

    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1", .{PORT});
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = base, .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");

    _ = try agent.send("report the output");

    // 参数每次不同,所以参数级判据不会触发 —— 必须靠输出指纹抓到
    try t.expect(state.nudge_seen.load(.acquire));
    const reqs = state.requests.load(.acquire);
    try t.expect(reqs >= 3);
    try t.expect(reqs <= 9); // 远早于 MAX_TOOL_ITER=24
}

// ---------------------------------------------------------------------
// 止损切断时不能让用户空手而归:答案在工具输出里,要交出去。
// ---------------------------------------------------------------------

const SalvageState = struct {
    port: u16,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    requests: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

/// 永远只发 tool_calls,一个字正文都不发 —— 复现「模型烧光额度也不给结论」。
/// 每轮命令不同且输出不同,好让两条空转判据都不触发,逼到迭代上限那条路径。
fn salvageServerMain(state: *SalvageState) void {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", state.port) catch return;
    var server = addr.listen(util.io, .{ .reuse_address = true }) catch return;
    defer server.deinit(util.io);
    util.setNonBlock(server.socket.handle);

    var pfds = [_]std.posix.pollfd{.{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    while (!state.stop.load(.acquire)) {
        const n = std.posix.poll(&pfds, 10) catch continue;
        if (n == 0) continue;
        const raw = std.os.linux.accept4(server.socket.handle, null, null, 0o2000000);
        const rc = @as(isize, @bitCast(raw));
        if (rc < 0) continue;
        const fd: std.posix.fd_t = @intCast(rc);
        defer _ = std.os.linux.close(fd);

        var rbuf: [32768]u8 = undefined;
        _ = readFd(fd, &rbuf) catch continue;
        const req_no = state.requests.fetchAdd(1, .acq_rel) + 1;

        // 每轮 echo 不同的数字:输出各不相同,空转判据不触发。
        var cbuf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cbuf, "echo round-{d}", .{req_no}) catch continue;
        var sbuf: [1024]u8 = undefined;
        const sse = std.fmt.bufPrint(&sbuf, "data: {{\"choices\":[{{\"delta\":{{\"tool_calls\":[{{\"index\":0,\"id\":\"c{d}\",\"type\":\"function\",\"function\":{{\"name\":\"bash\",\"arguments\":\"{{\\\"command\\\":\\\"{s}\\\"}}\"}}}}]}},\"finish_reason\":null}}]}}\n\n" ++
            "data: {{\"choices\":[{{\"delta\":{{}},\"finish_reason\":\"tool_calls\"}}]}}\n\n" ++
            "data: [DONE]\n\n", .{ req_no, cmd }) catch continue;
        var hbuf: [256]u8 = undefined;
        const head = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{sse.len}) catch continue;
        _ = writeFd(fd, head) catch {};
        _ = writeFd(fd, sse) catch {};
    }
}

test "cutoff with no model text hands back the last tool output" {
    const t = std.testing;
    try util.testInit();
    pluginsmod.resetEnabledForTest();
    const PORT: u16 = 18532;
    var state = SalvageState{ .port = PORT };
    const th = try std.Thread.spawn(.{}, salvageServerMain, .{&state});
    defer {
        state.stop.store(true, .release);
        th.join();
    }
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 80 * std.time.ns_per_ms }, .awake) catch {};

    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1", .{PORT});
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = base, .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");

    const res = try agent.send("what does it print");

    // 关键:模型一个字正文都没发,但用户不能拿到空回复 ——
    // 答案在最后一份工具输出里,piz 要把它交出来。
    try t.expect(res.text.len > 0);
    try t.expect(std.mem.indexOf(u8, res.text, "round-") != null);
    // 必须说清这是原始工具输出,不能让用户误以为模型作过判断
    try t.expect(std.mem.indexOf(u8, res.text, "原始输出") != null);
}

test "salvage never overwrites text the model actually produced" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 模型说了话 —— 原样保留,不许被工具输出顶掉
    var with_text = ai.RunResult{ .text = "the answer is 42" };
    agentmod.salvageTextForTest(a, &with_text, "bash", "raw tool bytes");
    try t.expectEqualStrings("the answer is 42", with_text.text);

    // 模型没说话 —— 用工具输出填补
    var empty = ai.RunResult{};
    agentmod.salvageTextForTest(a, &empty, "bash", "raw tool bytes");
    try t.expect(std.mem.indexOf(u8, empty.text, "raw tool bytes") != null);

    // 工具输出也是空的 —— 不许编造内容
    var both_empty = ai.RunResult{};
    agentmod.salvageTextForTest(a, &both_empty, "bash", "");
    try t.expectEqualStrings("", both_empty.text);
}

// ---------- 并发 provider 请求 ----------

/// 记录并发峰值的最小 mock。每连接一个线程 —— e2e 的主 mock 是串行 accept-handle,
/// 用它测不出串行化(服务端本身就是串行的)。
const ConcState = struct {
    port: u16,
    stop: std.atomic.Value(bool) = .init(false),
    /// 当前同时在处理的请求数
    in_flight: std.atomic.Value(u32) = .init(0),
    /// 见过的最大并发数 —— 这是断言的核心。锁串行化时它永远是 1,
    /// 而这个判据与机器速度无关(时间断言在 CI 上不稳)。
    peak: std.atomic.Value(u32) = .init(0),
    completed: std.atomic.Value(u32) = .init(0),
};

fn concHandle(state: *ConcState, fd: std.posix.fd_t) void {
    var conn = std.Io.net.Stream{ .socket = .{ .handle = fd, .address = undefined } };
    defer conn.close(util.io);

    const now = state.in_flight.fetchAdd(1, .acq_rel) + 1;
    _ = state.peak.fetchMax(now, .acq_rel);
    defer _ = state.in_flight.fetchSub(1, .acq_rel);

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var fin = conn.reader(util.io, &rbuf);
    var fout = conn.writer(util.io, &wbuf);
    var server = std.http.Server.init(&fin.interface, &fout.interface);
    var req = server.receiveHead() catch return;
    var tbuf: [8192]u8 = undefined;
    const reader = req.readerExpectContinue(&tbuf) catch return;
    _ = reader.allocRemaining(state_alloc, .limited(1024 * 1024)) catch return;

    // 停在这里等一小会:所有请求都卡在这段窗口内,峰值才反映真实并发度。
    // 串行化的话每个请求依次进出,峰值恒为 1。
    std.Io.sleep(util.io, .{ .nanoseconds = 120 * std.time.ns_per_ms }, .awake) catch {};

    const body =
        "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    req.respond(body, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
    }) catch return;
    _ = state.completed.fetchAdd(1, .acq_rel);
}

var state_alloc: std.mem.Allocator = undefined;

fn concServerMain(state: *ConcState) void {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", state.port) catch return;
    var server = addr.listen(util.io, .{ .reuse_address = true }) catch return;
    defer server.deinit(util.io);
    util.setNonBlock(server.socket.handle);

    var pfds = [_]std.posix.pollfd{.{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    while (!state.stop.load(.acquire)) {
        const n = std.posix.poll(&pfds, 10) catch continue;
        if (n == 0) continue;
        const raw = std.os.linux.accept4(server.socket.handle, null, null, 0o2000000);
        const rc = @as(isize, @bitCast(raw));
        if (rc < 0) continue;
        const th = std.Thread.spawn(.{}, concHandle, .{ state, @as(std.posix.fd_t, @intCast(rc)) }) catch {
            concHandle(state, @intCast(rc));
            continue;
        };
        th.detach();
    }
}

test "provider requests actually run in parallel and none get corrupted" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    state_alloc = arena.allocator();

    var state = ConcState{ .port = 18711 };
    const server_thread = try std.Thread.spawn(.{}, concServerMain, .{&state});
    defer {
        state.stop.store(true, .release);
        server_thread.join();
    }
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 60 * std.time.ns_per_ms }, .awake) catch {};

    const N = 8;
    const Worker = struct {
        ok: std.atomic.Value(u32) = .init(0),
        bad: std.atomic.Value(u32) = .init(0),
        port: u16,

        fn run(self: *@This()) void {
            var url_buf: [64]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{self.port}) catch return;
            const body = "{\"model\":\"m\",\"messages\":[],\"stream\":true}";
            const s = httpc.Stream.init(std.heap.page_allocator, url, &.{}, body) catch {
                _ = self.bad.fetchAdd(1, .acq_rel);
                return;
            };
            defer s.deinit();
            // 每个响应必须完整:2 个 data 事件 + [DONE]。少一个就说明
            // 两个线程读串了同一个连接。
            var data_events: usize = 0;
            var saw_done = false;
            while (s.readLine() catch null) |line| {
                if (std.mem.startsWith(u8, line, "data: [DONE]")) saw_done = true else if (std.mem.startsWith(u8, line, "data: ")) data_events += 1;
            }
            if (data_events == 2 and saw_done) {
                _ = self.ok.fetchAdd(1, .acq_rel);
            } else {
                _ = self.bad.fetchAdd(1, .acq_rel);
            }
        }
    };
    var w = Worker{ .port = state.port };
    var threads: [N]std.Thread = undefined;
    for (&threads) |*th| th.* = try std.Thread.spawn(.{}, Worker.run, .{&w});
    for (threads) |th| th.join();

    // 全部完整 —— 并发不能损坏连接池
    try t.expectEqual(@as(u32, N), w.ok.load(.acquire));
    try t.expectEqual(@as(u32, 0), w.bad.load(.acquire));

    // 真的并发。ClientPool 的锁曾覆盖整个 Stream.init(建连 + 发请求体 +
    // 收响应头),把并发调用完全串行化:实测 TTFB 300ms 下 160 个请求
    // 48169ms vs 3755ms(12.8 倍)。串行时这个峰值恒为 1。
    try t.expect(state.peak.load(.acquire) > 1);
}

// ---------- 进程内 subagent ----------

/// 专用 mock:第一轮回 task 工具调用,subagent 的请求回 bash 工具调用,
/// 带过工具结果的请求回文本。按请求内容分派而非序号 —— 并行 subagent
/// 的到达顺序不确定。
const SubMock = struct {
    port: u16,
    stop: std.atomic.Value(bool) = .init(false),
    /// 看到的 read_only 子请求数(请求体无 tools 字段)
    ro_requests: std.atomic.Value(u32) = .init(0),
    /// 见过的「要求再委派」的请求数 —— 深度闸门失效时它会失控增长
    nest_requests: std.atomic.Value(u32) = .init(0),
};

var submock_alloc: std.mem.Allocator = undefined;

fn subMockHandle(state: *SubMock, fd: std.posix.fd_t) void {
    var conn = std.Io.net.Stream{ .socket = .{ .handle = fd, .address = undefined } };
    defer conn.close(util.io);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [8 * 1024]u8 = undefined;
    var fin = conn.reader(util.io, &rbuf);
    var fout = conn.writer(util.io, &wbuf);
    var server = std.http.Server.init(&fin.interface, &fout.interface);
    var req = server.receiveHead() catch return;
    var tbuf: [64 * 1024]u8 = undefined;
    const reader = req.readerExpectContinue(&tbuf) catch return;
    const body = reader.allocRemaining(submock_alloc, .limited(4 * 1024 * 1024)) catch return;

    const ran_tool = std.mem.indexOf(u8, body, "\"role\":\"tool\"") != null;
    const wants_task = std.mem.indexOf(u8, body, "SPLIT-ME") != null;
    // 嵌套委派:subagent 收到 NEST-ME 时也要求再委派一层。深度正确递增时
    // 第二层撞上 MAX_TASK_DEPTH 被拒;不递增就会一层层下去。
    const wants_nest = std.mem.indexOf(u8, body, "NEST-ME") != null;
    if (std.mem.indexOf(u8, body, "\"tools\"") == null) {
        _ = state.ro_requests.fetchAdd(1, .acq_rel);
    }
    if (wants_nest and !ran_tool) _ = state.nest_requests.fetchAdd(1, .acq_rel);

    const payload = if (ran_tool)
        "data: {\"choices\":[{\"delta\":{\"content\":\"SUB-DONE\"},\"finish_reason\":null}]}\n\n" ++
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
            "data: [DONE]\n\n"
    else if (wants_task)
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"t1\",\"function\":{\"name\":\"task\",\"arguments\":\"{\\\"tasks\\\":[{\\\"description\\\":\\\"leg one\\\"},{\\\"description\\\":\\\"leg two\\\"}]}\"}}]},\"finish_reason\":null}]}\n\n" ++
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
            "data: [DONE]\n\n"
    else if (wants_nest)
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"n1\",\"function\":{\"name\":\"task\",\"arguments\":\"{\\\"description\\\":\\\"NEST-ME deeper\\\"}\"}}]},\"finish_reason\":null}]}\n\n" ++
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
            "data: [DONE]\n\n"
    else
        // subagent 的第一轮:跑一个真工具,父 agent 才有中间事件可看
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"b1\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"echo inner\\\"}\"}}]},\"finish_reason\":null}]}\n\n" ++
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
            "data: [DONE]\n\n";

    // 必须声明 close:这个 mock 每连接只处理一个请求,而 httpc 的连接池
    // 默认 keep_alive,复用到已关闭的连接就是 HttpConnectionClosing。
    req.respond(payload, .{
        .status = .ok,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
    }) catch return;
}

fn subMockMain(state: *SubMock) void {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", state.port) catch return;
    var server = addr.listen(util.io, .{ .reuse_address = true }) catch return;
    defer server.deinit(util.io);
    util.setNonBlock(server.socket.handle);
    var pfds = [_]std.posix.pollfd{.{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    while (!state.stop.load(.acquire)) {
        const n = std.posix.poll(&pfds, 10) catch continue;
        if (n == 0) continue;
        const raw = std.os.linux.accept4(server.socket.handle, null, null, 0o2000000);
        const rc = @as(isize, @bitCast(raw));
        if (rc < 0) continue;
        // 每连接一线程:并行 subagent 的请求必须能同时处理,串行 accept-handle
        // 会把它们排成队,测出来的是 mock 的极限而不是 piz 的
        const th = std.Thread.spawn(.{}, subMockHandle, .{ state, @as(std.posix.fd_t, @intCast(rc)) }) catch {
            subMockHandle(state, @intCast(rc));
            continue;
        };
        th.detach();
    }
}

/// 收集父 agent 看到的 subagent 事件。
const SubSpy = struct {
    mutex: std.Io.Mutex = .init,
    tool_starts: u32 = 0,
    tool_dones: u32 = 0,
    finished: u32 = 0,
    /// 见过的最大任务序号 —— 每一路都得有自己的编号,否则界面上分不清
    max_idx: usize = 0,

    fn onEvent(ctx: ?*anyopaque, idx: usize, kind: agentmod.SubagentEvent, text: []const u8) anyerror!void {
        _ = text;
        const self: *SubSpy = @ptrCast(@alignCast(ctx.?));
        self.mutex.lockUncancelable(util.io);
        defer self.mutex.unlock(util.io);
        self.max_idx = @max(self.max_idx, idx);
        switch (kind) {
            .tool_start => self.tool_starts += 1,
            .tool_done => self.tool_dones += 1,
            .finished => self.finished += 1,
            else => {},
        }
    }
};

test "in-process subagents report progress and inherit the right identity" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    submock_alloc = a;

    var state = SubMock{ .port = 18731 };
    const server_thread = try std.Thread.spawn(.{}, subMockMain, .{&state});
    defer {
        state.stop.store(true, .release);
        server_thread.join();
    }
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 60 * std.time.ns_per_ms }, .awake) catch {};

    var cfg = cfgmod.Config{ .arena = &arena };
    var provs = [_]cfgmod.Provider{.{
        .name = "mock",
        .api = .openai_completions,
        .base_url = "http://127.0.0.1:18731",
        .api_key = "k",
    }};
    cfg.providers = &provs;

    // 父 agent 带 task 工具
    var spy = SubSpy{};
    var parent = try agentmod.Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{
        .plugins = pluginsmod.withEnabled(0, "task-delegation"),
    });
    parent.cbs = .{ .ctx = &spy, .on_subagent = SubSpy.onEvent };

    const result = try parent.send("SPLIT-ME into two");
    try t.expect(result.error_msg == null);

    // 两路 subagent 都跑完,且父 agent 拿到了最终答复
    var tool_msg: []const u8 = "";
    for (parent.messages.items) |m| {
        if (std.mem.eql(u8, m.role, "tool")) tool_msg = m.content;
    }
    try t.expect(std.mem.indexOf(u8, tool_msg, "2 succeeded") != null);
    try t.expect(std.mem.indexOf(u8, tool_msg, "SUB-DONE") != null);

    // **本次改造的核心:中间过程可见。**
    // 子进程路径下委派是纯黑盒 —— 父 agent join() 干等,只能拿到最终文本。
    // 进程内跑之后 subagent 的每次工具调用都实时转发出来。
    try t.expect(spy.tool_starts >= 2);
    try t.expect(spy.tool_dones >= 2);
    try t.expectEqual(@as(u32, 2), spy.finished);
    // 每一路有自己的序号,否则界面上两路事件混成一团
    try t.expectEqual(@as(usize, 2), spy.max_idx);

    // subagent 没有真的 spawn 进程 —— 它们跑在本进程的线程里。
    // 校验方式:mock 看到的请求里既有带 tools 的(subagent 有工具),
    // 又都来自同一个进程(否则 e2e 里根本连不上这个 mock:
    // 子进程走的是 piz 可执行文件,那需要 API key 与真配置文件)。
    try t.expect(state.ro_requests.load(.acquire) == 0);
}

test "sub-agent identity: depth increments, read-only only tightens" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg = cfgmod.Config{ .arena = &arena };
    var provs = [_]cfgmod.Provider{.{
        .name = "mock",
        .api = .openai_completions,
        .base_url = "http://127.0.0.1:1",
        .api_key = "k",
    }};
    cfg.providers = &provs;

    // 只读父 agent 的 subagent 必然只读 —— 否则委派就是一条提权通道
    const ro_parent = try agentmod.Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{ .read_only = true });
    try t.expect(ro_parent.read_only);

    // 深度是 Agent 字段而非环境变量:进程内 subagent 没有新进程可继承环境
    const deep = try agentmod.Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{ .depth = 1 });
    try t.expectEqual(@as(usize, 1), deep.depth);
    const deeper = try agentmod.Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{ .depth = deep.depth + 1 });
    try t.expectEqual(@as(usize, 2), deeper.depth);

    // 启用集是 per-Agent:一个 Agent 开了插件不会影响另一个
    const with_task = try agentmod.Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{
        .plugins = pluginsmod.withEnabled(0, "task-delegation"),
    });
    const without = try agentmod.Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{ .plugins = 0 });
    try t.expect(pluginsmod.findToolIn(with_task.plugins, "task") != null);
    try t.expect(pluginsmod.findToolIn(without.plugins, "task") == null);
}

test "nested in-process delegation is stopped by the depth gate" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    submock_alloc = a;

    var state = SubMock{ .port = 18732 };
    const server_thread = try std.Thread.spawn(.{}, subMockMain, .{&state});
    defer {
        state.stop.store(true, .release);
        server_thread.join();
    }
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 60 * std.time.ns_per_ms }, .awake) catch {};

    var cfg = cfgmod.Config{ .arena = &arena };
    var provs = [_]cfgmod.Provider{.{
        .name = "mock",
        .api = .openai_completions,
        .base_url = "http://127.0.0.1:18732",
        .api_key = "k",
    }};
    cfg.providers = &provs;

    // mock 让每一层都要求再委派。深度正确递增时:顶层(0)派出 subagent(1),
    // 它再派就撞上 MAX_TASK_DEPTH=2 被拒。父 agent 拿到拒绝后会在工具循环里
    // 重试(上限 MAX_TOOL_ITER),所以请求数不是常数,但**有界**。
    //
    // 深度不递增的话每层都是 depth 1,闸门永远不触发,一层层递归下去 ——
    // 进程内路径没有进程边界兜底,那就是栈溢出或挂死。这个测试跑得完
    // 本身就是闸门生效的证据。
    var parent = try agentmod.Agent.initOpts(a, &cfg, "mock", "m", "/tmp", .{
        .plugins = pluginsmod.withEnabled(pluginsmod.factorySet(), "task-delegation"),
    });
    const result = try parent.send("NEST-ME once");
    try t.expect(result.error_msg == null);

    // 有界:每轮工具循环最多派一次,不会指数增长
    try t.expect(state.nest_requests.load(.acquire) <= 64);

    // 顶层派出的那一路必须跑完(闸门只该拦更深的一层,不该让整条委派失败)
    var saw_task_result = false;
    for (parent.messages.items) |m| {
        if (std.mem.eql(u8, m.role, "tool") and std.mem.indexOf(u8, m.content, "=== ") != null) {
            saw_task_result = true;
        }
    }
    try t.expect(saw_task_result);

    // 深度闸门的错误文本本身由 plugins.zig 的单元测试守着 —— 它在 subagent
    // 内部,父 agent 只看到那一路的最终答复。这里守的是「递归会停」。
}

test "read_image compresses and attaches the image to the next request" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    pluginsmod.resetEnabledForTest();
    try t.expect(pluginsmod.enable("vision-input"));
    defer pluginsmod.resetEnabledForTest();

    // 1×1 红色 PNG(69 字节):走 min_dim 放大路径 → 200×200 重编码
    const png = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 0, 0, 3, 1, 1, 0, 201, 254, 146, 239, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130 };
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = "/tmp/piz-img-e2e.png", .data = &png });

    const url_buf = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1/chat/completions", .{MOCK_PORT3});
    var provs = [_]cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = url_buf }};
    var cfg = cfgmod.Config{ .arena = &arena };
    cfg.providers = &provs;
    cfg.default_provider = "mock";
    cfg.default_model = "mock-model";

    var state = MockState{ .alloc = std.heap.page_allocator, .port = MOCK_PORT3, .vision_mode = true };
    const thread = try std.Thread.spawn(.{}, mockServerMain, .{&state});
    var ready = false;
    for (0..50) |_| {
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", MOCK_PORT3) catch break;
        var s = addr.connect(util.io, .{ .mode = .stream, .protocol = .tcp }) catch {
            _ = std.Io.sleep(util.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
            continue;
        };
        s.close(util.io);
        ready = true;
        break;
    }
    try t.expect(ready);
    defer state.stop.store(true, .release);

    var agent = try agentmod.Agent.initOpts(a, &cfg, "mock", "mock-model", "/tmp", .{});
    const result = try agent.send("look at /tmp/piz-img-e2e.png and describe it");
    try t.expect(std.mem.indexOf(u8, result.text, "IMG-OK") != null);
    // 第二轮请求体带 data URI 图片附件
    try t.expect(state.req_had_image.load(.acquire));
    try t.expect(state.req_image_data_ok.load(.acquire));
    // 消息历史里有图片消息(附在 user 消息上),且 token 估算计入图片
    var found = false;
    for (agent.messages.items) |m| {
        if (m.image != null) {
            found = true;
            try t.expect(m.image_w >= 200); // 1×1 被放大到 min_dim
        }
    }
    try t.expect(found);
    // 清理:先停服再 join(server 循环看 stop 才退出)
    state.stop.store(true, .release);
    thread.join();
    std.Io.Dir.cwd().deleteFile(util.io, "/tmp/piz-img-e2e.png") catch {};
}

test "Responses API: function_call events and input items round trip" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    pluginsmod.resetEnabledForTest();
    defer pluginsmod.resetEnabledForTest();

    // endpointUrl 会拼 /v1/responses —— base_url 只传主机
    const url_buf = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{MOCK_PORT4});
    var provs = [_]cfgmod.Provider{.{ .name = "mockr", .api = .openai_responses, .base_url = url_buf }};
    var cfg = cfgmod.Config{ .arena = &arena };
    cfg.providers = &provs;
    cfg.default_provider = "mockr";
    cfg.default_model = "mock-model";

    var state = MockState{ .alloc = std.heap.page_allocator, .port = MOCK_PORT4, .responses_mode = true };
    const thread = try std.Thread.spawn(.{}, mockServerMain, .{&state});
    var ready = false;
    for (0..50) |_| {
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", MOCK_PORT4) catch break;
        var s = addr.connect(util.io, .{ .mode = .stream, .protocol = .tcp }) catch {
            _ = std.Io.sleep(util.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
            continue;
        };
        s.close(util.io);
        ready = true;
        break;
    }
    try t.expect(ready);
    defer state.stop.store(true, .release);

    var agent = try agentmod.Agent.initOpts(a, &cfg, "mockr", "mock-model", "/tmp", .{});
    const result = agent.send("run the marker command") catch |e| {
        std.debug.print("send failed: {s} url={s}\n", .{ @errorName(e), url_buf });
        return error.TestUnexpectedResult;
    };
    try t.expect(std.mem.indexOf(u8, result.text, "RESP-OK") != null);
    try t.expect(state.responses_input_ok.load(.acquire));
    try t.expect(state.responses_call_output_ok.load(.acquire));
    state.stop.store(true, .release);
    thread.join();
}

test "mcp: parse tool name (first __ after prefix)" {
    const p = mcpmod.parseToolName("mcp__my_srv__do_it") orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("my_srv", p.server);
    try std.testing.expectEqualStrings("do_it", p.tool);
    try std.testing.expect(mcpmod.parseToolName("bash") == null);
    try std.testing.expect(mcpmod.parseToolName("mcp__only") == null);
}

test "mcp: script server roundtrip (stdout streaming + tool dispatch)" {
    try mcpmod.runScriptServerTest(std.testing);
}
