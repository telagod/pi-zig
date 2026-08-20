// git-awareness —— git_status 工具 + /git(git status --short + diff --stat)。
// 内嵌出厂件,默认关,同名覆写。与原 Zig 版同则:exit≠0 → null(非仓/无 git 报 error),输出截 64KB。
function gitStatus() {
  const st = piz.exec(["git", "status", "--short"]);
  if (st == null) return null;
  const df = piz.exec(["git", "diff", "--stat"]);
  return "Git status:\n" + st + (df == null ? "" : df);
}

piz.registerTool({
  name: "git_status",
  description: "Show git status and diff stat for the working tree.",
  parameters: {},
  execute() {
    const s = gitStatus();
    if (s == null) return { error: "not a git repo or git unavailable" };
    return { content: s };
  },
});

piz.registerCommand("git", {
  description: "git status + diffstat",
  handler() {
    const s = gitStatus();
    return s == null ? "not a git repo or git unavailable" : s;
  },
});
