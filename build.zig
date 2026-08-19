const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // 默认 ReleaseFast:标准库的 standardOptimizeOption 的 preferred 模式
    // 只在传 --release 时才生效,裸 `zig build` 会静默产出 Debug ——
    // README 安装指引就是裸 `zig build`,用户照做拿到的是带调试信息的
    // 46MB 慢二进制。这里反过来:默认快,想调试传 -Doptimize=Debug。
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Override the default ReleaseFast (e.g. -Doptimize=Debug)") orelse .ReleaseFast;
    // 嵌 QuickJS 扩展运行时(vendor/quickjs-ng,MIT):运行时 JS 钩子/工具/命令。
    // 开启后链接 libc(linux 静态发布请配 -Dtarget=x86_64-linux-musl);关则无 libc 纯静态。
    const quickjs = b.option(bool, "quickjs", "Embed QuickJS extension runtime (vendor/quickjs-ng)") orelse true;
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "quickjs", quickjs);

    // qjs C 单元 + 头路径挂到指定模块。libc 开时 vendor/shim 必须让位(否则假 stdlib.h 遮蔽真头)。
    const qjs_files = [_][]const u8{ "quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c", "quickjs-libc.c" };
    const qjs_flags = [_][]const u8{ "-std=c11", "-O2", "-DQUICKJS_NG_BUILD", "-DQJS_BUILD_LIBC", "-D_GNU_SOURCE", "-Wno-unused-parameter", "-Wno-unused-but-set-variable" };
    const attachQjs = struct {
        fn f(m: *std.Build.Module, bb: *std.Build, on: bool, files: []const []const u8, flags: []const []const u8) void {
            if (on) {
                m.link_libc = true;
                m.addCSourceFiles(.{ .root = bb.path("vendor/quickjs-ng"), .files = files, .flags = flags });
                m.addIncludePath(bb.path("vendor/quickjs-ng"));
            }
        }
    }.f;

    // ---- 模块拆分(对齐 pi 子包结构) ----
    // core:agent 循环、AI 客户端、工具、会话、配置、包管理
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    // stb 图像编解码实现单元(无 libc:内存/内存拷贝全由 imgx.zig 导出函数供给)
    core_mod.addCSourceFile(.{
        .file = b.path("vendor/stb_impl.c"),
        .flags = &.{ "-std=c99", "-O2" },
    });
    // shim 在前:无 libc 时 <stdlib.h> 等落到 shim,不碰系统头。
    // 有 libc(quickjs 开)时 shim 必须缺席,否则假头遮蔽真头。
    if (!quickjs) core_mod.addIncludePath(b.path("vendor/shim"));
    core_mod.addIncludePath(b.path("vendor"));
    core_mod.addOptions("build_options", build_opts);
    attachQjs(core_mod, b, quickjs, &qjs_files, &qjs_flags);
    // tui:终端界面
    const tui_mod = b.createModule(.{
        .root_source_file = b.path("src/tui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
        },
    });
    // app:CLI 入口(main)
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "tui", .module = tui_mod },
        },
    });

    // ---- lib 目标(core + tui 可独立链接) ----
    const core_lib = b.addLibrary(.{
        .name = "piz-core",
        .root_module = core_mod,
        .linkage = .static,
    });
    b.installArtifact(core_lib);
    const tui_lib = b.addLibrary(.{
        .name = "piz-tui",
        .root_module = tui_mod,
        .linkage = .static,
    });
    b.installArtifact(tui_lib);

    // ---- CLI ----
    const exe = b.addExecutable(.{
        .name = "piz",
        .root_module = app_mod,
    });
    // Release 剥离调试信息:46MB→20MB 全是 dwarf,strip 后个位数 MB。
    // Debug 保留符号供 gdb / panic 栈回溯。
    exe.root_module.strip = optimize != .Debug;
    // qjs 的 C 对象在 core 模块里,最终链 exe 需 libc 登场。
    if (quickjs) exe.root_module.link_libc = true;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run piz");
    run_step.dependOn(&run_cmd.step);

    // ---- 测试(独立 Debug 模块;zig test 只收集根模块测试,故 core 与 app 各一目标) ----
    const test_core = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = .Debug,
    });
    // test 模块是独立 createModule,不会继承 core_mod 的 C 单元 —— 重复挂载
    test_core.addCSourceFile(.{
        .file = b.path("vendor/stb_impl.c"),
        .flags = &.{ "-std=c99", "-O2" },
    });
    if (!quickjs) test_core.addIncludePath(b.path("vendor/shim"));
    test_core.addIncludePath(b.path("vendor"));
    test_core.addOptions("build_options", build_opts);
    attachQjs(test_core, b, quickjs, &qjs_files, &qjs_flags);
    const test_tui = b.createModule(.{
        .root_source_file = b.path("src/tui.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "core", .module = test_core },
        },
    });
    const core_tests = b.addTest(.{ .root_module = test_core });
    core_tests.root_module.link_libc = true; // 测试需进程环境(std.c.environ)
    const tui_tests = b.addTest(.{ .root_module = test_tui });
    tui_tests.root_module.link_libc = true;
    const app_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "core", .module = test_core },
                .{ .name = "tui", .module = test_tui },
            },
        }),
    });
    app_tests.root_module.link_libc = true; // 测试需进程环境(std.c.environ)
    const run_core_tests = b.addRunArtifact(core_tests);
    const run_tui_tests = b.addRunArtifact(tui_tests);
    const run_app_tests = b.addRunArtifact(app_tests);
    // 委托的 e2e 测试要 spawn 真实 piz 子进程(zig-out/bin/piz)。
    // 依赖 install:否则首次 `zig build test` 时产物不存在,那条测试静默
    // SkipZigTest —— 整条委托链路等于没测,却仍报「全部通过」。
    run_app_tests.step.dependOn(b.getInstallStep());
    // 测试后清理 .zig-cache/tmp(测试并行/zig build 探测进程的 tmpDir 残留)
    const clean_tmp = b.addSystemCommand(&.{ "rm", "-rf", ".zig-cache/tmp" });
    clean_tmp.step.dependOn(&run_core_tests.step);
    clean_tmp.step.dependOn(&run_tui_tests.step);
    clean_tmp.step.dependOn(&run_app_tests.step);
    const test_step = b.step("test", "Run unit + e2e tests");
    test_step.dependOn(&clean_tmp.step);
}
