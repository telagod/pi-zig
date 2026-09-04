// jobs.ts —— 后台活动触发钮 + 弹层(借 dsh ui-jobs 之形)。
// header 一颗 ⠿ 钮,活动时带计数 badge;点开平铺列表,esc/点外关。
// 数据同 composer 活动条(/api/activity 轮询),本模块只做容器与渲染,无轮询。
// dsh 对齐:活跃行在前(startedAt 升序=早开始在前,以 elapsed 降序近似);
// 已见但结束的行走「终态」区(finishedAt 降序=最新完成在前)弱化保留,
// 失败 detail 是唯一可读之处,不过滤;耗时钟打开且含活物才跑。
import { $, esc, fmtTok } from "./util";
import { setSubPool } from "./slash";
import { t, getLang } from "./i18n";

let live: any[] = [];
let gone: any[] = [];
let tickTimer: any = 0;

function keyOf(a: any): string {
  return a.kind + ":" + a.name;
}

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
    const tEl = e.target as HTMLElement;
    if (tEl.closest?.("#jobsPop,#hJobs")) return;
    closeJobs();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && isOpen()) closeJobs();
  });
}

export function closeJobs() {
  $("jobsPop")?.classList.remove("open");
  $("hJobs")?.classList.remove("open");
  if (tickTimer) {
    clearInterval(tickTimer);
    tickTimer = 0;
  }
}

export function toggleJobs() {
  if (isOpen()) {
    closeJobs();
    return;
  }
  const p = $("jobsPop");
  if (p) p.classList.add("open");
  $("hJobs")?.classList.add("open");
  refreshJobs(live);
  startTickIfNeeded();
}

function fmtSec(ms: number): string {
  const s = ms / 1000;
  if (s < 10) return s.toFixed(1) + "s";
  if (s < 3600) return Math.round(s) + "s";
  return Math.round(s / 60) + "m";
}

let openJobKey: string | null = null;

function fmtRow(a: any, gone_: boolean, i: number): string {
  const k = keyOf(a);
  const isOpen = openJobKey === k;
  const sec = fmtSec(a.ms || 0);
  const lim = a.limit_ms && !a.detached ? "/" + Math.round(a.limit_ms / 1000) + "s" : "";
  const by = a.bytes ? " · " + fmtTok(a.bytes) : "";
  const retry = a.attempt > 1 && !gone_ ? " · retry " + (a.attempt - 1) : "";
  const glyph = a.detached ? "~" : a.kind === "subagent" ? "●" : a.kind === "http" ? "↻" : "▸";
  const det = a.detail ? '<span class="jr-d">' + esc(a.detail) + "</span>" : "";
  let expandHtml = "";
  if (isOpen) {
    const details = [
      a.kind ? "<div><b>" + t("type", "Type") + ":</b> " + esc(a.kind) + "</div>" : "",
      a.pid ? "<div><b>PID:</b> " + esc(String(a.pid)) + "</div>" : "",
      a.limit_ms ? "<div><b>" + t("timeout", "Timeout") + ":</b> " + Math.round(a.limit_ms / 1000) + "s</div>" : "",
      a.bytes ? "<div><b>" + t("dataTransfer", "Data transfer") + ":</b> " + fmtTok(a.bytes) + "</div>" : "",
      a.attempt ? "<div><b>" + t("round", "Attempt") + ":</b> " + a.attempt + "</div>" : "",
      a.detail ? '<div><b>' + t("details", "Details") + ':</b><pre class="jr-code">' + esc(a.detail) + "</pre></div>" : "",
    ].filter(Boolean).join("");
    expandHtml = '<div class="jr-exp">' + (details || "<i>" + (getLang() === "zh" ? "暂无附加参数" : "No extra parameters") + "</i>") + "</div>";
  }
  return (
    '<div class="jr' + (a.detached ? " bg" : "") + (gone_ ? " gone" : "") + (isOpen ? " open" : "") + '" data-key="' + esc(k) + '" title="' + t("clickDetails", "Click to view details") + '">' +
    '<div class="jr-main">' +
    '<span class="jr-g">' + glyph + "</span>" +
    '<span class="jr-n">' + esc(a.name || "job") + "</span>" +
    det +
    '<span class="jr-t" data-i="' + i + '">' + sec + lim + by + retry + (gone_ ? " · " + t("done", "Done") : "") + "</span>" +
    '<span class="jr-arr">' + (isOpen ? "▾" : "▸") + "</span>" +
    "</div>" +
    expandHtml +
    "</div>"
  );
}


function startTickIfNeeded() {
  if (!isOpen()) return;
  if (tickTimer) return;
  // 只有列表里确实有会动的东西时,时钟才跑(dsh 同规)
  if (live.length === 0) return;
  tickTimer = setInterval(() => {
    if (!isOpen()) {
      clearInterval(tickTimer);
      tickTimer = 0;
      return;
    }
    live.forEach((a, i) => {
      a.ms = (a.ms || 0) + 1000;
      const el = document.querySelector('.jr-t[data-i="' + i + '"]');
      if (el) {
        const lim = a.limit_ms && !a.detached ? "/" + Math.round(a.limit_ms / 1000) + "s" : "";
        const by = a.bytes ? " · " + fmtTok(a.bytes) : "";
        const retry = a.attempt > 1 ? " · retry " + (a.attempt - 1) : "";
        el.textContent = fmtSec(a.ms) + lim + by + retry;
      }
    });
  }, 1000);
}

export function refreshJobs(list: any[]) {
  setSubPool(list);
  updateLineage(list);
  // 终态归集:上次活跃、这次消失的 → 弱化保留(最新完成在前)
  const nowIds = new Set(list.map(keyOf));
  for (const j of live) {
    if (!nowIds.has(keyOf(j))) gone.unshift(j);
  }
  live = list;
  const n = list.length;
  const btn = $("hJobs");
  // 控件出现条件:至少有一个任务(含已结束的历史);零不宣告零
  if (btn) btn.hidden = n === 0 && gone.length === 0;
  const badge = $("hJobsBadge");
  if (badge) {
    badge.hidden = n === 0;
    badge.textContent = String(n);
  }
  if (!isOpen()) {
    const hb = $("hJobs");
    if (hb?.classList.contains("open")) hb.classList.remove("open");
    return;
  }
  const p = $("jobsPop");
  if (!p) return;
  if (!n && !gone.length) {
    closeJobs();
    return;
  }
  // 排序:活跃 startedAt 升序(以 elapsed 降序近似)在前,终态 finishedAt 降序在后
  const sortedLive = [...live].sort((a, b) => (b.ms || 0) - (a.ms || 0));
  p.innerHTML =
    sortedLive.map((a, i) => fmtRow(a, false, i)).join("") +
    gone.map((a, i) => fmtRow(a, true, i + sortedLive.length)).join("");
  p.querySelectorAll(".jr").forEach((el: any) => {
    el.onclick = (e: any) => {
      e.stopPropagation();
      const k = el.getAttribute("data-key");
      openJobKey = openJobKey === k ? null : k;
      refreshJobs(live);
    };
  });
  startTickIfNeeded();
}

// 会话头谱系(dsh session.header.lineage 之简形):标题后 `/ N` 面包屑,
// N=活动子代理数;悬停 title 列出运行中的子代理(只读,不做继续语义)。
function updateLineage(list: any[]) {
  const subs = (list || []).filter((j: any) => j && j.kind === "subagent" && j.name);
  const ses = $("hSes");
  let el = $("hLineage") as HTMLElement | null;
  if (!subs.length) {
    if (el) el.hidden = true;
    return;
  }
  if (!el) {
    if (!ses) return;
    el = document.createElement("span");
    el.id = "hLineage";
    el.className = "lineage";
    ses.insertAdjacentElement("afterend", el);
  }
  el.hidden = false;
  el.innerHTML =
    '<span class="lg-sep">/</span><span class="lg-n" title="' +
    esc(subs.map((s: any) => s.name + (s.detail ? " — " + s.detail : "")).join("\n")) +
    '">' +
    subs.length +
    (subs.length > 1 ? (getLang() === "zh" ? " 个 Subagent" : " subagents") : (getLang() === "zh" ? " Subagent" : " subagent")) +
    "</span>";
}

// 验证钩(Playwright 驱动)
if (typeof window !== "undefined") {
  (window as any).pizDbgJobs = { refreshJobs, toggleJobs, closeJobs };
}
