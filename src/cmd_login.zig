// cmd_login.zig — `piz login`: write API key to ~/.piz/auth.json.
// API key only. No OAuth / Claude Pro / ChatGPT Plus subscription login.
const std = @import("std");
const util = @import("core").util;
const cfgmod = @import("core").config;

const usage =
    \\piz login [provider] [api-key]
    \\  piz login                  prompt for provider and key
    \\  piz login deepseek         prompt for key
    \\  piz login deepseek sk-...  write key and exit
    \\  piz login --list           which providers have a key
    \\
    \\Writes ~/.piz/auth.json. No OAuth. Keys also from models.json or <PROVIDER>_API_KEY.
    \\
;

pub fn run(alloc: std.mem.Allocator, args: *std.process.Args.Iterator) void {
    var list_only = false;
    var provider: ?[]const u8 = null;
    var key_arg: ?[]const u8 = null;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--list") or std.mem.eql(u8, a, "-l")) {
            list_only = true;
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

    if (list_only) {
        listKeys(&cfg);
        return;
    }

    const name = provider orelse blk: {
        if (!util.stdinIsTty()) {
            std.debug.print("{s}", .{usage});
            std.process.exit(2);
        }
        std.debug.print("provider (deepseek, openai, anthropic, or a models.json name): ", .{});
        var buf: [64]u8 = undefined;
        const line = util.readLineStdin(&buf) orelse {
            std.debug.print("piz login: no provider\n", .{});
            std.process.exit(2);
        };
        const t = std.mem.trim(u8, line, " \t\r\n");
        if (t.len == 0) {
            std.debug.print("piz login: no provider\n", .{});
            std.process.exit(2);
        }
        break :blk a.dupe(u8, t) catch {
            std.process.exit(1);
        };
    };

    if (std.mem.eql(u8, name, "openrouter") and key_arg == null) {
        std.debug.print("OpenRouter OAuth lives in the Web UI:\n  piz web\n  then Settings → Account → Sign in with OpenRouter\nOr paste a key: piz login openrouter sk-or-...\n", .{});
        return;
    }
    if (!cfgmod.authProviderOk(name)) {
        std.debug.print("piz login: bad provider name '{s}'\n", .{name});
        std.process.exit(2);
    }

    const key = key_arg orelse blk: {
        if (util.stdinIsTty()) std.debug.print("API key for {s}: ", .{name});
        var buf: [4096]u8 = undefined;
        const line = util.readLineStdin(&buf) orelse {
            std.debug.print("piz login: no key\n", .{});
            std.process.exit(2);
        };
        const t = std.mem.trim(u8, line, " \t\r\n");
        if (t.len == 0) {
            std.debug.print("piz login: empty key\n", .{});
            std.process.exit(2);
        }
        break :blk a.dupe(u8, t) catch {
            std.process.exit(1);
        };
    };

    cfg.saveAuth(name, key) catch |e| {
        std.debug.print("piz login: write auth.json failed: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    std.debug.print("saved {s} in auth.json\n", .{name});
}

fn listKeys(cfg: *cfgmod.Config) void {
    if (cfg.providers.len == 0) {
        std.debug.print("no providers\n", .{});
        return;
    }
    for (cfg.providers) |p| {
        const mark: []const u8 = if (p.api_key != null) "key set" else "no key";
        std.debug.print("{s:<16} {s}\n", .{ p.name, mark });
    }
}
