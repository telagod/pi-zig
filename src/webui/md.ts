// md.ts —— 极简 markdown / ansi / diff / todo 渲染,纯字符串进 HTML 出。
// 自 webui.js 切出;名与义一字未改。
import { esc } from "./util";

// markdown(极简:代码块+行内码+粗体)
export function md(raw: string) {
  const out = [];
  const re = /```(\w*)\n?([\s\S]*?)```/g;
  let last = 0,
    m;
  while ((m = re.exec(raw)) !== null) {
    if (m.index > last) out.push(mdInline(raw.slice(last, m.index)));
    out.push('<pre><button class="pre-cp" type="button" title="复制">⧉</button><code>' + esc(m[2]) + "</code></pre>");
    last = m.index + m[0].length;
  }
  if (last < raw.length) out.push(mdInline(raw.slice(last)));
  return out.join("");
}
const AC: Record<string, string> = {
  "30": "#333",
  "31": "#f85149",
  "32": "#3fb950",
  "33": "#d29922",
  "34": "#58a6ff",
  "35": "#bc8cff",
  "36": "#39c5cf",
  "37": "#c9d1d9",
  "90": "#8b949e",
  "91": "#ff7b72",
  "92": "#7ee787",
  "93": "#e3b341",
  "94": "#79c0ff",
  "95": "#d2a8ff",
  "96": "#76e3ea",
  "97": "#e6edf3",
};
export function ansiHtml(t: string) {
  let o = "",
    last = 0,
    fg = null;
  const re = /\x1b\[([0-9;]*)m/g;
  let m;
  while ((m = re.exec(t)) !== null) {
    o += esc(t.slice(last, m.index));
    const c = m[1].split(";").filter(Boolean);
    if (c.includes("0") || c.length === 0) fg = null;
    else {
      const col = AC[c.find((x) => AC[x]) || ""];
      if (col) fg = col;
    }
    last = m.index + m[0].length;
  }
  o += esc(t.slice(last));
  return fg ? '<span style="color:' + fg + '">' + o + "</span>" : o;
}
export function mdInline(s: string) {
  s = esc(s);
  s = s.replace(/`([^`]+)`/g, "<code>$1</code>");
  s = s.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/(^|[^\*])\*(?!\*)([^*]+)\*(?!\*)/g, "$1<em>$2</em>");
  s = s.replace(
    /\[([^\]]+)\]\((https?:[^)\s]+)\)/g,
    '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>',
  );
  return s;
}
export function mdBlocks(s: string) {
  const lines = String(s).replace(/\r\n/g, "\n").split("\n");
  let html = "";
  let i = 0;
  let para: string[] = [];
  const flushP = () => {
    if (!para.length) return;
    html += "<p>" + mdInline(para.join(" ")) + "</p>";
    para = [];
  };
  while (i < lines.length) {
    const line = lines[i];
    if (/^\s*$/.test(line)) {
      flushP();
      i++;
      continue;
    }
    const hm = /^(#{1,3})\s+(.+)$/.exec(line);
    if (hm) {
      flushP();
      html += "<h" + hm[1].length + ">" + mdInline(hm[2]) + "</h" + hm[1].length + ">";
      i++;
      continue;
    }
    if (/^---+$/.test(line.trim())) {
      flushP();
      html += "<hr/>";
      i++;
      continue;
    }
    if (/^>\s?/.test(line)) {
      flushP();
      const qs = [];
      while (i < lines.length && /^>\s?/.test(lines[i])) {
        qs.push(lines[i].replace(/^>\s?/, ""));
        i++;
      }
      html += "<blockquote>" + mdInline(qs.join(" ")) + "</blockquote>";
      continue;
    }
    if (/^\s*[-*]\s+/.test(line)) {
      flushP();
      html += "<ul>";
      while (i < lines.length && /^\s*[-*]\s+/.test(lines[i])) {
        html += "<li>" + mdInline(lines[i].replace(/^\s*[-*]\s+/, "")) + "</li>";
        i++;
      }
      html += "</ul>";
      continue;
    }
    if (/^\s*\d+\.\s+/.test(line)) {
      flushP();
      html += "<ol>";
      while (i < lines.length && /^\s*\d+\.\s+/.test(lines[i])) {
        html += "<li>" + mdInline(lines[i].replace(/^\s*[-*]\s+/, "")) + "</li>";
        i++;
      }
      html += "</ol>";
      continue;
    }
    para.push(line);
    i++;
  }
  flushP();
  return html;
}
export function renderMd(src: string) {
  const text = String(src || "");
  const re = /```(\w*)\n?([\s\S]*?)```/g;
  let html = "";
  let last = 0;
  let m;
  while ((m = re.exec(text))) {
    if (m.index > last) html += mdBlocks(text.slice(last, m.index));
    html += '<pre><button class="pre-cp" type="button" title="复制">⧉</button><code>' + esc(m[2].replace(/\n$/, "")) + "</code></pre>";
    last = m.index + m[0].length;
  }
  if (last < text.length) html += mdBlocks(text.slice(last));
  return html;
}
export function diffHtml(t: string) {
  const lines = String(t || "").split("\n");
  let html = "";
  let file = "";
  for (const l of lines) {
    if (/^(edited|wrote|created)\b/i.test(l)) {
      html += '<div class="diff-meta">' + esc(l) + "</div>";
      continue;
    }
    if (l.startsWith("+++ ")) {
      file = l.slice(4).replace(/^[ab]\//, "");
      continue;
    }
    if (l.startsWith("--- ")) continue;
    if (l.startsWith("@@")) {
      html +=
        '<div class="diff-row hunk"><span class="g"></span><span class="ln">' +
        esc(l) +
        "</span></div>";
      continue;
    }
    if (l.startsWith("+")) {
      html +=
        '<div class="diff-row add"><span class="g">+</span><span class="ln">' +
        esc(l.slice(1)) +
        "</span></div>";
      continue;
    }
    if (l.startsWith("-")) {
      html +=
        '<div class="diff-row del"><span class="g">−</span><span class="ln">' +
        esc(l.slice(1)) +
        "</span></div>";
      continue;
    }
    html +=
      '<div class="diff-row"><span class="g"></span><span class="ln">' + esc(l) + "</span></div>";
  }
  if (file) html = '<div class="diff-file">' + esc(file) + "</div>" + html;
  return html;
}
export function todoHtml(t: string) {
  let html = "";
  for (const l of String(t || "").split("\n")) {
    const m = /^\[([ x>X])\]\s*(.*)$/.exec(l);
    if (m) {
      const st = m[1] === "x" || m[1] === "X" ? "done" : m[1] === ">" ? "run" : "pend";
      const bm = /^(.*)\s+@([A-Za-z][A-Za-z0-9_-]*)$/.exec(m[2]);
      const tx = bm ? bm[1] : m[2];
      const bind = bm ? bm[2] : "";
      html +=
        '<div class="todo-i ' +
        st +
        '"><span class="todo-box"></span><span class="todo-tx">' +
        esc(tx) +
        (bind ? '<span class="todo-bind">@' + esc(bind) + "</span>" : "") +
        "</span></div>";
    } else if (l.trim()) {
      html += '<div class="todo-foot">' + esc(l) + "</div>";
    }
  }
  return html;
}
