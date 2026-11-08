"""SWC-17: варианты potential_bl и vortex_bl (SW6 v3: surface_flow, boundary_layer, separation Хеда, velocity_bl, step shed='auto').
Библиотека panels2d не менялась. Функция run_bl_variants — по сигнатуре замена common.run_variants: возвращает те же поля
(u, w, xl, ul, t_*, shed) для "potential" (как раньше), "potential_bl", "vortex_bl" + служебное (отрыв, слой)."""
import sys
import time

import numpy as np

import common as C
from common import build_panels, solve, velocity, step, Vortices
from panels2d import surface_flow, boundary_layer, separation, velocity_bl

ORIG_RUN = C.run_variants
Z0 = {"z0": 0.1}      # z0 текущего случая (задаёт вызывающий)


def _bl_state(P, sg, bg, vt, z0):
    fl = surface_flow(P, sg, bg, vt)
    bl = boundary_layer(P, fl, z0)
    sp = separation(P, fl, bl, "head")
    return fl, bl, sp


def run_bl_variants(terr, bg, points, crests_x, main_x, x_end, ds_min=25.0, u_adv=6.0, variants=None,
                    n_run=3, n_avg=2, x_lo=None, max_steps=20000, verbose=True, z0=None, with_vortex=True):
    z0 = Z0["z0"] if z0 is None else z0
    res = ORIG_RUN(terr, bg, points, crests_x, main_x, x_end, ds_min=ds_min, u_adv=u_adv, variants=("potential",),
                         verbose=False)
    P = build_panels(terr, x_focus=main_x, ds_min=ds_min)
    px = np.array([p[1] for p in points]); pz = P.ground(px) + np.array([p[2] for p in points])
    xl, zl = res["potential"]["xl"], P.ground(res["potential"]["xl"]) + C.ROTOR_Z
    sig = solve(P, bg)
    # ---- potential_bl
    t0 = time.perf_counter()
    fl, bl, sp = _bl_state(P, sig, bg, None, z0)
    t_bl = (time.perf_counter() - t0) * 1e3
    u, w = velocity_bl(P, sig, bg, px, pz, bl)
    ul, _ = velocity_bl(P, sig, bg, xl, zl, bl)
    xq = np.tile(px, 200 // max(1, len(px)) + 1)[:200]; zq = np.tile(pz, 200 // max(1, len(px)) + 1)[:200]
    t0 = time.perf_counter(); velocity_bl(P, sig, bg, xq, zq, bl); tq = (time.perf_counter() - t0) / len(xq) * 1e6
    t0 = time.perf_counter(); solve(P, bg); ts = (time.perf_counter() - t0) * 1e3
    res["potential_bl"] = dict(u=u, w=w, t_solve_ms=ts, t_query_us=tq, n_panels=P.n, shed=sp, xl=xl, ul=ul, t_bl_ms=t_bl,
                               bl=_bl_summary(P, fl, bl, sp, px))
    res["potential"]["umax"] = res["potential"].get("umax")
    if not with_vortex:
        return res
    # ---- vortex_bl: step(shed='auto'), осреднение u, w (velocity_bl) по окну
    xs_ = np.arange(min(crests_x) - 500, x_end, 25.0)
    vv, ww = velocity(P, sig, bg, xs_, P.ground(xs_) + 0.5 * ds_min)
    umax = float(np.nanmax(np.hypot(vv, ww)))
    dt = 0.5 * ds_min / umax
    x_hi = x_end
    x_lo = (min(crests_x) - 1000.0) if x_lo is None else x_lo
    z_top = float(P.ground(np.array(crests_x)).max()) + 1500.0
    t_span = (x_hi - min(crests_x)) / u_adv
    n_r, n_a = int(np.ceil(n_run * t_span / dt)), int(np.ceil(n_avg * t_span / dt))
    if n_r + n_a > max_steps:
        f = max_steps / (n_r + n_a)
        n_r, n_a = int(n_r * f), int(n_a * f)
        print("ВНИМАНИЕ: урезано число шагов", n_r, n_a, file=sys.stderr)
    state = dict(panels=P, bg=bg, vortices=Vortices(), t=0.0, shed="auto", z0=z0)
    acc_p = np.zeros((2, len(px))); acc_l = np.zeros(len(xl))
    half_p = [np.zeros(len(px)), np.zeros(len(px))]
    nv_hist, step_ms, xsep_hist, nsep_hist = [], [], [], []
    nav = 0
    for n in range(n_r + n_a):
        t0 = time.perf_counter()
        state = step(state, dt)
        vt = state["vortices"]
        if vt.n:
            gone = (vt.x > x_hi) | (vt.x < x_lo) | (vt.z > z_top)
            if gone.any():
                state["lost"] = state.get("lost", 0.0) + float(vt.gamma[gone].sum())
                k = ~gone
                state["vortices"] = Vortices(vt.x[k], vt.z[k], vt.gamma[k], vt.core[k])
        step_ms.append((time.perf_counter() - t0) * 1e3)
        nv_hist.append(state["vortices"].n)
        if n >= n_r:
            vt = state["vortices"]
            sg = solve(P, bg, vt)
            fl_, bl_, sp_ = _bl_state(P, sg, bg, vt, z0)
            uu, ww_ = velocity_bl(P, sg, bg, px, pz, bl_, vt)
            ull, _ = velocity_bl(P, sg, bg, xl, zl, bl_, vt)
            h = 0 if (n - n_r) < n_a // 2 else 1
            acc_p += np.vstack([uu, ww_]); acc_l += ull; half_p[h] += uu
            xsep_hist.append([q["x_sep"] for q in sp_]); nsep_hist.append(len(sp_))
            nav += 1
        if verbose and n % 500 == 0:
            print(f"  step {n}/{n_r + n_a} nv={state['vortices'].n}", flush=True)
    vt = state["vortices"]
    sg = solve(P, bg, vt)
    fl_, bl_, sp_ = _bl_state(P, sg, bg, vt, z0)
    nh = [max(1, n_a // 2), max(1, n_a - n_a // 2)]
    drift = float(np.nanmax(np.abs(half_p[0] / nh[0] - half_p[1] / nh[1])))
    t0 = time.perf_counter(); solve(P, bg, vt); ts = (time.perf_counter() - t0) * 1e3
    t0 = time.perf_counter(); velocity_bl(P, sg, bg, xq, zq, bl_, vt); tq = (time.perf_counter() - t0) / len(xq) * 1e6
    allx = [x for xs in xsep_hist for x in xs]
    res["vortex_bl"] = dict(u=acc_p[0] / nav, w=acc_p[1] / nav, t_solve_ms=ts, t_query_us=tq, n_panels=P.n, shed=sp_, xl=xl,
                            ul=acc_l / nav, t_step_ms=float(np.mean(step_ms)), n_vortices=float(np.mean(nv_hist[-n_a:])),
                            dt=dt, n_steps=n_r + n_a, t_model=(n_r + n_a) * dt, t_span=t_span, drift_u=drift,
                            born=state.get("born"), lost=state.get("lost"), umax=umax,
                            sep_n_mean=float(np.mean(nsep_hist)), sep_x_all=sorted(set(round(x) for x in allx))[:40],
                            sep_x_mean=float(np.mean(allx)) if allx else None, bl=_bl_summary(P, fl_, bl_, sp_, px))
    return res


def _bl_summary(P, fl, bl, sp, px):
    j = np.clip(np.searchsorted(P.x1, px, side="right") - 1, 0, P.n - 1)
    return dict(sep=[dict(x=q["x_sep"], z=q["z_sep"], H=q["value"]) for q in sp], Hmax=float(np.nanmax(bl["H"])),
                delta_pts=[None if not np.isfinite(bl["delta"][k]) else float(bl["delta"][k]) for k in j],
                H_pts=[None if not np.isfinite(bl["H"][k]) else float(bl["H"][k]) for k in j],
                i_sep=int(bl["i_sep"]), delta0=float(np.nanmax(bl["delta"][:3])))
