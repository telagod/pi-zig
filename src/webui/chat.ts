// chat.ts —— 对话流视图 (Turn 境界、思考流折叠、步骤轨迹与 Markdown 渲染)
import { tags, each } from "./dom";
import { turns, isStreaming, appendTerminalLine, setDeckTab } from "./store";
import { renderMarkdown } from "./md";
import { Turn, StepItem } from "./types";
import { signal, effect } from "./signal";
import {
  iconBot,
  iconUser,
  iconSpinner,
  iconCheck,
  iconClose,
  iconChevronRight,
  iconChevronDown,
  iconChevronUp,
  iconCopy,
  iconTerminal,
  iconBolt,
  iconDiff,
  iconShield,
} from "./icons";

export function renderChatStream(): HTMLElement {
  let userScrolledUp = false;

  const container = tags.div(
    {
      class: "chat-stream",
      onscroll: (e: Event) => {
        const el = e.target as HTMLElement;
        const distFromBottom = el.scrollHeight - el.scrollTop - el.clientHeight;
        userScrolledUp = distFromBottom > 80;
      },
    },
    // 渲染每一轮对话
    each(turns, (turn: Turn) => {
      if (turn.role === "user") {
        return renderUserTurn(turn);
      } else {
        return renderAssistantTurn(turn);
      }
    }),
    // 空态欢迎页
    () => {
      if (turns().length === 0) {
        return renderEmptyState();
      }
      return null;
    }
  );

  // 自动滚动到底部
  effect(() => {
    turns();
    isStreaming();
    if (!userScrolledUp) {
      setTimeout(() => {
        container.scrollTop = container.scrollHeight;
      }, 20);
    }
  });

  return container;
}

function renderEmptyState(): HTMLElement {
  return tags.div(
    { class: "chat-empty-state" },
    tags.div(
      { class: "empty-brand" },
      tags.div({ class: "empty-logo-wrap" }, iconBot(28, "empty-logo-icon")),
      tags.h2({ class: "empty-title" }, "piz workspace"),
      tags.p({ class: "empty-subtitle" }, "极速、安全的下一代自律型智能体工作台")
    ),
    tags.div(
      { class: "empty-prompts" },
      tags.div(
        { class: "prompt-card" },
        tags.div({ class: "prompt-card-icon" }, iconBolt(18)),
        tags.div(
          { class: "prompt-card-text" },
          tags.div({ class: "prompt-card-title" }, "任务驱动与自动编码"),
          tags.div({ class: "prompt-card-desc" }, "自动分解目标，阅读依赖，编写代码并运行验证")
        )
      ),
      tags.div(
        { class: "prompt-card" },
        tags.div({ class: "prompt-card-icon" }, iconDiff(18)),
        tags.div(
          { class: "prompt-card-text" },
          tags.div({ class: "prompt-card-title" }, "代码审查与检视台"),
          tags.div({ class: "prompt-card-desc" }, "在右侧实时检视变更行数、Hunk 差异与终端输出")
        )
      ),
      tags.div(
        { class: "prompt-card" },
        tags.div({ class: "prompt-card-icon" }, iconShield(18)),
        tags.div(
          { class: "prompt-card-text" },
          tags.div({ class: "prompt-card-title" }, "安全审计与授权把关"),
          tags.div({ class: "prompt-card-desc" }, "命令防护拦截、权限确认与严格的沙箱隔离")
        )
      )
    )
  );
}

function renderUserTurn(turn: Turn): HTMLElement {
  return tags.div(
    { class: "turn turn-user", id: turn.id },
    tags.div(
      { class: "turn-inner" },
      tags.div({ class: "turn-avatar user-avatar" }, iconUser(15)),
      tags.div(
        { class: "turn-body" },
        tags.div({ class: "user-bubble" }, turn.content)
      )
    )
  );
}

function renderAssistantTurn(turn: Turn): HTMLElement {
  const thoughtCollapsed = signal<boolean>(!turn.isStreaming && Boolean(turn.content));
  const copied = signal<boolean>(false);

  return tags.div(
    { class: "turn turn-assistant", id: turn.id },
    tags.div(
      { class: "turn-inner" },
      tags.div({ class: "turn-avatar assistant-avatar" }, iconBot(15)),
      tags.div(
        { class: "turn-body" },
        // 1. 思考流折叠
        () => {
          if (!turn.thought && !turn.isStreaming) return null;
          if (!turn.thought && turn.isStreaming && turn.steps.length === 0) {
            return tags.div(
              { class: "thought-panel is-thinking" },
              iconSpinner(13, "thought-spinner"),
              tags.span({ class: "thought-label" }, "Thinking...")
            );
          }
          if (!turn.thought) return null;

          const durationText = turn.thoughtDurationMs
            ? ` (${(turn.thoughtDurationMs / 1000).toFixed(1)}s)`
            : "";

          return tags.div(
            { class: "thought-panel" },
            tags.div(
              {
                class: "thought-header",
                onclick: () => thoughtCollapsed.set(!thoughtCollapsed()),
              },
              tags.span({ class: "thought-chevron" }, () =>
                thoughtCollapsed() ? iconChevronRight(12) : iconChevronDown(12)
              ),
              tags.span({ class: "thought-title" }, `Thinking Process${durationText}`),
              turn.isStreaming
                ? tags.span({ class: "thought-live-badge" }, "LIVE")
                : null
            ),
            () => {
              if (thoughtCollapsed()) return null;
              return tags.div({ class: "thought-content" }, turn.thought || "");
            }
          );
        },

        // 2. 步骤执行轨 (Step Track)
        () => {
          if (!turn.steps || turn.steps.length === 0) return null;
          return tags.div(
            { class: "step-track" },
            turn.steps.map((st) => renderStepCard(st))
          );
        },

        // 3. 正文 Markdown
        () => {
          const content = turn.content || "";
          if (!content && turn.isStreaming) {
            return tags.div(
              { class: "markdown-body is-generating" },
              tags.span({ class: "typing-cursor" })
            );
          }

          const html = renderMarkdown(content);
          const el = tags.div({ class: "markdown-body" });
          el.innerHTML = html;
          if (turn.isStreaming) {
            const cursor = document.createElement("span");
            cursor.className = "typing-cursor";
            el.appendChild(cursor);
          }
          return el;
        },

        // 4. 底部操作微栏 (复制等)
        () => {
          if (!turn.content || turn.isStreaming) return null;
          return tags.div(
            { class: "turn-footer-actions" },
            tags.button(
              {
                class: "turn-action-btn",
                title: "Copy reply",
                onclick: () => {
                  navigator.clipboard.writeText(turn.content || "");
                  copied.set(true);
                  setTimeout(() => copied.set(false), 2000);
                },
              },
              () => (copied() ? iconCheck(12) : iconCopy(12)),
              tags.span({}, () => (copied() ? "Copied" : "Copy"))
            )
          );
        }
      )
    )
  );
}

function renderStepCard(step: StepItem): HTMLElement {
  const isExpanded = signal<boolean>(false);
  const stepCopied = signal<boolean>(false);

  return tags.div(
    {
      class: () => `step-card status-${step.status}`,
    },
    tags.div(
      {
        class: "step-card-hdr",
        onclick: () => isExpanded.set(!isExpanded()),
      },
      tags.span({ class: "step-status-icon" }, () => {
        if (step.status === "running") return iconSpinner(13);
        if (step.status === "error") return iconClose(13);
        return iconCheck(13);
      }),
      tags.span({ class: "step-name" }, step.name),
      step.desc ? tags.span({ class: "step-desc" }, step.desc) : null,
      tags.span(
        { class: "step-time" },
        step.durationMs ? `${(step.durationMs / 1000).toFixed(2)}s` : "..."
      ),
      tags.span({ class: "step-chevron" }, () =>
        isExpanded() ? iconChevronUp(12) : iconChevronDown(12)
      )
    ),
    // 展开查看详情
    () => {
      if (!isExpanded()) return null;
      return tags.div(
        { class: "step-details" },
        step.args
          ? tags.div(
              { class: "step-detail-row" },
              tags.div({ class: "step-detail-lbl" }, "Arguments:"),
              tags.pre(
                { class: "step-detail-pre" },
                typeof step.args === "string"
                  ? step.args
                  : JSON.stringify(step.args, null, 2)
              )
            )
          : null,
        step.result
          ? tags.div(
              { class: "step-detail-row" },
              tags.div({ class: "step-detail-lbl" }, "Result:"),
              tags.pre({ class: "step-detail-pre" }, step.result)
            )
          : null,
        step.error
          ? tags.div(
              { class: "step-detail-row step-error" },
              tags.div({ class: "step-detail-lbl" }, "Error:"),
              tags.pre({ class: "step-detail-pre" }, step.error)
            )
          : null,
        tags.div(
          { class: "step-actions" },
          tags.button(
            {
              class: "step-deck-btn",
              onclick: () => {
                const text = step.result || step.error || "";
                navigator.clipboard.writeText(text);
                stepCopied.set(true);
                setTimeout(() => stepCopied.set(false), 2000);
              },
            },
            () => (stepCopied() ? iconCheck(12) : iconCopy(12)),
            tags.span({}, () => (stepCopied() ? "Copied" : "Copy"))
          ),
          tags.button(
            {
              class: "step-deck-btn",
              onclick: () => {
                appendTerminalLine(
                  `=== Step ${step.name} ===\n${step.result || step.error || ""}`,
                  "system"
                );
                setDeckTab("terminal");
              },
            },
            iconTerminal(12),
            tags.span({}, "Send to Terminal")
          )
        )
      );
    }
  );
}
