"""SWC-19: потенциал и вихри с внутренним слоем Jackson–Hunt (potential_jh, vortex_jh; SW6 v4) на тех же случаях и точках, что SWC-17.
Запуск: OPENBLAS_NUM_THREADS=1 tools/research/sw_charges/py -I panels_exp/run_jh.py <C1|C2|C4|PERD_NE|PERD_SW|LW_H3|...>
Пишет out/panels2d/cases/<case>_jh.json (rows: potential [тот же фон, справочно], potential_jh, vortex_jh).
C1/C2/C4/PERD — постановка SWC-16/12 (run_cc.case_cc, run_case.case_perd) с подменой run_variants; LW — масштабированная (см. README)."""
import json, math, os, sys, time
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C
import run_case as RC
import run_cc as RCC
import jh_common as B
from common import Terrain, bg_profile

LW_Z0_RATIO = 0.18e-3 / 38e-3        # z0/H трубы UC Davis: z0 0,16–0,20 мм, H = 38 мм (Lubitz & White 2007)
LW_Z0 = 0.1
LW_H_BL = LW_Z0 / LW_Z0_RATIO        # ≈ 21,1 м: хребет масштабирован так, что z0 = 0,1 м (как в библиотеке: δ0 = 500·z0 = 50 м)
LW_ALPHA = {"UCD": 0.19}              # UC Davis — по статье; остальным (EPA, G&I) профиль неизвестен: 0,15 как в SWC-12


def wrapper(*a, **kw):
    kw.pop("variants", None)
    return B.run_jh_variants(*a, **kw)


def case_lw_bl(name, ds_unused, vortex, H=None):
    HL, smax, dS_ref, zH = RC.LW[name]
    H = LW_H_BL if H is None else H
    k = H / RC.LW_H
    L = H / HL
    ds = 25.0 * k
    alpha = LW_ALPHA.get(name, RC.LW_ALPHA)
    x = np.arange(-6000.0 * k, 6000.1 * k, 10.0 * k)
    z = np.where(np.abs(x) < 2 * L, H * np.cos(np.pi * x / (4 * L)) ** 2, 0.0)
    terr = Terrain(x, z)
    bg = bg_profile(1.0, alpha, 10 * H, terr, smooth_m=10 * ds, z0=LW_Z0)
    zc = (5.0 / 38.0 if name == "UCD" else (RC.LW_SURF if zH is None else zH)) * H
    pts = [("upstream", -4000.0 * k, zc), ("crest", 0.0, zc)]
    if name == "UCD":
        pts += [("windward", -L, zc), ("foot", -2 * L, zc)]
    x_end = max(3000.0 * k, 5 * L)
    res = B.run_jh_variants(terr, bg, pts, [0.0], 0.0, x_end, ds_min=ds, u_adv=5.0 ** alpha, z0=LW_Z0)
    rows, case = [], "LW_" + name
    extra = {"windward": 0.24, "foot": -0.27}
    for var, r in res.items():
        up = r["u"][0]
        for kk, (pn, xx, zz) in enumerate(pts):
            if pn == "upstream":
                continue
            ref = dS_ref if pn == "crest" else extra[pn]
            src = RC.LW_SRC + ("" if pn == "crest" else " (середина склона x=L, подножие x=2L, UC Davis 2D, там же)") + \
                  f"; панели SWC-17: масштаб H = {H:.1f} м (z0/H = {LW_Z0 / H:.4f}, z0 = {LW_Z0} м), профиль α = {alpha}, z = " + \
                  ("0.13H (нижняя точка 5 мм)" if name == "UCD" else f"{zc / H:.2f}H")
            rows.append(RC.mk_row(case, var, pn, xx, zz, "tunnel", src, "труба", ref, None, r["u"][kk] / up - 1.0, None, "dS", ds, r))
    rot = []
    return rows, rot, res, dict(L=L, H=H, scale_k=k, alpha=alpha, z0=LW_Z0, bg="profile", z_cmp=zc, ds_min=ds)


def main():
    c = sys.argv[1]
    Hs = float(sys.argv[2]) if (len(sys.argv) > 2 and c.startswith("LW_")) else None      # LW: высота хребта, м (чувствительность к δ0/H); по умолчанию z0/H как в трубе
    tag = "_jh" if Hs is None else f"_jh_H{Hs:g}"
    if c.startswith("PERD_") and len(sys.argv) > 2:           # PERD: z0 слоя вместо z0_nominal (чувствительность: δ0 = 500·z0)
        tag = f"_jh_z0_{sys.argv[2]}"
    t0 = time.time()
    C.run_variants = wrapper
    if c in ("C1", "C2", "C4"):
        B.Z0["z0"] = 0.1
        rows, rot, res, info = RCC.case_cc(c, 25.0, False)
        ds = 25.0
    elif c.startswith("PERD_"):
        sys.path.insert(0, os.path.join(C.REPO, "tools", "research", "cases"))
        import perdigao as PD
        B.Z0["z0"] = float(sys.argv[2]) if len(sys.argv) > 2 else round(PD.z0_nominal(), 3)
        rows, rot, res, info = RC.case_perd(c[5:].lower(), 25.0, False, 40.0)
        ds = 25.0
    else:
        B.Z0["z0"] = LW_Z0
        rows, rot, res, info = case_lw_bl(c[3:], 25.0, True, Hs)
        ds = info["ds_min"]
    info["z0_bl"] = B.Z0["z0"]
    keys = ("t_solve_ms", "t_query_us", "t_step_ms", "n_vortices", "dt", "n_steps", "t_model", "t_span", "drift_u", "born", "lost",
            "umax", "n_panels", "t_bl_ms", "sep_n_mean", "sep_x_mean")
    sm = {}
    for var, r in res.items():
        sm[var] = {kk: (float(v) if isinstance(v, (int, float, np.floating)) else None) for kk, v in r.items() if kk in keys}
        sm[var]["shed"] = bool(r["shed"])
        sm[var]["sep"] = r.get("bl")
        sm[var]["sep_x_all"] = r.get("sep_x_all")
        sm[var]["rotor_line"] = dict(x=np.round(r["xl"], 1).tolist(), u=[None if not np.isfinite(v) else round(float(v), 3) for v in r["ul"]])
    out = dict(case=c, ds_min=ds, wall_s=time.time() - t0, rows=rows, rotor=rot, info=info, summary=sm)
    fn = os.path.join(C.CASES_DIR, c + tag + ".json")
    json.dump(out, open(fn + ".tmp", "w"), ensure_ascii=False, default=lambda o: o.tolist() if hasattr(o, "tolist") else str(o))
    os.replace(fn + ".tmp", fn)
    print(c, "rows", len(rows), "wall %.1f" % out["wall_s"], fn)


if __name__ == "__main__":
    main()
