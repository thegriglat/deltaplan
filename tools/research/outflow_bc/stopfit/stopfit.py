#!/usr/bin/env python3
"""OBC-5: критерий остановки (г) по истории невязок корпуса OBC-3 (OB2 res_hist).

Подгонка log r(k) ~ log(r_inf + A*rho^j) в скользящем окне последних W итераций (j - номер проверки, шаг 10 итераций),
r_inf >= 0, A >= 0, 0 < rho < 1. Стоп "conv": r_inf < порог игры; "plateau": (r(k)-r_inf)/r_inf < eps.
Выход: stop.csv (основная невязка mom_rms), stop_aux.csv (div_rms, th_rms, если не нулевая).
"""
import os
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ[_v] = "1"
import argparse, gzip, json, sys
from multiprocessing import Pool
import numpy as np
from scipy.optimize import least_squares

# Пороги игры: crit.tol_* (dp-air field/case_build.rs: tol_mom_rms 2e-5, tol_th_rms 5e-7, tol_div_rms 1e-6)
# x tol_scale 5 (picard_rs api.rs: crit.tol_* *= opts.tol_scale; dp-air air/tol_scale = 5).
# Проверено по корпусу: макс. невязка последней проверки ok-записей = 9.9995e-5 / 2.50e-6 / 1.4e-6 (< порогов).
THR = {"mom": 2e-5 * 5, "th": 5e-7 * 5, "div": 1e-6 * 5}
COL = {"mom": 1, "th": 3, "div": 5}
WS = (50, 100, 200)
EPS = (0.05, 0.1, 0.2)
STEP = 10
FLOOR = 1e-14


def fit_window(y):
    """y - невязки в окне (len>=3) -> (r_inf, rho). Модель по нормированной на min(y) невязке."""
    n = len(y)
    s = y.min()
    z = np.log(y / s)
    j = np.arange(n, dtype=float)
    a0 = max(y.max() / s - 1.0, 1e-3)

    def res(p):
        t, a, rho = p
        return np.log(t + a * rho ** j) - z

    def jac(p):
        t, a, rho = p
        m = t + a * rho ** j
        return np.stack([1.0 / m, rho ** j / m, a * j * rho ** np.maximum(j - 1.0, 0.0) / m], axis=1)

    best = None
    for p0 in ((0.9, a0, 0.8), (0.1, a0, 0.95)):
        try:
            f = least_squares(res, p0, jac=jac, bounds=([0.0, 0.0, 0.01], [1.0, 1e6, 0.999]), x_scale=[1, max(a0, 1), 1])
        except Exception:
            continue
        if best is None or f.cost < best.cost - 1e-15:
            best = f
    if best is None:
        return float("nan"), float("nan")
    t, a, rho = best.x
    return t * s, rho


def stops_for(rec, key, W):
    """Список (it, r, r_inf, rho) на каждой проверке с полным окном."""
    h = rec["res_hist"]
    col = COL[key]
    its = np.array([c[0] for c in h])
    r = np.maximum(np.array([c[col] for c in h], dtype=float), FLOOR)
    out = []
    m = W // STEP + 1
    for i in range(len(h)):
        lo = i - m + 1
        if lo < 0:
            continue
        rinf, rho = fit_window(r[lo:i + 1])
        out.append((int(its[i]), float(r[i]), rinf, rho))
    return out


def work(args):
    idx, rec = args
    rows = []
    for key in ("mom", "div", "th"):
        if key == "th" and max(c[3] for c in rec["res_hist"]) <= 0.0:
            continue
        thr = THR[key]
        for W in WS:
            fits = stops_for(rec, key, W)
            for eps in EPS:
                reason, kstop, rinf, rho, rs = "none", "", float("nan"), float("nan"), float("nan")
                for (it, r, ri, rh) in fits:
                    if not np.isfinite(ri):
                        continue
                    if ri < thr:
                        reason = "conv"
                    elif (r - ri) / ri < eps:
                        reason = "plateau"
                    if reason != "none":
                        kstop, rinf, rho, rs = it, ri, rh, r
                        break
                rows.append((idx, key, W, eps, kstop, reason, rinf, rho, rs))
    return rows


def f(x):
    return "" if x == "" or (isinstance(x, float) and not np.isfinite(x)) else f"{x:.6e}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    recs = [json.loads(l) for l in gzip.open(a.cases, "rt")]
    recs.sort(key=lambda r: (r["case_id"], r["variant"]))
    with Pool(min(16, os.cpu_count() or 1)) as p:
        res = p.map(work, list(enumerate(recs)), chunksize=4)
    hdr = "case_id,variant,u10_in,fr,heat,status,iters,W,eps,k_stop,reason,r_inf,rho,r_at_stop"
    aux = a.out.replace(".csv", "_aux.csv")
    with open(a.out, "w") as fo, open(aux, "w") as fa:
        fo.write(hdr + "\n")
        fa.write(hdr.replace("W,", "res,W,") + "\n")
        for rows in res:
            for (idx, key, W, eps, ks, reason, ri, rh, rs) in rows:
                r = recs[idx]
                base = f"{r['case_id']},{r['variant']},{r['u10_in']:g},{r['fr']:.4f},{int(r['heat'])},{r['status']},{r['iters']}"
                tail = f"{W},{eps:g},{ks},{reason},{f(ri)},{f(rh)},{f(rs)}"
                if key == "mom":
                    fo.write(f"{base},{tail}\n")
                else:
                    fa.write(f"{base},{key},{tail}\n")


if __name__ == "__main__":
    main()
