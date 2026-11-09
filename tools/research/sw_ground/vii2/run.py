"""SWG-11: VII-2 (тонкий слой JH + одновременная связь Ньютоном) на точках SWG1 и мачтах → out/swg-11/raw/.

  py -m vii2.run layer [case…]     # слой и связь на сетке случая (ds_min 100 м, фокус во всех точках) → raw/layer_<case>.npz/.json
  py -m vii2.run carter            # Askervein: явная Carter (vii, SWG-10) на том же тонком слое против Ньютона → raw/carter_ASK.json
  py -m vii2.run points [case…]    # s в точках группами фокуса (ds_min 25 м, как SWG-1) → raw/pts_<case>.json
  py -m vii2.run assemble          # ground.json (SWG2) + tables.md
Стадии пропускают готовое (--force — пересчитать).
"""
from __future__ import annotations

import json
import sys
import time

import numpy as np

from ground import common as K
from ground import evaluate as E
from ground import model as M

from vii import bl
from vii import core as V

from . import core as W

OUT = K.SG / "out" / "swg-11"
RAW = OUT / "raw"
LAYER_DS = 100.0          # сетка слоя — как SWG-10 (ds_min 100 м, фокус во всех точках радиусом 1·ds_min)
LAYER_KEYS = ("a", "lam", "theta", "dstar", "delta", "H", "cf", "U", "mode")
LAYERS = {}


def clean(o):
    if isinstance(o, dict):
        return {k: clean(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [clean(v) for v in o]
    if isinstance(o, (float, np.floating)):
        return float(o) if np.isfinite(o) else None
    if isinstance(o, (np.integer,)):
        return int(o)
    if isinstance(o, np.bool_):
        return bool(o)
    return o


def log(*a):
    print(*a, flush=True)


def layer_run(case, refs, pts):
    pl = E.case_points(case, refs, pts)
    xy = sorted({(p["x"], p["y"]) for p in pl})
    nm = refs["norm"][case]
    return M.GRun(case, xy + [(nm["x"], nm["y"])], ds_min=LAYER_DS, focus_r_mul=1.0)


def save_layer(case, vi, res, extra=None):
    om = vi.om
    L = vi.layer_grid()
    a0, l0, _ = vi.march_nc(vi.U_inv)
    a0, l0 = vi.clamp(a0, l0)
    L0 = vi.layer_grid(a0, l0, vi.U_inv)
    np.savez_compressed(RAW / f"layer_{case}.npz", m_ext=om.extended(vi.m), valid=vi.strips.valid,
                        **{k: np.asarray(L[k], np.float32) for k in LAYER_KEYS},
                        **{f"nc_{k}": np.asarray(L0[k], np.float32) for k in LAYER_KEYS},
                        U_inv=om.grid(vi.U_inv).astype(np.float32))
    st = bl.state(vi.a, vi.lam, vi.z0)
    info = dict(case=case, N=vi.panels.N, backend=vi.infl.backend, z0=vi.z0, delta0=vi.delta0, L_rule=vi.L_rule,
                n_crest_lines=vi.n_crest, U_l=vi.U_l,
                eq=dict(H0=vi.eq.H0, H1_0=vi.eq.H1_0, theta0=vi.eq.theta0, dstar0=vi.eq.dstar0, cf2_0=vi.eq.cf2_0,
                        lam0=vi.eq.lam0),
                n_nodes=om.n, n_lines=len(om.lines), converged=res["converged"], n_bad_lines=res["n_bad_lines"],
                iters_final=res["iters_final"], iters_total=res["iters_total"], branch_eps=res["branch_eps"],
                eps_result=res["eps_result"], stall=res["stall"], n_turns=res["n_turns"], n_arc_fail=res["n_arc_fail"], rmax=res["rmax"],
                n_active=int(vi.active.sum()), n_active_lam=int(vi.active_l.sum()), lam_cap=W.LAM_CAP, fine_sigma=vi.fine_sigma, cap=vi.cap, a_cap_margin=W.A_CAP_MARGIN, step=vi.strips.step,
                dc=vi.strips.dc,
                hist=res["hist"], n_sep_nodes=int((st["cf2"] < 0).sum()), H_max=float(st["H"].max()),
                n_lam_min=int((vi.lam <= bl.LAM_MIN + 1e-9).sum()), **(extra or {}))
    K.dump_json(RAW / f"layer_{case}.json", clean(info))


def cmd_layer(cases, force=False):
    refs = E.load_refs()
    pts = json.load(open(K.OUT_POINTS))
    RAW.mkdir(parents=True, exist_ok=True)
    for case in cases:
        if (RAW / f"layer_{case}.json").exists() and not force:
            continue
        t0 = time.time()
        run = layer_run(case, refs, pts)
        log(case, "сетка слоя N", run.N, f"{time.time() - t0:.0f} с", run.infl.backend)
        vi = W.VII2(run, log=log)
        log(case, f"δ0 = l = {vi.delta0:.1f} м (L {vi.L_rule:.0f} м по {vi.n_crest} профилям), U_l {vi.U_l:.2f}, "
                  f"λ0 {vi.eq.lam0:.2f}, H0 {vi.eq.H0:.2f}, узлов {vi.om.n}, профилей {len(vi.om.lines)}")
        res = vi.solve()
        save_layer(case, vi, res, dict(t_s=time.time() - t0))
        log(case, "слой готов", f"{time.time() - t0:.0f} с", "сошлось" if res["converged"] else "НЕ сошлось")
        run.free()


def cmd_carter(force=False):
    """Askervein: схема SWG-10 (vii.core.VII, явная полуобратная Carter, ω = 0,5 — Davis & Carter 1986, без
    сглаживания δ*) на том же тонком слое δ0 = l, против Ньютона: сравнение U_e и δ* в узлах слоя."""
    f = RAW / "carter_ASK.json"
    if f.exists() and not force:
        return
    case = "ASK_TU03B"
    refs = E.load_refs()
    pts = json.load(open(K.OUT_POINTS))
    run = layer_run(case, refs, pts)
    vi = W.VII2(run, log=log, fine=False)       # у Carter (vii) нет подсеточного закона — сравнение без него
    res = vi.solve()
    t0 = time.time()
    vc = V.VII(run, strips=vi.strips, delta0=vi.delta0, omega=bl.OMEGA, d_smooth=0.0, log=log)
    rc = vc.run_layer(coupled=True, k_max=80, tol=1e-4)
    om = vi.om
    Lc = rc["layer"]
    dsc = Lc["dstar"][om.node_ic, om.node_is]
    Uc = Lc["U"][om.node_ic, om.node_is]
    ok = np.isfinite(dsc + Uc)
    ds2 = bl.state(vi.a, vi.lam, vi.z0)["dstar"]
    d_ds = np.abs(dsc[ok] / ds2[ok] - 1)
    d_U = np.abs(Uc[ok] / vi.U[ok] - 1)
    out = dict(case=case, delta0=vi.delta0, newton=dict(converged=res["converged"], iters=len(res["hist"]) - 1,
                                                         rmax=res["hist"][-1]["rmax"]),
               carter=dict(converged=rc["converged"], iters=len(rc["hist"]), dmax_last=rc["hist"][-1]["dmax"],
                           n_inv_last=rc["hist"][-1]["n_inv"], t_s=time.time() - t0, omega=bl.OMEGA, tol=1e-4),
               n_nodes=int(ok.sum()), dstar_rel=dict(max=float(d_ds.max()), p99=float(np.percentile(d_ds, 99)),
                                                     mean=float(d_ds.mean())),
               U_rel=dict(max=float(d_U.max()), p99=float(np.percentile(d_U, 99)), mean=float(d_U.mean())))
    K.dump_json(f, clean(out))
    log(out)
    run.free()


class FullGrid:
    """Ω = вся решётка профилей (m уже продолжена): для build_Q на сетке группы."""

    def __init__(self, nl, ns):
        self.ext = np.arange(nl * ns).reshape(nl, ns)
        self.n = nl * ns


def load_layer(case, strips):
    d = np.load(RAW / f"layer_{case}.npz")
    info = json.load(open(RAW / f"layer_{case}.json"))
    assert d["valid"].shape == strips.valid.shape
    L = {k: d[k].astype(float) for k in LAYER_KEYS}
    L0 = {k: d[f"nc_{k}"].astype(float) for k in LAYER_KEYS}
    return V.LayerField(strips, L, info["z0"]), V.LayerField(strips, L0, info["z0"]), d["m_ext"].astype(float), info


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
        keys = ["s_pot", "s_jh", "s_vii2", "s_vii2_nc", "s_vii2_noblow", "sign_vii2", "sign_vii2_nc", "upar_vii2",
                "theta", "H", "dstar", "delta", "cf", "a", "f", "zagl"]
        res = {k: np.full(n, np.nan) for k in keys}
        groups = []
        strips = None
        for g in range(ng):
            sel = [i for i in range(n) if gid[i] == g]
            for attempt in range(2):
                try:
                    strips = _group(case, pl, sel, nm, res, groups, strips, attempt)
                    break
                except Exception as e:
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


def _group(case, pl, sel, nm, res, groups, strips, attempt):
    xy = [(pl[i]["x"], pl[i]["y"]) for i in sel] + [(nm["x"], nm["y"])]
    keep = M.GPU_RETRIES
    if attempt == 1:
        M.GPU_RETRIES = 0
    try:
        run = M.GRun(case, xy)
    finally:
        M.GPU_RETRIES = keep
    if strips is None:
        strips = V.Strips(run.panels.terrain, run.wt, W.STEP, W.DC)
        LAYERS[case] = load_layer(case, strips)
    lf, lf0, m_ext, info = LAYERS[case]
    X = np.array([pl[i]["x"] for i in sel] + [nm["x"]])
    Y = np.array([pl[i]["y"] for i in sel] + [nm["y"]])
    Z = np.array([pl[i]["z_agl"] for i in sel] + [nm["z_agl"]])
    Xa, Ya, Za = run.abs_points(X, Y, Z)
    p = M.jh_parts(run, Xa, Ya, Za)
    res["s_pot"][sel] = p["pot_speed"][:-1] / p["pot_speed"][-1]
    res["s_jh"][sel] = p["speed"][:-1] / p["speed"][-1]
    fg = FullGrid(*strips.valid.shape)
    sig_d = W.sigma_on(run, strips, fg, m_ext.ravel())
    pv = W.vii2_parts(run, Xa, Ya, Za, sig_d, lf)
    pn = W.vii2_parts(run, Xa, Ya, Za, None, lf)
    pc = W.vii2_parts(run, Xa, Ya, Za, None, lf0)
    res["s_vii2"][sel] = pv["speed"][:-1] / pv["speed"][-1]
    res["sign_vii2"][sel] = pv["upar_sign"][:-1]
    res["upar_vii2"][sel] = (pv["speed"] * pv["upar_sign"])[:-1] / pv["speed"][-1]
    res["s_vii2_noblow"][sel] = pn["speed"][:-1] / pn["speed"][-1]
    res["s_vii2_nc"][sel] = pc["speed"][:-1] / pc["speed"][-1]
    res["sign_vii2_nc"][sel] = pc["upar_sign"][:-1]
    for k in ("theta", "H", "dstar", "delta", "cf", "a"):
        res[k][sel] = pv["layer"][k][:-1]
    res["f"][sel] = pv["f"][:-1]
    res["zagl"][sel] = pv["zagl"][:-1]
    groups.append(dict(N=run.N, n=len(sel), backend=run.infl.backend,
                       norm=dict(vii2=float(pv["speed"][-1]), jh=float(p["speed"][-1]), f=float(pv["f"][-1]),
                                 H=float(pv["layer"]["H"][-1]))))
    run.free()
    run.panels._geom = None
    return strips


if __name__ == "__main__":
    args = sys.argv[1:]
    force = "--force" in args
    args = [a for a in args if a != "--force"]
    cmd = args[0] if args else ""
    cases = tuple(args[1:]) or K.CASES
    if cmd == "layer":
        cmd_layer(cases, force)
    elif cmd == "carter":
        cmd_carter(force)
    elif cmd == "points":
        cmd_points(cases, force)
    elif cmd == "assemble":
        from . import assemble as A
        A.main()
    else:
        print(__doc__)
