"""Этап 2: выборка точек, вырез 3×3 тайла мировой сетки из planet (или любого pbf), сборка, сводка.

    python -I stage2.py points  <out_points.json> [--seed=1] [--per-country=5]
    python -I stage2.py extract <planet.osm.pbf> <points.json> <work_dir> [--only=name,name]
    python -I stage2.py build   <points.json> <work_dir> <res_dir> [--jobs=8]
    python -I stage2.py summary <points.json> <res_dir> <out.json>

extract делает ОДИН запуск `osmium extract -c` (многобоксовый конфиг, стратегия smart), затем
tags-filter w/highway wr/building на каждом куске. build запускает build_tiles20.py на каждом
куске с --want на его 3×3 тайла. Точки: до N стартов на страну из data/places/hg_takeoffs.json
(random.Random(seed)), 4 места из configs/locations/*.json, города Манхэттен и Алматы.
Антимеридиан не поддержан (точки у ±180° пропускаются).
"""
from __future__ import annotations

import json
import math
import random
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from build_tiles20 import DLAT, Band, tile_of  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).parent
PY = sys.executable
CITIES = [("city_manhattan", 40.758, -73.985), ("city_almaty", 43.24, 76.89)]


def block(lon, lat, r=1):
    j0, _ = tile_of(lon, lat)
    out = []
    for j in range(j0 - r, j0 + r + 1):
        bd = Band.get(j)
        i = min(bd.n - 1, max(0, math.floor((lon + 180) / bd.dlon)))
        for di in range(-r, r + 1):
            if 0 <= i + di < bd.n:
                out.append((j, i + di))
    return out


def bbox_of(tiles):
    lo = min(Band.get(j).lon0(i) for j, i in tiles)
    hi = max(Band.get(j).lon0(i) + Band.get(j).dlon for j, i in tiles)
    return [round(lo, 4), round(min(j for j, _ in tiles) * DLAT, 4),
            round(hi, 4), round((max(j for j, _ in tiles) + 1) * DLAT, 4)]


def points(out, seed, per, extra=()):
    rnd = random.Random(seed)
    d = json.loads((ROOT / "data/places/hg_takeoffs.json").read_text())
    by = {}
    for t in d["takeoffs"]:
        by.setdefault(t["country"], []).append(t)
    pts = []
    for c in sorted(by):
        for t in rnd.sample(by[c], min(per, len(by[c]))):
            pts.append({"name": f"to_{c}_{t['id'].replace('/', '')}", "kind": "takeoff", "country": c,
                        "lat": t["lat"], "lon": t["lon"]})
    for f in sorted((ROOT / "configs/locations").glob("*.json")):
        c = json.loads(f.read_text())
        pts.append({"name": f"loc_{f.stem}", "kind": "location", "lat": c["center_lat"], "lon": c["center_lon"]})
    for n, la, lo in CITIES:
        pts.append({"name": n, "kind": "city", "lat": la, "lon": lo})
    res = []
    for p in pts:
        tl = block(p["lon"], p["lat"])
        bb = bbox_of(tl)
        if len(tl) < 9 or bb[0] < -179.9 or bb[2] > 179.9 or bb[1] < -89 or bb[3] > 89:
            continue
        p["tiles"], p["bbox"] = tl, bb
        res.append(p)
    Path(out).write_text(json.dumps(res, ensure_ascii=False, indent=1))
    print(len(res), "точек")


def extract(src, pts_f, work, only):
    pts = json.loads(Path(pts_f).read_text())
    if only:
        pts = [p for p in pts if p["name"] in only]
    work = Path(work)
    work.mkdir(parents=True, exist_ok=True)
    cfg = {"directory": str(work),
           "extracts": [{"output": f"{p['name']}.osm.pbf", "bbox": p["bbox"]} for p in pts]}
    (work / "extract.json").write_text(json.dumps(cfg, indent=1))
    subprocess.run(["osmium", "extract", "-O", "-s", "smart", "-c", str(work / "extract.json"), str(src)],
                   check=True)


def build_one(args):
    p, work, res = args
    f = Path(work) / f"{p['name']}.osm.pbf"
    hb = Path(work) / f"{p['name']}.hb.pbf"
    subprocess.run(["osmium", "tags-filter", "-O", "-o", str(hb), str(f), "w/highway", "wr/building"], check=True)
    want = ";".join(f"{j},{i}" for j, i in p["tiles"])
    r = subprocess.run([PY, "-I", str(HERE / "build_tiles20.py"), str(hb), str(Path(res) / f"{p['name']}.json"),
                        f"--want={want}"], capture_output=True, text=True)
    hb.unlink(missing_ok=True)
    return p["name"], r.returncode, r.stderr[-300:]


def build(pts_f, work, res, jobs):
    pts = json.loads(Path(pts_f).read_text())
    pts = [p for p in pts if (Path(work) / f"{p['name']}.osm.pbf").exists()]
    Path(res).mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(jobs) as ex:
        for r in ex.map(build_one, [(p, work, res) for p in pts]):
            print(*r)


def pct(a, q):
    a = sorted(a)
    return a[min(len(a) - 1, int(q * len(a)))] if a else None


def pearson(x, y):
    n = len(x)
    if n < 3:
        return None
    mx, my = sum(x) / n, sum(y) / n
    sx = sum((a - mx) ** 2 for a in x) ** .5
    sy = sum((b - my) ** 2 for b in y) ** .5
    return sum((a - mx) * (b - my) for a, b in zip(x, y)) / (sx * sy) if sx and sy else None


def stats(a):
    return {"n": len(a), "mean": round(sum(a) / len(a)) if a else None, "median": pct(a, .5),
            "p90": pct(a, .9), "max": max(a) if a else None}


def summary(pts_f, res, out):
    pts = {p["name"]: p for p in json.loads(Path(pts_f).read_text())}
    rows = []
    for f in sorted(Path(res).glob("*.json")):
        d = json.loads(f.read_text())
        p = pts.get(f.stem)
        if not p:
            continue
        tl = {}
        for j, i in p["tiles"]:
            t = d["tiles"].get(f"{j},{i}")
            if t:
                tl[f"{j},{i}"] = t
        rows.append({"name": f.stem, "kind": p["kind"], "country": p.get("country"), "tiles": tl})
    outd = {}
    for grp, sel in (("все", lambda r: True), ("без городов", lambda r: r["kind"] != "city"),
                     ("города", lambda r: r["kind"] == "city")):
        T = [t for r in rows if sel(r) for t in r["tiles"].values()]
        if not T:
            continue

        def z(t, *ss):
            return sum(t["streams_zstd"].get(s, 0) for s in ss)
        o = {"tiles": len(T)}
        for nm, ss in (("roads", ("roads",)), ("track", ("track",)), ("bpoly", ("bpoly",)), ("brect", ("brect",)),
                       ("roads+track+brect", ("roads", "track", "brect")),
                       ("roads+brect", ("roads", "brect")), ("roads+track+bpoly", ("roads", "track", "bpoly"))):
            o[nm] = {"B_per_tile": stats([z(t, *ss) for t in T]),
                     "B_per_km2": stats([round(z(t, *ss) / t["area_km2"], 1) for t in T])}
        for nm, ss in (("roads+brect", ("roads", "brect")), ("roads+track+brect", ("roads", "track", "brect")),
                       ("roads+track+bpoly", ("roads", "track", "bpoly"))):
            o["startup_9tiles_" + nm] = stats([sum(z(t, *ss) for t in r["tiles"].values())
                                                for r in rows if sel(r) and len(r["tiles"]) == 9])
        a = [z(t, "roads") for t in T]
        b = [z(t, "track") for t in T]
        la = [t["len_km"]["roads"] for t in T]
        lb = [t["len_km"]["track"] for t in T]
        o["corr_bytes_roads_track"] = pearson(a, b)
        o["corr_len_roads_track"] = pearson(la, lb)
        s = [x + y for x, y in zip(a, b)]
        o["roads_B"], o["track_B"], o["sum_B"] = stats(a), stats(b), stats(s)
        o["cv"] = {k: round((sum((v - sum(x) / len(x)) ** 2 for v in x) / len(x)) ** .5 / (sum(x) / len(x)), 2)
                   for k, x in (("roads", a), ("track", b), ("sum", s)) if x and sum(x)}
        tot = sum(t["buildings"].get("total", 0) for t in T) or 1
        o["buildings_total"] = tot
        for k in ("with_height", "with_levels_only", "with_height_or_levels", "rect_bad_iou<0.8",
                  "rect_bad_iou<0.9"):
            o["share_" + k] = round(sum(t["buildings"].get(k, 0) for t in T) / tot, 4)
        outd[grp] = o
    outd["points"] = [{"name": r["name"], "kind": r["kind"], "country": r["country"],
                       "tiles_B_roads_track_brect": {k: sum(t["streams_zstd"][s] for s in ("roads", "track", "brect"))
                                                      for k, t in r["tiles"].items()}} for r in rows]
    Path(out).write_text(json.dumps(outd, ensure_ascii=False, indent=1))
    print(json.dumps({k: v for k, v in outd.items() if k != "points"}, ensure_ascii=False)[:3000])


if __name__ == "__main__":
    c, a = sys.argv[1], sys.argv[2:]
    kw = {x.split("=")[0]: x.split("=")[1] for x in a if x.startswith("--")}
    pos = [x for x in a if not x.startswith("--")]
    if c == "points":
        points(pos[0], int(kw.get("--seed", 1)), int(kw.get("--per-country", 5)))
    elif c == "extract":
        extract(pos[0], pos[1], pos[2], set(kw["--only"].split(",")) if "--only" in kw else None)
    elif c == "build":
        build(pos[0], pos[1], pos[2], int(kw.get("--jobs", 8)))
    elif c == "summary":
        summary(*pos)
