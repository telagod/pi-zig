> 让 piz 加个工具：告诉它读 `docs/plugins.md`，然后描述你要的能力。

# 工具

piz 默认只给模型 **8 个核心工具**。其余 10 个是可选扩展，按需开启。

这是刻意的：每个工具都要占每轮请求的 tools 定义（token 成本），而且工具越多，模型选错的概率越高。默认工具集小到「少任何一个就不是编码 agent」，其他能力等你真的要用时再开。

```bash
piz --plugins                  # 看全部插件与启用状态
piz --plugin lsp               # 本次开启 lsp
```

或写进 `~/.piz/settings.json` 持久生效：

```json
{ "plugins": ["lsp", "todo"] }
```

用 `-r` / `--read-only` 完全不向模型暴露工具 —— 一个都不发，`read` 和 `grep` 也没有。

> **别用它做调研。** 只读模式下模型连文件都读不了，只能凭已有上下文和自身知识回答。
> 想让模型「看但不改」，用默认的逐次询问模式，写操作在提示时拒绝即可。

## 目录

- [核心工具](#核心工具)
- [可选工具](#可选工具)
- [文件工具](#文件工具)
- [搜索工具](#搜索工具)
- [执行工具](#执行工具)
- [扩展工具](#扩展工具)
- [输出上限](#输出上限)
- [并行执行与写锁](#并行执行与写锁)
- [参数 schema](#参数-schema)

## 核心工具

默认启用，定义在 `src/tools.zig`。

| 工具 | 作用 |
|------|------|
| `read` | 读文件，可选行区间 |
| `write` | 写文件，自动建父目录 |
| `edit` | 精确替换文件内片段 |
| `multi_edit` | 跨文件原子批量编辑 |
| `grep` | 正则搜索文件内容 |
| `find` | glob 匹配文件路径 |
| `ls` | 列目录 |
| `bash` | 执行 shell 命令 |

## 可选工具

默认关闭，由插件注册（`src/plugins.zig`）。开启方式见本页开头。

| 工具 | 插件 | 作用 |
|------|------|------|
| `skill` | `skills` | 按名加载 SKILL.md（**装了技能时自动开启**） |
| `lsp` | `lsp` | 语言服务器代码智能 |
| `todo_write` `todo_read` | `todo` | 结构化任务列表 |
| `task` | `task-delegation` | 委托子 agent 会话 |
| `web_search` | `web-search` | 网页搜索（需自建 SearXNG 端点） |
| `fetch_url` | `web-search` | 取网页正文，去标签（**不需要搜索端点**） |
| `git_status` | `git-awareness` | git status 与 diff stat |
| `read_image` | `vision-input` | 读图并附图给视觉模型（自动压缩/缩放） |
| `get_context_remaining` | `context-budget` | 剩余上下文预算 |
| `ask_user` | `elicitation` | 向用户提问 |

另有 6 个默认启用的插件只挂钩子、不加工具（上下文预剪枝、跨会话记忆、危险命令拦截等），零 token 成本，见 [Plugins](plugins.md)。

## 文件工具

### read

```json
{"path": "src/main.zig", "offset": 100, "limit": 50}
```

| 参数 | 必需 | 说明 |
|------|------|------|
| `path` | 是 | 文件路径 |
| `offset` | 否 | 起始行号，**1-based** |
| `limit` | 否 | 最多返回多少行 |

不给 `offset`/`limit` 时返回全文。`offset` 越界返回明确错误（含实际行数），而不是空内容。文件读取上限 16MB，返回内容超过 16KB 时截断保**头部**。

### write

```json
{"path": "src/new.zig", "content": "const std = @import(\"std\");\n"}
```

父目录不存在会自动创建。返回内容带 unified diff 风格的 `+` 行块（供 Web UI 的 diff 卡渲染，最多 40 行）。

### edit

```json
{"path": "src/main.zig", "edits": [{"oldText": "const x = 1;", "newText": "const x = 2;"}]}
```

每个 `oldText` **必须在文件中恰好匹配一次**。0 次或多次都报错并且不写入 —— 这是防止误改的核心约束。多条 edit 按数组顺序依次应用。

匹配失败时错误信息会说明实际匹配了几次，据此加长 `oldText` 补足上下文。

### multi_edit

```json
{"files": [
  {"path": "src/a.zig", "edits": [{"oldText": "foo", "newText": "bar"}]},
  {"path": "src/b.zig", "edits": [{"oldText": "foo", "newText": "bar"}]}
]}
```

**原子语义**：先对所有文件做全量 dry-run 校验，任一 `oldText` 匹配失败则**一个字节都不写**，错误信息指明哪个文件哪条 edit 失败。全部通过后才逐个落盘。

这是它相对多次单 `edit` 调用的核心价值：跨文件重命名之类的操作不会在中途失败时留下半改的工作树。

> 极端情况下（校验通过但落盘时磁盘满/权限变化）仍可能部分写入，此时错误信息会说明「earlier files in this batch were already written」。

## 搜索工具

搜索工具全部纯 Zig 实现，不调用外部 `rg` / `fd` / `grep`。

三个工具都跳过这些目录：`.git` `zig-out` `.zig-cache` `node_modules` `target` `dist` `__pycache__` `.venv` `venv` `.next` `vendor` `.mypy_cache` `.pytest_cache`

### grep

```json
{"pattern": "fn tool[A-Z]\\w+", "glob": "*.zig", "context": 2, "limit": 50}
```

| 参数 | 必需 | 说明 |
|------|------|------|
| `pattern` | 是 | 正则，见下方支持范围 |
| `path` | 否 | 起点，缺省 `.`；是文件则只搜该文件 |
| `glob` | 否 | 文件名过滤，如 `*.zig` |
| `ignoreCase` | 否 | 大小写不敏感 |
| `literal` | 否 | 按字面量而非正则处理 |
| `context` | 否 | 上下文行数，0-10 |
| `limit` | 否 | 最大匹配数，缺省 200，上限 2000 |

输出格式 `path:line:content`，上下文行用 `path-line-content`（仿 GNU grep）。

**正则支持范围**：

| 支持 | 语法 |
|------|------|
| 字符类 | `[abc]` `[a-z]` `[^0-9]` |
| 任意字符 | `.` |
| 量词 | `*` `+` `?`（贪婪） |
| 锚 | `^` `$` |
| 转义类 | `\d` `\w` `\s` 及大写取反 `\D` `\W` `\S` |
| 字面量转义 | `\.` `\*` `\[` 等 |

**不支持**：分组 `(...)`、选择 `|`、回溯引用、懒惰量词 `*?`。需要这些时用 `bash` 调系统 `rg`。

非法 pattern 返回可操作的错误（提示改用 `literal: true`），不会崩。单行超过 4096 字节会跳过（防压缩产物和 base64 引起病态回溯）。二进制文件自动跳过（判据：前 8KB 含 NUL 字节，与 git 同策略）。

`glob` 同时对相对路径和 basename 做匹配，所以 `*.zig` 能命中 `src/deep/a.zig`。

### find

```json
{"pattern": "**/*.test.ts", "limit": 100}
```

| 参数 | 必需 | 说明 |
|------|------|------|
| `pattern` | 是 | glob 模式 |
| `path` | 否 | 起点，缺省 `.` |
| `limit` | 否 | 最大结果数，缺省 200 |

**glob 语义**：

| 语法 | 含义 |
|------|------|
| `*` | 任意字符，**不跨** `/` |
| `**` | 任意字符，跨任意层级 |
| `?` | 单个字符，不跨 `/` |

```
*.zig          匹配 main.zig，不匹配 src/main.zig
src/*.zig      匹配 src/main.zig
**/*.zig       匹配任意层级的 .zig
src/**/*.ts    匹配 src 下任意深度的 .ts
```

### ls

```json
{"path": "src", "limit": 50}
```

目录优先、同类按名字典序。目录名带尾 `/`，文件带字节数。

## 执行工具

### bash

```json
{"command": "zig build test", "timeout": 60}
```

| 参数 | 必需 | 说明 |
|------|------|------|
| `command` | 是 | shell 命令，走 `sh -c` |
| `timeout` | 否 | 秒，缺省 30，范围 1-300 |

stdout 与 stderr 合并返回。输出超过 16KB 时截断保**尾部** —— 构建和测试的关键信息通常在末尾，与 `read` 的保头部策略相反。

**执行中可见、可中断。** 命令跑着时活动行显示耗时、墙钟上限与已收字节（见 [使用](usage.md#交互模式)）。
`Ctrl+C` 在 100ms 内停下它，`Ctrl+B` 转后台（去掉墙钟上限）。

**超时与取消都杀整个进程组。** 子进程用 `pgid=0` 起成新进程组的组长，收尾时先 `SIGTERM` 给 100ms
善后再 `SIGKILL`。只杀直接子进程是不够的：`sh -c "make -j8"` 里真正吃 CPU 的是 make 派生的编译进程，
它们会被 init 收养后继续跑到底 —— 用户以为命令停了，机器还在满载。
两种情况都保留已收到的输出，并在末尾标注是超时还是用户中断。

> **不要用 bash 改源文件。** 工具描述里就写明了这条规则：`write` / `edit` / `multi_edit` 才是改文件的正道，bash 用于检查、构建、测试。走 bash 改文件会绕过 per-file 写锁，并且 Web UI 无法渲染 diff。

危险命令会被 `command-canonicalization` 插件拦截，详见 [Plugins](plugins.md#command-canonicalization)。

## 扩展工具

以下工具默认关闭，需按本页开头的方式开启。

### skill

```json
{"name": "brave-search"}
```

从 `<配置目录>/skills/<name>/SKILL.md` 加载技能全文，上限 256KB。可用技能名在系统提示里列出。

**装了技能时自动开启** —— piz 检测到 `~/.piz/skills/` 下有技能就开这个插件；没装技能时暴露它是纯浪费（模型多一个永远无结果的工具）。

pi 的做法是让模型用 `read` 自己加载 SKILL.md；piz 把这个动作固化成专用工具，模型少一步猜路径。

### lsp

代码智能，桥接真实的语言服务器。**符号相关的工作优先用它而不是 `grep`** —— 它跟得上遮蔽、re-export 和跨文件引用，这些文本搜索会漏。

```json
{"action": "references", "file": "src/agent.zig", "symbol": "continueTurn"}
{"action": "definition", "file": "app.ts", "line": 42, "character": 8}
{"action": "rename", "file": "src/main.zig", "symbol": "onSubmit", "new_name": "handleSubmit"}
{"action": "diagnostics", "file": "demo.c"}
```

| 参数 | 必需 | 说明 |
|------|------|------|
| `action` | 是 | `definition` \| `references` \| `hover` \| `rename` \| `diagnostics` \| `implementation` \| `type_definition` |
| `file` | 是 | 文件路径，**扩展名决定用哪个语言服务器** |
| `symbol` | 否 | 符号名，取文件内首次出现处的位置 |
| `line` | 否 | 1-based 行号，与 `symbol` 二选一 |
| `character` | 否 | 1-based 列号，配合 `line` |
| `new_name` | 否 | `action=rename` 时必需 |

定位方式二选一：给 `symbol`（按名搜首次出现，门槛低）或给 `line`/`character`（精确）。`diagnostics` 不需要定位。

语言服务器按扩展名映射，需要自行安装并在 PATH 上：

| 扩展名 | 服务器 |
|--------|--------|
| `.zig` | `zls` |
| `.rs` | `rust-analyzer` |
| `.go` | `gopls` |
| `.py` | `pyright-langserver --stdio` |
| `.ts` `.tsx` `.js` `.jsx` `.mjs` | `typescript-language-server --stdio` |
| `.c` `.h` `.cc` `.cpp` `.hpp` | `clangd` |

服务器未安装时返回明确提示（含要装什么），不会崩。扩展名不在表内也一样。

输出形如：

```
/path/to/demo.c:3:5
/path/to/demo.c:8:17
/path/to/demo.c:10:12
```

行列号是 **1-based**（与编辑器一致；LSP 协议内部是 0-based，工具做了转换）。

`rename` **只报告将改动的位置，不写文件**：

```
rename 'sum_ints' would touch:
  /path/to/demo.c: 3 edits

Apply them with the edit or multi_edit tool — lsp does not write files.
```

这是故意的 —— 写文件要走 `edit` / `multi_edit`，才能过权限门和 per-file 写锁。

实现细节：每次调用起一个新的服务器进程（LSP over stdio + JSON-RPC），走 `initialize` → `didOpen` → 目标请求 → `kill` 的完整流程。不缓存进程，代价是大仓库首次索引开销，换来无状态泄漏。

> **有 15 秒超时。** 语言服务器索引大项目可能慢；超时返回错误而不是永久阻塞 agent 循环。真遇到超时可以重试（服务器可能已经预热了部分索引），或改用更窄的查询。

### todo_write / todo_read

```json
{"items": [
  {"content": "扫描仓库结构", "status": "completed"},
  {"content": "修掉失败的测试", "status": "in_progress"},
  {"content": "跑全量测试", "status": "pending"}
]}
```

`status` 取 `pending` | `in_progress` | `completed`，非法值会报错而不是静默当 pending。

`todo_write` **全量替换**列表，每步之后要带完整列表重新调用。输出形如：

```
[x] 扫描仓库结构
[>] 修掉失败的测试
[ ] 跑全量测试
(1/3 done)
```

任务列表按会话隔离（以 Agent 实例为界），Web UI 多标签并发互不干扰。列表只在内存里，不落盘，进程退出即消失。

pi 明确声明不做 to-dos，这是 piz 的增强。

### task

```json
{"description": "分析这段错误日志说明什么", "read_only": true}
{"tasks": [{"description": "任务 A"}, {"description": "任务 B", "read_only": true}]}
```

在**本进程内**建一个独立 Agent 跑委托任务，**阻塞等结果**，把子 agent 的最终答复回传给模型。`tasks` 数组并行（顶层上限 32、子 agent 里 4，超了直接报错而不是静默截断）。

`read_only` 让子 agent **一个工具都没有**（不是「只有读工具」）—— 它只能凭 `description` 里的
文字推理。调研任务别开：读不了文件的子 agent 调研不了任何东西。
它**只能收紧不能放宽**：只读父 agent 的子 agent 必然只读，否则委派就是一条提权通道。
顶层 `read_only` 作为 `tasks[]` 各项的默认值，单项可以覆盖。

返回是人读文本而非 JSON —— 子 agent 的输出是多行的，JSON 转义会把每个换行变成 `\n` 字面量，
模型得先解析再还原，白付两次代价：

```
Delegated 2 tasks: 1 succeeded, 1 failed.

=== task 1/2 (ok) [12s] ===
task: 审计 auth 模块的注入风险
（子 agent 的答复，保持原有换行）

=== task 2/2 (FAILED) [3.4s] ===
task: 检查 lexer 边界
error: non-zero exit
partial output before failing:
（失败前已回传的内容 —— 常常已经查到了有用的东西）
```

每个任务带耗时，模型能判断哪个子任务慢、下次是拆细还是干脆别委派。
部分失败不算工具失败 —— 成功的那些结果对模型仍然有用。只有全部失败才标 `is_error`。

执行期间每个子 agent 在活动行占一行，显示耗时与已回传字节。`Ctrl+C` 会连子 agent 自己
spawn 的进程一起收掉（子进程同样起成独立进程组）。

子 agent **继承**父 agent 的：

| 继承项 | 为什么 |
|---|---|
| 工作目录 | 不继承就在错误的目录动手（web 模式各会话 cwd 不同） |
| provider / model | 不继承会悄悄回退到配置里的默认模型 |
| 只读模式 | 否则只读 agent 能借委托绕出写权限 |

**不继承**对话历史。子 agent 从零开始，所以每条 `description` 必须自带全部上下文 —— 只写「继续上面那个」子 agent 看不懂。

### 进程内执行

子 agent 跑在本进程的线程里，不再 spawn 独立 piz 进程。两个收益：

**中间过程可见。** 子 agent 的每次工具调用、每条引擎告知都通过 `on_subagent` 回调实时转发给父 agent，TUI 与 `-o text` 显示成 `[sub 3] ⚙ bash`，`-o jsonl` 输出 `{"type":"subagent","task":"3","kind":"tool_start","text":"bash"}`。子进程路径下委派是纯黑盒：父 agent `join()` 干等，只能在结束时拿到一坨文本。实测 3 路委派进程内给出 9 条事件，子进程 0 条。

**委派开销降一半。** 省掉进程启动、配置重读、连接池重建。实测（零延迟 mock，只剩 piz 自身开销）：

| 并行路数 | 进程内 | 子进程 | 加速 |
|---------|-------|-------|------|
| 1 | 25 ms | 34 ms | 1.4x |
| 8 | 19 ms | 49 ms | 2.5x |
| 32 | 55 ms | 67 ms | 1.2x |

真实场景里 provider 延迟主导（一轮 TTFB 就几百毫秒），所以这个提升在墙钟上不明显 —— 32 路并行两条路径都是 1.66 秒，都完全并行。

子 agent 继承父 agent 的 provider / model / cwd / 插件启用集，`read_only` 只能加不能减，深度 +1。每个子 agent 有自己的 arena 与启用集：**并发跑的 32 个子 agent 互不影响**，这是把插件启用状态从进程级单例改成 `Agent.plugins` 位掩码换来的。

`PIZ_TASK_SPAWN=1` 切回 spawn 子进程。逃生通道：进程内共享地址空间，子 agent 里的 panic 会拖垮整个 piz，真出问题不必回滚版本。

子 agent 一律 `-x`（工具自动执行）：它没有终端可以向用户提权限询问。委托出去就等于放弃了那些任务的逐次确认，这是固有代价。墙钟上限 10 分钟，超时杀进程并报 `timed out` —— 父 agent 此刻正占着一个工具执行槽，不能无限期挂着。

**并行上限按层取**：顶层 agent 32 个，子 agent 里 4 个。并发是**乘起来**的，两个数字必须一起看：顶层 32 × 嵌套 32 × 深度 2 = 最坏 1056 个 piz 进程 ≈ 9GB，足够打死机器；压到嵌套 4 之后最坏是 32 + 32×4 = 160 个进程 ≈ 1.4GB。超限的错误里带上当前深度（`max 4 per call at delegation depth 1`），否则模型不明白同样的调用为什么在顶层能过。

实测（mock provider，13 代 i7）：每个 subagent 常驻 9MB / 3 线程，父进程侧每个约 +0.5MB、+1 线程、+2 fd。顶层跑满 32 个：整树 299MB、33 个进程、墙钟 1.60s，而单个 subagent 自己就要 1.54s —— 扇出代价几乎为零。再往上受制于 provider 的并发配额而不是本机资源。

**委托深度上限 2 层**（顶层 agent 算第 0 层）。子 agent 读的是同一份 `settings.json`，所以它也带 `task` 工具、也能继续 spawn —— 不拦就是 fork bomb。深度靠 `PIZ_TASK_DEPTH` 环境变量跨进程传递（进程间唯一可靠的通道），超限时报 `delegation depth limit reached` 让模型自己动手。

> 这条限制是读 codex 源码时发现的 —— 它有 `exceeds_thread_spawn_depth_limit`（`core/src/agent/registry.rs:76`）而 piz 当时只限并发数。

子进程失败时 stderr 的诊断原样透出（比如缺 API key），否则父 agent 只知道「失败了」而不知道为什么。输出超过 32KB 时**砍开头保尾部**，结论在最后。

实现上走的是自身可执行文件的绝对路径（`std.process.executablePathAlloc`）。早先 spawn 裸名 `"piz"` 靠 PATH 查找，而 piz 通常不在 PATH 里，实测 `error.FileNotFound` —— 那个版本一次都成功不了。

### 长驻 sub-agent

`task` 是**阻塞式批量**：派 N 路、等全部跑完、拼好返回。适合「这几件事互不相关，做完告诉我」。它的局限是委派期间父 agent 什么也做不了 —— 发现某一路方向错了只能等它烧完一整轮。

另一组工具把生命周期拆开（照 codex 的 `multi_agents` 做法）：

| 工具 | 作用 |
|------|------|
| `spawn_agent` | 起一个后台 agent，**立即返回 id**，父 agent 接着干自己的活 |
| `wait_agent` | 阻塞到**任意** agent 有结果，只报「谁有更新」，不返回内容 |
| `read_agent` | 取某个 agent 的结果，读取位置随之推进 |
| `send_agent` | 追加输入；`interrupt=true` 放弃它当前那一轮，立即处理新指令 |
| `list_agents` | 谁在跑、跑了几轮、多少未读、多少排队 |
| `close_agent` | 关掉并释放槽位 |

**长驻**的意思是跑完一轮不销毁，停在 `idle` 等下一条输入 —— 它保留自己的对话历史，所以 `send_agent` 是「接着刚才那件事」，不是重新开始。实测同一个 agent 跑两轮：第一轮报 parser，`interrupt` 转向后第二轮报 lexer，`turns` 从 1 变 2。

`spawn_agent` 的 `fork_context` 让子 agent 继承父 agent 的完整对话历史。默认关：多数委派任务不需要全部上下文，继承过去只是白烧 token。需要「接着刚才讨论的事」时才开。

**两个读者，两条通道。** `read_agent` 只返回终态（`turn_done` / `failed` / `notice`），逐条工具调用被过滤掉 —— 那对父 agent 的决策没有价值，进上下文只是烧 token。进度仍然收着，走 `on_subagent` 回调显示给**人**看（TUI 与 `-o text` 的 `[sub 1] ⚙ bash`）。codex 也是这样分的：它的细粒度事件只进 UI 与 rollout，进父 agent 模型上下文的唯一东西是子 agent 终止时的一条摘要（`session_prefix.rs`，上限 1000 token）。

**同时打开上限 32 个，跑完不等于释放** —— 完成的 agent 仍占槽位直到 `close_agent`。这是有意的：父 agent 可能还要 `send_agent` 让它继续，提前回收就丢了上下文。

> 槽位是**会话级共享**的。子 agent 继承父 agent 的插件启用集，所以它也有 `spawn_agent` —— 它派出的 agent 同样吃这 32 个槽位。深度闸门（2 层）限制的是层数，不是总数；一个中间层可以把槽位吃光，然后兄弟层拿不到。实测：一个会递归 spawn 的模型只开到 26 个就撞上限（每层多吃 6 个）。真跑满时错误信息会提示去 `close_agent`。

### web_search

```json
{"query": "zig 0.16 io interface migration"}
```

需要 `PIZ_WEB_SEARCH_URL` 指向一个返回 JSON 的搜索端点（查询作为最后一个参数拼上去，
SearXNG 就是 `http://localhost:8080/search?q=`）。没配时返回配置提示并建议改用 `bash` + `curl`。

查询会做 URL 编码 —— 带空格和中文是搜索的常态，不编码整个请求就坏了。
返回值整形成紧凑列表（最多 8 条，标题 + URL + 300 字摘要）而不是原始 JSON：
SearXNG 的响应是几十 KB 的嵌套结构，让模型自己在里面翻纯属浪费上下文。
端点不是 SearXNG（解析不出 `results`）时原样透传。

### fetch_url

```json
{"url": "https://ziglang.org/download/0.16.0/release-notes.html"}
```

取网页并抽出可读正文：丢掉 `script`/`style`/`head`/`svg` 的内容，去标签，解常见 HTML 实体，
块级标签转换行。截断到 24KB。

它和 `web_search` 是一对 —— 搜索给线索，取正文才拿到答案。没有它模型只能看到一串链接，
然后退回 `bash` + `curl` 在原始 HTML 里翻。不需要搜索端点也能单独用（喂 URL 就行）。

**只接受 `http://` 和 `https://`。** 否则 `file://` 能读本地任意文件，其他协议能把 curl 当跳板。
不执行 JavaScript，所以纯前端渲染的页面拿不到内容 —— 那种情况让模型找对应的 API 或原始文档。

### git_status

无参数。返回 `git status` 与 diff stat 摘要。

### get_context_remaining

无参数。返回上下文预算，供模型自己判断是否该收尾：

```
Context budget: window 131072 tokens, used ~1171 (of which ~1096 is the fixed
tool definitions), remaining ~129901. Auto-compaction triggers at 85%
(111411 tokens) — ~110240 tokens of headroom before that.
```

三处刻意的设计：用量**已含工具定义**（每轮全量重发的恒定开销，早先漏算导致虚报约 1000 token 余量）；工具那份单列出来，免得模型把恒定开销当成可回收空间；余量报到**压缩线**而不是窗口尽头 —— 「离窗口还有多远」对模型没有可操作性，它需要知道的是还能塞多少才会触发压缩。

### ask_user

```json
{"question": "要连同 v1 API 一起删掉，还是保留兼容层？"}
```

信息不足时向用户提问。交互模式下会打断并等待回答。

## 输出上限

所有工具输出上限 `MAX_TOOL_OUTPUT = 16KB`。超限时的截断方向按信息密度决定：

| 工具 | 保留 | 理由 |
|------|------|------|
| `read` | 头部 | 文件开头的 import 与声明信息量最高 |
| `bash` | 尾部 | 构建/测试的结论在末尾 |
| `grep` / `find` / `ls` | 头部 + 计数说明 | 达到 limit 时明确告知 |

超大工具输出会被 `artifact-store` 插件外置到文件，模型拿到路径而非全文，见 [Plugins](plugins.md#artifact-store)。

## 并行执行与写锁

同一轮里模型发出的多个工具调用**并行执行**，同时在跑的上限 8 个。执行分三阶段：

1. **串行 preflight** — 权限询问与插件前置拦截。权限提示必须串行，否则会同时弹多个提示。
2. **并行执行** — 获准的工具并发跑，信号量限流。
3. **按序写回** — 结果按模型发出的**原始顺序**写进历史。

顺序保证是硬要求：模型看到的工具结果顺序必须与它发出 `tool_calls` 的顺序一致，否则同一对话重放会得到不同上下文。

调度是**流水线**而非分批：全部工具一次性起线程，信号量把并发压在上限内，任一个完成就立刻放行下一个。从前是「8 个一批、join 完再开下一批」，一批里最慢的会拖住整批。实测 16 个工具、每 4 个夹一个慢的，流水线比分批快 45%（327ms vs 602ms）；均匀负载下两者相同。

`write` / `edit` / `multi_edit` 对**同一路径**互斥（per-file 写锁）。没有这个锁，两个 edit 会各自读到同一份旧内容、各自计算，后写的覆盖前面的，丢掉一次修改。

`multi_edit` 锁住它 `files[]` 里的每个路径，不是抢全局锁 —— 所以两个改不相干文件的 `multi_edit` 能真并行。多把锁按路径字典序获取，全局一致的顺序避免死锁；同一批里重复的路径先去重（对同一把互斥锁连锁两次会自锁死）。单次调用超过 16 个文件时退化为全局锁：宁可整体串行，也不要只锁一部分。

读类工具（`read` `grep` `find` `ls` `bash`）无锁并行。

`task` 是唯一会**嵌套**并发的工具：它自己占一个工具执行槽，同时最多再拉 32 个 piz 子进程（子 agent 里降到 4），每个子进程又能开自己的 8 个工具槽。并发是乘起来的，所以嵌套层的委托上限（4）刻意远小于顶层（32）—— 详见上面 [task](#task) 一节的进程数账。

## 参数 schema

每个工具都带完整 JSON Schema，随请求发给 provider（OpenAI 侧填 `parameters`，Anthropic 侧填 `input_schema`）。模型据此生成结构化参数，不靠猜。

新增工具时 `.schema` 字段是必填的，`src/ai.zig` 有测试校验所有 schema 是合法 JSON object 且 `type == "object"` —— 写坏了测试会红。无参数工具用 `toolsmod.EMPTY_SCHEMA`。

参数解析对模型的常见偏差有容错：`jint` 接受 integer、float 和字符串数字，`jbool` 接受 bool 和 `"true"` / `"false"` 字符串。

## read_image（图片输入）

`vision-input` 插件的工具：读图、压缩、以 image block 附到消息上，让视觉模型直接看。

```
read_image { "path": "screenshot.png" }
```

图片处理管线（`src/imgx.zig`，借鉴 oh-my-pi 的 image-resize 并改进）：

- **预算**：压缩后目标 ≤ 500KB；长边按 API 规格上限——Anthropic 1568px、OpenAI 兼容 2048px、**1M 窗口端点（≈Gemini 3 系）3072px**
- **窗口联动（现实修正）**：主流 1M/200K 窗口下，像素预算反推值恒超 API 上限——分辨率由体积预算主导；窗口只在小窗（<32K）吃紧时下调长边，给文本让 token
- **小图放大**：短边 < 200px 的退化图（如 1×1 空图表）放大重编 —— 视觉后端按 28px patch 分块，退化图会硬 400 毒化整个请求
- **内容自适应**：颜色数少（线稿/UI 截图）PNG 直出保真；照片走 JPEG；都不达标才双格式竞标取最小
- **质量二分 + 尺寸阶梯**：JPEG 质量对数收敛（比固定 4 档阶梯少一半编码），仍超预算再走 0.75→0.25 尺寸阶梯
- **降级路径**：解码失败原样回传（手工解析 PNG/JPEG/GIF 头拿尺寸），不丢图
- **坐标映射说明**：缩放后注入「原图 X×Y、发出 x×y、坐标乘 Z 映射回原图」，模型看缩放图也能算原图坐标
- **WebP 自动转码**：多数本地后端（llama.cpp/STB）不解 WebP，源图是 WebP 时强制转 PNG/JPEG
- **数量预算**：请求内图片超 provider 上限（OpenAI 20 / Anthropic 100）时丢最老图、原位换成 `[image omitted]`，不毒化请求

支持格式：PNG、JPEG、GIF、BMP、WebP（解码）；输出 PNG/JPEG。源图 ≤ 20MB。

CLI 与 web 会话同用此管线；会话落盘时图片不写入历史文件（重载后不带图）。
