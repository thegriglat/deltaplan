"""SWG-7: вихревой лист над мёртвой зоной на плотных точках SWG1 и мачтах (группами фокуса, как SWG-1/SWG-4) → out/swg-7/raw/.

  py -m sheet.run points [--case C]   # s по вариантам в точках → raw/pts_<case>.json (готовое пропускает; --force)
  py -m sheet.run assemble            # ground.json (SWG2) + tables.md
  py -m sheet.run all
"""
from __future__ import annotations

import json
import sys
import time

import numpy as np

from ground import common as K
from ground import evaluate as E
from ground import model as M
from wake.run import make_grid           # геометрия SWG-4 (WakeGrid, gate "slope") — только импорт
import filaments3d as F

from . import core as SH

OUT = K.SG / "out" / "swg-7"
RAW = OUT / "raw"
VARS = ("rest", "cpb")


def geom_stats(geo):
    hs = [q["hmax"] for q in geo.segs]
    return dict(n_segs=len(geo.segs), n_nodes=geo.n_nodes, ds_sheet=geo.ds,
                hmax_median=float(np.median(hs)) if hs else None,
                L_median=float(np.median([q["s_r"] - q["s_s"] for q in geo.segs])) if geo.segs else None)


def cmd_points(force=False, nmax=40, cases=K.CASES):
    refs = E.load_refs()
    pts = json.load(open(K.OUT_POINTS))
    for case in cases:
        f = RAW / f"pts_{case}.json"
        if f.exists() and not force:
            continue
        t0 = time.time()
        grid = make_grid(case, "slope")
        geo = SH.SheetGeom(grid, M.C.load_terrain(case, M.C.SMOOTH_MAIN)[0])
        pl = E.case_points(case, refs, pts)
        nm = refs["norm"][case]
        ng, gid = E.kd_groups(pl, nmax)
        n = len(pl)
        keys = ["s_pot", "s_jh", "A", "dS", "zone_h", "under"]
        for v in VARS:
            keys += [f"s_{v}", f"s_{v}_zone", f"spw_{v}", f"dSw_{v}", f"dS_{v}"]
        res = {k: np.full(n, np.nan) for k in keys}
        groups = []
        for g in range(ng):
            sel = [i for i in range(n) if gid[i] == g]
            xy = [(pl[i]["x"], pl[i]["y"]) for i in sel] + [(nm["x"], nm["y"])]
            run = M.GRun(case, xy)
            X = np.array([pl[i]["x"] for i in sel] + [nm["x"]])
            Y = np.array([pl[i]["y"] for i in sel] + [nm["y"]])
            Z = np.array([pl[i]["z_agl"] for i in sel] + [nm["z_agl"]])
            Xa, Ya, Za = run.abs_points(X, Y, Z)
            p = M.jh_parts(run, Xa, Ya, Za)
            res["s_pot"][sel] = p["pot_speed"][:-1] / p["pot_speed"][-1]
            res["s_jh"][sel] = p["speed"][:-1] / p["speed"][-1]
            res["A"][sel] = p["A"][:-1]
            res["dS"][sel] = p["dS"][:-1]
            ginfo = dict(N=run.N, n=len(sel))
            for v in VARS:
                tv = time.time()
                sh = SH.Sheet(run, geo, v)
                ps = SH.sheet_parts(run, Xa, Ya, Za, sh)
                res[f"s_{v}"][sel] = ps["speed"][:-1] / ps["speed"][-1]
                res[f"s_{v}_zone"][sel] = ps["zone_speed"][:-1] / ps["zone_speed"][-1]
                res[f"spw_{v}"][sel] = ps["potw_speed"][:-1] / ps["potw_speed"][-1]
                res[f"dSw_{v}"][sel] = ps["dS_w"][:-1]
                res[f"dS_{v}"][sel] = ps["dS"][:-1]
                res["zone_h"][sel] = ps["zone_h"][:-1]
                res["under"][sel] = ps["under"][:-1].astype(float)
                inf = {k: sh.info[k] for k in sh.info if k != "hist"}
                inf.update(hist=[round(h, 6) for h in sh.info["hist"]], t_s=time.time() - tv,
                           imbalance=F.imbalance(sh.fil) if len(sh.fil.seg) else 0.0,
                           norm_ratio=float(ps["speed"][-1] / p["speed"][-1]),
                           norm_under=bool(ps["under"][-1]))
                ginfo[v] = inf
                del sh
            groups.append(ginfo)
            run.free()
            run.panels._geom = None
            print(case, f"группа {g + 1}/{ng}", "N", run.N, "итераций", ginfo["rest"]["iters"],
                  f"{time.time() - t0:.0f} с", flush=True)
        out = {k: [None if not np.isfinite(x) else float(x) for x in a] for k, a in res.items()}
        out["ids"] = [p["id"] for p in pl]
        out["groups"] = groups
        out["geom"] = geom_stats(geo)
        out["t_s"] = time.time() - t0
        K.dump_json(f, out)


if __name__ == "__main__":
    args = sys.argv[1:]
    force = "--force" in args
    cases = K.CASES
    if "--case" in args:
        i = args.index("--case")
        cases = (args[i + 1],)
        del args[i:i + 2]
    args = [a for a in args if a != "--force"]
    cmd = args[0] if args else ""
    if cmd in ("points", "all"):
        cmd_points(force, cases=cases)
    if cmd in ("assemble", "all"):
        from . import assemble as A
        A.main()
    if cmd not in ("points", "assemble", "all"):
        print(__doc__)
