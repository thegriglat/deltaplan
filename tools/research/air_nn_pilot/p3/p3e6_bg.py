#!/usr/bin/env python3
"""P3E6, шаг 1: фоновый профиль θ̄(z) решателя по условиям случая → числа FiLM фона для всех случаев кеша П-2.

  /home/greg/deltaplan/tools/dp lock cpu p3e6bg -- env CUDA_VISIBLE_DEVICES= .venv/bin/python p3/p3e6_bg.py \
      --p2 $AIR_NN_DATA/pilot/runs/2026-10-03_p2b --out $AIR_NN_DATA/pilot/runs/2026-10-03_p3e6 [--procs 10]

→ <out>/film_bg.npz: ids (n,), F (n, 9) f32 (порядок film_bg.FILM_BG_NAMES), raw (json по случаю);
  <out>/film_bg_check.json: сверка восстановленного Day с `day` метаданных (все случаи) и глубокая сверка на 4 случаях
  тем же путём, что генератор (real.grid_domain + real.case: рельеф, Case.gam на уровнях сетки, z_i, поток тепла H
  против d400_hc / d400_H образца); сводка распределений (по классу устойчивости).
Профиль восстанавливается тем же кодом weather (см. pilotnn/film_bg.py); данные решателя не пересчитываются.
"""
from __future__ import annotations

import argparse
import json
import multiprocessing as mp
import os
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "air3d"))
from pilotnn import film_bg as FB  # noqa: E402
from pilotnn.data import Datasets  # noqa: E402

_DSS = None


def _init(specs):
    global _DSS
    _DSS = Datasets(specs)


def one(row):
    D = FB.day_of(row)
    bad = FB.check_day(D, row)
    with np.load(_DSS.ds_of(row["id"]).npz_path(row["id"])) as z:
        hc = z["d400_hc"].astype(np.float64)
    pr = row["profile"]
    raw = FB.bg_raw(D, hc, row["U10"], pr["max_profile"])
    raw.update(stab=pr.get("stab"), hour=row["hour"], cap=(row.get("day") or {}).get("cap_agl"))
    return row["id"], FB.bg_film(raw), raw, bad


def deep_check(dss, row):
    """Генераторный путь: real.grid_domain + real.case (CPU) против образца и восстановленного Day."""
    import real as R
    D = FB.day_of(row)
    g, hc = R.grid_domain(row["loc"], 400)
    c = R.case(row["loc"], g, hc, row["hour"], row["U10"], row["wdir"], row["t_max"], row["sky"], True)
    with np.load(dss.ds_of(row["id"]).npz_path(row["id"])) as z:
        hc0, H0 = z["d400_hc"].astype(np.float64), z["d400_H"].astype(np.float64)
    import air as A
    H = np.asarray(c.H, float)            # гашение у края области — как Air.__init__ (prm.heat_taper_m)
    tp = A.Params().heat_taper_m
    xe = (np.arange(g.nx) + 0.5) * g.dx
    ye = (np.arange(g.ny) + 0.5) * g.dx
    ex = np.clip(np.minimum(xe, g.nx * g.dx - xe) / tp, 0, 1)
    ey = np.clip(np.minimum(ye, g.ny * g.dx - ye) / tp, 0, 1)
    H = H * (np.sin(0.5 * np.pi * ey)[:, None] * np.sin(0.5 * np.pi * ex)[None, :]) ** 2
    zc = g.z_bot + (np.arange(g.nz) + 0.5) * g.dz
    gs, gd = np.asarray(c.gam(zc), float), np.asarray(D.gamma(zc), float)
    return dict(id=row["id"], hc_maxdiff_m=float(np.abs(hc - hc0).max()),
                H_maxdiff_wm2=float(np.abs(H - H0).max()), H_max_wm2=float(np.abs(H0).max()),
                gam_solver_vs_rebuilt_maxdiff_kkm=float(np.abs(gs - gd).max() * 1000),
                z_i_solver=float(c.z_i), z_i_rebuilt=float(D.z_i), z_i_meta=(row.get("day") or {}).get("z_i_msl"),
                gam_levels_kkm=[round(x * 1000, 3) for x in gs[:: max(1, g.nz // 8)]])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--p2", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--procs", type=int, default=10)
    a = ap.parse_args()
    p2, out = Path(a.p2), Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    info = json.loads((p2 / "run_info.json").read_text())
    specs = [(d["name"], d["root"]) for d in info["datasets"]]
    dss = Datasets(specs)
    import procedural as PR
    for name, root in specs:          # зерно процедурных рельефов — из плана набора с местами p_* (как dataset.run_setup)
        plan = json.loads((Path(root) / "plan.json").read_text())
        if any(str(x).startswith("p_") for x in plan.get("places", [])):
            PR.configure(plan["proc"]["seed"])
        if plan.get("p6"):
            import hashlib
            ish = hashlib.sha256((Path(os.environ["AIRNN_P6_DIR"]) / "index.csv").read_bytes()).hexdigest()
            assert ish == plan["p6"]["index_sha256"], f"индекс П6 {ish} ≠ плана {name}"
    want = []
    for d in info["datasets"]:
        want += json.loads((p2 / f"prep_ids_{d['name']}.json").read_text())
    rows = {r["id"]: r for r in dss.case_rows()}
    todo = [rows[i] for i in want]
    print(f"фон: {len(todo)} случаев, {a.procs} процессов", flush=True)
    with mp.get_context("fork").Pool(a.procs, _init, (specs,)) as pool:
        res = pool.map(one, todo, chunksize=16)
    ids = np.array([r[0] for r in res])
    F = np.stack([r[1] for r in res]).astype(np.float32)
    raws = [r[2] for r in res]
    bads = {r[0]: r[3] for r in res if r[3]}
    np.savez(out / "film_bg.npz", ids=ids, F=F, names=np.array(FB.FILM_BG_NAMES),
             raw=np.array(json.dumps(dict(zip(ids.tolist(), raws)))))
    # глубокая сверка: 2 места main (встроенное, процедурное), 2 вырезки П6 (утро с крышкой и день)
    pick = []
    for pref, hour in (("ongudai", 9.0), ("p_", 15.0), ("t_", 9.0), ("t_", 15.0)):
        for i in want:
            r = rows[i]
            if r["loc"].startswith(pref) and r["hour"] == hour:
                pick.append(r)
                break
    deep = [deep_check(dss, r) for r in pick]
    # распределения
    stab = np.array([r["stab"] for r in raws])
    N = np.array([r["N_bl"] for r in raws])
    Fr = np.array([r["Fr"] for r in raws])
    G = np.array([r["gam_kkm"] for r in raws])
    hour = np.array([r["hour"] for r in raws])
    by = {}
    for s in sorted(set(stab)):
        m = stab == s
        by[s] = dict(n=int(m.sum()), N_bl_p10_p50_p90=np.percentile(N[m], [10, 50, 90]).round(5).tolist(),
                     N_bl_std=float(N[m].std()), Fr_p10_p50_p90=np.percentile(Fr[m], [10, 50, 90]).round(3).tolist(),
                     frac_N_not_FA=float((np.abs(N[m] - N.max()) > 1e-4).mean()) if m.any() else None,
                     gam_kkm_mean_by_level=G[m].mean(0).round(2).tolist(), gam_kkm_std_by_level=G[m].std(0).round(2).tolist())
    byh = {str(h): dict(n=int((hour == h).sum()), N_bl_p10_p50_p90=np.percentile(N[hour == h], [10, 50, 90]).round(5).tolist())
           for h in sorted(set(hour))}
    chk = dict(n=len(ids), n_day_mismatch=len(bads), day_mismatch_examples=dict(list(bads.items())[:10]), deep=deep,
               levels_m=FB.BG_LEVELS, names=FB.FILM_BG_NAMES, by_stab=by, by_hour=byh,
               N_bl_overall_p0_p50_p100=np.percentile(N, [0, 50, 100]).round(5).tolist(),
               N_FA=float(np.sqrt(FB.G_OVER_TH0 * 5.8e-3)),
               Fr_overall_p10_p50_p90=np.percentile(Fr, [10, 50, 90]).round(3).tolist(),
               frac_Fr_clipped=float((Fr >= FB.FR_MAX).mean()))
    (out / "film_bg_check.json").write_text(json.dumps(chk, ensure_ascii=False, indent=1))
    print(json.dumps({k: chk[k] for k in ("n", "n_day_mismatch", "deep")}, ensure_ascii=False, indent=1))
    return 0 if not bads else 2


if __name__ == "__main__":
    os.environ.setdefault("AIRNN_P6_DIR", str(Path(os.environ.get("AIR_NN_DATA", "/home/greg/air_nn_data")) / "pilot/tiles/v3"))
    sys.exit(main())
