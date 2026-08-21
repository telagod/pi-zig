# 模块规矩

每模块一段:职责、禁则、测试归处。新人改码前先读对应段;规矩即 review 依据。
总纲:[architecture.md](architecture.md);插件合同:[plugins.md](plugins.md)。

## 通用五条

1. **测试出壳**:单测主体住 `<mod>_tests.zig`,被测文件尾挂
   `test { _ = @import("<mod>_tests.zig"); }` 引回(`zig build test` 收集不变)。
   测试要触的私有件,抬 `pub`,勿为测试改逻辑。生成物(pricing/catalog)不出壳。
2. **收集靠 main**:新文件/新测试文件,`main.zig` 必挂 `_ = @import("x.zig");`,否则 test 不收集。
3. **向下单向**:子文件不得回引门面(`plugins/` 不回引 `plugins.zig`,`tui_*.zig` 不回引 `tui.zig`)。
   跨层须过 `seams.zig` 或合同文件(`plugins/api.zig`)。
4. **改码纪律**:源码只经内置 edit/write 落盘;shell 仅作分析验证;改毕 `zig fmt` + `zig build test` 方算完。
5. **文件头一行**:每个 `.zig` 首行注释写清职责与边界,如 `// ai_openai.zig —— OpenAI 系序列化,禁网络 IO`。

## main 与 cmd_*

- `main.zig`:入口分发 + 极薄编排。逻辑入 `cmd_*` / `app_*`;picker/视图/worker 分居
  `app_pickers/app_views/app_worker`。新 CLI 子命令先注册 main() 分发,否则落 chdir 分支。
- `runopts.zig`:参数解析唯一出处。

## agent(主链路)

- `agent.zig`:会话主循环、ToolSlot 并发(补位式限流)、emitTurnEnd。
- 工具实现禁入此文件;插件钩子经 `plugins.zig` 分发,JS 事件经 `jsrt.zig`。
- 测试:`agent_tests.zig`。

## ai(provider 适配)

- `ai.zig` 只转调;实现分居 `ai_openai/ai_anthropic/ai_stream/ai_json/ai_markers/ai_think/ai_types`。
- 序列化序:**tools → system → messages**,乱序即 bug(缓存命中率)。
- 禁网络 IO(网络全在 `httpc.zig`);reasoning replay 存 thinkingSignature。
- 测试:`ai_tests.zig`。

## tools(内置工具)

- `tools.zig` 只留核心五件协调(read/write/edit/multi_edit/bash);按域分居
  `tools_search/tools_bash/tools_edit/tools_fs/tools_path/tools_json/tools_read/tools_write/tools_files/tools_skill`。
- 禁空 catch,错误走 `crashResult`;大输出 >4KB 落 artifacts/,bash >16KB 边跑边落。
- 测试用相对路径前必须 chdir 进 tmpDir;CI mtime 粒度粗,连写须隔 10ms。
- 测试:`tools_tests.zig`。

## plugins(内置插件)

- `plugins.zig`:合同 re-export + 出厂表 + 启用集 + 钩子分发,**零实现**。
- 实现按域居 `src/plugins/`(hooks/extras/todo/agents/task/workflow/lsp/childbind),
  合同在 `plugins/api.zig`,工具限流在 `plugins/limits.zig`。
- 能走 JS 扩展者不入此表;抽离件留**空壳行**(`extracted = true`)守名籍,实现居
  `src/embedded/extensions/`,jsrt 按启用集门控装载。
- 文档插件数须与 `builtin_plugins` 实数核对。

## jsrt(JS 窄桥)

- 引擎 quickjs-ng(vendor/),`-Dquickjs` 门控(默认开);off 时全体 API 退化为 no-op。
- 装载三档:内嵌 `src/embedded/extensions/` → `~/.piz/extensions/` → `<cwd>/.piz/extensions/`,同名后者胜。
- 雷区(勿复踩):JS_Eval 源码须 dupeZ;module 的 JS_EvalFunction 吃掉引用勿再 Free;
  JS 回调跑 worker 前 `JS_UpdateStackTop`;prelude defineProperty 须 `configurable:true`。
- 新宿主原语:加 `__piz_host_*` + prelude 包装 + 单测,三件套齐才算落。

## tui(终端界面)

- `tui.zig`:Tui 状态机 + 主绘制;`tui_types/emit/flow/input/slash/draw/keys/measure/footer` 按域分居。
- composer 框宽 `cols-1`(auto-margin 终端末列触换行);多行输入走 bracketed paste。
- 流式热点:cell 携 md 渲染缓存,勿每帧重渲染。
- 测试:`tui_tests.zig`(38 测试 + 绘制助手;paint 走 paintCellsForTest)。

## webui(Web UI)

- `webui.zig`:serve() 只留守卫(originOk/auth/?ws=)+ 一行分发;路由全在 `webui_routes.zig`,
  if-链顺序敏感(静态 assets 先于 plugins 前缀)。
- 前端 `webui.html/.css/.js` @embedFile 内嵌;拆 JS 前查 `</script>` 字串雷。
- 非 GET/HEAD 须过 originOk;静态资源免鉴权;容量 TCP64/SSE16/会话4。
- 测试:`webui_tests.zig`(ITest 上限 256KB);`cmd_web.zig` 会话池,测试 `cmd_web_tests.zig`。

## session / compress / config

- `session.zig`:JSONL 存取、分支;测试 `session_tests.zig`。
- `compress.zig`:压缩线 85%;摘要钩子在 plugins(on_compact 系)。
- `config.zig`:配置解析;`Api=enum{openai_completions,anthropic_messages,openai_responses}`;
  测试 `config_tests.zig`。

## 基础件

- `httpc.zig`:唯一网络层(连接池、SSE 流);他处禁直发 HTTP。
- `pool.zig`/`activity.zig`/`events.zig`/`usage_log.zig`/`oauth.zig`/`mcp.zig`:各守一职,禁膨胀。
- `util.zig`:io 时钟、debugLog(PIZ_DEBUG)、jsonString 等杂件;不放业务。
- `sandbox.zig`:bubblewrap 优先、Landlock 次之、两无 fail-closed。
- `snapfont.zig`/`imgx.zig`/`markdown.zig`/`theme.zig`:渲染/图像纯函数,禁 IO(读盘在调用方)。
- `pricing.zig`/`catalog.zig`:**生成物,勿手改**(重生成脚本见文件头)。
- `embedded/`:内嵌资源(sucrase、extensions);BUILD.md 记复现法。
- `e2e.zig`:端到端(mock provider+真子进程);测试 `e2e_tests.zig`。
