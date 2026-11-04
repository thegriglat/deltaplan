"""Сборщик квази-2D случаев R1 для cascade-2d (F0): C0-C3 (+C4 по возможности) на dx 400/200/100/50/25 м.

    tools/research/cascade_2d/py tools/research/cascade_2d/cases/build_cases.py [--cases C0,C1] [--dx 400,200]

Выход: $CASCADE2D_DATA/cases/<C>_d<dx>.{json,bin} (формат R1, docs/contracts/air-cascade.md).
Подготовка (Air.__init__ + init_background) идёт через air3d/air.py (CuPy, float64); итерации Пикара не делаются.
Параметры физики — params случая игры ongudai_d400_u3_mech_h1200.json, кроме sponge_axes="x" (квази-2D),
alpha/max_profile (по условиям случая) и того, что зависит от сетки (dtau_u = dtau_per_m*dx).
"""
from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
from dataclasses import replace
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
AIR3D = HERE.parents[1] / "air3d"
sys.path.insert(0, str(HERE.parent / "contract"))
sys.path.insert(0, str(AIR3D))  # air3d/synth.py раньше contract/synth.py

import air as A  # noqa: E402
import synth as SY  # noqa: E402
from cascade2d_io import LEVELS_DX, data_dir  # noqa: E402

NY = int(os.environ.get("CASCADE2D_NY", "4"))
TOP = 2500.0
YMIRROR = os.environ.get("CASCADE2D_YMIRROR", "1") == "1"
GAME_CASE = Path.home() / "data/air_cascade/ongudai/ongudai_d400_u3_mech_h1200.json"
GAM_N = SY.GAM_N
# нулевой уровень h в метрах для M1: x_c, L
CASES = {
    "C0": dict(U10=5.0, N=0.0, hill=None, heat=False),
    "C1": dict(U10=5.0, N=0.0, hill=(200.0, 500.0), heat=False),
    "C2": dict(U10=8.0, N=0.01, hill=(250.0, 300.0), heat=False),
    "C3": dict(U10=1.0, N=None, hill=(200.0, 500.0), heat=True),
    "C4": dict(U10=5.0, N=0.0, hill="askarovo", heat=False),
}
LOC = Path.home() / ".local/share/Deltaplan/locations/askarovo"      # собранная игрой локация (нужна только C4)
LOC_CFG = HERE.parents[3] / "configs/locations/askarovo.json"


def askarovo_profile():
    """Разрез Аскарово по ветру 270 (вдоль +x) через старт biyagoda_west: высоты (512 колонн по 25 м, x от -6400, X = 0 в точке
    старта), сдвинутые так, чтобы минимум разреза был 0. Источник — detail.webp игры (Copernicus GLO-30, шаг 25 м)."""
    from PIL import Image
    meta = json.loads((LOC / "meta.json").read_text())
    ly = next(l for l in meta["layers"] if l["id"] == "detail")
    im = np.asarray(Image.open(LOC / ly["file"]).convert("RGB")).astype(np.int64)
    dem = ly["min_height_m"] + ((im[..., 0] << 16) | (im[..., 1] << 8) | im[..., 2]) * ly["height_step_m"]
    cfg = json.loads(LOC_CFG.read_text())
    site = next(s_ for s_ in cfg["start_sites"] if s_["id"] == "biyagoda_west")
    R = meta["earth_radius_m"]
    xs = R * math.radians(site["lon"] - meta["center_lon"]) * math.cos(math.radians(meta["center_lat"]))
    zs = -R * math.radians(site["lat"] - meta["center_lat"])
    X = -6400.0 + (np.arange(512) + 0.5) * 25.0
    cx = (xs + X - ly["origin_x_m"]) / ly["spacing_m"]
    cz = (zs - ly["origin_z_m"]) / ly["spacing_m"]
    c0, r0 = np.floor(cx).astype(int), int(np.floor(cz))
    fx, fz = cx - c0, cz - r0
    h = ((1 - fx) * (1 - fz) * dem[r0, c0] + fx * (1 - fz) * dem[r0, c0 + 1]
         + (1 - fx) * fz * dem[r0 + 1, c0] + fx * fz * dem[r0 + 1, c0 + 1])
    h_site = float(np.interp(0.0, X, h))
    base = float(h.min())
    h = h - base
    near = np.abs(X) <= 2000.0
    ic = int(np.argmax(np.where(near, h, -1e9)))
    xc, Hc = float(X[ic]), float(h[ic])
    up = (X >= xc - 3000.0) & (X <= xc)
    hb = float(h[up].min())
    H = Hc - hb
    half = hb + H / 2
    iw = np.where((X <= xc) & (h <= half))[0]
    Lw = float(xc - X[iw.max()]) if iw.size else float("nan")
    info = dict(x_c=xc, L=Lw, H=H, crest_asl_m=Hc + base, base_asl_m=base, site_asl_m=h_site,
                site_x_world_m=xs, site_z_world_m=zs, source="Copernicus GLO-30 via detail.webp of the game location")
    return h, info
ARRS = ["hc", "cell", "tu", "tv", "tw", "nu_bg", "Q", "gam", "cplz", "sp_u", "sp_w", "spc", "ubg", "vbg", "lam",
        "Kx", "Ky", "Kz", "fixed_u", "fixed_v", "b_u", "b_v"]
STATE = ["u", "v", "w", "th", "thd", "p"]


def git_hash():
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=HERE, text=True).strip()
    except Exception:
        return None


def game_params():
    d = json.loads(GAME_CASE.read_text())
    keys = set(A.Params.__dataclass_fields__)
    return {k: v for k, v in d["params"].items() if k in keys}, d


def make_params(spec):
    p, _ = game_params()
    p["sponge_axes"] = "x"           # квази-2D: губки только по x
    p["max_profile"] = None          # по правилу z_sat при alpha и U10 случая
    return A.Params(**p)


def make_inputs(name, dx):
    sp = CASES[name]
    dz = dx / 4.0
    g = SY.grid2d(float(dx), 12800.0, TOP, dz=dz, ny=NY)
    assert g.nx == int(12800 // dx) and abs(g.x0 + 6400) < 1e-9 and abs(g.z_bot + dz) < 1e-9
    prof = None
    if sp["hill"] == "askarovo":
        h25, prof = askarovo_profile()
        hc1 = h25.reshape(g.nx, -1).mean(axis=1)       # блочное среднее 25 м -> колонны уровня (вложенность)
    elif sp["hill"]:
        hc1 = SY.agnesi(g.x, *sp["hill"])
    else:
        hc1 = np.zeros(g.nx)
    hc = np.tile(hc1, (g.ny, 1))
    if sp["heat"]:
        zi = 1500.0
        # как fixtures.heated_slope: sun_flux az 100, el 45; слой перемешивания 1500 м; gam над ним 5,8 К/км
        case = A.Case(U10=sp["U10"], wdir=270.0, gam=SY.cbl_gam(zi, 5.8e-3), z_i=zi,
                      H=SY.sun_flux(hc, g.dx, az=100.0, el=45.0), label=f"{name}")
    else:
        case = A.Case(U10=sp["U10"], wdir=270.0, gam=SY.const_gam(sp["N"] ** 2 * A.THETA0 / A.G), label=name)
    return g, hc, case, prof


def G(a):
    return a.get() if hasattr(a, "get") else np.asarray(a)


def build(name, dx, outdir):
    g, hc, case, prof = make_inputs(name, dx)
    prm = make_params(name)
    S = A.Air(g, hc, case, prm, dtype=np.float64, taper=True)
    S.init_background()
    NZ, NY_, NX = S.shape
    parts, arrays, off = [], {}, 0

    def add(n, a):
        nonlocal off
        a = np.ascontiguousarray(np.asarray(a, np.float64)).astype("<f4").ravel()
        arrays[n] = [off, int(a.size)]
        parts.append(a)
        off += a.size

    cell_a = S.cell_np.copy()
    tu_a, tv_a, tw_a = S.tu_np.copy(), S.tv_np.copy(), S.tw_np.copy()
    if YMIRROR:
        # зеркальные y-края: ряды ореола по y для u, w - тип 0 (стенка): решатель пропускает диффузию через такую грань
        # (kernels.rs mom_cell: tt[q]==0 при d != comp -> нулевой градиент), а не держит фон ubg (тип 3, Дирихле).
        # v на y-гранях уже фиксирован fixed_v (vbg = 0 при ветре вдоль x) - стенка v = 0.
        for t in (tu_a, tw_a):
            t[:, 0, :] = 0
            t[:, -1, :] = 0
        # клетки ореола по y - "земля" (cell 0): kloc берёт односторонний градиент вместо ореола с нулевой скоростью
        cell_a[:, 0, :] = 0
        cell_a[:, -1, :] = 0
    add("hc", hc)
    add("cell", cell_a); add("tu", tu_a); add("tv", tv_a); add("tw", tw_a)
    add("nu_bg", S.nu_np); add("Q", S.Q_np); add("gam", S.gam_np)
    add("cplz", S.cplz_np); add("sp_u", S.sp_np); add("sp_w", S.spw_np); add("spc", S.spc_np)
    add("ubg", S.ubg_np); add("vbg", S.vbg_np); add("lam", S.lam_np)
    add("Kx", S.Kx_np); add("Ky", S.Ky_np); add("Kz", S.Kz_np)
    add("fixed_u", G(S.fixed_u)); add("fixed_v", G(S.fixed_v))
    add("b_u", G(S.b_u)); add("b_v", G(S.b_v))
    for k in STATE:                                   # эталона, кроме самого Пикара, нет: нули
        add("sol_" + k, np.zeros(S.shape))
    stem = f"{name}_d{dx}"
    outdir.mkdir(parents=True, exist_ok=True)
    np.concatenate(parts).tofile(str(outdir / (stem + ".bin.tmp")))
    os.replace(outdir / (stem + ".bin.tmp"), outdir / (stem + ".bin"))
    sp = CASES[name]
    hill = sp["hill"]
    meta = dict(
        format="ref-case", version=1, case=stem, dims=[NX, NY_, NZ], halo=1, dx=g.dx, dz=g.dz, z_bot=g.z_bot,
        x0=g.x0, y0=g.y0, nx=g.nx, ny=g.ny, nz=g.nz,
        params={k: getattr(S.prm, k) for k in S.prm.__dataclass_fields__},
        case_params=dict(U10=case.U10, wdir=case.wdir, z_i=case.z_i, U_aloft=S.U_a, label=case.label,
                         x_c=(prof["x_c"] if prof else 0.0), L=(prof["L"] if prof else hill[1] if hill else 500.0),
                         H=(prof["H"] if prof else hill[0] if hill else 0.0), profile=prof,
                         N=sp["N"], cascade_case=name, level_dx=dx),
        cd=S.cd, fixed_scale=S.fixed_scale, n_fluid=S.n_fluid, closure=S.closure_info,
        mg_levels_xyz=[list(L["shape"])[::-1] for L in S.mg.levels],
        criterion=dict(tol_mom_rms=2e-5, tol_th_rms=5e-7, tol_div_rms=1e-6, check_every=10),
        source=dict(builder="tools/research/cascade_2d/cases/build_cases.py", contract="cascade-2d F0 v1",
                    params_from=str(GAME_CASE.name), dtype="float64", git=git_hash(), sol="zeros"),
        arrays=arrays,
        notes="Квази-2D: рельеф и вход постоянны по y, sponge_axes=x; sol_* — нули (эталон — сам picard_rs).",
    )
    tmp = outdir / (stem + ".json.tmp")
    tmp.write_text(json.dumps(meta, ensure_ascii=False, indent=1))
    os.replace(tmp, outdir / (stem + ".json"))
    print(f"{stem}: nx={g.nx} ny={g.ny} nz={g.nz} dz={g.dz} cells={g.nx*g.ny*g.nz} "
          f"U_aloft={S.U_a:.3f} alpha={S.prm.alpha} max_profile={S.prm.max_profile:.4f}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", default="C0,C1,C2,C3,C4")
    ap.add_argument("--dx", default=",".join(str(d) for d in LEVELS_DX))
    a = ap.parse_args()
    out = Path(data_dir()) / "cases"
    for c in a.cases.split(","):
        for dx in (int(d) for d in a.dx.split(",")):
            build(c, dx, out)


if __name__ == "__main__":
    main()
