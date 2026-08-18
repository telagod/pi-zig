// tools_files.zig — workspace file listing for Web /api/files and TUI @ complete.
const std = @import("std");
const util = @import("util.zig");
const fs_walk = @import("tools_fs.zig");
const tpath = @import("tools_path.zig");

pub const files_limit: usize = 40;
pub const files_scan: usize = 512;

pub const FileItem = struct {
    name: []const u8,
    path: []const u8,
    dir: bool,
    link: ?[]const u8 = null,
};

pub fn startsWithInsensitive(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    for (needle, 0..) |c, i| {
        if (std.ascii.toLower(hay[i]) != std.ascii.toLower(c)) return false;
    }
    return true;
}

/// Collapse `.` / `..`, strip `@` / `./`, reject absolute and escape.
pub fn normalizeRel(alloc: std.mem.Allocator, q: []const u8) !struct { rel: []u8, trail: bool } {
    if (q.len > 256) return error.BadPath;
    var s = q;
    if (s.len > 0 and s[0] == '@') s = s[1..];
    if (s.len >= 2 and s[0] == '.' and s[1] == '/') s = s[2..];
    if (s.len == 1 and s[0] == '.') s = s[1..];
    if (s.len > 0 and (s[0] == '/' or s[0] == '\\')) return error.BadPath;
    const trail = s.len > 0 and s[s.len - 1] == '/';
    var parts = std.array_list.Managed([]const u8).init(alloc);
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.items.len == 0) return error.BadPath;
            _ = parts.pop();
            continue;
        }
        if (std.mem.indexOfAny(u8, p, "\\\x00") != null) return error.BadPath;
        try parts.append(p);
    }
    if (parts.items.len == 0) return .{ .rel = try alloc.dupe(u8, ""), .trail = trail };
    return .{ .rel = try std.mem.join(alloc, "/", parts.items), .trail = trail };
}

pub fn isNoiseName(name: []const u8, show_hidden: bool) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return true;
    if (fs_walk.isSkippedDir(name)) return true;
    if (!show_hidden and name[0] == '.') return true;
    return false;
}

pub fn listWorkspaceFiles(alloc: std.mem.Allocator, root: []const u8, q: []const u8) ![]FileItem {
    const norm = try normalizeRel(alloc, q);
    const dir_rel, const name_prefix = blk: {
        if (norm.trail or norm.rel.len == 0) break :blk .{ norm.rel, @as([]const u8, "") };
        if (std.mem.lastIndexOfScalar(u8, norm.rel, '/')) |i|
            break :blk .{ norm.rel[0..i], norm.rel[i + 1 ..] };
        break :blk .{ @as([]const u8, ""), norm.rel };
    };
    const show_hidden = name_prefix.len > 0 and name_prefix[0] == '.';
    const abs_dir = if (dir_rel.len == 0) root else try util.joinPath(alloc, root, dir_rel);
    const rules = fs_walk.ignoreRulesFor(alloc, root, dir_rel);
    const saved_root = tpath.currentRoot();
    tpath.setRoot(root);
    defer tpath.setRoot(saved_root);
    var dir = std.Io.Dir.cwd().openDir(util.io, abs_dir, .{ .iterate = true }) catch return error.BadPath;
    defer dir.close(util.io);
    var items = std.array_list.Managed(FileItem).init(alloc);
    var scanned: usize = 0;
    var it = dir.iterate();
    while (it.next(util.io) catch null) |entry| {
        scanned += 1;
        if (scanned > files_scan) break;
        if (isNoiseName(entry.name, show_hidden)) continue;
        if (name_prefix.len > 0 and !startsWithInsensitive(entry.name, name_prefix)) continue;
        const child_abs = try util.joinPath(alloc, abs_dir, entry.name);
        if (entry.kind == .sym_link and fs_walk.escapingLink(alloc, child_abs)) continue;
        const is_dir = if (entry.kind == .directory)
            true
        else if (entry.kind == .sym_link) blk: {
            if (std.Io.Dir.cwd().statFile(util.io, child_abs, .{})) |st| {
                break :blk st.kind == .directory;
            } else |_| break :blk false;
        } else false;
        const name = try alloc.dupe(u8, entry.name);
        const path = if (dir_rel.len == 0)
            try alloc.dupe(u8, name)
        else
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_rel, name });
        if (fs_walk.pathIgnored(alloc, rules, path, is_dir)) continue;
        var link: ?[]const u8 = null;
        if (entry.kind == .sym_link) {
            var lbuf: [4096]u8 = undefined;
            if (dir.readLink(util.io, entry.name, &lbuf)) |n| {
                link = try alloc.dupe(u8, lbuf[0..n]);
            } else |_| {}
        }
        try items.append(.{ .name = name, .path = path, .dir = is_dir, .link = link });
    }
    std.mem.sort(FileItem, items.items, {}, struct {
        fn less(_: void, a: FileItem, b: FileItem) bool {
            if (a.dir != b.dir) return a.dir;
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.less);
    if (items.items.len > files_limit) items.shrinkRetainingCapacity(files_limit);
    return items.toOwnedSlice();
}

/// Last token `@./prefix` / `@prefix` at end of input. Returns the path query.
pub fn atQuery(input: []const u8) ?[]const u8 {
    if (input.len == 0) return null;
    var start: usize = 0;
    if (std.mem.lastIndexOfAny(u8, input, " \t")) |sp| start = sp + 1;
    const tok = input[start..];
    if (tok.len == 0 or tok[0] != '@') return null;
    const rest = tok[1..];
    if (std.mem.startsWith(u8, rest, "./")) return rest[2..];
    if (rest.len == 1 and rest[0] == '.') return "";
    return rest;
}

/// Byte offset of the `@` token, if atQuery is active.
pub fn atTokenStart(input: []const u8) ?usize {
    if (atQuery(input) == null) return null;
    if (std.mem.lastIndexOfAny(u8, input, " \t")) |sp| return sp + 1;
    return 0;
}

test "atQuery detects @./ tokens" {
    const t = std.testing;
    try t.expectEqualStrings("", atQuery("@").?);
    try t.expectEqualStrings("", atQuery("@./").?);
    try t.expectEqualStrings("src", atQuery("see @./src").?);
    try t.expectEqualStrings("src/f", atQuery("see @./src/f").?);
    try t.expect(atQuery("see @./src foo") == null);
    try t.expect(atQuery("mail @someone") != null);
    try t.expect(atQuery("hello") == null);
    try t.expectEqual(@as(usize, 4), atTokenStart("see @./src").?);
}

test "normalizeRel strips @./ and rejects escape" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try normalizeRel(a, "@./src/");
    try t.expectEqualStrings("src", n.rel);
    try t.expect(n.trail);
    try t.expectError(error.BadPath, normalizeRel(a, "../secret"));
    try t.expectError(error.BadPath, normalizeRel(a, "/etc"));
}

test "listWorkspaceFiles hides gitignored names" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(util.io, ".git");
    try tmp.dir.writeFile(util.io, .{ .sub_path = ".gitignore", .data = "secret.txt\n*.log\nbuild/\n" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "keep.txt", .data = "k" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "secret.txt", .data = "s" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "noise.log", .data = "n" });
    try tmp.dir.createDirPath(util.io, "build");
    try tmp.dir.createDirPath(util.io, "src");
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    const items = try listWorkspaceFiles(a, root, "");
    var names = std.array_list.Managed([]const u8).init(a);
    for (items) |it| try names.append(it.name);
    const joined = try std.mem.join(a, ",", names.items);
    try t.expect(std.mem.indexOf(u8, joined, "keep.txt") != null);
    try t.expect(std.mem.indexOf(u8, joined, "src") != null);
    try t.expect(std.mem.indexOf(u8, joined, "secret.txt") == null);
    try t.expect(std.mem.indexOf(u8, joined, "noise.log") == null);
    try t.expect(std.mem.indexOf(u8, joined, "build") == null);
}

test "listWorkspaceFiles includes in-workspace symlink and hides escape" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(util.io, .{ .sub_path = "real.txt", .data = "x" });
    tmp.dir.symLink(util.io, "real.txt", "alias.txt", .{}) catch return error.SkipZigTest;
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    const other = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, outside.sub_path });
    tmp.dir.symLink(util.io, other, "out", .{}) catch return error.SkipZigTest;
    const items = try listWorkspaceFiles(a, root, "");
    var names = std.array_list.Managed([]const u8).init(a);
    for (items) |it| try names.append(it.name);
    const joined = try std.mem.join(a, ",", names.items);
    try t.expect(std.mem.indexOf(u8, joined, "alias.txt") != null);
    try t.expect(std.mem.indexOf(u8, joined, "out") == null);
    var saw_alias = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.name, "alias.txt")) {
            saw_alias = true;
            try t.expect(it.link != null);
            try t.expectEqualStrings("real.txt", it.link.?);
        }
    }
    try t.expect(saw_alias);
}
