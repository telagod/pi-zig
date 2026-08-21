// cmd_pkg.zig — piz pkg 子命令:install / list / update / remove。
const std = @import("std");
const util = @import("core").util;
const pkgsmod = @import("core").pkgs;

/// 确认包目录声明的 events 钩子。返回 true 表示可以继续。
///
/// 包里的 `extensions.events` 会由 events.Bus 以 `bash -c` 执行,`startup` 钩子
/// 在下次启动时立刻跑 —— 装包等于授权本机命令执行。没有钩子的包直接放行
/// (大多数包如此),有钩子就把命令原文列出来让用户看。
///
/// stdin 不是终端时(脚本、管道)拒绝而非默认同意:静默授权任意命令执行
/// 比让脚本报错糟得多。需要非交互装包就显式加 `-y`。
///
/// 两个调用时机:本地源在拷贝**之前**问(干净,不用回滚);git 源那时还没 clone、
/// 拿不到 pkg.json,只能装完再问,拒绝时由调用方删掉包目录 —— 钩子要到下次启动
/// 才跑,此刻撤销仍然来得及。
fn confirmPkgHooks(alloc: std.mem.Allocator, pkg_dir: []const u8, prompt: []const u8, assume_yes: bool) bool {
    const hooks = pkgsmod.declaredHooks(alloc, pkg_dir) catch &.{};
    const tools = pkgsmod.declaredTools(alloc, pkg_dir) catch &.{};
    if (hooks.len == 0 and tools.len == 0) return true;

    if (hooks.len > 0) {
        std.debug.print("\n这个包声明了 {d} 个生命周期钩子,会以 `bash -c` 执行:\n\n", .{hooks.len});
        for (hooks) |h| {
            std.debug.print("  [{s}] {s}\n", .{ h.event, h.command });
        }
        std.debug.print("\n其中 startup 钩子会在下次启动 piz 时立刻运行。\n", .{});
    }
    if (tools.len > 0) {
        std.debug.print("\n这个包声明了 {d} 个工具,模型可调用,同样走 `bash -c`:\n\n", .{tools.len});
        for (tools) |t| {
            std.debug.print("  {s}  {s}\n", .{ t.name, t.command });
        }
    }
    if (assume_yes) {
        std.debug.print("(-y 已指定,继续)\n\n", .{});
        return true;
    }
    if (!util.stdinIsTty()) {
        std.debug.print("stdin 不是终端,无法确认。确认要装请加 -y。\n", .{});
        return false;
    }
    std.debug.print("{s} [y/N] ", .{prompt});
    var buf: [16]u8 = undefined;
    const line = util.readLineStdin(&buf) orelse return false;
    const ans = std.mem.trim(u8, line, " \t\r\n");
    return std.mem.eql(u8, ans, "y") or std.mem.eql(u8, ans, "Y") or std.mem.eql(u8, ans, "yes");
}

/// pkg 子命令:install <path> [-l] | list | remove <name> [-l]
pub fn runPkgCmd(alloc: std.mem.Allocator, args: *std.process.Args.Iterator) void {
    const sub = args.next() orelse {
        std.debug.print("piz pkg: usage: install <path> [-l] | list | remove <name> [-l]\n", .{});
        std.process.exit(1);
    };
    const proj_cwd = std.process.currentPathAlloc(util.io, alloc) catch null;
    if (std.mem.eql(u8, sub, "list")) {
        const user = pkgsmod.list(alloc, .user, proj_cwd) catch &.{};
        const proj = pkgsmod.list(alloc, .project, proj_cwd) catch &.{};
        std.debug.print("user packages ({d}):\n", .{user.len});
        for (user) |p| {
            std.debug.print("  {s}  skills:{d} prompts:{d}{s}{s}\n", .{ p.name, p.skills, p.prompts, if (p.has_agents) " agents:yes" else "", if (p.has_web) " web:yes" else "" });
        }
        std.debug.print("project packages ({d}):\n", .{proj.len});
        for (proj) |p| {
            std.debug.print("  {s}  skills:{d} prompts:{d}{s}{s}\n", .{ p.name, p.skills, p.prompts, if (p.has_agents) " agents:yes" else "", if (p.has_web) " web:yes" else "" });
        }
        if (user.len + proj.len == 0) std.debug.print("  (none)\n", .{});
        std.process.exit(0);
    }
    if (std.mem.eql(u8, sub, "install")) {
        const src = args.next() orelse {
            std.debug.print("piz pkg install: usage: piz pkg install <path|git-url|name@repo> [-l] [-y]\n", .{});
            std.process.exit(1);
        };
        var scope = pkgsmod.Scope.user;
        var assume_yes = false;
        while (args.next()) |extra| {
            if (std.mem.eql(u8, extra, "-l") or std.mem.eql(u8, extra, "--local")) {
                scope = .project;
            } else if (std.mem.eql(u8, extra, "-y") or std.mem.eql(u8, extra, "--yes")) {
                assume_yes = true;
            } else {
                std.debug.print("piz pkg install: unknown option {s}\n", .{extra});
                std.process.exit(1);
            }
        }
        // 包声明的 events 钩子会在 agent 生命周期各点跑 `bash -c <command>`,
        // startup 钩子在下次启动时立刻执行。装包因此等于授权本机命令执行 ——
        // 装之前必须让用户看见到底授权了什么。
        //
        // 本地源在这里问(拒绝就直接不装);git 源此刻还没 clone,见下面装后那一步。
        const local_src: ?[]const u8 = switch (pkgsmod.detectSource(src)) {
            .path => |p| p,
            .git => null,
        };
        if (local_src) |p| {
            if (!confirmPkgHooks(alloc, p, "继续安装?", assume_yes)) {
                std.debug.print("piz pkg install: 已取消。\n", .{});
                std.process.exit(1);
            }
        }
        const dest = pkgsmod.install(alloc, src, scope, proj_cwd) catch |err| {
            std.debug.print("piz pkg install: failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        // git 源在上一步还没 clone,只能装完再看(本地源已经问过,那时 hooks
        // 已确认,这里 declaredHooks 会再列一次 —— 所以只对 git 源做)。
        // 用户拒绝就删掉:钩子要到下次启动才跑,此刻撤销来得及。
        if (local_src == null and !confirmPkgHooks(alloc, dest, "保留这个包?", assume_yes)) {
            std.Io.Dir.cwd().deleteTree(util.io, dest) catch |err| {
                std.debug.print("piz pkg install: 已取消,但删除 {s} 失败({s})——请手动删除。\n", .{ dest, @errorName(err) });
                std.process.exit(1);
            };
            std.debug.print("piz pkg install: 已取消,已移除 {s}。\n", .{dest});
            std.process.exit(1);
        }
        std.debug.print("installed {s} → {s}\n", .{ src, dest });
        std.process.exit(0);
    }
    if (std.mem.eql(u8, sub, "update")) {
        var scope = pkgsmod.Scope.user;
        if (args.next()) |extra| {
            if (std.mem.eql(u8, extra, "-l") or std.mem.eql(u8, extra, "--local")) {
                scope = .project;
            } else {
                std.debug.print("piz pkg update: unknown option {s}\n", .{extra});
                std.process.exit(1);
            }
        }
        const n = pkgsmod.update(alloc, scope, proj_cwd) catch |err| {
            std.debug.print("piz pkg update: failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        std.debug.print("updated {d} packages\n", .{n});
        std.process.exit(0);
    }
    if (std.mem.eql(u8, sub, "remove")) {
        const name = args.next() orelse {
            std.debug.print("piz pkg remove: usage: piz pkg remove <name> [-l]\n", .{});
            std.process.exit(1);
        };
        var scope = pkgsmod.Scope.user;
        if (args.next()) |extra| {
            if (std.mem.eql(u8, extra, "-l") or std.mem.eql(u8, extra, "--local")) {
                scope = .project;
            } else {
                std.debug.print("piz pkg remove: unknown option {s}\n", .{extra});
                std.process.exit(1);
            }
        }
        pkgsmod.remove(alloc, name, scope, proj_cwd) catch |err| {
            std.debug.print("piz pkg remove: failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        std.debug.print("removed {s}\n", .{name});
        std.process.exit(0);
    }
    std.debug.print("piz pkg: unknown subcommand {s}\n", .{sub});
    std.process.exit(1);
}
