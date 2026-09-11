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
  attachedAttachment,
  isModelVisionCapable,
  showToast,
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
import { AppMode } from "./types";
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
  iconPaperclip,
  iconClose,
  iconSparkles,
  iconRefresh,
  iconChevronDown,
  iconCheck,
} from "./icons";

// 自绘下拉的开合状态。原生 <select> 的弹层由系统渲染,深色主题下会跳出
// 白底下拉,因此模型/模式选择都改用 popup-menu 自绘。
const modelMenuOpen = signal<boolean>(false);
const modeMenuOpen = signal<boolean>(false);

function closeComposerMenus(): boolean {
  if (!modelMenuOpen() && !modeMenuOpen()) return false;
  modelMenuOpen.set(false);
  modeMenuOpen.set(false);
  return true;
}

// 点击空白处收起(面板与触发按钮自身 stopPropagation,不会误关)
document.addEventListener("click", () => {
  closeComposerMenus();
});

// Esc 收起:输入框失焦时也要管用,所以挂全局而不是 textarea 的 keydown。
// 菜单确实开着时截断传播,免得同一次 Esc 又去关弹窗或中断生成。
document.addEventListener("keydown", (e: KeyboardEvent) => {
  if (e.key === "Escape" && closeComposerMenus()) e.stopPropagation();
});

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

  // 剪贴板附件粘贴处理 (根据模型声明能力验证多模态图片或文本代码)
  function handlePaste(e: ClipboardEvent) {
    const items = e.clipboardData?.items;
    if (!items) return;

    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      if (item.type.startsWith("image/")) {
        e.preventDefault();
        const file = item.getAsFile();
        if (!file) continue;
        processAttachmentFile(file);
        break;
      } else if (item.kind === "file") {
        e.preventDefault();
        const file = item.getAsFile();
        if (!file) continue;
        processAttachmentFile(file);
        break;
      }
    }
  }

  function processAttachmentFile(file: File) {
    const isVision = isModelVisionCapable(model());
    const isImage = file.type.startsWith("image/") || /\.(png|jpe?g|webp|svg|gif|bmp)$/i.test(file.name);

    if (isImage) {
      if (!isVision) {
        showToast(t("composer.attach_no_vision"), "warning");
        return;
      }
      const reader = new FileReader();
      reader.onload = (ev) => {
        const result = ev.target?.result as string;
        if (!result) return;
        const match = result.match(/^data:([^;]+);base64,(.+)$/);
        if (match) {
          const item = {
            mime: match[1],
            data: match[2],
            name: file.name || "pasted_image.png",
            isImage: true,
            size: file.size,
          };
          attachedAttachment.set(item);
          attachedImage.set({
            mime: match[1],
            data: match[2],
            name: file.name || "pasted_image.png",
          });
        }
      };
      reader.readAsDataURL(file);
      return;
    }

    // 任意文本 / 代码 / 配置附件
    if (file.size > 5 * 1024 * 1024) {
      showToast("Attachment exceeds 5MB limit", "warning");
      return;
    }

    const reader = new FileReader();
    reader.onload = (ev) => {
      const textVal = ev.target?.result;
      if (typeof textVal === "string") {
        attachedAttachment.set({
          mime: file.type || "text/plain",
          textContent: textVal,
          name: file.name || "attachment.txt",
          isImage: false,
          size: file.size,
        });
      }
    };
    reader.readAsText(file);
  }

  async function doSend() {
    const msg = text().trim();
    const hasAtt = Boolean(attachedAttachment()) || Boolean(attachedImage());
    if ((!msg && !hasAtt) || isStreaming()) return;

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
    if (e.key === "Escape" && (modelMenuOpen() || modeMenuOpen())) {
      modelMenuOpen.set(false);
      modeMenuOpen.set(false);
      return;
    }
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

    // 3. 任意附件附加预览条 (支持多模态图片预览与代码文档附件标签)
    () => {
      const att = attachedAttachment();
      const img = attachedImage();
      if (!att && !img) return null;
      const isImg = att ? att.isImage : Boolean(img);
      const name = att ? att.name : (img?.name || "image.png");
      const sizeText = att && att.size ? ` (${Math.round(att.size / 1024)}KB)` : "";

      return tags.div(
        { class: "attached-img-bar" },
        tags.div(
          { class: "attached-img-pill" },
          isImg && (att?.data || img?.data)
            ? tags.img({
                class: "attached-img-thumb",
                src: `data:${att?.mime || img?.mime || "image/png"};base64,${att?.data || img?.data}`,
              })
            : iconFile(14, "attached-file-icon"),
          tags.span({ class: "attached-img-name" }, `${name}${sizeText}`),
          tags.button(
            {
              class: "attached-img-remove",
              title: () => t("composer.remove_attachment"),
              onclick: () => {
                attachedAttachment.set(null);
                attachedImage.set(null);
              },
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

    // 隐藏的文件上传 input (根据模型声明能力动态约束 accept)
    tags.input({
      type: "file",
      accept: () =>
        isModelVisionCapable(model())
          ? "image/*,text/*,.pdf,.txt,.md,.json,.csv,.zig,.py,.js,.ts,.c,.h,.cpp,.html,.css,.sh,.rs,.go,.java,.xml,.yaml,.yml,.toml,.diff,.patch"
          : "text/*,.txt,.md,.json,.csv,.zig,.py,.js,.ts,.c,.h,.cpp,.html,.css,.sh,.rs,.go,.java,.xml,.yaml,.yml,.toml,.diff,.patch",
      style: "display:none;",
      ref: (el: HTMLInputElement) => {
        fileInputEl = el;
      },
      onchange: (e: Event) => {
        const input = e.target as HTMLInputElement;
        if (input.files && input.files[0]) {
          processAttachmentFile(input.files[0]);
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
          // 模型选择胶囊(自绘下拉)
          tags.div(
            { class: "composer-model-wrap" },
            tags.button(
              {
                class: "composer-dd-trigger",
                title: () => t("composer.model_select_title"),
                onclick: (e: MouseEvent) => {
                  e.stopPropagation();
                  modeMenuOpen.set(false);
                  modelMenuOpen.set(!modelMenuOpen());
                },
              },
              iconSparkles(12, "composer-model-icon"),
              tags.span({ class: "composer-dd-label" }, () => model()),
              iconChevronDown(10, "composer-dd-caret")
            ),
            () => {
              if (!modelMenuOpen()) return null;
              const list = models();
              const cur = model();
              // 当前模型可能不在 provider 返回的列表里(手填或实验模型),补在首位
              const items = cur && !list.includes(cur) ? [cur, ...list] : list;
              return tags.div(
                {
                  class: "popup-menu composer-dd-menu",
                  onclick: (e: MouseEvent) => e.stopPropagation(),
                },
                items.map((m) =>
                  tags.div(
                    {
                      class: () => `menu-item ${m === model() ? "is-selected" : ""}`,
                      title: m,
                      onclick: () => {
                        switchModel(m);
                        modelMenuOpen.set(false);
                      },
                    },
                    tags.span(
                      { class: "menu-icon" },
                      m === model() ? iconCheck(12) : iconSparkle(12)
                    ),
                    tags.span({ class: "menu-cmd composer-dd-name" }, m)
                  )
                )
              );
            },
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
              title: () => t("composer.ctx_usage_title"),
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
          // 通用附件按钮 (取代旧图片按钮，根据模型多模态能力动态限制文件类型)
          tags.button(
            {
              class: "bar-tag-btn composer-attach-btn",
              title: () => t("composer.attach_file"),
              onclick: () => fileInputEl && fileInputEl.click(),
            },
            iconPaperclip(13)
          ),
          // 模式切换下拉栏目 (紧凑下拉选择 YOLO / ASK / READ-ONLY)
          renderComposerModeDropdown(),
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
                  title: () => t("composer.interrupt_hint"),
                  onclick: interrupt,
                },
                iconStop(12),
                tags.span({}, () => t("composer.stop"))
              );
            }
            return tags.button(
              {
                class: "composer-send-btn",
                title: () => t("composer.send_hint"),
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

const MODE_OPTIONS: { id: AppMode; label: string; desc: string }[] = [
  { id: "yolo", label: "mode.yolo", desc: "mode.yolo_desc" },
  { id: "ask", label: "mode.ask", desc: "mode.ask_desc" },
  { id: "read-only", label: "mode.read_only", desc: "mode.read_only_desc" },
];

/** plan 是 read-only 的别名,统一折叠到 read-only 展示 */
function effectiveMode(): AppMode {
  return mode() === "plan" ? "read-only" : mode();
}

function modeIcon(id: AppMode, extra = ""): SVGElement {
  const cls = extra ? `${extra} mode-icon-${id}` : `mode-icon-${id}`;
  if (id === "yolo") return iconBolt(12, cls);
  if (id === "ask") return iconQuestion(12, cls);
  return iconShield(12, cls);
}

function renderComposerModeDropdown(): HTMLElement {
  return tags.div(
    { class: "composer-mode-wrap" },
    tags.button(
      {
        class: "composer-dd-trigger",
        title: () => t("composer.mode_select_title"),
        onclick: (e: MouseEvent) => {
          e.stopPropagation();
          modelMenuOpen.set(false);
          modeMenuOpen.set(!modeMenuOpen());
        },
      },
      () => modeIcon(effectiveMode(), "composer-mode-icon"),
      tags.span({ class: "composer-dd-label" }, () => {
        const cur = effectiveMode();
        if (cur === "yolo") return t("mode.yolo");
        if (cur === "ask") return t("mode.ask");
        return t("mode.read_only");
      }),
      iconChevronDown(10, "composer-dd-caret")
    ),
    () => {
      if (!modeMenuOpen()) return null;
      return tags.div(
        {
          class: "popup-menu composer-dd-menu composer-mode-menu",
          onclick: (e: MouseEvent) => e.stopPropagation(),
        },
        MODE_OPTIONS.map((m) =>
          tags.div(
            {
              class: () => `menu-item ${effectiveMode() === m.id ? "is-selected" : ""}`,
              onclick: () => {
                switchMode(m.id);
                modeMenuOpen.set(false);
              },
            },
            tags.span({ class: "menu-icon" }, modeIcon(m.id)),
            tags.span({ class: "menu-cmd" }, () => t(m.label)),
            tags.span({ class: "menu-desc" }, () => t(m.desc))
          )
        )
      );
    }
  );
}
