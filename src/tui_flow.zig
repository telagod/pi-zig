// tui_flow.zig — workflow rail:FlowSt/FlowNode 与 flow 事件绘制。拆自 tui.zig。
const std = @import("std");
const tui = @import("tui.zig");
const util = @import("core").util;
const emit = @import("tui_emit.zig");
const types = @import("tui_types.zig");

const Tui = tui.Tui;
const ToolMeta = types.ToolMeta;
const flowGoalPreview = emit.flowGoalPreview;
const ANSI_RESET = "\x1b[0m";

pub const FlowSt = enum { wait, run, ok, fail, skip };

pub const FlowNode = struct {
    id: []u8,
    role: []u8,
    last: []u8,
    st: FlowSt,
    idx: usize,
};

pub fn resetFlow(self: *Tui) void {
    for (self.flow_nodes.items) |n| {
        self.alloc.free(n.id);
        self.alloc.free(n.role);
        self.alloc.free(n.last);
    }
    self.flow_nodes.clearRetainingCapacity();
    if (self.flow_goal.len > 0) {
        self.alloc.free(self.flow_goal);
        self.flow_goal = &.{};
    }
    self.flow_active = false;
}

pub fn setFlowGoal(self: *Tui, goal: []const u8) !void {
    if (std.mem.eql(u8, self.flow_goal, goal)) return;
    const d = try self.alloc.dupe(u8, goal);
    if (self.flow_goal.len > 0) self.alloc.free(self.flow_goal);
    self.flow_goal = d;
}

pub fn flowNodeById(self: *Tui, id: []const u8) ?*FlowNode {
    for (self.flow_nodes.items) |*n| {
        if (std.mem.eql(u8, n.id, id)) return n;
    }
    return null;
}

pub fn flowNodeByIdx(self: *Tui, idx: usize) ?*FlowNode {
    for (self.flow_nodes.items) |*n| {
        if (n.idx == idx) return n;
    }
    return null;
}

pub fn addFlowNode(self: *Tui, id: []const u8, role: []const u8, st: FlowSt, idx: usize) !*FlowNode {
    if (flowNodeById(self, id)) |n| {
        n.st = st;
        if (role.len > 0 and n.role.len == 0) {
            const d = try self.alloc.dupe(u8, role);
            self.alloc.free(n.role);
            n.role = d;
        }
        return n;
    }
    try self.flow_nodes.append(self.alloc, .{
        .id = try self.alloc.dupe(u8, id),
        .role = try self.alloc.dupe(u8, role),
        .last = try self.alloc.dupe(u8, ""),
        .st = st,
        .idx = if (idx == 0) self.flow_nodes.items.len + 1 else idx,
    });
    return &self.flow_nodes.items[self.flow_nodes.items.len - 1];
}

pub fn setFlowLast(self: *Tui, n: *FlowNode, text: []const u8) !void {
    if (std.mem.eql(u8, n.last, text)) return;
    const d = try self.alloc.dupe(u8, text);
    self.alloc.free(n.last);
    n.last = d;
}

pub fn loadFlowFromArgs(self: *Tui, args: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, args, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    if (parsed.value.object.get("goal")) |g| {
        if (g == .string and g.string.len > 0) setFlowGoal(self, g.string) catch |err| util.debugCatch("tui.flow.goal", err);
    }
    const ns = parsed.value.object.get("nodes") orelse return;
    if (ns != .array) return;
    for (ns.array.items, 0..) |it, i| {
        if (it != .object) continue;
        const id_v = it.object.get("id") orelse continue;
        if (id_v != .string or id_v.string.len == 0) continue;
        const role = blk: {
            const r = it.object.get("role") orelse break :blk "";
            break :blk if (r == .string) r.string else "";
        };
        _ = addFlowNode(self, id_v.string, role, .wait, i + 1) catch |err| util.debugCatch("tui.flow.node", err);
    }
}

pub fn loadFlowFromOut(self: *Tui, out: []const u8) void {
    if (std.mem.indexOf(u8, out, "Workflow \"")) |at| {
        const start = at + "Workflow \"".len;
        if (std.mem.indexOfScalar(u8, out[start..], '"')) |end| {
            if (end > 0) setFlowGoal(self, out[start .. start + end]) catch |err| util.debugCatch("tui.flow.goal2", err);
        }
    }
    var rest = out;
    while (std.mem.indexOf(u8, rest, "=== ")) |at| {
        rest = rest[at + 4 ..];
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = rest[0..line_end];
        rest = if (line_end < rest.len) rest[line_end + 1 ..] else rest[line_end..];
        const head = if (std.mem.endsWith(u8, line, " ===")) line[0 .. line.len - 4] else line;
        var it = std.mem.tokenizeScalar(u8, head, ' ');
        const id = it.next() orelse continue;
        var role: []const u8 = "";
        var st: FlowSt = .ok;
        while (it.next()) |tok| {
            if (tok.len >= 2 and tok[0] == '(' and tok[tok.len - 1] == ')') {
                role = tok[1 .. tok.len - 1];
            } else if (std.mem.eql(u8, tok, "ok")) {
                st = .ok;
            } else if (std.mem.eql(u8, tok, "FAILED")) {
                st = .fail;
            } else if (std.mem.eql(u8, tok, "skipped")) {
                st = .skip;
            }
        }
        _ = addFlowNode(self, id, role, st, 0) catch |err| util.debugCatch("tui.flow.add", err);
    }
}

pub fn renderFlowRail(self: *Tui) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(self.alloc);
    errdefer aw.deinit();
    for (self.flow_nodes.items, 0..) |n, i| {
        if (i > 0) try aw.writer.writeByte('\n');
        const mark: []const u8 = switch (n.st) {
            .wait => "○",
            .run => "●",
            .ok => "●",
            .fail => "●",
            .skip => "·",
        };
        const ink: []const u8 = switch (n.st) {
            .wait, .skip => tui.theme.muted(),
            .run => tui.theme.fgStatus(.running),
            .ok => tui.theme.fgStatus(.ok),
            .fail => tui.theme.fgStatus(.err),
        };
        try aw.writer.writeAll(ink);
        try aw.writer.writeAll(mark);
        if (ink.len > 0) try aw.writer.writeAll(ANSI_RESET);
        try aw.writer.writeByte(' ');
        try aw.writer.writeAll(n.id);
        if (n.role.len > 0) {
            try aw.writer.writeAll("  ");
            try aw.writer.writeAll(n.role);
        }
        const extra: []const u8 = switch (n.st) {
            .run => if (n.last.len > 0) n.last else "running",
            .fail => if (n.last.len > 0) n.last else "fail",
            .skip => "skip",
            else => "",
        };
        if (extra.len > 0) {
            try aw.writer.writeAll("  ");
            try aw.writer.writeAll(extra);
        }
    }
    return try aw.toOwnedSlice();
}

pub fn paintFlowInto(self: *Tui, tm: *ToolMeta) void {
    var done_n: usize = 0;
    for (self.flow_nodes.items) |n| {
        if (n.st == .ok or n.st == .fail or n.st == .skip) done_n += 1;
    }
    var pbuf: [160]u8 = undefined;
    const preview = if (self.flow_goal.len > 0 and self.flow_nodes.items.len > 0)
        std.fmt.bufPrint(&pbuf, "{s}  {d}/{d}", .{ self.flow_goal, done_n, self.flow_nodes.items.len }) catch self.flow_goal
    else if (self.flow_goal.len > 0) self.flow_goal else tm.preview;
    if (!std.mem.eql(u8, tm.preview, preview)) {
        if (self.alloc.dupe(u8, preview)) |d| {
            self.alloc.free(tm.preview);
            tm.preview = d;
        } else |_| {}
    }
    tm.folded = false;
    const rail = renderFlowRail(self) catch return;
    tm.body.clearRetainingCapacity();
    tm.body.appendSlice(rail) catch |err| util.debugCatch("tui.tool.body", err);
    self.alloc.free(rail);
    if (self.cells.items.len > 0) {
        const last = &self.cells.items[self.cells.items.len - 1];
        if (last.kind == .tool and last.tool != null and last.tool.?.name.ptr == tm.name.ptr) {
            last.text.clearRetainingCapacity();
            last.text.appendSlice(tm.preview) catch |err| util.debugCatch("tui.tool.preview", err);
        }
    }
    self.dirty.store(true, .release);
}

pub fn flowTool(self: *Tui) ?*ToolMeta {
    if (self.firstRunningTool("workflow")) |c| return if (c.tool) |*tm| tm else null;
    var i = self.cells.items.len;
    while (i > 0) {
        i -= 1;
        const c = &self.cells.items[i];
        if (c.kind != .tool) continue;
        if (c.tool) |*tm| {
            if (std.mem.eql(u8, tm.name, "workflow")) return tm;
        }
    }
    return null;
}

pub fn appendWorkflow(self: *Tui, args: []const u8) !void {
    const preview = flowGoalPreview(args);
    try self.appendTool("workflow", preview);
    self.mutex.lock(util.io) catch {};
    defer self.mutex.unlock(util.io);
    resetFlow(self);
    loadFlowFromArgs(self, args);
    self.flow_active = true;
    if (flowTool(self)) |tm| paintFlowInto(self, tm);
}

pub fn applyFlowEvent(self: *Tui, idx: usize, kind: []const u8, text: []const u8) bool {
    self.mutex.lock(util.io) catch return false;
    defer self.mutex.unlock(util.io);
    if (!self.flow_active) return false;
    var n = if (std.mem.eql(u8, kind, "notice") and text.len > 0) flowNodeById(self, text) else null;
    if (n == null) n = flowNodeByIdx(self, idx);
    if (n == null and std.mem.eql(u8, kind, "notice") and text.len > 0) {
        n = addFlowNode(self, text, "", .run, idx) catch null;
    }
    const node = n orelse return false;
    if (std.mem.eql(u8, kind, "notice")) {
        if (node.st == .wait) node.st = .run;
    } else if (std.mem.eql(u8, kind, "tool_start")) {
        node.st = .run;
        setFlowLast(self, node, text) catch |err| util.debugCatch("tui.flow.last", err);
    } else if (std.mem.eql(u8, kind, "tool_done")) {
        setFlowLast(self, node, text) catch |err| util.debugCatch("tui.flow.last2", err);
    } else if (std.mem.eql(u8, kind, "finished")) {
        if (node.st != .fail) node.st = .ok;
    } else if (std.mem.eql(u8, kind, "tool_failed")) {
        node.st = .fail;
    } else return false;
    if (flowTool(self)) |tm| paintFlowInto(self, tm);
    return true;
}
