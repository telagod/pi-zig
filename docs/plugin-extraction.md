# 插件抽离路线:内置 Zig → 真 JS 插件

目标:把 `src/plugins/` 里适合的内置插件从编译期 Zig 表抽成**运行时 JS 扩展**
(jsrt 窄桥,见 [JS 扩展](extensions-js.md)),核心瘦身、免编译可改、用户可同名覆写。
抽离判定一句话:**桥有能力、核心不留安全隐患、行为可原样复刻**,三者齐才动手。

## 对账表(内置十五件 × 桥能力)

| 插件 | 挂载点 | 所需能力 | 判定 |
|------|--------|----------|------|
| `usage-ledger` | `after_turn` | agent_end 携 usage 载荷 + appendFile | ✅ **已抽**(内嵌层,见下) |
| `command-canonicalization` | `on_tool_before` | tool_call 拦截 | 桥有,**但安全件留核**,不抽 |
| `artifact-store` | `on_tool_result` | tool_result `{replace}` 改写 | ✅ **已抽**(改写桥随件落) |
| `cross-session-memory` | `on_compact` | on_compact 事件(携 summary) | ⏳ 待桥 |
| `concept-graph` | `on_compact` | 同上 | ⏳ 待桥 |
| `compact-resilience` | `on_compact_failed` | on_compact_failed(可返备用模型名) | ⏳ 待桥 |
| `web-search` | tools + /web | fetch + safe 护栏 + 门控装载 | ✅ **已抽**(safe fetch + `{error}` 透传 + gate 三桥随件落) |
| `skills` | tool + /skills | 宿主 API:skills index | ✅ **已抽**(`piz.listDir` 原语;pushGates 装了技能即开门) |
| `context-budget` | tool + /context | 宿主 API:estTokens/窗口 | ✅ **已抽**(`piz.contextStats()` 快照,桥注人) |
| `git-awareness` | tool + /git | exec 子进程 | ✅ **已抽**(`piz.exec(argv)`,与 execShort 同则:截 64KB/exit≠0→null) |
| `elicitation` | ask_user 工具 | 无(原件不触 UI,纯回执文本) | ✅ **已抽**(零桥复刻;停轮逻辑按名在核) |
| `todo` | tools + /todo | 会话态隔离 | ✅ **已抽**(快照携 `sid`=Agent 指针,JS 按 sid 分桶;plugins/todo.zig 删,语义由 jsrt parity 测试担) |
| `lsp` | /lsp + stdio 子进程 | exec + 长连 stdio | ❌ 留核:桥无长连 stdio(exec 为一次性收干),非安全因 |
| `vision-input` | read_image 工具 | 图像解码/缩压 | ❌ 二进制活,留核 |
| `task-delegation`/`workflow`/`childbind` | 生/管子代理 | 核内调度 | ❌ 永不抽 |

## 缺桥清单(按抽取顺序补)

1. ~~agent_end 载荷扩 usage~~ ✅ 已落(`e.usage={in,out,cr,cw,usd,model,cwd,ts,config_dir}`)
2. ~~`piz.appendFile`~~ ✅ 已落
3. ~~JS 工具 `{error}` 透传~~ ✅ 已落(prelude callTool)
4. ~~`piz.fetch` safe 护栏~~ ✅ 已落(opts.safe → httpc.urlBlocked,SSRF 拦含 getent 回拦;护栏自 plugins/web.zig 迁入 httpc.zig)
5. ~~内嵌档 gate 门控~~ ✅ 已落(bundled_exts.gate + plugins.pushGates/refreshExtracted;开关即重扫)
6. ~~`tool_result` 许改写~~ ✅ 已落(handler 返 `{replace}` 替换输出,全文不截;`piz.configDir()` 同落)
7. 事件:`before_turn` / `on_user_message` / `on_compact(summary)` / `on_compact_failed`
8. 宿主 API:~~`contextStats()`~~ ✅、~~`skillsIndex()`~~ ✅(以 `listDir`+`readFile` 拼)、`exec(argv)`(白名单?)

## 内嵌层(默认启用件的抽离去处)

默认启用件抽成 JS 后**仍须随二进制出厂**,否则 `-Dquickjs=off` 之外的用户默认退化。
故设三档装载序:

1. **内嵌** `src/embedded/extensions/*.js`(@embedFile,随二进制)
2. **用户** `~/.piz/extensions/`
3. **项目** `<cwd>/.piz/extensions/`

覆写语义:**同名 basename 后者胜** —— 用户/项目目录里放 `usage-ledger.js` 即顶替内嵌那份
(内嵌先记名,目录扫描命中同名则跳过对应内嵌件)。热重载 `/reload` 三档重扫,语义不变。

默认关闭件抽后保开关语义:内嵌表项携 `gate = 插件名`,jsrt 仅当启用集含其名才装载
(plugins.zig 留空壳行守名籍;开关走 pushGates/refreshExtracted 即重扫)。**默认开件同理带 gate**
(usage-ledger/artifact-store 皆然)——凡抽离件皆带 gate,名籍一律留壳。

代价:`-Dquickjs=off` 的纯静态构建失去已抽件(usage-ledger 即记账,失之无碍;
安全件正因如此留核)。每抽一件,此档与 [plugins.md](plugins.md) 清单同步改。

## 抽离序

1. ✅ `usage-ledger`(after_turn+记账,最小,验水道)
2. ✅ `web-search`(默认关;gate 门控保开关语义,护栏迁 httpc 供 safe fetch)
3. ✅ `artifact-store`(默认开;`{replace}` 改写桥;read 系跳过/阈值/预览边界与原 Zig 版同则)
4. ✅ `cross-session-memory` / `concept-graph`(compact 事件;e2e 记忆管线改经 JS 件验)
5. ✅ `context-budget`(`piz.contextStats()`;callTool/runCommand 携快照,互斥下无竞态;默认关保语义)
6. ✅ `skills`(`piz.listDir`;搜索序与 toolSkill/loadSkillsIndex 同;名校验/error 文案 parity)
7. ✅ `elicitation`(零桥)→ `todo`(sid 桶)→ `git-awareness`(`piz.exec`)
8. 留核定案:`lsp`(长连 stdio)、`compact-resilience`(死件,接线另立差)、`command-canonicalization`/`vision-input`/子代理三家
6. 留核:`command-canonicalization`(安全)、`vision-input`(二进制)、子代理三家(调度);`compact-resilience` 暂缓(见对账表)

## 验收标准(每件必过)

- 行为 diff 为零:同一会话抽前/抽后产物逐字节一致(ledger 行、记忆 md、拦截判定)
- `zig build test` 全绿;新 JS 件有 jsrt 层单测(emit 直驱)
- 同名覆写生效有单测;`/extensions` 列表可见内嵌件
- no-quickjs 构建(`zig build -Dquickjs=false`)编过
