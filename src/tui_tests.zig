//! tui_tests.zig —— tui.zig 的单测主体(38 测试 + 测试专用绘制助手)。
//! 拆自 tui.zig(测试与生产码交错,生产助手留原处);tui.zig 尾部 test 钩子引回,收集不变。
const std = @import("std");
const util = @import("core").util;
const theme_mod = @import("theme.zig");
const markdown = @import("markdown.zig");
const slash = @import("tui_slash.zig");
const measure = @import("tui_measure.zig");
const footer = @import("tui_footer.zig");
const keys = @import("tui_keys.zig");
const draw = @import("tui_draw.zig");
const emit = @import("tui_emit.zig");
const tui = @import("tui.zig");

// tui.zig 的 pub 声明(类型/常量/自由函数/主题全局)
const ANSI_BOLD = tui.ANSI_BOLD;
const ANSI_DIM = tui.ANSI_DIM;
const ANSI_ITALIC = tui.ANSI_ITALIC;
const ENTER_ALT_SCROLL = tui.ENTER_ALT_SCROLL;
const LEAVE_ALT_SCROLL = tui.LEAVE_ALT_SCROLL;
const Theme = tui.Theme;
const theme = &tui.theme; // 全局 var;测试要改 mode,取指针用之
const CellKind = tui.CellKind;
const Cell = tui.Cell;
const SessionInfo = tui.SessionInfo;
const StatusInfo = tui.StatusInfo;
const PickerItem = tui.PickerItem;
const SlashItem = tui.SlashItem;
const SlashRank = tui.SlashRank;
const Picker = tui.Picker;
const slashName = tui.slashName;
const slashQuery = tui.slashQuery;
const rankSlash = tui.rankSlash;
const footerHint = tui.footerHint;
const FooterIdent = tui.FooterIdent;
const footerNeedsTwoRows = tui.footerNeedsTwoRows;
const formatFooterRows = tui.formatFooterRows;
const formatTok = tui.formatTok;
const formatCtx = tui.formatCtx;
const formatCache = tui.formatCache;
const layoutFooter = tui.layoutFooter;
const cardInner = tui.cardInner;
const formatSessionCard = tui.formatSessionCard;
const formatStatusCard = tui.formatStatusCard;
const scrollSkip = tui.scrollSkip;
const workingRows = tui.workingRows;
const composerBoxWidth = tui.composerBoxWidth;
const composerInnerWidth = tui.composerInnerWidth;
const composerTopRow = tui.composerTopRow;
const composerInputRow = tui.composerInputRow;
const histEscape = tui.histEscape;
const histUnescape = tui.histUnescape;
const paintedOf = tui.paintedOf;
const cellRowCountCached = tui.cellRowCountCached;
const Tui = tui.Tui;

// 子模块直达(tui.zig 里的同名别名是私有的,此处自镜像)
const gapBetween = emit.gapBetween;
const gutter = emit.gutter;
const wrapRowCount = emit.wrapRowCount;
const emitCell = emit.emitCell;
const emitComposer = emit.emitComposer;
const classifyThink = emit.classifyThink;
const wrapCursor = emit.wrapCursor;
const cellRowCount = emit.cellRowCount;
const gutterInner = emit.gutterInner;
const thinkRowCount = emit.thinkRowCount;
const joinFit = measure.joinFit;
const skipAnsi = measure.skipAnsi;
const visibleCols = measure.visibleCols;
const consumeSameCsi = keys.consumeSameCsi;
const sgrWheel = keys.sgrWheel;
const classifyCsi = keys.classifyCsi;
const deleteUtf8Before = keys.deleteUtf8Before;
const utf8PrevLen = keys.utf8PrevLen;
const utf8LenAt = keys.utf8LenAt;
const writeBoxEdge = draw.writeBoxEdge;

test "history escape roundtrip" {
    const t = std.testing;
    const a = t.allocator;
    const esc = try histEscape(a, "zz\nyy");
    defer a.free(esc);
    try t.expectEqualStrings("zz\\nyy", esc);
    const back = try histUnescape(a, esc);
    defer a.free(back);
    try t.expectEqualStrings("zz\nyy", back);
    // 单行不转义,读回原样
    const plain = try histUnescape(a, "hello");
    defer a.free(plain);
    try t.expectEqualStrings("hello", plain);
}

fn paintComposerBox(alloc: std.mem.Allocator, input: []const u8, cols: usize, inner_rows: usize, skip: usize) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    errdefer aw.deinit();
    const box_w = composerBoxWidth(cols);
    const inner = composerInnerWidth(true, cols);
    try writeBoxEdge(&aw.writer, "╭", "╮", box_w);
    try emitComposer(&aw.writer, input, inner, inner_rows, skip);
    try writeBoxEdge(&aw.writer, "╰", "╯", box_w);
    return aw.toOwnedSlice();
}

fn stripForTest(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < s.len) {
        const next = skipAnsi(s, i);
        if (next != i) {
            i = next;
            continue;
        }
        if (s[i] == '\r') {
            i += 1;
            continue;
        }
        try out.append(s[i]);
        i += 1;
    }
    // 色带补白留尾空格:剥码后逐行修剪,免扰纯文断言
    var trimmed = std.array_list.Managed(u8).init(alloc);
    errdefer trimmed.deinit();
    var it = std.mem.splitScalar(u8, out.items, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try trimmed.append('\n');
        first = false;
        try trimmed.appendSlice(std.mem.trimEnd(u8, line, " "));
    }
    out.deinit();
    return trimmed.toOwnedSlice();
}

fn footerPlain(alloc: std.mem.Allocator, ident: FooterIdent, hint: ?[]const u8, width: usize, two_rows: bool) ![]u8 {
    const rows = try formatFooterRows(alloc, ident, hint, width, two_rows);
    defer rows.deinit(alloc);
    const p = try stripForTest(alloc, rows.primary);
    defer alloc.free(p);
    const s = try stripForTest(alloc, rows.secondary);
    defer alloc.free(s);
    if (s.len == 0) return alloc.dupe(u8, p);
    return std.fmt.allocPrint(alloc, "{s}\n{s}", .{ p, s });
}

fn countNonEmptyLines(plain: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, plain, '\n');
    while (it.next()) |line| {
        if (line.len > 0) n += 1;
    }
    return n;
}

fn lineIndent(plain: []const u8, needle: []const u8) ?usize {
    const at = std.mem.indexOf(u8, plain, needle) orelse return null;
    var start = at;
    while (start > 0 and plain[start - 1] != '\n') start -= 1;
    var n: usize = 0;
    while (start + n < plain.len and plain[start + n] == ' ') n += 1;
    return n;
}

fn paintCellsForTest(alloc: std.mem.Allocator, ui: *Tui, width: usize) ![]u8 {
    try ui.ensurePainted(width);
    var fw = std.Io.Writer.Allocating.init(alloc);
    errdefer fw.deinit();
    var ci: usize = 0;
    while (ci < ui.cells.items.len) : (ci += 1) {
        if (ci > 0 and gapBetween(ui.cells.items[ci - 1].kind, ui.cells.items[ci].kind)) {
            try fw.writer.writeAll("\x1b[K\r\n");
        }
        const painted = paintedOf(ui.cells.items[ci]);
        _ = try emitCell(alloc, &fw.writer, &ui.cells.items[ci], painted, true, width, 0, 64);
    }
    return fw.toOwnedSlice();
}

fn expectComposerClosed(alloc: std.mem.Allocator, painted: []const u8, cols: usize) !void {
    const t = std.testing;
    const plain = try stripForTest(alloc, painted);
    defer alloc.free(plain);
    try t.expect(plain.len > 0);
    try t.expect(std.mem.startsWith(u8, plain, "╭"));
    var last_line: []const u8 = plain;
    var it = std.mem.splitScalar(u8, plain, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        n += 1;
        last_line = line;
        try t.expect(visibleCols(line) <= cols);
    }
    try t.expect(n >= 3);
    try t.expect(std.mem.startsWith(u8, last_line, "╰"));
}

test "gutters are unique and not baked into cells" {
    const t = std.testing;
    try t.expect(std.mem.indexOf(u8, gutter(.user).first, "▎") != null);
    try t.expect(std.mem.indexOf(u8, gutter(.user).first, "› ") == null);
    try t.expect(std.mem.indexOf(u8, gutter(.user).first, ANSI_BOLD) != null);
    try t.expect(std.mem.indexOf(u8, gutter(.user).first, ANSI_ITALIC) == null);
    try t.expect(std.mem.indexOf(u8, gutter(.user).first, ANSI_DIM) == null);
    try t.expectEqualStrings("  ", gutter(.assistant).first);
    try t.expect(std.mem.indexOf(u8, gutter(.assistant).first, "▎") == null);
    try t.expect(std.mem.indexOf(u8, gutter(.assistant).first, "┌") == null);
    try t.expect(std.mem.indexOf(u8, gutter(.tool).first, "▸") != null);
    try t.expect(std.mem.indexOf(u8, gutter(.tool).first, "┌") == null);
    try t.expect(gutter(.tool).pad > gutter(.assistant).pad);
    try t.expect(std.mem.indexOf(u8, gutter(.think).first, ANSI_ITALIC) != null);
    try t.expect(std.mem.indexOf(u8, gutter(.think).first, ANSI_DIM) == null);
    try t.expect(std.mem.indexOf(u8, gutter(.think).first, "┆") != null);
    try t.expectEqual(@as(usize, 6), gutter(.think).pad);
    try t.expect(std.mem.indexOf(u8, gutter(.tool_end).first, "└ ") != null);
    try t.expectEqual(@as(usize, 2), gutter(.user).pad);
    try t.expectEqual(@as(usize, 2), gutter(.assistant).pad);
    try t.expectEqual(@as(usize, 6), gutter(.tool).pad);
    try t.expectEqual(@as(usize, 8), gutter(.tool_end).pad);
    try t.expectEqual(@as(usize, 0), gutter(.chrome).pad);
    try t.expectEqual(@as(usize, 78), gutterInner(.user, 80));
    try t.expectEqual(@as(usize, 74), gutterInner(.tool, 80));
    try t.expectEqual(@as(usize, 80), gutterInner(.chrome, 80));

    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendUser("hello");
    try ui.appendText("world");
    try ui.appendThink("hmm");
    try ui.appendTool("bash", "ls");
    try ui.appendToolEnd("bash", false, "4B");
    for (ui.cells.items) |c| {
        try t.expect(std.mem.indexOf(u8, c.text.items, "› ") == null);
        try t.expect(std.mem.indexOf(u8, c.text.items, "• ") == null);
        try t.expect(std.mem.indexOf(u8, c.text.items, "└ ") == null);
    }
    try t.expect(ui.cells.items[0].kind == .user);
    try t.expectEqualStrings("hello", ui.cells.items[0].text.items);
    try t.expect(ui.cells.items[1].kind == .assistant);
    try t.expectEqualStrings("world", ui.cells.items[1].text.items);
}

test "mouse modes follow Codex: 1007 not 1000" {
    const t = std.testing;
    try t.expect(std.mem.indexOf(u8, ENTER_ALT_SCROLL, "1007h") != null);
    try t.expect(std.mem.indexOf(u8, ENTER_ALT_SCROLL, "1000") == null);
    try t.expect(std.mem.indexOf(u8, ENTER_ALT_SCROLL, "1006") == null);
    try t.expect(std.mem.indexOf(u8, LEAVE_ALT_SCROLL, "1007l") != null);
}

test "Codex blank-line rhythm between layers" {
    const t = std.testing;
    try t.expect(gapBetween(.session_header, .user));
    try t.expect(gapBetween(.user, .think));
    try t.expect(gapBetween(.user, .assistant));
    try t.expect(gapBetween(.think, .assistant));
    try t.expect(gapBetween(.assistant, .tool));
    try t.expect(gapBetween(.tool_end, .assistant));
    try t.expect(gapBetween(.assistant, .chrome));
    try t.expect(!gapBetween(.tool, .tool_end));
    try t.expect(!gapBetween(.tool, .tool));
    try t.expect(!gapBetween(.tool_end, .tool));
    try t.expect(!gapBetween(.assistant, .assistant));
}

test "painted roles differ by layer" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendUser("hello");
    try ui.appendThink("hmm");
    try ui.appendText("world");
    try ui.appendTool("bash", "ls");
    try ui.appendToolEnd("bash", false, "4B");
    try ui.appendLine("", "\x1b[2m", "notice");

    const out = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(out);
    const plain = try stripForTest(t.allocator, out);
    defer t.allocator.free(plain);

    try t.expect(std.mem.indexOf(u8, plain, "┌ user") == null);
    try t.expect(std.mem.indexOf(u8, plain, "▎ hello") != null);
    try t.expect(std.mem.indexOf(u8, plain, "▎ world") == null);
    try t.expect(std.mem.indexOf(u8, plain, "thought") == null);
    try t.expect(std.mem.indexOf(u8, plain, "┆ hmm") != null);
    try t.expect(std.mem.indexOf(u8, plain, "  world") != null);
    try t.expect(std.mem.indexOf(u8, plain, "    ▸ bash  ls") != null);
    try t.expect(std.mem.indexOf(u8, plain, "ok") != null);
    try t.expect(std.mem.indexOf(u8, plain, "▎ hello\n\n    ┆ hmm") != null);
    try t.expect(std.mem.indexOf(u8, plain, "    ┆ hmm\n\n  world") != null);
    try t.expect(std.mem.indexOf(u8, plain, "  world\n\n    ▸ bash  ls") != null);
    try t.expect(std.mem.indexOf(u8, plain, "notice") != null);

    try t.expectEqual(@as(usize, 0), lineIndent(plain, "hello").?);
    try t.expectEqual(@as(usize, 4), lineIndent(plain, "hmm").?);
    try t.expectEqual(@as(usize, 2), lineIndent(plain, "world").?);
    try t.expectEqual(@as(usize, 4), lineIndent(plain, "bash").?);
    try t.expect(lineIndent(plain, "hmm").? > lineIndent(plain, "world").?);
    try t.expect(lineIndent(plain, "bash").? > lineIndent(plain, "world").?);

    try t.expect(std.mem.indexOf(u8, gutter(.user).first, ANSI_ITALIC) == null);
    try t.expect(std.mem.indexOf(u8, gutter(.user).first, ANSI_BOLD) != null);
    try t.expect(std.mem.indexOf(u8, gutter(.think).first, ANSI_ITALIC) != null);
    try t.expect(std.mem.indexOf(u8, gutter(.think).first, ANSI_DIM) == null);
    try t.expect(std.mem.indexOf(u8, out, ANSI_ITALIC) != null);
    try t.expect(std.mem.indexOf(u8, out, ANSI_BOLD ++ "▎ ") != null);
    try t.expect(std.mem.indexOf(u8, out, ANSI_BOLD ++ "bash") != null);
    try t.expect(std.mem.indexOf(u8, out, ANSI_DIM ++ ANSI_ITALIC ++ "ls") != null);
    try t.expect(std.mem.indexOf(u8, out, ANSI_ITALIC) != null);
}

test "tool cells default folded with summary, not body" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendTool("read", "src/tui.zig");
    try t.expectEqual(@as(usize, 1), ui.cells.items.len);
    try t.expect(ui.cells.items[0].kind == .tool);
    try t.expect(ui.cells.items[0].tool.?.folded);
    try t.expect(ui.cells.items[0].tool.?.status == .running);

    try ui.appendToolEnd("read", false, "line one\nline two\nSECRET_BODY\n");
    try t.expectEqual(@as(usize, 1), ui.cells.items.len);
    try t.expect(ui.cells.items[0].kind == .tool);
    try t.expect(ui.cells.items[0].kind != .tool_end);
    const meta = ui.cells.items[0].tool.?;
    try t.expect(meta.folded);
    try t.expect(meta.status == .ok);
    try t.expectEqual(@as(usize, 3), meta.lines);
    try t.expectEqualStrings("src/tui.zig", meta.preview);

    const out = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(out);
    const plain = try stripForTest(t.allocator, out);
    defer t.allocator.free(plain);
    try t.expect(std.mem.indexOf(u8, plain, "    ▸ read  src/tui.zig") != null);
    try t.expect(std.mem.indexOf(u8, plain, "ok") != null);
    try t.expect(std.mem.indexOf(u8, plain, "3ln") != null);
    try t.expect(std.mem.indexOf(u8, plain, "SECRET_BODY") == null);
    try t.expect(std.mem.indexOf(u8, plain, "SECRET") == null);
    try t.expect(countNonEmptyLines(plain) <= 2);
}

test "Ctrl+O expands and folds tool body" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendTool("bash", "zig build test");
    try ui.appendToolEnd("bash", false, "ok line\nSECRET_BODY\n");
    try t.expect(ui.cells.items[0].tool.?.folded);

    _ = try ui.handleInput(&.{0x0f});
    try t.expect(!ui.cells.items[0].tool.?.folded);
    const expanded = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(expanded);
    const exp_plain = try stripForTest(t.allocator, expanded);
    defer t.allocator.free(exp_plain);
    // 展开态升级为 omp 形盒子:╭─ 顶边 / │ 正文 │ / ╰─ 底边;旧 gutter └ 退场
    try t.expect(std.mem.indexOf(u8, exp_plain, "╭─ bash") != null);
    try t.expect(std.mem.indexOf(u8, exp_plain, "zig build test") != null);
    try t.expect(std.mem.indexOf(u8, exp_plain, "ok") != null);
    try t.expect(std.mem.indexOf(u8, exp_plain, "│ ok line") != null);
    try t.expect(std.mem.indexOf(u8, exp_plain, "SECRET_BODY") != null);
    try t.expect(std.mem.indexOf(u8, exp_plain, "└") == null);
    try t.expect(std.mem.indexOf(u8, exp_plain, "╰─ Wall") != null);

    ui.toggleTools();
    try t.expect(ui.cells.items[0].tool.?.folded);
    const folded = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(folded);
    const fold_plain = try stripForTest(t.allocator, folded);
    defer t.allocator.free(fold_plain);
    try t.expect(std.mem.indexOf(u8, fold_plain, "SECRET_BODY") == null);
}

test "sibling tools have no user-sized gap" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendUser("do work");
    try ui.appendTool("bash", "ls");
    try ui.appendToolEnd("bash", false, "a\n");
    try ui.appendTool("read", "src/tui.zig");
    try ui.appendToolEnd("read", true, "missing\n");
    try t.expectEqual(@as(usize, 3), ui.cells.items.len);
    try t.expect(!gapBetween(.tool, .tool));
    try t.expect(gapBetween(.user, .tool));

    const out = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(out);
    const plain = try stripForTest(t.allocator, out);
    defer t.allocator.free(plain);
    try t.expect(std.mem.indexOf(u8, plain, "▎ do work\n\n    ▸ bash  ls") != null);
    try t.expect(std.mem.indexOf(u8, plain, "▸ bash  ls") != null);
    try t.expect(std.mem.indexOf(u8, plain, "▸ read  src/tui.zig") != null);
    try t.expect(std.mem.indexOf(u8, plain, "err") != null);
    try t.expect(std.mem.indexOf(u8, plain, "missing") == null);
    try t.expect(std.mem.indexOf(u8, plain, "▸ bash  ls\n\n    ▸ read") == null);
}

test "consumeSameCsi counts a wheel burst" {
    const t = std.testing;
    const burst = "\x1b[A\x1b[A\x1b[A";
    var i: usize = 3;
    try t.expectEqual(@as(usize, 2), consumeSameCsi(burst, &i, "", 'A'));
    try t.expectEqual(@as(usize, burst.len), i);
    var j: usize = 3;
    try t.expectEqual(@as(usize, 0), consumeSameCsi("\x1b[A\x1b[B", &j, "", 'A'));
}

test "utf8 helpers" {
    const t = std.testing;
    const s = "a中b";
    try t.expectEqual(@as(usize, 1), utf8LenAt(s, 0));
    try t.expectEqual(@as(usize, 3), utf8LenAt(s, 1));
    try t.expectEqual(@as(usize, 3), utf8PrevLen(s, 4));
    try t.expectEqual(@as(usize, 1), utf8PrevLen(s, 1));
}

test "backspace deletes one CJK codepoint without OOB" {
    const t = std.testing;
    var buf = std.array_list.Managed(u8).init(t.allocator);
    defer buf.deinit();
    try buf.appendSlice("你好");
    var cursor: usize = buf.items.len;
    deleteUtf8Before(&buf, &cursor);
    try t.expectEqualStrings("你", buf.items);
    try t.expectEqual(@as(usize, 3), cursor);
    deleteUtf8Before(&buf, &cursor);
    try t.expectEqualStrings("", buf.items);
    try t.expectEqual(@as(usize, 0), cursor);
    deleteUtf8Before(&buf, &cursor);
    try t.expectEqual(@as(usize, 0), cursor);
}

test "soft wrap counts CJK columns and does not truncate" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 1), wrapRowCount("hello", 80));
    try t.expectEqual(@as(usize, 2), wrapRowCount("0123456789", 5));
    try t.expectEqual(@as(usize, 1), wrapRowCount("工作目录是哪里啊", 20));
    try t.expectEqual(@as(usize, 2), wrapRowCount("工作目录是哪里啊", 8));
    try t.expectEqual(@as(usize, 1), thinkRowCount("abc", false, 80));
    try t.expectEqual(@as(usize, 1), thinkRowCount("abc", true, 80));
    try t.expect(classifyThink(0) == .off);
    try t.expect(classifyThink(100) == .low);
    try t.expect(classifyThink(800) == .medium);
    try t.expect(classifyThink(4000) == .max);
}

test "CSI shift arrows and delete" {
    const t = std.testing;
    try t.expect(classifyCsi("", 'A') == .up);
    try t.expect(classifyCsi("", 'B') == .down);
    try t.expect(classifyCsi("1;2", 'A') == .shift_up);
    try t.expect(classifyCsi("1;2", 'B') == .shift_down);
    try t.expect(classifyCsi("2", 'A') == .shift_up);
    try t.expect(classifyCsi("3", '~') == .delete);
    try t.expect(classifyCsi("5", '~') == .page_up);
    try t.expect(classifyCsi("6", '~') == .page_down);
    try t.expect(classifyCsi("1;5", 'A') == .ctrl_up);
    try t.expect(classifyCsi("1;5", 'B') == .ctrl_down);
    try t.expect(classifyCsi("", 'H') == .home);
    try t.expect(sgrWheel("<64;10;5") == .up);
    try t.expect(sgrWheel("<65;10;5") == .down);
    try t.expect(sgrWheel("<80;1;1") == .up);
    try t.expect(sgrWheel("<0;1;1") == null);
}

test "footer hint wins over status" {
    const t = std.testing;
    try t.expectEqualStrings("y allow  n deny  a always  s skip", footerHint(.{ .perm = true, .picker = true, .quit_armed = true }).?);
    try t.expectEqualStrings("up/down select  enter confirm  esc cancel", footerHint(.{ .picker = true, .quit_armed = true }).?);
    try t.expectEqualStrings("ctrl+c again to quit", footerHint(.{ .quit_armed = true, .esc_armed = true }).?);
    try t.expectEqualStrings("esc again to edit last", footerHint(.{ .esc_armed = true, .scrolled = true }).?);
    try t.expectEqualStrings("pgup/pgdn to scroll", footerHint(.{ .scrolled = true }).?);
    try t.expectEqualStrings("up/down select  tab complete  enter run", footerHint(.{ .slash = true }).?);
    try t.expectEqualStrings("? for shortcuts", footerHint(.{}).?);
    try t.expectEqualStrings("tab to queue", footerHint(.{ .has_draft = true, .running = true }).?);
    try t.expect(footerHint(.{ .has_draft = true }) == null);
}

test "layoutFooter keeps context on the right" {
    const t = std.testing;
    const a = try layoutFooter(t.allocator, "? for shortcuts", "12%", 24);
    defer t.allocator.free(a);
    try t.expectEqualStrings("? for shortcuts      12%", a);
    const b = try layoutFooter(t.allocator, "? for shortcuts", "12%", 10);
    defer t.allocator.free(b);
    try t.expectEqualStrings("? for shor", b);
    const c = try layoutFooter(t.allocator, null, "12%", 8);
    defer t.allocator.free(c);
    try t.expectEqualStrings("     12%", c);
}

test "footer identity has hierarchy and never drops model" {
    const t = std.testing;
    const ident = FooterIdent{
        .model = "deepseek/v4-flash",
        .think = "max",
        .cwd = "~/桌面",
        .session = "1786748577703",
        .used = 12_000,
        .window = 128_000,
        .cache_read = 7_440,
        .prompt = 12_000,
        .tok_in = 4_700,
        .tok_out = 44,
        .tok_cache_r = 7_440,
        .cost = 0.009,
        .pct = 9,
    };
    const rows = try formatFooterRows(t.allocator, ident, "? for shortcuts", 80, true);
    defer rows.deinit(t.allocator);
    const primary = try stripForTest(t.allocator, rows.primary);
    defer t.allocator.free(primary);
    const secondary = try stripForTest(t.allocator, rows.secondary);
    defer t.allocator.free(secondary);
    // pi 式:行 1 = cwd (+branch),hint 右端;行 2 = stats 左,model · think 右
    try t.expect(std.mem.indexOf(u8, primary, "~/桌面") != null);
    try t.expect(std.mem.indexOf(u8, primary, "? for shortcuts") != null);
    try t.expect(std.mem.indexOf(u8, secondary, "deepseek/v4-flash · max") != null);
    try t.expect(std.mem.indexOf(u8, secondary, "ctx 9% 12k/128k") != null);
    try t.expect(std.mem.indexOf(u8, secondary, "R7.4k") != null);
    try t.expect(std.mem.indexOf(u8, secondary, "↑4.7k ↓44") != null);
    // pi 式:$ 三位小数 + CH 命中率(7440/12000)
    try t.expect(std.mem.indexOf(u8, secondary, "$0.009") != null);
    try t.expect(std.mem.indexOf(u8, secondary, "CH62%") != null);
    try t.expect(std.mem.indexOf(u8, rows.secondary, ANSI_DIM ++ "deepseek/v4-flash") != null);
    // 宽 >= 50 恒双行,窄端单行
    try t.expect(footerNeedsTwoRows(ident, "? for shortcuts", 80));
    try t.expect(footerNeedsTwoRows(ident, "? for shortcuts", 120));
    try t.expect(!footerNeedsTwoRows(ident, "? for shortcuts", 49));

    const wide_rows = try formatFooterRows(t.allocator, ident, "? for shortcuts", 120, true);
    defer wide_rows.deinit(t.allocator);
    const wide_s = try stripForTest(t.allocator, wide_rows.secondary);
    defer t.allocator.free(wide_s);
    try t.expect(std.mem.indexOf(u8, wide_s, "deepseek/v4-flash") != null);
    try t.expect(std.mem.indexOf(u8, wide_s, "ctx 9% 12k/128k") != null);

    // branch 缀于行 1 cwd 后
    var with_branch = ident;
    with_branch.branch = "main";
    const br_rows = try formatFooterRows(t.allocator, with_branch, null, 80, true);
    defer br_rows.deinit(t.allocator);
    const br_p = try stripForTest(t.allocator, br_rows.primary);
    defer t.allocator.free(br_p);
    try t.expect(std.mem.indexOf(u8, br_p, "~/桌面 (main)") != null);

    // 极窄(<40)顶边纯线,页脚维持 pi 双行:地点截断不画崩,行 2 仍在
    const tight = try formatFooterRows(t.allocator, ident, "? for shortcuts", 18, true);
    defer tight.deinit(t.allocator);
    const tight_p = try stripForTest(t.allocator, tight.primary);
    defer t.allocator.free(tight_p);
    try t.expect(std.mem.indexOf(u8, tight_p, "~/") != null);
    try t.expect(tight.secondary.len > 0);

    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.setFooterIdentity(with_branch);
    try t.expectEqual(@as(usize, 0), ui.cells.items.len);
    try t.expect(ui.footer_model.items.len > 0);
    try t.expectEqualStrings("main", ui.footer_branch.items);
}

test "footer pi-style: place row 1, stats/model row 2; narrow packs" {
    const t = std.testing;
    const ident = FooterIdent{
        .model = "deepseek/v4-flash",
        .think = "max",
        .cwd = "~/project/pi-zig",
        .session = "1786748577703",
        .used = 12_000,
        .window = 128_000,
        .cache_read = 7_440,
        .prompt = 12_000,
        .tok_in = 4_700,
        .tok_out = 44,
        .tok_cache_r = 7_440,
        .pct = 9,
    };
    const hint = "? for shortcuts";
    const widths = [_]usize{ 80, 120 };
    for (widths) |cols| {
        const plain = try footerPlain(t.allocator, ident, hint, cols, true);
        defer t.allocator.free(plain);
        // pi 式双行:行 1 地点 + hint,行 2 stats + model · think
        try t.expect(std.mem.indexOf(u8, plain, "\n") != null);
        try t.expect(std.mem.indexOf(u8, plain, "~/project/pi-zig") != null);
        try t.expect(std.mem.indexOf(u8, plain, hint) != null);
        try t.expect(std.mem.indexOf(u8, plain, "deepseek/v4-flash · max") != null);
        try t.expect(std.mem.indexOf(u8, plain, "ctx 9% 12k/128k") != null);
    }

    // 宽端单行:host 身份(cwd · session),model 已上顶边不重复
    const packed90 = try footerPlain(t.allocator, ident, hint, 90, false);
    defer t.allocator.free(packed90);
    try t.expect(std.mem.indexOf(u8, packed90, "\n") == null);
    try t.expect(std.mem.indexOf(u8, packed90, "~/project/pi-zig") != null);
    try t.expect(std.mem.indexOf(u8, packed90, "1786748577703") != null);
    try t.expect(std.mem.indexOf(u8, packed90, "deepseek/v4-flash") == null);

    const long_ident = FooterIdent{
        .model = "m",
        .cwd = "~/abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz",
        .session = "123",
    };
    const squeezed = try footerPlain(t.allocator, long_ident, hint, 36, true);
    defer t.allocator.free(squeezed);
    try t.expect(std.mem.indexOf(u8, squeezed, "~/") != null);
    try t.expect(std.mem.indexOf(u8, squeezed, "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz") == null);

    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.setFooterIdentity(ident);
    for (widths) |cols| {
        ui.width = cols;
        ui.height = 24;
        const bottom = ui.measureBottom(0, false, &.{});
        try t.expect(bottom.composer_rows >= 3);
        try t.expectEqual(composerBoxWidth(cols), if (cols > 1) cols - 1 else cols);
        try t.expectEqual(@as(usize, 1), bottom.footer_ident_rows);
        const painted = try footerPlain(t.allocator, ident, hint, cols, bottom.footer_ident_rows >= 2);
        defer t.allocator.free(painted);
        try t.expect(std.mem.indexOf(u8, painted, "~/project/pi-zig") != null);
    }
}

test "footer overflow keeps model and never leaks raw ANSI" {
    const t = std.testing;
    // 客报乱码 $e[2m:slim stats 的 defer 曾块尾即焚,layoutFooter 读已 free 内存。
    // 锁死:窄端+长模型名触发溢出降级,模型名必须在,且每个 \x1b 都是完整 CSI。
    const ident = FooterIdent{
        .model = "deepseek/v4-flash-vision-exp",
        .think = "max",
        .cwd = "~/project/pi-zig",
        .session = "1",
        .used = 5_000,
        .window = 1_000_000,
        .cache_read = 4_800,
        .prompt = 4_900,
        .tok_in = 4_900,
        .tok_out = 65,
        .tok_cache_r = 4_800,
        .cost = 0.0,
        .pct = 0,
    };
    var cols: usize = 52;
    while (cols <= 96) : (cols += 1) {
        const rows = try formatFooterRows(t.allocator, ident, "? for shortcuts", cols, true);
        defer rows.deinit(t.allocator);
        const plain = try stripForTest(t.allocator, rows.secondary);
        defer t.allocator.free(plain);
        try t.expect(std.mem.indexOf(u8, plain, "deepseek/v4-flash-vision-exp") != null);
        var i: usize = 0;
        while (i < rows.secondary.len) : (i += 1) {
            if (rows.secondary[i] == 0x1b) {
                try t.expect(i + 1 < rows.secondary.len and rows.secondary[i + 1] == '[');
                var k = i + 2;
                while (k < rows.secondary.len and !(rows.secondary[k] >= '@' and rows.secondary[k] <= '~')) k += 1;
                try t.expect(k < rows.secondary.len);
                i = k;
            }
        }
    }
    // 降级顺序:cache/CH 先弃,cost 留到最后(客之 $ 花费不得随 cache 俱没)
    const r1 = try formatFooterRows(t.allocator, ident, "? for shortcuts", 78, true);
    defer r1.deinit(t.allocator);
    const p1 = try stripForTest(t.allocator, r1.secondary);
    defer t.allocator.free(p1);
    try t.expect(std.mem.indexOf(u8, p1, "$0.000") != null); // 第 1 级:保 cost
    try t.expect(std.mem.indexOf(u8, p1, "R4.8k") == null); // cache 已弃
    const r2 = try formatFooterRows(t.allocator, ident, "? for shortcuts", 64, true);
    defer r2.deinit(t.allocator);
    const p2 = try stripForTest(t.allocator, r2.secondary);
    defer t.allocator.free(p2);
    try t.expect(std.mem.indexOf(u8, p2, "$0.000") != null); // 第 2 级:flow 弃而 cost 仍在
    try t.expect(std.mem.indexOf(u8, p2, "↑4.9k") == null);
}

test "session card renders at paint width" {
    const t = std.testing;
    const info = SessionInfo{
        .version = "0.1.0",
        .model = "deepseek/flash",
        .think = "high",
        .cwd = "~/pi-zig",
        .session = "1786735635034",
    };
    const wide = try formatSessionCard(t.allocator, info, 80);
    defer t.allocator.free(wide);
    const narrow = try formatSessionCard(t.allocator, info, 40);
    defer t.allocator.free(narrow);
    try t.expect(std.mem.indexOf(u8, wide, "╭") != null);
    try t.expect(std.mem.indexOf(u8, wide, "╰") != null);
    try t.expect(std.mem.indexOf(u8, wide, ">_ ") != null);
    try t.expect(std.mem.indexOf(u8, wide, "piz") != null);
    try t.expect(std.mem.indexOf(u8, wide, "model:") != null);
    try t.expect(std.mem.indexOf(u8, wide, "deepseek/flash") != null);
    try t.expect(std.mem.indexOf(u8, wide, "/model") != null);
    try t.expect(std.mem.indexOf(u8, wide, "/status") != null);
    try t.expect(std.mem.indexOf(u8, wide, "1786735635034") != null);
    try t.expect(std.mem.indexOf(u8, wide, ANSI_BOLD ++ "piz") != null);
    try t.expect(std.mem.indexOf(u8, wide, ANSI_BOLD ++ "deepseek/flash") != null);
    const wide_plain = try stripForTest(t.allocator, wide);
    defer t.allocator.free(wide_plain);
    try t.expect(std.mem.indexOf(u8, wide_plain, ">_ piz").? < std.mem.indexOf(u8, wide_plain, "model:").?);
    try t.expect(std.mem.indexOf(u8, wide_plain, "model:").? < std.mem.indexOf(u8, wide_plain, "directory:").?);
    try t.expect(std.mem.indexOf(u8, wide_plain, "session:").? < std.mem.indexOf(u8, wide_plain, "/model").?);
    try t.expect(std.mem.indexOf(u8, narrow, "piz") != null);
    try t.expect(cardInner(80) == 56);
    try t.expect(cardInner(40) == 36);
    try t.expect(wide.len != narrow.len);

    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.setFooterIdentity(.{
        .model = info.model,
        .think = info.think,
        .cwd = info.cwd,
        .session = info.session,
        .pct = 12,
    });
    try t.expectEqual(@as(usize, 0), ui.cells.items.len);
    for (ui.cells.items) |c| try t.expect(c.kind != .session_header);

    try ui.appendUser("hi");
    try ui.appendTool("bash", "ls");
    try ui.appendToolEnd("bash", false, "SECRET_BODY\nmore\n");
    try ui.appendStatusCard(.{
        .version = "0.1.0",
        .model = "deepseek/flash",
        .think = "high",
        .cwd = "~/pi-zig",
        .session = "1786735635034",
        .perms = "yolo",
        .context = "AGENTS.md",
        .usage = "12%",
    });
    try t.expect(ui.cells.items[0].kind == .user);
    try t.expect(ui.cells.items[ui.cells.items.len - 1].kind == .status_card);
    try t.expect(cardInner(80) == 56);
    try t.expect(cardInner(8) > 0);
    try t.expect(cardInner(4) == 0);

    const painted = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(painted);
    const plain = try stripForTest(t.allocator, painted);
    defer t.allocator.free(plain);
    const card_at = std.mem.indexOf(u8, plain, "╭");
    const tool_at = std.mem.indexOf(u8, plain, "    ▸ bash  ls");
    try t.expect(card_at != null);
    try t.expect(tool_at != null);
    try t.expect(tool_at.? < card_at.?);
    try t.expect(std.mem.indexOf(u8, plain, "model:") != null);
    try t.expect(std.mem.indexOf(u8, plain, "deepseek/flash") != null);
    try t.expect(std.mem.indexOf(u8, plain, "1786735635034") != null);
    try t.expect(std.mem.indexOf(u8, plain, "permissions:") != null);
    try t.expect(std.mem.indexOf(u8, plain, "yolo") != null);
    try t.expect(std.mem.indexOf(u8, plain, "SECRET_BODY") == null);

    const idle = ui.measureBottom(0, false, &.{});
    try t.expect(idle.composer_rows >= 3);
    try t.expect(idle.footer_rows >= 1);
    try t.expect(idle.height() < 24);
    try t.expectEqual(@as(usize, 1), composerTopRow(0, idle));
    try t.expectEqual(@as(usize, 0), idle.working_rows);
    ui.toggleTools();
    const still = ui.measureBottom(2, true, &.{});
    try t.expectEqual(@as(usize, 1), still.working_rows);
    try t.expectEqual(idle.composer_rows, still.composer_rows);
    try t.expectEqual(idle.footer_rows, still.footer_rows);
}

test "welcome card renders two columns at 100 cols" {
    const t = std.testing;
    const a = t.allocator;
    const info = tui.WelcomeInfo{
        .version = "0.1.0",
        .model = "deepseek/flash",
        .provider = "deepseek",
        .recents = &.{
            .{ .title = "refactor session store", .when = "2d · 8t" },
            .{ .title = "fix login flow", .when = "5d · 3t" },
        },
        .tip = "piz -c 续载上次会话",
    };
    const out = try tui.formatWelcomeCard(a, info, 100);
    defer a.free(out);
    try t.expect(std.mem.indexOf(u8, out, "╭") != null);
    try t.expect(std.mem.indexOf(u8, out, "╰") != null);
    try t.expect(std.mem.indexOf(u8, out, "┴") != null); // 双栏分隔落到下沿
    try t.expect(std.mem.indexOf(u8, out, "piz") != null);
    try t.expect(std.mem.indexOf(u8, out, "v0.1.0") != null);
    try t.expect(std.mem.indexOf(u8, out, "Welcome back!") != null);
    try t.expect(std.mem.indexOf(u8, out, "█") != null); // logo 块元素
    try t.expect(std.mem.indexOf(u8, out, "Tips") != null);
    try t.expect(std.mem.indexOf(u8, out, "/ for commands") != null);
    try t.expect(std.mem.indexOf(u8, out, "? for shortcuts") != null);
    try t.expect(std.mem.indexOf(u8, out, "! to run bash") != null);
    try t.expect(std.mem.indexOf(u8, out, "@ to embed files") != null);
    try t.expect(std.mem.indexOf(u8, out, "Recent sessions") != null);
    try t.expect(std.mem.indexOf(u8, out, "refactor session store") != null);
    try t.expect(std.mem.indexOf(u8, out, "2d · 8t") != null);
    try t.expect(std.mem.indexOf(u8, out, "deepseek/flash") != null);
    try t.expect(std.mem.indexOf(u8, out, " Tip: ") != null);
    try t.expect(std.mem.indexOf(u8, out, "piz -c 续载上次会话") != null);
    try t.expect(std.mem.indexOf(u8, out, ANSI_BOLD ++ "piz") != null);
    const plain = try stripForTest(a, out);
    defer a.free(plain);
    var it = std.mem.splitScalar(u8, plain, '\n');
    var first: ?[]const u8 = null;
    var n: usize = 0;
    while (it.next()) |line| {
        if (first == null) first = line;
        n += 1;
        try t.expect(visibleCols(line) <= 100);
    }
    // 卡宽 = composerBoxWidth(100) = 99;顶边占满
    try t.expectEqual(@as(usize, 99), visibleCols(first.?));
    try t.expect(n >= 12); // 顶边 + 双栏行 + 底边 + tip

    // 无会话时 Recent sessions 区省略
    const bare = try tui.formatWelcomeCard(a, .{ .version = "0.1.0", .model = "m", .provider = "p" }, 100);
    defer a.free(bare);
    try t.expect(std.mem.indexOf(u8, bare, "Recent sessions") == null);
    try t.expect(std.mem.indexOf(u8, bare, "Tips") != null);
}

test "welcome card degrades to single column at 50 cols" {
    const t = std.testing;
    const a = t.allocator;
    const info = tui.WelcomeInfo{
        .version = "0.1.0",
        .model = "deepseek/flash",
        .provider = "deepseek",
        .recents = &.{.{ .title = "refactor session store", .when = "2d · 8t" }},
        .tip = "!cmd 直跑 shell 并把输出喂给模型;!!cmd 只跑不喂",
    };
    const out = try tui.formatWelcomeCard(a, info, 50);
    defer a.free(out);
    try t.expect(std.mem.indexOf(u8, out, "╭") != null);
    try t.expect(std.mem.indexOf(u8, out, "╰") != null);
    try t.expect(std.mem.indexOf(u8, out, "┴") == null); // 单栏无分隔
    try t.expect(std.mem.indexOf(u8, out, "Welcome back!") != null);
    try t.expect(std.mem.indexOf(u8, out, "deepseek/flash") != null);
    // 窄终端无右栏
    try t.expect(std.mem.indexOf(u8, out, "Tips") == null);
    try t.expect(std.mem.indexOf(u8, out, "Recent sessions") == null);
    // 卡下 tip 仍在
    try t.expect(std.mem.indexOf(u8, out, " Tip: ") != null);
    const plain = try stripForTest(a, out);
    defer a.free(plain);
    var it = std.mem.splitScalar(u8, plain, '\n');
    var first: ?[]const u8 = null;
    while (it.next()) |line| {
        if (first == null) first = line;
        try t.expect(visibleCols(line) <= 50);
    }
    try t.expectEqual(@as(usize, 49), visibleCols(first.?)); // composerBoxWidth(50)

    // 极窄:不画盒也不崩
    const tiny = try tui.formatWelcomeCard(a, info, 12);
    defer a.free(tiny);
    try t.expect(std.mem.indexOf(u8, tiny, "╭") == null);
    try t.expect(std.mem.indexOf(u8, tiny, "Welcome back!") != null);
}

test "welcome header paints via cells and session header replaces it" {
    const t = std.testing;
    const a = t.allocator;
    var ui = try Tui.init(a);
    defer ui.deinit();
    try ui.setWelcomeHeader(.{
        .version = "0.1.0",
        .model = "deepseek/flash",
        .provider = "deepseek",
        .recents = &.{.{ .title = "old thread", .when = "1d · 2t" }},
        .tip = "tip one",
    });
    try t.expectEqual(@as(usize, 1), ui.cells.items.len);
    try t.expectEqual(CellKind.session_header, ui.cells.items[0].kind);
    // 100 列快照:卡在 cells 0 号位,对话在其后(随对话上滚留存)
    try ui.appendUser("hi");
    const painted = try paintCellsForTest(a, &ui, 100);
    defer a.free(painted);
    const plain = try stripForTest(a, painted);
    defer a.free(plain);
    const card_at = std.mem.indexOf(u8, plain, "╭");
    const user_at = std.mem.indexOf(u8, plain, "hi");
    try t.expect(card_at != null);
    try t.expect(user_at != null);
    try t.expect(card_at.? < user_at.?);
    try t.expect(std.mem.indexOf(u8, plain, "Welcome back!") != null);
    try t.expect(std.mem.indexOf(u8, plain, "old thread") != null);
    // 50 列快照:同一 cell 按新宽重画成单栏
    const narrow = try paintCellsForTest(a, &ui, 50);
    defer a.free(narrow);
    const narrow_plain = try stripForTest(a, narrow);
    defer a.free(narrow_plain);
    try t.expect(std.mem.indexOf(u8, narrow_plain, "Welcome back!") != null);
    try t.expect(std.mem.indexOf(u8, narrow_plain, "Tips") == null);
    // 续载会话卡逻辑不受影响:setSessionHeader 覆盖 0 号位,渲染回 session 卡
    try ui.setSessionHeader(.{ .version = "0.1.0", .model = "m", .think = "high", .cwd = "/tmp", .session = "sess" });
    try t.expectEqual(@as(usize, 2), ui.cells.items.len);
    try t.expect(ui.cells.items[0].card.?.welcome == null);
    const swapped = try paintCellsForTest(a, &ui, 100);
    defer a.free(swapped);
    try t.expect(std.mem.indexOf(u8, swapped, "Welcome back!") == null);
    try t.expect(std.mem.indexOf(u8, swapped, "model:") != null);
}

test "working rows are one status plus at most two subagent details" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 0), workingRows(0, false, 0));
    try t.expectEqual(@as(usize, 1), workingRows(0, true, 0));
    try t.expectEqual(@as(usize, 1), workingRows(1, false, 0));
    try t.expectEqual(@as(usize, 2), workingRows(2, true, 1));
    try t.expectEqual(@as(usize, 3), workingRows(8, true, 2));
    // 溢出折叠行:3 个子代理 = 状态 + 2 行 + 1 行 more
    try t.expectEqual(@as(usize, 4), workingRows(8, true, 3));
    try t.expectEqual(@as(usize, 4), workingRows(8, true, 5));
}

test "wrapCursor follows soft-wrapped composer rows" {
    const t = std.testing;
    const pos = wrapCursor("0123456789", 7, 5);
    try t.expectEqual(@as(usize, 1), pos.row);
    try t.expectEqual(@as(usize, 2), pos.col);
    const home = wrapCursor("hello", 0, 80);
    try t.expectEqual(@as(usize, 0), home.row);
    try t.expectEqual(@as(usize, 0), home.col);
}

test "scrollSkip pins to bottom then walks up" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 10), scrollSkip(0, 20, 10));
    try t.expectEqual(@as(usize, 5), scrollSkip(5, 20, 10));
    try t.expectEqual(@as(usize, 0), scrollSkip(10, 20, 10));
    try t.expectEqual(@as(usize, 0), scrollSkip(99, 20, 10));
    try t.expectEqual(@as(usize, 0), scrollSkip(0, 5, 10));
}

test "joinFit drops trailing segments then truncates" {
    const t = std.testing;
    const parts = [_][]const u8{ "aaa", "bbb", "ccc" };
    const a = try joinFit(t.allocator, &parts, "  ", 13);
    defer t.allocator.free(a);
    try t.expectEqualStrings("aaa  bbb  ccc", a);
    const b = try joinFit(t.allocator, &parts, "  ", 10);
    defer t.allocator.free(b);
    try t.expectEqualStrings("aaa  bbb", b);
    const c = try joinFit(t.allocator, &parts, "  ", 2);
    defer t.allocator.free(c);
    try t.expectEqualStrings("aa", c);
    try t.expectEqual(@as(usize, 2), visibleCols("\x1b[2mab"));
}

test "picker moves, confirms, and stays exclusive" {
    const t = std.testing;
    const items = [_]PickerItem{
        .{ .label = "yolo", .hint = "不询问", .value = "yolo" },
        .{ .label = "ask", .hint = "危险工具先问", .value = "ask" },
        .{ .label = "read-only", .value = "read-only" },
    };
    var p = try Picker.init(t.allocator, "permissions", "授权", &items, 0);
    defer p.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), p.sel);
    p.move(1);
    try t.expectEqual(@as(usize, 1), p.sel);
    p.move(10);
    try t.expectEqual(@as(usize, 2), p.sel);
    p.move(-10);
    try t.expectEqual(@as(usize, 0), p.sel);
    p.sel = 1;
    const line = try p.confirmLine(t.allocator);
    defer t.allocator.free(line);
    try t.expectEqualStrings("/permissions ask", line);
    try t.expectEqual(@as(usize, 4), p.displayRows(24));
    try t.expectEqual(@as(usize, 2), p.displayRows(3));
}

test "bottom pane is reserved before transcript" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    ui.width = 80;
    ui.height = 24;
    const idle = ui.measureBottom(0, false, &.{});
    try t.expectEqual(@as(usize, 0), idle.working_rows);
    try t.expectEqual(@as(usize, 3), idle.composer_rows);
    // >=40 列:信息上 composer 顶边,页脚恒单行
    try t.expectEqual(@as(usize, 1), idle.footer_rows);
    try t.expectEqual(@as(usize, 1), idle.footer_ident_rows);
    try t.expect(idle.composer_rows >= 3);
    try t.expect(idle.height() < 24);
    const busy = ui.measureBottom(5, true, &.{});
    try t.expectEqual(@as(usize, 1), busy.working_rows);
    try t.expect(busy.height() > idle.height());
    try t.expect(busy.composer_rows >= 3);
    ui.shortcuts_open = true;
    const help = ui.measureBottom(0, false, &.{});
    try t.expectEqual(@as(usize, 3), help.footer_rows);
    try t.expectEqual(@as(usize, 1), help.footer_ident_rows);
    ui.shortcuts_open = false;
    try ui.setFooterIdentity(.{
        .model = "deepseek/v4-flash",
        .think = "max",
        .cwd = "~/project/pi-zig",
        .session = "1786748577703",
        .used = 12_000,
        .window = 128_000,
        .cache_read = 7_440,
        .prompt = 12_000,
        .tok_in = 4_700,
        .tok_out = 44,
        .tok_cache_r = 7_440,
        .pct = 9,
    });
    const split = ui.measureBottom(0, false, &.{});
    try t.expectEqual(@as(usize, 1), split.footer_ident_rows);
    ui.width = 120;
    const wide = ui.measureBottom(0, false, &.{});
    try t.expectEqual(@as(usize, 1), wide.footer_ident_rows);
    ui.width = 40;
    const narrow = ui.measureBottom(0, false, &.{});
    try t.expectEqual(@as(usize, 1), narrow.footer_ident_rows);
    // <40 列:顶边纯线,页脚维持双行
    ui.width = 39;
    const tiny = ui.measureBottom(0, false, &.{});
    try t.expectEqual(@as(usize, 2), tiny.footer_ident_rows);
}

test "footer format includes ctx occupancy and cache when usage is set" {
    const t = std.testing;
    var ub: [16]u8 = undefined;
    var cb: [48]u8 = undefined;
    var kb: [32]u8 = undefined;
    try t.expectEqualStrings("1.2k", formatTok(&ub, 1200));
    try t.expectEqualStrings("128k", formatTok(&ub, 128_000));
    try t.expectEqualStrings("ctx 12k/128k 9.4%", formatCtx(&cb, 12_000, 128_000, true));
    try t.expectEqualStrings("ctx 9.4%", formatCtx(&cb, 12_000, 128_000, false));
    try t.expectEqualStrings("ctx —", formatCtx(&cb, 0, 0, true));
    // 0.79% 曾截成 0%(整数除法)->"百分比不显示";现一位小数
    try t.expectEqualStrings("ctx 0.8%", formatCtx(&cb, 7_900, 1_000_000, false));
    try t.expectEqualStrings("ctx 7.9k/1M 0.8%", formatCtx(&cb, 7_900, 1_000_000, true));
    try t.expectEqualStrings("cache 62%", formatCache(&kb, 7_440, 12_000, true));
    try t.expectEqualStrings("cached 8.1k", formatCache(&kb, 8100, null, true));
    try t.expectEqualStrings("cache —", formatCache(&kb, null, 100, true));
    try t.expectEqualStrings("—", formatCache(&kb, null, null, false));

    const rows = try formatFooterRows(t.allocator, .{
        .model = "deepseek/v4-flash",
        .think = "max",
        .used = 12_000,
        .window = 128_000,
        .cache_read = 7_440,
        .prompt = 12_000,
        .tok_in = 4_700,
        .tok_out = 44,
        .tok_cache_r = 7_440,
        .pct = 9,
    }, null, 80, true);
    defer rows.deinit(t.allocator);
    const secondary = try stripForTest(t.allocator, rows.secondary);
    defer t.allocator.free(secondary);
    // pi 式:行 2 左 stats 右 model · think
    try t.expect(std.mem.indexOf(u8, secondary, "ctx 9% 12k/128k") != null);
    try t.expect(std.mem.indexOf(u8, secondary, "R7.4k") != null);
    try t.expect(std.mem.indexOf(u8, secondary, "↑4.7k ↓44") != null);
    try t.expect(std.mem.indexOf(u8, secondary, "deepseek/v4-flash · max") != null);

    const unknown = try formatFooterRows(t.allocator, .{
        .model = "x",
        .window = 128_000,
    }, null, 80, true);
    defer unknown.deinit(t.allocator);
    const unk = try stripForTest(t.allocator, unknown.secondary);
    defer t.allocator.free(unk);
    // cache 未知则不缀 R 段
    try t.expect(std.mem.indexOf(u8, unk, " R") == null);
    try t.expect(std.mem.indexOf(u8, unk, "ctx 0% 0/128k") != null);
}

test "slash ranking: prefix then fuzzy then description" {
    const t = std.testing;
    const items = [_]SlashItem{
        .{ .cmd = "/help", .desc = "list commands" },
        .{ .cmd = "/status", .desc = "session model cwd tokens" },
        .{ .cmd = "/model [m]", .desc = "switch model" },
        .{ .cmd = "/memory", .desc = "cross-session memory" },
        .{ .cmd = "/sessions", .desc = "sessions in this dir" },
    };
    var ranks: [8]SlashRank = undefined;
    const st_n = rankSlash(&items, "st", &ranks);
    try t.expect(st_n >= 1);
    try t.expectEqualStrings("status", slashName(items[ranks[0].item].cmd));
    try t.expectEqual(@as(u8, 0), ranks[0].kind);
    var i: usize = 1;
    while (i < st_n) : (i += 1) {
        try t.expect(ranks[i].kind >= ranks[0].kind);
        if (std.mem.eql(u8, slashName(items[ranks[i].item].cmd), "help")) {
            try t.expectEqual(@as(u8, 2), ranks[i].kind);
        }
    }

    const mod_n = rankSlash(&items, "mod", &ranks);
    try t.expect(mod_n >= 1);
    try t.expectEqualStrings("model", slashName(items[ranks[0].item].cmd));

    const all_n = rankSlash(&items, "", &ranks);
    try t.expectEqual(@as(usize, items.len), all_n);
    try t.expectEqualStrings("help", slashName(items[ranks[0].item].cmd));
    try t.expectEqualStrings("sessions", slashName(items[ranks[all_n - 1].item].cmd));

    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    ui.slash_items = &items;
    try ui.input.appendSlice("/st");
    ui.cursor = ui.input.items.len;
    const act = try ui.handleInput("\n");
    try t.expect(act == .submit);
    defer t.allocator.free(act.submit);
    try t.expectEqualStrings("/status", act.submit);

    var ui2 = try Tui.init(t.allocator);
    defer ui2.deinit();
    ui2.slash_items = &items;
    try ui2.input.appendSlice("/mod");
    ui2.cursor = ui2.input.items.len;
    _ = try ui2.handleInput(&.{0x09});
    try t.expectEqualStrings("/model", ui2.input.items);

    var ui3 = try Tui.init(t.allocator);
    defer ui3.deinit();
    ui3.slash_items = &items;
    try ui3.input.appendSlice("/foo");
    ui3.cursor = ui3.input.items.len;
    const unknown = try ui3.handleInput("\n");
    try t.expect(unknown == .submit);
    defer t.allocator.free(unknown.submit);
    try t.expectEqualStrings("/foo", unknown.submit);

    try t.expectEqualStrings("st", slashQuery("/st").?);
    try t.expect(slashQuery("/status extra") == null);
    try t.expect(slashQuery("hello") == null);
}

test "slash empty query lists names and descriptions" {
    const t = std.testing;
    const items = [_]SlashItem{
        .{ .cmd = "/status", .desc = "session model cwd tokens" },
        .{ .cmd = "/model [m]", .desc = "switch model" },
    };
    var ranks: [4]SlashRank = undefined;
    const n = rankSlash(&items, "", &ranks);
    try t.expectEqual(@as(usize, 2), n);
    try t.expect(std.mem.indexOf(u8, items[ranks[0].item].desc, "session") != null);
    try t.expect(std.mem.indexOf(u8, items[ranks[1].item].cmd, "/model") != null);

    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    ui.slash_items = &items;
    try ui.input.append('/');
    ui.width = 80;
    ui.height = 24;
    const bottom = ui.measureBottom(0, false, &.{});
    try t.expect(bottom.slash_rows >= 2);
}

test "measureBottom keeps a 3-row composer above the footer" {
    const t = std.testing;
    const ident = FooterIdent{
        .model = "deepseek/v4-flash",
        .think = "max",
        .cwd = "~/桌面",
        .session = "1786748577703",
        .used = 12_000,
        .window = 128_000,
        .cache_read = 7_440,
        .prompt = 12_000,
        .tok_in = 4_700,
        .tok_out = 44,
        .tok_cache_r = 7_440,
        .pct = 9,
    };
    const widths = [_]usize{ 80, 120 };
    for (widths) |cols| {
        var ui = try Tui.init(t.allocator);
        defer ui.deinit();
        ui.width = cols;
        ui.height = 24;
        try ui.setFooterIdentity(ident);
        const idle = ui.measureBottom(0, false, &.{});
        try t.expect(idle.composer_rows >= 3);
        try t.expect(idle.boxed);
        try t.expect(idle.height() <= 24);
        const top = composerTopRow(0, idle);
        try t.expectEqual(@as(usize, 1), top);
        try t.expect(idle.footer_rows >= 1);

        const busy = ui.measureBottom(5, true, &.{});
        try t.expect(busy.composer_rows >= 3);
        try t.expect(busy.height() <= 24);
        const busy_top = composerTopRow(0, busy);
        try t.expectEqual(@as(usize, 1 + busy.working_rows), busy_top);
    }
}

test "composer box closes and cursor stays on the inner row" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 1), visibleCols("╭"));
    try t.expectEqual(@as(usize, 1), visibleCols("▎"));
    try t.expectEqual(@as(usize, 1), visibleCols("▸"));
    try t.expectEqual(@as(usize, 1), visibleCols("›"));
    try t.expectEqual(@as(usize, 2), visibleCols("桌"));
    try t.expectEqual(@as(usize, 79), composerBoxWidth(80));
    try t.expectEqual(@as(usize, 119), composerBoxWidth(120));

    const widths = [_]usize{ 80, 120 };
    for (widths) |cols| {
        const empty = try paintComposerBox(t.allocator, "", cols, 1, 0);
        defer t.allocator.free(empty);
        try expectComposerClosed(t.allocator, empty, cols);

        const cjk = try paintComposerBox(t.allocator, "在~/桌面写点东西", cols, 1, 0);
        defer t.allocator.free(cjk);
        try expectComposerClosed(t.allocator, cjk, cols);

        var long_buf: [200]u8 = undefined;
        @memset(&long_buf, 'x');
        const wrapped = try paintComposerBox(t.allocator, &long_buf, cols, 3, 0);
        defer t.allocator.free(wrapped);
        try expectComposerClosed(t.allocator, wrapped, cols);

        var ui = try Tui.init(t.allocator);
        defer ui.deinit();
        ui.width = cols;
        ui.height = 24;
        try ui.setFooterIdentity(.{
            .model = "deepseek/v4-flash",
            .think = "max",
            .cwd = "~/桌面",
            .session = "1786748577703",
        });
        const idle = ui.measureBottom(0, false, &.{});
        const cur = wrapCursor(ui.input.items, ui.cursor, idle.input_inner);
        const top = composerTopRow(0, idle);
        const row = composerInputRow(top, idle, cur.row);
        try t.expect(row >= top + 1);
        try t.expect(row <= top + idle.comp_inner);
        try t.expect(row < top + idle.composer_rows);

        try ui.input.appendSlice(&long_buf);
        ui.cursor = ui.input.items.len;
        const grown = ui.measureBottom(0, false, &.{});
        const cur2 = wrapCursor(ui.input.items, ui.cursor, grown.input_inner);
        const top2 = composerTopRow(0, grown);
        const row2 = composerInputRow(top2, grown, cur2.row);
        try t.expect(grown.composer_rows >= 3);
        try t.expect(row2 >= top2 + 1);
        try t.expect(row2 <= top2 + grown.comp_inner);
    }
}

test "user and tool rows carry semantic bg bands; folded tail" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendUser("帮我看下这个 bug");
    try ui.appendText("某去查日志。");
    try ui.appendTool("read", "src/main.zig");
    try ui.appendToolEnd("read", false, "one\ntwo\nthree\nfour\nfive");
    const out = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(out);
    // user 整行色带 + tool title 状态色带 + 折叠尾行
    try t.expect(std.mem.indexOf(u8, out, theme.bgUser()) != null);
    try t.expect(std.mem.indexOf(u8, out, theme.bgTool(.ok)) != null);
    try t.expect(std.mem.indexOf(u8, out, "3 more lines, ctrl+o") != null);
    const plain = try stripForTest(t.allocator, out);
    defer t.allocator.free(plain);
    try t.expect(std.mem.indexOf(u8, plain, "    · (3 more lines, ctrl+o)") != null);
    // err 态色带
    var ui2 = try Tui.init(t.allocator);
    defer ui2.deinit();
    try ui2.appendTool("bash", "ls");
    try ui2.appendToolEnd("bash", true, "missing\n");
    const out2 = try paintCellsForTest(t.allocator, &ui2, 80);
    defer t.allocator.free(out2);
    try t.expect(std.mem.indexOf(u8, out2, theme.bgTool(.err)) != null);
    // 无色系:无色带、无补白,行为如旧
    const saved_mode = theme.mode;
    defer theme.mode = saved_mode;
    theme.mode = .none;
    emit.attachTheme(theme);
    const out3 = try paintCellsForTest(t.allocator, &ui2, 80);
    defer t.allocator.free(out3);
    try t.expect(std.mem.indexOf(u8, out3, "\x1b[48;") == null);
    try t.expect(std.mem.indexOf(u8, out3, "\x1b[31m") != null);
}

test "footer shows (sub) for subscription provider without cost" {
    const t = std.testing;
    const rows = try formatFooterRows(t.allocator, .{
        .model = "codex/gpt-5.4",
        .cwd = "~/x",
        .window = 272_000,
        .subscription = true,
    }, null, 80, true);
    defer rows.deinit(t.allocator);
    const s = try stripForTest(t.allocator, rows.secondary);
    defer t.allocator.free(s);
    // 订阅制:cost 为零亦显 $,缀 (sub)
    try t.expect(std.mem.indexOf(u8, s, "$0.000 (sub)") != null);
}

test "assistant markdown strips markers and uses theme colors" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendText("# Hello\n- item `x`");
    const out = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, theme.fg_md_heading) != null);
    try t.expect(std.mem.indexOf(u8, out, theme.fg_md_code) != null);
    const plain = try stripForTest(t.allocator, out);
    defer t.allocator.free(plain);
    try t.expect(std.mem.indexOf(u8, plain, "Hello") != null);
    try t.expect(std.mem.indexOf(u8, plain, "# Hello") == null);
    try t.expect(std.mem.indexOf(u8, plain, "• item x") != null);
}

test "example theme json loads and paint keeps code color" {
    const t = std.testing;
    var th = Theme{};
    const dark_json = try std.Io.Dir.cwd().readFileAlloc(util.io, "themes/dark.json", t.allocator, .limited(16 * 1024));
    defer t.allocator.free(dark_json);
    try t.expect(theme_mod.applyJson(&th, dark_json));
    try t.expectEqual(@as(u8, 0x34), th.pal.user_bg.r);
    const light_json = try std.Io.Dir.cwd().readFileAlloc(util.io, "themes/light.json", t.allocator, .limited(16 * 1024));
    defer t.allocator.free(light_json);
    var light = Theme{};
    try t.expect(theme_mod.applyJson(&light, light_json));
    try t.expectEqual(@as(u8, 0xe8), light.pal.user_bg.r);

    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendText("- item `xyz`");
    const out = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, theme.fg_md_code) != null);
    const plain = try stripForTest(t.allocator, out);
    defer t.allocator.free(plain);
    try t.expect(std.mem.indexOf(u8, plain, "• item xyz") != null);
}

test "workflow rail updates in place and swallows sub events" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendWorkflow("{\"goal\":\"Review pending changes\",\"nodes\":[{\"id\":\"changes\",\"role\":\"scout\"},{\"id\":\"tests\",\"role\":\"worker\"},{\"id\":\"review\",\"role\":\"reviewer\"}]}");
    try t.expect(ui.applyFlowEvent(1, "notice", "changes"));
    try t.expect(ui.applyFlowEvent(1, "tool_start", "git status"));
    try t.expect(ui.applyFlowEvent(1, "finished", ""));
    try t.expect(ui.applyFlowEvent(2, "notice", "tests"));
    try t.expect(ui.applyFlowEvent(2, "tool_start", "bash"));
    const live = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(live);
    try t.expect(std.mem.indexOf(u8, live, "Review pending changes") != null);
    try t.expect(std.mem.indexOf(u8, live, "changes") != null);
    try t.expect(std.mem.indexOf(u8, live, "tests") != null);
    try t.expect(std.mem.indexOf(u8, live, "review") != null);
    try t.expect(std.mem.indexOf(u8, live, "bash") != null);
    try t.expect(std.mem.indexOf(u8, live, "[sub ") == null);
    try t.expect(std.mem.indexOf(u8, live, "│") == null);
    try ui.appendToolEnd("workflow", false, "Workflow \"Review pending changes\" — 3/3 ok [1s]\n\n=== changes (scout) ok ===\ndiff\n\n=== tests (worker) ok ===\npass\n\n=== review (reviewer) ok ===\nlgtm\n");
    const done = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(done);
    try t.expect(std.mem.indexOf(u8, done, "3/3") != null);
    try t.expect(std.mem.indexOf(u8, done, "lgtm") == null);
    try t.expect(!ui.applyFlowEvent(3, "notice", "review"));
}

test "findNext jumps between matching cells" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendUser("alpha one");
    try ui.appendUser("beta two");
    try ui.appendUser("alpha three");
    try t.expect(try ui.findNext("alpha", false));
    try t.expectEqual(@as(usize, 0), ui.search_hit.?);
    try t.expect(ui.cells.items[0].hl);
    try t.expect(try ui.findNext("alpha", false));
    try t.expectEqual(@as(usize, 2), ui.search_hit.?);
    try t.expect(!ui.cells.items[0].hl);
    try t.expect(ui.cells.items[2].hl);
    try t.expect(try ui.findNext("alpha", false));
    try t.expectEqual(@as(usize, 0), ui.search_hit.?);
    try t.expect(!try ui.findNext("zzz", false));
}

test "n repeats last find when composer empty" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendUser("alpha one");
    try ui.appendUser("beta two");
    try ui.appendUser("alpha three");
    try t.expect(try ui.findNext("alpha", false));
    try t.expectEqual(@as(usize, 0), ui.search_hit.?);
    _ = try ui.handleInput("n");
    try t.expectEqual(@as(usize, 2), ui.search_hit.?);
    _ = try ui.handleInput("n");
    try t.expectEqual(@as(usize, 0), ui.search_hit.?);
}

test "cellRowCountCached reuses count at same width" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendUser("hello cache");
    const a = cellRowCountCached(t.allocator, &ui.cells.items[0], "", false, 80);
    try t.expect(ui.cells.items[0].row_valid);
    const b = cellRowCountCached(t.allocator, &ui.cells.items[0], "", false, 80);
    try t.expectEqual(a, b);
    _ = cellRowCountCached(t.allocator, &ui.cells.items[0], "", false, 40);
    try t.expectEqual(@as(usize, 40), ui.cells.items[0].row_w);
}

test "tui prunes old cells and keeps session header" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.setSessionHeader(.{ .version = "0", .model = "m", .think = "high", .cwd = "/tmp", .session = "sess" });
    var i: usize = 0;
    while (i < 460) : (i += 1) try ui.appendUser("x");
    try t.expect(ui.cells.items.len <= 400);
    try t.expect(ui.cells.items.len > 0);
    try t.expectEqual(CellKind.session_header, ui.cells.items[0].kind);
    try t.expect(!ui.hasPendingImage());
    try t.expect(ui.find_log.items.len > 0);
    const hit = try ui.findNext("x", false);
    try t.expect(hit);
}

test "status indicator: retry mark and subagent overflow fold" {
    const t = std.testing;
    const activity = @import("core").activity;
    var views: [5]activity.View = undefined;
    // 3 个 subagent:2 行 + 1 行折叠;attempt=3 的 http 应标 retry 2
    views[0] = .{ .kind = .http, .name = "model", .detail = "", .elapsed_ms = 5000, .bytes = 0, .attempt = 3, .limit_ms = 0, .detached = false };
    views[1] = .{ .kind = .subagent, .name = "worker1", .detail = "bash", .elapsed_ms = 4200, .bytes = 0, .attempt = 0, .limit_ms = 0, .detached = false };
    views[2] = .{ .kind = .subagent, .name = "worker2", .detail = "", .elapsed_ms = 3100, .bytes = 0, .attempt = 0, .limit_ms = 0, .detached = false };
    views[3] = .{ .kind = .subagent, .name = "worker3", .detail = "", .elapsed_ms = 2000, .bytes = 0, .attempt = 0, .limit_ms = 0, .detached = false };
    var fw = std.Io.Writer.Allocating.init(t.allocator);
    defer fw.deinit();
    try draw.writeStatusIndicator(&fw.writer, views[0..4], false, 0, 100, 4);
    const out = fw.written();
    try t.expect(std.mem.indexOf(u8, out, "retry 2") != null);
    try t.expect(std.mem.indexOf(u8, out, "worker1") != null);
    try t.expect(std.mem.indexOf(u8, out, "worker2") != null);
    try t.expect(std.mem.indexOf(u8, out, "+1 more") != null);
    try t.expect(std.mem.indexOf(u8, out, "· 4.2s") != null);
    try t.expect(std.mem.indexOf(u8, out, "worker3") == null);
    // 2 个 subagent(rows=3):无折叠行
    var fw2 = std.Io.Writer.Allocating.init(t.allocator);
    defer fw2.deinit();
    try draw.writeStatusIndicator(&fw2.writer, views[1..3], false, 0, 100, 3);
    const out2 = fw2.written();
    try t.expect(std.mem.indexOf(u8, out2, "+1 more") == null);
    try t.expect(std.mem.indexOf(u8, out2, "worker2") != null);
    // writeActivityLine(/jobs 行):subagent 显示真名,不写死 "agent"
    var fw3 = std.Io.Writer.Allocating.init(t.allocator);
    defer fw3.deinit();
    try draw.writeActivityLine(&fw3.writer, views[1], 0, 100);
    const out3 = fw3.written();
    try t.expect(std.mem.indexOf(u8, out3, "worker1") != null);
    try t.expect(std.mem.indexOf(u8, out3, "agent") == null);
}
// —— boxed 工具卡(W2 omp 对齐):展开 ╭─╮/│/╰─╯,折叠一行不变,窄屏退化 ——

test "boxed tool card: expanded snapshot at 100 cols" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendTool("bash", "echo hello && ls");
    try ui.appendToolEnd("bash", false, "hello\nMakefile\nsrc\n");
    ui.toggleTools();
    try t.expect(!ui.cells.items[0].tool.?.folded);
    const out = try paintCellsForTest(t.allocator, &ui, 100);
    defer t.allocator.free(out);
    const plain = try stripForTest(t.allocator, out);
    defer t.allocator.free(plain);
    var it = std.mem.splitScalar(u8, plain, '\n');
    // 顶边:╭─ name · preview ─ status ─╮(status 含 ok + 耗时 + Nln)
    const top = it.next() orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.startsWith(u8, top, "╭─ bash"));
    try t.expect(std.mem.indexOf(u8, top, "· echo hello && ls") != null);
    try t.expect(std.mem.indexOf(u8, top, "ok") != null);
    try t.expect(std.mem.indexOf(u8, top, "3ln") != null);
    try t.expect(std.mem.endsWith(u8, top, "─╮"));
    // 正文:│ … │,左右边框齐
    const b1 = it.next() orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.startsWith(u8, b1, "│ hello"));
    try t.expect(std.mem.endsWith(u8, b1, " │"));
    const b3 = it.next() orelse return error.TestUnexpectedResult; // Makefile 行跳过,直接第三行
    _ = b3;
    // 底边:╰─ Wall … · 3ln ─╯
    var bottom: []const u8 = "";
    while (it.next()) |ln| {
        if (ln.len > 0) bottom = ln;
    }
    try t.expect(std.mem.startsWith(u8, bottom, "╰─ Wall"));
    try t.expect(std.mem.indexOf(u8, bottom, "3ln") != null);
    try t.expect(std.mem.endsWith(u8, bottom, "─╯"));
    // 列纪律:剥码后每行 ≤ 100 列(盒宽 99 + 色带补白 1)
    var rit = std.mem.splitScalar(u8, plain, '\n');
    while (rit.next()) |ln| {
        if (ln.len == 0) continue;
        try t.expect(visibleCols(ln) <= 100);
    }
    // 状态色带与边框色(ok)仍在
    try t.expect(std.mem.indexOf(u8, out, theme.bgTool(.ok)) != null);
}

test "folded tool card stays one line, never boxed" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendTool("bash", "ls");
    try ui.appendToolEnd("bash", false, "a\nb\nc\nd\ne\n");
    const out = try paintCellsForTest(t.allocator, &ui, 100);
    defer t.allocator.free(out);
    const plain = try stripForTest(t.allocator, out);
    defer t.allocator.free(plain);
    try t.expect(std.mem.indexOf(u8, plain, "╭") == null);
    try t.expect(std.mem.indexOf(u8, plain, "╰") == null);
    try t.expect(std.mem.indexOf(u8, plain, "    ▸ bash  ls") != null);
    try t.expect(std.mem.indexOf(u8, plain, "    · (3 more lines, ctrl+o)") != null);
    try t.expect(countNonEmptyLines(plain) <= 2);
}

test "narrow terminal degrades box to gutter (<40 cols)" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    try ui.appendTool("bash", "ls");
    try ui.appendToolEnd("bash", false, "one\ntwo\n");
    ui.toggleTools();
    const out = try paintCellsForTest(t.allocator, &ui, 39);
    defer t.allocator.free(out);
    const plain = try stripForTest(t.allocator, out);
    defer t.allocator.free(plain);
    // 不画盒:gutter 形 │/└ 保留,不画崩
    try t.expect(std.mem.indexOf(u8, plain, "╭") == null);
    try t.expect(std.mem.indexOf(u8, plain, "      │ one") != null);
    try t.expect(std.mem.indexOf(u8, plain, "      └ two") != null);
    var rit = std.mem.splitScalar(u8, plain, '\n');
    while (rit.next()) |ln| {
        if (ln.len == 0) continue;
        try t.expect(visibleCols(ln) <= 39);
    }
}

test "boxed body truncates past 20 lines with tail row" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    var body = std.array_list.Managed(u8).init(t.allocator);
    defer body.deinit();
    var i: usize = 1;
    while (i <= 30) : (i += 1) {
        var lb: [16]u8 = undefined;
        try body.appendSlice(std.fmt.bufPrint(&lb, "line{d:0>2}\n", .{i}) catch "line?\n");
    }
    try ui.appendTool("bash", "seq 30");
    try ui.appendToolEnd("bash", false, body.items);
    ui.toggleTools();
    // 行数:顶 1 + 19 正文 + 1 截断尾行 + 底 1 = 22
    try t.expectEqual(@as(usize, 22), emit.toolRowCount(ui.cells.items[0].tool.?, 80));
    const out = try paintCellsForTest(t.allocator, &ui, 80);
    defer t.allocator.free(out);
    const plain = try stripForTest(t.allocator, out);
    defer t.allocator.free(plain);
    try t.expect(std.mem.indexOf(u8, plain, "line19") != null);
    try t.expect(std.mem.indexOf(u8, plain, "line20") == null);
    try t.expect(std.mem.indexOf(u8, plain, "… (11 more lines)") != null);
}

test "bang result rides the boxed tool card, preview-matched finish" {
    const t = std.testing;
    var ui = try Tui.init(t.allocator);
    defer ui.deinit();
    // 并发两张同名 "!" 卡:appendToolEndMatch 按 cmd 认卡
    try ui.appendTool("!", "echo one");
    try ui.appendTool("!", "echo two");
    try ui.appendToolEndMatch("!", "echo two", false, "two\n");
    try t.expect(ui.cells.items[0].tool.?.status == .running);
    try t.expect(ui.cells.items[1].tool.?.status == .ok);
    try t.expectEqual(@as(usize, 1), ui.cells.items[1].tool.?.lines);
    try ui.appendToolEndMatch("!", "echo one", true, "boom\n");
    try t.expect(ui.cells.items[0].tool.?.status == .err);
    // 折叠态:一行 ▸ ! cmd status(不动)
    const folded = try paintCellsForTest(t.allocator, &ui, 100);
    defer t.allocator.free(folded);
    const fplain = try stripForTest(t.allocator, folded);
    defer t.allocator.free(fplain);
    try t.expect(std.mem.indexOf(u8, fplain, "    ▸ !  echo two") != null);
    try t.expect(std.mem.indexOf(u8, fplain, "two") != null);
    try t.expect(std.mem.indexOf(u8, fplain, "╭") == null);
    // 展开态:bang 输出进盒
    ui.toggleTools();
    const out = try paintCellsForTest(t.allocator, &ui, 100);
    defer t.allocator.free(out);
    const plain = try stripForTest(t.allocator, out);
    defer t.allocator.free(plain);
    try t.expect(std.mem.indexOf(u8, plain, "╭─ ! · echo two") != null);
    try t.expect(std.mem.indexOf(u8, plain, "│ two") != null);
    try t.expect(std.mem.indexOf(u8, plain, "│ boom") != null);
    try t.expect(std.mem.indexOf(u8, plain, "╰─ Wall") != null);
}

test "composer top edge embeds model dir cost ctx at 100 cols" {
    const t = std.testing;
    const a = t.allocator;
    const ident = FooterIdent{
        .model = "deepseek/v4-flash",
        .think = "max",
        .cwd = "~/project/pi-zig",
        .branch = "main*",
        .session = "1786748577703",
        .used = 12_000,
        .window = 128_000,
        .cost = 0.009,
        .pct = 9,
    };
    var aw = std.Io.Writer.Allocating.init(a);
    defer aw.deinit();
    try footer.writeComposerTopEdge(&aw.writer, ident, composerBoxWidth(100));
    const stripped = try stripForTest(a, aw.written());
    defer a.free(stripped);
    const line = std.mem.trimEnd(u8, stripped, "\n");
    // omp 形:╭── model · think ── cwd ↳ branch ── $cost · ctx% (u/w) ──╮
    try t.expect(std.mem.startsWith(u8, line, "╭── deepseek/v4-flash · max"));
    try t.expect(std.mem.endsWith(u8, line, "─╮"));
    try t.expect(std.mem.indexOf(u8, line, "~/project/pi-zig ↳ main*") != null);
    try t.expect(std.mem.indexOf(u8, line, "$0.01 · ctx 9% (12k/128k)") != null);
    try t.expectEqual(composerBoxWidth(100), visibleCols(line));
    // 无成本数据(定价缺失):省略 $cost,ctx 仍在,盒仍闭合等宽
    var nocost = ident;
    nocost.cost = null;
    var aw2 = std.Io.Writer.Allocating.init(a);
    defer aw2.deinit();
    try footer.writeComposerTopEdge(&aw2.writer, nocost, composerBoxWidth(100));
    const stripped2 = try stripForTest(a, aw2.written());
    defer a.free(stripped2);
    const line2 = std.mem.trimEnd(u8, stripped2, "\n");
    try t.expect(std.mem.indexOf(u8, line2, "$") == null);
    try t.expect(std.mem.indexOf(u8, line2, "ctx 9% (12k/128k)") != null);
    try t.expectEqual(composerBoxWidth(100), visibleCols(line2));
}

test "composer top edge degrades: <60 model+ctx only, <39 pure line" {
    const t = std.testing;
    const a = t.allocator;
    const ident = FooterIdent{
        .model = "deepseek/v4-flash",
        .think = "max",
        .cwd = "~/project/pi-zig",
        .branch = "main*",
        .used = 12_000,
        .window = 128_000,
        .cost = 0.009,
        .pct = 9,
    };
    // 56 列终端(box_w 55):只 model + ctx%,think/branch/cost 不上边
    var aw = std.Io.Writer.Allocating.init(a);
    defer aw.deinit();
    try footer.writeComposerTopEdge(&aw.writer, ident, composerBoxWidth(56));
    const s56 = try stripForTest(a, aw.written());
    defer a.free(s56);
    const l56 = std.mem.trimEnd(u8, s56, "\n");
    try t.expect(std.mem.indexOf(u8, l56, "deepseek/v4-flash") != null);
    try t.expect(std.mem.indexOf(u8, l56, "ctx 9%") != null);
    try t.expect(std.mem.indexOf(u8, l56, "max") == null);
    try t.expect(std.mem.indexOf(u8, l56, "↳") == null);
    try t.expect(std.mem.indexOf(u8, l56, "$") == null);
    try t.expectEqual(composerBoxWidth(56), visibleCols(l56));
    // 40 列终端(box_w 39):最小信息条,长模型也不丢 model、不画崩
    var long = ident;
    long.model = "deepseek/v4-flash-vision-exp";
    var aw2 = std.Io.Writer.Allocating.init(a);
    defer aw2.deinit();
    try footer.writeComposerTopEdge(&aw2.writer, long, composerBoxWidth(40));
    const s40 = try stripForTest(a, aw2.written());
    defer a.free(s40);
    const l40 = std.mem.trimEnd(u8, s40, "\n");
    try t.expect(std.mem.indexOf(u8, l40, "deepseek/v4-flash-vision-exp") != null);
    try t.expect(std.mem.endsWith(u8, l40, "╮"));
    try t.expectEqual(composerBoxWidth(40), visibleCols(l40));
    // 39 列终端(box_w 38):纯线,信息留页脚双行
    var aw3 = std.Io.Writer.Allocating.init(a);
    defer aw3.deinit();
    try footer.writeComposerTopEdge(&aw3.writer, ident, composerBoxWidth(39));
    const s39 = try stripForTest(a, aw3.written());
    defer a.free(s39);
    const l39 = std.mem.trimEnd(u8, s39, "\n");
    try t.expect(std.mem.indexOf(u8, l39, "deepseek") == null);
    try t.expect(std.mem.indexOf(u8, l39, "ctx") == null);
    try t.expectEqual(composerBoxWidth(39), visibleCols(l39));
}

test "footer is one row at >=40 cols: host identity left, hint right" {
    const t = std.testing;
    const a = t.allocator;
    const ident = FooterIdent{
        .model = "deepseek/v4-flash",
        .think = "max",
        .cwd = "~/project/pi-zig",
        .branch = "main*",
        .session = "1786748577703",
        .used = 12_000,
        .window = 128_000,
        .pct = 9,
    };
    var ui = try Tui.init(a);
    defer ui.deinit();
    ui.width = 100;
    ui.height = 34;
    try ui.setFooterIdentity(ident);
    const bottom = ui.measureBottom(0, false, &.{});
    try t.expectEqual(@as(usize, 1), bottom.footer_ident_rows);
    try t.expectEqual(@as(usize, 1), bottom.footer_rows);
    const rows = try formatFooterRows(a, ident, "? for shortcuts", 100, bottom.footer_ident_rows >= 2);
    defer rows.deinit(a);
    const primary = try stripForTest(a, rows.primary);
    defer a.free(primary);
    // host 身份 + hint;model/ctx 已上顶边,不重复
    try t.expect(std.mem.indexOf(u8, primary, "~/project/pi-zig (main*) · 1786748577703") != null);
    try t.expect(std.mem.indexOf(u8, primary, "? for shortcuts") != null);
    try t.expect(std.mem.indexOf(u8, primary, "deepseek") == null);
    try t.expect(std.mem.indexOf(u8, primary, "ctx") == null);
    try t.expectEqualStrings("", rows.secondary);
}
