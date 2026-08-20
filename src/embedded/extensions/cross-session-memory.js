// cross-session-memory —— 压缩摘要落盘,跨会话注入。内嵌出厂件,默认开,同名覆写。
// 写 <configDir>/memories/<cwd-slug>.md(覆写,单条最新);启动注入在核(injectMemory,只读)。
// slug:"--" + cwd 去首斜杠、余斜杠换 '-' + "--"(与 util.cwdSlug 同式)。
function cwdSlug(cwd) {
  let rest = String(cwd || "");
  if (rest[0] === "/") rest = rest.slice(1);
  return "--" + rest.replace(/\//g, "-") + "--";
}

piz.on("compact", (e) => {
  const dir = e && e.config_dir;
  if (!dir) return;
  const summary = String(e.summary || "");
  const clipped = summary.length > 2048 ? summary.slice(0, 2048) : summary;
  piz.writeFile(dir + "/memories/" + cwdSlug(e.cwd) + ".md",
    "## [" + Math.trunc(Number(e.ts) || 0) + "] " + (e.cwd || "") + "\n" + clipped + "\n\n");
});
