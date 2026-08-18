// tools.zig — 核心工具:read / write / edit / multi_edit / bash；grep/find/ls 见 tools_search.zig。
const std = @import("std");
const util = @import("util.zig");
const seams = @import("seams.zig");
const cfgmod = @import("config.zig");
const sandboxmod = @import("sandbox.zig");
const tjson = @import("tools_json.zig");
const tools_path = @import("tools_path.zig");
const search = @import("tools_search.zig");
const bash = @import("tools_bash.zig");
const tedit = @import("tools_edit.zig");
const tread = @import("tools_read.zig");
const twrite = @import("tools_write.zig");
const tskill = @import("tools_skill.zig");

pub const MAX_TOOL_OUTPUT = 16 * 1024;
pub const jstr = tjson.jstr;
pub const jint = tjson.jint;
pub const jbool = tjson.jbool;
pub const parseArgs = tjson.parseArgs;
pub const setRoot = tools_path.setRoot;
pub const clearRoot = tools_path.clearRoot;
pub const setSandbox = tools_path.setSandbox;
pub const clearSandbox = tools_path.clearSandbox;
pub const diskRead = tools_path.diskRead;
pub const resolvePath = tools_path.resolvePath;
pub const rootForSpawn = tools_path.rootForSpawn;
pub const insideRoot = tools_path.insideRoot;
pub const realInsideRoot = tools_path.realInsideRoot;
pub const PipeState = bash.PipeState;
pub const pumpPipes = bash.pumpPipes;
pub const killGroup = bash.killGroup;
pub const killTracked = bash.killTracked;
pub fn runPkgCommand(arena: std.mem.Allocator, command: []const u8, args: []const u8) !Result {
    const r = try bash.runPkgCommand(arena, command, args);
    return .{ .content = r.content, .is_error = r.is_error };
}
pub fn pkgToolStub(arena: std.mem.Allocator, args: []const u8) !Result {
    const r = try bash.pkgToolStub(arena, args);
    return .{ .content = r.content, .is_error = r.is_error };
}

const diskWrite = tools_path.diskWrite;

/// 工具产出的图片附件(如 read_image):数据、mime、像素尺寸、给模型看的说明。
/// data 必须与会话同寿(工具 handler 负责 dupe 到 agent 的常驻 allocator),
/// note 是给模型读的文本说明。
pub const ImageAttach = struct {
    data: []const u8,
    mime: []const u8,
    w: u32,
    h: u32,
    note: []const u8,
};

pub const Result = struct {
    content: []const u8, // 给模型看的内容(arena 所有)
    is_error: bool = false,
    /// 随本条工具结果附上的图片(agent 会把它们挂成 user 消息;
    /// 协议限制:image block 不能出现在 tool 消息里)
    images: ?[]const ImageAttach = null,
};

/// handler 抛错时的统一回执:把工具名和 error 名交给模型,不再一句 "tool crashed"。
/// FileNotFound vs AccessDenied 自愈路径完全不同。格式化失败退回静态串。
pub fn crashResult(arena: std.mem.Allocator, name: []const u8, err: anyerror) Result {
    util.debugLog("tool {s} crashed: {s}", .{ name, @errorName(err) });
    const content = std.fmt.allocPrint(arena, "tool crashed ({s}): {s}", .{ name, @errorName(err) }) catch "tool crashed: OutOfMemory";
    return .{ .content = content, .is_error = true };
}

/// read: {path, offset?, limit?, tail?, around?} → 文件内容(offset/limit/tail/around 给定时返回 1-based 行区间)
fn toolRead(arena: std.mem.Allocator, args: []const u8) !Result {
    const r = try tread.toolRead(arena, args);
    if (r.images) |imgs| {
        const out = arena.alloc(ImageAttach, imgs.len) catch
            return .{ .content = r.content, .is_error = r.is_error };
        for (imgs, out) |src, *dst| {
            dst.* = .{ .data = src.data, .mime = src.mime, .w = src.w, .h = src.h, .note = src.note };
        }
        return .{ .content = r.content, .is_error = r.is_error, .images = out };
    }
    return .{ .content = r.content, .is_error = r.is_error };
}

/// 工具输出上限裁剪(头尾各半)。源文件要头、日志要尾,只保一边会瞎。
/// 插件工具亦复用。
pub fn capped(arena: std.mem.Allocator, body: []const u8, path: []const u8, total: usize) !Result {
    if (body.len <= MAX_TOOL_OUTPUT) return .{ .content = try arena.dupe(u8, body) };
    const keep = MAX_TOOL_OUTPUT / 2;
    const head = util.utf8Prefix(body, keep);
    const tail = util.utf8Suffix(body, keep);
    const omitted = body.len -| (head.len + tail.len);
    return .{ .content = try std.fmt.allocPrint(arena, "{s}\n...[{s} truncated at {d} bytes, omitted {d}, total {d}; use offset/limit]...\n{s}", .{
        head,
        path,
        MAX_TOOL_OUTPUT,
        omitted,
        total,
        tail,
    }) };
}

/// write: {path, content} → 写文件
fn toolWrite(arena: std.mem.Allocator, args: []const u8) !Result {
    const r = try twrite.toolWrite(arena, args);
    return .{ .content = r.content, .is_error = r.is_error };
}

fn toolEdit(arena: std.mem.Allocator, args: []const u8) !Result {
    const r = try tedit.toolEdit(arena, args);
    return .{ .content = r.content, .is_error = r.is_error };
}

fn toolBash(arena: std.mem.Allocator, args: []const u8) !Result {
    const r = try bash.toolBash(arena, args);
    return .{ .content = r.content, .is_error = r.is_error };
}

/// skill: {name} → 读 SKILL.md。搜索顺序与 `util.loadSkillsIndex` 必须一致。
/// 由 skills 插件注册,故导出。
pub fn toolSkill(arena: std.mem.Allocator, args: []const u8) !Result {
    const r = try tskill.toolSkill(arena, args);
    return .{ .content = r.content, .is_error = r.is_error };
}

pub const Tool = struct {
    name: []const u8,
    desc: []const u8,
    /// 参数 JSON Schema(编译期字面量;发给 provider 作 input_schema/parameters)。
    /// 空串 = 无参数工具,序列化时退化为 {"type":"object","properties":{}}。
    schema: []const u8 = "",
    handler: *const fn (arena: std.mem.Allocator, args: []const u8) anyerror!Result,
    /// 插件工具:带宿主上下文(Agent 指针)的处理器。
    ctx_handler: ?*const fn (ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!Result = null,
    /// 非空:包声明的 shell 工具。runToolSlot 走 bash,`{key}` 从 args 替换。
    payload: []const u8 = "",
};

/// 无参数工具的空 schema。
pub const EMPTY_SCHEMA = "{\"type\":\"object\",\"properties\":{}}";

const fs_walk = @import("tools_fs.zig");
const loadIgnoreRules = fs_walk.loadIgnoreRules;
const pathIgnored = fs_walk.pathIgnored;
pub const globMatch = fs_walk.globMatch;
const gitignoreMatch = fs_walk.gitignoreMatch;
const IgnoreRule = fs_walk.IgnoreRule;
const Regex = fs_walk.Regex;
const collectFiles = fs_walk.collectFiles;

/// grep: {pattern, path?, glob?, ignoreCase?, literal?, context?, limit?}
/// 纯 Zig 实现:literal 走子串匹配,否则走最小正则引擎。
fn toolGrep(arena: std.mem.Allocator, args: []const u8) !Result {
    const r = try search.toolGrep(arena, args);
    return .{ .content = r.content, .is_error = r.is_error };
}

/// find: {pattern, path?, limit?} — glob 匹配文件路径,递归。
fn toolFind(arena: std.mem.Allocator, args: []const u8) !Result {
    const r = try search.toolFind(arena, args);
    return .{ .content = r.content, .is_error = r.is_error };
}

/// ls: {path?, limit?} — 列目录条目,目录优先按名排序。
fn toolLs(arena: std.mem.Allocator, args: []const u8) !Result {
    const r = try search.toolLs(arena, args);
    return .{ .content = r.content, .is_error = r.is_error };
}

/// multi_edit: {files: [{path, edits: [{oldText, newText}]}]}
/// 跨文件批量编辑,**原子语义**:先全量 dry-run 校验,任一失败则一个字节都不写。
/// 这是它相对多次单 edit 调用的核心价值 —— 避免改一半留下不一致的工作树。
fn toolMultiEdit(arena: std.mem.Allocator, args: []const u8) !Result {
    const r = try tedit.toolMultiEdit(arena, args);
    return .{ .content = r.content, .is_error = r.is_error };
}

pub const tools = [_]Tool{
    .{
        .name = "read",
        .desc = "Read a file. Each line is prefixed with its 1-based line number. Use offset/limit for a slice, tail for the last N lines (logs), or around for a window centered on a line. PNG/JPEG/GIF/WEBP/BMP are decoded and shown to vision models.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"File path to read."},"offset":{"type":"integer","description":"1-based line number to start from."},"limit":{"type":"integer","description":"Maximum number of lines to return. With around, this is the window size."},"tail":{"type":"integer","description":"Last N lines (do not combine with offset or around)."},"around":{"type":"integer","description":"1-based center line. Returns a window around it (default 41 lines). Do not combine with offset or tail."}},"required":["path"]}
        ,
        .handler = toolRead,
    },
    .{
        .name = "write",
        .desc = "Write a file inside the workspace, creating parent directories. Paths that escape via .. or an outside absolute path are rejected. Set createOnly to refuse overwriting an existing file. Set dryRun to preview without writing. RULE: use this tool for all file writes — never mutate files through shell scripts or spawned processes.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"File path to write."},"content":{"type":"string","description":"Full file contents."},"createOnly":{"type":"boolean","description":"Fail if the file already exists (default false)."},"dryRun":{"type":"boolean","description":"Preview without writing (default false)."}},"required":["path","content"]}
        ,
        .handler = toolWrite,
    },
    .{
        .name = "edit",
        .desc = "Replace exact oldText with newText in a file. Each oldText must match exactly once unless replaceAll is true. Do not include read() line-number prefixes (they are stripped if present). Set dryRun to validate and preview without writing. RULE: always mutate source files with this built-in tool — external scripting is for analysis/validation only, never for editing source.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"File path to edit."},"edits":{"type":"array","description":"Edits applied in order.","items":{"type":"object","properties":{"oldText":{"type":"string","description":"Exact text to replace; must occur exactly once unless replaceAll."},"newText":{"type":"string","description":"Replacement text."},"replaceAll":{"type":"boolean","description":"Replace every occurrence (default false)."}},"required":["oldText","newText"]}},"dryRun":{"type":"boolean","description":"Validate and preview without writing (default false)."}},"required":["path","edits"]}
        ,
        .handler = toolEdit,
    },
    .{
        .name = "bash",
        .desc = "Run a shell command. May run inside an OS sandbox (workspace: writes only in the working directory; strict: also no network). RULE: do not use shell to modify source files — use the built-in write/edit tools instead; bash is for inspection, builds, and tests.",
        .schema =
        \\{"type":"object","properties":{"command":{"type":"string","description":"Shell command to run."},"timeout":{"type":"integer","description":"Timeout in seconds (default 30)."},"background":{"type":"boolean","description":"Return immediately; stream output to an artifact log. Use for servers and long builds."},"cwd":{"type":"string","description":"Working directory inside the workspace (default: agent root)."}},"required":["command"]}
        ,
        .handler = toolBash,
    },
    .{
        .name = "grep",
        .desc = "Search file contents by regex (or literal text). Prefer this over shelling out to grep/rg: it returns structured path:line:match output, skips build dirs, binaries, and files over maxBytes (default 1MB). Set maxDepth to cap directory walk. Set exclude to skip a glob (rg -g '!pat'). Set filesWithMatches to list unique files only. Set invert to keep non-matching lines (rg -v); with filesWithMatches that lists files with no hits (rg -L). Set count for path:N totals (rg -c).",
        .schema =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"Regex pattern. Supports char classes [a-z], . * + ? ^ $, escapes \\d \\w \\s. No groups or alternation."},"path":{"type":"string","description":"File or directory to search (default '.')."},"glob":{"type":"string","description":"Filter files by glob, e.g. '*.zig' or 'src/**/*.ts'."},"ignoreCase":{"type":"boolean","description":"Case-insensitive match."},"literal":{"type":"boolean","description":"Treat pattern as plain text instead of regex."},"context":{"type":"integer","description":"Context lines around each match (0-10)."},"limit":{"type":"integer","description":"Max matches to return (default 200)."},"filesWithMatches":{"type":"boolean","description":"List unique file paths only, like rg -l."},"maxBytes":{"type":"integer","description":"Skip files larger than this when walking a tree (default 1048576). Single-file path is not skipped."},"invert":{"type":"boolean","description":"Keep non-matching lines (rg -v). With filesWithMatches, list files with no hits (rg -L)."},"maxDepth":{"type":"integer","description":"Directory walk depth (default 32, min 1). 1 = this folder only."},"count":{"type":"boolean","description":"Print path:N match counts (rg -c) instead of lines."},"exclude":{"type":"string","description":"Skip paths matching this glob (rg -g '!pat')."}},"required":["pattern"]}
        ,
        .handler = toolGrep,
    },
    .{
        .name = "find",
        .desc = "Find files or directories by glob pattern, recursively. Prefer this over shelling out to find/fd. Set type=dir to list folders. Set sort=mtime for newest first. Set ignoreCase to match Foo.TS with *.ts. Set maxDepth to cap how deep the walk goes. Set exclude to skip a glob.",
        .schema =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern, e.g. '*.zig' or 'src/**/*.test.ts'. Matched against both the relative path and the basename."},"path":{"type":"string","description":"Directory to search from (default '.')."},"limit":{"type":"integer","description":"Max results (default 200)."},"sort":{"type":"string","description":"'mtime' = newest first. Default is walk order."},"ignoreCase":{"type":"boolean","description":"Case-insensitive glob (default false)."},"type":{"type":"string","description":"'file', 'dir', or 'any' (default any)."},"maxDepth":{"type":"integer","description":"Directory walk depth (default 32, min 1). 1 = this folder only."},"exclude":{"type":"string","description":"Skip paths matching this glob."}},"required":["pattern"]}
        ,
        .handler = toolFind,
    },
    .{
        .name = "ls",
        .desc = "List directory entries; directories first, files with byte sizes. Hidden and gitignored names are omitted unless all=true. Set sort=mtime for newest first. Set type=file or type=dir to filter. Set exclude to skip a glob.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Directory to list (default '.')."},"limit":{"type":"integer","description":"Max entries (default 200)."},"all":{"type":"boolean","description":"Include gitignored and skipped dirs (default false)."},"sort":{"type":"string","description":"'mtime' = newest first. Default is dirs first, then name."},"type":{"type":"string","description":"'file', 'dir', or 'any' (default any)."},"exclude":{"type":"string","description":"Skip names matching this glob."}},"required":[]}
        ,
        .handler = toolLs,
    },
    .{
        .name = "multi_edit",
        .desc = "Edit several files in one atomic batch. All edits are validated first; if any oldText fails to match exactly once (unless replaceAll), nothing is written. Set dryRun to validate and preview without writing. Use this for refactors that must not leave the tree half-changed.",
        .schema =
        \\{"type":"object","properties":{"files":{"type":"array","description":"Files to edit.","items":{"type":"object","properties":{"path":{"type":"string","description":"File path."},"edits":{"type":"array","description":"Edits applied in order.","items":{"type":"object","properties":{"oldText":{"type":"string","description":"Exact text to replace; must occur exactly once unless replaceAll."},"newText":{"type":"string","description":"Replacement text."},"replaceAll":{"type":"boolean","description":"Replace every occurrence (default false)."}},"required":["oldText","newText"]}}},"required":["path","edits"]}},"dryRun":{"type":"boolean","description":"Validate and preview without writing (default false)."}},"required":["files"]}
        ,
        .handler = toolMultiEdit,
    },
};

pub fn find(name: []const u8) ?*const Tool {
    for (&tools) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// 只拦会改状态、出网或委派的工具。读/搜/列目录直接过。
/// 没登记的名字默认要问 —— 插件和 MCP 不能因为没写进表就放行。
pub fn needsConfirm(name: []const u8) bool {
    const safe = [_][]const u8{
        "read",                  "grep",       "find",
        "ls",                    "todo_read",  "todo_write",
        "get_context_remaining", "git_status", "skill",
        "read_image",            "lsp",        "ask_user",
    };
    for (safe) |s| {
        if (std.mem.eql(u8, name, s)) return false;
    }
    return true;
}

pub const ToolGate = enum { allow, deny, ask };

/// 按授权档决定工具过不过。读类一律放行。
pub fn toolGate(mode: cfgmod.ApprovalMode, name: []const u8) ToolGate {
    if (!needsConfirm(name)) return .allow;
    return switch (mode) {
        .yolo => .allow,
        .ask => .ask,
        .read_only => .deny,
    };
}

test "edit tool" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;
    try dir.writeFile(util.io, .{ .sub_path = "a.txt", .data = "hello world hello" });
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 进入临时目录,使 cwd 相对路径生效
    const tmppath = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const old_cwd = try std.process.currentPathAlloc(util.io, a);
    std.Io.Threaded.chdir(tmppath) catch unreachable;
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    // 多匹配 → 错误
    const r1 = try toolEdit(a, "{\"path\":\"a.txt\",\"edits\":[{\"oldText\":\"hello\",\"newText\":\"bye\"}]}");
    try t.expect(r1.is_error);
    try t.expect(std.mem.indexOf(u8, r1.content, "matches 2 times") != null);

    // 精确匹配
    const r2 = try toolEdit(a, "{\"path\":\"a.txt\",\"edits\":[{\"oldText\":\"world\",\"newText\":\"zig\"}]}");
    try t.expect(!r2.is_error);
    const content = try std.Io.Dir.cwd().readFileAlloc(util.io, "a.txt", a, .limited(1024));
    try t.expectEqualStrings("hello zig hello", content);
    const dry = try toolEdit(a, "{\"path\":\"a.txt\",\"dryRun\":true,\"edits\":[{\"oldText\":\"zig\",\"newText\":\"dry\"}]}");
    try t.expect(!dry.is_error);
    try t.expect(std.mem.indexOf(u8, dry.content, "dry-run") != null);
    const still = try std.Io.Dir.cwd().readFileAlloc(util.io, "a.txt", a, .limited(1024));
    try t.expectEqualStrings("hello zig hello", still);

    // 不存在 → 错误
    const r3 = try toolEdit(a, "{\"path\":\"nope.txt\",\"edits\":[{\"oldText\":\"x\",\"newText\":\"y\"}]}");
    try t.expect(r3.is_error);

    // 输出含 diff 块(web diff 卡数据源)
    try t.expect(std.mem.indexOf(u8, r2.content, "--- a.txt") != null);
    try t.expect(std.mem.indexOf(u8, r2.content, "+++ a.txt") != null);
    try t.expect(std.mem.indexOf(u8, r2.content, "-world") != null);
    try t.expect(std.mem.indexOf(u8, r2.content, "+zig") != null);

    // replaceAll 换全部 hello
    const r4 = try toolEdit(a, "{\"path\":\"a.txt\",\"edits\":[{\"oldText\":\"hello\",\"newText\":\"hi\",\"replaceAll\":true}]}");
    try t.expect(!r4.is_error);
    const all = try std.Io.Dir.cwd().readFileAlloc(util.io, "a.txt", a, .limited(1024));
    try t.expectEqualStrings("hi zig hi", all);

    // 模型从 read 抄了行号前缀,仍应命中
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = "a.txt", .data = "hello zig hello" });
    const r5 = try toolEdit(a, "{\"path\":\"a.txt\",\"edits\":[{\"oldText\":\"     1|hello zig hello\",\"newText\":\"     1|ok\"}]}");
    try t.expect(!r5.is_error);
    const numbered = try std.Io.Dir.cwd().readFileAlloc(util.io, "a.txt", a, .limited(1024));
    try t.expectEqualStrings("ok", numbered);

    const miss = try toolEdit(a, "{\"path\":\"a.txt\",\"edits\":[{\"oldText\":\"ok but wrong\",\"newText\":\"x\"}]}");
    try t.expect(miss.is_error);
    try t.expect(std.mem.indexOf(u8, miss.content, "nearest:") != null);
    try t.expect(std.mem.indexOf(u8, miss.content, "ok") != null);
}

test "globMatch semantics" {
    const t = std.testing;
    // 单星不跨目录分隔
    try t.expect(globMatch("*.zig", "main.zig"));
    try t.expect(!globMatch("*.zig", "src/main.zig"));
    try t.expect(globMatch("src/*.zig", "src/main.zig"));
    // ** 跨任意层级(含零层)
    try t.expect(globMatch("**/*.zig", "main.zig"));
    try t.expect(globMatch("**/*.zig", "src/deep/main.zig"));
    try t.expect(globMatch("src/**/*.ts", "src/a/b/c.ts"));
    // ? 单字符,不吃分隔符
    try t.expect(globMatch("a?c.txt", "abc.txt"));
    try t.expect(!globMatch("a?c.txt", "a/c.txt"));
    // 全字面量
    try t.expect(globMatch("build.zig", "build.zig"));
    try t.expect(!globMatch("build.zig", "build.zon"));
}

test "mini regex engine" {
    const t = std.testing;
    // 字符类与区间
    var re = try Regex.init("[a-c]at", false);
    try t.expect(re.search("the bat sat"));
    try t.expect(!re.search("the mat"));
    // 取反类
    re = try Regex.init("[^0-9]x", false);
    try t.expect(re.search("ax"));
    try t.expect(!re.search("1x"));
    // 量词
    re = try Regex.init("ab*c", false);
    try t.expect(re.search("ac"));
    try t.expect(re.search("abbbc"));
    re = try Regex.init("ab+c", false);
    try t.expect(!re.search("ac"));
    try t.expect(re.search("abc"));
    re = try Regex.init("ab?c", false);
    try t.expect(re.search("ac"));
    try t.expect(re.search("abc"));
    // 锚
    re = try Regex.init("^fn ", false);
    try t.expect(re.search("fn main() void {"));
    try t.expect(!re.search("  fn main"));
    re = try Regex.init("\\{$", false);
    try t.expect(re.search("fn main() void {"));
    try t.expect(!re.search("fn main() void { }"));
    // 转义类
    re = try Regex.init("\\d\\d\\d", false);
    try t.expect(re.search("abc 123"));
    try t.expect(!re.search("ab 12"));
    re = try Regex.init("\\w+_test", false);
    try t.expect(re.search("my_test"));
    // 转义字面量:\. 只匹配真的点
    re = try Regex.init("a\\.b", false);
    try t.expect(re.search("a.b"));
    try t.expect(!re.search("axb"));
    // 大小写不敏感
    re = try Regex.init("hello", true);
    try t.expect(re.search("HELLO world"));
    // 非法 pattern 报错而非 crash
    try t.expectError(error.UnclosedCharClass, Regex.init("[abc", false));
    try t.expectError(error.TrailingBackslash, Regex.init("abc\\", false));
}

test "grep find ls tools over a real tree" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;
    try dir.createDirPath(util.io, "src");
    try dir.createDirPath(util.io, ".git");
    try dir.createDirPath(util.io, ".turbo");
    try dir.writeFile(util.io, .{ .sub_path = "src/a.zig", .data = "const x = 1;\nfn hello() void {}\n" });
    try dir.writeFile(util.io, .{ .sub_path = "src/b.txt", .data = "hello there\n" });
    // .git 下的命中必须被跳过,否则搜索结果会被 VCS 元数据污染
    try dir.writeFile(util.io, .{ .sub_path = ".git/config", .data = "hello from git\n" });
    try dir.writeFile(util.io, .{ .sub_path = ".turbo/hello.txt", .data = "hello from turbo\n" });
    // 二进制文件必须被跳过
    try dir.writeFile(util.io, .{ .sub_path = "bin.dat", .data = "hello\x00\x01binary" });

    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmppath = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const old_cwd = try std.process.currentPathAlloc(util.io, a);
    std.Io.Threaded.chdir(tmppath) catch unreachable;
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    // grep:命中两个文本文件,跳过 .git 与二进制
    const g = try toolGrep(a, "{\"pattern\":\"hello\"}");
    try t.expect(!g.is_error);
    try t.expect(std.mem.indexOf(u8, g.content, "src/a.zig:2:") != null);
    try t.expect(std.mem.indexOf(u8, g.content, "src/b.txt:1:") != null);
    try t.expect(std.mem.indexOf(u8, g.content, ".git") == null);
    try t.expect(std.mem.indexOf(u8, g.content, ".turbo") == null);
    try t.expect(std.mem.indexOf(u8, g.content, "bin.dat") == null);

    // grep + glob 过滤
    const gex = try toolGrep(a, "{\"pattern\":\"hello\",\"exclude\":\"*.zig\"}");
    try t.expect(std.mem.indexOf(u8, gex.content, "a.zig") == null);
    const cnt = try toolGrep(a, "{\"pattern\":\"hello\",\"glob\":\"*.zig\",\"count\":true}");
    try t.expect(std.mem.indexOf(u8, cnt.content, ":1") != null);
    try t.expect(std.mem.indexOf(u8, cnt.content, "fn hello") == null);
    const inv = try toolGrep(a, "{\"pattern\":\"hello\",\"glob\":\"*.zig\",\"invert\":true}");
    try t.expect(std.mem.indexOf(u8, inv.content, "const x") != null);
    try t.expect(std.mem.indexOf(u8, inv.content, "hello") == null);
    const g2 = try toolGrep(a, "{\"pattern\":\"hello\",\"glob\":\"*.zig\"}");
    try t.expect(std.mem.indexOf(u8, g2.content, "src/a.zig") != null);
    try t.expect(std.mem.indexOf(u8, g2.content, "b.txt") == null);

    // grep literal:正则元字符按字面量处理
    const g3 = try toolGrep(a, "{\"pattern\":\"x = 1;\",\"literal\":true}");
    try t.expect(std.mem.indexOf(u8, g3.content, "src/a.zig:1:") != null);

    // grep 无命中:不是错误,是空结果
    const g4 = try toolGrep(a, "{\"pattern\":\"nonexistent_zzz\"}");
    try t.expect(!g4.is_error);
    try t.expect(std.mem.indexOf(u8, g4.content, "no matches") != null);

    // grep 坏 pattern:报错且给出可操作提示
    const g5 = try toolGrep(a, "{\"pattern\":\"[unclosed\"}");
    try t.expect(g5.is_error);
    try t.expect(std.mem.indexOf(u8, g5.content, "literal=true") != null);

    // find:glob 匹配路径
    const f = try toolFind(a, "{\"pattern\":\"*.zig\"}");
    try t.expect(!f.is_error);
    try t.expect(std.mem.indexOf(u8, f.content, "a.zig") != null);
    try t.expect(std.mem.indexOf(u8, f.content, "b.txt") == null);

    const fd = try toolFind(a, "{\"pattern\":\"src\",\"type\":\"dir\"}");
    try t.expect(!fd.is_error);
    try t.expect(std.mem.indexOf(u8, fd.content, "src/") != null);
    try t.expect(std.mem.indexOf(u8, fd.content, "a.zig") == null);
    var only_files = std.array_list.Managed([]const u8).init(a);
    try collectFiles(a, &only_files, ".", "", 20000, 0, loadIgnoreRules(a, "."), .files, 32);
    for (only_files.items) |rel| try t.expect(!std.mem.endsWith(u8, rel, "/"));
    const ff = try toolFind(a, "{\"pattern\":\"*\",\"type\":\"file\"}");
    try t.expect(!ff.is_error);
    try t.expect(std.mem.indexOf(u8, ff.content, "a.zig") != null);
    var lit = std.mem.splitScalar(u8, ff.content, '\n');
    while (lit.next()) |line| {
        if (line.len == 0) continue;
        try t.expect(!std.mem.endsWith(u8, line, "/"));
    }
    const shallow = try toolFind(a, "{\"pattern\":\"*.zig\",\"maxDepth\":1}");
    try t.expect(std.mem.indexOf(u8, shallow.content, "a.zig") == null);
    const deep = try toolFind(a, "{\"pattern\":\"*.zig\",\"maxDepth\":2}");
    try t.expect(std.mem.indexOf(u8, deep.content, "a.zig") != null);
    const nozig = try toolFind(a, "{\"pattern\":\"*\",\"exclude\":\"*.zig\"}");
    try t.expect(std.mem.indexOf(u8, nozig.content, "a.zig") == null);
    try t.expect(std.mem.indexOf(u8, nozig.content, "bin.dat") != null);

    // ls:目录优先,带大小
    const l = try toolLs(a, "{}");
    try t.expect(!l.is_error);
    try t.expect(std.mem.indexOf(u8, l.content, "src/") != null);
    try t.expect(std.mem.indexOf(u8, l.content, "bin.dat") != null);
    const lex = try toolLs(a, "{\"exclude\":\"*.dat\"}");
    try t.expect(std.mem.indexOf(u8, lex.content, "bin.dat") == null);
    try t.expect(std.mem.indexOf(u8, lex.content, "src/") != null);

    // ls 不存在的目录 → 错误
    const l2 = try toolLs(a, "{\"path\":\"nope\"}");
    try t.expect(l2.is_error);
    const ld = try toolLs(a, "{\"type\":\"dir\"}");
    try t.expect(std.mem.indexOf(u8, ld.content, "src/") != null);
    try t.expect(std.mem.indexOf(u8, ld.content, "bin.dat") == null);
    const lf = try toolLs(a, "{\"type\":\"file\"}");
    try t.expect(std.mem.indexOf(u8, lf.content, "src/\n") == null);
    try t.expect(std.mem.indexOf(u8, lf.content, "bin.dat") != null);

    const skip = try toolGrep(a, "{\"pattern\":\"hello\",\"maxBytes\":4}");
    try t.expect(!skip.is_error);
    try t.expect(std.mem.indexOf(u8, skip.content, "skipped") != null);
}

test "find sort=mtime returns newest first" {
    const t = std.testing;
    try util.testInit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(util.io, .{ .sub_path = "old.txt", .data = "a\n" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "new.txt", .data = "b\n" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "old.txt", .data = "a2\n" });
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    const r = try toolFind(a, try std.fmt.allocPrint(a, "{{\"pattern\":\"*.txt\",\"path\":\"{s}\",\"sort\":\"mtime\"}}", .{dir}));
    try t.expect(!r.is_error);
    const i_old = std.mem.indexOf(u8, r.content, "old.txt") orelse return error.MissingOld;
    const i_new = std.mem.indexOf(u8, r.content, "new.txt") orelse return error.MissingNew;
    try t.expect(i_old < i_new);
}

test "ls sort=mtime returns newest first" {
    const t = std.testing;
    try util.testInit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(util.io, .{ .sub_path = "old.txt", .data = "a\n" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "new.txt", .data = "b\n" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "old.txt", .data = "a2\n" });
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    const r = try toolLs(a, try std.fmt.allocPrint(a, "{{\"path\":\"{s}\",\"sort\":\"mtime\"}}", .{dir}));
    try t.expect(!r.is_error);
    const i_old = std.mem.indexOf(u8, r.content, "old.txt") orelse return error.MissingOld;
    const i_new = std.mem.indexOf(u8, r.content, "new.txt") orelse return error.MissingNew;
    try t.expect(i_old < i_new);
}

test "find ignoreCase matches mixed-case names" {
    const t = std.testing;
    try util.testInit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(util.io, .{ .sub_path = "Foo.TS", .data = "x\n" });
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    const sensitive = try toolFind(a, try std.fmt.allocPrint(a, "{{\"pattern\":\"*.ts\",\"path\":\"{s}\"}}", .{dir}));
    try t.expect(std.mem.indexOf(u8, sensitive.content, "Foo.TS") == null);
    const loose = try toolFind(a, try std.fmt.allocPrint(a, "{{\"pattern\":\"*.ts\",\"path\":\"{s}\",\"ignoreCase\":true}}", .{dir}));
    try t.expect(std.mem.indexOf(u8, loose.content, "Foo.TS") != null);
}

test "gitignoreMatch and pathIgnored" {
    const t = std.testing;
    try t.expect(gitignoreMatch("*.log", "foo.log", false));
    try t.expect(gitignoreMatch("*.log", "src/foo.log", false));
    try t.expect(!gitignoreMatch("*.log", "foo.txt", false));
    try t.expect(gitignoreMatch("/build", "build", true));
    try t.expect(!gitignoreMatch("/build", "src/build", true));
    try t.expect(gitignoreMatch("build/", "build", true));
    try t.expect(!gitignoreMatch("build/", "build", false));
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]IgnoreRule{ .{ .pat = "*.log" }, .{ .pat = "!keep.log" } };
    try t.expect(pathIgnored(a, &rules, "a.log", false));
    try t.expect(!pathIgnored(a, &rules, "keep.log", false));
    const nested = [_]IgnoreRule{.{ .pat = "/secret", .base = "src" }};
    try t.expect(pathIgnored(a, &nested, "src/secret", false));
    try t.expect(!pathIgnored(a, &nested, "other/secret", false));
    const tmpd = [_]IgnoreRule{.{ .pat = "tmp/", .base = "src" }};
    try t.expect(pathIgnored(a, &tmpd, "src/tmp", true));
    try t.expect(!pathIgnored(a, &tmpd, "tmp", true));
    const above = [_]IgnoreRule{.{ .pat = "/foo.log", .prefix = "src" }};
    try t.expect(!pathIgnored(a, &above, "foo.log", false));
}

test "grep honors gitignore" {
    const t = std.testing;
    try util.testInit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(util.io, .{ .sub_path = ".gitignore", .data = "*.skip\n" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "keep.txt", .data = "hello keep\n" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "drop.skip", .data = "hello drop\n" });
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    const args = try std.fmt.allocPrint(a, "{{\"pattern\":\"hello\",\"path\":\"{s}\"}}", .{dir});
    const r = try toolGrep(a, args);
    try t.expect(std.mem.indexOf(u8, r.content, "keep") != null);
    try t.expect(std.mem.indexOf(u8, r.content, "drop") == null);
}

test "grep filesWithMatches lists each file once" {
    const t = std.testing;
    try util.testInit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(util.io, .{ .sub_path = "a.txt", .data = "hello\nhello\n" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "b.txt", .data = "hello\n" });
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    const args = try std.fmt.allocPrint(a, "{{\"pattern\":\"hello\",\"path\":\"{s}\",\"filesWithMatches\":true}}", .{dir});
    const r = try toolGrep(a, args);
    try t.expect(std.mem.indexOf(u8, r.content, "a.txt") != null);
    try t.expect(std.mem.indexOf(u8, r.content, "b.txt") != null);
    try t.expect(std.mem.indexOf(u8, r.content, ":1:") == null);
}

test "grep honors nested gitignore" {
    const t = std.testing;
    try util.testInit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(util.io, "sub");
    try tmp.dir.createDirPath(util.io, "other");
    try tmp.dir.writeFile(util.io, .{ .sub_path = "sub/.gitignore", .data = "*.skip\n/secret\n" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "keep.txt", .data = "hello keep\n" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "sub/drop.skip", .data = "hello drop\n" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "sub/ok.txt", .data = "hello ok\n" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "sub/secret", .data = "hello secret\n" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "other/secret", .data = "hello other\n" });
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    const args = try std.fmt.allocPrint(a, "{{\"pattern\":\"hello\",\"path\":\"{s}\"}}", .{dir});
    const r = try toolGrep(a, args);
    try t.expect(std.mem.indexOf(u8, r.content, "keep") != null);
    try t.expect(std.mem.indexOf(u8, r.content, "ok") != null);
    try t.expect(std.mem.indexOf(u8, r.content, "drop") == null);
    try t.expect(std.mem.indexOf(u8, r.content, "hello secret") == null);
    try t.expect(std.mem.indexOf(u8, r.content, "hello other") != null);
}

test "ls hides gitignored and skipped dirs" {
    const t = std.testing;
    try util.testInit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(util.io, ".git");
    try tmp.dir.createDirPath(util.io, "node_modules");
    try tmp.dir.writeFile(util.io, .{ .sub_path = ".gitignore", .data = "*.skip\n" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "keep.txt", .data = "k\n" });
    try tmp.dir.writeFile(util.io, .{ .sub_path = "drop.skip", .data = "d\n" });
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    const hidden = try toolLs(a, try std.fmt.allocPrint(a, "{{\"path\":\"{s}\"}}", .{dir}));
    try t.expect(std.mem.indexOf(u8, hidden.content, "keep.txt") != null);
    try t.expect(std.mem.indexOf(u8, hidden.content, "drop.skip") == null);
    try t.expect(std.mem.indexOf(u8, hidden.content, "node_modules") == null);
    try t.expect(std.mem.indexOf(u8, hidden.content, "hidden") != null);
    const shown = try toolLs(a, try std.fmt.allocPrint(a, "{{\"path\":\"{s}\",\"all\":true}}", .{dir}));
    try t.expect(std.mem.indexOf(u8, shown.content, "drop.skip") != null);
    try t.expect(std.mem.indexOf(u8, shown.content, "node_modules") != null);
}

test "multi_edit is atomic: failure leaves files untouched" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;
    try dir.writeFile(util.io, .{ .sub_path = "one.txt", .data = "alpha beta" });
    try dir.writeFile(util.io, .{ .sub_path = "two.txt", .data = "gamma delta" });

    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmppath = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const old_cwd = try std.process.currentPathAlloc(util.io, a);
    std.Io.Threaded.chdir(tmppath) catch unreachable;
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    // 第二个文件的 edit 匹配不到 → 整批必须回滚(第一个文件也不能被写)
    const bad = try toolMultiEdit(a,
        \\{"files":[{"path":"one.txt","edits":[{"oldText":"alpha","newText":"ALPHA"}]},
        \\          {"path":"two.txt","edits":[{"oldText":"nonexistent","newText":"X"}]}]}
    );
    try t.expect(bad.is_error);
    try t.expect(std.mem.indexOf(u8, bad.content, "nothing was written") != null);
    // 关键断言:磁盘上第一个文件未被改动
    const c1 = try std.Io.Dir.cwd().readFileAlloc(util.io, "one.txt", a, .limited(1024));
    try t.expectEqualStrings("alpha beta", c1);

    // 全部合法 → 都写入
    const ok = try toolMultiEdit(a,
        \\{"files":[{"path":"one.txt","edits":[{"oldText":"alpha","newText":"ALPHA"}]},
        \\          {"path":"two.txt","edits":[{"oldText":"gamma","newText":"GAMMA"}]}]}
    );
    try t.expect(!ok.is_error);
    const c2 = try std.Io.Dir.cwd().readFileAlloc(util.io, "one.txt", a, .limited(1024));
    try t.expectEqualStrings("ALPHA beta", c2);
    const c3 = try std.Io.Dir.cwd().readFileAlloc(util.io, "two.txt", a, .limited(1024));
    try t.expectEqualStrings("GAMMA delta", c3);

    // 同一文件多条 edit 顺序应用
    const seq = try toolMultiEdit(a,
        \\{"files":[{"path":"two.txt","edits":[{"oldText":"GAMMA","newText":"g"},{"oldText":"delta","newText":"d"}]}]}
    );
    try t.expect(!seq.is_error);
    const c4 = try std.Io.Dir.cwd().readFileAlloc(util.io, "two.txt", a, .limited(1024));
    try t.expectEqualStrings("g d", c4);
}

test "read offset and limit slice lines" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(util.io, .{ .sub_path = "n.txt", .data = "l1\nl2\nl3\nl4\nl5\n" });

    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmppath = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const old_cwd = try std.process.currentPathAlloc(util.io, a);
    std.Io.Threaded.chdir(tmppath) catch unreachable;
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    // offset 是 1-based
    const r1 = try toolRead(a, "{\"path\":\"n.txt\",\"offset\":2,\"limit\":2}");
    try t.expect(!r1.is_error);
    try t.expect(std.mem.indexOf(u8, r1.content, "     2|l2") != null);
    try t.expect(std.mem.indexOf(u8, r1.content, "     3|l3") != null);
    try t.expect(std.mem.indexOf(u8, r1.content, "     1|") == null);
    // 只给 limit → 从首行起
    const r2 = try toolRead(a, "{\"path\":\"n.txt\",\"limit\":1}");
    try t.expect(std.mem.indexOf(u8, r2.content, "     1|l1") != null);
    try t.expect(std.mem.indexOf(u8, r2.content, "     2|") == null);
    // offset 越界 → 明确报错而非空内容
    const r3 = try toolRead(a, "{\"path\":\"n.txt\",\"offset\":99}");
    try t.expect(r3.is_error);
    try t.expect(std.mem.indexOf(u8, r3.content, "past end") != null);
    // 不给 offset/limit → 全文
    const r4 = try toolRead(a, "{\"path\":\"n.txt\"}");
    try t.expect(std.mem.indexOf(u8, r4.content, "     1|l1") != null);
    try t.expect(std.mem.indexOf(u8, r4.content, "     5|l5") != null);
    const r5 = try toolRead(a, "{\"path\":\"n.txt\",\"tail\":2}");
    try t.expect(!r5.is_error);
    try t.expect(std.mem.indexOf(u8, r5.content, "     4|l4") != null);
    try t.expect(std.mem.indexOf(u8, r5.content, "     5|l5") != null);
    try t.expect(std.mem.indexOf(u8, r5.content, "     3|") == null);
    const r6 = try toolRead(a, "{\"path\":\"n.txt\",\"offset\":1,\"tail\":2}");
    try t.expect(r6.is_error);
    const r7 = try toolRead(a, "{\"path\":\"n.txt\",\"around\":3,\"limit\":3}");
    try t.expect(!r7.is_error);
    try t.expect(std.mem.indexOf(u8, r7.content, "     2|l2") != null);
    try t.expect(std.mem.indexOf(u8, r7.content, "     3|l3") != null);
    try t.expect(std.mem.indexOf(u8, r7.content, "     4|l4") != null);
    try t.expect(std.mem.indexOf(u8, r7.content, "     1|") == null);
    try t.expect(std.mem.indexOf(u8, r7.content, "     5|") == null);
    const r8 = try toolRead(a, "{\"path\":\"n.txt\",\"around\":3,\"offset\":1}");
    try t.expect(r8.is_error);
}

test "read decodes png and attaches image" {
    const t = std.testing;
    try util.testInit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
        0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    };
    try tmp.dir.writeFile(util.io, .{ .sub_path = "dot.png", .data = &png });
    const dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ try std.process.currentPathAlloc(util.io, a), tmp.sub_path });
    const path = try util.joinPath(a, dir, "dot.png");
    const args = try std.fmt.allocPrint(a, "{{\"path\":\"{s}\"}}", .{path});
    const r = try toolRead(a, args);
    try t.expect(!r.is_error);
    try t.expect(std.mem.indexOf(u8, r.content, "image ") != null);
    try t.expect(r.images != null);
    try t.expectEqual(@as(usize, 1), r.images.?.len);
    try t.expect(r.images.?[0].data.len > 0);
    try t.expect(r.images.?[0].w > 0);
}

test "diskWrite replaces file without leftover tmp" {
    const t = std.testing;
    try util.testInit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ try std.process.currentPathAlloc(util.io, a), tmp.sub_path });
    const path = try util.joinPath(a, dir, "out.txt");
    try diskWrite(path, "hello-atomic");
    try diskWrite(path, "second");
    const got = try std.Io.Dir.cwd().readFileAlloc(util.io, path, a, .limited(64));
    try t.expectEqualStrings("second", got);
}

test "write tool emits diff block" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmppath = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const old_cwd = try std.process.currentPathAlloc(util.io, a);
    std.Io.Threaded.chdir(tmppath) catch unreachable;
    defer std.Io.Threaded.chdir(old_cwd) catch {};
    const r = try toolWrite(a, "{\"path\":\"b.txt\",\"content\":\"x\\ny\\n\"}");
    try t.expect(!r.is_error);
    try t.expect(std.mem.indexOf(u8, r.content, "--- b.txt") != null);
    try t.expect(std.mem.indexOf(u8, r.content, "+x") != null);
    try t.expect(std.mem.indexOf(u8, r.content, "+y") != null);
    const r2 = try toolWrite(a, "{\"path\":\"b.txt\",\"content\":\"z\",\"createOnly\":true}");
    try t.expect(r2.is_error);
    try t.expect(std.mem.indexOf(u8, r2.content, "already exists") != null);
    const preview = try toolWrite(a, "{\"path\":\"dry.txt\",\"content\":\"preview\\n\",\"dryRun\":true}");
    try t.expect(!preview.is_error);
    try t.expect(std.mem.indexOf(u8, preview.content, "dry-run:") != null);
    try t.expect(std.mem.indexOf(u8, preview.content, "+preview") != null);
    if (std.Io.Dir.cwd().statFile(util.io, "dry.txt", .{})) |_| {
        return error.DryRunWroteFile;
    } else |_| {}
}

test "read truncates large files" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmppath = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const old_cwd = try std.process.currentPathAlloc(util.io, a);
    std.Io.Threaded.chdir(tmppath) catch unreachable;
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    // 20KB 文件:输出应截断在 MAX_TOOL_OUTPUT 内且带标记
    try tmp.dir.writeFile(util.io, .{ .sub_path = "big.txt", .data = "x" ** (20 * 1024) });
    const r = try toolRead(a, "{\"path\":\"big.txt\"}");
    try t.expect(!r.is_error);
    try t.expect(r.content.len <= MAX_TOOL_OUTPUT + 160);
    try t.expect(std.mem.indexOf(u8, r.content, "truncated at") != null);
    try t.expect(std.mem.indexOf(u8, r.content, "     1|") != null);
    try t.expect(r.content[r.content.len - 1] == 'x' or std.mem.endsWith(u8, r.content, "x\n"));
    try t.expect(std.mem.indexOf(u8, r.content, "omitted") != null);
}

test "read/write tools" {
    const t = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 必须切进临时目录:工具收的是相对路径,不 chdir 的话 sub/b.txt 会落在
    // 仓库根上,留下一个每次跑测试都重建的脏文件。
    const tmppath = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const old_cwd = try std.process.currentPathAlloc(util.io, a);
    std.Io.Threaded.chdir(tmppath) catch unreachable;
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    // 父目录不存在时 write 应自己建出来
    const rw = try toolWrite(a, "{\"path\":\"sub/b.txt\",\"content\":\"data\"}");
    try t.expect(!rw.is_error);
    const rr = try toolRead(a, "{\"path\":\"sub/b.txt\"}");
    try t.expect(!rr.is_error);
    try t.expect(std.mem.indexOf(u8, rr.content, "     1|data") != null);
}

test "bash tool" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try toolBash(a, "{\"command\":\"echo hello; echo err >&2\"}");
    try t.expect(!r.is_error);
    try t.expect(std.mem.indexOf(u8, r.content, "hello") != null);
    try t.expect(std.mem.indexOf(u8, r.content, "err") != null);
    try t.expect(std.mem.indexOf(u8, r.content, "exit code 0") != null);

    const r2 = try toolBash(a, "{\"command\":\"exit 3\"}");
    try t.expect(r2.is_error);
    try t.expect(std.mem.indexOf(u8, r2.content, "exit code 3") != null);
}

test "bash background returns immediately and writes a log" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t0 = std.Io.Clock.now(.awake, util.io).nanoseconds;
    const r = try toolBash(a, "{\"command\":\"echo bg-ok\",\"background\":true}");
    const dt = std.Io.Clock.now(.awake, util.io).nanoseconds - t0;
    try t.expect(!r.is_error);
    try t.expect(std.mem.indexOf(u8, r.content, "[background]") != null);
    try t.expect(std.mem.indexOf(u8, r.content, "log: ") != null);
    try t.expect(dt < 2 * std.time.ns_per_s);
    const marker = "log: ";
    const i = std.mem.indexOf(u8, r.content, marker).?;
    const rest = r.content[i + marker.len ..];
    const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    const log_path = rest[0..nl];
    var saw = false;
    var n: u32 = 0;
    while (n < 50) : (n += 1) {
        if (std.Io.Dir.cwd().readFileAlloc(util.io, log_path, a, .limited(4096))) |body| {
            if (std.mem.indexOf(u8, body, "bg-ok") != null) {
                saw = true;
                break;
            }
        } else |_| {}
        _ = std.Io.sleep(util.io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};
    }
    try t.expect(saw);
}

test "appendCapped keeps the tail and never grows past 2x the window" {
    const t = std.testing;
    var list = std.array_list.Managed(u8).init(t.allocator);
    defer list.deinit();

    // keep=0 表示不限
    try bash.appendCapped(&list, "abc", 0);
    try t.expectEqualStrings("abc", list.items);
    list.clearRetainingCapacity();

    // 窗口内原样保留
    try bash.appendCapped(&list, "hello", 10);
    try t.expectEqualStrings("hello", list.items);

    // 灌 1000 个 chunk,每个 64 字节 = 64KB 流量,窗口 100 字节。
    // 关键不变量:缓冲永不超过 2×窗口 —— 这是内存有界的全部依据。
    // 原先无界追加:一个吐 500MB 的子进程让父进程驻留 473MB(实测)。
    list.clearRetainingCapacity();
    var i: usize = 0;
    var max_seen: usize = 0;
    while (i < 1000) : (i += 1) {
        var chunk: [64]u8 = undefined;
        @memset(&chunk, @intCast('a' + (i % 26)));
        try bash.appendCapped(&list, &chunk, 100);
        max_seen = @max(max_seen, list.items.len);
    }
    try t.expect(max_seen <= 200);

    // 保的是尾部:最后一个 chunk 的内容必须在
    const last: u8 = @intCast('a' + (999 % 26));
    try t.expectEqual(last, list.items[list.items.len - 1]);
}

test "bash reports the true byte total after dropping the head" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 输出远超 MAX_TOOL_OUTPUT。截断提示里的 total 必须是真实流量,
    // 不是被裁后的缓冲长度 —— 否则「输出了 5MB」会报成「输出了 16KB」,
    // 模型据此判断要不要换个更窄的命令重跑。
    const r = try toolBash(a, "{\"command\":\"head -c 5000000 /dev/zero | tr '\\\\0' x\",\"timeout\":60}");
    try t.expect(!r.is_error);
    try t.expect(std.mem.indexOf(u8, r.content, "truncated at") != null);

    const marker = "total ";
    const pos = std.mem.indexOf(u8, r.content, marker).?;
    var end = pos + marker.len;
    while (end < r.content.len and r.content[end] >= '0' and r.content[end] <= '9') end += 1;
    const total = try std.fmt.parseInt(usize, r.content[pos + marker.len .. end], 10);
    try t.expect(total >= 5_000_000);
    try t.expect(std.mem.indexOf(u8, r.content, "Artifact stored") != null);
    const stored = "[Artifact stored: ";
    const a0 = std.mem.indexOf(u8, r.content, stored).? + stored.len;
    const a1 = std.mem.indexOfScalar(u8, r.content[a0..], ' ').? + a0;
    const path = r.content[a0..a1];
    const spilled = try std.Io.Dir.cwd().readFileAlloc(util.io, path, t.allocator, .limited(6 * 1024 * 1024));
    defer t.allocator.free(spilled);
    try t.expect(spilled.len >= 5_000_000);

    // 交给模型的内容本身仍然受限
    try t.expect(r.content.len < MAX_TOOL_OUTPUT * 2);
}

test "skill tool" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 注:Environ.Map.put 覆盖时 free 旧值,恢复旧值会 UAF——测试内只覆盖不恢复
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    tmp.dir.createDirPath(util.io, "skills/rev") catch {};
    try tmp.dir.writeFile(util.io, .{ .sub_path = "skills/rev/SKILL.md", .data = "name: rev\ndescription: reverse engineering\n" });
    const r = try toolSkill(a, "{\"name\":\"rev\"}");
    try t.expect(!r.is_error);
    try t.expect(std.mem.indexOf(u8, r.content, "reverse engineering") != null);
    // 非法名
    const bad = try toolSkill(a, "{\"name\":\"../evil\"}");
    try t.expect(bad.is_error);
    // 不存在
    const nf = try toolSkill(a, "{\"name\":\"nope\"}");
    try t.expect(nf.is_error);

    // 资源包里的技能也必须能加载。
    //
    // loadSkillsIndex 会扫资源包,所以系统提示里列得出来;而 toolSkill
    // 原先只看 <configDir>/skills/ —— 于是「提示里有、工具报 FileNotFound」。
    // 实测装了包的技能全加载不了,模型只能自己 read SKILL.md 兜底。
    tmp.dir.createDirPath(util.io, "packages/demo-pkg/skills/demo-skill") catch {};
    try tmp.dir.writeFile(util.io, .{
        .sub_path = "packages/demo-pkg/skills/demo-skill/SKILL.md",
        .data = "name: demo-skill\ndescription: from an installed package\n",
    });
    const pk = try toolSkill(a, "{\"name\":\"demo-skill\"}");
    try t.expect(!pk.is_error);
    try t.expect(std.mem.indexOf(u8, pk.content, "from an installed package") != null);
}

test "tool paths resolve against the agent root, not the process cwd" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 无 root:原样返回(CLI 模式,Agent.cwd 就是进程 cwd)
    clearRoot();
    try t.expectEqualStrings("out.txt", resolvePath(a, "out.txt"));
    try t.expect(rootForSpawn() == null);

    // 有 root:相对路径拼到 root 下。web 模式多 workspace 时,会话声明在
    // projB 而 `write out.txt` 落进进程 cwd 是实测复现过的数据损坏。
    setRoot("/tmp/projB");
    defer clearRoot();
    try t.expectEqualStrings("/tmp/projB/out.txt", resolvePath(a, "out.txt"));
    try t.expectEqualStrings("/tmp/projB/sub/deep.txt", resolvePath(a, "sub/deep.txt"));
    try t.expectEqualStrings("/tmp/projB", rootForSpawn().?);

    // 绝对路径不动;写类工具另走 insideRoot
    try t.expectEqualStrings("/etc/hosts", resolvePath(a, "/etc/hosts"));
    try t.expect(insideRoot(a, "out.txt"));
    try t.expect(!insideRoot(a, "/etc/hosts"));
    try t.expect(!insideRoot(a, "../secret"));

    // root 是 thread-local:另一个线程看不到这里设的值,
    // 否则并行的两个 Agent 会互相串目录
    const Probe = struct {
        seen_empty: bool = false,
        fn run(self: *@This()) void {
            self.seen_empty = rootForSpawn() == null;
        }
    };
    var probe = Probe{};
    const th = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    th.join();
    try t.expect(probe.seen_empty);
}

test "bash runs in the agent root" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path[0..] });

    // bash 拿的是任意 shell 文本,resolvePath 帮不上 —— 只能靠子进程的
    // 工作目录。没有这个,web 多 workspace 下 `ls` 列的是别的项目。
    setRoot(root);
    defer clearRoot();
    const r = try toolBash(a, "{\"command\":\"pwd\"}");
    try t.expect(!r.is_error);
    try t.expect(std.mem.indexOf(u8, r.content, tmp.sub_path[0..]) != null);

    // 写文件也落在 root 里
    const w = try toolBash(a, "{\"command\":\"echo marker > from-bash.txt\"}");
    try t.expect(!w.is_error);
    const back = try tmp.dir.readFileAlloc(util.io, "from-bash.txt", a, .limited(64));
    try t.expectEqualStrings("marker\n", back);
}

test "bash cwd stays inside the workspace" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path[0..] });
    try tmp.dir.createDirPath(util.io, "nested");
    setRoot(root);
    defer clearRoot();
    const r = try toolBash(a, "{\"command\":\"pwd\",\"cwd\":\"nested\"}");
    try t.expect(!r.is_error);
    try t.expect(std.mem.indexOf(u8, r.content, "nested") != null);
    const bad = try toolBash(a, "{\"command\":\"pwd\",\"cwd\":\"../..\"}");
    try t.expect(bad.is_error);
    try t.expect(std.mem.indexOf(u8, bad.content, "outside") != null);
    const miss = try toolBash(a, "{\"command\":\"pwd\",\"cwd\":\"nope\"}");
    try t.expect(miss.is_error);
}

test "needsConfirm allows read-class tools and gates writes" {
    const t = std.testing;
    try t.expect(!needsConfirm("read"));
    try t.expect(!needsConfirm("ls"));
    try t.expect(!needsConfirm("grep"));
    try t.expect(!needsConfirm("find"));
    try t.expect(!needsConfirm("skill"));
    try t.expect(needsConfirm("bash"));
    try t.expect(needsConfirm("write"));
    try t.expect(needsConfirm("edit"));
    try t.expect(needsConfirm("multi_edit"));
    try t.expect(needsConfirm("task"));
    try t.expect(needsConfirm("fetch_url"));
    try t.expect(needsConfirm("unknown_mcp_tool"));
}

test "toolGate yolo allows writes, read-only denies them" {
    const t = std.testing;
    try t.expectEqual(ToolGate.allow, toolGate(.yolo, "bash"));
    try t.expectEqual(ToolGate.allow, toolGate(.yolo, "read"));
    try t.expectEqual(ToolGate.ask, toolGate(.ask, "write"));
    try t.expectEqual(ToolGate.allow, toolGate(.ask, "ls"));
    try t.expectEqual(ToolGate.deny, toolGate(.read_only, "bash"));
    try t.expectEqual(ToolGate.allow, toolGate(.read_only, "read"));
}

test "crashResult surfaces error name and tool name" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = crashResult(a, "read", error.FileNotFound);
    try t.expect(r.is_error);
    try t.expectEqualStrings("tool crashed (read): FileNotFound", r.content);
    const r2 = crashResult(a, "write", error.AccessDenied);
    try t.expectEqualStrings("tool crashed (write): AccessDenied", r2.content);
}

test "substBraceArgs quotes json fields" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try bash.substBraceArgs(a, "pdftotext {path} -", "{\"path\":\"/tmp/a.pdf\"}");
    try t.expectEqualStrings("pdftotext '/tmp/a.pdf' -", out);
    try t.expectError(error.MissingArg, bash.substBraceArgs(a, "echo {x}", "{}"));
}

test "workspace sandbox keeps writes in the workspace" {
    const t = std.testing;
    if (sandboxmod.findBwrap() == null) return error.SkipZigTest;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path[0..] });
    setRoot(root);
    defer clearRoot();
    setSandbox(.workspace);
    defer clearSandbox();

    const inside = try toolBash(a, "{\"command\":\"echo marker > from-sandbox.txt\"}");
    try t.expect(!inside.is_error);
    const back = try tmp.dir.readFileAlloc(util.io, "from-sandbox.txt", a, .limited(64));
    try t.expectEqualStrings("marker\n", back);

    const probe = "/tmp/piz-sandbox-probe-test";
    std.Io.Dir.cwd().deleteFile(util.io, probe) catch {};
    const leak = try toolBash(a, "{\"command\":\"echo leaked > /tmp/piz-sandbox-probe-test\"}");
    try t.expect(!leak.is_error);
    try t.expect(!util.fileExists(probe));
}
