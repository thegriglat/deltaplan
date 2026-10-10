"""Сверка пограничных тайлов (OT-4): регионы по отдельности + finalize (O4) против объединённой выгрузки.

    python3 border_compare.py --a sep/tiles --b merged/tiles --tiles border_tiles.txt [--frags sep/frag]
    python3 border_compare.py --almaty-south --a sep/tiles --b acc_kz/tiles

--a, --b — корни итоговых тайлов (с каталогом v1/). По тайлам списка и потокам: число объектов a и b;
max_count_diff_pct — наибольшее |a−b|/b·100 по парам (тайл, поток), где в a или b ≥ 20 объектов.
dup_keys — дубли ключей OSM. Ключи есть только во фрагментах (--frags, по умолчанию <a>/../frag), в итоговом
тайле их нет, поэтому проверка косвенная: число объектов потока в итоговом тайле больше, чем даёт правило O4
(по ключу берётся одна группа частей — с наибольшим числом точек, при равенстве регион по алфавиту), —
значит какой-то ключ попал дважды. Без фрагментов dup_keys не считается (печатается dup_keys=n/a).
geom_dups_a/b — справочно: разные объекты OSM с одинаковой геометрией (дважды нанесённый дом) — они есть и в
эталоне b, это данные источника, не склейка. Для --almaty-south:
южный ряд окна 5×5 эталона Алматы (j=238, 5 тайлов): объектов в a больше, чем в b → almaty_south_more=yes.
"""
import argparse
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _env  # noqa: E402,F401  (перезапуск в venv, если нет zstd)
from read_tile import read_tile  # noqa: E402

MIN_N = 20
ALMATY_SOUTH = [(238, i) for i in range(1043, 1048)]


def tile_file(root, j, i):
    return Path(root) / "v1" / str(j) / f"{i}.dpt"


def load(root, j, i):
    p = tile_file(root, j, i)
    return read_tile(p.read_bytes()) if p.exists() else None


def counts(t):
    return {s["kind"]: s["count"] for s in t["streams"]} if t else {}


def parse_tiles(path):
    return [tuple(int(x) for x in l.split()[:2]) for l in Path(path).read_text().splitlines() if l.strip()]


def geom_key(kind, o):
    if kind == "buildings":
        return (o["x"], o["y"], o["w2"], o["l2"], o["angle"], o["type"])
    if kind == "names":
        return o
    if "pts" in o:
        return (o.get("cls"), tuple(map(tuple, o["pts"])))
    return repr(o)


def geom_dups(t):
    n = 0
    for s in t["streams"]:
        if s["kind"] == "names":
            continue
        seen = set()
        for o in s["objects"]:
            k = geom_key(s["kind"], o)
            n += k in seen
            seen.add(k)
    return n


def expected_counts(frag_dir, j, i):
    """Число объектов по потокам после правила O4 и число ключей, присутствующих в нескольких регионах."""
    d = Path(frag_dir) / str(j) / str(i)
    if not d.is_dir():
        return None, 0
    groups = {}  # (kind, key) -> (npts, region, parts)
    multi = 0
    seen = defaultdict(set)
    for f in sorted(d.glob("*.frag")):
        reg = f.stem
        t = read_tile(f.read_bytes())
        local = defaultdict(list)
        for s in t["streams"]:
            if s["kind"] == "names":
                continue
            for o, k in zip(s["objects"], s["ids"]):
                local[(s["kind"], k)].append(o)
        for k, parts in local.items():
            if reg not in seen[k] and seen[k]:
                multi += 1
            seen[k].add(reg)
            npts = sum(len(o["pts"]) if "pts" in o else 1 for o in parts)
            cur = groups.get(k)
            if cur is None or npts > cur[0]:
                groups[k] = (npts, reg, len(parts))
    exp = defaultdict(int)
    for (kind, _), (_, _, n) in groups.items():
        exp[kind] += n
    return exp, multi


def border(a, b, tiles, frags):
    worst = (0.0, None)
    dup = 0
    gda = gdb = 0
    both = 0
    tot = defaultdict(lambda: [0, 0])
    print("# j i поток a b diff_pct (только пары с >= %d объектов)" % MIN_N)
    for j, i in tiles:
        ta, tb = load(a, j, i), load(b, j, i)
        ca, cb = counts(ta), counts(tb)
        for k in sorted(set(ca) | set(cb)):
            x, y = ca.get(k, 0), cb.get(k, 0)
            tot[k][0] += x
            tot[k][1] += y
            if max(x, y) >= MIN_N:
                p = abs(x - y) / max(y, 1) * 100
                if p > worst[0]:
                    worst = (p, (j, i, k, x, y))
                if p > 0:
                    print(f"{j} {i} {k} {x} {y} {p:.3f}")
        gda += geom_dups(ta) if ta else 0
        gdb += geom_dups(tb) if tb else 0
        if ta:
            if frags:
                exp, multi = expected_counts(frags, j, i)
                both += multi
                if exp is not None:
                    for k, c in ca.items():
                        if k != "names" and c > exp.get(k, 0):
                            dup += c - exp[k]
    print("# итого по потокам: поток a b")
    for k, (x, y) in sorted(tot.items()):
        print(f"{k} {x} {y}")
    print(f"tiles={len(tiles)} keys_in_several_regions={both}")
    print(f"worst={worst[1]}")
    print(f"max_count_diff_pct={worst[0]:.3f}")
    print(f"geom_dups_a={gda} geom_dups_b={gdb}")
    print(f"dup_keys={dup if frags else 'n/a'}")


def almaty_south(a, b):
    ra = rb = 0
    ok_all = True
    for j, i in ALMATY_SOUTH:
        ca, cb = counts(load(a, j, i)), counts(load(b, j, i))
        x, y = sum(ca.values()), sum(cb.values())
        print(f"tile {j} {i}: a={x} b={y}")
        ra, rb, ok_all = ra + x, rb + y, ok_all and x >= y
    print(f"total a={ra} b={rb}")
    print(f"almaty_south_more={'yes' if ra > rb and ok_all else 'no'}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--a", required=True)
    ap.add_argument("--b", required=True)
    ap.add_argument("--tiles")
    ap.add_argument("--frags")
    ap.add_argument("--almaty-south", action="store_true")
    o = ap.parse_args(argv)
    if o.almaty_south:
        almaty_south(o.a, o.b)
        return 0
    if not o.tiles:
        ap.error("нужен --tiles")
    frags = o.frags or str(Path(o.a).parent / "frag")
    border(o.a, o.b, parse_tiles(o.tiles), frags if Path(frags).is_dir() else None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
