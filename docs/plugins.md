> 想加插件？让 piz 读这篇，然后描述你要挂的钩子。它会照着 `src/plugins.zig` 的现有条目写。对齐外部 harness 哲学时先读 [dsh 对照札](dsh-mapping.md)。

# 内置插件

piz 的插件是**编译期注册的 Zig 函数表**，不是运行时加载的模块。它们随二进制发布，零配置生效，无加载开销。

这是有意的取舍:核心(`src/agent.zig`)只做主链路,凡是「有用但不该进核心」的能力都做成插件挂钩子。想改插件行为要改代码重编译 —— 换来的是没有插件加载器、没有沙箱、没有 ABI 兼容性负担。

适合免编译的场景化插件正逐步抽成真 JS 扩展(内嵌层随二进制出厂,同名可覆写),路线图见 [插件抽离](plugin-extraction.md)。

面向终端用户的运行时扩展点是 [Packages](packages.md) 的事件声明和 `tools[]`，那条路不需要重编译。

## 目录

- [插件清单](#插件清单)
- [钩子契约](#钩子契约)
- [各插件行为](#各插件行为)
- [新增一个插件](#新增一个插件)
- [并发注意事项](#并发注意事项)

## 插件清单

分两类。**默认启用**的只挂钩子、不加工具 —— 零 token 成本，不开反而会退化（上下文爆掉、危险命令直通）。**默认关闭**的每个都会往每轮请求的 tools 数组里加条目，不用时是纯浪费。

### 默认启用

| 插件 | 挂载点 | 作用 |
|------|--------|------|
| `cross-session-memory` | `on_compact` | 压缩摘要落盘，跨会话注入 |
| `concept-graph` | `on_compact` | 从摘要提取概念 |
| `compact-resilience` | `on_compact_failed` | 压缩失败时换备用模型重试 |
| `command-canonicalization` | `on_tool_before` | 拦截危险 shell 命令 |
| `artifact-store` | `on_tool_result` | 超大输出外置到文件 |
| `usage-ledger` | `after_turn` | 每轮 token 追加到 `~/.piz/usage.jsonl`(**已抽为内嵌 JS 扩展**,见 [抽离路线](plugin-extraction.md)) |

### 默认关闭

| 插件 | 注册的工具 |
|------|-----------|
| `skills` | `skill`（**装了技能时自动开启**） |
| `vision-input` | `read_image`（默认关，`read` 对图片已做同样的事） |
| `lsp` | `lsp` |
| `todo` | `todo_write` `todo_read` |
| `task-delegation` | `task` `workflow` `spawn_agent` `wait_agent` `read_agent` `send_agent` `list_agents` `close_agent`；斜杠 `/agents` |
| `web-search` | `web_search` `fetch_url`（`fetch_url` 拒内网 / metadata / localhost）；斜杠 `/web` |
| `git-awareness` | `git_status` |
| `context-budget` | `get_context_remaining` |
| `elicitation` | `ask_user`（成功后本轮立刻停，答复即问题正文） |

`task` 阻塞等独立结果；`workflow` 跑命名 DAG（后步用 `{id}` 引用前步）。其余 6 个是长驻 sub-agent 的生命周期管理（派出去、按需收、中途改向）。孩子默认不继承这组工具；要嵌套委派或收紧核心工具，用 `plugins` / `tools` 参数，见 [Tools](tools.md)。

### 开启方式

会话里 `/plugins` 列出本会话启用集；`/plugins on <name>` / `/plugins off <name>` 立刻改本会话、写进 settings，下一轮生效。Web 斜杠命令同语义。

```bash
piz --plugins                          # 列出全部插件与当前启用状态
piz --plugin lsp --plugin todo         # 本次开启（可重复）
piz --no-plugin cross-session-memory  # 本次关闭（撤钩、撤工具、撤 schema）
```

持久生效写进 `~/.piz/settings.json`：

```json
{ "plugins": ["lsp", "todo"], "disabled_plugins": ["cross-session-memory"] }
```

`--plugins` 显示的是**本次实际生效**的状态（出厂集 + settings.json + `--plugin` / `--no-plugin` + 技能自动检测），不是编译期默认。关在开之后应用，所以 `--no-plugin` 能盖掉 settings 里的开启。

> 关掉的插件**钩子不跑、工具查不到、schema 不进请求**。不只是不出现在 tools 定义里。

`piz --plugins` 在内置表之后列出当前工作区已装包声明的工具（`[pkg] name`）。包工具走 `command-canonicalization`，与 `bash` 同一套危险模式拦截。

## 钩子契约

`Plugin` 结构（`src/plugins.zig`）的全部挂载点：

| 钩子 | 签名 | 时机与语义 |
|------|------|-----------|
| `before_turn` | `fn (ctx) void` | 每轮请求前。可改 `messages`（裁剪、注入）。**串行调用**，不在并行区。 |
| `on_compact` | `fn (ctx, summary) void` | 压缩成功后。复用已有摘要，不额外调模型。 |
| `on_compact_failed` | `fn (ctx) ?[]const u8` | 压缩失败。返回非 null 则用该模型名重试一次。 |
| `on_tool_before` | `fn (chain: *BeforeChain) ?[]const u8` | 工具执行前 waterfall。须 `chain.next()` 才放行后续；不调即短路。返回非 null 则**跳过执行**，该字符串作为错误结果回模型。 |
| `on_tool_result` | `fn (chain: *AfterChain) ?[]const u8` | 工具成功后 waterfall。须 `chain.next()` 才放行后续。返回非 null 则**替换**结果内容。 |
| `on_user_message` | `fn (ctx, text) ?[]const u8` | 用户消息提交时。返回非 null 则替换进模型的文本（须挂 Agent.alloc）。多个插件同钩：声明序，第一个非 null 胜出。 |
| `after_turn` | `fn (ctx) void` | 一轮结束（有答复、中止、空转止损之后）。串行。可记账、落盘、改会话元数据。 |
| `slash_commands` | `[]const SlashCommand` | 注册 `/name`。TUI picker/`/help` 与 Web `/api/help`、`POST /api/slash` 同源分发。`todo`→`/todo`，`skills`→`/skills`，`context-budget`→`/context`，`git-awareness`→`/git`，`lsp`→`/lsp`，`web-search`→`/web`，`task-delegation`→`/agents`。 |
| `tools` | `[]const Tool` | 注册工具，与核心工具一起暴露给模型。 |

`ctx` 是 `*Agent` 的不透明指针，用 `@ptrCast(@alignCast(ctx.?))` 取回。

多个插件挂同一钩子时按 `builtin_plugins` 的声明顺序执行。`on_tool_before` / `on_tool_result` 是 waterfall：先注册的在外层，须调 `next()` 才进入内层；不调即短路。其余返回 `?T` 的钩子仍是第一个非 null 胜出。

## 各插件行为

### 快压（已入核心，不再是插件）

大 tool 结果进门即定形（密图 + 摘录），此后不改；85% 硬线机械折页。见 `compress.zig`。旧版回溯式 prune/shake/snap 已废 —— 改已送消息会把 prompt cache 前缀整段作废。

### cross-session-memory

压缩产生的摘要追加到 `<配置目录>/memories/<cwd-slug>.md`，下次在同一目录启动时注入系统提示。

这样跨会话能记住「这个项目用什么构建、上次做到哪」。零额外模型调用 —— 复用 compact 已经生成的摘要。

`/memory` 系列命令直接读写这个文件，见 [Usage](usage.md#斜杠命令)。

### concept-graph

从压缩摘要里提取概念条目，与 memory 一起持久化。

### compact-resilience

压缩请求失败时（模型不可用、超限），若当前 provider 配了多个模型，用第二个模型重试一次。避免上下文爆了但压缩也失败的死局。

### command-canonicalization

拦截明显的破坏性命令。当前黑名单：

```
sudo rm -rf /
rm -rf / 
rm -rf /*
rm -rf ~
rm -rf $HOME
mkfs.
:(){ :|:& };:
> /dev/sd
dd if=/dev/zero of=/dev/sd
chmod -R 777 /
curl|wget … | sh/bash
```

命中时返回错误给模型，要求它换个安全写法或说明必要性。`curl|wget | sha256sum` 这类不算。

> **这是启发式黑名单，不是安全边界。** `rm -fr /` 仍绕得过。定位是防手滑，不是防恶意。真正的隔离：`/sandbox workspace`（bwrap，工作区外只读）或 `strict`（再断网），再加权限门（写文件、shell、出网、委派会问）。

### artifact-store

工具输出超过 4KB 时写到 `<配置目录>/artifacts/`，模型拿到文件路径而非全文。`bash` 超过 16KB 时自己边跑边落全文（不丢头），回执已带 `[Artifact stored:]`，本插件不再二次外置。需要细节时用 `read` 按需取。

### lsp

桥接真实语言服务器（LSP over stdio + JSON-RPC）。工具用法见 [Tools](tools.md#lsp)，这里记设计取舍：

- **每次调用起新进程，不缓存。** 换来无状态泄漏与无并发协调问题，代价是大仓库首次索引开销。要改成常驻服务器池的话，注意工具会在多个工作线程里并发调用。
- **15 秒超时是硬上限。** 语言服务器索引慢是常态，但 agent 循环绝不能被永久阻塞。超时后 `kill` 进程并返回可操作提示。
- **`rename` 只报告不落盘。** 写文件必须走 `edit` / `multi_edit`，才能过权限门与 per-file 写锁。
- **`diagnostics` 用 hover 当同步栅栏。** 诊断是服务器主动推的通知，没有对应请求可等；发一个 hover 请求给服务器完成分析的机会，再从缓冲里捞 `publishDiagnostics`。
- **帧解码要容忍不完整数据。** `Content-Length` 头与 body 可能分多次到达，解码器在数据不全时返回 null 让调用方继续读，不能误判为坏帧。也容忍 LF-only 分隔（部分服务器不严格用 CRLF）。

> **踩过的坑：** `std.process.Child.kill` 内部会关闭并清理全部管道。在 `kill` 之前手动 `close(stdin)` 会造成 double close，std 在 Debug 下直接 panic（EBADF）。单测覆盖不到这条路径，是真实语言服务器烟雾测试才暴露出来的。

## 新增一个插件

三步。以「加一个 `line_count` 工具」为例。

**1. 写 handler**（`src/plugins.zig`）

无需 Agent 状态就用普通 handler：

```zig
fn toolLineCount(arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{}) catch
        return .{ .content = "error: invalid JSON arguments", .is_error = true };
    const path = if (v.object.get("path")) |p| (if (p == .string) p.string else "") else "";
    if (path.len == 0) return .{ .content = "error: missing 'path'", .is_error = true };
    const data = std.Io.Dir.cwd().readFileAlloc(agentmod.util.io, path, arena, .limited(16 * 1024 * 1024)) catch |err|
        return .{ .content = try std.fmt.allocPrint(arena, "error reading {s}: {s}", .{ path, @errorName(err) }), .is_error = true };
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |_| n += 1;
    return .{ .content = try std.fmt.allocPrint(arena, "{s}: {d} lines", .{ path, n }) };
}
```

需要读会话状态（模型名、上下文占用）就用 `ctx_handler`：

```zig
fn toolSomething(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    // self.provider / self.model / self.last_usage / self.messages ...
}
```

`ctx_handler` 的条目 `.handler` 必须填 `toolCtxStub` 占位。

**2. 注册到 `builtin_plugins`**

```zig
.{ .name = "line-count", .enabled_by_default = false, .tools = &.{
    .{
        .name = "line_count",
        .desc = "Count lines in a file.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"File to count."}},"required":["path"]}
        ,
        .handler = toolLineCount,
    },
} },
```

`.schema` 是**必填**的。不需要动 `appendToolDefs` —— 它自动遍历 `builtin_plugins` 收集，是工具定义的单一真相源。

**注册工具的插件必须 `enabled_by_default = false`。** 有测试守着这条：默认启用的插件不许带工具，带工具的插件必须默认关。理由是每个工具都占每轮的 tools 定义，默认开就是替所有用户付这个成本。

只挂钩子、不加工具的插件可以默认开（省掉 `enabled_by_default` 即为 true）——它们零 token 成本。

**3. 写测试**

```zig
test "line_count tool" {
    const t = std.testing;
    try agentmod.util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ... 造文件、chdir 进临时目录、调 handler、断言
}
```

有两个测试会自动守着你的新工具：`src/plugins.zig` 里校验所有插件工具的 schema 合法且 `type == "object"`；`src/ai.zig` 里校验 schema 真的进了请求体。

## 并发注意事项

工具**并行执行**（上限 8），写插件时注意：

- **工具 handler 会在工作线程里跑。** 不要在 handler 里改 `Agent` 的可变状态（`messages`、`last_usage`）。现有 `ctx_handler` 只读 `provider` / `model` / 计数。
- **`before_turn` 不在并行区。** 它可以安全地改 `messages`。
- **`on_tool_before` / `on_tool_result` 在串行阶段调用** —— 前者在 preflight，后者在按序写回阶段。可以安全触碰共享状态。
- **需要跨调用的插件状态**要自己加锁，并且按 Agent 实例隔离。参考 `todo` 插件：用 `std.AutoHashMap(usize, ...)` 以 Agent 指针地址为 key，配 `std.Io.Mutex`。用全局单例会让 Web UI 的多个会话互相踩。
- 状态用长生命周期 allocator（`self.alloc`），**不要用 arena** —— arena 每轮释放。
