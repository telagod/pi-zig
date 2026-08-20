# JS 扩展(QuickJS)

piz 内嵌 QuickJS-ng(MIT,vendor/quickjs-ng),运行时加载 JS 扩展,免编译。
由构建选项 `-Dquickjs`(默认开)门控;关掉则无 libc 纯静态(4.85MB ↔ 5.97MB)。

## 位置与加载

- **内嵌出厂档** `src/embedded/extensions/`(@embedFile 随二进制,先载);`~/.piz/extensions/`(全局)+ `<项目>/.piz/extensions/`(项目;web 模式装**服务器启动目**那份,引擎单例、全体会话共享,按 workspace 分装后置)
- 覆写语义:用户/项目目放**同名 basename** 即顶替内嵌件(内嵌让位)
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
piz.on("tool_result", (e) => {
  // e.toolName, e.output(全文,不截);返 { replace: "..." } 即改写回写内容
});
piz.on("agent_end", (e) => { /* e.text = 回合最后 assistant 正文(截 8KB,可空);
     e.model/e.cwd/e.config_dir/e.ts;有用量时 e.usage = {in,out,cr,cw,usd},无则 null */ });
piz.on("compact", (e) => { /* e.summary/e.cwd/e.config_dir/e.ts(压缩成功后,fire-and-forget) */ });

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

// 同步 fs/env(文本向,单发 8MB 封顶;相对路径 = 进程 cwd)
piz.readFile("/abs/or/rel");     // 不在/出错 → null
piz.writeFile("/tmp/x", "txt");  // 成 → true
piz.appendFile("/tmp/x", "txt"); // 尾追加,不在则建(0600),父目须已在
piz.env("HOME");                 // 未设 → null
piz.cwd();                       // 进程 cwd 串
piz.configDir();                 // 配置目(~/.piz 或 $PIZ_DIR),未装载 → null
piz.contextStats();              // 调用方 context 快照 {window,used,tools_share,remaining,hard_pct,limit,until_compact};
                                 // 仅工具/命令执行进行中可得,否则 null
piz.listDir(path);               // [{name,kind:dir|file|link|other}];不在/出错 → null
piz.exec(["git","status"]);      // stdout 串(截 64KB,stderr 弃,无 shell);spawn 败或 exit≠0 → null
                                 // ※ 扩展为受信本地代码,exec 不设白名单

// 同步 HTTP(阻塞引擎互斥锁期间其他扩展调用排队;传输错 throw,HTTP 错状态看 .status)
const r = piz.fetch("http://127.0.0.1:8873/x", {
  method: "POST",                 // GET/POST/PUT/DELETE/PATCH/HEAD
  headers: { authorization: "Bearer k" },
  body: "{}",
});
// r = { status: 200, ok: true, body: "..." }(body 8MB 封顶)
// opts.safe: true = SSRF 护栏(私网/本机/metadata 拦,抛 "blocked private or local address")
// execute 返 string | {content} | {error}(error → is_error,模型见失败态)
```

扩展是**受信代码**(同插件/钩子同级信任):fs 原语不过权限闸,装前自己审。

## 热重载

TUI `/reload` 除重灌配置外同刷 JS 扩展:重置 prelude 注册表(不重启引擎,
扩展全局态归零)后重扫两处扩展目。写扩展改完 `/reload` 即生效。

## 约束(窄桥期)

- execute/handler 可同步也可 **async**:async 的 await 链只能链 microtask
  (桥内无 IO 原语,无 fetch/timer/fs);宿主 `__piz_host_settle` 同步泵 job
  至落定,拒绝则原路 throw 进扩展既有 try/catch;永不 settle 报 never settles
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
- **多线程入口必刷栈顶**:ng 栈深上限按 `stack_top` 地址差算,创建时按
  主线程校准;工具回调在 agent worker 线程进 JS 不刷新就误报
  `Maximum call stack size exceeded`(单测主线程全绿、真循环必炸)。
  `callBridge` 入口已 `JS_UpdateStackTop`;新增 JS 入口路径须同例
- `/reload` 热重载:`__piz` 的 defineProperty 必须 `configurable:true`,
  且先重 eval prelude 清注册表再扫目,否则处理器双注册
