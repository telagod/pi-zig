// concept-graph —— 压缩摘要中提取事实行(decision/constraint/goal 等),
// 追加 <configDir>/concepts/<cwd-slug>.md,跨会话项目知识沉淀。内嵌出厂件,默认开,同名覆写。
const FACT_MARKERS = ["decision:", "decided", "constraint:", "goal:", "convention:", "architecture:"];

function cwdSlug(cwd) {
  let rest = String(cwd || "");
  if (rest[0] === "/") rest = rest.slice(1);
  return "--" + rest.replace(/\//g, "-") + "--";
}

piz.on("compact", (e) => {
  const dir = e && e.config_dir;
  if (!dir) return;
  let facts = "";
  for (const line of String(e.summary || "").split("\n")) {
    const l = line.trim();
    if (!l) continue;
    const low = l.toLowerCase();
    for (const mk of FACT_MARKERS) {
      if (low.startsWith(mk)) { facts += l + "\n"; break; }
    }
  }
  if (!facts) return;
  piz.appendFile(dir + "/concepts/" + cwdSlug(e.cwd) + ".md", facts);
});
