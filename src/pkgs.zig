// pkgs.zig — 资源包管理(对齐 pi packages 语义)。
// 包 = 目录,可含 skills/、prompts/、AGENTS.md 或 pkg.json 的 web 插件声明。
// 安装位置:用户级 ~/.piz/packages/<name>/ 或项目级 .piz/packages/<name>/。
const std = @import("std");
const util = @import("util.zig");
const toolsmod = @import("tools.zig");

pub const Scope = enum { user, project };

/// 包根目录(用户级或项目级)。
pub fn rootDir(alloc: std.mem.Allocator, scope: Scope, project_cwd: ?[]const u8) ![]u8 {
    return switch (scope) {
        .user => blk: {
            const cfg_dir = try util.configDir(alloc);
            defer alloc.free(cfg_dir);
            break :blk try util.joinPath(alloc, cfg_dir, "packages");
        },
        .project => blk: {
            const cwd = project_cwd orelse ".";
            const dot_piz = try util.joinPath(alloc, cwd, util.PROJECT_DIR);
            defer alloc.free(dot_piz);
            break :blk try util.joinPath(alloc, dot_piz, "packages");
        },
    };
}

/// 递归复制目录树:src_dir/sub → dst_abs/child(绝对路径)。
fn copyTree(alloc: std.mem.Allocator, src_dir: std.Io.Dir, sub: []const u8, dst_abs: []const u8) !void {
    // sub 为空时直接迭代 src_dir 本身(openDir("") 会 ENOENT)
    var d = if (sub.len == 0) src_dir else (try src_dir.openDir(util.io, sub, .{ .iterate = true }));
    defer if (sub.len > 0) d.close(util.io);
    var it = d.iterate();
    while (try it.next(util.io)) |entry| {
        const child = try util.joinPath(alloc, sub, entry.name);
        defer alloc.free(child);
        if (entry.kind == .directory) {
            try std.Io.Dir.cwd().createDirPath(util.io, try util.joinPath(alloc, dst_abs, child));
            try copyTree(alloc, src_dir, child, dst_abs);
        } else if (entry.kind == .file) {
            try std.Io.Dir.copyFile(src_dir, child, std.Io.Dir.cwd(), try util.joinPath(alloc, dst_abs, child), util.io, .{ .make_path = true });
        }
    }
}

/// 递归删除目录树(0.16 std deleteTree 对部分目录静默失败,自实现可靠版)。
fn removeTree(dir: std.Io.Dir, sub: []const u8) !void {
    var d = dir.openDir(util.io, sub, .{ .iterate = true }) catch {
        dir.deleteFile(util.io, sub) catch |err| util.debugCatch("pkg.rm.file", err);
        return;
    };
    var it = d.iterate();
    while (try it.next(util.io)) |entry| {
        if (entry.kind == .directory) {
            try removeTree(d, entry.name);
        } else {
            d.deleteFile(util.io, entry.name) catch |err| util.debugCatch("pkg.rm.child", err);
        }
    }
    d.close(util.io);
    dir.deleteDir(util.io, sub) catch |err| util.debugCatch("pkg.rm.dir", err);
}

/// 校验源目录是否为合法包(资源目录、AGENTS.md 或 pkg.json web 声明)。
fn validatePackage(alloc: std.mem.Allocator, _: std.Io.Dir, src: []const u8) !bool {
    const s = try std.fmt.allocPrint(alloc, "{s}/skills", .{src});
    defer alloc.free(s);
    var has_skills = false;
    if (std.Io.Dir.cwd().openDir(util.io, s, .{})) |_| {
        has_skills = true;
    } else |_| {}
    const p = try std.fmt.allocPrint(alloc, "{s}/prompts", .{src});
    defer alloc.free(p);
    var has_prompts = false;
    if (std.Io.Dir.cwd().openDir(util.io, p, .{})) |_| {
        has_prompts = true;
    } else |_| {}
    const a = try std.fmt.allocPrint(alloc, "{s}/AGENTS.md", .{src});
    defer alloc.free(a);
    var has_agents = false;
    if (std.Io.Dir.cwd().openFile(util.io, a, .{})) |f| {
        f.close(util.io);
        has_agents = true;
    } else |_| {}
    const manifest = try std.fmt.allocPrint(alloc, "{s}/pkg.json", .{src});
    defer alloc.free(manifest);
    var has_web = false;
    if (std.Io.Dir.cwd().readFileAlloc(util.io, manifest, alloc, .limited(256 * 1024))) |raw| {
        defer alloc.free(raw);
        if (std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{})) |root| {
            has_web = root == .object and root.object.get("web") != null;
        } else |_| {}
    } else |_| {}
    return has_skills or has_prompts or has_agents or has_web;
}

/// 一条包声明的生命周期钩子。
pub const DeclaredHook = struct {
    event: []const u8,
    command: []const u8,
};

/// 读出包目录声明的 events 钩子。
///
/// 这些命令会由 events.Bus 以 `bash -c` 执行,`startup` 钩子在下次启动时立刻跑。
/// 装包因此等于授权本机命令执行 —— 装之前得让用户看见到底授权了什么。
/// 解析失败/无声明都返回空切片(不是错误:大多数包没有钩子)。
pub const DeclaredTool = struct {
    name: []const u8,
    description: []const u8,
    command: []const u8,
    schema: []const u8,
};

fn toolNameOk(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (!std.ascii.isAlphabetic(name[0])) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
}

/// 读 pkg.json 的 `tools[]`。装包确认与运行时加载共用。
pub fn declaredTools(alloc: std.mem.Allocator, pkg_dir: []const u8) ![]DeclaredTool {
    const path = try util.joinPath(alloc, pkg_dir, "pkg.json");
    defer alloc.free(path);
    const raw = std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(256 * 1024)) catch return &.{};
    defer alloc.free(raw);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return &.{};
    defer parsed.deinit();
    const tools_v = parsed.value.object.get("tools") orelse return &.{};
    if (tools_v != .array) return &.{};
    var out = std.array_list.Managed(DeclaredTool).init(alloc);
    for (tools_v.array.items) |item| {
        if (item != .object) continue;
        const name = if (item.object.get("name")) |v| (if (v == .string) v.string else "") else "";
        const desc = if (item.object.get("description")) |v| (if (v == .string) v.string else "") else "";
        const cmd = if (item.object.get("command")) |v| (if (v == .string) v.string else "") else "";
        if (!toolNameOk(name) or cmd.len == 0) continue;
        var schema: []const u8 = toolsmod.EMPTY_SCHEMA;
        if (item.object.get("schema")) |sv| {
            schema = stringifyJson(alloc, sv) catch toolsmod.EMPTY_SCHEMA;
        }
        try out.append(.{
            .name = try alloc.dupe(u8, name),
            .description = try alloc.dupe(u8, if (desc.len > 0) desc else name),
            .command = try alloc.dupe(u8, cmd),
            .schema = if (schema.ptr == toolsmod.EMPTY_SCHEMA.ptr) schema else schema,
        });
    }
    return out.toOwnedSlice();
}

fn stringifyJson(alloc: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    var stw = std.Io.Writer.Allocating.init(alloc);
    errdefer stw.deinit();
    try std.json.Stringify.value(v, .{}, &stw.writer);
    return stw.toOwnedSlice();
}

/// 扫用户级 + 项目级已装包,合成可调的 Tool 表。核心/插件同名的丢掉。
pub fn loadPkgTools(alloc: std.mem.Allocator, project_cwd: []const u8) ![]toolsmod.Tool {
    var out = std.array_list.Managed(toolsmod.Tool).init(alloc);
    const scopes = [_]Scope{ .user, .project };
    for (scopes) |scope| {
        const infos = list(alloc, scope, project_cwd) catch continue;
        for (infos) |info| {
            const dts = declaredTools(alloc, info.path) catch continue;
            for (dts) |dt| {
                if (toolsmod.find(dt.name) != null) continue;
                var dup = false;
                for (out.items) |t| {
                    if (std.mem.eql(u8, t.name, dt.name)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                try out.append(.{
                    .name = dt.name,
                    .desc = dt.description,
                    .schema = dt.schema,
                    .handler = toolsmod.pkgToolStub,
                    .payload = dt.command,
                });
            }
        }
    }
    return out.toOwnedSlice();
}

pub fn declaredHooks(alloc: std.mem.Allocator, pkg_dir: []const u8) ![]DeclaredHook {
    var out = std.array_list.Managed(DeclaredHook).init(alloc);
    const manifest = try util.joinPath(alloc, pkg_dir, "pkg.json");
    defer alloc.free(manifest);
    const raw = std.Io.Dir.cwd().readFileAlloc(util.io, manifest, alloc, .limited(256 * 1024)) catch
        return out.toOwnedSlice();
    defer alloc.free(raw);
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{}) catch
        return out.toOwnedSlice();
    if (root != .object) return out.toOwnedSlice();
    const exts = root.object.get("extensions") orelse return out.toOwnedSlice();
    if (exts != .array) return out.toOwnedSlice();
    for (exts.array.items) |ext| {
        if (ext != .object) continue;
        const events = ext.object.get("events") orelse continue;
        if (events != .object) continue;
        var it = events.object.iterator();
        while (it.next()) |entry| {
            const v = entry.value_ptr.*;
            if (v != .string or v.string.len == 0) continue;
            try out.append(.{
                .event = try alloc.dupe(u8, entry.key_ptr.*),
                .command = try alloc.dupe(u8, v.string),
            });
        }
    }
    return out.toOwnedSlice();
}

/// 安装源类型:本地路径或 git 仓库。
pub const Source = union(enum) { path: []const u8, git: []const u8 };

/// 检测安装源:git: 前缀、https?://(github/gitlab) 或 git@ 视为 git,其余为路径。
pub fn detectSource(src: []const u8) Source {
    if (std.mem.startsWith(u8, src, "git:")) return .{ .git = src[4..] };
    if (std.mem.startsWith(u8, src, "git@") or std.mem.endsWith(u8, src, ".git")) return .{ .git = src };
    if (std.mem.startsWith(u8, src, "https://") or std.mem.startsWith(u8, src, "http://")) {
        if (std.mem.indexOf(u8, src, "github.com/") != null or std.mem.indexOf(u8, src, "gitlab.com/") != null or std.mem.endsWith(u8, src, ".git")) {
            return .{ .git = src };
        }
    }
    return .{ .path = src };
}

/// git clone 到临时目录,返回目录路径。
fn cloneGit(alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    const ts = @divTrunc(std.Io.Clock.now(.real, util.io).nanoseconds, std.time.ns_per_ms);
    const tmp = try std.fmt.allocPrint(alloc, "/tmp/piz-git-{d}", .{ts});
    std.Io.Dir.cwd().deleteTree(util.io, tmp) catch {};
    var child = try std.process.spawn(util.io, .{
        .argv = &.{ "git", "clone", "--depth", "1", url, tmp },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = child.wait(util.io) catch std.process.Child.Term{ .exited = 1 };
    return switch (term) {
        .exited => |code| if (code == 0) tmp else error.GitCloneFailed,
        else => error.GitCloneFailed,
    };
}

/// 读包目录 pkg.json 的 name 字段(git 源装名优先于此,胜于 URL basename)。
/// 名字须像 basename:含 '/' 或 '..' 者不受,返 null 以示回退。
fn pkgJsonName(alloc: std.mem.Allocator, pkg_dir: []const u8) ?[]u8 {
    const path = util.joinPath(alloc, pkg_dir, "pkg.json") catch return null;
    defer alloc.free(path);
    const raw = std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(256 * 1024)) catch return null;
    defer alloc.free(raw);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const nv = parsed.value.object.get("name") orelse return null;
    if (nv != .string) return null;
    const n = nv.string;
    if (n.len == 0 or n.len > 128) return null;
    if (std.mem.indexOfScalar(u8, n, '/') != null or std.mem.indexOf(u8, n, "..") != null) return null;
    return alloc.dupe(u8, n) catch null;
}

/// 安装包:复制 src 目录到 packages/<basename>/。git 源先 clone。返回安装路径。
/// marketplace 解析:install "name@repo" —— repo 为 git 源或本地目录,
/// 含 .claude-plugin/marketplace.json(catalog: {"plugins": {"name": {"source": "..."}}})。
/// 解析后返回真实源(alloc)。
pub fn resolveMarketplace(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, src, "@") orelse return alloc.dupe(u8, src);
    const name = src[0..at];
    const repo = src[at + 1 ..];
    if (name.len == 0 or repo.len == 0) return alloc.dupe(u8, src);
    // clone/打开 catalog
    var tmp: ?[]u8 = null;
    defer if (tmp) |t| std.Io.Dir.cwd().deleteTree(util.io, t) catch {};
    const repo_local: []const u8 = switch (detectSource(repo)) {
        .git => |url| blk: {
            tmp = try cloneGit(alloc, url);
            break :blk tmp.?;
        },
        .path => |pth| pth,
    };
    const cat_path = try util.joinPath(alloc, repo_local, ".claude-plugin/marketplace.json");
    defer alloc.free(cat_path);
    const content = std.Io.Dir.cwd().readFileAlloc(util.io, cat_path, alloc, .limited(4 * 1024 * 1024)) catch return alloc.dupe(u8, src);
    defer alloc.free(content);
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, content, .{}) catch return alloc.dupe(u8, src);
    if (root == .object) {
        if (root.object.get("plugins")) |pl| {
            if (pl == .object) {
                if (pl.object.get(name)) |entry| {
                    if (entry == .object) {
                        if (entry.object.get("source")) |sv| {
                            if (sv == .string) return alloc.dupe(u8, sv.string);
                        }
                    }
                }
            }
        }
    }
    return error.PluginNotFound;
}

pub fn install(alloc: std.mem.Allocator, src: []const u8, scope: Scope, project_cwd: ?[]const u8) ![]u8 {
    // marketplace 源:name@repo → 解析真实 source,以 catalog 的 name 安装
    if (std.mem.indexOf(u8, src, "@") != null and !std.mem.startsWith(u8, src, "git@")) {
        const at = std.mem.indexOf(u8, src, "@").?;
        const name = src[0..at];
        const resolved = resolveMarketplace(alloc, src) catch return error.PluginNotFound;
        defer alloc.free(resolved);
        return installPathNamed(alloc, resolved, name, src, scope, project_cwd);
    }
    // git 源:clone 到临时目录后按路径安装(包名取 URL 派生的仓库名)
    var git_tmp: ?[]u8 = null;
    defer if (git_tmp) |t| std.Io.Dir.cwd().deleteTree(util.io, t) catch {};
    return switch (detectSource(src)) {
        .git => |url| blk: {
            git_tmp = try cloneGit(alloc, url);
            var u = url;
            while (u.len > 0 and u[u.len - 1] == '/') u = u[0 .. u.len - 1];
            if (std.mem.endsWith(u8, u, ".git")) u = u[0 .. u.len - 4];
            const fallback = std.fs.path.basename(u);
            // 包名以 pkg.json 之 name 为准(作者权柄),无则 URL basename
            const name = pkgJsonName(alloc, git_tmp.?) orelse fallback;
            break :blk try installPathNamed(alloc, git_tmp.?, name, src, scope, project_cwd);
        },
        .path => |p| try installPath(alloc, p, src, scope, project_cwd),
    };
}

/// 安装本地目录(路径源;包名 = pkg.json 之 name,无则目录 basename)。
pub fn installPath(alloc: std.mem.Allocator, local: []const u8, orig_src: []const u8, scope: Scope, project_cwd: ?[]const u8) ![]u8 {
    var clean = local;
    while (clean.len > 1 and clean[clean.len - 1] == '/') clean = clean[0 .. clean.len - 1];
    var base = std.fs.path.basename(clean);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return error.InvalidSource;
    if (pkgJsonName(alloc, clean)) |n| base = n;
    return installPathNamed(alloc, local, base, orig_src, scope, project_cwd);
}

/// 安装本地目录(指定包名,git 源用)。
pub fn installPathNamed(alloc: std.mem.Allocator, local: []const u8, name: []const u8, orig_src: []const u8, scope: Scope, project_cwd: ?[]const u8) ![]u8 {
    var clean = local;
    while (clean.len > 1 and clean[clean.len - 1] == '/') clean = clean[0 .. clean.len - 1];
    const base = try alloc.dupe(u8, name);

    var src_dir = std.Io.Dir.cwd().openDir(util.io, clean, .{ .iterate = true }) catch return error.SourceNotFound;
    defer src_dir.close(util.io);
    if (!try validatePackage(alloc, src_dir, clean)) return error.NotAPackage;

    const root = try rootDir(alloc, scope, project_cwd);
    const dest = try util.joinPath(alloc, root, base);
    if (util.dirExists(dest)) return error.AlreadyInstalled;
    std.Io.Dir.cwd().createDirPath(util.io, dest) catch {};
    errdefer removeTree(std.Io.Dir.cwd(), dest) catch {};

    // 逐资源子目录复制
    try copyTree(alloc, src_dir, "", dest);

    // 依赖检查
    const missing = try missingDeps(alloc, dest, scope, project_cwd);
    if (missing.len > 0) {
        // 依赖缺失:回滚安装,报错列出
        removeTree(std.Io.Dir.cwd(), dest) catch {};
        var msg = std.array_list.Managed(u8).init(alloc);
        defer msg.deinit();
        try msg.appendSlice("missing dependencies: ");
        for (missing, 0..) |d, i| {
            if (i > 0) try msg.appendSlice(", ");
            try msg.appendSlice(d);
        }
        return error.MissingDependency;
    }

    // 记录 manifest
    try manifestAdd(alloc, base, orig_src, scope, project_cwd);
    return dest;
}

/// 读包 pkg.json 的 dependencies 数组;返回未安装的依赖名列表。
pub fn missingDeps(alloc: std.mem.Allocator, pkg_dir: []const u8, scope: Scope, project_cwd: ?[]const u8) ![][]const u8 {
    var out = std.array_list.Managed([]const u8).init(alloc);
    const pkg_json = try util.joinPath(alloc, pkg_dir, "pkg.json");
    const content = std.Io.Dir.cwd().readFileAlloc(util.io, pkg_json, alloc, .limited(64 * 1024)) catch return &.{};
    defer alloc.free(content);
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, content, .{}) catch return &.{};
    if (root != .object) return &.{};
    const deps = root.object.get("dependencies") orelse return &.{};
    if (deps != .array) return &.{};
    const installed = try list(alloc, scope, project_cwd);
    for (deps.array.items) |d| {
        if (d != .string) continue;
        var found = false;
        for (installed) |p| {
            if (std.mem.eql(u8, p.name, d.string)) {
                found = true;
                break;
            }
        }
        if (!found) try out.append(try alloc.dupe(u8, d.string));
    }
    return out.toOwnedSlice();
}

pub const Info = struct {
    name: []const u8,
    path: []const u8,
    skills: usize = 0,
    prompts: usize = 0,
    has_agents: bool = false,
    has_web: bool = false,
};

/// 列出某作用域全部包及其资源统计。
pub fn list(alloc: std.mem.Allocator, scope: Scope, project_cwd: ?[]const u8) ![]Info {
    var out = std.array_list.Managed(Info).init(alloc);
    const root = try rootDir(alloc, scope, project_cwd);
    var dir = std.Io.Dir.cwd().openDir(util.io, root, .{ .iterate = true }) catch return &.{};
    defer dir.close(util.io);
    var it = dir.iterate();
    while (try it.next(util.io)) |entry| {
        if (entry.kind != .directory) continue;
        var info = Info{
            .name = try alloc.dupe(u8, entry.name),
            .path = try util.joinPath(alloc, root, entry.name),
        };
        // skills/*/SKILL.md 计数
        const skills_dir = try util.joinPath(alloc, info.path, "skills");
        if (std.Io.Dir.cwd().openDir(util.io, skills_dir, .{ .iterate = true })) |sd| {
            defer sd.close(util.io);
            var sit = sd.iterate();
            while (try sit.next(util.io)) |se| {
                if (se.kind == .directory) info.skills += 1;
            }
        } else |_| {}
        // prompts/*.md 计数
        const prompts_dir = try util.joinPath(alloc, info.path, "prompts");
        if (std.Io.Dir.cwd().openDir(util.io, prompts_dir, .{ .iterate = true })) |pd| {
            defer pd.close(util.io);
            var pit = pd.iterate();
            while (try pit.next(util.io)) |pe| {
                if (pe.kind == .file and std.mem.endsWith(u8, pe.name, ".md")) info.prompts += 1;
            }
        } else |_| {}
        // AGENTS.md
        const agents = try util.joinPath(alloc, info.path, "AGENTS.md");
        if (util.fileExists(agents)) info.has_agents = true;
        // Web 前端插件
        const manifest = try util.joinPath(alloc, info.path, "pkg.json");
        if (std.Io.Dir.cwd().readFileAlloc(util.io, manifest, alloc, .limited(256 * 1024))) |raw| {
            defer alloc.free(raw);
            if (std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{})) |root_value| {
                info.has_web = root_value == .object and root_value.object.get("web") != null;
            } else |_| {}
        } else |_| {}
        try out.append(info);
    }
    return out.toOwnedSlice();
}

fn writeInfoArray(w: *std.Io.Writer, alloc: std.mem.Allocator, items: []const Info) !void {
    try w.writeByte('[');
    for (items, 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"name\":{s},\"skills\":{d},\"prompts\":{d},\"agents\":{s},\"web\":{s}}}", .{
            try util.jsonString(alloc, p.name),
            p.skills,
            p.prompts,
            if (p.has_agents) "true" else "false",
            if (p.has_web) "true" else "false",
        });
    }
    try w.writeByte(']');
}

/// Web /api/packages 用。
pub fn writeListJson(alloc: std.mem.Allocator, w: *std.Io.Writer, project_cwd: ?[]const u8) !void {
    const user = list(alloc, .user, project_cwd) catch &.{};
    const proj = list(alloc, .project, project_cwd) catch &.{};
    try w.writeAll("{\"user\":");
    try writeInfoArray(w, alloc, user);
    try w.writeAll(",\"project\":");
    try writeInfoArray(w, alloc, proj);
    try w.writeByte('}');
}

/// 移除包。
pub fn remove(alloc: std.mem.Allocator, name: []const u8, scope: Scope, project_cwd: ?[]const u8) !void {
    const root = try rootDir(alloc, scope, project_cwd);
    const dest = try util.joinPath(alloc, root, name);
    if (!util.dirExists(dest)) return error.PackageNotFound;
    try removeTree(std.Io.Dir.cwd(), dest);
    try manifestRemove(alloc, name, scope, project_cwd);
}

/// 收集全部包目录(用户级 + 项目级),供运行时扫描资源。
pub fn allPkgDirs(alloc: std.mem.Allocator, project_cwd: ?[]const u8) ![][]const u8 {
    var out = std.array_list.Managed([]const u8).init(alloc);
    const user_root = try rootDir(alloc, .user, null);
    defer alloc.free(user_root);
    if (std.Io.Dir.cwd().openDir(util.io, user_root, .{ .iterate = true })) |dir| {
        defer dir.close(util.io);
        var it = dir.iterate();
        while (try it.next(util.io)) |entry| {
            if (entry.kind == .directory) {
                try out.append(try util.joinPath(alloc, user_root, entry.name));
            }
        }
    } else |_| {}
    const proj_root = try rootDir(alloc, .project, project_cwd);
    defer alloc.free(proj_root);
    if (std.Io.Dir.cwd().openDir(util.io, proj_root, .{ .iterate = true })) |dir| {
        defer dir.close(util.io);
        var it = dir.iterate();
        while (try it.next(util.io)) |entry| {
            if (entry.kind == .directory) {
                try out.append(try util.joinPath(alloc, proj_root, entry.name));
            }
        }
    } else |_| {}
    return out.toOwnedSlice();
}

// ---- manifest:packages/manifest.json 记录 {name, source} ----

const ManifestEntry = struct {
    name: []const u8,
    source: []const u8,
};

fn manifestPath(alloc: std.mem.Allocator, scope: Scope, project_cwd: ?[]const u8) ![]u8 {
    return util.joinPath(alloc, try rootDir(alloc, scope, project_cwd), "manifest.json");
}

/// 读 manifest 条目。
fn manifestLoad(alloc: std.mem.Allocator, scope: Scope, project_cwd: ?[]const u8) ![]ManifestEntry {
    const path = try manifestPath(alloc, scope, project_cwd);
    const content = std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(256 * 1024)) catch return &.{};
    defer alloc.free(content);
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, content, .{}) catch return &.{};
    if (root != .object) return &.{};
    const arr = root.object.get("packages") orelse return &.{};
    if (arr != .array) return &.{};
    var out = std.array_list.Managed(ManifestEntry).init(alloc);
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const name = if (item.object.get("name")) |n| (if (n == .string) n.string else "") else "";
        const source = if (item.object.get("source")) |s| (if (s == .string) s.string else "") else "";
        if (name.len > 0) try out.append(.{ .name = name, .source = source });
    }
    return out.toOwnedSlice();
}

/// 写 manifest(原子替换)。
fn manifestWrite(alloc: std.mem.Allocator, scope: Scope, project_cwd: ?[]const u8, entries: []const ManifestEntry) !void {
    const path = try manifestPath(alloc, scope, project_cwd);
    var ww = std.Io.Writer.Allocating.init(alloc);
    defer ww.deinit();
    try ww.writer.writeAll("{\"packages\":[");
    for (entries, 0..) |e, i| {
        if (i > 0) try ww.writer.writeByte(',');
        try ww.writer.print("{{\"name\":{s},\"source\":{s}}}", .{
            try util.jsonString(alloc, e.name),
            try util.jsonString(alloc, e.source),
        });
    }
    try ww.writer.writeAll("]}\n");
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = path, .data = try ww.toOwnedSlice() });
}

fn manifestAdd(alloc: std.mem.Allocator, name: []const u8, source: []const u8, scope: Scope, project_cwd: ?[]const u8) !void {
    var entries = std.array_list.Managed(ManifestEntry).init(alloc);
    defer entries.deinit();
    var found = false;
    for (try manifestLoad(alloc, scope, project_cwd)) |e| {
        if (std.mem.eql(u8, e.name, name)) {
            try entries.append(.{ .name = e.name, .source = source });
            found = true;
        } else {
            try entries.append(e);
        }
    }
    if (!found) try entries.append(.{ .name = name, .source = source });
    try manifestWrite(alloc, scope, project_cwd, entries.items);
}

fn manifestRemove(alloc: std.mem.Allocator, name: []const u8, scope: Scope, project_cwd: ?[]const u8) !void {
    var entries = std.array_list.Managed(ManifestEntry).init(alloc);
    defer entries.deinit();
    for (try manifestLoad(alloc, scope, project_cwd)) |e| {
        if (!std.mem.eql(u8, e.name, name)) try entries.append(e);
    }
    try manifestWrite(alloc, scope, project_cwd, entries.items);
}

/// 按 manifest 记录的来源重装全部包。返回 (包名, 结果) 报告。
pub fn update(alloc: std.mem.Allocator, scope: Scope, project_cwd: ?[]const u8) !usize {
    const entries = try manifestLoad(alloc, scope, project_cwd);
    var ok: usize = 0;
    for (entries) |e| {
        // 先移除旧版,再按原 source 重装
        remove(alloc, e.name, scope, project_cwd) catch |err| util.debugCatch("pkg.update.remove", err);
        _ = install(alloc, e.source, scope, project_cwd) catch continue;
        ok += 1;
    }
    return ok;
}

test "pkg detectSource" {
    const t = std.testing;
    const s1 = detectSource("/home/x/pkg");
    try t.expect(s1 == .path);
    const s2 = detectSource("git:github.com/user/repo");
    try t.expect(s2 == .git);
    try t.expectEqualStrings("github.com/user/repo", s2.git);
    const s3 = detectSource("https://github.com/user/repo.git");
    try t.expect(s3 == .git);
    const s4 = detectSource("git@github.com:user/repo.git");
    try t.expect(s4 == .git);
    const s5 = detectSource("./local/dir");
    try t.expect(s5 == .path);
}

test "pkgJsonName prefers manifest name, rejects pathy names" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    const manifest = try util.joinPath(a, dir, "pkg.json");
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = manifest, .data = "{\"name\":\"demo-git-pkg\"}" });
    try t.expectEqualStrings("demo-git-pkg", pkgJsonName(a, dir).?);
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = manifest, .data = "{\"name\":\"../evil\"}" });
    try t.expect(pkgJsonName(a, dir) == null);
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = manifest, .data = "{}" });
    try t.expect(pkgJsonName(a, dir) == null);
}

test "pkg manifest + update + deps" {
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

    // 包 A(依赖 B)+ 包 B
    const src_b = try std.fmt.allocPrint(a, "{s}/pkgb", .{tmp_path});
    try std.Io.Dir.cwd().createDirPath(util.io, try std.fmt.allocPrint(a, "{s}/skills/b1", .{src_b}));
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/skills/b1/SKILL.md", .{src_b}), .data = "name: b1\ndescription: dep\n" });
    const src_a = try std.fmt.allocPrint(a, "{s}/pkga", .{tmp_path});
    try std.Io.Dir.cwd().createDirPath(util.io, try std.fmt.allocPrint(a, "{s}/skills/a1", .{src_a}));
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/skills/a1/SKILL.md", .{src_a}), .data = "name: a1\ndescription: v1\n" });
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/pkg.json", .{src_a}), .data = "{\"dependencies\":[\"pkgb\"]}\n" });

    // 依赖缺失 → 安装失败并回滚
    try t.expectError(error.MissingDependency, install(a, src_a, .user, null));
    const infos0 = try list(a, .user, null);
    try t.expectEqual(@as(usize, 0), infos0.len);

    // 先装依赖 B,再装 A 成功
    _ = try install(a, src_b, .user, null);
    _ = try install(a, src_a, .user, null);

    // manifest 记录 source
    const m = try manifestLoad(a, .user, null);
    try t.expectEqual(@as(usize, 2), m.len);
    try t.expectEqualStrings(src_a, m[1].source);

    // update:改源文件后重装生效
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/skills/a1/SKILL.md", .{src_a}), .data = "name: a1\ndescription: v2\n" });
    const n = try update(a, .user, null);
    try t.expectEqual(@as(usize, 2), n);
    const idx = try util.loadSkillsIndex(a);
    try t.expect(std.mem.indexOf(u8, idx, "a1: v2") != null);

    // remove 后 manifest 同步
    try remove(a, "pkga", .user, null);
    const m2 = try manifestLoad(a, .user, null);
    try t.expectEqual(@as(usize, 1), m2.len);
    try t.expectEqualStrings("pkgb", m2[0].name);
    try remove(a, "pkgb", .user, null);

    // 清理包源目录
    std.Io.Dir.cwd().deleteTree(util.io, src_a) catch {};
    std.Io.Dir.cwd().deleteTree(util.io, src_b) catch {};
}

test "pkg git source" {
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

    // 本地 git 仓库模拟远程包
    const repo = try std.fmt.allocPrint(a, "{s}/remote-repo", .{tmp_path});
    try std.Io.Dir.cwd().createDirPath(util.io, try std.fmt.allocPrint(a, "{s}/skills/g1", .{repo}));
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/skills/g1/SKILL.md", .{repo}), .data = "name: g1\ndescription: git pkg\n" });
    // git init + add + commit
    var git_init = try std.process.spawn(util.io, .{ .argv = &.{ "git", "-C", repo, "init", "-q" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    _ = git_init.wait(util.io) catch std.process.Child.Term{ .exited = 1 };
    var git_add = try std.process.spawn(util.io, .{ .argv = &.{ "git", "-C", repo, "add", "-A" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    _ = git_add.wait(util.io) catch std.process.Child.Term{ .exited = 1 };
    var git_cfg = try std.process.spawn(util.io, .{ .argv = &.{ "git", "-C", repo, "config", "user.email", "t@t" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    _ = git_cfg.wait(util.io) catch std.process.Child.Term{ .exited = 1 };
    var git_cfg2 = try std.process.spawn(util.io, .{ .argv = &.{ "git", "-C", repo, "config", "user.name", "t" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    _ = git_cfg2.wait(util.io) catch std.process.Child.Term{ .exited = 1 };
    var git_commit = try std.process.spawn(util.io, .{ .argv = &.{ "git", "-C", repo, "commit", "-qm", "init" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    const cterm = git_commit.wait(util.io) catch std.process.Child.Term{ .exited = 1 };
    try t.expect(cterm == .exited);

    // git: 前缀安装
    const git_src = try std.fmt.allocPrint(a, "git:{s}", .{repo});
    const dest = try install(a, git_src, .user, null);
    try t.expect(std.mem.endsWith(u8, dest, "/packages/remote-repo"));
    const idx = try util.loadSkillsIndex(a);
    try t.expect(std.mem.indexOf(u8, idx, "g1: git pkg") != null);
    // 临时 clone 目录已清理
    var left = false;
    var d = std.Io.Dir.cwd().openDir(util.io, "/tmp", .{ .iterate = true }) catch return;
    defer d.close(util.io);
    var it = d.iterate();
    while (try it.next(util.io)) |e| {
        if (std.mem.startsWith(u8, e.name, "piz-git-")) left = true;
    }
    try t.expect(!left);
    try remove(a, "remote-repo", .user, null);
    std.Io.Dir.cwd().deleteTree(util.io, repo) catch {};
}

test "declaredHooks surfaces exactly what the bus will run" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });

    const manifest = try util.joinPath(a, dir, "pkg.json");
    defer std.Io.Dir.cwd().deleteFile(util.io, manifest) catch {};

    // 没有 pkg.json / 没声明钩子 / 格式不对 → 空，且不报错。
    // 大多数包没有钩子，那条路径不能变成失败。
    try t.expectEqual(@as(usize, 0), (try declaredHooks(a, dir)).len);
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = manifest, .data = "{\"name\":\"p\"}" });
    try t.expectEqual(@as(usize, 0), (try declaredHooks(a, dir)).len);
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = manifest, .data = "{ OOPS }" });
    try t.expectEqual(@as(usize, 0), (try declaredHooks(a, dir)).len);

    // 声明了就要一条不漏地报出来 —— pkg install 的确认提示和 events.Bus
    // 用的是这同一个解析器，漏一条就等于用户没看见就授权了。
    try std.Io.Dir.cwd().writeFile(util.io, .{
        .sub_path = manifest,
        .data =
        \\{"name":"p","extensions":[{"events":{"startup":"curl x | sh","tool_end":"echo hi"}}]}
        ,
    });
    const hooks = try declaredHooks(a, dir);
    try t.expectEqual(@as(usize, 2), hooks.len);
    var saw_startup = false;
    for (hooks) |h| {
        if (std.mem.eql(u8, h.event, "startup")) {
            saw_startup = true;
            try t.expectEqualStrings("curl x | sh", h.command);
        }
    }
    try t.expect(saw_startup);
}

test "declaredTools reads pkg.json tools" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    const manifest = try util.joinPath(a, dir, "pkg.json");
    defer std.Io.Dir.cwd().deleteFile(util.io, manifest) catch {};
    try std.Io.Dir.cwd().writeFile(util.io, .{
        .sub_path = manifest,
        .data = "{\"tools\":[{\"name\":\"pdf_extract\",\"description\":\"Extract PDF\",\"command\":\"pdftotext {path} -\",\"schema\":{\"type\":\"object\"}},{\"name\":\"1bad\",\"command\":\"echo\"},{\"name\":\"ok_tool\",\"command\":\"echo hi\"}]}",
    });
    const tools = try declaredTools(a, dir);
    try t.expectEqual(@as(usize, 2), tools.len);
    try t.expectEqualStrings("pdf_extract", tools[0].name);
    try t.expectEqualStrings("pdftotext {path} -", tools[0].command);
    try t.expectEqualStrings("ok_tool", tools[1].name);
}

test "writeListJson emits user and project arrays" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aw = std.Io.Writer.Allocating.init(a);
    defer aw.deinit();
    try writeListJson(a, &aw.writer, "/tmp/piz-no-such-project");
    try t.expect(std.mem.indexOf(u8, aw.written(), "\"user\":") != null);
    try t.expect(std.mem.indexOf(u8, aw.written(), "\"project\":") != null);
}
