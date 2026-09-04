// net.ts —— 服务器凭证 + fetch 全局包装(带 Bearer,401 → 登录页)。
// 自 webui.js 切出;原 closure 变量 credential 改为模块私有,经 accessor 进出。
// 登录成功后的 boot 续跑由 main 经 setOnAuthed 注入(解循环)。
import { $ } from "./util";
import { sess, wsp } from "./state";
import { emit, on } from "./bus";

const AUTH_KEY = "piz-web.credential";
let credential: string | undefined = undefined;

export function readFragmentToken(): string | undefined {
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
export function initServerAuth() {
  const frag = readFragmentToken();
  if (frag) { setCredential(frag); return true; }
  try {
    const stored = sessionStorage.getItem(AUTH_KEY);
    if (stored) { credential = stored; return true; }
  } catch {}
  return false;
}
export function setCredential(v: string) {
  credential = v;
  try { sessionStorage.setItem(AUTH_KEY, v); } catch {}
}
export function clearCredential() {
  credential = undefined;
  try { sessionStorage.removeItem(AUTH_KEY); } catch {}
}
export const getCredential = () => credential;
export function showAuthPage(msg: string) {
  $("splash")?.classList.add("hide");
  $("authPage")?.classList.add("show");
  if (msg) $("authErr")!.textContent = msg;
  const inp = $("authTok") as HTMLInputElement | null;
  if (inp) { inp.disabled = false; inp.focus(); }
  const btn = $("authBtn") as HTMLButtonElement | null;
  if (btn) btn.disabled = true;
}
export function hideAuthPage() {
  $("authPage")?.classList.remove("show");
  $("authErr")!.textContent = "";
}

// fetch 全局包装:带 Bearer + 401 → 登录页(kimi http.ts 等价)
export const rawFetch = window.fetch.bind(window);
window.fetch = (url, opts: any = {}) => {
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

// 登录成功续跑 (向事件总线广播 auth:success)
export function setOnAuthed(f: () => void) { on("auth:success", f); }

// 登录提交
const authInp = $("authTok") as HTMLInputElement;
authInp.addEventListener("input", () => {
  ($("authBtn") as HTMLButtonElement).disabled = !authInp.value.trim();
});
authInp.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && authInp.value.trim() && !($("authBtn") as HTMLButtonElement).disabled)
    submitAuth();
});
export async function submitAuth() {
  const v = authInp.value.trim();
  if (!v) return;
  ($("authBtn") as HTMLButtonElement).disabled = true;
  authInp.disabled = true;
  setCredential(v);
  try {
    const r = await rawFetch("/api/state?" + wsp + "session=" + encodeURIComponent(sess), {
      headers: { Authorization: "Bearer " + v, "X-Skip-Auth": "1" },
    });
    if (r.ok) {
      hideAuthPage();
      emit("auth:success");
    } else {
      clearCredential();
      $("authErr")!.textContent = "连接失败,请检查 token";
      authInp.disabled = false;
      authInp.focus();
      ($("authBtn") as HTMLButtonElement).disabled = false;
    }
  } catch (e) {
    clearCredential();
    $("authErr")!.textContent = "无法连接服务器";
    authInp.disabled = false;
    ($("authBtn") as HTMLButtonElement).disabled = false;
  }
}
($("authBtn") as HTMLButtonElement).onclick = submitAuth;
