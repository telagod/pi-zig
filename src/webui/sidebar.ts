// sidebar.ts —— 侧边会话抽屉与多会话管理
import { tags, each } from "./dom";
import {
  sidebarOpen,
  sessions,
  activeSession,
  switchSession,
  createSession,
  renameSession,
  deleteSession,
} from "./store";
import { signal } from "./signal";
import { SessionItem } from "./types";
import { iconPlus, iconTrash, iconSearch } from "./icons";

export function renderSidebar(): HTMLElement {
  const searchQuery = signal<string>("");

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
    // 侧栏顶操作
    tags.div(
      { class: "sidebar-hdr" },
      tags.button(
        {
          class: "new-session-btn",
          onclick: createSession,
        },
        iconPlus(13, "btn-icon"),
        tags.span({ class: "btn-text" }, "New Session")
      )
    ),

    // 搜索框
    tags.div(
      { class: "sidebar-search-box" },
      iconSearch(12, "sidebar-search-icon"),
      tags.input({
        class: "sidebar-search-input",
        placeholder: "Filter sessions...",
        value: () => searchQuery(),
        oninput: (e: Event) => {
          searchQuery.set((e.target as HTMLInputElement).value);
        },
      })
    ),

    // 会话列表
    tags.div(
      { class: "sidebar-list" },
      each(filteredSessions, (item: SessionItem) => {
        const isCurrent = () => activeSession() === item.id;

        return tags.div(
          {
            class: () => `session-item ${isCurrent() ? "is-active" : ""}`,
            onclick: () => switchSession(item.id),
          },
          tags.div(
            { class: "session-item-body" },
            tags.div({ class: "session-title" }, item.title || item.name),
            tags.div(
              { class: "session-meta" },
              tags.span({ class: "session-badge" }, `${item.messageCount} msgs`),
              tags.span({ class: "session-time" }, formatRelativeTime(item.updatedAt))
            )
          ),
          // 悬浮操作
          tags.div(
            { class: "session-actions", onclick: (e: MouseEvent) => e.stopPropagation() },
            tags.button(
              {
                class: "session-act-btn session-del-btn",
                title: "Delete",
                onclick: () => {
                  if (confirm(`Delete session "${item.title || item.name}"?`)) {
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
          return tags.div({ class: "sidebar-empty" }, "No sessions yet.");
        }
        return null;
      }
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
