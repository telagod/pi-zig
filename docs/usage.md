> 不确定某个命令做什么？在交互模式里打 `/help`。

# 使用 piz

piz 有三种运行形态：交互模式（默认）、print 模式（`-p`，一次性问答）、Web UI（`piz web`）。

## 目录

- [交互模式](#交互模式)
- [编辑器行为](#编辑器行为)
- [斜杠命令](#斜杠命令)
- [上下文文件](#上下文文件)
- [print 模式](#print-模式)
- [CLI 参考](#cli-参考)
- [键位](#键位)

## 交互模式

在项目目录里直接运行：

```bash
piz              # 当前目录，续载最近会话
piz ~/code/api   # 指定目录
piz -n           # 新会话，不续载
```

默认续载该目录最近一次会话。启动后状态栏显示当前目录、git 分支、上下文占用百分比、模型名与缓存命中。

**工具执行默认逐次询问。** 每次工具调用会弹出授权提示：

```
? bash: cargo test --lib
  [y] 允许  [n] 拒绝  [a] 本会话总是允许  [s] 跳过本次
```

用 `-x` 关掉询问（工具自动执行），用 `-r` 走只读模式（一个工具都不发，连 `read` 也没有 —— 见 [Tools](tools.md)）。

> **注意：** `-x` 意味着模型可以未经确认执行任意 shell 命令。在不熟悉的仓库或处理不可信内容时，保留默认的逐次询问。

### 执行中你会看到什么

工具跑着的时候，输入行上方每个在跑的活动占一行，50ms 刷一次：

```
⠹ bash 12s/30s  4.1KB  npm install --legacy-peer-deps
⠹ agent 3m05s/10m  2.0KB  重构解析器，把递归下降改成 Pratt
⠹ model 3.1s  retry 2  HTTP 429 rate limited · retrying in 1.8s
⏻ bash 1m05s  1.4MB  [bg]  cargo build --release
```

从左到右：转动的 spinner（还在动）、已耗时与墙钟上限、已收到的输出字节、正在做的事。
`retry N` 是请求重试次数，后面跟退避倒计时。`⏻` 加 `[bg]` 是已转后台的活动。

读这几个数字就能判断该等还是该动手：字节在涨说明命令在产出；`12s/30s` 说明还有 18 秒会被超时杀掉；
`retry 2` 说明是网络在抖而不是 piz 卡住了。

执行中按 `Ctrl+C` 取消（长命令在 100ms 内停下，整个进程组一起收掉），按 `Ctrl+B` 转后台。

引擎自己做的动作会以 `·` 开头单独打一行，与模型的输出区分开：

```
· connection dropped mid-reply (ConnectionResetByPeer) — resuming (1/2)
· the model called bash with identical arguments 3 times — telling it to use the result it already has
· hit the 24-step tool limit for one turn — work may be unfinished; send another message to continue
```

## 编辑器行为

| 输入 | 效果 |
|------|------|
| `@./path/file` | 把文件内容嵌入消息（代码块包裹，截断到 8KB） |
| `!command` | 执行 shell 命令，输出发给模型 |
| `!!command` | 执行 shell 命令，输出**不**发给模型（自己看） |
| `/name args` | 未知斜杠命令会尝试当作 prompt 模板展开 |

`@` 引用只识别 `@/`、`@./`、`@../` 三种前缀，这是为了避免误伤邮箱地址和普通 `@` 符号。裸文件名（`@foo.txt`）不会展开，写 `@./foo.txt`。

模型正在生成时输入的内容会进队列，当前轮结束后自动投递。`/queue` 清空队列。

## 斜杠命令

| 命令 | 作用 |
|------|------|
| `/help` | 列出全部命令 |
| `/status` | 刷新状态栏（目录、分支、上下文占用、模型） |
| `/model <name>` | 会话内切换模型，按模型名自动匹配 provider |
| `/new` | 开新会话 |
| `/clear` | 清空当前会话历史并重开 |
| `/sessions` | 列出本目录全部会话（带编号与消息数） |
| `/resume <n>` | 切到第 n 个会话（编号来自 `/sessions`） |
| `/title <text>` | 设置会话标题；留空则清除 |
| `/tree` | 打印当前会话的消息列表（带编号，供 `/fork` 用） |
| `/fork <n>` | 从第 n 条消息分叉出新会话 |
| `/undo` | 撤销最近一轮（删除最后一条 user 消息及其后全部） |
| `/redo` | 重发上一次输入 |
| `/compact` | 立即压缩上下文 |
| `/memory` | 查看跨会话记忆内容 |
| `/memory set <text>` | 写入一条跨会话记忆 |
| `/memory clear` | 清空跨会话记忆 |
| `/plan <goal>` | 让模型为 `<goal>` 制定分步计划，写入 `PLAN.md` 后按计划执行 |
| `/queue` | 清空待投递的输入队列 |
| `/copy` | 复制**最后一条**回复到剪贴板（wl-copy → xclip） |
| `/export` | 导出整段会话为 `piz-export.html` |
| `/dump` | 复制**整段会话**为纯文本到剪贴板（无剪贴板工具则落 `/tmp/piz-dump.txt`） |
| `/quit`、`/exit`、`/q` | 退出 |

## 上下文文件

启动时按以下顺序收集，全部拼进系统提示：

1. **全局** `~/.piz/AGENTS.md`
2. **资源包** 各已装包内的 `AGENTS.md`
3. **项目** 从 `cwd` 逐级向上直到 git 仓库根的 `AGENTS.md`

系统提示本身可以替换或追加：

| 文件 | 效果 |
|------|------|
| `.piz/SYSTEM.md`（项目）或 `~/.piz/SYSTEM.md`（全局） | **替换**默认系统提示，项目级优先 |
| `.piz/APPEND_SYSTEM.md` 或全局同名 | **追加**到默认系统提示之后 |
| `--system "text"` | 命令行替换，优先级最高 |

## print 模式

一次性问答，流式输出到 stdout，不进交互界面：

```bash
piz -p "解释 src/agent.zig 的工具循环"
echo "总结这个文件" | piz -p              # 从 stdin 读
piz -p -i prompt.txt                      # 从文件读
piz -p "跑测试并修掉失败" -x              # 自动执行工具
```

输出格式：

```bash
piz -p "..." -o text     # 默认，纯文本流
piz -p "..." -o json     # 单个 JSON 结果对象
piz -p "..." -o jsonl    # 逐事件 JSON Lines
```

`-o jsonl` 的事件类型：`text`、`reasoning`、`tool_start`、`tool_end`、`result`。

> **注意：** 这套事件模型是 piz 自己的，与 pi 的 `--mode json` 事件流**不兼容**。按 pi 的 schema 写的下游脚本在 piz 上不工作。

后台运行：

```bash
piz -p "重构整个 auth 模块" -a
# 立即返回会话 id 与日志路径，用 piz -s <id> 回来看
```

## CLI 参考

```bash
piz [目录] [选项]              # 交互模式
piz -p "提示词" [选项]          # print 模式
piz pkg <子命令>               # 资源包管理
piz web [选项]                 # Web UI
```

### 模式

| 选项 | 说明 |
|------|------|
| 无 | 交互模式 |
| `-p`, `--print` | print 模式，流式输出到 stdout 后退出 |
| `-a`, `--async` | print 模式后台运行，立即返回会话 id 与日志路径 |
| `-o`, `--output <fmt>` | print 模式输出格式：`text`（默认）\| `json` \| `jsonl` |

### 模型

| 选项 | 说明 |
|------|------|
| `-m`, `--model <M>` | 指定模型 |
| `--provider <P>` | 指定 provider |
| `--models` | 列出全部可用模型后退出 |

### 会话

| 选项 | 说明 |
|------|------|
| `-c`, `--continue` | 续载最近会话（默认行为） |
| `-n`, `--new` | 新会话，不续载 |
| `-t`, `--title <T>` | 新会话并设置标题（隐含 `-n`） |
| `-s`, `--session <ID>` | 恢复指定会话，id 见 `/sessions` 或 `-a` 输出 |

### 工具与插件

| 选项 | 说明 |
|------|------|
| `-r`, `--read-only` | 只读模式，一个工具都不暴露（含 `read`） |
| `-x`, `--execute` | 工具自动执行，不逐次询问 |
| `--plugin <N>` | 开启一个可选插件（可重复） |
| `--plugins` | 列出全部插件与当前启用状态后退出 |
| `-i`, `--input <FILE>` | 从文件读提示词（print 模式） |
| `--system <TEXT>` | 替换默认系统提示 |

piz 默认只暴露 8 个核心工具，其余能力按需开启：

```bash
piz --plugins                     # 看有哪些
piz --plugin lsp --plugin todo    # 本次开启
```

持久生效写进 `~/.piz/settings.json` 的 `plugins` 数组。详见 [Tools](tools.md) 与 [Plugins](plugins.md)。

### 其他

| 选项 | 说明 |
|------|------|
| `-v`, `--version` | 版本 |
| `--` | 之后的参数不再当选项（提示词以 `-` 开头时用） |
| `-h`, `--help` | 帮助 |

### `--` 分隔符

提示词以 `-` 开头时，加 `--` 避免被当成选项解析：

```bash
piz -p -- "-rf 是什么意思"    # 提示词以 - 开头，不加 -- 会报 unknown option
```

### 子命令

```bash
piz pkg install <path> [-l]    # 安装资源包，-l 装到项目 .piz/packages
piz pkg list                   # 列出已装包
piz pkg remove <name> [-l]     # 移除包

piz web [--port N] [--no-open] [--token T | --no-token]
```

详见 [Packages](packages.md) 与 [Web UI](web-ui.md)。

> **与 pi 用户注意：** 几个单字母参数语义与 pi **相反**。pi 的 `-r` 是浏览会话、`-n` 是设会话名、`-t` 是工具白名单；piz 分别是只读模式、新会话、会话标题。

## 键位

键位当前是硬编码的，暂不支持自定义配置。

| 键 | 作用 |
|----|------|
| `Enter` | 提交 |
| `Ctrl+C` | 执行中：中断本轮并取消在跑的活动；空闲时：清空输入 |
| `Ctrl+B` | 执行中：把在跑的活动转后台（去掉墙钟上限，Ctrl+C 不再取消它们） |
| `Ctrl+D` | 输入为空时退出 |
| `Ctrl+A` | 光标到行首 |
| `Ctrl+E` | 光标到行尾 |
| `Ctrl+K` | 删到行尾 |
| `Ctrl+U` | 删除整行 |
| `Ctrl+W` | 删除前一个单词 |
| `Ctrl+L` | 清屏重绘 |
| `↑` / `↓` | 翻输入历史 |
| `←` / `→` | 移动光标 |
| `y` / `n` / `a` / `s` | 权限提示中：允许 / 拒绝 / 总是 / 跳过 |

输入是单行的，暂不支持 `Shift+Enter` 插入换行。多行内容用 `@./file` 引用文件，或走 Web UI。
