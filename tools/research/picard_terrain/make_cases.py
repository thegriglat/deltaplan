"""PT-1: случаи опыта PT1 (R1 + ключ `pt`) для Askervein, Каянчи и Perdigão; решение air3d (CuPy, f64) и снимки R4.

  PY=tools/research/sw_charges_3d/py
  $PY tools/research/picard_terrain/make_cases.py                 # все 9 случаев
  $PY tools/research/picard_terrain/make_cases.py askervein_d100  # выборочно

Случаи (имя = <site>_d<dx>):
  dx >= 30 м (askervein_d100/d50, kayancha_d100/d50, perdigao_{ne,sw}_d30) — сетки игры: air3d 1-й порядок (adv2 = false),
      float64, решение до критерия кладётся в sol_* (сверка порта picard_rs, R2 dev.u_rel) и в D/states/<case>_air3d.
  dx <= 25 м (askervein_d25, d12p5, kayancha_d25) — эталон: air3d adv2 = true, limiter = 1 (ван Лир), float64;
      в .bin решения нет (R6 v3), поле — D/states/<case>_air3d.{json,bin} (R4 v2, f32).
Растр подсетки PT1 — D/terrain/<site>.h5 (h float32, x0, y0 — узел [0,0], dx = 30): среднее по квадрату 30 м вокруг узла
(6x6 подвыборок по 5 м) исходного рельефа; Perdigão — один файл на оба случая.
Запись run-справок air3d (для строк PT4) — out/PT-1/air3d_runs/<case>.json.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from dataclasses import replace
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
for p in (ROOT / "tools/research/air3d", ROOT / "tools/research/cases", HERE):
    sys.path.insert(0, str(p))
import air as A  # noqa: E402
import air3d_state as ST  # noqa: E402

D = Path(os.environ.get("PICARD_TERRAIN_DATA", "~/data/picard_terrain")).expanduser()
OUT = HERE / "out" / "PT-1"
TOL = dict(tol_mom=2e-5, tol_th=5e-7, tol_div=1e-6)
CHECK_EVERY = 10
MAX_OUTER = 4000
R_EARTH = 6371008.8
RS_NODE = 30.0     # шаг растра подсетки, м
SUB = 6            # подвыборок на сторону 30-м квадрата (5 м)
NAMES = ["askervein_d100", "askervein_d50", "askervein_d25", "askervein_d12p5",
         "kayancha_d100", "kayancha_d50", "kayancha_d25", "perdigao_ne_d30", "perdigao_sw_d30"]
F32_CASES = {"askervein_d12p5"}   # 16,6 млн клеток: float64 не помещается в 12 ГБ GPU (OOM при 10 ГБ), счёт float32 как в reference.md
STATE_NAMES = ("u", "v", "w", "th", "thd", "p")


def split(name):
    site, d = name.rsplit("_d", 1)
    return site, float(d.replace("p5", ".5"))


# ----------------------------------------------------------------------------------------------- рельеф подсетки
def cell_means(fn, xr0, yr0, nxr, nyr):
    """Растр h (nyr, nxr): среднее fn(x, y) по квадрату 30 м вокруг узла (xr0 + i*30, yr0 + j*30), SUB x SUB точек."""
    s = (np.arange(SUB) + 0.5) / SUB * RS_NODE - RS_NODE / 2
    out = np.zeros((nyr, nxr))
    for j in range(nyr):                      # по строкам (память)
        ys = yr0 + j * RS_NODE + s
        xs = (xr0 + np.arange(nxr)[:, None] * RS_NODE + s[None, :]).ravel()
        Xf, Yf = np.meshgrid(xs, ys)
        out[j] = fn(Xf, Yf).reshape(SUB, nxr, SUB).mean(axis=(0, 2))
    return out


def write_raster(site, fn, x0, y0, L, extra):
    """D/terrain/<site>.h5: узлы со смещением -45 м от x0 (покрывают область с запасом >= 1 узла)."""
    import h5py
    xr0, yr0 = x0 - 1.5 * RS_NODE, y0 - 1.5 * RS_NODE
    n = int(math.ceil(L / RS_NODE)) + 4
    h = cell_means(fn, xr0, yr0, n, n).astype(np.float32)
    path = D / "terrain" / f"{site}.h5"
    path.parent.mkdir(parents=True, exist_ok=True)
    with h5py.File(path, "w") as f:
        ds = f.create_dataset("h", data=h, compression="gzip")
        ds.attrs.update(x0=xr0, y0=yr0, dx=RS_NODE, **extra)
    return dict(path=f"terrain/{site}.h5", dataset="h", x0=xr0, y0=yr0, dx=30), h


# ----------------------------------------------------------------------------------------------- постановки
def _load_air3d(mod):
    """Модуль air3d/<mod>.py по пути (в tools/research/cases есть одноимённый askervein.py)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("air3d_" + mod, ROOT / "tools/research/air3d" / f"{mod}.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def askervein_setup(dx):
    AK = _load_air3d("askervein")
    L, top = 4000.0, 1000.0
    x0, y0, n, hc = AK.terrain(dx, L)
    dz = dx / 2
    nz = int(math.ceil((top + dz) / dz)); nz += nz % 2
    g = A.Grid(dx, n, n, dz, -dz, nz, x0, y0)
    import synth as SY
    prm = A.Params(z0=0.03, alpha=0.17, max_profile=2.0, f_cor=1.22e-4, sponge_side_m=1000.0)
    case = A.Case(U10=8.9, wdir=210.0, gam=SY.const_gam(0.0))
    import matplotlib.tri as mtri
    P = AK.read_map_lines()
    it = mtri.LinearTriInterpolator(mtri.Triangulation(P[:, 0], P[:, 1]), P[:, 2])
    fn = lambda X, Y: np.asarray(it(X, Y).filled(0.0))
    probes = []
    for z in (10, 30, 60, 100):
        probes.append(dict(name=f"HT_{z}", x=AK.HT[0], y=AK.HT[1], z_agl=float(z), role="target", pair=f"RS_{z}"))
        probes.append(dict(name=f"RS_{z}", x=AK.RS[0], y=AK.RS[1], z_agl=float(z), role="norm", pair=None))
    pt = dict(site="askervein", domain_m=[L, L], top_m=top, U10=8.9, wdir_deg=210.0, z0=0.03, heat=False, probes=probes)
    return g, hc, case, prm, pt, fn, dict(z_offset_m=0.0, source="Askervein WAsP .map (Taylor & Teunissen 1987), tools/research/data/askervein")


_KAY = {}


def kayancha_load():
    """Рельеф игры Онгудая (слой detail 25 м, фикстура tests/fixtures/locations/ongudai) -> (h[north-up], x0, y0, sx, sy)."""
    if _KAY:
        return _KAY
    from PIL import Image
    d = ROOT / "tests/fixtures/locations/ongudai"
    meta = json.loads((d / "meta.json").read_text())
    lay = next(l for l in meta["layers"] if l["id"] == "detail")
    a = np.asarray(Image.open(d / lay["file"]).convert("RGB")).astype(np.uint32)
    v = (a[..., 0] << 16) | (a[..., 1] << 8) | a[..., 2]
    h = (lay["height_min_m"] + lay["height_step_m"] * v.astype(np.float64))[::-1].copy()   # север вверх (terrain.py)
    s = lay["spacing_m"]
    x0, y0 = lay["origin_x_m"], -(lay["origin_z_m"] + (lay["height"] - 1) * s)
    site = next(s_ for s_ in json.loads((ROOT / "configs/locations/ongudai.json").read_text())["start_sites"]
                if s_["id"] == "kayancha_south")
    sx = math.radians(site["lon"] - meta["center_lon"]) * meta["earth_radius_m"] * math.cos(math.radians(meta["center_lat"]))
    sy = math.radians(site["lat"] - meta["center_lat"]) * meta["earth_radius_m"]
    _KAY.update(h=h, s=s, x0=x0, y0=y0, sx=sx, sy=sy)
    return _KAY


def kayancha_setup(dx):
    import synth as SY
    K = kayancha_load()
    L = 4000.0
    x0 = round((K["sx"] - L / 2) / 100.0) * 100.0
    y0 = round((K["sy"] - L / 2) / 100.0) * 100.0
    n = int(round(L / dx))
    s, h = K["s"], K["h"]
    f = int(round(dx / s))
    i0, j0 = int(round((x0 - K["x0"]) / s)), int(round((y0 - K["y0"]) / s))
    hc = h[j0:j0 + f * n, i0:i0 + f * n].reshape(n, f, n, f).mean(axis=(1, 3))      # блочное среднее как terrain.block_mean

    def fn(X, Y):                                                   # билинейно по узлам 25 м
        fi = np.clip((X - K["x0"]) / s, 0, h.shape[1] - 1.000001)
        fj = np.clip((Y - K["y0"]) / s, 0, h.shape[0] - 1.000001)
        ii, jj = fi.astype(int), fj.astype(int)
        a, b = fi - ii, fj - jj
        return (1 - b) * ((1 - a) * h[jj, ii] + a * h[jj, ii + 1]) + b * ((1 - a) * h[jj + 1, ii] + a * h[jj + 1, ii + 1])

    big = fn(*np.meshgrid(np.arange(x0, x0 + L, 25.0), np.arange(y0, y0 + L, 25.0)))
    zb = math.floor(big.min() / 100.0) * 100.0 - 100.0
    top = math.ceil((big.max() + 1000.0) / 100.0) * 100.0
    dz = dx / 2
    nz = int(math.ceil((top - zb) / dz)); nz += nz % 2
    g = A.Grid(dx, n, n, dz, zb, nz, x0, y0)
    prm = A.Params(sponge_side_m=1000.0)             # Params по умолчанию (z0 0,1; alpha_N 0,24), губки как у Askervein 4 км
    case = A.Case(U10=6.0, wdir=150.0, gam=SY.const_gam(0.0))
    probes = [dict(name=f"START_{z}", x=K["sx"], y=K["sy"], z_agl=float(z), role="target", pair=None) for z in (20, 30, 50, 100)]
    pt = dict(site="kayancha", domain_m=[L, L], top_m=top, U10=6.0, wdir_deg=150.0, z0=prm.z0, heat=False, probes=probes)
    return g, hc, case, prm, pt, fn, dict(z_offset_m=0.0, source="Copernicus GLO-30 в слое detail игры (25 м), tests/fixtures/locations/ongudai/detail.webp")


def perdigao_setup(dx, sub):
    import perdigao as PD
    g, hc, case, prm, inp, geo = PD.grid_and_case(sub, dx)
    T = PD._terrain10(6000)
    h10 = T["dsm"] - PD.BASE + PD.D_DISP * T["tree"]                # 10 м, как PD.terrain (без блочного среднего)
    ny10, nx10 = h10.shape

    def fn(X, Y):                                                   # кусочно-постоянно по пикселям 10 м, у края — продолжение
        ii = np.clip(np.floor((X - g.x0) / 10.0).astype(int), 0, nx10 - 1)
        jj = np.clip(np.floor((Y - g.y0) / 10.0).astype(int), 0, ny10 - 1)
        return h10[jj, ii]

    prm = replace(prm, adv2=False, limiter=0)                       # схема калибровки (2-й порядок) заменена: база — 1-й порядок
    pts = json.loads((ROOT / "tools/research/sw_charges_3d/out/refs/points.json").read_text())
    key = "PERD_NE" if sub == "ne" else "PERD_SW"
    probes, seen = [], set()
    for r in pts["rows"]:
        if r["case"] == key and r["ref_kind"] == "mast":
            nm = f"{r['name']}_{int(r['z_agl'])}"
            if nm not in seen:
                seen.add(nm)
                probes.append(dict(name=nm, x=r["x"], y=r["y"], z_agl=float(r["z_agl"]), role="mast", pair=None))
    pt = dict(site=f"perdigao_{sub}", domain_m=[geo["L"], geo["L"]], top_m=float(geo["top"]), U10=None,
              U_ref=dict(mast=PD.CASES[sub]["ref"], z_agl=100.0, S=float(inp["u100"]), U10_background=PD.U10_IN[sub]),
              wdir_deg=float(inp["wdir"]), z0=prm.z0, heat=False, probes=probes)
    return g, hc, case, prm, pt, fn, dict(z_offset_m=float(PD.BASE), source=(
        "Copernicus GLO-30 DSM (10 м производное tools/research/cases/perdigao/out/terrain10.npz) - BASE + 0,7*18 м * доля леса; "
        "высоты в системе сетки: уровень моря = h + z_offset_m"))


def setup(site, dx):
    if site == "askervein":
        return askervein_setup(dx)
    if site == "kayancha":
        return kayancha_setup(dx)
    return perdigao_setup(dx, site.split("_")[1])


# ----------------------------------------------------------------------------------------------- решение и запись
INPUT = (("cell", "cell_np"), ("tu", "tu_np"), ("tv", "tv_np"), ("tw", "tw_np"), ("nu_bg", "nu_np"), ("Q", "Q_np"),
         ("gam", "gam_np"), ("cplz", "cplz_np"), ("sp_u", "sp_np"), ("sp_w", "spw_np"), ("spc", "spc_np"),
         ("ubg", "ubg_np"), ("vbg", "vbg_np"), ("lam", "lam_np"), ("Kx", "Kx_np"), ("Ky", "Ky_np"), ("Kz", "Kz_np"))


def make_one(name, resolve_raster=True):
    import cupy as cp
    site, dx = split(name)
    g, hc, case, prm, pt, fn, rattrs = setup(site, dx)
    first_order = dx >= 30
    prm = replace(prm, adv2=not first_order, limiter=0 if first_order else 1)
    # растр подсетки (один файл на site; Perdigão — общий)
    rname = "perdigao" if site.startswith("perdigao") else site
    t = D / "terrain" / f"{rname}.h5"
    L = pt["domain_m"][0]
    terr, _ = write_raster(rname, fn, g.x0, g.y0, L, rattrs) if (resolve_raster and not t.exists()) else (
        dict(path=f"terrain/{rname}.h5", dataset="h", x0=g.x0 - 1.5 * RS_NODE, y0=g.y0 - 1.5 * RS_NODE, dx=30), None)
    t0 = time.perf_counter()
    dt = np.float32 if name in F32_CASES else np.float64
    S = A.Air(g, hc, case, prm, dtype=dt)
    S.init_background()
    st = S.solve(max_outer=MAX_OUTER, check_every=CHECK_EVERY, **TOL)
    S.finalize()
    cp.cuda.Device().synchronize()
    wall = time.perf_counter() - t0
    t_solve = S.wall - S.t_check
    res = S.hist[-1]
    NX, NY, NZ = S.shape[2], S.shape[1], S.shape[0]
    u, v, w, th = S.centers()
    uu, vv, ww = (np.asarray(x, np.float64) for x in (u, v, w))
    max_speed = float(np.nanmax(np.sqrt(uu ** 2 + vv ** 2 + ww ** 2)))
    P = ST.Pack()
    P.add("hc", S.hc)
    for k, attr in INPUT:
        P.add(k, np.nan_to_num(np.asarray(getattr(S, attr), np.float64)))
    P.add("fixed_u", ST.G(S.fixed_u)); P.add("fixed_v", ST.G(S.fixed_v))
    P.add("b_u", ST.G(S.b_u)); P.add("b_v", ST.G(S.b_v))
    if first_order:
        for k in STATE_NAMES:
            P.add("sol_" + k, np.nan_to_num(np.asarray(ST.G(getattr(S, k)), np.float64)))
    rev = ST.git_rev()
    extra = {k: pt[k] for k in ("U_ref",) if k in pt}      # Perdigao: ветер задан U100 на мачте, U10 фона - подгонка (>= 5 м/с не требуется)
    pt = dict(version=1, site=pt["site"], dx=dx, dz=g.dz, domain_m=pt["domain_m"], top_m=pt["top_m"], U10=pt["U10"], **extra,
              wdir_deg=pt["wdir_deg"], z0=pt["z0"], heat=False,
              source=dict(script="tools/research/picard_terrain/make_cases.py", args=[name], git=rev),
              terrain=terr, probes=pt["probes"])
    params = {k: getattr(S.prm, k) for k in S.prm.__dataclass_fields__}
    params["cut_cells"] = False
    meta = dict(
        format="ref-case", version=1, case=name, dims=[NX, NY, NZ], halo=1, dx=S.g.dx, dz=S.g.dz, z_bot=S.g.z_bot,
        x0=S.g.x0, y0=S.g.y0, nx=S.g.nx, ny=S.g.ny, nz=S.g.nz, params=params,
        case_params=dict(U10=case.U10, wdir=case.wdir, z_i=case.z_i, U_aloft=S.U_a, label=name),
        cd=S.cd, fixed_scale=S.fixed_scale, n_fluid=S.n_fluid, closure=S.closure_info,
        mg_levels_xyz=[list(L_["shape"])[::-1] for L_ in S.mg.levels],
        criterion=dict(tol_mom_rms=TOL["tol_mom"], tol_th_rms=TOL["tol_th"], tol_div_rms=TOL["tol_div"], check_every=CHECK_EVERY),
        source=dict(script="tools/research/picard_terrain/make_cases.py", git=rev, dtype=np.dtype(dt).name, solver="air3d",
                    adv2=bool(prm.adv2), limiter=int(prm.limiter)),
        pt=pt,
        notes=f"PT-1: {name}, air3d {np.dtype(dt).name}, {'1-й порядок, решение в sol_*' if first_order else 'эталон 2-й порядок (ван Лир), решения в .bin нет'}.")
    if first_order:
        meta["solution"] = dict(status=st, iters=int(S.outer), final_residuals=res, max_speed=max_speed)
        meta["history"] = [dict(it=h["it"], mom_rms=h["mom_rms"], th_rms=h["th_rms"], thd_rms=h["thd_rms"], div_rms=h["div_rms"])
                           for h in S.hist]
    base = D / "cases" / name
    P.write(base, meta)
    case_json = str(base) + ".json"
    ST.write_state(D / "states" / f"{name}_air3d", S, name, case_json, residuals=dict(res))
    run = dict(case=name, site=pt["site"], dx=dx, solver="air3d", dtype="f32" if dt == np.float32 else "f64", adv2=bool(prm.adv2),
               limiter=int(prm.limiter) if prm.adv2 else None, status={"ok": "ok", "max": "max", "diverged": "diverged"}[st],
               iters=int(S.outer), max_iters=MAX_OUTER, final=dict(mom_rms=res["mom_rms"], th_rms=res["th_rms"], div_rms=res["div_rms"]),
               t_solve_s=t_solve, wall_s=wall, ms_per_iter=t_solve / max(S.outer, 1) * 1e3, n=[NX, NY, NZ],
               state=f"states/{name}_air3d.json", git=rev)
    (OUT / "air3d_runs").mkdir(parents=True, exist_ok=True)
    (OUT / "air3d_runs" / f"{name}.json").write_text(json.dumps(run, indent=1, ensure_ascii=False))
    print(f"{name}: {st} iters {S.outer} t_solve {t_solve:.1f}s wall {wall:.1f}s dims {NX}x{NY}x{NZ} "
          f"mom {res['mom_rms']:.2e} div {res['div_rms']:.2e}", flush=True)
    del S
    cp.get_default_memory_pool().free_all_blocks()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*")
    a = ap.parse_args()
    for nm in (a.names or NAMES):
        make_one(nm)


if __name__ == "__main__":
    main()
