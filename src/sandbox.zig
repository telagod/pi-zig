// sandbox.zig — bash 的 OS 隔离。授权档(yolo/ask/read-only)是问不问;
// 这一档是内核里拦不拦。workspace:工作区可写、其余只读、可出网。
// strict:同上再断网。没装 bubblewrap 时 fail-closed,不偷偷裸跑。
const std = @import("std");
const builtin = @import("builtin");
const util = @import("util.zig");

pub const Mode = enum {
    off,
    workspace,
    strict,

    pub fn parse(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "none") or std.mem.eql(u8, s, "full"))
            return .off;
        if (std.mem.eql(u8, s, "workspace") or std.mem.eql(u8, s, "workspace-write") or std.mem.eql(u8, s, "ws"))
            return .workspace;
        if (std.mem.eql(u8, s, "strict") or std.mem.eql(u8, s, "network") or std.mem.eql(u8, s, "no-net"))
            return .strict;
        return null;
    }

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .off => "off",
            .workspace => "workspace",
            .strict => "strict",
        };
    }

    pub fn uiLabel(self: Mode) []const u8 {
        return switch (self) {
            .off => "sandbox off",
            .workspace => "sandbox workspace",
            .strict => "sandbox strict",
        };
    }
};

const BWRAP_CANDIDATES = [_][]const u8{
    "/usr/bin/bwrap",
    "/usr/local/bin/bwrap",
    "/bin/bwrap",
};

pub fn findBwrap() ?[]const u8 {
    for (BWRAP_CANDIDATES) |p| {
        if (util.fileExists(p)) return p;
    }
    return null;
}

pub const Backend = enum {
    none,
    bwrap,
    landlock,

    pub fn label(self: Backend) []const u8 {
        return switch (self) {
            .none => "none",
            .bwrap => "bwrap",
            .landlock => "landlock",
        };
    }
};

/// 实际会走的隔离后端。bwrap 优先。
pub fn backend() Backend {
    if (findBwrap() != null) return .bwrap;
    if (landlockAbi() != null) return .landlock;
    return .none;
}

/// `off` 或 `workspace/bwrap` / `strict/landlock` / `workspace/none`。
pub fn describe(alloc: std.mem.Allocator, mode: Mode) ![]u8 {
    if (mode == .off) return alloc.dupe(u8, "off");
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ mode.label(), backend().label() });
}

const ACCESS_FS_EXECUTE: u64 = 1 << 0;
const ACCESS_FS_WRITE_FILE: u64 = 1 << 1;
const ACCESS_FS_READ_FILE: u64 = 1 << 2;
const ACCESS_FS_READ_DIR: u64 = 1 << 3;
const ACCESS_FS_REMOVE_DIR: u64 = 1 << 4;
const ACCESS_FS_REMOVE_FILE: u64 = 1 << 5;
const ACCESS_FS_MAKE_CHAR: u64 = 1 << 6;
const ACCESS_FS_MAKE_DIR: u64 = 1 << 7;
const ACCESS_FS_MAKE_REG: u64 = 1 << 8;
const ACCESS_FS_MAKE_SOCK: u64 = 1 << 9;
const ACCESS_FS_MAKE_FIFO: u64 = 1 << 10;
const ACCESS_FS_MAKE_BLOCK: u64 = 1 << 11;
const ACCESS_FS_MAKE_SYM: u64 = 1 << 12;
const ACCESS_FS_REFER: u64 = 1 << 13;
const ACCESS_FS_TRUNCATE: u64 = 1 << 14;
const ACCESS_FS_IOCTL_DEV: u64 = 1 << 15;
const ACCESS_NET_BIND_TCP: u64 = 1 << 0;
const ACCESS_NET_CONNECT_TCP: u64 = 1 << 1;
const LANDLOCK_RULE_PATH_BENEATH: u32 = 1;
const LANDLOCK_CREATE_RULESET_VERSION: usize = 1;
const PR_SET_NO_NEW_PRIVS: i32 = 38;

fn fsRead(abi: i64) u64 {
    var bits: u64 = ACCESS_FS_EXECUTE | ACCESS_FS_READ_FILE | ACCESS_FS_READ_DIR;
    if (abi >= 5) bits |= ACCESS_FS_IOCTL_DEV;
    return bits;
}

fn fsWrite(abi: i64) u64 {
    var bits: u64 = ACCESS_FS_WRITE_FILE | ACCESS_FS_REMOVE_DIR | ACCESS_FS_REMOVE_FILE |
        ACCESS_FS_MAKE_CHAR | ACCESS_FS_MAKE_DIR | ACCESS_FS_MAKE_REG |
        ACCESS_FS_MAKE_SOCK | ACCESS_FS_MAKE_FIFO | ACCESS_FS_MAKE_BLOCK |
        ACCESS_FS_MAKE_SYM;
    if (abi >= 2) bits |= ACCESS_FS_REFER;
    if (abi >= 3) bits |= ACCESS_FS_TRUNCATE;
    if (abi >= 5) bits |= ACCESS_FS_IOCTL_DEV;
    return bits;
}

fn sysOk(rc: usize) bool {
    return @as(isize, @bitCast(rc)) >= 0;
}

fn sysFd(rc: usize) ?i32 {
    const n: isize = @bitCast(rc);
    if (n < 0) return null;
    return @intCast(n);
}

/// 探测内核 Landlock ABI。null = 没有这套 syscall。
pub fn landlockAbi() ?i64 {
    if (builtin.os.tag != .linux) return null;
    const rc = std.os.linux.syscall3(.landlock_create_ruleset, 0, 0, LANDLOCK_CREATE_RULESET_VERSION);
    const n: isize = @bitCast(rc);
    if (n <= 0) return null;
    return n;
}

fn openPath(path: []const u8) ?i32 {
    var buf: [4096]u8 = undefined;
    if (path.len + 1 > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const z: [*:0]const u8 = @ptrCast(&buf);
    const rc = std.os.linux.open(z, .{ .ACCMODE = .RDONLY, .PATH = true, .CLOEXEC = true }, 0);
    return sysFd(rc);
}

fn addBeneath(ruleset: i32, path: []const u8, access: u64) bool {
    const fd = openPath(path) orelse return false;
    defer _ = std.os.linux.close(@intCast(fd));
    var attr: [12]u8 = undefined;
    std.mem.writeInt(u64, attr[0..8], access, .little);
    std.mem.writeInt(i32, attr[8..12], fd, .little);
    const rc = std.os.linux.syscall4(
        .landlock_add_rule,
        @as(usize, @intCast(ruleset)),
        LANDLOCK_RULE_PATH_BENEATH,
        @intFromPtr(&attr),
        0,
    );
    return sysOk(rc);
}

/// 给当前进程套上 landlock。随后 spawn 的孩子会继承。
/// `/` 只读,workspace 与 extras 可写。strict 且 ABI>=4 时断 TCP。
pub fn applyLandlock(mode: Mode, workspace: []const u8, extras: []const []const u8) !void {
    if (builtin.os.tag != .linux) return error.LandlockUnavailable;
    const abi = landlockAbi() orelse return error.LandlockUnavailable;
    const read = fsRead(abi);
    const write = fsWrite(abi);
    const handled_fs = read | write;
    const attr_fs = handled_fs;
    var attr_net: u64 = 0;
    var attr_size: usize = 8;
    if (mode == .strict and abi >= 4) {
        attr_net = ACCESS_NET_BIND_TCP | ACCESS_NET_CONNECT_TCP;
        attr_size = 16;
    }
    var ruleset_attr: [16]u8 = @splat(0);
    std.mem.writeInt(u64, ruleset_attr[0..8], attr_fs, .little);
    if (attr_size > 8) std.mem.writeInt(u64, ruleset_attr[8..16], attr_net, .little);
    const rs_rc = std.os.linux.syscall3(.landlock_create_ruleset, @intFromPtr(&ruleset_attr), attr_size, 0);
    const rs = sysFd(rs_rc) orelse return error.LandlockCreate;
    defer _ = std.os.linux.close(@intCast(rs));
    if (!addBeneath(rs, "/", read)) return error.LandlockRoot;
    if (workspace.len > 0 and !std.mem.eql(u8, workspace, "/")) {
        if (!addBeneath(rs, workspace, read | write)) return error.LandlockWorkspace;
    }
    for (extras) |p| {
        if (p.len == 0) continue;
        if (underPrefix(p, workspace)) continue;
        if (!addBeneath(rs, p, read | write)) return error.LandlockExtra;
    }
    const priv = std.os.linux.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
    if (!sysOk(priv)) return error.NoNewPrivs;
    const rest = std.os.linux.syscall2(.landlock_restrict_self, @as(usize, @intCast(rs)), 0);
    if (!sysOk(rest)) return error.LandlockRestrict;
}

pub fn buildLandlockArgv(
    arena: std.mem.Allocator,
    self_exe: []const u8,
    mode: Mode,
    workspace: []const u8,
    extras: []const []const u8,
    command: []const u8,
    chdir: []const u8,
) ![]const []const u8 {
    var list = std.array_list.Managed([]const u8).init(arena);
    try list.appendSlice(&.{ self_exe, "sandbox-exec", "--mode", mode.label(), "--dir", workspace });
    if (chdir.len > 0 and !std.mem.eql(u8, chdir, workspace)) {
        try list.appendSlice(&.{ "--chdir", chdir });
    }
    for (extras) |p| {
        if (p.len == 0) continue;
        try list.appendSlice(&.{ "--allow", p });
    }
    try list.appendSlice(&.{ "--allow", "/tmp", "--allow", "/dev" });
    try list.appendSlice(&.{ "--", "sh", "-c", command });
    return list.toOwnedSlice();
}

/// `piz sandbox-exec --mode workspace --dir DIR [--chdir START] [--allow P]... -- CMD...`
/// 套 landlock 后 spawn CMD,以子进程退出码退出。不返回。
pub fn runExec(args: *std.process.Args.Iterator) noreturn {
    var mode: Mode = .workspace;
    var dir: []const u8 = ".";
    var start: []const u8 = "";
    var allow_buf: [8][]const u8 = undefined;
    var allow_n: usize = 0;
    var cmd: []const []const u8 = &.{};
    var pending = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--mode")) {
            const v = args.next() orelse fail("missing --mode value");
            mode = Mode.parse(v) orelse fail("bad --mode");
        } else if (std.mem.eql(u8, a, "--dir")) {
            dir = args.next() orelse fail("missing --dir value");
        } else if (std.mem.eql(u8, a, "--chdir")) {
            start = args.next() orelse fail("missing --chdir value");
        } else if (std.mem.eql(u8, a, "--allow")) {
            const v = args.next() orelse fail("missing --allow value");
            if (allow_n < allow_buf.len) {
                allow_buf[allow_n] = v;
                allow_n += 1;
            }
        } else if (std.mem.eql(u8, a, "--")) {
            while (args.next()) |c| pending.append(c) catch fail("oom");
            cmd = pending.items;
            break;
        } else {
            fail("unknown sandbox-exec flag");
        }
    }
    if (cmd.len == 0) fail("sandbox-exec needs `-- CMD`");
    if (mode == .off) fail("sandbox-exec mode=off is pointless");
    const go = if (start.len > 0) start else dir;
    std.Io.Threaded.chdir(go) catch fail("chdir failed");
    applyLandlock(mode, dir, allow_buf[0..allow_n]) catch |err| fail(@errorName(err));
    var child = std.process.spawn(util.io, .{
        .argv = cmd,
        .cwd = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .stdin = .inherit,
    }) catch fail("spawn failed");
    const term = child.wait(util.io) catch fail("wait failed");
    switch (term) {
        .exited => |c| std.process.exit(c),
        .signal => |s| std.process.exit(@intCast(128 + @intFromEnum(s))),
        else => std.process.exit(1),
    }
}

fn fail(msg: []const u8) noreturn {
    std.debug.print("piz sandbox-exec: {s}\n", .{msg});
    std.process.exit(2);
}

fn underPrefix(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    if (path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/') return true;
    return false;
}

/// 组装 bash argv。mode=off 就是 `sh -c command`。
/// extras 是额外可写目录(artifacts);已落在 workspace 下的会跳过。
pub fn buildArgv(
    arena: std.mem.Allocator,
    mode: Mode,
    bwrap: []const u8,
    workspace: []const u8,
    extras: []const []const u8,
    command: []const u8,
    chdir: []const u8,
) ![]const []const u8 {
    if (mode == .off) {
        const argv = try arena.alloc([]const u8, 3);
        argv[0] = "sh";
        argv[1] = "-c";
        argv[2] = command;
        return argv;
    }

    var list = std.array_list.Managed([]const u8).init(arena);
    try list.appendSlice(&.{ bwrap, "--die-with-parent", "--unshare-pid" });
    const isolate_fs = workspace.len > 0 and !std.mem.eql(u8, workspace, "/");
    if (isolate_fs) {
        try list.appendSlice(&.{ "--ro-bind", "/", "/" });
        // 敏感凭证遮蔽 (Sensitive Path Masking):
        // 挂载 / 为只读虽阻断了写改,但在可出网模式下仍可通过网络外泄凭据。
        // 对 SSH / 云凭据 / API key / 影子文件实施空挂载隔离。
        if (util.getEnv("HOME")) |home| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const sensitive_dirs = [_][]const u8{ ".ssh", ".aws", ".gnupg" };
            for (sensitive_dirs) |sub| {
                const target = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, sub }) catch continue;
                if (!underPrefix(target, workspace) and util.dirExists(target)) {
                    var in_extras = false;
                    for (extras) |ep| {
                        if (underPrefix(target, ep)) {
                            in_extras = true;
                            break;
                        }
                    }
                    if (!in_extras) {
                        try list.appendSlice(&.{ "--tmpfs", try arena.dupe(u8, target) });
                    }
                }
            }
            const sensitive_files = [_][]const u8{ ".piz/auth.json", ".piz/models.json" };
            for (sensitive_files) |sub| {
                const target = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, sub }) catch continue;
                if (!underPrefix(target, workspace) and util.fileExists(target)) {
                    var in_extras = false;
                    for (extras) |ep| {
                        if (underPrefix(target, ep)) {
                            in_extras = true;
                            break;
                        }
                    }
                    if (!in_extras) {
                        try list.appendSlice(&.{ "--ro-bind", "/dev/null", try arena.dupe(u8, target) });
                    }
                }
            }
        }
        const sys_files = [_][]const u8{ "/etc/shadow", "/etc/sudoers" };
        for (sys_files) |sf| {
            if (!underPrefix(sf, workspace) and util.fileExists(sf)) {
                try list.appendSlice(&.{ "--ro-bind", "/dev/null", sf });
            }
        }
    }
    try list.appendSlice(&.{ "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp" });
    if (isolate_fs) {
        try list.appendSlice(&.{ "--bind", workspace, workspace });
        for (extras) |p| {
            if (p.len == 0) continue;
            if (underPrefix(p, workspace)) continue;
            try list.appendSlice(&.{ "--bind", p, p });
        }
    }
    if (mode == .strict) try list.append("--unshare-net");
    const start = if (chdir.len > 0) chdir else workspace;
    if (start.len > 0) try list.appendSlice(&.{ "--chdir", start });
    try list.appendSlice(&.{ "--", "sh", "-c", command });
    return list.toOwnedSlice();
}

pub fn missingSandboxMsg(arena: std.mem.Allocator, mode: Mode) []const u8 {
    return std.fmt.allocPrint(
        arena,
        "error: sandbox={s} needs bubblewrap (bwrap) or a Landlock-capable kernel. Install bwrap or run /sandbox off.",
        .{mode.label()},
    ) catch "error: sandbox needs bwrap or landlock";
}

/// 兼容旧名。
pub const missingBwrapMsg = missingSandboxMsg;

test "Mode parse aliases" {
    const t = std.testing;
    try t.expect(Mode.parse("off").? == .off);
    try t.expect(Mode.parse("none").? == .off);
    try t.expect(Mode.parse("workspace").? == .workspace);
    try t.expect(Mode.parse("workspace-write").? == .workspace);
    try t.expect(Mode.parse("strict").? == .strict);
    try t.expect(Mode.parse("no-net").? == .strict);
    try t.expect(Mode.parse("nope") == null);
    try t.expectEqualStrings("workspace", Mode.workspace.label());
}

test "buildArgv off is plain sh" {
    const t = std.testing;
    const argv = try buildArgv(t.allocator, .off, "/usr/bin/bwrap", "/proj", &.{}, "echo hi", "");
    defer t.allocator.free(argv);
    try t.expectEqual(@as(usize, 3), argv.len);
    try t.expectEqualStrings("sh", argv[0]);
    try t.expectEqualStrings("-c", argv[1]);
    try t.expectEqualStrings("echo hi", argv[2]);
}

test "buildArgv workspace binds root and not net" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const extras = [_][]const u8{"/home/u/.piz/artifacts"};
    const argv = try buildArgv(a, .workspace, "/usr/bin/bwrap", "/proj", &extras, "make", "");
    try t.expectEqualStrings("/usr/bin/bwrap", argv[0]);
    var saw_ro = false;
    var saw_ws = false;
    var saw_art = false;
    var saw_net = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--ro-bind") and i + 2 < argv.len and
            std.mem.eql(u8, argv[i + 1], "/") and std.mem.eql(u8, argv[i + 2], "/"))
            saw_ro = true;
        if (std.mem.eql(u8, argv[i], "--bind") and i + 2 < argv.len and std.mem.eql(u8, argv[i + 1], "/proj"))
            saw_ws = true;
        if (std.mem.eql(u8, argv[i], "--bind") and i + 2 < argv.len and std.mem.eql(u8, argv[i + 1], extras[0]))
            saw_art = true;
        if (std.mem.eql(u8, argv[i], "--unshare-net")) saw_net = true;
    }
    try t.expect(saw_ro);
    try t.expect(saw_ws);
    try t.expect(saw_art);
    try t.expect(!saw_net);
}

test "buildArgv strict unshares net and skips extra inside workspace" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const extras = [_][]const u8{"/proj/.piz/artifacts"};
    const argv = try buildArgv(a, .strict, "/usr/bin/bwrap", "/proj", &extras, "curl x", "");
    var saw_net = false;
    var saw_inner = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--unshare-net")) saw_net = true;
        if (std.mem.eql(u8, arg, "/proj/.piz/artifacts")) saw_inner = true;
    }
    try t.expect(saw_net);
    try t.expect(!saw_inner);
}

test "buildLandlockArgv uses sandbox-exec" {
    const t = std.testing;
    const extras = [_][]const u8{"/home/u/.piz/artifacts"};
    const argv = try buildLandlockArgv(t.allocator, "/opt/piz", .workspace, "/proj", &extras, "make", "");
    defer t.allocator.free(argv);
    try t.expectEqualStrings("/opt/piz", argv[0]);
    try t.expectEqualStrings("sandbox-exec", argv[1]);
    var saw_dir = false;
    var saw_allow = false;
    var saw_tmp = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--dir") and i + 1 < argv.len)
            saw_dir = std.mem.eql(u8, argv[i + 1], "/proj");
        if (std.mem.eql(u8, argv[i], "--allow") and i + 1 < argv.len and std.mem.eql(u8, argv[i + 1], extras[0]))
            saw_allow = true;
        if (std.mem.eql(u8, argv[i], "/tmp")) saw_tmp = true;
    }
    try t.expect(saw_dir);
    try t.expect(saw_allow);
    try t.expect(saw_tmp);
}

test "buildArgv chdir overrides workspace start" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try buildArgv(a, .workspace, "/usr/bin/bwrap", "/proj", &.{}, "pwd", "/proj/src");
    var saw = false;
    var i: usize = 0;
    while (i + 1 < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--chdir") and std.mem.eql(u8, argv[i + 1], "/proj/src")) saw = true;
    }
    try t.expect(saw);
    const ll = try buildLandlockArgv(a, "/opt/piz", .workspace, "/proj", &.{}, "pwd", "/proj/src");
    var saw_ll = false;
    i = 0;
    while (i + 1 < ll.len) : (i += 1) {
        if (std.mem.eql(u8, ll[i], "--chdir") and std.mem.eql(u8, ll[i + 1], "/proj/src")) saw_ll = true;
    }
    try t.expect(saw_ll);
}

test "landlockAbi probes this kernel" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const abi = landlockAbi() orelse return error.SkipZigTest;
    try std.testing.expect(abi >= 1);
}

test "describe names the live backend" {
    const t = std.testing;
    const off = try describe(t.allocator, .off);
    defer t.allocator.free(off);
    try t.expectEqualStrings("off", off);
    const ws = try describe(t.allocator, .workspace);
    defer t.allocator.free(ws);
    try t.expect(std.mem.startsWith(u8, ws, "workspace/"));
    if (findBwrap() != null) {
        try t.expectEqualStrings("workspace/bwrap", ws);
    } else if (landlockAbi() != null) {
        try t.expectEqualStrings("workspace/landlock", ws);
    } else {
        try t.expectEqualStrings("workspace/none", ws);
    }
}

test "buildArgv masks sensitive files and directories" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const fake_home = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}/home", .{ cwd_abs, tmp.sub_path });
    try std.Io.Dir.cwd().createDirPath(util.io, fake_home);

    const ssh_dir = try std.fmt.allocPrint(a, "{s}/.ssh", .{fake_home});
    try std.Io.Dir.cwd().createDirPath(util.io, ssh_dir);

    const auth_file = try std.fmt.allocPrint(a, "{s}/.piz/auth.json", .{fake_home});
    try std.Io.Dir.cwd().createDirPath(util.io, std.fs.path.dirname(auth_file).?);
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = auth_file, .data = "{}" });

    try util.environ_map.?.put("HOME", fake_home);

    const argv = try buildArgv(a, .workspace, "/usr/bin/bwrap", "/tmp/myproj", &.{}, "ls", "");

    var masked_ssh = false;
    var masked_auth = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--tmpfs") and i + 1 < argv.len and std.mem.eql(u8, argv[i + 1], ssh_dir)) {
            masked_ssh = true;
        }
        if (std.mem.eql(u8, argv[i], "--ro-bind") and i + 2 < argv.len and
            std.mem.eql(u8, argv[i + 1], "/dev/null") and std.mem.eql(u8, argv[i + 2], auth_file))
        {
            masked_auth = true;
        }
    }
    try t.expect(masked_ssh);
    try t.expect(masked_auth);
}
