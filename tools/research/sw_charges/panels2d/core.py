"""Ядро panels2d. Только NumPy. Оси: x — по ветру, z — вверх; Γ > 0 — против часовой стрелки."""
from dataclasses import dataclass
import numpy as np

_CHUNK = 2_000_000  # элементов в блоке парных расчётов


class Terrain:
    """Линия земли; x строго возрастает; smooth_m > 0 — гауссово сглаживание (σ, м); вне диапазона z продолжена."""

    def __init__(self, x, z, smooth_m=0.0, far_m=20000.0):
        x = np.asarray(x, float)
        z = np.asarray(z, float)
        if x.ndim != 1 or x.shape != z.shape or x.size < 2 or np.any(np.diff(x) <= 0):
            raise ValueError("x строго возрастает, z той же длины")
        self.far_m = float(far_m)
        if smooth_m > 0:
            x, z = _gauss(x, z, smooth_m)
        self.x, self.z = x, z

    def height(self, x):
        return np.interp(x, self.x, self.z)  # вне диапазона — горизонтальное продолжение

    def smoothed(self, sigma):
        return Terrain(self.x, self.z, smooth_m=sigma, far_m=self.far_m)


def _gauss(x, z, sigma):
    dx = min(sigma / 4.0, float(np.min(np.diff(x))))
    n = int(np.ceil((x[-1] - x[0]) / dx)) + 1
    xs = np.linspace(x[0], x[-1], n)
    dx = xs[1] - xs[0]
    zs = np.interp(xs, x, z)
    m = int(np.ceil(4 * sigma / dx))
    k = np.exp(-0.5 * ((np.arange(-m, m + 1) * dx) / sigma) ** 2)
    k /= k.sum()
    zp = np.concatenate([np.full(m, zs[0]), zs, np.full(m, zs[-1])])
    return xs, np.convolve(zp, k, mode="valid")


@dataclass
class Panels:
    x1: np.ndarray
    z1: np.ndarray
    x2: np.ndarray
    z2: np.ndarray
    xc: np.ndarray
    zc: np.ndarray
    nx: np.ndarray
    nz: np.ndarray
    ds: np.ndarray
    far_m: float = 20000.0
    ds_min: float = 0.0

    @property
    def n(self):
        return self.x1.size

    def ground(self, x):
        """Высота линии панелей в x (вне — продолжение)."""
        return np.interp(x, np.append(self.x1, self.x2[-1]), np.append(self.z1, self.z2[-1]))


def build_panels(terrain, x_focus=None, ds_min=25.0, ds_max=400.0, growth=1.15):
    """Узлы по длине дуги линии земли (продолженной до ±far_m). В зоне ds_min — целое число равных панелей;
    в зонах роста остаток короче 0,5·h присоединяется к последней панели, т.е. обрезков нет (каждая ≥ 0,5·ds_min)."""
    far = terrain.far_m
    m = (terrain.x > -far) & (terrain.x < far)
    xe = np.concatenate([[-far], terrain.x[m], [far]])
    ze = terrain.height(xe)
    se = np.concatenate([[0.0], np.cumsum(np.hypot(np.diff(xe), np.diff(ze)))])
    s_of_x = lambda x: np.interp(x, xe, se)
    if x_focus is None:
        lo, hi = max(terrain.x[0], -far), min(terrain.x[-1], far)
    else:
        lo, hi = max(x_focus - 10 * ds_min, -far), min(x_focus + 10 * ds_min, far)
    s_lo, s_hi = float(s_of_x(lo)), float(s_of_x(hi))

    def grow(length):  # длины панелей зоны роста суммарно = length
        out, tot, h = [], 0.0, ds_min * growth
        while length - tot > 0.5 * min(h, ds_max):
            h = min(h, ds_max)
            if length - tot < 1.5 * h:  # остаток без обрезка
                out.append(length - tot)
                return out
            out.append(h)
            tot += h
            h *= growth
        if out:
            out[-1] += length - tot
        elif length > 0:
            out.append(length)
        return out

    n = max(1, int(round((s_hi - s_lo) / ds_min)))
    mid = np.full(n, (s_hi - s_lo) / n)
    left = np.array(grow(s_lo))[::-1]
    right = np.array(grow(se[-1] - s_hi))
    sizes = np.concatenate([left, mid, right])
    sn = np.concatenate([[0.0], np.cumsum(sizes)])
    sn[-1] = se[-1]
    xn = np.interp(sn, se, xe)
    zn = terrain.height(xn)
    X1, X2, Z1, Z2 = xn[:-1], xn[1:], zn[:-1], zn[1:]
    ds = np.hypot(X2 - X1, Z2 - Z1)
    return Panels(X1, Z1, X2, Z2, 0.5 * (X1 + X2), 0.5 * (Z1 + Z2),
                  -(Z2 - Z1) / ds, (X2 - X1) / ds, ds, far, float(ds_min))


# ---- фон ----
def bg_uniform(U):
    def bg(x, z):
        x = np.asarray(x, float)
        return np.full_like(x, U), np.zeros_like(x)
    return bg


def bg_profile(U10, alpha, z_sat, terrain, smooth_m=250.0, z0=0.1):
    """U(z_agl) = U10 (z_agl/10)^alpha до z_sat, выше постоянно; z_agl над землёй, сглаженной гауссом σ = smooth_m."""
    sm = terrain.smoothed(smooth_m)

    def bg(x, z):
        x = np.asarray(x, float)
        zagl = np.clip(np.asarray(z, float) - sm.height(x), z0, z_sat)
        return U10 * (zagl / 10.0) ** alpha, np.zeros_like(x)
    return bg


@dataclass
class Vortices:
    x: np.ndarray
    z: np.ndarray
    gamma: np.ndarray
    core: np.ndarray

    def __init__(self, x=(), z=(), gamma=(), core=()):
        self.x = np.atleast_1d(np.asarray(x, float)).copy()
        self.z = np.atleast_1d(np.asarray(z, float)).copy()
        self.gamma = np.atleast_1d(np.asarray(gamma, float)).copy()
        c = np.atleast_1d(np.asarray(core, float))
        self.core = np.full_like(self.x, c[0]) if (c.size == 1 and self.x.size != 1) else c.copy()
        if not (self.x.size == self.z.size == self.gamma.size == self.core.size):
            raise ValueError("размеры вихрей не совпадают")

    @property
    def n(self):
        return self.x.size


def _vort_vel(v, x, z):
    """Скорость вихрей Лэмба — Озеена в точках (x, z) формы (M,)."""
    u = np.zeros(x.shape)
    w = np.zeros(x.shape)
    if v is None or v.n == 0:
        return u, w
    step_ = max(1, _CHUNK // v.n)
    for i in range(0, x.size, step_):
        dx = x[i:i + step_, None] - v.x[None]
        dz = z[i:i + step_, None] - v.z[None]
        r2 = dx * dx + dz * dz
        f = v.gamma[None] / (2 * np.pi) * (-np.expm1(-r2 / v.core[None] ** 2)) / np.maximum(r2, 1e-300)
        u[i:i + step_] = (-dz * f).sum(1)
        w[i:i + step_] = (dx * f).sum(1)
    return u, w


def _pair(p, x, z, js=slice(None)):
    """Скорость единичных источников панелей js в точках x, z: массивы (M, J) (u, w)."""
    x1, z1, ds = p.x1[js], p.z1[js], p.ds[js]
    tx, tz = p.nz[js], -p.nx[js]
    nx, nz = p.nx[js], p.nz[js]
    dx = x[:, None] - x1[None]
    dz = z[:, None] - z1[None]
    xl = dx * tx + dz * tz
    zl = dx * nx + dz * nz
    r1 = xl * xl + zl * zl
    r2 = (xl - ds) ** 2 + zl * zl
    tiny = 1e-24
    ul = np.log(np.maximum(r1, tiny) / np.maximum(r2, tiny)) / (4 * np.pi)
    wl = (np.arctan2(zl, xl - ds) - np.arctan2(zl, xl)) / (2 * np.pi)
    return ul * tx + wl * nx, ul * tz + wl * nz


def _panel_vel(p, sigma, x, z):
    u = np.zeros(x.shape)
    w = np.zeros(x.shape)
    step_ = max(1, _CHUNK // p.n)
    for i in range(0, x.size, step_):
        pu, pw = _pair(p, x[i:i + step_], z[i:i + step_])
        u[i:i + step_] = pu @ sigma
        w[i:i + step_] = pw @ sigma
    return u, w


def _rhs(p, bg, vortices):
    u, w = bg(p.xc, p.zc)
    vu, vw = _vort_vel(vortices, p.xc, p.zc)
    return -((u + vu) * p.nx + (w + vw) * p.nz)


def _matrix(p):
    A = np.empty((p.n, p.n))
    step_ = max(1, _CHUNK // p.n)
    for i in range(0, p.n, step_):
        sl = slice(i, i + step_)
        pu, pw = _pair(p, p.xc[sl], p.zc[sl])
        A[sl] = pu * p.nx[sl, None] + pw * p.nz[sl, None]
    A[np.arange(p.n), np.arange(p.n)] = 0.5  # собственный вклад σ/2
    return A


def solve(panels, bg, vortices=None):
    return np.linalg.solve(_matrix(panels), _rhs(panels, bg, vortices))


def residual(panels, sigma, bg, vortices=None):
    """max |u·n| в точках коллокации."""
    return float(np.max(np.abs(_matrix(panels) @ sigma - _rhs(panels, bg, vortices))))


def velocity(panels, sigma, bg, x, z, vortices=None):
    x = np.asarray(x, float)
    z = np.asarray(z, float)
    shp = x.shape
    xf, zf = x.ravel(), z.ravel()
    u, w = bg(xf, zf)
    pu, pw = _panel_vel(panels, sigma, xf, zf)
    vu, vw = _vort_vel(vortices, xf, zf)
    u = u + pu + vu
    w = w + pw + vw
    under = zf < panels.ground(xf)
    u = np.where(under, np.nan, u)
    w = np.where(under, np.nan, w)
    return u.reshape(shp), w.reshape(shp)


def step(state, dt):
    """Шаг МДВ: решить, RK2 (средняя точка) для вихрей, удалить ушедших, родить новые в точках shed.
    state: panels, bg, vortices, t, shed; ведётся учёт state['born'], state['lost'] (сумма Γ)."""
    p, bg, vt = state["panels"], state["bg"], state["vortices"]
    state.setdefault("born", 0.0)
    state.setdefault("lost", 0.0)
    if vt.n:
        sg = solve(p, bg, vt)
        u1, w1 = velocity(p, sg, bg, vt.x, vt.z, vt)
        mid = Vortices(vt.x + 0.5 * dt * u1, vt.z + 0.5 * dt * w1, vt.gamma, vt.core)
        sg2 = solve(p, bg, mid)
        u2, w2 = velocity(p, sg2, bg, mid.x, mid.z, mid)
        nx_, nz_ = vt.x + dt * u2, vt.z + dt * w2
        gone = (~np.isfinite(nx_)) | (~np.isfinite(nz_)) | (np.abs(nx_) > p.far_m) | (nz_ < p.ground(nx_))
        state["lost"] += float(vt.gamma[gone].sum())
        keep = ~gone
        vt = Vortices(nx_[keep], nz_[keep], vt.gamma[keep], vt.core[keep])
    # рождение: Γ = −½ u_s² dt по скорости над кромкой (с учётом вихрей)
    shed = state.get("shed") or []
    if shed:
        sg = solve(p, bg, vt)
        xs = np.array([s["x_s"] for s in shed], float)
        zs = np.array([s["z_s"] for s in shed], float)
        us, ws = velocity(p, sg, bg, xs, zs, vt)
        sp2 = us * us + ws * ws
        ok = np.isfinite(sp2)
        g = -0.5 * sp2[ok] * dt
        core = np.full(g.size, 0.5 * float(p.ds_min))
        state["born"] += float(g.sum())
        vt = Vortices(np.append(vt.x, xs[ok]), np.append(vt.z, zs[ok]), np.append(vt.gamma, g),
                      np.append(vt.core, core))
    state["vortices"] = vt
    state["t"] = state.get("t", 0.0) + dt
    return state
