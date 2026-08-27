// tui_types.zig — transcript cell types. Split from tui.zig so emit/paint
// can live in their own file without a cycle.
const std = @import("std");

pub const CellKind = enum {
    session_header,
    status_card,
    user,
    think,
    assistant,
    tool,
    tool_end,
    chrome,
};

pub const ToolStatus = enum { running, ok, err };

/// Structured tool turn. Body is stored always; painted only when unfolded.
pub const ToolMeta = struct {
    name: []u8,
    preview: []u8,
    status: ToolStatus = .running,
    bytes: usize = 0,
    lines: usize = 0,
    start_ms: i64 = 0,
    elapsed_ms: i64 = 0,
    folded: bool = true,
    body: std.array_list.Managed(u8),

    pub fn deinit(self: *ToolMeta, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.preview);
        self.body.deinit();
    }
};

/// One transcript item. `text` never contains paint-time gutters or indent.
pub const Cell = struct {
    kind: CellKind,
    text: std.array_list.Managed(u8),
    color: []const u8 = "",
    card: ?CardFields = null,
    tool: ?ToolMeta = null,
    hl: bool = false,
    card_buf: ?[]u8 = null,
    card_w: usize = 0,
    // markdown 渲染缓存:流式期间每帧 styleMd 重渲染全文是 O(n²),
    // 以 (theme_epoch<<32)|text.len 为指纹,文本只增不改,长度变即失效。
    md_buf: ?[]u8 = null,
    md_fp: usize = 0,
    row_n: usize = 0,
    row_w: usize = 0,
    row_think: bool = false,
    row_fp: usize = 0,
    row_valid: bool = false,
};

/// 欢迎卡 Recent sessions 一行(owned)。
pub const RecentField = struct {
    title: []u8,
    when: []u8,
};

/// 开场欢迎卡专有载荷(owned);挂在 CardFields 上,kind 仍为 session_header。
pub const WelcomeFields = struct {
    provider: []u8 = &.{},
    recents: []RecentField = &.{},
    tip: []u8 = &.{},

    pub fn deinit(self: WelcomeFields, alloc: std.mem.Allocator) void {
        alloc.free(self.provider);
        for (self.recents) |r| {
            alloc.free(r.title);
            alloc.free(r.when);
        }
        alloc.free(self.recents);
        alloc.free(self.tip);
    }
};

pub const CardFields = struct {
    version: []u8,
    model: []u8,
    think: []u8,
    cwd: []u8,
    session: []u8,
    perms: []u8 = &.{},
    context: []u8 = &.{},
    usage: []u8 = &.{},
    welcome: ?WelcomeFields = null,

    pub fn deinit(self: CardFields, alloc: std.mem.Allocator) void {
        alloc.free(self.version);
        alloc.free(self.model);
        alloc.free(self.think);
        alloc.free(self.cwd);
        alloc.free(self.session);
        alloc.free(self.perms);
        alloc.free(self.context);
        alloc.free(self.usage);
        if (self.welcome) |w| w.deinit(alloc);
    }
};
