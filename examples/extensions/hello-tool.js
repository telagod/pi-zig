// hello-tool.js —— piz JS 扩展示例:一个 LLM 工具 + 一个斜杠命令 + 一个事件钩。
// 安装:cp hello-tool.js ~/.piz/extensions/(项目级则 <项目>/.piz/extensions/)
// 验证:piz --plugins 见扩展加载;TUI 键 /hellojs;或让模型调 js_repo_fact。
// 文档:docs/extensions-js.md(全 API 面)。

export default function (piz) {
  // 1) LLM 工具:模型可调用,走与内置工具同一 permissions 闸。
  piz.registerTool({
    name: "js_repo_fact",
    description: "返回当前仓库的一条事实(分支名与提交数)",
    schema: { type: "object", properties: {} },
    execute: () => {
      const branch = (piz.exec(["git", "branch", "--show-current"]) || "?").trim();
      const count = (piz.exec(["git", "rev-list", "--count", "HEAD"]) || "0").trim();
      return { content: `分支 ${branch},共 ${count} 次提交` };
    },
  });

  // 2) 斜杠命令:/hellojs <名字>,进 TUI 补全与 web 命令目录。
  piz.registerCommand("hellojs", {
    description: "问候(扩展示例)",
    handler: (args) => `你好,${args.trim() || "客官"}!此令出自 hello-tool.js`,
  });

  // 3) 事件钩:工具败则记一行到 stderr(生产扩展可据此告警/统计)。
  piz.on("tool_result", (e) => {
    if (e && e.is_error) piz.notify(`工具 ${e.name} 失手`, "info");
  });

  piz.notify("hello-tool.js 已装载", "info");
}
