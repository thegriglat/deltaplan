"""Прототип A в 3D: вихревые частицы с плавучестью (термик-кольцо) над землёй из панелей.

Модель (ω — завихрённость, b — плавучесть, ẑ вверх):  Dω/Dt = (ω·∇)u + ∇×(b ẑ) = (ω·∇)u + (∂_y b, −∂_x b, 0);
Db/Dt = −N² w (N² = 0 в опытах: нейтральная атмосфера; вовлечения нет — невязкая модель, как A в 2D).  Частица: x, α = ω·V (м³/с), b, V (объём), ядро σ.
Скорость: u = u_bg + u_ВС(частицы) + u_панелей (σ из условия u·n = 0 на всех центроидах).
Допущения: невязкая жидкость (без трения о землю — скольжение), Буссинеск, фон без растяжения (∇u_bg, ∇u_панелей
в (ω·∇)u не входят), ядро фиксировано (нет диффузии), частицы под землёй зеркалятся по вертикали."""
import time
import numpy as np
import cupy as cp
from . import vp

G0 = 9.81
THETA0 = 300.0


def b_of_dtheta(dth):
    return G0 * dth / THETA0


def ball_particles(center, R, h, b0, sg_over_h=1.3, pad_sigma=2.5):
    """Кубическая решётка шага h в шаре радиуса R; все частицы — b0 (однородное), α = 0."""
    Rm = R + pad_sigma * sg_over_h * h  # решётка шире шара: частицы с b = 0 несут завихрённость на краю
    n = int(np.ceil(Rm / h))
    g = (np.arange(-n, n + 1)) * h
    X = np.stack(np.meshgrid(g, g, g, indexing="ij"), -1).reshape(-1, 3)
    r = np.linalg.norm(X, axis=1)
    keep = r <= Rm
    X, r = X[keep], r[keep]
    b = np.where(r <= R, b0, 0.0)
    X = X + np.asarray(center)[None]
    N = len(X)
    return dict(x=X, a=np.zeros((N, 3)), b=b, V=np.full(N, h ** 3), sg=np.full(N, sg_over_h * h))


class Run:
    def __init__(self, ground, bg, parts, N2=0.0, sg_over_h=1.3, shifts=None, heater=None):
        self.g, self.bg, self.N2 = ground, bg, N2
        self.sg_over_h = sg_over_h
        self.x = parts["x"].copy()
        self.a = parts["a"].copy()
        self.b = parts["b"].copy()
        self.V = parts["V"].copy()
        self.sg = parts["sg"].copy()
        self.t = 0.0
        self.heater = heater
        self.sigma_bg = ground.solve_sigma(bg)
        self.t_vel = 0.0
        self.shifts = shifts

    # --- скорость
    def velocity_at(self, P, x=None, a=None, sg=None, sigma=None, want_grad=False):
        x = self.x if x is None else x
        a = self.a if a is None else a
        sg = self.sg if sg is None else sg
        r = vp.velocity(P, x, a, sg, shifts=self.shifts, grad=want_grad)
        uv, Gr = (r if want_grad else (r, None))
        uv = uv.get()
        u0 = np.stack(self.bg(P[:, 0], P[:, 1], P[:, 2]), 1)
        up = self.g.panel_vel(sigma, P)
        return u0 + uv + up, (Gr if want_grad else None)

    def _rhs(self, x, a, b):
        t0 = time.time()
        sigma = self.g.solve_sigma(self.bg, x, a, self.sg, self.shifts)
        u, Gr = self.velocity_at(x, x, a, self.sg, sigma, want_grad=True)
        gb = vp.grad_b(x, x, b * self.V, self.sg).get()
        stretch = cp.einsum("iab,ib->ia", Gr, cp.asarray(a)).get()
        baro = self.V[:, None] * np.stack([gb[:, 1], -gb[:, 0], np.zeros(len(x))], 1)
        da = stretch + baro
        db = -self.N2 * u[:, 2]
        self.t_vel += time.time() - t0
        return u, da, db

    def _reflect(self):
        zg = self.g.height(self.x[:, 0], self.x[:, 1]) + 1.0
        low = self.x[:, 2] < zg
        self.x[low, 2] = 2 * zg[low] - self.x[low, 2]

    def step(self, dt):
        x0, a0, b0 = self.x.copy(), self.a.copy(), self.b.copy()
        u1, da1, db1 = self._rhs(x0, a0, b0)
        xm, am, bm = x0 + 0.5 * dt * u1, a0 + 0.5 * dt * da1, b0 + 0.5 * dt * db1
        u2, da2, db2 = self._rhs(xm, am, bm)
        self.x, self.a, self.b = x0 + dt * u2, a0 + dt * da2, b0 + dt * db2
        self._reflect()
        self.t += dt
        if self.heater is not None:
            self.heater.hook(self, dt)

    # --- наблюдаемые
    def centroid(self):
        w = np.maximum(self.b * self.V, 0)
        return (self.x * w[:, None]).sum(0) / w.sum()

    def B_total(self):
        return float((self.b * self.V).sum())

    def induced(self, P):
        """Скорость, добавленная частицами к (фон + земля): u(t) − u(без частиц) в точках P."""
        sigma = self.g.solve_sigma(self.bg, self.x, self.a, self.sg, self.shifts)
        u, _ = self.velocity_at(P, sigma=sigma)
        u0, _ = self.velocity_at(P, x=self.x[:0], a=self.a[:0], sg=self.sg[:0], sigma=self.sigma_bg)
        return u - u0


# ---------------------------------------------------------------- нагретая поверхность (поток тепла, штиль)
class Heated:
    """Нагрев склона потоком: слой частиц у земли (агл < h) в пятне радиуса Rp получает db/dt = F_b/(h cosθ);
    несущие частицы — решётка вдоль рельефа (шаг h в плане и по вертикали, V = h³) над пятном; пустые места у земли
    досеваются каждые `every` с. F_b = g/θ0 · H/(ρ c_p) — кинематический поток плавучести, м²/с³."""

    def __init__(self, ground, centre_xy, Rp, h, H_wm2=250.0, height=300.0, half_w=None, every=5.0, sg_over_h=1.3, noise=0.0):
        from scipy.spatial import cKDTree
        self.cKDTree = cKDTree
        self.g, self.c, self.Rp, self.h, self.every, self.sgh = ground, np.asarray(centre_xy, float), Rp, h, every, sg_over_h
        self.Fb = G0 / THETA0 * H_wm2 / (1.2 * 1005.0)
        self.half_w = (Rp + 3 * sg_over_h * h + 2 * h) if half_w is None else half_w
        self.height = height
        self.noise = noise
        self._next = every

    def weight(self, x, y):
        rho = np.hypot(x - self.c[0], y - self.c[1])
        s = np.clip((rho - self.Rp) / (0.5 * self.Rp), 0, 1)
        w = 1 - s * s * (3 - 2 * s)
        if self.noise:
            ix, iy = np.floor(x / self.h), np.floor(y / self.h)
            r = np.sin(ix * 12.9898 + iy * 78.233) * 43758.5453
            w = w * (1 + self.noise * (2 * (r - np.floor(r)) - 1))  # детерминированный шум по колонке решётки
        return w

    def lattice(self, kmax=None):
        h = self.h
        g = np.arange(-self.half_w, self.half_w + 1e-9, h)
        X, Y = np.meshgrid(g + self.c[0], g + self.c[1], indexing="ij")
        X, Y = X.ravel(), Y.ravel()
        zg = self.g.height(X, Y)
        kmax = int(self.height / h) if kmax is None else kmax
        pts = [np.stack([X, Y, zg + (k + 0.5) * h], 1) for k in range(kmax)]
        return np.vstack(pts)

    def initial(self):
        P = self.lattice()
        N = len(P)
        return dict(x=P, a=np.zeros((N, 3)), b=np.zeros(N), V=np.full(N, self.h ** 3),
                    sg=np.full(N, self.sgh * self.h))

    def heat(self, run, dt):
        agl = run.x[:, 2] - self.g.height(run.x[:, 0], run.x[:, 1])
        zx, zy = self.g.slope(run.x[:, 0], run.x[:, 1])
        sec = np.sqrt(1 + zx ** 2 + zy ** 2)
        lay = (agl < self.h) & (agl > 0)
        w = self.weight(run.x[:, 0], run.x[:, 1])
        run.b[lay] += dt * self.Fb * w[lay] * sec[lay] / self.h

    def reseed(self, run):
        h = self.h
        gp = np.arange(-self.half_w, self.half_w + 1e-9, h)
        X, Y = np.meshgrid(gp + self.c[0], gp + self.c[1], indexing="ij")
        X, Y = X.ravel(), Y.ravel()
        P = np.stack([X, Y, self.g.height(X, Y) + 0.5 * h], 1)
        agl = run.x[:, 2] - self.g.height(run.x[:, 0], run.x[:, 1])
        near = run.x[agl < 1.5 * h]
        if len(near):
            d, _ = self.cKDTree(near).query(P)
            P = P[d > 0.7 * h]
        if len(P):
            n = len(P)
            run.x = np.vstack([run.x, P]); run.a = np.vstack([run.a, np.zeros((n, 3))])
            run.b = np.concatenate([run.b, np.zeros(n)]); run.V = np.concatenate([run.V, np.full(n, h ** 3)])
            run.sg = np.concatenate([run.sg, np.full(n, self.sgh * h)])
        return len(P)

    def hook(self, run, dt):
        """Вызывается из Run.step (после шага)."""
        self.heat(run, dt)
        if run.t >= self._next - 1e-9:
            self._next += self.every
            self.reseed(run)
