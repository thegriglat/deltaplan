"""Markdown tables for the PR-8 README from summary.json: python3 md_tables.py summary.json > tables.md"""
import json
import sys

d = json.load(open(sys.argv[1]))


def row(p, with_dom=True):
    v, r, f = p["dev"], p["residuals"], p["flows"]
    L, S, T, D = v["launch"], v["slopes"], v["thermals"], v["domain"]
    lab = f"N={p['N']}" if p["by"] == "iter" else f"tol×{p['tol_scale']:g} ({p['N']} it)"
    return (f"| {lab} | {p['t_s']:.2f} | {r['mom_rms']:.1e} / {r['div_rms']:.1e} / {r['th_rms']:.1e} | "
            f"{L['dw_max']:.3f} / {L['du_max']:.3f} | {S['dw_max']:.3f} / {S['dwt_max']:.3f} | {T['dw_max']:.3f} | "
            f"{D['dw_max']:.3f} / {D['du_max']:.3f} | {f['thermal_w_peak_err']:+.3f} / {f['thermal_w_mean_err']:+.3f} / {f['slope_w_mean_err']:+.3f} |")


HEAD = ("| точка | t, с | mom / div / th rms | старт Δw / Δ(u,v) max | склоны Δw / Δwt max | термики Δw max | область Δw / Δ(u,v) max "
        "| поток: пик w терм. / среднее терм. / среднее склон |\n|---|---|---|---|---|---|---|---|")
for s in d["series"]:
    n = s["n_cells"]
    print(f"\n#### {s['case']} ({s['start']}" + (f", от {s['warm_from']}" if s["warm_from"] else "") + ")\n")
    print(f"Эталон: {s['ref']['iters']} итераций, {s['ref']['t_s']:.2f} с (чистый прогон); клеток: старт {n['launch']}, склоны {n['slopes']}, термики {n['thermals']}, область {n['domain']}.\n")
    print(HEAD)
    for p in s["points"]:
        print(row(p))
print("\n#### Пол точности: сошедшийся f32 против f64-решения случая (sol_*), и эталон против «глубокого» (tol_scale 0,1)\n")
print("| случай | f32−f64 старт Δw / Δ(u,v) max | f32−f64 область Δ(u,v) max, θ' max (К) | эталон−глубокое: старт Δw / Δ(u,v) max | склоны Δwt | область Δw / Δ(u,v) max |\n|---|---|---|---|---|---|")
for c, f in d["floor"].items():
    a, g = f["dev"], f.get("ref_vs_deep")
    gl = f"{g['launch']['dw_max']:.3f} / {g['launch']['du_max']:.3f} | {g['slopes']['dwt_max']:.3f} | {g['domain']['dw_max']:.3f} / {g['domain']['du_max']:.3f}" if g else "- | - | -"
    print(f"| {c} | {a['launch']['dw_max']:.1e} / {a['launch']['du_max']:.1e} | {a['domain']['du_max']:.1e}, {f['th_abs_max_domain']:.1e} | {gl} |")
print("\n#### Тёплый старт до первой проверки (только поля) и изменение поля за 15 мин\n")
print("| точка | старт Δw / Δ(u,v) max | склоны Δw max | область Δw / Δ(u,v) max |\n|---|---|---|---|")
v = d["warm_init_vs_ref"]
print(f"| исходное h1200 против сошедшегося h1215 (N=0) | {v['launch']['dw_max']:.3f} / {v['launch']['du_max']:.3f} | {v['slopes']['dw_max']:.3f} | {v['domain']['dw_max']:.3f} / {v['domain']['du_max']:.3f} |")
for e in d["warm_early"]:
    v = e["dev"]
    print(f"| после {e['N']} итераций тёплого | {v['launch']['dw_max']:.3f} / {v['launch']['du_max']:.3f} | {v['slopes']['dw_max']:.3f} | {v['domain']['dw_max']:.3f} / {v['domain']['du_max']:.3f} |")
