"""Сборка учебного острова: генерация (island_gen.py) + упаковка места формата 4 (контракт TI-К1)
в data/locations/training_island/ и конфиг configs/locations/training_island.json со стартами и посадками.

  tools/terrain/island/.venv/bin/python tools/terrain/island/build_island.py [--out ПАПКА] [--config ФАЙЛ|-]

Детерминизм: однопоточно (переменные ниже — до импорта numpy/numba), фиксированные зёрна, JSON с sort_keys,
без времени сборки. Повтор с теми же версиями библиотек (requirements.in) даёт побитно те же файлы (verify.sh).
"""
import os

for _v in ("OMP_NUM_THREADS", "NUMBA_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ[_v] = "1"

import argparse
import json
import sys
from importlib.metadata import version
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import island_gen as g  # noqa: E402
import sites as S  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]
LOC = "training_island"
LAT0, LON0, UTC = 43.2, 34.0, 3
ROCK_SLOPE_DEG = 38.0           # configs/world.json → terrain_look.rock_slope_deg (check_sites читает из конфига)

# Старты: id → (поиск: прямоугольник x0, x1, z0, z1 м; курс или None — по экспозиции; уклон; диапазон курса)
START_SEARCH = {
    "ridge_west": dict(box=(-5600, -4400, -2000, 0), heading=270, slope=(15, 28)),
    "thermal_plain": dict(box=(-4600, -3000, 2000, 4000), heading=None, heading_range=(120, 200), slope=(15, 28)),
    "landing_hill": dict(box=(3000, 4300, -2700, -900), heading=270, slope=(11, 28)),
    "lee_bowl": dict(box=(-3600, -2600, -2300, -500), heading=270, slope=(15, 28)),
}
START_DOC = {
    "ridge_west": "Склон: верх наветренного склона хребта С–Ю над морем, разбег на запад (ветер наборов 270°)",
    "thermal_plain": "Термики: южный конец хребта над равниной с полями, голым грунтом, рощами и озером",
    "landing_hill": "Посадка: учебный холм; поле-мишень landing_target в 1–1,5 км",
    "lee_bowl": "Ротор: восточный борт чаши за главным хребтом, разбег на запад — в подветренной зоне хребта",
}
LANDINGS = {
    "landing_target": "Поле-мишень у учебного холма",
    "plain_field": "Поле на равнине у южного конца хребта",
}


def _webp(path, arr, mode):
    Image.fromarray(arr, mode).save(path, "WEBP", lossless=True, quality=100, exact=True, method=4)


def _height_webp(path, h):
    hmin = float(h.min())
    v = np.round((h - hmin) / g.H_STEP).astype(np.int64)
    assert v.max() < (1 << 24)
    rgb = np.stack([(v >> 16) & 255, (v >> 8) & 255, v & 255], -1).astype(np.uint8)
    _webp(path, rgb, "RGB")
    return hmin


def _fractions(cls):
    n = cls.size
    return {str(k): round(float(np.count_nonzero(cls == k)) / n, 4) for k in range(9)}


def _jdump(path, obj):
    Path(path).write_text(json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def find_sites(pl, land, lake):
    def forbid(x, z):
        i = int(round((x - g.D_O) / g.D_DX))
        j = int(round((z - g.D_O) / g.D_DX))
        return (not land[j, i]) or lake[j, i] or pl.height(x, z) < 2.0

    starts = {}
    for sid, kw in START_SEARCH.items():
        s = S.find_start(pl, forbid=forbid, **kw)
        if s is None:
            raise SystemExit("старт не найден: " + sid)
        starts[sid] = s
    lh = starts["landing_hill"]
    lands = {
        "landing_target": S.find_landing(pl, (lh["x"], lh["z"]), 1000.0, 1500.0, prefer_bearing=270.0, forbid=forbid),
        "plain_field": S.find_landing(pl, (-2600.0, 1500.0), 0.0, 900.0, forbid=forbid),
    }
    for k, v in lands.items():
        if v is None:
            raise SystemExit("посадка не найдена: " + k)
    return starts, lands


def config(starts, lands):
    def ll(p):
        lat, lon = S.local_to_latlon(p["x"], p["z"], LAT0, LON0)
        return round(lat, 7), round(lon, 7)

    ss = []
    for sid in START_SEARCH:
        lat, lon = ll(starts[sid])
        ss.append({"id": sid, "name": f"site_{LOC}_{sid}", "name_doc": START_DOC[sid], "lat": lat, "lon": lon,
                   "heading_deg": int(starts[sid]["heading_deg"])})
    ls = []
    for lid, name in LANDINGS.items():
        lat, lon = ll(lands[lid])
        ls.append({"id": lid, "name": name, "lat": lat, "lon": lon})
    import apply_weather   # TI-5: фиксированная погода стартов (TI-К2) — weather_sets.json
    apply_weather.add_weather(ss)
    return {
        "_doc": "Учебный остров (TI-К1): вымышленный остров ~14 × 10 км в открытом море, рельеф и карта классов — "
                "процедурно (tools/terrain/island/, не править руками: build_island.py перезаписывает файл). "
                "Хребет С–Ю на западе (склон), равнина с полями на юге/юго-востоке (термики), учебный холм с "
                "полем-мишенью (посадка), чаша за хребтом (ротор). Координаты мира: X — восток, −Z — север.",
        "name": f"loc_{LOC}",
        "center_lat": LAT0,
        "center_lon": LON0,
        "utc_offset_h": UTC,
        "bundled": True,
        "bundled_doc": "Данные места — res://data/locations/training_island/ (без сборки и сети)",
        "synthetic": True,
        "synthetic_doc": "Вымышленное место: точка с карты в него не превращается",
        "country": "",
        "start_sites": ss,
        "landing_sites": ls,
        "landing_sites_doc": "Посадочные площадки {id, name, lat, lon}; детали — configs/world_objects.json → landing.sites.training_island",
        "start_position_agl_m": 0.0,
        "start_clearing_radius_m": 70,
        "render": {
            "detail": {"chunk_cells": 160, "lod_distances_m": [1500, 3500, 7000, 14000], "skirt_depth_m": 300},
            "far": {"chunk_cells": 200, "lod_distances_m": [12000, 25000, 45000], "skirt_depth_m": 400},
        },
    }


def build(out, cfg_path):
    out.mkdir(parents=True, exist_ok=True)
    _, z100, _, _ = g.run_fs1()
    h, info = g.detail_heights(z100)
    pl = S.Place(h, g.D_O, g.D_DX)
    starts, lands = find_sites(pl, info["land"], info["lake"])
    keep = [(v["x"], v["z"], g.C["start_clear_m"], "start") for v in starts.values()]
    keep += [(v["x"], v["z"], g.C["landing_clear_m"], "landing") for v in lands.values()]
    c25, L10, A10 = g.surface_maps(h, info, keep)
    # проверка правил по готовым слоям (как check_sites.py)
    full = S.Place(h, g.D_O, g.D_DX, c25, L10, A10, g.M_O, g.M_DX, ROCK_SLOPE_DEG)
    bad = []
    for sid, s in starts.items():
        r = full.start_checks(s["x"], s["z"], s["heading_deg"])
        if not r["ok"]:
            bad.append((sid, r))
    for lid, s in lands.items():
        r = full.landing_checks(s["x"], s["z"])
        if not r["ok"]:
            bad.append((lid, r))
    if bad:
        raise SystemExit("правила площадок нарушены: %s" % bad)
    # far: море 0 м, detail вклеен (узлы far совпадают с каждым 4-м узлом detail)
    hf = np.zeros((g.F_N, g.F_N))
    cf = np.full((g.F_N, g.F_N), g.WATER, np.uint8)
    o = int(round((g.D_O - g.F_O) / g.F_DX))
    k = int(round(g.F_DX / g.D_DX))
    n = (g.D_N - 1) // k + 1
    hf[o:o + n, o:o + n] = h[::k, ::k]
    cf[o:o + n, o:o + n] = c25[::k, ::k]
    water25 = np.where(c25 == g.WATER, 255, 0).astype(np.uint8)
    waterf = np.where(cf == g.WATER, 255, 0).astype(np.uint8)
    assert np.all(h[c25 != g.WATER] > 0) and np.all(h[~info["land"]] == 0)

    layers = []
    for lid, hh, sp, org, ww in (("detail", h, g.D_DX, g.D_O, water25), ("far", hf, g.F_DX, g.F_O, waterf)):
        hmin = _height_webp(out / f"{lid}.webp", hh)
        _webp(out / f"{lid}_water.webp", ww, "L")
        layers.append({"id": lid, "file": f"{lid}.webp", "width": hh.shape[1], "height": hh.shape[0],
                       "spacing_m": sp, "origin_x_m": org, "origin_z_m": org, "source": "synthetic",
                       "water_file": f"{lid}_water.webp", "min_height_m": float(hh.min()),
                       "max_height_m": float(hh.max()), "height_min_m": hmin, "height_step_m": g.H_STEP})
    _webp(out / "detail_surface.webp", c25, "L")
    _webp(out / "far_surface.webp", cf, "L")
    _webp(out / "detail_detail10.webp", np.stack([L10, A10], -1), "LA")
    _jdump(out / "meta.json", {"location": LOC, "center_lat": LAT0, "center_lon": LON0, "earth_radius_m": S.EARTH_R,
                               "attribution": ["Synthetic terrain: Deltaplan project"], "layers": layers})
    _jdump(out / "surface.json", {
        "_doc": "Собрано tools/terrain/island/build_island.py — не править руками.",
        "attribution": ["Synthetic surface map: Deltaplan project"],
        "source": "synthetic",
        "layers": [
            {"id": "detail", "file": "detail_surface.webp", "width": g.D_N, "height": g.D_N, "origin_x_m": g.D_O,
             "origin_z_m": g.D_O, "spacing_m": g.D_DX, "class_fraction": _fractions(c25),
             "detail10": {"file": "detail_detail10.webp", "width": g.M_N, "height": g.M_N, "origin_x_m": g.M_O,
                          "origin_z_m": g.M_O, "spacing_m": g.M_DX,
                          "channels": "L — доля леса (0..255), A — вода (0..255): море и озеро, процедурно",
                          "forest_fraction": round(float(L10.mean()) / 255.0, 4),
                          "water_fraction": round(float(A10.mean()) / 255.0, 4)}},
            {"id": "far", "file": "far_surface.webp", "width": g.F_N, "height": g.F_N, "origin_x_m": g.F_O,
             "origin_z_m": g.F_O, "spacing_m": g.F_DX, "class_fraction": _fractions(cf)},
        ],
    })
    _jdump(out / "osm_tiles.json", {"tiles": []})
    _jdump(out / "build.json", {"format_version": 4, "key": LOC, "center_lat": LAT0, "center_lon": LON0,
                                "complete": True, "missing": [], "sources": ["synthetic"], "net_requests": 0})
    cfg = config(starts, lands)
    libs = {k: version(k) for k in ("numpy", "scipy", "numba", "fastscapelib", "pillow")}
    _jdump(out / "params.json", {
        "generator": "tools/terrain/island/build_island.py", "libs": libs, "P": g.P, "classes": g.C,
        "ridges": g.RIDGES, "blobs": g.BLOBS, "fs1_scale": info["scale"], "lake_level_m": info["lake_level_m"],
        "start_search": START_SEARCH,
        "starts": {k: {**v, "checks": full.start_checks(v["x"], v["z"], v["heading_deg"])} for k, v in starts.items()},
        "landings": {k: {**v, "checks": full.landing_checks(v["x"], v["z"])} for k, v in lands.items()},
    })
    if cfg_path:
        _jdump(cfg_path, cfg)
    return starts, lands


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "data/locations" / LOC))
    ap.add_argument("--config", default=str(ROOT / "configs/locations" / f"{LOC}.json"),
                    help="куда писать конфиг места; '-' — не писать")
    a = ap.parse_args()
    starts, lands = build(Path(a.out), None if a.config == "-" else Path(a.config))
    for k, v in {**starts, **lands}.items():
        print(f"{k:16s} x={v['x']:8.0f} z={v['z']:8.0f}", v.get("heading_deg", ""))


if __name__ == "__main__":
    main()
