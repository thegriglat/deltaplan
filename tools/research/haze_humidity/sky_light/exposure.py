#!/usr/bin/env python3
"""Яркость сцены L(el) и экспозиция заката E(el) (HH-15): таблица el → свет рельефа, sky_k, L, E, засвет.

    python3 exposure.py [--a=0.8] [--emax=10] [--rho=0.2]

light(el) = T_G(el)/T_G(35°) — пропускание на 550 нм (Рэлей + аэрозоль 60 км, слой 2 км, уровень моря), как в игре;
sky_k(el) — таблица make_table.py; L(el) = [light·sin(el) + r·sky_k] / [sin(35°) + r] — яркость освещённой
горизонтальной поверхности относительно дня (r — рассеянная к прямой горизонтальной при 35°, ESRA: 0,199);
E = clamp((1/L)^a, 1, E_max); засвет глаза ∝ lum^p · E (lum — яркость солнца по Y, p — energy_exponent).
"""
import math
import sys

import numpy as np

import single_scatter as ss

TAB = {"el": [0.0, 0.5, 1.0, 2.0, 3.0, 4.0, 6.0, 8.0, 12.0, 18.0, 26.0, 35.0],
       "k": [0.082, 0.097, 0.115, 0.156, 0.202, 0.249, 0.340, 0.422, 0.559, 0.719, 0.875, 1.0]}


def t_green(el_deg, ext=6.52e-5, top=2000.0):
    mu = np.array([math.sin(math.radians(el_deg))])
    r = np.array([ss.R])
    tr, ta, blk = ss.sun_tau(r, mu, ext, top)
    return 0.0 if blk[0] else float(math.exp(-(tr[0] + ta[0])))


def main():
    o = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--"))
    a, emax, rho, esun = float(o.get("a", 0.8)), float(o.get("emax", 10.0)), float(o.get("rho", 0.2)), 1.2
    t35 = t_green(35.0)
    print("el   light  sky_k   L      E     sky*E  (L*E)")
    for el in [0.7, 1, 2, 3, 4, 6, 8, 12, 18, 26, 35]:
        light = t_green(el) / t35
        k = float(np.interp(el, TAB["el"], TAB["k"]))
        sl = math.sin(math.radians(el))
        big_l = (esun * light * sl * rho + k) / (esun * math.sin(math.radians(35)) * rho + 1.0)
        e = min(max((1.0 / big_l) ** a, 1.0), emax)
        print("%4.1f %6.3f %6.3f %6.3f %6.2f %6.2f %6.2f" % (el, light, k, big_l, e, k * e, big_l * e))


if __name__ == "__main__":
    main()
