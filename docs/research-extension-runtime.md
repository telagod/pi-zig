# 扩展运行时选型调研（2026-08，QuickJS-ng 已落地）

> 状态：选项 2 已于 1873e2f 落地（窄桥），用法见 [extensions-js.md](extensions-js.md)。
> ESM/import/async/TS 已落地(见 docs/extensions-js.md);WASM 沙箱仍后置。下文留调研原貌。

背景：piz 现为纯编译期插件表（Zig @embed/comptime），改扩展须重编（增量秒级）。
目标：扩展免编译 + 保住「单文件、静态、零依赖、低占用」。

## 现状已有的零成本答案：MCP

piz 已内置 MCP client（`/mcp`）。MCP server = 任意语言、stdio JSON-RPC、
进程边界即权限边界、崩溃隔离的运行时「工具型」插件。**工具扩展今天就有**，
缺的是进程内钩子（事件订阅、UI 通知、tool_call 拦截）与 pi 扩展生态兼容。

## 候选与硬数据

| 方案 | 二进制增量 | 内存增量 | 维护（gh pushed_at) | 生态兼容 | 沙箱 |
|---|---|---|---|---|---|
| QuickJS-ng | +1.1 MB（含 musl) | ~1.1 MB/ctx | 活跃（2026-08-16) | **JS——与 pi 扩展同语言** | 自建（host fn 白名单） |
| bellard/quickjs | 同上 | 同上 | 活跃（2026-06) | 同上 | 同上 |
| WAMR | +~1 MB | 视 AOT/interp | 活跃（Bytecode Alliance,2026-08-18) | 否（须编译 wasm) | **天然（线性内存+import 白名单）** |
| wasm3 | +~200 KB | 小 | 活跃（2026-08-19，纯解释） | 否 | 天然 |
| Lua 5.4 | +~200 KB | 极小 | 稳定 | 孤岛 | 自建 |
| LuaJIT | +~600 KB | 小 | 官方冻结，慎入 | 孤岛 | 自建 |
| mujs/JerryScript | +~300 KB | 小 | mujs 活跃但 ES5-ish;JerryScript 2025-10 后安静 | 半残 JS | 自建 |
| 子进程协议（MCP 扩） | +0 | 另起进程 | — | 任意语言 | 进程边界 |
| Zig 运行时编译+dlopen | 不可行：musl 静态无 dlopen，且须 zig 在场，违背零依赖 | | | | |

QuickJS-ng 已实测：zig cc + musl 静态一次编过（4 个 .c:dtoa/libregexp/
libunicode/quickjs,+quickjs-libc),strip 后引擎+musl 共 1.13 MB,
跑 1e6 循环 RSS 1.1 MB。注意：ng 已并件，无 cutils.c/xsum.c。

## pi 扩展 API 面（docs/extensions.md 实测）

- 入口：`export default function(pi: ExtensionAPI)`,TS 模块
- 能力：`pi.on(事件)`（启动/资源/会话/agent/模型/工具/bash/输入 八类几十种）、
  `pi.registerTool`、`pi.registerCommand`、`pi.sendMessage`、`pi.appendEntry`、
  `ctx.ui.*`（notify/confirm/dialog)、`ctx` 会话控制（compact/fork/navigate/
  switchSession/reload…)
- 全量兼容 = 大工程（文档 104 处 pi.* 调用）；窄桥子集（on/registerTool/
  registerCommand + ctx.ui.notify/confirm + 核心事件）可覆盖常见扩展大半
- **TS 障碍**：pi 扩展多为 .ts,QuickJS 只认 JS。须加类型剥离层
  （sucrase 类）或先只支持 .js 扩展

## 落地账（实证 2026-08-20）

- 体积：4.85MB ↔ 5.97MB（-Dquickjs 开/关），+1.13MB 与探针预测一致；musl 仍零依赖
- 四入口接线：CLI/TUI/web/print；357 测试绿
- 雷：`JS_Eval` 词法器瞥 `input[len]`，必须 NUL 结尾缓冲（jsrt.zig evalFile 详注）

## 判断

1. **工具型扩展**:MCP 已够，文档化即可，+0 成本。
2. **进程内钩子 + pi 生态**:QuickJS-ng 是唯一同时满足「同语言生态、可嵌、
   活跃、体积可控」的选项。Lua 系全是孤岛；WASM 系沙箱漂亮但扩展须预编译、
   桥走线性内存，成本高且不兼容 pi。
3. **WASM 留作远期**：若将来要跑「不可信第三方扩展」，WAMR 的
   import 白名单 + 内存隔离比 JS 沙箱硬得多。第一步不上。

## 若落地（窄桥先行）—— 已落地，下为原始方案留档

- vendor quickjs-ng 进 build.zig,feature flag `-Dquickjs` 可关
- 桥面：`piz.on(event, fn)` / `piz.registerTool(def)` / `piz.registerCommand`
  + `ctx.notify/confirm` 子集；事件先接 session_start、tool_call、tool_result
- 权限：扩展注册的 tool 走现有 permissions/沙箱同一闸
- ~~TS 剥离后置~~ 已落地(sucrase 内嵌,见 extensions-js.md)
- 内存纪律：JS 侧对象进出即拷贝，不留跨 GC/arena 引用
