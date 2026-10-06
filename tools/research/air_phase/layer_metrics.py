"""Метрики слоёв (контракт P6 v1, docs/contracts/air-phase.md): что из поля масштаба 1 берут следующие слои игры.

Критерий пользователя (06.10): качество поля — не ошибка скорости в м/с, а правильность того, что из поля читают
термики (масштаб 2), динамический подъём у склонов и подветренная зона (масштаб 3). Здесь — те же формулы, что в игре,
переписанные на numpy для поля P3 (4, 13, 96, 96) [u, v, w, θ′] на высотах над землёй S5.

Что игра читает из поля масштаба 1 (поиск: dp docs find «термики из поля»; docs/guide/air-model.md):

* Термики — `scripts/atmosphere/air_model/air_thermals.gd::build` (AM-07/07б, «Масштаб 2: термики из поля»):
  каналы w_conv = w − w_mech (`wind_field.gd:11–12`), θ′, u, v, рельеф сетки hc, вход решения H, z_i, dθ̄/dz, U10.
  По столбцу (строки 203–262): h = max(z_i − hc, 300 м); w* = (g/θ0·H/(ρc_p)·h)^(1/3) (`wind_field.gd:375`
  `deardorff_wstar`); u* = κ·U10/ln(10/z0) (стр. 162); w_m = (u*³ + 0,28 w*³)^(1/3); F̄ = w_m/(2b), b = 6,5
  (Холтслаг–Бовилль); W̄ — средний w_conv в слое 0..h; Φ = F̄ + max(W̄, 0); потолок — частица θ̄ + θ′(у земли) + Δθ,
  Δθ = b·H_kin/w_m, всплывает до θ̄ + θ′ поля (стр. 237–250); z_l = max(потолок − hc, 300); кандидат — H > 0, Φ > 0,
  столб ≥ 300 м (стр. 263–270). Плотность — Аллен (2006): n_A = 0,6/(z_l·r₂(½)), r₂(ζ) = max(10, 0,102ζ^(1/3)(1 −
  0,25ζ)z_l), n = n_A·Φ/Φ̂/p_жизни, не больше Φ/(w0·K̄) (стр. 272–286); выбор — по убыванию Φ с исключением в радиусе
  √(0,696/n) (стр. 287–335); водосбор — ближайший источник в 2 радиусах (стр. 336–379); сила w0 = k·w*,
  k = e·0,4575 ≈ 1,24, w* — по среднему H водосбора; радиус у верха R = r₂(1, z_l); снос — средний ветер столба
  от земли до потолка (стр. 452–466). Параметры жизни пузыря (grow/mature/decay/gap) — `configs/atmosphere.json →
  thermal`, доля циклов `duty` — из погоды (здесь 1,0, значение по умолчанию кода: стр. 632–633).
* Подъём у склонов — с полем пилоту идёт механическая вертикаль поля как есть: `atmosphere.gd:807`
  (`w = … + fw.y + …`, fw — `AirFieldSet.sample`, w_mech); аналитический `_ridge_lift` — только в полосе края поля.
  Порога «зоны подъёма» в игре нет; здесь порог — минимальное снижение крыльев игры (`configs/wings/*.json →
  min_sink_ms` = 0,83–1,24 м/с) → 1,0 м/с: где w выше, пилот держится (физика полёта, помечено [физика]).
* Подветренная зона — с полем признак отрыва `scripts/atmosphere/field_turbulence.gd::lee` (стр. 113–128):
  ex = 1 − (|U|/U_out)/(ln(z/z0)/ln(a_out/z0)), признак = smoothstep(0,3; 0,7; ex)·smoothstep(0; 0,05; s_d);
  U_out — наибольшая |U_h| столбца в слое A_OUT = 600 м над землёй, a_out — её высота, s_d = −min w/U_out в том же
  слое (`wind_field.gd:291–335`); пороги — `configs/atmosphere.json → lee.field_deficit_attached/separated,
  field_descent_slope`. Скачок слоя смешения ΔU = max(U_H − |U|, 0)·признак, U_H — |U| той же вертикали на высоте
  превышения гребня r (`atmosphere.gd:797–802`), r — `ground_field.gd:195–204` (наибольшее превышение земли против
  ветра на 60…1600 м, `lee.upwind_distances_m`); σ_w слоя смешения = 0,14·ΔU (`lee.field_sigma_w_per_du`).
  `_lee_flow` (`atmosphere.gd:912`) — аналитика вне поля (линия тени), из поля не берёт ничего; обратный поток
  эвристики `field_reverse_per_uh` дописывается только там, где пузырь не разрешён сеткой (на 400 м — всегда), —
  поэтому здесь отдельно — разрешённое полем обратное течение (u·e < 0 у земли).

Отступления от игры (помечены в описаниях NAMES):
* w_mech в P3 нет (одно поле на случай). w_conv = w − w_mech берётся с «близнеца» — того же случая с H = 0
  (`w_mech` — аргумент; features.py ищет его в плане); нет близнеца — w_conv ≈ w (вместе с механическим подъёмом
  склонов, завышает Φ над наветренными склонами) и `th_wconv_src` = 2. H ≤ 0 везде — w_conv = 0 (`th_wconv_src` = 0).
* Высоты P3 — над землёй решателя (у ENVELOPE — над h_eff), 13 уровней; средние по слою — с весами толщины ячеек
  (границы посередине между уровнями), в игре — по клеткам dz над морем. Частица стартует с 25 м (в игре — центр
  первой клетки). Верх поля — 2000 м над землёй: потолок выше — «упёрся» (`th_ceil_capped_frac`).
* dθ̄/dz фона — как override решателя (P4 инв. 3): 0 под z_i, θ0N²/g выше; z_i над морем = min(hc) + z_i_agl
  (`conditions.override_base`). У случаев из S2 (ENVELOPE_REAL) — та же форма с N и z_i строки (приближение).
* Кромка облаков (погода) не учитывается — потолок только по частице. Край области 5 клеток (EDGE, как
  phase_stats) в статистики не входит (в игре — вес края поля < ½).
* sl_* и lee_* — вертикаль как в игре — w_mech (близнец H = 0), если он есть; иначе полный w случая (у H > 0
  без близнеца в нём и организованная конвекция — `th_wconv_src` = 2).

Только numpy (+ scipy.spatial для водосбора). Без GPU.
"""
from __future__ import annotations

import math

import numpy as np

# --- постоянные игры (air_thermals.gd:30–55, wind_field.gd:24–36)
G = 9.81
THETA0 = 300.0
RHO_CP = 1.2 * 1005.0
KAPPA = 0.4
HB_B = 6.5
ZI_MIN = 300.0
K_ALLEN = math.e * 0.4575
CORE_FLUX = math.exp(-1.0)
ALLEN_R2 = 0.102
ALLEN_R_MIN = 10.0
ALLEN_N = 0.6
RSA_K = 0.834
Z0 = 0.1                      # WindField.z0 по умолчанию = air3d Params.z0
A_OUT = 600.0                 # wind_field.gd:29
# thermal-конфиг (configs/atmosphere.json → thermal), значения середин диапазонов (_mid)
TH_CFG = dict(grow_s=180.0, mature_s=510.0, decay_s=225.0, gap_s=180.0, duty=1.0, radius_min_factor=0.45,
              ground_ramp_m=150.0, top_taper_m=120.0, profile_cutoff_radii=2.5)
# lee-конфиг (configs/atmosphere.json → lee)
LEE_EX0, LEE_EX1, LEE_DESC = 0.3, 0.7, 0.05
LEE_SIGMA_W_PER_DU = 0.14
LEE_UPWIND_M = (60.0, 150.0, 300.0, 600.0, 1000.0, 1600.0)
# склон: порог силы подъёма — минимальное снижение крыльев игры (configs/wings/*.json → min_sink_ms 0,83–1,24)
SL_W_THR = 1.0
SL_LAYER = (50.0, 300.0)      # P6: 50–300 м над землёй
SL_SLOPE_MIN = 0.02           # наветренный склон: e·∇hc > 0,02 (≈ 1°) [физика: склон, на который набегает ветер]
LEE_THR = 0.5                 # клетка «в зоне» — признак ≥ ½ (половина силы зоны в игре)
EDGE = 5

AGL_M = np.array([25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000], np.float64)
_B = np.concatenate([[0.0], 0.5 * (AGL_M[1:] + AGL_M[:-1]), [AGL_M[-1] + 0.5 * (AGL_M[-1] - AGL_M[-2])]])

# Описание метрик (имя → единица и откуда формула). [игра] — формула/порог из кода игры; [физика] — нет в игре,
# обосновано физически; [P6] — величина из контракта.
NAMES = {
    # --- термики
    "th_wconv_src": "код источника w_conv: 0 — H ≤ 0 (w_conv = 0), 1 — w − w_mech близнеца H = 0, 2 — w (нет близнеца) [отступление]",
    "th_cand_frac": "доля воздушных столбцов (без края) — кандидатов в источники: H > 0, Φ > 0, столб частицы ≥ 300 м, 1 [игра air_thermals.gd:263–270]",
    "th_n_src": "число источников термиков в области (без края), шт [игра air_thermals.gd:287–335]",
    "th_src_density_km2": "источников на км² области без края, 1/км² [игра]",
    "th_phi_mean_ms": "средний восходящий поток поля Φ = F̄ + max(W̄, 0) по столбцам без края, м/с [игра air_thermals.gd:229–236]",
    "th_wbar_pos_mean_ms": "средний организованный подъём max(W̄, 0) (W̄ — средний w_conv слоя 0..h), м/с [игра]",
    "th_org_frac": "доля организованного потока в потоке водосборов ΣO/ΣM (O — W̄⁺·A), 1 [игра air_thermals.gd:447–451]",
    "th_carried_frac": "доля потока поля, которую несут ядра: Σ w0·K̄ / Σ Φ·A, 1 [игра]",
    "th_wstar_mean_ms": "средний по источникам w* водосбора (Дирдорф), м/с [игра wind_field.gd:375]",
    "th_w0_mean_ms": "средняя сила ядра w0 = 1,24·w* по источникам, м/с [игра air_thermals.gd:440]",
    "th_w0_max_ms": "наибольшая сила ядра w0, м/с [игра]",
    "th_radius_mean_m": "средний радиус ядра у верха R = r₂(1, z_l) (Аллен), м [игра]",
    "th_ceil_agl_mean_m": "средний потолок частицы над землёй по источникам (без кромки), м [игра air_thermals.gd:237–255]",
    "th_ceil_msl_mean_m": "средний потолок частицы над морем по источникам, м [игра]",
    "th_ceil_over_zi": "средний (потолок − база)/z_i над базой по источникам, 1 (1 — ровно z_i; > 1 — проскок) [физика: нормировка]",
    "th_ceil_capped_frac": "доля источников, у которых частица дошла до верха поля 2000 м над землёй, 1 [отступление]",
    "th_drift_mean_ms": "средний по источникам модуль сноса — среднего ветра столба от земли до потолка, м/с [игра air_thermals.gd:452–466]",
    "th_drift_along_ms": "средняя по источникам составляющая сноса по ветру прогноза, м/с [игра]",
    "th_drift_cross_ms": "средняя по источникам составляющая сноса поперёк ветра (влево от e +), м/с [игра]",
    "th_drift_zi_ms": "средняя скорость ветра в слое 0..z_i над землёй по области без края (P6 «снос»; есть и при H = 0), м/с [P6]",
    "th_src_top_dist_m": "расстояние от вершины (центроид клеток hc ≥ max − 2 % перепада) до источника с наибольшим Φ, м [P6]",
    "th_src_relief_frac": "доля источников на рельефе (hc − min hc > 10 % перепада), 1 [P6]",
    "th_src_relief_ratio": "густота источников на рельефе / вне рельефа (1 — рельеф не влияет, > 1 — притягивает), 1 [P6]",
    "th_src_x_mean_over_h": "среднее смещение источников на рельефе по ветру от вершины, в долях h (< 0 — наветренная сторона; NaN — нет), 1 [P6]",
    "th_phi_x_over_h": "смещение по ветру от вершины центра избытка Φ над медианой (вес max(Φ − med Φ, 0)), в долях h, 1 [физика]",
    # --- склон
    "sl_area_km2": "площадь наветренного склона (e·∇hc > 0,02), где средний w слоя 50–300 м над землёй > 1 м/с, км² [физика: порог — min_sink крыльев игры]",
    "sl_w_mean_ms": "средний w слоя 50–300 м по этой площади, м/с (NaN — площади нет) [игра atmosphere.gd:807: пилоту — w поля]",
    "sl_w_max_ms": "наибольший средний w слоя 50–300 м над наветренным склоном, м/с [игра]",
    "sl_w_max_over_us": "sl_w_max / (U_sat·s) — против линейной оценки w ≈ U·tg(уклона), 1 [физика]",
    "sl_x_peak_over_h": "положение максимума подъёма по ветру от вершины, в долях h (< 0 — наветренная сторона), 1 [физика]",
    "sl_ceil_agl_m": "высота над землёй, до которой над наветренным склоном где-то w ≥ 1 м/с (линейно между уровнями; 0 — нигде), м [физика]",
    # --- подветренная зона
    "lee_area25_km2": "площадь, где признак отрыва поля ≥ ½ на 25 м над землёй, км² [игра field_turbulence.gd:113–128]",
    "lee_area100_km2": "то же на 100 м, км² [игра]",
    "lee_depth_max_m": "наибольшая высота над землёй, до которой признак ≥ ½ (по столбцам зоны), м [игра]",
    "lee_depth_mean_m": "средняя по столбцам зоны (25 м) высота верха зоны, м [игра]",
    "lee_len_over_h": "протяжённость зоны (25 м) по ветру за вершиной: наибольшее расстояние по ветру от вершины, в долях h, 1 [физика]",
    "lee_wmin_ms": "наименьший w в слое 0…600 м в столбцах зоны (25 м; опускание), м/с (NaN — зоны нет) [игра: s_d по w]",
    "lee_desc_max": "наибольший наклон опускания s_d = −min w/U_out (слой 600 м) за вершиной, 1 [игра wind_field.gd:333]",
    "lee_du_mean_ms": "средний скачок слоя смешения ΔU = max(U_H − |U|, 0)·признак на 25 м по зоне, м/с [игра atmosphere.gd:797–802]",
    "lee_du_max_ms": "наибольший ΔU на 25 м, м/с [игра]",
    "lee_sigw_max_ms": "наибольшая σ_w слоя смешения 0,14·ΔU на 25 м, м/с [игра lee.field_sigma_w_per_du]",
    "lee_rev_area25_km2": "площадь разрешённого полем обратного течения u·e < 0 на 25 м, км² [физика: ротор, который поле даёт само]",
    "lee_urev_min_over_us": "min(u·e) на 25 м / U_sat (≤ 0 — есть обратное течение), 1 [физика; ср. lee.field_reverse_per_uh = 0,22]",
}
GROUPS = ("th_", "sl_", "lee_")


# ------------------------------------------------------------------ общие помощники
def smoothstep(e0, e1, x):
    t = np.clip((np.asarray(x, np.float64) - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def wind_unit(wdir_from_deg):
    """Единичный вектор «куда дует» (восток, север) по направлению «откуда», °."""
    a = math.radians(float(wdir_from_deg))
    return np.array([-math.sin(a), -math.cos(a)])


def layer_weights(lo, hi):
    """Веса уровней AGL_M для среднего по слою [lo, hi] над землёй: перекрытие ячеек (границы посередине) со слоем.
    lo, hi — число или массив (ny, nx) → (13,) или (13, ny, nx); сумма весов = 1 (0 — слой пуст)."""
    lo = np.asarray(lo, np.float64)
    hi = np.asarray(hi, np.float64)
    b0 = _B[:-1].reshape((-1,) + (1,) * hi.ndim)
    b1 = _B[1:].reshape((-1,) + (1,) * hi.ndim)
    w = np.clip(np.minimum(b1, hi) - np.maximum(b0, lo), 0.0, None)
    s = w.sum(axis=0)
    return w / np.where(s > 0, s, 1.0)


def deardorff_wstar(heat, z_i_msl, hc):
    """w* = (g/θ0·H/(ρc_p)·h)^(1/3), h = max(z_i − hc, 300); H ≤ 0 — 0 (wind_field.gd:375)."""
    heat = np.asarray(heat, np.float64)
    h = np.maximum(z_i_msl - np.asarray(hc, np.float64), ZI_MIN)
    return np.where(heat > 0, np.cbrt(G / THETA0 * np.maximum(heat, 0) / RHO_CP * h), 0.0)


def allen_r2(zeta, zi):
    return np.maximum(ALLEN_R_MIN, ALLEN_R2 * np.cbrt(zeta) * (1.0 - 0.25 * zeta) * zi)


def allen_density(zi):
    return ALLEN_N / (zi * allen_r2(0.5, zi))


def _q_at(xi, d, cfg=TH_CFG):
    rf = np.maximum(cfg["radius_min_factor"], np.cbrt(xi) * (1.0 - 0.25 * xi) / 0.75)
    dh = xi * d
    vert = np.where(dh > 0, np.minimum(1.0, np.cbrt(np.maximum(dh, 0) / cfg["ground_ramp_m"])), 0.0)
    tp = smoothstep(0.0, cfg["top_taper_m"], d - dh)
    return rf * rf * vert * tp


def shape_mean(d, cfg=TH_CFG):
    """Средний по столбу глубины d поток ядра на 1 м/с пика, R² = 1 (air_thermals.gd:667–672, 33 точки трапецией)."""
    d = np.atleast_1d(np.asarray(d, np.float64))
    xi = np.linspace(0, 1, 33)[:, None]
    q = _q_at(xi, d[None, :], cfg)
    wq = np.ones(33)
    wq[[0, -1]] = 0.5
    return (q * wq[:, None]).sum(0) / 32.0


def life_fractions(cfg=TH_CFG):
    """(life_mean, alive_frac) — air_thermals.gd:626–633."""
    g, m, d, gap = cfg["grow_s"], cfg["mature_s"], cfg["decay_s"], cfg["gap_s"]
    tot = g + m + d + gap
    return (0.5 * g + m + 0.5 * d) / tot * cfg["duty"], (g + m + d) / tot * cfg["duty"]


def grid_xy(ny, nx, dx, x0=-19200.0, y0=-19200.0):
    """Центры клеток (X восток, Y север), м: x0 + dx/2 + dx·i (P1)."""
    x = x0 + dx * (np.arange(nx) + 0.5)
    y = y0 + dx * (np.arange(ny) + 0.5)
    return np.meshgrid(x, y)


def summit_xy(hc, X, Y):
    """Вершина: центроид клеток hc ≥ max − 2 % перепада (у хребта — середина гребня)."""
    rng = float(hc.max() - hc.min())
    m = hc >= hc.max() - 0.02 * max(rng, 1e-6)
    return float(X[m].mean()), float(Y[m].mean())


def _bilinear(a, fi, fj):
    """a (ny, nx) в дробных индексах (fj, fi), с прижатием к краю."""
    ny, nx = a.shape
    fi = np.clip(fi, 0, nx - 1.000001)
    fj = np.clip(fj, 0, ny - 1.000001)
    i0 = fi.astype(int)
    j0 = fj.astype(int)
    tx, ty = fi - i0, fj - j0
    return ((a[j0, i0] * (1 - tx) + a[j0, i0 + 1] * tx) * (1 - ty)
            + (a[j0 + 1, i0] * (1 - tx) + a[j0 + 1, i0 + 1] * tx) * ty)


def upwind_relief(hc, e, dx, dists=LEE_UPWIND_M):
    """Превышение гребня против ветра над точкой r = max_d hc(x − d·e) − hc(x), ≥ 0 (ground_field.gd:195–204)."""
    ny, nx = hc.shape
    J, I = np.mgrid[0:ny, 0:nx].astype(np.float64)
    crest = hc.astype(np.float64).copy()
    for d in dists:
        crest = np.maximum(crest, _bilinear(hc, I - e[0] * d / dx, J - e[1] * d / dx))
    return crest - hc


def _interp_col(prof, z):
    """prof (13, ny, nx) на AGL_M → значение на высоте z (ny, nx) линейно (прижатие к краям)."""
    k = np.clip(np.searchsorted(AGL_M, z) - 1, 0, len(AGL_M) - 2)
    z0, z1 = AGL_M[k], AGL_M[k + 1]
    t = np.clip((z - z0) / (z1 - z0), 0.0, 1.0)
    p0 = np.take_along_axis(prof, k[None], 0)[0]
    p1 = np.take_along_axis(prof, (k + 1)[None], 0)[0]
    return p0 * (1 - t) + p1 * t


def _nan_metrics(groups=GROUPS):
    return {k: float("nan") for k in NAMES if k.startswith(tuple(groups))}


# ------------------------------------------------------------------ подветренная зона (масштаб 3 с полем)
def lee_flag(u, v, w, z0=Z0):
    """Признак отрыва игры на всех уровнях (13, ny, nx) + столбцовые U_out, a_out, s_d (field_turbulence.gd:113–128,
    wind_field.gd:291–335). u, v, w — (13, ny, nx)."""
    sp = np.hypot(u, v)
    inl = AGL_M <= A_OUT
    spl = sp[inl]
    kmax = np.argmax(spl, axis=0)
    u_out = np.take_along_axis(spl, kmax[None], 0)[0]
    a_out = np.maximum(AGL_M[inl][kmax], 2 * z0)
    desc = -np.minimum(w[inl].min(axis=0), 0.0) / np.maximum(u_out, 0.5)
    z = AGL_M[:, None, None]
    r = np.log(np.maximum(z, 2 * z0) / z0) / np.log(a_out / z0)[None]
    ex = 1.0 - sp / np.maximum(u_out, 1e-6)[None] / np.maximum(r, 1e-3)
    flag = smoothstep(LEE_EX0, LEE_EX1, ex) * smoothstep(0.0, LEE_DESC, desc)[None]
    flag = np.where((u_out[None] < 0.5) | (z >= a_out[None]), 0.0, flag)
    return flag, u_out, a_out, desc


# ------------------------------------------------------------------ термики (масштаб 2 из поля)
def _theta_bar(z_msl, z_i_msl, n_bv):
    """θ̄ фона относительно низа: 0 под z_i, θ0N²/g·(z − z_i) выше (P4 инв. 3)."""
    return THETA0 * n_bv ** 2 / G * np.maximum(z_msl - z_i_msl, 0.0)


def thermal_columns(f, hc, heat, case, w_mech=None, ground=None):
    """Столбцовые величины air_thermals.gd::build (стр. 203–270): dict массивов (ny, nx)."""
    u, v, w, th = (np.asarray(f[c], np.float64) for c in range(4))
    hc = np.asarray(hc, np.float64)
    gnd = hc if ground is None else np.asarray(ground, np.float64)
    heat = np.asarray(heat, np.float64)
    zi_msl = float(np.min(hc)) + float(case["z_i_agl_m"])
    n_bv = float(case.get("n_bv", 0.01))
    u10 = float(case.get("u10", 0.0))
    ustar = KAPPA * u10 / math.log(10.0 / Z0) if u10 > 0 else 0.0
    if not np.any(heat > 0):
        wconv, src = np.zeros_like(w), 0
    elif w_mech is not None:
        wconv, src = w - np.asarray(w_mech, np.float64), 1
    else:
        wconv, src = w, 2
    hk = heat / RHO_CP
    h = np.maximum(zi_msl - gnd, ZI_MIN)
    ws = deardorff_wstar(heat, zi_msl, gnd)
    wm = np.cbrt(ustar ** 3 + 0.28 * ws ** 3)
    fbar = np.where(hk > 0, wm / (2 * HB_B), 0.0)
    wbar = (layer_weights(0.0, h) * wconv).sum(0)
    phi = fbar + np.maximum(wbar, 0.0)
    # потолок частицы
    z_msl = gnd[None] + AGL_M[:, None, None]
    te = _theta_bar(z_msl, zi_msl, n_bv) + th
    ex = HB_B * hk / np.maximum(wm, 1e-3)
    tp = te[0] + ex
    above = te[1:] >= tp[None]
    hit = above.any(0)
    k = np.argmax(above, axis=0) + 1                     # первый уровень, где среда теплее частицы
    te_k = np.take_along_axis(te, k[None], 0)[0]
    te_p = np.take_along_axis(te, (k - 1)[None], 0)[0]
    fr = np.clip((tp - te_p) / np.maximum(te_k - te_p, 1e-6), 0.0, 1.0)
    d_top = np.where(hit, AGL_M[k - 1] + fr * (AGL_M[k] - AGL_M[k - 1]), AGL_M[-1])
    d_top = np.where(hk > 0, d_top, 0.0)
    return dict(phi=phi, wbar=wbar, fbar=fbar, ws=ws, hk=hk, d_top=d_top, capped=(hk > 0) & ~hit,
                top_msl=gnd + d_top, zl=np.maximum(d_top, ZI_MIN), zi_msl=zi_msl, src=src, gnd=gnd)


def select_sources(col, dx, edge=EDGE, cfg=TH_CFG):
    """Выбор источников (air_thermals.gd:263–335): → (индексы j, i источников, радиус исключения по столбцам, n)."""
    phi, hk, d_top, zl, ws = col["phi"], col["hk"], col["d_top"], col["zl"], col["ws"]
    ny, nx = phi.shape
    inner = np.zeros_like(phi, bool)
    inner[edge:ny - edge, edge:nx - edge] = True
    cut = cfg["profile_cutoff_radii"]
    life_mean, alive = life_fractions(cfg)
    rc = allen_r2(1.0, zl)
    cand_r = cut * rc
    ok = (hk > 0) & (phi > 0)
    na = np.where(ok, allen_density(zl), 0.0)
    kbar = np.where(ok, CORE_FLUX * np.pi * rc * rc * shape_mean(np.maximum(d_top, ZI_MIN).ravel(), cfg)
                    .reshape(phi.shape) * life_mean, 0.0)
    cand = ok & (d_top >= ZI_MIN) & inner
    s_na = na[cand].sum()
    phi_ref = (na * phi)[cand].sum() / s_na if s_na > 0 else 0.0
    if phi_ref > 0:
        m = na > 0
        dens = na * phi / phi_ref / max(alive, 1e-3)
        cap = phi / np.maximum(K_ALLEN * ws * kbar, 1e-9)
        dens = np.minimum(dens, cap)
        r_new = np.clip(RSA_K / np.sqrt(np.maximum(dens, 1e-12)), cand_r, np.maximum(4.0 * zl, cand_r))
        cand_r = np.where(m, r_new, cand_r)
    jj, ii = np.nonzero(cand)
    order = np.lexsort((jj * nx + ii, -phi[jj, ii]))   # по убыванию Φ, при равенстве — меньший номер
    taken = np.zeros((ny, nx), bool)
    cx, cy = [], []
    for o in order:
        j, i = jj[o], ii[o]
        r = cand_r[j, i] / dx
        R = int(math.ceil(r))
        j0, i0 = max(j - R, 0), max(i - R, 0)
        tj, ti = np.nonzero(taken[j0:j + R + 1, i0:i + R + 1])
        if tj.size and np.any((tj + j0 - j) ** 2 + (ti + i0 - i) ** 2 < r * r):
            continue
        taken[j, i] = True
        cx.append(i)
        cy.append(j)
    return np.asarray(cy, int), np.asarray(cx, int), cand_r, cand, kbar


def assign_catchments(sj, si, cand_r, shape, dx, kq=16):
    """Водосбор: столбец → ближайший источник, если не дальше 2 радиусов исключения источника (стр. 336–379)."""
    ny, nx = shape
    owner = -np.ones(shape, int)
    if sj.size == 0:
        return owner
    from scipy.spatial import cKDTree
    pts = np.c_[si, sj].astype(np.float64)
    reach = 2.0 * cand_r[sj, si] / dx
    J, I = np.mgrid[0:ny, 0:nx]
    q = np.c_[I.ravel(), J.ravel()].astype(np.float64)
    k = min(kq, len(pts))
    dd, ix = cKDTree(pts).query(q, k=k)
    dd, ix = dd.reshape(len(q), k), ix.reshape(len(q), k)
    okk = dd <= reach[ix] + 1e-9
    first = np.argmax(okk, axis=1)
    has = okk[np.arange(len(q)), first]
    owner.ravel()[has] = ix[np.arange(len(q)), first][has]
    return owner


def thermal_metrics(f, hc, heat, case, w_mech=None, ground=None, dx=400.0, edge=EDGE, x0=-19200.0, y0=-19200.0):
    out = _nan_metrics(("th_",))
    col = thermal_columns(f, hc, heat, case, w_mech, ground)
    hc = np.asarray(hc, np.float64)
    ny, nx = hc.shape
    inner = (slice(edge, ny - edge), slice(edge, nx - edge))
    e = wind_unit(case["wdir_from_deg"])
    X, Y = grid_xy(ny, nx, dx, x0, y0)
    xs, ys = summit_xy(hc, X, Y)
    S = (X - xs) * e[0] + (Y - ys) * e[1]
    h_rel = float(case.get("h_m") or 0.0) or float(hc.max() - hc.min())
    u, v = np.asarray(f[0], np.float64), np.asarray(f[1], np.float64)
    wz = layer_weights(0.0, float(case["z_i_agl_m"]))
    out["th_drift_zi_ms"] = float(np.hypot((wz[:, None, None] * u).sum(0), (wz[:, None, None] * v).sum(0))[inner].mean())
    out["th_wconv_src"] = float(col["src"])
    out["th_phi_mean_ms"] = float(col["phi"][inner].mean())
    out["th_wbar_pos_mean_ms"] = float(np.maximum(col["wbar"], 0)[inner].mean())
    sj, si, cand_r, cand, kbar = select_sources(col, dx, edge)
    n_in = cand[inner].size
    out["th_cand_frac"] = float(cand[inner].mean())
    out["th_n_src"] = float(sj.size)
    out["th_src_density_km2"] = float(sj.size / (n_in * dx * dx * 1e-6))
    if cand.any():
        wphi = np.maximum(col["phi"] - np.median(col["phi"][inner]), 0.0) * cand
        if wphi.sum() > 0:
            out["th_phi_x_over_h"] = float((wphi * S).sum() / wphi.sum() / h_rel)
    if sj.size == 0:
        return out
    cell_a = dx * dx
    owner = assign_catchments(sj, si, cand_r, hc.shape, dx)
    ns = sj.size
    own = owner.ravel()
    m_ok = own >= 0
    M = np.bincount(own[m_ok], weights=col["phi"].ravel()[m_ok] * cell_a, minlength=ns)
    O = np.bincount(own[m_ok], weights=np.maximum(col["wbar"], 0).ravel()[m_ok] * cell_a, minlength=ns)
    A = np.bincount(own[m_ok], minlength=ns) * cell_a
    Hs = np.bincount(own[m_ok], weights=np.maximum(np.asarray(heat, np.float64), 0).ravel()[m_ok] * cell_a, minlength=ns)
    gnd_s = col["gnd"][sj, si]
    wstar = deardorff_wstar(Hs / np.maximum(A, 1.0), col["zi_msl"], gnd_s)
    w0 = K_ALLEN * wstar
    d_top = np.maximum(col["d_top"][sj, si], ZI_MIN)
    R = allen_r2(1.0, col["zl"][sj, si])
    life_mean, _ = life_fractions()
    carried = w0 * CORE_FLUX * np.pi * R * R * shape_mean(d_top) * life_mean
    total = float(col["phi"][inner].sum() * cell_a)
    # снос: средний ветер столба от земли до потолка
    wd = layer_weights(0.0, col["d_top"][sj, si])                      # (13, ns)
    du = (wd * u[:, sj, si]).sum(0)
    dv = (wd * v[:, sj, si]).sum(0)
    dist = np.hypot(X[sj, si] - xs, Y[sj, si] - ys)
    top = int(np.argmax(col["phi"][sj, si]))
    rng = float(hc.max() - hc.min())
    on_rel = (hc - hc.min() > 0.1 * max(rng, 1e-6))
    src_rel = on_rel[sj, si]
    a_rel, a_flat = (on_rel & cand).sum(), (~on_rel & cand).sum()
    if a_rel > 0 and a_flat > 0 and (~src_rel).sum() > 0:
        out["th_src_relief_ratio"] = float(src_rel.sum() / a_rel / ((~src_rel).sum() / a_flat))
    if src_rel.any():
        out["th_src_x_mean_over_h"] = float(S[sj, si][src_rel].mean() / h_rel)
    out.update(
        th_org_frac=float(O.sum() / max(M.sum(), 1e-9)),
        th_carried_frac=float(carried.sum() / max(total, 1e-9)),
        th_wstar_mean_ms=float(wstar.mean()), th_w0_mean_ms=float(w0.mean()), th_w0_max_ms=float(w0.max()),
        th_radius_mean_m=float(R.mean()),
        th_ceil_agl_mean_m=float(col["d_top"][sj, si].mean()),
        th_ceil_msl_mean_m=float(col["top_msl"][sj, si].mean()),
        th_ceil_over_zi=float(((col["top_msl"][sj, si] - float(np.min(hc))) / float(case["z_i_agl_m"])).mean()),
        th_ceil_capped_frac=float(col["capped"][sj, si].mean()),
        th_drift_mean_ms=float(np.hypot(du, dv).mean()),
        th_drift_along_ms=float((du * e[0] + dv * e[1]).mean()),
        th_drift_cross_ms=float((-du * e[1] + dv * e[0]).mean()),
        th_src_top_dist_m=float(dist[top]),
        th_src_relief_frac=float(src_rel.mean()),
    )
    return out


# ------------------------------------------------------------------ склоны и подветренная зона
def slope_lee_metrics(f, hc, case, dx=400.0, edge=EDGE, x0=-19200.0, y0=-19200.0, groups=("sl_", "lee_"),
                      w_mech=None):
    """sl_*, lee_*. Вертикаль — w_mech, если дан (как игра: пилоту и s_d — механическая вертикаль), иначе w поля."""
    out = _nan_metrics(groups)
    u, v, w = (np.asarray(f[c], np.float64) for c in range(3))
    if w_mech is not None:
        w = np.asarray(w_mech, np.float64)
    hc = np.asarray(hc, np.float64)
    ny, nx = hc.shape
    inner = np.zeros((ny, nx), bool)
    inner[edge:ny - edge, edge:nx - edge] = True
    e = wind_unit(case["wdir_from_deg"])
    X, Y = grid_xy(ny, nx, dx, x0, y0)
    xs, ys = summit_xy(hc, X, Y)
    S = (X - xs) * e[0] + (Y - ys) * e[1]
    h_rel = float(case.get("h_m") or 0.0) or float(hc.max() - hc.min())
    cell_km2 = dx * dx * 1e-6
    u_sat = float(case.get("u_sat", float("nan")))
    if "sl_" in groups:
        gy, gx = np.gradient(hc, dx)
        wind_slope = gx * e[0] + gy * e[1]
        ww = (layer_weights(*SL_LAYER)[:, None, None] * w).sum(0)
        wsl = inner & (wind_slope > SL_SLOPE_MIN)
        lift = wsl & (ww > SL_W_THR)
        out["sl_area_km2"] = float(lift.sum() * cell_km2)
        if lift.any():
            out["sl_w_mean_ms"] = float(ww[lift].mean())
        if wsl.any():
            k = np.argmax(np.where(wsl, ww, -np.inf))
            out["sl_w_max_ms"] = float(ww.ravel()[k])
            out["sl_x_peak_over_h"] = float(S.ravel()[k] / h_rel)
            s = float(case.get("slope") or np.max(np.hypot(gx, gy)))
            if np.isfinite(u_sat) and u_sat * s > 0:
                out["sl_w_max_over_us"] = float(ww.ravel()[k] / (u_sat * s))
            wmax = np.where(wsl[None], w, -np.inf).max(axis=(1, 2))              # (13,)
            ok = wmax >= SL_W_THR
            if not ok.any():
                out["sl_ceil_agl_m"] = 0.0
            else:
                k2 = int(np.nonzero(ok)[0].max())
                if k2 == len(AGL_M) - 1:
                    out["sl_ceil_agl_m"] = float(AGL_M[-1])
                else:
                    t = (wmax[k2] - SL_W_THR) / max(wmax[k2] - wmax[k2 + 1], 1e-9)
                    out["sl_ceil_agl_m"] = float(AGL_M[k2] + np.clip(t, 0, 1) * (AGL_M[k2 + 1] - AGL_M[k2]))
        else:
            out["sl_area_km2"] = 0.0
    if "lee_" in groups:
        flag, u_out, a_out, desc = lee_flag(u, v, w)
        flag = flag * inner[None]
        z25 = flag[0] >= LEE_THR
        out["lee_area25_km2"] = float(z25.sum() * cell_km2)
        out["lee_area100_km2"] = float((flag[3] >= LEE_THR).sum() * cell_km2)
        top_k = np.where((flag >= LEE_THR).any(0), len(AGL_M) - 1 - np.argmax((flag >= LEE_THR)[::-1], axis=0), -1)
        depth = np.where(top_k >= 0, AGL_M[np.maximum(top_k, 0)], 0.0)
        out["lee_depth_max_m"] = float(depth.max())
        down = inner & (S > 0)
        out["lee_desc_max"] = float(desc[down].max()) if down.any() else float("nan")
        along25 = u[0] * e[0] + v[0] * e[1]
        rev = inner & (along25 < 0)
        out["lee_rev_area25_km2"] = float(rev.sum() * cell_km2)
        if np.isfinite(u_sat) and u_sat > 0:
            out["lee_urev_min_over_us"] = float(min(along25[inner].min(), 0.0) / u_sat)
        if z25.any():
            out["lee_depth_mean_m"] = float(depth[z25].mean())
            sd = S[z25 & (S > 0)]
            out["lee_len_over_h"] = float(sd.max() / h_rel) if sd.size else 0.0
            out["lee_wmin_ms"] = float(w[AGL_M <= A_OUT][:, z25].min())
            r = upwind_relief(hc, e, dx)
            sp = np.hypot(u, v)
            u_h = _interp_col(sp, np.maximum(r, AGL_M[0]))
            du = np.where(r > AGL_M[0], np.maximum(u_h - sp[0], 0.0), 0.0) * flag[0]
            out["lee_du_mean_ms"] = float(du[z25].mean())
            out["lee_du_max_ms"] = float(du.max())
            out["lee_sigw_max_ms"] = float(LEE_SIGMA_W_PER_DU * du.max())
        else:
            out.update(lee_len_over_h=0.0, lee_depth_mean_m=0.0, lee_du_mean_ms=0.0, lee_du_max_ms=0.0,
                       lee_sigw_max_ms=0.0)
    return out


# ------------------------------------------------------------------ контракт P6
def layer_metrics(f, hc, heat_flux, hbl, case, *, w_mech=None, dx=None, x0=-19200.0, y0=-19200.0,
                  groups=GROUPS):
    """P6: метрики слоёв поля f (4, 13, ny, nx) [u, v, w, θ′] → dict[str, float] (имена — NAMES).

    hc, heat_flux, hbl — (ny, nx) (hbl не нужен формулам игры: толщина слоя у игры — z_i и частица; принят для
    контракта). case — строка `cases` P3 (dict) + `h_m`, `slope`, `shape` из плана; нужны `wdir_from_deg`,
    `z_i_agl_m`, `n_bv`, `u10`, `u_sat`, `status`; необязательно `h_eff` (ENVELOPE: высоты поля — над ним),
    `dx_m` (шаг поля; у SEPARATION dx = 100 поле `fields/f` — область 400 м, поэтому по умолчанию 400).
    w_mech (13, ny, nx) — w случая-близнеца с H = 0 (для w_conv; см. шапку). Разошедшийся случай (status 2) — NaN.
    """
    f = np.asarray(f, np.float32)
    hc = np.asarray(hc, np.float64)
    dx = 400.0 if dx is None else float(dx)
    if int(case.get("status", 0)) == 2:
        return _nan_metrics(groups)
    ground = case.get("h_eff")
    out = {}
    if "th_" in groups:
        out.update(thermal_metrics(f, hc, heat_flux, case, w_mech=w_mech, ground=ground, dx=dx, x0=x0, y0=y0))
    sg = tuple(g for g in groups if g in ("sl_", "lee_"))
    if sg:
        out.update(slope_lee_metrics(f, hc, case, dx=dx, x0=x0, y0=y0, groups=sg, w_mech=w_mech))
    return out


def layer_diff(a, b):
    """P6: разности метрик a − b по общим ключам (NaN у обоих — 0: «у обоих нет»; у одного — NaN)."""
    out = {}
    for k in a:
        if k not in b:
            continue
        x, y = float(a[k]), float(b[k])
        if math.isnan(x) and math.isnan(y):
            out[k] = 0.0
        else:
            out[k] = x - y
    return out


def layer_masks(f, hc, heat_flux, case, *, w_mech=None, dx=400.0, edge=EDGE):
    """Карты слоёв (ny, nx) bool для сравнения положения (IoU): источники (с соседями ±1 клетка), подъём у склона,
    подветренная зона на 25 м. Те же пороги, что layer_metrics."""
    f = np.asarray(f, np.float32)
    hc = np.asarray(hc, np.float64)
    ny, nx = hc.shape
    inner = np.zeros((ny, nx), bool)
    inner[edge:ny - edge, edge:nx - edge] = True
    col = thermal_columns(f, hc, heat_flux, case, w_mech, case.get("h_eff"))
    sj, si, *_ = select_sources(col, dx, edge)
    src = np.zeros((ny, nx), bool)
    for dj in (-1, 0, 1):
        for di in (-1, 0, 1):
            src[np.clip(sj + dj, 0, ny - 1), np.clip(si + di, 0, nx - 1)] = True
    e = wind_unit(case["wdir_from_deg"])
    gy, gx = np.gradient(hc, dx)
    w = np.asarray(f[2] if w_mech is None else w_mech, np.float64)
    ww = (layer_weights(*SL_LAYER)[:, None, None] * w).sum(0)
    sl = inner & (gx * e[0] + gy * e[1] > SL_SLOPE_MIN) & (ww > SL_W_THR)
    flag, *_ = lee_flag(np.asarray(f[0], np.float64), np.asarray(f[1], np.float64), w)
    lee = inner & (flag[0] >= LEE_THR)
    return dict(th=src, sl=sl, lee=lee)


def iou(a, b):
    """Пересечение/объединение двух карт; обе пусты — 1 (совпадают), NaN не бывает."""
    u = np.logical_or(a, b).sum()
    return 1.0 if u == 0 else float(np.logical_and(a, b).sum() / u)
