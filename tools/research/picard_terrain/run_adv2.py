#!/usr/bin/env python3
"""PT-3: прогоны picard_rs со вторым порядком переноса (ван Лир = 1, minmod = 3) на случаях PT1.

Каждый случай × ограничитель: `picard solve <case> --adv2 <имя> --threads 8 --max-iters 4000 --out
out/PT-3/r2/<case>_l<L>.json --save-state D/states/<case>_adv2_l<L>.json`, затем строка PT4 в
out/PT-3/rows.jsonl (sample.py PT-1 → пробы S, dS) и итог out/PT-3/table.md (база — out/PT-1/rows.jsonl).
Под замком cpu (время сравнимо только при locked): запускать как

    .dpcli/dpcli lock cpu PT-3 --no-tmux -- python3 tools/research/picard_terrain/run_adv2.py --locked
    python3 tools/research/picard_terrain/run_adv2.py --table-only        # только пересобрать table.md

Статус: ok (критерий достигнут), diverged, max (предел итераций), stalled — предел, и невязка импульса не
упала вдвое за последние 50 % итераций (PT4); для stalled в note — уровень невязки импульса.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
D = Path(os.environ.get("PICARD_TERRAIN_DATA", Path.home() / "data/picard_terrain"))
BIN = ROOT / "rust/picard_rs/target/release/picard"
OUT = HERE / "out/PT-3"
CASES = ["askervein_d50", "askervein_d100", "kayancha_d50", "kayancha_d100", "perdigao_ne_d30", "perdigao_sw_d30"]
LIMS = {1: "vanleer", 3: "minmod"}
THREADS = 8
MAX_ITERS = 4000


def stalled(hist: list[dict], iters: int):
    """Невязка импульса за последние 50 % итераций упала меньше чем вдвое → (True, уровень), иначе (False, None)."""
    if len(hist) < 4:
        return False, None
    last = hist[-1]
    half = [h for h in hist if h["it"] <= iters / 2]
    if not half:
        return False, None
    if last["mom_rms"] > 0.5 * half[-1]["mom_rms"]:
        return True, last["mom_rms"]
    return False, None


def run_one(case: str, lim: int, locked: bool) -> dict:
    name = f"{case}_l{lim}"
    r2p = OUT / "r2" / f"{name}.json"
    st = D / "states" / f"{case}_adv2_l{lim}.json"
    cj = D / "cases" / f"{case}.json"
    cmd = [str(BIN), "solve", str(cj), "--adv2", LIMS[lim], "--threads", str(THREADS), "--max-iters", str(MAX_ITERS),
           "--out", str(r2p), "--save-state", str(st)]
    print("$", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
    r2 = json.loads(r2p.read_text())
    res = r2.get("residuals") or r2["history"][-1]
    hist = r2["history"]
    status = {"ok": "ok", "diverged": "diverged"}.get(r2["status"], "max")
    note = f"adv2 {LIMS[lim]} (limiter {lim}), {THREADS} потоков"
    if status == "max":
        s, lvl = stalled(hist, r2["iters"])
        if s:
            status = "stalled"
            note += f"; невязка импульса стоит на {lvl:.2e} м/с²"
    probes = []
    try:
        sys.path.insert(0, str(HERE))
        import sample  # PT-1
        probes = sample.probe_values(str(cj), str(st))
        cp = json.loads(cj.read_text())["pt"]["probes"]
        pair = {p["name"]: p["pair"] for p in cp}
        sv = {p["name"]: p["S"] for p in probes}
        for p in probes:
            if "dS" not in p:
                q = pair.get(p["name"])
                p["dS"] = (p["S"] / sv[q] - 1.0) if q else None
        probes = [{k: p.get(k) for k in ("name", "z_agl", "S", "dS")} for p in probes]
    except ImportError:
        note += "; sample.py не найден — пробы пусты"
    t = r2["time"]
    return {
        "format": "pt-row", "version": 1, "task": "PT-3", "case": case, "site": case.rsplit("_d", 1)[0],
        "dx": json.loads(cj.read_text())["dx"], "solver": "picard_rs", "dtype": "f32",
        "cut_cells": bool(r2["variant"]["cut_cells"]), "adv2": True, "limiter": lim,
        "status": status, "iters": r2["iters"], "max_iters": MAX_ITERS,
        "final": {"mom_rms": res["mom_rms"], "th_rms": res["th_rms"], "div_rms": res["div_rms"]},
        "time": {"total_s": t["total_s"], "ms_per_iter": t["ms_per_iter"], "threads": THREADS, "locked": locked},
        "r2": str(r2p.relative_to(ROOT)), "state": str(st), "probes": probes, "rotor": None, "masts_rmse": None,
        "note": note,
    }


def load_rows(p: Path):
    return [json.loads(x) for x in p.read_text().splitlines() if x.strip()] if p.exists() else []


def table():
    rows = load_rows(OUT / "rows.jsonl")
    base = {r["case"]: r for r in load_rows(HERE / "out/PT-1/rows.jsonl")
            if r.get("solver") == "picard_rs" and not r["adv2"] and not r["cut_cells"]}
    ref = {r["case"]: r for r in load_rows(HERE / "out/PT-1/rows.jsonl") if r.get("solver") == "air3d"}

    def pv(r, name):
        for p in (r or {}).get("probes", []):
            if p["name"] == name:
                return p
        return None

    def f(x, fmt):
        return "—" if x is None else format(x, fmt)

    L = ["# PT-3: ограниченный 2-й порядок переноса, picard_rs (f32, 8 потоков, под замком cpu)", "",
         "ΔS = S(HT)/S(RS) − 1 (Askervein), S — скорость над стартом (Каянча); база — 1-й порядок picard_rs на той же сетке "
         "(out/PT-1), эталон — air3d f64 (2-й порядок, сетка 12,5–25 м, строки PT-1). «—» — нет строки базы/эталона.", "",
         "| случай | ограничитель | статус | итер. | мс/итер | невязка имп. | ΔS HT10 | HT30 | S старт 30 м | база итер. | база мс/итер |",
         "|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in sorted(rows, key=lambda r: (r["case"], r["limiter"])):
        b = base.get(r["case"])
        h10, h30 = pv(r, "HT_10"), pv(r, "HT_30")
        st = next((p for p in r["probes"] if p["name"].startswith("start") and p["z_agl"] == 30), None)
        L.append(f"| {r['case']} | {LIMS[r['limiter']]} | {r['status']} | {r['iters']} | {r['time']['ms_per_iter']:.0f} | "
                 f"{r['final']['mom_rms']:.1e} | {f(h10 and h10['dS'], '+.3f')} | {f(h30 and h30['dS'], '+.3f')} | "
                 f"{f(st and st['S'], '.2f')} | {f(b and b['iters'], 'd')} | {f(b and b['time']['ms_per_iter'], '.0f')} |")
    L += ["", "Эталон air3d (2-й порядок): " + (", ".join(sorted(ref)) or "строк в out/PT-1 нет") + "."]
    (OUT / "table.md").write_text("\n".join(L) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--locked", action="store_true", help="запуск под замком cpu (пишется в time.locked)")
    ap.add_argument("--table-only", action="store_true")
    ap.add_argument("--cases", nargs="*", default=CASES)
    ap.add_argument("--lims", nargs="*", type=int, default=[1, 3])
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if not a.table_only:
        subprocess.run(["cargo", "build", "-q", "--release", "--manifest-path", str(ROOT / "rust/picard_rs/Cargo.toml")], check=True)
        rows = {(r["case"], r["limiter"]): r for r in load_rows(OUT / "rows.jsonl")}
        for case in a.cases:
            for lim in a.lims:
                rows[(case, lim)] = run_one(case, lim, a.locked)
                with open(OUT / "rows.jsonl", "w") as fh:
                    for k in sorted(rows):
                        fh.write(json.dumps(rows[k], ensure_ascii=False) + "\n")
    table()


if __name__ == "__main__":
    main()
