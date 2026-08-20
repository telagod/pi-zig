// usage-ledger —— 每轮 token 记账:追加 <config_dir>/usage.jsonl,一行一轮。
// 内嵌出厂件(嵌入 src/embedded/extensions/,随二进制);在 ~/.piz/extensions/
// 或 <项目>/.piz/extensions/ 放同名 usage-ledger.js 即覆写本件。
// 无 usage 的空转不记;不记 API key,只记量。
piz.on("agent_end", (e) => {
  const u = e && e.usage;
  if (!u) return;
  const dir = e.config_dir;
  if (!dir) return;
  const q = (s) => JSON.stringify(String(s == null ? "" : s));
  const line = '{"ts":' + Math.trunc(Number(e.ts) || 0) +
    ',"model":' + q(e.model) +
    ',"in":' + Math.trunc(Number(u.in) || 0) +
    ',"out":' + Math.trunc(Number(u.out) || 0) +
    ',"cr":' + Math.trunc(Number(u.cr) || 0) +
    ',"cw":' + Math.trunc(Number(u.cw) || 0) +
    ',"usd":' + Number(u.usd || 0).toFixed(8) +
    ',"cwd":' + q(e.cwd) + '}\n';
  piz.appendFile(dir + "/usage.jsonl", line);
});
