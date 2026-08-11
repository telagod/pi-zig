> 只想快点跑起来？设一个 `DEEPSEEK_API_KEY` 或 `ANTHROPIC_API_KEY` 环境变量就够了。

# 配置

piz 用自己的配置目录 `~/.piz`。配置**文件格式**与 pi 兼容（`settings.json` / `auth.json` / `models.json` 可以直接拷过来），但目录不共用。

## 目录

- [配置目录](#配置目录)
- [配置文件](#配置文件)
- [内置 provider](#内置-provider)
- [自定义 provider 与模型](#modelsjson)
- [API key 解析顺序](#api-key-解析顺序)
- [环境变量](#环境变量)
- [模型选择](#模型选择)

## 配置目录

`$PIZ_DIR` 若设置则用它，否则用 `~/.piz`。

> **piz 不与官方 pi 共用配置目录。** 早期版本读 `~/.pi/agent`，但两者的会话 JSONL 格式不兼容 —— 共用 `sessions/` 会让 `/sessions` 列出对方的会话、选中后静默得到空历史。独立目录换来格式自由演进。
>
> 从旧版升级：piz 检测到有 `~/.pi` 但没有 `~/.piz` 时会打印一次迁移提示。`settings.json` / `auth.json` / `models.json` / `AGENTS.md` 格式没变，直接 `cp -r ~/.pi/agent ~/.piz` 即可；会话历史无法迁移。

目录布局：

```
~/.piz/
├── settings.json          # 默认 provider 与模型
├── auth.json              # API key
├── models.json            # 自定义 provider 与模型目录
├── AGENTS.md              # 全局上下文文件
├── SYSTEM.md              # 替换默认系统提示（可选）
├── APPEND_SYSTEM.md       # 追加到系统提示（可选）
├── skills/                # 技能
├── packages/              # 资源包
├── memories/              # 跨会话记忆（自动生成）
├── artifacts/             # 外置的大工具输出（自动生成）
└── sessions/              # 会话文件
```

## 配置文件

### settings.json

```json
{
  "defaultProvider": "anthropic",
  "defaultModel": "claude-sonnet-5",
  "plugins": ["lsp", "todo"]
}
```

| 字段 | 说明 |
|------|------|
| `defaultProvider` | 默认 provider |
| `defaultModel` | 默认模型 |
| `plugins` | 要开启的可选插件名数组，见 [Plugins](plugins.md#开启方式) |

`plugins` 里的未知名字只警告不报错（配置可能是为更新版本写的）；`--plugin` 传的未知名字直接失败。

> pi 的 `settings.json` 支持三十多个字段（主题、压缩参数、重试策略、包管理等）。piz 忽略其余字段，也**不支持项目级 `.piz/settings.json` 覆盖全局** —— pi 有这个机制，piz 没有。

### auth.json

```json
{
  "anthropic": { "key": "sk-ant-..." },
  "deepseek":  { "apiKey": "sk-..." }
}
```

`key` 与 `apiKey` 两种字段名都认。

> **值必须是明文字符串。** pi 支持 `!command` 执行取值和 `$ENV` 插值（可以接 1Password 之类的密钥管理器），piz 不支持。

> **安全提示：** 文件明文存 key，piz 不会主动收紧文件权限。建议自己 `chmod 600 ~/.piz/auth.json`。

### models.json

声明自定义 provider 与其模型目录：

```json
{
  "providers": {
    "myrouter": {
      "api": "openai-completions",
      "baseUrl": "https://router.example.com/v1",
      "apiKey": "sk-...",
      "contextWindow": 200000,
      "models": ["gpt-5.6-sol", "claude-opus-5"]
    }
  }
}
```

| 字段 | 说明 |
|------|------|
| `api` | `openai-completions` 或 `anthropic-messages` |
| `baseUrl` | API 基址 |
| `apiKey` | 可选，也可走 auth.json 或环境变量 |
| `contextWindow` | 上下文窗口 token 数，缺省 131072（128K） |
| `models` | 该 provider 下的模型名列表 |

Claude 兼容（`anthropic-messages`）的第三方端点同理，只是 `api` 换一个值：

```json
{
  "providers": {
    "volcark": {
      "api": "anthropic-messages",
      "baseUrl": "https://ark.cn-beijing.volces.com/api/plan",
      "apiKey": "ark-...",
      "contextWindow": 1000000,
      "models": ["deepseek-v4-flash"]
    }
  }
}
```

`baseUrl` 写到 provider 文档给的那一层，piz 按协议补齐路径（`src/config.zig` 的 `endpointUrl`）：

| baseUrl 结尾 | anthropic-messages | openai-completions |
|-------------|-------------------|-------------------|
| `v1` | `+/messages` | `+/chat/completions` |
| `/v1/` | `+messages` | `+chat/completions` |
| `chat/completions` | — | 原样使用 |
| 其他 | `+/v1/messages` | `+/v1/chat/completions` |

所以 `https://ark.cn-beijing.volces.com/api/plan` 走「其他」这行，实际请求
`.../api/plan/v1/messages`。**别加尾部斜杠** —— 只有正好以 `/v1/` 结尾时才特殊处理，
其他路径带斜杠会拼出双斜杠。

## 内置 provider

| provider | 协议 | baseUrl | 内置模型列表 |
|----------|------|---------|-------------|
| `deepseek` | openai-completions | `https://api.deepseek.com` | `deepseek-v4-flash`、`deepseek-v4-pro` |
| `openai` | openai-completions | `https://api.openai.com/v1` | 无（需在 models.json 声明） |
| `anthropic` | anthropic-messages | `https://api.anthropic.com` | 无（需在 models.json 声明） |

只支持这两种协议形态。pi 支持三十多个 provider（Bedrock、Azure、Vertex、Gemini 原生 API、llama.cpp 等），piz 没有对应实现 —— 但只要目标服务提供 OpenAI 兼容端点，用 `models.json` 声明 `baseUrl` 就能接。

**没有 OAuth 登录**。pi 的 `/login` 可以蹭 Claude Pro / ChatGPT Plus 订阅额度，piz 只支持 API key。唯一的例外是会尝试从 `~/.codex/config.toml` 读 `experimental_bearer_token`（当 auth.json 为空时的兜底）。

## API key 解析顺序

单个 provider 的 key 按此顺序取，先命中者胜：

1. `models.json` 里该 provider 的 `apiKey`
2. `auth.json` 里该 provider 的 `key` / `apiKey`
3. 环境变量 `<PROVIDER>_API_KEY`

环境变量名由 provider 名生成：去掉连字符、转大写、加 `_API_KEY`。

```
anthropic     → ANTHROPIC_API_KEY
deepseek      → DEEPSEEK_API_KEY
my-router     → MYROUTER_API_KEY
```

> 这个算法与 pi 的固定变量名表不完全一致。例如 pi 用 `AZURE_OPENAI_API_KEY`，而 piz 对名为 `azure-openai` 的 provider 会去找 `AZUREOPENAI_API_KEY`。名字对不上时直接在 `models.json` 里写 `apiKey`。

## 环境变量

| 变量 | 作用 |
|------|------|
| `PIZ_DIR` | 覆盖配置目录 |
| `PIZ_PROVIDER` | 覆盖默认 provider，**优先级最高** |
| `PIZ_MODEL` | 覆盖默认模型，**优先级最高** |
| `<PROVIDER>_API_KEY` | 该 provider 的 key |
| `PIZ_WEB_SEARCH_URL` | SearXNG 端点，供 `web_search` 工具用 |

`PIZ_PROVIDER` / `PIZ_MODEL` 是 piz 自己的变量，与 pi 无关。

> **不支持代理。** `HTTP_PROXY` / `HTTPS_PROXY` 不生效 —— Zig 标准库的 http 客户端不读这些变量，piz 也没有额外实现。

> **bash 工具不注入会话元数据。** pi 会给 bash 子进程注入 `PI_SESSION_ID` / `PI_PROVIDER` / `PI_MODEL` 等，piz 不注入。模型想知道当前用什么模型，得靠系统提示或 `get_context_remaining` 工具。

## 模型选择

优先级从低到高：

1. `settings.json` 的 `defaultProvider` / `defaultModel`
2. `PIZ_PROVIDER` / `PIZ_MODEL` 环境变量
3. `--provider` / `-m` 命令行参数
4. 交互模式里的 `/model <name>`

给了模型名但没给 provider 时，piz 会遍历所有 provider 的 `models` 列表找匹配。`models` 为空的 provider（如内置的 `openai`）允许用 provider 名当模型名。

查看当前可用模型：

```bash
piz --models
```

只列出已配置 key 的 provider 下的模型。

### 上下文窗口与压缩

`contextWindow` 决定何时触发压缩：总 token 超过窗口的 **85%** 时压缩，压缩后保留最近 **20%** 窗口预算的消息。

压缩前会先由 `tool-output-pruner` 插件尝试裁剪早期工具输出 —— 裁剪不用调模型，比压缩便宜。详见 [Plugins](plugins.md#tool-output-pruner)。

token 数是**估算**的（不请求 provider 的 tokenizer）：按 UTF-8 序列长度分档 —— ASCII 4 字节/token，CJK 1 字符/token。早先按「4 字节 = 1 token」一刀切，对中文低估约 23%，会让压缩迟迟不触发直到请求被 provider 以超窗拒绝。估算宁可略高：高了只是早压缩一点，低了会把请求打过去被拒。

估算范围是一次请求真正发出去的全部内容：系统提示 + 全部消息 + **工具定义**。工具定义每轮全量重发，默认 9 个工具约 1065 token，开插件更多 —— 所以常规会话即使历史为空也已占掉约 1122 token。只读模式（`-r`）不发工具，空会话是 87 token。

### prompt caching

自动生效，无需配置。piz 每轮都要重发系统提示与工具定义（实测约 3217 token），缓存能把这部分的成本降到约 1/10。

- **Anthropic**：请求里带 `cache_control` 断点。首轮写入缓存，之后命中。注意最小可缓存长度按模型是 512–4096 token，低于阈值**静默不缓存**——所以要看状态栏的实际命中率，不能假定配了就有效。
- **OpenAI / DeepSeek / GLM / Kimi**：服务端全自动前缀匹配。piz 额外发一个 `prompt_cache_key`（值 = 工作目录），让同目录的请求路由到同一台机器以提高命中率。这个字段是可选的，不认它的 provider 会静默忽略（DeepSeek 实测如此）。

状态栏的 `cache N%` 是本轮命中率，`cache warm` 表示这轮刚写入缓存、下一轮才开始省。`-o json` 输出里有 `cache_read` 与 `cache_write` 两个字段（写入按 1.25 倍基础价计费、读取按 0.1 倍，分开看才知道这轮是省了还是多花了）。

压缩会重写历史开头，作废 `messages` 段的缓存 —— 但 tools 与系统提示排在请求里 `messages` 之前，那部分（每轮固定约 3217 token）照旧命中。这是有意的取舍：压缩防的是超窗硬失败，缓存只是省钱。设计取舍与 codex 的对照见 [Architecture](architecture.md#prompt-caching)。

### 请求重试

HTTP 请求失败会自动重试，缺省最多 3 次，指数退避（500ms / 1s / 2s，带抖动）。

| 情况 | 是否重试 |
|------|---------|
| 429、500、502、503、504 | 是 |
| 连接被拒 / 重置 / DNS 瞬时失败 | 是 |
| 400、401、403、404 等 4xx | 否（重试不会变好） |
| 流式已开始后失败 | 否（会导致重复输出） |

尊重响应的 `Retry-After` 头，但封顶 30 秒。退避等待期间可以用 `Ctrl+C` 中断。
