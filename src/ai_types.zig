// ai_types.zig — shared provider types. Split from ai.zig so parsers can import without a cycle.
const httpc = @import("httpc.zig");
const cfgmod = @import("config.zig");
const std = @import("std");

pub const ThinkLevel = cfgmod.ThinkLevel;

pub const ToolCall = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    args: []const u8 = "",
};

pub const ToolDef = struct {
    name: []const u8,
    desc: []const u8,
    schema: []const u8 = "",
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
    image: ?[]const u8 = null,
    image_mime: ?[]const u8 = null,
    image_w: u32 = 0,
    image_h: u32 = 0,
    image_file: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    thinking_signature: ?[]const u8 = null,
    thinking_redacted: bool = false,
};

pub const Usage = struct {
    input: ?u64 = null,
    output: ?u64 = null,
    cache_read: ?u64 = null,
    cost: ?f64 = null,
    cache_write: ?u64 = null,
};

pub const RunResult = struct {
    text: []const u8 = "",
    reasoning: []const u8 = "",
    thinking_signature: []const u8 = "",
    thinking_redacted: bool = false,
    tool_calls: []const ToolCall = &.{},
    usage: Usage = .{},
    finish_reason: []const u8 = "",
    error_msg: ?[]const u8 = null,
    aborted: bool = false,
    stream_interrupted: ?[]const u8 = null,
};

pub const Callbacks = struct {
    ctx: ?*anyopaque = null,
    on_text: ?*const fn (ctx: ?*anyopaque, text: []const u8) anyerror!void = null,
    on_reasoning: ?*const fn (ctx: ?*anyopaque, text: []const u8) anyerror!void = null,
    on_abort: ?*const fn (ctx: ?*anyopaque) bool = null,
    on_connect: ?*const fn (ctx: ?*anyopaque, fd: std.posix.fd_t) void = null,
};

pub const Options = struct {
    max_tokens: u32 = 8192,
    cache_key: ?[]const u8 = null,
    cache_retention: cfgmod.CacheRetention = .short,
    think_level: ThinkLevel = .high,
    think_map: cfgmod.ThinkingLevelMap = .{},
    reasoning: bool = true,
    compat: cfgmod.Compat = .{},
    thinking_budgets: cfgmod.ThinkingBudgets = .{},
    max_output: u32 = 0,
    callbacks: Callbacks = .{},
    retry_policy: httpc.RetryPolicy = .{},
};
