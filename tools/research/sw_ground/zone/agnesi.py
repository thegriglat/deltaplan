"""Хребет Аньези H/L = 0,5 (H 125 м, a 250 м; wake.synth.agnesi_run, как тесты SWG-7): профили u(z) на 10–100 м за
гребнем по вариантам, сходимость по числу листов слоя смешения, влияние обрезки γ ≥ 0 → out/swg-8/agnesi.json.

  py -m zone.agnesi
"""
from __future__ import annotations

import time

import numpy as np

from ground import common as K
from ground import model as M
from wake import core as W
from wake import synth as S
from sheet import core as SH

from . import core as Z

OUT = K.SG / "out" / "swg-8"
XS = np.array([-300.0, 150.0, 300.0, 450.0, 600.0, 750.0, 900.0, 1200.0])
ZS = np.array([5.0, 10.0, 20.0, 30.0, 40.0, 50.0, 75.0, 100.0, 300.0])
NS = (1, 3, 5, 7, 9)


def setup():
    r = S.agnesi_run(ds_min=25.0, focus_x=np.arange(-600.0, 1201.0, 150.0))
    g = W.WakeGrid(r.terrain, (1.0, 0.0), 25.0)
    geo = SH.SheetGeom(g, r.terrain)
    return r, geo


def columns(r, sheet, sep, mode, zone):
    """s(x, z) м/с: zone — правило зоны, иначе модель листа (sheet_parts)."""
    X, Zg = np.meshgrid(XS, ZS, indexing="ij")
    x, za = X.ravel(), Zg.ravel()
    z = r.panels.height(x, 0 * x) + za
    if sheet is None:
        p = M.jh_parts(r, x, 0 * x, z)
        return p["speed"].reshape(X.shape), None
    q = Z.zone_parts(r, x, 0 * x, z, sheet, sep, mode)
    s = q["speed"] if zone else q["speed_sheet"]
    return s.reshape(X.shape), q


def main():
    t0 = time.time()
    r, geo = setup()
    sep = Z.SepDist(geo)
    thin = SH.Sheet(r, geo, "rest")
    out = dict(H=125.0, a=250.0, xs=XS.tolist(), zs=ZS.tolist(), seg=[q for q in geo.segs if abs(q["c"]) < 1],
               thin_info={k: v for k, v in thin.info.items()}, n_clip=Z.clip_count(thin))
    zc = geo.zone_height(XS, 0 * XS)
    out["zone_h"] = zc.tolist()
    out["delta_omega"] = (Z.C_DW * sep.at_xy(XS, 0 * XS)).tolist()
    prof = {}
    prof["potential_jh"], _ = columns(r, None, sep, "thin", False)
    prof["sheet_jh"], _ = columns(r, thin, sep, "thin", False)
    s, q = columns(r, thin, sep, "thin", True)
    prof["zone_jh_thin"] = s
    out["zone_thin_ur_over_Ue"] = np.where(q["under"], q["ur"] / q["Ue"], np.nan).reshape(s.shape).tolist()
    conv = {}
    for n in NS:
        mx = Z.MixSheet(thin, n, sep=sep)
        a, _ = columns(r, mx, sep, "mix", False)
        b, q = columns(r, mx, sep, "mix", True)
        conv[n] = dict(sheet_jh_mix=a, zone_jh=b, info=mx.info)
        if n == Z.N_LAYERS:
            prof["sheet_jh_mix"], prof["zone_jh"] = a, b
            out["zone_ur_over_Ue"] = np.where(q["under"], q["ur"] / q["Ue"], np.nan).reshape(b.shape).tolist()
            out["zone_u_par"] = q["u_par"].reshape(b.shape).tolist()
            out["zone_capped"] = q["capped"].reshape(b.shape).astype(int).tolist()
            # непрерывность при z = h и массовый баланс
            iu = np.nonzero(zc > 15.0)[0]
            xx = XS[iu]
            zg = r.panels.height(xx, 0 * xx)
            eps = 0.05
            lo = Z.zone_parts(r, xx, 0 * xx, zg + zc[iu] - eps, mx, sep, "mix")["speed"]
            hi = Z.zone_parts(r, xx, 0 * xx, zg + zc[iu] + eps, mx, sep, "mix")["speed"]
            out["continuity"] = dict(x=xx.tolist(), below=lo.tolist(), above=hi.tolist(),
                                     max_rel_jump=float(np.max(np.abs(lo - hi) / hi)))
            mb = []
            for k, i in enumerate(iu):
                zq = np.linspace(r.z0 * 1.001, zc[i] - 1e-3, 400)
                qq = Z.zone_parts(r, np.full(zq.size, XS[i]), 0 * zq, zg[k] + zq, mx, sep, "mix")
                flux = np.trapezoid(qq["u_par"], zq)
                mb.append(dict(x=float(XS[i]), h=float(zc[i]), flux_over_uh_h=float(flux / (np.nanmax(np.abs(qq["u_par"])) * zc[i])),
                               capped=bool(qq["capped"].any())))
            out["mass_balance"] = mb
    ref = conv[NS[-1]]
    out["convergence"] = []
    for n in NS:
        for var in ("sheet_jh_mix", "zone_jh"):
            d = np.abs(conv[n][var] - ref[var]) / np.maximum(ref[var], 0.05 * thin.U_ref)
            m = (XS[:, None] >= 150) & (XS[:, None] <= 900) & (ZS[None, :] <= 100)
            out["convergence"].append(dict(n=n, variant=var, max_rel_vs_n9=float(d[m].max()),
                                           mean_rel_vs_n9=float(d[m].mean()), info=conv[n]["info"]))
    # обрезка γ ≥ 0
    nc = Z.iterate_rest(r, geo, clip=False)
    pnc, _ = columns(r, nc, sep, "thin", False)
    out["noclip"] = dict(info={k: v for k, v in nc.info.items()},
                         max_rel_sheet_jh=float(np.max(np.abs(pnc - prof["sheet_jh"]) / prof["sheet_jh"])))
    out["profiles"] = {k: v.tolist() for k, v in prof.items()}
    out["t_s"] = time.time() - t0
    print(fmt(out))
    K.dump_json(OUT / "agnesi.json", clean(out))


def clean(o):
    if isinstance(o, dict):
        return {str(k): clean(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [clean(v) for v in o]
    if isinstance(o, (float, np.floating)):
        return float(o) if np.isfinite(o) else None
    if isinstance(o, (np.integer,)):
        return int(o)
    if isinstance(o, np.bool_):
        return bool(o)
    return o


def fmt(out):
    L = ["Аньези H/L 0,5: s, м/с (x — столбцы, z — строки)"]
    xs, zs = out["xs"], out["zs"]
    L.append("zone_h " + " ".join(f"{h:6.1f}" for h in out["zone_h"]))
    L.append("δ_ω    " + " ".join(f"{h:6.1f}" for h in out["delta_omega"]))
    for k, v in out["profiles"].items():
        L.append(f"-- {k}")
        v = np.array(v)
        for j, z in enumerate(zs):
            L.append(f"z={z:5.0f} " + " ".join(f"{v[i, j]:6.2f}" for i in range(len(xs))))
    L.append("u_r/U_e zone_jh: " + str(np.round(np.array(out["zone_ur_over_Ue"], float), 2).tolist()))
    L.append("continuity " + str(out["continuity"]))
    L.append("mass " + str(out["mass_balance"]))
    for c in out["convergence"]:
        L.append(f"N={c['n']} {c['variant']}: max {c['max_rel_vs_n9']:.3f} mean {c['mean_rel_vs_n9']:.4f}")
    L.append("noclip " + str({k: out['noclip'][k] for k in ('max_rel_sheet_jh',)}) + " n_clip " + str(out["n_clip"])
             + " " + str({k: out["noclip"]["info"].get(k) for k in ("n_neg", "n_neg0", "iters", "converged")}))
    return "\n".join(L)


if __name__ == "__main__":
    main()
