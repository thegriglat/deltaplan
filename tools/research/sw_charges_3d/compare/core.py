"""SWD-5: расчёт панелей 3D (potential, potential_jh) в точках SWD1 для трёх случаев; кеш в out/compare/_cache.

Интерпретатор — tools/research/sw_charges_3d/py (без -I: PYTHONPATH). Не меняет panels3d/refs: только импорт.
"""
from __future__ import annotations

import json
import math
import sys
import time
from pathlib import Path

import h5py
import numpy as np

HERE = Path(__file__).resolve().parent
ROOT3D = HERE.parent
sys.path.insert(0, str(ROOT3D / "refs"))
import points as P  # noqa: E402  (SWD-1: определения; тянет cases/askervein, cases/perdigao)
from panels3d import (Terrain3D, bg_profile, build_panels, velocity, velocity_jh, assemble, solve,  # noqa: E402
                      separation3d)
import panels3d.sep as _sep  # noqa: E402

REFS = ROOT3D / "out" / "refs"
OUT = ROOT3D / "out" / "compare"
CACHE = OUT / "_cache"
CASES = ("ASK_TU03B", "PERD_NE", "PERD_SW")
ALPHA = 0.235          # показатель профиля фона = номинал перекалибровки Askervein/Perdigão (cases/askervein.NOM, perdigao.NOM)
Z_SAT = 500.0          # м, выше — постоянная скорость фона (допущение)
U10 = 5.0              # м/с: масштаб фона; s_norm и u∥/U_norm от него не зависят (поле линейно по фону)
SMOOTH_MAIN, DS_MAIN = 40.0, 25.0      # выбор a priori (см. README): σ как в 2D, ds_min — нижняя граница диапазона задачи
TOL = 0.15


def bg_log(U10_, z0, z_sat, terrain, wind_to, smooth_m=250.0):
    """Логарифмический фон U = U10·ln(z_agl/z0)/ln(10/z0) до z_sat (согласован с u0 внутреннего слоя JH); z_agl — над землёй,
    сглаженной σ = smooth_m; w = 0."""
    ex, ey = wind_to
    sm = terrain.smoothed(smooth_m) if smooth_m and smooth_m > 0 else terrain

    def bg(x, y, z):
        x = np.asarray(x, float)
        zagl = np.clip(np.asarray(z, float) - sm.height(x, np.asarray(y, float)), 0.1 + 3 * z0, z_sat)
        U = U10_ * np.log(zagl / z0) / math.log(10.0 / z0)
        return U * ex, U * ey, np.zeros_like(U)
    bg.wind_to = (ex, ey)
    bg.kind = "profile"
    return bg


def z0_of(case):
    """z0 для JH и отрыва: медиана растра z0 случая (out/refs/<case>.h5, terrain/z0) — velocity_jh принимает только скаляр.
    Askervein 0,03 м; Perdigão 1,80 м (лес — большинство клеток; среднее по ln z0 — z0_nominal() 0,645 м — было в первой версии)."""
    with h5py.File(REFS / f"{case}.h5", "r") as h:
        return float(np.median(h["terrain"]["z0"][:]))


def H_of(case):
    """Перепад рельефа для z/H: Askervein — HT над RS (cases/askervein), Perdigão — H Menke (cases/perdigao H_M)."""
    return float(P.AK._h_relief()) if case == "ASK_TU03B" else float(P.PD.H_M)


def load_terrain(case, smooth_m):
    with h5py.File(REFS / f"{case}.h5", "r") as h:
        t = h["terrain"]
        x, y, z = t["x"][:], t["y"][:], t["z"][:]
        wt = np.array(h.attrs["wind_to"], float)
    return Terrain3D(x, y, z.astype(float), smooth_m=smooth_m, far_m=10000.0), wt


def load_refs():
    return json.load(open(REFS / "points.json"))


def pkey(x, y, z):
    return (round(float(x), 2), round(float(y), 2), round(float(z), 2))


def eval_set(case, refs):
    """Уникальные точки (x, y, z_agl): строки SWD1, опорная, RS на уровнях строк (dS Askervein)."""
    S = {}
    nm = refs["norm"][case]
    S[pkey(nm["x"], nm["y"], nm["z_agl"])] = 1
    for r in refs["rows"]:
        if r["case"] != case:
            continue
        S[pkey(r["x"], r["y"], r["z_agl"])] = 1
        if case == "ASK_TU03B":
            S[pkey(*P.RS_ASK, r["z_agl"])] = 1
    return list(S)


class Run:
    """Одно решение панелей (case, ds_min, smooth_m): сетка, LU, поле в точках для potential и potential_jh."""

    def __init__(self, case, ds_min=DS_MAIN, smooth_m=SMOOTH_MAIN, focus_r_mul=10.0, refs=None, bg_kind="power"):
        self.case, self.ds_min, self.smooth_m = case, ds_min, smooth_m
        refs = refs or load_refs()
        self.refs = refs
        t0 = time.time()
        self.terrain, self.wt = load_terrain(case, smooth_m)
        self.keys = eval_set(case, refs)
        focus = sorted({(k[0], k[1]) for k in self.keys})
        self.panels = build_panels(self.terrain, focus=focus, ds_min=ds_min, focus_r=focus_r_mul * ds_min)
        self.t_mesh = time.time() - t0
        if bg_kind == "power":
            self.bg = bg_profile(U10, ALPHA, Z_SAT, self.terrain, wind_to=tuple(self.wt))
        else:
            self.bg = bg_log(U10, z0_of(case), Z_SAT, self.terrain, tuple(self.wt))
        self.infl = assemble(self.panels, "auto")
        self.sigma, self.info = solve(self.panels, self.bg, None, self.infl)
        self.z0 = z0_of(case)
        self.N = self.panels.N

    def points(self, keys=None):
        keys = keys or self.keys
        a = np.array(keys, float)
        z = self.panels.height(a[:, 0], a[:, 1]) + a[:, 2]
        return a[:, 0], a[:, 1], z

    def query(self, x, y, z, variant):
        if variant == "potential":
            return velocity(self.panels, self.sigma, self.bg, x, y, z)
        return velocity_jh(self.panels, self.sigma, self.bg, x, y, z, self.z0, infl=self.infl)

    def field(self, variant):
        """{pkey: (u, v, w)} в точках eval_set; время запроса на точку (мкс)."""
        x, y, z = self.points()
        t0 = time.time()
        u, v, w = self.query(x, y, z, variant)
        dt = time.time() - t0
        return {k: (float(a), float(b), float(c)) for k, a, b, c in zip(self.keys, u, v, w)}, 1e6 * dt / len(self.keys)

    def free(self):
        self.infl = None
        try:
            import cupy as cp
            cp.get_default_memory_pool().free_all_blocks()
        except Exception:
            pass


def hspeed(f, k):
    u, v, _ = f[k]
    return math.hypot(u, v)


def rotor_scan(run, variant, tr, u_scale):
    """Критерий SWD5: u∥ < −0,5 м/с на z_agl 15 м (шаг 10 м), самый длинный участок > 50 м; глубина — max z_agl (шаг 15 м)
    области, связной с этим участком. u∥ масштабирована к U данных в опорной точке (u_scale = U_data/|V_pan(norm)|)."""
    ex, ey = run.wt
    L = math.hypot(tr["x1"] - tr["x0"], tr["y1"] - tr["y0"])
    n = int(L // 10) + 1
    s = np.linspace(0, L, n)
    X = tr["x0"] + (tr["x1"] - tr["x0"]) * s / L
    Y = tr["y0"] + (tr["y1"] - tr["y0"]) * s / L
    zs = np.arange(15.0, 601.0, 15.0)
    XX, YY = np.tile(X, len(zs)), np.tile(Y, len(zs))
    ZZ = run.panels.height(XX, YY) + np.repeat(zs, n)
    u, v, _ = run.query(XX, YY, ZZ, variant)
    upar = ((u * ex + v * ey) * u_scale).reshape(len(zs), n)
    bad = np.isfinite(upar) & (upar < -0.5)
    row0 = bad[0]
    best, bi, i = 0.0, None, 0
    while i < n:
        if row0[i]:
            j = i
            while j + 1 < n and row0[j + 1]:
                j += 1
            ln = (j - i + 1) * 10.0
            if ln > 50.0 and ln > best:
                best, bi = ln, (i, j)
            i = j + 1
        else:
            i += 1
    if bi is None:
        return False, 0.0, 0.0
    cols = np.zeros(n, bool)
    cols[bi[0]:bi[1] + 1] = True
    depth = 15.0
    for k in range(1, len(zs)):
        if not (bad[k] & cols).any():
            break
        depth = zs[k]
    return True, best, float(depth)


def separation_diag(run):
    """Диагностика отрыва по линиям тока (2D №2, №8): число отрывов, отброшенных lee_only (с координатами), H(s) и cf(s) вдоль
    средней линии тока (затравка через центр растра), max H и min cf по всем линиям."""
    calls = []
    orig = _sep.march_layer
    orig_trace = _sep._trace
    stash = {}

    def spy(s, ue, du, z0, uref, sep_ok=None):
        r = orig(s, ue, du, z0, uref, sep_ok)
        c = dict(s=np.array(s), H=r["H"].copy(), cf=r["cf"].copy(), i_sep=r["i_sep"], ue0=float(ue[0]), n=len(s))
        if calls and calls[-1]["n"] == c["n"] and calls[-1]["ue0"] == c["ue0"] and calls[-1]["s"][-1] == c["s"][-1]:
            calls[-1] = c         # повторный расчёт той же линии после отбраковки lee_only
        else:
            calls.append(c)
        return r

    def trace_spy(*a, **k):
        recs = orig_trace(*a, **k)
        stash["recs"] = recs
        return recs
    _sep.march_layer = spy
    _sep._trace = trace_spy
    try:
        res = separation3d(run.panels, run.sigma, run.bg, run.z0, lee_only=True)
    finally:
        _sep.march_layer = orig
        _sep._trace = orig_trace
    recs = [r for r in stash["recs"] if r.shape[0] >= 4]
    T = run.terrain
    ex, ey = run.wt if hasattr(run, "wt") else (1.0, 0.0)
    px, py = -ey, ex
    q = [(r[0, 0] - T.cx) * px + (r[0, 1] - T.cy) * py for r in recs]
    kc = int(np.argmin(np.abs(q))) if recs and len(recs) == len(calls) else None
    central = None
    if kc is not None:
        c = calls[kc]
        r = recs[kc]
        n = c["s"].size
        idx = np.unique(np.linspace(0, n - 1, 14).astype(int))
        sx = np.interp(c["s"][idx], r[:, 3], r[:, 0])
        sy = np.interp(c["s"][idx], r[:, 3], r[:, 1])
        sz = np.interp(c["s"][idx], r[:, 3], r[:, 2])
        central = dict(q=float(q[kc]), s=c["s"][idx], H=c["H"][idx], cf=c["cf"][idx], x=sx, y=sy, z=sz, i_sep=int(c["i_sep"]),
                       s_total=float(c["s"][-1]))
    Hs = [float(np.nanmax(c["H"])) for c in calls if np.isfinite(c["H"]).any()]
    cs = [float(np.nanmin(c["cf"])) for c in calls if np.isfinite(c["cf"]).any()]
    pts, rej = res["points"], res["rejected"]
    return dict(n_lines=len(Hs), n_sep=int(len(pts["x"])), n_rej=int(len(rej["x"])),
                H_max=max(Hs) if Hs else None, cf_min=min(cs) if cs else None,
                H_sep=[float(v) for v in pts["value"]], rej=rej, sep=pts, central=central)
