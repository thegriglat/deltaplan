#!/usr/bin/env python3
"""SPF-1 п.3 и п.4: частота трепета ленточки f = St_L*U/L и эолов тон тросов f = St*V/d, Re = V*d/nu.
Запуск: python3 flutter_wires.py [--json out/flutter_wires.json]. Только stdlib."""
import json, math, sys
NU = 1.46e-5  # м2/с, воздух 15 C, 1 атм (МСА)
RHO = 1.225
# --- лента (configs/instruments.json -> telltale: length_m 0.13, width_m 0.01)
L = 0.13
rows_t = []
for st_l in (0.25, 0.4, 0.55):
    for u in (2.0, 5.0, 8.0, 12.0, 25.0):
        rows_t.append({"St_L": st_l, "U_ms": u, "f_hz": round(st_l * u / L, 1)})
# Jia, Andreotti, Claudin 2015: omega_m ~ (2 rho/m) V, m - масса на м2; у ленты ~1 г/м при ширине 1 см
rows_j = []
for lin_g_per_m in (0.5, 1.0, 2.0):
    m = lin_g_per_m * 1e-3 / 0.01  # кг/м2
    for u in (12.0, 25.0):
        f = RHO / (math.pi * m) * u
        rows_j.append({"linear_g_per_m": lin_g_per_m, "areal_kg_m2": m, "U_ms": u,
                       "f_hz": round(f, 1), "St_L": round(f * L / u, 2)})
# форма амплитуды: lambda ~ V^(-2/3) (Jia 2015, k_m ~ V^(2/3)); амплитуда ~ lambda при A/lambda = const
amp = [{"U_ms": u, "rel_to_12": round((12.0 / u) ** (2 / 3), 2)} for u in (12, 15, 18, 22, 25)]
# --- тросы
diam = {"front/rear 5/64in (WW T2C)": 2.0, "side 3/32in (WW T2C)": 2.38, "Bautek Fizz lower/top": 2.5,
        "sprog 1/8in (WW T2C)": 3.2}
speeds_kmh = (30, 40, 55, 80)
rows_w = []
for name, d_mm in diam.items():
    for v_kmh in speeds_kmh:
        v = v_kmh / 3.6
        d = d_mm * 1e-3
        re = v * d / NU
        rows_w.append({"wire": name, "d_mm": d_mm, "V_kmh": v_kmh, "Re": round(re), "f_hz_St0.20": round(0.20 * v / d),
                       "f_hz_St0.19": round(0.19 * v / d), "f_hz_St0.21": round(0.21 * v / d)})
out = {"telltale_physical": rows_t, "telltale_jia": rows_j, "telltale_amp_shape": amp, "wires": rows_w}
for k, v in out.items():
    print(k)
    for r in v:
        print("  ", r)
if "--json" in sys.argv:
    json.dump(out, open(sys.argv[sys.argv.index("--json") + 1], "w"), ensure_ascii=False, indent=1)
