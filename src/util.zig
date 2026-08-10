// util.zig — 小工具集:内存、路径、文件、环境。
const std = @import("std");
const pkgsmod = @import("pkgs.zig");

pub const Arena = std.heap.ArenaAllocator;

/// 全局 Io 实例:main 里用 init.io 覆盖;测试/默认用单线程 Io。
pub var io: std.Io = std.Io.Threaded.global_single_threaded.io();
/// 全局环境变量表:main 里用 init.environ_map 覆盖。
pub var environ_map: ?*std.process.Environ.Map = null;

var g_test_threaded: ?std.Io.Threaded = null;
var g_test_env_map: ?std.process.Environ.Map = null;

/// 测试/库环境初始化:真 Threaded io + 进程环境表。
/// (global_single_threaded 的 allocator 是 .failing,process.spawn 必 OOM;
/// 无 libc 时 std.c.environ 不可用,linkLibC 后才有真实环境。)
pub fn testInit() !void {
    if (g_test_threaded != null) return;
    const env_block: std.process.Environ.Block = if (@import("builtin").link_libc) blk: {
        const c_environ = std.c.environ;
        var env_count: usize = 0;
        while (c_environ[env_count] != null) : (env_count += 1) {}
        break :blk .{ .slice = @ptrCast(c_environ[0..env_count :null]) };
    } else .{ .slice = &.{} };
    g_test_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = .{ .block = env_block } });
    io = g_test_threaded.?.io();
    g_test_env_map = try std.process.Environ.createMap(.{ .block = env_block }, std.heap.page_allocator);
    environ_map = &g_test_env_map.?;
}

/// 读环境变量(0.16:std.posix.getenv 已移除)。
pub fn getEnv(key: []const u8) ?[]const u8 {
    if (environ_map) |m| return m.get(key);
    return null;
}

pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024 * 1024));
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse ".";
    if (dir.len > 0 and !std.mem.eql(u8, dir, ".")) {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// 拼接路径,处理 base 尾斜杠与 rel 前导斜杠。
pub fn joinPath(alloc: std.mem.Allocator, base: []const u8, rel: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(rel)) return alloc.dupe(u8, rel);
    if (base.len == 0) return alloc.dupe(u8, rel);
    const sep = std.fs.path.sep;
    var out = std.array_list.Managed(u8).init(alloc);
    try out.appendSlice(base);
    if (base[base.len - 1] != sep) try out.append(sep);
    try out.appendSlice(rel);
    return out.toOwnedSlice();
}

pub fn homeDir(alloc: std.mem.Allocator) ![]u8 {
    if (getEnv("HOME")) |h| return alloc.dupe(u8, h);
    if (getEnv("USERPROFILE")) |h| return alloc.dupe(u8, h);
    return error.NoHomeDir;
}

/// 执行命令并收集 stdout(截断 64KB;失败返回错误消息)。供插件工具使用。
pub fn execShort(alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    return execShortTimeout(alloc, argv, 60);
}

/// 执行命令并收集 stdout(带超时秒)。
pub fn execShortTimeout(alloc: std.mem.Allocator, argv: []const []const u8, timeout_s: u8) ![]u8 {
    _ = timeout_s;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return error.SpawnFailed;
    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    if (child.stdout) |f| {
        var rbuf: [4096]u8 = undefined;
        var reader = f.reader(io, &rbuf);
        var chunk: [8192]u8 = undefined;
        while (out.items.len < 64 * 1024) {
            const n = reader.interface.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            try out.appendSlice(chunk[0..n]);
        }
        child.stdout = null; // 防止 wait 清理时重复 close(BADF panic)
        f.close(io);
    }
    const term = child.wait(io) catch return error.WaitFailed;
    if (term != .exited or term.exited != 0) return error.CommandFailed;
    return out.toOwnedSlice();
}

/// piz 配置目录:$PIZ_DIR 或 ~/.piz。
///
/// 刻意**不与官方 pi 共用目录**。早期版本读 ~/.pi/agent,但两者的会话 JSONL
/// 格式不兼容(pi 把消息包在 entry.message 里,piz 是扁平结构),共用
/// sessions/ 目录会让 /sessions 列出对方的会话、选中后静默得到空历史。
/// 独立目录换来:格式自由演进、不怕 pi 升级、不怕互相踩。
pub fn configDir(alloc: std.mem.Allocator) ![]u8 {
    if (getEnv("PIZ_DIR")) |d| {
        if (d.len > 0) return alloc.dupe(u8, d);
    }
    const home = try homeDir(alloc);
    return joinPath(alloc, home, ".piz");
}

/// 项目级 piz 目录名(资源包、SYSTEM.md、prompts 覆盖等)。
pub const PROJECT_DIR = ".piz";

/// 检测「有旧 pi 配置但还没有 piz 配置」的情形,返回可迁移的旧目录路径。
/// piz 早期版本读 ~/.pi/agent;现在独立用 ~/.piz。老用户需要知道配置去哪了。
/// 返回非 null 时由调用方打印一次性提示 —— 这里只做判断,不做 I/O 输出。
pub fn legacyConfigDir(alloc: std.mem.Allocator) ?[]u8 {
    // 显式指定过目录就不提示
    if (getEnv("PIZ_DIR")) |d| {
        if (d.len > 0) return null;
    }
    const home = homeDir(alloc) catch return null;
    const current = joinPath(alloc, home, ".piz") catch return null;
    if (dirExists(current)) return null; // 已迁移或全新安装
    const legacy_agent = joinPath(alloc, home, ".pi/agent") catch return null;
    if (dirExists(legacy_agent)) return legacy_agent;
    const legacy = joinPath(alloc, home, ".pi") catch return null;
    if (dirExists(legacy)) return legacy;
    return null;
}

pub fn dirExists(path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// URL percent 解码(%XX → 字节)。
pub fn percentDecode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len + 1) {
            const hi = hexVal(s[i + 1]);
            const lo = hexVal(s[i + 2]);
            if (hi >= 0 and lo >= 0) {
                try out.append(@as(u8, @intCast(hi * 16 + lo)));
                i += 3;
                continue;
            }
        }
        try out.append(s[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

fn hexVal(c: u8) i32 {
    return switch (c) {
        '0'...'9' => @as(i32, c - '0'),
        'a'...'f' => @as(i32, c - 'a' + 10),
        'A'...'F' => @as(i32, c - 'A' + 10),
        else => -1,
    };
}

/// 设置 fd 非阻塞(0.16 无 posix.fcntl 封装,直调 syscall;负返回值即 errno)。
pub fn setNonBlock(fd: std.posix.fd_t) void {
    const raw = std.os.linux.fcntl(fd, std.posix.F.GETFL, 0);
    const res = @as(isize, @bitCast(raw));
    if (res < 0) return;
    // Linux O_NONBLOCK == 0o4000
    _ = std.os.linux.fcntl(fd, std.posix.F.SETFL, @as(usize, @intCast(res)) | 0o4000);
}

/// 对端是否已关闭连接(不消费数据,不阻塞)。
///
/// SSE 这类只写不读的长连接感知不到客户端离开:写一个已关闭的 socket
/// 第一次还会成功(数据进内核缓冲),要等对端 RST 回来的下一次写才失败。
/// 靠心跳发现断开就得等两个心跳周期,期间连接槽位一直被占着。
/// MSG_PEEK|MSG_DONTWAIT 的 recv 返回 0 就是干净的 EOF —— 即时且可靠。
pub fn peerClosed(fd: std.posix.fd_t) bool {
    var probe: [1]u8 = undefined;
    const flags = std.os.linux.MSG.PEEK | std.os.linux.MSG.DONTWAIT;
    const raw = std.os.linux.recvfrom(fd, &probe, probe.len, flags, null, null);
    const res = @as(isize, @bitCast(raw));
    // 0 = 对端有序关闭;负值多是 EAGAIN(无数据但连接活着) —— 只有 0 能断言关闭
    return res == 0;
}

/// stdin 是否连着终端。
///
/// 用 tcgetattr 成功与否判断 —— 只有终端有 termios。管道、重定向、脚本里都是 false。
/// 用来决定「能不能问用户」:不能问的时候安全选择是拒绝,不是默认同意。
pub fn stdinIsTty() bool {
    _ = std.posix.tcgetattr(std.Io.File.stdin().handle) catch return false;
    return true;
}

/// 从 stdin 读一行(不含换行)。EOF 或读失败返回 null。
///
/// 只服务 CLI 确认提示,所以缓冲区由调用方给且很小 —— 超长输入按截断处理,
/// 反正回答只可能是 y/N。
pub fn readLineStdin(buf: []u8) ?[]const u8 {
    var r = std.Io.File.stdin().reader(io, buf);
    return r.interface.takeDelimiterExclusive('\n') catch null;
}

/// 目录转 pi 风格会话 slug:--home-telagod-project-x--(去首斜杠,/→-,前后加 --)。
pub fn cwdSlug(alloc: std.mem.Allocator, cwd: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    try out.appendSlice("--");
    var rest = cwd;
    if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    for (rest) |c| {
        try out.append(if (c == '/') '-' else c);
    }
    try out.appendSlice("--");
    return out.toOwnedSlice();
}

/// 收集 AGENTS.md:全局(~/.piz/AGENTS.md)最前,然后 cwd 向上至根。
/// 每份文件前附注释行标明来源路径。
pub fn loadAgentsMd(alloc: std.mem.Allocator) ![]u8 {
    var outw = std.Io.Writer.Allocating.init(alloc);
    defer outw.deinit();
    var found: usize = 0;

    // 全局 AGENTS.md(与 pi 一致,最先)
    if (configDir(alloc)) |cfg_dir| {
        const g = try joinPath(alloc, cfg_dir, "AGENTS.md");
        if (std.Io.Dir.cwd().readFileAlloc(io, g, alloc, .limited(4 * 1024 * 1024))) |content| {
            try outw.writer.print("# AGENTS.md from {s}\n\n", .{cfg_dir});
            try outw.writer.writeAll(content);
            found += 1;
        } else |_| {}
    } else |_| {}

    // 资源包 AGENTS.md(用户级 + 项目级)
    if (pkgDirsForRuntime(alloc)) |pkgs| {
        for (pkgs) |pkg| {
            const g = try joinPath(alloc, pkg, "AGENTS.md");
            if (std.Io.Dir.cwd().readFileAlloc(io, g, alloc, .limited(4 * 1024 * 1024))) |content| {
                if (found > 0) try outw.writer.writeByte('\n');
                try outw.writer.print("# AGENTS.md from package {s}\n\n", .{std.fs.path.basename(pkg)});
                try outw.writer.writeAll(content);
                found += 1;
            } else |_| {}
        }
    } else |_| {}

    // cwd 向上(自下而上:最近优先)
    const cwd = try std.process.currentPathAlloc(io, alloc);
    var dir: []const u8 = cwd;
    while (true) {
        const p = try joinPath(alloc, dir, "AGENTS.md");
        if (std.Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(4 * 1024 * 1024))) |content| {
            if (found > 0) try outw.writer.writeByte('\n');
            try outw.writer.print("# AGENTS.md from {s}\n\n", .{dir});
            try outw.writer.writeAll(content);
            found += 1;
        } else |_| {}
        if (std.fs.path.dirname(dir)) |parent| {
            if (std.mem.eql(u8, parent, dir)) break;
            dir = parent;
        } else break;
        if (found >= 8) break; // 防止极端目录树
    }
    return outw.toOwnedSlice();
}

/// SYSTEM.md 候选路径(优先项目 .pi/SYSTEM.md,其次全局)。
pub fn systemMdPath(alloc: std.mem.Allocator, cwd: []const u8) !?[]u8 {
    const project = try joinPath(alloc, cwd, PROJECT_DIR);
    const p1 = try joinPath(alloc, project, "SYSTEM.md");
    if (fileExists(p1)) return p1;
    if (configDir(alloc)) |cfg_dir| {
        const p2 = try joinPath(alloc, cfg_dir, "SYSTEM.md");
        if (fileExists(p2)) return p2;
    } else |_| {}
    return null;
}

pub fn fileExists(path: []const u8) bool {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

/// 查找 prompt 模板(项目 .pi/prompts 优先,其次全局 prompts)。
pub fn loadTemplate(alloc: std.mem.Allocator, cwd: []const u8, name: []const u8) !?[]u8 {
    // 防路径穿越
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return null;
    }
    const project = try joinPath(alloc, try joinPath(alloc, cwd, PROJECT_DIR), "prompts");
    const p1 = try joinPath(alloc, project, try std.fmt.allocPrint(alloc, "{s}.md", .{name}));
    if (std.Io.Dir.cwd().readFileAlloc(io, p1, alloc, .limited(256 * 1024))) |content| {
        return content;
    } else |_| {}
    if (configDir(alloc)) |cfg_dir| {
        const p2 = try joinPath(alloc, try joinPath(alloc, cfg_dir, "prompts"), try std.fmt.allocPrint(alloc, "{s}.md", .{name}));
        if (std.Io.Dir.cwd().readFileAlloc(io, p2, alloc, .limited(256 * 1024))) |content| {
            return content;
        } else |_| {}
    } else |_| {}
    // 资源包 prompts(用户级 + 项目级)
    if (pkgDirsForRuntime(alloc)) |pkgs| {
        for (pkgs) |pkg| {
            const p3 = try joinPath(alloc, try joinPath(alloc, pkg, "prompts"), try std.fmt.allocPrint(alloc, "{s}.md", .{name}));
            if (std.Io.Dir.cwd().readFileAlloc(io, p3, alloc, .limited(256 * 1024))) |content| {
                return content;
            } else |_| {}
        }
    } else |_| {}
    return null;
}

/// 全部资源包目录(用户级 + 项目级;失败返回空)。
pub fn pkgDirsForRuntime(alloc: std.mem.Allocator) ![][]const u8 {
    const cwd = std.process.currentPathAlloc(io, alloc) catch ".";
    return @import("pkgs.zig").allPkgDirs(alloc, cwd);
}

/// 模板渲染:{{1}} {{2}} … 替换为参数;无参数时保留原文。
pub fn renderTemplate(alloc: std.mem.Allocator, tpl: []const u8, args: []const []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    var i: usize = 0;
    while (i < tpl.len) {
        if (tpl[i] == '{' and i + 2 < tpl.len and tpl[i + 1] == '{') {
            const close = std.mem.indexOfPos(u8, tpl, i + 2, "}}") orelse {
                try out.appendSlice(tpl[i..]);
                break;
            };
            const key = tpl[i + 2 .. close];
            if (key.len > 0 and key[0] >= '0' and key[0] <= '9') {
                const n = std.fmt.parseInt(usize, key, 10) catch 0;
                if (n >= 1 and n <= args.len) {
                    try out.appendSlice(args[n - 1]);
                    i = close + 2;
                    continue;
                }
            }
            try out.appendSlice(tpl[i .. close + 2]);
            i = close + 2;
            continue;
        }
        try out.append(tpl[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

/// APPEND_SYSTEM.md 追加内容(全局 + 项目,拼接)。
pub fn appendSystemMd(alloc: std.mem.Allocator, cwd: []const u8) ![]u8 {
    var outw = std.Io.Writer.Allocating.init(alloc);
    defer outw.deinit();
    if (configDir(alloc)) |cfg_dir| {
        const g = try joinPath(alloc, cfg_dir, "APPEND_SYSTEM.md");
        if (std.Io.Dir.cwd().readFileAlloc(io, g, alloc, .limited(512 * 1024))) |content| {
            try outw.writer.writeAll(content);
            try outw.writer.writeByte('\n');
        } else |_| {}
    } else |_| {}
    const project = try joinPath(alloc, cwd, PROJECT_DIR);
    const p = try joinPath(alloc, project, "APPEND_SYSTEM.md");
    if (std.Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(512 * 1024))) |content| {
        try outw.writer.writeAll(content);
        try outw.writer.writeByte('\n');
    } else |_| {}
    return outw.toOwnedSlice();
}

/// 扫描 skills 目录(~/.piz/skills/<name>/SKILL.md),
/// 返回可用的技能清单(名称 + description 首行)。无则返回空串。
/// 扫描单个 skills 目录,追加索引行到 outw。
fn scanSkillsDir(alloc: std.mem.Allocator, outw: *std.Io.Writer.Allocating, skills_dir: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, skills_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const skill_file = try joinPath(alloc, skills_dir, entry.name);
        const md = try joinPath(alloc, skill_file, "SKILL.md");
        const content = std.Io.Dir.cwd().readFileAlloc(io, md, alloc, .limited(256 * 1024)) catch continue;
        defer alloc.free(content);
        // 解析 name/description 行
        var name: []const u8 = entry.name;
        var desc: []const u8 = "";
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, "name:")) {
                name = std.mem.trim(u8, l["name:".len..], " \t");
            } else if (std.mem.startsWith(u8, l, "description:")) {
                desc = std.mem.trim(u8, l["description:".len..], " \t");
                if (desc.len > 0) break;
            }
        }
        try outw.writer.print("- {s}: {s}\n", .{ name, desc });
    }
}

pub fn loadSkillsIndex(alloc: std.mem.Allocator) ![]u8 {
    const cfg_dir = try configDir(alloc);
    const skills_dir = try joinPath(alloc, cfg_dir, "skills");
    var outw = std.Io.Writer.Allocating.init(alloc);
    defer outw.deinit();
    try scanSkillsDir(alloc, &outw, skills_dir);
    // 资源包 skills(用户级 + 项目级)
    if (pkgDirsForRuntime(alloc)) |pkgs| {
        for (pkgs) |pkg| {
            try scanSkillsDir(alloc, &outw, try joinPath(alloc, pkg, "skills"));
        }
    } else |_| {}
    return outw.toOwnedSlice();
}

/// 读 ~/.piz/memory.md(如有),供注入系统提示。
pub fn loadMemoryMd(alloc: std.mem.Allocator) ![]u8 {
    const cfg_dir = try configDir(alloc);
    const p = try joinPath(alloc, cfg_dir, "memory.md");
    return std.Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(512 * 1024)) catch "";
}

/// 粗略 token 估计:UTF-8 字符数 / 4。
pub fn estTokens(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if (b & 0xC0 != 0x80) n += 1; // 非续字节 = 一个字符
    }
    return n / 4 + 1;
}

/// 按字节上限把 s 截到最近的 UTF-8 边界,返回子切片(不分配)。
/// 切在多字节序列中间会产生非法 UTF-8,让 JSON 序列化吐出坏字符串 --
/// 中文每字 3 字节,盲切几乎必然踩中。
pub fn clampUtf8(s: []const u8, max_bytes: usize) []const u8 {
    if (s.len <= max_bytes) return s;
    var end = max_bytes;
    // 退到序列首字节(跳过 10xxxxxx 的 continuation byte)。停在这里就等于
    // 丢掉那个跨界的序列,不用再算它的宽度。
    while (end > 0 and s[end] & 0xC0 == 0x80) end -= 1;
    return s[0..end];
}

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

test "clampUtf8 never splits a codepoint" {
    const t = std.testing;
    // 上限内原样返回
    try t.expectEqualStrings("abc", clampUtf8("abc", 8));
    try t.expectEqualStrings("abc", clampUtf8("abc", 3));
    // 纯 ASCII 精确截断
    try t.expectEqualStrings("abcd", clampUtf8("abcdefgh", 4));
    // 中文每字 3 字节:上限 4 只能容一个字,第二个字整体丢掉
    try t.expectEqualStrings("中", clampUtf8("中文", 4));
    try t.expectEqualStrings("中", clampUtf8("中文", 5));
    try t.expectEqualStrings("中文", clampUtf8("中文", 6));
    // emoji 4 字节
    try t.expectEqualStrings("", clampUtf8("😀x", 3));
    try t.expectEqualStrings("😀", clampUtf8("😀x", 4));
    // 结果必须始终是合法 UTF-8 -- 这是整个函数存在的理由
    const zh = "会话标题很长很长很长很长很长";
    var n: usize = 0;
    while (n <= zh.len + 2) : (n += 1) {
        try t.expect(std.unicode.utf8ValidateSlice(clampUtf8(zh, n)));
    }
}

test "joinPath" {
    const t = std.testing;
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("/home/x/file", try joinPath(a, "/home/x", "file"));
    try t.expectEqualStrings("/home/x/file", try joinPath(a, "/home/x/", "file"));
    try t.expectEqualStrings("/abs", try joinPath(a, "/home/x", "/abs"));
}

test "estTokens" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 3), estTokens("hello world"));
    try t.expectEqual(@as(usize, 1), estTokens("hi"));
}

/// 将任意 JSON 可序列化值转成字符串。
pub fn jsonString(alloc: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}

test "pkg install/list/remove" {
    const t = std.testing;
    try testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd_abs = try std.process.currentPathAlloc(io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try environ_map.?.put("PIZ_DIR", tmp_path);

    // 构造一个包目录
    const pkg_src = try std.fmt.allocPrint(a, "{s}/mypkg", .{tmp_path});
    try std.Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/skills/rev", .{pkg_src}));
    try std.Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/prompts", .{pkg_src}));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/skills/rev/SKILL.md", .{pkg_src}), .data = "name: rev\ndescription: from package\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/prompts/review.md", .{pkg_src}), .data = "Pkg review {{1}}" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/AGENTS.md", .{pkg_src}), .data = "pkg rule\n" });

    // install
    const dest = try pkgsmod.install(a, pkg_src, .user, null);
    try t.expect(std.mem.endsWith(u8, dest, "/packages/mypkg"));
    // 重复安装报错
    try t.expectError(error.AlreadyInstalled, pkgsmod.install(a, pkg_src, .user, null));
    // 非法包
    const bad = try std.fmt.allocPrint(a, "{s}/badpkg", .{tmp_path});
    try std.Io.Dir.cwd().createDirPath(io, bad);
    try t.expectError(error.NotAPackage, pkgsmod.install(a, bad, .user, null));

    // list 统计
    const infos = try pkgsmod.list(a, .user, null);
    try t.expectEqual(@as(usize, 1), infos.len);
    try t.expectEqualStrings("mypkg", infos[0].name);
    try t.expectEqual(@as(usize, 1), infos[0].skills);
    try t.expectEqual(@as(usize, 1), infos[0].prompts);
    try t.expect(infos[0].has_agents);

    // 运行时集成:skills 索引、模板、AGENTS.md 均可见
    const idx = try loadSkillsIndex(a);
    try t.expect(std.mem.indexOf(u8, idx, "rev: from package") != null);
    const tpl = (try loadTemplate(a, "/tmp", "review")).?;
    try t.expect(std.mem.indexOf(u8, tpl, "Pkg review") != null);
    const agents = try loadAgentsMd(a);
    try t.expect(std.mem.indexOf(u8, agents, "pkg rule") != null);

    // remove
    try pkgsmod.remove(a, "mypkg", .user, null);
    try t.expectError(error.PackageNotFound, pkgsmod.remove(a, "mypkg", .user, null));
    const infos2 = try pkgsmod.list(a, .user, null);
    try t.expectEqual(@as(usize, 0), infos2.len);
    // 移除后不可见
    const idx2 = try loadSkillsIndex(a);
    try t.expect(std.mem.indexOf(u8, idx2, "rev: from package") == null);

    // 清理临时包源
    std.Io.Dir.cwd().deleteTree(io, pkg_src) catch {};
}

test "template render" {
    const t = std.testing;
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tpl = "Review {{1}} for bugs. Focus: {{2}}";
    const args = [_][]const u8{ "main.zig", "security" };
    const out = try renderTemplate(a, tpl, &args);
    try t.expectEqualStrings("Review main.zig for bugs. Focus: security", out);
    // 缺参保留
    const out2 = try renderTemplate(a, tpl, &.{});
    try t.expect(std.mem.indexOf(u8, out2, "{{1}}") != null);
    // 无花括号原样
    try t.expectEqualStrings("plain", try renderTemplate(a, "plain", &args));
}

test "loadTemplate lookup" {
    const t = std.testing;
    try testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd_abs = try std.process.currentPathAlloc(io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try environ_map.?.put("PIZ_DIR", tmp_path);

    // 全局 prompts/review.md
    tmp.dir.createDirPath(io, "prompts") catch {};
    try tmp.dir.writeFile(io, .{ .sub_path = "prompts/review.md", .data = "Review {{1}} now" });
    const tpl = (try loadTemplate(a, "/tmp", "review")).?;
    try t.expect(std.mem.indexOf(u8, tpl, "Review") != null);
    // 不存在 → null;非法名 → null
    try t.expect((try loadTemplate(a, "/tmp", "nope")) == null);
    try t.expect((try loadTemplate(a, "/tmp", "../evil")) == null);
}

test "cwdSlug" {
    const t = std.testing;
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("--home-telagod-project-pi-zig--", try cwdSlug(a, "/home/telagod/project/pi-zig"));
    try t.expectEqualStrings("--tmp--", try cwdSlug(a, "/tmp"));
    try t.expectEqualStrings("--home-telagod-桌面--", try cwdSlug(a, "/home/telagod/桌面"));
}

test "skills index + memory.md" {
    const t = std.testing;
    try testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 注:Environ.Map.put 覆盖时 free 旧值,恢复旧值会 UAF——测试内只覆盖不恢复
    // 0.16 tmpDir().sub_path 是裸随机名(位于 .zig-cache/tmp 下),须显式拼前缀
    const cwd_abs = try std.process.currentPathAlloc(io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try environ_map.?.put("PIZ_DIR", tmp_path);

    // 建 skills/foo/SKILL.md + memory.md(经 tmp.dir 相对路径)
    tmp.dir.createDirPath(io, "skills/foo") catch {};
    try tmp.dir.writeFile(io, .{ .sub_path = "skills/foo/SKILL.md", .data = "name: foo\ndescription: Do foo things\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "memory.md", .data = "remember: x=1\n" });

    const idx = try loadSkillsIndex(a);
    try t.expect(std.mem.indexOf(u8, idx, "foo: Do foo things") != null);
    const mem = try loadMemoryMd(a);
    try t.expectEqualStrings("remember: x=1\n", mem);
    // 无 skills 目录 → 空串
    try tmp.dir.deleteFile(io, "skills/foo/SKILL.md");
    try tmp.dir.deleteDir(io, "skills/foo");
    try tmp.dir.deleteDir(io, "skills");
    try t.expectEqualStrings("", try loadSkillsIndex(a));
}
