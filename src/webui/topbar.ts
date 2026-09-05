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
  setTheme,
  THEMES,
  showThemeMenu,
  switchMode,
  switchModel,
  toggleDeck,
  toggleSidebar,
  toggleTheme,
  showSearchModal,
  showSettingsModal,
  showShortcutsModal,
  renameSession,
  activityList,
  setDeckTab,
  refreshModels,
  loadUsage,
  locale,
  toggleLocale,
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
  iconHelp,
  iconBolt,
  iconQuestion,
  iconShield,
  iconBranch,
  iconActivity,
  iconRefresh,
  iconGlobe,
  getThemeIcon,
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
      tags.span({ class: "tb-sep" }, "/"),
      // 工作区与分支
      () => {
        const w = wsName() || "workspace";
        const b = branch();
        const ch = changesCount();
        const branchPart = b ? ` (${b})` : "";
        const chPart = ch > 0 ? ` · ${ch}Δ` : "";
        return tags.span(
          { class: "tb-ws-badge", title: `${t("topbar.workspace")}: ${w}${branchPart}` },
          iconBranch(12, "tb-branch-icon"),
          tags.span({}, `${w}${branchPart}${chPart}`)
        );
      },
      tags.span({ class: "tb-sep" }, "/"),
      tags.button(
        {
          class: "tb-session-btn",
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

    // 中间：模式切换胶囊
    tags.div(
      { class: "tb-center" },
      tags.div(
        { class: "mode-pill" },
        renderModeBtn("yolo", iconBolt, "mode.yolo", "mode.yolo_desc"),
        renderModeBtn("ask", iconQuestion, "mode.ask", "mode.ask_desc"),
        renderModeBtn("read-only", iconShield, "mode.read_only", "mode.read_only_desc")
      )
    ),

    // 右侧：活动指示、模型、Token、Deck 开关、语言、主题、设置
    tags.div(
      { class: "tb-right" },
      // 后台活动指示钮（带活跃数字 badge）
      tags.button(
        {
          class: () =>
            `tb-btn tb-act-badge-btn ${activityList().length > 0 ? "has-active" : ""}`,
          title: () => t("topbar.active_jobs"),
          onclick: () => setDeckTab("jobs"),
        },
        iconActivity(14),
        () => {
          const count = activityList().length;
          if (count === 0) return null;
          return tags.span({ class: "tb-count-badge" }, String(count));
        }
      ),
      // 搜索/命令面板
      tags.button(
        {
          class: "tb-btn tb-search-btn",
          title: () => t("topbar.search"),
          onclick: () => showSearchModal.set(true),
        },
        iconSearch(13),
        tags.span({ class: "search-key" }, "⌘K")
      ),
      // 模型下拉与刷新
      tags.div(
        { class: "model-selector-wrap" },
        tags.select(
          {
            class: "model-select",
            title: "Switch active LLM model",
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
        ),
        tags.button(
          {
            class: "model-refresh-btn",
            title: () => t("topbar.refresh_models"),
            onclick: refreshModels,
          },
          iconRefresh(11)
        )
      ),
      // Token 使用率胶囊（点击可查看台账明细）
      tags.div(
        {
          class: "token-pill",
          title: "Context Window Usage",
          onclick: () => {
            loadUsage();
            showSettingsModal.set(true);
          },
        },
        tags.span({ class: "token-dot" }),
        () => `${pct()}% ctx`
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
      // 国际化语言切换按钮
      tags.button(
        {
          class: "tb-btn tb-lang-btn",
          title: () => t("topbar.toggle_lang"),
          onclick: toggleLocale,
        },
        iconGlobe(13),
        tags.span({ class: "tb-lang-label" }, () => (locale() === "zh" ? "简" : "EN"))
      ),
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
          iconPalette(15)
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
      // 设置按钮
      tags.button(
        {
          class: "tb-btn tb-icon-btn tb-settings-btn",
          title: () => t("topbar.settings"),
          onclick: () => showSettingsModal.set(true),
        },
        iconSettings(15)
      ),
      // 快捷键帮助按钮
      tags.button(
        {
          class: "tb-btn tb-icon-btn tb-shortcuts-btn",
          title: () => t("topbar.shortcuts"),
          onclick: () => showShortcutsModal.set(true),
        },
        iconHelp(14)
      ),
      // 网络状态指示灯
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
      class: () => `mode-btn ${isSelected() ? "is-active" : ""}`,
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
