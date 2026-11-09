"""SWG-5: нить ротора (rotor_jh, SWG-2) на плотных точках SWG1 и мачтах против potential_jh.

  py -m rotor_ground.run_swg5 fil      # нить на сетке случая SWG-2 -> out/swg-5/raw/fil_<case>.pkl
  py -m rotor_ground.run_swg5 base     # группы SWG-1: potential_jh и rotor_jh -> out/swg-5/raw/rot_<case>.json
  py -m rotor_ground.run_swg5 sens     # чувствительность: корень Γ на групповой сетке -> raw/sens_<case>.json
  py -m rotor_ground.assemble          # ground.json, ridges.json, tables.md

Нить (геометрия, Γ, R) — штатные параметры SWG-2, не менялись. На групповых сетках SWG-1 (≤ 40 точек, ds_min 25 м
в фокусе) нить та же (корень Γ не перебирается), панели решаются с extra = induced(fil), поле — velocity_jh(couple=True).
"""
from __future__ import annotations

import json
import pickle
import sys
import time

import numpy as np

from ground import common as K
from ground import evaluate as E
from ground import model as M          # патчи panels3d (память/потоки) — как в SWG-1
import core as C
import rotor3d
from panels3d import solve, velocity_jh
import sheet3d.foppl as _fp

OUT = K.SG / "out" / "swg-5"
RAW = OUT / "raw"
PARAMS = {"closure": "reattach", "R_rule": 0.25, "gate": "slope", "slope_min": 0.27}   # = SWG-2


def build_fil(case, refs):
    run = C.Run(case, refs=refs)
    t = time.time()
    fil, sig, info = rotor3d.rotor_vortex(run.panels, run.bg, run.z0, run.infl, dict(PARAMS))
    t = time.time() - t
    N = run.N
    run.free()
    return fil, info, N, t


def cmd_fil(force=False):
    refs = C.load_refs()
    for case in K.CASES:
        f = RAW / f"fil_{case}.pkl"
        if f.exists() and not force:
            continue
        fil, info, N, t = build_fil(case, refs)
        pickle.dump(dict(fil=fil, info=info, N=N, t_rotor_s=t), open(f, "wb"))
        rd = [(round(r["Gamma"], 3), round(r["R"], 1)) for r in info["ridges"] if r["placed"]]
        print(case, "N", N, "нитей", len(rd), "сегментов", len(fil.seg), f"{t:.1f} с", rd, flush=True)


def fields(run, fil, X, Y, Z, sigma_ex=None):
    """-> (s-скорости jh без нити, с нитью) и u∥ с нитью; X, Y, Z — абсолютные, последняя точка — нормировочная."""
    ind = _fp._induced_fn(fil)
    sig_f, _ = solve(run.panels, run.bg, ind, run.infl) if sigma_ex is None else (sigma_ex, None)
    u0, v0, _ = velocity_jh(run.panels, run.sigma, run.bg, X, Y, Z, run.z0, infl=run.infl)
    u1, v1, _ = velocity_jh(run.panels, sig_f, run.bg, X, Y, Z, run.z0, extra=ind, infl=run.infl, couple=True)
    return u0, v0, u1, v1


def cmd_base(force=False, nmax=40):
    refs = E.load_refs()
    pts = json.load(open(K.OUT_POINTS))
    for case in K.CASES:
        f = RAW / f"rot_{case}.json"
        if f.exists() and not force:
            continue
        fil = pickle.load(open(RAW / f"fil_{case}.pkl", "rb"))["fil"]
        pl = E.case_points(case, refs, pts)
        ng, gid = E.kd_groups(pl, nmax)
        nm = refs["norm"][case]
        n = len(pl)
        out = {k: np.full(n, np.nan) for k in ("s_jh", "s_rot", "s_rot_fixnorm", "upar_rot", "upar_jh")}
        norm_ratio = []
        wt = None
        t0 = time.time()
        Ns, ts = [], []
        for g in range(ng):
            sel = [i for i in range(n) if gid[i] == g]
            xy = [(pl[i]["x"], pl[i]["y"]) for i in sel] + [(nm["x"], nm["y"])]
            run = M.GRun(case, xy, z0=M.z0_rules(case)["median"])
            t1 = time.time()
            X = np.array([pl[i]["x"] for i in sel] + [nm["x"]])
            Y = np.array([pl[i]["y"] for i in sel] + [nm["y"]])
            Z = np.array([pl[i]["z_agl"] for i in sel] + [nm["z_agl"]])
            Xa, Ya, Za = run.abs_points(X, Y, Z)
            u0, v0, u1, v1 = fields(run, fil, Xa, Ya, Za)
            ex, ey = run.wt
            sp0, sp1 = np.hypot(u0, v0), np.hypot(u1, v1)
            out["s_jh"][sel] = (sp0 / sp0[-1])[:-1]
            out["s_rot"][sel] = (sp1 / sp1[-1])[:-1]
            out["s_rot_fixnorm"][sel] = (sp1 / sp0[-1])[:-1]       # диагностика: нормировка скоростью опорной точки без нити
            norm_ratio.append(float(sp1[-1] / sp0[-1]))
            out["upar_jh"][sel] = ((u0 * ex + v0 * ey) / sp0[-1])[:-1]
            out["upar_rot"][sel] = ((u1 * ex + v1 * ey) / sp1[-1])[:-1]
            Ns.append(run.N)
            ts.append(time.time() - t1 + run.t_mesh)
            run.free()
        d = {k: [None if not np.isfinite(v) else float(v) for v in out[k]] for k in out}
        d.update(ids=[p["id"] for p in pl], meta=dict(groups=ng, N=Ns, t_s=time.time() - t0, t_group_s=ts, nmax=nmax, norm_ratio=norm_ratio))
        K.dump_json(f, d)
        print(case, n, "точек", ng, "групп", f"{time.time() - t0:.0f} с", flush=True)


def cmd_sens(force=False, ngr=2):
    """Корень Γ заново на групповой сетке (rotor_vortex на GRun группы) против нити с сетки случая — для групп с
    наибольшим |s_rot − s_jh| (по сумме по lee/valley 10-50 м)."""
    refs = E.load_refs()
    pts = json.load(open(K.OUT_POINTS))
    for case in K.CASES:
        f = RAW / f"sens_{case}.json"
        if f.exists() and not force:
            continue
        raw = json.load(open(RAW / f"rot_{case}.json"))
        pl = E.case_points(case, refs, pts)
        ng, gid = E.kd_groups(pl, raw["meta"]["nmax"])
        eff = np.zeros(ng)
        for i, p in enumerate(pl):
            if raw["s_rot"][i] is None or raw["s_jh"][i] is None:
                continue
            if p["type"] in ("lee", "valley") and p["z_agl"] <= 50:
                eff[gid[i]] += abs(raw["s_rot"][i] - raw["s_jh"][i])
        pick = [int(g) for g in np.argsort(-eff)[:ngr]]
        fil0 = pickle.load(open(RAW / f"fil_{case}.pkl", "rb"))
        nm = refs["norm"][case]
        res = []
        for g in pick:
            sel = [i for i in range(len(pl)) if gid[i] == g]
            xy = [(pl[i]["x"], pl[i]["y"]) for i in sel] + [(nm["x"], nm["y"])]
            run = M.GRun(case, xy, z0=M.z0_rules(case)["median"])
            X = np.array([pl[i]["x"] for i in sel] + [nm["x"]])
            Y = np.array([pl[i]["y"] for i in sel] + [nm["y"]])
            Z = np.array([pl[i]["z_agl"] for i in sel] + [nm["z_agl"]])
            Xa, Ya, Za = run.abs_points(X, Y, Z)
            fil_g, _, info_g = rotor3d.rotor_vortex(run.panels, run.bg, run.z0, run.infl, dict(PARAMS))
            u0, v0, u1, v1 = fields(run, fil0["fil"], Xa, Ya, Za)       # нить случая
            _, _, u2, v2 = fields(run, fil_g, Xa, Ya, Za)               # нить с корнем Γ на групповой сетке
            s = lambda u, v: (np.hypot(u, v) / np.hypot(u, v)[-1])[:-1]
            sj, s1, s2 = s(u0, v0), s(u1, v1), s(u2, v2)
            ref = np.array([pl[i]["s_ref"] for i in sel])
            eff_ = s1 - sj
            res.append(dict(group=g, n=len(sel), N=run.N,
                            Gamma_case=[round(r["Gamma"], 4) for r in fil0["info"]["ridges"] if r["placed"]],
                            Gamma_group=[round(r["Gamma"], 4) for r in info_g["ridges"] if r["placed"]],
                            R_case=[round(r["R"], 1) for r in fil0["info"]["ridges"] if r["placed"]],
                            R_group=[round(r["R"], 1) for r in info_g["ridges"] if r["placed"]],
                            max_abs_ds_jh_vs_case=float(np.nanmax(abs(s1 - sj))),
                            max_abs_ds_jh_vs_group=float(np.nanmax(abs(s2 - sj))),
                            max_abs_diff_case_vs_group=float(np.nanmax(abs(s1 - s2))),
                            rms_diff_case_vs_group=float(np.sqrt(np.nanmean((s1 - s2) ** 2))),
                            rms_effect_case=float(np.sqrt(np.nanmean(eff_ ** 2))),
                            mean_rel_jh=float(np.mean((sj - ref) / ref)), mean_rel_case=float(np.mean((s1 - ref) / ref)),
                            mean_rel_group=float(np.mean((s2 - ref) / ref))))
            print(case, res[-1], flush=True)
            run.free()
        K.dump_json(f, dict(case=case, groups=res))


if __name__ == "__main__":
    a = sys.argv[1:]
    force = "--force" in a
    a = [x for x in a if x != "--force"]
    {"fil": cmd_fil, "base": cmd_base, "sens": cmd_sens}.get(a[0] if a else "", lambda force: print(__doc__))(force)
