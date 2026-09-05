// deck.ts —— 右侧工作台检视 Deck (Diffs/Terminal/Jobs/Files)
import { tags, each } from "./dom";
import {
  deckTab,
  setDeckTab,
  deckOpen,
  toggleDeck,
  diffs,
  activeDiffPath,
  activeDiffFile,
  totalDiffStats,
  terminalLines,
  jobs,
  files,
  loadFiles,
  appendTerminalLine,
  runTerminalCommand,
  refreshDiffs,
  commitChanges,
  activityList,
  killActivity,
  getQuery,
  t,
} from "./store";
import { ansiToHtml } from "./term";
import { DeckTab, JobItem, TerminalLine, FileTreeItem, ActivityItem } from "./types";
import { signal, effect } from "./signal";
import { apiFetch } from "./net";
import {
  iconDiff,
  iconTerminal,
  iconCpu,
  iconFolder,
  iconFile,
  iconClose,
  iconCopy,
  iconCheck,
  iconRefresh,
  iconCommit,
  iconTrash,
} from "./icons";

export function renderDeck(): HTMLElement {
  return tags.aside(
    {
      class: () => `workbench-deck ${deckOpen() ? "is-open" : "is-closed"}`,
    },
    // Deck 顶栏选项卡
    tags.header(
      { class: "deck-header" },
      tags.div(
        { class: "deck-tabs" },
        renderDeckTabBtn("diffs", iconDiff, "deck.tab_diffs", () => {
          const st = totalDiffStats();
          return st.files > 0 ? `${st.files}` : "";
        }),
        renderDeckTabBtn("terminal", iconTerminal, "deck.tab_terminal", () => {
          const len = terminalLines().length;
          return len > 0 ? `${len}` : "";
        }),
        renderDeckTabBtn("jobs", iconCpu, "deck.tab_jobs", () => {
          const runCount = activityList().length + jobs().filter((j) => j.status === "running").length;
          return runCount > 0 ? `${runCount}` : "";
        }),
        renderDeckTabBtn("files", iconFolder, "deck.tab_files")
      ),
      tags.div(
        { class: "deck-header-actions" },
        tags.button(
          {
            class: "deck-close-btn",
            title: "Close Deck (Ctrl+J)",
            onclick: toggleDeck,
          },
          iconClose(14)
        )
      )
    ),

    // Deck 主体内容区（根据 deckTab 响应式切换）
    tags.div(
      { class: "deck-body" },
      () => {
        const current = deckTab();
        switch (current) {
          case "diffs":
            return renderDiffsPanel();
          case "terminal":
            return renderTerminalPanel();
          case "jobs":
            return renderJobsPanel();
          case "files":
            return renderFilesPanel();
        }
      }
    )
  );
}

function renderDeckTabBtn(
  tab: DeckTab,
  iconFn: (size: number, cls: string) => SVGElement,
  titleKey: string,
  badgeFn?: () => string
): HTMLElement {
  return tags.button(
    {
      class: () => `deck-tab-btn ${deckTab() === tab ? "is-active" : ""}`,
      onclick: () => setDeckTab(tab),
    },
    iconFn(13, "deck-tab-icon"),
    tags.span({}, () => t(titleKey)),
    () => {
      const badge = badgeFn ? badgeFn() : "";
      if (!badge) return null;
      return tags.span({ class: "deck-tab-badge" }, badge);
    }
  );
}

// 1. Diffs 面板
function renderDiffsPanel(): HTMLElement {
  const list = diffs();
  const active = activeDiffFile();
  const stats = totalDiffStats();
  const diffCopied = signal<boolean>(false);

  if (list.length === 0) {
    return tags.div(
      { class: "deck-empty" },
      tags.div({ class: "deck-empty-icon" }, iconDiff(28)),
      tags.div({ class: "deck-empty-title" }, () => t("deck.diff_no_changes")),
      tags.div({ class: "deck-empty-desc" }, "Uncommitted modifications in workspace or agent diffs appear here."),
      tags.button(
        {
          class: "diff-refresh-btn-large",
          onclick: () => refreshDiffs(false),
        },
        iconRefresh(13),
        tags.span({}, () => t("deck.diff_scan"))
      )
    );
  }

  return tags.div(
    { class: "diff-panel" },
    // 变更文件选择条
    tags.div(
      { class: "diff-toolbar" },
      tags.div(
        { class: "diff-stats" },
        tags.span({ class: "diff-stat-add" }, `+${stats.additions}`),
        tags.span({ class: "diff-stat-del" }, `-${stats.deletions}`),
        tags.span({ class: "diff-stat-files" }, `${stats.files} files`),
        tags.button(
          {
            class: "diff-act-btn",
            title: "Refresh diff from repository",
            onclick: () => refreshDiffs(false),
          },
          iconRefresh(12),
          tags.span({}, "Refresh")
        ),
        tags.button(
          {
            class: "diff-act-btn",
            title: "Commit staged modifications",
            onclick: () => {
              const msg = prompt("Git commit message for staged changes:");
              if (msg && msg.trim()) commitChanges(msg.trim());
            },
          },
          iconCommit(12),
          tags.span({}, "Commit")
        ),
        tags.button(
          {
            class: "diff-act-btn",
            title: "Copy current diff patch",
            onclick: () => {
              if (!active) return;
              const patch = active.hunks
                .map(
                  (h) =>
                    h.header +
                    "\n" +
                    h.lines
                      .map(
                        (l) =>
                          (l.type === "add" ? "+" : l.type === "del" ? "-" : " ") +
                          l.content
                      )
                      .join("\n")
                )
                .join("\n");
              navigator.clipboard.writeText(patch);
              diffCopied.set(true);
              setTimeout(() => diffCopied.set(false), 2000);
            },
          },
          () => (diffCopied() ? iconCheck(12) : iconCopy(12)),
          tags.span({}, () => (diffCopied() ? "Copied" : "Copy Diff"))
        )
      ),
      tags.div(
        { class: "diff-file-tabs" },
        list.map((file) =>
          tags.button(
            {
              class: () =>
                `diff-file-btn ${active && active.path === file.path ? "is-active" : ""}`,
              onclick: () => activeDiffPath.set(file.path),
            },
            tags.span({ class: `diff-status-pill status-${file.status}` }, file.status[0].toUpperCase()),
            tags.span({ class: "diff-tab-path" }, file.path),
            tags.span({ class: "diff-tab-delta" }, `+${file.additions} -${file.deletions}`)
          )
        )
      )
    ),

    // 当前选中的 Diff 视窗
    tags.div(
      { class: "diff-viewport" },
      active
        ? tags.div(
            { class: "diff-file-view" },
            tags.div(
              { class: "diff-hunk-list" },
              active.hunks.map((hunk) =>
                tags.div(
                  { class: "diff-hunk" },
                  tags.div({ class: "diff-hunk-header" }, hunk.header),
                  tags.div(
                    { class: "diff-lines" },
                    hunk.lines.map((line) =>
                      tags.div(
                        { class: `diff-line line-${line.type}` },
                        tags.span({ class: "diff-line-old" }, line.oldNo ? String(line.oldNo) : ""),
                        tags.span({ class: "diff-line-new" }, line.newNo ? String(line.newNo) : ""),
                        tags.span({ class: "diff-line-marker" }, line.type === "add" ? "+" : line.type === "del" ? "-" : " "),
                        tags.span({ class: "diff-line-content" }, line.content)
                      )
                    )
                  )
                )
              )
            )
          )
        : null
    )
  );
}

// 2. Terminal 面板
function renderTerminalPanel(): HTMLElement {
  const autoScroll = signal<boolean>(true);
  const termCopied = signal<boolean>(false);
  let termEl: HTMLElement | null = null;

  effect(() => {
    terminalLines();
    if (autoScroll() && termEl) {
      setTimeout(() => {
        if (termEl) termEl.scrollTop = termEl.scrollHeight;
      }, 10);
    }
  });

  return tags.div(
    { class: "terminal-panel" },
    // 终端控制条
    tags.div(
      { class: "terminal-bar" },
      tags.div({ class: "terminal-bar-title" }, "Agent Output Terminal"),
      tags.div(
        { class: "terminal-bar-actions" },
        tags.button(
          {
            class: () => `term-act-btn ${autoScroll() ? "is-active" : ""}`,
            title: "Toggle Auto Scroll",
            onclick: () => autoScroll.set(!autoScroll()),
          },
          "Auto-scroll"
        ),
        tags.button(
          {
            class: "term-act-btn",
            title: "Clear output",
            onclick: () => terminalLines.set([]),
          },
          "Clear"
        ),
        tags.button(
          {
            class: "term-act-btn",
            title: "Copy all output",
            onclick: () => {
              const full = terminalLines().map((l) => l.text).join("\n");
              navigator.clipboard.writeText(full);
              termCopied.set(true);
              setTimeout(() => termCopied.set(false), 2000);
            },
          },
          () => (termCopied() ? iconCheck(12) : iconCopy(12)),
          tags.span({}, () => (termCopied() ? "Copied" : "Copy"))
        )
      )
    ),

    // 终端输出流
    tags.div(
      {
        class: "terminal-screen",
        ref: (el: HTMLElement) => {
          termEl = el;
        },
      },
      each(terminalLines, (line: TerminalLine) => {
        const row = tags.div({ class: `term-row row-${line.type}` });
        row.innerHTML = `<span class="term-time">${line.time}</span> <span class="term-text">${ansiToHtml(line.text)}</span>`;
        return row;
      }),
      () => {
        if (terminalLines().length === 0) {
          return tags.div({ class: "term-empty" }, "Terminal idle. Commands and logs will stream here.");
        }
        return null;
      }
    ),

    // 终端交互执行行 (无模型沙箱直接执行)
    tags.div(
      { class: "terminal-input-bar" },
      tags.span({ class: "terminal-prompt-prefix" }, "$"),
      tags.input({
        class: "terminal-cmd-input",
        placeholder: "Run shell command in workspace (e.g. git status, ls -la)...",
        onkeydown: (e: KeyboardEvent) => {
          if (e.key === "Enter") {
            const input = e.target as HTMLInputElement;
            const cmd = input.value.trim();
            if (!cmd) return;
            runTerminalCommand(cmd);
            input.value = "";
          }
        },
      })
    )
  );
}

// 3. Jobs 面板
function renderJobsPanel(): HTMLElement {
  const activeProcessList = activityList();
  const subagentList = jobs();

  const totalCount = activeProcessList.length + subagentList.length;

  if (totalCount === 0) {
    return tags.div(
      { class: "deck-empty" },
      tags.div({ class: "deck-empty-icon" }, iconCpu(28)),
      tags.div({ class: "deck-empty-title" }, "No Active Jobs or Subagents"),
      tags.div({ class: "deck-empty-desc" }, "Background processes, tool executions, and delegated subagents appear here.")
    );
  }

  return tags.div(
    { class: "jobs-panel" },
    // 1. 活动后台进程表
    activeProcessList.length > 0
      ? tags.div(
          { class: "jobs-section" },
          tags.div({ class: "jobs-section-title" }, "Active Background Tasks"),
          activeProcessList.map((proc: ActivityItem) =>
            tags.div(
              { class: "job-card status-running" },
              tags.div(
                { class: "job-card-hdr" },
                tags.span({ class: "job-status-dot" }),
                tags.span({ class: "job-name" }, proc.cmd || proc.name || `PID ${proc.pid}`),
                proc.pid ? tags.span({ class: "job-role" }, `pid:${proc.pid}`) : null,
                tags.span({ class: "job-status-pill" }, "RUNNING"),
                proc.pid
                  ? tags.button(
                      {
                        class: "job-kill-btn",
                        title: "Kill process",
                        onclick: () => proc.pid && killActivity(proc.pid),
                      },
                      iconTrash(11),
                      tags.span({}, "Kill")
                    )
                  : null
              ),
              tags.div(
                { class: "job-meta-row" },
                tags.span({}, `Duration: ${proc.duration ? proc.duration + "s" : "active"}`),
                proc.bytes ? tags.span({}, ` · Output: ${proc.bytes} bytes`) : null
              )
            )
          )
        )
      : null,

    // 2. 子智能体任务列表
    subagentList.length > 0
      ? tags.div(
          { class: "jobs-section" },
          tags.div({ class: "jobs-section-title" }, "Delegated Subagents"),
          subagentList.map((job: JobItem) =>
            tags.div(
              { class: `job-card status-${job.status}` },
              tags.div(
                { class: "job-card-hdr" },
                tags.span({ class: "job-status-dot" }),
                tags.span({ class: "job-name" }, job.name),
                job.role ? tags.span({ class: "job-role" }, job.role) : null,
                tags.span({ class: "job-status-pill" }, job.status.toUpperCase())
              ),
              job.summary ? tags.div({ class: "job-summary" }, job.summary) : null
            )
          )
        )
      : null
  );
}

// 4. Files 面板
function renderFilesPanel(): HTMLElement {
  const filter = signal<string>("");
  const selectedFile = signal<{ path: string; text: string } | null>(null);

  const filtered = () => {
    const q = filter().toLowerCase().trim();
    const list = files();
    if (!q) return list;
    return list.filter((f) => f.path.toLowerCase().includes(q));
  };

  return tags.div(
    { class: "files-panel" },
    // 检索条
    tags.div(
      { class: "files-search-bar" },
      tags.input({
        class: "files-search-input",
        placeholder: "Search workspace files...",
        value: () => filter(),
        oninput: (e: Event) => filter.set((e.target as HTMLInputElement).value),
      }),
      tags.button(
        {
          class: "files-refresh-btn",
          title: "Refresh files",
          onclick: () => loadFiles(),
        },
        iconRefresh(13)
      )
    ),

    // 文件列表与预览
    tags.div(
      { class: "files-split" },
      tags.div(
        { class: "files-tree" },
        each(filtered, (item: FileTreeItem) =>
          tags.div(
            {
              class: () =>
                `file-tree-item ${item.dir ? "is-dir" : "is-file"} ${selectedFile() && selectedFile()!.path === item.path ? "is-active" : ""}`,
              onclick: async () => {
                if (item.dir) return;
                try {
                  const res = await apiFetch(`/api/file${getQuery({ path: item.path })}`);
                  if (res && res.text != null) {
                    selectedFile.set({ path: item.path, text: res.text });
                  }
                } catch (e) {
                  console.error(e);
                }
              },
            },
            tags.span({ class: "item-icon" }, item.dir ? iconFolder(13) : iconFile(13)),
            tags.span({ class: "item-name" }, item.name)
          )
        )
      ),
      // 文件预览
      tags.div(
        { class: "file-preview-wrap" },
        () => {
          const cur = selectedFile();
          if (!cur) {
            return tags.div({ class: "file-preview-empty" }, "Select a file to inspect content.");
          }
          return tags.div(
            { class: "file-preview" },
            tags.div(
              { class: "file-preview-hdr" },
              tags.span({ class: "file-preview-path" }, cur.path),
              tags.button(
                {
                  class: "file-ref-btn",
                  title: "Insert reference @file into composer",
                  onclick: () => {
                    if ((window as any).__pizAppendComposer) {
                      (window as any).__pizAppendComposer(`@${cur.path}`);
                    }
                  },
                },
                iconFile(12),
                tags.span({}, "Reference @")
              )
            ),
            tags.pre({ class: "file-preview-code" }, cur.text)
          );
        }
      )
    )
  );
}
