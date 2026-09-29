"""Уравнение массы (давления) ∇·(c∇φ) = f прогонками по линиям, с ПЕРЕМЕННЫМИ проводимостями граней
(c = d_f/dx²: у граней w — «жёстче» из-за устойчивости, см. adi5.py).

Два решателя, оба — только прогонки по линиям (столбцы вверх/вниз, слои вправо/влево):
  * ``adi``  — Писмен–Рэчфорд: один уровень, сдвиги по геометрическому циклу;
  * ``lmg``  — многоуровневый: те же прогонки (столбцы, затем слои) как сглаживатель на сетках
               d, 2d, 4d, … (V-цикл); на грубых уровнях линия короче — длинные моды гаснут там.
A = −∇·(c∇) (≥ 0), решаем A φ = −f; закрытые клетки (под землёй) — строка «φ = 0».
"""
from __future__ import annotations

import math

import numpy as np

from adi5 import thomas, thomas_parity, _sh


class Level:
    def __init__(self, xp, fluid, nz, nx):
        self.xp = xp
        self.nz, self.nx = nz, nx
        f32 = np.float32
        self.cx = xp.zeros((nz, nx + 1), f32)
        self.cz = xp.zeros((nz + 1, nx), f32)
        self.fluid = fluid
        self.fluidf = fluid.astype(f32)
        self.solid1 = 1.0 - self.fluidf

    def update(self):
        xp = self.xp
        self.E = -self.cx[:, 1:] * self.fluidf
        self.W = -self.cx[:, :-1] * self.fluidf
        self.N = -self.cz[1:] * self.fluidf
        self.S = -self.cz[:-1] * self.fluidf
        self.Hd = -(self.E + self.W)
        self.Vd = -(self.N + self.S)
        self.D = self.Hd + self.Vd + self.solid1

    def Ax(self, p):
        """A p = (Hd+Vd) p + Σ соседи (закрытые — 0)."""
        xp = self.xp
        return ((self.Hd + self.Vd) * p + self.E * _sh(xp, p, 0, 1) + self.W * _sh(xp, p, 0, -1)
                + self.N * _sh(xp, p, 1, 0) + self.S * _sh(xp, p, -1, 0))


class LinePoisson:
    def __init__(self, m, n_shifts=None, omega=1.0, cdiv=8.0, cscale=1.0):
        """m — HeatCA (геометрия, уровни базового многосеточного решателя — для масок)."""
        self.m = m
        self.xp = xp = m.xp
        self.levels = []
        for lv in m.poisson.levels:
            L = Level(xp, lv.fluid, lv.nz, lv.nx)
            self.levels.append(L)
        self.omega = omega
        self.cdiv, self.ccorr = cdiv, cscale
        self.bilinear = True
        self.zebra = True
        d = m.dx
        Lmax = max(m.pr.lx, m.pr.lz)
        a = (math.pi / Lmax) ** 2
        b = 4.0 / d ** 2
        if n_shifts is None:
            n_shifts = max(2, int(math.ceil(math.log(b / a) / math.log(8.0))))
        self.a, self.b = a, b
        self.shift_rel = [(b / a) ** ((j + 0.5) / n_shifts) for j in range(n_shifts)][::-1]
        self.shift_i = 0

    def set_coeffs(self, cx, cz):
        """Проводимости граней мелкого уровня (с учётом закрытых граней); грубые — осреднением."""
        xp = self.xp
        L0 = self.levels[0]
        L0.cx[...] = cx
        L0.cz[...] = cz
        L0.update()
        for f, c in zip(self.levels[:-1], self.levels[1:]):
            c.cx[...] = (f.cx[0::2, 0::2] + f.cx[1::2, 0::2]) / self.cdiv
            c.cz[...] = (f.cz[0::2, 0::2] + f.cz[0::2, 1::2]) / self.cdiv
            c.update()
        self.cscale = float(1.0)

    # ---------------------------------------------------------------- сглаживатель: прогонки
    def line_sweep(self, L, phi, f):
        """Столбцы (соседи по слою — с прошлого прохода), затем слои. Решаем A φ = f."""
        xp = self.xp
        if self.zebra:
            phi = phi.copy()
            for par in (0, 1):
                rr = (f - L.E * _sh(xp, phi, 0, 1) - L.W * _sh(xp, phi, 0, -1)) * L.fluidf
                thomas_parity(xp, L.S, L.D, L.N, rr, phi, 0, par)
            for par in (0, 1):
                rr = (f - L.N * _sh(xp, phi, 1, 0) - L.S * _sh(xp, phi, -1, 0)) * L.fluidf
                thomas_parity(xp, L.W, L.D, L.E, rr, phi, 1, par)
            return phi
        rr = f - L.E * _sh(xp, phi, 0, 1) - L.W * _sh(xp, phi, 0, -1)
        new = thomas(xp, L.S, L.D, L.N, rr * L.fluidf, axis=0)
        phi = phi + self.omega * (new - phi)
        rr = f - L.N * _sh(xp, phi, 1, 0) - L.S * _sh(xp, phi, -1, 0)
        new = thomas(xp, L.W, L.D, L.E, rr * L.fluidf, axis=1)
        phi = phi + self.omega * (new - phi)
        return phi

    def vcycle(self, li, phi, f, pre=1, post=1, coarse=10):
        xp = self.xp
        L = self.levels[li]
        if li == len(self.levels) - 1:
            for _ in range(coarse):
                phi = self.line_sweep(L, phi, f)
            return phi
        for _ in range(pre):
            phi = self.line_sweep(L, phi, f)
        r = (f - L.Ax(phi)) * L.fluidf
        C = self.levels[li + 1]
        rc = r.reshape(C.nz, 2, C.nx, 2).mean(axis=(1, 3)) * C.fluidf
        ec = self.vcycle(li + 1, xp.zeros_like(rc), rc, pre, post, coarse)
        phi = phi + self.ccorr * self.prolong(ec, C) * L.fluidf
        for _ in range(post):
            phi = self.line_sweep(L, phi, f)
        return phi

    def prolong(self, ec, C):
        """Билинейная интерполяция поправки с грубого уровня (веса 9/16, 3/16, 3/16, 1/16);
        за краем и под землёй сосед заменяется центром (отражение, как у стенки)."""
        xp = self.xp
        if not self.bilinear:
            return xp.repeat(xp.repeat(ec, 2, axis=0), 2, axis=1)
        nz, nx = ec.shape
        ep = xp.pad(ec, 1, mode="edge")
        fp = xp.pad(C.fluidf, 1)
        out = xp.empty((2 * nz, 2 * nx), ec.dtype)
        c = ec
        for a, dk in ((0, -1), (1, 1)):
            for b, di in ((0, -1), (1, 1)):
                sk = slice(1 + dk, 1 + dk + nz)
                si = slice(1 + di, 1 + di + nx)
                ck, ci = slice(1, 1 + nz), slice(1, 1 + nx)
                ek = xp.where(fp[sk, ci] > 0, ep[sk, ci], c)
                ei = xp.where(fp[ck, si] > 0, ep[ck, si], c)
                ekk = xp.where(fp[sk, si] > 0, ep[sk, si], 0.5 * (ek + ei))
                out[a::2, b::2] = (9 * c + 3 * ek + 3 * ei + ekk) / 16.0
        return out

    # ---------------------------------------------------------------- Писмен–Рэчфорд
    def adi(self, f, iters, scale):
        """scale — характерная проводимость (для сдвигов: спектр ∈ [a, b]·scale·d²)."""
        xp = self.xp
        L = self.levels[0]
        phi = xp.zeros_like(f)
        for it in range(iters):
            r = self.a * self.shift_rel[(self.shift_i + it) % len(self.shift_rel)] * scale
            Vphi = L.Vd * phi + L.N * _sh(xp, phi, 1, 0) + L.S * _sh(xp, phi, -1, 0)
            rr = (f - Vphi + r * phi) * L.fluidf
            phi = thomas(xp, L.W, L.Hd + r * L.fluidf + L.solid1, L.E, rr, axis=1)
            Hphi = L.Hd * phi + L.E * _sh(xp, phi, 0, 1) + L.W * _sh(xp, phi, 0, -1)
            rr = (f - Hphi + r * phi) * L.fluidf
            phi = thomas(xp, L.S, L.Vd + r * L.fluidf + L.solid1, L.N, rr, axis=0)
        return phi

    def solve(self, rhs, mode, iters, scale=1.0):
        """∇·(c∇φ) = rhs → φ (старт с нуля)."""
        xp = self.xp
        f = -rhs * self.levels[0].fluidf
        if mode == "adi":
            return self.adi(f, iters, scale)
        phi = xp.zeros_like(f)
        for _ in range(iters):
            phi = self.vcycle(0, phi, f)
        return phi
