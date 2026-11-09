#!/usr/bin/env python3
"""PT-4: срезанные клетки + ограниченный 2-й порядок (ван Лир = 1, minmod = 3) в picard_rs, solve.

Каждый случай × ограничитель: `picard solve <case>_cut --cut-cells --adv2 <имя> --threads 8 --max-iters 4000
--out out/PT-4/r2/<case>_cut_l<L>.json --save-state D/states/<case>_cut_adv2_l<L>.json` (под `dpcli lock cpu`,
8 слотов), затем строка PT4 (cut_cells = true, adv2 = true; выборка sample.py PT-1) в out/PT-4/rows_combo.jsonl.
Время здесь справочно (locked = false): честное — bench (run_bench.py).

    python3 tools/research/picard_terrain/run_combo.py
"""
from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

import run_adv2 as A

HERE, ROOT, D, BIN = A.HERE, A.ROOT, A.D, A.BIN
OUT = HERE / "out/PT-4"
LIMS = A.LIMS
ROWS = OUT / "rows_combo.jsonl"


def run_one(case: str, lim: int) -> dict:
    name = f"{case}_cut_l{lim}"
    r2p = OUT / "r2" / f"{name}.json"
    st = D / "states" / f"{case}_cut_adv2_l{lim}.json"
    cj = D / "cases" / f"{case}_cut.json"
    cmd = [str(ROOT / ".dpcli/dpcli"), "lock", "cpu", "PT-4", "--no-tmux", "--", str(BIN), "solve", str(cj), "--cut-cells",
           "--adv2", LIMS[lim], "--threads", str(A.THREADS), "--max-iters", str(A.MAX_ITERS), "--out", str(r2p), "--save-state", str(st)]
    print("$", " ".join(cmd), flush=True)
    r2p.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
    r2 = json.loads(r2p.read_text())
    res = r2.get("residuals") or r2["history"][-1]
    status = {"ok": "ok", "diverged": "diverged"}.get(r2["status"], "max")
    note = f"срезанные клетки + adv2 {LIMS[lim]} (limiter {lim}), {A.THREADS} потоков; solve под замком cpu, время справочно (замер — bench)"
    if status == "max":
        s, lvl = A.stalled(r2["history"], r2["iters"])
        if s:
            status = "stalled"
            note += f"; невязка импульса стоит на {lvl:.2e} м/с²"
    cj_state = st
    probes, extra = A.get_probes(f"{case}_cut", cj_state)
    t = r2["time"]
    return {
        "format": "pt-row", "version": 1, "task": "PT-4", "case": f"{case}_cut", "site": case.rsplit("_d", 1)[0],
        "dx": json.loads(cj.read_text())["dx"], "solver": "picard_rs", "dtype": "f32",
        "cut_cells": bool(r2["variant"]["cut_cells"]), "adv2": bool(r2["variant"]["adv2"]), "limiter": lim,
        "status": status, "iters": r2["iters"], "max_iters": A.MAX_ITERS,
        "final": {"mom_rms": res["mom_rms"], "th_rms": res["th_rms"], "div_rms": res["div_rms"]},
        "time": {"total_s": t["total_s"], "ms_per_iter": t["ms_per_iter"], "threads": A.THREADS, "locked": False},
        "r2": str(r2p.relative_to(ROOT)), "state": f"states/{case}_cut_adv2_l{lim}.json", "probes": probes, "rotor": None,
        "masts_rmse": None, "note": note + extra,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", nargs="*", default=A.CASES)
    ap.add_argument("--lims", nargs="*", type=int, default=[1, 3])
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cargo", "build", "-q", "--release", "--manifest-path", str(ROOT / "rust/picard_rs/Cargo.toml")], check=True)
    rows = {(r["case"], r["limiter"]): r for r in A.load_rows(ROWS)}
    for case in a.cases:
        for lim in a.lims:
            r = run_one(case, lim)
            rows[(r["case"], lim)] = r
            with open(ROWS, "w") as fh:
                for k in sorted(rows):
                    fh.write(json.dumps(rows[k], ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
