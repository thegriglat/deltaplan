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

Полный прогон П-2 (NN-P7): .venv/bin/python estimate.py --full-p2   → figures/estimate_p2_full.json
  ч GPU набора terrain (замер пробы на tiles/v3: время случая ok и max раздельно × доля max индекса, интервал Уилсона по
  доле max), ч подготовки (CPU), ч обучения (tests/out/bench_epoch.json NN-P5 × образцы × эпохи — верхняя граница, ранняя
  остановка короче), ГБ диска (набор, кеш подготовки, прогоны), всего, готовая команда.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import shutil
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
    if not a.n_places and plan["p6"]["fake"]:
        a.n_places = int(cfg["terrain"].get("expected_places") or 0)   # подставной индекс — пересчёт на ожидаемое число мест
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


def wilson(k, n, z=1.96):
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * ((p * (1 - p) / n + z * z / (4 * n * n)) ** 0.5) / d
    return max(0.0, c - h), min(1.0, c + h)


def full_p2(a):
    """Оценка полного прогона П-2 по пробе на настоящих местах (набор probe на tiles/v3) и замеру эпохи NN-P5."""
    import csv
    import yaml
    sys_path = str(HERE)
    import sys
    sys.path.insert(0, sys_path)
    from pilotnn import report as RP
    cfg = DS.load_cfg(HERE / "configs/dataset.yaml")
    pcfg = yaml.safe_load((HERE / "config.yaml").read_text())
    root = Path(a.data_root or os.environ.get("AIR_NN_DATA") or cfg["data_root"])
    L = DS.Layout(cfg, root, "probe")
    plan = json.loads(L.plan.read_text())
    con = sqlite3.connect(f"file:{L.db}?mode=ro", uri=True)
    rows = con.execute("SELECT id, loc, t_wall, solve_status, bytes FROM cases WHERE status='done'").fetchall()
    b = con.execute("SELECT SUM(n_cases), SUM(t_end - t_start) FROM batches WHERE n_cases > 0").fetchone()
    con.close()
    d = DS.p6_dir(cfg, root)
    with open(d / "index.csv", newline="") as f:
        idx = list(csv.DictReader(f))
    n_places, n_cond = len(idx), int(cfg["terrain"]["n_cond"])
    n_cases = n_places * n_cond
    k_par = b[1] / sum(r[2] for r in rows)                  # доля времени GPU на секунду t_wall случая при N воркерах
    ok = [r[2] * k_par for r in rows if r[3] == "ok"]
    mx = [r[2] * k_par for r in rows if r[3] != "ok"]
    f = len(mx) / len(rows)
    flo, fhi = wilson(len(mx), len(rows))
    t_ok, t_mx = float(np.mean(ok)), float(np.mean(mx))
    gpu = lambda ff: n_cases * ((1 - ff) * t_ok + ff * t_mx) / 3600   # noqa: E731
    gpu_h = gpu(f)
    # доля времени max — часть GPU-часов
    max_share = n_cases * f * t_mx / 3600 / gpu_h
    mb_case = float(np.mean([r[4] for r in rows])) / 1e6
    # подготовка (CPU): по замеру smoke П-2 (tests/out/smoke_p2_prep.json), иначе 0,1 с/случай (пул процессов)
    prep_s = 0.1
    pj = HERE / "tests/out/smoke_p2_prep.json"
    if pj.exists():
        prep_s = max(0.1, json.loads(pj.read_text())["s_per_case"])   # не меньше 0,1 с (холодный диск, запас)
    n_old = int(pcfg["estimate"]["n_old_pool"] + pcfg["estimate"]["n_old_hold"])
    prep_h = (n_cases + n_old) * prep_s / 3600
    prep_mb_case = float(os.environ.get("PREP_MB_CASE") or 1.95)   # кеш подготовки: 39 МБ на 20 случаев probe
    # обучение: report.estimate (замер эпохи NN-P5 × образцы × эпохи; верхняя граница — без ранней остановки)
    sm = sorted((root / "pilot/smoke_p2/reports").glob("*/metrics.json"), key=lambda p: p.stat().st_mtime)
    M = dict(config_estimate=pcfg["estimate"], main={}, t_eval_s=2.85, n_eval_cases=30)
    if sm:
        sj = json.loads(sm[-1].read_text())
        M.update(t_eval_s=sj["t_eval_s"], n_eval_cases=sj["n_eval_cases"])
    E = RP.estimate(M)
    train_h = E["h_main"] + E["h_curve"]
    runs_gb = 0.5
    disk = dict(dataset_terrain=round(n_cases * mb_case / 1e3, 1), prep_terrain=round(n_cases * prep_mb_case / 1e3, 1),
                prep_main=round(n_old * prep_mb_case / 1e3, 1), runs_reports=runs_gb)
    total_gb = sum(disk.values())
    total_h = gpu_h + prep_h + train_h + E["h_eval"]
    cmd = ("tmux new -s p2 'cd /home/greg/deltaplan-air-nn/tools/research/air_nn_pilot && ./run_pilot.sh; exec bash'   "
           "# копия после слияния ветки air-nn/assemble; повтор той же команды продолжает")
    probe_places = [dict(loc=l, slope_p50=round(float(plan["place_info"][l]["slope_p50"]), 3),
                         relief_m=round(float(plan["place_info"][l]["relief_m"])), system=plan["place_info"][l]["system"],
                         part=plan["place_info"][l]["part"],
                         gpu_s_case=round(float(np.mean([r[2] * k_par for r in rows if r[1] == l])), 1),
                         n=sum(r[1] == l for r in rows), n_max=sum(r[1] == l and r[3] != "ok" for r in rows))
                    for l in plan["places"]]
    out = dict(probe_real_places=not plan["p6"]["fake"], probe_dataset=str(L.dir), probe_places=probe_places,
               probe_n_places=len(plan["places"]), probe_n_cases=len(rows), solver_version=L.version,
               tiles=str(d), n_places=n_places, n_cond=n_cond, n_cases_terrain=n_cases,
               gpu_s_case_ok=round(t_ok, 2), gpu_s_case_max=round(t_mx, 2), max_frac=round(f, 3),
               max_frac_ci95=[round(flo, 3), round(fhi, 3)], max_time_share=round(max_share, 2),
               gpu_h_terrain=round(gpu_h, 1), gpu_h_terrain_range=[round(gpu(flo), 1), round(gpu(fhi), 1)],
               workers=cfg["run"]["workers"], cpu_h_prep=round(prep_h, 2), prep_s_per_case=prep_s,
               train_h_main=round(E["h_main"], 2), train_h_curve=round(E["h_curve"], 2), train_h=round(train_h, 2),
               eval_h=round(E["h_eval"], 2), t_per_sample_ms=E["t_per_sample_ms"], bench=E["src"],
               total_h=round(total_h, 1), total_h_range=[round(total_h - gpu_h + gpu(flo), 1), round(total_h - gpu_h + gpu(fhi), 1)],
               disk_gb=round(total_gb, 1), disk_parts_gb=disk, mb_per_case=round(mb_case, 3),
               free_gb_now=round(shutil.disk_usage(root).free / 1e9, 1), command=cmd,
               notes=["обучение — верхняя граница: max_epochs 150 без ранней остановки (patience 30)",
                      "ГПУ — время случая с учётом 2 воркеров (длительность пачек / случаи), замок GPU пилота",
                      "кеш подготовки main пересчитывается (код prep изменился с P-1); старый кеш prep/*/main_2922f6_* можно удалить"])
    o = Path(a.out if a.out != str(HERE / "figures/estimate.json") else HERE / "figures/estimate_p2_full.json")
    o.parent.mkdir(parents=True, exist_ok=True)
    o.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
    print(f"П-2 полный: {n_places} мест × {n_cond} = {n_cases} случаев; GPU {gpu_h:.1f} ч (CI max {flo:.0%}–{fhi:.0%}: "
          f"{gpu(flo):.1f}–{gpu(fhi):.1f}); подготовка {prep_h:.2f} ч CPU; обучение ≤ {train_h:.1f} ч; оценка {E['h_eval']:.2f} ч; "
          f"всего ≤ {total_h:.1f} ч; диск {total_gb:.1f} ГБ → {o}")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", default="main")
    ap.add_argument("--data-root", default=None)
    ap.add_argument("--n-places", type=int, default=0, help="probe: пересчитать оценку на это число мест")
    ap.add_argument("--out", default=str(HERE / "figures/estimate.json"))
    ap.add_argument("--full-p2", action="store_true", help="оценка полного прогона П-2 → figures/estimate_p2_full.json")
    a = ap.parse_args()
    if a.full_p2:
        return full_p2(a)
    cfg = DS.load_cfg(HERE / "configs/dataset.yaml")
    if (cfg["datasets"].get(a.dataset) or {}).get("terrain"):
        root = Path(a.data_root or os.environ.get("AIR_NN_DATA") or cfg["data_root"])
        L = DS.Layout(cfg, root, a.dataset)
        if not L.db.exists() and not a.data_root:
            # проба NN-P6 считалась во временном корне (набор в datasets/ не пишется до согласования счёта)
            alt = root / "pilot/tmp" / f"nnp6_{a.dataset}"
            if DS.Layout(cfg, alt, a.dataset).db.exists():
                print(f"(набор {a.dataset} не найден в {root}; беру пробу NN-P6 из {alt})")
                L = DS.Layout(cfg, alt, a.dataset)
        if "AIRNN_P6_DIR" not in os.environ and L.manifest.exists():
            d = (json.loads(L.manifest.read_text()).get("terrain") or {}).get("p6_dir")
            if d:
                os.environ["AIRNN_P6_DIR"] = d
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
