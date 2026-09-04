      "use strict";
      import { sess, ws, wsp } from "./state";
      import { $ } from "./util";
      import { initServerAuth, showAuthPage, getCredential, rawFetch, setOnAuthed } from "./net";
      import { showToast } from "./ui";
      import { restoreDraft } from "./store";
      import { openWsMenu, renderWsName, loadSessions, initSideFilter, initSideGrip } from "./sessions";
      import { connectSSE } from "./stream";
      import { loadHelpCatalog } from "./slash";
      import { th, setHistRange, paintHistMore, replayHist, inspect, resumeAsst } from "./chat";
      import { setRun } from "./composer";
      import { applyBootState, setModeBtn, setSandboxBtn, applySandboxLevel, setCost, setCtx } from "./model";
      import { openSearch } from "./settings";
      import { loadPlugins } from "./plugins";
      import { setupJobs } from "./jobs";
      import { initEvolve } from "./evolve";
      import { applyI18n, t } from "./i18n";
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
        applyI18n();
        inspect.init();
        const isWarm = !!sessionStorage.getItem("piz.booted");
        try { sessionStorage.setItem("piz.booted", "1"); } catch {}
        const wait = isWarm ? 0 : Math.max(0, 450 - (Date.now() - splashAt));
        if (wait === 0) {
          $("splash")?.remove();
        } else {
          setTimeout(() => {
            $("splash")?.classList.add("hide");
            setTimeout(() => $("splash")?.remove(), 350);
          }, wait);
        }
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
        .catch(() => showToast(t("statusLoadFail", "Failed to load state")));
      setModeBtn();
      setSandboxBtn();
      fetch("/api/config")
        .then((r) => r.json())
        .then((cfg) => {
          if (cfg && cfg.sandboxMode) applySandboxLevel(cfg.sandboxMode);
          if (cfg && cfg.sandboxBackend) window.sandboxBackend = cfg.sandboxBackend;
          setSandboxBtn();
        })
        .catch(() => showToast(t("configLoadFail", "Failed to load config")));
      loadHelpCatalog();
      // todo 计划条插槽(dsh input dock 计划条):actStrip 之后、队列行之前
      const ps = document.createElement("div");
      ps.id = "planStrip";
      ps.className = "plan-strip";
      ps.hidden = true;
      $("actStrip")?.insertAdjacentElement("afterend", ps);
      const welcome = document.createElement("div");
      welcome.id = "welcome";
      welcome.className = "empty-hint";
      welcome.innerHTML =
        '<div class="hero-card">' +
        '<div class="empty-headline">' +
        '<svg class="empty-logo" viewBox="0 0 24 18" fill="currentColor" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><path d="M2.4 1.8h17.2a1.7 1.7 0 0 1 0 3.4H10l10 8.2A1.8 1.8 0 0 1 18.65 16.45H3.2a1.7 1.7 0 0 1 0-3.4h9.4L2.7 4.9A1.8 1.8 0 0 1 4.1 1.8z"/></svg>' +
        '<span class="empty-hint-title">piz</span></div>' +
        '<button type="button" class="ws-chip" id="heroWs"><span class="ws-chip-ic">⌂</span><span id="heroWsLbl" data-i18n="workspace">' + t("workspace", "Workspace") + '</span><span class="ws-chip-chev">▾</span></button>' +
        '<button type="button" class="hero-start" id="heroStart" data-i18n="startSession">' + t("startSession", "＋ Start session") + '</button>' +
        '<div class="hero-sugs">' +
        '<button type="button" class="hero-sug" data-i18n="sugWhatProject">' + t("sugWhatProject", "What does this project do?") + '</button>' +
        '<button type="button" class="hero-sug" data-i18n="sugRunTests">' + t("sugRunTests", "Run tests for me") + '</button>' +
        '<button type="button" class="hero-sug" data-i18n="sugRecentChanges">' + t("sugRecentChanges", "What changed recently?") + '</button>' +
        '</div>' +
        '<div class="empty-hint-text" data-i18n="heroHint">' + t("heroHint", "Read, edit, run. Full control.") + '</div>' +
        '<div class="empty-keys"><span><kbd>/</kbd> <span data-i18n="keyCommands">' + t("keyCommands", "Commands") + '</span></span><span><kbd>j</kbd> <span data-i18n="keyJobs">' + t("keyJobs", "Jobs") + '</span></span><span><kbd>u</kbd> <span data-i18n="keyUsage">' + t("keyUsage", "Usage") + '</span></span><span><kbd>s</kbd> <span data-i18n="keySandbox">' + t("keySandbox", "Sandbox") + '</span></span><span><kbd>?</kbd> <span data-i18n="keyShortcuts">' + t("keyShortcuts", "Shortcuts") + '</span></span></div>' +
        '</div>';
      const wrap = $("wrap");
      if (!th.children.length) {
        wrap.prepend(welcome);
        $("app").classList.add("hero");
        $("heroWs").onclick = (e) => {
          e.stopPropagation();
          openWsMenu(e.currentTarget);
        };
        $("heroStart").onclick = () => $("newBtn").click();
        welcome.querySelectorAll(".hero-sug").forEach((b) => {
          (b as HTMLElement).onclick = () => {
            const inp = $("inp") as HTMLTextAreaElement | null;
            if (!inp) return;
            inp.value = (b as HTMLElement).textContent || "";
            inp.dispatchEvent(new Event("input"));
            inp.focus();
          };
        });
      }
      initSideFilter();
      initSideGrip();
      renderWsName();
      loadSessions();
      loadPlugins();
      setupJobs();
      restoreDraft();
      // 全生命周期错误采集:页面加载即挂 window error/unhandledrejection/console.error
      initEvolve();
      }
      $("searchBtn").onclick = () => openSearch();
      setOnAuthed(boot);
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
          $("authErr").textContent = t("cantConnect", "Cannot connect to local server. Please ensure piz web is running.");
          showAuthPage(t("cantConnect", "Cannot connect to local server. Please ensure piz web is running."));
        });
