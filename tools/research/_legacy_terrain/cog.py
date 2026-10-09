"""Минимальное чтение Cloud Optimized GeoTIFF по HTTP range-запросам (без GDAL).

Хватает для ESA WorldCover: классический TIFF, 8 бит, 1 канал, тайлы, сжатие Deflate/без сжатия,
обзорные уровни (overviews) — отдельные IFD. Тот же алгоритм на GDScript —
scripts/terrain/cog_reader.gd (рантайм-загрузка карты поверхности).

Кеш: заголовок и скачанные тайлы — в ~/.cache/deltaplan_terrain/cog/<имя файла>/.
"""

import struct
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
import zlib
from pathlib import Path

import numpy as np

CACHE = Path.home() / ".cache" / "deltaplan_terrain" / "cog"
HEADER_BYTES = 65536
MEM_TILES = 96
UA = "deltaplan-sim/0.1 terrain tool"

TYPE_SIZE = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 12: 8, 16: 8}
TYPE_FMT = {1: "B", 2: "c", 3: "H", 4: "I", 12: "d", 16: "Q"}


def http_range(url: str, start: int, end: int, attempts: int = 4) -> bytes:
    """Байты [start, end] (включительно); при обрыве — повтор."""
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Range": f"bytes={start}-{end}"})
    for k in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read()
        except urllib.error.HTTPError:
            raise
        except OSError as e:
            if k == attempts - 1:
                raise
            print("  повтор запроса:", e, flush=True)
    return b""


class Cog:
    """Один COG-файл: список уровней {width, height, tile_w, tile_h, offsets, counts,
    compression}, геопривязка уровня 0 (lon0, lat0 верхнего левого угла, шаг в градусах)."""

    def __init__(self, url: str):
        self.url = url
        self.dir = CACHE / Path(url).name
        self.dir.mkdir(parents=True, exist_ok=True)
        head = self.dir / "header.bin"
        if not head.exists():
            head.write_bytes(http_range(url, 0, HEADER_BYTES - 1))
        self._head = head.read_bytes()
        self.levels = []
        self._mem = {}  # распакованные тайлы (в памяти, до MEM_TILES штук)
        self._parse()

    def _read(self, off: int, n: int) -> bytes:
        if off + n <= len(self._head):
            return self._head[off:off + n]
        return http_range(self.url, off, off + n - 1)

    def _values(self, typ: int, cnt: int, raw4: bytes):
        size = TYPE_SIZE[typ] * cnt
        data = raw4[:size] if size <= 4 else self._read(struct.unpack("<I", raw4)[0], size)
        if typ == 2:
            return data.decode("latin-1").rstrip("\0")
        return list(struct.unpack("<%d%s" % (cnt, TYPE_FMT[typ]), data))

    def _parse(self):
        h = self._head
        if h[:4] != b"II*\0":
            raise ValueError("нужен little-endian классический TIFF")
        off = struct.unpack("<I", h[4:8])[0]
        while off:
            n = struct.unpack("<H", self._read(off, 2))[0]
            ent = self._read(off + 2, n * 12 + 4)
            tags = {}
            for i in range(n):
                t, typ, cnt = struct.unpack("<HHI", ent[i * 12:i * 12 + 8])
                if t in (256, 257, 258, 259, 277, 317, 322, 323, 324, 325, 33550, 33922):
                    tags[t] = self._values(typ, cnt, ent[i * 12 + 8:i * 12 + 12])
            self.levels.append({
                "width": tags[256][0], "height": tags[257][0],
                "tile_w": tags[322][0], "tile_h": tags[323][0],
                "offsets": tags[324], "counts": tags[325],
                "compression": tags[259][0], "predictor": tags.get(317, [1])[0],
            })
            if 33550 in tags:
                self.scale = tags[33550]      # шаг пикселя (градусы по x, y)
                self.tie = tags[33922]        # (i, j, k, lon, lat, z) — угол пикселя (0, 0)
            off = struct.unpack("<I", ent[n * 12:n * 12 + 4])[0]
        if self.levels[0]["predictor"] != 1:
            raise ValueError("предиктор TIFF не поддержан")

    def tile(self, level: int, tx: int, ty: int) -> np.ndarray:
        key = (level, tx, ty)
        if key not in self._mem:
            if len(self._mem) >= MEM_TILES:
                self._mem.clear()
            self._mem[key] = self._load_tile(level, tx, ty)
        return self._mem[key]

    def _load_tile(self, level: int, tx: int, ty: int) -> np.ndarray:
        lv = self.levels[level]
        raw = self._download(level, tx, ty)
        n = lv["tile_w"] * lv["tile_h"]
        if not raw:
            return np.zeros((lv["tile_h"], lv["tile_w"]), np.uint8)
        if lv["compression"] in (8, 32946):
            raw = zlib.decompress(raw)
        elif lv["compression"] != 1:
            raise ValueError("сжатие %d не поддержано" % lv["compression"])
        return np.frombuffer(raw[:n], np.uint8).reshape(lv["tile_h"], lv["tile_w"])

    def _pixels(self, level: int, lat: np.ndarray, lon: np.ndarray):
        lv = self.levels[level]
        k = self.levels[0]["width"] / lv["width"]
        px = np.floor((lon - self.tie[3]) / (self.scale[0] * k)).astype(np.int64)
        py = np.floor((self.tie[4] - lat) / (self.scale[1] * k)).astype(np.int64)
        inside = (px >= 0) & (py >= 0) & (px < lv["width"]) & (py < lv["height"])
        return px, py, inside

    def prefetch(self, level: int, lat: np.ndarray, lon: np.ndarray, workers: int = 8):
        """Скачать в кеш (параллельно) все тайлы, нужные для точек."""
        lv = self.levels[level]
        px, py, inside = self._pixels(level, lat, lon)
        need = set(zip((px[inside] // lv["tile_w"]).tolist(), (py[inside] // lv["tile_h"]).tolist()))
        need = [t for t in need if not (self.dir / f"L{level}_{t[0]}_{t[1]}.bin").exists()]
        if not need:
            return
        print(f"  скачиваю {len(need)} тайлов уровня {level}", flush=True)
        with ThreadPoolExecutor(workers) as ex:
            list(ex.map(lambda t: self._download(level, *t), need))

    def _download(self, level: int, tx: int, ty: int) -> bytes:
        lv = self.levels[level]
        cols = (lv["width"] + lv["tile_w"] - 1) // lv["tile_w"]
        idx = ty * cols + tx
        path = self.dir / f"L{level}_{tx}_{ty}.bin"
        if path.exists():
            return path.read_bytes()
        off, cnt = lv["offsets"][idx], lv["counts"][idx]
        raw = http_range(self.url, off, off + cnt - 1) if cnt > 0 else b""
        tmp = path.with_suffix(".part")
        tmp.write_bytes(raw)
        tmp.rename(path)
        return raw

    def sample(self, level: int, lat: np.ndarray, lon: np.ndarray, fill: int = 0) -> np.ndarray:
        """Значения ближайших пикселей уровня level в точках (lat, lon)."""
        lv = self.levels[level]
        px, py, inside = self._pixels(level, lat, lon)
        out = np.full(lat.shape, fill, np.uint8)
        tx = px // lv["tile_w"]
        ty = py // lv["tile_h"]
        for t in sorted(set(zip(tx[inside].ravel().tolist(), ty[inside].ravel().tolist()))):
            m = inside & (tx == t[0]) & (ty == t[1])
            arr = self.tile(level, t[0], t[1])
            out[m] = arr[py[m] - t[1] * lv["tile_h"], px[m] - t[0] * lv["tile_w"]]
        return out
