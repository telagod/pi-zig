# JS 扩展示例

`hello-tool.js`:pi 式 `export default function (piz)`,示范三件套——
`registerTool`(LLM 工具)、`registerCommand`(斜杠命令)、`on`(事件钩)。

## 安装

```bash
cp hello-tool.js ~/.piz/extensions/        # 全局
cp hello-tool.js <项目>/.piz/extensions/   # 仅该项目
```

## 验证

```bash
piz --plugins            # 扩展随插件表加载,装载行见 stderr
piz                      # TUI 里键 /hellojs 墨客
piz -p "用 js_repo_fact 说说这个仓库"
```

全 API 面见 [docs/extensions-js.md](../../docs/extensions-js.md)。
