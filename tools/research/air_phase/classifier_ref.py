"""P15 (docs/contracts/air-phase.md): эталонный классификатор фаз на Python — тот же, что спецификация AP-18
(`analysis/AP-18/section.md`, `hybrid/pipeline.py` + `assembly/assemble.classify`), в порядке фаз игры P10
`AirPhase.PHASES = ["A","B","C","D","F","G","H"]`, параметры — плоский словарь в формате `configs/atmosphere.json →
air_phase` (ключ + `<ключ>_doc`). Входы — только то, что знает игра: рельеф hc (96 × 96, м н. у. м.), строка условий S2
(ветер, профиль, z_i, N, Fr, солнце, облачность, поток тепла H_s) и поле потока явного тепла (функция рельефа и условий,
как вход решателя). Поле решателя не используется.

Фазы и кто их считает (решение пользователя 06.10, план §9): Пикар — A (обтекание, наветренные склоны), B (срыв за
бровкой, под огибающей), C (волны), слабое D; механизмы (колонны замораживаются) — H (штиль), сильное D, F (свободная
конвекция), G (вечерний сток).

Веса (σ(x) = 1/(1 + e^(−x)), ширины w — в декадах lg; Fr = U_sat/(N·h) по случаю):
  H   = 1 − σ((lg X_H − lg h_c)/h_w),   X_H = Fr (AP-18) или U10 (`h_axis`);
  Ds  = (1 − H)·(1 − σ((lg X_S − lg d_strong_c)/d_strong_w)),  X_S = Fr (AP-18), U_sat/N или «нет» — сильное D,
        вес для заморозки (подмножество D);
  D   = (1 − H)·(1 − σ((lg Fr − lg d_fr_c)/d_w)) [× блок ниже разделяющей линии тока при `d_local`: smoothstep(0,
        d_local_ramp_m, H_c − h), H_c = base + (h_max − base)(1 − Fr), Sheppard 1956; Snyder et al. 1985, JFM 152];
  C   = (1 − H)·(1 − D)·σ((lg(U_sat·|e·∇h_s|) − lg c_w_ms)/c_w) по клеткам — гидростатические волны: w ≈ U·∂h/∂x на
        всех высотах при a ≫ U/N (Smith 1979, Adv. Geophys. 21; Durran 1990), h_s — рельеф, сглаженный на масштабе U/N
        (не меньше клетки), e — направление ветра; c_w_ms — порог «слой видит волну» (min_sink дельтаплана ≈ 1 м/с);
  A   = 1 − H − D − C;
  B   = smoothstep(0, b_depth_m, h_eff − h) под огибающей угла b_env_angle_deg (AP-10), с нагревом
        × (1 − smoothstep(b_heat_lo, b_heat_hi, H_s)·(1 при s < b_steep, иначе 0,5)); A, C, D, H × (1 − B);
  F   (решение «h») = σ((lg(−z_i/L) − lg f_zil_c)/f_w) при H_s > 0; остальные × (1 − F);
  G   (решение «h») = вес `hybrid.drainage.evening_drainage` (Прандтль + гидравлический слой, AP-18); остальные × (1 − G).
  Сглаживание — гаусс smooth_cells клеток, затем Σ = 1.
Заморозка (механизм вместо Пикара): вся область при H + Ds ≥ freeze_w; F — клетки F ≥ freeze_w и w* ≥
f_wstar_over_usat·U_sat (только «h»); G — клетки G ≥ freeze_w (только «h»). Карта ω — AP-18 (полоса Fr / U10).
"""
from __future__ import annotations

import math

import numpy as np

from assembly import mechanisms as M

PHASES = ("A", "B", "C", "D", "F", "G", "H")
PI = {p: i for i, p in enumerate(PHASES)}
PICARD = ("A", "B", "C", "D")          # D здесь — слабое; сильное D — заморозка по Ds

# Конфиг AP-18 (спецификация переноса, до пересчёта AP-14) в формате configs/atmosphere.json → air_phase.
CONFIG_AP18 = {
    "h_axis": "fr", "h_axis_doc": "Ось штиля H: fr — Fr = U_sat/(N·h) (AP-18), u10 — ветер на 10 м.",
    "h_c": 0.25, "h_c_doc": "Центр границы H (по оси h_axis); AP-18: Fr ≲ 0,25 — блуждание Пикара (air_phase_results §0).",
    "h_w_dec": 0.05, "h_w_dec_doc": "Ширина сигмоиды H, декады lg.",
    "d_strong_axis": "fr", "d_strong_axis_doc": "Ось сильного D (заморозка): fr, u_over_n (U_sat/N, м), nc_law (N_c(U)/N, N_c = d_strong_nc0·(U_sat/3 м/с)^d_strong_p — закон AP-13) или none.",
    "d_strong_nc0": 0.0121, "d_strong_nc0_doc": "N_c при U_sat = 3 м/с для nc_law, 1/с (AP-13, ω = 0,5).",
    "d_strong_p": 0.71, "d_strong_p_doc": "Показатель N_c ∝ U^p для nc_law (AP-13: 0,70–0,71).",
    "d_strong_c": 0.3, "d_strong_c_doc": "Центр сильного D; AP-18: Fr < 0,3 — вся область механизмам.",
    "d_strong_w_dec": 0.05, "d_strong_w_dec_doc": "Ширина сигмоиды сильного D, декады.",
    "d_fr_c": 1.0, "d_fr_c_doc": "Граница D (блокирование) по Fr: AP-8 резкие параметры Fr_c 0,84–1,1.",
    "d_w_dec": 0.10, "d_w_dec_doc": "Ширина D: на эрозии 0,05–0,12 дек (AP-11).",
    "d_local": False, "d_local_doc": "D только ниже разделяющей линии тока H_c (Sheppard 1956) — по клеткам.",
    "d_local_ramp_m": 100.0, "d_local_ramp_m_doc": "Переход D по H_c − h, м.",
    "c_w_ms": 0.0, "c_w_ms_doc": "Порог волн C по U_sat·s95, м/с (0 — фаза C выключена, как в AP-18).",
    "c_w_dec": 0.10, "c_w_dec_doc": "Ширина сигмоиды C, декады.",
    "b_env_angle_deg": 12.0, "b_env_angle_deg_doc": "Угол огибающей (линии тени), AP-10 / lee.shadow_angle_deg.",
    "b_depth_m": 50.0, "b_depth_m_doc": "Глубина под огибающей до полного веса B, м (AP-17).",
    "b_heat_lo": 100.0, "b_heat_hi": 250.0, "b_steep": 0.4,
    "b_heat_doc": "AP-10: нагрев 100–250 Вт/м² убирает пузырь при s = 0,3, при s = 0,5 укорачивает вдвое.",
    "f_zil_c": 35.0, "f_zil_c_doc": "F по −z_i/L: потолок термиков Fr_c ≈ 1,5 ⇔ −z_i/L ≈ 35 (AP-8).",
    "f_w_dec": 0.2, "f_w_dec_doc": "Ширина F (промежуточная, 0,1–0,25 дек).",
    "f_wstar_over_usat": 1.0, "f_wstar_over_usat_doc": "Заморозка F при w* ≥ U_sat (свободная конвекция; Weckwerth 1999).",
    "smooth_cells": 1.0, "smooth_cells_doc": "Гаусс по весам, клетки (против «шахматки»).",
    "freeze_w": 0.5, "freeze_w_doc": "Порог веса механизма для заморозки колонн.",
    "omega_fr_lo": 0.3, "omega_fr_hi": 1.1, "omega_u10_lo": 0.6, "omega_u10_hi": 1.5, "omega_w_dec": 0.05,
    "omega_band": 0.5, "omega_doc": "Карта ω (AP-18): ω = 1 − (1 − omega_band)·max(b_Fr, b_U10).",
}


def cfg_values(cfg):
    """Конфиг без ключей *_doc."""
    return {k: v for k, v in cfg.items() if not k.endswith("_doc")}


def merged(base=None, **over):
    c = dict(CONFIG_AP18 if base is None else base)
    c.update(over)
    return c


def _sig(x, xc, w):
    x = np.maximum(np.asarray(x, np.float64), 1e-12)
    return 1.0 / (1.0 + np.exp(-(np.log10(x) - math.log10(xc)) / w))


def _band(x, lo, hi, w):
    return float(_sig(x, lo, w) * (1.0 - _sig(x, hi, w)))


def case_scalars(hc, cond):
    """Величины случая, которые знает игра: Fr, U10, U_sat, N, U_sat/N, перепад, s95 сглаженного рельефа, H_c."""
    hc = np.asarray(hc, np.float64)
    fr, u10, usat, nbv = (float(cond[k]) for k in ("froude", "u10_m_s", "u_sat_m_s", "n_bv_s"))
    lam = usat / max(nbv, 1e-6)
    sig = max(1.0, lam / M.DX)
    hs = M.gauss2d(hc, sig)
    gy, gx = np.gradient(hs, M.DX)
    e = M.wind_unit(cond["wind_from_deg"])
    s_along = np.abs(gx * e[0] + gy * e[1])
    s95 = float(np.percentile(s_along[5:-5, 5:-5], 95))
    Hc, base = M.dividing_height(hc, fr)
    return dict(fr=fr, u10=u10, usat=usat, nbv=nbv, u_over_n=lam, s95=s95, Hc=Hc, base=base,
                relief=float(hc.max() - base), _s_along=s_along)


def case_weights(sc, c):
    """Случайные (однородные по области) веса: H, Ds (сильное D), D_случая, C."""
    xh = sc["fr"] if c["h_axis"] == "fr" else sc["u10"]
    wH = float(1.0 - _sig(xh, c["h_c"], c["h_w_dec"]))
    ax = c["d_strong_axis"]
    if ax == "none":
        sS = 0.0
    else:
        if ax == "nc_law":
            xs = c["d_strong_nc0"] * (max(sc["usat"], 1e-3) / 3.0) ** c["d_strong_p"] / max(sc["nbv"], 1e-6)
        else:
            xs = sc["fr"] if ax == "fr" else sc["u_over_n"]
        sS = float(1.0 - _sig(xs, c["d_strong_c"], c["d_strong_w_dec"]))
    wDs = (1.0 - wH) * sS
    wD = (1.0 - wH) * float(1.0 - _sig(sc["fr"], c["d_fr_c"], c["d_w_dec"]))
    return dict(wH=wH, wDs=wDs, wD=wD, full=bool(wH + wDs >= c["freeze_w"]))


def omega_of(sc, c):
    b = max(_band(sc["fr"], c["omega_fr_lo"], c["omega_fr_hi"], c["omega_w_dec"]),
            _band(sc["u10"], c["omega_u10_lo"], c["omega_u10_hi"], c["omega_w_dec"]))
    om = 1.0 - (1.0 - c["omega_band"]) * b
    return 1.0 if om > 0.99 else om


def envelope_depth(hc, cond, c):
    he = M.envelope(hc, cond["wind_from_deg"], c["b_env_angle_deg"])
    return he - np.asarray(hc, np.float64)


def classify(hc, cond, heat=None, decision="h", cfg=None, env_depth=None, drainage=None):
    """→ dict: weights (7, ny, nx) f4 (PHASES, Σ = 1), omega (скаляр — однородна по случаю), freeze (ny, nx) bool,
    info (случайные веса, доли). decision: "m" — без нагрева (F, G нет), "h" — с нагревом heat (Вт/м²).
    env_depth (h_eff − h) и drainage (результат evening_drainage) можно передать готовыми (кэш)."""
    c = dict(CONFIG_AP18)
    if cfg:
        c.update(cfg)
    hc = np.asarray(hc, np.float64)
    ny, nx = hc.shape
    sc = case_scalars(hc, cond)
    cw = case_weights(sc, c)
    one = np.ones((ny, nx))
    wH = cw["wH"] * one
    wD = cw["wD"] * one
    if c["d_local"]:
        wD = wD * M.smoothstep(0.0, c["d_local_ramp_m"], sc["Hc"] - hc)
    if c["c_w_ms"] > 0:
        wC = (1.0 - wH) * (1.0 - wD) * _sig(np.maximum(sc["usat"] * sc["_s_along"], 1e-6), c["c_w_ms"], c["c_w_dec"])
    else:
        wC = 0.0 * one
    wA = np.clip(1.0 - wH - wD - wC, 0.0, None)
    dep = envelope_depth(hc, cond, c) if env_depth is None else env_depth
    wB = M.smoothstep(0.0, c["b_depth_m"], dep)
    heated = decision == "h" and heat is not None and np.any(np.asarray(heat) > 0)
    if heated:
        gy, gx = np.gradient(hc, M.DX)
        s = np.hypot(gx, gy)
        sup = M.smoothstep(c["b_heat_lo"], c["b_heat_hi"], np.asarray(heat, np.float64))
        wB = wB * (1.0 - sup * np.where(s < c["b_steep"], 1.0, 0.5))
    wA, wC, wD, wH = (x * (1.0 - wB) for x in (wA, wC, wD, wH))
    zi_msl = float(cond["z_i_m"])
    wF = np.zeros((ny, nx))
    wstar = np.zeros((ny, nx))
    if heated:
        bl = M.bl_state(hc, heat, zi_msl, sc["u10"])
        wstar = bl["wstar"]
        if bl["ustar"] > 0:
            zil = bl["h"] * M.KAPPA * M.G * np.maximum(bl["Hk"], 0.0) / (M.THETA0 * bl["ustar"] ** 3)
            wF = np.where(bl["Hk"] > 0, _sig(np.maximum(zil, 1e-6), c["f_zil_c"], c["f_w_dec"]), 0.0)
        else:
            wF = np.where(np.asarray(heat) > 0, 1.0, 0.0)
    wG = np.zeros((ny, nx))
    if decision == "h":
        if drainage is None:
            from hybrid import drainage as DR
            drainage = DR.evening_drainage(hc, heat, cond)
        wG = np.asarray(drainage["w"], np.float64)
    W = np.stack([wA, wB, wC, wD, np.zeros_like(wA), np.zeros_like(wA), wH])
    W = W * (1.0 - wF)[None]
    W[PI["F"]] = wF
    W = W * (1.0 - wG)[None]
    W[PI["G"]] = wG
    if c["smooth_cells"] > 0:
        W = np.stack([M.gauss2d(x, c["smooth_cells"]) for x in W])
    W = np.clip(W, 0.0, None)
    W /= np.maximum(W.sum(0, keepdims=True), 1e-12)
    fz_full = np.full((ny, nx), cw["full"])
    fz_f = (W[PI["F"]] >= c["freeze_w"]) & (wstar >= c["f_wstar_over_usat"] * sc["usat"])
    fz_g = W[PI["G"]] >= c["freeze_w"]
    freeze = fz_full | fz_f | fz_g if decision == "h" else fz_full
    sc = {k: v for k, v in sc.items() if not k.startswith("_")}
    info = dict(sc, **cw, omega=omega_of(sc, c), f_frac=float(fz_f.mean()) if decision == "h" else 0.0,
                g_frac=float(fz_g.mean()) if decision == "h" else 0.0, freeze_frac=float(freeze.mean()),
                b_frac=float((W[PI["B"]] >= 0.5).mean()), c_frac=float((W[PI["C"]] >= 0.5).mean()), mean={p: float(W[i].mean()) for i, p in enumerate(PHASES)})
    info["route"] = "mech" if info["freeze_frac"] >= 0.5 else "picard"
    return dict(weights=W.astype(np.float32), omega=info["omega"], freeze=freeze, info=info)


def case_phase(info, decision):
    """Фаза случая по классификатору (для матриц по случаям): N — вся область механизмам (H или сильное D), F/G —
    заморозка ≥ половины области, иначе D (вес D случая ≥ 0,5), иначе A (B и C — местные, для них отдельные матрицы
    «есть / нет»)."""
    if info["full"]:
        return "H" if info["wH"] >= info["wDs"] else "Ds"
    if decision == "h" and info["f_frac"] >= 0.5:
        return "F"
    if decision == "h" and info["g_frac"] >= 0.5:
        return "G"
    if info["wD"] >= 0.5:
        return "D"
    return "A"
