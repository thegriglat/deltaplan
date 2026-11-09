"""Шаблон пузыря-термика (TB1 v3): голова Хилла + шлейф Тёрнера + отражения, функция тока Стокса.

Только numpy. Контракт: docs/contracts/thermal-bubble.md, раздел TB1. Ось z вверх, земля z = 0.

Поле каждого пузыря — сумма осесимметричных вкладов, каждый выражен через функцию тока Стокса
psi(rho, s): u_rho = -(1/rho) d psi/ds, u_s = (1/rho) d psi/d rho  =>  div v = 0 тождественно.
  * голова — сферический вихрь Хилла (вертикальная ось через центр головы); v3: край r = R сглажен в оболочке
    толщиной hill_shell·R смешиванием функций тока ψ = (1 − s)ψ_in + s ψ_out (s — квинтика), а не скоростей;
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
# --- ядро по измерениям (Q1 п. 1, 2026-11-09): радиус головы растёт с высотой, как измеренный радиус ядра в слое конвекции.
# Lenschow & Stephens 1980: диаметр ядра d/z_i = 0,16 ζ^⅓(1 − 0,25ζ) (самолёт, условная выборка), радиус ядра r = d/2.
# Радиус ядра в шаблоне и в эталоне — ПЕРВАЯ СМЕНА ЗНАКА w на горизонтали через центр головы: у вихря Хилла на
# экваторе w = U(5/2 − 3ρ²/R²) ⇒ r_sign = sqrt(5/6) R = 0,9129 R. Поэтому R(ζ) = r_LS(ζ)/0,9129, линейная МНК-подгонка
# R = α(z + z_h) на ζ = 0,2…0,8 (25 точек): α = dR/dz головы, z_h — глубина вершины конуса под землёй (∝ z_i).
_HILL_SHELL = 0.2     # PARAMS["hill_shell"]: см. там


def _eq_w(x: float, shell: float) -> float:
    """w/U на экваторе головы (R = 1, U = 1) при ρ = x: w = 2g + ρ g'(r)·ρ/r с r = ρ (s_z = 0)."""
    r1, r2 = 1.0 - 0.5 * shell, 1.0 + 0.5 * shell
    u = min(max((x - r1) / (r2 - r1), 0.0), 1.0)
    sm = u ** 3 * (10.0 - 15.0 * u + 6.0 * u * u)
    dsm = 30.0 * u ** 2 * (1.0 - u) ** 2 / (r2 - r1)
    xs = max(x, r1)
    g_in, g_out = 1.25 - 0.75 * x * x, 0.5 / xs ** 3
    dgr = (1.0 - sm) * (-1.5) + sm * (-1.5 / xs ** 5) + dsm * (g_out - g_in) / xs
    return 2.0 * ((1.0 - sm) * g_in + sm * g_out) + x * x * dgr


def _sign_over_r(shell: float) -> float:
    """Радиус смены знака w на экваторе / R (бисекция). Хилл без оболочки: sqrt(5/6) = 0,9129."""
    lo, hi = 0.5, 1.5
    for _ in range(60):
        mid = 0.5 * (lo + hi)
        lo, hi = (mid, hi) if _eq_w(mid, shell) > 0.0 else (lo, mid)
    return 0.5 * (lo + hi)


_SIGN_OVER_R = _sign_over_r(_HILL_SHELL)


def _fit_core(c_d: float = 0.16) -> tuple[float, float]:
    zeta = np.linspace(0.2, 0.8, 25)
    r = 0.5 * c_d * zeta ** (1.0 / 3.0) * (1.0 - 0.25 * zeta) / _SIGN_OVER_R      # R/z_i по LS
    slope, icpt = np.polyfit(zeta, r, 1)
    return float(slope), float(icpt / slope)


_ALPHA_TH, _ZH_FRAC = _fit_core()                  # α = dR/dz (≈ 0,027), z_h/z_i (≈ 1,6)
_ALPHA_ALLEN, _ZH_FRAC_ALLEN = _fit_core(0.204)    # Аллен 2006: r₂ = 0,102 ζ^⅓(1 − 0,25ζ) z_l (справка, чувствительность)
_K_ADDED = 0.5
_A_CORE, _A_UP = 0.13, 0.35                        # доли площади: ядра Аллена; воздух подъёма (L&S 1980, Stull 1988)
_CORE_FLUX_FRAC = _A_CORE / _A_UP                  # 0,371
PARAMS: dict[str, dict] = {
    "alpha_thermal": {
        "value": _ALPHA_TH, "unit": "1 (dR/dz головы, R — радиус Хилла)", "reliability": "medium",
        "source": "Lenschow & Stephens 1980 (Boundary-Layer Meteorol. 19, 509): d/z_i = 0,16 ζ^⅓(1−0,25ζ), самолёт, условная выборка "
                  "ядер, радиус ядра = d/2 = радиус смены знака w (у Хилла sqrt(5/6)R = 0,913R, со сглаженным краем hill_shell 0,2 — %.3fR, считается в коде); линейная МНК R = α(z + z_h) на ζ 0,2–0,8; "
                  "z_h = %.2f z_i. Аллен 2006 (AIAA 2006-1510) r₂ = 0,102ζ^⅓(1−0,25ζ): α = %.3f (в %.2f раза больше)"
                  % (_SIGN_OVER_R, _ZH_FRAC, _ALPHA_ALLEN, _ALPHA_ALLEN / _ALPHA_TH),
    },
    "alpha_thermal_lab": {
        "value": 0.25, "unit": "1 (dR/dz)", "reliability": "medium",
        "source": "справка, в расчёте не участвует: Scorer 1957 (J. Fluid Mech. 2, 583); Morton, Taylor & Turner 1956 (Proc. R. Soc. A 234, 1); "
                  "Turner 1969 (Ann. Rev. Fluid Mech. 1, 29); лаборатория 0,25–0,34 (обзор arXiv:astro-ph/0008099)",
    },
    "core_flux_fraction": {
        "value": _CORE_FLUX_FRAC, "unit": "1 (доля потока плавучести водосбора, несомая ядром)", "reliability": "low",
        "source": "вывод без прямого измерения: доля площади ядер Аллена 2006 (0,13) / доля площади подъёма Lenschow & Stephens 1980, "
                  "Stull 1988 гл. 4 (0,35) = 0,37 при равном среднем w·θ′ ядра и остального подъёма; сильнее среднего — больше "
                  "(ядро вдвое сильнее ⇒ 0,70); совпадает с 37–45 % Φ днём в AM-07б; выкладка — README",
    },
    "hill_shell": {
        "value": _HILL_SHELL, "unit": "1 (доля R, полная толщина оболочки)", "reliability": "low",
        "source": "решение Q1 2026-11-09, ~0,2R; метрика инварианта 10 на экваторе при 0,2 ≈ 1,02 (порог TB1 v4 ≤ 1,2; излом Хилла 7,5); литература — разрежённый край вихревого кольца (Lecoanet & Jeevanjee 2019, "
                  "arXiv:1804.09326): непрерывная граница головы; число не измерено",
    },
    "added_mass_k": {
        "value": _K_ADDED, "unit": "1", "reliability": "high",
        "source": "присоединённая масса шара = 1/2 объёма (Lamb, Hydrodynamics, §92; Batchelor 1967, §6.4); "
                  "использована Тёрнером 1964 для термиков, ускорение шара 2B/3 при начале подъёма",
    },
    "C_thermal": {
        "value": 1.0 / np.sqrt(2.0 * (1.0 + _K_ADDED) * _ALPHA_TH), "unit": "1 (U = C sqrt(g' R))",
        "reliability": "low",
        "source": "вывод из импульса (1+k) d(V U)/dt = B при R = alpha (z + z_h), B = g'V = const (Scorer 1957; "
                  "Turner 1964, 1969): U = C sqrt(g'R), C = [2(1+k) alpha]^(-1/2); со сниженным измеренным α подобие Скорера "
                  "применено вне лабораторного диапазона; в динамике не участвует (K берётся из U при отрыве), только thermal_B; НЕ подогнано",
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
        "source": "справка v2, в v3 не участвует (радиус головы везде по измеренному alpha_thermal): Turner 1962 (J. Fluid Mech. 13, 356): "
                  "шляпа стартового факела расширяется чуть больше чем на половину угла термика; число — оценка по фразе",
    },
    "plume_top_hat": {
        "value": 1.0, "unit": "1 (флаг: MTT с плоским профилем)", "reliability": "high",
        "source": "Morton, Taylor & Turner 1956: b = (6/5) alpha z, w = (5/(6 alpha)) (9 alpha F/(10 pi))^(1/3) z^(-1/3), "
                  "Q = pi b^2 w ~ z^(5/3) (F — полный поток плавучести g'Q, без деления на pi в F/pi)",
    },
}

_AL_P = PARAMS["alpha_plume"]["value"]
_AL_T = PARAMS["alpha_thermal"]["value"]
_C_T = PARAMS["C_thermal"]["value"]
_PHI = PARAMS["front_fraction"]["value"]
_CFF = PARAMS["core_flux_fraction"]["value"]
_SHELL = PARAMS["hill_shell"]["value"]

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
    zh: float = _ZH_FRAC * 1400.0   # м, вершина конуса головы под землёй: R = α(z + z_h), z_h = _ZH_FRAC·z_l


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
def _s0(zv: float, zh: float) -> float:
    """Начало жизни (s = z + z_v): голова радиуса R = α(z_c + z_h), посаженная на землю (z_c = R = α z_h/(1 − α)),
    верх головы (фронт) z_f = z_c + R."""
    zc0 = _AL_T * zh / (1.0 - _AL_T)
    return 2.0 * zc0 + zv


def _front(F0: float, zv: float, zh: float, tp: float) -> tuple[float, float]:
    """Фронт стартового факела (Turner 1962) от виртуального источника: s^{4/3} = s_0^{4/3} + (4/3) φ kp t,
    s = z + z_v; возвращает (s_f, ds_f/dt)."""
    kp = _kp(F0)
    s = (_s0(zv, zh) ** (4.0 / 3.0) + 4.0 / 3.0 * _PHI * kp * tp) ** 0.75
    return s, _PHI * kp * s ** (-1.0 / 3.0)


def _head_from_front(zf: float, vf: float, zh: float) -> tuple[float, float, float]:
    """(zc, R, U) головы по фронту: верх головы z_f = z_c + R, R = α(z_c + z_h) ⇒ z_c = (z_f − α z_h)/(1 + α)."""
    zc = (zf - _AL_T * zh) / (1.0 + _AL_T)
    return zc, _AL_T * (zc + zh), vf / (1.0 + _AL_T)


def _raw(src: Source, tp: float) -> tuple[float, float, float]:
    """(zc, R, U) без крышки; tp = t − t0 ≥ 0. Радиус головы всегда R = α(z_c + z_h) (измеренный рост ядра, v3).
    Пока источник включён — голова на фронте шлейфа; после — свободный термик, U (z_c + z_h) = K (подобие Скорера)."""
    zv = _zv(src.b0)
    if tp <= src.tau:
        sf, vf = _front(src.F0, zv, src.zh, tp)
        return _head_from_front(sf - zv, vf, src.zh)
    sf, vf = _front(src.F0, zv, src.zh, src.tau)
    zc0, R0, U0 = _head_from_front(sf - zv, vf, src.zh)
    d0 = zc0 + src.zh
    K = U0 * d0     # непрерывность U при отрыве; B_head = thermal_B(): см. README
    d = np.sqrt(d0 ** 2 + 2.0 * K * (tp - src.tau))
    return d - src.zh, _AL_T * d, K / d


def thermal_B(src: Source) -> float:
    """Плавучесть головы после отрыва, м⁴/с²: из непрерывности U (U = C sqrt(3B/4pi)/(alpha_th d), K = U d);
    доля от F0·tau — сколько несёт голова, остальное осталось в шлейфе и следе."""
    sf, vf = _front(src.F0, _zv(src.b0), src.zh, src.tau)
    zc0, R0, U0 = _head_from_front(sf - _zv(src.b0), vf, src.zh)
    K = U0 * (zc0 + src.zh)
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
    """v3: F0 = core_flux_fraction · (w*^3/z_l) · z_l²/8,5 = core_flux_fraction · w*^3 z_l / 8,5
    (Дирдорф 1970: (g/θ0)H_kin = w*^3/z_l; Аллен 2006: n_A = 8,5/z_l² ядер на м²; ядро несёт измеренную долю потока водосбора).
    tau — время работы источника: ДОПУЩЕНИЕ (не вывод из баланса): рост + зрелость термика игры
    (ThermalCfg::default: grow_s 120–240, mature_s 300–720, середины 180 + 510 = 690 с).
    b0 — радиус шлейфа у земли = радиус ядра Аллена r₂(ζ = 0,1) = 0,0461 z_l (Allen 2006).
    t_decay — время гашения головы у крышки: конвективное время z_l/w* (Lenschow–Stephens: жизнь термика ~ z_i/w*).
    zh — вершина конуса головы: z_h = _ZH_FRAC·z_l (подгонка L&S, см. PARAMS)."""
    F0 = _CFF * wstar ** 3 * zl / 8.5
    return Source(x=x, y=y, t0=t0, F0=F0, tau=_T_GROW + _T_MATURE, b0=_B0_FRAC * zl, t_decay=zl / wstar,
                  zh=_ZH_FRAC * zl)


K_ALLEN = 1.2436   # сила ядра на пике / w* клетки (Аллен 2006 × e·0,4575, thermal_air/mod.rs); v5


def from_game_strength(x: float, y: float, t0: float, strength: float, zl: float, tau: float, env: Env) -> Source:
    """v5: источник термика игры из бюджета потока (TB-10, round3/life.md), не из пика на оси: w* клетки = strength / K_ALLEN,
    F0 = core_flux_fraction · w*³ · z_l / 8,5 (то есть from_game(x, y, t0, strength / K_ALLEN, zl, env)) с tau термика.
    Пик w на оси при этом выше strength (≈ +25 %, 2,5·U Хилла): сила игры — сила клетки, а не ядра пузыря."""
    import dataclasses

    return dataclasses.replace(from_game(x, y, t0, strength / K_ALLEN, zl, env), tau=tau)


def _axis_wmax(src: Source, env: Env, dt: float = 10.0, dz: float = 5.0) -> float:
    """Максимум w на оси за жизнь: моменты шагом dt до конца жизни, ось z = 1…z_i шагом dz (как в контрактном тесте)."""
    tr = _traj(src, env)
    z = np.arange(1.0, env.zi + 1e-9, dz)
    best = 0.0
    for t in np.arange(src.t0 + dt, src.t0 + tr.t_end, dt):
        st = state(src, env, float(t))
        if st is None:
            break
        P = np.stack([np.full_like(z, st.xc), np.full_like(z, st.yc), z], -1)
        best = max(best, float(velocity(P, [st], env)[:, 2].max()))
    return best


def from_strength(x: float, y: float, t0: float, w0: float, zl: float, tau: float, env: Env) -> Source:
    """Источник по силе термика игры: F0 подобран так, что максимум w на оси за жизнь = w0 (отн. ошибка ≤ 2 %, сходимость ≤ 0,3 %).
    Шлейф ∝ F0^⅓, голова иначе (U — из фронта, ∝ F0^⅓ тоже, но Хилл + крышка + шлейф-голова нелинейны) — точной степени нет;
    max w монотонен по F0: секущая по log F0 (старт — степень ⅓ от from_game), затем бисекция по скобке.
    Остальное — как from_game (b0, zh — по zl; t_decay = 1,24·z_l/w0 — в игре w0 = 1,24 w*)."""
    import dataclasses

    base = from_game(x, y, t0, w0 / 1.24, zl, env)
    base = dataclasses.replace(base, tau=tau)
    key = (x, y, t0, round(w0, 12), zl, tau, env)
    hit = _FS_CACHE.get(key)
    if hit is not None:
        return hit

    def f(lf: float) -> float:
        return np.log(_axis_wmax(dataclasses.replace(base, F0=float(np.exp(lf))), env) / w0)

    lf = float(np.log(base.F0))
    e = f(lf)
    pts = [(lf, e)]
    for _ in range(14):
        if abs(e) < 0.003:
            break
        step = 3.0 * (-e) if len(pts) == 1 else None
        if len(pts) == 1:
            nl = lf + step                          # w ∝ F0^⅓ ⇒ Δlog F0 = 3 Δlog w
        else:
            (la, ea), (lb, eb) = pts[-2], pts[-1]
            nl = lb - eb * (lb - la) / (eb - ea) if abs(eb - ea) > 1e-12 else lb - 3.0 * eb
            nl = float(np.clip(nl, lb - 2.0, lb + 2.0))
        lf, e = nl, f(nl)
        pts.append((lf, e))
    best = min(pts, key=lambda p: abs(p[1]))
    out = dataclasses.replace(base, F0=float(np.exp(best[0])))
    _FS_CACHE[key] = out
    return out


_FS_CACHE: dict = {}
_KBAR_CACHE: dict = {}


def mean_up_flux(w0: float, zl: float, tau: float, env: Env) -> float:
    """Средний по жизни (t0…конец) и по столбу 0…zl поток вверх ∫max(w,0)dA, м³/с, одного пузыря from_game_strength(w0, zl, tau) (v5).
    Сечения z — середины 28 слоёв, t — шаг 30 с, ρ до 900 м (положительная область головы и шлейфа; дальше w ≤ 0),
    91 узел трапеций, плотнее у оси. Ветер сносит всё целиком — считаем без него."""
    import dataclasses

    envn = dataclasses.replace(env, wind=(0.0, 0.0))
    key = (round(w0, 12), zl, tau, envn)
    hit = _KBAR_CACHE.get(key)
    if hit is not None:
        return hit
    src = from_game_strength(0.0, 0.0, 0.0, w0, zl, tau, envn)
    tr = _traj(src, envn)
    nz = 28
    zs = (np.arange(nz) + 0.5) * zl / nz
    rho = np.unique(np.concatenate([np.linspace(0.0, 150.0, 46), np.linspace(150.0, 900.0, 45)[1:]]))
    P = np.zeros((nz, rho.size, 3))
    P[..., 0] = rho[None, :]
    P[..., 2] = zs[:, None]
    ts = np.arange(15.0, tr.t_end, 30.0)
    acc = []
    for t in ts:
        st = state(src, envn, float(t))
        if st is None:
            acc.append(0.0)
            continue
        w = velocity(P, [st], envn)[..., 2]
        f = np.trapezoid(np.maximum(w, 0.0) * 2.0 * np.pi * rho[None, :], rho, axis=1)
        acc.append(float(f.mean()))
    out = float(np.mean(acc))        # равномерная сетка по жизни t0…t_end
    _KBAR_CACHE[key] = out
    return out


def kbar(zl: float, tau: float, env: Env, w0: float) -> float:
    """K̄ шаблона, м² (v5): средний по жизни и по столбу 0…zl поток вверх пузыря from_game_strength(w0, zl, tau), делённый на w0
    (см. mean_up_flux). Поток растёт с силой нелинейно (жизнь и подобие зависят от F0), поэтому w0 — сила типичного случая."""
    return mean_up_flux(w0, zl, tau, env) / w0


_BETWEEN_Q: list[float] = [
    0.0, 0.44752177774714036, 0.6993158433474265,
    0.8612045799163561, 0.9903752896003891, 1.1005690914326385,
    1.1955613537459822, 1.2918692699459584, 1.3412936555374746,
    1.362374318722942, 1.3960947044475158, 1.4115065216280567,
    1.3845375229406574, 1.3411277867302769, 1.273907268809101,
    1.1484386629963692, 0.9807275423890559, 0.7836072430932367,
    0.6236477158461969, 0.365879671545737, 0.0008803591549801406,
]   # round3/between.py (v5, TB-15): 21 узел ξ = 0…1, среднее по трапециям = 1; --check сверяет


def between_q_nodes() -> list[float]:
    return list(_BETWEEN_Q)


def between_q(xi: float) -> float:
    """v5: профиль «между» q(ξ), ξ = z/z_l ∈ [0, 1], среднее по ξ = 1: средний по жизни поток вверх пузыря
    from_game_strength (TB-12 на v5, round3/between.py), 21 узел, линейно между узлами; вне [0, 1] — край."""
    n = len(_BETWEEN_Q) - 1
    f = min(max(xi, 0.0), 1.0) * n
    i = min(int(f), n - 1)
    return float(_BETWEEN_Q[i] + (f - i) * (_BETWEEN_Q[i + 1] - _BETWEEN_Q[i]))


# ---------------------------------------------------------------- вклад одного пузыря
def _hill(P, st: State) -> np.ndarray:
    """Голова: ψ = ρ² g(r), g = (1 − s) g_in + s g_out; r ∈ [R(1 − δ/2), R(1 + δ/2)] — оболочка сглаживания (δ = hill_shell),
    s — квинтика 6x⁵ − 15x⁴ + 10x³ (C²). g_in = U(5/4 − 3r²/4R²), g_out = (U/2)R³/r³ (Хилл). w = 2g + ρ² g'/r,
    u_ρ = −ρ s_z g'/r ⇒ ∇·v = 0 тождественно; вне оболочки — Хилл как есть."""
    dx, dy, sz = P[:, 0] - st.xc, P[:, 1] - st.yc, P[:, 2] - st.zc
    rho2 = dx * dx + dy * dy
    r2 = rho2 + sz * sz
    U, R = (st.U if st.Uh < 0.0 else st.Uh), st.R
    r1, r2o = R * (1.0 - 0.5 * _SHELL), R * (1.0 + 0.5 * _SHELL)
    r = np.sqrt(r2)
    rs = np.maximum(r, r1)                 # g_out нужна только при r ≥ r1 (s = 0 ниже); без деления на ноль в центре
    x = np.clip((r - r1) / (r2o - r1), 0.0, 1.0)
    sm = x ** 3 * (10.0 - 15.0 * x + 6.0 * x * x)
    dsm = 30.0 * x ** 2 * (1.0 - x) ** 2 / (r2o - r1)
    g_in = U * (1.25 - 0.75 * r2 / (R * R))
    g_out = 0.5 * U * R ** 3 / rs ** 3
    g = (1.0 - sm) * g_in + sm * g_out
    # g'(r)/r: внутри g_in'/r = −1,5U/R²; g_out'/r = −1,5U R³/r⁵; s' (g_out − g_in)/r — только в оболочке (r ≥ r1 > 0)
    dgr = (1.0 - sm) * (-1.5 * U / (R * R)) + sm * (-1.5 * U * R ** 3 / rs ** 5) + dsm * (g_out - g_in) / rs
    out = np.empty_like(P)
    out[:, 0] = -sz * dgr * dx
    out[:, 1] = -sz * dgr * dy
    out[:, 2] = 2.0 * g + rho2 * dgr
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
