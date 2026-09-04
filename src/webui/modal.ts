// modal.ts —— 权限审批弹窗、命令面板与设置弹窗
import { tags } from "./dom";
import {
  pendingApproval,
  approve,
  showSearchModal,
  showAuthModal,
  showSettingsModal,
  sessions,
  switchSession,
  createSession,
  setDeckTab,
  models,
  model,
  switchModel,
  pct,
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
            tags.p({ class: "perm-desc" }, req.desc || "The agent is requesting authorization for the following action:"),
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
              placeholder: "Type a command or search sessions...",
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
            // 动作
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
                  setDeckTab("diffs");
                  showSearchModal.set(false);
                },
              },
              tags.span({ class: "palette-item-icon" }, iconDiff(14)),
              tags.span({}, "View Code Diffs")
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
          { class: "modal-card settings-modal" },
          tags.div(
            { class: "modal-hdr" },
            tags.h3({ class: "modal-title" }, "Workspace Settings"),
            tags.button(
              {
                class: "modal-close-btn",
                onclick: () => showSettingsModal.set(false),
              },
              iconClose(14)
            )
          ),
          tags.div(
            { class: "modal-body" },
            tags.div(
              { class: "settings-row" },
              tags.label({}, "Active Model"),
              tags.select(
                {
                  class: "settings-select",
                  value: () => model(),
                  onchange: (e: Event) => switchModel((e.target as HTMLSelectElement).value),
                },
                models().map((m) => tags.option({ value: m, selected: m === model() }, m))
              )
            ),
            tags.div(
              { class: "settings-row" },
              tags.label({}, "Context Window Usage"),
              tags.div({ class: "settings-stat" }, `${pct()}% utilized`)
            ),
            tags.div(
              { class: "settings-row" },
              tags.label({}, "Interface Architecture"),
              tags.div({ class: "settings-stat" }, "WebUI Next v2.0 (Signals Reactive)")
            )
          )
        );
      }
    )
  );

  return container;
}
