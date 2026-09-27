"""Реки/озёра из OSM (`data/osm/<id>.json`) → канал G маски «деталь 10 м» (T03, VR-9).

Канал R (доля леса, T02) не трогается. Пишем канал G — доля воды в клетке 10 м, тем же
антиалиасингом, что у канала R: 0..255, сглаженный край ~1 клетка (без «лесенки» и без мерцания
вдали — толщина линии не тоньше клетки маски).

Реки/ручьи/каналы (`water.rivers[].t`) — полосы вдоль ломаной, ширина по типу (тег `width` в
data/osm/<id>.json пока не пакуется fetch_osm.py — используются константы ниже):
    river 25 м, canal 6 м, stream 4 м (`WIDTH_M`).
Покрытие клетки — как в rivers.py: доля вдоль ширины линии (клетка мельче ширины — полная заливка,
клетка больше — доля по расстоянию до оси), без порога — узкие ручьи не «мерцают» при перегенерации.
Ручьи (stream, 4 м) уже клетки маски (10 м) — покрытие ≤ 0,4, ниже порога 0,5 классификации
`surface_at`/термиков (VR-4): в шейдере это только берег/затемнение полосой, не сплошная вода
(навигационные ориентиры пилота — реки и озёра, а не ручьи, VR-9). Реки и каналы шире порога
(25 м и 6 м) достаточно для surface_at = вода на оси русла.

Водоёмы (`water.lakes[]`) — полигоны `p` (внешний контур, мультиполигоны OSM собраны в кольца
tools/osm/fetch_osm.py → join_rings) с дырами-островами `h` (role=inner): заливка со
супервыборкой края (4×4) — антиалиасинг контура без «лесенки»; острова вычитаются (там суша и
лес WorldCover — иначе лес «в воде»).

Запуск (после fetch_landcover.py --only=detail10, из корня проекта):
    uv run --with numpy --with pillow python tools/terrain/osm_water.py <id> [--preview=<папка>]
"""

import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from fetch_dem import ROOT, strip_doc  # noqa: E402

WIDTH_M = {"river": 25.0, "canal": 6.0, "stream": 4.0}
DEFAULT_WIDTH_M = 4.0
LAKE_SUPERSAMPLE = 4


def river_coverage(mask: np.ndarray, info: dict, rivers: list) -> None:
    """Растеризовать реки/ручьи в mask (0..1, in-place, max с уже имеющимся)."""
    s = float(info["spacing_m"])
    w, h = int(info["width"]), int(info["height"])
    ox, oz = float(info["origin_x_m"]), float(info["origin_z_m"])
    n_segs = 0
    for river in rivers:
        p = river["p"]
        width = WIDTH_M.get(river.get("t"), DEFAULT_WIDTH_M)
        r = width / 2.0
        for k in range(0, len(p) - 2, 2):
            x0, z0, x1, z1 = p[k], p[k + 1], p[k + 2], p[k + 3]
            i0 = int(np.floor((min(x0, x1) - r - s - ox) / s))
            i1 = int(np.ceil((max(x0, x1) + r + s - ox) / s))
            j0 = int(np.floor((min(z0, z1) - r - s - oz) / s))
            j1 = int(np.ceil((max(z0, z1) + r + s - oz) / s))
            i0, j0 = max(i0, 0), max(j0, 0)
            i1, j1 = min(i1, w - 1), min(j1, h - 1)
            if i0 > i1 or j0 > j1:
                continue
            gx = ox + np.arange(i0, i1 + 1) * s
            gz = oz + np.arange(j0, j1 + 1) * s
            X, Z = np.meshgrid(gx, gz)
            dx, dz = x1 - x0, z1 - z0
            length2 = dx * dx + dz * dz
            if length2 > 0:
                t = np.clip(((X - x0) * dx + (Z - z0) * dz) / length2, 0.0, 1.0)
            else:
                t = 0.0
            d = np.hypot(X - (x0 + t * dx), Z - (z0 + t * dz))
            # клетка мельче ширины реки — полная заливка на полосе; шире — сглаженный край ~1 клетка
            cov = np.clip((r - d) / s + 0.5, 0.0, 1.0) * min(1.0, width / s)
            sub = mask[j0:j1 + 1, i0:i1 + 1]
            np.maximum(sub, cov, out=sub)
            n_segs += 1
    print(f"  реки: {n_segs} отрезков")


def lake_coverage(mask: np.ndarray, info: dict, lakes: list) -> None:
    """Растеризовать озёра (полигоны, супервыборка края) в mask (0..1, in-place, max)."""
    from PIL import Image, ImageDraw

    s = float(info["spacing_m"])
    w, h = int(info["width"]), int(info["height"])
    ox, oz = float(info["origin_x_m"]), float(info["origin_z_m"])
    ss = LAKE_SUPERSAMPLE
    n_lakes = 0
    for lake in lakes:
        p = lake["p"]
        if len(p) < 6:
            continue
        xs = p[0::2]
        zs = p[1::2]
        i0 = max(0, int(np.floor((min(xs) - ox) / s)) - 1)
        i1 = min(w - 1, int(np.ceil((max(xs) - ox) / s)) + 1)
        j0 = max(0, int(np.floor((min(zs) - oz) / s)) - 1)
        j1 = min(h - 1, int(np.ceil((max(zs) - oz) / s)) + 1)
        if i0 > i1 or j0 > j1:
            continue
        lw, lh = i1 - i0 + 1, j1 - j0 + 1
        def to_px(ring: list) -> list:
            return [(((x - ox) / s - i0) * ss, ((z - oz) / s - j0) * ss)
                    for x, z in zip(ring[0::2], ring[1::2])]

        hi = Image.new("L", (lw * ss, lh * ss), 0)
        draw = ImageDraw.Draw(hi)
        draw.polygon(to_px(p), fill=255)
        # острова (role=inner) — дыры: на них суша (и лес WorldCover), а не вода
        for hole in lake.get("h", []):
            if len(hole) >= 6:
                draw.polygon(to_px(hole), fill=0)
        lo = hi.resize((lw, lh), Image.BOX)
        cov = np.asarray(lo, dtype=np.float32) / 255.0
        sub = mask[j0:j1 + 1, i0:i1 + 1]
        np.maximum(sub, cov, out=sub)
        n_lakes += 1
    print(f"  озёра: {n_lakes} полигонов")


def main() -> None:
    from PIL import Image

    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    loc_id = args[0] if args else "altai"
    osm_path = ROOT / "data" / "osm" / f"{loc_id}.json"
    if not osm_path.exists():
        print(f"нет data/osm/{loc_id}.json — пропущено (OSM для локации не загружен)")
        return
    osm = strip_doc(json.loads(osm_path.read_text()))
    water = osm.get("water", {"rivers": [], "lakes": []})

    out_dir = ROOT / "data" / "terrain" / loc_id
    surface_json = out_dir / "surface.json"
    meta = json.loads(surface_json.read_text())
    layer = None
    for entry in meta["layers"]:
        if "detail10" in entry:
            layer = entry
            break
    if layer is None:
        print(f"нет маски «деталь 10 м» для {loc_id} — сначала fetch_landcover.py --only=detail10")
        return
    d10 = layer["detail10"]
    png_path = out_dir / d10["file"]
    img = Image.open(png_path).convert("LA")
    r = np.asarray(img, dtype=np.uint8)[:, :, 0]

    mask = np.zeros(r.shape, dtype=np.float32)
    river_coverage(mask, d10, water.get("rivers", []))
    lake_coverage(mask, d10, water.get("lakes", []))
    g = np.round(mask * 255.0).astype(np.uint8)

    Image.fromarray(np.dstack([r, g]), mode="LA").save(png_path, optimize=True)
    d10["channels"] = "R — доля леса (0..255, T02), G — доля воды (0..255, T03: реки/ручьи/каналы/озёра OSM)"
    d10["water_fraction"] = round(float((g >= 128).mean()), 4)
    surface_json.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
    print(f"  {d10['file']}: вода {d10['water_fraction']:.1%} клеток, "
          f"{png_path.stat().st_size / 1e6:.2f} МБ")

    for a in sys.argv:
        if a.startswith("--preview="):
            prev = np.dstack([r, g, np.zeros_like(r)])
            out = Path(a[10:]) / f"{loc_id}_water_preview.png"
            Image.fromarray(prev).save(out)
            print("  превью", out)


if __name__ == "__main__":
    main()
