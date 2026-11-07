"""Сборка out/results.json из out/step{1,2,3}.json: значения, пороги, pass/fail."""
import json
import numpy as np

s1 = json.load(open("out/step1.json")); s2 = json.load(open("out/step2.json")); s3 = json.load(open("out/step3.json"))


def chk(name, value, lo, hi, note=""):
    ok = bool(value is not None and lo <= value <= hi)
    return {"name": name, "value": None if value is None else float(value), "threshold": [lo, hi], "pass": ok, "note": note}


# --- шаг 1
b = s1["base"]; p = s1["profile"]
c1 = []
for z in ("0.25", "0.5"):
    c1.append(chk(f"пик w / w0 игры, ζ={z}", b["levels"][z]["peak_over_w0game"], 0.7, 1.3, "w0=1.24 w*; пик ЛЧ = 3,48·U"))
for z in ("0.25", "0.5", "0.75"):
    c1.append(chk(f"R / R Аллена, ζ={z}", b["levels"][z]["R_ratio"], 0.7, 1.3, "R результат вовлечения α=0,15"))
c1.append(chk("потолок / потолок частицы", b["z_max"] / s1["parcel_ceiling_m"], 0.7, 1.3, "частица без вовлечения (метод AirThermals)"))
c1.append(chk("время до 80 % потолка / t*", b["t_to_80pct_s"] / b["tstar_s"], 0.5, 1.5, "t*=z_i/w*"))
c1.append(chk("|∫w dx| / ∫|w|dx (линия через центр)", abs(p["lc_int_w_dx_over_Ua"]) / (p["lc_core_flux_over_Ua"] * 2), 0, 0.01, "ядро+кольцо ЛЧ"))
c1.append(chk("глубина кольца min/пик: ЛЧ против Гедеона", p["lc_min_over_peak"] / p["gedeon_min_over_peak"], 0.7, 1.3, "−0,31 против −0,135"))
c1.append(chk("нуль ядра: ЛЧ (a=R) / Гедеон", p["lc_zero_crossing_over_a"], 0.7, 1.3, "ядро ЛЧ уже 0,62 R"))
step1 = {"checks": c1, "base": b, "profile": p, "scan_ceiling": {k: [v["z_max"], v["t_to_80pct_s"], v["peak_w_max"]] for k, v in s1["scan"].items()}, "inputs": s1["inputs"], "parcel_ceiling_m": s1["parcel_ceiling_m"],
         "gedeon_1D_flux_nonzero": p["gedeon_1D_int_over_wcR"]}

# --- шаг 2
c2 = []
# полная σ_w игры при входе прототипа (H=250, u*=0,4): σ_w = 1,25 u*(1+3|z/L|)^(1/3), L = -u*^3 T/(κ g H_kin); эталон выше — нейтральный
LMO = -(0.4 ** 3) * 300.0 / (0.4 * 9.81 * (250.0 / (1.2 * 1005.0)))
for z, v in s2["base"].items():
    if z != "_meta":
        v["sigma_w_game_full"] = 1.25 * 0.4 * (1 + 3 * abs(float(z) / LMO)) ** (1 / 3)
        v["sigma_ratio_full"] = v["sigma_w"] / v["sigma_w_game_full"]
for z, v in s2["base"].items():
    if z == "_meta":
        continue
    c2.append(chk(f"σ_w / σ_w игры нейтральная, z={z} м", v["sigma_ratio"], 0.7, 1.3, f"σ_w={v['sigma_w']:.2f}, игра {v['sigma_w_game']:.2f}"))
for z, v in s2["base"].items():
    if z == "_meta":
        continue
    c2.append(chk(f"σ_w(механика пар) / σ_w игры полная с (1+3|z/L|)^⅓, z={z} м", v["sigma_ratio_full"], 0.7, 1.3, f"L_MO={LMO:.1f} м; игра {v['sigma_w_game_full']:.2f}; в пары конвекция не заложена"))
for z, v in s2["base"].items():
    if z == "_meta":
        continue
    c2.append(chk(f"L_w / z, z={z} м", v["L_ratio"], 0.7, 1.3, "L_w=2·∫ρ dx до нуля; игра L_w=z"))
for z, v in s2["base"].items():
    if z == "_meta":
        continue
    c2.append(chk(f"<u'w'>/(-u*²·(1-z/h)^1,5), z={z} м", v["uw"] / v["uw_game"], 0.7, 1.3, "поток импульса пар против u*_m²"))
for z, v in s2["base"].items():
    if z == "_meta":
        continue
    c2.append(chk(f"σ_крыло/σ_точка (b=10 м) против Кармана, z={z} м", v["wing_ratio"] / v["wing_ratio_karman"], 0.7, 1.3, f"{v['wing_ratio']:.2f} против {v['wing_ratio_karman']:.2f}"))
scan2 = {}
for k, r in s2["scan"].items():
    scan2[k] = {z: [v["sigma_ratio"], v["L_ratio"], v["uw"] / v["uw_game"]] for z, v in r.items() if z != "_meta"}
    scan2[k]["_alive"] = r["_meta"]["n_alive_mean"]; scan2[k]["_annihilated"] = r["_meta"]["annihilated"]
step2 = {"checks": c2, "base": s2["base"], "scan": scan2}

# --- шаг 3
bs = s3["base"]; lv = bs["levels"]
zb = [x for x in bs["zi_blocks"] if x["zi_H0"] and x["t"] > 1800]
t = np.array([x["t"] for x in zb]); zi = np.array([x["zi_H0"] for x in zb])
slope = float(np.polyfit(t, zi, 1)[0] * 3600)
enc = (bs["zi_enc_end"] - [l for l in bs["log"] if abs(l["t"] - 1800) < 1][0]["zi_enc"]) / ((bs["params"]["T"] - 1800) / 3600)
c3 = []
for z in ("0.1", "0.25", "0.5", "0.75"):
    c3.append(chk(f"H(ζ)/H_kin против 1-ζ, ζ={z}", lv[z]["H_over_Hkin"] / lv[z]["H_closure_1mzeta"], 0.7, 1.3, "замыкание thermals.md"))
for z in ("0.1", "0.25", "0.5", "0.75"):
    c3.append(chk(f"<u'w'>(ζ)/(-u*²(1-ζ)^1,5), ζ={z}", lv[z]["uw_over_ustar2"] / lv[z]["uw_game_over_ustar2"], 0.7, 1.3, "поток импульса термиков (знак: вниз)"))
c3.append(chk("поток импульса термиков есть и вниз (max |<u'w'>|/u*², ζ=0,1)", -lv["0.1"]["uw_over_ustar2"], 0.3, 3.0, "порог «есть обратный поток»: ≥ 0,3 u*²"))
c3.append(chk("рост z_i(t) по H=0, м/ч", slope, 0.5 * enc, 2.0 * enc, f"срезание по начальному профилю {enc:.0f} м/ч"))
c3.append(chk("торможение слоя 100..z_i за 3 ч / (u*²T/z_i)", bs["layer_100_zi_wind_change"] / (-0.4 ** 2 / 1500 * bs["params"]["T"]), 0.3, 3.0, f"Δ={bs['layer_100_zi_wind_change']:.2f} м/с"))
c3.append(chk("поток тепла у кромки min H/H_kin", min(x["H_min_over_Hkin"] for x in zb), -0.4, -0.1, "вовлечение у кромки −0,2 H"))
c3.append(chk("консервативность схемы: Σ(θ-θ0)dz/(H t) (проверка численной схемы, не модели)", bs["heat_budget_ratio"], 0.95, 1.05, "сохранение"))
c3.append(chk("∫w dx / ∫|w|dx по линии в ансамбле", max(abs(v["int_w_dx_over_int_abs"]) for v in bs["flux_check"].values()), 0, 0.02, "в 2D, периодика ±1, изображения"))
scan3 = {k: {"H_0.5": v["levels"]["0.5"]["H_over_Hkin"], "uw_0.1_over_u*2": v["levels"]["0.1"]["uw_over_ustar2"], "layer_wind_change": v["layer_100_zi_wind_change"],
             "zi_H0_end": (v["zi_blocks"][-1]["zi_H0"]), "Hmin": min(x["H_min_over_Hkin"] for x in v["zi_blocks"] if x["t"] > 1800), "alive": v["n_alive_mean"], "us_per_step": v["us_per_step"]} for k, v in s3["scan"].items()}
step3 = {"checks": c3, "zi_blocks": bs["zi_blocks"], "zi_slope_m_per_h": slope, "zi_encroach_m_per_h": enc, "levels": lv, "scan": scan3,
         "n_alive_mean": bs["n_alive_mean"], "birth_per_s": bs["params"]["nu_births_per_s"], "wind": bs["wind_12m_800m"]}

allc = c1 + c2 + c3
crit = {"rule": "pass: значение в [lo,hi]; σ_w ±30 % — критерий прототипа C", "n_pass": sum(c["pass"] for c in allc), "n_total": len(allc),
        "per_step": {"step1": [sum(c["pass"] for c in c1), len(c1)], "step2": [sum(c["pass"] for c in c2), len(c2)], "step3": [sum(c["pass"] for c in c3), len(c3)]},
        "sigma_w_pass_all_heights": all(c["pass"] for c in c2 if c["name"].startswith("σ_w / σ_w игры нейтральная")),
        "sigma_w_pass_full_reference": [c["pass"] for c in c2 if "полная" in c["name"]],
        "backflows_present": bool(lv["0.1"]["uw_over_ustar2"] < -0.3 or lv["0.1"]["uw_over_ustar2"] < 0),
        "verdict": "частично"}
m2 = s2["base"]["_meta"]
timing = {"step1_wall_s": s1["wall_s"], "step2_pairs_dyn_us_per_step": m2["us_per_step_dyn"], "step2_n_alive": m2["n_alive_mean"], "step2_us_per_pair_step": m2["us_per_step_dyn"] / m2["n_alive_mean"],
          "step2_wall_s": s2["wall_s"], "step3_us_per_step": bs["us_per_step"], "step3_n_alive": bs["n_alive_mean"], "step3_wall_s_all": s3["wall_s"],
          "step3_us_per_step_with_induced": s3["scan"]["induced_on"]["us_per_step"],
          "extrapolated_1e6_steps_s": {"thermals_N~100": bs["us_per_step"], "thermals_induced": s3["scan"]["induced_on"]["us_per_step"], "pairs_N~9e3": m2["us_per_step_dyn"]}}
timing["extrapolated_1e6_steps_s"] = {k: v * 1e6 / 1e6 for k, v in timing["extrapolated_1e6_steps_s"].items()}   # мкс*1e6/1e6 = с
json.dump({"step1": step1, "step2": step2, "step3": step3, "criterion": crit, "timing": timing}, open("out/results.json", "w"), indent=1, ensure_ascii=False)
for c in allc:
    print("PASS" if c["pass"] else "FAIL", c["name"], None if c["value"] is None else round(c["value"], 3), c["note"])
print(crit["per_step"], crit["n_pass"], crit["n_total"], timing)
