"""Минимальный читатель OsmAnd OBF (без protoc): разделы, правила тегов карты, уровни зума,
подсчёт объектов по тегам на самом подробном уровне в заданном bbox. Схема — OsmAnd-resources/protos/OBF.proto."""
import math
import struct
import sys
from collections import Counter

FIX32 = {(0, 4), (0, 6), (0, 7), (0, 8), (0, 9), (0, 10)}  # верхний уровень: разделы с fixed32 длиной


def varint(b, i):
    r = s = 0
    while True:
        c = b[i]; i += 1
        r |= (c & 0x7F) << s; s += 7
        if c < 0x80:
            return r, i


def zz(v):
    return (v >> 1) ^ -(v & 1)


def fields(b, i, end, fix32_tags=(), raw6=()):
    """Итератор (tag, wire, value_or_(start,end), next_i)."""
    while i < end:
        key, i = varint(b, i)
        tag, wt = key >> 3, key & 7
        if wt == 0:
            v, i = varint(b, i); yield tag, wt, v
        elif wt == 2:
            if tag in fix32_tags:
                ln = struct.unpack(">I", b[i:i + 4])[0]; i += 4
            else:
                ln, i = varint(b, i)
            yield tag, wt, (i, i + ln); i += ln
        elif wt == 6:  # OsmAnd: WIRETYPE_FIXED32_LENGTH_DELIMITED
            ln = struct.unpack(">I", b[i:i + 4])[0]; i += 4
            if tag in raw6:
                yield tag, 5, ln; continue
            yield tag, 2, (i, i + ln); i += ln
        elif wt == 5:
            yield tag, wt, struct.unpack("<I", b[i:i + 4])[0]; i += 4
        elif wt == 1:
            yield tag, wt, b[i:i + 8]; i += 8
        else:
            raise ValueError(f"wire {wt} at {i}")


def x31(lon):
    return int((lon + 180) / 360 * 2**31)


def y31(lat):
    la = math.radians(lat)
    return int((1 - math.log(math.tan(la) + 1 / math.cos(la)) / math.pi) / 2 * 2**31)


def main(path, lat, lon, half_km):
    b = open(path, "rb").read()
    names = {7: "address", 4: "transport", 8: "poi", 6: "map", 9: "routing", 10: "hh_routing"}
    print(f"file {path}: {len(b)/1e6:.1f} MB")
    maps = []
    for tag, wt, v in fields(b, 0, len(b)):
        if tag in names:
            s, e = v
            print(f"  section {names[tag]:10s} {(e-s)/1e6:8.1f} MB")
            if tag == 6:
                maps.append(v)
        elif tag in (1, 32, 18):
            print("  field", tag, v)
    dm = half_km * 1000 / 6371000 * 180 / math.pi
    bx = (x31(lon - dm / math.cos(math.radians(lat))), x31(lon + dm / math.cos(math.radians(lat))),
          y31(lat + dm), y31(lat - dm))
    for s, e in maps:
        rules = []
        levels = []
        for tag, wt, v in fields(b, s, e):
            if tag == 2:
                print("  map index name:", b[v[0]:v[1]].decode())
            elif tag == 4:
                t = val = ""
                for t2, _, v2 in fields(b, *v):
                    if t2 == 3: t = b[v2[0]:v2[1]].decode()
                    if t2 == 5: val = b[v2[0]:v2[1]].decode()
                rules.append((t, val))
            elif tag == 5:
                levels.append(v)
        print(f"  rules: {len(rules)}")
        interest = ("highway", "waterway", "natural", "power", "building", "landuse", "place", "barrier", "leisure", "landcover", "wood")
        keys = Counter(t for t, _ in rules)
        print("  rule tags (count of values):", {k: keys[k] for k in interest if k in keys})
        for k in ("power", "natural", "landuse", "waterway", "place"):
            print(f"    {k}:", sorted({v for t, v in rules if t == k})[:40])
        for ls, le in levels:
            lv = {}
            boxes = []
            for tag, wt, v in fields(b, ls, le):
                if tag <= 6: lv[tag] = v
                if tag == 7: boxes.append(v)
            print(f"  level zoom {lv.get(2)}..{lv.get(1)}, top boxes {len(boxes)}")
        # подробнейший уровень: обход дерева
        ls, le = max(levels, key=lambda v: dict((t, x) for t, _, x in fields(b, v[0], v[1]) if t <= 6).get(1))
        cnt = Counter(); nobj = 0; blocks = set()

        def walk(s0, e0, pl, pr, pt, pbm):
            nonlocal nobj
            d = {}; kids = []
            for tag, wt, v in fields(b, s0, e0, raw6={5}):
                if tag in (1, 2, 3, 4): d[tag] = zz(v)
                elif tag == 5: d[5] = v
                elif tag == 7: kids.append(v)
            l, r, t, bo = pl + d[1], pr + d[2], pt + d[3], pbm + d[4]
            if r < bx[0] or l > bx[1] or bo < bx[2] or t > bx[3]:
                return
            if 5 in d:
                off = s0 + d[5]
                # блок: длина varint? пробуем
                ln, j = varint(b, off)
                if off not in blocks:
                    blocks.add(off)
                    for tag, wt, v in fields(b, j, j + ln):
                        if tag == 12:
                            nobj += 1
                            for t2, _, v2 in fields(b, *v):
                                if t2 in (6, 7):
                                    k = v2[0]
                                    while k < v2[1]:
                                        tid, k = varint(b, k)
                                        if 0 < tid <= len(rules):
                                            cnt[rules[tid - 1]] += 1
            for ks, ke in kids:
                walk(ks, ke, l, r, t, bo)

        root = dict((t, x) for t, _, x in fields(b, ls, le) if t <= 6)
        for tag, wt, v in fields(b, ls, le):
            if tag == 7:
                walk(v[0], v[1], root[3], root[4], root[5], root[6])
        print(f"  bbox {half_km} km around {lat},{lon}: blocks {len(blocks)}, objects {nobj}")
        by = Counter()
        for (t, v), n in cnt.items():
            if t in interest: by[(t, v)] += n
        for (t, v), n in sorted(by.items(), key=lambda x: -x[1])[:45]:
            print(f"    {t}={v}: {n}")


if __name__ == "__main__":
    main(sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]))
