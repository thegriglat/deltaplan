#!/usr/bin/env python3
"""Рассеянная освещённость горизонтальной площадки ясным небом — однократное рассеяние в атмосфере игры (HH-15).

    python3 single_scatter.py [--aod_ext=6.5e-5] [--haze_top=2000] [--ssa=0.9] [--g=0.7] [--json]

Та же атмосфера, что у SunTransmission (HH4): сферическая Земля R=6371 км, Рэлей β_R(550)=1,16e-5 1/м, шкала 8 км,
аэрозоль — слой постоянной плотности до верха дымки (ext 1/м на 550 нм), выше — 0. Наблюдатель на уровне моря.
L(ω) = ∫ [β_R p_R(γ) + β_a·ssa·p_a(γ)]·E_sun·T(сквозь атмосферу к солнцу)·T(к наблюдателю) ds, p_R = 3/(16π)(1+cos²γ),
p_a — Хеньи–Гринстейн (g). DHI = ∫_{верхняя полусфера} L cosθ dω. Только однократное рассеяние (недооценка рассеянного
света сумерек; многократное и отражение от земли не учтены). Результат — отношение к 35°: sky_k(el) = DHI(el)/DHI(35°).
"""
import json
import math
import sys

import numpy as np

R = 6371000.0
H = 8000.0
BR = 1.16e-5


def sun_tau(r, mu_sun, ext_a, top_a, nstep=96):
    """Оптические толщи (Рэлей, аэрозоль) от точек (радиус r, косинус угла луча к солнцу с местной вертикалью mu_sun)
    до выхода из атмосферы; np.inf-признак, если луч упирается в Землю (возвращает mask)."""
    # геометрия: точка на радиусе r, луч под углом с вертикалью (cos = mu). Перигей: r·sqrt(1-mu²) при mu<0.
    sin2 = 1.0 - mu_sun**2
    peri = r * np.sqrt(np.maximum(sin2, 0.0))
    blocked = (mu_sun < 0.0) & (peri < R)
    rtop = R + 100000.0
    s_exit = -r * mu_sun + np.sqrt(np.maximum(rtop**2 - r**2 * sin2, 0.0))
    # Рэлей: ∫ exp(-(|x|-R)/H) ds, шаг растёт квадратично (u²)
    u = (np.arange(nstep) + 0.5) / nstep
    s = s_exit[..., None] * u**2
    ds = s_exit[..., None] * 2 * u / nstep
    rr = np.sqrt(r[..., None] ** 2 + 2 * r[..., None] * mu_sun[..., None] * s + s**2)
    ir = (np.exp(-(rr - R) / H) * ds).sum(-1)
    # аэрозоль: длина части луча внутри сферы верха дымки (в слое постоянной плотности)
    rt = R + top_a
    d2 = rt**2 - r**2 * sin2
    sq = np.sqrt(np.maximum(d2, 0.0))
    s_out = -r * mu_sun + sq
    s_in = np.maximum(-r * mu_sun - sq, 0.0)
    ia = np.where(d2 > 0, np.maximum(s_out - s_in, 0.0), 0.0)
    # точка сама может лежать выше слоя (r>rt): тогда доля внутри — только если луч входит; формула выше уже даёт
    return BR * ir, ext_a * ia, blocked


def dhi(el_deg, ext_a, top_a, ssa, g, nz=48, na=36, ns=64):
    el = math.radians(el_deg)
    # направление на солнце в плоскости x–z: (cos el, 0, sin el); z — вертикаль
    sun = np.array([math.cos(el), 0.0, math.sin(el)])
    # квадратура по полусфере (cosθ_v веса): zenith θ ∈ [0, π/2], азимут φ ∈ [0, π] (симметрия, ×2)
    th = (np.arange(nz) + 0.5) / nz * (math.pi / 2)
    ph = (np.arange(na) + 0.5) / na * math.pi
    TH, PH = np.meshgrid(th, ph, indexing="ij")
    vx, vy, vz = np.sin(TH) * np.cos(PH), np.sin(TH) * np.sin(PH), np.cos(TH)
    cosg = vx * sun[0] + vz * sun[2]  # угол рассеяния между направлением луча зрения и направлением на солнце
    # вдоль луча зрения от наблюдателя (0,0,R): ray length до верха атмосферы
    rtop = R + 100000.0
    s_end = -R * vz + np.sqrt(R**2 * vz**2 + rtop**2 - R**2)
    u = (np.arange(ns) + 0.5) / ns
    s = s_end[..., None] * u**2
    ds = s_end[..., None] * 2 * u / ns
    px, pz = s * vx[..., None], R + s * vz[..., None]
    py = s * vy[..., None]
    r = np.sqrt(px**2 + py**2 + pz**2)
    h = r - R
    # плотности
    rho_r = np.exp(-h / H)
    rho_a = (r - R < top_a).astype(float)
    # пропускание к наблюдателю по лучу зрения (накопленное): оптическая толща от 0 до s
    tau_v_r = np.cumsum(BR * rho_r * ds, axis=-1) - 0.5 * BR * rho_r * ds
    tau_v_a = np.cumsum(ext_a * rho_a * ds, axis=-1) - 0.5 * ext_a * rho_a * ds
    # пропускание к солнцу из точки: местная вертикаль (px,py,pz)/r, косинус с направлением на солнце
    mu = (px * sun[0] + pz * sun[2]) / r
    tr, ta, blk = sun_tau(r, mu, ext_a, top_a)
    t_sun = np.exp(-(tr + ta)) * (~blk)
    t_view = np.exp(-(tau_v_r + tau_v_a * 1.0))
    cg = cosg[..., None]
    p_r = 3.0 / (16 * math.pi) * (1 + cg**2)
    p_a = (1 - g * g) / (4 * math.pi * (1 + g * g - 2 * g * cg) ** 1.5)
    src = (BR * rho_r * p_r + ext_a * rho_a * ssa * p_a) * t_sun * t_view
    lum = (src * ds).sum(-1)  # радианс при E_sun = 1
    w = np.cos(TH) * np.sin(TH) * (math.pi / 2 / nz) * (math.pi / na) * 2  # dω cosθ, φ∈[0,π] ×2
    return float((lum * w).sum())


def main():
    opts = dict(a[2:].split("=", 1) if "=" in a else (a[2:], "1") for a in sys.argv[1:] if a.startswith("--"))
    ext = float(opts.get("aod_ext", 6.5e-5))
    top = float(opts.get("haze_top", 2000.0))
    ssa = float(opts.get("ssa", 0.9))
    g = float(opts.get("g", 0.7))
    els = [-2, -1, 0, 0.5, 1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 18, 22, 26, 30, 35]
    ref = dhi(35.0, ext, top, ssa, g)
    rows = [{"el": e, "k": dhi(e, ext, top, ssa, g) / ref} for e in els]
    if "json" in opts:
        print(json.dumps({"ext": ext, "top": top, "ssa": ssa, "g": g, "rows": rows}))
    else:
        print("ext=%.2e top=%.0f ssa=%.2f g=%.2f  DHI(35)/E_sun=%.4f" % (ext, top, ssa, g, ref))
        for r in rows:
            print("%5.1f %.4f" % (r["el"], r["k"]))


if __name__ == "__main__":
    main()
