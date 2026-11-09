#!/usr/bin/env python3
"""PT-4: замер времени всех вариантов одной пачкой (bench --solve, 8 потоков, замок cpu) и итог.

  run_bench.py start     один запуск job под замком cpu: 6 вариантов (база, cut, ван Лир, minmod, cut+ван Лир,
                         cut+minmod) × 6 случаев PT1 = 36 `picard bench <case> --solve --threads 8 --max-iters 4000
                         [--cut-cells] [--adv2 ..] --out-dir D/bench/PT-4/<case>_<variant>`
  run_bench.py collect   строки PT4 -> out/PT-4/rows.jsonl (время, статус, итерации, невязки — из bench; пробы — из
                         solve того же варианта: PT-1/2/3 или rows_combo.jsonl) и out/PT-4/table.md
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
D = Path(os.environ.get("PICARD_TERRAIN_DATA", Path.home() / "data/picard_terrain"))
OUT = HERE / "out/PT-4"
BENCH = D / "bench/PT-4"
BIN = ROOT / "rust/target/release/picard"
CASES = ["askervein_d50", "askervein_d100", "kayancha_d50", "kayancha_d100", "perdigao_ne_d30", "perdigao_sw_d30"]
# вариант: (cut, limiter | None, подпись)
VARIANTS = {"base": (False, None, "1-й порядок (база)"), "cut": (True, None, "срезанные клетки"),
            "vl": (False, 1, "ван Лир"), "mm": (False, 3, "minmod"),
            "cut_vl": (True, 1, "срезанные + ван Лир"), "cut_mm": (True, 3, "срезанные + minmod")}
LNAME = {1: "vanleer", 3: "minmod"}
THREADS, MAX_ITERS = 8, 4000


def load_rows(p: Path):
    return [json.loads(x) for x in p.read_text().splitlines() if x.strip()] if p.exists() else []


def cmd_for(case: str, v: str) -> str:
    cut, lim, _ = VARIANTS[v]
    cf = D / "cases" / (f"{case}_cut.json" if cut else f"{case}.json")
    s = f"{BIN} bench {cf} --solve --threads {THREADS} --max-iters {MAX_ITERS}"
    if cut:
        s += " --cut-cells"
    if lim:
        s += f" --adv2 {LNAME[lim]}"
    return s + f" --out-dir {BENCH}/{case}_{v}"


def start():
    subprocess.run(["cargo", "build", "-q", "--release", "--manifest-path", str(ROOT / "rust/picard_rs/Cargo.toml")], check=True)
    lines = []
    for c in CASES:
        for v in VARIANTS:
            lines.append(f"mkdir -p {BENCH}/{c}_{v} && {cmd_for(c, v)}")
    script = " && ".join(lines)
    subprocess.run([str(ROOT / ".dpcli/dpcli"), "job", "--lock", "cpu", "--no-tmux", "start", "pt4-bench", "7200", "bash", "-c", script], check=True)


def source_row(case: str, v: str, rows: dict):
    cut, lim, _ = VARIANTS[v]
    if cut and lim:
        return rows["combo"].get((f"{case}_cut", lim))
    if cut:
        return rows["pt2"].get(f"{case}_cut")
    if lim:
        return rows["pt3"].get((case, lim))
    return rows["pt1"].get(case)


def load_sources():
    o = HERE / "out"
    pt1 = load_rows(o / "PT-1/rows.jsonl")
    return {
        "pt1": {r["case"]: r for r in pt1 if r["solver"] == "picard_rs" and not r["adv2"] and not r["cut_cells"]},
        "ref": {r["case"]: r for r in pt1 if r["solver"] == "air3d" and r["adv2"]},
        "pt2": {r["case"]: r for r in load_rows(o / "PT-2/rows.jsonl")},
        "pt3": {(r["case"], r["limiter"]): r for r in load_rows(o / "PT-3/rows.jsonl")},
        "combo": {(r["case"], r["limiter"]): r for r in load_rows(OUT / "rows_combo.jsonl")},
    }


def collect():
    src = load_sources()
    out = []
    for c in CASES:
        for v, (cut, lim, label) in VARIANTS.items():
            fs = sorted((BENCH / f"{c}_{v}").glob("*.json"))
            if not fs:
                sys.exit(f"нет результата bench: {c}_{v}")
            r2p = fs[0]
            r2 = json.loads(r2p.read_text())
            s = source_row(c, v, src)
            if s is None:
                sys.exit(f"нет строки-источника для {c}_{v}")
            res = r2.get("residuals") or r2["history"][-1]
            status = {"ok": "ok", "diverged": "diverged"}.get(r2["status"], "max")
            note = f"{label}; время — bench --solve, {THREADS} потоков, замок cpu (locked); пробы — solve {s['task']}"
            if status == "max":
                note += f"; предел итераций, невязка импульса {res['mom_rms']:.2e}"
                if s["status"] == "stalled":
                    status = "stalled"
            if s["iters"] != r2["iters"]:
                note += f"; итераций solve {s['iters']} / bench {r2['iters']}"
            t = r2["time"]
            row = dict(s)
            row.update(task="PT-4", status=status, iters=r2["iters"], max_iters=MAX_ITERS,
                       final={"mom_rms": res["mom_rms"], "th_rms": res["th_rms"], "div_rms": res["div_rms"]},
                       time={"total_s": t["total_s"], "ms_per_iter": t["ms_per_iter"], "threads": THREADS, "locked": True},
                       r2=str(r2p.relative_to(D)), note=note)
            row["r2"] = "bench/PT-4/" + str(r2p.relative_to(BENCH))
            out.append(row)
    with open(OUT / "rows.jsonl", "w") as fh:
        for r in out:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    table(out, src)


def table(rows, src):
    by = {}
    for r in rows:
        base = r["case"][:-4] if r["case"].endswith("_cut") else r["case"]
        cut, lim = r["cut_cells"], r["limiter"]
        v = next(k for k, (c_, l_, _) in VARIANTS.items() if c_ == cut and l_ == lim)
        by[(base, v)] = r

    def pv(r, name, key):
        for p in r["probes"]:
            if p["name"] == name:
                return p[key]

    ask = ["HT_10", "HT_30", "HT_60", "HT_100"]
    kay = ["START_20", "START_30", "START_50", "START_100"]
    refs = src["ref"]

    def f(x, fmt):
        return "—" if x is None else format(x, fmt)

    L = ["# PT-4: срезанные клетки вместе со 2-м порядком; время всех вариантов", "",
         "picard_rs f32, `bench --solve` под замком cpu (locked), 8 потоков, до 4000 итераций, критерий случая; "
         "статус, итерации и время — из bench, пробы — из solve того же варианта (PT-1/2/3, комбинации — `rows_combo.jsonl`). "
         "Выборка — PT5 (`sample.py`). На d50/d100 «10 м» = значение нижней клетки воздуха (её центр выше 10 м), у срезанных "
         "клеток эта клетка ниже и ближе к рельефу, чем у ступеней. Эталон — air3d f64, 2-й порядок (ван Лир): d12p5 "
         "(Askervein), d25 (Каянча).",
         "Мера возврата — доля пути от базы до эталона: (вариант − база) / (эталон − база); >100 % — выше эталона, <0 — дальше "
         "от него, чем база.", ""]
    names = list(VARIANTS)

    def block(site, probes, key, fmt, refname, title):
        L.extend([f"## {title}", ""])
        for d in ("d100", "d50"):
            c = f"{site}_{d}"
            ref = refs[f"{site}_{refname}"]
            L.extend([f"### {d[1:]} м", "",
                      "| вариант | " + " | ".join(p.split("_")[1] + " м" for p in probes) + " | итер. | статус | невязка имп. |",
                      "|---|" + "---|" * (len(probes) + 3)])
            for v in names:
                r = by[(c, v)]
                L.append(f"| {VARIANTS[v][2]} | " + " | ".join(f(pv(r, p, key), fmt) for p in probes) +
                         f" | {r['iters']} | {r['status']} | {r['final']['mom_rms']:.1e} |")
            L.append(f"| эталон {refname} air3d f64 | " + " | ".join(f(pv(ref, p, key), fmt) for p in probes) + f" | {ref['iters']} | {ref['status']} | |")
            L.extend(["", "Возврат пути от базы к эталону, %:", "",
                      "| вариант | " + " | ".join(p.split("_")[1] + " м" for p in probes) + " |", "|---|" + "---|" * len(probes)])
            for v in names[1:]:
                r, b = by[(c, v)], by[(c, "base")]
                cells = []
                for p in probes:
                    e, x0, x1 = pv(ref, p, key), pv(b, p, key), pv(r, p, key)
                    cells.append("—" if None in (e, x0, x1) or abs(e - x0) < 1e-9 else f"{(x1 - x0) / (e - x0) * 100:.0f}")
                L.append(f"| {VARIANTS[v][2]} | " + " | ".join(cells) + " |")
            L.append("")

    block("askervein", ask, "dS", "+.3f", "d12p5", "Askervein: ΔS = S(HT)/S(RS) − 1 на той же высоте над землёй")
    block("kayancha", kay, "S", ".2f", "d25", "Каянча: S над стартом, м/с")
    L.extend(["## Стоимость: bench --solve, 8 потоков (locked)", "",
              "| случай | вариант | итер. | мс/итер. | всего, с | к базе (всего) | к базе (мс/итер.) | статус |", "|---|---|---|---|---|---|---|---|"])
    for c in CASES:
        b = by[(c, "base")]
        for v in names:
            r = by[(c, v)]
            L.append(f"| {c} | {VARIANTS[v][2]} | {r['iters']} | {r['time']['ms_per_iter']:.1f} | {r['time']['total_s']:.2f} | "
                     f"×{r['time']['total_s'] / b['time']['total_s']:.2f} | ×{r['time']['ms_per_iter'] / b['time']['ms_per_iter']:.2f} | {r['status']} |")
    L.append("")
    (OUT / "table.md").write_text("\n".join(L) + "\n")


if __name__ == "__main__":
    {"start": start, "collect": collect}.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: sys.exit(__doc__))()
