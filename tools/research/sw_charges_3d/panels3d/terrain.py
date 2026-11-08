"""Рельеф-растр и фоновые поля panels3d (SWD2). Оси: x — восток, y — север, z — вверх (м)."""
import numpy as np
from scipy.ndimage import gaussian_filter


class Terrain3D:
    """Растр высот: x (nx), y (ny) по возрастанию с постоянным шагом, z (ny, nx). `smooth_m` > 0 — гауссово
    сглаживание σ. Вне растра: высота ближайшей точки края, линейно сводимая к `z_far` (медиана края) на расстоянии
    `blend_m` от растра, дальше — `z_far`; продолжение — до квадрата ±`far_m` от центра растра."""

    def __init__(self, x, y, z, smooth_m=0.0, far_m=20000.0, blend_m=2000.0):
        x = np.asarray(x, float)
        y = np.asarray(y, float)
        z = np.asarray(z, float)
        if x.ndim != 1 or y.ndim != 1 or x.size < 2 or y.size < 2 or z.shape != (y.size, x.size):
            raise ValueError("x (nx), y (ny), z (ny, nx)")
        dx, dy = np.diff(x), np.diff(y)
        if np.any(dx <= 0) or np.any(dy <= 0):
            raise ValueError("x и y строго по возрастанию")
        if np.ptp(dx) > 1e-6 * dx[0] or np.ptp(dy) > 1e-6 * dy[0]:
            raise ValueError("шаг x и y постоянный")
        self.x0, self.y0 = float(x[0]), float(y[0])
        self.dx, self.dy = float(dx[0]), float(dy[0])
        self.nx, self.ny = x.size, y.size
        self.x, self.y = x, y
        self.far_m = float(far_m)
        self.blend_m = float(blend_m)
        self.smooth_m = float(smooth_m)
        self._z_raw = z
        if smooth_m > 0:
            z = gaussian_filter(z, (smooth_m / self.dy, smooth_m / self.dx), mode="nearest")
        self.z = z
        edge = np.concatenate([z[0], z[-1], z[:, 0], z[:, -1]])
        self.z_far = float(np.median(edge))
        self.cx = 0.5 * (x[0] + x[-1])
        self.cy = 0.5 * (y[0] + y[-1])

    def height(self, x, y):
        x = np.asarray(x, float)
        y = np.asarray(y, float)
        xc = np.clip(x, self.x[0], self.x[-1])
        yc = np.clip(y, self.y[0], self.y[-1])
        fx = (xc - self.x0) / self.dx
        fy = (yc - self.y0) / self.dy
        i = np.clip(np.floor(fx).astype(int), 0, self.nx - 2)
        j = np.clip(np.floor(fy).astype(int), 0, self.ny - 2)
        ax, ay = fx - i, fy - j
        z = self.z
        h = ((1 - ax) * (1 - ay) * z[j, i] + ax * (1 - ay) * z[j, i + 1]
             + (1 - ax) * ay * z[j + 1, i] + ax * ay * z[j + 1, i + 1])
        d = np.hypot(x - xc, y - yc)
        if self.blend_m <= 0:
            w = (d > 0).astype(float)
        else:
            w = np.clip(d / self.blend_m, 0.0, 1.0)
        return (1 - w) * h + w * self.z_far

    def smoothed(self, sigma):
        """Копия с дополнительным сглаживанием σ (для z_agl фона)."""
        t = Terrain3D(self.x, self.y, self._z_raw, smooth_m=sigma, far_m=self.far_m, blend_m=self.blend_m)
        t.z_far = self.z_far
        return t


def _wind_dir(wind_to):
    w = np.asarray(wind_to, float)
    n = float(np.hypot(w[0], w[1]))
    if n == 0:
        raise ValueError("wind_to ненулевой")
    return w[0] / n, w[1] / n


def bg_uniform(U, wind_to=(1, 0)):
    ex, ey = _wind_dir(wind_to)

    def bg(x, y, z):
        x = np.asarray(x, float)
        o = np.ones_like(x)
        return U * ex * o, U * ey * o, 0.0 * o
    bg.wind_to = (ex, ey)
    bg.kind = "uniform"
    return bg


def bg_profile(U10, alpha, z_sat, terrain, wind_to=(1, 0), smooth_m=250.0):
    """U(z_agl) = U10 (z_agl/10)^alpha до z_sat, выше постоянно; z_agl над землёй, сглаженной σ = smooth_m; w = 0."""
    ex, ey = _wind_dir(wind_to)
    sm = terrain.smoothed(smooth_m) if smooth_m and smooth_m > 0 else terrain

    def bg(x, y, z):
        x = np.asarray(x, float)
        y = np.asarray(y, float)
        zagl = np.clip(np.asarray(z, float) - sm.height(x, y), 0.1, z_sat)
        U = U10 * (zagl / 10.0) ** alpha
        return U * ex, U * ey, np.zeros_like(U)
    bg.wind_to = (ex, ey)
    bg.kind = "profile"
    return bg


def bg_zero():
    def bg(x, y, z):
        o = np.zeros_like(np.asarray(x, float))
        return o, o.copy(), o.copy()
    bg.wind_to = None
    bg.kind = "zero"
    return bg


def wind_of(bg, terrain):
    """Единичное направление «куда» фона: атрибут `wind_to` или горизонтальный вектор на 100 м над центром растра."""
    w = getattr(bg, "wind_to", None)
    if w is not None:
        return float(w[0]), float(w[1])
    z = float(terrain.height(terrain.cx, terrain.cy)) + 100.0
    u, v, _ = bg(np.array([terrain.cx]), np.array([terrain.cy]), np.array([z]))
    n = float(np.hypot(u[0], v[0]))
    if n < 1e-12:
        return 1.0, 0.0
    return float(u[0] / n), float(v[0] / n)


def u_ref_of(bg, terrain):
    """|bg| на 100 м над землёй в середине наветренного края растра; направление — wind_of."""
    ex, ey = wind_of(bg, terrain)
    hx, hy = 0.5 * (terrain.x[-1] - terrain.x[0]), 0.5 * (terrain.y[-1] - terrain.y[0])
    t = min(hx / abs(ex) if abs(ex) > 1e-12 else np.inf, hy / abs(ey) if abs(ey) > 1e-12 else np.inf)
    px, py = terrain.cx - ex * t, terrain.cy - ey * t
    pz = float(terrain.height(px, py)) + 100.0
    u, v, w = bg(np.array([px]), np.array([py]), np.array([pz]))
    return float(np.sqrt(u[0] ** 2 + v[0] ** 2 + w[0] ** 2)), (px, py)
