"""SWG-12: свободная линия тока с гребня — счёт на плотных точках SWG1 и мачтах (группы как SWG-7/8) → out/swg-12/raw/.

  py -m freeline.run geom                       # raw/geom_<case>.json — отрезки линий (оба триггера), без панелей; секунды
  py -m freeline.run points [--case C] [--force] # raw/pts_<case>.json
  py -m freeline.run rotor [--case C]           # raw/rotor.json — ротор по разрезам SWD1 (Menke 2019), критерий SWD5
  py -m freeline.run assemble                    # ground.json (SWG2) + tables.md
Триггер основного варианта — «head» (Хед по полю SWG-4, точки отрыва из out/swg-4/raw/grid_<case>.json), выбран до
сравнения (README); «slope» (SWD7/SWD9, уклон > 0,27) — вариант free_jh_slope.
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
from zone import core as Z
import filaments3d as F

from . import core as FL

OUT = K.SG / "out" / "swg-12"
RAW = OUT / "raw"
SWG4 = K.SG / "out" / "swg-4" / "raw"
GATES = ("head", "slope")
KEYS = ["s_pot", "s_jh", "A"] + [f"{k}_{g}" for g in GATES for k in (
    "s_sthin", "s_smix", "s_fthin", "s_free", "u_fthin", "u_free", "ur_free", "Ue_free", "cap_free", "cap_fthin",
    "resid_free", "zone_h", "under", "delta")]


def geometry(case, gate):
    t, _ = M.C.load_terrain(case, M.C.SMOOTH_MAIN)
    sep = json.load(open(SWG4 / f"grid_{case}.json"))["sep_xy"]
    g = make_grid(case, gate, sep)
    return FL.FreeGeom(g, t), SH.SheetGeom(g, t)


def geom_stats(geo):
    sg = geo.segs
    if not sg:
        return dict(n_segs=0, n_nodes=0)
    a = lambda k: np.array([q[k] for q in sg], float)
    L = a("s_r") - a("s_s")
    return dict(n_segs=len(sg), n_nodes=geo.n_nodes, ds_sheet=geo.ds, n_bridge=int(sum(q["rule"] == "bridge" for q in sg)),
                hmax_median=float(np.median(a("hmax"))), hmax_p90=float(np.percentile(a("hmax"), 90)),
                L_median=float(np.median(L)), bulge_median=float(np.median(a("bulge"))), bulge_max=float(a("bulge").max()),
                u_b_median=float(np.median(a("u_b"))), u_sep_median=float(np.median(a("u_sep"))),
                u_s_median=float(np.median(a("u_s"))), cpb_lin_median=float(np.median(-2 * a("u_b"))),
                n_cut=int(sum(q["n_cut"] > 0 for q in sg)), n_neg=int(sum(q["neg"] for q in sg)),
                depth_below_crest_median=float(np.median(a("depth_below_crest"))))


def cmd_geom():
    out = {}
    for case in K.CASES:
        out[case] = {}
        for gate in GATES:
            geo, hull = geometry(case, gate)
            st = geom_stats(geo)
            hs = [q["hmax"] for q in hull.segs]
            st.update(hull_n_segs=len(hull.segs), hull_n_nodes=hull.n_nodes,
                      hull_hmax_median=float(np.median(hs)) if hs else None)
            out[case][gate] = dict(stats=st, segs=geo.segs)
            print(case, gate, st, flush=True)
    K.dump_json(RAW / "geom.json", out)


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
        geos = {g: geometry(case, g)[0] for g in GATES}
        seps = {g: Z.SepDist(geos[g]) for g in GATES}
        pl = E.case_points(case, refs, pts)
        nm = refs["norm"][case]
        ng, gid = E.kd_groups(pl, nmax)
        n = len(pl)
        res = {k: np.full(n, np.nan) for k in KEYS}
        groups = []
        for gi_ in range(ng):
            sel = [i for i in range(n) if gid[i] == gi_]
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
            for gate in GATES:
                geo, sep = geos[gate], seps[gate]
                tv = time.time()
                thin = SH.Sheet(run, geo, "rest")
                geo.set_gamma(thin)
                info = _inf(thin)
                info["t_s"] = time.time() - tv
                info["n_clip"] = Z.clip_count(thin)
                info["imbalance"] = F.imbalance(thin.fil) if len(thin.fil.seg) else 0.0
                qt = FL.free_parts(run, Xa, Ya, Za, thin, geo, sep, "thin")
                tv = time.time()
                mx = FL.FreeMix(thin, FL.N_LAYERS, sep=sep)
                qm = FL.free_parts(run, Xa, Ya, Za, mx, geo, sep, "mix")
                mi = dict(mx.info, t_s=time.time() - tv, imbalance=F.imbalance(mx.fil) if len(mx.fil.seg) else 0.0)
                for nk, q, d in (("thin", qt, info), ("mix", qm, mi)):
                    d.update(norm_ratio_sheet=float(q["speed_sheet"][-1] / p["speed"][-1]),
                             norm_ratio_zone=float(q["speed"][-1] / p["speed"][-1]), norm_under=bool(q["under"][-1]))
                gi[gate] = dict(thin=info, mix=mi)
                G = gate
                res[f"s_sthin_{G}"][sel] = nrm(qt["speed_sheet"])
                res[f"s_smix_{G}"][sel] = nrm(qm["speed_sheet"])
                res[f"s_fthin_{G}"][sel] = nrm(qt["speed"])
                res[f"s_free_{G}"][sel] = nrm(qm["speed"])
                res[f"u_fthin_{G}"][sel] = qt["u_par"][:-1] / qt["speed"][-1]
                res[f"u_free_{G}"][sel] = qm["u_par"][:-1] / qm["speed"][-1]
                res[f"ur_free_{G}"][sel] = (qm["ur"] / qm["Ue"])[:-1]
                res[f"Ue_free_{G}"][sel] = qm["Ue"][:-1] / qm["speed"][-1]
                res[f"cap_free_{G}"][sel] = qm["capped"][:-1].astype(float)
                res[f"cap_fthin_{G}"][sel] = qt["capped"][:-1].astype(float)
                res[f"resid_free_{G}"][sel] = qm["resid"][:-1]
                res[f"zone_h_{G}"][sel] = qm["zone_h"][:-1]
                res[f"under_{G}"][sel] = qm["under"][:-1].astype(float)
                res[f"delta_{G}"][sel] = qm["delta"][:-1]
                del thin, mx
            groups.append(gi)
            run.free()
            run.panels._geom = None
            print(case, f"группа {gi_ + 1}/{ng}", "N", run.N, "итераций", gi["head"]["thin"]["iters"],
                  gi["slope"]["thin"]["iters"], f"{time.time() - t0:.0f} с", flush=True)
        out = {k: [None if not np.isfinite(x) else float(x) for x in a] for k, a in res.items()}
        out["ids"] = [p["id"] for p in pl]
        out["groups"] = groups
        out["geom"] = {g: geom_stats(geos[g]) for g in GATES}
        out["t_s"] = time.time() - t0
        K.dump_json(f, out)


def _norm_U(case, refs):
    nm = refs["norm"][case]
    for r in refs["rows"]:
        if r["case"] == case and r["ref_kind"] == "mast" and r["name"] == nm["name"] and abs(r["z_agl"] - nm["z_agl"]) < 1e-6:
            return float(r["speed"])
    return None


def scan_row(up15, step=10.0):
    """Самый длинный участок u∥ < −0,5 м/с длиной > 50 м (критерий SWD5, compare/core.rotor_scan). → (L, (i, j) | None)."""
    bad = np.isfinite(up15) & (up15 < -0.5)
    best, bi, i, n = 0.0, None, 0, up15.size
    while i < n:
        if bad[i]:
            j = i
            while j + 1 < n and bad[j + 1]:
                j += 1
            ln = (j - i + 1) * step
            if ln > 50.0 and ln > best:
                best, bi = ln, (i, j)
            i = j + 1
        else:
            i += 1
    return best, bi


SKIP_TR = ("mast_line",)    # 5,4 км: сетка с фокусом по всей линии не помещается на общую GPU (CPU — часы); не Menke


def cmd_rotor(cases=K.CASES, gate="head"):
    """Ротор по разрезам SWD1 (Menke 2019 и др.): u∥ free_jh (и free_jh_thin) на 15…300 м, критерий SWD5 → raw/rotor.json."""
    refs = E.load_refs()
    rows = []
    zs = np.arange(15.0, 301.0, 15.0)
    for case in cases:
        geo = geometry(case, gate)[0]
        sep = Z.SepDist(geo)
        nm = refs["norm"][case]
        Ud = _norm_U(case, refs)
        ex, ey = M.C.load_terrain(case, M.C.SMOOTH_MAIN)[1]
        e = np.array([ex, ey]) / np.hypot(ex, ey)
        for tr in [t for t in refs["transects"] if t["case"] == case and t["name"] not in SKIP_TR]:
            Lt = float(np.hypot(tr["x1"] - tr["x0"], tr["y1"] - tr["y0"]))
            n = int(Lt // 10) + 1
            s = np.linspace(0, Lt, n)
            X = tr["x0"] + (tr["x1"] - tr["x0"]) * s / Lt
            Y = tr["y0"] + (tr["y1"] - tr["y0"]) * s / Lt
            foc = [(float(a), float(b)) for a, b in zip(X[::5], Y[::5])] + [(nm["x"], nm["y"])]
            t0 = time.time()
            run = M.GRun(case, foc)
            XX = np.concatenate([np.tile(X, zs.size), [nm["x"]]])
            YY = np.concatenate([np.tile(Y, zs.size), [nm["y"]]])
            Zr = np.concatenate([np.repeat(zs, n), [nm["z_agl"]]])
            Xa, Ya, Za = run.abs_points(XX, YY, Zr)
            thin = SH.Sheet(run, geo, "rest")
            geo.set_gamma(thin)
            mx = FL.FreeMix(thin, FL.N_LAYERS, sep=sep)
            ref = {r["source"]: r for r in refs["rotor"] if r["case"] == case and r["transect"] == tr["name"]}
            for var, sh, mode in (("free_jh", mx, "mix"), ("free_jh_thin", thin, "thin")):
                q = FL.free_parts(run, Xa, Ya, Za, sh, geo, sep, mode)
                up = (q["u_par"][:-1] / q["speed"][-1] * Ud).reshape(zs.size, n)
                L, bi = scan_row(up[0])
                depth = 0.0
                if bi is not None:
                    depth = 15.0
                    for k in range(1, zs.size):
                        if not (np.isfinite(up[k]) & (up[k] < -0.5))[bi[0]:bi[1] + 1].any():
                            break
                        depth = float(zs[k])
                rows.append(dict(case=case, transect=tr["name"], variant=var, gate=gate, present=bool(bi is not None),
                                 L_m=float(L), depth_m=depth, u_min_15=float(np.nanmin(up[0])),
                                 L_menke=(ref.get("menke2019") or {}).get("L_m"),
                                 L_picard_nom=(ref.get("picard_nom") or {}).get("L_m"),
                                 depth_menke=(ref.get("menke2019") or {}).get("depth_m"),
                                 depth_picard_nom=(ref.get("picard_nom") or {}).get("depth_m"),
                                 under_frac_15=float(np.mean(q["under"][:-1].reshape(zs.size, n)[0]))))
                print(rows[-1], f"{time.time() - t0:.0f} с", flush=True)
            del thin, mx
            run.free()
            run.panels._geom = None
    K.dump_json(RAW / "rotor.json", dict(criterion="u∥ < −0,5 м/с на z_agl 15 м, участок > 50 м (SWD5); u∥ "
                                         "масштабирована к U мачты опорной точки", gate=gate, rows=rows))


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
    if cmd == "geom":
        cmd_geom()
    if cmd == "rotor":
        cmd_rotor(cases)
    if cmd in ("points", "all"):
        cmd_points(force, cases=cases)
    if cmd in ("assemble", "all"):
        from . import assemble as A
        A.main()
    if cmd not in ("points", "assemble", "all", "geom", "rotor"):
        print(__doc__)
