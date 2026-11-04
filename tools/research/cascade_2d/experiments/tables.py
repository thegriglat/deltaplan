"""CSD-4: таблицы для README из out/metrics, out/runs, out/verdict.json -> out/tables.md"""
import json, os
CD = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
O = CD + "/out"
v = json.load(open(f"{O}/verdict.json"))
L = []
f = lambda x, n=3: "—" if x is None else (f"{x:.{n}f}" if abs(x) >= 0.01 or x == 0 else f"{x:.1e}")
L += ["## T1. Точность на 25 м (СКО / U_ref в ROI), V3 против B400", "",
      "| случай | E_ref (B50) | E_u B400 | E_u V3(400) | E_u V3(200) | E_w B400 | E_w V3(400) | E_u_lee B400→V3 | ΔS B400→V3 | r_w V3 |", "|---|---|---|---|---|---|---|---|---|---|"]
for C, d in v["cases"].items():
    m = json.load(open(f"{O}/metrics/{C}.json"))
    bl = next(r for r in m["rows"] if r["variant"] == "B400")
    L.append(f"| {C} | {f(d['E_ref'])} | {f(d['B400']['E_u'])} | {f(d['V3_400']['E_u'])} | {f(d['V3_200']['E_u'])} | {f(d['B400']['E_w'])} | {f(d['V3_400']['E_w'])} | {f(bl['E_u_lee'])}→{f(d['V3_400']['E_u_lee'])} | {f(d['ref']['dS_B400'])}→{f(d['V3_400']['dS'])} | {f(d['V3_400']['r_w'],2)} |")
L += ["", "## T2. Варианты на 25 м (E_u / E_w; старт 400 | старт 200)", "", "| случай | V0 | V1 | V2 | V3 | V3h (сид 1) |", "|---|---|---|---|---|---|"]
for C in v["cases"]:
    m = json.load(open(f"{O}/metrics/{C}.json"))
    def g(var, p):
        r = next(r for r in m["rows"] if r["variant"] == var and r["dx"] == 25 and r["parent_dx"] == p and r["seed"] in (None, 1))
        return f"{r['E_u']:.3f}/{r['E_w']:.3f}"
    L.append(f"| {C} | " + " | ".join(f"{g(x,400)} \\| {g(x,200)}" for x in ("V0", "V1", "V2", "V3", "V3h")) + " |")
L += ["", "## T3. Баланс (K1), V3 от 400", "", "| случай | max rel_div по уровням | 200 | 100 | 50 | 25 | P400 (родитель) | P25 (эталон) | lost_flux | стенка родителя / подграни открыты |", "|---|---|---|---|---|---|---|---|---|---|"]
for C, d in v["cases"].items():
    k = d["K1"]; p = k["per_level"]
    L.append(f"| {C} | {k['max_rel_div']:.1e} | " + " | ".join(f"{p[x]:.1e}" for x in ("200", "100", "50", "25")) + f" | {k['parent_rel_div']:.1e} | {k['P25_rel_div']:.1e} | {k['lost_flux']} | {k['wall_parent_open_sub']} |")
L += ["", "## T4. Цена (K3), V3, один поток", "", "| случай | T_desc, с (медиана 10) | T(P25)/ny, с | отношение | RSS V3, МБ | RSS V1, МБ | поля, МБ | P25 RSS/ряд, МБ | опрос холодный, мкс | тёплый, мкс |", "|---|---|---|---|---|---|---|---|---|---|"]
for C, d in v["cases"].items():
    k = d["K3"]
    L.append(f"| {C} | {k['T_desc']:.3f} | {k['T_P25_row']:.0f} | {k['ratio']:.1e} | {k['rss_mb']:.0f} | {k['rss_V1_mb']:.0f} | {k['arrays_mb']:.1f} | {k['P25_rss_row_mb']:.0f} | {k['query_us']:.1f} | {k['query_warm_us']:.1f} |")
L += ["", "## T5. Парето (K4): B_k и стоимость, c на ряд", "", "| случай | T(P400)+T_desc | B400: T, E_u | B200: T, E_u | B100: T, E_u | B50: T, E_u | E_u V3 |", "|---|---|---|---|---|---|---|"]
for C, d in v["cases"].items():
    c = {x["k"]: x for x in d["K4"]["candidates"]}
    L.append(f"| {C} | {c[400]['T_row']+d['K3']['T_desc']:.2f} | " + " | ".join(f"{c[k]['T_row']:.2f}, {c[k]['E_u']:.3f}" for k in (400, 200, 100, 50)) + f" | {d['V3_400']['E_u']:.3f} |")
L += ["", "## T6. Сходимость (K5), V3 от 400: E_u против P_k своего уровня", "", "| случай | 200 | 100 | 50 | 25 | рост за уровень | max\\|u\\|/max\\|u\\|(P25) | 1 и 8 потоков | старт 200 / 400 (E_u) |", "|---|---|---|---|---|---|---|---|---|"]
for C, d in v["cases"].items():
    k = d["K5"]; e = k["E_u_levels"]
    L.append(f"| {C} | " + " | ".join(f"{e[x]:.3f}" for x in ("200", "100", "50", "25")) + f" | {', '.join(f'{x:.2f}' for x in k['growth'])} | {k['max_speed_ratio']:.2f} | {'побитно' if k['bitwise_1v8_threads'] else 'различаются'} ({k['bin_files_compared']} файлов) | {k['E_u_start200']:.3f} / {k['E_u_start400']:.3f} |")
L += ["", "## T7. Термик C3: V3 против эталона и B400", "", "| | w_max, м/с | F_up, м²/с |", "|---|---|---|"]
c3 = v["cases"]["C3"]
m = json.load(open(f"{O}/metrics/C3.json")); b = next(r for r in m["rows"] if r["variant"] == "B400")
L += [f"| P25 | {c3['ref']['w_max']:.3f} | {c3['ref']['F_up']:.1f} |", f"| B400 | {b['w_max']:.3f} | {b['F_up']:.1f} |", f"| V3 (400) | {c3['V3_400']['w_max']:.3f} | {c3['V3_400']['F_up']:.1f} |"]
open(f"{O}/tables.md", "w").write("\n".join(L) + "\n")
print("\n".join(L))
