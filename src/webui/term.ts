// term.ts —— 高保真 ANSI 颜色与控制序列转译器

const ANSI_COLORS: Record<number, string> = {
  30: "ansi-black",
  31: "ansi-red",
  32: "ansi-green",
  33: "ansi-yellow",
  34: "ansi-blue",
  35: "ansi-magenta",
  36: "ansi-cyan",
  37: "ansi-white",
  90: "ansi-bright-black",
  91: "ansi-bright-red",
  92: "ansi-bright-green",
  93: "ansi-bright-yellow",
  94: "ansi-bright-blue",
  95: "ansi-bright-magenta",
  96: "ansi-bright-cyan",
  97: "ansi-bright-white",
};

const ANSI_BG_COLORS: Record<number, string> = {
  40: "ansi-bg-black",
  41: "ansi-bg-red",
  42: "ansi-bg-green",
  43: "ansi-bg-yellow",
  44: "ansi-bg-blue",
  45: "ansi-bg-magenta",
  46: "ansi-bg-cyan",
  47: "ansi-bg-white",
};

export function ansiToHtml(input: string): string {
  if (!input) return "";

  // 1. 转义基础 HTML 实体
  let s = input
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");

  // 2. 状态机解析 ANSI 转义码 \x1b[...m
  const re = /\x1b\[([0-9;]*)m/g;
  let out = "";
  let lastIdx = 0;
  const activeClasses = new Set<string>();

  let match: RegExpExecArray | null;
  while ((match = re.exec(s)) !== null) {
    const textChunk = s.slice(lastIdx, match.index);
    if (textChunk) {
      if (activeClasses.size > 0) {
        out += `<span class="${Array.from(activeClasses).join(" ")}">${textChunk}</span>`;
      } else {
        out += textChunk;
      }
    }
    lastIdx = re.lastIndex;

    const codes = match[1] ? match[1].split(";").map(Number) : [0];
    for (const code of codes) {
      if (code === 0) {
        activeClasses.clear();
      } else if (code === 1) {
        activeClasses.add("ansi-bold");
      } else if (code === 2) {
        activeClasses.add("ansi-dim");
      } else if (code === 3) {
        activeClasses.add("ansi-italic");
      } else if (code === 4) {
        activeClasses.add("ansi-underline");
      } else if (ANSI_COLORS[code]) {
        // 清理旧前景色
        for (const cls of activeClasses) {
          if (cls.startsWith("ansi-") && !cls.startsWith("ansi-bg-") && !cls.startsWith("ansi-bold") && !cls.startsWith("ansi-dim") && !cls.startsWith("ansi-italic") && !cls.startsWith("ansi-underline")) {
            activeClasses.delete(cls);
          }
        }
        activeClasses.add(ANSI_COLORS[code]);
      } else if (ANSI_BG_COLORS[code]) {
        for (const cls of activeClasses) {
          if (cls.startsWith("ansi-bg-")) activeClasses.delete(cls);
        }
        activeClasses.add(ANSI_BG_COLORS[code]);
      }
    }
  }

  const remaining = s.slice(lastIdx);
  if (remaining) {
    if (activeClasses.size > 0) {
      out += `<span class="${Array.from(activeClasses).join(" ")}">${remaining}</span>`;
    } else {
      out += remaining;
    }
  }

  return out;
}
