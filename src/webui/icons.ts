// icons.ts —— 规范化现代高精矢量图标系统 (统一 16x16 / 20x20 规范，杜绝任何 Emoji)
import { tags } from "./dom";

function createSvg(
  d: string,
  size = 16,
  cls = "",
  attrs: Record<string, any> = {}
): SVGElement {
  return tags.svg(
    {
      class: `ui-icon ${cls}`.trim(),
      width: String(size),
      height: String(size),
      viewBox: "0 0 24 24",
      fill: "none",
      stroke: "currentColor",
      "stroke-width": "2",
      "stroke-linecap": "round",
      "stroke-linejoin": "round",
      ...attrs,
    },
    tags.path({ d })
  ) as SVGElement;
}

export function iconBot(size = 16, cls = ""): SVGElement {
  return createSvg(
    "M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8z",
    size,
    cls
  );
}

export function iconUser(size = 16, cls = ""): SVGElement {
  return createSvg(
    "M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z",
    size,
    cls
  );
}

export function iconSend(size = 16, cls = ""): SVGElement {
  return createSvg("M12 19V5M5 12l7-7 7 7", size, cls);
}

export function iconStop(size = 16, cls = ""): SVGElement {
  return createSvg("M6 6h12v12H6z", size, cls, { fill: "currentColor" });
}

export function iconSpinner(size = 16, cls = ""): SVGElement {
  return tags.svg(
    {
      class: `ui-icon ui-spinner ${cls}`.trim(),
      width: String(size),
      height: String(size),
      viewBox: "0 0 24 24",
      fill: "none",
      stroke: "currentColor",
      "stroke-width": "2.5",
      "stroke-linecap": "round",
    },
    tags.path({
      d: "M12 2a10 10 0 0 1 10 10",
    })
  ) as SVGElement;
}

export function iconCheck(size = 16, cls = ""): SVGElement {
  return createSvg("M20 6L9 17l-5-5", size, cls);
}

export function iconClose(size = 16, cls = ""): SVGElement {
  return createSvg("M18 6L6 18M6 6l12 12", size, cls);
}

export function iconChevronRight(size = 16, cls = ""): SVGElement {
  return createSvg("M9 18l6-6-6-6", size, cls);
}

export function iconChevronDown(size = 16, cls = ""): SVGElement {
  return createSvg("M6 9l6 6 6-6", size, cls);
}

export function iconChevronUp(size = 16, cls = ""): SVGElement {
  return createSvg("M18 15l-6-6-6 6", size, cls);
}

export function iconSearch(size = 16, cls = ""): SVGElement {
  return createSvg("M21 21l-4.35-4.35M19 11a8 8 0 1 1-16 0 8 8 0 0 1 16 0z", size, cls);
}

export function iconSun(size = 16, cls = ""): SVGElement {
  return createSvg(
    "M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42M12 17a5 5 0 1 0 0-10 5 5 0 0 0 0 10z",
    size,
    cls
  );
}

export function iconMoon(size = 16, cls = ""): SVGElement {
  return createSvg("M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z", size, cls);
}

export function iconPlus(size = 16, cls = ""): SVGElement {
  return createSvg("M12 5v14M5 12h14", size, cls);
}

export function iconTrash(size = 16, cls = ""): SVGElement {
  return createSvg(
    "M3 6h18M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2",
    size,
    cls
  );
}

export function iconCopy(size = 16, cls = ""): SVGElement {
  return createSvg(
    "M8 4v12a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V7.242a2 2 0 0 0-.602-1.43L16.083 2.57A2 2 0 0 0 14.685 2H10a2 2 0 0 0-2 2z M4 8H3a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-1",
    size,
    cls
  );
}

export function iconDiff(size = 16, cls = ""): SVGElement {
  return createSvg(
    "M16 3h5v5M4 20L21 3M21 16v5h-5M15 15l6 6M4 4l5 5",
    size,
    cls
  );
}

export function iconTerminal(size = 16, cls = ""): SVGElement {
  return createSvg("M4 17l6-6-6-6M12 19h8", size, cls);
}

export function iconFolder(size = 16, cls = ""): SVGElement {
  return createSvg(
    "M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z",
    size,
    cls
  );
}

export function iconFile(size = 16, cls = ""): SVGElement {
  return createSvg(
    "M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z M13 2v7h7",
    size,
    cls
  );
}

export function iconCpu(size = 16, cls = ""): SVGElement {
  return createSvg(
    "M4 4h16v16H4z M9 9h6v6H9z M9 1v3M15 1v3M9 20v3M15 20v3M20 9h3M20 15h3M1 9h3M1 15h3",
    size,
    cls
  );
}

export function iconBolt(size = 16, cls = ""): SVGElement {
  return createSvg("M13 2L3 14h9l-1 8 10-12h-9l1-8z", size, cls);
}

export function iconQuestion(size = 16, cls = ""): SVGElement {
  return createSvg(
    "M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3M12 17h.01M22 12A10 10 0 1 1 2 12a10 10 0 0 1 20 0z",
    size,
    cls
  );
}

export function iconCompass(size = 16, cls = ""): SVGElement {
  return createSvg(
    "M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zm4.24-14.24l-2.83 8.48-8.48 2.83 2.83-8.48 8.48-2.83z",
    size,
    cls
  );
}

export function iconShield(size = 16, cls = ""): SVGElement {
  return createSvg("M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z", size, cls);
}

export function iconSettings(size = 16, cls = ""): SVGElement {
  return createSvg(
    "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zm7.4 1.5a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V23a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 21.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z",
    size,
    cls
  );
}

export function iconMenu(size = 16, cls = ""): SVGElement {
  return createSvg("M3 12h18M3 6h18M3 18h18", size, cls);
}

export function iconSidebar(size = 16, cls = ""): SVGElement {
  return createSvg("M3 3h18v18H3z M9 3v18", size, cls);
}

export function iconDeck(size = 16, cls = ""): SVGElement {
  return createSvg("M3 3h18v18H3z M15 3v18", size, cls);
}

export function iconExternal(size = 16, cls = ""): SVGElement {
  return createSvg("M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6M15 3h6v6M10 14L21 3", size, cls);
}

export function iconKey(size = 16, cls = ""): SVGElement {
  return createSvg(
    "M21 2l-2 2m-1.5 1.5L14 9M3 21l6.5-6.5a4.5 4.5 0 1 1 2 2L5 23H3v-2z",
    size,
    cls
  );
}

export function iconSparkle(size = 16, cls = ""): SVGElement {
  return createSvg(
    "M12 2l2.4 7.2L21.6 12l-7.2 2.4L12 21.6l-2.4-7.2L2.4 12l7.2-2.4z",
    size,
    cls
  );
}

export function iconBranch(size = 16, cls = ""): SVGElement {
  return createSvg(
    "M6 3a3 3 0 1 0 0 6 3 3 0 0 0 0-6zm12 6a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM6 15a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM6 9v6m0 0a6 6 0 0 1 6-6h3",
    size,
    cls
  );
}
