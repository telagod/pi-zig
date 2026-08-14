# piz

<p align="center"><img src="src/logo.svg" width="72" alt="piz"></p>

极简终端编码 agent。[pi](https://pi.dev) 的 Zig 0.16 重写。

核心只做一条链路：组消息 → 调模型 → 跑工具 → 压缩。其余能力是编译期插件表，随二进制发布；不用的工具不进请求，以免白付 schema、也免得打乱 prompt 前缀缓存。

- **单个静态二进制**，无 Node、无 `node_modules`
- **默认 8 个核心工具**：`read` `write` `edit` `multi_edit` `grep` `find` `ls` `bash`。其余 `--plugin` 才开，全部带完整 JSON Schema
- **子 agent 进 8 线程 worker 池**，闲着不占线程；顶层排队 32、嵌套 4。孩子默认不带 `task` / `spawn_agent`，可用 `plugins` / `tools` 再收紧
- **护 prompt cache**：tools 写在 messages 前面，`prompt_cache_key` 用工作目录；快压优先动廉价尾，不无故改热前缀
- **内置 Web UI**：`piz web`
- 依赖是 Zig 标准库 + vendored [stb](https://github.com/nothings/stb)（读图）。正则和 glob 是自己的

当前只支持 Linux。macOS 未验证，Windows 不做。

## 安装

需要 [Zig 0.16](https://ziglang.org/download/)。

```bash
git clone <repo> && cd pi-zig
zig build
./zig-out/bin/piz --help
```

`zig build` 默认 ReleaseFast。调试用 `zig build -Doptimize=Debug`。

## 快速开始

密钥写 `~/.piz/auth.json`，或环境变量 `DEEPSEEK_API_KEY` / `ANTHROPIC_API_KEY` / `<PROVIDER>_API_KEY`：

```json
{ "deepseek": { "type": "api_key", "key": "sk-..." } }
```

```bash
cd ~/your-project
piz                    # 交互；续载该目录最近一次会话
piz -n                 # 新会话
piz -p "解释构建流程"  # 一次性问答
echo "总结这个文件" | piz -p
piz web                # 本地界面，URL 带一次性 token
```

工具默认逐次询问。`-x` 自动执行（模型能跑任意 shell）。`-r` 只读：一个工具都不发，连 `read` 也没有，别拿它做调研。

`piz --plugins` 看启用状态。本次开启：`piz --plugin lsp`。持久写 `~/.piz/settings.json` 的 `plugins` 数组。

## 文档

从 [docs/index.md](docs/index.md) 开始。

| 文档 | 内容 |
|------|------|
| [Usage](docs/usage.md) | 交互、斜杠命令、CLI、键位 |
| [Tools](docs/tools.md) | 核心工具与可选扩展 |
| [Configuration](docs/configuration.md) | 配置、provider、认证、环境变量 |
| [Web UI](docs/web-ui.md) | `piz web`、鉴权、HTTP |
| [Plugins](docs/plugins.md) | 内置插件、钩子、怎么加一条 |
| [Packages](docs/packages.md) | 资源包、skills、事件扩展 |
| [Web plugins](docs/web-plugins.md) | 前端插件 SDK |
| [Sessions](docs/sessions.md) | 会话、分支、压缩、格式 |
| [Architecture](docs/architecture.md) | 模块、主链路、并发、Zig 0.16 |

改 piz 本身：先读 Architecture，尤其是 Zig 0.16 那一节。对照外部 harness 哲学时看 [dsh-mapping](docs/dsh-mapping.md)。

## 与 pi 的关系

配置目录是 `~/.piz`，**不与 pi 共用**。`settings.json` / `auth.json` / `models.json` / `AGENTS.md` 格式兼容，可以从 `~/.pi/agent` 拷过来。资源包的 `skills/` `prompts/` 约定也兼容。

会话文件格式不兼容，历史迁不过来。这就是分目录的原因，见 [Sessions](docs/sessions.md#会话格式与-pi-的差异)。

piz 做了 pi 明确声明不做的事：交互式权限门、`/plan`、结构化 todo、任务委托、LSP、本地 Web UI。没有 OAuth 蹭订阅，只认 API key。

## 开发

```bash
zig build test
zig fmt src build.zig
```

测试分 core 与 app 两套目标，一条命令都跑。改并发或委派前读 Architecture 里的约束，不要让子 agent 默认带回 `task-delegation`。

## 许可证

[Apache-2.0](LICENSE)。Copyright 2026 telagod。

重写自 [pi](https://github.com/earendil-works/pi)（MIT，Copyright (c) 2025 Mario Zechner）。上游声明全文在 [NOTICE](NOTICE)，随所有副本分发。

独立实现，没有逐字拷贝的代码。CLI、配置格式和若干行为约定沿用 pi。
