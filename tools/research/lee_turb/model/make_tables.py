#!/usr/bin/env python3
"""out/sections*.json -> out/tables.md (таблицы для docs/research/lee_turb/model.md). Запуск: python3 -I make_tables.py"""
import json, os, math, csv, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import proto
import numpy as np

O = os.path.join(HERE, "out")
base = json.load(open(os.path.join(O, "sections.json")))
sens = {"x_r=2,8H": "sections_xr2.8_pNone.json", "x_r=5H": "sections_xr5.0_pNone.json", "σ²-сумма": "sections_xrNone_p2.json", "U2 по полю": "sections_xrNone_pNone_u2f.json"}
sens = {k: json.load(open(os.path.join(O, v))) for k, v in sens.items()}
f = lambda v, n=2: "–" if v is None else f"{v:.{n}f}"
L = []
L.append("### T1. Геометрия и максимумы σ_w (агл 5–150 м, x/H 0,05–12)\n")
L.append("| разрез | H, м | x_r/H | s_lee | f_sep | прежняя: max σ_w (x/H; над землёй/над гребнем, м; ветвь) | новая: max σ_w (x/H; над землёй/над гребнем, м) | прежняя: избыток над притоком до x/H 6 (×; x/H; agl) | новая: избыток |\n|---|---|---|---|---|---|---|---|---|")
for b, m in base.items():
    o, n, eo, en = m["old_max"], m["new_max"], m["old_excess"], m["new_excess"]
    L.append(f"| {b.replace('ongudai_','')} | {m['H']:.0f} | {m['xr_over_h']:.1f} | {m['s_lee']:.2f} | {m['f_sep']:.2f} | {o['sigma_w']:.2f} ({o['xh']:.1f}; {o['agl']:.0f}/{o['zc']:+.0f}; {o['src']}) | {n['sigma_w']:.2f} ({n['xh']:.1f}; {n['agl']:.0f}/{n['zc']:+.0f}) | {eo['ratio']:.1f} ({eo['xh']:.1f}; {eo['agl']:.0f}) | {en['ratio']:.1f} ({en['xh']:.1f}; {en['agl']:.0f}) |")
L.append("\n### T2. σ_w у гребня, у присоединения и σ_w/ΔU (максимум по высоте agl 5–150 м в колонке)\n")
L.append("| разрез | σ_w x/H 0,5: прежн./нов. | σ_w у присоед. (x/H): прежн./нов. | ΔU на 0,64·x_r, м/с | σ_w/ΔU на 0,64·x_r: прежн./нов. | δ_ω там, м | y_c−гребень там, м |\n|---|---|---|---|---|---|---|")
for b, m in base.items():
    L.append(f"| {b.replace('ongudai_','')} | {f(m['old_sw_crest05'])} / {f(m['new_sw_crest05'])} | {f(m['old_sw_reatt'])} / {f(m['new_sw_reatt'])} ({m['xh_reatt']:.1f}) | {m['dU_at_peak_station']:.1f} | {f(m['old_sw_over_dU_peak'])} / {f(m['new_sw_over_dU_peak'])} | {m['delta_at_peak_station_m']:.0f} | {m['yc_minus_crest_at_peak_station_m']:+.0f} |")
L.append("\n### T3. Станции по x/H: σ_w на 30 м над землёй и максимум в колонке (прежн. → нов.), только strong\n")
L.append("| разрез | x/H | σ_w@30 | max σ_w колонки (5–150 м) | ΔU, м/с | δ_ω, м | y_c−гребень, м |\n|---|---|---|---|---|---|---|")
for b, m in base.items():
    if "strong" not in b: continue
    for s in m["stations"]:
        L.append(f"| {b.replace('ongudai_strong_','')} | {s['xh']:.1f} | {s['sw30_old']:.2f} → {s['sw30_new']:.2f} | {s['sw_col_old']:.2f} → {s['sw_col_new']:.2f} | {s['dU']:.1f} | {s['delta']:.0f} | {s['yc_rel']:+.0f} |")
L.append("\n### T4. Чувствительность (strong): max σ_w в агл ≤150 м, x/H\n")
L.append("| разрез | база | " + " | ".join(sens) + " |\n|---|---|" + "---|" * len(sens))
for b, m in base.items():
    if "strong" not in b: continue
    cells = []
    for k, d in sens.items():
        n = d[b]["new_max"]; cells.append(f"{n['sigma_w']:.2f} ({n['xh']:.1f}; {n['agl']:.0f} м)")
    L.append(f"| {b.replace('ongudai_strong_','')} | {m['new_max']['sigma_w']:.2f} ({m['new_max']['xh']:.1f}; {m['new_max']['agl']:.0f} м) | " + " | ".join(cells) + " |")
# T5: форма против уступа и холма в нормированных осях
K = proto.K
LT = {r["id"]: float(r["value"]) for r in csv.DictReader(open(os.path.join(HERE, "..", "lit", "lit_numbers.csv"), encoding="utf-8"))}
L.append("\n### T5. Форма против уступа и холма (λ-модель, ΔU = U_ref(1−U2/U1), U2/U1 = −0,10, как без пузыря)\n")
geo_step = dict(H=1.0, h_c=1.0, h_at_xr=0.0, s_lee=1.0)
rows = []
xr = LT["ds_xr"]
L.append("| величина | x/H | эксперимент | модель |\n|---|---|---|---|")
for key, xh in (("ds_su_x1", 1), ("ds_su_x4", 4), ("ds_su_x6", 6), ("ds_su_x10", 10)):
    st = proto.layer_state(np.array([float(xh)]), np.array([0.0]), np.zeros(1), dict(H=1.0, h_c=1.0, h_at_xr=0.0, s_lee=1.0), xr, 1.0, K["u2_unresolved_over_u1"], f_sep_force=1.0)
    yc = st["yc"][0]
    st = proto.layer_state(np.array([float(xh)]), np.array([yc]), np.zeros(1), dict(H=1.0, h_c=1.0, h_at_xr=0.0, s_lee=1.0), xr, 1.0, K["u2_unresolved_over_u1"], f_sep_force=1.0)
    L.append(f"| уступ: пик σ_u/U_ref | {xh} | {LT[key]:.3f} | {st['sig_u'][0]:.3f} |")
for key, xh in (("ds_dw_x1", 1), ("ds_dw_x4", 4), ("ds_dw_x6", 6)):
    st = proto.layer_state(np.array([float(xh)]), np.array([0.0]), np.zeros(1), dict(H=1.0, h_c=1.0, h_at_xr=0.0, s_lee=1.0), xr, 1.0, K["u2_unresolved_over_u1"], f_sep_force=1.0)
    L.append(f"| уступ: δ_ω/H | {xh} | {LT[key]:.2f} | {st['delta'][0]:.2f} |")
xrh = LT["hill_xr"]
for key, xh in (("hill_su_x0p5", 0.5), ("hill_su_x2", 2), ("hill_su_x4", 4), ("hill_su_x6", 6), ("hill_su_x8", 8)):
    st = proto.layer_state(np.array([float(xh)]), np.array([1.0]), np.zeros(1), dict(H=1.0, h_c=1.0, h_at_xr=0.0, s_lee=1.0), xrh, 1.0, K["u2_unresolved_over_u1"], f_sep_force=1.0)
    yc = st["yc"][0]
    st = proto.layer_state(np.array([float(xh)]), np.array([yc]), np.zeros(1), dict(H=1.0, h_c=1.0, h_at_xr=0.0, s_lee=1.0), xrh, 1.0, K["u2_unresolved_over_u1"], f_sep_force=1.0)
    L.append(f"| холм: пик σ_u/u_b (Re 10 600) | {xh} | {LT[key]:.3f} | {st['sig_u'][0]:.3f} |")
open(os.path.join(O, "tables.md"), "w", encoding="utf-8").write("\n".join(L) + "\n")
print("\n".join(L))
