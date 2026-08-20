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
- [限额](#限额)

## 交互模式

在项目目录里直接运行：

```bash
piz              # 当前目录，续载最近会话
piz ~/code/api   # 指定目录
piz -n           # 新会话，不续载
```

默认续载该目录最近一次会话，并把历史画进对话区。输入和状态钉在屏幕底，对话在上面软换行。对话区可以**拖选复制**（原生终端选区；没有开鼠标按键跟踪）。`PageUp` / `PageDown`、滚轮、`Ctrl+↑/↓` 翻历史。不用表情符号。`/copy` `/dump` 仍是剪贴板后备。

开场不画会话卡。身份钉在输入框底下：模型加粗，`think` / `ctx` / `cache` 标签更淡、数字正常色，目录·会话 id 和 `? for shortcuts` 最淡。宽终端（大约 ≥100 列）全部挤在一行；80 列会拆成两行（上行指标，下行目录·会话和 hint），不右对齐留空白。完整栏（授权、上下文文件、用量）仍在 `/status`，按需才画进对话。输入是底栏框，不是壳上的 `>`。空框按 `?` 看快捷键；`r` 重发上一轮。输入 `@./` 弹出工作区文件补全（Tab / Enter 填入，↑↓ 选择；默认不列 gitignored / 跳过目录）。

对话是分块分层，靠左栏、缩进和字重区分，不是同一列淡灰。用户每行一条亮竖线 `▎`（加粗正文，没有 `┌/└` 空行）；思考退后两格、淡斜体（`Ctrl+T` 收成 `· thought` 一行）；助手正文同样缩进两格、正常色、没有竖线；工具再缩两格，一行写完 `▸` 名（加粗）+ 预览（淡）+ 状态，默认折叠，`Ctrl+O` 才在下面展开正文。块与块之间空一行；同轮兄弟工具中间不加空行。忙碌时输入框上方一行 `Working`，比对话更淡。

```
▎ your message

  dim italic thinking

  assistant text

    ▸ bash  zig test src/foo.zig  ok 1.2s 12ln
⠹ Working (12s • esc to interrupt)
 └ bash  zig test src/foo.zig
╭──────────────────────────────────────────╮
│ › _                                      │
╰──────────────────────────────────────────╯
deepseek/v4-flash think max ctx 1.2k/128k 9% cache 62%
~/project/pi-zig · 1786741809022 ? for shortcuts
```

宽约 120 列时同一栏收成一行：

```
deepseek/v4-flash think max ctx 1.2k/128k 9% cache 62% ~/project/pi-zig · 1786741809022 ? for shortcuts
```

页脚随 `/model`、`Alt+,/.`（或 `/think`）以及每轮结束的 usage 回调刷新。占用是 `est_ctx / 窗口`（`12k/128k 9%`），不是单独一个 `0%`。缓存是上一轮 API 回报的命中：有 `cached_tokens` / `prompt_cache_hit_tokens` / `cache_read_input_tokens` 时写 `cache 62%` 或 `cached 8.1k`；没回报就 `cache —`，不编数字。一行装不下时把路径和 hint 挪到第二行，避免把 cwd 挤掉。再窄才按 hint → think → cache 标签 → ctx 绝对数 → session 的顺序收；cwd 几乎不丢（极窄时截成 `…`）。模型不丢。思考档是当前选的（默认 `high`）。

上下文窗口按 pi 的声明解析：DeepSeek 只有 `deepseek-v4-flash` / `deepseek-v4-pro`（窗 1000000）；未写窗口的自定义模型缺省 128000。不是 131k。

**默认全权（yolo）。** 对齐 Codex Full Access：命令和写文件不弹窗。`/status` 写 `yolo`。要先问再用 `/permissions ask` 或 `--ask`；只读用 `/permissions read-only` 或 `-r`。

询问档下会改文件、跑 shell、出网或委派子 agent 时才弹出授权：

```
? bash  zig test src/parser.zig
```

页脚同时写 `y allow  n deny  a always  s skip`。

`read` / `grep` / `find` / `ls` 只读工具三档都直接跑。`-x` / `--yolo` 显式全权（已是默认）。

> **注意：** yolo 意味着模型可以未经确认执行任意 shell 命令。不熟悉的仓库或不可信内容请切 `/permissions ask`，并开 `/sandbox workspace`（bwrap 或 Landlock）。

### 执行中你会看到什么

工具跑着的时候，输入框上方一行 Working，底下最多两行当前活动：

```
⠹ Working (12s • esc to interrupt)
 └ bash  npm install --legacy-peer-deps
 └ agent  重构解析器，把递归下降改成 Pratt
```

对话区里每个工具是助手下面的一行（`    ▸ bash  zig test  ok 1.2s 12ln`），默认不贴 stdout。`Ctrl+O` 在下面用 `│` / `└` 展开正文。`workflow` 例外：标题下直接铺节点轨（`○` 等待、`●` 在跑/完成），子 agent 进度写进对应节点，不另起 `[sub N]` 行。Working 只回答「还在动、多久了、Esc 能停」。并行超过两路的活动仍在跑，只是不把输入框顶出屏幕。

执行中按 `Esc` 取消（长命令在 100ms 内停下，整个进程组一起收掉），按 `Ctrl+B` 转后台。空闲时 `Ctrl+C` 清空输入；输入为空再按一次（1 秒内）退出。退出后终端印 `resume: piz -s <id>`，下次用这条回来。

引擎自己做的动作以 `piz` 开头单独打一行，与模型的输出区分开：

```
  piz  connection dropped mid-reply (ConnectionResetByPeer) — resuming (1/2)
  piz  the model called bash with identical arguments 3 times — telling it to use the result it already has
```

单轮工具循环**没有步数上限**，和 pi 一样。模型要调多少次就调多少次。真停下来的只有：模型自己收工、你按 Esc、或者它在原地空转（同一调用 / 同一输出连发，会先劝再停）。并行同时在跑的工具上限 8，那是并发不是步数。

## 编辑器行为

| 输入 | 效果 |
|------|------|
| `@./path/file` | 把文件内容嵌入消息（代码块包裹，截断到 8KB） |
| `!command` | 执行 shell 命令，输出发给模型 |
| `!!command` | 执行 shell 命令，输出**不**发给模型（自己看） |
| `/name args` | 未知斜杠命令会尝试当作 prompt 模板展开 |
| `/` | 输入框一出现 `/` 就在上方弹出命令选择器（见下） |
| `/permissions` `/sandbox` `/model` `/think` | 无参数弹出选择器：↑↓ 或 j/k，Enter 确认，Esc 取消 |

`@` 引用只识别 `@/`、`@./`、`@../` 三种前缀，这是为了避免误伤邮箱地址和普通 `@` 符号。裸文件名（`@foo.txt`）不会展开，写 `@./foo.txt`。

模型正在生成时输入的内容会进队列，当前轮结束后自动投递。`/queue` 清空队列。

## 斜杠命令

输入框里打 `/` 立刻在输入框上方弹出选择器，每行挤在一起：`/status session model cwd tokens`（命令加粗，说明更淡）。排序：前缀匹配先于模糊子序列，再才是说明里的关键字。`st` 会把 `/status` 排到无关命令前面；`mod` 命中 `/model`；光一个 `/` 列出全部。↑↓ 移动，Tab 补全名字，Enter 执行当前选中项。没匹配上的 `/foo` 照旧当未知命令提交（prompt 模板）。

| 命令 | 作用 |
|------|------|
| `/help` | 列出全部命令 |
| `/status` | 把会话卡画进对话（模型、目录、授权、上下文、已开的可选插件） |
| `/doctor` | 体检：配置文件、沙箱后端、联网搜索、git、AGENTS.md（CLI 亦可 `piz doctor`） |
| `/init` | 工作区没有 AGENTS.md 时写脚手架，已有则不覆盖（`piz init` 同） |
| `/diff` | git status + staged/unstaged diffstat（不需开启 git-awareness；`piz diff` 同）。空输入按 `g` 同样 |
| `/commit [msg]` | 只提交已暂存；无说明则预览；不自动 `git add`（`piz commit` 同） |
| `/log [n]` | `git log --oneline`，默认 20 条、最多 50（`piz log` 同）。空输入按 `l` 同样 |
| `/branch` | 当前分支与最近本地分支，不切换（`piz branch` 同） |
| `/mcp` | 列出已配置 MCP server 与工具（`piz mcp` 同） |
| `/reload` | 重读 settings.json（主题/授权/沙箱/思考档；Web 当场套用外观；插件与 MCP 需重启；`piz reload` 同） |
| `/usage` | 跨会话 token 账本（`~/.piz/usage.jsonl`，最近 8 轮，含估算 `$`；`piz usage` 同）。空框按 `u` 同样 |
| `/jobs` | 当前在跑与后台任务（bash `background`、HTTP、子 agent）。空框按 `j` 同样 |
| `/jobs kill <pid>` | 只杀 activity 表里的进程。`/kill <pid>` 同义 |
| `/find <text>` | 在对话块里搜，再敲一次跳下一条；命中反色。空输入时 `n`/`N` 下一条/上一条。裁掉的旧块仍可搜到（提示 `match in pruned history`）。Web 上 F3 / Shift+F3 同样跳，没命中会先拉更早历史 |
| `/paste` | 从剪贴板附图（Ctrl+V 同样）。有 vision 才进消息，否则提示并丢图。图落 `~/.piz/artifacts/img-*`，续会话回放 |
| `/think` | 弹出思考等级选择器（↑↓ Enter Esc）。只列出**这个模型**能选的档 |
| `/think off\|minimal\|low\|medium\|high\|xhigh\|max` | 直接设定。该模型没有的档会夹到最近的可用档。`浅`/`中`/`深` 仍认，分别是 low / medium / max |
| `/theme` | TUI 弹出主题选择器；Web 显示当前配色 |
| `/theme dark\|light\|auto\|name` | TUI：`auto` 看 `COLORFGBG`，自定义名读 `~/.piz/themes/{name}.json`，写回 `settings.json`。Web：`light` / `dark` / `system`（`auto` 当 `system`），记 localStorage |
| `/permissions` | 弹出授权选择器。对齐 Codex `/permissions` |
| `/permissions yolo\|ask\|read-only` | 直接设定全权 / 询问 / 只读。写回 `settings.json` 的 `approvalMode`。`/approvals` 是别名 |
| `/sandbox` | 弹出 bash OS 沙箱选择器。空输入时按 `s` 同样 |
| `/sandbox off\|workspace\|strict` | `workspace`：工作区可写、其余只读；`strict` 再断网。优先 bwrap，否则 Landlock。两路都没有才报错。写回 `sandboxMode`。底栏 / 药丸显示 `workspace/bwrap` 或 `workspace/landlock` |
| `/model` | 弹出模型选择器（有密钥的 provider × 模型） |
| `/model <name>` | 会话内切换模型，`provider/model` 或按模型名匹配 provider |
| `/refresh` | 对各 provider 打 `GET /models`，新 id 并入内存表（不落盘）。Web 同令 |
| `/new` | 开新会话 |
| `/clear` | 清空当前会话历史并重开 |
| `/sessions` | 列出本目录全部会话（带编号与消息数；`piz sessions` 同） |
| `/resume <n>` | 切到第 n 个会话（编号来自 `/sessions`） |
| `/title <text>` | 设置会话标题；留空则清除。不设则用首条消息第一行 |
| `/tree` | 打印当前会话的消息列表（带编号，供 `/fork` 用） |
| `/fork <n>` | 从第 n 条消息分叉出新会话 |
| `/undo` | 撤销最近一轮（删除最后一条 user 消息及其后全部） |
| `/redo` | 重发上一次输入。Web 上也可 `Ctrl+Shift+R`；`Ctrl+Shift+C` 复制最后回复 |
| `/compact` | 立即压缩上下文（密图 + 摘录，不调模型） |
| `/fast-compress` | 看快压状态：窗况、vision、raw 大块清单 |
| `/pkg` | 列出已装资源包（用户 + 项目） |
| `/plugins` | 列出本会话插件（`piz plugins` 同） |
| `/plugins on <name>` | 开启插件（下一轮生效，写入 settings） |
| `/plugins off <name>` | 关闭插件 |
| `/memory` | 查看跨会话记忆内容（`piz memory` 同） |
| `/memory set <text>` | 写入一条跨会话记忆 |
| `/memory clear` | 清空跨会话记忆 |
| `/plan <goal>` | 让模型为 `<goal>` 制定分步计划，写入 `PLAN.md` 后按计划执行 |
| `/queue` | 清空待投递的输入队列 |
| `/copy` | 复制**最后一条**回复到剪贴板（wl-copy → xclip）。空输入时按 `c` 同样 |
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
piz -p "跑测试并修掉失败"                 # print 本身不询问；交互默认也是 yolo
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
| `-c`, `--continue` | 续载最近会话 |
| `-n`, `--new` | 新会话（默认行为，每次启动都是新会话） |
| `-t`, `--title <T>` | 新会话并设置标题（隐含 `-n`） |
| `-s`, `--session <ID>` | 恢复指定会话，id 见退出提示、`/sessions` 或 `-a` 输出 |

### 工具与插件

| 选项 | 说明 |
|------|------|
| `-r`, `--read-only` | 启动时不暴露工具（含 `read`）。会话内只读用 `/permissions read-only` |
| `-x`, `--execute`, `--yolo` | 全权（默认已是） |
| `--ask` | 危险工具先问 |
| `--sandbox off\|workspace\|strict` | 覆盖 `sandboxMode`（本进程，不写回配置除非再 `/sandbox`） |
| `--plugin <N>` | 开启一个插件（可重复） |
| `--no-plugin <N>` | 关闭一个插件（可重复，撤钩 / 工具 / schema） |
| `--plugins` | 列出全部插件与当前启用状态后退出 |
| `-i`, `--input <FILE>` | 从文件读提示词（print 模式） |
| `--system <TEXT>` | 替换默认系统提示 |

piz 默认只暴露 8 个核心工具，其余能力按需开启：

```bash
piz --plugins                     # 看有哪些
piz --plugin lsp --plugin todo    # 本次开启
piz --no-plugin tool-output-pruner  # 本次关掉出厂插件
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

键位对齐 [Codex TUI](https://developers.openai.com/codex/cli/slash-commands) 的默认表：Esc 中止、Ctrl+C/D 空行再按一次才退出、空框 `?` 出快捷键。piz 多出来的是 `Ctrl+B` 转后台、`Ctrl+T` 折叠思考、`Ctrl+O` 折叠工具输出、`PageUp`/`PageDown` / 滚轮 / `Ctrl+↑↓` 滚对话。对话区拖选即可复制（原生选区）。思考等级（`Alt+,/.`）与 Codex 相同。

| 键 | 作用 |
|----|------|
| `Enter` | 提交；模型忙碌时也投进队列 |
| `Tab` | `/` 选择器打开时补全命令名；模型忙碌时把当前输入入队 |
| `Esc` | 执行中：中止本轮；空闲空行再按一次：把上一条载回输入框 |
| `Ctrl+C` | 有字：清空输入；空行：提示「再按一次退出」，1 秒内再按才退出 |
| `Ctrl+D` | 空行：与 Ctrl+C 相同的两步退出 |
| `/quit` `/exit` `/q` | 立刻退出；离开备用屏后印 `resume: piz -s <id>` |
| `Ctrl+B` | 执行中：把在跑的活动转后台；空闲：光标左移 |
| `Ctrl+F` | 光标右移 |
| `Ctrl+P` / `Ctrl+N` | `/` 选择器打开时移动选项，否则上 / 下一条输入历史 |
| `Ctrl+A` | 光标到行首 |
| `Ctrl+E` | 光标到行尾 |
| `Ctrl+K` | 删到行尾 |
| `Ctrl+U` | 删除整行 |
| `Ctrl+W` | 删除前一个单词 |
| `Ctrl+L` | 清屏重绘 |
| `Ctrl+T` | 折叠 / 展开本轮思考（不改等级；不是 Codex 的 transcript overlay） |
| `Ctrl+O` | 折叠 / 展开工具输出（默认折叠成摘要；对齐 Claude Code 的 expand） |
| `Ctrl+V` | 贴剪贴板图（没有图则贴文本） |
| `PageUp` / `PageDown` | 向上 / 向下滚对话（半页） |
| 拖选 | 原生选中对话区文字并复制（终端 Shift 不是必须的） |
| 鼠标滚轮 | 向上 / 向下滚对话（alternate-scroll；也可用 PageUp / Ctrl+↑↓） |
| `Ctrl+↑` / `Ctrl+↓` | 向上 / 向下滚对话（3 行） |
| `Home` / `End` | 光标到行首 / 行尾 |
| `Alt+,` / `Alt+.` | 思考更浅 / 更深（只走当前模型支持的档，例如 Flash 是 off→low→high→max，Pro 是 off→high→max） |
| `Shift+↓` / `Shift+↑` | 同上 |
| `?` | 空输入框：打开 / 关闭快捷键叠层 |
| `↑` / `↓` | `/` 选择器打开时移动选项，否则翻输入历史 |
| `Alt+Enter` | 插入换行(多行草稿) |
| `←` / `→` | 移动光标 |
| `y` / `n` / `Esc` / `a` / `s` | 权限提示：允许 / 拒绝 / 拒绝 / 总是 / 跳过 |

多行输入:`Alt+Enter` 插换行;粘贴走 bracketed paste(终端对粘贴块自动加
`ESC[200~…ESC[201~`,piz 默认开启),多行原文整体进草稿,不再碰回车误提交。
`Shift+Enter` 需 kitty 键盘协议,暂不支持。跨行光标移动暂无(←/→ 按字节走)。

## 主题

对齐 pi 的 theme JSON（`vars` + `colors`，hex 或变量名）。内置 `dark` / `light`。

- `settings.json` 的 `theme`：`dark` / `light` / `auto` / 自定义名
- 环境变量 `$PIZ_THEME` 覆盖 settings
- `auto`：看 `$COLORFGBG` 背景色号（7 或 15 → light）
- 自定义：把 pi 兼容 JSON 放到 `~/.piz/themes/{name}.json`，然后 `/theme name`
- 例：仓库 `themes/dark.json`、`themes/light.json`

user 消息与 assistant 回复按 Markdown 着色（标题 / 围栏与缩进代码 / 列表 / 引用 / `code` **bold** *italic* ~~strike~~ / 链接 / `\` 转义）。围栏内注释与字符串浅着色。`NO_COLOR` 时退回素文。

## 限额

这些是硬上限，不是建议。碰到会停或截断，并尽量说出来。

| 限额 | 默认 | 改法 |
|------|------|------|
| 同一条 assistant 消息里并行工具 | 8 | 代码常量 `MAX_PARALLEL_TOOLS` |
| 单条工具输出进模型的字节 | 16 KiB | 代码常量 `MAX_TOOL_OUTPUT`（超了留尾、带截断标记） |
| 流中途断线自动续跑 | 2 次 | 代码常量 `MAX_STREAM_RESUMES` |
| 相同工具调用空转干预 | 连发 3 次相同参数 | 第三次起提示模型用已有结果 |
| 上下文占用 | 窗口的 85% 触发 compact | 见 [Architecture](architecture.md) |

`-r` 启动时不暴露任何工具（含 `read`）。会话里 `/permissions read-only` 只拒危险工具，读类仍跑。
