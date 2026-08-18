// cmd_commit.zig — /commit 与 `piz commit`：只提交已暂存内容，绝不自动 git add。
const std = @import("std");
const util = @import("core").util;

fn git(alloc: std.mem.Allocator, cwd: []const u8, rest: []const []const u8) ![]u8 {
    var argv = std.array_list.Managed([]const u8).init(alloc);
    try argv.appendSlice(&.{ "git", "-C", cwd });
    try argv.appendSlice(rest);
    return util.execShort(alloc, argv.items);
}

fn scratchPath(a: std.mem.Allocator, tag: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(a, "/tmp/piz-{s}-{d}", .{ tag, std.Thread.getCurrentId() });
    std.Io.Dir.cwd().createDirPath(util.io, path) catch return error.SkipZigTest;
    return path;
}

pub fn run(alloc: std.mem.Allocator, cwd: []const u8, message: []const u8) ![]u8 {
    const root = if (cwd.len == 0) "." else cwd;
    const staged = git(alloc, root, &.{ "diff", "--cached", "--name-only" }) catch
        return alloc.dupe(u8, "not a git repo or git unavailable");
    const names = std.mem.trim(u8, staged, " \t\r\n");
    if (names.len == 0) {
        const status = git(alloc, root, &.{ "status", "-sb" }) catch "";
        return std.fmt.allocPrint(alloc, "nothing staged. git add first, then /commit <message>\n{s}", .{status});
    }
    const msg = std.mem.trim(u8, message, " \t\r\n");
    if (msg.len == 0) {
        const stat = git(alloc, root, &.{ "diff", "--cached", "--stat" }) catch staged;
        return std.fmt.allocPrint(alloc, "staged (not committed):\n{s}\nusage: /commit <message>", .{stat});
    }
    _ = git(alloc, root, &.{ "commit", "-m", msg }) catch |err| {
        return std.fmt.allocPrint(alloc, "git commit failed: {s}", .{@errorName(err)});
    };
    const log = git(alloc, root, &.{ "log", "-1", "--oneline" }) catch msg;
    return std.fmt.allocPrint(alloc, "committed {s}", .{std.mem.trim(u8, log, " \t\r\n")});
}

test "run previews when message is empty" {
    const t = std.testing;
    try util.testInit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try scratchPath(a, "commit-prev");
    defer _ = util.execShort(a, &.{ "rm", "-rf", root }) catch {};
    _ = util.execShort(a, &.{ "git", "-C", root, "init", "-q" }) catch return error.SkipZigTest;
    _ = util.execShort(a, &.{ "git", "-C", root, "config", "user.email", "t@t" }) catch {};
    _ = util.execShort(a, &.{ "git", "-C", root, "config", "user.name", "t" }) catch {};
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/a.txt", .{root}), .data = "hi\n" });
    _ = util.execShort(a, &.{ "git", "-C", root, "add", "a.txt" }) catch return error.SkipZigTest;
    const preview = try run(a, root, "");
    try t.expect(std.mem.indexOf(u8, preview, "staged") != null);
    try t.expect(std.mem.indexOf(u8, preview, "usage:") != null);
    const done = try run(a, root, "add a");
    try t.expect(std.mem.indexOf(u8, done, "committed") != null);
    const again = try run(a, root, "nope");
    try t.expect(std.mem.indexOf(u8, again, "nothing staged") != null);
}
