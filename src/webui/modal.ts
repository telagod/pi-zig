// modal.ts —— 权限审批弹窗、命令面板、设置中心与 Artifact 检视层
import { tags, each } from "./dom";
import {
  pendingApproval,
  approve,
  showSearchModal,
  showAuthModal,
  showSettingsModal,
  showShortcutsModal,
  showAddWorkspaceModal,
  showArtifactModal,
  activeArtifact,
  sessions,
  switchSession,
  createSession,
  forkSession,
  undoSession,
  compactSession,
  setDeckTab,
  models,
  model,
  switchModel,
  pct,
  thinkingLevel,
  switchThinkingLevel,
  exportSession,
  sandboxMode,
  setSandboxMode,
  usageSummary,
  loadUsage,
  packagesList,
  loadPackages,
  refreshModels,
  refreshDiffs,
  theme,
  setTheme,
  THEMES,
  addWorkspace,
  toasts,
  dismissToast,
  mode,
  switchMode,
  locale,
  setLocale,
  askDialog,
  askInput,
  settleAsk,
  t,
} from "./store";
import { setToken, getToken } from "./net";
import { signal } from "./signal";
import {
  iconShield,
  iconSearch,
  iconPlus,
  iconDiff,
  iconTerminal,
  iconClose,
  iconKey,
  iconCheck,
  iconDownload,
  iconHelp,
  iconFork,
  iconUndo,
  iconCompact,
  iconRefresh,
  iconFolderPlus,
  iconCpu,
  iconSettings,
  iconCopy,
  iconPalette,
  getThemeIcon,
} from "./icons";

export function renderModals(): HTMLElement {
  const container = tags.div({ class: "modals-layer" });

  // 1. 权限审批弹窗
  container.appendChild(
    tags.div(
      {
        class: () =>
          `modal-backdrop ${pendingApproval() ? "is-visible" : "is-hidden"}`,
      },
      () => {
        const req = pendingApproval();
        if (!req) return null;

        return tags.div(
          { class: "modal-card permission-modal" },
          tags.div(
            { class: "modal-hdr" },
            tags.span({ class: "perm-icon" }, iconShield(18)),
            tags.h3({ class: "modal-title" }, () => t("modal.perm_title"))
          ),
          tags.div(
            { class: "modal-body" },
            tags.p(
              { class: "perm-desc" },
              req.desc || t("modal.perm_desc")
            ),
            req.command
              ? tags.pre({ class: "perm-command" }, req.command)
              : null,
            req.path
              ? tags.div({ class: "perm-path" }, () => t("modal.perm_target", { path: req.path }))
              : null
          ),
          tags.div(
            { class: "modal-actions" },
            tags.button(
              {
                class: "btn btn-deny",
                onclick: () => approve(req.id, false),
              },
              iconClose(13),
              tags.span({}, () => t("modal.perm_deny"))
            ),
            tags.button(
              {
                class: "btn btn-allow",
                onclick: () => approve(req.id, true),
              },
              iconCheck(13),
              tags.span({}, () => t("modal.perm_allow"))
            )
          )
        );
      }
    )
  );

  // 2. Command Palette (Ctrl+K)
  const cmdQuery = signal<string>("");
  container.appendChild(
    tags.div(
      {
        class: () =>
          `modal-backdrop ${showSearchModal() ? "is-visible" : "is-hidden"}`,
        onclick: (e: MouseEvent) => {
          if (e.target === e.currentTarget) showSearchModal.set(false);
        },
      },
      () => {
        if (!showSearchModal()) return null;

        const q = cmdQuery().toLowerCase().trim();
        const sessionMatches = sessions().filter((s) =>
          (s.title || s.name).toLowerCase().includes(q)
        );

        return tags.div(
          { class: "modal-card command-palette" },
          tags.div(
            { class: "palette-input-box" },
            iconSearch(15, "palette-icon"),
            tags.input({
              class: "palette-input",
              placeholder: () => t("palette.search_placeholder"),
              autofocus: true,
              value: () => cmdQuery(),
              oninput: (e: Event) => cmdQuery.set((e.target as HTMLInputElement).value),
              onkeydown: (e: KeyboardEvent) => {
                if (e.key === "Escape") showSearchModal.set(false);
              },
            })
          ),
          tags.div(
            { class: "palette-list" },
            // 常用快速指令
            tags.div({ class: "palette-group-hdr" }, () => t("palette.group_actions")),
            tags.div(
              {
                class: "palette-item",
                onclick: () => {
                  createSession();
                  showSearchModal.set(false);
                },
              },
              tags.span({ class: "palette-item-icon" }, iconPlus(14)),
              tags.span({}, () => t("palette.new_session"))
            ),
            tags.div(
              {
                class: "palette-item",
                onclick: () => {
                  refreshDiffs();
                  setDeckTab("diffs");
                  showSearchModal.set(false);
                },
              },
              tags.span({ class: "palette-item-icon" }, iconDiff(14)),
              tags.span({}, () => t("palette.scan_diffs"))
            ),
            tags.div(
              {
                class: "palette-item",
                onclick: () => {
                  setDeckTab("terminal");
                  showSearchModal.set(false);
                },
              },
              tags.span({ class: "palette-item-icon" }, iconTerminal(14)),
              tags.span({}, () => t("palette.open_terminal"))
            ),
            tags.div(
              {
                class: "palette-item",
                onclick: () => {
                  setDeckTab("jobs");
                  showSearchModal.set(false);
                },
              },
              tags.span({ class: "palette-item-icon" }, iconCpu(14)),
              tags.span({}, () => t("palette.view_jobs"))
            ),
            tags.div(
              {
                class: "palette-item",
                onclick: () => {
                  refreshModels();
                  showSearchModal.set(false);
                },
              },
              tags.span({ class: "palette-item-icon" }, iconRefresh(14)),
              tags.span({}, () => t("palette.refresh_models"))
            ),
            tags.div(
              {
                class: "palette-item",
                onclick: () => {
                  showSettingsModal.set(true);
                  showSearchModal.set(false);
                },
              },
              tags.span({ class: "palette-item-icon" }, iconSettings(14)),
              tags.span({}, () => t("palette.open_settings"))
            ),

            // 会话列表匹配
            sessionMatches.length > 0
              ? tags.div({ class: "palette-group-hdr" }, () => t("palette.group_sessions"))
              : null,
            sessionMatches.slice(0, 8).map((s) =>
              tags.div(
                {
                  class: "palette-item",
                  onclick: () => {
                    switchSession(s.id);
                    showSearchModal.set(false);
                  },
                },
                tags.span({ class: "palette-item-title" }, s.title || s.name),
                tags.span({ class: "palette-item-badge" }, () => t("unit.msgs", { n: s.messageCount }))
              )
            )
          )
        );
      }
    )
  );

  // 3. Auth Modal
  const inputTok = signal<string>(getToken());
  container.appendChild(
    tags.div(
      {
        class: () =>
          `modal-backdrop ${showAuthModal() ? "is-visible" : "is-hidden"}`,
      },
      () => {
        if (!showAuthModal()) return null;

        return tags.div(
          { class: "modal-card auth-modal" },
          tags.div(
            { class: "modal-hdr" },
            iconKey(18, "auth-icon"),
            tags.h3({ class: "modal-title" }, () => t("modal.auth_title"))
          ),
          tags.p({ class: "auth-desc" }, () => t("modal.auth_desc")),
          tags.input({
            type: "password",
            class: "auth-token-input",
            placeholder: () => t("modal.auth_placeholder"),
            value: () => inputTok(),
            oninput: (e: Event) => inputTok.set((e.target as HTMLInputElement).value),
          }),
          tags.div(
            { class: "modal-actions" },
            tags.button(
              {
                class: "btn btn-primary",
                onclick: () => {
                  const t = inputTok().trim();
                  if (t) {
                    setToken(t);
                    showAuthModal.set(false);
                    window.location.reload();
                  }
                },
              },
              () => t("modal.auth_connect")
            )
          )
        );
      }
    )
  );

  // 4. Settings Modal
  const activeSettingsTab = signal<"appearance" | "agent" | "security" | "usage" | "packages" | "export">("appearance");
  container.appendChild(
    tags.div(
      {
        class: () =>
          `modal-backdrop ${showSettingsModal() ? "is-visible" : "is-hidden"}`,
        onclick: (e: MouseEvent) => {
          if (e.target === e.currentTarget) showSettingsModal.set(false);
        },
      },
      () => {
        if (!showSettingsModal()) return null;

        return tags.div(
          { class: "modal-card settings-modal-card" },
          tags.div(
            { class: "modal-hdr" },
            tags.div({ class: "modal-hdr-left" }, iconSettings(18), tags.h3({ class: "modal-title" }, () => t("modal.settings_title"))),
            tags.div(
              { class: "modal-hdr-actions" },
              tags.button(
                {
                  class: "modal-help-btn tb-shortcuts-btn",
                  title: () => t("topbar.shortcuts"),
                  onclick: () => {
                    showSettingsModal.set(false);
                    showShortcutsModal.set(true);
                  },
                },
                iconHelp(14)
              ),
              tags.button(
                {
                  class: "modal-close-btn",
                  onclick: () => showSettingsModal.set(false),
                },
                iconClose(14)
              )
            )
          ),
          // 选项卡切换
          tags.div(
            { class: "settings-nav" },
            tags.button(
              {
                class: () => `settings-nav-btn ${activeSettingsTab() === "appearance" ? "is-active" : ""}`,
                onclick: () => activeSettingsTab.set("appearance"),
              },
              tags.span({}, () => t("settings.tab_appearance"))
            ),
            tags.button(
              {
                class: () => `settings-nav-btn ${activeSettingsTab() === "agent" ? "is-active" : ""}`,
                onclick: () => activeSettingsTab.set("agent"),
              },
              tags.span({}, () => t("settings.tab_agent"))
            ),
            tags.button(
              {
                class: () => `settings-nav-btn ${activeSettingsTab() === "security" ? "is-active" : ""}`,
                onclick: () => activeSettingsTab.set("security"),
              },
              tags.span({}, () => t("settings.tab_security"))
            ),
            tags.button(
              {
                class: () => `settings-nav-btn ${activeSettingsTab() === "usage" ? "is-active" : ""}`,
                onclick: () => {
                  loadUsage();
                  activeSettingsTab.set("usage");
                },
              },
              tags.span({}, () => t("settings.tab_usage"))
            ),
            tags.button(
              {
                class: () => `settings-nav-btn ${activeSettingsTab() === "packages" ? "is-active" : ""}`,
                onclick: () => {
                  loadPackages();
                  activeSettingsTab.set("packages");
                },
              },
              tags.span({}, () => t("settings.tab_packages"))
            ),
            tags.button(
              {
                class: () => `settings-nav-btn ${activeSettingsTab() === "export" ? "is-active" : ""}`,
                onclick: () => activeSettingsTab.set("export"),
              },
              tags.span({}, () => t("settings.tab_export"))
            )
          ),

          tags.div(
            { class: "modal-body settings-tab-body" },
            () => {
              const curTab = activeSettingsTab();
              switch (curTab) {
                case "appearance":
                  return tags.div(
                    { class: "settings-pane" },
                    tags.div(
                      { class: "settings-row" },
                      tags.div(
                        { class: "settings-row-info" },
                        tags.label({}, () => t("settings.ui_language")),
                        tags.div({ class: "settings-row-desc" }, "Language / 界面语言")
                      ),
                      tags.select(
                        {
                          class: "settings-select",
                          value: () => locale(),
                          onchange: (e: Event) => setLocale((e.target as HTMLSelectElement).value as any),
                        },
                        tags.option({ value: "zh", selected: locale() === "zh" }, "简体中文 (Chinese)"),
                        tags.option({ value: "en", selected: locale() === "en" }, "English")
                      )
                    ),
                    tags.div(
                      { class: "settings-row-hdr-standalone" },
                      tags.label({}, () => t("settings.theme_select")),
                      tags.div({ class: "settings-row-desc" }, () => t("settings.theme_select_desc"))
                    ),
                    tags.div(
                      { class: "theme-grid" },
                      THEMES.map((th) =>
                        tags.div(
                          {
                            class: () => `theme-card ${theme() === th.id ? "is-active" : ""}`,
                            onclick: () => setTheme(th.id),
                          },
                          tags.div(
                            { class: "theme-card-hdr" },
                            tags.div(
                              { class: "theme-card-title" },
                              tags.span({ class: "theme-card-icon" }, getThemeIcon(th.id, 16)),
                              tags.span({}, () => t(th.nameKey))
                            ),
                            () =>
                              theme() === th.id
                                ? tags.span({ class: "theme-card-badge" }, iconCheck(12))
                                : null
                          ),
                          tags.div(
                            { class: "theme-card-palette" },
                            tags.span({ class: "theme-card-color", style: `background: ${th.preview.canvas};` }),
                            tags.span({ class: "theme-card-color", style: `background: ${th.preview.surface};` }),
                            tags.span({ class: "theme-card-color", style: `background: ${th.preview.accent};` })
                          ),
                          tags.div({ class: "theme-card-desc" }, () => t(th.descKey))
                        )
                      )
                    ),
                    tags.div(
                      { class: "theme-preview-box" },
                      tags.div({ class: "theme-preview-title" }, () => t("settings.theme_preview")),
                      tags.pre(
                        { class: "theme-preview-code" },
                        tags.span({ class: "hl-comment" }, "// piz Theme Live Demo\n"),
                        tags.span({ class: "hl-keyword" }, "const "),
                        tags.span({ class: "hl-type" }, "std "),
                        "= ",
                        tags.span({ class: "hl-func" }, "@import"),
                        "(",
                        tags.span({ class: "hl-string" }, "\"std\""),
                        ");\n",
                        tags.span({ class: "hl-keyword" }, "pub fn "),
                        tags.span({ class: "hl-func" }, "main"),
                        "() !void {\n",
                        "    ",
                        tags.span({ class: "hl-type" }, "std.debug"),
                        ".",
                        tags.span({ class: "hl-func" }, "print"),
                        "(",
                        tags.span({ class: "hl-string" }, "\"Active Theme: {s}\\n\""),
                        ", .{",
                        tags.span({ class: "hl-string" }, `"${theme()}"`),
                        "});\n}"
                      )
                    )
                  );

                case "agent":
                  return tags.div(
                    { class: "settings-pane" },
                    tags.div(
                      { class: "settings-row" },
                      tags.div(
                        { class: "settings-row-info" },
                        tags.label({}, () => t("settings.ui_language")),
                        tags.div({ class: "settings-row-desc" }, "Language / 界面语言")
                      ),
                      tags.select(
                        {
                          class: "settings-select",
                          value: () => locale(),
                          onchange: (e: Event) => setLocale((e.target as HTMLSelectElement).value as any),
                        },
                        tags.option({ value: "zh", selected: locale() === "zh" }, "简体中文 (Chinese)"),
                        tags.option({ value: "en", selected: locale() === "en" }, "English")
                      )
                    ),
                    tags.div(
                      { class: "settings-row" },
                      tags.div(
                        { class: "settings-row-info" },
                        tags.label({}, () => t("settings.active_model")),
                        tags.div({ class: "settings-row-desc" }, () => t("settings.active_model_desc"))
                      ),
                      tags.div(
                        { class: "settings-select-group" },
                        tags.select(
                          {
                            class: "settings-select",
                            value: () => model(),
                            onchange: (e: Event) => switchModel((e.target as HTMLSelectElement).value),
                          },
                          models().map((m) => tags.option({ value: m, selected: m === model() }, m))
                        ),
                        tags.button(
                          {
                            class: "settings-act-btn",
                            title: "Refresh model list",
                            onclick: refreshModels,
                          },
                          iconRefresh(12)
                        )
                      )
                    ),
                    tags.div(
                      { class: "settings-row" },
                      tags.div(
                        { class: "settings-row-info" },
                        tags.label({}, () => t("settings.thinking_budget")),
                        tags.div({ class: "settings-row-desc" }, () => t("settings.thinking_desc"))
                      ),
                      tags.select(
                        {
                          class: "settings-select",
                          value: () => thinkingLevel(),
                          onchange: (e: Event) => switchThinkingLevel((e.target as HTMLSelectElement).value),
                        },
                        ["off", "low", "med", "high", "max"].map((lvl) =>
                          tags.option({ value: lvl, selected: lvl === thinkingLevel() }, lvl.toUpperCase())
                        )
                      )
                    ),
                    tags.div(
                      { class: "settings-row" },
                      tags.div(
                        { class: "settings-row-info" },
                        tags.label({}, () => t("settings.approval_mode")),
                        tags.div({ class: "settings-row-desc" }, () => t("settings.approval_mode_desc"))
                      ),
                      tags.select(
                        {
                          class: "settings-select",
                          value: () => mode(),
                          onchange: (e: Event) => switchMode((e.target as any).value),
                        },
                        tags.option({ value: "yolo", selected: mode() === "yolo" }, "YOLO"),
                        tags.option({ value: "ask", selected: mode() === "ask" }, "ASK"),
                        tags.option({ value: "read-only", selected: mode() === "read-only" }, "READ-ONLY")
                      )
                    ),
                    tags.div(
                      { class: "settings-row" },
                      tags.div(
                        { class: "settings-row-info" },
                        tags.label({}, () => t("settings.ctx_window")),
                        tags.div({ class: "settings-row-desc" }, () => t("settings.ctx_window_desc"))
                      ),
                      tags.div({ class: "settings-stat" }, () => t("settings.ctx_used", { n: pct() }))
                    )
                  );

                case "security":
                  return tags.div(
                    { class: "settings-pane" },
                    tags.div(
                      { class: "settings-row" },
                      tags.div(
                        { class: "settings-row-info" },
                        tags.label({}, () => t("settings.sandbox_level")),
                        tags.div({ class: "settings-row-desc" }, () => t("settings.sandbox_desc"))
                      ),
                      tags.select(
                        {
                          class: "settings-select",
                          value: () => sandboxMode(),
                          onchange: (e: Event) => setSandboxMode((e.target as HTMLSelectElement).value),
                        },
                        tags.option({ value: "off", selected: sandboxMode() === "off" }, "off"),
                        tags.option({ value: "workspace", selected: sandboxMode() === "workspace" }, "workspace"),
                        tags.option({ value: "strict", selected: sandboxMode() === "strict" }, "strict")
                      )
                    ),
                    tags.div(
                      { class: "settings-info-box" },
                      tags.div({ class: "info-box-title" }, () => t("settings.sec_boundaries")),
                      tags.p({}, () => t("settings.sec_boundaries_desc"))
                    )
                  );

                case "usage":
                  const us = usageSummary();
                  return tags.div(
                    { class: "settings-pane" },
                    tags.div(
                      { class: "usage-grid" },
                      tags.div(
                        { class: "usage-metric-card" },
                        tags.div({ class: "metric-title" }, () => t("settings.usage_in")),
                        tags.div({ class: "metric-val" }, us.in.toLocaleString())
                      ),
                      tags.div(
                        { class: "usage-metric-card" },
                        tags.div({ class: "metric-title" }, () => t("settings.usage_out")),
                        tags.div({ class: "metric-val" }, us.out.toLocaleString())
                      ),
                      tags.div(
                        { class: "usage-metric-card" },
                        tags.div({ class: "metric-title" }, () => t("settings.usage_cost")),
                        tags.div({ class: "metric-val" }, `$${us.usd.toFixed(4)}`)
                      ),
                      tags.div(
                        { class: "usage-metric-card" },
                        tags.div({ class: "metric-title" }, () => t("settings.usage_lines")),
                        tags.div({ class: "metric-val" }, String(us.lines))
                      )
                    ),
                    us.tail
                      ? tags.div(
                          { class: "usage-tail-box" },
                          tags.div({ class: "tail-title" }, () => t("settings.usage_tail")),
                          tags.pre({ class: "tail-pre" }, us.tail)
                        )
                      : null
                  );

                case "packages":
                  const pkgs = packagesList();
                  return tags.div(
                    { class: "settings-pane" },
                    tags.div({ class: "pkg-section-title" }, () => t("settings.pkg_project", { n: pkgs.project.length })),
                    pkgs.project.length > 0
                      ? pkgs.project.map((p: any) =>
                          tags.div(
                            { class: "pkg-item" },
                            tags.span({ class: "pkg-name" }, p.name),
                            tags.span({ class: "pkg-meta" }, () => t("settings.pkg_meta", { skills: p.skills || 0, prompts: p.prompts || 0 }))
                          )
                        )
                      : tags.div({ class: "settings-empty" }, () => t("settings.pkg_empty_project")),
                    tags.div({ class: "pkg-section-title", style: "margin-top:16px;" }, () => t("settings.pkg_user", { n: pkgs.user.length })),
                    pkgs.user.length > 0
                      ? pkgs.user.map((p: any) =>
                          tags.div(
                            { class: "pkg-item" },
                            tags.span({ class: "pkg-name" }, p.name),
                            tags.span({ class: "pkg-meta" }, () => t("settings.pkg_meta", { skills: p.skills || 0, prompts: p.prompts || 0 }))
                          )
                        )
                      : tags.div({ class: "settings-empty" }, () => t("settings.pkg_empty_user"))
                  );

                case "export":
                  return tags.div(
                    { class: "settings-pane" },
                    tags.p({ class: "settings-desc" }, () => t("settings.export_desc")),
                    tags.div(
                      { class: "export-card-group" },
                      tags.button(
                        {
                          class: "export-action-card",
                          onclick: () => exportSession("md"),
                        },
                        iconDownload(16),
                        tags.div(
                          { class: "export-card-text" },
                          tags.div({ class: "card-title" }, () => t("settings.export_md")),
                          tags.div({ class: "card-desc" }, () => t("settings.export_md_desc"))
                        )
                      ),
                      tags.button(
                        {
                          class: "export-action-card",
                          onclick: () => exportSession("json"),
                        },
                        iconDownload(16),
                        tags.div(
                          { class: "export-card-text" },
                          tags.div({ class: "card-title" }, () => t("settings.export_json")),
                          tags.div({ class: "card-desc" }, () => t("settings.export_json_desc"))
                        )
                      ),
                      tags.button(
                        {
                          class: "export-action-card",
                          onclick: () => exportSession("html"),
                        },
                        iconDownload(16),
                        tags.div(
                          { class: "export-card-text" },
                          tags.div({ class: "card-title" }, () => t("settings.export_html")),
                          tags.div({ class: "card-desc" }, () => t("settings.export_html_desc"))
                        )
                      )
                    )
                  );
              }
            }
          )
        );
      }
    )
  );

  // 5. Add Workspace Modal
  const inputWsPath = signal<string>("");
  container.appendChild(
    tags.div(
      {
        class: () =>
          `modal-backdrop ${showAddWorkspaceModal() ? "is-visible" : "is-hidden"}`,
        onclick: (e: MouseEvent) => {
          if (e.target === e.currentTarget) showAddWorkspaceModal.set(false);
        },
      },
      () => {
        if (!showAddWorkspaceModal()) return null;

        return tags.div(
          { class: "modal-card ws-add-modal" },
          tags.div(
            { class: "modal-hdr" },
            iconFolderPlus(18),
            tags.h3({ class: "modal-title" }, () => t("modal.ws_add_title"))
          ),
          tags.p({ class: "auth-desc" }, () => t("modal.ws_add_desc")),
          tags.input({
            class: "auth-token-input",
            placeholder: "/path/to/project...",
            value: () => inputWsPath(),
            oninput: (e: Event) => inputWsPath.set((e.target as HTMLInputElement).value),
            onkeydown: (e: KeyboardEvent) => {
              if (e.key === "Enter") {
                addWorkspace(inputWsPath());
                showAddWorkspaceModal.set(false);
              }
            },
          }),
          tags.div(
            { class: "modal-actions" },
            tags.button(
              {
                class: "btn btn-secondary",
                onclick: () => showAddWorkspaceModal.set(false),
              },
              "Cancel"
            ),
            tags.button(
              {
                class: "btn btn-primary",
                onclick: () => {
                  addWorkspace(inputWsPath());
                  showAddWorkspaceModal.set(false);
                },
              },
              "Register & Switch"
            )
          )
        );
      }
    )
  );

  // 6. Artifact Inspection Modal
  container.appendChild(
    tags.div(
      {
        class: () =>
          `modal-backdrop ${showArtifactModal() ? "is-visible" : "is-hidden"}`,
        onclick: (e: MouseEvent) => {
          if (e.target === e.currentTarget) showArtifactModal.set(false);
        },
      },
      () => {
        if (!showArtifactModal()) return null;
        const art = activeArtifact();
        if (!art) return null;

        return tags.div(
          { class: "modal-card artifact-modal" },
          tags.div(
            { class: "modal-hdr" },
            tags.div(
              { class: "modal-hdr-left" },
              iconDownload(16),
              tags.h3({ class: "modal-title" }, `Artifact: ${art.name}`)
            ),
            tags.button(
              {
                class: "modal-close-btn",
                onclick: () => showArtifactModal.set(false),
              },
              iconClose(14)
            )
          ),
          tags.div(
            { class: "modal-body" },
            art.isImage
              ? tags.div(
                  { class: "artifact-img-wrap" },
                  tags.img({ class: "artifact-img", src: art.content })
                )
              : tags.pre({ class: "artifact-pre" }, art.content)
          ),
          tags.div(
            { class: "modal-actions" },
            tags.button(
              {
                class: "btn btn-secondary",
                onclick: () => {
                  if (!art.isImage) navigator.clipboard.writeText(art.content);
                },
              },
              iconCopy(12),
              tags.span({}, "Copy Text")
            ),
            tags.button(
              {
                class: "btn btn-primary",
                onclick: () => showArtifactModal.set(false),
              },
              "Close"
            )
          )
        );
      }
    )
  );

  // 7. Shortcuts Modal
  container.appendChild(
    tags.div(
      {
        class: () =>
          `modal-backdrop ${showShortcutsModal() ? "is-visible" : "is-hidden"}`,
        onclick: (e: MouseEvent) => {
          if (e.target === e.currentTarget) showShortcutsModal.set(false);
        },
      },
      () => {
        if (!showShortcutsModal()) return null;

        // desc 存 i18n 键,渲染时经 t() 求值,跟随语言切换。
        const SHORTCUTS = [
          { key: "Ctrl + K / ⌘K", desc: "shortcuts.palette" },
          { key: "Ctrl + B / ⌘B", desc: "shortcuts.sidebar" },
          { key: "Ctrl + J / ⌘J", desc: "shortcuts.deck" },
          { key: "Ctrl + Shift + D", desc: "shortcuts.diffs" },
          { key: "Ctrl + Shift + T", desc: "shortcuts.terminal" },
          { key: "Ctrl + Shift + R", desc: "shortcuts.regenerate" },
          { key: "Enter", desc: "shortcuts.send" },
          { key: "Shift + Enter", desc: "shortcuts.newline" },
          { key: "↑ / ↓", desc: "shortcuts.history" },
          { key: "Esc", desc: "shortcuts.interrupt" },
          { key: "Ctrl + V / ⌘V", desc: "shortcuts.paste" },
          { key: "!cmd", desc: "shortcuts.bang_cmd" },
          { key: "!!cmd", desc: "shortcuts.bang_bang_cmd" },
          { key: "/", desc: "shortcuts.slash" },
          { key: "@", desc: "shortcuts.at" },
          { key: "?", desc: "shortcuts.help" },
        ];

        return tags.div(
          { class: "modal-card shortcuts-modal" },
          tags.div(
            { class: "modal-hdr" },
            tags.div(
              { class: "modal-hdr-left" },
              iconHelp(16),
              tags.h3({ class: "modal-title" }, () => t("shortcuts.title"))
            ),
            tags.button(
              {
                class: "modal-close-btn",
                onclick: () => showShortcutsModal.set(false),
              },
              iconClose(14)
            )
          ),
          tags.div(
            { class: "modal-body" },
            tags.div(
              { class: "shortcuts-list" },
              SHORTCUTS.map((item) =>
                tags.div(
                  { class: "shortcut-row" },
                  tags.kbd({ class: "shortcut-key" }, item.key),
                  tags.span({ class: "shortcut-desc" }, () => t(item.desc))
                )
              )
            )
          )
        );
      }
    )
  );

  // 9. 通用输入 / 确认对话框(替代原生 prompt/confirm 的白底弹窗)
  container.appendChild(
    tags.div(
      {
        class: () => `modal-backdrop ${askDialog() ? "is-visible" : "is-hidden"}`,
        onclick: (e: MouseEvent) => {
          if (e.target === e.currentTarget) settleAsk(null);
        },
      },
      () => {
        const d = askDialog();
        if (!d) return null;
        const isPrompt = d.kind === "prompt";
        return tags.div(
          { class: "modal-card ask-modal" },
          tags.div({ class: "modal-hdr" }, tags.h3({ class: "modal-title" }, d.title)),
          isPrompt
            ? tags.input({
                class: "auth-token-input ask-input",
                value: () => askInput(),
                placeholder: d.placeholder,
                autofocus: true,
                oninput: (e: Event) => askInput.set((e.target as HTMLInputElement).value),
                onkeydown: (e: KeyboardEvent) => {
                  if (e.key === "Enter") settleAsk(askInput());
                  else if (e.key === "Escape") settleAsk(null);
                },
              })
            : null,
          tags.div(
            { class: "modal-actions" },
            tags.button(
              { class: "btn btn-deny", onclick: () => settleAsk(isPrompt ? null : false) },
              tags.span({}, () => t("modal.cancel"))
            ),
            tags.button(
              { class: "btn btn-allow", onclick: () => settleAsk(isPrompt ? askInput() : true) },
              tags.span({}, () => t("modal.confirm"))
            )
          )
        );
      }
    )
  );

  // 8. 全局 Toast 浮层容器
  container.appendChild(
    tags.div(
      { class: "toast-container" },
      each(toasts, (t) =>
        tags.div(
          {
            class: `toast-card toast-${t.type}`,
            onclick: () => dismissToast(t.id),
          },
          tags.span({ class: "toast-dot" }),
          tags.span({ class: "toast-msg" }, t.message),
          tags.button({ class: "toast-close" }, iconClose(11))
        )
      )
    )
  );

  return container;
}
