// store.ts —— composer 的草稿与历史(localStorage,按会话分键)。
// 自 webui.js 切出;名与义一字未改。依赖仅 $ 与 sess,无迟绑钩。
import { $ } from "./util";
import { sess } from "./state";

export function autosizeInp() {
  const i = $("inp") as HTMLTextAreaElement | null;
  if (!i) return;
  i.style.height = "auto";
  i.style.height = Math.min(i.scrollHeight, 180) + "px";
}
function draftKey() {
  return "piz.draft." + sess;
}
export function saveDraft() {
  try {
    const v = ($("inp") as HTMLTextAreaElement).value;
    if (v) localStorage.setItem(draftKey(), v);
    else localStorage.removeItem(draftKey());
  } catch {}
}
export function restoreDraft() {
  try {
    const v = localStorage.getItem(draftKey());
    if (v) {
      ($("inp") as HTMLTextAreaElement).value = v;
      autosizeInp();
    }
  } catch {}
}
export function clearDraft() {
  try {
    localStorage.removeItem(draftKey());
  } catch {}
}
function histKey() {
  return "piz.hist." + sess;
}
function loadHist(): string[] {
  try {
    return JSON.parse(localStorage.getItem(histKey()) || "[]");
  } catch {
    return [];
  }
}
let histIdx = -1,
  histDraft = "";
export function pushHist(t: string) {
  const a = loadHist().filter((x) => x !== t);
  a.push(t);
  while (a.length > 50) a.shift();
  try {
    localStorage.setItem(histKey(), JSON.stringify(a));
  } catch {}
  histIdx = -1;
  histDraft = "";
}
export function histPrev() {
  const a = loadHist();
  if (!a.length) return;
  if (histIdx < 0) {
    histDraft = ($("inp") as HTMLTextAreaElement).value;
    histIdx = a.length;
  }
  if (histIdx > 0) histIdx--;
  ($("inp") as HTMLTextAreaElement).value = a[histIdx] || "";
  autosizeInp();
}
export function histNext() {
  const a = loadHist();
  if (histIdx < 0) return;
  histIdx++;
  if (histIdx >= a.length) {
    histIdx = -1;
    ($("inp") as HTMLTextAreaElement).value = histDraft;
  } else ($("inp") as HTMLTextAreaElement).value = a[histIdx] || "";
  autosizeInp();
}

let lastUser = "";
export const getLastUser = () => lastUser;
export const setLastUser = (v: string) => { lastUser = v; };

let running = false;
export const getRunning = () => running;
export const setRunning = (r: boolean) => { running = r; };
