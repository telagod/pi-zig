// session.zig — JSONL 会话持久化:<配置目录>/sessions/<cwd-slug>/<ts>.jsonl。
// 首行元信息 {cwd, started};后续每行一条消息。
const std = @import("std");
const util = @import("util.zig");
const ai = @import("ai.zig");

/// 会话标题字节上限。标题只用于会话列表的一行显示,超出的部分没有用途,
/// 但会一路带进内存、落盘和每个响应。在唯一的持久化入口(setTitle)裁掉,
/// 磁盘上就永远是安全值。
pub const MAX_TITLE_BYTES = 256;

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

/// 按项目(cwd)分桶的 web 会话目录:<cfg>/sessions/web/<cwd-slug>/。
pub fn webDirPublic(alloc: std.mem.Allocator, cwd: []const u8) ![]u8 {
    return webDir(alloc, cwd);
}

fn webDir(alloc: std.mem.Allocator, cwd: []const u8) ![]u8 {
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
    std.Io.Dir.cwd().createDirPath(util.io, target) catch {};
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
        std.Io.Dir.rename(std.Io.Dir.cwd(), src, std.Io.Dir.cwd(), dst, util.io) catch {};
    }
}

/// 全量重写 web 会话文件:meta 行 + 消息 JSONL。
pub fn saveWeb(alloc: std.mem.Allocator, cwd: []const u8, name: []const u8, model: []const u8, auto: bool, title: ?[]const u8, messages: []const ai.Message) !void {
    saveWebTs(alloc, cwd, name, model, auto, title, messages, std.Io.Clock.now(.real, util.io).nanoseconds) catch |e| return e;
}

/// saveWeb 带显式更新时间(毫秒粒度)。
pub fn saveWebTs(alloc: std.mem.Allocator, cwd: []const u8, name: []const u8, model: []const u8, auto: bool, title: ?[]const u8, messages: []const ai.Message, updated_ns: i128) !void {
    if (!webNameOk(name)) return error.InvalidName;
    const dir = try webDir(alloc, cwd);
    defer alloc.free(dir);
    std.Io.Dir.cwd().createDirPath(util.io, dir) catch {};
    const fname = try std.fmt.allocPrint(alloc, "{s}.jsonl", .{name});
    defer alloc.free(fname);
    const path = try util.joinPath(alloc, dir, fname);
    defer alloc.free(path);
    // Web 会话每轮 turn_end 都全量重写(不像 CLI 那样追加),所以崩溃窗口比 CLI
    // 大得多 —— 直写目标路径的话,写到一半被 kill 就是整份历史被截断。
    // 写临时文件再 rename:要么看到旧文件,要么看到完整的新文件。
    // 权限显式 0600:会话里是完整对话内容,不该跟目录默认权限走。
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
            jwtr.writeAll("}\n") catch return error.WriteFailed;
            const line = jw.toOwnedSlice() catch return error.WriteFailed;
            defer alloc.free(line);
            w.interface.writeAll(line) catch return error.WriteFailed;
        }
        w.interface.flush() catch return error.WriteFailed;
    }
    // 走到这里临时文件已完整落盘并关闭;rename 在同一文件系统上原子
    try std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), path, util.io);
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
    const content = std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(32 * 1024 * 1024)) catch return null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    const meta_line = lines.next() orelse return null;
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
    std.Io.Dir.cwd().createDirPath(util.io, arch) catch {};
    const fname = try std.fmt.allocPrint(alloc, "{s}.jsonl", .{name});
    defer alloc.free(fname);
    const src = try util.joinPath(alloc, dir, fname);
    defer alloc.free(src);
    const dst = try util.joinPath(alloc, arch, fname);
    defer alloc.free(dst);
    std.Io.Dir.renameAbsolute(src, dst, util.io) catch {};
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
    std.Io.Dir.renameAbsolute(src, dst, util.io) catch {};
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
    std.Io.Dir.cwd().deleteFile(util.io, path) catch {};
    const arch = try util.joinPath(alloc, dir, "archive");
    defer alloc.free(arch);
    const apath = try util.joinPath(alloc, arch, fname);
    defer alloc.free(apath);
    std.Io.Dir.cwd().deleteFile(util.io, apath) catch {};
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

pub const Session = struct {
    alloc: std.mem.Allocator,
    path: []u8, // 会话文件绝对路径
    cwd: []u8,
    title: ?[]const u8 = null,
    /// 会话树:消息计数与最后落盘消息 id(saveMessage 维护,loadMessages 恢复)
    seq: u64 = 0,
    last_id: ?[]const u8 = null,

    pub fn deinit(self: *Session) void {
        self.alloc.free(self.path);
        self.alloc.free(self.cwd);
        if (self.title) |t| self.alloc.free(t);
        if (self.last_id) |i| self.alloc.free(i);
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
    pub fn freshTitle(alloc: std.mem.Allocator, cwd: []const u8, title: ?[]const u8) !Session {
        const cfg_dir = try util.configDir(alloc);
        const slug = try util.cwdSlug(alloc, cwd);
        const sess_dir = try util.joinPath(alloc, cfg_dir, "sessions");
        const sub = try util.joinPath(alloc, sess_dir, slug);
        std.Io.Dir.cwd().createDirPath(util.io, sub) catch {};
        var buf: [64]u8 = undefined;
        const ts = @divTrunc(std.Io.Clock.now(.real, util.io).nanoseconds, std.time.ns_per_ms); // 毫秒粒度,避免同秒同名覆盖
        const name = std.fmt.bufPrint(&buf, "{d}.jsonl", .{ts}) catch "session.jsonl";
        const path = try util.joinPath(alloc, sub, name);
        var self = Session{ .alloc = alloc, .path = path, .cwd = try alloc.dupe(u8, cwd) };
        if (title) |t| self.title = try alloc.dupe(u8, t);
        try self.writeMeta();
        return self;
    }

    /// 打开指定路径的会话(解析首行元信息)。
    pub fn open(alloc: std.mem.Allocator, path: []const u8) !Session {
        const content = std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(256 * 1024)) catch {
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
        return all[0];
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
    }

    /// 设置标题:重写首行元信息。
    /// 参数在这里裁到 MAX_TITLE_BYTES —— 这是标题落盘的唯一入口,裁在这里
    /// 就保证磁盘上不会出现无界标题,读回来的也一定是安全值。
    pub fn setTitle(self: *Session, raw_title: []const u8) !void {
        const title = util.clampUtf8(raw_title, MAX_TITLE_BYTES);
        const content = std.Io.Dir.cwd().readFileAlloc(util.io, self.path, self.alloc, .limited(256 * 1024)) catch return error.InvalidSession;
        defer self.alloc.free(content);
        var lines = std.mem.splitScalar(u8, content, '\n');
        _ = lines.next() orelse return error.InvalidSession;
        var outw = std.Io.Writer.Allocating.init(self.alloc);
        defer outw.deinit();
        try outw.writer.print("{{\"cwd\":{s},\"started\":{d}", .{
            try util.jsonString(self.alloc, self.cwd),
            @divTrunc(std.Io.Clock.now(.real, util.io).nanoseconds, std.time.ns_per_s),
        });
        if (title.len > 0) {
            try outw.writer.print(",\"title\":{s}", .{try util.jsonString(self.alloc, title)});
        }
        try outw.writer.writeAll("}\n");
        // 其余行原样
        var rest = std.array_list.Managed(u8).init(self.alloc);
        defer rest.deinit();
        var it = lines;
        while (it.next()) |l| {
            try rest.appendSlice(l);
            try rest.append('\n');
        }
        try outw.writer.writeAll(rest.items);
        try self.writeAtomic(self.path, try outw.toOwnedSlice());
        const old = self.title;
        self.title = if (title.len > 0) try self.alloc.dupe(u8, title) else null;
        if (old) |o| self.alloc.free(o);
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
        errdefer std.Io.Dir.cwd().deleteFile(util.io, tmp) catch {};
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
        try ww.writer.writeAll("}\n");
        const line = try ww.toOwnedSlice();
        defer self.alloc.free(line);
        try self.append(line);
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

    /// 载入全部消息。
    pub fn loadMessages(self: *Session) ![]ai.Message {
        var out = std.array_list.Managed(ai.Message).init(self.alloc);
        const content = std.Io.Dir.cwd().readFileAlloc(util.io, self.path, self.alloc, .limited(16 * 1024 * 1024)) catch return &.{};
        defer self.alloc.free(content);
        var lines = std.mem.splitScalar(u8, content, '\n');
        var first = true;
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
            try out.append(msg);
        }
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
        std.Io.Dir.cwd().createDirPath(util.io, sub) catch {};
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

test "session roundtrip" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 隔离 env:否则会受其他测试污染并写真实会话目录
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    var sess = try Session.fresh(a, "/tmp");
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, sess.path) catch {};
        if (std.fmt.allocPrint(a, "{s}/sessions/--tmp--", .{tmp_path})) |sd1| {
            std.Io.Dir.cwd().deleteDir(util.io, sd1) catch {};
        } else |_| {}
        if (std.fmt.allocPrint(a, "{s}/sessions", .{tmp_path})) |sd2| {
            std.Io.Dir.cwd().deleteDir(util.io, sd2) catch {};
        } else |_| {}
    }
    try sess.saveMessage(&.{ .role = "user", .content = "hi" });
    try sess.saveMessage(&.{ .role = "assistant", .content = "hello", .tool_calls = &.{.{ .id = "c1", .name = "bash", .args = "{}" }}, .reasoning = "cot" });
    try sess.saveMessage(&.{ .role = "tool", .content = "out", .tool_call_id = "c1" });

    const msgs = try sess.loadMessages();
    try t.expectEqual(@as(usize, 3), msgs.len);
    try t.expectEqualStrings("hi", msgs[0].content);
    try t.expectEqualStrings("bash", msgs[1].tool_calls.?[0].name);
    try t.expectEqualStrings("cot", msgs[1].reasoning.?);
    try t.expectEqualStrings("c1", msgs[2].tool_call_id.?);
}

test "model-visible reconstruct drops system and keeps user/assistant/tool" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    var sess = try Session.fresh(a, "/tmp");
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, sess.path) catch {};
        if (std.fmt.allocPrint(a, "{s}/sessions/--tmp--", .{tmp_path})) |sd1| {
            std.Io.Dir.cwd().deleteDir(util.io, sd1) catch {};
        } else |_| {}
        if (std.fmt.allocPrint(a, "{s}/sessions", .{tmp_path})) |sd2| {
            std.Io.Dir.cwd().deleteDir(util.io, sd2) catch {};
        } else |_| {}
    }
    try sess.saveMessage(&.{ .role = "system", .content = "you are piz" });
    try sess.saveMessage(&.{ .role = "user", .content = "hi" });
    try sess.saveMessage(&.{ .role = "assistant", .content = "ok" });
    try sess.saveMessage(&.{ .role = "tool", .content = "out", .tool_call_id = "c1" });

    const vis = try sess.reconstructModelVisible();
    try t.expectEqual(@as(usize, 3), vis.len);
    try t.expectEqualStrings("user", vis[0].role);
    try t.expectEqualStrings("assistant", vis[1].role);
    try t.expectEqualStrings("tool", vis[2].role);
    try t.expect(Session.isModelVisibleRole("user"));
    try t.expect(!Session.isModelVisibleRole("system"));
}

test "session title + list + setTitle" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 注:Environ.Map.put 覆盖时 free 旧值,恢复旧值会 UAF——测试内只覆盖不恢复
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    var s1 = try Session.freshTitle(a, "/tmp", "my title");
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, s1.path) catch {};
        if (std.fmt.allocPrint(a, "{s}/sessions/--tmp--", .{tmp_path})) |sd1| {
            std.Io.Dir.cwd().deleteDir(util.io, sd1) catch |e| std.debug.print("[sess-test] deleteDir1 {s}\n", .{@errorName(e)});
        } else |_| {}
        if (std.fmt.allocPrint(a, "{s}/sessions", .{tmp_path})) |sd2| {
            std.Io.Dir.cwd().deleteDir(util.io, sd2) catch |e| std.debug.print("[sess-test] deleteDir2 {s}\n", .{@errorName(e)});
        } else |_| {}
    }
    try s1.saveMessage(&.{ .role = "user", .content = "hi" });
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};
    const s2 = try Session.fresh(a, "/tmp");
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, s2.path) catch {};
    }

    // open 读回 title
    const opened = try Session.open(a, s1.path);
    try t.expectEqualStrings("my title", opened.title.?);
    // findLatest 返回最新
    const latest = (try Session.findLatest(a, "/tmp")).?;
    try t.expectEqualStrings(s2.path, latest.path);
    // list 降序
    const all = try Session.list(a, "/tmp");
    try t.expectEqual(@as(usize, 2), all.len);
    try t.expectEqualStrings(s2.path, all[0].path);
    try t.expectEqualStrings(s1.path, all[1].path);
    // setTitle 重写元信息
    try s1.setTitle("renamed");
    const opened2 = try Session.open(a, s1.path);
    try t.expectEqualStrings("renamed", opened2.title.?);

    // 落盘的标题裁到 MAX_TITLE_BYTES:无界标题会一路带进内存和每个响应
    try s1.setTitle("L" ** 2000);
    try t.expectEqual(@as(usize, MAX_TITLE_BYTES), (try Session.open(a, s1.path)).title.?.len);

    // 中文不能切在多字节序列中间 —— 那样读回来是非法 UTF-8,JSON 也就坏了
    try s1.setTitle("标题" ** 500);
    const zh = (try Session.open(a, s1.path)).title.?;
    try t.expect(zh.len <= MAX_TITLE_BYTES);
    try t.expect(std.unicode.utf8ValidateSlice(zh));

    // 上限内原样保留
    try s1.setTitle("正常标题");
    try t.expectEqualStrings("正常标题", (try Session.open(a, s1.path)).title.?);
}

test "session truncate" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    var sess = try Session.fresh(a, "/tmp");
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, sess.path) catch {};
        // deleteTree 对空目录链静默失败,手动清 sessions 目录
        if (std.fmt.allocPrint(a, "{s}/sessions/--tmp--", .{tmp_path})) |sd1| {
            std.Io.Dir.cwd().deleteDir(util.io, sd1) catch |e| std.debug.print("[sess-test] deleteDir1 {s}\n", .{@errorName(e)});
        } else |_| {}
        if (std.fmt.allocPrint(a, "{s}/sessions", .{tmp_path})) |sd2| {
            std.Io.Dir.cwd().deleteDir(util.io, sd2) catch |e| std.debug.print("[sess-test] deleteDir2 {s}\n", .{@errorName(e)});
        } else |_| {}
    }
    try sess.saveMessage(&.{ .role = "user", .content = "q1" });
    try sess.saveMessage(&.{ .role = "assistant", .content = "a1" });
    try sess.saveMessage(&.{ .role = "user", .content = "q2" });
    try sess.saveMessage(&.{ .role = "assistant", .content = "a2" });

    try sess.truncate(2); // 保留元信息 + 前 2 条
    const msgs = try sess.loadMessages();
    try t.expectEqual(@as(usize, 2), msgs.len);
    try t.expectEqualStrings("q1", msgs[0].content);
    try t.expectEqualStrings("a1", msgs[1].content);
    // 截断后追加仍正常
    try sess.saveMessage(&.{ .role = "user", .content = "q3" });
    const msgs2 = try sess.loadMessages();
    try t.expectEqual(@as(usize, 3), msgs2.len);
    try t.expectEqualStrings("q3", msgs2[2].content);
}

test "full-file rewrites replace atomically, never truncate in place" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    var sess = try Session.fresh(a, "/tmp");
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, sess.path) catch {};
        if (std.fmt.allocPrint(a, "{s}/sessions/--tmp--", .{tmp_path})) |sd1| {
            std.Io.Dir.cwd().deleteDir(util.io, sd1) catch {};
        } else |_| {}
        if (std.fmt.allocPrint(a, "{s}/sessions", .{tmp_path})) |sd2| {
            std.Io.Dir.cwd().deleteDir(util.io, sd2) catch {};
        } else |_| {}
    }
    try sess.saveMessage(&.{ .role = "user", .content = "q1" });
    try sess.saveMessage(&.{ .role = "assistant", .content = "a1" });
    try sess.saveMessage(&.{ .role = "user", .content = "q2" });

    // 原地覆盖会保持 inode 不变;原子替换必然换掉 inode。
    // 这是「实现真的走了临时文件 + rename」唯一能从外部观测的签名 ——
    // 直写 writeFile 的话磁盘满/被 kill 会留下截断的文件,用户一次 /undo 丢光历史。
    const ino_before = (try std.Io.Dir.cwd().statFile(util.io, sess.path, .{})).inode;
    try sess.truncate(2);
    const ino_after = (try std.Io.Dir.cwd().statFile(util.io, sess.path, .{})).inode;
    try t.expect(ino_before != ino_after);

    // 内容仍然正确,且没有 .tmp 残留
    const msgs = try sess.loadMessages();
    try t.expectEqual(@as(usize, 2), msgs.len);
    try t.expectEqualStrings("q1", msgs[0].content);
    const leftover = try std.fmt.allocPrint(a, "{s}.tmp", .{sess.path});
    try t.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(util.io, leftover, .{}));

    // setTitle 走同一条原子路径
    const ino2 = (try std.Io.Dir.cwd().statFile(util.io, sess.path, .{})).inode;
    try sess.setTitle("renamed");
    const ino3 = (try std.Io.Dir.cwd().statFile(util.io, sess.path, .{})).inode;
    try t.expect(ino2 != ino3);
    try t.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(util.io, leftover, .{}));
}

test "session listing, latest and lookup by id" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    // 造一个更早的会话文件(手写,时间戳文件名),验证 list 按 mtime 降序
    const slug_dir = try std.fmt.allocPrint(a, "{s}/sessions/--tmp--", .{tmp_path});
    try std.Io.Dir.cwd().createDirPath(util.io, slug_dir);
    const pi_file = try std.fmt.allocPrint(a, "{s}/1700000000000.jsonl", .{slug_dir});
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = pi_file, .data = "{\"cwd\":\"/tmp\",\"started\":1}\n{\"role\":\"user\",\"content\":\"older\"}\n" });

    var s1 = try Session.fresh(a, "/tmp");
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, s1.path) catch {};
        std.Io.Dir.cwd().deleteFile(util.io, pi_file) catch {};
        if (std.fmt.allocPrint(a, "{s}/sessions/--tmp--", .{tmp_path})) |sd1| {
            std.Io.Dir.cwd().deleteDir(util.io, sd1) catch {};
        } else |_| {}
        if (std.fmt.allocPrint(a, "{s}/sessions", .{tmp_path})) |sd2| {
            std.Io.Dir.cwd().deleteDir(util.io, sd2) catch {};
        } else |_| {}
    }
    try s1.saveMessage(&.{ .role = "user", .content = "piz hello" });

    // list 看到两个会话,按 mtime 降序(最新在前)
    const all = try Session.list(a, "/tmp");
    try t.expectEqual(@as(usize, 2), all.len);
    try t.expectEqualStrings(s1.path, all[0].path); // piz 最新在前
    // findLatest 命中 piz 会话,消息完整
    var latest = (try Session.findLatest(a, "/tmp")).?;
    const msgs = try latest.loadMessages();
    try t.expectEqual(@as(usize, 1), msgs.len);
    try t.expectEqualStrings("piz hello", msgs[0].content);
    // findById:带/不带 .jsonl 均可命中
    const b1 = std.fs.path.basename(s1.path);
    const id1 = b1[0 .. b1.len - ".jsonl".len];
    try t.expectEqualStrings(s1.path, (try Session.findById(a, "/tmp", id1)).?.path);
    try t.expectEqualStrings(s1.path, (try Session.findById(a, "/tmp", b1)).?.path);
    try t.expect((try Session.findById(a, "/tmp", "nope")) == null);
}

test "session fork tree" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    var sess = try Session.fresh(a, "/tmp");
    try sess.saveMessage(&.{ .role = "user", .content = "q1" });
    try sess.saveMessage(&.{ .role = "assistant", .content = "a1" });
    try sess.saveMessage(&.{ .role = "user", .content = "q2" });
    try sess.saveMessage(&.{ .role = "assistant", .content = "a2" });

    // 落盘带 id/parent_id,链式相接
    const raw_content = try std.Io.Dir.cwd().readFileAlloc(util.io, sess.path, a, .limited(4096));
    // 首行是元信息,随后每条消息各一行(4 条消息 + meta + 尾随换行)
    try t.expect(std.mem.indexOf(u8, raw_content, "\"role\":\"user\"") != null);
    try t.expect(std.mem.indexOf(u8, raw_content, "\"parent_id\":") != null);
    const msgs = try sess.loadMessages();
    try t.expect(msgs[0].id != null);
    try t.expect(msgs[1].parent_id != null);
    try t.expectEqualStrings(msgs[0].id.?, msgs[1].parent_id.?);
    try t.expectEqualStrings(msgs[2].parent_id.?, msgs[1].id.?);
    // 续写接续最后一条
    try sess.saveMessage(&.{ .role = "user", .content = "q3" });
    const msgs2 = try sess.loadMessages();
    try t.expectEqualStrings(msgs[3].id.?, msgs2[4].parent_id.?);

    // fork:前 2 条拷贝到新会话,续写 parent 接第 2 条
    var branch = try sess.fork(2);
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, branch.path) catch {};
        std.Io.Dir.cwd().deleteFile(util.io, sess.path) catch {};
        if (std.fmt.allocPrint(a, "{s}/sessions/--tmp--", .{tmp_path})) |sd1| {
            std.Io.Dir.cwd().deleteDir(util.io, sd1) catch {};
        } else |_| {}
        if (std.fmt.allocPrint(a, "{s}/sessions", .{tmp_path})) |sd2| {
            std.Io.Dir.cwd().deleteDir(util.io, sd2) catch {};
        } else |_| {}
    }
    const bmsgs = try branch.loadMessages();
    try t.expectEqual(@as(usize, 2), bmsgs.len);
    try t.expectEqualStrings("q1", bmsgs[0].content);
    try t.expectEqualStrings("a1", bmsgs[1].content);
    try branch.saveMessage(&.{ .role = "user", .content = "branch-q" });
    const bmsgs2 = try branch.loadMessages();
    try t.expectEqual(@as(usize, 3), bmsgs2.len);
    try t.expectEqualStrings(bmsgs[1].id.?, bmsgs2[2].parent_id.?); // 分支接第 2 条
}

test "web session rewrite is atomic, 0600, and tolerates a corrupt line" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    const proj = "/tmp/webproj";
    const msgs = [_]ai.Message{
        .{ .role = "user", .content = "q1" },
        .{ .role = "assistant", .content = "a1" },
    };
    try saveWeb(a, proj, "s1", "m", true, "t1", &msgs);

    const dir = try webDirPublic(a, proj);
    const path = try util.joinPath(a, dir, "s1.jsonl");
    const tmpfile = try std.fmt.allocPrint(a, "{s}.tmp", .{path});
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, path) catch {};
        std.Io.Dir.cwd().deleteFile(util.io, tmpfile) catch {};
    }

    // 会话里是完整对话内容,权限必须是 0600 —— 不能跟目录默认权限走。
    const st = try std.Io.Dir.cwd().statFile(util.io, path, .{});
    try t.expectEqual(@as(u32, 0o600), @as(u32, @intFromEnum(st.permissions)) & 0o777);

    // web 会话每轮都全量重写。原地覆盖会保持 inode;原子替换必然换掉 ——
    // 直写的话写到一半被 kill 就是整份历史被截断。
    const ino1 = st.inode;
    const msgs2 = msgs ++ [_]ai.Message{.{ .role = "user", .content = "q2" }};
    try saveWeb(a, proj, "s1", "m", true, "t1", &msgs2);
    const ino2 = (try std.Io.Dir.cwd().statFile(util.io, path, .{})).inode;
    try t.expect(ino1 != ino2);
    // 临时文件不许残留
    try t.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(util.io, tmpfile, .{}));

    const loaded = (try loadWeb(a, proj, "s1")).?;
    try t.expectEqual(@as(usize, 3), loaded.msgs.len);
    try t.expectEqualStrings("q2", loaded.msgs[2].content);

    // 末行被截断(崩溃留下的形态):跳过坏行,前面的消息仍读得回来,不整体失败
    const raw = try std.Io.Dir.cwd().readFileAlloc(util.io, path, a, .limited(1 << 20));
    const cut = try std.fmt.allocPrint(a, "{s}{{\"role\":\"assistant\",\"cont", .{raw});
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = path, .data = cut });
    const after = (try loadWeb(a, proj, "s1")).?;
    try t.expectEqual(@as(usize, 3), after.msgs.len);
}
