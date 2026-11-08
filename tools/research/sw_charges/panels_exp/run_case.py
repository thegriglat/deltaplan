"""SWC-12: один случай → out/panels2d/cases/<case>[_<tag>].json (строки SW7 + rotor + служебное).
Запуск: OPENBLAS_NUM_THREADS=1 tools/research/cascade_2d/py tools/research/sw_charges/panels_exp/run_case.py <case> [--ds 25] [--tag T] [--no-vortex]
case: C1 C2 C4 PERD_NE PERD_SW LW_H3 LW_MD LW_UCD LW_H5 LW_GI LW_H8
"""
import argparse
import json
import math
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C  # noqa: E402
from common import Terrain, bg_profile  # noqa: E402

# Lubitz & White 2007, табл. 2 (slope-flow.md §2.2): (H/L, макс. уклон табл., dS набл., z/H максимума или None=у поверхности)
LW = {"H3": (0.67, 0.49, 1.08, None), "MD": (0.63, 0.50, 0.80, 0.10), "UCD": (0.53, 0.42, 0.68, None),
      "H5": (0.40, 0.29, 0.70, None), "GI": (0.31, 0.25, 0.61, 0.15), "H8": (0.25, 0.19, 0.35, 0.15)}
LW_H, LW_ALPHA, LW_SURF = 400.0, 0.15, 0.05      # H модели, м; степень профиля трубы (допущение); «у поверхности» = 0,05 H
LW_SRC = "Lubitz & White 2007 JWEIA 95:639, табл. 2 (docs/research/calibration_data/slope-flow.md §2.2)"


def mk_row(case, variant, point, x, zagl, kind, src, rel, uref, wref, upan, wpan, units, ds, res):
    err = None if (uref is None or upan is None or not np.isfinite(upan)) else float(upan - uref)
    wt = None
    if kind == "picard":
        wt = bool(err is not None and abs(err) <= C.TOL * abs(uref))
    f = lambda v: None if v is None or not np.isfinite(v) else float(v)
    return dict(case=case, variant=variant, point=point, x=float(x), z_agl=float(zagl), ref_kind=kind, ref_source=src,
                ref_reliability=rel, u_ref=f(uref), w_ref=f(wref), u_pan=f(upan), w_pan=f(wpan), units=units, err=f(err),
                within_tol=wt, ds_min=float(ds), t_solve_ms=f(res["t_solve_ms"]), t_query_us=f(res["t_query_us"]),
                shed=bool(res["shed"]), t_step_ms=f(res.get("t_step_ms")), n_vortices=f(res.get("n_vortices")),
                drift_u=f(res.get("drift_u")))


def case_cascade(case, ds, vortex):
    P = C.Picard(case)
    cp = P.cp
    xc, L = float(cp["x_c"]), float(cp["L"])
    x = np.arange(P.xc[0], P.xc[-1] + 1e-6, 10.0)
    z = np.interp(x, P.xc, P.h)
    terr = Terrain(P.xc, P.h, smooth_m=25.0 if case == "C4" else 0.0)
    U10 = float(cp["U10"])
    zsat = 10.0 * P.max_profile ** (1.0 / P.alpha)
    bg = bg_profile(U10, P.alpha, zsat, terr, smooth_m=10 * 25.0)
    xg = terr.x
    crests = [float(x[i]) for i in C.find_crests(xg, terr.z)] if False else [float(xg[i]) for i in C.find_crests(xg, terr.z)]
    main = min(crests, key=lambda c: abs(c - xc))
    x_end = xc + (3500.0 if case == "C4" else 2500.0)
    pts = []
    for zz in (10, 50, 300):
        pts += [("upstream", -4800.0, zz), ("windward", xc - L, zz), ("crest", xc, zz), ("lee", xc + L, zz),
                ("foot", xc + 3 * L, zz)]
    u50 = U10 * 5.0 ** P.alpha
    res = C.run_variants(terr, bg, pts, crests, main, x_end, ds_min=ds, u_adv=u50,
                         variants=("potential", "vortex") if vortex else ("potential",))
    rows = []
    src = f"~/data/cascade_2d/fields/{case}/picard_none_d50.json (picard_rs P50)"
    for var, r in res.items():
        for k, (name, xx, zz) in enumerate(pts):
            ur, wr = P.sample([xx], [zz])
            rows.append(mk_row(case, var, name, xx, zz, "picard", src, "модель ±15 %", ur[0], wr[0], r["u"][k], r["w"][k],
                               "m/s", ds, r))
    rot = []
    ref_u = P.sample(res["potential"]["xl"], np.full(res["potential"]["xl"].shape, C.ROTOR_Z))[0]
    nxt = min([c for c in crests if c > main + 100] + [x_end])
    rr, Lr = C.rotor_from_line(res["potential"]["xl"], ref_u, main, nxt)
    for var, r in res.items():
        rp, Lp = C.rotor_of(r, crests, main, x_end)
        rot.append(dict(case=case, variant=var, rotor_pan=bool(rp), L_pan=Lp, rotor_ref=bool(rr), L_ref=Lr,
                        ref_source=src + f"; u<{C.ROTOR_U} м/с на z_agl {C.ROTOR_Z:g} м между гребнем и следующим"))
    return rows, rot, res, dict(crests=crests, main=main, x_end=x_end, U10=U10, alpha=P.alpha, z_sat=zsat, u50=u50)


def case_lw(name, ds, vortex):
    HL, smax, dS_ref, zH = LW[name]
    L = LW_H / HL
    x = np.arange(-6000.0, 6000.1, 10.0)
    z = np.where(np.abs(x) < 2 * L, LW_H * np.cos(np.pi * x / (4 * L)) ** 2, 0.0)
    terr = Terrain(x, z)
    zsat = 10 * LW_H
    bg = bg_profile(1.0, LW_ALPHA, zsat, terr, smooth_m=10 * 25.0)
    zc = (LW_SURF if zH is None else zH) * LW_H
    pts = [("upstream", -4000.0, zc), ("crest", 0.0, zc)]
    if name == "UCD":
        pts += [("windward", -L, zc), ("foot", -2 * L, zc)]
    x_end = max(3000.0, 5 * L)
    res = C.run_variants(terr, bg, pts, [0.0], 0.0, x_end, ds_min=ds, u_adv=5.0 ** LW_ALPHA,
                         variants=("potential", "vortex") if vortex else ("potential",))
    rows = []
    case = "LW_" + name
    extra = {"windward": 0.24, "foot": -0.27}
    for var, r in res.items():
        up = r["u"][0]
        for k, (pn, xx, zz) in enumerate(pts):
            if pn == "upstream":
                continue
            ds_pan = r["u"][k] / up - 1.0
            ref = dS_ref if pn == "crest" else extra[pn]
            rows.append(mk_row(case, var, pn, xx, zz, "tunnel", LW_SRC + ("" if pn == "crest" else " (середина склона x=L, подножие x=2L, UC Davis 2D, там же)"),
                               "труба", ref, None, ds_pan, None, "dS", ds, r))
    rot = []
    for var, r in res.items():
        rp, Lp = C.rotor_of(r, [0.0], 0.0, x_end)
        rot.append(dict(case=case, variant=var, rotor_pan=bool(rp), L_pan=Lp, rotor_ref=None, L_ref=None,
                        ref_source="в статье не приведено"))
    return rows, rot, res, dict(L=L, H=LW_H, slope_max_cos2=0.785 * HL, slope_max_table=smax, alpha=LW_ALPHA, z_sat=zsat,
                                shape="cos^2(pi x/(4L)), |x|<2L (синусоидальное сечение UC Davis; для H3, MD, H5, GI, H8 форма не найдена — то же)")


def case_perd(sub, ds, vortex, smooth=40.0):
    sys.path.insert(0, os.path.join(C.REPO, "tools", "research", "cases"))
    import perdigao as PD
    from scipy.ndimage import map_coordinates
    ci = PD.case_inputs(sub)
    wdir = ci["wdir"]
    ang = math.radians(wdir)
    ex, ey = -math.sin(ang), -math.cos(ang)
    ax, ay = ey, -ex
    t_line = {"ne": -100.0, "sw": 130.0}[sub]
    x0, y0, n, hc = PD.terrain(10.0, 6000.0)
    s = np.arange(-2800.0, 2800.1, 10.0)
    px, py = t_line * ax + s * ex, t_line * ay + s * ey
    zline = map_coordinates(hc, [(py - y0) / 10 - 0.5, (px - x0) / 10 - 0.5], order=1, mode="nearest")
    terr = Terrain(s, zline, smooth_m=smooth)
    crests = [float(terr.x[i]) for i in C.find_crests(terr.x, terr.z, prom_min=60.0)]
    # геометрия по определению Menke (как perdigao.zone_metrics): дно между гребнями, H, D
    cs = sorted(crests)
    c1, c2 = cs[0], cs[1]
    m = (terr.x > c1) & (terr.x < c2)
    xv = float(terr.x[m][np.argmin(terr.z[m])])
    Hs = 0.5 * (terr.height(c1) + terr.height(c2)) - terr.height(xv)
    Dd = c2 - c1
    U10 = PD.U10_IN[sub]
    alpha = PD.NOM["alpha"]
    z0 = round(PD.z0_nominal(), 3)
    mp = PD.RU.max_profile(alpha, U10, z0, PD.F_COR)
    zsat = 10.0 * mp ** (1.0 / alpha)
    bg = bg_profile(U10, alpha, zsat, terr, smooth_m=10 * 25.0)
    ms = PD.masts()
    ref = ci["ref"]
    # мачты: координата вдоль потока s, поперечное смещение t
    def st(nm):
        m_ = ms[nm]
        return m_["x"] * ex + m_["y"] * ey, m_["x"] * ax + m_["y"] * ay
    pts, meta = [], []
    for nm in PD.PROFILE_MASTS[sub]:
        sm, tm = st(nm)
        if abs(tm - t_line) > 250 or abs(sm) > 2700:
            continue
        for zt in PD.PROFILE_LEVELS:
            if zt < PD.MIN_Z_TOWER:
                continue
            lab = ("crest" if (abs(sm - c1) < 150 or abs(sm - c2) < 150) else "upstream" if sm < c1 - 150 else
                   "lee" if sm < xv - 150 else "valley" if sm < xv + 150 else "windward" if sm < c2 - 150 else "lee")
            pts.append((lab, float(sm), float(zt)))
            meta.append((nm, zt, tm - t_line, m_gd(ms, nm)))
    sref, _ = st(ref)
    pts.append(("crest", float(sref), 100.0))   # опорная точка нормировки — последняя
    x_end = 2700.0
    u50 = U10 * 5.0 ** alpha
    res = C.run_variants(terr, bg, pts, crests, c1, x_end, ds_min=ds, u_adv=u50,
                         variants=("potential", "vortex") if vortex else ("potential",))
    rows = []
    obs = {(nm, zt): PD.upar_data(sub, nm, zt) for nm, zt, _, _ in meta}
    u100 = ci["u100"]
    for var, r in res.items():
        spd_ref = math.hypot(r["u"][-1], r["w"][-1])
        for k, (lab, xx, zz) in enumerate(pts[:-1]):
            nm, zt, dt_, gd = meta[k]
            if nm == ref and zt == 100:
                continue
            up = r["u"][k] / spd_ref * u100
            wp = r["w"][k] / spd_ref * u100
            ur = obs[(nm, zt)] * u100
            if not np.isfinite(ur):
                continue          # нет данных мачты на этом уровне
            rows.append(mk_row("PERD_" + sub.upper(), var, lab, xx, zz, "mast",
                               f"ISFS NCAR/EOL {nm} {zt} м, cases/{PD.CASES[sub]['file']}_5min.csv: u_∥ вдоль притока; мачта в {dt_:.0f} м от линии",
                               "измерение", ur, None, up, wp, "m/s", ds, r))
    rot = []
    L_ref = {"ne": 530.0, "sw": 675.0}[sub]
    for var, r in res.items():
        rp, Lp = C.rotor_of(r, crests, c1, x_end)
        rot.append(dict(case="PERD_" + sub.upper(), variant=var, rotor_pan=bool(rp), L_pan=Lp, rotor_ref=True, L_ref=L_ref,
                        ref_source="Menke 2019 ACP 19:2713, Рис. 8 (menke2019/fig8_zones_approx.csv, разрезы 1–2, ±50 м; "
                                   "условная статистика по периодам с рециркуляцией, 52 % периодов, ≈ 0,75–0,9 при U100 ≥ 8)"))
    return rows, rot, res, dict(t_line=t_line, crests=crests, x_valley=xv, H_section=float(Hs), D_section=float(Dd), H_menke=PD.H_M,
                                D_menke=PD.D_MENKE, smooth_sigma_m=smooth, U10=U10, alpha=alpha, z_sat=zsat, u100=u100,
                                z0=z0, masts=[dict(name=m_[0], z=m_[1], lateral_m=m_[2]) for m_ in meta],
                                terrain_range_line=float(terr.z.max() - terr.z.min()))


def m_gd(ms, nm):
    return ms[nm]["ground"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("case")
    ap.add_argument("--ds", type=float, default=25.0)
    ap.add_argument("--tag", default="")
    ap.add_argument("--no-vortex", action="store_true")
    ap.add_argument("--smooth", type=float, default=40.0)
    a = ap.parse_args()
    t0 = time.time()
    c = a.case
    vx = not a.no_vortex
    if c in ("C1", "C2", "C4"):
        rows, rot, res, info = case_cascade(c, a.ds, vx)
    elif c.startswith("LW_"):
        rows, rot, res, info = case_lw(c[3:], a.ds, vx)
    else:
        rows, rot, res, info = case_perd(c[5:].lower(), a.ds, vx, a.smooth)
    sm = {}
    for var, r in res.items():
        sm[var] = {k: (float(v) if isinstance(v, (int, float, np.floating)) else None) for k, v in r.items()
                   if k in ("t_solve_ms", "t_query_us", "t_step_ms", "n_vortices", "dt", "n_steps", "t_model", "t_span",
                            "drift_u", "born", "lost", "umax", "n_panels")}
        sm[var]["shed"] = r["shed"]
        sm[var]["rotor_line"] = dict(x=np.round(r["xl"], 1).tolist(), u=[None if not np.isfinite(v) else round(float(v), 3) for v in r["ul"]])
    out = dict(case=c, ds_min=a.ds, wall_s=time.time() - t0, rows=rows, rotor=rot, info=info, summary=sm)
    os.makedirs(C.CASES_DIR, exist_ok=True)
    fn = os.path.join(C.CASES_DIR, f"{c}{a.tag}.json")
    with open(fn + ".tmp", "w") as f:
        json.dump(out, f, ensure_ascii=False, default=lambda o: o.tolist() if hasattr(o, "tolist") else str(o))
    os.replace(fn + ".tmp", fn)
    print(c, a.tag, "rows", len(rows), "wall %.1f s" % out["wall_s"], fn)


if __name__ == "__main__":
    main()
