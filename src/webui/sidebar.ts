// sidebar.ts —— 现代化项目工作区与会话展开树管理 (Project Session Tree)
import { tags, each } from "./dom";
import {
  sidebarOpen,
  sessions,
  projectSessions,
  expandedProjects,
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
  branch,
  switchWorkspace,
  showAddWorkspaceModal,
  loadSessions,
  t,
} from "./store";
import { signal, computed } from "./signal";
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
  iconChevronRight,
  iconBranch,
} from "./icons";

export function renderSidebar(): HTMLElement {
  const searchQuery = signal<string>("");

  // 聚合所有已知工程工作区 (当前工作区始终置顶，其余外部项目排列在后)
  const allProjects = computed(() => {
    const list = workspaces();
    const cur = currentWs();
    const curName = wsName() || "workspace";

    const exists = list.some((w) => w.root === cur);
    if (!exists) {
      return [
        { root: cur, name: curName, isCurrent: true },
        ...list.map((w) => ({ ...w, isCurrent: false })),
      ];
    }
    return list.map((w) => ({
      ...w,
      isCurrent: w.root === cur,
    }));
  });

  // 判断项目是否在树中展开 (当前活跃项目默认保持展开)
  function isExpanded(root: string): boolean {
    const exp = expandedProjects();
    if (exp[root] !== undefined) return exp[root];
    return root === currentWs() || !currentWs();
  }

  // 展开 / 折叠指定项目
  function toggleProject(root: string) {
    const nextState = !isExpanded(root);
    expandedProjects.update((prev) => ({ ...prev, [root]: nextState }));
    if (nextState) {
      const map = projectSessions();
      if (!map[root]) {
        loadSessions(root);
      }
    }
  }

  // 获取特定项目的会话列表
  function getSessionsForProject(root: string): SessionItem[] {
    if (root === currentWs()) {
      return sessions();
    }
    const map = projectSessions();
    return map[root] || [];
  }

  // 选择会话并切换到对应项目
  async function handleSelectSession(projectRoot: string, sessionId: string) {
    if (currentWs() !== projectRoot) {
      await switchWorkspace(projectRoot);
    }
    if (activeSession() !== sessionId) {
      await switchSession(sessionId);
    }
  }

  // 在特定项目下快捷新建会话
  async function handleCreateSessionInProject(e: MouseEvent, projectRoot: string) {
    e.stopPropagation();
    if (currentWs() !== projectRoot) {
      await switchWorkspace(projectRoot);
    }
    await createSession();
  }

  return tags.aside(
    {
      class: () => `sidebar ${sidebarOpen() ? "is-open" : "is-collapsed"}`,
    },
    // 1. 侧边栏顶栏操作群 (项目树标题 + 注册外部工程 + 极速新会话)
    tags.div(
      { class: "sidebar-hdr" },
      tags.div(
        { class: "sidebar-hdr-title-wrap" },
        tags.span({ class: "sidebar-hdr-title" }, () => t("sidebar.projects")),
        tags.span(
          { class: "sidebar-hdr-badge" },
          () => String(allProjects().length)
        )
      ),
      tags.div(
        { class: "sidebar-hdr-actions" },
        tags.button(
          {
            class: "sidebar-hdr-btn",
            title: () => t("sidebar.add_project"),
            onclick: () => showAddWorkspaceModal.set(true),
          },
          iconFolderPlus(13)
        ),
        tags.button(
          {
            class: "sidebar-hdr-btn is-primary",
            title: () => t("sidebar.new_session"),
            onclick: createSession,
          },
          iconPlus(13)
        )
      )
    ),

    // 2. 跨工程会话过滤搜索框
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

    // 3. 项目树与展开的会话列表 (Project Session Tree)
    tags.div(
      { class: "sidebar-project-tree" },
      each(allProjects, (project: WorkspaceItem) => {
        const isCurrentProj = () => currentWs() === project.root;
        const projectExpanded = () => {
          if (searchQuery().trim()) return true; // 搜索时自动展开以查看匹配会话
          return isExpanded(project.root);
        };

        const projSessions = () => {
          const raw = getSessionsForProject(project.root);
          const q = searchQuery().toLowerCase().trim();
          if (!q) return raw;
          return raw.filter((s) => (s.title || s.name).toLowerCase().includes(q));
        };

        return tags.div(
          {
            class: () =>
              `project-group ${isCurrentProj() ? "is-current-project" : ""}`,
          },
          // 项目树干节点 (Project Header)
          tags.div(
            {
              class: () =>
                `project-group-header ${isCurrentProj() ? "is-active" : ""}`,
              title: project.root || "Current project root",
              onclick: () => toggleProject(project.root),
            },
            tags.span(
              { class: "project-chevron" },
              () =>
                projectExpanded() ? iconChevronDown(11) : iconChevronRight(11)
            ),
            tags.span({ class: "project-folder-icon" }, iconFolder(13)),
            tags.div(
              { class: "project-name-wrap" },
              tags.span({ class: "project-name" }, project.name),
              isCurrentProj()
                ? tags.span({ class: "project-current-dot", title: "Active project" })
                : null,
              isCurrentProj() && branch()
                ? tags.span({ class: "project-branch-name" }, `(${branch()})`)
                : null
            ),
            tags.span(
              { class: "project-session-count" },
              () => String(projSessions().length)
            ),
            tags.button(
              {
                class: "project-add-session-btn",
                title: () => t("sidebar.new_session_in_project"),
                onclick: (e: MouseEvent) =>
                  handleCreateSessionInProject(e, project.root),
              },
              iconPlus(11)
            )
          ),

          // 项目展开的会话分支 (Sessions under this project)
          () => {
            if (!projectExpanded()) return null;
            const sList = projSessions();

            if (sList.length === 0) {
              return tags.div(
                { class: "project-sessions-empty" },
                () => t("sidebar.no_sessions")
              );
            }

            return tags.div(
              { class: "project-sessions-list" },
              sList.map((item: SessionItem) => {
                const isCurrentSession = () =>
                  isCurrentProj() && activeSession() === item.id;
                const isArchived = !!item.archived;

                return tags.div(
                  {
                    class: () =>
                      `session-item ${isCurrentSession() ? "is-active" : ""} ${isArchived ? "is-archived" : ""}`,
                    onclick: () =>
                      handleSelectSession(project.root, item.id),
                    ondblclick: (e: MouseEvent) => {
                      e.stopPropagation();
                      const currentTitle = item.title || item.name;
                      const next = prompt(t("sidebar.rename_prompt"), currentTitle);
                      if (next && next.trim()) {
                        renameSession(item.id, next.trim());
                      }
                    },
                  },
                  tags.div(
                    { class: "session-item-body" },
                    tags.div(
                      { class: "session-title" },
                      item.title || item.name
                    ),
                    tags.div(
                      { class: "session-meta" },
                      tags.span(
                        { class: "session-badge" },
                        `${item.messageCount} msgs`
                      ),
                      isArchived
                        ? tags.span(
                            { class: "session-badge is-archived-badge" },
                            () => t("sidebar.archived_badge")
                          )
                        : null,
                      tags.span(
                        { class: "session-time" },
                        formatRelativeTime(item.updatedAt)
                      )
                    )
                  ),
                  // 悬浮全功能会话操作条
                  tags.div(
                    {
                      class: "session-actions",
                      onclick: (e: MouseEvent) => e.stopPropagation(),
                    },
                    !isArchived
                      ? tags.button(
                          {
                            class: "session-act-btn",
                            title: () => t("sidebar.rename"),
                            onclick: () => {
                              const currentTitle = item.title || item.name;
                              const next = prompt(
                                t("sidebar.rename_prompt"),
                                currentTitle
                              );
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
                            onclick: () => {
                              const sTitle = item.title || item.name;
                              if (confirm(t("sidebar.fork_confirm", { title: sTitle }))) {
                                forkSession(item.id);
                              }
                            },
                          },
                          iconFork(12)
                        )
                      : null,
                    !isArchived
                      ? tags.button(
                          {
                            class: "session-act-btn",
                            title: () => t("sidebar.undo"),
                            onclick: () => {
                              const sTitle = item.title || item.name;
                              if (confirm(t("sidebar.undo_confirm", { title: sTitle }))) {
                                undoSession(item.id);
                              }
                            },
                          },
                          iconUndo(12)
                        )
                      : null,
                    !isArchived
                      ? tags.button(
                          {
                            class: "session-act-btn",
                            title: () => t("sidebar.compact"),
                            onclick: () => {
                              const sTitle = item.title || item.name;
                              if (confirm(t("sidebar.compact_confirm", { title: sTitle }))) {
                                compactSession(item.id);
                              }
                            },
                          },
                          iconCompact(12)
                        )
                      : null,
                    isArchived
                      ? tags.button(
                          {
                            class: "session-act-btn",
                            title: () => t("sidebar.restore"),
                            onclick: () => {
                              const sTitle = item.title || item.name;
                              if (confirm(t("sidebar.restore_confirm", { title: sTitle }))) {
                                restoreSession(item.id);
                              }
                            },
                          },
                          iconRotateCcw(12)
                        )
                      : tags.button(
                          {
                            class: "session-act-btn",
                            title: () => t("sidebar.archive"),
                            onclick: () => {
                              const sTitle = item.title || item.name;
                              if (confirm(t("sidebar.archive_confirm", { title: sTitle }))) {
                                archiveSession(item.id);
                              }
                            },
                          },
                          iconArchive(12)
                        ),
                    tags.button(
                      {
                        class: "session-act-btn session-del-btn",
                        title: () => t("sidebar.delete"),
                        onclick: () => {
                          const sTitle = item.title || item.name;
                          if (
                            confirm(
                              t("sidebar.del_confirm", {
                                title: sTitle,
                              })
                            )
                          ) {
                            deleteSession(item.id);
                          }
                        },
                      },
                      iconTrash(12)
                    )
                  )
                );
              })
            );
          }
        );
      })
    ),

    // 4. 侧边栏底部工程统计与树形层级指示
    tags.div(
      { class: "sidebar-footer" },
      () =>
        tags.span(
          {},
          `${allProjects().length} projects · ${sessions().length} sessions`
        ),
      tags.span({ class: "sidebar-footer-dot" }, "·"),
      tags.span({ class: "sidebar-footer-mode" }, "Tree")
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
