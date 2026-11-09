"""Хребет Аньези H/L 0,5 (H 125 м, a 250 м; wake.synth.agnesi_run, как SWG-7/8): форма свободной линии тока (высота над
подножием, длина до присоединения), профили u(z) на 10–100 м за гребнем по вариантам, баланс ∫u dz → out/swg-12/agnesi.json.

  py -m freeline.agnesi
"""
from __future__ import annotations

import time

import numpy as np

from ground import common as K
from ground import model as M
from wake import core as W
from wake import synth as S
from sheet import core as SH
from zone import core as Z
from zone.agnesi import clean

from . import core as FL

OUT = K.SG / "out" / "swg-12"
XS = np.array([-300.0, 150.0, 300.0, 450.0, 600.0, 750.0, 900.0, 1200.0])
ZS = np.array([5.0, 10.0, 20.0, 30.0, 50.0, 75.0, 100.0, 150.0, 300.0])


def setup(r=None):
    r = r or S.agnesi_run(ds_min=25.0, focus_x=np.arange(-600.0, 1201.0, 150.0))
    g = W.WakeGrid(r.terrain, (1.0, 0.0), 25.0)
    return r, g, FL.FreeGeom(g, r.terrain), SH.SheetGeom(g, r.terrain)


def line_shape(geo):
    """Отрезок на оси (c = 0): высота η над подножием и гребнем, длина до присоединения, u_b, u_sep."""
    q = min((q for q in geo.segs), key=lambda q: abs(q["c"]))
    return q


def columns(r, sheet, geo, sep, mode):
    X, Zg = np.meshgrid(XS, ZS, indexing="ij")
    x, za = X.ravel(), Zg.ravel()
    z = r.panels.height(x, 0 * x) + za
    if sheet is None:
        return M.jh_parts(r, x, 0 * x, z)["speed"].reshape(X.shape), None
    q = FL.free_parts(r, x, 0 * x, z, sheet, geo, sep, mode)
    return q["speed"].reshape(X.shape), q


def main():
    t0 = time.time()
    r, g, geo, hull = setup()
    sep = Z.SepDist(geo)
    thin = SH.Sheet(r, geo, "rest")
    geo.set_gamma(thin)
    mx = FL.FreeMix(thin, FL.N_LAYERS, sep=sep)
    q = line_shape(geo)
    qh = min((q for q in hull.segs), key=lambda q: abs(q["c"]))
    out = dict(H=125.0, a=250.0, xs=XS.tolist(), zs=ZS.tolist(), seg=q, hull_seg=qh, thin_info=dict(thin.info),
               mix_info=mx.info)
    out["zone_h"] = geo.zone_height(XS, 0 * XS).tolist()
    out["hull_h"] = hull.zone_height(XS, 0 * XS).tolist()
    prof = {}
    prof["potential_jh"], _ = columns(r, None, geo, sep, "thin")
    s, qt = columns(r, thin, geo, sep, "thin")
    prof["free_jh_thin"] = s
    prof["free_sheet_thin"] = qt["speed_sheet"].reshape(s.shape)
    s, qm = columns(r, mx, geo, sep, "mix")
    prof["free_jh"] = s
    prof["free_sheet_mix"] = qm["speed_sheet"].reshape(s.shape)
    out["free_u_par"] = qm["u_par"].reshape(s.shape).tolist()
    out["free_capped"] = qm["capped"].reshape(s.shape).astype(int).tolist()
    out["free_ur_over_Ue"] = np.where(qm["under"], qm["ur"] / qm["Ue"], np.nan).reshape(s.shape).tolist()
    # непрерывность при z = h и баланс ∫u dz по колонкам за гребнем
    zc = geo.zone_height(XS, 0 * XS)
    iu = np.nonzero(zc > 15.0)[0]
    xx = XS[iu]
    zg = r.panels.height(xx, 0 * xx)
    lo = FL.free_parts(r, xx, 0 * xx, zg + zc[iu] - 0.05, mx, geo, sep, "mix")
    hi = FL.free_parts(r, xx, 0 * xx, zg + zc[iu] + 0.05, mx, geo, sep, "mix")
    out["continuity"] = dict(x=xx.tolist(), below=lo["u_par"].tolist(), above=hi["u_par"].tolist(),
                             max_rel_jump=float(np.max(np.abs(lo["u_par"] - hi["u_par"]) / np.abs(hi["u_par"]))))
    mb = []
    for k, i in enumerate(iu):
        zq = np.linspace(r.z0 * 1.001, zc[i] - 1e-3, 400)
        qq = FL.free_parts(r, np.full(zq.size, XS[i]), 0 * zq, zg[k] + zq, mx, geo, sep, "mix")
        flux = np.trapezoid(qq["u_par"], zq)
        mb.append(dict(x=float(XS[i]), h=float(zc[i]), flux_over_umax_h=float(flux / (np.nanmax(np.abs(qq["u_par"])) * zc[i])),
                       capped=bool(qq["capped"].any()), ur_over_Ue=float(np.nanmedian(qq["ur"] / qq["Ue"])),
                       delta=float(qq["delta"][0])))
    out["mass_balance"] = mb
    out["profiles"] = {k: v.tolist() for k, v in prof.items()}
    out["t_s"] = time.time() - t0
    print(fmt(out))
    K.dump_json(OUT / "agnesi.json", clean(out))


def fmt(out):
    q, qh = out["seg"], out["hull_seg"]
    L = [f"Аньези: линия x_s {q['s_s']:.0f} → x_r {q['s_r']:.0f} м ({q['rule']}), h_max {q['hmax']:.1f} м, "
         f"η_max − z_гребня {q['bulge']:+.1f} м, u_b {q['u_b']:.3f}, u_sep {q['u_sep']:.3f}, u_s {q['u_s']:.3f}; "
         f"оболочка SWG-4: {qh['s_s']:.0f} → {qh['s_r']:.0f}, h_max {qh['hmax']:.1f}"]
    L.append("x      " + " ".join(f"{x:6.0f}" for x in out["xs"]))
    L.append("zone_h " + " ".join(f"{h:6.1f}" for h in out["zone_h"]))
    L.append("hull_h " + " ".join(f"{h:6.1f}" for h in out["hull_h"]))
    for k, v in out["profiles"].items():
        L.append(f"-- {k}")
        v = np.array(v)
        for j, z in enumerate(out["zs"]):
            L.append(f"z={z:5.0f} " + " ".join(f"{v[i, j]:6.2f}" for i in range(len(out["xs"]))))
    L.append("continuity " + str(out["continuity"]))
    L.append("mass " + str(out["mass_balance"]))
    return "\n".join(L)


if __name__ == "__main__":
    main()
