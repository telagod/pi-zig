# 代码评审(2025-08 自查)

本页是一次独立的代码走读记录:强项、弱项、风险与改进优先级。评审针对
`zig 0.16.0`,复核时 `zig build`(ReleaseFast)干净通过、`zig build test`
340 个测试全绿。贴图落盘回放；写盘不得逃出工作区；`read` 带行号；TUI 转录细胞封顶 400。

范围:src/ 全量结构 + agent 主链路 + 工具层 + 测试约定;tui/webui/ai 的
逐行细节未完全覆盖,大文件单体的判断基于体量与模块边界。

## 总评

**B+/A- 的独立重写项目。** 核心链路(组消息 → 调模型 → 跑工具 → 压缩)写得
简洁克制。工程质量的主要风险不在"会不会坏",而在"坏了能不能查"——即错误
吞掉和文件单体这两个维护性问题。

## 强项

### 1. 注释是文档级的,而且都是"为什么"

每个反直觉决策都带实测证据,读到的人直接继承踩坑经验:

- `runToolSlotGated` 解释为什么不用"一批 8 个 join 完再开下一批":实测
  9 个各 100ms 的工具,分批 202ms,流水线(信号量补位)102ms ——
  [agent.zig:195](../src/agent.zig)
- 多文件锁按路径字典序获取,注释明说"这是加多锁的必要条件,不是优化,
  少了它两个 multi_edit 撞上重叠文件集就会永久互等" ——
  [agent.zig:208](../src/agent.zig)
- thread-local `tool_root` 的动机是 web 多 workspace 下实测复现过的数据
  损坏("会话声明在 projB,`write out.txt` 落进 projA") ——
  [tools.zig:18](../src/tools.zig)

### 2. 代码里能看到真实调试过的痕迹

- 中断用原子 `cur_stream_fd` 而非 `?*httpc.Stream` 指针,注释直说旧方案
  是 UAF —— [agent.zig:393](../src/agent.zig)
- 流中断自动续跑,上限 2 次、计数不重置;重连额度用尽时把半截回复交出去
  并说明不完整,不让用户空手而归 —— [agent.zig:820](../src/agent.zig)
- 压缩失败不吞:吞了下一轮会撞 provider 400,用户看到的是静默失败 ——
  [agent.zig:710](../src/agent.zig)

### 3. 测试是真测试,不是凑数

- e2e 内嵌 mock OpenAI provider 走真实 HTTP 端口,用原子 flag 断言请求体
  内容("第二轮是否带 tool_call 历史""tools 是否排在 messages 之前保证
  缓存前缀稳定""读图请求是否带 data: base64") —— [e2e.zig:1](../src/e2e.zig)
- 连刁钻行为都覆盖:identical tool calls 连续截断、salvage 不覆盖模型
  真话、嵌套委派被深度门拦住。
- `seams.zig` 的 fs / llm / find_tool 注入缝让测试不碰真实文件系统与
  网络,设计干净。

### 4. 架构决策克制

- 插件启用集是 per-Agent 位掩码而非进程级单例(否则"一个 Agent 开了
  skills 会让所有 Agent 都看到 skill 工具") —— [agent.zig:370](../src/agent.zig)
- 模块拆分对齐 pi 子包结构,core / tui / app 三层;依赖只有 Zig 标准库
  + vendored stb;`build.zig` 默认 ReleaseFast 并解释原因(裸 `zig build`
  会静默产出带调试信息的 46MB 慢二进制)。
- 已知坑不藏着:`mcp.zig` 测试不收集进 `core.zig` 的 test 块,因为
  Zig 0.16 全量引用闭包下 sema 挂死,注释里说明了移居 e2e.zig 的原因。

## 弱项与风险

### 1. `catch {}` 仍多,入口层已有 debug 通道

`util.debugCatch` 已落地,`PIZ_DEBUG=1` 打 stderr。session mkdir、bash spill、
cmd_web 若干入口已改走它。session 落盘/清临时文件已走 debugCatch。
剩余吞错多为 TUI 绘制 / 测试清理 / 写盘 best-effort。坏的时候先开 `PIZ_DEBUG`。

### 2. 工具失败的错误信息丢了

[agent.zig:184](../src/agent.zig) 与 :186:

```zig
slot.result = h(...) catch .{ .content = "tool crashed", .is_error = true };
```

错误值整个丢弃,模型只知道"崩了",不知道"文件不存在"还是"权限拒绝"。
对 agent 的自愈能力是实打实的损失,与项目自己定的"自愈"基调矛盾。

### 3. 大文件单体

| 文件 | 体量 |
|---|---|
| src/tui.zig | 187 KB |
| src/ai.zig | 125 KB |
| src/main.zig | 104 KB |
| src/webui.html | 217 KB(内联) |
| src/pricing.zig | 274 KB(生成物) |

模块边界清楚,但这个体量下任何单个文件的 review 成本都接近极限。

### 4. provider 怪癖漏进核心循环

deepseek 的 DSML 标记、U+FF5C 全角竖线直接出现在 agent 主循环的
`textToolCallMarker` 里 —— [agent.zig:54](../src/agent.zig)、
[ai.zig:816](../src/ai.zig)。这类特例应收敛到 ai.zig 的 provider 适配层,
否则每加一个 provider 主循环就要动一次。

### 5. token 估算是启发式

按 UTF-8 序列长度分档计权(ASCII 4 字节/token、CJK 3 字节/token)——方向
对(中文对话是常态不是边缘情况),但精度有限,可能触发过早压缩或漏压缩。
见 [agent.zig:640](../src/agent.zig)。

## 改进优先级

| 优先级 | 事项 | 理由 | 状态 |
|---|---|---|---|
| P0 | 工具失败透出错误名/错误信息,不再统一 "tool crashed" | 直接伤害模型侧自愈能力 | 已落地: `tools.crashResult`,三处调用点 |
| P1 | 审计 `catch {}`,入口层吞错至少留 debug 日志通道 | "坏了能不能查" | 通道已有;`cmd_web`/`webui`/`session`/`main` 斜杠与 JSON 已改 `debugCatch`;余 mutex/sleep/signal/测试清理 |
| P2 | provider 怪癖隔离到适配层;大文件按边界拆 | 每加 provider 都要动主循环,review 成本 | 标记清单在 `ai_markers.zig`;tui/tools 已拆,main/ai 仍大 |
| P3 | pricing.zig 生成物考虑构建时生成 | 避免价格表变更的 diff 噪音 | 未做 |

### 已落地(2026-08-16)

- P0:`tools.crashResult(alloc, name, err)` 回执 `tool crashed (name): ErrorName`。`agent.runToolSlot` 的 handler/ctx_handler、TUI `!cmd`、Web `!cmd` 三处不再吞成裸 `"tool crashed"`。回归:`crashResult surfaces error name`、`tool handler error surfaces the error name`。
- P1:`util.debugLog` 受 `PIZ_DEBUG` 门控;`crashResult` 已打。入口层 JSON/斜杠/快压/队列已改;mutex/sleep/signal 保留。
- P2:`TEXT_MARKERS` / `textToolCallMarker` 在 `ai_markers.zig`;ai 再导出。
- 后续已落地:`pkg.json` tools[]、write 原子落盘、gitignore 按目录、`edit replaceAll`、`fetch_url` SSRF、Web 贴图/缩略图/自动标题、TUI `/find` 裁后仍可搜。
- 仍欠:大文件继续拆（`tui`/`main`/`ai` 仍大）。已抽出：tui slash/measure/footer/keys/draw/types/emit；tools_fs/json/path/search/bash/edit/read/write/skill；`ai_markers`/`ai_json`；`cmd_help`。`catch {}` 入口层已大量改 `debugCatch`，mutex/sleep/signal 保留。
- OS sandbox 已落地:`sandbox.zig` + `sandboxMode` / `/sandbox` / `--sandbox`。优先 bwrap；否则 Landlock（`piz sandbox-exec`）。两路都没有才 fail-closed。

## 复核信息

- 评审日期:2026-03-26
- 工具链:Zig 0.16.0;`zig build test` 340 全绿
- 二进制:ReleaseFast 静态可执行,`--help` 正常
