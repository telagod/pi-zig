// plugins.ts —— 插件 SDK v1:listener 总线、pluginUrl/pluginApi、loadPlugins、
// window.piz、beforeunload 清理。自 webui.js 切出。
// api.send 借 composer 之 getRunning/sendPlain,环引(plugins↔composer)为
// build-web DFS 所禁,故以 pluginsH 钩袋迟取;chat/composer 直引本模块无环。
import { sess, ws, wsp } from "./state";
import { showToast } from "./ui";
import { getRunning } from "./store";
import { emit } from "./bus";

const pluginListeners = new Map<string, Set<any>>(),
  msgRenderers: any[] = [],
  pluginCleanups: any[] = [];
export const toolRenderers = new Map<string, any>();
export const getToolRenderer = (n: string) => toolRenderers.get(n);
export function pluginEmit(type: string, detail?: any) {
  for (const fn of pluginListeners.get(type) || []) {
    try {
      fn(detail);
    } catch (e) {
      console.error("[piz plugin]", e);
    }
  }
  window.dispatchEvent(new CustomEvent("piz:" + type, { detail }));
}
export function pluginOn(type: string, fn: any) {
  const set = pluginListeners.get(type) || new Set();
  set.add(fn);
  pluginListeners.set(type, set);
  return () => set.delete(fn);
}
export function pluginUrl(path: string) {
  const u = new URL(path, location.href);
  if (ws) u.searchParams.set("ws", ws);
  return u.href;
}
export function pluginApi(meta: any) {
  const owned: any[] = [];
  const api: any = {
    version: 1,
    id: meta.id,
    name: meta.name,
    session: sess,
    workspace: ws,
    asset: (rel: string) =>
      pluginUrl(new URL(rel, new URL(meta.base, location.href)).href),
    on: (type: string, fn: any) => {
      const off = pluginOn(type, fn);
      owned.push(off);
      return off;
    },
    toast: showToast,
    fetch: async (path: string, opts?: any) => {
      const u = new URL(path, location.href);
      if (u.origin !== location.origin || !u.pathname.startsWith("/api/"))
        throw new Error(
          "plugin fetch only allows same-origin /api routes",
        );
      if (ws && !u.searchParams.has("ws")) u.searchParams.set("ws", ws);
      return fetch(u, opts);
    },
    send: (text: any) => {
      if (getRunning()) return false;
      emit("chat:send", { text: String(text) });
      return true;
    },
    ui: {
      slot: (name: string) =>
        document.querySelector('[data-piz-slot="' + name + '"]'),
      mount: (slot: string, value: any) => {
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
      button: (slot: string, spec: any = {}) => {
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
    renderTool: (name: string, fn: any) => {
      toolRenderers.set(name, fn);
      owned.push(() => {
        if (toolRenderers.get(name) === fn) toolRenderers.delete(name);
      });
    },
    renderMessage: (fn: any) => {
      msgRenderers.push(fn);
      owned.push(() => {
        const i = msgRenderers.indexOf(fn);
        if (i >= 0) msgRenderers.splice(i, 1);
      });
    },
    storage: {
      get: (key: string, fb: any = null) => {
        try {
          const v = localStorage.getItem(
            "piz.plugin." + meta.id + "." + key,
          );
          return v === null ? fb : JSON.parse(v);
        } catch {
          return fb;
        }
      },
      set: (key: string, value: any) =>
        localStorage.setItem(
          "piz.plugin." + meta.id + "." + key,
          JSON.stringify(value),
        ),
      remove: (key: string) =>
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
export async function loadPlugins() {
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
(window as any).piz = Object.freeze({
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
