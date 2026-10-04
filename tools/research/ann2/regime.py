"""AN-4 (A1 v2): режим случая — механический / конвективный; N и Fr случая. Таблица случаев (кеш вне git):
`$AIR_NN_DATA/ann2/case_table.npz` (ids, N_bl, z_i_agl, Hs, wstar, U, wsu, zil, status_h, status_m, U10, hour) —
строится из исходных случаев набора P1 (d400_H) и film_bg.npz P3E6 (z_i, N_bl восстановлены из Day.gamma случая).

  regime.py --build        # собрать таблицу (CPU, ~1 мин)
  regime.py --table        # доля несошедшихся против w*/U, z_i/L → out/an4/regime_table.md

regime(case_id | meta) → "mech" | "conv". Определение:
  Hs — среднее по области max(d400_H, 0), Вт/м² (поток явного тепла, расчёт решателя с нагревом);
  w* = (g/θ0 · Hs/(ρ·cp) · z_i)^(1/3) (Дирдорф), θ0 = 300 К, ρ·cp = 1206 Дж/(м³·К), z_i — верх слоя перемешивания
  (Day.z_i, над средним рельефом области); U = U10·mp — скорость притока выше слоя трения (профиль решателя
  насыщается на z_sat ≈ 100 м), на высоте z_i/2 это то же значение; режим = конвективный, если w*/U > WSU_THR.
"""
from __future__ import annotations

import argparse
import json
import math
import multiprocessing as mp
import os
import sys
from pathlib import Path

import numpy as np

AIR = Path(os.environ.get("AIR_NN_DATA", "/home/greg/air_nn_data"))
TABLE = AIR / "ann2" / "case_table.npz"
FILM_BG = AIR / "pilot" / "runs" / "2026-10-03_p3e6" / "film_bg.npz"
G, TH0, RHO_CP, KAPPA, Z0 = 9.81, 300.0, 1.2 * 1005.0, 0.4, 0.1
WSU_THR = 0.5          # порог w*/U (README «Режим случая»; записан после разбора таблицы)
_T = None


def build(procs=12):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "air_nn_pilot"))
    from pilotnn.data import Datasets, solver_status  # noqa: F401
    import common as C
    info = json.loads((C.RUN / "run_info.json").read_text())
    specs = [(d["name"], d["root"]) for d in info["datasets"]]
    dss = Datasets(specs)
    rows = dss.case_rows()
    z = np.load(FILM_BG, allow_pickle=True)
    raw = json.loads(str(z["raw"])) if z["raw"].dtype.kind in "US" else z["raw"].item()
    if isinstance(raw, str):
        raw = json.loads(raw)
    with mp.get_context("fork").Pool(procs, _init, (specs,)) as pool:
        Hs = pool.map(_hs, [r["id"] for r in rows], chunksize=32)
    out = {k: [] for k in ("ids", "N_bl", "z_i_agl", "Hs", "U", "U10", "mp", "hour", "sh", "sm", "H_relief")}
    for r, h in zip(rows, Hs):
        rw = raw[r["id"]]
        out["ids"].append(r["id"]); out["N_bl"].append(rw["N_bl"]); out["z_i_agl"].append(rw["z_i_agl"])
        out["Hs"].append(h); out["U"].append(rw["U"]); out["U10"].append(r["U10"]); out["mp"].append(r["profile"]["max_profile"])
        out["hour"].append(r["hour"]); out["H_relief"].append(rw["H"])
        out["sh"].append(((r.get("runs") or {}).get("d400_h") or {}).get("status", "ok"))
        out["sm"].append(((r.get("runs") or {}).get("d400_m") or {}).get("status", "ok"))
    a = {k: np.array(v) for k, v in out.items()}
    a["wstar"] = wstar(a["Hs"], a["z_i_agl"])
    a["wsu"] = a["wstar"] / np.maximum(a["U"], 0.1)
    a["zil"] = zi_over_L(a["Hs"], a["z_i_agl"], a["U10"])
    TABLE.parent.mkdir(parents=True, exist_ok=True)
    np.savez(TABLE, **a)
    print("table", len(a["ids"]), "->", TABLE)


_DSS = None


def _init(specs):
    global _DSS
    from pilotnn.data import Datasets
    _DSS = Datasets(specs)


def _hs(cid):
    with np.load(_DSS.ds_of(cid).npz_path(cid)) as z:
        H = z["d400_H"].astype(np.float64)
    return float(np.maximum(H, 0).mean())


def wstar(Hs, zi):
    """Дирдорф: w* = (g/θ0 · Hs/(ρ cp) · z_i)^(1/3), м/с; Hs ≤ 0 → 0."""
    return (G / TH0 * np.maximum(Hs, 0) / RHO_CP * np.maximum(zi, 0)) ** (1 / 3)


def zi_over_L(Hs, zi, U10):
    """−z_i/L = κ w*³/u*³ (L — Монин–Обухов; u* = κ·U10/ln(10/z0) логарифмический профиль, z0 = 0,1 м решателя)."""
    us = KAPPA * np.maximum(U10, 0.5) / math.log(10.0 / Z0)
    return KAPPA * wstar(Hs, zi) ** 3 / us ** 3


def table():
    global _T
    if _T is None:
        z = np.load(TABLE)
        _T = {k: z[k] for k in z.files}
        _T["idx"] = {c: i for i, c in enumerate(_T["ids"].tolist())}
    return _T


def case_row(cid_or_meta):
    t = table()
    cid = cid_or_meta["id"] if isinstance(cid_or_meta, dict) else cid_or_meta
    return t["idx"][cid]


def regime(case, thr=None):
    """'mech' | 'conv' по w*/U случая (case — id или meta кеша P2)."""
    i = case_row(case)
    return "conv" if table()["wsu"][i] > (WSU_THR if thr is None else thr) else "mech"


def n_bl(case):
    """N случая, 1/с: средняя N=sqrt(g/θ0·dθ̄/dz) на z_i…z_i+1500 м (Day.gamma случая, P3E6)."""
    return float(table()["N_bl"][case_row(case)])


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--table", action="store_true")
    a = ap.parse_args()
    if a.build:
        build()
    if a.table:
        t = table()
        print("n", len(t["ids"]))
        for lo, hi in ((0, 0.01), (0.01, .25), (.25, .5), (.5, .75), (.75, 1), (1, 1.25), (1.25, 1.5), (1.5, 2), (2, 3), (3, 5), (5, 99)):
            m = (t["wsu"] >= lo) & (t["wsu"] < hi)
            print(f"wsu [{lo},{hi}): n={m.sum()} nc_h={np.mean(t['sh'][m] != 'ok') if m.any() else float('nan'):.3f}")
