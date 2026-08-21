// jobs.ts —— 后台活动触发钮 + 弹层(借 dsh ui-jobs 之形)。
// header 一颗 ⠿ 钮,活动时带计数 badge;点开平铺列表,esc/点外关。
// 数据同 composer 活动条(/api/activity 轮询),本模块只做容器与渲染,无轮询。
// opens 状态以 DOM(.menu.open)为准:closeMenus(其它菜单触发)会摘掉 open,
// 本模块 tick 时自纠,不会残留假开态。
import { $, esc, fmtTok } from "./util";

let lastList: any[] = [];

function isOpen(): boolean {
  return $("jobsPop")?.classList.contains("open") ?? false;
}

export function setupJobs() {
  const btn = $("hJobs");
  if (!btn) return;
  btn.onclick = (e) => {
    e.stopPropagation();
    toggleJobs();
  };
  document.addEventListener("click", (e) => {
    if (!isOpen()) return;
    const t = e.target as HTMLElement;
    if (t.closest?.("#jobsPop,#hJobs")) return;
    closeJobs();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && isOpen()) closeJobs();
  });
}

export function closeJobs() {
  $("jobsPop")?.classList.remove("open");
  $("hJobs")?.classList.remove("open");
}

export function toggleJobs() {
  if (isOpen()) {
    closeJobs();
    return;
  }
  const p = $("jobsPop");
  if (p) p.classList.add("open");
  $("hJobs")?.classList.add("open");
  refreshJobs(lastList);
}

function fmtRow(a: any): string {
  const sec = a.ms < 10000 ? (a.ms / 1000).toFixed(1) : String(Math.round(a.ms / 1000));
  const lim = a.limit_ms && !a.detached ? "/" + Math.round(a.limit_ms / 1000) + "s" : "";
  const by = a.bytes ? " · " + fmtTok(a.bytes) : "";
  const retry = a.attempt > 1 ? " · retry " + (a.attempt - 1) : "";
  const glyph = a.detached ? "~" : a.kind === "subagent" ? "●" : a.kind === "http" ? "↻" : "▸";
  const det = a.detail ? '<span class="jr-d">' + esc(a.detail) + "</span>" : "";
  return (
    '<div class="jr' + (a.detached ? " bg" : "") + '">' +
    '<span class="jr-g">' + glyph + "</span>" +
    '<span class="jr-n">' + esc(a.name || "job") + "</span>" +
    det +
    '<span class="jr-t">' + sec + "s" + lim + by + retry + "</span>" +
    "</div>"
  );
}

export function refreshJobs(list: any[]) {
  lastList = list;
  const n = list.length;
  const btn = $("hJobs");
  if (btn) btn.hidden = n === 0;
  const badge = $("hJobsBadge");
  if (badge) {
    badge.hidden = n === 0;
    badge.textContent = String(n);
  }
  if (!isOpen()) {
    // 其它菜单路径(closeMenus)摘了 open,顺带复位按钮样式
    const hb = $("hJobs");
    if (hb?.classList.contains("open")) hb.classList.remove("open");
    return;
  }
  const p = $("jobsPop");
  if (!p) return;
  if (!n) {
    closeJobs();
    return;
  }
  p.innerHTML = list.map(fmtRow).join("");
}
