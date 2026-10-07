#!/usr/bin/env python3
"""QL-5: сводка out/*.json -> table_places.csv, table_px.csv, summary_numbers.json."""
import csv, glob, json, math, os, statistics as st

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
H = 1080.0


def px(span, dist, fov_deg):
    return span / dist * (H / 2) / math.tan(math.radians(fov_deg) / 2)


def dist_for_px(span, n, fov_deg):
    return span * (H / 2) / math.tan(math.radians(fov_deg) / 2) / n


runs = {}
for f in sorted(glob.glob(os.path.join(OUT, "*_*_*.json"))):
    d = json.load(open(f))
    kind = os.path.basename(f).split("_")[0]
    runs[(kind, d["location"], int(d["hour"]))] = d
if not runs:
    raise SystemExit("нет out/*.json")
any_run = next(iter(runs.values()))
span = any_run["bird"]["span_m"]

# 1. Размер птицы в пикселях.
rows = []
for fov in (45, 60, 100):
    for dist in (300, 800, 1500):
        rows.append({"fov_v_deg": fov, "dist_m": dist, "span_m": round(span, 3),
                     "px": round(px(span, dist, fov), 2)})
with open(os.path.join(HERE, "table_px.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, rows[0].keys())
    w.writeheader()
    w.writerows(rows)
reach = {f"fov{fov}_{n}px_m": round(dist_for_px(span, n, fov)) for fov in (45, 60, 100) for n in (1, 2, 5, 10)}

# 2-3. По местам.
SCALES = (1, 2, 3, 5)
FOV = 60.0
table = []
for (kind, loc, hour), d in sorted(runs.items()):
    for pname, p in d["points"].items():
        ft = p["filter_t0"]
        ds = p["bird_distances_per_s"]
        n = len(ds)
        row = {
            "engine": {"gpu": "phase+Picard (GPU)", "ana": "analytic (headless)"}[kind],
            "air_src": d["air_src"], "air_engine": d["air_engine"],
            "location": loc, "hour": hour, "point": pname,
            "thermals_all": ft["all"], "pass_strength": ft["strength_ok"],
            "pass_strength_envelope": ft["strength_envelope_ok"],
            "pass_all_filters": ft["pass_all"], "radius_only": ft["radius_only"],
            "pass_depth_ok": ft["pass_depth_ok"],
            "flock_spawns_10min": p["flock_spawns"], "unique_birds_10min": p["unique_birds"],
            "birds_mean": round(sum(len(x) for x in ds) / n, 2) if n else 0,
            "dust_in_3km_10min": p["dust_unique_in_3km"],
            "dust_visible_cap3_10min": p["dust_unique_visible_cap3"],
            "clouds_5km_10min": p["cloud_unique_5km"],
            "clouds_5km_diam_ge700": p["cloud_unique_5km_diam_ge700"],
            "clouds_5km_max_simult": p["cloud_max_simult_5km"],
        }
        alld = [x for s in ds for x in s]
        row["min_dist_m"] = round(min(alld)) if alld else ""
        row["median_dist_m"] = round(statistics_median := st.median(alld)) if alld else ""
        for k in SCALES:
            thr = dist_for_px(span * k, 2, FOV)
            near = [sum(1 for x in s if x <= thr) for s in ds]
            row[f"px2_span_x{k}_max_simult"] = max(near) if near else 0
            row[f"px2_span_x{k}_time_frac"] = round(sum(1 for c in near if c > 0) / n, 3) if n else 0
        table.append(row)

with open(os.path.join(HERE, "table_places.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, table[0].keys())
    w.writeheader()
    w.writerows(table)

summary = {"bird_span_m": span, "reach_m": reach, "rows": table,
           "aabb": any_run["bird"]["aabb_size_m"]}
json.dump(summary, open(os.path.join(HERE, "summary_numbers.json"), "w"), ensure_ascii=False, indent=1)
print(json.dumps(reach))
for r in table:
    print(r["engine"][:3], r["location"], r["hour"], r["point"][:1], "all", r["thermals_all"],
          "pass", r["pass_all_filters"], "flocks", r["flock_spawns_10min"], "birds", r["unique_birds_10min"],
          "dist_med", r["median_dist_m"], "px2x1", r["px2_span_x1_max_simult"], "dust", r["dust_in_3km_10min"],
          "cl", r["clouds_5km_10min"])

# Сводка по всем GPU-прогонам: доля птице-секунд по размеру в пикселях и дальность.
agg = {}
for kind in ("gpu", "ana"):
    allp = {"A": [], "B": []}
    for (k, loc, hour), d in runs.items():
        if k != kind:
            continue
        for pname, p in d["points"].items():
            for s in p["bird_distances_per_s"]:
                allp[pname[0]].extend(s)
    for pt, ds in allp.items():
        if not ds:
            continue
        a = {"n_bird_samples": len(ds), "dist_median_m": round(st.median(ds)),
             "dist_p10_m": round(sorted(ds)[len(ds) // 10]), "dist_p90_m": round(sorted(ds)[len(ds) * 9 // 10])}
        for thr in (1, 2, 5, 10, 20):
            a[f"share_px_ge{thr}"] = round(sum(1 for x in ds if px(span, x, FOV) >= thr) / len(ds), 3)
        a["px_at_median"] = round(px(span, a["dist_median_m"], FOV), 2)
        agg[f"{kind}_{pt}"] = a
    sel = [r for r in table if r["engine"].startswith("phase" if kind == "gpu" else "analytic")]
    for pt in ("A", "B"):
        rr = [r for r in sel if r["point"].startswith(pt)]
        if rr:
            agg[f"{kind}_{pt}_means"] = {
                "thermals_all": round(st.mean(r["thermals_all"] for r in rr)),
                "pass_all_filters": round(st.mean(r["pass_all_filters"] for r in rr), 1),
                "birds_mean": round(st.mean(r["birds_mean"] for r in rr), 1),
                "flock_spawns": round(st.mean(r["flock_spawns_10min"] for r in rr), 1),
                "px2_x1_time_frac": round(st.mean(r["px2_span_x1_time_frac"] for r in rr), 2),
                "dust_3km": round(st.mean(r["dust_in_3km_10min"] for r in rr), 1),
                "clouds_5km": round(st.mean(r["clouds_5km_10min"] for r in rr), 1),
            }
summary["aggregate"] = agg
json.dump(summary, open(os.path.join(HERE, "summary_numbers.json"), "w"), ensure_ascii=False, indent=1)
print(json.dumps(agg, ensure_ascii=False, indent=1))
