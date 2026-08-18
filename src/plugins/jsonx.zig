// 插件共用的 JSON 取值。
const std = @import("std");

pub fn jsonStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    if (f != .string) return null;
    if (f.string.len == 0) return null;
    return f.string;
}

/// 取字符串数组。缺省返回 null;出现则每项必须是非空字符串。
pub fn jsonStrs(arena: std.mem.Allocator, v: std.json.Value, key: []const u8) !?[]const []const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    if (f != .array) return error.BadType;
    if (f.array.items.len == 0) return error.EmptyList;
    var out = std.array_list.Managed([]const u8).init(arena);
    for (f.array.items) |it| {
        if (it != .string or it.string.len == 0) return error.BadType;
        try out.append(it.string);
    }
    return try out.toOwnedSlice();
}

/// 取布尔字段。容忍 true/false 字符串。
pub fn jsonBool(v: std.json.Value, key: []const u8) ?bool {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return switch (f) {
        .bool => |b| b,
        .string => |sv| if (std.mem.eql(u8, sv, "true")) true else if (std.mem.eql(u8, sv, "false")) false else null,
        else => null,
    };
}

/// 取整数字段。容忍模型把数字写成字符串或浮点(常见偏差)。
pub fn jsonInt(v: std.json.Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return switch (f) {
        .integer => |i| i,
        .float => |x| @intFromFloat(x),
        .string => |sv| std.fmt.parseInt(i64, std.mem.trim(u8, sv, " \t"), 10) catch null,
        else => null,
    };
}

test "jsonStrs rejects empty arrays and non-strings" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const empty = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"tools\":[]}", .{});
    try t.expectError(error.EmptyList, jsonStrs(a, empty, "tools"));
    const bad = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"tools\":[1]}", .{});
    try t.expectError(error.BadType, jsonStrs(a, bad, "tools"));
    const ok = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"tools\":[\"read\",\"grep\"]}", .{});
    const got = (try jsonStrs(a, ok, "tools")).?;
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("read", got[0]);
    try t.expect(try jsonStrs(a, ok, "missing") == null);
}
