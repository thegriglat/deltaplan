"""Прогон WindNinja (массосогласованный) по всем случаям и DEM; время каждого пишется в out/runs.json.
Запуск (под замком процессора): dp lock cpu windninja -- python run.py [--dems d400,d100,d50] [--veg grass] [--tag mass]
python — любой (нужен только stdlib)."""
import argparse, json, subprocess, time, re
from pathlib import Path
from common import *

ap = argparse.ArgumentParser()
ap.add_argument("--dems", default="d400,d100")
ap.add_argument("--veg", default="grass")
ap.add_argument("--tag", default="mass")
ap.add_argument("--heights", default="60")
ap.add_argument("--only", default="")
ap.add_argument("--ver", default="3.13", help="3.13 (conda-forge) | 4.0 (сборка из исходников)")
ap.add_argument("--flat", action="store_true", help="плоский DEM (недеформированный приток)")
ap.add_argument("--threads", type=int, default=10)
a = ap.parse_args()
cases = json.load(open(OUT / "cases.json"))["cases"]
RES = {"d400": 400, "d100": 100, "d50": 50}
log = OUT / f"runs_{a.tag}.json"
res = json.loads(log.read_text()) if log.exists() else {}
for c in cases:
    if a.only and c["id"] not in a.only.split(","):
        continue
    for dem in a.dems.split(","):
        for hgt in a.heights.split(","):
            key = f"{c['id']}|{dem}|{hgt}"
            od = WORK / "out" / a.tag / dem / hgt / c["id"]
            if key in res and (od / "done").exists():
                continue
            od.mkdir(parents=True, exist_ok=True)
            cmd = [wn_bin(a.ver), "--num_threads", str(a.threads),
                   "--elevation_file", str(WORK / "dem" / f"{'flat' if a.flat else c['loc']}_{dem}.asc"),
                   "--initialization_method", "domainAverageInitialization",
                   "--input_speed", str(c["U10"]), "--input_speed_units", "mps", "--input_direction", str(c["wdir"]),
                   "--input_wind_height", "10", "--units_input_wind_height", "m",
                   "--output_wind_height", hgt, "--units_output_wind_height", "m", "--output_speed_units", "mps",
                   "--vegetation", a.veg, "--mesh_resolution", str(RES[dem]), "--units_mesh_resolution", "m",
                   "--write_ascii_output", "true", "--ascii_out_uv", "true", "--output_path", str(od)]
            t = time.time()
            p = subprocess.run(cmd, capture_output=True, text=True, env=wn_env(a.ver))
            wall = time.time() - t
            m = re.search(r"Total simulation time was ([\d.]+)", p.stdout)
            res[key] = dict(wall=wall, sim=float(m.group(1)) if m else None, rc=p.returncode)
            if m:
                (od / "done").write_text("ok")
            else:
                (od / "err.txt").write_text(p.stdout + p.stderr)
            print(key, res[key], flush=True)
            log.write_text(json.dumps(res, indent=1))
