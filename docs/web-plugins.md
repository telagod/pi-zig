> 让 piz 写插件：告诉它读这篇，然后描述你要的界面能力。

# Web 前端插件

给 [Web UI](web-ui.md) 注入自定义 JS 与 CSS。插件随 [资源包](packages.md) 安装，不需要改 `src/webui.zig`，也不需要重编译 piz。

用户级包在 `~/.piz/packages/<id>/`，项目级包在 `<project>/.piz/packages/<id>/`；同名时项目级优先。

## 目录

- [最小结构](#最小结构)
- [入口](#入口)
- [API](#api)
- [完整示例](#完整示例)

## 最小结构

```text
my-plugin/
├── pkg.json
└── web/
    ├── index.js
    └── style.css       # 可选
```

```json
{
  "name": "My Plugin",
  "version": "1.0.0",
  "web": {
    "entry": "web/index.js",
    "style": "web/style.css"
  }
}
```

`entry` 必须是 `web/` 内的 `.js`/`.mjs`；`style` 必须是 `web/` 内的 `.css`。服务端拒绝绝对路径、编码路径与 `..`。

> **安全：** 插件是同源 JS，拥有与页面完全相同的权限 —— 能读你的会话内容、调 `/api/` 全部端点、通过 `api.send()` 驱动 agent 执行工具。**没有沙箱。** 只装读过源码或信任来源的包。

安装并运行：

```sh
piz pkg install ./my-plugin -l   # 当前项目
piz web
```

安装后刷新页面即可。`piz pkg list` 会标记 `web:yes`。

## 入口

```js
export async function activate(api) {
  // 初始化
  return () => {
    // 可选清理；页面卸载时调用
  };
}

// 也可 export default activate
```

`activate` 出错只禁用该插件，不影响主界面。插件逐个动态加载；样式先加载，随后执行入口。

## API

### 基础

- `api.version`：SDK 版本，当前为 `1`
- `api.id` / `api.name`：包 ID / 显示名
- `api.session` / `api.workspace`：当前会话与项目根
- `api.asset("icon.svg")`：解析相对 `web/` 的插件资源 URL
- `api.toast(text)`：使用主界面 toast
- `api.send(text)`：发送真实对话；运行中返回 `false`
- `api.fetch(path, options)`：仅允许同源 `/api/`，自动附加 `ws`

### 事件

```js
const off = api.on("tool_result", event => {});
```

事件名包括主 SSE 类型：`user_message`、`reasoning`、`message`、`tool_call`、`tool_result`、`permission`、`permission_result`、`status`、`turn_end`；`event` 可监听全部事件。另有 `plugin-loaded`、`plugin-error`、`ready`、`message-rendered`。

也可监听 DOM 事件：`window.addEventListener("piz:turn_end", e => e.detail)`。

### UI slots

稳定槽位：`header`、`composer`、`status`。

```js
const button = api.ui.button("header", {
  label: "总结",
  title: "总结当前会话",
  onClick: () => api.send("总结当前会话")
});

const element = document.createElement("span");
element.textContent = "ready";
api.ui.mount("status", element);
```

API 挂载的节点会在插件卸载时自动删除。自定义按钮可复用 `.piz-plugin-btn`。

### 自定义渲染

```js
api.renderTool("my_tool", ({ args, output, error }) => {
  const pre = document.createElement("pre");
  pre.textContent = output;
  return pre;
});

api.renderMessage(({ role, text }) => {
  if (role !== "assistant" || !text.startsWith("CARD:")) return null;
  const card = document.createElement("div");
  card.textContent = text.slice(5);
  return card;
});
```

渲染器必须返回 `Node`；返回 `null` 时走下一渲染器或内置 Markdown。错误会隔离并回退内置渲染。

### 持久化

```js
api.storage.set("enabled", true);
const enabled = api.storage.get("enabled", false);
api.storage.remove("enabled");
```

键按插件 ID 隔离，值使用 JSON 存入浏览器 `localStorage`。

## 完整示例

见 [`examples/web-plugin/`](../examples/web-plugin/)。
