// 子 agent 掩码的运行时绑定。task / agents 不能 import plugins.zig(循环)。
const std = @import("std");

pub const ChildSetFn = *const fn (u16, ?[]const []const u8) anyerror!u16;
pub const ToolAllowFn = *const fn (std.mem.Allocator, u16, []const []const u8) anyerror![]const []const u8;

pub var child_set: ?ChildSetFn = null;
pub var tool_allow: ?ToolAllowFn = null;

pub fn resolveSet(parent: u16, want: ?[]const []const u8) !u16 {
    if (child_set) |f| return f(parent, want);
    // 未绑定时的底线:继承并摘掉 task-delegation(第 12 位)。plugins.zig 有 comptime 守着。
    return parent & ~@as(u16, 1 << 12);
}

pub fn resolveTools(arena: std.mem.Allocator, parent: u16, names: []const []const u8) ![]const []const u8 {
    if (tool_allow) |f| return f(arena, parent, names);
    return names;
}
