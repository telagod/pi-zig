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
        tags.span({ class: "btn-icon" }, "＋"),
        tags.span({ class: "btn-text" }, "New Session")
      )
    ),

    // 搜索框
    tags.div(
      { class: "sidebar-search-box" },
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
                class: "session-act-btn",
                title: "Rename",
                onclick: () => {
                  const val = prompt("Rename session:", item.title || item.name);
                  if (val && val.trim()) renameSession(item.id, val.trim());
                },
              },
              "✎"
            ),
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
              "🗑"
            )
          )
        );
      })
    ),

    // 侧栏底端状态
    tags.div(
      { class: "sidebar-footer" },
      tags.span({ class: "sidebar-info" }, () => `${sessions().length} sessions`)
    )
  );
}

function formatRelativeTime(ts: number): string {
  if (!ts) return "";
  const sec = Math.max(1, Math.floor((Date.now() - ts) / 1000));
  if (sec < 60) return `${sec}s ago`;
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const days = Math.floor(hr / 24);
  return `${days}d ago`;
}
