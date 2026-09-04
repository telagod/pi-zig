// dom.ts —— 细粒度响应式声明式 DOM 构造器 (Zero-vdom, Proxy Tags, Exact Reactivity)
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
  | (() => any)
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
      } else if (typeof value === "function") {
        effect(() => {
          setAttr(el, key, value());
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
  } else {
    el.setAttribute(key, val === true ? "" : String(val));
    if (key === "value" && (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement)) {
      el.value = String(val);
    }
  }
}

function bindClass(el: Element, val: any) {
  if (typeof val === "function") {
    effect(() => {
      applyClass(el, val());
    });
  } else {
    applyClass(el, val);
  }
}

function applyClass(el: Element, val: any) {
  if (typeof val === "string") {
    el.setAttribute("class", val);
  } else if (Array.isArray(val)) {
    el.setAttribute("class", val.filter(Boolean).join(" "));
  } else if (typeof val === "object" && val !== null) {
    const classes: string[] = [];
    for (const [cls, enabled] of Object.entries(val)) {
      if (typeof enabled === "function") {
        effect(() => {
          el.classList.toggle(cls, Boolean(enabled()));
        });
      } else if (enabled) {
        classes.push(cls);
      }
    }
    if (classes.length) {
      el.setAttribute("class", classes.join(" "));
    } else {
      el.removeAttribute("class");
    }
  }
}

function bindStyle(el: HTMLElement | SVGElement, val: any) {
  if (typeof val === "function") {
    effect(() => {
      applyStyle(el, val());
    });
  } else {
    applyStyle(el, val);
  }
}

function applyStyle(el: HTMLElement | SVGElement, val: any) {
  if (typeof val === "string") {
    el.setAttribute("style", val);
  } else if (typeof val === "object" && val !== null) {
    for (const [prop, sVal] of Object.entries(val)) {
      if (typeof sVal === "function") {
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
    } else if (typeof child === "function") {
      appendDynamicChild(parent, child);
    } else if (child instanceof Node) {
      parent.appendChild(child);
    } else {
      parent.appendChild(document.createTextNode(String(child)));
    }
  }
}

function appendDynamicChild(parent: Node, getter: () => any) {
  const startAnchor = document.createComment("dyn-start");
  const endAnchor = document.createComment("dyn-end");
  parent.appendChild(startAnchor);
  parent.appendChild(endAnchor);

  let renderedNodes: Node[] = [];

  effect(() => {
    const p = startAnchor.parentNode;
    if (!p) return;

    for (const node of renderedNodes) {
      if (node.parentNode === p) {
        p.removeChild(node);
      }
    }
    renderedNodes = [];

    const val = getter();
    if (val == null || val === false) return;

    if (Array.isArray(val)) {
      for (const item of val) {
        if (item == null || item === false) continue;
        const node = item instanceof Node ? item : document.createTextNode(String(item));
        p.insertBefore(node, endAnchor);
        renderedNodes.push(node);
      }
    } else {
      const node = val instanceof Node ? val : document.createTextNode(String(val));
      p.insertBefore(node, endAnchor);
      renderedNodes.push(node);
    }
  });
}

export function show(
  condition: Signal<boolean> | ReadonlySignal<boolean> | (() => boolean),
  thenFn: () => Child,
  elseFn?: () => Child
): Node {
  const fragment = document.createDocumentFragment();
  appendDynamicChild(fragment, () => {
    const cond = typeof condition === "function" ? condition() : condition;
    return cond ? thenFn() : elseFn ? elseFn() : null;
  });
  return fragment;
}

export function each<T>(
  items: Signal<T[]> | ReadonlySignal<T[]> | (() => T[]),
  renderItem: (item: T, index: number) => HTMLElement
): Node {
  const fragment = document.createDocumentFragment();
  appendDynamicChild(fragment, () => {
    const list = typeof items === "function" ? items() : items;
    if (!Array.isArray(list)) return null;
    return list.map((item, i) => renderItem(item, i));
  });
  return fragment;
}

// 优雅 Proxy tags：自动支持所有 HTML/SVG 标签，杜绝 undefined function
export const tags: Record<string, (p?: Props | null, ...c: Child[]) => HTMLElement | SVGElement> = new Proxy({} as any, {
  get: (_, tag: string) => (p?: Props | null, ...c: Child[]) => h(tag, p, ...c),
});
