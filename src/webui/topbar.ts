// topbar.ts —— 顶栏工作台导航与全局状态指示
import { tags } from "./dom";
import {
  wsName,
  branch,
  changesCount,
  activeSession,
  sessions,
  mode,
  model,
  models,
  pct,
  deckOpen,
  connectionStatus,
  theme,
  switchMode,
  switchModel,
  toggleDeck,
  toggleSidebar,
  toggleTheme,
  showSearchModal,
  showSettingsModal,
  renameSession,
} from "./store";
import { AppMode } from "./types";
import {
  iconSidebar,
  iconDeck,
  iconSearch,
  iconSun,
  iconMoon,
  iconSettings,
  iconBolt,
  iconQuestion,
  iconCompass,
  iconBranch,
  iconBot,
} from "./icons";

export function renderTopBar(): HTMLElement {
  return tags.header(
    { class: "topbar" },
    // 左侧：品牌与会话谱系
    tags.div(
      { class: "tb-left" },
      tags.button(
        {
          class: "tb-btn tb-icon-btn",
          title: "Toggle Sidebar (Ctrl+B)",
          onclick: toggleSidebar,
        },
        iconSidebar(15)
      ),
      tags.div(
        { class: "tb-brand" },
        tags.svg(
          { class: "tb-logo", viewBox: "0 0 24 18", fill: "currentColor" },
          tags.path({
            d: "M2.4 1.8h17.2a1.7 1.7 0 0 1 0 3.4H10l10 8.2A1.8 1.8 0 0 1 18.65 16.45H3.2a1.7 1.7 0 0 1 0-3.4h9.4L2.7 4.9A1.8 1.8 0 0 1 4.1 1.8z",
          })
        ),
        tags.span({ class: "tb-title" }, "piz")
      ),
      tags.span({ class: "tb-sep" }, "/"),
      // 工作区与分支
      () => {
        const w = wsName() || "workspace";
        const b = branch();
        const ch = changesCount();
        const branchPart = b ? ` (${b})` : "";
        const chPart = ch > 0 ? ` · ${ch}Δ` : "";
        return tags.span(
          { class: "tb-ws-badge", title: `Workspace: ${w}${branchPart}` },
          iconBranch(12, "tb-branch-icon"),
          tags.span({}, `${w}${branchPart}${chPart}`)
        );
      },
      tags.span({ class: "tb-sep" }, "/"),
      tags.button(
        {
          class: "tb-session-btn",
          title: "Double click to rename session",
          ondblclick: () => {
            const cur = activeSession();
            const next = prompt("Rename session:", cur);
            if (next && next.trim()) renameSession(cur, next.trim());
          },
        },
        () => {
          const cur = activeSession();
          const s = sessions().find((x) => x.id === cur);
          return s ? s.title : cur;
        }
      )
    ),

    // 中间：模式切换胶囊
    tags.div(
      { class: "tb-center" },
      tags.div(
        { class: "mode-pill" },
        renderModeBtn("yolo", iconBolt, "YOLO", "Full auto-execution"),
        renderModeBtn("ask", iconQuestion, "ASK", "Ask before destructive operations"),
        renderModeBtn("plan", iconCompass, "PLAN", "Analysis & plan only, no write")
      )
    ),

    // 右侧：模型、Token、Deck 开关、主题
    tags.div(
      { class: "tb-right" },
      // 搜索/命令面板
      tags.button(
        {
          class: "tb-btn tb-search-btn",
          title: "Search / Command Palette (Ctrl+K)",
          onclick: () => showSearchModal.set(true),
        },
        iconSearch(13),
        tags.span({ class: "search-key" }, "⌘K")
      ),
      // 模型下拉
      tags.div(
        { class: "model-selector-wrap" },
        tags.select(
          {
            class: "model-select",
            value: () => model(),
            onchange: (e: Event) => {
              const target = e.target as HTMLSelectElement;
              if (target.value) switchModel(target.value);
            },
          },
          () => {
            const list = models();
            const cur = model();
            const opts = list.map((m) =>
              tags.option({ value: m, selected: m === cur }, m)
            );
            if (cur && !list.includes(cur)) {
              opts.unshift(tags.option({ value: cur, selected: true }, cur));
            }
            return opts;
          }
        )
      ),
      // Token 使用率胶囊
      tags.div(
        {
          class: "token-pill",
          title: "Context Window Usage",
        },
        tags.span({ class: "token-dot" }),
        () => `${pct()}% ctx`
      ),
      // 工作台 Deck 切换按钮
      tags.button(
        {
          class: () => `tb-btn tb-deck-btn ${deckOpen() ? "is-active" : ""}`,
          title: "Toggle Workspace Deck (Diffs/Terminal/Jobs)",
          onclick: toggleDeck,
        },
        iconDeck(14),
        tags.span({ class: "tb-deck-label" }, "Deck")
      ),
      // 主题切换
      tags.button(
        {
          class: "tb-btn tb-icon-btn",
          title: "Toggle Theme",
          onclick: toggleTheme,
        },
        () => (theme() === "dark" ? iconSun(15) : iconMoon(15))
      ),
      // 设置按钮
      tags.button(
        {
          class: "tb-btn tb-icon-btn",
          title: "Settings",
          onclick: () => showSettingsModal.set(true),
        },
        iconSettings(15)
      ),
      // 网络状态指示灯
      tags.span({
        class: () => `status-indicator ${connectionStatus()}`,
        title: () => `Connection: ${connectionStatus()}`,
      })
    )
  );
}

function renderModeBtn(
  m: AppMode,
  iconFn: (size: number, cls: string) => SVGElement,
  label: string,
  title: string
): HTMLElement {
  return tags.button(
    {
      class: () => `mode-btn ${mode() === m ? "is-active" : ""}`,
      title,
      onclick: () => switchMode(m),
    },
    iconFn(12, "mode-btn-icon"),
    tags.span({ class: "mode-btn-label" }, label)
  );
}
