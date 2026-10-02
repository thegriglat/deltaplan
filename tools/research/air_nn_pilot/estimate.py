#!/usr/bin/env python3
"""Оценка полного досчёта набора main: время GPU и диск — по замерам этого кода (готовые случаи набора) и по 49
случаям air-lite (`research/air-lite:tools/research/air_lite/out/runs.jsonl`, тот же решатель и условия).

Время случая = время решателя (сумма t_init + t_solve решений из runs) × накладные (запись, срезы, загрузка места) —
отношение t_wall / время решателя на замерах этого кода. Для встроенных и синтетики среднее время решателя — по
air-lite (49 случаев, в т. ч. 8 «max»), для процедурных — по синтетике air-lite (тот же формат: 1 окно) и, для
сверки, по своим замерам. Повтор случаев air-lite этим кодом: итерации должны совпасть.

  .venv/bin/python estimate.py [--dataset main] [--out figures/estimate.json]
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
from pathlib import Path

import numpy as np

import dataset as DS

HERE = Path(__file__).resolve().parent
REF = "research/air-lite:tools/research/air_lite/out/runs.jsonl"


def solver_t(runs):
    return sum(v["t_solve"] + v["t_init"] for v in runs.values())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", default="main")
    ap.add_argument("--data-root", default=None)
    ap.add_argument("--out", default=str(HERE / "figures/estimate.json"))
    a = ap.parse_args()
    cfg = DS.load_cfg(HERE / "configs/dataset.yaml")
    L = DS.Layout(cfg, a.data_root or os.environ.get("AIR_NN_DATA") or cfg["data_root"], a.dataset)
    con = sqlite3.connect(f"file:{L.db}?mode=ro", uri=True)
    rows = con.execute("SELECT id, kind, t_wall, iters, solve_status, runs, bytes FROM cases WHERE status='done'").fetchall()
    n_kind = dict(con.execute("SELECT kind, COUNT(*) FROM cases GROUP BY kind").fetchall())
    con.close()
    mine = {}
    for cid, kind, tw, it, ss, runs, b in rows:
        runs = json.loads(runs)
        mine[cid] = dict(kind=kind, t_wall=tw, t_solver=round(solver_t(runs), 2), iters=it, status=ss, mb=b / 1e6)
    ref = {}
    txt = subprocess.run(["git", "-C", str(HERE), "show", REF], capture_output=True, text=True, check=True).stdout
    for line in txt.splitlines():
        r = json.loads(line)
        ref[r["id"]] = dict(kind=DS.kind_of(r["loc"]), t_solver=round(solver_t(r["runs"]), 2),
                            iters=sum(v["iters"] for v in r["runs"].values()), status=r["status"])
    out = dict(measured=mine, n_cases=n_kind)
    print("замеры этого кода (t_wall — без ожидания GPU):")
    for cid, m in mine.items():
        rr = ref.get(cid)
        same = "" if rr is None else f" | air-lite: {rr['iters']} ит., решатель {rr['t_solver']:.1f} с" + \
            (" — итерации совпали" if rr["iters"] == m["iters"] else " — ИТЕРАЦИИ РАЗНЫЕ")
        print(f"  {cid:14s} {m['kind']:5s} {m['status']:3s} {m['iters']:6d} ит., {m['t_wall']:6.1f} с (решатель "
              f"{m['t_solver']:.1f} с), {m['mb']:.2f} МБ{same}")
    ratio = {}
    for kind in ("real", "synth", "proc"):
        ms = [m for m in mine.values() if m["kind"] == kind]
        if ms:
            ratio[kind] = float(np.sum([m["t_wall"] for m in ms]) / np.sum([m["t_solver"] for m in ms]))
    r_all = float(np.sum([m["t_wall"] for m in mine.values()]) / np.sum([m["t_solver"] for m in mine.values()]))
    est, tot_h, tot_gb = {}, 0.0, 0.0
    print("оценка (среднее время решателя × накладные; диск — средний размер своих файлов):")
    for kind in ("real", "synth", "proc"):
        src = "synth" if kind == "proc" else kind
        rs = [r for r in ref.values() if r["kind"] == src]
        t_ref = float(np.mean([r["t_solver"] for r in rs]))
        f_max = float(np.mean([r["status"] != "ok" for r in rs]))
        rk = ratio.get(kind, r_all)
        t_case = t_ref * rk
        ms = [m for m in mine.values() if m["kind"] == kind]
        mb = float(np.mean([m["mb"] for m in ms])) if ms else float("nan")
        n = n_kind.get(kind, 0)
        h = n * t_case / 3600
        gb = n * mb / 1e3
        tot_h += h
        tot_gb += gb
        est[kind] = dict(n=n, airlite_cases=len(rs), airlite_solver_mean_s=round(t_ref, 2), airlite_max_frac=round(f_max, 3),
                         overhead=round(rk, 3), case_s=round(t_case, 2), hours=round(h, 2), mb=round(mb, 3), gb=round(gb, 2),
                         measured_mean_s=round(float(np.mean([m["t_wall"] for m in ms])), 2) if ms else None)
        print(f"  {kind:5s} {n:5d} сл. × {t_case:5.1f} с (решатель {t_ref:.1f} с по {len(rs)} сл. air-lite «{src}», "
              f"max {f_max:.0%}; накладные ×{rk:.2f}) = {h:5.2f} ч; {mb:.2f} МБ/сл. → {gb:.2f} ГБ")
    out.update(estimate=est, total_hours=round(tot_h, 2), total_gb=round(tot_gb, 2), overhead_all=round(r_all, 3))
    print(f"  ИТОГО: {sum(n_kind.values())} случаев ≈ {tot_h:.1f} ч GPU (без ожидания замка), ≈ {tot_gb:.1f} ГБ")
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")


if __name__ == "__main__":
    main()
