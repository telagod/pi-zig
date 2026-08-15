# piz TUI 对齐 pi 设计稿

状态：**已实施**（Theme 三级探测 + dark/light/auto + `~/.piz/themes/*.json` / user 带 / tool 状态带 + 折叠尾行 / footer pi 式双行 + branch + 累计 stats `↑in ↓out R W CH% $cost[(sub)]` / assistant+user Markdown，窄端 <50 列退化单行挤排）。

目标：**语义对齐 pi 交互模式，美感与层级过之。**
依据：pi `dist/modes/interactive/`（user-message.js、tool-execution.js、footer.js、theme/dark.json）与官方截图实证。

## 0. 总纲

- pi 之长：**背景色带分语义**——user 整宽带、tool 盒随状态变色、footer 双行左右分列。
- piz 之长：**缩进层级**——user 0 / assistant 2 / tool 4 / body 6，pi 全平无层级。
- 新制：pi 之色 + piz 之层。色带随缩进起讫，不满屏铺，层级与语义兼得。
- 现状缺口：piz 只用 8 色粗/暗/斜，**无背景色、无 256 色、无状态色**。

## 1. 逐元素对照

| 元素 | pi | piz 现状 | 新制 |
|---|---|---|---|
| user 消息 | 整宽 bg 带 `#343541`，Markdown | 缩进 0，粗体，`▎` 条，无 bg | **缩进 0，`▎` 条保留，条右整行铺 bg 带**（宽至屏缘），粗体 |
| tool 块 | 整盒 bg 随状态：pending `#282832` / ok `#283228` / err `#3c2828`；折叠末行 `... (N more lines, ctrl+o to expand)` | 缩进 4 `▸` 一行，dim 预览 + 状态字，无 bg | **title 行右缘铺状态 bg**（pending 深灰 / ok 暗绿 / err 暗红），`●` 点改状态 fg；折叠体加 pi 式尾行 `· (N more, ctrl+o)` |
| thinking | dim italic `thinkingText` | 缩进 2 dim italic | 已对，不动 |
| assistant | 正体 pad 1 | 缩进 2 正体 | 不动（层级已胜） |
| footer | 两行：行 1 `~/cwd (branch)`；行 2 左 `↑4.7k ↓44 R3.8k $0.009 1.7%/272k`，右 `(provider) model · think`；ctx% 高则 warning/error | 单行挤排 model+think+ctx+cache+cwd·session+hint，溢出拆两行 | **改 pi 式双行**（见 §3.5，与未提交之坍缩改动有取舍，候批） |
| git branch | footer 行 1 `(main)` | 无 | 新增：启动读 `.git/HEAD`，footer 行 1 缀之 |
| header | 启动列键位单 + [Context]/[Skills] 等节 | 无开场卡（c1792d0 已去） | 不复活开场卡；`/status` 卡照旧 |
| composer | 全宽，上下横线 | boxed 框 | 不动（框已美于横线） |
| picker | SelectList + DynamicBorder | 内嵌排序 picker | 不动 |

## 2. 主题色表

新增 `Theme` 结构。探测序：`COLORTERM=truecolor` → 24 位色；否则 256 色；`NO_COLOR` → 全素（现状行为）。色值取 pi dark.json，256 取最近似：

| 语义 | truecolor (dark) | 256 | 用途 |
|---|---|---|---|
| userMessageBg | `#343541` | 236 | user 行 bg |
| toolPendingBg | `#282832` | 235 | tool running bg |
| toolSuccessBg | `#283228` | 22 | tool ok bg |
| toolErrorBg | `#3c2828` | 52 | tool err bg |
| statusOkFg | `#b5bd68` | 107 | `●` ok |
| statusErrFg | `#cc6666` | 167 | `●` err |
| warning | `#ffff00`→ 柔化 `#d7af00` | 178 | ctx% ≥ 60% |
| error | `#cc6666` | 167 | ctx% ≥ 85% |
| accent | `#8abeb7` | 109 | 选中、picker |
| muted | `#808080` | 244 | 次级文 |
| dim | `#666666` | 242 | hint、预览 |

dark / light / auto 已上。think 等级色（绿/青/紫）现状已对，不动。

## 3. ANSI mockup

```
▎ 帮我看下这个 bug                                    ← bg 236 铺至屏缘,粗体

  某去查日志。                                        ← 缩进 2 正体,无带

    ▸ read  src/main.zig ●                            ← bg 22(ok) 铺至屏缘,● 绿
    · (34 more lines, ctrl+o)                         ← dim,折叠尾行(pi 式)

    ▸ bash  grep -r foo ●                             ← bg 52(err) 带,● 红
    │ grep: foo: No such file                         ← 展开体照旧,缩进 6

  · thought                                           ← dim italic,不动

┌ composer 框 ┐
~/project/pi-zig (main)                               ← footer 行 1:muted
↑4.7k ↓44 R3.8k $0.009 1.7%/272k  (openai) model · med ← 行 2:左 stats 右模型
```

色带只铺文字所在行之右缘补白，不起新行、不动间距（gapBetween 照旧）。

## 4. 函数级改动清单

1. **新增 `Theme`**（tui.zig 顶部）：`initFromEnv()` 探测 truecolor/256/NO_COLOR；`bgUser() / bgTool(status) / fgStatus(status) / fgCtx(pct)` 返回 ANSI 串。全局 `var theme: Theme`。
2. **`emitUser`**：每行 `prefix + text + 补白至 width`，整行裹 `theme.bgUser()`；`userRowCount` 不变。
3. **`emitTool`**：title 行裹 `theme.bgTool(status)` + 补白；`●` 用 `fgStatus`；`toolTitle` 状态字着色。折叠且 body 非空时加尾行 `· (N more lines, ctrl+o)`（`countContentLines` 已有）。
4. **footer 改 pi 式双行**（**与未提交之单行坍缩冲突，取舍候客批**）：
   - `formatFooterRows` 重写：行 1 = `cwd (branch)`；行 2 = `layoutFooter(stats, "(provider) model · think")`（`layoutFooter` 已存在）。
   - stats 串：`↑in ↓out Rcache $cost ctx%/win`，ctx% 经 `fgCtx` 变色。
   - `FooterIdent` 加 `branch: ?[]const u8`；`main.zig` 启动读 `.git/HEAD` 填之。
   - 窄端（<60 列）退化为现状单行挤排。
5. **`renderFrame` 底部**：`footerRows` 调用处随之；`BottomPane` 高度不变（本就两行）。
6. **测试**：`paintCellsForTest` 加用例——user 行含 bg 码、tool 状态色、footer 双行；`stripForTest` 已能剥 ANSI，旧断言多不受影响。

## 5. 不做之事

- 不复活开场卡、不动 composer 框、不动 slash picker 交互骨架。
- Markdown 不做完整 CommonMark / 语法高亮（块级+常用行内已上）。

## 6. 验证

`zig fmt src/tui.zig && zig build && zig build test`；`zig-out/bin/piz` 起交互目视三块色带与 footer。
