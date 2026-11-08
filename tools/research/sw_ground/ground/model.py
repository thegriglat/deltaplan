"""Расчёт панелей 3D (SWD2) в произвольном наборе точек с разложением на слагаемые.

Копия `compare/core.py: Run` и `panels3d/jh.py: velocity_jh` с новыми именами (оригиналы не менялись): `GRun` —
сетка/LU/σ под набор фокусных точек, настраиваемые z0 (правило), σ (smooth_m), σ фона (bg_smooth), вид фона;
`jh_parts` — velocity_jh (без extra) с выдачей промежуточных величин. Контроль: jh_parts().speed ≡ velocity_jh.
"""
from __future__ import annotations

import math
import os
import time

import h5py
import numpy as np

from . import common as K
import core as C  # noqa: E402  (SWD5: Run, bg_log, z0_of, load_terrain)
from panels3d import build_panels, assemble, solve, velocity, bg_profile  # noqa: E402
from panels3d import influence as _inf  # noqa: E402
from panels3d.jh import _column_scales, inner_depth, middle_top  # noqa: E402
from panels3d.terrain import bg_uniform, wind_of, u_ref_of  # noqa: E402

def _lu_inplace(self):
    """lu_factor с overwrite_a=True (в копии Influence.lu SWD2 — оригинал не менялся): матрица A после LU не нужна
    (решения и скорости идут через LU и panel_velocity), а общая GPU не вмещает вторую копию N×N."""
    if self._lu is None:
        if self.backend == "cupy":
            from cupyx.scipy.linalg import lu_factor
        else:
            from scipy.linalg import lu_factor
        self._lu = lu_factor(self.A, overwrite_a=True)
    return self._lu


_inf.Influence.lu = _lu_inplace

_orig_assemble = _inf.assemble


def _assemble_mt(panels, backend="auto"):
    """assemble (SWD2) на NumPy в нескольких потоках (блоки строк независимы, NumPy отпускает GIL); CuPy — оригинал."""
    xp, name = _inf.get_xp(backend)
    if name != "numpy":
        return _orig_assemble(panels, backend)
    from concurrent.futures import ThreadPoolExecutor
    t0 = time.time()
    N = panels.N
    g = _inf._geom(panels, xp)
    c = np.asarray(panels.c)
    A = np.empty((N, N))
    step = _inf._rows(xp, N, N)

    def work(i):
        sl = slice(i, min(N, i + step))
        V = _inf._influence(xp, c[sl], g, slice(None))
        A[sl] = (V * g["n"][sl][:, None, :]).sum(-1)
        idx = np.arange(sl.start, sl.stop)
        A[idx, idx] = 0.5
    with ThreadPoolExecutor(CPU_THREADS) as ex:
        list(ex.map(work, range(0, N, step)))
    return _inf.Influence(A, name, xp, time.time() - t0, N)


_inf.assemble = _assemble_mt

_inf._BLOCK = 600_000        # меньше временных массивов при сборке на общей GPU (оригинал 3 000 000)
CPU_THREADS = int(os.environ.get("SWG_CPU_THREADS", "6"))
GPU_RETRIES = 1
BG_SMOOTH_MAIN = 250.0       # σ сглаживания земли для z_agl фона в bg_log (умолчание SWD5, не меняется основным набором)


def z0_raster(case):
    with h5py.File(K.REFS / f"{case}.h5", "r") as h:
        t = h["terrain"]
        return t["x"][:], t["y"][:], t["z0"][:].astype(float)


def z0_rules(case):
    """{правило: скаляр} для JH и фона: медиана растра (SWD5), exp(mean ln z0) (= скаляр прогона Пикара)."""
    _, _, z = z0_raster(case)
    return {"median": float(np.median(z)), "lnmean": float(np.exp(np.mean(np.log(z))))}


def z0_local(case, x, y):
    """z0 растра в точке (ближайшая клетка 10 м)."""
    gx, gy, z = z0_raster(case)
    i = np.clip(np.rint((np.asarray(x) - gx[0]) / (gx[1] - gx[0])).astype(int), 0, gx.size - 1)
    j = np.clip(np.rint((np.asarray(y) - gy[0]) / (gy[1] - gy[0])).astype(int), 0, gy.size - 1)
    return z[j, i]


class GRun:
    """Одно решение панелей (case, ds_min, smooth_m, z0, bg_smooth, фон) для набора фокусных xy."""

    def __init__(self, case, focus_xy, ds_min=C.DS_MAIN, smooth_m=C.SMOOTH_MAIN, focus_r_mul=10.0, z0=None,
                 bg_smooth=BG_SMOOTH_MAIN, bg_kind="log", z0_rule="median"):
        self.case, self.ds_min, self.smooth_m = case, ds_min, smooth_m
        self.bg_smooth, self.bg_kind, self.focus_r_mul = bg_smooth, bg_kind, focus_r_mul
        t0 = time.time()
        self.terrain, self.wt = C.load_terrain(case, smooth_m)
        self.z0 = z0 if z0 is not None else z0_rules(case)[z0_rule]
        focus = sorted({(round(float(a), 2), round(float(b), 2)) for a, b in focus_xy})
        self.panels = build_panels(self.terrain, focus=focus, ds_min=ds_min, focus_r=focus_r_mul * ds_min)
        self.t_mesh = time.time() - t0
        if bg_kind == "power":
            self.bg = bg_profile(C.U10, C.ALPHA, C.Z_SAT, self.terrain, wind_to=tuple(self.wt), smooth_m=bg_smooth)
        else:
            self.bg = C.bg_log(C.U10, self.z0, C.Z_SAT, self.terrain, tuple(self.wt), smooth_m=bg_smooth)
        self.N = self.panels.N
        self.infl, self.sigma, self.info = self._assemble_solve()

    def _assemble_solve(self):
        """GPU (CuPy) делят с другими агентами: при нехватке памяти — до GPU_RETRIES попыток, затем CPU (NumPy, потоки)."""
        for attempt in range(GPU_RETRIES + 1):
            be = "auto" if attempt < GPU_RETRIES else "numpy"
            try:
                infl = assemble(self.panels, be)
                sigma, info = solve(self.panels, self.bg, None, infl)
                return infl, sigma, info
            except Exception as e:  # cupy OutOfMemoryError / CUDARuntimeError
                if be == "numpy" or not any(k in type(e).__name__ for k in ("OutOfMemory", "CUDA", "Cuda")):
                    raise
                self.infl = None
                self.free()
                time.sleep(2.0)

    def abs_points(self, x, y, zagl):
        x = np.asarray(x, float)
        y = np.asarray(y, float)
        return x, y, self.panels.height(x, y) + np.asarray(zagl, float)

    def free(self):
        self.infl = None
        try:
            import cupy as cp
            cp.get_default_memory_pool().free_all_blocks()
        except Exception:
            pass


def jh_parts(run, x, y, z, z0=None):
    """velocity_jh (контракт SWD2 v3, extra = None) с промежуточными величинами. z0 — скаляр или массив по точкам
    (по умолчанию run.z0). → dict: u, v, w, speed (итог), pot_speed, bg_speed, и диагностика JH:
    L, l, hm, t, A, dS, u0, uin, zagl, ok."""
    panels, sigma, bg, infl = run.panels, run.sigma, run.bg, run.infl
    z0 = run.z0 if z0 is None else z0
    terrain = panels.terrain
    ex, ey = wind_of(bg, terrain)
    U_ref, _ = u_ref_of(bg, terrain)
    x = np.asarray(x, float).ravel()
    y = np.asarray(y, float).ravel()
    z = np.asarray(z, float).ravel()
    be = infl.backend
    key = ("uniform", float(U_ref), round(ex, 12), round(ey, 12))
    if key not in infl._cache:
        infl._cache[key] = solve(panels, bg_uniform(U_ref, (ex, ey)), None, infl)[0]
    sig_u = infl._cache[key]
    bgu = bg_uniform(U_ref, (ex, ey))
    zg = panels.height(x, y)
    zagl = z - zg
    L = _column_scales(terrain, x, y, ex, ey, panels.ds_min)
    l = inner_depth(L, z0)
    hm = middle_top(L, z0)
    uv, vv, wv = _inf.velocity(panels, sigma, bg, x, y, z, None, be)
    ok = np.isfinite(uv)
    zz = np.where(ok, np.maximum(zagl, z0), z0)
    ze = np.maximum(zz, l)
    up, vp, _ = _inf.velocity(panels, sig_u, bgu, x, y, np.where(ok, zg + ze, zg + 1.0), None, be)
    sp = np.hypot(up, vp)
    dx_ = np.where(sp > 1e-9, up / np.maximum(sp, 1e-12), ex)
    dy_ = np.where(sp > 1e-9, vp / np.maximum(sp, 1e-12), ey)
    dS = sp / U_ref - 1.0
    lnh = np.log(np.maximum(hm, 1.01 * z0) / z0)
    A = np.where(ze < hm, (lnh / np.log(np.maximum(ze, 1.0001 * z0) / z0)) ** 2, 1.0)
    u0 = U_ref * np.log(zz / z0) / np.log(100.0 / z0)
    uin = u0 * (1.0 + A * dS)
    t = np.clip(np.log(zz / hm) / np.log(2.0), 0.0, 1.0)
    uh_out = np.hypot(uv, vv)
    spo = np.maximum(uh_out, 1e-12)
    ox = np.where(uh_out > 1e-9, uv / spo, dx_)
    oy = np.where(uh_out > 1e-9, vv / spo, dy_)
    U = (1 - t) * uin * dx_ + t * uh_out * ox
    V = (1 - t) * uin * dy_ + t * uh_out * oy
    U = np.where(ok, U, np.nan)
    V = np.where(ok, V, np.nan)
    W = np.where(ok, wv, np.nan)
    bgu_, bgv_, _ = bg(x, y, z)
    return dict(u=U, v=V, w=W, speed=np.hypot(U, V), pot_speed=np.where(ok, uh_out, np.nan),
                bg_speed=np.hypot(bgu_, bgv_), L=L, l=l, hm=hm, t=t, A=A, dS=dS, u0=u0, uin=uin, zagl=zagl, ok=ok,
                jh_in_speed=np.where(ok, uin, np.nan), U_ref=float(U_ref))


def stage_speeds(run, x, y, zagl, z0=None):
    """Скорости по стадиям в точках (x, y, z_agl над поверхностью панелей): bg, pot, jh (+ диагностика JH)."""
    x, y, z = run.abs_points(x, y, zagl)
    p = jh_parts(run, x, y, z, z0)
    return p


def norm_stages(run, refs, case):
    nm = refs["norm"][case]
    return stage_speeds(run, [nm["x"]], [nm["y"]], [nm["z_agl"]])
