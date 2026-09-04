// bus.ts —— 统一强类型事件总线 (Typed Event Bus)
// 彻底解耦模块间动作分发，根除 *H 钩袋、手工接线板与循环依赖。

export interface BusEvents {
  // 弹层与菜单收起 (替代 dlgHooks)
  "popups:dismiss": void;
  // 会话切换选中 (替代 sessHooks)
  "session:select": any;
  // 触发斜杠命令 (替代 modelH.runSlash)
  "slash:run": { cmd: { name: string; [k: string]: any }; arg?: string };
  // 消息发送与重试 (解耦 chat/plugins/slash 与 composer)
  "chat:send": { text: string };
  "chat:retry": void;
  // composer 状态/动作通知
  "composer:refresh-send": void;
  "composer:ensure-act-poll": void;
  "composer:clear-pending": void;
  "composer:paste-image": { callback: (ok: boolean) => void };
  // 搜索面板打开
  "search:open": void;
  // 鉴权成功续跑 boot (替代 setOnAuthed)
  "auth:success": void;
}

type Handler<T> = (payload: T) => void;
const listeners = new Map<string, Set<Handler<any>>>();

export function on<K extends keyof BusEvents>(event: K, handler: Handler<BusEvents[K]>): () => void {
  let set = listeners.get(event);
  if (!set) {
    set = new Set();
    listeners.set(event, set);
  }
  set.add(handler);
  return () => {
    set?.delete(handler);
  };
}

export function emit<K extends keyof BusEvents>(
  event: K,
  ...args: BusEvents[K] extends void ? [] : [BusEvents[K]]
): void {
  const set = listeners.get(event);
  if (set) {
    for (const h of set) {
      try {
        h(args[0]);
      } catch (err) {
        console.error(`[piz bus] Error handling "${event}":`, err);
      }
    }
  }
}
