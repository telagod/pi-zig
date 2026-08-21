> piz 可以帮你写 piz。让它读 `docs/architecture.md`，然后描述你想加的能力。

# piz 文档

piz 是一个极简的终端编码 agent，用 Zig 重写自 [pi](https://pi.dev)。核心保持小巧，能力通过内置插件扩展。

设计取向与 pi 一致：核心只做「消息组装 → provider 调用 → 工具执行 → 压缩」这条主链路；其余能力（跨会话记忆、上下文预剪枝、任务委托、结构化计划）都是编译期注册的插件，随二进制发布，零配置生效。

与 pi 的关键差异：

- **单一静态二进制**，无 Node.js 运行时，无 `node_modules`
- **Zig 标准库 + vendored stb**（读图）；正则和 glob 是自己的
- **内置 Web UI**（`piz web`），pi 没有
- **LSP 代码智能**（`lsp` 工具），接真实语言服务器查定义/引用/重命名影响面
- **交互式权限门**、**OS sandbox**（`/sandbox workspace|strict`，bwrap）、`/plan`、结构化 todo 工具，这些是 pi 明确声明不做的
- 插件是**编译期**的 Zig 函数表，不是运行时加载的 TypeScript 模块
- **包可声明工具**（`pkg.json` `tools[]`），装包确认后模型可调，不必重编译
- **可贴图**（Web 剪贴板 / TUI `Ctrl+V`），续会话从图文件回放
- **`read` 带行号**；图片文件直接给 vision。搜索认目录级 `.gitignore`
- **`edit` 可 `replaceAll`**，并会剥掉从 `read` 抄来的行号。写盘不得逃出工作区
- **`ls` 默认不列 gitignored**；`grep` 可 `filesWithMatches`；`fetch_url` 拒内网
- **默认只暴露 8 个核心工具**，其余按需开启（`--plugin` 或 settings.json）

## 快速开始

```bash
zig build                      # 构建到 zig-out/bin/piz
export DEEPSEEK_API_KEY=sk-... # 或写入 ~/.piz/auth.json
./zig-out/bin/piz              # 在项目目录里启动交互模式
```

完整首次运行流程见 [Usage](usage.md)。

## 从这里开始

- [Usage](usage.md) — 交互模式、画面怎么读、斜杠命令、CLI、键位、限额
- [Tools](tools.md) — 内置工具完整参考，含每个工具的参数 schema
- [Configuration](configuration.md) — 配置文件、provider、认证、环境变量
- [Web UI](web-ui.md) — `piz web` 的启动、鉴权与端点

## 扩展

- [Plugins](plugins.md) — 内置插件清单、钩子契约、如何新增一个插件
- [Packages](packages.md) — 资源包（skills / prompts / AGENTS.md）、事件扩展、包声明工具
- [JS 扩展](extensions-js.md) — QuickJS 窄桥：加载位置、API、ESM/TS/async、fs/fetch 原语、热重载
- [Web plugins](web-plugins.md) — 给 Web UI 注入前端 JS/CSS
- [生态](ecosystem.md) — 三面总览、装包(git/marketplace)、写包、兼容与分发

## 参考

- [Sessions](sessions.md) — 会话存储、分支、JSONL 格式
- [Architecture](architecture.md) — 模块划分、构建目标、主链路时序、测试约定
- [模块规矩](modules.md) — 每模块职责/禁则/测试归处,review 依据

## 与 pi 的关系

piz 用**自己的**配置目录 `~/.piz`，不与 pi 共用。

配置**文件格式**兼容：`settings.json` / `auth.json` / `models.json` / `AGENTS.md` 可以从 `~/.pi/agent` 直接拷过来。资源包的约定目录结构（`skills/` `prompts/`）也兼容。

**会话文件格式不兼容**，无法迁移历史。这也正是不共用目录的原因 —— 早期版本共用 `sessions/`，导致 `/sessions` 列出 pi 的会话、选中后静默得到空历史。细节见 [Sessions](sessions.md#会话格式与-pi-的差异)。

许可证：piz 是 Apache-2.0，pi 是 MIT（Copyright (c) 2025 Mario Zechner）。
上游声明全文在仓库根的 `NOTICE`，随所有副本分发。
