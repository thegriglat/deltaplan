"""Механизм G — вечерний сток холодного воздуха (P9, AP-18; построен заново, не из AP-17).

Что моделируется: после захода солнца земля выхолаживается, у склонов под устойчивым слоем образуется тонкий холодный
слой, который стекает вниз по уклону (стоковый, катабатический ветер), а внизу — в долинах и котловинах — холодный
воздух собирается (накопление холода, «озёра» холода). Сетка — S5 v4 (96 × 96 клеток по 400 м, 13 высот над землёй).
Всё — на CPU, numpy/scipy.

1. Когда (`active`). Поток явного тепла клетки ≤ 0 (вход решателя `heat_flux` — в S2 он нулевой при солнце ниже ≈ −3°)
   и солнце ниже 5° (радиационный баланс у земли меняет знак незадолго до заката; Stull 1988 §1.6, Whiteman 2000 гл. 9),
   устойчивость N > 0. Нагрев (H > 0) и G исключают друг друга.
2. Выхолаживание. Поток явного тепла вниз H_c = −H_CLEAR·(1 − 0,75·c), c — облачность строки S2; множитель 1 − 0,75·c —
   тот же, что у нагрева в погоде S2 v4 (`s5_io.weather_cfg`: heat = 1 − 0,75·cover), — облака держат длинноволновое
   излучение. H_CLEAR = 30 Вт/м² — типичный ночной поток явного тепла над сушей при ясном небе и слабом ветре
   (диапазон −10…−50 Вт/м²: Stull 1988 §1.6 и рис. 1.10; Garratt 1992 §6.1; Mahrt 1998, «Stratified atmospheric boundary
   layers and breakdown of models», Theor. Comput. Fluid Dyn. 11).
3. Склон — модель Прандтля (Prandtl 1942, «Führer durch die Strömungslehre»; разбор — Zardi & Whiteman 2013, «Diurnal
   mountain wind systems», в кн. Mountain Weather Research and Forecasting, Springer, §2.4; Oerlemans & Grisogono 2002,
   Tellus 54A, 440–452). Бесконечный склон с углом α в устойчивой атмосфере N, постоянные K = K_h (Pr = 1), стационарно,
   n — расстояние от склона по нормали:
       θ′(n) = −Δθ·e^(−n/l)·cos(n/l),     u(n) = Δθ·g/(θ0·N)·e^(−n/l)·sin(n/l)   (вниз по склону),
       l = √(2K/(N·sin α)).
   Замыкание по потоку тепла (вместо заданного перепада): H = −ρc_p·K·∂θ′/∂n|₀ ⇒ Δθ = |H_c|·l/(ρc_p·K).
   Отсюда u_max = e^(−π/4)·sin(π/4)·Δθ·g/(θ0·N) ≈ 0,322·Δθ·g/(θ0·N) на высоте n_j = π·l/4 и расход на единицу ширины
   q = ∫u dn = Δθ·g/(θ0·N)·l/2.
   K = 0,3 м²/с — оценка длиной перемешивания в струе: K ≈ κ·u*·n_j/φ_m, u* ≈ 0,1·u_max ≈ 0,15–0,2 м/с, n_j ≈ 20 м,
   φ_m = 1 + 5·n/L ≈ 2 (Бузингер–Дайер) — порядок 0,2–0,5 м²/с (численная оценка, помечено).
   N — из строки условий (`n_bv_s`, свободная атмосфера); в приземной инверсии N больше, тогда u_max ∝ N^(−3/2) меньше —
   оценка по N свободной атмосферы — верхняя.
   Модель Прандтля завышает струю на пологих склонах (l, Δθ → ∞ при α → 0): склон учитывается при sin α ≥ SIN_MIN = 0,02,
   Δθ ≤ DTH_MAX = 6 К (типичная сила склоновой/долинной инверсии вечером — 3–10 К, Whiteman 2000 гл. 9) и
   u_max ≤ U_MAX = 3,5 м/с (верх наблюдаемых склоновых стоков на склонах сотни метров — 1–3,5 м/с, Zardi & Whiteman 2013).
4. Накопление в долинах — объёмный баланс гидравлического слоя (Fleagle 1950; Manins & Sawford 1979, J. Atmos. Sci. 36,
   619–630 — объёмная модель стока). Расход склонов собирается вниз по рельефу (D8: каждая клетка отдаёт всё соседу с
   наибольшим уклоном, рельеф сглажен гауссом в 1 клетку): Q = Σ q·Δx по водосбору, м³/с. В клетке слой глубиной d
   и скоростью u_c: Q = u_c·d·Δx; баланс плавучести и трения слоя: g′·d·sin α = C_D·u_c² (g′ = g·Δθ/(2θ0) — средний
   дефицит линейного профиля θ′ = −Δθ·(1 − z/d)), откуда d = (Q/Δx)^(2/3)·(C_D/(g′·sin α))^(1/3). C_D = 0,01 — трение
   о землю и вовлечение вместе (k ≈ 0,003–0,01 и E ≈ 0,001–0,01 у Manins & Sawford — порядок, помечено). На плоском
   дне (sin α → 0) слой растёт — это и есть «озеро»; глубина ограничена половиной местного перепада (радиус 2 км) и
   D_MAX = 300 м (глубина холодных озёр долин такого масштаба — 50–400 м, Whiteman 2000 гл. 9), сверх — растекание:
   u_c = Q/(d·Δx). Время не моделируется: состояние — установившееся для текущего выхолаживания (на 1–3 ч после заката
   водосбор в десятки километров за 1–2 м/с успевает стечь лишь частично — завышение Q в больших долинах, помечено).
5. Вес фазы G — стоковый ветер против фонового: w_G = active·σ((lg u_G − lg U_bg(z_G))/0,15), u_G — большее из u_max
   склона и u_c слоя, z_G — его высота (n_j или d/2), U_bg — профиль притока решателя (`mechanisms.bg_profile`). При
   фоне сильнее стока перемешивание сдувает холодный слой (сток наблюдается при фоне ≲ 2–3 м/с у земли — Whiteman 2000).
   Ширина 0,15 декады — «промежуточная» ширина классификатора (air_phase_results.md §0), не измерена для G.
Поле G на высотах AGL: в слое (склон — n < 3l, слой — z < d, сглаженный верх ×1,5) скорость G вниз по уклону
(склон — профиль Прандтля, слой — однородная u_c), θ′_G — профиль Прандтля / линейный дефицит слоя; `member` (13, ny, nx)
— доля замены фонового поля по высоте. Сборка с фоном — `hybrid.pipeline`: u = (1 − w_G·member)·u_фон + w_G·member·u_G,
θ′ += w_G·θ′_G, w — из проекции.

Границы: нет утреннего (рассветного) режима и ночной эволюции во времени, нет склоново-долинного перехода по времени,
нет взаимодействия с фоновым ветром кроме веса (струя не смещается ветром), нет облачного переноса и испарения; поток
выхолаживания задан, а не из баланса излучения; Picard-решатель этой физики не имеет (у него нет потока тепла < 0),
поэтому сравнить G с Пикаром нельзя — только с литературой.
"""
from __future__ import annotations

import math

import numpy as np

from assembly import mechanisms as M

H_CLEAR = 30.0          # Вт/м², ночной поток явного тепла при ясном небе (Stull 1988; Garratt 1992)
CLOUD_K = 0.75          # множитель облачности, как нагрев в S2 v4
K_KAT = 0.3             # м²/с, K в струе (оценка длиной перемешивания, помечено)
SIN_MIN = 0.02          # склон для модели Прандтля
DTH_MAX = 6.0           # К
U_MAX = 3.5             # м/с
C_D = 0.01              # трение + вовлечение слоя (Manins & Sawford 1979, порядок)
SIN_FLOOR = 0.005       # уклон «плоского дна» для гидравлического слоя
D_MAX = 300.0           # м, верх глубины холодного озера
RELIEF_R_M = 2000.0     # радиус местного перепада для ограничения глубины
SUN_MAX_DEG = 5.0
W_DEC = 0.15
PRANDTL_PEAK = math.exp(-math.pi / 4) * math.sin(math.pi / 4)   # 0,3224


def prandtl(sin_a, n_bv, h_cool):
    """Модель Прандтля с замыканием по потоку: → (l, Δθ, u_s = Δθ·g/(θ0 N), u_max, n_j, q) по клеткам."""
    s = np.maximum(sin_a, SIN_MIN)
    l = np.sqrt(2.0 * K_KAT / (n_bv * s))
    dth = np.minimum(abs(h_cool) * l / (M.RHO_CP * K_KAT), DTH_MAX)
    us = dth * M.G / (M.THETA0 * n_bv)
    us = np.minimum(us, U_MAX / PRANDTL_PEAK)
    dth = us * M.THETA0 * n_bv / M.G
    on = sin_a >= SIN_MIN
    us = np.where(on, us, 0.0)
    return dict(l=l, dth=dth, us=us, umax=PRANDTL_PEAK * us, nj=0.25 * math.pi * l, q=0.5 * us * l, on=on)


def d8_accumulate(h, q_cell, dx=M.DX):
    """D8: каждая клетка отдаёт накопленный расход соседу с наибольшим уклоном вниз (если он ниже). → (Q м³/с,
    единичный вектор направления стока (ex, ey) по клеткам, маска стока наружу/в яму)."""
    ny, nx = h.shape
    Q = q_cell * dx
    ex = np.zeros_like(h); ey = np.zeros_like(h)
    order = np.argsort(h, axis=None)[::-1]
    nb = [(dj, di) for dj in (-1, 0, 1) for di in (-1, 0, 1) if (dj, di) != (0, 0)]
    for f in order:
        j, i = divmod(int(f), nx)
        best, bj, bi = 0.0, -1, -1
        for dj, di in nb:
            jj, ii = j + dj, i + di
            if 0 <= jj < ny and 0 <= ii < nx:
                s = (h[j, i] - h[jj, ii]) / (dx * math.hypot(dj, di))
                if s > best:
                    best, bj, bi = s, jj, ii
        if bj >= 0:
            Q[bj, bi] += Q[j, i]
            r = math.hypot(bj - j, bi - i)
            ex[j, i], ey[j, i] = (bi - i) / r, (bj - j) / r       # i — восток, j — север
    return Q, ex, ey


def local_relief(hc, radius_m=RELIEF_R_M, dx=M.DX):
    from scipy.ndimage import maximum_filter, minimum_filter
    r = max(1, int(round(radius_m / dx)))
    size = 2 * r + 1
    return maximum_filter(hc, size=size, mode="nearest") - minimum_filter(hc, size=size, mode="nearest")


def evening_drainage(hc, heat, cond, dx=M.DX):
    """G на сетке S5. hc (ny, nx) м н. у. м.; heat (ny, nx) Вт/м² (вход решателя) или None; cond — строка S2 (dict).
    → dict: w (ny, nx) — вес фазы G (0, если не активна), u, v, th, member (13, ny, nx), diag (числа для отчёта)."""
    hc = np.asarray(hc, np.float64)
    ny, nx = hc.shape
    nz = len(M.AGL_M)
    zero3 = np.zeros((nz, ny, nx))
    n_bv = float(cond.get("n_bv_s", 0.0))
    sun = float(cond.get("sun_el_deg", 90.0))
    hs = float(cond.get("hs_w_m2", 0.0))
    cell_cool = np.ones((ny, nx), bool) if heat is None else (np.asarray(heat, np.float64) <= 0.0)
    out = dict(w=np.zeros((ny, nx)), u=zero3, v=zero3.copy(), th=zero3.copy(), member=zero3.copy(),
               diag=dict(active=False))
    if not (hs <= 0.0 and sun < SUN_MAX_DEG and n_bv > 1e-4 and cell_cool.any()):
        return out
    cc = float(np.clip(cond.get("cloud_cover", 0.0), 0.0, 1.0))
    h_cool = -H_CLEAR * (1.0 - CLOUD_K * cc)
    hs_ = M.gauss2d(hc, 1.0)
    gy, gx = np.gradient(hs_, dx)
    grad = np.hypot(gx, gy)
    sin_a = grad / np.sqrt(1.0 + grad ** 2)
    P = prandtl(sin_a, n_bv, h_cool)
    dn_x = np.where(grad > 0, -gx / np.maximum(grad, 1e-12), 0.0)   # вниз по уклону
    dn_y = np.where(grad > 0, -gy / np.maximum(grad, 1e-12), 0.0)
    q = np.where(cell_cool, P["q"], 0.0)
    Q, ex8, ey8 = d8_accumulate(hs_, q, dx)
    dth_c = float(np.median(P["dth"][P["on"]])) if P["on"].any() else DTH_MAX
    gp = M.G * dth_c / (2.0 * M.THETA0)
    sf = np.maximum(sin_a, SIN_FLOOR)
    d = (Q / dx) ** (2.0 / 3.0) * (C_D / (gp * sf)) ** (1.0 / 3.0)
    d_cap = np.minimum(0.5 * local_relief(hc, dx=dx), D_MAX)
    d = np.minimum(d, np.maximum(d_cap, 1.0))
    uc = np.minimum(np.sqrt(gp * d * sf / C_D), Q / np.maximum(d * dx, 1e-9))
    uc = np.minimum(uc, U_MAX)
    layer = d > 3.0 * P["l"]                                          # слой толще склоновой струи — сток долины
    z = M.AGL_M[:, None, None]
    # склон
    xn = z / P["l"][None]
    u_slope = P["us"][None] * np.exp(-xn) * np.sin(xn)
    th_slope = -P["dth"][None] * np.exp(-xn) * np.cos(xn) * P["on"][None]
    top_s = 3.0 * P["l"]
    # слой долины
    u_layer = np.broadcast_to(uc[None], (nz, ny, nx))
    th_layer = -dth_c * np.clip(1.0 - z / np.maximum(d[None], 1.0), 0.0, 1.0)
    top = np.where(layer, d, top_s)
    member = _member(z, top)
    sp = np.where(layer[None], u_layer, u_slope)
    exd = np.where(layer, ex8, dn_x); eyd = np.where(layer, ey8, dn_y)
    th = np.where(layer[None], th_layer, th_slope) * member
    u = sp * exd[None] * member
    v = sp * eyd[None] * member
    uG = np.where(layer, uc, P["umax"])
    zG = np.where(layer, 0.5 * d, P["nj"])
    ubg = M.bg_profile(np.maximum(zG, 2.0), float(cond["u_sat_m_s"]), float(cond["alpha"]), float(cond["max_profile"]))
    w = 1.0 / (1.0 + np.exp(-(np.log10(np.maximum(uG, 1e-6)) - np.log10(np.maximum(ubg, 1e-6))) / W_DEC))
    w = np.where(cell_cool & ((P["on"]) | layer), w, 0.0)
    out.update(w=w, u=u, v=v, th=th, member=member,
               diag=dict(active=True, h_cool_wm2=h_cool, dth_med_k=dth_c, umax_med=float(np.median(P["umax"][P["on"]])) if P["on"].any() else 0.0,
                         l_med_m=float(np.median(P["l"][P["on"]])) if P["on"].any() else 0.0,
                         layer_frac=float(layer.mean()), d_layer_med_m=float(np.median(d[layer])) if layer.any() else 0.0,
                         uc_layer_med=float(np.median(uc[layer])) if layer.any() else 0.0,
                         w_mean=float(w.mean()), w_ge05_frac=float((w >= 0.5).mean())))
    return out


def _member(z, top):
    """Доля замены по высоте: 1 ниже top, сглаженный спад до 0 к 1,5·top (smoothstep)."""
    t = np.clip((z - top[None]) / (0.5 * np.maximum(top[None], 1.0)), 0.0, 1.0)
    return 1.0 - t * t * (3.0 - 2.0 * t)
