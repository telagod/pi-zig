// sessions.ts —— 菜单助手 / 项目 / 会话列 / 会话操作。
// 自 webui.js 切出。approvalMode/setModeBtn/closeSheet 属 main,经 sessHooks.applySessionMeta 注入(解循环)。
// sessList/archList/sessMeta 以 sessData 活引用外供(main 的搜索与数字跳会读之)。
import { $, esc, fmtTime, projectName } from "./util";
import { sess, ws, wsp, sessUrl } from "./state";
import { showToast, askText, askYes } from "./ui";

export const sessHooks: { applySessionMeta: ((s: any) => void) | null } = {
  applySessionMeta: null,
};

export const sessData = { list: [] as any[], arch: [] as any[], meta: {} as Record<string, any> };

let openMenu: any = null;
export function closeMenus() {
  for (const m of document.querySelectorAll(".menu.open"))
    m.classList.remove("open");
  openMenu = null;
}
export function openAt(id: string, btn: any) {
  closeMenus();
  const m = $(id)!;
  m.classList.add("open");
  const r = btn.getBoundingClientRect();
  const mw = m.offsetWidth,
    mh = m.offsetHeight;
  m.style.left = Math.min(r.right - mw, innerWidth - mw - 8) + "px";
  m.style.top = Math.min(r.bottom + 4, innerHeight - mh - 8) + "px";
  openMenu = m;
}
document.addEventListener("click", (e: any) => {
  if (
    !e.target.closest(".menu") &&
    !e.target.closest(".ib") &&
    !e.target.closest(".perm-pill") &&
    !e.target.closest(".mode-pill") &&
    !e.target.closest(".ch-brand") &&
    !e.target.closest(".ws-chip") &&
    !e.target.closest(".ch-ws")
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
  if ($("heroWsLbl")) $("heroWsLbl")!.textContent = nm || "选择项目";
  if ($("hWs") && !$("hWs")!.textContent) {
    $("hWs")!.textContent = nm;
    if ($("hSep")) $("hSep")!.style.display = nm ? "" : "none";
  }
  return list;
}
export async function addProject() {
  const root = await askText("添加项目", "", "绝对路径，如 /home/me/proj");
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
    .catch(() => showToast("无效目录"));
}
export async function openWsMenu(btn: any) {
  const list = await renderWsName();
  const cur = ws || (list[0] ? list[0].root : "");
  const m = $("wsmenu")!;
  m.innerHTML = "";
  for (const w of list) {
    const d = document.createElement("div");
    d.className = "mi" + (w.root === cur ? " check" : "");
    d.textContent = (w.name || projectName(w.root)) + " · " + w.root;
    d.title = w.root;
    d.onclick = () => {
      if (w.root !== cur) location.href = sessUrl("default", w.root);
    };
    m.appendChild(d);
  }
  const sep = document.createElement("div");
  sep.className = "sep";
  m.appendChild(sep);
  const add = document.createElement("div");
  add.className = "mi";
  add.textContent = "＋ 添加项目…";
  add.onclick = () => {
    closeMenus();
    addProject();
  };
  m.appendChild(add);
  openAt("wsmenu", btn);
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
  const title = s.name === "default" ? "默认会话" : s.title || s.name;
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
      ? '<span class="tag info">回答</span>'
      : "") +
    (s.status === "awaitingApproval"
      ? '<span class="tag warn">审批</span>'
      : "") +
    (s.status === "aborted"
      ? '<span class="tag danger">中止</span>'
      : "") +
    '<span class="sts">' +
    fmtTime(s.ts) +
    '</span><button class="kebab" title="操作">⋯</button></div>';
  d.onclick = () => {
    if (s.name === sess) {
      sessHooks.applySessionMeta?.(s);
    } else location.href = sessUrl(s.name, wsRoot);
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
    const ren = document.createElement("div");
    ren.className = "mi";
    ren.textContent = "✎ 重命名";
    ren.onclick = async () => {
      closeMenus();
      const t = await askText("重命名会话", s.title || s.name, "会话标题");
      if (t === null) return;
      act({ act: "rename", name: t, session: s.name }, (j) => {
        loadSessions();
        showToast(j && j.ok ? "已重命名" : "失败");
      });
    };
    m.appendChild(ren);
    const fork = document.createElement("div");
    fork.className = "mi";
    fork.textContent = "✱ 派生会话";
    fork.onclick = async () => {
      closeMenus();
      const n = await askText("派生会话", "", "新会话名，留空自动");
      if (n === null) return;
      act({ act: "fork", name: n || "", session: s.name }, (j) => {
        if (j && j.name) {
          showToast("已派生 " + j.name);
          setTimeout(
            () =>
              (location.href = sessUrl(j.name)),
            600,
          );
        }
      });
    };
    m.appendChild(fork);
    const arc = document.createElement("div");
    arc.className = "mi";
    arc.textContent = "🗄 归档";
    arc.onclick = () => {
      closeMenus();
      act({ act: "archive", session: s.name }, (j) => {
        if (j && j.ok) {
          showToast("已归档");
          if (s.name === sess)
            setTimeout(() => (location.href = sessUrl("default")), 400);
        }
        loadSessions();
      });
    };
    m.appendChild(arc);
    const sep = document.createElement("div");
    sep.className = "sep";
    m.appendChild(sep);
  }
  const del = document.createElement("div");
  del.className = "mi danger";
  del.textContent = arch ? "永久删除" : "删除";
  del.onclick = async () => {
    closeMenus();
    if (!(await askYes("删除会话", "永久删除 " + s.name + "？"))) return;
    act({ act: "delete", session: s.name }, () => {
      loadSessions();
    });
  };
  m.appendChild(del);
  if (arch) {
    const res = document.createElement("div");
    res.className = "mi";
    res.textContent = "↩ 恢复";
    res.onclick = () => {
      closeMenus();
      act({ act: "restore", session: s.name }, () => {
        loadSessions();
        showToast("已恢复 " + s.name);
      });
    };
    m.prepend(res);
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
      const q = ((searchQ && searchQ.value) || "").toLowerCase();
      const show = (s: any) =>
        !q || (s.name + (s.title || "")).toLowerCase().includes(q);
      const cur = ws || (projects[0] ? projects[0].root : "");
      const lab = document.createElement("div");
      lab.className = "side-lab";
      lab.textContent = "项目";
      sl.appendChild(lab);
      if (!projects.length) {
        const empty = document.createElement("div");
        empty.className = "sg-name";
        empty.style.padding = "6px 8px";
        empty.textContent = "当前目录";
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
            ne.textContent = "无匹配会话";
            wrap.appendChild(ne);
          } else if (!vis.length) {
            const ne = document.createElement("div");
            ne.className = "sg-name";
            ne.textContent = "还没有会话,发一条消息开始";
            wrap.appendChild(ne);
          }
          for (const s of vis) wrap.appendChild(sessionRow(s, false, w.root));
          if (archList.length) {
            const se = document.createElement("div");
            se.className = "sg-arch";
            se.textContent = "归档 " + archList.length;
            wrap.appendChild(se);
            for (const s of archList)
              wrap.appendChild(sessionRow(s, true, w.root));
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
      addp.innerHTML = '<span class="pl">＋</span><span>添加项目</span>';
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
          ne2.textContent = "还没有会话,发一条消息开始";
          sb.appendChild(ne2);
        }
        if (archList.length) {
          const se2 = document.createElement("div");
          se2.className = "sg-sep";
          sb.appendChild(se2);
          const sh = document.createElement("div");
          sh.className = "sg-arch";
          sh.textContent = "归档 " + archList.length;
          sb.appendChild(sh);
          for (const s of archList)
            sb.appendChild(sessionRow(s, true, cur));
        }
      }
    })
    .catch(() => showToast("sessions load failed"));
}
// 搜索框过滤态(脱壳元素,值随 openSearch 写入)
export const searchQ = document.createElement("input");
searchQ.id = "searchQ";

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
    .catch(() => showToast("action failed"));
}
