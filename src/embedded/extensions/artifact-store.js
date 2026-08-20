// artifact-store —— 大工具输出外置:>4KB 落 <configDir>/artifacts/<ms>-<tool>.txt,
// 会话里只留 400 字节预览 + 路径(模型可 bash cat 取全量)。内嵌出厂件,默认开,
// 同名覆写;/plugins off artifact-store 可关(gate 门控)。
// 与原 Zig 版同则:read/read_image 自裁 16KB,再外置会死循环 —— 跳过;
// 已含 [Artifact stored: 标记的不重复外置。
const THRESHOLD = 4 * 1024;

// 字节长度(UTF-8):阈值与字节数皆按字节,与原 Zig 版同口径。
function byteLen(s) {
  let n = 0;
  for (const ch of s) {
    const cp = ch.codePointAt(0);
    n += cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
  }
  return n;
}

// clampUtf8:切在多字节中间会产出非法 UTF-8,JSON 化时静默退化成整数数组,
// provider 直接 400 —— 预览必须退到字符边界(与原 Zig 版同)。
function clampUtf8(s, max) {
  let bytes = 0;
  let i = 0;
  for (const ch of s) {
    const cp = ch.codePointAt(0);
    bytes += cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
    if (bytes > max) break;
    i += ch.length;
  }
  return s.slice(0, i);
}

piz.on("tool_result", (e) => {
  const name = (e && e.toolName) || "";
  if (name === "read" || name === "read_image") return undefined;
  const content = String((e && e.output) || "");
  if (content.indexOf("[Artifact stored:") >= 0) return undefined;
  const blen = byteLen(content);
  if (blen <= THRESHOLD) return undefined;
  const dir = piz.configDir();
  if (!dir) return undefined;
  const fpath = dir + "/artifacts/" + Date.now() + "-" + name + ".txt";
  if (!piz.writeFile(fpath, content)) return undefined;
  return { replace: "[Artifact stored: " + fpath + " (" + blen + " bytes)]\n" +
    clampUtf8(content, 400) + "\n...(truncated; read the artifact file for full content)" };
});
