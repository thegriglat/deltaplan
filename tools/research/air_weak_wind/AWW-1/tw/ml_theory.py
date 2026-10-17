"""TW-2: оценки по теории слоя перемешивания (конвективный пограничный слой) для старта «Термики».
Печатает json: w*, σ_w и средний подъём у земли 0–20 м, ветер на 10 м при заданном ветре слоя U_ML.

Источники:
- w* = (g/θ0·H/(ρc_p)·z_i)^(1/3) — Deardorff (1970), Stull (1988) гл. 4.
- σ_w/w* = 1,34 (z/z_i)^(1/3) (1 − 0,8 z/z_i) — Lenschow, Wyngaard & Pennell (1980), JAS 37, 1313.
- средний подъём термика w̄/w* = (z/z_i)^(1/3)(1 − 1,1 z/z_i) — Allen (2006), AIAA 2006-1510 (то же в thermals.md игры).
- приземный слой: U(z) = u*/κ [ln(z/z0) − ψ_m(z/L)], ψ_m — Paulson (1970) с φ_m = (1 − 16 ζ)^(−1/4) (Businger–Dyer,
  Dyer 1974); L = −u*³ θ0/(κ g H_kin).
- связь со слоем: U_ML = U(z_s) на верху приземного слоя z_s = 0,1 z_i (Stull 1988 §9; Garratt 1992 гл. 3) —
  ветер в слое перемешивания однороден по высоте.
- порывистость свободной конвекции: эффективная скорость для потока импульса √(U² + (β w*)²), β = 1,2
  (Godfrey & Beljaars 1991, JGR 96, 22043; Beljaars 1995, QJRMS 121, 255).
Запуск: python3 ml_theory.py > ml_theory.json
"""
import json
import math

G, TH0, RHO_CP, KAPPA = 9.81, 300.0, 1206.0, 0.4


def wstar(h_wm2, zi):
    return (G / TH0 * h_wm2 / RHO_CP * zi) ** (1 / 3)


def psi_m(zeta):
    if zeta >= 0:
        return -5.0 * zeta
    x = (1 - 16 * zeta) ** 0.25
    return 2 * math.log((1 + x) / 2) + math.log((1 + x * x) / 2) - 2 * math.atan(x) + math.pi / 2


def surface_wind(u_ml, h_wm2, zi, z0, z=10.0, beta=1.2, gust=True):
    """Средний (векторный) ветер на высоте z при ветре слоя u_ml: u* из сшивки на z_s = 0,1 z_i."""
    hk = h_wm2 / RHO_CP
    ws = wstar(h_wm2, zi)
    zs = 0.1 * zi
    ust = 0.3
    for _ in range(200):
        L = -ust ** 3 * TH0 / (KAPPA * G * hk) if hk > 0 else 1e9
        # эффективная скорость на z_s (с порывистостью) задаёт u*
        ueff = math.sqrt(u_ml ** 2 + (beta * ws) ** 2) if gust else u_ml
        ust_new = KAPPA * ueff / (math.log(zs / z0) - psi_m(zs / L))
        if abs(ust_new - ust) < 1e-7:
            break
        ust = 0.5 * (ust + ust_new)
    L = -ust ** 3 * TH0 / (KAPPA * G * hk) if hk > 0 else 1e9
    prof = lambda zz: (math.log(zz / z0) - psi_m(zz / L))
    # векторный средний ветер — та же форма профиля, нормированная на u_ml на z_s
    u_z = u_ml * prof(z) / prof(zs)
    return {"u_star": ust, "L": L, "u10": u_z, "ratio": u_z / u_ml}


def main():
    # старт «Термики»: H у старта 301–317 Вт/м² (запечённое поле, канал heat), z_i 1750 м над морем, земля ~180 м,
    # z0 0,03 м (meta.z0 столбца); ветер слоя в области 400 м у старта 2,3–2,5 м/с
    h, zi_agl, z0 = 314.0, 1750.0 - 180.0, 0.03
    ws = wstar(h, zi_agl)
    rows = []
    for z in (1.0, 2.0, 5.0, 10.0, 20.0, 50.0):
        zeta = z / zi_agl
        sw = ws * 1.34 * zeta ** (1 / 3) * (1 - 0.8 * zeta)
        wb = ws * zeta ** (1 / 3) * (1 - 1.1 * zeta)
        rows.append({"z_m": z, "sigma_w": round(sw, 3), "w_allen_mean": round(wb, 3),
                     "w_core_peak_est": round(2.2 * wb, 3), "w_3sigma": round(3 * sw, 3)})
    winds = []
    for u_ml in (1.0, 2.0, 2.5, 3.0, 4.0, 6.0):
        for hh in (0.0001, 100.0, 200.0, 314.0, 400.0):
            r = surface_wind(u_ml, hh, zi_agl, z0)
            winds.append({"U_ML": u_ml, "H_wm2": hh, "u10": round(r["u10"], 3), "ratio_u10_UML": round(r["ratio"], 3),
                          "u_star": round(r["u_star"], 3), "L_m": round(r["L"], 1)})
    out = {"inputs": {"H_wm2": h, "zi_agl_m": zi_agl, "z0_m": z0}, "w_star": round(ws, 3), "w_profile": rows,
           "u10_vs_UML": winds}
    print(json.dumps(out, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
