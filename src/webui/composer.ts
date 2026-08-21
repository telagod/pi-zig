// composer.ts —— 发送生命周期:运行态/队列/活动条、SSE 事件路由(ev.onmessage)、
// 输入框键盘与草稿、图片黏附、sendPlain/send。
// 自 webui.js 切出。聊天渲染直引 chat.ts,插件直引 plugins.ts,无环无钩。
import { $, esc, fmtTok } from "./util";
import { sess, wsp, prefs } from "./state";
import { showToast } from "./ui";
import { act, loadSessions } from "./sessions";
import { autosizeInp, saveDraft, clearDraft, pushHist, histPrev, histNext } from "./store";
import { ev } from "./stream";
import {
  hideSlash, hideBang, slashOpen, slashMove, slashComplete, slashPick,
  updateSlash, runSlash, findSlash,
} from "./slash";
import {
  addUser, addAsst, finishAsst, addRsn, finishRsn, addTool, toolDone,
  addSub, addPerm, addNotice, finishWork, stampTurn, noteTurn,
} from "./chat";
import {
  applyThink, applyTitle, renderModel, setCost, setCtx, setTurnMeta, getVision,
} from "./model";
import { pluginEmit } from "./plugins";


let running = false;
let lastUser = "";
let lastImgUrl: any = null;
let pending: string[] = [];
export const getRunning = () => running;
export const getLastUser = () => lastUser;
export const setLastUser = (v: string) => { lastUser = v; };
export const clearPending = () => { pending = []; };
export function refreshSend() {
  const t = ($("inp") as HTMLTextAreaElement).value.trim();
  const stop = running && !t;
  $("send")!.textContent = stop ? "■" : "➤";
  $("send")!.classList.toggle("stop", stop);
  $("send")!.title = stop ? "停止" : running ? "接着发" : "发送";
  const inp = $("inp") as HTMLTextAreaElement | null;
  if (inp) {
    inp.placeholder = running
      ? "接着发…"
      : inp.dataset.ph || inp.placeholder;
  }
}
export function setRun(r: boolean) {
  running = r;
  refreshSend();
  if (r) ensureActPoll();
}
let actTimer: any = 0;
function fmtActChip(a: any) {
  const sec = a.ms < 10000 ? (a.ms / 1000).toFixed(1) : String(Math.round(a.ms / 1000));
  const lim = a.limit_ms && !a.detached ? "/" + Math.round(a.limit_ms / 1000) + "s" : "";
  const by = a.bytes ? " · " + fmtTok(a.bytes) : "";
  return (
    '<span class="act-chip' +
    (a.detached ? " bg" : "") +
    '">' +
    esc(a.name || "job") +
    " " +
    sec +
    "s" +
    lim +
    by +
    (a.detached ? " · bg" : "") +
    "</span>"
  );
}
async function tickActivity() {
  const el = $("actStrip");
  if (!el) return 0;
  try {
    const r = await fetch("/api/activity");
    const list = await r.json();
    if (!list || !list.length) {
      el.hidden = true;
      el.innerHTML = "";
      return 0;
    }
    el.hidden = false;
    el.innerHTML = list.map(fmtActChip).join("");
    return list.length;
  } catch {
    return 0;
  }
}
export function ensureActPoll() {
  if (actTimer) return;
  actTimer = setInterval(async () => {
    const n = await tickActivity();
    if (!n && !running) {
      clearInterval(actTimer);
      actTimer = 0;
    }
  }, 400);
}
export function renderQueue() {
  const box = $("qbox"),
    items = $("qItems"),
    count = $("qCount");
  if (!box || !items) return;
  if (!pending.length) {
    box.hidden = true;
    items.innerHTML = "";
    return;
  }
  box.hidden = false;
  count!.textContent = pending.length === 1 ? "待发" : pending.length + " 条待发";
  items.innerHTML = pending
    .map((t) => '<div class="q-item">' + esc(t) + "</div>")
    .join("");
}
export function dropPending(text: string) {
  const i = pending.indexOf(text);
  if (i >= 0) pending.splice(i, 1);
  else if (pending.length) pending.shift();
  renderQueue();
}
ev.onmessage = (e) => {
  let evt;
  try {
    evt = JSON.parse(e.data);
  } catch {
    return;
  }
  if (evt.session && evt.session !== sess) return;
  pluginEmit("event", evt);
  pluginEmit(evt.type, evt);
  switch (evt.type) {
    case "user_message":
      lastUser = evt.text || lastUser;
      dropPending(evt.text);
      addUser(evt.has_image && !evt.text ? "[image]" : evt.has_image ? (evt.text || "") + "  [image]" : (evt.text || ""), evt.image_file ? "/api/image?name=" + encodeURIComponent(evt.image_file) : evt.has_image ? lastImgUrl : null);
      lastImgUrl = null;
      noteTurn();
      setRun(true);
      break;
    case "queued":
      if (evt.text && pending.indexOf(evt.text) < 0) pending.push(evt.text);
      renderQueue();
      break;
    case "title":
      if (evt.title) {
        applyTitle(evt.title);
        if ($("hSes") && sess !== "default") $("hSes")!.textContent = evt.title;
        if ($("tbSe") && sess !== "default") $("tbSe")!.textContent = evt.title;
        loadSessions();
      }
      break;
    case "notice":
      addNotice(evt.text);
      break;
    case "reasoning":
      setRun(true);
      addRsn(evt.text);
      break;
    case "message":
      setRun(true);
      addAsst(evt.text);
      break;
    case "tool_call":
      addTool(evt.name, evt.args);
      break;
    case "tool_result":
      toolDone(evt.name, evt.error, evt.summary);
      break;
    case "subagent":
      addSub(evt.idx, evt.kind, evt.text);
      break;
    case "permission":
      addPerm(evt.id, evt.name, evt.args);
      break;
    case "permission_result":
      {
        const pc = document.querySelector(
          '.pc[data-pid="' + evt.id + '"]',
        );
        if (pc) pc.remove();
      }
      break;
    case "turn_end":
      finishAsst();
      finishRsn();
      finishWork();
      stampTurn();
      setRun(false);
      if (
        prefs.notify &&
        window.Notification &&
        Notification.permission === "granted"
      ) {
        try {
          new Notification("piz", { body: "本轮已完成" });
        } catch {}
      }
      if (prefs.sound) {
        try {
          const AC = (window as any).AudioContext || (window as any).webkitAudioContext;
          const ac = new AC();
          const o = ac.createOscillator();
          const g = ac.createGain();
          o.frequency.value = 880;
          g.gain.value = 0.04;
          o.connect(g);
          g.connect(ac.destination);
          o.start();
          o.stop(ac.currentTime + 0.08);
        } catch {}
      }
      break;
    case "status":
      if (evt.cost !== undefined) setCost(evt.cost);
      if (evt.pct !== undefined || evt.used !== undefined) {
        setCtx(evt.pct, evt.used, evt.window);
      }
      setTurnMeta(evt);
      if (evt.model) renderModel();
      if (evt.think) applyThink(evt.think);
      break;
  }
};
// ---- 发送 ----
($("qClr") as HTMLElement).onclick = () => runSlash({ name: "/queue" }, "");
($("send") as HTMLElement).onclick = () => {
  if (running && !($("inp") as HTMLTextAreaElement).value.trim()) {
    fetch(
      "/api/interrupt?" + wsp + "session=" + encodeURIComponent(sess),
      { method: "POST" },
    );
  } else send();
};
export function toggleKeysHint() {
  const el = $("keysHint");
  if (!el) return;
  if (!el.hidden) {
    el.hidden = true;
    el.innerHTML = "";
    return;
  }
  el.hidden = false;
  el.innerHTML =
    "<div><kbd>/</kbd> 命令 · <kbd>@./</kbd> 文件 · <kbd>!</kbd> 本页命令</div>" +
    "<div><kbd>j</kbd> 任务 · <kbd>u</kbd> 用量 · <kbd>g</kbd> 差异 · <kbd>l</kbd> 日志 · <kbd>c</kbd> 复制 · <kbd>s</kbd> 沙箱 · <kbd>?</kbd> 本卡</div>" +
    "<div><kbd>Ctrl</kbd><kbd>K</kbd> 搜会话 · <kbd>Ctrl</kbd><kbd>Shift</kbd><kbd>C</kbd> 复制回复</div>" +
    "<div><kbd>Ctrl</kbd><kbd>Shift</kbd><kbd>R</kbd> 重发 · <kbd>Ctrl</kbd><kbd>V</kbd> 贴图 · <kbd>Esc</kbd> 关</div>";
}
($("inp") as HTMLElement).addEventListener("keydown", (e: any) => {
  if (
    !e.isComposing &&
    !e.ctrlKey &&
    !e.metaKey &&
    !e.altKey &&
    !($("inp") as HTMLTextAreaElement).value &&
    !slashOpen()
  ) {
    if (e.key === "u" || e.key === "U") {
      e.preventDefault();
      runSlash({ name: "/usage" }, "");
      return;
    }
    if (e.key === "j" || e.key === "J") {
      e.preventDefault();
      runSlash({ name: "/jobs" }, "");
      return;
    }
    if (e.key === "d" || e.key === "D") {
      e.preventDefault();
      runSlash({ name: "/doctor" }, "");
      return;
    }
    if (e.key === "g" || e.key === "G") {
      e.preventDefault();
      runSlash({ name: "/diff" }, "");
      return;
    }
    if (e.key === "l" || e.key === "L") {
      e.preventDefault();
      runSlash({ name: "/log" }, "");
      return;
    }
    if (e.key === "r" || e.key === "R") {
      e.preventDefault();
      runSlash({ name: "/redo" }, "");
      return;
    }
    if (e.key === "c" || e.key === "C") {
      e.preventDefault();
      runSlash({ name: "/copy" }, "");
      return;
    }
    if (e.key === "s" || e.key === "S") {
      e.preventDefault();
      const p = $("sbPill");
      if (p) p.click();
      else runSlash({ name: "/sandbox" }, "");
      return;
    }
    if (e.key === "?") {
      e.preventDefault();
      toggleKeysHint();
      return;
    }
  }
  if (slashOpen()) {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      slashMove(1);
      return;
    }
    if (e.key === "ArrowUp") {
      e.preventDefault();
      slashMove(-1);
      return;
    }
    if (e.key === "Tab") {
      e.preventDefault();
      slashComplete();
      return;
    }
    if (e.key === "Enter") {
      e.preventDefault();
      slashPick();
      return;
    }
    if (e.key === "Escape") {
      e.preventDefault();
      hideSlash();
      return;
    }
  }
  const inpEl = $("inp") as HTMLTextAreaElement;
  if (
    e.key === "ArrowUp" &&
    !e.shiftKey &&
    inpEl.selectionStart === 0 &&
    inpEl.value.indexOf("\n") < 0
  ) {
    e.preventDefault();
    histPrev();
    return;
  }
  if (
    e.key === "ArrowDown" &&
    !e.shiftKey &&
    inpEl.selectionStart === inpEl.value.length &&
    inpEl.value.indexOf("\n") < 0
  ) {
    e.preventDefault();
    histNext();
    return;
  }
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    send();
  }
});
($("inp") as HTMLElement).addEventListener("input", () => {
  const kh = $("keysHint");
  if (kh && !kh.hidden && ($("inp") as HTMLTextAreaElement).value) {
    kh.hidden = true;
    kh.innerHTML = "";
  }
  autosizeInp();
  saveDraft();
  updateSlash();
  refreshSend();
});
let pendingImg: any = null;
export function paintImgChip() {
  let c = $("img-chip") as HTMLElement | null;
  if (!c) {
    c = document.createElement("div");
    c.id = "img-chip";
    c.className = "img-chip";
    const box = $("inp")!.parentNode;
    if (box) box.insertBefore(c, $("inp"));
  }
  if (!pendingImg) {
    c.hidden = true;
    c.innerHTML = "";
    return;
  }
  c.hidden = false;
  c.innerHTML = "<img alt=\"\" /><span>image</span><button type=button>✕</button>";
  (c.querySelector("img") as HTMLImageElement).src = "data:" + pendingImg.mime + ";base64," + pendingImg.b64;
  (c.querySelector("button") as HTMLElement).onclick = () => {
    pendingImg = null;
    paintImgChip();
  };
}
export async function blobToChatImage(blob: Blob) {
  const bmp = await createImageBitmap(blob);
  const max = 1600;
  let w = bmp.width,
    h = bmp.height;
  if (w > max || h > max) {
    const s = max / Math.max(w, h);
    w = Math.round(w * s);
    h = Math.round(h * s);
  }
  const cv = document.createElement("canvas");
  cv.width = w;
  cv.height = h;
  cv.getContext("2d")!.drawImage(bmp, 0, 0, w, h);
  const url = cv.toDataURL("image/jpeg", 0.85);
  const i = url.indexOf(",");
  return { mime: "image/jpeg", b64: url.slice(i + 1) };
}
export async function attachClipboardImage() {
  if (navigator.clipboard && (navigator.clipboard as any).read) {
    try {
      const items = await (navigator.clipboard as any).read();
      for (const it of items) {
        const type = (it.types || []).find((t: string) => String(t).indexOf("image/") === 0);
        if (!type) continue;
        const blob = await it.getType(type);
        pendingImg = await blobToChatImage(blob);
        paintImgChip();
        return true;
      }
    } catch {}
  }
  return false;
}
document.addEventListener("paste", async (ev: any) => {
  const items = ev.clipboardData && ev.clipboardData.items;
  if (!items) return;
  for (const it of items) {
    if (it.type && it.type.indexOf("image/") === 0) {
      ev.preventDefault();
      const blob = it.getAsFile();
      if (!blob) return;
      try {
        pendingImg = await blobToChatImage(blob);
        paintImgChip();
      } catch {}
      return;
    }
  }
});
export async function sendPlain(t: string) {
  if (!t && !pendingImg) return;
  lastUser = t || "(image)";
  let img = pendingImg;
  lastImgUrl = img || null;
  pendingImg = null;
  if (img && !getVision()) {
    addNotice("image dropped: model has no vision");
    img = null;
    if (!t) {
      paintImgChip();
      return false;
    }
  }
  paintImgChip();
  setRun(true);
  let ok = false;
  try {
    const body: any = { text: t || "" };
    if (img) {
      body.image = img.b64;
      body.mime = img.mime;
    }
    const r = await fetch(
      "/api/chat?" + wsp + "session=" + encodeURIComponent(sess),
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      },
    );
    const j = await r.json().catch(() => ({}));
    if (!r.ok || j.ok === false) {
      showToast(j.error || "send failed");
    } else ok = true;
  } catch {
    showToast("send failed");
  }
  if (!ok) {
    // 失败不吞草稿:文本塞回输入框,图也还回 pending。
    setRun(false);
    if (t && $("inp")) {
      ($("inp") as HTMLTextAreaElement).value = t;
      autosizeInp();
      refreshSend();
    }
    if (img && !pendingImg) {
      pendingImg = img;
      paintImgChip();
    }
  }
  return ok;
}
export async function send() {
  hideSlash();
  hideBang();
  const t = ($("inp") as HTMLTextAreaElement).value.trim();
  if (!t && !pendingImg) return;
  if (t.startsWith("/")) {
    const space = t.indexOf(" ");
    const cmd = space < 0 ? t : t.slice(0, space);
    const arg = space < 0 ? "" : t.slice(space + 1);
    const item = findSlash(cmd);
    if (item) {
      ($("inp") as HTMLTextAreaElement).value = "";
      ($("inp") as HTMLTextAreaElement).style.height = "auto";
      clearDraft();
      hideSlash();
      refreshSend();
      pushHist(t);
      await runSlash(item, arg);
      return;
    }
  }
  ($("inp") as HTMLTextAreaElement).value = "";
  ($("inp") as HTMLTextAreaElement).style.height = "auto";
  clearDraft();
  pushHist(t);
  hideSlash();
  refreshSend();
  await sendPlain(t);
  // 桌面端发完回焦,接着打下一行;触屏不弹键盘。
  if (window.matchMedia("(hover: hover)").matches) $("inp")!.focus();
}
