// chat.ts —— 对话流视图 (Turn 境界、思考流折叠、步骤轨迹与 Markdown 渲染)
import { tags, each, h } from "./dom";
import { turns, isStreaming, appendTerminalLine, setDeckTab } from "./store";
import { renderMarkdown } from "./md";
import { Turn, StepItem } from "./types";
import { signal, effect } from "./signal";

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
    // 触发依赖
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
      tags.svg(
        { class: "empty-logo", viewBox: "0 0 24 18", fill: "currentColor" },
        tags.path({
          d: "M2.4 1.8h17.2a1.7 1.7 0 0 1 0 3.4H10l10 8.2A1.8 1.8 0 0 1 18.65 16.45H3.2a1.7 1.7 0 0 1 0-3.4h9.4L2.7 4.9A1.8 1.8 0 0 1 4.1 1.8z",
        })
      ),
      tags.h2({ class: "empty-title" }, "piz - Agentic Workspace"),
      tags.p({ class: "empty-subtitle" }, "极速、安全的下一代自律型智能体工作台")
    ),
    tags.div(
      { class: "empty-prompts" },
      tags.div(
        { class: "prompt-card" },
        tags.div({ class: "prompt-card-title" }, "⚡ 快速诊断与修复"),
        tags.div({ class: "prompt-card-desc" }, "分析编译报错、内存泄漏或逻辑缺陷并立即提出补丁")
      ),
      tags.div(
        { class: "prompt-card" },
        tags.div({ class: "prompt-card-title" }, "🛠 代码审查与 Diff"),
        tags.div({ class: "prompt-card-desc" }, "在右侧检视台实时审查变更行数、Hunk 差异与终端输出")
      ),
      tags.div(
        { class: "prompt-card" },
        tags.div({ class: "prompt-card-title" }, "🛡 安全审计与攻防"),
        tags.div({ class: "prompt-card-desc" }, "污点分析、权限防范、最小权限原则审查与闭环验证")
      )
    )
  );
}

function renderUserTurn(turn: Turn): HTMLElement {
  return tags.div(
    { class: "turn turn-user", id: turn.id },
    tags.div(
      { class: "turn-inner" },
      tags.div({ class: "turn-avatar user-avatar" }, "U"),
      tags.div(
        { class: "turn-body" },
        tags.div({ class: "user-bubble" }, turn.content)
      )
    )
  );
}

function renderAssistantTurn(turn: Turn): HTMLElement {
  const thoughtCollapsed = signal<boolean>(!turn.isStreaming && Boolean(turn.content));

  return tags.div(
    { class: "turn turn-assistant", id: turn.id },
    tags.div(
      { class: "turn-inner" },
      tags.div({ class: "turn-avatar assistant-avatar" }, "π"),
      tags.div(
        { class: "turn-body" },
        // 1. 思考流折叠
        () => {
          if (!turn.thought && !turn.isStreaming) return null;
          if (!turn.thought && turn.isStreaming && turn.steps.length === 0) {
            return tags.div(
              { class: "thought-panel is-thinking" },
              tags.span({ class: "thought-spinner" }),
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
                thoughtCollapsed() ? "▸" : "▾"
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
            return tags.div({ class: "markdown-body is-generating" }, tags.span({ class: "typing-cursor" }));
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
        }
      )
    )
  );
}

function renderStepCard(step: StepItem): HTMLElement {
  const isExpanded = signal<boolean>(false);

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
        if (step.status === "running") return "⟳";
        if (step.status === "error") return "✕";
        return "✓";
      }),
      tags.span({ class: "step-name" }, step.name),
      step.desc ? tags.span({ class: "step-desc" }, step.desc) : null,
      tags.span(
        { class: "step-time" },
        step.durationMs ? `${(step.durationMs / 1000).toFixed(2)}s` : "..."
      ),
      tags.span({ class: "step-chevron" }, () => (isExpanded() ? "▴" : "▾"))
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
                appendTerminalLine(`=== Step ${step.name} ===\n${step.result || step.error || ""}`, "system");
                setDeckTab("terminal");
              },
            },
            "Send to Terminal"
          )
        )
      );
    }
  );
}
