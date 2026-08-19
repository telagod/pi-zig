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
const aimod = @import("ai.zig");

pub const enabled = build_options.quickjs;

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

/// JS prelude:注册表全部在 JS 侧,Zig 只供两个 host 原语与四个内省入口。
const PRELUDE =
    \\globalThis.piz = (() => {
    \\  const handlers = Object.create(null);
    \\  const tools = [];
    \\  const commands = Object.create(null);
    \\  const api = {
    \\    on(ev, fn) { (handlers[ev] || (handlers[ev] = [])).push(fn); },
    \\    registerTool(def) { if (def && def.name) tools.push(def); },
    \\    registerCommand(name, def) { if (name) commands[name] = def || {}; },
    \\    notify(msg, level) { __piz_host_notify(String(msg), String(level || "info")); },
    \\    confirm(msg) { return !!__piz_host_confirm(String(msg)); },
    \\  };
    \\  Object.defineProperty(globalThis, "__piz", { value: {
    \\    emit(ev, json) {
    \\      const hs = handlers[ev];
    \\      if (!hs || !hs.length) return undefined;
    \\      let payload;
    \\      try { payload = json ? JSON.parse(json) : {}; } catch (_) { payload = {}; }
    \\      let out;
    \\      for (const h of hs) {
    \\        try { const r = h(payload, api); if (r !== undefined) out = r; }
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
    \\        const r = t.execute(args, api);
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
    \\      try { const r = fn(args || "", api); return r === undefined || r === null ? "" : String(r); }
    \\      catch (e) { return JSON.stringify({ error: String(e && (e.stack || e.message) || e) }); }
    \\    },
    \\  }, enumerable: false });
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

/// 取 globalThis.__piz 上的函数并调用,返回值转 Zig 串(dupe 到 arena)。
/// 无此函数/异常/undefined 一律回 null。
fn callBridge(arena: std.mem.Allocator, name: []const u8, args: []const []const u8) ?[]const u8 {
    const ctx_ = ctx orelse return null;
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
    if (c.JS_IsUndefined(ret) or c.JS_IsNull(ret)) return null;
    const s = c.JS_ToCString(ctx_, ret);
    if (s == null) return null;
    defer c.JS_FreeCString(ctx_, s);
    const span = std.mem.span(s);
    if (span.len > MAX_RET) return null;
    return arena.dupe(u8, span) catch null;
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
    // host 原语
    const global = c.JS_GetGlobalObject(ctx.?);
    defer c.JS_FreeValue(ctx.?, global);
    const nf = c.JS_NewCFunction(ctx.?, hostNotify, "__piz_host_notify", 2);
    _ = c.JS_SetPropertyStr(ctx.?, global, "__piz_host_notify", nf);
    const cf = c.JS_NewCFunction(ctx.?, hostConfirm, "__piz_host_confirm", 1);
    _ = c.JS_SetPropertyStr(ctx.?, global, "__piz_host_confirm", cf);
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
    }
    js_tools = &.{};
    js_commands = &.{};
    last_notify = null;
    loaded_files = 0;
    load_errors = 0;
    h_tool_call = false;
    h_tool_result = false;
    h_session_start = false;
    gpa = null;
}

fn evalFile(path: []const u8) bool {
    const ctx_ = ctx orelse return false;
    const a = gpa orelse return false;
    const src = std.Io.Dir.cwd().readFileAlloc(util.io, path, a, .limited(MAX_EXT_FILE)) catch return false;
    defer a.free(src);
    if (src.len == 0) return true;
    // 必须 NUL 后送:实测 quickjs-ng 词法器会瞥 input[len] 一眼 —— 非 NUL 结尾的
    // 堆缓冲按相邻字节随机报 "invalid UTF-8"/"unexpected token"(4/4 复现),
    // dupeZ 后 4/4 干净。len 不变,NUL 只是兜底界标。
    const src_z = a.dupeZ(u8, src) catch return false;
    defer a.free(src_z);
    const path_z = a.dupeZ(u8, path) catch return false;
    defer a.free(path_z);
    const v = c.JS_Eval(ctx_, src_z.ptr, @intCast(src.len), path_z.ptr, c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(v)) {
        var tmp = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer tmp.deinit();
        const msg = jsThrowToString(ctx_, tmp.allocator());
        std.debug.print("piz: extension {s}: {s}\n", .{ path, msg });
        c.JS_FreeValue(ctx_, v);
        return false;
    }
    c.JS_FreeValue(ctx_, v);
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
        if (!std.mem.endsWith(u8, ent.name, ".js")) continue;
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
    const user_dir = util.joinPath(a, cfg_dir, "extensions") catch null;
    defer if (user_dir) |p| a.free(p);
    if (user_dir) |p| loadDir(p);
    const proj_dir = if (cwd.len > 0) (util.joinPath(a, cwd, ".piz/extensions") catch null) else null;
    defer if (proj_dir) |p| a.free(p);
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

/// tool_result 事件:只发不收。内容截 8KB(整段输出进 JSON 太贵)。
pub fn emitToolResult(arena: std.mem.Allocator, name: []const u8, content: []const u8) void {
    if (!enabled or rt == null or !h_tool_result) return;
    const clipped = if (content.len > 8192) content[0..8192] else content;
    const payload = std.json.Stringify.valueAlloc(arena, .{ .toolName = name, .output = clipped }, .{}) catch return;
    _ = emit(arena, "tool_result", payload);
}

/// session_start 是否有人听(供调用方省 payload 构造)。
pub fn wantsSessionStart() bool {
    return enabled and rt != null and h_session_start;
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
