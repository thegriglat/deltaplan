"""Землепользование — главный объём пакета. Две быстрые проверки на выбранных ячейках:
1) доля общих вершин у соседних полигонов (верхняя оценка выигрыша топологического кодирования
   «общие рёбра хранятся один раз»);
2) тот же слой, заранее растеризованный в классы (uint8, без сглаживания) на 5 и 2 м/пикс,
   brotli q9 / zstd 19 — против вектора brotli q11.

    uv run --with skia-python --with numpy --with brotli --with zstandard python lc_check.py \
        <out_dir> <res.json> <ячейка> [<ячейка> ...]      (ячейка — имя файла без .bin)
"""
from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path

import brotli
import numpy as np
import skia
import zstandard

sys.path.insert(0, str(Path(__file__).parent))
import osmpack as op  # noqa: E402
from analyze import split  # noqa: E402
from raster import AREA_STYLE  # noqa: E402


def main():
    out, res_path, names = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3:]
    classes = json.loads((out / "classes.json").read_text())
    grid = json.loads((out / "stats.json").read_text())["grid_m"]
    res = {}
    for nm in names:
        blob = (out / "cells" / f"{nm}.bin").read_bytes()
        streams = split(blob)
        vec_br = len(brotli.compress(streams["landcover"], quality=11, lgwin=24))
        dec = op.decode_cell(blob, classes)["landcover"]
        cnt = Counter()
        total = 0
        for _, _, _, _, _, rings in dec:
            for xs, ys in rings:
                total += len(xs)
                cnt.update(zip(xs, ys))
        shared = sum(v for v in cnt.values() if v > 1)
        r = {"landcover_vec_br": vec_br, "vertices": total, "unique_vertices": len(cnt),
             "vertices_in_shared_points": shared}
        maxx = max(max(max(xs) for xs, _ in g[5]) for g in dec)
        maxy = max(max(max(ys) for _, ys in g[5]) for g in dec)
        order = sorted({g[0].rsplit(":", 1)[0] for g in dec},
                       key=lambda c: AREA_STYLE.get(c, (0,))[0])
        cid = {c: i + 1 for i, c in enumerate(order)}
        for px in (5.0, 2.0):
            w, h = int(maxx * grid / px) + 1, int(maxy * grid / px) + 1
            surf = skia.Surface(skia.ImageInfo.Make(w, h, skia.ColorType.kAlpha_8_ColorType,
                                                    skia.AlphaType.kPremul_AlphaType))
            cv = surf.getCanvas()
            cv.clear(skia.Color4f(0, 0, 0, 0))
            m = skia.Matrix.MakeAll(grid / px, 0, 0, 0, -grid / px, h, 0, 0, 1)
            paths = {}
            for name, _, _, _, _, rings in dec:
                c = name.rsplit(":", 1)[0]
                p = paths.setdefault(c, skia.Path())
                p.setFillType(skia.PathFillType.kEvenOdd)
                t = skia.Path()
                t.setFillType(skia.PathFillType.kEvenOdd)
                for xs, ys in rings:
                    t.moveTo(xs[0], ys[0])
                    for x, y in zip(xs[1:], ys[1:]):
                        t.lineTo(x, y)
                    t.close()
                p.addPath(t, m)
            for c in order:
                cv.drawPath(paths[c], skia.Paint(Color=skia.ColorSetARGB(cid[c], 0, 0, 0),
                                                 AntiAlias=False))
            a = np.ascontiguousarray(surf.makeImageSnapshot().toarray()).tobytes()
            r[f"raster{px:g}m_px"] = w * h
            r[f"raster{px:g}m_br9"] = len(brotli.compress(a, quality=9, lgwin=24))
            r[f"raster{px:g}m_zstd19"] = len(zstandard.ZstdCompressor(level=19).compress(a))
        res[nm] = r
        print(nm, r, flush=True)
    res_path.write_text(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
