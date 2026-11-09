"""Вихревые нити: структура, Био — Савар (Розенхед — Мур), конструкторы. Контракт SWD3."""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

try:  # CuPy — по возможности
    import cupy as _cp
except Exception:  # pragma: no cover
    _cp = None

GPU_PAIRS = 1_000_000  # узлов × отрезков, с которых "auto" выбирает GPU
_gpu_ok = None


def _gpu_available():
    global _gpu_ok
    if _gpu_ok is None:
        try:
            _gpu_ok = _cp is not None and _cp.cuda.runtime.getDeviceCount() > 0
            if _gpu_ok:
                _cp.asarray([1.0]).sum()
        except Exception:
            _gpu_ok = False
    return _gpu_ok


@dataclass
class Filaments:
    """Граф отрезков: узлы x (M,3) м; seg (K,2) от a к b; gamma (K) м²/с (вдоль a→b, правая рука);
    core (K) м; anchored (M) bool; fid (K) номер нити. stats — накопительные счётчики событий."""
    x: np.ndarray = field(default_factory=lambda: np.zeros((0, 3)))
    seg: np.ndarray = field(default_factory=lambda: np.zeros((0, 2), int))
    gamma: np.ndarray = field(default_factory=lambda: np.zeros(0))
    core: np.ndarray = field(default_factory=lambda: np.zeros(0))
    anchored: np.ndarray = field(default_factory=lambda: np.zeros(0, bool))
    fid: np.ndarray = field(default_factory=lambda: np.zeros(0, int))
    stats: dict = field(default_factory=dict)
    t_birth: np.ndarray = field(default_factory=lambda: np.zeros(0))   # K: время схода отрезка, с (SWD3 v3)

    def __post_init__(self):
        self.x = np.asarray(self.x, float).reshape(-1, 3)
        self.seg = np.asarray(self.seg, int).reshape(-1, 2)
        k = len(self.seg)
        self.gamma = np.broadcast_to(np.asarray(self.gamma, float), (k,)).copy()
        self.core = np.broadcast_to(np.asarray(self.core, float), (k,)).copy()
        self.anchored = np.broadcast_to(np.asarray(self.anchored, bool), (len(self.x),)).copy()
        self.fid = np.asarray(self.fid, int).reshape(-1)
        if len(self.fid) != k:
            self.fid = np.zeros(k, int)
        tb = np.asarray(self.t_birth, float).reshape(-1)
        self.t_birth = np.zeros(k) if len(tb) != k else tb.copy()
        for key in ("split", "merge", "reconnect", "lifted", "removed", "coarsen_collapse", "coarsen_rounds",
                    "coarsen_nmax_unmet"):
            self.stats.setdefault(key, 0)

    def copy(self):
        return Filaments(self.x.copy(), self.seg.copy(), self.gamma.copy(), self.core.copy(),
                         self.anchored.copy(), self.fid.copy(), dict(self.stats), self.t_birth.copy())

    @property
    def n_filaments(self):
        return int(len(np.unique(self.fid))) if len(self.seg) else 0


def imbalance(f):
    """max |Σ Γ_вх − Σ Γ_исх| по неякорным узлам, м²/с."""
    if len(f.seg) == 0:
        return 0.0
    net = np.bincount(f.seg[:, 1], f.gamma, len(f.x)) - np.bincount(f.seg[:, 0], f.gamma, len(f.x))
    net = net[~f.anchored]
    return float(np.abs(net).max()) if len(net) else 0.0


def _bs_chunk(xp, px, py, pz, a, t, L, d2, g):
    """Скорость в точках (N) от K прямых отрезков: замкнутая форма интеграла Розенхеда — Мура.
    u = Γ/(4π) (t × r0) [ (s−s0) / (A sqrt((s−s0)²+A)) ]₀ᴸ, r0 = P − a, s0 = r0·t, A = |t×r0|² + δ²."""
    rx = px[:, None] - a[None, :, 0]
    ry = py[:, None] - a[None, :, 1]
    rz = pz[:, None] - a[None, :, 2]
    tx, ty, tz = t[None, :, 0], t[None, :, 1], t[None, :, 2]
    s0 = rx * tx + ry * ty + rz * tz
    cx = ty * rz - tz * ry
    cy = tz * rx - tx * rz
    cz = tx * ry - ty * rx
    A = cx * cx + cy * cy + cz * cz + d2[None, :]
    e1 = L[None, :] - s0
    c = g[None, :] / (4 * np.pi) * (e1 / xp.sqrt(e1 * e1 + A) + s0 / xp.sqrt(s0 * s0 + A)) / A
    return (c * cx).sum(1), (c * cy).sum(1), (c * cz).sum(1)


def induced(f, x, y, z, backend="auto", method="direct", theta=0.5):
    """Скорость (u, v, w) в точках от всех нитей (Био — Савар, Розенхед — Мур, δ = core отрезка).
    backend: "auto" (GPU при N·K ≥ 1e6, если есть), "numpy", "cupy"."""
    if method == "tree":
        raise NotImplementedError("method='tree' (Барнс — Хат) не реализован: SWD3 v4, необязательная часть")
    if method != "direct":
        raise ValueError("method: direct | tree")
    x = np.asarray(x, float)
    shape = x.shape
    px, py, pz = (np.ravel(np.asarray(c, float)) for c in np.broadcast_arrays(x, y, z))
    n = len(px)
    k = len(f.seg)
    if n == 0 or k == 0:
        zz = np.zeros(shape)
        return zz, zz.copy(), zz.copy()
    a = f.x[f.seg[:, 0]]
    d = f.x[f.seg[:, 1]] - a
    L = np.linalg.norm(d, axis=1)
    ok = L > 1e-12
    a, d, L = a[ok], d[ok], L[ok]
    t = d / L[:, None]
    d2, g = f.core[ok] ** 2, f.gamma[ok]
    use_gpu = backend == "cupy" or (backend == "auto" and n * k >= GPU_PAIRS and _gpu_available())
    if use_gpu:
        xp = _cp
        px, py, pz, a, t, L, d2, g = (xp.asarray(q) for q in (px, py, pz, a, t, L, d2, g))
    else:
        xp = np
    kk = len(L)
    step = max(1, int(1_500_000 // max(kk, 1)))
    out = [[], [], []]
    for i in range(0, n, step):
        r = _bs_chunk(xp, px[i:i + step], py[i:i + step], pz[i:i + step], a, t, L, d2, g)
        for j in range(3):
            out[j].append(r[j])
    res = []
    for j in range(3):
        v = xp.concatenate(out[j])
        res.append((_cp.asnumpy(v) if use_gpu else v).reshape(shape))
    return tuple(res)


def self_velocity(f, method="direct", theta=0.5):
    """Скорость в узлах (M,3) от всех отрезков той же регуляризацией."""
    if len(f.x) == 0:
        return np.zeros((0, 3))
    u, v, w = induced(f, f.x[:, 0], f.x[:, 1], f.x[:, 2], method=method, theta=theta)
    return np.stack([u, v, w], 1)


def _unit(v):
    v = np.asarray(v, float)
    return v / np.linalg.norm(v)


def ring(R, gamma, core, n, center=(0, 0, 0), normal=(0, 0, 1)):
    """Кольцо радиуса R из n отрезков; обход против часовой вокруг normal; движется вдоль +normal при Γ > 0."""
    nrm = _unit(normal)
    h = np.array([1.0, 0, 0]) if abs(nrm[0]) < 0.9 else np.array([0, 1.0, 0])
    e1 = _unit(np.cross(nrm, h))
    e2 = np.cross(nrm, e1)
    ph = 2 * np.pi * np.arange(n) / n
    x = np.asarray(center, float) + R * (np.cos(ph)[:, None] * e1 + np.sin(ph)[:, None] * e2)
    seg = np.stack([np.arange(n), (np.arange(n) + 1) % n], 1)
    return Filaments(x, seg, np.full(n, gamma, float), np.full(n, core, float), np.zeros(n, bool), np.zeros(n, int))


def line(points, gamma, core, anchored_ends=True):
    """Ломаная по points (M,3), Γ вдоль порядка точек; концы — якорные узлы (замкнуты землёй)."""
    p = np.asarray(points, float).reshape(-1, 3)
    m = len(p)
    seg = np.stack([np.arange(m - 1), np.arange(1, m)], 1)
    anc = np.zeros(m, bool)
    if anchored_ends and m:
        anc[0] = anc[-1] = True
    return Filaments(p, seg, np.full(m - 1, gamma, float), np.full(m - 1, core, float), anc, np.zeros(m - 1, int))
