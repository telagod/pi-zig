// signal.ts —— 微型细粒度响应式内核 (Zero-dependency Signals)
// 支持依赖自动追踪、惰性计算、批量合并与自动解除订阅。

type Subscriber = () => void;

let activeEffect: Subscriber | null = null;
let batchDepth = 0;
const pendingEffects = new Set<Subscriber>();

export interface Signal<T> {
  (): T;
  get(): T;
  set(next: T): void;
  update(fn: (prev: T) => T): void;
  subscribe(fn: (val: T) => void): () => void;
}

export interface ReadonlySignal<T> {
  (): T;
  get(): T;
  subscribe(fn: (val: T) => void): () => void;
}

export function signal<T>(initialValue: T): Signal<T> {
  let value = initialValue;
  const subscribers = new Set<Subscriber>();

  function read(): T {
    if (activeEffect) {
      subscribers.add(activeEffect);
    }
    return value;
  }

  read.get = () => read();

  read.set = (next: T) => {
    if (Object.is(value, next)) return;
    value = next;
    notify();
  };

  read.update = (fn: (prev: T) => T) => {
    read.set(fn(value));
  };

  read.subscribe = (fn: (val: T) => void): (() => void) => {
    return effect(() => {
      fn(read());
    });
  };

  function notify() {
    for (const sub of subscribers) {
      if (batchDepth > 0) {
        pendingEffects.add(sub);
      } else {
        sub();
      }
    }
  }

  return read;
}

export function computed<T>(computeFn: () => T): ReadonlySignal<T> {
  let cachedValue: T;
  let isDirty = true;
  const subscribers = new Set<Subscriber>();

  const runner = () => {
    if (!isDirty) {
      isDirty = true;
      for (const sub of subscribers) {
        if (batchDepth > 0) {
          pendingEffects.add(sub);
        } else {
          sub();
        }
      }
    }
  };

  function read(): T {
    if (activeEffect) {
      subscribers.add(activeEffect);
    }
    if (isDirty) {
      const prevEffect = activeEffect;
      activeEffect = runner;
      try {
        cachedValue = computeFn();
        isDirty = false;
      } finally {
        activeEffect = prevEffect;
      }
    }
    return cachedValue;
  }

  read.get = () => read();

  read.subscribe = (fn: (val: T) => void): (() => void) => {
    return effect(() => {
      fn(read());
    });
  };

  return read;
}

export function effect(fn: () => void | (() => void)): () => void {
  let cleanup: void | (() => void);
  let isDisposed = false;

  const execute: Subscriber = () => {
    if (isDisposed) return;
    if (cleanup && typeof cleanup === 'function') {
      cleanup();
    }
    const prevEffect = activeEffect;
    activeEffect = execute;
    try {
      cleanup = fn();
    } finally {
      activeEffect = prevEffect;
    }
  };

  execute();

  return () => {
    isDisposed = true;
    if (cleanup && typeof cleanup === 'function') {
      cleanup();
    }
  };
}

export function batch<T>(fn: () => T): T {
  batchDepth++;
  try {
    return fn();
  } finally {
    batchDepth--;
    if (batchDepth === 0) {
      const toRun = Array.from(pendingEffects);
      pendingEffects.clear();
      for (const sub of toRun) {
        sub();
      }
    }
  }
}
