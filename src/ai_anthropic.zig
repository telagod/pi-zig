// ai_anthropic.zig — Anthropic Messages request bodies. Split from ai.zig.
const std = @import("std");
const cfgmod = @import("config.zig");
const types = @import("ai_types.zig");
const ajson = @import("ai_json.zig");

const Message = types.Message;
const ToolDef = types.ToolDef;
const ThinkLevel = types.ThinkLevel;
const writeSchema = ajson.writeSchema;
const writeJsonText = ajson.writeJsonText;

fn hasAnthropicThinkingReplay(m: Message) bool {
    const sig = m.thinking_signature orelse "";
    if (m.thinking_redacted) return sig.len > 0;
    const text = m.reasoning orelse "";
    return text.len > 0 or sig.len > 0;
}

fn writeAnthropicThinkingBlock(writer: *std.Io.Writer, m: Message, allow_empty: bool) !bool {
    if (m.thinking_redacted) {
        const sig = m.thinking_signature orelse return false;
        if (sig.len == 0) return false;
        try writer.writeAll("{\"type\":\"redacted_thinking\",\"data\":");
        try std.json.Stringify.value(sig, .{}, writer);
        try writer.writeByte('}');
        return true;
    }
    const text = m.reasoning orelse "";
    const sig = m.thinking_signature orelse "";
    if (text.len == 0 and sig.len == 0) return false;
    if (sig.len == 0 and !allow_empty) {
        try writer.writeAll("{\"type\":\"text\",\"text\":");
        try writeJsonText(writer, text);
        try writer.writeByte('}');
        return true;
    }
    try writer.writeAll("{\"type\":\"thinking\",\"thinking\":");
    try writeJsonText(writer, text);
    try writer.writeAll(",\"signature\":");
    try std.json.Stringify.value(sig, .{}, writer);
    try writer.writeByte('}');
    return true;
}

fn writeAnthropicThinkParams(
    writer: *std.Io.Writer,
    level: ThinkLevel,
    map: cfgmod.ThinkingLevelMap,
    reasoning: bool,
    compat: cfgmod.Compat,
    budget_tokens: u32,
) !void {
    if (!reasoning) return;
    if (level == .off) {
        if (map.get(.off) != .hidden)
            try writer.writeAll(",\"thinking\":{\"type\":\"disabled\"}");
        return;
    }
    const adaptive = compat.force_adaptive_thinking orelse false;
    if (adaptive) {
        try writer.writeAll(",\"thinking\":{\"type\":\"adaptive\",\"display\":\"summarized\"}");
        const effort = cfgmod.thinkEffort(.{ .think_map = map }, level) orelse switch (level) {
            .minimal, .low => "low",
            .medium => "medium",
            else => "high",
        };
        try writer.writeAll(",\"output_config\":{\"effort\":");
        try std.json.Stringify.value(effort, .{}, writer);
        try writer.writeByte('}');
        return;
    }
    try writer.writeAll(",\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":");
    try writer.print("{d}", .{if (budget_tokens > 0) budget_tokens else 1024});
    try writer.writeAll(",\"display\":\"summarized\"}");
}

pub fn serializeAnthropic(alloc: std.mem.Allocator, model: []const u8, messages: []const Message, tools: []const ToolDef, max_tokens: u32) ![]u8 {
    return serializeAnthropicThink(alloc, model, messages, tools, max_tokens, .off, .{}, false, .{}, .{}, 0);
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
) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    const writer = &aw.writer;
    var send_max = max_tokens;
    var budget_tokens: u32 = 0;
    if (reasoning and think_level != .off and (compat.force_adaptive_thinking orelse false) == false) {
        const adj = cfgmod.adjustMaxTokensForThinking(max_tokens, max_output, think_level, budgets);
        send_max = adj.max_tokens;
        budget_tokens = adj.thinking_budget;
    }
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, writer);
    try writer.writeAll(",\"max_tokens\":");
    try writer.print("{d}", .{send_max});
    if (tools.len > 0) {
        try writer.writeAll(",\"tools\":[");
        for (tools, 0..) |td, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"name\":");
            try std.json.Stringify.value(td.name, .{}, writer);
            try writer.writeAll(",\"description\":");
            try std.json.Stringify.value(td.desc, .{}, writer);
            try writer.writeAll(",\"input_schema\":");
            try writeSchema(writer, td.schema);
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
    }
    {
        var sys = std.Io.Writer.Allocating.init(alloc);
        defer sys.deinit();
        for (messages) |m| {
            if (!std.mem.eql(u8, m.role, "system")) continue;
            if (sys.written().len > 0) try sys.writer.writeAll("\n\n");
            try sys.writer.writeAll(m.content);
        }
        if (sys.written().len > 0) {
            try writer.writeAll(",\"system\":[{\"type\":\"text\",\"text\":");
            try std.json.Stringify.value(sys.written(), .{}, writer);
            try writer.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}}]");
        }
    }
    try writer.writeAll(",\"stream\":true,\"messages\":[");
    var first = true;
    for (messages) |m| {
        if (std.mem.eql(u8, m.role, "system")) continue;
        if (std.mem.eql(u8, m.role, "tool")) {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":");
            try std.json.Stringify.value(m.tool_call_id orelse "", .{}, writer);
            try writer.writeAll(",\"content\":");
            try writeJsonText(writer, m.content);
            try writer.writeAll("}]}");
            first = false;
            continue;
        }
        if (m.tool_calls) |tcs| {
            if (tcs.len == 0) continue;
            if (!first) try writer.writeByte(',');
            try writer.writeAll("{\"role\":\"assistant\",\"content\":[");
            const allow_empty = compat.allow_empty_signature orelse false;
            var need_comma = try writeAnthropicThinkingBlock(writer, m, allow_empty);
            if (m.content.len > 0) {
                if (need_comma) try writer.writeByte(',');
                try writer.writeAll("{\"type\":\"text\",\"text\":");
                try writeJsonText(writer, m.content);
                try writer.writeByte('}');
                need_comma = true;
            }
            for (tcs, 0..) |tc, i| {
                if (i > 0 or need_comma) try writer.writeByte(',');
                try writer.writeAll("{\"type\":\"tool_use\",\"id\":");
                try std.json.Stringify.value(tc.id, .{}, writer);
                try writer.writeAll(",\"name\":");
                try std.json.Stringify.value(tc.name, .{}, writer);
                try writer.writeAll(",\"input\":");
                if (tc.args.len == 0) {
                    try writer.writeAll("{}");
                } else {
                    if (std.json.parseFromSliceLeaky(std.json.Value, alloc, tc.args, .{})) |v| {
                        try std.json.Stringify.value(v, .{}, writer);
                    } else |_| {
                        try std.json.Stringify.value(tc.args, .{}, writer);
                    }
                }
                try writer.writeAll("}");
            }
            try writer.writeAll("]}");
            first = false;
            continue;
        }
        if (!first) try writer.writeByte(',');
        try writer.writeAll("{\"role\":");
        try std.json.Stringify.value(m.role, .{}, writer);
        if (m.image) |img| {
            try writer.writeAll(",\"content\":[{\"type\":\"text\",\"text\":");
            try writeJsonText(writer, m.content);
            try writer.writeAll("},{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
            try std.json.Stringify.value(m.image_mime orelse "image/png", .{}, writer);
            try writer.writeAll(",\"data\":\"");
            try writer.writeAll(img);
            try writer.writeAll("\"}}]}");
        } else if (std.mem.eql(u8, m.role, "assistant") and hasAnthropicThinkingReplay(m)) {
            try writer.writeAll(",\"content\":[");
            const wrote = try writeAnthropicThinkingBlock(writer, m, compat.allow_empty_signature orelse false);
            if (m.content.len > 0) {
                if (wrote) try writer.writeByte(',');
                try writer.writeAll("{\"type\":\"text\",\"text\":");
                try writeJsonText(writer, m.content);
                try writer.writeByte('}');
            }
            try writer.writeAll("]}");
        } else {
            try writer.writeAll(",\"content\":");
            try writeJsonText(writer, m.content);
            try writer.writeAll("}");
        }
        first = false;
    }
    try writer.writeAll("]");
    try writeAnthropicThinkParams(writer, think_level, think_map, reasoning, compat, budget_tokens);
    if (tools.len > 0) {
        try writer.writeAll(",\"tools\":[");
        for (tools, 0..) |td, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"name\":");
            try std.json.Stringify.value(td.name, .{}, writer);
            try writer.writeAll(",\"description\":");
            try std.json.Stringify.value(td.desc, .{}, writer);
            try writer.writeAll(",\"input_schema\":");
            try writeSchema(writer, td.schema);
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
    }
    try writer.writeAll("}");
    return aw.toOwnedSlice();
}
