<p align="center">
  <img src="src/logo.svg" width="56" alt="piz">
</p>
<h1 align="center">piz</h1>
<p align="center">
  极简终端编码 agent。<a href="https://pi.dev">pi</a> 的 Zig 0.16 重写。<br>
  <sub>单个静态二进制 · Linux · Apache-2.0</sub>
</p>

<p align="center">
  <img src="docs/images/tui.png" width="720" alt="piz 交互模式：会话卡、对话、boxed composer">
</p>
<p align="center"><sub>交互模式。开场是会话卡，对话用 <code>›</code> / <code>•</code>，输入在底栏框。页脚左侧提示、右侧上下文占用。空框按 <code>?</code> 看快捷键。</sub></p>

<p align="center">
  <img src="docs/images/web.png" width="720" alt="piz Web UI：项目侧栏、对话、工具卡、斜杠命令">
</p>
<p align="center"><sub><code>piz web</code> 活页面。侧栏按项目列会话，对话里有工具卡，<code>/</code> 出命令；手动审批、缓存命中和上下文环在输入栏。</sub></p>

核心只做一条链路：组消息 → 调模型 → 跑工具 → 压缩。其余是编译期插件表，随二进制发布。不用的工具不进请求——少付 schema，也不打乱 prompt 前缀缓存。

| | |
|---|---|
| 工具 | 默认 8 个：`read` `write` `edit` `multi_edit` `grep` `find` `ls` `bash`。其余 `--plugin` 才开，都带 JSON Schema |
| 子 agent | 8 线程 worker 池，闲着不占线程。顶层排队 32、嵌套 4。孩子默认不带 `task` / `spawn_agent` |
| 缓存 | tools 写在 messages 前面，`prompt_cache_key` 用工作目录。快压优先动廉价尾 |
| 依赖 | Zig 标准库 + vendored [stb](https://github.com/nothings/stb)（读图）。正则和 glob 是自己的 |

macOS 未验证。Windows 不做。

## 安装

需要 [Zig 0.16](https://ziglang.org/download/)。

```bash
git clone <repo> && cd pi-zig
zig build                 # 默认 ReleaseFast
./zig-out/bin/piz --help
```

调试：`zig build -Doptimize=Debug`。

## 快速开始

密钥写 `~/.piz/auth.json`，或 `DEEPSEEK_API_KEY` / `ANTHROPIC_API_KEY` / `<PROVIDER>_API_KEY`：

```json
{ "deepseek": { "type": "api_key", "key": "sk-..." } }
```

```bash
cd ~/your-project
piz                       # 交互，续载该目录最近一次会话
piz -n                    # 新会话
piz -p "解释构建流程"     # 一次性问答
echo "总结这个文件" | piz -p
piz web                   # 本地界面
```

`-x` 自动执行（模型能跑任意 shell）。`-r` 只读：一个工具都不发，连 `read` 也没有，别拿它做调研。

```bash
piz --plugins             # 看启用状态
piz --plugin lsp          # 本次开启
```

持久写 `~/.piz/settings.json` 的 `plugins` 数组。

## 文档

从 [docs/index.md](docs/index.md) 开始。

| | |
|---|---|
| [Usage](docs/usage.md) | 交互、斜杠命令、CLI、键位 |
| [Tools](docs/tools.md) | 核心工具与可选扩展 |
| [Configuration](docs/configuration.md) | 配置、provider、认证 |
| [Web UI](docs/web-ui.md) | `piz web`、鉴权、HTTP |
| [Plugins](docs/plugins.md) | 内置插件、钩子 |
| [Packages](docs/packages.md) | 资源包、skills |
| [Sessions](docs/sessions.md) | 会话、分支、格式 |
| [Architecture](docs/architecture.md) | 模块、主链路、并发、Zig 0.16 |

改 piz 本身先读 Architecture。对照外部 harness 哲学看 [dsh-mapping](docs/dsh-mapping.md)。

## 与 pi 的关系

配置目录是 `~/.piz`，不与 pi 共用。`settings.json` / `auth.json` / `models.json` / `AGENTS.md` 格式兼容，可以从 `~/.pi/agent` 拷过来。

会话文件格式不兼容，历史迁不过来。见 [Sessions](docs/sessions.md#会话格式与-pi-的差异)。

piz 做了 pi 明确声明不做的事：权限门、`/plan`、todo、任务委托、LSP、本地 Web UI。没有 OAuth 蹭订阅，只认 API key。

## 开发

```bash
zig build test
zig fmt src build.zig
```

改并发或委派前读 Architecture 里的约束。不要让子 agent 默认带回 `task-delegation`。

## 许可证

[Apache-2.0](LICENSE)。Copyright 2026 telagod。

重写自 [pi](https://github.com/earendil-works/pi)（MIT，Copyright (c) 2025 Mario Zechner）。上游声明在 [NOTICE](NOTICE)。独立实现，没有逐字拷贝的代码。
