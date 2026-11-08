"""SWG-9: зонд JH (профили по 11 уровням, линия ΔS вдоль ветра) на колонках точек SWG1 и мачт → out/swg-9/raw/.

  py -m attached.run probe [--case C] [--force]   # raw/probe_<case>.json (группы ≤ 40 (x, y), как SWG-1/7)
  py -m attached.run assemble                      # ground.json (SWG2 v1) + tables.md + diag.json
  py -m attached.run all
"""
from __future__ import annotations

import json
import sys
import time

import numpy as np

from ground import common as K
from ground import evaluate as E
from ground import model as M

from . import core as AC

OUT = K.SG / "out" / "swg-9"
RAW = OUT / "raw"


def _l(a):
    return [None if not np.isfinite(v) else float(v) for v in np.ravel(a)]


def cmd_probe(force=False, nmax=40, cases=K.CASES):
    refs = E.load_refs()
    pts = json.load(open(K.OUT_POINTS))
    for case in cases:
        f = RAW / f"probe_{case}.json"
        if f.exists() and not force:
            continue
        t0 = time.time()
        pl = E.case_points(case, refs, pts)
        nm = refs["norm"][case]
        ng, gid = E.kd_groups(pl, nmax)          # те же группы, что SWG-1/7 → та же сетка, s_jh побитно
        n = len(pl)
        PK = ("s_jh", "s_pot", "uin", "uh", "t", "A", "dS", "u0", "l", "hm", "L")      # в точках (u — в долях U_ref)
        P = {k: np.full(n, np.nan) for k in PK}
        cols, col_of = {}, [None] * n
        for i, p in enumerate(pl):
            k = (round(p["x"], 2), round(p["y"], 2))
            col_of[i] = cols.setdefault(k, len(cols))
        nc = len(cols)
        nz, no = len(AC.ZP), len(AC.OFF)
        C2 = {k: np.full((nc, nz), np.nan) for k in ("s_jh", "s_pot", "A", "dS", "t", "u0")}
        C1 = {k: np.full(nc, np.nan) for k in ("l", "hm", "L", "u0hm", "dSdx")}
        line = np.full((nc, no), np.nan)
        gmeta = []
        for g in range(ng):
            sel = [i for i in range(n) if gid[i] == g]
            xy = [(pl[i]["x"], pl[i]["y"]) for i in sel] + [(nm["x"], nm["y"])]
            run = M.GRun(case, xy)
            X = np.array([pl[i]["x"] for i in sel] + [nm["x"]])
            Y = np.array([pl[i]["y"] for i in sel] + [nm["y"]])
            Z = np.array([pl[i]["z_agl"] for i in sel] + [nm["z_agl"]])
            Xa, Ya, Za = run.abs_points(X, Y, Z)
            p = M.jh_parts(run, Xa, Ya, Za)
            Ur = p["U_ref"]
            P["s_jh"][sel] = p["speed"][:-1] / p["speed"][-1]
            P["s_pot"][sel] = p["pot_speed"][:-1] / p["pot_speed"][-1]
            P["uin"][sel] = p["uin"][:-1] / Ur
            P["uh"][sel] = p["pot_speed"][:-1] / Ur
            for k in ("t", "A", "dS", "u0", "l", "hm", "L"):
                P[k][sel] = p[k][:-1] / (Ur if k == "u0" else 1.0)
            first = {}
            for i in sel:
                first.setdefault(col_of[i], i)
            cs = sorted(first)
            # колонки группы + опорная точка последней (её ∂ΔS/∂s нужен правилу в опорной точке)
            cx = np.array([pl[first[c]]["x"] for c in cs] + [nm["x"]])
            cy = np.array([pl[first[c]]["y"] for c in cs] + [nm["y"]])
            pr = AC.probe(run, cx, cy, (nm["x"], nm["y"], nm["z_agl"]))
            normq = dict(speed=float(p["speed"][-1] / Ur), uin=float(p["uin"][-1] / Ur),
                         uh=float(p["pot_speed"][-1] / Ur), t=float(p["t"][-1]), A=float(p["A"][-1]),
                         dS=float(p["dS"][-1]), u0=float(p["u0"][-1] / Ur), l=float(p["l"][-1]),
                         hm=float(p["hm"][-1]), u0hm=float(pr["u0hm"][-1]), dSdx=float(pr["dSdx"][-1]),
                         z_agl=float(nm["z_agl"]))
            pr = {k: (v[:-1] if isinstance(v, np.ndarray) else v) for k, v in pr.items()}
            for k in C2:
                C2[k][cs] = pr[k]
            for k in C1:
                C1[k][cs] = pr[k]
            line[cs] = pr["dS_line"]
            gmeta.append(dict(N=run.N, n=len(sel), cols=len(cs), norm=normq, idx=sel,
                              norm_check=float(p["speed"][-1] / pr["norm_speed"] - 1.0)))
            run.free()
            run.panels._geom = None
            print(case, f"группа {g + 1}/{ng}", "N", run.N, f"{time.time() - t0:.0f} с", flush=True)
        out = dict(ids=[p["id"] for p in pl], col_of=col_of, pt={k: _l(v) for k, v in P.items()},
                   col_x=[None] * nc, col_y=[None] * nc, ZP=list(AC.ZP), OFF=list(AC.OFF), z0=float(M.z0_rules(case)["median"]),
                   groups=gmeta, t_s=time.time() - t0)
        for i, p in enumerate(pl):
            out["col_x"][col_of[i]] = float(p["x"])
            out["col_y"][col_of[i]] = float(p["y"])
        for k, v in C2.items():
            out[k] = [_l(r) for r in v]
        for k, v in C1.items():
            out[k] = _l(v)
        out["dS_line"] = [_l(r) for r in line]
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
    if cmd in ("probe", "all"):
        cmd_probe(force, cases=cases)
    if cmd in ("assemble", "all"):
        from . import assemble as A
        A.main()
    if cmd not in ("probe", "assemble", "all"):
        print(__doc__)
