// skills —— /skills 列表 + skill 工具(按名读 SKILL.md)。内嵌出厂件,默认关,
// 但 pushGates 对装了技能的宿主自动开门(与 agent.zig per-Agent 自动开同则)。同名覆写。
// 搜索序与原 Zig 版一致:<configDir>/skills → <configDir>/packages/*/skills → <cwd>/.piz/packages/*/skills。

function scan(dir, out) {
  const entries = piz.listDir(dir);
  if (!entries) return out;
  for (const e of entries) {
    if (e.kind !== "dir") continue;
    const content = piz.readFile(dir + "/" + e.name + "/SKILL.md");
    if (content == null) continue;
    let name = e.name, desc = "";
    for (const l of String(content).split("\n")) {
      if (l.startsWith("name:")) name = l.slice(5).replace(/^[ \t]+|[ \t]+$/g, "");
      else if (l.startsWith("description:")) {
        desc = l.slice(12).replace(/^[ \t]+|[ \t]+$/g, "");
        if (desc) break;
      }
    }
    out += "- " + name + ": " + desc + "\n";
  }
  return out;
}

function pkgDirs() {
  const out = [];
  const cfg = piz.configDir();
  const roots = [];
  if (cfg) roots.push(cfg + "/packages");
  roots.push(piz.cwd() + "/.piz/packages");
  for (const root of roots) {
    const entries = piz.listDir(root);
    if (!entries) continue;
    for (const e of entries) if (e.kind === "dir") out.push(root + "/" + e.name);
  }
  return out;
}

piz.registerCommand("skills", {
  description: "list available skills",
  handler() {
    const cfg = piz.configDir();
    let out = "";
    if (cfg) out = scan(cfg + "/skills", out);
    for (const pkg of pkgDirs()) out = scan(pkg + "/skills", out);
    return out.length ? out : "no skills";
  },
});

piz.registerTool({
  name: "skill",
  description: "Load a skill's SKILL.md content by name. Skill names are listed in the system prompt.",
  parameters: {
    type: "object",
    properties: { name: { type: "string", description: "Skill name as listed in the skills index." } },
    required: ["name"],
  },
  execute(args) {
    const name = String(args && args.name || "");
    if (!name) return { error: "error: missing 'name' argument" };
    if (!/^[A-Za-z0-9_-]+$/.test(name)) return { error: "error: invalid skill name" };
    const cfg = piz.configDir();
    if (!cfg) return { error: "error: no config dir" };
    const tries = [cfg + "/skills/" + name + "/SKILL.md"];
    for (const pkg of pkgDirs()) tries.push(pkg + "/skills/" + name + "/SKILL.md");
    for (const p of tries) {
      const c = piz.readFile(p);
      if (c != null) return { content: "# Skill " + name + "\n\n" + c };
    }
    return { error: "error: skill '" + name + "' not found in " + cfg + "/skills/ or any installed package" };
  },
});
