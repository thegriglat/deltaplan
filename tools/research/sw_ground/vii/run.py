"""SWG-10: VII (панели + интегральный слой) на плотных точках SWG1 и мачтах → out/swg-10/raw/.

  py -m vii.run layer [case…]     # слой и связь на сетке случая (ds_min 50 м, фокус во всех точках) → raw/layer_<case>.npz/.json
  py -m vii.run points [case…]    # s в точках группами фокуса (ds_min 25 м, как SWG-1) → raw/pts_<case>.json
  py -m vii.run assemble          # ground.json (SWG2) + tables.md
Стадии пропускают готовое (--force — пересчитать); `all` — подряд.
"""
from __future__ import annotations

import json
import sys
import time

import numpy as np

from ground import common as K
from ground import evaluate as E
from ground import model as M

from . import bl
from . import core as V

import os
SMOKE = os.environ.get("SWG10_SMOKE") == "1"   # проверка конвейера: сетка слоя 100 м, 2 группы точек, raw_smoke/
OUT = K.SG / "out" / "swg-10"
RAW = OUT / ("raw_smoke" if SMOKE else "raw")
LAYER_DS = 100.0          # сетка слоя: ds_min 100 м, фокус во всех точках (радиус 1·ds_min); U_e сглажена 25 м, δ* — 50 м
LAYERS = {}
LAYER_KEYS = ("a", "lam", "theta", "dstar", "delta", "H", "cf", "U", "mode")


def clean(o):
    """NaN/inf → None (JSON без NaN по контракту)."""
    if isinstance(o, dict):
        return {k: clean(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [clean(v) for v in o]
    if isinstance(o, (float, np.floating)):
        return float(o) if np.isfinite(o) else None
    if isinstance(o, np.integer):
        return int(o)
    return o


def log(*a):
    print(*a, flush=True)


def layer_run(case, refs, pts):
    pl = E.case_points(case, refs, pts)
    xy = sorted({(p["x"], p["y"]) for p in pl})
    nm = refs["norm"][case]
    return M.GRun(case, xy + [(nm["x"], nm["y"])], ds_min=LAYER_DS, focus_r_mul=1.0)


def cmd_layer(cases, force=False):
    refs = E.load_refs()
    pts = json.load(open(K.OUT_POINTS))
    RAW.mkdir(parents=True, exist_ok=True)
    for case in cases:
        f = RAW / f"layer_{case}.npz"
        if (RAW / f"layer_{case}.json").exists() and not force:
            continue
        t0 = time.time()
        run = layer_run(case, refs, pts)
        log(case, "сетка слоя N", run.N, f"{time.time() - t0:.0f} с", run.infl.backend)
        vi = V.VII(run, log=log)
        log(case, "без связи (слой по невязкому)")
        r0 = vi.run_layer(coupled=False)
        L0 = {f"nc_{k}": np.asarray(r0["layer"][k], np.float32) for k in LAYER_KEYS}
        log(case, "VII")
        r = vi.run_layer(coupled=True, k_max=3 if SMOKE else V.K_MAX)
        L = {k: np.asarray(r["layer"][k], np.float32) for k in LAYER_KEYS}
        Lp = {f"pv_{k}": np.asarray(vi.prev_layer[k], np.float32) for k in LAYER_KEYS} if vi.prev_layer is not None else {}
        Mp = {"Mf_prev": vi.prev_Mf.astype(np.float32)} if vi.prev_Mf is not None else {}
        np.savez_compressed(f, Ui=vi.Ui.astype(np.float32), D=vi.D.astype(np.float32), Mf=vi.Mf.astype(np.float32),
                            valid=vi.strips.valid, **L, **L0, **Lp, **Mp)
        info = dict(case=case, N=run.N, backend=run.infl.backend, z0=vi.z0, U_inf=vi.U_inf, delta0=vi.delta0,
                    eq=dict(H0=vi.eq.H0, H1_0=vi.eq.H1_0, theta0=vi.eq.theta0, dstar0=vi.eq.dstar0, cf2_0=vi.eq.cf2_0),
                    hist=r["hist"], hist_nc=r0["hist"], converged=r["converged"], t_s=time.time() - t0,
                    strips=dict(n_lines=int(vi.strips.cvals.size), n_s=int(vi.strips.svals.size),
                                n_nodes=int(vi.strips.valid.sum())))
        K.dump_json(RAW / f"layer_{case}.json", clean(info))
        run.free()
        run.panels._geom = None
        log(case, "слой готов", f"{time.time() - t0:.0f} с", "сошлось" if r["converged"] else "НЕ сошлось")


def load_layer(case, strips):
    d = np.load(RAW / f"layer_{case}.npz")
    info = json.load(open(RAW / f"layer_{case}.json"))
    L = {k: d[k].astype(float) for k in LAYER_KEYS}
    L0 = {k: d[f"nc_{k}"].astype(float) for k in LAYER_KEYS}
    assert d["valid"].shape == strips.valid.shape
    lf = V.LayerField(strips, L, info["z0"])
    lf0 = V.LayerField(strips, L0, info["z0"])
    lfp, Mp = None, None
    if "pv_a" in d.files:
        lfp = V.LayerField(strips, {k: d[f"pv_{k}"].astype(float) for k in LAYER_KEYS}, info["z0"])
        Mp = d["Mf_prev"].astype(float)
    return lf, lf0, d["Mf"].astype(float), info, lfp, Mp


def cmd_points(cases, force=False, nmax=40):
    refs = E.load_refs()
    pts = json.load(open(K.OUT_POINTS))
    for case in cases:
        f = RAW / f"pts_{case}.json"
        if f.exists() and not force:
            continue
        t0 = time.time()
        pl = E.case_points(case, refs, pts)
        nm = refs["norm"][case]
        ng, gid = E.kd_groups(pl, nmax)
        n = len(pl)
        keys = ["s_pot", "s_jh", "s_vii", "s_vii_nc", "s_vii_noblow", "s_outer_eq", "sign_vii", "sign_vii_nc",
                "theta", "H", "dstar", "delta", "cf", "inv", "a", "f", "zagl", "s_vii_prev"]
        res = {k: np.full(n, np.nan) for k in keys}
        strips = lf = lf0 = Mf = None
        groups = []
        for g in range(2 if SMOKE else ng):
            sel = [i for i in range(n) if gid[i] == g]
            for attempt in range(2):
                try:
                    strips, lf, lf0, Mf = _group(case, pl, sel, nm, res, groups, strips, lf, lf0, Mf, attempt)
                    break
                except Exception as e:  # cupy OutOfMemoryError / CUDARuntimeError — общая GPU: повтор на CPU
                    if attempt == 1 or not any(k in type(e).__name__ for k in ("OutOfMemory", "CUDA", "Cuda")):
                        raise
                    log(case, f"группа {g + 1}: {type(e).__name__} — повтор на CPU")
                    try:
                        import cupy as cp
                        cp.get_default_memory_pool().free_all_blocks()
                    except Exception:
                        pass
            log(case, f"группа {g + 1}/{ng}", "N", groups[-1]["N"], groups[-1]["backend"], f"{time.time() - t0:.0f} с")
        out = {k: [None if not np.isfinite(x) else float(x) for x in a] for k, a in res.items()}
        out["ids"] = [p["id"] for p in pl]
        out["groups"] = groups
        out["t_s"] = time.time() - t0
        K.dump_json(f, out)


def _group(case, pl, sel, nm, res, groups, strips, lf, lf0, Mf, attempt):
    """Одна группа фокуса: GRun ds_min 25 м, potential/potential_jh, VII-поле. attempt 1 — только CPU."""
    xy = [(pl[i]["x"], pl[i]["y"]) for i in sel] + [(nm["x"], nm["y"])]
    keep = M.GPU_RETRIES
    if attempt == 1:
        M.GPU_RETRIES = 0
    try:
        run = M.GRun(case, xy)
    finally:
        M.GPU_RETRIES = keep
    if strips is None:
        strips = V.Strips(run.panels.terrain, run.wt)
        LAYERS[case] = load_layer(case, strips)
    lf, lf0, Mf, info, lfp, Mp = LAYERS[case]
    X = np.array([pl[i]["x"] for i in sel] + [nm["x"]])
    Y = np.array([pl[i]["y"] for i in sel] + [nm["y"]])
    Z = np.array([pl[i]["z_agl"] for i in sel] + [nm["z_agl"]])
    Xa, Ya, Za = run.abs_points(X, Y, Z)
    p = M.jh_parts(run, Xa, Ya, Za)
    res["s_pot"][sel] = p["pot_speed"][:-1] / p["pot_speed"][-1]
    res["s_jh"][sel] = p["speed"][:-1] / p["speed"][-1]
    vi = V.VII(run, strips=strips, need_ue=False)
    sig_d, _ = V.sigma_d(run, strips, Mf)
    pv = V.vii_parts(run, Xa, Ya, Za, sig_d, lf, vi.sig_u, vi.U_inf)
    pn = V.vii_parts(run, Xa, Ya, Za, None, lf, vi.sig_u, vi.U_inf)
    pc = V.vii_parts(run, Xa, Ya, Za, None, lf0, vi.sig_u, vi.U_inf)
    if lfp is not None:
        sdp, _ = V.sigma_d(run, strips, Mp)
        pp = V.vii_parts(run, Xa, Ya, Za, sdp, lfp, vi.sig_u, vi.U_inf)
        res["s_vii_prev"][sel] = pp["speed"][:-1] / pp["speed"][-1]
    # внешнее поле × равновесный лог (без слоя и вдува): f = ln(z/z0)/λ0
    f_eq = bl.profile(np.maximum(pv["zagl"], 0), 1.0, vi.eq.lam0, vi.z0)
    so = pn["outer0_speed"] * f_eq
    res["s_vii"][sel] = pv["speed"][:-1] / pv["speed"][-1]
    res["sign_vii"][sel] = pv["upar_sign"][:-1]
    res["s_vii_noblow"][sel] = pn["speed"][:-1] / pn["speed"][-1]
    res["s_vii_nc"][sel] = pc["speed"][:-1] / pc["speed"][-1]
    res["sign_vii_nc"][sel] = pc["upar_sign"][:-1]
    res["s_outer_eq"][sel] = so[:-1] / so[-1]
    for k in ("theta", "H", "dstar", "delta", "cf", "inv", "a"):
        res[k][sel] = pv["layer"][k][:-1]
    res["f"][sel] = pv["f"][:-1]
    res["zagl"][sel] = pv["zagl"][:-1]
    groups.append(dict(N=run.N, n=len(sel), backend=run.infl.backend,
                       norm=dict(vii=float(pv["speed"][-1]), jh=float(p["speed"][-1]),
                                 f=float(pv["f"][-1]), H=float(pv["layer"]["H"][-1]))))
    run.free()
    run.panels._geom = None
    return strips, lf, lf0, Mf


if __name__ == "__main__":
    args = sys.argv[1:]
    force = "--force" in args
    args = [a for a in args if a != "--force"]
    cmd = args[0] if args else ""
    cases = tuple(args[1:]) or K.CASES
    if cmd in ("layer", "all"):
        cmd_layer(cases, force)
    if cmd in ("points", "all"):
        cmd_points(cases, force)
    if cmd in ("assemble", "all"):
        from . import assemble as A
        A.main()
    if cmd not in ("layer", "points", "assemble", "all"):
        print(__doc__)
