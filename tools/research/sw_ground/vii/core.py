"""VII (SWG-10): панели 3D (невязкое, однородный набегающий поток U_∞) + интегральный слой (vii.bl) на профилях вдоль
ветра, связь зарядами вытеснения σ_d: A σ_d = q, q = d(U_e·δ*)/ds (Lighthill 1958) — новая правая часть той же
матрицы и LU (wake.core.solve_rhs, wake_panels — импорт). Прямая связь на присоединённом слое, полуобратная Carter в
отрыве: δ*_{k+1} = δ*_k·[1 + ω(U_e,visc/U_e,inv − 1)], ω = 0,5; на прямом участке δ*_{k+1} = δ*_k + ω(δ*_слоя − δ*_k).
Сходимость — max|Δδ*|/δ* < 1e-3 по всем узлам профилей; несошедшиеся — счётчиком.

Скорость у земли: u(z) = |U_o(x, y, z)|·f(z), f — профиль слоя (bl.profile) по (a, λ) в точке, U_o — невязкое поле
(однородный поток + панели + вдув) на высоте точки; выше δ f = 1. s — модуль, знак f — знак u∥.
"""
from __future__ import annotations

import math

import numpy as np
from scipy.interpolate import LinearNDInterpolator, RegularGridInterpolator
from scipy.ndimage import gaussian_filter1d
from scipy.spatial import Delaunay

from ground import model as M  # noqa: F401  (патчи panels3d: lu overwrite_a, assemble в потоках; не менять)
import core as C  # noqa: E402  (compare/core.py: U10, Z_SAT)
from panels3d import influence as _inf
from panels3d import solve
from panels3d.jh import _line_profile
from panels3d.terrain import bg_uniform, wind_of
from wake.core import solve_rhs, wake_panels

from . import bl

STEP = 12.5           # шаг вдоль профиля, м (как WakeGrid SWG-4)
DC = 25.0             # шаг поперёк, м (как WakeGrid SWG-4: ds_min)
UE_SMOOTH = 25.0      # σ сглаживания U_e вдоль профиля, м (= ds_min основного набора; шум интерполяции центров панелей)
TOL = 1e-3            # max|Δδ*|/δ*
K_MAX = 60            # предел глобальных итераций
OMEGA_RUN = 0.2       # релаксация Carter в расчёте: 0,5 (Davis & Carter 1986) на Perdigão расходится (проверено, README)
D_SMOOTH = 50.0       # σ сглаживания δ* вдоль профиля после каждой поправки, м (стабилизатор; меняет неподвижную точку —
                      # смещение оценено на Аньези, README; сглаживание только поправки ΔD расходится — проверено)
RATIO_LIM = 0.5       # ограничение U_visc/U_inv в поправке Carter за итерацию ([0,5; 1,5]; допущение — шаг итераций)


def panel_velocity_mt(panels, sigma, P, backend, self_idx=None):
    """panel_velocity (SWD2) — на NumPy блоками строк в потоках (NumPy отпускает GIL; общая GPU бывает занята), на
    CuPy — оригинал. Копия логики influence.panel_velocity, оригинал не менялся."""
    if backend != "numpy":
        return _inf.panel_velocity(panels, sigma, P, backend, self_idx)
    from concurrent.futures import ThreadPoolExecutor
    g = _inf._geom(panels, np)
    P = np.atleast_2d(np.asarray(P, float))
    sg = np.asarray(sigma)
    out = np.empty((P.shape[0], 3))
    step = _inf._rows(np, P.shape[0], panels.N)

    def work(i):
        sl = slice(i, min(P.shape[0], i + step))
        si = None
        if self_idx is not None:
            si = np.asarray(self_idx[sl])[:, None] == np.arange(panels.N)[None]
        V = _inf._influence(np, P[sl], g, slice(None), si)
        out[sl] = np.einsum("mkc,k->mc", V, sg)
    with ThreadPoolExecutor(M.CPU_THREADS) as ex:
        list(ex.map(work, range(0, P.shape[0], step)))
    return out


def tangent_velocity_mt(panels, sigma, bg, backend):
    c = panels.c
    u, v, w = bg(c[:, 0], c[:, 1], c[:, 2])
    pv = panel_velocity_mt(panels, sigma, c, backend, self_idx=np.arange(panels.N))
    U = np.stack([np.asarray(u, float), np.asarray(v, float), np.asarray(w, float)], 1) + pv
    return U - (U * panels.n).sum(1)[:, None] * panels.n


def u_inf(z0, z_top=None):
    """U_∞ = bg_log на верху слоя (по умолчанию Z_SAT; выше — постоянный фон)."""
    z_top = C.Z_SAT if z_top is None else z_top
    return C.U10 * math.log(z_top / z0) / math.log(10.0 / z0)


class Strips:
    """Профили вдоль ветра (поперёк dc, вдоль step) по рельефу панелей; s — длина дуги по поверхности."""

    def __init__(self, terrain, wind_to, step=STEP, dc=DC):
        w = np.asarray(wind_to, float)
        self.ex, self.ey = w / np.hypot(w[0], w[1])
        self.px, self.py = -self.ey, self.ex
        self.cx, self.cy = float(terrain.cx), float(terrain.cy)
        self.step, self.dc = float(step), float(dc)
        R = 0.5 * float(np.hypot(terrain.x[-1] - terrain.x[0], terrain.y[-1] - terrain.y[0]))
        K = int(np.ceil(R / self.step)) + 2
        self.K = K
        self.svals = self.step * np.arange(-K, K + 1)
        nc = int(np.ceil(R / self.dc)) + 1
        self.cvals = self.dc * np.arange(-nc, nc + 1)
        nl, ns = self.cvals.size, self.svals.size
        self.valid = np.zeros((nl, ns), bool)
        self.zs = np.full((nl, ns), np.nan)
        for ic, c in enumerate(self.cvals):
            x0, y0 = self.cx + c * self.px, self.cy + c * self.py
            s, z = _line_profile(terrain, x0, y0, self.ex, self.ey, self.step)
            if s.size < 10:
                continue
            k = np.rint(s / self.step).astype(int) + K
            self.valid[ic, k] = True
            self.zs[ic, k] = z
        C_, S_ = np.meshgrid(self.cvals, self.svals, indexing="ij")
        self.X = self.cx + C_ * self.px + S_ * self.ex
        self.Y = self.cy + C_ * self.py + S_ * self.ey
        dz = np.diff(np.nan_to_num(self.zs), axis=1)
        darc = np.sqrt(self.step ** 2 + dz ** 2)
        self.arc = np.concatenate([np.zeros((nl, 1)), np.cumsum(darc, 1)], 1)
        self.cosb = np.full((nl, ns), 1.0)
        g = np.gradient(np.nan_to_num(self.zs), self.step, axis=1)
        self.cosb = 1.0 / np.sqrt(1.0 + g * g)

    def rot(self, x, y):
        x = np.asarray(x, float) - self.cx
        y = np.asarray(y, float) - self.cy
        return x * self.px + y * self.py, x * self.ex + y * self.ey

    def extend(self, F):
        """Поле на профилях с продолжением за растр постоянным вдоль профиля (краевых источников нет); пустые
        профили — ближайшим непустым."""
        G = np.array(F, float, copy=True)
        for i in range(G.shape[0]):
            v = np.nonzero(self.valid[i])[0]
            if v.size == 0:
                continue
            G[i, :v[0]] = G[i, v[0]]
            G[i, v[-1] + 1:] = G[i, v[-1]]
        rows = np.nonzero(self.valid.any(1))[0]
        for i in range(G.shape[0]):
            if not self.valid[i].any():
                G[i] = G[rows[np.argmin(np.abs(rows - i))]]
        return G

    def interp(self, F, x, y):
        """Билинейная интерполяция поля (n_l, n_s) (уже продолженного) в точки; за краями решётки — край."""
        c, a = self.rot(x, y)
        c = np.clip(np.ravel(c), self.cvals[0], self.cvals[-1])
        a = np.clip(np.ravel(a), self.svals[0], self.svals[-1])
        it = RegularGridInterpolator((self.cvals, self.svals), F, bounds_error=False, fill_value=None)
        return it(np.stack([c, a], 1)).reshape(np.shape(x))


class _MGrid:
    """Обёртка под wake.core.wake_panels: dstar(x, y) → m = U_e·δ*, ddstar — dm/ds по ветру (горизонтально)."""

    def __init__(self, strips, Mfield):
        self.st, self.M = strips, strips.extend(Mfield)
        self.ex, self.ey, self.step = strips.ex, strips.ey, strips.step

    def dstar(self, x, y):
        return self.st.interp(self.M, x, y)

    def ddstar(self, x, y):
        h = self.step
        x = np.asarray(x, float)
        y = np.asarray(y, float)
        return (self.dstar(x + h * self.ex, y + h * self.ey) - self.dstar(x - h * self.ex, y - h * self.ey)) / (2 * h)


def sigma_d(run, strips, Mfield):
    """σ_d: A σ_d = q, q = cos β·dm/ds_h на панелях внутри растра (вне — m постоянна вдоль ветра, q = 0)."""
    panels, infl = run.panels, run.infl
    g = _MGrid(strips, Mfield)
    sub, d, dd, cosb = wake_panels(panels, g)
    t = panels.terrain
    c = panels.c[sub]
    inside = (c[:, 0] >= t.x[0]) & (c[:, 0] <= t.x[-1]) & (c[:, 1] >= t.y[0]) & (c[:, 1] <= t.y[-1])
    b = np.zeros(panels.N)
    b[sub[inside]] = (cosb * dd)[inside]
    return solve_rhs(infl, b), b


class VII:
    """Связь панелей и слоя на сетке run (GRun) и профилях strips. U_∞ = bg_log(Z_SAT); σ_u — решение однородного
    потока 1 м/с (в масштабе U_∞)."""

    def __init__(self, run, strips=None, z0=None, delta0=None, omega=OMEGA_RUN, htmax=bl.HTMAX, log=None, need_ue=True, d_smooth=D_SMOOTH):
        self.run = run
        self.panels, self.infl = run.panels, run.infl
        self.z0 = float(run.z0 if z0 is None else z0)
        self.delta0 = float(C.Z_SAT if delta0 is None else delta0)
        self.U_inf = u_inf(self.z0, self.delta0)
        ex, ey = wind_of(run.bg, self.panels.terrain)
        self.e = (ex, ey)
        self.bgu = bg_uniform(self.U_inf, (ex, ey))
        self.sig_u = solve(self.panels, self.bgu, None, self.infl)[0]
        self.strips = strips if strips is not None else Strips(self.panels.terrain, (ex, ey))
        self.eq = bl.Equilibrium(self.z0, self.delta0, self.U_inf)
        self.omega, self.htmax, self.d_smooth = omega, htmax, float(d_smooth)
        self.log = log or (lambda *a: None)
        self._T = None
        if need_ue:
            self.tri = Delaunay(self.panels.c[:, :2])
        if need_ue and self.infl.backend == "numpy":
            _, rows = self._tmatrix()
            self.tri_rows = Delaunay(self.panels.c[rows, :2])
        lam_tab = np.linspace(bl.LAM_MIN, bl.LAM_MAX, 400)
        lo, hi = bl.a_limits(lam_tab)
        self.alim = (lam_tab, lo, hi)
        self.sig_d = np.zeros(self.panels.N)

    def _tmatrix(self):
        """Матрица касательных скоростей от единичных σ в центрах панелей внутри растра (+ 2 шага по краю):
        float32 (3·n_rows, N), без собственного телесного угла (как tangent_velocity). Строится один раз: каждая
        итерация — одно умножение вместо N² интегралов (CPU под замком — одно ядро)."""
        if getattr(self, "_T", None) is not None:
            return self._T, self._rows_idx
        p = self.panels
        t = p.terrain
        c = p.c
        mg = 2 * self.strips.step + float(np.max(p.ds))
        rows = np.nonzero((c[:, 0] >= t.x[0] - mg) & (c[:, 0] <= t.x[-1] + mg) & (c[:, 1] >= t.y[0] - mg)
                          & (c[:, 1] <= t.y[-1] + mg))[0]
        g = _inf._geom(p, np)
        n = p.n[rows]
        T = np.empty((rows.size, 3, p.N), np.float32)
        step = _inf._rows(np, rows.size, p.N)
        from concurrent.futures import ThreadPoolExecutor

        def work(i):
            sl = slice(i, min(rows.size, i + step))
            ri = rows[sl]
            si = ri[:, None] == np.arange(p.N)[None]
            V = _inf._influence(np, c[ri], g, slice(None), si)            # (m, N, 3)
            Vn = np.einsum("mkc,mc->mk", V, n[sl])
            Vt = V - Vn[..., None] * n[sl][:, None, :]
            T[sl] = np.transpose(Vt, (0, 2, 1)).astype(np.float32)
        with ThreadPoolExecutor(M.CPU_THREADS) as ex:
            list(ex.map(work, range(0, rows.size, step)))
        self._T = T.reshape(rows.size * 3, p.N)
        self._rows_idx = rows
        return self._T, rows

    def surface_ue(self, sig_d):
        """|касательная скорость| невязкого (U_∞ + σ_u + σ_d) в центрах панелей → на узлы профилей, сглажено."""
        if self.infl.backend == "numpy":
            T, rows = self._tmatrix()
            p = self.panels
            c = p.c[rows]
            u, v, w = self.bgu(c[:, 0], c[:, 1], c[:, 2])
            B = np.stack([np.asarray(u, float), np.asarray(v, float), np.asarray(w, float)], 1)
            B = B - (B * p.n[rows]).sum(1)[:, None] * p.n[rows]
            Ut = B + (T @ (self.sig_u + sig_d).astype(np.float32)).reshape(rows.size, 3)
            ue = np.linalg.norm(Ut, axis=1)
            tri = self.tri_rows
        else:
            Ut = tangent_velocity_mt(self.panels, self.sig_u + sig_d, self.bgu, self.infl.backend)
            ue = np.linalg.norm(Ut, axis=1)
            tri = self.tri
        st = self.strips
        f = LinearNDInterpolator(tri, ue)
        U = f(st.X.ravel(), st.Y.ravel()).reshape(st.X.shape)
        U = np.where(st.valid & np.isfinite(U), U, np.nan)
        Us = np.full_like(U, np.nan)
        for i in range(U.shape[0]):
            v = np.nonzero(st.valid[i] & np.isfinite(U[i]))[0]
            if v.size < 5:
                continue
            Us[i, v] = gaussian_filter1d(U[i, v], UE_SMOOTH / st.step, mode="nearest")
        dU = np.full_like(U, np.nan)
        for i in range(U.shape[0]):
            v = np.nonzero(np.isfinite(Us[i]))[0]
            if v.size < 5:
                continue
            dU[i, v] = np.gradient(Us[i, v], st.arc[i, v])
        ok = np.isfinite(Us) & np.isfinite(dU)
        return Us, dU, ok

    def run_layer(self, coupled=True, k_max=K_MAX, tol=TOL):
        """Глобальные итерации. coupled=False — слой по невязкому без вдува (одна прогонка). → dict."""
        st = self.strips
        sig_d = np.zeros(self.panels.N)
        D = None
        inv = None
        hist = []
        r = None
        prev = (None, None)
        for k in range(k_max if coupled else 1):
            Ui, dUi, ok = self.surface_ue(sig_d)
            r = bl.march(st.arc, np.nan_to_num(Ui), np.nan_to_num(dUi), ok, self.eq, D, inv, self.htmax, self.alim)
            ds_l = r["dstar"]
            if D is None:
                Dn = ds_l.copy()
            else:
                ratio = np.clip(r["U"] / np.maximum(Ui, 1e-9), 1 - RATIO_LIM, 1 + RATIO_LIM)
                carter = ds_l * (1 + self.omega * (ratio - 1))
                direct = D + self.omega * (ds_l - D)
                Dn = np.where(r["mode"] >= 1, carter, direct)
                Dn = np.where(np.isfinite(Dn), Dn, ds_l)
            Dn = np.maximum(Dn, 1e-3 * self.eq.dstar0)
            if self.d_smooth > 0:
                Dn = self._smooth(Dn, ok)
            okm = ok & np.isfinite(Dn)
            if D is None:
                dmax = np.inf
                nbad = int(okm.sum())
                nbad_inv, p95 = 0, None
            else:
                rel = np.abs(Dn - D) / np.maximum(np.abs(D), 1e-9)
                rel = np.where(okm & np.isfinite(D), rel, 0.0)
                dmax = float(rel.max())
                nbad = int((rel > tol).sum())
                nbad_inv = int(((rel > tol) & (r["mode"] >= 1)).sum())
                p95 = float(np.percentile(rel[okm], 95))
            inv_new = (r["mode"] >= 1) | (np.nan_to_num(r["H"]) > self.htmax)
            inv = inv_new if inv is None else (inv | inv_new)
            Mf = np.where(okm, Ui * Dn, np.nan)
            Mf = self._fill(Mf)
            hist.append(dict(k=k, dmax=dmax if np.isfinite(dmax) else None, n_bad=nbad, n_bad_inv=nbad_inv, p95=p95, n_inv=int((r["mode"] >= 1).sum()),
                             n_sep=int((np.nan_to_num(r["cf"], nan=1.0) <= 0).sum()), n_nodes=int(okm.sum()),
                             H_max=float(np.nanmax(r["H"])), n_fallback=int(r["n_fallback"]),
                             n_delta_cap=int((np.nan_to_num(r["lam"]) >= self.eq.lam0 + math.log(bl.DELTA_UP) - 1e-9).sum())))
            self.log(f"  итерация {k}: max|Δδ*|/δ* {dmax:.2e}, узлов > tol {nbad}, обратных {hist[-1]['n_inv']}, "
                     f"C_f ≤ 0 {hist[-1]['n_sep']}, H_max {hist[-1]['H_max']:.2f}, отказов {hist[-1]['n_fallback']}, "
                     f"δ на пределе {hist[-1]['n_delta_cap']}, > tol в обратной зоне {nbad_inv}, p95 {p95}")
            prev = (self.layer if hasattr(self, "layer") and k > 0 else None, getattr(self, "Mf", None) if k > 0 else None)
            self.layer, self.Mf = r, Mf
            D = Dn
            if not coupled:
                break
            if dmax < tol:
                break
            sig_d, _ = sigma_d(self.run, st, Mf)
        self.sig_d = sig_d if coupled else np.zeros(self.panels.N)
        self.layer = r
        self.prev_layer, self.prev_Mf = prev
        self.D = D
        self.Ui = Ui
        self.Mf = Mf
        self.hist = hist
        return dict(layer=r, D=D, Ui=Ui, hist=hist, converged=bool(hist[-1]["dmax"] is not None and hist[-1]["dmax"] < tol) if coupled else None)

    def _smooth(self, F, ok):
        """Гауссово сглаживание поля вдоль профиля (σ = d_smooth) по узлам ok: стабилизатор итераций Carter на Perdigão
        (шаг 12,5 м ≪ δ*); неподвижная точка — уже со сглаженной δ*."""
        G = F.copy()
        for i in range(F.shape[0]):
            v = np.nonzero(ok[i] & np.isfinite(F[i]))[0]
            if v.size >= 5:
                G[i, v] = gaussian_filter1d(F[i, v], self.d_smooth / self.strips.step, mode="nearest")
        return G

    def _fill(self, Mf):
        """Пропуски m (вне растра/без U_e) вдоль профиля — ближайшим значением (для продолжения)."""
        G = Mf.copy()
        for i in range(G.shape[0]):
            v = np.nonzero(np.isfinite(G[i]))[0]
            if v.size == 0:
                continue
            G[i] = np.interp(np.arange(G.shape[1]), v, G[i, v])
        rows = np.nonzero(np.isfinite(G).all(1))[0]
        for i in range(G.shape[0]):
            if not np.isfinite(G[i]).all() and rows.size:
                G[i] = G[rows[np.argmin(np.abs(rows - i))]]
        return G


class LayerField:
    """Состояние слоя (a, λ, θ, H, δ*, C_f, режим) на профилях → в точки (билинейно; вне растра — край)."""

    def __init__(self, strips, layer, z0, Mf=None):
        self.st = strips
        self.z0 = float(z0)
        self.F = {}
        for k in ("a", "lam", "theta", "dstar", "H", "cf", "delta"):
            v = np.where(strips.valid & np.isfinite(layer[k]), layer[k], np.nan)
            self.F[k] = strips.extend(_fill_rows(v, strips))
        mode = np.where(strips.valid, layer["mode"], 0).astype(float)
        self.F["inv"] = strips.extend((mode >= 1).astype(float))
        self.Mf = Mf

    def at(self, x, y):
        return {k: self.st.interp(F, x, y) for k, F in self.F.items()}


def _fill_rows(v, strips):
    G = v.copy()
    for i in range(G.shape[0]):
        f = np.nonzero(np.isfinite(G[i]))[0]
        if f.size == 0:
            G[i] = np.nan
            continue
        G[i] = np.interp(np.arange(G.shape[1]), f, G[i, f])
    rows = np.nonzero(np.isfinite(G).all(1))[0]
    for i in range(G.shape[0]):
        if not np.isfinite(G[i]).all():
            G[i] = G[rows[np.argmin(np.abs(rows - i))]]
    return G


def vii_parts(run, x, y, z, sig_d=None, lf=None, sig_u=None, U_inf=None, z0=None):
    """Скорость в точках (абсолютные z). lf = None — слой выключен: поле = potential (панели run.sigma + лог-фон
    run.bg) + вдув σ_d (при σ_d = 0 — побитно potential). lf задан — VII: |U_o|·f, U_o = U_∞ + σ_u + σ_d (σ_u — решение
    однородного потока с U_∞). → dict: u, v, w, speed, upar_sign, outer_speed, f, outer0_speed (без вдува), ok."""
    panels, infl = run.panels, run.infl
    be = infl.backend
    x = np.asarray(x, float).ravel()
    y = np.asarray(y, float).ravel()
    z = np.asarray(z, float).ravel()
    P = np.stack([x, y, z], 1)
    if lf is None:
        u, v, w = _inf.velocity(panels, run.sigma, run.bg, x, y, z, None, be)
        if sig_d is not None:
            ok = np.isfinite(u)
            pw = _inf.panel_velocity(panels, sig_d, np.stack([x, y, np.where(ok, z, panels.height(x, y) + 1)], 1), be)
            u, v, w = u + pw[:, 0], v + pw[:, 1], w + pw[:, 2]
        return dict(u=u, v=v, w=w, speed=np.hypot(u, v), ok=np.isfinite(u))
    ex, ey = wind_of(run.bg, panels.terrain)
    bgu = bg_uniform(U_inf, (ex, ey))
    u0, v0, w0 = _inf.velocity(panels, sig_u, bgu, x, y, z, None, be)
    ok = np.isfinite(u0)
    if sig_d is not None:
        pw = _inf.panel_velocity(panels, sig_d, np.stack([x, y, np.where(ok, z, panels.height(x, y) + 1)], 1), be)
    else:
        pw = np.zeros((x.size, 3))
    uo, vo, wo = u0 + pw[:, 0], v0 + pw[:, 1], w0 + pw[:, 2]
    st = lf.at(x, y)
    zagl = z - panels.height(x, y)
    f = bl.profile(np.maximum(zagl, 0.0), st["a"], st["lam"], lf.z0)
    sp = np.hypot(uo, vo)
    return dict(u=uo * f, v=vo * f, w=wo * f, speed=sp * np.abs(f), upar_sign=np.sign(f), outer_speed=sp,
                outer0_speed=np.hypot(u0, v0), f=f, ok=ok, layer=st, zagl=zagl)
