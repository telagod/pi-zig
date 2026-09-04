// i18n.ts —— WebUI 国际化多语言支持。默认英文 (en)，支持中文 (zh)。
// 术语严格保持英文 (Token, Tokens, Session, Model, Provider, Sandbox, Context, MCP, Git, Diff, Workflow)。
import { prefs, savePrefs } from "./state";

export type Lang = "en" | "zh";

const en: Record<string, string> = {
  // Brand & connection
  connecting: "Connecting to local server...",
  authTitle: "Credentials Required",
  authDesc: "This server is protected. Enter the token printed at startup (or configured via --token).",
  connect: "Connect",
  cantConnect: "Cannot connect to local server. Please ensure piz web is running.",

  // Sidebar
  collapseSidebar: "Collapse sidebar",
  expandSidebar: "Expand sidebar",
  searchSessions: "Search sessions...",
  newSession: "New session",
  settings: "Settings",

  // Topbar
  switchWorkspace: "Switch workspace",
  session: "Session",
  sessionActions: "Session actions",
  rename: "Rename",
  backgroundTasks: "Background tasks (j)",
  scrollToBottom: "Scroll to bottom",

  // Queue
  queued: "Queued",
  sendWhenReady: "Send when ready",
  clear: "Clear",

  // Composer
  inputPlaceholder: "Message · / command · @./file · !command · Enter to send",
  permMode: "Approval mode",
  sandboxMode: "Bash sandbox",
  slashCommandsTitle: "/ commands",
  switchModel: "Switch model",
  thinkingLevel: "Thinking level",
  contextFull: "Context full",
  send: "Send",
  stop: "Stop",
  sendMore: "Send more",
  sendMorePh: "Send more…",

  // Hero / Welcome
  workspace: "Workspace",
  startSession: "＋ Start session",
  sugWhatProject: "What does this project do?",
  sugRunTests: "Run tests for me",
  sugRecentChanges: "What changed recently?",
  heroHint: "Read, edit, run. Full control.",
  keyCommands: "Commands",
  keyJobs: "Jobs",
  keyUsage: "Usage",
  keySandbox: "Sandbox",
  keyShortcuts: "Shortcuts",

  // Menus & Actions
  copyReply: "⧉ Copy last reply",
  undoTurn: "↶ Undo turn",
  renameSession: "✎ Rename session",
  forkSession: "✱ Fork session",
  exportHtml: "⎘ Export HTML",
  dumpAll: "📋 Dump all",
  tree: "☰ Message list",
  plan: "✎ Plan",
  planGoal: "Plan goal",
  whatToAccomplish: "What to accomplish",
  compactContext: "⚡ Compact context",
  archiveSession: "🗄 Archive session",
  deleteSession: "🗑 Delete session",
  confirmDeleteSession: "Confirm delete this session?",
  sessionTitle: "Session title",
  defaultSession: "Default session",
  statusAnswer: "Answer",
  statusApproval: "Approval",
  statusAborted: "Aborted",
  renamed: "Renamed",
  failed: "Failed",
  forked: "Forked ",
  forkHint: "New session name, empty for auto",
  archive: "Archive",
  archived: "Archived",
  delete: "Delete",
  deleteForever: "Delete forever",
  restore: "Restore",
  restored: "Restored ",
  noMatchingSessions: "No matching sessions",
  noSessionsHint: "No sessions yet. Send a message to start.",
  addProject: "Add project",
  currentDir: "Current directory",

  // Settings
  tabAuth: "Providers & Keys",
  tabLook: "Appearance",
  tabAgent: "Agent & Sandbox",
  tabNote: "Notifications",
  tabAbout: "About",
  language: "Language",
  scheme: "Color scheme",
  schemeLight: "Light",
  schemeDark: "Dark",
  schemeSystem: "System",
  accent: "Accent color",
  accentMono: "Mono",
  accentBlue: "Blue",
  accentGreen: "Green",
  accentAmber: "Amber",
  density: "Density",
  densityCozy: "Cozy",
  densityCompact: "Compact",
  wideScreen: "Wide screen",
  wideScreenHint: "Widen chat column",
  wideNarrow: "Standard",
  wideWide: "Wide",
  fontSize: "UI font size",
  sessModel: "Session model",
  selectModel: "Select model",
  sessAppr: "Session approval",
  defAppr: "Default approval",
  sandbox: "Bash sandbox",
  sandboxHint: "workspace: writable workspace; strict: no network",
  defModel: "Default model",
  defModelHint: "Used for new sessions",
  notifyDone: "Notify on completion",
  notifyDoneHint: "Browser system notification",
  soundDone: "Sound on completion",
  aboutConfigHint: "Config files located in ~/.piz/",
  shortcutsHint: "Shortcuts",
  builtinProvidersHint: "Built-in providers. Paste API key and save. Green dot = configured.",
  configured: "Configured",
  notConfigured: "Not configured",
  replaceApiKey: "Replace API key",
  pasteApiKey: "Paste API key",
  save: "Save",
  saved: "Saved ",
  saveFail: "Save failed",
  packages: "Packages",
  plugins: "Plugins",
  pluginHint: "task-delegation enables workflow / subagents. Takes effect next turn.",
  ok: "OK",
  cancel: "Cancel",
  close: "Close",
  noContent: "No content",

  // Status & Toasts
  copied: "Copied",
  copyFailed: "Failed to copy",
  undone: "Undone",
  noUndo: "Nothing to undo",
  compressing: "Compressing context...",
  compressedOk: "Context compressed",
  compressedFail: "Compression failed",
  modelSwitchFail: "Failed to switch model",
  thinkSwitchFail: "Failed to switch thinking level",
  permSwitchFail: "Failed to switch approval mode",
  sandboxSwitchFail: "Failed to switch sandbox",
  statusLoadFail: "Failed to load state",
  configLoadFail: "Failed to load config",
  modelsLoadFail: "Failed to load models",
  sessionsLoadFail: "Failed to load sessions",
  actionFail: "Action failed",
  setTitleFail: "Failed to set title",
  working: "Working...",
  done: "Done",
  noModels: "No models available",
  activeTasks: "Active tasks",
  taskHistory: "Task history",
  noTasks: "No background tasks",
  kill: "Kill",
  killed: "Killed",
  killFailed: "Failed to kill",
  expandMore: "Expand ▾",
  foldLess: "Collapse ▴",
  permRequired: "Permission Required",
  awaitingApproval: "Awaiting approval",
  allow: "Allow",
  alwaysSession: "Always in session",
  deny: "Deny",
  apprFailed: "Approval failed",
  contextCompressed: "Context compressed",
  type: "Type",
  timeout: "Timeout",
  dataTransfer: "Data transfer",
  round: "Attempt",
  details: "Details",
  clickDetails: "Click to view details",
  subagent: "subagent",
  subagents: "subagents",
  cache: "Cache ",
  context: "Context ",
  copy: "Copy",
  undo: "Undo",
  regenerate: "Regenerate",
  running: "Running...",
  noOutput: "No output",
  thinking: "Thinking",
  thinkingActive: "Thinking...",
  thoughtFor: "Thought for ",
  tool: "Tool",
  completed: "Completed",
  disconnectedReconnecting: "Disconnected, reconnecting...",
  retryNoInput: "No input to retry",
  copiedLastReply: "Copied last reply",
  noReplyYet: "No reply yet",
};

const zh: Record<string, string> = {
  // Brand & connection
  connecting: "正在连接本地服务器…",
  authTitle: "需要凭证",
  authDesc: "此服务器受保护。输入启动时打印的 Token（或 --token 设置的值）。",
  connect: "连接",
  cantConnect: "无法连接本地服务器，请确认 piz web 已启动。",

  // Sidebar
  collapseSidebar: "折叠侧栏",
  expandSidebar: "展开侧栏",
  searchSessions: "搜索 Session…",
  newSession: "新建 Session",
  settings: "设置",

  // Topbar
  switchWorkspace: "切换项目",
  session: "Session",
  sessionActions: "Session 操作",
  rename: "重命名",
  backgroundTasks: "后台任务 (j)",
  scrollToBottom: "回到底部",

  // Queue
  queued: "待发",
  sendWhenReady: "轮到就发",
  clear: "清空",

  // Composer
  inputPlaceholder: "消息 · / 命令 · @./文件 · !命令 · Enter 发送",
  permMode: "授权模式",
  sandboxMode: "Bash Sandbox",
  slashCommandsTitle: "/ 命令",
  switchModel: "切换 Model",
  thinkingLevel: "Thinking 等级",
  contextFull: "Context 已满",
  send: "发送",
  stop: "停止",
  sendMore: "接着发",
  sendMorePh: "接着发…",

  // Hero / Welcome
  workspace: "项目",
  startSession: "＋ Start Session",
  sugWhatProject: "这个项目是做什么的?",
  sugRunTests: "帮我跑一下测试",
  sugRecentChanges: "最近改了什么?",
  heroHint: "读、改、跑。全权受控。",
  keyCommands: "Commands",
  keyJobs: "Jobs",
  keyUsage: "Token 用量",
  keySandbox: "Sandbox",
  keyShortcuts: "快捷键",

  // Menus & Actions
  copyReply: "⧉ 复制最后回复",
  undoTurn: "↶ 撤销此轮",
  renameSession: "✎ 重命名 Session",
  forkSession: "✱ 派生 Session",
  exportHtml: "⎘ 导出 HTML",
  dumpAll: "📋 导出全部消息",
  tree: "☰ 消息列表",
  plan: "✎ Plan 计划",
  planGoal: "Plan 目标",
  whatToAccomplish: "要完成什么",
  compactContext: "⚡ 压缩 Context",
  archiveSession: "🗄 归档 Session",
  deleteSession: "🗑 删除 Session",
  confirmDeleteSession: "确认删除该 Session？",
  sessionTitle: "Session 标题",
  defaultSession: "默认 Session",
  statusAnswer: "回答",
  statusApproval: "审批",
  statusAborted: "中止",
  renamed: "已重命名",
  failed: "失败",
  forked: "已派生 ",
  forkHint: "新 Session 名，留空自动",
  archive: "归档",
  archived: "已归档",
  delete: "删除",
  deleteForever: "永久删除",
  restore: "恢复",
  restored: "已恢复 ",
  noMatchingSessions: "无匹配 Session",
  noSessionsHint: "还没有 Session，发一条消息开始",
  addProject: "添加项目",
  currentDir: "当前目录",

  // Settings
  tabAuth: "Provider & Key",
  tabLook: "外观",
  tabAgent: "Agent & Sandbox",
  tabNote: "通知",
  tabAbout: "关于",
  language: "语言",
  scheme: "配色方案",
  schemeLight: "浅色",
  schemeDark: "深色",
  schemeSystem: "跟随系统",
  accent: "强调色",
  accentMono: "墨",
  accentBlue: "蓝",
  accentGreen: "苔",
  accentAmber: "赭",
  density: "排版密度",
  densityCozy: "舒适",
  densityCompact: "紧凑",
  wideScreen: "宽屏显示",
  wideScreenHint: "加宽主对话列",
  wideNarrow: "标准",
  wideWide: "宽屏",
  fontSize: "界面字号",
  sessModel: "当前 Session Model",
  selectModel: "选择 Model",
  sessAppr: "Session 授权",
  defAppr: "默认授权",
  sandbox: "Bash Sandbox",
  sandboxHint: "workspace: 工作区可写；strict: 严禁网络",
  defModel: "默认 Model",
  defModelHint: "新建 Session 时生效",
  notifyDone: "执行完成通知",
  notifyDoneHint: "浏览器系统通知",
  soundDone: "完成提示音",
  aboutConfigHint: "配置持久化于 ~/.piz/",
  shortcutsHint: "快捷键",
  builtinProvidersHint: "内置 Provider，粘贴 API key 保存即用。绿点 = 已配置。",
  configured: "已配置",
  notConfigured: "未配置",
  replaceApiKey: "替换 API key",
  pasteApiKey: "粘贴 API key",
  save: "保存",
  saved: "已保存 ",
  saveFail: "保存失败",
  packages: "Packages 资源包",
  plugins: "Plugins 插件",
  pluginHint: "task-delegation 启用 Workflow / Subagent。开关后下一轮生效。",
  ok: "确定",
  cancel: "取消",
  close: "关闭",
  noContent: "没有内容",

  // Status & Toasts
  copied: "已复制",
  copyFailed: "复制失败",
  undone: "已撤销",
  noUndo: "无可撤销",
  compressing: "正在压缩 Context…",
  compressedOk: "Context 压缩完成",
  compressedFail: "压缩失败",
  modelSwitchFail: "切换 Model 失败",
  thinkSwitchFail: "切换 Thinking 等级失败",
  permSwitchFail: "切换授权模式失败",
  sandboxSwitchFail: "切换 Sandbox 失败",
  statusLoadFail: "状态加载失败",
  configLoadFail: "配置加载失败",
  modelsLoadFail: "Model 列表加载失败",
  sessionsLoadFail: "Session 加载失败",
  actionFail: "操作失败",
  setTitleFail: "设置标题失败",
  working: "正在工作…",
  done: "已完成",
  noModels: "无可用 Model",
  activeTasks: "活跃任务",
  taskHistory: "历史任务",
  noTasks: "无后台任务",
  kill: "终止",
  killed: "已终止",
  killFailed: "终止失败",
  expandMore: "展开 ▾",
  foldLess: "收起 ▴",
  permRequired: "需要许可",
  awaitingApproval: "等待审批",
  allow: "允许",
  alwaysSession: "本 Session 总是",
  deny: "拒绝",
  apprFailed: "审批失败",
  contextCompressed: "Context 已压缩",
  type: "类型",
  timeout: "超时限制",
  dataTransfer: "传输数据",
  round: "执行轮次",
  details: "详细内容",
  clickDetails: "点击查看详情",
  subagent: "Subagent",
  subagents: "Subagents",
  cache: "Cache ",
  context: "Context ",
  copy: "复制",
  undo: "撤销",
  regenerate: "重新生成",
  running: "正在运行…",
  noOutput: "暂无输出",
  thinking: "思考",
  thinkingActive: "思考中",
  thoughtFor: "思考 ",
  tool: "工具",
  completed: "已完成",
  disconnectedReconnecting: "连接断开，重连中…",
  retryNoInput: "没有可重发的输入",
  copiedLastReply: "已复制最后回复",
  noReplyYet: "还没有回复",
};

const dicts: Record<Lang, Record<string, string>> = { en, zh };
const listeners: Array<(lang: Lang) => void> = [];

export function getLang(): Lang {
  try {
    const saved = localStorage.getItem("piz.lang") || prefs.lang;
    if (saved === "zh") return "zh";
  } catch {}
  return "en";
}

export function t(key: string, fallback?: string): string {
  const lang = getLang();
  const d = dicts[lang] || en;
  if (d[key] !== undefined) return d[key];
  if (en[key] !== undefined) return en[key];
  return fallback !== undefined ? fallback : key;
}

export function onLangChange(fn: (lang: Lang) => void) {
  listeners.push(fn);
}

export function setLang(lang: Lang) {
  try {
    localStorage.setItem("piz.lang", lang);
    prefs.lang = lang;
    savePrefs();
  } catch {}
  applyI18n();
  for (const fn of listeners) {
    try {
      fn(lang);
    } catch {}
  }
}

export function applyI18n() {
  const lang = getLang();
  try {
    document.documentElement.lang = lang;
  } catch {}

  document.querySelectorAll("[data-i18n]").forEach((el) => {
    const key = el.getAttribute("data-i18n");
    if (key) el.textContent = t(key);
  });

  document.querySelectorAll("[data-i18n-title]").forEach((el) => {
    const key = el.getAttribute("data-i18n-title");
    if (key) el.setAttribute("title", t(key));
  });

  document.querySelectorAll("[data-i18n-ph]").forEach((el) => {
    const key = el.getAttribute("data-i18n-ph");
    if (key) {
      const val = t(key);
      (el as HTMLInputElement | HTMLTextAreaElement).placeholder = val;
      (el as HTMLElement).dataset.ph = val;
    }
  });
}

