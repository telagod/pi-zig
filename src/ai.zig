// ai.zig — provider 客户端:openai-completions 与 anthropic-messages 双协议。
// 流式解析 + 工具调用累积 + 非流式回退 + HTTP 错误映射。
const std = @import("std");
const httpc = @import("httpc.zig");
const cfgmod = @import("config.zig");
const util = @import("util.zig");

pub const ToolCall = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    args: []const u8 = "", // JSON 字符串
};

/// 工具定义(发给 provider 的 tools 数组条目)。
/// schema 为 JSON Schema 字符串;空串退化为无参数对象。
pub const ToolDef = struct {
    name: []const u8,
    desc: []const u8,
    schema: []const u8 = "",
};

pub const Message = struct {
    role: []const u8, // system | user | assistant | tool
    content: []const u8,
    tool_call_id: ?[]const u8 = null, // role == tool 时
    tool_calls: ?[]const ToolCall = null, // role == assistant 时
    /// 会话树:消息 id 与父消息 id(落盘时由 Session 生成,可选字段)
    id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
    /// 图片附件(base64 数据 + mime + 像素尺寸)。协议只在 user/assistant
    /// 消息上支持 image block;tool 消息必须保持纯文本。
    /// 生命周期:与会话同寿(挂在会话 arena),不随单轮 arena 重置。
    image: ?[]const u8 = null,
    image_mime: ?[]const u8 = null,
    image_w: u32 = 0,
    image_h: u32 = 0,
};

pub const Usage = struct {
    input: ?u64 = null,
    output: ?u64 = null,
    /// 上下文缓存**命中**的 token。
    /// - OpenAI 兼容:`prompt_cache_hit_tokens`(deepseek)/ `prompt_tokens_details.cached_tokens`
    /// - Anthropic:`cache_read_input_tokens`
    ///
    /// 只用于展示(状态栏、web UI、`-o json`),**不参与压缩决策**。
    /// 压缩一定会改写历史开头、让前缀缓存失效,但压缩是为了不超窗 —— 超窗是硬
    /// 失败,缓存只是省钱。不能让省钱的考虑推翻防失败的机制。
    cache_read: ?u64 = null,
    /// 缓存**写入**的 token(Anthropic `cache_creation_input_tokens`)。
    /// 与 cache_read 分开记:写入按 1.25 倍基础价计费、读取按 0.1 倍,
    /// 混成一个数就看不出这次到底省了钱还是多花了钱。
    /// OpenAI 兼容侧不暴露写入量,那边恒为 null。
    cache_write: ?u64 = null,
};

pub const RunResult = struct {
    text: []const u8 = "", // 最终回复正文(不含推理)
    reasoning: []const u8 = "",
    tool_calls: []const ToolCall = &.{},
    usage: Usage = .{},
    finish_reason: []const u8 = "",
    /// 非 null 表示请求失败(HTTP 错误等)
    error_msg: ?[]const u8 = null,
    /// 被中止(on_abort 检查点或连接被打断):text 为已收集的 partial
    aborted: bool = false,
    /// 流在读到一半时断了(网络抖动、provider 掉线),**不是**用户主动中止。
    ///
    /// 与 `error_msg` 的区别:那表示整个请求失败、什么都没拿到;这表示已经
    /// 收到并显示给用户的内容是有效的,只是没收完。区分开才能保住 partial ——
    /// 原先这里直接 `return err`,用户屏幕上那半段回复会被丢弃,
    /// 下一轮模型也不知道自己说过什么。
    stream_interrupted: ?[]const u8 = null,
};

pub const Callbacks = struct {
    ctx: ?*anyopaque = null,
    on_text: ?*const fn (ctx: ?*anyopaque, text: []const u8) anyerror!void = null,
    on_reasoning: ?*const fn (ctx: ?*anyopaque, text: []const u8) anyerror!void = null,
    /// 注意:没有 on_tool_call。「工具要开始执行」是 agent 层的事实 ——
    /// 此刻 ai 层解析出的调用还没过权限与插件拦截,报出去就是假消息。
    /// 返回 true 请求中止:流式检查点(每 chunk)与读错误时判定;中止保留 partial text
    on_abort: ?*const fn (ctx: ?*anyopaque) bool = null,
    /// 流建立后通知(供中断时 shutdown 打断阻塞读)
    on_connect: ?*const fn (ctx: ?*anyopaque, stream: *httpc.Stream) void = null,
};

pub const Options = struct {
    max_tokens: u32 = 8192,
    /// `prompt_cache_key`(OpenAI Chat Completions / Responses):与前缀 hash
    /// 组合影响请求落到哪台机器,提高缓存命中率。官方文档明确它**取代** `user`
    /// 字段承担缓存路由职责。
    ///
    /// 只写在 OpenAI 路径 —— Anthropic Messages API 没有这个字段,靠显式
    /// `cache_control` 断点。DeepSeek 文档未列此字段但实测静默忽略(HTTP 200),
    /// 所以对 OpenAI 兼容端点无条件发是安全的。
    cache_key: ?[]const u8 = null,
    callbacks: Callbacks = .{},
    /// HTTP 重试策略(缺省开启;compact 等内部调用亦受益)。
    retry_policy: httpc.RetryPolicy = .{},
};

/// 把 ai.Callbacks.on_abort 适配成 httpc 的 AbortFn(退避等待期间可中断)。
fn abortTrampoline(ctx: ?*anyopaque) bool {
    const cbs: *const Callbacks = @ptrCast(@alignCast(ctx.?));
    return if (cbs.on_abort) |f| f(cbs.ctx) else false;
}

fn abortRequested(cbs: Callbacks) bool {
    return if (cbs.on_abort) |f| f(cbs.ctx) else false;
}

fn jstr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const val = v.object.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

/// 写工具参数 schema:空串退化为无参数对象。
/// schema 是编译期 JSON 字面量,原样嵌入(不重解析,零分配)。
fn writeSchema(writer: *std.Io.Writer, schema: []const u8) !void {
    if (schema.len == 0) {
        try writer.writeAll("{\"type\":\"object\",\"properties\":{}}");
        return;
    }
    try writer.writeAll(schema);
}

/// 把任意字节写成 JSON **字符串**。
///
/// 存在的理由:`std.json.Stringify.value` 对 `[]const u8` 的处理取决于内容是否
/// 合法 UTF-8 —— 合法则写字符串,不合法**静默退化成整数数组**。于是一份被切在
/// 汉字中间的工具输出会让请求体里出现 `"content":[91,65,114,...]`,provider
/// 直接 400(deepseek 原话:`invalid type: integer 91, expected
/// ChatCompletionRequestContentBlock`),而报错内容与真正的原因毫无关系。
///
/// 工具输出来自文件、命令 stdout、网络 —— 非法字节是常态而非异常,不能指望
/// 每个产出点都先自查。这里统一兜住:非法序列替换为 U+FFFD,永远写出字符串。
fn writeJsonText(writer: *std.Io.Writer, s: []const u8) !void {
    // 快路径:绝大多数内容是合法 UTF-8,直接交给 std(它也负责转义)。
    if (std.unicode.utf8ValidateSlice(s)) {
        try std.json.Stringify.value(s, .{}, writer);
        return;
    }
    // 慢路径:逐序列扫,合法的整段透出、非法字节替换。不逐字符分配。
    try writer.writeByte('"');
    var i: usize = 0;
    var run_start: usize = 0; // 待输出的合法段起点
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        const ok = n > 0 and i + n <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + n]);
        if (ok and !needsEscape(s[i])) {
            i += n;
            continue;
        }
        // 遇到需转义或非法字节:先把之前攒的合法段冲出去
        if (i > run_start) try writer.writeAll(s[run_start..i]);
        if (!ok) {
            try writer.writeAll("\u{fffd}");
            i += 1;
        } else {
            try writeEscaped(writer, s[i]);
            i += 1;
        }
        run_start = i;
    }
    if (i > run_start) try writer.writeAll(s[run_start..i]);
    try writer.writeByte('"');
}

/// JSON 字符串里必须转义的字节。
fn needsEscape(c: u8) bool {
    return c == '"' or c == '\\' or c < 0x20;
}

/// 写单个需转义字节的 JSON 形式。
fn writeEscaped(writer: *std.Io.Writer, c: u8) !void {
    switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0c => try writer.writeAll("\\f"),
        else => try writer.print("\\u{x:0>4}", .{c}),
    }
}

/// 序列化 OpenAI Responses API 请求体(input items 语义,与 Completions 不同)。
fn serializeResponses(
    alloc: std.mem.Allocator,
    model: []const u8,
    messages: []const Message,
    tools: []const ToolDef,
    max_tokens: u32,
) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    const writer = &aw.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"store\":false,\"max_output_tokens\":");
    try writer.print("{d}", .{max_tokens});
    if (tools.len > 0) {
        try writer.writeAll(",\"tools\":[");
        for (tools, 0..) |td, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"type\":\"function\",\"name\":");
            try std.json.Stringify.value(td.name, .{}, writer);
            try writer.writeAll(",\"description\":");
            try std.json.Stringify.value(td.desc, .{}, writer);
            try writer.writeAll(",\"parameters\":");
            try writeSchema(writer, td.schema);
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
    }
    // system 合并进顶层 instructions;其余进 input 数组
    var ins = std.Io.Writer.Allocating.init(alloc);
    defer ins.deinit();
    var have_ins = false;
    try writer.writeAll(",\"input\":[");
    var first = true;
    for (messages) |m| {
        if (std.mem.eql(u8, m.role, "system")) {
            if (have_ins) try ins.writer.writeAll("\n\n");
            try ins.writer.writeAll(m.content);
            have_ins = true;
            continue;
        }
        if (!first) try writer.writeByte(',');
        first = false;
        if (m.tool_calls) |tcs| {
            // assistant 的工具调用:每调用一个 function_call item
            for (tcs, 0..) |tc, j| {
                if (j > 0) try writer.writeByte(',');
                try writer.writeAll("{\"type\":\"function_call\",\"call_id\":");
                try std.json.Stringify.value(tc.id, .{}, writer);
                try writer.writeAll(",\"name\":");
                try std.json.Stringify.value(tc.name, .{}, writer);
                try writer.writeAll(",\"arguments\":");
                try std.json.Stringify.value(tc.args, .{}, writer);
                try writer.writeAll("}");
            }
        } else if (std.mem.eql(u8, m.role, "tool")) {
            try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
            try std.json.Stringify.value(m.tool_call_id orelse "", .{}, writer);
            try writer.writeAll(",\"output\":");
            try writeJsonText(writer, m.content);
            try writer.writeAll("}");
        } else if (m.image) |img| {
            try writer.writeAll("{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":");
            try writeJsonText(writer, m.content);
            try writer.writeAll("},{\"type\":\"input_image\",\"image_url\":\"data:");
            try writer.writeAll(m.image_mime orelse "image/png");
            try writer.writeAll(";base64,");
            try writer.writeAll(img);
            try writer.writeAll("\"}]}");
        } else if (std.mem.eql(u8, m.role, "assistant")) {
            try writer.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
            try writeJsonText(writer, m.content);
            try writer.writeAll("}]}");
        } else {
            try writer.writeAll("{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":");
            try writeJsonText(writer, m.content);
            try writer.writeAll("}]}");
        }
    }
    try writer.writeAll("]");
    if (have_ins) {
        try writer.writeAll(",\"instructions\":");
        try std.json.Stringify.value(ins.written(), .{}, writer);
    }
    try writer.writeAll("}");
    return aw.toOwnedSlice();
}

/// 序列化 OpenAI 兼容请求体。
fn serializeOpenAI(
    alloc: std.mem.Allocator,
    model: []const u8,
    messages: []const Message,
    tools: []const ToolDef,
    max_tokens: u32,
    cache_key: ?[]const u8,
) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    const writer = &aw.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"max_tokens\":");
    try writer.print("{d}", .{max_tokens});
    // prompt_cache_key:与前缀 hash 组合决定请求路由到哪台机器。同一工作目录
    // 的请求共享同一个长前缀,给相同的 key 能让它们落到同一台,命中率更高。
    if (cache_key) |k| {
        if (k.len > 0) {
            try writer.writeAll(",\"prompt_cache_key\":");
            try std.json.Stringify.value(k, .{}, writer);
        }
    }
    // tools 写在 messages 之前:静态部分在前、每轮变化的 messages 尾部在后。
    //
    // 注意 JSON 顶层字段顺序本身**不影响**缓存命中 —— OpenAI / DeepSeek 都是
    // 服务端反序列化后按自己的模板重组 prompt 再做前缀匹配,JSON object 无序。
    // 这里只是让字面顺序反映语义顺序,便于阅读。真正影响命中率的是:
    // (a) tools 数组**内部**顺序每轮必须一致(打乱就是另一个前缀);
    // (b) messages 只在尾部追加,不在中间插改。
    if (tools.len > 0) {
        try writer.writeAll(",\"tools\":[");
        for (tools, 0..) |td, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
            try std.json.Stringify.value(td.name, .{}, writer);
            try writer.writeAll(",\"description\":");
            try std.json.Stringify.value(td.desc, .{}, writer);
            try writer.writeAll(",\"parameters\":");
            try writeSchema(writer, td.schema);
            try writer.writeAll("}}");
        }
        try writer.writeAll("]");
    }
    try writer.writeAll(",\"messages\":[");
    for (messages, 0..) |m, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"role\":");
        try std.json.Stringify.value(m.role, .{}, writer);
        if (m.tool_calls) |tcs| {
            try writer.writeAll(",\"content\":null,\"tool_calls\":[");
            for (tcs, 0..) |tc, j| {
                if (j > 0) try writer.writeByte(',');
                try writer.writeAll("{\"id\":");
                try std.json.Stringify.value(tc.id, .{}, writer);
                try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                try std.json.Stringify.value(tc.name, .{}, writer);
                try writer.writeAll(",\"arguments\":");
                try std.json.Stringify.value(tc.args, .{}, writer);
                try writer.writeAll("}}");
            }
            try writer.writeAll("]}");
        } else if (m.image) |img| {
            // 带图消息:content 数组 [text, image_url](openai 协议)
            try writer.writeAll(",\"content\":[{\"type\":\"text\",\"text\":");
            try writeJsonText(writer, m.content);
            try writer.writeAll("},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
            try writer.writeAll(m.image_mime orelse "image/png");
            try writer.writeAll(";base64,");
            try writer.writeAll(img);
            try writer.writeAll("\"}}]");

            if (m.tool_call_id) |id| {
                try writer.writeAll(",\"tool_call_id\":");
                try std.json.Stringify.value(id, .{}, writer);
            }
            try writer.writeAll("}");
        } else {
            try writer.writeAll(",\"content\":");
            try writeJsonText(writer, m.content);

            if (m.tool_call_id) |id| {
                try writer.writeAll(",\"tool_call_id\":");
                try std.json.Stringify.value(id, .{}, writer);
            }
            try writer.writeAll("}");
        }
    }
    try writer.writeAll("]");
    try writer.writeAll("}");
    return aw.toOwnedSlice();
}

/// 序列化 Anthropic Messages 请求体。
fn serializeAnthropic(alloc: std.mem.Allocator, model: []const u8, messages: []const Message, tools: []const ToolDef, max_tokens: u32) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    const writer = &aw.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, writer);
    try writer.writeAll(",\"max_tokens\":");
    try writer.print("{d}", .{max_tokens});
    // tools 写在 system 之前,与 Anthropic 计算缓存前缀的语义顺序
    // (tools → system → messages)一致。服务端按语义位置处理,不看字面顺序,
    // 但写成一致的更好读。
    if (tools.len > 0) {
        try writer.writeAll(",\"tools\":[");
        for (tools, 0..) |td, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"name\":");
            try std.json.Stringify.value(td.name, .{}, writer);
            try writer.writeAll(",\"description\":");
            try std.json.Stringify.value(td.desc, .{}, writer);
            try writer.writeAll(",\"input_schema\":");
            try writeSchema(writer, td.schema);
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
    }
    // Anthropic 的系统提示走顶层 "system" 字段,不进 messages 数组。
    // 多条 system 消息(压缩摘要也是 system 角色)按顺序拼接成一段。
    // 漏掉这个字段等于把 AGENTS.md / memory.md / skills 索引全部丢弃 ——
    // 模型收不到项目规范却看不出任何报错,是最难察觉的一类 bug。
    //
    // 用**数组**形式而非纯字符串,因为只有内容块才能挂 cache_control。
    // 断点打在这里(而不是 tools 末尾)就够了:Anthropic 按
    // tools → system → messages 的顺序拼前缀,缓存的是「该块及其之前的全部内容」,
    // 所以 system 末尾的断点已经把 tools + system 整个前缀纳入。
    // 实测这部分是 3217 token/轮(系统提示 2153 + 工具定义 1064),8 轮重发 25.7K。
    {
        var sys = std.Io.Writer.Allocating.init(alloc);
        defer sys.deinit();
        for (messages) |m| {
            if (!std.mem.eql(u8, m.role, "system")) continue;
            if (sys.written().len > 0) try sys.writer.writeAll("\n\n");
            try sys.writer.writeAll(m.content);
        }
        if (sys.written().len > 0) {
            try writer.writeAll(",\"system\":[{\"type\":\"text\",\"text\":");
            try std.json.Stringify.value(sys.written(), .{}, writer);
            // ttl 省略 = 5 分钟。agent 的工具迭代间隔是秒级,5 分钟够用;
            // 1h TTL 写入要 2 倍价,只有长时间等用户输入才值得。
            try writer.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}}]");
        }
    }
    try writer.writeAll(",\"stream\":true,\"messages\":[");
    var first = true;
    for (messages) |m| {
        // anthropic:system 走顶层字段;tool 结果转为 user 消息 tool_result 块
        if (std.mem.eql(u8, m.role, "system")) continue;
        if (std.mem.eql(u8, m.role, "tool")) {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":");
            try std.json.Stringify.value(m.tool_call_id orelse "", .{}, writer);
            try writer.writeAll(",\"content\":");
            try writeJsonText(writer, m.content);
            try writer.writeAll("}]}");
            first = false;
            continue;
        }
        if (m.tool_calls) |tcs| {
            if (tcs.len == 0) continue;
            if (!first) try writer.writeByte(',');
            try writer.writeAll("{\"role\":\"assistant\",\"content\":[");
            if (m.content.len > 0) {
                try writer.writeAll("{\"type\":\"text\",\"text\":");
                try writeJsonText(writer, m.content);
                try writer.writeByte(',');
            }
            for (tcs, 0..) |tc, i| {
                if (i > 0 or m.content.len > 0) try writer.writeByte(',');
                try writer.writeAll("{\"type\":\"tool_use\",\"id\":");
                try std.json.Stringify.value(tc.id, .{}, writer);
                try writer.writeAll(",\"name\":");
                try std.json.Stringify.value(tc.name, .{}, writer);
                try writer.writeAll(",\"input\":");
                if (tc.args.len == 0) {
                    try writer.writeAll("{}");
                } else {
                    // args 是 JSON 字符串,原样嵌入(由模型生成,若非法则退化为字符串)
                    if (std.json.parseFromSliceLeaky(std.json.Value, alloc, tc.args, .{})) |v| {
                        try std.json.Stringify.value(v, .{}, writer);
                    } else |_| {
                        try std.json.Stringify.value(tc.args, .{}, writer);
                    }
                }
                try writer.writeAll("}");
            }
            try writer.writeAll("]}");
            first = false;
            continue;
        }
        if (!first) try writer.writeByte(',');
        try writer.writeAll("{\"role\":");
        try std.json.Stringify.value(m.role, .{}, writer);
        if (m.image) |img| {
            // 带图 user 消息:content 数组 [text, image block]
            try writer.writeAll(",\"content\":[{\"type\":\"text\",\"text\":");
            try writeJsonText(writer, m.content);
            try writer.writeAll("},{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
            try std.json.Stringify.value(m.image_mime orelse "image/png", .{}, writer);
            try writer.writeAll(",\"data\":\"");
            try writer.writeAll(img);
            try writer.writeAll("\"}}]}");
        } else {
            try writer.writeAll(",\"content\":");
            try writeJsonText(writer, m.content);
            try writer.writeAll("}");
        }
        first = false;
    }
    try writer.writeAll("]");
    if (tools.len > 0) {
        try writer.writeAll(",\"tools\":[");
        for (tools, 0..) |td, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"name\":");
            try std.json.Stringify.value(td.name, .{}, writer);
            try writer.writeAll(",\"description\":");
            try std.json.Stringify.value(td.desc, .{}, writer);
            try writer.writeAll(",\"input_schema\":");
            try writeSchema(writer, td.schema);
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
    }
    try writer.writeAll("}");
    return aw.toOwnedSlice();
}

const ToolAcc = struct {
    id: std.array_list.Managed(u8),
    name: std.array_list.Managed(u8),
    args: std.array_list.Managed(u8),
    started: bool = false,
    finished: bool = false,
};

fn emitCallback(cbs: Callbacks, cb: ?*const fn (ctx: ?*anyopaque, text: []const u8) anyerror!void, text: []const u8) !void {
    if (cb) |f| try f(cbs.ctx, text);
}

/// 正文 chunk 专用:模型把工具调用写成正文时(deepseek 漏 `<｜｜DSML｜｜` 这类
/// 特殊 token 字面量),标记之后的内容一律不外发。
///
/// 必须在流式层拦:文本是一边收一边打到 stdout 的,等整轮结束再判断已经晚了 ——
/// 标记早就印在用户屏幕上,收不回来。agent 层的重试负责让模型重答,这里只
/// 负责别把垃圾漏出去。
///
/// `accumulated` 是**含本 chunk**的全部正文,所以标记跨 chunk 拆开也能认出来。
fn emitText(cbs: Callbacks, accumulated: []const u8, chunk: []const u8) !void {
    const cut = textMarkerStart(accumulated) orelse {
        try emitCallback(cbs, cbs.on_text, chunk);
        return;
    };
    // 标记起点在本 chunk 之前 → 整块丢掉;落在本 chunk 内 → 只发前半截
    const chunk_start = accumulated.len - chunk.len;
    if (cut <= chunk_start) return;
    try emitCallback(cbs, cbs.on_text, accumulated[chunk_start..cut]);
}

/// 伪造工具调用标记的起始下标。同时匹配**前缀** —— 标记可能刚开始流,
/// 后半截还在下个 chunk 里,那时也必须立刻闭嘴。
fn textMarkerStart(text: []const u8) ?usize {
    var best: ?usize = null;
    for (TEXT_MARKERS) |m| {
        if (std.mem.indexOf(u8, text, m)) |i| {
            if (best == null or i < best.?) best = i;
            continue;
        }
        // 尾部是否是 m 的前缀(标记被 chunk 边界切断)
        const max = @min(m.len - 1, text.len);
        var n = max;
        while (n > 0) : (n -= 1) {
            if (std.mem.eql(u8, text[text.len - n ..], m[0..n])) {
                const i = text.len - n;
                if (best == null or i < best.?) best = i;
                break;
            }
        }
    }
    return best;
}

/// 与 agent.TEXT_TOOL_CALL_MARKERS 同一份清单(这里是流式层的副本 ——
/// ai 不依赖 agent,反向依赖会成环)。
const TEXT_MARKERS = [_][]const u8{
    "<｜｜DSML｜｜",
    "<|DSML|>",
    "<｜tool▁calls▁begin｜>",
    "<|tool_calls_begin|>",
};

/// 解析单个 OpenAI 流式 chunk,返回是否消耗。
fn parseOpenAIChunk(alloc: std.mem.Allocator, arena: std.mem.Allocator, chunk: []const u8, acc: *std.array_list.Managed(ToolAcc), cbs: Callbacks, out_text: *std.array_list.Managed(u8), out_reasoning: *std.array_list.Managed(u8), usage: *Usage, finish: *std.array_list.Managed(u8)) !void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, chunk, .{}) catch return;
    const v = root;
    if (v != .object) return;
    if (v.object.get("usage")) |u| {
        if (u == .object) {
            if (u.object.get("prompt_tokens")) |pt| {
                if (pt == .integer) usage.input = @intCast(pt.integer);
            }
            if (u.object.get("completion_tokens")) |ct| {
                if (ct == .integer) usage.output = @intCast(ct.integer);
            }
            if (u.object.get("total_tokens")) |tt| {
                if (tt == .integer and usage.input == null) usage.input = @intCast(tt.integer);
            }
            // 缓存命中(deepseek: prompt_cache_hit_tokens;openai: prompt_tokens_details.cached_tokens)
            if (u.object.get("prompt_cache_hit_tokens")) |ch| {
                if (ch == .integer) usage.cache_read = @intCast(ch.integer);
            }
            if (usage.cache_read == null) {
                if (u.object.get("prompt_tokens_details")) |pd| {
                    if (pd == .object) {
                        if (pd.object.get("cached_tokens")) |ct2| {
                            if (ct2 == .integer) usage.cache_read = @intCast(ct2.integer);
                        }
                    }
                }
            }
        }
    }
    const choices = v.object.get("choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) return;
    const choice = choices.array.items[0];
    if (choice != .object) return;
    if (choice.object.get("finish_reason")) |fr| {
        if (fr == .string) try finish.appendSlice(fr.string);
    }
    const delta = choice.object.get("delta") orelse return;
    if (delta != .object) return;
    if (delta.object.get("content")) |c| {
        if (c == .string and c.string.len > 0) {
            try out_text.appendSlice(c.string);
            try emitText(cbs, out_text.items, c.string);
        }
    }
    // 推理字段有两种叫法:DeepSeek 系用 reasoning_content,OpenRouter 等网关用 reasoning。
    // 实测某网关**同时发两个**且内容完全一致(1107 次全同),所以只能取其一 ——
    // 都累加会让推理文本翻倍。优先 reasoning_content,回退 reasoning。
    const reasoning_delta = delta.object.get("reasoning_content") orelse delta.object.get("reasoning");
    if (reasoning_delta) |rc| {
        if (rc == .string and rc.string.len > 0) {
            try out_reasoning.appendSlice(rc.string);
            try emitCallback(cbs, cbs.on_reasoning, rc.string);
        }
    }
    if (delta.object.get("tool_calls")) |tcs| {
        if (tcs != .array) return;
        for (tcs.array.items) |tc| {
            if (tc != .object) continue;
            const idx = if (tc.object.get("index")) |i| (if (i == .integer) @as(usize, @intCast(i.integer)) else 0) else 0;
            while (acc.items.len <= idx) {
                try acc.append(.{ .id = std.array_list.Managed(u8).init(alloc), .name = std.array_list.Managed(u8).init(alloc), .args = std.array_list.Managed(u8).init(alloc) });
            }
            const slot = &acc.items[idx];
            if (tc.object.get("id")) |id| {
                if (id == .string and slot.id.items.len == 0) try slot.id.appendSlice(id.string);
            }
            if (tc.object.get("function")) |f| {
                if (f == .object) {
                    if (f.object.get("name")) |n| {
                        if (n == .string and slot.name.items.len == 0) try slot.name.appendSlice(n.string);
                    }
                    if (f.object.get("arguments")) |a| {
                        if (a == .string) try slot.args.appendSlice(a.string);
                    }
                }
            }
            slot.started = true;
        }
    }
    _ = arena;
}

fn finalizeToolCalls(alloc: std.mem.Allocator, acc: *std.array_list.Managed(ToolAcc)) ![]ToolCall {
    var out = std.array_list.Managed(ToolCall).init(alloc);
    for (acc.items) |*slot| {
        if (!slot.started) continue;
        try out.append(.{
            .id = try slot.id.toOwnedSlice(),
            .name = try slot.name.toOwnedSlice(),
            .args = try slot.args.toOwnedSlice(),
        });
    }
    return out.toOwnedSlice();
}

fn freeToolAcc(acc: *std.array_list.Managed(ToolAcc)) void {
    for (acc.items) |*slot| {
        slot.id.deinit();
        slot.name.deinit();
        slot.args.deinit();
    }
    acc.deinit();
}

/// 解析 Responses API 的一个 SSE 事件。
/// 事件模型与 Completions 完全不同:文本走 response.output_text.delta,
/// 工具走 output_item.added + function_call_arguments.delta/done,
/// usage 与结束在 response.completed。
fn parseResponsesEvent(alloc: std.mem.Allocator, chunk: []const u8, acc: *std.array_list.Managed(ToolAcc), cbs: Callbacks, out_text: *std.array_list.Managed(u8), out_reasoning: *std.array_list.Managed(u8), usage: *Usage, finish: *std.array_list.Managed(u8), err_out: *std.array_list.Managed(u8)) !void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, chunk, .{}) catch return;
    const v = root;
    if (v != .object) return;
    const ty = if (v.object.get("type")) |t| (if (t == .string) t.string else "") else "";

    if (std.mem.eql(u8, ty, "response.output_text.delta")) {
        if (v.object.get("delta")) |d| {
            if (d == .string and d.string.len > 0) {
                try out_text.appendSlice(d.string);
                try emitText(cbs, out_text.items, d.string);
            }
        }
    } else if (std.mem.eql(u8, ty, "response.reasoning_summary_text.delta") or std.mem.eql(u8, ty, "response.reasoning_text.delta")) {
        // 推理摘要/思维链:展示用,不参与最终文本
        if (v.object.get("delta")) |d| {
            if (d == .string and d.string.len > 0) {
                try out_reasoning.appendSlice(d.string);
                try emitCallback(cbs, cbs.on_reasoning, d.string);
            }
        }
    } else if (std.mem.eql(u8, ty, "response.output_item.added")) {
        if (v.object.get("item")) |it| {
            if (it == .object) {
                if (it.object.get("type")) |it_t| {
                    if (it_t == .string and std.mem.eql(u8, it_t.string, "function_call")) {
                        const slot_idx = acc.items.len;
                        try acc.append(.{ .id = std.array_list.Managed(u8).init(alloc), .name = std.array_list.Managed(u8).init(alloc), .args = std.array_list.Managed(u8).init(alloc) });
                        const slot = &acc.items[slot_idx];
                        slot.started = true; // finalizeToolCalls 只收已开始的调用
                        if (it.object.get("call_id")) |id| {
                            if (id == .string) try slot.id.appendSlice(id.string);
                        }
                        if (it.object.get("name")) |n| {
                            if (n == .string) try slot.name.appendSlice(n.string);
                        }
                        // 有些实现直接把完整 arguments 放在 item 里
                        if (it.object.get("arguments")) |a| {
                            if (a == .string) try slot.args.appendSlice(a.string);
                        }
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, ty, "response.function_call_arguments.delta")) {
        if (v.object.get("delta")) |d| {
            if (d == .string and d.string.len > 0) {
                if (acc.items.len > 0) try acc.items[acc.items.len - 1].args.appendSlice(d.string);
            }
        }
    } else if (std.mem.eql(u8, ty, "response.function_call_arguments.done")) {
        // done 带全量 arguments —— 以它为准覆盖增量拼接(两全其美:只发 delta 的
        // 实现也能用,两者都发的实现拿全量)。
        if (v.object.get("arguments")) |a| {
            if (a == .string and acc.items.len > 0) {
                const slot = &acc.items[acc.items.len - 1];
                slot.args.clearRetainingCapacity();
                try slot.args.appendSlice(a.string);
            }
        }
    } else if (std.mem.eql(u8, ty, "response.completed")) {
        try finish.appendSlice("completed");
        if (v.object.get("response")) |r| {
            if (r == .object) {
                if (r.object.get("usage")) |u| {
                    parseResponsesUsage(u, usage);
                }
            }
        }
        if (usage.input == null) {
            if (v.object.get("usage")) |u| parseResponsesUsage(u, usage);
        }
    } else if (std.mem.eql(u8, ty, "response.failed")) {
        if (v.object.get("response")) |r| {
            if (r == .object) {
                if (r.object.get("error")) |e| {
                    if (e == .object) {
                        if (e.object.get("message")) |m| {
                            if (m == .string) try err_out.appendSlice(m.string);
                        }
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, ty, "error")) {
        if (v.object.get("message")) |m| {
            if (m == .string) try err_out.appendSlice(m.string);
        }
    }
}

fn parseResponsesUsage(u: std.json.Value, usage: *Usage) void {
    if (u != .object) return;
    if (u.object.get("input_tokens")) |it| {
        if (it == .integer) usage.input = @intCast(it.integer);
    }
    if (u.object.get("output_tokens")) |ot| {
        if (ot == .integer) usage.output = @intCast(ot.integer);
    }
    if (u.object.get("input_tokens_details")) |d| {
        if (d == .object) {
            if (d.object.get("cached_tokens")) |ct| {
                if (ct == .integer) usage.cache_read = @intCast(ct.integer);
            }
        }
    }
}

/// Responses API 非流式响应解析(output items)。
fn parseResponsesJson(alloc: std.mem.Allocator, body: []const u8, cbs: Callbacks, result: *RunResult, out_text: *std.array_list.Managed(u8), out_reasoning: *std.array_list.Managed(u8), usage: *Usage) !void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{}) catch return;
    if (root != .object) return;
    if (root.object.get("error")) |e| {
        if (e == .object) {
            if (e.object.get("message")) |m| {
                if (m == .string) {
                    result.error_msg = try std.fmt.allocPrint(alloc, "{s}", .{m.string});
                    return;
                }
            }
        }
    }
    if (root.object.get("usage")) |u| parseResponsesUsage(u, usage);
    if (root.object.get("output")) |out| {
        if (out != .array) return;
        var acc = std.array_list.Managed(ToolAcc).init(alloc);
        defer freeToolAcc(&acc);
        for (out.array.items) |item| {
            if (item != .object) continue;
            const it_t = if (item.object.get("type")) |t| (if (t == .string) t.string else "") else "";
            if (std.mem.eql(u8, it_t, "message")) {
                if (item.object.get("content")) |c| {
                    if (c == .array) {
                        for (c.array.items) |part| {
                            if (part != .object) continue;
                            const pt = if (part.object.get("type")) |t| (if (t == .string) t.string else "") else "";
                            if (std.mem.eql(u8, pt, "output_text") or std.mem.eql(u8, pt, "input_text")) {
                                if (part.object.get("text")) |tx| {
                                    if (tx == .string and tx.string.len > 0) {
                                        try out_text.appendSlice(tx.string);
                                        try emitText(cbs, out_text.items, tx.string);
                                    }
                                }
                            }
                        }
                    }
                }
            } else if (std.mem.eql(u8, it_t, "function_call")) {
                const slot_idx = acc.items.len;
                try acc.append(.{ .id = std.array_list.Managed(u8).init(alloc), .name = std.array_list.Managed(u8).init(alloc), .args = std.array_list.Managed(u8).init(alloc) });
                const slot = &acc.items[slot_idx];
                slot.started = true;
                if (item.object.get("call_id")) |id| {
                    if (id == .string) try slot.id.appendSlice(id.string);
                }
                if (item.object.get("name")) |n| {
                    if (n == .string) try slot.name.appendSlice(n.string);
                }
                if (item.object.get("arguments")) |a| {
                    if (a == .string) try slot.args.appendSlice(a.string);
                }
            } else if (std.mem.eql(u8, it_t, "reasoning")) {
                if (item.object.get("summary")) |s| {
                    if (s == .array) {
                        for (s.array.items) |part| {
                            if (part != .object) continue;
                            if (part.object.get("text")) |tx| {
                                if (tx == .string and tx.string.len > 0) {
                                    try out_reasoning.appendSlice(tx.string);
                                    try emitCallback(cbs, cbs.on_reasoning, tx.string);
                                }
                            }
                        }
                    }
                }
            }
        }
        result.tool_calls = try finalizeToolCalls(alloc, &acc);
    }
}

/// OpenAI 流式主循环。
fn runOpenAIStream(alloc: std.mem.Allocator, arena: std.mem.Allocator, stream: *httpc.Stream, cbs: Callbacks, result: *RunResult, out_text: *std.array_list.Managed(u8), out_reasoning: *std.array_list.Managed(u8), usage: *Usage) !void {
    var acc = std.array_list.Managed(ToolAcc).init(alloc);
    defer freeToolAcc(&acc);
    var finish = std.array_list.Managed(u8).init(alloc);
    defer finish.deinit();
    var parser = httpc.SseParser.init(stream);
    defer parser.deinit();
    while (true) {
        const ev = parser.nextEvent() catch |err| {
            // 读错误:若已请求中止,按中止处理(保留 partial),否则透传
            if (abortRequested(cbs)) {
                result.aborted = true;
                break;
            }
            // 网络抖动导致的中途断流。已收到的内容已经显示给用户了,
            // 丢掉它等于让那半段回复凭空消失。一个字都没收到才算真失败。
            if (out_text.items.len == 0 and out_reasoning.items.len == 0) return err;
            result.stream_interrupted = @errorName(err);
            break;
        };
        if (ev) |e| {
            defer alloc.free(e);
            try parseOpenAIChunk(alloc, arena, e, &acc, cbs, out_text, out_reasoning, usage, &finish);
        } else break;
        if (abortRequested(cbs)) {
            result.aborted = true;
            break;
        }
    }
    result.tool_calls = try finalizeToolCalls(alloc, &acc);
    result.finish_reason = try finish.toOwnedSlice();
    // 不在这里通知「工具要开始了」:那是 agent 层的事实,而且此刻工具还没执行,
    // 甚至可能被权限拒绝或被插件拦下。ai 层只负责协议解析。
    // (原先这里报一次、agent preflight 再报一次,每个工具调用打印两遍。)
}

/// 非流式 OpenAI 响应(个别网关不支持流)。
fn parseOpenAIJson(alloc: std.mem.Allocator, body: []const u8, cbs: Callbacks, result: *RunResult, out_text: *std.array_list.Managed(u8), out_reasoning: *std.array_list.Managed(u8), usage: *Usage) !void {
    _ = out_reasoning;
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{}) catch {
        result.error_msg = "provider returned invalid JSON";
        return;
    };
    const v = root;
    if (v == .object) {
        if (v.object.get("usage")) |u| {
            if (u == .object) {
                if (u.object.get("prompt_tokens")) |pt| {
                    if (pt == .integer) usage.input = @intCast(pt.integer);
                }
                if (u.object.get("completion_tokens")) |ct| {
                    if (ct == .integer) usage.output = @intCast(ct.integer);
                }
                // deepseek 把命中数放 usage 顶层;openai / GLM 放
                // usage.prompt_tokens_details.cached_tokens。两条路径都要试。
                if (u.object.get("prompt_cache_hit_tokens")) |ch| {
                    if (ch == .integer) usage.cache_read = @intCast(ch.integer);
                }
                if (usage.cache_read == null) {
                    if (u.object.get("prompt_tokens_details")) |pd| {
                        if (pd == .object) {
                            if (pd.object.get("cached_tokens")) |ct2| {
                                if (ct2 == .integer) usage.cache_read = @intCast(ct2.integer);
                            }
                        }
                    }
                }
            }
        }
        if (v.object.get("choices")) |choices| {
            if (choices == .array and choices.array.items.len > 0) {
                const choice = choices.array.items[0];
                if (choice == .object) {
                    if (choice.object.get("finish_reason")) |fr| {
                        if (fr == .string) result.finish_reason = fr.string;
                    }
                    if (choice.object.get("message")) |msg| {
                        if (msg == .object) {
                            if (msg.object.get("content")) |c| {
                                if (c == .string) {
                                    try out_text.appendSlice(c.string);
                                    try emitText(cbs, out_text.items, c.string);
                                }
                            }
                            if (msg.object.get("tool_calls")) |tcs| {
                                if (tcs == .array) {
                                    var calls = std.array_list.Managed(ToolCall).init(alloc);
                                    for (tcs.array.items) |tc| {
                                        if (tc != .object) continue;
                                        var id: []const u8 = "";
                                        var name: []const u8 = "";
                                        var args: []const u8 = "";
                                        if (tc.object.get("id")) |i| {
                                            if (i == .string) id = i.string;
                                        }
                                        if (tc.object.get("function")) |f| {
                                            if (f == .object) {
                                                if (f.object.get("name")) |n| {
                                                    if (n == .string) name = n.string;
                                                }
                                                if (f.object.get("arguments")) |a| {
                                                    if (a == .string) args = a.string;
                                                }
                                            }
                                        }
                                        try calls.append(.{ .id = id, .name = name, .args = args });
                                    }
                                    result.tool_calls = try calls.toOwnedSlice();
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Anthropic 事件解析。
fn parseAnthropicEvent(alloc: std.mem.Allocator, arena: std.mem.Allocator, ev: []const u8, acc: *std.array_list.Managed(ToolAcc), cbs: Callbacks, out_text: *std.array_list.Managed(u8), out_reasoning: *std.array_list.Managed(u8), usage: *Usage, finish: *std.array_list.Managed(u8)) !void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, ev, .{}) catch return;
    const v = root;
    if (v != .object) return;
    const etype = jstr(v, "type") orelse return;
    if (std.mem.eql(u8, etype, "message_start")) {
        if (v.object.get("message")) |msg| {
            if (msg == .object) {
                if (msg.object.get("usage")) |u| {
                    if (u == .object) {
                        if (u.object.get("input_tokens")) |it| {
                            if (it == .integer) usage.input = @intCast(it.integer);
                        }
                        // 缓存统计只在 message_start 的 message.usage 里必然完整
                        // (message_delta 的 usage 不保证带这两个字段)。
                        // 注意 input_tokens **不含**缓存部分:Anthropic 把
                        // 命中与写入分别计在下面两个字段里,要算总输入得三者相加。
                        if (u.object.get("cache_read_input_tokens")) |cr| {
                            if (cr == .integer) usage.cache_read = @intCast(cr.integer);
                        }
                        if (u.object.get("cache_creation_input_tokens")) |cw| {
                            if (cw == .integer) usage.cache_write = @intCast(cw.integer);
                        }
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, etype, "content_block_start")) {
        const idx = if (v.object.get("index")) |i| (if (i == .integer) @as(usize, @intCast(i.integer)) else 0) else 0;
        while (acc.items.len <= idx) {
            try acc.append(.{ .id = std.array_list.Managed(u8).init(alloc), .name = std.array_list.Managed(u8).init(alloc), .args = std.array_list.Managed(u8).init(alloc) });
        }
        const slot = &acc.items[idx];
        if (v.object.get("content_block")) |cb| {
            if (cb == .object) {
                if (cb.object.get("type")) |t| {
                    if (t == .string and std.mem.eql(u8, t.string, "tool_use")) {
                        if (cb.object.get("id")) |id| if (id == .string) try slot.id.appendSlice(id.string);
                        if (cb.object.get("name")) |n| if (n == .string) try slot.name.appendSlice(n.string);
                        slot.started = true;
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, etype, "content_block_delta")) {
        const idx = if (v.object.get("index")) |i| (if (i == .integer) @as(usize, @intCast(i.integer)) else 0) else 0;
        if (v.object.get("delta")) |d| {
            if (d == .object) {
                if (d.object.get("type")) |t| {
                    if (t == .string) {
                        if (std.mem.eql(u8, t.string, "text_delta")) {
                            if (d.object.get("text")) |txt| {
                                if (txt == .string) {
                                    try out_text.appendSlice(txt.string);
                                    try emitText(cbs, out_text.items, txt.string);
                                }
                            }
                        } else if (std.mem.eql(u8, t.string, "input_json_delta")) {
                            while (acc.items.len <= idx) {
                                try acc.append(.{ .id = std.array_list.Managed(u8).init(alloc), .name = std.array_list.Managed(u8).init(alloc), .args = std.array_list.Managed(u8).init(alloc) });
                            }
                            const slot = &acc.items[idx];
                            if (d.object.get("partial_json")) |pj| {
                                if (pj == .string) try slot.args.appendSlice(pj.string);
                            }
                            slot.started = true;
                        } else if (std.mem.eql(u8, t.string, "thinking_delta")) {
                            if (d.object.get("thinking")) |th| {
                                if (th == .string) {
                                    try out_reasoning.appendSlice(th.string);
                                    try emitCallback(cbs, cbs.on_reasoning, th.string);
                                }
                            }
                        }
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, etype, "message_delta")) {
        if (v.object.get("delta")) |d| {
            if (d == .object) {
                if (d.object.get("stop_reason")) |sr| {
                    if (sr == .string) try finish.appendSlice(sr.string);
                }
            }
        }
        if (v.object.get("usage")) |u| {
            if (u == .object) {
                if (u.object.get("output_tokens")) |ot| {
                    if (ot == .integer) usage.output = @intCast(ot.integer);
                }
            }
        }
    }
    _ = arena;
}

/// 主入口:发送请求并流式解析,结果写 result(arena 或调用方 allocator)。
/// 图片数量预算:视觉请求里图片太多会被 provider 硬拒(且常是毒化整请求
/// 的 400)。超限丢最老的图、原位换成省略标记 —— 与 omp 的
/// provider-image-budget 同策。在浅拷贝上做,不改会话历史(历史里的
/// 图还可能在后续轮次因为更少的新图而重新纳入)。
///
/// 上限:openai 兼容视觉端点实践上限 20 张/请求;anthropic 100 个 image block。
fn maxImagesFor(api: cfgmod.Api) usize {
    return switch (api) {
        .anthropic_messages => 100,
        .openai_completions, .openai_responses => 20,
    };
}

fn clampProviderImages(alloc: std.mem.Allocator, messages: []const Message, api: cfgmod.Api) ![]const Message {
    const limit = maxImagesFor(api);
    var total: usize = 0;
    for (messages) |m| {
        if (m.image != null) total += 1;
    }
    if (total <= limit) return messages;
    const out = try alloc.alloc(Message, messages.len);
    var drops = total - limit;
    for (messages, 0..) |m, i| {
        out[i] = m;
        if (m.image != null and drops > 0) {
            drops -= 1;
            out[i].image = null;
            out[i].image_mime = null;
            out[i].content = "[image omitted: provider image limit]";
        }
    }
    return out;
}

pub fn run(
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    provider: *const cfgmod.Provider,
    key: ?[]const u8,
    url: []const u8,
    model: []const u8,
    messages: []const Message,
    tools: []const ToolDef,
    options: Options,
) !RunResult {
    var result = RunResult{};
    var out_text = std.array_list.Managed(u8).init(alloc);
    defer out_text.deinit();
    var out_reasoning = std.array_list.Managed(u8).init(alloc);
    defer out_reasoning.deinit();
    var usage = Usage{};

    // 图片数量预算:视觉请求里图片太多会被 provider 硬拒(且常是毒化整请求
    // 的 400)。超限丢最老的图、原位换成省略标记 —— 与 omp 的
    // provider-image-budget 同策。在浅拷贝上做,不改会话历史(历史里的
    // 图还可能在后续轮次因为更少的新图而重新纳入)。
    const msgs = clampProviderImages(alloc, messages, provider.api) catch messages;

    const body = if (provider.api == .anthropic_messages)
        try serializeAnthropic(alloc, model, msgs, tools, options.max_tokens)
    else if (provider.api == .openai_responses)
        try serializeResponses(alloc, model, msgs, tools, options.max_tokens)
    else
        try serializeOpenAI(alloc, model, msgs, tools, options.max_tokens, options.cache_key);
    defer alloc.free(body);

    var headers = std.array_list.Managed(httpc.Header).init(alloc);
    defer headers.deinit();
    if (provider.api == .anthropic_messages) {
        if (key) |k| try headers.append(.{ .name = "x-api-key", .value = k });
        try headers.append(.{ .name = "anthropic-version", .value = "2023-06-01" });
    } else {
        if (key) |k| try headers.append(.{ .name = "Authorization", .value = try std.fmt.allocPrint(alloc, "Bearer {s}", .{k}) });
    }
    if (provider.api == .openai_responses) {
        try headers.append(.{ .name = "OpenAI-Beta", .value = "responses=v1" });
    }

    // 重试窗口仅覆盖此处:连接 + receiveHead + 状态码判定。
    // 一旦往下走进流式读取(向 out_text 累积 / 触发 on_text),就绝不能重试 ——
    // 否则用户会看到重复输出。requestWithRetry 内部同样只在返回前重试。
    var stream = httpc.requestWithRetry(
        alloc,
        url,
        headers.items,
        body,
        options.retry_policy,
        if (options.callbacks.on_abort) |_| abortTrampoline else null,
        @ptrCast(@constCast(&options.callbacks)),
    ) catch |err| {
        if (err == error.Canceled) {
            result.aborted = true;
            return result;
        }
        result.error_msg = try std.fmt.allocPrint(arena, "request failed: {s}", .{@errorName(err)});
        return result;
    };
    defer stream.deinit();
    // 通知中断方持有流(供 shutdown 打断阻塞读)
    if (options.callbacks.on_connect) |f| f(options.callbacks.ctx, stream);

    const status = stream.status();
    if (status >= 400) {
        const resp_body = stream.readAll(64 * 1024) catch &.{};
        // 提取 provider 错误消息
        var msg: []const u8 = "";
        if (resp_body.len > 0) {
            if (std.json.parseFromSliceLeaky(std.json.Value, arena, resp_body, .{})) |root| {
                if (root == .object) {
                    if (root.object.get("error")) |e| {
                        if (e == .object) {
                            if (e.object.get("message")) |m| {
                                if (m == .string) msg = m.string;
                            }
                        } else if (e == .string) {
                            msg = e.string;
                        }
                    }
                }
            } else |_| {}
        }
        result.error_msg = if (msg.len > 0)
            try std.fmt.allocPrint(arena, "HTTP {d}: {s}", .{ status, msg })
        else
            try std.fmt.allocPrint(arena, "HTTP {d}: {s}", .{ status, resp_body });
        return result;
    }

    // 判断 SSE 与否:content-type 含 text/event-stream(init 时已拷贝)
    const is_sse = if (stream.content_type) |ct|
        std.mem.indexOf(u8, ct, "text/event-stream") != null
    else
        false;

    if (is_sse) {
        if (provider.api == .anthropic_messages) {
            var acc = std.array_list.Managed(ToolAcc).init(alloc);
            defer freeToolAcc(&acc);
            var finish = std.array_list.Managed(u8).init(alloc);
            defer finish.deinit();
            var parser = httpc.SseParser.init(stream);
            defer parser.deinit();
            while (true) {
                const ev = parser.nextEvent() catch |err| {
                    if (abortRequested(options.callbacks)) {
                        result.aborted = true;
                        break;
                    }
                    // 连接读到一半断了。已经收到并显示给用户的内容是有效的,
                    // 丢掉它等于让用户看着半段回复消失、模型也不知道自己说过什么。
                    // 一个字都没收到才算真失败 —— 那时没有可保的东西。
                    if (out_text.items.len == 0 and out_reasoning.items.len == 0) return err;
                    result.stream_interrupted = @errorName(err);
                    break;
                };
                if (ev) |e| {
                    defer alloc.free(e);
                    try parseAnthropicEvent(alloc, arena, e, &acc, options.callbacks, &out_text, &out_reasoning, &usage, &finish);
                } else break;
                if (abortRequested(options.callbacks)) {
                    result.aborted = true;
                    break;
                }
            }
            result.tool_calls = try finalizeToolCalls(alloc, &acc);
            result.finish_reason = try finish.toOwnedSlice();
        } else if (provider.api == .openai_responses) {
            var acc = std.array_list.Managed(ToolAcc).init(alloc);
            defer freeToolAcc(&acc);
            var finish = std.array_list.Managed(u8).init(alloc);
            defer finish.deinit();
            var errs = std.array_list.Managed(u8).init(alloc);
            defer errs.deinit();
            var parser = httpc.SseParser.init(stream);
            defer parser.deinit();
            while (true) {
                const ev = parser.nextEvent() catch |err| {
                    if (abortRequested(options.callbacks)) {
                        result.aborted = true;
                        break;
                    }
                    if (out_text.items.len == 0 and out_reasoning.items.len == 0 and acc.items.len == 0) return err;
                    result.stream_interrupted = @errorName(err);
                    break;
                };
                if (ev) |e| {
                    defer alloc.free(e);
                    try parseResponsesEvent(alloc, e, &acc, options.callbacks, &out_text, &out_reasoning, &usage, &finish, &errs);
                } else break;
                if (abortRequested(options.callbacks)) {
                    result.aborted = true;
                    break;
                }
            }
            result.tool_calls = try finalizeToolCalls(alloc, &acc);
            result.finish_reason = try finish.toOwnedSlice();
            if (errs.items.len > 0) {
                result.error_msg = try errs.toOwnedSlice();
            }
        } else {
            try runOpenAIStream(alloc, arena, stream, options.callbacks, &result, &out_text, &out_reasoning, &usage);
        }
    } else {
        const resp_body = stream.readAll(64 * 1024) catch |err| {
            if (abortRequested(options.callbacks)) {
                result.aborted = true;
                return result;
            }
            return err;
        };
        if (abortRequested(options.callbacks)) {
            result.aborted = true;
            return result;
        }
        if (provider.api == .anthropic_messages) {
            // 非流式 anthropic 响应
            const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, resp_body, .{}) catch {
                result.error_msg = "provider returned invalid JSON";
                return result;
            };
            const v = root;
            if (v == .object) {
                if (v.object.get("usage")) |u| {
                    if (u == .object) {
                        if (u.object.get("input_tokens")) |it| {
                            if (it == .integer) usage.input = @intCast(it.integer);
                        }
                        if (u.object.get("output_tokens")) |ot| {
                            if (ot == .integer) usage.output = @intCast(ot.integer);
                        }
                    }
                }
                if (v.object.get("stop_reason")) |sr| {
                    if (sr == .string) result.finish_reason = sr.string;
                }
                if (v.object.get("content")) |content| {
                    if (content == .array) {
                        var calls = std.array_list.Managed(ToolCall).init(alloc);
                        for (content.array.items) |block| {
                            if (block != .object) continue;
                            if (block.object.get("type")) |t| {
                                if (t != .string) continue;
                                if (std.mem.eql(u8, t.string, "text")) {
                                    if (block.object.get("text")) |txt| {
                                        if (txt == .string) {
                                            try out_text.appendSlice(txt.string);
                                            try emitText(options.callbacks, out_text.items, txt.string);
                                        }
                                    }
                                } else if (std.mem.eql(u8, t.string, "tool_use")) {
                                    var id: []const u8 = "";
                                    var name: []const u8 = "";
                                    var args: []const u8 = "";
                                    if (block.object.get("id")) |i| {
                                        if (i == .string) id = i.string;
                                    }
                                    if (block.object.get("name")) |n| {
                                        if (n == .string) name = n.string;
                                    }
                                    if (block.object.get("input")) |inp| {
                                        args = std.json.Stringify.valueAlloc(alloc, inp, .{}) catch "{}";
                                    }
                                    try calls.append(.{ .id = id, .name = name, .args = args });
                                }
                            }
                        }
                        result.tool_calls = try calls.toOwnedSlice();
                    }
                }
            }
        } else if (provider.api == .openai_responses) {
            try parseResponsesJson(alloc, resp_body, options.callbacks, &result, &out_text, &out_reasoning, &usage);
        } else {
            try parseOpenAIJson(alloc, resp_body, options.callbacks, &result, &out_text, &out_reasoning, &usage);
        }
    }

    result.text = try out_text.toOwnedSlice();
    result.reasoning = try out_reasoning.toOwnedSlice();
    result.usage = usage;
    return result;
}

test "serializeOpenAI basic" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{
        .{ .role = "system", .content = "sys" },
        .{ .role = "user", .content = "hi" },
        .{ .role = "assistant", .content = "", .tool_calls = &.{.{ .id = "c1", .name = "bash", .args = "{\"command\":\"ls\"}" }} },
        .{ .role = "tool", .content = "out", .tool_call_id = "c1" },
    };
    const body = try serializeOpenAI(a, "m", &msgs, &.{}, 100, null);
    try t.expect(std.mem.indexOf(u8, body, "\"model\":\"m\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"c1\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"") != null);
}

test "invalid utf8 in tool output still serializes as a JSON string" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 汉字被切在序列中间 —— 工具输出砍字节数时的常态。
    // "会话级" 的 UTF-8 是 e4bc9a e8af9d e7baa7;这里砍掉最后一个字节。
    const truncated = "// agents.zig — \xe4\xbc\x9a\xe8\xaf\x9d\xe7\xba";
    try t.expect(!std.unicode.utf8ValidateSlice(truncated));

    const msgs = [_]Message{
        .{ .role = "user", .content = "go" },
        .{ .role = "tool", .content = truncated, .tool_call_id = "c1" },
    };

    // 两个协议都必须写出**字符串**。std.json.Stringify 对非法 UTF-8 的
    // []const u8 会静默退化成整数数组,provider 拿到 "content":[91,65,...]
    // 直接 400,而报错内容(“expected ContentBlock”)跟真实原因毫无关系。
    inline for (.{ true, false }) |openai| {
        const body = if (openai)
            try serializeOpenAI(a, "m", &msgs, &.{}, 100, null)
        else
            try serializeAnthropic(a, "m", &msgs, &.{}, 100);
        // 合法 JSON 是底线
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        // content 是字符串,不是数组
        const arr = parsed.value.object.get("messages").?.array;
        var saw_tool_text = false;
        for (arr.items) |m| {
            const c = m.object.get("content") orelse continue;
            switch (c) {
                .string => |s| {
                    if (std.mem.indexOf(u8, s, "agents.zig") != null) saw_tool_text = true;
                },
                // anthropic 把 tool 结果包成 content 块数组,块里的 content 才是文本
                .array => |blocks| for (blocks.items) |b| {
                    const inner = b.object.get("content") orelse continue;
                    if (inner == .string and std.mem.indexOf(u8, inner.string, "agents.zig") != null) {
                        saw_tool_text = true;
                    }
                    // 非字符串就是退化成了整数数组 —— 正是要防的
                    try t.expect(inner != .integer);
                },
                else => return error.ContentIsNotText,
            }
        }
        try t.expect(saw_tool_text);
    }
}

test "text tool-call markers are withheld from the stream" {
    const t = std.testing;

    // 收集 on_text 实际外发的内容
    const Sink = struct {
        var buf: [4096]u8 = undefined;
        var len: usize = 0;
        fn reset() void {
            len = 0;
        }
        fn cb(_: ?*anyopaque, text: []const u8) anyerror!void {
            @memcpy(buf[len .. len + text.len], text);
            len += text.len;
        }
        fn got() []const u8 {
            return buf[0..len];
        }
    };
    const cbs = Callbacks{ .on_text = Sink.cb };

    // 按 chunk 喂进去,模拟流式
    const feed = struct {
        fn go(c: Callbacks, chunks: []const []const u8) !void {
            Sink.reset();
            var acc = std.array_list.Managed(u8).init(std.testing.allocator);
            defer acc.deinit();
            for (chunks) |ch| {
                try acc.appendSlice(ch);
                try emitText(c, acc.items, ch);
            }
        }
    }.go;

    // 干净文本原样透传
    try feed(cbs, &.{ "hello ", "world" });
    try t.expectEqualStrings("hello world", Sink.got());

    // 标记在一个 chunk 内 —— 之前的留下,标记及之后全部扣住
    try feed(cbs, &.{"answer: <｜｜DSML｜｜tool_calls>\n<｜｜DSML｜｜invoke name=\"bash\">"});
    try t.expectEqualStrings("answer: ", Sink.got());

    // 标记被 chunk 边界切开 —— 半截前缀也必须立刻闭嘴,
    // 否则 `<｜｜DS` 已经印在屏幕上了
    try feed(cbs, &.{ "text <｜｜DS", "ML｜｜tool_calls>" });
    try t.expectEqualStrings("text ", Sink.got());

    // 逐字节流式:最坏情况
    var bytes: [64][]const u8 = undefined;
    const src = "ok <｜｜DSML｜｜tool_calls>";
    var n: usize = 0;
    for (src, 0..) |_, i| {
        bytes[n] = src[i .. i + 1];
        n += 1;
    }
    try feed(cbs, bytes[0..n]);
    try t.expectEqualStrings("ok ", Sink.got());

    // 标记之后就算又出现正常文本也不放行 —— 那都是伪造调用的内容
    try feed(cbs, &.{ "a<｜｜DSML｜｜x", "more text here" });
    try t.expectEqualStrings("a", Sink.got());

    // 全角竖线不能和 ASCII 竖线混淆:正常文本里的 | 不该触发
    try feed(cbs, &.{"pipe | char and <|not a marker|>"});
    try t.expectEqualStrings("pipe | char and <|not a marker|>", Sink.got());
}

test "escapes survive the invalid-utf8 slow path" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 非法字节触发慢路径,同一份内容里还有必须转义的字符。
    // 慢路径自己做转义,漏了就产出非法 JSON。
    const nasty = "say \"hi\"\n\ttab\\slash \x1b[0m \xff end";
    const msgs = [_]Message{.{ .role = "tool", .content = nasty, .tool_call_id = "c" }};
    const body = try serializeOpenAI(a, "m", &msgs, &.{}, 100, null);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const got = parsed.value.object.get("messages").?.array.items[0].object.get("content").?.string;
    // 往返之后合法字符原样留存,只有非法字节变成替换符
    try t.expect(std.mem.indexOf(u8, got, "say \"hi\"") != null);
    try t.expect(std.mem.indexOf(u8, got, "\n\ttab\\slash") != null);
    try t.expect(std.mem.indexOf(u8, got, "\x1b[0m") != null);
    try t.expect(std.mem.indexOf(u8, got, "\u{fffd}") != null);
}

test "parse streamed usage with cache hit" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var acc = std.array_list.Managed(ToolAcc).init(a);
    defer acc.deinit();
    var out_text = std.array_list.Managed(u8).init(a);
    defer out_text.deinit();
    var out_reasoning = std.array_list.Managed(u8).init(a);
    defer out_reasoning.deinit();
    var finish = std.array_list.Managed(u8).init(a);
    defer finish.deinit();
    var usage: Usage = .{};

    // deepseek 流式 usage chunk(include_usage):含 prompt_cache_hit_tokens
    const chunk =
        "{\"id\":\"x\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":40000,\"completion_tokens\":100,\"total_tokens\":40100,\"prompt_cache_hit_tokens\":39000,\"prompt_cache_miss_tokens\":1000}}";
    try parseOpenAIChunk(a, a, chunk, &acc, .{}, &out_text, &out_reasoning, &usage, &finish);
    try t.expectEqual(@as(?u64, 40000), usage.input);
    try t.expectEqual(@as(?u64, 100), usage.output);
    try t.expectEqual(@as(?u64, 39000), usage.cache_read);
    try t.expectEqualStrings("stop", finish.items);
}

test "anthropic request carries a cache breakpoint on system" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{
        .{ .role = "system", .content = "long system prompt with project rules" },
        .{ .role = "user", .content = "hi" },
    };
    var defs = [_]ToolDef{.{ .name = "read", .desc = "read a file", .schema = "{\"type\":\"object\"}" }};
    const body = try serializeAnthropic(a, "m", &msgs, &defs, 100);

    // system 必须是数组形式(纯字符串挂不了 cache_control)
    try t.expect(std.mem.indexOf(u8, body, "\"system\":[{\"type\":\"text\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
    // 系统提示内容仍然在
    try t.expect(std.mem.indexOf(u8, body, "long system prompt with project rules") != null);

    // 断点必须在 system 上,不在 tools 上 —— Anthropic 按 tools→system→messages
    // 拼前缀,标在 system 末尾就已覆盖 tools,标在 tools 上反而漏掉 system。
    const i_tools = std.mem.indexOf(u8, body, "\"tools\":[").?;
    const i_sys = std.mem.indexOf(u8, body, "\"system\":[").?;
    const i_cc = std.mem.indexOf(u8, body, "\"cache_control\"").?;
    try t.expect(i_tools < i_sys);
    try t.expect(i_cc > i_sys);
}

test "no cache breakpoint when there is no system prompt" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{.{ .role = "user", .content = "hi" }};
    const body = try serializeAnthropic(a, "m", &msgs, &.{}, 100);
    // 没有 system 就不该出现空的 system 数组或孤立的断点
    try t.expect(std.mem.indexOf(u8, body, "\"system\"") == null);
    try t.expect(std.mem.indexOf(u8, body, "\"cache_control\"") == null);
}

test "static parts precede messages so the cacheable prefix stays intact" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var defs = [_]ToolDef{.{ .name = "read", .desc = "read a file", .schema = "{\"type\":\"object\"}" }};

    // 两轮:第二轮只在尾部追加消息。静态部分(tools)必须仍在同一位置,
    // 这样服务端重组出的 prompt 前缀才逐字节一致。
    const t1 = [_]Message{
        .{ .role = "system", .content = "rules" },
        .{ .role = "user", .content = "q1" },
    };
    const t2 = [_]Message{
        .{ .role = "system", .content = "rules" },
        .{ .role = "user", .content = "q1" },
        .{ .role = "assistant", .content = "a1" },
        .{ .role = "user", .content = "q2" },
    };
    const b1 = try serializeOpenAI(a, "m", &t1, &defs, 100, null);
    const b2 = try serializeOpenAI(a, "m", &t2, &defs, 100, null);

    // 公共前缀必须覆盖到 messages 开始处 —— 即 tools 整段落在稳定区
    var cp: usize = 0;
    while (cp < b1.len and cp < b2.len and b1[cp] == b2[cp]) cp += 1;
    const i_msgs = std.mem.indexOf(u8, b1, "\"messages\":[").?;
    try t.expect(cp >= i_msgs);

    // tools 在 messages 之前
    try t.expect(std.mem.indexOf(u8, b1, "\"tools\":[").? < i_msgs);
}

test "prompt_cache_key lands in the stable prefix and never on anthropic" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var defs = [_]ToolDef{.{ .name = "read", .desc = "read", .schema = "{\"type\":\"object\"}" }};
    const msgs = [_]Message{
        .{ .role = "system", .content = "rules" },
        .{ .role = "user", .content = "q" },
    };

    const oa = try serializeOpenAI(a, "m", &msgs, &defs, 100, "/home/u/proj");
    const i_key = std.mem.indexOf(u8, oa, "\"prompt_cache_key\":\"/home/u/proj\"");
    try t.expect(i_key != null);
    // 必须在 messages 之前:它属于每轮不变的静态部分
    try t.expect(i_key.? < std.mem.indexOf(u8, oa, "\"messages\":[").?);

    // 空 key 不写字段(别发 "prompt_cache_key":"")
    const empty = try serializeOpenAI(a, "m", &msgs, &defs, 100, "");
    try t.expect(std.mem.indexOf(u8, empty, "prompt_cache_key") == null);
    const none = try serializeOpenAI(a, "m", &msgs, &defs, 100, null);
    try t.expect(std.mem.indexOf(u8, none, "prompt_cache_key") == null);

    // Anthropic Messages API 没有这个字段,发过去是未知字段 —— 绝不能出现
    const an = try serializeAnthropic(a, "m", &msgs, &defs, 100);
    try t.expect(std.mem.indexOf(u8, an, "prompt_cache_key") == null);
}

test "anthropic cache usage fields are parsed from message_start" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var acc = std.array_list.Managed(ToolAcc).init(a);
    defer acc.deinit();
    var out_text = std.array_list.Managed(u8).init(a);
    defer out_text.deinit();
    var out_reasoning = std.array_list.Managed(u8).init(a);
    defer out_reasoning.deinit();
    var finish = std.array_list.Managed(u8).init(a);
    defer finish.deinit();
    var usage: Usage = .{};

    // 缓存命中的 message_start:input_tokens 不含缓存部分,读写分列
    const ev =
        "{\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"usage\":{\"input_tokens\":12,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":3200,\"output_tokens\":1}}}";
    try parseAnthropicEvent(a, a, ev, &acc, .{}, &out_text, &out_reasoning, &usage, &finish);
    try t.expectEqual(@as(?u64, 12), usage.input);
    try t.expectEqual(@as(?u64, 3200), usage.cache_read);
    try t.expectEqual(@as(?u64, 0), usage.cache_write);

    // 首次写入缓存:read 为 0、write 是实际写入量
    var usage2: Usage = .{};
    const ev2 =
        "{\"type\":\"message_start\",\"message\":{\"id\":\"m2\",\"role\":\"assistant\",\"usage\":{\"input_tokens\":12,\"cache_creation_input_tokens\":3200,\"cache_read_input_tokens\":0,\"output_tokens\":1}}}";
    try parseAnthropicEvent(a, a, ev2, &acc, .{}, &out_text, &out_reasoning, &usage2, &finish);
    try t.expectEqual(@as(?u64, 3200), usage2.cache_write);
    try t.expectEqual(@as(?u64, 0), usage2.cache_read);
}

test "openai nested cached_tokens is parsed in the non-stream path" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var acc = std.array_list.Managed(ToolAcc).init(a);
    defer acc.deinit();
    var out_text = std.array_list.Managed(u8).init(a);
    defer out_text.deinit();
    var out_reasoning = std.array_list.Managed(u8).init(a);
    defer out_reasoning.deinit();
    var finish = std.array_list.Managed(u8).init(a);
    defer finish.deinit();
    var usage: Usage = .{};

    // openai / GLM 的路径是嵌套的 prompt_tokens_details.cached_tokens
    const chunk =
        "{\"id\":\"x\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5000,\"completion_tokens\":10,\"prompt_tokens_details\":{\"cached_tokens\":4096}}}";
    try parseOpenAIChunk(a, a, chunk, &acc, .{}, &out_text, &out_reasoning, &usage, &finish);
    try t.expectEqual(@as(?u64, 4096), usage.cache_read);
}

test "cacheable prefix covers tools and system for a realistic request" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 用接近真实体量的系统提示(AGENTS.md 级别)与多个工具定义
    const sys = "PROJECT RULES\n" ++ ("规则条目:保持简洁,不要过度抽象。\n" ** 60);
    var defs = [_]ToolDef{
        .{ .name = "read", .desc = "Read a file with optional line range.", .schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}" },
        .{ .name = "write", .desc = "Write a file, creating parents.", .schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}" },
        .{ .name = "bash", .desc = "Run a shell command.", .schema = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}" },
    };
    const msgs = [_]Message{
        .{ .role = "system", .content = sys },
        .{ .role = "user", .content = "开始任务" },
    };

    const body = try serializeAnthropic(a, "claude-sonnet-5", &msgs, &defs, 8192);
    const i_m = std.mem.indexOf(u8, body, "\",\"stream\":true,\"messages\":[") orelse
        std.mem.indexOf(u8, body, "\"messages\":[").?;

    // 断点之前(tools + system)就是被缓存的前缀。Anthropic 的最小可缓存长度
    // 按模型 512–4096 token,低于阈值静默不缓存 —— 这里确认真实配置远超 1024。
    const prefix_tokens = @import("agent.zig").Agent.estTokensOf(body[0..i_m]);
    try t.expect(prefix_tokens > 1024);

    // 前缀里必须同时含 tools 与 system 的内容
    const prefix = body[0..i_m];
    try t.expect(std.mem.indexOf(u8, prefix, "\"name\":\"bash\"") != null);
    try t.expect(std.mem.indexOf(u8, prefix, "PROJECT RULES") != null);
    try t.expect(std.mem.indexOf(u8, prefix, "\"cache_control\"") != null);
}

// 压缩对缓存前缀的影响。codex 明令禁止 history rewrite(AGENTS.md「No history
// rewrite - the context must be built up incrementally」),它把摘要 **push 到
// 末尾**;piz 是摘要置前 + clearRetainingCapacity,整段 messages 重写。
//
// 这个测试把差异钉成数字:置前保住的共同前缀只到 messages 开头,追加能保住
// 全部旧消息。tools/system 排在 messages 之前,所以固定成本那段仍然命中 ——
// 这是 piz 选择保留「置前」的前提。
test "compaction placement determines how much request prefix survives" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sys = "SYSTEM PROMPT " ** 150;
    var defs = [_]ToolDef{
        .{ .name = "bash", .desc = "run a command", .schema = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}}}" },
    };

    var pre = std.array_list.Managed(Message).init(a);
    try pre.append(.{ .role = "system", .content = sys });
    const turns = [_][]const u8{ "问题一", "回答一", "问题二", "回答二", "问题三" };
    for (turns, 0..) |c, i| {
        try pre.append(.{ .role = if (i % 2 == 0) "user" else "assistant", .content = c });
    }

    // piz 现状:摘要置前,只保留最近 2 条
    var front = std.array_list.Managed(Message).init(a);
    try front.append(.{ .role = "system", .content = sys });
    try front.append(.{ .role = "system", .content = "(Conversation compacted. Summary:)\n摘要" });
    try front.appendSlice(pre.items[pre.items.len - 2 ..]);

    // codex 做法:原历史 + 摘要追加到尾
    var tail = std.array_list.Managed(Message).init(a);
    try tail.appendSlice(pre.items);
    try tail.append(.{ .role = "user", .content = "(Conversation compacted. Summary:)\n摘要" });

    const b_pre = try serializeOpenAI(a, "m", pre.items, &defs, 100, null);
    const b_front = try serializeOpenAI(a, "m", front.items, &defs, 100, null);
    const b_tail = try serializeOpenAI(a, "m", tail.items, &defs, 100, null);

    const shared = struct {
        fn len(x: []const u8, y: []const u8) usize {
            var i: usize = 0;
            while (i < @min(x.len, y.len) and x[i] == y[i]) i += 1;
            return i;
        }
    };
    const keep_front = shared.len(b_pre, b_front);
    const keep_tail = shared.len(b_pre, b_tail);

    // 追加严格优于置前 —— 这是 codex 那条规则的量化依据
    try t.expect(keep_tail > keep_front);

    // 但置前**仍然**保住 tools + system:固定成本(实测约 3217 token/轮)照旧命中。
    // 作废的只是对话消息那段,而它本来每轮都在变。
    const i_m = std.mem.indexOf(u8, b_pre, "\"messages\":[").?;
    try t.expect(keep_front >= i_m);
    try t.expect(std.mem.indexOf(u8, b_front[0..keep_front], "\"name\":\"bash\"") != null);
}

test "serializeAnthropic tool result" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{
        .{ .role = "user", .content = "hi" },
        .{ .role = "tool", .content = "ok", .tool_call_id = "t1" },
    };
    const body = try serializeAnthropic(a, "m", &msgs, &.{}, 100);
    try t.expect(std.mem.indexOf(u8, body, "\"tool_result\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"tool_use_id\":\"t1\"") != null);
}

test "system prompt reaches the model on both protocols" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{
        .{ .role = "system", .content = "RULE: reply in Chinese" },
        .{ .role = "user", .content = "hi" },
    };

    // openai:system 作为 messages 数组里的一条
    const oa = try serializeOpenAI(a, "m", &msgs, &.{}, 100, null);
    try t.expect(std.mem.indexOf(u8, oa, "RULE: reply in Chinese") != null);
    try t.expect(std.mem.indexOf(u8, oa, "\"role\":\"system\"") != null);

    // anthropic:system 走顶层字段(数组形式,带缓存断点),不出现在 messages 数组里
    const an = try serializeAnthropic(a, "m", &msgs, &.{}, 100);
    try t.expect(std.mem.indexOf(u8, an, "\"system\":[{\"type\":\"text\",\"text\":\"RULE: reply in Chinese\"") != null);
    const msgs_start = std.mem.indexOf(u8, an, "\"messages\":[").?;
    try t.expect(std.mem.indexOf(u8, an[msgs_start..], "\"role\":\"system\"") == null);
}

test "multiple system messages concatenate for anthropic" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 压缩摘要也是 system 角色 —— 两条都必须送达
    const msgs = [_]Message{
        .{ .role = "system", .content = "base prompt" },
        .{ .role = "system", .content = "(Conversation compacted. Summary:)\nearlier work" },
        .{ .role = "user", .content = "next" },
    };
    const an = try serializeAnthropic(a, "m", &msgs, &.{}, 100);
    try t.expect(std.mem.indexOf(u8, an, "base prompt") != null);
    try t.expect(std.mem.indexOf(u8, an, "earlier work") != null);
    // 拼接顺序:base 在摘要之前
    const i_base = std.mem.indexOf(u8, an, "base prompt").?;
    const i_sum = std.mem.indexOf(u8, an, "earlier work").?;
    try t.expect(i_base < i_sum);
}

test "no system field when there is no system message" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{.{ .role = "user", .content = "hi" }};
    const an = try serializeAnthropic(a, "m", &msgs, &.{}, 100);
    // 空 system 不该写出 "system":"" —— Anthropic 会拒绝空字符串
    try t.expect(std.mem.indexOf(u8, an, "\"system\"") == null);
}

test "tool defs carry real json schema to both providers" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{.{ .role = "user", .content = "hi" }};
    const defs = [_]ToolDef{
        .{
            .name = "read",
            .desc = "Read a file.",
            .schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}",
        },
        // 空 schema 退化为无参数对象(不能漏字段,否则 provider 报 400)
        .{ .name = "git_status", .desc = "Show git status." },
    };

    const oa = try serializeOpenAI(a, "m", &msgs, &defs, 100, null);
    try t.expect(std.mem.indexOf(u8, oa, "\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}") != null);
    try t.expect(std.mem.indexOf(u8, oa, "\"parameters\":{\"type\":\"object\",\"properties\":{}}") != null);
    // 旧 bug 回归:desc 曾被塞进 args 字段,schema 恒为空
    try t.expect(std.mem.indexOf(u8, oa, "\"description\":\"Read a file.\"") != null);

    const an = try serializeAnthropic(a, "m", &msgs, &defs, 100);
    try t.expect(std.mem.indexOf(u8, an, "\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}") != null);
    try t.expect(std.mem.indexOf(u8, an, "\"input_schema\":{\"type\":\"object\",\"properties\":{}}") != null);
}

test "every registered tool ships a parseable schema" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 契约:任何工具的 schema 要么为空(退化),要么是合法 JSON object 且 type=object。
    // 防止新增插件工具时写坏 schema 字面量导致 provider 400。
    for (&@import("tools.zig").tools) |*tool| {
        if (tool.schema.len == 0) continue;
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, tool.schema, .{});
        try t.expect(v == .object);
        const ty = v.object.get("type") orelse return error.SchemaMissingType;
        try t.expectEqualStrings("object", ty.string);
    }
}

test "reasoning arrives under either field name, never doubled" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Case = struct { json: []const u8, want: []const u8 };
    const cases = [_]Case{
        // DeepSeek 系
        .{ .json = "{\"choices\":[{\"delta\":{\"reasoning_content\":\"aa\"}}]}", .want = "aa" },
        // OpenRouter 等网关只发 reasoning —— 不认它就丢掉整段推理
        .{ .json = "{\"choices\":[{\"delta\":{\"reasoning\":\"bb\"}}]}", .want = "bb" },
        // 实测某网关两个都发且内容相同:只能算一次,否则推理文本翻倍
        .{ .json = "{\"choices\":[{\"delta\":{\"reasoning_content\":\"cc\",\"reasoning\":\"cc\"}}]}", .want = "cc" },
    };

    for (cases) |c| {
        var acc = std.array_list.Managed(ToolAcc).init(a);
        var out_text = std.array_list.Managed(u8).init(a);
        var out_reasoning = std.array_list.Managed(u8).init(a);
        var finish = std.array_list.Managed(u8).init(a);
        var usage: Usage = .{};
        try parseOpenAIChunk(a, a, c.json, &acc, .{}, &out_text, &out_reasoning, &usage, &finish);
        try t.expectEqualStrings(c.want, out_reasoning.items);
        // 推理不许漏进正文 —— 那会让思考过程冒充答案
        try t.expectEqualStrings("", out_text.items);
    }
}

test "image messages serialize to content arrays on both protocols" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const msgs = [_]Message{
        .{ .role = "user", .content = "look at this", .image = "AAAA", .image_mime = "image/png", .image_w = 10, .image_h = 20 },
    };
    const body = try serializeOpenAI(a, "m", &msgs, &.{}, 100, null);
    try t.expect(std.mem.indexOf(u8, body, "\"content\":[{\"type\":\"text\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,AAAA\"}") != null);

    const body2 = try serializeAnthropic(a, "m", &msgs, &.{}, 100);
    try t.expect(std.mem.indexOf(u8, body2, "\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"AAAA\"}") != null);
}

test "clampProviderImages drops oldest images past the cap" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var msgs: [25]Message = undefined;
    for (&msgs, 0..) |*m, i| m.* = .{ .role = "user", .content = "x", .image = if (i < 25) "img" else null };
    const clamped = try clampProviderImages(a, &msgs, .openai_completions);
    // 20 张上限:5 张最老的被替换为省略标记
    var kept: usize = 0;
    var omitted: usize = 0;
    for (clamped) |m| {
        if (m.image != null) kept += 1;
        if (std.mem.eql(u8, m.content, "[image omitted: provider image limit]")) omitted += 1;
    }
    try t.expectEqual(@as(usize, 20), kept);
    try t.expectEqual(@as(usize, 5), omitted);
    // 原消息未被修改(浅拷贝)
    try t.expect(msgs[0].image != null);
}
