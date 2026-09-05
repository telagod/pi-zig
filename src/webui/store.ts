// store.ts —— 全局响应式状态机
import { signal, computed, batch } from "./signal";
import {
  Turn,
  StepItem,
  FileDiff,
  JobItem,
  TerminalLine,
  SessionItem,
  WorkspaceItem,
  FileTreeItem,
  AppMode,
  DeckTab,
  ApprovalRequest,
  ActivityItem,
  SlashCommandItem,
  ToastItem,
  UsageSummary,
  PackageItem,
  ArtifactItem,
  ThemeId,
  ThemeMeta,
} from "./types";
import { apiFetch, connectEventStream, setToken } from "./net";
import { parseUnifiedDiff } from "./diff";
export { locale, setLocale, toggleLocale, t } from "./i18n";

export const THEMES: ThemeMeta[] = [
  {
    id: "dark",
    nameKey: "theme.dark",
    descKey: "theme.dark_desc",
    preview: { canvas: "#090a0c", surface: "#16191e", accent: "#4493f8" },
    isDark: true,
  },
  {
    id: "abyss",
    nameKey: "theme.abyss",
    descKey: "theme.abyss_desc",
    preview: { canvas: "#0b0708", surface: "#1b0f14", accent: "#f43f5e" },
    isDark: true,
  },
  {
    id: "matrix",
    nameKey: "theme.matrix",
    descKey: "theme.matrix_desc",
    preview: { canvas: "#020804", surface: "#0b1c10", accent: "#22c55e" },
    isDark: true,
  },
  {
    id: "synthwave",
    nameKey: "theme.synthwave",
    descKey: "theme.synthwave_desc",
    preview: { canvas: "#090513", surface: "#190f2e", accent: "#d946ef" },
    isDark: true,
  },
  {
    id: "amber",
    nameKey: "theme.amber",
    descKey: "theme.amber_desc",
    preview: { canvas: "#0d0905", surface: "#1e160d", accent: "#f59e0b" },
    isDark: true,
  },
  {
    id: "light",
    nameKey: "theme.light",
    descKey: "theme.light_desc",
    preview: { canvas: "#f8fafc", surface: "#ffffff", accent: "#0284c7" },
    isDark: false,
  },
];

export const showThemeMenu = signal<boolean>(false);

function resolveInitialTheme(): ThemeId {
  const stored = getStored<string>("theme", "");
  if (THEMES.some((x) => x.id === stored)) return stored as ThemeId;
  if (stored === "light") return "light";
  return window.matchMedia?.("(prefers-color-scheme: light)").matches ? "light" : "dark";
}

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
export const currentWs = signal<string>(urlWs);
export const wsName = signal<string>(urlWs ? urlWs.split("/").pop() || "workspace" : "workspace");
export const workspaces = signal<WorkspaceItem[]>([]);
export const branch = signal<string>("");
export const changesCount = signal<number>(0);

export const activeSession = signal<string>(urlParams.get("session") || "default");
export const sessions = signal<SessionItem[]>([]);
export const projectSessions = signal<Record<string, SessionItem[]>>({});
export const expandedProjects = signal<Record<string, boolean>>({});
export const turns = signal<Turn[]>([]);
export const isStreaming = signal<boolean>(false);
export const streamingTurnId = signal<string | null>(null);

export const historyTotal = signal<number>(0);
export const historyStart = signal<number>(0);
export const hasMoreHistory = computed(() => historyTotal() > turns().length);

export const theme = signal<ThemeId>(resolveInitialTheme());

export const connectionStatus = signal<"connected" | "connecting" | "disconnected">("connecting");

export const mode = signal<AppMode>(getStored("mode", "yolo"));
export const model = signal<string>("");
export const models = signal<string[]>([]);
export const pct = signal<number>(0);
export const thinkingLevel = signal<string>(getStored("think", "high"));
export const attachedImage = signal<{ data: string; mime: string; name?: string } | null>(null);

export interface AttachedAttachment {
  mime: string;
  data?: string;
  textContent?: string;
  name: string;
  isImage: boolean;
  size?: number;
}

export const attachedAttachment = signal<AttachedAttachment | null>(null);
export const hasVision = signal<boolean>(false);

export function isModelVisionCapable(m?: string): boolean {
  if (hasVision()) return true;
  const name = (m || model() || "").toLowerCase();
  if (!name) return false;
  const visionKeywords = [
    "vision",
    "-vl",
    "gpt-4o",
    "gpt-4.1",
    "gpt-5",
    "claude",
    "gemini",
    "grok",
    "pixtral",
    "glm-4v",
    "qwen-vl",
    "qwen2-vl",
    "qwen2.5-vl",
  ];
  return visionKeywords.some((k) => name.includes(k));
}

export const deckTab = signal<DeckTab>(getStored("deckTab", "diffs"));
export const deckOpen = signal<boolean>(getStored("deckOpen", true));
export const sidebarOpen = signal<boolean>(getStored("sidebarOpen", true));

export const diffs = signal<FileDiff[]>([]);
export const activeDiffPath = signal<string>("");
export const terminalLines = signal<TerminalLine[]>([]);
export const jobs = signal<JobItem[]>([]);
export const files = signal<FileTreeItem[]>([]);

export const activityList = signal<ActivityItem[]>([]);
export const slashCommands = signal<SlashCommandItem[]>([]);
export const toasts = signal<ToastItem[]>([]);

export const sandboxMode = signal<string>("off");
export const usageSummary = signal<UsageSummary>({ lines: 0, in: 0, out: 0, usd: 0, tail: "" });
export const packagesList = signal<{ user: any[]; project: any[] }>({ user: [], project: [] });

export const activeArtifact = signal<{ name: string; content: string; isImage?: boolean } | null>(null);
export const pendingApproval = signal<ApprovalRequest | null>(null);
export const showSearchModal = signal<boolean>(false);
export const showAuthModal = signal<boolean>(false);
export const showSettingsModal = signal<boolean>(false);
export const showShortcutsModal = signal<boolean>(false);
export const showAddWorkspaceModal = signal<boolean>(false);
export const showArtifactModal = signal<boolean>(false);

export const promptHistory = signal<string[]>(getStored("promptHistory", []));

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
  const curW = currentWs();
  if (curW) params.set("ws", curW);
  for (const [k, v] of Object.entries(extra)) {
    if (v != null && v !== "") params.set(k, v);
  }
  const q = params.toString();
  return q ? `?${q}` : "";
}

// Toast 消息通知
export function showToast(
  message: string,
  type: ToastItem["type"] = "info",
  duration = 3200
) {
  const id = `toast_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`;
  toasts.update((prev) => [...prev, { id, message, type, time: Date.now() }]);
  setTimeout(() => dismissToast(id), duration);
}

export function dismissToast(id: string) {
  toasts.update((prev) => prev.filter((t) => t.id !== id));
}

// 主题切换与设置
export function setTheme(next: ThemeId) {
  theme.set(next);
  setStored("theme", next);
  document.documentElement.setAttribute("data-theme", next);
  document.documentElement.setAttribute("data-color-scheme", next === "light" ? "light" : "dark");
}

export function toggleTheme() {
  const current = theme();
  const idx = THEMES.findIndex((x) => x.id === current);
  const next = THEMES[(idx + 1) % THEMES.length].id;
  setTheme(next);
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

// 草稿存取
export function getDraft(sessionId: string): string {
  try {
    return localStorage.getItem(`piz.draft.${sessionId}`) || "";
  } catch (_) {
    return "";
  }
}

export function setDraft(sessionId: string, text: string) {
  try {
    if (text) {
      localStorage.setItem(`piz.draft.${sessionId}`, text);
    } else {
      localStorage.removeItem(`piz.draft.${sessionId}`);
    }
  } catch (_) {}
}

// 历史提示词记录
export function pushPromptHistory(prompt: string) {
  const p = prompt.trim();
  if (!p) return;
  promptHistory.update((prev) => {
    const filtered = prev.filter((x) => x !== p);
    const next = [...filtered, p].slice(-100);
    setStored("promptHistory", next);
    return next;
  });
}

// 核心网络同步
export async function loadState() {
  try {
    const data = await apiFetch(`/api/state${getQuery()}`);
    if (data) {
      batch(() => {
        if (data.model) model.set(data.model);
        if (typeof data.vision === "boolean") hasVision.set(data.vision);
        if (typeof data.pct === "number") pct.set(data.pct);
        if (data.mode) {
          const m = data.mode === "read_only" ? "read-only" : data.mode;
          if (m === "yolo" || m === "ask" || m === "read-only" || m === "plan") {
            mode.set(m);
          }
        }
        if (data.ws) {
          wsName.set(data.ws.split("/").pop() || data.ws);
        }
        if (data.branch) branch.set(data.branch);
        if (typeof data.changes === "number") changesCount.set(data.changes);
        if (typeof data.hist_total === "number") historyTotal.set(data.hist_total);
        if (typeof data.hist_start === "number") historyStart.set(data.hist_start);
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

export async function loadWorkspaces() {
  try {
    const res = await apiFetch("/api/workspaces");
    const list = Array.isArray(res) ? res : [];
    const curW = currentWs();
    const items: WorkspaceItem[] = list.map((w: any) => ({
      root: w.root || w.path || "",
      name: w.name || (w.root ? w.root.split("/").pop() || "workspace" : "workspace"),
      isCurrent: w.root === curW,
    }));
    workspaces.set(items);
  } catch (err) {
    console.warn("loadWorkspaces error:", err);
  }
}

export async function addWorkspace(root: string) {
  const trimmed = root.trim();
  if (!trimmed) return;
  try {
    const res = await apiFetch("/api/workspaces", {
      method: "POST",
      body: JSON.stringify({ root: trimmed }),
    });
    showToast(`Workspace added: ${trimmed.split("/").pop()}`, "success");
    await loadWorkspaces();
    await switchWorkspace(trimmed);
  } catch (err) {
    showToast(`Failed to register workspace: ${err}`, "error");
  }
}

export async function switchWorkspace(root: string) {
  if (currentWs() === root) return;
  currentWs.set(root);
  const name = root.split("/").pop() || "workspace";
  wsName.set(name);
  const newUrl = `${window.location.pathname}?ws=${encodeURIComponent(root)}&session=default`;
  window.history.pushState(null, "", newUrl);
  activeSession.set("default");
  await loadState();
  await loadSessions();
  await loadHistory();
  await loadFiles();
  refreshDiffs(true);
}

export async function loadSessions(targetWs?: string) {
  try {
    const isCurrent = targetWs === undefined || targetWs === currentWs();
    const q = targetWs !== undefined ? `?ws=${encodeURIComponent(targetWs)}` : getQuery();
    const res = await apiFetch(`/api/sessions${q}`);
    const list = Array.isArray(res) ? res : Array.isArray(res?.sessions) ? res.sessions : [];
    const parsed: SessionItem[] = list.map((s: any) => ({
      id: s.name,
      name: s.name,
      title: s.title || s.name,
      updatedAt: s.ts || s.updated_at || Date.now(),
      messageCount: s.msgs || s.msg_count || 0,
      isCurrent: isCurrent && s.name === activeSession(),
      archived: !!s.archived,
    }));
    if (isCurrent) {
      sessions.set(parsed);
    }
    const wsKey = (targetWs !== undefined ? targetWs : currentWs()) || "";
    projectSessions.update((prev) => ({ ...prev, [wsKey]: parsed }));
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

function parseRawHistoryMessages(rawList: any[]): Turn[] {
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
  return turnList;
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

    const turnList = parseRawHistoryMessages(rawList);
    turns.set(turnList);
  } catch (err) {
    console.warn("loadHistory error:", err);
  }
}

export async function loadMoreHistory() {
  const currentCount = turns().length;
  try {
    const res = await apiFetch(`/api/history${getQuery({ offset: String(currentCount), limit: "40" })}`);
    const rawList = Array.isArray(res?.history)
      ? res.history
      : Array.isArray(res?.messages)
      ? res.messages
      : Array.isArray(res)
      ? res
      : [];

    if (rawList.length > 0) {
      const earlierTurns = parseRawHistoryMessages(rawList);
      turns.update((prev) => [...earlierTurns, ...prev]);
      showToast(`Loaded ${earlierTurns.length} earlier messages`, "info");
    }
  } catch (err) {
    showToast(`Failed to load more history: ${err}`, "error");
  }
}

export async function switchSession(name: string) {
  if (activeSession() === name) return;
  activeSession.set(name);
  const newUrl = `${window.location.pathname}?session=${encodeURIComponent(name)}${currentWs() ? `&ws=${encodeURIComponent(currentWs())}` : ""}`;
  window.history.pushState(null, "", newUrl);
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
      showToast(`Created session: ${res.name}`, "success");
      await switchSession(res.name);
    }
  } catch (err) {
    showToast(`Failed to create session: ${err}`, "error");
  }
}

export async function forkSession(id: string) {
  try {
    const q = getQuery({ session: id });
    const res = await apiFetch(`/api/action${q}`, {
      method: "POST",
      body: JSON.stringify({ act: "fork" }),
    });
    if (res && res.ok && res.name) {
      showToast(`Forked to session: ${res.name}`, "success");
      await loadSessions();
      await switchSession(res.name);
    } else {
      showToast(`Fork failed: ${res?.error || "unknown"}`, "error");
    }
  } catch (err) {
    showToast(`Fork failed: ${err}`, "error");
  }
}

export async function undoSession(id: string) {
  try {
    const q = getQuery({ session: id });
    const res = await apiFetch(`/api/action${q}`, {
      method: "POST",
      body: JSON.stringify({ act: "undo" }),
    });
    if (res && res.ok) {
      showToast("Undid last turn", "success");
      await loadState();
      await loadHistory();
      await loadSessions();
    } else {
      showToast("Nothing to undo", "info");
    }
  } catch (err) {
    showToast(`Undo failed: ${err}`, "error");
  }
}

export async function compactSession(id: string) {
  try {
    const q = getQuery({ session: id });
    const res = await apiFetch(`/api/action${q}`, {
      method: "POST",
      body: JSON.stringify({ act: "compact" }),
    });
    if (res && res.ok) {
      showToast("Context snapshot compacted successfully", "success");
      await loadState();
      await loadHistory();
    } else {
      showToast("Compact failed", "error");
    }
  } catch (err) {
    showToast(`Compact failed: ${err}`, "error");
  }
}

export async function archiveSession(id: string) {
  try {
    const q = getQuery({ session: id });
    const res = await apiFetch(`/api/action${q}`, {
      method: "POST",
      body: JSON.stringify({ act: "archive" }),
    });
    if (res && res.ok) {
      showToast("Session archived", "info");
      if (activeSession() === id) {
        await switchSession("default");
      }
      await loadSessions();
    }
  } catch (err) {
    showToast(`Archive failed: ${err}`, "error");
  }
}

export async function restoreSession(id: string) {
  try {
    const q = getQuery({ session: id });
    const res = await apiFetch(`/api/action${q}`, {
      method: "POST",
      body: JSON.stringify({ act: "restore" }),
    });
    if (res && res.ok) {
      showToast("Session restored", "success");
      await loadSessions();
      await switchSession(id);
    } else {
      showToast("Restore failed", "error");
    }
  } catch (err) {
    showToast(`Restore failed: ${err}`, "error");
  }
}

export async function renameSession(id: string, title: string) {
  try {
    const q = getQuery({ session: id });
    await apiFetch(`/api/title${q}`, {
      method: "POST",
      body: JSON.stringify({ title }),
    });
    showToast("Session renamed", "success");
    await loadSessions();
  } catch (err) {
    showToast(`Rename failed: ${err}`, "error");
  }
}

export async function deleteSession(id: string) {
  try {
    const q = getQuery({ session: id });
    await apiFetch(`/api/action${q}`, {
      method: "POST",
      body: JSON.stringify({ act: "delete" }),
    });
    showToast("Session deleted", "info");
    if (activeSession() === id) {
      activeSession.set("default");
      await loadState();
      await loadHistory();
    }
    await loadSessions();
  } catch (err) {
    showToast(`Delete session failed: ${err}`, "error");
  }
}

export async function switchMode(nextMode: AppMode) {
  const backendMode = nextMode === "plan" ? "read-only" : nextMode;
  mode.set(nextMode);
  setStored("mode", nextMode);
  try {
    await apiFetch(`/api/mode${getQuery()}`, {
      method: "POST",
      body: JSON.stringify({ mode: backendMode }),
    });
    showToast(`Mode switched to ${nextMode.toUpperCase()}`, "info");
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
    showToast(`Model set to: ${nextModel}`, "info");
  } catch (err) {
    showToast(`Switch model failed: ${err}`, "error");
  }
}

export async function interrupt() {
  try {
    await apiFetch(`/api/interrupt${getQuery()}`, { method: "POST" });
    showToast("Generation interrupted", "warning");
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
    showToast(allow ? "Action authorized" : "Action denied", allow ? "success" : "warning");
  } catch (err) {
    showToast(`Approval response failed: ${err}`, "error");
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
    showToast(`Thinking level set to ${lvl.toUpperCase()}`, "info");
  } catch (e) {
    console.warn("switchThinkingLevel failed:", e);
  }
}

export async function loadConfig() {
  try {
    const res = await apiFetch("/api/config");
    if (res) {
      if (res.sandboxMode) sandboxMode.set(res.sandboxMode);
      if (res.defaultThinkingLevel) thinkingLevel.set(res.defaultThinkingLevel);
    }
  } catch (e) {}
}

export async function setSandboxMode(sb: string) {
  sandboxMode.set(sb);
  try {
    await apiFetch("/api/config", {
      method: "POST",
      body: JSON.stringify({ setSandboxMode: sb }),
    });
    showToast(`Sandbox mode: ${sb}`, "info");
  } catch (e) {
    showToast(`Set sandbox failed: ${e}`, "error");
  }
}

export async function loadUsage() {
  try {
    const res = await apiFetch("/api/usage");
    if (res) {
      usageSummary.set({
        lines: res.lines || 0,
        in: res.in || 0,
        out: res.out || 0,
        usd: res.usd || 0,
        tail: res.tail || "",
      });
    }
  } catch (e) {}
}

export async function loadPackages() {
  try {
    const res = await apiFetch(`/api/packages${getQuery()}`);
    if (res) {
      packagesList.set({
        user: Array.isArray(res.user) ? res.user : [],
        project: Array.isArray(res.project) ? res.project : [],
      });
    }
  } catch (e) {}
}

export async function refreshModels() {
  showToast("Refreshing models from providers...", "info");
  try {
    await apiFetch("/api/config", {
      method: "POST",
      body: JSON.stringify({ refreshModels: true }),
    });
    await loadModels();
    showToast("Models refreshed", "success");
  } catch (e) {
    showToast(`Failed to refresh models: ${e}`, "error");
  }
}

export async function pollActivity() {
  try {
    const res = await apiFetch("/api/activity");
    const list = Array.isArray(res) ? res : [];
    activityList.set(
      list.map((item: any) => ({
        pid: item.pid,
        name: item.name || item.cmd || `Process ${item.pid}`,
        cmd: item.cmd || item.name || "",
        duration: item.duration || item.dur || 0,
        bytes: item.bytes || item.out_bytes || 0,
        startedAt: item.startedAt || Date.now(),
      }))
    );
  } catch (_) {}
}

export async function killActivity(pid: number) {
  try {
    const res = await apiFetch("/api/activity", {
      method: "POST",
      body: JSON.stringify({ kill: pid }),
    });
    if (res && res.ok) {
      showToast(`Terminated task pid:${pid}`, "success");
      await pollActivity();
    } else {
      showToast(`Could not terminate task pid:${pid}`, "error");
    }
  } catch (e) {
    showToast(`Kill task error: ${e}`, "error");
  }
}

export async function refreshDiffs(silent = false) {
  try {
    const res = await apiFetch(`/api/slash${getQuery()}`, {
      method: "POST",
      body: JSON.stringify({ name: "diff", args: "" }),
    });
    if (res && res.text) {
      const parsed = parseUnifiedDiff(res.text);
      diffs.set(parsed);
      if (parsed.length > 0 && !activeDiffPath()) {
        activeDiffPath.set(parsed[0].path);
      }
      if (!silent) showToast(`Diff updated (${parsed.length} changed files)`, "info");
    } else {
      diffs.set([]);
      if (!silent) showToast("No modified files in workspace", "info");
    }
  } catch (e) {
    console.warn("refreshDiffs error:", e);
  }
}

export async function commitChanges(msg: string) {
  if (!msg.trim()) return;
  try {
    const res = await apiFetch(`/api/slash${getQuery()}`, {
      method: "POST",
      body: JSON.stringify({ name: "commit", args: msg.trim() }),
    });
    if (res && res.text) {
      appendTerminalLine(res.text, "stdout");
      showToast("Git commit completed", "success");
      await refreshDiffs(true);
      await loadState();
    }
  } catch (e) {
    showToast(`Commit failed: ${e}`, "error");
  }
}

export async function loadHelp() {
  try {
    const res = await apiFetch(`/api/help${getQuery()}`);
    const cmds = Array.isArray(res?.commands) ? res.commands : [];
    if (cmds.length > 0) {
      slashCommands.set(
        cmds.map((c: any) => ({
          cmd: c.name || c.cmd,
          desc: c.desc || "",
        }))
      );
      return;
    }
  } catch (_) {}

  // 兜底常用标准列表
  slashCommands.set([
    { cmd: "/diff", desc: "View git status & diffstat in deck" },
    { cmd: "/commit", desc: "Commit staged workspace files" },
    { cmd: "/log", desc: "Git commit history log" },
    { cmd: "/branch", desc: "Show current and recent git branches" },
    { cmd: "/term", desc: "Open terminal viewer in deck" },
    { cmd: "/jobs", desc: "View subagents & active background processes" },
    { cmd: "/files", desc: "Browse workspace repository files" },
    { cmd: "/clear", desc: "Create a fresh clean session" },
    { cmd: "/fork", desc: "Fork current session into a new branch" },
    { cmd: "/undo", desc: "Undo last message turn" },
    { cmd: "/compact", desc: "Compact session context window" },
    { cmd: "/doctor", desc: "Run environment health check" },
    { cmd: "/usage", desc: "View token ledger and cost summary" },
    { cmd: "/models", desc: "Refresh available AI model list" },
    { cmd: "/yolo", desc: "Switch mode to YOLO (auto-execute)" },
    { cmd: "/ask", desc: "Switch mode to ASK (require approval)" },
    { cmd: "/read-only", desc: "Switch mode to READ-ONLY (safe)" },
    { cmd: "/theme", desc: "Switch theme (dark, abyss, matrix, synthwave, amber, light)" },
    { cmd: "/export", desc: "Export session as Markdown or JSON" },
    { cmd: "/help", desc: "Open keyboard shortcuts and help guide" },
  ]);
}

export async function executeSlash(fullInput: string): Promise<boolean> {
  const trimmed = fullInput.trim();
  if (!trimmed.startsWith("/")) return false;
  const parts = trimmed.slice(1).split(/\s+/);
  const name = parts[0].toLowerCase();
  const args = parts.slice(1).join(" ");

  if (name === "diff") {
    setDeckTab("diffs");
    refreshDiffs();
    return true;
  }
  if (name === "term" || name === "terminal") {
    setDeckTab("terminal");
    return true;
  }
  if (name === "jobs") {
    setDeckTab("jobs");
    pollActivity();
    return true;
  }
  if (name === "files") {
    setDeckTab("files");
    loadFiles();
    return true;
  }
  if (name === "clear" || name === "new") {
    createSession();
    return true;
  }
  if (name === "yolo") {
    switchMode("yolo");
    return true;
  }
  if (name === "ask") {
    switchMode("ask");
    return true;
  }
  if (name === "read-only" || name === "readonly" || name === "ro" || name === "plan") {
    switchMode("read-only");
    return true;
  }
  if (name === "theme") {
    const trimmedArg = (args || "").trim().toLowerCase();
    const match = THEMES.find((t) => t.id === trimmedArg);
    if (match) {
      setTheme(match.id);
      showToast(`Theme switched to ${match.id}`);
    } else {
      toggleTheme();
      showToast(`Theme switched to ${theme()}`);
    }
    return true;
  }
  if (name === "help") {
    showShortcutsModal.set(true);
    return true;
  }
  if (name === "fork") {
    forkSession(activeSession());
    return true;
  }
  if (name === "undo") {
    undoSession(activeSession());
    return true;
  }
  if (name === "compact") {
    compactSession(activeSession());
    return true;
  }
  if (name === "export") {
    exportSession(args === "json" ? "json" : "md");
    return true;
  }
  if (name === "find") {
    showSearchModal.set(true);
    return true;
  }
  if (name === "models" || name === "refresh") {
    refreshModels();
    return true;
  }

  // 服务端执行
  try {
    const res = await apiFetch(`/api/slash${getQuery()}`, {
      method: "POST",
      body: JSON.stringify({ name, args }),
    });
    if (res && res.ok) {
      if (res.text) {
        appendTerminalLine(`[/${name}] ${res.text}`, "stdout");
        setDeckTab("terminal");
        showToast(`Command /${name} finished`, "success");
      }
      return true;
    } else {
      showToast(`Command /${name} failed: ${res?.error || "unknown"}`, "error");
      return false;
    }
  } catch (e) {
    showToast(`Error running /${name}: ${e}`, "error");
    return false;
  }
}

export async function viewArtifact(name: string) {
  if (!name) return;
  if (name.startsWith("img-")) {
    activeArtifact.set({
      name,
      content: `/api/image?name=${encodeURIComponent(name)}`,
      isImage: true,
    });
    showArtifactModal.set(true);
    return;
  }
  try {
    const res = await apiFetch(`/api/artifact?name=${encodeURIComponent(name)}`);
    if (res && res.text != null) {
      activeArtifact.set({ name, content: res.text, isImage: false });
      showArtifactModal.set(true);
    } else {
      showToast(`Cannot load artifact: ${name}`, "warning");
    }
  } catch (e) {
    showToast(`Failed to fetch artifact: ${e}`, "error");
  }
}

export async function loadPlugins() {
  try {
    const res = await apiFetch(`/api/plugins${getQuery()}`);
    const list = Array.isArray(res?.plugins) ? res.plugins : Array.isArray(res) ? res : [];
    for (const p of list) {
      if (p.enabled && Array.isArray(p.assets)) {
        for (const asset of p.assets) {
          if (asset.endsWith(".css")) {
            const link = document.createElement("link");
            link.rel = "stylesheet";
            link.href = `/api/plugins/assets/${p.id}/${asset}`;
            document.head.appendChild(link);
          } else if (asset.endsWith(".js")) {
            const script = document.createElement("script");
            script.src = `/api/plugins/assets/${p.id}/${asset}`;
            document.head.appendChild(script);
          }
        }
      }
    }
  } catch (_) {}
}

export async function sendMessage(
  text: string,
  imgObj?: { data: string; mime: string } | null
) {
  const att = attachedAttachment();
  if ((!text || !text.trim()) && !imgObj && !attachedImage() && !att) return;
  if (isStreaming()) return;

  let currentImg = imgObj !== undefined ? imgObj : attachedImage();
  let trimmedText = text.trim();

  // 拼接文本/代码类型附件到提示词中
  if (att && !att.isImage && att.textContent) {
    const ext = att.name.split(".").pop() || "txt";
    const snippet = `\n\n[Attached File: ${att.name}]\n\`\`\`${ext}\n${att.textContent}\n\`\`\``;
    trimmedText = trimmedText ? `${trimmedText}${snippet}` : snippet.trim();
  } else if (att && att.isImage && att.data) {
    currentImg = { data: att.data, mime: att.mime, name: att.name };
  }

  // 记录提示词历史
  if (trimmedText) pushPromptHistory(trimmedText);

  // 清除草稿
  setDraft(activeSession(), "");

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
    attachedAttachment.set(null);
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
    showToast(`Send failed: ${err instanceof Error ? err.message : String(err)}`, "error");
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

export function exportSession(format: "md" | "json" | "html" = "md") {
  const list = turns();
  const curName = activeSession();
  let content = "";
  let filename = `piz_session_${curName}_${new Date().toISOString().slice(0, 10)}`;

  if (format === "json") {
    content = JSON.stringify(list, null, 2);
    filename += ".json";
  } else if (format === "html") {
    filename += ".html";
    content = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>piz session - ${curName}</title>
  <style>
    body { font-family: -apple-system, sans-serif; max-width: 800px; margin: 40px auto; padding: 0 20px; line-height: 1.6; color: #24292f; background: #fff; }
    h1 { border-bottom: 1px solid #d0d7de; padding-bottom: 8px; }
    .turn { margin: 24px 0; padding: 16px; border-radius: 8px; }
    .turn-user { background: #f6f8fa; border: 1px solid #d0d7de; }
    .turn-assistant { background: #f0f7ff; border: 1px solid #b6e3ff; }
    .role { font-weight: 600; font-size: 13px; text-transform: uppercase; margin-bottom: 8px; color: #57606a; }
    pre { background: #f6f8fa; padding: 12px; border-radius: 6px; overflow-x: auto; }
    blockquote { border-left: 3px solid #0969da; margin: 0; padding-left: 12px; color: #57606a; }
  </style>
</head>
<body>
  <h1>piz session: ${curName}</h1>
  <p>Exported on ${new Date().toLocaleString()}</p>
  <hr />
`;
    for (const t of list) {
      content += `<div class="turn turn-${t.role}">\n<div class="role">${t.role}</div>\n`;
      if (t.thought) {
        content += `<blockquote><b>Thought Process:</b><br>${t.thought.replace(/\n/g, "<br>")}</blockquote>\n`;
      }
      content += `<div><pre>${t.content.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")}</pre></div>\n</div>\n`;
    }
    content += "</body>\n</html>";
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

  const mimeType = format === "json" ? "application/json" : format === "html" ? "text/html;charset=utf-8" : "text/markdown;charset=utf-8";
  const blob = new Blob([content], { type: mimeType });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
  showToast(`Session exported to ${filename}`, "success");
}

// 核心 SSE 事件调度
export function handleSseEvent(evt: any) {
  if (!evt || !evt.type) return;

  // 会话隔离检查
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
      pollActivity();
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
      pollActivity();
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
      batch(() => {
        isStreaming.set(false);
        turns.update((prev) =>
          prev.map((t) => (t.isStreaming ? { ...t, isStreaming: false } : t))
        );
        streamingTurnId.set(null);
      });
      loadState();
      refreshDiffs(true);
      pollActivity();
      break;
    }
  }
}

// 统一应用启动
export function boot() {
  const curTheme = theme();
  document.documentElement.setAttribute("data-theme", curTheme);
  document.documentElement.setAttribute("data-color-scheme", curTheme === "light" ? "light" : "dark");

  connectEventStream(handleSseEvent, (st) => {
    connectionStatus.set(st);
  });

  loadState();
  loadModels();
  loadWorkspaces();
  loadSessions();
  loadHistory();
  loadFiles();
  loadHelp();
  loadConfig();
  loadUsage();
  loadPackages();
  loadPlugins();
  refreshDiffs(true);
  pollActivity();

  setInterval(pollActivity, 4000);

  window.addEventListener("piz:unauthorized", () => {
    showAuthModal.set(true);
  });
}
