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
pub fn toolRead(arena: std.mem.Allocator, args: []const u8) !Result {
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
pub fn toolWrite(arena: std.mem.Allocator, args: []const u8) !Result {
    const r = try twrite.toolWrite(arena, args);
    return .{ .content = r.content, .is_error = r.is_error };
}

pub fn toolEdit(arena: std.mem.Allocator, args: []const u8) !Result {
    const r = try tedit.toolEdit(arena, args);
    return .{ .content = r.content, .is_error = r.is_error };
}

pub fn toolBash(arena: std.mem.Allocator, args: []const u8) !Result {
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
pub fn toolGrep(arena: std.mem.Allocator, args: []const u8) !Result {
    const r = try search.toolGrep(arena, args);
    return .{ .content = r.content, .is_error = r.is_error };
}

/// find: {pattern, path?, limit?} — glob 匹配文件路径,递归。
pub fn toolFind(arena: std.mem.Allocator, args: []const u8) !Result {
    const r = try search.toolFind(arena, args);
    return .{ .content = r.content, .is_error = r.is_error };
}

/// ls: {path?, limit?} — 列目录条目,目录优先按名排序。
pub fn toolLs(arena: std.mem.Allocator, args: []const u8) !Result {
    const r = try search.toolLs(arena, args);
    return .{ .content = r.content, .is_error = r.is_error };
}

/// multi_edit: {files: [{path, edits: [{oldText, newText}]}]}
/// 跨文件批量编辑,**原子语义**:先全量 dry-run 校验,任一失败则一个字节都不写。
/// 这是它相对多次单 edit 调用的核心价值 —— 避免改一半留下不一致的工作树。
pub fn toolMultiEdit(arena: std.mem.Allocator, args: []const u8) !Result {
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

test {
    // 单测主体在 tools_tests.zig(占近八成);引回以保持 zig test 收集。
    _ = @import("tools_tests.zig");
}
