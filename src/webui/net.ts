// net.ts —— 高韧性网络层 (Bearer 鉴权、CSRF 防护、fetch+ReadableStream SSE 流)

let authToken = "";

// 初始化读取 token (同时支持 ?token= 与 #token=)
try {
  let qToken = new URLSearchParams(window.location.search).get("token");
  if (!qToken && window.location.hash.includes("token=")) {
    const hashParams = new URLSearchParams(window.location.hash.replace(/^#/, ""));
    qToken = hashParams.get("token");
  }
  if (qToken) {
    authToken = qToken;
    localStorage.setItem("piz.token", authToken);
  } else {
    authToken = localStorage.getItem("piz.token") || "";
  }
} catch (_) {}

export function getToken(): string {
  return authToken;
}

export function setToken(token: string) {
  authToken = token.trim();
  try {
    if (authToken) {
      localStorage.setItem("piz.token", authToken);
    } else {
      localStorage.removeItem("piz.token");
    }
  } catch (_) {}
}

export async function apiFetch<T = any>(
  path: string,
  init: RequestInit = {}
): Promise<T> {
  const headers = new Headers(init.headers || {});
  headers.set("X-Requested-With", "piz");
  if (authToken) {
    headers.set("Authorization", `Bearer ${authToken}`);
  }

  const res = await fetch(path, {
    ...init,
    headers,
  });

  if (res.status === 401) {
    window.dispatchEvent(new CustomEvent("piz:unauthorized"));
    throw new Error("Unauthorized");
  }

  if (!res.ok) {
    const txt = await res.text().catch(() => "");
    throw new Error(`HTTP ${res.status}: ${txt}`);
  }

  const cType = res.headers.get("content-type") || "";
  if (cType.includes("application/json")) {
    return (await res.json()) as T;
  }
  return (await res.text()) as unknown as T;
}

export type EventHandler = (event: { type: string; data: any }) => void;

// 基于 fetch + ReadableStream 的 SSE 客户端 (EventSource 原生无法带 Authorization 头)
export function connectEventStream(
  onEvent: EventHandler,
  onStateChange: (state: "connected" | "connecting" | "disconnected") => void
): () => void {
  let isClosed = false;
  let retryCount = 0;
  let abortCtrl: AbortController | null = null;
  let timer: any = null;

  async function startStream() {
    if (isClosed) return;
    onStateChange("connecting");

    abortCtrl = new AbortController();
    const headers: Record<string, string> = {
      Accept: "text/event-stream",
      "X-Requested-With": "piz",
    };
    if (authToken) {
      headers["Authorization"] = `Bearer ${authToken}`;
    }

    try {
      const res = await fetch("/api/events", {
        headers,
        signal: abortCtrl.signal,
      });

      if (res.status === 401) {
        onStateChange("disconnected");
        window.dispatchEvent(new CustomEvent("piz:unauthorized"));
        return;
      }

      if (!res.ok || !res.body) {
        throw new Error(`SSE stream failed: HTTP ${res.status}`);
      }

      retryCount = 0;
      onStateChange("connected");

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        let idx: number;
        while ((idx = buffer.indexOf("\n\n")) !== -1) {
          const chunk = buffer.slice(0, idx);
          buffer = buffer.slice(idx + 2);

          for (const line of chunk.split("\n")) {
            if (!line.startsWith("data: ")) continue;
            const rawData = line.slice(6).trim();
            if (!rawData) continue;

            try {
              const parsed = JSON.parse(rawData);
              if (parsed && parsed.type) {
                onEvent(parsed);
              } else if (parsed) {
                onEvent({ type: "message", data: parsed });
              }
            } catch (err) {
              console.warn("SSE JSON parse err:", err, rawData);
            }
          }
        }
      }
    } catch (err: any) {
      if (err?.name === "AbortError" || isClosed) return;
      console.warn("SSE connection error:", err);
    }

    if (!isClosed) {
      onStateChange("disconnected");
      const delay = Math.min(1000 * Math.pow(1.5, retryCount), 10000);
      retryCount++;
      timer = setTimeout(startStream, delay);
    }
  }

  startStream();

  return () => {
    isClosed = true;
    if (timer) clearTimeout(timer);
    if (abortCtrl) abortCtrl.abort();
    onStateChange("disconnected");
  };
}
