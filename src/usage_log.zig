// usage_log.zig — 每轮 token 账本。~/.piz/usage.jsonl,一行一轮。
// after_turn 追加; /usage 读尾。不记 API key,只记量。
const std = @import("std");
const util = @import("util.zig");
const agentmod = @import("agent.zig");
const pricing = @import("pricing.zig");

pub fn filePath(alloc: std.mem.Allocator) ![]u8 {
    const dir = try util.configDir(alloc);
    return util.joinPath(alloc, dir, "usage.jsonl");
}

fn esc(alloc: std.mem.Allocator, s: []const u8) []const u8 {
    return util.jsonString(alloc, s) catch "\"\"";
}

/// 有用量才落一行。无 input/output 的空转不记。
pub fn appendTurn(self: *agentmod.Agent) void {
    const u = self.last_usage;
    if (u.input == null and u.output == null) return;
    const path = filePath(self.alloc) catch return;
    const ts = @divTrunc(std.Io.Clock.now(.real, util.io).nanoseconds, std.time.ns_per_s);
    const inp = u.input orelse 0;
    const out = u.output orelse 0;
    const cr = u.cache_read orelse 0;
    const cw = u.cache_write orelse 0;
    const usd = if (pricing.lookupAny(self.provider.name, self.model)) |r|
        pricing.turnCost(r, inp, out, cr, cw)
    else
        0;
    const line = std.fmt.allocPrint(self.alloc, "{{\"ts\":{d},\"model\":{s},\"in\":{d},\"out\":{d},\"cr\":{d},\"cw\":{d},\"usd\":{d:.8},\"cwd\":{s}}}\n", .{
        ts,
        esc(self.alloc, self.model),
        inp,
        out,
        cr,
        cw,
        usd,
        esc(self.alloc, self.cwd),
    }) catch return;
    const dir = std.fs.path.dirname(path) orelse return;
    std.Io.Dir.cwd().createDirPath(util.io, dir) catch |err| util.debugCatch("usage.mkdir", err);
    var f = std.Io.Dir.cwd().createFile(util.io, path, .{ .exclusive = true, .permissions = @enumFromInt(0o600) }) catch |err| switch (err) {
        error.PathAlreadyExists => std.Io.Dir.cwd().openFile(util.io, path, .{ .mode = .write_only }) catch |e| {
            util.debugCatch("usage.open", e);
            return;
        },
        else => {
            util.debugCatch("usage.create", err);
            return;
        },
    };
    defer f.close(util.io);
    var wbuf: [512]u8 = undefined;
    var w = f.writer(util.io, &wbuf);
    w.seekTo(f.length(util.io) catch 0) catch |err| util.debugCatch("usage.seek", err);
    w.interface.writeAll(line) catch |err| util.debugCatch("usage.write", err);
    w.flush() catch |err| util.debugCatch("usage.flush", err);
}

pub const Summary = struct {
    lines: u32 = 0,
    tok_in: u64 = 0,
    tok_out: u64 = 0,
    usd: f64 = 0,
    tail: []u8 = &.{},
};

/// 读全文记账,tail 留最后 max_tail 行原文(不含换行拼成一块)。
pub fn summarize(alloc: std.mem.Allocator, max_tail: usize) !Summary {
    const path = try filePath(alloc);
    const raw = std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    var s = Summary{};
    var it = std.mem.splitScalar(u8, raw, '\n');
    var kept = std.array_list.Managed([]const u8).init(alloc);
    while (it.next()) |line| {
        if (line.len == 0) continue;
        s.lines += 1;
        if (fieldU64(line, "\"in\":")) |n| s.tok_in += n;
        if (fieldU64(line, "\"out\":")) |n| s.tok_out += n;
        if (fieldF64(line, "\"usd\":")) |n| s.usd += n;
        try kept.append(line);
    }
    const start = if (kept.items.len > max_tail) kept.items.len - max_tail else 0;
    var aw = std.Io.Writer.Allocating.init(alloc);
    for (kept.items[start..], 0..) |line, i| {
        if (i > 0) try aw.writer.writeByte('\n');
        try aw.writer.writeAll(line);
    }
    s.tail = try aw.toOwnedSlice();
    return s;
}

fn fieldU64(line: []const u8, key: []const u8) ?u64 {
    const i = std.mem.indexOf(u8, line, key) orelse return null;
    var p = i + key.len;
    while (p < line.len and (line[p] == ' ')) p += 1;
    var e = p;
    while (e < line.len and line[e] >= '0' and line[e] <= '9') e += 1;
    if (e == p) return null;
    return std.fmt.parseInt(u64, line[p..e], 10) catch null;
}

fn fieldF64(line: []const u8, key: []const u8) ?f64 {
    const i = std.mem.indexOf(u8, line, key) orelse return null;
    var p = i + key.len;
    while (p < line.len and line[p] == ' ') p += 1;
    var e = p;
    if (e < line.len and (line[e] == '-' or line[e] == '+')) e += 1;
    while (e < line.len and ((line[e] >= '0' and line[e] <= '9') or line[e] == '.' or line[e] == 'e' or line[e] == 'E' or line[e] == '+' or line[e] == '-')) e += 1;
    if (e == p) return null;
    return std.fmt.parseFloat(f64, line[p..e]) catch null;
}

test "appendTurn writes in/out and summarize tails" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path[0..] });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    var cfg = @import("config.zig").Config{ .arena = &arena };
    var provs = [_]@import("config.zig").Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/proj");
    agent.model = "gpt-4o-mini";
    agent.last_usage = .{ .input = 12, .output = 3, .cache_read = 4, .cache_write = 1 };
    appendTurn(&agent);
    appendTurn(&agent);

    const sum = try summarize(a, 1);
    try t.expectEqual(@as(u32, 2), sum.lines);
    try t.expectEqual(@as(u64, 24), sum.tok_in);
    try t.expectEqual(@as(u64, 6), sum.tok_out);
    const one = pricing.turnCost(pricing.lookupAny("mock", "gpt-4o-mini").?, 12, 3, 4, 1);
    try t.expectApproxEqAbs(one * 2, sum.usd, 1e-12);
    try t.expect(std.mem.indexOf(u8, sum.tail, "\"in\":12") != null);
    try t.expect(std.mem.indexOf(u8, sum.tail, "\"usd\":") != null);
    try t.expect(std.mem.indexOf(u8, sum.tail, "\n") == null);
}
