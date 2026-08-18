// oauth.zig — browser OAuth used by `piz web` Settings → Account.
// OpenRouter PKCE (permanent API key). xAI + ChatGPT Codex device-code.
const std = @import("std");
const util = @import("util.zig");
const httpc = @import("httpc.zig");

pub const OPENROUTER_AUTH = "https://openrouter.ai/auth";
pub const OPENROUTER_TOKEN = "https://openrouter.ai/api/v1/auth/keys";

pub const XAI_CLIENT_ID = "b1a00492-073a-47ea-816f-4c329264a828";
pub const XAI_SCOPE = "openid profile email offline_access grok-cli:access api:access";
pub const XAI_DEVICE = "https://auth.x.ai/oauth2/device/code";
pub const XAI_TOKEN = "https://auth.x.ai/oauth2/token";

pub const CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const CODEX_DEVICE_USER = "https://auth.openai.com/api/accounts/deviceauth/usercode";
pub const CODEX_DEVICE_TOKEN = "https://auth.openai.com/api/accounts/deviceauth/token";
pub const CODEX_TOKEN = "https://auth.openai.com/oauth/token";
pub const CODEX_DEVICE_REDIRECT = "https://auth.openai.com/deviceauth/callback";
pub const CODEX_VERIFY = "https://auth.openai.com/codex/device";

pub const Pkce = struct {
    verifier: [43]u8,
    challenge: [43]u8,
};

pub fn generatePkce() Pkce {
    var raw: [32]u8 = undefined;
    util.io.random(&raw);
    var out: Pkce = undefined;
    const enc = std.base64.url_safe_no_pad.Encoder;
    _ = enc.encode(&out.verifier, &raw);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&out.verifier, &hash, .{});
    _ = enc.encode(&out.challenge, &hash);
    return out;
}

pub fn randomState(buf: []u8) []const u8 {
    var raw: [16]u8 = undefined;
    util.io.random(&raw);
    const enc = std.base64.url_safe_no_pad.Encoder;
    const n = enc.encode(buf, &raw).len;
    return buf[0..n];
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
}

pub fn queryEscape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        if (isUnreserved(c)) {
            try out.append(c);
        } else {
            try out.append('%');
            try out.append(hex[c >> 4]);
            try out.append(hex[c & 15]);
        }
    }
    return out.toOwnedSlice();
}

pub fn openrouterAuthUrl(alloc: std.mem.Allocator, callback: []const u8, challenge: []const u8) ![]u8 {
    const cb = try queryEscape(alloc, callback);
    defer alloc.free(cb);
    return std.fmt.allocPrint(alloc, "{s}?callback_url={s}&code_challenge={s}&code_challenge_method=S256", .{
        OPENROUTER_AUTH,
        cb,
        challenge,
    });
}

pub fn parseOpenrouterKey(body: []const u8) ?[]const u8 {
    return jsonStrField(body, "key");
}

/// POST code+verifier to OpenRouter; returns allocated API key.
pub fn exchangeOpenrouter(alloc: std.mem.Allocator, code: []const u8, verifier: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(alloc, "{{\"code\":{s},\"code_verifier\":{s},\"code_challenge_method\":\"S256\"}}", .{
        util.jsonString(alloc, code) catch return error.BadJson,
        util.jsonString(alloc, verifier) catch return error.BadJson,
    });
    const raw = try postRaw(alloc, OPENROUTER_TOKEN, "application/json", body);
    const key = parseOpenrouterKey(raw) orelse return error.OauthExchange;
    return alloc.dupe(u8, key);
}

pub fn jsonStrField(body: []const u8, key: []const u8) ?[]const u8 {
    var mark_buf: [80]u8 = undefined;
    const mark = std.fmt.bufPrint(&mark_buf, "\"{s}\":\"", .{key}) catch return null;
    const i = std.mem.indexOf(u8, body, mark) orelse return null;
    const start = i + mark.len;
    const end = std.mem.indexOfScalar(u8, body[start..], '"') orelse return null;
    if (end == 0) return null;
    return body[start .. start + end];
}

fn postRaw(alloc: std.mem.Allocator, url: []const u8, content_type: []const u8, body: []const u8) ![]u8 {
    var stream = try httpc.Stream.init(alloc, url, &.{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "accept", .value = "application/json" },
    }, body);
    defer stream.deinit();
    return stream.readAll(64 * 1024);
}

pub const DeviceStart = struct {
    user_code: []const u8,
    verify_url: []const u8,
    device: []const u8,
};

pub fn xaiStart(alloc: std.mem.Allocator) !DeviceStart {
    const scope = try queryEscape(alloc, XAI_SCOPE);
    defer alloc.free(scope);
    const body = try std.fmt.allocPrint(alloc, "client_id={s}&scope={s}&referrer=pi", .{ XAI_CLIENT_ID, scope });
    const raw = try postRaw(alloc, XAI_DEVICE, "application/x-www-form-urlencoded", body);
    const user_code = jsonStrField(raw, "user_code") orelse return error.OauthDevice;
    const device = jsonStrField(raw, "device_code") orelse return error.OauthDevice;
    const uri = jsonStrField(raw, "verification_uri_complete") orelse jsonStrField(raw, "verification_uri") orelse return error.OauthDevice;
    if (!std.mem.startsWith(u8, uri, "https://")) return error.OauthDevice;
    return .{ .user_code = user_code, .verify_url = uri, .device = device };
}

pub const Poll = enum { pending, denied, expired, done };

pub const PollResult = struct {
    status: Poll,
    access: ?[]const u8,
};

pub fn xaiPoll(alloc: std.mem.Allocator, device: []const u8) !PollResult {
    const dev = try queryEscape(alloc, device);
    const body = try std.fmt.allocPrint(alloc, "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&client_id={s}&device_code={s}", .{ XAI_CLIENT_ID, dev });
    const raw = try postRaw(alloc, XAI_TOKEN, "application/x-www-form-urlencoded", body);
    if (jsonStrField(raw, "access_token")) |tok| return .{ .status = .done, .access = tok };
    const err = jsonStrField(raw, "error") orelse return .{ .status = .denied, .access = null };
    if (std.mem.eql(u8, err, "authorization_pending") or std.mem.eql(u8, err, "slow_down")) return .{ .status = .pending, .access = null };
    if (std.mem.eql(u8, err, "expired_token")) return .{ .status = .expired, .access = null };
    return .{ .status = .denied, .access = null };
}

pub fn codexStart(alloc: std.mem.Allocator) !DeviceStart {
    const raw = try postRaw(alloc, CODEX_DEVICE_USER, "application/json", "{}");
    const user_code = jsonStrField(raw, "user_code") orelse return error.OauthDevice;
    const device = jsonStrField(raw, "device_auth_id") orelse return error.OauthDevice;
    return .{ .user_code = user_code, .verify_url = CODEX_VERIFY, .device = device };
}

pub fn codexPoll(alloc: std.mem.Allocator, device: []const u8) !PollResult {
    const id_j = util.jsonString(alloc, device) catch return error.BadJson;
    var aw = std.Io.Writer.Allocating.init(alloc);
    aw.writer.writeAll("{\"device_auth_id\":") catch return error.BadJson;
    aw.writer.writeAll(id_j) catch return error.BadJson;
    aw.writer.writeAll("}") catch return error.BadJson;
    const req = aw.toOwnedSlice() catch return error.BadJson;
    const raw = try postRaw(alloc, CODEX_DEVICE_TOKEN, "application/json", req);
    if (jsonStrField(raw, "error")) |err| {
        if (std.mem.indexOf(u8, err, "pending") != null) return .{ .status = .pending, .access = null };
        return .{ .status = .denied, .access = null };
    }
    const code = jsonStrField(raw, "authorization_code") orelse return .{ .status = .pending, .access = null };
    const verifier = jsonStrField(raw, "code_verifier") orelse return .{ .status = .denied, .access = null };
    const form = try std.fmt.allocPrint(alloc, "grant_type=authorization_code&client_id={s}&code={s}&code_verifier={s}&redirect_uri={s}", .{
        CODEX_CLIENT_ID,
        try queryEscape(alloc, code),
        try queryEscape(alloc, verifier),
        try queryEscape(alloc, CODEX_DEVICE_REDIRECT),
    });
    const tok = try postRaw(alloc, CODEX_TOKEN, "application/x-www-form-urlencoded", form);
    const access = jsonStrField(tok, "access_token") orelse return .{ .status = .denied, .access = null };
    return .{ .status = .done, .access = access };
}

test "pkce verifier and challenge are base64url" {
    const t = std.testing;
    try util.testInit();
    const p = generatePkce();
    try t.expectEqual(@as(usize, 43), p.verifier.len);
    try t.expectEqual(@as(usize, 43), p.challenge.len);
    for (p.verifier) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
        try t.expect(ok);
    }
}

test "openrouter auth url carries callback and challenge" {
    const t = std.testing;
    const url = try openrouterAuthUrl(t.allocator, "http://127.0.0.1:5494/api/oauth/callback", "abc");
    defer t.allocator.free(url);
    try t.expect(std.mem.indexOf(u8, url, "openrouter.ai/auth") != null);
    try t.expect(std.mem.indexOf(u8, url, "callback_url=") != null);
    try t.expect(std.mem.indexOf(u8, url, "code_challenge=abc") != null);
    try t.expect(std.mem.indexOf(u8, url, "S256") != null);
}

test "jsonStrField extracts quoted values" {
    const t = std.testing;
    try t.expectEqualStrings("abc", jsonStrField("{\"user_code\":\"abc\"}", "user_code").?);
    try t.expect(jsonStrField("{}", "user_code") == null);
}

test "parseOpenrouterKey reads key field" {
    const t = std.testing;
    const k = parseOpenrouterKey("{\"key\":\"sk-or-v1-x\"}").?;
    try t.expectEqualStrings("sk-or-v1-x", k);
    try t.expect(parseOpenrouterKey("{\"error\":\"nope\"}") == null);
}
