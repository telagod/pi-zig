// config.zig — 配置与认证:settings.json / auth.json / models.json / 环境变量。
// 目录:~/.piz(或 $PIZ_DIR)。刻意不与官方 pi 共用,见 util.configDir 注释。
const std = @import("std");
const util = @import("util.zig");

pub const Api = enum { openai_completions, anthropic_messages, openai_responses };

/// 未知模型缺省窗口。跟 pi 一样是十进制 128000,不是 128*1024。
/// 后者会显示成 131k,就是状态栏上那个错数。
pub const DEFAULT_CONTEXT_WINDOW: u32 = 128000;
pub const DEFAULT_MAX_OUTPUT: u32 = 16384;

/// 行业思考等级。词表对齐 OpenAI `reasoning.effort` 与 pi `thinkingLevelMap`:
/// `off | minimal | low | medium | high | xhigh | max`。
/// 不是每家都认全部七档;可见档与发给 provider 的字符串由 `thinkingLevelMap` 定。
pub const ThinkLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
    max,

    pub const all = [_]ThinkLevel{ .off, .minimal, .low, .medium, .high, .xhigh, .max };

    pub fn parse(s: []const u8) ?ThinkLevel {
        if (std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "none") or
            std.mem.eql(u8, s, "-") or std.mem.eql(u8, s, "—") or
            std.mem.eql(u8, s, "disabled"))
            return .off;
        if (std.mem.eql(u8, s, "minimal") or std.mem.eql(u8, s, "min"))
            return .minimal;
        if (std.mem.eql(u8, s, "low") or std.mem.eql(u8, s, "light") or
            std.mem.eql(u8, s, "浅"))
            return .low;
        if (std.mem.eql(u8, s, "medium") or std.mem.eql(u8, s, "mid") or
            std.mem.eql(u8, s, "中"))
            return .medium;
        if (std.mem.eql(u8, s, "high"))
            return .high;
        if (std.mem.eql(u8, s, "xhigh"))
            return .xhigh;
        if (std.mem.eql(u8, s, "max") or std.mem.eql(u8, s, "deep") or
            std.mem.eql(u8, s, "深"))
            return .max;
        return null;
    }

    pub fn label(self: ThinkLevel) []const u8 {
        return @tagName(self);
    }
};

/// 工具授权。对齐 Codex `/permissions` 能真正做到的三档
/// (piz 没有 OS sandbox,所以没有 workspace-write 那一档):
/// yolo = 不询问(Codex Full Access / `--yolo`);
/// ask = 危险工具先问;
/// read_only = 危险工具直接拒,读类放行。
pub const ApprovalMode = enum {
    yolo,
    ask,
    read_only,

    pub fn parse(s: []const u8) ?ApprovalMode {
        if (std.mem.eql(u8, s, "yolo") or std.mem.eql(u8, s, "full") or
            std.mem.eql(u8, s, "full-access") or std.mem.eql(u8, s, "never") or
            std.mem.eql(u8, s, "execute"))
            return .yolo;
        if (std.mem.eql(u8, s, "ask") or std.mem.eql(u8, s, "on-request") or
            std.mem.eql(u8, s, "confirm") or std.mem.eql(u8, s, "manual"))
            return .ask;
        if (std.mem.eql(u8, s, "read-only") or std.mem.eql(u8, s, "readonly") or
            std.mem.eql(u8, s, "ro") or std.mem.eql(u8, s, "read"))
            return .read_only;
        return null;
    }

    pub fn label(self: ApprovalMode) []const u8 {
        return switch (self) {
            .yolo => "yolo",
            .ask => "ask",
            .read_only => "read-only",
        };
    }

    pub fn uiLabel(self: ApprovalMode) []const u8 {
        return switch (self) {
            .yolo => "yolo",
            .ask => "ask",
            .read_only => "read-only",
        };
    }
};

/// `thinkingLevelMap` 一档的三态。对齐 pi `packages/coding-agent/docs/models.md`:
/// omitted = 走缺省(标准档到 high 可见;`xhigh`/`max` 要显式写出才出现);
/// hidden (`null`) = 不支持,UI 跳过;
/// send = 支持,请求里发这个字符串。
pub const ThinkSlot = union(enum) {
    omitted,
    hidden,
    send: []const u8,
};

pub const ThinkingLevelMap = struct {
    slots: [ThinkLevel.all.len]ThinkSlot = .{.omitted} ** ThinkLevel.all.len,

    pub fn get(self: ThinkingLevelMap, level: ThinkLevel) ThinkSlot {
        return self.slots[@intFromEnum(level)];
    }

    pub fn put(self: *ThinkingLevelMap, level: ThinkLevel, slot: ThinkSlot) void {
        self.slots[@intFromEnum(level)] = slot;
    }
};

/// 一条模型的能力。0 / null = 这项没配,继续往下回退(目录 → provider → 缺省)。
///
/// 来源只有两处,都不发 `/models` 请求:OpenAI 形的列表通常只有 id,没有窗口。
///   1. models.json 对象项(camelCase 或 OpenRouter 形 snake_case)
///   2. catalogMeta 里写死的已知模型
pub const ModelMeta = struct {
    context_window: u32 = 0,
    max_output: u32 = 0,
    vision: ?bool = null,
    reasoning: ?bool = null,
    think_map: ThinkingLevelMap = .{},
    /// models.json 或目录写过 thinkingLevelMap。
    think_map_set: bool = false,
    compat: Compat = .{},
};

/// 思考请求形状。词表抄 pi `thinkingFormat`,只留渠道实际会碰到的几档
/// (omp 也是这套,不另发明)。
pub const ThinkFormat = enum {
    openai,
    openrouter,
    deepseek,
    zai,
    together,
    qwen,

    pub fn parse(s: []const u8) ?ThinkFormat {
        if (std.mem.eql(u8, s, "openai")) return .openai;
        if (std.mem.eql(u8, s, "openrouter")) return .openrouter;
        if (std.mem.eql(u8, s, "deepseek")) return .deepseek;
        if (std.mem.eql(u8, s, "zai")) return .zai;
        if (std.mem.eql(u8, s, "together")) return .together;
        if (std.mem.eql(u8, s, "qwen")) return .qwen;
        return null;
    }

    pub fn label(self: ThinkFormat) []const u8 {
        return @tagName(self);
    }
};

/// 渠道兼容。null = 这项没写,走 detectCompat。
/// 字段名对齐 pi `OpenAICompletionsCompat`,只收发送路径用到的三个。
pub const Compat = struct {
    think_format: ?ThinkFormat = null,
    requires_reasoning_content: ?bool = null,
    supports_reasoning_effort: ?bool = null,
    /// anthropic-messages:`thinking.type: adaptive` + `output_config.effort`。
    /// 抄 pi `forceAdaptiveThinking`;未写则按模型 id 探测。
    force_adaptive_thinking: ?bool = null,
    /// 无 signature 时仍回放 thinking 块(部分兼容端点)。默认改成 text。
    allow_empty_signature: ?bool = null,
};

/// pi `thinkingBudgets`:预算思考(旧 Claude)每档 token。xhigh/max 夹到 high。
pub const ThinkingBudgets = struct {
    minimal: u32 = 1024,
    low: u32 = 2048,
    medium: u32 = 8192,
    high: u32 = 16384,

    pub fn forLevel(self: ThinkingBudgets, level: ThinkLevel) u32 {
        return switch (level) {
            .off => 0,
            .minimal => self.minimal,
            .low => self.low,
            .medium => self.medium,
            .high, .xhigh, .max => self.high,
        };
    }
};

/// 留给正文的下限。抄 pi `MIN_ANSWER_TOKENS`。
pub const MIN_ANSWER_TOKENS: u32 = 1024;

/// 抄 pi `adjustMaxTokensForThinking`。
pub fn adjustMaxTokensForThinking(base: u32, model_max: u32, level: ThinkLevel, budgets: ThinkingBudgets) struct { max_tokens: u32, thinking_budget: u32 } {
    var thinking_budget = budgets.forLevel(level);
    const cap = if (model_max > 0) model_max else base + thinking_budget;
    const max_tokens = if (base == 0) cap else @min(base + thinking_budget, cap);
    if (max_tokens <= thinking_budget) {
        thinking_budget = if (max_tokens > MIN_ANSWER_TOKENS) max_tokens - MIN_ANSWER_TOKENS else 0;
    }
    return .{ .max_tokens = max_tokens, .thinking_budget = thinking_budget };
}

pub const Provider = struct {
    name: []const u8,
    api: Api,
    base_url: []const u8,
    api_key: ?[]const u8 = null,
    models: []const []const u8 = &.{},
    /// 与 models 平行。空表或某项全 0 = 该模型没配,走目录 / provider 默认。
    model_metas: []const ModelMeta = &.{},
    /// provider 默认上下文窗口。0 = 未写,windowFor 再走目录或 DEFAULT。
    context_window: u32 = DEFAULT_CONTEXT_WINDOW,
    compat: Compat = .{},
};

pub fn parsePositiveU32(v: std.json.Value) ?u32 {
    switch (v) {
        .integer => |n| {
            if (n > 0 and n <= std.math.maxInt(u32)) return @intCast(n);
        },
        .float => |f| {
            if (f > 0 and f <= @as(f64, @floatFromInt(std.math.maxInt(u32))))
                return @intFromFloat(f);
        },
        else => {},
    }
    return null;
}

fn jsonPick(obj: std.json.ObjectMap, names: []const []const u8) ?std.json.Value {
    for (names) |n| {
        if (obj.get(n)) |v| return v;
    }
    return null;
}

/// 从模型对象抠能力。认 models.json 的 camelCase,也认 OpenRouter `/models` 形。
pub fn parseModelMeta(obj: std.json.ObjectMap) ModelMeta {
    var m = ModelMeta{};
    if (jsonPick(obj, &.{ "contextWindow", "context_window", "context_length" })) |v| {
        if (parsePositiveU32(v)) |n| m.context_window = n;
    }
    if (jsonPick(obj, &.{ "maxTokens", "max_tokens", "maxOutput", "max_output_tokens", "max_completion_tokens" })) |v| {
        if (parsePositiveU32(v)) |n| m.max_output = n;
    }
    if (jsonPick(obj, &.{ "vision", "hasVision" })) |v| {
        if (v == .bool) m.vision = v.bool;
    }
    // pi 的视觉字段是 input: ["text"] | ["text","image"],不是 bool
    if (obj.get("input")) |inp| {
        if (inp == .array) {
            var saw_image = false;
            for (inp.array.items) |it| {
                if (it == .string and (std.mem.eql(u8, it.string, "image") or std.mem.eql(u8, it.string, "image_url")))
                    saw_image = true;
            }
            m.vision = saw_image;
        }
    }
    if (jsonPick(obj, &.{ "reasoning", "thinking" })) |v| {
        if (v == .bool) m.reasoning = v.bool;
    }
    if (obj.get("thinkingLevelMap")) |raw| {
        if (raw == .object) {
            m.think_map = parseThinkMap(raw.object);
            m.think_map_set = true;
        }
    }
    m.compat = parseCompat(obj);
    if (obj.get("architecture")) |arch| {
        if (arch == .object) {
            if (arch.object.get("modality")) |mod| {
                if (mod == .string and std.mem.indexOf(u8, mod.string, "image") != null) m.vision = true;
            }
            if (arch.object.get("input_modalities")) |arr| {
                if (arr == .array) {
                    for (arr.array.items) |it| {
                        if (it == .string and (std.mem.eql(u8, it.string, "image") or std.mem.eql(u8, it.string, "image_url")))
                            m.vision = true;
                    }
                }
            }
        }
    }
    return m;
}

fn parseCompat(obj: std.json.ObjectMap) Compat {
    var c = Compat{};
    const src = if (obj.get("compat")) |raw| (if (raw == .object) raw.object else obj) else obj;
    if (src.get("thinkingFormat")) |v| {
        if (v == .string) c.think_format = ThinkFormat.parse(v.string);
    }
    if (src.get("requiresReasoningContentOnAssistantMessages")) |v| {
        if (v == .bool) c.requires_reasoning_content = v.bool;
    }
    if (src.get("supportsReasoningEffort")) |v| {
        if (v == .bool) c.supports_reasoning_effort = v.bool;
    }
    if (src.get("forceAdaptiveThinking")) |v| {
        if (v == .bool) c.force_adaptive_thinking = v.bool;
    }
    if (src.get("allowEmptySignature")) |v| {
        if (v == .bool) c.allow_empty_signature = v.bool;
    }
    return c;
}

/// 抄 pi `detectCompat`(openai-completions.ts)。只返回发送路径用到的三项。
/// `deepseek-v4` 出现在 id 里也要回放 reasoning_content(pi #3668,OpenRouter 同病)。
pub fn detectCompat(provider: *const Provider, model: []const u8) Compat {
    const name = provider.name;
    const url = provider.base_url;
    const is_zai = std.mem.eql(u8, name, "zai") or std.mem.eql(u8, name, "zai-coding-cn") or
        std.mem.indexOf(u8, url, "api.z.ai") != null or std.mem.indexOf(u8, url, "open.bigmodel.cn") != null;
    const is_together = std.mem.eql(u8, name, "together") or
        std.mem.indexOf(u8, url, "api.together.ai") != null or std.mem.indexOf(u8, url, "api.together.xyz") != null;
    const is_openrouter = std.mem.eql(u8, name, "openrouter") or std.mem.indexOf(u8, url, "openrouter.ai") != null;
    const is_deepseek = std.mem.eql(u8, name, "deepseek") or containsIgnoreCase(url, "deepseek.com");
    const is_moonshot = std.mem.eql(u8, name, "moonshotai") or std.mem.eql(u8, name, "moonshotai-cn") or
        std.mem.indexOf(u8, url, "api.moonshot.") != null;
    const is_grok = std.mem.eql(u8, name, "xai") or std.mem.indexOf(u8, url, "api.x.ai") != null;
    const is_nvidia = std.mem.eql(u8, name, "nvidia") or std.mem.indexOf(u8, url, "integrate.api.nvidia.com") != null;
    const is_ant = std.mem.eql(u8, name, "ant-ling") or std.mem.indexOf(u8, url, "api.ant-ling.com") != null;
    const is_cf_gw = std.mem.eql(u8, name, "cloudflare-ai-gateway") or
        std.mem.indexOf(u8, url, "gateway.ai.cloudflare.com") != null;

    const format: ThinkFormat = if (is_deepseek)
        .deepseek
    else if (is_zai)
        .zai
    else if (is_together)
        .together
    else if (is_openrouter)
        .openrouter
    else
        .openai;

    if (provider.api == .anthropic_messages) {
        return .{
            .force_adaptive_thinking = isAnthropicAdaptiveThinkingModel(model),
        };
    }

    return .{
        .think_format = format,
        .requires_reasoning_content = is_deepseek or std.mem.indexOf(u8, model, "deepseek-v4") != null,
        .supports_reasoning_effort = !(is_grok or is_zai or is_moonshot or is_together or is_cf_gw or is_nvidia or is_ant),
    };
}

/// 抄 pi `generate-models.ts` `isAnthropicAdaptiveThinkingModel`。
pub fn isAnthropicAdaptiveThinkingModel(model: []const u8) bool {
    return std.mem.indexOf(u8, model, "opus-4-6") != null or
        std.mem.indexOf(u8, model, "opus-4.6") != null or
        std.mem.indexOf(u8, model, "opus-4-7") != null or
        std.mem.indexOf(u8, model, "opus-4.7") != null or
        std.mem.indexOf(u8, model, "opus-4-8") != null or
        std.mem.indexOf(u8, model, "opus-4.8") != null or
        std.mem.indexOf(u8, model, "opus-5") != null or
        std.mem.indexOf(u8, model, "opus.5") != null or
        std.mem.indexOf(u8, model, "sonnet-4-6") != null or
        std.mem.indexOf(u8, model, "sonnet-4.6") != null or
        std.mem.indexOf(u8, model, "sonnet-5") != null or
        std.mem.indexOf(u8, model, "sonnet.5") != null or
        std.mem.indexOf(u8, model, "fable-5") != null;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn overlayCompat(base: Compat, over: Compat) Compat {
    return .{
        .think_format = over.think_format orelse base.think_format,
        .requires_reasoning_content = over.requires_reasoning_content orelse base.requires_reasoning_content,
        .supports_reasoning_effort = over.supports_reasoning_effort orelse base.supports_reasoning_effort,
        .force_adaptive_thinking = over.force_adaptive_thinking orelse base.force_adaptive_thinking,
        .allow_empty_signature = over.allow_empty_signature orelse base.allow_empty_signature,
    };
}

/// detect → provider.compat → 模型对象 compat。
pub fn resolveCompat(provider: *const Provider, model: []const u8) Compat {
    const meta = metaFor(provider, model);
    return overlayCompat(overlayCompat(detectCompat(provider, model), provider.compat), meta.compat);
}

fn parseThinkingBudgets(obj: std.json.ObjectMap) ThinkingBudgets {
    var b = ThinkingBudgets{};
    if (obj.get("minimal")) |v| {
        if (parsePositiveU32(v)) |n| b.minimal = n;
    }
    if (obj.get("low")) |v| {
        if (parsePositiveU32(v)) |n| b.low = n;
    }
    if (obj.get("medium")) |v| {
        if (parsePositiveU32(v)) |n| b.medium = n;
    }
    if (obj.get("high")) |v| {
        if (parsePositiveU32(v)) |n| b.high = n;
    }
    return b;
}

fn parseThinkMap(obj: std.json.ObjectMap) ThinkingLevelMap {
    var map = ThinkingLevelMap{};
    for (ThinkLevel.all) |level| {
        const v = obj.get(level.label()) orelse continue;
        switch (v) {
            .null => map.put(level, .hidden),
            .string => |s| map.put(level, .{ .send = s }),
            else => {},
        }
    }
    return map;
}

fn modelBareId(model: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, model, '/')) |i| model[i + 1 ..] else model;
}

/// 内置目录。数字抄自 pi `packages/ai/scripts/generate-models.ts` 的
/// `deepseekV4Models`(earendil-works/pi main)。那里只 push 了这两条,
/// 没有 deepseek-chat / deepseek-reasoner(生成器遇到 status=deprecated 会 skip)。
///
/// flash/pro 原文: contextWindow 1000000, maxTokens 384000,
/// reasoning true, input ["text"]。
pub fn catalogMeta(model: []const u8) ModelMeta {
    const name = modelBareId(model);
    if (std.mem.eql(u8, name, "deepseek-v4-flash") or std.mem.eql(u8, name, "deepseek-v4-pro")) {
        return .{
            .context_window = 1_000_000,
            .max_output = 384_000,
            .vision = false,
            .reasoning = true,
        };
    }
    // adaptive Claude:generate-models 给这些 id 标了 reasoning + forceAdaptiveThinking。
    // 窗口仍走 models.json / provider,不在这里编数字。
    if (isAnthropicAdaptiveThinkingModel(model)) {
        return .{ .reasoning = true };
    }
    // GPT-5.2+ 在 generate-models 里拿 xhigh(以及 5.6 的 max)。窗口不在这里编。
    if (supportsOpenAiXhigh(model)) {
        return .{ .reasoning = true };
    }
    return .{};
}

/// pi `generate-models.ts` `applyThinkingLevelMetadata`:
/// `api === "openai-completions" && id.includes("deepseek-v4")` 时套这三张表。
///
/// ```
/// DEEPSEEK_V4_THINKING_LEVEL_MAP = { minimal:null, low:null, medium:null, high:"high", max:"max" }
/// DEEPSEEK_V4_FLASH_THINKING_LEVEL_MAP = { ...that, low:"low" }
/// openrouter: { ...Pro, xhigh:"xhigh", max:null }
/// ```
pub fn catalogThinkMap(provider: *const Provider, model: []const u8) ?ThinkingLevelMap {
    if (catalogAnthropicThinkMap(model)) |m| return m;
    if (catalogOpenAiThinkMap(provider, model)) |m| return m;
    if (provider.api != .openai_completions) return null;
    if (std.mem.indexOf(u8, model, "deepseek-v4") == null) return null;

    var map = ThinkingLevelMap{};
    map.put(.minimal, .hidden);
    map.put(.low, .hidden);
    map.put(.medium, .hidden);
    map.put(.high, .{ .send = "high" });
    map.put(.max, .{ .send = "max" });

    if (std.mem.eql(u8, provider.name, "openrouter")) {
        map.put(.xhigh, .{ .send = "xhigh" });
        map.put(.max, .hidden);
        return map;
    }
    if (std.mem.eql(u8, provider.name, "deepseek") and std.mem.eql(u8, modelBareId(model), "deepseek-v4-flash")) {
        map.put(.low, .{ .send = "low" });
        return map;
    }
    return map;
}

/// pi `applyThinkingLevelMetadata` 里按模型 id 套的 Anthropic adaptive 表。
fn catalogAnthropicThinkMap(model: []const u8) ?ThinkingLevelMap {
    var map = ThinkingLevelMap{};
    var set = false;
    if (std.mem.indexOf(u8, model, "opus-4-6") != null or
        std.mem.indexOf(u8, model, "opus-4.6") != null or
        std.mem.indexOf(u8, model, "sonnet-4-6") != null or
        std.mem.indexOf(u8, model, "sonnet-4.6") != null)
    {
        map.put(.max, .{ .send = "max" });
        set = true;
    }
    if (std.mem.indexOf(u8, model, "opus-4-7") != null or
        std.mem.indexOf(u8, model, "opus-4.7") != null or
        std.mem.indexOf(u8, model, "opus-4-8") != null or
        std.mem.indexOf(u8, model, "opus-4.8") != null or
        std.mem.indexOf(u8, model, "opus-5") != null or
        std.mem.indexOf(u8, model, "opus.5") != null or
        std.mem.indexOf(u8, model, "sonnet-5") != null or
        std.mem.indexOf(u8, model, "sonnet.5") != null)
    {
        map.put(.xhigh, .{ .send = "xhigh" });
        map.put(.max, .{ .send = "max" });
        set = true;
    }
    if (std.mem.indexOf(u8, model, "fable-5") != null) {
        map.put(.off, .hidden);
        map.put(.xhigh, .{ .send = "xhigh" });
        map.put(.max, .{ .send = "max" });
        set = true;
    }
    return if (set) map else null;
}

/// pi `generate-models.ts` `supportsOpenAiXhigh`。
fn supportsOpenAiXhigh(model: []const u8) bool {
    return std.mem.indexOf(u8, model, "gpt-5.2") != null or
        std.mem.indexOf(u8, model, "gpt-5.3") != null or
        std.mem.indexOf(u8, model, "gpt-5.4") != null or
        std.mem.indexOf(u8, model, "gpt-5.5") != null or
        std.mem.indexOf(u8, model, "gpt-5.6") != null;
}

/// pi `OPENAI_RESPONSES_NONE_REASONING_MODELS`。Responses 上这些 id 的 off 发 `none`。
fn openaiResponsesOffSendsNone(model: []const u8) bool {
    const ids = [_][]const u8{
        "gpt-5.1",
        "gpt-5.2",
        "gpt-5.3-codex",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.4-nano",
        "gpt-5.5",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
    };
    const name = modelBareId(model);
    for (ids) |id| {
        if (std.mem.eql(u8, model, id) or std.mem.eql(u8, name, id)) return true;
    }
    return false;
}

/// pi `applyThinkingLevelMetadata` 的 OpenAI 段。Chat Completions 与 Responses 共用 xhigh/max;
/// `off: null` / `off: "none"` 只套 Responses。
fn catalogOpenAiThinkMap(provider: *const Provider, model: []const u8) ?ThinkingLevelMap {
    var map = ThinkingLevelMap{};
    var set = false;
    const responses = provider.api == .openai_responses;
    if (responses and std.mem.startsWith(u8, modelBareId(model), "gpt-5")) {
        map.put(.off, .hidden);
        set = true;
    }
    if (responses and std.mem.eql(u8, provider.name, "openai") and openaiResponsesOffSendsNone(model)) {
        map.put(.off, .{ .send = "none" });
        set = true;
    }
    if (supportsOpenAiXhigh(model)) {
        map.put(.xhigh, .{ .send = "xhigh" });
        set = true;
    }
    if (std.mem.indexOf(u8, model, "gpt-5.6") != null and
        (provider.api == .openai_responses or provider.api == .openai_completions))
    {
        map.put(.max, .{ .send = "max" });
        set = true;
    }
    if (std.mem.eql(u8, provider.name, "openai") and std.mem.eql(u8, modelBareId(model), "gpt-5.5")) {
        map.put(.minimal, .hidden);
        set = true;
    }
    if (std.mem.endsWith(u8, model, "gpt-5.5-pro")) {
        map.put(.off, .hidden);
        map.put(.minimal, .hidden);
        map.put(.low, .hidden);
        set = true;
    }
    return if (set) map else null;
}

fn overlayThinkMap(base: ThinkingLevelMap, over: ThinkingLevelMap) ThinkingLevelMap {
    var out = base;
    for (ThinkLevel.all) |level| {
        const slot = over.get(level);
        if (slot != .omitted) out.put(level, slot);
    }
    return out;
}

/// 该模型 UI 里能选的档。算法抄 pi `packages/ai/src/models.ts`
/// `getSupportedThinkingLevels`: reasoning 关则只有 off;`null` 隐藏;
/// `xhigh`/`max` 必须 map 里显式有非 null 才出现。
pub fn fillSupportedThinkLevels(meta: ModelMeta, buf: *[ThinkLevel.all.len]ThinkLevel) []const ThinkLevel {
    if (meta.reasoning != true) {
        buf[0] = .off;
        return buf[0..1];
    }
    var n: usize = 0;
    for (ThinkLevel.all) |level| {
        const slot = meta.think_map.get(level);
        if (slot == .hidden) continue;
        if ((level == .xhigh or level == .max) and slot == .omitted) continue;
        buf[n] = level;
        n += 1;
    }
    if (n == 0) {
        buf[0] = .off;
        return buf[0..1];
    }
    return buf[0..n];
}

/// 抄 pi `clampThinkingLevel`:先往高档找,再往低档找。
pub fn clampThinkLevel(meta: ModelMeta, level: ThinkLevel) ThinkLevel {
    var buf: [ThinkLevel.all.len]ThinkLevel = undefined;
    const avail = fillSupportedThinkLevels(meta, &buf);
    for (avail) |a| {
        if (a == level) return level;
    }
    const want = @intFromEnum(level);
    var i: usize = want;
    while (i < ThinkLevel.all.len) : (i += 1) {
        const cand: ThinkLevel = @enumFromInt(i);
        for (avail) |a| {
            if (a == cand) return cand;
        }
    }
    if (want > 0) {
        var j: usize = want;
        while (j > 0) {
            j -= 1;
            const cand: ThinkLevel = @enumFromInt(j);
            for (avail) |a| {
                if (a == cand) return cand;
            }
        }
    }
    return avail[0];
}

pub fn cycleThinkLevel(meta: ModelMeta, current: ThinkLevel, up: bool) ThinkLevel {
    var buf: [ThinkLevel.all.len]ThinkLevel = undefined;
    const avail = fillSupportedThinkLevels(meta, &buf);
    const cur = clampThinkLevel(meta, current);
    var idx: usize = 0;
    for (avail, 0..) |a, i| {
        if (a == cur) {
            idx = i;
            break;
        }
    }
    if (up) {
        if (idx + 1 < avail.len) return avail[idx + 1];
        return avail[idx];
    }
    if (idx > 0) return avail[idx - 1];
    return avail[idx];
}

/// 发给 provider 的 effort 字符串。off 或 hidden 返回 null。
pub fn thinkEffort(meta: ModelMeta, level: ThinkLevel) ?[]const u8 {
    if (level == .off) return null;
    return switch (meta.think_map.get(level)) {
        .send => |s| s,
        .omitted => level.label(),
        .hidden => null,
    };
}

pub fn writeSupportedThink(w: *std.Io.Writer, meta: ModelMeta) !void {
    var buf: [ThinkLevel.all.len]ThinkLevel = undefined;
    const avail = fillSupportedThinkLevels(meta, &buf);
    for (avail, 0..) |level, i| {
        if (i > 0) try w.writeByte('|');
        try w.writeAll(level.label());
    }
}

/// 合并后的能力:模型对象 > 内置目录 > provider 默认窗。
pub fn metaFor(provider: *const Provider, model: []const u8) ModelMeta {
    var out = catalogMeta(model);
    if (catalogThinkMap(provider, model)) |m| {
        out.think_map = m;
        out.think_map_set = true;
    }
    const n = @min(provider.models.len, provider.model_metas.len);
    for (provider.models[0..n], provider.model_metas[0..n]) |m, meta| {
        if (!std.mem.eql(u8, m, model)) continue;
        if (meta.context_window > 0) out.context_window = meta.context_window;
        if (meta.max_output > 0) out.max_output = meta.max_output;
        if (meta.vision) |v| out.vision = v;
        if (meta.reasoning) |v| out.reasoning = v;
        if (meta.think_map_set) {
            out.think_map = overlayThinkMap(out.think_map, meta.think_map);
            out.think_map_set = true;
        }
        out.compat = overlayCompat(out.compat, meta.compat);
        break;
    }
    if (out.context_window == 0) out.context_window = provider.context_window;
    if (out.context_window == 0) out.context_window = DEFAULT_CONTEXT_WINDOW;
    return out;
}

/// 查所选模型的上下文窗口。
pub fn windowFor(provider: *const Provider, model: []const u8) usize {
    return metaFor(provider, model).context_window;
}

pub const Resolved = struct {
    provider: *const Provider,
    model: []const u8,
    key: ?[]const u8,
};

pub const Config = struct {
    arena: *util.Arena,
    providers: []Provider = &.{},
    default_provider: ?[]const u8 = null,
    default_model: ?[]const u8 = null,
    /// settings.json 的 `defaultThinkingLevel`。字段名抄 pi。
    default_think_level: ?ThinkLevel = null,
    /// settings.json 的 `approvalMode`。缺省 yolo。
    default_approval: ApprovalMode = .yolo,
    /// settings.json 的 `thinkingBudgets`。未写用 pi 缺省。
    thinking_budgets: ThinkingBudgets = .{},
    /// settings.json 的 `plugins` 数组:要额外开启的可选插件名。
    enabled_plugins: []const []const u8 = &.{},
    /// settings.json 的 `disabled_plugins` 数组:要从出厂集关掉的插件名。
    disabled_plugins: []const []const u8 = &.{},
    /// 加载时解析失败的配置文件名(不含路径)。
    ///
    /// 语法错误的配置会被静默当成不存在,于是用户看到的是「unknown provider」
    /// 之类的下游症状,完全猜不到是自己的 JSON 少了个逗号。记下来在启动时提示。
    broken_files: []const []const u8 = &.{},

    /// 启动时点名解析失败的配置文件。走 stderr:stdout 留给管道下游。
    pub fn warnBroken(self: *const Config) void {
        for (self.broken_files) |name| {
            std.debug.print(
                "piz: ~/.piz/{s} 有语法错误,已按「不存在」处理。修好它才会生效。\n",
                .{name},
            );
        }
    }

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *Config) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn jsonVal(self: *Config, s: []const u8) !std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, self.allocator(), s, .{});
    }

    fn getStr(v: std.json.Value, key: []const u8) ?[]const u8 {
        if (v != .object) return null;
        const val = v.object.get(key) orelse return null;
        if (val != .string) return null;
        return val.string;
    }

    /// 加载全部 provider(内置 + models.json),并解析 settings。
    pub fn load(self: *Config) !void {
        const alloc = self.allocator();
        const cfg_dir = try util.configDir(alloc);

        // 解析失败的配置文件名。静默降级会让用户看到无关的下游症状
        // (「unknown provider」而非「你的 JSON 少了个逗号」),所以要记下来。
        var broken = std.array_list.Managed([]const u8).init(alloc);

        // --- 内置目录 ---
        const builtin = [_]Provider{
            .{
                .name = "deepseek",
                .api = .openai_completions,
                .base_url = "https://api.deepseek.com",
                .models = &.{ "deepseek-v4-flash", "deepseek-v4-pro" },
                .model_metas = &.{
                    .{ .context_window = 1_000_000, .max_output = 384_000, .vision = false, .reasoning = true },
                    .{ .context_window = 1_000_000, .max_output = 384_000, .vision = false, .reasoning = true },
                },
                .context_window = 1_000_000,
            },
            .{ .name = "openai", .api = .openai_completions, .base_url = "https://api.openai.com/v1", .models = &.{} },
            .{ .name = "anthropic", .api = .anthropic_messages, .base_url = "https://api.anthropic.com", .models = &.{} },
        };

        // --- models.json 动态 provider ---
        var file_providers = std.array_list.Managed(Provider).init(alloc);
        const models_path = try util.joinPath(alloc, cfg_dir, "models.json");
        if (std.Io.Dir.cwd().readFileAlloc(util.io, models_path, alloc, .limited(8 * 1024 * 1024))) |content| {
            defer alloc.free(content);
            const root = self.jsonVal(content) catch blk: {
                try broken.append("models.json");
                break :blk std.json.Value{ .null = {} };
            };
            if (root == .object) {
                if (root.object.get("providers")) |provs| {
                    if (provs == .object) {
                        var it = provs.object.iterator();
                        while (it.next()) |entry| {
                            const p = entry.value_ptr.*;
                            if (p != .object) continue;
                            const api_str = getStr(p, "api") orelse "openai-completions";
                            const base_url = getStr(p, "baseUrl") orelse continue;
                            const api_enum = if (std.mem.eql(u8, api_str, "anthropic-messages"))
                                Api.anthropic_messages
                            else if (std.mem.eql(u8, api_str, "openai-responses"))
                                Api.openai_responses
                            else
                                Api.openai_completions;
                            var models = std.array_list.Managed([]const u8).init(alloc);
                            var metas = std.array_list.Managed(ModelMeta).init(alloc);
                            var context_window: u32 = 0;
                            if (jsonPick(p.object, &.{ "contextWindow", "context_window" })) |cw| {
                                if (parsePositiveU32(cw)) |n| context_window = n;
                            }
                            if (p.object.get("models")) |ms| {
                                if (ms == .array) {
                                    for (ms.array.items) |m| {
                                        // 字符串模型名或 {id,name,contextWindow,maxTokens,vision,reasoning} 对象
                                        if (m == .string) {
                                            try models.append(m.string);
                                            try metas.append(.{});
                                        } else if (m == .object) {
                                            if (m.object.get("id")) |id| {
                                                if (id == .string) {
                                                    try models.append(id.string);
                                                    const meta = parseModelMeta(m.object);
                                                    try metas.append(meta);
                                                    if (meta.context_window > 0) {
                                                        context_window = @max(context_window, meta.context_window);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            if (context_window == 0) context_window = DEFAULT_CONTEXT_WINDOW;
                            try file_providers.append(.{
                                .name = entry.key_ptr.*,
                                .api = api_enum,
                                .base_url = base_url,
                                .api_key = getStr(p, "apiKey"),
                                .models = try models.toOwnedSlice(),
                                .model_metas = try metas.toOwnedSlice(),
                                .context_window = context_window,
                                .compat = parseCompat(p.object),
                            });
                        }
                    }
                }
            }
        } else |_| {}

        // --- auth.json 密钥 ---
        var auth_keys: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        const auth_path = try util.joinPath(alloc, cfg_dir, "auth.json");
        if (std.Io.Dir.cwd().readFileAlloc(util.io, auth_path, alloc, .limited(4 * 1024 * 1024))) |content| {
            defer alloc.free(content);
            const root = self.jsonVal(content) catch blk: {
                try broken.append("auth.json");
                break :blk std.json.Value{ .null = {} };
            };
            if (root == .object) {
                var it = root.object.iterator();
                while (it.next()) |entry| {
                    const v = entry.value_ptr.*;
                    const key = getStr(v, "key") orelse getStr(v, "apiKey") orelse continue;
                    try auth_keys.put(alloc, entry.key_ptr.*, key);
                }
            }
        } else |_| {}

        // --- discovery:codex 供应商密钥导入(auth.json 缺失时) ---
        // 极简:从 ~/.codex/config.toml 提取 experimental_bearer_token
        if (auth_keys.count() == 0) {
            const home = util.homeDir(alloc) catch null;
            if (home) |h| {
                defer alloc.free(h);
                const cx_path = try util.joinPath(alloc, h, ".codex/config.toml");
                if (std.Io.Dir.cwd().readFileAlloc(util.io, cx_path, alloc, .limited(2 * 1024 * 1024))) |cx| {
                    defer alloc.free(cx);
                    if (std.mem.indexOf(u8, cx, "experimental_bearer_token")) |pos| {
                        const rest = cx[pos..];
                        if (std.mem.indexOf(u8, rest, "\"")) |q1| {
                            const after = rest[q1 + 1 ..];
                            if (std.mem.indexOf(u8, after, "\"")) |q2| {
                                try auth_keys.put(alloc, "codex", after[0..q2]);
                            }
                        }
                    }
                } else |_| {}
            }
        }

        // --- settings.json ---
        const settings_path = try util.joinPath(alloc, cfg_dir, "settings.json");
        if (std.Io.Dir.cwd().readFileAlloc(util.io, settings_path, alloc, .limited(2 * 1024 * 1024))) |content| {
            defer alloc.free(content);
            const root = self.jsonVal(content) catch blk: {
                try broken.append("settings.json");
                break :blk std.json.Value{ .null = {} };
            };
            if (root == .object) {
                self.default_provider = getStr(root, "defaultProvider");
                self.default_model = getStr(root, "defaultModel");
                if (getStr(root, "defaultThinkingLevel")) |s| {
                    self.default_think_level = ThinkLevel.parse(s);
                }
                if (getStr(root, "approvalMode")) |s| {
                    if (ApprovalMode.parse(s)) |m| self.default_approval = m;
                }
                if (root.object.get("thinkingBudgets")) |raw| {
                    if (raw == .object) self.thinking_budgets = parseThinkingBudgets(raw.object);
                }
                // plugins: 要额外开启的可选插件名数组
                if (root.object.get("plugins")) |arr| {
                    if (arr == .array) {
                        var names = std.array_list.Managed([]const u8).init(alloc);
                        for (arr.array.items) |it| {
                            if (it == .string and it.string.len > 0) {
                                try names.append(try alloc.dupe(u8, it.string));
                            }
                        }
                        self.enabled_plugins = try names.toOwnedSlice();
                    }
                }
                if (root.object.get("disabled_plugins")) |arr| {
                    if (arr == .array) {
                        var names = std.array_list.Managed([]const u8).init(alloc);
                        for (arr.array.items) |it| {
                            if (it == .string and it.string.len > 0) {
                                try names.append(try alloc.dupe(u8, it.string));
                            }
                        }
                        self.disabled_plugins = try names.toOwnedSlice();
                    }
                }
            }
        } else |_| {}

        // --- 合并:builtin + file。同名文件项盖掉内置(否则 findModel 永远命中
        // 排在前面的内置 deepseek,models.json 里写的窗口等于没写)。
        var all = std.array_list.Managed(Provider).init(alloc);
        for (builtin) |p| {
            var merged = p;
            if (merged.api_key == null) {
                if (auth_keys.get(p.name)) |k| merged.api_key = k;
            }
            try all.append(merged);
        }
        for (file_providers.items) |p| {
            var merged = p;
            if (merged.api_key == null) {
                if (auth_keys.get(p.name)) |k| merged.api_key = k;
            }
            var replaced = false;
            for (all.items) |*ex| {
                if (!std.mem.eql(u8, ex.name, p.name)) continue;
                if (merged.api_key == null) merged.api_key = ex.api_key;
                if (merged.models.len == 0) {
                    merged.models = ex.models;
                    merged.model_metas = ex.model_metas;
                }
                if (p.context_window == DEFAULT_CONTEXT_WINDOW and ex.context_window != DEFAULT_CONTEXT_WINDOW) {
                    merged.context_window = ex.context_window;
                }
                merged.compat = overlayCompat(ex.compat, merged.compat);
                ex.* = merged;
                replaced = true;
                break;
            }
            if (!replaced) try all.append(merged);
        }
        self.providers = try all.toOwnedSlice();

        // --- env 覆盖 ---
        if (util.getEnv("PIZ_PROVIDER")) |p| self.default_provider = p;
        if (util.getEnv("PIZ_MODEL")) |m| self.default_model = m;

        self.broken_files = try broken.toOwnedSlice();
    }

    /// 按模型名找 provider(models 列表匹配;仅当 provider 无 models 配置时允许其名作模型)。
    /// 渠道名(有 models 的 provider 名)不算模型。
    pub fn findModel(self: *Config, model_name: []const u8) ?*const Provider {
        for (self.providers) |*p| {
            for (p.models) |m| {
                if (std.mem.eql(u8, m, model_name)) return p;
            }
        }
        for (self.providers) |*p| {
            if (p.models.len == 0 and std.mem.eql(u8, p.name, model_name)) return p;
        }
        return null;
    }

    /// 全部可用模型(provider:model 展示名)。
    pub fn allModels(self: *Config, alloc: std.mem.Allocator) [][]const u8 {
        var list = std.array_list.Managed([]const u8).init(alloc);
        for (self.providers) |p| {
            if (p.api_key == null) continue;
            // 只列真实模型(models 列表);空列表的渠道名不冒充模型
            for (p.models) |m| {
                list.append(alloc.dupe(u8, m) catch continue) catch continue;
            }
        }
        return list.toOwnedSlice() catch &.{};
    }

    pub fn resolve(self: *Config, provider_name: ?[]const u8, model_name: ?[]const u8) !Resolved {
        const want_provider = provider_name orelse self.default_provider orelse self.pickDefault();

        // env 密钥名:<PROVIDER>_API_KEY(去连字符,大写)
        var env_buf: [80]u8 = undefined;
        var i: usize = 0;
        if (want_provider.len + 8 <= env_buf.len) {
            for (want_provider) |c| {
                if (c == '-') continue;
                env_buf[i] = std.ascii.toUpper(c);
                i += 1;
            }
            @memcpy(env_buf[i .. i + 8], "_API_KEY");
            i += 8;
        }
        const key_from_env = if (i > 0) util.getEnv(env_buf[0..i]) else null;

        var found: ?*const Provider = null;
        for (self.providers) |*p| {
            if (std.mem.eql(u8, p.name, want_provider)) {
                found = p;
                break;
            }
        }
        const provider = found orelse return error.UnknownProvider;

        const model = model_name orelse self.default_model orelse (if (provider.models.len > 0) provider.models[0] else want_provider);
        const key = provider.api_key orelse key_from_env;
        return .{ .provider = provider, .model = model, .key = key };
    }

    fn pickDefault(self: *Config) []const u8 {
        for (self.providers) |*p| {
            if (p.api_key != null) return p.name;
        }
        return "deepseek";
    }

    /// 原子地写 JSON 配置文件(util 内无现成 JSON 落盘)。
    ///
    /// 先写同目录临时文件再 rename:直写目标路径的话,写到一半失败(磁盘满、被 kill)
    /// 会留下截断的配置。models.json 里是全部 provider 的 apiKey,配置比会话更
    /// 不能出现半个文件。
    ///
    /// 权限 0600:apiKey 不该让同机其他用户读到。
    fn writeJsonFile(alloc: std.mem.Allocator, path: []const u8, root: std.json.Value) !void {
        var aw = std.Io.Writer.Allocating.init(alloc);
        defer aw.deinit();
        try std.json.Stringify.value(root, .{ .whitespace = .indent_2 }, &aw.writer);
        const body = try aw.toOwnedSlice();
        defer alloc.free(body);
        const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
        defer alloc.free(tmp);
        errdefer std.Io.Dir.cwd().deleteFile(util.io, tmp) catch {};
        {
            const file = try std.Io.Dir.cwd().createFile(util.io, tmp, .{
                .truncate = true,
                .permissions = @enumFromInt(0o600),
            });
            defer file.close(util.io);
            var wbuf: [4096]u8 = undefined;
            var w = file.writer(util.io, &wbuf);
            try w.interface.writeAll(body);
            try w.interface.flush();
        }
        try std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), path, util.io);
    }

    /// 写 settings.json(defaultProvider/defaultModel)。
    pub fn saveSettings(self: *Config, provider: ?[]const u8, model: ?[]const u8) !void {
        const alloc = self.allocator();
        const cfg_dir = try util.configDir(alloc);
        defer alloc.free(cfg_dir);
        const path = try util.joinPath(alloc, cfg_dir, "settings.json");
        defer alloc.free(path);
        // 读现有(保留未知字段)。
        //
        // 解析失败必须**拒绝写入**:原先是 `catch root`,root 还是空对象,
        // 于是一个语法写错的 settings.json 会被 {"defaultModel":"x"} 整体覆盖 ——
        // 用户的 plugins 列表和自定义字段全丢。实测确认过:212 字节的配置
        // 被压成 28 字节。语法错误用户自己能修,被覆盖就永远没了。
        var root = std.json.Value{ .object = .{} };
        if (std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(2 * 1024 * 1024))) |content| {
            defer alloc.free(content);
            root = self.jsonVal(content) catch return error.ConfigUnparseable;
            if (root != .object) return error.ConfigUnparseable;
        } else |_| {
            // 文件不存在是正常的首次写入,继续用空对象
        }
        if (provider) |p| try root.object.put(alloc, "defaultProvider", .{ .string = p });
        if (model) |m| try root.object.put(alloc, "defaultModel", .{ .string = m });
        try writeJsonFile(alloc, path, root);
    }

    /// 写 settings.json 的 `defaultThinkingLevel`(pi 同名字段)。
    pub fn saveThinkLevel(self: *Config, level: ThinkLevel) !void {
        const alloc = self.allocator();
        const cfg_dir = try util.configDir(alloc);
        defer alloc.free(cfg_dir);
        const path = try util.joinPath(alloc, cfg_dir, "settings.json");
        defer alloc.free(path);
        var root = std.json.Value{ .object = .{} };
        if (std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(2 * 1024 * 1024))) |content| {
            defer alloc.free(content);
            root = self.jsonVal(content) catch return error.ConfigUnparseable;
            if (root != .object) return error.ConfigUnparseable;
        } else |_| {}
        try root.object.put(alloc, "defaultThinkingLevel", .{ .string = level.label() });
        self.default_think_level = level;
        try writeJsonFile(alloc, path, root);
    }

    /// 写 settings.json 的 `approvalMode`。
    pub fn saveApprovalMode(self: *Config, mode: ApprovalMode) !void {
        const alloc = self.allocator();
        const cfg_dir = try util.configDir(alloc);
        defer alloc.free(cfg_dir);
        const path = try util.joinPath(alloc, cfg_dir, "settings.json");
        defer alloc.free(path);
        var root = std.json.Value{ .object = .{} };
        if (std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(2 * 1024 * 1024))) |content| {
            defer alloc.free(content);
            root = self.jsonVal(content) catch return error.ConfigUnparseable;
            if (root != .object) return error.ConfigUnparseable;
        } else |_| {}
        try root.object.put(alloc, "approvalMode", .{ .string = mode.label() });
        self.default_approval = mode;
        try writeJsonFile(alloc, path, root);
    }

    /// 写 models.json(仅动态 provider;内置 deepseek/openai/anthropic 不落盘)。
    pub fn saveModels(self: *Config, providers: []const Provider) !void {
        const alloc = self.allocator();
        const cfg_dir = try util.configDir(alloc);
        defer alloc.free(cfg_dir);
        const path = try util.joinPath(alloc, cfg_dir, "models.json");
        defer alloc.free(path);
        // 读现有(保留对象格式:name/contextWindow/reasoning 等;仅更新 api/baseUrl/apiKey/models)。
        //
        // 与 saveSettings 同一个理由,但后果更重:models.json 里是**全部 provider 的
        // apiKey**。原先解析失败时 root 保持空对象,一次写入就把所有凭证覆盖掉 ——
        // 用户手工编辑打错一个逗号,再在 UI 里加个 provider,API key 全没了。
        // 解析不了就拒绝写,让用户先修文件。
        var root = std.json.Value{ .object = .{} };
        if (std.Io.Dir.cwd().readFileAlloc(util.io, path, alloc, .limited(8 * 1024 * 1024))) |content| {
            defer alloc.free(content);
            root = self.jsonVal(content) catch return error.ConfigUnparseable;
            if (root != .object) return error.ConfigUnparseable;
        } else |_| {
            // 文件不存在是正常的首次写入
        }
        var provs: std.json.ObjectMap = .{};
        if (root.object.get("providers")) |pv| {
            if (pv == .object) provs = pv.object;
        }
        for (providers) |p| {
            if (std.mem.eql(u8, p.name, "deepseek") or std.mem.eql(u8, p.name, "openai") or std.mem.eql(u8, p.name, "anthropic")) continue;
            // 保留原对象(若有);models 以 id 列表重建,其余字段保持
            var po: std.json.ObjectMap = .{};
            if (provs.get(p.name)) |existing| {
                if (existing == .object) po = existing.object;
            }
            try po.put(alloc, "api", .{ .string = switch (p.api) {
                .anthropic_messages => "anthropic-messages",
                .openai_responses => "openai-responses",
                .openai_completions => "openai-completions",
            } });
            try po.put(alloc, "baseUrl", .{ .string = p.base_url });
            if (p.api_key) |k| {
                try po.put(alloc, "apiKey", .{ .string = k });
            } else {
                _ = po.orderedRemove("apiKey");
            }
            if (p.models.len > 0) {
                var arr = std.json.Array.init(alloc);
                for (p.models) |m| try arr.append(.{ .string = m });
                try po.put(alloc, "models", .{ .array = arr });
            }
            try provs.put(alloc, p.name, .{ .object = po });
        }
        try root.object.put(alloc, "providers", .{ .object = provs });
        try writeJsonFile(alloc, path, root);
    }

    /// 组装请求 URL。
    pub fn endpointUrl(self: *Config, provider: *const Provider) ![]u8 {
        const alloc = self.arena.allocator();
        const base = provider.base_url;
        var url: []u8 = undefined;
        if (provider.api == .anthropic_messages) {
            if (std.mem.endsWith(u8, base, "v1")) {
                url = try std.fmt.allocPrint(alloc, "{s}/messages", .{base});
            } else if (std.mem.endsWith(u8, base, "/v1/")) {
                url = try std.fmt.allocPrint(alloc, "{s}messages", .{base});
            } else {
                url = try std.fmt.allocPrint(alloc, "{s}/v1/messages", .{base});
            }
        } else if (provider.api == .openai_responses) {
            if (std.mem.endsWith(u8, base, "v1")) {
                url = try std.fmt.allocPrint(alloc, "{s}/responses", .{base});
            } else if (std.mem.endsWith(u8, base, "/v1/")) {
                url = try std.fmt.allocPrint(alloc, "{s}responses", .{base});
            } else {
                url = try std.fmt.allocPrint(alloc, "{s}/v1/responses", .{base});
            }
        } else {
            if (std.mem.endsWith(u8, base, "chat/completions")) {
                url = try alloc.dupe(u8, base);
            } else if (std.mem.endsWith(u8, base, "v1")) {
                url = try std.fmt.allocPrint(alloc, "{s}/chat/completions", .{base});
            } else if (std.mem.endsWith(u8, base, "/v1/")) {
                url = try std.fmt.allocPrint(alloc, "{s}chat/completions", .{base});
            } else {
                url = try std.fmt.allocPrint(alloc, "{s}/v1/chat/completions", .{base});
            }
        }
        return url;
    }
};

test "endpoint url building" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    var c = Config{ .arena = &arena };
    defer c.deinit();
    const deepseek = Provider{ .name = "deepseek", .api = .openai_completions, .base_url = "https://api.deepseek.com" };
    const openai = Provider{ .name = "openai", .api = .openai_completions, .base_url = "https://api.openai.com/v1" };
    const antr = Provider{ .name = "anthropic", .api = .anthropic_messages, .base_url = "https://api.anthropic.com" };
    try t.expectEqualStrings("https://api.deepseek.com/v1/chat/completions", try c.endpointUrl(&deepseek));
    try t.expectEqualStrings("https://api.openai.com/v1/chat/completions", try c.endpointUrl(&openai));
    try t.expectEqualStrings("https://api.anthropic.com/v1/messages", try c.endpointUrl(&antr));
}

test "auth key merges into builtin provider" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    const a = arena.allocator();
    // 注:cfg.deinit 内部 deinit arena,勿重复 defer

    // 隔离 config dir:auth.json 含内置 provider deepseek 的 key
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);
    try tmp.dir.writeFile(util.io, .{ .sub_path = "auth.json", .data = "{\"deepseek\":{\"type\":\"api_key\",\"key\":\"sk-test\"}}" });

    var cfg = Config{ .arena = &arena };
    defer cfg.deinit();
    try cfg.load();
    const resolved = try cfg.resolve(null, null);
    try t.expectEqualStrings("deepseek", resolved.provider.name);
    try t.expectEqualStrings("sk-test", resolved.key.?);
    // 未配置 provider 无 key
    const openai = try cfg.resolve("openai", null);
    try t.expect(openai.key == null);
}

test "a syntactically broken config is never overwritten" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    const a = arena.allocator();

    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    // 用户手工编辑打错了,但文件里有 plugins 列表和自定义字段
    const broken = "{\n  \"plugins\": [\"skills\"],\n  \"mine\": 42,\n  OOPS\n}\n";
    try tmp.dir.writeFile(util.io, .{ .sub_path = "settings.json", .data = broken });
    // models.json 里是全部 provider 的 apiKey —— 覆盖它等于丢光凭证
    const keys = "{\"providers\":{\"p1\":{\"baseUrl\":\"http://x\",\"apiKey\":\"KEEP-ME\", OOPS}}}";
    try tmp.dir.writeFile(util.io, .{ .sub_path = "models.json", .data = keys });

    var cfg = Config{ .arena = &arena };
    defer cfg.deinit();
    try cfg.load();

    // 拒绝写入,而不是用新值覆盖
    try t.expectError(error.ConfigUnparseable, cfg.saveSettings(null, "newmodel"));
    try t.expectError(error.ConfigUnparseable, cfg.saveModels(&.{
        .{ .name = "p2", .api = .openai_completions, .base_url = "http://y" },
    }));

    // 原文件一个字节都没动 —— 语法错误用户能自己修,被覆盖就永远没了
    const s_after = try tmp.dir.readFileAlloc(util.io, "settings.json", a, .limited(1 << 16));
    try t.expectEqualStrings(broken, s_after);
    const m_after = try tmp.dir.readFileAlloc(util.io, "models.json", a, .limited(1 << 16));
    try t.expectEqualStrings(keys, m_after);

    // 语法修好后:写得进去,且未知字段保留
    try tmp.dir.writeFile(util.io, .{ .sub_path = "settings.json", .data = "{\"plugins\":[\"skills\"],\"mine\":42}" });
    try cfg.saveSettings(null, "newmodel");
    const ok_after = try tmp.dir.readFileAlloc(util.io, "settings.json", a, .limited(1 << 16));
    try t.expect(std.mem.indexOf(u8, ok_after, "\"mine\"") != null);
    try t.expect(std.mem.indexOf(u8, ok_after, "newmodel") != null);

    try cfg.saveThinkLevel(.low);
    const think_after = try tmp.dir.readFileAlloc(util.io, "settings.json", a, .limited(1 << 16));
    try t.expect(std.mem.indexOf(u8, think_after, "\"defaultThinkingLevel\"") != null);
    try t.expect(std.mem.indexOf(u8, think_after, "\"low\"") != null);
    try t.expectEqual(ThinkLevel.low, cfg.default_think_level.?);

    // apiKey 落盘不能让同机其他用户读到
    const st = try tmp.dir.statFile(util.io, "settings.json", .{});
    try t.expectEqual(@as(u32, 0o600), @as(u32, @intFromEnum(st.permissions)) & 0o777);
    // 临时文件不许残留
    try t.expectError(error.FileNotFound, tmp.dir.statFile(util.io, "settings.json.tmp", .{}));
}

test "load reports which config file failed to parse" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    const a = arena.allocator();

    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    // settings 坏、models 好、auth 缺失
    try tmp.dir.writeFile(util.io, .{ .sub_path = "settings.json", .data = "{ OOPS }" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "models.json", .data = "{\"providers\":{}}" });

    var cfg = Config{ .arena = &arena };
    defer cfg.deinit();
    try cfg.load();

    // 坏文件必须被点名 —— 否则用户只看到「unknown provider」这类下游症状,
    // 完全猜不到是自己的 JSON 少了个逗号。缺失的文件不算坏。
    try t.expectEqual(@as(usize, 1), cfg.broken_files.len);
    try t.expectEqualStrings("settings.json", cfg.broken_files[0]);

    // 加载仍然成功(降级为空配置),不能因为一个坏文件就起不来
    try t.expect(cfg.providers.len >= 3); // 内置 deepseek/openai/anthropic
}

test "windowFor prefers per-model window then provider default" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = Provider{
        .name = "glm",
        .api = .openai_completions,
        .base_url = "https://x",
        .models = &.{ "m-64k", "m-200k", "m-1m" },
        .model_metas = &.{
            .{ .context_window = 64 * 1024 },
            .{ .context_window = 200 * 1024 },
            .{ .context_window = 1_000_000 },
        },
        .context_window = 128 * 1024,
    };
    try t.expectEqual(@as(usize, 64 * 1024), windowFor(&p, "m-64k"));
    try t.expectEqual(@as(usize, 200 * 1024), windowFor(&p, "m-200k"));
    try t.expectEqual(@as(usize, 1_000_000), windowFor(&p, "m-1m"));
    // 未配置窗口的模型回退 provider 默认
    try t.expectEqual(@as(usize, 128 * 1024), windowFor(&p, "m-unknown"));
    // 内置 deepseek:没写 model_metas 也必须是 1M,不能再掉进 128K 缺省。
    const builtin_ds = Provider{
        .name = "deepseek",
        .api = .openai_completions,
        .base_url = "https://api.deepseek.com",
        .models = &.{ "deepseek-v4-flash", "deepseek-v4-pro" },
        .context_window = 1_000_000,
    };
    try t.expectEqual(@as(usize, 1_000_000), windowFor(&builtin_ds, "deepseek-v4-flash"));
    try t.expectEqual(@as(usize, 1_000_000), windowFor(&builtin_ds, "deepseek-v4-pro"));
    // 挂在别的 provider 上的同名 id,目录仍然认
    const other = Provider{
        .name = "volcark",
        .api = .anthropic_messages,
        .base_url = "https://x",
        .models = &.{"deepseek-v4-flash"},
        .context_window = DEFAULT_CONTEXT_WINDOW,
    };
    try t.expectEqual(@as(usize, 1_000_000), windowFor(&other, "deepseek-v4-flash"));
    _ = a;
}

test "models.json parses per-model contextWindow" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    const json =
        \\{"providers":{"glm":{"baseUrl":"https://glm.example","api":"openai-completions",
        \\"models":[{"id":"glm-64k","contextWindow":65536},{"id":"glm-1m","contextWindow":1000000},"glm-plain"]}}}
    ;
    try tmp.dir.writeFile(util.io, .{ .sub_path = "models.json", .data = json });

    var c = Config{ .arena = &arena };
    defer c.deinit();
    try c.load();
    var found = false;
    for (c.providers) |*p| {
        if (!std.mem.eql(u8, p.name, "glm")) continue;
        found = true;
        try t.expectEqual(@as(usize, 3), p.models.len);
        try t.expectEqual(@as(u32, 64 * 1024), p.model_metas[0].context_window);
        try t.expectEqual(@as(u32, 1_000_000), p.model_metas[1].context_window);
        try t.expectEqual(@as(u32, 0), p.model_metas[2].context_window); // 字符串模型项
        try t.expectEqual(@as(usize, 64 * 1024), windowFor(p, "glm-64k"));
        try t.expectEqual(@as(usize, 1_000_000), windowFor(p, "glm-1m"));
        // provider 默认 = 所有模型窗口的最大值(未写 provider 级 contextWindow 时)
        try t.expectEqual(@as(u32, 1_000_000), p.context_window);
    }
    try t.expect(found);
}

test "models.json parses provider contextWindow and model capabilities" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    const json =
        \\{"providers":{"mine":{"baseUrl":"https://x","contextWindow":200000,
        \\"models":[{"id":"v","context_length":64000,"maxTokens":8000,"vision":true,"reasoning":false}]}}}
    ;
    try tmp.dir.writeFile(util.io, .{ .sub_path = "models.json", .data = json });

    var c = Config{ .arena = &arena };
    defer c.deinit();
    try c.load();
    var found = false;
    for (c.providers) |*p| {
        if (!std.mem.eql(u8, p.name, "mine")) continue;
        found = true;
        try t.expectEqual(@as(u32, 200000), p.context_window);
        try t.expectEqual(@as(u32, 64000), p.model_metas[0].context_window);
        try t.expectEqual(@as(u32, 8000), p.model_metas[0].max_output);
        try t.expectEqual(true, p.model_metas[0].vision.?);
        try t.expectEqual(false, p.model_metas[0].reasoning.?);
        try t.expectEqual(@as(usize, 64000), windowFor(p, "v"));
    }
    try t.expect(found);
}

test "catalogMeta knows DeepSeek V4 and parseModelMeta reads OpenRouter shape" {
    const t = std.testing;
    const v4 = catalogMeta("deepseek-v4-flash");
    try t.expectEqual(@as(u32, 1_000_000), v4.context_window);
    try t.expectEqual(@as(u32, 384_000), v4.max_output);
    try t.expectEqual(false, v4.vision.?);
    try t.expectEqual(true, v4.reasoning.?);
    try t.expectEqual(@as(u32, 1_000_000), catalogMeta("acme/deepseek-v4-pro").context_window);
    try t.expectEqual(@as(u32, 0), catalogMeta("gpt-4o").context_window);
    // pi generate-models.ts 的 deepseekV4Models 没有这两条
    try t.expectEqual(@as(u32, 0), catalogMeta("deepseek-chat").context_window);
    try t.expectEqual(@as(u32, 0), catalogMeta("deepseek-reasoner").context_window);

    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const raw =
        \\{"id":"x","context_length":128000,"architecture":{"modality":"text+image"}}
    ;
    const val = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), raw, .{});
    const meta = parseModelMeta(val.object);
    try t.expectEqual(@as(u32, 128000), meta.context_window);
    try t.expectEqual(true, meta.vision.?);

    // pi 的 input 数组:有 image 才算视觉;只有 text 则明确没有
    const pi_raw =
        \\{"id":"llama","input":["text","image"],"contextWindow":128000,"maxTokens":32000,"reasoning":false}
    ;
    const pi_val = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), pi_raw, .{});
    const pi_meta = parseModelMeta(pi_val.object);
    try t.expectEqual(true, pi_meta.vision.?);
    try t.expectEqual(@as(u32, 128000), pi_meta.context_window);
    try t.expectEqual(@as(u32, 32000), pi_meta.max_output);
    try t.expectEqual(false, pi_meta.reasoning.?);
}

fn expectLevels(meta: ModelMeta, want: []const ThinkLevel) !void {
    var buf: [ThinkLevel.all.len]ThinkLevel = undefined;
    const got = fillSupportedThinkLevels(meta, &buf);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqual(w, g);
}

test "DeepSeek V4 thinkingLevelMap matches pi generate-models.ts" {
    const t = std.testing;
    const ds = Provider{
        .name = "deepseek",
        .api = .openai_completions,
        .base_url = "https://api.deepseek.com",
        .models = &.{ "deepseek-v4-flash", "deepseek-v4-pro" },
    };
    const flash = metaFor(&ds, "deepseek-v4-flash");
    const pro = metaFor(&ds, "deepseek-v4-pro");
    try expectLevels(flash, &.{ .off, .low, .high, .max });
    try expectLevels(pro, &.{ .off, .high, .max });
    try t.expectEqualStrings("low", thinkEffort(flash, .low).?);
    try t.expectEqualStrings("high", thinkEffort(flash, .high).?);
    try t.expectEqualStrings("max", thinkEffort(pro, .max).?);
    try t.expect(thinkEffort(pro, .low) == null);
    try t.expectEqual(ThinkLevel.high, clampThinkLevel(pro, .low));
    try t.expectEqual(ThinkLevel.high, clampThinkLevel(pro, .medium));
    try t.expectEqual(ThinkLevel.max, clampThinkLevel(flash, .xhigh));
    try t.expectEqual(ThinkLevel.low, cycleThinkLevel(flash, .off, true));
    try t.expectEqual(ThinkLevel.high, cycleThinkLevel(pro, .off, true));
    try t.expectEqual(ThinkLevel.off, cycleThinkLevel(pro, .off, false));
    try t.expectEqual(ThinkLevel.max, cycleThinkLevel(pro, .max, true));

    const orouter = Provider{
        .name = "openrouter",
        .api = .openai_completions,
        .base_url = "https://openrouter.ai/api/v1",
        .models = &.{"deepseek/deepseek-v4-pro"},
    };
    try expectLevels(metaFor(&orouter, "deepseek/deepseek-v4-pro"), &.{ .off, .high, .xhigh });

    // 无 reasoning 的模型只有 off
    try expectLevels(.{ .reasoning = false }, &.{.off});
    // reasoning 开、没写 map:标准档到 high,没有 xhigh/max
    try expectLevels(.{ .reasoning = true }, &.{ .off, .minimal, .low, .medium, .high });
}

test "models.json thinkingLevelMap overlays catalog" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    const json =
        \\{"providers":{"deepseek":{"baseUrl":"https://api.deepseek.com","api":"openai-completions",
        \\"models":[{"id":"deepseek-v4-pro","reasoning":true,
        \\"thinkingLevelMap":{"low":"low","medium":null,"high":"high","max":"max"}}]}}}
    ;
    try tmp.dir.writeFile(util.io, .{ .sub_path = "models.json", .data = json });

    var c = Config{ .arena = &arena };
    defer c.deinit();
    try c.load();
    var found = false;
    for (c.providers) |*p| {
        if (!std.mem.eql(u8, p.name, "deepseek")) continue;
        found = true;
        const meta = metaFor(p, "deepseek-v4-pro");
        try expectLevels(meta, &.{ .off, .low, .high, .max });
        try t.expectEqualStrings("low", thinkEffort(meta, .low).?);
    }
    try t.expect(found);
}

test "detectCompat follows pi openai-completions.ts" {
    const t = std.testing;
    const ds = Provider{ .name = "deepseek", .api = .openai_completions, .base_url = "https://api.deepseek.com" };
    const d = detectCompat(&ds, "deepseek-v4-pro");
    try t.expectEqual(ThinkFormat.deepseek, d.think_format.?);
    try t.expectEqual(true, d.requires_reasoning_content.?);
    try t.expectEqual(true, d.supports_reasoning_effort.?);

    const oai = Provider{ .name = "openai", .api = .openai_completions, .base_url = "https://api.openai.com/v1" };
    const o = detectCompat(&oai, "gpt-5.4");
    try t.expectEqual(ThinkFormat.openai, o.think_format.?);
    try t.expectEqual(false, o.requires_reasoning_content.?);

    const orouter = Provider{ .name = "openrouter", .api = .openai_completions, .base_url = "https://openrouter.ai/api/v1" };
    const r = detectCompat(&orouter, "deepseek/deepseek-v4-flash");
    try t.expectEqual(ThinkFormat.openrouter, r.think_format.?);
    try t.expectEqual(true, r.requires_reasoning_content.?); // id 含 deepseek-v4

    const zai = Provider{ .name = "zai", .api = .openai_completions, .base_url = "https://api.z.ai/api/paas/v4" };
    const z = detectCompat(&zai, "glm-5");
    try t.expectEqual(ThinkFormat.zai, z.think_format.?);
    try t.expectEqual(false, z.supports_reasoning_effort.?);
}

test "ApprovalMode parse matches Codex aliases" {
    const t = std.testing;
    try t.expect(ApprovalMode.parse("yolo").? == .yolo);
    try t.expect(ApprovalMode.parse("never").? == .yolo);
    try t.expect(ApprovalMode.parse("ask").? == .ask);
    try t.expect(ApprovalMode.parse("on-request").? == .ask);
    try t.expect(ApprovalMode.parse("read-only").? == .read_only);
    try t.expect(ApprovalMode.parse("ro").? == .read_only);
    try t.expect(ApprovalMode.parse("nope") == null);
    try t.expectEqualStrings("yolo", ApprovalMode.yolo.label());
    try t.expectEqualStrings("yolo", ApprovalMode.yolo.uiLabel());
}

test "settings.json defaultThinkingLevel loads" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);
    try tmp.dir.writeFile(util.io, .{ .sub_path = "settings.json", .data = "{\"defaultThinkingLevel\":\"low\"}" });
    var c = Config{ .arena = &arena };
    defer c.deinit();
    try c.load();
    try t.expectEqual(ThinkLevel.low, c.default_think_level.?);
}

test "Anthropic adaptive maps and detect match pi generate-models.ts" {
    const t = std.testing;
    const ant = Provider{
        .name = "anthropic",
        .api = .anthropic_messages,
        .base_url = "https://api.anthropic.com",
    };
    try t.expectEqual(true, resolveCompat(&ant, "claude-sonnet-4-6").force_adaptive_thinking.?);
    try t.expectEqual(true, resolveCompat(&ant, "claude-opus-4-7").force_adaptive_thinking.?);
    try t.expectEqual(false, resolveCompat(&ant, "claude-sonnet-4-20250514").force_adaptive_thinking orelse false);

    try expectLevels(metaFor(&ant, "claude-sonnet-4-6"), &.{ .off, .minimal, .low, .medium, .high, .max });
    try expectLevels(metaFor(&ant, "claude-opus-4-7"), &.{ .off, .minimal, .low, .medium, .high, .xhigh, .max });
    try expectLevels(metaFor(&ant, "claude-fable-5"), &.{ .minimal, .low, .medium, .high, .xhigh, .max });
    try t.expectEqualStrings("max", thinkEffort(metaFor(&ant, "claude-sonnet-4-6"), .max).?);
    try t.expectEqualStrings("xhigh", thinkEffort(metaFor(&ant, "claude-opus-4-7"), .xhigh).?);
}

test "OpenAI GPT thinkingLevelMap matches pi generate-models.ts for chat and responses" {
    const t = std.testing;
    const chat = Provider{
        .name = "openai",
        .api = .openai_completions,
        .base_url = "https://api.openai.com/v1",
    };
    const resp = Provider{
        .name = "openai",
        .api = .openai_responses,
        .base_url = "https://api.openai.com/v1",
    };

    try t.expectEqual(true, catalogMeta("gpt-5.4").reasoning.?);
    try t.expectEqual(@as(u32, 0), catalogMeta("gpt-5.4").context_window);
    try expectLevels(metaFor(&chat, "gpt-5.4"), &.{ .off, .minimal, .low, .medium, .high, .xhigh });
    try expectLevels(metaFor(&resp, "gpt-5.4"), &.{ .off, .minimal, .low, .medium, .high, .xhigh });
    try t.expectEqualStrings("xhigh", thinkEffort(metaFor(&chat, "gpt-5.4"), .xhigh).?);
    try t.expectEqualStrings("none", switch (metaFor(&resp, "gpt-5.4").think_map.get(.off)) {
        .send => |s| s,
        else => "",
    });

    try expectLevels(metaFor(&chat, "gpt-5.6"), &.{ .off, .minimal, .low, .medium, .high, .xhigh, .max });
    try expectLevels(metaFor(&resp, "gpt-5.6"), &.{ .minimal, .low, .medium, .high, .xhigh, .max });
    try expectLevels(metaFor(&resp, "gpt-5.6-sol"), &.{ .off, .minimal, .low, .medium, .high, .xhigh, .max });
    try expectLevels(metaFor(&resp, "gpt-5.5"), &.{ .off, .low, .medium, .high, .xhigh });
    try expectLevels(metaFor(&resp, "gpt-5.5-pro"), &.{ .medium, .high, .xhigh });
    try expectLevels(metaFor(&chat, "gpt-5.5-pro"), &.{ .medium, .high, .xhigh });
    try t.expectEqual(ThinkLevel.xhigh, clampThinkLevel(metaFor(&chat, "gpt-5.4"), .max));
}

test "Anthropic proxy forceAdaptiveThinking and thinkingBudgets math" {
    const t = std.testing;
    const proxy = Provider{
        .name = "anthropic-proxy",
        .api = .anthropic_messages,
        .base_url = "https://proxy.example.com",
        .models = &.{"anthropic--claude-opus-latest"},
        .model_metas = &.{.{ .reasoning = true, .compat = .{ .force_adaptive_thinking = true } }},
    };
    try t.expectEqual(true, resolveCompat(&proxy, "anthropic--claude-opus-latest").force_adaptive_thinking.?);

    const adj = adjustMaxTokensForThinking(8192, 64000, .high, .{});
    try t.expectEqual(@as(u32, 16384), adj.thinking_budget);
    try t.expectEqual(@as(u32, 8192 + 16384), adj.max_tokens);
}

test "settings.json thinkingBudgets loads" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);
    try tmp.dir.writeFile(util.io, .{ .sub_path = "settings.json", .data = "{\"thinkingBudgets\":{\"high\":32768}}" });
    var c = Config{ .arena = &arena };
    defer c.deinit();
    try c.load();
    try t.expectEqual(@as(u32, 32768), c.thinking_budgets.high);
    try t.expectEqual(@as(u32, 1024), c.thinking_budgets.minimal);
}
