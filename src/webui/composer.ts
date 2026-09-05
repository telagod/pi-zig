// composer.ts —— 底部智能输入台 (自适应高度、斜杠补全、多模态剪贴板图片粘贴、文件引用与流控)
import { tags } from "./dom";
import {
  sendMessage,
  interrupt,
  isStreaming,
  files,
  mode,
  switchMode,
  setDeckTab,
  attachedImage,
  slashCommands,
  executeSlash,
  activityList,
  killActivity,
  sandboxMode,
  setSandboxMode,
  activeSession,
  getDraft,
  setDraft,
  promptHistory,
  model,
  models,
  pct,
  switchModel,
  refreshModels,
  loadUsage,
  showSettingsModal,
  t,
} from "./store";
import { signal, effect } from "./signal";
import {
  iconSend,
  iconStop,
  iconFile,
  iconBolt,
  iconTerminal,
  iconQuestion,
  iconShield,
  iconSparkle,
  iconImage,
  iconClose,
  iconSparkles,
  iconRefresh,
} from "./icons";

export function renderComposer(): HTMLElement {
  const text = signal<string>("");
  const showSlashMenu = signal<boolean>(false);
  const showFileMenu = signal<boolean>(false);
  const menuIndex = signal<number>(0);
  const historyIndex = signal<number>(-1);

  let textareaEl: HTMLTextAreaElement | null = null;
  let fileInputEl: HTMLInputElement | null = null;

  // 全局暴露给外部快速填入 prompt
  (window as any).__pizFillComposer = (val: string) => {
    text.set(val);
    if (textareaEl) {
      textareaEl.value = val;
      autoResize(textareaEl);
      textareaEl.focus();
    }
    setDraft(activeSession(), val);
  };

  (window as any).__pizAppendComposer = (val: string) => {
    const cur = text().trim();
    const next = cur ? `${cur} ${val} ` : `${val} `;
    text.set(next);
    if (textareaEl) {
      textareaEl.value = next;
      autoResize(textareaEl);
      textareaEl.focus();
    }
    setDraft(activeSession(), next);
  };

  // 监听会话变更，恢复相应草稿
  effect(() => {
    const s = activeSession();
    const saved = getDraft(s);
    text.set(saved);
    if (textareaEl) {
      textareaEl.value = saved;
      autoResize(textareaEl);
    }
  });

  function handleInput(e: Event) {
    const el = e.target as HTMLTextAreaElement;
    const val = el.value;
    text.set(val);
    autoResize(el);
    setDraft(activeSession(), val);

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

  // 剪贴板图片粘贴处理
  function handlePaste(e: ClipboardEvent) {
    const items = e.clipboardData?.items;
    if (!items) return;

    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      if (item.type.startsWith("image/")) {
        e.preventDefault();
        const file = item.getAsFile();
        if (!file) continue;
        processImageFile(file);
        break;
      }
    }
  }

  function processImageFile(file: File) {
    const reader = new FileReader();
    reader.onload = (ev) => {
      const result = ev.target?.result as string;
      if (!result) return;
      const match = result.match(/^data:([^;]+);base64,(.+)$/);
      if (match) {
        attachedImage.set({
          mime: match[1],
          data: match[2],
          name: file.name || "pasted_image.png",
        });
      }
    };
    reader.readAsDataURL(file);
  }

  async function doSend() {
    const msg = text().trim();
    const hasImg = Boolean(attachedImage());
    if ((!msg && !hasImg) || isStreaming()) return;

    // 斜杠命令拦截执行
    if (msg.startsWith("/")) {
      const handled = await executeSlash(msg);
      if (handled) {
        clearInput();
        return;
      }
    }

    sendMessage(msg);
    clearInput();
  }

  function clearInput() {
    text.set("");
    historyIndex.set(-1);
    if (textareaEl) {
      textareaEl.value = "";
      autoResize(textareaEl);
    }
    setDraft(activeSession(), "");
    showSlashMenu.set(false);
    showFileMenu.set(false);
  }

  function handleKeyDown(e: KeyboardEvent) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      if (showSlashMenu()) {
        const q = text().toLowerCase();
        const filtered = slashCommands().filter((c) =>
          c.cmd.toLowerCase().startsWith(q) || c.desc.toLowerCase().includes(q.slice(1))
        );
        if (filtered[menuIndex()]) {
          const chosen = filtered[menuIndex()].cmd;
          text.set(chosen + " ");
          if (textareaEl) textareaEl.value = chosen + " ";
          showSlashMenu.set(false);
          return;
        }
      }
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
      } else if (!text() || (textareaEl && textareaEl.selectionStart === text().length)) {
        // 提示词历史向下
        const hist = promptHistory();
        if (historyIndex() !== -1) {
          e.preventDefault();
          const nextIdx = historyIndex() + 1;
          if (nextIdx >= hist.length) {
            historyIndex.set(-1);
            text.set("");
            if (textareaEl) {
              textareaEl.value = "";
              autoResize(textareaEl);
            }
          } else {
            historyIndex.set(nextIdx);
            const val = hist[nextIdx];
            text.set(val);
            if (textareaEl) {
              textareaEl.value = val;
              autoResize(textareaEl);
            }
          }
        }
      }
    } else if (e.key === "ArrowUp") {
      if (showSlashMenu() || showFileMenu()) {
        e.preventDefault();
        menuIndex.update((i) => Math.max(0, i - 1));
      } else if (!text() || (textareaEl && textareaEl.selectionStart === 0)) {
        // 提示词历史向上
        const hist = promptHistory();
        if (hist.length > 0) {
          e.preventDefault();
          const nextIdx =
            historyIndex() === -1 ? hist.length - 1 : Math.max(0, historyIndex() - 1);
          historyIndex.set(nextIdx);
          const val = hist[nextIdx];
          text.set(val);
          if (textareaEl) {
            textareaEl.value = val;
            autoResize(textareaEl);
          }
        }
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
    // 1. 后台活动流动态指示条
    () => {
      const active = activityList();
      if (active.length === 0) return null;
      const first = active[0];

      return tags.div(
        { class: "composer-live-activity-bar" },
        tags.span({ class: "activity-live-dot" }),
        tags.span(
          { class: "activity-live-text" },
          () =>
            `${t("composer.active_task")}: ${first.cmd || first.name} (pid:${first.pid || "bg"}) · ${first.duration ? first.duration + "s" : "running"}`
        ),
        tags.button(
          {
            class: "activity-kill-btn",
            title: () => t("composer.kill_task"),
            onclick: () => first.pid && killActivity(first.pid),
          },
          () => t("composer.kill_task")
        )
      );
    },

    // 2. 行内命令预览 Banner (!cmd 与 !!cmd)
    () => {
      const val = text();
      if (val.startsWith("!!") && val.length > 2) {
        return tags.div(
          { class: "composer-inline-hint hint-local" },
          tags.span({ class: "hint-icon" }, iconTerminal(14)),
          tags.span({}, `${t("composer.hint_local")} ${val.slice(2)}`)
        );
      }
      if (val.startsWith("!") && !val.startsWith("!!") && val.length > 1) {
        return tags.div(
          { class: "composer-inline-hint hint-model" },
          tags.span({ class: "hint-icon" }, iconBolt(14)),
          tags.span({}, `${t("composer.hint_model")} ${val.slice(1)}`)
        );
      }
      return null;
    },

    // 3. 图片附加预览条
    () => {
      const img = attachedImage();
      if (!img) return null;
      return tags.div(
        { class: "attached-img-bar" },
        tags.div(
          { class: "attached-img-pill" },
          tags.img({
            class: "attached-img-thumb",
            src: `data:${img.mime};base64,${img.data}`,
          }),
          tags.span({ class: "attached-img-name" }, img.name || "image.png"),
          tags.button(
            {
              class: "attached-img-remove",
              title: "Remove image",
              onclick: () => attachedImage.set(null),
            },
            iconClose(12)
          )
        )
      );
    },

    // 4. 斜杠菜单浮层（全量命令实时补全）
    () => {
      if (!showSlashMenu()) return null;
      const q = text().toLowerCase();
      const filtered = slashCommands().filter((c) =>
        c.cmd.toLowerCase().startsWith(q) || c.desc.toLowerCase().includes(q.slice(1))
      );
      if (!filtered.length) return null;

      return tags.div(
        { class: "popup-menu slash-menu" },
        filtered.slice(0, 10).map((item, idx) =>
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
            tags.span({ class: "menu-icon" }, iconSparkle(14)),
            tags.span({ class: "menu-cmd" }, item.cmd),
            tags.span({ class: "menu-desc" }, item.desc)
          )
        )
      );
    },

    // 5. @文件菜单浮层
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
                const next = `${before}@${f.path} `;
                text.set(next);
                if (textareaEl) {
                  textareaEl.value = next;
                  textareaEl.focus();
                }
                showFileMenu.set(false);
              },
            },
            tags.span({ class: "file-icon" }, iconFile(14)),
            tags.span({ class: "file-cmd" }, `@${f.name}`),
            tags.span({ class: "file-desc" }, f.path)
          )
        )
      );
    },

    // 隐藏的文件上传 input
    tags.input({
      type: "file",
      accept: "image/*",
      style: "display:none;",
      ref: (el: HTMLInputElement) => {
        fileInputEl = el;
      },
      onchange: (e: Event) => {
        const input = e.target as HTMLInputElement;
        if (input.files && input.files[0]) {
          processImageFile(input.files[0]);
          input.value = "";
        }
      },
    }),

    // 主输入框容器
    tags.div(
      { class: "composer-box" },
      tags.textarea({
        id: "inp",
        class: "composer-input",
        placeholder: () => t("composer.placeholder"),
        rows: "1",
        value: () => text(),
        oninput: handleInput,
        onkeydown: handleKeyDown,
        onpaste: handlePaste,
        ref: (el: HTMLTextAreaElement) => {
          textareaEl = el;
        },
      }),

      // 控制栏底排
      tags.div(
        { class: "composer-bar" },
        tags.div(
          { class: "composer-bar-left" },
          // 模型选择胶囊
          tags.div(
            { class: "composer-model-wrap", title: "Active LLM Model" },
            iconSparkles(12, "composer-model-icon"),
            tags.select(
              {
                class: "composer-model-select",
                title: "Switch active LLM model",
                value: () => model(),
                onchange: (e: Event) => {
                  const target = e.target as HTMLSelectElement;
                  if (target.value) switchModel(target.value);
                },
              },
              () => {
                const list = models();
                const cur = model();
                const opts = list.map((m) =>
                  tags.option({ value: m, selected: m === cur }, m)
                );
                if (cur && !list.includes(cur)) {
                  opts.unshift(tags.option({ value: cur, selected: true }, cur));
                }
                return opts;
              }
            ),
            tags.button(
              {
                class: "composer-model-refresh-btn",
                title: () => t("topbar.refresh_models"),
                onclick: refreshModels,
              },
              iconRefresh(11)
            )
          ),
          // Token 上下文使用量胶囊
          tags.button(
            {
              class: "composer-token-pill",
              title: "Context Window Usage - Click for Token Ledger",
              onclick: () => {
                loadUsage();
                showSettingsModal.set(true);
              },
            },
            tags.span({
              class: () => {
                const p = pct();
                return `token-dot ${p > 90 ? "is-danger" : p > 70 ? "is-warning" : "is-healthy"}`;
              },
            }),
            () => `${pct()}% ctx`
          ),
          tags.button(
            {
              class: "bar-tag-btn",
              title: () => t("composer.attach_img"),
              onclick: () => fileInputEl && fileInputEl.click(),
            },
            iconImage(13)
          ),
          tags.button(
            {
              class: "bar-tag-btn",
              title: () => t("composer.slash_menu"),
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
              title: () => t("composer.file_mention"),
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
                return tags.span({ class: "mode-badge mode-yolo" }, iconBolt(12), () => t("mode.yolo"));
              }
              if (curMode === "ask") {
                return tags.span({ class: "mode-badge mode-ask" }, iconQuestion(12), () => t("mode.ask"));
              }
              return tags.span({ class: "mode-badge mode-plan" }, iconShield(12), () => t("mode.read_only"));
            }
          ),
          // 沙箱药丸（点击轮切：off -> workspace -> strict）
          () => {
            const cur = sandboxMode();
            return tags.button(
              {
                class: `sandbox-pill sb-${cur}`,
                title: `Sandbox Mode: ${cur}. Click to toggle.`,
                onclick: () => {
                  const next = cur === "off" ? "workspace" : cur === "workspace" ? "strict" : "off";
                  setSandboxMode(next);
                },
              },
              tags.span({ class: "sb-dot" }),
              tags.span({}, () =>
                cur === "strict"
                  ? t("composer.sb_strict")
                  : cur === "workspace"
                  ? t("composer.sb_workspace")
                  : t("composer.sb_off")
              )
            );
          }
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
                tags.span({}, () => t("composer.stop"))
              );
            }
            return tags.button(
              {
                class: "composer-send-btn",
                title: "Send message (Enter)",
                onclick: doSend,
              },
              iconSend(13),
              tags.span({}, () => t("composer.send"))
            );
          }
        )
      )
    )
  );
}
