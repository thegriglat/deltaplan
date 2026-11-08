"""SWC-16 (1): скан факторов недобора dS потенциальных панелей против труб Lubitz & White 2007.
Запуск: OPENBLAS_NUM_THREADS=1 tools/research/cascade_2d/py tools/research/sw_charges/panels_exp/scan_lw.py
Пишет out/panels2d/tunnel/scan_lw.json. Только вариант potential (вихри к dS на гребне не меняют знака: SWC-12)."""
import json, os, sys, itertools
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C
from common import Terrain, bg_profile, build_panels, solve, velocity
from panels2d import bg_uniform

H = 400.0
# H/L1, dS набл. (макс.), z/H максимума (None = «поверхность» = нижняя точка измерений), alpha трубы (UC Davis 0.19 — в статье; прочие неизвестны)
LW = {"H3": (0.67, 1.08), "MD": (0.63, 0.80), "UCD": (0.53, 0.68), "H5": (0.40, 0.70), "GI": (0.31, 0.61), "H8": (0.25, 0.35)}
ZH_OBS = {"H3": None, "MD": 0.10, "UCD": None, "H5": None, "GI": 0.15, "H8": 0.15}
# высота сравнения SWC-12: «у поверхности» = 0.05 H, иначе z/H таблицы
Z_SW12 = {m: (0.05 if ZH_OBS[m] is None else ZH_OBS[m]) for m in LW}


def shape(kind, L):
    """z(x), L — полуширина на половине высоты (как у Lubitz & White: L1 для cos^2, полудлина основания 2L)."""
    x = np.arange(-6000.0, 6000.1, 10.0)
    if kind == "cos2":                       # h/2+h/2 cos(pi x/(2 L1)) = h cos^2(pi x/(4 L1)); L1 — до половины высоты
        z = np.where(np.abs(x) < 2 * L, H * np.cos(np.pi * x / (4 * L)) ** 2, 0.0)
    elif kind == "agnesi":                   # h/(1+(x/a)^2), a = L
        z = H / (1 + (x / L) ** 2)
    elif kind == "gauss":                    # половина высоты при x = L → sigma = L/sqrt(2 ln2)
        z = H * np.exp(-0.5 * (x / (L / np.sqrt(2 * np.log(2)))) ** 2)
    elif kind == "cos4":                     # прокси «Cos2» Gong–Ibbetson (определение в статье не дано): cos^4
        W = L / 0.3652
        z = np.where(np.abs(x) < W, H * np.cos(np.pi * x / (2 * W)) ** 4, 0.0)
    return x, z


def dS_at(kind, HL, alpha, smooth, zlist, ref="agl", ds=25.0, xup=-4000.0, return_prof=False):
    L = H / HL
    x, z = shape(kind, L)
    terr = Terrain(x, z)
    if alpha is None:
        bg = bg_uniform(1.0)
    else:
        bg = bg_profile(1.0, alpha, 10 * H, terr, smooth_m=smooth)
    P = build_panels(terr, x_focus=0.0, ds_min=ds)
    sig = solve(P, bg)
    zl = np.atleast_1d(np.asarray(zlist, float))
    g0, gu = float(P.ground(np.array([0.0]))[0]), float(P.ground(np.array([xup]))[0])
    if ref == "agl":                         # как в трубе: на той же высоте над землёй
        uc, _ = velocity(P, sig, bg, np.zeros_like(zl), g0 + zl)
        uu, _ = velocity(P, sig, bg, np.full_like(zl, xup), gu + zl)
    else:                                    # «над уровнем подножия»: z — над уровнем равнины, гребень на H
        uc, _ = velocity(P, sig, bg, np.zeros_like(zl), H + zl)
        uu, _ = velocity(P, sig, bg, np.full_like(zl, xup), gu + H + zl)
    return uc / uu - 1.0


def main():
    out = dict(H=H, models={m: dict(HL=LW[m][0], dS_obs=LW[m][1], zH_obs=ZH_OBS[m]) for m in LW})
    zprof = np.array([0.02, 0.05, 0.075, 0.10, 0.13, 0.15, 0.20, 0.30, 0.50, 1.0])
    base = dict(kind="cos2", alpha=0.15, smooth=250.0, ref="agl")
    # baseline profile dS(z/H) per model
    out["base_profile"] = {m: dict(zH=zprof.tolist(), dS=dS_at("cos2", LW[m][0], 0.15, 250.0, zprof * H).tolist()) for m in LW}
    scans = {
        "profile": [("uniform", dict(alpha=None)), ("a0.10", dict(alpha=0.10)), ("a0.15", dict(alpha=0.15)), ("a0.19", dict(alpha=0.19)), ("a0.25", dict(alpha=0.25))],
        "smooth_m": [(f"s{s}", dict(smooth=float(s))) for s in (0, 50, 250, 1000)],
        "shape": [(k, dict(kind=k)) for k in ("cos2", "agnesi", "gauss", "cos4")],
        "z_cmp": [(f"z{z}H", dict(zH=z)) for z in (0.02, 0.05, 0.10, 0.13, 0.15, 0.20)] + [("z_obs", dict(zH="obs"))],
        "ref_def": [("agl", dict(ref="agl")), ("abs_foot", dict(ref="abs"))],
        "ds_min": [("ds50", dict(ds=50.0)), ("ds25", dict(ds=25.0)), ("ds12.5", dict(ds=12.5))],
    }
    res = {}
    for fac, items in scans.items():
        res[fac] = {}
        for name, kw in items:
            res[fac][name] = {}
            for m in LW:
                p = dict(base); p["ds"] = 25.0
                zH = Z_SW12[m]
                for k, v in kw.items():
                    if k == "zH":
                        zH = ZH_OBS[m] or 0.05 if v == "obs" else v
                        if v == "obs": zH = 0.13 if m == "UCD" else (ZH_OBS[m] or 0.05)
                    else:
                        p[k] = v
                ref = p.pop("ref"); kind = p.pop("kind"); a = p.pop("alpha"); s = p.pop("smooth"); ds = p.pop("ds")
                zs = np.linspace(0.02, 1.0, 50) * H
                dmax = float(np.max(dS_at(kind, LW[m][0], a, s, zs, ref=ref, ds=ds)))
                d = float(dS_at(kind, LW[m][0], a, s, [zH * H], ref=ref, ds=ds)[0])
                res[fac][name][m] = dict(dS=d, dS_maxz=dmax, zH=zH)
    out["scan"] = res
    # полный факторный перебор профиль x сглаживание (cos2, agl) на z_SW12 и z_obs(UCD 0.13)
    fac = {}
    for a, s in itertools.product((None, 0.10, 0.15, 0.19, 0.25), (0.0, 50.0, 250.0, 1000.0)):
        key = f"{'uni' if a is None else a}|{int(s)}"
        fac[key] = {m: float(dS_at("cos2", LW[m][0], a, s, [Z_SW12[m] * H])[0]) for m in LW}
    out["factorial_alpha_smooth"] = fac
    # контроль: u_up(x=-4000) против невозмущённого профиля без земли
    L = H / 0.53; x, z = shape("cos2", L); terr = Terrain(x, z); bg = bg_profile(1.0, 0.15, 10 * H, terr, smooth_m=250.0)
    P = build_panels(terr, x_focus=0.0, ds_min=25.0); sig = solve(P, bg)
    zz = np.array([20.0, 60.0, 200.0])
    u, _ = velocity(P, sig, bg, np.full(3, -4000.0), zz)
    out["upstream_check"] = dict(z=zz.tolist(), u_over_flat_profile=(u / (zz / 10) ** 0.15).tolist())
    fn = os.path.join(C.OUT, "tunnel", "scan_lw.json")
    json.dump(out, open(fn, "w"), indent=1)
    print("ok", fn)


if __name__ == "__main__":
    main()
