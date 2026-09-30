"""А1.1 — пробы «до/после» структурных правок решателя воздуха, без правок air.py (подклассы).

Правки (docs/plan/air_model_a1.md):
  1. Pr_t: K_θ = K_m/Pr_t (и K_θ,h = K_h/Pr_t) — класс PrtAir;
  2. выхолаживание с τ только диабатической части θ′: второй переносимый скаляр θ′_d
     (L θ′_d = Q − θ′_d/τ), полное θ′ — L θ′ = Q − w·dθ̄/dz − θ′_d/τ — класс SplitAir (схема A′ плана);
  3. closure = const + heat_mode = cbl: h слоя как в hb, K = nu_const — класс HAir.

  PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python   (CuPy + brotli)
  flock /tmp/heat_ca_gpu.lock $PY probe.py saddle   # (2): ×(седло/склон) при τ 1800/7200/21600, до и после
  flock /tmp/heat_ca_gpu.lock $PY probe.py const    # (3): const + cbl падает; с h как в hb — считается
  flock /tmp/heat_ca_gpu.lock $PY probe.py heat     # heated_slope: до/после разделения, баланс тепла
  flock /tmp/heat_ca_gpu.lock $PY probe.py prt      # (1): Онгудай 12:00, штиль и 3 м/с, Pr_t 1 / 0,85 / 0,74
Выход — out/<проба>.json.
"""
from __future__ import annotations

import dataclasses
import json
import math
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "air3d"))
OUT = HERE / "out"
OUT.mkdir(exist_ok=True)
AFTER = False          # «after» вторым аргументом: правки уже в air.py — всё на A.Air, выход out/<проба>_after.json

import air as A          # noqa: E402
import synth as SY       # noqa: E402


# ------------------------------------------------------------------------------------------ 1. Pr_t
class PrtAir(A.Air):
    """K_θ = K_m/Pr_t по вертикали и K_θ,h = K_h/Pr_t по горизонтали (в air.py khf — псевдоним nuf)."""

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        cp = self.cp
        self.inv_prt = float(1.0 / self.prm.pr_t)
        self.khf = self.nuf * self.dt.type(self.inv_prt)
        self.khh = self.nuh * self.dt.type(self.inv_prt)

    def update_k(self):
        super().update_k()
        R = self.dt.type
        self.cp.multiply(self.nuf, R(self.inv_prt), out=self.khf)
        self.cp.multiply(self.nuh, R(self.inv_prt), out=self.khh)

    def _heat_kernel(self, th, Q, thb, gam, corr, C, b, inv_tau):
        gr, bl = self._grid1()
        R = self.dt.type
        self.k["build_heat"](gr, bl, (self.u, self.v, self.w, self.cell, th, Q, self.spc, thb, gam,
                                      self.khf, self.khh, corr, C, b, np.int32(self.NZ), np.int32(self.NY),
                                      np.int32(self.NX), R(self.dx), R(self.dz), R(1.0 / self.prm.dtau_th),
                                      R(inv_tau)))

    def build_heat(self):
        self._heat_kernel(self.th, self.Q, self.thbg, self.gam, self.ct, self.Ct, self.bt, 1.0 / self.prm.tau_cool)


# ------------------------------------------------------------------------------------------ 2. θ′ = θ′_a + θ′_d
class SplitAir(PrtAir):
    """Схема A′: th — полное θ′ (плавучесть, N², ореол, поле игры), thd — диабатическая часть.
        L θ′_d = Q − θ′_d/τ − s_θ (θ′_d − θ_b,d)
        L θ′   = Q − w dθ̄/dz − θ′_d/τ − s_θ (θ′ − θ_b)
    Одно ядро build_heat: для θ′_d — gam = 0, inv_tau = 1/τ; для θ′ — Q_eff = Q − θ′_d/τ, inv_tau = 0."""

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        cp, dt = self.cp, self.dt
        self.thd = cp.zeros(self.shape, dt)
        self.thbd = cp.zeros(self.shape, dt)
        self.Ctd = cp.zeros((7,) + self.shape, dt)
        self.btd = cp.zeros(self.shape, dt)
        self.ctd = cp.zeros(self.shape, dt)
        self.Qeff = cp.zeros(self.shape, dt)
        self.gam0 = cp.zeros(self.NZ, dt)
        self.inv_tau = float(1.0 / self.prm.tau_cool)

    # --- начальные поля / ореол
    def set_ghosts_background(self):
        super().set_ghosts_background()
        self.thd[...] = self.cp.where(self.cell == 1, self.thd, 0)

    def init_background(self):
        self.thd[...] = 0
        super().init_background()

    def init_from(self, st, with_p=True, cycles=4):
        self.thd[...] = self.cp.asarray(st["thd"], self.dt) if "thd" in st else 0
        super().init_from(st, with_p, cycles)

    def state(self):
        st = super().state()
        st["thd"] = self.thd.copy()
        return st

    def set_nest_bc(self, init=False):
        super().set_nest_bc(init)
        cp = self.cp
        P = self.nest["parent"]
        g, gp = self.g, P.g
        NZ, NY, NX = self.shape
        if hasattr(P, "thd"):
            T = (P.thd * (P.cell != 0).astype(P.dt)).get().astype(np.float64)
        else:
            T = np.zeros(P.shape)
        xc = g.x0 + (np.arange(NX) - 0.5) * g.dx
        yc = g.y0 + (np.arange(NY) - 0.5) * g.dx
        zc = g.z_bot + (np.arange(NZ) - 0.5) * g.dz
        Zc, Yc, Xc = np.meshgrid(zc, yc, xc, indexing="ij")
        tt = A.trilinear(T, (Zc - gp.z_bot) / gp.dz + 0.5, (Yc - gp.y0) / gp.dx + 0.5, (Xc - gp.x0) / gp.dx + 0.5)
        tt = np.where(self.cell_np == 0, 0, tt)
        self.thbd[...] = cp.asarray(tt, self.dt)
        if init:
            self.thd[...] = cp.asarray(tt, self.dt)
        else:
            self.thd[...] = cp.where(self.cell == 2, cp.asarray(tt, self.dt), self.thd)

    # --- шаг тепла
    def adv2_heat(self):
        super().adv2_heat()
        if self.prm.adv2:
            gr, bl = self._grid1()
            R = self.dt.type
            self.k["adv2_heat"](gr, bl, (self.u, self.v, self.w, self.cell, self.thd, self.ctd,
                                         np.int32(self.NZ), np.int32(self.NY), np.int32(self.NX), R(self.dx), R(self.dz)))
        else:
            self.ctd[...] = 0

    def _build_d(self):
        self._heat_kernel(self.thd, self.Q, self.thbd, self.gam0, self.ctd, self.Ctd, self.btd, self.inv_tau)

    def _build_t(self):
        R = self.dt.type
        self.cp.multiply(self.thd, R(self.inv_tau), out=self.Qeff)
        self.cp.subtract(self.Q, self.Qeff, out=self.Qeff)
        self._heat_kernel(self.th, self.Qeff, self.thbg, self.gam, self.ct, self.Ct, self.bt, 0.0)

    def build_heat(self):
        self._build_d()
        self._build_t()

    def heat_step(self):
        for _ in range(self.prm.heat_sweeps):
            self.lines.sweep(self.Ctd, self.thd, self.btd)
        self._build_t()                       # правая часть θ′ — от нового θ′_d
        for _ in range(self.prm.heat_sweeps):
            self.lines.sweep(self.Ct, self.th, self.bt)

    def residuals(self):
        cp = self.cp
        out = super().residuals()             # build_heat → оба шаблона; невязка полного θ′
        self.lines.resid(self.Ctd, self.thd, self.btd, self.rr)
        r = cp.abs(self.rr) * self.fluid
        d_max, d_rms = float(r.max()), float(cp.sqrt(cp.sum(r * r) / self.n_fluid))
        out["thd_max"], out["thd_rms"] = d_max, d_rms
        out["th_max"] = max(out["th_max"], d_max)
        out["th_rms"] = max(out["th_rms"], d_rms)   # критерий — по обоим скалярам
        return out

    def heat_budget(self):
        cp = self.cp
        hb = super().heat_budget()
        V = self.dx * self.dx * self.dz
        hb["cool"] = float(cp.sum(self.thd * self.fluid, dtype=np.float64)) * V / self.prm.tau_cool
        res = hb["q_in"] + hb["bg"] - hb["cool"] - hb["sponge"] - hb["outflow"]
        scale = abs(hb["q_in"]) + abs(hb["bg"]) + abs(hb["cool"]) + abs(hb["sponge"]) + abs(hb["outflow"])
        hb["residual"], hb["rel"] = res, (res / scale if scale > 0 else None)
        return hb


# ------------------------------------------------------------------------------------------ 3. h при const
class HAir(A.Air):
    """closure = const: h, w*, L — как в hb (Троен–Март), постоянна только вязкость (как MAir Морриса)."""

    def _closure(self):
        if self.prm.closure != "const":
            return super()._closure()
        p = self.prm
        self.prm = dataclasses.replace(p, closure="hb")
        try:
            super()._closure()
        finally:
            self.prm = p
        return np.full(self.shape, p.nu_const), dict(kind="const", nu=p.nu_const, h_max=float(self.h_bl.max()))


# ------------------------------------------------------------------------------------------ вспомогательное
def free(*objs):
    import cupy as cp
    import gc
    for o in objs:
        if o is None:
            continue
        if hasattr(o, "release"):
            o.release()
        for k in list(vars(o)):
            if k not in ("g", "case", "prm", "loc", "hc"):
                setattr(o, k, None)
    gc.collect()
    cp.get_default_memory_pool().free_all_blocks()


def info(S):
    last = S.hist[-1] if S.hist else {}
    return dict(status=S.status, iters=int(S.outer), t_solve=round(S.wall - S.t_check, 2),
                th_rms=last.get("th_rms"), thd_rms=last.get("thd_rms"), mom_rms=last.get("mom_rms"))


def run(cls, g, hc, case, prm, max_outer=3000, taper=True):
    S = cls(g, hc, case, prm, dtype=np.float32, taper=taper)
    S.init_background()
    S.solve(max_outer=max_outer)
    S.finalize()
    return S


def dump(name, obj):
    name = name + ("_after" if AFTER else "")
    (OUT / f"{name}.json").write_text(json.dumps(obj, ensure_ascii=False, indent=1, default=lambda o: float(o)))
    print(json.dumps(obj, ensure_ascii=False, indent=1, default=lambda o: float(o)))


# ------------------------------------------------------------------------------------------ пробы
def saddle_obs(S, g):
    """Как morris/model.py::case_saddle: ×(седло/перед склоном) на 20 и 50 м, за седлом 50 м."""
    u, v, w, th = S.centers()
    sp = SY.speed(u, v)
    j0 = int(np.argmin(np.abs(g.y)))
    i_sad = int(np.argmin(np.abs(g.x)))
    i_up = int(np.argmin(np.abs(g.x + 3000)))
    i_lee = int(np.argmin(np.abs(g.x - 1500)))
    obs = {}
    for h in (20, 50):
        obs[f"ratio{h}"] = float(SY.agl(S, sp, h)[j0, i_sad] / SY.agl(S, sp, h)[j0, i_up])
    obs["lee50"] = float(SY.agl(S, sp, 50)[j0, i_lee] / SY.agl(S, sp, 50)[j0, i_up])
    obs["th_min"], obs["th_max"] = float(np.nanmin(th)), float(np.nanmax(th))
    obs["s20_axis"] = [float(x) for x in SY.agl(S, sp, 20)[j0]]     # разрез вдоль ветра через седло
    return obs


def probe_saddle():
    g = SY.grid3d(100.0, 12800, 3000)
    X, Y = SY.XY(g)
    hc = SY.saddle3d(X, Y)
    case = A.Case(U10=5.0, wdir=270.0, gam=SY.const_gam(SY.GAM_N))
    res = dict(x=[float(x) for x in g.x], h_axis=[float(x) for x in hc[int(np.argmin(np.abs(g.y)))]], runs={})
    for label, cls in (("now", A.Air), ("split", SplitAir)):
        for tau in (1800.0, 7200.0, 21600.0):
            S = run(cls, g, hc, case, A.Params(tau_cool=tau))
            r = dict(info=info(S), **saddle_obs(S, g))
            r["budget"] = S.heat_budget()
            if label == "split":
                r["thd_absmax"] = float(self_absmax(S.thd, S))
            res["runs"][f"{label}_tau{int(tau)}"] = r
            print(label, tau, {k: v for k, v in r.items() if k in ("info", "ratio20", "ratio50", "lee50", "th_min", "th_max")}, flush=True)
            free(S)
    for label in ("now", "split"):
        a, b = res["runs"][f"{label}_tau1800"], res["runs"][f"{label}_tau21600"]
        res[f"{label}_delta_ratio20"] = a["ratio20"] - b["ratio20"]
        res[f"{label}_delta_ratio50"] = a["ratio50"] - b["ratio50"]
    dump("saddle", res)


def self_absmax(arr, S):
    return float(S.cp.max(S.cp.abs(arr * S.fluid)))


def heated_slope():
    """Случай heated_slope из fixtures.py (прогретый склон, штиль, слой перемешивания 1500 м)."""
    g = A.Grid(100.0, 24, 24, 100.0, -100.0, 16, -1200.0, -1200.0)
    X, Y = np.meshgrid(g.x, g.y)
    hc = SY.ridge3d(X, Y, 400.0, 400.0, 600.0)
    H = SY.sun_flux(hc, g.dx, az=100.0, el=45.0)
    gam = SY.cbl_gam(1500.0, 5.8e-3)
    return g, hc, A.Case(U10=0.0, gam=gam, z_i=1500.0, H=H)


def probe_const():
    g, hc, case = heated_slope()
    res = {}
    prm = A.Params(closure="const", nu_const=30.0, heat_mode="cbl")
    try:
        S = run(A.Air, g, hc, case, prm, taper=False)
        res["now_const_cbl"] = dict(status="ok?", info=info(S))
        free(S)
    except Exception as e:                       # noqa: BLE001
        res["now_const_cbl"] = dict(status="error", err=repr(e))
    S = run(A.Air, g, hc, case, A.Params(closure="const", nu_const=30.0, heat_mode="surface"), taper=False)
    res["now_const_surface"] = dict(info=info(S), closure=S.closure_info)
    free(S)
    S = run(HAir, g, hc, case, prm, taper=False)
    u, v, w, th = S.centers()
    res["fixed_const_cbl"] = dict(info=info(S), closure=S.closure_info, w_max=float(np.nanmax(w)), th_max=float(np.nanmax(th)),
                                  lam_max=float(S.lam_np.max()))
    free(S)
    S = run(A.Air, g, hc, case, A.Params(heat_mode="cbl"), taper=False)
    u, v, w, th = S.centers()
    res["hb_cbl_reference"] = dict(info=info(S), closure=S.closure_info, w_max=float(np.nanmax(w)), th_max=float(np.nanmax(th)))
    free(S)
    dump("const", res)


def probe_heat():
    g, hc, case = heated_slope()
    res = {}
    for label, cls in (("now", A.Air), ("split", SplitAir)):
        S = run(cls, g, hc, case, A.Params(), taper=False)
        u, v, w, th = S.centers()
        r = dict(info=info(S), w_max=float(np.nanmax(w)), w_min=float(np.nanmin(w)), th_max=float(np.nanmax(th)),
                 th_min=float(np.nanmin(th)), budget=S.heat_budget())
        if label == "split":
            thd = (S.thd * S.fluid).get()
            r["thd_max"], r["thd_min"] = float(thd.max()), float(thd.min())
            tha = ((S.th - S.thd) * S.fluid).get()
            r["tha_max"], r["tha_min"] = float(tha.max()), float(tha.min())
        res[label] = r
        free(S)
    dump("heat", res)


def probe_prt():
    import real as R
    import ref_study as RS
    res = {}
    orig = A.Air
    if not AFTER:
        A.Air = PrtAir                           # real.make берёт A.Air в момент вызова
    for U in (0.0, 3.0):
        for prt in (1.0, 0.85, 0.74):
            prm = A.Params(pr_t=prt)
            t0 = time.perf_counter()
            D = RS.domain(400.0, 12.0, U, prm=prm)
            rd = RS.solve(D)
            kd = R.key_numbers(D)
            W1 = RS.window(D, 100.0, 12.0, U, prm=prm)
            r1 = RS.solve(W1)
            W2 = RS.window(W1, 50.0, 12.0, U, prm=prm)
            r2 = RS.solve(W2)
            k2 = R.key_numbers(W2)
            kmax = float(D.cp.max((D.khf if not AFTER else D.nuf * D.inv_prt) * D.fluid))
            res[f"U{int(U)}_prt{prt}"] = dict(
                iters=dict(d400=rd["iters"], w100=r1["iters"], w50=r2["iters"]),
                status=dict(d400=rd["status"], w100=r1["status"], w50=r2["status"]),
                d400=dict(start_w200_max=kd["start_w200_max"], w200_p99=kd["w200_p99"], start_th50=kd["start_th50"]),
                w50=dict(start_w200_max=k2["start_w200_max"], start_speed50=k2["start_speed50"], start_w50=k2["start_w50"],
                         start_th50=k2["start_th50"], th_max=k2["th_max"]),
                k_theta_max_d400=kmax, t=round(time.perf_counter() - t0, 1))
            print(U, prt, res[f"U{int(U)}_prt{prt}"], flush=True)
            RS.free(W2, W1, D)
    A.Air = orig
    dump("prt", res)


def probe_ongudai():
    """Онгудай 12:00 (область 400 м → окно 100 → окно 50), штиль и 3 м/с: до/после разделения θ′
    (Pr_t = 1) — сходимость, подъём у старта, θ′; окна берут θ′_d ореола от родителя."""
    import real as R
    import ref_study as RS
    res = {}
    orig = A.Air
    try:
        for label, cls in (("now", A.Air), ("split", SplitAir)):
            A.Air = cls
            for U in (0.0, 3.0):
                prm = A.Params()
                t0 = time.perf_counter()
                D = RS.domain(400.0, 12.0, U, prm=prm)
                rd = RS.solve(D)
                kd = R.key_numbers(D)
                W1 = RS.window(D, 100.0, 12.0, U, prm=prm)
                r1 = RS.solve(W1)
                W2 = RS.window(W1, 50.0, 12.0, U, prm=prm)
                r2 = RS.solve(W2)
                k2 = R.key_numbers(W2)
                r = dict(iters=dict(d400=rd["iters"], w100=r1["iters"], w50=r2["iters"]),
                         status=dict(d400=rd["status"], w100=r1["status"], w50=r2["status"]),
                         t_solve=dict(d400=rd["t_solve"], w100=r1["t_solve"], w50=r2["t_solve"]),
                         d400=dict(start_w200_max=kd["start_w200_max"], w200_p99=kd["w200_p99"], w200_p01=kd["w200_p01"],
                                   start_th50=kd["start_th50"], th_min=kd["th_min"], th_max=kd["th_max"]),
                         w50=dict(start_w200_max=k2["start_w200_max"], start_speed50=k2["start_speed50"],
                                  start_w50=k2["start_w50"], start_th50=k2["start_th50"], th_min=k2["th_min"],
                                  th_max=k2["th_max"], saddle_speed50=k2.get("saddle_speed50")),
                         budget_d400=D.heat_budget(), budget_w50=W2.heat_budget(), t=round(time.perf_counter() - t0, 1))
                if label == "split":
                    for nm, S in (("d400", D), ("w50", W2)):
                        thd = (S.thd * S.fluid).get()
                        tha = ((S.th - S.thd) * S.fluid).get()
                        r[nm]["thd_range"] = [float(thd.min()), float(thd.max())]
                        r[nm]["tha_range"] = [float(tha.min()), float(tha.max())]
                res[f"{label}_U{int(U)}"] = r
                print(label, U, json.dumps({k: r[k] for k in ("iters", "status", "d400", "w50")}), flush=True)
                RS.free(W2, W1, D)
    finally:
        A.Air = orig
    dump("ongudai", res)


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "saddle"
    AFTER = len(sys.argv) > 2 and sys.argv[2] == "after"
    dict(saddle=probe_saddle, const=probe_const, heat=probe_heat, prt=probe_prt, ongudai=probe_ongudai)[what]()
