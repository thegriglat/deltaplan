"""Доли классов поверхности на равнине термического старта учебного острова — по готовым файлам места.
Равнина: клетки суши detail 25 м, высота 5–90 м, уклон < 6°, в радиусе 4 км от старта thermal_plain.
Печатает plain_bare_frac=… (доля класса 5, голый грунт = тёмная пашня) и долю каждого класса.

  python3 tools/terrain/island/plain_stats.py [--dir ПАПКА] [--config ФАЙЛ] [--radius_m 4000]
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _venv  # noqa: E402

_venv.ensure("numpy", "PIL")

import numpy as np  # noqa: E402

import check_sites  # noqa: E402
import sites as S  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]
NAMES = {0: "none", 1: "forest", 2: "grass", 3: "crop", 4: "shrub", 5: "bare", 6: "water"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=str(ROOT / "data/locations/training_island"))
    ap.add_argument("--config", default=str(ROOT / "configs/locations/training_island.json"))
    ap.add_argument("--radius_m", type=float, default=4000.0)
    a = ap.parse_args()
    d = Path(a.dir)
    meta = json.loads((d / "meta.json").read_text())
    surf = json.loads((d / "surface.json").read_text())
    lay = next(x for x in meta["layers"] if x["id"] == "detail")
    sl = next(x for x in surf["layers"] if x["id"] == "detail")
    from PIL import Image
    rgb = np.array(Image.open(d / lay["file"]).convert("RGB")).astype(np.int64)
    h = lay["height_min_m"] + ((rgb[..., 0] << 16) | (rgb[..., 1] << 8) | rgb[..., 2]) * lay["height_step_m"]
    cls = check_sites.gray(d / sl["file"])
    dx = lay["spacing_m"]
    ox = lay["origin_x_m"]
    gz, gx = np.gradient(h, dx)
    slope = np.degrees(np.arctan(np.hypot(gx, gz)))
    cfg = json.loads(Path(a.config).read_text())
    st = next(s for s in cfg["start_sites"] if s["id"] == "thermal_plain")
    sx, sz = S.latlon_to_local(st["lat"], st["lon"], cfg["center_lat"], cfg["center_lon"])
    ax = ox + dx * np.arange(h.shape[1])
    X, Z = np.meshgrid(ax, ax)
    m = ((X - sx) ** 2 + (Z - sz) ** 2 <= a.radius_m ** 2) & (cls != 6) & (h >= 5.0) & (h <= 90.0) & (slope < 6.0)
    n = int(m.sum())
    if n == 0:
        raise SystemExit("нет клеток равнины")
    print(f"клеток равнины: {n} (радиус {a.radius_m:.0f} м от thermal_plain {sx:.0f}, {sz:.0f})")
    for k in sorted(NAMES):
        f = float((cls[m] == k).sum()) / n
        if f > 0:
            print(f"  {k} {NAMES[k]}: {f:.3f}")
    print(f"plain_bare_frac={float((cls[m] == 5).sum()) / n:.3f}")


if __name__ == "__main__":
    main()
