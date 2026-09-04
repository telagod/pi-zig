// store.ts —— 全局响应式状态机
import { signal, computed, batch } from "./signal";
import {
  Turn,
  StepItem,
  FileDiff,
  JobItem,
  TerminalLine,
  SessionItem,
  FileTreeItem,
  AppMode,
  DeckTab,
  ApprovalRequest,
} from "./types";
import { apiFetch, connectEventStream, setToken } from "./net";
import { parseUnifiedDiff } from "./diff";

// 持久化辅助
function getStored<T>(key: string, fallback: T): T {
  try {
    const v = localStorage.getItem(`piz.${key}`);
    return v != null ? JSON.parse(v) : fallback;
  } catch (_) {
    return fallback;
  }
}

function setStored<T>(key: string, val: T) {
  try {
    localStorage.setItem(`piz.${key}`, JSON.stringify(val));
  } catch (_) {}
}

const urlParams = new URLSearchParams(window.location.search);
export const urlWs = urlParams.get("ws") || "";
export const wsName = signal<string>(urlWs || "workspace");
export const branch = signal<string>("");
export const changesCount = signal<number>(0);

export const activeSession = signal<string>(urlParams.get("session") || "default");
export const sessions = signal<SessionItem[]>([]);
export const turns = signal<Turn[]>([]);
export const isStreaming = signal<boolean>(false);
export const streamingTurnId = signal<string | null>(null);

export const theme = signal<"dark" | "light">(
  getStored("theme", window.matchMedia?.("(prefers-color-scheme: light)").matches ? "light" : "dark")
);

export const connectionStatus = signal<"connected" | "connecting" | "disconnected">("connecting");

export const mode = signal<AppMode>(getStored("mode", "yolo"));
export const model = signal<string>("");
export const models = signal<string[]>([]);
export const pct = signal<number>(0);

export const deckTab = signal<DeckTab>(getStored("deckTab", "diffs"));
export const deckOpen = signal<boolean>(getStored("deckOpen", true));
export const sidebarOpen = signal<boolean>(getStored("sidebarOpen", true));

export const diffs = signal<FileDiff[]>([]);
export const activeDiffPath = signal<string>("");
export const terminalLines = signal<TerminalLine[]>([]);
export const jobs = signal<JobItem[]>([]);
export const files = signal<FileTreeItem[]>([]);

export const pendingApproval = signal<ApprovalRequest | null>(null);
export const showSearchModal = signal<boolean>(false);
export const showAuthModal = signal<boolean>(false);
export const showSettingsModal = signal<boolean>(false);

// 统计衍生物
export const totalDiffStats = computed(() => {
  let add = 0;
  let del = 0;
  for (const d of diffs()) {
    add += d.additions;
    del += d.deletions;
  }
  return { additions: add, deletions: del, files: diffs().length };
});

export const activeDiffFile = computed(() => {
  const curPath = activeDiffPath();
  const list = diffs();
  if (!list.length) return null;
  return list.find((d) => d.path === curPath) || list[0];
});

// 构建符合后端白名单规则的安全 query string
export function getQuery(extra: Record<string, string> = {}): string {
  const params = new URLSearchParams();
  const s = activeSession();
  if (s) params.set("session", s);
  // 空 ws 代表当前默认项目，非空时才传递给后端
  if (urlWs) params.set("ws", urlWs);
  for (const [k, v] of Object.entries(extra)) {
    if (v != null && v !== "") params.set(k, v);
  }
  const q = params.toString();
  return q ? `?${q}` : "";
}

// 主题切换
export function toggleTheme() {
  const next = theme() === "dark" ? "light" : "dark";
  theme.set(next);
  setStored("theme", next);
  document.documentElement.setAttribute("data-color-scheme", next);
}

// 工作台控制
export function toggleDeck() {
  const next = !deckOpen();
  deckOpen.set(next);
  setStored("deckOpen", next);
}

export function setDeckTab(tab: DeckTab) {
  deckTab.set(tab);
  setStored("deckTab", tab);
  if (!deckOpen()) {
    deckOpen.set(true);
    setStored("deckOpen", true);
  }
}

export function toggleSidebar() {
  const next = !sidebarOpen();
  sidebarOpen.set(next);
  setStored("sidebarOpen", next);
}

// 终端行追加
export function appendTerminalLine(text: string, type: TerminalLine["type"] = "stdout") {
  const time = new Date().toLocaleTimeString();
  const line: TerminalLine = {
    id: `tl_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`,
    time,
    text,
    type,
  };
  terminalLines.update((prev) => [...prev.slice(-400), line]);
}

// 核心网络同步
export async function loadState() {
  try {
    const data = await apiFetch(`/api/state${getQuery()}`);
    if (data) {
      batch(() => {
        if (data.model) model.set(data.model);
        if (typeof data.pct === "number") pct.set(data.pct);
        if (data.mode && (data.mode === "yolo" || data.mode === "ask" || data.mode === "plan")) {
          mode.set(data.mode);
        }
        if (data.ws) wsName.set(data.ws);
        if (data.branch) branch.set(data.branch);
        if (typeof data.changes === "number") changesCount.set(data.changes);
      });
    }
  } catch (err) {
    console.warn("loadState error:", err);
  }
}

export async function loadModels() {
  try {
    const res = await apiFetch("/api/models");
    const list = Array.isArray(res) ? res : Array.isArray(res?.models) ? res.models : [];
    models.set(list);
  } catch (err) {
    console.warn("loadModels error:", err);
  }
}

export async function loadSessions() {
  try {
    const res = await apiFetch(`/api/sessions${getQuery()}`);
    const list = Array.isArray(res) ? res : Array.isArray(res?.sessions) ? res.sessions : [];
    sessions.set(
      list.map((s: any) => ({
        id: s.name,
        name: s.name,
        title: s.title || s.name,
        updatedAt: s.ts || s.updated_at || Date.now(),
        messageCount: s.msgs || s.msg_count || 0,
        isCurrent: s.name === activeSession(),
      }))
    );
  } catch (err) {
    console.warn("loadSessions error:", err);
  }
}

export async function loadFiles(query = "") {
  try {
    const res = await apiFetch(`/api/files${getQuery({ q: query })}`);
    const items = Array.isArray(res?.items) ? res.items : Array.isArray(res) ? res : [];
    files.set(items);
  } catch (err) {
    console.warn("loadFiles error:", err);
  }
}

export async function loadHistory() {
  try {
    const res = await apiFetch(`/api/history${getQuery()}`);
    const rawList = Array.isArray(res?.history)
      ? res.history
      : Array.isArray(res?.messages)
      ? res.messages
      : Array.isArray(res)
      ? res
      : [];

    const turnList: Turn[] = [];
    let currentAssistantTurn: Turn | null = null;

    for (const m of rawList) {
      if (m.role === "user") {
        currentAssistantTurn = null;
        turnList.push({
          id: `u_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`,
          role: "user",
          content: m.content || "",
          steps: [],
          timestamp: m.timestamp || Date.now(),
        });
      } else if (m.role === "assistant") {
        currentAssistantTurn = {
          id: `a_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`,
          role: "assistant",
          content: m.content || "",
          thought: m.thought || m.reasoning || "",
          thoughtDurationMs: m.thought_duration,
          steps: [],
          timestamp: m.timestamp || Date.now(),
        };
        turnList.push(currentAssistantTurn);
      } else if (m.role === "tool") {
        const step: StepItem = {
          id: `st_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`,
          name: m.name || "Tool",
          desc: typeof m.args === "string" ? m.args : JSON.stringify(m.args),
          status: "done",
          startedAt: Date.now(),
          result: m.content || "",
          args: m.args,
        };
        if (currentAssistantTurn) {
          currentAssistantTurn.steps.push(step);
        } else {
          currentAssistantTurn = {
            id: `a_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`,
            role: "assistant",
            content: "",
            steps: [step],
            timestamp: Date.now(),
          };
          turnList.push(currentAssistantTurn);
        }
      }
    }
    turns.set(turnList);
  } catch (err) {
    console.warn("loadHistory error:", err);
  }
}

export async function switchSession(name: string) {
  if (activeSession() === name) return;
  activeSession.set(name);
  await loadState();
  await loadHistory();
  await loadSessions();
}

export async function createSession() {
  try {
    const res = await apiFetch(`/api/action${getQuery()}`, {
      method: "POST",
      body: JSON.stringify({ act: "new" }),
    });
    if (res && res.name) {
      await switchSession(res.name);
    }
  } catch (err) {
    console.warn("createSession error:", err);
  }
}

export async function renameSession(id: string, title: string) {
  try {
    const q = getQuery({ session: id });
    await apiFetch(`/api/title${q}`, {
      method: "POST",
      body: JSON.stringify({ title }),
    });
    await loadSessions();
  } catch (err) {
    console.warn("renameSession error:", err);
  }
}

export async function deleteSession(id: string) {
  try {
    const q = getQuery({ session: id });
    await apiFetch(`/api/action${q}`, {
      method: "POST",
      body: JSON.stringify({ act: "delete" }),
    });
    if (activeSession() === id) {
      activeSession.set("default");
      await loadState();
      await loadHistory();
    }
    await loadSessions();
  } catch (err) {
    console.warn("deleteSession error:", err);
  }
}

export async function switchMode(nextMode: AppMode) {
  mode.set(nextMode);
  setStored("mode", nextMode);
  try {
    await apiFetch(`/api/mode${getQuery()}`, {
      method: "POST",
      body: JSON.stringify({ mode: nextMode }),
    });
  } catch (err) {
    console.warn("switchMode error:", err);
  }
}

export async function switchModel(nextModel: string) {
  model.set(nextModel);
  try {
    await apiFetch(`/api/model${getQuery()}`, {
      method: "POST",
      body: JSON.stringify({ model: nextModel }),
    });
  } catch (err) {
    console.warn("switchModel error:", err);
  }
}

export async function interrupt() {
  try {
    await apiFetch(`/api/interrupt${getQuery()}`, { method: "POST" });
  } catch (err) {
    console.warn("interrupt error:", err);
  } finally {
    isStreaming.set(false);
  }
}

export async function approve(id: string, allow: boolean) {
  try {
    await apiFetch("/api/approve", {
      method: "POST",
      body: JSON.stringify({ id, allow }),
    });
    pendingApproval.set(null);
  } catch (err) {
    console.warn("approve error:", err);
  }
}

export async function sendMessage(text: string) {
  if (!text || !text.trim() || isStreaming()) return;

  const userTurn: Turn = {
    id: `u_${Date.now()}`,
    role: "user",
    content: text.trim(),
    steps: [],
    timestamp: Date.now(),
  };

  const assistantTurnId = `a_${Date.now()}`;
  const assistantTurn: Turn = {
    id: assistantTurnId,
    role: "assistant",
    content: "",
    thought: "",
    steps: [],
    timestamp: Date.now(),
    isStreaming: true,
  };

  batch(() => {
    turns.update((prev) => [...prev, userTurn, assistantTurn]);
    isStreaming.set(true);
    streamingTurnId.set(assistantTurnId);
  });

  try {
    await apiFetch(`/api/chat${getQuery()}`, {
      method: "POST",
      body: JSON.stringify({ message: text.trim() }),
    });
  } catch (err) {
    console.error("sendMessage failed:", err);
    batch(() => {
      turns.update((prev) =>
        prev.map((t) =>
          t.id === assistantTurnId
            ? { ...t, content: `Error: ${err instanceof Error ? err.message : String(err)}`, isStreaming: false }
            : t
        )
      );
      isStreaming.set(false);
      streamingTurnId.set(null);
    });
  }
}

// 核心 SSE 事件调度
export function handleSseEvent(event: { type: string; data: any }) {
  const { type, data } = event;

  switch (type) {
    case "stream_start":
      isStreaming.set(true);
      break;

    case "stream": {
      const chunk = typeof data === "string" ? data : data?.chunk || "";
      const curId = streamingTurnId();
      if (curId) {
        turns.update((prev) =>
          prev.map((t) =>
            t.id === curId ? { ...t, content: (t.content || "") + chunk } : t
          )
        );
      }
      break;
    }

    case "thought": {
      const thoughtChunk = typeof data === "string" ? data : data?.chunk || "";
      const curId = streamingTurnId();
      if (curId) {
        turns.update((prev) =>
          prev.map((t) =>
            t.id === curId ? { ...t, thought: (t.thought || "") + thoughtChunk } : t
          )
        );
      }
      break;
    }

    case "step_start": {
      const curId = streamingTurnId();
      const step: StepItem = {
        id: data.id || `st_${Date.now()}`,
        name: data.name || "Task Step",
        desc: data.desc,
        status: "running",
        startedAt: Date.now(),
        args: data.args,
      };
      if (curId) {
        turns.update((prev) =>
          prev.map((t) =>
            t.id === curId ? { ...t, steps: [...t.steps, step] } : t
          )
        );
      }
      appendTerminalLine(`▶ [Step] ${step.name}: ${step.desc || ""}`, "cmd");
      break;
    }

    case "step_end": {
      const curId = streamingTurnId();
      if (curId && data.id) {
        turns.update((prev) =>
          prev.map((t) =>
            t.id === curId
              ? {
                  ...t,
                  steps: t.steps.map((st) =>
                    st.id === data.id
                      ? {
                          ...st,
                          status: data.error ? "error" : "done",
                          durationMs: Date.now() - st.startedAt,
                          result: data.result,
                          error: data.error,
                        }
                      : st
                  ),
                }
              : t
          )
        );
      }
      break;
    }

    case "tool_diff": {
      if (data && data.diff) {
        const parsed = parseUnifiedDiff(data.diff);
        diffs.set(parsed);
        if (parsed.length > 0) {
          activeDiffPath.set(parsed[0].path);
          setDeckTab("diffs");
        }
      }
      break;
    }

    case "terminal_out": {
      const text = typeof data === "string" ? data : data?.text || "";
      appendTerminalLine(text, data?.stream === "stderr" ? "stderr" : "stdout");
      break;
    }

    case "job_update": {
      if (data && data.id) {
        jobs.update((prev) => {
          const idx = prev.findIndex((j) => j.id === data.id);
          const item: JobItem = {
            id: data.id,
            name: data.name || "Background Job",
            role: data.role,
            status: data.status || "running",
            startedAt: data.startedAt || Date.now(),
            finishedAt: data.finishedAt,
            summary: data.summary,
          };
          if (idx >= 0) {
            const next = [...prev];
            next[idx] = { ...next[idx], ...item };
            return next;
          }
          return [...prev, item];
        });
      }
      break;
    }

    case "permission_request": {
      if (data && data.id) {
        pendingApproval.set({
          id: data.id,
          type: data.type || "execute",
          command: data.command,
          desc: data.desc,
          path: data.path,
        });
      }
      break;
    }

    case "stream_end":
      batch(() => {
        isStreaming.set(false);
        const curId = streamingTurnId();
        if (curId) {
          turns.update((prev) =>
            prev.map((t) => (t.id === curId ? { ...t, isStreaming: false } : t))
          );
        }
        streamingTurnId.set(null);
      });
      loadState();
      break;
  }
}

// 统一应用启动
export function boot() {
  document.documentElement.setAttribute("data-color-scheme", theme());

  connectEventStream(handleSseEvent, (st) => {
    connectionStatus.set(st);
  });

  loadState();
  loadModels();
  loadSessions();
  loadHistory();
  loadFiles();

  window.addEventListener("piz:unauthorized", () => {
    showAuthModal.set(true);
  });
}
