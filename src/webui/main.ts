// main.ts —— WebUI Next 根入口总装
import { tags, h } from "./dom";
import { renderTopBar } from "./topbar";
import { renderSidebar } from "./sidebar";
import { renderChatStream } from "./chat";
import { renderComposer } from "./composer";
import { renderDeck } from "./deck";
import { renderSplitter, deckWidth } from "./splitter";
import { renderModals } from "./modal";
import {
  boot,
  deckOpen,
  sidebarOpen,
  toggleSidebar,
  toggleDeck,
  setDeckTab,
  showSearchModal,
  showShortcutsModal,
  showSettingsModal,
  showAddWorkspaceModal,
  showArtifactModal,
  isStreaming,
  interrupt,
  regenerateLastTurn,
  turns,
  showToast,
} from "./store";

function createApp(): HTMLElement {
  const root = tags.div({ class: "app-root" });

  // 1. 左侧边栏 (顶格贯穿 100vh)
  const sidebar = renderSidebar();

  // 2. 主体工作区容器 (Chat Area + Splitter + Deck)
  const mainWorkspace = tags.div(
    { class: "main-layout main-workspace" },
    // 中央会话流与输入台
    tags.main(
      { class: "chat-workspace chat-main-column" },
      renderChatStream(),
      renderComposer()
    ),

    // 双栏调节中缝
    renderSplitter(),

    // 右侧工作台检视 Deck
    renderDeck()
  );

  // 动态同步 Deck 宽度样式
  deckWidth.subscribe((w) => {
    if (deckOpen()) {
      mainWorkspace.style.setProperty("--deck-width", `${w}px`);
    }
  });

  // 3. 右侧主体容器 (顶栏 + 主工作区)
  const appMain = tags.div(
    { class: "app-main" },
    renderTopBar(),
    mainWorkspace
  );

  root.appendChild(sidebar);
  root.appendChild(appMain);

  // 4. 模态层
  root.appendChild(renderModals());

  return root;
}

// 键盘快捷键
function setupKeybindings() {
  window.addEventListener("keydown", (e: KeyboardEvent) => {
    const isMeta = e.metaKey || e.ctrlKey;

    if (isMeta && e.key === "k") {
      e.preventDefault();
      showSearchModal.update((v) => !v);
    } else if (isMeta && e.key === "b") {
      e.preventDefault();
      toggleSidebar();
    } else if (isMeta && e.key === "j") {
      e.preventDefault();
      toggleDeck();
    } else if (isMeta && e.shiftKey && (e.key === "D" || e.key === "d")) {
      e.preventDefault();
      setDeckTab("diffs");
    } else if (isMeta && e.shiftKey && (e.key === "T" || e.key === "t")) {
      e.preventDefault();
      setDeckTab("terminal");
    } else if (isMeta && e.shiftKey && (e.key === "R" || e.key === "r")) {
      e.preventDefault();
      regenerateLastTurn();
    } else if (isMeta && e.shiftKey && (e.key === "C" || e.key === "c")) {
      e.preventDefault();
      const list = turns();
      for (let i = list.length - 1; i >= 0; i--) {
        if (list[i].role === "assistant" && list[i].content) {
          navigator.clipboard.writeText(list[i].content);
          showToast("Copied last assistant response", "info");
          break;
        }
      }
    } else if (e.key === "?" && !["INPUT", "TEXTAREA"].includes((e.target as HTMLElement)?.tagName)) {
      e.preventDefault();
      showShortcutsModal.update((v) => !v);
    } else if (e.key === "Escape") {
      if (showSearchModal()) {
        showSearchModal.set(false);
      } else if (showShortcutsModal()) {
        showShortcutsModal.set(false);
      } else if (showSettingsModal()) {
        showSettingsModal.set(false);
      } else if (showAddWorkspaceModal()) {
        showAddWorkspaceModal.set(false);
      } else if (showArtifactModal()) {
        showArtifactModal.set(false);
      } else if (isStreaming()) {
        interrupt();
      }
    }
  });
}

// 启动挂载
function mount() {
  const mountPoint = document.getElementById("app") || document.body;
  mountPoint.innerHTML = "";
  mountPoint.appendChild(createApp());

  setupKeybindings();
  boot();
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", mount);
} else {
  mount();
}
