#!/usr/bin/env python3
"""QL-9: out/s9_gpu_*.json -> раздел qol9 в summary_numbers.json (остальные разделы не трогаем)."""
import glob, json, math, os, statistics as st

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
SUM = os.path.join(HERE, "summary_numbers.json")
H, FOV, MIN_PX = 1080.0, 60.0, 4.0
SPAN_SW, SIZE_FL = 0.34, 0.12


def px(size, dist, scale_cap=40.0):
    """Размер на экране с учётом min_px (шейдер раздувает до min_px, не больше scale_cap)."""
    raw = size / dist * (H / 2) / math.tan(math.radians(FOV) / 2)
    return max(raw, min(MIN_PX, raw * scale_cap))


runs = {}
for f in sorted(glob.glob(os.path.join(OUT, "s9_gpu_*_*.json"))):
    d = json.load(open(f))
    runs[(d["location"], int(d["hour"]))] = d
if not runs:
    raise SystemExit("нет out/s9_gpu_*.json")

# Базовая линия «до»: признаки, что были до QL-9 (пылевые вихри и новые стаи птиц) — QL-5, поле GPU.
summ = json.load(open(SUM)) if os.path.exists(SUM) else {}
before = {}
for r in summ.get("rows", []):
    if not str(r.get("engine", "")).startswith("phase"):
        continue
    before.setdefault(r["location"], []).append(r["dust_in_3km_10min"] + r["flock_spawns_10min"])
before_min = min(st.mean(v) for v in before.values()) if before else None
before_dust = {}
for r in summ.get("rows", []):
    if str(r.get("engine", "")).startswith("phase"):
        before_dust.setdefault(r["location"], []).append(r["dust_in_3km_10min"])

rows = []
per_place = {}
off = 0
for (loc, hour), d in sorted(runs.items()):
    for pname, p in d["points"].items():
        rows.append({"location": loc, "hour": hour, "point": pname, "signs_new_10min": p["signs_new_10min"],
                     "swallow_flocks": p["swallow_flocks"], "fluff_sources": p["fluff_sources"],
                     "samples": p["samples"], "off_thermal_samples": p["off_thermal_samples"],
                     "entries_max": p["entries_max"]})
        per_place.setdefault(loc, []).append(p["signs_new_10min"])
        off += p["off_thermal_samples"]
alld = [x for d in runs.values() for p in d["points"].values() for x in p["dist_samples_m"]]
alld.sort()
sw_px = [px(SPAN_SW, x) for x in alld]
fl_px = [px(SIZE_FL, x) for x in alld]
n = max(len(alld), 1)
q = {
    "signs_per_10min_min": round(min(st.mean(v) for v in per_place.values()), 1),
    "signs_per_10min_min_run": min(r["signs_new_10min"] for r in rows),
    "signs_per_10min_by_place": {k: round(st.mean(v), 1) for k, v in per_place.items()},
    "signs_per_10min_mean": round(st.mean(r["signs_new_10min"] for r in rows), 1),
    "signs_off_thermal": off,
    "samples_total": sum(r["samples"] for r in rows),
    "before_signs_per_10min_min": round(before_min, 1) if before_min is not None else None,
    "before_dust_per_10min_min": round(min(st.mean(v) for v in before_dust.values()), 1) if before_dust else None,
    "before_note": "до = пылевые вихри в 3 км + новые стаи птиц за 10 мин (QL-5, поле GPU), среднее по часам/точкам, минимум по местам",
    "dist_median_m": round(st.median(alld)) if alld else None,
    "share_swallow_ge4px_if_min_px": round(sum(1 for v in sw_px if v >= MIN_PX - 1e-6) / n, 3),
    "share_swallow_native_ge2px": round(sum(1 for x in alld if SPAN_SW / x * (H / 2) / math.tan(math.radians(FOV) / 2) >= 2) / n, 3),
    "rows": rows,
}
summ["qol9"] = q
json.dump(summ, open(SUM, "w"), ensure_ascii=False, indent=1)
print(json.dumps({k: v for k, v in q.items() if k != "rows"}, ensure_ascii=False, indent=1))
