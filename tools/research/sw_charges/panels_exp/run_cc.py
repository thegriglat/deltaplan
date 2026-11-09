"""SWC-16: (a) C1/C2/C4 с эталоном Пикара по центрам клеток F1 dx 50 (без степенной поправки); (b) LW с однородным фоном.
Запуск: OPENBLAS_NUM_THREADS=1 tools/research/cascade_2d/py -I tools/research/sw_charges/panels_exp/run_cc.py <C1|C2|C4|LW_H3|...>
Пишет out/panels2d/cases/<case>_cc.json (C*) или <case>_uni.json (LW_*)."""
import json, math, os, sys, time
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C
import run_case as RC
from common import Terrain, bg_profile
from panels2d import bg_uniform


def cc_points(P, case, cp):
    """Точки SW7 по центрам клеток F1: колонка — клетка, содержащая x; клетки воздуха k0 (нижняя), k0+1, ~50 м, ~300 м над землёй."""
    xc, L = float(cp["x_c"]), float(cp["L"])
    pts = []
    for name, x in (("upstream", -4800.0), ("windward", xc - L), ("crest", xc), ("lee", xc + L), ("foot", xc + 3 * L)):
        i = int(np.floor((x - (P.xc[0] - P.dx / 2)) / P.dx))
        k0 = int(np.argmax(P.air[:, i]))
        agl0 = P.zc[k0] - P.h[i]
        ks = [k0, k0 + 1]
        for target in (50.0, 300.0):
            ks.append(k0 + int(round((target - agl0) / P.dz)))
        for k in ks:
            pts.append(dict(name=name, i=i, k=int(k), x=float(P.xc[i]), zagl=float(P.zc[k] - P.h[i])))
    return pts


def case_cc(case, ds, vortex):
    P = C.Picard(case)
    cp = P.cp
    xc, L = float(cp["x_c"]), float(cp["L"])
    terr = Terrain(P.xc, P.h, smooth_m=25.0 if case == "C4" else 0.0)
    U10 = float(cp["U10"])
    zsat = 10.0 * P.max_profile ** (1.0 / P.alpha)
    bg = bg_profile(U10, P.alpha, zsat, terr, smooth_m=250.0)
    xg = terr.x
    crests = [float(xg[i]) for i in C.find_crests(xg, terr.z)]
    main = min(crests, key=lambda c: abs(c - xc))
    x_end = xc + (3500.0 if case == "C4" else 2500.0)
    cpts = cc_points(P, case, cp)
    pts = [(p["name"], p["x"], p["zagl"]) for p in cpts]
    u50 = U10 * 5.0 ** P.alpha
    res = C.run_variants(terr, bg, pts, crests, main, x_end, ds_min=ds, u_adv=u50,
                         variants=("potential", "vortex") if vortex else ("potential",))
    src = f"~/data/cascade_2d/fields/{case}/picard_none_d50.json (picard_rs P50), центр клетки F1 (i={{i}}, k={{k}}), без степенной поправки"
    rows = []
    for var, r in res.items():
        for n, (p, (name, xx, zz)) in enumerate(zip(cpts, pts)):
            rows.append(RC.mk_row(case, var, name, xx, zz, "picard", src.format(i=p["i"], k=p["k"]), "модель ±15 %",
                                  float(P.uc[p["k"], p["i"]]), float(P.wc[p["k"], p["i"]]), r["u"][n], r["w"][n], "m/s", ds, r))
    # ротор — как в SWC-12 (линия z_agl 15 м): эталон — линейная интерполяция по центрам клеток двух ближайших воздушных клеток
    rot = []
    xl = res["potential"]["xl"]
    ref_u = np.full(xl.shape, np.nan)
    for n, x in enumerate(xl):
        i = int(np.clip(np.floor((x - (P.xc[0] - P.dx / 2)) / P.dx), 0, len(P.xc) - 1))
        k0 = int(np.argmax(P.air[:, i]))
        a0 = P.zc[k0] - P.h[i]
        if a0 <= C.ROTOR_Z < a0 + P.dz:                       # 15 м между центрами k0 и k0+1
            f = (C.ROTOR_Z - a0) / P.dz
            ref_u[n] = (1 - f) * P.uc[k0, i] + f * P.uc[k0 + 1, i]
        elif C.ROTOR_Z >= a0 + P.dz:
            k = k0 + int(np.floor((C.ROTOR_Z - a0) / P.dz)); f = ((C.ROTOR_Z - a0) / P.dz) % 1
            ref_u[n] = (1 - f) * P.uc[k, i] + f * P.uc[k + 1, i]
        else:                                                  # ниже центра нижней клетки (<15 м): центр нижней клетки
            ref_u[n] = P.uc[k0, i]
    nxt = min([c for c in crests if c > main + 100] + [x_end])
    rr, Lr = C.rotor_from_line(xl, ref_u, main, nxt)
    for var, r in res.items():
        rp, Lp = C.rotor_of(r, crests, main, x_end)
        rot.append(dict(case=case, variant=var, rotor_pan=bool(rp), L_pan=Lp, rotor_ref=bool(rr), L_ref=Lr,
                        ref_source=src.split(", центр")[0] + f"; u<{C.ROTOR_U} м/с на z_agl {C.ROTOR_Z:g} м (интерп. между центрами клеток) между гребнем и следующим"))
    info = dict(crests=crests, main=main, x_end=x_end, U10=U10, alpha=P.alpha, z_sat=zsat, u50=u50, dz=P.dz, dx=P.dx,
                cells=[dict(name=p["name"], i=p["i"], k=p["k"], x=p["x"], zagl=p["zagl"], h=float(P.h[p["i"]])) for p in cpts])
    return rows, rot, res, info


# ---------------------------------------------------------------- LW с однородным фоном
def case_lw_uni(name, ds, vortex):
    HL, smax, dS_ref, zH = RC.LW[name]
    L = RC.LW_H / HL
    x = np.arange(-6000.0, 6000.1, 10.0)
    z = np.where(np.abs(x) < 2 * L, RC.LW_H * np.cos(np.pi * x / (4 * L)) ** 2, 0.0)
    terr = Terrain(x, z)
    bg = bg_uniform(1.0)
    zc = (5.0 / 38.0 if name == "UCD" else (RC.LW_SURF if zH is None else zH)) * RC.LW_H   # UCD: нижняя точка трубы 5 мм / H 38 мм
    pts = [("upstream", -4000.0, zc), ("crest", 0.0, zc)]
    if name == "UCD":
        pts += [("windward", -L, zc), ("foot", -2 * L, zc)]
    x_end = max(3000.0, 5 * L)
    res = C.run_variants(terr, bg, pts, [0.0], 0.0, x_end, ds_min=ds, u_adv=1.0,
                         variants=("potential", "vortex") if vortex else ("potential",))
    rows, case = [], "LW_" + name
    extra = {"windward": 0.24, "foot": -0.27}
    for var, r in res.items():
        up = r["u"][0]
        for k, (pn, xx, zz) in enumerate(pts):
            if pn == "upstream":
                continue
            ref = dS_ref if pn == "crest" else extra[pn]
            src = RC.LW_SRC + ("" if pn == "crest" else " (середина склона x=L, подножие x=2L, UC Davis 2D, там же)") + \
                  "; панели SWC-16: однородный фон, z = " + ("0.13H (нижняя точка 5 мм)" if name == "UCD" else f"{zc / RC.LW_H:.2f}H")
            rows.append(RC.mk_row(case, var, pn, xx, zz, "tunnel", src, "труба", ref, None, r["u"][k] / up - 1.0, None, "dS", ds, r))
    rot = []
    for var, r in res.items():
        rp, Lp = C.rotor_of(r, [0.0], 0.0, x_end)
        rot.append(dict(case=case, variant=var, rotor_pan=bool(rp), L_pan=Lp, rotor_ref=None, L_ref=None, ref_source="в статье не приведено"))
    return rows, rot, res, dict(L=L, H=RC.LW_H, bg="uniform", z_cmp=zc)


def main():
    c = sys.argv[1]
    t0 = time.time()
    if c in ("C1", "C2", "C4"):
        rows, rot, res, info = case_cc(c, 25.0, True); tag = "_cc"
    else:
        rows, rot, res, info = case_lw_uni(c[3:], 25.0, True); tag = "_uni"
    sm = {}
    for var, r in res.items():
        sm[var] = {k: (float(v) if isinstance(v, (int, float, np.floating)) else None) for k, v in r.items()
                   if k in ("t_solve_ms", "t_query_us", "t_step_ms", "n_vortices", "dt", "n_steps", "t_model", "t_span", "drift_u", "born", "lost", "umax", "n_panels")}
        sm[var]["shed"] = r["shed"]
        sm[var]["rotor_line"] = dict(x=np.round(r["xl"], 1).tolist(), u=[None if not np.isfinite(v) else round(float(v), 3) for v in r["ul"]])
    out = dict(case=c, ds_min=25.0, wall_s=time.time() - t0, rows=rows, rotor=rot, info=info, summary=sm)
    fn = os.path.join(C.CASES_DIR, c + tag + ".json")
    json.dump(out, open(fn + ".tmp", "w"), ensure_ascii=False, default=lambda o: o.tolist() if hasattr(o, "tolist") else str(o))
    os.replace(fn + ".tmp", fn)
    print(c, "rows", len(rows), "wall %.1f" % out["wall_s"], fn)


if __name__ == "__main__":
    main()
