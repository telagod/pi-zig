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
  toggleTheme,
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
            tags.h3({ class: "modal-title" }, "Permission Approval Required")
          ),
          tags.div(
            { class: "modal-body" },
            tags.p(
              { class: "perm-desc" },
              req.desc || "The agent is requesting authorization for the following action:"
            ),
            req.command
              ? tags.pre({ class: "perm-command" }, req.command)
              : null,
            req.path
              ? tags.div({ class: "perm-path" }, `Target: ${req.path}`)
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
              tags.span({}, "Deny")
            ),
            tags.button(
              {
                class: "btn btn-allow",
                onclick: () => approve(req.id, true),
              },
              iconCheck(13),
              tags.span({}, "Allow Execution")
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
              placeholder: "Search actions or sessions...",
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
            tags.div({ class: "palette-group-hdr" }, "Actions"),
            tags.div(
              {
                class: "palette-item",
                onclick: () => {
                  createSession();
                  showSearchModal.set(false);
                },
              },
              tags.span({ class: "palette-item-icon" }, iconPlus(14)),
              tags.span({}, "Create New Session")
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
              tags.span({}, "Scan & View Code Diffs")
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
              tags.span({}, "Open Terminal Viewer")
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
              tags.span({}, "View Background Jobs & Subagents")
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
              tags.span({}, "Refresh Model List from Providers")
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
              tags.span({}, "Open Workspace Settings")
            ),
            tags.div(
              {
                class: "palette-item",
                onclick: () => {
                  toggleTheme();
                  showSearchModal.set(false);
                },
              },
              tags.span({ class: "palette-item-icon" }, iconRefresh(14)),
              tags.span({}, "Toggle Theme (Light / Dark)")
            ),

            // 会话列表匹配
            sessionMatches.length > 0
              ? tags.div({ class: "palette-group-hdr" }, "Sessions")
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
                tags.span({ class: "palette-item-badge" }, `${s.messageCount} msgs`)
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
            tags.h3({ class: "modal-title" }, "Authentication Required")
          ),
          tags.p({ class: "auth-desc" }, "Please enter your server token to access piz."),
          tags.input({
            type: "password",
            class: "auth-token-input",
            placeholder: "Enter token...",
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
              "Connect"
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
            tags.div({ class: "modal-hdr-left" }, iconSettings(18), tags.h3({ class: "modal-title" }, "Workspace Settings")),
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
                      tags.div({ class: "settings-stat" }, `${pct()}% utilized`)
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
                        tags.div({ class: "metric-title" }, "Input Tokens"),
                        tags.div({ class: "metric-val" }, us.in.toLocaleString())
                      ),
                      tags.div(
                        { class: "usage-metric-card" },
                        tags.div({ class: "metric-title" }, "Output Tokens"),
                        tags.div({ class: "metric-val" }, us.out.toLocaleString())
                      ),
                      tags.div(
                        { class: "usage-metric-card" },
                        tags.div({ class: "metric-title" }, "Estimated Cost"),
                        tags.div({ class: "metric-val" }, `$${us.usd.toFixed(4)}`)
                      ),
                      tags.div(
                        { class: "usage-metric-card" },
                        tags.div({ class: "metric-title" }, "Total Ledger Entries"),
                        tags.div({ class: "metric-val" }, String(us.lines))
                      )
                    ),
                    us.tail
                      ? tags.div(
                          { class: "usage-tail-box" },
                          tags.div({ class: "tail-title" }, "Recent Activity Tail"),
                          tags.pre({ class: "tail-pre" }, us.tail)
                        )
                      : null
                  );

                case "packages":
                  const pkgs = packagesList();
                  return tags.div(
                    { class: "settings-pane" },
                    tags.div({ class: "pkg-section-title" }, `Project Packages (${pkgs.project.length})`),
                    pkgs.project.length > 0
                      ? pkgs.project.map((p: any) =>
                          tags.div(
                            { class: "pkg-item" },
                            tags.span({ class: "pkg-name" }, p.name),
                            tags.span({ class: "pkg-meta" }, `${p.skills || 0} skills · ${p.prompts || 0} prompts`)
                          )
                        )
                      : tags.div({ class: "settings-empty" }, "No local project packages installed"),
                    tags.div({ class: "pkg-section-title", style: "margin-top:16px;" }, `User Global Packages (${pkgs.user.length})`),
                    pkgs.user.length > 0
                      ? pkgs.user.map((p: any) =>
                          tags.div(
                            { class: "pkg-item" },
                            tags.span({ class: "pkg-name" }, p.name),
                            tags.span({ class: "pkg-meta" }, `${p.skills || 0} skills · ${p.prompts || 0} prompts`)
                          )
                        )
                      : tags.div({ class: "settings-empty" }, "No global packages installed")
                  );

                case "export":
                  return tags.div(
                    { class: "settings-pane" },
                    tags.p({ class: "settings-desc" }, "Export current session transcript, thought processes, and tool summaries into standard formats:"),
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
                          tags.div({ class: "card-title" }, "Export as Markdown (.md)"),
                          tags.div({ class: "card-desc" }, "Clean formatted GFM with code blocks and quotes")
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
                          tags.div({ class: "card-title" }, "Export as JSON (.json)"),
                          tags.div({ class: "card-desc" }, "Structured turns and step items for programmatic use")
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
                          tags.div({ class: "card-title" }, "Export as Standalone HTML (.html)"),
                          tags.div({ class: "card-desc" }, "Self-contained webpage ready for sharing and offline reading")
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
            tags.h3({ class: "modal-title" }, "Register Project Workspace")
          ),
          tags.p(
            { class: "auth-desc" },
            "Enter absolute local filesystem path of the repository or folder:"
          ),
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

        const SHORTCUTS = [
          { key: "Ctrl + K / ⌘K", desc: "Open command palette and session switcher" },
          { key: "Ctrl + B / ⌘B", desc: "Toggle workspace session drawer" },
          { key: "Ctrl + J / ⌘J", desc: "Toggle inspection deck (Diffs/Terminal/Jobs/Files)" },
          { key: "Ctrl + Shift + D", desc: "Jump directly to code diffs panel" },
          { key: "Ctrl + Shift + T", desc: "Jump directly to terminal panel" },
          { key: "Ctrl + Shift + R", desc: "Regenerate last assistant answer" },
          { key: "Enter", desc: "Send message / Submit prompt" },
          { key: "Shift + Enter", desc: "Insert new line in input composer" },
          { key: "↑ / ↓", desc: "Navigate prompt history when input is empty" },
          { key: "Esc", desc: "Interrupt generation / Close open dialogs" },
          { key: "Ctrl + V / ⌘V", desc: "Paste image from clipboard into composer" },
          { key: "!cmd", desc: "Execute shell command and feed output to model" },
          { key: "!!cmd", desc: "Execute shell command locally (preview only)" },
          { key: "/", desc: "Trigger slash command popup menu" },
          { key: "@", desc: "Trigger workspace file mention menu" },
          { key: "?", desc: "Open this keyboard shortcuts reference" },
        ];

        return tags.div(
          { class: "modal-card shortcuts-modal" },
          tags.div(
            { class: "modal-hdr" },
            tags.div(
              { class: "modal-hdr-left" },
              iconHelp(16),
              tags.h3({ class: "modal-title" }, "Keyboard Shortcuts & Command Guide")
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
                  tags.span({ class: "shortcut-desc" }, item.desc)
                )
              )
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
