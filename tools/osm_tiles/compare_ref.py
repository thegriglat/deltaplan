#!/usr/bin/env python3
"""Сверка сводки O6 (osmtiles stats --zstd-per-stream) с эталоном §9 по допускам плана.

    python3 compare_ref.py stats.json --ref slovenia|almaty [--cover cover.txt] [--twin stats2.json]
                           [--ref-dir DIR] [--json out.json]

Код 0 — все проверки PASS, 1 — есть FAIL. Допуски — в TOL ниже
(docs/plan/osm-tiles.md, «Допуски сверки с эталоном (этап 1)»).

Набор тайлов сравнения: без --cover — только тайлы эталона с inside=true (у Алматы флага нет — все 25);
с --cover (вывод `osmtiles cover`, строки «j i») — тайлы эталона, пересекающие .poly. Сумма — по этому набору
(нет нашего тайла = 0). Расхождение наборов допустимо только для тайлов, не пересекающих .poly: тайл
эталона (не пустой) без нашего, лежащий в cover, и наш тайл вне эталона, лежащий в cover, — FAIL.
Без --cover наши «лишние» тайлы только перечисляются (судить нельзя).
Алматы — только roads, track, buildings. Пустой (все count = 0) тайл эталона без нашего — не ошибка.
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ref_to_stats import load_ref  # noqa: E402

# Допуски, % (план: «Допуски сверки с эталоном»). Все в одном месте.
TOL = {
    "count_line": 1.0,        # roads, track, river, canal, powerline, rail, aerialway
    "count_buildings": 0.5,   # дома >= 50 м2
    "count_point": 1.0,       # power_tower, vertical, peak, pass, names, aeroway
    "small_stream_n": 200,    # поток < 200 объектов в эталоне: ±max(small_abs, small_pct)
    "small_abs": 2,           # объектов
    "small_pct": 3.0,
    "len_km": 0.5,            # roads, track
    "raw": 3.0,
    "zstd": 5.0,
    "tile_min_objects": 200,  # по тайлам: тайлы с >= 200 объектов в потоке ...
    "tile_count_pct": 2.0,    # ... где расхождение числа <= 2 % ...
    "tile_share_min": 95.0,   # ... должны составлять >= 95 %
}
LINE = ["roads", "track", "river", "canal", "powerline", "rail", "aerialway"]
POINT = ["power_tower", "vertical", "peak", "pass", "names", "aeroway"]
ALL_STREAMS = ["roads", "track", "buildings"] + LINE[2:] + POINT
STREAMS_BY_REF = {"slovenia": ALL_STREAMS, "almaty": ["roads", "track", "buildings"]}
LEN_STREAMS = ["roads", "track"]


def parse_cover(path):
    out = set()
    for ln in Path(path).read_text().splitlines():
        p = ln.split()
        if len(p) >= 2:
            out.add(f"{int(p[0])},{int(p[1])}")
    return out


def get(stats_tile, stream, field):
    return ((stats_tile or {}).get("streams", {}).get(stream) or {}).get(field, 0) or 0


class Table:
    def __init__(self):
        self.rows = []

    def add(self, metric, ref, ours, tol_txt, ok, delta=None):
        self.rows.append({"metric": metric, "ref": ref, "ours": ours,
                          "delta_pct": None if delta is None else ("inf" if delta == float("inf") else round(delta, 4)), "tol": tol_txt, "ok": bool(ok)})

    def tol_row(self, metric, ref, ours, tol_pct, abs_tol=None):
        """±tol_pct %, а если abs_tol задан — ±max(abs_tol, tol_pct %) в абсолютных единицах."""
        diff = ours - ref
        if ref == 0:
            ok, delta = diff == 0, (0.0 if diff == 0 else float("inf"))
        else:
            delta = diff / ref * 100
            lim = abs(ref) * tol_pct / 100
            if abs_tol is not None:
                lim = max(abs_tol, lim)
            ok = abs(diff) <= lim + 1e-9
        txt = f"±{tol_pct:g} %" if abs_tol is None else f"±max({abs_tol:g}, {tol_pct:g} %)"
        self.add(metric, ref, ours, txt, ok, delta)


def count_tol(stream, ref_total):
    if ref_total < TOL["small_stream_n"]:
        return TOL["small_pct"], TOL["small_abs"]
    if stream == "buildings":
        return TOL["count_buildings"], None
    return (TOL["count_line"] if stream in LINE or stream in ("roads", "track") else TOL["count_point"]), None


def compare(stats, ref, cover=None, ref_dir=None):
    rt, inside = load_ref(ref, ref_dir)
    streams = STREAMS_BY_REF[ref]
    tb = Table()
    ours_t = stats.get("tiles", {})
    if cover is None:
        comp = sorted(k for k in rt if inside.get(k, True))
    else:
        comp = sorted(k for k in rt if k in cover)

    def nonempty(k):
        return any(rt[k].get(s, {}).get("count", 0) for s in streams)

    missing = [k for k in comp if k not in ours_t and nonempty(k)]
    if cover is None:
        extra = sorted(k for k in ours_t if k not in rt)
        tb.add("тайлы эталона (inside) без наших", len(comp), len(missing), "0", not missing)
        tb.add("наши тайлы вне эталона (без --cover не судим)", 0, len(extra), "инфо", True)
    else:
        extra = sorted(k for k in ours_t if k not in rt and k in cover)
        tb.add("тайлы эталона из cover без наших", len(comp), len(missing), "0", not missing)
        tb.add("наши тайлы из cover, которых нет в эталоне", 0, len(extra), "0", not extra)
    tb.rows[0]["list"] = missing[:20]

    for s in streams:
        refc = sum(rt[k].get(s, {}).get("count", 0) for k in comp)
        ourc = sum(get(ours_t.get(k), s, "count") for k in comp)
        pct, ab = count_tol(s, refc)
        tb.tol_row(f"{s}: число объектов", refc, ourc, pct, ab)
    for s in LEN_STREAMS:
        if s in streams:
            r = sum(rt[k].get(s, {}).get("len_km", 0) for k in comp)
            o = sum(get(ours_t.get(k), s, "len_km") for k in comp)
            tb.tol_row(f"{s}: длина, км", round(r, 3), round(o, 3), TOL["len_km"])
    for s in streams:
        if any("raw" in rt[k].get(s, {}) for k in comp):
            r = sum(rt[k].get(s, {}).get("raw", 0) for k in comp)
            o = sum(get(ours_t.get(k), s, "raw") for k in comp)
            tb.tol_row(f"{s}: raw, Б", r, o, TOL["raw"])
    for s in streams:
        r = sum(rt[k].get(s, {}).get("zstd", 0) for k in comp)
        o = sum(get(ours_t.get(k), s, "zstd") for k in comp)
        tb.tol_row(f"{s}: zstd 19, Б", r, o, TOL["zstd"])
    for s in streams:
        big = [k for k in comp if rt[k].get(s, {}).get("count", 0) >= TOL["tile_min_objects"]]
        if not big:
            continue
        good = 0
        for k in big:
            r = rt[k][s]["count"]
            if abs(get(ours_t.get(k), s, "count") - r) <= r * TOL["tile_count_pct"] / 100:
                good += 1
        share = good / len(big) * 100
        tb.add(f"{s}: тайлы ≥{TOL['tile_min_objects']} объектов с Δ ≤ {TOL['tile_count_pct']:g} % (из {len(big)})",
               100.0, round(share, 2), f"≥ {TOL['tile_share_min']:g} %", share >= TOL["tile_share_min"],
               share - 100)
    fb = stats.get("file_bytes_total")
    zs = [v.get("zstd") for v in stats.get("totals", {}).values()]
    if fb is not None and zs and all(z is not None for z in zs):
        sz = sum(zs)
        tb.add("итоговые файлы ≤ сумма zstd потоков, Б", sz, fb, "≤", fb <= sz,
               (fb - sz) / sz * 100 if sz else 0)
    return tb


def render(tb):
    w = max(len(r["metric"]) for r in tb.rows)
    lines = [f"{'метрика':<{w}} | {'эталон':>12} | {'наше':>12} | {'Δ%':>8} | {'допуск':<14} | итог"]
    for r in tb.rows:
        d = "" if r["delta_pct"] is None else (r["delta_pct"] if r["delta_pct"] == "inf" else f"{r['delta_pct']:+.3f}")
        lines.append(f"{r['metric']:<{w}} | {r['ref']:>12} | {r['ours']:>12} | {d:>8} | {r['tol']:<14} | "
                     f"{'PASS' if r['ok'] else 'FAIL'}")
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stats")
    ap.add_argument("--ref", required=True, choices=("slovenia", "almaty"))
    ap.add_argument("--cover")
    ap.add_argument("--twin", help="второй прогон: файл сводки должен совпасть побайтно")
    ap.add_argument("--ref-dir")
    ap.add_argument("--json", help="записать таблицу в json")
    a = ap.parse_args(argv)
    stats = json.loads(Path(a.stats).read_text())
    if stats.get("schema") != "osmtiles-stats/1":
        raise SystemExit("ожидается schema osmtiles-stats/1")
    tb = compare(stats, a.ref, parse_cover(a.cover) if a.cover else None, a.ref_dir)
    if a.twin:
        same = Path(a.stats).read_bytes() == Path(a.twin).read_bytes()
        tb.add("два прогона побайтно равны", "-", "равны" if same else "различны", "равны", same)
    print(render(tb))
    ok = all(r["ok"] for r in tb.rows)
    print(f"\nитог: {'PASS' if ok else 'FAIL'} ({sum(not r['ok'] for r in tb.rows)} из {len(tb.rows)} проверок не прошли)")
    if a.json:
        Path(a.json).write_text(json.dumps({"ok": ok, "rows": tb.rows}, ensure_ascii=False, indent=1))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
