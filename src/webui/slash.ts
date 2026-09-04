// slash.ts —— 斜杠命令目录/菜单/bang 提示/@文件补全 + runSlash 全分发。
// 自 webui.js 切出。聊天渲染/发送/模型态皆 main 之物,经 slashH 钩袋注入;
// 别名包装使本体调用点一字不改(唯活读之 bare var 改 H.getX())。
import { $, esc, rankSlash, hlSpan, fmtTok, downloadText } from "./util";
import { sess, ws, wsp, sessUrl, prefs } from "./state";
import { showToast, askText } from "./ui";
import { act, sessData } from "./sessions";
import { autosizeInp, saveDraft } from "./store";
import {
  setApproval, setSandbox, setThink, applySessionTitle,
  getCurModel, getCurTitle, getThink, getVision, getSandboxMode,
  approvalLabel, setApprovalMode, applySandboxLevel, applyThink,
} from "./model";
import { setScheme } from "./ui";

export const slashH: any = {};
const addUser = (...a: any[]) => slashH.addUser(...a);
const addAsst = (...a: any[]) => slashH.addAsst(...a);
const finishAsst = (...a: any[]) => slashH.finishAsst(...a);
const openSearch = (...a: any[]) => slashH.openSearch(...a);
const attachClipboardImage = (...a: any[]) => slashH.attachClipboardImage(...a);
const refreshSend = (...a: any[]) => slashH.refreshSend(...a);
const ensureActPoll = (...a: any[]) => slashH.ensureActPoll(...a);
const asstEl = (...a: any[]) => slashH.asstEl(...a);
const findInThread = (...a: any[]) => slashH.findInThread(...a);
const sendPlain = (...a: any[]) => slashH.sendPlain(...a);
const send = (...a: any[]) => slashH.send(...a);
const renderQueue = (...a: any[]) => slashH.renderQueue(...a);
const clipText = (...a: any[]) => slashH.clipText(...a);

export function findSlash(cmd: string) {
  return SLASH.find((s) => s.name === cmd);
}
export function applyHelpCatalog(j: any) {
  if (j && Array.isArray(j.commands) && j.commands.length) {
    SLASH = j.commands.map((c: any) => ({
      name: c.name,
      desc: c.desc,
      accepts: !!c.accepts,
    }));
    (window as any).HELP_KEYS = Array.isArray(j.keys) ? j.keys : (window as any).HELP_KEYS || [];
  }
}
export function loadHelpCatalog() {
  return fetch("/api/help?" + wsp + "session=" + encodeURIComponent(sess))
    .then((r) => r.json())
    .then(applyHelpCatalog)
    .catch(() => showToast("帮助目录加载失败"));
}
let SLASH: any[] = [
  { name: "/help", desc: "list commands" },
  { name: "/login", desc: "save API key", accepts: true },
  { name: "/new", desc: "新会话" },
  { name: "/clear", desc: "清空并重开" },
  { name: "/sessions", desc: "搜索会话" },
  { name: "/resume", desc: "切到第 n 个会话", accepts: true },
  { name: "/undo", desc: "撤销上一轮" },
  { name: "/compact", desc: "压缩上下文" },
  { name: "/fast-compress", desc: "快压状态" },
  { name: "/fork", desc: "派生会话" },
  { name: "/title", desc: "改会话标题", accepts: true },
  { name: "/model", desc: "切换模型" },
  { name: "/refresh", desc: "拉取 provider 模型列表" },
  { name: "/think", desc: "思考等级", accepts: true },
  { name: "/permissions", desc: "授权 yolo/ask/read-only", accepts: true },
  { name: "/sandbox", desc: "bash 沙箱 off/workspace/strict", accepts: true },
  { name: "/status", desc: "当前状态" },
  { name: "/doctor", desc: "环境体检" },
  { name: "/init", desc: "写 AGENTS.md（已有不覆盖）" },
  { name: "/diff", desc: "git status + diffstat" },
  { name: "/commit", desc: "提交已暂存（需说明）", accepts: true },
  { name: "/log", desc: "git log --oneline", accepts: true },
  { name: "/branch", desc: "当前与最近分支" },
  { name: "/mcp", desc: "MCP server 列表" },
  { name: "/reload", desc: "重读 settings.json" },
  { name: "/theme", desc: "外观 light/dark/system", accepts: true },
  { name: "/paste", desc: "从剪贴板附图" },
  { name: "/usage", desc: "token 账本" },
  { name: "/jobs", desc: "在跑 / 后台任务", accepts: true },
  { name: "/find", desc: "搜对话", accepts: true },
  { name: "/plan", desc: "写 PLAN.md 再执行", accepts: true },
  { name: "/queue", desc: "清空输入队列" },
  { name: "/memory", desc: "跨会话记忆", accepts: true },
  { name: "/plugins", desc: "列出或开关插件", accepts: true },
  { name: "/pkg", desc: "已装资源包" },
  { name: "/tree", desc: "消息列表" },
  { name: "/copy", desc: "复制最后一条回复" },
  { name: "/export", desc: "导出 HTML" },
  { name: "/dump", desc: "整段会话到剪贴板" },
  { name: "/redo", desc: "重发上一次输入" },
];
(window as any).HELP_KEYS = (window as any).HELP_KEYS || [
  { name: "@./path", desc: "embed a file" },
  { name: "!cmd", desc: "run shell, send to model" },
  { name: "!!cmd", desc: "run shell, show only" },
  { name: "?", desc: "shortcut overlay when empty" },
  { name: "c", desc: "copy last reply when empty" },
  { name: "d", desc: "doctor when empty" },
  { name: "g", desc: "git diff when empty" },
  { name: "l", desc: "git log when empty" },
  { name: "r", desc: "redo last input when empty" },
  { name: "s", desc: "sandbox picker when empty" },
  { name: "j", desc: "list jobs when empty" },
  { name: "u", desc: "token ledger when empty" },
  { name: "Esc", desc: "abort; empty again edits last" },
  { name: "Ctrl+C", desc: "clear; empty again quits" },
  { name: "Ctrl+D", desc: "empty again quits" },
  { name: "Tab", desc: "queue input while busy" },
  { name: "Ctrl+B", desc: "background while busy" },
  { name: "Ctrl+T", desc: "fold thinking" },
  { name: "Ctrl+O", desc: "fold tool output" },
  { name: "PgUp/PgDn", desc: "scroll transcript" },
  { name: "Ctrl+↑/↓", desc: "scroll a few lines" },
  { name: "wheel", desc: "scroll transcript" },
  { name: "Alt+,/.", desc: "think less / more" },
  { name: "Shift+↑/↓", desc: "think less / more" },
];
let slashItems: any[] = [],
  slashIdx = 0,
  pickKind = "",
  atTok: any = null,
  fileTimer: any = 0;
export function hideSlash() {
  const m = $("slashMenu");
  if (m) m.hidden = true;
  slashItems = [];
  pickKind = "";
  atTok = null;
  if (fileTimer) {
    clearTimeout(fileTimer);
    fileTimer = 0;
  }
}
export function slashOpen() {
  const m = $("slashMenu");
  return m && !m.hidden && slashItems.length > 0;
}
export function renderSlash() {
  const m = $("slashMenu");
  if (!m) return;
  if (!slashItems.length) {
    m.hidden = true;
    return;
  }
  m.hidden = false;
  const file = pickKind === "file";
  const foot = file
    ? "<span>↑↓ 选择</span><span>Enter 填入</span><span>Tab 补全</span><span>Esc 关闭</span>"
    : "<span>↑↓ 选择</span><span>Enter 执行</span><span>Tab 补全</span><span>Esc 关闭</span>";
  m.innerHTML =
    '<div class="slash-list">' +
    slashItems
      .map((it, i) => {
        const name = file ? it.path || it.name : it.name;
        const desc = file ? (it.dir ? "目录" : "文件") : it.desc;
        const nameHl = (it.hlLen ? hlSpan(name, it.hlFrom || 0, it.hlLen) : esc(name)) + (file && it.dir ? '<span class="mark">/</span>' : "");
        return (
          '<div class="slash-item' +
          (i === slashIdx ? " active" : "") +
          '" data-i="' +
          i +
          '" role="option"><span class="slash-name">' +
          nameHl +
          '</span><span class="slash-desc">' +
          esc(desc || "") +
          "</span></div>"
        );
      })
      .join("") +
    '</div><div class="slash-foot">' +
    foot +
    "</div>";
  const on = m.querySelector(".slash-item.active");
  if (on) on.scrollIntoView({ block: "nearest" });
}
export function updateSlashList(q: string) {
  pickKind = "slash";
  const ranked = rankSlash(SLASH, q);
  slashItems = ranked.map((r: any) =>
    Object.assign({}, r.it, { hlFrom: r.hlFrom, hlLen: r.kind === 2 ? 0 : r.hlLen }),
  );
  if (slashIdx >= slashItems.length) slashIdx = 0;
  renderSlash();
}
export function atToken(v: string, caret: number) {
  const left = v.slice(0, caret == null ? v.length : caret);
  const m = /(^|[\s])(@(?:\.\/[^\s]*|\.?))$/.exec(left);
  if (!m) return null;
  const raw = m[2];
  return { start: left.length - raw.length, raw, q: raw.startsWith("@./") ? raw.slice(3) : "" };
}
export function scheduleFiles(tok: any) {
  atTok = tok;
  pickKind = "file";
  if (fileTimer) clearTimeout(fileTimer);
  fileTimer = setTimeout(async () => {
    fileTimer = 0;
    const cur = atToken(($("inp") as HTMLTextAreaElement).value, ($("inp") as HTMLTextAreaElement).selectionStart);
    if (!cur) {
      hideSlash();
      return;
    }
    atTok = cur;
    try {
      const r = await fetch("/api/files?" + wsp + "q=" + encodeURIComponent(cur.q));
      const j = await r.json();
      if (!j || !j.ok) {
        slashItems = [];
        renderSlash();
        return;
      }
      slashItems = (j.items || []).map((it: any) =>
        Object.assign({ desc: it.link ? "→ " + it.link : it.dir ? "目录" : "文件" }, it),
      );
      // 裸 @(无 ./):运行中的子代理候选排最前(插入字面 @label,不做继续语义)
      if (!cur.q) {
        const subs = (subPool || [])
          .filter((s: any) => s && s.kind === "subagent" && s.name)
          .map((s: any) => ({
            id: "@" + s.name,
            name: s.name,
            desc: "运行中 子代理",
            sub: true,
          }));
        if (subs.length) slashItems = subs.concat(slashItems);
      }
      if (slashIdx >= slashItems.length) slashIdx = 0;
      pickKind = "file";
      renderSlash();
    } catch {
      hideSlash();
    }
  }, 60);
}
// 运行子代理池(jobs 轮询灌入;裸 @ 候选)
export let subPool: any[] = [];
export function setSubPool(list: any[]) {
  subPool = list || [];
}
export function insertFile() {
  const it = slashItems[slashIdx];
  const inp = $("inp") as HTMLTextAreaElement;
  const tok = atToken(inp.value, inp.selectionStart) || atTok;
  if (!it || !tok) {
    hideSlash();
    return;
  }
  const prefix = inp.value.slice(0, tok.start);
  const suffix = inp.value.slice(tok.start + tok.raw.length);
  if (it.sub && it.name) {
    // 子代理引用:插入字面 @label(不做继续语义,仅文本)
    const filled = prefix + "@" + it.name + " ";
    inp.value = filled + suffix;
    inp.setSelectionRange(filled.length, filled.length);
    hideSlash();
  } else if (it.dir) {
    const filled = prefix + "@./" + it.path + "/";
    inp.value = filled + suffix;
    inp.setSelectionRange(filled.length, filled.length);
    hideSlash();
    scheduleFiles(atToken(inp.value, filled.length));
  } else {
    const filled = prefix + "@./" + it.path + " ";
    inp.value = filled + suffix;
    inp.setSelectionRange(filled.length, filled.length);
    hideSlash();
  }
  autosizeInp();
  saveDraft();
  refreshSend();
}
export function hideBang() {
  const el = $("cmpHint");
  if (!el) return;
  el.hidden = true;
  el.innerHTML = "";
}
export function showBang(v: string) {
  const el = $("cmpHint");
  if (!el) return;
  const local = v.startsWith("!!");
  const cmd = v.slice(local ? 2 : 1).trim();
  el.hidden = false;
  el.innerHTML = local
    ? '<span class="bang-local">!! 只跑</span><b>' +
      esc(cmd || "…") +
      "</b><span>结果留在本页，不送模型</span>"
    : '<span class="bang-run">! 跑并送</span><b>' +
      esc(cmd || "…") +
      "</b><span>输出会一并交给模型</span>";
}
export function updateComposerChrome() {
  const inp = $("inp") as HTMLTextAreaElement;
  const v = inp.value;
  if (v.startsWith("/") && v.indexOf("\n") < 0 && v.indexOf(" ") < 0) {
    hideBang();
    updateSlashList(v.slice(1));
    return;
  }
  if (v.startsWith("!")) {
    hideSlash();
    showBang(v);
    return;
  }
  const tok = atToken(v, inp.selectionStart);
  if (tok) {
    hideBang();
    scheduleFiles(tok);
    return;
  }
  hideSlash();
  hideBang();
}
export function updateSlash() {
  updateComposerChrome();
}
export function slashMove(d: number) {
  if (!slashItems.length) return;
  slashIdx = (slashIdx + d + slashItems.length) % slashItems.length;
  renderSlash();
}
export function slashComplete() {
  if (pickKind === "file") {
    insertFile();
    return;
  }
  const it = slashItems[slashIdx];
  if (!it) return;
  ($("inp") as HTMLTextAreaElement).value = it.name + (it.accepts ? " " : "");
  hideSlash();
  autosizeInp();
  saveDraft();
}
export function slashPick() {
  if (pickKind === "file") {
    insertFile();
    return;
  }
  const it = slashItems[slashIdx];
  if (!it) return;
  if (it.accepts) {
    ($("inp") as HTMLTextAreaElement).value = it.name + " ";
    hideSlash();
    autosizeInp();
    return;
  }
  ($("inp") as HTMLTextAreaElement).value = it.name;
  hideSlash();
  send();
}
($("slashMenu") as HTMLElement).onmousedown = (e: any) => {
  const it = e.target.closest(".slash-item");
  if (!it) return;
  e.preventDefault();
  slashIdx = +it.getAttribute("data-i") || 0;
  slashPick();
};
export async function runSlash(item: any, arg?: string) {
  switch (item.name) {
    case "/login": {
      const parts = (arg || "").trim().split(/\s+/);
      const name = parts[0] || "";
      const key = parts.slice(1).join(" ").trim();
      if (!name || !key) {
        showToast("usage: /login <provider> <api-key>");
        break;
      }
      fetch("/api/config", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ setAuth: { name, key } }),
      })
        .then((r) => r.json())
        .then((j) => showToast(j && j.ok ? "saved " + name : "login failed"))
        .catch(() => showToast("登录失败"));
      break;
    }
    case "/quit":
      showToast("close the tab to quit");
      break;
    case "/help":
      addUser("/help");
      const cmds = SLASH.map((s) => s.name.padEnd(16) + s.desc).join("\n");
      const keys = ((window as any).HELP_KEYS || [])
        .map((s: any) => String(s.name || "").padEnd(16) + (s.desc || ""))
        .join("\n");
      addAsst(
        cmds +
          (keys ? "\n\n" + keys : "") +
          "\n\n@./path 嵌文件 · !cmd 跑命令并送给模型 · !!cmd 只跑不送\nCtrl+K 搜会话 · 发送中再按 Enter 会接着发",
      );
      finishAsst();
      break;
    case "/sessions":
      openSearch();
      break;
    case "/new":
    case "/clear":
      location.href = sessUrl(Math.random().toString(36).slice(2, 8));
      break;
    case "/undo":
      act({ act: "undo" }, (j) =>
        showToast(j && j.ok ? "已撤销" : "撤销失败"),
      );
      break;
    case "/compact":
      act({ act: "compact" }, (j) =>
        showToast(j && j.ok ? "压缩完成" : "压缩失败"),
      );
      break;
    case "/fork": {
      const n =
        arg || (await askText("派生会话", "", "新会话名，留空自动"));
      if (n === null) return;
      act({ act: "fork", name: n || "" }, (j) => {
        if (j && j.ok && j.name) location.href = sessUrl(j.name);
        else showToast("派生失败");
      });
      break;
    }
    case "/title": {
      const t = arg || (await askText("会话标题", getCurTitle() || "", ""));
      if (t === null || !t) return;
      await applySessionTitle(t, true);
      break;
    }
    case "/refresh": {
      addUser("/refresh");
      try {
        const r = await fetch("/api/config", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ refreshModels: true }),
        });
        const j = await r.json().catch(() => ({}));
        if (!r.ok || j.ok === false) {
          addAsst(j.error || "cannot refresh models");
        } else {
          addAsst("refreshed " + (j.refreshed || 0) + " provider(s), +" + (j.added || 0) + " models" +
            (j.fail ? "\n" + j.fail + " provider(s) failed GET /models" : ""));
        }
      } catch {
        addAsst("cannot refresh models");
      }
      finishAsst();
      break;
    }
    case "/model":
      ($("hModel") as HTMLElement).click();
      break;
    case "/permissions":
    case "/approvals": {
      const lv = (arg || "").trim();
      if (!lv) {
        ($("permPill") as HTMLElement).click();
        break;
      }
      await setApproval(lv);
      addUser("/permissions " + lv);
      addAsst("授权 " + approvalLabel());
      finishAsst();
      break;
    }
    case "/jobs": {
      const raw = (arg || "").trim();
      addUser(raw ? "/jobs " + raw : "/jobs");
      try {
        if (/^kill\s+\d+/.test(raw) || /^\d+$/.test(raw)) {
          const pid = parseInt(raw.replace(/^kill\s+/, ""), 10);
          const r = await fetch("/api/activity", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ kill: pid }),
          });
          const j = await r.json();
          addAsst(j.ok ? "killed pid " + pid : "no tracked job with that pid");
        } else {
          const r = await fetch("/api/activity");
          const list = await r.json();
          if (!list || !list.length) addAsst("no running jobs");
          else
            addAsst(
              list
                .map((a: any) => {
                  const sec = Math.round((a.ms || 0) / 1000);
                  return (
                    (a.detached ? "~ " : "* ") +
                    (a.pid ? "pid " + a.pid + "  " : "") +
                    (a.name || "job") +
                    " " +
                    sec +
                    "s" +
                    (a.detail ? "  " + a.detail : "")
                  );
                })
                .join("\n"),
            );
        }
        ensureActPoll();
      } catch {
        addAsst("cannot read activity");
      }
      finishAsst();
      break;
    }
    case "/usage": {
      addUser("/usage");
      try {
        const r = await fetch("/api/usage");
        const j = await r.json();
        const cost = j.usd > 0 ? "  $" + Number(j.usd).toFixed(4) : "";
        const head = "usage  " + (j.lines || 0) + " turns  ↑" + fmtTok(j.in || 0) + " ↓" + fmtTok(j.out || 0) + cost;
        addAsst(j.tail ? head + "\n" + j.tail : head);
      } catch {
        addAsst("cannot read usage.jsonl");
      }
      finishAsst();
      break;
    }
    case "/sandbox": {
      const lv = (arg || "").trim();
      if (!lv) {
        addUser("/sandbox");
        addAsst("usage: /sandbox off|workspace|strict");
        finishAsst();
        break;
      }
      addUser("/sandbox " + lv);
      await setSandbox(lv);
      addAsst("sandbox " + getSandboxMode());
      finishAsst();
      break;
    }
    case "/think": {
      const lv = (arg || "").trim();
      if (!lv) {
        ($("hThink") as HTMLElement).click();
        break;
      }
      addUser("/think " + lv);
      await setThink(lv);
      addAsst("思考 " + (getThink() || lv));
      finishAsst();
      break;
    }
    case "/find": {
      const q = (arg || "").trim();
      addUser("/find" + (q ? " " + q : ""));
      const e = asstEl().querySelector(".md");
      if (!q && !slashH.getWebFindQ()) e.textContent = "usage: /find <text>";
      else if (findInThread(q || slashH.getWebFindQ(), false)) e.textContent = "found: " + (q || slashH.getWebFindQ());
      else e.textContent = "no match";
      finishAsst();
      break;
    }
    case "/paste": {
      addUser("/paste");
      try {
        if (await attachClipboardImage()) {
          addAsst(getVision() ? "image attached — enter to send" : "image attached — this model has no vision");
        } else {
          addAsst("no image on clipboard — use Ctrl+V");
        }
      } catch {
        addAsst("no image on clipboard — use Ctrl+V");
      }
      finishAsst();
      break;
    }
    case "/theme": {
      const lv = (arg || "").trim().toLowerCase();
      addUser(lv ? "/theme " + lv : "/theme");
      if (!lv) {
        addAsst("theme " + (prefs.scheme || "dark") + "\nusage: /theme light|dark|system");
      } else if (setScheme(lv)) {
        addAsst("theme " + prefs.scheme);
      } else {
        addAsst("usage: /theme light|dark|system");
      }
      finishAsst();
      break;
    }
    case "/reload":
      fetch("/api/slash?" + wsp + "session=" + encodeURIComponent(sess), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "reload", args: "" }),
      })
        .then((r) => r.json())
        .then((j) => {
          const text = (j && j.text) || "reload failed";
          String(text)
            .split("\n")
            .forEach((line) => {
              const m = line.match(/^(theme|approval|sandbox|think)\s+(\S+)/);
              if (!m) return;
              if (m[1] === "theme") setScheme(m[2]);
              if (m[1] === "approval") setApprovalMode(m[2]);
              if (m[1] === "sandbox") applySandboxLevel(m[2]);
              if (m[1] === "think") applyThink(m[2]);
            });
          addUser("/reload");
          addAsst(text);
          finishAsst();
        })
        .catch(() => {
          addUser("/reload");
          addAsst("reload failed");
          finishAsst();
        });
      break;
    case "/mcp":
      fetch("/api/slash?" + wsp + "session=" + encodeURIComponent(sess), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "mcp", args: "" }),
      })
        .then((r) => r.json())
        .then((j) => {
          addUser("/mcp");
          addAsst((j && j.text) || "mcp failed");
          finishAsst();
        })
        .catch(() => {
          addUser("/mcp");
          addAsst("mcp failed");
          finishAsst();
        });
      break;
    case "/branch":
      fetch("/api/slash?" + wsp + "session=" + encodeURIComponent(sess), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "branch", args: "" }),
      })
        .then((r) => r.json())
        .then((j) => {
          addUser("/branch");
          addAsst((j && j.text) || "branch failed");
          finishAsst();
        })
        .catch(() => {
          addUser("/branch");
          addAsst("branch failed");
          finishAsst();
        });
      break;
    case "/log":
      fetch("/api/slash?" + wsp + "session=" + encodeURIComponent(sess), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "log", args: arg || "" }),
      })
        .then((r) => r.json())
        .then((j) => {
          addUser("/log" + (arg ? " " + arg : ""));
          addAsst((j && j.text) || "log failed");
          finishAsst();
        })
        .catch(() => {
          addUser("/log");
          addAsst("log failed");
          finishAsst();
        });
      break;
    case "/commit":
      fetch("/api/slash?" + wsp + "session=" + encodeURIComponent(sess), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "commit", args: arg || "" }),
      })
        .then((r) => r.json())
        .then((j) => {
          addUser("/commit" + (arg ? " " + arg : ""));
          addAsst((j && j.text) || "commit failed");
          finishAsst();
        })
        .catch(() => {
          addUser("/commit");
          addAsst("commit failed");
          finishAsst();
        });
      break;
    case "/diff":
      fetch("/api/slash?" + wsp + "session=" + encodeURIComponent(sess), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "diff", args: "" }),
      })
        .then((r) => r.json())
        .then((j) => {
          addUser("/diff");
          addAsst((j && j.text) || "diff failed");
          finishAsst();
        })
        .catch(() => {
          addUser("/diff");
          addAsst("diff failed");
          finishAsst();
        });
      break;
    case "/init":
      fetch("/api/slash?" + wsp + "session=" + encodeURIComponent(sess), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "init", args: "" }),
      })
        .then((r) => r.json())
        .then((j) => {
          addUser("/init");
          addAsst((j && j.text) || "init failed");
          finishAsst();
        })
        .catch(() => {
          addUser("/init");
          addAsst("init failed");
          finishAsst();
        });
      break;
    case "/doctor":
      fetch("/api/slash?" + wsp + "session=" + encodeURIComponent(sess), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "doctor", args: "" }),
      })
        .then((r) => r.json())
        .then((j) => {
          addUser("/doctor");
          addAsst((j && j.text) || "doctor failed");
          finishAsst();
        })
        .catch(() => {
          addUser("/doctor");
          addAsst("doctor failed");
          finishAsst();
        });
      break;
    case "/status":
      fetch("/api/config")
        .then((r) => r.json())
        .then((cfg) => {
          const on = (Array.isArray(cfg.plugins) ? cfg.plugins : [])
            .filter((p: any) => p && p.enabled && p.optional)
            .map((p: any) => p.name);
          addUser("/status");
          addAsst(
            "模型 " +
              (getCurModel() || "?") +
              " · 思考 " +
              (getThink() || "high") +
              " · 会话 " +
              sess +
              " · 项目 " +
              (ws || ".") +
              (on.length ? " · 插件 " + on.join(" ") : ""),
          );
          finishAsst();
        })
        .catch(() => {
          addUser("/status");
          addAsst(
            "模型 " +
              (getCurModel() || "?") +
              " · 思考 " +
              (getThink() || "high") +
              " · 会话 " +
              sess +
              " · 项目 " +
              (ws || "."),
          );
          finishAsst();
        });
      break;
    case "/resume": {
      const n = parseInt(arg || "", 10);
      if (!arg || !n) {
        openSearch();
        break;
      }
      if (n < 1 || n > sessData.list.length) {
        showToast("没有第 " + n + " 个会话（/sessions）");
        break;
      }
      location.href = sessUrl(sessData.list[n - 1].name);
      break;
    }
    case "/plan": {
      const goal =
        (arg && arg.trim()) ||
        (await askText("计划目标", "", "要完成什么"));
      if (!goal) return;
      await sendPlain("/plan " + goal);
      break;
    }
    case "/queue":
      slashH.clearPending();
      renderQueue();
      act({ act: "queue" }, (j) => {
        showToast(
          j && j.cleared
            ? "已清空 " + j.cleared + " 条"
            : "没有待发送的消息",
        );
      });
      break;
    case "/memory": {
      const rest = (arg || "").trim();
      if (rest === "clear") {
        act({ act: "memory-clear" }, (j) =>
          showToast(j && j.ok ? "记忆已清空" : "清空失败"),
        );
        break;
      }
      if (rest.startsWith("set ")) {
        const text = rest.slice(4).trim();
        if (!text) {
          showToast("usage: /memory set <text>");
          break;
        }
        act({ act: "memory-set", name: text }, (j) =>
          showToast(j && j.ok ? "记忆已写入" : "写入失败"),
        );
        break;
      }
      act({ act: "memory" }, (j) => {
        addUser("/memory");
        addAsst(
          (j && j.text) ||
            "memory is empty — /memory set <text> to add",
        );
        finishAsst();
      });
      break;
    }
    case "/plugins": {
      const rest = (arg || "").trim();
      if (!rest) {
        fetch("/api/config")
          .then((r) => r.json())
          .then((cfg) => {
            const plugs = Array.isArray(cfg.plugins) ? cfg.plugins : [];
            const lines = plugs.map(
              (p: any) =>
                "  [" +
                (p.enabled ? "on " : "off") +
                "] " +
                p.name,
            );
            addUser("/plugins");
            addAsst(
              "plugins (next turn):\n" +
                lines.join("\n") +
                "\nusage: /plugins on <name> | /plugins off <name>",
            );
            finishAsst();
          })
          .catch(() => showToast("plugins 读取失败"));
        break;
      }
      const m = rest.match(/^(on|off)\s+(\S+)$/);
      if (!m) {
        showToast("usage: /plugins on <name> | /plugins off <name>");
        break;
      }
      const on = m[1] === "on";
      fetch("/api/config", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ setPlugin: { name: m[2], enabled: on } }),
      })
        .then((r) => r.json())
        .then((j) => {
          if (j && j.ok === false) {
            showToast("插件开关失败");
            return;
          }
          showToast("plugin " + m[2] + (on ? " on" : " off") + " — next turn");
          loadHelpCatalog();
        })
        .catch(() => showToast("插件开关失败"));
      break;
    }
    case "/pkg":
      fetch("/api/packages?" + wsp)
        .then((r) => r.json())
        .then((j) => {
          function rows(arr: any, title: string) {
            const xs = Array.isArray(arr) ? arr : [];
            const body = xs.length
              ? xs
                  .map(
                    (p: any) =>
                      "  " +
                      p.name +
                      "  skills:" +
                      (p.skills || 0) +
                      " prompts:" +
                      (p.prompts || 0),
                  )
                  .join("\n")
              : "  (none)";
            return title + " (" + xs.length + "):\n" + body;
          }
          addUser("/pkg");
          addAsst(
            rows(j.user, "user packages") +
              "\n" +
              rows(j.project, "project packages") +
              "\ninstall: piz pkg install <path> [-l]",
          );
          finishAsst();
        })
        .catch(() => {
          addUser("/pkg");
          addAsst("packages 读取失败");
          finishAsst();
        });
      break;
    case "/tree":
      act({ act: "tree" }, (j) => {
        addUser("/tree");
        addAsst((j && j.text) || "no messages");
        finishAsst();
      });
      break;
    case "/copy":
      act({ act: "copy" }, (j) =>
        clipText(j && j.text, "已复制最后回复", "还没有回复"),
      );
      break;
    case "/export":
      act({ act: "export" }, (j) => {
        if (j && j.text) {
          downloadText("piz-export.html", j.text, "text/html");
          showToast("已导出");
        } else showToast("导出失败");
      });
      break;
    case "/dump":
      act({ act: "dump" }, (j) =>
        clipText(j && j.text, "会话已复制", "没有内容"),
      );
      break;
    case "/fast-compress":
      act({ act: "fast-compress" }, (j) => {
        addUser("/fast-compress");
        addAsst((j && j.text) || "fast-compress: ?");
        finishAsst();
      });
      break;
    case "/redo":
      if (!slashH.getLastUser()) {
        showToast("没有可重发的输入");
        break;
      }
      await sendPlain(slashH.getLastUser());
      break;
    default: {
      const stem = String(item.name || "").replace(/^\//, "");
      fetch("/api/slash?" + wsp + "session=" + encodeURIComponent(sess), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: stem, args: arg || "" }),
      })
        .then((r) => r.json())
        .then((j) => {
          if (j && j.ok) {
            addUser("/" + stem + (arg ? " " + arg : ""));
            addAsst(j.text || "");
            finishAsst();
          } else showToast((j && j.error) || "未知命令");
        })
        .catch(() => showToast("未知命令"));
      break;
    }
  }
}
