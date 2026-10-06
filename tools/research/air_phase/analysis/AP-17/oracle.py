"""AP-17, диагностика (не результат сборки): «оракул профиля» — сборка, у которой средний по области профиль u, v, θ′
по каждой высоте заменён профилем Пикара (поправка одной кривой на случай). Отвечает на вопрос: что ошибочно —
средний профиль (одномерная задача) или пространственная структура механизмов фаз.

    oracle.py [--data $AIR_SYNTH_DATA/phase/assembly_v1] [--workers 16]
Выход — <data>/oracle_profile.jsonl (по строке на случай: метрики слоёв поправленной сборки, e60).
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from pathlib import Path

for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "1")

import h5py  # noqa: E402
import numpy as np  # noqa: E402

HERE = Path(__file__).resolve().parent
AP = HERE.parents[1]
sys.path.insert(0, str(AP))
import layer_metrics as LM  # noqa: E402
from assembly import run_assembly as RA  # noqa: E402

E = 5


def fix(A, P):
    """Средний по внутренней области профиль каждого канала (кроме w) — как у Пикара."""
    B = A.astype(np.float32).copy()
    I = slice(E, -E)
    for ch in [c for c in range(A.shape[0]) if c != 2]:
        d = P[ch][:, I, I].mean((1, 2)) - B[ch][:, I, I].mean((1, 2))
        B[ch] += d[:, None, None]
    return B


def work(args):
    part, index, ctab = args
    out = []
    with h5py.File(part, "r") as h:
        cs = h["cases"][:]
        for q in range(len(cs)):
            if cs["status_m"][q] != 0 or cs["status_h"][q] != 0:
                continue
            key = int(cs["case"][q])
            p, r = index[key]
            with h5py.File(p, "r") as s:
                fm = s["fields/m"][r].astype(np.float32)
                fh = s["fields/h"][r].astype(np.float32)
                hc = s["inputs/hc"][r].astype(np.float64)
                heat = s["inputs/heat_flux"][r].astype(np.float64)
                hbl = s["inputs/hbl"][r].astype(np.float64)
            ah = fix(h["fields/f"][q], fh)
            am = fix(h["fields/m"][q], fm)
            cd = ctab[(int(cs["relief_id"][q]), int(cs["cond_id"][q]))]
            c = RA.lm_case(cd, hc)
            ma = LM.layer_metrics(ah, hc, heat, hbl, c, w_mech=am[2])
            W = h["weights"][q].astype(np.float32) / 255.0
            err = RA.errors(fh, ah, W)
            out.append(json.dumps(dict(case=key, lm_asm=RA._clean({k: float(v) for k, v in ma.items()}),
                                       e60_med=err["e60_med"]), ensure_ascii=False))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=str(RA.DATA / "phase/assembly_v1"))
    ap.add_argument("--workers", type=int, default=16)
    a = ap.parse_args()
    index = {x[2]["case"]: (x[0], x[1]) for x in RA.load_index()}
    ctab = RA.cond_table()
    parts = sorted(glob.glob(str(Path(a.data) / "part-*.h5")))
    from multiprocessing import Pool
    lines = []
    with Pool(a.workers) as pool:
        for o in pool.imap_unordered(work, [(p, index, ctab) for p in parts]):
            lines += o
    Path(a.data, "oracle_profile.jsonl").write_text("\n".join(sorted(lines)) + "\n", encoding="utf-8")
    print("oracle", len(lines))


if __name__ == "__main__":
    main()
