      "use strict";
      import { qp, sess, ws, wsp, isMobile, prefs, savePrefs, sessUrl } from "./state";
      import { $, esc, histText, projectName, fmtTime, fmtTok, closeFences, nunit, downloadText, toolType, parseToolArgs, argsPreview, toolIcon, artifactName, workKind, ico, icoKind, slashStem, startsWithInsens, indexOfInsens, fuzzySubseq, rankSlash, hlSpan, isMarkdownPath, looksLikeMd } from "./util";
      import { md, ansiHtml, mdInline, mdBlocks, renderMd, diffHtml, todoHtml } from "./md";
      import { segHtml, authPanelHtml, packageRows, pluginRows } from "./render";
      import { initServerAuth, showAuthPage, hideAuthPage, setCredential, clearCredential, getCredential, rawFetch, setOnAuthed } from "./net";
      import { showToast, closeDlg, openDlg, askText, askYes, dlgHooks, clipText, setScheme } from "./ui";
      import { autosizeInp, saveDraft, restoreDraft, clearDraft, pushHist, histPrev, histNext } from "./store";
      import { closeMenus, openAt, loadWorkspaces, renderWsName, addProject, openWsMenu, sessionRow, openSessionMenu, loadSessions, act, sessData, sessHooks } from "./sessions";
      import { ev, connectSSE } from "./stream";
      import { slashH, loadHelpCatalog, hideSlash, hideBang, slashOpen, updateSlash, updateComposerChrome, slashMove, slashComplete, slashPick, runSlash, findSlash } from "./slash";
      import { chatH, th, scrl, setHistRange, getWebFindQ, paintHistMore, replayHist, loadOlder, findInThread, noteTurn, stampTurn, finishWork, addUser, asstEl, addAsst, finishAsst, addRsn, finishRsn, addTool, fillTool, toolDone, addPerm, addNotice, inspect, resumeAsst } from "./chat";
      import { compH, getRunning, getLastUser, setLastUser, clearPending, setRun, refreshSend, ensureActPoll, renderQueue, dropPending, toggleKeysHint, attachClipboardImage, sendPlain, send } from "./composer";
      import { applyBootState, setModeBtn, setSandboxBtn, applySandboxLevel, setApprovalMode, setCost, setCtx, modelH } from "./model";
      import { openSettings, openSearch } from "./settings";
      import { closeSheet } from "./sheet";
      import { loadPlugins, pluginsH } from "./plugins";
      // ---- 外观方案已迁 ui.ts(setScheme/applyScheme) ----
      try {
        if (localStorage.getItem("piz.sidebar") === "1")
          document.body.classList.add("collapsed");
      } catch {}
      // ---- 服务器凭证与 fetch 包装已迁 net.ts;toast/对话框迁 ui.ts ----
      // ---- 设置/搜索/全局键已迁 settings.ts ----
      // ---- 菜单助手 ----
      // ---- 菜单助手/项目/会话列已迁 sessions.ts ----
      $("searchBtn").onclick = () => openSearch();
      // ---- 模型/思考/授权/沙箱/cost/ctx/hdr 已迁 model.ts ----
      // ---- 渲染核心已迁 chat.ts ----

      // ---- SSE 已迁 stream.ts(ev.onmessage 于下方指派) ----
      // ---- 发送态/SSE 路由/键盘/图片/send 已迁 composer.ts ----
      // ---- 斜杠目录/菜单/runSlash 已迁 slash.ts ----
      // ---- runSlash 已迁 slash.ts ----
      // ---- sheet/顶栏钮/welcome 已迁 sheet.ts;插件 SDK 已迁 plugins.ts ----
      // ---- 初始化 ----
      // curModel/curThink/curTitle/curVision 已迁 model.ts
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
