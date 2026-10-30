"""PR-12: builds out/final/summary.json from the R2 results and R4 states written by out/final/run.sh.

    python3 -I summarize_final.py --out summary.json

Reads <final>/{cold_tol*,warm_tol*,coldh_tol*}/*.json (R2 v3), base R2 from out/base/ (PR-1), states from
~/data/air_cascade/picard_rs/final/. Region fields and thresholds are reused from PR-8 (fields.py, threshold.json).
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fields as F  # noqa: E402

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
FIN = ROOT / "out/final"
BASE = ROOT / "out/base"
DATA = Path.home() / "data/air_cascade/ongudai"
ST = Path.home() / "data/air_cascade/picard_rs/final"
CASES = ["u3_heat", "u3_mech", "u0_heat", "u6_heat"]
THREADS = [2, 3, 6, 8]
W_THERMAL = 0.75
RECOMPUTE_GAME_MIN = 15.0
SPEEDS = [1, 10, 60]   # configs/world.json:44 time.speed, :46 speed_options (x1, x10, x60)


def jl(p):
    return json.loads(Path(p).read_text())


def row(p):
    """Compact view of one R2 file, or None when it does not exist."""
    p = Path(p)
    if not p.exists():
        return None
    d = jl(p)
    t = d["time"]
    return dict(iters=int(d["iters"]), stop=d.get("stop"), status=d["status"], total_s=float(t["total_s"]),
                ms_per_iter=float(t["ms_per_iter"]), setup_s=float(t.get("setup_s", 0.0)), iter_s=float(d["residuals"]["t_s"]) if "residuals" in d else None,
                phase_ms=t.get("phase_ms"))


def by_threads(fmt):
    return {str(t): row(fmt.format(t=t)) for t in THREADS}


def ratio(a, b):
    return None if a is None or b is None or b == 0 else a / b


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    host = jl(FIN / "cold_tol5/ongudai_d400_u3_heat_release_t8.json")["host"]
    before_after, table_cold = {}, {}
    for c in CASES:
        n = f"ongudai_d400_{c}"
        before_after[c], table_cold[c] = {}, {}
        for t in THREADS:
            b, r1, r5 = row(BASE / f"{n}_release_t{t}.json"), row(FIN / f"cold_tol1/{n}_release_t{t}.json"), row(FIN / f"cold_tol5/{n}_release_t{t}.json")
            before_after[c][str(t)] = dict(
                base_total_s=b and b["total_s"], tol1_total_s=r1["total_s"], tol5_total_s=r5["total_s"],
                base_ms_per_iter=b and b["ms_per_iter"], ms_per_iter=r1["ms_per_iter"], ms_per_iter_tol5=r5["ms_per_iter"],
                base_iters=b and b["iters"], iters=r1["iters"], iters_tol5=r5["iters"],
                speedup_tol1_vs_base=ratio(b and b["total_s"], r1["total_s"]),
                speedup_tol5_vs_base=ratio(b and b["total_s"], r5["total_s"]))
            table_cold[c][str(t)] = dict(tol1=r1, tol5=r5)
    # warm vs cold at h1215 / h1230 (start of the chain is cold h1200)
    table_warm = {}
    recompute_s = {str(s): RECOMPUTE_GAME_MIN * 60.0 / s for s in SPEEDS}
    for h in ("h1215", "h1230"):
        n = f"ongudai_d400_u3_heat_{h}"
        table_warm[h] = {}
        for X in (1, 5):
            table_warm[h][f"tol{X}"] = {}
            for t in THREADS:
                w, c = row(FIN / f"warm_tol{X}/{n}_release_t{t}.json"), row(FIN / f"coldh_tol{X}/{n}_release_t{t}.json")
                table_warm[h][f"tol{X}"][str(t)] = dict(
                    warm=w, cold=c, iters_ratio=ratio(w["iters"], c["iters"]), total_s_ratio=ratio(w["total_s"], c["total_s"]),
                    share_of_recompute_period={s: w["total_s"] / recompute_s[s] for s in recompute_s})
    # chain deviations: warm (tol 5 and tol 1) against cold converged (tol 1) of the same time
    thr = jl(HERE / "threshold.json")
    chain = dict(recompute_period_real_s=recompute_s,
                 recompute_source="configs/atmosphere.json:321 recompute_game_min=15 game min; real seconds = 900 / clock speed; "
                                  "configs/world.json:44 time.speed=1 (default), :46 speed_options; scripts/world/sun_clock.gd:80 hour += dt*speed/3600; "
                                  "network: speed locked to 1 (scripts/game/game.gd:1419)",
                 threshold=dict(launch_dw_max=thr["launch_dw_max"], launch_du_max=thr["launch_du_max"], slopes_dw_max=thr["slopes_dw_max"],
                                thermals_dw_max=0.1, note="slopes: PR-8 judged along-terrain dwt; both dw and dwt reported; thermals 0.1 m/s from the PR-12 task"),
                 regions={}, series={})
    for h in ("h1215", "h1230"):
        n = f"ongudai_d400_u3_heat_{h}"
        geom = F.Geometry(DATA / f"{n}.json")
        ref = F.load_uvw(ST / f"C{h[1:]}_1.json", geom)
        masks = geom.masks(ref["w"], W_THERMAL)
        chain["n_cells_" + h] = {k: int(v.sum()) for k, v in masks.items()}
        chain["series"][h] = {}
        for label, state in (("warm_tol5", f"W{h[1:]}_5"), ("warm_tol1", f"W{h[1:]}_1"), ("cold_tol5", f"C{h[1:]}_5")):
            f = F.load_uvw(ST / f"{state}.json", geom)
            dev = F.deviation(f, ref, masks, geom)
            chain["series"][h][label] = dict(
                dev={k: {kk: vv for kk, vv in v.items()} for k, v in dev.items()}, flows=F.flows(f, ref, masks, geom))
    s5 = chain["series"]["h1230"]["warm_tol5"]["dev"]
    chain["verdict_h1230_warm_tol5"] = dict(
        launch_dw_max=s5["launch"]["dw_max"], launch_du_max=s5["launch"]["du_max"],
        slopes_dw_max=s5["slopes"]["dw_max"], slopes_dwt_max=s5["slopes"]["dwt_max"], thermals_dw_max=s5["thermals"]["dw_max"],
        launch_dw_ok=s5["launch"]["dw_max"] <= thr["launch_dw_max"], launch_du_ok=s5["launch"]["du_max"] <= thr["launch_du_max"],
        slopes_dwt_ok=s5["slopes"]["dwt_max"] <= thr["slopes_dw_max"], thermals_dw_ok=s5["thermals"]["dw_max"] <= 0.1)
    chain["regions"] = {k: v for k, v in jl(ROOT / "out/residual/PR-8/summary.json")["regions"].items()}
    d = dict(version=1, host=dict(git=host["git"], cpu=host["cpu"]), git=host["git"], before_after=before_after, table_cold=table_cold,
             table_warm=table_warm, chain=chain)
    Path(a.out).write_text(json.dumps(d, indent=1, ensure_ascii=False) + "\n")
    print("wrote", a.out)


if __name__ == "__main__":
    main()
