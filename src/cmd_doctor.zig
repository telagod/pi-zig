// cmd_doctor.zig — /doctor 与 `piz doctor`：环境体检，不调模型。
const std = @import("std");
const util = @import("core").util;
const sandbox = @import("core").sandbox;

pub const Info = struct {
    version: []const u8,
    cwd: []const u8,
    provider: []const u8 = "",
    model: []const u8 = "",
    has_key: bool = false,
    think: []const u8 = "",
    approval: []const u8 = "",
    sandbox_mode: []const u8 = "",
    plugins: []const u8 = "",
};

fn existsJoin(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) bool {
    const p = util.joinPath(alloc, dir, name) catch return false;
    return util.fileExists(p);
}

pub fn format(alloc: std.mem.Allocator, info: Info) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("piz doctor v{s}\n", .{info.version});
    try w.print("cwd          {s}\n", .{info.cwd});
    if (util.configDir(alloc)) |cfg| {
        try w.print("config       {s}\n", .{cfg});
        try w.print("  settings   {s}\n", .{if (existsJoin(alloc, cfg, "settings.json")) "ok" else "missing"});
        try w.print("  models     {s}\n", .{if (existsJoin(alloc, cfg, "models.json")) "ok" else "missing"});
        try w.print("  auth       {s}\n", .{if (existsJoin(alloc, cfg, "auth.json")) "ok" else "missing"});
    } else |_| {
        try w.writeAll("config       (unavailable)\n");
    }
    if (info.provider.len > 0) {
        try w.print("provider     {s}\n", .{info.provider});
        try w.print("model        {s}\n", .{info.model});
        try w.print("api key      {s}\n", .{if (info.has_key) "set" else "missing"});
    }
    if (info.think.len > 0) try w.print("think        {s}\n", .{info.think});
    if (info.approval.len > 0) try w.print("approval     {s}\n", .{info.approval});
    const sb = if (info.sandbox_mode.len > 0) info.sandbox_mode else "off";
    try w.print("sandbox      {s} (backend {s})\n", .{ sb, sandbox.backend().label() });
    const web = util.getEnv("PIZ_WEB_SEARCH_URL") orelse "";
    try w.print("web search   {s}\n", .{if (web.len > 0) "PIZ_WEB_SEARCH_URL set" else "unset"});
    try w.print("git          {s}\n", .{if (existsJoin(alloc, info.cwd, ".git")) "repo" else "no"});
    try w.print("AGENTS.md    {s}\n", .{if (existsJoin(alloc, info.cwd, "AGENTS.md")) "present" else "absent"});
    if (info.plugins.len > 0) try w.print("plugins      {s}\n", .{info.plugins});
    return aw.toOwnedSlice();
}

test "format lists cwd and sandbox backend" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try format(a, .{ .version = "0.1.0", .cwd = "/tmp" });
    try t.expect(std.mem.indexOf(u8, out, "piz doctor v0.1.0") != null);
    try t.expect(std.mem.indexOf(u8, out, "cwd          /tmp") != null);
    try t.expect(std.mem.indexOf(u8, out, "sandbox") != null);
    try t.expect(std.mem.indexOf(u8, out, "web search") != null);
}
