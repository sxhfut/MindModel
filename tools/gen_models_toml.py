#!/usr/bin/env python3
"""从 Sources/Catalog.swift 的模型清单生成 data/models.toml。

Swift 的 Catalog.all 是权威源，本脚本把它抽成 TOML，供 Rust 侧与社区 PR 使用。
改模型清单后跑一次：python3 tools/gen_models_toml.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Sources" / "Catalog.swift"
OUT = ROOT / "data" / "models.toml"

PAT = re.compile(
    r'^m\("(.*?)",\s*([0-9.]+),\s*([0-9.]+),\s*\.(\w+),\s*(nil|"(.*?)"),\s*'
    r'([0-9.]+),\s*"(.*?)"(?:,\s*active:\s*([0-9.]+))?\)'
)


def main() -> int:
    src = SRC.read_text(encoding="utf-8")
    lines = [l.strip() for l in src.splitlines() if l.strip().startswith('m("')]
    rows = []
    for l in lines:
        m = PAT.match(l)
        if not m:
            print(f"解析失败：{l}", file=sys.stderr)
            return 1
        name, params, q4, cat, tag_raw, tag, kv, note, active = m.groups()
        tag = None if tag_raw == "nil" else tag
        rows.append((name, params, q4, cat, tag, kv, note, active))

    out = [
        "# MindModel 模型清单（单一数据源）",
        "# 由 tools/gen_models_toml.py 从 Sources/Catalog.swift 生成，不要手改。",
        "# 体积与适配数据取自 localmodel.run 的 Apple M5 Max 128GB 档位（2026-11 快照）；KV cache 为按架构估算。",
        "# 字段：params_b 总参数(十亿)、q4_gb Q4_K_M 权重体积、cat 分类、tag ollama 标签(空为需 HF 搜索)、",
        "#       kv_1k 每 1K token 的 KV cache(GB)、note 备注、active_b MoE 激活参数(缺省=params_b)",
        "",
    ]

    cur = None
    for name, params, q4, cat, tag, kv, note, active in rows:
        if cur != cat:
            cur = cat
            out.append(f"# ---- {cat} ----")
        out.append("[[models]]")
        out.append(f'name = "{name}"')
        out.append(f"params_b = {params}")
        out.append(f"q4_gb = {q4}")
        out.append(f'cat = "{cat}"')
        out.append(f'tag = "{tag}"' if tag else 'tag = ""')
        out.append(f"kv_1k = {kv}")
        out.append(f'note = "{note}"')
        if active:
            out.append(f"active_b = {active}")
        out.append("")

    OUT.write_text("\n".join(out), encoding="utf-8")
    print(f"生成 {OUT.relative_to(ROOT)}：{len(rows)} 条模型")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
