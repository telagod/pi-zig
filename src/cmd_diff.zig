// cmd_diff.zig — /diff 与 `piz diff`：工作区 git 状态 + diffstat，不依赖 git-awareness 插件。
const std = @import("std");
const util = @import("core").util;

fn git(alloc: std.mem.Allocator, cwd: []const u8, rest: []const []const u8) ![]u8 {
    var argv = std.array_list.Managed([]const u8).init(alloc);
    try argv.appendSlice(&.{ "git", "-C", cwd });
    try argv.appendSlice(rest);
    return util.execShort(alloc, argv.items);
}

pub fn format(alloc: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const root = if (cwd.len == 0) "." else cwd;
    const status = git(alloc, root, &.{ "status", "-sb" }) catch
        return alloc.dupe(u8, "not a git repo or git unavailable");
    const unstaged = git(alloc, root, &.{ "diff", "--stat" }) catch "";
    const staged = git(alloc, root, &.{ "diff", "--cached", "--stat" }) catch "";
    var aw = std.Io.Writer.Allocating.init(alloc);
    errdefer aw.deinit();
    try aw.writer.print("git status\n{s}", .{status});
    if (std.mem.trim(u8, staged, " \t\r\n").len > 0) {
        try aw.writer.print("\nstaged\n{s}", .{staged});
    }
    if (std.mem.trim(u8, unstaged, " \t\r\n").len > 0) {
        try aw.writer.print("\nunstaged\n{s}", .{unstaged});
    } else if (std.mem.trim(u8, staged, " \t\r\n").len == 0) {
        try aw.writer.writeAll("\nclean worktree\n");
    }
    const out = aw.written();
    if (out.len > 8 * 1024) {
        return std.fmt.allocPrint(alloc, "{s}\n...[truncated]...", .{out[0 .. 8 * 1024]});
    }
    return aw.toOwnedSlice();
}

pub fn parseLogCount(raw: []const u8) usize {
    const s = std.mem.trim(u8, raw, " \t");
    if (s.len == 0) return 20;
    const n = std.fmt.parseInt(usize, s, 10) catch return 20;
    return @max(1, @min(n, 50));
}

pub fn formatLog(alloc: std.mem.Allocator, cwd: []const u8, count: usize) ![]u8 {
    const root = if (cwd.len == 0) "." else cwd;
    var nb: [8]u8 = undefined;
    const nstr = std.fmt.bufPrint(&nb, "{d}", .{@max(1, @min(count, 50))}) catch "20";
    const out = git(alloc, root, &.{ "log", "--oneline", "-n", nstr }) catch
        return alloc.dupe(u8, "not a git repo or git unavailable");
    if (std.mem.trim(u8, out, " \t\r\n").len == 0)
        return alloc.dupe(u8, "no commits yet");
    return out;
}

fn parseHeadRef(head: []const u8, buf: []u8) ?[]u8 {
    const ref = "ref: refs/heads/";
    if (std.mem.startsWith(u8, head, ref)) {
        const br = std.mem.trim(u8, head[ref.len..], " \t\r\n");
        if (br.len == 0 or br.len > buf.len) return null;
        @memcpy(buf[0..br.len], br);
        return buf[0..br.len];
    }
    const hash = std.mem.trim(u8, head, " \t\r\n");
    if (hash.len < 7 or buf.len < 7) return null;
    @memcpy(buf[0..7], hash[0..7]);
    return buf[0..7];
}

/// 读 `{cwd}/.git/HEAD`(含 worktree 的 gitdir 文件)。不 spawn git。结果在 buf 内。
pub fn currentBranchBuf(cwd: []const u8, buf: []u8) ?[]u8 {
    const root = if (cwd.len == 0) "." else cwd;
    var path_buf: [4096]u8 = undefined;
    var data_buf: [1024]u8 = undefined;
    const head_path = std.fmt.bufPrint(&path_buf, "{s}/.git/HEAD", .{root}) catch return null;
    if (std.Io.Dir.cwd().readFile(util.io, head_path, &data_buf)) |head| {
        return parseHeadRef(head, buf);
    } else |_| {}
    const gitfile_path = std.fmt.bufPrint(&path_buf, "{s}/.git", .{root}) catch return null;
    const gitfile = std.Io.Dir.cwd().readFile(util.io, gitfile_path, &data_buf) catch return null;
    const prefix = "gitdir:";
    const trimmed = std.mem.trim(u8, gitfile, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    var gitdir = std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
    if (gitdir.len == 0) return null;
    var gitdir_buf: [4096]u8 = undefined;
    if (!std.fs.path.isAbsolute(gitdir)) {
        gitdir = std.fmt.bufPrint(&gitdir_buf, "{s}/{s}", .{ root, gitdir }) catch return null;
    }
    const wt_head = std.fmt.bufPrint(&path_buf, "{s}/HEAD", .{gitdir}) catch return null;
    const head2 = std.Io.Dir.cwd().readFile(util.io, wt_head, &data_buf) catch return null;
    return parseHeadRef(head2, buf);
}

pub fn currentBranch(alloc: std.mem.Allocator, cwd: []const u8) ?[]u8 {
    var buf: [128]u8 = undefined;
    const br = currentBranchBuf(cwd, &buf) orelse return null;
    return alloc.dupe(u8, br) catch null;
}

pub const Brief = struct {
    ahead: u32 = 0,
    behind: u32 = 0,
    changes: u32 = 0,
};

fn parseAfter(s: []const u8, key: []const u8) u32 {
    const i = std.mem.indexOf(u8, s, key) orelse return 0;
    const rest = s[i + key.len ..];
    var n: u32 = 0;
    var saw = false;
    for (rest) |c| {
        if (c < '0' or c > '9') break;
        saw = true;
        n = n *| 10 + (c - '0');
    }
    return if (saw) n else 0;
}

pub fn parseStatusBrief(out: []const u8) Brief {
    var brief = Brief{};
    var it = std.mem.splitScalar(u8, out, '\n');
    var first = true;
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \t\r");
        if (ln.len == 0) continue;
        if (first) {
            first = false;
            brief.ahead = parseAfter(ln, "ahead ");
            brief.behind = parseAfter(ln, "behind ");
            continue;
        }
        brief.changes += 1;
    }
    return brief;
}

pub fn formatBranchLabel(buf: []u8, branch: []const u8, st: Brief) []const u8 {
    if (branch.len == 0) return "";
    var aw = std.Io.Writer.fixed(buf);
    aw.writeAll(branch) catch return branch;
    if (st.changes > 0) aw.writeByte('*') catch {};
    if (st.ahead > 0) aw.print(" ↑{d}", .{st.ahead}) catch {};
    if (st.behind > 0) aw.print(" ↓{d}", .{st.behind}) catch {};
    return aw.buffered();
}

pub fn statusBrief(alloc: std.mem.Allocator, cwd: []const u8) ?Brief {
    const root = if (cwd.len == 0) "." else cwd;
    const out = git(alloc, root, &.{ "status", "-sb" }) catch return null;
    defer alloc.free(out);
    return parseStatusBrief(out);
}

pub fn formatBranch(alloc: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const root = if (cwd.len == 0) "." else cwd;
    const cur = git(alloc, root, &.{ "branch", "--show-current" }) catch
        return alloc.dupe(u8, "not a git repo or git unavailable");
    const list = git(alloc, root, &.{ "branch", "--sort=-committerdate" }) catch "";
    var aw = std.Io.Writer.Allocating.init(alloc);
    errdefer aw.deinit();
    const head = std.mem.trim(u8, cur, " \t\r\n");
    if (head.len == 0) {
        try aw.writer.writeAll("detached HEAD\n");
    } else {
        try aw.writer.print("current {s}\n", .{head});
    }
    if (std.mem.trim(u8, list, " \t\r\n").len > 0) {
        try aw.writer.writeAll(list);
        if (list.len == 0 or list[list.len - 1] != '\n') try aw.writer.writeByte('\n');
    }
    return aw.toOwnedSlice();
}

fn scratchPath(a: std.mem.Allocator, tag: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(a, "/tmp/piz-{s}-{d}", .{ tag, std.Thread.getCurrentId() });
    std.Io.Dir.cwd().createDirPath(util.io, path) catch return error.SkipZigTest;
    return path;
}

test "format reports missing git repo" {
    const t = std.testing;
    try util.testInit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try scratchPath(a, "diff-none");
    defer _ = util.execShort(a, &.{ "rm", "-rf", root }) catch {};
    const out = try format(a, root);
    try t.expect(std.mem.indexOf(u8, out, "not a git repo") != null);
}

test "format shows status in a real repo" {
    const t = std.testing;
    try util.testInit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try scratchPath(a, "diff-repo");
    defer _ = util.execShort(a, &.{ "rm", "-rf", root }) catch {};
    _ = util.execShort(a, &.{ "git", "-C", root, "init", "-q" }) catch return error.SkipZigTest;
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/a.txt", .{root}), .data = "hi\n" });
    const out = try format(a, root);
    try t.expect(std.mem.indexOf(u8, out, "git status") != null);
    try t.expect(std.mem.indexOf(u8, out, "a.txt") != null);
}

test "formatLog handles empty repo and count clamp" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 20), parseLogCount(""));
    try t.expectEqual(@as(usize, 5), parseLogCount("5"));
    try t.expectEqual(@as(usize, 50), parseLogCount("99"));
    try t.expectEqual(@as(usize, 1), parseLogCount("0"));
    try util.testInit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try scratchPath(a, "log-none");
    defer _ = util.execShort(a, &.{ "rm", "-rf", root }) catch {};
    const missing = try formatLog(a, root, 5);
    try t.expect(std.mem.indexOf(u8, missing, "not a git repo") != null);
    const nobr = try formatBranch(a, root);
    try t.expect(std.mem.indexOf(u8, nobr, "not a git repo") != null);
    try t.expect(currentBranch(a, root) == null);
    const repo = try scratchPath(a, "br-repo");
    defer _ = util.execShort(a, &.{ "rm", "-rf", repo }) catch {};
    _ = util.execShort(a, &.{ "git", "-C", repo, "init", "-q", "-b", "main" }) catch return error.SkipZigTest;
    const br = currentBranch(a, repo) orelse return error.SkipZigTest;
    try t.expectEqualStrings("main", br);
}

test "parseStatusBrief reads ahead behind and changes" {
    const t = std.testing;
    const a = parseStatusBrief("## main...origin/main [ahead 2, behind 1]\n M a.zig\n?? b.txt\n");
    try t.expectEqual(@as(u32, 2), a.ahead);
    try t.expectEqual(@as(u32, 1), a.behind);
    try t.expectEqual(@as(u32, 2), a.changes);
    const clean = parseStatusBrief("## main\n");
    try t.expectEqual(@as(u32, 0), clean.ahead);
    try t.expectEqual(@as(u32, 0), clean.behind);
    try t.expectEqual(@as(u32, 0), clean.changes);
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("main* ↑2 ↓1", formatBranchLabel(&buf, "main", a));
    try t.expectEqualStrings("main", formatBranchLabel(&buf, "main", .{}));
}
