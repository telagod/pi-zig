// tools_fs.zig — ignore / glob / regex / directory walk. Split from tools.zig.
const std = @import("std");
const util = @import("util.zig");
const seams = @import("seams.zig");
const tpath = @import("tools_path.zig");

fn diskRead(arena: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const f = seams.fs();
    return f.readFile(f.ctx, arena, path, limit);
}

// =====================================================================
// 搜索基础设施:glob 匹配 + 最小正则引擎 + 目录遍历(零外部依赖,不 spawn rg/fd)
// =====================================================================

/// 搜索时始终跳过的目录(构建产物与 VCS 元数据,搜它们只会污染结果)。
const SKIP_DIRS = [_][]const u8{
    ".git",          "zig-out",     ".zig-cache",    "node_modules", "target",
    "dist",          "__pycache__", ".venv",         "venv",         ".next",
    "vendor",        ".mypy_cache", ".pytest_cache", ".turbo",       ".cache",
    ".direnv",       ".gradle",     ".pnpm-store",   "Pods",         "buck-out",
    "site-packages",
};

pub fn isSkippedDir(name: []const u8) bool {
    for (SKIP_DIRS) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

fn appendIgnoreFile(arena: std.mem.Allocator, out: *std.array_list.Managed([]const u8), path: []const u8) void {
    const data = diskRead(arena, path, 256 * 1024) catch return;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        out.append(line) catch |err| util.debugCatch("ignore.line", err);
    }
}

fn loadIgnoreFiles(arena: std.mem.Allocator, dir: []const u8) []const []const u8 {
    var out = std.array_list.Managed([]const u8).init(arena);
    const names = [_][]const u8{ ".gitignore", ".ignore" };
    for (names) |n| {
        const p = util.joinPath(arena, dir, n) catch continue;
        appendIgnoreFile(arena, &out, p);
    }
    return out.toOwnedSlice() catch &.{};
}

fn dirHasGit(dir: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/.git", .{dir}) catch return false;
    if (std.Io.Dir.cwd().statFile(util.io, p, .{})) |_| return true else |_| return false;
}

fn parentDir(path: []const u8) ?[]const u8 {
    if (path.len == 0 or std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "/")) return null;
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse {
        if (std.mem.eql(u8, path, ".")) return null;
        return ".";
    };
    if (i == 0) return "/";
    return path[0..i];
}

pub const IgnoreRule = struct {
    pat: []const u8,
    /// gitignore 在搜索根之下时:该目录相对 root。
    base: []const u8 = "",
    /// gitignore 在搜索根之上时:搜索根相对该目录。
    prefix: []const u8 = "",
};

fn relBetween(ancestor: []const u8, descendant: []const u8) []const u8 {
    if (ancestor.len == 0 or std.mem.eql(u8, ancestor, descendant)) return "";
    if (descendant.len > ancestor.len and std.mem.startsWith(u8, descendant, ancestor) and descendant[ancestor.len] == '/')
        return descendant[ancestor.len + 1 ..];
    return "";
}

fn relUnderBase(rel: []const u8, base: []const u8) ?[]const u8 {
    if (base.len == 0) return rel;
    if (rel.len == base.len and std.mem.eql(u8, rel, base)) return "";
    if (rel.len > base.len and std.mem.startsWith(u8, rel, base) and rel[base.len] == '/')
        return rel[base.len + 1 ..];
    return null;
}

fn ruleLocalPath(alloc: std.mem.Allocator, r: IgnoreRule, rel: []const u8) ?[]const u8 {
    const local = relUnderBase(rel, r.base) orelse return null;
    if (r.prefix.len == 0) return local;
    if (local.len == 0) return r.prefix;
    return util.joinPath(alloc, r.prefix, local) catch null;
}

fn wrapIgnore(arena: std.mem.Allocator, pats: []const []const u8, base: []const u8, prefix: []const u8) []IgnoreRule {
    var out = std.array_list.Managed(IgnoreRule).init(arena);
    for (pats) |p| out.append(.{ .pat = p, .base = base, .prefix = prefix }) catch |err| util.debugCatch("ignore.wrap", err);
    return out.toOwnedSlice() catch &.{};
}

/// 从搜索根向上走到 .git 或文件系统根,先祖先后自身,后写的规则覆盖前者。
pub fn loadIgnoreRules(arena: std.mem.Allocator, root: []const u8) []IgnoreRule {
    var dirs = std.array_list.Managed([]const u8).init(arena);
    var cur: []const u8 = root;
    var n: usize = 0;
    while (n < 16) : (n += 1) {
        dirs.append(cur) catch break;
        if (dirHasGit(cur)) break;
        cur = parentDir(cur) orelse break;
        if (dirs.items.len > 1 and std.mem.eql(u8, dirs.items[dirs.items.len - 1], dirs.items[dirs.items.len - 2])) break;
    }
    var out = std.array_list.Managed(IgnoreRule).init(arena);
    var i = dirs.items.len;
    while (i > 0) {
        i -= 1;
        const extra = loadIgnoreFiles(arena, dirs.items[i]);
        const prefix = relBetween(dirs.items[i], root);
        out.appendSlice(wrapIgnore(arena, extra, "", prefix)) catch |err| util.debugCatch("ignore.merge", err);
    }
    return out.toOwnedSlice() catch &.{};
}

/// 工作区 root 的规则，再叠 listed rel 目录自己的 .gitignore。
pub fn ignoreRulesFor(alloc: std.mem.Allocator, root: []const u8, rel: []const u8) []const IgnoreRule {
    const rules = loadIgnoreRules(alloc, root);
    if (rel.len == 0) return rules;
    const abs = util.joinPath(alloc, root, rel) catch return rules;
    const extra_pats = loadIgnoreFiles(alloc, abs);
    if (extra_pats.len == 0) return rules;
    const extra = wrapIgnore(alloc, extra_pats, rel, "");
    var both = std.array_list.Managed(IgnoreRule).init(alloc);
    both.appendSlice(rules) catch return rules;
    both.appendSlice(extra) catch return rules;
    return both.toOwnedSlice() catch rules;
}

fn globMatchAnyDir(pat: []const u8, rel: []const u8) bool {
    var i: usize = 0;
    while (i <= rel.len) : (i += 1) {
        if (i == 0 or rel[i - 1] == '/') {
            if (globMatch(pat, rel[i..])) return true;
        }
    }
    return false;
}

pub fn gitignoreMatch(pat0: []const u8, rel: []const u8, is_dir: bool) bool {
    var pat = std.mem.trim(u8, pat0, " ");
    if (pat.len == 0) return false;
    if (std.mem.endsWith(u8, pat, "/")) {
        if (!is_dir) return false;
        pat = pat[0 .. pat.len - 1];
    }
    const rooted = std.mem.startsWith(u8, pat, "/");
    if (rooted) pat = pat[1..];
    if (rooted or std.mem.indexOfScalar(u8, pat, '/') != null) return globMatch(pat, rel);
    if (globMatch(pat, std.fs.path.basename(rel))) return true;
    return globMatchAnyDir(pat, rel);
}

pub fn pathIgnored(alloc: std.mem.Allocator, rules: []const IgnoreRule, rel: []const u8, is_dir: bool) bool {
    var skip = false;
    for (rules) |r| {
        const local = ruleLocalPath(alloc, r, rel) orelse continue;
        const neg = r.pat.len > 0 and r.pat[0] == '!';
        const pat = if (neg) r.pat[1..] else r.pat;
        if (gitignoreMatch(pat, local, is_dir)) skip = !neg;
    }
    return skip;
}

/// glob 匹配(支持 `*` `?` `**`)。`*` 不跨 `/`,`**` 跨任意层级。
/// 递归实现,pattern 与 name 都短,无回溯爆炸风险。
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    return globMatchEx(pattern, name, false);
}

pub fn pathExcluded(exclude: ?[]const u8, rel: []const u8, ic: bool) bool {
    const g = exclude orelse return false;
    const bare = if (std.mem.endsWith(u8, rel, "/")) rel[0 .. rel.len - 1] else rel;
    return globMatchEx(g, bare, ic) or globMatchEx(g, std.fs.path.basename(bare), ic);
}

fn globEq(a: u8, b: u8, ic: bool) bool {
    if (a == b) return true;
    if (!ic) return false;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

pub fn globMatchEx(pattern: []const u8, name: []const u8, ic: bool) bool {
    // `**/` 前缀:匹配任意层级(含零层)
    if (std.mem.startsWith(u8, pattern, "**/")) {
        const rest = pattern[3..];
        if (globMatchEx(rest, name, ic)) return true;
        var i: usize = 0;
        while (i < name.len) : (i += 1) {
            if (name[i] == '/' and globMatchEx(rest, name[i + 1 ..], ic)) return true;
        }
        return false;
    }
    if (pattern.len == 0) return name.len == 0;
    switch (pattern[0]) {
        '*' => {
            const cross = pattern.len > 1 and pattern[1] == '*';
            const rest = if (cross) pattern[2..] else pattern[1..];
            if (globMatchEx(rest, name, ic)) return true;
            var i: usize = 0;
            while (i < name.len) : (i += 1) {
                if (!cross and name[i] == '/') break;
                if (globMatchEx(rest, name[i + 1 ..], ic)) return true;
            }
            return false;
        },
        '?' => {
            if (name.len == 0 or name[0] == '/') return false;
            return globMatchEx(pattern[1..], name[1..], ic);
        },
        else => {
            if (name.len == 0 or !globEq(name[0], pattern[0], ic)) return false;
            return globMatchEx(pattern[1..], name[1..], ic);
        },
    }
}

/// 最小正则引擎。支持:字符类 `[abc]` `[a-z]` `[^x]`、`.`、`*` `+` `?`、
/// 锚 `^` `$`、转义 `\.` `\d` `\w` `\s`(及大写取反)。
/// 不支持:分组、选择 `|`、回溯引用、懒惰量词 —— 这些留给模型用 bash 调 rg。
/// 设计取舍:单遍回溯匹配,单行长度设上限防指数爆炸。
pub const Regex = struct {
    pattern: []const u8,
    ignore_case: bool,

    /// 单行长度上限:超长行(压缩产物、base64)跳过,防病态回溯。
    const MAX_LINE = 4096;

    pub fn init(pattern: []const u8, ignore_case: bool) !Regex {
        // 预校验:字符类必须闭合,转义不能悬空
        var i: usize = 0;
        while (i < pattern.len) : (i += 1) {
            switch (pattern[i]) {
                '\\' => {
                    if (i + 1 >= pattern.len) return error.TrailingBackslash;
                    i += 1;
                },
                '[' => {
                    const close = findClassEnd(pattern, i) orelse return error.UnclosedCharClass;
                    i = close;
                },
                else => {},
            }
        }
        return .{ .pattern = pattern, .ignore_case = ignore_case };
    }

    /// 找字符类结束的 `]` 下标。首字符 `]` 视为字面量(POSIX 惯例)。
    fn findClassEnd(p: []const u8, open: usize) ?usize {
        var i = open + 1;
        if (i < p.len and p[i] == '^') i += 1;
        if (i < p.len and p[i] == ']') i += 1; // 首个 ] 是字面量
        while (i < p.len) : (i += 1) {
            if (p[i] == '\\') {
                i += 1;
                continue;
            }
            if (p[i] == ']') return i;
        }
        return null;
    }

    fn fold(self: Regex, c: u8) u8 {
        return if (self.ignore_case) std.ascii.toLower(c) else c;
    }

    /// 转义类匹配:\d \w \s 及大写取反。
    fn matchEscape(esc: u8, c: u8) bool {
        return switch (esc) {
            'd' => std.ascii.isDigit(c),
            'D' => !std.ascii.isDigit(c),
            'w' => std.ascii.isAlphanumeric(c) or c == '_',
            'W' => !(std.ascii.isAlphanumeric(c) or c == '_'),
            's' => std.ascii.isWhitespace(c),
            'S' => !std.ascii.isWhitespace(c),
            'n' => c == '\n',
            't' => c == '\t',
            'r' => c == '\r',
            else => esc == c, // \. \* \[ 等:字面量
        };
    }

    /// 字符类匹配。返回是否命中。
    fn matchClass(self: Regex, p: []const u8, open: usize, close: usize, c: u8) bool {
        var i = open + 1;
        var negate = false;
        if (i < close and p[i] == '^') {
            negate = true;
            i += 1;
        }
        const cf = self.fold(c);
        var hit = false;
        while (i < close) : (i += 1) {
            if (p[i] == '\\' and i + 1 < close) {
                if (matchEscape(p[i + 1], c)) hit = true;
                i += 1;
                continue;
            }
            // 区间 a-z(`-` 在末尾时是字面量)
            if (i + 2 < close and p[i + 1] == '-') {
                const lo = self.fold(p[i]);
                const hi = self.fold(p[i + 2]);
                if (cf >= lo and cf <= hi) hit = true;
                i += 2;
                continue;
            }
            if (self.fold(p[i]) == cf) hit = true;
        }
        return hit != negate;
    }

    /// 单元素长度(用于量词跳过):转义 2、字符类到 `]`、其余 1。
    fn atomLen(self: Regex, p: []const u8, i: usize) usize {
        _ = self;
        if (p[i] == '\\') return 2;
        if (p[i] == '[') {
            if (findClassEnd(p, i)) |close| return close - i + 1;
        }
        return 1;
    }

    /// 单元素与单字符是否匹配。
    fn atomMatches(self: Regex, p: []const u8, i: usize, c: u8) bool {
        if (p[i] == '\\') return matchEscape(p[i + 1], c);
        if (p[i] == '[') {
            if (findClassEnd(p, i)) |close| return self.matchClass(p, i, close, c);
            return false;
        }
        if (p[i] == '.') return c != '\n';
        return self.fold(p[i]) == self.fold(c);
    }

    /// 从 text 任意位置起找匹配。返回是否命中。
    pub fn search(self: Regex, text: []const u8) bool {
        if (text.len > MAX_LINE) return false; // 超长行跳过
        if (self.pattern.len > 0 and self.pattern[0] == '^') {
            return self.matchHere(self.pattern[1..], text, 0);
        }
        var start: usize = 0;
        while (start <= text.len) : (start += 1) {
            if (self.matchHere(self.pattern, text, start)) return true;
        }
        return false;
    }

    /// 从 text[pos] 起匹配 p。回溯实现。
    fn matchHere(self: Regex, p: []const u8, text: []const u8, pos: usize) bool {
        if (p.len == 0) return true;
        if (p.len == 1 and p[0] == '$') return pos == text.len;
        const alen = self.atomLen(p, 0);
        // 量词:紧跟单元素之后
        if (p.len > alen) {
            const q = p[alen];
            if (q == '*' or q == '+' or q == '?') {
                const rest = p[alen + 1 ..];
                const min: usize = if (q == '+') 1 else 0;
                const max: usize = if (q == '?') 1 else text.len - pos;
                // 贪婪:先吃最多,再逐步回退
                var n: usize = 0;
                while (n < max and pos + n < text.len and self.atomMatches(p, 0, text[pos + n])) n += 1;
                while (n + 1 > min) : (n -= 1) {
                    if (self.matchHere(rest, text, pos + n)) return true;
                    if (n == 0) break;
                }
                return min == 0 and self.matchHere(rest, text, pos);
            }
        }
        if (pos >= text.len) return false;
        if (!self.atomMatches(p, 0, text[pos])) return false;
        return self.matchHere(p[alen..], text, pos + 1);
    }
};

/// 二进制探测:前 8KB 含 NUL 即认为二进制(与 git 同策略)。
pub fn looksBinary(data: []const u8) bool {
    const head = data[0..@min(data.len, 8192)];
    return std.mem.indexOfScalar(u8, head, 0) != null;
}

pub const WalkKind = enum { files, dirs, all };

/// 起点若是指向工作区外的目录 symlink,不跟。子项 .sym_link 本就不进递归。
pub fn escapingLink(arena: std.mem.Allocator, path: []const u8) bool {
    if (tpath.currentRoot().len == 0) return false;
    var buf: [4096]u8 = undefined;
    _ = std.Io.Dir.cwd().readLink(util.io, path, &buf) catch return false;
    return !tpath.realInsideRoot(arena, path);
}

/// 递归收集相对路径到 out。跳过 SKIP_DIRS 与符号链接。
/// 目录条目带尾 `/`,便于 find type=dir。rel 为相对 root 的前缀。
pub fn collectFiles(
    alloc: std.mem.Allocator,
    out: *std.array_list.Managed([]const u8),
    root: []const u8,
    rel: []const u8,
    limit: usize,
    depth: u8,
    rules: []const IgnoreRule,
    walk: WalkKind,
    max_depth: u8,
) !void {
    if (out.items.len >= limit or depth >= max_depth) return;
    const abs = if (rel.len == 0) root else try util.joinPath(alloc, root, rel);
    if (rel.len == 0 and escapingLink(alloc, abs)) return;
    var dir = std.Io.Dir.cwd().openDir(util.io, abs, .{ .iterate = true }) catch return;
    defer dir.close(util.io);
    const extra_pats = if (rel.len == 0) &.{} else loadIgnoreFiles(alloc, abs);
    const extra = wrapIgnore(alloc, extra_pats, rel, "");
    const combined = if (extra.len == 0) rules else blk: {
        var both = std.array_list.Managed(IgnoreRule).init(alloc);
        both.appendSlice(rules) catch break :blk rules;
        both.appendSlice(extra) catch break :blk rules;
        break :blk both.toOwnedSlice() catch rules;
    };
    var it = dir.iterate();
    while (it.next(util.io) catch null) |entry| {
        if (out.items.len >= limit) return;
        const child = try util.joinPath(alloc, rel, entry.name);
        if (entry.kind == .directory) {
            if (isSkippedDir(entry.name) or pathIgnored(alloc, combined, child, true)) continue;
            if (walk != .files) {
                try out.append(try std.fmt.allocPrint(alloc, "{s}/", .{child}));
            }
            try collectFiles(alloc, out, root, child, limit, depth + 1, combined, walk, max_depth);
        } else if (entry.kind == .file) {
            if (walk == .dirs) continue;
            if (pathIgnored(alloc, combined, child, false)) continue;
            try out.append(child);
        } else if (entry.kind == .sym_link) {
            const child_abs = try util.joinPath(alloc, abs, entry.name);
            const tgt_dir = blk: {
                if (std.Io.Dir.cwd().statFile(util.io, child_abs, .{})) |st| {
                    break :blk st.kind == .directory;
                } else |_| break :blk false;
            };
            if (tgt_dir) {
                if (walk == .files) continue;
                if (pathIgnored(alloc, combined, child, true)) continue;
                try out.append(try std.fmt.allocPrint(alloc, "{s}/", .{child}));
            } else {
                if (walk == .dirs) continue;
                if (pathIgnored(alloc, combined, child, false)) continue;
                try out.append(child);
            }
        }
    }
}

test "collectFiles does not walk escaping dir symlink" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(util.io, .{ .sub_path = "ok.txt", .data = "x" });
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile(util.io, .{ .sub_path = "secret.txt", .data = "nope" });
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    const other = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, outside.sub_path });
    tmp.dir.symLink(util.io, other, "out", .{}) catch return error.SkipZigTest;
    tpath.setRoot(root);
    defer tpath.clearRoot();
    var files = std.array_list.Managed([]const u8).init(a);
    try collectFiles(a, &files, root, "", 200, 0, &.{}, .all, 8);
    for (files.items) |p| {
        try t.expect(std.mem.indexOf(u8, p, "secret.txt") == null);
    }
    try collectFiles(a, &files, try util.joinPath(a, root, "out"), "", 200, 0, &.{}, .all, 8);
    for (files.items) |p| {
        try t.expect(std.mem.indexOf(u8, p, "secret.txt") == null);
    }
}
