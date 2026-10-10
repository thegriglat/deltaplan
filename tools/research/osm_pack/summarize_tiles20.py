"""Сводка по Словении: python -I summarize_tiles20.py results/tiles20_slovenia.json results/tiles20_slovenia_summary.json"""
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from stage2 import pearson, stats  # noqa: E402

d = json.loads(Path(sys.argv[1]).read_text())
tiles = d["tiles"]
ST = ("roads", "track", "bpoly", "brect")


def z(t, *s):
    return sum(t["streams_zstd"][x] for x in s)


def table(T):
    o = {"tiles": len(T)}
    for nm, ss in (("roads", ("roads",)), ("track", ("track",)), ("bpoly", ("bpoly",)), ("brect", ("brect",)),
                   ("roads+brect", ("roads", "brect")), ("roads+bpoly", ("roads", "bpoly")),
                   ("roads+track+brect", ("roads", "track", "brect")),
                   ("roads+track+bpoly", ("roads", "track", "bpoly"))):
        o[nm] = {"B_per_tile": stats([z(t, *ss) for t in T]),
                 "B_per_km2": stats([round(z(t, *ss) / t["area_km2"], 1) for t in T])}
    return o


inside = [t for t in tiles.values() if t.get("inside")]
allt = list(tiles.values())
out = {"tiles_total": len(allt), "tiles_inside": len(inside), "inside": table(inside), "all": table(allt)}
tot = {s: sum(t["streams_zstd"][s] for t in allt) for s in ST}
out["country_total_B"] = tot
out["country_total_B"]["roads+brect"] = tot["roads"] + tot["brect"]
out["country_total_B"]["roads+track+brect"] = tot["roads"] + tot["track"] + tot["brect"]
out["country_total_B"]["roads+bpoly"] = tot["roads"] + tot["bpoly"]
out["country_total_B"]["roads+track+bpoly"] = tot["roads"] + tot["track"] + tot["bpoly"]
out["n_buildings"] = sum(t["n_buildings"] for t in allt)
out["len_km"] = {s: round(sum(t["len_km"][s] for t in allt)) for s in ("roads", "track")}
out["B_per_building"] = {"bpoly": round(tot["bpoly"] / out["n_buildings"], 2),
                         "brect": round(tot["brect"] / out["n_buildings"], 2)}
out["B_per_km_road"] = {s: round(tot[s] / out["len_km"][s]) for s in ("roads", "track")}
for nm, T in (("all", allt), ("inside", inside)):
    a = [z(t, "roads") for t in T]
    b = [z(t, "track") for t in T]
    s = [x + y for x, y in zip(a, b)]
    la = [t["len_km"]["roads"] for t in T]
    lb = [t["len_km"]["track"] for t in T]
    cv = lambda x: round((sum((v - sum(x) / len(x)) ** 2 for v in x) / len(x)) ** .5 / (sum(x) / len(x)), 2)
    out["roads_vs_track_" + nm] = {"corr_bytes": pearson(a, b), "corr_len": pearson(la, lb),
                                    "roads": stats(a), "track": stats(b), "sum": stats(s),
                                    "cv": {"roads": cv(a), "track": cv(b), "sum": cv(s)}}
# 9 тайлов подряд (3x3 вокруг тайла, все внутри): окно загрузки
byk = {tuple(map(int, k.split(","))): t for k, t in tiles.items()}
win = []
for (j, i), t in byk.items():
    nb = [byk.get((j + dj, i + di)) for dj in (-1, 0, 1) for di in (-1, 0, 1)]
    if all(n is not None and n.get("inside") for n in nb):
        win.append(nb)
out["window3x3_inside"] = {"n": len(win)}
for nm, ss in (("roads+brect", ("roads", "brect")), ("roads+track+brect", ("roads", "track", "brect")),
               ("roads+track+bpoly", ("roads", "track", "bpoly"))):
    out["window3x3_inside"][nm] = stats([sum(z(t, *ss) for t in w) for w in win])
b = d["buildings"]
out["buildings"] = {**b, **{"share_" + k: round(b[k] / b["total"], 4) for k in
                            ("with_height", "with_levels_only", "with_height_or_levels",
                             "rect_bad_iou<0.8", "rect_bad_iou<0.9")}}
out["time"] = {"t_parse_s": d["t_parse_s"], "t_encode_s": d["t_encode_s"], "maxrss_MB": d["maxrss_MB"]}
Path(sys.argv[2]).write_text(json.dumps(out, ensure_ascii=False, indent=1))
print(json.dumps(out, ensure_ascii=False, indent=1))
