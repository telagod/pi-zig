// config.zig — 配置与认证:settings.json / auth.json / models.json / 环境变量。
// 目录:~/.piz(或 $PIZ_DIR)。刻意不与官方 pi 共用,见 util.configDir 注释。
const std = @import("std");
const util = @import("util.zig");

pub const Api = enum { openai_completions, anthropic_messages, openai_responses };

pub const Provider = struct {
    name: []const u8,
    api: Api,
    base_url: []const u8,
    api_key: ?[]const u8 = null,
    models: []const []const u8 = &.{},
    /// 模型级上下文窗口(models.json 的 contextWindow),与 models 平行对齐。
    /// 0 = 该模型未配置,回退 context_window。
    ///
    /// 为什么要有:同 provider 下 64K/200K/1M 模型并存(如 GLM/Gemini 系),
    /// 图片规格与压缩硬线都该按**所选模型**的窗口定,而不是 provider 一刀切。
    model_windows: []const u32 = &.{},
    /// provider 默认上下文窗口(token)。模型级未配置时回退到这里(默认 128K)。
    context_window: u32 = 128 * 1024,
};

/// 查所选模型的上下文窗口:模型级优先,否则 provider 默认。
pub fn windowFor(provider: *const Provider, model: []const u8) usize {
    // 内置 deepseek 有 models、没有平行的 model_windows。for (a, b) 要求等长,
    // 否则一进 pruneHook → ctxWindow 就 SIGSEGV,print 模式起不来。
    const n = @min(provider.models.len, provider.model_windows.len);
    for (provider.models[0..n], provider.model_windows[0..n]) |m, w| {
        if (w > 0 and std.mem.eql(u8, m, model)) return w;
    }
    return provider.context_window;
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
            .{ .name = "deepseek", .api = .openai_completions, .base_url = "https://api.deepseek.com", .models = &.{ "deepseek-v4-flash", "deepseek-v4-pro" } },
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
                            var windows = std.array_list.Managed(u32).init(alloc);
                            var context_window: u32 = 128 * 1024;
                            if (p.object.get("models")) |ms| {
                                if (ms == .array) {
                                    for (ms.array.items) |m| {
                                        // 字符串模型名或 {id,name,contextWindow,...} 对象(取 id)
                                        if (m == .string) {
                                            try models.append(m.string);
                                            try windows.append(0); // 未配置,回退 provider 默认
                                        } else if (m == .object) {
                                            if (m.object.get("id")) |id| {
                                                if (id == .string) {
                                                    try models.append(id.string);
                                                    // 模型级窗口:0 = 未配置
                                                    var mw: u32 = 0;
                                                    if (m.object.get("contextWindow")) |cw| {
                                                        if (cw == .integer and cw.integer > 0 and cw.integer <= std.math.maxInt(u32)) {
                                                            mw = @intCast(cw.integer);
                                                        }
                                                    }
                                                    try windows.append(mw);
                                                }
                                            }
                                            // 上下文窗口:取最大(避免长窗口模型被误压缩)
                                            if (m.object.get("contextWindow")) |cw| {
                                                if (cw == .integer and cw.integer > 0 and cw.integer <= std.math.maxInt(u32)) {
                                                    context_window = @max(context_window, @as(u32, @intCast(cw.integer)));
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            try file_providers.append(.{
                                .name = entry.key_ptr.*,
                                .api = api_enum,
                                .base_url = base_url,
                                .api_key = getStr(p, "apiKey"),
                                .models = try models.toOwnedSlice(),
                                .model_windows = try windows.toOwnedSlice(),
                                .context_window = context_window,
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

        // --- 合并:builtin + file(统一补 auth.json 密钥——此前内置 provider 漏查) ---
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
            try all.append(merged);
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
        .model_windows = &.{ 64 * 1024, 200 * 1024, 1_000_000 },
        .context_window = 128 * 1024,
    };
    try t.expectEqual(@as(usize, 64 * 1024), windowFor(&p, "m-64k"));
    try t.expectEqual(@as(usize, 200 * 1024), windowFor(&p, "m-200k"));
    try t.expectEqual(@as(usize, 1_000_000), windowFor(&p, "m-1m"));
    // 未配置窗口的模型回退 provider 默认
    try t.expectEqual(@as(usize, 128 * 1024), windowFor(&p, "m-unknown"));
    // 内置 deepseek 形:有模型名、窗口表为空。不能崩。
    const builtin_ds = Provider{
        .name = "deepseek",
        .api = .openai_completions,
        .base_url = "https://api.deepseek.com",
        .models = &.{ "deepseek-v4-flash", "deepseek-v4-pro" },
    };
    try t.expectEqual(@as(usize, 128 * 1024), windowFor(&builtin_ds, "deepseek-v4-flash"));
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
        try t.expectEqual(@as(u32, 64 * 1024), p.model_windows[0]);
        try t.expectEqual(@as(u32, 1_000_000), p.model_windows[1]);
        try t.expectEqual(@as(u32, 0), p.model_windows[2]); // 字符串模型项
        try t.expectEqual(@as(usize, 64 * 1024), windowFor(p, "glm-64k"));
        try t.expectEqual(@as(usize, 1_000_000), windowFor(p, "glm-1m"));
        // provider 默认 = 所有模型窗口的最大值(旧语义保留)
        try t.expectEqual(@as(u32, 1_000_000), p.context_window);
    }
    try t.expect(found);
}
