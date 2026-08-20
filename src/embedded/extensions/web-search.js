// web-search —— web_search + fetch_url + /web 斜杠。默认关:settings.json 的
// plugins:["web-search"] 或 /plugins on web-search 开(jsrt 按启用集门控内嵌装载)。
// 内嵌出厂件;在 ~/.piz/extensions/ 或 <项目>/.piz/extensions/ 放同名 web-search.js 即覆写。
// fetch_url 经 piz.fetch safe:true 拦私网/本机/metadata(护栏在宿主 httpc.urlBlocked)。
const MAX_RESULTS = 8;
const LIMIT = 24 * 1024;

function errIs(s) { return { error: s }; }

// 逐 UTF-8 字节百分编码;字母数字与 - _ . ~ 不编码(与原 Zig 版一致)。
function utf8Bytes(cp) {
  if (cp < 0x80) return [cp];
  if (cp < 0x800) return [0xc0 | (cp >> 6), 0x80 | (cp & 63)];
  if (cp < 0x10000) return [0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63)];
  return [0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63)];
}
function urlEncode(s) {
  let out = "";
  for (const ch of String(s)) {
    const cp = ch.codePointAt(0);
    if ((cp >= 0x30 && cp <= 0x39) || (cp >= 0x41 && cp <= 0x5a) || (cp >= 0x61 && cp <= 0x7a) ||
        cp === 0x2d || cp === 0x5f || cp === 0x2e || cp === 0x7e) {
      out += ch;
    } else {
      for (const b of utf8Bytes(cp)) out += "%" + b.toString(16).toUpperCase().padStart(2, "0");
    }
  }
  return out;
}

function webStatus() {
  const ep = piz.env("PIZ_WEB_SEARCH_URL") || "";
  if (!ep) return "web-search: PIZ_WEB_SEARCH_URL is unset.\nSet it to a SearXNG JSON endpoint (e.g. http://127.0.0.1:8080/search?q=).\nusage: /web <query>";
  return "web-search: endpoint " + ep + "\nusage: /web <query>\nfetch_url blocks private/localhost/metadata.";
}

// SearXNG JSON 压成紧凑列表;解析失败原样返回 —— 端点可能不是 SearXNG。
function shapeSearchResults(raw, query) {
  let root;
  try { root = JSON.parse(raw); } catch (_) { return raw; }
  if (!root || typeof root !== "object" || !Array.isArray(root.results)) return raw;
  let out = 'Search results for "' + query + '":\n';
  let n = 0;
  for (const item of root.results) {
    if (n >= MAX_RESULTS) break;
    if (!item || typeof item !== "object") continue;
    if (typeof item.title !== "string" || typeof item.url !== "string") continue;
    const snip = typeof item.content === "string" ? item.content : "";
    n += 1;
    out += "\n" + n + ". " + item.title + "\n   " + item.url + "\n";
    if (snip.length > 0) out += "   " + snip.slice(0, 300) + (snip.length > 300 ? "…" : "") + "\n";
  }
  if (n === 0) return 'No results for "' + query + '".';
  return out + "\nUse fetch_url on a result to read its full text.";
}

// HTML 抽正文(与原 Zig 版同算法):丢 script/style/head/noscript/svg 整块,
// 块级标签转换行,解常见实体,压空白。
function matchTagOpen(html, i, tag) {
  if (i + 1 + tag.length > html.length) return false;
  if (html[i] !== "<") return false;
  if (html.slice(i + 1, i + 1 + tag.length).toLowerCase() !== tag) return false;
  const after = i + 1 + tag.length;
  if (after >= html.length) return true;
  const c = html[after];
  return c === ">" || c === " " || c === "\t" || c === "\n" || c === "/" || c === "\r";
}
function skipToTagClose(html, start, tag) {
  let i = start + 1 + tag.length;
  while (i + 2 + tag.length < html.length) {
    if (html[i] === "<" && html[i + 1] === "/" && html.slice(i + 2, i + 2 + tag.length).toLowerCase() === tag) {
      const end = html.indexOf(">", i);
      return end < 0 ? html.length : end + 1;
    }
    i += 1;
  }
  return html.length;
}
function decodeEntity(html, i) {
  const pairs = [["&amp;", "&"], ["&lt;", "<"], ["&gt;", ">"], ["&quot;", '"'], ["&apos;", "'"], ["&nbsp;", " "], ["&#39;", "'"], ["&#x27;", "'"], ["&#34;", '"']];
  for (const pr of pairs) if (html.startsWith(pr[0], i)) return { text: pr[1], next: i + pr[0].length };
  return null;
}
function htmlToText(html) {
  let out = "";
  let i = 0;
  let lastSpace = true; // 开头不留空白
  while (i < html.length) {
    if (html[i] === "<") {
      let skipTo = -1;
      for (const tag of ["script", "style", "head", "noscript", "svg"]) {
        if (matchTagOpen(html, i, tag)) { skipTo = skipToTagClose(html, i, tag); break; }
      }
      if (skipTo >= 0) { i = skipTo; continue; }
      const isBreak = matchTagOpen(html, i, "p") || matchTagOpen(html, i, "br") ||
        matchTagOpen(html, i, "div") || matchTagOpen(html, i, "li") ||
        matchTagOpen(html, i, "tr") || matchTagOpen(html, i, "h1") ||
        matchTagOpen(html, i, "h2") || matchTagOpen(html, i, "h3");
      const end = html.indexOf(">", i);
      i = end < 0 ? html.length + 1 : end + 1;
      if (isBreak && out.length > 0 && out[out.length - 1] !== "\n") { out += "\n"; lastSpace = true; }
      continue;
    }
    if (html[i] === "&") {
      const hit = decodeEntity(html, i);
      if (hit) { out += hit.text; i = hit.next; lastSpace = false; continue; }
    }
    const c = html[i];
    if (c === " " || c === "\t" || c === "\n" || c === "\r") {
      if (!lastSpace) { out += " "; lastSpace = true; }
    } else {
      out += c;
      lastSpace = false;
    }
    i += 1;
  }
  return out;
}

function webSearch(args) {
  const q = args && typeof args.query === "string" ? args.query : "";
  if (!q) return errIs("error: web_search requires 'query'");
  const ep = piz.env("PIZ_WEB_SEARCH_URL") || "";
  if (!ep) return errIs("error: web_search is not configured. Set PIZ_WEB_SEARCH_URL to a JSON search endpoint that takes the query as its last parameter (e.g. http://localhost:8080/search?q= for SearXNG). Until then, use bash with curl for network lookups.");
  // 搜索端点是运营方自配(常是本机 SearXNG),不过私网拦 —— 与原实现一致。
  let r;
  try { r = piz.fetch(ep + urlEncode(q) + "&format=json"); }
  catch (_) { return errIs("error: search request failed (is the endpoint reachable?)"); }
  return shapeSearchResults(String((r && r.body) || ""), q);
}

function fetchUrl(args) {
  const url = args && typeof args.url === "string" ? args.url : "";
  if (!url) return errIs("error: fetch_url requires 'url'");
  if (!url.startsWith("http://") && !url.startsWith("https://")) {
    return errIs("error: fetch_url only accepts http:// or https:// URLs");
  }
  let r;
  try {
    r = piz.fetch(url, { safe: true, headers: { "user-agent": "Mozilla/5.0 (compatible; piz)" } });
  } catch (e) {
    const m = (e && e.message) ? String(e.message) : "";
    return errIs(m.indexOf("blocked") >= 0
      ? "error: fetch_url blocked private or local address"
      : "error: fetch failed (unreachable, timed out, or too large)");
  }
  const text = htmlToText(String((r && r.body) || ""));
  if (!text.length) return errIs("error: fetched page had no readable text");
  if (text.length > LIMIT) {
    return text.slice(0, LIMIT) + "\n\n...[truncated at " + LIMIT + " of " + text.length + " chars]";
  }
  return text;
}

piz.registerTool({
  name: "web_search",
  description: "Search the web when local information is insufficient or possibly out of date. Returns a ranked list of titles, URLs and snippets; follow up with fetch_url to read a result in full. Requires PIZ_WEB_SEARCH_URL.",
  schema: { type: "object", properties: { query: { type: "string", description: "Search query." } }, required: ["query"] },
  execute: (args) => webSearch(args),
});
piz.registerTool({
  name: "fetch_url",
  description: "Fetch a web page or plain-text URL and return its readable text with markup stripped. Use it to read documentation, changelogs, issues or search results in full.",
  schema: { type: "object", properties: { url: { type: "string", description: "http:// or https:// URL to fetch." } }, required: ["url"] },
  execute: (args) => fetchUrl(args),
});
piz.registerCommand("web", { description: "web search status or /web <query>", handler: (args) => {
  const q = String(args == null ? "" : args).trim();
  if (!q) return webStatus();
  const r = webSearch({ query: q });
  return r && r.error ? r.error : String(r);
} });
