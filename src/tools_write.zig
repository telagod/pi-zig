// tools_write.zig — write + dryRun preview. Split from tools.zig.
const std = @import("std");
const util = @import("util.zig");
const tjson = @import("tools_json.zig");
const tpath = @import("tools_path.zig");

const parseArgs = tjson.parseArgs;
const jstr = tjson.jstr;
const jbool = tjson.jbool;
const resolvePath = tpath.resolvePath;
const diskWrite = tpath.diskWrite;
const diskMkdir = tpath.diskMkdir;

pub const Result = struct {
    content: []const u8,
    is_error: bool = false,
};

fn outsideWorkspace(arena: std.mem.Allocator, path: []const u8) ?Result {
    if (tpath.realInsideRoot(arena, path)) return null;
    return .{ .content = "error: path is outside the workspace", .is_error = true };
}

pub fn toolWrite(arena: std.mem.Allocator, args: []const u8) !Result {
    const v = try parseArgs(arena, args);
    const path = resolvePath(arena, jstr(v, "path") orelse return .{ .content = "error: missing 'path' argument", .is_error = true });
    if (outsideWorkspace(arena, path)) |err| return err;
    const content = jstr(v, "content") orelse "";
    const create_only = jbool(v, "createOnly") orelse false;
    const dry = jbool(v, "dryRun") orelse false;
    if (create_only) {
        if (std.Io.Dir.cwd().statFile(util.io, path, .{})) |_| {
            return .{ .content = try std.fmt.allocPrint(arena, "error: {s} already exists (createOnly)", .{path}), .is_error = true };
        } else |_| {}
    }
    if (!dry) {
        if (std.fs.path.dirname(path)) |d| {
            if (d.len > 0) diskMkdir(d);
        }
        diskWrite(path, content) catch |err| {
            return .{ .content = try std.fmt.allocPrint(arena, "error writing {s}: {s}", .{ path, @errorName(err) }), .is_error = true };
        };
    }
    var diff = std.array_list.Managed(u8).init(arena);
    const head = if (dry)
        try std.fmt.allocPrint(arena, "dry-run: would write {d} bytes to {s}\n--- {s}\n+++ {s}\n", .{ content.len, path, path, path })
    else
        try std.fmt.allocPrint(arena, "wrote {d} bytes to {s}\n--- {s}\n+++ {s}\n", .{ content.len, path, path, path });
    try diff.appendSlice(head);
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |ln| : (n += 1) {
        if (n >= 40) {
            try diff.appendSlice("... (truncated)\n");
            break;
        }
        try diff.appendSlice("+");
        try diff.appendSlice(ln);
        try diff.appendSlice("\n");
    }
    return .{ .content = try diff.toOwnedSlice() };
}
