# webui 前端(TS 模块化)

## 结构

源在 `src/webui/*.ts`,构建产单文件 `src/webui.js`(`webui.zig` `@embedFile` 不变,运行时零依赖)。

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

## 候拆缝(模块地图)

`main.ts` 之候拆缝已尽徙(见上「余缝」)。此节留纪旧图:api(裸 fetch 由 net.ts 收口)、stream、chat、composer、sessions 五族皆已出,逐一以 build-web + 全量测试 + playwright 交互烟验过。
