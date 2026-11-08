"""SWG-8: скорость зоны под листом + слой смешения на плотных точках SWG1 и мачтах (группы как SWG-7) → out/swg-8/raw/.

  py -m zone.run points [--case C] [--force]   # raw/pts_<case>.json
  py -m zone.run conv [--case PERD_NE]         # сходимость по числу листов на группах лее (raw/conv_<case>.json)
  py -m zone.run assemble                      # ground.json (SWG2) + tables.md
"""
from __future__ import annotations

import json
import sys
import time

import numpy as np

from ground import common as K
from ground import evaluate as E
from ground import model as M
from wake.run import make_grid
from sheet import core as SH
import filaments3d as F

from . import core as Z

OUT = K.SG / "out" / "swg-8"
RAW = OUT / "raw"
KEYS = ["s_pot", "s_jh", "s_thin", "s_mix", "s_zthin", "s_zone", "u_zthin", "u_zone", "ur_zthin", "ur_zone",
        "Ue_zone", "cap_zthin", "cap_zone", "zone_h", "under", "delta", "s_noclip", "A", "dS_thin", "dS_mix"]


def geom_stats(geo):
    hs = [q["hmax"] for q in geo.segs]
    return dict(n_segs=len(geo.segs), n_nodes=geo.n_nodes, ds_sheet=geo.ds,
                hmax_median=float(np.median(hs)) if hs else None,
                L_median=float(np.median([q["s_r"] - q["s_s"] for q in geo.segs])) if geo.segs else None)


def _inf(sh):
    return {k: (v if not isinstance(v, list) else [round(float(h), 6) for h in v]) for k, v in sh.info.items()}


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
        sep = Z.SepDist(geo)
        pl = E.case_points(case, refs, pts)
        nm = refs["norm"][case]
        ng, gid = E.kd_groups(pl, nmax)
        n = len(pl)
        res = {k: np.full(n, np.nan) for k in KEYS}
        groups = []
        for g in range(ng):
            sel = [i for i in range(n) if gid[i] == g]
            xy = [(pl[i]["x"], pl[i]["y"]) for i in sel] + [(nm["x"], nm["y"])]
            run = M.GRun(case, xy)
            X = np.array([pl[i]["x"] for i in sel] + [nm["x"]])
            Y = np.array([pl[i]["y"] for i in sel] + [nm["y"]])
            Zz = np.array([pl[i]["z_agl"] for i in sel] + [nm["z_agl"]])
            Xa, Ya, Za = run.abs_points(X, Y, Zz)
            p = M.jh_parts(run, Xa, Ya, Za)
            nrm = lambda a: a[:-1] / a[-1]
            res["s_pot"][sel] = nrm(p["pot_speed"])
            res["s_jh"][sel] = nrm(p["speed"])
            res["A"][sel] = p["A"][:-1]
            gi = dict(N=run.N, n=len(sel))
            tv = time.time()
            thin = SH.Sheet(run, geo, "rest")
            gi["thin"] = _inf(thin)
            gi["thin"]["t_s"] = time.time() - tv
            gi["thin"]["n_clip"] = Z.clip_count(thin)
            gi["thin"]["imbalance"] = F.imbalance(thin.fil) if len(thin.fil.seg) else 0.0
            qt = Z.zone_parts(run, Xa, Ya, Za, thin, sep, "thin")
            tv = time.time()
            mx = Z.MixSheet(thin, Z.N_LAYERS, sep=sep)
            qm = Z.zone_parts(run, Xa, Ya, Za, mx, sep, "mix")
            gi["mix"] = dict(mx.info, t_s=time.time() - tv,
                             imbalance=F.imbalance(mx.fil) if len(mx.fil.seg) else 0.0)
            for nk, q in (("thin", qt), ("mix", qm)):
                gi[nk].update(norm_ratio_sheet=float(q["speed_sheet"][-1] / p["speed"][-1]),
                              norm_ratio_zone=float(q["speed"][-1] / p["speed"][-1]), norm_under=bool(q["under"][-1]))
            res["s_thin"][sel] = nrm(qt["speed_sheet"])
            res["s_mix"][sel] = nrm(qm["speed_sheet"])
            res["s_zthin"][sel] = nrm(qt["speed"])
            res["s_zone"][sel] = nrm(qm["speed"])
            res["u_zthin"][sel] = qt["u_par"][:-1] / qt["speed"][-1]
            res["u_zone"][sel] = qm["u_par"][:-1] / qm["speed"][-1]
            res["ur_zthin"][sel] = (qt["ur"] / qt["Ue"])[:-1]
            res["ur_zone"][sel] = (qm["ur"] / qm["Ue"])[:-1]
            res["Ue_zone"][sel] = qm["Ue"][:-1] / qm["speed"][-1]
            res["cap_zthin"][sel] = qt["capped"][:-1].astype(float)
            res["cap_zone"][sel] = qm["capped"][:-1].astype(float)
            res["zone_h"][sel] = qm["zone_h"][:-1]
            res["under"][sel] = qm["under"][:-1].astype(float)
            res["delta"][sel] = qm["delta"][:-1]
            res["dS_thin"][sel] = qt["parts"]["dS"][:-1]
            res["dS_mix"][sel] = qm["parts"]["dS"][:-1]
            if gi["thin"]["n_clip"] > 0:
                tv = time.time()
                nc = Z.iterate_rest(run, geo, clip=False)
                ps = SH.sheet_parts(run, Xa, Ya, Za, nc)
                res["s_noclip"][sel] = nrm(ps["speed"])
                gi["noclip"] = dict(_inf(nc), t_s=time.time() - tv)
                del nc
            else:
                res["s_noclip"][sel] = res["s_thin"][sel]
            groups.append(gi)
            del thin, mx
            run.free()
            run.panels._geom = None
            print(case, f"группа {g + 1}/{ng}", "N", run.N, "итераций", gi["thin"]["iters"], "clip",
                  gi["thin"]["n_clip"], f"{time.time() - t0:.0f} с", flush=True)
        out = {k: [None if not np.isfinite(x) else float(x) for x in a] for k, a in res.items()}
        out["ids"] = [p["id"] for p in pl]
        out["groups"] = groups
        out["geom"] = geom_stats(geo)
        out["t_s"] = time.time() - t0
        K.dump_json(f, out)


def cmd_conv(case="PERD_NE", ns=(3, 5, 7, 9), ngroups=3, nmax=40):
    """Сходимость по числу листов на реальном рельефе: группы с наибольшей долей точек лее под оболочкой."""
    refs = E.load_refs()
    pts = json.load(open(K.OUT_POINTS))
    grid = make_grid(case, "slope")
    geo = SH.SheetGeom(grid, M.C.load_terrain(case, M.C.SMOOTH_MAIN)[0])
    sep = Z.SepDist(geo)
    pl = E.case_points(case, refs, pts)
    nm = refs["norm"][case]
    ng, gid = E.kd_groups(pl, nmax)
    hz = geo.zone_height(np.array([p["x"] for p in pl]), np.array([p["y"] for p in pl]))
    score = [np.sum([(hz[i] > p["z_agl"]) for i, p in enumerate(pl) if gid[i] == g]) for g in range(ng)]
    pick = list(np.argsort(score)[::-1][:ngroups])
    out = dict(case=case, ns=list(ns), groups=[])
    for g in pick:
        sel = [i for i in range(len(pl)) if gid[i] == g]
        xy = [(pl[i]["x"], pl[i]["y"]) for i in sel] + [(nm["x"], nm["y"])]
        run = M.GRun(case, xy)
        X = np.array([pl[i]["x"] for i in sel] + [nm["x"]])
        Y = np.array([pl[i]["y"] for i in sel] + [nm["y"]])
        Zz = np.array([pl[i]["z_agl"] for i in sel] + [nm["z_agl"]])
        Xa, Ya, Za = run.abs_points(X, Y, Zz)
        thin = SH.Sheet(run, geo, "rest")
        res = {}
        for n in ns:
            mx = Z.MixSheet(thin, n, sep=sep)
            q = Z.zone_parts(run, Xa, Ya, Za, mx, sep, "mix")
            res[n] = (q["speed_sheet"][:-1] / q["speed_sheet"][-1], q["speed"][:-1] / q["speed"][-1])
        ref = res[ns[-1]]
        z = Zz[:-1]
        m = z <= 100
        rows = []
        for n in ns:
            for k, var in enumerate(("sheet_jh_mix", "zone_jh")):
                d = np.abs(res[n][k] - ref[k]) / np.maximum(ref[k], 0.05)
                rows.append(dict(n=n, variant=var, max_rel=float(d[m].max()), mean_rel=float(d[m].mean())))
        out["groups"].append(dict(group=int(g), n_points=len(sel), n_under=int(score[g]), rows=rows))
        print(case, "группа", g, rows, flush=True)
        run.free()
    K.dump_json(RAW / f"conv_{case}.json", out)


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
    if cmd == "conv":
        cmd_conv(cases[0] if len(cases) == 1 else "PERD_NE")
    if cmd in ("assemble", "all"):
        from . import assemble as A
        A.main()
    if cmd not in ("points", "assemble", "all", "conv"):
        print(__doc__)
