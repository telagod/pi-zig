# piz

极简终端编码 agent。用 Zig 重写自 [pi](https://pi.dev)，核心保持小巧，能力通过内置插件扩展。

- **单个静态二进制**，无运行时依赖，无 `node_modules`
- **零第三方库**，只用 Zig 标准库（含自实现的正则与 glob 引擎）
- **默认 8 个核心工具**，其余按需开启；全部带完整 JSON Schema
- **内置 Web UI**，一条命令起本地界面
- **工具并行执行**，写操作按文件加锁
- **LSP 代码智能**，接真实语言服务器查定义/引用/重命名影响面

## 安装

需要 Zig 0.16。

```bash
git clone <repo> && cd pi-zig
zig build
./zig-out/bin/piz --help
```

## 快速开始

```bash
export DEEPSEEK_API_KEY=sk-...   # 或 ANTHROPIC_API_KEY，或写 ~/.piz/auth.json
cd ~/your-project
piz                              # 交互模式
```

一次性问答：

```bash
piz -p "解释这个仓库的构建流程"
echo "总结这个文件" | piz -p
```

Web UI：

```bash
piz web                          # 自动开浏览器，URL 带一次性 token
```

## 文档

从 [docs/index.md](docs/index.md) 开始。

| 文档 | 内容 |
|------|------|
| [Usage](docs/usage.md) | 交互模式、斜杠命令、CLI 参考、键位 |
| [Tools](docs/tools.md) | 核心工具与可选扩展的完整参数参考 |
| [Configuration](docs/configuration.md) | 配置文件、provider、认证、环境变量 |
| [Web UI](docs/web-ui.md) | `piz web` 启动、鉴权、HTTP 端点 |
| [Plugins](docs/plugins.md) | 内置插件、钩子契约、如何新增插件 |
| [Packages](docs/packages.md) | 资源包、skills、prompt 模板、事件扩展 |
| [Web plugins](docs/web-plugins.md) | 前端插件 SDK |
| [Sessions](docs/sessions.md) | 会话存储、分支、压缩、格式 |
| [Architecture](docs/architecture.md) | 模块划分、主链路、并发模型、测试约定 |

## 与 pi 的关系

piz 用自己的配置目录 `~/.piz`，**不与 pi 共用**。配置文件格式兼容（`settings.json` / `auth.json` / `models.json` / `AGENTS.md` 可以直接拷过来），资源包的约定目录结构也兼容。

piz 额外做了 pi 明确声明不做的事：交互式权限门、`/plan` 计划模式、结构化 todo 工具、任务委托、LSP 代码智能、本地 Web UI。

**会话文件格式不兼容**，历史无法迁移。这正是不共用目录的原因，细节见 [Sessions](docs/sessions.md#会话格式与-pi-的差异)。

## 开发

```bash
zig build test                   # 140 个测试
zig fmt src build.zig            # 格式化
```

改代码前先读 [Architecture](docs/architecture.md)，尤其是 Zig 0.16 注意事项那一节 —— 0.16 的标准库与旧版差异很大。

## 许可证

[Apache-2.0](LICENSE)。

piz 重写自 [pi](https://github.com/earendil-works/pi)（MIT，Copyright (c) 2025
Mario Zechner）。上游的 MIT 声明全文见 [NOTICE](NOTICE) —— MIT 要求它随所有副本
分发，Apache-2.0 第 4(d) 条要求衍生作品保留 NOTICE 的内容，两条一起满足。

piz 是独立实现（pi 是 TypeScript，piz 是 Zig），没有逐字拷贝的代码；CLI 界面、
配置文件格式和若干行为约定沿用 pi。
