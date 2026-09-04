// tools_path.zig — per-thread tool root, sandbox, path resolve. Split from tools.zig.
const std = @import("std");
const util = @import("util.zig");
const seams = @import("seams.zig");
const sandboxmod = @import("sandbox.zig");

threadlocal var tool_root: []const u8 = "";
threadlocal var sandbox_mode: sandboxmod.Mode = .off;

pub fn setRoot(root: []const u8) void {
    tool_root = root;
}

pub fn clearRoot() void {
    tool_root = "";
}

pub fn setSandbox(mode: sandboxmod.Mode) void {
    sandbox_mode = mode;
}

pub fn clearSandbox() void {
    sandbox_mode = .off;
}

pub fn currentRoot() []const u8 {
    return tool_root;
}

pub fn currentSandbox() sandboxmod.Mode {
    return sandbox_mode;
}

pub fn diskRead(arena: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const f = seams.fs();
    return f.readFile(f.ctx, arena, path, limit);
}

/// 把工具参数里的路径解析成可直接用于 `Dir.cwd()` 的路径。
/// 绝对路径原样返回。写类工具另走 `insideRoot`,读类仍可看工作区外。
pub fn resolvePath(arena: std.mem.Allocator, path: []const u8) []const u8 {
    if (tool_root.len == 0) return path;
    if (std.fs.path.isAbsolute(path)) return path;
    return std.fs.path.join(arena, &.{ tool_root, path }) catch path;
}

/// 子进程的工作目录:有根目录就用它,否则让子进程继承进程 cwd。
pub fn rootForSpawn() ?[]const u8 {
    return if (tool_root.len > 0) tool_root else null;
}

pub fn lexNorm(arena: std.mem.Allocator, path: []const u8) []const u8 {
    const abs = std.fs.path.isAbsolute(path);
    var parts = std.array_list.Managed([]const u8).init(arena);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.items.len > 0) {
                _ = parts.pop();
            } else if (!abs) {
                parts.append("..") catch |err| util.debugCatch("lexNorm.dotdot", err);
            }
            continue;
        }
        parts.append(p) catch |err| util.debugCatch("lexNorm.part", err);
    }
    var aw = std.Io.Writer.Allocating.init(arena);
    if (abs) aw.writer.writeByte('/') catch |err| util.debugCatch("lexNorm.slash", err);
    for (parts.items, 0..) |p, i| {
        if (i > 0) aw.writer.writeByte('/') catch |err| util.debugCatch("lexNorm.sep", err);
        aw.writer.writeAll(p) catch |err| util.debugCatch("lexNorm.seg", err);
    }
    if (abs and parts.items.len == 0) return "/";
    return aw.toOwnedSlice() catch path;
}

/// 路径规范化:结合 root 补全相对路径并消除多余斜杠与 .. 相对段。
pub fn normalizePath(arena: std.mem.Allocator, root: []const u8, path: []const u8) []const u8 {
    const full = if (root.len > 0 and !std.fs.path.isAbsolute(path))
        std.fs.path.join(arena, &.{ root, path }) catch path
    else
        path;
    return lexNorm(arena, full);
}

/// 写类工具:路径必须落在当前 tool_root 下。未设 root 时不拦(单测直调)。
pub fn insideRoot(arena: std.mem.Allocator, path: []const u8) bool {
    if (tool_root.len == 0) return true;
    const resolved = resolvePath(arena, path);
    const norm = lexNorm(arena, resolved);
    const root = lexNorm(arena, tool_root);
    if (root.len == 0) {
        if (std.fs.path.isAbsolute(norm)) return false;
        return !std.mem.eql(u8, norm, "..") and !std.mem.startsWith(u8, norm, "../");
    }
    if (std.mem.eql(u8, norm, root)) return true;
    if (norm.len > root.len and std.mem.startsWith(u8, norm, root) and norm[root.len] == '/') return true;
    return false;
}

fn pathUnder(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    if (path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/') return true;
    return false;
}

/// 写类工具:跟 symlink 后仍须落在 tool_root。文件不存在则看父目录。
pub fn realInsideRoot(arena: std.mem.Allocator, path: []const u8) bool {
    if (!insideRoot(arena, path)) return false;
    if (tool_root.len == 0) return true;
    const resolved = resolvePath(arena, path);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_n = std.Io.Dir.cwd().realPathFile(util.io, tool_root, &root_buf) catch return true;
    const root_real = root_buf[0..root_n];
    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.cwd().realPathFile(util.io, resolved, &dest_buf)) |n| {
        return pathUnder(dest_buf[0..n], root_real);
    } else |_| {
        const parent = std.fs.path.dirname(resolved) orelse ".";
        if (std.Io.Dir.cwd().realPathFile(util.io, parent, &dest_buf)) |n| {
            return pathUnder(dest_buf[0..n], root_real);
        } else |_| {
            return false;
        }
    }
}

pub fn absWorkspace(arena: std.mem.Allocator) []const u8 {
    if (rootForSpawn()) |r| {
        if (std.fs.path.isAbsolute(r)) return r;
        const cwd = std.process.currentPathAlloc(util.io, arena) catch return r;
        return std.fs.path.join(arena, &.{ cwd, r }) catch r;
    }
    return std.process.currentPathAlloc(util.io, arena) catch ".";
}

pub fn artifactDir(arena: std.mem.Allocator) []const u8 {
    const dir = util.configDir(arena) catch return "";
    return util.joinPath(arena, dir, "artifacts") catch "";
}

pub fn diskWrite(path: []const u8, data: []const u8) !void {
    const f = seams.fs();
    var tmp_buf: [4096]u8 = undefined;
    if (path.len + 16 < tmp_buf.len) {
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.piz.tmp", .{path}) catch null;
        if (tmp) |tpath| {
            if (f.writeFile(f.ctx, tpath, data)) {
                if (std.Io.Dir.rename(std.Io.Dir.cwd(), tpath, std.Io.Dir.cwd(), path, util.io)) {
                    return;
                } else |_| {
                    std.Io.Dir.cwd().deleteFile(util.io, tpath) catch |err| util.debugCatch("diskWrite.tmp", err);
                }
            } else |_| {}
        }
    }
    return f.writeFile(f.ctx, path, data);
}

pub fn diskMkdir(path: []const u8) void {
    const f = seams.fs();
    f.createDirPath(f.ctx, path) catch |err| util.debugCatch("diskMkdir", err);
}

test "realInsideRoot rejects symlink escape" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "ok.txt", .data = "x" });
    tmp.dir.symLink(util.io, "ok.txt", "alias", .{}) catch return error.SkipZigTest;
    tmp.dir.symLink(util.io, "/etc/hosts", "escape", .{}) catch return error.SkipZigTest;
    setRoot(root);
    defer clearRoot();
    try t.expect(realInsideRoot(a, "ok.txt"));
    try t.expect(realInsideRoot(a, "alias"));
    try t.expect(realInsideRoot(a, "new.txt"));
    try t.expect(!realInsideRoot(a, "escape"));
    try t.expect(!realInsideRoot(a, "/etc/hosts"));
    try t.expect(!realInsideRoot(a, "../secret"));
}
