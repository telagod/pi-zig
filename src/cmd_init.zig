// cmd_init.zig — /init 与 `piz init`：在工作区写 AGENTS.md 脚手架。
const std = @import("std");
const util = @import("core").util;

pub const TEMPLATE =
    \\# AGENTS.md
    \\
    \\Instructions for coding agents in this repository.
    \\
    \\## Commands
    \\
    \\- Build:
    \\- Test:
    \\- Format:
    \\
    \\## Conventions
    \\
    \\- Match existing style. Prefer small, reversible edits.
    \\- Do not commit, push, or rewrite history unless asked.
    \\- Use project tools for source edits; keep analysis scripts read-only.
    \\
    \\## Don't
    \\
    \\- Drive-by refactors
    \\- Secrets in the tree
    \\
;

pub fn agentsPath(alloc: std.mem.Allocator, cwd: []const u8) ![]u8 {
    if (cwd.len == 0 or std.mem.eql(u8, cwd, ".")) return alloc.dupe(u8, "AGENTS.md");
    return util.joinPath(alloc, cwd, "AGENTS.md");
}

pub fn writeAgents(alloc: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const path = try agentsPath(alloc, cwd);
    if (util.fileExists(path)) {
        return std.fmt.allocPrint(alloc, "AGENTS.md already exists at {s} (not overwritten)", .{path});
    }
    if (std.fs.path.dirname(path)) |d| {
        if (d.len > 0 and !std.mem.eql(u8, d, ".")) {
            std.Io.Dir.cwd().createDirPath(util.io, d) catch {};
        }
    }
    std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = path, .data = TEMPLATE }) catch |err| {
        return std.fmt.allocPrint(alloc, "error writing {s}: {s}", .{ path, @errorName(err) });
    };
    return std.fmt.allocPrint(alloc, "wrote {s}", .{path});
}

test "writeAgents refuses to overwrite" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    const first = try writeAgents(a, root);
    try t.expect(std.mem.startsWith(u8, first, "wrote "));
    const again = try writeAgents(a, root);
    try t.expect(std.mem.indexOf(u8, again, "already exists") != null);
    const body = try std.Io.Dir.cwd().readFileAlloc(util.io, try agentsPath(a, root), a, .limited(4096));
    try t.expect(std.mem.indexOf(u8, body, "# AGENTS.md") != null);
}
