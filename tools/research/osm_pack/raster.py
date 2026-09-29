"""Проверка вида и скорости растеризации пакета на CPU (skia, нижняя оценка для GPU).

    uv run --with skia-python --with numpy --with pillow python raster.py <out_dir> \
        --lat=46.29 --lon=13.88 --km=10 --px=1.0 --png=<полный.png> --prefix=<путь/имя>

Рисует квадрат km x km с шагом px м/пикс; цвет — по классу. Тоннели не рисуются, точки не рисуются
(дома/вершины/опоры — не подложка). Пишет <prefix>_full_small.jpg (уменьшенная копия),
<prefix>_crop_1m.jpg (фрагмент 1:1), <prefix>_timing.json.
"""
from __future__ import annotations

import json
import math
import sys
import time
from pathlib import Path

import numpy as np
import skia
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
import osmpack as op  # noqa: E402

Image.MAX_IMAGE_PIXELS = None

BG = (206, 214, 170)  # «нет данных» — нейтральная трава
# класс -> (порядок, цвет)
AREA_STYLE = {
    "grassland": (1, (196, 214, 150)), "meadow": (1, (184, 214, 128)), "grass": (1, (170, 208, 120)),
    "heath": (2, (190, 190, 140)), "farmland": (2, (226, 216, 150)),
    "allotments": (3, (200, 200, 140)), "orchard": (3, (160, 200, 110)),
    "vineyard": (3, (170, 190, 120)), "scrub": (4, (130, 160, 90)),
    "forest": (5, (60, 110, 50)), "wood": (5, (70, 118, 56)),
    "sand": (6, (230, 214, 170)), "shingle": (6, (200, 196, 186)), "scree": (6, (186, 182, 176)),
    "bare_rock": (7, (160, 156, 150)), "glacier": (8, (236, 244, 250)),
    "quarry": (9, (180, 170, 160)), "residential": (9, (190, 180, 176)),
    "industrial": (9, (184, 172, 190)), "wetland": (10, (120, 170, 160)),
}
WATER = (70, 120, 190)
ROAD_W = {"motorway": 22, "trunk": 16, "primary": 11, "secondary": 9, "tertiary": 7,
          "unclassified": 5, "residential": 5, "living_street": 4, "service": 3.5,
          "motorway_link": 8, "trunk_link": 7, "primary_link": 7, "secondary_link": 6,
          "tertiary_link": 5, "track": 2.5, "path": 1.0, "footway": 1.5, "cycleway": 2,
          "bridleway": 1.5, "steps": 1.5, "pedestrian": 4}
ROAD_C = {"track": (170, 150, 110), "path": (160, 140, 110), "footway": (170, 160, 140),
          "steps": (170, 160, 140), "bridleway": (160, 140, 110)}
ROAD_DEF_C = (120, 120, 118)
RIVER_W = {"river": 15, "canal": 8, "stream": 2.5, "ditch": 1.2, "drain": 1.2}


def color(c, a=255):
    return skia.Color(c[0], c[1], c[2], a)


def main():
    out = Path(sys.argv[1])
    o = dict(a[2:].split("=", 1) for a in sys.argv[2:])
    latc, lonc, km, px = float(o["lat"]), float(o["lon"]), float(o["km"]), float(o["px"])
    prefix = Path(o["prefix"])
    classes = json.loads((out / "classes.json").read_text())
    stats = json.loads((out / "stats.json").read_text())
    grid = stats["grid_m"]
    kxc = op.M_PER_DEG * math.cos(math.radians(latc))
    ky = op.M_PER_DEG
    half = km * 500.0
    lonL, lonR = lonc - half / kxc, lonc + half / kxc
    latB, latT = latc - half / ky, latc + half / ky
    npx = int(round(km * 1000 / px))
    tm = {}

    t0 = time.perf_counter()
    cells = []
    for ix in range(math.floor(lonL / op.CELL_DEG), math.floor(lonR / op.CELL_DEG) + 1):
        for iy in range(math.floor(latB / op.CELL_DEG), math.floor(latT / op.CELL_DEG) + 1):
            f = out / "cells" / f"{op.cell_name(ix, iy)}.bin"
            if f.exists():
                blob = f.read_bytes()
                cells.append((ix, iy, len(blob), op.decode_cell(blob, classes)))
    tm["decode_s"] = time.perf_counter() - t0
    tm["cells"] = [(op.cell_name(a, b), n) for a, b, n, _ in cells]

    # пути по (порядок, вид, класс/ширина) — все ячейки в одни пути, матрица на ячейку
    t0 = time.perf_counter()
    areas: dict = {}
    lines: dict = {}
    nobj = 0

    def cell_mat(ix, iy):
        lon0, lat0, kx, _ = op.cell_origin(ix, iy)
        sx = grid * (kxc / kx) / px
        sy = grid / px
        tx = (lon0 - lonL) * kxc / px
        ty = npx - (lat0 - latB) * ky / px
        return skia.Matrix.MakeAll(sx, 0, tx, 0, -sy, ty, 0, 0, 1)

    def add_ring(path, xs, ys):
        path.moveTo(xs[0], ys[0])
        for x, y in zip(xs[1:], ys[1:]):
            path.lineTo(x, y)
        path.close()

    def add_line(path, xs, ys):
        path.moveTo(xs[0], ys[0])
        for x, y in zip(xs[1:], ys[1:]):
            path.lineTo(x, y)

    for ix, iy, _, dec in cells:
        m = cell_mat(ix, iy)
        for stream, objs in dec.items():
            for name, f, w, h, nm, geom in objs:
                cls, gt = name.rsplit(":", 1)
                if gt == "point" or f & 8:  # точки и тоннели не рисуем
                    continue
                if stream == "places":
                    continue
                if gt == "area":
                    if stream == "water_areas":
                        key = (20, "water", WATER)
                    elif stream == "landcover" and cls in AREA_STYLE:
                        key = (AREA_STYLE[cls][0], cls, AREA_STYLE[cls][1])
                    else:
                        continue  # аэродромы и пр. — не подложка
                    p = areas.get(key)
                    if p is None:
                        p = areas[key] = skia.Path()
                        p.setFillType(skia.PathFillType.kEvenOdd)
                    tmp = skia.Path()
                    tmp.setFillType(skia.PathFillType.kEvenOdd)
                    for xs, ys in geom:
                        add_ring(tmp, xs, ys)
                    p.addPath(tmp, m)
                else:
                    xs, ys = geom
                    if stream in ("roads_main", "roads_tp"):
                        wd = w / 10 if w else ROAD_W.get(cls, 3)
                        key = (30 + (0 if stream == "roads_tp" else 1), "road",
                               ROAD_C.get(cls, ROAD_DEF_C), round(wd, 1))
                    elif stream == "rail":
                        key = (33, "rail", (90, 80, 80), 3.0)
                    elif stream == "water_lines":
                        wd = w / 10 if w else RIVER_W.get(cls, 2)
                        key = (25, "river", WATER, round(wd, 1))
                    elif stream == "cliffs":
                        key = (28, "cliff", (110, 100, 95), 2.0)
                    elif stream == "pilot" and cls.startswith(("power_", "aerialway_")):
                        key = (40, "wire", (40, 40, 40), 0.6)
                    else:
                        continue
                    p = lines.get(key)
                    if p is None:
                        p = lines[key] = skia.Path()
                    tmp = skia.Path()
                    add_line(tmp, xs, ys)
                    p.addPath(tmp, m)
                nobj += 1
    tm["paths_s"] = time.perf_counter() - t0
    tm["objects_drawn"] = nobj

    t0 = time.perf_counter()
    surf = skia.Surface(npx, npx)
    cv = surf.getCanvas()
    cv.clear(color(BG))
    for key in sorted(areas, key=lambda k: k[0]):
        cv.drawPath(areas[key], skia.Paint(Color=color(key[2]), AntiAlias=True))
    for key in sorted(lines, key=lambda k: k[0]):
        cv.drawPath(lines[key], skia.Paint(Color=color(key[2]), AntiAlias=True,
                                           Style=skia.Paint.kStroke_Style,
                                           StrokeWidth=key[3] / px, StrokeCap=skia.Paint.kRound_Cap,
                                           StrokeJoin=skia.Paint.kRound_Join))
    surf.flushAndSubmit()
    img = surf.makeImageSnapshot()
    arr = img.toarray()  # RGBA/BGRA по платформе
    tm["draw_s"] = time.perf_counter() - t0
    tm["npx"] = npx
    tm["px_m"] = px

    t0 = time.perf_counter()
    rgb = arr[:, :, :3]
    if img.colorType() == skia.ColorType.kBGRA_8888_ColorType:
        rgb = rgb[:, :, ::-1]
    im = Image.fromarray(np.ascontiguousarray(rgb))
    if "png" in o:
        im.save(o["png"], optimize=False)
    prefix.parent.mkdir(parents=True, exist_ok=True)
    im.resize((2000, 2000), Image.LANCZOS).save(f"{prefix}_full_small.jpg", quality=88)
    c = npx // 2
    im.crop((c - 1000, c - 1000, c + 1000, c + 1000)).save(f"{prefix}_crop_1m.jpg", quality=88)
    tm["save_s"] = time.perf_counter() - t0
    tm["bbox"] = [lonL, latB, lonR, latT]
    Path(f"{prefix}_timing.json").write_text(json.dumps(tm, ensure_ascii=False, indent=1))
    print(json.dumps(tm, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
