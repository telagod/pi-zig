      "use strict";
      import { qp, sess, ws, wsp, isMobile, prefs, savePrefs, sessUrl } from "./state";
      import { $, esc, histText, projectName, fmtTime, fmtTok, closeFences, nunit, downloadText, toolType, parseToolArgs, argsPreview, toolIcon, artifactName, workKind, ico, icoKind, slashStem, startsWithInsens, indexOfInsens, fuzzySubseq, rankSlash, hlSpan, isMarkdownPath, looksLikeMd } from "./util";
      import { md, ansiHtml, mdInline, mdBlocks, renderMd, diffHtml, todoHtml } from "./md";
      import { segHtml, authPanelHtml, packageRows, pluginRows } from "./render";
      import { initServerAuth, showAuthPage, hideAuthPage, setCredential, clearCredential, getCredential, rawFetch, setOnAuthed } from "./net";
      import { showToast, closeDlg, openDlg, askText, askYes, bindSeg, bindAuthPanel, dlgHooks, clipText } from "./ui";
      import { autosizeInp, saveDraft, restoreDraft, clearDraft, pushHist, histPrev, histNext } from "./store";
      import { closeMenus, openAt, loadWorkspaces, renderWsName, addProject, openWsMenu, sessionRow, openSessionMenu, loadSessions, act, sessData, sessHooks } from "./sessions";
      import { ev, connectSSE } from "./stream";
      import { slashH, loadHelpCatalog, hideSlash, hideBang, slashOpen, updateSlash, updateComposerChrome, slashMove, slashComplete, slashPick, runSlash, findSlash } from "./slash";
      import { chatH, th, scrl, setHistRange, getWebFindQ, paintHistMore, replayHist, loadOlder, findInThread, noteTurn, stampTurn, finishWork, addUser, asstEl, addAsst, finishAsst, addRsn, finishRsn, addTool, fillTool, toolDone, addPerm, addNotice, inspect } from "./chat";
      function setScheme(v) {
        const map = { auto: "system", light: "light", dark: "dark", system: "system" };
        const next = map[String(v || "").trim()];
        if (!next) return false;
        prefs.scheme = next;
        savePrefs();
        applyScheme();
        return true;
      }
      function applyScheme() {
        const root = document.documentElement;
        root.dataset.colorScheme = prefs.scheme || "dark";
        root.dataset.accent = prefs.accent || "mono";
        root.dataset.density = prefs.density || "cozy";
        root.dataset.wide = prefs.wide ? "1" : "";
        const fs = (prefs.uiFont || 14) + "px";
        root.style.setProperty("--ui-font-size", fs);
        root.style.setProperty("--text-base", fs);
        const dark =
          prefs.scheme === "dark" ||
          (prefs.scheme === "system" &&
            window.matchMedia &&
            window.matchMedia("(prefers-color-scheme: dark)").matches);
        const tm = document.querySelector('meta[name="theme-color"]');
        if (tm) tm.setAttribute("content", dark ? "#151517" : "#ffffff");
      }
      applyScheme();
      if (window.matchMedia) {
        try {
          matchMedia("(prefers-color-scheme: dark)").addEventListener(
            "change",
            applyScheme,
          );
        } catch {}
      }
      try {
        if (localStorage.getItem("piz.sidebar") === "1")
          document.body.classList.add("collapsed");
      } catch {}
      // ---- 服务器凭证与 fetch 包装已迁 net.ts;toast/对话框迁 ui.ts ----
      async function openSettings() {
        let cfg = {};
        let models = [];
        let pkgs = { user: [], project: [] };
        try {
          const [cr, mr, pr] = await Promise.all([
            fetch("/api/config"),
            fetch("/api/models"),
            fetch("/api/packages?" + wsp),
          ]);
          cfg = await cr.json();
          models = await mr.json();
          if (!Array.isArray(models)) models = [];
          pkgs = await pr.json();
        } catch {}
        const defThink = cfg.defaultThinkingLevel || curThink || "high";
        const defAppr = cfg.approvalMode || "yolo";
        const defModel = cfg.defaultModel || "";
        const thinkOpts = (typeof THINK_LEVELS !== "undefined" ? THINK_LEVELS : ["off", "low", "medium", "high"]).map(
          (v) => ({ v, l: v }),
        );
        const apprOpts = (typeof APPROVALS !== "undefined" ? APPROVALS : []).map((x) => ({ v: x.id, l: x.label }));
        function optHtml(id, cur, list) {
          const xs = list.slice();
          if (cur && xs.indexOf(cur) < 0) xs.unshift(cur);
          if (!xs.length) xs.push(cur || "");
          return (
            '<select id="' +
            id +
            '" class="set-sel">' +
            xs
              .map(
                (m) =>
                  '<option value="' +
                  esc(m) +
                  '"' +
                  (m === cur ? " selected" : "") +
                  ">" +
                  esc(m) +
                  "</option>",
              )
              .join("") +
            "</select>"
          );
        }
        const provHtml =
          (cfg.providers || [])
            .map(
              (p) =>
                '<div class="set-row"><div class="set-lab">' +
                esc(p.name || "") +
                '<span class="set-hint">' +
                esc(p.api || "") +
                (p.hasKey ? " · 已配 key" : " · 无 key") +
                "</span></div></div>",
            )
            .join("") ||
          '<div class="set-row"><div class="set-lab">无自定义 provider<span class="set-hint">见 ~/.piz/models.json</span></div></div>';
        openDlg({
          cls: "set",
          title: "设置",
          body:
            '<div class="set-tabs" id="setTabs"><button type="button" data-tab="auth" class="on">Account</button><button type="button" data-tab="look">外观</button><button type="button" data-tab="agent">智能体</button><button type="button" data-tab="note">通知</button><button type="button" data-tab="about">关于</button></div>' +
            '<div id="setAuth">' +
            authPanelHtml(cfg) +
            "</div>" +
            '<div id="setLook" hidden>' +
            '<div class="set-row"><div class="set-lab">配色</div>' +
            segHtml("scheme", [{ v: "light", l: "浅色" }, { v: "dark", l: "深色" }, { v: "system", l: "系统" }], prefs.scheme) +
            "</div>" +
            '<div class="set-row"><div class="set-lab">强调色</div>' +
            segHtml("accent", [{ v: "mono", l: "墨" }, { v: "blue", l: "蓝" }, { v: "green", l: "苔" }, { v: "amber", l: "赭" }], prefs.accent) +
            "</div>" +
            '<div class="set-row"><div class="set-lab">密度</div>' +
            segHtml("density", [{ v: "cozy", l: "舒适" }, { v: "compact", l: "紧凑" }], prefs.density || "cozy") +
            "</div>" +
            '<div class="set-row"><div class="set-lab">宽屏<span class="set-hint">内容列加宽</span></div>' +
            segHtml("wide", [{ v: "0", l: "窄" }, { v: "1", l: "宽" }], prefs.wide ? "1" : "0") +
            "</div>" +
            '<div class="set-row"><div class="set-lab">界面字号</div><input id="setFont" class="num-in" type="number" min="12" max="20" value="' +
            (prefs.uiFont || 14) +
            '"></div></div>' +
            '<div id="setAgent" hidden>' +
            '<div class="set-row"><div class="set-lab">本会话模型</div>' +
            optHtml("setSessModel", curModel, models) +
            "</div>" +
            '<div class="set-row"><div class="set-lab">思考等级<span class="set-hint">写入默认并作用于当前会话</span></div>' +
            segHtml("think", thinkOpts, defThink) +
            "</div>" +
            '<div class="set-row"><div class="set-lab">本会话授权</div>' +
            segHtml("sessappr", apprOpts.length ? apprOpts : [{ v: "yolo", l: "yolo" }, { v: "ask", l: "ask" }, { v: "read-only", l: "read-only" }], approvalMode) +
            "</div>" +
            '<div class="set-row"><div class="set-lab">新会话默认授权</div>' +
            segHtml("defappr", apprOpts.length ? apprOpts : [{ v: "yolo", l: "yolo" }, { v: "ask", l: "ask" }, { v: "read-only", l: "read-only" }], defAppr) +
            "</div>" +
            '<div class="set-row"><div class="set-lab">bash 沙箱<span class="set-hint">workspace 工作区可写；strict 再断网</span></div>' +
            segHtml("sandbox", [{ v: "off", l: "off" }, { v: "workspace", l: "workspace" }, { v: "strict", l: "strict" }], cfg.sandboxMode || "off") +
            "</div>" +
            '<div class="set-row"><div class="set-lab">默认模型<span class="set-hint">新会话用</span></div>' +
            optHtml("setDefModel", defModel || curModel, models) +
            "</div>" +
            pluginRows(cfg.plugins) +
            packageRows(pkgs) +
            "</div>" +
            '<div id="setNote" hidden>' +
            '<div class="set-row"><div class="set-lab">完成时通知<span class="set-hint">浏览器系统通知</span></div><button type="button" class="sw' +
            (prefs.notify ? " on" : "") +
            '" id="swNotify"></button></div>' +
            '<div class="set-row"><div class="set-lab">完成时提示音</div><button type="button" class="sw' +
            (prefs.sound ? " on" : "") +
            '" id="swSound"></button></div></div>' +
            '<div id="setAbout" hidden>' +
            '<div class="set-row"><div class="set-lab">piz web<span class="set-hint">配置见 ~/.piz/</span></div></div>' +
            '<div class="set-row"><div class="set-lab">快捷键<span class="set-hint"><kbd>Ctrl</kbd><kbd>K</kbd> 搜会话 · <kbd>Ctrl</kbd><kbd>,</kbd> 设置 · <kbd>/</kbd> 命令 · <kbd>@./</kbd> 文件 · <kbd>!</kbd> 命令</span></div></div>' +
            provHtml +
            "</div>",
        });
        const tabs = $("setTabs");
        const panels = { auth: $("setAuth"), look: $("setLook"), agent: $("setAgent"), note: $("setNote"), about: $("setAbout") };
        bindAuthPanel();
        tabs.onclick = (e) => {
          const b = e.target.closest("button");
          if (!b) return;
          for (const x of tabs.querySelectorAll("button")) x.classList.toggle("on", x === b);
          for (const k of Object.keys(panels)) panels[k].hidden = k !== b.dataset.tab;
        };
        bindSeg("scheme", (v) => {
          setScheme(v);
        });
        bindSeg("accent", (v) => {
          prefs.accent = v;
          prefs.accentPicked = true;
          savePrefs();
          applyScheme();
        });
        $("setFont").onchange = () => {
          prefs.uiFont = Math.min(20, Math.max(12, +$("setFont").value || 14));
          savePrefs();
          applyScheme();
        };
        bindSeg("density", (v) => {
          prefs.density = v || "cozy";
          savePrefs();
          applyScheme();
        });
        bindSeg("wide", (v) => {
          prefs.wide = v === "1";
          savePrefs();
          applyScheme();
        });
        if ($("setSessModel"))
          $("setSessModel").onchange = async () => {
            await applySessionModel($("setSessModel").value);
          };
        if ($("setDefModel"))
          $("setDefModel").onchange = () => {
            fetch("/api/config", {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ setDefaultModel: $("setDefModel").value }),
            })
              .then((r) => r.json().catch(() => ({})))
              .then((j) => {
                if (j && j.ok === false) showToast(j.error || "save default model failed");
              })
              .catch(() => showToast("save default model failed"));
          };
        bindSeg("think", (v) => setThink(v));
        bindSeg("sessappr", (v) => setApproval(v));
        bindSeg("defappr", (v) => {
          fetch("/api/config", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ setApprovalMode: v }),
          })
            .then((r) => r.json().catch(() => ({})))
            .then((j) => {
              if (j && j.ok === false) showToast(j.error || "save approval failed");
            })
            .catch(() => showToast("save approval failed"));
        });
        bindSeg("sandbox", (v) => {
          setSandbox(v);
        });
        document.querySelectorAll("[data-plugin]").forEach((btn) => {
          btn.onclick = async () => {
            const name = btn.getAttribute("data-plugin");
            const on = !btn.classList.contains("on");
            btn.classList.toggle("on", on);
            try {
              await fetch("/api/config", {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({ setPlugin: { name, enabled: on } }),
              });
            } catch {
              btn.classList.toggle("on", !on);
            }
          };
        });
        $("swNotify").onclick = async () => {
          if (!prefs.notify && window.Notification && Notification.permission === "default") {
            try {
              await Notification.requestPermission();
            } catch {}
          }
          prefs.notify = !prefs.notify;
          $("swNotify").classList.toggle("on", prefs.notify);
          savePrefs();
        };
        $("swSound").onclick = () => {
          prefs.sound = !prefs.sound;
          $("swSound").classList.toggle("on", prefs.sound);
          savePrefs();
        };
      }
      function openSearch() {
        const hits = sessData.list.slice();
        let sel = 0;
        openDlg({
          cls: "wide",
          title: "搜索会话",
          body:
            '<input id="dlgIn" class="dlg-in" placeholder="按标题或名字过滤…">' +
            '<div id="hitList" style="margin-top:8px;max-height:50vh;overflow:auto"></div>',
          focus: "dlgIn",
        });
        const box = $("hitList");
        const inp = $("dlgIn");
        function paint() {
          const q = (inp.value || "").toLowerCase().trim();
          const shown = [];
          for (const s of hits) {
            const title = s.title || s.name || "";
            const name = s.name || "";
            if (q && !title.toLowerCase().includes(q) && !name.toLowerCase().includes(q))
              continue;
            shown.push(s);
            if (shown.length >= 80) break;
          }
          if (sel >= shown.length) sel = Math.max(0, shown.length - 1);
          box.innerHTML = shown.length
            ? shown
                .map(
                  (s, i) =>
                    '<div class="hit' +
                    (i === sel ? " on" : "") +
                    '" data-name="' +
                    esc(s.name) +
                    '"><div class="hit-t">' +
                    esc(s.title || s.name) +
                    '</div><div class="hit-s">' +
                    esc(s.name) +
                    (s.msgs ? " · " + s.msgs + " 条" : "") +
                    "</div></div>",
                )
                .join("")
            : '<div class="dlg-msg">无匹配会话</div>';
          const on = box.querySelector(".hit.on");
          if (on) on.scrollIntoView({ block: "nearest" });
          return shown;
        }
        function go(name) {
          if (!name) return;
          closeDlg();
          location.href =
            "/?session=" +
            encodeURIComponent(name) +
            (ws ? "&ws=" + encodeURIComponent(ws) : "");
        }
        inp.addEventListener("input", () => {
          sel = 0;
          paint();
        });
        inp.addEventListener("keydown", (e) => {
          const shown = paint();
          if (e.key === "ArrowDown") {
            e.preventDefault();
            sel = Math.min(shown.length - 1, sel + 1);
            paint();
          } else if (e.key === "ArrowUp") {
            e.preventDefault();
            sel = Math.max(0, sel - 1);
            paint();
          } else if (e.key === "Enter") {
            e.preventDefault();
            if (shown[sel]) go(shown[sel].name);
          }
        });
        box.onclick = (e) => {
          const h = e.target.closest(".hit");
          if (h) go(h.getAttribute("data-name"));
        };
        paint();
      }
      document.addEventListener("keydown", (e) => {
        if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
          e.preventDefault();
          openSearch();
          return;
        }
        if ((e.metaKey || e.ctrlKey) && e.key === ",") {
          e.preventDefault();
          openSettings();
          return;
        }
        if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key.toLowerCase() === "c") {
          e.preventDefault();
          const md = th.querySelector(".a-turn:last-of-type .md");
          clipText(md && (md.dataset.raw || md.textContent), "已复制最后回复", "还没有回复");
          return;
        }
        if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key.toLowerCase() === "r") {
          e.preventDefault();
          if (lastUser) sendPlain(lastUser);
          else showToast("没有可重发的输入");
          return;
        }
        // 输入框外按 "/":聚焦输入框并直接进斜杠菜单。
        if (
          e.key === "/" &&
          !e.metaKey &&
          !e.ctrlKey &&
          !e.altKey &&
          !e.isComposing
        ) {
          const ae = document.activeElement;
          const editable =
            ae &&
            (ae.tagName === "INPUT" ||
              ae.tagName === "TEXTAREA" ||
              ae.isContentEditable);
          if (!editable && !$("overlay").classList.contains("open")) {
            e.preventDefault();
            const inp = $("inp");
            inp.focus();
            if (!inp.value) {
              inp.value = "/";
              inp.dispatchEvent(new Event("input"));
            }
            return;
          }
        }
        if (e.key === "Escape") {
          const kh = $("keysHint");
          if (kh && !kh.hidden) {
            kh.hidden = true;
            kh.innerHTML = "";
            return;
          }
          if ($("overlay").classList.contains("open")) {
            e.preventDefault();
            if (dlgOncancel) dlgOncancel();
            closeDlg();
            return;
          }
          const sm = $("slashMenu");
          if (sm && !sm.hidden) {
            sm.hidden = true;
            return;
          }
          if ($("inspect") && !$("inspect").hidden) {
            e.preventDefault();
            inspect.close();
          }
        }
      });
      // ---- 菜单助手 ----
      // ---- 菜单助手/项目/会话列已迁 sessions.ts ----
      $("searchBtn").onclick = () => openSearch();
      // ---- 模型 ----
      async function applySessionModel(md) {
        try {
          const r = await fetch(
            "/api/model?" + wsp + "session=" + encodeURIComponent(sess),
            {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ model: md }),
            },
          );
          const j = await r.json().catch(() => ({}));
          if (!r.ok || j.ok === false || !j.model) {
            showToast(j.error || "switch model failed");
            return false;
          }
          curModel = j.model;
          renderModel();
          return true;
        } catch {
          showToast("switch model failed");
          return false;
        }
      }
      function loadModels(sel) {
        fetch("/api/models")
          .then((r) => r.json())
          .then((list) => {
            const m = $("modelMenu");
            m.innerHTML = "";
            for (const md of list) {
              const d = document.createElement("div");
              d.className = "mi" + (md === curModel ? " check" : "");
              d.textContent = md;
              d.onclick = async () => {
                if (await applySessionModel(md)) closeMenus();
              };
              m.appendChild(d);
            }
            openAt("modelMenu", sel);
          })
          .catch(() => showToast("models load failed"));
      }
      function modelShort(m) {
        if (!m) return "模型";
        const n = m.includes("/") ? m.slice(m.lastIndexOf("/") + 1) : m;
        return n.length > 22 ? n.slice(0, 20) + "…" : n;
      }
      function renderModel() {
        const el = $("hModel");
        if (!el) return;
        el.textContent = modelShort(curModel);
        el.title = curModel ? "模型 " + curModel : "切换模型";
      }
      $("hModel").onclick = (e) => {
        e.stopPropagation();
        loadModels(e.currentTarget);
      };
      const THINK_LEVELS = [
        "off",
        "minimal",
        "low",
        "medium",
        "high",
        "xhigh",
        "max",
      ];
      function renderThink() {
        const el = $("hThink");
        if (!el) return;
        el.textContent = curThink || "high";
        el.title = "思考 " + (curThink || "high");
      }
      async function setThink(level) {
        try {
          const r = await fetch("/api/config", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ setDefaultThinkingLevel: level }),
          });
          const j = await r.json().catch(() => ({}));
          if (!r.ok || j.ok === false) {
            showToast(j.error || "switch think failed");
            return false;
          }
          if (j && j.defaultThinkingLevel) {
            curThink = j.defaultThinkingLevel;
            renderThink();
          }
          return true;
        } catch {
          showToast("switch think failed");
          return false;
        }
      }
      $("hThink").onclick = (e) => {
        e.stopPropagation();
        const m = $("thinkMenu");
        m.innerHTML = "";
        THINK_LEVELS.forEach((lv) => {
          const d = document.createElement("div");
          d.className = "mi" + (lv === curThink ? " check" : "");
          d.textContent = lv;
          d.onclick = () => {
            m.hidden = true;
            setThink(lv);
          };
          m.appendChild(d);
        });
        openAt("thinkMenu", e.currentTarget);
      };
      // ---- 授权模式(Codex /permissions: yolo / ask / read-only) ----
      let approvalMode = "yolo";
      const APPROVALS = [
        { id: "yolo", label: "yolo", hint: "不询问，默认" },
        { id: "ask", label: "ask", hint: "危险工具先问" },
        { id: "read-only", label: "read-only", hint: "危险工具直接拒" },
      ];
      function setModeBtn() {
        const p = $("permPill");
        const cur = APPROVALS.find((x) => x.id === approvalMode) || APPROVALS[0];
        p.textContent = cur.label;
        p.className =
          "perm-pill " +
          (approvalMode === "yolo"
            ? "perm-allow"
            : approvalMode === "ask"
              ? "perm-ask"
              : "perm-deny");
        p.title = "授权 " + cur.hint;
      }
      async function setApproval(mode) {
        approvalMode = mode;
        setModeBtn();
        try {
          const r = await fetch(
            "/api/mode?" + wsp + "session=" + encodeURIComponent(sess),
            {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ mode }),
            },
          );
          const j = await r.json().catch(() => ({}));
          if (!r.ok || j.ok === false) {
            showToast(j.error || "授权切换失败");
            return;
          }
          if (j.mode) approvalMode = j.mode;
          else if (j.auto !== undefined) approvalMode = j.auto ? "yolo" : "ask";
          setModeBtn();
        } catch {
          showToast("授权切换失败");
        }
      }
      $("permPill").onclick = (e) => {
        e.stopPropagation();
        const m = $("permMenu");
        m.innerHTML = "";
        APPROVALS.forEach((it) => {
          const d = document.createElement("div");
          d.className = "mi" + (it.id === approvalMode ? " check" : "");
          d.textContent = it.label + "  " + it.hint;
          d.onclick = (ev) => {
            ev.stopPropagation();
            closeMenus();
            setApproval(it.id);
          };
          m.appendChild(d);
        });
        openAt("permMenu", e.currentTarget);
      };
      let sandboxMode = "off";
      const SANDBOXES = [
        { id: "off", label: "off", hint: "不隔离" },
        { id: "workspace", label: "workspace", hint: "工作区可写，其余只读" },
        { id: "strict", label: "strict", hint: "工作区 + 断网" },
      ];
      function setSandboxBtn() {
        const p = $("sbPill");
        if (!p) return;
        const cur = SANDBOXES.find((x) => x.id === sandboxMode) || SANDBOXES[0];
        const be = window.sandboxBackend || "";
        p.textContent =
          cur.label === "off" ? "sb off" : be ? cur.label + "/" + be : cur.label;
        p.className =
          "perm-pill " +
          (sandboxMode === "strict" ? "perm-deny" : sandboxMode === "workspace" ? "perm-ask" : "");
        p.title = "沙箱 " + cur.hint + (be ? " · " + be : "");
      }
      async function setSandbox(mode) {
        sandboxMode = mode;
        setSandboxBtn();
        try {
          const r = await fetch("/api/config", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ setSandboxMode: mode }),
          });
          const j = await r.json().catch(() => ({}));
          if (!r.ok || j.ok === false) {
            showToast(j.error || "沙箱切换失败");
            return;
          }
          if (j && j.sandboxMode) sandboxMode = j.sandboxMode;
          if (j && j.sandboxBackend) window.sandboxBackend = j.sandboxBackend;
          setSandboxBtn();
        } catch {
          showToast("沙箱切换失败");
        }
      }
      $("sbPill").onclick = (e) => {
        e.stopPropagation();
        const m = $("sbMenu");
        m.innerHTML = "";
        SANDBOXES.forEach((it) => {
          const d = document.createElement("div");
          d.className = "mi" + (it.id === sandboxMode ? " check" : "");
          d.textContent = it.label + "  " + it.hint;
          d.onclick = (ev) => {
            ev.stopPropagation();
            closeMenus();
            setSandbox(it.id);
          };
          m.appendChild(d);
        });
        openAt("sbMenu", e.currentTarget);
      };
      $("modePill").onclick = () => {
        const i = $("inp");
        if (!i.value.startsWith("/")) i.value = "/";
        i.focus();
        i.dispatchEvent(new Event("input"));
      };
      // ---- 压缩提示 ----
      function setCost(n) {
        const el = $("costLbl");
        if (!el) return;
        if (n == null || !(Number(n) > 0)) {
          el.hidden = true;
          el.textContent = "";
          return;
        }
        const v = Number(n);
        el.hidden = false;
        el.textContent = v < 0.01 ? "$" + v.toFixed(4) : "$" + v.toFixed(3);
        el.title = "Session cost";
      }
      function setCtx(pct, used, win) {
        const wrap = $("ctxWrap"),
          fill = $("ctxFill"),
          lbl = $("ctxLbl");
        if (wrap && fill && lbl) {
          const frac =
            win > 0 ? used / win : Math.max(0, Math.min(1, (+pct || 0) / 100));
          const n = Math.max(0, Math.min(100, frac * 100));
          const C = 2 * Math.PI * 7;
          fill.style.strokeDashoffset = String(C * (1 - frac));
          lbl.textContent =
            n < 1 && (used > 0 || pct > 0) ? "<1%" : Math.round(n) + "%";
          wrap.hidden = false;
          const pretty =
            n < 0.1 && used > 0
              ? "<0.1%"
              : (n < 10 ? n.toFixed(1) : Math.round(n)) + "%";
          wrap.dataset.baseTitle =
            used != null && win
              ? fmtTok(used) + " / " + fmtTok(win) + " · " + pretty
              : "上下文 " + pretty;
          wrap.title = wrap.dataset.baseTitle;
          fill.style.stroke =
            n > 85 ? "var(--color-danger)" : "var(--color-accent)";
        }
        if ((win > 0 ? used / win : (+pct || 0) / 100) > 0.85) {
          const c = $("compactChip");
          c.style.display = "";
          c.onclick = () => {
            showToast("正在压缩…");
            act({ act: "compact" }, (j) => {
              showToast(j && j.ok ? "压缩完成" : "压缩失败");
            });
          };
        } else $("compactChip").style.display = "none";
      }
      function setTurnMeta(evt) {
        const el = $("turnMeta");
        if (!el) return;
        const bits = [];
        if (evt.cache !== undefined && evt.cache !== "")
          bits.push("缓存 " + evt.cache + "%");
        if (evt.tps) bits.push(evt.tps + " tok/s");
        if (!bits.length) {
          el.hidden = true;
          return;
        }
        el.hidden = false;
        el.textContent = bits.join(" · ");
        const wrap = $("ctxWrap");
        if (wrap && !wrap.hidden) {
          const extra = [];
          if (evt.cache !== undefined && evt.cache !== "") extra.push("缓存 " + evt.cache + "%");
          if (evt.tps) extra.push(evt.tps + " tok/s");
          wrap.title =
            (wrap.dataset.baseTitle || wrap.title || "上下文") +
            (extra.length ? " · " + extra.join(" · ") : "");
        }
      }
      // ---- 头部 ----
      function renderHdr(s) {
        const wsName = s.ws || projectName(ws) || "";
        const hWs = $("hWs"),
          hSep = $("hSep"),
          hSes = $("hSes");
        if (wsName) {
          hWs.textContent = wsName;
          hSep.style.display = "";
          hWs.onclick = (e) => {
            e.stopPropagation();
            openWsMenu(hWs);
          };
        } else {
          hWs.textContent = "";
          hSep.style.display = "none";
        }
        hSes.textContent = sess === "default" ? "默认会话" : s.title || sess;
        $("tbWs").textContent = wsName || "";
        $("tbSe").textContent =
          sess === "default" ? "默认会话" : s.title || sess;
        const git = $("hGit");
        git.innerHTML = "";
        if (s.branch) {
          const pill = document.createElement("span");
          pill.className = "ch-pill";
          pill.innerHTML =
            "<b>" +
            esc(s.branch) +
            "</b>" +
            (s.ahead ? ' <span class="ch-ahead">↑' + s.ahead + "</span>" : "") +
            (s.behind
              ? ' <span class="ch-behind">↓' + s.behind + "</span>"
              : "");
          git.appendChild(pill);
        }
        if (s.changes) {
          const pill = document.createElement("span");
          pill.className = "ch-pill";
          pill.style.borderColor =
            "color-mix(in srgb,var(--color-success) 20%,var(--color-line))";
          pill.textContent = s.changes + " 个变更";
          git.appendChild(pill);
        }
      }
      async function applySessionTitle(t, hdr) {
        try {
          const r = await fetch(
            "/api/title?" + wsp + "session=" + encodeURIComponent(sess),
            {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ title: t }),
            },
          );
          const j = await r.json().catch(() => ({}));
          if (!r.ok || j.ok === false || j.title === undefined) {
            showToast(j.error || "set title failed");
            return false;
          }
          curTitle = j.title;
          if (hdr) renderHdr({ title: j.title });
          loadSessions();
          return true;
        } catch {
          showToast("set title failed");
          return false;
        }
      }
      $("hSes").onclick = async () => {
        const t = await askText("会话标题", curTitle || "", "");
        if (t === null) return;
        await applySessionTitle(t, true);
      };
      $("hKebab").onclick = (e) => {
        e.stopPropagation();
        const m = $("kmenu");
        m.innerHTML = "";
        const mi = (t, fn, danger) => {
          const d = document.createElement("div");
          d.className = "mi" + (danger ? " danger" : "");
          d.textContent = t;
          d.onclick = () => {
            closeMenus();
            fn();
          };
          m.appendChild(d);
        };
        mi("⧉ 复制最后回复", () => runSlash({ name: "/copy" }, ""));
        mi("⎘ 导出 HTML", () => runSlash({ name: "/export" }, ""));
        mi("☰ 消息列表", () => runSlash({ name: "/tree" }, ""));
        mi("📋 复制全部", () => runSlash({ name: "/dump" }, ""));
        mi("✎ 计划", async () => {
          const g = await askText("计划目标", "", "要完成什么");
          if (g) runSlash({ name: "/plan" }, g);
        });
        mi("✎ 重命名", async () => {
          const t = await askText("会话标题", curTitle || "", "");
          if (t === null) return;
          await applySessionTitle(t, false);
        });
        mi("✱ 派生会话", async () => {
          const n = await askText("派生会话", "", "新会话名，留空自动");
          if (n === null) return;
          act({ act: "fork", name: n || "" }, (j) => {
            if (j && j.name) {
              showToast("已派生 " + j.name);
              setTimeout(
                () =>
                  (location.href = sessUrl(j.name)),
                600,
              );
            }
          });
        });
        const se = document.createElement("div");
        se.className = "sep";
        m.appendChild(se);
        mi("↶ 撤销最后一条", () => {
          act({ act: "undo" }, (j) => {
            showToast(j && j.ok ? "已撤销" : "无可撤销");
            setTimeout(() => location.reload(), 400);
          });
        });
        mi("⚡ 压缩上下文", () => {
          showToast("正在压缩…");
          act({ act: "compact" }, (j) => {
            showToast(j && j.ok ? "压缩完成" : "压缩失败");
          });
        });
        const se2 = document.createElement("div");
        se2.className = "sep";
        m.appendChild(se2);
        mi(
          "🗄 归档会话",
          () => {
            act({ act: "archive" }, (j) => {
              if (j && j.ok) {
                showToast("已归档");
                setTimeout(() => (location.href = sessUrl("default")), 400);
              }
            });
          },
          true,
        );
        openAt("kmenu", e.currentTarget);
      };
      $("tbKebab").onclick = (e) => {
        e.stopPropagation();
        $("hKebab").onclick(e);
      };
      // ---- 渲染核心已迁 chat.ts ----

      // ---- SSE 已迁 stream.ts(ev.onmessage 于下方指派) ----
      let running = false;
      let lastUser = "";
      let lastImgUrl = null;
      let pending = [];
      function refreshSend() {
        const t = $("inp").value.trim();
        const stop = running && !t;
        $("send").textContent = stop ? "■" : "➤";
        $("send").classList.toggle("stop", stop);
        $("send").title = stop ? "停止" : running ? "接着发" : "发送";
        const inp = $("inp");
        if (inp) {
          inp.placeholder = running
            ? "接着发…"
            : inp.dataset.ph || inp.placeholder;
        }
      }
      function setRun(r) {
        running = r;
        refreshSend();
        if (r) ensureActPoll();
      }
      let actTimer = 0;
      function fmtActChip(a) {
        const sec = a.ms < 10000 ? (a.ms / 1000).toFixed(1) : String(Math.round(a.ms / 1000));
        const lim = a.limit_ms && !a.detached ? "/" + Math.round(a.limit_ms / 1000) + "s" : "";
        const by = a.bytes ? " · " + fmtTok(a.bytes) : "";
        return (
          '<span class="act-chip' +
          (a.detached ? " bg" : "") +
          '">' +
          esc(a.name || "job") +
          " " +
          sec +
          "s" +
          lim +
          by +
          (a.detached ? " · bg" : "") +
          "</span>"
        );
      }
      async function tickActivity() {
        const el = $("actStrip");
        if (!el) return 0;
        try {
          const r = await fetch("/api/activity");
          const list = await r.json();
          if (!list || !list.length) {
            el.hidden = true;
            el.innerHTML = "";
            return 0;
          }
          el.hidden = false;
          el.innerHTML = list.map(fmtActChip).join("");
          return list.length;
        } catch {
          return 0;
        }
      }
      function ensureActPoll() {
        if (actTimer) return;
        actTimer = setInterval(async () => {
          const n = await tickActivity();
          if (!n && !running) {
            clearInterval(actTimer);
            actTimer = 0;
          }
        }, 400);
      }
      function renderQueue() {
        const box = $("qbox"),
          items = $("qItems"),
          count = $("qCount");
        if (!box || !items) return;
        if (!pending.length) {
          box.hidden = true;
          items.innerHTML = "";
          return;
        }
        box.hidden = false;
        count.textContent = pending.length === 1 ? "待发" : pending.length + " 条待发";
        items.innerHTML = pending
          .map((t) => '<div class="q-item">' + esc(t) + "</div>")
          .join("");
      }
      function dropPending(text) {
        const i = pending.indexOf(text);
        if (i >= 0) pending.splice(i, 1);
        else if (pending.length) pending.shift();
        renderQueue();
      }
      ev.onmessage = (e) => {
        let evt;
        try {
          evt = JSON.parse(e.data);
        } catch {
          return;
        }
        if (evt.session && evt.session !== sess) return;
        pluginEmit("event", evt);
        pluginEmit(evt.type, evt);
        switch (evt.type) {
          case "user_message":
            lastUser = evt.text || lastUser;
            dropPending(evt.text);
            addUser(evt.has_image && !evt.text ? "[image]" : evt.has_image ? (evt.text || "") + "  [image]" : (evt.text || ""), evt.image_file ? "/api/image?name=" + encodeURIComponent(evt.image_file) : evt.has_image ? lastImgUrl : null);
            lastImgUrl = null;
            noteTurn();
            setRun(true);
            break;
          case "queued":
            if (evt.text && pending.indexOf(evt.text) < 0) pending.push(evt.text);
            renderQueue();
            break;
          case "title":
            if (evt.title) {
              curTitle = evt.title;
              if ($("hSes") && sess !== "default") $("hSes").textContent = evt.title;
              if ($("tbSe") && sess !== "default") $("tbSe").textContent = evt.title;
              loadSessions();
            }
            break;
          case "notice":
            addNotice(evt.text);
            break;
          case "reasoning":
            setRun(true);
            addRsn(evt.text);
            break;
          case "message":
            setRun(true);
            addAsst(evt.text);
            break;
          case "tool_call":
            addTool(evt.name, evt.args);
            break;
          case "tool_result":
            toolDone(evt.name, evt.error, evt.summary);
            break;
          case "subagent":
            addSub(evt.idx, evt.kind, evt.text);
            break;
          case "permission":
            addPerm(evt.id, evt.name, evt.args);
            break;
          case "permission_result":
            {
              const pc = document.querySelector(
                '.pc[data-pid="' + evt.id + '"]',
              );
              if (pc) pc.remove();
            }
            break;
          case "turn_end":
            finishAsst();
            finishRsn();
            finishWork();
            stampTurn();
            setRun(false);
            if (
              prefs.notify &&
              window.Notification &&
              Notification.permission === "granted"
            ) {
              try {
                new Notification("piz", { body: "本轮已完成" });
              } catch {}
            }
            if (prefs.sound) {
              try {
                const AC = window.AudioContext || window.webkitAudioContext;
                const ac = new AC();
                const o = ac.createOscillator();
                const g = ac.createGain();
                o.frequency.value = 880;
                g.gain.value = 0.04;
                o.connect(g);
                g.connect(ac.destination);
                o.start();
                o.stop(ac.currentTime + 0.08);
              } catch {}
            }
            break;
          case "status":
            if (evt.cost !== undefined) setCost(evt.cost);
            if (evt.pct !== undefined || evt.used !== undefined) {
              setCtx(evt.pct, evt.used, evt.window);
            }
            setTurnMeta(evt);
            if (evt.model) renderModel();
            if (evt.think) {
              curThink = evt.think;
              renderThink();
            }
            break;
        }
      };
      // ---- 发送 ----
      $("qClr").onclick = () => runSlash({ name: "/queue" }, "");
      $("send").onclick = () => {
        if (running && !$("inp").value.trim()) {
          fetch(
            "/api/interrupt?" + wsp + "session=" + encodeURIComponent(sess),
            { method: "POST" },
          );
        } else send();
      };
      // ---- 斜杠目录/菜单/runSlash 已迁 slash.ts ----
      // ---- runSlash 已迁 slash.ts ----
      function toggleKeysHint() {
        const el = $("keysHint");
        if (!el) return;
        if (!el.hidden) {
          el.hidden = true;
          el.innerHTML = "";
          return;
        }
        el.hidden = false;
        el.innerHTML =
          "<div><kbd>/</kbd> 命令 · <kbd>@./</kbd> 文件 · <kbd>!</kbd> 本页命令</div>" +
          "<div><kbd>j</kbd> 任务 · <kbd>u</kbd> 用量 · <kbd>g</kbd> 差异 · <kbd>l</kbd> 日志 · <kbd>c</kbd> 复制 · <kbd>s</kbd> 沙箱 · <kbd>?</kbd> 本卡</div>" +
          "<div><kbd>Ctrl</kbd><kbd>K</kbd> 搜会话 · <kbd>Ctrl</kbd><kbd>Shift</kbd><kbd>C</kbd> 复制回复</div>" +
          "<div><kbd>Ctrl</kbd><kbd>Shift</kbd><kbd>R</kbd> 重发 · <kbd>Ctrl</kbd><kbd>V</kbd> 贴图 · <kbd>Esc</kbd> 关</div>";
      }
      $("inp").addEventListener("keydown", (e) => {
        if (
          !e.isComposing &&
          !e.ctrlKey &&
          !e.metaKey &&
          !e.altKey &&
          !$("inp").value &&
          !slashOpen()
        ) {
          if (e.key === "u" || e.key === "U") {
            e.preventDefault();
            runSlash({ name: "/usage" }, "");
            return;
          }
          if (e.key === "j" || e.key === "J") {
            e.preventDefault();
            runSlash({ name: "/jobs" }, "");
            return;
          }
          if (e.key === "d" || e.key === "D") {
            e.preventDefault();
            runSlash({ name: "/doctor" }, "");
            return;
          }
          if (e.key === "g" || e.key === "G") {
            e.preventDefault();
            runSlash({ name: "/diff" }, "");
            return;
          }
          if (e.key === "l" || e.key === "L") {
            e.preventDefault();
            runSlash({ name: "/log" }, "");
            return;
          }
          if (e.key === "r" || e.key === "R") {
            e.preventDefault();
            runSlash({ name: "/redo" }, "");
            return;
          }
          if (e.key === "c" || e.key === "C") {
            e.preventDefault();
            runSlash({ name: "/copy" }, "");
            return;
          }
          if (e.key === "s" || e.key === "S") {
            e.preventDefault();
            const p = $("sbPill");
            if (p) p.click();
            else runSlash({ name: "/sandbox" }, "");
            return;
          }
          if (e.key === "?") {
            e.preventDefault();
            toggleKeysHint();
            return;
          }
        }
        if (slashOpen()) {
          if (e.key === "ArrowDown") {
            e.preventDefault();
            slashMove(1);
            return;
          }
          if (e.key === "ArrowUp") {
            e.preventDefault();
            slashMove(-1);
            return;
          }
          if (e.key === "Tab") {
            e.preventDefault();
            slashComplete();
            return;
          }
          if (e.key === "Enter") {
            e.preventDefault();
            slashPick();
            return;
          }
          if (e.key === "Escape") {
            e.preventDefault();
            hideSlash();
            return;
          }
        }
        if (
          e.key === "ArrowUp" &&
          !e.shiftKey &&
          $("inp").selectionStart === 0 &&
          $("inp").value.indexOf("\n") < 0
        ) {
          e.preventDefault();
          histPrev();
          return;
        }
        if (
          e.key === "ArrowDown" &&
          !e.shiftKey &&
          $("inp").selectionStart === $("inp").value.length &&
          $("inp").value.indexOf("\n") < 0
        ) {
          e.preventDefault();
          histNext();
          return;
        }
        if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault();
          send();
        }
      });
      $("inp").addEventListener("input", () => {
        const kh = $("keysHint");
        if (kh && !kh.hidden && $("inp").value) {
          kh.hidden = true;
          kh.innerHTML = "";
        }
        autosizeInp();
        saveDraft();
        updateSlash();
        refreshSend();
      });
      let pendingImg = null;
      function paintImgChip() {
        let c = $("img-chip");
        if (!c) {
          c = document.createElement("div");
          c.id = "img-chip";
          c.className = "img-chip";
          const box = $("inp").parentNode;
          if (box) box.insertBefore(c, $("inp"));
        }
        if (!pendingImg) {
          c.hidden = true;
          c.innerHTML = "";
          return;
        }
        c.hidden = false;
        c.innerHTML = "<img alt=\"\" /><span>image</span><button type=button>✕</button>";
        c.querySelector("img").src = "data:" + pendingImg.mime + ";base64," + pendingImg.b64;
        c.querySelector("button").onclick = () => {
          pendingImg = null;
          paintImgChip();
        };
      }
      async function blobToChatImage(blob) {
        const bmp = await createImageBitmap(blob);
        const max = 1600;
        let w = bmp.width,
          h = bmp.height;
        if (w > max || h > max) {
          const s = max / Math.max(w, h);
          w = Math.round(w * s);
          h = Math.round(h * s);
        }
        const cv = document.createElement("canvas");
        cv.width = w;
        cv.height = h;
        cv.getContext("2d").drawImage(bmp, 0, 0, w, h);
        const url = cv.toDataURL("image/jpeg", 0.85);
        const i = url.indexOf(",");
        return { mime: "image/jpeg", b64: url.slice(i + 1) };
      }
      async function attachClipboardImage() {
        if (navigator.clipboard && navigator.clipboard.read) {
          try {
            const items = await navigator.clipboard.read();
            for (const it of items) {
              const type = (it.types || []).find((t) => String(t).indexOf("image/") === 0);
              if (!type) continue;
              const blob = await it.getType(type);
              pendingImg = await blobToChatImage(blob);
              paintImgChip();
              return true;
            }
          } catch {}
        }
        return false;
      }
      document.addEventListener("paste", async (ev) => {
        const items = ev.clipboardData && ev.clipboardData.items;
        if (!items) return;
        for (const it of items) {
          if (it.type && it.type.indexOf("image/") === 0) {
            ev.preventDefault();
            const blob = it.getAsFile();
            if (!blob) return;
            try {
              pendingImg = await blobToChatImage(blob);
              paintImgChip();
            } catch {}
            return;
          }
        }
      });
      async function sendPlain(t) {
        if (!t && !pendingImg) return;
        lastUser = t || "(image)";
        let img = pendingImg;
        lastImgUrl = img || null;
        pendingImg = null;
        if (img && !curVision) {
          addNotice("image dropped: model has no vision");
          img = null;
          if (!t) {
            paintImgChip();
            return;
          }
        }
        paintImgChip();
        setRun(true);
        let ok = false;
        try {
          const body = { text: t || "" };
          if (img) {
            body.image = img.b64;
            body.mime = img.mime;
          }
          const r = await fetch(
            "/api/chat?" + wsp + "session=" + encodeURIComponent(sess),
            {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify(body),
            },
          );
          const j = await r.json().catch(() => ({}));
          if (!r.ok || j.ok === false) {
            showToast(j.error || "send failed");
          } else ok = true;
        } catch {
          showToast("send failed");
        }
        if (!ok) {
          // 失败不吞草稿:文本塞回输入框,图也还回 pending。
          setRun(false);
          if (t && $("inp")) {
            $("inp").value = t;
            autosizeInp();
            refreshSend();
          }
          if (img && !pendingImg) {
            pendingImg = img;
            paintImgChip();
          }
        }
        return ok;
      }
      async function send() {
        hideSlash();
        hideBang();
        const t = $("inp").value.trim();
        if (!t && !pendingImg) return;
        if (t.startsWith("/")) {
          const space = t.indexOf(" ");
          const cmd = space < 0 ? t : t.slice(0, space);
          const arg = space < 0 ? "" : t.slice(space + 1);
          const item = findSlash(cmd);
          if (item) {
            $("inp").value = "";
            $("inp").style.height = "auto";
            clearDraft();
            hideSlash();
            refreshSend();
            pushHist(t);
            await runSlash(item, arg);
            return;
          }
        }
        $("inp").value = "";
        $("inp").style.height = "auto";
        clearDraft();
        pushHist(t);
        hideSlash();
        refreshSend();
        await sendPlain(t);
        // 桌面端发完回焦,接着打下一行;触屏不弹键盘。
        if (window.matchMedia("(hover: hover)").matches) $("inp").focus();
      }
      // ---- 移动 sheet ----
      const sheet = $("sheet");
      function openSheet() {
        loadSessions();
        sheet.classList.add("open");
        document.body.style.overflow = "hidden"; // 锁住背后滚动
      }
      function closeSheet() {
        sheet.classList.remove("open");
        document.body.style.overflow = "";
      }
      // 下滑关闭:按住 grab/头部往下拖超过 70px 或快甩即收。
      (function () {
        const pnl = $("spnl");
        if (!pnl) return;
        let y0 = 0,
          dy = 0,
          t0 = 0,
          drag = false;
        pnl.addEventListener("touchstart", (e) => {
          const onHandle = e.target.closest(".grab, .shd");
          const atTop = $("sbody") && $("sbody").scrollTop <= 0;
          drag = !!(onHandle || atTop);
          y0 = e.touches[0].clientY;
          t0 = Date.now();
          dy = 0;
          if (drag) pnl.style.transition = "none";
        }, { passive: true });
        pnl.addEventListener("touchmove", (e) => {
          if (!drag) return;
          dy = Math.max(0, e.touches[0].clientY - y0);
          pnl.style.transform = "translateY(" + dy + "px)";
        }, { passive: true });
        pnl.addEventListener("touchend", () => {
          if (!drag) return;
          drag = false;
          pnl.style.transition = "";
          pnl.style.transform = "";
          const fling = Date.now() - t0 < 250 && dy > 30;
          if (dy > 70 || fling) closeSheet();
        });
      })();
      $("scrim").onclick = closeSheet;
      $("scls").onclick = closeSheet;
      $("tbMid").onclick = openSheet;
      $("newBtn").onclick = () => {
        location.href = sessUrl(Math.random().toString(36).slice(2, 8));
      };
      $("colBtn").onclick = () => {
        document.body.classList.add("collapsed");
        try {
          localStorage.setItem("piz.sidebar", "1");
        } catch {}
      };
      $("expBtn").onclick = () => {
        document.body.classList.remove("collapsed");
        try {
          localStorage.setItem("piz.sidebar", "0");
        } catch {}
      };
      $("setBtn").onclick = () => openSettings();
      document.querySelector(".ch-brand").onclick = (e) => {
        e.stopPropagation();
        openWsMenu(e.currentTarget);
      };
      // 空状态
      function hideWelcome() {
        const x = $("welcome");
        if (x) x.remove();
        $("app")?.classList.remove("hero");
      }
      // ---- 插件 SDK v1 ----
      const pluginListeners = new Map(),
        toolRenderers = new Map(),
        msgRenderers = [],
        pluginCleanups = [];
      function pluginEmit(type, detail) {
        for (const fn of pluginListeners.get(type) || []) {
          try {
            fn(detail);
          } catch (e) {
            console.error("[piz plugin]", e);
          }
        }
        window.dispatchEvent(new CustomEvent("piz:" + type, { detail }));
      }
      function pluginOn(type, fn) {
        const set = pluginListeners.get(type) || new Set();
        set.add(fn);
        pluginListeners.set(type, set);
        return () => set.delete(fn);
      }
      function pluginUrl(path) {
        const u = new URL(path, location.href);
        if (ws) u.searchParams.set("ws", ws);
        return u.href;
      }
      function pluginApi(meta) {
        const owned = [];
        const api = {
          version: 1,
          id: meta.id,
          name: meta.name,
          session: sess,
          workspace: ws,
          asset: (rel) =>
            pluginUrl(new URL(rel, new URL(meta.base, location.href)).href),
          on: (type, fn) => {
            const off = pluginOn(type, fn);
            owned.push(off);
            return off;
          },
          toast: showToast,
          fetch: async (path, opts) => {
            const u = new URL(path, location.href);
            if (u.origin !== location.origin || !u.pathname.startsWith("/api/"))
              throw new Error(
                "plugin fetch only allows same-origin /api routes",
              );
            if (ws && !u.searchParams.has("ws")) u.searchParams.set("ws", ws);
            return fetch(u, opts);
          },
          send: (text) => {
            if (running) return false;
            sendPlain(String(text));
            return true;
          },
          ui: {
            slot: (name) =>
              document.querySelector('[data-piz-slot="' + name + '"]'),
            mount: (slot, value) => {
              const host = api.ui.slot(slot);
              if (!host) throw new Error("unknown slot: " + slot);
              const root = document.createElement("span");
              root.dataset.pizPlugin = meta.id;
              root.appendChild(
                value instanceof Node
                  ? value
                  : document.createTextNode(String(value)),
              );
              host.appendChild(root);
              owned.push(() => root.remove());
              return root;
            },
            button: (slot, spec = {}) => {
              const b = document.createElement("button");
              b.type = "button";
              b.className =
                "piz-plugin-btn" + (spec.className ? " " + spec.className : "");
              b.textContent = spec.label || meta.name;
              b.title = spec.title || "";
              if (spec.onClick) b.addEventListener("click", spec.onClick);
              api.ui.mount(slot, b);
              return b;
            },
          },
          renderTool: (name, fn) => {
            toolRenderers.set(name, fn);
            owned.push(() => {
              if (toolRenderers.get(name) === fn) toolRenderers.delete(name);
            });
          },
          renderMessage: (fn) => {
            msgRenderers.push(fn);
            owned.push(() => {
              const i = msgRenderers.indexOf(fn);
              if (i >= 0) msgRenderers.splice(i, 1);
            });
          },
          storage: {
            get: (key, fb = null) => {
              try {
                const v = localStorage.getItem(
                  "piz.plugin." + meta.id + "." + key,
                );
                return v === null ? fb : JSON.parse(v);
              } catch {
                return fb;
              }
            },
            set: (key, value) =>
              localStorage.setItem(
                "piz.plugin." + meta.id + "." + key,
                JSON.stringify(value),
              ),
            remove: (key) =>
              localStorage.removeItem("piz.plugin." + meta.id + "." + key),
          },
        };
        api.dispose = () => {
          while (owned.length) {
            try {
              owned.pop()();
            } catch {}
          }
        };
        return Object.freeze(api);
      }
      async function loadPlugins() {
        try {
          const r = await fetch("/api/plugins?" + wsp);
          if (!r.ok) throw new Error("manifest " + r.status);
          const m = await r.json();
          for (const meta of m.plugins || []) {
            try {
              if (meta.style) {
                const l = document.createElement("link");
                l.rel = "stylesheet";
                l.href = pluginUrl(meta.style);
                l.dataset.pizPlugin = meta.id;
                document.head.appendChild(l);
                pluginCleanups.push(() => l.remove());
              }
              const mod = await import(pluginUrl(meta.entry));
              const activate =
                typeof mod.activate === "function"
                  ? mod.activate
                  : typeof mod.default === "function"
                    ? mod.default
                    : null;
              if (!activate) throw new Error("missing activate(api)");
              const api = pluginApi(meta);
              const cleanup = await activate(api);
              pluginCleanups.push(() => {
                try {
                  if (typeof cleanup === "function") cleanup();
                } finally {
                  api.dispose();
                }
              });
              pluginEmit("plugin-loaded", { plugin: meta });
            } catch (e) {
              console.error("[piz plugin " + meta.id + "]", e);
              pluginEmit("plugin-error", { plugin: meta, error: String(e) });
            }
          }
          pluginEmit("ready", {
            apiVersion: m.apiVersion || 1,
            plugins: m.plugins || [],
          });
        } catch (e) {
          console.error("[piz plugins]", e);
        }
      }
      window.piz = Object.freeze({
        version: 1,
        on: pluginOn,
        session: sess,
        workspace: ws,
        slots: ["header", "composer", "status"],
      });
      window.addEventListener("beforeunload", () => {
        while (pluginCleanups.length) {
          try {
            pluginCleanups.pop()();
          } catch {}
        }
      });
      // ---- 初始化 ----
      let curModel = "",
        curThink = "high",
        curTitle = "",
        curVision = false;
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
            if (s.running) {
              const la = th.querySelector(".a-turn:last-child");
              if (la) curAsst = la;
            }
          } else paintHistMore();
          if (s.cost !== undefined) setCost(s.cost);
          if (s.pct !== undefined || s.used !== undefined) setCtx(s.pct, s.used, s.window);
          if (s.running) setRun(true);
          if (s.model) {
            curModel = s.model;
            renderModel();
          }
          if (typeof s.vision === "boolean") curVision = s.vision;
          if (s.think) {
            curThink = s.think;
            renderThink();
          }
          if (s.title) {
            curTitle = s.title;
          }
          if (s.mode || s.auto !== undefined) {
            approvalMode = s.mode || (s.auto ? "yolo" : "ask");
            setModeBtn();
          }
          renderHdr(s);
        })
        .catch(() => showToast("state load failed"));
      setModeBtn();
      setSandboxBtn();
      fetch("/api/config")
        .then((r) => r.json())
        .then((cfg) => {
          if (cfg && cfg.sandboxMode) sandboxMode = cfg.sandboxMode;
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
          approvalMode = s.mode || (s.auto ? "yolo" : "ask");
          setModeBtn();
        }
        closeSheet();
      };
      // slash 解缠钩:聊天渲染/发送/模型态皆以箭函迟取,调用时方触
      Object.assign(slashH, {
        addUser, addAsst, finishAsst, openSearch, setApproval,
        attachClipboardImage, refreshSend, ensureActPoll, setSandbox, setThink,
        asstEl, findInThread, setScheme, applySessionTitle, sendPlain, send,
        renderQueue, clipText,
        getSandboxMode: () => sandboxMode,
        getThink: () => curThink,
        getWebFindQ,
        getCurModel: () => curModel,
        getCurTitle: () => curTitle,
        getVision: () => curVision,
        getLastUser: () => lastUser,
        approvalLabel: () => (APPROVALS.find((x) => x.id === approvalMode) || {}).label,
        setApprovalMode: (v) => { approvalMode = v === "read-only" ? "read-only" : v; setModeBtn(); },
        applySandboxLevel: (v) => { sandboxMode = v; setSandboxBtn(); },
        applyThinkLevel: (v) => { curThink = v; renderThink(); },
        clearPending: () => { pending = []; },
      });
      // chat 解缠钩:欢迎页/插件/授权/发送皆以箭函迟取
      Object.assign(chatH, {
        hideWelcome, pluginEmit, setApproval, sendPlain,
        getLastUser: () => lastUser,
        setLastUser: (v) => { lastUser = v; },
        getToolRenderer: (n) => toolRenderers.get(n),
      });
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
