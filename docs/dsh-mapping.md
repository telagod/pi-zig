> piz 可以帮你写 piz。先读本文，再读 `docs/plugins.md` 与 `docs/packages.md`。改插件表或主链路前，核「可摘 / 不可摘」。

# dsh 对照札

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的插件哲学映射到本仓**已有**钩子。本文是北极星，不是施工图。不改运行时。

dsh 原句：**everything is a plugin**。无特权内核；扩展是把插件挂到别的插件旁边。本仓原句：核心只做主链路，其余编译期注册。两边都要「新行为不进 loop」，手段相反。

## 原则对照

| dsh | 本仓现状 | 可摘？ |
|-----|----------|--------|
| 万物皆插件，含 agent loop | `agent.zig` 是特权主链；插件是函数表 | 不可摘。loop 进加载器 = 丢掉静态二进制与零 ABI |
| `ctx.<key>` 服务面，不 import 实现 | 插件 `ctx` 是 `*Agent` 不透明指针；工具/fs/llm 多为直调 | 可摘接口，不可摘 Cordis |
| `inject` 声明依赖，加载序由依赖决定 | `builtin_plugins` 数组序；`--plugin` 只是位掩码 | 不可摘加载器。序可文档化，勿暗依赖 |
| 注册是可逆副作用（`ctx.effect`） | `enable`/`disable` 成对；关位撤钩、撤工具、撤 schema | **已摘** |
| 事件即扩展点 | 编译期钩子 + Packages `events.Bus` | 半摘。钩子已是点；Bus 是观察，不是策略 |
| waterfall 须 `next()`，不调即短路 | `BeforeChain` / `AfterChain`：须 `next()` 才放行 | **已摘** |
| 能力 seam = Definition + Provider + Consumer | `seams.zig`：fs / llm 默认 Provider；`Agent.find_tool` / `llm_run` / `fs` 可换；loop 与工具已接入 | **已摘并接入**，默认仍是本地实现 |
| 模型可见 ⟺ 已记录 | `Session.reconstructModelVisible` + `architecture.md` 清单 | **已摘纪律**。系统提示仍是每轮重装 |
| 改 loop 须改架构文档 | 有 `architecture.md`，无硬门禁 | 可摘纪律，不必抄 Cordis |
| profile + bundle + patch 叠层 | settings / `--plugin` / Packages 目录 | 不可摘 YAML 组装树。叠层语义可借鉴：默认核 + 可选插件 + 用户包 |
| 误配即炸 | 部分路径静默跳过（包缺文件、插件名不识） | 可摘纪律 |

## 扩展点地图

dsh 选事件域是改动的第一个决定。本仓对应如下。

### 编译期钩子（`plugins.zig`）≈ dsh `agent/*` + `tools/*`

| 本仓钩子 | 时机 | 近于 dsh | 差在哪 |
|----------|------|----------|--------|
| `before_turn` | 每轮请求前 | `agent/pre-step`（无 reject/rewrite 消息） | 只能副作用（快压），不能拒领或改写入箱 |
| `on_tool_before` | 工具执行前 | `tools/pre-execute` waterfall | 须 `next()`，可包装 |
| `on_tool_result` | 工具结果回写前 | `tools/post-execute` | 同上，无 `next()` |
| `on_compact` | 压缩成功 | 近 `ctx.compaction` 之后的观察 | 无独立 compaction seam |
| `on_compact_failed` | 压缩失败 | 近 `agent/request-error` 救援 | 返回备用模型名，不是通用错误链 |
| `on_user_message` | 用户提交 | 近 inbox 观察 | 不能改写/拒绝 |

多个插件同钩：声明序执行。工具前后是 waterfall；其余 `?T` 钩子仍首胜。

### Packages 事件（`events.zig`）≈ dsh `emit` 观察

`startup` / `user_message` / `tool_start` / `tool_end` / `turn_end` / `shutdown`。

命令 detach，stdin 喂 JSON，piz 不等、不收输出。这是**旁路观察**，不能当审批门。审批在 `on_tool_before` 与 TUI/Web 权限门。

### 会话 JSONL ≈ dsh 会话事件（残）

记了模型对话三态。未记：系统提示拼装、skill 加载、记忆注入、快压占位的「为何裁」。dsh 铁律「进模型的都能从日志重建」——本仓尚未立。

### Web 插件 ≈ dsh ConversationNode（远）

`web/` 注入 JS/CSS，走 DOM 槽。不是 `session/event` 投影，也不能换 Chat 节点类型。别和宿主插件表混谈。

## 已对齐（勿再发明）

- 新行为优先挂钩子，不进 `agent.zig` 主链 —— 与「Plugins, not loop changes」同向。
- 工具 schema 进提示拼装（`appendToolDefsIn`）—— 近 Consumer 挂 `ctx.tools`。
- 权限门、沙箱、快压已是可关插件，不是焊死在 loop 里。
- Packages 把技能/事件/前端打成目录 —— 近 bundle，只是无 patch 语言。

## 不可摘（动则换身份）

- Cordis / `cordis.yml` / 运行时加载 .so 或 JS 插件。
- 把 `agent.zig` 降成可替换 Provider。主链留在核心，是静态二进制的代价。
- 为 seam 而引入第三方运行时或 ABI。

## 可摘进度

1. **纪律** — 已摘。见上表与 `architecture.md`「模型可见清单」。
2. **挂钩形态** — 已摘。`BeforeChain` / `AfterChain`。
3. **seam 切口** — 已摘并接入。`seams.Fs` / `seams.LlmRun` / `Agent.find_tool`；`runToolSlot` 绑定 fs，loop 走 `llm_run` / `find_tool`，核心工具与 `read_image` 走 `seams.fs()`。默认仍是本地实现。
4. **可逆** — 已摘。`enable`/`disable` 成对；关位后钩子、工具、schema 一并消失。`--no-plugin` 与 `disabled_plugins`。

对照到此为止。要动代码，另下差遣，并点明上表第几条。
