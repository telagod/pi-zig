      "use strict";
      const $ = (id) => document.getElementById(id);
      const esc = (s) =>
        String(s)
          .replace(/&/g, "&amp;")
          .replace(/</g, "&lt;")
          .replace(/>/g, "&gt;");
      function histText(v) {
        if (typeof v === "string") return v;
        if (Array.isArray(v)) {
          try {
            return new TextDecoder("utf-8").decode(Uint8Array.from(v));
          } catch {
            return "";
          }
        }
        return v == null ? "" : String(v);
      }
      const qp = new URLSearchParams(location.search);
      const sess = qp.get("session") || "default";
      const ws = decodeURIComponent(qp.get("ws") || "");
      const wsp = ws ? "ws=" + encodeURIComponent(ws) + "&" : "";
      const isMobile = () => window.innerWidth < 840;
      const PREF_KEY = "piz.prefs";
      const prefs = {
        scheme: "dark",
        accent: "mono",
        accentPicked: false,
        uiFont: 14,
        notify: false,
        sound: false,
      };
      try {
        Object.assign(prefs, JSON.parse(localStorage.getItem(PREF_KEY) || "{}"));
      } catch {}
      if (!prefs.accentPicked) prefs.accent = "mono";
      try {
        const old = localStorage.getItem("piz.scheme");
        if (old && !localStorage.getItem(PREF_KEY)) prefs.scheme = old;
      } catch {}
      function savePrefs() {
        try {
          localStorage.setItem(PREF_KEY, JSON.stringify(prefs));
        } catch {}
      }
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
      // ---- 服务器凭证(kimi serverAuth.ts:#token= fragment + sessionStorage) ----
      const AUTH_KEY = "piz-web.credential";
      let credential = undefined;
      function readFragmentToken() {
        const hash = location.hash || "";
        if (!hash.startsWith("#")) return undefined;
        const params = new URLSearchParams(hash.slice(1));
        const token = params.get("token");
        if (!token) return undefined;
        const url = new URL(location.href);
        url.hash = "";
        history.replaceState(history.state, "", url.pathname + url.search);
        return token;
      }
      function initServerAuth() {
        const frag = readFragmentToken();
        if (frag) { setCredential(frag); return true; }
        try {
          const stored = sessionStorage.getItem(AUTH_KEY);
          if (stored) { credential = stored; return true; }
        } catch {}
        return false;
      }
      function setCredential(v) {
        credential = v;
        try { sessionStorage.setItem(AUTH_KEY, v); } catch {}
      }
      function clearCredential() {
        credential = undefined;
        try { sessionStorage.removeItem(AUTH_KEY); } catch {}
      }
      function showAuthPage(msg) {
        $("splash")?.classList.add("hide");
        $("authPage")?.classList.add("show");
        if (msg) $("authErr").textContent = msg;
        const inp = $("authTok");
        if (inp) { inp.disabled = false; inp.focus(); }
        const btn = $("authBtn");
        if (btn) btn.disabled = true;
      }
      function hideAuthPage() {
        $("authPage")?.classList.remove("show");
        $("authErr").textContent = "";
      }
      // fetch 全局包装:带 Bearer + 401 → 登录页(kimi http.ts 等价)
      const rawFetch = window.fetch.bind(window);
      window.fetch = (url, opts = {}) => {
        opts = Object.assign({}, opts);
        opts.headers = Object.assign({}, opts.headers || {});
        if (credential) opts.headers["Authorization"] = "Bearer " + credential;
        return rawFetch(url, opts).then((res) => {
          if (res.status === 401 && !opts.headers["X-Skip-Auth"]) {
            clearCredential();
            showAuthPage("凭证无效或已过期,请重新输入");
          }
          return res;
        });
      };
      // 登录提交
      const authInp = $("authTok");
      authInp.addEventListener("input", () => {
        $("authBtn").disabled = !authInp.value.trim();
      });
      authInp.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && authInp.value.trim() && !$("authBtn").disabled)
          submitAuth();
      });
      async function submitAuth() {
        const v = authInp.value.trim();
        if (!v) return;
        $("authBtn").disabled = true;
        authInp.disabled = true;
        setCredential(v);
        try {
          const r = await rawFetch("/api/state?" + wsp + "session=" + encodeURIComponent(sess), {
            headers: { Authorization: "Bearer " + v, "X-Skip-Auth": "1" },
          });
          if (r.ok) {
            hideAuthPage();
            boot();
          } else {
            clearCredential();
            $("authErr").textContent = "连接失败,请检查 token";
            authInp.disabled = false;
            authInp.focus();
            $("authBtn").disabled = false;
          }
        } catch (e) {
          clearCredential();
          $("authErr").textContent = "无法连接服务器";
          authInp.disabled = false;
          $("authBtn").disabled = false;
        }
      }
      $("authBtn").onclick = submitAuth;
      // ---- toast ----
      const toastEl = $("toast");
      let toastT = null;
      function showToast(t) {
        toastEl.textContent = t;
        toastEl.classList.add("show");
        clearTimeout(toastT);
        toastT = setTimeout(() => toastEl.classList.remove("show"), 2200);
      }
      let dlgOnok = null,
        dlgOncancel = null;
      let dlgPrevFocus = null;
      function closeDlg() {
        const ov = $("overlay");
        ov.classList.remove("open", "sheet");
        ov.innerHTML = "";
        dlgOnok = dlgOncancel = null;
        // 焦点还给弹出前的元素(还在文档里才还)。
        if (dlgPrevFocus && document.contains(dlgPrevFocus)) {
          try { dlgPrevFocus.focus({ preventScroll: true }); } catch {}
        }
        dlgPrevFocus = null;
      }
      function openDlg(opts) {
        if (typeof closeMenus === "function") closeMenus();
        if (typeof hideSlash === "function") hideSlash();
        if (typeof hideBang === "function") hideBang();
        const ov = $("overlay");
        ov.classList.add("open");
        if (opts.cls === "set") ov.classList.add("sheet");
        ov.innerHTML =
          '<div class="dlg ' +
          (opts.cls || "") +
          '" role="dialog"><div class="dlg-hd"><span>' +
          esc(opts.title || "") +
          '</span><button class="dlg-x" id="dlgX" type="button">✕</button></div><div class="dlg-bd">' +
          (opts.body || "") +
          "</div>" +
          (opts.ok
            ? '<div class="dlg-ft">' +
              (opts.cancel
                ? '<button class="btn" id="dlgCancel" type="button">' +
                  esc(opts.cancel) +
                  "</button>"
                : "") +
              '<button class="btn ' +
              (opts.danger ? "btn-d" : "btn-p") +
              '" id="dlgOk" type="button">' +
              esc(opts.ok) +
              "</button></div>"
            : "") +
          "</div>";
        dlgOnok = opts.onok || null;
        dlgOncancel = opts.oncancel || null;
        dlgPrevFocus = document.activeElement; // 关时还原焦点
        $("dlgX").onclick = () => {
          if (dlgOncancel) dlgOncancel();
          closeDlg();
        };
        const cxl = $("dlgCancel");
        if (cxl)
          cxl.onclick = () => {
            if (dlgOncancel) dlgOncancel();
            closeDlg();
          };
        const ok = $("dlgOk");
        if (ok)
          ok.onclick = () => {
            const r = dlgOnok && dlgOnok();
            if (r !== false) closeDlg();
          };
        ov.onclick = (e) => {
          if (e.target === ov) {
            if (dlgOncancel) dlgOncancel();
            closeDlg();
          }
        };
        if (opts.focus && $(opts.focus)) {
          const el = $(opts.focus);
          el.focus();
          if (el.select) el.select();
        } else {
          // 默认焦点给第一个可输入控件,否则给主按钮 —— 键盘流不用先 Tab 一圈。
          const el = ov.querySelector(
            ".dlg-bd input, .dlg-bd textarea, .dlg-bd select, .dlg-bd button",
          );
          const btn = el || $("dlgOk");
          if (btn) btn.focus({ preventScroll: true });
        }
      }
      function askText(title, value, placeholder) {
        return new Promise((resolve) => {
          openDlg({
            title,
            body:
              '<input id="dlgIn" class="dlg-in" value="' +
              esc(value || "") +
              '" placeholder="' +
              esc(placeholder || "") +
              '">',
            ok: "确定",
            cancel: "取消",
            focus: "dlgIn",
            onok: () => {
              resolve($("dlgIn").value);
            },
            oncancel: () => resolve(null),
          });
          $("dlgIn").addEventListener("keydown", (e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              resolve($("dlgIn").value);
              closeDlg();
            }
          });
        });
      }
      function askYes(title, msg) {
        return new Promise((resolve) => {
          openDlg({
            title,
            body: '<p class="dlg-msg">' + esc(msg) + "</p>",
            ok: "确定",
            danger: true,
            cancel: "取消",
            onok: () => resolve(true),
            oncancel: () => resolve(false),
          });
        });
      }
      function segHtml(name, opts, cur) {
        return (
          '<div class="seg" data-seg="' +
          name +
          '">' +
          opts
            .map(
              (o) =>
                '<button type="button" data-v="' +
                esc(o.v) +
                '" class="' +
                (o.v === cur ? "on" : "") +
                '">' +
                esc(o.l) +
                "</button>",
            )
            .join("") +
          "</div>"
        );
      }
      function bindSeg(name, fn) {
        const box = document.querySelector('[data-seg="' + name + '"]');
        if (!box) return;
        box.onclick = (e) => {
          const b = e.target.closest("button");
          if (!b) return;
          for (const x of box.querySelectorAll("button")) x.classList.remove("on");
          b.classList.add("on");
          fn(b.getAttribute("data-v"));
        };
      }
      function authPanelHtml(cfg) {
        const keysFirst = [
          "deepseek",
          "openai",
          "anthropic",
          "xai",
          "openrouter",
          "groq",
          "mistral",
          "together",
          "fireworks",
          "cerebras",
          "moonshotai",
          "huggingface",
          "nvidia",
          "zai",
          "minimax",
        ];
        const src = cfg.providers || [];
        const by = {};
        src.forEach((p) => {
          by[p.name] = p;
        });
        const list = keysFirst.map((n) => by[n] || { name: n, hasKey: false });
        const oauthLabel = {
          openrouter: "Sign in with OpenRouter",
          xai: "Sign in with xAI",
          openai: "Sign in with ChatGPT",
        };
        return (
          '<div class="set-row"><div class="set-lab">API keys<span class="set-hint">Built-in providers. Paste a key and Save.</span></div></div>' +
          list
            .map((p) => {
              const oauthl = oauthLabel[p.name];
              return (
                '<div class="set-row auth-row" data-prov="' +
                esc(p.name) +
                '"><div class="set-lab">' +
                esc(p.name) +
                '<span class="set-hint">' +
                (p.hasKey ? "key set" : "no key") +
                '</span></div><div class="auth-actions"><input class="set-sel auth-key" type="password" placeholder="API key" autocomplete="off">' +
                '<button type="button" class="btn auth-save">Save</button>' +
                (oauthl ? '<button type="button" class="btn auth-oauth">' + oauthl + "</button>" : "") +
                '</div><div class="set-hint auth-dev" hidden></div></div>'
              );
            })
            .join("")
        );
      }
      function bindAuthPanel() {
        document.querySelectorAll(".auth-row").forEach((row) => {
          const name = row.getAttribute("data-prov");
          const inp = row.querySelector(".auth-key");
          const save = row.querySelector(".auth-save");
          const oauthBtn = row.querySelector(".auth-oauth");
          if (save)
            save.onclick = () => {
              const key = (inp && inp.value) || "";
              if (!key) {
                showToast("paste an API key");
                return;
              }
              fetch("/api/config", {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({ setAuth: { name, key } }),
              })
                .then((r) => r.json())
                .then((j) => {
                  showToast(j && j.ok ? "saved " + name : "save failed");
                  if (inp) inp.value = "";
                })
                .catch(() => showToast("save failed"));
            };
          if (oauthBtn)
            oauthBtn.onclick = async () => {
              const hint = row.querySelector(".auth-dev");
              try {
                const r = await fetch("/api/oauth/start", {
                  method: "POST",
                  headers: { "content-type": "application/json" },
                  body: JSON.stringify({ provider: name }),
                });
                const j = await r.json();
                if (!j || !j.ok) {
                  showToast("oauth start failed");
                  return;
                }
                if (j.user_code) {
                  if (hint) {
                    hint.hidden = false;
                    hint.textContent = "Enter code " + j.user_code + " at " + (j.verification_uri || "");
                  }
                  if (j.verification_uri) window.open(j.verification_uri, "_blank");
                  showToast("code " + j.user_code);
                } else if (j.url) {
                  window.open(j.url, "_blank");
                  showToast("finish sign-in in the new tab");
                } else {
                  showToast("oauth start failed");
                  return;
                }
                const path = j.user_code ? "/api/oauth/poll?state=" : "/api/oauth/status?state=";
                const t0 = Date.now();
                const tick = async () => {
                  if (Date.now() - t0 > 180000) {
                    showToast("oauth timed out");
                    return;
                  }
                  const s = await fetch(path + encodeURIComponent(j.state)).then((x) => x.json());
                  if (s && s.done && s.ok) {
                    showToast("signed in");
                    if (hint) hint.hidden = true;
                    return;
                  }
                  if (s && s.done && !s.ok) {
                    showToast("sign-in failed");
                    return;
                  }
                  setTimeout(tick, 1500);
                };
                setTimeout(tick, 1500);
              } catch {
                showToast("oauth start failed");
              }
            };
        });
      }
      function packageRows(data) {
        const user = data && Array.isArray(data.user) ? data.user : [];
        const proj = data && Array.isArray(data.project) ? data.project : [];
        if (!user.length && !proj.length) {
          return '<div class="set-row"><div class="set-lab">资源包<span class="set-hint">piz pkg install &lt;path&gt; [-l]</span></div></div>';
        }
        function one(p, scope) {
          return (
            '<div class="set-row"><div class="set-lab">' +
            esc(p.name || "") +
            '<span class="set-hint">' +
            scope +
            " · skills:" +
            (p.skills || 0) +
            " prompts:" +
            (p.prompts || 0) +
            (p.web ? " · web" : "") +
            "</span></div></div>"
          );
        }
        let html =
          '<div class="set-row"><div class="set-lab">资源包<span class="set-hint">用户 ~/.piz/packages 与项目 .piz/packages</span></div></div>';
        for (const p of user) html += one(p, "user");
        for (const p of proj) html += one(p, "project");
        return html;
      }
      function pluginRows(list) {
        const plugs = Array.isArray(list) ? list.filter((p) => p && p.optional) : [];
        if (!plugs.length) return "";
        let html =
          '<div class="set-row"><div class="set-lab">插件<span class="set-hint">task-delegation 才有 workflow / 子代理。开关后下一轮生效。</span></div></div>';
        for (const p of plugs) {
          html +=
            '<div class="set-row"><div class="set-lab">' +
            esc(p.name) +
            '</div><button type="button" class="sw' +
            (p.enabled ? " on" : "") +
            '" data-plugin="' +
            esc(p.name) +
            '"></button></div>';
        }
        return html;
      }
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
            segHtml("accent", [{ v: "mono", l: "墨" }, { v: "blue", l: "蓝" }], prefs.accent) +
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
        const hits = sessList.slice();
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
      let openMenu = null;
      function closeMenus() {
        for (const m of document.querySelectorAll(".menu.open"))
          m.classList.remove("open");
        openMenu = null;
      }
      function openAt(id, btn) {
        closeMenus();
        const m = $(id);
        m.classList.add("open");
        const r = btn.getBoundingClientRect();
        const mw = m.offsetWidth,
          mh = m.offsetHeight;
        m.style.left = Math.min(r.right - mw, innerWidth - mw - 8) + "px";
        m.style.top = Math.min(r.bottom + 4, innerHeight - mh - 8) + "px";
        openMenu = m;
      }
      document.addEventListener("click", (e) => {
        if (
          !e.target.closest(".menu") &&
          !e.target.closest(".ib") &&
          !e.target.closest(".perm-pill") &&
          !e.target.closest(".mode-pill") &&
          !e.target.closest(".ch-brand") &&
          !e.target.closest(".ws-chip") &&
          !e.target.closest(".ch-ws")
        )
          closeMenus();
      });
      // ---- 项目 ----
      function loadWorkspaces() {
        return fetch("/api/workspaces")
          .then((r) => r.json())
          .catch(() => []);
      }
      function projectName(root) {
        if (!root) return "";
        const parts = String(root).replace(/\/+$/, "").split("/");
        return parts[parts.length - 1] || root;
      }
      async function renderWsName() {
        const list = await loadWorkspaces();
        const cur = ws || (list[0] ? list[0].root : "");
        const nm = projectName(cur) || "piz";
        $("wsName").textContent = "piz";
        $("tbWs").textContent = nm;
        if ($("heroWsLbl")) $("heroWsLbl").textContent = nm || "选择项目";
        if ($("hWs") && !$("hWs").textContent) {
          $("hWs").textContent = nm;
          if ($("hSep")) $("hSep").style.display = nm ? "" : "none";
        }
        return list;
      }
      async function addProject() {
        const root = await askText("添加项目", "", "绝对路径，如 /home/me/proj");
        if (!root) return;
        fetch("/api/workspaces", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ root }),
        })
          .then((r) => r.json())
          .then(() => {
            location.href = sessUrl("default", root);
          })
          .catch(() => showToast("无效目录"));
      }
      async function openWsMenu(btn) {
        const list = await renderWsName();
        const cur = ws || (list[0] ? list[0].root : "");
        const m = $("wsmenu");
        m.innerHTML = "";
        for (const w of list) {
          const d = document.createElement("div");
          d.className = "mi" + (w.root === cur ? " check" : "");
          d.textContent = (w.name || projectName(w.root)) + " · " + w.root;
          d.title = w.root;
          d.onclick = () => {
            if (w.root !== cur) location.href = sessUrl("default", w.root);
          };
          m.appendChild(d);
        }
        const sep = document.createElement("div");
        sep.className = "sep";
        m.appendChild(sep);
        const add = document.createElement("div");
        add.className = "mi";
        add.textContent = "＋ 添加项目…";
        add.onclick = () => {
          closeMenus();
          addProject();
        };
        m.appendChild(add);
        openAt("wsmenu", btn);
      }
      $("wsqBtn").onclick = (e) => {
        e.stopPropagation();
        openWsMenu(e.currentTarget);
      };
      // ---- 会话列表 ----
      let sessList = [],
        archList = [],
        sessMeta = {};
      function fmtTime(ts) {
        if (!ts) return "";
        const d = new Date(ts),
          now = new Date();
        if (d.toDateString() === now.toDateString())
          return d.toTimeString().slice(0, 5);
        const y = new Date(now);
        y.setDate(y.getDate() - 1);
        if (d.toDateString() === y.toDateString()) return "昨天";
        return d.getMonth() + 1 + "月" + d.getDate() + "日";
      }
      function sessionRow(s, arch, wsRoot) {
        const d = document.createElement("div");
        const here = !ws || !wsRoot || wsRoot === ws;
        d.className =
          "se" +
          (s.name === sess && here ? " on" : "") +
          (arch ? " arch" : "");
        const title = s.name === "default" ? "默认会话" : s.title || s.name;
        d.innerHTML =
          '<div class="srow"><span class="lead">' +
          (s.busy
            ? '<span class="spin"></span>'
            : s.unread
              ? '<span class="unread-dot"></span>'
              : "") +
          '</span><span class="st">' +
          esc(title) +
          "</span>" +
          (s.status === "awaitingQuestion"
            ? '<span class="tag info">回答</span>'
            : "") +
          (s.status === "awaitingApproval"
            ? '<span class="tag warn">审批</span>'
            : "") +
          (s.status === "aborted"
            ? '<span class="tag danger">中止</span>'
            : "") +
          '<span class="sts">' +
          fmtTime(s.ts) +
          '</span><button class="kebab" title="操作">⋯</button></div>';
        d.onclick = () => {
          if (s.name === sess) {
            if (s.mode || s.auto !== undefined) {
              approvalMode = s.mode || (s.auto ? "yolo" : "ask");
              setModeBtn();
            }
            closeSheet();
          } else location.href = sessUrl(s.name, wsRoot);
        };
        const kb = d.querySelector(".kebab");
        kb.onclick = (e) => {
          e.stopPropagation();
          openSessionMenu(kb, s, arch);
        };
        return d;
      }
      function openSessionMenu(btn, s, arch) {
        const m = $("kmenu");
        m.innerHTML = "";
        if (!arch) {
          const ren = document.createElement("div");
          ren.className = "mi";
          ren.textContent = "✎ 重命名";
          ren.onclick = async () => {
            closeMenus();
            const t = await askText("重命名会话", s.title || s.name, "会话标题");
            if (t === null) return;
            act({ act: "rename", name: t }, (j) => {
              loadSessions();
              showToast(j && j.ok ? "已重命名" : "失败");
            });
          };
          m.appendChild(ren);
          const fork = document.createElement("div");
          fork.className = "mi";
          fork.textContent = "✱ 派生会话";
          fork.onclick = async () => {
            closeMenus();
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
          };
          m.appendChild(fork);
          const arc = document.createElement("div");
          arc.className = "mi";
          arc.textContent = "🗄 归档";
          arc.onclick = () => {
            closeMenus();
            act({ act: "archive" }, (j) => {
              if (j && j.ok) {
                showToast("已归档");
                if (s.name === sess)
                  setTimeout(() => (location.href = sessUrl("default")), 400);
              }
              loadSessions();
            });
          };
          m.appendChild(arc);
          const sep = document.createElement("div");
          sep.className = "sep";
          m.appendChild(sep);
        }
        const del = document.createElement("div");
        del.className = "mi danger";
        del.textContent = arch ? "永久删除" : "删除";
        del.onclick = async () => {
          closeMenus();
          if (!(await askYes("删除会话", "永久删除 " + s.name + "？"))) return;
          act({ act: "delete" }, () => {
            loadSessions();
          });
        };
        m.appendChild(del);
        if (arch) {
          const res = document.createElement("div");
          res.className = "mi";
          res.textContent = "↩ 恢复";
          res.onclick = () => {
            closeMenus();
            act({ act: "restore" }, () => {
              loadSessions();
              showToast("已恢复 " + s.name);
            });
          };
          m.prepend(res);
        }
        openAt("kmenu", btn);
      }
      function loadSessions() {
        Promise.all([
          loadWorkspaces(),
          fetch("/api/sessions?" + wsp)
            .then((r) => r.json())
            .catch(() => []),
        ])
          .then(([projects, list]) => {
            sessList = list.filter((s) => !s.archived);
            archList = list.filter((s) => s.archived);
            sessMeta = {};
            for (const s of list) sessMeta[s.name] = s;
            const sl = $("slist");
            sl.innerHTML = "";
            const q = ((searchQ && searchQ.value) || "").toLowerCase();
            const show = (s) =>
              !q || (s.name + (s.title || "")).toLowerCase().includes(q);
            const cur = ws || (projects[0] ? projects[0].root : "");
            const lab = document.createElement("div");
            lab.className = "side-lab";
            lab.textContent = "项目";
            sl.appendChild(lab);
            if (!projects.length) {
              const empty = document.createElement("div");
              empty.className = "sg-name";
              empty.style.padding = "6px 8px";
              empty.textContent = "当前目录";
              sl.appendChild(empty);
            }
            for (const w of projects) {
              const isCur = w.root === cur;
              const gh = document.createElement("div");
              gh.className = "sg-head" + (isCur ? " on" : "");
              gh.title = w.root;
              gh.innerHTML =
                '<span class="sg-chev' +
                (isCur ? " open" : "") +
                '">▶</span><span class="sg-name">' +
                esc(w.name || projectName(w.root)) +
                "</span>" +
                (isCur
                  ? '<span class="sg-cnt">' + sessList.length + "</span>"
                  : "");
              sl.appendChild(gh);
              if (isCur) {
                const wrap = document.createElement("div");
                wrap.className = "sg-chats";
                const vis = sessList.filter(show);
                if (!vis.length && q) {
                  const ne = document.createElement("div");
                  ne.className = "sg-name";
                  ne.textContent = "无匹配会话";
                  wrap.appendChild(ne);
                } else if (!vis.length) {
                  const ne = document.createElement("div");
                  ne.className = "sg-name";
                  ne.textContent = "还没有会话,发一条消息开始";
                  wrap.appendChild(ne);
                }
                for (const s of vis) wrap.appendChild(sessionRow(s, false, w.root));
                if (archList.length) {
                  const se = document.createElement("div");
                  se.className = "sg-arch";
                  se.textContent = "归档 " + archList.length;
                  wrap.appendChild(se);
                  for (const s of archList)
                    wrap.appendChild(sessionRow(s, true, w.root));
                }
                sl.appendChild(wrap);
                gh.onclick = () => {
                  const open = gh
                    .querySelector(".sg-chev")
                    .classList.toggle("open");
                  wrap.style.display = open ? "" : "none";
                };
              } else {
                gh.onclick = () => {
                  location.href = sessUrl("default", w.root);
                };
              }
            }
            const addp = document.createElement("button");
            addp.className = "btn-add-proj";
            addp.type = "button";
            addp.innerHTML = '<span class="pl">＋</span><span>添加项目</span>';
            addp.onclick = () => addProject();
            sl.appendChild(addp);
            const sb = $("sbody");
            if (sb) {
              sb.innerHTML = "";
              for (const s of sessList) sb.appendChild(sessionRow(s, false, cur));
              if (!sessList.length && !archList.length) {
                const ne2 = document.createElement("div");
                ne2.className = "sg-name";
                ne2.style.padding = "12px 14px";
                ne2.textContent = "还没有会话,发一条消息开始";
                sb.appendChild(ne2);
              }
              if (archList.length) {
                const se2 = document.createElement("div");
                se2.className = "sg-sep";
                sb.appendChild(se2);
                const sh = document.createElement("div");
                sh.className = "sg-arch";
                sh.textContent = "归档 " + archList.length;
                sb.appendChild(sh);
                for (const s of archList)
                  sb.appendChild(sessionRow(s, true, cur));
              }
            }
          })
          .catch(() => showToast("sessions load failed"));
      }
      const searchQ = document.createElement("input");
      searchQ.id = "searchQ";
      $("searchBtn").onclick = () => openSearch();
      // ---- 会话操作 ----
      function act(body, then) {
        fetch("/api/action?" + wsp + "session=" + encodeURIComponent(sess), {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(body),
        })
          .then((r) => r.json())
          .then((j) => {
            if (then) then(j);
          })
          .catch(() => showToast("action failed"));
      }
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
      function fmtTok(n) {
        n = +n || 0;
        if (n >= 1e6) return (n / 1e6).toFixed(n % 1e6 ? 1 : 0) + "M";
        if (n >= 1000) return (n / 1000).toFixed(n % 1000 ? 1 : 0) + "k";
        return String(Math.round(n));
      }
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
      // ---- 渲染 ----
      const th = $("thread");
      let stick = true;
      $("panes").addEventListener("scroll", () => {
        const p = $("panes");
        stick = p.scrollHeight - p.scrollTop - p.clientHeight < 80;
      });
      function scrl() {
        if (replayQuiet) return;
        if (stick) $("panes").scrollTop = $("panes").scrollHeight;
      }
      let replayQuiet = false;
      let webFindQ = "",
        webFindIdx = -1;
      async function findInThread(q, reverse, retried) {
        q = String(q || "").trim();
        if (!q) return false;
        if (q !== webFindQ) {
          webFindQ = q;
          webFindIdx = reverse ? 1e9 : -1;
        }
        const nodes = th.querySelectorAll(".u-bub, .md, .p, .bb-pad");
        const hits = [];
        const low = q.toLowerCase();
        nodes.forEach((el) => {
          if ((el.textContent || "").toLowerCase().indexOf(low) >= 0) hits.push(el);
        });
        th.querySelectorAll(".find-hit").forEach((e) => e.classList.remove("find-hit"));
        if (!hits.length) {
          if (!retried && histStart > 0) {
            await loadOlder();
            return findInThread(q, reverse, true);
          }
          return false;
        }
        if (reverse) webFindIdx = (webFindIdx - 1 + hits.length) % hits.length;
        else webFindIdx = (webFindIdx + 1) % hits.length;
        const el = hits[webFindIdx];
        el.classList.add("find-hit");
        el.scrollIntoView({ block: "center", behavior: "smooth" });
        return true;
      }
      document.addEventListener("keydown", (ev) => {
        if (ev.key !== "F3" || !webFindQ) return;
        ev.preventDefault();
        findInThread(webFindQ, ev.shiftKey);
      });
      let histStart = 0,
        histTotal = 0;
      function paintHistMore() {
        let b = $("hist-more");
        if (!b) {
          b = document.createElement("button");
          b.id = "hist-more";
          b.className = "hist-more";
          b.type = "button";
          b.onclick = loadOlder;
          th.insertBefore(b, th.firstChild);
        } else if (th.firstChild !== b) th.insertBefore(b, th.firstChild);
        const n = histStart;
        b.hidden = n <= 0;
        b.textContent = n > 0 ? "↑ 更早 " + n + " 条" : "";
      }
      function replayHist(items, prepend) {
        if (!items || !items.length) return;
        hideWelcome();
        const saved = [];
        if (prepend) {
          const more = $("hist-more");
          while (th.firstChild) {
            const n = th.firstChild;
            th.removeChild(n);
            if (n !== more) saved.push(n);
          }
        }
        replayQuiet = true;
        try {
          for (const h of items) {
            const text = histText(h.content);
            if (h.role === "user") {
              finishRsn();
              finishWork();
              lastUser = text;
              addUser(h.has_image && !text ? "[image]" : h.has_image ? text + "  [image]" : text, h.image_file ? "/api/image?name=" + encodeURIComponent(h.image_file) : null);
            } else if (h.role === "assistant") {
              const rsn = histText(h.reasoning);
              if (rsn) addRsn(rsn);
              if (text) {
                finishRsn();
                const e = asstEl().querySelector(".md");
                e.textContent = text;
                finishAsst();
              }
            } else if (h.role === "system") {
              continue;
            } else {
              const name = h.name || "tool";
              const args = h.args || "";
              if (isWorkflow(name, args, text)) Flow.upsert(args, text);
              else {
                addTool(name, args);
                toolDone(name, false, text);
              }
            }
          }
          finishWork();
        } finally {
          replayQuiet = false;
        }
        if (prepend) {
          for (const n of saved) th.appendChild(n);
        }
        paintHistMore();
      }
      async function loadOlder() {
        if (histStart <= 0) return;
        const lim = 80;
        const off = Math.max(0, histStart - lim);
        const take = histStart - off;
        const r = await fetch(
          "/api/history?" + wsp + "session=" + encodeURIComponent(sess) + "&offset=" + off + "&limit=" + take,
        );
        if (!r.ok) return;
        const j = await r.json();
        const panes = $("panes");
        const oldH = panes.scrollHeight;
        replayHist(j.history || [], true);
        histStart = j.start ?? off;
        histTotal = j.total ?? histTotal;
        paintHistMore();
        panes.scrollTop += panes.scrollHeight - oldH;
      }
      let curAsst = null,
        rsnEl = null,
        undoBtn = null;
      let workEl = null;
      let workCounts = { read: 0, search: 0, edit: 0, bash: 0, web: 0, mcp: 0, todo: 0, agent: 0, other: 0 };
      function ico(kind) {
        const p = {
          think:
            '<circle cx="8" cy="6.5" r="4"/><path d="M6 11.2h4M6.4 13h3.2M8 2.2v-1M3.2 6.5h-1M13.8 6.5h1"/>',
          read: '<path d="M3 2.6h6.6L13 6v7.4H3z"/><path d="M9.4 2.6V6H13"/>',
          search: '<circle cx="7" cy="7" r="4"/><path d="M10.1 10.1L14 14"/>',
          bash: '<rect x="2.4" y="3.2" width="11.2" height="9.6" rx="1.2"/><path d="M5 6.4l2 1.6-2 1.6M8.4 10.2h3"/>',
          edit: '<path d="M9.2 2.8l4 4L6 14H2v-4z"/>',
          web: '<circle cx="8" cy="8" r="5.6"/><path d="M2.4 8h11.2M8 2.4c2 2.4 2 8.8 0 11.2M8 2.4c-2 2.4-2 8.8 0 11.2"/>',
          mcp: '<path d="M6 3.2h4v2.6h2.8v4H10v2.8H6v-2.8H3.2v-4H6z"/>',
          todo: '<rect x="3" y="3" width="10" height="10" rx="2"/><path d="M5.4 8.1l1.8 1.8 3.5-3.7"/>',
          agent: '<circle cx="8" cy="5.6" r="2.3"/><path d="M3.4 13c.5-2.3 2.3-3.5 4.6-3.5s4.1 1.2 4.6 3.5"/>',
          tool: '<path d="M10.2 2.6l3.2 3.2-2 1-2.4 2.4-1.6-1.6 2.4-2.4zM3 13l4-4"/>',
        };
        return (
          '<svg class="ico" viewBox="0 0 16 16" aria-hidden="true">' +
          (p[kind] || p.tool) +
          "</svg>"
        );
      }
      function icoKind(name) {
        const k = workKind(name);
        return k === "other" ? "tool" : k;
      }
      let turnAt = 0;
      function noteTurn() {
        if (!turnAt) turnAt = Date.now();
      }
      function workKind(name) {
        const n = String(name || "");
        if (n === "read" || n === "read_image") return "read";
        if (/^(grep|find|ls)$/.test(n)) return "search";
        if (/^(edit|write|multi_edit|apply_patch)$/.test(n)) return "edit";
        if (n === "bash" || n === "exec") return "bash";
        if (/^(web_search|fetch_url|webfetch|web_fetch|search_web|browse)$/.test(n) || /web/i.test(n))
          return "web";
        if (/^mcp/i.test(n) || /mcp/i.test(n)) return "mcp";
        if (/^todo_/.test(n)) return "todo";
        if (/^(task|workflow|spawn_agent|wait_agent|send_agent|read_agent|close_agent|list_agents)$/.test(n))
          return "agent";
        return "other";
      }
      function workBitsHtml(live) {
        const bits = [];
        if (workCounts.read) bits.push(ico("read") + "<span>" + nunit(workCounts.read, "file") + "</span>");
        if (workCounts.search) bits.push(ico("search") + "<span>" + nunit(workCounts.search, "search", "searches") + "</span>");
        if (workCounts.web) bits.push(ico("web") + "<span>" + nunit(workCounts.web, "web") + "</span>");
        if (workCounts.mcp) bits.push(ico("mcp") + "<span>" + nunit(workCounts.mcp, "MCP") + "</span>");
        if (workCounts.bash) bits.push(ico("bash") + "<span>" + nunit(workCounts.bash, "command") + "</span>");
        if (workCounts.edit) bits.push(ico("edit") + "<span>" + nunit(workCounts.edit, "edit") + "</span>");
        if (workCounts.todo) bits.push(ico("todo") + "<span>" + nunit(workCounts.todo, "plan") + "</span>");
        if (workCounts.agent) bits.push(ico("agent") + "<span>" + nunit(workCounts.agent, "agent") + "</span>");
        if (workCounts.other) bits.push(ico("tool") + "<span>" + nunit(workCounts.other, "tool") + "</span>");
        if (!bits.length) return live ? "Working" : "Worked";
        return bits.map((b) => '<span class="work-chip">' + b + "</span>").join('<span class="work-dot">·</span>');
      }
      function refreshWorkSum(live) {
        if (!workEl) return;
        const sum = workEl.querySelector(".work-sum");
        const bits = sum.querySelector(".work-bits") || sum;
        bits.innerHTML = workBitsHtml(live);
        sum.classList.toggle("edit", !live && workCounts.edit > 0);
      }
      function ensureWork() {
        if (workEl && workEl.isConnected) return workEl;
        const el = document.createElement("div");
        el.className = "work live";
        el.innerHTML =
          '<button type="button" class="work-sum"><span class="work-caret">▸</span><span class="work-bits">Working</span></button><div class="work-list"></div>';
        el.querySelector(".work-sum").onclick = () => el.classList.toggle("open");
        th.appendChild(el);
        workEl = el;
        workCounts = { read: 0, search: 0, edit: 0, bash: 0, web: 0, mcp: 0, todo: 0, agent: 0, other: 0 };
        return workEl;
      }
      const Flow = {
        el: null,
        id: "",
        goal: "",
        nodes: [],
        args: "",
        out: "",
        done: false,
        openId: "",
        ident(args, out) {
          const o = parseToolArgs(args);
          const gm = /^Workflow\s+"([^"]+)"/.exec(String(out || ""));
          const goal = (o.goal && String(o.goal)) || (gm && gm[1]) || "";
          const ids = (Array.isArray(o.nodes) ? o.nodes.map((n) => n && n.id) : this.nodesFrom(out).map((n) => n.id))
            .filter(Boolean)
            .join(">");
          return { goal, ids };
        },
        nodesFrom(out) {
          const nodes = [];
          const re = /===\s+([A-Za-z][A-Za-z0-9_-]*)\b(?:\s+\(([^)]+)\))?\s+(ok|FAILED|skipped)/g;
          let m;
          while ((m = re.exec(String(out || "")))) {
            nodes.push({
              id: m[1],
              role: m[2] || "",
              needs: [],
              st: m[3] === "ok" ? "ok" : m[3] === "FAILED" ? "fail" : "skip",
              last: "",
              body: "",
              idx: nodes.length + 1,
            });
          }
          return nodes;
        },
        slice(out, id) {
          if (!out || !id) return "";
          const re = new RegExp("===\\s+" + id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\b[^\\n]*===\\n");
          const m = re.exec(out);
          if (!m) return "";
          const rest = out.slice(m.index + m[0].length);
          const next = rest.search(/\n===\s+/);
          return (next < 0 ? rest : rest.slice(0, next)).trim();
        },
        parse(args, out) {
          const o = parseToolArgs(args);
          let nodes = (Array.isArray(o.nodes) ? o.nodes : [])
            .map((n, i) => ({
              id: String((n && n.id) || ""),
              role: (n && n.role) || "",
              needs: Array.isArray(n && n.needs) ? n.needs : [],
              st: "wait",
              last: "",
              body: "",
              idx: i + 1,
            }))
            .filter((n) => n.id);
          if (!nodes.length) nodes = this.nodesFrom(out);
          let goal = o.goal ? String(o.goal) : "";
          if (!goal) {
            const gm = /^Workflow\s+"([^"]+)"/.exec(String(out || ""));
            if (gm) goal = gm[1];
          }
          return { goal, nodes };
        },
        same(a, b) {
          if (a.goal && b.goal) return a.goal === b.goal;
          if (a.ids && b.ids) return a.ids === b.ids;
          return false;
        },
        applyOut(out) {
          if (!out) return;
          this.out = out;
          for (const e of this.nodesFrom(out)) {
            let n = this.nodes.find((x) => x.id === e.id);
            if (!n) {
              e.idx = this.nodes.length + 1;
              this.nodes.push(e);
              n = e;
            } else {
              n.st = e.st;
              if (e.role && !n.role) n.role = e.role;
            }
            n.body = this.slice(out, n.id);
          }
        },
        queue() {
          if (!pendingByName.workflow) pendingByName.workflow = [];
          if (this.id && !pendingByName.workflow.includes(this.id)) pendingByName.workflow.push(this.id);
        },
        upsert(args, out) {
          const parsed = this.parse(args, out);
          const want = this.ident(args, out);
          if (this.el && this.el.isConnected && this.same(want, this.ident(this.args, this.out))) {
            if (args) this.args = args;
            if (parsed.goal) this.goal = parsed.goal;
            if (parsed.nodes.length && !this.nodes.length) this.nodes = parsed.nodes;
            if (out) {
              this.applyOut(out);
              this.done = true;
              if (cards[this.id]) {
                cards[this.id].out = this.out;
                cards[this.id].done = true;
                cards[this.id].args = this.args;
              }
            } else if (!this.done) this.queue();
            this.paint();
            return this.id;
          }
          finishWork();
          seq++;
          this.id = "t" + seq;
          this.args = args || "";
          this.goal = parsed.goal;
          this.nodes = parsed.nodes;
          this.out = out || "";
          this.done = !!out;
          this.openId = "";
          if (out) this.applyOut(out);
          this.el = document.createElement("section");
          this.el.className = "flow";
          this.el.id = this.id;
          this.el.dataset.ty = "agent";
          th.appendChild(this.el);
          cards[this.id] = {
            el: this.el,
            name: "workflow",
            ty: "agent",
            args: this.args,
            out: this.out,
            done: this.done,
          };
          if (!this.done) this.queue();
          this.paint();
          curAsst = null;
          scrl();
          return this.id;
        },
        event(idx, kind, text) {
          if (!this.el || !this.el.isConnected || this.done) return false;
          let n = kind === "notice" && text ? this.nodes.find((x) => x.id === text) : null;
          if (!n) n = this.nodes.find((x) => x.idx === Number(idx));
          if (!n) return false;
          if (kind === "notice") n.st = n.st === "wait" ? "run" : n.st;
          else if (kind === "tool_start") {
            n.st = "run";
            n.last = text || n.last;
          } else if (kind === "tool_done") n.last = text || n.last;
          else if (kind === "finished") n.st = n.st === "fail" ? "fail" : "ok";
          else if (kind === "tool_failed") n.st = "fail";
          this.paint();
          return true;
        },
        finish(out) {
          this.applyOut(out);
          this.done = true;
          if (cards[this.id]) {
            cards[this.id].out = this.out;
            cards[this.id].done = true;
          }
          this.paint();
        },
        nodeHtml(n) {
          const open = this.openId === n.id && n.body;
          const act = n.st === "run" ? n.last || "running" : n.st === "fail" ? "fail" : n.st === "skip" ? "skip" : "";
          return (
            '<li class="flow-n ' +
            n.st +
            (open ? " open" : "") +
            '" data-id="' +
            esc(n.id) +
            '"><i class="flow-dot"></i><div class="flow-main"><div class="flow-row"><b>' +
            esc(n.id) +
            "</b>" +
            (n.role ? "<em>" + esc(n.role) + "</em>" : "") +
            (act ? '<span class="flow-act">' + esc(act) + "</span>" : "") +
            "</div>" +
            (open ? '<pre class="flow-body">' + esc(n.body) + "</pre>" : "") +
            "</div></li>"
          );
        },
        paint() {
          if (!this.el) return;
          const doneN = this.nodes.filter((n) => n.st === "ok" || n.st === "fail" || n.st === "skip").length;
          const meta = this.nodes.length ? doneN + "/" + this.nodes.length : "";
          this.el.classList.toggle("done", this.done);
          this.el.innerHTML =
            '<div class="flow-hd"><span class="flow-k">workflow</span>' +
            (this.goal ? '<div class="flow-goal">' + esc(this.goal) + "</div>" : "") +
            (meta ? '<div class="flow-meta">' + esc(meta) + "</div>" : "") +
            '</div><ol class="flow-list">' +
            this.nodes.map((n) => this.nodeHtml(n)).join("") +
            "</ol>";
          const hd = this.el.querySelector(".flow-hd");
          if (hd) hd.onclick = () => inspect.open(this.el);
          this.el.querySelectorAll(".flow-n").forEach((li) => {
            li.onclick = (e) => {
              e.stopPropagation();
              const id = li.getAttribute("data-id");
              this.openId = this.openId === id ? "" : id;
              this.paint();
            };
          });
          if (inspect.src === this.id) inspect.paint(this.el);
        },
        html() {
          return this.el ? this.el.innerHTML : "";
        },
      };
      function isWorkflow(name, args, out) {
        if (name === "workflow") return true;
        const o = parseToolArgs(args);
        if (Array.isArray(o.nodes) && o.nodes.length) return true;
        return /^Workflow\b/.test(String(out || ""));
      }



      function addSub(idx, kind, text) {
        if (Flow.event(idx, kind, text)) return;
        const w = workEl && workEl.isConnected ? workEl : ensureWork();
        let log = w.querySelector(".sub-log");
        if (!log) {
          log = document.createElement("div");
          log.className = "sub-log";
          w.appendChild(log);
        }
        const row = document.createElement("div");
        row.className = "sub-i " + String(kind || "");
        const tag =
          kind === "tool_start"
            ? "tool"
            : kind === "tool_done"
              ? "ok"
              : kind === "tool_failed"
                ? "err"
                : kind === "finished"
                  ? "done"
                  : kind === "notice"
                    ? "piz"
                    : String(kind || "-");
        const ix = document.createElement("span");
        ix.className = "sub-idx";
        ix.textContent = String(idx);
        const k = document.createElement("span");
        k.className = "sub-k";
        k.textContent = tag;
        const tx = document.createElement("span");
        tx.className = "sub-t";
        tx.textContent = text || "";
        row.append(ix, k, tx);
        log.appendChild(row);
        while (log.children.length > 48) log.removeChild(log.firstChild);
        scrl();
      }
      function finishWork() {
        if (!workEl) return;
        workEl.querySelectorAll(".tcall:not(.done):not(.err)").forEach((d) => {
          d.classList.add("done");
          const g = d.querySelector(".st-glyph");
          if (g) {
            g.className = "st-glyph ok";
            g.textContent = "✓";
          }
        });
        refreshWorkSum(false);
        workEl.classList.remove("live");
        workEl.classList.remove("open");
        workEl = null;
      }
      function stampTurn() {
        if (!turnAt) return;
        const sec = Math.max(1, Math.round((Date.now() - turnAt) / 1000));
        turnAt = 0;
        const label =
          sec < 60
            ? "用了 " + sec + "s"
            : "用了 " + Math.floor(sec / 60) + "m " + (sec % 60) + "s";
        const host =
          th.querySelector(".a-turn:last-of-type") ||
          th.querySelector(".work:last-of-type");
        if (!host || host.querySelector(".a-meta")) return;
        const m = document.createElement("div");
        m.className = "a-meta";
        m.textContent = label;
        host.prepend(m);
      }
      function pruneTranscript() {
        const kids = [...th.querySelectorAll(":scope > .u-turn, :scope > .a-turn")];
        const cap = 200;
        if (kids.length <= cap) return;
        const drop = kids.length - cap + 32;
        for (let i = 0; i < drop; i++) kids[i].remove();
        const more = $("hist-more");
        if (more) more.hidden = false;
      }
      function addUser(txt, imgSrc) {
        hideWelcome();
        finishWork();
        noteTurn();
        pruneTranscript();
        const t = document.createElement("div");
        t.className = "u-turn";
        t.innerHTML =
          '<div class="u-bub"></div><div class="u-ops"><button type="button" class="copy-chip" title="复制">⧉</button><button type="button" class="undo-chip" title="撤销">↶</button></div>';
        const bub = t.querySelector(".u-bub");
        if (imgSrc) {
          const im = document.createElement("img");
          im.className = "u-img";
          im.alt = "image";
          im.src = imgSrc;
          bub.appendChild(im);
        }
        const shown = String(txt || "").replace(/\s*\[image\]\s*$/, "").replace(/^\[image\]$/, "");
        if (shown) {
          const s = document.createElement("span");
          s.textContent = shown;
          bub.appendChild(s);
        } else if (!imgSrc) {
          bub.textContent = txt || "";
        }
        const rawUser = shown || txt || "";
        t.querySelector(".copy-chip").onclick = () => clipText(rawUser, "已复制", "复制失败");
        t.querySelector(".undo-chip").onclick = () => {
          act({ act: "undo" }, (j) => {
            showToast(j && j.ok ? "已撤销" : "无可撤销");
            setTimeout(() => location.reload(), 400);
          });
        };
        th.appendChild(t);
        scrl();
        curAsst = null;
      }
      function asstEl() {
        if (!curAsst) {
          curAsst = document.createElement("div");
          curAsst.className = "a-turn";
          curAsst.innerHTML = '<div class="a-msg"><div class="md"></div></div>';
          th.appendChild(curAsst);
          scrl();
        }
        return curAsst;
      }
      let mdTimer = 0;
      function closeFences(s) {
        const n = (s.match(/```/g) || []).length;
        return n % 2 ? s + "\n```" : s;
      }
      function paintAsst(final) {
        if (!curAsst) return;
        const e = curAsst.querySelector(".md");
        if (!e) return;
        const raw = e.dataset.raw || "";
        // 未变不画 —— 流式期 dataset.raw 涨但定时器空跑时省一次全量重排。
        if (!final && e.dataset.painted === String(raw.length)) return;
        e.dataset.painted = String(raw.length);
        e.innerHTML = md(final ? raw : closeFences(raw));
        scrl();
      }
      function addAsst(txt) {
        if (!txt) return;
        const e = asstEl().querySelector(".md");
        e.dataset.raw = (e.dataset.raw || "") + txt;
        if (!mdTimer) {
          // 自适应节流:回复越长全量重排越贵,间隔跟着涨(80→160→280ms)。
          const n = e.dataset.raw.length;
          const iv = n > 20000 ? 280 : n > 5000 ? 160 : 80;
          mdTimer = setTimeout(() => {
            mdTimer = 0;
            paintAsst(false);
          }, iv);
        }
        scrl();
      }
      function finishAsst() {
        if (mdTimer) {
          clearTimeout(mdTimer);
          mdTimer = 0;
        }
        if (curAsst) {
          const e = curAsst.querySelector(".md");
          const raw = e.dataset.raw || e.textContent;
          e.dataset.raw = raw;
          e.dataset.painted = String(raw.length);
          e.innerHTML = md(raw);
          if (!curAsst.querySelector(".a-ops")) {
            const ops = document.createElement("div");
            ops.className = "a-ops";
            ops.innerHTML =
              '<button type="button" class="copy-a" title="复制">⧉</button>' +
              (lastUser ? '<button type="button" class="redo-a" title="重新生成">↻</button>' : "");
            ops.querySelector(".copy-a").onclick = () => clipText(raw, "已复制", "复制失败");
            const redo = ops.querySelector(".redo-a");
            if (redo) redo.onclick = () => sendPlain(lastUser);
            curAsst.appendChild(ops);
          }
          pluginEmit("message-rendered", {
            role: "assistant",
            text: raw,
            element: e,
          });
          curAsst = null;
        }
      }
      function nunit(n, one, many) {
        const w = n === 1 ? one : many || one + "s";
        return n + " " + w;
      }
      function addRsn(txt) {
        if (!txt) return;
        if (!rsnEl) {
          const el = document.createElement("div");
          el.className = "think";
          el.innerHTML =
            '<button type="button" class="think-sum"><span class="work-caret">▸</span>' +
            ico("think") +
            '<span class="think-txt">Thinking</span></button><pre class="tk"></pre>';
          el.querySelector(".think-sum").onclick = () => el.classList.toggle("open");
          th.appendChild(el);
          rsnEl = el;
          scrl();
        }
        const tc = rsnEl.querySelector(".tk");
        if (tc.textContent) tc.textContent += "\n\n";
        tc.textContent += txt;
        scrl();
        if (inspect.thinkEl === rsnEl && $("inspect") && !$("inspect").hidden) inspect.openThink(rsnEl);
      }
      function finishRsn() {
        if (!rsnEl) return;
        const txt = rsnEl.querySelector(".think-txt");
        if (txt) txt.textContent = "Thought";
        rsnEl = null;
      }
      // 工具卡
      const cards = {};
      let seq = 0;
      const pendingByName = {};
      function toolType(n) {
        if (/^(bash|exec|sh|git|cmd|powershell)$/.test(n)) return "term";
        if (/^(edit|write|apply_patch)$/.test(n)) return "diff";
        if (/^(read|skill|show)$/.test(n)) return "code";
        if (/^todo_/.test(n)) return "todo";
        if (/^(task|workflow|spawn_agent|wait_agent|send_agent|read_agent|close_agent|list_agents)$/.test(n))
          return "agent";
        return "sum";
      }
      function parseToolArgs(raw) {
        if (!raw) return {};
        if (typeof raw === "object") return raw;
        try {
          const o = JSON.parse(raw);
          return o && typeof o === "object" ? o : {};
        } catch {
          return {};
        }
      }
      function argsPreview(raw) {
        const o = parseToolArgs(raw);
        const s = o.command || o.path || o.pattern || o.query || raw || "";
        return String(s).slice(0, 140);
      }
      const inspect = {
        src: "",
        kind(d) {
          if (!d) return "Tool";
          const ty = d.dataset.ty;
          if (ty === "diff") return "Diff";
          if (ty === "code") return "File";
          if (ty === "term") return "Output";
          if (ty === "todo") return "Plan";
          if (ty === "agent") return (cards[d.id] && cards[d.id].name) === "workflow" ? "Workflow" : "Agent";
          const n = (cards[d.id] && cards[d.id].name) || "";
          if (/^(ls|find)$/.test(n)) return "List";
          if (/^(grep|search)$/.test(n)) return "Search";
          return n || "Output";
        },
        pathOf(d) {
          const c = cards[d.id];
          if (!c) return "";
          const o = parseToolArgs(c.args);
          return String(o.path || o.file || "");
        },
        title(d) {
          const p = this.pathOf(d);
          if (p) return p.split(/[/\\]/).pop() || p;
          const c = cards[d.id];
          if (!c) return "Inspect";
          const o = parseToolArgs(c.args);
          if (c.name === "workflow") return String(o.goal || "workflow");
          return String(o.command || c.name || "Inspect");
        },
        workEl: null,
        setHead(k, t) {
          const hk = $("inspK");
          const ht = $("inspT");
          if (ht) {
            ht.textContent = t || k || "";
            ht.title = t || k || "";
          }
          if (hk) {
            hk.textContent = k && k !== t ? k : "";
            hk.hidden = !hk.textContent;
          }
        },
        show() {
          const el = $("inspect");
          if (el) el.hidden = false;
        },
        open(d) {
          if (!d) return;
          this.workEl = null;
          if (this.src && cards[this.src]) cards[this.src].el.classList.remove("watching");
          this.src = d.id;
          d.classList.add("watching");
          this.show();
          this.paintInto(d, $("inspBd"));
        },
        thinkEl: null,
        openThink(el) {
          if (!el) return;
          this.workEl = null;
          this.thinkEl = el;
          this.src = "";
          this.show();
          this.setHead("Thought", "Thought");
          const txt = el.querySelector(".tk");
          const box = document.createElement("div");
          box.className = "insp-think";
          box.textContent = txt ? txt.textContent : "";
          const host = $("inspBd");
          if (host) host.replaceChildren(box);
        },

        close() {
          const el = $("inspect");
          if (!el) return;
          if (this.src && cards[this.src]) cards[this.src].el.classList.remove("watching");
          this.src = "";
          this.workEl = null;
          this.thinkEl = null;
          el.hidden = true;
          const bd = $("inspBd");
          if (bd) bd.innerHTML = "";
        },
        async paintInto(d, host) {
          if (!d || !host) return;
          const c = cards[d.id];
          this.setHead(this.kind(d), this.title(d));
          if (c && !c.done) {
            if (c.name === "workflow" || d.classList.contains("flow")) {
              host.innerHTML = '<div class="flow">' + Flow.html() + "</div>";
              return;
            }
            host.innerHTML = '<div class="insp-wait">Running…</div>';
            return;
          }
          let out = (c && c.out) || "";
          const path = this.pathOf(d);
          if (path && d.dataset.ty === "code") {
            try {
              const r = await fetch("/api/file?" + wsp + "path=" + encodeURIComponent(path));
              if (r.ok) {
                const j = await r.json();
                if (j && j.text) out = j.text;
              }
            } catch {}
          }
          if (!out) {
            host.innerHTML = '<div class="insp-wait">No output.</div>';
            return;
          }
          d.dataset.out = out;
          host.replaceChildren(toolBody(d.dataset.ty || "code", out, path, c && c.args));
        },
        paint(d) {
          this.paintInto(d, $("inspBd"));
        },
        init() {
          const x = $("inspX");
          if (x) x.onclick = () => inspect.close();
        },
      };
      function addTool(name, args) {
        if (isWorkflow(name, args)) return Flow.upsert(args, "");
        seq++;
        const id = "t" + seq;
        const ty = toolType(name);
        const d = document.createElement("div");
        d.className = "tcall";
        d.id = id;
        d.dataset.ty = ty;
        d.innerHTML =
          '<div class="bh">' +
          ico(icoKind(name)) +
          '<span class="a">' +
          esc(name) +
          '</span><span class="p">' +
          esc(argsPreview(args)) +
          '</span><span class="rt"><span class="st-glyph run"></span></span></div><div class="bb"><div class="bb-pad"></div></div>';
        d.querySelector(".bh").onclick = () => inspect.open(d);
        const w = ensureWork();
        workCounts[workKind(name)]++;
        refreshWorkSum(true);
        w.querySelector(".work-list").appendChild(d);
        scrl();
        cards[id] = { el: d, name, ty, args: args || "", out: "", done: false };
        (pendingByName[name] || (pendingByName[name] = [])).push(id);
        curAsst = null;
        return id;
      }
      function toolIcon(n) {
        if (/^(edit|write|apply_patch)$/.test(n)) return "✎";
        if (/^(read|skill|show)$/.test(n)) return "≡";
        if (n === "bash" || n === "exec") return "$";
        return "⚙";
      }
      function artifactName(out) {
        const m = /\[Artifact stored: ([^\]\n]+?) \((\d+) bytes\)\]/.exec(out || "");
        if (!m) return null;
        const base = m[1].split(/[/\\]/).pop() || "";
        return /^[\w.-]+$/.test(base) ? base : null;
      }
      async function fillTool(d) {
        const ty = d.dataset.ty || "sum";
        let out = d.dataset.out || "";
        const art = artifactName(out);
        if (art && !d.dataset.full) {
          try {
            const r = await fetch("/api/artifact?name=" + encodeURIComponent(art));
            const j = await r.json();
            if (j && j.ok && typeof j.text === "string") {
              d.dataset.full = "1";
              d.dataset.out = j.text;
              out = j.text;
            }
          } catch {}
        }
        const bd = d.querySelector(".bb-pad");
        const card = cards[d.id];
        const custom = card && toolRenderers.get(card.name);
        if (custom) {
          try {
            const node = custom({
              name: card.name,
              args: card.args,
              output: out,
              error: d.classList.contains("err"),
              element: d,
            });
            if (node instanceof Node) {
              bd.replaceChildren(node);
              return;
            }
          } catch (x) {
            console.error("[piz plugin]", x);
          }
        }
        const c = cards[d.id];
        const o = c ? parseToolArgs(c.args) : {};
        bd.replaceChildren(toolBody(ty, out, String(o.path || o.file || ""), (c && c.args) || ""));
      }
      function toolDone(name, err, summary) {
        const q = pendingByName[name];
        const id = q && q.shift();
        if (!id) return;
        const c = cards[id];
        if (!c) return;
        const d = c.el;
        d.classList.add(err ? "err" : "done");
        const g = d.querySelector(".st-glyph");
        if (g) {
          g.className = "st-glyph " + (err ? "err" : "ok");
          g.textContent = err ? "✗" : "✓";
        }
        c.out = summary || "";
        c.done = true;
        d.dataset.out = c.out;
        if (name === "workflow") Flow.finish(c.out);
        if (inspect.src === id && $("inspect") && !$("inspect").hidden) inspect.paint(d);
        else if (err) inspect.open(d);
      }
      // 审批
      function addPerm(id, name, args) {
        hideWelcome();
        const d = document.createElement("div");
        d.className = "pc";
        d.dataset.pid = id;
        const o = parseToolArgs(args);
        const kind = name === "bash" ? "shell" : "file";
        let body = "";
        if (kind === "shell") {
          body =
            '<div class="body"><div class="shell-cmd"><span class="shell-dollar">$</span>' +
            esc(String(o.command || args || "").slice(0, 300)) +
            "</div></div>";
        } else
          body =
            '<div class="body"><pre class="shell-cmd">' +
            esc(String(o.path || args || "").slice(0, 300)) +
            "</pre></div>";
        d.innerHTML =
          '<div class="ah"><span class="ah-ic">?</span><span class="akind">需要许可</span><span class="apath">' +
          esc(name) +
          (o.path && kind === "shell" ? "  " + esc(String(o.path).slice(0, 80)) : "") +
          '</span><span class="aw">等待审批</span></div>' +
          body +
          '<div class="pb"><button class="ok">允许</button><button class="alw">本会话总是</button><button class="no">拒绝</button></div>';
        d.querySelector(".ok").onclick = (e) => {
          e.stopPropagation();
          appr(d, id, true, false);
        };
        d.querySelector(".alw").onclick = (e) => {
          e.stopPropagation();
          appr(d, id, true, true);
        };
        d.querySelector(".no").onclick = (e) => {
          e.stopPropagation();
          appr(d, id, false, false);
        };
        const dk = $("dock");
        dk.appendChild(d);
        scrl();
      }
      async function appr(card, id, allow, always) {
        card.querySelectorAll("button").forEach((b) => (b.disabled = true));
        try {
          if (always) await setApproval("yolo");
          const r = await fetch("/api/approve", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ id, allow }),
          });
          const j = await r.json().catch(() => ({}));
          if (!r.ok || j.ok === false) {
            showToast(j.error || "审批失败");
            card.querySelectorAll("button").forEach((b) => (b.disabled = false));
            return;
          }
          card.remove();
        } catch {
          showToast("审批失败");
          card.querySelectorAll("button").forEach((b) => (b.disabled = false));
        }
      }
      function addNotice(txt) {
        if (!txt) return;
        hideWelcome();
        const d = document.createElement("div");
        d.className = "sys-line";
        d.textContent = txt;
        th.appendChild(d);
        scrl();
      }
      function downloadText(name, text, mime) {
        const a = document.createElement("a");
        a.href = URL.createObjectURL(new Blob([text], { type: mime || "text/plain" }));
        a.download = name;
        a.click();
        setTimeout(() => URL.revokeObjectURL(a.href), 1000);
      }
      function clipText(text, ok, fail) {
        if (!text) {
          showToast(fail || "没有内容");
          return;
        }
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard
            .writeText(text)
            .then(() => showToast(ok || "已复制"))
            .catch(() => showToast(fail || "复制失败"));
        } else showToast(fail || "复制失败");
      }
      // markdown(极简:代码块+行内码+粗体)
      function md(raw) {
        const out = [];
        const re = /```(\w*)\n?([\s\S]*?)```/g;
        let last = 0,
          m;
        while ((m = re.exec(raw)) !== null) {
          if (m.index > last) out.push(mdInline(raw.slice(last, m.index)));
          out.push("<pre><code>" + esc(m[2]) + "</code></pre>");
          last = m.index + m[0].length;
        }
        if (last < raw.length) out.push(mdInline(raw.slice(last)));
        return out.join("");
      }
      const AC = {
        30: "#333",
        31: "#f85149",
        32: "#3fb950",
        33: "#d29922",
        34: "#58a6ff",
        35: "#bc8cff",
        36: "#39c5cf",
        37: "#c9d1d9",
        90: "#8b949e",
        91: "#ff7b72",
        92: "#7ee787",
        93: "#e3b341",
        94: "#79c0ff",
        95: "#d2a8ff",
        96: "#76e3ea",
        97: "#e6edf3",
      };
      function ansiHtml(t) {
        let o = "",
          last = 0,
          fg = null;
        const re = /\x1b\[([0-9;]*)m/g;
        let m;
        while ((m = re.exec(t)) !== null) {
          o += esc(t.slice(last, m.index));
          const c = m[1].split(";").filter(Boolean);
          if (c.includes("0") || c.length === 0) fg = null;
          else {
            const col = AC[c.find((x) => AC[x]) || ""];
            if (col) fg = col;
          }
          last = m.index + m[0].length;
        }
        o += esc(t.slice(last));
        return fg ? '<span style="color:' + fg + '">' + o + "</span>" : o;
      }
      function isMarkdownPath(p) {
        return /\.(md|markdown|mdx)$/i.test(p || "");
      }
      function looksLikeMd(t) {
        if (!t || t.length < 8) return false;
        return /^#{1,3}\s/m.test(t) || /```/.test(t) || /^\s*[-*]\s+\S/m.test(t);
      }
      function mdInline(s) {
        s = esc(s);
        s = s.replace(/`([^`]+)`/g, "<code>$1</code>");
        s = s.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
        s = s.replace(/(^|[^\*])\*(?!\*)([^*]+)\*(?!\*)/g, "$1<em>$2</em>");
        s = s.replace(
          /\[([^\]]+)\]\((https?:[^)\s]+)\)/g,
          '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>',
        );
        return s;
      }
      function mdBlocks(s) {
        const lines = String(s).replace(/\r\n/g, "\n").split("\n");
        let html = "";
        let i = 0;
        let para = [];
        const flushP = () => {
          if (!para.length) return;
          html += "<p>" + mdInline(para.join(" ")) + "</p>";
          para = [];
        };
        while (i < lines.length) {
          const line = lines[i];
          if (/^\s*$/.test(line)) {
            flushP();
            i++;
            continue;
          }
          const hm = /^(#{1,3})\s+(.+)$/.exec(line);
          if (hm) {
            flushP();
            html += "<h" + hm[1].length + ">" + mdInline(hm[2]) + "</h" + hm[1].length + ">";
            i++;
            continue;
          }
          if (/^---+$/.test(line.trim())) {
            flushP();
            html += "<hr/>";
            i++;
            continue;
          }
          if (/^>\s?/.test(line)) {
            flushP();
            const qs = [];
            while (i < lines.length && /^>\s?/.test(lines[i])) {
              qs.push(lines[i].replace(/^>\s?/, ""));
              i++;
            }
            html += "<blockquote>" + mdInline(qs.join(" ")) + "</blockquote>";
            continue;
          }
          if (/^\s*[-*]\s+/.test(line)) {
            flushP();
            html += "<ul>";
            while (i < lines.length && /^\s*[-*]\s+/.test(lines[i])) {
              html += "<li>" + mdInline(lines[i].replace(/^\s*[-*]\s+/, "")) + "</li>";
              i++;
            }
            html += "</ul>";
            continue;
          }
          if (/^\s*\d+\.\s+/.test(line)) {
            flushP();
            html += "<ol>";
            while (i < lines.length && /^\s*\d+\.\s+/.test(lines[i])) {
              html += "<li>" + mdInline(lines[i].replace(/^\s*\d+\.\s+/, "")) + "</li>";
              i++;
            }
            html += "</ol>";
            continue;
          }
          para.push(line);
          i++;
        }
        flushP();
        return html;
      }
      function renderMd(src) {
        const text = String(src || "");
        const re = /```(\w*)\n?([\s\S]*?)```/g;
        let html = "";
        let last = 0;
        let m;
        while ((m = re.exec(text))) {
          if (m.index > last) html += mdBlocks(text.slice(last, m.index));
          html += "<pre><code>" + esc(m[2].replace(/\n$/, "")) + "</code></pre>";
          last = m.index + m[0].length;
        }
        if (last < text.length) html += mdBlocks(text.slice(last));
        return html;
      }
      function diffHtml(t) {
        const lines = String(t || "").split("\n");
        let html = "";
        let file = "";
        for (const l of lines) {
          if (/^(edited|wrote|created)\b/i.test(l)) {
            html += '<div class="diff-meta">' + esc(l) + "</div>";
            continue;
          }
          if (l.startsWith("+++ ")) {
            file = l.slice(4).replace(/^[ab]\//, "");
            continue;
          }
          if (l.startsWith("--- ")) continue;
          if (l.startsWith("@@")) {
            html +=
              '<div class="diff-row hunk"><span class="g"></span><span class="ln">' +
              esc(l) +
              "</span></div>";
            continue;
          }
          if (l.startsWith("+")) {
            html +=
              '<div class="diff-row add"><span class="g">+</span><span class="ln">' +
              esc(l.slice(1)) +
              "</span></div>";
            continue;
          }
          if (l.startsWith("-")) {
            html +=
              '<div class="diff-row del"><span class="g">−</span><span class="ln">' +
              esc(l.slice(1)) +
              "</span></div>";
            continue;
          }
          html +=
            '<div class="diff-row"><span class="g"></span><span class="ln">' + esc(l) + "</span></div>";
        }
        if (file) html = '<div class="diff-file">' + esc(file) + "</div>" + html;
        return html;
      }
      function todoHtml(t) {
        let html = "";
        for (const l of String(t || "").split("\n")) {
          const m = /^\[([ x>X])\]\s*(.*)$/.exec(l);
          if (m) {
            const st = m[1] === "x" || m[1] === "X" ? "done" : m[1] === ">" ? "run" : "pend";
            const bm = /^(.*)\s+@([A-Za-z][A-Za-z0-9_-]*)$/.exec(m[2]);
            const tx = bm ? bm[1] : m[2];
            const bind = bm ? bm[2] : "";
            html +=
              '<div class="todo-i ' +
              st +
              '"><span class="todo-box"></span><span class="todo-tx">' +
              esc(tx) +
              (bind ? '<span class="todo-bind">@' + esc(bind) + "</span>" : "") +
              "</span></div>";
          } else if (l.trim()) {
            html += '<div class="todo-foot">' + esc(l) + "</div>";
          }
        }
        return html;
      }
      function agentHtml(out, args) {
        if (Flow.el && (Flow.out === out || Flow.args === args || parseToolArgs(args).nodes)) {
          return Flow.html();
        }
        const o = parseToolArgs(args);
        let html = "";
        const desc = o.description || o.task || o.prompt || "";
        if (desc) html += '<div class="agent-desc">' + esc(desc) + "</div>";
        if (out) html += '<pre class="code">' + esc(out) + "</pre>";
        return html;
      }
      function toolBody(ty, out, path, args) {
        const text = String(out || "");
        if (ty === "term") {
          const pre = document.createElement("pre");
          pre.className = "term";
          // 与 code 同帽:超长输出别让 ansi 逐字扫拖住主线程。
          const capped = text.length > 32000 ? text.slice(0, 32000) + "\n…" : text;
          pre.innerHTML = ansiHtml(capped);
          return pre;
        }
        if (ty === "diff") {
          const box = document.createElement("div");
          box.className = "diff-view";
          box.innerHTML = diffHtml(text);
          return box;
        }
        if (ty === "todo") {
          const box = document.createElement("div");
          box.className = "todo-view";
          box.innerHTML = todoHtml(text);
          return box;
        }
        if (ty === "agent") {
          const box = document.createElement("div");
          box.className = "agent-view";
          box.innerHTML = agentHtml(text, args || "");
          return box;
        }
        if (isMarkdownPath(path) || (ty === "code" && looksLikeMd(text))) {
          const box = document.createElement("div");
          box.className = "insp-md";
          box.innerHTML = renderMd(text);
          return box;
        }
        const pre = document.createElement("pre");
        pre.className = "code";
        pre.textContent = text.length > 32000 ? text.slice(0, 32000) + "\n…" : text;
        return pre;
      }
      // ---- SSE ----
      // SSE:EventSource 无法带 Bearer header → fetch + ReadableStream 解析(kimi ws.ts 等价)
      const ev = { onmessage: null };
      let sseRetry = 0;
      function handleSSELine(line) {
        if (!line.startsWith("data: ")) return;
        try {
          ev.onmessage({ data: line.slice(6) });
        } catch {}
      }
      async function connectSSE() {
        try {
          const res = await fetch("/api/events" + (wsp ? "?" + wsp : ""), {
            headers: { accept: "text/event-stream" },
          });
          if (!res.ok || !res.body) {
            sseDown();
            sseRetry = Math.min(sseRetry + 1, 8);
            setTimeout(connectSSE, 1000 * sseRetry);
            return;
          }
          sseRetry = 0;
          sseUp();
          const reader = res.body.getReader();
          const dec = new TextDecoder();
          let buf = "";
          for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            buf += dec.decode(value, { stream: true });
            let idx;
            while ((idx = buf.indexOf("\n\n")) !== -1) {
              const chunk = buf.slice(0, idx);
              buf = buf.slice(idx + 2);
              for (const line of chunk.split("\n")) handleSSELine(line);
            }
          }
        } catch {}
        sseDown();
        setTimeout(connectSSE, sseDelay());
      }
      // 断线反馈:横幅 + 指数退避(1.5s→3s→6s→10s 封顶),连上即复位。
      let sseFails = 0;
      function sseDelay() {
        return Math.min(10000, 1500 * Math.pow(2, sseFails++));
      }
      function sseDown() {
        let b = $("ssebar");
        if (!b) {
          b = document.createElement("div");
          b.id = "ssebar";
          b.textContent = "连接断开,重连中…";
          document.body.appendChild(b);
        }
        b.classList.add("on");
      }
      function sseUp() {
        if (sseFails || $("ssebar")) {
          sseFails = 0;
          const b = $("ssebar");
          if (b) b.classList.remove("on");
        }
      }
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
      function applyHelpCatalog(j) {
        if (j && Array.isArray(j.commands) && j.commands.length) {
          SLASH = j.commands.map((c) => ({
            name: c.name,
            desc: c.desc,
            accepts: !!c.accepts,
          }));
          window.HELP_KEYS = Array.isArray(j.keys) ? j.keys : window.HELP_KEYS || [];
        }
      }
      function loadHelpCatalog() {
        return fetch("/api/help?" + wsp + "session=" + encodeURIComponent(sess))
          .then((r) => r.json())
          .then(applyHelpCatalog)
          .catch(() => showToast("help catalog load failed"));
      }
      let SLASH = [
        { name: "/help", desc: "list commands" },
        { name: "/login", desc: "save API key", accepts: true },
        { name: "/new", desc: "新会话" },
        { name: "/clear", desc: "清空并重开" },
        { name: "/sessions", desc: "搜索会话" },
        { name: "/resume", desc: "切到第 n 个会话", accepts: true },
        { name: "/undo", desc: "撤销上一轮" },
        { name: "/compact", desc: "压缩上下文" },
        { name: "/fast-compress", desc: "快压状态" },
        { name: "/fork", desc: "派生会话" },
        { name: "/title", desc: "改会话标题", accepts: true },
        { name: "/model", desc: "切换模型" },
        { name: "/refresh", desc: "拉取 provider 模型列表" },
        { name: "/think", desc: "思考等级", accepts: true },
        { name: "/permissions", desc: "授权 yolo/ask/read-only", accepts: true },
        { name: "/sandbox", desc: "bash 沙箱 off/workspace/strict", accepts: true },
        { name: "/status", desc: "当前状态" },
        { name: "/doctor", desc: "环境体检" },
        { name: "/init", desc: "写 AGENTS.md（已有不覆盖）" },
        { name: "/diff", desc: "git status + diffstat" },
        { name: "/commit", desc: "提交已暂存（需说明）", accepts: true },
        { name: "/log", desc: "git log --oneline", accepts: true },
        { name: "/branch", desc: "当前与最近分支" },
        { name: "/mcp", desc: "MCP server 列表" },
        { name: "/reload", desc: "重读 settings.json" },
        { name: "/theme", desc: "外观 light/dark/system", accepts: true },
        { name: "/paste", desc: "从剪贴板附图" },
        { name: "/usage", desc: "token 账本" },
        { name: "/jobs", desc: "在跑 / 后台任务", accepts: true },
        { name: "/find", desc: "搜对话", accepts: true },
        { name: "/plan", desc: "写 PLAN.md 再执行", accepts: true },
        { name: "/queue", desc: "清空输入队列" },
        { name: "/memory", desc: "跨会话记忆", accepts: true },
        { name: "/plugins", desc: "列出或开关插件", accepts: true },
        { name: "/pkg", desc: "已装资源包" },
        { name: "/tree", desc: "消息列表" },
        { name: "/copy", desc: "复制最后一条回复" },
        { name: "/export", desc: "导出 HTML" },
        { name: "/dump", desc: "整段会话到剪贴板" },
        { name: "/redo", desc: "重发上一次输入" },
      ];
      window.HELP_KEYS = window.HELP_KEYS || [
        { name: "@./path", desc: "embed a file" },
        { name: "!cmd", desc: "run shell, send to model" },
        { name: "!!cmd", desc: "run shell, show only" },
        { name: "?", desc: "shortcut overlay when empty" },
        { name: "c", desc: "copy last reply when empty" },
        { name: "d", desc: "doctor when empty" },
        { name: "g", desc: "git diff when empty" },
        { name: "l", desc: "git log when empty" },
        { name: "r", desc: "redo last input when empty" },
        { name: "s", desc: "sandbox picker when empty" },
        { name: "j", desc: "list jobs when empty" },
        { name: "u", desc: "token ledger when empty" },
        { name: "Esc", desc: "abort; empty again edits last" },
        { name: "Ctrl+C", desc: "clear; empty again quits" },
        { name: "Ctrl+D", desc: "empty again quits" },
        { name: "Tab", desc: "queue input while busy" },
        { name: "Ctrl+B", desc: "background while busy" },
        { name: "Ctrl+T", desc: "fold thinking" },
        { name: "Ctrl+O", desc: "fold tool output" },
        { name: "PgUp/PgDn", desc: "scroll transcript" },
        { name: "Ctrl+↑/↓", desc: "scroll a few lines" },
        { name: "wheel", desc: "scroll transcript" },
        { name: "Alt+,/.", desc: "think less / more" },
        { name: "Shift+↑/↓", desc: "think less / more" },
      ];
      let slashItems = [],
        slashIdx = 0,
        pickKind = "",
        atTok = null,
        fileTimer = 0;
      function slashStem(cmd) {
        const s = cmd[0] === "/" ? cmd.slice(1) : cmd;
        const i = s.indexOf(" ");
        return i < 0 ? s : s.slice(0, i);
      }
      function startsWithInsens(hay, needle) {
        return hay.slice(0, needle.length).toLowerCase() === needle.toLowerCase();
      }
      function indexOfInsens(hay, needle) {
        return hay.toLowerCase().indexOf(needle.toLowerCase());
      }
      function fuzzySubseq(hay, needle) {
        if (!needle) return { from: 0, to: 0 };
        let i = 0,
          first = -1,
          last = 0;
        const n = needle.toLowerCase();
        const h = hay.toLowerCase();
        for (let hi = 0; hi < h.length; hi++) {
          if (i < n.length && h[hi] === n[i]) {
            if (first < 0) first = hi;
            last = hi + 1;
            i++;
          }
        }
        return i === n.length ? { from: first, to: last } : null;
      }
      function rankSlash(items, query) {
        if (!query) return items.map((it) => ({ it, kind: 0, hlFrom: 0, hlLen: 0, score: 0 }));
        const out = [];
        for (const it of items) {
          const name = slashStem(it.name);
          if (startsWithInsens(name, query)) {
            out.push({
              it,
              kind: 0,
              hlFrom: 0,
              hlLen: query.length,
              score: 2000 + (name.length === query.length ? 1000 : 0) - Math.min(name.length, 500),
            });
            continue;
          }
          const span = fuzzySubseq(name, query);
          if (span) {
            out.push({
              it,
              kind: 1,
              hlFrom: span.from,
              hlLen: span.to - span.from,
              score: 1000 - Math.min(span.to - span.from, 500),
            });
            continue;
          }
          const at = indexOfInsens(it.desc, query);
          if (at >= 0) out.push({ it, kind: 2, hlFrom: at, hlLen: query.length, score: 100 });
        }
        out.sort((a, b) => a.kind - b.kind || b.score - a.score);
        return out;
      }
      function hlSpan(s, from, len) {
        if (!len) return esc(s);
        return (
          esc(s.slice(0, from)) +
          "<mark>" +
          esc(s.slice(from, from + len)) +
          "</mark>" +
          esc(s.slice(from + len))
        );
      }
      function hideSlash() {
        const m = $("slashMenu");
        if (m) m.hidden = true;
        slashItems = [];
        pickKind = "";
        atTok = null;
        if (fileTimer) {
          clearTimeout(fileTimer);
          fileTimer = 0;
        }
      }
      function slashOpen() {
        const m = $("slashMenu");
        return m && !m.hidden && slashItems.length > 0;
      }
      function renderSlash() {
        const m = $("slashMenu");
        if (!m) return;
        if (!slashItems.length) {
          m.hidden = true;
          return;
        }
        m.hidden = false;
        const file = pickKind === "file";
        const foot = file
          ? "<span>↑↓ 选择</span><span>Enter 填入</span><span>Tab 补全</span><span>Esc 关闭</span>"
          : "<span>↑↓ 选择</span><span>Enter 执行</span><span>Tab 补全</span><span>Esc 关闭</span>";
        m.innerHTML =
          '<div class="slash-list">' +
          slashItems
            .map((it, i) => {
              const name = file ? it.path || it.name : it.name;
              const desc = file ? (it.dir ? "目录" : "文件") : it.desc;
              const mark = file && it.dir ? '<span class="mark">/</span>' : "";
              return (
                '<div class="slash-item' +
                (i === slashIdx ? " active" : "") +
                '" data-i="' +
                i +
                '" role="option"><span class="slash-name">' +
                (it.hlLen ? hlSpan(name, it.hlFrom || 0, it.hlLen) : esc(name)) +
                '</span><span class="slash-desc">' +
                esc(desc || "") +
                "</span>" +
                mark +
                "</div>"
              );
            })
            .join("") +
          '</div><div class="slash-foot">' +
          foot +
          "</div>";
        const on = m.querySelector(".slash-item.active");
        if (on) on.scrollIntoView({ block: "nearest" });
      }
      function updateSlashList(q) {
        pickKind = "slash";
        const ranked = rankSlash(SLASH, q);
        slashItems = ranked.map((r) =>
          Object.assign({}, r.it, { hlFrom: r.hlFrom, hlLen: r.kind === 2 ? 0 : r.hlLen }),
        );
        if (slashIdx >= slashItems.length) slashIdx = 0;
        renderSlash();
      }
      function atToken(v, caret) {
        const left = v.slice(0, caret == null ? v.length : caret);
        const m = /(^|[\s])(@(?:\.\/[^\s]*|\.?))$/.exec(left);
        if (!m) return null;
        const raw = m[2];
        return { start: left.length - raw.length, raw, q: raw.startsWith("@./") ? raw.slice(3) : "" };
      }
      function scheduleFiles(tok) {
        atTok = tok;
        pickKind = "file";
        if (fileTimer) clearTimeout(fileTimer);
        fileTimer = setTimeout(async () => {
          fileTimer = 0;
          const cur = atToken($("inp").value, $("inp").selectionStart);
          if (!cur) {
            hideSlash();
            return;
          }
          atTok = cur;
          try {
            const r = await fetch("/api/files?" + wsp + "q=" + encodeURIComponent(cur.q));
            const j = await r.json();
            if (!j || !j.ok) {
              slashItems = [];
              renderSlash();
              return;
            }
            slashItems = (j.items || []).map((it) =>
              Object.assign({ desc: it.link ? "→ " + it.link : it.dir ? "目录" : "文件" }, it),
            );
            if (slashIdx >= slashItems.length) slashIdx = 0;
            pickKind = "file";
            renderSlash();
          } catch {
            hideSlash();
          }
        }, 60);
      }
      function insertFile() {
        const it = slashItems[slashIdx];
        const inp = $("inp");
        const tok = atToken(inp.value, inp.selectionStart) || atTok;
        if (!it || !tok) {
          hideSlash();
          return;
        }
        const prefix = inp.value.slice(0, tok.start);
        const suffix = inp.value.slice(tok.start + tok.raw.length);
        if (it.dir) {
          const filled = prefix + "@./" + it.path + "/";
          inp.value = filled + suffix;
          inp.setSelectionRange(filled.length, filled.length);
          hideSlash();
          scheduleFiles(atToken(inp.value, filled.length));
        } else {
          const filled = prefix + "@./" + it.path + " ";
          inp.value = filled + suffix;
          inp.setSelectionRange(filled.length, filled.length);
          hideSlash();
        }
        autosizeInp();
        saveDraft();
        refreshSend();
      }
      function hideBang() {
        const el = $("cmpHint");
        if (!el) return;
        el.hidden = true;
        el.innerHTML = "";
      }
      function showBang(v) {
        const el = $("cmpHint");
        if (!el) return;
        const local = v.startsWith("!!");
        const cmd = v.slice(local ? 2 : 1).trim();
        el.hidden = false;
        el.innerHTML = local
          ? '<span class="bang-local">!! 只跑</span><b>' +
            esc(cmd || "…") +
            "</b><span>结果留在本页，不送模型</span>"
          : '<span class="bang-run">! 跑并送</span><b>' +
            esc(cmd || "…") +
            "</b><span>输出会一并交给模型</span>";
      }
      function updateComposerChrome() {
        const inp = $("inp");
        const v = inp.value;
        if (v.startsWith("/") && v.indexOf("\n") < 0 && v.indexOf(" ") < 0) {
          hideBang();
          updateSlashList(v.slice(1));
          return;
        }
        if (v.startsWith("!")) {
          hideSlash();
          showBang(v);
          return;
        }
        const tok = atToken(v, inp.selectionStart);
        if (tok) {
          hideBang();
          scheduleFiles(tok);
          return;
        }
        hideSlash();
        hideBang();
      }
      function updateSlash() {
        updateComposerChrome();
      }
      function slashMove(d) {
        if (!slashItems.length) return;
        slashIdx = (slashIdx + d + slashItems.length) % slashItems.length;
        renderSlash();
      }
      function slashComplete() {
        if (pickKind === "file") {
          insertFile();
          return;
        }
        const it = slashItems[slashIdx];
        if (!it) return;
        $("inp").value = it.name + (it.accepts ? " " : "");
        hideSlash();
        autosizeInp();
        saveDraft();
      }
      function slashPick() {
        if (pickKind === "file") {
          insertFile();
          return;
        }
        const it = slashItems[slashIdx];
        if (!it) return;
        if (it.accepts) {
          $("inp").value = it.name + " ";
          hideSlash();
          autosizeInp();
          return;
        }
        $("inp").value = it.name;
        hideSlash();
        send();
      }
      $("slashMenu").onmousedown = (e) => {
        const it = e.target.closest(".slash-item");
        if (!it) return;
        e.preventDefault();
        slashIdx = +it.getAttribute("data-i") || 0;
        slashPick();
      };
      function autosizeInp() {
        const i = $("inp");
        i.style.height = "auto";
        i.style.height = Math.min(i.scrollHeight, 180) + "px";
      }
      function draftKey() {
        return "piz.draft." + sess;
      }
      function saveDraft() {
        try {
          const v = $("inp").value;
          if (v) localStorage.setItem(draftKey(), v);
          else localStorage.removeItem(draftKey());
        } catch {}
      }
      function restoreDraft() {
        try {
          const v = localStorage.getItem(draftKey());
          if (v) {
            $("inp").value = v;
            autosizeInp();
          }
        } catch {}
      }
      function clearDraft() {
        try {
          localStorage.removeItem(draftKey());
        } catch {}
      }
      function histKey() {
        return "piz.hist." + sess;
      }
      function loadHist() {
        try {
          return JSON.parse(localStorage.getItem(histKey()) || "[]");
        } catch {
          return [];
        }
      }
      let histIdx = -1,
        histDraft = "";
      function pushHist(t) {
        const a = loadHist().filter((x) => x !== t);
        a.push(t);
        while (a.length > 50) a.shift();
        try {
          localStorage.setItem(histKey(), JSON.stringify(a));
        } catch {}
        histIdx = -1;
        histDraft = "";
      }
      function histPrev() {
        const a = loadHist();
        if (!a.length) return;
        if (histIdx < 0) {
          histDraft = $("inp").value;
          histIdx = a.length;
        }
        if (histIdx > 0) histIdx--;
        $("inp").value = a[histIdx] || "";
        autosizeInp();
      }
      function histNext() {
        const a = loadHist();
        if (histIdx < 0) return;
        histIdx++;
        if (histIdx >= a.length) {
          histIdx = -1;
          $("inp").value = histDraft;
        } else $("inp").value = a[histIdx] || "";
        autosizeInp();
      }
      function sessUrl(name, root) {
        const r = root !== undefined ? root : ws;
        return (
          "/?session=" +
          encodeURIComponent(name) +
          (r ? "&ws=" + encodeURIComponent(r) : "")
        );
      }
      async function runSlash(item, arg) {
        switch (item.name) {
          case "/login": {
            const parts = (arg || "").trim().split(/\s+/);
            const name = parts[0] || "";
            const key = parts.slice(1).join(" ").trim();
            if (!name || !key) {
              showToast("usage: /login <provider> <api-key>");
              break;
            }
            fetch("/api/config", {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ setAuth: { name, key } }),
            })
              .then((r) => r.json())
              .then((j) => showToast(j && j.ok ? "saved " + name : "login failed"))
              .catch(() => showToast("login failed"));
            break;
          }
          case "/quit":
            showToast("close the tab to quit");
            break;
          case "/help":
            addUser("/help");
            const cmds = SLASH.map((s) => s.name.padEnd(16) + s.desc).join("\n");
            const keys = (window.HELP_KEYS || [])
              .map((s) => String(s.name || "").padEnd(16) + (s.desc || ""))
              .join("\n");
            addAsst(
              cmds +
                (keys ? "\n\n" + keys : "") +
                "\n\n@./path 嵌文件 · !cmd 跑命令并送给模型 · !!cmd 只跑不送\nCtrl+K 搜会话 · 发送中再按 Enter 会接着发",
            );
            finishAsst();
            break;
          case "/sessions":
            openSearch();
            break;
          case "/new":
          case "/clear":
            location.href = sessUrl(Math.random().toString(36).slice(2, 8));
            break;
          case "/undo":
            act({ act: "undo" }, (j) =>
              showToast(j && j.ok ? "已撤销" : "撤销失败"),
            );
            break;
          case "/compact":
            act({ act: "compact" }, (j) =>
              showToast(j && j.ok ? "压缩完成" : "压缩失败"),
            );
            break;
          case "/fork": {
            const n =
              arg || (await askText("派生会话", "", "新会话名，留空自动"));
            if (n === null) return;
            act({ act: "fork", name: n || "" }, (j) => {
              if (j && j.ok && j.name) location.href = sessUrl(j.name);
              else showToast("派生失败");
            });
            break;
          }
          case "/title": {
            const t = arg || (await askText("会话标题", curTitle || "", ""));
            if (t === null || !t) return;
            await applySessionTitle(t, true);
            break;
          }
          case "/refresh": {
            addUser("/refresh");
            try {
              const r = await fetch("/api/config", {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({ refreshModels: true }),
              });
              const j = await r.json().catch(() => ({}));
              if (!r.ok || j.ok === false) {
                addAsst(j.error || "cannot refresh models");
              } else {
                addAsst("refreshed " + (j.refreshed || 0) + " provider(s), +" + (j.added || 0) + " models" +
                  (j.fail ? "\n" + j.fail + " provider(s) failed GET /models" : ""));
              }
            } catch {
              addAsst("cannot refresh models");
            }
            finishAsst();
            break;
          }
          case "/model":
            $("hModel").click();
            break;
          case "/permissions":
          case "/approvals": {
            const lv = (arg || "").trim();
            if (!lv) {
              $("permPill").click();
              break;
            }
            await setApproval(lv);
            addUser("/permissions " + lv);
            addAsst("授权 " + (APPROVALS.find((x) => x.id === approvalMode) || {}).label);
            finishAsst();
            break;
          }
          case "/jobs": {
            const raw = (arg || "").trim();
            addUser(raw ? "/jobs " + raw : "/jobs");
            try {
              if (/^kill\s+\d+/.test(raw) || /^\d+$/.test(raw)) {
                const pid = parseInt(raw.replace(/^kill\s+/, ""), 10);
                const r = await fetch("/api/activity", {
                  method: "POST",
                  headers: { "content-type": "application/json" },
                  body: JSON.stringify({ kill: pid }),
                });
                const j = await r.json();
                addAsst(j.ok ? "killed pid " + pid : "no tracked job with that pid");
              } else {
                const r = await fetch("/api/activity");
                const list = await r.json();
                if (!list || !list.length) addAsst("no running jobs");
                else
                  addAsst(
                    list
                      .map((a) => {
                        const sec = Math.round((a.ms || 0) / 1000);
                        return (
                          (a.detached ? "~ " : "* ") +
                          (a.pid ? "pid " + a.pid + "  " : "") +
                          (a.name || "job") +
                          " " +
                          sec +
                          "s" +
                          (a.detail ? "  " + a.detail : "")
                        );
                      })
                      .join("\n"),
                  );
              }
              ensureActPoll();
            } catch {
              addAsst("cannot read activity");
            }
            finishAsst();
            break;
          }
          case "/usage": {
            addUser("/usage");
            try {
              const r = await fetch("/api/usage");
              const j = await r.json();
              const cost = j.usd > 0 ? "  $" + Number(j.usd).toFixed(4) : "";
              const head = "usage  " + (j.lines || 0) + " turns  ↑" + fmtTok(j.in || 0) + " ↓" + fmtTok(j.out || 0) + cost;
              addAsst(j.tail ? head + "\n" + j.tail : head);
            } catch {
              addAsst("cannot read usage.jsonl");
            }
            finishAsst();
            break;
          }
          case "/sandbox": {
            const lv = (arg || "").trim();
            if (!lv) {
              addUser("/sandbox");
              addAsst("usage: /sandbox off|workspace|strict");
              finishAsst();
              break;
            }
            addUser("/sandbox " + lv);
            await setSandbox(lv);
            addAsst("sandbox " + sandboxMode);
            finishAsst();
            break;
          }
          case "/think": {
            const lv = (arg || "").trim();
            if (!lv) {
              $("hThink").click();
              break;
            }
            addUser("/think " + lv);
            await setThink(lv);
            addAsst("思考 " + (curThink || lv));
            finishAsst();
            break;
          }
          case "/find": {
            const q = (arg || "").trim();
            addUser("/find" + (q ? " " + q : ""));
            const e = asstEl().querySelector(".md");
            if (!q && !webFindQ) e.textContent = "usage: /find <text>";
            else if (findInThread(q || webFindQ, false)) e.textContent = "found: " + (q || webFindQ);
            else e.textContent = "no match";
            finishAsst();
            break;
          }
          case "/paste": {
            addUser("/paste");
            try {
              if (await attachClipboardImage()) {
                addAsst(curVision ? "image attached — enter to send" : "image attached — this model has no vision");
              } else {
                addAsst("no image on clipboard — use Ctrl+V");
              }
            } catch {
              addAsst("no image on clipboard — use Ctrl+V");
            }
            finishAsst();
            break;
          }
          case "/theme": {
            const lv = (arg || "").trim().toLowerCase();
            addUser(lv ? "/theme " + lv : "/theme");
            if (!lv) {
              addAsst("theme " + (prefs.scheme || "dark") + "\nusage: /theme light|dark|system");
            } else if (setScheme(lv)) {
              addAsst("theme " + prefs.scheme);
            } else {
              addAsst("usage: /theme light|dark|system");
            }
            finishAsst();
            break;
          }
          case "/reload":
            fetch("/api/slash?" + wsp + "session=" + encodeURIComponent(sess), {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ name: "reload", args: "" }),
            })
              .then((r) => r.json())
              .then((j) => {
                const text = (j && j.text) || "reload failed";
                String(text)
                  .split("\n")
                  .forEach((line) => {
                    const m = line.match(/^(theme|approval|sandbox|think)\s+(\S+)/);
                    if (!m) return;
                    if (m[1] === "theme") setScheme(m[2]);
                    if (m[1] === "approval") {
                      approvalMode = m[2] === "read-only" ? "read-only" : m[2];
                      setModeBtn();
                    }
                    if (m[1] === "sandbox") {
                      sandboxMode = m[2];
                      setSandboxBtn();
                    }
                    if (m[1] === "think") {
                      curThink = m[2];
                      renderThink();
                    }
                  });
                addUser("/reload");
                addAsst(text);
                finishAsst();
              })
              .catch(() => {
                addUser("/reload");
                addAsst("reload failed");
                finishAsst();
              });
            break;
          case "/mcp":
            fetch("/api/slash?" + wsp + "session=" + encodeURIComponent(sess), {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ name: "mcp", args: "" }),
            })
              .then((r) => r.json())
              .then((j) => {
                addUser("/mcp");
                addAsst((j && j.text) || "mcp failed");
                finishAsst();
              })
              .catch(() => {
                addUser("/mcp");
                addAsst("mcp failed");
                finishAsst();
              });
            break;
          case "/branch":
            fetch("/api/slash?" + wsp + "session=" + encodeURIComponent(sess), {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ name: "branch", args: "" }),
            })
              .then((r) => r.json())
              .then((j) => {
                addUser("/branch");
                addAsst((j && j.text) || "branch failed");
                finishAsst();
              })
              .catch(() => {
                addUser("/branch");
                addAsst("branch failed");
                finishAsst();
              });
            break;
          case "/log":
            fetch("/api/slash?" + wsp + "session=" + encodeURIComponent(sess), {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ name: "log", args: arg || "" }),
            })
              .then((r) => r.json())
              .then((j) => {
                addUser("/log" + (arg ? " " + arg : ""));
                addAsst((j && j.text) || "log failed");
                finishAsst();
              })
              .catch(() => {
                addUser("/log");
                addAsst("log failed");
                finishAsst();
              });
            break;
          case "/commit":
            fetch("/api/slash?" + wsp + "session=" + encodeURIComponent(sess), {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ name: "commit", args: arg || "" }),
            })
              .then((r) => r.json())
              .then((j) => {
                addUser("/commit" + (arg ? " " + arg : ""));
                addAsst((j && j.text) || "commit failed");
                finishAsst();
              })
              .catch(() => {
                addUser("/commit");
                addAsst("commit failed");
                finishAsst();
              });
            break;
          case "/diff":
            fetch("/api/slash?" + wsp + "session=" + encodeURIComponent(sess), {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ name: "diff", args: "" }),
            })
              .then((r) => r.json())
              .then((j) => {
                addUser("/diff");
                addAsst((j && j.text) || "diff failed");
                finishAsst();
              })
              .catch(() => {
                addUser("/diff");
                addAsst("diff failed");
                finishAsst();
              });
            break;
          case "/init":
            fetch("/api/slash?" + wsp + "session=" + encodeURIComponent(sess), {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ name: "init", args: "" }),
            })
              .then((r) => r.json())
              .then((j) => {
                addUser("/init");
                addAsst((j && j.text) || "init failed");
                finishAsst();
              })
              .catch(() => {
                addUser("/init");
                addAsst("init failed");
                finishAsst();
              });
            break;
          case "/doctor":
            fetch("/api/slash?" + wsp + "session=" + encodeURIComponent(sess), {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ name: "doctor", args: "" }),
            })
              .then((r) => r.json())
              .then((j) => {
                addUser("/doctor");
                addAsst((j && j.text) || "doctor failed");
                finishAsst();
              })
              .catch(() => {
                addUser("/doctor");
                addAsst("doctor failed");
                finishAsst();
              });
            break;
          case "/status":
            fetch("/api/config")
              .then((r) => r.json())
              .then((cfg) => {
                const on = (Array.isArray(cfg.plugins) ? cfg.plugins : [])
                  .filter((p) => p && p.enabled && p.optional)
                  .map((p) => p.name);
                addUser("/status");
                addAsst(
                  "模型 " +
                    (curModel || "?") +
                    " · 思考 " +
                    (curThink || "high") +
                    " · 会话 " +
                    sess +
                    " · 项目 " +
                    (ws || ".") +
                    (on.length ? " · 插件 " + on.join(" ") : ""),
                );
                finishAsst();
              })
              .catch(() => {
                addUser("/status");
                addAsst(
                  "模型 " +
                    (curModel || "?") +
                    " · 思考 " +
                    (curThink || "high") +
                    " · 会话 " +
                    sess +
                    " · 项目 " +
                    (ws || "."),
                );
                finishAsst();
              });
            break;
          case "/resume": {
            const n = parseInt(arg, 10);
            if (!arg || !n) {
              openSearch();
              break;
            }
            if (n < 1 || n > sessList.length) {
              showToast("没有第 " + n + " 个会话（/sessions）");
              break;
            }
            location.href = sessUrl(sessList[n - 1].name);
            break;
          }
          case "/plan": {
            const goal =
              (arg && arg.trim()) ||
              (await askText("计划目标", "", "要完成什么"));
            if (!goal) return;
            await sendPlain("/plan " + goal);
            break;
          }
          case "/queue":
            pending = [];
            renderQueue();
            act({ act: "queue" }, (j) => {
              showToast(
                j && j.cleared
                  ? "已清空 " + j.cleared + " 条"
                  : "没有待发送的消息",
              );
            });
            break;
          case "/memory": {
            const rest = (arg || "").trim();
            if (rest === "clear") {
              act({ act: "memory-clear" }, (j) =>
                showToast(j && j.ok ? "记忆已清空" : "清空失败"),
              );
              break;
            }
            if (rest.startsWith("set ")) {
              const text = rest.slice(4).trim();
              if (!text) {
                showToast("usage: /memory set <text>");
                break;
              }
              act({ act: "memory-set", name: text }, (j) =>
                showToast(j && j.ok ? "记忆已写入" : "写入失败"),
              );
              break;
            }
            act({ act: "memory" }, (j) => {
              addUser("/memory");
              addAsst(
                (j && j.text) ||
                  "memory is empty — /memory set <text> to add",
              );
              finishAsst();
            });
            break;
          }
          case "/plugins": {
            const rest = (arg || "").trim();
            if (!rest) {
              fetch("/api/config")
                .then((r) => r.json())
                .then((cfg) => {
                  const plugs = Array.isArray(cfg.plugins) ? cfg.plugins : [];
                  const lines = plugs.map(
                    (p) =>
                      "  [" +
                      (p.enabled ? "on " : "off") +
                      "] " +
                      p.name,
                  );
                  addUser("/plugins");
                  addAsst(
                    "plugins (next turn):\n" +
                      lines.join("\n") +
                      "\nusage: /plugins on <name> | /plugins off <name>",
                  );
                  finishAsst();
                })
                .catch(() => showToast("plugins 读取失败"));
              break;
            }
            const m = rest.match(/^(on|off)\s+(\S+)$/);
            if (!m) {
              showToast("usage: /plugins on <name> | /plugins off <name>");
              break;
            }
            const on = m[1] === "on";
            fetch("/api/config", {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ setPlugin: { name: m[2], enabled: on } }),
            })
              .then((r) => r.json())
              .then((j) => {
                if (j && j.ok === false) {
                  showToast("插件开关失败");
                  return;
                }
                showToast("plugin " + m[2] + (on ? " on" : " off") + " — next turn");
                loadHelpCatalog();
              })
              .catch(() => showToast("插件开关失败"));
            break;
          }
          case "/pkg":
            fetch("/api/packages?" + wsp)
              .then((r) => r.json())
              .then((j) => {
                function rows(arr, title) {
                  const xs = Array.isArray(arr) ? arr : [];
                  const body = xs.length
                    ? xs
                        .map(
                          (p) =>
                            "  " +
                            p.name +
                            "  skills:" +
                            (p.skills || 0) +
                            " prompts:" +
                            (p.prompts || 0),
                        )
                        .join("\n")
                    : "  (none)";
                  return title + " (" + xs.length + "):\n" + body;
                }
                addUser("/pkg");
                addAsst(
                  rows(j.user, "user packages") +
                    "\n" +
                    rows(j.project, "project packages") +
                    "\ninstall: piz pkg install <path> [-l]",
                );
                finishAsst();
              })
              .catch(() => {
                addUser("/pkg");
                addAsst("packages 读取失败");
                finishAsst();
              });
            break;
          case "/tree":
            act({ act: "tree" }, (j) => {
              addUser("/tree");
              addAsst((j && j.text) || "no messages");
              finishAsst();
            });
            break;
          case "/copy":
            act({ act: "copy" }, (j) =>
              clipText(j && j.text, "已复制最后回复", "还没有回复"),
            );
            break;
          case "/export":
            act({ act: "export" }, (j) => {
              if (j && j.text) {
                downloadText("piz-export.html", j.text, "text/html");
                showToast("已导出");
              } else showToast("导出失败");
            });
            break;
          case "/dump":
            act({ act: "dump" }, (j) =>
              clipText(j && j.text, "会话已复制", "没有内容"),
            );
            break;
          case "/fast-compress":
            act({ act: "fast-compress" }, (j) => {
              addUser("/fast-compress");
              addAsst((j && j.text) || "fast-compress: ?");
              finishAsst();
            });
            break;
          case "/redo":
            if (!lastUser) {
              showToast("没有可重发的输入");
              break;
            }
            await sendPlain(lastUser);
            break;
          default: {
            const stem = String(item.name || "").replace(/^\//, "");
            fetch("/api/slash?" + wsp + "session=" + encodeURIComponent(sess), {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ name: stem, args: arg || "" }),
            })
              .then((r) => r.json())
              .then((j) => {
                if (j && j.ok) {
                  addUser("/" + stem + (arg ? " " + arg : ""));
                  addAsst(j.text || "");
                  finishAsst();
                } else showToast((j && j.error) || "未知命令");
              })
              .catch(() => showToast("未知命令"));
            break;
          }
        }
      }
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
          const item = SLASH.find((s) => s.name === cmd);
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
          histStart = s.hist_start || 0;
          histTotal = s.hist_total || (s.history ? s.history.length : 0);
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
      initServerAuth();
      const probe = rawFetch("/api/state?" + wsp + "session=" + encodeURIComponent(sess), {
        headers: credential ? { Authorization: "Bearer " + credential } : {},
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
