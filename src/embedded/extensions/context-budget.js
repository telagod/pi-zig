// context-budget —— context 余量查询。内嵌出厂件,默认关,同名覆写。
// 快照由桥在 callTool/runCommand 进入时设(piz.contextStats()),数字口径与原 plugins.zig 版一致。
// 文案与原 Zig 版逐字节同式。
function fmt(s) {
  return "Context budget: window " + s.window + " tokens, used ~" + s.used +
    " (of which ~" + s.tools_share + " is the fixed tool definitions), remaining ~" + s.remaining +
    ". Auto-compaction triggers at " + s.hard_pct + "% (" + s.limit +
    " tokens) — ~" + s.until_compact + " tokens of headroom before that.";
}

piz.registerTool({
  name: "get_context_remaining",
  description: "Report remaining context budget in tokens.",
  parameters: {},
  execute() {
    const s = piz.contextStats();
    if (!s) return { error: "context stats unavailable" };
    return { content: fmt(s) };
  },
});

piz.registerCommand("context", {
  description: "context budget remaining",
  handler() {
    const s = piz.contextStats();
    return s ? fmt(s) : "context stats unavailable";
  },
});
