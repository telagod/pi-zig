# JS 扩展(QuickJS)

piz 内嵌 QuickJS-ng(MIT,vendor/quickjs-ng),运行时加载 JS 扩展,免编译。
由构建选项 `-Dquickjs`(默认开)门控;关掉则无 libc 纯静态(4.85MB ↔ 5.97MB)。

## 位置与加载

- `~/.piz/extensions/`(全局)+ `<项目>/.piz/extensions/`(项目,web 模式不装)
- 认 `.js`(classic/ESM)、`.mjs`(ESM)、`.ts/.mts/.cts`(先 sucrase 剥皮)
- 字典序加载;单文件 1MB 封顶;加载错误打 stderr,不致命
- **ESM 支持**:`.mjs/.mts` 或源含 `export default` 即走模块支路,pi 式
  `export default function(pi) { ... }` 会被调用,参数即下述 `piz` 对象;
  顶层 await / promise 微任务由 job 泵跑尽;unhandled rejection 打 stderr
- **import 支持**:`import { x } from "./dep.mjs"` 按相对路径解析(引擎默认
  normalizer + 宿主读盘编译);裸包名/远程 URL 报 cannot load module
- **TS 支持**:sucrase 类型剥离(仅 typescript transform;enum/装饰器这类
  有运行论语义的不在范围内);bundle 内嵌 src/embedded/(复现见同目 BUILD.md),
  首个 .ts 才惰性起,加载错误原样报出

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
piz.notify("msg", "info");   // print → stderr;TUI → transcript 行(TUI 起前暂存一条)
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

- `JS_Eval` 词法器会读 `input[len]`(头注释明写 must be zero terminated):
  必须 NUL 结尾缓冲(dupeZ),否则按相邻堆字节随机报 SyntaxError(jsrt.zig evalFile 有详注)
- `JS_EvalFunction` 对 JS_TAG_MODULE **吃掉**传入引用(内部 FreeValue,
  注释 refcount should be >= 2);模块 JSValue 到手后绝不再 free——模块
  refcount 到 0 直接 `abort()`(js_free_value_rt: never freed here)
