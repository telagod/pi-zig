> 想回到上一次的对话？直接 `piz`，它默认续载本目录最近的会话。

# 会话

会话是 JSONL 文件，一行一条消息，追加写入。同一目录下的会话按修改时间排序，最新在前。

## 目录

- [存储位置](#存储位置)
- [文件格式](#文件格式)
- [会话操作](#会话操作)
- [分支](#分支)
- [压缩](#压缩)
- [会话格式与 pi 的差异](#会话格式与-pi-的差异)

## 存储位置

CLI 会话按工作目录分桶：

```
<配置目录>/sessions/<cwd-slug>/<时间戳>.jsonl
```

`cwd-slug` 是工作目录路径把 `/` 换成 `-` 并前后加 `--`：

```
/home/you/code/api  →  --home-you-code-api--
```

这个 slug 规则与 pi 一致，所以两者的会话文件落在同一个目录里（但内容格式不同，见下文）。

Web UI 会话是另一套布局：

```
<配置目录>/sessions/web/<cwd-slug>/<会话名>.jsonl
<配置目录>/sessions/web/<cwd-slug>/archive/<会话名>.jsonl   # 归档
```

Web 会话用人类可读的名字（默认 `default`），CLI 会话用时间戳。两者互不干扰。

## 文件格式

首行是元信息：

```json
{"cwd":"/home/you/code/api","started":1786188766,"title":"重构 auth"}
```

| 字段 | 说明 |
|------|------|
| `cwd` | 工作目录绝对路径，必需 |
| `started` | 创建时间，Unix 秒 |
| `title` | 会话标题，可选。写入时裁到 **256 字节**（按 UTF-8 边界，不会切出半个汉字）——标题只用于会话列表的一行显示，更长的部分没有用途却会一路带进内存和每个 API 响应 |

后续每行一条消息：

```json
{"role":"user","content":"跑一下测试","id":"19fe1259c35-1"}
{"role":"assistant","content":"","id":"19fe1259c35-2","parent_id":"19fe1259c35-1","tool_calls":[{"id":"c1","name":"bash","args":"{\"command\":\"zig build test\"}"}]}
{"role":"tool","content":"All 63 tests passed.","id":"19fe1259c35-3","parent_id":"19fe1259c35-2","tool_call_id":"c1"}
```

| 字段 | 说明 |
|------|------|
| `role` | `user` \| `assistant` \| `tool` |
| `content` | 文本内容，**始终是字符串**（不是内容块数组） |
| `id` | 消息 id，格式 `<毫秒时间戳16进制>-<序号>` |
| `parent_id` | 父消息 id，构成链式结构；首条消息无此字段 |
| `tool_call_id` | `role: tool` 时，对应的工具调用 id |
| `tool_calls` | `role: assistant` 时，发出的工具调用数组 |

Web 会话的首行元信息略有不同，含 `model` 与 `auto`（审批模式）。

## 会话操作

### 命令行

```bash
piz              # 续载本目录最近会话（默认）
piz -c           # 同上，显式
piz -n           # 新会话
piz -t "标题"     # 新会话并设标题
piz -s <id>      # 恢复指定会话（id = 文件名去掉 .jsonl）
```

### 交互模式

| 命令 | 作用 |
|------|------|
| `/sessions` | 列出本目录全部会话，带编号 |
| `/resume <n>` | 切到第 n 个 |
| `/new` | 开新会话（新时间戳 id，欢迎卡和退出提示都会换成新的） |
| `/clear` | 清空当前并重开 |
| `/title <text>` | 设置标题 |
| `/tree` | 打印消息列表，带编号 |
| `/fork <n>` | 从第 n 条消息分叉 |
| `/undo` | 撤销最近一轮 |
| `/export` | 导出为 HTML |

> `/resume` 只接受数字编号，没有搜索和交互式选择器。pi 有一个带模糊搜索、重命名、删除的会话 picker，piz 是纯文本的两步流程（`/sessions` 看编号 → `/resume <n>`）。

> CLI 会话**没有删除命令**。直接删 `.jsonl` 文件即可。Web UI 有删除与归档。

## 分支

`/fork <n>` 复制前 n 条消息到新会话文件，后续写入接续第 n 条：

```
/tree           # 看编号
  [1] user: 实现 auth
  [2] assistant: ...
  [3] user: 加上 OAuth
  [4] assistant: ...
/fork 2         # 从第 2 条分叉，丢掉 OAuth 那一支
```

这是**线性截断复制**，不是树上任意节点分支。piz 的消息虽然带 `id`/`parent_id`，但存储和加载都按线性数组处理，`/tree` 显示的也是线性列表而非可折叠的树。

pi 有真正的会话树（可视化导航、任意节点跳转续写、分支摘要、标签）。piz 只做到 fork + undo。

## 压缩

上下文总 token 超过窗口 **85%** 时自动压缩：

1. `tool-output-pruner` 先跑快压三件套（prune → 70% shake → 80% snap → 85% shake 救援），不调模型
2. 仍然超限则调模型生成摘要，替换掉早期消息
3. 保留最近 **20%** 窗口预算的消息
4. 摘要通过 `cross-session-memory` 插件落盘，下次同目录启动时注入

切点规则：只在 `user` / `assistant` 消息处切，**绝不切断 tool 结果** —— 工具调用与其结果必须成对，否则 provider 会拒绝请求。

压缩失败（模型不可用）时，若 provider 配了多个模型，`compact-resilience` 插件会换第二个模型重试一次。

手动触发：`/compact`（密图秒压，不调模型）、`/shake`（机械裁，可 `/shake images`）、`/snap`（8x13+CJK 密图 + 原文摘，无 vision 跳过）、`/fast-compress`（看快压状态）。

> 压缩是增量的：只总结上次压缩边界之后的新增内容，不重复总结已压缩部分。

## 会话格式与 pi 的差异

piz 的会话存在 `~/.piz/sessions/`，pi 的存在 `~/.pi/agent/sessions/` —— **目录分开，不会互相干扰**。

早期版本共用同一个 `sessions/<cwd-slug>/` 目录，结果 `/sessions` 会把 pi 的会话文件列出来，选中后静默得到空历史（无报错）。断开目录共用就是为了消掉这个坑。

两者的 JSONL 结构差异：

| 方面 | pi | piz |
|------|-----|-----|
| 行结构 | `{"type":"message","id","parentId","timestamp","message":{...}}` | `{"role","content","id","parent_id"}` |
| 消息包装 | 包在 `message` 字段里 | 直接摊在顶层 |
| `content` | 字符串或内容块数组 | 始终字符串 |
| 父指针字段名 | `parentId` | `parent_id` |
| 条目类型 | 8 种（`model_change`、`compaction`、`branch_summary`、`label`、`session_info` 等） | 只有消息 |
| 版本号 | 首行有 `version`，支持 v1→v3 迁移 | 无版本概念，无迁移 |
| 时间戳 | 每条 ISO 8601 | 只有首行 Unix 秒 |

实测：让 piz 读一个 20 行的 pi 会话文件，只能解析出 1 条消息，其余静默跳过。所以**历史会话无法从 pi 迁移过来**。

配置文件本身是兼容的 —— `settings.json` / `auth.json` / `models.json` / `AGENTS.md` 可以直接拷贝或做符号链接。
