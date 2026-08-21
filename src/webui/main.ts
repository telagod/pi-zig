      "use strict";
      import { sess, ws, wsp } from "./state";
      import { $ } from "./util";
      import { initServerAuth, showAuthPage, getCredential, rawFetch, setOnAuthed } from "./net";
      import { showToast, dlgHooks, clipText } from "./ui";
      import { restoreDraft } from "./store";
      import { closeMenus, openWsMenu, renderWsName, loadSessions, sessHooks } from "./sessions";
      import { connectSSE } from "./stream";
      import { slashH, loadHelpCatalog, hideSlash, hideBang, runSlash } from "./slash";
      import { chatH, th, setHistRange, getWebFindQ, paintHistMore, replayHist, findInThread, addUser, asstEl, addAsst, finishAsst, inspect, resumeAsst } from "./chat";
      import { getRunning, getLastUser, setLastUser, clearPending, setRun, refreshSend, ensureActPoll, renderQueue, attachClipboardImage, sendPlain, send } from "./composer";
      import { applyBootState, setModeBtn, setSandboxBtn, applySandboxLevel, setApprovalMode, setCost, setCtx, modelH } from "./model";
      import { openSearch } from "./settings";
      import { closeSheet } from "./sheet";
      import { loadPlugins, pluginsH } from "./plugins";
      // 侧栏折叠态(piz.sidebar=1 则预合)
      try {
        if (localStorage.getItem("piz.sidebar") === "1")
          document.body.classList.add("collapsed");
      } catch {}
      // ---- 启动门(kimi GlobalLoading + auth gate):splash → 探活 → 登录页或主界面 ----
      let booted = false;
      let splashAt = Date.now();
      function boot() {
        if (booted) return;
        booted = true;
        inspect.init();
        const wait = Math.max(0, 450 - (Date.now() - splashAt));
        setTimeout(() => {
          $("splash")?.classList.add("hide");
          setTimeout(() => $("splash")?.remove(), 350);
        }, wait);
        connectSSE();
        fetch("/api/state?" + wsp + "session=" + encodeURIComponent(sess))
        .then((r) => r.json())
        .then((s) => {
          setHistRange(s.hist_start || 0, s.hist_total || (s.history ? s.history.length : 0));
          if (s.history && s.history.length) {
            replayHist(s.history, false);
            if (s.running) resumeAsst();
          } else paintHistMore();
          if (s.cost !== undefined) setCost(s.cost);
          if (s.pct !== undefined || s.used !== undefined) setCtx(s.pct, s.used, s.window);
          if (s.running) setRun(true);
          applyBootState(s);
        })
        .catch(() => showToast("state load failed"));
      setModeBtn();
      setSandboxBtn();
      fetch("/api/config")
        .then((r) => r.json())
        .then((cfg) => {
          if (cfg && cfg.sandboxMode) applySandboxLevel(cfg.sandboxMode);
          if (cfg && cfg.sandboxBackend) window.sandboxBackend = cfg.sandboxBackend;
          setSandboxBtn();
        })
        .catch(() => showToast("config load failed"));
      loadHelpCatalog();
      const welcome = document.createElement("div");
      welcome.id = "welcome";
      welcome.className = "empty-hint";
      welcome.innerHTML =
        '<div class="empty-headline">' +
        '<svg class="empty-logo" viewBox="0 0 24 18" fill="currentColor" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><path d="M2.4 1.8h17.2a1.7 1.7 0 0 1 0 3.4H10l10 8.2A1.8 1.8 0 0 1 18.65 16.45H3.2a1.7 1.7 0 0 1 0-3.4h9.4L2.7 4.9A1.8 1.8 0 0 1 4.1 1.8z"/></svg>' +
        '<span class="empty-hint-title">piz</span></div>' +
        '<button type="button" class="ws-chip" id="heroWs"><span class="ws-chip-ic">⌂</span><span id="heroWsLbl">项目</span><span class="ws-chip-chev">▾</span></button>' +
        '<div class="empty-hint-text">读、改、跑。工具默认先问你。</div>' +
        '<div class="empty-keys"><span><kbd>/</kbd> 命令</span><span><kbd>j</kbd> 任务</span><span><kbd>u</kbd> 用量</span><span><kbd>s</kbd> 沙箱</span><span><kbd>?</kbd> 快捷键</span></div>';
      const wrap = $("wrap");
      if (!th.children.length) {
        wrap.prepend(welcome);
        $("app").classList.add("hero");
        $("heroWs").onclick = (e) => {
          e.stopPropagation();
          openWsMenu(e.currentTarget);
        };
      }
      renderWsName();
      loadSessions();
      loadPlugins();
      restoreDraft();
      }
      // ui/net 解缠钩:对话框开场收菜单/补全;登录成功续 boot
      $("searchBtn").onclick = () => openSearch();
      dlgHooks.closeMenus = closeMenus;
      dlgHooks.hideSlash = hideSlash;
      dlgHooks.hideBang = hideBang;
      setOnAuthed(boot);
      // sessions 解缠钩:点当前会话行 → 应其 mode/auto 并收 sheet
      sessHooks.applySessionMeta = (s) => {
        if (s.mode || s.auto !== undefined) {
          setApprovalMode(s.mode || (s.auto ? "yolo" : "ask"));
        }
        closeSheet();
      };
      // slash 解缠钩:聊天渲染/发送经箭函迟取;模型态已直引 model.ts
      modelH.runSlash = runSlash;
      Object.assign(slashH, {
        addUser, addAsst, finishAsst, openSearch,
        attachClipboardImage, refreshSend, ensureActPoll,
        asstEl, findInThread, sendPlain, send,
        renderQueue, clipText,
        getWebFindQ,
        getLastUser,
        clearPending,
      });
      // chat 解缠钩:发送与 lastUser 以箭函迟取(余者已直引 sheet/plugins/model)
      Object.assign(chatH, {
        sendPlain,
        getLastUser, setLastUser,
      });
      // plugins 解缠钩:api.send 之运行态/发送迟取(避 plugins↔composer 环)
      Object.assign(pluginsH, { getRunning, sendPlain });
      initServerAuth();
      const probe = rawFetch("/api/state?" + wsp + "session=" + encodeURIComponent(sess), {
        headers: getCredential() ? { Authorization: "Bearer " + getCredential() } : {},
      });
      probe
        .then((r) => {
          if (r.ok) boot();
          else if (r.status === 401) showAuthPage("");
          else if (r.status === 403 && ws) {
            const u = new URL(location.href);
            u.searchParams.delete("ws");
            location.replace(u.pathname + u.search + u.hash);
          } else {
            setTimeout(() => location.reload(), 1500);
          }
        })
        .catch(() => {
          $("authErr").textContent = "无法连接本地服务器";
          showAuthPage("无法连接本地服务器,请确认 piz web 已启动");
        });
