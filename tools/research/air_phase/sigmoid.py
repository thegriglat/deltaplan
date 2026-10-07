"""Подгонка сигмоиды границы фазы (контракт P6 v1; модель — docs/research/air_phase.md §9 п. 6).

y = y₀ + Δy·σ((ξ − ξ_c)/w), σ(t) = 1/(1 + e^(−t)), ξ = log10 x (log=True; w — в декадах) или ξ = x (log=False;
w — в единицах x, ключ всё равно `w_dec`). Подгонка — scipy.optimize.curve_fit (МНК), доверительные интервалы —
бутстрэп по точкам (n_boot выборок с возвращением, 2,5–97,5 %).

Классы (P6): резкая — w < 0,1 декады или скачок соседних точек > 3σ шума между стартами (`noise` — СКО того же
y при повторном старте, например SWEEP против GRID; не задан — только по w); плавная — w > 0,3 декады; между —
ни то ни другое.
"""
from __future__ import annotations

import numpy as np

SHARP_W = 0.1
SMOOTH_W = 0.3
W_BOUNDS = (1e-3, 3.0)


def _model(xi, xc, w, y0, dy):
    t = np.clip((xi - xc) / w, -60.0, 60.0)
    return y0 + dy / (1.0 + np.exp(-t))


def _guess(xi, y):
    o = np.argsort(xi)
    xs, ys = xi[o], y[o]
    n = max(len(ys) // 4, 1)
    lo, hi = ys[:n].mean(), ys[-n:].mean()
    mid = 0.5 * (lo + hi)
    k = np.nonzero(np.diff(np.sign(ys - mid)))[0]
    xc = 0.5 * (xs[k[0]] + xs[k[0] + 1]) if k.size else 0.5 * (xs[0] + xs[-1])
    return [xc, 0.2 * (xs[-1] - xs[0]) / 2 + 1e-3, lo, hi - lo]


def _fit(xi, y, p0):
    from scipy.optimize import curve_fit
    span = xi.max() - xi.min()
    yr = max(float(np.ptp(y)), 1e-9)
    lo = [xi.min() - 0.5 * span, W_BOUNDS[0], y.min() - 2 * yr, -4 * yr]
    hi = [xi.max() + 0.5 * span, W_BOUNDS[1] if span > 0 else 1.0, y.max() + 2 * yr, 4 * yr]
    p0 = np.clip(p0, np.array(lo) + 1e-9, np.array(hi) - 1e-9)
    p, _ = curve_fit(_model, xi, y, p0=p0, bounds=(lo, hi), maxfev=20000)
    return p


def fit_sigmoid(x, y, *, log=True, n_boot=200, noise=None, seed=0):
    """→ dict: x_c (в единицах x), w_dec, y0, dy, x_c_ci, w_ci (пары 2,5/97,5 %), sharp, smooth (bool),
    resid_std, n, jump_max (наибольший скачок соседних по x средних), n_boot_ok. Неудача подгонки — NaN, False."""
    x = np.asarray(x, np.float64)
    y = np.asarray(y, np.float64)
    m = np.isfinite(x) & np.isfinite(y) & ((x > 0) if log else True)
    x, y = x[m], y[m]
    nan = float("nan")
    out = dict(x_c=nan, w_dec=nan, y0=nan, dy=nan, x_c_ci=(nan, nan), w_ci=(nan, nan), sharp=False, smooth=False,
               resid_std=nan, n=int(x.size), jump_max=nan, n_boot_ok=0)
    if x.size < 5 or np.unique(x).size < 4:
        return out
    xi = np.log10(x) if log else x
    try:
        p = _fit(xi, y, _guess(xi, y))
    except (RuntimeError, ValueError):
        return out
    res = y - _model(xi, *p)
    ux = np.unique(xi)
    ym = np.array([y[xi == u].mean() for u in ux])
    jump = float(np.max(np.abs(np.diff(ym)))) if ux.size > 1 else nan
    rng = np.random.default_rng(seed)
    boot = []
    for _ in range(int(n_boot)):
        k = rng.integers(0, x.size, x.size)
        if np.unique(xi[k]).size < 4:
            continue
        try:
            boot.append(_fit(xi[k], y[k], p))
        except (RuntimeError, ValueError):
            continue
    boot = np.array(boot) if boot else np.full((0, 4), nan)
    xc = 10 ** p[0] if log else p[0]
    if len(boot):
        q = np.percentile(boot[:, 0], [2.5, 97.5])
        xc_ci = tuple(float(10 ** v if log else v) for v in q)
        w_ci = tuple(float(v) for v in np.percentile(boot[:, 1], [2.5, 97.5]))
    else:
        xc_ci, w_ci = (nan, nan), (nan, nan)
    sharp = bool(p[1] < SHARP_W or (noise is not None and np.isfinite(jump) and jump > 3.0 * float(noise)))
    out.update(x_c=float(xc), w_dec=float(p[1]), y0=float(p[2]), dy=float(p[3]), x_c_ci=xc_ci, w_ci=w_ci,
               sharp=sharp, smooth=bool(p[1] > SMOOTH_W and not sharp), resid_std=float(res.std()),
               jump_max=jump, n_boot_ok=int(len(boot)))
    return out
