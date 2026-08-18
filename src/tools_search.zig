// tools_search.zig — grep / find / ls. Split from tools.zig.
const std = @import("std");
const util = @import("util.zig");
const tjson = @import("tools_json.zig");
const tpath = @import("tools_path.zig");
const fs_walk = @import("tools_fs.zig");

const parseArgs = tjson.parseArgs;
const jstr = tjson.jstr;
const jint = tjson.jint;
const jbool = tjson.jbool;
const resolvePath = tpath.resolvePath;
const diskRead = tpath.diskRead;
const loadIgnoreRules = fs_walk.loadIgnoreRules;
const pathIgnored = fs_walk.pathIgnored;
const pathExcluded = fs_walk.pathExcluded;
const globMatchEx = fs_walk.globMatchEx;
const collectFiles = fs_walk.collectFiles;
const looksBinary = fs_walk.looksBinary;
const Regex = fs_walk.Regex;
const isSkippedDir = fs_walk.isSkippedDir;
const WalkKind = fs_walk.WalkKind;
const IgnoreRule = fs_walk.IgnoreRule;

const MAX_TOOL_OUTPUT = 16 * 1024;

pub const Result = struct {
    content: []const u8,
    is_error: bool = false,
};

fn capped(arena: std.mem.Allocator, body: []const u8, path: []const u8, total: usize) !Result {
    if (body.len <= MAX_TOOL_OUTPUT) return .{ .content = try arena.dupe(u8, body) };
    const keep = MAX_TOOL_OUTPUT / 2;
    const head = util.utf8Prefix(body, keep);
    const tail = util.utf8Suffix(body, keep);
    const omitted = body.len -| (head.len + tail.len);
    return .{ .content = try std.fmt.allocPrint(arena, "{s}\n...[{s} truncated at {d} bytes, omitted {d}, total {d}; use offset/limit]...\n{s}", .{
        head,
        path,
        MAX_TOOL_OUTPUT,
        omitted,
        total,
        tail,
    }) };
}

pub fn toolGrep(arena: std.mem.Allocator, args: []const u8) !Result {
    const v = try parseArgs(arena, args);
    const pattern = jstr(v, "pattern") orelse return .{ .content = "error: missing 'pattern' argument", .is_error = true };
    if (pattern.len == 0) return .{ .content = "error: 'pattern' must not be empty", .is_error = true };
    const root = resolvePath(arena, jstr(v, "path") orelse ".");
    const glob = jstr(v, "glob");
    const exclude = jstr(v, "exclude");
    const ignore_case = jbool(v, "ignoreCase") orelse false;
    const literal = jbool(v, "literal") orelse false;
    const ctx_lines: usize = if (jint(v, "context")) |c| @intCast(@max(0, @min(c, 10))) else 0;
    const limit: usize = if (jint(v, "limit")) |l| @intCast(@max(1, @min(l, 2000))) else 200;
    const files_with = jbool(v, "filesWithMatches") orelse false;
    const invert = jbool(v, "invert") orelse false;
    const count_only = jbool(v, "count") orelse false;
    const max_depth: u8 = if (jint(v, "maxDepth")) |n|
        @intCast(@max(1, @min(n, 32)))
    else
        32;
    const max_bytes: usize = if (jint(v, "maxBytes")) |n|
        @intCast(@max(1, @min(n, 8 * 1024 * 1024)))
    else
        1024 * 1024;

    var re: ?Regex = null;
    if (!literal) {
        re = Regex.init(pattern, ignore_case) catch |err| {
            return .{
                .content = try std.fmt.allocPrint(arena, "error: bad pattern '{s}': {s}. Supported: char classes, . * + ? ^ $, escapes \\d \\w \\s. Not supported: groups, alternation |. Use literal=true for plain text.", .{ pattern, @errorName(err) }),
                .is_error = true,
            };
        };
    }

    // 候选文件:单文件直接用,目录则递归收集
    var files = std.array_list.Managed([]const u8).init(arena);
    const single = blk: {
        var d = std.Io.Dir.cwd().openDir(util.io, root, .{}) catch break :blk true;
        d.close(util.io);
        break :blk false;
    };
    if (single) {
        try files.append(root);
    } else {
        // 收集上限放宽,glob 过滤后才是真正的搜索集
        try collectFiles(arena, &files, root, "", 20000, 0, loadIgnoreRules(arena, root), .files, max_depth);
    }

    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    var hits: usize = 0;
    var scanned: usize = 0;
    var skipped_big: usize = 0;
    var truncated = false;

    for (files.items) |rel| {
        if (hits >= limit) {
            truncated = true;
            break;
        }
        if (glob) |g| {
            // glob 同时试全路径与 basename(模型常写 "*.zig" 期望匹配任意层级)
            if (!globMatchEx(g, rel, ignore_case) and !globMatchEx(g, std.fs.path.basename(rel), ignore_case)) continue;
        }
        if (pathExcluded(exclude, rel, ignore_case)) continue;
        const full = if (single) rel else try util.joinPath(arena, root, rel);
        if (!single and fs_walk.escapingLink(arena, full)) continue;
        if (!single) {
            if (std.Io.Dir.cwd().statFile(util.io, full, .{})) |st| {
                if (st.size > max_bytes) {
                    skipped_big += 1;
                    continue;
                }
            } else |_| {}
        }
        const data = diskRead(arena, full, if (single) 8 * 1024 * 1024 else max_bytes) catch continue;
        if (looksBinary(data)) continue;
        scanned += 1;

        // 行切分后逐行匹配;context 需要回看,故先物化行数组
        var lines = std.array_list.Managed([]const u8).init(arena);
        var lit = std.mem.splitScalar(u8, data, '\n');
        while (lit.next()) |ln| try lines.append(ln);

        if (count_only) {
            var n: usize = 0;
            for (lines.items) |line| {
                const matched = if (literal)
                    (if (ignore_case) asciiContainsIgnoreCase(line, pattern) else std.mem.indexOf(u8, line, pattern) != null)
                else
                    re.?.search(line);
                if (matched != invert) n += 1;
            }
            if (n > 0) {
                if (hits >= limit) {
                    truncated = true;
                } else {
                    try aw.writer.print("{s}:{d}\n", .{ full, n });
                    hits += 1;
                }
            }
            continue;
        }
        var last_printed: ?usize = null;
        var any_match = false;
        for (lines.items, 0..) |line, idx| {
            if (hits >= limit) {
                truncated = true;
                break;
            }
            const matched = if (literal)
                (if (ignore_case) asciiContainsIgnoreCase(line, pattern) else std.mem.indexOf(u8, line, pattern) != null)
            else
                re.?.search(line);
            if (matched) any_match = true;
            if (files_with) {
                if (matched and !invert) {
                    try aw.writer.print("{s}\n", .{full});
                    hits += 1;
                    break;
                }
                continue;
            }
            if (matched == invert) continue;

            // 上下文前置行(用 `-` 分隔符,仿 GNU grep)。invert 时不扩上下文。
            if (!invert and ctx_lines > 0) {
                const from = if (idx >= ctx_lines) idx - ctx_lines else 0;
                var c = from;
                while (c < idx) : (c += 1) {
                    if (last_printed) |lp| {
                        if (c <= lp) continue;
                    }
                    try aw.writer.print("{s}-{d}-{s}\n", .{ full, c + 1, lines.items[c] });
                    last_printed = c;
                }
            }
            try aw.writer.print("{s}:{d}:{s}\n", .{ full, idx + 1, line });
            last_printed = idx;
            hits += 1;
            // 上下文后置行
            if (!invert and ctx_lines > 0) {
                var c = idx + 1;
                const to = @min(idx + ctx_lines, lines.items.len - 1);
                while (c <= to) : (c += 1) {
                    try aw.writer.print("{s}-{d}-{s}\n", .{ full, c + 1, lines.items[c] });
                    last_printed = c;
                }
            }
        }
        if (files_with and invert and !any_match) {
            if (hits >= limit) {
                truncated = true;
            } else {
                try aw.writer.print("{s}\n", .{full});
                hits += 1;
            }
        }
    }

    if (hits == 0) {
        if (skipped_big > 0) {
            return .{ .content = try std.fmt.allocPrint(arena, "no matches for '{s}' in {s} ({d} files scanned, {d} skipped as >{d} bytes; raise maxBytes)", .{ pattern, root, scanned, skipped_big, max_bytes }) };
        }
        return .{ .content = try std.fmt.allocPrint(arena, "no matches for '{s}' in {s} ({d} files scanned)", .{ pattern, root, scanned }) };
    }
    if (truncated) {
        try aw.writer.print("...[stopped at {d} matches; narrow the pattern or raise limit]...\n", .{limit});
    }
    if (skipped_big > 0) {
        try aw.writer.print("...[{d} files skipped as >{d} bytes; raise maxBytes]...\n", .{ skipped_big, max_bytes });
    }
    return capped(arena, aw.written(), "grep", aw.written().len);
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return needle.len == 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// find: {pattern, path?, limit?} — glob 匹配文件路径,递归。
pub fn toolFind(arena: std.mem.Allocator, args: []const u8) !Result {
    const v = try parseArgs(arena, args);
    const pattern = jstr(v, "pattern") orelse return .{ .content = "error: missing 'pattern' argument", .is_error = true };
    const root = resolvePath(arena, jstr(v, "path") orelse ".");
    const limit: usize = if (jint(v, "limit")) |l| @intCast(@max(1, @min(l, 2000))) else 200;
    const max_depth: u8 = if (jint(v, "maxDepth")) |n|
        @intCast(@max(1, @min(n, 32)))
    else
        32;
    const sort_mtime = if (jstr(v, "sort")) |s| std.mem.eql(u8, s, "mtime") else false;
    const ignore_case = jbool(v, "ignoreCase") orelse false;
    const exclude = jstr(v, "exclude");
    const typ = jstr(v, "type") orelse "any";
    const walk: WalkKind = if (std.mem.eql(u8, typ, "dir") or std.mem.eql(u8, typ, "directory"))
        .dirs
    else if (std.mem.eql(u8, typ, "file"))
        .files
    else if (std.mem.eql(u8, typ, "any") or typ.len == 0)
        .all
    else
        return .{ .content = "error: type must be file, dir, or any", .is_error = true };

    var files = std.array_list.Managed([]const u8).init(arena);
    try collectFiles(arena, &files, root, "", 20000, 0, loadIgnoreRules(arena, root), walk, max_depth);

    const Hit = struct { path: []const u8, mtime: i128, is_dir: bool };
    var hits = std.array_list.Managed(Hit).init(arena);
    for (files.items) |rel| {
        const is_dir = std.mem.endsWith(u8, rel, "/");
        const bare = if (is_dir) rel[0 .. rel.len - 1] else rel;
        // 同时试全路径与 basename:模型写 "*.zig" 通常想匹配任意层级
        if (!globMatchEx(pattern, bare, ignore_case) and !globMatchEx(pattern, std.fs.path.basename(bare), ignore_case)) continue;
        if (pathExcluded(exclude, bare, ignore_case)) continue;
        const full = try util.joinPath(arena, root, bare);
        var mtime: i128 = 0;
        if (sort_mtime) {
            if (std.Io.Dir.cwd().statFile(util.io, full, .{})) |st| {
                mtime = st.mtime.nanoseconds;
            } else |_| {}
        }
        try hits.append(.{ .path = full, .mtime = mtime, .is_dir = is_dir });
    }
    if (sort_mtime) {
        std.mem.sort(Hit, hits.items, {}, struct {
            fn lt(_: void, a: Hit, b: Hit) bool {
                return a.mtime > b.mtime;
            }
        }.lt);
    }

    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    var n: usize = 0;
    for (hits.items) |h| {
        if (n >= limit) break;
        var lbuf: [4096]u8 = undefined;
        if (std.Io.Dir.cwd().readLink(util.io, h.path, &lbuf)) |ln| {
            if (h.is_dir) {
                try aw.writer.print("{s}/ -> {s}\n", .{ h.path, lbuf[0..ln] });
            } else {
                try aw.writer.print("{s} -> {s}\n", .{ h.path, lbuf[0..ln] });
            }
        } else |_| {
            if (h.is_dir) {
                try aw.writer.print("{s}/\n", .{h.path});
            } else {
                try aw.writer.print("{s}\n", .{h.path});
            }
        }
        n += 1;
    }
    if (n == 0) {
        return .{ .content = try std.fmt.allocPrint(arena, "no matches for '{s}' under {s}", .{ pattern, root }) };
    }
    if (n >= limit) try aw.writer.print("...[stopped at {d} results]...\n", .{limit});
    return capped(arena, aw.written(), "find", aw.written().len);
}

/// ls: {path?, limit?} — 列目录条目,目录优先按名排序。
pub fn toolLs(arena: std.mem.Allocator, args: []const u8) !Result {
    const v = try parseArgs(arena, args);
    const path = resolvePath(arena, jstr(v, "path") orelse ".");
    const limit: usize = if (jint(v, "limit")) |l| @intCast(@max(1, @min(l, 2000))) else 200;
    const show_all = jbool(v, "all") orelse false;
    const sort_mtime = if (jstr(v, "sort")) |s| std.mem.eql(u8, s, "mtime") else false;
    const typ = jstr(v, "type") orelse "any";
    const exclude = jstr(v, "exclude");
    const want_dir = std.mem.eql(u8, typ, "dir") or std.mem.eql(u8, typ, "directory");
    const want_file = std.mem.eql(u8, typ, "file");
    if (!want_dir and !want_file and !std.mem.eql(u8, typ, "any") and typ.len != 0) {
        return .{ .content = "error: type must be file, dir, or any", .is_error = true };
    }
    const rules = if (show_all) &[_]IgnoreRule{} else loadIgnoreRules(arena, path);

    var dir = std.Io.Dir.cwd().openDir(util.io, path, .{ .iterate = true }) catch |err| {
        return .{ .content = try std.fmt.allocPrint(arena, "error listing {s}: {s}", .{ path, @errorName(err) }), .is_error = true };
    };
    defer dir.close(util.io);

    const Entry = struct { name: []const u8, is_dir: bool, size: u64, mtime: i128, link: ?[]const u8 };
    var entries = std.array_list.Managed(Entry).init(arena);
    var hidden: usize = 0;
    var it = dir.iterate();
    while (it.next(util.io) catch null) |e| {
        const is_dir = e.kind == .directory;
        if (want_dir and !is_dir) continue;
        if (want_file and is_dir) continue;
        if (pathExcluded(exclude, e.name, false)) continue;
        if (!show_all) {
            if (isSkippedDir(e.name) or pathIgnored(arena, rules, e.name, is_dir)) {
                hidden += 1;
                continue;
            }
        }
        var size: u64 = 0;
        var mtime: i128 = 0;
        var link: ?[]const u8 = null;
        const full = try util.joinPath(arena, path, e.name);
        if (std.Io.Dir.cwd().statFile(util.io, full, .{})) |st| {
            if (e.kind == .file) size = st.size;
            if (sort_mtime) mtime = st.mtime.nanoseconds;
        } else |_| {}
        if (e.kind == .sym_link) {
            var buf: [4096]u8 = undefined;
            if (dir.readLink(util.io, e.name, &buf)) |n| {
                link = try arena.dupe(u8, buf[0..n]);
            } else |_| {}
        }
        try entries.append(.{
            .name = try arena.dupe(u8, e.name),
            .is_dir = is_dir,
            .size = size,
            .mtime = mtime,
            .link = link,
        });
    }
    if (sort_mtime) {
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                return a.mtime > b.mtime;
            }
        }.lt);
    } else {
        // 目录优先,同类按名字典序
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                if (a.is_dir != b.is_dir) return a.is_dir;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
    }

    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    if (hidden > 0) {
        try aw.writer.print("{s}/ ({d} entries, {d} hidden — pass all=true)\n", .{ path, entries.items.len, hidden });
    } else {
        try aw.writer.print("{s}/ ({d} entries)\n", .{ path, entries.items.len });
    }
    for (entries.items, 0..) |e, i| {
        if (i >= limit) {
            try aw.writer.print("...[stopped at {d} entries]...\n", .{limit});
            break;
        }
        if (e.link) |tgt| {
            if (e.is_dir) {
                try aw.writer.print("  {s}/ -> {s}\n", .{ e.name, tgt });
            } else {
                try aw.writer.print("  {s} -> {s}  {d}B\n", .{ e.name, tgt, e.size });
            }
        } else if (e.is_dir) {
            try aw.writer.print("  {s}/\n", .{e.name});
        } else {
            try aw.writer.print("  {s}  {d}B\n", .{ e.name, e.size });
        }
    }
    return capped(arena, aw.written(), "ls", aw.written().len);
}

test "ls shows symlink targets" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(util.io, .{ .sub_path = "real.txt", .data = "hi" });
    tmp.dir.symLink(util.io, "real.txt", "alias.txt", .{}) catch return error.SkipZigTest;
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    tpath.setRoot(dir);
    defer tpath.clearRoot();
    const r = try toolLs(a, try std.fmt.allocPrint(a, "{{\"path\":\"{s}\"}}", .{dir}));
    try t.expect(!r.is_error);
    try t.expect(std.mem.indexOf(u8, r.content, "alias.txt -> real.txt") != null);
}

test "find lists symlink files without following" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(util.io, .{ .sub_path = "real.txt", .data = "hi" });
    tmp.dir.symLink(util.io, "real.txt", "alias.txt", .{}) catch return error.SkipZigTest;
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    tpath.setRoot(dir);
    defer tpath.clearRoot();
    const r = try toolFind(a, try std.fmt.allocPrint(a, "{{\"pattern\":\"alias.txt\",\"path\":\"{s}\"}}", .{dir}));
    try t.expect(!r.is_error);
    try t.expect(std.mem.indexOf(u8, r.content, "alias.txt -> real.txt") != null);
}
