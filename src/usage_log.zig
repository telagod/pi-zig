// usage_log.zig — 每轮 token 账本读侧。~/.piz/usage.jsonl,一行一轮。
// 写侧已抽为内嵌 JS 扩展(src/embedded/extensions/usage-ledger.js,agent_end 携 usage 落账);
// 本文件只留 filePath/summarize 供 /usage 与 web 读。不记 API key,只记量。
const std = @import("std");
const util = @import("util.zig");

pub fn filePath(alloc: std.mem.Allocator) ![]const u8 {
    const dir = try util.configDir(alloc);
    return util.joinPath(alloc, dir, "usage.jsonl");
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

test "summarize reads ledger lines and tails" {
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
    // 行式与内嵌 usage-ledger.js 产出一致(原 Zig appendTurn 同式)
    const line = "{\"ts\":1,\"model\":\"gpt-4o-mini\",\"in\":12,\"out\":3,\"cr\":4,\"cw\":1,\"usd\":0.00100000,\"cwd\":\"/proj\"}\n";
    const path = try filePath(a);
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = path, .data = line ++ line });

    const sum = try summarize(a, 1);
    try t.expectEqual(@as(u32, 2), sum.lines);
    try t.expectEqual(@as(u64, 24), sum.tok_in);
    try t.expectEqual(@as(u64, 6), sum.tok_out);
    try t.expectApproxEqAbs(@as(f64, 0.002), sum.usd, 1e-12);
    try t.expect(std.mem.indexOf(u8, sum.tail, "\"in\":12") != null);
    try t.expect(std.mem.indexOf(u8, sum.tail, "\"usd\":") != null);
    try t.expect(std.mem.indexOf(u8, sum.tail, "\n") == null);
}
