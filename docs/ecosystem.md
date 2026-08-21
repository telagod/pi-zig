# 生态

piz 的三层扩展面与包流转。机制文档各详:[plugins](plugins.md)(编译期)、[extensions-js](extensions-js.md)(QuickJS)、[packages](packages.md)(资源包)、[web-plugins](web-plugins.md)(前端 SDK)。

## 三面一图

| 面 | 载体 | 装载 | 能耐 |
|---|---|---|---|
| 编译期插件 | Zig,`src/plugins/` | 随二进制,`--plugin` 开关 | 工具/钩子/agent 内核,零运行时成本 |
| JS/TS 扩展 | QuickJS,`.js/.mjs/.ts` | `~/.piz/extensions/` + 项目级,启动即装 | `registerTool`/`registerCommand`/事件钩/fs/exec/fetch |
| Web 前端插件 | 包内 `web/` | 随资源包,浏览器侧 | slots/`renderTool`/`renderMessage`/storage |
| 资源包 | 目录 + `pkg.json` | `piz pkg install` | skills/prompts/AGENTS.md/web 插件/工具声明/事件钩子,可打包前三面 |

## 装包

```bash
piz pkg install ./my-pack                              # 本地目录
piz pkg install https://github.com/user/pack.git       # git 仓库(--depth 1)
piz pkg install git:github.com/user/pack               # git: 前缀
piz pkg install name@owner/marketplace-repo            # marketplace 目录取件
piz pkg update                                         # 全部按原 source 重装(git 即重拉)
piz pkg list && piz pkg remove <name>
```

包名以 `pkg.json` 的 `name` 为准(无则目录/仓库 basename)。项目级加 `-l`,同名压用户级。
装含钩子/工具声明的包会列出将跑的 `bash -c` 命令并求确认——装包即授权,先审源。

## 写包

最小一枚(示例在 [examples/skill-pack](../examples/skill-pack)):

```text
my-pack/
├── pkg.json            # {"name":"my-pack","version":"1.0.0"}
├── skills/<名>/SKILL.md # 模型技能,frontmatter 带 name/description
├── prompts/*.md        # prompt 模板
└── web/                # 可选:前端插件(index.js + style.css)
```

JS 扩展散件示例在 [examples/extensions](../examples/extensions);前端插件示例在 [examples/web-plugin](../examples/web-plugin)。

## 兼容

- **pi 扩展**:零依赖纯 JS 者移入 `.piz/extensions/` 多可直跑;`import` 仅认相对路径,裸包名/远程 URL 不受理——npm 包需先自 bundle 成单文件。
- **claude marketplace**:`name@repo` 形式可读 `.claude-plugin/marketplace.json` 之 catalog 取件。

## 分发

发布即推 Git 仓库——`piz pkg install <url>` 即装,无需 registry。欲广而告之:仓库 README 写清 `piz pkg install` 一行,packages.md 之规约照守即可。
