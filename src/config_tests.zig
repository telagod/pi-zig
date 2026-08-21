//! config_tests.zig —— config.zig 的单测主体(endpoint/auth/加载/模型元/思考档)。
//! 拆自 config.zig(原净尾 613 行);config.zig 尾部 test 钩子引回,收集不变。
const std = @import("std");
const util = @import("util.zig");
const cfg = @import("config.zig");

const Config = cfg.Config;
const Provider = cfg.Provider;
const ModelMeta = cfg.ModelMeta;
const ThinkLevel = cfg.ThinkLevel;
const ThinkFormat = cfg.ThinkFormat;
const ApprovalMode = cfg.ApprovalMode;
const CacheRetention = cfg.CacheRetention;
const SandboxMode = cfg.SandboxMode;
const DEFAULT_CONTEXT_WINDOW = cfg.DEFAULT_CONTEXT_WINDOW;
const authProviderOk = cfg.authProviderOk;
const parseModelsList = cfg.parseModelsList;
const modelsEndpoint = cfg.modelsEndpoint;
const refreshProviders = cfg.refreshProviders;
const parseModelMeta = cfg.parseModelMeta;
const catalogMeta = cfg.catalogMeta;
const detectCompat = cfg.detectCompat;
const resolveCompat = cfg.resolveCompat;
const metaFor = cfg.metaFor;
const windowFor = cfg.windowFor;
const clampThinkLevel = cfg.clampThinkLevel;
const fillSupportedThinkLevels = cfg.fillSupportedThinkLevels;
const cycleThinkLevel = cfg.cycleThinkLevel;
const thinkEffort = cfg.thinkEffort;
const adjustMaxTokensForThinking = cfg.adjustMaxTokensForThinking;
const providerIsSub = cfg.providerIsSub;

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

test "saveAuth merges keys into auth.json" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);
    var c = Config{ .arena = &arena };
    try c.saveAuth("deepseek", "sk-a");
    try c.saveAuth("openai", "sk-b");
    const raw = try std.Io.Dir.cwd().readFileAlloc(util.io, try util.joinPath(a, tmp_path, "auth.json"), a, .limited(64 * 1024));
    try t.expect(std.mem.indexOf(u8, raw, "sk-a") != null);
    try t.expect(std.mem.indexOf(u8, raw, "sk-b") != null);
    try t.expect(std.mem.indexOf(u8, raw, "deepseek") != null);
    try t.expectError(error.BadProvider, c.saveAuth("../x", "k"));
    try t.expectError(error.EmptyKey, c.saveAuth("deepseek", "  "));
    try t.expect(authProviderOk("deepseek"));
    try t.expect(!authProviderOk(""));
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

    var c = Config{ .arena = &arena };
    defer c.deinit();
    try c.load();
    const resolved = try c.resolve(null, null);
    try t.expectEqualStrings("deepseek", resolved.provider.name);
    try t.expectEqualStrings("sk-test", resolved.key.?);
    // 未配置 provider 无 key
    const openai = try c.resolve("openai", null);
    try t.expect(openai.key == null);
}

test "reloadSettings picks up theme and approval" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);
    try tmp.dir.writeFile(util.io, .{ .sub_path = "settings.json", .data = "{\"theme\":\"light\",\"approvalMode\":\"ask\",\"sandboxMode\":\"workspace\"}" });
    var c = Config{ .arena = &arena };
    defer c.deinit();
    try c.load();
    const out = try c.reloadSettings();
    try t.expectEqualStrings("light", c.theme);
    try t.expectEqual(ApprovalMode.ask, c.default_approval);
    try t.expectEqual(SandboxMode.workspace, c.default_sandbox);
    try t.expect(std.mem.indexOf(u8, out, "theme light") != null);
    try t.expect(std.mem.indexOf(u8, out, "approval ask") != null);
    try t.expect(std.mem.indexOf(u8, out, "sandbox workspace") != null);
    try t.expect(std.mem.indexOf(u8, out, "need restart") != null);
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

    var c = Config{ .arena = &arena };
    defer c.deinit();
    try c.load();

    // 拒绝写入,而不是用新值覆盖
    try t.expectError(error.ConfigUnparseable, c.saveSettings(null, "newmodel"));
    try t.expectError(error.ConfigUnparseable, c.saveModels(&.{
        .{ .name = "p2", .api = .openai_completions, .base_url = "http://y" },
    }));

    // 原文件一个字节都没动 —— 语法错误用户能自己修,被覆盖就永远没了
    const s_after = try tmp.dir.readFileAlloc(util.io, "settings.json", a, .limited(1 << 16));
    try t.expectEqualStrings(broken, s_after);
    const m_after = try tmp.dir.readFileAlloc(util.io, "models.json", a, .limited(1 << 16));
    try t.expectEqualStrings(keys, m_after);

    // 语法修好后:写得进去,且未知字段保留
    try tmp.dir.writeFile(util.io, .{ .sub_path = "settings.json", .data = "{\"plugins\":[\"skills\"],\"mine\":42}" });
    try c.saveSettings(null, "newmodel");
    const ok_after = try tmp.dir.readFileAlloc(util.io, "settings.json", a, .limited(1 << 16));
    try t.expect(std.mem.indexOf(u8, ok_after, "\"mine\"") != null);
    try t.expect(std.mem.indexOf(u8, ok_after, "newmodel") != null);

    try c.saveThinkLevel(.low);
    const think_after = try tmp.dir.readFileAlloc(util.io, "settings.json", a, .limited(1 << 16));
    try t.expect(std.mem.indexOf(u8, think_after, "\"defaultThinkingLevel\"") != null);
    try t.expect(std.mem.indexOf(u8, think_after, "\"low\"") != null);
    try t.expectEqual(ThinkLevel.low, c.default_think_level.?);

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

    var c = Config{ .arena = &arena };
    defer c.deinit();
    try c.load();

    // 坏文件必须被点名 —— 否则用户只看到「unknown provider」这类下游症状,
    // 完全猜不到是自己的 JSON 少了个逗号。缺失的文件不算坏。
    try t.expectEqual(@as(usize, 1), c.broken_files.len);
    try t.expectEqualStrings("settings.json", c.broken_files[0]);

    // 加载仍然成功(降级为空配置),不能因为一个坏文件就起不来
    try t.expect(c.providers.len >= 3); // 内置 deepseek/openai/anthropic
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

test "parseModelsList reads OpenAI and OpenRouter /models" {
    const t = std.testing;
    const a = t.allocator;
    const openai =
        \\{"data":[{"id":"gpt-4o"},{"id":"o3-mini","context_window":200000}]}
    ;
    const found = try parseModelsList(a, openai);
    defer {
        for (found) |d| a.free(d.id);
        a.free(found);
    }
    try t.expectEqual(@as(usize, 2), found.len);
    try t.expectEqualStrings("gpt-4o", found[0].id);
    try t.expectEqual(@as(u32, 200000), found[1].meta.context_window);

    const orouter =
        \\{"data":[{"id":"openai/gpt-4o","architecture":{"input_modalities":["text","image"]},"context_length":128000}]}
    ;
    const found2 = try parseModelsList(a, orouter);
    defer {
        for (found2) |d| a.free(d.id);
        a.free(found2);
    }
    try t.expectEqualStrings("openai/gpt-4o", found2[0].id);
    try t.expectEqual(@as(u32, 128000), found2[0].meta.context_window);
    try t.expectEqual(true, found2[0].meta.vision.?);
}

test "modelsEndpoint joins /models once" {
    const t = std.testing;
    const a = t.allocator;
    const joined = try modelsEndpoint(a, "https://api.x.com/v1");
    defer a.free(joined);
    try t.expectEqualStrings("https://api.x.com/v1/models", joined);
    const already = try modelsEndpoint(a, "https://api.x.com/v1/models/");
    defer a.free(already);
    try t.expectEqualStrings("https://api.x.com/v1/models", already);
    const empty = refreshProviders(a, &[_]Provider{});
    try t.expectEqual(@as(usize, 0), empty.ok);
    try t.expectEqual(@as(usize, 0), empty.fail);
    try t.expectEqual(@as(usize, 0), empty.added);
}

test "catalogMeta knows DeepSeek V4 and parseModelMeta reads OpenRouter shape" {
    const t = std.testing;
    const v4 = catalogMeta("deepseek-v4-flash");
    try t.expectEqual(@as(u32, 1_000_000), v4.context_window);
    try t.expectEqual(@as(u32, 384_000), v4.max_output);
    try t.expectEqual(false, v4.vision.?);
    try t.expectEqual(true, v4.reasoning.?);
    try t.expectEqual(@as(u32, 1_000_000), catalogMeta("acme/deepseek-v4-pro").context_window);
    // 官方文档补录之实验视觉版(上游 pi-ai 未收,EXTRA 机制保 regen)
    const ve = catalogMeta("deepseek-v4-flash-vision-exp");
    try t.expectEqual(@as(u32, 1_000_000), ve.context_window);
    try t.expectEqual(@as(u32, 384_000), ve.max_output);
    try t.expectEqual(true, ve.vision.?);
    try t.expectEqual(true, ve.reasoning.?);
    try t.expect(catalogMeta("gpt-4o").context_window > 0);
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

test "SandboxMode parse aliases" {
    const t = std.testing;
    try t.expect(SandboxMode.parse("workspace").? == .workspace);
    try t.expect(SandboxMode.parse("strict").? == .strict);
    try t.expect(SandboxMode.parse("off").? == .off);
    try t.expectEqualStrings("workspace", SandboxMode.workspace.label());
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

test "settings.json cacheRetention loads" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);
    try tmp.dir.writeFile(util.io, .{ .sub_path = "settings.json", .data = "{\"cacheRetention\":\"long\"}" });
    var c = Config{ .arena = &arena };
    defer c.deinit();
    try c.load();
    try t.expectEqual(CacheRetention.long, c.cache_retention);
    try t.expect(CacheRetention.parse("bogus") == null);
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
    try t.expect(catalogMeta("gpt-5.4").context_window > 0);
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

test "providerIsSub: codex/kimi-coding 自动,显式标,普通 provider 否" {
    const t = std.testing;
    const codex = Provider{ .name = "codex", .api = .openai_responses, .base_url = "https://x" };
    const kimi = Provider{ .name = "kimi-coding", .api = .openai_completions, .base_url = "https://x" };
    const marked = Provider{ .name = "corp", .api = .openai_completions, .base_url = "https://x", .subscription = true };
    const plain = Provider{ .name = "deepseek", .api = .openai_completions, .base_url = "https://x" };
    try t.expect(providerIsSub(&codex));
    try t.expect(providerIsSub(&kimi));
    try t.expect(providerIsSub(&marked));
    try t.expect(!providerIsSub(&plain));
}
