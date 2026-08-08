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
| 权限审批 | 工具调用在界面里点允许/拒绝，或切自动模式 |
| 中断 | 生成中随时打断 |
| 会话管理 | 列表、切换、fork、undo、compact、归档、恢复、删除 |
| 模型切换 | 界面内切，per-session 生效 |
| 多项目 | 注册多个工作区，各自独立会话池 |
| 前端插件 | 注入自定义 JS/CSS，见 [Web plugins](web-plugins.md) |

会话池上限 4 个并发会话，每个会话独立的 Agent 实例、arena 与工作线程。

## 多项目与多会话

启动时当前目录自动注册为第一个工作区。界面里可以再添加别的项目路径，每个工作区有自己的会话列表。

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
| `/api/mode` | 读写审批模式（自动 / 逐次询问） |
| `/api/model` | 读写当前模型 |
| `/api/title` | 读写会话标题（写入裁到 256 字节，见 [Sessions](sessions.md)） |
| `/api/action` | 会话动作：`fork` / `undo` / `compact` / `archive` / `restore` / `delete` |
| `/api/config` | 写配置 |
| `/api/workspaces` | 注册工作区 |

### SSE 事件流

`GET /api/events` 返回 `text/event-stream`，30 秒心跳。前端用 `fetch` + `ReadableStream` 手工解析（`EventSource` 不支持自定义 header，带不了 Bearer token）。

## 安全边界

明确一下这个服务保护了什么、没保护什么。

**保护了：**

- 绑定 `127.0.0.1`，硬编码，非 loopback 地址无法访问
- 默认要求 Bearer token，未授权端点返回 401
- 不返回 CORS 头，所以跨域请求即使被处理，浏览器也读不到响应
- Web 插件资源路径做了穿越校验（拒绝 `..`、编码路径、非 `web/` 前缀）
- 插件资源响应带 `X-Content-Type-Options: nosniff`

**没保护：**

- **无 CSRF token，无 Origin/Referer 校验。** 开启 token 时，攻击者拿不到 token 所以发不出有效请求；但 `--no-token` 时本机任意页面都能驱动 agent。
- **token 比较不是常量时间的。** 本机场景下 timing 侧信道不现实，但值得知道。
- **Web 插件是同源无沙箱 JS**，拥有与页面相同的全部权限。只装可信的包。
- **agent 本身没有沙箱。** 工具以 piz 进程的权限直接读写文件、执行命令。需要隔离就套容器。

如果要暴露到非 loopback 地址（比如通过 SSH 端口转发之外的方式），当前实现**不够** —— 至少还需要 CSRF 防护和 Origin 白名单。
