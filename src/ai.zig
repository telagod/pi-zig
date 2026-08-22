// ai.zig — provider 客户端:openai-completions 与 anthropic-messages 双协议。
// 流式解析 + 工具调用累积 + 非流式回退 + HTTP 错误映射。
const std = @import("std");
const httpc = @import("httpc.zig");
const cfgmod = @import("config.zig");
const util = @import("util.zig");
const markers = @import("ai_markers.zig");
const ajson = @import("ai_json.zig");
const writeSchema = ajson.writeSchema;
const writeJsonText = ajson.writeJsonText;
const aopenai = @import("ai_openai.zig");
const aanthro = @import("ai_anthropic.zig");
const astream = @import("ai_stream.zig");
pub const ToolAcc = astream.ToolAcc;
const parseOpenAIChunk = astream.parseOpenAIChunk;
const parseAnthropicEvent = astream.parseAnthropicEvent;
const parseResponsesEvent = astream.parseResponsesEvent;
const runOpenAIStream = astream.runOpenAIStream;
const parseOpenAIJson = astream.parseOpenAIJson;
const parseResponsesJson = astream.parseResponsesJson;
const finalizeToolCalls = astream.finalizeToolCalls;
const freeToolAcc = astream.freeToolAcc;
const emitCallback = astream.emitCallback;
const emitText = astream.emitText;
pub const TEXT_MARKERS = markers.TEXT_MARKERS;
pub const textToolCallMarker = markers.textToolCallMarker;
const textMarkerStart = markers.textMarkerStart;

const types = @import("ai_types.zig");
pub const ToolCall = types.ToolCall;
pub const ToolDef = types.ToolDef;
pub const Message = types.Message;
pub const Usage = types.Usage;
pub const RunResult = types.RunResult;
pub const Callbacks = types.Callbacks;
pub const Options = types.Options;
pub const ThinkLevel = types.ThinkLevel;

/// 把 ai.Callbacks.on_abort 适配成 httpc 的 AbortFn(退避等待期间可中断)。
fn abortTrampoline(ctx: ?*anyopaque) bool {
    const cbs: *const Callbacks = @ptrCast(@alignCast(ctx.?));
    return if (cbs.on_abort) |f| f(cbs.ctx) else false;
}

fn abortRequested(cbs: Callbacks) bool {
    return if (cbs.on_abort) |f| f(cbs.ctx) else false;
}

pub fn serializeResponses(
    alloc: std.mem.Allocator,
    model: []const u8,
    messages: []const Message,
    tools: []const ToolDef,
    max_tokens: u32,
    think_level: ThinkLevel,
    think_map: cfgmod.ThinkingLevelMap,
    reasoning: bool,
    compat: cfgmod.Compat,
) ![]u8 {
    return aopenai.serializeResponses(alloc, model, messages, tools, max_tokens, think_level, think_map, reasoning, compat);
}

/// 序列化 OpenAI 兼容请求体。测试走默认 high;真正发请求用 serializeOpenAIThink。
pub fn serializeOpenAI(
    alloc: std.mem.Allocator,
    model: []const u8,
    messages: []const Message,
    tools: []const ToolDef,
    max_tokens: u32,
    cache_key: ?[]const u8,
) ![]u8 {
    return aopenai.serializeOpenAI(alloc, model, messages, tools, max_tokens, cache_key);
}

pub fn serializeOpenAIThink(
    alloc: std.mem.Allocator,
    model: []const u8,
    messages: []const Message,
    tools: []const ToolDef,
    max_tokens: u32,
    cache_key: ?[]const u8,
    think_level: ThinkLevel,
    think_map: cfgmod.ThinkingLevelMap,
    reasoning: bool,
    compat: cfgmod.Compat,
) ![]u8 {
    return aopenai.serializeOpenAIThink(alloc, model, messages, tools, max_tokens, cache_key, think_level, think_map, reasoning, compat);
}

/// 序列化 Anthropic Messages 请求体。
pub fn serializeAnthropic(alloc: std.mem.Allocator, model: []const u8, messages: []const Message, tools: []const ToolDef, max_tokens: u32) ![]u8 {
    return aanthro.serializeAnthropic(alloc, model, messages, tools, max_tokens);
}

pub fn serializeAnthropicThink(
    alloc: std.mem.Allocator,
    model: []const u8,
    messages: []const Message,
    tools: []const ToolDef,
    max_tokens: u32,
    think_level: ThinkLevel,
    think_map: cfgmod.ThinkingLevelMap,
    reasoning: bool,
    compat: cfgmod.Compat,
    budgets: cfgmod.ThinkingBudgets,
    max_output: u32,
    cache_retention: cfgmod.CacheRetention,
) ![]u8 {
    return aanthro.serializeAnthropicThink(alloc, model, messages, tools, max_tokens, think_level, think_map, reasoning, compat, budgets, max_output, cache_retention);
}

/// 主入口:发送请求并流式解析,结果写 result(arena 或调用方 allocator)。
/// 图片数量预算:视觉请求里图片太多会被 provider 硬拒(且常是毒化整请求
/// 的 400)。超限丢最老的图、原位换成省略标记 —— 与 omp 的
/// provider-image-budget 同策。在浅拷贝上做,不改会话历史(历史里的
/// 图还可能在后续轮次因为更少的新图而重新纳入)。
///
/// 上限:openai 兼容视觉端点实践上限 20 张/请求;anthropic 100 个 image block。
fn maxImagesFor(api: cfgmod.Api) usize {
    return switch (api) {
        .anthropic_messages => 100,
        .openai_completions, .openai_responses => 20,
    };
}

pub fn clampProviderImages(alloc: std.mem.Allocator, messages: []const Message, api: cfgmod.Api) ![]const Message {
    const limit = maxImagesFor(api);
    var total: usize = 0;
    for (messages) |m| {
        if (m.image != null) total += 1;
    }
    if (total <= limit) return messages;
    const out = try alloc.alloc(Message, messages.len);
    var drops = total - limit;
    for (messages, 0..) |m, i| {
        out[i] = m;
        if (m.image != null and drops > 0) {
            drops -= 1;
            out[i].image = null;
            out[i].image_mime = null;
            out[i].content = "[image omitted: provider image limit]";
        }
    }
    return out;
}

pub fn run(
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    provider: *const cfgmod.Provider,
    key: ?[]const u8,
    url: []const u8,
    model: []const u8,
    messages: []const Message,
    tools: []const ToolDef,
    options: Options,
) !RunResult {
    var result = RunResult{};
    var out_text = std.array_list.Managed(u8).init(alloc);
    defer out_text.deinit();
    var out_reasoning = std.array_list.Managed(u8).init(alloc);
    defer out_reasoning.deinit();
    var out_signature = std.array_list.Managed(u8).init(alloc);
    defer out_signature.deinit();
    var thinking_redacted = false;
    var usage = Usage{};

    // 图片数量预算:视觉请求里图片太多会被 provider 硬拒(且常是毒化整请求
    // 的 400)。超限丢最老的图、原位换成省略标记 —— 与 omp 的
    // provider-image-budget 同策。在浅拷贝上做,不改会话历史(历史里的
    // 图还可能在后续轮次因为更少的新图而重新纳入)。
    const msgs = clampProviderImages(alloc, messages, provider.api) catch messages;

    const body = if (provider.api == .anthropic_messages)
        try serializeAnthropicThink(alloc, model, msgs, tools, options.max_tokens, options.think_level, options.think_map, options.reasoning, options.compat, options.thinking_budgets, options.max_output, options.cache_retention)
    else if (provider.api == .openai_responses)
        try serializeResponses(alloc, model, msgs, tools, options.max_tokens, options.think_level, options.think_map, options.reasoning, options.compat)
    else
        try serializeOpenAIThink(alloc, model, msgs, tools, options.max_tokens, if (options.cache_retention == .none) null else options.cache_key, options.think_level, options.think_map, options.reasoning, options.compat);
    defer alloc.free(body);

    var headers = std.array_list.Managed(httpc.Header).init(alloc);
    defer headers.deinit();
    if (provider.api == .anthropic_messages) {
        if (key) |k| try headers.append(.{ .name = "x-api-key", .value = k });
        try headers.append(.{ .name = "anthropic-version", .value = "2023-06-01" });
    } else {
        if (key) |k| try headers.append(.{ .name = "Authorization", .value = try std.fmt.allocPrint(alloc, "Bearer {s}", .{k}) });
    }
    if (provider.api == .openai_responses) {
        try headers.append(.{ .name = "OpenAI-Beta", .value = "responses=v1" });
    }

    // 重试窗口仅覆盖此处:连接 + receiveHead + 状态码判定。
    // 一旦往下走进流式读取(向 out_text 累积 / 触发 on_text),就绝不能重试 ——
    // 否则用户会看到重复输出。requestWithRetry 内部同样只在返回前重试。
    // 连接建立回调：把 httpc 的 fd 通知直接转成 ai.Callbacks.on_connect。
    // 时机提前到「连接建立、请求已发」—— receiveHead 可能永远不来(服务器
    // 挂死),那之前就必须让中断方拿到 fd。
    const FdWrap = struct {
        cbs: *const Callbacks,
        fn tramp(ctx: ?*anyopaque, fd: std.posix.fd_t) void {
            const p: *const @This() = @ptrCast(@alignCast(ctx.?));
            if (p.cbs.on_connect) |f| f(p.cbs.ctx, fd);
        }
    };
    var fdwrap = FdWrap{ .cbs = &options.callbacks };
    var stream = httpc.requestWithRetry(
        alloc,
        url,
        headers.items,
        body,
        options.retry_policy,
        if (options.callbacks.on_abort) |_| abortTrampoline else null,
        @ptrCast(@constCast(&options.callbacks)),
        FdWrap.tramp,
        &fdwrap,
    ) catch |err| {
        if (err == error.Canceled) {
            result.aborted = true;
            return result;
        }
        result.error_msg = try std.fmt.allocPrint(arena, "request failed: {s}", .{@errorName(err)});
        return result;
    };
    defer stream.deinit();

    const status = stream.status();
    if (status >= 400) {
        const resp_body = stream.readAll(64 * 1024) catch &.{};
        // 提取 provider 错误消息
        var msg: []const u8 = "";
        if (resp_body.len > 0) {
            if (std.json.parseFromSliceLeaky(std.json.Value, arena, resp_body, .{})) |root| {
                if (root == .object) {
                    if (root.object.get("error")) |e| {
                        if (e == .object) {
                            if (e.object.get("message")) |m| {
                                if (m == .string) msg = m.string;
                            }
                        } else if (e == .string) {
                            msg = e.string;
                        }
                    }
                }
            } else |_| {}
        }
        result.error_msg = if (msg.len > 0)
            try std.fmt.allocPrint(arena, "HTTP {d}: {s}", .{ status, msg })
        else
            try std.fmt.allocPrint(arena, "HTTP {d}: {s}", .{ status, resp_body });
        return result;
    }

    // 判断 SSE 与否:content-type 含 text/event-stream(init 时已拷贝)
    const is_sse = if (stream.content_type) |ct|
        std.mem.indexOf(u8, ct, "text/event-stream") != null
    else
        false;

    if (is_sse) {
        if (provider.api == .anthropic_messages) {
            var acc = std.array_list.Managed(ToolAcc).init(alloc);
            defer freeToolAcc(&acc);
            var finish = std.array_list.Managed(u8).init(alloc);
            defer finish.deinit();
            var parser = httpc.SseParser.init(stream);
            defer parser.deinit();
            while (true) {
                const ev = parser.nextEvent() catch |err| {
                    if (abortRequested(options.callbacks)) {
                        result.aborted = true;
                        break;
                    }
                    // 连接读到一半断了。已经收到并显示给用户的内容是有效的,
                    // 丢掉它等于让用户看着半段回复消失、模型也不知道自己说过什么。
                    // 一个字都没收到才算真失败 —— 那时没有可保的东西。
                    if (out_text.items.len == 0 and out_reasoning.items.len == 0) return err;
                    result.stream_interrupted = @errorName(err);
                    break;
                };
                if (ev) |e| {
                    defer alloc.free(e);
                    try parseAnthropicEvent(alloc, arena, e, &acc, options.callbacks, &out_text, &out_reasoning, &out_signature, &thinking_redacted, &usage, &finish);
                } else break;
                if (abortRequested(options.callbacks)) {
                    result.aborted = true;
                    break;
                }
            }
            result.tool_calls = try finalizeToolCalls(alloc, &acc);
            result.finish_reason = try finish.toOwnedSlice();
        } else if (provider.api == .openai_responses) {
            var acc = std.array_list.Managed(ToolAcc).init(alloc);
            defer freeToolAcc(&acc);
            var finish = std.array_list.Managed(u8).init(alloc);
            defer finish.deinit();
            var errs = std.array_list.Managed(u8).init(alloc);
            defer errs.deinit();
            var parser = httpc.SseParser.init(stream);
            defer parser.deinit();
            while (true) {
                const ev = parser.nextEvent() catch |err| {
                    if (abortRequested(options.callbacks)) {
                        result.aborted = true;
                        break;
                    }
                    if (out_text.items.len == 0 and out_reasoning.items.len == 0 and acc.items.len == 0) return err;
                    result.stream_interrupted = @errorName(err);
                    break;
                };
                if (ev) |e| {
                    defer alloc.free(e);
                    try parseResponsesEvent(alloc, e, &acc, options.callbacks, &out_text, &out_reasoning, &out_signature, &usage, &finish, &errs);
                } else break;
                if (abortRequested(options.callbacks)) {
                    result.aborted = true;
                    break;
                }
            }
            result.tool_calls = try finalizeToolCalls(alloc, &acc);
            result.finish_reason = try finish.toOwnedSlice();
            if (errs.items.len > 0) {
                result.error_msg = try errs.toOwnedSlice();
            }
        } else {
            try runOpenAIStream(alloc, arena, stream, options.callbacks, &result, &out_text, &out_reasoning, &usage);
        }
    } else {
        const resp_body = stream.readAll(64 * 1024) catch |err| {
            if (abortRequested(options.callbacks)) {
                result.aborted = true;
                return result;
            }
            return err;
        };
        if (abortRequested(options.callbacks)) {
            result.aborted = true;
            return result;
        }
        if (provider.api == .anthropic_messages) {
            // 非流式 anthropic 响应
            const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, resp_body, .{}) catch {
                result.error_msg = "provider returned invalid JSON";
                return result;
            };
            const v = root;
            if (v == .object) {
                if (v.object.get("usage")) |u| {
                    if (u == .object) {
                        if (u.object.get("input_tokens")) |it| {
                            if (it == .integer) usage.input = @intCast(it.integer);
                        }
                        if (u.object.get("output_tokens")) |ot| {
                            if (ot == .integer) usage.output = @intCast(ot.integer);
                        }
                    }
                }
                if (v.object.get("stop_reason")) |sr| {
                    if (sr == .string) result.finish_reason = sr.string;
                }
                if (v.object.get("content")) |content| {
                    if (content == .array) {
                        var calls = std.array_list.Managed(ToolCall).init(alloc);
                        for (content.array.items) |block| {
                            if (block != .object) continue;
                            if (block.object.get("type")) |t| {
                                if (t != .string) continue;
                                if (std.mem.eql(u8, t.string, "text")) {
                                    if (block.object.get("text")) |txt| {
                                        if (txt == .string) {
                                            try out_text.appendSlice(txt.string);
                                            try emitText(options.callbacks, out_text.items, txt.string);
                                        }
                                    }
                                } else if (std.mem.eql(u8, t.string, "thinking")) {
                                    if (block.object.get("thinking")) |th| {
                                        if (th == .string) {
                                            try out_reasoning.appendSlice(th.string);
                                            try emitCallback(options.callbacks, options.callbacks.on_reasoning, th.string);
                                        }
                                    }
                                    if (block.object.get("signature")) |s| {
                                        if (s == .string) try out_signature.appendSlice(s.string);
                                    }
                                } else if (std.mem.eql(u8, t.string, "redacted_thinking")) {
                                    thinking_redacted = true;
                                    if (block.object.get("data")) |d| {
                                        if (d == .string) try out_signature.appendSlice(d.string);
                                    }
                                    try out_reasoning.appendSlice("[Reasoning redacted]");
                                    try emitCallback(options.callbacks, options.callbacks.on_reasoning, "[Reasoning redacted]");
                                } else if (std.mem.eql(u8, t.string, "tool_use")) {
                                    var id: []const u8 = "";
                                    var name: []const u8 = "";
                                    var args: []const u8 = "";
                                    if (block.object.get("id")) |i| {
                                        if (i == .string) id = i.string;
                                    }
                                    if (block.object.get("name")) |n| {
                                        if (n == .string) name = n.string;
                                    }
                                    if (block.object.get("input")) |inp| {
                                        args = std.json.Stringify.valueAlloc(alloc, inp, .{}) catch "{}";
                                    }
                                    try calls.append(.{ .id = id, .name = name, .args = args });
                                }
                            }
                        }
                        result.tool_calls = try calls.toOwnedSlice();
                    }
                }
            }
        } else if (provider.api == .openai_responses) {
            try parseResponsesJson(alloc, resp_body, options.callbacks, &result, &out_text, &out_reasoning, &out_signature, &usage);
        } else {
            try parseOpenAIJson(alloc, resp_body, options.callbacks, &result, &out_text, &out_reasoning, &usage);
        }
    }

    result.text = try out_text.toOwnedSlice();
    result.reasoning = try out_reasoning.toOwnedSlice();
    result.thinking_signature = try out_signature.toOwnedSlice();
    result.thinking_redacted = thinking_redacted;
    result.usage = usage;
    return result;
}

test {
    // 单测主体在 ai_tests.zig(体量超实现两倍);引回以保持 zig test 收集。
    _ = @import("ai_tests.zig");
}
