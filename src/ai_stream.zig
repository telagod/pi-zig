// ai_stream.zig — SSE stream + non-stream response parsers. Split from ai.zig.
const std = @import("std");
const httpc = @import("httpc.zig");
const markers = @import("ai_markers.zig");
const textMarkerStart = markers.textMarkerStart;
const types = @import("ai_types.zig");
const ajson = @import("ai_json.zig");

pub const Callbacks = types.Callbacks;
pub const RunResult = types.RunResult;
pub const Usage = types.Usage;
pub const ToolCall = types.ToolCall;

pub const ToolAcc = struct {
    id: std.array_list.Managed(u8),
    name: std.array_list.Managed(u8),
    args: std.array_list.Managed(u8),
    started: bool = false,
    finished: bool = false,
};

pub fn emitCallback(cbs: Callbacks, cb: ?*const fn (ctx: ?*anyopaque, text: []const u8) anyerror!void, text: []const u8) !void {
    if (cb) |f| try f(cbs.ctx, text);
}

/// 正文 chunk 专用:模型把工具调用写成正文时(deepseek 漏 `<｜｜DSML｜｜` 这类
/// 特殊 token 字面量),标记之后的内容一律不外发。
///
/// 必须在流式层拦:文本是一边收一边打到 stdout 的,等整轮结束再判断已经晚了 ——
/// 标记早就印在用户屏幕上,收不回来。agent 层的重试负责让模型重答,这里只
/// 负责别把垃圾漏出去。
///
/// `accumulated` 是**含本 chunk**的全部正文,所以标记跨 chunk 拆开也能认出来。
pub fn emitText(cbs: Callbacks, accumulated: []const u8, chunk: []const u8) !void {
    const cut = textMarkerStart(accumulated) orelse {
        try emitCallback(cbs, cbs.on_text, chunk);
        return;
    };
    // 标记起点在本 chunk 之前 → 整块丢掉;落在本 chunk 内 → 只发前半截
    const chunk_start = accumulated.len - chunk.len;
    if (cut <= chunk_start) return;
    try emitCallback(cbs, cbs.on_text, accumulated[chunk_start..cut]);
}

fn takeUsageCost(u: std.json.Value) ?f64 {
    if (u != .object) return null;
    const keys = [_][]const u8{ "cost", "total_cost", "cost_usd" };
    for (keys) |k| {
        const v = u.object.get(k) orelse continue;
        switch (v) {
            .float => |f| return f,
            .integer => |i| return @floatFromInt(i),
            .number_string => |s| return std.fmt.parseFloat(f64, s) catch continue,
            else => {},
        }
    }
    return null;
}

/// 解析单个 OpenAI 流式 chunk,返回是否消耗。
pub fn parseOpenAIChunk(alloc: std.mem.Allocator, arena: std.mem.Allocator, chunk: []const u8, acc: *std.array_list.Managed(ToolAcc), cbs: Callbacks, out_text: *std.array_list.Managed(u8), out_reasoning: *std.array_list.Managed(u8), usage: *Usage, finish: *std.array_list.Managed(u8)) !void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, chunk, .{}) catch return;
    const v = root;
    if (v != .object) return;
    if (v.object.get("usage")) |u| {
        if (u == .object) {
            if (takeUsageCost(u)) |c| usage.cost = c;
            if (u.object.get("prompt_tokens")) |pt| {
                if (pt == .integer) usage.input = @intCast(pt.integer);
            }
            if (u.object.get("completion_tokens")) |ct| {
                if (ct == .integer) usage.output = @intCast(ct.integer);
            }
            if (u.object.get("total_tokens")) |tt| {
                if (tt == .integer and usage.input == null) usage.input = @intCast(tt.integer);
            }
            // 缓存命中(deepseek: prompt_cache_hit_tokens;openai: prompt_tokens_details.cached_tokens)
            if (u.object.get("prompt_cache_hit_tokens")) |ch| {
                if (ch == .integer) usage.cache_read = @intCast(ch.integer);
            }
            if (usage.cache_read == null) {
                if (u.object.get("prompt_tokens_details")) |pd| {
                    if (pd == .object) {
                        if (pd.object.get("cached_tokens")) |ct2| {
                            if (ct2 == .integer) usage.cache_read = @intCast(ct2.integer);
                        }
                    }
                }
            }
        }
    }
    const choices = v.object.get("choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) return;
    const choice = choices.array.items[0];
    if (choice != .object) return;
    if (choice.object.get("finish_reason")) |fr| {
        if (fr == .string) try finish.appendSlice(fr.string);
    }
    const delta = choice.object.get("delta") orelse return;
    if (delta != .object) return;
    if (delta.object.get("content")) |c| {
        if (c == .string and c.string.len > 0) {
            try out_text.appendSlice(c.string);
            try emitText(cbs, out_text.items, c.string);
        }
    }
    // pi openai-completions.ts:reasoning_content → reasoning → reasoning_text,
    // 只取第一个非空,避免双字段翻倍。
    if (ajson.firstReasoningText(delta.object)) |rc| {
        try out_reasoning.appendSlice(rc);
        try emitCallback(cbs, cbs.on_reasoning, rc);
    }
    if (delta.object.get("tool_calls")) |tcs| {
        if (tcs != .array) return;
        for (tcs.array.items) |tc| {
            if (tc != .object) continue;
            const idx = if (tc.object.get("index")) |i| (if (i == .integer) @as(usize, @intCast(i.integer)) else 0) else 0;
            while (acc.items.len <= idx) {
                try acc.append(.{ .id = std.array_list.Managed(u8).init(alloc), .name = std.array_list.Managed(u8).init(alloc), .args = std.array_list.Managed(u8).init(alloc) });
            }
            const slot = &acc.items[idx];
            if (tc.object.get("id")) |id| {
                if (id == .string and slot.id.items.len == 0) try slot.id.appendSlice(id.string);
            }
            if (tc.object.get("function")) |f| {
                if (f == .object) {
                    if (f.object.get("name")) |n| {
                        if (n == .string and slot.name.items.len == 0) try slot.name.appendSlice(n.string);
                    }
                    if (f.object.get("arguments")) |a| {
                        if (a == .string) try slot.args.appendSlice(a.string);
                    }
                }
            }
            slot.started = true;
        }
    }
    _ = arena;
}

pub fn finalizeToolCalls(alloc: std.mem.Allocator, acc: *std.array_list.Managed(ToolAcc)) ![]ToolCall {
    var out = std.array_list.Managed(ToolCall).init(alloc);
    for (acc.items) |*slot| {
        if (!slot.started) continue;
        try out.append(.{
            .id = try slot.id.toOwnedSlice(),
            .name = try slot.name.toOwnedSlice(),
            .args = try slot.args.toOwnedSlice(),
        });
    }
    return out.toOwnedSlice();
}

pub fn freeToolAcc(acc: *std.array_list.Managed(ToolAcc)) void {
    for (acc.items) |*slot| {
        slot.id.deinit();
        slot.name.deinit();
        slot.args.deinit();
    }
    acc.deinit();
}

fn responsesItemEncrypted(obj: std.json.ObjectMap) bool {
    if (obj.get("encrypted_content")) |v| {
        return v == .string and v.string.len > 0;
    }
    return false;
}

/// 把 reasoning item 整段 JSON 存进 thinking_signature,下一轮原样回放。
fn captureResponsesReasoning(alloc: std.mem.Allocator, item: std.json.Value, out_signature: *std.array_list.Managed(u8)) !void {
    if (item != .object) return;
    const ty = if (item.object.get("type")) |t| (if (t == .string) t.string else "") else "";
    if (!std.mem.eql(u8, ty, "reasoning")) return;
    const incoming_enc = responsesItemEncrypted(item.object);
    if (out_signature.items.len > 0) {
        const old = std.json.parseFromSliceLeaky(std.json.Value, alloc, out_signature.items, .{}) catch {
            out_signature.clearRetainingCapacity();
            const json = try std.json.Stringify.valueAlloc(alloc, item, .{});
            try out_signature.appendSlice(json);
            return;
        };
        if (old == .object and responsesItemEncrypted(old.object) and !incoming_enc) return;
    }
    out_signature.clearRetainingCapacity();
    const json = try std.json.Stringify.valueAlloc(alloc, item, .{});
    try out_signature.appendSlice(json);
}

fn backfillResponsesReasoning(alloc: std.mem.Allocator, output: std.json.Value, out_signature: *std.array_list.Managed(u8)) !void {
    if (output != .array) return;
    for (output.array.items) |item| {
        try captureResponsesReasoning(alloc, item, out_signature);
    }
}

/// 解析 Responses API 的一个 SSE 事件。
/// 事件模型与 Completions 完全不同:文本走 response.output_text.delta,
/// 工具走 output_item.added + function_call_arguments.delta/done,
/// usage 与结束在 response.completed。
pub fn parseResponsesEvent(alloc: std.mem.Allocator, chunk: []const u8, acc: *std.array_list.Managed(ToolAcc), cbs: Callbacks, out_text: *std.array_list.Managed(u8), out_reasoning: *std.array_list.Managed(u8), out_signature: *std.array_list.Managed(u8), usage: *Usage, finish: *std.array_list.Managed(u8), err_out: *std.array_list.Managed(u8)) !void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, chunk, .{}) catch return;
    const v = root;
    if (v != .object) return;
    const ty = if (v.object.get("type")) |t| (if (t == .string) t.string else "") else "";

    if (std.mem.eql(u8, ty, "response.output_text.delta")) {
        if (v.object.get("delta")) |d| {
            if (d == .string and d.string.len > 0) {
                try out_text.appendSlice(d.string);
                try emitText(cbs, out_text.items, d.string);
            }
        }
    } else if (std.mem.eql(u8, ty, "response.reasoning_summary_text.delta") or std.mem.eql(u8, ty, "response.reasoning_text.delta")) {
        // 推理摘要/思维链:展示用,不参与最终文本
        if (v.object.get("delta")) |d| {
            if (d == .string and d.string.len > 0) {
                try out_reasoning.appendSlice(d.string);
                try emitCallback(cbs, cbs.on_reasoning, d.string);
            }
        }
    } else if (std.mem.eql(u8, ty, "response.output_item.added")) {
        if (v.object.get("item")) |it| {
            if (it == .object) {
                if (it.object.get("type")) |it_t| {
                    if (it_t == .string and std.mem.eql(u8, it_t.string, "function_call")) {
                        const slot_idx = acc.items.len;
                        try acc.append(.{ .id = std.array_list.Managed(u8).init(alloc), .name = std.array_list.Managed(u8).init(alloc), .args = std.array_list.Managed(u8).init(alloc) });
                        const slot = &acc.items[slot_idx];
                        slot.started = true; // finalizeToolCalls 只收已开始的调用
                        if (it.object.get("call_id")) |id| {
                            if (id == .string) try slot.id.appendSlice(id.string);
                        }
                        if (it.object.get("name")) |n| {
                            if (n == .string) try slot.name.appendSlice(n.string);
                        }
                        // 有些实现直接把完整 arguments 放在 item 里
                        if (it.object.get("arguments")) |a| {
                            if (a == .string) try slot.args.appendSlice(a.string);
                        }
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, ty, "response.function_call_arguments.delta")) {
        if (v.object.get("delta")) |d| {
            if (d == .string and d.string.len > 0) {
                if (acc.items.len > 0) try acc.items[acc.items.len - 1].args.appendSlice(d.string);
            }
        }
    } else if (std.mem.eql(u8, ty, "response.output_item.done")) {
        if (v.object.get("item")) |it| {
            try captureResponsesReasoning(alloc, it, out_signature);
        }
    } else if (std.mem.eql(u8, ty, "response.function_call_arguments.done")) {
        // done 带全量 arguments —— 以它为准覆盖增量拼接(两全其美:只发 delta 的
        // 实现也能用,两者都发的实现拿全量)。
        if (v.object.get("arguments")) |a| {
            if (a == .string and acc.items.len > 0) {
                const slot = &acc.items[acc.items.len - 1];
                slot.args.clearRetainingCapacity();
                try slot.args.appendSlice(a.string);
            }
        }
    } else if (std.mem.eql(u8, ty, "response.completed")) {
        try finish.appendSlice("completed");
        if (v.object.get("response")) |r| {
            if (r == .object) {
                if (r.object.get("usage")) |u| {
                    parseResponsesUsage(u, usage);
                }
                // Azure 有时只在 completed.output 给 encrypted_content(pi #6409)。
                if (r.object.get("output")) |out| {
                    try backfillResponsesReasoning(alloc, out, out_signature);
                }
            }
        }
        if (usage.input == null) {
            if (v.object.get("usage")) |u| parseResponsesUsage(u, usage);
        }
    } else if (std.mem.eql(u8, ty, "response.failed")) {
        if (v.object.get("response")) |r| {
            if (r == .object) {
                if (r.object.get("error")) |e| {
                    if (e == .object) {
                        if (e.object.get("message")) |m| {
                            if (m == .string) try err_out.appendSlice(m.string);
                        }
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, ty, "error")) {
        if (v.object.get("message")) |m| {
            if (m == .string) try err_out.appendSlice(m.string);
        }
    }
}

pub fn parseResponsesUsage(u: std.json.Value, usage: *Usage) void {
    if (u != .object) return;
    if (takeUsageCost(u)) |c| usage.cost = c;
    if (u.object.get("input_tokens")) |it| {
        if (it == .integer) usage.input = @intCast(it.integer);
    }
    if (u.object.get("output_tokens")) |ot| {
        if (ot == .integer) usage.output = @intCast(ot.integer);
    }
    if (u.object.get("input_tokens_details")) |d| {
        if (d == .object) {
            if (d.object.get("cached_tokens")) |ct| {
                if (ct == .integer) usage.cache_read = @intCast(ct.integer);
            }
        }
    }
}

/// Responses API 非流式响应解析(output items)。
pub fn parseResponsesJson(alloc: std.mem.Allocator, body: []const u8, cbs: Callbacks, result: *RunResult, out_text: *std.array_list.Managed(u8), out_reasoning: *std.array_list.Managed(u8), out_signature: *std.array_list.Managed(u8), usage: *Usage) !void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{}) catch return;
    if (root != .object) return;
    if (root.object.get("error")) |e| {
        if (e == .object) {
            if (e.object.get("message")) |m| {
                if (m == .string) {
                    result.error_msg = try std.fmt.allocPrint(alloc, "{s}", .{m.string});
                    return;
                }
            }
        }
    }
    if (root.object.get("usage")) |u| parseResponsesUsage(u, usage);
    if (root.object.get("output")) |out| {
        if (out != .array) return;
        var acc = std.array_list.Managed(ToolAcc).init(alloc);
        defer freeToolAcc(&acc);
        for (out.array.items) |item| {
            if (item != .object) continue;
            const it_t = if (item.object.get("type")) |t| (if (t == .string) t.string else "") else "";
            if (std.mem.eql(u8, it_t, "message")) {
                if (item.object.get("content")) |c| {
                    if (c == .array) {
                        for (c.array.items) |part| {
                            if (part != .object) continue;
                            const pt = if (part.object.get("type")) |t| (if (t == .string) t.string else "") else "";
                            if (std.mem.eql(u8, pt, "output_text") or std.mem.eql(u8, pt, "input_text")) {
                                if (part.object.get("text")) |tx| {
                                    if (tx == .string and tx.string.len > 0) {
                                        try out_text.appendSlice(tx.string);
                                        try emitText(cbs, out_text.items, tx.string);
                                    }
                                }
                            }
                        }
                    }
                }
            } else if (std.mem.eql(u8, it_t, "function_call")) {
                const slot_idx = acc.items.len;
                try acc.append(.{ .id = std.array_list.Managed(u8).init(alloc), .name = std.array_list.Managed(u8).init(alloc), .args = std.array_list.Managed(u8).init(alloc) });
                const slot = &acc.items[slot_idx];
                slot.started = true;
                if (item.object.get("call_id")) |id| {
                    if (id == .string) try slot.id.appendSlice(id.string);
                }
                if (item.object.get("name")) |n| {
                    if (n == .string) try slot.name.appendSlice(n.string);
                }
                if (item.object.get("arguments")) |a| {
                    if (a == .string) try slot.args.appendSlice(a.string);
                }
            } else if (std.mem.eql(u8, it_t, "reasoning")) {
                try captureResponsesReasoning(alloc, item, out_signature);
                if (item.object.get("summary")) |s| {
                    if (s == .array) {
                        for (s.array.items) |part| {
                            if (part != .object) continue;
                            if (part.object.get("text")) |tx| {
                                if (tx == .string and tx.string.len > 0) {
                                    try out_reasoning.appendSlice(tx.string);
                                    try emitCallback(cbs, cbs.on_reasoning, tx.string);
                                }
                            }
                        }
                    }
                }
            }
        }
        result.tool_calls = try finalizeToolCalls(alloc, &acc);
    }
}

/// OpenAI 流式主循环。
pub fn runOpenAIStream(alloc: std.mem.Allocator, arena: std.mem.Allocator, stream: *httpc.Stream, cbs: Callbacks, result: *RunResult, out_text: *std.array_list.Managed(u8), out_reasoning: *std.array_list.Managed(u8), usage: *Usage) !void {
    var acc = std.array_list.Managed(ToolAcc).init(alloc);
    defer freeToolAcc(&acc);
    var finish = std.array_list.Managed(u8).init(alloc);
    defer finish.deinit();
    var parser = httpc.SseParser.init(stream);
    defer parser.deinit();
    while (true) {
        const ev = parser.nextEvent() catch |err| {
            // 读错误:若已请求中止,按中止处理(保留 partial),否则透传
            if (abortRequested(cbs)) {
                result.aborted = true;
                break;
            }
            // 网络抖动导致的中途断流。已收到的内容已经显示给用户了,
            // 丢掉它等于让那半段回复凭空消失。一个字都没收到才算真失败。
            if (out_text.items.len == 0 and out_reasoning.items.len == 0) return err;
            result.stream_interrupted = @errorName(err);
            break;
        };
        if (ev) |e| {
            defer alloc.free(e);
            try parseOpenAIChunk(alloc, arena, e, &acc, cbs, out_text, out_reasoning, usage, &finish);
        } else break;
        if (abortRequested(cbs)) {
            result.aborted = true;
            break;
        }
    }
    result.tool_calls = try finalizeToolCalls(alloc, &acc);
    result.finish_reason = try finish.toOwnedSlice();
    // 不在这里通知「工具要开始了」:那是 agent 层的事实,而且此刻工具还没执行,
    // 甚至可能被权限拒绝或被插件拦下。ai 层只负责协议解析。
    // (原先这里报一次、agent preflight 再报一次,每个工具调用打印两遍。)
}

/// 非流式 OpenAI 响应(个别网关不支持流)。
pub fn parseOpenAIJson(alloc: std.mem.Allocator, body: []const u8, cbs: Callbacks, result: *RunResult, out_text: *std.array_list.Managed(u8), out_reasoning: *std.array_list.Managed(u8), usage: *Usage) !void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{}) catch {
        result.error_msg = "provider returned invalid JSON";
        return;
    };
    const v = root;
    if (v == .object) {
        if (v.object.get("usage")) |u| {
            if (u == .object) {
                if (takeUsageCost(u)) |c| usage.cost = c;
                if (u.object.get("prompt_tokens")) |pt| {
                    if (pt == .integer) usage.input = @intCast(pt.integer);
                }
                if (u.object.get("completion_tokens")) |ct| {
                    if (ct == .integer) usage.output = @intCast(ct.integer);
                }
                // deepseek 把命中数放 usage 顶层;openai / GLM 放
                // usage.prompt_tokens_details.cached_tokens。两条路径都要试。
                if (u.object.get("prompt_cache_hit_tokens")) |ch| {
                    if (ch == .integer) usage.cache_read = @intCast(ch.integer);
                }
                if (usage.cache_read == null) {
                    if (u.object.get("prompt_tokens_details")) |pd| {
                        if (pd == .object) {
                            if (pd.object.get("cached_tokens")) |ct2| {
                                if (ct2 == .integer) usage.cache_read = @intCast(ct2.integer);
                            }
                        }
                    }
                }
            }
        }
        if (v.object.get("choices")) |choices| {
            if (choices == .array and choices.array.items.len > 0) {
                const choice = choices.array.items[0];
                if (choice == .object) {
                    if (choice.object.get("finish_reason")) |fr| {
                        if (fr == .string) result.finish_reason = fr.string;
                    }
                    if (choice.object.get("message")) |msg| {
                        if (msg == .object) {
                            if (msg.object.get("content")) |c| {
                                if (c == .string) {
                                    try out_text.appendSlice(c.string);
                                    try emitText(cbs, out_text.items, c.string);
                                }
                            }
                            if (ajson.firstReasoningText(msg.object)) |rc| {
                                try out_reasoning.appendSlice(rc);
                                try emitCallback(cbs, cbs.on_reasoning, rc);
                            }
                            if (msg.object.get("tool_calls")) |tcs| {
                                if (tcs == .array) {
                                    var calls = std.array_list.Managed(ToolCall).init(alloc);
                                    for (tcs.array.items) |tc| {
                                        if (tc != .object) continue;
                                        var id: []const u8 = "";
                                        var name: []const u8 = "";
                                        var args: []const u8 = "";
                                        if (tc.object.get("id")) |i| {
                                            if (i == .string) id = i.string;
                                        }
                                        if (tc.object.get("function")) |f| {
                                            if (f == .object) {
                                                if (f.object.get("name")) |n| {
                                                    if (n == .string) name = n.string;
                                                }
                                                if (f.object.get("arguments")) |a| {
                                                    if (a == .string) args = a.string;
                                                }
                                            }
                                        }
                                        try calls.append(.{ .id = id, .name = name, .args = args });
                                    }
                                    result.tool_calls = try calls.toOwnedSlice();
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Anthropic 事件解析。
pub fn parseAnthropicEvent(alloc: std.mem.Allocator, arena: std.mem.Allocator, ev: []const u8, acc: *std.array_list.Managed(ToolAcc), cbs: Callbacks, out_text: *std.array_list.Managed(u8), out_reasoning: *std.array_list.Managed(u8), out_signature: *std.array_list.Managed(u8), redacted: *bool, usage: *Usage, finish: *std.array_list.Managed(u8)) !void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, ev, .{}) catch return;
    const v = root;
    if (v != .object) return;
    const etype = ajson.jstr(v, "type") orelse return;
    if (std.mem.eql(u8, etype, "message_start")) {
        if (v.object.get("message")) |msg| {
            if (msg == .object) {
                if (msg.object.get("usage")) |u| {
                    if (u == .object) {
                        if (takeUsageCost(u)) |c| usage.cost = c;
                        if (u.object.get("input_tokens")) |it| {
                            if (it == .integer) usage.input = @intCast(it.integer);
                        }
                        // 缓存统计只在 message_start 的 message.usage 里必然完整
                        // (message_delta 的 usage 不保证带这两个字段)。
                        // 注意 input_tokens **不含**缓存部分:Anthropic 把
                        // 命中与写入分别计在下面两个字段里,要算总输入得三者相加。
                        if (u.object.get("cache_read_input_tokens")) |cr| {
                            if (cr == .integer) usage.cache_read = @intCast(cr.integer);
                        }
                        if (u.object.get("cache_creation_input_tokens")) |cw| {
                            if (cw == .integer) usage.cache_write = @intCast(cw.integer);
                        }
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, etype, "content_block_start")) {
        const idx = if (v.object.get("index")) |i| (if (i == .integer) @as(usize, @intCast(i.integer)) else 0) else 0;
        while (acc.items.len <= idx) {
            try acc.append(.{ .id = std.array_list.Managed(u8).init(alloc), .name = std.array_list.Managed(u8).init(alloc), .args = std.array_list.Managed(u8).init(alloc) });
        }
        const slot = &acc.items[idx];
        if (v.object.get("content_block")) |cb| {
            if (cb == .object) {
                if (cb.object.get("type")) |t| {
                    if (t == .string and std.mem.eql(u8, t.string, "tool_use")) {
                        if (cb.object.get("id")) |id| if (id == .string) try slot.id.appendSlice(id.string);
                        if (cb.object.get("name")) |n| if (n == .string) try slot.name.appendSlice(n.string);
                        slot.started = true;
                    } else if (t == .string and std.mem.eql(u8, t.string, "thinking")) {
                        if (cb.object.get("signature")) |s| {
                            if (s == .string and s.string.len > 0) try out_signature.appendSlice(s.string);
                        }
                    } else if (t == .string and std.mem.eql(u8, t.string, "redacted_thinking")) {
                        redacted.* = true;
                        if (cb.object.get("data")) |d| {
                            if (d == .string) try out_signature.appendSlice(d.string);
                        }
                        try out_reasoning.appendSlice("[Reasoning redacted]");
                        try emitCallback(cbs, cbs.on_reasoning, "[Reasoning redacted]");
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, etype, "content_block_delta")) {
        const idx = if (v.object.get("index")) |i| (if (i == .integer) @as(usize, @intCast(i.integer)) else 0) else 0;
        if (v.object.get("delta")) |d| {
            if (d == .object) {
                if (d.object.get("type")) |t| {
                    if (t == .string) {
                        if (std.mem.eql(u8, t.string, "text_delta")) {
                            if (d.object.get("text")) |txt| {
                                if (txt == .string) {
                                    try out_text.appendSlice(txt.string);
                                    try emitText(cbs, out_text.items, txt.string);
                                }
                            }
                        } else if (std.mem.eql(u8, t.string, "input_json_delta")) {
                            while (acc.items.len <= idx) {
                                try acc.append(.{ .id = std.array_list.Managed(u8).init(alloc), .name = std.array_list.Managed(u8).init(alloc), .args = std.array_list.Managed(u8).init(alloc) });
                            }
                            const slot = &acc.items[idx];
                            if (d.object.get("partial_json")) |pj| {
                                if (pj == .string) try slot.args.appendSlice(pj.string);
                            }
                            slot.started = true;
                        } else if (std.mem.eql(u8, t.string, "thinking_delta")) {
                            if (d.object.get("thinking")) |th| {
                                if (th == .string) {
                                    try out_reasoning.appendSlice(th.string);
                                    try emitCallback(cbs, cbs.on_reasoning, th.string);
                                }
                            }
                        } else if (std.mem.eql(u8, t.string, "signature_delta")) {
                            if (d.object.get("signature")) |s| {
                                if (s == .string) try out_signature.appendSlice(s.string);
                            }
                        }
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, etype, "message_delta")) {
        if (v.object.get("delta")) |d| {
            if (d == .object) {
                if (d.object.get("stop_reason")) |sr| {
                    if (sr == .string) try finish.appendSlice(sr.string);
                }
            }
        }
        if (v.object.get("usage")) |u| {
            if (u == .object) {
                if (u.object.get("output_tokens")) |ot| {
                    if (ot == .integer) usage.output = @intCast(ot.integer);
                }
            }
        }
    }
    _ = arena;
}

fn abortRequested(cbs: Callbacks) bool {
    return if (cbs.on_abort) |f| f(cbs.ctx) else false;
}
