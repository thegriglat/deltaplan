"""Опыт 4: установившееся поле автомата проходами по слоям с матрицами перехода.

Идея. Установившееся состояние автомата — решение стационарных уравнений той же дискретизации
(MAC-сетка, те же операторы, что в model.HeatCA._step_impl, только без времени):

    импульс:      0 = −(u·∇)u + ν∇²u − ∇p + b·ẑ − губка          (b = g·θ′/θ0)
    масса:        0 = ∇·u
    тепло:        0 = −∇·(u θ) + κ∇²θ′ + нагрев − θ′/τ − губка

Её линейная часть относительно покоя (вязкость, давление, плавучесть, перенос фона θ̄(z),
теплопроводность, выхолаживание, губки) на прямоугольнике не зависит от x → по горизонтали
раскладывается на гармоники (косинусы для p, θ′, w; синусы для u — стенки), и для каждой гармоники
остаётся задача по высоте: блочно-трёхдиагональная система 4×4 (u, p, θ′, w в слое).
Она решается РОВНО ДВУМЯ проходами (блочная прогонка):
  * проход вверх: y_k = g_k − E_k·y_{k+1}, где g_k = D_k⁻¹(r_k − A_k g_{k−1}) — «состояние слоя k
    из слоя k−1» через матрицы перехода D_k⁻¹, A_k (4×4 на гармонику, считаются один раз);
  * проход вниз: y_k = g_k − E_k y_{k+1} — ответ сверху возвращается к земле.
Проход вверх несёт от земли плавучесть и накопленный поток массы, проход вниз замыкает
циркуляцию (возврат под потолком, опускание, приток у земли).

Нелинейность (перенос ветром) и рельеф (лесенка клеток, прилипание) в линейную часть не входят —
их доделывают повторы «невязка → два прохода» с ускорением Андерсона (линейная комбинация прошлых
повторов, как GMRES). Цель — мало повторов.

Массивы [k, i]; xp — numpy или cupy.
"""
from __future__ import annotations

import math

import numpy as np

from model import HeatCA, G, THETA0


class SteadyOp:
    """Стационарная невязка автомата F(x) и двухпроходный линейный решатель P⁻¹."""

    def __init__(self, sc, pr, xp=np, dtype=np.float64):
        self.m = HeatCA(sc, pr)
        m = self.m
        self.xp = xp
        self.dtype = dtype
        self.nz, self.nx, self.d = m.nz, m.nx, m.dx
        nz, nx, d = self.nz, self.nx, self.d
        to = lambda a: xp.asarray(m.to_np(a) if not isinstance(a, np.ndarray) else a, dtype)
        self.fluidf = to(m.fluid_np.astype(float)) if hasattr(m, "fluid_np") else to((~m.solid_np).astype(float))
        self.uxf = to(m.ux_open_np.astype(float))
        self.wzf = to(m.wz_open_np.astype(float))
        self.tb = to(np.repeat(m.theta_bar_np[:, None], nx, 1))
        self.tbc = to(m.theta_bar_np)
        self.ubg = to(np.repeat(m.ubg_np[:, None], nx + 1, 1))
        self.sp_u, self.sp_w = to(m.sp_u), to(m.sp_w)
        self.sp_c = to(m.sp_c) if m.sp_c is not None else None
        self.heat = to(m.heat_src)
        self.wind = m.sc.wind_ms > 0
        self.nu, self.kappa, self.tau = pr.nu, pr.kappa, pr.tau_cool
        self.beta = G / THETA0
        # диагональ «твёрдых» строк — в масштабе строк воздуха (чтобы проходы их не путали)
        self.cu = 4 * self.nu / d**2
        self.ct = 4 * self.kappa / d**2
        self.cp_ = 1.0 / self.nu
        # веса компонент в норме (давление ~ b·H ≫ скоростей)
        self.p_scale = 30.0
        self.nl = 1.0
        self.nlm = 1.0
        self.u0 = to(m.u)          # старт: фон (с ветром — уже обтекает хребет)
        self._build_precond()

    # ------------------------------------------------------------------ состояние
    def shapes(self):
        nz, nx = self.nz, self.nx
        return [(nz, nx + 1), (nz + 1, nx), (nz, nx), (nz, nx)]

    def pack(self, u, w, p, t):
        xp = self.xp
        return xp.concatenate([u.ravel(), w.ravel(), (p / self.p_scale).ravel(), t.ravel()])

    def unpack(self, x):
        out, o = [], 0
        for s in self.shapes():
            n = s[0] * s[1]
            out.append(x[o:o + n].reshape(s))
            o += n
        out[2] = out[2] * self.p_scale
        return out

    def x0(self):
        xp = self.xp
        nz, nx = self.nz, self.nx
        return self.pack(self.u0.copy(), xp.zeros((nz + 1, nx), self.dtype), xp.zeros((nz, nx), self.dtype),
                         xp.zeros((nz, nx), self.dtype))

    # ------------------------------------------------------------------ невязка
    def _lap(self, f):
        xp, d = self.xp, self.d
        fp = xp.pad(f, 1, mode="edge")
        fp[0, :] = 0
        return (fp[1:-1, 2:] + fp[1:-1, :-2] + fp[2:, 1:-1] + fp[:-2, 1:-1] - 4 * f) / d**2

    def _adv(self, f, a, c):
        """(a ∂x + c ∂z) f «откуда дует» (1-й порядок; = полулагранжев перенос при малом шаге)."""
        xp, d = self.xp, self.d
        fp = xp.pad(f, 1, mode="edge")
        dxm = (f - fp[1:-1, :-2]) / d
        dxp = (fp[1:-1, 2:] - f) / d
        dzm = (f - fp[:-2, 1:-1]) / d
        dzp = (fp[2:, 1:-1] - f) / d
        return xp.where(a > 0, a * dxm, a * dxp) + xp.where(c > 0, c * dzm, c * dzp)

    def residual(self, x, parts=False):
        xp, d = self.xp, self.d
        u, w, p, t = self.unpack(x)
        fl = self.fluidf
        thp = t * fl
        th = self.nl * thp + self.tb          # nl = 0 — опыт: без переноса θ′ ветром
        # --- импульс
        wp = xp.pad(w, ((0, 0), (1, 1)), mode="edge")
        w_at_u = 0.25 * (wp[:-1, :-1] + wp[:-1, 1:] + wp[1:, :-1] + wp[1:, 1:])
        up = xp.pad(u, ((1, 1), (0, 0)), mode="edge")
        u_at_w = 0.25 * (up[:-1, :-1] + up[:-1, 1:] + up[1:, :-1] + up[1:, 1:])
        gx = xp.zeros_like(u)
        gx[:, 1:-1] = (p[:, 1:] - p[:, :-1]) / d
        gz = xp.zeros_like(w)
        gz[1:-1] = (p[1:] - p[:-1]) / d
        b = xp.zeros_like(w)
        b[1:-1] = self.beta * 0.5 * (thp[1:] + thp[:-1])
        Ru = (-self.nlm * self._adv(u, u, w_at_u) + self.nu * self._lap(u - self.ubg * self.uxf)
              - self.sp_u * (u - self.ubg) - gx)
        Rw = -self.nlm * self._adv(w, u_at_w, w) + self.nu * self._lap(w) + b - self.sp_w * w - gz
        # закрытые грани/твёрдые клетки: значение держим нулём вне проходов (см. sweeps)
        Ru = Ru * self.uxf
        Rw = Rw * self.wzf
        if self.wind:
            # приток слева задан, справа — «сносовый» выход, подогнанный под приток (как у автомата)
            Ru[:, 0] = self.cu * (self.ubg[:, 0] - u[:, 0]) * self.uxf[:, 0]
            out = xp.maximum(u[:, -2], 0.0) * self.uxf[:, -1]
            tgt = out * (xp.sum(self.ubg[:, 0] * self.uxf[:, 0]) / xp.maximum(xp.sum(out), 1e-6))
            Ru[:, -1] = self.cu * (tgt - u[:, -1]) * self.uxf[:, -1]
        # --- масса
        div = ((u[:, 1:] - u[:, :-1]) + (w[1:] - w[:-1])) / d
        Rp = -div * fl
        # --- тепло (как у автомата: поток «откуда дует» + теплопроводность по θ′ на открытых гранях)
        tbc = self.tbc[:, None]
        thx = xp.empty_like(u)
        thx[:, 1:-1] = xp.where(u[:, 1:-1] > 0, th[:, :-1], th[:, 1:])
        thx[:, :1] = xp.where(u[:, :1] > 0, tbc, th[:, :1])
        thx[:, -1:] = xp.where(u[:, -1:] > 0, th[:, -1:], tbc)
        thz = xp.zeros_like(w)
        thz[1:-1] = xp.where(w[1:-1] > 0, th[:-1], th[1:])
        Fx = u * thx
        Fz = w * thz
        Fx[:, 1:-1] -= self.kappa * (thp[:, 1:] - thp[:, :-1]) / d * self.uxf[:, 1:-1]
        Fz[1:-1] -= self.kappa * (thp[1:] - thp[:-1]) / d * self.wzf[1:-1]
        Rt = -((Fx[:, 1:] - Fx[:, :-1]) + (Fz[1:] - Fz[:-1])) / d + self.heat - thp / self.tau
        if self.sp_c is not None:
            Rt = Rt - self.sp_c * thp
        Rt = Rt * fl
        if parts:
            return Ru, Rw, Rp, Rt
        return xp.concatenate([Ru.ravel(), Rw.ravel(), Rp.ravel(), Rt.ravel()])

    # ------------------------------------------------------------------ двухпроходный решатель
    heat_damp = 0.0   # опыт: добавочное «затухание» тепла в проходах (вместо переноса θ′)

    def _build_precond(self, tb_add=None, basis=None):
        """Матрицы перехода слой→слой для каждой гармоники (float64, один раз на рельеф/фон).

        basis = "dct" (стенки по бокам: косинусы для p, θ′, w и синусы для u — точно для штиля)
              | "fft" (периодические гармоники e^{ikx}; с ветром — туда входит перенос фоновым
                ветром U(z)∂x, иначе проходы его не видят)."""
        nz, nx, d = self.nz, self.nx, self.d
        nu, ka, be = self.nu, self.kappa, self.beta
        m = self.m
        basis = basis or ("fft" if self.wind else "dct")
        self.basis = basis
        i = np.arange(nx)
        if basis == "dct":
            M = nx
            C = np.sqrt(2.0 / nx) * np.cos(np.pi * np.arange(nx)[:, None] * (i[None, :] + 0.5) / nx)
            C[0] /= np.sqrt(2.0)
            S = np.zeros((nx, nx))          # [m, грань 0..nx-1]; m = 0 и грань 0 — пустые
            S[1:, 1:] = np.sqrt(2.0 / nx) * np.sin(np.pi * np.arange(1, nx)[:, None] * i[None, 1:] / nx)
            Tc, Tf, Ic, If = C, S, C.T, S.T
            sig = 2.0 / d * np.sin(np.pi * np.arange(nx) / (2 * nx))
            gm, dv = -sig + 0j, sig + 0j
            am = np.zeros(M, complex)
            cm = np.zeros(M, complex)
        else:
            M = nx // 2 + 1
            kk = 2 * np.pi * np.arange(M) / (nx * d)
            Tc = np.exp(-1j * kk[:, None] * (i[None, :] + 0.5) * d)
            Tf = np.exp(-1j * kk[:, None] * i[None, :] * d)
            wgt = np.full(M, 2.0)
            wgt[0] = 1.0
            if nx % 2 == 0:
                wgt[-1] = 1.0
            Ic = (np.conj(Tc).T * wgt[None, :]) / nx      # вещественная часть берётся после
            If = (np.conj(Tf).T * wgt[None, :]) / nx
            sig = 2.0 / d * np.sin(kk * d / 2)
            gm = 1j * sig
            dv = 1j * sig
            am = (1 - np.exp(-1j * kk * d)) / d
            cm = np.cos(kk * d / 2) + 0j
        self.M = M
        tb = m.theta_bar_np.copy()
        if tb_add is not None:
            tb = tb + tb_add
        tbf = np.zeros(nz + 1)
        tbf[1:-1] = 0.5 * (tb[1:] + tb[:-1])
        spu = m.to_np(m.sp_u).min(axis=1)
        spw = m.to_np(m.sp_w).min(axis=1)
        spc = np.zeros(nz) if m.sp_c is None else m.to_np(m.sp_c).min(axis=1)
        Ub = m.ubg_np if basis == "fft" else np.zeros(nz)
        dUdz = np.gradient(Ub, d) if nz > 1 else np.zeros(nz)
        A = np.zeros((M, nz, 4, 4), complex)
        B = np.zeros((M, nz, 4, 4), complex)
        Cc = np.zeros((M, nz, 4, 4), complex)
        U, P, T, W = 0, 1, 2, 3
        s2 = sig**2
        for k in range(nz):
            # строка u (импульс по x в слое k)
            nbu = (2.0 if k < nz - 1 else 1.0)
            B[:, k, U, U] = -nu * (s2 + nbu / d**2) - spu[k] - Ub[k] * am
            B[:, k, U, P] = -gm
            B[:, k, U, W] = -cm * 0.5 * dUdz[k]
            if k > 0:
                A[:, k, U, U] = nu / d**2
            if k < nz - 1:
                Cc[:, k, U, U] = nu / d**2
                Cc[:, k, U, W] = -cm * 0.5 * dUdz[k]
            # масса
            B[:, k, P, U] = -dv
            B[:, k, P, W] = 1.0 / d
            if k < nz - 1:
                Cc[:, k, P, W] = -1.0 / d
            # m = 0: давление задано до константы; малый «якорь» (float32: без него константа
            # набирает шум ~10³ и съедает точность перепадов давления)
            B[0, k, P, P] = -1e-4 / nu
            # тепло
            nbt = (k > 0) + (k < nz - 1)
            B[:, k, T, T] = -ka * s2 - ka * nbt / d**2 - 1.0 / self.tau - spc[k] - Ub[k] * am - self.heat_damp
            B[:, k, T, U] = -tb[k] * dv
            B[:, k, T, W] = tbf[k] / d
            if k > 0:
                A[:, k, T, T] = ka / d**2
            if k < nz - 1:
                Cc[:, k, T, T] = ka / d**2
                Cc[:, k, T, W] = -tbf[k + 1] / d
            # w на нижней грани слоя k
            if k == 0:
                B[:, k, W, W] = -self.cu
            else:
                Uw = 0.5 * (Ub[k] + Ub[k - 1])
                B[:, k, W, W] = -nu * (s2 + 2.0 / d**2) - spw[k] - Uw * am
                B[:, k, W, T] = be / 2
                B[:, k, W, P] = -1.0 / d
                A[:, k, W, T] = be / 2
                A[:, k, W, P] = 1.0 / d
                if k > 1:
                    A[:, k, W, W] = nu / d**2
                if k < nz - 1:
                    Cc[:, k, W, W] = nu / d**2
        if basis == "dct":           # m = 0: синуса нет — строка u развязана («пустышка»)
            B[0, :, U, P] = 0
            B[0, :, P, U] = 0
            B[0, :, T, U] = 0
        Dinv = np.zeros_like(B)
        E = np.zeros_like(B)
        for k in range(nz):
            Dk = B[:, k] - (A[:, k] @ E[:, k - 1] if k > 0 else 0.0)
            Dinv[:, k] = np.linalg.inv(Dk)
            E[:, k] = Dinv[:, k] @ Cc[:, k]
        self.pA, self.pB, self.pC, self.pDinv, self.pE = A, B, Cc, Dinv, E
        xp = self.xp
        self.cplx = basis == "fft"
        ct = (np.complex64 if self.dtype == np.float32 else np.complex128) if self.cplx else self.dtype
        cast = (lambda a: a) if self.cplx else (lambda a: a.real)
        self.ctype = ct
        self.gA, self.gDinv, self.gE = (xp.asarray(cast(a), ct) for a in (A, Dinv, E))
        self.gTc, self.gTf = xp.asarray(cast(Tc), ct), xp.asarray(cast(Tf), ct)
        self.gIc, self.gIf = xp.asarray(cast(Ic), ct), xp.asarray(cast(If), ct)

    def to_harm(self, r):
        """Невязка → гармоники: [m, k, 4] (u, масса, тепло, w)."""
        xp = self.xp
        Ru, Rw, Rp, Rt = self.unpack_res(r)
        Ruf = Ru[:, :-1]
        if self.wind:
            Ruf = Ruf.copy()
            Ruf[:, 0] = 0
        rhs = xp.empty((self.M, self.nz, 4), self.ctype)
        rhs[:, :, 0] = self.gTf @ Ruf.T
        rhs[:, :, 1] = self.gTc @ Rp.T
        rhs[:, :, 2] = self.gTc @ Rt.T
        rhs[:, :, 3] = self.gTc @ Rw[:-1].T
        return rhs, Ru

    def from_harm(self, y, Ru):
        xp = self.xp
        nz, nx = self.nz, self.nx
        re = (lambda a: a.real) if self.cplx else (lambda a: a)
        du = xp.zeros((nz, nx + 1), self.dtype)
        du[:, :-1] = re(self.gIf @ y[:, :, 0]).T
        dp = re(self.gIc @ y[:, :, 1]).T
        dt = re(self.gIc @ y[:, :, 2]).T
        dw = xp.zeros((nz + 1, nx), self.dtype)
        dw[:-1] = re(self.gIc @ y[:, :, 3]).T
        if self.wind:  # боковые грани — граничные условия (диагональ)
            du[:, 0] = Ru[:, 0] / (-self.cu)
            du[:, -1] = Ru[:, -1] / (-self.cu)
        # закрытые грани и твёрдые клетки: поправку не пускаем (там всегда 0)
        du *= self.uxf
        dw *= self.wzf
        dp *= self.fluidf
        dt *= self.fluidf
        return -self.pack(du, dw, dp, dt)

    def solve_blocks(self, rhs):
        """Два прохода блочной прогонки (numpy/cupy; на GPU — одно ядро, см. gpu.py)."""
        xp = self.xp
        nz = self.nz
        g = xp.empty_like(rhs)
        prev = None
        for k in range(nz):                        # проход вверх
            rk = rhs[:, k]
            if prev is not None:
                rk = rk - xp.einsum("mij,mj->mi", self.gA[:, k], prev)
            prev = xp.einsum("mij,mj->mi", self.gDinv[:, k], rk)
            g[:, k] = prev
        y = xp.empty_like(g)                       # проход вниз
        y[:, nz - 1] = g[:, nz - 1]
        for k in range(nz - 2, -1, -1):
            y[:, k] = g[:, k] - xp.einsum("mij,mj->mi", self.gE[:, k], y[:, k + 1])
        return y

    def sweeps(self, r):
        """Два прохода: r (невязка) → δx = −L⁻¹ r (L — линейная часть без рельефа и переноса θ′)."""
        rhs, Ru = self.to_harm(r)
        return self.from_harm(self.solve_blocks(rhs), Ru)

    def unpack_res(self, r):
        out, o = [], 0
        for s in self.shapes():
            n = s[0] * s[1]
            out.append(r[o:o + n].reshape(s))
            o += n
        return out

    # ------------------------------------------------------------------ итоги
    def centers(self, x):
        u, w, p, t = (self.m.to_np(a) if not isinstance(a, np.ndarray) else a for a in self.unpack(x))
        s = self.m.solid_np
        uc = 0.5 * (u[:, 1:] + u[:, :-1])
        wc = 0.5 * (w[1:] + w[:-1])
        return np.where(s, np.nan, uc), np.where(s, np.nan, wc), np.where(s, np.nan, t)


def anderson(op, x, iters, mem=20, beta=1.0, tol=0.0, callback=None, weights=None):
    """Повторы «невязка → два прохода» с ускорением Андерсона (тип II).
    g(x) = x + P⁻¹F(x); f = g(x) − x. Возвращает x и историю ‖f‖."""
    xp = op.xp
    X, Fh = [], []
    hist = []
    f_old = x_old = None
    for n in range(iters):
        f = op.sweeps(op.residual(x))
        nf = float(xp.linalg.norm(f))
        hist.append(nf)
        if callback:
            callback(n, x, nf)
        if nf <= tol:
            break
        if f_old is not None:
            X.append(x - x_old)
            Fh.append(f - f_old)
            if len(X) > mem:
                X.pop(0)
                Fh.pop(0)
        x_old, f_old = x.copy(), f.copy()
        if X:
            dF = xp.stack(Fh, 1)
            dX = xp.stack(X, 1)
            gam = xp.linalg.lstsq(dF, f, rcond=None)[0]
            x = x + beta * f - (dX + beta * dF) @ gam
        else:
            x = x + beta * f
    return x, hist


# ---------------------------------------------------------------------- перенос тепла ветром
def heat_coeffs(op, u, w):
    """Линейный оператор тепла при замороженном ветре: δRt = H δθ′ (пятиточечный, «откуда дует»).
    Возвращает D (диагональ), Lz, Uz (к k−1, k+1), Lx, Rx (к i−1, i+1)."""
    xp, d, ka = op.xp, op.d, op.kappa
    pos = lambda a: xp.maximum(a, 0.0)
    neg = lambda a: xp.minimum(a, 0.0)
    ko_x = ka / d * op.uxf.copy()
    ko_x[:, 0] = 0
    ko_x[:, -1] = 0
    ko_z = ka / d * op.wzf
    uL, uR = u[:, :-1], u[:, 1:]
    wB, wT = w[:-1], w[1:]
    D = -(pos(uR) + ko_x[:, 1:] - neg(uL) + ko_x[:, :-1] + pos(wT) + ko_z[1:] - neg(wB) + ko_z[:-1]) / d
    D = D - 1.0 / op.tau
    if op.sp_c is not None:
        D = D - op.sp_c
    Rx = (-neg(uR) + ko_x[:, 1:]) / d
    Lx = (pos(uL) + ko_x[:, :-1]) / d
    Uz = (-neg(wT) + ko_z[1:]) / d
    Lz = (pos(wB) + ko_z[:-1]) / d
    fl = op.fluidf
    D = D * fl + (1 - fl)
    return D, Lz * fl, Uz * fl, Lx * fl, Rx * fl


def heat_apply(op, H, t):
    D, Lz, Uz, Lx, Rx = H
    xp = op.xp
    tp = xp.pad(t * op.fluidf, 1)
    return (D * t + Lz * tp[:-2, 1:-1] + Uz * tp[2:, 1:-1] + Lx * tp[1:-1, :-2] + Rx * tp[1:-1, 2:]) * op.fluidf


def thomas(xp, a, b, c, r, axis):
    """Прогонка вдоль оси axis (0 — по столбцам снизу вверх, 1 — вдоль слоя): a — к предыдущему,
    c — к следующему. Проход туда + проход обратно."""
    if axis == 1:
        a, b, c, r = a.T, b.T, c.T, r.T
    n = b.shape[0]
    cp_ = xp.empty_like(b)
    dp = xp.empty_like(b)
    cp_[0] = c[0] / b[0]
    dp[0] = r[0] / b[0]
    for k in range(1, n):
        den = b[k] - a[k] * cp_[k - 1]
        cp_[k] = c[k] / den
        dp[k] = (r[k] - a[k] * dp[k - 1]) / den
    x = xp.empty_like(b)
    x[-1] = dp[-1]
    for k in range(n - 2, -1, -1):
        x[k] = dp[k] - cp_[k] * x[k + 1]
    return x.T if axis == 1 else x


def heat_lines(op, x, Rt=None, rows=True):
    """Прогонки тепла при замороженном ветре: по столбцам (вверх-вниз), затем вдоль слоёв."""
    xp = op.xp
    u, w, p, t = op.unpack(x)
    if Rt is None:
        Rt = op.residual(x, parts=True)[3]
    H = heat_coeffs(op, u, w)
    D, Lz, Uz, Lx, Rx = H
    dt = thomas(xp, Lz, D, Uz, -Rt, 0) * op.fluidf
    if rows:
        R2 = Rt + heat_apply(op, H, dt)
        dt = dt + thomas(xp, Lx, D, Rx, -R2, 1) * op.fluidf
    return dt


def step_combined(op, x, rows=True):
    """Один повтор: невязка → два прохода по гармоникам (давление, плавучесть, циркуляция) →
    прогонки тепла по столбцам/слоям с замороженным ветром (перенос тепла потоком)."""
    x1 = x + op.sweeps(op.residual(x))
    u, w, p, t = op.unpack(x1)
    dt = heat_lines(op, x1, rows=rows)
    t = t + dt
    return op.pack(u, w, p, t)


def anderson_map(op, gmap, x, iters, mem=20, beta=1.0, tol=0.0, callback=None):
    xp = op.xp
    X, Fh, hist = [], [], []
    f_old = x_old = None
    for n in range(iters):
        f = gmap(x) - x
        nf = float(xp.linalg.norm(f))
        hist.append(nf)
        if callback:
            callback(n, x, nf)
        if nf <= tol:
            break
        if f_old is not None:
            X.append(x - x_old)
            Fh.append(f - f_old)
            if len(X) > mem:
                X.pop(0)
                Fh.pop(0)
        x_old, f_old = x, f
        if X:
            dF = xp.stack(Fh, 1)
            dX = xp.stack(X, 1)
            gam = xp.linalg.lstsq(dF, f, rcond=None)[0]
            x = x + beta * f - (dX + beta * dF) @ gam
        else:
            x = x + beta * f
    return x, hist


# ---------------------------------------------------------------------- грубая сетка → мелкая
def _interp(xp, f, fmask, xs_c, zs_c, xs_f, zs_f):
    """Билинейная интерполяция поля f (на точках xs_c × zs_c) в точки xs_f × zs_f;
    веса только по «воздушным» точкам (fmask), чтобы нули под землёй не тянули вниз."""
    def idx(xc, xf):
        t = np.clip((xf - xc[0]) / (xc[1] - xc[0]), 0, len(xc) - 1.000001)
        i0 = np.floor(t).astype(int)
        return i0, t - i0
    ix, ax = idx(xs_c, xs_f)
    iz, az = idx(zs_c, zs_f)
    f = f * fmask
    num = 0
    den = 0
    for dz_, wz in ((0, 1 - az), (1, az)):
        for dx_, wx in ((0, 1 - ax), (1, ax)):
            kk = np.minimum(iz + dz_, len(zs_c) - 1)
            ii = np.minimum(ix + dx_, len(xs_c) - 1)
            wgt = xp.asarray(np.outer(wz, wx), f.dtype)
            sub = f[kk][:, ii]
            msk = fmask[kk][:, ii]
            num = num + wgt * sub
            den = den + wgt * msk
    return xp.where(den > 1e-6, num / xp.maximum(den, 1e-6), 0.0)


def prolong(op_c, x_c, op_f):
    """Установившееся поле грубой сетки — стартом для мелкой (последовательность сеток)."""
    xp = op_f.xp
    u, w, p, t = op_c.unpack(x_c)
    dc, df = op_c.d, op_f.d
    nzc, nxc, nzf, nxf = op_c.nz, op_c.nx, op_f.nz, op_f.nx
    cx_c, cz_c = (np.arange(nxc) + 0.5) * dc, (np.arange(nzc) + 0.5) * dc
    fx_c, fz_c = np.arange(nxc + 1) * dc, np.arange(nzc + 1) * dc
    cx_f, cz_f = (np.arange(nxf) + 0.5) * df, (np.arange(nzf) + 0.5) * df
    fx_f, fz_f = np.arange(nxf + 1) * df, np.arange(nzf + 1) * df
    uf = _interp(xp, u, op_c.uxf, fx_c, cz_c, fx_f, cz_f) * op_f.uxf
    if op_f.wind:
        uf[:, 0] = op_f.u0[:, 0]
    wf = _interp(xp, w, op_c.wzf, cx_c, fz_c, cx_f, fz_f) * op_f.wzf
    pf = _interp(xp, p, op_c.fluidf, cx_c, cz_c, cx_f, cz_f) * op_f.fluidf
    tf = _interp(xp, t, op_c.fluidf, cx_c, cz_c, cx_f, cz_f) * op_f.fluidf
    return op_f.pack(uf, wf, pf, tf)
