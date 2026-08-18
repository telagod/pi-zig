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

/// `/web`：无参报端点；有参当 query 跑搜索。
fn webStatus(arena: std.mem.Allocator) ![]const u8 {
    const endpoint = agentmod.util.getEnv("PIZ_WEB_SEARCH_URL") orelse "";
    if (endpoint.len == 0) {
        return arena.dupe(u8, "web-search: PIZ_WEB_SEARCH_URL is unset.\nSet it to a SearXNG JSON endpoint (e.g. http://127.0.0.1:8080/search?q=).\nusage: /web <query>");
    }
    return std.fmt.allocPrint(arena, "web-search: endpoint {s}\nusage: /web <query>\nfetch_url blocks private/localhost/metadata.", .{endpoint});
}

pub fn slashWeb(ctx: ?*anyopaque, args: []const u8) anyerror![]const u8 {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx orelse return error.NoAgent));
    var arena = agentmod.util.Arena.init(self.alloc);
    defer arena.deinit();
    const q = std.mem.trim(u8, args, " \t\r\n");
    if (q.len == 0) {
        const line = try webStatus(arena.allocator());
        return self.alloc.dupe(u8, line);
    }
    var jw = std.Io.Writer.Allocating.init(arena.allocator());
    try jw.writer.writeAll("{\"query\":");
    try std.json.Stringify.value(q, .{}, &jw.writer);
    try jw.writer.writeByte('}');
    const r = try toolWebSearch(ctx, arena.allocator(), jw.written());
    return self.alloc.dupe(u8, r.content);
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
fn urlHost(url: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    var rest = url[sep + 3 ..];
    if (rest.len == 0) return null;
    if (rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
        return rest[1..close];
    }
    if (std.mem.indexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];
    var end: usize = 0;
    while (end < rest.len) : (end += 1) {
        switch (rest[end]) {
            ':', '/', '?', '#' => break,
            else => {},
        }
    }
    if (end == 0) return null;
    if (rest[end - 1] == '.') return rest[0 .. end - 1];
    return rest[0..end];
}

fn parseHexU32(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var acc: u32 = 0;
    for (s) |c| {
        const d: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        acc = acc *% 16 + d;
    }
    return acc;
}

fn parseOctet(s: []const u8, max: u32) ?u32 {
    if (s.len == 0) return null;
    var v: u32 = 0;
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        v = parseHexU32(s[2..]) orelse return null;
    } else if (s.len > 1 and s[0] == '0') {
        for (s) |c| {
            if (c < '0' or c > '7') return null;
            v = v *% 8 + (c - '0');
        }
    } else {
        for (s) |c| {
            if (c < '0' or c > '9') return null;
            v = v *% 10 + (c - '0');
        }
    }
    if (v > max) return null;
    return v;
}

fn parseIpv4Loose(host: []const u8) ?u32 {
    if (host.len == 0) return null;
    for (host) |c| {
        switch (c) {
            '0'...'9', '.', 'x', 'X' => {},
            else => return null,
        }
    }
    var vals: [4]u32 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |p| {
        if (n >= 4) return null;
        vals[n] = parseOctet(p, 0xffff_ffff) orelse return null;
        n += 1;
    }
    return switch (n) {
        1 => vals[0],
        2 => if (vals[0] <= 255 and vals[1] <= 0xff_ffff) (vals[0] << 24) | vals[1] else null,
        3 => if (vals[0] <= 255 and vals[1] <= 255 and vals[2] <= 0xffff) (vals[0] << 24) | (vals[1] << 16) | vals[2] else null,
        4 => if (vals[0] <= 255 and vals[1] <= 255 and vals[2] <= 255 and vals[3] <= 255)
            (vals[0] << 24) | (vals[1] << 16) | (vals[2] << 8) | vals[3]
        else
            null,
        else => null,
    };
}

fn ipv4Blocked(ip: u32) bool {
    const a = ip >> 24;
    const b = (ip >> 16) & 0xff;
    if (a == 0 or a == 10 or a == 127) return true;
    if (a == 169 and b == 254) return true;
    if (a == 172 and b >= 16 and b <= 31) return true;
    if (a == 192 and b == 168) return true;
    if (a == 100 and b >= 64 and b <= 127) return true;
    if (a == 198 and (b == 18 or b == 19)) return true;
    if (a >= 224) return true;
    return false;
}

fn ipv6Blocked(bytes: [16]u8) bool {
    var zeros: usize = 0;
    for (bytes[0..15]) |c| {
        if (c == 0) zeros += 1;
    }
    if (zeros == 15 and (bytes[15] == 0 or bytes[15] == 1)) return true;
    if (bytes[0] == 0xfe and (bytes[1] & 0xc0) == 0x80) return true;
    if (bytes[0] & 0xfe == 0xfc) return true;
    if (std.mem.eql(u8, bytes[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
        return ipv4Blocked(std.mem.readInt(u32, bytes[12..16], .big));
    }
    return false;
}

fn hostNameBlocked(host: []const u8) bool {
    var buf: [256]u8 = undefined;
    if (host.len == 0 or host.len >= buf.len) return true;
    const lower = std.ascii.lowerString(&buf, host);
    const names = [_][]const u8{
        "localhost",                "localhost.localdomain",
        "ip6-localhost",            "ip6-loopback",
        "metadata.google.internal", "metadata.internal",
        "host.docker.internal",     "gateway.docker.internal",
        "kubernetes.default",       "kubernetes.default.svc",
    };
    for (names) |n| {
        if (std.mem.eql(u8, lower, n)) return true;
    }
    if (std.mem.endsWith(u8, lower, ".localhost")) return true;
    if (std.mem.endsWith(u8, lower, ".local")) return true;
    if (std.mem.endsWith(u8, lower, ".internal")) return true;
    return false;
}

fn hostBlocked(host: []const u8) bool {
    if (hostNameBlocked(host)) return true;
    if (parseIpv4Loose(host)) |ip| return ipv4Blocked(ip);
    if (std.Io.net.IpAddress.parseIp6(host, 0)) |addr| {
        return ipv6Blocked(addr.ip6.bytes);
    } else |_| {}
    return false;
}

fn resolveBlocked(alloc: std.mem.Allocator, host: []const u8) bool {
    if (hostBlocked(host)) return true;
    const out = util.execShortTimeout(alloc, &.{ "getent", "ahosts", host }, 3) catch return false;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const cut = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        const ip = std.mem.trim(u8, line[0..cut], " \t");
        if (ip.len == 0) continue;
        if (hostBlocked(ip)) return true;
    }
    return false;
}

fn urlBlocked(alloc: std.mem.Allocator, url: []const u8) bool {
    const host = urlHost(url) orelse return true;
    return resolveBlocked(alloc, host);
}

pub fn toolFetchUrl(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = ctx;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{});
    const url = jsonx.jsonStr(v, "url") orelse return .{ .content = "error: fetch_url requires 'url'", .is_error = true };
    // 只允许 http(s):否则 `file://` 能读本地任意文件,`gopher://` 之类能拿 curl 当跳板
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return .{ .content = "error: fetch_url only accepts http:// or https:// URLs", .is_error = true };
    }
    if (urlBlocked(arena, url)) {
        return .{ .content = "error: fetch_url blocked private or local address", .is_error = true };
    }
    const act = activity.begin(.tool, "fetch_url", url, 30_000);
    defer act.release();

    const raw = agentmod.util.execShortTimeout(arena, &.{
        "curl",    "-sSL",                                      "--max-time",    "25",          "--max-filesize", "8000000",
        "--proto", "=https,http",                               "--proto-redir", "=https,http", "--max-redirs",   "3",
        "-H",      "user-agent: Mozilla/5.0 (compatible; piz)", url,
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

test "webStatus mentions usage" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const line = try webStatus(arena.allocator());
    try t.expect(std.mem.indexOf(u8, line, "usage: /web") != null);
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

test "fetch_url blocks private and local addresses" {
    const t = std.testing;
    try t.expectEqualStrings("127.0.0.1", urlHost("http://evil.com@127.0.0.1/x").?);
    try t.expectEqualStrings("::1", urlHost("https://[::1]:8080/").?);
    try t.expectEqualStrings("example.com", urlHost("https://example.com./path").?);
    try t.expect(hostBlocked("127.0.0.1"));
    try t.expect(hostBlocked("localhost"));
    try t.expect(hostBlocked("169.254.169.254"));
    try t.expect(hostBlocked("10.1.2.3"));
    try t.expect(hostBlocked("192.168.0.1"));
    try t.expect(hostBlocked("172.16.0.1"));
    try t.expect(hostBlocked("::1"));
    try t.expect(hostBlocked("metadata.google.internal"));
    try t.expect(hostBlocked("foo.localhost"));
    try t.expect(!hostBlocked("ziglang.org"));
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blocked = try toolFetchUrl(null, a, "{\"url\":\"http://127.0.0.1:5494/api/chat\"}");
    try t.expect(blocked.is_error);
    try t.expect(std.mem.indexOf(u8, blocked.content, "blocked") != null);
}
