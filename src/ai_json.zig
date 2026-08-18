// ai_json.zig — JSON string/schema writers for provider payloads. Split from ai.zig.
const std = @import("std");

/// 写工具参数 schema:空串退化为无参数对象。
pub fn jstr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const val = v.object.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

/// pi 流式/非流式同一优先级:reasoning_content → reasoning → reasoning_text。
pub fn firstReasoningText(obj: std.json.ObjectMap) ?[]const u8 {
    const fields = [_][]const u8{ "reasoning_content", "reasoning", "reasoning_text" };
    for (fields) |f| {
        if (obj.get(f)) |v| {
            if (v == .string and v.string.len > 0) return v.string;
        }
    }
    return null;
}

pub fn writeSchema(writer: *std.Io.Writer, schema: []const u8) !void {
    if (schema.len == 0) {
        try writer.writeAll("{\"type\":\"object\",\"properties\":{}}");
        return;
    }
    try writer.writeAll(schema);
}

/// 把任意字节写成 JSON **字符串**。非法 UTF-8 替换为 U+FFFD,永不退化成整数数组。
pub fn writeJsonText(writer: *std.Io.Writer, s: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(s)) {
        try std.json.Stringify.value(s, .{}, writer);
        return;
    }
    try writer.writeByte('"');
    var i: usize = 0;
    var run_start: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        const ok = n > 0 and i + n <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + n]);
        if (ok and !needsEscape(s[i])) {
            i += n;
            continue;
        }
        if (i > run_start) try writer.writeAll(s[run_start..i]);
        if (!ok) {
            try writer.writeAll("\u{fffd}");
            i += 1;
        } else {
            try writeEscaped(writer, s[i]);
            i += 1;
        }
        run_start = i;
    }
    if (i > run_start) try writer.writeAll(s[run_start..i]);
    try writer.writeByte('"');
}

fn needsEscape(c: u8) bool {
    return c == '"' or c == '\\' or c < 0x20;
}

fn writeEscaped(writer: *std.Io.Writer, c: u8) !void {
    switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0c => try writer.writeAll("\\f"),
        else => try writer.print("\\u{x:0>4}", .{c}),
    }
}

test "writeJsonText quotes utf8 and replaces invalid bytes" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    try writeJsonText(&aw, "ok");
    try t.expectEqualStrings("\"ok\"", aw.buffered());
    aw = std.Io.Writer.fixed(&buf);
    try writeJsonText(&aw, "a\"b");
    try t.expectEqualStrings("\"a\\\"b\"", aw.buffered());
    aw = std.Io.Writer.fixed(&buf);
    try writeJsonText(&aw, &[_]u8{ 'x', 0xff, 'y' });
    try t.expect(std.mem.indexOf(u8, aw.buffered(), "\u{fffd}") != null);
    try t.expect(aw.buffered()[0] == '"');
}

test "writeSchema empty becomes object" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    try writeSchema(&aw, "");
    try t.expectEqualStrings("{\"type\":\"object\",\"properties\":{}}", aw.buffered());
}
