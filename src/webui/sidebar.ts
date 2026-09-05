// sidebar.ts —— 侧边工作区与会话抽屉管理
import { tags, each } from "./dom";
import {
  sidebarOpen,
  sessions,
  activeSession,
  switchSession,
  createSession,
  renameSession,
  deleteSession,
  forkSession,
  undoSession,
  compactSession,
  archiveSession,
  restoreSession,
  workspaces,
  currentWs,
  wsName,
  switchWorkspace,
  showAddWorkspaceModal,
  t,
} from "./store";
import { signal } from "./signal";
import { SessionItem, WorkspaceItem } from "./types";
import {
  iconPlus,
  iconTrash,
  iconSearch,
  iconClose,
  iconFolder,
  iconFolderPlus,
  iconFork,
  iconUndo,
  iconCompact,
  iconArchive,
  iconRotateCcw,
  iconEdit,
  iconChevronDown,
} from "./icons";

export function renderSidebar(): HTMLElement {
  const searchQuery = signal<string>("");
  const showWsDropdown = signal<boolean>(false);

  const filteredSessions = () => {
    const q = searchQuery().toLowerCase().trim();
    const list = sessions();
    if (!q) return list;
    return list.filter((s) => (s.title || s.name).toLowerCase().includes(q));
  };

  return tags.aside(
    {
      class: () => `sidebar ${sidebarOpen() ? "is-open" : "is-collapsed"}`,
    },
    // 1. 顶层工作区选择卡
    tags.div(
      { class: "sidebar-ws-section" },
      tags.div(
        {
          class: "sidebar-ws-card",
          title: () => t("sidebar.switch_ws"),
          onclick: () => showWsDropdown.set(!showWsDropdown()),
        },
        tags.div({ class: "ws-icon" }, iconFolder(15)),
        tags.div(
          { class: "ws-info" },
          tags.div({ class: "ws-label" }, () => t("sidebar.project_ws")),
          tags.div({ class: "ws-name" }, () => wsName() || "workspace")
        ),
        tags.span({ class: "ws-chevron" }, iconChevronDown(12))
      ),
      // 工作区下拉选择单
      () => {
        if (!showWsDropdown()) return null;
        const list = workspaces();

        return tags.div(
          { class: "ws-dropdown" },
          tags.div({ class: "ws-dropdown-hdr" }, () => t("sidebar.project_ws")),
          list.length > 0
            ? list.map((w: WorkspaceItem) =>
                tags.div(
                  {
                    class: () =>
                      `ws-dropdown-item ${currentWs() === w.root ? "is-active" : ""}`,
                    onclick: (e: MouseEvent) => {
                      e.stopPropagation();
                      showWsDropdown.set(false);
                      switchWorkspace(w.root);
                    },
                  },
                  iconFolder(13),
                  tags.div(
                    { class: "ws-item-text" },
                    tags.div({ class: "ws-item-name" }, w.name),
                    tags.div({ class: "ws-item-root" }, w.root)
                  )
                )
              )
            : tags.div({ class: "ws-dropdown-empty" }, () => t("sidebar.no_external_ws")),
          tags.div(
            {
              class: "ws-add-item",
              onclick: (e: MouseEvent) => {
                e.stopPropagation();
                showWsDropdown.set(false);
                showAddWorkspaceModal.set(true);
              },
            },
            iconFolderPlus(13),
            tags.span({}, () => t("sidebar.add_project"))
          )
        );
      }
    ),

    // 2. 侧栏操作区（新建会话与搜索）
    tags.div(
      { class: "sidebar-hdr" },
      tags.button(
        {
          class: "new-session-btn",
          onclick: createSession,
        },
        iconPlus(13, "btn-icon"),
        tags.span({ class: "btn-text" }, () => t("sidebar.new_session"))
      )
    ),

    tags.div(
      { class: "sidebar-search-box" },
      iconSearch(12, "sidebar-search-icon"),
      tags.input({
        class: "sidebar-search-input",
        placeholder: () => t("sidebar.filter_sessions"),
        value: () => searchQuery(),
        oninput: (e: Event) => {
          searchQuery.set((e.target as HTMLInputElement).value);
        },
      }),
      () =>
        searchQuery()
          ? tags.button(
              {
                class: "sidebar-search-clear",
                onclick: () => searchQuery.set(""),
                title: "Clear filter",
              },
              iconClose(10)
            )
          : null
    ),

    // 3. 会话列表（支持重命名、Fork、Undo、Compact、删除）
    tags.div(
      { class: "sidebar-list" },
      each(filteredSessions, (item: SessionItem) => {
        const isCurrent = () => activeSession() === item.id;

        const isArchived = !!item.archived;

        return tags.div(
          {
            class: () => `session-item ${isCurrent() ? "is-active" : ""} ${isArchived ? "is-archived" : ""}`,
            onclick: () => switchSession(item.id),
          },
          tags.div(
            { class: "session-item-body" },
            tags.div({ class: "session-title" }, item.title || item.name),
            tags.div(
              { class: "session-meta" },
              tags.span({ class: "session-badge" }, `${item.messageCount} msgs`),
              isArchived ? tags.span({ class: "session-badge is-archived-badge" }, () => t("sidebar.archived_badge")) : null,
              tags.span({ class: "session-time" }, formatRelativeTime(item.updatedAt))
            )
          ),
          // 悬浮全功能操作条
          tags.div(
            { class: "session-actions", onclick: (e: MouseEvent) => e.stopPropagation() },
            !isArchived
              ? tags.button(
                  {
                    class: "session-act-btn",
                    title: () => t("sidebar.rename"),
                    onclick: () => {
                      const currentTitle = item.title || item.name;
                      const next = prompt(t("sidebar.rename_prompt"), currentTitle);
                      if (next && next.trim()) {
                        renameSession(item.id, next.trim());
                      }
                    },
                  },
                  iconEdit(12)
                )
              : null,
            !isArchived
              ? tags.button(
                  {
                    class: "session-act-btn",
                    title: () => t("sidebar.fork"),
                    onclick: () => forkSession(item.id),
                  },
                  iconFork(12)
                )
              : null,
            !isArchived
              ? tags.button(
                  {
                    class: "session-act-btn",
                    title: () => t("sidebar.undo"),
                    onclick: () => undoSession(item.id),
                  },
                  iconUndo(12)
                )
              : null,
            !isArchived
              ? tags.button(
                  {
                    class: "session-act-btn",
                    title: () => t("sidebar.compact"),
                    onclick: () => compactSession(item.id),
                  },
                  iconCompact(12)
                )
              : null,
            isArchived
              ? tags.button(
                  {
                    class: "session-act-btn",
                    title: () => t("sidebar.restore"),
                    onclick: () => restoreSession(item.id),
                  },
                  iconRotateCcw(12)
                )
              : tags.button(
                  {
                    class: "session-act-btn",
                    title: () => t("sidebar.archive"),
                    onclick: () => archiveSession(item.id),
                  },
                  iconArchive(12)
                ),
            tags.button(
              {
                class: "session-act-btn session-del-btn",
                title: () => t("sidebar.delete"),
                onclick: () => {
                  if (confirm(t("sidebar.del_confirm", { title: item.title || item.name }))) {
                    deleteSession(item.id);
                  }
                },
              },
              iconTrash(12)
            )
          )
        );
      }),
      () => {
        if (sessions().length === 0) {
          return tags.div({ class: "sidebar-empty" }, () => t("sidebar.no_sessions"));
        }
        return null;
      }
    ),

    // 4. 侧栏底部状态统计
    tags.div(
      { class: "sidebar-footer" },
      () => tags.span({}, t("sidebar.sessions_count", { count: sessions().length })),
      tags.span({ class: "sidebar-footer-dot" }, "·"),
      tags.span({ class: "sidebar-footer-mode" }, "Local DAG")
    )
  );
}

function formatRelativeTime(ts: number): string {
  if (!ts) return "";
  const diff = Date.now() - ts;
  if (diff < 60000) return "just now";
  if (diff < 3600000) return `${Math.floor(diff / 60000)}m ago`;
  if (diff < 86400000) return `${Math.floor(diff / 3600000)}h ago`;
  return `${Math.floor(diff / 86400000)}d ago`;
}
