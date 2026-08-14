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
| 工具卡片 | 可折叠，按工具类型分类渲染（终端输出走 ANSI 着色，`write`/`edit` 走 diff 着色） |
| Diff 高亮 | 增行绿、删行红、hunk 头强调 |
| 权限审批 | 默认全权。输入框旁 `yolo` 打开三档：yolo / ask / read-only。询问档下工具卡点允许/拒绝 |
| 中断 | 生成中随时打断 |
| 会话管理 | 列表、切换、fork、undo、compact、归档、恢复、删除 |
| 会话搜索 | `Ctrl/⌘K` Spotlight，按标题与名字过滤 |
| 斜杠命令 | 输入 `/` 弹出菜单：help/new/undo/compact/shake/snap/fork/title/model/think/status |
| 设置 | 配色（浅/深/系统）、强调色、字号、完成通知与提示音 |
| 上下文环 | 工具栏显示占用百分比，超过 85% 提示压缩 |
| 草稿与历史 | 未发送草稿按会话落 localStorage；↑/↓ 翻输入历史 |
| 模型切换 | 界面内切，per-session 生效 |
| 多项目 | 注册多个工作区，各自独立会话池 |
| 前端插件 | 注入自定义 JS/CSS，见 [Web plugins](web-plugins.md) |

会话池上限 4 个并发会话，每个会话独立的 Agent 实例、arena 与工作线程。

### 资源上限

| 上限 | 值 | 越界行为 |
|------|-----|---------|
| 并发 TCP 连接 | 64 | 立刻关闭，客户端 connect 成功但读到 EOF |
| 并发 SSE 流 | 16 | `503` + `{"error":"too many event streams"}` + `retry-after: 5` |
| 请求头读超时 | 无 | 见下面的说明 |
| 并发会话 | 4 | `/api/chat` 返回 `{"ok":false,"error":"session limit"}` |

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

## HTTP 端点

### GET

| 路径 | 返回 |
|------|------|
| `/`、`/index.html` | 单页 HTML（编译期嵌入） |
| `/api/state` | 指定会话的状态与历史 |
| `/api/sessions` | 工作区内的会话列表（名字 + 消息数） |
| `/api/models` | 可用模型列表 |
| `/api/config` | 当前配置 |
| `/api/workspaces` | 已注册工作区列表 |
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
