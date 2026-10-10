"""Независимый декодер тайла O2/O3 (docs/contracts/osm-tiles.md) — для проверки Rust-кодера.

Только stdlib, кроме распаковки zstd: Python < 3.14 её не имеет, берётся пакет `zstandard`
(есть в venv эталона /home/greg/deltaplan_data/osm_pack/venv). Результат `read_tile(bytes)` — тот же
словарь, что печатает `osmtiles dump` (сверка в tests/).
"""
import struct
import sys

KINDS = {1: "roads", 2: "track", 3: "buildings", 4: "powerline", 5: "power_tower", 6: "aerialway",
         7: "aeroway", 8: "vertical", 9: "rail", 10: "peak", 11: "pass", 12: "names", 13: "river", 14: "canal"}
MAX_RAW = 64 << 20


def _zstd_decompress(frame, raw_len):
    try:
        from compression import zstd  # Python 3.14+
        return zstd.decompress(frame)
    except ImportError:
        pass
    import zstandard
    return zstandard.ZstdDecompressor().decompress(frame, max_output_size=raw_len)


class Buf:
    def __init__(self, b):
        self.b, self.p = b, 0

    def varint(self):
        v = shift = 0
        while True:
            c = self.b[self.p]
            self.p += 1
            v |= (c & 0x7F) << shift
            if not c & 0x80:
                return v
            shift += 7

    def byte(self):
        c = self.b[self.p]
        self.p += 1
        return c

    def take(self, n):
        s = self.b[self.p:self.p + n]
        if len(s) != n:
            raise ValueError("конец данных")
        self.p += n
        return s

    def done(self):
        return self.p == len(self.b)


def unzz(u):
    return (u >> 1) ^ -(u & 1)


def _points(r, n, last):
    pts = []
    for _ in range(n):
        last[0] += unzz(r.varint())
        last[1] += unzz(r.varint())
        pts.append([last[0], last[1]])
    return pts


def decode_stream(kind, count, data):
    r, last, out = Buf(data), [0, 0], []
    for _ in range(count):
        if kind in ("roads", "track"):
            cls, fl = r.varint(), r.byte()
            w = r.varint() if fl & 1 else None
            lanes = r.varint() if fl & 2 else None
            pts = _points(r, r.varint(), last)
            out.append({"cls": cls, "width_dm": w, "lanes": lanes, "tunnel": bool(fl & 8),
                        "bridge": bool(fl & 16), "pts": pts})
        elif kind == "buildings":
            last[0] += unzz(r.varint())
            last[1] += unzz(r.varint())
            w2, l2, ang, hl, typ = (r.varint() for _ in range(5))
            out.append({"x": last[0], "y": last[1], "w2": w2, "l2": l2, "angle": ang,
                        "hq": hl >> 1, "lv": bool(hl & 1), "type": typ})
        elif kind == "names":
            out.append(r.take(r.varint()).decode("utf-8"))
        else:
            cls, fl, h = r.varint(), r.byte(), r.varint()
            out.append({"cls": cls, "flags": fl, "h": h, "pts": _points(r, r.varint(), last)})
    if not r.done():
        raise ValueError("лишние байты в потоке " + kind)
    return out


def _parse_stream(msg):
    r, s = Buf(msg), {"kind": 0, "count": 0, "data": b"", "ids": b""}
    while not r.done():
        tag = r.varint()
        f, wt = tag >> 3, tag & 7
        if wt == 0:
            v = r.varint()
            if f == 1:
                s["kind"] = v
            elif f == 2:
                s["count"] = v
        elif wt == 2:
            v = r.take(r.varint())
            if f == 3:
                s["data"] = bytes(v)
            elif f == 4:
                s["ids"] = bytes(v)
        else:
            raise ValueError("тип поля %d" % wt)
    return s


def _parse_tile(pbuf):
    r = Buf(pbuf)
    t = {"format_version": 0, "j": 0, "i": 0, "n": 0, "osm_timestamp": 0, "sources": [], "streams": []}
    names = {1: "format_version", 2: "j", 3: "i", 4: "n", 5: "osm_timestamp"}
    while not r.done():
        tag = r.varint()
        f, wt = tag >> 3, tag & 7
        if wt == 0:
            v = r.varint()
            if f == 2:
                v = unzz(v)  # sint32
            elif f == 5 and v >= 1 << 63:
                v -= 1 << 64  # int64
            if f in names:
                t[names[f]] = v
        elif wt == 2:
            v = r.take(r.varint())
            if f == 6:
                t["sources"].append(bytes(v).decode("utf-8"))
            elif f == 7:
                t["streams"].append(_parse_stream(v))
        else:
            raise ValueError("тип поля %d" % wt)
    return t


def read_tile(data):
    """Файл O2 → словарь как у `osmtiles dump`."""
    if data[:4] != b"DPOT":
        raise ValueError("нет магии DPOT")
    version, flags, raw_len, reserved = struct.unpack("<HHII", data[4:16])
    if version != 1 or flags & ~1 or reserved or raw_len > MAX_RAW:
        raise ValueError("заголовок")
    raw = _zstd_decompress(data[16:], raw_len)
    if len(raw) != raw_len:
        raise ValueError("raw_len")
    t = _parse_tile(raw)
    streams = []
    for s in t["streams"]:
        kind = KINDS.get(s["kind"])
        if kind is None:
            continue  # неизвестный kind клиент пропускает
        ids, rr, prev = [], Buf(s["ids"]), 0
        if flags & 1:
            for _ in range(s["count"]):
                prev += unzz(rr.varint())
                ids.append(prev)
        streams.append({"kind": kind, "count": s["count"],
                        "objects": decode_stream(kind, s["count"], s["data"]), "ids": ids})
    return {"header": {"magic": "DPOT", "version": version, "flags": flags, "raw_len": raw_len},
            "format_version": t["format_version"], "j": t["j"], "i": t["i"], "n": t["n"],
            "osm_timestamp": t["osm_timestamp"], "sources": t["sources"], "streams": streams}


if __name__ == "__main__":
    import json
    json.dump(read_tile(open(sys.argv[1], "rb").read()), sys.stdout, ensure_ascii=False, indent=1, sort_keys=True)
    print()
