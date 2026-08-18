// tools_read.zig — read + image attach + numbered slices. Split from tools.zig.
const std = @import("std");
const util = @import("util.zig");
const imgx = @import("imgx.zig");
const tjson = @import("tools_json.zig");
const tpath = @import("tools_path.zig");

const parseArgs = tjson.parseArgs;
const jstr = tjson.jstr;
const jint = tjson.jint;
const resolvePath = tpath.resolvePath;
const diskRead = tpath.diskRead;

const MAX_TOOL_OUTPUT = 16 * 1024;

pub const ImageAttach = struct {
    data: []const u8,
    mime: []const u8,
    w: u32,
    h: u32,
    note: []const u8,
};

pub const Result = struct {
    content: []const u8,
    is_error: bool = false,
    images: ?[]const ImageAttach = null,
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

fn isImageBytes(data: []const u8) bool {
    if (data.len >= 8 and std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) return true;
    if (data.len >= 3 and data[0] == 0xff and data[1] == 0xd8 and data[2] == 0xff) return true;
    if (data.len >= 6 and (std.mem.eql(u8, data[0..6], "GIF87a") or std.mem.eql(u8, data[0..6], "GIF89a"))) return true;
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) return true;
    if (data.len >= 2 and data[0] == 'B' and data[1] == 'M') return true;
    return false;
}

fn isImagePath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    const kinds = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp" };
    for (kinds) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

fn readImage(arena: std.mem.Allocator, path: []const u8, raw: []const u8) ?Result {
    if (!isImageBytes(raw) and !isImagePath(path)) return null;
    if (!isImageBytes(raw)) {
        const msg = std.fmt.allocPrint(arena, "image {s}: unrecognized or empty ({d} bytes)", .{ path, raw.len }) catch "image: unrecognized";
        return .{ .content = msg };
    }
    const out = imgx.process(arena, raw, .{}) catch {
        const msg = std.fmt.allocPrint(arena, "image {s}: decode failed ({d} bytes)", .{ path, raw.len }) catch "image: decode failed";
        return .{ .content = msg };
    };
    const note = std.fmt.allocPrint(arena, "image {s} ({s} {d}x{d}, {d} bytes)", .{ path, out.mime, out.w, out.h, out.bytes }) catch "image";
    const imgs = arena.alloc(ImageAttach, 1) catch return .{ .content = note };
    imgs[0] = .{ .data = out.data, .mime = out.mime, .w = out.w, .h = out.h, .note = note };
    return .{ .content = note, .images = imgs };
}

fn numberLines(arena: std.mem.Allocator, content: []const u8, start_line: usize, max_lines: ?usize) !struct { text: []const u8, found: bool, total: usize } {
    var aw = std.Io.Writer.Allocating.init(arena);
    var line_no: usize = 0;
    var emitted: usize = 0;
    var found = false;
    var pos: usize = 0;
    while (pos <= content.len) {
        const nl = std.mem.indexOfScalarPos(u8, content, pos, '\n');
        const end = nl orelse content.len;
        const line = content[pos..end];
        line_no += 1;
        if (nl == null and line.len == 0 and line_no > 1) {
            line_no -= 1;
            break;
        }
        if (line_no >= start_line) {
            if (max_lines) |m| {
                if (emitted >= m) break;
            }
            found = true;
            try aw.writer.print("{d: >6}|{s}\n", .{ line_no, line });
            emitted += 1;
        }
        if (nl == null) break;
        pos = end + 1;
    }
    return .{ .text = try aw.toOwnedSlice(), .found = found, .total = line_no };
}

fn countLines(content: []const u8) usize {
    if (content.len == 0) return 0;
    var line_no: usize = 0;
    var pos: usize = 0;
    while (pos <= content.len) {
        const nl = std.mem.indexOfScalarPos(u8, content, pos, '\n');
        const end = nl orelse content.len;
        const line = content[pos..end];
        line_no += 1;
        if (nl == null and line.len == 0 and line_no > 1) {
            line_no -= 1;
            break;
        }
        if (nl == null) break;
        pos = end + 1;
    }
    return line_no;
}

fn withLinkNote(arena: std.mem.Allocator, path: []const u8, r: Result) !Result {
    var buf: [4096]u8 = undefined;
    const n = std.Io.Dir.cwd().readLink(util.io, path, &buf) catch return r;
    const note = try std.fmt.allocPrint(arena, "symlink {s} -> {s}\n", .{ path, buf[0..n] });
    return .{ .content = try std.fmt.allocPrint(arena, "{s}{s}", .{ note, r.content }), .is_error = r.is_error, .images = r.images };
}

pub fn toolRead(arena: std.mem.Allocator, args: []const u8) !Result {
    const v = try parseArgs(arena, args);
    const path = resolvePath(arena, jstr(v, "path") orelse return .{ .content = "error: missing 'path' argument", .is_error = true });
    const content = diskRead(arena, path, 16 * 1024 * 1024) catch |err| {
        return .{ .content = try std.fmt.allocPrint(arena, "error reading {s}: {s}", .{ path, @errorName(err) }), .is_error = true };
    };
    const offset = jint(v, "offset");
    const limit = jint(v, "limit");
    const tail = jint(v, "tail");
    const around = jint(v, "around");
    if (tail != null and offset != null) {
        return .{ .content = "error: use tail or offset, not both", .is_error = true };
    }
    if (around != null and (offset != null or tail != null)) {
        return .{ .content = "error: use around or offset/tail, not both", .is_error = true };
    }
    if (offset == null and limit == null and tail == null and around == null) {
        if (readImage(arena, path, content)) |img| return withLinkNote(arena, path, img);
    }
    const start_line: usize, const max_lines: ?usize = if (around) |mid_raw| blk: {
        const mid: usize = if (mid_raw < 1) 1 else @intCast(mid_raw);
        const want: usize = if (limit) |l| (if (l < 1) 1 else @intCast(l)) else 41;
        const half = want / 2;
        const start = if (mid > half) mid - half else 1;
        break :blk .{ start, want };
    } else if (tail) |t| blk: {
        const want: usize = if (t < 1) 1 else @intCast(t);
        const total = countLines(content);
        const start = if (total > want) total - want + 1 else 1;
        break :blk .{ start, want };
    } else .{ if (offset) |o| (if (o < 1) 1 else @intCast(o)) else 1, if (limit) |l| (if (l < 1) 0 else @as(usize, @intCast(l))) else null };
    const numbered = try numberLines(arena, content, start_line, max_lines);
    if (!numbered.found) return .{
        .content = try std.fmt.allocPrint(arena, "error: offset {d} is past end of {s} ({d} lines)", .{ start_line, path, numbered.total }),
        .is_error = true,
    };
    return withLinkNote(arena, path, try capped(arena, numbered.text, path, content.len));
}

test "read notes symlink target" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(util.io, .{ .sub_path = "real.txt", .data = "hello\n" });
    tmp.dir.symLink(util.io, "real.txt", "alias.txt", .{}) catch return error.SkipZigTest;
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    tpath.setRoot(dir);
    defer tpath.clearRoot();
    const r = try toolRead(a, try std.fmt.allocPrint(a, "{{\"path\":\"{s}/alias.txt\"}}", .{dir}));
    try t.expect(!r.is_error);
    try t.expect(std.mem.indexOf(u8, r.content, "symlink ") != null);
    try t.expect(std.mem.indexOf(u8, r.content, "-> real.txt") != null);
    try t.expect(std.mem.indexOf(u8, r.content, "hello") != null);
}
