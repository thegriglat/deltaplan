"""TW-2: до/после прототипа proto_theta_energy.patch по стартам → before_after.csv и таблица markdown.
До — прогоны b1 (места) и v1 (Термики, варианты), после — p2, иначе p1. python3 compare.py"""
import csv, os
HERE = os.path.dirname(os.path.abspath(__file__))
rows = list(csv.DictReader(open(os.path.join(HERE, "runs.csv"))))
by = {(r["tag"], r["variant"]): r for r in rows}
pairs = [(v, "v1") for v in ("calc", "h9", "h15", "overcast", "w4")] + [
    (v, "b1") for v in ("ridge_west_calc", "landing_hill_calc", "lee_bowl_calc", "crater_ridge_calc", "east_cliffs_calc",
                        "plateau_landing_calc", "thermal_slope_calc", "ongudai", "ongudai_w2", "askarovo_w", "askarovo_e", "askarovo_w2")]
out = []
for v, bt in pairs:
    b, a = by.get((bt, v)), by.get(("p2", v)) or by.get(("p1", v))
    if not b or not a:
        continue
    def f(r, k):
        try:
            return float(r[k])
        except (TypeError, ValueError):
            return float("nan")
    ub, ua = f(b, "u10_mean"), f(a, "u10_mean")
    hb, ha = f(b, "u100_mean"), f(a, "u100_mean")
    out.append({"start": v, "k_before": round(f(b, "inflow_k"), 3), "k_after": round(f(a, "inflow_k"), 3),
                "u10_before": ub, "u10_after": ua, "u10_change_pct": round(100 * (ua / ub - 1), 1),
                "u100_before": hb, "u100_after": ha, "u100_change_pct": round(100 * (ha / hb - 1), 1),
                "frozen_before": round(f(b, "frozen_frac"), 2), "frozen_after": round(f(a, "frozen_frac"), 2),
                "w10_max_before": b["w10_max"], "w10_max_after": a["w10_max"]})
w = csv.DictWriter(open(os.path.join(HERE, "before_after.csv"), "w"), fieldnames=list(out[0]))
w.writeheader(); w.writerows(out)
print("| старт (вариант) | k до → после | U10 до → после, м/с | Δ U10 | U100 до → после, м/с | Δ U100 | заморожено до/после |")
print("|---|---|---|---|---|---|---|")
for r in out:
    print(f"| {r['start']} | {r['k_before']} → {r['k_after']} | {r['u10_before']:.2f} → {r['u10_after']:.2f} | {r['u10_change_pct']:+.1f} % | "
          f"{r['u100_before']:.2f} → {r['u100_after']:.2f} | {r['u100_change_pct']:+.1f} % | {r['frozen_before']}/{r['frozen_after']} |")
