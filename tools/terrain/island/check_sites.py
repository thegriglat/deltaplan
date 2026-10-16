"""Старты и посадки учебного острова по готовым файлам места — правила tests/terrain/test_locations.gd:
старт — уклон 8–35°, земля в 60 м по курсу ниже > 5 м, не в лесу; посадка — уклон < 10°, не лес и не вода.
Высоты, классы и маски читаются из data/locations/training_island (как Terrain), площадки — из конфига.

  python3 tools/terrain/island/check_sites.py [--dir ПАПКА] [--config ФАЙЛ]     exit 1 — правило нарушено
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _venv  # noqa: E402

_venv.ensure("numpy", "PIL")

import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402

import sites as S  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]


def gray(path):
    a = np.array(Image.open(path))
    return a if a.ndim == 2 else a[..., 0]


def load(d):
    meta = json.loads((d / "meta.json").read_text())
    surf = json.loads((d / "surface.json").read_text())
    lay = next(x for x in meta["layers"] if x["id"] == "detail")
    rgb = np.array(Image.open(d / lay["file"]).convert("RGB")).astype(np.int64)
    v = (rgb[..., 0] << 16) | (rgb[..., 1] << 8) | rgb[..., 2]
    h = lay["height_min_m"] + v * lay["height_step_m"]
    sl = next(x for x in surf["layers"] if x["id"] == "detail")
    cls = gray(d / sl["file"])
    m = sl["detail10"]
    la = np.array(Image.open(d / m["file"]).convert("RGBA"))
    rock = float(json.loads((ROOT / "configs/world.json").read_text())["terrain_look"]["rock_slope_deg"])
    return S.Place(h, lay["origin_x_m"], lay["spacing_m"], cls, la[..., 0], la[..., 3], m["origin_x_m"],
                   m["spacing_m"], rock)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=str(ROOT / "data/locations/training_island"))
    ap.add_argument("--config", default=str(ROOT / "configs/locations/training_island.json"))
    a = ap.parse_args()
    pl = load(Path(a.dir))
    cfg = json.loads(Path(a.config).read_text())
    lat0, lon0 = cfg["center_lat"], cfg["center_lon"]
    ok = True
    print(f"{'площадка':18s} {'вид':8s} {'x, м':>8s} {'z, м':>8s} {'h, м':>7s} {'уклон°':>7s} {'h+60, м':>8s} класс итог")
    for st in cfg["start_sites"]:
        x, z = S.latlon_to_local(st["lat"], st["lon"], lat0, lon0)
        r = pl.start_checks(x, z, float(st["heading_deg"]))
        ok &= r["ok"]
        print(f"{st['id']:18s} {'старт':8s} {x:8.0f} {z:8.0f} {r['h_m']:7.1f} {r['slope_deg']:7.1f} {r['ahead60_m']:8.1f} "
              f"{r['class']:5d} {'OK' if r['ok'] else 'FAIL ' + str([k for k, v in r.items() if k.startswith('ok_') and not v])}")
    for ls in cfg.get("landing_sites", []):
        x, z = S.latlon_to_local(ls["lat"], ls["lon"], lat0, lon0)
        r = pl.landing_checks(x, z)
        ok &= r["ok"]
        print(f"{ls['id']:18s} {'посадка':8s} {x:8.0f} {z:8.0f} {r['h_m']:7.1f} {r['slope_deg']:7.1f} {'':>8s} "
              f"{r['class']:5d} {'OK' if r['ok'] else 'FAIL ' + str([k for k, v in r.items() if k.startswith('ok_') and not v])}")
    c = pl.height(0.0, 0.0)
    cc = pl.surface(0.0, 0.0)
    centre_ok = c > 0.5 and cc != S.WATER
    ok &= centre_ok
    print(f"центр (0, 0): h={c:.2f} м, класс {cc} {'OK' if centre_ok else 'FAIL (Terrain.is_sea)'}")
    print("ИТОГ:", "OK" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
