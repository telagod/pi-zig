// md.ts —— 现代化极速安全 Markdown 与代码语法高亮引擎 (Zero-dep, Fail-closed, Lexical Syntax Highlighting)

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// 关键词词典
const KEYWORDS = new Set([
  "const", "let", "var", "function", "return", "if", "else", "for", "while", "do",
  "switch", "case", "break", "continue", "default", "import", "export", "from", "as",
  "class", "extends", "super", "this", "new", "typeof", "instanceof", "try", "catch",
  "finally", "throw", "async", "await", "yield", "pub", "fn", "struct", "enum", "union",
  "error", "orelse", "catch", "try", "defer", "errdefer", "comptime", "inline", "test",
  "type", "interface", "namespace", "using", "package", "def", "elif", "pass", "lambda",
  "with", "is", "in", "not", "and", "or", "true", "false", "null", "undefined", "nil", "None"
]);

const TYPES = new Set([
  "string", "number", "boolean", "any", "void", "never", "unknown", "u8", "u16", "u32", "u64",
  "i8", "i16", "i32", "i64", "usize", "isize", "f32", "f64", "bool", "int", "float", "str",
  "list", "dict", "tuple", "set", "Self", "Allocator", "ArrayList", "Writer", "Reader"
]);

// 轻量词法高亮
export function highlightCode(code: string, lang: string): string {
  const lines = code.split("\n");
  const highlightedLines = lines.map((line) => {
    let i = 0;
    let out = "";
    const len = line.length;

    while (i < len) {
      // 1. 注释 // 或 # 或 --
      if ((line[i] === "/" && line[i + 1] === "/") || (line[i] === "#" && !lang.includes("hash")) || (line[i] === "-" && line[i + 1] === "-")) {
        out += `<span class="hl-comment">${escapeHtml(line.slice(i))}</span>`;
        break;
      }

      // 2. 字符串 "..." 或 '...' 或 `...`
      const ch = line[i];
      if (ch === '"' || ch === "'" || ch === "`") {
        let str = ch;
        i++;
        while (i < len && line[i] !== ch) {
          if (line[i] === "\\" && i + 1 < len) {
            str += line[i] + line[i + 1];
            i += 2;
          } else {
            str += line[i];
            i++;
          }
        }
        if (i < len) {
          str += line[i];
          i++;
        }
        out += `<span class="hl-string">${escapeHtml(str)}</span>`;
        continue;
      }

      // 3. 数字 (包括十六进制 0x...)
      if (/[0-9]/.test(ch) && (i === 0 || /[^a-zA-Z0-9_]/.test(line[i - 1]))) {
        let num = "";
        while (i < len && /[0-9a-fA-FxX_.]/.test(line[i])) {
          num += line[i];
          i++;
        }
        out += `<span class="hl-number">${escapeHtml(num)}</span>`;
        continue;
      }

      // 4. 标识符（关键词、类型、函数调用）
      if (/[a-zA-Z_]/.test(ch)) {
        let word = "";
        while (i < len && /[a-zA-Z0-9_]/.test(line[i])) {
          word += line[i];
          i++;
        }

        if (KEYWORDS.has(word)) {
          out += `<span class="hl-keyword">${word}</span>`;
        } else if (TYPES.has(word) || /^[A-Z][a-zA-Z0-9_]*$/.test(word)) {
          out += `<span class="hl-type">${word}</span>`;
        } else if (i < len && line[i] === "(") {
          out += `<span class="hl-func">${word}</span>`;
        } else {
          out += escapeHtml(word);
        }
        continue;
      }

      // 5. 符号与其它字符
      out += escapeHtml(ch);
      i++;
    }

    return out || " ";
  });

  return highlightedLines.join("\n");
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
        const rawCode = codeBlockContent.join("\n");
        const hlCode = highlightCode(rawCode, codeBlockLang);
        out.push(
          `<div class="code-block" data-lang="${codeBlockLang}">` +
            `<div class="code-block-hdr">` +
              `<span class="code-lang">${codeBlockLang || "text"}</span>` +
              `<button class="copy-btn" onclick="navigator.clipboard.writeText(this.closest('.code-block').querySelector('code').innerText);this.classList.add('is-copied');setTimeout(()=>this.classList.remove('is-copied'),2000)">` +
                `<span class="copy-lbl">Copy</span><span class="copied-lbl">Copied!</span>` +
              `</button>` +
            `</div>` +
            `<pre><code class="lang-${codeBlockLang}">${hlCode}</code></pre>` +
          `</div>`
        );
        inCodeBlock = false;
        codeBlockLang = "";
        codeBlockContent = [];
      } else {
        // 打开代码块
        inCodeBlock = true;
        codeBlockLang = line.trim().slice(3).trim().toLowerCase();
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
    const rawCode = codeBlockContent.join("\n");
    const hlCode = highlightCode(rawCode, codeBlockLang);
    out.push(
      `<div class="code-block is-streaming" data-lang="${codeBlockLang}">` +
        `<div class="code-block-hdr">` +
          `<span class="code-lang">${codeBlockLang || "text"}</span>` +
        `</div>` +
        `<pre><code class="lang-${codeBlockLang}">${hlCode}</code></pre>` +
      `</div>`
    );
  }
  if (inTable) out.push("</table></div>");
  if (inBlockquote) out.push("</blockquote>");
  if (inList) out.push("</ul>");

  return out.join("\n");
}
