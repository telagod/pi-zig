// state.ts —— 会话/工作区定位与本地偏好(prefs)。
// 自 webui.js 切出;名与义一字未改,import 后调用点零改。
export interface Prefs {
  scheme: string;
  accent: string;
  accentPicked: boolean;
  uiFont: number;
  density: string;
  wide: boolean;
  notify: boolean;
  sound: boolean;
}

export const qp = new URLSearchParams(location.search);
export const sess = qp.get("session") || "default";
export const ws = decodeURIComponent(qp.get("ws") || "");
export const wsp = ws ? "ws=" + encodeURIComponent(ws) + "&" : "";
export const isMobile = () => window.innerWidth < 840;

const PREF_KEY = "piz.prefs";
export const prefs: Prefs = {
  scheme: "dark",
  accent: "mono",
  accentPicked: false,
  uiFont: 14,
  density: "cozy",
  wide: false,
  notify: false,
  sound: false,
};
try {
  Object.assign(prefs, JSON.parse(localStorage.getItem(PREF_KEY) || "{}"));
} catch {}
if (!prefs.accentPicked) prefs.accent = "mono";
try {
  const old = localStorage.getItem("piz.scheme");
  if (old && !localStorage.getItem(PREF_KEY)) prefs.scheme = old;
} catch {}
export function savePrefs() {
  try {
    localStorage.setItem(PREF_KEY, JSON.stringify(prefs));
  } catch {}
}

// 会话链接:root 未给则随当前工作区
export function sessUrl(name: string, root?: string) {
  const r = root !== undefined ? root : ws;
  return (
    "/?session=" +
    encodeURIComponent(name) +
    (r ? "&ws=" + encodeURIComponent(r) : "")
  );
}
