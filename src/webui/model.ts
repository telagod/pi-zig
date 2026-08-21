// model.ts —— 模型/思考档/授权/沙箱/cost/ctx/turnMeta/头部渲染与 kebab 菜单。
// 自 webui.js 切出。runSlash 借自 slash.ts(环引,仅运行期回调用之,安全);
// 诸模块直引本簇,旧 slashH/chatH/compH 之模型钩尽废。
import { $, esc, fmtTok, projectName } from "./util";
import { sess, wsp, ws, sessUrl } from "./state";
import { showToast, askText } from "./ui";
import { closeMenus, openAt, loadSessions, act, openWsMenu } from "./sessions";

// runSlash 环引(slash↔model 为 build-web DFS 所禁),以钩袋迟取之。
export const modelH: any = {};
const runSlash = (...a: any[]) => modelH.runSlash(...a);

// ---- 模型 ----
export let curModel = "";
export let curThink = "high";
export let curTitle = "";
export let curVision = false;
export const getCurModel = () => curModel;
export const getThink = () => curThink;
export const getCurTitle = () => curTitle;
export const getVision = () => curVision;
export function applyThink(t: string) {
  curThink = t;
  renderThink();
}
export function applyTitle(t: string) {
  curTitle = t;
}
export async function applySessionModel(md: string) {
  try {
    const r = await fetch(
      "/api/model?" + wsp + "session=" + encodeURIComponent(sess),
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ model: md }),
      },
    );
    const j = await r.json().catch(() => ({}));
    if (!r.ok || j.ok === false || !j.model) {
      showToast(j.error || "switch model failed");
      return false;
    }
    curModel = j.model;
    renderModel();
    return true;
  } catch {
    showToast("switch model failed");
    return false;
  }
}
export function loadModels(sel: any) {
  fetch("/api/models")
    .then((r) => r.json())
    .then((list) => {
      const m = $("modelMenu")!;
      m.innerHTML = "";
      for (const md of list) {
        const d = document.createElement("div");
        d.className = "mi" + (md === curModel ? " check" : "");
        d.textContent = md;
        d.onclick = async () => {
          if (await applySessionModel(md)) closeMenus();
        };
        m.appendChild(d);
      }
      openAt("modelMenu", sel);
    })
    .catch(() => showToast("models load failed"));
}
export function modelShort(m: string) {
  if (!m) return "模型";
  const n = m.includes("/") ? m.slice(m.lastIndexOf("/") + 1) : m;
  return n.length > 22 ? n.slice(0, 20) + "…" : n;
}
export function renderModel() {
  const el = $("hModel");
  if (!el) return;
  el.textContent = modelShort(curModel);
  el.title = curModel ? "模型 " + curModel : "切换模型";
}
($("hModel") as HTMLElement).onclick = (e: any) => {
  e.stopPropagation();
  loadModels(e.currentTarget);
};
export const THINK_LEVELS = [
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
];
export function renderThink() {
  const el = $("hThink");
  if (!el) return;
  el.textContent = curThink || "high";
  el.title = "思考 " + (curThink || "high");
}
export async function setThink(level: string) {
  try {
    const r = await fetch("/api/config", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ setDefaultThinkingLevel: level }),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || j.ok === false) {
      showToast(j.error || "switch think failed");
      return false;
    }
    if (j && j.defaultThinkingLevel) {
      curThink = j.defaultThinkingLevel;
      renderThink();
    }
    return true;
  } catch {
    showToast("switch think failed");
    return false;
  }
}
($("hThink") as HTMLElement).onclick = (e: any) => {
  e.stopPropagation();
  const m = $("thinkMenu")!;
  m.innerHTML = "";
  THINK_LEVELS.forEach((lv) => {
    const d = document.createElement("div");
    d.className = "mi" + (lv === curThink ? " check" : "");
    d.textContent = lv;
    d.onclick = () => {
      m.hidden = true;
      setThink(lv);
    };
    m.appendChild(d);
  });
  openAt("thinkMenu", e.currentTarget);
};
// ---- 授权模式(Codex /permissions: yolo / ask / read-only) ----
export let approvalMode = "yolo";
export const APPROVALS = [
  { id: "yolo", label: "yolo", hint: "不询问，默认" },
  { id: "ask", label: "ask", hint: "危险工具先问" },
  { id: "read-only", label: "read-only", hint: "危险工具直接拒" },
];
export const approvalLabel = () =>
  (APPROVALS.find((x) => x.id === approvalMode) || ({} as any)).label;
export const setApprovalMode = (v: string) => {
  approvalMode = v === "read-only" ? "read-only" : v;
  setModeBtn();
};
export function setModeBtn() {
  const p = $("permPill")!;
  const cur = APPROVALS.find((x) => x.id === approvalMode) || APPROVALS[0];
  p.textContent = cur.label;
  p.className =
    "perm-pill " +
    (approvalMode === "yolo"
      ? "perm-allow"
      : approvalMode === "ask"
        ? "perm-ask"
        : "perm-deny");
  p.title = "授权 " + cur.hint;
}
export async function setApproval(mode: string) {
  approvalMode = mode;
  setModeBtn();
  try {
    const r = await fetch(
      "/api/mode?" + wsp + "session=" + encodeURIComponent(sess),
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ mode }),
      },
    );
    const j = await r.json().catch(() => ({}));
    if (!r.ok || j.ok === false) {
      showToast(j.error || "授权切换失败");
      return;
    }
    if (j.mode) approvalMode = j.mode;
    else if (j.auto !== undefined) approvalMode = j.auto ? "yolo" : "ask";
    setModeBtn();
  } catch {
    showToast("授权切换失败");
  }
}
($("permPill") as HTMLElement).onclick = (e: any) => {
  e.stopPropagation();
  const m = $("permMenu")!;
  m.innerHTML = "";
  APPROVALS.forEach((it) => {
    const d = document.createElement("div");
    d.className = "mi" + (it.id === approvalMode ? " check" : "");
    d.textContent = it.label + "  " + it.hint;
    d.onclick = (ev: any) => {
      ev.stopPropagation();
      closeMenus();
      setApproval(it.id);
    };
    m.appendChild(d);
  });
  openAt("permMenu", e.currentTarget);
};
export let sandboxMode = "off";
export const SANDBOXES = [
  { id: "off", label: "off", hint: "不隔离" },
  { id: "workspace", label: "workspace", hint: "工作区可写，其余只读" },
  { id: "strict", label: "strict", hint: "工作区 + 断网" },
];
export const getSandboxMode = () => sandboxMode;
export const getApprovalMode = () => approvalMode;
export const applySandboxLevel = (v: string) => {
  sandboxMode = v;
  setSandboxBtn();
};
export function setSandboxBtn() {
  const p = $("sbPill");
  if (!p) return;
  const cur = SANDBOXES.find((x) => x.id === sandboxMode) || SANDBOXES[0];
  const be = (window as any).sandboxBackend || "";
  p.textContent =
    cur.label === "off" ? "sb off" : be ? cur.label + "/" + be : cur.label;
  p.className =
    "perm-pill " +
    (sandboxMode === "strict" ? "perm-deny" : sandboxMode === "workspace" ? "perm-ask" : "");
  p.title = "沙箱 " + cur.hint + (be ? " · " + be : "");
}
export async function setSandbox(mode: string) {
  sandboxMode = mode;
  setSandboxBtn();
  try {
    const r = await fetch("/api/config", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ setSandboxMode: mode }),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || j.ok === false) {
      showToast(j.error || "沙箱切换失败");
      return;
    }
    if (j && j.sandboxMode) sandboxMode = j.sandboxMode;
    if (j && j.sandboxBackend) (window as any).sandboxBackend = j.sandboxBackend;
    setSandboxBtn();
  } catch {
    showToast("沙箱切换失败");
  }
}
($("sbPill") as HTMLElement).onclick = (e: any) => {
  e.stopPropagation();
  const m = $("sbMenu")!;
  m.innerHTML = "";
  SANDBOXES.forEach((it) => {
    const d = document.createElement("div");
    d.className = "mi" + (it.id === sandboxMode ? " check" : "");
    d.textContent = it.label + "  " + it.hint;
    d.onclick = (ev: any) => {
      ev.stopPropagation();
      closeMenus();
      setSandbox(it.id);
    };
    m.appendChild(d);
  });
  openAt("sbMenu", e.currentTarget);
};
($("modePill") as HTMLElement).onclick = () => {
  const i = $("inp") as HTMLTextAreaElement;
  if (!i.value.startsWith("/")) i.value = "/";
  i.focus();
  i.dispatchEvent(new Event("input"));
};
// ---- 压缩提示 ----
export function setCost(n: any) {
  const el = $("costLbl");
  if (!el) return;
  if (n == null || !(Number(n) > 0)) {
    el.hidden = true;
    el.textContent = "";
    return;
  }
  const v = Number(n);
  el.hidden = false;
  el.textContent = v < 0.01 ? "$" + v.toFixed(4) : "$" + v.toFixed(3);
  el.title = "Session cost";
}
export function setCtx(pct: any, used: any, win: any) {
  const wrap = $("ctxWrap"),
    fill = $("ctxFill"),
    lbl = $("ctxLbl");
  if (wrap && fill && lbl) {
    const frac =
      win > 0 ? used / win : Math.max(0, Math.min(1, (+pct || 0) / 100));
    const n = Math.max(0, Math.min(100, frac * 100));
    const C = 2 * Math.PI * 7;
    (fill as unknown as SVGCircleElement).style.strokeDashoffset = String(C * (1 - frac));
    lbl.textContent =
      n < 1 && (used > 0 || pct > 0) ? "<1%" : Math.round(n) + "%";
    wrap.hidden = false;
    const pretty =
      n < 0.1 && used > 0
        ? "<0.1%"
        : (n < 10 ? n.toFixed(1) : Math.round(n)) + "%";
    wrap.dataset.baseTitle =
      used != null && win
        ? fmtTok(used) + " / " + fmtTok(win) + " · " + pretty
        : "上下文 " + pretty;
    wrap.title = wrap.dataset.baseTitle;
    (fill as unknown as SVGCircleElement).style.stroke =
      n > 85 ? "var(--color-danger)" : "var(--color-accent)";
  }
  if ((win > 0 ? used / win : (+pct || 0) / 100) > 0.85) {
    const c = $("compactChip")!;
    c.style.display = "";
    c.onclick = () => {
      showToast("正在压缩…");
      act({ act: "compact" }, (j: any) => {
        showToast(j && j.ok ? "压缩完成" : "压缩失败");
      });
    };
  } else $("compactChip")!.style.display = "none";
}
export function setTurnMeta(evt: any) {
  const el = $("turnMeta");
  if (!el) return;
  const bits = [];
  if (evt.cache !== undefined && evt.cache !== "")
    bits.push("缓存 " + evt.cache + "%");
  if (evt.tps) bits.push(evt.tps + " tok/s");
  if (!bits.length) {
    el.hidden = true;
    return;
  }
  el.hidden = false;
  el.textContent = bits.join(" · ");
  const wrap = $("ctxWrap");
  if (wrap && !wrap.hidden) {
    const extra = [];
    if (evt.cache !== undefined && evt.cache !== "") extra.push("缓存 " + evt.cache + "%");
    if (evt.tps) extra.push(evt.tps + " tok/s");
    wrap.title =
      (wrap.dataset.baseTitle || wrap.title || "上下文") +
      (extra.length ? " · " + extra.join(" · ") : "");
  }
}
// ---- 头部 ----
export function renderHdr(s: any) {
  const wsName = s.ws || projectName(ws) || "";
  const hWs = $("hWs")!,
    hSep = $("hSep")!,
    hSes = $("hSes")!;
  if (wsName) {
    hWs.textContent = wsName;
    hSep.style.display = "";
    hWs.onclick = (e: any) => {
      e.stopPropagation();
      openWsMenu(hWs);
    };
  } else {
    hWs.textContent = "";
    hSep.style.display = "none";
  }
  hSes.textContent = sess === "default" ? "默认会话" : s.title || sess;
  $("tbWs")!.textContent = wsName || "";
  $("tbSe")!.textContent =
    sess === "default" ? "默认会话" : s.title || sess;
  const git = $("hGit")!;
  git.innerHTML = "";
  if (s.branch) {
    const pill = document.createElement("span");
    pill.className = "ch-pill";
    pill.innerHTML =
      "<b>" +
      esc(s.branch) +
      "</b>" +
      (s.ahead ? ' <span class="ch-ahead">↑' + s.ahead + "</span>" : "") +
      (s.behind
        ? ' <span class="ch-behind">↓' + s.behind + "</span>"
        : "");
    git.appendChild(pill);
  }
  if (s.changes) {
    const pill = document.createElement("span");
    pill.className = "ch-pill";
    pill.style.borderColor =
      "color-mix(in srgb,var(--color-success) 20%,var(--color-line))";
    pill.textContent = s.changes + " 个变更";
    git.appendChild(pill);
  }
}
export async function applySessionTitle(t: string, hdr?: boolean) {
  try {
    const r = await fetch(
      "/api/title?" + wsp + "session=" + encodeURIComponent(sess),
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ title: t }),
      },
    );
    const j = await r.json().catch(() => ({}));
    if (!r.ok || j.ok === false || j.title === undefined) {
      showToast(j.error || "set title failed");
      return false;
    }
    curTitle = j.title;
    if (hdr) renderHdr({ title: j.title });
    loadSessions();
    return true;
  } catch {
    showToast("set title failed");
    return false;
  }
}
($("hSes") as HTMLElement).onclick = async () => {
  const t = await askText("会话标题", curTitle || "", "");
  if (t === null) return;
  await applySessionTitle(t, true);
};
($("hKebab") as HTMLElement).onclick = (e: any) => {
  e.stopPropagation();
  const m = $("kmenu")!;
  m.innerHTML = "";
  const mi = (t: string, fn: () => void, danger?: boolean) => {
    const d = document.createElement("div");
    d.className = "mi" + (danger ? " danger" : "");
    d.textContent = t;
    d.onclick = () => {
      closeMenus();
      fn();
    };
    m.appendChild(d);
  };
  mi("⧉ 复制最后回复", () => runSlash({ name: "/copy" }, ""));
  mi("⎘ 导出 HTML", () => runSlash({ name: "/export" }, ""));
  mi("☰ 消息列表", () => runSlash({ name: "/tree" }, ""));
  mi("📋 复制全部", () => runSlash({ name: "/dump" }, ""));
  mi("✎ 计划", async () => {
    const g = await askText("计划目标", "", "要完成什么");
    if (g) runSlash({ name: "/plan" }, g);
  });
  mi("✎ 重命名", async () => {
    const t = await askText("会话标题", curTitle || "", "");
    if (t === null) return;
    await applySessionTitle(t, false);
  });
  mi("✱ 派生会话", async () => {
    const n = await askText("派生会话", "", "新会话名，留空自动");
    if (n === null) return;
    act({ act: "fork", name: n || "" }, (j: any) => {
      if (j && j.name) {
        showToast("已派生 " + j.name);
        setTimeout(
          () =>
            (location.href = sessUrl(j.name) as any),
          600,
        );
      }
    });
  });
  const se = document.createElement("div");
  se.className = "sep";
  m.appendChild(se);
  mi("↶ 撤销最后一条", () => {
    act({ act: "undo" }, (j: any) => {
      showToast(j && j.ok ? "已撤销" : "无可撤销");
      setTimeout(() => location.reload(), 400);
    });
  });
  mi("⚡ 压缩上下文", () => {
    showToast("正在压缩…");
    act({ act: "compact" }, (j: any) => {
      showToast(j && j.ok ? "压缩完成" : "压缩失败");
    });
  });
  const se2 = document.createElement("div");
  se2.className = "sep";
  m.appendChild(se2);
  mi(
    "🗄 归档会话",
    () => {
      act({ act: "archive" }, (j: any) => {
        if (j && j.ok) {
          showToast("已归档");
          setTimeout(() => (location.href = sessUrl("default") as any), 400);
        }
      });
    },
    true,
  );
  openAt("kmenu", e.currentTarget);
};
($("tbKebab") as HTMLElement).onclick = (e: any) => {
  e.stopPropagation();
  ($("hKebab") as any).onclick(e);
};
// ---- 启动时应用 /api/state 之模型簇字段 ----
export function applyBootState(s: any) {
  if (s.model) {
    curModel = s.model;
    renderModel();
  }
  if (typeof s.vision === "boolean") curVision = s.vision;
  if (s.think) {
    curThink = s.think;
    renderThink();
  }
  if (s.title) {
    curTitle = s.title;
  }
  if (s.mode || s.auto !== undefined) {
    approvalMode = s.mode || (s.auto ? "yolo" : "ask");
    setModeBtn();
  }
  renderHdr(s);
}
