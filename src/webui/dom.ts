// dom.ts —— 细粒度响应式声明式 DOM 构造器
import { effect, Signal, ReadonlySignal } from "./signal";

export type Child =
  | Node
  | string
  | number
  | boolean
  | null
  | undefined
  | Signal<any>
  | ReadonlySignal<any>
  | Child[];

export type Props = Record<string, any>;

export function isSignal(val: any): val is Signal<any> | ReadonlySignal<any> {
  return typeof val === "function" && typeof (val as any).subscribe === "function";
}

const SVG_TAGS = new Set([
  "svg", "path", "circle", "rect", "line", "polyline", "polygon", "g", "text"
]);

export function h(
  tag: string,
  props?: Props | null,
  ...children: Child[]
): HTMLElement | SVGElement {
  const isSvg = SVG_TAGS.has(tag);
  const el = isSvg
    ? document.createElementNS("http://www.w3.org/2000/svg", tag)
    : document.createElement(tag);

  if (props) {
    for (const [key, value] of Object.entries(props)) {
      if (value == null) continue;

      if (key.startsWith("on") && typeof value === "function") {
        const eventName = key.slice(2).toLowerCase();
        el.addEventListener(eventName, value);
      } else if (key === "class" || key === "className") {
        bindClass(el, value);
      } else if (key === "style") {
        bindStyle(el, value);
      } else if (key === "ref" && typeof value === "function") {
        value(el);
      } else if (isSignal(value)) {
        effect(() => {
          setAttr(el, key, (value as any)());
        });
      } else {
        setAttr(el, key, value);
      }
    }
  }

  appendChildren(el, children);
  return el;
}

function setAttr(el: Element, key: string, val: any) {
  if (val == null || val === false) {
    el.removeAttribute(key);
    if (key in el) {
      try { (el as any)[key] = ""; } catch (_) {}
    }
  } else {
    if (key in el && typeof (el as any)[key] === "boolean") {
      (el as any)[key] = Boolean(val);
    }
    el.setAttribute(key, val === true ? "" : String(val));
    if (key === "value" && (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)) {
      el.value = String(val);
    }
  }
}

function bindClass(el: Element, val: any) {
  if (isSignal(val)) {
    effect(() => {
      applyClass(el, val());
    });
  } else {
    applyClass(el, val);
  }
}

function applyClass(el: Element, val: any) {
  if (typeof val === "string") {
    el.className = val;
  } else if (Array.isArray(val)) {
    el.className = val.filter(Boolean).join(" ");
  } else if (typeof val === "object" && val !== null) {
    const classes: string[] = [];
    for (const [cls, enabled] of Object.entries(val)) {
      if (isSignal(enabled)) {
        effect(() => {
          el.classList.toggle(cls, Boolean(enabled()));
        });
      } else if (enabled) {
        classes.push(cls);
      }
    }
    if (classes.length) {
      el.className = classes.join(" ");
    }
  }
}

function bindStyle(el: HTMLElement | SVGElement, val: any) {
  if (isSignal(val)) {
    effect(() => {
      applyStyle(el, val());
    });
  } else {
    applyStyle(el, val);
  }
}

function applyStyle(el: HTMLElement | SVGElement, val: any) {
  if (typeof val === "string") {
    el.style.cssText = val;
  } else if (typeof val === "object" && val !== null) {
    for (const [prop, sVal] of Object.entries(val)) {
      if (isSignal(sVal)) {
        effect(() => {
          (el.style as any)[prop] = sVal();
        });
      } else {
        (el.style as any)[prop] = sVal;
      }
    }
  }
}

function appendChildren(parent: Node, children: Child[]) {
  for (const child of children) {
    if (child == null || child === false) continue;

    if (Array.isArray(child)) {
      appendChildren(parent, child);
    } else if (isSignal(child)) {
      let currentMarker: Node = document.createTextNode("");
      parent.appendChild(currentMarker);

      effect(() => {
        const val = (child as any)();
        if (val instanceof Node) {
          parent.replaceChild(val, currentMarker);
          currentMarker = val;
        } else {
          const text = val == null ? "" : String(val);
          if (currentMarker.nodeType === Node.TEXT_NODE) {
            currentMarker.nodeValue = text;
          } else {
            const textNode = document.createTextNode(text);
            parent.replaceChild(textNode, currentMarker);
            currentMarker = textNode;
          }
        }
      });
    } else if (child instanceof Node) {
      parent.appendChild(child);
    } else {
      parent.appendChild(document.createTextNode(String(child)));
    }
  }
}

export function show(
  condition: Signal<boolean> | ReadonlySignal<boolean> | (() => boolean),
  thenFn: () => Child,
  elseFn?: () => Child
): Node {
  const container = document.createDocumentFragment();
  let currentAnchor: Node = document.createComment("show");
  container.appendChild(currentAnchor);

  let currentChild: Node | null = null;

  effect(() => {
    const parent = currentAnchor.parentNode;
    const cond = typeof condition === "function" ? (condition as any)() : condition;
    const nextChildResult = cond ? thenFn() : elseFn ? elseFn() : null;

    let nextNode: Node | null = null;
    if (nextChildResult instanceof Node) {
      nextNode = nextChildResult;
    } else if (nextChildResult != null && nextChildResult !== false) {
      nextNode = document.createTextNode(String(nextChildResult));
    }

    if (parent) {
      if (currentChild && currentChild.parentNode === parent) {
        parent.removeChild(currentChild);
        currentChild = null;
      }
      if (nextNode) {
        parent.insertBefore(nextNode, currentAnchor);
        currentChild = nextNode;
      }
    }
  });

  return container;
}

export function each<T>(
  items: Signal<T[]> | ReadonlySignal<T[]> | (() => T[]),
  renderItem: (item: T, index: number) => HTMLElement
): Node {
  const fragment = document.createDocumentFragment();
  const anchor = document.createComment("each");
  fragment.appendChild(anchor);

  let renderedNodes: HTMLElement[] = [];

  effect(() => {
    const parent = anchor.parentNode;
    if (!parent) return;

    const list = typeof items === "function" ? (items as any)() : items;
    for (const node of renderedNodes) {
      if (node.parentNode === parent) {
        parent.removeChild(node);
      }
    }
    renderedNodes = [];

    if (Array.isArray(list)) {
      for (let i = 0; i < list.length; i++) {
        const itemNode = renderItem(list[i], i);
        parent.insertBefore(itemNode, anchor);
        renderedNodes.push(itemNode);
      }
    }
  });

  return fragment;
}

export const tags = {
  div: (p?: Props | null, ...c: Child[]) => h("div", p, ...c),
  span: (p?: Props | null, ...c: Child[]) => h("span", p, ...c),
  button: (p?: Props | null, ...c: Child[]) => h("button", p, ...c),
  input: (p?: Props | null, ...c: Child[]) => h("input", p, ...c),
  textarea: (p?: Props | null, ...c: Child[]) => h("textarea", p, ...c),
  header: (p?: Props | null, ...c: Child[]) => h("header", p, ...c),
  main: (p?: Props | null, ...c: Child[]) => h("main", p, ...c),
  aside: (p?: Props | null, ...c: Child[]) => h("aside", p, ...c),
  section: (p?: Props | null, ...c: Child[]) => h("section", p, ...c),
  nav: (p?: Props | null, ...c: Child[]) => h("nav", p, ...c),
  article: (p?: Props | null, ...c: Child[]) => h("article", p, ...c),
  pre: (p?: Props | null, ...c: Child[]) => h("pre", p, ...c),
  code: (p?: Props | null, ...c: Child[]) => h("code", p, ...c),
  ul: (p?: Props | null, ...c: Child[]) => h("ul", p, ...c),
  li: (p?: Props | null, ...c: Child[]) => h("li", p, ...c),
  a: (p?: Props | null, ...c: Child[]) => h("a", p, ...c),
  p: (p?: Props | null, ...c: Child[]) => h("p", p, ...c),
  svg: (p?: Props | null, ...c: Child[]) => h("svg", p, ...c),
  path: (p?: Props | null, ...c: Child[]) => h("path", p, ...c),
};
