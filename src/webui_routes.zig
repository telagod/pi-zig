// webui_routes.zig — HTTP 路由体。从 webui.zig 拆出:serve() 只留
// guards(静态豁免/Bearer/CSRF/ws 校验)+ 按序分发,响应字节不变。
// 路由顺序即原 if-链顺序:先匹配先赢(assets 先于 plugins;mode 排除 model 前缀)。
const std = @import("std");
const util = @import("core").util;
const oauth = @import("core").oauth;
const activity = @import("core").activity;
const pkgsmod = @import("core").pkgs;
const webplugins = @import("core").webplugins;
const sessionmod = @import("core").session;
const webui = @import("webui.zig");
const cmd_help = @import("cmd_help.zig");
const http = std.http;

const WebServer = webui.WebServer;
pub const OauthKind = webui.OauthKind;
pub const OauthPend = webui.OauthPend;

const filesmod = @import("core").tools_files;
pub const FileItem = filesmod.FileItem;
pub const listWorkspaceFiles = filesmod.listWorkspaceFiles;
pub const normalizeRel = filesmod.normalizeRel;

/// 按 `&` 切分取查询参数原始值。
///
/// 不能用 `indexOf(rest, "ws=")` —— 那会把 `?foo=1&notws=/etc` 里的 `notws=`
/// 当成 `ws=`。参数名必须是完整的一段,否则任何以目标名结尾的参数都能顶替它,
/// 白名单校验也就跟着被绕过。
pub fn queryParam(target: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

pub fn queryUsize(target: []const u8, key: []const u8, fallback: usize) usize {
    const raw = queryParam(target, key) orelse return fallback;
    return std.fmt.parseInt(usize, raw, 10) catch fallback;
}

/// 从 target 提取 ?session= 参数(无则 "default")。
pub fn querySession(alloc: std.mem.Allocator, target: []const u8) ![]const u8 {
    if (queryParam(target, "session")) |name| {
        if (name.len > 0 and name.len <= 64) return alloc.dupe(u8, name);
    }
    return alloc.dupe(u8, "default");
}

/// 从 target 提取 ?ws= 参数(项目根,percent 解码;无则 "" = 用默认)。
pub fn queryWs(alloc: std.mem.Allocator, target: []const u8) ![]const u8 {
    if (queryParam(target, "ws")) |name| {
        if (name.len > 0 and name.len <= 512) return util.percentDecode(alloc, name) catch alloc.dupe(u8, name) catch "";
    }
    return "";
}

/// 构造 `{"ok":true,"<key>":"<value>"}`,长度不受限。分配失败返回 null。
///
/// 原先两处用 `[512]u8` 栈缓冲 + `try bufPrint`:模型名或标题一长就
/// `error.NoSpaceLeft`,错误冒出 handler,**连响应头都没写出去**,客户端
/// 只看到连接断开 —— 而写操作在这之前已经生效,读路径也走同一段代码,
/// 于是这个端点在进程余生里每次都断连。
pub fn okJson(alloc: std.mem.Allocator, key: []const u8, value: []const u8) ?[]u8 {
    var w = std.Io.Writer.Allocating.init(alloc);
    defer w.deinit();
    const vj: ?[]u8 = util.jsonString(alloc, value) catch null;
    defer if (vj) |j| alloc.free(j);
    w.writer.print("{{\"ok\":true,\"{s}\":{s}}}", .{ key, vj orelse "\"\"" }) catch return null;
    return w.toOwnedSlice() catch null;
}

pub fn fileJson(alloc: std.mem.Allocator, root: []const u8, raw: []const u8) ?[]u8 {
    if (raw.len == 0 or raw.len > 1024) return null;
    const rel = blk: {
        if (std.fs.path.isAbsolute(raw)) {
            if (!std.mem.startsWith(u8, raw, root)) return null;
            var rest = raw[root.len..];
            if (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) rest = rest[1..];
            const n = normalizeRel(alloc, rest) catch return null;
            break :blk n.rel;
        }
        const n = normalizeRel(alloc, raw) catch return null;
        break :blk n.rel;
    };
    if (rel.len == 0) return null;
    const abs = util.joinPath(alloc, root, rel) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(util.io, abs, alloc, .limited(256 * 1024)) catch return null;
    const path_j = util.jsonString(alloc, rel) catch return null;
    const text_j = util.jsonString(alloc, data) catch return null;
    return std.fmt.allocPrint(alloc, "{{\"ok\":true,\"path\":{s},\"text\":{s}}}", .{ path_j, text_j }) catch null;
}

pub fn filesJson(alloc: std.mem.Allocator, root: []const u8, q: []const u8) ?[]u8 {
    const items = listWorkspaceFiles(alloc, root, q) catch return null;
    var stw = std.Io.Writer.Allocating.init(alloc);
    const w = &stw.writer;
    w.writeAll("{\"ok\":true,\"items\":[") catch return null;
    for (items, 0..) |it, i| {
        if (i > 0) w.writeAll(",") catch return null;
        const name_j = util.jsonString(alloc, it.name) catch return null;
        const path_j = util.jsonString(alloc, it.path) catch return null;
        if (it.link) |tgt| {
            const link_j = util.jsonString(alloc, tgt) catch return null;
            w.print("{{\"name\":{s},\"path\":{s},\"dir\":{s},\"link\":{s}}}", .{
                name_j,
                path_j,
                if (it.dir) "true" else "false",
                link_j,
            }) catch return null;
        } else {
            w.print("{{\"name\":{s},\"path\":{s},\"dir\":{s}}}", .{
                name_j,
                path_j,
                if (it.dir) "true" else "false",
            }) catch return null;
        }
    }
    w.writeAll("]}") catch return null;
    return stw.toOwnedSlice() catch null;
}

pub fn safeArtifactName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

pub fn artifactImage(alloc: std.mem.Allocator, name: []const u8) ?struct { data: []const u8, mime: []const u8 } {
    if (!safeArtifactName(name)) return null;
    if (!std.mem.startsWith(u8, name, "img-")) return null;
    const cfg = util.configDir(alloc) catch return null;
    const dir = util.joinPath(alloc, cfg, "artifacts") catch return null;
    const path = util.joinPath(alloc, dir, name) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(8 * 1024 * 1024)) catch return null;
    const mime: []const u8 = if (std.mem.endsWith(u8, name, ".jpg") or std.mem.endsWith(u8, name, ".jpeg"))
        "image/jpeg"
    else if (std.mem.endsWith(u8, name, ".webp"))
        "image/webp"
    else
        "image/png";
    return .{ .data = data, .mime = mime };
}

pub fn artifactJson(alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (!safeArtifactName(name)) return null;
    const cfg = util.configDir(alloc) catch return null;
    const dir = util.joinPath(alloc, cfg, "artifacts") catch return null;
    const path = util.joinPath(alloc, dir, name) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(256 * 1024)) catch return null;
    const text_j = util.jsonString(alloc, util.utf8Prefix(data, data.len)) catch return null;
    return std.fmt.allocPrint(alloc, "{{\"ok\":true,\"name\":{s},\"bytes\":{d},\"text\":{s}}}", .{
        util.jsonString(alloc, name) catch "\"\"",
        data.len,
        text_j,
    }) catch null;
}

pub fn oauthStart(self: *WebServer, body: []const u8) []const u8 {
    const provider = blk: {
        const root = std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{}) catch break :blk "openrouter";
        if (root == .object) {
            if (root.object.get("provider")) |v| {
                if (v == .string) break :blk v.string;
            }
        }
        break :blk "openrouter";
    };
    var kind: OauthKind = .openrouter;
    if (std.mem.eql(u8, provider, "xai")) kind = .xai else if (std.mem.eql(u8, provider, "openai") or std.mem.eql(u8, provider, "codex")) kind = .openai else if (!std.mem.eql(u8, provider, "openrouter")) return "{\"ok\":false,\"error\":\"unsupported\"}";
    var state_buf: [32]u8 = undefined;
    const state = oauth.randomState(&state_buf);
    var pkce: oauth.Pkce = undefined;
    var user_code: []const u8 = "";
    var verify_url: []const u8 = "";
    var device: []const u8 = "";
    if (kind == .openrouter) {
        pkce = oauth.generatePkce();
    } else if (kind == .xai) {
        const d = oauth.xaiStart(self.alloc) catch return "{\"ok\":false,\"error\":\"device\"}";
        user_code = d.user_code;
        verify_url = d.verify_url;
        device = d.device;
    } else {
        const d = oauth.codexStart(self.alloc) catch return "{\"ok\":false,\"error\":\"device\"}";
        user_code = d.user_code;
        verify_url = d.verify_url;
        device = d.device;
    }
    self.oauth_mu.lockUncancelable(util.io);
    defer self.oauth_mu.unlock(util.io);
    var slot: ?*OauthPend = null;
    for (&self.oauth_slots) |*s| {
        if (!s.live or s.done) {
            slot = s;
            break;
        }
    }
    const dest = slot orelse return "{\"ok\":false,\"error\":\"busy\"}";
    dest.* = .{ .live = true, .kind = kind };
    @memcpy(dest.state[0..state.len], state);
    dest.state_n = @intCast(state.len);
    if (kind == .openrouter) dest.verifier = pkce.verifier;
    if (device.len > 0 and device.len <= dest.device.len) {
        @memcpy(dest.device[0..device.len], device);
        dest.device_n = @intCast(device.len);
    }
    const st_j = util.jsonString(self.alloc, state) catch return "{\"ok\":false}";
    if (kind == .openrouter) {
        const cb = std.fmt.allocPrint(self.alloc, "http://127.0.0.1:{d}/api/oauth/callback", .{self.port}) catch return "{\"ok\":false}";
        const url = oauth.openrouterAuthUrl(self.alloc, cb, &pkce.challenge) catch return "{\"ok\":false}";
        const url_j = util.jsonString(self.alloc, url) catch return "{\"ok\":false}";
        return std.fmt.allocPrint(self.alloc, "{{\"ok\":true,\"url\":{s},\"state\":{s}}}", .{ url_j, st_j }) catch "{\"ok\":false}";
    }
    const code_j = util.jsonString(self.alloc, user_code) catch return "{\"ok\":false}";
    const uri_j = util.jsonString(self.alloc, verify_url) catch return "{\"ok\":false}";
    return std.fmt.allocPrint(self.alloc, "{{\"ok\":true,\"state\":{s},\"user_code\":{s},\"verification_uri\":{s}}}", .{ st_j, code_j, uri_j }) catch "{\"ok\":false}";
}

pub fn oauthPoll(self: *WebServer, state: []const u8) []const u8 {
    const st = if (state.len == 0) return "{\"ok\":false}" else (util.percentDecode(self.alloc, state) catch state);
    self.oauth_mu.lockUncancelable(util.io);
    var found: ?*OauthPend = null;
    for (&self.oauth_slots) |*s| {
        if (s.live and s.state_n > 0 and std.mem.eql(u8, s.state[0..s.state_n], st)) {
            found = s;
            break;
        }
    }
    const slot = found orelse {
        self.oauth_mu.unlock(util.io);
        return "{\"ok\":false,\"done\":true,\"error\":true}";
    };
    if (slot.done) {
        const err = slot.err;
        self.oauth_mu.unlock(util.io);
        return if (err) "{\"ok\":false,\"done\":true,\"error\":true}" else "{\"ok\":true,\"done\":true}";
    }
    if (slot.kind == .openrouter) {
        self.oauth_mu.unlock(util.io);
        return "{\"ok\":true,\"done\":false}";
    }
    const kind = slot.kind;
    const device = slot.device[0..slot.device_n];
    const dev_copy = self.alloc.dupe(u8, device) catch {
        self.oauth_mu.unlock(util.io);
        return "{\"ok\":false}";
    };
    self.oauth_mu.unlock(util.io);
    const polled = if (kind == .xai) oauth.xaiPoll(self.alloc, dev_copy) else oauth.codexPoll(self.alloc, dev_copy);
    const result = polled catch return "{\"ok\":true,\"done\":false}";
    if (result.status == .pending) return "{\"ok\":true,\"done\":false}";
    var saved = false;
    if (result.status == .done) {
        if (result.access) |tok| {
            const name: []const u8 = if (kind == .xai) "xai" else "openai";
            if (self.auth_save_hook) |h| saved = h(self.auth_save_ctx, name, tok);
        }
    }
    self.oauth_mu.lockUncancelable(util.io);
    slot.done = true;
    slot.err = !saved;
    self.oauth_mu.unlock(util.io);
    if (saved) return "{\"ok\":true,\"done\":true}";
    return "{\"ok\":false,\"done\":true,\"error\":true}";
}

pub fn oauthCallback(self: *WebServer, target: []const u8) []const u8 {
    const fail = "<html><body><p>Sign-in failed. You can close this tab.</p></body></html>";
    const ok_html = "<html><body><p>Signed in. You can close this tab.</p><script>window.close()</script></body></html>";
    const state = queryParam(target, "state") orelse return fail;
    const code = queryParam(target, "code") orelse return fail;
    const st = util.percentDecode(self.alloc, state) catch state;
    const cd = util.percentDecode(self.alloc, code) catch code;
    self.oauth_mu.lockUncancelable(util.io);
    var found: ?*OauthPend = null;
    for (&self.oauth_slots) |*s| {
        if (s.live and s.state_n > 0 and std.mem.eql(u8, s.state[0..s.state_n], st)) {
            found = s;
            break;
        }
    }
    const slot = found orelse {
        self.oauth_mu.unlock(util.io);
        return fail;
    };
    const verifier = slot.verifier;
    self.oauth_mu.unlock(util.io);
    const key = oauth.exchangeOpenrouter(self.alloc, cd, &verifier) catch {
        self.oauth_mu.lockUncancelable(util.io);
        slot.err = true;
        slot.done = true;
        self.oauth_mu.unlock(util.io);
        return fail;
    };
    var saved = false;
    if (self.auth_save_hook) |h| saved = h(self.auth_save_ctx, "openrouter", key);
    self.oauth_mu.lockUncancelable(util.io);
    slot.done = true;
    slot.err = !saved;
    self.oauth_mu.unlock(util.io);
    return if (saved) ok_html else fail;
}

pub fn oauthStatus(self: *WebServer, state: []const u8) []const u8 {
    const st = if (state.len == 0) return "{\"ok\":false}" else (util.percentDecode(self.alloc, state) catch state);
    self.oauth_mu.lockUncancelable(util.io);
    defer self.oauth_mu.unlock(util.io);
    for (&self.oauth_slots) |*s| {
        if (s.state_n > 0 and std.mem.eql(u8, s.state[0..s.state_n], st)) {
            if (s.err) return "{\"ok\":false,\"done\":true,\"error\":true}";
            if (s.done) return "{\"ok\":true,\"done\":true}";
            return "{\"ok\":true,\"done\":false}";
        }
    }
    return "{\"ok\":false,\"done\":true,\"error\":true}";
}

pub const ChatBody = struct { text: []const u8, image: ?[]const u8 = null, mime: []const u8 = "" };

pub fn decodeB64(alloc: std.mem.Allocator, s: []const u8) ?[]u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(s) catch return null;
    if (n == 0 or n > 6 * 1024 * 1024) return null;
    const out = alloc.alloc(u8, n) catch return null;
    dec.decode(out, s) catch {
        alloc.free(out);
        return null;
    };
    return out;
}

pub fn parseChatBody(alloc: std.mem.Allocator, body: []const u8) ChatBody {
    const empty = ChatBody{ .text = alloc.dupe(u8, "") catch "" };
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{}) catch return empty;
    if (root != .object) return empty;
    var text: []const u8 = "";
    if (root.object.get("text")) |v| {
        if (v == .string) text = alloc.dupe(u8, v.string) catch "";
    }
    var image: ?[]u8 = null;
    var mime: []const u8 = "image/png";
    if (root.object.get("image")) |v| {
        if (v == .string and v.string.len > 0) image = decodeB64(alloc, v.string);
    }
    if (root.object.get("mime")) |v| {
        if (v == .string and v.string.len > 0) mime = v.string;
    }
    return .{ .text = text, .image = image, .mime = mime };
}

pub fn parseChatText(alloc: std.mem.Allocator, body: []const u8) ![]const u8 {
    return parseChatBody(alloc, body).text;
}

// ---- 路由体(顺序 = 原 if-链顺序) ----

pub fn indexHtml(self: *WebServer, req: *http.Server.Request) !void {
    _ = self;
    try req.respond(webui.INDEX_HTML, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            .{ .name = "cache-control", .value = "no-store" },
        },
    });
}

/// /app.css /app.js —— 拆分出的静态件,与 HTML 同策略 no-store(版本随二进制走)。
pub fn staticAsset(self: *WebServer, req: *http.Server.Request, path: []const u8) !void {
    _ = self;
    const is_css = std.mem.endsWith(u8, path, ".css");
    try req.respond(if (is_css) webui.APP_CSS else webui.APP_JS, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = if (is_css) "text/css; charset=utf-8" else "text/javascript; charset=utf-8" },
            .{ .name = "cache-control", .value = "no-store" },
        },
    });
}

pub fn pluginsAssets(self: *WebServer, req: *http.Server.Request, target: []const u8, ws: []const u8) !void {
    const plugin_cwd = if (ws.len > 0) ws else self.opts.project_cwd;
    if (webplugins.readAsset(self.alloc, plugin_cwd, target) catch null) |asset| {
        defer self.alloc.free(asset.data);
        try req.respond(asset.data, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = asset.content_type },
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
            },
        });
        return;
    }
    try req.respond("not found", .{ .status = .not_found });
}

pub fn plugins(self: *WebServer, req: *http.Server.Request, ws: []const u8) !void {
    const plugin_cwd = if (ws.len > 0) ws else self.opts.project_cwd;
    const body = webplugins.manifestJson(self.alloc, plugin_cwd) catch "{\"apiVersion\":1,\"plugins\":[]}";
    defer if (!std.mem.eql(u8, body, "{\"apiVersion\":1,\"plugins\":[]}")) self.alloc.free(body);
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "cache-control", .value = "no-store" },
        },
    });
}

pub fn stateGet(self: *WebServer, req: *http.Server.Request, target: []const u8, ws: []const u8) !void {
    const session = querySession(self.alloc, target) catch "default";
    defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
    const body = if (self.state_hook) |f| f(self.state_ctx, ws, session, self.alloc) else self.stateJson();
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

pub fn history(self: *WebServer, req: *http.Server.Request, target: []const u8, ws: []const u8) !void {
    const session = querySession(self.alloc, target) catch "default";
    defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
    const offset = queryUsize(target, "offset", 0);
    var limit = queryUsize(target, "limit", 80);
    if (limit == 0 or limit > 200) limit = 80;
    const body = if (self.history_hook) |f|
        f(self.history_ctx, ws, session, offset, limit, self.alloc)
    else
        "{\"start\":0,\"total\":0,\"history\":[]}";
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

pub fn sessions(self: *WebServer, req: *http.Server.Request, ws: []const u8) !void {
    const body = if (self.sessions_hook) |f| f(self.sessions_ctx, ws, self.alloc) else "[]";
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

pub fn models(self: *WebServer, req: *http.Server.Request) !void {
    const body = if (self.models_hook) |f| f(self.models_ctx, self.alloc) else "[]";
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

// ---- 自演化采集 sink ----
// 前端错误报告 → ~/.piz/evolve/queue.jsonl(JSONL)。尽力而为:任何失败
// 都静默(采集本身不能成为缺陷)。
pub fn evolveSink(self: *WebServer, req: *http.Server.Request) !void {
    var body_buf: [8192]u8 = undefined;
    const reader = req.readerExpectNone(&body_buf);
    const body = reader.allocRemaining(self.alloc, .limited(8192)) catch "";
    if (std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{})) |root| {
        if (root == .object) {
            const sig = evolveSig(self.alloc, root) catch "";
            const ts = @divTrunc(std.Io.Clock.now(.real, util.io).nanoseconds, std.time.ns_per_s);
            var w = std.Io.Writer.Allocating.init(self.alloc);
            defer w.deinit();
            const wr = &w.writer;
            wr.writeAll("{\"id\":") catch {};
            wr.print("{s}", .{try util.jsonString(self.alloc, sig)}) catch {};
            wr.writeAll(",\"ts\":") catch {};
            wr.print("{d}", .{ts}) catch {};
            if (jsonStr(root, "kind")) |v| {
                wr.writeAll(",\"kind\":") catch {};
                wr.print("{s}", .{try util.jsonString(self.alloc, v)}) catch {};
            }
            if (jsonStr(root, "where")) |v| {
                wr.writeAll(",\"where\":") catch {};
                wr.print("{s}", .{try util.jsonString(self.alloc, v)}) catch {};
            }
            if (jsonStr(root, "msg")) |v| {
                wr.writeAll(",\"msg\":") catch {};
                wr.print("{s}", .{try util.jsonString(self.alloc, v[0..@min(v.len, 1200)])}) catch {};
            }
            if (jsonStr(root, "stack")) |v| {
                wr.writeAll(",\"stack\":") catch {};
                wr.print("{s}", .{try util.jsonString(self.alloc, v[0..@min(v.len, 3000)])}) catch {};
            }
            if (jsonStr(root, "session")) |v| {
                wr.writeAll(",\"session\":") catch {};
                wr.print("{s}", .{try util.jsonString(self.alloc, v)}) catch {};
            }
            wr.writeAll(",\"state\":\"open\",\"attempts\":0}") catch {};
            const line = w.toOwnedSlice() catch "";
            const qp = util.evolveQueuePath(self.alloc) catch "";
            if (line.len > 0 and qp.len > 0) {
                evolveAppend(qp, line) catch {};
            }
            // 双写:errors.jsonl 全生命周期记录(前端错误流也进总账)
            util.errLog(self.alloc, "fe", jsonStr(root, "where") orelse "window", jsonStr(root, "msg") orelse "");
        }
    } else |_| {}
    try req.respond("{\"ok\":true}", .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

/// 同源同信息合并成稳定 id(前缀签名,后续可去重)。
pub fn evolveSig(alloc: std.mem.Allocator, root: std.json.Value) ![]const u8 {
    const where = jsonStr(root, "where") orelse "";
    const msg = jsonStr(root, "msg") orelse "";
    var h = std.hash.Wyhash.init(0x9e3779b97f4a7c15);
    h.update(where);
    h.update(msg[0..@min(msg.len, 200)]);
    return std.fmt.allocPrint(alloc, "e-{x}", .{h.final()});
}

pub fn jsonStr(root: std.json.Value, key: []const u8) ?[]const u8 {
    if (root != .object) return null;
    const v = root.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

pub fn evolveAppend(path: []const u8, line: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse ".";
    if (dir.len > 0 and !std.mem.eql(u8, dir, ".")) {
        std.Io.Dir.cwd().createDirPath(util.io, dir) catch {};
    }
    // 读改写(队列文件小;避开 Io.File 各版本的 seek 差异)
    const old = std.Io.Dir.cwd().readFileAlloc(util.io, path, std.heap.page_allocator, .limited(8 * 1024 * 1024)) catch "";
    var w = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer w.deinit();
    try w.writer.writeAll(old);
    try w.writer.writeAll(line);
    try w.writer.writeByte('\n');
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = path, .data = w.toOwnedSlice() catch line });
}

/// GET /api/evolve/queue:返回全部条目(供 UI/审计)。
pub fn evolveQueue(self: *WebServer, req: *http.Server.Request) !void {
    const qp = util.evolveQueuePath(self.alloc) catch "";
    var body: []const u8 = "[]";
    if (qp.len > 0) {
        if (std.Io.Dir.cwd().readFileAlloc(util.io, qp, self.alloc, .limited(8 * 1024 * 1024))) |data| {
            var w = std.Io.Writer.Allocating.init(self.alloc);
            defer w.deinit();
            const wr = &w.writer;
            wr.writeByte('[') catch {};
            var it = std.mem.splitScalar(u8, data, '\n');
            var first = true;
            while (it.next()) |line| {
                if (line.len == 0) continue;
                if (!first) wr.writeByte(',') catch {};
                first = false;
                wr.writeAll(line) catch {};
            }
            wr.writeByte(']') catch {};
            body = w.toOwnedSlice() catch "[]";
        } else |_| {}
    }
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

pub fn activityPost(self: *WebServer, req: *http.Server.Request) !void {
    var body_buf: [4096]u8 = undefined;
    const reader = req.readerExpectNone(&body_buf);
    const body = reader.allocRemaining(self.alloc, .limited(4096)) catch "";
    const toolsmod = @import("core").tools;
    var killed = false;
    var pid_n: i32 = 0;
    if (std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{})) |root| {
        if (root == .object) {
            if (root.object.get("kill")) |kv| {
                pid_n = switch (kv) {
                    .integer => |i| @intCast(i),
                    .float => |f| @intFromFloat(f),
                    .string => |s| std.fmt.parseInt(i32, s, 10) catch 0,
                    else => 0,
                };
                if (pid_n > 0) killed = toolsmod.killTracked(@intCast(pid_n));
            }
        }
    } else |_| {}
    const out = std.fmt.allocPrint(self.alloc, "{{\"ok\":{s},\"pid\":{d}}}", .{ if (killed) "true" else "false", pid_n }) catch "{\"ok\":false}";
    try req.respond(out, .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

pub fn activityGet(self: *WebServer, req: *http.Server.Request) !void {
    var aw = std.Io.Writer.Allocating.init(self.alloc);
    activity.writeJson(self.alloc, &aw.writer) catch {
        try req.respond("[]", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        return;
    };
    try req.respond(aw.written(), .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

pub fn usage(self: *WebServer, req: *http.Server.Request) !void {
    const uselog = @import("core").usage_log;
    const sum = uselog.summarize(self.alloc, 8) catch uselog.Summary{};
    const body = std.fmt.allocPrint(self.alloc, "{{\"lines\":{d},\"in\":{d},\"out\":{d},\"usd\":{d:.8},\"tail\":{s}}}", .{
        sum.lines,
        sum.tok_in,
        sum.tok_out,
        sum.usd,
        util.jsonString(self.alloc, sum.tail) catch "\"\"",
    }) catch "{\"lines\":0,\"in\":0,\"out\":0,\"usd\":0,\"tail\":\"\"}";
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

pub fn help(self: *WebServer, req: *http.Server.Request, target: []const u8, ws: []const u8) !void {
    const session = querySession(self.alloc, target) catch "default";
    defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
    var extra_buf: [32]cmd_help.HelpItem = undefined;
    const extra_n = if (self.slash_catalog_hook) |f| f(self.slash_ctx, ws, session, extra_buf[0..]) else 0;
    var aw = std.Io.Writer.Allocating.init(self.alloc);
    cmd_help.writeCatalogJsonExtra(self.alloc, &aw.writer, extra_buf[0..extra_n]) catch {
        try req.respond("{\"commands\":[]}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        return;
    };
    try req.respond(aw.written(), .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

pub fn slash(self: *WebServer, req: *http.Server.Request, target: []const u8, ws: []const u8) !void {
    const session = querySession(self.alloc, target) catch "default";
    defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
    var body_buf: [1024]u8 = undefined;
    const reader = req.readerExpectNone(&body_buf);
    const body = reader.allocRemaining(self.alloc, .limited(4096)) catch "";
    defer if (body.len > 0) self.alloc.free(body);
    const root = std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{}) catch {
        try req.respond("{\"ok\":false,\"error\":\"bad json\"}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        return;
    };
    const name = if (root == .object) (if (root.object.get("name")) |v| (if (v == .string) v.string else "") else "") else "";
    const args = if (root == .object) (if (root.object.get("args")) |v| (if (v == .string) v.string else "") else "") else "";
    if (name.len == 0 or self.slash_hook == null) {
        try req.respond("{\"ok\":false,\"error\":\"unknown command\"}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        return;
    }
    var aw = std.Io.Writer.Allocating.init(self.alloc);
    if (!self.slash_hook.?(self.slash_ctx, ws, session, name, args, &aw.writer)) {
        try req.respond("{\"ok\":false,\"error\":\"unknown command\"}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        return;
    }
    const text_js = util.jsonString(self.alloc, aw.written()) catch "\"\"";
    const resp = std.fmt.allocPrint(self.alloc, "{{\"ok\":true,\"text\":{s}}}", .{text_js}) catch "{\"ok\":true,\"text\":\"\"}";
    try req.respond(resp, .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

pub fn packages(self: *WebServer, req: *http.Server.Request, ws: []const u8) !void {
    const cwd = if (ws.len > 0) ws else self.opts.project_cwd;
    var aw = std.Io.Writer.Allocating.init(self.alloc);
    pkgsmod.writeListJson(self.alloc, &aw.writer, cwd) catch {
        try req.respond("{\"user\":[],\"project\":[]}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        return;
    };
    try req.respond(aw.written(), .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

pub fn configGet(self: *WebServer, req: *http.Server.Request) !void {
    const body = if (self.config_hook) |f| (f(self.config_ctx, self.alloc, null) orelse "{}") else "{}";
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

pub fn configPost(self: *WebServer, req: *http.Server.Request) !void {
    var body_buf: [16 * 1024]u8 = undefined;
    const reader = req.readerExpectNone(&body_buf);
    const body = reader.allocRemaining(self.alloc, .limited(64 * 1024)) catch "";
    defer if (body.len > 0) self.alloc.free(body);
    if (self.config_hook) |f| {
        const out = f(self.config_ctx, self.alloc, if (body.len > 0) body else null) orelse {
            try req.respond("{\"ok\":false}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
            return;
        };
        try req.respond(out, .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        return;
    }
    try req.respond("{\"ok\":true}", .{ .status = .ok });
}

pub fn chatPost(self: *WebServer, req: *http.Server.Request, target: []const u8, ws: []const u8) !void {
    const session = querySession(self.alloc, target) catch "default";
    defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
    var body_buf: [16 * 1024]u8 = undefined;
    const reader = req.readerExpectNone(&body_buf);
    const body = reader.allocRemaining(self.alloc, .limited(4 * 1024 * 1024)) catch "";
    defer if (body.len > 0) self.alloc.free(body);
    const chat = parseChatBody(self.alloc, body);
    defer if (chat.text.len > 0) self.alloc.free(chat.text);
    defer if (chat.image) |img| self.alloc.free(img);
    if ((chat.text.len > 0 or chat.image != null) and !self.stopping.load(.acquire)) {
        if (self.chat_hook) |f| {
            if (!f(self.chat_ctx, ws, session, chat.text, chat.image, chat.mime)) {
                try req.respond("{\"ok\":false,\"error\":\"rejected\"}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                return;
            }
        } else {
            self.hub.push("{{\"type\":\"user_message\",\"text\":{s},\"has_image\":{s}}}", .{ try util.jsonString(self.alloc, chat.text), if (chat.image != null) "true" else "false" });
            if (!webui.ChatQueue.enqueueEx(session, chat.text, chat.image, chat.mime)) {
                try req.respond("{\"ok\":false,\"error\":\"queue failed\"}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
                return;
            }
        }
    }
    try req.respond("{\"ok\":true}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

pub fn interrupt(self: *WebServer, req: *http.Server.Request, target: []const u8, ws: []const u8) !void {
    const session = querySession(self.alloc, target) catch "default";
    defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
    if (self.interrupt_hook) |f| f(self.interrupt_ctx, ws, session);
    // 手动响应:0.16 respond 对无 body 的 POST 断言(transfer_encoding/content_length)
    try req.server.out.writeAll("HTTP/1.1 200 OK\r\ncontent-length: 7\r\nconnection: close\r\n\r\n{\"ok\":true}");
    try req.server.out.flush();
}

pub fn approve(self: *WebServer, req: *http.Server.Request) !void {
    var body_buf: [1024]u8 = undefined;
    const reader = req.readerExpectNone(&body_buf);
    const body = reader.allocRemaining(self.alloc, .limited(4096)) catch "";
    defer if (body.len > 0) self.alloc.free(body);
    const root = std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{}) catch return;
    var id: u32 = 0;
    var allow = false;
    if (root == .object) {
        if (root.object.get("id")) |v| {
            if (v == .integer) id = @intCast(v.integer);
        }
        if (root.object.get("allow")) |v| {
            if (v == .bool) allow = v.bool;
        }
    }
    if (id != 0 and webui.PermGate.resolve(id, allow)) {
        self.hub.push("{{\"type\":\"permission_result\",\"id\":{d},\"allow\":{s}}}", .{ id, if (allow) "true" else "false" });
        try req.respond("{\"ok\":true}", .{ .status = .ok });
        return;
    }
    try req.respond("{\"ok\":false,\"error\":\"unknown or already resolved\"}", .{ .status = .ok });
}

pub fn modePost(self: *WebServer, req: *http.Server.Request, target: []const u8, ws: []const u8) !void {
    const session = querySession(self.alloc, target) catch "default";
    defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
    var mode: ?[]const u8 = null;
    var body_buf: [256]u8 = undefined;
    const reader = req.readerExpectNone(&body_buf);
    const body = reader.allocRemaining(self.alloc, .limited(1024)) catch "";
    defer if (body.len > 0) self.alloc.free(body);
    if (body.len > 0) {
        const root = std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{}) catch null;
        if (root) |r| {
            if (r == .object) {
                if (r.object.get("mode")) |v| {
                    if (v == .string) mode = v.string;
                } else if (r.object.get("auto")) |v| {
                    if (v == .bool) mode = if (v.bool) "yolo" else "ask";
                }
            }
        }
    }
    if (self.mode_hook) |f| {
        const cur = f(self.mode_ctx, ws, session, mode) orelse {
            try req.respond("{\"ok\":false}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
            return;
        };
        const s = if (std.mem.eql(u8, cur, "yolo"))
            "{\"ok\":true,\"auto\":true,\"mode\":\"yolo\"}"
        else if (std.mem.eql(u8, cur, "ask"))
            "{\"ok\":true,\"auto\":false,\"mode\":\"ask\"}"
        else
            "{\"ok\":true,\"auto\":false,\"mode\":\"read-only\"}";
        try req.respond(s, .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        return;
    }
    try req.respond("{\"ok\":true}", .{ .status = .ok });
}

pub fn modelPost(self: *WebServer, req: *http.Server.Request, target: []const u8, ws: []const u8) !void {
    const session = querySession(self.alloc, target) catch "default";
    defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
    var model: ?[]const u8 = null;
    var body_buf: [256]u8 = undefined;
    const reader = req.readerExpectNone(&body_buf);
    const body = reader.allocRemaining(self.alloc, .limited(1024)) catch "";
    defer if (body.len > 0) self.alloc.free(body);
    if (body.len > 0) {
        const root = std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{}) catch null;
        if (root) |r| {
            if (r == .object) {
                if (r.object.get("model")) |v| {
                    if (v == .string) model = v.string;
                }
            }
        }
    }
    if (self.model_hook) |f| {
        const cur = f(self.model_ctx, ws, session, model) orelse {
            try req.respond("{\"ok\":false}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
            return;
        };
        const resp = okJson(self.alloc, "model", cur);
        defer if (resp) |j| self.alloc.free(j);
        try req.respond(resp orelse "{\"ok\":true}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        return;
    }
    try req.respond("{\"ok\":true}", .{ .status = .ok });
}

pub fn titlePost(self: *WebServer, req: *http.Server.Request, target: []const u8, ws: []const u8) !void {
    const session = querySession(self.alloc, target) catch "default";
    defer if (!std.mem.eql(u8, session, "default")) self.alloc.free(session);
    var title: ?[]const u8 = null;
    var body_buf: [256]u8 = undefined;
    const reader = req.readerExpectNone(&body_buf);
    const body = reader.allocRemaining(self.alloc, .limited(1024)) catch "";
    defer if (body.len > 0) self.alloc.free(body);
    if (body.len > 0) {
        const root = std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{}) catch null;
        if (root) |r| {
            if (r == .object) {
                if (r.object.get("title")) |v| {
                    // 在最外层入口就裁:hook 之后标题会进内存、落盘,
                    // 再往下每一步都不该见到无界值。
                    if (v == .string) title = util.clampUtf8(v.string, sessionmod.MAX_TITLE_BYTES);
                }
            }
        }
    }
    if (self.title_hook) |f| {
        const cur = f(self.title_ctx, ws, session, title) orelse {
            try req.respond("{\"ok\":false}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
            return;
        };
        // 入口已裁过标题,但读路径拿的是磁盘上的旧值 —— 那可能是限长
        // 之前写进去的,所以响应侧也必须不设长度上限。
        const resp = okJson(self.alloc, "title", cur);
        defer if (resp) |j| self.alloc.free(j);
        try req.respond(resp orelse "{\"ok\":true}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        return;
    }
    try req.respond("{\"ok\":true}", .{ .status = .ok });
}

pub fn action(self: *WebServer, req: *http.Server.Request, target: []const u8) !void {
    const aws = queryWs(self.alloc, target) catch "";
    defer if (aws.len > 0) self.alloc.free(aws);
    const session = querySession(self.alloc, target) catch "";
    if (session.len == 0) {
        try req.respond("{\"ok\":false}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        return;
    }
    var body_buf: [16 * 1024]u8 = undefined;
    const reader = req.readerExpectNone(&body_buf);
    const body = reader.allocRemaining(self.alloc, .limited(64 * 1024)) catch "";
    defer if (body.len > 0) self.alloc.free(body);
    var act: []const u8 = "";
    var name: ?[]const u8 = null;
    var count: usize = 0;
    if (std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{})) |root| {
        if (root == .object) {
            if (root.object.get("act")) |v| {
                if (v == .string) act = v.string;
            }
            if (root.object.get("name")) |v| {
                if (v == .string) name = v.string;
            }
            if (root.object.get("count")) |v| {
                if (v == .integer and v.integer > 0) count = @intCast(v.integer);
            }
        }
    } else |_| {}
    if (self.action_hook) |f| {
        const out = f(self.action_ctx, aws, session, act, name, count) orelse {
            try req.respond("{\"ok\":false}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
            return;
        };
        try req.respond(out, .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        return;
    }
    try req.respond("{\"ok\":false}", .{ .status = .ok });
}

pub fn workspacesGet(self: *WebServer, req: *http.Server.Request) !void {
    const body = if (self.workspaces_hook) |f| (f(self.workspaces_ctx, self.alloc, null) orelse "[]") else "[]";
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

pub fn workspacesPost(self: *WebServer, req: *http.Server.Request) !void {
    var body_buf: [16 * 1024]u8 = undefined;
    const reader = req.readerExpectNone(&body_buf);
    const body = reader.allocRemaining(self.alloc, .limited(64 * 1024)) catch "";
    defer if (body.len > 0) self.alloc.free(body);
    if (self.workspaces_hook) |f| {
        const out = f(self.workspaces_ctx, self.alloc, if (body.len > 0) body else null) orelse {
            try req.respond("{\"ok\":false}", .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
            return;
        };
        try req.respond(out, .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        return;
    }
    try req.respond("{\"ok\":true}", .{ .status = .ok });
}

pub fn oauthStartRoute(self: *WebServer, req: *http.Server.Request) !void {
    var body_buf: [4096]u8 = undefined;
    const reader = req.readerExpectNone(&body_buf);
    const body = reader.allocRemaining(self.alloc, .limited(4096)) catch "";
    const out = oauthStart(self, body);
    try req.respond(out, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

pub fn oauthCallbackRoute(self: *WebServer, req: *http.Server.Request, target: []const u8) !void {
    const html = oauthCallback(self, target);
    try req.respond(html, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
    });
}

pub fn oauthPollRoute(self: *WebServer, req: *http.Server.Request, target: []const u8) !void {
    const st = queryParam(target, "state") orelse "";
    const out = oauthPoll(self, st);
    try req.respond(out, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

pub fn oauthStatusRoute(self: *WebServer, req: *http.Server.Request, target: []const u8) !void {
    const st = queryParam(target, "state") orelse "";
    const out = oauthStatus(self, st);
    try req.respond(out, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

pub fn imageGet(self: *WebServer, req: *http.Server.Request, target: []const u8) !void {
    const raw = queryParam(target, "name") orelse "";
    const name = if (raw.len == 0) "" else (util.percentDecode(self.alloc, raw) catch raw);
    if (artifactImage(self.alloc, name)) |img| {
        try req.respond(img.data, .{
            .status = .ok,
            .extra_headers = &.{ .{ .name = "content-type", .value = img.mime }, .{ .name = "cache-control", .value = "private, max-age=86400" } },
        });
    } else {
        try req.respond("{\"ok\":false}", .{ .status = .not_found, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    }
}

pub fn artifact(self: *WebServer, req: *http.Server.Request, target: []const u8) !void {
    const raw = queryParam(target, "name") orelse "";
    const name = if (raw.len == 0) "" else (util.percentDecode(self.alloc, raw) catch raw);
    const body = artifactJson(self.alloc, name) orelse "{\"ok\":false,\"error\":\"not found\"}";
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

pub fn files(self: *WebServer, req: *http.Server.Request, target: []const u8, ws: []const u8) !void {
    const q_raw = queryParam(target, "q") orelse "";
    const q = if (q_raw.len == 0) "" else (util.percentDecode(self.alloc, q_raw) catch q_raw);
    const root = if (ws.len > 0) ws else ".";
    const body = filesJson(self.alloc, root, q) orelse "{\"ok\":false,\"error\":\"bad path\"}";
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

pub fn file(self: *WebServer, req: *http.Server.Request, target: []const u8, ws: []const u8) !void {
    const p_raw = queryParam(target, "path") orelse "";
    const pth = if (p_raw.len == 0) "" else (util.percentDecode(self.alloc, p_raw) catch p_raw);
    const root = if (ws.len > 0) ws else ".";
    const body = fileJson(self.alloc, root, pth) orelse "{\"ok\":false,\"error\":\"bad path\"}";
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}
