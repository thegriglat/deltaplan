"""Ядро настройки SY-5: пространство θ (лог для широких пределов), латинский гиперкуб, полиномы Professor,
подгонка θ к одному эталонному вектору (χ², ограниченная оптимизация), eigentunes (якобиан χ²)."""
import numpy as np
from scipy.optimize import least_squares
from scipy.stats import qmc
from professor_core import Surrogate, eigentunes  # noqa: F401  (копия tools/research/tune/professor.py)


class Space:
    """θ ↔ u ∈ [-1,1]^d; параметр лог-масштабный, если lo > 0 и hi/lo ≥ 5."""
    def __init__(self, tunable):
        self.names = list(tunable)
        self.lo = np.array([tunable[n][0] for n in self.names], float)
        self.hi = np.array([tunable[n][1] for n in self.names], float)
        self.default = np.array([tunable[n][2] for n in self.names], float)
        self.log = (self.lo > 0) & (self.hi / np.where(self.lo > 0, self.lo, 1) >= 5)

    def _f(self, p):
        return np.where(self.log, np.log(np.where(self.log, p, 1.0)), p)

    def to_u(self, p):
        p = np.asarray(p, float)
        a, b = self._f(self.lo), self._f(self.hi)
        return 2 * (self._f(p) - a) / (b - a) - 1

    def from_u(self, u):
        u = np.clip(np.asarray(u, float), -1, 1)
        a, b = self._f(self.lo), self._f(self.hi)
        x = a + (u + 1) / 2 * (b - a)
        return np.where(self.log, np.exp(np.where(self.log, x, 0.0)), x)

    def theta(self, u):
        return {n: float(v) for n, v in zip(self.names, self.from_u(u))}


def lhs(dim, n, seed=0):
    """Латинский гиперкуб в u ∈ [-1,1]^dim (оптимизированный по дискрепансии)."""
    return 2 * qmc.LatinHypercube(d=dim, seed=seed, optimization="random-cd").random(n) - 1


def fit_one(sur, y_ref, sigma, dim, starts=24, seed=0, fixed=None):
    """argmin_u Σ ((sur(u) − y_ref)/σ)² по u ∈ [-1,1]^dim, несколько стартов; fixed = {индекс: u} — закреплённые координаты.
    nan в y_ref/σ — наблюдаемая пропущена. Возвращает (u, χ², остатки/σ, ndf)."""
    fixed = fixed or {}
    free = [k for k in range(dim) if k not in fixed]
    ok = np.isfinite(y_ref) & np.isfinite(sigma) & (sigma > 0)

    def full(x):
        u = np.zeros(dim)
        u[free] = x
        for k, v in fixed.items():
            u[k] = v
        return u
    f = lambda x: ((sur(full(x))[0] - y_ref) / sigma)[ok]
    rng = np.random.default_rng(seed)
    best = None
    for s in range(starts):
        x0 = np.zeros(len(free)) if s == 0 else rng.uniform(-1, 1, len(free))
        r = least_squares(f, x0, bounds=(-1, 1))
        if best is None or r.cost < best.cost:
            best = r
    res = np.full(len(y_ref), np.nan)
    res[ok] = best.fun
    return full(best.x), float(2 * best.cost), res, int(ok.sum() - len(free))


def chi2_cov(sur, u, sigma, ok, eps=1e-3):
    """Ковариация θ (в u) ≈ (JᵀJ)⁻¹ по якобиану полиномов в точке u: 1σ-область χ² = χ²min + 1."""
    d = len(u)
    J = np.zeros((int(ok.sum()), d))
    for k in range(d):
        du = np.zeros(d); du[k] = eps
        J[:, k] = ((sur(u + du)[0] - sur(u - du)[0]) / (2 * eps) / sigma)[ok]
    return np.linalg.pinv(J.T @ J)
