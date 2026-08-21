// ui.ts —— toast / 对话框 / seg 与 auth 面板 DOM 绑定。
// 自 webui.js 切出。openDlg 开场要收菜单与补全 —— 彼在 main,经 dlgHooks 迟绑注入(解循环)。
import { $, esc } from "./util";
import { prefs, savePrefs } from "./state";

// ---- toast ----
const toastEl = $("toast")!;
let toastT: any = null;
export function showToast(t: string) {
  toastEl.textContent = t;
  toastEl.classList.add("show");
  clearTimeout(toastT);
  toastT = setTimeout(() => toastEl.classList.remove("show"), 2200);
}

// 迟绑钩:main 在启动时把 closeMenus/hideSlash/hideBang 挂上
export const dlgHooks: { closeMenus: (() => void) | null; hideSlash: (() => void) | null; hideBang: (() => void) | null } = {
  closeMenus: null,
  hideSlash: null,
  hideBang: null,
};

let dlgOnok: any = null,
  dlgOncancel: any = null;
export function dlgCancel() {
  if (dlgOncancel) dlgOncancel();
}
let dlgPrevFocus: any = null;
export function closeDlg() {
  const ov = $("overlay")!;
  ov.classList.remove("open", "sheet");
  ov.innerHTML = "";
  dlgOnok = dlgOncancel = null;
  // 焦点还给弹出前的元素(还在文档里才还)。
  if (dlgPrevFocus && document.contains(dlgPrevFocus)) {
    try { dlgPrevFocus.focus({ preventScroll: true }); } catch {}
  }
  dlgPrevFocus = null;
}
export function openDlg(opts: any) {
  dlgHooks.closeMenus?.();
  dlgHooks.hideSlash?.();
  dlgHooks.hideBang?.();
  const ov = $("overlay")!;
  ov.classList.add("open");
  if (opts.cls === "set") ov.classList.add("sheet");
  ov.innerHTML =
    '<div class="dlg ' +
    (opts.cls || "") +
    '" role="dialog"><div class="dlg-hd"><span>' +
    esc(opts.title || "") +
    '</span><button class="dlg-x" id="dlgX" type="button">✕</button></div><div class="dlg-bd">' +
    (opts.body || "") +
    "</div>" +
    (opts.ok
      ? '<div class="dlg-ft">' +
        (opts.cancel
          ? '<button class="btn" id="dlgCancel" type="button">' +
            esc(opts.cancel) +
            "</button>"
          : "") +
        '<button class="btn ' +
        (opts.danger ? "btn-d" : "btn-p") +
        '" id="dlgOk" type="button">' +
        esc(opts.ok) +
        "</button></div>"
      : "") +
    "</div>";
  dlgOnok = opts.onok || null;
  dlgOncancel = opts.oncancel || null;
  dlgPrevFocus = document.activeElement; // 关时还原焦点
  $("dlgX")!.onclick = () => {
    if (dlgOncancel) dlgOncancel();
    closeDlg();
  };
  const cxl = $("dlgCancel");
  if (cxl)
    cxl.onclick = () => {
      if (dlgOncancel) dlgOncancel();
      closeDlg();
    };
  const ok = $("dlgOk");
  if (ok)
    ok.onclick = () => {
      const r = dlgOnok && dlgOnok();
      if (r !== false) closeDlg();
    };
  ov.onclick = (e) => {
    if (e.target === ov) {
      if (dlgOncancel) dlgOncancel();
      closeDlg();
    }
  };
  if (opts.focus && $(opts.focus)) {
    const el: any = $(opts.focus);
    el.focus();
    if (el.select) el.select();
  } else {
    // 默认焦点给第一个可输入控件,否则给主按钮 —— 键盘流不用先 Tab 一圈。
    const el = ov.querySelector(
      ".dlg-bd input, .dlg-bd textarea, .dlg-bd select, .dlg-bd button",
    ) as any;
    const btn = el || $("dlgOk");
    if (btn) btn.focus({ preventScroll: true });
  }
}
export function askText(title: string, value?: string, placeholder?: string): Promise<string | null> {
  return new Promise((resolve) => {
    openDlg({
      title,
      body:
        '<input id="dlgIn" class="dlg-in" value="' +
        esc(value || "") +
        '" placeholder="' +
        esc(placeholder || "") +
        '">',
      ok: "确定",
      cancel: "取消",
      focus: "dlgIn",
      onok: () => {
        resolve(($("dlgIn") as HTMLInputElement).value);
      },
      oncancel: () => resolve(null),
    });
    $("dlgIn")!.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        resolve(($("dlgIn") as HTMLInputElement).value);
        closeDlg();
      }
    });
  });
}
export function askYes(title: string, msg: string): Promise<boolean> {
  return new Promise((resolve) => {
    openDlg({
      title,
      body: '<p class="dlg-msg">' + esc(msg) + "</p>",
      ok: "确定",
      danger: true,
      cancel: "取消",
      onok: () => resolve(true),
      oncancel: () => resolve(false),
    });
  });
}
// 剪贴板 + toast
export function clipText(text: string, ok?: string, fail?: string) {
  if (!text) {
    showToast(fail || "没有内容");
    return;
  }
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard
      .writeText(text)
      .then(() => showToast(ok || "已复制"))
      .catch(() => showToast(fail || "复制失败"));
  } else showToast(fail || "复制失败");
}
export function bindSeg(name: string, fn: (v: string | null) => void) {
  const box = document.querySelector('[data-seg="' + name + '"]') as HTMLElement | null;
  if (!box) return;
  box.onclick = (e: any) => {
    const b = e.target.closest("button");
    if (!b) return;
    for (const x of box.querySelectorAll("button")) x.classList.remove("on");
    b.classList.add("on");
    fn(b.getAttribute("data-v"));
  };
}
export function bindAuthPanel() {
  document.querySelectorAll(".auth-row").forEach((row: any) => {
    const name = row.getAttribute("data-prov");
    const inp = row.querySelector(".auth-key");
    const save = row.querySelector(".auth-save");
    const oauthBtn = row.querySelector(".auth-oauth");
    if (save)
      save.onclick = () => {
        const key = (inp && inp.value) || "";
        if (!key) {
          showToast("paste an API key");
          return;
        }
        fetch("/api/config", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ setAuth: { name, key } }),
        })
          .then((r) => r.json())
          .then((j) => {
            showToast(j && j.ok ? "saved " + name : "save failed");
            if (inp) inp.value = "";
          })
          .catch(() => showToast("save failed"));
      };
    if (oauthBtn)
      oauthBtn.onclick = async () => {
        const hint = row.querySelector(".auth-dev");
        try {
          const r = await fetch("/api/oauth/start", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ provider: name }),
          });
          const j = await r.json();
          if (!j || !j.ok) {
            showToast("oauth start failed");
            return;
          }
          if (j.user_code) {
            if (hint) {
              hint.hidden = false;
              hint.textContent = "Enter code " + j.user_code + " at " + (j.verification_uri || "");
            }
            if (j.verification_uri) window.open(j.verification_uri, "_blank");
            showToast("code " + j.user_code);
          } else if (j.url) {
            window.open(j.url, "_blank");
            showToast("finish sign-in in the new tab");
          } else {
            showToast("oauth start failed");
            return;
          }
          const path = j.user_code ? "/api/oauth/poll?state=" : "/api/oauth/status?state=";
          const t0 = Date.now();
          const tick = async () => {
            if (Date.now() - t0 > 180000) {
              showToast("oauth timed out");
              return;
            }
            const s = await fetch(path + encodeURIComponent(j.state)).then((x) => x.json());
            if (s && s.done && s.ok) {
              showToast("signed in");
              if (hint) hint.hidden = true;
              return;
            }
            if (s && s.done && !s.ok) {
              showToast("sign-in failed");
              return;
            }
            setTimeout(tick, 1500);
          };
          setTimeout(tick, 1500);
        } catch {
          showToast("oauth start failed");
        }
      };
  });
}

// ---- 外观方案(配色/强调色/密度/宽屏/字号):自 main 迁入 ----
export function setScheme(v: string) {
  const map: any = { auto: "system", light: "light", dark: "dark", system: "system" };
  const next = map[String(v || "").trim()];
  if (!next) return false;
  prefs.scheme = next;
  savePrefs();
  applyScheme();
  return true;
}
export function applyScheme() {
  const root = document.documentElement;
  root.dataset.colorScheme = prefs.scheme || "dark";
  root.dataset.accent = prefs.accent || "mono";
  root.dataset.density = prefs.density || "cozy";
  root.dataset.wide = prefs.wide ? "1" : "";
  const fs = (prefs.uiFont || 14) + "px";
  root.style.setProperty("--ui-font-size", fs);
  root.style.setProperty("--text-base", fs);
  const dark =
    prefs.scheme === "dark" ||
    (prefs.scheme === "system" &&
      window.matchMedia &&
      window.matchMedia("(prefers-color-scheme: dark)").matches);
  const tm = document.querySelector('meta[name="theme-color"]');
  if (tm) tm.setAttribute("content", dark ? "#151517" : "#ffffff");
}
applyScheme();
if (window.matchMedia) {
  try {
    (window.matchMedia("(prefers-color-scheme: dark)") as any).addEventListener(
      "change",
      applyScheme,
    );
  } catch {}
}
