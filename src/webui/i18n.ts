// i18n.ts —— piz 全局轻量响应式双语国际化核心 (English / 简体中文)
import { signal } from "./signal";

export type Locale = "zh" | "en";

const STORAGE_KEY = "piz.locale";

function getInitialLocale(): Locale {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved === "zh" || saved === "en") return saved;
    const nav = navigator.language || "";
    if (nav.toLowerCase().startsWith("zh")) return "zh";
  } catch (_) {}
  return "zh"; // 默认中文，亦随魔尊意愿一键切换
}

export const locale = signal<Locale>(getInitialLocale());

export function setLocale(next: Locale) {
  locale.set(next);
  try {
    localStorage.setItem(STORAGE_KEY, next);
  } catch (_) {}
}

export function toggleLocale() {
  setLocale(locale() === "zh" ? "en" : "zh");
}

export const translations: Record<Locale, Record<string, string>> = {
  zh: {
    // 品牌与顶栏
    "app.title": "piz",
    "topbar.workspace": "工作区",
    "topbar.session_rename": "双击重命名会话",
    "topbar.toggle_sidebar": "切换侧边栏 (Ctrl+B)",
    "topbar.toggle_deck": "切换工作台检视 (Ctrl+J)",
    "topbar.toggle_theme": "切换主题",
    "topbar.toggle_lang": "Switch to English",

    // 主题系统
    "theme.name": "界面主题",
    "theme.toggle": "切换主题",
    "theme.dark": "暗夜黑曜",
    "theme.dark_desc": "极客深黑，沉稳克制工程质感",
    "theme.abyss": "宿命幽冥",
    "theme.abyss_desc": "赤焰破妄，血月暗红高燃杀气",
    "theme.matrix": "骇客矩阵",
    "theme.matrix_desc": "复古终端，高饱和辐射荧光绿",
    "theme.synthwave": "紫霄霓虹",
    "theme.synthwave_desc": "赛博朋克，暗夜深紫与电光洋红",
    "theme.amber": "复古琥珀",
    "theme.amber_desc": "VT220 暖光 CRT，温润醇厚长跑护眼",
    "theme.light": "极地素雪",
    "theme.light_desc": "玄冰无瑕，高净度纯粹日光",
    "topbar.search": "全局搜索与指令 (Ctrl+K)",
    "topbar.search_short": "搜索或指令...",
    "topbar.settings": "全局工作区设置",
    "topbar.shortcuts": "快捷键帮助 (?)",
    "topbar.active_jobs": "后台活动进程与子代理任务",
    "topbar.refresh_models": "刷新模型列表",
    "topbar.connected": "已连接服务端",
    "topbar.connecting": "连接中...",
    "topbar.disconnected": "服务端已断开",

    // 模式胶囊
    "mode.yolo": "YOLO",
    "mode.yolo_desc": "极速全自动执行，无需交互确认",
    "mode.ask": "ASK",
    "mode.ask_desc": "破坏性及关键写入前弹出确认",
    "mode.read_only": "READ-ONLY",
    "mode.read_only_desc": "安全只读检视，禁止写操作与命令执行",

    // 侧边栏
    "sidebar.project_ws": "项目工作区",
    "sidebar.projects": "项目工作区",
    "sidebar.projects_count": "{count} 个项目",
    "sidebar.new_session_in_project": "在此项目中新建会话",
    "sidebar.switch_ws": "切换或注册外部项目工作区",
    "sidebar.add_project": "添加外部项目...",
    "sidebar.no_external_ws": "暂无已注册外部工作区",
    "sidebar.new_session": "新建会话",
    "sidebar.filter_sessions": "搜索会话...",
    "sidebar.rename": "重命名",
    "sidebar.fork": "从此处分叉会话",
    "sidebar.undo": "撤销上一轮操作",
    "sidebar.compact": "压缩上下文建立存档点",
    "sidebar.delete": "删除会话",
    "sidebar.archive": "归档此会话",
    "sidebar.restore": "恢复此会话",
    "sidebar.archived_badge": "已归档",
    "sidebar.del_confirm": "确定要删除会话 \"{title}\" 吗？此操作无法撤销。",
    "sidebar.rename_prompt": "重命名会话：",
    "sidebar.no_sessions": "暂无匹配会话",
    "sidebar.sessions_count": "{count} 个会话",

    // 会话聊天流与空态
    "chat.empty_title": "piz workspace",
    "chat.empty_subtitle": "极速、安全的下一代自律型智能体工作台",
    "chat.prompt_card1_title": "任务驱动与自动编码",
    "chat.prompt_card1_desc": "自动分解目标，阅读依赖，编写代码并运行验证",
    "chat.prompt_card1_prompt": "分析当前项目架构与未提交修改并提出优化建议",
    "chat.prompt_card2_title": "代码审查与检视台",
    "chat.prompt_card2_desc": "在右侧实时检视变更行数、Hunk 差异与终端输出",
    "chat.prompt_card3_title": "安全审计与授权把关",
    "chat.prompt_card3_desc": "命令防护拦截、权限确认与严格的沙箱隔离",
    "chat.prompt_card3_prompt": "对当前项目进行安全审计，检查未授权操作与潜在漏洞",
    "chat.load_earlier": "↑ 加载更早的对话历史 ({remaining} 条未载入)",
    "chat.checkpoint": "上下文已压缩 · 建立存档点",
    "chat.copy": "复制",
    "chat.copied": "已复制",
    "chat.retry": "重试此轮",
    "chat.thinking": "思考历程",
    "chat.thinking_in_progress": "深度思考推演中...",
    "chat.expand_output": "展开全部输出 ({lines} 行)",
    "chat.collapse_output": "收起输出",
    "chat.view_artifact": "查看产物检视",

    // 智能输入台
    "composer.placeholder": "向 piz 提问、粘贴图片 (Ctrl+V)、'/' 调用指令、'@' 选文件、'!cmd' 执行终端...",
    "composer.attach_img": "附加图片",
    "composer.slash_menu": "斜杠指令",
    "composer.file_mention": "引用文件",
    "composer.send": "发送",
    "composer.stop": "停止生成",
    "composer.sb_off": "sb: 关闭",
    "composer.sb_workspace": "sb: 工作区隔离",
    "composer.sb_strict": "sb: 严格沙箱",
    "composer.active_task": "后台活跃任务",
    "composer.kill_task": "强杀任务",
    "composer.hint_local": "本地终端直接运行预览：",
    "composer.hint_model": "执行命令并将输出导入模型流：",

    // 工作台 Deck
    "deck.tab_diffs": "Diffs",
    "deck.tab_terminal": "Terminal",
    "deck.tab_jobs": "Jobs",
    "deck.tab_files": "Files",
    "deck.diff_no_changes": "暂无未暂存的代码变更",
    "deck.diff_scan": "重新扫描仓库 Diffs",
    "deck.diff_commit_placeholder": "输入提交信息 (Commit message)...",
    "deck.diff_commit_btn": "一键 Commit",
    "deck.term_title": "智能体终端与执行日志",
    "deck.term_autoscroll": "自动滚动",
    "deck.term_clear": "清空终端",
    "deck.term_copy": "复制全部输出",
    "deck.term_idle": "终端空闲，命令输出与执行日志将在此实时回显",
    "deck.term_input_placeholder": "在此输入终端命令并回车执行 (如 git status)...",
    "deck.jobs_title": "当前无正在运行的后台任务",
    "deck.jobs_desc": "后台进程、工具调用与派生的子代理将在此集中展示与管控",
    "deck.jobs_empty": "当前没有正在运行的后台子任务或子代理",
    "deck.files_loading": "正在读取工作区文件树...",
    "deck.files_search": "检索工作区文件...",
    "deck.files_select_hint": "在左侧选择文件以检视内容",

    // 弹窗与设置
    "modal.close": "关闭",
    "modal.auth_title": "服务端访问授权",
    "modal.auth_desc": "请输入 piz 守护进程访问 Token：",
    "modal.auth_connect": "验证并连接",
    "modal.perm_title": "关键操作授权确认",
    "modal.perm_allow": "允许执行",
    "modal.perm_deny": "拦截阻止",
    "modal.ws_add_title": "注册外部项目工作区",
    "modal.ws_add_desc": "输入魔尊本地文件系统的项目绝对路径：",
    "modal.ws_add_placeholder": "/path/to/project...",
    "modal.ws_add_confirm": "登记并载入",
    "modal.settings_title": "工作区设置中心",
    "settings.tab_appearance": "外观与主题",
    "settings.tab_agent": "模型与配置",
    "settings.tab_security": "沙箱与安全",
    "settings.tab_usage": "Token 台账",
    "settings.tab_packages": "资源与插件",
    "settings.tab_export": "导出数据",
    "settings.theme_select": "专属界面主题",
    "settings.theme_select_desc": "选择契合当前作战环境与视觉心境的特色主题调色盘",
    "settings.theme_preview": "语法高亮与组件预览",
    "settings.ui_language": "界面显示语言",
    "settings.active_model": "活跃大语言模型",
    "settings.active_model_desc": "驱动当前会话推理分析的主力模型",
    "settings.thinking_budget": "思考强度等级",
    "settings.thinking_desc": "调节推理大模型的深入思考预算限制",
    "settings.approval_mode": "操作执行审批模式",
    "settings.approval_mode_desc": "YOLO 极速全自动执行；ASK 关键操作确认；READ-ONLY 严格只读",
    "settings.ctx_window": "上下文窗口占用率",
    "settings.ctx_window_desc": "当前会话活跃 Token 占用模型上限的百分比",
    "settings.sandbox_level": "工作区沙箱隔离级别",
    "settings.sandbox_desc": "约束命令执行在特定目录范围或只读沙箱环境",
    "settings.sec_boundaries": "安全边界声明",
    "settings.sec_boundaries_desc": "服务严格绑定本机回环地址 (127.0.0.1)，受 Bearer Token 强鉴权与同源守卫护佑。工作区沙箱模式下，阻断项目树外的破坏性修改。",
    "settings.export_json": "导出为 JSON 结构化数据 (.json)",
    "settings.export_json_desc": "包含完整对话轮次与每步工具调用的原始数据",
    "settings.export_html": "导出为单文件独立网页 (.html)",
    "settings.export_html_desc": "自洽排版、支持离线查看与团队分享的完整会话归档",
    "shortcuts.title": "键盘快捷键速查",
  },
  en: {
    // Brand & TopBar
    "app.title": "piz",
    "topbar.workspace": "Workspace",
    "topbar.session_rename": "Double-click to rename session",
    "topbar.toggle_sidebar": "Toggle Sidebar (Ctrl+B)",
    "topbar.toggle_deck": "Toggle Workbench Deck (Ctrl+J)",
    "topbar.toggle_theme": "Switch Theme",
    "topbar.toggle_lang": "切换为中文",

    // Theme System
    "theme.name": "Theme",
    "theme.toggle": "Switch Theme",
    "theme.dark": "Obsidian Dark",
    "theme.dark_desc": "Deep engineered dark with muted gray scale",
    "theme.abyss": "Crimson Abyss",
    "theme.abyss_desc": "Blood moon dark red with fierce crimson flame",
    "theme.matrix": "Matrix Green",
    "theme.matrix_desc": "Retro phosphor CRT green hacker terminal",
    "theme.synthwave": "Violet Synthwave",
    "theme.synthwave_desc": "80s cyberpunk deep purple and electric neon",
    "theme.amber": "Retro Amber",
    "theme.amber_desc": "Classic VT220 warm amber glow, easy on the eyes",
    "theme.light": "Polar Light",
    "theme.light_desc": "Pristine arctic daylight with pure contrast",
    "topbar.search": "Search & Command Palette (Ctrl+K)",
    "topbar.search_short": "Search or jump...",
    "topbar.settings": "Workspace Settings",
    "topbar.shortcuts": "Keyboard Shortcuts (?)",
    "topbar.active_jobs": "Active processes & subagent jobs",
    "topbar.refresh_models": "Refresh models",
    "topbar.connected": "Connected to server",
    "topbar.connecting": "Connecting...",
    "topbar.disconnected": "Server disconnected",

    // Mode Pill
    "mode.yolo": "YOLO",
    "mode.yolo_desc": "Full auto-execution, no confirmation dialogs",
    "mode.ask": "ASK",
    "mode.ask_desc": "Confirm before destructive or critical write operations",
    "mode.read_only": "READ-ONLY",
    "mode.read_only_desc": "Safe inspection mode, no writes or executions permitted",

    // Sidebar
    "sidebar.project_ws": "PROJECT WORKSPACE",
    "sidebar.projects": "PROJECTS",
    "sidebar.projects_count": "{count} projects",
    "sidebar.new_session_in_project": "New session in project",
    "sidebar.switch_ws": "Switch or register external project workspace",
    "sidebar.add_project": "Add Project...",
    "sidebar.no_external_ws": "No registered external workspaces",
    "sidebar.new_session": "New Session",
    "sidebar.filter_sessions": "Filter sessions...",
    "sidebar.rename": "Rename",
    "sidebar.fork": "Fork session from here",
    "sidebar.undo": "Undo last turn",
    "sidebar.compact": "Compact context and checkpoint",
    "sidebar.delete": "Delete session",
    "sidebar.archive": "Archive session",
    "sidebar.restore": "Restore session",
    "sidebar.archived_badge": "Archived",
    "sidebar.del_confirm": "Are you sure you want to delete session \"{title}\"? This cannot be undone.",
    "sidebar.rename_prompt": "Rename session:",
    "sidebar.no_sessions": "No sessions found",
    "sidebar.sessions_count": "{count} sessions",

    // Chat Stream & Empty state
    "chat.empty_title": "piz workspace",
    "chat.empty_subtitle": "Fast, safe next-generation autonomous AI workbench",
    "chat.prompt_card1_title": "Goal-Driven Coding",
    "chat.prompt_card1_desc": "Deconstruct tasks, read dependencies, write & verify code",
    "chat.prompt_card1_prompt": "Analyze project architecture and uncommitted diffs, then suggest optimizations",
    "chat.prompt_card2_title": "Code Review & Inspection",
    "chat.prompt_card2_desc": "Inspect changed lines, hunks, and terminal outputs on the right deck",
    "chat.prompt_card3_title": "Security Audit & Sandboxing",
    "chat.prompt_card3_desc": "Command interception, permission gates, and strict sandbox isolation",
    "chat.prompt_card3_prompt": "Perform a security audit on current project, checking unverified actions and risks",
    "chat.load_earlier": "↑ Load earlier messages ({remaining} remaining)",
    "chat.checkpoint": "Context compressed · Checkpoint established",
    "chat.copy": "Copy",
    "chat.copied": "Copied",
    "chat.retry": "Retry turn",
    "chat.thinking": "Thinking Process",
    "chat.thinking_in_progress": "Deep reasoning in progress...",
    "chat.expand_output": "Expand full output ({lines} lines)",
    "chat.collapse_output": "Collapse output",
    "chat.view_artifact": "View Artifact",

    // Composer
    "composer.placeholder": "Ask piz, paste images (Ctrl+V), type '/' for commands, '@' for files, '!cmd' for shell...",
    "composer.attach_img": "Attach image",
    "composer.slash_menu": "Slash command",
    "composer.file_mention": "Mention file",
    "composer.send": "Send",
    "composer.stop": "Stop",
    "composer.sb_off": "sb: off",
    "composer.sb_workspace": "sb: workspace",
    "composer.sb_strict": "sb: strict",
    "composer.active_task": "Active Task",
    "composer.kill_task": "Kill Task",
    "composer.hint_local": "Local shell execution (terminal preview only):",
    "composer.hint_model": "Execute shell and stream output into model:",

    // Workbench Deck
    "deck.tab_diffs": "Diffs",
    "deck.tab_terminal": "Terminal",
    "deck.tab_jobs": "Jobs",
    "deck.tab_files": "Files",
    "deck.diff_no_changes": "No Uncommitted Changes Detected",
    "deck.diff_scan": "Scan Workspace Diffs",
    "deck.diff_commit_placeholder": "Enter commit message...",
    "deck.diff_commit_btn": "Commit Changes",
    "deck.term_title": "Agent Output Terminal",
    "deck.term_autoscroll": "Auto-scroll",
    "deck.term_clear": "Clear Terminal",
    "deck.term_copy": "Copy All",
    "deck.term_idle": "Terminal idle. Commands and logs will stream here.",
    "deck.term_input_placeholder": "Type shell command and press Enter (e.g. git status)...",
    "deck.jobs_title": "No Active Jobs or Subagents",
    "deck.jobs_desc": "Background processes, tool executions, and delegated subagents appear here.",
    "deck.jobs_empty": "No active background processes or subagents",
    "deck.files_loading": "Loading workspace file tree...",
    "deck.files_search": "Search workspace files...",
    "deck.files_select_hint": "Select a file to inspect content.",

    // Modals & Settings
    "modal.close": "Close",
    "modal.auth_title": "Authentication Required",
    "modal.auth_desc": "Please enter your piz server access token:",
    "modal.auth_connect": "Connect",
    "modal.perm_title": "Action Authorization Required",
    "modal.perm_allow": "Allow Execution",
    "modal.perm_deny": "Deny",
    "modal.ws_add_title": "Register Project Workspace",
    "modal.ws_add_desc": "Enter absolute local filesystem path of repository or folder:",
    "modal.ws_add_placeholder": "/path/to/project...",
    "modal.ws_add_confirm": "Register Workspace",
    "modal.settings_title": "Workspace Settings",
    "settings.tab_appearance": "Appearance & Theme",
    "settings.tab_agent": "Agent & Model",
    "settings.tab_security": "Sandbox & Security",
    "settings.tab_usage": "Usage & Tokens",
    "settings.tab_packages": "Packages",
    "settings.tab_export": "Export",
    "settings.theme_select": "Theme Palette",
    "settings.theme_select_desc": "Select a personalized interface theme matching your workflow and environment",
    "settings.theme_preview": "Syntax Highlighting Preview",
    "settings.ui_language": "UI Language",
    "settings.active_model": "Active Model",
    "settings.active_model_desc": "Large language model driving current session inference",
    "settings.thinking_budget": "Thinking Level",
    "settings.thinking_desc": "Budget limit for extended reasoning steps",
    "settings.approval_mode": "Approval Mode",
    "settings.approval_mode_desc": "YOLO executes freely; ASK prompts; READ-ONLY restricts write tools",
    "settings.ctx_window": "Context Window Utilization",
    "settings.ctx_window_desc": "Proportion of active context tokens occupied",
    "settings.sandbox_level": "Sandbox Isolation Level",
    "settings.sandbox_desc": "Restrict command execution to specific directories or read-only sandbox",
    "settings.sec_boundaries": "Security Boundaries",
    "settings.sec_boundaries_desc": "Service binds strictly to loopback (127.0.0.1) with Bearer token authentication and strict Cross-Origin verification.",
    "settings.export_json": "Export as JSON (.json)",
    "settings.export_json_desc": "Structured turns and step items for programmatic use",
    "settings.export_html": "Export as Standalone HTML (.html)",
    "settings.export_html_desc": "Self-contained webpage ready for sharing and offline reading",
    "shortcuts.title": "Keyboard Shortcuts",
  },
};

export function t(key: string, params?: Record<string, string | number>): string {
  const currentLang = locale();
  const dict = translations[currentLang] || translations.zh;
  let text = dict[key] || translations.zh[key] || key;
  if (params) {
    for (const [k, v] of Object.entries(params)) {
      text = text.replace(new RegExp(`\\{${k}\\}`, "g"), String(v));
    }
  }
  return text;
}
