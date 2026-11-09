"""Влияние плоских треугольников постоянной плотности источника (Hess & Smith 1967; Katz & Plotkin, гл. 10–11),
сборка матрицы, решение (dense LU / GMRES), скорость, касательная скорость на поверхности. NumPy / CuPy.

Скорость единичного источника на треугольнике в точке P (σ = 1, V = ∇φ):
  V = [Ω·n + Σ_e m_e · ln((r1 + r2 + L)/(r1 + r2 − L))] / 4π,
Ω — телесный угол со знаком (Ван Оостером — Стратаски), m_e = t_e × n — внешняя в плоскости нормаль ребра. Формула
точна во всём пространстве; r1 + r2 − L = 2(r1 r2 + d1·d2)/(r1 + r2 + L) — без потери точности вдали от ребра."""
import time
import numpy as np

_BLOCK = 3_000_000  # элементов (точек × панелей) в блоке


def get_xp(backend):
    if backend in ("auto", None, "cupy"):
        try:
            import cupy as cp
            cp.cuda.runtime.getDeviceCount()
            return cp, "cupy"
        except Exception:
            if backend == "cupy":
                raise
    return np, "numpy"


def _geom(panels, xp):
    g = panels._geom
    if g is None:
        g = panels._geom = {}
    key = "cupy" if xp is not np else "numpy"
    if key not in g:
        v = panels.v
        e = np.stack([v[:, 1] - v[:, 0], v[:, 2] - v[:, 1], v[:, 0] - v[:, 2]], 1)      # (N, 3, 3) рёбра
        L = np.linalg.norm(e, axis=2)
        t = e / L[..., None]
        m = np.cross(t, panels.n[:, None, :])                                           # внешние нормали рёбер
        g[key] = dict(v=xp.asarray(v), n=xp.asarray(panels.n), m=xp.asarray(m), L=xp.asarray(L),
                      eps=xp.asarray(1e-3 * panels.ds))
    return g[key]


def _influence(xp, P, g, sl, self_idx=None):
    """Скорость единичных источников панелей sl в точках P (M, 3): (M, K, 3)."""
    v = g["v"][sl]
    n = g["n"][sl]
    m = g["m"][sl]
    L = g["L"][sl]
    eps = g["eps"][sl]
    d = v[None] - P[:, None, None, :]               # (M, K, 3 верш, 3)
    r = xp.sqrt((d * d).sum(-1))                    # (M, K, 3)
    a, b, c = d[:, :, 0], d[:, :, 1], d[:, :, 2]
    ra, rb, rc = r[:, :, 0], r[:, :, 1], r[:, :, 2]
    num = (a * xp.cross(b, c)).sum(-1)
    den = ra * rb * rc + (a * b).sum(-1) * rc + (a * c).sum(-1) * rb + (b * c).sum(-1) * ra
    omega = -2.0 * xp.arctan2(num, den)
    if self_idx is not None:
        omega = xp.where(self_idx, 0.0, omega)
    # рёбра: 0: A→B, 1: B→C, 2: C→A
    out = omega[..., None] * n[None]
    e2 = eps[None, :] ** 2
    for k in range(3):
        d1, d2 = d[:, :, k], d[:, :, (k + 1) % 3]
        r1 = xp.sqrt(r[:, :, k] ** 2 + e2)
        r2 = xp.sqrt(r[:, :, (k + 1) % 3] ** 2 + e2)
        Lk = L[None, :, k]
        s = r1 + r2
        q = 2.0 * (r1 * r2 + (d1 * d2).sum(-1)) / (s + Lk)
        le = xp.log((s + Lk) / xp.maximum(q, 1e-300))
        out = out + le[..., None] * m[None, :, k, :]
    return out / (4.0 * np.pi)


def _rows(xp, n_pts, n_pan):
    return max(1, _BLOCK // max(n_pan, 1))


class Influence:
    def __init__(self, A, backend, xp, t_assemble_s, N):
        self.A = A
        self.backend = backend
        self._xp = xp
        self.t_assemble_s = t_assemble_s
        self.N = N
        self._lu = None
        self._cache = {}   # решения для однородного фона (velocity_jh)

    @property
    def mem_bytes(self):
        return int(self.A.nbytes + (self._lu[0].nbytes if self._lu is not None else 0))

    def lu(self):
        if self._lu is None:
            if self.backend == "cupy":
                from cupyx.scipy.linalg import lu_factor
            else:
                from scipy.linalg import lu_factor
            self._lu = lu_factor(self.A)
        return self._lu


def assemble(panels, backend="auto"):
    xp, name = get_xp(backend)
    t0 = time.time()
    N = panels.N
    g = _geom(panels, xp)
    c = xp.asarray(panels.c)
    A = xp.empty((N, N))
    step = _rows(xp, N, N)
    cols = xp.arange(N)
    for i in range(0, N, step):
        sl = slice(i, min(N, i + step))
        V = _influence(xp, c[sl], g, slice(None))                           # (m, N, 3)
        A[sl] = (V * g["n"][sl][:, None, :]).sum(-1)
        idx = xp.arange(sl.start, sl.stop)
        A[idx, idx] = 0.5
    if name == "cupy":
        xp.cuda.Stream.null.synchronize()
    return Influence(A, name, xp, time.time() - t0, N)


def _gmres(xp, matvec, b, tol, restart=80, maxit=400):
    n = b.size
    x = xp.zeros(n)
    bn = float(xp.linalg.norm(b))
    if bn == 0:
        return x, 0
    it = 0
    while it < maxit:
        r = b - matvec(x)
        beta = float(xp.linalg.norm(r))
        if beta <= tol * bn:
            break
        V = [r / beta]
        H = np.zeros((restart + 1, restart))
        cs, sn = np.zeros(restart), np.zeros(restart)
        g = np.zeros(restart + 1)
        g[0] = beta
        k_used = 0
        for k in range(restart):
            w = matvec(V[k])
            for j in range(k + 1):
                H[j, k] = float(xp.dot(w, V[j]))
                w = w - H[j, k] * V[j]
            H[k + 1, k] = float(xp.linalg.norm(w))
            if H[k + 1, k] > 1e-300:
                V.append(w / H[k + 1, k])
            for j in range(k):
                t = cs[j] * H[j, k] + sn[j] * H[j + 1, k]
                H[j + 1, k] = -sn[j] * H[j, k] + cs[j] * H[j + 1, k]
                H[j, k] = t
            den = np.hypot(H[k, k], H[k + 1, k])
            cs[k], sn[k] = (1.0, 0.0) if den == 0 else (H[k, k] / den, H[k + 1, k] / den)
            H[k, k] = den
            H[k + 1, k] = 0.0
            g[k + 1] = -sn[k] * g[k]
            g[k] = cs[k] * g[k]
            it += 1
            k_used = k + 1
            if abs(g[k + 1]) <= 0.1 * tol * bn or H[k, k] == 0 or len(V) <= k + 1:
                break
        y = np.linalg.solve(H[:k_used, :k_used] + 1e-300 * np.eye(k_used), g[:k_used])
        for j in range(k_used):
            x = x + y[j] * V[j]
    return x, it


def horizontal_extra(extra, pts):
    """(u, v, w) внешней скорости в точках pts (M, 3) или нули."""
    if extra is None:
        z = np.zeros(pts.shape[0])
        return z, z.copy(), z.copy()
    u, v, w = extra(pts[:, 0], pts[:, 1], pts[:, 2])
    return np.asarray(u, float), np.asarray(v, float), np.asarray(w, float)


def rhs_of(panels, bg, extra=None):
    c = panels.c
    u, v, w = bg(c[:, 0], c[:, 1], c[:, 2])
    eu, ev, ew = horizontal_extra(extra, c)
    U = np.stack([np.asarray(u, float) + eu, np.asarray(v, float) + ev, np.asarray(w, float) + ew], 1)
    return -(U * panels.n).sum(1), U


def solve(panels, bg, extra=None, infl=None, method="dense", backend="auto"):
    if method not in ("dense", "gmres"):
        raise ValueError("method: dense | gmres")
    if infl is None:
        infl = assemble(panels, backend)
    xp = infl._xp
    b, U = rhs_of(panels, bg, extra)
    scale = float(np.max(np.abs(bg(panels.c[:, 0], panels.c[:, 1], panels.c[:, 2])[0]))) if b.size else 0.0
    bx = xp.asarray(b)
    t0 = time.time()
    if method == "dense":
        if infl.backend == "cupy":
            from cupyx.scipy.linalg import lu_solve
        else:
            from scipy.linalg import lu_solve
        sig = lu_solve(infl.lu(), bx)
    else:
        sig, _ = _gmres(xp, lambda z: infl.A @ z, bx, 1e-9)
    res = float(xp.max(xp.abs(infl.A @ sig - bx)))
    sigma = np.asarray(sig.get() if hasattr(sig, "get") else sig)
    return sigma, dict(N=panels.N, method=method, backend=infl.backend, residual=res,
                       t_assemble_s=infl.t_assemble_s, t_solve_s=time.time() - t0, mem_bytes=infl.mem_bytes)


def panel_velocity(panels, sigma, P, backend="auto", self_idx=None):
    """Скорость, наведённая панелями (σ в м/с) в точках P (M, 3): (M, 3), numpy."""
    xp, _ = get_xp(backend)
    g = _geom(panels, xp)
    P = np.atleast_2d(np.asarray(P, float))
    sg = xp.asarray(sigma)
    Px = xp.asarray(P)
    out = np.empty((P.shape[0], 3))
    step = _rows(xp, P.shape[0], panels.N)
    for i in range(0, P.shape[0], step):
        sl = slice(i, min(P.shape[0], i + step))
        si = None
        if self_idx is not None:
            si = xp.asarray(self_idx[sl])[:, None] == xp.arange(panels.N)[None]
        V = _influence(xp, Px[sl], g, slice(None), si)
        r = (V * sg[None, :, None]).sum(1)
        out[sl] = r.get() if hasattr(r, "get") else r
    return out


def velocity(panels, sigma, bg, x, y, z, extra=None, backend="auto"):
    x = np.asarray(x, float)
    y = np.asarray(y, float)
    z = np.asarray(z, float)
    shp = np.broadcast(x, y, z).shape
    xf, yf, zf = (np.broadcast_to(a, shp).ravel() for a in (x, y, z))
    P = np.stack([xf, yf, zf], 1)
    u, v, w = bg(xf, yf, zf)
    eu, ev, ew = horizontal_extra(extra, P)
    pv = panel_velocity(panels, sigma, P, backend)
    U = np.asarray(u, float) + eu + pv[:, 0]
    V = np.asarray(v, float) + ev + pv[:, 1]
    W = np.asarray(w, float) + ew + pv[:, 2]
    under = zf < panels.height(xf, yf)
    U[under] = V[under] = W[under] = np.nan
    return U.reshape(shp), V.reshape(shp), W.reshape(shp)


def tangent_velocity(panels, sigma, bg, extra=None, backend="auto"):
    """Касательная скорость в центроидах (N, 3) (нормальная часть — нулевая по граничному условию)."""
    c = panels.c
    u, v, w = bg(c[:, 0], c[:, 1], c[:, 2])
    eu, ev, ew = horizontal_extra(extra, c)
    pv = panel_velocity(panels, sigma, c, backend, self_idx=np.arange(panels.N))
    U = np.stack([np.asarray(u, float) + eu, np.asarray(v, float) + ev, np.asarray(w, float) + ew], 1) + pv
    return U - (U * panels.n).sum(1)[:, None] * panels.n
