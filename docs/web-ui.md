> `piz web` 启动后会自动开浏览器，URL 里带一次性 token。直接用就行。

# Web UI

piz 自带一个本地 Web UI：单进程 HTTP 服务 + SSE 流式推送 + 单页前端（编译期嵌入二进制，无静态文件依赖）。

pi 没有这个功能。设计上参考了 kimi code 的交互与视觉语言。

## 目录

- [启动](#启动)
- [鉴权](#鉴权)
- [能力](#能力)
- [多项目与多会话](#多项目与多会话)
- [HTTP 端点](#http-端点)
- [安全边界](#安全边界)

## 启动

```bash
piz web                          # 127.0.0.1:5494，随机 token，自动开浏览器
piz web --port 8080              # 指定端口
piz web --no-open                # 不自动开浏览器（打印 URL 自己复制）
piz web --token mysecret         # 固定 token
piz web --no-token               # 关闭鉴权（见下方警告）
```

端口缺省 5494，被占用时自动 +1 直到 5503；显式 `--port` 时不自动递增，占用即报错。

启动输出：

```
piz web: http://127.0.0.1:5494/#token=0cbc72149b1492b0e5e8ddd11b95fb33  (Ctrl+C 退出)
```

## 鉴权

**默认开启。** 每次启动生成一个随机 16 字节 token，写进打开的 URL 的 fragment（`#token=...`）。前端读取后存进 `sessionStorage` 并从地址栏抹掉，后续请求带 `Authorization: Bearer <token>`。

| 模式 | 行为 |
|------|------|
| 缺省 | 随机 token，每次启动不同 |
| `--token T` | 固定 token，适合需要复用 URL 的场景 |
| `--no-token` | 完全不鉴权，启动时打印警告 |

免鉴权的路径（否则登录页自己都加载不出来）：

- `GET /`、`GET /index.html`
- `GET /api/plugins/assets/*`（Web 插件的 JS/CSS）

其余所有端点在开启鉴权时都要求 Bearer token，未授权返回 401。

> **`--no-token` 的实际风险：** 服务绑定 `127.0.0.1`，远程访问不到。但**本机浏览器里的任意页面**都能向它发请求 —— 没有 CSRF token 也没有 Origin 校验。你打开的某个恶意网页可以 POST `/api/chat` 驱动 agent 在你的仓库里跑 bash。只在完全可信的单用户环境用这个开关。

## 能力

| 功能 | 说明 |
|------|------|
| 流式对话 | SSE 推送文本与推理内容 |
| 活动条 | 输入框上方显示在跑工具/后台 bash 的耗时与字节；`/jobs` 同表 |
| 后台活动钮 | 会话头 `⠿` 钮带活动计数 badge（借 dsh ui-jobs 之形），点开弹层平铺列表：字元 ●子代理 / ↻模型 / ▸工具、名称、详情、时长；esc 或点外关闭 |
| 贴图 | Ctrl+V 或 `/paste` 从剪贴板附图 |
| 工具卡片 | 可折叠，按工具类型分类渲染（终端输出走 ANSI 着色，`write`/`edit` 走 diff 着色） |
| Workflow 轨道 | `workflow` 在对话里是一截节点轨，与 Thought / 工具摘要同级。回放与再跑同一 goal 写进同一截，不叠第二块。点节点展开该步报告 |
| Diff 高亮 | 增行绿、删行红、hunk 头强调 |
| 权限审批 | 默认全权。输入框旁 `yolo` 打开三档：yolo / ask / read-only。询问档下工具卡点允许/拒绝 |
| 中断 | 生成中随时打断 |
| 会话管理 | 列表、切换、fork、undo、compact、归档、恢复、删除 |
| 会话搜索 | `Ctrl/⌘K` Spotlight，按标题与名字过滤 |
| 斜杠命令 | 输入 `/` 弹出菜单：前缀优先、模糊次之、说明关键字；Tab 补全、Enter 执行。空框 `j` 任务、`u` 用量、`c` 复制、`s` 沙箱、`?` 快捷键卡 |
| 文件引用 | 输入 `@` / `@./` 弹出工作区文件补全，目录 Enter 进入 |
| 本页命令 | 行首 `!cmd` 跑并送模型，`!!cmd` 只跑不送；composer 上方有预览 |
| 设置 | 外观、智能体（本会话模型/思考/授权、bash 沙箱、新会话默认）、通知、关于。`/theme light\|dark\|system` 同外观页 |
| 沙箱药丸 | 输入栏旁 `sb off` / `workspace` / `strict`，点开即切 |
| 上下文环 | 工具栏显示占用百分比，超过 85% 提示压缩 |
| 草稿与历史 | 未发送草稿按会话落 localStorage；↑/↓ 翻输入历史 |
| 模型切换 | 界面内切，per-session 生效；`/refresh` 拉各 provider 的 `/models` |
| 多项目 | 注册多个工作区，各自独立会话池 |
| 自动标题 | 未命名会话用首条用户消息的第一行作侧栏标题 |
| 重新生成 | 助手气泡 ↻，或 `Ctrl+Shift+R`。`Ctrl+Shift+C` 复制最后一条回复 |
| 前端插件 | 注入自定义 JS/CSS，见 [Web plugins](web-plugins.md) |

会话池上限 4 个并发会话，每个会话独立的 Agent 实例、arena 与工作线程。

### 资源上限

| 上限 | 值 | 越界行为 |
|------|-----|---------|
| 并发 TCP 连接 | 64 | 立刻关闭，客户端 connect 成功但读到 EOF |
| 并发 SSE 流 | 16 | `503` + `{"error":"too many event streams"}` + `retry-after: 5` |
| 请求头读超时 | 无 | 见下面的说明 |
| 并发会话 | 4 | `/api/chat` 返回 `{"ok":false,"error":"rejected"}` |
| 入队失败 | — | `/api/chat` 返回 `{"ok":false,"error":"queue failed"}`，页面 toast 并取消 running |
| 切模型失败 | — | `/api/model` 失败 toast `switch model failed` |
| 设置/斜杠失败 | — | think / 授权 / action / 会话列表失败均 toast |
| 改标题失败 | — | `/api/title` 失败 toast `set title failed` |
| 启动/沙箱失败 | — | `/api/state` `/api/config` 与沙箱切换失败均 toast |
| `/think` | — | 等服务器回写后再显示实际档（含夹紧） |

每个连接一个 OS 线程加 12KB 栈缓冲，所以连接数必须有上限——否则本机一个
循环 `connect` 就能把线程耗光，agent 随之停摆。

SSE 槽位在客户端断开时立即回收：只写不读的长连接感知不到对端离开（写一个已关闭
的 socket 第一次还会成功），所以轮询里用 `MSG_PEEK|MSG_DONTWAIT` 探测 EOF。
关标签页后槽位在 200ms 内释放，不必等心跳超时。

**没有请求头读超时。** 试过 `setsockopt(SO_RCVTIMEO)`，不能用：`std.Io.Threaded`
假定所有 fd 都是阻塞的（它自己管调度），超时让 `recv` 返回 `EAGAIN`，而 Threaded
把 `EAGAIN` 当 programmer bug —— Debug 构建直接 panic，ReleaseFast 下静默转
`error.Unexpected`。真要做得靠看门狗线程 `shutdown(fd, SHUT_RD)` 把阻塞的 `recv`
变成干净的 EOF。

没做的理由：服务绑 `127.0.0.1`，能占住连接的攻击者已经在本机执行代码，那时他直接
读 `~/.piz/models.json` 就有 apiKey，占满 64 个连接是最不划算的选择。连接数上限
已经挡住了线程耗尽这个后果。

## 多项目与多会话

启动时当前目录自动注册为第一个工作区。侧栏按**项目**分组：当前项目展开其会话，点另一个项目就切过去。也可以「添加项目」注册别的绝对路径，每个工作区有自己的会话列表。所有会话链接都带 `?ws=`，不会串到别的仓库。

工具的相对路径相对**会话所属 workspace** 解析，不是进程启动目录。早先所有工具走
`Dir.cwd()`（进程级），会话声明在 projB 而 `write out.txt` 落进 projA 是实测复现过的
数据损坏 —— 用户以为在改 B 项目，实际在改 A 项目。现在分发工具前把 thread-local 的
root 设成 `Agent.cwd`，`bash` 则直接以它作为子进程的工作目录。

所有 API 端点接受两个 query 参数：

- `?ws=<项目根绝对路径>` — 指定工作区，省略则用默认
- `?session=<会话名>` — 指定会话，省略则用 `default`

## 会话存什么

一份真源，两处附件：

| 位置 | 作用 |
| --- | --- |
| `~/.piz/sessions/web/<项目slug>/<名>.jsonl` | 事件日志：用户/助手/思考/工具全文 |
| `~/.piz/artifacts/<ts>-<工具>.txt` | 超 4KB 的 bash 等输出外置，jsonl 里留指针 |
| 工作区磁盘 | 文件本身，不另做快照 |

刷新读 jsonl（最近 80 条、每条最多 16KB）。更早的对话点顶部「↑ 更早 N 条」走 `/api/history` 往前翻，滚动位置不跳。`/find <text>` 在当前页面对话里搜，F3 / Shift+F3 下一条/上一条。剪贴板贴图会压成 JPEG 随 `/api/chat` 发出，模型有 vision 才进消息；无 vision 会提示并丢图。图落 `~/.piz/artifacts/img-*`，续会话回放缩略图（`/api/image`）。长会话转录超过 200 轮会从顶上裁掉，可用「更早」拉回。点开带 `[Artifact stored: …]` 的卡片会再取 artifact。不要再搞第二份砍过的历史副本。

## HTTP 端点

### GET

| 路径 | 返回 |
|------|------|
| `/`、`/index.html` | 单页 HTML（编译期嵌入） |
| `/api/state` | 指定会话的状态与最近 80 条历史（带 `hist_start`/`hist_total`） |
| `/api/history` | 按 `offset`/`limit` 取更早的消息（默认 80，上限 200） |
| `/api/sessions` | 工作区内的会话列表（名字 + 消息数） |
| `/api/models` | 可用模型列表 |
| `/api/config` | 当前配置 |
| `/api/workspaces` | 已注册工作区列表 |
| `/api/files?q=` | 当前工作区目录列举（composer `@./` 补全；不跟 symlink、不越界；默认藏 gitignored / 跳过目录） |
| `/api/artifact?name=` | 读 `~/.piz/artifacts/` 下的大段工具输出（仅 basename） |
| `/api/plugins` | Web 插件清单 |
| `/api/plugins/assets/<id>/<path>` | 插件静态资源 |
| `/api/events` | SSE 事件流 |

### POST

| 路径 | 作用 |
|------|------|
| `/api/chat` | 发消息（入队，返回是否接受） |
| `/api/interrupt` | 中断当前轮 |
| `/api/approve` | 权限决策 |
| `/api/mode` | 读写授权档。body `{mode:"yolo"|"ask"|"read-only"}`，仍认旧的 `{auto:true}` |
| `/api/config` | 可读 `sandboxMode` / `sandboxBackend`（`bwrap`\|`landlock`\|`none`）；POST `{setSandboxMode:"workspace"}` 写回 settings；POST `{refreshModels:true}` 拉 `/models` |
| `/api/usage` | token 账本。`{lines,in,out,usd,tail}`，tail 最近 8 行；`usd` 按 `pricing.zig` 累加 |
| `/api/packages` | 已装资源包。`{user,project}`，每项 `{name,skills,prompts,agents,web}`。设置页智能体栏也列。 |
| `/api/help` | 斜杠 + 快捷键 + 当前会话插件斜杠，与 TUI `/help` 同源（`cmd_help.zig`）。`/plugins on|off` 后页面会重拉此表。 |
| `POST /api/slash` | 分发插件斜杠。`{name,args}` → `{ok,text}` |
| `/api/activity` | GET 在跑活动（含 `pid`）。POST `{kill:pid}` 只杀表内进程 |
| `/api/model` | 读写当前模型 |
| `/api/title` | 读写会话标题（写入裁到 256 字节，见 [Sessions](sessions.md)） |
| `/api/action` | 会话动作：`fork` / `undo` / `compact` / `shake` / `snap` / `archive` / `restore` / `delete` |
| `/api/config` | 写配置 |
| `/api/workspaces` | 注册工作区 |

### SSE 事件流

`GET /api/events` 返回 `text/event-stream`，30 秒心跳。前端用 `fetch` + `ReadableStream` 手工解析（`EventSource` 不支持自定义 header，带不了 Bearer token）。

## 安全边界

明确一下这个服务保护了什么、没保护什么。

**保护了：**

- 绑定 `127.0.0.1`，硬编码，非 loopback 地址无法访问
- 默认要求 Bearer token（随机生成，生成失败拒绝启动而非降级放行），未授权端点返回 401
- 跨源写请求校验 `Origin`，恶意源返回 403 —— `--no-token` 下同样生效
- `?ws=` 必须指向已注册项目，hook 未接线时拒绝一切非空 ws（fail-closed）
- 不返回 CORS 头，所以跨域请求即使被处理，浏览器也读不到响应
- Web 插件资源路径做了穿越校验（拒绝 `..`、编码路径、非 `web/` 前缀），且不跟随符号链接
- 插件资源响应带 `X-Content-Type-Options: nosniff`
- 连接数和 SSE 流数有上限，见上面的资源上限表

**没保护：**

- **没有 CSRF token。** 防线是 Origin 校验加 token，不是 per-request token。
- **token 比较不是常量时间的。** 本机场景下 timing 侧信道不现实，但值得知道。
- **Web 插件是同源无沙箱 JS**，拥有与页面相同的全部权限。只装可信的包。
- **agent 本身没有沙箱。** 工具以 piz 进程的权限直接读写文件、执行命令，绝对路径和
  `../` 都不拦（CLI 模式亦然）。需要隔离就套容器。
- **已注册项目可以是任意目录**，包括 `/`。注册只校验目录存在 —— 拦不住也不该拦，
  用户本人就要注册目录。浏览器发起的注册被 Origin 校验挡在门外（实测 403），
  剩下的路径是绕过浏览器的本机进程：拿到 token 的程序，或 `--no-token` 下任何
  本机程序。这类注册会在终端打一行 `已注册项目 <路径>`，agent 的工作目录被换掉
  这件事不会无声无息。
- **没有请求头读超时**，所以慢速连接能占住槽位直到对端断开或 TCP keepalive 超时。
  连接数上限挡住了线程耗尽，但 64 个慢连接确实能让服务不可用一段时间。原因和
  权衡见上面的资源上限一节。

如果要暴露到非 loopback 地址（比如通过 SSH 端口转发之外的方式），当前实现**不够** ——
Origin 校验挡的是浏览器发起的跨源请求，挡不住直接构造的 HTTP 请求。

## 前端架构

源在 `src/webui/*.ts`,构建产单文件 `src/webui.js`(编译期 `@embedFile`,运行时零依赖)。

| 件 | 职 |
| --- | --- |
| `state.ts` | URL 参数(session/ws)、prefs 本地偏好、sessUrl |
| `util.ts` | 纯工具:DOM/转义/格式化、工具分类与图标、斜杠打分 |
| `md.ts` | 极简 markdown / ansi / diff / todo 渲染(字符串→HTML) |
| `render.ts` | 设置面板 HTML 构造器(seg/auth/资源包/插件行) |
| `net.ts` | 服务器凭证、fetch 全局包装(Bearer/401)、登录页;`setOnAuthed` 迟绑 boot 解循环 |
| `ui.ts` | toast、对话框(openDlg/askText/askYes/dlgCancel)、seg/auth 绑定、外观方案(setScheme/applyScheme);`dlgHooks` 迟绑收菜单钩 |
| `store.ts` | composer 草稿与历史(localStorage,按会话分键) |
| `sessions.ts` | 菜单助手/项目/会话列/act;`sessHooks` 注入 mode 应用,`sessData` 活引用外供 |
| `stream.ts` | SSE(fetch+ReadableStream、断线横幅、退避重连);`ev.onmessage` 由 composer 指派 |
| `slash.ts` | 斜杠目录/菜单/bang/@文件/runSlash 全分发;`slashH` 钩袋(模型态已直引 model.ts) |
| `chat.ts` | 线程渲染核心:滚动贴底、搜索、历史重放、消息流、work/Flow 卡、工具卡/inspect、审批;`chatH` 钩袋(仅余发送/lastUser) |
| `jobs.ts` | 会话头后台活动钮+badge+弹层(借 dsh ui-jobs 之形);数据走 composer 轮询的 refreshJobs,无自轮询 |
| `composer.ts` | 发送生命周期:运行态/队列/活动条、ev.onmessage 路由、键盘簇、图片、sendPlain/send |
| `model.ts` | 模型/思考档/授权/沙箱/cost/ctx/turnMeta/头部渲染/kebab;`modelH.runSlash` 一钩(环禁) |
| `settings.ts` | openSettings/openSearch/全局键;setBtn 自 wired(避 sheet↔settings 环) |
| `sheet.ts` | 移动 sheet/侧栏折叠/顶栏钮/hideWelcome |
| `plugins.ts` | 插件 SDK v1:总线/pluginApi/loadPlugins/window.piz;`pluginsH` 注 getRunning/sendPlain(避环) |
| `main.ts` | 余:boot 门(splash/探活/auth)、welcome 英雄位、三家钩袋总成(~150 行) |

## 构建

```sh
zig build web            # = piz build-web src/webui src/webui.js
piz build-web            # 同上手写
```

管线(`src/build_web.zig`):自 `main.ts` 顺相对 import DFS 拓扑排 → 逐件过 sucrase(typescript+imports 双变换,与 JS 扩展同款引擎)→ 迷你 require 运行头拼合。循环 import 报错;只认同目 `./x` 相对径。

## 规矩

- **改前端改 `src/webui/*.ts`,勿手改 `src/webui.js`**(头部有 generated 标记);改毕 `zig build web` 重产并一并提交。
- 模块间只许 `import { x } from "./y"`,禁动态 `import()`;新增模块无需注册,被 import 即入伙。
- 迁出纪律:函数搬进模块须**纯**(无 main 闭包态);名不改,调用点不动。有闭包纠缠者(agentHtml/toolBody 之 Flow)留 main;互倚成环者(登录续 boot、对话框收菜单、会话行应 mode、slash 触聊天/模型)以迟绑钩注入,勿回环 import。
- **嵌件陷阱**:`webui.js` 经 `@embedFile` 入 zig 二进制——改 TS 后须全量 `zig build` 重嵌,仅 `zig build web` 不起伺服新码(冒烟先构二进制,勿以旧品验新码)。

## 余缝

尽徙矣。main 唯余 boot 与钩袋总成(~150 行)。铁律:build-web 以 DFS 拓扑排模块,**循环 import 即拒**(piz build-web 静默退出,唯 zig build web 见败);跨界调用先思方向,逆向者以钩袋迟取(modelH.runSlash、pluginsH.{getRunning,sendPlain} 即此遗痕)。chatH/slashH 尚余数钩(sendPlain/getLastUser 等),皆 composer↔chat↔slash 环之逆边,留之。
