"""Алматы: тайлы мировой сетки 20 км, 5×5 вокруг точки (и центральные 3×3).
    python -I almaty.py <kazakhstan.osm.pbf> <work_dir> <res.json>
"""
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import stage2 as s  # noqa: E402
from build_tiles20 import tile_of  # noqa: E402

src, work, res = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
work.mkdir(parents=True, exist_ok=True)
lat, lon = 43.24, 76.89
t5, t3 = s.block(lon, lat, 2), s.block(lon, lat, 1)
bb = s.bbox_of(t5)
H = Path(__file__).parent
x, hb = work / "almaty.osm.pbf", work / "almaty.hb.pbf"
subprocess.run(["osmium", "extract", "-O", "-s", "smart", "-b", ",".join(map(str, bb)), "-o", str(x), src], check=True)
subprocess.run(["osmium", "tags-filter", "-O", "-o", str(hb), str(x), "w/highway", "wr/building"], check=True)
want = ";".join(f"{j},{i}" for j, i in t5)
rj = work / "tiles.json"
subprocess.run([sys.executable, "-I", str(H / "build_tiles20.py"), str(hb), str(rj), f"--want={want}"], check=True)
pj = work / "pilot.json"
subprocess.run([sys.executable, "-I", str(H / "build_pilot20.py"), str(x), str(pj), f"--want={want}"], check=True)
d = json.loads(rj.read_text())
pil = json.loads(pj.read_text())


def tot(ts):
    T = [d["tiles"][f"{j},{i}"] for j, i in ts if f"{j},{i}" in d["tiles"]]
    r = {"tiles": len(T)}
    for k, ss in (("roads+brect", ("roads", "brect")), ("roads+track+brect", ("roads", "track", "brect")),
                  ("roads+track+bpoly", ("roads", "track", "bpoly")), ("roads", ("roads",)), ("track", ("track",)),
                  ("bpoly", ("bpoly",)), ("brect", ("brect",))):
        r[k] = sum(t["streams_zstd"][x_] for t in T for x_ in ss)
    P = [pil["tiles"][f"{j},{i}"]["zstd"] for j, i in ts if f"{j},{i}" in pil["tiles"]]
    r["pilot"] = {k: sum(p[k] for p in P) for k in (P[0] if P else {})}
    r["buildings"] = sum(t["n_buildings"] for t in T)
    return r


out = {"center": [lat, lon], "bbox": bb, "center_tile": list(tile_of(lon, lat)),
       "window3x3": tot(t3), "window5x5": tot(t5), "tiles": d["tiles"], "pilot_tiles": pil["tiles"], "pilot_counts": pil["counts"], "buildings": d["buildings"],
       "t_parse_s": d["t_parse_s"], "maxrss_MB": d["maxrss_MB"]}
res.write_text(json.dumps(out, ensure_ascii=False, indent=1))
print(json.dumps({k: v for k, v in out.items() if k != "tiles"}, ensure_ascii=False))
