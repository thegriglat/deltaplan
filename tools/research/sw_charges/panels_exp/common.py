"""SWC-12: общие функции опытов panels2d на разрезах (SW7). Интерпретатор — venv cascade_2d (numpy, scipy)."""
import json
import os
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SWC = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(SWC, "..", "..", ".."))
sys.path.insert(0, SWC)
sys.path.insert(0, os.path.join(REPO, "tools", "research", "cascade_2d", "contract"))
from panels2d import (Terrain, build_panels, bg_profile, solve, velocity, step, Vortices)  # noqa: E402

OUT = os.path.join(SWC, "out", "panels2d")
CASES_DIR = os.path.join(OUT, "cases")
C2D = os.path.expanduser(os.environ.get("CASCADE2D_DATA", "~/data/cascade_2d"))
SLOPE_SEP = 0.27          # порог отрыва (Finnigan 1988, slope-flow.md §2.4)
ROTOR_U, ROTOR_Z, ROTOR_LMIN = -0.5, 15.0, 50.0    # как у Menke 2019 (перегрузка 0,5 м/с, слепая зона 15 м, > 50 м)
TOL = 0.15


def git_rev():
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip()
    except Exception:
        return "unknown"


# ---------------------------------------------------------------- Пикар F1
class Picard:
    def __init__(self, case, dx=50):
        import cascade2d_io as IO
        meta, a = IO.read_f1(os.path.join(C2D, "fields", case, f"picard_none_d{dx}.json"))
        self.meta, self.dx, self.dz = meta, float(meta["dx"]), float(meta["dz"])
        nx, nz = meta["nx"], meta["nz"]
        self.xc = meta["x0"] + (np.arange(nx) + 0.5) * self.dx
        self.zc = meta["z0"] + (np.arange(nz) + 0.5) * self.dz
        self.uc = 0.5 * (a["u"][:, :-1] + a["u"][:, 1:]).astype(float)
        self.wc = 0.5 * (a["w"][:-1] + a["w"][1:]).astype(float)
        self.air = a["cell"] > 0.5
        self.h = a["h"].astype(float)
        cj = json.load(open(os.path.join(C2D, "cases", f"{case}_d{dx}.json")))
        self.cp = cj["case_params"]
        self.alpha = float(cj["params"]["alpha"]) if isinstance(cj["params"], dict) else 0.112
        mp = float(cj["params"]["max_profile"]) if isinstance(cj["params"], dict) else None
        self.max_profile = mp
        self.cj_params = cj["params"]

    def ground(self, x):
        return np.interp(x, self.xc, self.h)

    def sample(self, x, zagl):
        """(u, w) в точках (x, z_agl): билинейно по воздушным клеткам; ниже/вблизи стенки — степенной закон
        (alpha) от эффективной высоты клеток над землёй."""
        x = np.atleast_1d(np.asarray(x, float))
        zagl = np.broadcast_to(np.asarray(zagl, float), x.shape)
        U, W = np.full(x.shape, np.nan), np.full(x.shape, np.nan)
        for n_, (xx, za) in enumerate(zip(x, zagl)):
            zabs = self.ground(xx) + za
            fi = (xx - self.xc[0]) / self.dx
            fk = (zabs - self.zc[0]) / self.dz
            i0, k0 = int(np.floor(fi)), int(np.floor(fk))
            sw = su = sww = sz = 0.0
            for di in (0, 1):
                for dk in (0, 1):
                    i, k = i0 + di, k0 + dk
                    if not (0 <= i < len(self.xc) and 0 <= k < len(self.zc)) or not self.air[k, i]:
                        continue
                    wgt = (1 - abs(fi - i)) * (1 - abs(fk - k))
                    if wgt <= 0:
                        continue
                    agl = self.zc[k] - self.h[i]
                    sw += wgt
                    su += wgt * self.uc[k, i]
                    sww += wgt * self.wc[k, i]
                    sz += wgt * agl
            if sw > 0:
                zeff = sz / sw
                f = (za / zeff) ** self.alpha if (zeff > 0 and za < zeff) else 1.0
                U[n_], W[n_] = f * su / sw, f * sww / sw
        return U, W


# ---------------------------------------------------------------- гребни, отрыв, ротор
def find_crests(x, z, prom_min=60.0, win=100.0):
    """Локальные максимумы линии с заметностью ≥ prom_min (м)."""
    dx = x[1] - x[0]
    w = max(1, int(win / dx))
    out = []
    for i in range(w, len(x) - w):
        if z[i] < z[i - w:i + w + 1].max() or z[i] <= z[i - 1]:
            continue
        j = i
        while j > 0 and z[j - 1] <= z[i]:
            j -= 1
        lm = z[j:i + 1].min()
        k = i
        while k < len(x) - 1 and z[k + 1] <= z[i]:
            k += 1
        rm = z[i:k + 1].min()
        if z[i] - max(lm, rm) >= prom_min:
            out.append(i)
    # слить близкие (плато)
    res = []
    for i in out:
        if not res or x[i] - x[res[-1]] > 3 * win:
            res.append(i)
    return res


def shed_points(panels, ds_min, crests_x, x_end):
    """За каждым гребнем — первая точка вниз по потоку, где подветренный уклон ≥ SLOPE_SEP; точка рождения
    на ds_min/2 над землёй. Возвращает список {x_s, z_s, rule}."""
    xs = np.arange(min(crests_x) - 500, x_end, 5.0)
    g = panels.ground(xs)
    sl = -(np.roll(g, -4) - np.roll(g, 4)) / (xs[1] * 0 + 40.0)      # уклон по базе 40 м
    out = []
    ordered = sorted(crests_x)
    for n, xc in enumerate(ordered):
        xnext = ordered[n + 1] if n + 1 < len(ordered) else x_end
        m = (xs > xc) & (xs < xnext - 10)
        idx = np.where(m & (sl >= SLOPE_SEP))[0]
        if idx.size:
            xsd = float(xs[idx[0]])
            out.append(dict(x_s=xsd, z_s=float(panels.ground(xsd)) + 0.5 * ds_min,
                            rule=f"slope>={SLOPE_SEP} lee of crest x={xc:.0f}", slope=float(sl[idx[0]])))
    return out


def rotor_from_line(x, u, crest_x, nxt_x):
    """Самый длинный непрерывный участок u < ROTOR_U между гребнем и следующим гребнем (или концом); (bool, L)."""
    m = (x > crest_x) & (x < nxt_x) & np.isfinite(u) & (u < ROTOR_U)
    best = cur = 0
    dx = x[1] - x[0]
    for v in m:
        cur = cur + 1 if v else 0
        best = max(best, cur)
    L = best * dx
    return (L > ROTOR_LMIN), float(L if L > ROTOR_LMIN else 0.0)


# ---------------------------------------------------------------- один прогон панелей
def run_variants(terr, bg, points, crests_x, main_x, x_end, ds_min=25.0, u_adv=6.0,
                 variants=("potential", "vortex"), n_run=3, n_avg=2, x_lo=None, max_steps=20000, verbose=True):
    """points: список (name, x, zagl). Возвращает {variant: dict(vel=[(u,w)], t_solve_ms, t_query_us, rotor...)}.
    Вихревой вариант: если нет точек отрыва — копия потенциального (shed=False)."""
    res = {}
    P = build_panels(terr, x_focus=main_x, ds_min=ds_min)
    px = np.array([p[1] for p in points])
    pz_agl = np.array([p[2] for p in points])
    pz = P.ground(px) + pz_agl
    # потенциальный
    t0 = time.perf_counter()
    for _ in range(3):
        sig = solve(P, bg)
    t_solve = (time.perf_counter() - t0) / 3 * 1e3
    xl = np.arange(main_x - 100.0, x_end, 25.0)        # линия ротора
    zl = P.ground(xl) + ROTOR_Z
    xq = np.concatenate([np.tile(px, 200 // max(1, len(px)) + 1)[:200]])
    zq = np.concatenate([np.tile(pz, 200 // max(1, len(px)) + 1)[:200]])
    t0 = time.perf_counter()
    velocity(P, sig, bg, xq, zq)
    t_query = (time.perf_counter() - t0) / len(xq) * 1e6
    u, w = velocity(P, sig, bg, px, pz)
    ul, _ = velocity(P, sig, bg, xl, zl)
    res["potential"] = dict(u=u, w=w, t_solve_ms=t_solve, t_query_us=t_query, n_panels=P.n, shed=[],
                            xl=xl, ul=ul)
    # потенциальная скорость около земли для dt
    xs_ = np.arange(min(crests_x) - 500, x_end, 25.0)
    vv, ww = velocity(P, sig, bg, xs_, P.ground(xs_) + 0.5 * ds_min)
    umax = float(np.nanmax(np.hypot(vv, ww)))
    res["potential"]["umax"] = umax
    if "vortex" not in variants:
        return res
    shed = shed_points(P, ds_min, crests_x, x_end)
    if not shed:
        res["vortex"] = dict(res["potential"], shed=[], note="нет склона >= %.2f: вариант совпадает с potential" % SLOPE_SEP)
        return res
    dt = 0.5 * ds_min / umax
    x_hi = x_end
    x_lo = (min(crests_x) - 1000.0) if x_lo is None else x_lo
    z_top = float(P.ground(np.array(crests_x)).max()) + 1500.0
    t_span = (x_hi - min(crests_x)) / u_adv
    n_steps_run = int(np.ceil(n_run * t_span / dt))
    n_steps_avg = int(np.ceil(n_avg * t_span / dt))
    if n_steps_run + n_steps_avg > max_steps:
        f = max_steps / (n_steps_run + n_steps_avg)
        n_steps_run, n_steps_avg = int(n_steps_run * f), int(n_steps_avg * f)
        print("ВНИМАНИЕ: урезано число шагов", n_steps_run, n_steps_avg, file=sys.stderr)
    state = dict(panels=P, bg=bg, vortices=Vortices(), t=0.0, shed=shed)
    acc_p = np.zeros((2, len(px)))
    acc_l = np.zeros(len(xl))
    acc_p_h = [np.zeros((2, len(px))), np.zeros((2, len(px)))]
    acc_l_h = [np.zeros(len(xl)), np.zeros(len(xl))]
    nv_hist, step_ms = [], []
    nav = 0
    for n in range(n_steps_run + n_steps_avg):
        t0 = time.perf_counter()
        state = step(state, dt)
        vt = state["vortices"]
        if vt.n:
            gone = (vt.x > x_hi) | (vt.x < x_lo) | (vt.z > z_top)
            if gone.any():
                state["lost"] = state.get("lost", 0.0) + float(vt.gamma[gone].sum())
                k = ~gone
                state["vortices"] = Vortices(vt.x[k], vt.z[k], vt.gamma[k], vt.core[k])
        step_ms.append((time.perf_counter() - t0) * 1e3)
        nv_hist.append(state["vortices"].n)
        if n >= n_steps_run:
            vt = state["vortices"]
            sg = solve(P, bg, vt)
            uu, ww_ = velocity(P, sg, bg, px, pz, vt)
            ull, _ = velocity(P, sg, bg, xl, zl, vt)
            h = 0 if (n - n_steps_run) < n_steps_avg // 2 else 1
            acc_p += np.vstack([uu, ww_])
            acc_l += ull
            acc_p_h[h] += np.vstack([uu, ww_])
            acc_l_h[h] += ull
            nav += 1
        if verbose and n % 500 == 0:
            print(f"  step {n}/{n_steps_run + n_steps_avg} nv={state['vortices'].n}", flush=True)
    vt = state["vortices"]
    sg = solve(P, bg, vt)
    t0 = time.perf_counter()
    solve(P, bg, vt)
    ts = (time.perf_counter() - t0) * 1e3
    t0 = time.perf_counter()
    velocity(P, sg, bg, xq, zq, vt)
    tq = (time.perf_counter() - t0) / len(xq) * 1e6
    nh = [max(1, n_steps_avg // 2), max(1, n_steps_avg - n_steps_avg // 2)]
    drift = np.nanmax(np.abs(acc_p_h[0][0] / nh[0] - acc_p_h[1][0] / nh[1]))
    res["vortex"] = dict(u=acc_p[0] / nav, w=acc_p[1] / nav, t_solve_ms=ts, t_query_us=tq, n_panels=P.n, shed=shed,
                         xl=xl, ul=acc_l / nav, t_step_ms=float(np.mean(step_ms)), n_vortices=float(np.mean(nv_hist[-n_steps_avg:])),
                         dt=dt, n_steps=n_steps_run + n_steps_avg, t_model=(n_steps_run + n_steps_avg) * dt, t_span=t_span,
                         drift_u=float(drift), u_half=[acc_p_h[0][0] / nh[0], acc_p_h[1][0] / nh[1]],
                         born=state.get("born"), lost=state.get("lost"), umax=umax)
    return res


def rotor_of(r, crests_x, main_x, x_end):
    nxt = min([c for c in crests_x if c > main_x + 100] + [x_end])
    return rotor_from_line(r["xl"], r["ul"], main_x, nxt)
