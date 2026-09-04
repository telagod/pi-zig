// util.ts —— 纯工具:DOM 取值、转义、格式化、工具分类、斜杠打分。
// 自 webui.js 切出,一律无闭包态;名与义一字未改。
export const $ = (id: string) => document.getElementById(id);
export const esc = (s: any) =>
  String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
export function histText(v: any): string {
  if (typeof v === "string") return v;
  if (Array.isArray(v)) {
    try {
      return new TextDecoder("utf-8").decode(Uint8Array.from(v));
    } catch {
      return "";
    }
  }
  return v == null ? "" : String(v);
}

export function projectName(root: string) {
  if (!root) return "";
  const parts = String(root).replace(/\/+$/, "").split("/");
  return parts[parts.length - 1] || root;
}

export function fmtTime(ts: any) {
  if (!ts) return "";
  const d = new Date(ts),
    now = new Date();
  if (d.toDateString() === now.toDateString())
    return d.toTimeString().slice(0, 5);
  const y = new Date(now);
  y.setDate(y.getDate() - 1);
  if (d.toDateString() === y.toDateString()) return "昨天";
  return d.getMonth() + 1 + "月" + d.getDate() + "日";
}

export function fmtTok(n: any) {
  n = +n || 0;
  if (n >= 1e6) return (n / 1e6).toFixed(n % 1e6 ? 1 : 0) + "M";
  if (n >= 1000) return (n / 1000).toFixed(n % 1000 ? 1 : 0) + "k";
  return String(Math.round(n));
}

export function closeFences(s: string) {
  const n = (s.match(/```/g) || []).length;
  return n % 2 ? s + "\n```" : s;
}

export function nunit(n: number, one: string, many?: string) {
  const w = n === 1 ? one : many || one + "s";
  return n + " " + w;
}

export function downloadText(name: string, text: string, mime?: string) {
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([text], { type: mime || "text/plain" }));
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

// ---- 工具分类/图标/参数 ----
export function toolType(n: string) {
  if (/^(bash|exec|sh|git|cmd|powershell)$/.test(n)) return "term";
  if (/^(edit|write|apply_patch)$/.test(n)) return "diff";
  if (/^(read|skill|show)$/.test(n)) return "code";
  if (/^todo_/.test(n)) return "todo";
  if (/^(task|workflow|spawn_agent|wait_agent|send_agent|read_agent|close_agent|list_agents)$/.test(n))
    return "agent";
  return "sum";
}
export function parseToolArgs(raw: any): any {
  if (!raw) return {};
  if (typeof raw === "object") return raw;
  try {
    const o = JSON.parse(raw);
    return o && typeof o === "object" ? o : {};
  } catch {
    return {};
  }
}
export function argsPreview(raw: any) {
  const o = parseToolArgs(raw);
  const s = o.command || o.path || o.pattern || o.query || raw || "";
  return String(s).slice(0, 140);
}
export function toolIcon(n: string) {
  if (/^(edit|write|apply_patch)$/.test(n)) return "✎";
  if (/^(read|skill|show)$/.test(n)) return "≡";
  if (n === "bash" || n === "exec") return "$";
  return "⚙";
}
export function artifactName(out: string) {
  const m = /\[Artifact stored: ([^\]\n]+?) \((\d+) bytes\)\]/.exec(out || "");
  if (!m) return null;
  const base = m[1].split(/[/\\]/).pop() || "";
  return /^[\w.-]+$/.test(base) ? base : null;
}
export function workKind(name: string) {
  const n = String(name || "");
  if (n === "read" || n === "read_image") return "read";
  if (/^(grep|find|ls)$/.test(n)) return "search";
  if (/^(edit|write|multi_edit|apply_patch)$/.test(n)) return "edit";
  if (n === "bash" || n === "exec") return "bash";
  if (/^(web_search|fetch_url|webfetch|web_fetch|search_web|browse)$/.test(n) || /web/i.test(n))
    return "web";
  if (/^mcp/i.test(n) || /mcp/i.test(n)) return "mcp";
  if (/^todo_/.test(n)) return "todo";
  if (/^(task|workflow|spawn_agent|wait_agent|send_agent|read_agent|close_agent|list_agents)$/.test(n))
    return "agent";
  return "other";
}
export function ico(kind: string) {
  const p: Record<string, string> = {
    think:
      '<circle cx="8" cy="6.5" r="4"/><path d="M6 11.2h4M6.4 13h3.2M8 2.2v-1M3.2 6.5h-1M13.8 6.5h1"/>',
    read: '<path d="M3 2.6h6.6L13 6v7.4H3z"/><path d="M9.4 2.6V6H13"/>',
    search: '<circle cx="7" cy="7" r="4"/><path d="M10.1 10.1L14 14"/>',
    bash: '<rect x="2.4" y="3.2" width="11.2" height="9.6" rx="1.2"/><path d="M5 6.4l2 1.6-2 1.6M8.4 10.2h3"/>',
    edit: '<path d="M9.2 2.8l4 4L6 14H2v-4z"/>',
    web: '<circle cx="8" cy="8" r="5.6"/><path d="M2.4 8h11.2M8 2.4c2 2.4 2 8.8 0 11.2M8 2.4c-2 2.4-2 8.8 0 11.2"/>',
    mcp: '<path d="M6 3.2h4v2.6h2.8v4H10v2.8H6v-2.8H3.2v-4H6z"/>',
    todo: '<rect x="3" y="3" width="10" height="10" rx="2"/><path d="M5.4 8.1l1.8 1.8 3.5-3.7"/>',
    agent: '<circle cx="8" cy="5.6" r="2.3"/><path d="M3.4 13c.5-2.3 2.3-3.5 4.6-3.5s4.1 1.2 4.6 3.5"/>',
    tool: '<path d="M10.2 2.6l3.2 3.2-2 1-2.4 2.4-1.6-1.6 2.4-2.4zM3 13l4-4"/>',
  };
  return (
    '<svg class="ico" viewBox="0 0 16 16" aria-hidden="true">' +
    (p[kind] || p.tool) +
    "</svg>"
  );
}
export function icoKind(name: string) {
  const k = workKind(name);
  return k === "other" ? "tool" : k;
}

// ---- 斜杠补全打分(模糊子序列) ----
export function slashStem(cmd: string) {
  const s = cmd[0] === "/" ? cmd.slice(1) : cmd;
  const i = s.indexOf(" ");
  return i < 0 ? s : s.slice(0, i);
}
export function startsWithInsens(hay: string, needle: string) {
  return hay.slice(0, needle.length).toLowerCase() === needle.toLowerCase();
}
export function indexOfInsens(hay: string, needle: string) {
  return hay.toLowerCase().indexOf(needle.toLowerCase());
}
export function fuzzySubseq(hay: string, needle: string): { from: number; to: number } | null {
  if (!needle) return { from: 0, to: 0 };
  let i = 0,
    first = -1,
    last = 0;
  const n = needle.toLowerCase();
  const h = hay.toLowerCase();
  for (let hi = 0; hi < h.length; hi++) {
    if (i < n.length && h[hi] === n[i]) {
      if (first < 0) first = hi;
      last = hi + 1;
      i++;
    }
  }
  return i === n.length ? { from: first, to: last } : null;
}
export function rankSlash(items: any[], query: string): any[] {
  if (!query) return items.map((it) => ({ it, kind: 0, hlFrom: 0, hlLen: 0, score: 0 }));
  const out = [];
  for (const it of items) {
    const name = slashStem(it.name);
    if (startsWithInsens(name, query)) {
      out.push({
        it,
        kind: 0,
        hlFrom: 0,
        hlLen: query.length,
        score: 2000 + (name.length === query.length ? 1000 : 0) - Math.min(name.length, 500),
      });
      continue;
    }
    const span = fuzzySubseq(name, query);
    if (span) {
      out.push({
        it,
        kind: 1,
        hlFrom: span.from,
        hlLen: span.to - span.from,
        score: 1000 - Math.min(span.to - span.from, 500),
      });
      continue;
    }
    const at = indexOfInsens(it.desc, query);
    if (at >= 0) out.push({ it, kind: 2, hlFrom: at, hlLen: query.length, score: 100 });
  }
  out.sort((a, b) => a.kind - b.kind || b.score - a.score);
  return out;
}
export function hlSpan(s: string, from: number, len: number) {
  if (!len) return esc(s);
  return (
    esc(s.slice(0, from)) +
    "<mark>" +
    esc(s.slice(from, from + len)) +
    "</mark>" +
    esc(s.slice(from + len))
  );
}

export function isMarkdownPath(p: string) {
  return /\.(md|markdown|mdx)$/i.test(p || "");
}
export function looksLikeMd(t: string) {
  if (!t || t.length < 8) return false;
  return /^#{1,3}\s/m.test(t) || /```/.test(t) || /^\s*[-*]\s+\S/m.test(t);
}
