"""Скачивание и подготовка рельефа для встроенной локации.

Запуск (из корня проекта):
    uv run --with numpy --with pillow --with tifffile --with imagecodecs \
        python tools/terrain/fetch_dem.py altai [--preview=<папка для png-отмывки>]

Читает configs/locations/<id>.json (раздел "dem"), для каждого слоя
скачивает тайлы источника (Copernicus GLO-30 или Terrarium), кеширует их в
~/.cache/deltaplan_terrain и пересэмплирует на регулярную метрическую сетку
в локальных координатах игры (X — восток, Z — юг, начало — центр локации).

Результат в data/terrain/<id>/:
    <слой>.f32.br — высоты float32 little-endian, построчно с севера на юг,
                    каждая строка с запада на восток; brotli (Godot:
                    PackedByteArray.decompress_dynamic(-1, COMPRESSION_BROTLI));
    meta.json     — размеры сеток, шаг, источник, атрибуция.

Проекция: локальная равнопромежуточная (equirectangular) вокруг центра:
    x = (lon - lon0) * cos(lat0) * R * pi/180,   z = -(lat - lat0) * R * pi/180.
Для 160 км ошибка по масштабу < 1 %, для игры несущественно. Те же формулы
в scripts/terrain/geo.gd.
"""

import io
import json
import math
import sys
import urllib.request
from pathlib import Path

import brotli
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

ROOT = Path(__file__).resolve().parents[3]
CACHE = Path.home() / ".cache" / "deltaplan_terrain"
EARTH_R_M = 6371008.8  # средний радиус Земли, м (тот же в geo.gd)

COP_URL = ("https://copernicus-dem-30m.s3.amazonaws.com/"
           "Copernicus_DSM_COG_10_{ns}{lat:02d}_00_{ew}{lon:03d}_00_DEM/"
           "Copernicus_DSM_COG_10_{ns}{lat:02d}_00_{ew}{lon:03d}_00_DEM.tif")
TERRARIUM_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"

ATTRIBUTION = {
    "copernicus": "Copernicus DEM GLO-30: produced using Copernicus WorldDEM-30 "
                  "© DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 "
                  "provided under COPERNICUS by the European Union and ESA",
    "terrarium": "Terrain Tiles (Mapzen/AWS Open Data): SRTM, GMTED2010, ETOPO1 и др.; "
                 "см. https://github.com/tilezen/joerd/blob/master/docs/attribution.md",
}


def strip_doc(d):
    """Убирает ключи-комментарии на '_'."""
    if isinstance(d, dict):
        return {k: strip_doc(v) for k, v in d.items() if not k.startswith("_")}
    if isinstance(d, list):
        return [strip_doc(v) for v in d]
    return d


def download(url: str, path: Path) -> Path:
    if path.exists() and path.stat().st_size > 0:
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    print("  скачиваю", url, flush=True)
    req = urllib.request.Request(url, headers={"User-Agent": "deltaplan-sim/0.1 terrain tool"})
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
    tmp = path.with_suffix(".part")
    tmp.write_bytes(data)
    tmp.rename(path)
    return path


def bilinear(arr: np.ndarray, fx: np.ndarray, fy: np.ndarray) -> np.ndarray:
    """Билинейная выборка arr в дробных индексах (fx — столбец, fy — строка)."""
    h, w = arr.shape
    fx = np.clip(fx, 0, w - 1.000001)
    fy = np.clip(fy, 0, h - 1.000001)
    x0 = np.floor(fx).astype(np.int64)
    y0 = np.floor(fy).astype(np.int64)
    tx = fx - x0
    ty = fy - y0
    a = arr[y0, x0]
    b = arr[y0, x0 + 1]
    c = arr[y0 + 1, x0]
    d = arr[y0 + 1, x0 + 1]
    return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty


# ---------- Copernicus GLO-30 ----------

def cop_tile(lat_i: int, lon_i: int):
    """Тайл 1°×1°, у которого юго-западный угол (lat_i, lon_i). None — море/нет тайла."""
    import tifffile
    ns = "N" if lat_i >= 0 else "S"
    ew = "E" if lon_i >= 0 else "W"
    url = COP_URL.format(ns=ns, lat=abs(lat_i), ew=ew, lon=abs(lon_i))
    path = CACHE / "copernicus" / Path(url).name
    try:
        download(url, path)
    except Exception as e:  # noqa: BLE001
        print("  нет тайла", url, e)
        return None
    return tifffile.imread(path).astype(np.float32)


def sample_copernicus(lat: np.ndarray, lon: np.ndarray) -> np.ndarray:
    """Высоты в точках (lat, lon). Сетка GLO-30 — pixel-is-point:
    центр пикселя (r, c) = (lat_i + 1 - r/rows, lon_i + c/cols)."""
    out = np.full(lat.shape, np.nan, dtype=np.float64)
    lat_is = np.floor(lat).astype(int)
    lon_is = np.floor(lon).astype(int)
    for la in np.unique(lat_is):
        for lo in np.unique(lon_is):
            mask = (lat_is == la) & (lon_is == lo)
            if not mask.any():
                continue
            t = cop_tile(int(la), int(lo))
            if t is None:
                out[mask] = 0.0
                continue
            rows, cols = t.shape
            # Добавляем строку/столбец соседнего тайла (дублируем край) для интерполяции у границы.
            t = np.pad(t, ((0, 1), (0, 1)), mode="edge")
            fy = (la + 1 - lat[mask]) * rows
            fx = (lon[mask] - lo) * cols
            out[mask] = bilinear(t, fx, fy)
    return out


# ---------- Terrarium ----------

def terrarium_tile(z: int, x: int, y: int) -> np.ndarray:
    from PIL import Image
    n = 2 ** z
    x %= n
    y = min(max(y, 0), n - 1)
    path = CACHE / "terrarium" / str(z) / str(x) / f"{y}.png"
    download(TERRARIUM_URL.format(z=z, x=x, y=y), path)
    img = np.asarray(Image.open(io.BytesIO(path.read_bytes())).convert("RGB")).astype(np.float64)
    return img[:, :, 0] * 256.0 + img[:, :, 1] + img[:, :, 2] / 256.0 - 32768.0


def sample_terrarium(lat: np.ndarray, lon: np.ndarray, z: int) -> np.ndarray:
    """Высоты в точках (lat, lon) из тайлов Terrarium уровня z (web mercator)."""
    world = 256 * 2 ** z
    gx = (lon + 180.0) / 360.0 * world - 0.5
    lat_r = np.radians(lat)
    gy = (1.0 - np.log(np.tan(lat_r) + 1.0 / np.cos(lat_r)) / math.pi) / 2.0 * world - 0.5
    tx0, tx1 = int(np.floor(gx.min() / 256)), int(np.floor(gx.max() / 256)) + 1
    ty0, ty1 = int(np.floor(gy.min() / 256)), int(np.floor(gy.max() / 256)) + 1
    mosaic = np.zeros(((ty1 - ty0 + 1) * 256, (tx1 - tx0 + 1) * 256))
    for ty in range(ty0, ty1 + 1):
        for tx in range(tx0, tx1 + 1):
            mosaic[(ty - ty0) * 256:(ty - ty0 + 1) * 256,
                   (tx - tx0) * 256:(tx - tx0 + 1) * 256] = terrarium_tile(z, tx, ty)
    return bilinear(mosaic, gx - tx0 * 256, gy - ty0 * 256)


def gaussian_blur(a: np.ndarray, sigma: float) -> np.ndarray:
    """Разделимый гауссов фильтр (без scipy), края — повтор крайних значений."""
    r = max(1, int(np.ceil(sigma * 3)))
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2)
    k /= k.sum()
    p = np.pad(a, r, mode="edge")
    tmp = sum(k[i] * p[:, i:i + a.shape[1]] for i in range(2 * r + 1))
    return sum(k[i] * tmp[i:i + a.shape[0], :] for i in range(2 * r + 1))


# ---------- сборка слоя ----------

def build_layer(center_lat: float, center_lon: float, layer: dict) -> tuple[np.ndarray, dict]:
    size_m = layer["size_km"] * 1000.0
    step = float(layer["spacing_m"])
    n = int(round(size_m / step)) + 1
    half = (n - 1) * step / 2.0
    xs = -half + np.arange(n) * step          # восток
    zs = -half + np.arange(n) * step          # юг (строка 0 — север)
    X, Z = np.meshgrid(xs, zs)
    m_per_deg_lat = EARTH_R_M * math.pi / 180.0
    m_per_deg_lon = m_per_deg_lat * math.cos(math.radians(center_lat))
    lat = center_lat - Z / m_per_deg_lat
    lon = center_lon + X / m_per_deg_lon
    src = layer["source"]
    if src == "copernicus":
        h = sample_copernicus(lat, lon)
    elif src == "terrarium":
        h = sample_terrarium(lat, lon, int(layer["zoom"]))
    else:
        raise SystemExit(f"неизвестный источник {src}")
    # Лёгкое сглаживание: в DSM (Copernicus, SRTM) есть ступеньки высотой с деревья на опушках
    # и вырубках — на них модель полёта «видела» бы обрывы, а шейдер — скалы.
    sigma = float(layer.get("smooth_sigma_cells", 0.0))
    if sigma > 0:
        h = gaussian_blur(np.nan_to_num(h, nan=0.0), sigma)
    # Квантуем до 1/32 м (3 см): младшие биты мантиссы становятся нулями,
    # и сжатие даёт файл почти в 1.5 раза лучше. На точность не влияет.
    q = float(layer.get("quantize_per_m", 32))
    h = (np.round(np.nan_to_num(h, nan=0.0) * q) / q).astype("<f4")
    info = {
        "id": layer["id"],
        "file": f"{layer['id']}.f32.br",
        "width": n,
        "height": n,
        "spacing_m": step,
        "origin_x_m": -half,
        "origin_z_m": -half,
        "min_height_m": float(h.min()),
        "max_height_m": float(h.max()),
        "source": src,
    }
    return h, info


def patch_from_finer(h: np.ndarray, info: dict, fine_h: np.ndarray, fine: dict):
    step = info["spacing_m"]
    xs = info["origin_x_m"] + np.arange(info["width"]) * step
    zs = info["origin_z_m"] + np.arange(info["height"]) * step
    f_x1 = fine["origin_x_m"] + (fine["width"] - 1) * fine["spacing_m"]
    f_z1 = fine["origin_z_m"] + (fine["height"] - 1) * fine["spacing_m"]
    ci = np.where((xs >= fine["origin_x_m"] - 1e-6) & (xs <= f_x1 + 1e-6))[0]
    ri = np.where((zs >= fine["origin_z_m"] - 1e-6) & (zs <= f_z1 + 1e-6))[0]
    if len(ci) == 0 or len(ri) == 0:
        return
    X, Z = np.meshgrid(xs[ci], zs[ri])
    fx = (X - fine["origin_x_m"]) / fine["spacing_m"]
    fz = (Z - fine["origin_z_m"]) / fine["spacing_m"]
    h[ri[0]:ri[-1] + 1, ci[0]:ci[-1] + 1] = bilinear(fine_h.astype(np.float64), fx, fz)


def main():
    loc_id = sys.argv[1] if len(sys.argv) > 1 else "altai"
    cfg = strip_doc(json.loads((ROOT / "configs" / "locations" / f"{loc_id}.json").read_text()))
    out_dir = ROOT / "data" / "terrain" / loc_id
    out_dir.mkdir(parents=True, exist_ok=True)
    meta = {
        "_doc": "Сгенерировано tools/terrain/fetch_dem.py — не править руками.",
        "location": loc_id,
        "center_lat": cfg["center_lat"],
        "center_lon": cfg["center_lon"],
        "earth_radius_m": EARTH_R_M,
        "layers": [],
        "attribution": [],
    }
    built = []  # (высоты, info) уже готовых (более детальных) слоёв
    for layer in cfg["dem"]["layers"]:
        print(f"слой {layer['id']}: {layer['size_km']} км, шаг {layer['spacing_m']} м, {layer['source']}")
        h, info = build_layer(cfg["center_lat"], cfg["center_lon"], layer)
        # Там, где есть более детальный слой, грубый слой берёт высоты из него:
        # тогда на стыке слоёв меш и height_at совпадают (узлы сеток выровнены).
        for fine_h, fine in built:
            patch_from_finer(h, info, fine_h, fine)
        built.append((h, info))
        raw = h.tobytes()
        (out_dir / info["file"]).write_bytes(brotli.compress(raw, quality=11, lgwin=22))
        meta["layers"].append(info)
        if ATTRIBUTION[layer["source"]] not in meta["attribution"]:
            meta["attribution"].append(ATTRIBUTION[layer["source"]])
        print(f"  {info['width']}x{info['height']}, высоты {info['min_height_m']:.0f}..{info['max_height_m']:.0f} м, "
              f"файл {(out_dir / info['file']).stat().st_size / 1e6:.1f} МБ")
        for a in sys.argv:
            if a.startswith("--preview="):
                save_preview(h, Path(a[10:]) / f"{loc_id}_{layer['id']}_preview.png", info["spacing_m"])
    rcfg = cfg.get("rivers")
    if rcfg:
        make_rivers(rcfg, built, out_dir)
    (out_dir / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
    print("готово:", out_dir)


def make_rivers(rcfg: dict, built: list, out_dir: Path):
    """Маски рек для всех слоёв (см. tools/terrain/rivers.py)."""
    from PIL import Image

    import rivers
    src = next((b for b in built if b[1]["id"] == rcfg["source_layer"]), built[-1])
    print(f"реки: сток по слою {src[1]['id']} …")
    segs = rivers.river_segments(src[0], src[1], rcfg, fine=built[0])
    for h, info in built:
        mask = rivers.rasterize(segs, info)
        info["water_file"] = f"{info['id']}_water.png"
        Image.fromarray(mask, mode="L").save(out_dir / info["water_file"], optimize=True)
        print(f"  маска воды {info['water_file']}: {(mask > 127).mean() * 100:.2f} % площади, "
              f"{(out_dir / info['water_file']).stat().st_size / 1e3:.0f} КБ")


def save_preview(h: np.ndarray, path: Path, step: float):
    """Отмывка рельефа (hillshade) для проверки глазами. Не для репозитория."""
    from PIL import Image
    gy, gx = np.gradient(h, step)
    # свет с северо-запада
    shade = np.clip((-gx * -0.7 + -gy * 0.7 + 1.0) / np.sqrt(gx ** 2 + gy ** 2 + 1.0), 0, 1)
    hn = (h - h.min()) / max(1.0, h.max() - h.min())
    rgb = np.stack([shade * (0.4 + 0.6 * hn), shade * (0.6 + 0.2 * hn), shade * (0.4 + 0.3 * hn)], -1)
    Image.fromarray((rgb * 255).astype(np.uint8)).save(path)
    print("  превью", path)


if __name__ == "__main__":
    main()
