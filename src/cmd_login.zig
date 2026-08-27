// cmd_login.zig — `piz login` / `piz logout`(参考 pi 的 /login 重做)。
// 分层:选 provider → 选凭据类型(API key / 订阅 OAuth 引导)→ 写 ~/.piz/auth.json。
// OAuth 本体在 web UI(piz web → Settings → Account);CLI 负责指路与 API key。
// auth.json 格式:{"<provider>": {"type":"api_key","key":"sk-..."}} 或
//                {"<provider>": {"type":"oauth","key":"..."}} 等(web OAuth 回写)。
const std = @import("std");
const util = @import("core").util;
const cfgmod = @import("core").config;

const usage =
    \\piz login                      选择 provider(列表)并保存凭据
    \\piz login <provider>           该 provider 交互存凭据
    \\piz login <provider> <api-key> 直写 key(脚本用)
    \\piz login --list               已配置 provider 与凭据状态
    \\piz login --clear <provider>   删除单个凭据
    \\piz login --clear --all        清空全部凭据
    \\piz logout [provider] [--all]  /login 的清除面(pi 风格)
    \\
    \\写 ~/.piz/auth.json。key 也可放 models.json 或 <PROVIDER>_API_KEY 环境变量。
    \\订阅类(OpenRouter/XAI/Codex)走 piz web → Settings → Account;CLI 只存 API key。
    \\
;

/// 内置 provider 表(选择器排序;models.json 里配置过的会追加)。
const builtin = [_]BuiltinProvider{
    .{ .name = "openai", .oauth = true, .note = "Codex 订阅(OAuth)或 API key" },
    .{ .name = "anthropic", .oauth = false, .note = "API key" },
    .{ .name = "xai", .oauth = true, .note = "Grok 订阅(web)或 API key" },
    .{ .name = "openrouter", .oauth = true, .note = "OAuth(web)或 API key" },
    .{ .name = "deepseek", .oauth = false, .note = "API key" },
    .{ .name = "groq", .oauth = false, .note = "API key" },
    .{ .name = "mistral", .oauth = false, .note = "API key" },
    .{ .name = "together", .oauth = false, .note = "API key" },
    .{ .name = "fireworks", .oauth = false, .note = "API key" },
    .{ .name = "cerebras", .oauth = false, .note = "API key" },
    .{ .name = "moonshotai", .oauth = false, .note = "API key" },
    .{ .name = "zai", .oauth = false, .note = "API key" },
};

/// TUI /login 选择器用:内置表条目(name/note/oauth 能力)。
pub const BuiltinProvider = struct { name: []const u8, oauth: bool, note: []const u8 };
pub const builtinProviders: []const BuiltinProvider = &builtin;

/// provider 是否支持订阅/OAuth(指路 web UI)。
pub fn providerOAuth(name: []const u8) bool {
    for (builtin) |b| {
        if (std.mem.eql(u8, b.name, name)) return b.oauth;
    }
    return false;
}

fn inTable(name: []const u8) bool {
    for (builtin) |b| {
        if (std.mem.eql(u8, b.name, name)) return true;
    }
    return false;
}

/// 逐字节读一行(无缓冲预读;readLineStdin 的 reader 会预读整块,
/// 第二次调用时剩余数据已被吞 —— 实机踩坑)。EOF 返回剩余或 null。
fn readLineRaw(buf: []u8) ?[]const u8 {
    var n: usize = 0;
    while (n < buf.len) {
        var ch: [1]u8 = undefined;
        const k = std.posix.read(std.posix.STDIN_FILENO, &ch) catch return null;
        if (k == 0) return if (n == 0) null else buf[0..n];
        if (ch[0] == '\n') return buf[0..n];
        buf[n] = ch[0];
        n += 1;
    }
    return buf[0..n];
}

/// 该 provider 的交互分支:先问凭据类型(cur 类),再存或指路。
fn interactFor(cfg: *cfgmod.Config, name: []const u8) void {
    if (!cfgmod.authProviderOk(name)) {
        std.debug.print("piz login: bad provider name '{s}'\n", .{name});
        std.process.exit(2);
    }
    var oauth = false;
    for (builtin) |b| {
        if (std.mem.eql(u8, b.name, name)) {
            oauth = b.oauth;
            break;
        }
    }
    if (oauth and !cfgHasKey(cfg, name)) {
        std.debug.print("\n{s} 支持订阅/OAuth —— 走 Web UI(浏览器登录):\n", .{name});
        std.debug.print("  piz web\n  然后 Settings → Account → Sign in\n\n", .{});
        std.debug.print("或者在这里直接存 API key [y/N]: ", .{});
        var buf: [8]u8 = undefined;
        const line = readLineRaw(&buf) orelse "";
        const t = std.mem.trim(u8, line, " \t\r\n");
        if (!(t.len == 1 and (t[0] == 'y' or t[0] == 'Y'))) {
            std.debug.print("未存。跑 piz web 用 OAuth,或 piz login {s} 后重来。\n", .{name});
            return;
        }
    }
    askKeyAndSave(cfg, name);
}

fn cfgHasKey(cfg: *cfgmod.Config, name: []const u8) bool {
    for (cfg.providers) |p| {
        if (std.mem.eql(u8, p.name, name) and p.api_key != null) return true;
    }
    return false;
}

fn askKeyAndSave(cfg: *cfgmod.Config, name: []const u8) void {
    if (util.stdinIsTty()) std.debug.print("API key for {s}: ", .{name});
    var buf: [4096]u8 = undefined;
    const line = readLineRaw(&buf) orelse {
        std.debug.print("\npiz login: no key\n", .{});
        std.process.exit(2);
    };
    const t = std.mem.trim(u8, line, " \t\r\n");
    if (t.len == 0) {
        std.debug.print("\npiz login: empty key\n", .{});
        std.process.exit(2);
    }
    saveKey(cfg, name, t);
}

fn saveKey(cfg: *cfgmod.Config, name: []const u8, key: []const u8) void {
    cfg.saveAuth(name, key) catch |e| {
        std.debug.print("piz login: write auth.json failed: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    std.debug.print("saved {s} → ~/.piz/auth.json (type=api_key)\n", .{name});
}

/// 选择器:piz login(无参,TTY 或管道)。编号选择,兼容管道 stdin。
fn interactiveSelect(arena: std.mem.Allocator, cfg: *cfgmod.Config) void {
    var names = std.array_list.Managed([]const u8).init(arena);
    for (builtin) |b| {
        names.append(b.name) catch {};
    }
    for (cfg.providers) |p| {
        var seen = false;
        for (names.items) |n| {
            if (std.mem.eql(u8, n, p.name)) {
                seen = true;
                break;
            }
        }
        if (!seen and !std.mem.eql(u8, p.name, "radius")) {
            names.append(p.name) catch {};
        }
    }
    if (names.items.len == 0) {
        std.debug.print("piz login: 无可用 provider。先在 models.json 配置,或从内置名单挑选:\n", .{});
        for (builtin) |b| std.debug.print("  {s}\n", .{b.name});
        std.process.exit(1);
    }
    while (true) {
        std.debug.print("\n选择 provider(输入编号;q 退出):\n", .{});
        for (names.items, 0..) |n, i| {
            var mark: []const u8 = " ";
            var oauth_mark: []const u8 = "";
            for (builtin) |b| {
                if (std.mem.eql(u8, b.name, n)) {
                    if (cfgHasKey(cfg, n)) mark = "*";
                    oauth_mark = if (b.oauth) " [OAuth/web]" else "";
                    break;
                }
            }
            // 非内置(仅 models.json)也标 key 状态
            if (std.mem.eql(u8, mark, " ") and cfgHasKey(cfg, n)) mark = "*";
            std.debug.print("  {d:>2}. {s}{s} {s} {s}\n", .{ i + 1, n, if (std.mem.eql(u8, mark, "*")) "  ✓" else "   ", oauth_mark, if (std.mem.eql(u8, mark, "*")) "已存 key" else "" });
        }
        std.debug.print("> ", .{});
        var buf: [64]u8 = undefined;
        const line = readLineRaw(&buf) orelse return;
        const t = std.mem.trim(u8, line, " \t\r\n");
        if (t.len == 0) continue;
        if (std.mem.eql(u8, t, "q")) return;
        if (t.len <= 3 and std.ascii.isDigit(t[0])) {
            const idx = std.fmt.parseInt(usize, t, 10) catch 0;
            if (idx >= 1 and idx <= names.items.len) {
                interactFor(cfg, names.items[idx - 1]);
                return;
            }
        } else {
            // 名字直配
            for (names.items) |n| {
                if (std.mem.eql(u8, n, t)) {
                    interactFor(cfg, n);
                    return;
                }
            }
        }
        std.debug.print("无效选择\n", .{});
    }
}

fn cfgHasProvider(cfg: *cfgmod.Config, name: []const u8) bool {
    for (cfg.providers) |p| {
        if (std.mem.eql(u8, p.name, name)) return true;
    }
    return false;
}

fn listKeys(cfg: *cfgmod.Config) void {
    if (cfg.providers.len == 0) {
        std.debug.print("no providers\n", .{});
        return;
    }
    std.debug.print("provider          凭据\n", .{});
    for (cfg.providers) |p| {
        const mark: []const u8 = if (p.api_key != null) "key set" else "no key";
        std.debug.print("{s:<18} {s}\n", .{ p.name, mark });
    }
    std.debug.print("\n订阅/OAuth 状态: piz web → Settings → Account\n", .{});
}

/// piz login / piz logout 主入口。
pub fn run(alloc: std.mem.Allocator, args: *std.process.Args.Iterator) void {
    var list_only = false;
    var clear = false;
    var clear_all = false;
    var provider: ?[]const u8 = null;
    var key_arg: ?[]const u8 = null;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--list") or std.mem.eql(u8, a, "-l")) {
            list_only = true;
        } else if (std.mem.eql(u8, a, "--clear")) {
            clear = true;
        } else if (std.mem.eql(u8, a, "--all")) {
            clear_all = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (provider == null) {
            provider = a;
        } else if (key_arg == null) {
            key_arg = a;
        }
    }

    var arena = util.Arena.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = cfgmod.Config{ .arena = &arena };
    cfg.load() catch |e| {
        std.debug.print("piz login: load config failed: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };

    // ---- logout / --clear 面 ----
    if (clear or clear_all) {
        logout(&cfg, provider, clear_all);
        return;
    }

    if (list_only) {
        listKeys(&cfg);
        return;
    }

    const name = provider orelse {
        interactiveSelect(a, &cfg);
        return;
    };

    if (!cfgmod.authProviderOk(name)) {
        std.debug.print("piz login: bad provider name '{s}'\n", .{name});
        std.process.exit(2);
    }

    if (key_arg) |k| {
        saveKey(&cfg, name, k);
        return;
    }
    interactFor(&cfg, name);
}

/// piz logout [provider] [--all]:清凭据。默认全清(pi /logout 语义)。
pub fn runLogout(alloc: std.mem.Allocator, args: *std.process.Args.Iterator) void {
    var provider: ?[]const u8 = null;
    var all = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--all")) {
            all = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("piz logout [provider] [--all]\n  清 auth.json 凭据;无参=全清(带确认,TTY 下)\n", .{});
            return;
        } else if (provider == null) {
            provider = a;
        }
    }
    var arena = util.Arena.init(alloc);
    defer arena.deinit();
    var cfg = cfgmod.Config{ .arena = &arena };
    cfg.load() catch |e| {
        std.debug.print("piz logout: load config failed: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    if (provider == null and !all and util.stdinIsTty()) {
        std.debug.print("清空全部凭据(auth.json 全删)? [y/N]: ", .{});
        var buf: [8]u8 = undefined;
        const line = readLineRaw(&buf) orelse "";
        const t = std.mem.trim(u8, line, " \t\r\n");
        if (!(t.len == 1 and (t[0] == 'y' or t[0] == 'Y'))) {
            std.debug.print("未清。指定 provider 如: piz logout deepseek\n", .{});
            return;
        }
        all = true;
    }
    logout(&cfg, provider, all);
}

/// 清凭据:provider 指定删单个;--all 或无 provider 全清。
fn logout(cfg: *cfgmod.Config, provider: ?[]const u8, all: bool) void {
    if (all or provider == null) {
        cfg.clearAuthAll() catch |e| {
            std.debug.print("piz logout: failed: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        std.debug.print("cleared all credentials in auth.json\n", .{});
        return;
    }
    cfg.clearAuth(provider.?) catch |e| {
        std.debug.print("piz logout: failed: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    std.debug.print("cleared {s} from auth.json\n", .{provider.?});
}
