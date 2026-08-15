#!/usr/bin/env python3
"""从 pi-ai 价目 JSON 生成 src/pricing.zig。

用法: scripts/gen_pricing.py [pi-ai providers/data 目录]
默认目录: 本机 pi-coding-agent 安装内的 pi-ai。

每模型一条: "provider/model_id" → 每百万 token 费率 (input/output/cache_read/cache_write)
+ 可选 tier(取 inputTokensAbove 最高一档,对齐 pi calculateCost 的 matchedThreshold 语义)。
"""
import json
import glob
import os
import sys

DEFAULT_DIR = os.path.expanduser(
    "~/.local/share/mise/installs/node/24.17.0/lib/node_modules/"
    "@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/"
    "dist/providers/data"
)
OUT = os.path.join(os.path.dirname(__file__), "..", "src", "pricing.zig")


def main() -> None:
    data_dir = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DIR
    entries: dict[str, dict] = {}
    for path in sorted(glob.glob(os.path.join(data_dir, "*.json"))):
        data = json.load(open(path))
        for _api, models in data.items():
            for _mid, m in models.items():
                cost = m.get("cost")
                if not cost:
                    continue
                key = f"{m['provider']}/{m['id']}"
                ent = {
                    "input": cost.get("input", 0),
                    "output": cost.get("output", 0),
                    "cache_read": cost.get("cacheRead", 0),
                    "cache_write": cost.get("cacheWrite", 0),
                    "tier_above": 0,
                    "t_input": 0.0,
                    "t_output": 0.0,
                    "t_cache_read": 0.0,
                    "t_cache_write": 0.0,
                }
                tiers = cost.get("tiers") or []
                if tiers:
                    top = max(tiers, key=lambda t: t["inputTokensAbove"])
                    ent["tier_above"] = top["inputTokensAbove"]
                    ent["t_input"] = top.get("input", 0)
                    ent["t_output"] = top.get("output", 0)
                    ent["t_cache_read"] = top.get("cacheRead", 0)
                    ent["t_cache_write"] = top.get("cacheWrite", 0)
                entries[key] = ent  # 后写覆盖:同 key 跨 api 组去重

    lines = [
        "// 代码生成,勿手改。源: pi-ai dist/providers/data/*.json",
        "// 再生成: scripts/gen_pricing.py",
        "",
        "/// 每百万 token 费率(USD)。tier_above 非零时,单轮 input+cache 总量",
        "/// 超阈则全轮按 tier 费率(pi calculateCost 语义,取最高阈档)。",
        "pub const Rates = struct {",
        "    input: f64,",
        "    output: f64,",
        "    cache_read: f64,",
        "    cache_write: f64,",
        "    tier_above: u32 = 0,",
        "    t_input: f64 = 0,",
        "    t_output: f64 = 0,",
        "    t_cache_read: f64 = 0,",
        "    t_cache_write: f64 = 0,",
        "};",
        "",
        "pub const table = std.StaticStringMap(Rates).initComptime(.{",
    ]
    for key in sorted(entries):
        e = entries[key]
        lines.append(
            '    .{ "%s", Rates{ .input = %r, .output = %r, .cache_read = %r, '
            ".cache_write = %r, .tier_above = %d, .t_input = %r, .t_output = %r, "
            ".t_cache_read = %r, .t_cache_write = %r } },"
            % (
                key, e["input"], e["output"], e["cache_read"], e["cache_write"],
                e["tier_above"], e["t_input"], e["t_output"],
                e["t_cache_read"], e["t_cache_write"],
            )
        )
    lines += [
        "});",
        "",
        "/// 查 \"provider/model_id\" 费率;无价目返回 null(footer 不显 $)。",
        "pub fn lookup(key: []const u8) ?Rates {",
        "    return table.get(key);",
        "}",
        "",
        "/// 单轮费用:usage 各项 × 费率 / 1e6。tier 以 input+cache 总量判定。",
        "/// input 为 prompt 总量(OpenAI 系含命中),内部扣 cache_read 得 miss ——",
        "/// miss 按 input 价、命中按 cache_read 价;Anthropic 系 input 本不含命中,减 0 无损。",
        "pub fn turnCost(r: Rates, input: u64, output: u64, cache_read: u64, cache_write: u64) f64 {",
        "    var ri = r.input;",
        "    var ro = r.output;",
        "    var rcr = r.cache_read;",
        "    var rcw = r.cache_write;",
        "    if (r.tier_above > 0 and input + cache_read + cache_write > r.tier_above) {",
        "        ri = r.t_input;",
        "        ro = r.t_output;",
        "        rcr = r.t_cache_read;",
        "        rcw = r.t_cache_write;",
        "    }",
        "    const M: f64 = 1_000_000;",
        "    const miss = input -| cache_read;",
        "    return (@as(f64, @floatFromInt(miss)) * ri +",
        "        @as(f64, @floatFromInt(output)) * ro +",
        "        @as(f64, @floatFromInt(cache_read)) * rcr +",
        "        @as(f64, @floatFromInt(cache_write)) * rcw) / M;",
        "}",
        "",
        "const std = @import(\"std\");",
        "",
    ]
    out = os.path.normpath(OUT)
    with open(out, "w") as f:
        f.write("\n".join(lines))
    print(f"{out}: {len(entries)} models, {sum(1 for e in entries.values() if e['tier_above'])} tiered")


if __name__ == "__main__":
    main()
