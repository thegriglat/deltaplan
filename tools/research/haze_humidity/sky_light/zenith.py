#!/usr/bin/env python3
"""Яркость зенита и неба над горизонтом при высоте солнца el, относительно 35° (однократное рассеяние, как single_scatter.py)."""
import math, sys
import numpy as np
import single_scatter as ss

def radiance(el_deg, vz_deg, az_deg, ext=6.5e-5, top=2000.0, ssa=0.9, g=0.7, ns=96):
    el = math.radians(el_deg)
    sun = np.array([math.cos(el), 0.0, math.sin(el)])
    th = math.radians(90 - vz_deg); ph = math.radians(az_deg)
    v = np.array([math.sin(th) * math.cos(ph), math.sin(th) * math.sin(ph), math.cos(th)])
    cosg = float(v @ sun)
    rtop = ss.R + 100000.0
    s_end = -ss.R * v[2] + math.sqrt(ss.R**2 * v[2]**2 + rtop**2 - ss.R**2)
    u = (np.arange(ns) + 0.5) / ns
    s = s_end * u**2; ds = s_end * 2 * u / ns
    px, py, pz = s * v[0], s * v[1], ss.R + s * v[2]
    r = np.sqrt(px**2 + py**2 + pz**2); h = r - ss.R
    rho_r = np.exp(-h / ss.H); rho_a = (h < top).astype(float)
    tvr = np.cumsum(ss.BR * rho_r * ds) - 0.5 * ss.BR * rho_r * ds
    tva = np.cumsum(ext * rho_a * ds) - 0.5 * ext * rho_a * ds
    mu = (px * sun[0] + pz * sun[2]) / r
    tr, ta, blk = ss.sun_tau(r, mu, ext, top)
    tsun = np.exp(-(tr + ta)) * (~blk)
    pr = 3 / (16 * math.pi) * (1 + cosg**2)
    pa = (1 - g * g) / (4 * math.pi * (1 + g * g - 2 * g * cosg) ** 1.5)
    src = (ss.BR * rho_r * pr + ext * rho_a * ssa * pa) * tsun * np.exp(-(tvr + tva))
    return float((src * ds).sum())

if __name__ == "__main__":
    ref_z = radiance(35, 90, 0)
    print("el  zenith  alt30/az90  alt5/az90  alt5/az180(anti)   (относительно зенита при 35°)")
    for el in [0.7, 2, 4, 8, 18, 35]:
        print("%4.1f %.3f  %.3f  %.3f  %.3f" % (el, radiance(el, 90, 0) / ref_z, radiance(el, 30, 90) / ref_z, radiance(el, 5, 90) / ref_z, radiance(el, 5, 180) / ref_z))
