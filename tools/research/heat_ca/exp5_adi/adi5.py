"""Опыт 5: установившееся состояние автомата раундами неявных прогонок по линиям (ADI).

Решаем ТЕ ЖЕ дискретные установившиеся уравнения, что у автомата (копия model.py), — не «похожие»:
невязки считаются кодом самого автомата (тот же полулагранжев перенос импульса с тем же dt,
та же вязкость с теми же краями, та же губка, тот же перенос тепла «откуда дует»,
теплопроводность по отклонению от фона, выхолаживание τ). Поэтому неподвижная точка раундов —
ровно неподвижная точка шага автомата (проверяется: невязка автомата на решении ~0 и
автомат, запущенный с решения, с него не уходит).

Неподвижная точка шага автомата (штиль, стенки по бокам):
  тепло:    −∇·F(u, θ) + нагрев − θ′/τ = 0,   F = u·θ(«откуда дует») − κ∇θ′
  импульс:  G(u, θ′) − ∇p = 0,  G = [(SL_dt(u) − u)/dt + ν∇²u + b(θ′) − губка·u] / (1 + dt·губка)
  масса:    ∇·u = 0 (по граням клеток, точно)

Раунд (коррекция по невязке + неполная проекция, «SIMPLEC в псевдовремени»):
  1. тепло:   δθ = (1/Δτ_θ + A_h)⁻¹ R_h            — прогонки по столбцам, потом по слоям (heat_iters раз)
  2. импульс: δu = (1/Δτ + A_u + S)⁻¹ (G − ∇p)      — то же для u и w (плавучесть — из нового θ);
              S — неявная плавучесть (дополнение Шура связи w ↔ θ): подъём на δw приносит воздух
              холоднее на Γ·δw/P_h → «сопротивление» (g/θ0)·Γ/P_h на гранях w (Γ = ∂θ/∂z ≥ 0)
  3. масса:   ∇·(d_f∇φ) = ∇·u*,  d_f = 1/(1/Δτ [+ S]),  u = u* − d_f∇φ,  p += φ;
              уравнение для φ — прогонками: Писмен–Рэчфорд на одном уровне (p_mode="adi") или
              «зебра»-прогонки как сглаживатель на уровнях d, 2d, 4d, … (p_mode="lmg");
              "mg" — многосеточный решатель автомата (для сравнения, только без S)
A_h, A_u — «против течения» + диффузия (+1/τ, губка) — только ПРЕДОБУСЛОВЛИВАТЕЛЬ (трёхдиагональные
по линиям), точность решения задаёт невязка. Главный ускоритель — Δτ_θ ≫ Δτ: медленная мода задачи —
выхолаживание τ = 2 ч, её гасит крупный псевдошаг тепла; шаг импульса ограничен связью с
гравитационными волнами в инверсии. Одна прогонка по линии = проход туда (прямой ход) и
обратно (обратный ход): столбцы (вверх/вниз) + слои (вправо/влево) = 4 прохода; в 3D — 6.
Прогонка — одно ядро CUDA: поток на линию, цикл по линии внутри.
"""
from __future__ import annotations

import math
import time

import numpy as np

from model import HeatCA, Params, SCENARIOS, G, THETA0

# ---------------------------------------------------------------- прогонка Томаса одним ядром
_THOMAS = {}


def _thomas_kernel(cp):
    if "k" in _THOMAS:
        return _THOMAS["k"]
    src = r'''
extern "C" __global__ void thomas(const float* a, const float* b, const float* c, const float* d,
                                  float* x, float* cw, int nlines, int n, int sl, int sj) {
    int l = blockDim.x * blockIdx.x + threadIdx.x;
    if (l >= nlines) return;
    int o = l * sl;
    // прямой ход (вверх по столбцу / вправо по слою)
    float bb = b[o];
    float cc = c[o] / bb;
    float dd = d[o] / bb;
    cw[o] = cc; x[o] = dd;
    for (int j = 1; j < n; ++j) {
        int q = o + j * sj;
        float aj = a[q];
        float den = b[q] - aj * cc;
        cc = c[q] / den;
        dd = (d[q] - aj * dd) / den;
        cw[q] = cc; x[q] = dd;
    }
    // обратный ход (вниз / влево)
    float xn = x[o + (n - 1) * sj];
    for (int j = n - 2; j >= 0; --j) {
        int q = o + j * sj;
        xn = x[q] - cw[q] * xn;
        x[q] = xn;
    }
}
'''
    k = cp.RawKernel(src, "thomas")
    _THOMAS["k"] = k
    return k


def thomas(xp, a, b, c, d, axis):
    """Трёхдиагональные системы вдоль оси для всех линий сразу. a — связь с предыдущим, c — со
    следующим, b — диагональ. axis=0: линии — столбцы (вдоль z), axis=1: слои (вдоль x)."""
    nz, nx = b.shape
    if xp is np:
        return _thomas_np(a, b, c, d, axis)
    k = _thomas_kernel(xp)
    x = xp.empty_like(b)
    cw = xp.empty_like(b)
    if axis == 0:
        nlines, n, sl, sj = nx, nz, 1, nx
    else:
        nlines, n, sl, sj = nz, nx, nx, 1
    k(((nlines + 127) // 128,), (128,), (a, b, c, d, x, cw, np.int32(nlines), np.int32(n), np.int32(sl), np.int32(sj)))
    return x


def thomas_parity(xp, a, b, c, d, x, axis, parity):
    """То же, но только для линий чётности parity (0 — чётные, 1 — нечётные), ответ пишется в x
    на месте (остальные линии не трогаются) — «зебра»: линии одной чётности не зависят друг от друга."""
    nz, nx = b.shape
    k = _thomas_kernel(xp)
    cw = xp.empty_like(b)
    if axis == 0:
        nl, n, sl, sj, off = (nx - parity + 1) // 2, nz, 2, nx, parity
    else:
        nl, n, sl, sj, off = (nz - parity + 1) // 2, nx, 2 * nx, 1, parity * nx
    if nl <= 0:
        return x
    v = lambda arr: arr.ravel()[off:]
    k(((nl + 127) // 128,), (128,), (v(a), v(b), v(c), v(d), v(x), v(cw), np.int32(nl), np.int32(n),
                                     np.int32(sl), np.int32(sj)))
    return x


def _thomas_np(a, b, c, d, axis):
    if axis == 1:
        a, b, c, d = (v.T for v in (a, b, c, d))
    n = b.shape[0]
    cp_, dp_ = np.empty_like(b), np.empty_like(b)
    cp_[0], dp_[0] = c[0] / b[0], d[0] / b[0]
    for k in range(1, n):
        den = b[k] - a[k] * cp_[k - 1]
        cp_[k] = c[k] / den
        dp_[k] = (d[k] - a[k] * dp_[k - 1]) / den
    x = np.empty_like(b)
    x[-1] = dp_[-1]
    for k in range(n - 2, -1, -1):
        x[k] = dp_[k] - cp_[k] * x[k + 1]
    return x.T if axis == 1 else x


def _sh(xp, f, dk, di):
    """f сдвинутое: out[k,i] = f[k+dk, i+di], за краем — 0."""
    out = xp.zeros_like(f)
    nz, nx = f.shape
    ks = slice(max(0, -dk), nz - max(0, dk))
    is_ = slice(max(0, -di), nx - max(0, di))
    kd = slice(max(0, dk), nz - max(0, -dk) if max(0, -dk) else nz)
    idd = slice(max(0, di), nx - max(0, -di) if max(0, -di) else nx)
    out[ks, is_] = f[kd, idd]
    return out


def line_gs(xp, P, E, W, N, S, R, iters=1, x=None):
    """Решение P x + E x_{i+1} + W x_{i−1} + N x_{k+1} + S x_{k−1} = R прогонками: столбцы
    (соседи по слою — с прошлого прохода), затем слои (соседи по столбцу — только что найденные)."""
    if x is None:
        x = xp.zeros_like(R)
    for _ in range(iters):
        x = thomas(xp, S, P, N, R - E * _sh(xp, x, 0, 1) - W * _sh(xp, x, 0, -1), axis=0)
        x = thomas(xp, W, P, E, R - N * _sh(xp, x, 1, 0) - S * _sh(xp, x, -1, 0), axis=1)
    return x


# ---------------------------------------------------------------- решатель
class ADI5:
    def __init__(self, name, cell, dtau=300.0, dtau_h=None, p_mode="adi", p_iters=4, heat_iters=1,
                 mom_iters=1, n_shifts=None, p_under=1.0, schur=False, cfl_loc=None, order="heat_first", device="gpu"):
        sc = SCENARIOS[name]
        assert sc.wind_ms == 0, "только штиль (стенки по бокам): сценарии 1, 2, 4"
        self.m = m = HeatCA(sc, Params(cell=cell, device=device))
        self.xp = xp = m.xp
        self.dt = m.dt                        # шаг автомата: полулагранжев перенос с ТЕМ ЖЕ dt
        self.d = m.dx
        self.dtau = dtau
        self.dtau_h = dtau_h                  # None — тепло без псевдовремени (сразу установившееся)
        self.p_mode, self.p_iters = p_mode, p_iters
        self.heat_iters, self.mom_iters = heat_iters, mom_iters
        self.p_under = p_under
        self.order = order                    # heat_first: тепло → ветер → масса; mom_first: ветер → масса → тепло
        self.cfl_loc = cfl_loc                # местный псевдошаг: 1/Δτ + |v|/(C·d) (None — всюду Δτ)
        self.schur = schur                    # неявная связь «w ↔ θ» через устойчивость (гравитационные волны)
        f = m.dtype
        self.u = xp.zeros_like(m.u)
        self.w = xp.zeros_like(m.w)
        self.th = xp.zeros((m.nz, m.nx), f)
        self.p = xp.zeros((m.nz, m.nx), f)
        self.dmax = xp.zeros((), f)
        self.graph = None
        self.rounds = 0
        # индексы граней для полулагранжевой выборки (как у автомата)
        ku, iu = np.indices(m.u.shape)
        kw, iw = np.indices(m.w.shape)
        m._iu, m._ku = xp.asarray(iu, f), xp.asarray(ku, f)
        m._iw, m._kw = xp.asarray(iw, f), xp.asarray(kw, f)
        from line_poisson import LinePoisson
        self.lp = LinePoisson(m, n_shifts=n_shifts)

    # ------------------------------------------------ невязки (код автомата)
    def heat_residual(self, u, w, th):
        """R_h = −∇·F + нагрев − θ′/τ (К/с) — ровно правая часть dH/dt автомата при μ = 0."""
        xp, m, d, pr = self.xp, self.m, self.d, self.m.pr
        thf = m.tb + th                      # полная θ − θ0
        thx = xp.zeros_like(u)
        thx[:, 1:-1] = xp.where(u[:, 1:-1] > 0, thf[:, :-1], thf[:, 1:])
        thx[:, 0] = xp.where(u[:, 0] > 0, m.tb_col, thf[:, 0])
        thx[:, -1] = xp.where(u[:, -1] > 0, thf[:, -1], m.tb_col)
        thz = xp.zeros_like(w)
        thz[1:-1] = xp.where(w[1:-1] > 0, thf[:-1], thf[1:])
        Fx = u * thx
        Fz = w * thz
        Fx[:, 1:-1] -= pr.kappa * (th[:, 1:] - th[:, :-1]) / d * m.uxf[:, 1:-1]
        Fz[1:-1] -= pr.kappa * (th[1:] - th[:-1]) / d * m.wzf[1:-1]
        dH = -((Fx[:, 1:] - Fx[:, :-1]) + (Fz[1:] - Fz[:-1])) / d
        return (dH + m.heat_src - th / pr.tau_cool) * m.fluidf

    def mom_force(self, u, w, th):
        """G = (шаг автомата без давления − u)/dt: полулагранжев перенос, вязкость, плавучесть, губка."""
        xp, m, dt, d, pr = self.xp, self.m, self.dt, self.d, self.m.pr
        wp = xp.pad(w, ((0, 0), (1, 1)), mode="edge")
        w_at_u = 0.25 * (wp[:-1, :-1] + wp[:-1, 1:] + wp[1:, :-1] + wp[1:, 1:])
        up = xp.pad(u, ((1, 1), (0, 0)), mode="edge")
        u_at_w = 0.25 * (up[:-1, :-1] + up[:-1, 1:] + up[1:, :-1] + up[1:, 1:])
        un = m._sample(u, m._iu - u * dt / d, m._ku - w_at_u * dt / d)
        wn = m._sample(w, m._iw - u_at_w * dt / d, m._kw - w * dt / d)
        un = un + dt * pr.nu * m._lap(u - m.ubg * m.uxf)
        wn = wn + dt * pr.nu * m._lap(w)
        b = xp.zeros_like(w)
        thp = th * m.fluidf
        b[1:-1, :] = G / THETA0 * 0.5 * (thp[1:, :] + thp[:-1, :])
        wn = wn + dt * b
        un = (un + dt * m.sp_u * m.ubg) / (1 + dt * m.sp_u)
        wn = wn / (1 + dt * m.sp_w)
        Gu = (un - u) / dt * m.uxf
        Gw = (wn - w) / dt * m.wzf
        return Gu, Gw

    def grad(self, p):
        xp, m, d = self.xp, self.m, self.d
        gx = xp.zeros_like(self.u)
        gx[:, 1:-1] = (p[:, 1:] - p[:, :-1]) / d * m.uxf[:, 1:-1]
        gz = xp.zeros_like(self.w)
        gz[1:-1] = (p[1:] - p[:-1]) / d * m.wzf[1:-1]
        return gx, gz

    def residuals(self, u=None, w=None, th=None, p=None):
        """Невязки неподвижной точки автомата: тепло (К/с), импульс (м/с²), дивергенция (1/с)."""
        u = self.u if u is None else u
        w = self.w if w is None else w
        th = self.th if th is None else th
        p = self.p if p is None else p
        Rh = self.heat_residual(u, w, th)
        Gu, Gw = self.mom_force(u, w, th)
        gx, gz = self.grad(p)
        return Rh, Gu - gx, Gw - gz, self.m.div(u, w) * self.m.fluidf

    # ------------------------------------------------ предобусловливатели (трёхдиагональные по линиям)
    def heat_coeffs(self, u, w, inv_h=None):
        xp, m, d = self.xp, self.m, self.d
        K, tau = m.pr.kappa, m.pr.tau_cool
        pos = lambda a: xp.maximum(a, 0.0)
        neg = lambda a: xp.maximum(-a, 0.0)
        ue, uw, wn, ws = u[:, 1:], u[:, :-1], w[1:], w[:-1]
        ox = m.uxf.copy()
        ox[:, 0] = 0.0
        ox[:, -1] = 0.0
        oe, ow, on, os_ = ox[:, 1:], ox[:, :-1], m.wzf[1:], m.wzf[:-1]
        kd = K / d / d
        E = -neg(ue) / d - kd * oe
        W = -pos(uw) / d - kd * ow
        N = -neg(wn) / d - kd * on
        S = -pos(ws) / d - kd * os_
        P = (pos(ue) + neg(uw) + pos(wn) + neg(ws)) / d + kd * (oe + ow + on + os_) + 1.0 / tau
        P = xp.maximum(P, -(E + W + N + S) + 1.0 / tau)    # диагональное преобладание при ∇·u ≠ 0
        if inv_h is not None:
            P = P + inv_h
        f = m.fluidf
        P = xp.where(m.fluid, P, 1.0)
        return P, E * f, W * f, N * f, S * f

    def mom_coeffs(self, ua, wa, fixed, sponge, inv):
        """(1/Δτ + перенос «против течения» + вязкость + губка) для поля на гранях."""
        xp, d, nu = self.xp, self.d, self.m.pr.nu
        pos = lambda a: xp.maximum(a, 0.0)
        neg = lambda a: xp.maximum(-a, 0.0)
        one = xp.ones_like(ua)
        hasW = one.copy(); hasW[:, 0] = 0
        hasE = one.copy(); hasE[:, -1] = 0
        hasS = one.copy(); hasS[0, :] = 0
        hasN = one.copy(); hasN[-1, :] = 0
        kd = nu / d / d
        P = inv + (pos(ua) * hasW + neg(ua) * hasE + pos(wa) * hasS + neg(wa) * hasN) / d + sponge
        W = -pos(ua) / d * hasW - kd * hasW
        E = -neg(ua) / d * hasE - kd * hasE
        S = -pos(wa) / d * hasS - kd * hasS
        N = -neg(wa) / d * hasN - kd * hasN
        P = P + kd * (hasW + hasE + hasS + hasN)
        P[0, :] += kd                          # под нижним краем массива — ноль (прилипание)
        P = xp.where(fixed, 1.0, P)
        W, E, S, N = (xp.where(fixed, 0.0, c) for c in (W, E, S, N))
        return P, E, W, N, S

    # ------------------------------------------------ раунд
    def _heat(self, u, w, th, inv_h):
        """Тепло: δθ = M_h⁻¹ R_h прогонками (столбцы, затем слои; heat_iters раз)."""
        xp, m = self.xp, self.m
        Rh = self.heat_residual(u, w, th)
        P, E, W, N, S = self.heat_coeffs(u, w, inv_h)
        dth = line_gs(xp, P, E, W, N, S, Rh, self.heat_iters)
        if getattr(self, "freeze_heat", False):
            return th, P
        return (th + dth) * m.fluidf, P

    def round(self):
        xp, m, d = self.xp, self.m, self.d
        u, w, th = self.u, self.w, self.th           # ссылки на состояние: присваиваем в конце
        wp = xp.pad(w, ((0, 0), (1, 1)), mode="edge")
        w_at_u = 0.25 * (wp[:-1, :-1] + wp[:-1, 1:] + wp[1:, :-1] + wp[1:, 1:])
        up = xp.pad(u, ((1, 1), (0, 0)), mode="edge")
        u_at_w = 0.25 * (up[:-1, :-1] + up[:-1, 1:] + up[1:, :-1] + up[1:, 1:])
        if self.cfl_loc:
            k = 1.0 / (self.cfl_loc * d)
            va = 0.5 * (xp.abs(u[:, 1:]) + xp.abs(u[:, :-1]) + xp.abs(w[1:]) + xp.abs(w[:-1]))
            inv_h = (1.0 / self.dtau_h + k * va) if self.dtau_h else None
            inv_u = 1.0 / self.dtau + k * (xp.abs(u) + xp.abs(w_at_u))
            inv_w = 1.0 / self.dtau + k * (xp.abs(w) + xp.abs(u_at_w))
        else:
            inv_h = (1.0 / self.dtau_h) if self.dtau_h else None
            inv_u = xp.full(u.shape, 1.0 / self.dtau, m.dtype)
            inv_w = xp.full(w.shape, 1.0 / self.dtau, m.dtype)
        heat_first = self.order == "heat_first"
        Ph = None
        # 1. тепло (порядок «тепло → ветер»: плавучесть в импульсе — уже из нового θ)
        if heat_first:
            th, Ph = self._heat(u, w, th, inv_h)
        # 2. импульс
        Gu, Gw = self.mom_force(u, w, th)
        gx, gz = self.grad(self.p)
        P, E, W, N, S = self.mom_coeffs(u, w_at_u, ~m.ux_open, m.sp_u, inv_u)
        du = line_gs(xp, P, E, W, N, S, (Gu - gx) * m.uxf, self.mom_iters)
        P, E, W, N, S = self.mom_coeffs(u_at_w, w, ~m.wz_open, m.sp_w, inv_w)
        cpl = None
        if self.schur:
            # неявная плавучесть (дополнение Шура по связи w ↔ θ): подъём на δw за «время отклика»
            # тепла s приносит воздух холоднее на Γ·s·δw → в уравнении w «сопротивление» (g/θ0)·Γ·s
            gam = xp.zeros_like(w)
            if self.schur == "bg":        # Γ — фон, s = Δτ_h/(1 + Δτ_h/τ) (как полунеявно в атм. моделях)
                tb = m.tb
                gam[1:-1] = xp.maximum((tb[1:] - tb[:-1]) / d, 0.0) * m.wzf[1:-1]
                s_th = 1.0 / (1.0 / (self.dtau_h or 1e30) + 1.0 / m.pr.tau_cool)
                cpl = G / THETA0 * gam * s_th
            else:                         # Γ — полная θ, s = 1/P_h (диагональ предобусловливателя тепла)
                if Ph is None:
                    Ph = self.heat_coeffs(u, w, inv_h)[0]
                thf = m.tb + th
                gam[1:-1] = xp.maximum((thf[1:] - thf[:-1]) / d, 0.0) * m.wzf[1:-1]
                rph = xp.zeros_like(w)
                rph[1:-1] = 0.5 * (1.0 / Ph[1:] + 1.0 / Ph[:-1])
                cpl = G / THETA0 * gam * rph
            P = P + cpl * m.wzf
        dw = line_gs(xp, P, E, W, N, S, (Gw - gz) * m.wzf, self.mom_iters)
        us = (u + du) * m.uxf
        ws = (w + dw) * m.wzf
        # 3. масса: ∇·(d_f ∇φ) = ∇·u*,  u = u* − d_f ∇φ,  p += φ.  d_f = псевдошаг грани;
        #    на гранях w с неявной плавучестью — 1/(1/Δτ + связь): устойчивость «сопротивляется» подъёму
        du_f = 1.0 / inv_u
        dw_f = 1.0 / inv_w if cpl is None else 1.0 / (inv_w + cpl)
        if self.p_mode == "mg":
            assert not self.cfl_loc and not self.schur, "mg — только постоянные проводимости"
            rhs = m.div(us, ws) / self.dtau * m.fluidf
            rhs -= xp.sum(rhs) / m.n_fluid * m.fluidf
            phi = xp.zeros_like(rhs)
            for _ in range(self.p_iters):
                phi = m.poisson.vcycle(0, phi, rhs)
        else:
            lv = m.poisson.levels[0]
            self.lp.set_coeffs(lv.cx * du_f, lv.cz * dw_f)
            rhs = m.div(us, ws) * m.fluidf
            rhs -= xp.sum(rhs) / m.n_fluid * m.fluidf
            phi = self.lp.solve(rhs, self.p_mode, self.p_iters, scale=self.dtau)
        phi -= xp.sum(phi * m.fluidf) / m.n_fluid * m.fluidf
        gx, gz = self.grad(phi)
        un = us - du_f * gx
        wn = ws - dw_f * gz
        # 4. тепло (порядок «ветер → тепло»: тепло видит новый ветер — «обратная» половина связи)
        if not heat_first:
            th, _ = self._heat(un, wn, th, inv_h)
        self.dmax[...] = xp.maximum(xp.abs(un - u).max(), xp.abs(wn - w).max())
        self.u[...] = un
        self.w[...] = wn
        self.th[...] = th
        self.p[...] = self.p + self.p_under * phi

    def advance_shift(self):
        if self.p_mode == "adi":
            self.lp.shift_i = (self.lp.shift_i + self.p_iters) % len(self.lp.shift_rel)

    def capture(self):
        """Раунд как CUDA Graph. Сдвиги ПР-ADI внутри графа фиксированы: p_iters кратно их числу,
        или (если меньше) — граф на каждую фазу цикла сдвигов."""
        import cupy as cp
        m = self.m
        m.stream.use()
        self.round()
        self.advance_shift()
        self.rounds += 1
        m.stream.synchronize()
        self._pool = cp.cuda.MemoryPool()
        old = cp.get_default_memory_pool()
        cp.cuda.set_allocator(self._pool.malloc)
        self.graphs = []
        nph = 1
        ns = len(self.lp.shift_rel)
        if self.p_mode == "adi" and self.p_iters % ns:
            nph = ns // math.gcd(ns, self.p_iters)
        try:
            for _ in range(nph):
                m.stream.use()
                m.stream.begin_capture()
                self.round()
                self.graphs.append(m.stream.end_capture())
                self.advance_shift()
        finally:
            cp.cuda.set_allocator(old.malloc)
        self.graph = True
        self._gi = 0

    def step(self):
        if self.graph:
            self.graphs[self._gi].launch(self.m.stream)
            self._gi = (self._gi + 1) % len(self.graphs)
        else:
            self.round()
            self.advance_shift()
        self.rounds += 1

    def set_state(self, u, w, th, p):
        xp = self.xp
        self.u[...] = xp.asarray(u)
        self.w[...] = xp.asarray(w)
        self.th[...] = xp.asarray(th)
        self.p[...] = xp.asarray(p)

    def centers(self):
        m = self.m
        u, w, th = m.to_np(self.u), m.to_np(self.w), m.to_np(self.th)
        m.stream.use()
        uc = 0.5 * (u[:, 1:] + u[:, :-1])
        wc = 0.5 * (w[1:] + w[:-1])
        s = m.solid_np
        return (np.where(s, np.nan, uc), np.where(s, np.nan, wc), np.where(s, np.nan, th))
