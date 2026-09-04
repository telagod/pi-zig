// md.ts —— 极简 markdown / ansi / diff / todo 渲染,纯字符串进 HTML 出。
// 块级:标题/表格/任务列表/嵌套列表/引用/分割线/围栏代码(含语法着色与头部栏)。
import { esc } from "./util";
import { t } from "./i18n";

// ---- 语法着色(轻量 tokenizer;关键字取常见语言并集) ----
const KW = new Set(
  (
    "const let var fn pub function return if else elif for while do switch case default break continue " +
    "import from export class struct enum union interface type extends implements new delete typeof instanceof " +
    "in of try catch finally throw throws raise await async yield static this self super null undefined nil " +
    "none None true false True False and or not is def pass with as print package go defer chan select match " +
    "where mut impl trait use mod crate void int float double char bool string byte rune error any unknown " +
    "never public private protected readonly abstract override virtual final sealed internal namespace " +
    "using module requires concept template typename auto constexpr inline extern volatile register sizeof " +
    "alignof noexcept comptime orelse unreachable errdefer test threadlocal callconv asm " +
    "then done fi esac echo local declare shift trap source set unset eval exec " +
    "begin end rescue ensure unless until when attr_accessor include extend require " +
    "dyn box move Self unsafe"
  ).split(/\s+/),
);
// # 行注释仅这些语言(zig/js 等把 # 当普通字符)
const HASHLANG = new Set(
  ("sh bash zsh shell py python ruby rb perl pl r yaml yml toml ini conf cfg makefile make dockerfile nim crystal elixir ex exs").split(/\s+/),
);
const TOK_RE =
  /(\/\*[\s\S]*?\*\/)|(\/\/[^\n]*)|(#[^\n]*)|("(?:[^"\\\n]|\\.)*"?|'(?:[^'\\\n]|\\.)*'?|`(?:[^`\\]|\\.)*`?)|(\b\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?[a-zA-Z]*)|([A-Za-z_$][A-Za-z0-9_$]*)/g;

export function hlCode(code: string, lang: string): string {
  const hashC = HASHLANG.has(lang.toLowerCase());
  let html = "";
  let last = 0;
  TOK_RE.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = TOK_RE.exec(code)) !== null) {
    if (m.index > last) html += esc(code.slice(last, m.index));
    const [full, blk, line, hash, str, num, word] = m;
    if (blk || line) html += '<span class="tk-c">' + esc(full) + "</span>";
    else if (hash) html += hashC ? '<span class="tk-c">' + esc(full) + "</span>" : esc(full);
    else if (str) html += '<span class="tk-s">' + esc(full) + "</span>";
    else if (num) html += '<span class="tk-n">' + esc(full) + "</span>";
    else if (word) {
      if (KW.has(word)) html += '<span class="tk-k">' + esc(full) + "</span>";
      else if (code[TOK_RE.lastIndex] === "(") html += '<span class="tk-f">' + esc(full) + "</span>";
      else html += esc(full);
    }
    last = TOK_RE.lastIndex;
  }
  if (last < code.length) html += esc(code.slice(last));
  return html;
}

// ---- 代码块外壳:语言徽标 + 复制钮(点击委托在 chat.ts) ----
function codeBlock(lang: string, body: string) {
  const L = (lang || "").trim();
  const inner = L ? hlCode(body, L) : esc(body);
  return (
    '<div class="cb"><div class="cb-hd"><span class="cb-lang">' +
    esc(L) +
    '</span><button class="pre-cp" type="button" title="' +
    t("copy", "Copy") +
    '">⧉</button></div><pre><code>' +
    inner +
    "</code></pre></div>"
  );
}

// ---- 行内:转义优先,再码/粗/斜/删/链 ----
export function mdInline(s: string) {
  const spans: string[] = [];
  // 码段先占位,防内部字符被粗斜体吃掉
  s = s.replace(/`([^`]+)`/g, (_m, c) => "\u0000" + (spans.push("<code>" + esc(c) + "</code>") - 1) + "\u0000");
  s = esc(s);
  s = s.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/(^|[^*])\*(?!\s|\*)([^*]*[^\s*])\*(?!\*)/g, "$1<em>$2</em>");
  s = s.replace(/~~(.+?)~~/g, "<del>$1</del>");
  s = s.replace(
    /\[([^\]]+)\]\((https?:[^)\s]+)\)/g,
    '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>',
  );
  s = s.replace(
    /(^|[\s(>])((?:https?:\/\/)[^\s<>()"]+[^\s<>().,;:!?'"])/g,
    '$1<a href="$2" target="_blank" rel="noopener noreferrer">$2</a>',
  );
  s = s.replace(/\u0000(\d+)\u0000/g, (_m, i) => spans[+i]);
  return s;
}

// CJK 相邻行间不补空格
function joinLines(a: string[]) {
  let o = a[0] || "";
  for (let i = 1; i < a.length; i++) {
    const prev = o[o.length - 1] || "";
    const cur = a[i][0] || "";
    o += /[\u2e80-\u9fff\uff00-\uffef\u3000-\u303f]/.test(prev + cur) ? a[i] : " " + a[i];
  }
  return o;
}

// ---- 表格:表头行 + 界定行(|---|) ----
function isTableAt(lines: string[], i: number) {
  if (i + 1 >= lines.length) return false;
  const head = lines[i], sep = lines[i + 1];
  if (!/^\s*\|?[\s:|-]+\|?\s*$/.test(sep) || !/-/.test(sep)) return false;
  return /\|/.test(head) && /\|/.test(sep);
}
function splitRow(line: string) {
  let t = line.trim();
  if (t.startsWith("|")) t = t.slice(1);
  if (t.endsWith("|")) t = t.slice(0, -1);
  return t.split(/(?<!\\)\|/).map((c) => c.trim().replace(/\\\|/g, "|"));
}
function tableHtml(lines: string[], start: number) {
  const head = splitRow(lines[start]);
  const seps = splitRow(lines[start + 1]);
  const aligns = seps.map((s) =>
    s.startsWith(":") && s.endsWith(":") ? "center" : s.endsWith(":") ? "right" : "left",
  );
  let html = '<div class="tbl"><table><thead><tr>';
  head.forEach((c, i) => {
    html += '<th style="text-align:' + (aligns[i] || "left") + '">' + mdInline(c) + "</th>";
  });
  html += "</tr></thead><tbody>";
  let i = start + 2;
  while (i < lines.length && /\|/.test(lines[i]) && lines[i].trim() !== "") {
    const cells = splitRow(lines[i]);
    html += "<tr>";
    for (let c = 0; c < head.length; c++) {
      html += '<td style="text-align:' + (aligns[c] || "left") + '">' + mdInline(cells[c] || "") + "</td>";
    }
    html += "</tr>";
    i++;
  }
  html += "</tbody></table></div>";
  return { html, next: i };
}

// ---- 列表:缩进栈出嵌套;任务项 [ ]/[x];懒续行并入上项 ----
const ITEM_RE = /^(\s{0,12})([-*+]|(\d+)[.)])\s+(.*)$/;
function listHtml(lines: string[], start: number) {
  const items: { ind: number; ord: boolean; text: string }[] = [];
  let i = start;
  while (i < lines.length) {
    const m = ITEM_RE.exec(lines[i]);
    if (m) {
      items.push({ ind: m[1].length, ord: !!m[3], text: m[4] });
      i++;
      continue;
    }
    const last = items[items.length - 1];
    if (last && lines[i].trim() !== "" && /^\s{2,}/.test(lines[i])) {
      last.text += "\n" + lines[i].trim();
      i++;
      continue;
    }
    break;
  }
  let html = "";
  const stack: { ind: number; ord: boolean }[] = [];
  const closeTo = (ind: number) => {
    while (stack.length && stack[stack.length - 1].ind > ind) {
      html += stack.pop()!.ord ? "</ol>" : "</ul>";
    }
  };
  for (const it of items) {
    let top = stack[stack.length - 1];
    if (top && it.ind < top.ind) closeTo(it.ind);
    top = stack[stack.length - 1];
    if (!top || it.ind > top.ind || (it.ind === top.ind && it.ord !== top.ord)) {
      if (top && it.ind === top.ind) {
        html += top.ord ? "</ol>" : "</ul>";
        stack.pop();
      }
      html += it.ord ? "<ol>" : "<ul>";
      stack.push({ ind: it.ind, ord: it.ord });
    }
    const tm = /^\[([ xX])\]\s+([\s\S]*)$/.exec(it.text);
    if (tm) {
      const done = tm[1] !== " ";
      html +=
        '<li class="task' +
        (done ? " done" : "") +
        '"><span class="task-box" aria-hidden="true">' +
        (done ? "✓" : "") +
        "</span><span>" +
        mdInline(tm[2]) +
        "</span></li>";
    } else {
      html += "<li>" + mdInline(joinLines(it.text.split("\n"))) + "</li>";
    }
  }
  closeTo(-1);
  return { html, next: i };
}

// ---- 块级主体 ----
export function mdBlocks(src: string) {
  const lines = String(src).replace(/\r\n/g, "\n").split("\n");
  let html = "";
  let i = 0;
  let para: string[] = [];
  const flushP = () => {
    if (!para.length) return;
    html += "<p>" + mdInline(joinLines(para)) + "</p>";
    para = [];
  };
  while (i < lines.length) {
    const line = lines[i];
    if (/^\s*$/.test(line)) {
      flushP();
      i++;
      continue;
    }
    // 围栏代码(吞到闭合;流式期由 closeFences 补闭合)
    const fm = /^\s*```([^\s`]*)\s*$/.exec(line);
    if (fm) {
      flushP();
      const body: string[] = [];
      i++;
      const closeRe = /^\s*```\s*$/;
      while (i < lines.length && !closeRe.test(lines[i])) {
        body.push(lines[i]);
        i++;
      }
      i++; // 吃闭合行
      html += codeBlock(fm[1] || "", body.join("\n"));
      continue;
    }
    const hm = /^(#{1,6})\s+(.+?)\s*#*\s*$/.exec(line);
    if (hm) {
      flushP();
      html += "<h" + hm[1].length + ">" + mdInline(hm[2]) + "</h" + hm[1].length + ">";
      i++;
      continue;
    }
    if (/^((-\s*){3,}|(\*\s*){3,}|(_\s*){3,})$/.test(line.trim() + " ")) {
      flushP();
      html += "<hr/>";
      i++;
      continue;
    }
    if (/^>\s?/.test(line)) {
      flushP();
      const qs: string[] = [];
      while (i < lines.length) {
        if (/^>\s?/.test(lines[i])) {
          qs.push(lines[i].replace(/^>\s?/, ""));
          i++;
          continue;
        }
        // 空行续引用仅当后行仍是引用
        if (lines[i].trim() === "" && i + 1 < lines.length && /^>\s?/.test(lines[i + 1])) {
          qs.push("");
          i++;
          continue;
        }
        break;
      }
      const first = qs[0] || "";
      const am = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?:\s+(.*))?$/i.exec(first);
      if (am) {
        const kind = am[1].toUpperCase();
        const rest = qs.slice(1);
        if (am[2]) rest.unshift(am[2]);
        const inner = mdBlocks(rest.join("\n"));
        html += '<div class="callout callout-' + kind.toLowerCase() + '"><div class="callout-hd">' + kind + "</div>" + inner + "</div>";
      } else {
        html += "<blockquote>" + mdBlocks(qs.join("\n")) + "</blockquote>";
      }
      continue;
    }
    if (isTableAt(lines, i)) {
      flushP();
      const t = tableHtml(lines, i);
      html += t.html;
      i = t.next;
      continue;
    }
    if (ITEM_RE.test(line)) {
      flushP();
      const l = listHtml(lines, i);
      html += l.html;
      i = l.next;
      continue;
    }
    para.push(line);
    i++;
  }
  flushP();
  return html;
}

// ---- 入口:助手消息与 inspect 共用 ----
export function md(raw: string) {
  return mdBlocks(String(raw ?? ""));
}
export function renderMd(src: string) {
  return mdBlocks(String(src ?? ""));
}

// ---- ANSI(工具终端输出):语义类名,浅深两套色板在 webui.css ----
const AC: Record<string, string> = {
  "30": "30", "31": "31", "32": "32", "33": "33", "34": "34", "35": "35",
  "36": "36", "37": "37", "90": "90", "91": "91", "92": "92", "93": "93",
  "94": "94", "95": "95", "96": "96", "97": "97",
};
export function ansiHtml(t: string) {
  // 逐段包 span:颜色切换处收前段、开新段(旧实现把整段染成末尾色)
  let o = "",
    last = 0,
    fg: string | null = null;
  const re = /\x1b\[([0-9;]*)m/g;
  let m;
  const flush = (end: number) => {
    const seg = esc(t.slice(last, end));
    if (!seg) return;
    o += fg ? '<span class="ansi-' + fg + '">' + seg + "</span>" : seg;
  };
  while ((m = re.exec(t)) !== null) {
    flush(m.index);
    const c = m[1].split(";").filter(Boolean);
    if (c.includes("0") || c.length === 0) fg = null;
    else {
      const col = AC[c.find((x) => AC[x]) || ""];
      if (col) fg = col;
    }
    last = m.index + m[0].length;
  }
  flush(t.length);
  return o;
}

// ---- diff / todo(工具卡) ----
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
