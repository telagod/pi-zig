// tools_json.zig — tool argument JSON helpers. Split from tools.zig.
const std = @import("std");

pub fn jstr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const val = v.object.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

/// 取整数字段:接受 JSON integer,以及模型常误发的 float/字符串数字。
pub fn jint(v: std.json.Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const val = v.object.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// 取布尔字段:接受 JSON bool,以及模型常误发的 "true"/"false" 字符串。
pub fn jbool(v: std.json.Value, key: []const u8) ?bool {
    if (v != .object) return null;
    const val = v.object.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        .string => |s| if (std.mem.eql(u8, s, "true")) true else if (std.mem.eql(u8, s, "false")) false else null,
        else => null,
    };
}

pub fn parseArgs(arena: std.mem.Allocator, args: []const u8) !std.json.Value {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{}) catch return error.BadArgs;
    return root;
}
