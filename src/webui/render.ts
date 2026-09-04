// render.ts —— 设置面板的纯 HTML 构造器(seg 开关 / auth 键列 / 资源包 / 插件行)。
// 自 webui.js 切出;名与义一字未改。DOM 绑定(bindSeg/bindAuthPanel)留在 main。
import { esc } from "./util";
import { t } from "./i18n";

export function segHtml(name: string, opts: { v: string; l: string }[], cur: string) {
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
/// 供应商凭证卡片(dsh settings-models rowCard 之形):每 provider 一张卡 ——
/// 头行(状态点 + 名称 + 协议 hint) + key 输入行 + OAuth 按钮。
/// 已配 key = 绿实心点;未配 = 红实心点(dsh credentialDot 规范)。
export function authPanelHtml(cfg: any) {
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
  const by: Record<string, any> = {};
  src.forEach((p: any) => {
    by[p.name] = p;
  });
  const list = keysFirst.map((n) => by[n] || { name: n, hasKey: false });
  const oauthLabel: Record<string, string> = {
    openrouter: "Sign in with OpenRouter",
    xai: "Sign in with xAI",
    openai: "Sign in with ChatGPT",
  };
  return (
    '<div class="prov-hint">' +
    t("builtinProvidersHint", "Built-in providers. Paste API key and save. Green dot = configured.") +
    "</div>" +
    '<div class="prov-cards">' +
    list
      .map((p) => {
        const oauthl = oauthLabel[p.name];
        return (
          '<div class="prov-card auth-row" data-prov="' +
          esc(p.name) +
          '"><div class="prov-head"><span class="cred-dot ' +
          (p.hasKey ? "cred-ok" : "cred-miss") +
          '" title="' +
          (p.hasKey ? t("configured", "Configured") : t("notConfigured", "Not configured")) +
          '"></span><span class="prov-name">' +
          esc(p.name) +
          "</span>" +
          (p.api ? '<span class="prov-api">' + esc(p.api) + "</span>" : "") +
          "</div>" +
          '<div class="auth-actions"><input class="set-sel auth-key" type="password" placeholder="' +
          (p.hasKey ? t("replaceApiKey", "Replace API key") : t("pasteApiKey", "Paste API key")) +
          '" autocomplete="off">' +
          '<button type="button" class="btn auth-save">' +
          t("save", "Save") +
          "</button>" +
          (oauthl ? '<button type="button" class="btn auth-oauth">' + oauthl + "</button>" : "") +
          "</div>" +
          '<div class="set-hint auth-dev" hidden></div></div>'
        );
      })
      .join("") +
    "</div>"
  );
}
export function packageRows(data: any) {
  const user = data && Array.isArray(data.user) ? data.user : [];
  const proj = data && Array.isArray(data.project) ? data.project : [];
  const title = t("packages", "Packages");
  if (!user.length && !proj.length) {
    return '<div class="set-row"><div class="set-lab">' + title + '<span class="set-hint">piz pkg install &lt;path&gt; [-l]</span></div></div>';
  }
  function one(p: any, scope: string) {
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
    '<div class="set-row"><div class="set-lab">' + title + '<span class="set-hint">~/.piz/packages &amp; .piz/packages</span></div></div>';
  for (const p of user) html += one(p, "user");
  for (const p of proj) html += one(p, "project");
  return html;
}
export function pluginRows(list: any) {
  const plugs = Array.isArray(list) ? list.filter((p: any) => p && p.optional) : [];
  if (!plugs.length) return "";
  let html =
    '<div class="set-row"><div class="set-lab">' +
    t("plugins", "Plugins") +
    '<span class="set-hint">' +
    t("pluginHint", "task-delegation enables workflow / subagents. Takes effect next turn.") +
    "</span></div></div>";
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

