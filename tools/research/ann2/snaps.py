"""AN-1, шаг 2: пересчёт решателем малой выборки случаев набора terrain с сохранением ВСЕХ снимков (каждые 10 итераций)
ветра на 60 м (u, v) и истории невязок. Решатель не правится; условия и предел итераций — как в наборе (max_outer 1000).
Продолжение после прерывания: готовый случай (out/snaps/<id>.npz) пропускается.
Запуск (venv пилота, под замком GPU):  dp lock gpu -- python snaps.py <id> [<id> ...]   либо  python snaps.py --list out/sample.json
Допуски обнулены: идём до 1000 итераций и у сошедшихся (conv_it — итерация, где критерий набора выполнился). Только решение «с нагревом» (h): на нём считается ошибка ветра P2."""
import json
import os
import sys
import time
from pathlib import Path

import numpy as np

import common
from common import DATA, OUT, PILOT_SRC

os.environ.setdefault("AIRNN_P6_DIR", str(DATA / "tiles" / "v3"))
sys.path.insert(0, str(PILOT_SRC))
sys.path.insert(0, str(PILOT_SRC.parent / "air3d"))
SNAP = Path(os.environ.get("AN1_SNAPS", "/home/greg/air_nn_data/ann2/an1/snaps"))
SNAP.mkdir(parents=True, exist_ok=True)
TERRAIN = DATA / "datasets" / "s0-1c8c322" / "terrain"


def rows():
    import sqlite3
    con = sqlite3.connect(f"file:{TERRAIN}/state.sqlite?mode=ro", uri=True)
    return {r[0]: json.loads(r[1]) for r in con.execute("select id, meta from cases where status='done'")}


def run_case(cid, row):
    import cupy as cp
    import airlite_gen as G
    import real as R
    import ref_study as RS
    c = {k: row[k] for k in ("id", "loc", "hour", "U10", "wdir", "t_max", "sky")}
    mo = int(row["solver"]["max_outer"])
    g, hc = R.grid_domain(c["loc"], 400)
    cond = R.case(c["loc"], g, hc, c["hour"], c["U10"], c["wdir"], c["t_max"], c["sky"], True)
    D = R.make(c["loc"], g, hc, cond)
    its, uv = [], []

    def cb(S, r):
        its.append(int(r["it"]))
        sl = G.slices(S)
        uv.append(G.at60(sl[:2]).astype(np.float32))

    t0 = time.perf_counter()
    D.init_background()
    # допуски 0: решатель не останавливается по сходимости — идём до max_outer (траектория до остановки та же, что в наборе)
    st = D.solve(max_outer=mo, cb=cb, tol_mom=0.0, tol_th=0.0, tol_div=0.0)
    dt = time.perf_counter() - t0
    tol = RS.TOL
    conv_it = next((int(h['it']) for h in D.hist if h['mom_rms'] < tol['tol_mom'] and h['th_rms'] < tol['tol_th'] and h['div_rms'] < tol['tol_div']), -1)
    hist = np.array([[h["it"], h["mom_rms"], h["th_rms"], h["div_rms"]] for h in D.hist], np.float64)
    fin = G.slices(D)
    np.savez_compressed(SNAP / f"{cid}.npz", it=np.array(its), uv60=np.stack(uv), hist=hist, status=st, conv_it=conv_it, iters=D.outer,
                        final60=G.at60(fin[:2]).astype(np.float32), t_wall=dt)
    RS.free(D)
    return st, conv_it, dt


def main(ids):
    rw = rows()
    for cid in ids:
        if (SNAP / f"{cid}.npz").exists():
            print(cid, "готов, пропуск", flush=True)
            continue
        st, it, dt = run_case(cid, rw[cid])
        print(cid, st, 'it_сходимости', it, f"{dt:.1f} s (стенка решателя)", flush=True)


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "--list":
        a = json.loads(Path(a[1]).read_text())
    main(a)
