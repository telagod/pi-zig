// md.ts —— 极速安全 Markdown 渲染器 (Fail-closed 防 XSS，流式容错)

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function renderInline(text: string): string {
  let s = escapeHtml(text);

  // 行内代码 `code`
  s = s.replace(/`([^`]+)`/g, '<code class="inline-code">$1</code>');
  // 粗体 **bold** or __bold__
  s = s.replace(/(\*\*|__)(.*?)\1/g, "<strong>$2</strong>");
  // 斜体 *italic* or _italic_
  s = s.replace(/(\*|_)(.*?)\1/g, "<em>$2</em>");
  // 删除线 ~~del~~
  s = s.replace(/~~(.*?)~~/g, "<del>$1</del>");
  // 链接 [text](url)
  s = s.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer" class="md-link">$1</a>');

  return s;
}

export function renderMarkdown(markdown: string): string {
  if (!markdown) return "";

  const lines = markdown.split(/\r?\n/);
  const out: string[] = [];
  let inCodeBlock = false;
  let codeBlockLang = "";
  let codeBlockContent: string[] = [];
  let inTable = false;
  let inList = false;
  let inBlockquote = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    // 代码块判定 ```lang
    if (line.trim().startsWith("```")) {
      if (inCodeBlock) {
        // 闭合代码块
        const codeText = escapeHtml(codeBlockContent.join("\n"));
        out.push(
          `<div class="code-block" data-lang="${codeBlockLang}">` +
            `<div class="code-block-hdr">` +
              `<span class="code-lang">${codeBlockLang || "text"}</span>` +
              `<button class="copy-btn" onclick="navigator.clipboard.writeText(this.closest('.code-block').querySelector('code').innerText);this.textContent='Copied!';setTimeout(()=>this.textContent='Copy',1500)">Copy</button>` +
            `</div>` +
            `<pre><code class="lang-${codeBlockLang}">${codeText}</code></pre>` +
          `</div>`
        );
        inCodeBlock = false;
        codeBlockLang = "";
        codeBlockContent = [];
      } else {
        // 打开代码块
        inCodeBlock = true;
        codeBlockLang = line.trim().slice(3).trim();
        codeBlockContent = [];
      }
      continue;
    }

    if (inCodeBlock) {
      codeBlockContent.push(line);
      continue;
    }

    // 表格判定 | a | b |
    if (line.trim().startsWith("|") && line.trim().endsWith("|")) {
      if (!inTable) {
        inTable = true;
        out.push('<div class="table-wrap"><table>');
      }
      // 忽略分隔线 |---|---|
      if (/^\|[\s\-:|]+\|$/.test(line.trim())) {
        continue;
      }
      const cells = line
        .trim()
        .slice(1, -1)
        .split("|")
        .map((c) => c.trim());
      const isHeader = i + 1 < lines.length && /^\|[\s\-:|]+\|$/.test(lines[i + 1].trim());
      const tag = isHeader ? "th" : "td";
      out.push("<tr>" + cells.map((c) => `<${tag}>${renderInline(c)}</${tag}>`).join("") + "</tr>");
      continue;
    } else if (inTable) {
      inTable = false;
      out.push("</table></div>");
    }

    // 引用块 > quote
    if (line.startsWith("> ") || line === ">") {
      if (!inBlockquote) {
        inBlockquote = true;
        out.push("<blockquote>");
      }
      out.push(`<p>${renderInline(line.slice(2))}</p>`);
      continue;
    } else if (inBlockquote) {
      inBlockquote = false;
      out.push("</blockquote>");
    }

    // 列表判定 - item or * item or 1. item
    const listMatch = line.match(/^(\s*)([-*]|\d+\.)\s+(.*)$/);
    if (listMatch) {
      if (!inList) {
        inList = true;
        out.push("<ul>");
      }
      let content = listMatch[3];
      // 任务列表 [ ] or [x]
      if (content.startsWith("[ ] ")) {
        content = `<input type="checkbox" disabled class="task-chk"> ` + content.slice(4);
      } else if (content.startsWith("[x] ")) {
        content = `<input type="checkbox" checked disabled class="task-chk"> ` + content.slice(4);
      }
      out.push(`<li>${renderInline(content)}</li>`);
      continue;
    } else if (inList) {
      inList = false;
      out.push("</ul>");
    }

    // 空行
    if (!line.trim()) {
      continue;
    }

    // 标题 # ## ###
    const hMatch = line.match(/^(#{1,6})\s+(.*)$/);
    if (hMatch) {
      const level = hMatch[1].length;
      out.push(`<h${level}>${renderInline(hMatch[2])}</h${level}>`);
      continue;
    }

    // 分隔线 ---
    if (/^(\*{3,}|-{3,}|_{3,})$/.test(line.trim())) {
      out.push("<hr />");
      continue;
    }

    // 常规段落
    out.push(`<p>${renderInline(line)}</p>`);
  }

  // 兜底闭合流式未完结结构
  if (inCodeBlock) {
    const codeText = escapeHtml(codeBlockContent.join("\n"));
    out.push(
      `<div class="code-block is-streaming" data-lang="${codeBlockLang}">` +
        `<div class="code-block-hdr">` +
          `<span class="code-lang">${codeBlockLang || "text"}</span>` +
        `</div>` +
        `<pre><code class="lang-${codeBlockLang}">${codeText}</code></pre>` +
      `</div>`
    );
  }
  if (inTable) out.push("</table></div>");
  if (inBlockquote) out.push("</blockquote>");
  if (inList) out.push("</ul>");

  return out.join("\n");
}
