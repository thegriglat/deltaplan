#!/usr/bin/env python3
"""П3-Б (NN-P10): формы профиля по высоте (POD/EOF) целей П-2 — кодировки v4 (7 величин) и v5 (9 величин).

POD отдельно по каждой величине: q(z_a) ≈ μ(z) + Σₖ cₖ·φₖ(z), μ и φ — по обучающим случаям (split.json прогона
2026-10-03_p2b, train_ids), по всем клеткам 96² и 13 высотам (ковариация 13×13, копится по случаям без загрузки всего).
Ошибка восстановления — в м/с на 60 м: цель с K формами → обратное преобразование (prep.to_physical / base.to_physical_v5)
→ вектор ветра (u, v) против поля решателя, интерполяция 50–75 м как evaluate.level_weights; медиана и p90 по клеткам
(каждая 3-я по обоим осям) на (г) holdout_sys_ids и на подвыборке обучения. Считается для ветра без нагрева (m) и с (h).
Формы пакуются по одной величине: ошибка величины при K формах идёт в физику вместе с остальными величинами при том же K.

  .venv/bin/python p3/pod.py --enc v4|v5 [--workers 4] [--train-eval 600]
Выход: $AIR_NN_DATA/pilot/p3/NN-P10/pod_<enc>.npz (mean [Q,13], phi [Q,8,13], eig [Q,13], vfrac [Q,13]),
pod_<enc>.json (таблица K → ошибка), pod_<enc>.md (фрагмент для pod.md).
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from multiprocessing import Pool
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import prep as P  # noqa: E402

DATA = Path(os.environ.get("AIR_NN_DATA", os.path.expanduser("~/air_nn_data")))
RUN = DATA / "pilot/runs/2026-10-03_p2b"
OUT = DATA / "pilot/p3/NN-P10"
AGL = P.AGL
NA = len(AGL)
KMAX = 8
STRIDE = 3
A_KEY = 60.0
NAMES = dict(v4=("u_m", "v_m", "w_m", "u_h", "v_h", "w_h", "theta"),
             v5=("a_m", "sd_m", "cd_m", "wrel_m", "a_h", "sd_h", "cd_h", "wrel_h", "theta"))


def level_weights(agl, a_key):          # как pilotnn.evaluate.level_weights
    agl = list(agl)
    for i in range(len(agl) - 1):
        if agl[i] <= a_key <= agl[i + 1]:
            t = (a_key - agl[i]) / (agl[i + 1] - agl[i])
            return i, 1 - t, t
    raise ValueError(a_key)


LW = level_weights(AGL, A_KEY)
_info = json.load(open(RUN / "run_info.json"))
PREP = [d["prep_dir"] for d in _info["datasets"]]
DSET = [d["root"] for d in _info["datasets"]]


def find(dirs, cid):
    for d in dirs:
        p = Path(d) / "cases" / f"{cid}.npz"
        if p.exists():
            return p
    raise FileNotFoundError(cid)


def load_case(cid, enc):
    """→ (Y (Q,13,ny*nx) float64 в величинах кодировки, meta, z (поля решателя) или None, base)."""
    with np.load(find(PREP, cid)) as c:
        meta = json.loads(str(c["meta"]))
        if enc == "v4":
            y = c["Y"].astype(np.float64)
    z = None
    base = None
    if enc == "v5" or True:
        with np.load(find(DSET, cid)) as zz:
            z = {k: zz[k] for k in ("d400_hc", "d400_m", "d400_h")}
    if enc == "v5":
        from pilotnn import base as B
        hr = np.ascontiguousarray(P.rot_scalar(z["d400_hc"].astype(np.float64), meta["k"]))
        ub = P.ubg(AGL, meta["alpha"], meta["mp"], meta["U10"])
        base = B.linear_base(hr, meta["r"], ub)
        y = np.asarray(B.target_v5(z, meta, base), np.float64)
    return y.reshape(len(NAMES[enc]), NA, -1), meta, z, base


def to_phys(enc, y, meta, base, shape):
    y = y.reshape(-1, *shape)
    if enc == "v4":
        return P.to_physical(y, meta)
    from pilotnn import base as B
    return B.to_physical_v5(y, meta, base)


def _cov_job(args):
    ids, enc = args
    Q = len(NAMES[enc])
    s = np.zeros((Q, NA)); ss = np.zeros((Q, NA, NA)); n = 0
    bad = 0
    for cid in ids:
        y = load_case(cid, enc)[0]
        if not np.isfinite(y).all():
            bad += 1
            continue
        s += y.sum(-1)
        ss += np.einsum("qap,qbp->qab", y, y)
        n += y.shape[-1]
    return s, ss, n, bad


def pod_fit(ids, enc, workers):
    chunks = [(ids[i::workers * 8], enc) for i in range(workers * 8)]
    Q = len(NAMES[enc])
    s = np.zeros((Q, NA)); ss = np.zeros((Q, NA, NA)); n = 0; bad = 0
    with Pool(workers) as p:
        for a, b, m, bd in p.imap_unordered(_cov_job, chunks):
            s += a; ss += b; n += m; bad += bd
    mean = s / n
    cov = ss / n - np.einsum("qa,qb->qab", mean, mean)
    eig = np.zeros((Q, NA)); phi = np.zeros((Q, NA, NA))
    for q in range(Q):
        w, v = np.linalg.eigh(cov[q])
        o = np.argsort(w)[::-1]
        eig[q] = np.maximum(w[o], 0); phi[q] = v[:, o].T
        for k in range(NA):                      # знак: наибольший по модулю элемент положителен
            if phi[q, k][np.argmax(np.abs(phi[q, k]))] < 0:
                phi[q, k] *= -1
    return mean, phi, eig, n, bad


_G = {}


def _init(enc, mean, phi):
    _G.update(enc=enc, mean=mean, phi=phi)


def _err_job(cid):
    enc, mean, phi = _G["enc"], _G["mean"], _G["phi"]
    y, meta, z, base = load_case(cid, enc)
    if not np.isfinite(y).all():
        return None
    shape = z["d400_hc"].shape
    sl = (slice(None), slice(None, None, STRIDE), slice(None, None, STRIDE))
    i, w0, w1 = LW
    tru = dict(m=np.asarray(z["d400_m"], np.float64), h=np.asarray(z["d400_h"], np.float64))
    res = []
    yc = y - mean[:, :, None]
    for K in list(range(1, KMAX + 1)) + [NA]:
        ph = phi[:, :K, :]
        rec = mean[:, :, None] + np.einsum("qka,qkp->qap", ph, np.einsum("qka,qap->qkp", ph, yc))
        phy = to_phys(enc, rec, meta, base, shape)
        row = []
        for key in ("m", "h"):
            d = w0 * (phy[key][:, i] - tru[key][:, i]) + w1 * (phy[key][:, i + 1] - tru[key][:, i + 1])
            row.append(np.hypot(d[0], d[1])[sl[1:]].ravel())          # ошибка вектора ветра
            row.append(np.abs(d[2])[sl[1:]].ravel())                  # ошибка w
        res.append(np.stack(row).astype(np.float32))                 # (4, ncell): wind_m, w_m, wind_h, w_h
    return np.stack(res)                                              # (K+1, 4, ncell)


def evaluate(ids, enc, mean, phi, workers):
    out = []
    with Pool(workers, initializer=_init, initargs=(enc, mean, phi)) as p:
        for r in p.imap(_err_job, ids, chunksize=4):
            if r is not None:
                out.append(r)
    A = np.concatenate(out, axis=-1)                                  # (K+1, 4, cells)
    q = lambda a: [float(np.median(a)), float(np.percentile(a, 90))]
    tab = []
    for ki in range(A.shape[0]):
        tab.append(dict(K=(ki + 1 if ki < KMAX else NA), wind_m=q(A[ki, 0]), w_m=q(A[ki, 1]),
                        wind_h=q(A[ki, 2]), w_h=q(A[ki, 3])))
    return tab, A.shape[-1], len(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--enc", choices=("v4", "v5"), required=True)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--train-eval", type=int, default=600)
    ap.add_argument("--limit", type=int, default=0, help="отладка: взять первые N случаев в каждом наборе")
    a = ap.parse_args()
    split = json.load(open(RUN / "split.json"))
    train, gsys = list(split["train_ids"]), list(split["holdout_sys_ids"])
    rng = np.random.default_rng(20261003)
    tr_eval = [train[i] for i in sorted(rng.choice(len(train), min(a.train_eval, len(train)), replace=False))]
    if a.limit:
        train, gsys, tr_eval = train[:a.limit], gsys[:a.limit], tr_eval[:a.limit]
    OUT.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    mean, phi, eig, n, bad = pod_fit(train, a.enc, a.workers)
    print(f"[{a.enc}] POD по {len(train)} случаям, {n} клеток-профилей, не конечных случаев {bad}; {time.time()-t0:.0f} с", flush=True)
    vfrac = np.cumsum(eig, -1) / np.maximum(eig.sum(-1, keepdims=True), 1e-30)
    res = dict(enc=a.enc, names=NAMES[a.enc], n_train=len(train), n_cells=int(n), bad=int(bad), eig=eig.tolist(),
               vfrac=vfrac.tolist(), mean=mean.tolist(), stride=STRIDE, a_key=A_KEY)
    for name, ids in (("g", gsys), ("train", tr_eval)):
        tab, nc, nk = evaluate(ids, a.enc, mean, phi, a.workers)
        res[name] = dict(table=tab, n_cells=nc, n_cases=nk)
        print(f"[{a.enc}] {name}: {nk} случаев, {nc} клеток; {time.time()-t0:.0f} с", flush=True)
    sfx = f"_lim{a.limit}" if a.limit else ""
    np.savez(OUT / f"pod_{a.enc}{sfx}.npz", mean=mean.astype(np.float32), phi=phi[:, :KMAX, :].astype(np.float32),
             eig=eig.astype(np.float32), vfrac=vfrac.astype(np.float32))
    json.dump(res, open(OUT / f"pod_{a.enc}{sfx}.json", "w"), indent=1)
    lines = [f"| K | (г) wind m p50 / p90 | (г) wind h p50 / p90 | (г) w_h p90 | обуч. wind h p50 / p90 |", "|---|---|---|---|---|"]
    for tg, tt in zip(res["g"]["table"], res["train"]["table"]):
        lines.append(f"| {tg['K']} | {tg['wind_m'][0]:.3f} / {tg['wind_m'][1]:.3f} | {tg['wind_h'][0]:.3f} / {tg['wind_h'][1]:.3f}"
                     f" | {tg['w_h'][1]:.3f} | {tt['wind_h'][0]:.3f} / {tt['wind_h'][1]:.3f} |")
    lines += ["", "Доля дисперсии, накопленная (по величинам, K = 1…8):", "",
              "| величина | " + " | ".join(str(k) for k in range(1, KMAX + 1)) + " |", "|---|" + "---|" * KMAX]
    for q, nm in enumerate(NAMES[a.enc]):
        lines.append(f"| {nm} | " + " | ".join(f"{vfrac[q, k]*100:.2f}" for k in range(KMAX)) + " |")
    (OUT / f"pod_{a.enc}{sfx}.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
