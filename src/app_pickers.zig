//! app_pickers.zig —— TUI 选择器群(theme/think/approval/sandbox/model/resume)。
//! 拆自 main.zig(评审 P2:大文件按边界拆)。函数皆动 App 内部,故 import main.zig
//! 取类型与 tuiNote/tuiOk;main.zig 以 pub const 再导出,调用点零改动。
const std = @import("std");
const util = @import("core").util;
const cfgmod = @import("core").config;
const sessionmod = @import("core").session;
const pricing = @import("core").pricing;
const tui_mod = @import("tui");
const main_mod = @import("main.zig");

const App = main_mod.App;
const tuiNote = main_mod.tuiNote;
const tuiOk = main_mod.tuiOk;

pub fn persistTheme(app: *App, name: []const u8) void {
    app.cfg.saveTheme(name) catch |err| util.debugCatch("saveTheme", err);
}

pub fn openThemePicker(app: *App) void {
    const items = [_]tui_mod.PickerItem{
        .{ .label = "dark", .value = "dark" },
        .{ .label = "light", .value = "light" },
        .{ .label = "auto", .value = "auto" },
    };
    var sel: usize = 0;
    if (std.mem.eql(u8, app.cfg.theme, "light")) sel = 1;
    if (std.mem.eql(u8, app.cfg.theme, "auto")) sel = 2;
    tuiOk("picker.theme", app.tui.openPicker("theme", "theme", &items, sel));
}

pub fn persistThink(app: *App) void {
    app.cfg.saveThinkLevel(app.tui.think_level) catch |err| util.debugCatch("saveThinkLevel", err);
}

pub fn applyApproval(app: *App, mode: cfgmod.ApprovalMode) void {
    app.approval = mode;
    app.perm.always.store(mode == .yolo, .release);
    app.cfg.saveApprovalMode(mode) catch |err| util.debugCatch("saveApprovalMode", err);
}

pub fn applySandbox(app: *App, mode: cfgmod.SandboxMode) void {
    app.cfg.default_sandbox = mode;
    app.cfg.saveSandboxMode(mode) catch |err| util.debugCatch("saveSandboxMode", err);
}

pub fn openSandboxPicker(app: *App) void {
    const items = [_]tui_mod.PickerItem{
        .{ .label = "off", .hint = "no OS isolation", .value = "off" },
        .{ .label = "workspace", .hint = "workspace RW, rest RO", .value = "workspace" },
        .{ .label = "strict", .hint = "workspace + no network", .value = "strict" },
    };
    const sel: usize = switch (app.cfg.default_sandbox) {
        .off => 0,
        .workspace => 1,
        .strict => 2,
    };
    app.tui.openPicker("sandbox", "沙箱", &items, sel) catch |err| util.debugCatch("openSandboxPicker", err);
}

pub fn openApprovalPicker(app: *App) void {
    const items = [_]tui_mod.PickerItem{
        .{ .label = "yolo", .hint = "never ask", .value = "yolo" },
        .{ .label = "ask", .hint = "ask on dangerous tools", .value = "ask" },
        .{ .label = "read-only", .hint = "deny dangerous tools", .value = "read-only" },
    };
    const sel: usize = switch (app.approval) {
        .yolo => 0,
        .ask => 1,
        .read_only => 2,
    };
    tuiOk("tui.picker", app.tui.openPicker("permissions", "permissions", &items, sel));
}

pub fn openThinkPicker(app: *App) void {
    var buf: [cfgmod.ThinkLevel.all.len]cfgmod.ThinkLevel = undefined;
    const avail = cfgmod.fillSupportedThinkLevels(app.agent.modelMeta(), &buf);
    var items: [cfgmod.ThinkLevel.all.len]tui_mod.PickerItem = undefined;
    var sel: usize = 0;
    for (avail, 0..) |lv, i| {
        items[i] = .{ .label = tui_mod.thinkLabel(lv), .value = lv.label() };
        if (lv == app.tui.think_level) sel = i;
    }
    tuiOk("tui.picker", app.tui.openPicker("think", "thinking", items[0..avail.len], sel));
}

fn fmtWindow(buf: []u8, n: u32) []const u8 {
    if (n == 0) return "";
    if (n >= 1_000_000 and n % 1_000_000 == 0)
        return std.fmt.bufPrint(buf, "{d}M", .{n / 1_000_000}) catch "";
    if (n >= 1000) return std.fmt.bufPrint(buf, "{d}k", .{n / 1000}) catch "";
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch "";
}

fn modelCapsHint(alloc: std.mem.Allocator, p: *const cfgmod.Provider, model: []const u8) ![]u8 {
    const meta = cfgmod.metaFor(p, model);
    const rates = pricing.lookupAny(p.name, model);
    var wb: [16]u8 = undefined;
    const win = fmtWindow(&wb, meta.context_window);
    var bits = std.array_list.Managed(u8).init(alloc);
    errdefer bits.deinit();
    var need = false;
    if (win.len > 0) {
        try bits.appendSlice(win);
        need = true;
    }
    if (rates) |r| {
        if (need) try bits.appendSlice(" · ");
        const price = try std.fmt.allocPrint(alloc, "${d:.2}/{d:.2}", .{ r.input, r.output });
        defer alloc.free(price);
        try bits.appendSlice(price);
        need = true;
    }
    if (meta.reasoning == true) {
        if (need) try bits.appendSlice(" · ");
        try bits.appendSlice("think");
        need = true;
    }
    if (meta.vision == true) {
        if (need) try bits.appendSlice(" · ");
        try bits.appendSlice("vis");
    }
    return bits.toOwnedSlice();
}

pub fn refreshProviderModels(app: *App) void {
    const r = cfgmod.refreshProviders(app.alloc, app.cfg.providers);
    const msg = std.fmt.allocPrint(app.alloc, "refreshed {d} provider(s), +{d} models", .{ r.ok, r.added }) catch return;
    defer app.alloc.free(msg);
    tuiNote(app, "\x1b[2m", msg);
    if (r.fail > 0) {
        const warn = std.fmt.allocPrint(app.alloc, "{d} provider(s) failed GET /models", .{r.fail}) catch return;
        defer app.alloc.free(warn);
        tuiNote(app, "\x1b[2m", warn);
    }
}

pub fn openModelPicker(app: *App) void {
    var specs = std.array_list.Managed([]u8).init(app.alloc);
    defer {
        for (specs.items) |s| app.alloc.free(s);
        specs.deinit();
    }
    var hints = std.array_list.Managed([]u8).init(app.alloc);
    defer {
        for (hints.items) |s| app.alloc.free(s);
        hints.deinit();
    }
    var items = std.array_list.Managed(tui_mod.PickerItem).init(app.alloc);
    defer items.deinit();
    var sel: usize = 0;
    for (app.cfg.providers) |*p| {
        if (p.api_key == null) continue;
        for (p.models) |m| {
            const spec = std.fmt.allocPrint(app.alloc, "{s}/{s}", .{ p.name, m }) catch continue;
            specs.append(spec) catch {
                app.alloc.free(spec);
                continue;
            };
            if (std.mem.eql(u8, p.name, app.agent.provider.name) and std.mem.eql(u8, m, app.agent.model))
                sel = specs.items.len - 1;
            var hint: []const u8 = "";
            if (modelCapsHint(app.alloc, p, m)) |h| {
                hints.append(h) catch app.alloc.free(h);
                hint = h;
            } else |_| {}
            items.append(.{ .label = spec, .hint = hint, .value = spec }) catch |err| util.debugCatch("picker.model", err);
        }
    }
    if (items.items.len == 0) {
        tuiNote(app, "\x1b[2m", "no models configured");
        return;
    }
    tuiOk("tui.picker", app.tui.openPicker("model", "模型", items.items, sel));
}

pub fn openResumePicker(app: *App) void {
    const list = sessionmod.Session.list(app.alloc, app.agent.cwd) catch &.{};
    defer for (list) |s| {
        var s2 = s;
        s2.deinit();
    };
    if (list.len == 0) {
        tuiNote(app, "\x1b[2m", "no sessions yet — /new to start one");
        return;
    }
    var labels = std.array_list.Managed([]u8).init(app.alloc);
    defer {
        for (labels.items) |s| app.alloc.free(s);
        labels.deinit();
    }
    var hints = std.array_list.Managed([]u8).init(app.alloc);
    defer {
        for (hints.items) |s| app.alloc.free(s);
        hints.deinit();
    }
    var values = std.array_list.Managed([]u8).init(app.alloc);
    defer {
        for (values.items) |s| app.alloc.free(s);
        values.deinit();
    }
    var items = std.array_list.Managed(tui_mod.PickerItem).init(app.alloc);
    defer items.deinit();
    var sel: usize = 0;
    const now_ns = std.Io.Clock.now(.real, util.io).nanoseconds;
    for (list, 0..) |s, i| {
        const nstr = std.fmt.allocPrint(app.alloc, "{d}", .{i + 1}) catch continue;
        values.append(nstr) catch {
            app.alloc.free(nstr);
            continue;
        };
        var d = s.describe(app.alloc, now_ns) catch {
            const fallback = app.alloc.dupe(u8, s.sessionId()) catch continue;
            labels.append(fallback) catch {
                app.alloc.free(fallback);
                continue;
            };
            const hint = if (std.mem.eql(u8, s.path, app.sess.path)) "current" else "";
            if (std.mem.eql(u8, s.path, app.sess.path)) sel = i;
            items.append(.{ .label = fallback, .hint = hint, .value = nstr }) catch |err| util.debugCatch("picker.sess", err);
            continue;
        };
        labels.append(d.headline) catch {
            d.deinit(app.alloc);
            continue;
        };
        const cur = std.mem.eql(u8, s.path, app.sess.path);
        if (cur) sel = i;
        const hint = if (cur)
            std.fmt.allocPrint(app.alloc, "{d}  {s} · current", .{ i + 1, d.hint }) catch d.hint
        else
            std.fmt.allocPrint(app.alloc, "{d}  {s}", .{ i + 1, d.hint }) catch d.hint;
        if (hint.ptr != d.hint.ptr) app.alloc.free(d.hint);
        hints.append(hint) catch {
            app.alloc.free(hint);
            continue;
        };
        items.append(.{ .label = d.headline, .hint = hint, .value = nstr }) catch |err| util.debugCatch("picker.sess.d", err);
    }
    if (items.items.len == 0) {
        tuiNote(app, "\x1b[2m", "no sessions yet — /new to start one");
        return;
    }
    tuiOk("tui.picker", app.tui.openPicker("resume", "sessions", items.items, sel));
}
