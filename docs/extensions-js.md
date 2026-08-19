# JS 扩展(QuickJS)

piz 内嵌 QuickJS-ng(MIT,vendor/quickjs-ng),运行时加载 JS 扩展,免编译。
由构建选项 `-Dquickjs`(默认开)门控;关掉则无 libc 纯静态(4.85MB ↔ 5.97MB)。

## 位置与加载

- `~/.piz/extensions/*.js`(全局)+ `<项目>/.piz/extensions/*.js`(项目,web 模式不装)
- 字典序加载;单文件 1MB 封顶;加载错误打 stderr,不致命
- classic script,顶层用全局 `piz` 对象;**暂不支持 ESM/TS**(pi 式 default-export 与 TS 剥离后置)

## API(窄桥)

```js
// 事件
piz.on("session_start", (e) => { /* e.cwd */ });
piz.on("tool_call", (e) => {
  // e.toolName, e.inputRaw(参数 JSON 原文)
  if (e.toolName === "bash") return { block: true, reason: "no bash" };
});
piz.on("tool_result", (e) => { /* e.toolName, e.output(截 8KB) */ });

// 注册 LLM 工具(走与内置工具同一 permissions 闸;同步 execute)
piz.registerTool({
  name: "js_echo",
  description: "echo args",
  schema: { type: "object", properties: { text: { type: "string" } } },
  execute: (args) => "echo:" + args.text,   // 返回 string 或 {content}
});

// 注册斜杠命令(/hellojs world),进 TUI 补全与 web /api/help 目录
piz.registerCommand("hellojs", {
  description: "js hello",
  handler: (args) => "hello from js: " + args,
});

// 宿主交互
piz.notify("msg", "info");   // 打印模式 → stderr;TUI 接线后置
piz.confirm("sure?");        // 未接管一律 false(安全默认)
```

## 约束(窄桥期)

- execute/handler 必须**同步**;promise 不支持
- JS 侧一切调用全局互斥序列化(QuickJS 上下文非线程安全;工具回调跑在工作线程上)
- 同名内置/插件工具优先,JS 工具最后兜底
- 对象进出即拷贝;不留跨 GC/arena 引用

## 实现索引

- 胶层:`src/jsrt.zig`(runtime/prelude/注册表/互斥/事件)
- 挂点:agent.zig(runToolSlot 事件+工具路由、lookupTool、appendToolDefs)、
  main.zig(启动加载+session_start+斜杠回退+TUI 补全)、
  cmd_web.zig(启动加载+斜杠回退+目录)、cmd_print.zig(打印模式同桥+notify→stderr)
- 构建:build.zig `-Dquickjs`;静态发布配 `-Dtarget=x86_64-linux-musl`

## 已知雷(实测)

- `JS_Eval` 词法器会瞥 `input[len]`:必须传 NUL 结尾缓冲(dupeZ),否则按相邻
  堆字节随机报 SyntaxError(jsrt.zig evalFile 有详注)。
