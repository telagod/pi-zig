// compress.zig — 快压新制:入境定形 + 折页。无 LLM。学制 pi-moke fast-compress.ts。
//
// 入境(shapeIngress):大 tool_result 进门即定稿(密图+摘录 / 仅摘录),此后不改。
// 折页(compactHistory):/compact 与 85% 硬线把旧段收成短卡,不调模型。
// 已送前缀永不动 —— 改已送消息会把 Anthropic prompt cache 从改动点起整段作废,
// 这正是旧四层(prune/shake/snap 回溯改旧消息)被废的原因。
const std = @import("std");
const ai = @import("ai.zig");
const imgx = @import("imgx.zig");
const snapfont = @import("snapfont.zig");
const util = @import("util.zig");
const cfgmod = @import("config.zig");

const est = util.estTokensUtf8;

pub const MIN_SNAP_TOKENS: usize = 3000;
const SNAP_SAVINGS_NUM: usize = 85;
const SNAP_SAVINGS_DEN: usize = 100;
const SNAP_HEAD_LINES: u32 = 16;
const SNAP_TAIL_LINES: u32 = 8;

pub const Input = struct {
    alloc: std.mem.Allocator,
    messages: *std.array_list.Managed(ai.Message),
    window: usize,
    api: cfgmod.Api,
    /// false = 文本模型,入境定形与折页都不打图(避 400,也避无故改前缀炸 cache)。
    vision: bool = true,
};

pub fn isPlaceholder(s: []const u8) bool {
    const prefixes = [_][]const u8{
        "[Output truncated",
        "[Superseded",
        "[Artifact stored",
        "[Shake elided",
        "[Snapcompact",
        "[Uneventful",
        "[image omitted",
    };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, s, p)) return true;
    }
    return false;
}

// ============================================================
// 入境定形:tool_result 进门即裁,此后不改(保前缀稳定 → 命中 prompt cache)。
// ============================================================

/// 任务节点:脚注只在这些节点盖,不条条都盖。
pub const TaskNode = enum { user, turn, ingress, hard };

/// turn/user 节点到此水位起,脚注带 /compact 提示。
pub const PROACTIVE_PERCENT: usize = 40;

pub fn compactHint(node: ?TaskNode, percent: usize) bool {
    const n = node orelse return false;
    if (n == .hard) return true;
    return (n == .turn or n == .user) and percent >= PROACTIVE_PERCENT;
}

/// 窗况脚注,如 `[ctx 57% 150382/262144 node=turn → /compact]`。非节点返空串。
pub fn usageFooter(alloc: std.mem.Allocator, percent: usize, tokens: usize, window: usize, node: ?TaskNode) ![]const u8 {
    const n = node orelse return "";
    const hint = if (compactHint(n, percent)) " → /compact" else "";
    return std.fmt.allocPrint(alloc, "\n\n[ctx {d}% {d}/{d} node={s}{s}]", .{ percent, tokens, window, @tagName(n), hint });
}

pub const IngressOpts = struct {
    vision: bool = true,
    api: cfgmod.Api,
    tool_name: []const u8 = "",
    window: usize = 0,
};

pub const Ingress = struct {
    changed: bool = false,
    text: []const u8,
    image: ?[]const u8 = null, // base64 PNG
    width: u32 = 0,
    height: u32 = 0,
    tokens_saved: usize = 0,
};

fn skipIngressTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "skill") or std.mem.eql(u8, name, "context");
}

const SNAP_EXCERPT_MAX: usize = 2400;

/// 首 16 行 + 省略标 + 尾 8 行,UTF-8 安全截到 2400B。
pub fn snapExcerpt(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    const total = countLines(text);
    if (total <= SNAP_HEAD_LINES + SNAP_TAIL_LINES)
        return alloc.dupe(u8, util.clampUtf8(text, SNAP_EXCERPT_MAX));
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    try out.appendSlice(lineRange(text, 0, SNAP_HEAD_LINES));
    try out.append('\n');
    try out.appendSlice(try std.fmt.allocPrint(alloc, "… ({d} lines elided; see image) …\n", .{total - SNAP_HEAD_LINES - SNAP_TAIL_LINES}));
    try out.appendSlice(lineRange(text, total - SNAP_TAIL_LINES, SNAP_TAIL_LINES));
    return alloc.dupe(u8, util.clampUtf8(out.items, SNAP_EXCERPT_MAX));
}

/// 大工具结果进门定形:≥3000 tok 才动;vision 打密图+摘录,无 vision 仅摘录。
/// 图比原文贵(省不到 15%)退摘录;摘录也不省则原样放行。
pub fn shapeIngress(alloc: std.mem.Allocator, text: []const u8, opts: IngressOpts) !Ingress {
    const keep: Ingress = .{ .text = text };
    if (text.len == 0 or isPlaceholder(text) or skipIngressTool(opts.tool_name)) return keep;
    const tok = est(text);
    if (tok < MIN_SNAP_TOKENS) return keep;

    const excerpt = try snapExcerpt(alloc, text);
    const excerpt_notice = try std.fmt.allocPrint(alloc, "[Snapcompact: {d} tokens → excerpt]\n{s}", .{ tok, excerpt });
    const excerpt_saved = tok -| est(excerpt_notice);
    const excerpt_only: Ingress = .{ .changed = excerpt_saved > 0, .text = excerpt_notice, .tokens_saved = excerpt_saved };

    if (!opts.vision) return if (excerpt_only.changed) excerpt_only else keep;

    const shape = snapfont.resolveShape(opts.api);
    const max_rows: u32 = if (shape.cell_h == 0) 64 else shape.frame_h / shape.cell_h;
    const frame = (snapfont.raster(alloc, text, shape, max_rows) catch null) orelse
        return if (excerpt_only.changed) excerpt_only else keep;
    defer alloc.free(frame.rgba);
    const win: u32 = @intCast(@max(opts.window, 1));
    const img_tok = imgx.estImageTokens(frame.w, frame.h, opts.api, win);
    if (img_tok == 0) return if (excerpt_only.changed) excerpt_only else keep;

    const notice = try std.fmt.allocPrint(alloc, "[Snapcompact: {d} tokens → {d}x{d} PNG ~{d} tokens]\n{s}", .{ tok, frame.w, frame.h, img_tok, excerpt });
    const after = est(notice) + img_tok;
    if (after * 100 > tok * SNAP_SAVINGS_NUM) return if (excerpt_only.changed) excerpt_only else keep;

    const enc = imgx.encodeRgbaPngB64(alloc, frame.rgba, frame.w, frame.h) catch
        return if (excerpt_only.changed) excerpt_only else keep;
    return .{
        .changed = true,
        .text = notice,
        .image = enc.data,
        .width = frame.w,
        .height = frame.h,
        .tokens_saved = tok -| after,
    };
}

pub fn totalTokens(in: Input) usize {
    var n: usize = 0;
    for (in.messages.items) |m| {
        n += est(m.content) + 16;
        if (m.image != null) n += imgx.estImageTokens(m.image_w, m.image_h, in.api, @intCast(in.window));
    }
    return n;
}

/// tool 消息上的密图在协议里发不出去,组装请求时拆成 tool 文本 + user 图。
pub fn appendForRequest(out: *std.array_list.Managed(ai.Message), m: ai.Message) !void {
    if (m.image != null and std.mem.eql(u8, m.role, "tool")) {
        var text = m;
        text.image = null;
        text.image_mime = null;
        text.image_w = 0;
        text.image_h = 0;
        try out.append(text);
        try out.append(.{
            .role = "user",
            .content = m.content,
            .image = m.image,
            .image_mime = m.image_mime,
            .image_w = m.image_w,
            .image_h = m.image_h,
        });
        return;
    }
    try out.append(m);
}

/// /compact 与 85% 硬线的折页结果:短卡 + 可选密图(打卡,不打原文)。
pub const Fold = struct {
    summary: []const u8,
    image: ?[]const u8 = null,
    width: u32 = 0,
    height: u32 = 0,
};

const FOLD_FILE_MAX: usize = 24;
const FOLD_INTENT_MAX: usize = 3;
const FOLD_INTENT_CHARS: usize = 200;
const FOLD_HEAD_LINES: usize = 16;
const FOLD_TAIL_LINES: usize = 8;
const FOLD_MSG_CLAMP: usize = 400;

fn isOldFold(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "(Conversation compacted") or
        std.mem.startsWith(u8, s, "[Snapcompact]") or
        std.mem.eql(u8, s, "[Snapcompact frame]");
}

fn jsonPath(s: []const u8) ?[]const u8 {
    const key = "\"path\"";
    const i = std.mem.indexOf(u8, s, key) orelse return null;
    var j = i + key.len;
    while (j < s.len and (s[j] == ' ' or s[j] == '\t' or s[j] == ':' or s[j] == '\n' or s[j] == '\r')) j += 1;
    if (j >= s.len or s[j] != '"') return null;
    j += 1;
    const start = j;
    while (j < s.len and s[j] != '"') j += 1;
    if (j > start) return s[start..j];
    return null;
}

fn pushUnique(list: *std.array_list.Managed([]const u8), p: []const u8) !void {
    if (p.len == 0 or p.len > 512) return;
    for (list.items) |x| {
        if (std.mem.eql(u8, x, p)) return;
    }
    if (list.items.len >= FOLD_FILE_MAX) return;
    try list.append(p);
}

fn collectFiles(alloc: std.mem.Allocator, discarded: []const ai.Message) ![][]const u8 {
    var files = std.array_list.Managed([]const u8).init(alloc);
    for (discarded) |m| {
        if (isOldFold(m.content)) continue;
        if (jsonPath(m.content)) |p| try pushUnique(&files, p);
        if (m.tool_calls) |tcs| {
            for (tcs) |tc| {
                if (jsonPath(tc.args)) |p| try pushUnique(&files, p);
            }
        }
    }
    return files.toOwnedSlice();
}

fn collectIntents(alloc: std.mem.Allocator, discarded: []const ai.Message) ![][]const u8 {
    var found: [FOLD_INTENT_MAX][]const u8 = undefined;
    var n: usize = 0;
    var i = discarded.len;
    while (i > 0 and n < FOLD_INTENT_MAX) {
        i -= 1;
        const m = discarded[i];
        if (!std.mem.eql(u8, m.role, "user")) continue;
        if (isOldFold(m.content)) continue;
        found[n] = util.clampUtf8(std.mem.trim(u8, m.content, " \t\r\n"), FOLD_INTENT_CHARS);
        n += 1;
    }
    const out = try alloc.alloc([]const u8, n);
    var k: usize = 0;
    while (k < n) : (k += 1) out[k] = found[n - 1 - k];
    return out;
}

fn collectExcerpt(alloc: std.mem.Allocator, discarded: []const ai.Message) ![]u8 {
    var lines = std.array_list.Managed([]const u8).init(alloc);
    defer lines.deinit();
    for (discarded) |m| {
        if (isOldFold(m.content)) continue;
        const body = util.clampUtf8(m.content, FOLD_MSG_CLAMP);
        try lines.append(try std.fmt.allocPrint(alloc, "[{s}] {s}", .{ m.role, body }));
    }
    var out = std.array_list.Managed(u8).init(alloc);
    if (lines.items.len == 0) return out.toOwnedSlice();
    if (lines.items.len <= FOLD_HEAD_LINES + FOLD_TAIL_LINES) {
        for (lines.items) |ln| {
            try out.appendSlice(ln);
            try out.append('\n');
        }
    } else {
        for (lines.items[0..FOLD_HEAD_LINES]) |ln| {
            try out.appendSlice(ln);
            try out.append('\n');
        }
        try out.appendSlice("...\n");
        const tail_start = lines.items.len - FOLD_TAIL_LINES;
        for (lines.items[tail_start..]) |ln| {
            try out.appendSlice(ln);
            try out.append('\n');
        }
    }
    return out.toOwnedSlice();
}

/// 把 [0..cut) 折成短卡。旧摘要占位丢弃。有 vision 且图比原文省才贴 PNG。
pub fn compactHistory(
    alloc: std.mem.Allocator,
    discarded: []const ai.Message,
    api: cfgmod.Api,
    vision: bool,
) !Fold {
    var discarded_tok: usize = 0;
    for (discarded) |m| discarded_tok += est(m.content);

    const files = try collectFiles(alloc, discarded);
    const intents = try collectIntents(alloc, discarded);
    const excerpt = try collectExcerpt(alloc, discarded);

    var card = std.array_list.Managed(u8).init(alloc);
    try card.appendSlice(try std.fmt.allocPrint(alloc, "[Snapcompact] Fold ~{d} tok.\n", .{discarded_tok}));
    if (files.len > 0) {
        try card.appendSlice("FILES\n");
        for (files) |p| {
            try card.appendSlice(try std.fmt.allocPrint(alloc, "- {s}\n", .{p}));
        }
    }
    if (intents.len > 0) {
        try card.appendSlice("INTENTS\n");
        for (intents) |s| {
            try card.appendSlice(try std.fmt.allocPrint(alloc, "- {s}\n", .{s}));
        }
    }
    if (excerpt.len > 0) {
        try card.appendSlice("EXCERPT\n");
        try card.appendSlice(excerpt);
    }
    const summary = try card.toOwnedSlice();

    var image: ?[]const u8 = null;
    var iw: u32 = 0;
    var ih: u32 = 0;
    if (vision and summary.len > 0) {
        const shape = snapfont.resolveShape(api);
        const hard: u32 = if (shape.cell_h == 0) 64 else shape.frame_h / shape.cell_h;
        if (snapfont.raster(alloc, summary, shape, hard) catch null) |frame| {
            defer alloc.free(frame.rgba);
            const img_tok = imgx.estImageTokens(frame.w, frame.h, api, 128_000);
            if (img_tok > 0 and img_tok * 100 < discarded_tok * SNAP_SAVINGS_NUM) {
                if (imgx.encodeRgbaPngB64(alloc, frame.rgba, frame.w, frame.h)) |enc| {
                    image = enc.data;
                    iw = frame.w;
                    ih = frame.h;
                } else |_| {}
            }
        }
    }
    return .{ .summary = summary, .image = image, .width = iw, .height = ih };
}

fn countLines(text: []const u8) u32 {
    if (text.len == 0) return 0;
    var n: u32 = 1;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    if (text[text.len - 1] == '\n' and n > 0) n -= 1;
    return n;
}

fn lineRange(text: []const u8, start_line: u32, n_lines: u32) []const u8 {
    if (n_lines == 0 or text.len == 0) return "";
    var line: u32 = 0;
    var start_off: usize = 0;
    var i: usize = 0;
    var seen = false;
    while (i < text.len) : (i += 1) {
        if (line == start_line and !seen) {
            start_off = i;
            seen = true;
        }
        if (text[i] == '\n') {
            line += 1;
            if (seen and line >= start_line + n_lines) return text[start_off..i];
        }
    }
    if (!seen) return "";
    return text[start_off..];
}

pub fn hasVision(provider: *const cfgmod.Provider, model: []const u8) bool {
    if (cfgmod.metaFor(provider, model).vision) |v| return v;
    return modelHasVision(model);
}

pub fn modelHasVision(model: []const u8) bool {
    var buf: [160]u8 = undefined;
    const n = blk: {
        const len = @min(model.len, buf.len);
        for (model[0..len], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        break :blk buf[0..len];
    };
    const no = [_][]const u8{ "o1-mini", "o1-preview", "o3-mini", "o4-mini", "embedding", "moderation", "codestral" };
    const yes = [_][]const u8{ "vision", "-vl", "gpt-4o", "gpt-4.1", "gpt-5", "claude", "gemini", "grok", "pixtral", "glm-4v", "qwen-vl", "qwen2-vl", "qwen2.5-vl" };
    for (no) |p| {
        if (std.mem.indexOf(u8, n, p) != null) return false;
    }
    for (yes) |p| {
        if (std.mem.indexOf(u8, n, p) != null) return true;
    }
    return false;
}

const StatusItem = struct { tok: usize, shaped: bool };

fn statusItemGt(_: void, x: StatusItem, y: StatusItem) bool {
    return x.tok > y.tok;
}

/// /fast-compress 状态:窗况一行 + 大块清单(raw = 未入境定形)。
pub fn formatStatus(alloc: std.mem.Allocator, in: Input) []const u8 {
    const used = totalTokens(in);
    const pct: usize = if (in.window == 0) 0 else used * 100 / in.window;
    const next: []const u8 = if (pct >= 85) "compact" else "idle";
    var out = std.array_list.Managed(u8).init(alloc);
    out.appendSlice(std.fmt.allocPrint(
        alloc,
        "fast-compress: {d}/{d} ({d}%) next={s} vision={s}",
        .{ used, in.window, pct, next, if (in.vision) "yes" else "no" },
    ) catch "fast-compress: ?") catch return "fast-compress: ?";
    var items = std.array_list.Managed(StatusItem).init(alloc);
    defer items.deinit();
    for (in.messages.items) |m| {
        if (!std.mem.eql(u8, m.role, "tool")) continue;
        const tok = est(m.content) + 16;
        if (tok < 80) continue;
        items.append(.{ .tok = tok, .shaped = isPlaceholder(m.content) }) catch break;
    }
    std.mem.sort(StatusItem, items.items, {}, statusItemGt);
    var raw_tok: usize = 0;
    for (items.items) |it| {
        if (!it.shaped) raw_tok += it.tok;
    }
    out.appendSlice(std.fmt.allocPrint(alloc, " raw≈{d}", .{raw_tok}) catch "") catch {};
    for (items.items[0..@min(8, items.items.len)]) |it| {
        out.appendSlice(std.fmt.allocPrint(alloc, "\n  {d}tok {s}", .{ it.tok, if (it.shaped) "shaped" else "raw" }) catch "") catch {};
    }
    return out.toOwnedSlice() catch "fast-compress: ?";
}

test "placeholder detector covers every fast-compress marker" {
    const t = std.testing;
    try t.expect(isPlaceholder("[Output truncated - 12 tokens]"));
    try t.expect(isPlaceholder("[Superseded by a newer read of a.ts]"));
    try t.expect(isPlaceholder("[Shake elided - 9 tokens]"));
    try t.expect(isPlaceholder("[Snapcompact: 3000 tokens → 768x256 PNG ~400 tokens]"));
    try t.expect(!isPlaceholder("real tool output"));
}

test "modelHasVision gates known families" {
    const t = std.testing;
    try t.expect(modelHasVision("claude-sonnet-4"));
    try t.expect(modelHasVision("gpt-4o-mini"));
    try t.expect(modelHasVision("qwen2.5-vl-72b"));
    try t.expect(!modelHasVision("deepseek-v4-flash"));
    try t.expect(!modelHasVision("deepseek-v4-pro"));
    try t.expect(!modelHasVision("o1-mini"));
    const forced = cfgmod.Provider{
        .name = "x",
        .api = .openai_completions,
        .base_url = "https://x",
        .models = &.{"plain"},
        .model_metas = &.{.{ .vision = true }},
    };
    try t.expect(hasVision(&forced, "plain"));
    try t.expect(!hasVision(&forced, "deepseek-v4-flash"));
}

test "hasVision catalog says DeepSeek V4 cannot see images" {
    const t = std.testing;
    const ds = cfgmod.Provider{
        .name = "deepseek",
        .api = .openai_completions,
        .base_url = "https://api.deepseek.com",
        .models = &.{"deepseek-v4-flash"},
        .context_window = 1_000_000,
    };
    try t.expect(!hasVision(&ds, "deepseek-v4-flash"));
}

test "formatStatus reports window state and big blocks" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msgs = std.array_list.Managed(ai.Message).init(a);
    try msgs.append(.{ .role = "user", .content = "hi" });
    const in = Input{ .alloc = a, .messages = &msgs, .window = 1000, .api = .openai_completions, .vision = false };
    const s = formatStatus(a, in);
    try t.expect(std.mem.indexOf(u8, s, "fast-compress:") != null);
    try t.expect(std.mem.indexOf(u8, s, "vision=no") != null);
    try t.expect(std.mem.indexOf(u8, s, "next=") != null);
}

test "compactHistory builds a short card and skips old summaries" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blob = "s" ** 4000;
    const msgs = [_]ai.Message{
        .{ .role = "system", .content = "(Conversation compacted. Summary:)\n" ++ blob },
        .{ .role = "assistant", .content = "{\"path\":\"src/foo.zig\"}", .tool_calls = &[_]ai.ToolCall{.{ .name = "read", .args = "{\"path\":\"src/foo.zig\"}" }} },
        .{ .role = "user", .content = "fix the parser" },
        .{ .role = "user", .content = "then run tests" },
    };
    const fold = try compactHistory(a, &msgs, .openai_completions, false);
    try t.expect(std.mem.startsWith(u8, fold.summary, "[Snapcompact]"));
    try t.expect(std.mem.indexOf(u8, fold.summary, "FILES") != null);
    try t.expect(std.mem.indexOf(u8, fold.summary, "src/foo.zig") != null);
    try t.expect(std.mem.indexOf(u8, fold.summary, "INTENTS") != null);
    try t.expect(std.mem.indexOf(u8, fold.summary, "fix the parser") != null);
    try t.expect(std.mem.indexOf(u8, fold.summary, "then run tests") != null);
    try t.expect(std.mem.indexOf(u8, fold.summary, blob) == null);
    try t.expect(fold.image == null);
}

test "compactHistory attaches a card PNG when vision saves tokens" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fat = "w" ** (80 * 1024);
    const msgs = [_]ai.Message{
        .{ .role = "user", .content = fat },
        .{ .role = "user", .content = "work item 1" },
    };
    const fold = try compactHistory(a, &msgs, .openai_completions, true);
    try t.expect(std.mem.startsWith(u8, fold.summary, "[Snapcompact]"));
    try t.expect(fold.image != null);
    try t.expect(fold.width > 0);
    try t.expect(fold.height > 0);
}

test "shapeIngress keeps small and placeholder results untouched" {
    const t = std.testing;
    try util.testInit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const opts: IngressOpts = .{ .api = .openai_completions, .vision = true };
    const small = try shapeIngress(a, "tiny output", opts);
    try t.expect(!small.changed);
    const ph = try shapeIngress(a, "[Snapcompact: 9000 tokens → excerpt]\nold", opts);
    try t.expect(!ph.changed);
    const sk = try shapeIngress(a, @as([]const u8, "x") ** 20000, .{ .api = .openai_completions, .vision = true, .tool_name = "skill" });
    try t.expect(!sk.changed);
}

test "shapeIngress excerpts big result when model has no vision" {
    const t = std.testing;
    try util.testInit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var big = std.array_list.Managed(u8).init(a);
    var i: usize = 0;
    while (i < 600) : (i += 1) try big.appendSlice(try std.fmt.allocPrint(a, "line {d} lorem ipsum dolor sit amet\n", .{i}));
    const r = try shapeIngress(a, big.items, .{ .api = .openai_completions, .vision = false });
    try t.expect(r.changed);
    try t.expect(r.image == null);
    try t.expect(std.mem.startsWith(u8, r.text, "[Snapcompact:"));
    try t.expect(std.mem.indexOf(u8, r.text, "lines elided") != null);
    try t.expect(std.mem.indexOf(u8, r.text, "line 0") != null);
    try t.expect(std.mem.indexOf(u8, r.text, "line 599") != null);
    try t.expect(r.tokens_saved > 0);
    // 定稿即占位符:再进门不再动。
    const again = try shapeIngress(a, r.text, .{ .api = .openai_completions, .vision = false });
    try t.expect(!again.changed);
}

test "shapeIngress snaps dense image when vision and savings hold" {
    const t = std.testing;
    try util.testInit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var big = std.array_list.Managed(u8).init(a);
    var i: usize = 0;
    while (i < 800) : (i += 1) try big.appendSlice(try std.fmt.allocPrint(a, "row {d}: the quick brown fox jumps over the lazy dog\n", .{i}));
    const r = try shapeIngress(a, big.items, .{ .api = .anthropic_messages, .vision = true, .window = 262144 });
    try t.expect(r.changed);
    if (r.image) |img| {
        try t.expect(std.mem.startsWith(u8, r.text, "[Snapcompact:"));
        try t.expect(std.mem.indexOf(u8, r.text, "PNG") != null);
        try t.expect(img.len > 100);
        try t.expect(r.width > 0 and r.height > 0);
    } else {
        // 图不省时退摘录,也算定形。
        try t.expect(std.mem.indexOf(u8, r.text, "excerpt") != null);
    }
    try t.expect(r.tokens_saved > 0);
}

test "usageFooter only stamps at task nodes with hint rules" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("", try usageFooter(a, 57, 1000, 2000, null));
    const turn = try usageFooter(a, 57, 1000, 2000, .turn);
    try t.expect(std.mem.indexOf(u8, turn, "node=turn") != null);
    try t.expect(std.mem.indexOf(u8, turn, "/compact") != null); // 57% ≥ 40%
    const low = try usageFooter(a, 20, 400, 2000, .turn);
    try t.expect(std.mem.indexOf(u8, low, "/compact") == null);
    const hard = try usageFooter(a, 90, 1800, 2000, .hard);
    try t.expect(std.mem.indexOf(u8, hard, "node=hard") != null);
    try t.expect(std.mem.indexOf(u8, hard, "/compact") != null);
    const ingress_low = try usageFooter(a, 10, 200, 2000, .ingress);
    try t.expect(std.mem.indexOf(u8, ingress_low, "node=ingress") != null);
    try t.expect(std.mem.indexOf(u8, ingress_low, "/compact") == null); // ingress 不带提示
}
