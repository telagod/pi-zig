// events.zig — 事件总线 + 包扩展声明(对齐 pi extensions 的最小可用版)。
// 包内 pkg.json 声明扩展:
//   {"extensions":[{"name":"notify","events":{"tool_end":"echo done","turn_end":"/x.sh"}}]}
// 事件触发时 spawn `bash -c <command>`,JSON 上下文({type,...})经 stdin 传入。
// 命令 detach 执行(不阻塞主流程;父进程退出后由 init 收养)。
const std = @import("std");
const util = @import("util.zig");
const pkgsmod = @import("pkgs.zig");

/// 单条事件订阅:事件名 → 命令。
pub const Handler = struct {
    event: []const u8,
    command: []const u8,
};

/// 事件总线:扫描包扩展声明,emit 时执行匹配命令。
pub const Bus = struct {
    alloc: std.mem.Allocator,
    handlers: []Handler = &.{},

    pub fn init(alloc: std.mem.Allocator) !Bus {
        var hs = std.array_list.Managed(Handler).init(alloc);
        // 扫描全部资源包的 pkg.json extensions 声明
        if (pkgsmod.allPkgDirs(alloc, null)) |pkgs| {
            for (pkgs) |pkg| {
                try scanPkg(alloc, &hs, pkg);
            }
        } else |_| {}
        return .{ .alloc = alloc, .handlers = try hs.toOwnedSlice() };
    }

    /// 从包 pkg.json 收集 events 钩子。
    ///
    /// 复用 pkgs.declaredHooks —— `pkg install` 的确认提示用的是同一个解析器。
    /// 两份实现会让「提示的」和「实际跑的」出现差异,那比不提示更糟。
    fn scanPkg(alloc: std.mem.Allocator, hs: *std.array_list.Managed(Handler), pkg_dir: []const u8) !void {
        const declared = pkgsmod.declaredHooks(alloc, pkg_dir) catch return;
        for (declared) |d| {
            try hs.append(.{ .event = d.event, .command = d.command });
        }
    }

    /// 触发事件:执行所有匹配 handler,JSON 上下文走 stdin。detach 不等待。
    pub fn emit(self: *Bus, name: []const u8, data_json: []const u8) void {
        // 组装 {"type":name, ...data}
        var ww = std.Io.Writer.Allocating.init(self.alloc);
        defer ww.deinit();
        ww.writer.print("{{\"type\":{s}", .{util.jsonString(self.alloc, name) catch "\"\""}) catch return;
        if (data_json.len > 0) {
            ww.writer.print(",{s}", .{data_json}) catch return;
        }
        ww.writer.writeAll("}") catch return;
        const payload = ww.toOwnedSlice() catch return;
        defer self.alloc.free(payload);

        for (self.handlers) |h| {
            if (!std.mem.eql(u8, h.event, name)) continue;
            const child = std.process.spawn(util.io, .{
                .argv = &.{ "bash", "-c", h.command },
                .stdin = .pipe,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch continue;
            // 写 JSON 上下文并关闭 stdin
            if (child.stdin) |f| {
                var wbuf: [4096]u8 = undefined;
                var w = f.writer(util.io, &wbuf);
                w.interface.writeAll(payload) catch {};
                w.flush() catch {};
                f.close(util.io);
            }
            // detach:不 wait(短命令;进程退出后由 init 收养)
        }
    }
};

test "bus emit runs commands" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 手工构造 handler(不依赖包扫描):tool_end → 写文件
    var bus = Bus{ .alloc = a };
    const log = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}/ext.log", .{
        try std.process.currentPathAlloc(util.io, a), tmp.sub_path,
    });
    defer std.Io.Dir.cwd().deleteFile(util.io, log) catch {}; // deleteTree 对含文件目录不可靠,手动清
    const cmd = try std.fmt.allocPrint(a, "cat >> {s}", .{log});
    bus.handlers = try a.dupe(Handler, &.{
        .{ .event = "tool_end", .command = cmd },
    });

    bus.emit("tool_end", "\"tool\":\"bash\",\"error\":false");
    bus.emit("turn_end", "");
    // 等待子进程写完(轮询 2s)
    var ok = false;
    for (0..40) |_| {
        if (std.Io.Dir.cwd().readFileAlloc(util.io, log, a, .limited(4096))) |content| {
            defer a.free(content);
            if (std.mem.indexOf(u8, content, "tool_end") != null) {
                ok = true;
                break;
            }
        } else |_| {}
        _ = std.Io.sleep(util.io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
    }
    try t.expect(ok);
    // 不匹配事件不执行
    try t.expect(std.mem.indexOf(u8, try std.Io.Dir.cwd().readFileAlloc(util.io, log, a, .limited(4096)), "turn_end") == null);
}

test "bus discovers handlers declared by an installed package" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 上一条测试手工塞 handler,绕过了包扫描 —— 于是「装包声明的钩子真能生效」
    // 这条链路从没被验证过。这里造一个真实的已装包目录走 Bus.init。
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    const pkg_dir = try std.fmt.allocPrint(a, "{s}/packages/hooked", .{tmp_path});
    try std.Io.Dir.cwd().createDirPath(util.io, pkg_dir);
    const pkg_json = try util.joinPath(a, pkg_dir, "pkg.json");
    try std.Io.Dir.cwd().writeFile(util.io, .{
        .sub_path = pkg_json,
        .data =
        \\{"name":"hooked","version":"1.0.0","extensions":[{"events":{"startup":"true"}}]}
        ,
    });
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, pkg_json) catch {};
        std.Io.Dir.cwd().deleteDir(util.io, pkg_dir) catch {};
        if (std.fmt.allocPrint(a, "{s}/packages", .{tmp_path})) |pd| {
            std.Io.Dir.cwd().deleteDir(util.io, pd) catch {};
        } else |_| {}
    }

    const bus = try Bus.init(a);
    // 装包声明的 startup 钩子必须被发现。发现不了意味着 events 扩展整体是死的:
    // 文档说支持,实际装了包什么都不会发生。
    var found = false;
    for (bus.handlers) |h| {
        if (std.mem.eql(u8, h.event, "startup")) found = true;
    }
    try t.expect(found);
}
