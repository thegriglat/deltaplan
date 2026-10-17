"""TW-3: до / прототип TW-2 / правка TW-3 по стартам → before_after.csv и таблица markdown (stdout).
До и прототип — tools/research/takeoff_wind/TW-2/runs.csv (метки v1, b1 и p2, иначе p1; код scripts/ configs/ data/
с тех пор не менялся); правка — runs.csv рядом (метка t3, TW-2/summary.py по TW-2/out/t3). python3 compare.py"""
import csv, os

HERE = os.path.dirname(os.path.abspath(__file__))
TW2 = os.path.join(HERE, "..", "TW-2")


def load(path):
    return {(r["tag"], r["variant"]): r for r in csv.DictReader(open(path))}


old, new = load(os.path.join(TW2, "runs.csv")), load(os.path.join(HERE, "runs.csv"))
pairs = [(v, "v1") for v in ("calc", "h9", "h15", "overcast", "w4")] + [
    (v, "b1") for v in ("ridge_west_calc", "landing_hill_calc", "lee_bowl_calc", "crater_ridge_calc", "east_cliffs_calc",
                        "plateau_landing_calc", "thermal_slope_calc", "ongudai", "ongudai_w2", "askarovo_w", "askarovo_e",
                        "askarovo_w2")]


def f(r, k):
    try:
        return float(r[k])
    except (TypeError, ValueError, KeyError):
        return float("nan")


out = []
for v, bt in pairs:
    b, p, a = old.get((bt, v)), old.get(("p2", v)) or old.get(("p1", v)), new.get(("t3", v))
    if not b or not a:
        continue
    p = p or {}
    ub, up, ua = f(b, "u10_mean"), f(p, "u10_mean"), f(a, "u10_mean")
    hb, hp, ha = f(b, "u100_mean"), f(p, "u100_mean"), f(a, "u100_mean")
    out.append({"start": v, "k_before": round(f(b, "inflow_k"), 3), "k_after": round(f(a, "inflow_k"), 3),
                "u10_before": ub, "u10_proto": up, "u10_after": ua, "u10_change_pct": round(100 * (ua / ub - 1), 1),
                "u100_before": hb, "u100_proto": hp, "u100_after": ha, "u100_change_pct": round(100 * (ha / hb - 1), 1),
                "dir10_before": b.get("dir10_from_deg"), "dir10_after": a.get("dir10_from_deg"),
                "frozen_before": round(f(b, "frozen_frac"), 2), "frozen_after": round(f(a, "frozen_frac"), 2)})
w = csv.DictWriter(open(os.path.join(HERE, "before_after.csv"), "w"), fieldnames=list(out[0]))
w.writeheader()
w.writerows(out)
print("| старт (вариант) | k до → после | U10 до → прототип TW-2 → TW-3, м/с | Δ U10 | U100 до → прототип → TW-3, м/с | "
      "Δ U100 | направление на 10 м до → после, ° | заморожено до/после |")
print("|---|---|---|---|---|---|---|---|")
for r in out:
    print(f"| {r['start']} | {r['k_before']} → {r['k_after']} | {r['u10_before']:.2f} → {r['u10_proto']:.2f} → "
          f"{r['u10_after']:.2f} | {r['u10_change_pct']:+.1f} % | {r['u100_before']:.2f} → {r['u100_proto']:.2f} → "
          f"{r['u100_after']:.2f} | {r['u100_change_pct']:+.1f} % | {r['dir10_before']} → {r['dir10_after']} | "
          f"{r['frozen_before']}/{r['frozen_after']} |")
