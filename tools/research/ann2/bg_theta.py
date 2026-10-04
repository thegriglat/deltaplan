#!/usr/bin/env python3
"""AN-3: фоновый профиль θ̄(η) решателя по каждому случаю кеша П2 на 13 уровнях П1 (AGL) → bg_theta.npz (ids, th (n,13), К).
Профиль не «3/6 К/км», а `weather.Day.gamma` случая (нейтральный слой перемешивания, инверсия, 5,8 К/км выше; film_bg.py П2).
  $V bg_theta.py --out $AIR_NN_DATA/ann2/bg_theta.npz [--procs 10]"""
import argparse, json, multiprocessing as mp, os, sys
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parents[1] / "air_nn_pilot"
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / "air3d"))
from pilotnn import film_bg as FB  # noqa: E402
from pilotnn import prep as P  # noqa: E402
from pilotnn.data import Datasets  # noqa: E402

_DSS = None
AGL = np.asarray(P.AGL, float)


def _init(specs):
    global _DSS
    _DSS = Datasets(specs)


def one(row):
    D = FB.day_of(row)
    bad = FB.check_day(D, row)
    with np.load(_DSS.ds_of(row["id"]).npz_path(row["id"])) as z:
        hm = float(z["d400_hc"].astype(np.float64).mean())
    zz = hm + np.arange(0.0, 2000.0 + 1e-6, 2.0)              # θ̄ = ∫ dθ̄/dz (как решатель: Case.gam = D.gamma)
    g = np.asarray(D.gamma(zz), float)
    cum = np.concatenate([[0.0], np.cumsum(0.5 * (g[1:] + g[:-1]) * 2.0)])
    th = np.interp(AGL, zz - hm, cum)
    return row["id"], th.astype(np.float32), bool(bad)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--p2", default=os.environ.get("AIR_NN_DATA", "/home/greg/air_nn_data") + "/pilot/runs/2026-10-03_p2b")
    ap.add_argument("--out", required=True)
    ap.add_argument("--procs", type=int, default=10)
    a = ap.parse_args()
    p2 = Path(a.p2)
    info = json.loads((p2 / "run_info.json").read_text())
    specs = [(d["name"], d["root"]) for d in info["datasets"]]
    dss = Datasets(specs)
    import procedural as PR
    for name, root in specs:
        plan = json.loads((Path(root) / "plan.json").read_text())
        if any(str(x).startswith("p_") for x in plan.get("places", [])):
            PR.configure(plan["proc"]["seed"])
    want = []
    for d in info["datasets"]:
        want += json.loads((p2 / f"prep_ids_{d['name']}.json").read_text())
    rows = {r["id"]: r for r in dss.case_rows()}
    todo = [rows[i] for i in want]
    with mp.get_context("fork").Pool(a.procs, _init, (specs,)) as pool:
        res = pool.map(one, todo, chunksize=16)
    ids = np.array([r[0] for r in res]); th = np.stack([r[1] for r in res])
    print("n", len(ids), "day_mismatch", sum(r[2] for r in res), "th[:, -1] min/med/max", th[:, -1].min(), np.median(th[:, -1]), th[:, -1].max())
    np.savez(a.out, ids=ids, th=th)


if __name__ == "__main__":
    main()
