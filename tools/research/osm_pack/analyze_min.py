"""Итог минимального пакета по ячейкам, пересекающим границу региона.

    python -I analyze_min.py <out_min> <граница.geojson> <results/slovenia_min.json>

Для уровней detail (0,25°) и world (1°): по потокам (каждый поток каждой ячейки сжат отдельно)
raw / zstd19 / brotli q11; целый блоб ячейки; маска озёр тремя кодировками (packbits, длины серий
varint) против вектора озёр. Итог ячейки = блоб без озёр + лучшая маска ИЛИ блоб с вектором озёр.
"""
from __future__ import annotations

import json
import math
import statistics
import sys
import time
from collections import Counter
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import brotli
import numpy as np
import shapely
import zstandard
from shapely.geometry import shape

sys.path.insert(0, str(Path(__file__).parent))
import osmpack as op  # noqa: E402
import build_min as bm  # noqa: E402  (задаёт op.STREAMS)

ZC = zstandard.ZstdCompressor(level=19)


def zs(b):
    return len(ZC.compress(b)) if b else 0


def br(b):
    return len(brotli.compress(b, quality=11, lgwin=24)) if b else 0


def split(blob):
    p = 4
    n, p = op.get_varint(blob, p)
    out = {}
    for _ in range(n):
        sid, p = op.get_varint(blob, p)
        ln, p = op.get_varint(blob, p)
        out[op.STREAMS[sid]] = blob[p:p + ln]
        p += ln
    return out


def runs_bytes(m: np.ndarray) -> bytes:
    flat = m.ravel().astype(np.int8)
    ch = np.flatnonzero(np.diff(flat)) + 1            # позиции смены значения
    bounds = np.concatenate([[0], ch, [flat.size]])
    lens = np.diff(bounds).tolist()
    if flat[0] == 1:
        lens = [0] + lens                              # серии чередуются, начиная с нулей
    b = bytearray()
    for v in lens:
        op.put_varint(b, v)
    return bytes(b)


def one(args):
    f, has_mask_dir = args
    blob = Path(f).read_bytes()
    streams = split(blob)
    row = {"raw": len(blob)}
    for s, v in streams.items():
        row[f"s_{s}_raw"] = len(v)
        row[f"s_{s}_zstd"] = zs(v)
        row[f"s_{s}_br"] = br(v)
    row["blob_zstd"] = zs(blob)
    row["blob_br"] = br(blob)
    nol = op.pack_cell(streams, skip=("lakes",))
    row["blob_nolakes_zstd"] = zs(nol)
    row["blob_nolakes_br"] = br(nol)
    mp = Path(str(f)[:-4] + ".mask")
    if mp.exists():
        d = mp.read_bytes()
        w = int.from_bytes(d[:2], "little")
        h = int.from_bytes(d[2:4], "little")
        pk = d[4:]
        m = np.unpackbits(np.frombuffer(pk, np.uint8).reshape(h, -1), axis=1)[:, :w]
        rb = runs_bytes(m)
        row.update(mask_px=int(m.sum()), mask_w=w, mask_h=h, mask_pack_raw=len(pk),
                   mask_pack_zstd=zs(pk), mask_pack_br=br(pk), mask_runs_raw=len(rb),
                   mask_runs_zstd=zs(rb), mask_runs_br=br(rb))
        row["mask_best_zstd"] = min(row["mask_pack_zstd"], row["mask_runs_zstd"])
        row["mask_best_br"] = min(row["mask_pack_br"], row["mask_runs_br"])
    return Path(f).stem, row


def region_cells(geo, deg):
    g = shape(json.loads(Path(geo).read_text())["features"][0]["geometry"])
    minx, miny, maxx, maxy = g.bounds
    cells = []
    for ix in range(math.floor(minx / deg), math.floor(maxx / deg) + 1):
        for iy in range(math.floor(miny / deg), math.floor(maxy / deg) + 1):
            if g.intersects(shapely.box(ix * deg, iy * deg, (ix + 1) * deg, (iy + 1) * deg)):
                cells.append((ix, iy))
    k = 111.195
    latc = (miny + maxy) / 2
    area = shapely.transform(g, lambda a: a * (k * math.cos(math.radians(latc)), k)).area
    return cells, area


def dist(vals):
    v = sorted(vals)
    return {"mean": round(sum(v) / len(v), 1), "median": v[len(v) // 2], "max": v[-1]}


def main():
    out, geo, res = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
    result = {}
    t0 = time.time()
    for lvl, deg in (("detail", 0.25), ("world", 1.0)):
        cells, area = region_cells(geo, deg)
        files = [out / lvl / "cells" / f"{op.cell_name(ix, iy)}.bin" for ix, iy in cells]
        have = [f for f in files if f.exists()]
        with ProcessPoolExecutor(max_workers=16) as ex:
            rows = [r for _, r in ex.map(one, [(str(f), 1) for f in have], chunksize=2)]
        n_all = len(cells)
        tot = Counter()
        for r in rows:
            tot.update({k: v for k, v in r.items() if k not in ("mask_w", "mask_h")})
        pad = n_all - len(rows)         # ячейки региона без данных = 0 байт

        def per_cell(key):
            return [r.get(key, 0) for r in rows] + [0] * pad
        streams = [s for s in bm.STREAMS]
        sres = {}
        for s in streams:
            z = per_cell(f"s_{s}_zstd")
            sres[s] = {"raw": tot[f"s_{s}_raw"], "zstd": tot[f"s_{s}_zstd"],
                       "br": tot[f"s_{s}_br"], "cells_nonempty": sum(1 for x in z if x),
                       "per_cell_zstd": dist(z)}
        mask = {k: tot[k] for k in ("mask_px", "mask_pack_raw", "mask_pack_zstd", "mask_pack_br",
                                    "mask_runs_raw", "mask_runs_zstd", "mask_runs_br",
                                    "mask_best_zstd", "mask_best_br")}
        mask["cells_with_mask"] = sum(1 for r in rows if "mask_px" in r)
        mask["per_cell_best_zstd"] = dist(per_cell("mask_best_zstd"))
        tm = [r.get("blob_nolakes_zstd", 0) + r.get("mask_best_zstd", 0) for r in rows] + [0] * pad
        tv = per_cell("blob_zstd")
        tmb = [r.get("blob_nolakes_br", 0) + r.get("mask_best_br", 0) for r in rows] + [0] * pad
        tvb = per_cell("blob_br")
        result[lvl] = {
            "cell_deg": deg, "area_km2": round(area), "cells_in_region": n_all,
            "cells_with_data": len(rows),
            "streams": sres, "lake_mask": mask,
            "total_variant_mask_zstd": sum(tm), "total_variant_vec_zstd": sum(tv),
            "total_variant_mask_br": sum(tmb), "total_variant_vec_br": sum(tvb),
            "per_cell_variant_mask_zstd": dist(tm), "per_cell_variant_vec_zstd": dist(tv),
            "per_cell_variant_mask_br": dist(tmb), "per_cell_variant_vec_br": dist(tvb),
            "blob_nolakes_zstd": tot["blob_nolakes_zstd"], "blob_zstd": tot["blob_zstd"],
            "raw_blob_total": tot["raw"],
            "bytes_per_km2_mask": round(sum(tm) / area, 1),
            "bytes_per_km2_vec": round(sum(tv) / area, 1),
        }
    result["t_analyze_s"] = round(time.time() - t0, 1)
    b = json.loads((out / "build_stats.json").read_text())
    result["build"] = b
    res.write_text(json.dumps(result, ensure_ascii=False, indent=1))
    print(json.dumps({l: {k: v for k, v in result[l].items() if k != "streams"}
                      for l in ("detail", "world")}, ensure_ascii=False, indent=1))
    for l in ("detail", "world"):
        print(l, {s: v["zstd"] for s, v in result[l]["streams"].items()})


if __name__ == "__main__":
    main()
