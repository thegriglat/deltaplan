"""P8 v1: сборка поля масштаба 1 по фазам из рельефа и условий (без поля решателя). Формулы механизмов —
`mechanisms.py`; классификатор — здесь. Контракт — docs/contracts/air-phase.md P8; физика —
docs/research/air_phase_experts.md §12, §15; оси и пороги — docs/research/air_phase_results.md §0, §6, §7.

assemble(hc, cond, cfg=None) → dict:
  fields   (4, 13, 96, 96) f4 — u, v, w (м/с), θ′ (К) с нагревом (раскладка S5: [канал, высота AGL, j, i]);
  fields_m (3, 13, 96, 96) f4 — то же без нагрева (для w_mech слоёв и сравнения с решением «m» Пикара);
  weights  (K, 96, 96) f4 — веса фаз (Σ = 1), порядок — PHASES; weights_m — веса без нагрева;
  stats    — sigma_w (13, ny, nx) E/F, spread (ny, nx) H (оценка блуждания — 0,45·U_sat·w_H);
  seconds, steps (разбивка по шагам), div (∇·u до/после проекции), meta (Fr, H_c, base, …).

Классификатор (по клеткам, §15.1): веса как ступеньки-сигмоиды по осям итогов (§0):
  H   — σ((lg 0,25 − lg Fr)/0,05): штиль, поле Пикара — блуждание (Fr ≲ 0,25);
  D   — (1 − w_H)·σ((lg 1 − lg Fr)/0,10): блокирование, Fr_c ≈ 0,84–1,1 на идеальных формах (резкие параметры,
        w 0,01–0,04 дек), на эрозии ширина 0,05–0,12 дек (AP-11) — берём 0,10;
  A   — остальное механическое;
  LEE — срыв под огибающей 12° (AP-10: обратное течение при s ≈ 0,20–0,30 при всех Fr): s_lee = smoothstep(0, 50 м,
        h_eff − h), с нагревом ослаблен (AP-10: 100–250 Вт/м² убирают пузырь при s = 0,3, при s = 0,5 укорачивают
        вдвое): × (1 − smoothstep(100, 250, H)·(1 при s < 0,4, иначе 0,5)); механические веса × (1 − w_LEE);
  E/F — σ((lg(−z_i/L) − lg 35)/0,2) по местному −z_i/L (H клетки, h слоя, u*): ось потолка термиков (Fr_c ≈ 1,5 ⇔
        −z_i/L ≈ 35, ширина «промежуточная» 0,1–0,25 дек); остальные веса × (1 − w_EF).
  Сглаживание весов — гаусс σ = 1 клетка (против «шахматки», §15.1), затем нормировка Σ = 1.
Поле: u = Σ w_φ·u_φ по механическим фазам (у H среднее = поле D: предел Fr → 0, Drazin; разброс — stats) + w_EF·Δu_EF
(анабатика, простая форма) → один шаг проекции ∇·u = 0. θ′ — баланс тепла столба (`theta_march`) во всех клетках.
"""
from __future__ import annotations

import json
import math
import time

import numpy as np

from . import mechanisms as M

PHASES = ("A", "D", "LEE", "EF", "H")

DEFAULT_CFG = dict(
    version="assembly_v1",
    fr_d=1.0, w_d=0.10,                 # D: Fr_c, ширина (дек) — §0, AP-11
    fr_h=0.25, w_h=0.05,                # H: Fr ≲ 0,25 — §0
    env_angle_deg=12.0, lee_depth_m=50.0, lee_reverse=0.2,   # AP-10; B §12
    lee_heat_lo=100.0, lee_heat_hi=250.0, lee_steep=0.4,     # AP-10 нагрев
    zil_c=35.0, w_ef=0.2,               # E/F по −z_i/L — §0 п. 2
    smooth_cells=1.0,
    damp_m=20000.0, cap_frac=0.8,       # A: затухание волн (численное), ограничение линейной теории (страховка)
    dz_layer=100.0, max_layers=12,      # D: слои Лапласа
    slope_len_m=2000.0,                 # E/F анабатика (простая форма)
    spread_frac=0.45,                   # H: блуждание 0,39–0,56 U_sat (§0)
    project=True,
)


def _cfg(cfg):
    c = dict(DEFAULT_CFG)
    if cfg:
        c.update(cfg)
    return c


def mech_field(hc, e, Ucol, cond, cfg, n_eff, terrain=None):
    """Механическое поле (A или D по Fr) на рельефе terrain (по умолчанию hc); высоты — над hc.
    Ucol (13, ny, nx) — фон вдоль e. → dict: A=(u,v,w), D=(u,v,w), Hc, base."""
    t = hc if terrain is None else terrain
    Umean = Ucol.reshape(Ucol.shape[0], -1).mean(1)

    def U_of_z(z):
        return np.interp(np.asarray(z, np.float64), M.AGL_M, Umean)

    def a_on(h):
        du, dv, dw = M.linear_a(h, e, U_of_z, n_eff, dx=M.DX, damp_m=cfg["damp_m"], cap_frac=cfg["cap_frac"], U_level=Ucol)
        return du, dv, dw

    out = {}
    # A на полном рельефе (высоты над t; если t ≠ hc — пересчёт ниже вызывающим)
    du, dv, dw = a_on(t)
    out["A"] = (Ucol * e[0] + du, Ucol * e[1] + dv, dw)
    fr = float(cond["froude"])
    Hc, base = M.dividing_height(t, fr)
    out["Hc"], out["base"] = Hc, base
    if Hc <= base + 1.0:
        out["D"] = out["A"]
        out["n_layers"] = 0
        return out
    hcut = np.maximum(t, Hc)                                       # срезанный рельеф: ниже H_c — плоско на H_c
    du2, dv2, dw2 = a_on(hcut)
    zL, gx, gy = M.blocked_layers(t, Hc, base, e, cfg["dz_layer"], cfg["max_layers"])
    out["n_layers"] = len(zL)
    nz = len(M.AGL_M)
    u = np.empty((nz,) + hc.shape); v = np.empty_like(u); w = np.empty_like(u)
    above_cut = t >= Hc
    for k, z in enumerate(M.AGL_M):
        zmsl = t + z
        # выше H_c: A на срезанном рельефе; у клеток ниже H_c высота над плоскостью H_c
        za = np.where(above_cut, z, zmsl - Hc)
        ua = M.interp_levels(du2, za); va = M.interp_levels(dv2, za); wa = M.interp_levels(dw2, za, log_below=False)
        ub, vb = Ucol[k] * e[0] + ua, Ucol[k] * e[1] + va
        # ниже H_c: слой Лапласа (ближайший по высоте над морем), доля набегающей × фон столба
        q = np.clip(np.searchsorted(zL, zmsl) - 1, 0, len(zL) - 1)
        q2 = np.clip(q + 1, 0, len(zL) - 1)
        tq = np.clip((zmsl - zL[q]) / np.maximum(zL[q2] - zL[q], 1e-6), 0, 1)
        jj, ii = np.indices(hc.shape)
        lgx = (1 - tq) * gx[q, jj, ii] + tq * gx[q2, jj, ii]
        lgy = (1 - tq) * gy[q, jj, ii] + tq * gy[q2, jj, ii]
        low = zmsl < Hc
        u[k] = np.where(low, lgx * Ucol[k], ub)
        v[k] = np.where(low, lgy * Ucol[k], vb)
        w[k] = np.where(low, 0.0, wa)
    out["D"] = (u, v, w)
    return out


def _resample_over(F, depth, log_below=True):
    """Поле F (13, ny, nx), заданное по высотам над h_eff, — на высотах над hc: z_над_heff = z − depth."""
    out = np.empty_like(F)
    for k, z in enumerate(M.AGL_M):
        out[k] = M.interp_levels(F, z - depth, log_below=log_below)
    return out


def lee_field(hc, heff, e, Ucol, cond, cfg, n_eff, mech_heff):
    """LEE: обтекание огибающей (A/D на h_eff) выше линии тени + пузырь ниже (`bubble_profile`)."""
    depth = heff - hc
    fr = float(cond["froude"])
    sd = M.sigmoid_log(fr, cfg["fr_d"], cfg["w_d"])
    uo = tuple((1 - sd) * a + sd * d for a, d in zip(mech_heff["A"], mech_heff["D"]))
    u = _resample_over(uo[0], depth); v = _resample_over(uo[1], depth); w = _resample_over(uo[2], depth, log_below=False)
    utop = np.sqrt(uo[0][0] ** 2 + uo[1][0] ** 2)                 # скорость над огибающей (25 м над h_eff)
    for k, z in enumerate(M.AGL_M):
        inb = z < depth
        ub = M.bubble_profile(z, depth, utop, cfg["lee_reverse"])
        u[k] = np.where(inb, ub * e[0], u[k])
        v[k] = np.where(inb, ub * e[1], v[k])
        w[k] = np.where(inb, 0.0, w[k])
    return u, v, w


def classify(hc, heff, cond, bl, heat, cfg, heated):
    """Веса фаз (K, ny, nx) по PHASES — см. шапку модуля."""
    fr = float(cond["froude"])
    ny, nx = hc.shape
    wH = np.full((ny, nx), 1.0 - M.sigmoid_log(fr, cfg["fr_h"], cfg["w_h"]) if fr < 1e3 else 0.0)
    sD = M.sigmoid_log(fr, cfg["fr_d"], cfg["w_d"]) if fr < 1e3 else 0.0
    sD = 1.0 - sD                                                  # D при Fr < Fr_c
    wD = (1 - wH) * sD
    wA = (1 - wH) * (1 - sD)
    slee = M.smoothstep(0.0, cfg["lee_depth_m"], heff - hc)
    if heated and heat is not None:
        gy, gx = np.gradient(hc, M.DX)
        s = np.sqrt(gx ** 2 + gy ** 2)
        sup = M.smoothstep(cfg["lee_heat_lo"], cfg["lee_heat_hi"], np.asarray(heat, np.float64))
        slee = slee * (1 - sup * np.where(s < cfg["lee_steep"], 1.0, 0.5))
    wL = slee
    wA = wA * (1 - wL); wD = wD * (1 - wL); wH = wH * (1 - wL)
    if heated and heat is not None and bl["ustar"] > 0:
        zil = bl["h"] * M.KAPPA * M.G * np.maximum(bl["Hk"], 0.0) / (M.THETA0 * bl["ustar"] ** 3)
        wE = M.sigmoid_log(np.maximum(zil, 1e-6), cfg["zil_c"], cfg["w_ef"])
        wE = np.where(bl["Hk"] > 0, wE, 0.0)
    elif heated and heat is not None:
        wE = np.where(np.asarray(heat) > 0, 1.0, 0.0)
    else:
        wE = np.zeros((ny, nx))
    W = np.stack([wA * (1 - wE), wD * (1 - wE), wL * (1 - wE), wE, wH * (1 - wE)])
    if cfg["smooth_cells"] > 0:
        W = np.stack([M.gauss2d(x, cfg["smooth_cells"]) for x in W])
    W = np.clip(W, 0, None)
    W /= np.maximum(W.sum(0, keepdims=True), 1e-12)
    return W


def n_effective(cond, hc):
    """N для линейной теории: N над z_i, если рельеф пробивает слой перемешивания (z_i над базой < перепада), иначе
    N·(перепад/z_i) — слой перемешивания нейтрален, волны возбуждает только часть рельефа выше z_i (простая
    двухслойная замена, помечено)."""
    n = float(cond["n_bv_s"])
    relief = float(np.max(hc) - np.min(hc))
    zi_agl = float(cond["z_i_m"]) - float(np.min(hc))
    if zi_agl <= relief or zi_agl <= 0:
        return n
    return n * min(1.0, relief / zi_agl)


def assemble(hc, cond, *, cfg=None, heat=None):
    """P8: поле по фазам. hc (96, 96) м н. у. м.; cond — строка S2 (u10_m_s, wind_from_deg, alpha, max_profile,
    u_sat_m_s, z_i_m, n_bv_s, froude, …) как dict; heat (96, 96) Вт/м² — поток явного тепла (вход решателя
    `inputs/heat_flux`, функция рельефа и условий; None — 0). См. шапку модуля."""
    c = _cfg(cfg)
    t0 = time.perf_counter()
    steps = {}
    hc = np.asarray(hc, np.float64)
    e = M.wind_unit(cond["wind_from_deg"])
    heated = heat is not None and np.any(np.asarray(heat) > 0)
    n_eff = n_effective(cond, hc)
    meta = dict(froude=float(cond["froude"]), n_eff=n_eff)
    res = {}
    for variant in ("m", "h"):
        hv = heat if variant == "h" else None
        if variant == "h" and not (heat is not None and np.any(np.asarray(heat) != 0)):
            res["h"] = res["m"]
            continue
        ts = time.perf_counter()
        Ucol, bl = M.background_field(hc, cond, hv)
        steps[f"background_{variant}"] = time.perf_counter() - ts
        ts = time.perf_counter()
        mf = mech_field(hc, e, Ucol, cond, c, n_eff)
        steps[f"A_D_{variant}"] = time.perf_counter() - ts
        ts = time.perf_counter()
        heff = M.envelope(hc, cond["wind_from_deg"], c["env_angle_deg"])
        if np.any(heff > hc + 1.0):
            # фон над огибающей: тот же столб (по высоте над h_eff)
            mfe = mech_field(heff, e, Ucol, cond, c, n_eff)
            lu, lv, lw = lee_field(hc, heff, e, Ucol, cond, c, n_eff, mfe)
        else:
            lu, lv, lw = mf["A"]
        steps[f"lee_{variant}"] = time.perf_counter() - ts
        ts = time.perf_counter()
        W = classify(hc, heff, cond, bl, hv, c, variant == "h")
        wA, wD, wL, wE, wH = W
        uD = mf["D"]
        u = wA * mf["A"][0] + (wD + wH) * uD[0] + wL * lu
        v = wA * mf["A"][1] + (wD + wH) * uD[1] + wL * lv
        w = wA * mf["A"][2] + (wD + wH) * uD[2] + wL * lw
        # E/F: поле механики (по нормированным механическим весам) + анабатика
        sm = np.maximum(wA + wD + wH + wL, 1e-12)
        um = (wA * mf["A"][0] + (wD + wH) * uD[0] + wL * lu) / sm
        vm = (wA * mf["A"][1] + (wD + wH) * uD[1] + wL * lv) / sm
        wm = (wA * mf["A"][2] + (wD + wH) * uD[2] + wL * lw) / sm
        th = np.zeros_like(u)
        sigw = np.zeros_like(u)
        if variant == "h":
            au, av = M.anabatic(hc, bl["Hk"], bl["h"], slope_len_m=c["slope_len_m"])
            u = u + wE * (um + au)
            v = v + wE * (vm + av)
            w = w + wE * wm
            # θ′: баланс тепла столба; в слое h — равномерно (нагрев cbl), выше 0
            Uml = np.sqrt(u[:6] ** 2 + v[:6] ** 2).mean(0)
            th2 = M.theta_march(bl["Hk"], bl["h"], Uml, e)
            inside = M.AGL_M[:, None, None] < bl["h"][None]
            th = np.where(inside, th2[None], 0.0)
            # волновая часть θ′ = −dθ̄/dz·η (линейная теория, выше z_i — θ0N²/g; ниже — 0; в блокированном слое η = 0)
            Umean = Ucol.reshape(Ucol.shape[0], -1).mean(1)
            *_, eta = M.linear_a(hc, e, lambda z: np.interp(np.asarray(z, np.float64), M.AGL_M, Umean), n_eff,
                                 damp_m=c["damp_m"], cap_frac=None, eta=True)
            zmsl = hc[None] + M.AGL_M[:, None, None]
            gam = np.where(zmsl > float(cond["z_i_m"]), M.THETA0 * float(cond["n_bv_s"]) ** 2 / M.G, 0.0)
            blocked = zmsl < mf["Hc"]
            th = th - np.where(blocked, 0.0, gam * eta)
            sigw = M.similarity_sigma_w(bl["wstar"], bl["h"])
        else:
            u = u + wE * um; v = v + wE * vm; w = w + wE * wm
        steps[f"classify_blend_{variant}"] = time.perf_counter() - ts
        ts = time.perf_counter()
        if c["project"]:
            u, v, w, dinfo = M.project(u, v, w, hc)
        else:
            dinfo = {}
        steps[f"project_{variant}"] = time.perf_counter() - ts
        res[variant] = dict(u=u, v=v, w=w, th=th, W=W, div=dinfo, sigw=sigw, Hc=mf["Hc"], base=mf["base"],
                            n_layers=mf["n_layers"], shadow_frac=float(np.mean(heff > hc + 1.0)))
    rh, rm = res["h"], res["m"]
    fr = float(cond["froude"])
    spread = c["spread_frac"] * float(cond["u_sat_m_s"]) * rh["W"][PHASES.index("H")]
    meta.update(Hc=rm["Hc"], base=rm["base"], n_layers=rm["n_layers"], shadow_frac=rm["shadow_frac"])
    return dict(
        fields=np.stack([rh["u"], rh["v"], rh["w"], rh["th"]]).astype(np.float32),
        fields_m=np.stack([rm["u"], rm["v"], rm["w"]]).astype(np.float32),
        weights=rh["W"].astype(np.float32), weights_m=rm["W"].astype(np.float32), phases=PHASES,
        stats=dict(sigma_w=rh["sigw"].astype(np.float32), spread=spread.astype(np.float32)),
        seconds=time.perf_counter() - t0, steps=steps, div=dict(h=rh["div"], m=rm["div"]), meta=meta,
        cfg=json.dumps(c, ensure_ascii=False))
