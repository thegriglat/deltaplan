"""Сводка results/slovenia_min.json + экстраполяция на планету -> results/summary_min.json, печать таблиц.

    python -I summarize_min.py
PBF planet — Content-Length на 30.09.2026 (как в summarize.py); суша без Антарктиды ~134 млн км².
"""
import json
from pathlib import Path

R = Path(__file__).parent / "results"
r = json.loads((R / "slovenia_min.json").read_text())
SLO_PBF = 299.0e6 if False else 313335209   # прошлый замер; новая выгрузка — см. README
PLANET_PBF, PLANET_KM2 = 94983340321, 134e6
out = {}
for lv in ("detail", "world"):
    d = r[lv]
    print(f"== {lv}: площадь {d['area_km2']} км², ячеек {d['cells_in_region']}")
    print(f"{'поток':12} {'raw':>10} {'zstd19':>10} {'brotli':>10} {'яч.непуст':>9} "
          f"{'zstd/яч: среднее':>16} {'медиана':>8} {'макс':>8}")
    for s, v in d["streams"].items():
        p = v["per_cell_zstd"]
        print(f"{s:12} {v['raw']:10} {v['zstd']:10} {v['br']:10} {v['cells_nonempty']:9} "
              f"{p['mean']:16} {p['median']:8} {p['max']:8}")
    m = d["lake_mask"]
    if m["cells_with_mask"]:
        print("маска:", {k: v for k, v in m.items() if k != "per_cell_best_zstd"}, m["per_cell_best_zstd"])
    for k in ("total_variant_mask_zstd", "total_variant_vec_zstd", "total_variant_mask_br",
              "total_variant_vec_br", "bytes_per_km2_mask", "bytes_per_km2_vec"):
        print(k, d[k])
    for k in ("per_cell_variant_mask_zstd", "per_cell_variant_vec_zstd"):
        print(k, d[k])
    bpk = d["bytes_per_km2_vec"] if lv == "world" else d["bytes_per_km2_mask"]
    tot = d["total_variant_vec_zstd"] if lv == "world" else d["total_variant_mask_zstd"]
    out[lv] = {"slovenia_bytes": tot, "bytes_per_km2": bpk,
               "planet_by_density_MB": round(PLANET_KM2 * bpk / 1e6, 1),
               "planet_by_pbf_share_MB": round(PLANET_PBF * tot / SLO_PBF / 1e6, 1)}
    print(out[lv])
(R / "summary_min.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
print("build", r["build"]["t_parse_s"], r["build"]["t_write_mask_s"], r["t_analyze_s"])
print(r["build"]["detail"]["parts"], r["build"]["world"]["parts"])
