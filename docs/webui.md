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
| `ui.ts` | toast、对话框(openDlg/askText/askYes)、seg/auth 绑定;`dlgHooks` 迟绑收菜单钩 |
| `store.ts` | composer 草稿与历史(localStorage,按会话分键) |
| `main.ts` | 其余全部:聊天流、SSE、composer、会话列表、插件页(尚余 ~4000 行) |

## 构建

```sh
zig build web            # = piz build-web src/webui src/webui.js
piz build-web            # 同上手写
```

管线(`src/build_web.zig`):自 `main.ts` 顺相对 import DFS 拓扑排 → 逐件过 sucrase(typescript+imports 双变换,与 JS 扩展同款引擎)→ 迷你 require 运行头拼合。循环 import 报错;只认同目 `./x` 相对径。

## 规矩

- **改前端改 `src/webui/*.ts`,勿手改 `src/webui.js`**(头部有 generated 标记);改毕 `zig build web` 重产并一并提交。
- 模块间只许 `import { x } from "./y"`,禁动态 `import()`;新增模块无需注册,被 import 即入伙。
- 迁出纪律:函数搬进模块须**纯**(无 main 闭包态);名不改,调用点不动。有闭包纠缠者(agentHtml/toolBody 之 Flow)留 main;互倚成环者(登录续 boot、对话框收菜单)以迟绑钩注入,勿回环 import。

## 候拆缝(模块地图)

`main.ts` 内下一批可剥者:`api.ts`(约 40 处裸 fetch 收口)、`stream.ts`(SSE connect/handleSSELine/sseUp/Down)、`chat.ts`(addUser/addAsst/Flow/cards 渲染族)、`composer.ts`(slash/bang/draft/hist/send)、`sessions.ts`(loadSessions/sessionRow/菜单)。每拆一族,先验纯或以参数解缠,再走 build-web + 全量测试。
