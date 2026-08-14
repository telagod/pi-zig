//! 编译期能力缝:Definition + 默认 Provider。无加载器、无 ABI。
//! Consumer(agent loop / 工具)只打这些接口;替换 Provider 即可换实现。

const std = @import("std");
const util = @import("util.zig");
const ai = @import("ai.zig");
const cfgmod = @import("config.zig");

pub const Allocator = std.mem.Allocator;

// ---- fs ----

pub const Fs = struct {
    ctx: ?*anyopaque = null,
    readFile: *const fn (ctx: ?*anyopaque, arena: Allocator, path: []const u8, limit: usize) anyerror![]u8,
    writeFile: *const fn (ctx: ?*anyopaque, path: []const u8, data: []const u8) anyerror!void,
    createDirPath: *const fn (ctx: ?*anyopaque, path: []const u8) anyerror!void,
};

fn localRead(_: ?*anyopaque, arena: Allocator, path: []const u8, limit: usize) anyerror![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(util.io, path, arena, .limited(limit));
}

fn localWrite(_: ?*anyopaque, path: []const u8, data: []const u8) anyerror!void {
    return std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = path, .data = data });
}

fn localMkdir(_: ?*anyopaque, path: []const u8) anyerror!void {
    return std.Io.Dir.cwd().createDirPath(util.io, path);
}

pub const local_fs: Fs = .{
    .readFile = localRead,
    .writeFile = localWrite,
    .createDirPath = localMkdir,
};

threadlocal var bound_fs: *const Fs = &local_fs;

pub fn setFs(provider: *const Fs) void {
    bound_fs = provider;
}

pub fn resetFs() void {
    bound_fs = &local_fs;
}

pub fn fs() *const Fs {
    return bound_fs;
}

// ---- llm ----

pub const LlmRun = *const fn (
    alloc: Allocator,
    arena: Allocator,
    provider: *const cfgmod.Provider,
    key: ?[]const u8,
    url: []const u8,
    model: []const u8,
    messages: []const ai.Message,
    tool_defs: []const ai.ToolDef,
    options: ai.Options,
) anyerror!ai.RunResult;

pub fn defaultLlmRun(
    alloc: Allocator,
    arena: Allocator,
    provider: *const cfgmod.Provider,
    key: ?[]const u8,
    url: []const u8,
    model: []const u8,
    messages: []const ai.Message,
    tool_defs: []const ai.ToolDef,
    options: ai.Options,
) anyerror!ai.RunResult {
    return ai.run(alloc, arena, provider, key, url, model, messages, tool_defs, options);
}

// ---- 测试 ----

const MemFs = struct {
    reads: usize = 0,
    writes: usize = 0,
    last_path: []const u8 = "",
    payload: []const u8 = "from-mem-fs",

    fn read(ctx: ?*anyopaque, arena: Allocator, path: []const u8, _: usize) anyerror![]u8 {
        const self: *MemFs = @ptrCast(@alignCast(ctx.?));
        self.reads += 1;
        self.last_path = path;
        return arena.dupe(u8, self.payload);
    }
    fn write(ctx: ?*anyopaque, _: []const u8, _: []const u8) anyerror!void {
        const self: *MemFs = @ptrCast(@alignCast(ctx.?));
        self.writes += 1;
    }
    fn mkdir(_: ?*anyopaque, _: []const u8) anyerror!void {}
};

test "fs seam default is local, bind swaps provider" {
    const t = std.testing;
    var mem = MemFs{};
    const fake = Fs{
        .ctx = @ptrCast(&mem),
        .readFile = MemFs.read,
        .writeFile = MemFs.write,
        .createDirPath = MemFs.mkdir,
    };
    setFs(&fake);
    defer resetFs();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const got = try fs().readFile(fs().ctx, arena.allocator(), "any.txt", 1024);
    try t.expectEqualStrings("from-mem-fs", got);
    try t.expectEqual(@as(usize, 1), mem.reads);
    try fs().writeFile(fs().ctx, "x", "y");
    try t.expectEqual(@as(usize, 1), mem.writes);
}
