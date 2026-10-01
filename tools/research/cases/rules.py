"""Общие правила постановки случаев калибровки (волна Б, Б1) — контракт C10 v3, правка — через координатора.

Всё, что не данные случая, задаётся здесь одним правилом для всех случаев (Askervein, Perdigão, …): сетка и область —
в единицах характерной высоты рельефа H, насыщение степенного профиля притока — по толщине нейтрального слоя модели,
нижняя граница наблюдений — по dz. Модули случаев (askervein.py, perdigao.py) берут числа только отсюда; различаются
лишь данные (рельеф, лес, широта, ветер, устойчивость) и подгоняемые у случая α, z0.
Обоснование каждого числа — docs/plan/air_model_b1.md (§ «Сопоставимость»).
"""
from __future__ import annotations

import math

KAPPA = 0.4

# ------------------------------------------------------------------------------------------ сетка и область
# H — перепад высот рельефа в области наблюдений: от нижней до верхней точки, где стоят опорная точка и наблюдаемые
# (Askervein: вершина HT над опорной RS на равнине, 116 м; Perdigão: гребни над дном долины, Menke 2019 табл. 2, 174 м).
H_PER_DX = 5.8            # клеток на H: dx_nom = H/5,8, округлённый к шагу данных (Perdigão 30 м — Copernicus GLO-30; Askervein 20 м)
N_DOM = 200               # сторона области в клетках номинальной сетки (= 34,5 H при H/dx 5,8)
TOP_PER_H = 7.5           # потолок над высшей точкой рельефа области, в H
SPONGE_CELLS = 35         # боковая губка в клетках номинальной сетки (= 6 H)
# верхняя губка = от высшей точки рельефа до потолка (квадратичная рампа air.py: у гребня ~0, у потолка — полная)
MIN_AGL_PER_DZ = 1.0      # наблюдаемая точка ниже 1·dz (номинальной сетки) над поверхностью модели — не наблюдается (NaN)

# ------------------------------------------------------------------------------------------ профиль притока
# Степенной профиль U(z) = U10 (z/10)^α до z_sat, выше — постоянный (air.wind_profile, max_profile = (z_sat/10)^α).
# z_sat = Z_SAT_FRAC · h, h = 0,3 u*/f — толщина нейтрального слоя самой модели (air._bl_depth), u* = κ U10 / ln(10/z0).
# Проверено данными притока: RS Askervein (змей до 267 м — насыщения нет, местный показатель 0,21 между 178 и 267 м),
# Perdigão RHI-лидары WS1/WS3 выше гребня (ветер перестаёт расти на ≈ 420 м (NE) и ≈ 590 м (SW) над равниной притока).
Z_SAT_FRAC = 0.3
H_MECH_C = 0.3            # как в air.py (_bl_depth): h = 0,3 u*/f


def ustar(u10, z0):
    return KAPPA * u10 / math.log(10.0 / z0)


def h_mech(u10, z0, f_cor):
    return H_MECH_C * ustar(u10, z0) / f_cor


def z_sat(u10, z0, f_cor):
    return Z_SAT_FRAC * h_mech(u10, z0, f_cor)


def max_profile(alpha, u10, z0, f_cor):
    """U(z_sat)/U10 для air.Params.max_profile (air.wind_profile: z_sat = 10·max_profile^(1/α))."""
    return (z_sat(u10, z0, f_cor) / 10.0) ** alpha


def lam_eff(lam, lam_frac, u10, z0, f_cor):
    """λ = max(lam, λ/h · h) — в нейтрали без нагрева h однородно (h_mech), и λ — одно число на прогон."""
    return max(lam, lam_frac * h_mech(u10, z0, f_cor))


def geometry(H, hmax, dx_nom, dx=None, dom_mul=1.0, top_mul=1.0):
    """Числа сетки случая по правилу. H — перепад, м; hmax — высшая точка рельефа области над нулём сетки, м;
    dx_nom — номинальный шаг случая (H/H_PER_DX, округлённый к сетке данных); dx — шаг прогона (контроль: dx/2 и т. п.);
    dom_mul, top_mul — контроль области (сторона и запас над рельефом × множитель)."""
    dx = dx or dx_nom
    L = N_DOM * dx_nom * dom_mul
    n = int(round(L / dx)); n += n % 2
    dz = dx / 2.0
    top = hmax + TOP_PER_H * H * top_mul
    nz = int(math.ceil(top / dz)) + 1
    nz += nz % 2
    sponge_side = SPONGE_CELLS * dx_nom
    sponge_top = top - hmax
    return dict(dx=dx, dz=dz, n=n, L=n * dx, top=top, nz=nz, sponge_side=sponge_side, sponge_top=sponge_top,
                min_agl=MIN_AGL_PER_DZ * dx_nom / 2.0)
