#!/usr/bin/env python3
"""SY-12: сверка h400 конвейера П6 (pack_hg2.py) с игрой из main (godot headless, AirPlace.block_mean, C2 v7).
Места: 4 игры + бывшие «вне слоя» (clamped_px > 0 в out/geometry.json) + 5 случайных (зерно 12). -> out/game_check_v2.json
  check_game.py [--data ~/sy12_data] [--project <копия>]   (нужно raw/ тайлов и hc400_all.npz из `pack_hg2.py pack`)"""
import argparse, json, os, subprocess, tempfile, random
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
ap = argparse.ArgumentParser()
ap.add_argument("--data", default=os.path.expanduser("~/sy12_data"))
ap.add_argument("--project", default=str(ROOT))
a = ap.parse_args()
dd = Path(a.data)
hc = np.load(dd / "hc400_all.npz")
sites = {s["site_id"]: s for s in json.loads((HERE.parent / "hg_sites/sites.json").read_text())}
for n in ["askarovo", "aushkul", "altai", "ongudai"]:
    loc = json.loads((ROOT / f"configs/locations/{n}.json").read_text())
    sites[n] = dict(site_id=n, lat=loc["center_lat"], lon=loc["center_lon"])
old = [k for k, v in json.load(open(HERE / "out/geometry.json")).items() if v["clamped_px"] > 0 and not k in ("ongudai",)]
old.append("hg_0151")   # 5-е «вне слоя» v1 (-33,69°): исключено (море), в geometry.json нет, но h400 П6 посчитан
rest = sorted(set(sites) - set(old) - {"askarovo", "aushkul", "altai", "ongudai"} - {k for k in sites if k not in hc.files})
excl = {e["site_id"] for e in json.loads((HERE / "out/excluded_v2.json").read_text())}
rest = [k for k in rest if k not in excl]
rnd = random.Random(12).sample(rest, 5)
names = ["askarovo", "aushkul", "altai", "ongudai"] + old + rnd
rows = []
env = dict(os.environ, XDG_DATA_HOME=tempfile.mkdtemp())
for n in names:
    s = sites[n]
    with tempfile.NamedTemporaryFile(suffix=".f64") as f:
        r = subprocess.run(["godot", "--headless", "--path", a.project, "res://tools/research/air_synth/hg_real/game_block_check2.tscn", "--",
                            str(s["lat"]), str(s["lon"]), str(dd / "raw"), f.name], capture_output=True, text=True, env=env)
        hdr = [l for l in r.stdout.splitlines() if l.startswith("HEADER") or l.startswith("ERROR")]
        g = np.fromfile(f.name, np.float64)
    if g.size != 96 * 96:
        rows.append(dict(site_id=n, error=(hdr or r.stderr[-300:])))
        continue
    d = np.abs(g.reshape(96, 96) - hc[n]).max()
    rows.append(dict(site_id=n, group="game" if n in ("askarovo", "aushkul", "altai", "ongudai") else "was_out_of_layer" if n in old else "random",
                     header=hdr[0], max_abs_diff_m=float(d)))
    print(rows[-1], flush=True)
ok = [r["max_abs_diff_m"] for r in rows if "max_abs_diff_m" in r]
out = dict(n_checked=len(ok), n_failed=len(rows) - len(ok), max_abs_diff_m=max(ok), places=rows)
(HERE / "out/game_check_v2.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
print('"max_abs_diff_m": %s' % out["max_abs_diff_m"])
