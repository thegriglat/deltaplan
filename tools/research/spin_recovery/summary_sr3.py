#!/usr/bin/env python3
"""SR-3: out/sr-3/raw/*.json → runs.jsonl, summary.json, tables.md (SR-К2). python3 tools/research/spin_recovery/summary_sr3.py"""
import json, re, statistics, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
D = ROOT / "tools/research/spin_recovery/out/sr-3"
V = ["game", "strips_id", "sprog2_a", "sprog2_b", "sprog3_a", "sprog3_b", "clmax2_10", "clmax2_15", "clmax3_10", "clmax3_15"]
VDOC = {"game": "игра как есть", "strips_id": "наследник SR3Strips с выключенными правками (= game)"}
for n in (2, 3):
    for s, w in (("a", 4), ("b", 7)):
        VDOC[f"sprog{n}_{s}"] = f"упор концов: {n} крайних полос консоли, α_геом ≤ корень − {w}° (оценка, не замер)"
    for k in (10, 15):
        VDOC[f"clmax{n}_{k}"] = f"C_L max {n} крайних полос консоли × {1 + k / 100:.2f}, затем match_polar_cl_max"
MODES = ["release", "standard", "pull_release"]
W = ["sport", "laminar", "training"]


def main():
    runs = [json.loads(p.read_text()) for p in sorted((D / "raw").glob("*.json"))]
    runs.sort(key=lambda r: (V.index(r["variant"]), W.index(r["wing"]), MODES.index(r["mode"]), -r["dt"]))
    (D / "runs.jsonl.tmp").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in runs))
    (D / "runs.jsonl.tmp").rename(D / "runs.jsonl")
    commit = subprocess.run(["git", "log", "-1", "--format=%h", "--", "tools/research/spin_recovery/spin_run.gd"], cwd=ROOT,
                            capture_output=True, text=True).stdout.strip() or "uncommitted"
    rows = [{k: v for k, v in r.items() if k != "extra"} for r in runs]
    s = {"contract": "SR-К2 v1", "task": "SR-3", "commit": commit,
         "cmd": ["python3 tools/research/spin_recovery/run_sr3.py -j 10", "python3 tools/research/spin_recovery/summary_sr3.py"],
         "variants": VDOC, "rows": rows}
    (D / "summary.json.tmp").write_text(json.dumps(s, ensure_ascii=False, indent=1))
    (D / "summary.json.tmp").rename(D / "summary.json")
    by = {(r["wing"], r["variant"], r["mode"], round(1 / r["dt"])): r for r in runs}
    rev = json.loads((D / "reversal.json").read_text())

    def rec(w, v, m):
        rs = [by[(w, v, m, d)] for d in (120, 60, 30)]
        return sum(r["recovered"] for r in rs), rs

    def pr(w, v):
        n, rs = rec(w, v, "pull_release")
        t = [r["recover_s"] for r in rs if r["recovered"]]
        return f"{n}/3" + (f", мед {statistics.median(t):.1f} ({min(t):.1f}–{max(t):.1f}) с" if t else "")

    o = ["# SR-3: таблицы\n",
         "Штопор — release, 1/120: рыскание °/с / макс. снижение м/с / макс. крен °. Выход — число шагов из 3 (1/120, 1/60, 1/30), где recovered. "
         "pull_release: выходов, медиана и размах recover_s. Переложение 45→45 — шаг 1/120, с.\n",
         "| крыло | вариант | рыск. °/с | снижение м/с | крен ° | release | standard | pull_release | 45→45, с | срез упора, ° | C_L max полосы |",
         "|---|---|---|---|---|---|---|---|---|---|---|"]
    for w in W:
        for v in V:
            a = by[(w, v, "release", 120)]
            sp = a["extra"].get("sprog_active_max_deg")
            o.append(f"| {w} | {v} | {a['spin_yaw_dps']:.0f} | {a['spin_sink_max_ms']:.1f} | {a['spin_bank_max_deg']:.0f} | "
                     f"{rec(w, v, 'release')[0]}/3 | {rec(w, v, 'standard')[0]}/3 | {pr(w, v)} | "
                     f"{('%.2f' % rev[w][v]) if isinstance(rev[w].get(v), (int, float)) else '—'} | "
                     f"{('%.1f' % sp) if sp is not None else '—'} | {a['extra']['info']['cl_max_strip']:.4f} |")
    (D / "tables.md").write_text("\n".join(o) + "\n")
    print("rows", len(rows), "commit", commit)


main()
