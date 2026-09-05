// types.ts —— 核心领域实体类型定义

export type Role = "user" | "assistant" | "system";

export interface StepItem {
  id: string;
  name: string;
  desc?: string;
  status: "running" | "done" | "error";
  startedAt: number;
  durationMs?: number;
  args?: Record<string, any> | string;
  result?: string;
  error?: string;
}

export interface Turn {
  id: string;
  role: Role;
  content: string;
  thought?: string;
  thoughtDurationMs?: number;
  steps: StepItem[];
  timestamp: number;
  isStreaming?: boolean;
  image?: string;
}

export interface DiffLine {
  type: "add" | "del" | "context";
  content: string;
  oldNo?: number;
  newNo?: number;
}

export interface Hunk {
  header: string;
  lines: DiffLine[];
}

export interface FileDiff {
  path: string;
  oldPath?: string;
  status: "modified" | "added" | "deleted";
  additions: number;
  deletions: number;
  hunks: Hunk[];
  raw?: string;
}

export interface JobItem {
  id: string;
  name: string;
  role?: string;
  status: "pending" | "running" | "succeeded" | "failed";
  startedAt: number;
  finishedAt?: number;
  summary?: string;
  parentId?: string;
}

export interface TerminalLine {
  id: string;
  time: string;
  text: string;
  type: "stdout" | "stderr" | "system" | "cmd";
}

export interface SessionItem {
  id: string;
  name: string;
  title: string;
  updatedAt: number;
  messageCount: number;
  isCurrent?: boolean;
}

export interface WorkspaceItem {
  root: string;
  name: string;
  isCurrent?: boolean;
}

export interface FileTreeItem {
  name: string;
  path: string;
  dir: boolean;
  size?: number;
  link?: string;
}

export type AppMode = "yolo" | "ask" | "read-only" | "plan";
export type DeckTab = "diffs" | "terminal" | "jobs" | "files";

export interface ApprovalRequest {
  id: string;
  type: string;
  desc?: string;
  command?: string;
  path?: string;
}

export interface ServerState {
  port: number;
  model?: string;
  pct?: number;
  ws?: string;
  branch?: string;
  changes?: number;
  mode?: string;
  hist_start?: number;
  hist_total?: number;
  history?: Array<{ role: string; content: string; name?: string; args?: any; thought?: string }>;
}

export interface ActivityItem {
  pid?: number;
  name?: string;
  cmd?: string;
  duration?: number;
  bytes?: number;
  startedAt?: number;
}

export interface SlashCommandItem {
  cmd: string;
  desc: string;
}

export interface ToastItem {
  id: string;
  message: string;
  type: "info" | "success" | "warning" | "error";
  time: number;
}

export interface UsageSummary {
  lines: number;
  in: number;
  out: number;
  usd: number;
  tail: string;
}

export interface PackageItem {
  name: string;
  skills?: number;
  prompts?: number;
  agents?: number;
}

export interface ArtifactItem {
  name: string;
  content: string;
}

export type ThemeId = "dark" | "abyss" | "matrix" | "synthwave" | "amber" | "light";

export interface ThemeMeta {
  id: ThemeId;
  nameKey: string;
  descKey: string;
  icon: string;
  preview: {
    canvas: string;
    surface: string;
    accent: string;
  };
  isDark: boolean;
}
