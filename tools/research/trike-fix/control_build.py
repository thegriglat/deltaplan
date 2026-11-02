#!/usr/bin/env python3
"""Собирает out/control_summary.json (TKF-К2) из out/control_main.jsonl (+ out/control_t3030_g1.jsonl — перезамер t_30_30 при газе 1
с подбором усилений регулятора: основной прогон не удержал 30°). Запуск: python3 control_build.py"""
import json, subprocess, os
here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "out")
rows = {}
for l in open(os.path.join(out, "control_main.jsonl")):
    r = json.loads(l); rows[r["name"]] = r
fix = json.loads(open(os.path.join(out, "control_t3030_g1.jsonl")).readline())
rows["trike_1.0"]["t3030"] = fix["t3030"]
names = {"sport": "sport", "training": "training", "trike_0.0": "trike_0", "trike_0.5": "trike_0.5", "trike_1.0": "trike_1"}
cases = {}
for k, r in rows.items():
    rr = r["roll"]
    cases[names[k]] = {
        "roll_rate_dps": {s: round(rr[s]["rate_dps"], 2) for s in ("0.25", "0.5", "1.0")},
        "t_30_30_s": r["t3030"]["t_s"], "t_45_45_s": r["t4545"]["t_s"],
        "pitch_rate_dps": {"push": round(r["push"]["pitch_rate_dps"], 2), "pull": round(r["pull"]["pitch_rate_dps"], 2)},
        "bar_force_n": round(r["push"]["bar_fx_steady_n"], 1),
        "extra": {"bar_force_pull_n": round(r["pull"]["bar_fx_steady_n"], 1), "bar_force_peak_push_n": round(r["push"]["bar_f_peak_n"], 1),
                  "trim_v_kmh": round(r["settle"]["v_kmh"], 1), "trim_theta_deg": round(r["settle"]["theta_deg"], 1),
                  "hold_err_30_deg": round(r["t3030"]["hold_err_deg"], 2), "hold_err_45_deg": round(r["t4545"]["hold_err_deg"], 2),
                  "hold": r["hold"], "spiral": r["spiral"]},
    }
for c in cases.values():
    c["roll_rate_dps"]["1"] = c["roll_rate_dps"].pop("1.0")
git = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, cwd=here).stdout.strip()
ref = [
 {"source": "Gratton G.B., Newman S., «Towards the tumble resistant microlight», https://bura.brunel.ac.uk/bitstream/2438/705/1/Fulltext.pdf (разд. «Describing…», с. 3): «roll authority capable typically between 2.5-5.0 seconds from 30°-30° without exceptional piloting effort»",
  "aircraft": "weightshift_microlight_flexwing", "quantity": "t_30_30_s_min", "value": 2.5, "unit": "s"},
 {"source": "Gratton G.B., Newman S. (там же): верхняя граница типичной перекладки 30°-30°", "aircraft": "weightshift_microlight_flexwing",
  "quantity": "t_30_30_s_max", "value": 5.0, "unit": "s"},
 {"source": "Gratton G.B., доклад RAeS 2000 о BCAR Section S (https://core.ac.uk/download/333439.pdf; оригинал не открыт — по пересказу поиска, ПРОВЕРИТЬ): Table 1, наибольшая сила по крену, кратковременно",
  "aircraft": "BCAR_S_weightshift", "quantity": "roll_control_force_temporary_max", "value": 100.0, "unit": "N"},
 {"source": "то же (по пересказу, проверить): сила по крену при длительном приложении", "aircraft": "BCAR_S_weightshift",
  "quantity": "roll_control_force_prolonged_max", "value": 15.0, "unit": "N"},
 {"source": "Gratton G.B., Newman S. (там же, разд. «Spiral Instability»): «many weightshift microlight aircraft are spirally unstable (particularly at higher power settings)» — качественно, числа нет",
  "aircraft": "weightshift_microlight_flexwing", "quantity": "spiral_unstable_at_high_power(1=yes)", "value": 1.0, "unit": "bool"},
 {"source": "Gratton G.B., Newman S. (там же): разворот 45 kn CAS, крен 60° — угловая скорость поворота курса ≈ 40°/с (не скорость крена)",
  "aircraft": "weightshift_microlight_flexwing", "quantity": "turn_rate_at_60deg_bank_45kn", "value": 40.0, "unit": "deg/s"},
 {"source": "configs/wings/*.json старого режима weight_shift (git 574dfab6a^): sport roll_rate_max_dps, сам режим удалён; сверка 45→45 ≈ 2,2 с по doc ключа",
  "aircraft": "sport_removed_weight_shift_mode", "quantity": "t_45_45_s", "value": 2.2, "unit": "s"},
]
doc = {"version": 1, "git": git, "cases": cases, "reference": ref}
json.dump(doc, open(os.path.join(out, "control_summary.json"), "w"), ensure_ascii=False, indent=1)
print("ok", list(cases))
