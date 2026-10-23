#!/usr/bin/env python3
"""SNW-1: числа для configs/snow_plume.json из литературных формул. Запуск: python3 snow_plume_params.py"""
import json, math
import numpy as np

# --- порог (Li & Pomeroy 1997, J. Appl. Meteorol. 36, 205-213; форма из карточки, проверена по эквиваленту 6.9+0.0033(T+27.27)^2)
A, B, C = 9.43, 0.18, 0.0033
def u_t(T): return A + B*T + C*T*T
Ts = list(range(-40, 11, 5))
thr = {T: round(u_t(T), 2) for T in Ts}
T_min = -B/(2*C); u_min = u_t(T_min)

# --- скорость оседания: ледяная сфера, сопротивление Schiller-Naumann (1933); сфера — верхняя оценка (Xiao et al. 2000: у реальных частиц меньше)
rho_i, g = 917.0, 9.81
T_k = 263.15; mu = 1.716e-5*(T_k/273.15)**1.5*(273.15+110.4)/(T_k+110.4); rho_a = 1.3
def w_term(r):
    lo, hi = 1e-4, 5.0
    for _ in range(80):
        w = 0.5*(lo+hi); Re = 2*rho_a*w*r/mu
        cd = 24/Re*(1+0.15*Re**0.687)  # Schiller-Naumann (1933)
        f = 0.5*rho_a*w*w*cd*math.pi*r*r - (4/3)*math.pi*r**3*(rho_i-rho_a)*g
        lo, hi = (w, hi) if f < 0 else (lo, w)
    return 0.5*(lo+hi)
wt = {int(r*1e6): round(w_term(r), 3) for r in (25e-6, 40e-6, 50e-6, 75e-6, 100e-6)}

# --- u*, sigma_w
kappa = 0.4
def ustar(u10, z0): return kappa*u10/math.log(10/z0)
us = {u: {"z0=0.2mm": round(ustar(u, 2e-4), 3), "z0=1.5mm": round(ustar(u, 1.5e-3), 3)} for u in (7, 10, 12, 15, 20)}
sig_w = {u: round(1.25*us[u]["z0=1.5mm"], 2) for u in us}

# --- длина видимого шлейфа = u * t, t = h/w
plume = {}
for u in (8, 10, 15, 20):
    for h, w in ((5, 0.2), (5, 0.1), (3, 0.2)):
        plume[f"u={u},h={h},w={w}"] = round(u*h/w)

out = dict(threshold_C_to_ms=thr, T_min_C=round(T_min, 1), u_min=round(u_min, 2), terminal_velocity_ms_by_radius_um=wt,
           ustar=us, sigma_w_1p25_ustar=sig_w, plume_length_m=plume)
json.dump(out, open("snow_plume_params.json", "w"), indent=1)
print(json.dumps(out, indent=1))

try:
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    T = np.linspace(-40, 10, 200)
    plt.figure(figsize=(5, 3.2)); plt.plot(T, u_t(T), label="Li & Pomeroy 1997")
    plt.axhspan(5, 7, alpha=.2, label="ориентир 5-7 м/с"); plt.xlabel("T, °C"); plt.ylabel("u10_t, м/с"); plt.legend(); plt.tight_layout()
    plt.savefig("threshold_vs_T.png", dpi=150)
except Exception as e:
    print("no plot", e)
