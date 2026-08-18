// ai_openai.zig — OpenAI Chat Completions + Responses request bodies. Split from ai.zig.
const std = @import("std");
const cfgmod = @import("config.zig");
const types = @import("ai_types.zig");
const ajson = @import("ai_json.zig");
const athink = @import("ai_think.zig");

const Message = types.Message;
const ToolDef = types.ToolDef;
const ThinkLevel = types.ThinkLevel;
const writeSchema = ajson.writeSchema;
const writeJsonText = ajson.writeJsonText;
const writeThinkCompat = athink.writeThinkCompat;
const writeThinkResponses = athink.writeThinkResponses;

fn writeReasoningContent(writer: *std.Io.Writer, m: Message, require: bool) !void {
    const text = m.reasoning orelse "";
    if (!require and text.len == 0) return;
    try writer.writeAll(",\"reasoning_content\":");
    try writeJsonText(writer, text);
}

fn writeResponsesReasoningReplay(writer: *std.Io.Writer, m: Message) !bool {
    const sig = m.thinking_signature orelse return false;
    if (sig.len == 0 or sig[0] != '{') return false;
    try writer.writeAll(sig);
    return true;
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
    _ = compat;
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    const writer = &aw.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"store\":false,\"max_output_tokens\":");
    try writer.print("{d}", .{max_tokens});
    if (tools.len > 0) {
        try writer.writeAll(",\"tools\":[");
        for (tools, 0..) |td, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"type\":\"function\",\"name\":");
            try std.json.Stringify.value(td.name, .{}, writer);
            try writer.writeAll(",\"description\":");
            try std.json.Stringify.value(td.desc, .{}, writer);
            try writer.writeAll(",\"parameters\":");
            try writeSchema(writer, td.schema);
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
    }
    var ins = std.Io.Writer.Allocating.init(alloc);
    defer ins.deinit();
    var have_ins = false;
    try writer.writeAll(",\"input\":[");
    var first = true;
    for (messages) |m| {
        if (std.mem.eql(u8, m.role, "system")) {
            if (have_ins) try ins.writer.writeAll("\n\n");
            try ins.writer.writeAll(m.content);
            have_ins = true;
            continue;
        }
        if (!first) try writer.writeByte(',');
        first = false;
        if (m.tool_calls) |tcs| {
            const replayed = try writeResponsesReasoningReplay(writer, m);
            for (tcs, 0..) |tc, j| {
                if (replayed or j > 0) try writer.writeByte(',');
                try writer.writeAll("{\"type\":\"function_call\",\"call_id\":");
                try std.json.Stringify.value(tc.id, .{}, writer);
                try writer.writeAll(",\"name\":");
                try std.json.Stringify.value(tc.name, .{}, writer);
                try writer.writeAll(",\"arguments\":");
                try std.json.Stringify.value(tc.args, .{}, writer);
                try writer.writeAll("}");
            }
        } else if (std.mem.eql(u8, m.role, "tool")) {
            try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
            try std.json.Stringify.value(m.tool_call_id orelse "", .{}, writer);
            try writer.writeAll(",\"output\":");
            try writeJsonText(writer, m.content);
            try writer.writeAll("}");
        } else if (m.image) |img| {
            try writer.writeAll("{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":");
            try writeJsonText(writer, m.content);
            try writer.writeAll("},{\"type\":\"input_image\",\"image_url\":\"data:");
            try writer.writeAll(m.image_mime orelse "image/png");
            try writer.writeAll(";base64,");
            try writer.writeAll(img);
            try writer.writeAll("\"}]}");
        } else if (std.mem.eql(u8, m.role, "assistant")) {
            if (try writeResponsesReasoningReplay(writer, m)) try writer.writeByte(',');
            try writer.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
            try writeJsonText(writer, m.content);
            try writer.writeAll("}]}");
        } else {
            try writer.writeAll("{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":");
            try writeJsonText(writer, m.content);
            try writer.writeAll("}]}");
        }
    }
    try writer.writeAll("]");
    if (have_ins) {
        try writer.writeAll(",\"instructions\":");
        try std.json.Stringify.value(ins.written(), .{}, writer);
    }
    try writeThinkResponses(writer, think_level, think_map, reasoning);
    try writer.writeAll("}");
    return aw.toOwnedSlice();
}

pub fn serializeOpenAI(
    alloc: std.mem.Allocator,
    model: []const u8,
    messages: []const Message,
    tools: []const ToolDef,
    max_tokens: u32,
    cache_key: ?[]const u8,
) ![]u8 {
    return serializeOpenAIThink(alloc, model, messages, tools, max_tokens, cache_key, .high, .{}, true, .{});
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
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    const writer = &aw.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"max_tokens\":");
    try writer.print("{d}", .{max_tokens});
    if (cache_key) |k| {
        if (k.len > 0) {
            try writer.writeAll(",\"prompt_cache_key\":");
            try std.json.Stringify.value(k, .{}, writer);
        }
    }
    if (tools.len > 0) {
        try writer.writeAll(",\"tools\":[");
        for (tools, 0..) |td, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
            try std.json.Stringify.value(td.name, .{}, writer);
            try writer.writeAll(",\"description\":");
            try std.json.Stringify.value(td.desc, .{}, writer);
            try writer.writeAll(",\"parameters\":");
            try writeSchema(writer, td.schema);
            try writer.writeAll("}}");
        }
        try writer.writeAll("]");
    }
    const replay_rc = (compat.requires_reasoning_content orelse false) and reasoning;
    try writer.writeAll(",\"messages\":[");
    for (messages, 0..) |m, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"role\":");
        try std.json.Stringify.value(m.role, .{}, writer);
        if (m.tool_calls) |tcs| {
            try writer.writeAll(",\"content\":null,\"tool_calls\":[");
            for (tcs, 0..) |tc, j| {
                if (j > 0) try writer.writeByte(',');
                try writer.writeAll("{\"id\":");
                try std.json.Stringify.value(tc.id, .{}, writer);
                try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                try std.json.Stringify.value(tc.name, .{}, writer);
                try writer.writeAll(",\"arguments\":");
                try std.json.Stringify.value(tc.args, .{}, writer);
                try writer.writeAll("}}");
            }
            try writer.writeAll("]");
            try writeReasoningContent(writer, m, replay_rc);
            try writer.writeByte('}');
        } else if (m.image) |img| {
            try writer.writeAll(",\"content\":[{\"type\":\"text\",\"text\":");
            try writeJsonText(writer, m.content);
            try writer.writeAll("},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
            try writer.writeAll(m.image_mime orelse "image/png");
            try writer.writeAll(";base64,");
            try writer.writeAll(img);
            try writer.writeAll("\"}}]");
            if (m.tool_call_id) |id| {
                try writer.writeAll(",\"tool_call_id\":");
                try std.json.Stringify.value(id, .{}, writer);
            }
            if (std.mem.eql(u8, m.role, "assistant"))
                try writeReasoningContent(writer, m, replay_rc);
            try writer.writeAll("}");
        } else {
            try writer.writeAll(",\"content\":");
            try writeJsonText(writer, m.content);
            if (m.tool_call_id) |id| {
                try writer.writeAll(",\"tool_call_id\":");
                try std.json.Stringify.value(id, .{}, writer);
            }
            if (std.mem.eql(u8, m.role, "assistant"))
                try writeReasoningContent(writer, m, replay_rc);
            try writer.writeAll("}");
        }
    }
    try writer.writeAll("]");
    try writeThinkCompat(writer, think_level, think_map, reasoning, compat);
    try writer.writeAll("}");
    return aw.toOwnedSlice();
}
