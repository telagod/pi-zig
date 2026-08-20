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

pub const MockState = struct {
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
    /// jsrt e2e:第二轮请求体的 tool 结果里是否带扩展的 block reason
    req2_had_block_reason: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn sseEvent(alloc: std.mem.Allocator, data_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "data: {s}\n\n", .{data_json});
}

pub fn mockServerMain(state: *MockState) void {
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
    } else if (req_no == 6 or req_no == 7) {
        // 第六轮:密图 compact 后的正常请求(不再占用一轮 LLM 摘要)
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
        if (std.mem.indexOf(u8, body, "js-ext-no") != null) {
            state.req2_had_block_reason.store(true, .release);
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

    // 手工 provider 指向 mock(记忆管线走密图折页,/compact 不调模型)
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

    // 会话 A:塞大消息触发自动压缩(密图秒压,不调模型)。
    // 压缩成功 → cross-session-memory 插件把摘要追加到 memories/<cwd-slug>.md。
    var agentA = try agentmod.Agent.initOpts(a, &cfg, "mock", "mock-model", "/tmp", .{});
    for (0..2) |_| {
        try agentA.messages.append(.{ .role = "system", .content = "(Conversation compacted. Summary:)\n" ++ ("s" ** (250 * 1024)) });
    }
    for (0..3) |i| {
        try agentA.messages.append(.{ .role = "user", .content = try std.fmt.allocPrint(a, "work item {d} {s}", .{ i, "w" ** (60 * 1024) }) });
    }
    _ = try agentA.send("continue");
    // 记忆文件已生成且含摘要
    const slug = try util.cwdSlug(a, "/tmp");
    const mem_name = try std.fmt.allocPrint(a, "{s}.md", .{slug});
    const mem_path = try std.fs.path.join(a, &.{ tmp_path, "memories", mem_name });
    const stored = try std.Io.Dir.cwd().readFileAlloc(util.io, mem_path, a, .limited(64 * 1024));
    try t.expect(std.mem.indexOf(u8, stored, "[Snapcompact]") != null);

    // 会话 B:同一 cwd 的新会话 → 启动注入;另一 cwd 不注入。
    var agentB = try agentmod.Agent.initOpts(a, &cfg, "mock", "mock-model", "/tmp", .{});
    pluginsmod.injectMemory(&agentB);
    try t.expect(std.mem.indexOf(u8, agentB.system_prompt, "## Cross-session memory") != null);
    const probe = stored[0..@min(stored.len, 64)];
    try t.expect(std.mem.indexOf(u8, agentB.system_prompt, probe) != null);
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
    // → 增量超过保留预算:折页旧段,近窗留下,不调模型
    for (0..2) |_| {
        try comp_agent.messages.append(.{ .role = "system", .content = "(Conversation compacted. Summary:)\n" ++ ("s" ** (250 * 1024)) });
    }
    for (0..3) |i| {
        try comp_agent.messages.append(.{ .role = "user", .content = try std.fmt.allocPrint(a, "work item {d} {s}", .{ i, "w" ** (60 * 1024) }) });
    }
    const comp_result = try comp_agent.send("continue");
    try t.expect(comp_result.error_msg == null);
    try t.expect(std.mem.indexOf(u8, comp_result.text, "COMPACT-OK") != null);
    // compact 后:summary 置前 + 保留最近消息(codex 式),随后模型回复
    try t.expect(comp_agent.messages.items.len >= 3);
    // summary 存在(可能被 trim 占位前插),最近消息保留
    var found_summary = false;
    for (comp_agent.messages.items) |m| {
        if (std.mem.indexOf(u8, m.content, "[Snapcompact]") != null or std.mem.indexOf(u8, m.content, "Conversation compacted") != null) found_summary = true;
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

pub const DropState = struct {
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
pub fn readFd(fd: std.posix.fd_t, buf: []u8) !usize {
    const rc = @as(isize, @bitCast(std.os.linux.read(fd, buf.ptr, buf.len)));
    if (rc < 0) return error.ReadFailed;
    return @intCast(rc);
}

pub fn writeFd(fd: std.posix.fd_t, bytes: []const u8) !usize {
    const rc = @as(isize, @bitCast(std.os.linux.write(fd, bytes.ptr, bytes.len)));
    if (rc < 0) return error.WriteFailed;
    return @intCast(rc);
}

/// 故意中途断流的 mock:第一次请求写半个 SSE 就关 socket,第二次正常回完。
///
/// 直接操作裸 socket 而不用 std.http.Server:必须在响应写到一半时真的
/// 关掉连接,让客户端的 SSE 解析器撞上读错误 —— 这是网络抖动的真实形态,
/// 返回一个 5xx 状态码模拟不出来(那走的是重试路径,不是断流路径)。
pub fn dropServerMain(state: *DropState) void {
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

/// JS 扩展端到端:tool_call 事件 block 在真实 agent 循环里拦住 bash。
/// mock 首轮要跑 bash;扩展挡下,第二轮请求体的 tool 结果应带 block reason,
/// 且最终答复照常(E2E-OK)。
pub fn testJsExtBlocksBash(exe_path: []const u8) !void {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const PORT: u16 = 18528;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const cfg_dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    const models = try std.fmt.allocPrint(a,
        \\{{"providers":{{"mock":{{"baseUrl":"http://127.0.0.1:{d}/v1","apiKey":"k","api":"openai-completions","models":["mock-model"]}}}}}}
    , .{PORT});
    try tmp.dir.writeFile(util.io, .{ .sub_path = "models.json", .data = models });
    try tmp.dir.createDirPath(util.io, "extensions");
    try tmp.dir.writeFile(util.io, .{ .sub_path = "extensions/block.js", .data =
        \\piz.on("tool_call", (e) => e.toolName === "bash" ? { block: true, reason: "js-ext-no" } : undefined);
        \\
    });

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

    var child = try std.process.spawn(util.io, .{
        .argv = &.{ exe_path, "-p", "run bash", "-n", "--provider", "mock", "-m", "mock-model", "-x" },
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
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    // 扩展拦了 bash:第二轮 tool 结果带 reason;bash 没真跑(marker 不应出现在工具输出)。
    if (!state.req2_had_block_reason.load(.acquire)) {
        std.debug.print("-- child stdout --\n{s}\n-- child stderr --\n{s}\n-- requests={d} --\n", .{ out.items[out.items.len -| 1200..], errbuf.items[errbuf.items.len -| 1200..], state.requests.load(.monotonic) });
    }
    try t.expect(state.req2_had_block_reason.load(.acquire));
    try t.expect(std.mem.indexOf(u8, out.items, "E2E-OK") != null);
}

test {
    // 单测主体在 e2e_tests.zig(原 14 测试 + 各 mock 助手);引回以保持 zig test 收集。
    _ = @import("e2e_tests.zig");
}
