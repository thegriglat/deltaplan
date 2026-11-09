"""Шаблон пузыря-термика (TB1): голова Хилла + шлейф Тёрнера + отражения, функция тока Стокса.

Только numpy. Контракт: docs/contracts/thermal-bubble.md, раздел TB1. Ось z вверх, земля z = 0.

Поле каждого пузыря — сумма осесимметричных вкладов, каждый выражен через функцию тока Стокса
psi(rho, s): u_rho = -(1/rho) d psi/ds, u_s = (1/rho) d psi/d rho  =>  div v = 0 тождественно.
  * голова — сферический вихрь Хилла (вертикальная ось через центр головы);
  * шлейф — трубка (rho < b) с потоком Q(s), снаружи — потенциальный приток вовлечения
    (линия стоков плотности -dQ/ds на оси), сшивка гладким весом chi(rho/b) на [b, 1.5 b];
  * земля и крышка — метод изображений (зеркальные образы, ряд по обеим плоскостям).
Скорости — аналитические производные psi, не разности.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

import numpy as np

# ---------------------------------------------------------------- числа из литературы
_ALPHA_TH = 0.25
_K_ADDED = 0.5
PARAMS: dict[str, dict] = {
    "alpha_thermal": {
        "value": _ALPHA_TH, "unit": "1 (dR/dz)", "reliability": "medium",
        "source": "Scorer 1957 (J. Fluid Mech. 2, 583); Morton, Taylor & Turner 1956 (Proc. R. Soc. A 234, 1); "
                  "Turner 1969 (Ann. Rev. Fluid Mech. 1, 29); лаборатория 0,25–0,34 (по обзору в arXiv:astro-ph/0008099)",
    },
    "added_mass_k": {
        "value": _K_ADDED, "unit": "1", "reliability": "high",
        "source": "присоединённая масса шара = 1/2 объёма (Lamb, Hydrodynamics, §92; Batchelor 1967, §6.4); "
                  "использована Тёрнером 1964 для термиков, ускорение шара 2B/3 при начале подъёма",
    },
    "C_thermal": {
        "value": 1.0 / np.sqrt(2.0 * (1.0 + _K_ADDED) * _ALPHA_TH), "unit": "1 (U = C sqrt(g' R))",
        "reliability": "medium",
        "source": "вывод из импульса (1+k) d(V U)/dt = B при R = alpha z, B = g'V = const (Scorer 1957; "
                  "Turner 1964, 1969): U = C sqrt(g'R), C = [2(1+k) alpha]^(-1/2) = 1,155; НЕ подогнано",
    },
    "alpha_plume": {
        "value": 0.12, "unit": "1 (db/dz, плоский профиль)", "reliability": "medium",
        "source": "Morton, Taylor & Turner 1956 (Proc. R. Soc. A 234, 1); Turner 1973, Buoyancy Effects in Fluids, гл. 6; "
                  "обзоры: 0,10–0,16 для круглых шлейфов (плоский профиль), гауссов в 1/sqrt2 меньше",
    },
    "front_fraction": {
        "value": 0.6, "unit": "1 (скорость фронта / скорость шлейфа на той же высоте)", "reliability": "medium",
        "source": "Turner 1962 (J. Fluid Mech. 13, 356): фронт стартового факела движется со скоростью "
                  "≈ 0,6 средней осевой скорости установившегося шлейфа на том же уровне",
    },
    "alpha_head": {
        "value": 0.15, "unit": "1 (R / z центра)", "reliability": "low",
        "source": "Turner 1962 (J. Fluid Mech. 13, 356): шляпа стартового факела расширяется чуть больше чем на "
                  "половину угла термика (0,5·0,25); число — оценка по этой фразе, оригинал не сверен",
    },
    "plume_top_hat": {
        "value": 1.0, "unit": "1 (флаг: MTT с плоским профилем)", "reliability": "high",
        "source": "Morton, Taylor & Turner 1956: b = (6/5) alpha z, w = (5/(6 alpha)) (9 alpha F/(10 pi))^(1/3) z^(-1/3), "
                  "Q = pi b^2 w ~ z^(5/3) (F — полный поток плавучести g'Q, без деления на pi в F/pi)",
    },
}

_AL_P = PARAMS["alpha_plume"]["value"]
_AL_H = PARAMS["alpha_head"]["value"]
_AL_T = PARAMS["alpha_thermal"]["value"]
_C_T = PARAMS["C_thermal"]["value"]
_PHI = PARAMS["front_fraction"]["value"]

# численные константы шаблона (не физика)
_S0 = 3.0          # м, сглаживание точечного источника шлейфа у земли
_BLEND = 0.5       # ширина сшивки: rho/b от 1 до 1,5
_PANEL = 1.25      # рост панели квадратуры вдоль шлейфа
_GL_N = 8


@dataclass(frozen=True)
class Env:
    wind: tuple[float, float] = (0.0, 0.0)
    zi: float = 1400.0
    g_theta: float = 9.81 / 300.0


@dataclass(frozen=True)
class Source:
    x: float
    y: float
    t0: float
    F0: float
    tau: float


@dataclass(frozen=True)
class State:
    xs: float
    ys: float
    xc: float
    yc: float
    zc: float
    R: float
    U: float
    Q: float
    F0: float
    zb: float


# ---------------------------------------------------------------- шлейф (MTT)
def _kp(F0: float) -> float:
    """w_p(z) = kp z^(-1/3)."""
    return 5.0 / (6.0 * _AL_P) * (0.9 * _AL_P * F0 / np.pi) ** (1.0 / 3.0)


def _cq(F0: float) -> float:
    """Q_p(s) = cq s^(5/3)."""
    return np.pi * 1.2 * _AL_P * (0.9 * _AL_P * F0 / np.pi) ** (1.0 / 3.0)


def plume_Q(F0: float, s: float) -> float:
    return _cq(F0) * s ** (5.0 / 3.0)


def plume_w(F0: float, z: float) -> float:
    return _kp(F0) * z ** (-1.0 / 3.0)


# ---------------------------------------------------------------- траектория
def _front(F0: float, tp: float) -> tuple[float, float]:
    """Фронт стартового факела (Turner 1962): z^(4/3) = (4/3) phi kp t; (z, dz/dt)."""
    kp = _kp(F0)
    z = (4.0 / 3.0 * _PHI * kp * tp) ** 0.75
    return z, _PHI * kp * z ** (-1.0 / 3.0)


def _raw(src: Source, tp: float) -> tuple[float, float, float]:
    """(zc, R, U) без крышки; tp = t − t0 > 0."""
    if tp <= src.tau:
        zf, vf = _front(src.F0, tp)
        k = 1.0 + _AL_H
        zc = zf / k
        return zc, _AL_H * zc, vf / k
    zf, vf = _front(src.F0, src.tau)
    k = 1.0 + _AL_H
    zc0, R0 = zf / k, _AL_H * zf / k
    zv = zc0 - R0 / _AL_T
    K = (vf / k) * (R0 / _AL_T)  # непрерывность U при отрыве; B_head = thermal_B(): см. README
    d = np.sqrt((R0 / _AL_T) ** 2 + 2.0 * K * (tp - src.tau))
    return zv + d, _AL_T * d, K / d


def thermal_B(src: Source) -> float:
    """Плавучесть головы после отрыва, м⁴/с²: из непрерывности U (U = C sqrt(3B/4pi)/(alpha_th d), K = U d);
    доля от F0·tau — сколько несёт голова, остальное осталось в шлейфе и следе."""
    zf, vf = _front(src.F0, src.tau)
    k = 1.0 + _AL_H
    K = (vf / k) * (_AL_H * zf / k / _AL_T)
    return 4.0 * np.pi / 3.0 * (K * _AL_T / _C_T) ** 2


def _life(src: Source, env: Env) -> tuple[float, float, float, float]:
    """(t_hit, zc_hit, R_hit, t_end) относительно t0; t_hit = inf, если крышки не достичь."""
    f = lambda tp: (lambda r: r[0] + r[1] - env.zi)(_raw(src, tp))  # noqa: E731
    hi = 1.0
    while f(hi) < 0 and hi < 1e6:
        hi *= 2.0
    if f(hi) < 0:
        return np.inf, 0.0, 0.0, np.inf
    lo = 0.0
    for _ in range(80):
        mid = 0.5 * (lo + hi)
        lo, hi = (mid, hi) if f(mid) < 0 else (lo, mid)
    zc, R, U = _raw(src, hi)
    # конец: голова упёрлась — живёт ещё ~R/U (время обтекания головой своего радиуса), но не меньше,
    # чем нужно шлейфу, чтобы кончиться
    t_end = hi + R / max(U, 1e-3)
    return hi, zc, R, t_end


def _zb(src: Source, tp: float) -> float:
    if tp <= src.tau:
        return 0.0
    return (4.0 / 3.0 * _kp(src.F0) * (tp - src.tau)) ** 0.75


def state(src: Source, env: Env, t: float) -> State | None:
    tp = t - src.t0
    if tp <= 0.0:
        return None
    t_hit, zc_h, R_h, t_end = _life(src, env)
    stopped = tp >= t_hit
    if stopped:
        zc, R, U = zc_h, R_h, 0.0
    else:
        zc, R, U = _raw(src, tp)
    zb = _zb(src, tp)
    xc = src.x + env.wind[0] * tp
    yc = src.y + env.wind[1] * tp
    L = float(np.sqrt((xc - src.x) ** 2 + (yc - src.y) ** 2 + zc * zc))
    zbs = zb * L / zc
    F0, Q = src.F0, 0.0
    if zbs >= L - R:  # нижний край догнал голову — шлейфа нет
        F0, zb = 0.0, zc
    else:
        Q = plume_Q(src.F0, max(L - R, 0.0))
    if stopped and F0 == 0.0 and tp >= t_end:
        return None
    return State(xs=src.x, ys=src.y, xc=xc, yc=yc, zc=zc, R=R, U=U, Q=Q, F0=F0, zb=zb)


def from_game(x: float, y: float, t0: float, wstar: float, zl: float, env: Env) -> Source:
    """F0 = (w*^3/z_l) / n_A, n_A = 8,5/z_l^2 (Дирдорф 1970; Аллен 2006): F0 = w*^3 z_l / 8,5.
    tau — интервал между рождениями термиков с одного ядра: из баланса потока плавучести
    w*^3/z_l = n_A · B / T, B = F0 · tau и T = tau (термик за tau пересекает слой), tau = время,
    за которое фронт стартового факела с этим F0 доходит до z_l (Turner 1962)."""
    F0 = wstar ** 3 * zl / 8.5
    kp = _kp(F0)
    tau = 0.75 * zl ** (4.0 / 3.0) / (_PHI * kp)
    return Source(x=x, y=y, t0=t0, F0=F0, tau=tau)


# ---------------------------------------------------------------- вклад одного пузыря
def _ss(x):
    x = np.clip(x, 0.0, 1.0)
    return x ** 3 * (10.0 - 15.0 * x + 6.0 * x * x)


def _dss(x):
    xc = np.clip(x, 0.0, 1.0)
    return 30.0 * xc ** 2 * (1.0 - xc) ** 2


def _hill(P, st: State) -> np.ndarray:
    dx, dy, s = P[:, 0] - st.xc, P[:, 1] - st.yc, P[:, 2] - st.zc
    r2 = dx * dx + dy * dy + s * s
    rho2 = dx * dx + dy * dy
    U, R = st.U, st.R
    inside = r2 < R * R
    r = np.sqrt(np.where(inside, 1.0, r2))
    r5 = r ** 5
    kin = 1.5 * U * s / (R * R)
    kout = 1.5 * U * R ** 3 * s / r5
    k = np.where(inside, kin, kout)
    w_in = U + 1.5 * U * (1.0 - r2 / (R * R)) - 1.5 * U * rho2 / (R * R)
    w_out = U * R ** 3 / r ** 3 - 1.5 * U * R ** 3 * rho2 / r5
    out = np.empty_like(P)
    out[:, 0] = k * dx
    out[:, 1] = k * dy
    out[:, 2] = np.where(inside, w_in, w_out)
    return out


class _Plume:
    """Геометрия и профили потока шлейфа одного State."""

    def __init__(self, st: State):
        a = np.array([st.xs, st.ys, 0.0])
        c = np.array([st.xc, st.yc, st.zc])
        d = c - a
        self.L = float(np.linalg.norm(d))
        self.e = d / self.L
        self.a = a
        self.sb = st.zb * self.L / st.zc
        self.stb = self.L - st.R
        self.cq = _cq(st.F0)
        self.attached = self.sb <= 1e-9
        self.Lb = 0.0 if self.attached else min(0.5 * self.sb, 0.3 * (self.stb - self.sb))
        self.Lt = st.R
        self.k = 1.2 * _AL_P
        self.kap = self.cq / (2.0 * np.pi * self.k ** 2)
        self.s, self.wq = self._nodes()
        self.m = -self._dQ(self.s) * self.wq  # сила точечных источников (отрицательная — сток)

    def _edges(self) -> np.ndarray:
        pts = [max(self.sb, 0.0), self.stb, self.L]
        if not self.attached and self.Lb > 0:
            pts.append(self.sb + self.Lb)
        pts = sorted(set(pts))
        edges = [pts[0]]
        for lo, hi in zip(pts[:-1], pts[1:]):
            x = lo
            while x < hi:
                nx = max(x * _PANEL, x + 2.0) if x >= 2.0 else min(2.0, hi)
                nx = min(nx, hi)
                if hi - nx < 0.2 * (nx - x):
                    nx = hi
                edges.append(nx)
                x = nx
        return np.array(edges)

    def _nodes(self):
        g, w = np.polynomial.legendre.leggauss(_GL_N)
        e = self._edges()
        a, b = e[:-1, None], e[1:, None]
        s = (0.5 * (b - a) * g + 0.5 * (b + a)).ravel()
        wq = (0.5 * (b - a) * w).ravel()
        return s, wq

    # --- профили
    def _bt(self, s):
        """BT и dBT/ds: низ (если оторван) и верх (вливание в голову)."""
        ttop = 1.0 - _ss((s - self.stb) / self.Lt)
        dttop = -_dss((s - self.stb) / self.Lt) / self.Lt
        if self.attached:
            return ttop, dttop
        x = (s - self.sb) / self.Lb
        bb, dbb = _ss(x), _dss(x) / self.Lb
        return bb * ttop, dbb * ttop + bb * dttop

    def _Q_dQ(self, s):
        se = np.sqrt(s * s + _S0 * _S0)
        g1 = s * s * se ** (-1.0 / 3.0)
        dg1 = 2.0 * s * se ** (-1.0 / 3.0) - s ** 3 * se ** (-7.0 / 3.0) / 3.0
        bt, dbt = self._bt(s)
        return self.cq * g1 * bt, self.cq * (dg1 * bt + g1 * dbt)

    def _dQ(self, s):
        return self._Q_dQ(s)[1]

    def G_dG(self, s):
        se = np.sqrt(s * s + _S0 * _S0)
        g0 = s * s * se ** (-7.0 / 3.0)
        dg0 = 2.0 * s * se ** (-7.0 / 3.0) - 7.0 / 3.0 * s ** 3 * se ** (-13.0 / 3.0)
        bt, dbt = self._bt(s)
        return self.kap * g0 * bt, self.kap * (dg0 * bt + g0 * dbt)

    def velocity(self, P: np.ndarray) -> np.ndarray:
        d = P - self.a
        s = d @ self.e
        dperp = d - s[:, None] * self.e
        rho2 = np.einsum("ij,ij->i", dperp, dperp)
        rho = np.sqrt(rho2)
        se = np.sqrt(s * s + _S0 * _S0)
        # огибающая трубки: за концами шлейфа радиус сшивки сходит к нулю (там ψ_in = 0, чужое поле не стирать)
        sb0 = max(self.sb, 0.0)
        Lrl = max(0.5 * sb0, _S0)
        xu, xl = (s - self.L) / self.Lt, (sb0 - s) / Lrl
        W = (1.0 - _ss(xu)) * (1.0 - _ss(xl))
        dW = -_dss(xu) / self.Lt * (1.0 - _ss(xl)) + (1.0 - _ss(xu)) * _dss(xl) / Lrl
        W = np.maximum(W, 1e-3)
        dW = np.where(W > 1e-3, dW, 0.0)
        b = self.k * se * W
        db = self.k * (s / se * W + se * dW)
        inside = (s > self.sb - 1e-12) & (s < self.L)
        G, dG = self.G_dG(s)
        G = np.where(inside, G, 0.0)
        dG = np.where(inside, dG, 0.0)
        t = (rho / b - 1.0) / _BLEND
        chi = 1.0 - _ss(t)
        us = chi * 2.0 * G
        Bs = chi * dG
        far = t > 0.0
        if np.any(far):
            idx = np.nonzero(far)[0]
            for lo in range(0, idx.size, 1500):
                ii = idx[lo:lo + 1500]
                ds = s[ii, None] - self.s[None, :]
                r2 = rho2[ii, None] + ds * ds
                r = np.sqrt(r2)
                m4 = self.m[None, :] / (4.0 * np.pi)
                Aout = np.sum(m4 * ds / r ** 3, axis=1)
                Bout = -np.sum(m4 / r ** 3, axis=1)
                psi_out = -np.sum(m4 * ds / r, axis=1)
                psi_in = G[ii] * rho2[ii]
                sp = _dss(t[ii])
                diff = psi_in - psi_out
                us[ii] = chi[ii] * 2.0 * G[ii] + (1.0 - chi[ii]) * Aout - diff * sp / (_BLEND * b[ii] * rho[ii])
                Bs[ii] = chi[ii] * dG[ii] + (1.0 - chi[ii]) * Bout + diff * sp * db[ii] / (_BLEND * b[ii] ** 2 * rho[ii])
        return -Bs[:, None] * dperp + us[:, None] * self.e[None, :]


def _contribution(P: np.ndarray, st: State) -> np.ndarray:
    v = _hill(P, st) if st.U != 0.0 else np.zeros_like(P)
    if st.F0 > 0.0 and st.zb < st.zc:
        pl = _Plume(st)
        if pl.sb < pl.stb - 1e-6:
            v = v + pl.velocity(P)
    return v


def _images(ground: bool, lid: bool, zi: float):
    """(знак, смещение): образ точки z -> sgn z + off; sgn = −1 — зеркальный (w меняет знак)."""
    if ground and lid:
        out = []
        for n in range(-2, 3):
            out += [(1.0, 2.0 * n * zi), (-1.0, 2.0 * n * zi)]
        return out
    if ground:
        return [(1.0, 0.0), (-1.0, 0.0)]
    if lid:
        return [(1.0, 0.0), (-1.0, 2.0 * zi)]
    return [(1.0, 0.0)]


def velocity(p: np.ndarray, states: Sequence[State], env: Env, *, ground: bool = True, lid: bool = True) -> np.ndarray:
    p = np.asarray(p, dtype=np.float64)
    shape = p.shape
    P = p.reshape(-1, 3)
    out = np.zeros_like(P)
    ok = P[:, 2] >= 0.0
    if lid:
        ok &= P[:, 2] <= env.zi
    idx = np.nonzero(ok)[0]
    if idx.size == 0:
        return out.reshape(shape)
    Pv = P[idx]
    acc = np.zeros_like(Pv)
    imgs = _images(ground, lid, env.zi)
    for st in states:
        for sgn, off in imgs:
            Q = Pv.copy()
            Q[:, 2] = sgn * Pv[:, 2] + off
            v = _contribution(Q, st)
            v[:, 2] *= sgn
            acc += v
    out[idx] = acc
    return out.reshape(shape)
