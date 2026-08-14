// web-search / fetch_url。
const std = @import("std");
const agentmod = @import("../agent.zig");
const activity = @import("../activity.zig");
const toolsmod = @import("../tools.zig");
const util = @import("../util.zig");
const jsonx = @import("jsonx.zig");

// =====================================================================
// web 搜索插件:web_search + fetch_url。
//
// 「路走不通要联网」的落点。两个工具是一对:搜索给线索,取正文才拿到答案 ——
// 只有搜索的话模型看到一堆标题和摘要,还得靠 bash+curl 硬啃 HTML。
// =====================================================================

/// URL 查询串编码。不编码的话「zig 0.16 std.Io」这种带空格的查询直接坏掉,
/// 而带空格恰恰是搜索查询的常态。
fn urlEncode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try aw.writer.writeByte(c);
        } else {
            // 手工两位十六进制:Zig 0.16 的格式串没有零填充语法
            const hex = "0123456789ABCDEF";
            try aw.writer.writeAll(&[_]u8{ '%', hex[c >> 4], hex[c & 0xF] });
        }
    }
    return aw.toOwnedSlice();
}

pub fn toolWebSearch(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = ctx;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{});
    const q = blk: {
        if (v == .object) {
            if (v.object.get("query")) |qv| {
                if (qv == .string) break :blk qv.string;
            }
        }
        break :blk "";
    };
    if (q.len == 0) return .{ .content = "error: web_search requires 'query'", .is_error = true };

    const endpoint = agentmod.util.getEnv("PIZ_WEB_SEARCH_URL") orelse "";
    if (endpoint.len == 0) {
        // 说清怎么修而不只是说坏了 —— 模型看到这条要能判断「换 bash+curl」
        return .{
            .content = "error: web_search is not configured. Set PIZ_WEB_SEARCH_URL to a JSON search endpoint that takes the query as its last parameter (e.g. http://localhost:8080/search?q= for SearXNG). Until then, use bash with curl for network lookups.",
            .is_error = true,
        };
    }
    const enc = try urlEncode(arena, q);
    const url = try std.fmt.allocPrint(arena, "{s}{s}&format=json", .{ endpoint, enc });
    const raw = agentmod.util.execShortTimeout(arena, &.{ "curl", "-sS", "--max-time", "15", url }, 20) catch
        return .{ .content = "error: search request failed (is the endpoint reachable?)", .is_error = true };
    // 整形成人读的列表:原样回 SearXNG 的 JSON 是几十 KB 的嵌套结构,
    // 模型得自己在里面翻 title/url/content,白烧上下文。
    return .{ .content = try shapeSearchResults(arena, raw, q) };
}

/// 把 SearXNG 的 JSON 压成紧凑列表。解析失败就原样返回 —— 端点可能不是 SearXNG。
fn shapeSearchResults(arena: std.mem.Allocator, raw: []const u8, query: []const u8) ![]const u8 {
    const MAX_RESULTS = 8;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return raw;
    if (root != .object) return raw;
    const results = root.object.get("results") orelse return raw;
    if (results != .array) return raw;

    var aw = std.Io.Writer.Allocating.init(arena);
    try aw.writer.print("Search results for \"{s}\":\n", .{query});
    var n: usize = 0;
    for (results.array.items) |item| {
        if (n >= MAX_RESULTS) break;
        if (item != .object) continue;
        const title = jsonx.jsonStr(item, "title") orelse continue;
        const url = jsonx.jsonStr(item, "url") orelse continue;
        const snippet = jsonx.jsonStr(item, "content") orelse "";
        n += 1;
        try aw.writer.print("\n{d}. {s}\n   {s}\n", .{ n, title, url });
        if (snippet.len > 0) {
            const cut = @min(snippet.len, 300);
            try aw.writer.print("   {s}{s}\n", .{ snippet[0..cut], if (snippet.len > cut) "…" else "" });
        }
    }
    if (n == 0) return try std.fmt.allocPrint(arena, "No results for \"{s}\".", .{query});
    try aw.writer.writeAll("\nUse fetch_url on a result to read its full text.");
    return aw.toOwnedSlice();
}

/// 没有这个工具,搜索就只是给了一串链接 —— 模型拿不到里面写了什么,
/// 只能退回 bash+curl 然后在原始 HTML 里翻。
pub fn toolFetchUrl(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = ctx;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{});
    const url = jsonx.jsonStr(v, "url") orelse return .{ .content = "error: fetch_url requires 'url'", .is_error = true };
    // 只允许 http(s):否则 `file://` 能读本地任意文件,`gopher://` 之类能拿 curl 当跳板
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return .{ .content = "error: fetch_url only accepts http:// or https:// URLs", .is_error = true };
    }
    const act = activity.begin(.tool, "fetch_url", url, 30_000);
    defer act.release();

    const raw = agentmod.util.execShortTimeout(arena, &.{
        "curl", "-sSL",                                      "--max-time", "25", "--max-filesize", "8000000",
        "-H",   "user-agent: Mozilla/5.0 (compatible; piz)", url,
    }, 30) catch return .{ .content = "error: fetch failed (unreachable, timed out, or too large)", .is_error = true };

    const text = try htmlToText(arena, raw);
    if (text.len == 0) return .{ .content = "error: fetched page had no readable text", .is_error = true };
    const LIMIT = 24 * 1024;
    if (text.len > LIMIT) {
        return .{ .content = try std.fmt.allocPrint(arena, "{s}\n\n...[truncated at {d} of {d} chars]", .{ text[0..LIMIT], LIMIT, text.len }) };
    }
    return .{ .content = text };
}

/// HTML 抽正文。不是解析器,是「够用的降噪」:
/// 丢掉 script/style/head 的内容,去标签,解常见实体,压空白。
///
/// 为什么不引第三方 readability:piz 是零依赖项目,而模型对噪声的容忍度
/// 比人高得多 —— 它需要的是「能读到字」,不是排版还原。
fn htmlToText(arena: std.mem.Allocator, html: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(arena);
    var i: usize = 0;
    var last_was_space = true; // 开头不留空白
    while (i < html.len) {
        if (html[i] == '<') {
            // 整块跳过的标签:里面是代码/样式,不是正文。
            // 先求跳转位置再统一处理 —— `inline for` 里的 continue 归属编译期循环,
            // 不能用来跳过外层的 while 迭代。
            const skip_to: ?usize = blk: {
                inline for (.{ "script", "style", "head", "noscript", "svg" }) |tag| {
                    if (matchTagOpen(html, i, tag)) break :blk skipToTagClose(html, i, tag);
                }
                break :blk null;
            };
            if (skip_to) |to| {
                i = to;
                continue;
            }
            // 块级标签转成换行,免得整页挤成一行
            const is_break = matchTagOpen(html, i, "p") or matchTagOpen(html, i, "br") or
                matchTagOpen(html, i, "div") or matchTagOpen(html, i, "li") or
                matchTagOpen(html, i, "tr") or matchTagOpen(html, i, "h1") or
                matchTagOpen(html, i, "h2") or matchTagOpen(html, i, "h3");
            const end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse html.len;
            i = end + 1;
            if (is_break and out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
                try out.append('\n');
                last_was_space = true;
            }
            continue;
        }
        if (html[i] == '&') {
            if (decodeEntity(html, i)) |hit| {
                try out.appendSlice(hit.text);
                i = hit.next;
                last_was_space = false;
                continue;
            }
        }
        const c = html[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!last_was_space) {
                try out.append(' ');
                last_was_space = true;
            }
        } else {
            try out.append(c);
            last_was_space = false;
        }
        i += 1;
    }
    return out.toOwnedSlice();
}

fn matchTagOpen(html: []const u8, i: usize, tag: []const u8) bool {
    if (i + 1 + tag.len > html.len) return false;
    if (html[i] != '<') return false;
    if (!std.ascii.startsWithIgnoreCase(html[i + 1 ..], tag)) return false;
    const after = i + 1 + tag.len;
    if (after >= html.len) return true;
    const c = html[after];
    return c == '>' or c == ' ' or c == '\t' or c == '\n' or c == '/' or c == '\r';
}

fn skipToTagClose(html: []const u8, start: usize, tag: []const u8) usize {
    var i = start + 1 + tag.len;
    while (i + 2 + tag.len < html.len) : (i += 1) {
        if (html[i] == '<' and html[i + 1] == '/' and std.ascii.startsWithIgnoreCase(html[i + 2 ..], tag)) {
            const end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse return html.len;
            return end + 1;
        }
    }
    return html.len;
}

const EntityHit = struct { text: []const u8, next: usize };

fn decodeEntity(html: []const u8, i: usize) ?EntityHit {
    const rest = html[i..];
    const pairs = [_]struct { []const u8, []const u8 }{
        .{ "&amp;", "&" },
        .{ "&lt;", "<" },
        .{ "&gt;", ">" },
        .{ "&quot;", "\"" },
        .{ "&apos;", "'" },
        .{ "&nbsp;", " " },
        .{ "&#39;", "'" },
        .{ "&#x27;", "'" },
        .{ "&#34;", "\"" },
    };
    for (pairs) |p| {
        if (std.mem.startsWith(u8, rest, p[0])) return .{ .text = p[1], .next = i + p[0].len };
    }
    return null;
}

test "htmlToText strips tags and decodes entities" {
    const t = std.testing;
    const a = t.allocator;
    const out = try htmlToText(a, "<html><head><title>x</title></head><body><h1>Hello</h1><p>world &amp; zig</p><script>bad()</script></body></html>");
    defer a.free(out);
    try t.expect(std.mem.indexOf(u8, out, "Hello") != null);
    try t.expect(std.mem.indexOf(u8, out, "world & zig") != null);
    try t.expect(std.mem.indexOf(u8, out, "bad()") == null);
    try t.expect(std.mem.indexOf(u8, out, "<") == null);
}

test "urlEncode encodes spaces and unicode bytes" {
    const t = std.testing;
    const a = t.allocator;
    const enc = try urlEncode(a, "zig 0.16");
    defer a.free(enc);
    try t.expectEqualStrings("zig%200.16", enc);
}

test "shapeSearchResults formats searx-like json" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw =
        \\{"results":[{"title":"Zig","url":"https://ziglang.org","content":"A programming language."}]}
    ;
    const out = try shapeSearchResults(a, raw, "zig");
    try t.expect(std.mem.indexOf(u8, out, "Zig") != null);
    try t.expect(std.mem.indexOf(u8, out, "https://ziglang.org") != null);
    try t.expect(std.mem.indexOf(u8, out, "fetch_url") != null);
}
