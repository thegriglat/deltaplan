"""Рельеф и покров Словении в компактном виде — по двум пробным квадратам 0,5°x0,5° (8 ячеек 0,25°),
с пересчётом на площадь страны (оценка). Скачивание ~90 МБ: 2 тайла Copernicus GLO-30 целиком
и окна ESA WorldCover через HTTP range (tools/terrain/cog.py).

    uv run --with numpy --with tifffile --with imagecodecs --with shapely --with brotli \
        --with zstandard python slovenia_rasters.py results/slovenia_rasters.json

Квадраты: «горы» 46,0–46,5 с. ш., 13,5–14,0 в. д. (Юлийские Альпы: Триглав, Бохинь, Соча);
«холмы» 45,5–46,0 с. ш., 14,5–15,0 в. д. (к югу от Любляны, карст и леса Кочевья).
Кодирование — terrain_cover.job_dem / job_wc (шаги 1 и 0,1 м, предсказатель, brotli/zstd).
"""
from __future__ import annotations

import json
import sys
import time
import urllib.request
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "_legacy_terrain"))
from terrain_cover import COP, CELL, cell_area_km2, job_dem, job_wc  # noqa: E402
from cog import Cog  # noqa: E402

SQUARES = {"горы": (46.0, 13.5), "холмы": (45.5, 14.5)}  # юго-западный угол, 0,5°
WC_URL = ("https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/"
          "ESA_WorldCover_10m_2021_v200_N45E012_Map.tif")
COP_URL = "https://copernicus-dem-30m.s3.amazonaws.com/{n}/{n}.tif"
SLOVENIA_KM2 = 20271  # официальная площадь


def cop_tile(la: int, lo: int) -> np.ndarray:
    import tifffile
    n = f"Copernicus_DSM_COG_10_N{la:02d}_00_E{lo:03d}_00_DEM"
    p = COP / f"{n}.tif"
    if not p.exists():
        p.parent.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(COP_URL.format(n=n), p.with_suffix(".part"))
        p.with_suffix(".part").rename(p)
    return tifffile.imread(p).astype(np.float32)


def wc_window(cog: Cog, lat0: float, lon0: float, deg: float) -> np.ndarray:
    """Окно уровня 0 (1/12000°), юго-западный угол (lat0, lon0)."""
    lv = cog.levels[0]
    tw, th = lv["tile_w"], lv["tile_h"]
    step = cog.scale[0]
    x0 = round((lon0 - cog.tie[3]) / step)
    y0 = round((cog.tie[4] - (lat0 + deg)) / step)
    n = round(deg / step)
    out = np.zeros((n, n), np.uint8)
    for ty in range(y0 // th, (y0 + n - 1) // th + 1):
        for tx in range(x0 // tw, (x0 + n - 1) // tw + 1):
            t = cog.tile(0, tx, ty)
            ya, yb = max(y0, ty * th), min(y0 + n, (ty + 1) * th)
            xa, xb = max(x0, tx * tw), min(x0 + n, (tx + 1) * tw)
            out[ya - y0:yb - y0, xa - x0:xb - x0] = t[ya - ty * th:yb - ty * th,
                                                        xa - tx * tw:xb - tx * tw]
    return out


def main():
    t0 = time.time()
    cog = Cog(WC_URL)
    res = {}
    with ProcessPoolExecutor(max_workers=16) as ex:
        futs = {}
        for name, (la0, lo0) in SQUARES.items():
            dem = cop_tile(int(la0), int(lo0))
            rows, cols = dem.shape
            ys = np.linspace(la0, la0 + 0.5, 64)
            xs = np.linspace(lo0, lo0 + 0.5, 64)
            gy, gx = np.meshgrid(ys, xs)
            cog.prefetch(0, gy.ravel(), gx.ravel(), workers=8)
            wc = wc_window(cog, la0, lo0, 0.5)
            n = wc.shape[0] // 2
            for i in range(2):
                for j in range(2):
                    lat_lo = la0 + i * CELL
                    lon_lo = lo0 + j * CELL
                    r0 = round((int(la0) + 1 - (lat_lo + CELL)) * rows)
                    c0 = round((lon_lo - int(lo0)) * cols)
                    h = np.ascontiguousarray(dem[r0:r0 + rows // 4, c0:c0 + cols // 4])
                    w = np.ascontiguousarray(wc[(1 - i) * n:(2 - i) * n, j * n:(j + 1) * n])
                    key = (name, i, j)
                    futs[key] = (ex.submit(job_dem, h), ex.submit(job_wc, w),
                                 cell_area_km2(round(lat_lo / CELL)),
                                 float(h.min()), float(h.max()),
                                 {int(k): int(v) for k, v in zip(*np.unique(w, return_counts=True))})
        for (name, i, j), (fd, fw, a, hmin, hmax, hist) in futs.items():
            d = {**fd.result(), **fw.result(), "area_km2": a, "hmin": hmin, "hmax": hmax,
                 "wc_hist": hist}
            res.setdefault(name, []).append(d)
    summ = {}
    for name, cells in res.items():
        tot = {}
        for c in cells:
            for k, v in c.items():
                if isinstance(v, (int, float)) and k not in ("hmin", "hmax"):
                    tot[k] = tot.get(k, 0) + v
        summ[name] = tot
    out = {"squares": SQUARES, "per_cell": res, "sum": summ, "slovenia_km2": SLOVENIA_KM2,
           "t_s": round(time.time() - t0, 1)}
    Path(sys.argv[1]).write_text(json.dumps(out, ensure_ascii=False, indent=1))
    for name, s in summ.items():
        print(name, {k: v for k, v in s.items() if "br" in k or k == "area_km2"})


if __name__ == "__main__":
    main()
