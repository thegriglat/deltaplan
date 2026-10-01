"""Профиль ветра притока по высоте — эталон той же функции, что `scripts/atmosphere/wind_profile.gd`
(WindProfile, контракт C2 v4): показатель α по устойчивости и насыщение профиля z_sat.

U(z) = U10 (z/10)^α до z_sat, выше — постоянный: max_profile = U(z_sat)/U10 = (z_sat/10)^α (air.wind_profile).

* α = α_N · r(класс), класс Паскуилла–Тёрнера по скорости на 10 м и индексу радиации
  (Turner 1964, «A worksheet for estimating the stability class»; таблица и правила индекса —
  EPA-454/R-99-005, табл. 6-4, 6-5; Pasquill 1961). r — отношения показателей степенного профиля Irwin (1979,
  «A theoretical variation of the wind profile power-law exponent as a function of surface roughness and
  stability», Atmos. Environ. 13, сельская местность: A 0,07, B 0,07, C 0,10, D 0,15, E 0,35, F 0,55) к классу D.
  α_N = configs/atmosphere.json → wind.shear_exponent_neutral (0,24 — совместная калибровка Б1, Askervein).
* z_sat = wind.z_sat_frac · h, h = 0,3 u*/f — толщина нейтрального слоя модели (air._bl_depth), u* = κ U10/ln(10/z0)
  — то же правило, что tools/research/cases/rules.py (C10 v3); для устойчивых E, F h = min(0,3 u*/f, 0,4 √(u* L/f)),
  L по классу и z0 — Golder 1972 (C2 v5).

Индекс радиации (NRI) по Тёрнеру: ночь (от часа до заката до часа после восхода) — облачность ≤ 0,4 → −2, иначе −1;
день — класс инсоляции по высоте солнца (> 60° — 4, 35–60° — 3, 15–35° — 2, ≤ 15° — 1), облачность > 0,5 снижает
его на 2 (нижняя граница облаков < 7000 футов — кучевые и слоистые игры; не ниже 1); сплошная облачность (1,0) — 0.
«Час до заката / после восхода» задан высотой солнца NIGHT_SUN_DEG: в июле на 50° с. ш. (Онгудай) солнце через час
после восхода — ≈ 9°, за час до заката — ≈ 7° (weather.solar_position).
"""
from __future__ import annotations

import json
import math
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

KAPPA = 0.4
H_MECH_C = 0.3          # h = 0,3 u*/f — как air._bl_depth и AirCase.NEUTRAL_BL_K
U10_MIN = 0.5           # нижний предел U10, м/с (порог трогания чашечного анемометра ≤ 0,5 м/с, EPA-454/R-99-005 § 5)
NIGHT_SUN_DEG = 8.0     # ниже — «ночь» Тёрнера (час до заката / после восхода)
CLASSES = "ABCDEF"
IRWIN_RURAL = (0.07, 0.07, 0.10, 0.15, 0.35, 0.55)   # A–F, Irwin 1979
# Turner: строки — скорость на 10 м в узлах (0–1, 2–3, 4–5, 6, 7, 8–9, 10, 11, ≥ 12), столбцы — NRI 4, 3, 2, 1, 0, −1, −2;
# значения — класс 1 (A) … 7 (G); G считается F (у Irwin классов A–F).
TURNER = (
    (1, 1, 2, 3, 4, 6, 7),
    (1, 2, 2, 3, 4, 6, 7),
    (1, 2, 3, 4, 4, 5, 6),
    (2, 2, 3, 4, 4, 5, 6),
    (2, 2, 3, 4, 4, 4, 5),
    (2, 3, 3, 4, 4, 4, 5),
    (3, 3, 4, 4, 4, 4, 5),
    (3, 3, 4, 4, 4, 4, 4),
    (3, 4, 4, 4, 4, 4, 4),
)
KT_EDGES = (1.5, 3.5, 5.5, 6.5, 7.5, 9.5, 10.5, 11.5)   # границы строк в узлах (скорость округляется до целых узлов)
MS_PER_KT = 0.514444


@lru_cache(maxsize=None)
def _wind_cfg():
    return json.loads((ROOT / "configs/atmosphere.json").read_text())["wind"]


def alpha_n():
    return float(_wind_cfg()["shear_exponent_neutral"])


def z_sat_frac():
    return float(_wind_cfg()["z_sat_frac"])


def net_radiation_index(sun_elev_deg, cover):
    if cover >= 1.0:
        return 0
    if sun_elev_deg < NIGHT_SUN_DEG:
        return -2 if cover <= 0.4 else -1
    a = sun_elev_deg
    ic = 4 if a > 60.0 else 3 if a > 35.0 else 2 if a > 15.0 else 1
    if cover > 0.5:
        ic = max(ic - 2, 1)
    return ic


def stability_class(u10, sun_elev_deg, cover):
    """0..5 — A..F."""
    kt = max(u10, 0.0) / MS_PER_KT
    row = sum(1 for e in KT_EDGES if kt >= e)
    nri = net_radiation_index(sun_elev_deg, cover)
    return min(TURNER[row][4 - nri], 6) - 1


def alpha(u10, sun_elev_deg, cover):
    return alpha_n() * IRWIN_RURAL[stability_class(u10, sun_elev_deg, cover)] / IRWIN_RURAL[3]


# Golder (1972): 1/L = a + b·lg z0 по классу A–F (Myrup & Ranzieri 1976; Seinfeld & Pandis, «Atmospheric Chemistry and
# Physics», гл. 16) — длина Обухова для толщины устойчивого слоя (C2 v5).
GOLDER = ((-0.096, 0.029), (-0.037, 0.029), (-0.002, 0.018), (0.0, 0.0), (0.004, -0.018), (0.035, -0.036))
D = 3


def obukhov_inv(cls, z0):
    a, b = GOLDER[cls]
    return a + b * math.log10(z0)


def bl_depth(u10, z0, f_cor, cls=D):
    """Толщина слоя для насыщения профиля: 0,3 u*/f; для устойчивых E, F — не больше 0,4 √(u*·L/f) (Зилитинкевич,
    как air._bl_depth и AirCase._closure)."""
    us = KAPPA * max(u10, U10_MIN) / math.log(10.0 / z0)
    h = H_MECH_C * us / f_cor
    if cls > D:
        h = min(h, 0.4 * math.sqrt(us / obukhov_inv(cls, z0) / f_cor))
    return h


def z_sat(u10, z0, f_cor, cls=D):
    return z_sat_frac() * bl_depth(u10, z0, f_cor, cls)


def max_profile(alpha_v, u10, z0, f_cor, cls=D):
    return (z_sat(u10, z0, f_cor, cls) / 10.0) ** alpha_v


def for_hour(ctx, hour, sky, u10, z0, f_cor):
    """α и max_profile на час места (солнце без запаздывания прогрева — инсоляция в момент), облачность — sky игры.
    → (alpha, max_profile, класс 'A'..'F', высота солнца, °)."""
    import weather as W
    doy = W.day_of_year(ctx["month"], ctx["day"])
    el = W.solar_position(ctx["lat"], ctx["lon"], doy, hour, ctx["utc_offset_h"])[1]
    cover = float(W.CFG["sky"].get(sky, W.CFG["sky"]["clear"]).get("cover", 0.0))
    k = stability_class(u10, el, cover)
    a = alpha(u10, el, cover)
    return a, max_profile(a, u10, z0, f_cor, k), CLASSES[k], el
