// workflow:原生 DAG 委派。
//
// 官方 pi 的 example 只有链式 {previous};pi-subagents 要写 JS。
// 这里用命名节点 + needs 做 DAG:就绪的一起跑,后步用 {id} 引用前步输出。
// 某节点失败,依赖它的后继直接 skip,不烧 token。
const std = @import("std");
const agentmod = @import("../agent.zig");
const toolsmod = @import("../tools.zig");
const util = @import("../util.zig");
const jsonx = @import("jsonx.zig");
const childbind = @import("childbind.zig");
const limits = @import("limits.zig");
const taskmod = @import("task.zig");

const MAX_ID = 32;
const SPLICE_CAP = 4000;
const ROLE_TOOLS = [_][]const u8{ "read", "grep", "ls", "find", "web_search", "fetch_url" };

const Role = enum {
    none,
    scout,
    planner,
    reviewer,
    worker,

    fn parse(s: []const u8) ?Role {
        if (std.mem.eql(u8, s, "scout")) return .scout;
        if (std.mem.eql(u8, s, "planner")) return .planner;
        if (std.mem.eql(u8, s, "reviewer")) return .reviewer;
        if (std.mem.eql(u8, s, "worker")) return .worker;
        return null;
    }

    fn label(self: Role) []const u8 {
        return switch (self) {
            .none => "",
            .scout => "scout",
            .planner => "planner",
            .reviewer => "reviewer",
            .worker => "worker",
        };
    }

    fn preamble(self: Role) []const u8 {
        return switch (self) {
            .none => "",
            .scout => "[role: scout] Survey and compress. Do not implement or edit files.\n\n",
            .planner => "[role: planner] Produce a concrete plan. Do not implement.\n\n",
            .reviewer => "[role: reviewer] Review against the cited outputs. Report issues. Do not implement.\n\n",
            .worker => "[role: worker] Implement the cited plan. Stay inside the given scope.\n\n",
        };
    }

    fn preferredTools(self: Role) []const []const u8 {
        return switch (self) {
            .scout, .planner, .reviewer => &ROLE_TOOLS,
            .none, .worker => &.{},
        };
    }
};

const NodeStatus = enum { pending, ready, running, ok, failed, skipped };

const Node = struct {
    id: []const u8,
    task: []const u8,
    role: Role = .none,
    needs: []const []const u8 = &.{},
    read_only: bool = false,
    plugins: ?[]const []const u8 = null,
    tools: ?[]const []const u8 = null,
    status: NodeStatus = .pending,
    output: []const u8 = "",
    err: []const u8 = "",
    elapsed_ms: i64 = 0,
};

fn validId(s: []const u8) bool {
    if (s.len == 0 or s.len > MAX_ID) return false;
    if (!std.ascii.isAlphabetic(s[0])) return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
}

fn findNode(nodes: []const Node, id: []const u8) ?usize {
    for (nodes, 0..) |n, i| {
        if (std.mem.eql(u8, n.id, id)) return i;
    }
    return null;
}

/// Kahn:有环返回 false。
fn acyclic(nodes: []const Node) bool {
    var indeg_buf: [limits.MAX_PARALLEL_TASKS]usize = undefined;
    if (nodes.len > indeg_buf.len) return false;
    const indeg = indeg_buf[0..nodes.len];
    @memset(indeg, 0);
    for (nodes, 0..) |n, i| {
        indeg[i] = n.needs.len;
    }
    var q: [limits.MAX_PARALLEL_TASKS]usize = undefined;
    var qn: usize = 0;
    for (indeg, 0..) |d, i| {
        if (d == 0) {
            q[qn] = i;
            qn += 1;
        }
    }
    var seen: usize = 0;
    var qi: usize = 0;
    while (qi < qn) : (qi += 1) {
        const i = q[qi];
        seen += 1;
        for (nodes, 0..) |n, j| {
            for (n.needs) |need| {
                if (!std.mem.eql(u8, need, nodes[i].id)) continue;
                if (indeg[j] == 0) continue;
                indeg[j] -= 1;
                if (indeg[j] == 0) {
                    q[qn] = j;
                    qn += 1;
                }
            }
        }
    }
    return seen == nodes.len;
}

fn heldTools(arena: std.mem.Allocator, parent_plugins: u16, names: []const []const u8) []const []const u8 {
    var out = std.array_list.Managed([]const u8).init(arena);
    for (names) |n| {
        _ = childbind.resolveTools(arena, parent_plugins, &.{n}) catch continue;
        out.append(n) catch continue;
    }
    return out.toOwnedSlice() catch &.{};
}

fn substitute(arena: std.mem.Allocator, tmpl: []const u8, nodes: []const Node) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    var i: usize = 0;
    while (i < tmpl.len) {
        if (tmpl[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, tmpl, i + 1, '}')) |end| {
                const key = tmpl[i + 1 .. end];
                if (validId(key)) {
                    if (findNode(nodes, key)) |ni| {
                        const n = nodes[ni];
                        const piece: []const u8 = switch (n.status) {
                            .ok => if (n.output.len == 0) "(empty)" else util.clampUtf8(n.output, SPLICE_CAP),
                            .failed => if (n.err.len > 0) n.err else "(failed)",
                            .skipped => "(skipped)",
                            else => "(pending)",
                        };
                        try aw.writer.writeAll(piece);
                        i = end + 1;
                        continue;
                    }
                }
            }
        }
        try aw.writer.writeByte(tmpl[i]);
        i += 1;
    }
    return arena.dupe(u8, aw.written());
}

fn parseNodes(arena: std.mem.Allocator, v: std.json.Value) !union(enum) {
    ok: []Node,
    fail: []const u8,
} {
    const arr = if (v == .object) v.object.get("nodes") else null;
    if (arr == null or arr.? != .array) return .{ .fail = "error: missing 'nodes' array" };
    const items = arr.?.array.items;
    if (items.len == 0) return .{ .fail = "error: nodes must not be empty" };
    if (items.len > limits.MAX_PARALLEL_TASKS)
        return .{ .fail = try std.fmt.allocPrint(arena, "error: at most {d} workflow nodes", .{limits.MAX_PARALLEL_TASKS}) };

    var nodes = try arena.alloc(Node, items.len);
    for (items, nodes) |it, *n| {
        if (it != .object) return .{ .fail = "error: each node must be an object" };
        const id = jsonx.jsonStr(it, "id") orelse return .{ .fail = "error: node missing id" };
        if (!validId(id)) return .{ .fail = "error: node id must start with a letter and use only A-Za-z0-9_-" };
        const task = jsonx.jsonStr(it, "task") orelse return .{ .fail = "error: node missing task" };
        var role: Role = .none;
        if (jsonx.jsonStr(it, "role")) |rs| {
            role = Role.parse(rs) orelse return .{ .fail = "error: role must be scout | planner | reviewer | worker" };
        }
        var needs: []const []const u8 = &.{};
        if (it.object.get("needs")) |nv| {
            if (nv != .array) return .{ .fail = "error: needs must be an array of node ids" };
            if (nv.array.items.len > 0) {
                const buf = try arena.alloc([]const u8, nv.array.items.len);
                for (nv.array.items, buf) |e, *d| {
                    if (e != .string or e.string.len == 0) return .{ .fail = "error: needs entries must be non-empty strings" };
                    d.* = e.string;
                }
                needs = buf;
            }
        }
        const plugins = jsonx.jsonStrs(arena, it, "plugins") catch {
            return .{ .fail = "error: plugins must be a non-empty string array" };
        };
        const tools = jsonx.jsonStrs(arena, it, "tools") catch {
            return .{ .fail = "error: tools must be a non-empty string array" };
        };
        n.* = .{
            .id = id,
            .task = task,
            .role = role,
            .needs = needs,
            .read_only = jsonx.jsonBool(it, "read_only") orelse false,
            .plugins = plugins,
            .tools = tools,
        };
    }

    for (nodes, 0..) |n, i| {
        for (nodes[0..i]) |prev| {
            if (std.mem.eql(u8, prev.id, n.id))
                return .{ .fail = try std.fmt.allocPrint(arena, "error: duplicate node id '{s}'", .{n.id}) };
        }
        for (n.needs) |need| {
            if (std.mem.eql(u8, need, n.id))
                return .{ .fail = try std.fmt.allocPrint(arena, "error: node '{s}' cannot need itself", .{n.id}) };
            if (findNode(nodes, need) == null)
                return .{ .fail = try std.fmt.allocPrint(arena, "error: node '{s}' needs unknown '{s}'", .{ n.id, need }) };
        }
    }
    if (!acyclic(nodes)) return .{ .fail = "error: workflow has a cycle" };
    return .{ .ok = nodes };
}

fn formatWorkflow(arena: std.mem.Allocator, goal: []const u8, nodes: []const Node) !toolsmod.Result {
    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    var ok_n: usize = 0;
    var fail_n: usize = 0;
    var skip_n: usize = 0;
    var ms: i64 = 0;
    for (nodes) |n| {
        ms += n.elapsed_ms;
        switch (n.status) {
            .ok => ok_n += 1,
            .failed => fail_n += 1,
            .skipped => skip_n += 1,
            else => {},
        }
    }
    if (goal.len > 0) {
        try aw.writer.print("Workflow \"{s}\" — {d}/{d} ok", .{ goal, ok_n, nodes.len });
    } else {
        try aw.writer.print("Workflow — {d}/{d} ok", .{ ok_n, nodes.len });
    }
    if (fail_n > 0) try aw.writer.print(", {d} failed", .{fail_n});
    if (skip_n > 0) try aw.writer.print(", {d} skipped", .{skip_n});
    try aw.writer.print(" [{d}s]\n", .{@divTrunc(ms, 1000)});

    for (nodes) |n| {
        const role = n.role.label();
        const st = switch (n.status) {
            .ok => "ok",
            .failed => "FAILED",
            .skipped => "skipped",
            else => @tagName(n.status),
        };
        try aw.writer.writeAll("\n=== ");
        try aw.writer.writeAll(n.id);
        if (role.len > 0) try aw.writer.print(" ({s})", .{role});
        try aw.writer.print(" {s}", .{st});
        if (n.elapsed_ms > 0) try aw.writer.print(" [{d}s]", .{@divTrunc(n.elapsed_ms, 1000)});
        if (n.needs.len > 0) {
            try aw.writer.writeAll("  needs:");
            for (n.needs) |need| try aw.writer.print(" {s}", .{need});
        }
        try aw.writer.writeAll(" ===\n");
        if (n.status == .skipped) {
            try aw.writer.writeAll("blocked\n");
        } else if (n.status == .failed) {
            if (n.err.len > 0) try aw.writer.writeAll(n.err);
            if (n.output.len > 0) {
                if (n.err.len > 0) try aw.writer.writeByte('\n');
                try aw.writer.writeAll(n.output);
            }
            if (n.err.len == 0 and n.output.len == 0) try aw.writer.writeAll("(failed)\n");
        } else if (n.output.len > 0) {
            try aw.writer.writeAll(n.output);
            if (n.output[n.output.len - 1] != '\n') try aw.writer.writeByte('\n');
        }
    }
    return .{ .content = try arena.dupe(u8, aw.written()), .is_error = fail_n > 0 };
}

pub fn toolWorkflow(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    const depth = self.depth;
    if (depth >= limits.MAX_TASK_DEPTH) {
        return .{
            .content = try std.fmt.allocPrint(
                arena,
                "error: delegation depth limit reached ({d}/{d}); do the work yourself",
                .{ depth, limits.MAX_TASK_DEPTH },
            ),
            .is_error = true,
        };
    }
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{}) catch
        return .{ .content = "error: invalid JSON arguments", .is_error = true };
    const parsed = try parseNodes(arena, v);
    const nodes = switch (parsed) {
        .fail => |msg| return .{ .content = msg, .is_error = true },
        .ok => |ns| ns,
    };
    const limit = limits.parallelLimitAt(depth);
    if (nodes.len > limit) {
        return .{
            .content = try std.fmt.allocPrint(arena, "error: at most {d} workflow nodes at this depth", .{limit}),
            .is_error = true,
        };
    }
    const goal = jsonx.jsonStr(v, "goal") orelse "";
    const fail_fast = jsonx.jsonBool(v, "fail_fast") orelse false;

    var remaining: usize = nodes.len;
    var wave_failed = false;
    while (remaining > 0) {
        var ready_idx = try arena.alloc(usize, remaining);
        var rn: usize = 0;
        for (nodes, 0..) |n, i| {
            if (n.status != .pending) continue;
            var blocked = false;
            var dead = false;
            for (n.needs) |need| {
                const j = findNode(nodes, need).?;
                switch (nodes[j].status) {
                    .ok => {},
                    .failed, .skipped => dead = true,
                    else => blocked = true,
                }
            }
            if (dead) {
                nodes[i].status = .skipped;
                remaining -= 1;
            } else if (!blocked) {
                ready_idx[rn] = i;
                rn += 1;
            }
        }
        if (rn == 0) {
            for (nodes) |*n| {
                if (n.status == .pending) {
                    n.status = .skipped;
                    remaining -= 1;
                }
            }
            break;
        }
        if (fail_fast and wave_failed) {
            for (ready_idx[0..rn]) |i| {
                nodes[i].status = .skipped;
                remaining -= 1;
            }
            continue;
        }

        const specs = try arena.alloc(taskmod.Spec, rn);
        for (ready_idx[0..rn], specs) |i, *spec| {
            nodes[i].status = .running;
            const spliced = try substitute(arena, nodes[i].task, nodes);
            const body = try std.fmt.allocPrint(arena, "{s}{s}", .{ nodes[i].role.preamble(), spliced });
            var tools = nodes[i].tools;
            if (tools == null) {
                const pref = nodes[i].role.preferredTools();
                if (pref.len > 0) {
                    const held = heldTools(arena, self.plugins, pref);
                    if (held.len > 0) tools = held;
                }
            }
            spec.* = .{
                .desc = body,
                .read_only = nodes[i].read_only,
                .plugins = nodes[i].plugins,
                .tools = tools,
                // i 即 ready_idx 的元素(DAG 下标):曾误写 ready_idx[i] 二次寻址,
                // 沃内下标>节点数时读出垃圾(实测 118),名/idx/事件全错位。
                .idx = i + 1,
                .name = nodes[i].id,
                // 摘要用节点原始任务;desc 带 role 模板(大段英语说明曾占满摘要行)
                .brief = nodes[i].task,
            };
        }

        if (self.cbs.on_subagent) |cb| {
            for (ready_idx[0..rn]) |i| {
                cb(self.cbs.ctx, i + 1, .notice, nodes[i].id) catch {};
            }
        }

        const ran = try taskmod.runSpecs(self, arena, specs);
        switch (ran) {
            .fail => |msg| return .{ .content = msg, .is_error = true },
            .done => |outs| {
                for (ready_idx[0..rn], outs) |ni, o| {
                    nodes[ni].output = o.output;
                    nodes[ni].err = o.err;
                    nodes[ni].elapsed_ms = o.elapsed_ms;
                    nodes[ni].status = if (o.failed) .failed else .ok;
                    if (o.failed) wave_failed = true;
                    remaining -= 1;
                    if (self.cbs.on_subagent) |cb| {
                        cb(self.cbs.ctx, ni + 1, .finished, nodes[ni].id) catch {};
                    }
                }
            },
        }
    }
    return formatWorkflow(arena, goal, nodes);
}

test "validId and cycle detection" {
    const t = std.testing;
    try t.expect(validId("recon"));
    try t.expect(validId("A1_b-2"));
    try t.expect(!validId(""));
    try t.expect(!validId("1abc"));
    try t.expect(!validId("has space"));
    try t.expect(!validId("bad.id"));

    var cycle = [_]Node{
        .{ .id = "a", .task = "x", .needs = &.{"b"} },
        .{ .id = "b", .task = "y", .needs = &.{"a"} },
    };
    try t.expect(!acyclic(&cycle));
    var line = [_]Node{
        .{ .id = "a", .task = "x" },
        .{ .id = "b", .task = "y", .needs = &.{"a"} },
        .{ .id = "c", .task = "z", .needs = &.{"b"} },
    };
    try t.expect(acyclic(&line));
    var dag = [_]Node{
        .{ .id = "a", .task = "x" },
        .{ .id = "b", .task = "y" },
        .{ .id = "c", .task = "z", .needs = &.{ "a", "b" } },
    };
    try t.expect(acyclic(&dag));
}

test "parseNodes rejects dup cycle and unknown need" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dup = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"nodes":[{"id":"a","task":"1"},{"id":"a","task":"2"}]}
    , .{});
    switch (try parseNodes(a, dup)) {
        .fail => |m| try t.expect(std.mem.indexOf(u8, m, "duplicate") != null),
        .ok => return error.TestUnexpectedResult,
    }

    const cyc = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"nodes":[{"id":"a","task":"1","needs":["b"]},{"id":"b","task":"2","needs":["a"]}]}
    , .{});
    switch (try parseNodes(a, cyc)) {
        .fail => |m| try t.expect(std.mem.indexOf(u8, m, "cycle") != null),
        .ok => return error.TestUnexpectedResult,
    }

    const miss = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"nodes":[{"id":"a","task":"1","needs":["ghost"]}]}
    , .{});
    switch (try parseNodes(a, miss)) {
        .fail => |m| try t.expect(std.mem.indexOf(u8, m, "unknown") != null),
        .ok => return error.TestUnexpectedResult,
    }

    const ok = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"nodes":[{"id":"recon","role":"scout","task":"look"},{"id":"plan","role":"planner","task":"use {recon}","needs":["recon"]}]}
    , .{});
    switch (try parseNodes(a, ok)) {
        .ok => |ns| {
            try t.expectEqual(@as(usize, 2), ns.len);
            try t.expect(ns[1].role == .planner);
        },
        .fail => return error.TestUnexpectedResult,
    }
}

test "substitute splices named outputs and leaves unknown braces" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nodes = [_]Node{
        .{ .id = "recon", .task = "x", .status = .ok, .output = "found auth.rs" },
        .{ .id = "plan", .task = "y", .status = .failed, .err = "boom" },
    };
    const got = try substitute(a, "based on {recon} then {plan} keep {not_a_node} and {", &nodes);
    try t.expectEqualStrings("based on found auth.rs then boom keep {not_a_node} and {", got);
}

test "toolWorkflow validates without calling a model" {
    const t = std.testing;
    try agentmod.util.testInit();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = agentmod.cfgmod.Config{ .arena = &arena };
    var provs = [_]agentmod.cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");

    const bad = try toolWorkflow(@ptrCast(&agent), a, "{}");
    try t.expect(bad.is_error);
    try t.expect(std.mem.indexOf(u8, bad.content, "nodes") != null);

    const cyc = try toolWorkflow(@ptrCast(&agent), a,
        \\{"nodes":[{"id":"a","task":"1","needs":["b"]},{"id":"b","task":"2","needs":["a"]}]}
    );
    try t.expect(cyc.is_error);
    try t.expect(std.mem.indexOf(u8, cyc.content, "cycle") != null);
}
