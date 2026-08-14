// 插件共用的 JSON 取值。
const std = @import("std");

pub fn jsonStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    if (f != .string) return null;
    if (f.string.len == 0) return null;
    return f.string;
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
