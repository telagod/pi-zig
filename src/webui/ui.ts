// ui.ts —— toast / 对话框 / seg 与 auth 面板 DOM 绑定。
import { $, esc } from "./util";
import { prefs, savePrefs } from "./state";
import { t, getLang } from "./i18n";
import { emit } from "./bus";

// ---- toast ----
const toastEl = $("toast")!;
let toastT: any = null;
export function showToast(t: string) {
  toastEl.textContent = t;
  toastEl.classList.add("show");
  clearTimeout(toastT);
  toastT = setTimeout(() => toastEl.classList.remove("show"), 2200);
}

let dlgOnok: any = null,
  dlgOncancel: any = null;
export function dlgCancel() {
  if (dlgOncancel) dlgOncancel();
}
let dlgPrevFocus: any = null;
export function closeDlg() {
  const ov = $("overlay")!;
  ov.classList.remove("open");
  ov.innerHTML = "";
  document.body.style.overflow = "";
  dlgOnok = dlgOncancel = null;
  // 焦点还给弹出前的元素(还在文档里才还)。
  if (dlgPrevFocus && document.contains(dlgPrevFocus)) {
    try { dlgPrevFocus.focus({ preventScroll: true }); } catch {}
  }
  dlgPrevFocus = null;
}
export function openDlg(opts: any) {
  emit("popups:dismiss");
  const ov = $("overlay")!;
  ov.classList.add("open");
  document.body.style.overflow = "hidden";
  ov.innerHTML =
    '<div class="dlg ' +
    (opts.cls || "") +
    '" role="dialog" aria-modal="true"><div class="dlg-hd"><span>' +
    esc(opts.title || "") +
    '</span><button class="dlg-x" id="dlgX" type="button" aria-label="' + t("close", "Close") + '">✕</button></div><div class="dlg-bd">' +
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
  // 焦点陷阱:Tab / Shift+Tab 在对话框内循环,防止焦点逃逸至背后界面
  const dlgEl = ov.querySelector(".dlg") as HTMLElement | null;
  if (dlgEl) {
    dlgEl.addEventListener("keydown", (e: KeyboardEvent) => {
      if (e.key !== "Tab") return;
      const focusables = dlgEl.querySelectorAll<HTMLElement>(
        'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
      );
      if (!focusables.length) return;
      const first = focusables[0];
      const last = focusables[focusables.length - 1];
      if (e.shiftKey) {
        if (document.activeElement === first) {
          e.preventDefault();
          last.focus();
        }
      } else {
        if (document.activeElement === last) {
          e.preventDefault();
          first.focus();
        }
      }
    });
  }
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
      ok: t("ok", "OK"),
      cancel: t("cancel", "Cancel"),
      focus: "dlgIn",
      onok: () => {
        resolve(($("dlgIn") as HTMLInputElement).value);
      },
      oncancel: () => resolve(null),
    });
    $("dlgIn")!.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.isComposing && (e as any).keyCode !== 229) {
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
      ok: t("ok", "OK"),
      danger: true,
      cancel: t("cancel", "Cancel"),
      onok: () => resolve(true),
      oncancel: () => resolve(false),
    });
  });
}
// 剪贴板 + toast
export function clipText(text: string, ok?: string, fail?: string) {
  if (!text) {
    showToast(fail || t("noContent", "No content"));
    return;
  }
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard
      .writeText(text)
      .then(() => showToast(ok || t("copied", "Copied")))
      .catch(() => showToast(fail || t("copyFailed", "Failed to copy")));
  } else showToast(fail || t("copyFailed", "Failed to copy"));
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
          showToast(t("pasteApiKey", "Please paste API key"));
          return;
        }
        fetch("/api/config", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ setAuth: { name, key } }),
        })
          .then((r) => r.json())
          .then((j) => {
            showToast(j && j.ok ? t("saved", "Saved ") + name : t("saveFail", "Save failed"));
            if (inp) inp.value = "";
          })
          .catch(() => showToast(t("saveFail", "Save failed")));
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
            showToast(getLang() === "zh" ? "OAuth 启动失败" : "Failed to start OAuth");
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
            showToast(getLang() === "zh" ? "请在新标签页完成登录" : "Please complete login in new tab");
          } else {
            showToast(getLang() === "zh" ? "OAuth 启动失败" : "Failed to start OAuth");
            return;
          }
          const path = j.user_code ? "/api/oauth/poll?state=" : "/api/oauth/status?state=";
          const t0 = Date.now();
          const tick = async () => {
            if (Date.now() - t0 > 180000) {
              showToast(getLang() === "zh" ? "OAuth 超时" : "OAuth timed out");
              return;
            }
            const s = await fetch(path + encodeURIComponent(j.state)).then((x) => x.json());
            if (s && s.done && s.ok) {
              showToast(getLang() === "zh" ? "已登录" : "Logged in");
              if (hint) hint.hidden = true;
              return;
            }
            if (s && s.done && !s.ok) {
              showToast(getLang() === "zh" ? "登录失败" : "Login failed");
              return;
            }
            setTimeout(tick, 1500);
          };
          setTimeout(tick, 1500);
        } catch {
          showToast(getLang() === "zh" ? "OAuth 启动失败" : "Failed to start OAuth");
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
