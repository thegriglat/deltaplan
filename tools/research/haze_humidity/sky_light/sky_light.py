#!/usr/bin/env python3
"""Рассеянная освещённость безоблачного неба по высоте солнца (HH-15): ESRA и Bird–Hulstrom.

    python3 sky_light.py [--tl=3.0] [--aod=0.12] [--json]

sky_k(el) = DHI(el) / DHI(35°) — рассеянная горизонтальная освещённость (поток энергии, W/m²) относительно 35°
(та же нормировка, что у света солнца: T_ref при 35°). Основная модель — ESRA (Rigollier, Bauer, Wald 2000, Solar
Energy 68(1); формулы — European Solar Radiation Atlas, Remund et al.), сверка — Bird & Hulstrom 1981 (SERI/TR-642-761).
Печатает таблицу по el, ESRA, Bird, отношение рассеянной к прямой на горизонтальную поверхность при 35° (r).
"""
import json
import math
import sys

I0 = 1367.0  # солнечная постоянная, W/m2 (без поправки на эксцентриситет — берём среднее расстояние)


def esra_diffuse(el_deg: float, tl: float):
    """ESRA, ясное небо: (DHI, BHI) W/m2 на горизонтальной поверхности, air mass — Kasten–Young в ESRA не нужна.
    Dh = I0·Trd(TL)·Fd(sin h); Bh = I0·sin h·exp(-0.8662·TL·m·δR(m)) (Kasten 1996)."""
    sh = math.sin(math.radians(max(el_deg, 0.0)))
    trd = -1.5843e-2 + 3.0543e-2 * tl + 3.797e-4 * tl * tl
    a0 = 2.6463e-1 - 6.1581e-2 * tl + 3.1408e-3 * tl * tl
    if a0 * trd < 2e-3:
        a0 = 2e-3 / trd
    a1 = 2.0402 + 1.8945e-2 * tl - 1.1161e-2 * tl * tl
    a2 = -1.3025 + 3.9231e-2 * tl + 8.5079e-3 * tl * tl
    fd = a0 + a1 * sh + a2 * sh * sh
    dhi = I0 * trd * fd
    # прямая: Kasten 1996, воздушная масса Kasten–Young 1989, δR по Kasten 1996 (m ≤ 20: полином, выше — 1/(10.4+0.718 m))
    m = 1.0 / (sh + 0.50572 * (el_deg + 6.07995) ** -1.6364) if el_deg > -1 else 40.0
    dr = 1.0 / (6.6296 + 1.7513 * m - 0.1202 * m**2 + 0.0065 * m**3 - 0.00013 * m**4) if m <= 20 else 1.0 / (10.4 + 0.718 * m)
    bn = I0 * math.exp(-0.8662 * tl * m * dr)
    return dhi, bn * sh


def bird_diffuse(el_deg: float, aod: float, w_cm=1.5, o3_cm=0.3, p_mb=1013.0, albedo=0.2, ba=0.85):
    """Bird & Hulstrom 1981: (DHI, BHI) W/m2. aod — оптическая толща аэрозоля (среднее на 380 и 500 нм ≈ 550 нм)."""
    z = 90.0 - el_deg
    cz = math.cos(math.radians(z))
    m = 1.0 / (cz + 0.15 * (93.885 - z) ** -1.253)
    mp = m * p_mb / 1013.0
    tr = math.exp(-0.0903 * mp**0.84 * (1.0 + mp - mp**1.01))
    u3 = o3_cm * m
    to = 1.0 - 0.1611 * u3 * (1.0 + 139.48 * u3) ** -0.3035 - 0.002715 * u3 / (1.0 + 0.044 * u3 + 0.0003 * u3 * u3)
    tum = math.exp(-0.0127 * mp**0.26)
    aw = w_cm * m
    tw = 1.0 - 2.4959 * aw / ((1.0 + 79.034 * w_cm * m) ** 0.6828 + 6.385 * w_cm * m) if False else 1.0 - 2.4959 * aw / ((1.0 + 79.034 * aw) ** 0.6828 + 6.385 * aw)
    ta = math.exp(-(aod**0.873) * (1.0 + aod - aod**0.7088) * m**0.9108)
    taa = 1.0 - 0.1 * (1.0 - m + m**1.06) * (1.0 - ta)
    tas = ta / taa
    rs = 0.0685 + (1.0 - ba) * (1.0 - tas)
    ibn = 0.9662 * I0 * tr * to * tum * tw * ta  # Bird: Ib = 0.9662·I0·Tr·To·Tum·Tw·Ta (нормаль)
    ibh = ibn * cz
    ids = 0.79 * I0 * cz * to * tum * tw * taa * (0.5 * (1.0 - tr) + ba * (1.0 - tas)) / (1.0 - m + m**1.02)
    ig = (ibh + ids) * albedo * rs / (1.0 - albedo * rs)
    return ids + ig, ibh


def main():
    opts = dict(a[2:].split("=", 1) if "=" in a else (a[2:], "1") for a in sys.argv[1:] if a.startswith("--"))
    tl = float(opts.get("tl", 3.0))
    aod = float(opts.get("aod", 0.12))
    els = [-2, 0, 0.5, 1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 18, 22, 26, 30, 35]
    e35, b35 = esra_diffuse(35.0, tl)
    d35, bb35 = bird_diffuse(35.0, aod)
    rows = []
    for el in els:
        e, b = esra_diffuse(el, tl)
        d, bb = bird_diffuse(max(el, 0.05), aod)
        rows.append({"el": el, "esra": e / e35, "bird": d / d35, "esra_w": e, "bird_w": d})
    if "json" in opts:
        print(json.dumps({"tl": tl, "aod": aod, "r_esra": e35 / b35, "r_bird": d35 / bb35, "rows": rows}, indent=1))
        return
    print("TL=%.2f AOD=%.3f  DHI(35)=%.1f (ESRA) %.1f (Bird) W/m2;  DHI/BHI(35): ESRA %.3f, Bird %.3f" % (tl, aod, e35, d35, e35 / b35, d35 / bb35))
    print("el   ESRA   Bird   DHI_esra DHI_bird")
    for r in rows:
        print("%4.1f %6.3f %6.3f %8.1f %8.1f" % (r["el"], r["esra"], r["bird"], r["esra_w"], r["bird_w"]))


if __name__ == "__main__":
    main()
