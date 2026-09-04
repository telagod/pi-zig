//! TUI 主题:对齐 pi theme JSON(vars + colors)。
//! 内置 dark/light;~/.piz/themes/{name}.json 可覆盖;settings.json `theme` /
//! $PIZ_THEME = dark|light|auto|自定义名。auto 看 COLORFGBG。

const std = @import("std");
const util = @import("core").util;

pub const ColorMode = enum { none, ansi256, truecolor };
pub const Scheme = enum { dark, light };
pub const PaintStatus = enum { running, ok, err };

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const Palette = struct {
    user_bg: Rgb,
    tool_pending: Rgb,
    tool_ok: Rgb,
    tool_err: Rgb,
    ok_fg: Rgb,
    err_fg: Rgb,
    warn_fg: Rgb,
    muted_fg: Rgb,
    dim_fg: Rgb,
    think_fg: Rgb,
    output_fg: Rgb,
    md_heading: Rgb,
    md_link: Rgb,
    md_link_url: Rgb,
    md_code: Rgb,
    md_code_block: Rgb,
    md_code_border: Rgb,
    md_quote: Rgb,
    md_quote_border: Rgb,
    md_hr: Rgb,
    md_list: Rgb,

    pub const dark = Palette{
        .user_bg = hex(0x1e1e24),
        .tool_pending = hex(0x22222a),
        .tool_ok = hex(0x1e2820),
        .tool_err = hex(0x321e1e),
        .ok_fg = hex(0x87c37a),
        .err_fg = hex(0xdd6666),
        .warn_fg = hex(0xe5c07b),
        .muted_fg = hex(0x909095),
        .dim_fg = hex(0x55555c),
        .think_fg = hex(0x75757e),
        .output_fg = hex(0x606068),
        .md_heading = hex(0xe5c07b),
        .md_link = hex(0x61afef),
        .md_link_url = hex(0x707078),
        .md_code = hex(0x56b6c2),
        .md_code_block = hex(0x87c37a),
        .md_code_border = hex(0x40404a),
        .md_quote = hex(0x909095),
        .md_quote_border = hex(0x40404a),
        .md_hr = hex(0x40404a),
        .md_list = hex(0x61afef),
    };

    pub const light = Palette{
        .user_bg = hex(0xe8e8e8),
        .tool_pending = hex(0xe8e8f0),
        .tool_ok = hex(0xe8f0e8),
        .tool_err = hex(0xf0e8e8),
        .ok_fg = hex(0x588458),
        .err_fg = hex(0xaa5555),
        .warn_fg = hex(0x9a7326),
        .muted_fg = hex(0x5a5a5a),
        .dim_fg = hex(0x8a8a8a),
        .think_fg = hex(0x6e6e6e),
        .output_fg = hex(0x7a7a7a),
        .md_heading = hex(0x9a7326),
        .md_link = hex(0x547da7),
        .md_link_url = hex(0x767676),
        .md_code = hex(0x5a8080),
        .md_code_block = hex(0x588458),
        .md_code_border = hex(0x6c6c6c),
        .md_quote = hex(0x6c6c6c),
        .md_quote_border = hex(0x6c6c6c),
        .md_hr = hex(0x6c6c6c),
        .md_list = hex(0x588458),
    };
};

fn hex(v: u24) Rgb {
    return .{ .r = @intCast(v >> 16), .g = @intCast((v >> 8) & 0xff), .b = @intCast(v & 0xff) };
}

/// 语义色。默认 dark + ansi256(测试与未 apply 时行为)。
pub const Theme = struct {
    mode: ColorMode = .ansi256,
    scheme: Scheme = .dark,
    pal: Palette = .dark,
    name: []const u8 = "dark",

    bg_user: []const u8 = "\x1b[48;5;236m",
    bg_tool_run: []const u8 = "\x1b[48;5;235m",
    bg_tool_ok: []const u8 = "\x1b[48;5;22m",
    bg_tool_err: []const u8 = "\x1b[48;5;52m",
    fg_ok: []const u8 = "\x1b[38;5;107m",
    fg_err: []const u8 = "\x1b[38;5;167m",
    fg_warn: []const u8 = "\x1b[38;5;178m",
    fg_muted: []const u8 = "\x1b[38;5;244m",
    fg_dim: []const u8 = "\x1b[38;5;242m",
    fg_think: []const u8 = "\x1b[38;5;242m",
    fg_output: []const u8 = "\x1b[38;5;240m",
    fg_md_heading: []const u8 = "\x1b[38;5;178m",
    fg_md_link: []const u8 = "\x1b[38;5;69m",
    fg_md_link_url: []const u8 = "\x1b[38;5;242m",
    fg_md_code: []const u8 = "\x1b[38;5;109m",
    fg_md_code_block: []const u8 = "\x1b[38;5;107m",
    fg_md_code_border: []const u8 = "\x1b[38;5;239m",
    fg_md_quote: []const u8 = "\x1b[38;5;244m",
    fg_md_quote_border: []const u8 = "\x1b[38;5;239m",
    fg_md_hr: []const u8 = "\x1b[38;5;239m",
    fg_md_list: []const u8 = "\x1b[38;5;107m",

    /// 自绘 ANSI 缓冲(自定义主题 / truecolor / light 时用)。
    store: [22][32]u8 = [_][32]u8{[_]u8{0} ** 32} ** 22,

    pub fn detectMode() ColorMode {
        if (util.getEnv("NO_COLOR") != null) return .none;
        if (util.getEnv("COLORTERM")) |ct| {
            if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit")) return .truecolor;
        }
        return .ansi256;
    }

    /// COLORFGBG 末段为终端背景色号:7/15 视为浅底。
    pub fn detectScheme() Scheme {
        const v = util.getEnv("COLORFGBG") orelse return .dark;
        const semi = std.mem.lastIndexOfScalar(u8, v, ';') orelse return .dark;
        const bg = std.fmt.parseInt(u8, v[semi + 1 ..], 10) catch return .dark;
        if (bg == 7 or bg == 15) return .light;
        return .dark;
    }

    pub fn detect() Theme {
        return resolve("auto");
    }

    /// name: dark|light|auto|自定义(读 ~/.piz/themes/{name}.json)。
    pub fn resolve(name: []const u8) Theme {
        var t = Theme{ .mode = detectMode() };
        const spec = util.getEnv("PIZ_THEME") orelse name;
        if (std.mem.eql(u8, spec, "light")) {
            t.scheme = .light;
            t.pal = .light;
            t.name = "light";
        } else if (std.mem.eql(u8, spec, "dark")) {
            t.scheme = .dark;
            t.pal = .dark;
            t.name = "dark";
        } else if (std.mem.eql(u8, spec, "auto") or spec.len == 0) {
            t.scheme = detectScheme();
            t.pal = if (t.scheme == .light) .light else .dark;
            t.name = if (t.scheme == .light) "light" else "dark";
        } else {
            t.scheme = detectScheme();
            t.pal = if (t.scheme == .light) .light else .dark;
            t.name = spec;
            _ = t.loadNamed(spec);
        }
        t.rebuild();
        return t;
    }

    pub fn bgUser(self: Theme) []const u8 {
        return if (self.mode == .none) "" else self.bg_user;
    }

    pub fn bgTool(self: Theme, status: PaintStatus) []const u8 {
        if (self.mode == .none) return "";
        return switch (status) {
            .running => self.bg_tool_run,
            .ok => self.bg_tool_ok,
            .err => self.bg_tool_err,
        };
    }

    pub fn fgStatus(self: Theme, status: PaintStatus) []const u8 {
        return switch (status) {
            .running => "",
            .ok => if (self.mode == .none) "\x1b[32m" else self.fg_ok,
            .err => if (self.mode == .none) "\x1b[31m" else self.fg_err,
        };
    }

    pub fn fgCtx(self: Theme, pct: usize) []const u8 {
        if (pct >= 90) return if (self.mode == .none) "\x1b[31m" else self.fg_err;
        if (pct >= 70) return if (self.mode == .none) "\x1b[33m" else self.fg_warn;
        return "";
    }

    pub fn muted(self: Theme) []const u8 {
        return if (self.mode == .none) "\x1b[2m" else self.fg_muted;
    }

    pub fn rebuild(self: *Theme) void {
        if (self.mode == .none) {
            self.bg_user = "";
            self.bg_tool_run = "";
            self.bg_tool_ok = "";
            self.bg_tool_err = "";
            self.fg_ok = "\x1b[32m";
            self.fg_err = "\x1b[31m";
            self.fg_warn = "\x1b[33m";
            self.fg_muted = "\x1b[2m";
            self.fg_dim = "\x1b[2m";
            self.fg_think = "\x1b[2m";
            self.fg_output = "\x1b[2m";
            self.fg_md_heading = "\x1b[1m";
            self.fg_md_link = "\x1b[4m";
            self.fg_md_link_url = "\x1b[2m";
            self.fg_md_code = "\x1b[36m";
            self.fg_md_code_block = "\x1b[32m";
            self.fg_md_code_border = "\x1b[2m";
            self.fg_md_quote = "\x1b[2m";
            self.fg_md_quote_border = "\x1b[2m";
            self.fg_md_hr = "\x1b[2m";
            self.fg_md_list = "\x1b[32m";
            return;
        }
        self.bg_user = self.put(0, true, self.pal.user_bg);
        self.bg_tool_run = self.put(1, true, self.pal.tool_pending);
        self.bg_tool_ok = self.put(2, true, self.pal.tool_ok);
        self.bg_tool_err = self.put(3, true, self.pal.tool_err);
        self.fg_ok = self.put(4, false, self.pal.ok_fg);
        self.fg_err = self.put(5, false, self.pal.err_fg);
        self.fg_warn = self.put(6, false, self.pal.warn_fg);
        self.fg_muted = self.put(7, false, self.pal.muted_fg);
        self.fg_dim = self.put(8, false, self.pal.dim_fg);
        self.fg_think = self.put(19, false, self.pal.think_fg);
        self.fg_output = self.put(20, false, self.pal.output_fg);
        self.fg_md_heading = self.put(9, false, self.pal.md_heading);
        self.fg_md_link = self.put(10, false, self.pal.md_link);
        self.fg_md_link_url = self.put(11, false, self.pal.md_link_url);
        self.fg_md_code = self.put(12, false, self.pal.md_code);
        self.fg_md_code_block = self.put(13, false, self.pal.md_code_block);
        self.fg_md_code_border = self.put(14, false, self.pal.md_code_border);
        self.fg_md_quote = self.put(15, false, self.pal.md_quote);
        self.fg_md_quote_border = self.put(16, false, self.pal.md_quote_border);
        self.fg_md_hr = self.put(17, false, self.pal.md_hr);
        self.fg_md_list = self.put(18, false, self.pal.md_list);
    }

    fn put(self: *Theme, slot: usize, bg: bool, rgb: Rgb) []const u8 {
        const n = writeSgr(&self.store[slot], self.mode, bg, rgb);
        return self.store[slot][0..n];
    }

    fn loadNamed(self: *Theme, name: []const u8) bool {
        var buf: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const dir = util.configDir(fba.allocator()) catch return false;
        const path = std.fmt.allocPrint(fba.allocator(), "{s}/themes/{s}.json", .{ dir, name }) catch return false;
        const content = std.Io.Dir.cwd().readFileAlloc(util.io, path, std.heap.page_allocator, .limited(256 * 1024)) catch return false;
        defer std.heap.page_allocator.free(content);
        return applyJson(self, content);
    }
};

fn writeSgr(out: *[32]u8, mode: ColorMode, bg: bool, rgb: Rgb) usize {
    return switch (mode) {
        .none => 0,
        .truecolor => blk: {
            const s = std.fmt.bufPrint(out, "\x1b[{d};2;{d};{d};{d}m", .{ @as(u8, if (bg) 48 else 38), rgb.r, rgb.g, rgb.b }) catch return 0;
            break :blk s.len;
        },
        .ansi256 => blk: {
            const s = std.fmt.bufPrint(out, "\x1b[{d};5;{d}m", .{ @as(u8, if (bg) 48 else 38), rgbTo256(rgb) }) catch return 0;
            break :blk s.len;
        },
    };
}

pub fn rgbTo256(c: Rgb) u8 {
    if (c.r == c.g and c.g == c.b) {
        if (c.r < 8) return 16;
        if (c.r > 248) return 231;
        return @intCast(232 + (@as(u16, c.r) - 8) * 24 / 247);
    }
    const q = struct {
        fn step(v: u8) u8 {
            if (v < 48) return 0;
            if (v < 115) return 1;
            return (v - 35) / 40;
        }
    };
    return 16 + 36 * q.step(c.r) + 6 * q.step(c.g) + q.step(c.b);
}

pub fn parseHex(s: []const u8) ?Rgb {
    var t = std.mem.trim(u8, s, " \t");
    if (t.len > 0 and t[0] == '#') t = t[1..];
    if (t.len != 6) return null;
    const v = std.fmt.parseInt(u24, t, 16) catch return null;
    return hex(v);
}

/// 解析 pi 式 theme JSON,覆盖 pal 已有字段。成功返回 true。
pub fn applyJson(t: *Theme, src: []const u8) bool {
    const alloc = std.heap.page_allocator;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, src, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const root = parsed.value.object;
    var vars_map = std.StringHashMap(Rgb).init(alloc);
    defer vars_map.deinit();
    if (root.get("vars")) |vs| {
        if (vs == .object) {
            var it = vs.object.iterator();
            while (it.next()) |e| {
                if (asRgb(e.value_ptr.*, null)) |rgb| {
                    vars_map.put(e.key_ptr.*, rgb) catch {};
                }
            }
        }
    }
    const colors = root.get("colors") orelse return vars_map.count() > 0;
    if (colors != .object) return false;
    const set = struct {
        fn go(pal: *Palette, key: []const u8, rgb: Rgb) void {
            if (std.mem.eql(u8, key, "userMessageBg")) pal.user_bg = rgb;
            if (std.mem.eql(u8, key, "toolPendingBg")) pal.tool_pending = rgb;
            if (std.mem.eql(u8, key, "toolSuccessBg")) pal.tool_ok = rgb;
            if (std.mem.eql(u8, key, "toolErrorBg")) pal.tool_err = rgb;
            if (std.mem.eql(u8, key, "success")) pal.ok_fg = rgb;
            if (std.mem.eql(u8, key, "error")) pal.err_fg = rgb;
            if (std.mem.eql(u8, key, "warning")) pal.warn_fg = rgb;
            if (std.mem.eql(u8, key, "muted")) pal.muted_fg = rgb;
            if (std.mem.eql(u8, key, "dim")) pal.dim_fg = rgb;
            if (std.mem.eql(u8, key, "thinkingText") or std.mem.eql(u8, key, "thinkFg")) pal.think_fg = rgb;
            if (std.mem.eql(u8, key, "outputFg") or std.mem.eql(u8, key, "toolOutput")) pal.output_fg = rgb;
            if (std.mem.eql(u8, key, "mdHeading")) pal.md_heading = rgb;
            if (std.mem.eql(u8, key, "mdLink")) pal.md_link = rgb;
            if (std.mem.eql(u8, key, "mdLinkUrl")) pal.md_link_url = rgb;
            if (std.mem.eql(u8, key, "mdCode")) pal.md_code = rgb;
            if (std.mem.eql(u8, key, "mdCodeBlock")) pal.md_code_block = rgb;
            if (std.mem.eql(u8, key, "mdCodeBlockBorder")) pal.md_code_border = rgb;
            if (std.mem.eql(u8, key, "mdQuote")) pal.md_quote = rgb;
            if (std.mem.eql(u8, key, "mdQuoteBorder")) pal.md_quote_border = rgb;
            if (std.mem.eql(u8, key, "mdHr")) pal.md_hr = rgb;
            if (std.mem.eql(u8, key, "mdListBullet")) pal.md_list = rgb;
        }
    }.go;
    var it = colors.object.iterator();
    var any = false;
    while (it.next()) |e| {
        if (asRgb(e.value_ptr.*, &vars_map)) |rgb| {
            set(&t.pal, e.key_ptr.*, rgb);
            any = true;
        }
    }
    return any;
}

fn asRgb(v: std.json.Value, vars_map: ?*const std.StringHashMap(Rgb)) ?Rgb {
    switch (v) {
        .string => |s| {
            if (parseHex(s)) |rgb| return rgb;
            if (vars_map) |m| return m.get(s);
            return null;
        },
        .integer => |n| {
            if (n < 0 or n > 255) return null;
            return xterm256(@intCast(n));
        },
        else => return null,
    }
}

fn xterm256(n: u8) Rgb {
    if (n < 16) {
        const tab = [_]Rgb{
            hex(0x000000), hex(0x800000), hex(0x008000), hex(0x808000),
            hex(0x000080), hex(0x800080), hex(0x008080), hex(0xc0c0c0),
            hex(0x808080), hex(0xff0000), hex(0x00ff00), hex(0xffff00),
            hex(0x0000ff), hex(0xff00ff), hex(0x00ffff), hex(0xffffff),
        };
        return tab[n];
    }
    if (n < 232) {
        const i = n - 16;
        const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
        return .{ .r = levels[i / 36], .g = levels[(i / 6) % 6], .b = levels[i % 6] };
    }
    const g: u8 = @intCast(8 + @as(u16, n - 232) * 10);
    return .{ .r = g, .g = g, .b = g };
}

test "rgbTo256 gray and cube" {
    const t = std.testing;
    try t.expectEqual(@as(u8, 16), rgbTo256(hex(0x000000)));
    try t.expectEqual(@as(u8, 231), rgbTo256(hex(0xffffff)));
    try t.expect(rgbTo256(hex(0x343541)) >= 16);
}

test "parseHex and applyJson vars" {
    const t = std.testing;
    try t.expectEqual(hex(0x343541), parseHex("#343541").?);
    var th = Theme{};
    try t.expect(applyJson(&th,
        \\{"name":"x","vars":{"userMsgBg":"#e8e8e8"},"colors":{"userMessageBg":"userMsgBg","success":"#588458"}}
    ));
    try t.expectEqual(hex(0xe8e8e8), th.pal.user_bg);
    try t.expectEqual(hex(0x588458), th.pal.ok_fg);
}

test "resolve light rebuilds codes" {
    const t = std.testing;
    var th = Theme{ .mode = .truecolor, .scheme = .light, .pal = .light };
    th.rebuild();
    try t.expect(std.mem.indexOf(u8, th.bgUser(), "232;232;232") != null);
    try t.expect(std.mem.indexOf(u8, th.bgTool(.ok), "232;240;232") != null);
}

test "luminance ladder keeps think and output distinct" {
    const t = std.testing;
    var dark = Theme{ .mode = .truecolor, .scheme = .dark, .pal = .dark };
    dark.rebuild();
    try t.expect(!std.mem.eql(u8, dark.fg_think, dark.fg_dim));
    try t.expect(!std.mem.eql(u8, dark.fg_think, dark.fg_output));
    try t.expect(!std.mem.eql(u8, dark.fg_output, dark.fg_muted));
    var light = Theme{ .mode = .truecolor, .scheme = .light, .pal = .light };
    light.rebuild();
    try t.expect(!std.mem.eql(u8, light.fg_think, light.fg_output));
}

test "rebuild after copy keeps color slices inside store" {
    const t = std.testing;
    var dest = Theme{ .mode = .truecolor, .scheme = .dark, .pal = .dark };
    dest.rebuild();
    var copy = dest;
    copy.rebuild();
    const lo = @intFromPtr(&copy.store);
    const hi = lo + @sizeOf(@TypeOf(copy.store));
    try t.expect(copy.fg_dim.len > 0);
    try t.expect(@intFromPtr(copy.fg_dim.ptr) >= lo);
    try t.expect(@intFromPtr(copy.fg_dim.ptr) < hi);
    try t.expect(@intFromPtr(copy.fg_muted.ptr) >= lo);
    try t.expect(@intFromPtr(copy.fg_think.ptr) >= lo);
    try t.expect(@intFromPtr(copy.fg_output.ptr) >= lo);
}
