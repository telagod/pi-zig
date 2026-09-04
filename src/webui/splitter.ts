// splitter.ts —— 可拖拽双栏分隔调节器
import { tags } from "./dom";
import { signal } from "./signal";
import { deckOpen } from "./store";

const STORAGE_KEY = "piz.deckWidth";
const initialWidth = (() => {
  try {
    const v = localStorage.getItem(STORAGE_KEY);
    return v ? parseInt(v, 10) : 520;
  } catch (_) {
    return 520;
  }
})();

export const deckWidth = signal<number>(initialWidth);

export function renderSplitter(): HTMLElement {
  let isDragging = false;
  let startX = 0;
  let startW = 0;

  function onMouseDown(e: MouseEvent) {
    if (!deckOpen()) return;
    isDragging = true;
    startX = e.clientX;
    startW = deckWidth();
    document.body.classList.add("is-resizing");

    window.addEventListener("mousemove", onMouseMove);
    window.addEventListener("mouseup", onMouseUp);
  }

  function onMouseMove(e: MouseEvent) {
    if (!isDragging) return;
    const delta = startX - e.clientX;
    const nextW = Math.max(320, Math.min(window.innerWidth * 0.75, startW + delta));
    deckWidth.set(nextW);
  }

  function onMouseUp() {
    if (!isDragging) return;
    isDragging = false;
    document.body.classList.remove("is-resizing");
    try {
      localStorage.setItem(STORAGE_KEY, String(deckWidth()));
    } catch (_) {}
    window.removeEventListener("mousemove", onMouseMove);
    window.removeEventListener("mouseup", onMouseUp);
  }

  function onDblClick() {
    const defaultW = Math.floor(window.innerWidth * 0.45);
    deckWidth.set(defaultW);
    try {
      localStorage.setItem(STORAGE_KEY, String(defaultW));
    } catch (_) {}
  }

  return tags.div({
    class: () => `workbench-splitter ${deckOpen() ? "" : "is-hidden"}`,
    onmousedown: onMouseDown,
    ondblclick: onDblClick,
    title: "Drag to resize workbench, double-click to reset",
  });
}
