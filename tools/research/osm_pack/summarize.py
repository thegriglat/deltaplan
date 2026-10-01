"""Сводка замеров Словении и экстраполяция (оценка) -> results/summary.json, results/summary.csv.

    python3 summarize.py
Размеры PBF Geofabrik/planet — Content-Length на 30.09.2026 (см. README). Площади — справочные.
"""
import csv
import json
from pathlib import Path

R = Path(__file__).parent / "results"
MB = 1e6
osm = json.loads((R / "slovenia_osm.json").read_text())
ras = json.loads((R / "slovenia_rasters.json").read_text())

SLO_KM2 = 20271
PBF = {"Словения": 313335209, "Швейцария": 547252929, "Австрия": 811212288,
       "Россия": 4167329472, "Мир (planet)": 94983340321}
AREA = {"Словения": 20271, "Швейцария": 41285, "Австрия": 83879, "Россия": 17098246,
        "Мир (planet)": 134e6}  # суша без Антарктиды ~134 млн км²
ALTAI = {"pbf": 63289351, "filtered": 57872069, "km2": 92903}  # замер фильтра (complete_ways)

# растры: байт/км² по двум пробным квадратам (среднее), Словения — пересчёт на площадь
per = {}
for k in ("q1p_br", "q01p_br", "q1_br", "f32_br", "far3_q1p_br", "far7_q1p_br", "wc10_br",
          "wc25_br", "game25_br", "q1p_zstd", "wc10_zstd", "wc25_zstd"):
    v = [ras["sum"][s][k] / ras["sum"][s]["area_km2"] for s in ras["sum"]]
    per[k] = {"горы": v[0], "холмы": v[1], "среднее": sum(v) / 2}

osm_br = osm["totals"]["all_br"]
osm_notp = osm["totals"]["no_tp_br"]
ratio = osm_br / PBF["Словения"]
dens = osm_br / SLO_KM2
rast = per["q1p_br"]["среднее"] + per["wc25_br"]["среднее"]
rows = []
for reg in PBF:
    rows.append({
        "регион": reg, "PBF, МБ": round(PBF[reg] / MB, 1), "площадь, км²": AREA[reg],
        "OSM по доле PBF, МБ": round(PBF[reg] * ratio / MB, 1),
        "OSM по плотности Словении, МБ": round(AREA[reg] * dens / MB, 1),
        "рельеф 30 м q1 + покров 25 м, МБ": round(AREA[reg] * rast / MB, 1),
        "покров 10 м вместо 25 м, +МБ": round(AREA[reg] * (per["wc10_br"]["среднее"]
                                                         - per["wc25_br"]["среднее"]) / MB, 1),
    })
out = {"osm_ratio_to_pbf": ratio, "osm_bytes_per_km2": dens, "osm_no_tp_bytes_per_km2":
       osm_notp / SLO_KM2, "raster_bytes_per_km2": per, "slovenia": {
           "osm_br": osm_br, "osm_no_tp_br": osm_notp,
           **{k: v["среднее"] * SLO_KM2 for k, v in per.items()}},
       "altai_filter_share": ALTAI["filtered"] / ALTAI["pbf"],
       "altai_pbf_bytes_per_km2": ALTAI["pbf"] / ALTAI["km2"],
       "slovenia_pbf_bytes_per_km2": PBF["Словения"] / SLO_KM2,
       "extrapolation": rows}
(R / "summary.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
with open(R / "summary.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0]))
    w.writeheader()
    w.writerows(rows)
print(json.dumps(out, ensure_ascii=False, indent=1))
