// sessions.ts —— 菜单助手 / 项目 / 会话列 / 会话操作。
import { $, esc, fmtTime, projectName } from "./util";
import { sess, ws, wsp, sessUrl } from "./state";
import { showToast, askText, askYes } from "./ui";
import { t, getLang } from "./i18n";
import { emit, on } from "./bus";

export const sessData = { list: [] as any[], arch: [] as any[], meta: {} as Record<string, any> };

let openMenu: any = null;
export function closeMenus() {
  for (const m of document.querySelectorAll(".menu.open"))
    m.classList.remove("open");
  openMenu = null;
}
on("popups:dismiss", closeMenus);
/// 统一锚定菜单(dsh Menu 原语之形):锚元素矩形 + 优先弹出方向/对齐。
/// side: "bl"(默认 左下)| "br"(右下)| "tr"(右上)| "tl"(左上);
/// 菜单卡片永远不越过视口(8px 边距),溢出时自动翻转。
export function openAt(id: string, btn: any, side: "bl" | "br" | "tr" | "tl" = "bl") {
  const m = $(id)!;
  const wasOpen = m.classList.contains("open");
  closeMenus();
  if (wasOpen) return;
  m.classList.add("open");
  const r = btn.getBoundingClientRect();
  const mw = m.offsetWidth,
    mh = m.offsetHeight;
  const GAP = 4,
    MARGIN = 8;
  let left: number, top: number;
  if (side === "bl" || side === "tl") left = Math.min(Math.max(r.left, MARGIN), innerWidth - mw - MARGIN);
  else left = Math.min(Math.max(r.right - mw, MARGIN), innerWidth - mw - MARGIN);
  if (side === "bl" || side === "br") {
    top = r.bottom + GAP;
    if (top + mh > innerHeight - MARGIN) top = Math.max(MARGIN, r.top - GAP - mh); // 翻上
  } else {
    top = r.top - GAP - mh;
    if (top < MARGIN) top = Math.min(r.bottom + GAP, innerHeight - mh - MARGIN); // 翻下
  }
  m.style.left = left + "px";
  m.style.top = top + "px";
  openMenu = m;
}
/// 菜单内容构造器:与 openAt 配套,产出 dsh 式菜单行(label + hint + check + danger)。
export function menuRow(opts: {
  label: string;
  hint?: string;
  check?: boolean;
  danger?: boolean;
  icon?: string;
  onclick: () => void;
}): HTMLElement {
  const d = document.createElement("div");
  d.className = "mi" + (opts.check ? " check" : "") + (opts.danger ? " danger" : "");
  d.innerHTML =
    (opts.icon ? '<span class="mi-ic">' + opts.icon + "</span>" : "") +
    '<span class="mi-tx">' + opts.label + "</span>" +
    (opts.hint ? '<span class="mi-hint">' + opts.hint + "</span>" : "");
  d.onclick = (e) => {
    e.stopPropagation();
    closeMenus();
    opts.onclick();
  };
  return d;
}
export function menuSep(): HTMLElement {
  const d = document.createElement("div");
  d.className = "sep";
  return d;
}
export function menuLabel(text: string): HTMLElement {
  const d = document.createElement("div");
  d.className = "menu-label";
  d.textContent = text;
  return d;
}
document.addEventListener("click", (e: any) => {
  if (
    !e.target.closest(".menu") &&
    !e.target.closest(".ib") &&
    !e.target.closest(".perm-pill") &&
    !e.target.closest(".mode-pill") &&
    !e.target.closest(".ch-brand") &&
    !e.target.closest(".ws-chip") &&
    !e.target.closest(".ch-ws") &&
    !e.target.closest(".set-model-btn") &&
    !e.target.closest(".kebab")
  )
    closeMenus();
});

// ---- 项目 ----
export function loadWorkspaces(): Promise<any[]> {
  return fetch("/api/workspaces")
    .then((r) => r.json())
    .catch(() => []);
}
export async function renderWsName() {
  const list = await loadWorkspaces();
  const cur = ws || (list[0] ? list[0].root : "");
  const nm = projectName(cur) || "piz";
  $("wsName")!.textContent = "piz";
  $("tbWs")!.textContent = nm;
  if ($("heroWsLbl")) $("heroWsLbl")!.textContent = nm || t("workspace", "Workspace");
  if ($("hWs") && !$("hWs")!.textContent) {
    $("hWs")!.textContent = nm;
    if ($("hSep")) $("hSep")!.style.display = nm ? "" : "none";
  }
  return list;
}
export async function addProject() {
  const root = await askText(t("addProject", "Add project"), "", getLang() === "zh" ? "绝对路径，如 /home/me/proj" : "Absolute path, e.g. /home/me/proj");
  if (!root) return;
  fetch("/api/workspaces", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ root }),
  })
    .then((r) => r.json())
    .then(() => {
      location.href = sessUrl("default", root);
    })
    .catch(() => showToast(getLang() === "zh" ? "无效目录" : "Invalid directory"));
}
export async function openWsMenu(btn: any) {
  const list = await renderWsName();
  const cur = ws || (list[0] ? list[0].root : "");
  const m = $("wsmenu")!;
  m.innerHTML = "";
  m.appendChild(menuLabel(t("workspace", "Workspace")));
  for (const w of list) {
    m.appendChild(
      menuRow({
        label: w.name || projectName(w.root),
        hint: w.root,
        check: w.root === cur,
        onclick: () => {
          if (w.root !== cur) location.href = sessUrl("default", w.root);
        },
      }),
    );
  }
  m.appendChild(menuSep());
  m.appendChild(
    menuRow({
      label: t("addProject", "Add project") + "…",
      icon: "＋",
      onclick: () => addProject(),
    }),
  );
  openAt("wsmenu", btn, "bl");
}
// 侧栏内联过滤:搜索按钮原地变输入框(实时过滤会话;✕ 清空)
export function initSideFilter() {
  const btn = $("searchBtn");
  if (!btn || btn.dataset.done) return;
  btn.dataset.done = "1";
  const box = document.createElement("div");
  box.className = "side-filter";
  box.innerHTML =
    '<span class="sf-ic">⌕</span><input type="text" placeholder="' + t("searchSessions", "Search sessions...") + '" spellcheck="false" /><button type="button" class="sf-x" title="' + t("clear", "Clear") + '">✕</button>';
  const inp = box.querySelector("input") as HTMLInputElement;
  const x = box.querySelector(".sf-x") as HTMLElement;

  x.hidden = true;
  let ft: any = 0;
  inp.addEventListener("input", () => {
    x.hidden = inp.value.length === 0;
    clearTimeout(ft);
    ft = setTimeout(() => {
      sideQ = (inp.value || "").toLowerCase().trim();
      loadSessions();
    }, 120);
  });
  x.addEventListener("click", () => {
    inp.value = "";
    x.hidden = true;
    sideQ = "";
    loadSessions();
    inp.focus();
  });
  btn.replaceWith(box);
  sideFilterEl = inp;
}
// 侧栏拖宽:5px 热区,记忆 localStorage
export function initSideGrip() {
  if (document.getElementById("sideGrip")) return;
  const side = $("side");
  const rail = document.querySelector(".side-rail");
  if (!side || !rail) return;
  // grip 挂 side 内右缘(absolute),不得插入 grid —— 第 4 个子元素会破坏三列布局
  side.style.position = "relative";
  const g = document.createElement("div");
  g.id = "sideGrip";
  side.appendChild(g);
  // --side-w 定义在 .app(局部变量),documentElement 上 set 会被遮蔽
  const appEl = document.querySelector(".app");
  try {
    const w = localStorage.getItem("piz.sideW");
    if (w && appEl) appEl.style.setProperty("--side-w", w + "px");
  } catch {}
  let dragging = false;
  g.addEventListener("mousedown", (e: any) => {
    dragging = true;
    document.body.classList.add("gripping");
    e.preventDefault();
  });
  window.addEventListener("mousemove", (e: any) => {
    if (!dragging) return;
    const w = Math.min(420, Math.max(200, e.clientX - side.getBoundingClientRect().left + 4));
    appEl && appEl.style.setProperty("--side-w", w + "px");
  });
  window.addEventListener("mouseup", () => {
    if (!dragging) return;
    dragging = false;
    document.body.classList.remove("gripping");
    try {
      localStorage.setItem("piz.sideW", String(Math.round(side.getBoundingClientRect().width)));
    } catch {}
  });
}

($("wsqBtn") as HTMLElement).onclick = (e: any) => {
  e.stopPropagation();
  openWsMenu(e.currentTarget);
};

// ---- 会话列表 ----
export function sessionRow(s: any, arch: boolean, wsRoot?: string) {
  const d = document.createElement("div");
  const here = !ws || !wsRoot || wsRoot === ws;
  d.className =
    "se" +
    (s.name === sess && here ? " on" : "") +
    (arch ? " arch" : "");
  const title = s.title || (s.name === "default" ? t("defaultSession", "Default session") : s.name);
  d.innerHTML =
    '<div class="srow"><span class="lead">' +
    (s.busy
      ? '<span class="spin"></span>'
      : s.unread
        ? '<span class="unread-dot"></span>'
        : "") +
    '</span><span class="st">' +
    esc(title) +
    "</span>" +
    (s.status === "awaitingQuestion"
      ? '<span class="tag info">' + t("statusAnswer", "Answer") + "</span>"
      : "") +
    (s.status === "awaitingApproval"
      ? '<span class="tag warn">' + t("statusApproval", "Approval") + "</span>"
      : "") +
    (s.status === "aborted"
      ? '<span class="tag danger">' + t("statusAborted", "Aborted") + "</span>"
      : "") +
    '<span class="sts">' +
    fmtTime(s.ts) +
    '</span><button class="kebab" title="' + t("sessionActions", "Session actions") + '">⋯</button></div>';
  d.onclick = () => {
    if (s.name === sess) {
      emit("session:select", s);
    } else {
      d.classList.add("switching");
      const wrap = $("wrap");
      if (wrap) wrap.style.opacity = "0.5";
      location.href = sessUrl(s.name, wsRoot);
    }
  };
  const kb = d.querySelector(".kebab") as HTMLElement;
  kb.onclick = (e: any) => {
    e.stopPropagation();
    openSessionMenu(kb, s, arch);
  };
  return d;
}
export function openSessionMenu(btn: any, s: any, arch: boolean) {
  const m = $("kmenu")!;
  m.innerHTML = "";
  if (!arch) {
    m.appendChild(
      menuRow({
        label: t("rename", "Rename"),
        icon: "✎",
        onclick: async () => {
          const tName = await askText(t("renameSession", "Rename session"), s.title || s.name, t("sessionTitle", "Session title"));
          if (tName === null) return;
          act({ act: "rename", name: tName, session: s.name }, (j) => {
            loadSessions();
            showToast(j && j.ok ? t("renamed", "Renamed") : t("failed", "Failed"));
          });
        },
      }),
    );
    m.appendChild(
      menuRow({
        label: t("forkSession", "Fork session"),
        icon: "✱",
        onclick: async () => {
          const n = await askText(t("forkSession", "Fork session"), "", t("forkHint", "New session name, empty for auto"));
          if (n === null) return;
          act({ act: "fork", name: n || "", session: s.name }, (j) => {
            if (j && j.name) {
              showToast(t("forked", "Forked ") + j.name);
              setTimeout(
                () =>
                  (location.href = sessUrl(j.name)),
                600,
              );
            }
          });
        },
      }),
    );
    m.appendChild(
      menuRow({
        label: t("archive", "Archive"),
        icon: "🗄",
        onclick: () => {
          act({ act: "archive", session: s.name }, (j) => {
            if (j && j.ok) {
              showToast(t("archived", "Archived"));
              if (s.name === sess)
                setTimeout(() => (location.href = sessUrl("default")), 400);
            }
            loadSessions();
          });
        },
      }),
    );
    m.appendChild(menuSep());
  }
  m.appendChild(
    menuRow({
      label: arch ? t("deleteForever", "Delete forever") : t("delete", "Delete"),
      icon: "🗑",
      danger: true,
      onclick: async () => {
        if (!(await askYes(t("deleteSession", "Delete session"), (arch ? t("deleteForever", "Delete forever ") : t("delete", "Delete ")) + s.name + "?"))) return;
        act({ act: "delete", session: s.name }, () => {
          loadSessions();
        });
      },
    }),
  );
  if (arch) {
    m.prepend(
      menuRow({
        label: t("restore", "Restore"),
        icon: "↩",
        onclick: () => {
          act({ act: "restore", session: s.name }, () => {
            loadSessions();
            showToast(t("restored", "Restored ") + s.name);
          });
        },
      }),
    );
  }
  openAt("kmenu", btn);
}
export function loadSessions() {
  Promise.all([
    loadWorkspaces(),
    fetch("/api/sessions?" + wsp)
      .then((r) => r.json())
      .catch(() => []),
  ])
    .then(([projects, list]) => {
      sessData.list = list.filter((s: any) => !s.archived);
      sessData.arch = list.filter((s: any) => s.archived);
      sessData.meta = {};
      for (const s of list) sessData.meta[s.name] = s;
      const sessList = sessData.list,
        archList = sessData.arch;
      const sl = $("slist")!;
      sl.innerHTML = "";
      const q = sideQ;
      const show = (s: any) =>
        !q || (s.name + (s.title || "")).toLowerCase().includes(q);
      const cur = ws || (projects[0] ? projects[0].root : "");
      const lab = document.createElement("div");
      lab.className = "side-lab";
      lab.textContent = t("workspace", "Workspace");
      sl.appendChild(lab);
      if (!projects.length) {
        const empty = document.createElement("div");
        empty.className = "sg-name";
        empty.style.padding = "6px 8px";
        empty.textContent = t("currentDir", "Current directory");
        sl.appendChild(empty);
      }
      for (const w of projects) {
        const isCur = w.root === cur;
        const gh = document.createElement("div");
        gh.className = "sg-head" + (isCur ? " on" : "");
        gh.title = w.root;
        gh.innerHTML =
          '<span class="sg-chev' +
          (isCur ? " open" : "") +
          '">▶</span><span class="sg-name">' +
          esc(w.name || projectName(w.root)) +
          "</span>" +
          (isCur
            ? '<span class="sg-cnt">' + sessList.length + "</span>"
            : "");
        sl.appendChild(gh);
        if (isCur) {
          const wrap = document.createElement("div");
          wrap.className = "sg-chats";
          const vis = sessList.filter(show);
          if (!vis.length && q) {
            const ne = document.createElement("div");
            ne.className = "sg-name";
            ne.textContent = t("noMatchingSessions", "No matching sessions");
            wrap.appendChild(ne);
          } else if (!vis.length) {
            const ne = document.createElement("div");
            ne.className = "sg-name";
            ne.textContent = t("noSessionsHint", "No sessions yet. Send a message to start.");
            wrap.appendChild(ne);
          }
          for (const s of vis) wrap.appendChild(sessionRow(s, false, w.root));
          if (archList.length) {
            const se = document.createElement("div");
            se.className = "sg-arch";
            se.innerHTML =
              '<span class="sg-chev">▶</span><span>' + t("archive", "Archive") + '</span><span class="sg-arch-n">' +
              archList.length +
              "</span>";
            const awrap = document.createElement("div");
            awrap.className = "arch-chats";
            awrap.hidden = true;
            for (const s of archList)
              awrap.appendChild(sessionRow(s, true, w.root));
            wrap.appendChild(se);
            wrap.appendChild(awrap);
            se.onclick = (e: any) => {
              e.stopPropagation();
              const open = se.classList.toggle("open");
              awrap.hidden = !open;
            };
          }
          sl.appendChild(wrap);
          gh.onclick = () => {
            const open = (gh
              .querySelector(".sg-chev") as HTMLElement)
              .classList.toggle("open");
            wrap.style.display = open ? "" : "none";
          };
        } else {
          gh.onclick = () => {
            location.href = sessUrl("default", w.root);
          };
        }
      }
      const addp = document.createElement("button");
      addp.className = "btn-add-proj";
      addp.type = "button";
      addp.innerHTML = '<span class="pl">＋</span><span>' + t("addProject", "Add project") + '</span>';
      addp.onclick = () => addProject();
      sl.appendChild(addp);
      const sb = $("sbody");
      if (sb) {
        sb.innerHTML = "";
        for (const s of sessList) sb.appendChild(sessionRow(s, false, cur));
        if (!sessList.length && !archList.length) {
          const ne2 = document.createElement("div");
          ne2.className = "sg-name";
          ne2.style.padding = "12px 14px";
          ne2.textContent = t("noSessionsHint", "No sessions yet. Send a message to start.");
          sb.appendChild(ne2);
        }
        if (archList.length) {
          const se2 = document.createElement("div");
          se2.className = "sg-sep";
          sb.appendChild(se2);
          const sh = document.createElement("div");
          sh.className = "sg-arch";
          sh.textContent = t("archive", "Archive") + " " + archList.length;
          sb.appendChild(sh);
          for (const s of archList)
            sb.appendChild(sessionRow(s, true, cur));
        }
      }
    })
    .catch(() => showToast(t("sessionsLoadFail", "Failed to load sessions")));
}
// 搜索框过滤态:内联侧栏过滤输入(loadSessions 的 show 读它)
let sideQ = "";
export function currentFilterQ(): string {
  return sideQ;
}
let sideFilterEl: HTMLInputElement | null = null;
export function setSideFilter(q: string) {
  sideQ = q;
  if (sideFilterEl) sideFilterEl.value = q;
}
// 旧接口引用(searchQ 全局)保持兼容
export const searchQ: any = {
  get value() {
    return sideQ;
  },
  set value(v: string) {
    sideQ = String(v || "");
  },
};

// ---- 会话操作 ----
export function act(body: any, then?: (j: any) => void) {
  // body.session 可为指定目标(会话行菜单操作);缺省用当前打开的 sess。
  const target = body && body.session ? body.session : sess;
  fetch("/api/action?" + wsp + "session=" + encodeURIComponent(target), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  })
    .then((r) => r.json())
    .then((j) => {
      if (then) then(j);
    })
    .catch(() => showToast(t("actionFail", "Action failed")));
}

