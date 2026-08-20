// todo —— 结构化计划清单:todo_write/todo_read + /todo。内嵌出厂件,默认关,同名覆写。
// 态按会话隔离(原版按 Agent 指针;此以快照 sid 为 key),进程终即收。
// 语义与原 Zig 版逐条同:replace 全量、merge 按 id 补丁、自动 id t1..、bind 挂 workflow 节点。
const store = Object.create(null);

function key() {
  const s = piz.contextStats();
  return (s && s.sid != null) ? String(s.sid) : "_";
}
function list() { return store[key()] || []; }
function glyph(s) { return s === "completed" ? "[x]" : s === "in_progress" ? "[>]" : "[ ]"; }
function findId(items, id) { for (let i = 0; i < items.length; i++) if (items[i].id === id) return i; return -1; }
function nextAutoId(items) {
  let max = 0;
  for (const it of items) {
    if (it.id.length >= 2 && it.id[0] === "t") {
      const n = parseInt(it.id.slice(1), 10);
      if (!isNaN(n) && String(n) === it.id.slice(1) && n > max) max = n;
    }
  }
  return "t" + (max + 1);
}
function parseStatus(raw) {
  return raw === "pending" || raw === "in_progress" || raw === "completed" ? raw : null;
}
function parseIncoming(e) {
  if (!e || typeof e !== "object" || Array.isArray(e)) return { fail: "error: each item must be an object" };
  const content = typeof e.content === "string" ? e.content : "";
  const id = typeof e.id === "string" ? e.id : "";
  let status = null;
  if (typeof e.status === "string") {
    status = parseStatus(e.status);
    if (!status) return { fail: "error: bad status '" + e.status + "'; use pending | in_progress | completed" };
  }
  const bind = typeof e.bind === "string" ? e.bind : null;
  return { ok: { id, content, status, bind } };
}
function render(items) {
  if (!items.length) return { content: "todo list is empty" };
  let done = 0, out = "";
  for (const it of items) {
    if (it.status === "completed") done++;
    out += glyph(it.status) + " " + it.content + (it.bind ? "  @" + it.bind : "") + "\n";
  }
  out += "(" + done + "/" + items.length + " done)";
  return { content: out };
}

function write(args) {
  if (!args || typeof args !== "object" || Array.isArray(args))
    return { error: "error: arguments must be an object" };
  const arr = args.items;
  if (arr === undefined || arr === null) return { error: "error: missing 'items' array" };
  if (!Array.isArray(arr)) return { error: "error: 'items' must be an array" };
  const mode = typeof args.mode === "string" ? args.mode : "replace";
  const merge = mode === "merge" ? true : mode === "replace" ? false : null;
  if (merge === null) return { error: "error: mode must be replace | merge" };
  const k = key();

  if (merge) {
    const cur = list().map(it => ({ id: it.id, content: it.content, status: it.status, bind: it.bind }));
    for (const e of arr) {
      const p = parseIncoming(e);
      if (p.fail) return { error: p.fail };
      const inc = p.ok;
      if (inc.id) {
        const idx = findId(cur, inc.id);
        if (idx >= 0) {
          if (inc.content) cur[idx].content = inc.content;
          if (inc.status) cur[idx].status = inc.status;
          if (inc.bind != null) cur[idx].bind = inc.bind;
          continue;
        }
      }
      if (!inc.content) return { error: "error: new item missing 'content'" };
      const id = inc.id || nextAutoId(cur);
      if (findId(cur, id) >= 0) return { error: "error: duplicate id '" + id + "'" };
      cur.push({ id, content: inc.content, status: inc.status || "pending", bind: inc.bind || "" });
    }
    store[k] = cur;
    return render(cur);
  }

  const items = [];
  for (const e of arr) {
    const p = parseIncoming(e);
    if (p.fail) return { error: p.fail };
    const inc = p.ok;
    if (!inc.content) return { error: "error: item 'content' must be a non-empty string" };
    const id = inc.id || ("t" + (items.length + 1));
    if (findId(items, id) >= 0) return { error: "error: duplicate id '" + id + "'" };
    items.push({ id, content: inc.content, status: inc.status || "pending", bind: inc.bind || "" });
  }
  store[k] = items;
  return render(items);
}

piz.registerTool({
  name: "todo_write",
  description: "Update the task list for this session. Default mode replace swaps the whole list. mode merge updates items with the same id and appends new ones, so you do not have to resend finished work. Optional bind attaches an item to a workflow node id.",
  parameters: {
    type: "object",
    properties: {
      mode: { type: "string", enum: ["replace", "merge"], description: "replace (default) swaps the list. merge updates matching ids and appends the rest." },
      items: { type: "array", description: "Task items. On replace this is the full list. On merge, matching id updates fields; new id appends.", items: { type: "object", properties: {
        id: { type: "string", description: "Stable item id. Assigned as t1, t2, … if omitted." },
        content: { type: "string", description: "Task description, 5-10 words." },
        status: { type: "string", enum: ["pending", "in_progress", "completed"], description: "Task state." },
        bind: { type: "string", description: "Optional workflow node id this item tracks." },
      }, required: ["content"] } },
    },
    required: ["items"],
  },
  execute(args) { return write(args); },
});

piz.registerTool({
  name: "todo_read",
  description: "Read the current task list for this session.",
  parameters: {},
  execute() { return render(list()); },
});

piz.registerCommand("todo", {
  description: "list session todos",
  handler() { const r = render(list()); return r.content; },
});
