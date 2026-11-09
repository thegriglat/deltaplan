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
_S0 = 3.0          # м, сглаживание корня s²+s0² (при виртуальном источнике s ≥ z_v ≫ s0 — не влияет)
_BLEND = 0.5       # ширина сшивки: rho/b от 1 до 1,5
_PANEL = 0.6       # панель квадратуры вдоль шлейфа ≤ _PANEL·b (b — радиус шлейфа)
_GL_N = 8
_T_GROW, _T_MATURE = 180.0, 510.0   # с: середины grow_s [120;240] и mature_s [300;720] ThermalCfg::default игры
_B0_FRAC = 0.102 * 0.1 ** (1.0 / 3.0) * (1.0 - 0.25 * 0.1)   # r₂(ζ = 0,1)/z_l, Allen 2006: 0,0461
_B0_DEF = _B0_FRAC * 1400.0
_END_FRAC = 0.02   # конец жизни, когда оценка амплитуды < 2 % пика (контракт: < 5 %)


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
    b0: float = _B0_DEF   # м, радиус шлейфа у земли (площадной источник; виртуальный источник z_v = 5 b0/(6 α_p))
    t_decay: float = 560.0  # с, время гашения головы у крышки (конвективное время z_i/w*)


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
    Uh: float = -1.0       # сила поля головы (Хилл), м/с; < 0 — равна U. У крышки U → 0, а вихрь гаснет по t_decay
    b0: float = _B0_DEF    # радиус шлейфа у земли, м


def _zv(b0: float) -> float:
    """Виртуальный источник MTT для площадного источника радиуса b0: b = (6/5) α_p (z + z_v) = b0 при z = 0."""
    return 5.0 * b0 / (6.0 * _AL_P)


# ---------------------------------------------------------------- шлейф (MTT)
def _kp(F0: float) -> float:
    """w_p(s) = kp s^(-1/3)."""
    return 5.0 / (6.0 * _AL_P) * (0.9 * _AL_P * F0 / np.pi) ** (1.0 / 3.0)


def _cq(F0: float) -> float:
    """Q_p(s) = cq s^(5/3)."""
    return np.pi * 1.2 * _AL_P * (0.9 * _AL_P * F0 / np.pi) ** (1.0 / 3.0)


def plume_Q(F0: float, s: float) -> float:
    return _cq(F0) * s ** (5.0 / 3.0)


def plume_w(F0: float, z: float) -> float:
    return _kp(F0) * z ** (-1.0 / 3.0)


def _ss(x):
    x = np.clip(x, 0.0, 1.0)
    return x ** 3 * (10.0 - 15.0 * x + 6.0 * x * x)


def _dss(x):
    xc = np.clip(x, 0.0, 1.0)
    return 30.0 * xc ** 2 * (1.0 - xc) ** 2


# ---------------------------------------------------------------- траектория
def _s0(zv: float) -> float:
    """Начало жизни: голова радиуса R = α_h s_c, посаженная на землю (z_c = R), s_c = z_v/(1 − α_h);
    верх головы (фронт) на s_f = (1 + α_h) z_v/(1 − α_h) (при α_h = 0,15, b0 = 65 м: z_f = 158 м)."""
    return (1.0 + _AL_H) * zv / (1.0 - _AL_H)


def _front(F0: float, zv: float, tp: float) -> tuple[float, float]:
    """Фронт стартового факела (Turner 1962) от виртуального источника: s^{4/3} = s_0^{4/3} + (4/3) φ kp t,
    s = z + z_v; возвращает (s_f, ds_f/dt)."""
    kp = _kp(F0)
    s = (_s0(zv) ** (4.0 / 3.0) + 4.0 / 3.0 * _PHI * kp * tp) ** 0.75
    return s, _PHI * kp * s ** (-1.0 / 3.0)


def _raw(src: Source, tp: float) -> tuple[float, float, float]:
    """(zc, R, U) без крышки; tp = t − t0 ≥ 0. Пока источник включён — голова на фронте шлейфа,
    R = α_h (z_c + z_v) (конус от виртуального источника); после — свободный термик R = α_th (z − z_v')."""
    zv = _zv(src.b0)
    k = 1.0 + _AL_H
    if tp <= src.tau:
        sf, vf = _front(src.F0, zv, tp)
        sc = sf / k
        return sc - zv, _AL_H * sc, vf / k
    sf, vf = _front(src.F0, zv, src.tau)
    sc0 = sf / k
    zc0, R0 = sc0 - zv, _AL_H * sc0
    zvt = zc0 - R0 / _AL_T
    K = (vf / k) * (R0 / _AL_T)  # непрерывность U при отрыве; B_head = thermal_B(): см. README
    d = np.sqrt((R0 / _AL_T) ** 2 + 2.0 * K * (tp - src.tau))
    return zvt + d, _AL_T * d, K / d


def thermal_B(src: Source) -> float:
    """Плавучесть головы после отрыва, м⁴/с²: из непрерывности U (U = C sqrt(3B/4pi)/(alpha_th d), K = U d);
    доля от F0·tau — сколько несёт голова, остальное осталось в шлейфе и следе."""
    sf, vf = _front(src.F0, _zv(src.b0), src.tau)
    k = 1.0 + _AL_H
    K = (vf / k) * (_AL_H * sf / k / _AL_T)
    return 4.0 * np.pi / 3.0 * (K * _AL_T / _C_T) ** 2


def _onset(src: Source, tp: float) -> float:
    """Гладкий выход на полную силу за время, пока голова отходит от площадки источника на свой радиус: R₀/U₀."""
    zc, R, U = _raw(src, 0.0)
    return float(_ss(tp / (R / U)))


def _free(src: Source, env: Env, te: float) -> float:
    """Доля свободного подъёма s_f ∈ [0, 1]: гладкая ступень от запаса c = z_i − (z_c + R) на масштабе R."""
    zc, R, _ = _raw(src, te)
    return float(_ss((env.zi - zc - R) / max(R, 1e-9)))


@dataclass(frozen=True)
class _Traj:
    dt: float
    te: np.ndarray       # «собственное» время головы в сетке реального времени
    theta: np.ndarray    # накопленное гашение вихря головы
    zb: np.ndarray       # низ шлейфа после отключения источника
    t_end: float         # с (от t0)


_CACHE: dict = {}


def _traj(src: Source, env: Env) -> _Traj:
    """Таблица траектории с гладкой остановкой у крышки: dte/dt = s_f(te) (время головы замедляется, пока
    запас под крышкой c = z_i − (z_c+R) не станет 0; c→0 как t^(-1/2), крышку не пересекает);
    гашение вихря dθ/dt = (1 − s_f)/t_decay — только у остановившейся головы."""
    key = (src, env)
    tr = _CACHE.get(key)
    if tr is not None:
        return tr
    dt = 1.0
    t_cap = 4.0 * src.tau + 3000.0
    n = int(t_cap / dt) + 2
    te = np.zeros(n)
    th = np.zeros(n)
    zb = np.zeros(n)
    zv, kp = _zv(src.b0), _kp(src.F0)
    t_up = 3.0 * src.b0 / (kp * zv ** (-1.0 / 3.0))
    for i in range(1, n):
        # низ шлейфа: скорость шлейфа w_p(z_b + z_v), разгон по гладкой ступени (иначе поле у земли меняется рывком)
        tm = (i - 0.5) * dt - src.tau
        zm = zb[i - 1] + 0.5 * dt * kp * (zb[i - 1] + zv) ** (-1.0 / 3.0) * float(_ss(tm / t_up))
        zb[i] = zb[i - 1] + dt * kp * (zm + zv) ** (-1.0 / 3.0) * float(_ss(tm / t_up))
        a = te[i - 1]
        k1 = _free(src, env, a)
        k2 = _free(src, env, a + 0.5 * dt * k1)
        te[i] = a + dt * k2
        sf = 0.5 * (k1 + k2)
        th[i] = th[i - 1] + dt * (1.0 - sf) / src.t_decay
    tr = _Traj(dt=dt, te=te, theta=th, zb=zb, t_end=t_cap)
    # конец жизни — по оценке амплитуды
    amp = np.array([_amp(src, env, tr, i * dt) for i in range(n)])
    pk = float(amp.max())
    ipk = int(np.argmax(amp))
    idx = np.nonzero(amp[ipk:] < _END_FRAC * pk)[0]
    t_end = (ipk + int(idx[0])) * dt if idx.size else t_cap
    tr = _Traj(dt=dt, te=te, theta=th, zb=zb, t_end=min(t_end, t_cap))
    _CACHE[key] = tr
    return tr


def _tail(src: Source, zb_t: float, tp: float, zc: float, R: float) -> tuple[float, float]:
    """(zb, f): низ шлейфа и множитель амплитуды f ∈ [0,1] (Q ∝ f, w_p ∝ f; F0_eff = F0 f³):
    гаснет, когда длина шлейфа top − zb меньше ~2R (низ догоняет голову)."""
    if tp <= src.tau:
        return 0.0, 1.0
    top = zc - R
    zb = min(zb_t, top)
    Lf = min(2.0 * R, 0.4 * top)
    f = float(_ss((top - zb) / Lf)) if Lf > 0 else 0.0
    return zb, f


def _amp(src: Source, env: Env, tr: _Traj, tp: float) -> float:
    """Оценка пика возмущения: центр головы 2,5 Uh против шлейфа f·w_p у низа."""
    st = _state_tp(src, env, tr, tp)
    if st is None:
        return 0.0
    uh = st.U if st.Uh < 0 else st.Uh
    wp = 0.0
    if st.F0 > 0.0:
        wp = plume_w(st.F0, st.zb + _zv(st.b0) + st.b0)
    return max(2.5 * uh, wp)


def _state_tp(src: Source, env: Env, tr: _Traj, tp: float) -> State | None:
    te = float(np.interp(tp, np.arange(tr.te.size) * tr.dt, tr.te))
    th = float(np.interp(tp, np.arange(tr.te.size) * tr.dt, tr.theta))
    zbt = float(np.interp(tp, np.arange(tr.te.size) * tr.dt, tr.zb))
    zc, R, Ur = _raw(src, te)
    sf = float(_ss((env.zi - zc - R) / max(R, 1e-9)))
    zb, f = _tail(src, zbt, tp, zc, R)
    on = _onset(src, tp)
    f *= on
    F0 = src.F0 * f ** 3
    top = zc - R + _zv(src.b0)
    Q = _cq(F0) * top ** (5.0 / 3.0) if F0 > 0.0 else 0.0
    xc = src.x + env.wind[0] * tp
    yc = src.y + env.wind[1] * tp
    return State(xs=xc, ys=yc, xc=xc, yc=yc, zc=zc, R=R, U=float(Ur * sf), Q=Q, F0=F0, zb=zb,
                 Uh=float(Ur * on * np.exp(-th)), b0=src.b0)


def state(src: Source, env: Env, t: float) -> State | None:
    tp = t - src.t0
    if tp <= 0.0:
        return None
    tr = _traj(src, env)
    if tp >= tr.t_end:
        return None
    return _state_tp(src, env, tr, tp)


def from_game(x: float, y: float, t0: float, wstar: float, zl: float, env: Env) -> Source:
    """F0 = (w*^3/z_l) / n_A, n_A = 8,5/z_l^2 (Дирдорф 1970; Аллен 2006): F0 = w*^3 z_l / 8,5.
    tau — время работы источника: ДОПУЩЕНИЕ (не вывод из баланса): рост + зрелость термика игры
    (ThermalCfg::default: grow_s 120–240, mature_s 300–720, середины 180 + 510 = 690 с).
    b0 — радиус шлейфа у земли = радиус ядра Аллена r₂(ζ = 0,1) = 0,0461 z_l (Allen 2006).
    t_decay — время гашения головы у крышки: конвективное время z_l/w* (Lenschow–Stephens: жизнь термика ~ z_i/w*)."""
    F0 = wstar ** 3 * zl / 8.5
    return Source(x=x, y=y, t0=t0, F0=F0, tau=_T_GROW + _T_MATURE, b0=_B0_FRAC * zl, t_decay=zl / wstar)


# ---------------------------------------------------------------- вклад одного пузыря
def _hill(P, st: State) -> np.ndarray:
    dx, dy, s = P[:, 0] - st.xc, P[:, 1] - st.yc, P[:, 2] - st.zc
    r2 = dx * dx + dy * dy + s * s
    rho2 = dx * dx + dy * dy
    U, R = (st.U if st.Uh < 0.0 else st.Uh), st.R
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
    """Шлейф одного State: вертикальная ось через (xc, yc), начало координат s — виртуальный источник
    на глубине z_v под землёй (s = z + z_v)."""

    def __init__(self, st: State):
        self.zv = _zv(st.b0)
        self.a = np.array([st.xc, st.yc, -self.zv])
        self.L = st.zc + self.zv
        self.sb = st.zb + self.zv
        self.stb = st.zc - st.R + self.zv
        self.cq = _cq(st.F0)
        self.Lb = max(st.b0, 0.5 * st.zb)
        self.Lt = st.R
        self.k = 1.2 * _AL_P
        self.kap = self.cq / (2.0 * np.pi * self.k ** 2)
        self.s, self.wq = self._nodes()
        self.m = -self._dQ(self.s) * self.wq  # сила точечных источников (отрицательная — сток)

    def _edges(self) -> np.ndarray:
        pts = sorted({self.sb, self.sb + self.Lb, self.stb, self.L})
        edges = [pts[0]]
        for lo, hi in zip(pts[:-1], pts[1:]):
            if hi - lo <= 0.0:
                continue
            h = _PANEL * self.k * 0.5 * (lo + hi)
            n = max(int(np.ceil((hi - lo) / h)), 2)
            edges.extend(np.linspace(lo, hi, n + 1)[1:])
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
        """BT и dBT/ds: низ (подъём Q от нуля — приток у земли / оторванный низ) и верх (вливание в голову)."""
        ttop = 1.0 - _ss((s - self.stb) / self.Lt)
        dttop = -_dss((s - self.stb) / self.Lt) / self.Lt
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

    def _sums(self, rho2, s, want_psi):
        """Сумма по узлам-стокам: (u_s, B, psi) на точках (rho2, s); u_s = Σ m/(4π) ds/r³, B = −Σ m/(4π r³),
        ψ = −Σ m/(4π) ds/r (ψ_s = B ρ², ψ_ρ = ρ u_s)."""
        As = np.empty_like(s)
        Bs = np.empty_like(s)
        Ps = np.empty_like(s) if want_psi else None
        m4 = self.m[None, :] / (4.0 * np.pi)
        for lo in range(0, s.size, 1500):
            sl = slice(lo, lo + 1500)
            ds = s[sl, None] - self.s[None, :]
            r = np.sqrt(rho2[sl, None] + ds * ds)
            As[sl] = np.sum(m4 * ds / r ** 3, axis=1)
            Bs[sl] = -np.sum(m4 / r ** 3, axis=1)
            if want_psi:
                Ps[sl] = -np.sum(m4 * ds / r, axis=1)
        return As, Bs, Ps

    def velocity(self, P: np.ndarray) -> np.ndarray:
        """ψ = χ ψ_in + (1−χ) ψ_out; ψ_out — сумма стоков (потенциальный приток), ψ_in = G(s) ρ² — труба,
        G(s) = ψ_out(b(s), s)/b(s)²: поток трубы берётся из самого внешнего решения на её границе, поэтому
        сшивка согласована и на концах (где Q меняется на масштабе b), а в середине G = Q/(2π b²) (w = w_p)."""
        d = P - self.a
        s = d[:, 2]
        rho2 = d[:, 0] ** 2 + d[:, 1] ** 2
        rho = np.sqrt(rho2)
        se = np.sqrt(s * s + _S0 * _S0)
        b = self.k * se
        db = self.k * s / se
        t = (rho / b - 1.0) / _BLEND
        chi = 1.0 - _ss(t)
        us = np.zeros_like(s)
        Bs = np.zeros_like(s)
        near = t < 1.0
        far = t > 0.0
        if np.any(near):
            i = np.nonzero(near)[0]
            bi, dbi = b[i], db[i]
            A, B, ps = self._sums(bi * bi, s[i], True)
            G = ps / bi ** 2
            dG = B + A * dbi / bi - 2.0 * ps * dbi / bi ** 3
            us[i] = chi[i] * 2.0 * G
            Bs[i] = chi[i] * dG
            Gn = np.zeros_like(s); Gn[i] = G
            dGn = np.zeros_like(s); dGn[i] = dG
        else:
            Gn = np.zeros_like(s); dGn = Gn
        if np.any(far):
            j = np.nonzero(far)[0]
            Aout, Bout, psi_out = self._sums(rho2[j], s[j], True)
            psi_in = Gn[j] * rho2[j]
            sp = _dss(t[j])
            diff = psi_in - psi_out
            us[j] = chi[j] * 2.0 * Gn[j] + (1.0 - chi[j]) * Aout - diff * sp / (_BLEND * b[j] * rho[j])
            Bs[j] = chi[j] * dGn[j] + (1.0 - chi[j]) * Bout + diff * sp * db[j] / (_BLEND * b[j] ** 2 * rho[j])
        out = -Bs[:, None] * d
        out[:, 2] = us
        out[:, 0] = -Bs * d[:, 0]
        out[:, 1] = -Bs * d[:, 1]
        return out


def _contribution(P: np.ndarray, st: State) -> np.ndarray:
    uh = st.U if st.Uh < 0.0 else st.Uh
    v = _hill(P, st) if uh != 0.0 else np.zeros_like(P)
    if st.F0 > 0.0 and st.zb < st.zc - 1e-6:
        v = v + _Plume(st).velocity(P)
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
