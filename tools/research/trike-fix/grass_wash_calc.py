"""TKF-3: оценка струи винта дельталёта (идеальный диск + затухание турбулентной струи).
Все коэффициенты затухания - оценки по литературе, не замеры. python3 grass_wash_calc.py [-> grass_wash.json]"""
import json, math
rho, D = 1.2, 1.8
A = math.pi * D * D / 4
out = {"rho": rho, "D_m": D, "A_m2": A, "rows": []}
for T in (500.0, 1000.0, 2070.0):
    vd = math.sqrt(T / (2 * rho * A))      # скорость в диске
    vw = 2 * vd                            # далёкая струя = sqrt(2T/(rho A))
    r_w = D / 2 / math.sqrt(2)             # сжатая струя
    d_w = 2 * r_w
    row = {"T_N": T, "v_disk": vd, "v_wake": vw, "d_wake_m": d_w, "decay": []}
    for x in (1, 2, 3, 4, 6, 8, 12, 16):
        # осевая струя: потенциальное ядро ~6 d_w, дальше u/u0 = 6.2 d_w/x (Schlichting; оценка)
        uc = vw if x <= 6 * d_w else vw * 6 * d_w / x
        b = 0.1 * x + r_w                  # полуширина по гауссу ~0.1x (оценка)
        row["decay"].append({"x_m": x, "u_axis": round(uc, 1), "half_width_m": round(b, 2)})
    out["rows"].append(row)
# порог наклона травы: скоростной напор q=0.5 rho u^2; сравнение с ветром 3 м/с (q=5,4 Па)
out["q_ref_wind3"] = 0.5 * rho * 9
json.dump(out, open("tools/research/trike-fix/grass_wash.json", "w"), indent=1, ensure_ascii=False)
for r in out["rows"]:
    print(r["T_N"], round(r["v_disk"], 1), round(r["v_wake"], 1), round(r["d_wake_m"], 2), [(d["x_m"], d["u_axis"]) for d in r["decay"]])
