// chat.ts —— 线程渲染核心:滚动贴底/回底钮、会话内搜索、历史重放、消息流、
// 工作卡(work/Flow 工作流图)、工具卡与 inspect 窗格、审批卡、系统行。
// 自 webui.js 切出。main 之物(欢迎页/插件/授权/发送)经 chatH 钩袋注入,别名包装保调用点不改;
// 活读改 H.getX()(lastUser),活写改 H.setX()(lastUser、histStart/histTotal 由 setHistRange)。
import {
  $, esc, histText, closeFences, nunit, toolType, parseToolArgs, argsPreview,
  artifactName, workKind, ico, icoKind, isMarkdownPath, looksLikeMd,
} from "./util";
import { md, ansiHtml, diffHtml, todoHtml, renderMd } from "./md";
import { sess, wsp } from "./state";
import { showToast, clipText } from "./ui";
import { act } from "./sessions";
import { setApproval } from "./model";
import { hideWelcome } from "./sheet";
import { pluginEmit, getToolRenderer } from "./plugins";

export const chatH: any = {};
const sendPlain = (...a: any[]) => chatH.sendPlain(...a);

// ---- 渲染 ----
export const th = $("thread")!;
let stick = true;
// 代码块复制:一次性委托(钮随 md.ts 的 <pre> 渲染;inspect 窗格同沾)
document.addEventListener("click", (e: any) => {
  const b = e.target && e.target.closest ? e.target.closest(".pre-cp") : null;
  if (!b) return;
  const box = b.closest(".cb") || b.parentElement;
  const code = box && box.querySelector("code");
  clipText(code ? code.textContent || "" : "", "已复制", "复制失败");
});
// 回到底部:非贴底且有溢出时现身
const toB = $("toBottom")!;
function updToBottom() {
  const p = $("panes")!;
  const overflow = p.scrollHeight - p.clientHeight > 40;
  toB.hidden = stick || !overflow;
}
toB.onclick = () => {
  const p = $("panes")!;
  stick = true;
  p.scrollTop = p.scrollHeight;
  updToBottom();
};
$("panes")!.addEventListener("scroll", () => {
  const p = $("panes")!;
  stick = p.scrollHeight - p.scrollTop - p.clientHeight < 80;
  updToBottom();
});
export function scrl() {
  if (replayQuiet) return;
  if (stick) $("panes")!.scrollTop = $("panes")!.scrollHeight;
  updToBottom();
}
let replayQuiet = false;
let webFindQ = "",
  webFindIdx = -1;
export async function findInThread(q: string, reverse?: boolean, retried?: boolean): Promise<boolean> {
  q = String(q || "").trim();
  if (!q) return false;
  if (q !== webFindQ) {
    webFindQ = q;
    webFindIdx = reverse ? 1e9 : -1;
  }
  const nodes = th.querySelectorAll(".u-bub, .md, .p, .bb-pad");
  const hits: any[] = [];
  const low = q.toLowerCase();
  nodes.forEach((el: any) => {
    if ((el.textContent || "").toLowerCase().indexOf(low) >= 0) hits.push(el);
  });
  th.querySelectorAll(".find-hit").forEach((e: any) => e.classList.remove("find-hit"));
  if (!hits.length) {
    if (!retried && histStart > 0) {
      await loadOlder();
      return findInThread(q, reverse, true);
    }
    return false;
  }
  if (reverse) webFindIdx = (webFindIdx - 1 + hits.length) % hits.length;
  else webFindIdx = (webFindIdx + 1) % hits.length;
  const el = hits[webFindIdx];
  el.classList.add("find-hit");
  el.scrollIntoView({ block: "center", behavior: "smooth" });
  return true;
}
document.addEventListener("keydown", (ev) => {
  if (ev.key !== "F3" || !webFindQ) return;
  ev.preventDefault();
  findInThread(webFindQ, ev.shiftKey);
});
let histStart = 0,
  histTotal = 0;
export function setHistRange(start: number, total: number) {
  histStart = start;
  histTotal = total;
}
export function getWebFindQ() {
  return webFindQ;
}
export function paintHistMore() {
  let b = $("hist-more") as HTMLButtonElement | null;
  if (!b) {
    b = document.createElement("button");
    b.id = "hist-more";
    b.className = "hist-more";
    b.type = "button";
    b.onclick = () => loadOlder();
    th.insertBefore(b, th.firstChild);
  } else if (th.firstChild !== b) th.insertBefore(b, th.firstChild);
  const n = histStart;
  b.hidden = n <= 0;
  b.textContent = n > 0 ? "↑ 更早 " + n + " 条" : "";
}
export function replayHist(items: any[], prepend?: boolean) {
  if (!items || !items.length) return;
  hideWelcome();
  const saved: any[] = [];
  if (prepend) {
    const more = $("hist-more");
    while (th.firstChild) {
      const n: any = th.firstChild;
      th.removeChild(n);
      if (n !== more) saved.push(n);
    }
  }
  replayQuiet = true;
  try {
    for (const h of items) {
      const text = histText(h.content);
      if (h.role === "user") {
        finishRsn();
        finishWork();
        chatH.setLastUser(text);
        addUser(h.has_image && !text ? "[image]" : h.has_image ? text + "  [image]" : text, h.image_file ? "/api/image?name=" + encodeURIComponent(h.image_file) : null);
      } else if (h.role === "assistant") {
        const rsn = histText(h.reasoning);
        if (rsn) addRsn(rsn);
        if (text) {
          finishRsn();
          const e = asstEl().querySelector(".md") as HTMLElement;
          e.textContent = text;
          finishAsst();
        }
      } else if (h.role === "system") {
        continue;
      } else {
        const name = h.name || "tool";
        const args = h.args || "";
        if (isWorkflow(name, args, text)) Flow.upsert(args, text);
        else {
          addTool(name, args);
          toolDone(name, false, text);
        }
      }
    }
    finishWork();
  } finally {
    replayQuiet = false;
  }
  if (prepend) {
    for (const n of saved) th.appendChild(n);
  }
  paintHistMore();
}
export async function loadOlder() {
  if (histStart <= 0) return;
  const lim = 80;
  const off = Math.max(0, histStart - lim);
  const take = histStart - off;
  const r = await fetch(
    "/api/history?" + wsp + "session=" + encodeURIComponent(sess) + "&offset=" + off + "&limit=" + take,
  );
  if (!r.ok) return;
  const j = await r.json();
  const panes = $("panes")!;
  const oldH = panes.scrollHeight;
  replayHist(j.history || [], true);
  histStart = j.start ?? off;
  histTotal = j.total ?? histTotal;
  paintHistMore();
  panes.scrollTop += panes.scrollHeight - oldH;
}
let curAsst: any = null,
  rsnEl: any = null,
  undoBtn: any = null;
// 重载后流之续:以末条 a-turn 为活泡。
export function resumeAsst() {
  const la = th.querySelector(".a-turn:last-child");
  if (la) {
    curAsst = la;
    curAsst.classList.add("gen");
  }
}
let workEl: any = null;
let workCounts: any = { read: 0, search: 0, edit: 0, bash: 0, web: 0, mcp: 0, todo: 0, agent: 0, other: 0 };
let turnAt = 0;
export function noteTurn() {
  if (!turnAt) turnAt = Date.now();
}
function workBitsHtml(live: boolean) {
  const bits = [];
  if (workCounts.read) bits.push(ico("read") + "<span>" + nunit(workCounts.read, "file") + "</span>");
  if (workCounts.search) bits.push(ico("search") + "<span>" + nunit(workCounts.search, "search", "searches") + "</span>");
  if (workCounts.web) bits.push(ico("web") + "<span>" + nunit(workCounts.web, "web") + "</span>");
  if (workCounts.mcp) bits.push(ico("mcp") + "<span>" + nunit(workCounts.mcp, "MCP") + "</span>");
  if (workCounts.bash) bits.push(ico("bash") + "<span>" + nunit(workCounts.bash, "command") + "</span>");
  if (workCounts.edit) bits.push(ico("edit") + "<span>" + nunit(workCounts.edit, "edit") + "</span>");
  if (workCounts.todo) bits.push(ico("todo") + "<span>" + nunit(workCounts.todo, "plan") + "</span>");
  if (workCounts.agent) bits.push(ico("agent") + "<span>" + nunit(workCounts.agent, "agent") + "</span>");
  if (workCounts.other) bits.push(ico("tool") + "<span>" + nunit(workCounts.other, "tool") + "</span>");
  if (!bits.length) return live ? "正在工作" : "已完成";
  return bits.map((b) => '<span class="work-chip">' + b + "</span>").join('<span class="work-dot">·</span>');
}
function refreshWorkSum(live: boolean) {
  if (!workEl) return;
  const sum = workEl.querySelector(".work-sum");
  const bits = sum.querySelector(".work-bits") || sum;
  bits.innerHTML = workBitsHtml(live);
  sum.classList.toggle("edit", !live && workCounts.edit > 0);
}
function ensureWork() {
  if (workEl && workEl.isConnected) return workEl;
  const el = document.createElement("div");
  el.className = "work live";
  el.innerHTML =
    '<button type="button" class="work-sum"><span class="work-caret">▸</span><span class="work-bits">正在工作</span></button><div class="work-list"></div>';
  (el.querySelector(".work-sum") as HTMLElement).onclick = () => el.classList.toggle("open");
  th.appendChild(el);
  workEl = el;
  workCounts = { read: 0, search: 0, edit: 0, bash: 0, web: 0, mcp: 0, todo: 0, agent: 0, other: 0 };
  return workEl;
}
export const Flow: any = {
  el: null,
  id: "",
  goal: "",
  nodes: [],
  args: "",
  out: "",
  done: false,
  openId: "",
  ident(args: string, out: string) {
    const o = parseToolArgs(args);
    const gm = /^Workflow\s+"([^"]+)"/.exec(String(out || ""));
    const goal = (o.goal && String(o.goal)) || (gm && gm[1]) || "";
    const ids = (Array.isArray(o.nodes) ? o.nodes.map((n: any) => n && n.id) : this.nodesFrom(out).map((n: any) => n.id))
      .filter(Boolean)
      .join(">");
    return { goal, ids };
  },
  nodesFrom(out: string) {
    const nodes: any[] = [];
    const re = /===\s+([A-Za-z][A-Za-z0-9_-]*)\b(?:\s+\(([^)]+)\))?\s+(ok|FAILED|skipped)/g;
    let m;
    while ((m = re.exec(String(out || "")))) {
      nodes.push({
        id: m[1],
        role: m[2] || "",
        needs: [],
        st: m[3] === "ok" ? "ok" : m[3] === "FAILED" ? "fail" : "skip",
        last: "",
        body: "",
        idx: nodes.length + 1,
      });
    }
    return nodes;
  },
  slice(out: string, id: string) {
    if (!out || !id) return "";
    const re = new RegExp("===\\s+" + id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\b[^\\n]*===\\n");
    const m = re.exec(out);
    if (!m) return "";
    const rest = out.slice(m.index + m[0].length);
    const next = rest.search(/\n===\s+/);
    return (next < 0 ? rest : rest.slice(0, next)).trim();
  },
  parse(args: string, out: string) {
    const o = parseToolArgs(args);
    let nodes = (Array.isArray(o.nodes) ? o.nodes : [])
      .map((n: any, i: number) => ({
        id: String((n && n.id) || ""),
        role: (n && n.role) || "",
        needs: Array.isArray(n && n.needs) ? n.needs : [],
        st: "wait",
        last: "",
        body: "",
        idx: i + 1,
      }))
      .filter((n: any) => n.id);
    if (!nodes.length) nodes = this.nodesFrom(out);
    let goal = o.goal ? String(o.goal) : "";
    if (!goal) {
      const gm = /^Workflow\s+"([^"]+)"/.exec(String(out || ""));
      if (gm) goal = gm[1];
    }
    return { goal, nodes };
  },
  same(a: any, b: any) {
    if (a.goal && b.goal) return a.goal === b.goal;
    if (a.ids && b.ids) return a.ids === b.ids;
    return false;
  },
  applyOut(out: string) {
    if (!out) return;
    this.out = out;
    for (const e of this.nodesFrom(out)) {
      let n = this.nodes.find((x: any) => x.id === e.id);
      if (!n) {
        e.idx = this.nodes.length + 1;
        this.nodes.push(e);
        n = e;
      } else {
        n.st = e.st;
        if (e.role && !n.role) n.role = e.role;
      }
      n.body = this.slice(out, n.id);
    }
  },
  queue() {
    if (!pendingByName.workflow) pendingByName.workflow = [];
    if (this.id && !pendingByName.workflow.includes(this.id)) pendingByName.workflow.push(this.id);
  },
  upsert(args: string, out: string) {
    const parsed = this.parse(args, out);
    const want = this.ident(args, out);
    if (this.el && this.el.isConnected && this.same(want, this.ident(this.args, this.out))) {
      if (args) this.args = args;
      if (parsed.goal) this.goal = parsed.goal;
      if (parsed.nodes.length && !this.nodes.length) this.nodes = parsed.nodes;
      if (out) {
        this.applyOut(out);
        this.done = true;
        if (cards[this.id]) {
          cards[this.id].out = this.out;
          cards[this.id].done = true;
          cards[this.id].args = this.args;
        }
      } else if (!this.done) this.queue();
      this.paint();
      return this.id;
    }
    finishWork();
    seq++;
    this.id = "t" + seq;
    this.args = args || "";
    this.goal = parsed.goal;
    this.nodes = parsed.nodes;
    this.out = out || "";
    this.done = !!out;
    this.openId = "";
    if (out) this.applyOut(out);
    this.el = document.createElement("section");
    this.el.className = "flow";
    this.el.id = this.id;
    this.el.dataset.ty = "agent";
    th.appendChild(this.el);
    cards[this.id] = {
      el: this.el,
      name: "workflow",
      ty: "agent",
      args: this.args,
      out: this.out,
      done: this.done,
    };
    if (!this.done) this.queue();
    this.paint();
    curAsst = null;
    scrl();
    return this.id;
  },
  event(idx: number, kind: string, text: string) {
    if (!this.el || !this.el.isConnected || this.done) return false;
    let n = kind === "notice" && text ? this.nodes.find((x: any) => x.id === text) : null;
    if (!n) n = this.nodes.find((x: any) => x.idx === Number(idx));
    if (!n) return false;
    if (kind === "notice") n.st = n.st === "wait" ? "run" : n.st;
    else if (kind === "tool_start") {
      n.st = "run";
      n.last = text || n.last;
    } else if (kind === "tool_done") n.last = text || n.last;
    else if (kind === "finished") n.st = n.st === "fail" ? "fail" : "ok";
    else if (kind === "tool_failed") n.st = "fail";
    this.paint();
    return true;
  },
  finish(out: string) {
    this.applyOut(out);
    this.done = true;
    if (cards[this.id]) {
      cards[this.id].out = this.out;
      cards[this.id].done = true;
    }
    this.paint();
  },
  nodeHtml(n: any) {
    const open = this.openId === n.id && n.body;
    const act2 = n.st === "run" ? n.last || "running" : n.st === "fail" ? "fail" : n.st === "skip" ? "skip" : "";
    return (
      '<li class="flow-n ' +
      n.st +
      (open ? " open" : "") +
      '" data-id="' +
      esc(n.id) +
      '"><i class="flow-dot"></i><div class="flow-main"><div class="flow-row"><b>' +
      esc(n.id) +
      "</b>" +
      (n.role ? "<em>" + esc(n.role) + "</em>" : "") +
      (act2 ? '<span class="flow-act">' + esc(act2) + "</span>" : "") +
      "</div>" +
      (open ? '<pre class="flow-body">' + esc(n.body) + "</pre>" : "") +
      "</div></li>"
    );
  },
  paint() {
    if (!this.el) return;
    const doneN = this.nodes.filter((n: any) => n.st === "ok" || n.st === "fail" || n.st === "skip").length;
    const meta = this.nodes.length ? doneN + "/" + this.nodes.length : "";
    this.el.classList.toggle("done", this.done);
    this.el.innerHTML =
      '<div class="flow-hd"><span class="flow-k">workflow</span>' +
      (this.goal ? '<div class="flow-goal">' + esc(this.goal) + "</div>" : "") +
      (meta ? '<div class="flow-meta">' + esc(meta) + "</div>" : "") +
      '</div><ol class="flow-list">' +
      this.nodes.map((n: any) => this.nodeHtml(n)).join("") +
      "</ol>";
    const hd = this.el.querySelector(".flow-hd");
    if (hd) hd.onclick = () => inspect.open(this.el);
    this.el.querySelectorAll(".flow-n").forEach((li: any) => {
      li.onclick = (e: any) => {
        e.stopPropagation();
        const id = li.getAttribute("data-id");
        this.openId = this.openId === id ? "" : id;
        this.paint();
      };
    });
    if (inspect.src === this.id) inspect.paint(this.el);
  },
  html() {
    return this.el ? this.el.innerHTML : "";
  },
};
export function isWorkflow(name: string, args?: string, out?: string) {
  if (name === "workflow") return true;
  const o = parseToolArgs(args || "");
  if (Array.isArray(o.nodes) && o.nodes.length) return true;
  return /^Workflow\b/.test(String(out || ""));
}
export function addSub(idx: number, kind: string, text: string) {
  if (Flow.event(idx, kind, text)) return;
  // 其余 subagent 事件不再刷对话流(对齐 dsh:活动收进 jobs/活动条,不染 transcript);
  // SSE 的 subagent 活动仍由 /api/activity 轮询条呈现。
}
export function finishWork() {
  if (!workEl) return;
  workEl.querySelectorAll(".tcall:not(.done):not(.err)").forEach((d: any) => {
    d.classList.add("done");
    const g = d.querySelector(".st-glyph");
    if (g) {
      g.className = "st-glyph ok";
    }
  });
  refreshWorkSum(false);
  workEl.classList.remove("live");
  workEl.classList.remove("open");
  workEl = null;
}
export function stampTurn() {
  if (!turnAt) return;
  const sec = Math.max(1, Math.round((Date.now() - turnAt) / 1000));
  turnAt = 0;
  const label =
    sec < 60
      ? "用了 " + sec + "s"
      : "用了 " + Math.floor(sec / 60) + "m " + (sec % 60) + "s";
  const host =
    th.querySelector(".a-turn:last-of-type") ||
    th.querySelector(".work:last-of-type");
  if (!host || host.querySelector(".a-meta")) return;
  const m = document.createElement("div");
  m.className = "a-meta";
  m.textContent = label;
  host.prepend(m);
}
function pruneTranscript() {
  const kids = [...th.querySelectorAll(":scope > .u-turn, :scope > .a-turn")] as any[];
  const cap = 200;
  if (kids.length <= cap) return;
  const drop = kids.length - cap + 32;
  for (let i = 0; i < drop; i++) kids[i].remove();
  const more = $("hist-more");
  if (more) more.hidden = false;
}
export function addUser(txt: string, imgSrc?: string | null) {
  hideWelcome();
  finishWork();
  noteTurn();
  pruneTranscript();
  const t = document.createElement("div");
  t.className = "u-turn";
  t.innerHTML =
    '<div class="u-bub"></div><div class="u-ops"><button type="button" class="copy-chip" title="复制">⧉</button><button type="button" class="undo-chip" title="撤销">↶</button></div>';
  const bub = t.querySelector(".u-bub")!;
  if (imgSrc) {
    const im = document.createElement("img");
    im.className = "u-img";
    im.alt = "image";
    im.src = imgSrc;
    bub.appendChild(im);
  }
  const shown = String(txt || "").replace(/\s*\[image\]\s*$/, "").replace(/^\[image\]$/, "");
  if (shown) {
    const s = document.createElement("span");
    s.textContent = shown;
    bub.appendChild(s);
    // 折叠阈值:长文本且多行,收为 7 行内 + 展开钮(dsh 用户消息折叠开头同法)
    const tlines = shown.split("\n");
    const long = shown.length > 340 && (tlines.length > 7 || shown.length > 900);
    if (long) {
      bub.classList.add("folded");
      const more = document.createElement("button");
      more.type = "button";
      more.className = "fold-more";
      more.textContent = "展开 ▾";
      more.onclick = () => bub.classList.remove("folded");
      bub.appendChild(document.createElement("br"));
      bub.appendChild(more);
    }
  } else if (!imgSrc) {
    bub.textContent = txt || "";
  }
  const rawUser = shown || txt || "";
  (t.querySelector(".copy-chip") as HTMLElement).onclick = () => clipText(rawUser, "已复制", "复制失败");
  (t.querySelector(".undo-chip") as HTMLElement).onclick = () => {
    act({ act: "undo" }, (j) => {
      showToast(j && j.ok ? "已撤销" : "无可撤销");
      setTimeout(() => location.reload(), 400);
    });
  };
  // 轮首时间戳(dsh 用户消息行 12px 灰):每次用户消息记录发问时刻
  const ts = document.createElement("div");
  ts.className = "turn-ts";
  ts.textContent = new Date().toTimeString().slice(0, 5);
  th.appendChild(ts);
  th.appendChild(t);
  scrl();
  curAsst = null;
}
export function asstEl() {
  if (!curAsst) {
    curAsst = document.createElement("div");
    curAsst.className = "a-turn";
    curAsst.innerHTML = '<div class="a-msg"><div class="md"></div></div>';
    th.appendChild(curAsst);
    scrl();
  }
  return curAsst;
}
let mdTimer: any = 0;
export function paintAsst(final?: boolean) {
  if (!curAsst) return;
  const e = curAsst.querySelector(".md");
  if (!e) return;
  const raw = e.dataset.raw || "";
  // 未变不画 —— 流式期 dataset.raw 涨但定时器空跑时省一次全量重排。
  if (!final && e.dataset.painted === String(raw.length)) return;
  e.dataset.painted = String(raw.length);
  e.innerHTML = md(final ? raw : closeFences(raw));
  scrl();
}
export function addAsst(txt: string) {
  if (!txt) return;
  const el = asstEl();
  el.classList.add("gen");
  const e = el.querySelector(".md");
  e.dataset.raw = (e.dataset.raw || "") + txt;
  if (!mdTimer) {
    // 自适应节流:回复越长全量重排越贵,间隔跟着涨(80→160→280ms)。
    const n = e.dataset.raw.length;
    const iv = n > 20000 ? 280 : n > 5000 ? 160 : 80;
    mdTimer = setTimeout(() => {
      mdTimer = 0;
      paintAsst(false);
    }, iv);
  }
  scrl();
}
export function finishAsst() {
  if (mdTimer) {
    clearTimeout(mdTimer);
    mdTimer = 0;
  }
  if (curAsst) {
    const e = curAsst.querySelector(".md");
    const raw = e.dataset.raw || e.textContent;
    e.dataset.raw = raw;
    e.dataset.painted = String(raw.length);
    e.innerHTML = md(raw);
    curAsst.classList.remove("gen");
    if (!curAsst.querySelector(".a-ops")) {
      const ops = document.createElement("div");
      ops.className = "a-ops";
      ops.innerHTML =
        '<button type="button" class="copy-a" title="复制">⧉</button>' +
        (chatH.getLastUser() ? '<button type="button" class="redo-a" title="重新生成">↻</button>' : "");
      (ops.querySelector(".copy-a") as HTMLElement).onclick = () => clipText(raw, "已复制", "复制失败");
      const redo = ops.querySelector(".redo-a") as HTMLElement | null;
      if (redo) redo.onclick = () => sendPlain(chatH.getLastUser());
      curAsst.appendChild(ops);
    }
    pluginEmit("message-rendered", {
      role: "assistant",
      text: raw,
      element: e,
    });
    curAsst = null;
  }
}
export function addRsn(txt: string) {
  if (!txt) return;
  if (!rsnEl) {
    const el = document.createElement("div");
    el.className = "think";
    el.innerHTML =
      '<button type="button" class="think-sum"><span class="work-caret">▸</span>' +
      ico("think") +
      '<span class="think-txt">思考中</span></button><pre class="tk"></pre>';
    (el.querySelector(".think-sum") as HTMLElement).onclick = () => el.classList.toggle("open");
    th.appendChild(el);
    rsnEl = el;
    scrl();
  }
  const tc = rsnEl.querySelector(".tk");
  // 流式 chunk 挤压成词,逐 chunk 换行会每词一行(客实测截图)。
  // 与 addAsst 同法:累积 raw + 节流重画,断行只落句读/换行处。
  tc.dataset.raw = (tc.dataset.raw || "") + txt;
  if (!rsnTm) {
    rsnTm = setTimeout(() => {
      rsnTm = 0;
      paintRsn();
    }, 90);
  }
  scrl();
  if (inspect.thinkEl === rsnEl && $("inspect") && !$("inspect")!.hidden) inspect.openThink(rsnEl);
}
let rsnTm: any = 0;
function paintRsn() {
  if (!rsnEl) return;
  const tc = rsnEl.querySelector(".tk");
  const raw = tc.dataset.raw || "";
  // 断行:句读/分号/引号后换行;压缩连续换行;黏合流式碎片
  let out = raw
    .replace(/([。！？!?;；]|：|——|\.{2,}|\n)/g, "$1\n")
    .replace(/\n{2,}/g, "\n\n")
    .trim();
  tc.textContent = out;
}
export function finishRsn() {
  if (!rsnEl) return;
  paintRsn();
  rsnTm && (clearTimeout(rsnTm), (rsnTm = 0));
  const txt = rsnEl.querySelector(".think-txt");
  if (txt) txt.textContent = "Thought";
  rsnEl = null;
}
// 工具卡
const cards: Record<string, any> = {};
let seq = 0;
const pendingByName: Record<string, string[]> = {};
export const inspect: any = {
  src: "",
  kind(d: any) {
    if (!d) return "Tool";
    const ty = d.dataset.ty;
    if (ty === "diff") return "Diff";
    if (ty === "code") return "File";
    if (ty === "term") return "Output";
    if (ty === "todo") return "Plan";
    if (ty === "agent") return (cards[d.id] && cards[d.id].name) === "workflow" ? "Workflow" : "Agent";
    const n = (cards[d.id] && cards[d.id].name) || "";
    if (/^(ls|find)$/.test(n)) return "List";
    if (/^(grep|search)$/.test(n)) return "Search";
    return n || "Output";
  },
  pathOf(d: any) {
    const c = cards[d.id];
    if (!c) return "";
    const o = parseToolArgs(c.args);
    return String(o.path || o.file || "");
  },
  title(d: any) {
    const p = this.pathOf(d);
    if (p) return p.split(/[/\\]/).pop() || p;
    const c = cards[d.id];
    if (!c) return "Inspect";
    const o = parseToolArgs(c.args);
    if (c.name === "workflow") return String(o.goal || "workflow");
    return String(o.command || c.name || "Inspect");
  },
  workEl: null,
  setHead(k: string, t: string) {
    const hk = $("inspK");
    const ht = $("inspT");
    if (ht) {
      ht.textContent = t || k || "";
      ht.title = t || k || "";
    }
    if (hk) {
      hk.textContent = k && k !== t ? k : "";
      hk.hidden = !hk.textContent;
    }
  },
  show() {
    const el = $("inspect");
    if (el) el.hidden = false;
  },
  open(d: any) {
    if (!d) return;
    this.workEl = null;
    if (this.src && cards[this.src]) cards[this.src].el.classList.remove("watching");
    this.src = d.id;
    d.classList.add("watching");
    this.show();
    this.paintInto(d, $("inspBd"));
  },
  thinkEl: null,
  openThink(el: any) {
    if (!el) return;
    this.workEl = null;
    this.thinkEl = el;
    this.src = "";
    this.show();
    this.setHead("Thought", "Thought");
    const txt = el.querySelector(".tk");
    const box = document.createElement("div");
    box.className = "insp-think";
    box.textContent = txt ? txt.textContent : "";
    const host = $("inspBd");
    if (host) host.replaceChildren(box);
  },

  close() {
    const el = $("inspect");
    if (!el) return;
    if (this.src && cards[this.src]) cards[this.src].el.classList.remove("watching");
    this.src = "";
    this.workEl = null;
    this.thinkEl = null;
    el.hidden = true;
    const bd = $("inspBd");
    if (bd) bd.innerHTML = "";
  },
  async paintInto(d: any, host: any) {
    if (!d || !host) return;
    const c = cards[d.id];
    this.setHead(this.kind(d), this.title(d));
    if (c && !c.done) {
      if (c.name === "workflow" || d.classList.contains("flow")) {
        host.innerHTML = '<div class="flow">' + Flow.html() + "</div>";
        return;
      }
      host.innerHTML = '<div class="insp-wait">Running…</div>';
      return;
    }
    let out = (c && c.out) || "";
    const path = this.pathOf(d);
    if (path && d.dataset.ty === "code") {
      try {
        const r = await fetch("/api/file?" + wsp + "path=" + encodeURIComponent(path));
        if (r.ok) {
          const j = await r.json();
          if (j && j.text) out = j.text;
        }
      } catch {}
    }
    if (!out) {
      host.innerHTML = '<div class="insp-wait">No output.</div>';
      return;
    }
    d.dataset.out = out;
    host.replaceChildren(toolBody(d.dataset.ty || "code", out, path, c && c.args));
  },
  paint(d: any) {
    this.paintInto(d, $("inspBd"));
  },
  init() {
    const x = $("inspX");
    if (x) x.onclick = () => inspect.close();
  },
};
export function addTool(name: string, args?: string) {
  if (isWorkflow(name, args)) return Flow.upsert(args || "", "");
  seq++;
  const id = "t" + seq;
  const ty = toolType(name);
  const d = document.createElement("div");
  d.className = "tcall";
  d.id = id;
  d.dataset.ty = ty;
  d.innerHTML =
    '<div class="bh">' +
    '<span class="st-glyph run"></span>' +
    ico(icoKind(name)) +
    '<span class="a">' +
    esc(name) +
    '</span><span class="p">' +
    esc(argsPreview(args || "")) +
    '</span></div><div class="bb"><div class="bb-pad"></div></div>';
  (d.querySelector(".bh") as HTMLElement).onclick = () => inspect.open(d);
  const w = ensureWork();
  workCounts[workKind(name)]++;
  refreshWorkSum(true);
  w.querySelector(".work-list").appendChild(d);
  scrl();
  cards[id] = { el: d, name, ty, args: args || "", out: "", done: false };
  (pendingByName[name] || (pendingByName[name] = [])).push(id);
  // 工具打断流式回复:前缀文本若已吐出即收尾(修 gen 悬挂——旧 turn 永久带
  // 生成光标的病),空的话直接丢弃空壳。
  if (curAsst) {
    const e = curAsst.querySelector(".md");
    if (e && (e.dataset.raw || "").length > 0) finishAsst();
    else {
      curAsst.classList.remove("gen");
      curAsst = null;
    }
  } else curAsst = null;
  return id;
}
export async function fillTool(d: any) {
  const ty = d.dataset.ty || "sum";
  let out = d.dataset.out || "";
  const art = artifactName(out);
  if (art && !d.dataset.full) {
    try {
      const r = await fetch("/api/artifact?name=" + encodeURIComponent(art));
      const j = await r.json();
      if (j && j.ok && typeof j.text === "string") {
        d.dataset.full = "1";
        d.dataset.out = j.text;
        out = j.text;
      }
    } catch {}
  }
  const bd = d.querySelector(".bb-pad")!;
  const card = cards[d.id];
  const custom = card && getToolRenderer(card.name);
  if (custom) {
    try {
      const node = custom({
        name: card.name,
        args: card.args,
        output: out,
        error: d.classList.contains("err"),
        element: d,
      });
      if (node instanceof Node) {
        bd.replaceChildren(node);
        return;
      }
    } catch (x) {
      console.error("[piz plugin]", x);
    }
  }
  const c = cards[d.id];
  const o = c ? parseToolArgs(c.args) : {};
  bd.replaceChildren(toolBody(ty, out, String(o.path || o.file || ""), (c && c.args) || ""));
}
export function toolDone(name: string, err?: boolean, summary?: string) {
  const q = pendingByName[name];
  const id = q && q.shift();
  if (!id) return;
  const c = cards[id];
  if (!c) return;
  const d = c.el;
  d.classList.add(err ? "err" : "done");
  const g = d.querySelector(".st-glyph");
  if (g) {
    g.className = "st-glyph " + (err ? "err" : "ok");
  }
  c.out = summary || "";
  c.done = true;
  d.dataset.out = c.out;
  if (name === "workflow") Flow.finish(c.out);
  if (name === "todo" && !err) planStrip(c);
  if (inspect.src === id && $("inspect") && !$("inspect")!.hidden) inspect.paint(d);
  else if (err) inspect.open(d);
}
// 审批
export function addPerm(id: string, name: string, args: string) {
  hideWelcome();
  const d = document.createElement("div");
  d.className = "pc";
  d.dataset.pid = id;
  const o = parseToolArgs(args);
  const kind = name === "bash" ? "shell" : "file";
  let body = "";
  if (kind === "shell") {
    body =
      '<div class="body"><div class="shell-cmd"><span class="shell-dollar">$</span>' +
      esc(String(o.command || args || "").slice(0, 300)) +
      "</div></div>";
  } else
    body =
      '<div class="body"><pre class="shell-cmd">' +
      esc(String(o.path || args || "").slice(0, 300)) +
      "</pre></div>";
  d.innerHTML =
    '<div class="ah"><span class="ah-ic">?</span><span class="akind">需要许可</span><span class="apath">' +
    esc(name) +
    (o.path && kind === "shell" ? "  " + esc(String(o.path).slice(0, 80)) : "") +
    '</span><span class="aw">等待审批</span></div>' +
    body +
    '<div class="pb"><button class="ok">允许</button><button class="alw">本会话总是</button><button class="no">拒绝</button></div>';
  (d.querySelector(".ok") as HTMLElement).onclick = (e: any) => {
    e.stopPropagation();
    appr(d, id, true, false);
  };
  (d.querySelector(".alw") as HTMLElement).onclick = (e: any) => {
    e.stopPropagation();
    appr(d, id, true, true);
  };
  (d.querySelector(".no") as HTMLElement).onclick = (e: any) => {
    e.stopPropagation();
    appr(d, id, false, false);
  };
  const dk = $("dock")!;
  dk.appendChild(d);
  scrl();
}
async function appr(card: any, id: string, allow: boolean, always: boolean) {
  card.querySelectorAll("button").forEach((b: any) => (b.disabled = true));
  try {
    if (always) await setApproval("yolo");
    const r = await fetch("/api/approve", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ id, allow }),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || j.ok === false) {
      showToast(j.error || "审批失败");
      card.querySelectorAll("button").forEach((b: any) => (b.disabled = false));
      return;
    }
    card.remove();
  } catch {
    showToast("审批失败");
    card.querySelectorAll("button").forEach((b: any) => (b.disabled = false));
  }
}
export function addNotice(txt: string) {
  if (!txt) return;
  hideWelcome();
  const d = document.createElement("div");
  d.className = "sys-line";
  d.textContent = txt;
  th.appendChild(d);
  scrl();
}
// 压缩检查点(dsh checkpoint row):消息流内一行,点开摘要;静止时仅悬停显示展开指示
let cpOpen: any = null;
export function addCheckpoint(summary: string, folded: number, kept: number) {
  hideWelcome();
  if (cpOpen) {
    cpOpen.classList.remove("open");
    cpOpen = null;
  }
  const d = document.createElement("div");
  d.className = "cp";
  const n = Number(folded) || 0;
  const k = Number(kept) || 0;
  const same = th.lastElementChild && th.lastElementChild.classList && th.lastElementChild.classList.contains("cp");
  d.innerHTML =
    '<button type="button" class="cp-sum" aria-expanded="false"><span class="cp-ic">⧉</span><span class="cp-t">上下文已压缩</span>' +
    (same ? "" : "<span class=\"cp-meta\">折叠 " + n + " 条 · 保留 " + fmtK(k) + " tok</span>") +
    '<span class="cp-caret">▸</span></button>' +
    '<div class="cp-body"></div>';
  const bd = d.querySelector(".cp-body")!;
  if (summary) bd.textContent = summary;
  (d.querySelector(".cp-sum") as HTMLElement).onclick = () => {
    d.classList.toggle("open");
    (d.querySelector(".cp-sum") as HTMLElement).setAttribute("aria-expanded", String(d.classList.contains("open")));
  };
  th.appendChild(d);
  cpOpen = d;
  scrl();
}
// todo 计划条(dsh input dock 计划条之形):todo 工具完成时,输入区上方一条
// 📋 计划 · x/y 完成,点击打开检视查看全表;无计划即隐藏。
export function planStrip(c: any) {
  const txt = c.out || "";
  const done = (txt.match(/\[x\]/gi) || []).length;
  const open = (txt.match(/\[ \]/g) || []).length;
  const total = done + open;
  const strip = $("planStrip") as HTMLElement | null;
  if (!strip || !total) return;
  strip.hidden = false;
  strip.innerHTML =
    '<button type="button" class="plan-sum"><span class="plan-ic">📋</span><span class="plan-t">计划</span><span class="plan-meta">' +
    done +
    "/" +
    total +
    " 完成</span><span class=\"plan-caret\">▸</span></button>";
  (strip.querySelector(".plan-sum") as HTMLElement).onclick = () => inspect.open(c.el);
}
function fmtK(n: number) {
  if (n >= 1000) {
    const k = n / 1000;
    return (k >= 100 ? Math.round(k) : Math.round(k * 10) / 10) + "k";
  }
  return String(Math.round(n));
}
function agentHtml(out: string, args: string) {
  if (Flow.el && (Flow.out === out || Flow.args === args || parseToolArgs(args).nodes)) {
    return Flow.html();
  }
  const o = parseToolArgs(args);
  let html = "";
  const desc = o.description || o.task || o.prompt || "";
  if (desc) html += '<div class="agent-desc">' + esc(desc) + "</div>";
  if (out) html += '<pre class="code">' + esc(out) + "</pre>";
  return html;
}
export function toolBody(ty: string, out: string, path: string, args?: string): any {
  const text = String(out || "");
  if (ty === "term") {
    const pre = document.createElement("pre");
    pre.className = "term";
    // 与 code 同帽:超长输出别让 ansi 逐字扫拖住主线程。
    const capped = text.length > 32000 ? text.slice(0, 32000) + "\n…" : text;
    pre.innerHTML = ansiHtml(capped);
    return pre;
  }
  if (ty === "diff") {
    const box = document.createElement("div");
    box.className = "diff-view";
    box.innerHTML = diffHtml(text);
    return box;
  }
  if (ty === "todo") {
    const box = document.createElement("div");
    box.className = "todo-view";
    box.innerHTML = todoHtml(text);
    return box;
  }
  if (ty === "agent") {
    const box = document.createElement("div");
    box.className = "agent-view";
    box.innerHTML = agentHtml(text, args || "");
    return box;
  }
  if (isMarkdownPath(path) || (ty === "code" && looksLikeMd(text))) {
    const box = document.createElement("div");
    box.className = "insp-md";
    box.innerHTML = renderMd(text);
    return box;
  }
  const pre = document.createElement("pre");
  pre.className = "code";
  pre.textContent = text.length > 32000 ? text.slice(0, 32000) + "\n…" : text;
  return pre;
}

// 验证钩(Playwright 驱动;生产无副作用,不挂全局业务)
if (typeof window !== "undefined") {
  (window as any).pizDbg = { addCheckpoint, planStrip };
}
