#!/usr/bin/env python3
"""LT-7: out/sections.json, out/obs_compare.json -> out/tables.md (таблицы для docs/research/lee_turb/model.md и model_obs.md).
Запуск: python3 -I make_tables.py"""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import proto
import numpy as np

O = os.path.join(HERE, "out")
base = json.load(open(os.path.join(O, "sections.json")))
obs = json.load(open(os.path.join(O, "obs_compare.json")))
exp = json.load(open(os.path.join(HERE, "..", "lit", "derived_exp.json")))
f = lambda v, n=2: "–" if (v is None or not np.isfinite(v)) else f"{v:.{n}f}"
nm = lambda b: b.replace("ongudai_", "")
L = []

L.append("### T1. Онгудай: доля колонок с центром слоя по полю, максимум σ_w (agl 5–150 м, x/H 0,05–12)\n")
L.append("Ячейка: σ_w, м/с (x/H; высота над землёй, м; z/H над подножием).\n")
L.append("| разрез | H, м | f_sep | колонок x/H 0,5–6 с q>0,5 | прежняя | LT-5 | A (линия LT-7) | B под линией (LT-7) |\n|---|---|---|---|---|---|---|---|")
for b, m in base.items():
    c = lambda t: f"{m['max'][t]['sigma_w']:.2f} ({m['max'][t]['xh']:.1f}; {m['max'][t]['agl']:.0f}; {m['max'][t]['zf']:.2f})"
    L.append(f"| {nm(b)} | {m['H']:.0f} | {m['f_sep']:.2f} | {m['field_center']['frac_q_gt_half']:.2f} | {c('old')} | {c('lt5')} | {c('A_new')} | {c('B_new')} |")

L.append("\n### T2. Онгудай, strong: центр слоя по полю и линии, м над уровнем гребня\n")
L.append("ΔU_f/U1 — дефицит u на 0,1H над землёй; q — вес поля; z½ — центр по полю; «запас» — линия по глубине пузыря; LT-5 — прежняя линейная; «итог» = q·z½ + (1−q)·запас.\n")
L.append("| разрез | x/H | ΔU_f/U1 | q | z½ | запас | LT-5 | итог | z½ над землёй, м |\n|---|---|---|---|---|---|---|---|---|")
for b, m in base.items():
    if "strong" not in b:
        continue
    for s in m["stations"]:
        if round(s["xh"]) not in (1, 2, 4, 6) or s["xh"] < 0.9 or not np.isfinite(s["yc_rel"]):
            continue
        L.append(f"| {nm(b).replace('strong_', '')} | {s['xh']:.1f} | {f(s['dUf_frac'])} | {s['q']:.2f} | {f(s['z_half_rel'], 0)} | {f(s['yc_fb_rel'], 0)} | {f(s['yc_lt5_rel'], 0)} | {f(s['yc_rel'], 0)} | {f(s['z_half_agl'], 0)} |")

L.append("\n### T3. Онгудай, strong: σ_w на 30 м над землёй и максимум по колонке (agl 5–150 м), м/с: прежняя → LT-5 → A → B\n")
L.append("| разрез | x/H | σ_w@30 | max колонки |\n|---|---|---|---|")
for b, m in base.items():
    if "strong" not in b:
        continue
    for s in m["stations"]:
        L.append(f"| {nm(b).replace('strong_', '')} | {s['xh']:.1f} | " + " → ".join(f"{s['sw30_' + t]:.2f}" for t in ("old", "lt5", "A_new", "B_new")) +
                 " | " + " → ".join(f"{s['col_' + t]:.2f}" for t in ("old", "lt5", "A_new", "B_new")) + " |")

L.append("\n### T4. Онгудай: гладкость перехода поле / запасная линия (соседние колонки x/H 0,5–6)\n")
L.append("| разрез | max скачок q | max dy_c/dx итог / запас, м/м | max скачок max σ_w колонки, м/с: прежняя / B запас / B итог |\n|---|---|---|---|")
for b, m in base.items():
    c = m["field_center"]
    L.append(f"| {nm(b)} | {f(c['max_dq'])} | {f(c['max_dyc_over_dx'], 1)} / {f(c['max_dyc_fb_over_dx'], 1)} | {f(c['max_dcol_old'])} / {f(c['max_dcol_B_fb'])} / {f(c['max_dcol_B_new'])} |")

L.append("\n### T5. Положение линии слоя против уступа и холма: высота над дном/подножием, доли H\n")
geo_u = dict(H=1.0, h_c=1.0, h_at_xr=0.0, foot=0.0, s_lee=1.0)
L.append("| форма | x/x_r | эксперимент (пик σ_u) | запасная LT-7 | LT-5 |\n|---|---|---|---|---|")
xr = exp["step_xr"]
for key in ("1", "4", "6"):
    xx = np.array([float(key)])
    L.append(f"| уступ (x_r = {xr:.2f}H), x/H={key} | {float(key) / xr:.2f} | {exp['step'][key]['su_y']:.2f} | {proto.yc_fallback(xx, np.zeros(1), geo_u, xr)[0]:.2f} | {proto.yc_lt5(xx, np.zeros(1), geo_u, xr)[0]:.2f} |")
xrh = exp["hill"]["10600"]["xr"]
for key in ("0.5", "1", "2", "4", "6"):
    xx = np.array([float(key)])
    L.append(f"| холм (x_r = {xrh:.2f}h), x/h={key} | {float(key) / xrh:.2f} | {exp['hill']['10600']['rows'][key]['su_y']:.2f} | {proto.yc_fallback(xx, np.zeros(1), geo_u, xrh)[0]:.2f} | {proto.yc_lt5(xx, np.zeros(1), geo_u, xrh)[0]:.2f} |")

S = obs["summary"]
L.append("\n### M1. Мачты, 0 < x/H ≤ 6: RMSE и смещение ТКЭ/u_ref², один набор строк для всех вариантов\n")
L.append("Прежняя — механика гребня без слоя; A, B — LT-6 (линия LT-5; B на весь столбец); A2 — запасная линия LT-7; N — B только под линией LT-7; N5 — то же под линией LT-5; A_meas — «идеальное поле» (скорость измерена); bg — постоянный фон.\n")
vs = ("old", "A", "B", "A2", "N", "N5", "A_meas", "bg")
L.append("| случай | n | " + " | ".join(vs) + " |\n|---|---|" + "---|" * len(vs))
for k, v in S.items():
    st = v["stats_within6"]
    L.append(f"| {k} RMSE | {st['_n']['n']} | " + " | ".join(f"{st[t]['rmse']:.4f}" for t in vs) + " |")
    L.append(f"| {k} смещение | | " + " | ".join(f"{st[t]['bias']:+.4f}" for t in vs) + " |")
L.append("\nТо же выше 30 м над землёй (вне кроны):\n")
L.append("| случай | n | " + " | ".join(vs) + " |\n|---|---|" + "---|" * len(vs))
for k, v in S.items():
    st = v["stats_above30"]
    if st["_n"]["n"] == 0:
        continue
    L.append(f"| {k} RMSE | {st['_n']['n']} | " + " | ".join(f"{st[t]['rmse']:.4f}" for t in vs) + " |")
    L.append(f"| {k} смещение | | " + " | ".join(f"{st[t]['bias']:+.4f}" for t in vs) + " |")

L.append("\n### M2. Положение максимума ТКЭ/u_ref² на мачтах (0 < x/H ≤ 6): x/H; z/H над землёй\n")
vm = ("obs", "old", "A", "B", "A2", "N", "bg")
L.append("| случай | " + " | ".join(vm) + " |\n|---|" + "---|" * len(vm))
for k, v in S.items():
    L.append(f"| {k} | " + " | ".join(f"{v['max_within6'][t]['x_over_h']:.1f}; {v['max_within6'][t]['z_over_h']:.2f}" for t in vm) + " |")

L.append("\n### M3. Наклон ТКЭ/u_ref² по высоте на мачте (МНК по z/H, 0 < x/H ≤ 6; > 0 — растёт вверх)\n")
vp = ("obs", "old", "A", "B", "A2", "N", "bg")
L.append("| случай | мачта | n | x/H | " + " | ".join(vp) + " |\n|---|---|---|---|" + "---|" * len(vp))
for k, v in S.items():
    for r in v["profile_slopes"]:
        L.append(f"| {k} | {r['mast']} | {r['n']} | {r['x_over_h']:.1f} | " + " | ".join(f"{r['slope_' + t]:+.3f}" for t in vp) + " |")

import csv
L.append("\n### M0. Станции за гребнем (0 < x/H ≤ 6): ТКЭ/u_ref²; η — положение станции относительно линии LT-7 (η < 0 — под линией), w_B — вес B\n")
L.append("| случай | станция | x/H | z/H | данные | прежняя | A (LT-6) | B (LT-6) | A2 | N | фон | η | w_B |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for r in csv.DictReader(open(os.path.join(O, "obs_compare.csv"), encoding="utf-8")):
    if 0 < float(r["x_over_h"]) <= 6.0:
        g = lambda k: float(r["tke_%s_over_uref2" % k])
        L.append(f"| {r['site']}/{r['case']} | {r['station']} | {float(r['x_over_h']):.2f} | {float(r['z_over_h']):.2f} | {g('obs'):.4f} | {g('old'):.4f} | {g('A'):.4f} | {g('B'):.4f} | {g('A2'):.4f} | {g('N'):.4f} | {g('bg'):.4f} | {f(float(r['eta']))} | {float(r['w_below']):.2f} |")

open(os.path.join(O, "tables.md"), "w", encoding="utf-8").write("\n".join(L) + "\n")
