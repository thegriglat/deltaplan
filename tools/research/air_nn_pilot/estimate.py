#!/usr/bin/env python3
"""Оценка полного досчёта набора main: время GPU и диск — по замерам этого кода (готовые случаи набора) и по 49
случаям air-lite (`research/air-lite:tools/research/air_lite/out/runs.jsonl`, тот же решатель и условия).

Время случая = время решателя (сумма t_init + t_solve решений из runs) × накладные (запись, срезы, загрузка места) —
отношение t_wall / время решателя на замерах этого кода. Для встроенных и синтетики среднее время решателя — по
air-lite (49 случаев, в т. ч. 8 «max»), для процедурных — по синтетике air-lite (тот же формат: 1 окно) и, для
сверки, по своим замерам. Повтор случаев air-lite этим кодом: итерации должны совпасть.

  .venv/bin/python estimate.py [--dataset main] [--out figures/estimate.json]

Набор probe / terrain (П1 v2, NN-P6) — оценка полного счёта terrain (все места индекса П6 × terrain.n_cond) по замеру
пробы: время GPU на случай = длительность пачек / число случаев (воркеры уже учтены), с поправкой на крутизну —
каждое место индекса получает среднее время ближайшего по рангу slope_p50 места пробы; диск — средний размер файла.
  .venv/bin/python estimate.py --dataset probe [--n-places 345]   → figures/estimate_probe.json
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


def estimate_terrain(cfg, L, a):
    import csv
    plan = json.loads(L.plan.read_text())
    con = sqlite3.connect(f"file:{L.db}?mode=ro", uri=True)
    rows = con.execute("SELECT id, loc, t_wall, solve_status, bytes, runs FROM cases WHERE status='done'").fetchall()
    n_plan = con.execute("SELECT COUNT(*) FROM cases").fetchone()[0]
    b = con.execute("SELECT SUM(n_cases), SUM(t_end - t_start) FROM batches WHERE n_cases > 0").fetchone()
    con.close()
    if not rows or not b[0]:
        print(f"набор {L.name}: нет посчитанных случаев — сначала dataset.py run --dataset {L.name}")
        return 1
    pinfo = plan["place_info"]
    t_gpu_case = b[1] / b[0]                          # с при N воркерах (длительность пачек / случаи)
    sum_wall = sum(r[2] for r in rows)
    k_par = b[1] / sum_wall                           # перевод t_wall случая (при N воркерах) в долю времени GPU
    by_loc = {}
    for cid, loc, tw, ss, nb, runs in rows:
        by_loc.setdefault(loc, []).append((tw, ss, nb, json.loads(runs)))
    places = []
    for loc, v in sorted(by_loc.items(), key=lambda kv: pinfo[kv[0]]["slope_p50"]):
        places.append(dict(loc=loc, slope_p50=round(pinfo[loc]["slope_p50"], 4), relief_m=round(pinfo[loc]["relief_m"]),
                           system=pinfo[loc]["system"], n=len(v), t_wall_mean_s=round(float(np.mean([x[0] for x in v])), 2),
                           gpu_s_per_case=round(float(np.mean([x[0] for x in v])) * k_par, 2),
                           max_frac=round(float(np.mean([x[1] == "max" for x in v])), 3),
                           iters=[int(sum(r["iters"] for r in x[3].values())) for x in v]))
    # индекс П6 полного набора
    d = Path(os.environ.get("AIRNN_P6_DIR") or DS.p6_dir(cfg, L.data_root))
    with open(d / "index.csv", newline="") as f:
        idx = list(csv.DictReader(f))
    n_cond = int(cfg["terrain"]["n_cond"])
    slopes = np.array([p["slope_p50"] for p in places])
    t_full = 0.0
    for r in idx:
        j = int(np.argmin(np.abs(slopes - float(r["slope_p50"]))))
        t_full += n_cond * places[j]["gpu_s_per_case"]
    n_full = len(idx) * n_cond
    mb = float(np.mean([r[4] for r in rows])) / 1e6
    out = dict(dataset=L.name, p6_fake=plan["p6"]["fake"], p6_dir=str(d), n_probe_cases=len(rows), n_probe_plan=n_plan,
               workers_rate_per_h=round(b[0] / b[1] * 3600, 1), gpu_s_per_case=round(t_gpu_case, 2),
               max_frac=round(float(np.mean([r[3] == "max" for r in rows])), 3), max_outer=plan["solver"]["max_outer"],
               places=places, mb_per_case=round(mb, 3),
               full=dict(n_places=len(idx), n_cond=n_cond, n_cases=n_full, gpu_h=round(t_full / 3600, 2),
                         gpu_h_flat=round(n_full * t_gpu_case / 3600, 2), gb=round(n_full * mb / 1e3, 2)))
    print(f"проба {L.name}: {len(rows)} случаев ({'ПОДСТАВНЫЕ места П6' if plan['p6']['fake'] else 'настоящие места П6'}), "
          f"{out['workers_rate_per_h']:.0f} случаев/ч (время GPU {t_gpu_case:.1f} с/случай), max {out['max_frac']:.0%}, "
          f"предел {out['max_outer']} ит.")
    print("  по крутизне (slope_p50 ↑): место, уклон, размах, случаев, t_wall, с GPU/случай, доля max")
    for p in places:
        print(f"    {p['loc']} {p['slope_p50']:.3f} {p['relief_m']:5d} м {p['n']} {p['t_wall_mean_s']:6.1f} с "
              f"{p['gpu_s_per_case']:6.1f} с {p['max_frac']:.0%}")
    print(f"  полный terrain: {len(idx)} мест × {n_cond} = {n_full} случаев ≈ {out['full']['gpu_h']:.1f} ч GPU "
          f"(без поправки на крутизну {out['full']['gpu_h_flat']:.1f} ч GPU), ≈ {out['full']['gb']:.1f} ГБ")
    if a.n_places:
        f = a.n_places / len(idx)
        out["scaled"] = dict(n_places=a.n_places, n_cases=a.n_places * n_cond, gpu_h=round(out["full"]["gpu_h"] * f, 1),
                             gb=round(out["full"]["gb"] * f, 1),
                             note="пересчёт на заданное число мест при том же распределении крутизны, что у индекса пробы")
        print(f"  на {a.n_places} мест: ≈ {out['scaled']['gpu_h']:.1f} ч GPU, ≈ {out['scaled']['gb']:.1f} ГБ")
    o = Path(a.out if a.out != str(HERE / "figures/estimate.json") else HERE / f"figures/estimate_{L.name}.json")
    o.parent.mkdir(parents=True, exist_ok=True)
    o.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", default="main")
    ap.add_argument("--data-root", default=None)
    ap.add_argument("--n-places", type=int, default=0, help="probe: пересчитать оценку на это число мест")
    ap.add_argument("--out", default=str(HERE / "figures/estimate.json"))
    a = ap.parse_args()
    cfg = DS.load_cfg(HERE / "configs/dataset.yaml")
    if (cfg["datasets"].get(a.dataset) or {}).get("terrain"):
        L = DS.Layout(cfg, a.data_root or os.environ.get("AIR_NN_DATA") or cfg["data_root"], a.dataset)
        return estimate_terrain(cfg, L, a)
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
    raise SystemExit(main())
