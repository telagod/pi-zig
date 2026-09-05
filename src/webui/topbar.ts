// topbar.ts —— 顶栏工作台导航与全局状态指示
import { tags } from "./dom";
import {
  wsName,
  branch,
  changesCount,
  activeSession,
  sessions,
  mode,
  deckOpen,
  connectionStatus,
  theme,
  setTheme,
  THEMES,
  showThemeMenu,
  switchMode,
  toggleDeck,
  toggleSidebar,
  toggleTheme,
  showSearchModal,
  showSettingsModal,
  renameSession,
  activityList,
  setDeckTab,
  t,
} from "./store";
import { AppMode } from "./types";
import {
  iconSidebar,
  iconDeck,
  iconSearch,
  iconSun,
  iconMoon,
  iconPalette,
  iconCheck,
  iconSettings,
  iconBolt,
  iconQuestion,
  iconShield,
  iconBranch,
  iconActivity,
  iconChevronRight,
  getThemeIcon,
} from "./icons";

export function renderTopBar(): HTMLElement {
  return tags.header(
    { class: "topbar" },
    // 左侧：品牌与工程上下文面包屑
    tags.div(
      { class: "tb-left" },
      tags.button(
        {
          class: "tb-btn tb-icon-btn tb-sidebar-btn",
          title: () => t("topbar.toggle_sidebar"),
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
      tags.span({ class: "tb-sep" }, iconChevronRight(10, "tb-sep-icon")),
      // 工作区与分支 (轻量一体化面包屑，摒弃突兀黑框)
      () => {
        const w = wsName() || "workspace";
        const b = branch();
        const ch = changesCount();
        return tags.div(
          {
            class: "tb-crumb tb-crumb-ws",
            title: `${t("topbar.workspace")}: ${w}${b ? ` (${b})` : ""}`,
          },
          iconBranch(12, "tb-branch-icon"),
          tags.span({ class: "tb-crumb-name" }, w),
          b ? tags.span({ class: "tb-crumb-branch" }, `(${b})`) : null,
          ch > 0 ? tags.span({ class: "tb-crumb-delta" }, `${ch}Δ`) : null
        );
      },
      tags.span({ class: "tb-sep" }, iconChevronRight(10, "tb-sep-icon")),
      tags.button(
        {
          class: "tb-crumb tb-session-btn",
          title: () => t("topbar.session_rename"),
          ondblclick: () => {
            const cur = activeSession();
            const s = sessions().find((x) => x.id === cur);
            const titleNow = s ? s.title : cur;
            const next = prompt(t("sidebar.rename_prompt"), titleNow);
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

    // 中间：模式切换胶囊 (紧凑型 Segmented Control)
    tags.div(
      { class: "tb-center" },
      tags.div(
        { class: "mode-pill" },
        renderModeBtn("yolo", iconBolt, "mode.yolo", "mode.yolo_desc"),
        renderModeBtn("ask", iconQuestion, "mode.ask", "mode.ask_desc"),
        renderModeBtn("read-only", iconShield, "mode.read_only", "mode.read_only_desc")
      )
    ),

    // 右侧：紧凑搜索胶囊、模型引擎舱、Deck 开关、主题面板与全局设置
    tags.div(
      { class: "tb-right" },
      // 紧凑型搜索/命令面板胶囊 (去掉冗长文本，纯净内敛)
      tags.button(
        {
          class: "tb-btn tb-search-btn",
          title: () => t("topbar.search"),
          onclick: () => showSearchModal.set(true),
        },
        iconSearch(13, "tb-search-icon"),
        tags.span({ class: "search-key" }, "⌘K")
      ),
      // 工作台 Deck 切换按钮
      tags.button(
        {
          class: () => `tb-btn tb-deck-btn ${deckOpen() ? "is-active" : ""}`,
          title: () => t("topbar.toggle_deck"),
          onclick: toggleDeck,
        },
        iconDeck(14),
        tags.span({ class: "tb-deck-label" }, "Deck")
      ),
      // 动态后台活动指示钮 (当且仅当有活动任务在跑时才浮现，空闲不占像素)
      () => {
        const count = activityList().length;
        if (count === 0) return null;
        return tags.button(
          {
            class: "tb-btn tb-icon-btn tb-act-badge-btn has-active",
            title: () => t("topbar.active_jobs"),
            onclick: () => setDeckTab("jobs"),
          },
          iconActivity(14),
          tags.span({ class: "tb-count-badge" }, String(count))
        );
      },
      // 辅助系统动作组 (Ghost Icons: 主题 + 设置)
      tags.div(
        { class: "tb-actions-group" },
        // 特色主题切换菜单
        tags.div(
          { class: "tb-theme-wrap" },
          tags.button(
            {
              class: () => `tb-btn tb-icon-btn tb-theme-btn ${showThemeMenu() ? "is-active" : ""}`,
              title: () => `${t("theme.name")}: ${t("theme." + theme())}`,
              onclick: (e: MouseEvent) => {
                e.stopPropagation();
                showThemeMenu.update((v) => !v);
              },
            },
            iconPalette(14)
          ),
          () =>
            showThemeMenu()
              ? tags.div(
                  {
                    class: "tb-theme-dropdown",
                    onclick: (e: MouseEvent) => e.stopPropagation(),
                  },
                  tags.div({ class: "tb-theme-hdr" }, () => t("theme.name")),
                  THEMES.map((th) =>
                    tags.div(
                      {
                        class: () => `tb-theme-item ${theme() === th.id ? "is-active" : ""}`,
                        onclick: () => {
                          setTheme(th.id);
                          showThemeMenu.set(false);
                        },
                      },
                      tags.span({ class: "tb-theme-icon" }, getThemeIcon(th.id, 14)),
                      tags.span({ class: "tb-theme-title" }, () => t(th.nameKey)),
                      tags.div(
                        { class: "tb-theme-dots" },
                        tags.span({ class: "tb-theme-dot", style: `background: ${th.preview.canvas};` }),
                        tags.span({ class: "tb-theme-dot", style: `background: ${th.preview.surface};` }),
                        tags.span({ class: "tb-theme-dot", style: `background: ${th.preview.accent};` })
                      ),
                      () =>
                        theme() === th.id
                          ? tags.span({ class: "tb-theme-check" }, iconCheck(12))
                          : null
                    )
                  )
                )
              : null
        ),
        // 全局设置中心按钮
        tags.button(
          {
            class: "tb-btn tb-icon-btn tb-settings-btn",
            title: () => t("topbar.settings"),
            onclick: () => showSettingsModal.set(true),
          },
          iconSettings(14)
        )
      ),
      // 网络连接状态指示灯 (严格包裹居中)
      tags.div(
        { class: "tb-status-wrap" },
        tags.span({
          class: () => `status-indicator ${connectionStatus()}`,
          title: () =>
            connectionStatus() === "connected"
              ? t("topbar.connected")
              : connectionStatus() === "connecting"
              ? t("topbar.connecting")
              : t("topbar.disconnected"),
        })
      )
    )
  );
}

function renderModeBtn(
  m: AppMode,
  iconFn: (size: number, cls: string) => SVGElement,
  labelKey: string,
  titleKey: string
): HTMLElement {
  const isSelected = () => {
    const cur = mode();
    if (m === "read-only") return cur === "read-only" || cur === "plan";
    return cur === m;
  };

  return tags.button(
    {
      class: () => `mode-btn mode-btn-${m} ${isSelected() ? "is-active" : ""}`,
      title: () => t(titleKey),
      onclick: () => switchMode(m),
    },
    iconFn(12, "mode-btn-icon"),
    tags.span({ class: "mode-btn-label" }, () => t(labelKey))
  );
}

window.addEventListener("pointerdown", (e) => {
  if (showThemeMenu()) {
    const target = e.target as HTMLElement | null;
    if (!target || !target.closest(".tb-theme-wrap")) {
      showThemeMenu.set(false);
    }
  }
});
