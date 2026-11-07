"""Таблицы для docs/research/sw_charges/stage1-sections.md из out/sections/sections.json и perd.csv (печать в stdout)."""
import csv
import json
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "out", "sections")
rows = json.load(open(os.path.join(OUT, "sections.json")))["rows"]
print("| случай | вариант ref | dx_sw | F0 | M | ст. | E | E0 | E_c | S_sw / S_p | D_sw / D_p | x_D_sw / x_D_p, м |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|")
for r in rows:
    if r["dx"] != 50:
        continue
    v = (r["rule_b0"] or "крышка") + f", h0 {r['h0']:.0f}" + (", без нагрева" if "_q0_" in r["sw_case"] else ", 3 ч" if "_3h_" in r["sw_case"] else "")
    print(f"| {r['case']} | {v} | {r['dx_sw']} | {r['F0']:.2f} | {r['M']:.2f} | {r['status'][:3]} | {r['E']:.3f} | {r['E0']:.3f} | {r['E_c']:.3f} | "
          f"{r['S_sw']:.2f} / {r['S_p']:.2f} | {r['D_sw']:.2f} / {r['D_p']:.2f} | {r['x_D_sw']:.0f} / {r['x_D_p']:.0f} |")
print()
print("Контроль Пикара dx 400 (слой 400 м):")
print()
print("| случай | вариант | E (P400) | E0 (P400) | S_p | D_p |")
print("|---|---|---|---|---|---|")
for r in rows:
    if r["dx"] == 400:
        v = (r["rule_b0"] or "крышка") + f", h0 {r['h0']:.0f}" + (", без нагрева" if "_q0_" in r["sw_case"] else ", 3 ч" if "_3h_" in r["sw_case"] else "")
        print(f"| {r['case']} | {v} | {r['E']:.3f} | {r['E0']:.3f} | {r['S_p']:.2f} | {r['D_p']:.2f} |")
print()
print("| слой | h0 | dx_sw | F0 | ū(tse13), м/с | ū(tse09) | ū(tse04) | ū(tse09)/ū(tse13) | мин ū / U0 | клеток с ū<0 |")
print("|---|---|---|---|---|---|---|---|---|---|")
for r in csv.DictReader(open(os.path.join(OUT, "perd.csv"))):
    print(f"| PERD | {float(r['h0']):.0f} | {float(r['dx_sw']):.0f} | {float(r['F0']):.2f} | {float(r['u_tse13']):.2f} | {float(r['u_tse09']):.2f} | "
          f"{float(r['u_tse04']):.2f} | {float(r['ratio_valley_crest']):.2f} | {float(r['u_min_over_U0']):.2f} | {r['reverse_cells']} |")
