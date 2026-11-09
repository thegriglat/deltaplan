"""Огрубление старых нитей и потолок узлов (SWD3 v3/v4). Слияние (б) и дерево — не реализованы (v4)."""
from __future__ import annotations

import numpy as np

from .dynamics import MIN_SEGS_PER_FILAMENT, relabel

DEFAULTS = dict(l_age=None, r_amal=None, amal_cos=0.9, n_max=None)
MAX_ROUNDS = 8
PASSES = 3
ROUNDS = 6


def _collapse(f, lim):
    """Стягивание отрезков с L < lim (массив K): непересекающийся по узлам набор (раундами, самые короткие первыми),
    векторно. Как `dynamics._merge`, но два якорных узла сливаются (в них баланс потока не требуется; положение
    на земле вернёт `step`) и на нить остаётся ≥ MIN_SEGS_PER_FILAMENT отрезков. → (f, число стянутых)."""
    K = len(f.seg)
    L = np.linalg.norm(f.x[f.seg[:, 1]] - f.x[f.seg[:, 0]], axis=1)
    cand = np.nonzero((L < lim) & (f.seg[:, 0] != f.seg[:, 1]))[0]
    if len(cand) == 0:
        return f, 0
    cand = cand[np.argsort(L[cand], kind="stable")]
    room = np.bincount(f.fid, minlength=f.fid.max() + 1) - MIN_SEGS_PER_FILAMENT
    chosen = []
    free = np.ones(len(f.x), bool)
    for _ in range(ROUNDS):
        ok = free[f.seg[cand, 0]] & free[f.seg[cand, 1]]
        cand = cand[ok]
        if len(cand) == 0:
            break
        rank = np.arange(len(cand))
        best = np.full(len(f.x), len(cand))
        np.minimum.at(best, f.seg[cand, 0], rank)
        np.minimum.at(best, f.seg[cand, 1], rank)
        acc = (best[f.seg[cand, 0]] == rank) & (best[f.seg[cand, 1]] == rank)
        sel = cand[acc]
        free[f.seg[sel]] = False
        chosen.append(sel)
        cand = cand[~acc]
    if not chosen:
        return f, 0
    sel = np.concatenate(chosen)
    sel = sel[np.argsort(L[sel], kind="stable")]
    # не больше room[fid] на нить: порядковый номер внутри нити
    o = np.argsort(f.fid[sel], kind="stable")
    fs = f.fid[sel][o]
    first = np.r_[0, np.nonzero(np.diff(fs))[0] + 1]
    k_in = np.arange(len(fs)) - np.repeat(first, np.diff(np.r_[first, len(fs)]))
    sel = sel[o][k_in < room[fs]]
    if len(sel) == 0:
        return f, 0
    a, b = f.seg[sel, 0].copy(), f.seg[sel, 1].copy()
    sw = f.anchored[b] & ~f.anchored[a]          # остаётся якорный
    a[sw], b[sw] = b[sw], a[sw].copy()
    X = f.x.copy()
    mid = ~(f.anchored[a] ^ f.anchored[b])       # оба якорных или оба свободных — среднее
    X[a[mid]] = 0.5 * (f.x[a[mid]] + f.x[b[mid]])
    rep = np.arange(len(f.x))
    rep[b] = a
    f.anchored = f.anchored | (np.bincount(a, f.anchored[b], len(f.x)) > 0)
    seg = rep[f.seg]
    keep = seg[:, 0] != seg[:, 1]
    f.x, f.seg = X, seg[keep]
    f.gamma, f.core, f.fid, f.t_birth = f.gamma[keep], f.core[keep], f.fid[keep], f.t_birth[keep]
    return f, len(sel)


def _collapse_old(f, t, l_age, scale, age_min):
    """(а) Отрезки короче ½·l_age·scale·возраст (возраст ≥ age_min) стягиваются в узел; сумма потоков в свободных
    узлах сохраняется точно. Число стянутых → f.stats["coarsen_collapse"]."""
    if len(f.seg) == 0 or not l_age:
        return f
    for _ in range(PASSES):
        age = t - f.t_birth
        lim = np.where(age >= age_min, 0.5 * l_age * scale * age, 0.0)
        f, done = _collapse(f, lim)
        f.stats["coarsen_collapse"] += done
        if done == 0:
            break
        f = relabel(f)
    return f


def coarsen(f, t, params=None):
    """Огрубление: (а) по возрасту — отрезок короче ½·l_age·(t − t_birth) стягивается; (в) n_max — пока узлов > n_max,
    раунды k = 1…8: l_age·2ᵏ для самых старых отрезков (доля 0,5·k по возрасту, k ≥ 2 — все); не получилось —
    f.stats["coarsen_nmax_unmet"]. (б) r_amal не None → NotImplementedError. Новый Filaments, замкнутость сохранена."""
    p = dict(DEFAULTS)
    p.update(params or {})
    if p["r_amal"] is not None:
        raise NotImplementedError("слияние параллельных отрезков (r_amal) не реализовано: SWD3 v4, необязательная часть")
    f = f.copy()
    if len(f.seg) == 0:
        return f
    f = relabel(f)
    l_age = p["l_age"]
    f = _collapse_old(f, t, l_age, 1.0, -np.inf)
    n_max = p["n_max"]
    if n_max is None or len(f.x) <= n_max:
        return f
    for k in range(1, MAX_ROUNDS + 1):
        if len(f.x) <= n_max:
            break
        f.stats["coarsen_rounds"] += 1
        age = t - f.t_birth
        frac = min(1.0, 0.5 * k)
        age_min = np.quantile(age, 1.0 - frac) if frac < 1.0 else -np.inf
        f = _collapse_old(f, t, l_age if l_age else 0.1, 2.0 ** k, age_min)
    if len(f.x) > n_max:
        f.stats["coarsen_nmax_unmet"] += 1
    return f
