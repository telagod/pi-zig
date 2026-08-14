// 插件合同:钩子链与表项。实现不得回引 plugins.zig。
const toolsmod = @import("../tools.zig");

/// 工具前 waterfall。不调 next() 即短路。返回非 null = 拦截(内容回给模型)。
pub const BeforeChain = struct {
    ctx: ?*anyopaque,
    name: []const u8,
    args: []const u8,
    hooks: []const ?*const fn (*BeforeChain) ?[]const u8,
    index: usize = 0,

    pub fn next(self: *BeforeChain) ?[]const u8 {
        while (self.index < self.hooks.len) {
            const i = self.index;
            self.index += 1;
            if (self.hooks[i]) |h| return h(self);
        }
        return null;
    }
};

/// 工具结果 waterfall。不调 next() 即短路。返回非 null = 替换内容。
pub const AfterChain = struct {
    ctx: ?*anyopaque,
    name: []const u8,
    content: []const u8,
    hooks: []const ?*const fn (*AfterChain) ?[]const u8,
    index: usize = 0,

    pub fn next(self: *AfterChain) ?[]const u8 {
        while (self.index < self.hooks.len) {
            const i = self.index;
            self.index += 1;
            if (self.hooks[i]) |h| return h(self);
        }
        return null;
    }
};

/// 内置插件定义。
pub const Plugin = struct {
    name: []const u8,
    /// 是否默认启用。false = 可选扩展,需 settings.json 的 `plugins` 数组
    /// 或 `--plugin <name>` 显式开启。
    ///
    /// 极简内核的实际含义:默认暴露给模型的工具越少,模型选错工具的概率越低,
    /// 每轮的 tools 定义也越省 token。场景化能力按需开。
    enabled_by_default: bool = true,
    /// 每轮请求前钩子(可裁剪上下文、注入内容等)。ctx 为 Agent 指针。
    before_turn: ?*const fn (ctx: ?*anyopaque) void = null,
    /// 压缩成功后钩子(跨会话记忆等,复用摘要,零额外模型调用)。
    on_compact: ?*const fn (ctx: ?*anyopaque, summary: []const u8) void = null,
    /// 压缩失败钩子:返回备用模型名(非 null 则用其重试一次)。
    on_compact_failed: ?*const fn (ctx: ?*anyopaque) ?[]const u8 = null,
    /// 工具执行前(waterfall):不调 chain.next() 即短路。返回非 null 则拦截。
    on_tool_before: ?*const fn (chain: *BeforeChain) ?[]const u8 = null,
    /// 工具结果回写前(waterfall):不调 chain.next() 即短路。返回非 null 则替换。
    on_tool_result: ?*const fn (chain: *AfterChain) ?[]const u8 = null,
    /// 用户消息钩子(elicitation 续跑等)。
    on_user_message: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
    /// 斜杠命令(交互模式 /<name>)。
    slash_commands: []const SlashCommand = &.{},
    /// 插件注册的工具(与核心工具合并暴露给模型)。
    tools: []const toolsmod.Tool = &.{},
};

/// 插件斜杠命令。
pub const SlashCommand = struct {
    name: []const u8,
    desc: []const u8,
    /// ctx = 宿主(如 App),args = 命令参数。
    handler: *const fn (ctx: ?*anyopaque, args: []const u8) anyerror![]const u8,
};
