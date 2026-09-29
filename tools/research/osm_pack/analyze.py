"""Итог по собранному пакету: только ячейки, пересекающие границу региона.

    uv run --with shapely --with brotli --with zstandard python analyze.py <out_dir> <граница.geojson> <res.json>

Считает по потокам и группам сырые / brotli q11 / zstd 19 байты (каждый поток сжат отдельно
в каждой ячейке), целые ячейки (весь блоб) и вариант без track/path; число ячеек; площадь.
"""
from __future__ import annotations

import json
import sys
from collections import Counter
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import brotli
import zstandard

sys.path.insert(0, str(Path(__file__).parent))
import osmpack as op  # noqa: E402
from terrain_cover import region_cells  # noqa: E402


def split(blob: bytes) -> dict:
    p = 4
    n, p = op.get_varint(blob, p)
    out = {}
    for _ in range(n):
        sid, p = op.get_varint(blob, p)
        ln, p = op.get_varint(blob, p)
        out[op.STREAMS[sid]] = blob[p:p + ln]
        p += ln
    return out


def one_cell(f: Path):
    zc = zstandard.ZstdCompressor(level=19)
    tot = Counter()
    st = {}
    blob = f.read_bytes()
    streams = split(blob)
    size = 0
    for var, skip in (("all", ()), ("no_tp", ("roads_tp",))):
        b = blob if var == "all" else op.pack_cell(streams, skip)
        bb = brotli.compress(b, quality=11, lgwin=24)
        tot[f"{var}_raw"] += len(b)
        tot[f"{var}_br"] += len(bb)
        tot[f"{var}_zstd"] += len(zc.compress(b))
        if var == "all":
            size = len(bb)
    for s, v in streams.items():
        st[s] = Counter(raw=len(v), br=len(brotli.compress(v, quality=11, lgwin=24)),
                        zstd=len(zc.compress(v)))
    return tot, st, size


def main():
    out, geo, res_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    cells, area = region_cells(geo)
    zc = zstandard.ZstdCompressor(level=19)
    st = {s: Counter() for s in op.STREAMS}
    tot = Counter()
    n = 0
    sizes = []
    files = [out / "cells" / f"{op.cell_name(ix, iy)}.bin" for ix, iy in cells]
    files = [f for f in files if f.exists()]
    n = len(files)
    with ProcessPoolExecutor(max_workers=18) as ex:
        for ctot, cst, size in ex.map(one_cell, files):
            tot.update(ctot)
            sizes.append(size)
            for s, c in cst.items():
                st[s].update(c)
    stats = json.loads((out / "stats.json").read_text())
    sizes.sort()
    res = {"area_km2": round(area), "cells_in_region": len(cells), "cells_with_data": n,
           "totals": dict(tot), "streams": {k: dict(v) for k, v in st.items() if v},
           "groups": {g: {k: sum(st[s][k] for s in ss) for k in ("raw", "br", "zstd")}
                      for g, ss in op.GROUPS.items()},
           "cell_br_median": sizes[len(sizes) // 2] if sizes else 0,
           "cell_br_max": sizes[-1] if sizes else 0,
           "t_parse_s": stats["t_parse_s"], "osm_objects": stats["osm_objects"],
           "pilot_with_height_or_ele": stats["pilot_with_height_or_ele"],
           "geom_fail": stats["geom_fail"], "grid_m": stats["grid_m"], "tol_m": stats["tol_m"]}
    res["bytes_per_km2_br"] = round(tot["all_br"] / area, 1)
    res_path.write_text(json.dumps(res, ensure_ascii=False, indent=1))
    print(json.dumps({k: v for k, v in res.items() if k not in ("osm_objects",)},
                     ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
