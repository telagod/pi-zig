// settings.ts —— 设置对话框(openSettings)、会话搜索(openSearch)、全局键盘。
// 自 webui.js 切出。模型态直引 model.ts;外观方案直引 ui.ts;无环。
import { $, esc } from "./util";
import { prefs, savePrefs, ws, wsp } from "./state";
import {
  showToast, openDlg, closeDlg, dlgCancel, bindSeg, bindAuthPanel,
  setScheme, applyScheme, clipText,
} from "./ui";
import { segHtml, authPanelHtml, packageRows, pluginRows } from "./render";
import { sessData, closeMenus } from "./sessions";
import {
  THINK_LEVELS, APPROVALS, getThink, getCurModel, getApprovalMode,
  applySessionModel, setThink, setApproval, setSandbox, loadModels,
} from "./model";
import { th, inspect } from "./chat";
import { getLastUser, sendPlain } from "./composer";

// 自 wired:设置钮(侧栏底部 foot;绑定居此避环)。
($("setBtn") as HTMLElement).onclick = () => openSettings();

export async function openSettings() {
  let cfg: any = {};
  let models: string[] = [];
  let pkgs: any = { user: [], project: [] };
  try {
    const [cr, mr, pr] = await Promise.all([
      fetch("/api/config"),
      fetch("/api/models"),
      fetch("/api/packages?" + wsp),
    ]);
    cfg = await cr.json();
    models = await mr.json();
    if (!Array.isArray(models)) models = [];
    pkgs = await pr.json();
  } catch {}
  const defThink = cfg.defaultThinkingLevel || getThink() || "high";
  const defAppr = cfg.approvalMode || "yolo";
  const defModel = cfg.defaultModel || "";
  const thinkOpts = (typeof THINK_LEVELS !== "undefined" ? THINK_LEVELS : ["off", "low", "medium", "high"]).map(
    (v) => ({ v, l: v }),
  );
  const apprOpts = (typeof APPROVALS !== "undefined" ? APPROVALS : []).map((x) => ({ v: x.id, l: x.label }));
  function optHtml(id: string, cur: string, list: string[]) {
    const xs = list.slice();
    if (cur && xs.indexOf(cur) < 0) xs.unshift(cur);
    if (!xs.length) xs.push(cur || "");
    // 会话模型列:点击弹分组卡片菜单(modelMenu);默认模型仍是原生 select(选项即值)
    if (id === "setSessModel") {
      return (
        '<button type="button" class="set-sel set-model-btn" id="setSessModel" title="点击选择模型">' +
        esc(cur || "选择模型") +
        "</button>"
      );
    }
    return (
      '<select id="' +
      id +
      '" class="set-sel">' +
      xs
        .map(
          (m) =>
            '<option value="' +
            esc(m) +
            '"' +
            (m === cur ? " selected" : "") +
            ">" +
            esc(m) +
            "</option>",
        )
        .join("") +
      "</select>"
    );
  }
  // 自定义 provider(非内置目录)→ 账户 tab 底部卡片列表;内置键走 authPanelHtml
  const builtin = new Set([
    "deepseek", "openai", "anthropic", "xai", "openrouter", "groq",
    "mistral", "together", "fireworks", "cerebras", "moonshotai",
    "huggingface", "nvidia", "zai", "minimax",
  ]);
  const customs = (cfg.providers || []).filter((p: any) => !builtin.has(p.name));
  const provHtml = customs.length
    ? '<div class="prov-hint" style="margin-top:14px">自定义供应商(见 ~/.piz/models.json)</div>' +
      '<div class="prov-cards">' +
      customs
        .map(
          (p: any) =>
            '<div class="prov-card"><div class="prov-head"><span class="cred-dot ' +
            (p.hasKey ? "cred-ok" : "cred-miss") +
            '"></span><span class="prov-name">' +
            esc(p.name || "") +
            "</span>" +
            (p.api ? '<span class="prov-api">' + esc(p.api) + "</span>" : "") +
            (p.models && p.models.length ? '<span class="prov-api">' + p.models.length + " 模型</span>" : "") +
            "</div></div>",
        )
        .join("") +
      "</div>"
    : "";
  openDlg({
    cls: "set",
    title: "设置",
    body:
      '<div class="set-tabs" id="setTabs"><button type="button" data-tab="auth" class="on">账户</button><button type="button" data-tab="look">外观</button><button type="button" data-tab="agent">智能体</button><button type="button" data-tab="note">通知</button><button type="button" data-tab="about">关于</button></div>' +
      '<div id="setAuth">' +
      authPanelHtml(cfg) +
      provHtml +
      "</div>" +
      '<div id="setLook" hidden>' +
      '<div class="set-row"><div class="set-lab">配色</div>' +
      segHtml("scheme", [{ v: "light", l: "浅色" }, { v: "dark", l: "深色" }, { v: "system", l: "系统" }], prefs.scheme) +
      "</div>" +
      '<div class="set-row"><div class="set-lab">强调色</div>' +
      segHtml("accent", [{ v: "mono", l: "墨" }, { v: "blue", l: "蓝" }, { v: "green", l: "苔" }, { v: "amber", l: "赭" }], prefs.accent) +
      "</div>" +
      '<div class="set-row"><div class="set-lab">密度</div>' +
      segHtml("density", [{ v: "cozy", l: "舒适" }, { v: "compact", l: "紧凑" }], prefs.density || "cozy") +
      "</div>" +
      '<div class="set-row"><div class="set-lab">宽屏<span class="set-hint">内容列加宽</span></div>' +
      segHtml("wide", [{ v: "0", l: "窄" }, { v: "1", l: "宽" }], prefs.wide ? "1" : "0") +
      "</div>" +
      '<div class="set-row"><div class="set-lab">界面字号</div><input id="setFont" class="num-in" type="number" min="12" max="20" value="' +
      (prefs.uiFont || 14) +
      '"></div></div>' +
      '<div id="setAgent" hidden>' +
      '<div class="set-row"><div class="set-lab">本会话模型</div>' +
      optHtml("setSessModel", getCurModel(), models) +
      "</div>" +
      '<div class="set-row"><div class="set-lab">思考等级<span class="set-hint">写入默认并作用于当前会话</span></div>' +
      segHtml("think", thinkOpts, defThink) +
      "</div>" +
      '<div class="set-row"><div class="set-lab">本会话授权</div>' +
      segHtml("sessappr", apprOpts.length ? apprOpts : [{ v: "yolo", l: "yolo" }, { v: "ask", l: "ask" }, { v: "read-only", l: "read-only" }], getApprovalMode()) +
      "</div>" +
      '<div class="set-row"><div class="set-lab">新会话默认授权</div>' +
      segHtml("defappr", apprOpts.length ? apprOpts : [{ v: "yolo", l: "yolo" }, { v: "ask", l: "ask" }, { v: "read-only", l: "read-only" }], defAppr) +
      "</div>" +
      '<div class="set-row"><div class="set-lab">bash 沙箱<span class="set-hint">workspace 工作区可写；strict 再断网</span></div>' +
      segHtml("sandbox", [{ v: "off", l: "off" }, { v: "workspace", l: "workspace" }, { v: "strict", l: "strict" }], cfg.sandboxMode || "off") +
      "</div>" +
      '<div class="set-row"><div class="set-lab">默认模型<span class="set-hint">新会话用</span></div>' +
      optHtml("setDefModel", defModel || getCurModel(), models) +
      "</div>" +
      pluginRows(cfg.plugins) +
      packageRows(pkgs) +
      "</div>" +
      '<div id="setNote" hidden>' +
      '<div class="set-row"><div class="set-lab">完成时通知<span class="set-hint">浏览器系统通知</span></div><button type="button" class="sw' +
      (prefs.notify ? " on" : "") +
      '" id="swNotify"></button></div>' +
      '<div class="set-row"><div class="set-lab">完成时提示音</div><button type="button" class="sw' +
      (prefs.sound ? " on" : "") +
      '" id="swSound"></button></div></div>' +
      '<div id="setAbout" hidden>' +
      '<div class="set-row"><div class="set-lab">piz web<span class="set-hint">配置见 ~/.piz/</span></div></div>' +
      '<div class="set-row"><div class="set-lab">快捷键<span class="set-hint"><kbd>Ctrl</kbd><kbd>K</kbd> 搜会话 · <kbd>Ctrl</kbd><kbd>,</kbd> 设置 · <kbd>/</kbd> 命令 · <kbd>@./</kbd> 文件 · <kbd>!</kbd> 命令</span></div></div>' +
      "</div>",
  });
  const tabs = $("setTabs")!;
  const panels: any = { auth: $("setAuth"), look: $("setLook"), agent: $("setAgent"), note: $("setNote"), about: $("setAbout") };
  bindAuthPanel();
  tabs.onclick = (e: any) => {
    const b = e.target.closest("button");
    if (!b) return;
    for (const x of Array.from(tabs.querySelectorAll("button"))) x.classList.toggle("on", x === b);
    for (const k of Object.keys(panels)) panels[k].hidden = k !== b.dataset.tab;
  };
  bindSeg("scheme", (v) => {
    setScheme(v || "dark");
  });
  bindSeg("accent", (v) => {
    prefs.accent = v || "mono";
    prefs.accentPicked = true;
    savePrefs();
    applyScheme();
  });
  ($("setFont") as any).onchange = () => {
    prefs.uiFont = Math.min(20, Math.max(12, +($("setFont") as HTMLInputElement).value || 14));
    savePrefs();
    applyScheme();
  };
  bindSeg("density", (v) => {
    prefs.density = v || "cozy";
    savePrefs();
    applyScheme();
  });
  bindSeg("wide", (v) => {
    prefs.wide = v === "1";
    savePrefs();
    applyScheme();
  });
  if ($("setSessModel"))
    ($("setSessModel") as HTMLElement).onclick = (ev: any) => {
      ev.stopPropagation();
      closeMenus();
      loadModels(ev.currentTarget);
    };
  if ($("setDefModel"))
    ($("setDefModel") as any).onchange = () => {
      fetch("/api/config", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ setDefaultModel: ($("setDefModel") as HTMLSelectElement).value }),
      })
        .then((r) => r.json().catch(() => ({})))
        .then((j) => {
          if (j && j.ok === false) showToast(j.error || "保存默认模型失败");
        })
        .catch(() => showToast("保存默认模型失败"));
    };
  bindSeg("think", (v) => setThink(v || "high"));
  bindSeg("sessappr", (v) => setApproval(v || "ask"));
  bindSeg("defappr", (v) => {
    fetch("/api/config", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ setApprovalMode: v }),
    })
      .then((r) => r.json().catch(() => ({})))
      .then((j) => {
        if (j && j.ok === false) showToast(j.error || "保存默认授权失败");
      })
      .catch(() => showToast("保存默认授权失败"));
  });
  bindSeg("sandbox", (v) => {
    setSandbox(v || "off");
  });
  document.querySelectorAll("[data-plugin]").forEach((btn: any) => {
    btn.onclick = async () => {
      const name = btn.getAttribute("data-plugin");
      const on = !btn.classList.contains("on");
      btn.classList.toggle("on", on);
      try {
        await fetch("/api/config", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ setPlugin: { name, enabled: on } }),
        });
      } catch {
        btn.classList.toggle("on", !on);
      }
    };
  });
  ($("swNotify") as HTMLElement).onclick = async () => {
    if (!prefs.notify && window.Notification && Notification.permission === "default") {
      try {
        await Notification.requestPermission();
      } catch {}
    }
    prefs.notify = !prefs.notify;
    $("swNotify")!.classList.toggle("on", prefs.notify);
    savePrefs();
  };
  ($("swSound") as HTMLElement).onclick = () => {
    prefs.sound = !prefs.sound;
    $("swSound")!.classList.toggle("on", prefs.sound);
    savePrefs();
  };
}
export function openSearch() {
  const hits = sessData.list.slice();
  let sel = 0;
  openDlg({
    cls: "wide",
    title: "搜索会话",
    body:
      '<input id="dlgIn" class="dlg-in" placeholder="按标题或名字过滤…">' +
      '<div id="hitList" style="margin-top:8px;max-height:50vh;overflow:auto"></div>',
    focus: "dlgIn",
  });
  const box = $("hitList")!;
  const inp = $("dlgIn") as HTMLInputElement;
  function paint() {
    const q = (inp.value || "").toLowerCase().trim();
    const shown: any[] = [];
    for (const s of hits) {
      const title = s.title || s.name || "";
      const name = s.name || "";
      if (q && !title.toLowerCase().includes(q) && !name.toLowerCase().includes(q))
        continue;
      shown.push(s);
      if (shown.length >= 80) break;
    }
    if (sel >= shown.length) sel = Math.max(0, shown.length - 1);
    box.innerHTML = shown.length
      ? shown
          .map(
            (s, i) =>
              '<div class="hit' +
              (i === sel ? " on" : "") +
              '" data-name="' +
              esc(s.name) +
              '"><div class="hit-t">' +
              esc(s.title || s.name) +
              '</div><div class="hit-s">' +
              esc(s.name) +
              (s.msgs ? " · " + s.msgs + " 条" : "") +
              "</div></div>",
          )
          .join("")
      : '<div class="dlg-msg">无匹配会话</div>';
    const on = box.querySelector(".hit.on");
    if (on) on.scrollIntoView({ block: "nearest" });
    return shown;
  }
  function go(name: string) {
    if (!name) return;
    closeDlg();
    location.href =
      "/?session=" +
      encodeURIComponent(name) +
      (ws ? "&ws=" + encodeURIComponent(ws) : "");
  }
  inp.addEventListener("input", () => {
    sel = 0;
    paint();
  });
  inp.addEventListener("keydown", (e) => {
    const shown = paint();
    if (e.key === "ArrowDown") {
      e.preventDefault();
      sel = Math.min(shown.length - 1, sel + 1);
      paint();
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      sel = Math.max(0, sel - 1);
      paint();
    } else if (e.key === "Enter") {
      e.preventDefault();
      if (shown[sel]) go(shown[sel].name);
    }
  });
  box.onclick = (e: any) => {
    const h = e.target.closest(".hit");
    if (h) go(h.getAttribute("data-name"));
  };
  paint();
}
// ---- 全局键盘(Ctrl+K/,/Shift+C/R、"/" 聚焦、Esc 级联) ----
document.addEventListener("keydown", (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
    e.preventDefault();
    openSearch();
    return;
  }
  if ((e.metaKey || e.ctrlKey) && e.key === ",") {
    e.preventDefault();
    openSettings();
    return;
  }
  if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key.toLowerCase() === "c") {
    e.preventDefault();
    const md = th.querySelector(".a-turn:last-of-type .md") as HTMLElement | null;
    clipText(md && (md.dataset.raw || md.textContent), "已复制最后回复", "还没有回复");
    return;
  }
  if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key.toLowerCase() === "r") {
    e.preventDefault();
    if (getLastUser()) sendPlain(getLastUser());
    else showToast("没有可重发的输入");
    return;
  }
  // 输入框外按 "/":聚焦输入框并直接进斜杠菜单。
  if (
    e.key === "/" &&
    !e.metaKey &&
    !e.ctrlKey &&
    !e.altKey &&
    !e.isComposing
  ) {
    const ae = document.activeElement as HTMLElement | null;
    const editable =
      ae &&
      (ae.tagName === "INPUT" ||
        ae.tagName === "TEXTAREA" ||
        ae.isContentEditable);
    if (!editable && !$("overlay")!.classList.contains("open")) {
      e.preventDefault();
      const inp = $("inp") as HTMLTextAreaElement;
      inp.focus();
      if (!inp.value) {
        inp.value = "/";
        inp.dispatchEvent(new Event("input"));
      }
      return;
    }
  }
  if (e.key === "Escape") {
    const kh = $("keysHint");
    if (kh && !kh.hidden) {
      kh.hidden = true;
      kh.innerHTML = "";
      return;
    }
    if ($("overlay")!.classList.contains("open")) {
      e.preventDefault();
      dlgCancel();
      closeDlg();
      return;
    }
    const sm = $("slashMenu");
    if (sm && !sm.hidden) {
      sm.hidden = true;
      return;
    }
    if ($("inspect") && !$("inspect")!.hidden) {
      e.preventDefault();
      inspect.close();
    }
  }
});
