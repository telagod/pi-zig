// evolve.ts —— 自演化观测(采集端)。
// 前端运行时错误 → POST /api/evolve/sink → 服务器落 ~/.piz/evolve/queue.jsonl。
// 发送用 fetch keepalive:不阻塞、页面关闭也送达;失败静默,不干扰用户。
// (曾用 sendBeacon —— 它带不了 Authorization 头,默认 token 模式下全线 401,管道静默失效。)
// 去重:60 秒内同签名(where|msg 前 200 字符)只发一次。

const SINK = "/api/evolve/sink";

let lastSig = "";
let lastAt = 0;

function sink(kind: string, where: string, msg: string, stack: string) {
  if (!msg && !stack) return;
  const sig = (where + "|" + msg).slice(0, 200);
  const now = Date.now();
  if (sig === lastSig && now - lastAt < 60000) return;
  lastSig = sig;
  lastAt = now;
  try {
    const payload = JSON.stringify({
      kind,
      where: String(where || "").slice(0, 300),
      msg: String(msg || "").slice(0, 2000),
      stack: String(stack || "").slice(0, 4000),
      ts: Math.floor(now / 1000),
      session: "", // 调用时补
      ua: String(navigator.userAgent || "").slice(0, 200),
    });
    // window.fetch 已被 net.ts 包装:自动带 Bearer;keepalive 等价 sendBeacon 的
    // 「页面关闭也送达」,且能过鉴权。失败静默(采集不能成为缺陷)。
    fetch(SINK, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: payload,
      keepalive: true,
    }).catch(() => {});
  } catch {}
}

export function initEvolve() {
  window.addEventListener("error", (e: any) => {
    // 资源加载失败(target 非 window)不算缺陷,跳过
    if (e.target && e.target !== window) return;
    const where = e.filename
      ? (e.filename.split("/").pop() || e.filename) + (e.lineno ? "#" + e.lineno : "") + (e.colno ? ":" + e.colno : "")
      : "window";
    sink("jserr", where, e.message || "", e.error?.stack || "");
  });
  window.addEventListener("unhandledrejection", (e: any) => {
    const r = e.reason;
    const msg = r?.message || String(r || "");
    sink("unhandled", "promise", msg, r?.stack || "");
  });
  let ce = console.error;
  console.error = function (...a: any[]) {
    try {
      const msg = a
        .map((x) => (x && (x.message || x.stack)) || String(x || ""))
        .join(" ")
        .slice(0, 1000);
      sink("console", "console.error", msg, "");
    } catch {}
    ce.apply(console, a as any);
  };
}
