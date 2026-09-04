// model.ts —— 模型/思考档/授权/沙箱/cost/ctx/turnMeta/头部渲染与 kebab 菜单。
import { $, esc, fmtTok, projectName } from "./util";
import { sess, wsp, ws, sessUrl } from "./state";
import { showToast, askText } from "./ui";
import { closeMenus, openAt, menuRow, menuLabel, menuSep, loadSessions, act, openWsMenu } from "./sessions";
import { t, getLang } from "./i18n";
import { emit, on } from "./bus";

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
      showToast(j.error || t("modelSwitchFail", "Failed to switch model"));
      return false;
    }
    curModel = j.model;
    renderModel();
    return true;
  } catch {
    showToast(t("modelSwitchFail", "Failed to switch model"));
    return false;
  }
}
/// 模型选择卡片(dsh ModelSelect 之形):按 provider 分组 + sticky 组题 + 当前项尾勾。
/// 模型 id 形如 "provider/model";无斜线的归「其他」组。向上弹出(锚在输入工具条)。
export function loadModels(sel: any) {
  fetch("/api/models")
    .then((r) => r.json())
    .then((list: string[]) => {
      if (!Array.isArray(list)) list = [];
      const m = $("modelMenu")!;
      m.innerHTML = "";
      // 分组:provider 前缀 → 模型列表
      const groups = new Map<string, string[]>();
      for (const md of list) {
        const prov = md.includes("/") ? md.slice(0, md.indexOf("/")) : (getLang() === "zh" ? "其他" : "Other");
        if (!groups.has(prov)) groups.set(prov, []);
        groups.get(prov)!.push(md);
      }
      const provs = [...groups.keys()].sort((a, b) => {
        // 当前模型所在组置顶
        const ca = curModel.startsWith(a + "/") ? 0 : 1;
        const cb = curModel.startsWith(b + "/") ? 0 : 1;
        return ca - cb || a.localeCompare(b);
      });
      for (const prov of provs) {
        m.appendChild(menuLabel(prov));
        for (const md of groups.get(prov)!) {
          const short = md.includes("/") ? md.slice(md.indexOf("/") + 1) : md;
          m.appendChild(
            menuRow({
              label: short,
              check: md === curModel,
              onclick: async () => {
                if (await applySessionModel(md)) closeMenus();
              },
            }),
          );
        }
      }
      if (!list.length) m.appendChild(menuLabel(t("noModels", "No models available")));
      openAt("modelMenu", sel, "tr");
    })
    .catch(() => showToast(t("modelsLoadFail", "Failed to load models")));
}
export function modelShort(m: string) {
  if (!m) return t("selectModel", "Model");
  const n = m.includes("/") ? m.slice(m.lastIndexOf("/") + 1) : m;
  return n.length > 22 ? n.slice(0, 20) + "…" : n;
}
export function renderModel() {
  const el = $("hModel");
  if (!el) return;
  el.textContent = modelShort(curModel);
  el.title = curModel ? "Model: " + curModel : t("switchModel", "Switch model");
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
  el.title = t("thinkingLevel", "Thinking") + ": " + (curThink || "high");
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
      showToast(j.error || t("thinkSwitchFail", "Failed to switch thinking level"));
      return false;
    }
    if (j && j.defaultThinkingLevel) {
      curThink = j.defaultThinkingLevel;
      renderThink();
    }
    return true;
  } catch {
    showToast(t("thinkSwitchFail", "Failed to switch thinking level"));
    return false;
  }
}
($("hThink") as HTMLElement).onclick = (e: any) => {
  e.stopPropagation();
  const m = $("thinkMenu")!;
  m.innerHTML = "";
  m.appendChild(menuLabel(t("thinkingLevel", "Thinking level")));
  THINK_LEVELS.forEach((lv) => {
    m.appendChild(
      menuRow({
        label: lv,
        check: lv === curThink,
        onclick: () => setThink(lv),
      }),
    );
  });
  openAt("thinkMenu", e.currentTarget, "tr");
};
// ---- 授权模式(Codex /permissions: yolo / ask / read-only) ----
export let approvalMode = "yolo";
export const APPROVALS = [
  { id: "yolo", label: "yolo", hint: () => (getLang() === "zh" ? "不询问，默认" : "No confirmation, default") },
  { id: "ask", label: "ask", hint: () => (getLang() === "zh" ? "危险工具先问" : "Ask before dangerous tools") },
  { id: "read-only", label: "read-only", hint: () => (getLang() === "zh" ? "危险工具直接拒" : "Deny dangerous tools directly") },
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
  p.title = t("permMode", "Approval mode") + ": " + (typeof cur.hint === "function" ? cur.hint() : cur.hint);
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
      showToast(j.error || t("permSwitchFail", "Failed to switch approval mode"));
      return;
    }
    if (j.mode) approvalMode = j.mode;
    else if (j.auto !== undefined) approvalMode = j.auto ? "yolo" : "ask";
    setModeBtn();
  } catch {
    showToast(t("permSwitchFail", "Failed to switch approval mode"));
  }
}
($("permPill") as HTMLElement).onclick = (e: any) => {
  e.stopPropagation();
  const m = $("permMenu")!;
  m.innerHTML = "";
  m.appendChild(menuLabel(t("permMode", "Approval mode")));
  APPROVALS.forEach((it) => {
    m.appendChild(
      menuRow({
        label: it.label,
        hint: typeof it.hint === "function" ? it.hint() : it.hint,
        check: it.id === approvalMode,
        onclick: () => setApproval(it.id),
      }),
    );
  });
  openAt("permMenu", e.currentTarget, "tr");
};

export let sandboxMode = "off";
export const SANDBOXES = [
  { id: "off", label: "off", hint: () => (getLang() === "zh" ? "不隔离" : "No isolation") },
  { id: "workspace", label: "workspace", hint: () => (getLang() === "zh" ? "工作区可写，其余只读" : "Workspace writable, others read-only") },
  { id: "strict", label: "strict", hint: () => (getLang() === "zh" ? "工作区 + 断网" : "Workspace + no network") },
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
  p.title = "Sandbox: " + (typeof cur.hint === "function" ? cur.hint() : cur.hint) + (be ? " · " + be : "");
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
      showToast(j.error || t("sandboxSwitchFail", "Failed to switch sandbox"));
      return;
    }
    if (j && j.sandboxMode) sandboxMode = j.sandboxMode;
    if (j && j.sandboxBackend) (window as any).sandboxBackend = j.sandboxBackend;
    setSandboxBtn();
  } catch {
    showToast(t("sandboxSwitchFail", "Failed to switch sandbox"));
  }
}
($("sbPill") as HTMLElement).onclick = (e: any) => {
  e.stopPropagation();
  const m = $("sbMenu")!;
  m.innerHTML = "";
  m.appendChild(menuLabel(t("sandboxMode", "Bash sandbox")));
  SANDBOXES.forEach((it) => {
    m.appendChild(
      menuRow({
        label: it.label,
        hint: typeof it.hint === "function" ? it.hint() : it.hint,
        check: it.id === sandboxMode,
        onclick: () => setSandbox(it.id),
      }),
    );
  });
  openAt("sbMenu", e.currentTarget, "tr");
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
        : t("context", "Context ") + pretty;
    wrap.title = wrap.dataset.baseTitle;
    (fill as unknown as SVGCircleElement).style.stroke =
      n > 85 ? "var(--color-danger)" : "var(--color-accent)";
  }
  if ((win > 0 ? used / win : (+pct || 0) / 100) > 0.85) {
    const c = $("compactChip")!;
    c.style.display = "";
    c.onclick = () => {
      showToast(t("compressing", "Compressing context..."));
      act({ act: "compact" }, (j: any) => {
        showToast(j && j.ok ? t("compressedOk", "Context compressed") : t("compressedFail", "Compression failed"));
      });
    };
  } else $("compactChip")!.style.display = "none";
}
export function setTurnMeta(evt: any) {
  const el = $("turnMeta");
  if (!el) return;
  const bits = [];
  if (evt.cache !== undefined && evt.cache !== "")
    bits.push(t("cache", "Cache ") + evt.cache + "%");
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
    if (evt.cache !== undefined && evt.cache !== "") extra.push(t("cache", "Cache ") + evt.cache + "%");
    if (evt.tps) extra.push(evt.tps + " tok/s");
    wrap.title =
      (wrap.dataset.baseTitle || wrap.title || t("context", "Context ")) +
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
  hSes.textContent = sess === "default" ? t("defaultSession", "Default session") : s.title || sess;
  $("tbWs")!.textContent = wsName || "";
  $("tbSe")!.textContent =
    sess === "default" ? t("defaultSession", "Default session") : s.title || sess;
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
    pill.textContent = s.changes + (getLang() === "zh" ? " 个变更" : " changes");
    git.appendChild(pill);
  }
}
export async function applySessionTitle(tStr: string, hdr?: boolean) {
  try {
    const r = await fetch(
      "/api/title?" + wsp + "session=" + encodeURIComponent(sess),
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ title: tStr }),
      },
    );
    const j = await r.json().catch(() => ({}));
    if (!r.ok || j.ok === false || j.title === undefined) {
      showToast(j.error || t("setTitleFail", "Failed to set title"));
      return false;
    }
    curTitle = j.title;
    if (hdr) renderHdr({ title: j.title });
    loadSessions();
    return true;
  } catch {
    showToast(t("setTitleFail", "Failed to set title"));
    return false;
  }
}
($("hSes") as HTMLElement).onclick = async () => {
  const tStr = await askText(t("sessionTitle", "Session title"), curTitle || "", "");
  if (tStr === null) return;
  await applySessionTitle(tStr, true);
};
($("hKebab") as HTMLElement).onclick = (e: any) => {
  e.stopPropagation();
  const m = $("kmenu")!;
  m.innerHTML = "";
  const mi = (label: string, fn: () => void, danger?: boolean) =>
    m.appendChild(menuRow({ label: label.replace(/^[^ ]+ /, ""), icon: label.slice(0, label.indexOf(" ")), danger, onclick: fn }));
  mi(t("copyReply", "⧉ Copy last reply"), () => emit("slash:run", { cmd: { name: "/copy" }, arg: "" }));
  mi(t("exportHtml", "⎘ Export HTML"), () => emit("slash:run", { cmd: { name: "/export" }, arg: "" }));
  mi(t("tree", "☰ Message list"), () => emit("slash:run", { cmd: { name: "/tree" }, arg: "" }));
  mi(t("dumpAll", "📋 Dump all"), () => emit("slash:run", { cmd: { name: "/dump" }, arg: "" }));
  mi(t("plan", "✎ Plan"), async () => {
    const g = await askText(t("planGoal", "Plan goal"), "", t("whatToAccomplish", "What to accomplish"));
    if (g) emit("slash:run", { cmd: { name: "/plan" }, arg: g });
  });
  mi(t("renameSession", "✎ Rename session"), async () => {
    const tStr = await askText(t("sessionTitle", "Session title"), curTitle || "", "");
    if (tStr === null) return;
    await applySessionTitle(tStr, false);
  });
  mi(t("forkSession", "✱ Fork session"), async () => {
    const n = await askText(t("forkSession", "Fork session"), "", t("forkHint", "New session name, empty for auto"));
    if (n === null) return;
    act({ act: "fork", name: n || "" }, (j: any) => {
      if (j && j.name) {
        showToast(t("forked", "Forked ") + j.name);
        setTimeout(
          () =>
            (location.href = sessUrl(j.name) as any),
          600,
        );
      }
    });
  });
  m.appendChild(menuSep());
  mi(t("undoTurn", "↶ Undo turn"), () => {
    act({ act: "undo" }, (j: any) => {
      showToast(j && j.ok ? t("undone", "Undone") : t("noUndo", "Nothing to undo"));
      setTimeout(() => location.reload(), 400);
    });
  });
  mi(t("compactContext", "⚡ Compact context"), () => {
    showToast(t("compressing", "Compressing context..."));
    act({ act: "compact" }, (j: any) => {
      showToast(j && j.ok ? t("compressedOk", "Context compressed") : t("compressedFail", "Compression failed"));
    });
  });
  m.appendChild(menuSep());
  mi(
    t("archiveSession", "🗄 Archive session"),
    () => {
      act({ act: "archive" }, (j: any) => {
        if (j && j.ok) {
          showToast(t("archived", "Archived"));
          setTimeout(() => (location.href = sessUrl("default") as any), 400);
        }
      });
    },
    true,
  );
  openAt("kmenu", e.currentTarget, "br");
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

on("session:select", (s: any) => {
  if (s && (s.mode || s.auto !== undefined)) {
    setApprovalMode(s.mode || (s.auto ? "yolo" : "ask"));
  }
});
