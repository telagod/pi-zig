// stream.ts —— SSE:fetch + ReadableStream 解析(EventSource 不能带 Bearer),断线横幅 + 指数退避重连。
// 自 webui.js 切出;ev.onmessage 由 main 指派(消息路由属聊天层)。
import { $ } from "./util";
import { wsp } from "./state";

export const ev: { onmessage: ((m: { data: string }) => void) | null } = { onmessage: null };
let sseRetry = 0;
export function handleSSELine(line: string) {
  if (!line.startsWith("data: ")) return;
  try {
    ev.onmessage?.({ data: line.slice(6) });
  } catch {}
}
export async function connectSSE() {
  try {
    const res = await fetch("/api/events" + (wsp ? "?" + wsp : ""), {
      headers: { accept: "text/event-stream" },
    });
    if (!res.ok || !res.body) {
      sseDown();
      sseRetry = Math.min(sseRetry + 1, 8);
      setTimeout(connectSSE, 1000 * sseRetry);
      return;
    }
    sseRetry = 0;
    sseUp();
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    let buf = "";
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let idx;
      while ((idx = buf.indexOf("\n\n")) !== -1) {
        const chunk = buf.slice(0, idx);
        buf = buf.slice(idx + 2);
        for (const line of chunk.split("\n")) handleSSELine(line);
      }
    }
  } catch {}
  sseDown();
  setTimeout(connectSSE, sseDelay());
}
// 断线反馈:横幅 + 指数退避(1.5s→3s→6s→10s 封顶),连上即复位。
let sseFails = 0;
function sseDelay() {
  return Math.min(10000, 1500 * Math.pow(2, sseFails++));
}
function sseDown() {
  let b = $("ssebar");
  if (!b) {
    b = document.createElement("div");
    b.id = "ssebar";
    b.textContent = "连接断开,重连中…";
    document.body.appendChild(b);
  }
  b.classList.add("on");
}
function sseUp() {
  if (sseFails || $("ssebar")) {
    sseFails = 0;
    const b = $("ssebar");
    if (b) b.classList.remove("on");
  }
}
