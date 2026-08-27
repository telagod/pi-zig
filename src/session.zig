// session.zig — JSONL 会话持久化:<配置目录>/sessions/<cwd-slug>/<ts>.jsonl。
// 首行元信息 {cwd, started};后续每行一条消息。
const std = @import("std");
const util = @import("util.zig");
const ai = @import("ai.zig");

/// 会话标题字节上限。标题只用于会话列表的一行显示,超出的部分没有用途,
/// 但会一路带进内存、落盘和每个响应。在唯一的持久化入口(setTitle)裁掉,
/// 磁盘上就永远是安全值。
pub const MAX_TITLE_BYTES = 256;

/// 从首条用户消息抽出侧栏标题。空、纯图、纯空白则无。
pub fn deriveTitle(alloc: std.mem.Allocator, text: []const u8) ?[]const u8 {
    var t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return null;
    if (std.mem.eql(u8, t, "(image)") or std.mem.eql(u8, t, "[image]")) return null;
    if (std.mem.indexOfScalar(u8, t, '\n')) |nl| t = std.mem.trim(u8, t[0..nl], " \t\r");
    if (t.len == 0) return null;
    const cap: usize = 64;
    return alloc.dupe(u8, util.clampUtf8(t, cap)) catch null;
}

/// ── web 会话持久化 ──
/// 独立目录 <cfg>/sessions/web/<name>.jsonl;首行 meta {"model","auto"},后续每行一条消息。
/// 文件名校验:仅 [a-zA-Z0-9_-],防路径穿越。
/// name 是否合法(仅字母数字下划线连字符)。
pub fn webNameOk(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn imageExt(mime: ?[]const u8) []const u8 {
    const m = mime orelse "image/png";
    if (std.mem.eql(u8, m, "image/jpeg") or std.mem.eql(u8, m, "image/jpg")) return "jpg";
    if (std.mem.eql(u8, m, "image/webp")) return "webp";
    return "png";
}

pub fn persistImageFile(alloc: std.mem.Allocator, b64: []const u8, mime: ?[]const u8) ?[]const u8 {
    const cfg = util.configDir(alloc) catch return null;
    const dir = util.joinPath(alloc, cfg, "artifacts") catch return null;
    std.Io.Dir.cwd().createDirPath(util.io, dir) catch |err| util.debugCatch("session.img.mkdir", err);
    var h: u64 = 14695981039346656037;
    for (b64) |c| h = (h ^ @as(u64, c)) *% 1099511628211;
    const name = std.fmt.allocPrint(alloc, "img-{x}.{s}", .{ h, imageExt(mime) }) catch return null;
    const path = util.joinPath(alloc, dir, name) catch return null;
    if (std.Io.Dir.cwd().statFile(util.io, path, .{})) |_| return name else |_| {}
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(b64) catch return null;
    if (n == 0 or n > 8 * 1024 * 1024) return null;
    const raw = alloc.alloc(u8, n) catch return null;
    dec.decode(raw, b64) catch return null;
    std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = path, .data = raw }) catch |err| {
        util.debugCatch("session.img.write", err);
        return null;
    };
    return name;
}

pub fn loadImageFile(alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.indexOfScalar(u8, name, '\\') != null) return null;
    const cfg = util.configDir(alloc) catch return null;
    const path = util.joinPath(alloc, cfg, "artifacts") catch return null;
    const full = util.joinPath(alloc, path, name) catch return null;
    const raw = std.Io.Dir.cwd().readFileAlloc(util.io, full, alloc, .limited(8 * 1024 * 1024)) catch return null;
    const enc = std.base64.standard.Encoder;
    const n = enc.calcSize(raw.len);
    const out = alloc.alloc(u8, n) catch return null;
    _ = enc.encode(out, raw);
    return out;
}

fn writeImageFields(w: *std.Io.Writer, alloc: std.mem.Allocator, m: ai.Message) void {
    const img = m.image orelse return;
    if (img.len == 0) return;
    const name = persistImageFile(alloc, img, m.image_mime) orelse return;
    w.print(",\"image_file\":{s}", .{util.jsonString(alloc, name) catch "\"\""}) catch |err| util.debugCatch("session.img.file", err);
    if (m.image_mime) |mime| {
        if (mime.len > 0) w.print(",\"image_mime\":{s}", .{util.jsonString(alloc, mime) catch "\"\""}) catch |err| util.debugCatch("session.img.mime", err);
    }
    if (m.image_w > 0) w.print(",\"image_w\":{d}", .{m.image_w}) catch |err| util.debugCatch("session.img.w", err);
    if (m.image_h > 0) w.print(",\"image_h\":{d}", .{m.image_h}) catch |err| util.debugCatch("session.img.h", err);
}

fn applyImageFields(alloc: std.mem.Allocator, v: std.json.Value, m: *ai.Message) void {
    if (v != .object) return;
    if (v.object.get("image_file")) |f| {
        if (f == .string) {
            if (loadImageFile(alloc, f.string)) |b64| m.image = b64;
            m.image_file = alloc.dupe(u8, f.string) catch null;
        }
    }
    if (v.object.get("image_mime")) |mm| {
        if (mm == .string) m.image_mime = alloc.dupe(u8, mm.string) catch null;
    }
    if (v.object.get("image_w")) |w| {
        if (w == .integer) m.image_w = @intCast(@max(w.integer, 0));
    }
    if (v.object.get("image_h")) |h| {
        if (h == .integer) m.image_h = @intCast(@max(h.integer, 0));
    }
}

/// 按项目(cwd)分桶的 web 会话目录:<cfg>/sessions/web/<cwd-slug>/。
pub fn webDirPublic(alloc: std.mem.Allocator, cwd: []const u8) ![]u8 {
    return webDir(alloc, cwd);
}

pub fn webDir(alloc: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const cfg_dir = try util.configDir(alloc);
    defer alloc.free(cfg_dir);
    const sess_dir = try util.joinPath(alloc, cfg_dir, "sessions");
    defer alloc.free(sess_dir);
    const web_root = try util.joinPath(alloc, sess_dir, "web");
    defer alloc.free(web_root);
    const slug = try util.cwdSlug(alloc, cwd);
    defer alloc.free(slug);
    return util.joinPath(alloc, web_root, slug);
}

/// 旧布局会话目录(无项目分桶,迁移用)。
fn legacyWebDir(alloc: std.mem.Allocator) ![]u8 {
    const cfg_dir = try util.configDir(alloc);
    const sess_dir = try util.joinPath(alloc, cfg_dir, "sessions");
    return util.joinPath(alloc, sess_dir, "web");
}

/// 迁移旧布局会话到默认项目桶(启动时调一次)。
pub fn migrateLegacyWeb(alloc: std.mem.Allocator, default_cwd: []const u8) void {
    const legacy = legacyWebDir(alloc) catch return;
    defer alloc.free(legacy);
    const target = webDir(alloc, default_cwd) catch return;
    defer alloc.free(target);
    if (std.mem.eql(u8, legacy, target)) return;
    std.Io.Dir.cwd().createDirPath(util.io, target) catch |err| util.debugCatch("session.mkdir", err);
    var d = std.Io.Dir.cwd().openDir(util.io, legacy, .{ .iterate = true }) catch return;
    defer d.close(util.io);
    var it = d.iterate();
    while (it.next(util.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const src = util.joinPath(alloc, legacy, entry.name) catch continue;
        defer alloc.free(src);
        const dst = util.joinPath(alloc, target, entry.name) catch continue;
        defer alloc.free(dst);
        // 目标已有则跳过
        if (std.Io.Dir.cwd().access(util.io, dst, .{})) |_| {
            continue;
        } else |_| {}
        std.Io.Dir.rename(std.Io.Dir.cwd(), src, std.Io.Dir.cwd(), dst, util.io) catch |err| util.debugCatch("migrateLegacyWeb", err);
    }
}

/// 全量重写 web 会话文件:meta 行 + 消息 JSONL。
pub fn saveWeb(alloc: std.mem.Allocator, cwd: []const u8, name: []const u8, model: []const u8, auto: bool, title: ?[]const u8, messages: []const ai.Message) !void {
    saveWebTs(alloc, cwd, name, model, auto, title, messages, std.Io.Clock.now(.real, util.io).nanoseconds) catch |e| return e;
}

/// saveWeb 带显式更新时间(毫秒粒度)。v2:常规路径追加(只写新消息),
/// 消息变短(undo/compact)才整体重写 —— 超长会话不再轮轮 O(size)。
/// 镜像 <name>.meta.json 记 model/auto/title/updated/count。
pub fn saveWebTs(alloc: std.mem.Allocator, cwd: []const u8, name: []const u8, model: []const u8, auto: bool, title: ?[]const u8, messages: []const ai.Message, updated_ns: i128) !void {
    if (!webNameOk(name)) return error.InvalidName;
    const dir = try webDir(alloc, cwd);
    defer alloc.free(dir);
    std.Io.Dir.cwd().createDirPath(util.io, dir) catch |err| util.debugCatch("session.mkdir", err);
    const fname = try std.fmt.allocPrint(alloc, "{s}.jsonl", .{name});
    defer alloc.free(fname);
    const path = try util.joinPath(alloc, dir, fname);
    defer alloc.free(path);
    const mp = try util.joinPath(alloc, dir, try std.fmt.allocPrint(alloc, "{s}.meta.json", .{name}));
    defer alloc.free(mp);

    // 镜像计数:文件已有几条消息(无镜像回退数行,一次性)
    var count0: usize = 0;
    if (std.Io.Dir.cwd().readFileAlloc(util.io, mp, alloc, .limited(64 * 1024))) |mraw| {
        defer alloc.free(mraw);
        const m = std.json.parseFromSliceLeaky(std.json.Value, alloc, mraw, .{}) catch null;
        if (m) |mv| {
            if (mv == .object) {
                if (mv.object.get("count")) |v| {
                    if (v == .integer) count0 = @intCast(@max(v.integer, 0));
                }
            }
        }
    } else |_| {
        // 无镜像:先看文件在不在;在则数行(旧文件,一次性代价)
        if (std.Io.Dir.cwd().statFile(util.io, path, .{})) |st| {
            if (st.size > 0) {
                const got = std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(64 * 1024 * 1024)) catch null;
                if (got) |g| {
                    defer alloc.free(g);
                    var n: usize = 0;
                    var lines = std.mem.splitScalar(u8, g, '\n');
                    while (lines.next()) |l| {
                        if (l.len == 0) continue;
                        n += 1;
                    }
                    count0 = n - @as(usize, @intFromBool(n > 0));
                }
            }
        } else |_| {}
    }

    const st0 = std.Io.Dir.cwd().statFile(util.io, path, .{}) catch null;
    if (count0 == messages.len and st0 != null) {
        // 消息数正好不变:只更新镜像(updated/title/auto 可能过了)
        try writeWebMirror(alloc, mp, model, auto, title orelse "", updated_ns, messages.len);
        return;
    }
    // 消息变短(undo/compact):落到下方整体原子重写 —— 只更镜像会留下
    // 比镜像多的旧消息,下次追加从错位的 count0 起写,历史即错乱。

    if (count0 > 0 and count0 < messages.len and st0 != null) {
        // 常规:追加新消息(messages[count0..])
        {
            var f = try std.Io.Dir.cwd().openFile(util.io, path, .{ .mode = .write_only });
            defer f.close(util.io);
            var wbuf: [8192]u8 = undefined;
            var w = f.writer(util.io, &wbuf);
            try w.seekTo(try f.length(util.io));
            for (messages[count0..]) |m| {
                const line = try webMessageLine(alloc, m);
                defer alloc.free(line);
                try w.interface.writeAll(line);
            }
            try w.interface.flush();
        }
        try writeWebMirror(alloc, mp, model, auto, title orelse "", updated_ns, messages.len);
        return;
    }

    // 首写或消息变短(undo/compact):整体重写(tmp+rename 原子)
    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp);
    errdefer std.Io.Dir.cwd().deleteFile(util.io, tmp) catch {};
    {
        const file = try std.Io.Dir.cwd().createFile(util.io, tmp, .{
            .truncate = true,
            .permissions = @enumFromInt(0o600),
        });
        defer file.close(util.io);
        var wbuf: [8192]u8 = undefined;
        var w = file.writer(util.io, &wbuf);
        w.interface.writeAll("{\"model\":") catch return error.WriteFailed;
        w.interface.writeAll(util.jsonString(alloc, model) catch "\"\"") catch return error.WriteFailed;
        w.interface.writeAll(",\"auto\":") catch return error.WriteFailed;
        w.interface.writeAll(if (auto) "true" else "false") catch return error.WriteFailed;
        w.interface.writeAll(",\"title\":") catch return error.WriteFailed;
        w.interface.writeAll(util.jsonString(alloc, title orelse "") catch "\"\"") catch return error.WriteFailed;
        w.interface.writeAll(",\"updated\":") catch return error.WriteFailed;
        w.interface.print("{d}\n", .{@divTrunc(updated_ns, std.time.ns_per_ms)}) catch return error.WriteFailed;
        for (messages) |m| {
            const line = try webMessageLine(alloc, m);
            defer alloc.free(line);
            w.interface.writeAll(line) catch return error.WriteFailed;
        }
        w.interface.flush() catch return error.WriteFailed;
    }
    try std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), path, util.io);
    try writeWebMirror(alloc, mp, model, auto, title orelse "", updated_ns, messages.len);
}

/// 单条 web 消息行(序列化共用)。
fn webMessageLine(alloc: std.mem.Allocator, m: ai.Message) ![]u8 {
    var jw = std.Io.Writer.Allocating.init(alloc);
    defer jw.deinit();
    const jwtr = &jw.writer;
    jwtr.writeByte('{') catch return error.WriteFailed;
    jwtr.print("\"role\":{s}", .{util.jsonString(alloc, m.role) catch "\"\""}) catch return error.WriteFailed;
    jwtr.print(",\"content\":{s}", .{util.jsonString(alloc, m.content) catch "\"\""}) catch return error.WriteFailed;
    if (m.tool_call_id) |id| jwtr.print(",\"tool_call_id\":{s}", .{util.jsonString(alloc, id) catch "\"\""}) catch return error.WriteFailed;
    if (m.tool_calls) |tcs| {
        jwtr.writeAll(",\"tool_calls\":[") catch return error.WriteFailed;
        for (tcs, 0..) |tc, i| {
            if (i > 0) jwtr.writeByte(',') catch return error.WriteFailed;
            jwtr.print("{{\"id\":{s},\"name\":{s},\"args\":{s}}}", .{
                util.jsonString(alloc, tc.id) catch "\"\"",
                util.jsonString(alloc, tc.name) catch "\"\"",
                util.jsonString(alloc, tc.args) catch "\"\"",
            }) catch return error.WriteFailed;
        }
        jwtr.writeByte(']') catch return error.WriteFailed;
    }
    if (m.reasoning) |r| {
        if (r.len > 0)
            jwtr.print(",\"reasoning\":{s}", .{util.jsonString(alloc, r) catch "\"\""}) catch return error.WriteFailed;
    }
    if (m.thinking_signature) |s| {
        if (s.len > 0)
            jwtr.print(",\"thinking_signature\":{s}", .{util.jsonString(alloc, s) catch "\"\""}) catch return error.WriteFailed;
    }
    if (m.thinking_redacted) jwtr.writeAll(",\"thinking_redacted\":true") catch return error.WriteFailed;
    writeImageFields(jwtr, alloc, m);
    jwtr.writeAll("}\n") catch return error.WriteFailed;
    return jw.toOwnedSlice() catch return error.WriteFailed;
}

/// web 镜像:model/auto/title/updated/count。
fn writeWebMirror(alloc: std.mem.Allocator, mp: []const u8, model: []const u8, auto: bool, title: []const u8, updated_ns: i128, count: usize) !void {
    var ww = std.Io.Writer.Allocating.init(alloc);
    defer ww.deinit();
    const wr = &ww.writer;
    wr.writeAll("{\"model\":") catch return error.WriteFailed;
    wr.writeAll(util.jsonString(alloc, model) catch "\"\"") catch return error.WriteFailed;
    wr.writeAll(",\"auto\":") catch return error.WriteFailed;
    wr.writeAll(if (auto) "true" else "false") catch return error.WriteFailed;
    wr.writeAll(",\"title\":") catch return error.WriteFailed;
    wr.writeAll(util.jsonString(alloc, title) catch "\"\"") catch return error.WriteFailed;
    wr.writeAll(",\"updated\":") catch return error.WriteFailed;
    wr.print("{d}", .{@divTrunc(updated_ns, std.time.ns_per_ms)}) catch return error.WriteFailed;
    wr.print(",\"count\":{d}}}\n", .{count}) catch return error.WriteFailed;
    const data = ww.toOwnedSlice() catch return error.WriteFailed;
    defer alloc.free(data);
    try writeFile600(alloc, mp, data);
}

/// 加载 web 会话:返回 (meta_auto, messages) 或 null(不存在/损坏)。
pub fn loadWeb(alloc: std.mem.Allocator, cwd: []const u8, name: []const u8) !?struct { auto: bool, title: ?[]const u8, model: ?[]const u8, updated: i128, msgs: []ai.Message } {
    if (!webNameOk(name)) return null;
    const dir = try webDir(alloc, cwd);
    defer alloc.free(dir);
    const fname = try std.fmt.allocPrint(alloc, "{s}.jsonl", .{name});
    defer alloc.free(fname);
    const path = try util.joinPath(alloc, dir, fname);
    defer alloc.free(path);
    const w = loadSessionWindow(alloc, path, SESSION_FULL_LIMIT, SESSION_TAIL_BYTES) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer w.deinit(alloc);
    const meta_line = w.meta_line orelse return null;
    var auto = true;
    var title: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var updated: i128 = 0;
    if (std.json.parseFromSliceLeaky(std.json.Value, alloc, meta_line, .{})) |m| {
        if (m == .object) {
            if (m.object.get("auto")) |v| {
                if (v == .bool) auto = v.bool;
            }
            if (m.object.get("title")) |v| {
                if (v == .string and v.string.len > 0) title = alloc.dupe(u8, v.string) catch null;
            }
            if (m.object.get("model")) |v| {
                if (v == .string and v.string.len > 0) model = alloc.dupe(u8, v.string) catch null;
            }
            if (m.object.get("updated")) |v| {
                if (v == .integer and v.integer > 0) updated = v.integer * std.time.ns_per_ms;
            }
        }
    } else |_| {}
    var list = std.array_list.Managed(ai.Message).init(alloc);
    errdefer {
        for (list.items) |m| {
            alloc.free(m.role);
            alloc.free(m.content);
            if (m.tool_call_id) |i| alloc.free(i);
            if (m.tool_calls) |tcs| {
                for (tcs) |tc| {
                    alloc.free(tc.id);
                    alloc.free(tc.name);
                    alloc.free(tc.args);
                }
                alloc.free(tcs);
            }
        }
        list.deinit();
    }
    if (w.folded) {
        try list.append(.{
            .role = try alloc.dupe(u8, "system"),
            .content = try std.fmt.allocPrint(alloc, "[会话历史折叠] 当前上下文仅含本会话近尾内容(前文未载入,完整历史在会话文件中)。如需完整历史重新载入,请直接引用旧会话。", .{}),
        });
    }
    var lines = std.mem.splitScalar(u8, w.body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{}) catch continue;
        if (v != .object) continue;
        const role = if (v.object.get("role")) |r| (if (r == .string) r.string else "") else "";
        const msg_content = if (v.object.get("content")) |c| (if (c == .string) c.string else "") else "";
        var m = ai.Message{
            .role = alloc.dupe(u8, role) catch continue,
            .content = alloc.dupe(u8, msg_content) catch continue,
        };
        if (v.object.get("tool_call_id")) |t| {
            if (t == .string) m.tool_call_id = alloc.dupe(u8, t.string) catch null;
        }
        if (v.object.get("tool_calls")) |t| {
            if (t == .array) {
                const tcs = alloc.alloc(ai.ToolCall, t.array.items.len) catch null;
                if (tcs) |arr| {
                    var n: usize = 0;
                    for (t.array.items) |item| {
                        if (item != .object) continue;
                        const id = if (item.object.get("id")) |i| (if (i == .string) i.string else "") else "";
                        const nm = if (item.object.get("name")) |i| (if (i == .string) i.string else "") else "";
                        const ar = if (item.object.get("args")) |i| (if (i == .string) i.string else "") else "";
                        arr[n] = .{
                            .id = alloc.dupe(u8, id) catch "",
                            .name = alloc.dupe(u8, nm) catch "",
                            .args = alloc.dupe(u8, ar) catch "",
                        };
                        n += 1;
                    }
                    m.tool_calls = arr[0..n];
                }
            }
        }
        if (v.object.get("reasoning") orelse v.object.get("reasoning_content")) |r| {
            if (r == .string and r.string.len > 0) m.reasoning = alloc.dupe(u8, r.string) catch null;
        }
        if (v.object.get("thinking_signature")) |s| {
            if (s == .string and s.string.len > 0) m.thinking_signature = alloc.dupe(u8, s.string) catch null;
        }
        if (v.object.get("thinking_redacted")) |r| {
            if (r == .bool) m.thinking_redacted = r.bool;
        }
        applyImageFields(alloc, v, &m);
        list.append(m) catch continue;
    }
    return .{ .auto = auto, .title = title, .model = model, .updated = updated, .msgs = list.toOwnedSlice() catch return null };
}

/// 归档会话:移到 <dir>/archive/<name>.jsonl。
pub fn archiveWeb(alloc: std.mem.Allocator, cwd: []const u8, name: []const u8) !void {
    if (!webNameOk(name)) return error.InvalidName;
    const dir = try webDir(alloc, cwd);
    defer alloc.free(dir);
    const arch = try util.joinPath(alloc, dir, "archive");
    defer alloc.free(arch);
    std.Io.Dir.cwd().createDirPath(util.io, arch) catch |err| util.debugCatch("session.archive", err);
    const fname = try std.fmt.allocPrint(alloc, "{s}.jsonl", .{name});
    defer alloc.free(fname);
    const src = try util.joinPath(alloc, dir, fname);
    defer alloc.free(src);
    const dst = try util.joinPath(alloc, arch, fname);
    defer alloc.free(dst);
    try std.Io.Dir.renameAbsolute(src, dst, util.io);
    // 镜像随行(best-effort):留档会变幽灵计数
    const msrc = try std.fmt.allocPrint(alloc, "{s}.meta.json", .{src[0 .. src.len - ".jsonl".len]});
    defer alloc.free(msrc);
    const mdst = try std.fmt.allocPrint(alloc, "{s}.meta.json", .{dst[0 .. dst.len - ".jsonl".len]});
    defer alloc.free(mdst);
    std.Io.Dir.renameAbsolute(msrc, mdst, util.io) catch {};
}

/// 恢复归档会话:移回 <dir>/<name>.jsonl。
pub fn restoreWeb(alloc: std.mem.Allocator, cwd: []const u8, name: []const u8) !void {
    if (!webNameOk(name)) return error.InvalidName;
    const dir = try webDir(alloc, cwd);
    defer alloc.free(dir);
    const arch = try util.joinPath(alloc, dir, "archive");
    defer alloc.free(arch);
    const fname = try std.fmt.allocPrint(alloc, "{s}.jsonl", .{name});
    defer alloc.free(fname);
    const src = try util.joinPath(alloc, arch, fname);
    defer alloc.free(src);
    const dst = try util.joinPath(alloc, dir, fname);
    defer alloc.free(dst);
    try std.Io.Dir.renameAbsolute(src, dst, util.io);
    const msrc = try std.fmt.allocPrint(alloc, "{s}.meta.json", .{src[0 .. src.len - ".jsonl".len]});
    defer alloc.free(msrc);
    const mdst = try std.fmt.allocPrint(alloc, "{s}.meta.json", .{dst[0 .. dst.len - ".jsonl".len]});
    defer alloc.free(mdst);
    std.Io.Dir.renameAbsolute(msrc, mdst, util.io) catch {};
}

/// 删除 web 会话文件(归档或活动)。
pub fn deleteWeb(alloc: std.mem.Allocator, cwd: []const u8, name: []const u8) !void {
    if (!webNameOk(name)) return error.InvalidName;
    const dir = try webDir(alloc, cwd);
    defer alloc.free(dir);
    const fname = try std.fmt.allocPrint(alloc, "{s}.jsonl", .{name});
    defer alloc.free(fname);
    const path = try util.joinPath(alloc, dir, fname);
    defer alloc.free(path);
    var n: u8 = 0;
    if (std.Io.Dir.cwd().deleteFile(util.io, path)) |_| {
        n += 1;
    } else |_| {}
    const arch = try util.joinPath(alloc, dir, "archive");
    defer alloc.free(arch);
    const apath = try util.joinPath(alloc, arch, fname);
    defer alloc.free(apath);
    if (std.Io.Dir.cwd().deleteFile(util.io, apath)) |_| {
        n += 1;
    } else |_| {}
    if (n == 0) return error.FileNotFound;
    // 孤儿镜像一并清(best-effort)
    const base = fname[0 .. fname.len - ".jsonl".len];
    for ([_][]const u8{ dir, arch }) |d| {
        const m = std.fmt.allocPrint(alloc, "{s}/{s}.meta.json", .{ d, base }) catch continue;
        defer alloc.free(m);
        std.Io.Dir.cwd().deleteFile(util.io, m) catch {};
    }
}

/// 列出归档会话名。
pub fn listWebArchived(alloc: std.mem.Allocator, cwd: []const u8) ![][]const u8 {
    const dir = try util.joinPath(alloc, try webDirPublic(alloc, cwd), "archive");
    defer alloc.free(dir);
    var names = std.array_list.Managed([]const u8).init(alloc);
    var d = std.Io.Dir.cwd().openDir(util.io, dir, .{ .iterate = true }) catch return names.toOwnedSlice() catch &.{};
    defer d.close(util.io);
    var it = d.iterate();
    while (try it.next(util.io)) |entry| {
        if (entry.kind != .file) continue;
        const base = std.fs.path.basename(entry.name);
        if (!std.mem.endsWith(u8, base, ".jsonl")) continue;
        names.append(alloc.dupe(u8, base[0 .. base.len - 6]) catch continue) catch continue;
    }
    return names.toOwnedSlice() catch &.{};
}

/// 列出 web 会话名(不含 meta 行计数)。
pub fn listWebNames(alloc: std.mem.Allocator, cwd: []const u8) ![][]const u8 {
    const dir = try webDir(alloc, cwd);
    defer alloc.free(dir);
    var names = std.array_list.Managed([]const u8).init(alloc);
    var d = std.Io.Dir.cwd().openDir(util.io, dir, .{ .iterate = true }) catch return names.toOwnedSlice() catch &.{};
    defer d.close(util.io);
    var it = d.iterate();
    while (try it.next(util.io)) |entry| {
        if (entry.kind != .file) continue;
        const base = std.fs.path.basename(entry.name);
        if (!std.mem.endsWith(u8, base, ".jsonl")) continue;
        names.append(alloc.dupe(u8, base[0 .. base.len - 6]) catch continue) catch continue;
    }
    return names.toOwnedSlice() catch &.{};
}

/// v2 阈值:全文载入上限与尾窗字节(参数化便于测试)。
pub const SESSION_FULL_LIMIT: usize = 8 * 1024 * 1024;
pub const SESSION_TAIL_BYTES: usize = 3 * 1024 * 1024;

pub const SessionWindow = struct {
    /// 文件首行(meta;小文件时与 body 同源,单独 dupe;调用方经 deinit 释放)
    meta_line: ?[]u8,
    /// body 的持有分配(body 是其子切片;释放只能 free buf,不得 free body)
    buf: []u8,
    /// 消息区(已剥 meta 行;尾窗时从行边界起;切片指向 buf)
    body: []const u8,
    /// 是否折叠(前文省略)
    folded: bool,

    pub fn deinit(self: SessionWindow, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
        if (self.meta_line) |ml| alloc.free(ml);
    }
};

/// 会话读窗口:小文件全载;大文件只取尾 tail_bytes(行边界起)+ 首行 meta。
/// 写路径不变(追加);此为读侧唯一入口(CLI loadMessages / web loadWeb 共用)。
pub fn loadSessionWindow(alloc: std.mem.Allocator, path: []const u8, full_limit: usize, tail_bytes: usize) !SessionWindow {
    var f = try std.Io.Dir.cwd().openFile(util.io, path, .{ .mode = .read_only });
    defer f.close(util.io);
    const len = try f.length(util.io);
    var rbuf: [8192]u8 = undefined;
    var r = f.reader(util.io, &rbuf);

    // 首行 meta:小读(8KB 足够 meta 行)
    var meta_line: ?[]u8 = null;
    {
        var hbuf: [8192]u8 = undefined;
        const got = r.interface.readSliceShort(&hbuf) catch 0;
        if (got > 0) {
            const nl = std.mem.indexOfScalar(u8, hbuf[0..@min(got, hbuf.len)], '\n');
            const end = if (nl) |i| i else got;
            if (end > 0) meta_line = try alloc.dupe(u8, hbuf[0..@min(end, got)]);
        }
        try r.seekTo(0);
    }

    if (len <= full_limit) {
        const whole = try r.interface.readAlloc(alloc, @intCast(len));
        var body: []const u8 = whole;
        if (meta_line) |ml| {
            // 剥首行(逐字节定位;meta_line 长度即首行长度)
            if (whole.len > ml.len) {
                const skip = ml.len + 1; // 首行 + '\n'
                if (skip < whole.len) body = whole[skip..];
            }
        }
        return .{ .meta_line = meta_line, .buf = whole, .body = body, .folded = false };
    }

    // 尾窗:seek 到 len - tail(行边界修正:找窗口内首个 '\n' 后起)
    const start = len - @min(len, @as(u64, tail_bytes));
    try r.seekTo(start);
    const win = try r.interface.readAlloc(alloc, @intCast(@min(len - start, @as(u64, tail_bytes))));
    const nl = std.mem.indexOfScalar(u8, win, '\n');
    const body: []const u8 = if (nl) |i|
        (if (i + 1 <= win.len) win[i + 1 ..] else win)
    else
        win;
    return .{ .meta_line = meta_line, .buf = win, .body = body, .folded = true };
}

/// 镜像路径(文件级):<path 去 .jsonl>.meta.json。
pub fn mirrorPathFor(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var mp = std.array_list.Managed(u8).init(alloc);
    const base = if (std.mem.endsWith(u8, path, ".jsonl")) path[0 .. path.len - ".jsonl".len] else path;
    try mp.appendSlice(base);
    try mp.appendSlice(".meta.json");
    return mp.toOwnedSlice();
}

/// 写 0600 小文件(镜像用)。
pub fn writeFile600(alloc: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp);
    errdefer std.Io.Dir.cwd().deleteFile(util.io, tmp) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(util.io, tmp, .{
            .truncate = true,
            .permissions = @enumFromInt(0o600),
        });
        defer f.close(util.io);
        var wbuf: [4096]u8 = undefined;
        var w = f.writer(util.io, &wbuf);
        try w.interface.writeAll(data);
        try w.interface.flush();
    }
    try std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), path, util.io);
}

pub const Session = struct {
    alloc: std.mem.Allocator,
    path: []u8, // 会话文件绝对路径
    cwd: []u8,
    title: ?[]const u8 = null,
    /// 会话树:消息计数与最后落盘消息 id(saveMessage 维护,loadMessages 恢复)
    seq: u64 = 0,
    last_id: ?[]const u8 = null,
    /// meta 首行已落盘?惰性写盘:fresh 只定径不写首行,首条消息/setTitle/fork 方落——
    /// 开而未言即退者不留空壳(findLatest/list 本也不见无 meta 之档)。
    meta_written: bool = false,
    /// v2:轻量镜像 <id>.meta.json(扫描/描述零正文读)。preview/turns 由镜像维护。
    mirror: bool = false,
    preview: ?[]const u8 = null,
    turns: u32 = 0,

    pub fn deinit(self: *Session) void {
        self.alloc.free(self.path);
        self.alloc.free(self.cwd);
        if (self.title) |t| self.alloc.free(t);
        if (self.last_id) |i| self.alloc.free(i);
        if (self.preview) |p| self.alloc.free(p);
    }

    /// 镜像路径:会话文件去 .jsonl 加 .meta.json。
    fn mirrorPath(self: *const Session, alloc: std.mem.Allocator) ![]u8 {
        var mp = std.array_list.Managed(u8).init(alloc);
        try mp.appendSlice(self.path[0 .. self.path.len - ".jsonl".len]);
        try mp.appendSlice(".meta.json");
        return mp.toOwnedSlice();
    }

    /// 写轻量镜像(整字段覆盖写;180-500B/次)。
    pub fn writeMirror(self: *const Session) !void {
        const mp = try self.mirrorPath(self.alloc);
        defer self.alloc.free(mp);
        var ww = std.Io.Writer.Allocating.init(self.alloc);
        defer ww.deinit();
        const wr = &ww.writer;
        wr.writeAll("{\"format\":2,\"cwd\":") catch return error.WriteFailed;
        wr.writeAll(util.jsonString(self.alloc, self.cwd) catch "\"\"") catch return error.WriteFailed;
        wr.writeAll(",\"started\":") catch return error.WriteFailed;
        wr.print("{d}", .{@divTrunc(std.Io.Clock.now(.real, util.io).nanoseconds, std.time.ns_per_s)}) catch return error.WriteFailed;
        if (self.title) |t| {
            wr.writeAll(",\"title\":") catch return error.WriteFailed;
            wr.writeAll(util.jsonString(self.alloc, t) catch "\"\"") catch return error.WriteFailed;
        }
        if (self.preview) |p| {
            wr.writeAll(",\"preview\":") catch return error.WriteFailed;
            wr.writeAll(util.jsonString(self.alloc, p) catch "\"\"") catch return error.WriteFailed;
        }
        if (self.turns > 0) {
            wr.writeAll(",\"turns\":") catch return error.WriteFailed;
            wr.print("{d}", .{self.turns}) catch return error.WriteFailed;
        }
        wr.writeAll("}\n") catch return error.WriteFailed;
        const data = ww.toOwnedSlice() catch return error.WriteFailed;
        defer self.alloc.free(data);
        try writeFile600(self.alloc, mp, data);
    }

    /// 从镜像读(open 用):解析 format 2 镜像,填充 cwd/title/preview/turns。
    fn readMirror(self: *Session, mirror_raw: []const u8) bool {
        const m = std.json.parseFromSliceLeaky(std.json.Value, self.alloc, mirror_raw, .{}) catch return false;
        if (m != .object) return false;
        const fmt = if (m.object.get("format")) |v| (if (v == .integer) v.integer else 0) else 0;
        if (fmt != 2) return false;
        const mcwd = if (m.object.get("cwd")) |v| (if (v == .string) v.string else "") else "";
        if (mcwd.len == 0) return false;
        self.cwd = self.alloc.dupe(u8, mcwd) catch return false;
        if (m.object.get("title")) |v| {
            if (v == .string and v.string.len > 0) self.title = self.alloc.dupe(u8, v.string) catch null;
        }
        if (m.object.get("preview")) |v| {
            if (v == .string and v.string.len > 0) self.preview = self.alloc.dupe(u8, v.string) catch null;
        }
        if (m.object.get("turns")) |v| {
            if (v == .integer) self.turns = @intCast(@max(v.integer, 0));
        }
        self.mirror = true;
        self.meta_written = true;
        return true;
    }



    pub fn sessionsDir(self: *Session) ![]u8 {
        const cfg_dir = try util.configDir(self.alloc);
        return util.joinPath(self.alloc, cfg_dir, "sessions");
    }

    /// 创建新会话文件。
    pub fn fresh(alloc: std.mem.Allocator, cwd: []const u8) !Session {
        return freshTitle(alloc, cwd, null);
    }

    /// 创建新会话文件(带标题)。
    /// 布局与 pi 兼容:sessions/<cwd-slug>/<ts>.jsonl(可看到 pi 的会话)。
    /// 文件名是毫秒时间戳;已被占用就 +1,避免 `/new` 连打写回同一个文件。
    pub fn freshTitle(alloc: std.mem.Allocator, cwd: []const u8, title: ?[]const u8) !Session {
        const cfg_dir = try util.configDir(alloc);
        defer alloc.free(cfg_dir);
        const slug = try util.cwdSlug(alloc, cwd);
        defer alloc.free(slug);
        const sess_dir = try util.joinPath(alloc, cfg_dir, "sessions");
        defer alloc.free(sess_dir);
        const sub = try util.joinPath(alloc, sess_dir, slug);
        defer alloc.free(sub);
        std.Io.Dir.cwd().createDirPath(util.io, sub) catch |err| util.debugCatch("session.mkdir", err);
        var ts: i128 = @divTrunc(std.Io.Clock.now(.real, util.io).nanoseconds, std.time.ns_per_ms);
        var path: []u8 = undefined;
        var n: usize = 0;
        while (n < 1000) : (n += 1) {
            var buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&buf, "{d}.jsonl", .{ts}) catch return error.Overflow;
            path = try util.joinPath(alloc, sub, name);
            var f = std.Io.Dir.cwd().createFile(util.io, path, .{
                .exclusive = true,
                .permissions = @enumFromInt(0o600),
            }) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    alloc.free(path);
                    ts += 1;
                    continue;
                },
                else => {
                    alloc.free(path);
                    return err;
                },
            };
            f.close(util.io);
            break;
        } else return error.Overflow;
        var self = Session{ .alloc = alloc, .path = path, .cwd = try alloc.dupe(u8, cwd) };
        errdefer {
            std.Io.Dir.cwd().deleteFile(util.io, self.path) catch |err| util.debugCatch("session.create.cleanup", err);
            self.deinit();
        }
        if (title) |t| self.title = try alloc.dupe(u8, t);
        return self;
    }

    /// 打开指定路径的会话(解析首行元信息)。
    /// 打开:优先读轻量镜像(open 是 list/findById 热路径,不能全读正文);
    /// 无镜像回退首行内嵌 meta(v1 格式,兼容旧档)。
    pub fn open(alloc: std.mem.Allocator, path: []const u8) !Session {
        // v2:镜像优先
        if (mirrorPathFor(alloc, path)) |mp| {
            defer alloc.free(mp);
            if (std.Io.Dir.cwd().readFileAlloc(util.io, mp, alloc, .limited(64 * 1024))) |mraw| {
                defer alloc.free(mraw);
                var self = Session{
                    .alloc = alloc,
                    .path = try alloc.dupe(u8, path),
                    .cwd = try alloc.dupe(u8, ""),
                    .mirror = true,
                    .meta_written = true,
                };
                if (self.readMirror(mraw)) return self;
            } else |_| {}
        } else |_| {}
        const content = std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(16 * 1024 * 1024)) catch {
            return error.InvalidSession;
        };
        defer alloc.free(content);
        var lines = std.mem.splitScalar(u8, content, '\n');
        const meta_line = lines.next() orelse return error.InvalidSession;
        const m = std.json.parseFromSliceLeaky(std.json.Value, alloc, meta_line, .{}) catch return error.InvalidSession;
        if (m != .object) return error.InvalidSession;
        const meta_cwd = if (m.object.get("cwd")) |v| (if (v == .string) v.string else "") else "";
        if (meta_cwd.len == 0) return error.InvalidSession;
        var self = Session{
            .alloc = alloc,
            .path = try alloc.dupe(u8, path),
            .cwd = try alloc.dupe(u8, meta_cwd),
            .meta_written = true,
        };
        if (m.object.get("title")) |v| {
            if (v == .string and v.string.len > 0) self.title = try alloc.dupe(u8, v.string);
        }
        return self;
    }

    /// 寻找 cwd 的最新会话;无则返回 null。
    pub fn findLatest(alloc: std.mem.Allocator, cwd: []const u8) !?Session {
        const all = try list(alloc, cwd);
        if (all.len == 0) return null;
        // 空会话(仅首行 meta、无消息——例如开而未言即退)不作续载目标,
        // 否则裸 piz 落在一页白屏上。顺延至最近有消息者;皆空则回最新空者。
        for (all) |s| {
            if (hasMessages(alloc, s.path)) return s;
        }
        return all[0];
    }

    /// 文件内有消息行({"role":...)即非空。首行 meta 之外一条消息即算。
    /// 文件内有消息行({"role":...)即非空。镜像在场直接判;否则核查正文。
    fn hasMessages(alloc: std.mem.Allocator, path: []const u8) bool {
        if (mirrorPathFor(alloc, path)) |mp| {
            defer alloc.free(mp);
            if (std.Io.Dir.cwd().readFileAlloc(util.io, mp, alloc, .limited(64 * 1024))) |mraw| {
                defer alloc.free(mraw);
                if (std.mem.indexOf(u8, mraw, "\"turns\":") != null) return true;
                if (std.mem.indexOf(u8, mraw, "\"preview\":") != null) return true;
            } else |_| {}
        } else |_| {}
        const raw = std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(16 * 1024 * 1024)) catch return false;
        defer alloc.free(raw);
        return std.mem.indexOf(u8, raw, "\"role\":") != null;
    }

    /// 列出 cwd 的全部会话(sessions/<slug> 子目录,与 pi 布局互通),按 mtime 降序(最新在前)。
    pub fn list(alloc: std.mem.Allocator, cwd: []const u8) ![]Session {
        const cfg_dir = try util.configDir(alloc);
        const slug = try util.cwdSlug(alloc, cwd);
        const sess_dir = try util.joinPath(alloc, cfg_dir, "sessions");
        const sub = try util.joinPath(alloc, sess_dir, slug);
        var dir = std.Io.Dir.cwd().openDir(util.io, sub, .{ .iterate = true }) catch return &.{};
        defer dir.close(util.io);
        var out = std.array_list.Managed(Session).init(alloc);
        var it = dir.iterate();
        while (try it.next(util.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
            const full = try util.joinPath(alloc, sub, entry.name);
            const sess = open(alloc, full) catch continue;
            if (!std.mem.eql(u8, sess.cwd, cwd)) continue;
            try out.append(sess);
        }
        // mtime 降序稳定排序(插入排序):ext4 延迟元数据提交导致同窗口创建的
        // 文件 mtime 可能相同,不稳定排序会打乱顺序;相等时保持发现顺序
        var i: usize = 1;
        while (i < out.items.len) : (i += 1) {
            var j = i;
            while (j > 0) : (j -= 1) {
                const a = out.items[j - 1];
                const b = out.items[j];
                const ma = std.Io.Dir.cwd().statFile(util.io, a.path, .{}) catch return &.{};
                const mb = std.Io.Dir.cwd().statFile(util.io, b.path, .{}) catch return &.{};
                if (ma.mtime.nanoseconds >= mb.mtime.nanoseconds) break;
                out.items[j - 1] = b;
                out.items[j] = a;
            }
        }
        return out.toOwnedSlice();
    }

    fn writeMeta(self: *Session) !void {
        var ww = std.Io.Writer.Allocating.init(self.alloc);
        defer ww.deinit();
        try ww.writer.print("{{\"cwd\":{s},\"started\":{d}", .{
            try util.jsonString(self.alloc, self.cwd),
            @divTrunc(std.Io.Clock.now(.real, util.io).nanoseconds, std.time.ns_per_s),
        });
        if (self.title) |t| {
            try ww.writer.print(",\"title\":{s}", .{try util.jsonString(self.alloc, t)});
        }
        try ww.writer.writeAll("}\n");
        const line = try ww.toOwnedSlice();
        defer self.alloc.free(line);
        try self.append(line);
        // v2:同步镜像(轻量 read-modify 面都在镜像上)
        try self.writeMirror();
        self.meta_written = true;
    }

    /// 设置标题:v2 只改镜像(不再重写正文;老版回退首行可见旧标题,无碍)。
    pub fn setTitle(self: *Session, raw_title: []const u8) !void {
        const title = util.clampUtf8(raw_title, MAX_TITLE_BYTES);
        const old = self.title;
        self.title = if (title.len > 0) try self.alloc.dupe(u8, title) else null;
        if (old) |o| self.alloc.free(o);
        // 档未落盘:首行写出时自携 title,此刻只记账;镜像也等 writeMeta 再写
        if (!self.meta_written) return;
        try self.writeMirror();
    }

    fn append(self: *Session, line: []const u8) !void {
        var f = std.Io.Dir.cwd().createFile(util.io, self.path, .{ .exclusive = true, .permissions = @enumFromInt(0o600) }) catch |err| switch (err) {
            // 已存在:以写模式打开追加
            error.PathAlreadyExists => try std.Io.Dir.cwd().openFile(util.io, self.path, .{ .mode = .write_only }),
            else => return err,
        };
        defer f.close(util.io);
        var wbuf: [4096]u8 = undefined;
        var w = f.writer(util.io, &wbuf);
        try w.seekTo(try f.length(util.io)); // 追加到末尾
        try w.interface.writeAll(line);
        try w.flush(); // 0.16 File.Writer 有缓冲,须显式刷盘
    }

    /// 原子地整体替换会话文件:先写同目录临时文件,再 rename 覆盖。
    ///
    /// 直接 writeFile 到目标路径的话,写入中途失败(磁盘满、被 kill)会留下一个
    /// 截断的文件 —— 用户按一次 /undo 就可能丢掉整个会话历史。rename 在同一
    /// 文件系统上是原子的:要么看到旧文件,要么看到完整的新文件,没有中间态。
    ///
    /// 日常追加走 append(),不经过这里;这条路只服务 setTitle/truncate/fork
    /// 这三个需要重写全文的低频操作。
    fn writeAtomic(self: *Session, path: []const u8, data: []const u8) !void {
        const tmp = try std.fmt.allocPrint(self.alloc, "{s}.tmp", .{path});
        defer self.alloc.free(tmp);
        // 写失败或被打断:删掉临时文件走人,目标文件一个字节都没动过
        errdefer std.Io.Dir.cwd().deleteFile(util.io, tmp) catch |err| util.debugCatch("session.write.tmp", err);
        {
            var f = try std.Io.Dir.cwd().createFile(util.io, tmp, .{
                .truncate = true,
                .permissions = @enumFromInt(0o600),
            });
            defer f.close(util.io);
            var wbuf: [4096]u8 = undefined;
            var w = f.writer(util.io, &wbuf);
            try w.interface.writeAll(data);
            try w.interface.flush();
        }
        // 走到这里临时文件已完整落盘并关闭;rename 在同一文件系统上原子
        try std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), path, util.io);
    }

    /// 截断会话文件至前 msg_count 条消息(保留元信息行)。撤销后保持文件与内存一致。
    pub fn truncate(self: *Session, msg_count: usize) !void {
        const content = std.Io.Dir.cwd().readFileAlloc(util.io, self.path, self.alloc, .limited(16 * 1024 * 1024)) catch return error.InvalidSession;
        defer self.alloc.free(content);
        var outw = std.Io.Writer.Allocating.init(self.alloc);
        defer outw.deinit();
        var lines = std.mem.splitScalar(u8, content, '\n');
        var kept: usize = 0;
        while (lines.next()) |l| {
            if (l.len == 0) continue;
            if (kept >= msg_count + 1) break; // 元信息行 + msg_count 条消息
            try outw.writer.writeAll(l);
            try outw.writer.writeByte('\n');
            kept += 1;
        }
        try self.writeAtomic(self.path, try outw.toOwnedSlice());
    }

    /// 追加一条消息(带会话树 id/parent_id)。
    pub fn saveMessage(self: *Session, msg: *const ai.Message) !void {
        if (!self.meta_written) try self.writeMeta();
        var ww = std.Io.Writer.Allocating.init(self.alloc);
        defer ww.deinit();
        try ww.writer.writeByte('{');
        try ww.writer.print("\"role\":{s}", .{try util.jsonString(self.alloc, msg.role)});
        try ww.writer.print(",\"content\":{s}", .{try util.jsonString(self.alloc, msg.content)});
        // 会话树 id:落盘时生成(ts-seq),parent 接续上一条
        self.seq += 1;
        const mid = try std.fmt.allocPrint(self.alloc, "{x}-{d}", .{
            @divTrunc(std.Io.Clock.now(.real, util.io).nanoseconds, std.time.ns_per_ms),
            self.seq,
        });
        try ww.writer.print(",\"id\":{s}", .{try util.jsonString(self.alloc, mid)});
        if (self.last_id) |pid| {
            try ww.writer.print(",\"parent_id\":{s}", .{try util.jsonString(self.alloc, pid)});
        }
        const old_last = self.last_id;
        self.last_id = mid;
        if (old_last) |o| self.alloc.free(o);
        if (msg.tool_call_id) |id| {
            try ww.writer.print(",\"tool_call_id\":{s}", .{try util.jsonString(self.alloc, id)});
        }
        if (msg.tool_calls) |tcs| {
            try ww.writer.writeAll(",\"tool_calls\":[");
            for (tcs, 0..) |tc, i| {
                if (i > 0) try ww.writer.writeByte(',');
                try ww.writer.print("{{\"id\":{s},\"name\":{s},\"args\":{s}}}", .{
                    try util.jsonString(self.alloc, tc.id),
                    try util.jsonString(self.alloc, tc.name),
                    try util.jsonString(self.alloc, tc.args),
                });
            }
            try ww.writer.writeByte(']');
        }
        if (msg.reasoning) |r| {
            if (r.len > 0)
                try ww.writer.print(",\"reasoning\":{s}", .{try util.jsonString(self.alloc, r)});
        }
        if (msg.thinking_signature) |s| {
            if (s.len > 0)
                try ww.writer.print(",\"thinking_signature\":{s}", .{try util.jsonString(self.alloc, s)});
        }
        if (msg.thinking_redacted) try ww.writer.writeAll(",\"thinking_redacted\":true");
        writeImageFields(&ww.writer, self.alloc, msg.*);
        try ww.writer.writeAll("}\n");
        const line = try ww.toOwnedSlice();
        defer self.alloc.free(line);
        try self.append(line);
        // v2:user 消息维护镜像(preview/turns) —— 列表/描述零正文读
        if (std.mem.eql(u8, msg.role, "user")) {
            if (self.preview == null and msg.content.len > 0) {
                const p = util.clampUtf8(msg.content, 60);
                if (p.len > 0) self.preview = try self.alloc.dupe(u8, p);
            }
            self.turns += 1;
            try self.writeMirror();
        }
    }

    /// 会话 id:文件名去掉 .jsonl,与 `-s` / findById 同一套。
    pub fn sessionId(self: *const Session) []const u8 {
        const base = std.fs.path.basename(self.path);
        return if (std.mem.endsWith(u8, base, ".jsonl"))
            base[0 .. base.len - ".jsonl".len]
        else
            base;
    }

    pub const Describe = struct {
        headline: []u8,
        hint: []u8,

        pub fn deinit(self: Describe, alloc: std.mem.Allocator) void {
            alloc.free(self.headline);
            alloc.free(self.hint);
        }
    };

    /// 列表/picker 用:标题优先,否则首条 user 预览,再否则 id。hint 为相对时间与轮数。
    /// v2:镜像在场则零正文读;v1 旧档回退读首 256KB。
    pub fn describe(self: *const Session, alloc: std.mem.Allocator, now_ns: i128) !Describe {
        var preview_buf: [64]u8 = undefined;
        var preview: ?[]const u8 = null;
        var turns: usize = 0;
        var preview_owned: ?[]u8 = null;
        defer if (preview_owned) |p| alloc.free(p);
        if (self.mirror) {
            preview = self.preview;
            turns = self.turns;
        } else if (std.Io.Dir.cwd().readFileAlloc(util.io, self.path, alloc, .limited(256 * 1024))) |content| {
            defer alloc.free(content);
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
                defer parsed.deinit();
                if (parsed.value != .object) continue;
                const role = if (parsed.value.object.get("role")) |r| (if (r == .string) r.string else "") else "";
                if (!std.mem.eql(u8, role, "user")) continue;
                turns += 1;
                if (preview != null) continue;
                const body = if (parsed.value.object.get("content")) |c| (if (c == .string) c.string else "") else "";
                if (body.len == 0) continue;
                preview = flattenPreview(body, &preview_buf);
                preview_owned = alloc.dupe(u8, preview.?) catch null;
            }
        } else |_| {}

        const raw = if (self.title) |tt|
            tt
        else if (preview) |p|
            p
        else
            self.sessionId();
        const headline = try alloc.dupe(u8, util.clampUtf8(raw, 48));
        errdefer alloc.free(headline);

        var age_buf: [16]u8 = undefined;
        const then_ns = if (std.Io.Dir.cwd().statFile(util.io, self.path, .{})) |st| st.mtime.nanoseconds else |_| @as(i128, 0);
        const age = formatAge(&age_buf, now_ns, then_ns);
        const hint = if (turns > 0)
            try std.fmt.allocPrint(alloc, "{s} · {d}t", .{ age, turns })
        else
            try alloc.dupe(u8, age);
        return .{ .headline = headline, .hint = hint };
    }

    /// 按 id(文件名去 .jsonl)寻找会话。
    pub fn findById(alloc: std.mem.Allocator, cwd: []const u8, id: []const u8) !?Session {
        const list_sessions = try list(alloc, cwd);
        for (list_sessions) |s| {
            const base = std.fs.path.basename(s.path);
            if (std.mem.eql(u8, base, id)) return s;
            if (std.mem.endsWith(u8, base, ".jsonl") and std.mem.eql(u8, base[0 .. base.len - ".jsonl".len], id)) return s;
        }
        return null;
    }

    /// 解析消息行(跳过 skip_first 行),追加到 out。恢复 seq/last_id;统计
    /// preview/turns(镜像缺失时兜底,载完由调用方落镜像升级 v1→v2)。
    fn parseMessageLines(self: *Session, content: []const u8, skip_first: bool, out: *std.array_list.Managed(ai.Message)) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');
        var first = skip_first;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (first) {
                first = false;
                continue; // 元信息行
            }
            const root = std.json.parseFromSliceLeaky(std.json.Value, self.alloc, line, .{}) catch continue;
            const v = root;
            if (v != .object) continue;
            const role = if (v.object.get("role")) |r| (if (r == .string) r.string else "") else continue;
            const content_str = if (v.object.get("content")) |c| (if (c == .string) c.string else "") else "";
            var msg = ai.Message{
                .role = try self.alloc.dupe(u8, role),
                .content = try self.alloc.dupe(u8, content_str),
            };
            if (v.object.get("tool_call_id")) |tcid| {
                if (tcid == .string) msg.tool_call_id = try self.alloc.dupe(u8, tcid.string);
            }
            // 会话树 id/parent_id(可选字段,兼容旧文件)
            if (v.object.get("id")) |mid| {
                if (mid == .string and mid.string.len > 0) msg.id = try self.alloc.dupe(u8, mid.string);
            }
            if (v.object.get("parent_id")) |pid| {
                if (pid == .string and pid.string.len > 0) msg.parent_id = try self.alloc.dupe(u8, pid.string);
            }
            // 恢复 last_id/seq(续写时 parent 接续)——须 dupe,msg.id 归 out 数组所有
            if (msg.id) |mid| {
                self.seq += 1;
                const old_last = self.last_id;
                self.last_id = try self.alloc.dupe(u8, mid);
                if (old_last) |o| self.alloc.free(o);
            }
            if (v.object.get("tool_calls")) |tcs| {
                if (tcs == .array and tcs.array.items.len > 0) {
                    var calls = std.array_list.Managed(ai.ToolCall).init(self.alloc);
                    for (tcs.array.items) |tc| {
                        if (tc != .object) continue;
                        const id = if (tc.object.get("id")) |i| (if (i == .string) i.string else "") else "";
                        const name = if (tc.object.get("name")) |n| (if (n == .string) n.string else "") else "";
                        const args = if (tc.object.get("args")) |a| (if (a == .string) a.string else "") else "";
                        try calls.append(.{
                            .id = try self.alloc.dupe(u8, id),
                            .name = try self.alloc.dupe(u8, name),
                            .args = try self.alloc.dupe(u8, args),
                        });
                    }
                    msg.tool_calls = try calls.toOwnedSlice();
                }
            }
            if (v.object.get("reasoning") orelse v.object.get("reasoning_content")) |r| {
                if (r == .string and r.string.len > 0) msg.reasoning = try self.alloc.dupe(u8, r.string);
            }
            if (v.object.get("thinking_signature")) |s| {
                if (s == .string and s.string.len > 0) msg.thinking_signature = try self.alloc.dupe(u8, s.string);
            }
            if (v.object.get("thinking_redacted")) |r| {
                if (r == .bool) msg.thinking_redacted = r.bool;
            }
            applyImageFields(self.alloc, v, &msg);
            // preview/turns 统计(镜像兜底)
            if (std.mem.eql(u8, role, "user")) {
                if (self.preview == null and content_str.len > 0) {
                    const p = util.clampUtf8(content_str, 60);
                    if (p.len > 0) self.preview = try self.alloc.dupe(u8, p);
                }
                self.turns += 1;
            }
            try out.append(msg);
        }
    }

    /// 载入消息(超限尾窗 + 折叠锚)。见 loadSessionWindow。
    pub fn loadMessages(self: *Session) ![]ai.Message {
        var out = std.array_list.Managed(ai.Message).init(self.alloc);
        const w = try loadSessionWindow(self.alloc, self.path, SESSION_FULL_LIMIT, SESSION_TAIL_BYTES);
        defer w.deinit(self.alloc);
        try self.parseMessageLines(w.body, false, &out);
        if (w.folded) {
            // 折叠锚置首(在最前):历史被省,模型需知
            var anchored = std.array_list.Managed(ai.Message).init(self.alloc);
            try anchored.append(.{
                .role = "system",
                .content = try std.fmt.allocPrint(self.alloc, "[会话历史折叠] 当前上下文仅含本会话近尾内容(前文未载入,完整历史在会话文件中)。如需完整历史重新载入,请直接引用旧会话。", .{}),
            });
            try anchored.appendSlice(out.items);
            out = anchored;
        }
        // v1 旧档升级:载入后补镜像(preview/turns 已统计)
        if (!self.mirror and self.meta_written) {
            self.writeMirror() catch |err| util.debugCatch("session.mirror.bootstrap", err);
        }
        return out.toOwnedSlice();
    }

    /// 全量载入(带 meta 行解析;loadMessages 尾窗版用 body 流)。
    pub fn loadAllMessages(self: *Session) ![]ai.Message {
        const content = std.Io.Dir.cwd().readFileAlloc(util.io, self.path, self.alloc, .limited(64 * 1024 * 1024)) catch return error.InvalidSession;
        defer self.alloc.free(content);
        var out = std.array_list.Managed(ai.Message).init(self.alloc);
        try self.parseMessageLines(content, true, &out);
        return out.toOwnedSlice();
    }

    /// 能进模型请求的会话角色。新的模型可见输入必须能落成其中之一,
    /// 或在 architecture.md 的「模型可见清单」里登记为每轮重装的瞬时件。
    pub const MODEL_VISIBLE_ROLES = [_][]const u8{ "user", "assistant", "tool" };

    pub fn isModelVisibleRole(role: []const u8) bool {
        for (MODEL_VISIBLE_ROLES) |r| {
            if (std.mem.eql(u8, r, role)) return true;
        }
        return false;
    }

    /// 压缩审计(借 dsh compaction/* 仅日志事件之意):密图折页一成,全局追加一行于
    /// <cfg>/sessions/compactions.jsonl。独立 sidecar —— 会话文件被 app 层整写,
    /// 标记行会被冲掉;另立档案,回放不染。失败静默:审计不应绊主链。
    pub fn logCompaction(alloc: std.mem.Allocator, cwd: []const u8, cut: usize, kept: usize, compacts: usize, window: usize, est_after: usize, summary: []const u8) void {
        const cfg = util.configDir(alloc) catch return;
        defer alloc.free(cfg);
        const dir = util.joinPath(alloc, cfg, "sessions") catch return;
        defer alloc.free(dir);
        std.Io.Dir.cwd().createDirPath(util.io, dir) catch {};
        const path = util.joinPath(alloc, dir, "compactions.jsonl") catch return;
        defer alloc.free(path);
        const sum_clip = if (summary.len > 200) summary[0..200] else summary;
        const cwd_json = util.jsonString(alloc, cwd) catch return;
        defer alloc.free(cwd_json);
        const sum_json = util.jsonString(alloc, sum_clip) catch return;
        defer alloc.free(sum_json);
        const line = std.fmt.allocPrint(alloc, "{{\"ts\":{d},\"cwd\":{s},\"cut\":{d},\"kept\":{d},\"compacts\":{d},\"window\":{d},\"est_after\":{d},\"summary\":{s}}}\n", .{
            @divTrunc(std.Io.Clock.now(.real, util.io).nanoseconds, std.time.ns_per_ms),
            cwd_json,
            cut,
            kept,
            compacts,
            window,
            est_after,
            sum_json,
        }) catch return;
        defer alloc.free(line);
        var f = std.Io.Dir.cwd().createFile(util.io, path, .{ .exclusive = true, .permissions = @enumFromInt(0o600) }) catch |err| switch (err) {
            error.PathAlreadyExists => std.Io.Dir.cwd().openFile(util.io, path, .{ .mode = .write_only }) catch return,
            else => return,
        };
        defer f.close(util.io);
        var wbuf: [512]u8 = undefined;
        var w = f.writer(util.io, &wbuf);
        w.seekTo(f.length(util.io) catch 0) catch return;
        w.interface.writeAll(line) catch return;
        w.flush() catch return;
    }

    /// 从日志重建模型历史:丢掉 system / 未知角色,保留 user/assistant/tool。
    pub fn reconstructModelVisible(self: *Session) ![]ai.Message {
        const all = try self.loadMessages();
        var out = std.array_list.Managed(ai.Message).init(self.alloc);
        for (all) |m| {
            if (isModelVisibleRole(m.role)) try out.append(m);
        }
        return out.toOwnedSlice();
    }

    /// 分支:新建会话文件,拷贝前 cut 条消息(含元信息)。后续 saveMessage 自动接续 parent。
    pub fn fork(self: *Session, cut: usize) !Session {
        const content = std.Io.Dir.cwd().readFileAlloc(util.io, self.path, self.alloc, .limited(16 * 1024 * 1024)) catch return error.InvalidSession;
        defer self.alloc.free(content);
        const cfg_dir = try util.configDir(self.alloc);
        const slug = try util.cwdSlug(self.alloc, self.cwd);
        const sub = try util.joinPath(self.alloc, try util.joinPath(self.alloc, cfg_dir, "sessions"), slug);
        std.Io.Dir.cwd().createDirPath(util.io, sub) catch |err| util.debugCatch("session.mkdir", err);
        var buf: [64]u8 = undefined;
        const ts = @divTrunc(std.Io.Clock.now(.real, util.io).nanoseconds, std.time.ns_per_ms);
        const name = std.fmt.bufPrint(&buf, "{d}.jsonl", .{ts}) catch "session.jsonl";
        const new_path = try util.joinPath(self.alloc, sub, name);

        var outw = std.Io.Writer.Allocating.init(self.alloc);
        defer outw.deinit();
        var lines = std.mem.splitScalar(u8, content, '\n');
        var kept: usize = 0;
        var first = true;
        while (lines.next()) |l| {
            if (l.len == 0) continue;
            if (first) {
                first = false;
                // 新 meta 行(不带旧 title)
                try outw.writer.print("{{\"cwd\":{s},\"started\":{d}}}\n", .{
                    try util.jsonString(self.alloc, self.cwd),
                    @divTrunc(std.Io.Clock.now(.real, util.io).nanoseconds, std.time.ns_per_s),
                });
                continue;
            }
            if (kept >= cut) break;
            try outw.writer.writeAll(l);
            try outw.writer.writeByte('\n');
            kept += 1;
        }
        try self.writeAtomic(new_path, try outw.toOwnedSlice());
        var new_sess = Session{
            .alloc = self.alloc,
            .path = new_path,
            .cwd = try self.alloc.dupe(u8, self.cwd),
            .meta_written = true, // fork 拷贝含新 meta 首行
        };
        // 轻量恢复 seq/last_id:只解析行数与每行 id,不构建消息
        if (std.Io.Dir.cwd().readFileAlloc(util.io, new_path, self.alloc, .limited(16 * 1024 * 1024))) |nc| {
            defer self.alloc.free(nc);
            var lit = std.mem.splitScalar(u8, nc, '\n');
            var is_first = true;
            while (lit.next()) |l| {
                if (l.len == 0) continue;
                if (is_first) {
                    is_first = false;
                    continue;
                }
                new_sess.seq += 1;
                if (std.json.parseFromSliceLeaky(std.json.Value, self.alloc, l, .{})) |m| {
                    if (m == .object) {
                        if (m.object.get("id")) |mid| {
                            if (mid == .string) {
                                if (new_sess.last_id) |o| self.alloc.free(o);
                                new_sess.last_id = try self.alloc.dupe(u8, mid.string);
                            }
                        }
                    }
                } else |_| {}
            }
        } else |_| {}
        return new_sess;
    }
};

fn flattenPreview(src: []const u8, buf: []u8) []const u8 {
    var o: usize = 0;
    var space = false;
    for (src) |c| {
        const ws = c == ' ' or c == '\n' or c == '\r' or c == '\t';
        if (ws) {
            if (o > 0) space = true;
            continue;
        }
        if (o >= buf.len) break;
        if (space) {
            if (o + 1 >= buf.len) break;
            buf[o] = ' ';
            o += 1;
            space = false;
        }
        buf[o] = c;
        o += 1;
    }
    return buf[0..o];
}

pub fn formatAge(buf: []u8, now_ns: i128, then_ns: i128) []const u8 {
    if (then_ns <= 0 or now_ns <= then_ns) return "now";
    const sec = @divTrunc(now_ns - then_ns, std.time.ns_per_s);
    if (sec < 60) return "now";
    if (sec < 3600) return std.fmt.bufPrint(buf, "{d}m", .{@divTrunc(sec, 60)}) catch "now";
    if (sec < 86400) return std.fmt.bufPrint(buf, "{d}h", .{@divTrunc(sec, 3600)}) catch "now";
    return std.fmt.bufPrint(buf, "{d}d", .{@divTrunc(sec, 86400)}) catch "now";
}

test {
    // 单测主体在 session_tests.zig(原净尾 483 行);引回以保持 zig test 收集。
    _ = @import("session_tests.zig");
}
