// 小件可选插件:读图、git 状态、向用户提问。
const std = @import("std");
const agentmod = @import("../agent.zig");
const imgxmod = @import("../imgx.zig");
const toolsmod = @import("../tools.zig");
const util = @import("../util.zig");

// =====================================================================
// 图片输入插件:read_image 走 imgx 压缩管线后以 user 消息附图。
// =====================================================================

/// 单图输入上限(压缩前的源文件体积)。
const MAX_IMAGE_INPUT_BYTES = 20 * 1024 * 1024;

pub fn toolReadImage(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{});
    const path: []const u8 = if (v == .object) blk: {
        const p = v.object.get("path") orelse break :blk "";
        break :blk if (p == .string) p.string else "";
    } else "";
    if (path.len == 0) return .{ .content = "error: path is required", .is_error = true };
    // 相对路径按 agent cwd 解析(root 是 thread-local,工具线程内可用)
    const resolved = toolsmod.resolvePath(arena, path);
    const input = std.Io.Dir.cwd().readFileAlloc(util.io, resolved, arena, .limited(MAX_IMAGE_INPUT_BYTES)) catch {
        return .{ .content = try std.fmt.allocPrint(arena, "error: cannot read image file: {s}", .{path}), .is_error = true };
    };
    if (input.len == 0) return .{ .content = "error: empty file", .is_error = true };
    // 长边按 provider 上下文窗口推导:小窗自动压小,给文本让 token。
    const max_dim = imgxmod.maxDimForContext(@intCast(self.ctxWindow()), self.provider.api);
    const out = try imgxmod.process(arena, input, .{ .max_dim = max_dim });
    const dim_note = imgxmod.dimensionNote(out, arena) orelse "";
    // 工具 handler 的 arena 就是会话 arena(self.alloc),分配即常驻 ——
    // 消息历史里会长期引用这些字符串,不能落在单轮 arena。
    const content = if (out.passthrough)
        try std.fmt.allocPrint(arena, "Read image file [{s}] ({d}x{d}, {d} bytes; decoder could not process it, sent as-is)", .{ out.mime, out.w, out.h, out.bytes })
    else if (dim_note.len > 0)
        try std.fmt.allocPrint(arena, "Read image file [{s}] ({d}x{d}, {d} bytes; source was {d}x{d}).\n{s}", .{ out.mime, out.w, out.h, out.bytes, out.orig_w, out.orig_h, dim_note })
    else
        try std.fmt.allocPrint(arena, "Read image file [{s}] ({d}x{d}, {d} bytes; source was {d}x{d})", .{ out.mime, out.w, out.h, out.bytes, out.orig_w, out.orig_h });
    const imgs = try arena.create([1]toolsmod.ImageAttach);
    imgs[0] = .{ .data = out.data, .mime = out.mime, .w = out.w, .h = out.h, .note = content };
    return .{ .content = content, .images = imgs };
}

// =====================================================================
// git 状态插件:git_status 工具(每轮改动可见性)。
// =====================================================================
pub fn toolGitStatus(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = ctx;
    _ = args;
    // 极简:git status --short + 最近 diffstat(经 bash 子进程,失败返回提示)
    const status = agentmod.util.execShort(arena, &.{ "git", "status", "--short" }) catch return .{ .content = "not a git repo or git unavailable", .is_error = true };
    const diffstat = agentmod.util.execShort(arena, &.{ "git", "diff", "--stat" }) catch "";
    return .{ .content = try std.fmt.allocPrint(arena, "Git status:\n{s}{s}", .{ status, diffstat }) };
}

// =====================================================================
// elicitation 插件:ask_user 工具——信息不足时向用户提问。
// 极简语义:工具结果强提示模型"已向用户提问,等待回复",模型输出问题后停下。
// =====================================================================
pub fn toolAskUser(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    _ = self;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{});
    const q = blk: {
        if (v == .object) {
            if (v.object.get("question")) |qv| {
                if (qv == .string) break :blk qv.string;
            }
        }
        break :blk "";
    };
    if (q.len == 0) return .{ .content = "error: ask_user requires 'question'", .is_error = true };
    return .{ .content = try std.fmt.allocPrint(arena, "The user has been asked: {s}\nSTOP and present this question to the user in your reply. Do not guess or continue until the user answers in their next message.", .{q}) };
}
