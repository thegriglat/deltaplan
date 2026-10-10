"""Проверка конвейера этапа 2 на Словении (вырез из slovenia pbf вместо planet).
    python -I test_stage2.py <slovenia-latest.osm.pbf> <work_dir>
"""
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import stage2 as s  # noqa: E402

src, work = sys.argv[1], Path(sys.argv[2])
work.mkdir(parents=True, exist_ok=True)
pts = []
for n, k, la, lo in [("t_bovec", "location", 46.33, 13.55), ("t_ljubljana", "city", 46.05, 14.5),
                     ("t_murska", "takeoff", 46.66, 16.17)]:
    tl = s.block(lo, la)
    pts.append({"name": n, "kind": k, "lat": la, "lon": lo, "tiles": tl, "bbox": s.bbox_of(tl)})
pf = work / "points.json"
pf.write_text(json.dumps(pts))
H = Path(__file__).parent
for cmd in (["extract", src, str(pf), str(work / "x")],
            ["build", str(pf), str(work / "x"), str(work / "res"), "--jobs=3"],
            ["summary", str(pf), str(work / "res"), str(work / "sum.json")]):
    subprocess.run([sys.executable, "-I", str(H / "stage2.py")] + cmd, check=True)
