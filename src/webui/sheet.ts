// sheet.ts —— 移动 sheet(下滑关闭)、侧栏折叠钮、顶栏 sheet 钮、空态 welcome。
// 自 webui.js 切出。setBtn 之线归 settings.ts(sheet↛settings,避环)。
import { $ } from "./util";
import { sessUrl } from "./state";
import { loadSessions, openWsMenu } from "./sessions";

const sheet = $("sheet")!;
export function openSheet() {
  loadSessions();
  sheet.classList.add("open");
  document.body.style.overflow = "hidden"; // 锁住背后滚动
}
export function closeSheet() {
  sheet.classList.remove("open");
  document.body.style.overflow = "";
}
// 下滑关闭:按住 grab/头部往下拖超过 70px 或快甩即收。
(function () {
  const pnl = $("spnl");
  if (!pnl) return;
  let y0 = 0,
    dy = 0,
    t0 = 0,
    drag = false;
  pnl.addEventListener("touchstart", (e: any) => {
    const onHandle = e.target.closest(".grab, .shd");
    const atTop = $("sbody") && ($("sbody") as HTMLElement).scrollTop <= 0;
    drag = !!(onHandle || atTop);
    y0 = e.touches[0].clientY;
    t0 = Date.now();
    dy = 0;
    if (drag) pnl.style.transition = "none";
  }, { passive: true });
  pnl.addEventListener("touchmove", (e: any) => {
    if (!drag) return;
    dy = Math.max(0, e.touches[0].clientY - y0);
    pnl.style.transform = "translateY(" + dy + "px)";
  }, { passive: true });
  pnl.addEventListener("touchend", () => {
    if (!drag) return;
    drag = false;
    pnl.style.transition = "";
    pnl.style.transform = "";
    const fling = Date.now() - t0 < 250 && dy > 30;
    if (dy > 70 || fling) closeSheet();
  });
})();
($("scrim") as HTMLElement).onclick = closeSheet;
($("scls") as HTMLElement).onclick = closeSheet;
($("tbMid") as HTMLElement).onclick = openSheet;
($("newBtn") as HTMLElement).onclick = () => {
  location.href = sessUrl(Math.random().toString(36).slice(2, 8));
};
($("colBtn") as HTMLElement).onclick = () => {
  document.body.classList.add("collapsed");
  try {
    localStorage.setItem("piz.sidebar", "1");
  } catch {}
};
($("expBtn") as HTMLElement).onclick = () => {
  document.body.classList.remove("collapsed");
  try {
    localStorage.setItem("piz.sidebar", "0");
  } catch {}
};
(document.querySelector(".ch-brand") as HTMLElement).onclick = (e: any) => {
  e.stopPropagation();
  openWsMenu(e.currentTarget);
};
// 空状态
export function hideWelcome() {
  const x = $("welcome");
  if (x) x.remove();
  $("app")?.classList.remove("hero");
}
