// webplugins.zig — Web 前端插件发现与静态资源服务。
// 包在 pkg.json 中声明:
//   {"name":"demo","version":"1.0.0","web":{"entry":"web/index.js","style":"web/style.css"}}
// 仅服务包内 web/ 目录；项目级包覆盖同名用户级包。
const std = @import("std");
const util = @import("util.zig");
const pkgs = @import("pkgs.zig");

pub const Asset = struct {
    data: []u8,
    content_type: []const u8,
};

const Descriptor = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    entry: []const u8,
    style: ?[]const u8,
};

fn safeId(id: []const u8) bool {
    if (id.len == 0 or std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    }
    return true;
}

fn safeAssetPath(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "web/") or path.len <= 4) return false;
    if (std.mem.indexOfAny(u8, path, "\\%?#\x00") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".mjs")) return "text/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    if (std.mem.endsWith(u8, path, ".woff2")) return "font/woff2";
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    return "application/octet-stream";
}

fn containsId(items: []const Descriptor, id: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return true;
    return false;
}

fn readDescriptor(alloc: std.mem.Allocator, pkg_dir: []const u8, id: []const u8) !?Descriptor {
    if (!safeId(id)) return null;
    const manifest_path = try util.joinPath(alloc, pkg_dir, "pkg.json");
    const raw = std.Io.Dir.cwd().readFileAlloc(util.io, manifest_path, alloc, .limited(256 * 1024)) catch return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{}) catch return null;
    if (root != .object) return null;
    const web = root.object.get("web") orelse return null;
    if (web != .object) return null;
    const entry_v = web.object.get("entry") orelse return null;
    if (entry_v != .string or !safeAssetPath(entry_v.string)) return null;
    if (!std.mem.endsWith(u8, entry_v.string, ".js") and !std.mem.endsWith(u8, entry_v.string, ".mjs")) return null;
    const entry_path = try util.joinPath(alloc, pkg_dir, entry_v.string);
    if (!util.fileExists(entry_path)) return null;

    var style: ?[]const u8 = null;
    if (web.object.get("style")) |style_v| {
        if (style_v != .string or !safeAssetPath(style_v.string) or !std.mem.endsWith(u8, style_v.string, ".css")) return null;
        const style_path = try util.joinPath(alloc, pkg_dir, style_v.string);
        if (!util.fileExists(style_path)) return null;
        style = try alloc.dupe(u8, style_v.string);
    }
    const display = if (root.object.get("name")) |v| (if (v == .string and v.string.len > 0) v.string else id) else id;
    const version = if (root.object.get("version")) |v| (if (v == .string) v.string else "") else "";
    return .{
        .id = try alloc.dupe(u8, id),
        .name = try alloc.dupe(u8, display),
        .version = try alloc.dupe(u8, version),
        .entry = try alloc.dupe(u8, entry_v.string),
        .style = style,
    };
}

fn scanRoot(alloc: std.mem.Allocator, out: *std.array_list.Managed(Descriptor), root: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(util.io, root, .{ .iterate = true }) catch return;
    defer dir.close(util.io);
    var it = dir.iterate();
    while (try it.next(util.io)) |entry| {
        if (entry.kind != .directory or containsId(out.items, entry.name)) continue;
        const pkg_dir = try util.joinPath(alloc, root, entry.name);
        if (try readDescriptor(alloc, pkg_dir, entry.name)) |desc| try out.append(desc);
    }
}

/// 返回浏览器可加载的插件清单。项目级插件优先于同名用户级插件。
pub fn manifestJson(out_alloc: std.mem.Allocator, project_cwd: ?[]const u8) ![]u8 {
    var arena = util.Arena.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var items = std.array_list.Managed(Descriptor).init(alloc);
    const project_root = try pkgs.rootDir(alloc, .project, project_cwd);
    try scanRoot(alloc, &items, project_root);
    const user_root = try pkgs.rootDir(alloc, .user, null);
    try scanRoot(alloc, &items, user_root);

    var out = std.Io.Writer.Allocating.init(out_alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"apiVersion\":1,\"plugins\":[");
    for (items.items, 0..) |item, i| {
        if (i > 0) try out.writer.writeByte(',');
        try out.writer.print("{{\"id\":{s},\"name\":{s},\"version\":{s},\"entry\":\"/api/plugins/assets/{s}/{s}\",\"base\":\"/api/plugins/assets/{s}/web/\"", .{
            try util.jsonString(alloc, item.id),
            try util.jsonString(alloc, item.name),
            try util.jsonString(alloc, item.version),
            item.id,
            item.entry,
            item.id,
        });
        if (item.style) |style| try out.writer.print(",\"style\":\"/api/plugins/assets/{s}/{s}\"", .{ item.id, style });
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn webEnabled(alloc: std.mem.Allocator, pkg_dir: []const u8, id: []const u8) !bool {
    return (try readDescriptor(alloc, pkg_dir, id)) != null;
}

fn readFromRoot(out_alloc: std.mem.Allocator, alloc: std.mem.Allocator, root: []const u8, id: []const u8, rel: []const u8) !?Asset {
    const pkg_dir = try util.joinPath(alloc, root, id);
    if (!try webEnabled(alloc, pkg_dir, id)) return null;
    const full = try util.joinPath(alloc, pkg_dir, rel);
    // 不跟随符号链接。字符串层已经拦掉 `..`/`%`/绝对路径,但包目录里的一个
    // 指向 ~/.piz/models.json 的符号链接照样能把 apiKey 读出来 ——
    // 实测复现过。ws 白名单封住了「任意包根」,这里封住「已注册项目内的恶意包」。
    var f = std.Io.Dir.cwd().openFile(util.io, full, .{ .follow_symlinks = false }) catch return null;
    defer f.close(util.io);
    var rbuf: [8192]u8 = undefined;
    var r = f.reader(util.io, &rbuf);
    const data = r.interface.allocRemaining(out_alloc, .limited(8 * 1024 * 1024)) catch return null;
    return .{ .data = data, .content_type = contentType(rel) };
}

/// 读取 /api/plugins/assets/<package>/<web/path>。拒绝编码路径与目录穿越。
pub fn readAsset(out_alloc: std.mem.Allocator, project_cwd: ?[]const u8, target: []const u8) !?Asset {
    const prefix = "/api/plugins/assets/";
    if (!std.mem.startsWith(u8, target, prefix)) return null;
    var path = target[prefix.len..];
    if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return null;
    const id = path[0..slash];
    const rel = path[slash + 1 ..];
    if (!safeId(id) or !safeAssetPath(rel)) return null;

    var arena = util.Arena.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const project_root = try pkgs.rootDir(alloc, .project, project_cwd);
    if (try readFromRoot(out_alloc, alloc, project_root, id, rel)) |asset| return asset;
    const user_root = try pkgs.rootDir(alloc, .user, null);
    return readFromRoot(out_alloc, alloc, user_root, id, rel);
}

test "web plugin manifest and confined assets" {
    const t = std.testing;
    try util.testInit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const project = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    const pkg = try std.fmt.allocPrint(a, "{s}/.piz/packages/demo", .{project});
    try std.Io.Dir.cwd().createDirPath(util.io, try util.joinPath(a, pkg, "web"));
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = try util.joinPath(a, pkg, "pkg.json"), .data = "{\"name\":\"Demo\",\"version\":\"1.2.3\",\"web\":{\"entry\":\"web/index.js\",\"style\":\"web/style.css\"}}" });
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = try util.joinPath(a, pkg, "web/index.js"), .data = "export default () => {};" });
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = try util.joinPath(a, pkg, "web/style.css"), .data = ".demo{}" });

    const manifest = try manifestJson(t.allocator, project);
    defer t.allocator.free(manifest);
    try t.expect(std.mem.indexOf(u8, manifest, "\"apiVersion\":1") != null);
    try t.expect(std.mem.indexOf(u8, manifest, "\"id\":\"demo\"") != null);
    try t.expect(std.mem.indexOf(u8, manifest, "/api/plugins/assets/demo/web/index.js") != null);

    const asset = (try readAsset(t.allocator, project, "/api/plugins/assets/demo/web/index.js?ws=x")).?;
    defer t.allocator.free(asset.data);
    try t.expectEqualStrings("text/javascript; charset=utf-8", asset.content_type);
    try t.expectEqualStrings("export default () => {};", asset.data);
    try t.expect((try readAsset(t.allocator, project, "/api/plugins/assets/demo/web/../pkg.json")) == null);
    try t.expect((try readAsset(t.allocator, project, "/api/plugins/assets/demo/%2e%2e/pkg.json")) == null);

    // 符号链接不许跟随。字符串层拦得住 `..` 与 `%2e%2e`,但包目录里一个指向
    // ~/.piz/models.json 的链接照样能把 apiKey 读出来 —— 实测复现过一次
    // 「无 token 的 GET 拿到 apiKey」。
    const secret = try std.fmt.allocPrint(a, "{s}/secret.txt", .{project});
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = secret, .data = "sk-MUST-NOT-LEAK" });
    const link = try util.joinPath(a, pkg, "web/leak");
    try std.Io.Dir.cwd().symLink(util.io, secret, link, .{});
    defer std.Io.Dir.cwd().deleteFile(util.io, link) catch {};
    try t.expect((try readAsset(t.allocator, project, "/api/plugins/assets/demo/web/leak")) == null);
}
