// ai_think.zig — provider thinking/reasoning JSON fields. Split from ai.zig.
const std = @import("std");
const cfgmod = @import("config.zig");

const ThinkLevel = cfgmod.ThinkLevel;

pub fn thinkEffortStr(level: ThinkLevel, map: cfgmod.ThinkingLevelMap) ?[]const u8 {
    if (level == .off) return null;
    return switch (map.get(level)) {
        .send => |s| s,
        .omitted => level.label(),
        .hidden => null,
    };
}

fn writeEffortField(writer: *std.Io.Writer, key: []const u8, effort: []const u8) !void {
    try writer.writeByte(',');
    try std.json.Stringify.value(key, .{}, writer);
    try writer.writeByte(':');
    try std.json.Stringify.value(effort, .{}, writer);
}

/// 思考字段。形状抄 pi `openai-completions.ts` 的 `thinkingFormat` 分支。
pub fn writeThinkCompat(
    writer: *std.Io.Writer,
    level: ThinkLevel,
    map: cfgmod.ThinkingLevelMap,
    reasoning: bool,
    compat: cfgmod.Compat,
) !void {
    if (!reasoning) return;
    const format = compat.think_format orelse .openai;
    const supports_effort = compat.supports_reasoning_effort orelse true;
    const effort = thinkEffortStr(level, map);

    switch (format) {
        .deepseek => {
            if (level == .off) {
                if (map.get(.off) != .hidden)
                    try writer.writeAll(",\"thinking\":{\"type\":\"disabled\"}");
                return;
            }
            try writer.writeAll(",\"thinking\":{\"type\":\"enabled\"}");
            if (supports_effort) {
                if (effort) |e| try writeEffortField(writer, "reasoning_effort", e);
            }
        },
        .openrouter => {
            if (level == .off) {
                if (map.get(.off) != .hidden)
                    try writer.writeAll(",\"reasoning\":{\"effort\":\"none\"}");
                return;
            }
            if (effort) |e| {
                try writer.writeAll(",\"reasoning\":{\"effort\":");
                try std.json.Stringify.value(e, .{}, writer);
                try writer.writeByte('}');
            }
        },
        .zai => {
            try writer.writeAll(if (level == .off)
                ",\"thinking\":{\"type\":\"disabled\"}"
            else
                ",\"thinking\":{\"type\":\"enabled\"}");
        },
        .together => {
            try writer.writeAll(if (level == .off)
                ",\"reasoning\":{\"enabled\":false}"
            else
                ",\"reasoning\":{\"enabled\":true}");
            if (level != .off and supports_effort) {
                if (effort) |e| try writeEffortField(writer, "reasoning_effort", e);
            }
        },
        .qwen => {
            try writer.writeAll(if (level == .off)
                ",\"enable_thinking\":false"
            else
                ",\"enable_thinking\":true");
            if (level != .off and supports_effort) {
                if (effort) |e| try writeEffortField(writer, "reasoning_effort", e);
            }
        },
        .openai => {
            if (level == .off) {
                if (map.get(.off) == .send) {
                    try writeEffortField(writer, "reasoning_effort", map.get(.off).send);
                }
                return;
            }
            if (supports_effort) {
                if (effort) |e| try writeEffortField(writer, "reasoning_effort", e);
            }
        },
    }
}

/// OpenAI Responses reasoning params.
pub fn writeThinkResponses(writer: *std.Io.Writer, level: ThinkLevel, map: cfgmod.ThinkingLevelMap, reasoning: bool) !void {
    if (!reasoning) return;
    if (level == .off) {
        const effort = switch (map.get(.off)) {
            .hidden => return,
            .send => |s| s,
            .omitted => "none",
        };
        try writer.writeAll(",\"reasoning\":{\"effort\":");
        try std.json.Stringify.value(effort, .{}, writer);
        try writer.writeAll("}");
        return;
    }
    const effort = switch (map.get(level)) {
        .send => |s| s,
        .omitted => level.label(),
        .hidden => return,
    };
    try writer.writeAll(",\"reasoning\":{\"effort\":");
    try std.json.Stringify.value(effort, .{}, writer);
    try writer.writeAll(",\"summary\":\"auto\"},\"include\":[\"reasoning.encrypted_content\"]");
}

test "writeThinkCompat openai high emits effort" {
    const t = std.testing;
    var buf: [128]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    try writeThinkCompat(&aw, .high, .{}, true, .{});
    try t.expect(std.mem.indexOf(u8, aw.buffered(), "reasoning_effort") != null);
    aw = std.Io.Writer.fixed(&buf);
    try writeThinkCompat(&aw, .high, .{}, false, .{});
    try t.expectEqual(@as(usize, 0), aw.buffered().len);
}

test "writeThinkResponses off omitted is none" {
    const t = std.testing;
    var buf: [128]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    try writeThinkResponses(&aw, .off, .{}, true);
    try t.expect(std.mem.indexOf(u8, aw.buffered(), "\"none\"") != null);
}
