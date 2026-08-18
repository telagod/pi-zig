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

fn serializeResponses(
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
fn serializeOpenAI(
    alloc: std.mem.Allocator,
    model: []const u8,
    messages: []const Message,
    tools: []const ToolDef,
    max_tokens: u32,
    cache_key: ?[]const u8,
) ![]u8 {
    return aopenai.serializeOpenAI(alloc, model, messages, tools, max_tokens, cache_key);
}

fn serializeOpenAIThink(
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
fn serializeAnthropic(alloc: std.mem.Allocator, model: []const u8, messages: []const Message, tools: []const ToolDef, max_tokens: u32) ![]u8 {
    return aanthro.serializeAnthropic(alloc, model, messages, tools, max_tokens);
}

fn serializeAnthropicThink(
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

fn clampProviderImages(alloc: std.mem.Allocator, messages: []const Message, api: cfgmod.Api) ![]const Message {
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
    var stream = httpc.requestWithRetry(
        alloc,
        url,
        headers.items,
        body,
        options.retry_policy,
        if (options.callbacks.on_abort) |_| abortTrampoline else null,
        @ptrCast(@constCast(&options.callbacks)),
    ) catch |err| {
        if (err == error.Canceled) {
            result.aborted = true;
            return result;
        }
        result.error_msg = try std.fmt.allocPrint(arena, "request failed: {s}", .{@errorName(err)});
        return result;
    };
    defer stream.deinit();
    // 通知中断方持有流(供 shutdown 打断阻塞读)
    if (options.callbacks.on_connect) |f| f(options.callbacks.ctx, stream);

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

test "serializeOpenAI basic" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{
        .{ .role = "system", .content = "sys" },
        .{ .role = "user", .content = "hi" },
        .{ .role = "assistant", .content = "", .tool_calls = &.{.{ .id = "c1", .name = "bash", .args = "{\"command\":\"ls\"}" }} },
        .{ .role = "tool", .content = "out", .tool_call_id = "c1" },
    };
    const body = try serializeOpenAI(a, "m", &msgs, &.{}, 100, null);
    try t.expect(std.mem.indexOf(u8, body, "\"model\":\"m\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"c1\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
}

test "ThinkLevel parse uses industry names" {
    const t = std.testing;
    try t.expect(ThinkLevel.parse("浅").? == .low);
    try t.expect(ThinkLevel.parse("off").? == .off);
    try t.expect(ThinkLevel.parse("medium").? == .medium);
    try t.expect(ThinkLevel.parse("xhigh").? == .xhigh);
    try t.expect(ThinkLevel.parse("max").? == .max);
    try t.expect(ThinkLevel.parse("nope") == null);
    try t.expectEqualStrings("high", ThinkLevel.high.label());
}

test "serializeOpenAI think level maps to DeepSeek fields after messages" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{.{ .role = "user", .content = "hi" }};

    const ds_c = cfgmod.Compat{ .think_format = .deepseek, .requires_reasoning_content = true, .supports_reasoning_effort = true };
    const off = try serializeOpenAIThink(a, "m", &msgs, &.{}, 100, null, .off, .{}, true, ds_c);
    try t.expect(std.mem.indexOf(u8, off, "\"thinking\":{\"type\":\"disabled\"}") != null);
    try t.expect(std.mem.indexOf(u8, off, "reasoning_effort") == null);
    try t.expect(std.mem.indexOf(u8, off, "\"thinking\"").? > std.mem.indexOf(u8, off, "\"messages\":[").?);

    const low = try serializeOpenAIThink(a, "m", &msgs, &.{}, 100, null, .low, .{}, true, ds_c);
    try t.expect(std.mem.indexOf(u8, low, "\"reasoning_effort\":\"low\"") != null);

    const deep = try serializeOpenAIThink(a, "m", &msgs, &.{}, 100, null, .max, .{}, true, ds_c);
    try t.expect(std.mem.indexOf(u8, deep, "\"reasoning_effort\":\"max\"") != null);

    const resp = try serializeResponses(a, "m", &msgs, &.{}, 100, .max, .{}, true, .{});
    try t.expect(std.mem.indexOf(u8, resp, "\"effort\":\"max\"") != null);
    try t.expect(std.mem.indexOf(u8, resp, "\"summary\":\"auto\"") != null);
    try t.expect(std.mem.indexOf(u8, resp, "\"include\":[\"reasoning.encrypted_content\"]") != null);

    const silent = try serializeOpenAIThink(a, "m", &msgs, &.{}, 100, null, .high, .{}, false, ds_c);
    try t.expect(std.mem.indexOf(u8, silent, "thinking") == null);
    try t.expect(std.mem.indexOf(u8, silent, "reasoning_effort") == null);

    const ds = cfgmod.Provider{
        .name = "deepseek",
        .api = .openai_completions,
        .base_url = "https://api.deepseek.com",
    };
    const flash = cfgmod.metaFor(&ds, "deepseek-v4-flash");
    const pro = cfgmod.metaFor(&ds, "deepseek-v4-pro");
    const flash_low = try serializeOpenAIThink(a, "deepseek-v4-flash", &msgs, &.{}, 100, null, .low, flash.think_map, true, ds_c);
    try t.expect(std.mem.indexOf(u8, flash_low, "\"reasoning_effort\":\"low\"") != null);
    const pro_high = try serializeOpenAIThink(a, "deepseek-v4-pro", &msgs, &.{}, 100, null, .high, pro.think_map, true, ds_c);
    try t.expect(std.mem.indexOf(u8, pro_high, "\"reasoning_effort\":\"high\"") != null);
    const pro_low = try serializeOpenAIThink(a, "deepseek-v4-pro", &msgs, &.{}, 100, null, .low, pro.think_map, true, ds_c);
    try t.expect(std.mem.indexOf(u8, pro_low, "reasoning_effort") == null);

    const oai_c = cfgmod.Compat{ .think_format = .openai, .supports_reasoning_effort = true };
    const oai = try serializeOpenAIThink(a, "gpt", &msgs, &.{}, 100, null, .high, .{}, true, oai_c);
    try t.expect(std.mem.indexOf(u8, oai, "\"reasoning_effort\":\"high\"") != null);
    try t.expect(std.mem.indexOf(u8, oai, "\"thinking\"") == null);

    const or_c = cfgmod.Compat{ .think_format = .openrouter };
    const orb = try serializeOpenAIThink(a, "x", &msgs, &.{}, 100, null, .high, .{}, true, or_c);
    try t.expect(std.mem.indexOf(u8, orb, "\"reasoning\":{\"effort\":\"high\"}") != null);

    const replay_msgs = [_]Message{.{
        .role = "assistant",
        .content = "",
        .tool_calls = &.{.{ .id = "c1", .name = "bash", .args = "{}" }},
        .reasoning = "step",
    }};
    const replay = try serializeOpenAIThink(a, "m", &replay_msgs, &.{}, 100, null, .high, .{}, true, ds_c);
    try t.expect(std.mem.indexOf(u8, replay, "\"reasoning_content\":\"step\"") != null);
    const empty_rc = [_]Message{.{
        .role = "assistant",
        .content = "",
        .tool_calls = &.{.{ .id = "c1", .name = "bash", .args = "{}" }},
    }};
    const empty = try serializeOpenAIThink(a, "m", &empty_rc, &.{}, 100, null, .high, .{}, true, ds_c);
    try t.expect(std.mem.indexOf(u8, empty, "\"reasoning_content\":\"\"") != null);
}

test "live resolveCompat path: official DeepSeek flash/pro request shape" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = cfgmod.Provider{
        .name = "deepseek",
        .api = .openai_completions,
        .base_url = "https://api.deepseek.com",
        .models = &.{ "deepseek-v4-flash", "deepseek-v4-pro" },
        .model_metas = &.{
            .{ .context_window = 1_000_000, .max_output = 384_000, .vision = false, .reasoning = true },
            .{ .context_window = 1_000_000, .max_output = 384_000, .vision = false, .reasoning = true },
        },
    };
    const hist = [_]Message{
        .{ .role = "user", .content = "hi" },
        .{
            .role = "assistant",
            .content = "",
            .tool_calls = &.{.{ .id = "c1", .name = "bash", .args = "{}" }},
            .reasoning = "think-1",
        },
        .{ .role = "tool", .content = "ok", .tool_call_id = "c1" },
    };

    const flash_meta = cfgmod.metaFor(&p, "deepseek-v4-flash");
    const flash_c = cfgmod.resolveCompat(&p, "deepseek-v4-flash");
    try t.expectEqual(cfgmod.ThinkFormat.deepseek, flash_c.think_format.?);
    try t.expectEqual(true, flash_c.requires_reasoning_content.?);
    const flash_lv = cfgmod.clampThinkLevel(flash_meta, .high);
    try t.expectEqual(cfgmod.ThinkLevel.high, flash_lv);
    const flash = try serializeOpenAIThink(a, "deepseek-v4-flash", &hist, &.{}, 100, "/tmp", flash_lv, flash_meta.think_map, flash_meta.reasoning.?, flash_c);
    try t.expect(std.mem.indexOf(u8, flash, "\"thinking\":{\"type\":\"enabled\"}") != null);
    try t.expect(std.mem.indexOf(u8, flash, "\"reasoning_effort\":\"high\"") != null);
    try t.expect(std.mem.indexOf(u8, flash, "\"reasoning_content\":\"think-1\"") != null);

    const pro_meta = cfgmod.metaFor(&p, "deepseek-v4-pro");
    const pro_c = cfgmod.resolveCompat(&p, "deepseek-v4-pro");
    try t.expectEqual(cfgmod.ThinkLevel.high, cfgmod.clampThinkLevel(pro_meta, .low));
    const pro = try serializeOpenAIThink(a, "deepseek-v4-pro", &hist, &.{}, 100, "/tmp", .high, pro_meta.think_map, pro_meta.reasoning.?, pro_c);
    try t.expect(std.mem.indexOf(u8, pro, "\"reasoning_effort\":\"high\"") != null);
    try t.expect(std.mem.indexOf(u8, pro, "\"reasoning_content\":\"think-1\"") != null);

    const orouter = cfgmod.Provider{
        .name = "openrouter",
        .api = .openai_completions,
        .base_url = "https://openrouter.ai/api/v1",
        .models = &.{"deepseek/deepseek-v4-pro"},
        .model_metas = &.{.{ .reasoning = true }},
    };
    const or_c = cfgmod.resolveCompat(&orouter, "deepseek/deepseek-v4-pro");
    try t.expectEqual(cfgmod.ThinkFormat.openrouter, or_c.think_format.?);
    try t.expectEqual(true, or_c.requires_reasoning_content.?);
    const or_body = try serializeOpenAIThink(a, "deepseek/deepseek-v4-pro", &hist, &.{}, 100, null, .high, cfgmod.metaFor(&orouter, "deepseek/deepseek-v4-pro").think_map, true, or_c);
    try t.expect(std.mem.indexOf(u8, or_body, "\"reasoning\":{\"effort\":\"high\"}") != null);
    try t.expect(std.mem.indexOf(u8, or_body, "\"thinking\"") == null);
    try t.expect(std.mem.indexOf(u8, or_body, "\"reasoning_content\":\"think-1\"") != null);
}

test "non-stream JSON keeps reasoning_content for replay" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out_text = std.array_list.Managed(u8).init(a);
    var out_reasoning = std.array_list.Managed(u8).init(a);
    var usage = Usage{};
    var result = RunResult{};
    const body =
        \\{"choices":[{"message":{"role":"assistant","content":"hi","reasoning_content":"cot"}}]}
    ;
    try parseOpenAIJson(a, body, .{}, &result, &out_text, &out_reasoning, &usage);
    try t.expectEqualStrings("hi", out_text.items);
    try t.expectEqualStrings("cot", out_reasoning.items);
}

test "Anthropic adaptive and budget thinking match pi anthropic-messages.ts" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{.{ .role = "user", .content = "hi" }};
    const ant = cfgmod.Provider{
        .name = "anthropic",
        .api = .anthropic_messages,
        .base_url = "https://api.anthropic.com",
    };
    const sonnet = cfgmod.metaFor(&ant, "claude-sonnet-4-6");
    const sonnet_c = cfgmod.resolveCompat(&ant, "claude-sonnet-4-6");
    const adaptive = try serializeAnthropicThink(a, "claude-sonnet-4-6", &msgs, &.{}, 8192, .high, sonnet.think_map, true, sonnet_c, .{}, sonnet.max_output, .short);
    try t.expect(std.mem.indexOf(u8, adaptive, "\"thinking\":{\"type\":\"adaptive\",\"display\":\"summarized\"}") != null);
    try t.expect(std.mem.indexOf(u8, adaptive, "\"output_config\":{\"effort\":\"high\"}") != null);
    try t.expect(std.mem.indexOf(u8, adaptive, "budget_tokens") == null);

    const opus = cfgmod.metaFor(&ant, "claude-opus-4-7");
    const opus_c = cfgmod.resolveCompat(&ant, "claude-opus-4-7");
    const xhigh = try serializeAnthropicThink(a, "claude-opus-4-7", &msgs, &.{}, 8192, .xhigh, opus.think_map, true, opus_c, .{}, 0, .short);
    try t.expect(std.mem.indexOf(u8, xhigh, "\"effort\":\"xhigh\"") != null);

    const off = try serializeAnthropicThink(a, "claude-sonnet-4-6", &msgs, &.{}, 8192, .off, sonnet.think_map, true, sonnet_c, .{}, 0, .short);
    try t.expect(std.mem.indexOf(u8, off, "\"thinking\":{\"type\":\"disabled\"}") != null);

    const silent = try serializeAnthropicThink(a, "claude-sonnet-4-6", &msgs, &.{}, 8192, .high, sonnet.think_map, false, sonnet_c, .{}, 0, .short);
    try t.expect(std.mem.indexOf(u8, silent, "thinking") == null);

    const budget_c = cfgmod.Compat{};
    const budget = try serializeAnthropicThink(a, "claude-sonnet-4-20250514", &msgs, &.{}, 8192, .high, .{}, true, budget_c, .{}, 64000, .short);
    try t.expect(std.mem.indexOf(u8, budget, "\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":16384") != null);
    try t.expect(std.mem.indexOf(u8, budget, "\"max_tokens\":24576") != null);

    const replay_msgs = [_]Message{.{
        .role = "assistant",
        .content = "",
        .tool_calls = &.{.{ .id = "c1", .name = "bash", .args = "{}" }},
        .reasoning = "step",
        .thinking_signature = "sig",
    }};
    const replay = try serializeAnthropicThink(a, "claude-sonnet-4-6", &replay_msgs, &.{}, 100, .high, sonnet.think_map, true, sonnet_c, .{}, 0, .short);
    try t.expect(std.mem.indexOf(u8, replay, "\"type\":\"thinking\",\"thinking\":\"step\",\"signature\":\"sig\"") != null);

    const nosig = [_]Message{.{
        .role = "assistant",
        .content = "hi",
        .reasoning = "step",
    }};
    const as_text = try serializeAnthropicThink(a, "m", &nosig, &.{}, 100, .off, .{}, false, .{}, .{}, 0, .short);
    try t.expect(std.mem.indexOf(u8, as_text, "\"type\":\"text\",\"text\":\"step\"") != null);
    try t.expect(std.mem.indexOf(u8, as_text, "\"type\":\"thinking\"") == null);
}

test "OpenAI chat and responses thinking match pi" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{.{ .role = "user", .content = "hi" }};
    const chat = cfgmod.Provider{
        .name = "openai",
        .api = .openai_completions,
        .base_url = "https://api.openai.com/v1",
    };
    const resp = cfgmod.Provider{
        .name = "openai",
        .api = .openai_responses,
        .base_url = "https://api.openai.com/v1",
    };
    const chat_meta = cfgmod.metaFor(&chat, "gpt-5.4");
    const chat_c = cfgmod.resolveCompat(&chat, "gpt-5.4");
    const chat_xhigh = try serializeOpenAIThink(a, "gpt-5.4", &msgs, &.{}, 100, null, .xhigh, chat_meta.think_map, true, chat_c);
    try t.expect(std.mem.indexOf(u8, chat_xhigh, "\"reasoning_effort\":\"xhigh\"") != null);
    try t.expect(std.mem.indexOf(u8, chat_xhigh, "\"thinking\"") == null);
    const chat_off = try serializeOpenAIThink(a, "gpt-5.4", &msgs, &.{}, 100, null, .off, chat_meta.think_map, true, chat_c);
    try t.expect(std.mem.indexOf(u8, chat_off, "reasoning_effort") == null);

    const resp_meta = cfgmod.metaFor(&resp, "gpt-5.4");
    const on = try serializeResponses(a, "gpt-5.4", &msgs, &.{}, 100, .high, resp_meta.think_map, true, .{});
    try t.expect(std.mem.indexOf(u8, on, "\"effort\":\"high\"") != null);
    try t.expect(std.mem.indexOf(u8, on, "\"summary\":\"auto\"") != null);
    try t.expect(std.mem.indexOf(u8, on, "\"include\":[\"reasoning.encrypted_content\"]") != null);
    const off = try serializeResponses(a, "gpt-5.4", &msgs, &.{}, 100, .off, resp_meta.think_map, true, .{});
    try t.expect(std.mem.indexOf(u8, off, "\"reasoning\":{\"effort\":\"none\"}") != null);
    try t.expect(std.mem.indexOf(u8, off, "include") == null);

    const hidden_off = cfgmod.metaFor(&resp, "gpt-5.6");
    const hidden = try serializeResponses(a, "gpt-5.6", &msgs, &.{}, 100, .off, hidden_off.think_map, true, .{});
    try t.expect(std.mem.indexOf(u8, hidden, "\"reasoning\"") == null);

    const item =
        \\{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"cot"}],"encrypted_content":"enc"}
    ;
    const replay_msgs = [_]Message{.{
        .role = "assistant",
        .content = "",
        .tool_calls = &.{.{ .id = "c1", .name = "bash", .args = "{}" }},
        .thinking_signature = item,
    }};
    const replay = try serializeResponses(a, "gpt-5.4", &replay_msgs, &.{}, 100, .high, resp_meta.think_map, true, .{});
    try t.expect(std.mem.indexOf(u8, replay, item) != null);
    try t.expect(std.mem.indexOf(u8, replay, "\"type\":\"function_call\"").? > std.mem.indexOf(u8, replay, "\"encrypted_content\":\"enc\"").?);

    var out_text = std.array_list.Managed(u8).init(a);
    var out_reasoning = std.array_list.Managed(u8).init(a);
    var out_signature = std.array_list.Managed(u8).init(a);
    var usage = Usage{};
    var finish = std.array_list.Managed(u8).init(a);
    var errs = std.array_list.Managed(u8).init(a);
    var acc = std.array_list.Managed(ToolAcc).init(a);
    const done =
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"cot"}]}}
    ;
    try parseResponsesEvent(a, done, &acc, .{}, &out_text, &out_reasoning, &out_signature, &usage, &finish, &errs);
    try t.expect(std.mem.indexOf(u8, out_signature.items, "\"id\":\"rs_1\"") != null);
    try t.expect(std.mem.indexOf(u8, out_signature.items, "encrypted_content") == null);
    const completed =
        \\{"type":"response.completed","response":{"output":[{"type":"reasoning","id":"rs_1","encrypted_content":"enc","summary":[]}]}}
    ;
    try parseResponsesEvent(a, completed, &acc, .{}, &out_text, &out_reasoning, &out_signature, &usage, &finish, &errs);
    try t.expect(std.mem.indexOf(u8, out_signature.items, "\"encrypted_content\":\"enc\"") != null);

    var result = RunResult{};
    var json_text = std.array_list.Managed(u8).init(a);
    var json_reason = std.array_list.Managed(u8).init(a);
    var json_sig = std.array_list.Managed(u8).init(a);
    const body =
        \\{"output":[{"type":"reasoning","id":"rs_2","summary":[{"type":"summary_text","text":"why"}],"encrypted_content":"blob"},{"type":"message","content":[{"type":"output_text","text":"hi"}]}]}
    ;
    try parseResponsesJson(a, body, .{}, &result, &json_text, &json_reason, &json_sig, &usage);
    try t.expectEqualStrings("hi", json_text.items);
    try t.expectEqualStrings("why", json_reason.items);
    try t.expect(std.mem.indexOf(u8, json_sig.items, "\"encrypted_content\":\"blob\"") != null);
}

test "invalid utf8 in tool output still serializes as a JSON string" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 汉字被切在序列中间 —— 工具输出砍字节数时的常态。
    // "会话级" 的 UTF-8 是 e4bc9a e8af9d e7baa7;这里砍掉最后一个字节。
    const truncated = "// agents.zig — \xe4\xbc\x9a\xe8\xaf\x9d\xe7\xba";
    try t.expect(!std.unicode.utf8ValidateSlice(truncated));

    const msgs = [_]Message{
        .{ .role = "user", .content = "go" },
        .{ .role = "tool", .content = truncated, .tool_call_id = "c1" },
    };

    // 两个协议都必须写出**字符串**。std.json.Stringify 对非法 UTF-8 的
    // []const u8 会静默退化成整数数组,provider 拿到 "content":[91,65,...]
    // 直接 400,而报错内容(“expected ContentBlock”)跟真实原因毫无关系。
    inline for (.{ true, false }) |openai| {
        const body = if (openai)
            try serializeOpenAI(a, "m", &msgs, &.{}, 100, null)
        else
            try serializeAnthropic(a, "m", &msgs, &.{}, 100);
        // 合法 JSON 是底线
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        // content 是字符串,不是数组
        const arr = parsed.value.object.get("messages").?.array;
        var saw_tool_text = false;
        for (arr.items) |m| {
            const c = m.object.get("content") orelse continue;
            switch (c) {
                .string => |s| {
                    if (std.mem.indexOf(u8, s, "agents.zig") != null) saw_tool_text = true;
                },
                // anthropic 把 tool 结果包成 content 块数组,块里的 content 才是文本
                .array => |blocks| for (blocks.items) |b| {
                    const inner = b.object.get("content") orelse continue;
                    if (inner == .string and std.mem.indexOf(u8, inner.string, "agents.zig") != null) {
                        saw_tool_text = true;
                    }
                    // 非字符串就是退化成了整数数组 —— 正是要防的
                    try t.expect(inner != .integer);
                },
                else => return error.ContentIsNotText,
            }
        }
        try t.expect(saw_tool_text);
    }
}

test "text tool-call markers are withheld from the stream" {
    const t = std.testing;

    // 收集 on_text 实际外发的内容
    const Sink = struct {
        var buf: [4096]u8 = undefined;
        var len: usize = 0;
        fn reset() void {
            len = 0;
        }
        fn cb(_: ?*anyopaque, text: []const u8) anyerror!void {
            @memcpy(buf[len .. len + text.len], text);
            len += text.len;
        }
        fn got() []const u8 {
            return buf[0..len];
        }
    };
    const cbs = Callbacks{ .on_text = Sink.cb };

    // 按 chunk 喂进去,模拟流式
    const feed = struct {
        fn go(c: Callbacks, chunks: []const []const u8) !void {
            Sink.reset();
            var acc = std.array_list.Managed(u8).init(std.testing.allocator);
            defer acc.deinit();
            for (chunks) |ch| {
                try acc.appendSlice(ch);
                try emitText(c, acc.items, ch);
            }
        }
    }.go;

    // 干净文本原样透传
    try feed(cbs, &.{ "hello ", "world" });
    try t.expectEqualStrings("hello world", Sink.got());

    // 标记在一个 chunk 内 —— 之前的留下,标记及之后全部扣住
    try feed(cbs, &.{"answer: <｜｜DSML｜｜tool_calls>\n<｜｜DSML｜｜invoke name=\"bash\">"});
    try t.expectEqualStrings("answer: ", Sink.got());

    // 标记被 chunk 边界切开 —— 半截前缀也必须立刻闭嘴,
    // 否则 `<｜｜DS` 已经印在屏幕上了
    try feed(cbs, &.{ "text <｜｜DS", "ML｜｜tool_calls>" });
    try t.expectEqualStrings("text ", Sink.got());

    // 逐字节流式:最坏情况
    var bytes: [64][]const u8 = undefined;
    const src = "ok <｜｜DSML｜｜tool_calls>";
    var n: usize = 0;
    for (src, 0..) |_, i| {
        bytes[n] = src[i .. i + 1];
        n += 1;
    }
    try feed(cbs, bytes[0..n]);
    try t.expectEqualStrings("ok ", Sink.got());

    // 标记之后就算又出现正常文本也不放行 —— 那都是伪造调用的内容
    try feed(cbs, &.{ "a<｜｜DSML｜｜x", "more text here" });
    try t.expectEqualStrings("a", Sink.got());

    // 全角竖线不能和 ASCII 竖线混淆:正常文本里的 | 不该触发
    try feed(cbs, &.{"pipe | char and <|not a marker|>"});
    try t.expectEqualStrings("pipe | char and <|not a marker|>", Sink.got());
}

test "escapes survive the invalid-utf8 slow path" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 非法字节触发慢路径,同一份内容里还有必须转义的字符。
    // 慢路径自己做转义,漏了就产出非法 JSON。
    const nasty = "say \"hi\"\n\ttab\\slash \x1b[0m \xff end";
    const msgs = [_]Message{.{ .role = "tool", .content = nasty, .tool_call_id = "c" }};
    const body = try serializeOpenAI(a, "m", &msgs, &.{}, 100, null);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const got = parsed.value.object.get("messages").?.array.items[0].object.get("content").?.string;
    // 往返之后合法字符原样留存,只有非法字节变成替换符
    try t.expect(std.mem.indexOf(u8, got, "say \"hi\"") != null);
    try t.expect(std.mem.indexOf(u8, got, "\n\ttab\\slash") != null);
    try t.expect(std.mem.indexOf(u8, got, "\x1b[0m") != null);
    try t.expect(std.mem.indexOf(u8, got, "\u{fffd}") != null);
}

test "parse streamed usage with cache hit" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var acc = std.array_list.Managed(ToolAcc).init(a);
    defer acc.deinit();
    var out_text = std.array_list.Managed(u8).init(a);
    defer out_text.deinit();
    var out_reasoning = std.array_list.Managed(u8).init(a);
    defer out_reasoning.deinit();
    var finish = std.array_list.Managed(u8).init(a);
    defer finish.deinit();
    var usage: Usage = .{};

    // deepseek 流式 usage chunk(include_usage):含 prompt_cache_hit_tokens
    const chunk =
        "{\"id\":\"x\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":40000,\"completion_tokens\":100,\"total_tokens\":40100,\"prompt_cache_hit_tokens\":39000,\"prompt_cache_miss_tokens\":1000}}";
    try parseOpenAIChunk(a, a, chunk, &acc, .{}, &out_text, &out_reasoning, &usage, &finish);
    try t.expectEqual(@as(?u64, 40000), usage.input);
    try t.expectEqual(@as(?u64, 100), usage.output);
    try t.expectEqual(@as(?u64, 39000), usage.cache_read);
    try t.expectEqualStrings("stop", finish.items);
}

test "parse streamed usage prefers remote cost" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var acc = std.array_list.Managed(ToolAcc).init(a);
    defer acc.deinit();
    var out_text = std.array_list.Managed(u8).init(a);
    defer out_text.deinit();
    var out_reasoning = std.array_list.Managed(u8).init(a);
    defer out_reasoning.deinit();
    var finish = std.array_list.Managed(u8).init(a);
    defer finish.deinit();
    var usage: Usage = .{};
    const chunk =
        "{\"id\":\"x\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"cost\":0.00125}}";
    try parseOpenAIChunk(a, a, chunk, &acc, .{}, &out_text, &out_reasoning, &usage, &finish);
    try t.expect(usage.cost != null);
    try t.expectApproxEqAbs(@as(f64, 0.00125), usage.cost.?, 1e-9);
}

test "anthropic request carries a cache breakpoint on system" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{
        .{ .role = "system", .content = "long system prompt with project rules" },
        .{ .role = "user", .content = "hi" },
    };
    var defs = [_]ToolDef{.{ .name = "read", .desc = "read a file", .schema = "{\"type\":\"object\"}" }};
    const body = try serializeAnthropic(a, "m", &msgs, &defs, 100);

    // system 必须是数组形式(纯字符串挂不了 cache_control)
    try t.expect(std.mem.indexOf(u8, body, "\"system\":[{\"type\":\"text\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
    // 系统提示内容仍然在
    try t.expect(std.mem.indexOf(u8, body, "long system prompt with project rules") != null);

    // 新制三断点(学制 pi-mono):末位 tool(tools 段在 system 前) + system 末块
    // + 末条 user 消息末块。Anthropic 按 tools→system→messages 拼前缀,三处封口。
    const i_tools = std.mem.indexOf(u8, body, "\"tools\":[").?;
    const i_sys = std.mem.indexOf(u8, body, "\"system\":[").?;
    try t.expect(i_tools < i_sys);
    try t.expect(std.mem.indexOf(u8, body[i_tools..i_sys], "\"cache_control\"") != null); // 末位 tool
    try t.expect(std.mem.indexOf(u8, body[i_sys..], "\"cache_control\"") != null); // system 块
    var n_cc: usize = 0;
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, body, scan, "\"cache_control\"")) |p| {
        n_cc += 1;
        scan = p + 1;
    }
    try t.expectEqual(@as(usize, 3), n_cc);
}

test "anthropic cache retention none and long" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{
        .{ .role = "system", .content = "rules" },
        .{ .role = "user", .content = "hi" },
    };
    var defs = [_]ToolDef{.{ .name = "read", .desc = "read a file", .schema = "{\"type\":\"object\"}" }};
    const off = try @import("ai_anthropic.zig").serializeAnthropicThink(a, "m", &msgs, &defs, 100, .off, .{}, false, .{}, .{}, 0, .none);
    try t.expect(std.mem.indexOf(u8, off, "cache_control") == null);
    const long = try @import("ai_anthropic.zig").serializeAnthropicThink(a, "m", &msgs, &defs, 100, .off, .{}, false, .{}, .{}, 0, .long);
    try t.expect(std.mem.indexOf(u8, long, "\"ttl\":\"1h\"") != null);
}

test "no system prompt still seals history on the last user message" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{.{ .role = "user", .content = "hi" }};
    const body = try serializeAnthropic(a, "m", &msgs, &.{}, 100);
    // 没有 system 就不该出现空的 system 数组;断点落在末条 user 消息上。
    try t.expect(std.mem.indexOf(u8, body, "\"system\"") == null);
    try t.expect(std.mem.indexOf(u8, body, "\"content\":[{\"type\":\"text\",\"text\":\"hi\",\"cache_control\":{\"type\":\"ephemeral\"}}]") != null);
}

test "static parts precede messages so the cacheable prefix stays intact" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var defs = [_]ToolDef{.{ .name = "read", .desc = "read a file", .schema = "{\"type\":\"object\"}" }};

    // 两轮:第二轮只在尾部追加消息。静态部分(tools)必须仍在同一位置,
    // 这样服务端重组出的 prompt 前缀才逐字节一致。
    const t1 = [_]Message{
        .{ .role = "system", .content = "rules" },
        .{ .role = "user", .content = "q1" },
    };
    const t2 = [_]Message{
        .{ .role = "system", .content = "rules" },
        .{ .role = "user", .content = "q1" },
        .{ .role = "assistant", .content = "a1" },
        .{ .role = "user", .content = "q2" },
    };
    const b1 = try serializeOpenAI(a, "m", &t1, &defs, 100, null);
    const b2 = try serializeOpenAI(a, "m", &t2, &defs, 100, null);

    // 公共前缀必须覆盖到 messages 开始处 —— 即 tools 整段落在稳定区
    var cp: usize = 0;
    while (cp < b1.len and cp < b2.len and b1[cp] == b2[cp]) cp += 1;
    const i_msgs = std.mem.indexOf(u8, b1, "\"messages\":[").?;
    try t.expect(cp >= i_msgs);

    // tools 在 messages 之前
    try t.expect(std.mem.indexOf(u8, b1, "\"tools\":[").? < i_msgs);
}

test "prompt_cache_key lands in the stable prefix and never on anthropic" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var defs = [_]ToolDef{.{ .name = "read", .desc = "read", .schema = "{\"type\":\"object\"}" }};
    const msgs = [_]Message{
        .{ .role = "system", .content = "rules" },
        .{ .role = "user", .content = "q" },
    };

    const oa = try serializeOpenAI(a, "m", &msgs, &defs, 100, "/home/u/proj");
    const i_key = std.mem.indexOf(u8, oa, "\"prompt_cache_key\":\"/home/u/proj\"");
    try t.expect(i_key != null);
    // 必须在 messages 之前:它属于每轮不变的静态部分
    try t.expect(i_key.? < std.mem.indexOf(u8, oa, "\"messages\":[").?);

    // 空 key 不写字段(别发 "prompt_cache_key":"")
    const empty = try serializeOpenAI(a, "m", &msgs, &defs, 100, "");
    try t.expect(std.mem.indexOf(u8, empty, "prompt_cache_key") == null);
    const none = try serializeOpenAI(a, "m", &msgs, &defs, 100, null);
    try t.expect(std.mem.indexOf(u8, none, "prompt_cache_key") == null);

    // Anthropic Messages API 没有这个字段,发过去是未知字段 —— 绝不能出现
    const an = try serializeAnthropic(a, "m", &msgs, &defs, 100);
    try t.expect(std.mem.indexOf(u8, an, "prompt_cache_key") == null);
}

test "anthropic cache usage fields are parsed from message_start" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var acc = std.array_list.Managed(ToolAcc).init(a);
    defer acc.deinit();
    var out_text = std.array_list.Managed(u8).init(a);
    defer out_text.deinit();
    var out_reasoning = std.array_list.Managed(u8).init(a);
    defer out_reasoning.deinit();
    var finish = std.array_list.Managed(u8).init(a);
    defer finish.deinit();
    var out_sig = std.array_list.Managed(u8).init(a);
    defer out_sig.deinit();
    var redacted = false;
    var usage: Usage = .{};

    // 缓存命中的 message_start:input_tokens 不含缓存部分,读写分列
    const ev =
        "{\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"usage\":{\"input_tokens\":12,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":3200,\"output_tokens\":1}}}";
    try parseAnthropicEvent(a, a, ev, &acc, .{}, &out_text, &out_reasoning, &out_sig, &redacted, &usage, &finish);
    try t.expectEqual(@as(?u64, 12), usage.input);
    try t.expectEqual(@as(?u64, 3200), usage.cache_read);
    try t.expectEqual(@as(?u64, 0), usage.cache_write);

    // 首次写入缓存:read 为 0、write 是实际写入量
    var usage2: Usage = .{};
    const ev2 =
        "{\"type\":\"message_start\",\"message\":{\"id\":\"m2\",\"role\":\"assistant\",\"usage\":{\"input_tokens\":12,\"cache_creation_input_tokens\":3200,\"cache_read_input_tokens\":0,\"output_tokens\":1}}}";
    try parseAnthropicEvent(a, a, ev2, &acc, .{}, &out_text, &out_reasoning, &out_sig, &redacted, &usage2, &finish);
    try t.expectEqual(@as(?u64, 3200), usage2.cache_write);
    try t.expectEqual(@as(?u64, 0), usage2.cache_read);
}

test "openai nested cached_tokens is parsed in the non-stream path" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var acc = std.array_list.Managed(ToolAcc).init(a);
    defer acc.deinit();
    var out_text = std.array_list.Managed(u8).init(a);
    defer out_text.deinit();
    var out_reasoning = std.array_list.Managed(u8).init(a);
    defer out_reasoning.deinit();
    var finish = std.array_list.Managed(u8).init(a);
    defer finish.deinit();
    var usage: Usage = .{};

    // openai / GLM 的路径是嵌套的 prompt_tokens_details.cached_tokens
    const chunk =
        "{\"id\":\"x\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5000,\"completion_tokens\":10,\"prompt_tokens_details\":{\"cached_tokens\":4096}}}";
    try parseOpenAIChunk(a, a, chunk, &acc, .{}, &out_text, &out_reasoning, &usage, &finish);
    try t.expectEqual(@as(?u64, 4096), usage.cache_read);
}

test "cacheable prefix covers tools and system for a realistic request" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 用接近真实体量的系统提示(AGENTS.md 级别)与多个工具定义
    const sys = "PROJECT RULES\n" ++ ("规则条目:保持简洁,不要过度抽象。\n" ** 60);
    var defs = [_]ToolDef{
        .{ .name = "read", .desc = "Read a file with optional line range.", .schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}" },
        .{ .name = "write", .desc = "Write a file, creating parents.", .schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}" },
        .{ .name = "bash", .desc = "Run a shell command.", .schema = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}" },
    };
    const msgs = [_]Message{
        .{ .role = "system", .content = sys },
        .{ .role = "user", .content = "开始任务" },
    };

    const body = try serializeAnthropic(a, "claude-sonnet-5", &msgs, &defs, 8192);
    const i_m = std.mem.indexOf(u8, body, "\",\"stream\":true,\"messages\":[") orelse
        std.mem.indexOf(u8, body, "\"messages\":[").?;

    // 断点之前(tools + system)就是被缓存的前缀。Anthropic 的最小可缓存长度
    // 按模型 512–4096 token,低于阈值静默不缓存 —— 这里确认真实配置远超 1024。
    const prefix_tokens = @import("agent.zig").Agent.estTokensOf(body[0..i_m]);
    try t.expect(prefix_tokens > 1024);

    // 前缀里必须同时含 tools 与 system 的内容
    const prefix = body[0..i_m];
    try t.expect(std.mem.indexOf(u8, prefix, "\"name\":\"bash\"") != null);
    try t.expect(std.mem.indexOf(u8, prefix, "PROJECT RULES") != null);
    try t.expect(std.mem.indexOf(u8, prefix, "\"cache_control\"") != null);
}

// 压缩对缓存前缀的影响。codex 明令禁止 history rewrite(AGENTS.md「No history
// rewrite - the context must be built up incrementally」),它把摘要 **push 到
// 末尾**;piz 是摘要置前 + clearRetainingCapacity,整段 messages 重写。
//
// 这个测试把差异钉成数字:置前保住的共同前缀只到 messages 开头,追加能保住
// 全部旧消息。tools/system 排在 messages 之前,所以固定成本那段仍然命中 ——
// 这是 piz 选择保留「置前」的前提。
test "compaction placement determines how much request prefix survives" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sys = "SYSTEM PROMPT " ** 150;
    var defs = [_]ToolDef{
        .{ .name = "bash", .desc = "run a command", .schema = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}}}" },
    };

    var pre = std.array_list.Managed(Message).init(a);
    try pre.append(.{ .role = "system", .content = sys });
    const turns = [_][]const u8{ "问题一", "回答一", "问题二", "回答二", "问题三" };
    for (turns, 0..) |c, i| {
        try pre.append(.{ .role = if (i % 2 == 0) "user" else "assistant", .content = c });
    }

    // piz 现状:摘要置前,只保留最近 2 条
    var front = std.array_list.Managed(Message).init(a);
    try front.append(.{ .role = "system", .content = sys });
    try front.append(.{ .role = "system", .content = "(Conversation compacted. Summary:)\n摘要" });
    try front.appendSlice(pre.items[pre.items.len - 2 ..]);

    // codex 做法:原历史 + 摘要追加到尾
    var tail = std.array_list.Managed(Message).init(a);
    try tail.appendSlice(pre.items);
    try tail.append(.{ .role = "user", .content = "(Conversation compacted. Summary:)\n摘要" });

    const b_pre = try serializeOpenAI(a, "m", pre.items, &defs, 100, null);
    const b_front = try serializeOpenAI(a, "m", front.items, &defs, 100, null);
    const b_tail = try serializeOpenAI(a, "m", tail.items, &defs, 100, null);

    const shared = struct {
        fn len(x: []const u8, y: []const u8) usize {
            var i: usize = 0;
            while (i < @min(x.len, y.len) and x[i] == y[i]) i += 1;
            return i;
        }
    };
    const keep_front = shared.len(b_pre, b_front);
    const keep_tail = shared.len(b_pre, b_tail);

    // 追加严格优于置前 —— 这是 codex 那条规则的量化依据
    try t.expect(keep_tail > keep_front);

    // 但置前**仍然**保住 tools + system:固定成本(实测约 3217 token/轮)照旧命中。
    // 作废的只是对话消息那段,而它本来每轮都在变。
    const i_m = std.mem.indexOf(u8, b_pre, "\"messages\":[").?;
    try t.expect(keep_front >= i_m);
    try t.expect(std.mem.indexOf(u8, b_front[0..keep_front], "\"name\":\"bash\"") != null);
}

test "serializeAnthropic tool result" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{
        .{ .role = "user", .content = "hi" },
        .{ .role = "tool", .content = "ok", .tool_call_id = "t1" },
    };
    const body = try serializeAnthropic(a, "m", &msgs, &.{}, 100);
    try t.expect(std.mem.indexOf(u8, body, "\"tool_result\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"tool_use_id\":\"t1\"") != null);
}

test "system prompt reaches the model on both protocols" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{
        .{ .role = "system", .content = "RULE: reply in Chinese" },
        .{ .role = "user", .content = "hi" },
    };

    // openai:system 作为 messages 数组里的一条
    const oa = try serializeOpenAI(a, "m", &msgs, &.{}, 100, null);
    try t.expect(std.mem.indexOf(u8, oa, "RULE: reply in Chinese") != null);
    try t.expect(std.mem.indexOf(u8, oa, "\"role\":\"system\"") != null);

    // anthropic:system 走顶层字段(数组形式,带缓存断点),不出现在 messages 数组里
    const an = try serializeAnthropic(a, "m", &msgs, &.{}, 100);
    try t.expect(std.mem.indexOf(u8, an, "\"system\":[{\"type\":\"text\",\"text\":\"RULE: reply in Chinese\"") != null);
    const msgs_start = std.mem.indexOf(u8, an, "\"messages\":[").?;
    try t.expect(std.mem.indexOf(u8, an[msgs_start..], "\"role\":\"system\"") == null);
}

test "multiple system messages concatenate for anthropic" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 压缩摘要也是 system 角色 —— 两条都必须送达
    const msgs = [_]Message{
        .{ .role = "system", .content = "base prompt" },
        .{ .role = "system", .content = "(Conversation compacted. Summary:)\nearlier work" },
        .{ .role = "user", .content = "next" },
    };
    const an = try serializeAnthropic(a, "m", &msgs, &.{}, 100);
    try t.expect(std.mem.indexOf(u8, an, "base prompt") != null);
    try t.expect(std.mem.indexOf(u8, an, "earlier work") != null);
    // 拼接顺序:base 在摘要之前
    const i_base = std.mem.indexOf(u8, an, "base prompt").?;
    const i_sum = std.mem.indexOf(u8, an, "earlier work").?;
    try t.expect(i_base < i_sum);
}

test "no system field when there is no system message" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{.{ .role = "user", .content = "hi" }};
    const an = try serializeAnthropic(a, "m", &msgs, &.{}, 100);
    // 空 system 不该写出 "system":"" —— Anthropic 会拒绝空字符串
    try t.expect(std.mem.indexOf(u8, an, "\"system\"") == null);
}

test "tool defs carry real json schema to both providers" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{.{ .role = "user", .content = "hi" }};
    const defs = [_]ToolDef{
        .{
            .name = "read",
            .desc = "Read a file.",
            .schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}",
        },
        // 空 schema 退化为无参数对象(不能漏字段,否则 provider 报 400)
        .{ .name = "git_status", .desc = "Show git status." },
    };

    const oa = try serializeOpenAI(a, "m", &msgs, &defs, 100, null);
    try t.expect(std.mem.indexOf(u8, oa, "\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}") != null);
    try t.expect(std.mem.indexOf(u8, oa, "\"parameters\":{\"type\":\"object\",\"properties\":{}}") != null);
    // 旧 bug 回归:desc 曾被塞进 args 字段,schema 恒为空
    try t.expect(std.mem.indexOf(u8, oa, "\"description\":\"Read a file.\"") != null);

    const an = try serializeAnthropic(a, "m", &msgs, &defs, 100);
    try t.expect(std.mem.indexOf(u8, an, "\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}") != null);
    try t.expect(std.mem.indexOf(u8, an, "\"input_schema\":{\"type\":\"object\",\"properties\":{}}") != null);
}

test "every registered tool ships a parseable schema" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 契约:任何工具的 schema 要么为空(退化),要么是合法 JSON object 且 type=object。
    // 防止新增插件工具时写坏 schema 字面量导致 provider 400。
    for (&@import("tools.zig").tools) |*tool| {
        if (tool.schema.len == 0) continue;
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, tool.schema, .{});
        try t.expect(v == .object);
        const ty = v.object.get("type") orelse return error.SchemaMissingType;
        try t.expectEqualStrings("object", ty.string);
    }
}

test "reasoning arrives under either field name, never doubled" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Case = struct { json: []const u8, want: []const u8 };
    const cases = [_]Case{
        // DeepSeek 系
        .{ .json = "{\"choices\":[{\"delta\":{\"reasoning_content\":\"aa\"}}]}", .want = "aa" },
        // OpenRouter 等网关只发 reasoning —— 不认它就丢掉整段推理
        .{ .json = "{\"choices\":[{\"delta\":{\"reasoning\":\"bb\"}}]}", .want = "bb" },
        // 实测某网关两个都发且内容相同:只能算一次,否则推理文本翻倍
        .{ .json = "{\"choices\":[{\"delta\":{\"reasoning_content\":\"cc\",\"reasoning\":\"cc\"}}]}", .want = "cc" },
        .{ .json = "{\"choices\":[{\"delta\":{\"reasoning_text\":\"dd\"}}]}", .want = "dd" },
    };

    for (cases) |c| {
        var acc = std.array_list.Managed(ToolAcc).init(a);
        var out_text = std.array_list.Managed(u8).init(a);
        var out_reasoning = std.array_list.Managed(u8).init(a);
        var finish = std.array_list.Managed(u8).init(a);
        var usage: Usage = .{};
        try parseOpenAIChunk(a, a, c.json, &acc, .{}, &out_text, &out_reasoning, &usage, &finish);
        try t.expectEqualStrings(c.want, out_reasoning.items);
        // 推理不许漏进正文 —— 那会让思考过程冒充答案
        try t.expectEqualStrings("", out_text.items);
    }
}

test "image messages serialize to content arrays on both protocols" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const msgs = [_]Message{
        .{ .role = "user", .content = "look at this", .image = "AAAA", .image_mime = "image/png", .image_w = 10, .image_h = 20 },
    };
    const body = try serializeOpenAI(a, "m", &msgs, &.{}, 100, null);
    try t.expect(std.mem.indexOf(u8, body, "\"content\":[{\"type\":\"text\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,AAAA\"}") != null);

    const asst_img = [_]Message{.{
        .role = "assistant",
        .content = "see",
        .image = "BBBB",
        .image_mime = "image/png",
        .reasoning = "cot",
    }};
    const ds_c = cfgmod.Compat{ .think_format = .deepseek, .requires_reasoning_content = true };
    const replay_img = try serializeOpenAIThink(a, "m", &asst_img, &.{}, 100, null, .high, .{}, true, ds_c);
    try t.expect(std.mem.indexOf(u8, replay_img, "\"reasoning_content\":\"cot\"") != null);

    const body2 = try serializeAnthropic(a, "m", &msgs, &.{}, 100);
    try t.expect(std.mem.indexOf(u8, body2, "\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"AAAA\"}") != null);
}

test "clampProviderImages drops oldest images past the cap" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var msgs: [25]Message = undefined;
    for (&msgs, 0..) |*m, i| m.* = .{ .role = "user", .content = "x", .image = if (i < 25) "img" else null };
    const clamped = try clampProviderImages(a, &msgs, .openai_completions);
    // 20 张上限:5 张最老的被替换为省略标记
    var kept: usize = 0;
    var omitted: usize = 0;
    for (clamped) |m| {
        if (m.image != null) kept += 1;
        if (std.mem.eql(u8, m.content, "[image omitted: provider image limit]")) omitted += 1;
    }
    try t.expectEqual(@as(usize, 20), kept);
    try t.expectEqual(@as(usize, 5), omitted);
    // 原消息未被修改(浅拷贝)
    try t.expect(msgs[0].image != null);
}
