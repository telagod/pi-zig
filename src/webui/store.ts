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
export const thinkingLevel = signal<string>(getStored("think", "high"));
export const attachedImage = signal<{ data: string; mime: string; name?: string } | null>(null);

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
export const showShortcutsModal = signal<boolean>(false);

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
  }
}

export async function approve(id: string, allow: boolean) {
  try {
    await apiFetch("/api/approve", {
      method: "POST",
      body: JSON.stringify({ id: Number(id) || 0, allow }),
    });
    pendingApproval.set(null);
  } catch (err) {
    console.warn("approve error:", err);
  }
}

export async function switchThinkingLevel(lvl: string) {
  thinkingLevel.set(lvl);
  setStored("think", lvl);
  try {
    await apiFetch("/api/config", {
      method: "POST",
      body: JSON.stringify({ setDefaultThinkingLevel: lvl }),
    });
  } catch (e) {
    console.warn("switchThinkingLevel failed:", e);
  }
}

export async function sendMessage(
  text: string,
  imgObj?: { data: string; mime: string } | null
) {
  if ((!text || !text.trim()) && !imgObj && !attachedImage()) return;
  if (isStreaming()) return;

  const currentImg = imgObj !== undefined ? imgObj : attachedImage();
  const trimmedText = text.trim();

  const userTurn: Turn = {
    id: `u_${Date.now()}`,
    role: "user",
    content: trimmedText,
    steps: [],
    timestamp: Date.now(),
    image: currentImg ? `data:${currentImg.mime};base64,${currentImg.data}` : undefined,
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
    attachedImage.set(null);
  });

  try {
    const payload: any = {
      text: trimmedText,
      message: trimmedText,
    };
    if (currentImg) {
      payload.image = currentImg.data;
      payload.mime = currentImg.mime;
    }

    const res = await apiFetch(`/api/chat${getQuery()}`, {
      method: "POST",
      body: JSON.stringify(payload),
    });
    if (res && res.ok === false) {
      throw new Error(res.error || "Request rejected by server");
    }
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

export function regenerateLastTurn() {
  if (isStreaming()) return;
  const list = turns();
  for (let i = list.length - 1; i >= 0; i--) {
    if (list[i].role === "user") {
      sendMessage(list[i].content);
      break;
    }
  }
}

export async function runTerminalCommand(cmd: string) {
  const trimmed = cmd.trim();
  if (!trimmed) return;
  appendTerminalLine(`$ ${trimmed}`, "cmd");
  try {
    await apiFetch(`/api/chat${getQuery()}`, {
      method: "POST",
      body: JSON.stringify({ text: `!!${trimmed}`, message: `!!${trimmed}` }),
    });
  } catch (err) {
    appendTerminalLine(`Error executing command: ${err}`, "stderr");
  }
}

export function exportSession(format: "md" | "json" = "md") {
  const list = turns();
  const curName = activeSession();
  let content = "";
  let filename = `piz_session_${curName}_${new Date().toISOString().slice(0, 10)}`;

  if (format === "json") {
    content = JSON.stringify(list, null, 2);
    filename += ".json";
  } else {
    content = `# piz Session: ${curName}\n\n*Exported on ${new Date().toLocaleString()}*\n\n---\n\n`;
    for (const t of list) {
      if (t.role === "user") {
        content += `### User\n\n${t.content}\n\n`;
      } else {
        content += `### Assistant\n\n`;
        if (t.thought) {
          content += `> **Thought Process**:\n> ${t.thought.replace(/\n/g, "\n> ")}\n\n`;
        }
        content += `${t.content}\n\n---\n\n`;
      }
    }
    filename += ".md";
  }

  const blob = new Blob([content], { type: format === "json" ? "application/json" : "text/markdown;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

// 核心 SSE 事件调度（精准对齐后端真实事件契约）
export function handleSseEvent(evt: any) {
  if (!evt || !evt.type) return;

  // 会话隔离检查：如果事件带有 session 且不匹配当前激活会话，跳过
  if (evt.session && evt.session !== activeSession()) return;

  function ensureAssistantTurn(): string {
    const cur = streamingTurnId();
    if (cur) return cur;
    const list = turns();
    const last = list[list.length - 1];
    if (last && last.role === "assistant") {
      streamingTurnId.set(last.id);
      return last.id;
    }
    const newId = `a_${Date.now()}`;
    streamingTurnId.set(newId);
    turns.update((prev) => [
      ...prev,
      {
        id: newId,
        role: "assistant",
        content: "",
        thought: "",
        steps: [],
        timestamp: Date.now(),
        isStreaming: true,
      },
    ]);
    return newId;
  }

  switch (evt.type) {
    case "user_message": {
      isStreaming.set(true);
      break;
    }

    case "reasoning": {
      // 思考流增量
      const chunk = evt.text || "";
      if (!chunk) break;
      isStreaming.set(true);
      const targetId = ensureAssistantTurn();
      turns.update((prev) =>
        prev.map((t) =>
          t.id === targetId ? { ...t, thought: (t.thought || "") + chunk, isStreaming: true } : t
        )
      );
      break;
    }

    case "message": {
      // 回答正文增量
      const chunk = evt.text || "";
      if (!chunk) break;
      isStreaming.set(true);
      const targetId = ensureAssistantTurn();
      turns.update((prev) =>
        prev.map((t) =>
          t.id === targetId ? { ...t, content: (t.content || "") + chunk, isStreaming: true } : t
        )
      );
      break;
    }

    case "tool_call": {
      isStreaming.set(true);
      let argsObj: any = evt.args;
      if (typeof evt.args === "string") {
        try { argsObj = JSON.parse(evt.args); } catch (_) {}
      }

      const step: StepItem = {
        id: `st_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`,
        name: evt.name || "Tool",
        desc: typeof evt.args === "string" ? evt.args : JSON.stringify(evt.args),
        status: "running",
        startedAt: Date.now(),
        args: argsObj,
      };

      const targetId = ensureAssistantTurn();
      turns.update((prev) =>
        prev.map((t) =>
          t.id === targetId ? { ...t, steps: [...t.steps, step], isStreaming: true } : t
        )
      );
      appendTerminalLine(`▶ [Tool] ${evt.name}: ${typeof evt.args === "string" ? evt.args : JSON.stringify(evt.args)}`, "cmd");
      break;
    }

    case "tool_result": {
      const isError = evt.error === true || evt.error === "true";
      const summary = evt.summary || "";

      turns.update((prev) =>
        prev.map((t) => {
          if (!t.steps || t.steps.length === 0) return t;
          const steps = [...t.steps];
          for (let i = steps.length - 1; i >= 0; i--) {
            if (steps[i].name === evt.name && steps[i].status === "running") {
              steps[i] = {
                ...steps[i],
                status: isError ? "error" : "done",
                durationMs: Date.now() - steps[i].startedAt,
                result: summary,
                error: isError ? summary : undefined,
              };
              break;
            }
          }
          return { ...t, steps };
        })
      );

      // 提取代码 diff
      if (summary.includes("diff --git") || summary.includes("@@ -")) {
        const parsed = parseUnifiedDiff(summary);
        if (parsed.length > 0) {
          diffs.set(parsed);
          activeDiffPath.set(parsed[0].path);
          setDeckTab("diffs");
        }
      }

      appendTerminalLine(summary, isError ? "stderr" : "stdout");
      break;
    }

    case "permission": {
      pendingApproval.set({
        id: String(evt.id),
        type: evt.name || "execute",
        command: typeof evt.args === "string" ? evt.args : JSON.stringify(evt.args),
        desc: `Operation '${evt.name}' requires authorization`,
      });
      break;
    }

    case "permission_result": {
      if (pendingApproval() && pendingApproval()!.id === String(evt.id)) {
        pendingApproval.set(null);
      }
      break;
    }

    case "subagent": {
      const item: JobItem = {
        id: `sub_${evt.idx || 0}`,
        name: `Subagent #${evt.idx || 0}`,
        role: evt.kind,
        status: "running",
        startedAt: Date.now(),
        summary: evt.text,
      };
      jobs.update((prev) => {
        const idx = prev.findIndex((j) => j.id === item.id);
        if (idx >= 0) {
          const next = [...prev];
          next[idx] = { ...next[idx], ...item };
          return next;
        }
        return [...prev, item];
      });
      break;
    }

    case "status": {
      batch(() => {
        if (typeof evt.pct === "number") pct.set(evt.pct);
        if (evt.model) model.set(evt.model);
      });
      break;
    }

    case "title": {
      if (evt.title) {
        loadSessions();
      }
      break;
    }

    case "turn_end": {
      // 本轮彻底完成，解开流式锁定！
      batch(() => {
        isStreaming.set(false);
        turns.update((prev) =>
          prev.map((t) => (t.isStreaming ? { ...t, isStreaming: false } : t))
        );
        streamingTurnId.set(null);
      });
      loadState();
      break;
    }
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
