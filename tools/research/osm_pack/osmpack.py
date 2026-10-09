"""Прототип компактного векторного пакета OSM для Deltaplan (формат и кодек).

Ячейка — CELL_DEG x CELL_DEG градусов. Внутри — локальная сетка в метрах от юго-западного угла
ячейки (равнопромежуточная проекция по широте центра ячейки: x = dlon*R*cos(lat_c), y = dlat*R),
координаты — целые с шагом GRID_M, дельты от предыдущей точки ПОТОКА (цепочка через объекты),
zigzag + varint.

Блоб ячейки: magic b"DPK1", varint число потоков, затем для каждого потока: varint id потока,
varint длина, байты. Поток — последовательность объектов:
    varint класс (индекс в CLASSES[поток]; геометрия задаётся классом: point/line/area)
    u8 флаги: 1 ширина, 2 высота, 4 имя, 8 тоннель, 16 мост
    [varint ширина, дм] [zigzag высота/ele, м] [varint индекс имени в потоке names]
    point: zigzag dx, dy
    line : varint n, n x (zigzag dx, dy)
    area : varint колец (первое — внешнее), на кольцо varint n, n x (dx, dy), кольцо не замкнуто
Поток names: varint n, затем n x (varint длина, utf-8).
Не прототип-шлифовка: без индекса внутри ячейки, без уровней детализации.
"""
from __future__ import annotations

import math

CELL_DEG = 0.25
R_EARTH = 6371008.8
M_PER_DEG = math.pi * R_EARTH / 180.0

STREAMS = ["roads_main", "roads_tp", "rail", "water_lines", "water_areas", "landcover",
           "cliffs", "places", "pilot", "names"]
SID = {s: i for i, s in enumerate(STREAMS)}
# группы для отчёта
GROUPS = {
    "дороги (без track/path)": ["roads_main"],
    "дороги track/path": ["roads_tp"],
    "ж/д": ["rail"],
    "вода": ["water_lines", "water_areas"],
    "землепользование+natural (+cliff)": ["landcover", "cliffs"],
    "объекты для пилота": ["pilot"],
    "place": ["places"],
    "имена": ["names"],
}

HIGHWAY_TP = {"track", "path"}
LANDCOVER = ["forest", "wood", "meadow", "grassland", "grass", "farmland", "orchard", "vineyard",
             "allotments", "heath", "scrub", "wetland", "sand", "shingle", "scree", "bare_rock",
             "glacier", "quarry", "residential", "industrial"]


class ClassTable:
    """Строка класса -> id (заполняется при сборке, сохраняется в classes.json)."""

    def __init__(self, init=None):
        self.names: dict[str, list[str]] = init or {s: [] for s in STREAMS}
        self.idx = {s: {n: i for i, n in enumerate(v)} for s, v in self.names.items()}

    def get(self, stream: str, name: str) -> int:
        d = self.idx[stream]
        if name not in d:
            d[name] = len(self.names[stream])
            self.names[stream].append(name)
        return d[name]


def put_varint(buf: bytearray, v: int) -> None:
    while v >= 0x80:
        buf.append((v & 0x7F) | 0x80)
        v >>= 7
    buf.append(v)


def zz(v: int) -> int:
    return (v << 1) ^ (v >> 63)


def get_varint(b, p: int):
    r = 0
    s = 0
    while True:
        c = b[p]
        p += 1
        r |= (c & 0x7F) << s
        if c < 0x80:
            return r, p
        s += 7


def unzz(v: int) -> int:
    return (v >> 1) ^ -(v & 1)


class StreamWriter:
    def __init__(self):
        self.buf = bytearray()
        self.lx = 0
        self.ly = 0
        self.count = 0

    def header(self, cls: int, width_dm=None, height_m=None, name_idx=None, tunnel=False,
               bridge=False):
        b = self.buf
        put_varint(b, cls)
        f = ((1 if width_dm is not None else 0) | (2 if height_m is not None else 0)
             | (4 if name_idx is not None else 0) | (8 if tunnel else 0) | (16 if bridge else 0))
        b.append(f)
        if width_dm is not None:
            put_varint(b, width_dm)
        if height_m is not None:
            put_varint(b, zz(height_m))
        if name_idx is not None:
            put_varint(b, name_idx)
        self.count += 1

    def pts(self, xs, ys, with_n=True):
        b = self.buf
        if with_n:
            put_varint(b, len(xs))
        lx, ly = self.lx, self.ly
        for x, y in zip(xs, ys):
            put_varint(b, zz(x - lx))
            put_varint(b, zz(y - ly))
            lx, ly = x, y
        self.lx, self.ly = lx, ly

    def rings(self, rings):
        put_varint(self.buf, len(rings))
        for xs, ys in rings:
            self.pts(xs, ys)


class NameTable:
    def __init__(self):
        self.idx: dict[str, int] = {}

    def get(self, s: str) -> int:
        if s not in self.idx:
            self.idx[s] = len(self.idx)
        return self.idx[s]

    def encode(self) -> bytes:
        b = bytearray()
        put_varint(b, len(self.idx))
        for s in self.idx:
            e = s.encode("utf-8")
            put_varint(b, len(e))
            b += e
        return bytes(b)


def pack_cell(streams: dict[str, bytes], skip=()) -> bytes:
    b = bytearray(b"DPK1")
    items = [(SID[s], v) for s, v in streams.items() if v and s not in skip]
    put_varint(b, len(items))
    for sid, v in sorted(items):
        put_varint(b, sid)
        put_varint(b, len(v))
        b += v
    return bytes(b)


def gtype_of(cls_name: str) -> str:
    return cls_name.rsplit(":", 1)[1]


def decode_cell(blob: bytes, classes: dict[str, list[str]]):
    """-> {поток: [(класс, флаги, ширина_дм, высота, имя, геометрия)]}, геометрия в метрах
    ячейки: point (x, y); line [(xs, ys)]; area [кольца (xs, ys)] (xs/ys — списки целых шагов)."""
    assert blob[:4] == b"DPK1"
    p = 4
    n, p = get_varint(blob, p)
    raw = {}
    for _ in range(n):
        sid, p = get_varint(blob, p)
        ln, p = get_varint(blob, p)
        raw[STREAMS[sid]] = blob[p:p + ln]
        p += ln
    names = []
    if "names" in raw:
        b = raw["names"]
        q = 0
        k, q = get_varint(b, q)
        for _ in range(k):
            ln, q = get_varint(b, q)
            names.append(bytes(b[q:q + ln]).decode("utf-8"))
            q += ln
    out = {}
    for s, b in raw.items():
        if s == "names":
            continue
        objs = []
        q = 0
        lx = ly = 0
        cl = classes[s]

        def read_pts(q, lx, ly):
            m, q = get_varint(b, q)
            xs = [0] * m
            ys = [0] * m
            for i in range(m):
                dx, q = get_varint(b, q)
                dy, q = get_varint(b, q)
                lx += unzz(dx)
                ly += unzz(dy)
                xs[i] = lx
                ys[i] = ly
            return (xs, ys), q, lx, ly

        while q < len(b):
            c, q = get_varint(b, q)
            f = b[q]
            q += 1
            w = h = nm = None
            if f & 1:
                w, q = get_varint(b, q)
            if f & 2:
                h, q = get_varint(b, q)
                h = unzz(h)
            if f & 4:
                ni, q = get_varint(b, q)
                nm = names[ni]
            name = cl[c]
            gt = gtype_of(name)
            if gt == "point":
                dx, q = get_varint(b, q)
                dy, q = get_varint(b, q)
                lx += unzz(dx)
                ly += unzz(dy)
                geom = (lx, ly)
            elif gt == "line":
                geom, q, lx, ly = read_pts(q, lx, ly)
            else:
                nr, q = get_varint(b, q)
                geom = []
                for _ in range(nr):
                    r, q, lx, ly = read_pts(q, lx, ly)
                    geom.append(r)
            objs.append((name, f, w, h, nm, geom))
        out[s] = objs
    return out


def cell_origin(ix: int, iy: int):
    lon0 = ix * CELL_DEG
    lat0 = iy * CELL_DEG
    kx = M_PER_DEG * math.cos(math.radians(lat0 + CELL_DEG / 2))
    ky = M_PER_DEG
    return lon0, lat0, kx, ky


def cell_name(ix: int, iy: int) -> str:
    return f"{iy:+04d}_{ix:+04d}"


def set_streams(streams: list[str]) -> None:
    """Подменить набор потоков (build_min.py/analyze_min.py), на месте — SID/decode видят."""
    STREAMS[:] = streams
    SID.clear()
    SID.update({s: i for i, s in enumerate(streams)})
