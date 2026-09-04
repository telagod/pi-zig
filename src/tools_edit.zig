// tools_edit.zig — edit / multi_edit. Split from tools.zig.
const std = @import("std");
const util = @import("util.zig");
const tjson = @import("tools_json.zig");
const tpath = @import("tools_path.zig");

const parseArgs = tjson.parseArgs;
const jstr = tjson.jstr;
const jbool = tjson.jbool;
const resolvePath = tpath.resolvePath;
const diskRead = tpath.diskRead;
const diskWrite = tpath.diskWrite;

const MAX_TOOL_OUTPUT = 16 * 1024;

pub const Result = struct {
    content: []const u8,
    is_error: bool = false,
};

fn outsideWorkspace(arena: std.mem.Allocator, path: []const u8) ?Result {
    if (tpath.realInsideRoot(arena, path)) return null;
    return .{ .content = "error: path is outside the workspace", .is_error = true };
}

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

const ReplaceErr = error{ NotFound, NotUnique };

fn countMatches(hay: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var n: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, hay, idx, needle)) |found| {
        n += 1;
        idx = found + needle.len;
    }
    return n;
}

fn replaceAt(buf: *std.array_list.Managed(u8), pos: usize, old_len: usize, new_text: []const u8) !void {
    if (new_text.len == old_len) {
        @memcpy(buf.items[pos .. pos + new_text.len], new_text);
        return;
    }
    if (new_text.len > old_len) {
        const grow = new_text.len - old_len;
        try buf.resize(buf.items.len + grow);
        std.mem.copyBackwards(u8, buf.items[pos + new_text.len ..], buf.items[pos + old_len .. buf.items.len - grow]);
        @memcpy(buf.items[pos .. pos + new_text.len], new_text);
        return;
    }
    std.mem.copyForwards(u8, buf.items[pos + new_text.len ..], buf.items[pos + old_len ..]);
    try buf.resize(buf.items.len - (old_len - new_text.len));
    @memcpy(buf.items[pos .. pos + new_text.len], new_text);
}

fn stripLinePrefix(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and i < 6 and line[i] == ' ') i += 1;
    if (i == 0) return line;
    const digs = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
    if (i == digs or i >= line.len or line[i] != '|') return line;
    return line[i + 1 ..];
}

fn stripReadLineNums(arena: std.mem.Allocator, s: []const u8) []const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    var it = std.mem.splitScalar(u8, s, '\n');
    var first = true;
    var stripped_any = false;
    while (it.next()) |line| {
        if (!first) aw.writer.writeByte('\n') catch |err| util.debugCatch("stripLine.nl", err);
        first = false;
        const cut = stripLinePrefix(line);
        if (cut.ptr != line.ptr) stripped_any = true;
        aw.writer.writeAll(cut) catch |err| util.debugCatch("stripLine.cut", err);
    }
    if (!stripped_any) return s;
    return aw.toOwnedSlice() catch s;
}

fn stripCr(arena: std.mem.Allocator, s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\r') == null) return s;
    var out = std.array_list.Managed(u8).init(arena);
    for (s) |b| {
        if (b != '\r') out.append(b) catch return s;
    }
    return out.toOwnedSlice() catch s;
}

fn prepareEdit(arena: std.mem.Allocator, hay: []const u8, old_text: []const u8, new_text: []const u8) struct { old: []const u8, new: []const u8 } {
    if (countMatches(hay, old_text) > 0) return .{ .old = old_text, .new = new_text };
    const so = stripReadLineNums(arena, old_text);
    if (countMatches(hay, so) > 0) {
        return .{ .old = so, .new = stripReadLineNums(arena, new_text) };
    }
    // CRLF 规范化容错: 若 hay 为纯 LF 且 old_text 带 \r, 剥离 \r 后再匹配
    const nocr_old = stripCr(arena, so);
    if (countMatches(hay, nocr_old) > 0) {
        return .{ .old = nocr_old, .new = stripCr(arena, stripReadLineNums(arena, new_text)) };
    }
    if (!std.mem.eql(u8, so, old_text)) {
        return .{ .old = so, .new = stripReadLineNums(arena, new_text) };
    }
    return .{ .old = old_text, .new = new_text };
}

fn firstNeedleLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (std.mem.indexOfScalar(u8, t, '\n')) |nl| return std.mem.trimEnd(u8, t[0..nl], " \t\r");
    return t;
}

fn hintMissing(arena: std.mem.Allocator, hay: []const u8, needle: []const u8) []const u8 {
    const key0 = firstNeedleLine(needle);
    if (key0.len < 2) return "";
    var n = @min(key0.len, 48);
    var pos: ?usize = null;
    while (n >= 2) {
        pos = std.mem.indexOf(u8, hay, key0[0..n]);
        if (pos != null) break;
        n = if (n > 8) n * 3 / 4 else n - 1;
    }
    const at = pos orelse return "";
    var start = at;
    while (start > 0 and hay[start - 1] != '\n') start -= 1;
    if (start > 0) {
        var p = start - 1;
        while (p > 0 and hay[p - 1] != '\n') p -= 1;
        start = p;
    }
    var end = at;
    var lines: usize = 0;
    while (end < hay.len and lines < 3) : (end += 1) {
        if (hay[end] == '\n') lines += 1;
    }
    return std.fmt.allocPrint(arena, "\nnearest:\n{s}", .{hay[start..end]}) catch "";
}

fn applyReplace(buf: *std.array_list.Managed(u8), old_text: []const u8, new_text: []const u8, replace_all: bool) !usize {
    if (old_text.len == 0) return error.NotFound;
    const count = countMatches(buf.items, old_text);
    if (count == 0) return error.NotFound;
    if (count > 1 and !replace_all) return error.NotUnique;
    var left = count;
    var idx: usize = 0;
    while (left > 0) : (left -= 1) {
        const pos = std.mem.indexOfPos(u8, buf.items, idx, old_text) orelse return error.NotFound;
        try replaceAt(buf, pos, old_text.len, new_text);
        idx = pos + new_text.len;
    }
    return count;
}

pub fn toolEdit(arena: std.mem.Allocator, args: []const u8) !Result {
    const v = try parseArgs(arena, args);
    const path = resolvePath(arena, jstr(v, "path") orelse return .{ .content = "error: missing 'path' argument", .is_error = true });
    if (outsideWorkspace(arena, path)) |err| return err;
    const edits = v.object.get("edits") orelse return .{ .content = "error: missing 'edits' array", .is_error = true };
    if (edits != .array or edits.array.items.len == 0) {
        return .{ .content = "error: 'edits' must be a non-empty array", .is_error = true };
    }
    const dry = jbool(v, "dryRun") orelse false;
    const orig = diskRead(arena, path, 64 * 1024 * 1024) catch |err| {
        return .{ .content = try std.fmt.allocPrint(arena, "error reading {s}: {s}", .{ path, @errorName(err) }), .is_error = true };
    };
    var buf = std.array_list.Managed(u8).init(arena);
    try buf.appendSlice(orig);
    for (edits.array.items, 0..) |e, i| {
        if (e != .object) return .{ .content = "error: edit entry must be an object", .is_error = true };
        const old_text = jstr(e, "oldText") orelse return .{ .content = "error: edit missing oldText", .is_error = true };
        const new_text = jstr(e, "newText") orelse "";
        const replace_all = jbool(e, "replaceAll") orelse false;
        const pair = prepareEdit(arena, buf.items, old_text, new_text);
        _ = applyReplace(&buf, pair.old, pair.new, replace_all) catch |err| switch (err) {
            error.NotFound => return .{ .content = try std.fmt.allocPrint(arena, "error: edit {d}: oldText not found in {s}{s}", .{ i + 1, path, hintMissing(arena, buf.items, pair.old) }), .is_error = true },
            error.NotUnique => return .{ .content = try std.fmt.allocPrint(arena, "error: edit {d}: oldText matches {d} times in {s}, must be unique (or set replaceAll)", .{ i + 1, countMatches(buf.items, old_text), path }), .is_error = true },
            else => return err,
        };
    }
    if (!dry) {
        diskWrite(path, buf.items) catch |err| {
            return .{ .content = try std.fmt.allocPrint(arena, "error writing {s}: {s}", .{ path, @errorName(err) }), .is_error = true };
        };
    }
    var diff = std.array_list.Managed(u8).init(arena);
    const head = try std.fmt.allocPrint(arena, "{s}edited {s}: {d} replacements\n--- {s}\n+++ {s}\n", .{ if (dry) "dry-run " else "", path, edits.array.items.len, path, path });
    try diff.appendSlice(head);
    var n: usize = 0;
    for (edits.array.items) |e| {
        const old_text = jstr(e, "oldText") orelse "";
        const new_text = jstr(e, "newText") orelse "";
        var ol = std.mem.splitScalar(u8, old_text, '\n');
        while (ol.next()) |ln| : (n += 1) {
            if (n >= 40) break;
            try diff.appendSlice("-");
            try diff.appendSlice(ln);
            try diff.appendSlice("\n");
        }
        var nl = std.mem.splitScalar(u8, new_text, '\n');
        while (nl.next()) |ln| : (n += 1) {
            if (n >= 40) break;
            try diff.appendSlice("+");
            try diff.appendSlice(ln);
            try diff.appendSlice("\n");
        }
        if (n >= 40) {
            try diff.appendSlice("... (truncated)\n");
            break;
        }
    }
    return .{ .content = try diff.toOwnedSlice() };
}

pub fn toolMultiEdit(arena: std.mem.Allocator, args: []const u8) !Result {
    const v = try parseArgs(arena, args);
    const dry = jbool(v, "dryRun") orelse false;
    const files = v.object.get("files") orelse return .{ .content = "error: missing 'files' array", .is_error = true };
    if (files != .array or files.array.items.len == 0) {
        return .{ .content = "error: 'files' must be a non-empty array", .is_error = true };
    }

    const Pending = struct { path: []const u8, disk_path: []const u8, content: []const u8, n_edits: usize };
    var pending = std.array_list.Managed(Pending).init(arena);
    for (files.array.items) |f| {
        if (f != .object) return .{ .content = "error: files entry must be an object", .is_error = true };
        const path = jstr(f, "path") orelse return .{ .content = "error: files entry missing 'path'", .is_error = true };
        const disk_path = resolvePath(arena, path);
        if (outsideWorkspace(arena, disk_path)) |err| return err;
        const edits = f.object.get("edits") orelse return .{
            .content = try std.fmt.allocPrint(arena, "error: {s}: missing 'edits' array", .{path}),
            .is_error = true,
        };
        if (edits != .array or edits.array.items.len == 0) return .{
            .content = try std.fmt.allocPrint(arena, "error: {s}: 'edits' must be a non-empty array", .{path}),
            .is_error = true,
        };
        const orig = diskRead(arena, disk_path, 64 * 1024 * 1024) catch |err| {
            return .{
                .content = try std.fmt.allocPrint(arena, "error reading {s}: {s} — nothing was written", .{ path, @errorName(err) }),
                .is_error = true,
            };
        };
        var buf = std.array_list.Managed(u8).init(arena);
        try buf.appendSlice(orig);
        for (edits.array.items, 0..) |e, ei| {
            if (e != .object) return .{
                .content = try std.fmt.allocPrint(arena, "error: {s} edit[{d}]: must be an object — nothing was written", .{ path, ei }),
                .is_error = true,
            };
            const old_text = jstr(e, "oldText") orelse return .{
                .content = try std.fmt.allocPrint(arena, "error: {s} edit[{d}]: missing oldText — nothing was written", .{ path, ei }),
                .is_error = true,
            };
            const new_text = jstr(e, "newText") orelse "";
            const replace_all = jbool(e, "replaceAll") orelse false;
            const pair = prepareEdit(arena, buf.items, old_text, new_text);
            if (old_text.len == 0) return .{
                .content = try std.fmt.allocPrint(arena, "error: {s} edit[{d}]: oldText must not be empty — nothing was written", .{ path, ei }),
                .is_error = true,
            };
            _ = applyReplace(&buf, pair.old, pair.new, replace_all) catch |err| switch (err) {
                error.NotFound => return .{ .content = try std.fmt.allocPrint(arena, "error: {s} edit[{d}]: oldText not found — nothing was written{s}", .{ path, ei, hintMissing(arena, buf.items, pair.old) }), .is_error = true },
                error.NotUnique => return .{ .content = try std.fmt.allocPrint(arena, "error: {s} edit[{d}]: oldText matched {d} times, need exactly 1 or replaceAll — nothing was written", .{ path, ei, countMatches(buf.items, old_text) }), .is_error = true },
                else => return err,
            };
        }
        try pending.append(.{ .path = path, .disk_path = disk_path, .content = buf.items, .n_edits = edits.array.items.len });
    }

    if (!dry) {
        for (pending.items) |p| {
            diskWrite(p.disk_path, p.content) catch |err| {
                return .{
                    .content = try std.fmt.allocPrint(arena, "error writing {s}: {s} — earlier files in this batch were already written", .{ p.path, @errorName(err) }),
                    .is_error = true,
                };
            };
        }
    }

    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    try aw.writer.print("{s}edited {d} files:\n", .{ if (dry) "dry-run " else "", pending.items.len });
    for (pending.items) |p| {
        try aw.writer.print("  {s}: {d} replacements\n", .{ p.path, p.n_edits });
    }
    return capped(arena, aw.written(), "multi_edit", aw.written().len);
}
