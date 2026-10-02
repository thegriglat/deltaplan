#!/usr/bin/env python3
"""Рельефы П-2 (NN-P4, NN-16; контракт П6 v2): выбор, скачивание и нарезка реальных горных квадратов 38,4 км.

  .venv/bin/python terrain_cut.py run            # все стадии по порядку (этап n из 5), с продолжения
  .venv/bin/python terrain_cut.py screen|select|fetch|cut|figures
  .venv/bin/python terrain_cut.py status [--json]
  общие флаги: --config configs/terrain.yaml  --root КАТАЛОГ (всё в одном корне: raw/, tiles/, work/ — для тестов)

Стадии (каждая прерываема и продолжается той же командой; файлы появляются целиком: временное имя → fsync → rename):
  screen  z5 по всей суше → маска гор (размах в квадрате) → z8 тайлы под маской → признаки кандидатов сетки
  select  сетка кандидатов без перекрытия → отложенные системы → пул по слоям уклона p50 с пределом доли системы
  fetch   все тайлы z (layer_zoom игры) всех мест одним прогоном, пул потоков, кеш на диске
  cut     пул процессов: путь рельефа игры → сетка 25 м 1601² → клетки 400 м, признаки → index.csv, manifest.json
  figures гистограммы признаков пула и отложенных против Онгудая/Алтая/процедурных

Путь рельефа — как scripts/terrain/terrarium_loader.gd (_plan_layer, assemble) + height_layer.gd (sample):
уровень z = layer_zoom (zoom слоя, понижение при шаге < min_spacing_m), высота R·256 + G + B/256 − 32768,
узлы — центры пикселей web-mercator, метрическая сетка с шагом пикселя на широте центра, без сглаживания;
билинейно (как HeightLayer.sample, с обрезкой по краю) на сетку 25 м (x — восток, y — север, узел 800 — центр).
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import logging
import math
import os
import random
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import yaml

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
CONTRACT = "П6 v2"
MERCATOR_R_M = 6378137.0      # web-mercator, как MERCATOR_R_M игры
R_EARTH = 6371008.8           # сфера для расстояний (как контрактный тест)
TILE_PX = 256
N_NODES, SP, N400, DX = 1601, 25.0, 96, 400.0
STAGES = ["screen", "select", "fetch", "cut", "figures"]
ATTRIBUTION = ("Terrain Tiles (Mapzen/AWS Open Data, формат Terrarium): SRTM, GMTED2010, ETOPO1, NRCan CDEM, "
               "EU-DEM, LINZ и др.; см. https://github.com/tilezen/joerd/blob/master/docs/attribution.md")
LICENSE = ("Открытые данные; условия источников — https://github.com/tilezen/joerd/blob/master/docs/attribution.md "
           "(в т. ч. EU-DEM — атрибуция Copernicus, ArcticDEM/LINZ — CC BY)")
INDEX_COLUMNS = ["id", "lat", "lon", "system", "part", "stratum", "zoom", "src_spacing_m", "h_mean", "h_min",
                 "h_max", "relief_m", "slope_p50", "slope_p95", "tpi2k_p95", "sea_frac", "sha256"]

log = logging.getLogger("terrain")


# ───────────────────────────── окружение, пути, файлы ─────────────────────────────

class Ctx:
    def __init__(self, cfg_path: Path, root: str | None):
        self.cfg_path = cfg_path
        self.cfg = yaml.safe_load(cfg_path.read_text())
        world = json.loads((ROOT / "configs/world.json").read_text())["runtime_terrain"]
        self.rt = world
        self.layer = next(l for l in world["layers"] if l["id"] == self.cfg["source"]["layer"])
        self.url_template = os.environ.get("TERRAIN_URL_TEMPLATE") or world["url_template"]
        if root:
            r = Path(root)
            self.raw, self.out, self.work = r / "raw", r / "tiles", r / "work"
        else:
            base = Path(os.environ.get("AIR_NN_DATA") or self.cfg["data_root"])
            p = self.cfg["paths"]
            self.raw, self.out, self.work = base / p["raw"], base / p["out"], base / p["work"]
        self.tiles_dir = self.raw / "terrarium"

    def tile_path(self, z, x, y) -> Path:
        return self.tiles_dir / str(z) / str(x) / f"{y}.png"


def fsync_dir(d: Path):
    try:
        fd = os.open(d, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass


def atomic_write(path: Path, data: bytes):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}.{threading.get_ident()}")
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    fsync_dir(path.parent)


def atomic_json(path: Path, obj):
    atomic_write(path, (json.dumps(obj, ensure_ascii=False, indent=1, sort_keys=False) + "\n").encode())


def clean_tmp(d: Path):
    if d.exists():
        for p in d.rglob(".*.tmp.*"):
            try:
                p.unlink()
            except OSError:
                pass


def npz_bytes(arrays: dict) -> bytes:
    """npz без времени в zip (np.savez пишет текущую дату → не побитно): фиксированная дата, порядок ключей."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", allowZip64=True) as zf:
        for name, arr in arrays.items():
            a = io.BytesIO()
            np.lib.format.write_array(a, np.asanyarray(arr), allow_pickle=False)
            zi = zipfile.ZipInfo(name + ".npy", date_time=(1980, 1, 1, 0, 0, 0))
            zi.external_attr = 0o644 << 16
            zf.writestr(zi, a.getvalue(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)
    return buf.getvalue()


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def setup_log(ctx: Ctx, stage: str):
    d = ctx.work / "log"
    d.mkdir(parents=True, exist_ok=True)
    log.handlers.clear()
    log.setLevel(logging.INFO)
    fh = logging.FileHandler(d / f"{stage}.log")
    fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.addHandler(fh)
    return d / f"{stage}.log"


class Progress:
    """Одна обновляемая строка прогресса (в не-терминал — строка раз в 10 с)."""

    def __init__(self, total, unit):
        self.total, self.unit, self.t0, self.last = total, unit, time.time(), 0.0
        self.tty = sys.stdout.isatty()

    def __call__(self, done, extra=""):
        now = time.time()
        if not self.tty and now - self.last < 10 and done < self.total:
            return
        self.last = now
        pct = 100.0 * done / max(1, self.total)
        el = now - self.t0
        eta = el / done * (self.total - done) if done else 0
        s = (f"  {self.unit} {done}/{self.total} ({pct:.0f} %) · прошло {el:.0f} с · осталось ~{eta:.0f} с"
             f"{(' · ' + extra) if extra else ''}")
        print(("\r" + s + "   ") if self.tty else s, end="" if self.tty else "\n", flush=True)

    def end(self):
        if self.tty:
            print(flush=True)


# ───────────────────────────── геометрия игры ─────────────────────────────

def layer_zoom(lc: dict, lat: float) -> int:
    """terrarium_loader.gd layer_zoom."""
    z = int(lc["zoom"])
    min_step = float(lc.get("min_spacing_m", 0.0))
    while z > 0 and 2 * math.pi * MERCATOR_R_M * math.cos(math.radians(lat)) / float(TILE_PX << z) < min_step:
        z -= 1
    return z


def f32(v: float) -> float:
    return float(np.float32(v))


def plan_layer(lat: float, lon: float, z: int, size_m: float, chunk_cells: int) -> dict:
    """terrarium_loader.gd _plan_layer (origin — Vector2, float32 в Godot)."""
    world_px = float(TILE_PX << z)
    gx0 = (lon + 180.0) / 360.0 * world_px
    lat_r = math.radians(lat)
    gy0 = (1.0 - math.log(math.tan(lat_r) + 1.0 / math.cos(lat_r)) / math.pi) / 2.0 * world_px
    spacing = 2 * math.pi * MERCATOR_R_M * math.cos(lat_r) / world_px
    cells = int(math.ceil(size_m / spacing / chunk_cells)) * chunk_cells
    n = cells + 1
    px0 = int(math.floor(gx0)) - cells // 2
    py0 = int(math.floor(gy0)) - cells // 2
    tx0, ty0 = px0 // TILE_PX, py0 // TILE_PX
    tx1, ty1 = (px0 + n - 1) // TILE_PX, (py0 + n - 1) // TILE_PX
    tiles = [(tx, ty) for ty in range(ty0, ty1 + 1) for tx in range(tx0, tx1 + 1)]
    return dict(z=z, n=n, spacing=spacing, tiles=tiles, t0=(tx0, ty0), t1=(tx1, ty1),
                crop=(px0 - tx0 * TILE_PX, py0 - ty0 * TILE_PX),
                origin=(f32((px0 + 0.5 - gx0) * spacing), f32((py0 + 0.5 - gy0) * spacing)))


def wrap_tile(z, x, y):
    """_fetch_tile_bytes: x по модулю, y обрезкой."""
    n = 1 << z
    return z, x % n, min(max(y, 0), n - 1)


def place_plan(ctx: Ctx, lat, lon) -> dict:
    lc = ctx.layer
    z = layer_zoom(lc, lat)
    return plan_layer(lat, lon, z, float(lc["size_km"]) * 1000.0, int(lc["chunk_cells"]))


def decode_png(path: Path) -> np.ndarray:
    """PNG Terrarium → высоты float32 (256, 256), строки с севера (как Image.convert(RGB8) игры)."""
    from PIL import Image
    with Image.open(path) as im:
        a = np.asarray(im.convert("RGB"), dtype=np.float64)
    return (a[..., 0] * 256.0 + a[..., 1] + a[..., 2] / 256.0 - 32768.0).astype(np.float32)


def grid_h(ctx: Ctx, plan: dict) -> np.ndarray:
    """Мозаика → обрезка → HeightLayer → билинейно на сетку 25 м. h[j — север, i — восток], float32."""
    (tx0, ty0), (tx1, ty1) = plan["t0"], plan["t1"]
    n, z = plan["n"], plan["z"]
    mosaic = np.empty(((ty1 - ty0 + 1) * TILE_PX, (tx1 - tx0 + 1) * TILE_PX), np.float32)
    for tx, ty in plan["tiles"]:
        mosaic[(ty - ty0) * TILE_PX:(ty - ty0 + 1) * TILE_PX, (tx - tx0) * TILE_PX:(tx - tx0 + 1) * TILE_PX] = \
            decode_png(ctx.tile_path(*wrap_tile(z, tx, ty)))
    cx, cy = plan["crop"]
    H = mosaic[cy:cy + n, cx:cx + n]          # строки — к югу (+Z игры), столбцы — к востоку
    s, (ox, oz) = plan["spacing"], plan["origin"]
    inv = 1.0 / s
    xs = (np.arange(N_NODES) - (N_NODES - 1) // 2) * SP     # восток
    zs = -xs                                                 # строки сетки — к северу: z игры = −y
    fx = np.clip((xs - ox) * inv, 0.0, n - 1.0)
    fz = np.clip((zs - oz) * inv, 0.0, n - 1.0)
    i = np.minimum(fx.astype(np.int64), n - 2)
    j = np.minimum(fz.astype(np.int64), n - 2)
    tx, tz = (fx - i)[None, :], (fz - j)[:, None]
    Hd = H.astype(np.float64)
    a = Hd[j[:, None], i[None, :]]
    b = Hd[j[:, None], i[None, :] + 1]
    c = Hd[j[:, None] + 1, i[None, :]]
    d = Hd[j[:, None] + 1, i[None, :] + 1]
    top = a + (b - a) * tx                 # lerpf(a, b, tx)
    bot = c + (d - c) * tx
    return (top + (bot - top) * tz).astype(np.float32)


def block_mean_400(h: np.ndarray) -> np.ndarray:
    """= air3d/terrain.block_mean(h.astype(float64), info(x0 = y0 = −20 000, 25), −19 200, −19 200, 400, 96, 96)."""
    f = int(round(DX / SP))
    i0 = int(round((-19200.0 + 20000.0) / SP))
    blk = h.astype(np.float64)[i0:i0 + f * N400, i0:i0 + f * N400].reshape(N400, f, N400, f)
    return blk.mean(axis=(1, 3))


def features(h: np.ndarray, hc: np.ndarray) -> dict:
    """Признаки П6: по hc400 (уклон — центральными разностями без 1 клетки у края, TPI 2 км — hc − гаусс σ 2 км)."""
    from scipy.ndimage import gaussian_filter
    gy, gx = np.gradient(hc, DX)
    sl = np.hypot(gx, gy)[1:-1, 1:-1]
    tpi = (hc - gaussian_filter(hc, 2000.0 / DX, mode="nearest"))[1:-1, 1:-1]
    return dict(h_mean=float(hc.mean()), h_min=float(hc.min()), h_max=float(hc.max()),
                relief_m=float(hc.max() - hc.min()), slope_p50=float(np.percentile(sl, 50)),
                slope_p95=float(np.percentile(sl, 95)), tpi2k_p95=float(np.percentile(tpi, 95)),
                sea_frac=float((h <= 0.5).mean()))


# ───────────────────────────── загрузка тайлов ─────────────────────────────

def fetch_tiles(ctx: Ctx, tiles, unit="тайлов", throttle=0.0):
    """Скачать недостающие тайлы (z, x, y). Возвращает (скачано, байт, нет_данных[])."""
    sc = ctx.cfg["source"]
    ua = ctx.rt.get("user_agent", "deltaplan-sim")
    todo = sorted({wrap_tile(*t) for t in tiles})
    have = [t for t in todo if ctx.tile_path(*t).exists()]
    need = [t for t in todo if not ctx.tile_path(*t).exists()]
    log.info("тайлов %d: в кеше %d, скачать %d", len(todo), len(have), len(need))
    pr = Progress(len(todo), unit)
    done = [len(have)]
    nbytes = [0]
    missing = []
    lock = threading.Lock()

    def one(t):
        z, x, y = t
        url = ctx.url_template.format(z=z, x=x, y=y)
        last = None
        for k in range(int(sc["retries"]) + 1):
            try:
                if throttle:
                    time.sleep(throttle)
                req = urllib.request.Request(url, headers={"User-Agent": ua})
                with urllib.request.urlopen(req, timeout=float(sc["timeout_s"])) as r:
                    data = r.read()
                if not data:
                    raise IOError("пустой ответ")
                atomic_write(ctx.tile_path(z, x, y), data)
                return t, len(data), None
            except urllib.error.HTTPError as e:
                if e.code in (403, 404):
                    return t, 0, f"HTTP {e.code}"
                last = e
            except Exception as e:    # сеть, таймаут
                last = e
            time.sleep(float(sc["backoff_s"]) * 2 ** k)
        raise RuntimeError(f"тайл {t}: {last}")

    with ThreadPoolExecutor(max_workers=int(sc["workers"])) as ex:
        futs = [ex.submit(one, t) for t in need]
        for fu in as_completed(futs):
            t, nb, err = fu.result()
            with lock:
                done[0] += 1
                nbytes[0] += nb
                if err:
                    missing.append((t, err))
                    log.warning("нет тайла %s: %s", t, err)
            pr(done[0])
    pr(done[0])
    pr.end()
    return len(need), nbytes[0], missing


# ───────────────────────────── сетка кандидатов ─────────────────────────────

def candidate_grid(cfg) -> list[dict]:
    """Строки по широте с шагом step; в строке n = floor(360 / dlon_min) равных клеток (шов 180° без перекрытия)."""
    step = float(cfg["grid_step_km"]) * 1000.0
    lat_lo, lat_hi = cfg["screen"]["lat_range"]
    rng = np.random.default_rng(int(cfg["screen"]["grid_seed"]))
    off_lat, off_lon = rng.random(2)
    dlat = math.degrees(step / R_EARTH)
    out = []
    r = 0
    while True:
        lat = lat_lo + (off_lat + r) * dlat
        if lat > lat_hi:
            break
        dlon_min = math.degrees(step / (R_EARTH * math.cos(math.radians(lat))))
        n = int(math.floor(360.0 / dlon_min))
        dlon = 360.0 / n
        for c in range(n):
            lon = -180.0 + (off_lon + c) * dlon
            out.append(dict(cid=f"c{r:03d}_{c:04d}", lat=round(lat, 5), lon=round(lon, 5), row=r))
        r += 1
    return out


def system_of(cfg, lat, lon) -> str:
    for name, boxes in cfg["systems"].items():
        for b in boxes:
            if b[0] <= lat <= b[1] and b[2] <= lon <= b[3]:
                return name
    return "other"


def dist_km(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * R_EARTH * math.asin(min(1.0, math.sqrt(h))) / 1000.0


def overlap(a, b, side_km):
    """Квадраты перекрываются, если |Δx| < side и |Δy| < side (метрика на средней широте)."""
    dy = math.radians(a["lat"] - b["lat"]) * R_EARTH / 1000.0
    dl = (a["lon"] - b["lon"] + 180.0) % 360.0 - 180.0
    dx = math.radians(dl) * R_EARTH * math.cos(math.radians((a["lat"] + b["lat"]) / 2)) / 1000.0
    return abs(dx) < side_km and abs(dy) < side_km


def window_px(lat, lon, z, half_m):
    """Окно пикселей уровня z вокруг точки (полуразмер half_m): (gx, gy, pix0x, pix1x, pix0y, pix1y, шаг)."""
    world_px = float(TILE_PX << z)
    gx = (lon + 180.0) / 360.0 * world_px
    lat_r = math.radians(lat)
    gy = (1.0 - math.log(math.tan(lat_r) + 1.0 / math.cos(lat_r)) / math.pi) / 2.0 * world_px
    s = 2 * math.pi * MERCATOR_R_M * math.cos(lat_r) / world_px
    hp = half_m / s
    return (int(math.floor(gx - hp)), int(math.ceil(gx + hp)), int(math.floor(gy - hp)), int(math.ceil(gy + hp)), s)


class TileCache:
    def __init__(self, ctx, z, cap=3000):
        self.ctx, self.z, self.cap, self.d = ctx, z, cap, {}

    def get(self, x, y):
        k = wrap_tile(self.z, x, y)
        a = self.d.get(k)
        if a is None:
            p = self.ctx.tile_path(*k)
            a = decode_png(p) if p.exists() else None
            if len(self.d) >= self.cap:
                self.d.pop(next(iter(self.d)))
            self.d[k] = a
        return a

    def window(self, x0, x1, y0, y1):
        tx0, tx1, ty0, ty1 = x0 // TILE_PX, x1 // TILE_PX, y0 // TILE_PX, y1 // TILE_PX
        m = np.empty(((ty1 - ty0 + 1) * TILE_PX, (tx1 - tx0 + 1) * TILE_PX), np.float32)
        for ty in range(ty0, ty1 + 1):
            for tx in range(tx0, tx1 + 1):
                a = self.get(tx, ty)
                if a is None:
                    return None
                m[(ty - ty0) * TILE_PX:(ty - ty0 + 1) * TILE_PX, (tx - tx0) * TILE_PX:(tx - tx0 + 1) * TILE_PX] = a
        return m[y0 - ty0 * TILE_PX:y1 - ty0 * TILE_PX + 1, x0 - tx0 * TILE_PX:x1 - tx0 * TILE_PX + 1]


def win_tiles(lat, lon, z, half_m):
    x0, x1, y0, y1, _ = window_px(lat, lon, z, half_m)
    return [(z, tx, ty) for ty in range(y0 // TILE_PX, y1 // TILE_PX + 1) for tx in range(x0 // TILE_PX, x1 // TILE_PX + 1)]


# ───────────────────────────── стадии ─────────────────────────────

def stage_screen(ctx: Ctx, a):
    cfg, sc = ctx.cfg, ctx.cfg["screen"]
    out = ctx.work / "screen.json"
    if out.exists():
        print("  экран уже готов:", out)
        return
    t0 = time.time()
    half = float(cfg["square_km"]) * 500.0
    cands = candidate_grid(cfg)
    z5, z8 = int(sc["z_mask"]), int(sc["z_cand"])
    # z5 — весь мир в пределах широт
    t5 = sorted({t for c in cands for t in win_tiles(c["lat"], c["lon"], z5, half)})
    print(f"  кандидатов сетки {len(cands)}; z{z5}: тайлов {len(t5)}")
    fetch_tiles(ctx, t5, unit=f"z{z5}")
    tc5 = TileCache(ctx, z5)
    mask = []
    for c in cands:
        x0, x1, y0, y1, _ = window_px(c["lat"], c["lon"], z5, half)
        w = tc5.window(x0, x1, y0, y1)
        c["z5_relief"] = float(w.max() - w.min())
        c["z5_sea"] = float((w <= 0.5).mean())
        if c["z5_relief"] >= sc["mask_relief_min_m"] and c["z5_sea"] <= sc["mask_sea_max"]:
            mask.append(c)
    log.info("маска z5: %d из %d", len(mask), len(cands))
    t8 = sorted({t for c in mask for t in win_tiles(c["lat"], c["lon"], z8, half)})
    print(f"  маска гор z{z5}: {len(mask)} из {len(cands)}; z{z8}: тайлов {len(t8)}")
    fetch_tiles(ctx, t8, unit=f"z{z8}")
    tc8 = TileCache(ctx, z8)
    pr = Progress(len(mask), "признаки z8")
    for k, c in enumerate(sorted(mask, key=lambda c: (c["row"], c["lon"]))):
        x0, x1, y0, y1, s = window_px(c["lat"], c["lon"], z8, half)
        w = tc8.window(x0, x1, y0, y1)
        if w is None:
            c["z8"] = None
            continue
        gy, gx = np.gradient(w.astype(np.float64), s)
        sl = np.hypot(gx, gy)[1:-1, 1:-1]
        c["z8"] = dict(relief=float(w.max() - w.min()), slope_p50=float(np.percentile(sl, 50)),
                       slope_p95=float(np.percentile(sl, 95)), sea=float((w <= 0.5).mean()),
                       h_mean=float(w.mean()), spacing=s)
        pr(k + 1)
    pr.end()
    dt = time.time() - t0
    atomic_json(out, dict(n_grid=len(cands), n_mask=len(mask), z_mask=z5, z_cand=z8, tiles_z5=len(t5),
                          tiles_z8=len(t8), time_s=dt, candidates=mask))
    log.info("экран: %.0f с", dt)
    print(f"  экран готов за {dt:.0f} с: {out}")


def stage_select(ctx: Ctx, a):
    cfg, sel = ctx.cfg, ctx.cfg["select"]
    out = ctx.work / "select.json"
    if out.exists():
        print("  выбор уже готов:", out)
        return
    t0 = time.time()
    if cfg.get("explicit"):      # явный список мест (тесты): без экрана
        places = [dict(sid=f"e{k:03d}", lat=p["lat"], lon=p["lon"], system=p.get("system", "other"),
                       part=p.get("part", "pool"), sel_stratum=p.get("stratum", "explicit"), rank=k)
                  for k, p in enumerate(cfg["explicit"])]
        atomic_json(out, dict(explicit=True, places=places, targets={}, rejected={}, time_s=0.0))
        print(f"  выбор (явный список): {len(places)} мест")
        return
    scr = json.loads((ctx.work / "screen.json").read_text())
    rng = random.Random(int(sel["seed"]))
    edges = [float(e) for e in sel["strata"]]
    labels = [f"s{k}_{edges[k]:.2f}-{edges[k + 1]:.2f}".replace("-inf", "-inf") for k in range(len(edges) - 1)]
    k_slope = float(sel["slope_est_scale"])
    rej = dict(no_data=0, sea=0, relief_low=0, relief_high=0, exclude=0, holdout_zone=0)
    good = []
    excl = []
    for e in sel.get("exclude", []):
        if "location" in e:
            j = json.loads((ROOT / f"configs/locations/{e['location']}.json").read_text())
            excl.append(((j["center_lat"], j["center_lon"]), float(e["km"])))
        else:
            excl.append(((e["lat"], e["lon"]), float(e["km"])))
    for c in scr["candidates"]:
        f = c.get("z8")
        if f is None:
            rej["no_data"] += 1
            continue
        if f["sea"] > sel["sea_max"]:
            rej["sea"] += 1
            continue
        if f["relief"] < sel["relief_min_m"]:
            rej["relief_low"] += 1
            continue
        if f["relief"] > sel["relief_max_est_m"]:
            rej["relief_high"] += 1
            continue
        c = dict(c)
        c["system"] = system_of(cfg, c["lat"], c["lon"])
        c["slope_est"] = f["slope_p50"] * k_slope
        c["relief_est"] = f["relief"]
        good.append(c)
    # отложенные системы: по per_system + reserve мест, равномерно по уклону внутри системы
    ho = sel["holdout"]
    hold = []
    for sysname in ho["systems"]:
        smin = float((ho.get("slope_est_min") or {}).get(sysname, 0.0))   # крутая система: нижняя граница оценки уклона
        cs = sorted([c for c in good if c["system"] == sysname and c["slope_est"] >= smin],
                    key=lambda c: (c["slope_est"], c["cid"]))
        m = min(len(cs), int(ho["per_system"]) + int(ho["reserve"]))
        idx = sorted({int(round(q)) for q in np.linspace(0, len(cs) - 1, m)}) if m else []
        pick = [cs[i] for i in idx]
        rng.shuffle(pick)
        for r, c in enumerate(pick):
            hold.append(dict(c, part="holdout", sel_stratum=sysname, rank=r))
    hold_pts = [(c["lat"], c["lon"]) for c in hold]
    # пул: вне систем отложенных, дальше pool_min_km от отложенных, дальше exclude-точек
    cand = []
    for c in good:
        if c["system"] in ho["systems"] or any(dist_km((c["lat"], c["lon"]), p) < float(ho["pool_min_km"]) + 1.0
                                               for p in hold_pts):
            rej["holdout_zone"] += 1
            continue
        if any(dist_km((c["lat"], c["lon"]), p) < km for p, km in excl):
            rej["exclude"] += 1
            continue
        cand.append(c)
    by = {lab: [] for lab in labels}
    for c in cand:
        for k, lab in enumerate(labels):
            if edges[k] <= c["slope_est"] < edges[k + 1]:
                by[lab].append(c)
    per = int(sel["per_stratum"])
    n_pool_target = per * len(labels)
    cap = {s: int(math.floor(sel["system_cap"] * n_pool_target)) for s in cfg["systems"]}
    cap["other"] = int(math.floor(sel["other_cap"] * n_pool_target))
    used = {s: 0 for s in cap}
    rbins = [float(x) for x in sel["relief_bins"]]
    targets, avail = {}, {}
    pool = []
    carry = 0
    for lab in reversed(labels):        # с крутого: его кандидатов меньше, нехватка уходит в соседний положе
        tgt = per + carry
        want = int(math.ceil(tgt * (1.0 + float(sel["reserve"]))))
        bins = [[c for c in by[lab] if rbins[b] <= c["relief_est"] < rbins[b + 1]] for b in range(len(rbins) - 1)]
        for b in bins:
            b.sort(key=lambda c: c["cid"])
            rng.shuffle(b)
        picked = []
        while len(picked) < want and any(bins):
            for b in bins:
                while b:
                    c = b.pop(0)
                    if used[c["system"]] < cap[c["system"]]:
                        used[c["system"]] += 1
                        picked.append(c)
                        break
                if len(picked) >= want:
                    break
        avail[lab] = len(by[lab])
        n_ok = min(tgt, int(math.floor(len(picked) / (1.0 + float(sel["reserve"])))) if len(picked) < want else tgt)
        targets[lab] = n_ok
        carry = tgt - n_ok
        for r, c in enumerate(picked):
            pool.append(dict(c, part="pool", sel_stratum=lab, rank=r))
    if carry:
        log.warning("нехватка %d мест после всех слоёв", carry)
    for s in ho["systems"]:
        targets[s] = int(ho["per_system"])
    allp = pool + hold
    for k, p in enumerate(allp):     # проверка: квадраты не перекрываются (сетка — по построению)
        for q in allp[k + 1:]:
            assert not overlap(p, q, float(cfg["square_km"])), (p["cid"], q["cid"])
    keep = ("cid", "lat", "lon", "system", "part", "sel_stratum", "rank", "slope_est", "relief_est", "z8")
    places = [{("sid" if k == "cid" else k): p[k] for k in keep} for p in allp]
    dt = time.time() - t0
    atomic_json(out, dict(explicit=False, seed=sel["seed"], labels=labels, targets=targets, available=avail,
                          n_candidates=len(good), n_pool_candidates=len(cand), rejected=rej,
                          system_used=used, system_cap=cap, carry_short=carry, time_s=dt, places=places))
    print(f"  выбор готов: пул {len(pool)} (цель {sum(targets[l] for l in labels)}), "
          f"отложено {len(hold)}; кандидатов {len(good)}; файл {out}")
    for lab in labels:
        print(f"    {lab}: кандидатов {avail[lab]}, цель {targets[lab]}")


def all_places(ctx: Ctx):
    s = json.loads((ctx.work / "select.json").read_text())
    pl = list(s["places"])
    for name in ctx.cfg.get("ref_cuts") or []:
        j = json.loads((ROOT / f"configs/locations/{name}.json").read_text())
        pl.append(dict(sid=f"ref_{name}", lat=j["center_lat"], lon=j["center_lon"], system="ref", part="ref",
                       sel_stratum="ref", rank=0))
    return s, pl


def place_tiles(ctx, p):
    pl = place_plan(ctx, p["lat"], p["lon"])
    return [wrap_tile(pl["z"], tx, ty) for tx, ty in pl["tiles"]]


def stage_fetch(ctx: Ctx, a):
    _, pl = all_places(ctx)
    clean_tmp(ctx.tiles_dir)
    t0 = time.time()
    tiles = sorted({t for p in pl for t in place_tiles(ctx, p)})
    print(f"  мест {len(pl)}, тайлов {len(tiles)}")
    n, nb, missing = fetch_tiles(ctx, tiles, unit="тайлов", throttle=a.throttle)
    dt = time.time() - t0
    man = ctx.raw / "manifest.json"
    atomic_json(man, dict(source="AWS Terrain Tiles (Terrarium)", url_template=ctx.url_template,
                          layout="terrarium/<z>/<x>/<y>.png (как кеш игры user://terrain_cache)",
                          attribution=ATTRIBUTION, license=LICENSE,
                          updated=datetime.now(timezone.utc).isoformat(timespec="seconds")))
    st = dict(n_tiles=len(tiles), downloaded=n, bytes_downloaded=nb, missing=[list(t) + [e] for t, e in missing],
              time_s=dt)
    atomic_json(ctx.work / "fetch.json", st)
    log.info("fetch: %s", st)
    print(f"  загрузка: тайлов {len(tiles)}, скачано {n} ({nb / 1e6:.0f} МБ) за {dt:.0f} с; нет данных {len(missing)}")


def _cut_one(args):
    cfg_path, root, p = args
    ctx = Ctx(Path(cfg_path), root)
    d = ctx.work / "cut_all"
    fz, fj = d / f"{p['sid']}.npz", d / f"{p['sid']}.json"
    if fz.exists() and fj.exists():
        return p["sid"], "skip"
    plan = place_plan(ctx, p["lat"], p["lon"])
    tiles = [list(wrap_tile(plan["z"], tx, ty)) for tx, ty in plan["tiles"]]
    for t in tiles:
        if not ctx.tile_path(*t).exists():
            atomic_json(fj, dict(sid=p["sid"], error=f"нет тайла {t}"))
            return p["sid"], "nodata"
    h = grid_h(ctx, plan)
    hc = block_mean_400(h)
    assert np.isfinite(h).all() and np.isfinite(hc).all()
    meta = dict(contract=CONTRACT, lat=p["lat"], lon=p["lon"], zoom=plan["z"], src_spacing_m=plan["spacing"],
                n_src=plan["n"], origin_m=list(plan["origin"]), tiles=tiles, grid="1601×1601 по 25 м, узел 800 — центр, "
                "оси [j — север, i — восток]", source="AWS Terrain Tiles (Terrarium)")
    data = npz_bytes({"h": h, "hc400": hc, "meta": np.array(json.dumps(meta, ensure_ascii=False))})
    atomic_write(fz, data)
    f = features(h, hc)
    f.update(sid=p["sid"], zoom=plan["z"], src_spacing_m=plan["spacing"], sha256=hashlib.sha256(data).hexdigest(),
             bytes=len(data))
    atomic_json(fj, f)
    return p["sid"], "ok"


def stratum_of(edges, v):
    for k in range(len(edges) - 1):
        if edges[k] <= v < edges[k + 1]:
            return f"s{k}_{edges[k]:.2f}-{edges[k + 1]:.2f}"
    return "none"


def stage_cut(ctx: Ctx, a):
    import multiprocessing as mp
    s, pl = all_places(ctx)
    d = ctx.work / "cut_all"
    d.mkdir(parents=True, exist_ok=True)
    clean_tmp(d)
    t0 = time.time()
    jobs = [(str(ctx.cfg_path), a.root, p) for p in pl]
    pr = Progress(len(jobs), "вырезок")
    nproc = a.workers or min(16, os.cpu_count() or 4)
    res = {}
    with mp.get_context("spawn").Pool(nproc) as pool:
        for k, (sid, st) in enumerate(pool.imap_unordered(_cut_one, jobs)):
            res[sid] = st
            pr(k + 1)
    pr.end()
    dt_cut = time.time() - t0
    log.info("вырезки: %s за %.0f с", {v: sum(1 for x in res.values() if x == v) for v in set(res.values())}, dt_cut)
    finalize(ctx, a, s, pl, dt_cut)


def finalize(ctx: Ctx, a, s, pl, dt_cut):
    """Отбор по точным признакам (цели слоёв выбора, запас) → cut/<id>.npz (жёсткие ссылки), index.csv, manifest."""
    sel, d = ctx.cfg["select"], ctx.work / "cut_all"
    edges = [float(e) for e in sel["strata"]]
    feats = {p["sid"]: json.loads((d / f"{p['sid']}.json").read_text()) for p in pl}
    rej = dict(nodata=0, relief_high=0, sea=0, reserve_unused=0)
    chosen = []
    groups = {}
    for p in pl:
        if p["part"] == "ref":
            continue
        groups.setdefault((p["part"], p["sel_stratum"]), []).append(p)
    order = sorted(groups, key=lambda k: (k[0] != "pool", k[1]))
    for key in order:
        ps = sorted(groups[key], key=lambda p: p["rank"])
        tgt = s["targets"].get(key[1], len(ps))
        n = 0
        for p in ps:
            f = feats[p["sid"]]
            if "error" in f:
                rej["nodata"] += 1
                continue
            if f["relief_m"] > float(sel["relief_max_m"]):
                rej["relief_high"] += 1
                continue
            if f["sea_frac"] > float(sel["sea_max"]):
                rej["sea"] += 1
                continue
            if n >= tgt:
                rej["reserve_unused"] += 1
                continue
            n += 1
            chosen.append(p)
    out = ctx.out
    if (out / "manifest.json").exists():
        old = json.loads((out / "manifest.json").read_text())
        if old.get("complete"):
            print("  tiles уже complete — не перезаписываю (перенарезка — новый каталог или событие в журнале)")
            return
    (out / "cut").mkdir(parents=True, exist_ok=True)
    clean_tmp(out)
    rows = []
    for k, p in enumerate(chosen):
        tid = f"t_{k:04d}"
        f = feats[p["sid"]]
        dst = out / "cut" / f"{tid}.npz"
        src = d / f"{p['sid']}.npz"
        if not dst.exists() or sha256_file(dst) != f["sha256"]:
            tmp = dst.with_name(f".{dst.name}.tmp.{os.getpid()}")
            if tmp.exists():
                tmp.unlink()
            try:
                os.link(src, tmp)
            except OSError:
                atomic_write(tmp, src.read_bytes())
            os.replace(tmp, dst)
        stratum = stratum_of(edges, f["slope_p50"])   # метка — по точному уклону (цели выбора — по оценке z8)
        rows.append(dict(id=tid, lat=repr(float(p["lat"])), lon=repr(float(p["lon"])), system=p["system"],
                         part=p["part"], stratum=stratum, zoom=f["zoom"], src_spacing_m=repr(f["src_spacing_m"]),
                         **{k: repr(f[k]) for k in ("h_mean", "h_min", "h_max", "relief_m", "slope_p50",
                                                   "slope_p95", "tpi2k_p95", "sea_frac")},
                         sha256=f["sha256"]))
    for extra in (out / "cut").glob("t_*.npz"):
        if extra.stem not in {r["id"] for r in rows}:
            extra.unlink()
    fsync_dir(out / "cut")
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=INDEX_COLUMNS, lineterminator="\n")
    w.writeheader()
    for r in rows:
        w.writerow(r)
    atomic_write(out / "index.csv", buf.getvalue().encode())
    sid_of = {f"t_{k:04d}": p["sid"] for k, p in enumerate(chosen)}
    atomic_json(out / "sources.json", sid_of)

    def cnt(key):
        c = {}
        for r in rows:
            c.setdefault(r["part"], {}).setdefault(r[key], 0)
            c[r["part"]][r[key]] += 1
        return c
    try:
        commit = subprocess.run(["git", "-C", str(HERE), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        dirty = bool(subprocess.run(["git", "-C", str(HERE), "status", "--porcelain", "--", "terrain_cut.py",
                                     "configs/terrain.yaml"], capture_output=True, text=True).stdout.strip())
    except OSError:
        commit, dirty = "", True
    cut_bytes = sum((out / "cut" / f"{r['id']}.npz").stat().st_size for r in rows)
    man = dict(contract=CONTRACT, complete=False,
               command="terrain_cut.py " + " ".join(sys.argv[1:]), commit=commit, code_dirty=dirty,
               config_file=str(ctx.cfg_path), config_sha256=hashlib.sha256(ctx.cfg_path.read_bytes()).hexdigest(),
               config=ctx.cfg, seeds=dict(grid=ctx.cfg["screen"]["grid_seed"], select=sel["seed"]),
               terrain_path=dict(game="scripts/terrain/terrarium_loader.gd + configs/world.json runtime_terrain",
                                 layer=ctx.layer, url_template=ctx.url_template, smoothing="нет",
                                 grid="билинейно (HeightLayer.sample) на 1601×1601 по 25 м → hc400 = блочное среднее 16×16"),
               source="AWS Terrain Tiles (Terrarium)", attribution=ATTRIBUTION, license=LICENSE,
               n_places=len(rows), counts=dict(part={pt: sum(1 for r in rows if r["part"] == pt) for pt in ("pool", "holdout")},
                                               stratum=cnt("stratum"), system=cnt("system")),
               selection=dict(targets=s.get("targets"), rejected_select=s.get("rejected"), rejected_cut=rej,
                              available=s.get("available")),
               sizes=dict(h=[N_NODES, N_NODES], hc400=[N400, N400], spacing_m=SP, cell_m=DX, cut_bytes=cut_bytes),
               time_s=dict(cut=dt_cut),
               date=datetime.now(timezone.utc).isoformat(timespec="seconds"))
    atomic_json(out / "manifest.json", man)
    print(f"  вырезки: мест {len(rows)} (пул {man['counts']['part']['pool']}, отложено {man['counts']['part']['holdout']}),"
          f" отсеяно {rej}; {cut_bytes / 1e9:.2f} ГБ")


def ref_features(ctx: Ctx):
    """Признаки сравнения тем же определением: встроенные места (Copernicus, слой detail), процедурные p_000…p_039,
    справочные вырезки Terrarium (ref_*)."""
    p = ctx.work / "refs.json"
    if p.exists():
        return json.loads(p.read_text())
    sys.path.insert(0, str(HERE))
    import places as PL
    import procedural as PR
    PR.configure(yaml.safe_load((HERE / "configs/dataset.yaml").read_text())["plan"]["proc_seed"])  # как набор main
    out = {}
    names = ["ongudai", "altai", "aushkul", "askarovo"] + [f"p_{k:03d}" for k in range(40)]
    for n in names:
        L = PL.location(n)
        h = np.asarray(L.h, np.float64)
        out[n] = features(h, block_mean_400(h))
    for f in (ctx.work / "cut_all").glob("ref_*.json"):
        out[f.stem + "_terrarium"] = {k: v for k, v in json.loads(f.read_text()).items() if k in
                                      ("h_mean", "h_min", "h_max", "relief_m", "slope_p50", "slope_p95", "tpi2k_p95", "sea_frac")}
    atomic_json(p, out)
    return out


def write_system_table(figd: Path, pool, hold, proc, refs):
    """Таблица признаков по системам (отложенные), пулу, процедурным и Онгудаю → systems_table.json/.md."""
    def agg(rs, label):
        g = lambda k: np.array([float(r[k]) for r in rs])
        return dict(group=label, n=len(rs), slope_p50_med=float(np.median(g("slope_p50"))),
                    slope_p50_min=float(g("slope_p50").min()), slope_p50_max=float(g("slope_p50").max()),
                    slope_p95_med=float(np.median(g("slope_p95"))), relief_med=float(np.median(g("relief_m"))),
                    relief_min=float(g("relief_m").min()), relief_max=float(g("relief_m").max()))
    rows = [agg(pool, "пул")] + [agg([r for r in hold if r["system"] == s_], f"отложено: {s_}")
                                 for s_ in sorted({r["system"] for r in hold})]
    rows.append(agg(proc and [{k: str(v) for k, v in p.items()} for p in proc], "процедурные p_*"))
    og = refs["ongudai"]
    rows.append(dict(group="Онгудай", n=1, slope_p50_med=og["slope_p50"], slope_p50_min=og["slope_p50"],
                     slope_p50_max=og["slope_p50"], slope_p95_med=og["slope_p95"], relief_med=og["relief_m"],
                     relief_min=og["relief_m"], relief_max=og["relief_m"]))
    atomic_json(figd / "systems_table.json", rows)
    md = ["| группа | мест | уклон p50 (мед; min–max) | уклон p95 (мед) | размах, м (мед; min–max) |", "|---|---|---|---|---|"]
    for r in rows:
        md.append(f"| {r['group']} | {r['n']} | {r['slope_p50_med']:.3f}; {r['slope_p50_min']:.3f}–{r['slope_p50_max']:.3f} | "
                  f"{r['slope_p95_med']:.3f} | {r['relief_med']:.0f}; {r['relief_min']:.0f}–{r['relief_max']:.0f} |")
    atomic_write(figd / "systems_table.md", ("\n".join(md) + "\n").encode())


def stage_figures(ctx: Ctx, a):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    out = ctx.out
    man_p = out / "manifest.json"
    if not man_p.exists():
        raise SystemExit("нет manifest.json — сначала cut")
    man = json.loads(man_p.read_text())
    rows = list(csv.DictReader(open(out / "index.csv")))
    refs = ref_features(ctx)
    figd = out / "figures"
    figd.mkdir(parents=True, exist_ok=True)
    proc = [refs[k] for k in refs if k.startswith("p_")]
    pool = [r for r in rows if r["part"] == "pool"]
    hold = [r for r in rows if r["part"] == "holdout"]
    marks = [("ongudai", "Онгудай", "#d62728"), ("altai", "Алтай", "#9467bd")]
    hsys = sorted({r["system"] for r in hold})
    write_system_table(figd, pool, hold, proc, refs)
    for key, xl, fn, bins in [("slope_p50", "уклон p50 по клеткам 400 м, м/м", "hist_slope_p50.png", np.linspace(0, 0.7, 36)),
                              ("relief_m", "размах hc400, м", "hist_relief.png", np.linspace(0, 3000, 31)),
                              ("slope_p95", "уклон p95 по клеткам 400 м, м/м", "hist_slope_p95.png", np.linspace(0, 1.2, 37))]:
        fig, ax = plt.subplots(figsize=(7.5, 4.2))
        ax.hist([float(r[key]) for r in pool], bins=bins, alpha=0.75, label=f"пул ({len(pool)})", color="#1f77b4")
        for sname, col in zip(hsys, ("#ff7f0e", "#2ca02c", "#17becf", "#e377c2", "#bcbd22")):
            hh = [float(r[key]) for r in hold if r["system"] == sname]
            ax.hist(hh, bins=bins, alpha=0.55, label=f"отложенные: {sname} ({len(hh)})", color=col)
        ax.hist([p[key] for p in proc], bins=bins, alpha=0.6, label=f"процедурные ({len(proc)})", color="#7f7f7f",
                histtype="step", linewidth=2)
        for n, lab, col in marks:
            ax.axvline(refs[n][key], color=col, linewidth=2, label=f"{lab} {refs[n][key]:.3g}")
        ax.set_xlabel(xl)
        ax.set_ylabel("мест")
        ax.legend(fontsize=8)
        ax.set_title(f"Рельефы П-2 ({CONTRACT}): {key}")
        fig.tight_layout()
        fig.savefig(figd / fn, dpi=110)
        plt.close(fig)
    # уклон × размах
    fig, ax = plt.subplots(figsize=(7.5, 5))
    ax.scatter([float(r["relief_m"]) for r in pool], [float(r["slope_p50"]) for r in pool], s=10, label="пул")
    for sname, m in zip(hsys, "^sDvP"):
        hh = [r for r in hold if r["system"] == sname]
        ax.scatter([float(r["relief_m"]) for r in hh], [float(r["slope_p50"]) for r in hh], s=22, marker=m,
                   label=f"отложенные: {sname}")
    ax.scatter([p["relief_m"] for p in proc], [p["slope_p50"] for p in proc], s=10, c="#7f7f7f", marker="x",
               label="процедурные")
    for n, lab, col in marks:
        ax.scatter([refs[n]["relief_m"]], [refs[n]["slope_p50"]], s=90, c=col, marker="*", label=lab)
    ax.set_xlabel("размах hc400, м")
    ax.set_ylabel("уклон p50, м/м")
    ax.legend(fontsize=8)
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(figd / "scatter_slope_relief.png", dpi=110)
    plt.close(fig)
    # карта мест
    fig, ax = plt.subplots(figsize=(11, 5.5))
    ax.scatter([float(r["lon"]) for r in pool], [float(r["lat"]) for r in pool], s=8,
               c=[float(r["slope_p50"]) for r in pool], cmap="viridis", vmin=0, vmax=0.5, label="пул")
    ax.scatter([float(r["lon"]) for r in hold], [float(r["lat"]) for r in hold], s=14, c="#ff7f0e", marker="^",
               label="отложенные")
    ax.set_xlim(-180, 180)
    ax.set_ylim(-60, 75)
    ax.set_xlabel("долгота")
    ax.set_ylabel("широта")
    ax.grid(alpha=0.3)
    ax.legend(fontsize=8)
    ax.set_title("Места П-2 (цвет — уклон p50)")
    fig.tight_layout()
    fig.savefig(figd / "map_places.png", dpi=110)
    plt.close(fig)
    # примеры: по одному месту на слой
    strata = sorted({r["stratum"] for r in pool})
    fig, axs = plt.subplots(2, max(1, (len(strata) + 1) // 2), figsize=(13, 7))
    for ax, st in zip(np.ravel(axs), strata):
        r = next(r for r in pool if r["stratum"] == st)
        hc = np.load(out / "cut" / f"{r['id']}.npz")["hc400"]
        im = ax.imshow(hc, origin="lower", cmap="terrain", extent=[-19.2, 19.2, -19.2, 19.2])
        ax.set_title(f"{r['id']} {r['system']}\n{st} p50 {float(r['slope_p50']):.2f} размах {float(r['relief_m']):.0f}",
                     fontsize=8)
        plt.colorbar(im, ax=ax, shrink=0.7)
    fig.tight_layout()
    fig.savefig(figd / "examples_hc400.png", dpi=100)
    plt.close(fig)
    atomic_json(figd / "features_ref.json", refs)
    copy = HERE / f"figures/p2_terrain_{ctx.out.name}"
    copy.mkdir(parents=True, exist_ok=True)
    if a.root is None:
        for f in figd.iterdir():
            (copy / f.name).write_bytes(f.read_bytes())
    man["complete"] = True
    man["figures"] = sorted(f.name for f in figd.iterdir())
    atomic_json(man_p, man)
    print(f"  картинки: {figd}; complete = true")


# ───────────────────────────── статус ─────────────────────────────

def status(ctx: Ctx, a):
    st = dict(stage=None, complete=False, stages={})
    scr, sel = ctx.work / "screen.json", ctx.work / "select.json"
    st["stages"]["screen"] = dict(done=scr.exists())
    st["stages"]["select"] = dict(done=sel.exists())
    if sel.exists():
        _, pl = all_places(ctx)
        tiles = sorted({t for p in pl for t in place_tiles(ctx, p)})
        have = sum(1 for t in tiles if ctx.tile_path(*t).exists())
        fj = ctx.work / "fetch.json"
        miss = len(json.loads(fj.read_text())["missing"]) if fj.exists() else 0
        st["stages"]["fetch"] = dict(done=fj.exists() and have + miss >= len(tiles), n=have, total=len(tiles),
                                     missing=miss)
        d = ctx.work / "cut_all"
        nc = sum(1 for p in pl if (d / f"{p['sid']}.json").exists())
        st["stages"]["cut"] = dict(done=(ctx.out / "index.csv").exists() and nc == len(pl), n=nc, total=len(pl))
    man = ctx.out / "manifest.json"
    if man.exists():
        m = json.loads(man.read_text())
        st["complete"] = bool(m.get("complete"))
        st["stages"]["figures"] = dict(done=st["complete"])
        st["counts"] = m.get("counts", {}).get("part")
    st["stage"] = next((s for s in STAGES if not st["stages"].get(s, {}).get("done")), "готово")
    st["paths"] = dict(raw=str(ctx.raw), out=str(ctx.out), work=str(ctx.work))
    if a.json:
        print(json.dumps(st, ensure_ascii=False, indent=1))
        return
    for s in STAGES:
        v = st["stages"].get(s, {})
        extra = f" {v['n']}/{v['total']}" if "total" in v else ""
        print(f"  {s:8s} {'готово' if v.get('done') else '—'}{extra}")
    print("итог: готово (complete)" if st["complete"] else f"итог: не готово, следующий этап — {st['stage']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stage", choices=STAGES + ["run", "status"])
    ap.add_argument("--config", default=str(HERE / "configs/terrain.yaml"))
    ap.add_argument("--root", default=None, help="один корень данных (raw/, tiles/, work/) — для тестов")
    ap.add_argument("--workers", type=int, default=0, help="процессов нарезки (по умолчанию min(16, CPU))")
    ap.add_argument("--throttle", type=float, default=0.0, help=argparse.SUPPRESS)   # пауза на тайл — тест kill -9
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    ctx = Ctx(Path(a.config).resolve(), a.root)
    if a.stage == "status":
        return status(ctx, a)
    stages = STAGES if a.stage == "run" else [a.stage]
    fn = dict(screen=stage_screen, select=stage_select, fetch=stage_fetch, cut=stage_cut, figures=stage_figures)
    for k, s in enumerate(stages):
        lp = setup_log(ctx, s)
        print(f"этап {k + 1} из {len(stages)}: {s}  (лог: {lp})", flush=True)
        t0 = time.time()
        fn[s](ctx, a)
        tj = ctx.work / "times.json"
        times = json.loads(tj.read_text()) if tj.exists() else {}
        times.setdefault(s, []).append(round(time.time() - t0, 1))
        atomic_json(tj, times)


if __name__ == "__main__":
    main()
