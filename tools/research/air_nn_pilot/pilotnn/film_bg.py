"""P3E6: числа фоновой стратификации для FiLM — восстановление профиля θ̄(z) решателя по условиям случая.

Откуда профиль. Решатель (air3d/air.py, Case.gam) берёт dθ̄/dz(z) как функцию `weather.Day.gamma` дня случая:
`real.case(loc, g, hc, hour, U10, wdir, t_max, sky, heat)` → `Case(gam=D.gamma, z_i=D.z_i, …)`, D = `weather.Day(hour,
t_max, sky, ctx)`; один и тот же профиль — в решении «с нагревом» и «без» (airlite_gen.solve_case). В метаданных случая
профиль не хранится — только `day = Day.summary()` (z_i, z_lcl, долина, t, cap, brk, heat; округлено). Здесь Day
восстанавливается тем же кодом: ctx — из строки случая (`ctx`, набор terrain) или `places.context(loc)` (набор main),
как у генератора; совпадение с `day` проверяется (`check_day`).

Профиль (weather.py): свободная атмосфера dθ/dz = Γd − γ = 9,8 − 4 = 5,8 К/км (одна на все случаи, месяц фиксирован
reference_context); до пика прогрева (cap конечен) — ночная инверсия от дна долины (градиент (T_full − T_min)/0,5 км),
остаточный нейтральный слой, затем свободная атмосфера; слой перемешивания (до z_i) — нейтральный (0).

Числа (FILM_BG_NAMES, добавляются к 18 числам П2 после них; нормировки — константы):
  gam_<a>  dθ̄/dz на высоте a над средней высотой рельефа области (a = BG_LEVELS), К/км / NORM_GAM_KKM;
  N_bl     средняя N = sqrt(g/θ0·max(dθ̄/dz, 0)) на z_i…z_i + 1500 м (θ0 = 300 К, как решатель), 1/с / NORM_N;
  Fr       U/(N_bl·H): U = U10·max_profile (насыщенный профиль притока, выше z_sat ≈ 100 м), H — размах рельефа
           области (max − min hc 400 м), обрезано сверху FR_MAX (штиль — 0).
Все — скаляры, при отражении поперёк ветра знак не меняется (REFLECT_FILM_SIGN = +1).
"""
from __future__ import annotations

import math

import numpy as np

BG_LEVELS = (100, 300, 600, 1000, 1500, 2000, 3000)        # м над средней высотой рельефа области
FILM_BG_NAMES = tuple(f"gam_{a}" for a in BG_LEVELS) + ("N_bl", "Fr")
NORM_GAM_KKM = 10.0
NORM_N = 0.02
FR_MAX = 3.0
N_LAYER_M = 1500.0
G_OVER_TH0 = 9.81 / 300.0                                   # как air.py (kloc: N2 = 9,81/300·(gam + dθ))


def day_of(row):
    """weather.Day случая тем же кодом, что генератор. ctx — из строки (terrain) или places.context (main)."""
    import places as PL          # noqa: F401  (подменяет real.context; sys.path — air_nn_pilot и air3d)
    import weather as W
    ctx = row.get("ctx")
    if not ctx:
        ctx = PL.context(row["loc"])
    else:
        ctx = dict(ctx)
    return W.Day(float(row["hour"]), float(row["t_max"]), str(row["sky"]), ctx)


def check_day(D, row):
    """Сравнение восстановленного Day с `day` метаданных (округление summary) → dict расхождений (пусто — совпало)."""
    s = D.summary()
    ref = row.get("day") or {}
    bad = {}
    for k in ("t", "z_i_msl", "z_dry_game_msl", "z_lcl_msl", "valley_msl", "heat", "brk"):
        a, b = s.get(k), ref.get(k)
        if b is None:
            continue
        tol = 1.0 if k.endswith("msl") else 0.011
        if abs(float(a) - float(b)) > tol:
            bad[k] = (a, b)
    ca, cb = s.get("cap_agl"), ref.get("cap_agl")
    fa = ca is not None and math.isfinite(ca)
    fb = cb is not None and math.isfinite(float(cb))
    if fa != fb or (fa and abs(ca - float(cb)) > 1.0):
        bad["cap_agl"] = (ca, cb)
    return bad


def bg_raw(D, hc, U10, mp):
    """Сырые числа фона: gam (К/км) на BG_LEVELS, N_bl (1/с), Fr, U, H, hm."""
    hc = np.asarray(hc, np.float64)
    hm = float(hc.mean())
    H = float(hc.max() - hc.min())
    gam = [float(D.gamma(hm + a)) * 1000.0 for a in BG_LEVELS]
    z = D.z_i + np.linspace(0.0, N_LAYER_M, 301)
    g = np.maximum(np.asarray(D.gamma(z), float), 0.0)
    N = float(np.mean(np.sqrt(G_OVER_TH0 * g)))
    U = float(U10) * float(mp)
    Fr = min(U / (N * max(H, 1.0)), FR_MAX) if N > 0 else FR_MAX
    return dict(gam_kkm=gam, N_bl=N, Fr=Fr, U=U, H=H, hm=hm, z_i_agl=float(D.z_i - hm))


def bg_film(raw):
    """Сырые → нормированные числа FiLM (порядок FILM_BG_NAMES), float32."""
    v = [x / NORM_GAM_KKM for x in raw["gam_kkm"]] + [raw["N_bl"] / NORM_N, raw["Fr"]]
    return np.asarray(v, np.float32)
