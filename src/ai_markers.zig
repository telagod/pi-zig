// ai_markers.zig — provider 漏进正文的工具调用标记。只在此维护。
const std = @import("std");

/// Provider 漏进正文的工具调用标记。agent 经 textToolCallMarker 查询。
pub const TEXT_MARKERS = [_][]const u8{
    "<｜｜DSML｜｜",
    "<|DSML|>",
    "<｜tool▁calls▁begin｜>",
    "<|tool_calls_begin|>",
};

/// 伪造工具调用标记的起始下标。同时匹配**前缀** —— 标记可能刚开始流,
/// 后半截还在下个 chunk 里,那时也必须立刻闭嘴。
pub fn textMarkerStart(text: []const u8) ?usize {
    var best: ?usize = null;
    for (TEXT_MARKERS) |m| {
        if (std.mem.indexOf(u8, text, m)) |i| {
            if (best == null or i < best.?) best = i;
            continue;
        }
        const max = @min(m.len - 1, text.len);
        var n = max;
        while (n > 0) : (n -= 1) {
            if (std.mem.eql(u8, text[text.len - n ..], m[0..n])) {
                const i = text.len - n;
                if (best == null or i < best.?) best = i;
                break;
            }
        }
    }
    return best;
}

pub fn textToolCallMarker(text: []const u8) ?[]const u8 {
    for (TEXT_MARKERS) |m| {
        if (std.mem.indexOf(u8, text, m) != null) return m;
    }
    return null;
}

test "textToolCallMarker finds leaked markers and ignores ascii pipe" {
    const t = std.testing;
    try t.expect(textToolCallMarker("hello") == null);
    try t.expect(textToolCallMarker("pipe | char") == null);
    try t.expect(textToolCallMarker("<|DSML|>invoke") != null);
    try t.expect(textToolCallMarker("<|tool_calls_begin|>") != null);
}
