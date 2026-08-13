// compress.zig — 快压三件套:prune → shake → snap。无 LLM。
//
// 比 omp 更好的四处:
//   1. 同 path 再 read 立刻 supersede 旧结果(保护窗内也裁)。omp/旧 piz 永保全部 read。
//   2. 年龄裁与 snap 优先动 cache 廉价尾(suffix ≤ 8K),不够才深裁,不无故炸热前缀。
//   3. shake 可卸 fence/XML 大块;硬线前自动救援(protect=0),避免「单轮过大切不动」。
//   4. snap 多带+留原文摘,无 vision / CJK / 图 token 不过关则跳过。
const std = @import("std");
const ai = @import("ai.zig");
const imgx = @import("imgx.zig");
const util = @import("util.zig");
const cfgmod = @import("config.zig");

const est = util.estTokensUtf8;

pub const PROTECT_TOKENS: usize = 16 * 1024;
pub const MIN_SAVINGS_TOKENS: usize = 4 * 1024;
pub const CACHE_WARM_SUFFIX: usize = 8 * 1024;
pub const SHAKE_AUTO_PERCENT: usize = 70;
pub const SNAP_AUTO_PERCENT: usize = 80;
pub const MIN_PRUNE_TOKENS: usize = 50;
pub const MIN_SNAP_TOKENS: usize = 3000;
pub const FENCE_MIN_TOKENS: usize = 400;
const PLACEHOLDER_EST: usize = 16;
const SNAP_SAVINGS_NUM: usize = 85;
const SNAP_SAVINGS_DEN: usize = 100;
const SNAP_ASCII_NUM: usize = 80;
const SNAP_ASCII_DEN: usize = 100;
const SNAP_MAX_FRAMES: usize = 6;
const CELL_W: u32 = 6;
const CELL_H: u32 = 8;
const SNAP_COLS: u32 = 128;
const SNAP_MAX_ROWS: u32 = 64;
const SNAP_HEAD_LINES: u32 = 16;
const SNAP_TAIL_LINES: u32 = 8;

pub const Input = struct {
    alloc: std.mem.Allocator,
    messages: *std.array_list.Managed(ai.Message),
    window: usize,
    api: cfgmod.Api,
    /// false = 文本模型,自动/手动 snap 都不打图(避 400,也避无故改前缀炸 cache)。
    vision: bool = true,
};

pub const Report = struct {
    superseded: usize = 0,
    pruned: usize = 0,
    shaken: usize = 0,
    snapped: usize = 0,
    images_dropped: usize = 0,
    tokens_saved: usize = 0,

    pub fn any(self: Report) bool {
        return self.tokens_saved > 0 or self.images_dropped > 0;
    }
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

fn jsonStringField(args: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + key.len + 3 < args.len) : (i += 1) {
        if (args[i] != '"') continue;
        if (!std.mem.startsWith(u8, args[i + 1 ..], key)) continue;
        if (args[i + 1 + key.len] != '"') continue;
        var j = i + 2 + key.len;
        while (j < args.len and (args[j] == ' ' or args[j] == '\t' or args[j] == '\n' or args[j] == ':')) j += 1;
        if (j >= args.len or args[j] != '"') return null;
        const start = j + 1;
        var k = start;
        while (k < args.len and args[k] != '"') {
            if (args[k] == '\\' and k + 1 < args.len) k += 2 else k += 1;
        }
        return args[start..k];
    }
    return null;
}

const ToolRef = struct { name: []const u8, args: []const u8 };

fn findTool(messages: []const ai.Message, call_id: []const u8) ?ToolRef {
    for (messages) |m| {
        const tcs = m.tool_calls orelse continue;
        for (tcs) |tc| {
            if (std.mem.eql(u8, tc.id, call_id)) return .{ .name = tc.name, .args = tc.args };
        }
    }
    return null;
}

fn isSkill(ref: ToolRef) bool {
    return std.mem.eql(u8, ref.name, "skill");
}

fn readKey(ref: ToolRef) ?[]const u8 {
    if (!std.mem.eql(u8, ref.name, "read")) return null;
    return jsonStringField(ref.args, "path");
}

fn fillSuffix(messages: []const ai.Message, out: []usize) void {
    var acc: usize = 0;
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        out[i] = acc;
        acc += est(messages[i].content) + 16;
        if (messages[i].image != null) acc += 256;
    }
}

fn noticeTrunc(alloc: std.mem.Allocator, tokens: usize) []const u8 {
    return std.fmt.allocPrint(alloc, "[Output truncated - {d} tokens]", .{tokens}) catch "[Output truncated]";
}

fn noticeSupersede(alloc: std.mem.Allocator, path: []const u8) []const u8 {
    return std.fmt.allocPrint(alloc, "[Superseded by a newer read of {s}]", .{path}) catch "[Superseded by a newer read]";
}

fn noticeShake(alloc: std.mem.Allocator, tokens: usize) []const u8 {
    return std.fmt.allocPrint(alloc, "[Shake elided - {d} tokens]", .{tokens}) catch "[Shake elided]";
}

/// 每轮自动:prune →(70%) shake →(80%) snap →(85%) shake 救援。
pub fn runAuto(in: Input) Report {
    var r = prune(in);
    const used1 = totalTokens(in);
    if (in.window > 0 and used1 > in.window * SHAKE_AUTO_PERCENT / 100) {
        const s = shake(in, .{ .protect_tokens = PROTECT_TOKENS, .min_savings = MIN_SAVINGS_TOKENS });
        r.shaken += s.shaken;
        r.tokens_saved += s.tokens_saved;
    }
    const used2 = totalTokens(in);
    if (in.vision and in.window > 0 and used2 > in.window * SNAP_AUTO_PERCENT / 100) {
        const s = snap(in);
        r.snapped += s.snapped;
        r.tokens_saved += s.tokens_saved;
    }
    const used3 = totalTokens(in);
    if (in.window > 0 and used3 > in.window * 85 / 100) {
        const s = shake(in, .{ .protect_tokens = 0, .min_savings = 0 });
        r.shaken += s.shaken;
        r.tokens_saved += s.tokens_saved;
    }
    return r;
}

pub fn totalTokens(in: Input) usize {
    var n: usize = 0;
    for (in.messages.items) |m| {
        n += est(m.content) + 16;
        if (m.image != null) n += imgx.estImageTokens(m.image_w, m.image_h, in.api, @intCast(in.window));
    }
    return n;
}

pub fn prune(in: Input) Report {
    var r = Report{};
    const msgs = in.messages.items;
    if (msgs.len == 0) return r;

    const suffix = in.alloc.alloc(usize, msgs.len) catch return r;
    defer in.alloc.free(suffix);
    fillSuffix(msgs, suffix);

    var seen_paths = std.StringHashMap(void).init(in.alloc);
    defer seen_paths.deinit();

    var i = msgs.len;
    while (i > 0) {
        i -= 1;
        const m = msgs[i];
        if (!std.mem.eql(u8, m.role, "tool")) continue;
        if (isPlaceholder(m.content)) continue;
        const id = m.tool_call_id orelse continue;
        const ref = findTool(msgs, id) orelse continue;
        if (isSkill(ref)) continue;
        const path = readKey(ref) orelse continue;
        if (seen_paths.contains(path)) {
            const tok = est(m.content);
            in.messages.items[i].content = noticeSupersede(in.alloc, path);
            r.superseded += 1;
            r.tokens_saved += if (tok > PLACEHOLDER_EST) tok - PLACEHOLDER_EST else 0;
        } else {
            seen_paths.put(path, {}) catch {};
        }
    }

    var protected: usize = 0;
    var first_protected: usize = msgs.len;
    i = msgs.len;
    while (i > 0) {
        i -= 1;
        if (!std.mem.eql(u8, msgs[i].role, "tool")) continue;
        if (protected >= PROTECT_TOKENS) break;
        protected += est(msgs[i].content);
        first_protected = i;
    }

    var cheap = std.array_list.Managed(usize).init(in.alloc);
    defer cheap.deinit();
    var deep = std.array_list.Managed(usize).init(in.alloc);
    defer deep.deinit();
    var cheap_save: usize = 0;
    var deep_save: usize = 0;
    for (0..first_protected) |j| {
        if (!std.mem.eql(u8, msgs[j].role, "tool")) continue;
        if (isPlaceholder(msgs[j].content)) continue;
        const id = msgs[j].tool_call_id orelse continue;
        const ref = findTool(msgs, id) orelse continue;
        if (isSkill(ref)) continue;
        if (readKey(ref) != null) continue; // 最新 read 已在 seen 里留下,旧的已被 supersede
        const tok = est(msgs[j].content);
        if (tok < MIN_PRUNE_TOKENS) continue;
        const gain = if (tok > PLACEHOLDER_EST) tok - PLACEHOLDER_EST else 0;
        deep.append(j) catch continue;
        deep_save += gain;
        if (suffix[j] <= CACHE_WARM_SUFFIX) {
            cheap.append(j) catch continue;
            cheap_save += gain;
        }
    }
    // 廉价尾够省就只动尾,保住热前缀;不够才深裁(值得炸 cache)。
    const victims = if (cheap_save >= MIN_SAVINGS_TOKENS) cheap.items else if (deep_save >= MIN_SAVINGS_TOKENS) deep.items else &.{};
    if (victims.len == 0) return r;
    for (victims) |j| {
        const tok = est(in.messages.items[j].content);
        in.messages.items[j].content = noticeTrunc(in.alloc, tok);
        r.pruned += 1;
        r.tokens_saved += if (tok > PLACEHOLDER_EST) tok - PLACEHOLDER_EST else 0;
    }
    return r;
}

pub const ShakeOpts = struct {
    protect_tokens: usize = PROTECT_TOKENS,
    min_savings: usize = MIN_SAVINGS_TOKENS,
    drop_images: bool = false,
};

pub fn shake(in: Input, opts: ShakeOpts) Report {
    var r = Report{};
    const msgs = in.messages.items;
    if (msgs.len == 0) return r;

    if (opts.drop_images) {
        r.images_dropped = dropImages(msgs);
        return r;
    }

    var acc_after: usize = 0;
    var i = msgs.len;
    var first_unprotected: usize = 0;
    while (i > 0) {
        i -= 1;
        if (acc_after >= opts.protect_tokens) {
            first_unprotected = i + 1;
            break;
        }
        acc_after += est(msgs[i].content) + 16;
    }
    if (opts.protect_tokens == 0) first_unprotected = msgs.len;

    var savings: usize = 0;
    var victims = std.array_list.Managed(usize).init(in.alloc);
    defer victims.deinit();
    const limit = if (opts.protect_tokens == 0) msgs.len else first_unprotected;
    for (0..limit) |j| {
        const m = msgs[j];
        if (std.mem.eql(u8, m.role, "tool")) {
            if (isPlaceholder(m.content)) continue;
            const id = m.tool_call_id orelse continue;
            const ref = findTool(msgs, id) orelse continue;
            if (isSkill(ref)) continue;
            const tok = est(m.content);
            if (tok < MIN_PRUNE_TOKENS) continue;
            savings += if (tok > PLACEHOLDER_EST) tok - PLACEHOLDER_EST else 0;
            victims.append(j) catch continue;
            continue;
        }
        if (std.mem.eql(u8, m.role, "user") or std.mem.eql(u8, m.role, "assistant")) {
            const stripped = elideHeavy(in.alloc, m.content) orelse continue;
            const before = est(m.content);
            const after = est(stripped);
            if (after + FENCE_MIN_TOKENS < before) {
                in.messages.items[j].content = stripped;
                r.shaken += 1;
                r.tokens_saved += before - after;
            }
        }
    }
    if (savings < opts.min_savings and r.shaken == 0) return r;
    if (savings >= opts.min_savings) {
        for (victims.items) |j| {
            const tok = est(in.messages.items[j].content);
            in.messages.items[j].content = noticeShake(in.alloc, tok);
            r.shaken += 1;
            r.tokens_saved += if (tok > PLACEHOLDER_EST) tok - PLACEHOLDER_EST else 0;
        }
    }
    return r;
}

pub fn dropImages(messages: []ai.Message) usize {
    var n: usize = 0;
    for (messages) |*m| {
        if (m.image == null) continue;
        m.image = null;
        m.image_mime = null;
        m.image_w = 0;
        m.image_h = 0;
        n += 1;
    }
    return n;
}

const ElideRange = struct { start: usize, end: usize, kind: enum { fence, xml } };

fn elideHeavy(alloc: std.mem.Allocator, text: []const u8) ?[]const u8 {
    var ranges = std.array_list.Managed(ElideRange).init(alloc);
    defer ranges.deinit();
    collectFences(text, &ranges);
    collectXml(text, &ranges);
    if (ranges.items.len == 0) return null;
    std.mem.sort(ElideRange, ranges.items, {}, struct {
        fn less(_: void, a: ElideRange, b: ElideRange) bool {
            return a.start < b.start;
        }
    }.less);

    var out = std.array_list.Managed(u8).init(alloc);
    var cursor: usize = 0;
    for (ranges.items) |rg| {
        if (rg.start < cursor) continue;
        out.appendSlice(text[cursor..rg.start]) catch return null;
        const tok = est(text[rg.start..rg.end]);
        const label: []const u8 = if (rg.kind == .xml) "XML" else "fence";
        const note = std.fmt.allocPrint(alloc, "[Shake elided {s} - {d} tokens]", .{ label, tok }) catch return null;
        out.appendSlice(note) catch return null;
        cursor = rg.end;
    }
    out.appendSlice(text[cursor..]) catch return null;
    return out.toOwnedSlice() catch null;
}

fn collectFences(text: []const u8, ranges: *std.array_list.Managed(ElideRange)) void {
    var in_fence = false;
    var fence_start: usize = 0;
    var line_start: usize = 0;
    var idx: usize = 0;
    while (idx <= text.len) : (idx += 1) {
        if (idx != text.len and text[idx] != '\n') continue;
        const line = text[line_start..idx];
        const trimmed = std.mem.trim(u8, line, " \t");
        const is_fence = std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~");
        if (is_fence) {
            if (!in_fence) {
                in_fence = true;
                fence_start = line_start;
            } else {
                in_fence = false;
                const tok = est(text[fence_start..idx]);
                if (tok >= FENCE_MIN_TOKENS) ranges.append(.{ .start = fence_start, .end = idx, .kind = .fence }) catch {};
            }
        }
        line_start = idx + 1;
    }
}

fn isTagChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == ':';
}

fn findCloseTag(text: []const u8, from: usize, tag: []const u8) ?usize {
    var i = from;
    while (i + 3 + tag.len <= text.len) : (i += 1) {
        if (text[i] != '<' or text[i + 1] != '/') continue;
        if (!std.mem.startsWith(u8, text[i + 2 ..], tag)) continue;
        const after = i + 2 + tag.len;
        if (after < text.len and isTagChar(text[after])) continue;
        var j = after;
        while (j < text.len and text[j] != '>') j += 1;
        if (j >= text.len) return null;
        return j + 1;
    }
    return null;
}

fn collectXml(text: []const u8, ranges: *std.array_list.Managed(ElideRange)) void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '<') {
            i += 1;
            continue;
        }
        if (i + 1 >= text.len) break;
        const nxt = text[i + 1];
        if (nxt == '/' or nxt == '!' or nxt == '?' or nxt == ' ') {
            i += 1;
            continue;
        }
        const tag_start = i + 1;
        var tag_end = tag_start;
        while (tag_end < text.len and isTagChar(text[tag_end])) tag_end += 1;
        if (tag_end == tag_start) {
            i += 1;
            continue;
        }
        const tag = text[tag_start..tag_end];
        var gt = tag_end;
        while (gt < text.len and text[gt] != '>') gt += 1;
        if (gt >= text.len) break;
        if (gt > tag_end and text[gt - 1] == '/') {
            i = gt + 1;
            continue;
        }
        const close = findCloseTag(text, gt + 1, tag) orelse {
            i += 1;
            continue;
        };
        const tok = est(text[i..close]);
        if (tok >= FENCE_MIN_TOKENS) {
            ranges.append(.{ .start = i, .end = close, .kind = .xml }) catch {};
            i = close;
            continue;
        }
        i += 1;
    }
}

fn snapEligible(msgs: []const ai.Message, j: usize) bool {
    const m = msgs[j];
    if (!std.mem.eql(u8, m.role, "tool")) return false;
    if (isPlaceholder(m.content) or m.image != null) return false;
    const id = m.tool_call_id orelse return false;
    const ref = findTool(msgs, id) orelse return false;
    if (isSkill(ref)) return false;
    const tok = est(m.content);
    if (tok < MIN_SNAP_TOKENS) return false;
    if (asciiRatio(m.content) * SNAP_ASCII_DEN < SNAP_ASCII_NUM) return false;
    return true;
}

pub fn snap(in: Input) Report {
    var r = Report{};
    if (!in.vision) return r;
    const msgs = in.messages.items;
    if (msgs.len == 0) return r;

    const suffix = in.alloc.alloc(usize, msgs.len) catch return r;
    defer in.alloc.free(suffix);
    fillSuffix(msgs, suffix);

    var cheap = std.array_list.Managed(usize).init(in.alloc);
    defer cheap.deinit();
    var deep = std.array_list.Managed(usize).init(in.alloc);
    defer deep.deinit();
    for (0..msgs.len) |j| {
        if (!snapEligible(msgs, j)) continue;
        if (suffix[j] <= CACHE_WARM_SUFFIX) {
            cheap.append(j) catch continue;
        } else {
            deep.append(j) catch continue;
        }
    }
    // 廉价尾有货就只动尾,保住热前缀;没有才深打(80% 线,值得炸 cache)。
    const victims = if (cheap.items.len > 0) cheap.items else deep.items;

    var bands_left: usize = SNAP_MAX_FRAMES;
    for (victims) |j| {
        if (bands_left == 0) break;
        const src = in.messages.items[j].content;
        const tok = est(src);
        const max_rows: u32 = @intCast(bands_left * SNAP_MAX_ROWS);
        const framed = renderFrame(in.alloc, src, max_rows) orelse continue;
        const img_tok = imgx.estImageTokens(framed.w, framed.h, in.api, @intCast(in.window));
        const notice = buildSnapText(in.alloc, src, tok, framed, img_tok) orelse continue;
        const after = est(notice) + img_tok;
        if (after * SNAP_SAVINGS_DEN > tok * SNAP_SAVINGS_NUM) continue;
        in.messages.items[j].content = notice;
        in.messages.items[j].image = framed.data;
        in.messages.items[j].image_mime = "image/png";
        in.messages.items[j].image_w = framed.w;
        in.messages.items[j].image_h = framed.h;
        const rows = if (CELL_H == 0) 0 else framed.h / CELL_H;
        const used = (rows + SNAP_MAX_ROWS - 1) / SNAP_MAX_ROWS;
        bands_left -= @min(bands_left, if (used == 0) 1 else used);
        r.snapped += 1;
        r.tokens_saved += if (tok > after) tok - after else 0;
    }
    return r;
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

fn asciiRatio(s: []const u8) usize {
    if (s.len == 0) return 100;
    var n: usize = 0;
    for (s) |c| {
        if (c < 0x80) n += 1;
    }
    return n * 100 / s.len;
}

const Frame = struct { data: []const u8, w: u32, h: u32 };

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

fn buildSnapText(alloc: std.mem.Allocator, src: []const u8, tok: usize, framed: Frame, img_tok: usize) ?[]const u8 {
    const total = countLines(src);
    const shown = if (CELL_H == 0) 0 else framed.h / CELL_H;
    const header = std.fmt.allocPrint(
        alloc,
        "[Snapcompact: {d} tokens → {d}x{d} PNG ~{d} tokens; {d}/{d} lines]\n",
        .{ tok, framed.w, framed.h, img_tok, @min(shown, total), total },
    ) catch return null;
    var out = std.array_list.Managed(u8).init(alloc);
    out.appendSlice(header) catch return null;
    const head_n: u32 = @min(SNAP_HEAD_LINES, total);
    if (head_n > 0) {
        const head = lineRange(src, 0, head_n);
        out.appendSlice(head) catch return null;
        if (head.len == 0 or head[head.len - 1] != '\n') out.append('\n') catch return null;
    }
    if (total > head_n) {
        const tail_n: u32 = @min(SNAP_TAIL_LINES, total - head_n);
        const tail_start = total - tail_n;
        if (tail_start > head_n) out.appendSlice("...\n") catch return null;
        const tail = lineRange(src, tail_start, tail_n);
        out.appendSlice(tail) catch return null;
    }
    return out.toOwnedSlice() catch null;
}

fn renderFrame(alloc: std.mem.Allocator, text: []const u8, max_rows: u32) ?Frame {
    if (max_rows == 0) return null;
    const cols = SNAP_COLS;
    var rows: u32 = 1;
    var col: u32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const ch = text[i];
        i += cp_len;
        if (ch == '\n' or col + 1 >= cols) {
            rows += 1;
            col = 0;
            if (ch == '\n') continue;
        }
        col += 1;
        if (rows > max_rows) break;
    }
    if (rows == 0) rows = 1;
    if (rows > max_rows) rows = max_rows;
    const w = cols * CELL_W;
    const h = rows * CELL_H;
    const rgba = alloc.alloc(u8, @as(usize, w) * h * 4) catch return null;
    defer alloc.free(rgba);
    @memset(rgba, 255);

    var row: u32 = 0;
    col = 0;
    i = 0;
    while (i < text.len and row < rows) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const slice = text[i..@min(i + cp_len, text.len)];
        const ch: u8 = if (slice.len == 1) slice[0] else '?';
        i += cp_len;
        if (ch == '\n' or col >= cols) {
            row += 1;
            col = 0;
            if (ch == '\n') continue;
            if (row >= rows) break;
        }
        blitGlyph(rgba, w, h, col, row, ch);
        col += 1;
    }

    const enc = imgx.encodeRgbaPngB64(alloc, rgba, w, h) catch return null;
    return .{ .data = enc.data, .w = w, .h = h };
}

fn blitGlyph(rgba: []u8, w: u32, h: u32, col: u32, row: u32, ch: u8) void {
    const bits = glyph5x7(ch);
    const ox = col * CELL_W;
    const oy = row * CELL_H;
    var gy: u32 = 0;
    while (gy < 7) : (gy += 1) {
        var gx: u32 = 0;
        while (gx < 5) : (gx += 1) {
            const on = (bits[gy] >> @intCast(4 - gx)) & 1 == 1;
            if (!on) continue;
            const x = ox + gx;
            const y = oy + gy;
            if (x >= w or y >= h) continue;
            const p = (@as(usize, y) * w + x) * 4;
            rgba[p] = 16;
            rgba[p + 1] = 16;
            rgba[p + 2] = 16;
            rgba[p + 3] = 255;
        }
    }
}

/// 5×7 点阵,bit4 = 最左像素。覆盖可打印 ASCII;其余画小框。
fn glyph5x7(ch: u8) [7]u8 {
    return switch (ch) {
        ' ' => .{ 0, 0, 0, 0, 0, 0, 0 },
        '!' => .{ 0x04, 0x04, 0x04, 0x04, 0x00, 0x04, 0x00 },
        '"' => .{ 0x0A, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00 },
        '#' => .{ 0x0A, 0x1F, 0x0A, 0x0A, 0x1F, 0x0A, 0x00 },
        '$' => .{ 0x04, 0x0F, 0x14, 0x0E, 0x05, 0x1E, 0x04 },
        '%' => .{ 0x19, 0x19, 0x02, 0x04, 0x08, 0x13, 0x13 },
        '&' => .{ 0x08, 0x14, 0x14, 0x08, 0x15, 0x12, 0x0D },
        '\'' => .{ 0x04, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00 },
        '(' => .{ 0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02 },
        ')' => .{ 0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08 },
        '*' => .{ 0x00, 0x0A, 0x04, 0x1F, 0x04, 0x0A, 0x00 },
        '+' => .{ 0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00 },
        ',' => .{ 0x00, 0x00, 0x00, 0x00, 0x04, 0x04, 0x08 },
        '-' => .{ 0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00 },
        '.' => .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00 },
        '/' => .{ 0x01, 0x01, 0x02, 0x04, 0x08, 0x10, 0x10 },
        '0' => .{ 0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E },
        '1' => .{ 0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E },
        '2' => .{ 0x0E, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1F },
        '3' => .{ 0x1F, 0x01, 0x02, 0x06, 0x01, 0x11, 0x0E },
        '4' => .{ 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02 },
        '5' => .{ 0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E },
        '6' => .{ 0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E },
        '7' => .{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08 },
        '8' => .{ 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E },
        '9' => .{ 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C },
        ':' => .{ 0x00, 0x04, 0x00, 0x00, 0x04, 0x00, 0x00 },
        ';' => .{ 0x00, 0x04, 0x00, 0x00, 0x04, 0x04, 0x08 },
        '<' => .{ 0x02, 0x04, 0x08, 0x10, 0x08, 0x04, 0x02 },
        '=' => .{ 0x00, 0x00, 0x1F, 0x00, 0x1F, 0x00, 0x00 },
        '>' => .{ 0x08, 0x04, 0x02, 0x01, 0x02, 0x04, 0x08 },
        '?' => .{ 0x0E, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04 },
        '@' => .{ 0x0E, 0x11, 0x17, 0x15, 0x17, 0x10, 0x0E },
        'A' => .{ 0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 },
        'B' => .{ 0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E },
        'C' => .{ 0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E },
        'D' => .{ 0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C },
        'E' => .{ 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F },
        'F' => .{ 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10 },
        'G' => .{ 0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F },
        'H' => .{ 0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 },
        'I' => .{ 0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E },
        'J' => .{ 0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C },
        'K' => .{ 0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11 },
        'L' => .{ 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F },
        'M' => .{ 0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11 },
        'N' => .{ 0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11 },
        'O' => .{ 0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E },
        'P' => .{ 0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10 },
        'Q' => .{ 0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D },
        'R' => .{ 0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11 },
        'S' => .{ 0x0E, 0x11, 0x10, 0x0E, 0x01, 0x11, 0x0E },
        'T' => .{ 0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04 },
        'U' => .{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E },
        'V' => .{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04 },
        'W' => .{ 0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11 },
        'X' => .{ 0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11 },
        'Y' => .{ 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04 },
        'Z' => .{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F },
        '[' => .{ 0x0E, 0x08, 0x08, 0x08, 0x08, 0x08, 0x0E },
        '\\' => .{ 0x10, 0x10, 0x08, 0x04, 0x02, 0x01, 0x01 },
        ']' => .{ 0x0E, 0x02, 0x02, 0x02, 0x02, 0x02, 0x0E },
        '^' => .{ 0x04, 0x0A, 0x11, 0x00, 0x00, 0x00, 0x00 },
        '_' => .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F },
        '`' => .{ 0x08, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00 },
        'a' => .{ 0x00, 0x00, 0x0E, 0x01, 0x0F, 0x11, 0x0F },
        'b' => .{ 0x10, 0x10, 0x1E, 0x11, 0x11, 0x11, 0x1E },
        'c' => .{ 0x00, 0x00, 0x0E, 0x11, 0x10, 0x11, 0x0E },
        'd' => .{ 0x01, 0x01, 0x0F, 0x11, 0x11, 0x11, 0x0F },
        'e' => .{ 0x00, 0x00, 0x0E, 0x11, 0x1F, 0x10, 0x0E },
        'f' => .{ 0x06, 0x08, 0x08, 0x1C, 0x08, 0x08, 0x08 },
        'g' => .{ 0x00, 0x00, 0x0F, 0x11, 0x0F, 0x01, 0x0E },
        'h' => .{ 0x10, 0x10, 0x1E, 0x11, 0x11, 0x11, 0x11 },
        'i' => .{ 0x04, 0x00, 0x0C, 0x04, 0x04, 0x04, 0x0E },
        'j' => .{ 0x02, 0x00, 0x06, 0x02, 0x02, 0x12, 0x0C },
        'k' => .{ 0x10, 0x10, 0x12, 0x14, 0x18, 0x14, 0x12 },
        'l' => .{ 0x0C, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E },
        'm' => .{ 0x00, 0x00, 0x1A, 0x15, 0x15, 0x15, 0x15 },
        'n' => .{ 0x00, 0x00, 0x1E, 0x11, 0x11, 0x11, 0x11 },
        'o' => .{ 0x00, 0x00, 0x0E, 0x11, 0x11, 0x11, 0x0E },
        'p' => .{ 0x00, 0x00, 0x1E, 0x11, 0x1E, 0x10, 0x10 },
        'q' => .{ 0x00, 0x00, 0x0F, 0x11, 0x0F, 0x01, 0x01 },
        'r' => .{ 0x00, 0x00, 0x16, 0x19, 0x10, 0x10, 0x10 },
        's' => .{ 0x00, 0x00, 0x0F, 0x10, 0x0E, 0x01, 0x1E },
        't' => .{ 0x08, 0x08, 0x1C, 0x08, 0x08, 0x08, 0x06 },
        'u' => .{ 0x00, 0x00, 0x11, 0x11, 0x11, 0x11, 0x0F },
        'v' => .{ 0x00, 0x00, 0x11, 0x11, 0x11, 0x0A, 0x04 },
        'w' => .{ 0x00, 0x00, 0x11, 0x15, 0x15, 0x15, 0x0A },
        'x' => .{ 0x00, 0x00, 0x11, 0x0A, 0x04, 0x0A, 0x11 },
        'y' => .{ 0x00, 0x00, 0x11, 0x11, 0x0F, 0x01, 0x0E },
        'z' => .{ 0x00, 0x00, 0x1F, 0x02, 0x04, 0x08, 0x1F },
        '{' => .{ 0x02, 0x04, 0x04, 0x08, 0x04, 0x04, 0x02 },
        '|' => .{ 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04 },
        '}' => .{ 0x08, 0x04, 0x04, 0x02, 0x04, 0x04, 0x08 },
        '~' => .{ 0x00, 0x00, 0x08, 0x15, 0x02, 0x00, 0x00 },
        else => .{ 0x1F, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1F },
    };
}

fn formatReport(alloc: std.mem.Allocator, r: Report) []const u8 {
    return std.fmt.allocPrint(
        alloc,
        "fast-compress: supersede {d} prune {d} shake {d} snap {d} (−{d} tok)",
        .{ r.superseded, r.pruned, r.shaken, r.snapped, r.tokens_saved },
    ) catch "fast-compress: done";
}

pub fn formatNotice(alloc: std.mem.Allocator, r: Report) ?[]const u8 {
    if (!r.any()) return null;
    return formatReport(alloc, r);
}

pub fn modelHasVision(model: []const u8) bool {
    var buf: [160]u8 = undefined;
    const n = blk: {
        const len = @min(model.len, buf.len);
        for (model[0..len], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        break :blk buf[0..len];
    };
    const no = [_][]const u8{ "reasoner", "o1-mini", "o1-preview", "o3-mini", "o4-mini", "embedding", "moderation", "codestral" };
    const yes = [_][]const u8{ "vision", "-vl", "gpt-4o", "gpt-4.1", "gpt-5", "claude", "gemini", "grok", "pixtral", "glm-4v", "qwen-vl", "qwen2-vl", "qwen2.5-vl" };
    for (no) |p| {
        if (std.mem.indexOf(u8, n, p) != null) return false;
    }
    for (yes) |p| {
        if (std.mem.indexOf(u8, n, p) != null) return true;
    }
    return false;
}

pub fn formatStatus(alloc: std.mem.Allocator, in: Input) []const u8 {
    const used = totalTokens(in);
    const pct: usize = if (in.window == 0) 0 else used * 100 / in.window;
    const next: []const u8 = if (pct >= 85) "compact" else if (pct >= 80) "snap" else if (pct >= 70) "shake" else "prune";
    var n_sup: usize = 0;
    var n_trunc: usize = 0;
    var n_shake: usize = 0;
    var n_snap: usize = 0;
    var n_img: usize = 0;
    for (in.messages.items) |m| {
        if (std.mem.startsWith(u8, m.content, "[Superseded")) n_sup += 1 else if (std.mem.startsWith(u8, m.content, "[Output truncated")) n_trunc += 1 else if (std.mem.startsWith(u8, m.content, "[Shake elided")) n_shake += 1 else if (std.mem.startsWith(u8, m.content, "[Snapcompact")) n_snap += 1;
        if (m.image != null) n_img += 1;
    }
    return std.fmt.allocPrint(
        alloc,
        "fast-compress: {d}/{d} ({d}%) next={s} vision={s} superseded={d} prune={d} shake={d} snap={d} images={d}",
        .{ used, in.window, pct, next, if (in.vision) "yes" else "no", n_sup, n_trunc, n_shake, n_snap, n_img },
    ) catch "fast-compress: ?";
}

fn makeAgentish(alloc: std.mem.Allocator) !std.array_list.Managed(ai.Message) {
    var msgs = std.array_list.Managed(ai.Message).init(alloc);
    try msgs.ensureTotalCapacity(64);
    return msgs;
}

fn addTool(alloc: std.mem.Allocator, msgs: *std.array_list.Managed(ai.Message), id: []const u8, name: []const u8, args: []const u8, content: []const u8) !void {
    const tcs = try alloc.alloc(ai.ToolCall, 1);
    tcs[0] = .{ .id = id, .name = name, .args = args };
    try msgs.append(.{ .role = "assistant", .content = "a", .tool_calls = tcs });
    try msgs.append(.{ .role = "tool", .content = content, .tool_call_id = id });
}

test "prune supersedes older read of the same path" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msgs = try makeAgentish(a);
    const big = "x" ** 800;
    try addTool(a, &msgs, "r1", "read", "{\"path\":\"src/a.zig\"}", big);
    try addTool(a, &msgs, "r2", "read", "{\"path\":\"src/a.zig\"}", big ++ "newer");
    const in = Input{ .alloc = a, .messages = &msgs, .window = 128 * 1024, .api = .openai_completions };
    const r = prune(in);
    try t.expect(r.superseded == 1);
    try t.expect(std.mem.startsWith(u8, msgs.items[1].content, "[Superseded"));
    try t.expect(std.mem.eql(u8, msgs.items[3].content, big ++ "newer"));
}

test "prune age-cuts old bash in the cheap tail and keeps latest read" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msgs = try makeAgentish(a);
    const big = "z" ** (20 * 1024);
    var n: usize = 0;
    while (n < 8) : (n += 1) {
        const id = try std.fmt.allocPrint(a, "b{d}", .{n});
        try addTool(a, &msgs, id, "bash", "{}", big);
    }
    try addTool(a, &msgs, "rd", "read", "{\"path\":\"keep.zig\"}", big);
    const in = Input{ .alloc = a, .messages = &msgs, .window = 128 * 1024, .api = .openai_completions };
    const r = prune(in);
    try t.expect(r.pruned > 0);
    var read_ok = false;
    var cut = false;
    for (msgs.items) |m| {
        if (!std.mem.eql(u8, m.role, "tool")) continue;
        if (std.mem.eql(u8, m.tool_call_id orelse "", "rd")) {
            try t.expectEqualStrings(big, m.content);
            read_ok = true;
        }
        if (std.mem.startsWith(u8, m.content, "[Output truncated")) cut = true;
    }
    try t.expect(read_ok);
    try t.expect(cut);
}

test "shake drops old tool results and large fences" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msgs = try makeAgentish(a);
    const big = "y" ** (6 * 1024);
    try addTool(a, &msgs, "b0", "bash", "{}", big);
    try addTool(a, &msgs, "sk", "skill", "{\"name\":\"x\"}", big);
    const fence = "intro\n```\n" ++ ("line\n" ** 500) ++ "```\nend";
    try msgs.append(.{ .role = "assistant", .content = fence });
    const in = Input{ .alloc = a, .messages = &msgs, .window = 128 * 1024, .api = .openai_completions };
    const r = shake(in, .{ .protect_tokens = 0, .min_savings = 0 });
    try t.expect(r.shaken >= 2);
    try t.expect(std.mem.startsWith(u8, msgs.items[1].content, "[Shake elided"));
    try t.expectEqualStrings(big, msgs.items[3].content); // skill 保留
    try t.expect(std.mem.indexOf(u8, msgs.items[4].content, "[Shake elided fence") != null);
}

test "snap rasters large ASCII tool output and skips CJK" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msgs = try makeAgentish(a);
    const ascii = "fn main() void { return; }\n" ** 600;
    try t.expect(est(ascii) >= MIN_SNAP_TOKENS);
    try addTool(a, &msgs, "b0", "bash", "{}", ascii);
    const zh = "这是一段很长的中文日志用来验证密图不会拿汉字去赌视觉识别。" ** 80;
    try addTool(a, &msgs, "b1", "bash", "{}", zh);
    const in = Input{ .alloc = a, .messages = &msgs, .window = 128 * 1024, .api = .openai_completions };
    const r = snap(in);
    try t.expect(r.snapped == 1);
    try t.expect(msgs.items[1].image != null);
    try t.expect(std.mem.startsWith(u8, msgs.items[1].content, "[Snapcompact"));
    try t.expect(msgs.items[3].image == null);
    try t.expect(!std.mem.startsWith(u8, msgs.items[3].content, "[Snapcompact"));

    var out = std.array_list.Managed(ai.Message).init(a);
    try appendForRequest(&out, msgs.items[1]);
    try t.expectEqual(@as(usize, 2), out.items.len);
    try t.expectEqualStrings("tool", out.items[0].role);
    try t.expect(out.items[0].image == null);
    try t.expectEqualStrings("user", out.items[1].role);
    try t.expect(out.items[1].image != null);
}

test "dropImages clears attachments" {
    const t = std.testing;
    var msgs = [_]ai.Message{
        .{ .role = "user", .content = "see", .image = "AAAA", .image_mime = "image/png", .image_w = 10, .image_h = 10 },
        .{ .role = "assistant", .content = "ok" },
    };
    try t.expectEqual(@as(usize, 1), dropImages(&msgs));
    try t.expect(msgs[0].image == null);
    try t.expectEqual(@as(u32, 0), msgs[0].image_w);
}

test "placeholder detector covers every fast-compress marker" {
    const t = std.testing;
    try t.expect(isPlaceholder("[Output truncated - 12 tokens]"));
    try t.expect(isPlaceholder("[Superseded by a newer read of a.ts]"));
    try t.expect(isPlaceholder("[Shake elided - 9 tokens]"));
    try t.expect(isPlaceholder("[Snapcompact: 3000 tokens → 768x256 PNG ~400 tokens]"));
    try t.expect(!isPlaceholder("real tool output"));
}

test "snap keeps a text excerpt so the original is not evaporated" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msgs = try makeAgentish(a);
    const line = "fn snap_excerpt_marker() void { return; }\n";
    const ascii = line ** 600;
    try t.expect(est(ascii) >= MIN_SNAP_TOKENS);
    try addTool(a, &msgs, "b0", "bash", "{}", ascii);
    const in = Input{ .alloc = a, .messages = &msgs, .window = 128 * 1024, .api = .openai_completions };
    const r = snap(in);
    try t.expect(r.snapped == 1);
    try t.expect(msgs.items[1].image != null);
    try t.expect(std.mem.startsWith(u8, msgs.items[1].content, "[Snapcompact"));
    try t.expect(std.mem.indexOf(u8, msgs.items[1].content, "snap_excerpt_marker") != null);
}

test "snap covers more than one 64-row band" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msgs = try makeAgentish(a);
    const ascii = "fn main() void { return; }\n" ** 600;
    try addTool(a, &msgs, "b0", "bash", "{}", ascii);
    const in = Input{ .alloc = a, .messages = &msgs, .window = 128 * 1024, .api = .openai_completions };
    const r = snap(in);
    try t.expect(r.snapped == 1);
    try t.expect(msgs.items[1].image_h > 64 * CELL_H);
}

test "snap prefers cheap tail so prefix cache stays warm" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msgs = try makeAgentish(a);
    const ascii = "fn cache_prefix_keep() void { return; }\n" ** 600;
    const recent = "fn cache_tail_snap() void { return; }\n" ** 600;
    try addTool(a, &msgs, "old", "bash", "{}", ascii);
    var k: usize = 0;
    while (k < 16) : (k += 1) {
        try msgs.append(.{ .role = "user", .content = "w" ** 2500 });
    }
    try addTool(a, &msgs, "new", "bash", "{}", recent);
    const in = Input{ .alloc = a, .messages = &msgs, .window = 128 * 1024, .api = .openai_completions };
    const r = snap(in);
    try t.expect(r.snapped == 1);
    try t.expect(msgs.items[1].image == null);
    try t.expect(!std.mem.startsWith(u8, msgs.items[1].content, "[Snapcompact"));
    const last = msgs.items[msgs.items.len - 1];
    try t.expect(last.image != null);
    try t.expect(std.mem.startsWith(u8, last.content, "[Snapcompact"));
}

test "shake elides large XML blocks" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msgs = try makeAgentish(a);
    const xml = "<repo-rules>\n" ++ ("rule line keep-me-out\n" ** 500) ++ "</repo-rules>\nkeep";
    try msgs.append(.{ .role = "assistant", .content = xml });
    const in = Input{ .alloc = a, .messages = &msgs, .window = 128 * 1024, .api = .openai_completions };
    const r = shake(in, .{ .protect_tokens = 0, .min_savings = 0 });
    try t.expect(r.shaken >= 1);
    try t.expect(std.mem.indexOf(u8, msgs.items[0].content, "[Shake elided") != null);
    try t.expect(std.mem.indexOf(u8, msgs.items[0].content, "keep") != null);
    try t.expect(std.mem.indexOf(u8, msgs.items[0].content, "keep-me-out") == null);
}

test "prune still supersedes when history is longer than 8192 messages" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msgs = try makeAgentish(a);
    try addTool(a, &msgs, "r1", "read", "{\"path\":\"src/a.zig\"}", "old-body-xxxxxxxx");
    var n: usize = 0;
    while (n < 8192) : (n += 1) {
        try msgs.append(.{ .role = "user", .content = "x" });
    }
    try addTool(a, &msgs, "r2", "read", "{\"path\":\"src/a.zig\"}", "new-body-yyyyyyyy");
    const in = Input{ .alloc = a, .messages = &msgs, .window = 128 * 1024, .api = .openai_completions };
    const r = prune(in);
    try t.expect(r.superseded == 1);
    try t.expect(std.mem.startsWith(u8, msgs.items[1].content, "[Superseded"));
    try t.expectEqualStrings("new-body-yyyyyyyy", msgs.items[msgs.items.len - 1].content);
}

test "snap skips when the model has no vision" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msgs = try makeAgentish(a);
    const ascii = "fn main() void { return; }\n" ** 600;
    try addTool(a, &msgs, "b0", "bash", "{}", ascii);
    const in = Input{ .alloc = a, .messages = &msgs, .window = 128 * 1024, .api = .openai_completions, .vision = false };
    const r = snap(in);
    try t.expect(r.snapped == 0);
    try t.expect(msgs.items[1].image == null);
    try t.expect(!std.mem.startsWith(u8, msgs.items[1].content, "[Snapcompact"));
}

test "snap goes deep only when the cheap tail has nothing eligible" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msgs = try makeAgentish(a);
    const ascii = "fn deep_only_snap() void { return; }\n" ** 600;
    try addTool(a, &msgs, "old", "bash", "{}", ascii);
    var k: usize = 0;
    while (k < 16) : (k += 1) {
        try msgs.append(.{ .role = "user", .content = "w" ** 2500 });
    }
    const in = Input{ .alloc = a, .messages = &msgs, .window = 128 * 1024, .api = .openai_completions };
    const r = snap(in);
    try t.expect(r.snapped == 1);
    try t.expect(msgs.items[1].image != null);
}

test "modelHasVision gates known families" {
    const t = std.testing;
    try t.expect(modelHasVision("claude-sonnet-4"));
    try t.expect(modelHasVision("gpt-4o-mini"));
    try t.expect(modelHasVision("qwen2.5-vl-72b"));
    try t.expect(!modelHasVision("deepseek-reasoner"));
    try t.expect(!modelHasVision("deepseek-chat"));
    try t.expect(!modelHasVision("o1-mini"));
}

test "formatStatus reports usage next-layer and vision" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msgs = try makeAgentish(a);
    try msgs.append(.{ .role = "user", .content = "hi" });
    const in = Input{ .alloc = a, .messages = &msgs, .window = 1000, .api = .openai_completions, .vision = false };
    const s = formatStatus(a, in);
    try t.expect(std.mem.indexOf(u8, s, "fast-compress:") != null);
    try t.expect(std.mem.indexOf(u8, s, "vision=no") != null);
    try t.expect(std.mem.indexOf(u8, s, "next=") != null);
}
