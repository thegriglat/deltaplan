"""Карта поверхности (земной покров) для встроенной локации — VR-4.

Запуск (из корня проекта, после fetch_dem.py):
    uv run --with numpy --with pillow python tools/terrain/fetch_landcover.py altai [--preview=<папка>]

Источник — ESA WorldCover 2021 v200, 10 м (COG на AWS, CC-BY 4.0). Скачиваются только нужные
тайлы 1024×1024 через HTTP range-запросы (tools/terrain/cog.py), кеш в ~/.cache/deltaplan_terrain/cog.
Для каждого узла сетки высот (те же размеры, шаг и начало, что у слоя в meta.json) берётся
самый частый класс из k×k подвыборок внутри клетки (мода) и переводится в классы игры
(configs/world.json → surface.worldcover.classes).

Результат в data/terrain/<id>/:
    <слой>_surface.png — 8 бит, градации серого: значение = класс поверхности (0 — нет данных),
                         строки с севера на юг, как у высот;
    surface.json       — описание слоёв карты и атрибуция.
Классы (scripts/terrain/surface_layer.gd): 1 лес, 2 луг/трава, 3 пашня/поля, 4 кустарник,
5 скалы/голый грунт, 6 вода, 7 застройка, 8 снег/лёд.
"""

import json
import math
import sys
import urllib.error
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from cog import Cog  # noqa: E402
from fetch_dem import EARTH_R_M, ROOT, strip_doc  # noqa: E402

ATTRIBUTION = ("© ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021) "
               "processed by ESA WorldCover consortium; CC-BY 4.0")
N_CLASSES = 9
_COGS = {}

# Цвета превью (не для игры): классы 0..8.
PREVIEW_RGB = np.array([
    [0, 0, 0], [30, 80, 30], [140, 190, 90], [220, 200, 120], [150, 140, 60],
    [150, 140, 130], [60, 110, 200], [200, 60, 60], [250, 250, 250]], np.uint8)


def wc_tile_name(lat_i: int, lon_i: int) -> str:
    return "%s%02d%s%03d" % ("N" if lat_i >= 0 else "S", abs(lat_i),
                             "E" if lon_i >= 0 else "W", abs(lon_i))


def sample_worldcover(lat: np.ndarray, lon: np.ndarray, level: int, wc: dict) -> np.ndarray:
    """Коды WorldCover (10, 20, …) в точках, 0 — нет данных."""
    out = np.zeros(lat.shape, np.uint8)
    la3 = (np.floor(lat / 3.0) * 3).astype(int)
    lo3 = (np.floor(lon / 3.0) * 3).astype(int)
    for a in np.unique(la3):
        for b in np.unique(lo3):
            m = (la3 == a) & (lo3 == b)
            if not m.any():
                continue
            url = wc["url_template"].format(tile=wc_tile_name(int(a), int(b)))
            if url not in _COGS:
                try:
                    _COGS[url] = Cog(url)
                    print(f"  {Path(url).name}: уровень {level}", flush=True)
                except urllib.error.HTTPError as e:  # нет файла (океан)
                    print("  нет тайла", url, e)
                    _COGS[url] = None
            cog = _COGS[url]
            if cog is None:
                continue
            cog.prefetch(level, lat[m], lon[m])
            out[m] = cog.sample(level, lat[m], lon[m])
    return out


def build_surface(info: dict, center_lat: float, center_lon: float, lcfg: dict,
                  wc: dict) -> np.ndarray:
    """Класс поверхности в каждом узле слоя (мода по k×k подвыборкам клетки)."""
    w, h, step = info["width"], info["height"], info["spacing_m"]
    k = int(lcfg["subsamples"])
    lut = np.zeros(256, np.uint8)
    for code, cls in wc["classes"].items():
        lut[int(code)] = int(cls)
    m_lat = EARTH_R_M * math.pi / 180.0
    m_lon = m_lat * math.cos(math.radians(center_lat))
    counts = np.zeros((N_CLASSES, h, w), np.uint16)
    offs = (np.arange(k) + 0.5) / k - 0.5
    xs = info["origin_x_m"] + np.arange(w) * step
    for j0 in range(0, h, 200):               # полосами — чтобы не держать всё в памяти
        zs = info["origin_z_m"] + np.arange(j0, min(h, j0 + 200)) * step
        X, Z = np.meshgrid(xs, zs)
        for dz in offs:
            for dx in offs:
                lat = center_lat - (Z + dz * step) / m_lat
                lon = center_lon + (X + dx * step) / m_lon
                cls = lut[sample_worldcover(lat, lon, int(lcfg["level"]), wc)]
                for c in range(N_CLASSES):
                    counts[c, j0:j0 + len(zs)] += cls == c
        print(f"  строки {j0}..{j0 + len(zs) - 1} из {h}", flush=True)
    counts[0] = counts[0] // 2  # «нет данных» проигрывает любому настоящему классу при равенстве
    return counts.argmax(axis=0).astype(np.uint8)


def main():
    from PIL import Image
    loc_id = sys.argv[1] if len(sys.argv) > 1 else "altai"
    cfg = strip_doc(json.loads((ROOT / "configs" / "locations" / f"{loc_id}.json").read_text()))
    world = strip_doc(json.loads((ROOT / "configs" / "world.json").read_text()))
    wc = world["surface"]["worldcover"]
    out_dir = ROOT / "data" / "terrain" / loc_id
    meta = json.loads((out_dir / "meta.json").read_text())
    scfg = cfg["surface"]
    out = {"_doc": "Сгенерировано tools/terrain/fetch_landcover.py — не править руками.",
           "source": "ESA WorldCover 10 m 2021 v200", "layers": [], "attribution": [ATTRIBUTION]}
    for info in meta["layers"]:
        lcfg = scfg["layers"].get(info["id"])
        if lcfg is None:
            continue
        print(f"слой {info['id']}: {info['width']}×{info['height']}, шаг {info['spacing_m']} м")
        cls = build_surface(info, meta["center_lat"], meta["center_lon"], lcfg, wc)
        name = f"{info['id']}_surface.png"
        Image.fromarray(cls, mode="L").save(out_dir / name, optimize=True)
        # Godot не импортирует файл, а кладёт в сборку как есть (читаем байты сами).
        (out_dir / (name + ".import")).write_text('[remap]\n\nimporter="keep"\n')
        frac = {str(c): round(float((cls == c).mean()), 4) for c in range(N_CLASSES)}
        out["layers"].append({
            "id": info["id"], "file": name, "width": info["width"], "height": info["height"],
            "spacing_m": info["spacing_m"], "origin_x_m": info["origin_x_m"],
            "origin_z_m": info["origin_z_m"], "class_fraction": frac})
        print(f"  {name}: {(out_dir / name).stat().st_size / 1e3:.0f} КБ, доли классов {frac}")
        for a in sys.argv:
            if a.startswith("--preview="):
                p = Path(a[10:]) / f"{loc_id}_{info['id']}_surface_preview.png"
                Image.fromarray(PREVIEW_RGB[cls]).save(p)
                print("  превью", p)
    (out_dir / "surface.json").write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n")
    print("готово:", out_dir / "surface.json")


if __name__ == "__main__":
    main()
