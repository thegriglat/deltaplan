"""Шаг 3 прототипа A: вихревые частицы с плавучестью (pa_core.Sim) над линией рельефа; земля — панели panels2d (SW6 v2).

Скорость частицы = фон + панели (σ из solve) + частицы (ядро Лэмба — Озеена, RawKernel). Нормальная скорость на
линии земли гасится решением N×N на коллокациях: правая часть = −(фон + скорость частиц)·n. Матрица панелей не
меняется — обращается один раз (np.linalg.inv); solve раз в `resolve_every` вычислений скорости.
Частицы ушедшие под землю: mode='reflect' (зеркало по вертикали относительно линии земли, Γ не меняется) или 'delete'.
Учёт: lost_G, n_under. Баротропная часть ∂b/∂x — только от частиц (свободное пространство; изображений b у земли нет).
"""
import os, sys, time
import numpy as np
import cupy as cp

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..'))
from pa_core import Sim, make_images, disk_lattice   # noqa: E402,F401
import panels2d as P2                                 # noqa: E402
from panels2d.core import _matrix                     # noqa: E402  (только чтение: матрица влияния)

G0, TH0 = 9.81, 300.0


class Ground:
    """Панели + обратная матрица + GPU-расчёт скорости от источников панелей."""

    def __init__(self, terrain, ds_min=25.0, ds_max=400.0, x_focus=None):
        self.terrain = terrain
        self.p = P2.build_panels(terrain, x_focus=x_focus, ds_min=ds_min, ds_max=ds_max)
        t0 = time.time()
        self.Minv = np.linalg.inv(_matrix(self.p))
        self.t_setup = time.time() - t0
        p = self.p
        self.g = {k: cp.asarray(v) for k, v in dict(x1=p.x1, z1=p.z1, ds=p.ds, nx=p.nx, nz=p.nz).items()}
        self.xc, self.zc = p.xc, p.zc
        self.gxc, self.gzc = cp.asarray(p.xc), cp.asarray(p.zc)

    def panel_vel(self, sigma, x, z, blk=4096):
        """Скорость источников панелей (cupy, x,z — cupy (M,)). Те же формулы, что panels2d._pair."""
        g = self.g
        sg = cp.asarray(sigma)
        tx, tz = g['nz'], -g['nx']
        u = cp.empty_like(x); w = cp.empty_like(x)
        for a in range(0, x.size, blk):
            dx = x[a:a + blk, None] - g['x1'][None]
            dz = z[a:a + blk, None] - g['z1'][None]
            xl = dx * tx[None] + dz * tz[None]
            zl = dx * g['nx'][None] + dz * g['nz'][None]
            r1 = xl * xl + zl * zl
            r2 = (xl - g['ds'][None]) ** 2 + zl * zl
            ul = cp.log(cp.maximum(r1, 1e-24) / cp.maximum(r2, 1e-24)) / (4 * np.pi)
            wl = (cp.arctan2(zl, xl - g['ds'][None]) - cp.arctan2(zl, xl)) / (2 * np.pi)
            u[a:a + blk] = ((ul * tx[None] + wl * g['nx'][None]) * sg[None]).sum(1)
            w[a:a + blk] = ((ul * tz[None] + wl * g['nz'][None]) * sg[None]).sum(1)
        return u, w


class Run:
    """Частицы + земля + фон. bg — callable numpy (x, z) → (u, w) (panels2d bg_*)."""

    def __init__(self, ground, bg, sigma_core, mode='reflect', resolve_every=1, x_max=None):
        self.gr = ground
        self.bg = bg
        self.sim = Sim(sigma_core, make_images())
        self.mode = mode
        self.k = resolve_every
        self._cnt = 0
        self._sig = None
        self.core = float(sigma_core)
        self.lost_G = 0.0
        self.n_under = 0
        self.n_deleted = 0
        self.x_max = x_max
        self.born_G = 0.0
        self.t = 0.0
        self.t_solve = 0.0
        self.t_vel = 0.0

    def bgc(self, x, z):
        u, w = self.bg(cp.asnumpy(x), cp.asnumpy(z))
        return cp.asarray(u), cp.asarray(w)

    def solve_sigma(self, st):
        t0 = time.time()
        gr = self.gr
        ub, wb = self.bg(gr.xc, gr.zc)
        if st['x'].size:
            vu, vw, _ = self.sim.eval(gr.gxc, gr.gzc, st['x'], st['z'], st['G'], st['A'] * st['b'])
            vu, vw = cp.asnumpy(vu), cp.asnumpy(vw)
        else:
            vu = vw = 0.0
        rhs = -((ub + vu) * gr.p.nx + (wb + vw) * gr.p.nz)
        sg = gr.Minv @ rhs
        self.t_solve += time.time() - t0
        return sg

    def velocity(self, st, x, z, sigma=None, particles=True, bg=True, baro=False):
        """(u, w[, dbdx]) в точках x, z (cupy) от фона, панелей и частиц состояния st."""
        if sigma is None:
            sigma = self.solve_sigma(st)
        pu, pw = self.gr.panel_vel(sigma, x, z)
        u, w = pu, pw
        if bg:
            ub, wb = self.bgc(x, z)
            u = u + ub; w = w + wb
        dbdx = None
        if particles and st['x'].size:
            vu, vw, dbdx = self.sim.eval(x, z, st['x'], st['z'], st['G'], st['A'] * st['b'])
            u = u + vu; w = w + vw
        return (u, w, dbdx) if baro else (u, w)

    def _vel_particles(self, st, x, z, baro, fresh):
        t0 = time.time()
        if fresh or self._sig is None:
            s2 = dict(st); s2['x'], s2['z'] = x, z
            self._sig = self.solve_sigma(s2)
        pu, pw = self.gr.panel_vel(self._sig, x, z)
        ub, wb = self.bgc(x, z)
        vu, vw, g = self.sim.eval(x, z, x, z, st['G'], st['A'] * st['b'])
        self.t_vel += time.time() - t0
        return ub + pu + vu, wb + pw + vw, (g if baro else 0 * g)

    def _ground_fix(self, st):
        x, z = st['x'], st['z']
        if not x.size:
            return
        gz = cp.asarray(self.gr.p.ground(cp.asnumpy(x)))
        under = z < gz
        nu = int(under.sum())
        if nu == 0:
            return
        self.n_under += nu
        if self.mode == 'reflect':
            st['z'] = cp.where(under, 2 * gz - z, z)
        else:
            self.lost_G += float(st['G'][under].sum())
            self.n_deleted += nu
            keep = ~under
            for k in ('x', 'z', 'G', 'A', 'b'):
                st[k] = st[k][keep]

    def step(self, st, dt, baro=True):
        """Heun. σ пересчитывается на первом и втором вычислении каждого resolve_every-го шага."""
        fresh = (self._cnt % self.k == 0)
        self._cnt += 1
        x, z, G, A = st['x'], st['z'], st['G'], st['A']
        u1, w1, g1 = self._vel_particles(st, x, z, baro, fresh)
        dG1 = A * g1
        xp, zp, Gp = x + dt * u1, z + dt * w1, G + dt * dG1
        sp = dict(st); sp['G'] = Gp
        u2, w2, g2 = self._vel_particles(sp, xp, zp, baro, fresh)
        dG2 = A * g2
        st['x'] = x + 0.5 * dt * (u1 + u2)
        st['z'] = z + 0.5 * dt * (w1 + w2)
        st['G'] = G + 0.5 * dt * (dG1 + dG2)
        self._ground_fix(st)
        if self.x_max is not None and st['x'].size:
            far = (st['x'] > self.x_max) | (st['x'] < -self.x_max)
            if bool(far.any()):
                self.lost_G += float(st['G'][far].sum())
                keep = ~far
                for k in ('x', 'z', 'G', 'A', 'b'):
                    st[k] = st[k][keep]
        self.t += dt
        return u1, w1

    def shed(self, st, xs, zs, dt, core=None):
        """Рождение вихря Γ = −½ |u_s|² dt в точках (xs, zs) (как panels2d.step), A = core², b = 0."""
        xs = np.atleast_1d(np.asarray(xs, float)); zs = np.atleast_1d(np.asarray(zs, float))
        sg = self.solve_sigma(st)
        u, w = self.velocity(st, cp.asarray(xs), cp.asarray(zs), sigma=sg)
        sp2 = cp.asnumpy(u) ** 2 + cp.asnumpy(w) ** 2
        g = -0.5 * sp2 * dt
        self.born_G += float(g.sum())
        n = xs.size
        st['x'] = cp.concatenate([st['x'], cp.asarray(xs)]); st['z'] = cp.concatenate([st['z'], cp.asarray(zs)])
        st['G'] = cp.concatenate([st['G'], cp.asarray(g)])
        st['A'] = cp.concatenate([st['A'], cp.full(n, self.core ** 2)])
        st['b'] = cp.concatenate([st['b'], cp.zeros(n)])


def empty_state():
    z = cp.zeros(0)
    return dict(x=z.copy(), z=z.copy(), G=z.copy(), A=z.copy(), b=z.copy())


def patch_state(xc, zc, R, dtheta, N, sig_fac=1.5, pad_sig=3.5):
    b0 = G0 * dtheta / TH0
    h0 = R * np.sqrt(2 * np.pi / (np.sqrt(3) * N))
    sig = sig_fac * h0
    lx, lz, A, h, inside = disk_lattice(R, N, pad=pad_sig * sig)
    st = dict(x=cp.asarray(xc + lx), z=cp.asarray(zc + lz), G=cp.zeros(lx.size), A=cp.full(lx.size, A),
              b=cp.asarray(np.where(inside, b0, 0.0)))
    return st, dict(b0=b0, sigma=sig, h=h, inside=cp.asarray(inside), B=float(inside.sum() * A * b0), pad=pad_sig * sig)
