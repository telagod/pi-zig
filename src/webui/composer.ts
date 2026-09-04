// composer.ts —— 底部智能输入台 (自适应高度、斜杠补全、文件引用与流控)
import { tags } from "./dom";
import {
  sendMessage,
  interrupt,
  isStreaming,
  files,
  mode,
  switchMode,
  createSession,
  setDeckTab,
} from "./store";
import { signal } from "./signal";
import {
  iconSend,
  iconStop,
  iconFile,
  iconBolt,
  iconQuestion,
  iconCompass,
  iconDiff,
  iconTerminal,
  iconCpu,
  iconTrash,
  iconSparkle,
} from "./icons";

export function renderComposer(): HTMLElement {
  const text = signal<string>("");
  const showSlashMenu = signal<boolean>(false);
  const showFileMenu = signal<boolean>(false);
  const menuIndex = signal<number>(0);

  let textareaEl: HTMLTextAreaElement | null = null;

  const SLASH_COMMANDS = [
    { cmd: "/diff", desc: "Open right deck to inspect code changes", icon: iconDiff },
    { cmd: "/term", desc: "Open terminal viewer in deck", icon: iconTerminal },
    { cmd: "/jobs", desc: "View subagent hierarchy and jobs", icon: iconCpu },
    { cmd: "/files", desc: "Browse workspace files", icon: iconFile },
    { cmd: "/clear", desc: "Create a fresh new session", icon: iconTrash },
    { cmd: "/yolo", desc: "Switch mode to YOLO (auto-execute)", icon: iconBolt },
    { cmd: "/ask", desc: "Switch mode to Ask (require approval)", icon: iconQuestion },
    { cmd: "/plan", desc: "Switch mode to Plan (write plan first)", icon: iconCompass },
  ];

  function handleInput(e: Event) {
    const el = e.target as HTMLTextAreaElement;
    text.set(el.value);
    autoResize(el);

    const val = el.value;
    if (val.startsWith("/")) {
      showSlashMenu.set(true);
      showFileMenu.set(false);
      menuIndex.set(0);
    } else if (val.includes("@")) {
      showFileMenu.set(true);
      showSlashMenu.set(false);
      menuIndex.set(0);
    } else {
      showSlashMenu.set(false);
      showFileMenu.set(false);
    }
  }

  function autoResize(el: HTMLTextAreaElement) {
    el.style.height = "auto";
    const nextH = Math.min(Math.max(el.scrollHeight, 40), 220);
    el.style.height = `${nextH}px`;
  }

  function doSend() {
    const msg = text().trim();
    if (!msg || isStreaming()) return;

    // 本地拦截部分斜杠命令
    if (msg === "/diff") {
      setDeckTab("diffs");
      clearInput();
      return;
    }
    if (msg === "/term") {
      setDeckTab("terminal");
      clearInput();
      return;
    }
    if (msg === "/jobs") {
      setDeckTab("jobs");
      clearInput();
      return;
    }
    if (msg === "/files") {
      setDeckTab("files");
      clearInput();
      return;
    }
    if (msg === "/clear") {
      createSession();
      clearInput();
      return;
    }
    if (msg === "/yolo") {
      switchMode("yolo");
      clearInput();
      return;
    }
    if (msg === "/ask") {
      switchMode("ask");
      clearInput();
      return;
    }
    if (msg === "/plan") {
      switchMode("plan");
      clearInput();
      return;
    }

    sendMessage(msg);
    clearInput();
  }

  function clearInput() {
    text.set("");
    if (textareaEl) {
      textareaEl.value = "";
      autoResize(textareaEl);
    }
    showSlashMenu.set(false);
    showFileMenu.set(false);
  }

  function handleKeyDown(e: KeyboardEvent) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      // 如果斜杠菜单开着，回车选择当前项
      if (showSlashMenu()) {
        const q = text().toLowerCase();
        const filtered = SLASH_COMMANDS.filter((c) => c.cmd.toLowerCase().startsWith(q));
        if (filtered[menuIndex()]) {
          text.set(filtered[menuIndex()].cmd + " ");
          if (textareaEl) textareaEl.value = filtered[menuIndex()].cmd + " ";
          showSlashMenu.set(false);
          return;
        }
      }
      // 如果文件菜单开着，回车选择当前文件
      if (showFileMenu()) {
        const atIdx = text().lastIndexOf("@");
        const q = atIdx >= 0 ? text().slice(atIdx + 1).toLowerCase() : "";
        const filtered = files()
          .filter((f) => !f.dir && f.path.toLowerCase().includes(q))
          .slice(0, 10);
        if (filtered[menuIndex()]) {
          const before = text().slice(0, atIdx);
          const nextVal = `${before}@${filtered[menuIndex()].path} `;
          text.set(nextVal);
          if (textareaEl) textareaEl.value = nextVal;
          showFileMenu.set(false);
          return;
        }
      }
      doSend();
    } else if (e.key === "ArrowDown") {
      if (showSlashMenu() || showFileMenu()) {
        e.preventDefault();
        menuIndex.update((i) => i + 1);
      }
    } else if (e.key === "ArrowUp") {
      if (showSlashMenu() || showFileMenu()) {
        e.preventDefault();
        menuIndex.update((i) => Math.max(0, i - 1));
      }
    } else if (e.key === "Escape") {
      if (showSlashMenu() || showFileMenu()) {
        e.preventDefault();
        showSlashMenu.set(false);
        showFileMenu.set(false);
      } else if (isStreaming()) {
        e.preventDefault();
        interrupt();
      }
    }
  }

  return tags.div(
    { class: "composer-wrap" },
    // 斜杠菜单浮层
    () => {
      if (!showSlashMenu()) return null;
      const q = text().toLowerCase();
      const filtered = SLASH_COMMANDS.filter((c) => c.cmd.toLowerCase().startsWith(q));
      if (!filtered.length) return null;

      return tags.div(
        { class: "popup-menu slash-menu" },
        filtered.map((item, idx) =>
          tags.div(
            {
              class: () => `menu-item ${menuIndex() === idx ? "is-selected" : ""}`,
              onclick: () => {
                text.set(item.cmd + " ");
                if (textareaEl) {
                  textareaEl.value = item.cmd + " ";
                  textareaEl.focus();
                }
                showSlashMenu.set(false);
              },
            },
            tags.span({ class: "menu-icon" }, item.icon ? item.icon(14) : iconSparkle(14)),
            tags.span({ class: "menu-cmd" }, item.cmd),
            tags.span({ class: "menu-desc" }, item.desc)
          )
        )
      );
    },

    // @文件菜单浮层
    () => {
      if (!showFileMenu()) return null;
      const atIdx = text().lastIndexOf("@");
      const q = atIdx >= 0 ? text().slice(atIdx + 1).toLowerCase() : "";
      const filtered = files()
        .filter((f) => !f.dir && f.path.toLowerCase().includes(q))
        .slice(0, 10);
      if (!filtered.length) return null;

      return tags.div(
        { class: "popup-menu file-menu" },
        filtered.map((f, idx) =>
          tags.div(
            {
              class: () => `menu-item ${menuIndex() === idx ? "is-selected" : ""}`,
              onclick: () => {
                const before = text().slice(0, atIdx);
                const nextVal = `${before}@${f.path} `;
                text.set(nextVal);
                if (textareaEl) {
                  textareaEl.value = nextVal;
                  textareaEl.focus();
                }
                showFileMenu.set(false);
              },
            },
            tags.span({ class: "file-icon" }, iconFile(13)),
            tags.span({ class: "file-path" }, f.path)
          )
        )
      );
    },

    // 主输入框容器
    tags.div(
      { class: "composer-box" },
      tags.textarea({
        class: "composer-input",
        placeholder: "Ask piz or type '/' for commands, '@' to reference files...",
        rows: "1",
        value: () => text(),
        oninput: handleInput,
        onkeydown: handleKeyDown,
        ref: (el: HTMLTextAreaElement) => {
          textareaEl = el;
        },
      }),

      // 控制栏底排
      tags.div(
        { class: "composer-bar" },
        tags.div(
          { class: "composer-bar-left" },
          tags.button(
            {
              class: "bar-tag-btn",
              title: "Trigger Slash Commands",
              onclick: () => {
                text.set("/");
                if (textareaEl) {
                  textareaEl.value = "/";
                  textareaEl.focus();
                }
                showSlashMenu.set(true);
              },
            },
            tags.span({ class: "bar-tag-text" }, "/")
          ),
          tags.button(
            {
              class: "bar-tag-btn",
              title: "Reference File",
              onclick: () => {
                text.update((v) => v + "@");
                if (textareaEl) {
                  textareaEl.value = text();
                  textareaEl.focus();
                }
                showFileMenu.set(true);
              },
            },
            tags.span({ class: "bar-tag-text" }, "@")
          ),
          tags.div(
            { class: "mode-badge-wrap" },
            () => {
              const curMode = mode();
              if (curMode === "yolo") {
                return tags.span({ class: "mode-badge mode-yolo" }, iconBolt(12), "YOLO");
              }
              if (curMode === "ask") {
                return tags.span({ class: "mode-badge mode-ask" }, iconQuestion(12), "ASK");
              }
              return tags.span({ class: "mode-badge mode-plan" }, iconCompass(12), "PLAN");
            }
          )
        ),
        tags.div(
          { class: "composer-bar-right" },
          () => {
            if (isStreaming()) {
              return tags.button(
                {
                  class: "composer-send-btn is-stop",
                  title: "Interrupt Generation (Esc)",
                  onclick: interrupt,
                },
                iconStop(12),
                tags.span({}, "Stop")
              );
            }
            return tags.button(
              {
                class: "composer-send-btn",
                title: "Send message (Enter)",
                onclick: doSend,
              },
              iconSend(13),
              tags.span({}, "Send")
            );
          }
        )
      )
    )
  );
}
