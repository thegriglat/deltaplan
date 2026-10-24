#!/usr/bin/env python3
"""Residuals per check, Rust vs reference (history_ref): SVG plot + markdown table (AC-R3).

    python3 residuals.py            # writes residuals_ongudai_u3.svg, prints the table
"""
import json, math, os

d = os.path.dirname(os.path.abspath(__file__))
CASES = ["u3_heat", "u3_mech"]
KEYS = [("mom_rms", "импульс, rms"), ("th_rms", "θ′, rms"), ("div_rms", "∇·u, rms")]
COL = {"u3_heat": "#1f77b4", "u3_mech": "#d95f02"}
runs = {c: json.load(open(os.path.join(d, f"ongudai_d400_{c}_release_t8.json"))) for c in CASES}

# --- table
print("| случай | проверка (итерация) | величина | Rust | эталон f64 | Rust/эталон |")
print("|---|---|---|---|---|---|")
for c, r in runs.items():
    ref = {h["it"]: h for h in r["history_ref"]}
    its = sorted(h["it"] for h in r["history"])
    pick = [its[0], its[len(its) // 4], its[len(its) // 2], its[3 * len(its) // 4], its[-1]]
    byit = {h["it"]: h for h in r["history"]}
    for it in pick:
        for k, name in KEYS:
            a, b = byit[it][k], ref[it][k]
            print(f"| {c} | {it} | {name} | {a:.3e} | {b:.3e} | {a / b:.4f} |")
worst = 0.0
for r in runs.values():
    ref = {h["it"]: h for h in r["history_ref"]}
    for h in r["history"]:
        for k, _ in KEYS:
            worst = max(worst, abs(h[k] / ref[h["it"]][k] - 1))
print(f"\nнаибольшее |Rust/эталон − 1| по всем проверкам и величинам обоих случаев: {worst:.3f}")

# --- svg
W, H, mx, my = 330, 230, 52, 28
svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{3 * W}" height="{H + 40}" font-family="sans-serif" font-size="11">',
       '<rect width="100%" height="100%" fill="white"/>']
for p, (k, name) in enumerate(KEYS):
    vals = [h[k] for r in runs.values() for h in r["history"] + r["history_ref"] if h.get(k, 0) > 0]
    lo, hi = math.floor(math.log10(min(vals))), math.ceil(math.log10(max(vals)))
    xmax = max(h["it"] for r in runs.values() for h in r["history_ref"])
    ox = p * W

    def X(it): return ox + mx + (W - mx - 10) * it / xmax
    def Y(v): return my + (H - my - 28) * (1 - (math.log10(v) - lo) / (hi - lo))
    svg.append(f'<text x="{ox + mx}" y="16" font-weight="bold">{name}</text>')
    for e in range(lo, hi + 1):
        y = Y(10.0 ** e)
        svg.append(f'<line x1="{ox + mx}" x2="{ox + W - 10}" y1="{y:.1f}" y2="{y:.1f}" stroke="#ddd"/>'
                   f'<text x="{ox + mx - 4}" y="{y + 4:.1f}" text-anchor="end">1e{e}</text>')
    for t in range(0, int(xmax) + 1, 50):
        svg.append(f'<text x="{X(t):.1f}" y="{H - 12}" text-anchor="middle">{t}</text>')
    for c, r in runs.items():
        for hist, dash, sw in ((r["history_ref"], "5,3", 3), (r["history"], "", 1.2)):
            pts = " ".join(f"{X(h['it']):.1f},{Y(h[k]):.1f}" for h in hist if h.get(k, 0) > 0)
            da = f' stroke-dasharray="{dash}"' if dash else ""
            svg.append(f'<polyline points="{pts}" fill="none" stroke="{COL[c]}" stroke-width="{sw}"{da} opacity="{0.55 if dash else 1}"/>')
yl = H + 22
svg.append(f'<text x="{mx}" y="{yl}">итерация; штрих (толстый) — эталон f64, сплошная — Rust f32, 8 потоков; '
           f'<tspan fill="{COL["u3_heat"]}">■ u3_heat</tspan> <tspan fill="{COL["u3_mech"]}">■ u3_mech</tspan></text>')
svg.append("</svg>")
open(os.path.join(d, "residuals_ongudai_u3.svg"), "w").write("\n".join(svg))
