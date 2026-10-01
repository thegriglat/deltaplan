"""AM-09: схема Professor — полиномы по прогонам, χ², неопределённости, eigentunes, сходимость.

Общие функции для fit.py. Параметры преобразуются в u ∈ [−1, 1] (логарифмически), каждая
наблюдаемая аппроксимируется полиномом полной степени d по u (МНК), ошибка аппроксимации —
по выбросу-одному (LOO, через матрицу-шляпу).
"""
from __future__ import annotations

import itertools
import math

import numpy as np


class Space:
    def __init__(self, names, lo, hi, log=True):
        self.names, self.lo, self.hi, self.log = list(names), np.array(lo, float), np.array(hi, float), log

    def to_u(self, p):
        p = np.atleast_2d(np.asarray(p, float))
        if self.log:
            return 2 * (np.log(p) - np.log(self.lo)) / (np.log(self.hi) - np.log(self.lo)) - 1
        return 2 * (p - self.lo) / (self.hi - self.lo) - 1

    def from_u(self, u):
        u = np.atleast_2d(np.asarray(u, float))
        if self.log:
            return np.exp(np.log(self.lo) + (u + 1) / 2 * (np.log(self.hi) - np.log(self.lo)))
        return self.lo + (u + 1) / 2 * (self.hi - self.lo)


def monomials(dim, deg):
    return [e for d in range(deg + 1) for e in itertools.product(range(d + 1), repeat=dim) if sum(e) == d]


def design(u, mons):
    u = np.atleast_2d(u)
    return np.stack([np.prod(u ** np.array(e)[None, :], axis=1) for e in mons], axis=1)


class Surrogate:
    """Полиномы степени deg для всех наблюдаемых сразу: Y (n_runs, n_obs)."""

    def __init__(self, U, Y, deg):
        self.mons = monomials(U.shape[1], deg)
        X = design(U, self.mons)
        if X.shape[0] <= X.shape[1]:
            raise ValueError(f"прогонов {X.shape[0]} ≤ коэффициентов {X.shape[1]}")
        self.coef, *_ = np.linalg.lstsq(X, Y, rcond=None)
        H = X @ np.linalg.pinv(X)
        r = Y - X @ self.coef
        loo = r / (1 - np.diag(H))[:, None]
        self.loo_rms = np.sqrt(np.mean(loo ** 2, axis=0))
        self.fit_rms = np.sqrt(np.mean(r ** 2, axis=0))

    def __call__(self, u):
        return design(np.atleast_2d(u), self.mons) @ self.coef


def eigentunes(cov):
    """Собственные направления ковариации: (λ, векторы) по убыванию λ."""
    w, v = np.linalg.eigh(cov)
    o = np.argsort(w)[::-1]
    return w[o], v[:, o]


def corr(cov):
    s = np.sqrt(np.diag(cov))
    return cov / np.outer(s, s)


def chi2_prob(chi2, ndf):
    """P(χ² ≥ chi2) для ndf степеней свободы (регуляризованная неполная гамма, без scipy)."""
    from scipy.special import gammaincc
    return float(gammaincc(ndf / 2, chi2 / 2))


def fmt(x, s):
    if s <= 0 or not math.isfinite(s):
        return f"{x:.3g}"
    d = max(0, -int(math.floor(math.log10(s))) + 1)
    return f"{x:.{d}f} ± {s:.{d}f}"
