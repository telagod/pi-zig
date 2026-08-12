const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // 默认 ReleaseFast:标准库的 standardOptimizeOption 的 preferred 模式
    // 只在传 --release 时才生效,裸 `zig build` 会静默产出 Debug ——
    // README 安装指引就是裸 `zig build`,用户照做拿到的是带调试信息的
    // 46MB 慢二进制。这里反过来:默认快,想调试传 -Doptimize=Debug。
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Override the default ReleaseFast (e.g. -Doptimize=Debug)") orelse .ReleaseFast;

    // ---- 模块拆分(对齐 pi 子包结构) ----
    // core:agent 循环、AI 客户端、工具、会话、配置、包管理
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
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
    const run_app_tests = b.addRunArtifact(app_tests);
    // 委托的 e2e 测试要 spawn 真实 piz 子进程(zig-out/bin/piz)。
    // 依赖 install:否则首次 `zig build test` 时产物不存在,那条测试静默
    // SkipZigTest —— 整条委托链路等于没测,却仍报「全部通过」。
    run_app_tests.step.dependOn(b.getInstallStep());
    // 测试后清理 .zig-cache/tmp(测试并行/zig build 探测进程的 tmpDir 残留)
    const clean_tmp = b.addSystemCommand(&.{ "rm", "-rf", ".zig-cache/tmp" });
    clean_tmp.step.dependOn(&run_core_tests.step);
    clean_tmp.step.dependOn(&run_app_tests.step);
    const test_step = b.step("test", "Run unit + e2e tests");
    test_step.dependOn(&clean_tmp.step);
}
