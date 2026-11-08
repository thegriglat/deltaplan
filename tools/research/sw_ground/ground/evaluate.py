"""Вычисление s по стадиям (фон, потенциал, потенциал + JH) в точках SWG1/мачтах, группами фокуса (память GPU/CPU)."""
from __future__ import annotations

import json
import time

import h5py
import numpy as np

from . import common as K
from . import model as M


def load_refs():
    return json.load(open(K.REFS / "points.json"))


def case_points(case, refs, pts):
    """Точки случая: SWG1 (rows) + мачты SWD1 (ref_kind mast) как единый список словарей с x, y, z_agl, id, type, kind."""
    out = []
    for r in pts["rows"]:
        if r["case"] == case:
            out.append(dict(id=r["id"], type=r["type"], x=r["x"], y=r["y"], z_agl=r["z_agl"], kind="picard_nom",
                            s_ref=r["s_nom"]))
    for r in refs["rows"]:
        if r["case"] == case and r["ref_kind"] == "mast":
            out.append(dict(id=f"{r['name']}@{r['z_agl']:g}", type=r["point"], x=r["x"], y=r["y"], z_agl=r["z_agl"],
                            kind="mast", s_ref=r["s_norm"]))
    return out


def kd_groups(pts_list, nmax):
    """Пространственно компактные группы: рекурсивное деление по медиане вдоль большей стороны, в группе ≤ nmax различных
    (x, y). Компактность — чтобы кольца сгущения сетки у соседних точек перекрывались (N ≈ 5 тыс. + 200 на точку)."""
    xy = sorted({(round(p["x"], 2), round(p["y"], 2)) for p in pts_list})
    gid_of = {}

    def rec(idx, g0):
        if len(idx) <= nmax:
            for i in idx:
                gid_of[xy[i]] = g0
            return g0 + 1
        a = np.array([xy[i] for i in idx])
        ax = 0 if np.ptp(a[:, 0]) >= np.ptp(a[:, 1]) else 1
        o = np.argsort(a[:, ax], kind="stable")
        h = len(idx) // 2
        g1 = rec([idx[i] for i in o[:h]], g0)
        return rec([idx[i] for i in o[h:]], g1)
    ng = rec(list(range(len(xy))), 0)
    return ng, [gid_of[(round(p["x"], 2), round(p["y"], 2))] for p in pts_list]


def stages(case, pts_list, refs, nmax=30, z0_mode="median", **kw):
    """→ dict массивов (по pts_list): s_bg, s_pot, s_jh и диагностика JH (L, l, hm, t, A, dS), N групп.

    z0_mode: median | lnmean — скаляр z0 фона и JH (расчёт панелей заново); local_jh — фон по median, JH с z0 клетки
    растра в точке (z0 в опорной точке — тоже локальный)."""
    t0 = time.time()
    wt = None
    rules = M.z0_rules(case)
    z0_base = rules["median" if z0_mode in ("median", "local_jh") else z0_mode]
    run0 = None
    nm = refs["norm"][case]
    # направление ветра
    with h5py.File(K.REFS / f"{case}.h5", "r") as h:
        wt = np.array(h.attrs["wind_to"], float)
    ng, gid = kd_groups(pts_list, nmax)
    n = len(pts_list)
    keys = ["s_bg", "s_pot", "s_jh", "L", "l", "hm", "t", "A", "dS", "zagl_bg", "u0_over_Uref"]
    norm = []
    res = {k: np.full(n, np.nan) for k in keys}
    Ns, tm = [], []
    for g in range(ng):
        sel = [i for i in range(n) if gid[i] == g]
        xy = [(pts_list[i]["x"], pts_list[i]["y"]) for i in sel] + [(nm["x"], nm["y"])]
        run = M.GRun(case, xy, z0=z0_base, **kw)
        Ns.append(run.N)
        X = np.array([pts_list[i]["x"] for i in sel] + [nm["x"]])
        Y = np.array([pts_list[i]["y"] for i in sel] + [nm["y"]])
        Z = np.array([pts_list[i]["z_agl"] for i in sel] + [nm["z_agl"]])
        Xa, Ya, Za = run.abs_points(X, Y, Z)
        z0v = None
        if z0_mode == "local_jh":
            z0v = M.z0_local(case, X, Y)
        p = M.jh_parts(run, Xa, Ya, Za, z0v)
        for k_src, k_dst in (("bg_speed", "s_bg"), ("pot_speed", "s_pot"), ("speed", "s_jh")):
            v = p[k_src]
            res[k_dst][sel] = v[:-1] / v[-1]
        for k in ("L", "l", "hm", "t", "A", "dS"):
            res[k][sel] = p[k][:-1]
        res["u0_over_Uref"][sel] = (p["u0"] / p["U_ref"])[:-1]
        norm.append({k: float(p[k][-1]) for k in ("L", "l", "hm", "t", "A", "dS", "speed", "pot_speed", "bg_speed")})
        norm[-1]["u0_over_Uref"] = float(p["u0"][-1] / p["U_ref"])
        sm = run.terrain.smoothed(run.bg_smooth) if run.bg_smooth else run.terrain
        res["zagl_bg"][sel] = (Za - sm.height(Xa, Ya))[:-1]
        tm.append(run.t_mesh + run.info.get("t_assemble_s", 0) + run.info.get("t_solve_s", 0))
        run.free()
    res["_meta"] = dict(groups=ng, N=Ns, t_s=time.time() - t0, z0=z0_base, norm=norm)
    return res
