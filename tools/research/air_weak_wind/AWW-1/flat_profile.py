"""AWW-1, диагноз 2: приземный профиль решателя на ровной земле (эталон tools/research/air3d/air.py — тот же
решатель, что air_picard.glsl). Ровный рельеф, приток — профиль игры (степенной до z_sat), замыкание hb + local_k.
Выборка как в игре (WindField.sample): ниже центра первой клетки — лог-профиль к z0, выше — линейно между центрами.
Вопрос: даёт ли сам решатель u10/u100 ≈ 0,45 (как в окнах у стартов) или ≈ профиль притока.
Запуск (venv с CuPy): $VENV/bin/python flat_profile.py > out/flat_profile.json
"""
import json
import math
import sys
from dataclasses import replace
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "air3d"))
import air as A  # noqa: E402
import synth as SY  # noqa: E402

KAPPA = 0.4


def sample_col(S, i, j):
    """Профиль |U_h| в столбце (i, j) по центрам клеток (nz,), высоты над землёй."""
    uc, vc, wc, th = S.centers()
    z = S.g.z - S.hc[j, i]
    U = np.sqrt(uc[:, j, i] ** 2 + vc[:, j, i] ** 2)
    return z, U, th[:, j, i]


def at_agl(z, U, agl, z0):
    k = np.where(np.isfinite(U))[0]
    z, U = z[k], U[k]
    if agl <= z[0]:
        return U[0] * math.log(max(agl, z0) / z0) / math.log(z[0] / z0)
    return float(np.interp(agl, z, U))


def inflow(agl, prm, u10):
    return u10 * prm.max_profile * SY.A.wind_profile(np.asarray(agl, float), prm)


def run_case(name, dx, dz, n, top, u10, z0, H, zi_agl, alpha, over=None, max_outer=3000):
    nz = int(math.ceil(top / dz)) + 1
    nz += nz % 2
    g = A.Grid(dx, n, n, dz, -dz, nz, 0.0, 0.0)
    hc = np.zeros((n, n))
    prm = A.Params(z0=z0, alpha=alpha, **(over or {}))
    if H > 0:
        case = A.Case(U10=u10, wdir=270.0, H=np.full((n, n), H), z_i=zi_agl, gam=SY.cbl_gam(zi_agl, 0.004))
    else:
        case = A.Case(U10=u10, wdir=270.0, gam=SY.const_gam(0.003))
    S = SY.run(g, hc, case, prm, max_outer=max_outer)
    prm = S.prm
    rows = []
    # центр и три точки по оси ветра (вход → выход): x = 1/4, 1/2, 3/4
    for frac in (0.25, 0.5, 0.75):
        i = int(n * frac)
        j = n // 2
        z, U, th = sample_col(S, i, j)
        u10m = at_agl(z, U, 10.0, z0)
        u100 = at_agl(z, U, 100.0, z0)
        u50 = at_agl(z, U, 50.0, z0)
        u2 = at_agl(z, U, 2.0, z0)
        k = np.where(np.isfinite(U))[0]
        rows.append({
            "x_frac": frac, "u2": u2, "u10": u10m, "u50": u50, "u100": u100, "r10_100": u10m / u100,
            "u_first": float(U[k[0]]), "z_first": float(z[k[0]]),
            "prof": [[float(z[q]), float(U[q]), float(th[q])] for q in k[:12]],
        })
    inf10 = inflow(10.0, prm, u10)
    inf100 = inflow(100.0, prm, u10)
    info = SY.info(S)
    out = {
        "name": name, "dx": dx, "dz": dz, "n": n, "u10_menu": u10, "z0": z0, "H": H, "zi_agl": zi_agl,
        "alpha": alpha, "over": over or {}, "max_profile": prm.max_profile,
        "inflow": {"u10": float(inf10), "u100": float(inf100), "r10_100": float(inf10 / inf100)},
        "status": info["status"], "iters": info["iters"], "closure": info["closure"], "cols": rows,
    }
    print(f"{name}: {info['status']} {info['iters']} it; centre u10 {rows[1]['u10']:.3f} u100 {rows[1]['u100']:.3f} "
          f"r {rows[1]['r10_100']:.3f} (приток r {inf10 / inf100:.3f}, u10 {inf10:.2f} u100 {inf100:.2f})",
          file=sys.stderr)
    return out


def main():
    res = []
    # окно 50 м (dz 25), старт «Термики»: z0 0,03, 2 м/с, класс A (α 0,112), H 300, z_i 1550 м
    base = dict(dx=50.0, dz=25.0, n=64, top=2000.0, u10=2.0, z0=0.03, H=300.0, zi_agl=1550.0, alpha=0.112)
    res.append(run_case("w50_conv", **base))
    res.append(run_case("w50_neutral", **{**base, "H": 0.0, "alpha": 0.24}))
    res.append(run_case("w50_conv_z0_0.1", **{**base, "z0": 0.1}))
    res.append(run_case("w50_conv_z0_1", **{**base, "z0": 1.0}))
    res.append(run_case("w50_neutral_z0_1", **{**base, "H": 0.0, "alpha": 0.24, "z0": 1.0}))
    res.append(run_case("w50_conv_u6", **{**base, "u10": 6.0, "alpha": 0.24}))
    res.append(run_case("w50_neutral_u6", **{**base, "u10": 6.0, "alpha": 0.24, "H": 0.0}))
    # переключатели замыкания
    res.append(run_case("w50_conv_lam_inf", **base, over={"lam": 1e9, "lam_frac": 0.0}))
    res.append(run_case("w50_neutral_lam_inf", **{**base, "H": 0.0, "alpha": 0.24}, over={"lam": 1e9, "lam_frac": 0.0}))
    res.append(run_case("w50_conv_nolocal", **base, over={"local_k": False}))
    res.append(run_case("w50_neutral_nolocal", **{**base, "H": 0.0, "alpha": 0.24}, over={"local_k": False}))
    res.append(run_case("w50_conv_surface_heat", **base, over={"heat_mode": "surface"}))
    # окно 100 м (dz 50) и область 400 м (dz 105)
    res.append(run_case("w100_conv", **{**base, "dx": 100.0, "dz": 50.0}))
    res.append(run_case("w100_neutral", **{**base, "dx": 100.0, "dz": 50.0, "H": 0.0, "alpha": 0.24}))
    res.append(run_case("d400_conv", **{**base, "dx": 400.0, "dz": 105.0, "n": 48, "top": 3000.0}))
    res.append(run_case("d400_neutral", **{**base, "dx": 400.0, "dz": 105.0, "n": 48, "top": 3000.0, "H": 0.0, "alpha": 0.24}))
    print(json.dumps(res, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
