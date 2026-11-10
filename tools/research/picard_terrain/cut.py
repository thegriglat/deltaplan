"""PT-2: случаи со срезанными клетками PT2 (<site>_d<dx>_cut) из случаев PT1 (<site>_d<dx>) и растра подсетки.

  PY=tools/research/sw_charges_3d/py
  .dpcli/dpcli lock gpu PT-2 -- $PY tools/research/picard_terrain/cut.py                    # 4 случая сеток игры
  $PY tools/research/picard_terrain/cut.py askervein_d50 [--vf-min 0.1] [--samples 17]

Доли (PT2 v1, раскладка R1 с ореолом):
  * рельеф подсетки — растр PT1 D/terrain/<site>.h5 (билинейно, sample.Raster); точки — общая мелкая решётка с шагом
    dx/(N-1) (N = samples_per_edge точек на ребро клетки, концы включены): у соседних клеток общая грань — одни и те же точки;
  * vf — среднее (веса трапеций по x и y) открытой доли высоты клетки clip((z_верх - h)/dz, 0, 1) по N x N точкам клетки;
  * af_w — доля точек грани (плоскость z = низ клетки) не ниже рельефа [h <= z]; af_u, af_v — среднее открытой доли высоты
    clip((z_верх - h)/dz, 0, 1) по N точкам ребра грани. Клетка с vf = 1 даёт 1 на всех своих гранях (те же точки);
  * ореол — копия соседней внутренней клетки/грани по нормали к границе (по z доли считаются по геометрии на всех слоях).
Типы — по vf_min: клетка воздуха <=> vf >= vf_min; в столбце vf не убывает по k, поэтому типы задаёт высота
hc_type = низ первой клетки с vf >= vf_min, и вход, зависящий от типов (cell, tu, tv, tw, Kx, Ky, Kz, b_u, b_v,
fixed_u, fixed_v), даёт подготовка air3d (air.Air с hc_type; модуль не меняется). Фон ветра ubg, vbg — профиль air3d
от настоящего рельефа случая (hc PT1), умноженный на новые типы; fixed_* — Air._setup_boundary от него (баланс по
полным площадям; баланс по открытым площадям делает решатель). Остальной вход (hc, nu_bg, Q, gam, cplz, губки, lam)
— из случая PT1 без изменений. Грань типа 1 с нулевой долей (гребень по линии грани между двумя открытыми клетками)
получает долю AF_FLOOR (счёт — в отчёте и в pt.cut.n_face_floor). Клетка воздуха с vf >= 1 - 1e-6 (выступ рельефа
в одну точку решётки) — полная: vf и все её грани 1 (pt.cut.n_snap_full).
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
from dataclasses import fields
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
for p in (ROOT / "tools/research/air3d", HERE):
    sys.path.insert(0, str(p))
import air as A  # noqa: E402
import air3d_state as ST  # noqa: E402
import sample as SM  # noqa: E402

D = Path(os.environ.get("PICARD_TERRAIN_DATA", "~/data/picard_terrain")).expanduser()
NAMES = ["askervein_d50", "askervein_d100", "kayancha_d50", "kayancha_d100"]
VF_MIN = 0.05
SAMPLES = 17
AF_FLOOR = 1e-3
TYPE_KEYS = ("cell", "tu", "tv", "tw", "Kx", "Ky", "Kz", "ubg", "vbg", "fixed_u", "fixed_v", "b_u", "b_v")


def read_case(json_path):
    meta = json.loads(Path(json_path).read_text())
    mm = np.memmap(Path(json_path).with_suffix(".bin"), dtype="<f4", mode="r")
    arr = {k: np.asarray(mm[o:o + n], np.float64) for k, (o, n) in meta["arrays"].items()}
    return meta, arr


def fractions(meta, raster, n):
    """-> vf, af_u, af_v, af_w (NZ, NY, NX) с ореолом."""
    NX, NY, NZ = meta["dims"]
    nx, ny = meta["nx"], meta["ny"]
    dx, dz, zb = meta["dx"], meta["dz"], meta["z_bot"]
    m = n - 1
    xs = meta["x0"] + np.arange(nx * m + 1) * (dx / m)
    ys = meta["y0"] + np.arange(ny * m + 1) * (dx / m)
    X, Y = np.meshgrid(xs, ys)
    H = raster(X, Y)                                   # (ny*m+1, nx*m+1)
    wt = np.ones(n)
    wt[0] = wt[-1] = 0.5
    wt /= wt.sum()

    def block_x(F):          # (..., nx*m+1) -> (..., nx): трапеции по ребру клетки
        return sum(wt[a] * F[..., a:a + nx * m:m] for a in range(n))

    def block_y(F):          # (ny*m+1, ...) -> (ny, ...)
        return sum(wt[b] * F[b:b + ny * m:m] for b in range(n))

    vf = np.zeros((NZ, NY, NX))
    au = np.zeros((NZ, NY, NX))
    av = np.zeros((NZ, NY, NX))
    aw = np.zeros((NZ, NY, NX))
    for k in range(NZ):
        zlo = zb + (k - 1) * dz
        O = np.clip((zlo + dz - H) / dz, 0.0, 1.0)
        vf[k, 1:-1, 1:-1] = block_y(block_x(O))
        aw[k, 1:-1, 1:-1] = block_y(block_x((H <= zlo).astype(float)))
        au[k, 1:-1, 1:] = block_y(O[:, ::m])               # грани x = x0 + i*dx, i = 0..nx -> индекс i + 1
        av[k, 1:, 1:-1] = block_x(O[::m, :])
    for a in (vf, aw):                                      # ореол по x, y: копия соседней по нормали
        a[:, 0, :] = a[:, 1, :]; a[:, -1, :] = a[:, -2, :]
        a[:, :, 0] = a[:, :, 1]; a[:, :, -1] = a[:, :, -2]
    au[:, :, 0] = au[:, :, 1]
    au[:, 0, :] = au[:, 1, :]; au[:, -1, :] = au[:, -2, :]
    av[:, 0, :] = av[:, 1, :]
    av[:, :, 0] = av[:, :, 1]; av[:, :, -1] = av[:, :, -2]
    return vf, au, av, aw


def type_height(meta, vf, vf_min):
    """hc_type (ny, nx): низ первой клетки столбца (k >= 1) с vf >= vf_min — air.Air даёт cell = 1 ровно там."""
    zb, dz = meta["z_bot"], meta["dz"]
    open_ = vf[1:-1, 1:-1, 1:-1] >= vf_min                  # (nz, ny, nx), k = 1..nz
    if not open_.any(axis=0).all():
        raise ValueError("column without an open cell")
    kb = np.argmax(open_, axis=0) + 1
    if not np.all(np.take_along_axis(open_, (kb - 1)[None], 0)) or np.any(np.diff(open_.astype(int), axis=0) < 0):
        raise ValueError("vf not monotone in a column")
    return zb + (kb - 1) * dz


def air_from_meta(meta, hc_type):
    """air.Air по постановке случая PT1 (сетка, Params, Case из JSON) на высотах типов."""
    p = meta["params"]
    names = {f.name for f in fields(A.Params)}
    prm = A.Params(**{k: v for k, v in p.items() if k in names})
    g = A.Grid(meta["dx"], meta["nx"], meta["ny"], meta["dz"], meta["z_bot"], meta["nz"], meta["x0"], meta["y0"])
    cp_ = meta["case_params"]
    NZ = meta["dims"][2]
    return g, prm, cp_, NZ


def build(name, vf_min=VF_MIN, n=SAMPLES):
    base_json = D / "cases" / f"{name}.json"
    meta, arr = read_case(base_json)
    NX, NY, NZ = meta["dims"]
    shape = (NZ, NY, NX)
    pt = meta["pt"]
    raster = SM.Raster(D / pt["terrain"]["path"], pt["terrain"]["dataset"])
    vf, au, av, aw = fractions(meta, raster, n)
    hc = arr["hc"].reshape(meta["ny"], meta["nx"])
    hct = type_height(meta, vf, vf_min)
    g, prm, cpar, _ = air_from_meta(meta, hct)
    gam = arr["gam"]
    zc = meta["z_bot"] + (np.arange(NZ) - 0.5) * meta["dz"]
    case = A.Case(U10=cpar["U10"], wdir=cpar["wdir"], z_i=cpar["z_i"], gam=lambda z: np.interp(z, zc, gam),
                  label=name + "_cut")
    S = A.Air(g, hct, case, prm, dtype=np.float64)
    # фон ветра — от настоящего рельефа (как у случая PT1), на новых типах
    hp = np.pad(hc, 1, mode="edge")
    hu = np.zeros((NY, NX)); hu[:, 1:] = 0.5 * (hp[:, 1:] + hp[:, :-1]); hu[:, 0] = hp[:, 0]
    hv = np.zeros((NY, NX)); hv[1:, :] = 0.5 * (hp[1:, :] + hp[:-1, :]); hv[0, :] = hp[0, :]
    S.ubg_np = S.U_a * S.ex * A.wind_profile(zc[:, None, None] - hu[None], S.prm) * (S.tu_np != 0)
    S.vbg_np = S.U_a * S.ey * A.wind_profile(zc[:, None, None] - hv[None], S.prm) * (S.tv_np != 0)
    S._setup_boundary()
    # проверка: старые ubg совпадают с новыми там, где типы граней не изменились (тот же профиль)
    same = (arr["tu"].reshape(shape) == S.tu_np) & (S.tu_np != 0)
    dub = float(np.max(np.abs(arr["ubg"].reshape(shape)[same] - S.ubg_np[same]))) if same.any() else 0.0
    if dub > 1e-4:
        raise ValueError(f"background profile differs from the PT1 case: {dub}")
    # почти полная клетка воздуха (vf >= 1 - 1e-6: выступ рельефа в одну точку решётки) — полная, все её грани 1 (PT2)
    full = (S.cell_np == 1) & (vf >= 1 - 1e-6)
    n_snap = int((full & (vf < 1)).sum())
    vf[full] = 1.0
    au[full] = 1.0; au[:, :, 1:][full[:, :, :-1]] = 1.0
    av[full] = 1.0; av[:, 1:, :][full[:, :-1, :]] = 1.0
    aw[full] = 1.0; aw[1:][full[:-1]] = 1.0
    # грань типа 1 с нулевой долей
    n_floor = 0
    for a, t in ((au, S.tu_np), (av, S.tv_np), (aw, S.tw_np)):
        bad = (t == 1) & (a <= 0)
        n_floor += int(bad.sum())
        a[bad] = AF_FLOOR
    new = dict(cell=S.cell_np, tu=S.tu_np, tv=S.tv_np, tw=S.tw_np, Kx=S.Kx_np, Ky=S.Ky_np, Kz=S.Kz_np, ubg=S.ubg_np,
               vbg=S.vbg_np, fixed_u=ST.G(S.fixed_u), fixed_v=ST.G(S.fixed_v), b_u=ST.G(S.b_u), b_v=ST.G(S.b_v))
    for k in ("sp_u", "sp_w", "spc", "cplz"):
        ref = {"sp_u": S.sp_np, "sp_w": S.spw_np, "spc": S.spc_np, "cplz": S.cplz_np}[k]
        if np.max(np.abs(arr[k] - np.ravel(ref))) > 1e-6:
            raise ValueError(f"{k} differs from the PT1 case")
    P = ST.Pack()
    for k in meta["arrays"]:
        if k.startswith("sol_"):
            continue
        P.add(k, new[k] if k in new else arr[k])
    for k, a in (("vf", vf), ("af_u", au), ("af_v", av), ("af_w", aw)):
        P.add(k, a)
    cname = f"{name}_cut"
    m2 = {k: v for k, v in meta.items() if k not in ("arrays", "solution", "history")}
    m2["case"] = cname
    m2["params"] = dict(meta["params"], cut_cells=True)
    m2["n_fluid"] = float((S.cell_np == 1).sum())
    m2["fixed_scale"] = S.fixed_scale
    m2["mg_levels_xyz"] = [list(L_["shape"])[::-1] for L_ in S.mg.levels]
    rev = ST.git_rev()
    pt2 = dict(pt)
    pt2["source"] = dict(script="tools/research/picard_terrain/cut.py", args=[name, f"--vf-min={vf_min}", f"--samples={n}"],
                         git=rev, base=f"cases/{name}.json")
    fl = S.cell_np[1:-1, 1:-1, 1:-1] == 1
    cutc = fl & (vf[1:-1, 1:-1, 1:-1] < 1 - 1e-6)
    pt2["cut"] = dict(version=1, vf_min=vf_min, samples_per_edge=n, terrain_dx=30, af_floor=AF_FLOOR,
                      n_face_floor=n_floor, n_snap_full=n_snap, n_cut_cells=int(cutc.sum()),
                      n_air_base=float(meta.get("n_fluid", float("nan"))), n_air=m2["n_fluid"],
                      open_volume_air=float(vf[1:-1, 1:-1, 1:-1][fl].sum()))
    m2["pt"] = pt2
    m2["source"] = dict(meta.get("source", {}), script="tools/research/picard_terrain/cut.py", git=rev)
    m2["notes"] = (f"PT-2: {cname} — случай {name} (PT1) со срезанными клетками PT2: доли vf, af_* по растру "
                   f"{pt['terrain']['path']} ({n} точек на ребро), типы по vf_min = {vf_min}; решения в .bin нет.")
    P.write(D / "cases" / cname, m2)
    dh = hct - hc
    print(f"{cname}: {NX}x{NY}x{NZ} air {int(m2['n_fluid'])} (base {int(meta['n_fluid'])}), cut cells {int(cutc.sum())}, "
          f"faces at floor {n_floor}, snapped full {n_snap}, h_type - hc: mean {dh.mean():+.1f} [{dh.min():+.1f}, {dh.max():+.1f}] m, "
          f"fixed_scale {S.fixed_scale:.4f}", flush=True)
    del S
    import cupy as cp
    cp.get_default_memory_pool().free_all_blocks()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*")
    ap.add_argument("--vf-min", type=float, default=VF_MIN)
    ap.add_argument("--samples", type=int, default=SAMPLES)
    a = ap.parse_args()
    for nm in (a.names or NAMES):
        build(nm, a.vf_min, a.samples)


if __name__ == "__main__":
    main()
