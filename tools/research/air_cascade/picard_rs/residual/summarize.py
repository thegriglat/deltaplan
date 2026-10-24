"""PR-8: builds summary.json (R7 v1) from the R2 results and R4 snapshots written by run.sh.

    python3 -I summarize.py --out summary.json [--floor-out floor.json]

Reads  <out>/r2/*.json  (R2 v3, in git), states and snapshots in ~/data/air_cascade/picard_rs/residual/PR-8/,
cases in ~/data/air_cascade/ongudai/. Threshold block comes from threshold.json beside this script.
"""
import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fields as F  # noqa: E402

HOME = Path.home()
DATA = HOME / "data/air_cascade/ongudai"
ST = HOME / "data/air_cascade/picard_rs/residual/PR-8"
HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "out/residual/PR-8"
COLD = ["ongudai_d400_u3_heat", "ongudai_d400_u3_mech", "ongudai_d400_u0_heat", "ongudai_d400_u6_heat"]
COLD_N = [30, 50, 100, 150]
WARM_N = [10, 20, 30, 50]
TOLS = [3, 10, 30]
TOLS_COLD = [3, 5, 7, 10, 30]   # 5 and 7 are extra
W_THERMAL = 0.75     # m/s, see README: ~p99 of the mechanical w in non-slope columns, 10-400 m agl
RES = ("mom_rms", "div_rms", "th_rms")

REGION_TEXT = {
    "domain": "All fluid cells (cell type 1) of the case, halo excluded; includes the side and top sponge layers.",
    "launch": f"Fluid cells in the R1 `crop` window (16x16 columns around the launch, as in export_ongudai.py:check_field), "
              f"up to {F.LAUNCH_AGL_MAX:.0f} m above terrain (check_field takes all levels; the pilot layer is below 400 m).",
    "agl_10_50": "Fluid cells whose centre is 10 <= h < 50 m above the terrain height hc of the column (centre z = z_bot + (k+0.5)dz).",
    "agl_50_100": "Fluid cells whose centre is 50 <= h < 100 m above the terrain height hc of the column.",
    "agl_100_200": "Fluid cells whose centre is 100 <= h < 200 m above the terrain height hc of the column.",
    "agl_200_400": "Fluid cells whose centre is 200 <= h < 400 m above the terrain height hc of the column.",
    "thermals": f"Fluid cells 10-400 m above terrain, outside `slopes` columns, where the REFERENCE w >= {W_THERMAL} m/s "
                f"(about the 99.3rd percentile of w of the mechanical u3_mech case in the same cells; heat cases have "
                f"~3x more such cells, so the region is the strong-updraft cores, thermals in heat cases). "
                f"Same rule for every case; mech has mechanical updrafts there.",
    "slopes": f"Fluid cells 10-400 m above terrain in columns with terrain slope norm(grad hc) >= {F.SLOPE_MIN} "
              f"(central differences on the 400 m grid, ~17 deg; upper quintile of Ongudai columns, median 0.22). "
              f"The lowest fluid cell (agl < 105 m) has w = 0 by the staggering, so raw dw there is 0; `dwt_*` adds "
              f"the along-terrain term u*hx + v*hy.",
}


def jl(p):
    return json.loads(Path(p).read_text())


def hist_time(hist, n):
    """Wall time (s) of iteration n from the R2 history (linear in iterations between check records)."""
    its = np.array([h["it"] for h in hist], float)
    ts = np.array([h["t_s"] for h in hist], float)
    if n <= its[0]:
        return float(ts[0] * n / its[0])
    return float(np.interp(n, its, ts))


def hist_record(hist, n):
    """Residual record of iteration n, or of the first check after it (the snapshot has no own check)."""
    for h in hist:
        if h["it"] >= n:
            return h
    return hist[-1]


def res3(r):
    return {k: float(r[k]) for k in RES}


def point_common(by, n, tol, t_s, res, dev, fl, **extra):
    return dict(by=by, N=int(n), tol_scale=None if tol is None else float(tol), t_s=float(t_s),
                residuals=res3(res), dev={k: {kk: vv for kk, vv in v.items() if kk != "n_cells"} for k, v in dev.items()},
                flows=fl, **extra)


def make_series(case, start, warm_from, ref_state, ref_r2, time_ref, pts_spec, masks_cache):
    geom, ref, masks = masks_cache
    rr = jl(ref_r2)
    tr = jl(time_ref)
    ser = dict(case=case, start=start, warm_from=warm_from,
               ref=dict(iters=int(rr["iters"]), t_s=float(tr["residuals"]["t_s"]), residuals=res3(rr["residuals"])),
               n_cells={k: int(v.sum()) for k, v in masks.items()}, points=[])
    for spec in pts_spec:
        r2 = jl(spec["r2"])
        if spec["by"] == "iter":
            n = spec["N"]
            if n >= rr["iters"] or n > r2["iters"]:
                continue
            rec = hist_record(r2["history"], n)
            f = F.load_uvw(spec["state"], geom)
            ser["points"].append(point_common(
                "iter", n, None, hist_time(jl(spec["time"])["history"], n), rec, F.deviation(f, ref, masks, geom), F.flows(f, ref, masks, geom),
                res_it=int(rec["it"]), state=os.path.basename(spec["state"])))
        else:
            f = F.load_uvw(spec["state"], geom)
            ser["points"].append(point_common(
                "tol_scale", r2["iters"], spec["tol"], r2["residuals"]["t_s"], r2["residuals"],
                F.deviation(f, ref, masks, geom), F.flows(f, ref, masks, geom), stop=r2["stop"], status=r2["status"]))
    return ser


def floor_block(case):
    """Deviation of the converged f32 reference field from the f64 reference solution (sol_*) of the case."""
    meta, arr = F.read_pair(DATA / f"{case}.json", ("sol_u", "sol_v", "sol_w", "sol_th"))
    geom = F.Geometry(DATA / f"{case}.json")
    nzh, nyh, nxh = geom.dims
    sol = {k[4:]: F.interior(a, nzh, nyh, nxh).astype(np.float64) for k, a in arr.items()}
    f = F.load_uvw(ST / f"{case}_ref.json", geom)
    f64 = dict(sol)
    masks = geom.masks(sol["w"], W_THERMAL)
    masks["crop_all_levels"] = geom.fluid & geom.crop[None]
    dev = F.deviation(f, f64, masks, geom)
    th = np.abs(f["th"] - sol["th"])
    m = masks["crop_all_levels"]
    deep = ST / f"{case}_deep.json"
    ref_vs_deep = None
    if deep.exists():
        g = F.load_uvw(deep, geom)
        r = F.load_uvw(ST / f"{case}_ref.json", geom)
        ref_vs_deep = F.deviation(r, g, geom.masks(g["w"], W_THERMAL), geom)
    return dict(dev=dev, ref_vs_deep=ref_vs_deep, th_abs_max_crop=float(th[m].max()), th_abs_max_domain=float(th[geom.fluid].max()),
                u_scale_note="export_ongudai.py FIELD_TOL = 1e-3*u_scale, THETA_TOL = 0.05 K")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    r2d = OUT / "r2"
    regions, series = REGION_TEXT, []
    floors = {}
    for case in COLD:
        geom = F.Geometry(DATA / f"{case}.json")
        ref = F.load_uvw(ST / f"{case}_ref.json", geom)
        masks = geom.masks(ref["w"], W_THERMAL)
        spec = [dict(by="iter", N=n, r2=r2d / f"ref/{case}_release_t8.json", time=r2d / f"{case}_time_t8.json", state=ST / f"{case}_snap/{case}_it{n}.json")
                for n in COLD_N]
        spec += [dict(by="tol_scale", tol=t, r2=r2d / f"{case}_tol{t}_t8.json", state=ST / f"{case}_tol{t}.json")
                 for t in TOLS_COLD]
        series.append(make_series(case, "cold", None, None, r2d / f"ref/{case}_release_t8.json", r2d / f"{case}_time_t8.json", spec, (geom, ref, masks)))
        floors[case] = floor_block(case)
    a_, b_ = "ongudai_d400_u3_heat_h1200", "ongudai_d400_u3_heat_h1215"
    geom = F.Geometry(DATA / f"{b_}.json")
    ref = F.load_uvw(ST / f"{b_}_ref.json", geom)
    masks = geom.masks(ref["w"], W_THERMAL)
    wr = f"{b_}_warm_ref"
    spec = [dict(by="iter", N=n, r2=r2d / f"{b_}_warm_ext_t8.json", time=r2d / f"{b_}_warm_time_t8.json", state=ST / f"{b_}_warm_snap/{b_}_it{n}.json") for n in WARM_N]
    spec += [dict(by="tol_scale", tol=t, r2=r2d / f"{b_}_warm_tol{t}_t8.json", state=ST / f"{b_}_warm_tol{t}.json")
             for t in TOLS]
    spec.append(dict(by="tol_scale", tol=1, r2=r2d / f"{wr}_t8.json", state=ST / f"{wr}.json"))
    ws = make_series(b_, "warm", a_, None, r2d / f"{b_}_ref_t8.json", r2d / f"{b_}_ref_t8.json", spec, (geom, ref, masks))
    series.append(ws)
    # warm start before the first residual check: fields only (no residual exists), and the 15-minute field change
    early = []
    for n in (2, 4, 6, 8):
        f = F.load_uvw(ST / f"{b_}_warm_snap/{b_}_it{n}.json", geom)
        early.append(dict(N=n, dev=F.deviation(f, ref, masks, geom)))
    f0 = F.load_uvw(ST / f"{a_}_ref.json", geom)
    start_field = F.deviation(f0, ref, masks, geom)
    floors[b_] = floor_block(b_)

    host = jl(r2d / "ref/ongudai_d400_u3_heat_release_t8.json")["host"]
    th = jl(HERE / "threshold.json")
    d = dict(version=1, threads=8, host=dict(git=host["git"], cpu=host["cpu"]), regions=regions,
             w_thermal_ms=W_THERMAL, slope_min=F.SLOPE_MIN, series=series, floor=floors, warm_early=early, warm_init_vs_ref=start_field, threshold=th)
    Path(a.out).write_text(json.dumps(d, indent=1, ensure_ascii=False) + "\n")
    print("wrote", a.out)


if __name__ == "__main__":
    main()
