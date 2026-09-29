"""Сетки Онгудая и запуск решателя (общая часть study.py / report.py)."""
from __future__ import annotations

import json
import math
import os
import time
from pathlib import Path

import numpy as np

import terrain as T
import solver as S

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
FIELDS = HERE / "fields"          # большие поля — вне git (см. .gitignore)
OUT.mkdir(exist_ok=True)
FIELDS.mkdir(exist_ok=True)

_TER = {}


def ter():
    if not _TER:
        h, info, meta, water = T.load_detail()
        _TER.update(h=h, info=info, meta=meta, water=water.astype(float), sites=T.sites(meta))
    return _TER


# Параметры решателя по умолчанию (итог подбора: couple = 1 — полностью полунеявная плавучесть,
# Δτ_u = 600 с — быстрее сходится штиль; выход — «жёсткие» границы с губками, см. summary.md
# см. summary.md → «Что не сошлось сразу»)
PRM = dict(couple=1.0, dtau_u=600.0)

DOMAIN_L = 38400.0       # сторона области, м (слой detail — 40 км; 38,4 = 96·400 = 192·200)
NZ_DOMAIN = 48
DZ_DOMAIN = 105.0
ZBOT_DOMAIN = 400.0      # мин. рельеф 508 м; нижний слой — земля


def grid_domain(dx):
    n = int(round(DOMAIN_L / dx))
    return T.Grid(dx, n, n, DZ_DOMAIN, ZBOT_DOMAIN, NZ_DOMAIN)


def grid_window(dx, n=64, dz=None, top_above=2000.0, center=None):
    t = ter()
    s = t["sites"]["start"]
    cx, cy = center if center is not None else (s["x"], s["y"])
    # центр — по узлам 25-м сетки, чтобы блоки ложились целыми
    cx = round((cx - 0.5 * n * dx) / 25.0) * 25.0 + 0.5 * n * dx
    cy = round((cy - 0.5 * n * dx) / 25.0) * 25.0 + 0.5 * n * dx
    dz = dz if dz is not None else dx / 2
    x0, y0 = cx - n * dx / 2, cy - n * dx / 2
    hc = T.block_mean(t["h"], t["info"], x0, y0, dx, n, n)
    zb = math.floor(hc.min() / dz) * dz - dz
    nz = int(math.ceil((hc.max() + top_above - zb) / dz))
    nz += nz % 2
    return T.Grid(dx, n, n, dz, zb, nz, cx, cy)


def heights(g):
    t = ter()
    return T.block_mean(t["h"], t["info"], g.x0, g.y0, g.dx, g.nx, g.ny)


def water(g):
    t = ter()
    f = int(round(g.dx / 25.0))
    info = t["info"]
    i0 = int(round((g.x0 - info["x0"]) / 25.0))
    j0 = int(round((g.y0 - info["y0"]) / 25.0))
    w = t["water"][j0:j0 + f * g.ny, i0:i0 + f * g.nx]
    return w.reshape(g.ny, f, g.nx, f).mean(axis=(1, 3))


def make(g, cond, parent=None, prm=None):
    p = dict(PRM)
    if prm:
        p.update(prm)
    return S.Air3D(g, heights(g), cond, S.Params(**p), water=water(g),
                   nest=None if parent is None else dict(parent=parent))


def sync():
    import cupy as cp
    cp.cuda.Device().synchronize()


def state(A):
    """Копия состояния на устройстве (для тёплого старта)."""
    return {k: getattr(A, k).copy() for k in ("u", "v", "w", "th", "p")}


def run(A, warm=None, tol=None, max_outer=1500, check_every=10, verbose=False, with_p=True):
    """Решить (холодный старт или тёплый от warm — состояние state()) — возвращает dict с числами."""
    sync()
    t0 = time.perf_counter()
    if warm is not None:
        A.init_from(warm, with_p=with_p)
    elif A.nest is not None:
        A.init_nest()
    else:
        A.init_background()
    sync()
    t_init = time.perf_counter() - t0
    tol = tol or TOL
    st = A.solve(max_outer=max_outer, check_every=check_every, verbose=verbose, **tol)
    return dict(status=st, iters=A.outer, t_solve=A.wall - A.t_check, t_check=A.t_check, t_init=t_init,
                mem_mb=A.mem_mb(), hist=A.hist, last=A.hist[-1] if A.hist else None)


# Критерий остановки (СКО невязки по неизвестным): подобран по опыту «ошибка против
# итераций» (study.py conv) — при нём ошибка u, w против досчитанного решения ≈ 1 % (отн. L2) с
# ветром; в штиль w ≪ 1 %, слабая горизонталь (< 1 м/с) — до ~2 см/с (она сходится медленнее всего).
TOL = dict(tol_mom=2e-5, tol_th=5e-7, tol_div=1e-6, rms=True)


def agl_slice(A, F, agl):
    """Значение поля F (nz, ny, nx, NaN в земле) на высоте agl над рельефом hc (линейно по z;
    ниже центра первой воздушной клетки — её значение)."""
    g = A.g
    hc = A.hc
    z = g.z_bot + (np.arange(g.nz) + 0.5) * g.dz
    zt = hc + agl
    kf = (zt - z[0]) / g.dz
    out = np.full(hc.shape, np.nan)
    kb = A.kb - 1           # индекс первой воздушной клетки без ореола
    kf = np.maximum(kf, kb)
    k0 = np.clip(np.floor(kf).astype(int), 0, g.nz - 2)
    a = np.clip(kf - k0, 0, 1)
    jj, ii = np.indices(hc.shape)
    f0 = F[k0, jj, ii]
    f1 = F[k0 + 1, jj, ii]
    f1 = np.where(np.isnan(f1), f0, f1)
    out = (1 - a) * f0 + a * f1
    return out


def bilinear2d(A, M, x, y):
    g = A.g
    fi = (x - g.x0) / g.dx - 0.5
    fj = (y - g.y0) / g.dx - 0.5
    i0 = int(np.clip(np.floor(fi), 0, g.nx - 2))
    j0 = int(np.clip(np.floor(fj), 0, g.ny - 2))
    a, b = fi - i0, fj - j0
    return float((1 - b) * ((1 - a) * M[j0, i0] + a * M[j0, i0 + 1]) + b * ((1 - a) * M[j0 + 1, i0] + a * M[j0 + 1, i0 + 1]))


def probes():
    """Точки для ключевых чисел (м, мир игры: x — восток, y — север)."""
    t = ter()
    s = t["sites"]["start"]
    return dict(
        start=(s["x"], s["y"]),
        # седловина хребта к северу от старта (≈ 1865 м по 100-м рельефу; поиск в README)
        saddle=(s["x"] + 300.0, s["y"] + 800.0),
    )


def key_numbers(A, fields=None):
    """Ключевые числа поля: подъём над солнечными склонами, разгон у старта, ветер в седловине."""
    u, v, w, th = fields if fields is not None else A.centers()
    sp = np.sqrt(u ** 2 + v ** 2)
    w50, w200 = agl_slice(A, w, 50.0), agl_slice(A, w, 200.0)
    s50 = agl_slice(A, sp, 50.0)
    th50 = agl_slice(A, th, 50.0)
    P = probes()
    g = A.g
    X, Y = np.meshgrid(g.x, g.y)
    sx, sy = P["start"]
    near = (X - sx) ** 2 + (Y - sy) ** 2 < 1500.0 ** 2
    U = max(A.cond.wind, 1e-9)
    out = dict(
        w200_p99=float(np.nanpercentile(w200, 99)),
        w200_p01=float(np.nanpercentile(w200, 1)),
        w200_max=float(np.nanmax(w200)),
        w_max=float(np.nanmax(w)), w_min=float(np.nanmin(w)),
        th_max=float(np.nanmax(th)),
        start_w200_max=float(np.nanmax(np.where(near, w200, np.nan))),
        start_w50=bilinear2d(A, w50, sx, sy),
        start_speed50=bilinear2d(A, s50, sx, sy),
        start_th50=bilinear2d(A, th50, sx, sy),
        saddle_speed50=bilinear2d(A, s50, *P["saddle"]),
        saddle_w50=bilinear2d(A, w50, *P["saddle"]),
        speed_max=float(np.nanmax(sp)),
    )
    if A.cond.wind > 0:
        out["start_speedup50"] = out["start_speed50"] / U
        out["saddle_speedup50"] = out["saddle_speed50"] / U
    return out


def save_fields(A, path, fp16=True):
    u, v, w, th = A.centers()
    dt = np.float16 if fp16 else np.float32
    np.savez_compressed(path, u=np.nan_to_num(u).astype(dt), v=np.nan_to_num(v).astype(dt),
                        w=np.nan_to_num(w).astype(dt), th=np.nan_to_num(th).astype(dt), hc=A.hc.astype(np.float32),
                        meta=json.dumps(dict(dx=A.g.dx, dz=A.g.dz, x0=A.g.x0, y0=A.g.y0, z_bot=A.g.z_bot,
                                             nx=A.g.nx, ny=A.g.ny, nz=A.g.nz, cond=A.cond.__dict__)))


def jdump(obj, path):
    def conv(o):
        if isinstance(o, (np.floating, np.integer)):
            return o.item()
        if isinstance(o, np.ndarray):
            return o.tolist()
        raise TypeError(type(o))
    Path(path).write_text(json.dumps(obj, ensure_ascii=False, indent=1, default=conv))
