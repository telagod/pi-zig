//! jsrt.zig —— QuickJS 扩展宿主(窄桥)。
//!
//! 由 build -Dquickjs(默认开)门控;关闭时全部 API 退化为 no-op/空表,
//! 调用方不必写两套。设计约束见 docs/research-extension-runtime.md:
//!   - 单 runtime 单 context;一切入 JS 的调用过全局互斥闸(工具回调跑在工作线程上,
//!     QuickJS 上下文非线程安全,序列化是窄桥期的明确取舍)。
//!   - JS 侧对象进出即拷贝(字符串 dupe 到调用方 allocator),不留跨 GC/arena 引用。
//!   - 扩展为 classic script(~/.piz/extensions/*.js 与 .piz/extensions/*.js),
//!     用全局 `piz` 对象:piz.on / piz.registerTool / piz.registerCommand /
//!     piz.notify / piz.confirm。pi 式 ESM default-export 与 TS 剥离后置。
//!   - execute/handler 须同步;promise 不支持(窄桥期记录在案)。
//!
//! 安全默认:confirm 未接管时一律 deny;JS 工具不绕过 permissions ——
//! 与内置工具同一闸(调用方负责接)。

const std = @import("std");
const build_options = @import("build_options");
const util = @import("util.zig");
const toolsmod = @import("tools.zig");
const httpc = @import("httpc.zig");
const aimod = @import("ai.zig");

pub const enabled = build_options.quickjs;
/// TS 类型剥离(-Djsts,默认随 quickjs):.ts/.mts 扩展先经 sucrase 剥皮再 eval。
pub const jsts_on = enabled and build_options.jsts;
/// sucrase standalone(MIT,vendor/sucrase.standalone.js;复现见 vendor/sucrase.BUILD.md)。
/// 只在首个 .ts 扩展出现时惰性 eval 一次。embedFile 产出无 NUL,用前 dupeZ。
const sucrase_src: []const u8 = if (jsts_on) @embedFile("embedded/sucrase.standalone.js") else "";
var ts_ready = false; // sucrase 已在本 runtime 里 eval 过
var sucrase_z: ?[:0]u8 = null; // bundle 的 NUL 副本,deinit 时 free

const c = if (enabled) @cImport({
    @cInclude("quickjs.h");
}) else struct {};

/// 宿主回调:notify(msg, level)。未设 = 丢弃(记 last_notify 供测试/排查)。
pub var notify_cb: ?*const fn (msg: []const u8, level: []const u8) void = null;
/// 宿主回调:confirm(msg) -> 用户是否同意。未设 = 一律 deny(安全默认)。
pub var confirm_cb: ?*const fn (msg: []const u8) bool = null;

/// 调试用:最近一次 notify 内容(由 hostNotify 记录,dupe 到内部 allocator)。
pub var last_notify: ?[]u8 = null;

const MAX_EXT_FILE = 1 << 20; // 单个扩展脚本 1MB 封顶
const MAX_RET = 4 << 20; // JS 返回串 4MB 封顶
const MAX_FS_IO = 8 << 20; // piz.readFile/writeFile 单发 8MB 封顶

/// JS prelude:注册表全部在 JS 侧,Zig 只供两个 host 原语与四个内省入口。
const PRELUDE =
    \\globalThis.piz = (() => {
    \\  const handlers = Object.create(null);
    \\  const tools = [];
    \\  const commands = Object.create(null);
    \\  // promise 收干:async handler 的 await 链全是 microtask(桥无 IO 原语),
    \\  // host_settle 同步泵 job 至 settle;拒绝则 throw,落进各处既有 try/catch。
    \\  const settle = (r) => (r && typeof r.then === "function") ? __piz_host_settle(r) : r;
    \\  const api = {
    \\    on(ev, fn) { (handlers[ev] || (handlers[ev] = [])).push(fn); },
    \\    registerTool(def) { if (def && def.name) tools.push(def); },
    \\    registerCommand(name, def) { if (name) commands[name] = def || {}; },
    \\    notify(msg, level) { __piz_host_notify(String(msg), String(level || "info")); },
    \\    confirm(msg) { return !!__piz_host_confirm(String(msg)); },
    \\    readFile(path) { return __piz_host_readFile(String(path)); },
    \\    writeFile(path, text) { return !!__piz_host_writeFile(String(path), String(text)); },
    \\    appendFile(path, text) { return !!__piz_host_appendFile(String(path), String(text)); },
    \\    env(name) { return __piz_host_env(String(name)); },
    \\    cwd() { return __piz_host_cwd(); },
    \\    configDir() { return __piz_host_configDir(); },
    \\    fetch(url, opts) { return __piz_host_fetch(String(url), opts === undefined ? "" : JSON.stringify(opts)); },
    \\  };
    \\  Object.defineProperty(globalThis, "__piz", { value: {
    \\    emit(ev, json) {
    \\      const hs = handlers[ev];
    \\      if (!hs || !hs.length) return undefined;
    \\      let payload;
    \\      try { payload = json ? JSON.parse(json) : {}; } catch (_) { payload = {}; }
    \\      let out;
    \\      for (const h of hs) {
    \\        try { const r = settle(h(payload, api)); if (r !== undefined) out = r; }
    \\        catch (e) { api.notify("ext " + ev + " handler: " + (e && e.message || e), "error"); }
    \\      }
    \\      return out === undefined ? undefined : JSON.stringify(out);
    \\    },
    \\    has(ev) { return !!(handlers[ev] && handlers[ev].length); },
    \\    toolsJson() {
    \\      return JSON.stringify(tools.map(t => ({
    \\        name: String(t.name),
    \\        description: String(t.description || ""),
    \\        schema: t.schema || t.parameters || null,
    \\      })));
    \\    },
    \\    callTool(name, argsJson) {
    \\      const t = tools.find(x => x.name === name);
    \\      if (!t || typeof t.execute !== "function")
    \\        return JSON.stringify({ error: "js tool not found: " + name });
    \\      let args = {};
    \\      try { args = argsJson ? JSON.parse(argsJson) : {}; } catch (e) {
    \\        return JSON.stringify({ error: "bad args json: " + (e && e.message || e) });
    \\      }
    \\      try {
    \\        const r = settle(t.execute(args, api));
    \\        if (r && r.error !== undefined) return JSON.stringify({ error: String(r.error) });
    \\        const text = r && r.content !== undefined ? r.content : r;
    \\        return JSON.stringify({ content: typeof text === "string" ? text : JSON.stringify(text) });
    \\      } catch (e) {
    \\        return JSON.stringify({ error: String(e && (e.stack || e.message) || e) });
    \\      }
    \\    },
    \\    commandsJson() {
    \\      return JSON.stringify(Object.keys(commands).map(name => ({
    \\        name, description: String((commands[name] && commands[name].description) || ""),
    \\      })));
    \\    },
    \\    runCommand(name, args) {
    \\      const d = commands[name];
    \\      if (!d) return undefined;
    \\      const fn = typeof d === "function" ? d : d.handler;
    \\      if (typeof fn !== "function") return "";
    \\      try { const r = settle(fn(args || "", api)); return r === undefined || r === null ? "" : String(r); }
    \\      catch (e) { return JSON.stringify({ error: String(e && (e.stack || e.message) || e) }); }
    \\    },
    \\  }, enumerable: false, configurable: true }); // configurable:/reload 重 eval prelude 重置注册表靠它
    \\  return api;
    \\})();
;

pub const JsTool = struct {
    name: []const u8,
    desc: []const u8,
    /// JSON Schema 原文(parameters/schema 字段透传);空串 = 无参数。
    schema: []const u8,
};

pub const JsCommand = struct {
    name: []const u8,
    desc: []const u8,
};

var mu: std.Io.Mutex = .init;
var rt: ?*c.JSRuntime = null;
var ctx: ?*c.JSContext = null;
var gpa: ?std.mem.Allocator = null; // 宿主长寿命 allocator(注册表/last_notify 用)
var js_tools: []JsTool = &.{};
var js_tool_defs: []toolsmod.Tool = &.{}; // 与 js_tools 平行的 Tool 表(稳定指针,供 findTool)
var js_commands: []JsCommand = &.{};
var loaded_files: usize = 0;
var load_errors: usize = 0;
// 事件处理器在场缓存(refreshRegistry 时刷):工具热路径免两次桥调用。
var h_tool_call = false;
var h_tool_result = false;
var h_session_start = false;
var h_agent_end = false;

fn jsThrowToString(ctx_: *c.JSContext, arena: std.mem.Allocator) []const u8 {
    const ex = c.JS_GetException(ctx_);
    defer c.JS_FreeValue(ctx_, ex);
    const s = c.JS_ToCString(ctx_, ex);
    if (s == null) return "js exception";
    defer c.JS_FreeCString(ctx_, s);
    return arena.dupe(u8, std.mem.span(s)) catch "js exception";
}

fn mkVal(tag: i64, val: i32) c.JSValue {
    // translate-c 的 JSValueUnion 不能直接默认初始化,显式逐字段构造。
    var u: c.union_JSValueUnion = undefined;
    u.int32 = val;
    return .{ .u = u, .tag = tag };
}
fn jsUndef() c.JSValue {
    return mkVal(c.JS_TAG_UNDEFINED, 0);
}
fn jsNull() c.JSValue {
    return mkVal(c.JS_TAG_NULL, 0);
}
fn jsBool(v: bool) c.JSValue {
    return mkVal(c.JS_TAG_BOOL, @intFromBool(v));
}

/// host 原语:__piz_host_notify(msg, level)。
fn hostNotify(ctx_: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1 or ctx_ == null) return jsUndef();
    const msg = c.JS_ToCString(ctx_.?, argv[0]);
    const level = if (argc > 1) c.JS_ToCString(ctx_.?, argv[1]) else null;
    defer if (msg != null) c.JS_FreeCString(ctx_.?, msg);
    defer if (level != null) c.JS_FreeCString(ctx_.?, level);
    const m = if (msg != null) std.mem.span(msg) else "";
    const l = if (level != null) std.mem.span(level) else "info";
    if (gpa) |a| {
        if (last_notify) |old| a.free(old);
        last_notify = std.fmt.allocPrint(a, "[{s}] {s}", .{ l, m }) catch null;
    }
    if (notify_cb) |cb| cb(m, l);
    return jsUndef();
}

/// host 原语:__piz_host_confirm(msg) -> bool。未接管 = deny。
fn hostConfirm(ctx_: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1 or ctx_ == null) return jsBool(false);
    const msg = c.JS_ToCString(ctx_.?, argv[0]);
    defer if (msg != null) c.JS_FreeCString(ctx_.?, msg);
    const m = if (msg != null) std.mem.span(msg) else "";
    const ok = if (confirm_cb) |cb| cb(m) else false;
    return jsBool(ok);
}

/// host 原语:__piz_host_readFile(path) -> string|null。相对路径走进程 cwd(=agent cwd)。
fn hostReadFile(ctx_: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    const cx = ctx_ orelse return jsNull();
    if (argc < 1) return jsNull();
    const p = c.JS_ToCString(cx, argv[0]);
    defer if (p != null) c.JS_FreeCString(cx, p);
    if (p == null) return jsNull();
    const a = gpa orelse return jsNull();
    const data = std.Io.Dir.cwd().readFileAlloc(util.io, std.mem.span(p), a, .limited(MAX_FS_IO)) catch return jsNull();
    defer a.free(data);
    return c.JS_NewStringLen(cx, data.ptr, @intCast(data.len));
}

/// host 原语:__piz_host_writeFile(path, text) -> bool。
fn hostWriteFile(ctx_: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    const cx = ctx_ orelse return jsBool(false);
    if (argc < 2) return jsBool(false);
    const p = c.JS_ToCString(cx, argv[0]);
    defer if (p != null) c.JS_FreeCString(cx, p);
    const t = c.JS_ToCString(cx, argv[1]);
    defer if (t != null) c.JS_FreeCString(cx, t);
    if (p == null or t == null) return jsBool(false);
    const text = std.mem.span(t);
    if (text.len > MAX_FS_IO) return jsBool(false);
    const path = std.mem.span(p);
    if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().createDirPath(util.io, d) catch {};
    std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = path, .data = text }) catch return jsBool(false);
    return jsBool(true);
}

/// host 原语:__piz_host_appendFile(path, text) -> bool。尾追加,不存在则建(0600)。
fn hostAppendFile(ctx_: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    const cx = ctx_ orelse return jsBool(false);
    if (argc < 2) return jsBool(false);
    const p = c.JS_ToCString(cx, argv[0]);
    defer if (p != null) c.JS_FreeCString(cx, p);
    const t = c.JS_ToCString(cx, argv[1]);
    defer if (t != null) c.JS_FreeCString(cx, t);
    if (p == null or t == null) return jsBool(false);
    const text = std.mem.span(t);
    if (text.len > MAX_FS_IO) return jsBool(false);
    const path = std.mem.span(p);
    if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().createDirPath(util.io, d) catch {};
    var f = std.Io.Dir.cwd().createFile(util.io, path, .{ .exclusive = true, .permissions = @enumFromInt(0o600) }) catch |err| switch (err) {
        error.PathAlreadyExists => std.Io.Dir.cwd().openFile(util.io, path, .{ .mode = .write_only }) catch return jsBool(false),
        else => return jsBool(false),
    };
    defer f.close(util.io);
    var wbuf: [512]u8 = undefined;
    var w = f.writer(util.io, &wbuf);
    w.seekTo(f.length(util.io) catch 0) catch return jsBool(false);
    w.interface.writeAll(text) catch return jsBool(false);
    w.flush() catch return jsBool(false);
    return jsBool(true);
}

/// host 原语:__piz_host_configDir() -> string|null。值在 loadExtensions 存档。
fn hostConfigDir(ctx_: ?*c.JSContext, _: c.JSValue, _: c_int, _: [*c]c.JSValue) callconv(.c) c.JSValue {
    const cx = ctx_ orelse return jsNull();
    const s = saved_cfg orelse return jsNull();
    return c.JS_NewStringLen(cx, s.ptr, @intCast(s.len));
}

/// host 原语:__piz_host_env(name) -> string|null。
fn hostEnv(ctx_: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    const cx = ctx_ orelse return jsNull();
    if (argc < 1) return jsNull();
    const n = c.JS_ToCString(cx, argv[0]);
    defer if (n != null) c.JS_FreeCString(cx, n);
    if (n == null) return jsNull();
    const v = util.getEnv(std.mem.span(n)) orelse return jsNull();
    return c.JS_NewStringLen(cx, v.ptr, @intCast(v.len));
}

/// host 原语:__piz_host_cwd() -> string。
fn hostCwd(ctx_: ?*c.JSContext, _: c.JSValue, _: c_int, _: [*c]c.JSValue) callconv(.c) c.JSValue {
    const cx = ctx_ orelse return jsNull();
    const a = gpa orelse return jsNull();
    const p = std.process.currentPathAlloc(util.io, a) catch return jsNull();
    defer a.free(p);
    return c.JS_NewStringLen(cx, p.ptr, @intCast(p.len));
}

/// host 原语:__piz_host_fetch(url, optsJson) -> {status, ok, body}。同步阻塞(窄桥:
/// 引擎全局互斥锁内完成,期间其他扩展调用排队);opts = {method?, headers?{}, body?}。
/// 传输错 throw;HTTP 错状态不 throw(看 .status)。8MB 封顶。扩展是受信代码,不过权限闸。
fn hostFetch(ctx_: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    const cx = ctx_ orelse return jsNull();
    if (argc < 1) return c.JS_ThrowInternalError(cx, "fetch(url, opts?)");
    const url_c = c.JS_ToCString(cx, argv[0]);
    defer if (url_c != null) c.JS_FreeCString(cx, url_c);
    if (url_c == null) return jsNull();
    const a = gpa orelse return jsNull();
    // opts 解析与 headers 用临时 arena:此前直用 gpa 是漏的(扩展每 fetch 一次漏一串)。
    var tmp_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer tmp_arena.deinit();
    const ta = tmp_arena.allocator();
    var method: std.http.Method = .GET;
    var body: []const u8 = "";
    var headers = std.ArrayList(std.http.Header).empty;
    var safe = false;
    if (argc > 1) {
        const oj = c.JS_ToCString(cx, argv[1]);
        defer if (oj != null) c.JS_FreeCString(cx, oj);
        if (oj != null and std.mem.span(oj).len > 0) {
            const v = std.json.parseFromSliceLeaky(std.json.Value, ta, std.mem.span(oj), .{}) catch {
                return c.JS_ThrowInternalError(cx, "fetch: bad opts json");
            };
            if (v == .object) {
                if (v.object.get("method")) |m| {
                    if (m == .string) {
                        if (std.ascii.eqlIgnoreCase(m.string, "GET")) method = .GET;
                        if (std.ascii.eqlIgnoreCase(m.string, "POST")) method = .POST;
                        if (std.ascii.eqlIgnoreCase(m.string, "PUT")) method = .PUT;
                        if (std.ascii.eqlIgnoreCase(m.string, "DELETE")) method = .DELETE;
                        if (std.ascii.eqlIgnoreCase(m.string, "PATCH")) method = .PATCH;
                        if (std.ascii.eqlIgnoreCase(m.string, "HEAD")) method = .HEAD;
                    }
                }
                if (v.object.get("body")) |b| {
                    if (b == .string) body = b.string;
                }
                if (v.object.get("safe")) |sv| {
                    if (sv == .bool) safe = sv.bool;
                }
                if (v.object.get("headers")) |h| {
                    if (h == .object) {
                        var it = h.object.iterator();
                        while (it.next()) |e| {
                            if (e.value_ptr.* == .string)
                                headers.append(ta, .{ .name = e.key_ptr.*, .value = e.value_ptr.string }) catch {};
                        }
                    }
                }
            }
        }
    }
    if (body.len > MAX_FS_IO) return c.JS_ThrowInternalError(cx, "fetch: body too large");
    // safe: true = SSRF 护栏(fetch_url 用):私网/本机/metadata 拦,含 getent 解析回拦
    if (safe and httpc.urlBlocked(a, std.mem.span(url_c))) {
        return c.JS_ThrowInternalError(cx, "fetch: blocked private or local address");
    }
    const stream = httpc.Stream.initWith(a, std.mem.span(url_c), headers.items, body, method) catch |err| {
        return c.JS_ThrowInternalError(cx, "fetch: %s", @errorName(err).ptr);
    };
    defer stream.deinit();
    const rb = stream.readAll(MAX_FS_IO) catch |err| {
        return c.JS_ThrowInternalError(cx, "fetch read: %s", @errorName(err).ptr);
    };
    defer a.free(rb);
    const obj = c.JS_NewObject(cx);
    _ = c.JS_SetPropertyStr(cx, obj, "status", mkVal(c.JS_TAG_INT, @intCast(stream.status())));
    const st = stream.status();
    _ = c.JS_SetPropertyStr(cx, obj, "ok", jsBool(st >= 200 and st < 300));
    _ = c.JS_SetPropertyStr(cx, obj, "body", c.JS_NewStringLen(cx, rb.ptr, @intCast(rb.len)));
    return obj;
}

/// host 原语:__piz_host_settle(promise) -> 落定值;拒绝则 throw;永不 pending 也 throw。
/// js_std_await 同款模式:host fn 里同步泵 job,允许嵌套。
fn hostSettle(ctx_: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    const cx = ctx_ orelse return jsUndef();
    if (argc < 1) return jsUndef();
    if (!c.JS_IsPromise(argv[0])) return c.JS_DupValue(cx, argv[0]);
    var spins: u32 = 0;
    while (c.JS_PromiseState(cx, argv[0]) == c.JS_PROMISE_PENDING and spins < 100_000) : (spins += 1) {
        drainJobs();
        if (!c.JS_IsJobPending(rt orelse return jsUndef())) break;
    }
    const st = c.JS_PromiseState(cx, argv[0]);
    if (st == c.JS_PROMISE_FULFILLED) return c.JS_PromiseResult(cx, argv[0]); // 新引用,调用方收
    if (st == c.JS_PROMISE_REJECTED) {
        const reason = c.JS_PromiseResult(cx, argv[0]);
        return c.JS_Throw(cx, reason); // JS_Throw 吃掉 reason 引用
    }
    return c.JS_ThrowInternalError(cx, "promise never settles (no host async in piz extensions)");
}

/// 取 globalThis.__piz 上的函数并调用,返回值转 Zig 串(dupe 到 arena)。
/// 无此函数/异常/undefined 一律回 null。
fn callBridge(arena: std.mem.Allocator, name: []const u8, args: []const []const u8) ?[]const u8 {
    const ctx_ = ctx orelse return null;
    // 工具回调跑在 worker 线程上:ng 的栈深上限按 stack_top 地址差算,
    // 不随线程刷新就在工作线程上误报 "Maximum call stack size exceeded"
    // (e2e:js-ext block 在真 agent 循环里失效,2026-08-20 实擒)。
    c.JS_UpdateStackTop(rt.?);
    const global = c.JS_GetGlobalObject(ctx_);
    defer c.JS_FreeValue(ctx_, global);
    const api = c.JS_GetPropertyStr(ctx_, global, "__piz");
    defer c.JS_FreeValue(ctx_, api);
    const name_z = arena.dupeZ(u8, name) catch return null;
    const func = c.JS_GetPropertyStr(ctx_, api, name_z.ptr);
    defer c.JS_FreeValue(ctx_, func);
    if (c.JS_IsUndefined(func)) return null;
    var argv_buf: [4]c.JSValue = undefined;
    if (args.len > argv_buf.len) return null;
    for (args, 0..) |s, i| argv_buf[i] = c.JS_NewStringLen(ctx_, s.ptr, @intCast(s.len));
    defer {
        for (argv_buf[0..args.len]) |v| c.JS_FreeValue(ctx_, v);
    }
    const ret = c.JS_Call(ctx_, func, api, @intCast(args.len), argv_buf[0..args.len].ptr);
    defer c.JS_FreeValue(ctx_, ret);
    if (c.JS_IsException(ret)) {
        // 桥入口自身的异常:notify 出去,不当静默。
        var tmp_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer tmp_arena.deinit();
        const msg = jsThrowToString(ctx_, tmp_arena.allocator());
        if (notify_cb) |cb| cb(msg, "error");
        return null;
    }
    // promise 已在 JS 侧经 __piz_host_settle 收干(见 prelude settle),到不了这里。
    return jsRetToString(arena, ctx_, ret);
}

/// undefined/null/超长 → null;否则 dupe 到 arena。
fn jsRetToString(arena: std.mem.Allocator, ctx_: *c.JSContext, v: c.JSValue) ?[]const u8 {
    if (c.JS_IsUndefined(v) or c.JS_IsNull(v)) return null;
    const s = c.JS_ToCString(ctx_, v);
    if (s == null) return null;
    defer c.JS_FreeCString(ctx_, s);
    const span = std.mem.span(s);
    if (span.len > MAX_RET) return null;
    return arena.dupe(u8, span) catch null;
}

/// 模块加载器:引擎默认 normalizer 已把 './x.js' 按 base 文件名解成绝对路径,
/// 这里读盘编译(COMPILE_ONLY),引用直接移交引擎 —— 勿 free(模块 refcount
/// 到 0 走 abort)。
fn moduleLoader(ctx_: ?*c.JSContext, name: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) ?*c.JSModuleDef {
    const cx = ctx_ orelse return null;
    const path = std.mem.span(name orelse return null);
    const a = gpa orelse return null;
    const src = std.Io.Dir.cwd().readFileAlloc(util.io, path, a, .limited(MAX_EXT_FILE)) catch {
        _ = c.JS_ThrowReferenceError(cx, "cannot load module '%s'", path.ptr);
        return null;
    };
    defer a.free(src);
    // JS_Eval 要求 NUL 结尾(见 evalFile 注)。
    const src_z = a.dupeZ(u8, src) catch return null;
    defer a.free(src_z);
    const path_z = a.dupeZ(u8, path) catch return null;
    defer a.free(path_z);
    const mv = c.JS_Eval(cx, src_z.ptr, @intCast(src.len), path_z.ptr, c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
    if (c.JS_IsException(mv)) return null; // 异常已挂在 ctx 上
    return @ptrCast(c.JS_VALUE_GET_PTR(mv));
}

/// 初始化引擎并加载扩展目。幂等;重复调用只生效一次。
/// alloc 须与进程同寿(注册表终生有效)。
pub fn init(alloc: std.mem.Allocator) void {
    if (!enabled) return;
    mu.lockUncancelable(util.io);
    defer mu.unlock(util.io);
    if (rt != null) return;
    gpa = alloc;
    rt = c.JS_NewRuntime();
    if (rt == null) return;
    ctx = c.JS_NewContext(rt.?);
    if (ctx == null) {
        c.JS_FreeRuntime(rt.?);
        rt = null;
        return;
    }
    // 静默 promise 拒绝打到 stderr(否则扩展里的异步错谁也看不见)。
    c.JS_SetHostPromiseRejectionTracker(rt.?, struct {
        fn f(ctx_: ?*c.JSContext, _: c.JSValueConst, reason: c.JSValueConst, handled: bool, _: ?*anyopaque) callconv(.c) void {
            if (handled) return;
            const cx = ctx_ orelse return;
            const s = c.JS_ToCString(cx, reason);
            defer c.JS_FreeCString(cx, s);
            std.debug.print("piz: extension: unhandled rejection: {s}\n", .{s});
        }
    }.f, null);
    // 模块加载器:import './x.js' 由默认 normalizer 解相对路径,这里读盘编译。
    c.JS_SetModuleLoaderFunc(rt.?, null, moduleLoader, null);
    // host 原语
    const global = c.JS_GetGlobalObject(ctx.?);
    defer c.JS_FreeValue(ctx.?, global);
    const nf = c.JS_NewCFunction(ctx.?, hostNotify, "__piz_host_notify", 2);
    _ = c.JS_SetPropertyStr(ctx.?, global, "__piz_host_notify", nf);
    const cf = c.JS_NewCFunction(ctx.?, hostConfirm, "__piz_host_confirm", 1);
    _ = c.JS_SetPropertyStr(ctx.?, global, "__piz_host_confirm", cf);
    const sf = c.JS_NewCFunction(ctx.?, hostSettle, "__piz_host_settle", 1);
    _ = c.JS_SetPropertyStr(ctx.?, global, "__piz_host_settle", sf);
    const rf = c.JS_NewCFunction(ctx.?, hostReadFile, "__piz_host_readFile", 1);
    _ = c.JS_SetPropertyStr(ctx.?, global, "__piz_host_readFile", rf);
    const wf = c.JS_NewCFunction(ctx.?, hostWriteFile, "__piz_host_writeFile", 2);
    _ = c.JS_SetPropertyStr(ctx.?, global, "__piz_host_writeFile", wf);
    const af = c.JS_NewCFunction(ctx.?, hostAppendFile, "__piz_host_appendFile", 2);
    _ = c.JS_SetPropertyStr(ctx.?, global, "__piz_host_appendFile", af);
    const ef = c.JS_NewCFunction(ctx.?, hostEnv, "__piz_host_env", 1);
    _ = c.JS_SetPropertyStr(ctx.?, global, "__piz_host_env", ef);
    const pf = c.JS_NewCFunction(ctx.?, hostCwd, "__piz_host_cwd", 0);
    _ = c.JS_SetPropertyStr(ctx.?, global, "__piz_host_cwd", pf);
    const cdf = c.JS_NewCFunction(ctx.?, hostConfigDir, "__piz_host_configDir", 0);
    _ = c.JS_SetPropertyStr(ctx.?, global, "__piz_host_configDir", cdf);
    const ff = c.JS_NewCFunction(ctx.?, hostFetch, "__piz_host_fetch", 2);
    _ = c.JS_SetPropertyStr(ctx.?, global, "__piz_host_fetch", ff);
    // prelude
    const pv = c.JS_Eval(ctx.?, PRELUDE.ptr, PRELUDE.len, "<prelude>", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(pv)) {
        var tmp = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer tmp.deinit();
        const msg = jsThrowToString(ctx.?, tmp.allocator());
        std.debug.print("piz: js prelude failed: {s}\n", .{msg});
        c.JS_FreeValue(ctx.?, pv);
        c.JS_FreeContext(ctx.?);
        c.JS_FreeRuntime(rt.?);
        ctx = null;
        rt = null;
        return;
    }
    c.JS_FreeValue(ctx.?, pv);
}

/// 进程退出前释放。可不调(进程寿终即回收),web 长驻/测试复初始化时有用。
pub fn deinit() void {
    if (!enabled) return;
    mu.lockUncancelable(util.io);
    defer mu.unlock(util.io);
    if (ctx) |cx| c.JS_FreeContext(cx);
    if (rt) |r| c.JS_FreeRuntime(r);
    ctx = null;
    rt = null;
    freeRegistry();
    if (gpa) |a| {
        if (last_notify) |s| a.free(s);
        if (saved_cfg) |s| a.free(s);
        if (saved_cwd) |s| a.free(s);
        if (gate_names.len > 0) a.free(gate_names);
    }
    js_tools = &.{};
    js_commands = &.{};
    last_notify = null;
    saved_cfg = null;
    saved_cwd = null;
    gate_names = &.{};
    loaded_files = 0;
    load_errors = 0;
    h_tool_call = false;
    h_tool_result = false;
    h_session_start = false;
    h_agent_end = false;
    ts_ready = false;
    if (sucrase_z) |z| {
        if (gpa) |a| a.free(z);
        sucrase_z = null;
    }
    gpa = null;
}

fn evalFile(path: []const u8) bool {
    const ctx_ = ctx orelse return false;
    const a = gpa orelse return false;
    const raw = std.Io.Dir.cwd().readFileAlloc(util.io, path, a, .limited(MAX_EXT_FILE)) catch return false;
    defer a.free(raw);
    if (raw.len == 0) return true;
    // TS 剥皮:.ts/.mts 先过 sucrase(惰性,一次);剥不动(语法错)按加载错报出。
    var src: []const u8 = raw;
    var stripped: ?[]const u8 = null;
    defer if (stripped) |s| a.free(s);
    if (isTsFile(path)) {
        if (!jsts_on) {
            std.debug.print("piz: extension {s}: TypeScript disabled (rebuild without -Djsts=false)\n", .{path});
            return false;
        }
        stripped = tsStrip(a, raw) orelse {
            std.debug.print("piz: extension {s}: ts strip failed\n", .{path});
            return false;
        };
        src = stripped.?;
    }
    // 必须 NUL 后送:实测 quickjs-ng 词法器会瞥 input[len] 一眼 —— 非 NUL 结尾的
    // 堆缓冲按相邻字节随机报 "invalid UTF-8"/"unexpected token"(4/4 复现),
    // dupeZ 后 4/4 干净。len 不变,NUL 只是兜底界标。
    const src_z = a.dupeZ(u8, src) catch return false;
    defer a.free(src_z);
    const path_z = a.dupeZ(u8, path) catch return false;
    defer a.free(path_z);
    if (isModule(path, src)) return evalModule(path_z.ptr, src_z.ptr, src.len);
    const v = c.JS_Eval(ctx_, src_z.ptr, @intCast(src.len), path_z.ptr, c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(v)) {
        reportEx(ctx_, path);
        c.JS_FreeValue(ctx_, v);
        return false;
    }
    c.JS_FreeValue(ctx_, v);
    drainJobs();
    return true;
}

/// pi 式扩展是 ESM(`export default function(pi)`)。判定从宽:
/// .mjs 后缀或源含 "export default" 即走模块支路。
fn isModule(path: []const u8, src: []const u8) bool {
    return std.mem.endsWith(u8, path, ".mjs") or std.mem.endsWith(u8, path, ".mts") or std.mem.indexOf(u8, src, "export default") != null;
}

fn isTsFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".mts") or std.mem.endsWith(u8, path, ".cts");
}

/// 惰性起 sucrase:bundle 走 global script eval,产出全局 Sucrase。
fn ensureTs() bool {
    if (!jsts_on) return false;
    if (ts_ready) return true;
    const ctx_ = ctx orelse return false;
    const a = gpa orelse return false;
    const z = a.dupeZ(u8, sucrase_src) catch return false; // 登记在 sucrase_z,deinit 时 free
    sucrase_z = z;
    const v = c.JS_Eval(ctx_, z.ptr, @intCast(sucrase_src.len), "sucrase.standalone.js", c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(v)) {
        reportEx(ctx_, "<sucrase>");
        c.JS_FreeValue(ctx_, v);
        return false;
    }
    c.JS_FreeValue(ctx_, v);
    drainJobs();
    ts_ready = true;
    return true;
}

/// sucrase transform(src, {transforms:["typescript"]}) → JS 源(dupe 到 a,调用方 free)。
fn tsStrip(a: std.mem.Allocator, src: []const u8) ?[]const u8 {
    if (!ensureTs()) return null;
    const ctx_ = ctx orelse return null;
    const global = c.JS_GetGlobalObject(ctx_);
    defer c.JS_FreeValue(ctx_, global);
    const s = c.JS_GetPropertyStr(ctx_, global, "Sucrase");
    defer c.JS_FreeValue(ctx_, s);
    if (c.JS_IsUndefined(s)) return null;
    const tr = c.JS_GetPropertyStr(ctx_, s, "transform");
    defer c.JS_FreeValue(ctx_, tr);
    const arg0 = c.JS_NewStringLen(ctx_, src.ptr, @intCast(src.len));
    defer c.JS_FreeValue(ctx_, arg0);
    const opt_src = "({transforms:['typescript']})";
    const opt = c.JS_Eval(ctx_, opt_src.ptr, opt_src.len, "<opt>", c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(ctx_, opt);
    var argv = [_]c.JSValue{ arg0, opt };
    const r = c.JS_Call(ctx_, tr, s, 2, &argv);
    defer c.JS_FreeValue(ctx_, r);
    if (c.JS_IsException(r)) {
        reportEx(ctx_, "<ts>");
        return null;
    }
    const code = c.JS_GetPropertyStr(ctx_, r, "code");
    defer c.JS_FreeValue(ctx_, code);
    return jsRetToString(a, ctx_, code);
}

/// 取异常并打 stderr(模块/classic 共用)。
fn reportEx(ctx_: *c.JSContext, path: []const u8) void {
    var tmp = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer tmp.deinit();
    const msg = jsThrowToString(ctx_, tmp.allocator());
    std.debug.print("piz: extension {s}: {s}\n", .{ path, msg });
}

/// 跑尽待决作业(promise 微任务)。模块顶层 await / default 导出返回 promise 皆靠此。
fn drainJobs() void {
    const rt_ = rt orelse return;
    var n: u32 = 0;
    while (c.JS_IsJobPending(rt_)) {
        var pctx: ?*c.JSContext = null;
        if (c.JS_ExecutePendingJob(rt_, &pctx) < 0) break; // job 异常已在 ctx 上,由调用方报
        n += 1;
        if (n > 100_000) break;
    }
}

/// 模块支路:COMPILE_ONLY 编译 → EvalFunction 执行 → 取 default 导出,是函数则以 piz 对象为参调用。
fn evalModule(path_z: [*:0]const u8, src_z: [*:0]const u8, len: usize) bool {
    const ctx_ = ctx orelse return false;
    const mv = c.JS_Eval(ctx_, src_z, @intCast(len), path_z, c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
    if (c.JS_IsException(mv)) {
        reportEx(ctx_, std.mem.span(path_z));
        return false;
    }
    // 勿再 JS_FreeValue(mv):JS_EvalFunction 对 JS_TAG_MODULE 会吃掉这份引用
    // (quickjs.c JS_EvalFunctionInternal: "the module refcount should be >= 2" 后即 FreeValue)。
    // 模块本体由 runtime 注册表续命,GetModuleNamespace 之后仍可用。
    const mod: ?*c.JSModuleDef = @ptrCast(c.JS_VALUE_GET_PTR(mv));
    const rv = c.JS_EvalFunction(ctx_, mv);
    const rv_bad = c.JS_IsException(rv);
    c.JS_FreeValue(ctx_, rv);
    drainJobs();
    if (rv_bad) {
        reportEx(ctx_, std.mem.span(path_z));
        return false;
    }
    const ns = c.JS_GetModuleNamespace(ctx_, mod);
    defer c.JS_FreeValue(ctx_, ns);
    const def = c.JS_GetPropertyStr(ctx_, ns, "default");
    defer c.JS_FreeValue(ctx_, def);
    if (!c.JS_IsFunction(ctx_, def)) return true; // 纯副作用模块
    const global = c.JS_GetGlobalObject(ctx_);
    defer c.JS_FreeValue(ctx_, global);
    const piz_obj = c.JS_GetPropertyStr(ctx_, global, "piz");
    defer c.JS_FreeValue(ctx_, piz_obj);
    var argv = [_]c.JSValue{piz_obj};
    const res = c.JS_Call(ctx_, def, piz_obj, 1, &argv);
    if (c.JS_IsException(res)) {
        reportEx(ctx_, std.mem.span(path_z));
        c.JS_FreeValue(ctx_, res);
        return false;
    }
    c.JS_FreeValue(ctx_, res);
    drainJobs();
    return true;
}

/// 内嵌出厂扩展:随二进制,先于目录档加载;用户/项目目有同名 basename 则让位(覆写)。
/// gate 非空 = 抽离件:仅当插件启用集含其名才装载(开关语义与内置表一致,见 plugins.pushGates)。
const bundled_exts = [_]struct { name: []const u8, gate: []const u8 = "", src: []const u8 }{
    .{ .name = "usage-ledger.js", .gate = "usage-ledger", .src = @embedFile("embedded/extensions/usage-ledger.js") },
    .{ .name = "web-search.js", .gate = "web-search", .src = @embedFile("embedded/extensions/web-search.js") },
    .{ .name = "artifact-store.js", .gate = "artifact-store", .src = @embedFile("embedded/extensions/artifact-store.js") },
};

var gate_names: []const []const u8 = &.{};
var saved_cfg: ?[]u8 = null;
var saved_cwd: ?[]u8 = null;

/// 内嵌门控:传入启用的插件名(静态串,dupe 容器;plugins.enabledNamesList 供)。
pub fn setGates(names: []const []const u8) void {
    if (!enabled) return;
    mu.lockUncancelable(util.io);
    defer mu.unlock(util.io);
    const a = gpa orelse return;
    if (gate_names.len > 0) a.free(gate_names);
    gate_names = a.dupe([]const u8, names) catch &.{};
}

fn gateOn(name: []const u8) bool {
    for (gate_names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// 用上次 loadExtensions 的两项目重扫(开关抽离件后由 plugins.refreshExtracted 调)。
pub fn reloadSaved() void {
    if (!enabled) return;
    mu.lockUncancelable(util.io);
    const a = gpa orelse {
        mu.unlock(util.io);
        return;
    };
    const cd = if (saved_cfg) |s| a.dupe(u8, s) catch null else null;
    const cw = if (saved_cwd) |s| a.dupe(u8, s) catch null else null;
    mu.unlock(util.io);
    defer if (cd) |s| a.free(s);
    defer if (cw) |s| a.free(s);
    if (cd) |d| reload(d, cw orelse "");
}

fn dirHasFile(path: ?[]const u8, name: []const u8) bool {
    const p = path orelse return false;
    var d = std.Io.Dir.cwd().openDir(util.io, p, .{ .iterate = true }) catch return false;
    defer d.close(util.io);
    var it = d.iterate();
    while (it.next(util.io) catch null) |ent| {
        if (ent.kind == .file and std.mem.eql(u8, ent.name, name)) return true;
    }
    return false;
}

/// 内嵌件求值:源在二进制里,无盘读/TS 剥;模块判定同 evalFile。
fn evalBundled(name: []const u8, src: []const u8) bool {
    const ctx_ = ctx orelse return false;
    const a = gpa orelse return false;
    if (src.len == 0) return true;
    const src_z = a.dupeZ(u8, src) catch return false;
    defer a.free(src_z);
    const label = std.fmt.allocPrintSentinel(a, "<embedded:{s}>", .{name}, 0) catch return false;
    defer a.free(label);
    if (isModule(name, src)) return evalModule(label.ptr, src_z.ptr, src.len);
    const v = c.JS_Eval(ctx_, src_z.ptr, @intCast(src.len), label.ptr, c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(v)) {
        reportEx(ctx_, label);
        c.JS_FreeValue(ctx_, v);
        return false;
    }
    c.JS_FreeValue(ctx_, v);
    drainJobs();
    return true;
}

fn loadDir(path: []const u8) void {
    var d = std.Io.Dir.cwd().openDir(util.io, path, .{ .iterate = true }) catch return;
    defer d.close(util.io);
    var names = std.array_list.Managed([]u8).init(gpa.?);
    defer {
        for (names.items) |n| gpa.?.free(n);
        names.deinit();
    }
    var it = d.iterate();
    while (it.next(util.io) catch null) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.name, ".js") and !std.mem.endsWith(u8, ent.name, ".mjs") and !std.mem.endsWith(u8, ent.name, ".ts") and !std.mem.endsWith(u8, ent.name, ".mts") and !std.mem.endsWith(u8, ent.name, ".cts")) continue;
        const full = util.joinPath(gpa.?, path, ent.name) catch continue;
        names.append(full) catch {
            gpa.?.free(full);
            continue;
        };
    }
    // 字典序加载:同名/顺序可预期。
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    for (names.items) |full| {
        if (evalFile(full)) loaded_files += 1 else load_errors += 1;
    }
}

/// 发现并加载所有扩展:~/.piz/extensions/*.js,然后 <cwd>/.piz/extensions/*.js。
/// 完成后把 JS 注册表物化到 Zig 侧(jsTools()/jsCommands())。
pub fn loadExtensions(cfg_dir: []const u8, cwd: []const u8) void {
    if (!enabled) return;
    mu.lockUncancelable(util.io);
    defer mu.unlock(util.io);
    if (rt == null) return;
    const a = gpa.?;
    // 存档装载目,reloadSaved 复用(开关抽离件后无 cwd 在手也能重扫)。
    if (saved_cfg) |s| a.free(s);
    saved_cfg = a.dupe(u8, cfg_dir) catch null;
    if (saved_cwd) |s| a.free(s);
    saved_cwd = a.dupe(u8, cwd) catch null;
    const user_dir = util.joinPath(a, cfg_dir, "extensions") catch null;
    defer if (user_dir) |p| a.free(p);
    const proj_dir = if (cwd.len > 0) (util.joinPath(a, cwd, ".piz/extensions") catch null) else null;
    defer if (proj_dir) |p| a.free(p);
    // 内嵌档先行;gate 未开或同名见于用户/项目目则跳过。
    for (bundled_exts) |b| {
        if (b.gate.len > 0 and !gateOn(b.gate)) continue;
        if (dirHasFile(user_dir, b.name) or dirHasFile(proj_dir, b.name)) continue;
        if (evalBundled(b.name, b.src)) loaded_files += 1 else load_errors += 1;
    }
    if (user_dir) |p| loadDir(p);
    if (proj_dir) |p| loadDir(p);
    refreshRegistry();
}

fn freeRegistry() void {
    const a = gpa orelse return;
    for (js_tools) |t| {
        a.free(t.name);
        a.free(t.desc);
        a.free(t.schema);
    }
    if (js_tools.len > 0) a.free(js_tools);
    js_tools = &.{};
    if (js_tool_defs.len > 0) a.free(js_tool_defs);
    js_tool_defs = &.{};
    for (js_commands) |cm| {
        a.free(cm.name);
        a.free(cm.desc);
    }
    if (js_commands.len > 0) a.free(js_commands);
    js_commands = &.{};
}

fn refreshRegistry() void {
    // 重刷前先放旧注册表(loadExtensions 幂等可重入)。
    freeRegistry();
    var arena_inst = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    if (callBridge(arena, "toolsJson", &.{})) |json| parseTools(arena, json);
    if (callBridge(arena, "commandsJson", &.{})) |json| parseCommands(arena, json);
    // 事件在场缓存一次拿齐(同一把锁内)。
    h_tool_call = bridgeHas(arena, "tool_call");
    h_tool_result = bridgeHas(arena, "tool_result");
    h_session_start = bridgeHas(arena, "session_start");
    h_agent_end = bridgeHas(arena, "agent_end");
}

fn bridgeHas(arena: std.mem.Allocator, ev: []const u8) bool {
    const r = callBridge(arena, "has", &.{ev}) orelse return false;
    return std.mem.eql(u8, r, "true");
}

/// parse_arena:JSON 树用完即弃;注册表字符串 dupe 到 gpa。
fn parseTools(parse_arena: std.mem.Allocator, json: []const u8) void {
    const a = gpa.?;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, parse_arena, json, .{}) catch return;
    if (parsed != .array) return;
    var list = std.array_list.Managed(JsTool).init(a);
    for (parsed.array.items) |item| {
        if (item != .object) continue;
        const name = if (item.object.get("name")) |v| (if (v == .string) v.string else "") else "";
        if (name.len == 0) continue;
        const desc = if (item.object.get("description")) |v| (if (v == .string) v.string else "") else "";
        var schema: []const u8 = "";
        if (item.object.get("schema")) |v| {
            if (v == .object) {
                schema = std.json.Stringify.valueAlloc(a, v, .{}) catch "";
            }
        }
        list.append(.{
            .name = a.dupe(u8, name) catch continue,
            .desc = a.dupe(u8, desc) catch continue,
            .schema = if (schema.len > 0) schema else a.dupe(u8, "") catch continue,
        }) catch continue;
    }
    js_tools = list.toOwnedSlice() catch &.{};
    // 平行 Tool 表:ctx_handler 挂 marker,runToolSlot 认得并改走 runJsTool(name 从 call 取)。
    var defs = std.array_list.Managed(toolsmod.Tool).init(a);
    for (js_tools) |t| {
        defs.append(.{
            .name = t.name,
            .desc = t.desc,
            .schema = if (t.schema.len > 0) t.schema else toolsmod.EMPTY_SCHEMA,
            .handler = struct {
                fn unreachable_(arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
                    _ = arena;
                    _ = args;
                    return error.JsToolMisrouted;
                }
            }.unreachable_,
            .ctx_handler = toolEntryMarker,
        }) catch continue;
    }
    js_tool_defs = defs.toOwnedSlice() catch &.{};
}

fn parseCommands(parse_arena: std.mem.Allocator, json: []const u8) void {
    const a = gpa.?;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, parse_arena, json, .{}) catch return;
    if (parsed != .array) return;
    var list = std.array_list.Managed(JsCommand).init(a);
    for (parsed.array.items) |item| {
        if (item != .object) continue;
        const name = if (item.object.get("name")) |v| (if (v == .string) v.string else "") else "";
        if (name.len == 0) continue;
        const desc = if (item.object.get("description")) |v| (if (v == .string) v.string else "") else "";
        list.append(.{
            .name = a.dupe(u8, name) catch continue,
            .desc = a.dupe(u8, desc) catch continue,
        }) catch continue;
    }
    js_commands = list.toOwnedSlice() catch &.{};
}

pub fn jsTools() []const JsTool {
    return js_tools;
}

pub fn jsCommands() []const JsCommand {
    return js_commands;
}

pub fn loadedCount() usize {
    return loaded_files;
}

pub fn loadErrorCount() usize {
    return load_errors;
}

pub fn hasHandlers(event: []const u8) bool {
    if (!enabled) return false;
    if (rt == null) return false;
    var arena_inst = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    mu.lockUncancelable(util.io);
    defer mu.unlock(util.io);
    const r = callBridge(arena, "has", &.{event}) orelse return false;
    return std.mem.eql(u8, r, "true");
}

/// 触发事件。payload_json 为空串按 {} 处理。返回最后一个非 undefined
/// 处理结果的 JSON 串(dupe 到 arena);无处理器/无返回 = null。
pub fn emit(arena: std.mem.Allocator, event: []const u8, payload_json: []const u8) ?[]const u8 {
    if (!enabled) return null;
    if (rt == null) return null;
    mu.lockUncancelable(util.io);
    defer mu.unlock(util.io);
    return callBridge(arena, "emit", &.{ event, payload_json });
}

/// tool_call 事件便捷封装:返回 block 原因(null = 放行)。
pub fn emitToolCall(arena: std.mem.Allocator, name: []const u8, args_json: []const u8) ?[]const u8 {
    if (!enabled or rt == null or !h_tool_call) return null;
    const payload = std.json.Stringify.valueAlloc(arena, .{ .toolName = name, .inputRaw = args_json }, .{}) catch return null;
    const out = emit(arena, "tool_call", payload) orelse return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{}) catch return null;
    if (parsed != .object) return null;
    const blk = if (parsed.object.get("block")) |v| v == .bool and v.bool else false;
    if (!blk) return null;
    if (parsed.object.get("reason")) |v| {
        if (v == .string and v.string.len > 0) return v.string;
    }
    return "blocked by js extension";
}

/// tool_result 事件:handler 返 {replace} 则替换输出(artifact 外置等),多 handler 后者胜。
/// 全文不截 —— 外置正是为大件;无 handler 时 h_tool_result 旗标短路,不进 JS。
pub fn emitToolResult(arena: std.mem.Allocator, name: []const u8, content: []const u8) ?[]const u8 {
    if (!enabled or rt == null or !h_tool_result) return null;
    const payload = std.json.Stringify.valueAlloc(arena, .{ .toolName = name, .output = content }, .{}) catch return null;
    const out = emit(arena, "tool_result", payload) orelse return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{}) catch return null;
    if (parsed != .object) return null;
    if (parsed.object.get("replace")) |v| {
        if (v == .string) return v.string;
    }
    return null;
}

/// session_start 是否有人听(供调用方省 payload 构造)。
pub fn wantsSessionStart() bool {
    return enabled and rt != null and h_session_start;
}

/// agent_end 事件:回合收口(text = 最后一条 assistant 正文,可空)。只发不收。
pub const AgentEndInfo = struct {
    text: []const u8 = "",
    model: []const u8 = "",
    cwd: []const u8 = "",
    config_dir: []const u8 = "",
    ts: i64 = 0,
    has_usage: bool = false,
    in: u64 = 0,
    out: u64 = 0,
    cr: u64 = 0,
    cw: u64 = 0,
    usd: f64 = 0,
};

const AgentEndUsage = struct { in: u64 = 0, out: u64 = 0, cr: u64 = 0, cw: u64 = 0, usd: f64 = 0 };

/// agent_end:正文 + usage 载荷(无用量则 usage=null,插件自跳)。
pub fn emitAgentEnd(arena: std.mem.Allocator, info: AgentEndInfo) void {
    if (!enabled or rt == null or !h_agent_end) return;
    const clipped = if (info.text.len > 8192) info.text[0..8192] else info.text;
    const usage: ?AgentEndUsage = if (info.has_usage) .{
        .in = info.in,
        .out = info.out,
        .cr = info.cr,
        .cw = info.cw,
        .usd = info.usd,
    } else null;
    const payload = std.json.Stringify.valueAlloc(arena, .{
        .text = clipped,
        .model = info.model,
        .cwd = info.cwd,
        .config_dir = info.config_dir,
        .ts = info.ts,
        .usage = usage,
    }, .{}) catch return;
    _ = emit(arena, "agent_end", payload);
}

/// 热重载:重 eval prelude(JS 侧 handlers/tools/commands 清零,扩展全局态随之归零)
/// 再重扫两处扩展目。引擎/ctx 不动;sucrase 全局保留。失败打 stderr,不致命。
pub fn reload(cfg_dir: []const u8, cwd: []const u8) void {
    if (!enabled) return;
    {
        mu.lockUncancelable(util.io);
        defer mu.unlock(util.io);
        const ctx_ = ctx orelse return;
        const v = c.JS_Eval(ctx_, PRELUDE.ptr, PRELUDE.len, "<prelude>", c.JS_EVAL_TYPE_GLOBAL);
        if (c.JS_IsException(v)) reportEx(ctx_, "<prelude>");
        c.JS_FreeValue(ctx_, v);
        drainJobs();
    }
    loadExtensions(cfg_dir, cwd);
}

/// marker:JS 工具的 Tool.ctx_handler 占位 —— runToolSlot 凭它改走 runJsTool。
/// 直接被调 = 路由错了。
pub fn toolEntryMarker(host_ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    _ = host_ctx;
    _ = arena;
    _ = args;
    return error.JsToolMisrouted;
}

/// 查 JS 注册工具(稳定指针;空表/未开 = null)。
pub fn findTool(name: []const u8) ?*const toolsmod.Tool {
    if (!enabled) return null;
    for (js_tool_defs) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// JS 工具定义追加进模型请求(allow 非空时同名过滤,与插件同口径)。
pub fn appendToolDefs(allow: []const []const u8, out: *std.array_list.Managed(aimod.ToolDef)) !void {
    if (!enabled) return;
    for (js_tool_defs) |*t| {
        if (allow.len > 0) {
            var ok = false;
            for (allow) |n| {
                if (std.mem.eql(u8, n, t.name)) {
                    ok = true;
                    break;
                }
            }
            if (!ok) continue;
        }
        try out.append(.{ .name = t.name, .desc = t.desc, .schema = t.schema });
    }
}

/// 执行 JS 工具并产出 Result。{error} → is_error。
pub fn runJsTool(alloc: std.mem.Allocator, name: []const u8, args_json: []const u8) !toolsmod.Result {
    var arena_inst = std.heap.ArenaAllocator.init(alloc);
    defer arena_inst.deinit();
    const json = callTool(arena_inst.allocator(), name, args_json) orelse
        return .{ .content = try alloc.dupe(u8, "js runtime unavailable"), .is_error = true };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena_inst.allocator(), json, .{}) catch
        return .{ .content = try alloc.dupe(u8, json), .is_error = false };
    if (parsed != .object) return .{ .content = try alloc.dupe(u8, json), .is_error = false };
    if (parsed.object.get("error")) |v| {
        if (v == .string) return .{ .content = try alloc.dupe(u8, v.string), .is_error = true };
    }
    if (parsed.object.get("content")) |v| {
        if (v == .string) return .{ .content = try alloc.dupe(u8, v.string), .is_error = false };
    }
    return .{ .content = try alloc.dupe(u8, json), .is_error = false };
}

/// 执行 JS 注册工具。返回 JSON:{content}|{error}(dupe 到 arena)。
pub fn callTool(arena: std.mem.Allocator, name: []const u8, args_json: []const u8) ?[]const u8 {
    if (!enabled or rt == null) return null;
    mu.lockUncancelable(util.io);
    defer mu.unlock(util.io);
    return callBridge(arena, "callTool", &.{ name, args_json });
}

/// 执行 JS 注册命令。未注册 = null;输出串(可空)或 {error} JSON。
pub fn runCommand(arena: std.mem.Allocator, name: []const u8, args: []const u8) ?[]const u8 {
    if (!enabled or rt == null) return null;
    mu.lockUncancelable(util.io);
    defer mu.unlock(util.io);
    return callBridge(arena, "runCommand", &.{ name, args });
}

test "qjs bridge: load, events, tools, commands" {
    if (!enabled) return error.SkipZigTest;
    const t = std.testing;
    const a = t.allocator;
    deinit();
    init(a);
    try t.expect(rt != null);
    // 直接 eval 一段扩展脚本,不走文件系统
    mu.lockUncancelable(util.io);
    const src =
        \\piz.on("session_start", (e) => { piz.notify("hi " + e.cwd); });
        \\piz.on("tool_call", (e) => e.toolName === "bash" ? { block: true, reason: "no bash" } : undefined);
        \\piz.registerTool({ name: "greet", description: "greet", schema: { type: "object" },
        \\  execute: (args) => "hello " + (args.who || "world") });
        \\piz.registerCommand("wave", { description: "wave", handler: (args) => "waved " + args });
    ;
    const v = c.JS_Eval(ctx.?, src.ptr, src.len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
    try t.expect(!c.JS_IsException(v));
    c.JS_FreeValue(ctx.?, v);
    mu.unlock(util.io);
    refreshRegistryLockedForTest();
    // 注册表
    try t.expect(jsTools().len == 1);
    try t.expect(std.mem.eql(u8, jsTools()[0].name, "greet"));
    try t.expect(jsCommands().len == 1);
    // 事件
    try t.expect(hasHandlers("session_start"));
    try t.expect(!hasHandlers("nope"));
    var arena_inst = std.heap.ArenaAllocator.init(a);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const blocked = emitToolCall(arena, "bash", "{}");
    try t.expect(blocked != null);
    try t.expect(std.mem.eql(u8, blocked.?, "no bash"));
    try t.expect(emitToolCall(arena, "read", "{}") == null);
    // 工具
    const out = callTool(arena, "greet", "{\"who\":\"piz\"}").?;
    try t.expect(std.mem.indexOf(u8, out, "hello piz") != null);
    // 命令
    const cmd_out = runCommand(arena, "wave", "abc").?;
    try t.expect(std.mem.eql(u8, cmd_out, "waved abc"));
    try t.expect(runCommand(arena, "missing", "") == null);
    // notify 落账
    _ = emit(arena, "session_start", "{\"cwd\":\"/tmp\"}");
    try t.expect(last_notify != null);
    try t.expect(std.mem.indexOf(u8, last_notify.?, "hi /tmp") != null);
    deinit();
}

fn refreshRegistryLockedForTest() void {
    mu.lockUncancelable(util.io);
    defer mu.unlock(util.io);
    refreshRegistry();
}

test "qjs esm: module default export gets piz api" {
    if (!enabled) return error.SkipZigTest;
    const t = std.testing;
    const a = t.allocator;
    deinit();
    init(a);
    defer deinit();
    try t.expect(rt != null);
    const path = std.fmt.allocPrint(a, "/tmp/piz_jsrt_esm_{d}.mjs", .{std.os.linux.getpid()}) catch return error.SkipZigTest;
    defer a.free(path);
    defer std.Io.Dir.cwd().deleteFile(util.io, path) catch {};
    const src =
        \\export default function(pi) {
        \\  pi.registerCommand("esmcmd", { description: "d", handler: (x) => "esm:" + x });
        \\}
    ;
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = path, .data = src });
    mu.lockUncancelable(util.io);
    const ok = evalFile(path);
    mu.unlock(util.io);
    try t.expect(ok);
    mu.lockUncancelable(util.io);
    defer mu.unlock(util.io);
    refreshRegistry();
    var found = false;
    for (jsCommands()) |jc| {
        if (std.mem.eql(u8, jc.name, "esmcmd")) found = true;
    }
    try t.expect(found);
}

test "qjs settle: async handlers resolve synchronously" {
    if (!enabled) return error.SkipZigTest;
    const t = std.testing;
    const a = t.allocator;
    deinit();
    init(a);
    defer deinit();
    mu.lockUncancelable(util.io);
    const src =
        \\piz.registerCommand("ac", { handler: async (x) => "A:" + (await Promise.resolve(x)) });
        \\piz.registerTool({ name: "at", description: "d", schema: {}, execute: async (args) => "T:" + (await Promise.resolve(args.v || "")) });
    ;
    const v = c.JS_Eval(ctx.?, src.ptr, src.len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
    try t.expect(!c.JS_IsException(v));
    c.JS_FreeValue(ctx.?, v);
    mu.unlock(util.io);
    refreshRegistryLockedForTest();
    var arena_inst = util.Arena.init(a);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    try t.expectEqualStrings("A:xyz", runCommand(arena, "ac", "xyz").?);
    const out = callTool(arena, "at", "{\"v\":\"q\"}").?;
    try t.expect(std.mem.indexOf(u8, out, "T:q") != null);
}

test "qjs esm import: relative module loads" {
    if (!enabled) return error.SkipZigTest;
    const t = std.testing;
    const a = t.allocator;
    deinit();
    init(a);
    defer deinit();
    const base = std.fmt.allocPrint(a, "/tmp/piz_jsrt_imp_{d}", .{std.os.linux.getpid()}) catch return error.SkipZigTest;
    defer a.free(base);
    defer std.Io.Dir.cwd().deleteTree(util.io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(util.io, base);
    const util_p = try std.fmt.allocPrint(a, "{s}/dep.mjs", .{base});
    defer a.free(util_p);
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = util_p, .data = "export const tag = \"DEPOK\";\n" });
    const main_p = try std.fmt.allocPrint(a, "{s}/main.mjs", .{base});
    defer a.free(main_p);
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = main_p, .data =
        \\import { tag } from "./dep.mjs";
        \\export default function(pi) {
        \\  pi.registerCommand("depcmd", { handler: () => "tag=" + tag });
        \\}
    });
    mu.lockUncancelable(util.io);
    const ok = evalFile(main_p);
    mu.unlock(util.io);
    try t.expect(ok);
    refreshRegistryLockedForTest();
    var arena_inst = util.Arena.init(a);
    defer arena_inst.deinit();
    try t.expectEqualStrings("tag=DEPOK", runCommand(arena_inst.allocator(), "depcmd", "").?);
}

test "qjs ts: typescript extension strips and loads" {
    if (!enabled or !jsts_on) return error.SkipZigTest;
    const t = std.testing;
    const a = t.allocator;
    deinit();
    init(a);
    defer deinit();
    const path = std.fmt.allocPrint(a, "/tmp/piz_jsrt_ts_{d}.ts", .{std.os.linux.getpid()}) catch return error.SkipZigTest;
    defer a.free(path);
    defer std.Io.Dir.cwd().deleteFile(util.io, path) catch {};
    const src =
        \\interface Opt { v: string }
        \\export default function(pi: any) {
        \\  pi.registerCommand("tsc", { handler: (x: string) => "TS:" + (x as string) });
        \\}
    ;
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = path, .data = src });
    mu.lockUncancelable(util.io);
    const ok = evalFile(path);
    mu.unlock(util.io);
    try t.expect(ok);
    refreshRegistryLockedForTest();
    var arena_inst = util.Arena.init(a);
    defer arena_inst.deinit();
    try t.expectEqualStrings("TS:q", runCommand(arena_inst.allocator(), "tsc", "q").?);
}

test "qjs fs primitives: readFile/writeFile/env/cwd" {
    if (!enabled) return error.SkipZigTest;
    const t = std.testing;
    const a = t.allocator;
    deinit();
    init(a);
    defer deinit();
    mu.lockUncancelable(util.io);
    const src =
        \\const out = [];
        \\const wp = "/tmp/piz_jsrt_fs_" + String(Date.now()) + ".txt";
        \\out.push(piz.writeFile(wp, "fsok:" + piz.env("PIZ_TEST_MARKER")));
        \\out.push(piz.readFile(wp));
        \\out.push(piz.readFile("/definitely/missing") === null);
        \\out.push(typeof piz.cwd() === "string" && piz.cwd().length > 0);
        \\piz.registerCommand("fsprobe", { handler: () => out.join("|") });
    ;
    const v = c.JS_Eval(ctx.?, src.ptr, src.len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
    try t.expect(!c.JS_IsException(v));
    c.JS_FreeValue(ctx.?, v);
    mu.unlock(util.io);
    var arena_inst = util.Arena.init(a);
    defer arena_inst.deinit();
    const out = runCommand(arena_inst.allocator(), "fsprobe", "").?;
    try t.expect(std.mem.indexOf(u8, out, "true|fsok:") != null);
    try t.expect(std.mem.indexOf(u8, out, "|true|true") != null);
}

test "qjs agent_end: fires with last assistant text" {
    if (!enabled) return error.SkipZigTest;
    const t = std.testing;
    const a = t.allocator;
    deinit();
    init(a);
    defer deinit();
    mu.lockUncancelable(util.io);
    const src = "piz.on(\"agent_end\", (e) => piz.notify(\"AE:\" + e.text, \"info\"));";
    const v = c.JS_Eval(ctx.?, src.ptr, src.len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
    try t.expect(!c.JS_IsException(v));
    c.JS_FreeValue(ctx.?, v);
    mu.unlock(util.io);
    refreshRegistryLockedForTest();
    var arena_inst = util.Arena.init(a);
    defer arena_inst.deinit();
    emitAgentEnd(arena_inst.allocator(), .{ .text = "回合正文" });
    try t.expect(last_notify != null);
    try t.expectEqualStrings("[info] AE:回合正文", last_notify.?);
}

test "qjs bundled: usage-ledger 内嵌出厂,agent_end 携 usage 落账" {
    if (!enabled) return error.SkipZigTest;
    const t = std.testing;
    const a = t.allocator;
    deinit();
    init(a);
    defer deinit();
    const root = std.fmt.allocPrint(a, "/tmp/piz_jsrt_bund_{d}", .{std.os.linux.getpid()}) catch return error.SkipZigTest;
    defer a.free(root);
    defer std.Io.Dir.cwd().deleteTree(util.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(util.io, root);
    setGates(&.{"usage-ledger"});
    loadExtensions(root, "");
    try t.expect(hasHandlers("agent_end")); // 内嵌件在场(gate 已开)
    var arena_inst = util.Arena.init(a);
    defer arena_inst.deinit();
    emitAgentEnd(arena_inst.allocator(), .{
        .text = "ok",
        .model = "gpt-4o-mini",
        .cwd = "/proj",
        .config_dir = root,
        .ts = 123,
        .has_usage = true,
        .in = 12,
        .out = 3,
        .cr = 4,
        .cw = 1,
        .usd = 0.5,
    });
    const path = try std.fmt.allocPrint(a, "{s}/usage.jsonl", .{root});
    defer a.free(path);
    const got = try std.Io.Dir.cwd().readFileAlloc(util.io, path, a, .limited(4096));
    defer a.free(got);
    // 与原 Zig usage_log.appendTurn 行式逐字节一致
    try t.expectEqualStrings("{\"ts\":123,\"model\":\"gpt-4o-mini\",\"in\":12,\"out\":3,\"cr\":4,\"cw\":1,\"usd\":0.50000000,\"cwd\":\"/proj\"}\n", got);
    // 无 usage 不记
    emitAgentEnd(arena_inst.allocator(), .{ .text = "x", .config_dir = root });
    const got2 = try std.Io.Dir.cwd().readFileAlloc(util.io, path, a, .limited(4096));
    defer a.free(got2);
    try t.expectEqualStrings(got, got2);
}

test "qjs bundled override: 同名文件顶替内嵌件" {
    if (!enabled) return error.SkipZigTest;
    const t = std.testing;
    const a = t.allocator;
    deinit();
    init(a);
    defer deinit();
    const root = std.fmt.allocPrint(a, "/tmp/piz_jsrt_ovr_{d}", .{std.os.linux.getpid()}) catch return error.SkipZigTest;
    defer a.free(root);
    defer std.Io.Dir.cwd().deleteTree(util.io, root) catch {};
    const ext_dir = try std.fmt.allocPrint(a, "{s}/extensions", .{root});
    defer a.free(ext_dir);
    try std.Io.Dir.cwd().createDirPath(util.io, ext_dir);
    const op = try std.fmt.allocPrint(a, "{s}/usage-ledger.js", .{ext_dir});
    defer a.free(op);
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = op, .data = "piz.registerCommand(\"ovr\", { handler: () => \"OVR\" });\n" });
    setGates(&.{"usage-ledger"}); // gate 开但同名文件在,内嵌让位
    loadExtensions(root, "");
    var arena_inst = util.Arena.init(a);
    defer arena_inst.deinit();
    try t.expectEqualStrings("OVR", runCommand(arena_inst.allocator(), "ovr", "").?);
    // 内嵌 ledger 已让位:无 agent_end 手写者,发事件不落账
    emitAgentEnd(arena_inst.allocator(), .{ .text = "x", .config_dir = root, .has_usage = true, .in = 1 });
    const up = try std.fmt.allocPrint(a, "{s}/usage.jsonl", .{root});
    defer a.free(up);
    try t.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(util.io, up, a, .limited(4096)));
}

test "qjs appendFile 追加并新建" {
    if (!enabled) return error.SkipZigTest;
    const t = std.testing;
    const a = t.allocator;
    deinit();
    init(a);
    defer deinit();
    mu.lockUncancelable(util.io);
    const src =
        \\const wp = "/tmp/piz_jsrt_ap_" + String(Date.now()) + ".txt";
        \\piz.appendFile(wp, "a\n");
        \\piz.appendFile(wp, "b\n");
        \\piz.registerCommand("aprobe", { handler: () => piz.readFile(wp) });
    ;
    const v = c.JS_Eval(ctx.?, src.ptr, src.len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
    try t.expect(!c.JS_IsException(v));
    c.JS_FreeValue(ctx.?, v);
    mu.unlock(util.io);
    var arena_inst = util.Arena.init(a);
    defer arena_inst.deinit();
    try t.expectEqualStrings("a\nb\n", runCommand(arena_inst.allocator(), "aprobe", "").?);
}

test "qjs bundled gate: web-search 默认关,setGates 开后装载" {
    if (!enabled) return error.SkipZigTest;
    const t = std.testing;
    const a = t.allocator;
    deinit();
    init(a);
    defer deinit();
    const root = std.fmt.allocPrint(a, "/tmp/piz_jsrt_gate_{d}", .{std.os.linux.getpid()}) catch return error.SkipZigTest;
    defer a.free(root);
    defer std.Io.Dir.cwd().deleteTree(util.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(util.io, root);
    loadExtensions(root, "");
    try t.expect(findTool("web_search") == null); // 门控默认关
    try t.expect(!hasHandlers("agent_end")); // usage-ledger 亦带门,默认不在
    setGates(&.{ "usage-ledger", "web-search" });
    reloadSaved();
    try t.expect(hasHandlers("agent_end"));
    try t.expect(findTool("web_search") != null);
    try t.expect(findTool("fetch_url") != null);
    // 私网拦:safe fetch 拦 127.0.0.1,报错原文与原 Zig 工具一致
    const r = try runJsTool(a, "fetch_url", "{\"url\":\"http://127.0.0.1:5494/api/chat\"}");
    defer a.free(r.content);
    try t.expect(r.is_error);
    try t.expect(std.mem.indexOf(u8, r.content, "blocked private or local address") != null);
    // 未配端点:web_search 报配置指引(假定测试环境未设 PIZ_WEB_SEARCH_URL)
    const r2 = try runJsTool(a, "web_search", "{\"query\":\"zig\"}");
    defer a.free(r2.content);
    try t.expect(r2.is_error);
    try t.expect(std.mem.indexOf(u8, r2.content, "PIZ_WEB_SEARCH_URL") != null);
    // 门控件同享同名覆写
    const ext_dir = try std.fmt.allocPrint(a, "{s}/extensions", .{root});
    defer a.free(ext_dir);
    try std.Io.Dir.cwd().createDirPath(util.io, ext_dir);
    const op = try std.fmt.allocPrint(a, "{s}/web-search.js", .{ext_dir});
    defer a.free(op);
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = op, .data = "piz.registerCommand(\"wovr\", { handler: () => \"WOVR\" });\n" });
    reloadSaved();
    try t.expect(findTool("web_search") == null); // 内嵌让位
    var arena_inst = util.Arena.init(a);
    defer arena_inst.deinit();
    try t.expectEqualStrings("WOVR", runCommand(arena_inst.allocator(), "wovr", "").?);
}

test "qjs tool_result replace:artifact-store 外置大件,小件/read/已置不动" {
    if (!enabled) return error.SkipZigTest;
    const t = std.testing;
    const a = t.allocator;
    deinit();
    init(a);
    defer deinit();
    const root = std.fmt.allocPrint(a, "/tmp/piz_jsrt_art_{d}", .{std.os.linux.getpid()}) catch return error.SkipZigTest;
    defer a.free(root);
    defer std.Io.Dir.cwd().deleteTree(util.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(util.io, root);
    setGates(&.{"artifact-store"});
    loadExtensions(root, "");
    try t.expect(hasHandlers("tool_result"));
    var arena_inst = util.Arena.init(a);
    defer arena_inst.deinit();
    const ar = arena_inst.allocator();
    // 小件不改写
    try t.expect(emitToolResult(ar, "bash", "small") == null);
    // read 系跳过
    const big = try ar.dupe(u8, "x" ** (8 * 1024));
    try t.expect(emitToolResult(ar, "read", big) == null);
    // 大件外置:引用式替换 + 文件真在
    const repl = emitToolResult(ar, "bash", big).?;
    try t.expect(std.mem.indexOf(u8, repl, "[Artifact stored: ") != null);
    try t.expect(std.mem.indexOf(u8, repl, "(8192 bytes)") != null);
    try t.expect(std.mem.indexOf(u8, repl, "truncated; read the artifact file") != null);
    const ps = std.mem.indexOf(u8, repl, "stored: ").? + 8;
    const pe = std.mem.indexOfScalar(u8, repl[ps..], ' ').? + ps;
    const stored = try std.Io.Dir.cwd().readFileAlloc(util.io, repl[ps..pe], ar, .limited(64 * 1024));
    try t.expectEqualStrings(big, stored);
    // 已含标记不重复外置
    try t.expect(emitToolResult(ar, "bash", repl) == null);
    // CJK 边界:预览退到字符边界,整链合法 UTF-8
    const zh = try ar.dupe(u8, "x" ++ "// 中文注释行填充凑长\n" ** 300);
    const zrepl = emitToolResult(ar, "bash", zh).?;
    try t.expect(std.unicode.utf8ValidateSlice(zrepl));
}

test "qjs bundled web-search: 内部函数探针(整形/编码/HTML 抽文/状态)" {
    if (!enabled) return error.SkipZigTest;
    const t = std.testing;
    const a = t.allocator;
    deinit();
    init(a);
    defer deinit();
    mu.lockUncancelable(util.io);
    const src = @embedFile("embedded/extensions/web-search.js") ++
        "piz.registerCommand(\"t_enc\", { handler: (x) => urlEncode(x) });\n" ++
        "piz.registerCommand(\"t_html\", { handler: (x) => htmlToText(x) });\n" ++
        "piz.registerCommand(\"t_shape\", { handler: (x) => shapeSearchResults(x, \"zig\") });\n" ++
        "piz.registerCommand(\"t_status\", { handler: () => webStatus() });\n";
    const v = c.JS_Eval(ctx.?, src.ptr, src.len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
    try t.expect(!c.JS_IsException(v));
    c.JS_FreeValue(ctx.?, v);
    mu.unlock(util.io);
    var arena_inst = util.Arena.init(a);
    defer arena_inst.deinit();
    const ar = arena_inst.allocator();
    try t.expectEqualStrings("zig%200.16", runCommand(ar, "t_enc", "zig 0.16").?);
    const html = runCommand(ar, "t_html", "<html><head><title>x</title></head><body><h1>Hello</h1><p>world &amp; zig</p><script>bad()</script></body></html>").?;
    try t.expect(std.mem.indexOf(u8, html, "Hello") != null);
    try t.expect(std.mem.indexOf(u8, html, "world & zig") != null);
    try t.expect(std.mem.indexOf(u8, html, "bad()") == null);
    try t.expect(std.mem.indexOf(u8, html, "<") == null);
    const shaped = runCommand(ar, "t_shape", "{\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\",\"content\":\"A programming language.\"}]}").?;
    try t.expect(std.mem.indexOf(u8, shaped, "Zig") != null);
    try t.expect(std.mem.indexOf(u8, shaped, "https://ziglang.org") != null);
    try t.expect(std.mem.indexOf(u8, shaped, "fetch_url") != null);
    try t.expect(std.mem.indexOf(u8, runCommand(ar, "t_status", "").?, "usage: /web") != null);
}

test "qjs reload: registry resets, no double registration" {
    if (!enabled) return error.SkipZigTest;
    const t = std.testing;
    const a = t.allocator;
    deinit();
    init(a);
    defer deinit();
    const root = std.fmt.allocPrint(a, "/tmp/piz_jsrt_rl_{d}", .{std.os.linux.getpid()}) catch return error.SkipZigTest;
    defer a.free(root);
    defer std.Io.Dir.cwd().deleteTree(util.io, root) catch {};
    const ext_dir = try std.fmt.allocPrint(a, "{s}/extensions", .{root});
    defer a.free(ext_dir);
    try std.Io.Dir.cwd().createDirPath(util.io, ext_dir);
    const pa = try std.fmt.allocPrint(a, "{s}/a.js", .{ext_dir});
    defer a.free(pa);
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = pa, .data =
        \\piz.registerCommand("cmdA", { handler: () => "A" });
        \\piz.on("tool_call", () => undefined);
    });
    reload(root, "");
    try t.expect(h_tool_call);
    try t.expect(js_commands.len == 1);
    // 换装:删 a.js,加 b.js
    try std.Io.Dir.cwd().deleteFile(util.io, pa);
    const pb = try std.fmt.allocPrint(a, "{s}/b.js", .{ext_dir});
    defer a.free(pb);
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = pb, .data =
        \\piz.registerCommand("cmdB", { handler: () => "B" });
    });
    reload(root, "");
    try t.expect(!h_tool_call); // 旧事件处理器清零
    try t.expect(js_commands.len == 1); // cmdA 不在了,无双注册
    var arena_inst = util.Arena.init(a);
    defer arena_inst.deinit();
    try t.expectEqualStrings("B", runCommand(arena_inst.allocator(), "cmdB", "").?);
    try t.expect(runCommand(arena_inst.allocator(), "cmdA", "") == null);
}
