"""Шаг 1: один термик-диполь (ЛЧ) 2D против AirThermals (ядро Гедеона + кольцо), подъём до потолка."""
import json, sys, time
import numpy as np
sys.path.insert(0, ".")
from common import *

# вход: тот же «типичный июльский день», что в thermals.md (H ~ 250 Вт/м^2, z_i 1500 м, u* 0.4)
H_W = 250.0
RHOCP = 1.2 * 1005.0
H_KIN = H_W / RHOCP
ZI = 1500.0
USTAR = 0.4
WSTAR = (G_OVER_T0 * H_KIN * ZI) ** (1 / 3)
WM = (USTAR ** 3 + 0.28 * WSTAR ** 3) ** (1 / 3)
DTH0 = 6.5 * H_KIN / WM                       # избыток частицы, thermals.md (Холтслаг-Бовилль)
KM = 1.0                                       # присоединённая масса цилиндра, Lamb
W0_GAME = 1.24 * WSTAR                         # сила ядра AirThermals


def allen_r2(zeta, zl=ZI):
    return np.maximum(10.0, 0.102 * zeta ** (1 / 3) * (1 - 0.25 * zeta) * zl)


def run_thermal(alpha, R0=None, gam_ml=0.5e-3, gam_up=5e-3, dth0=DTH0, dt=0.2, tmax=7200.0):
    if R0 is None:
        R0 = float(allen_r2(0.1))               # радиус на ζ=0.1 по Аллену
    z, U, R, th = R0, 0.0, R0, dth0
    t = 0.0
    out = []
    while t < tmax:
        gam = gam_ml if z < ZI else gam_up
        b = G_OVER_T0 * th
        dU = b / (1 + KM) - alpha * U * U / R
        U_new = U + dU * dt
        dz = 0.5 * (U + U_new) * dt
        dR = alpha * 0.5 * U * dt
        dth = -(alpha * U / R) * th * dt - gam * U * dt
        out.append((t, z, R, U, th))
        z += dz; R += dR; th += dth; U = U_new; t += dt
        if U <= 0.0 and t > 30:
            break
    a = np.array(out)
    return a


def parcel_ceiling(dth0=DTH0, gam_ml=0.5e-3, gam_up=5e-3):
    z = np.linspace(0, 4000, 40001)
    th = theta_env(z, gam_ml, ZI, gam_up)
    # частица без вовлечения: θ_t = θ_env(z0)+Δθ; потолок — где θ_env = θ_t
    tt = th[0] + dth0
    i = np.argmax(th >= tt)
    return float(z[i])


def summary(alpha, **kw):
    a = run_thermal(alpha, **kw)
    t, z, R, U, th = a.T
    zmax = z.max()
    imax = int(np.argmax(z))
    res = {"alpha": alpha, "z_max": float(zmax), "t_ceiling_s": float(t[imax]),
           "zmax_over_zi": float(zmax / ZI), "Umax": float(U.max()), "peak_w_max": float(3.483 * U.max()),
           "tstar_s": ZI / WSTAR}
    # 80 % потолка
    i80 = int(np.argmax(z >= 0.8 * zmax))
    res["t_to_80pct_s"] = float(t[i80])
    zs = {}
    for zeta in (0.25, 0.5, 0.75):
        i = int(np.argmax(z >= zeta * ZI)) if zmax >= zeta * ZI else None
        if i is None:
            zs[str(zeta)] = None
            continue
        zs[str(zeta)] = {"R": float(R[i]), "R_allen": float(allen_r2(zeta)), "R_ratio": float(R[i] / allen_r2(zeta)),
                         "U": float(U[i]), "peak_w": float(3.483 * U[i]), "peak_over_w0game": float(3.483 * U[i] / W0_GAME),
                         "theta_excess": float(th[i]), "t": float(t[i])}
    res["levels"] = zs
    return res


def profile_compare():
    """Профиль w(x) на высоте центра: ЛЧ (a=1) против Гедеона (R=1), нормировка на пик."""
    x = np.linspace(-12, 12, 480001)
    u, w = lc_velocity(x, 0 * x, 0.0, 1.0, 1.0, 1.0)
    flux_total = float(np.trapezoid(w, x) - 2 * (1.0 / 12.0))     # хвост |x|>12 даёт -2/12 (w=-U a^2/x^2)
    pos = w > 0
    core_flux = float(np.trapezoid(np.where(pos, w, 0), x))
    ring_flux = float(np.trapezoid(np.where(pos, 0, w), x) - 2 / 12.0)   # + хвост
    wg = np.exp(-x ** 2) * (1 - x ** 2)
    g_total = float(np.trapezoid(wg, x))
    g_core = float(np.trapezoid(np.where(wg > 0, wg, 0), x))
    zc = float(x[:-1][(w[:-1] * w[1:] < 0)][-1])
    return {
        "lc_peak_over_U": float(w.max()), "lc_min_over_peak": float(w.min() / w.max()),
        "lc_zero_crossing_over_a": zc, "lc_int_w_dx_over_Ua": flux_total / 1.0,
        "lc_core_flux_over_Ua": core_flux, "lc_ring_flux_over_Ua": ring_flux,
        "gedeon_1D_int_over_wcR": g_total, "gedeon_1D_core_over_wcR": g_core,
        "gedeon_min_over_peak": float(wg.min()), "gedeon_zero_crossing_over_R": 1.0,
        "a_equiv_for_same_core_width": 1.0 / zc,
    }


def main():
    t0 = time.perf_counter()
    prof = profile_compare()
    base = summary(0.15)
    scan = {f"alpha={al}": summary(al) for al in (0.0, 0.1, 0.15, 0.2)}
    scan["alpha=0.15,R0=30"] = summary(0.15, R0=30.0)
    scan["alpha=0.15,R0=100"] = summary(0.15, R0=100.0)
    scan["alpha=0.15,gam_ml=0"] = summary(0.15, gam_ml=0.0)
    scan["alpha=0.15,gam_ml=1e-3"] = summary(0.15, gam_ml=1e-3)
    out = {
        "inputs": {"H_W": H_W, "zi": ZI, "ustar": USTAR, "wstar": WSTAR, "w_m": WM, "dtheta0": DTH0, "w0_game": W0_GAME,
                   "k_m": KM, "alpha_base": 0.15, "R0": float(allen_r2(0.1))},
        "profile": prof, "base": base, "scan": scan,
        "parcel_ceiling_m": parcel_ceiling(),
        "wall_s": time.perf_counter() - t0,
    }
    json.dump(out, open("out/step1.json", "w"), indent=1, ensure_ascii=False)
    print(json.dumps({k: out[k] for k in ("inputs", "profile", "parcel_ceiling_m")}, indent=1))
    print(json.dumps(base, indent=1))
    for k, v in scan.items():
        print(k, round(v["z_max"]), round(v["t_ceiling_s"]), round(v["peak_w_max"], 2), {z: (round(l["R_ratio"], 2) if l else None) for z, l in v["levels"].items()})


if __name__ == "__main__":
    main()
