"""Отбор по чувствительности (Моррис) модели воздуха: факторы, случаи и наблюдаемые.

Эталон масштаба 1 — tools/research/air3d/air.py. Отбор 30.09.2026 считался с подклассом MAir (Pr_t
только по вертикали: K_θ = K_m/Pr_t, K_θ,h = K_h; h слоя при closure = const — как в hb); после А1
(docs/plan/air_model_a1.md) оба дополнения — в самом air.py (Pr_t — общий множитель на все три оси,
θ′_d — τ только для диабатической части), MAir удалён: повтор отбора — на A.Air как есть.
Случаи (все — air.py на GPU, float32, критерий сходимости как в калибровке AM-09):
  askervein — Askervein 210°, нейтрально, 25 м, область 4 км/потолок 1 км (как askervein_runs.py);
  ridge     — хребет Аньези H = L = 500 м, квази-2D, 50 м (synth.check4) + провал за гребнем;
  saddle    — хребет 500 м с седловиной 250 м, 100 м, ветер вдоль оси седла (synth.check5, 0°);
  oblique   — хребет 300 м, 100 м, ветер 0° и 45° к нормали (synth.check6);
  heat0/heat3 — Онгудай 12:00, штиль / 3 м/с, 150°: область 400 м → окно 100 м → окно 50 м (cost_check).
"""
from __future__ import annotations

import fcntl
import math
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "air3d"))
sys.path.insert(0, str(HERE.parent / "tune"))

import air as A          # noqa: E402
import synth as SY       # noqa: E402

LOCK = "/tmp/heat_ca_gpu.lock"

# ------------------------------------------------------------------------------------------- факторы
# kind: log — равномерно в ln между lo и hi; lin — линейно; cat — уровни (значения в levels).
# z0 и alpha — множители к номиналу случая (Askervein 0,03 м / 0,17; прочие случаи — Params: 0,1 м / 0,14).
FACTORS = [
    dict(name="lam_frac", kind="log", lo=0.02, hi=0.6, nom=0.25),
    dict(name="lam", kind="log", lo=15.0, hi=150.0, nom=40.0),
    dict(name="cs_h", kind="lin", lo=0.0, hi=0.30, nom=0.25),
    dict(name="pr_t", kind="log", lo=0.5, hi=1.3, nom=1.0),
    dict(name="k_fa", kind="log", lo=0.1, hi=3.0, nom=1.0),
    dict(name="z0_mul", kind="log", lo=1 / 3, hi=3.0, nom=1.0),
    dict(name="alpha_mul", kind="lin", lo=0.7, hi=1.4, nom=1.0),
    dict(name="tau_cool", kind="log", lo=1800.0, hi=21600.0, nom=7200.0),
    dict(name="zi_min", kind="log", lo=100.0, hi=600.0, nom=300.0),
    dict(name="k_smooth_m", kind="log", lo=500.0, hi=3000.0, nom=1500.0),
    dict(name="adv2", kind="cat", levels=[False, True], nom=True),
    dict(name="closure", kind="cat", levels=["hb", "const"], nom="hb"),
    dict(name="nu_const", kind="log", lo=5.0, hi=100.0, nom=30.0),
    dict(name="local_k", kind="cat", levels=[False, True], nom=True),
    dict(name="heat_mode", kind="cat", levels=["cbl", "surface"], nom="cbl"),
    dict(name="limiter", kind="cat", levels=[0, 1, 2], nom=0),
]
NAMES = [f["name"] for f in FACTORS]


def to_phys(u):
    """Точка плана в [0, 1]^k → значения факторов."""
    out = {}
    for f, x in zip(FACTORS, u):
        x = float(x)
        if f["kind"] == "log":
            out[f["name"]] = math.exp(math.log(f["lo"]) + x * (math.log(f["hi"]) - math.log(f["lo"])))
        elif f["kind"] == "lin":
            out[f["name"]] = f["lo"] + x * (f["hi"] - f["lo"])
        else:
            n = len(f["levels"])
            out[f["name"]] = f["levels"][min(int(x * n + 1e-9), n - 1)]
    return out


def params(fx, z0_nom, alpha_nom, **kw):
    """Params из значений факторов; kw — постоянные для случая (сетка, губки, f)."""
    p = dict(lam_frac=fx["lam_frac"], lam=fx["lam"], cs_h=fx["cs_h"], pr_t=fx["pr_t"], k_fa=fx["k_fa"],
             z0=z0_nom * fx["z0_mul"], alpha=alpha_nom * fx["alpha_mul"], tau_cool=fx["tau_cool"],
             zi_min=fx["zi_min"], k_smooth_m=fx["k_smooth_m"], adv2=bool(fx["adv2"]), closure=fx["closure"],
             nu_const=fx["nu_const"], local_k=bool(fx["local_k"]), heat_mode=fx["heat_mode"],
             limiter=int(fx["limiter"]) if fx["adv2"] else 0)
    p.update(kw)
    return A.Params(**p)


class GpuLock:
    """Замок GPU на один прогон (не на всю пачку — пробы других агентов проходят между точками)."""
    def __enter__(self):
        self.f = open(LOCK, "w")
        t0 = time.perf_counter()
        fcntl.flock(self.f, fcntl.LOCK_EX)
        self.wait = time.perf_counter() - t0
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


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


def meta(S):
    return dict(status=S.status, iters=int(S.outer), t=round(float(S.wall), 2))


# ------------------------------------------------------------------------------------------- случаи
def case_askervein(fx):
    import askervein as AK
    import askervein_runs as R
    dx, L, top = 25.0, 4000.0, 1000.0
    x0, y0, n, hc = AK.terrain(dx, L)
    dz = dx / 2
    nz = int(math.ceil(top / dz)) + 1
    nz += nz % 2
    g = A.Grid(dx, n, n, dz, -dz, nz, x0, y0)
    prm = params(fx, 0.03, 0.17, max_profile=2.0, f_cor=1.22e-4, sponge_side_m=1000.0)
    case = A.Case(U10=8.9, wdir=210.0, gam=SY.const_gam(0.0))
    S = SY.run(g, hc, case, prm, max_outer=4000)
    u, v, w, th = S.centers()
    sp = np.sqrt(u ** 2 + v ** 2 + w ** 2)
    obs = R.model_obs(S, g, sp)
    out = dict(runs=dict(askervein=meta(S)), obs={k: float(v) for k, v in obs.items()})
    free(S)
    return out


def case_ridge(fx):
    """synth.check4 (без потенциального решения) + провал за гребнем."""
    H, L = 500.0, 500.0
    g = SY.grid2d(50.0, 24000, 4500)
    hc = np.tile(SY.agnesi(g.x, H, L), (g.ny, 1))
    case = A.Case(U10=5.0, wdir=270, gam=SY.const_gam(0.0))
    prm = params(fx, 0.1, 0.14, sponge_axes="x")
    S = SY.run(g, hc, case, prm)
    u, v, w, th = S.centers()
    sp = SY.speed(u, v)
    z = g.z
    iu = int(np.argmin(np.abs(g.x + 8000)))
    up = np.nanmean(sp[:, :, iu], axis=1)
    near = np.abs(g.x) <= 3 * L
    obs = {}
    for mult in (2.0, 2.5):
        k = int(np.argmin(np.abs(z - mult * H)))
        row = np.nanmean(sp[k], axis=0)
        obs[f"ridge_su_{mult:g}H"] = float(np.nanmax(row[near]) / up[k] - 1)
        obs[f"ridge_w_{mult:g}H"] = float(np.nanmax(np.abs(np.nanmean(w[k], axis=0))[near]) / up[k])
    for h in (10, 50):
        s_h = np.nanmean(SY.agl(S, sp, h), axis=0)
        ref = np.nanmean(SY.agl(S, sp, h)[:, iu])
        obs[f"ridge_crest_su{h}"] = float(np.nanmax(s_h[near]) / ref - 1)
    # за гребнем: ветер на 20/50 м над землёй в 2L и 4L за гребнем к ветру вдали на той же высоте;
    # мин. продольная скорость на 20 м в полосе до 6L за гребнем (< 0 — возвратное течение, ротор)
    for h in (20, 50):
        s_h = np.nanmean(SY.agl(S, sp, h), axis=0)
        ref = np.nanmean(SY.agl(S, sp, h)[:, iu])
        for xl in (2, 4):
            i = int(np.argmin(np.abs(g.x - xl * L)))
            obs[f"lee_s{h}_{xl}L"] = float(s_h[i] / ref)
    u20 = np.nanmean(SY.agl(S, u, 20.0), axis=0)
    lee = (g.x > 0) & (g.x < 6 * L)
    obs["lee_umin20"] = float(np.nanmin(u20[lee]) / np.nanmean(SY.agl(S, sp, 20.0)[:, iu]))
    w50 = np.nanmean(SY.agl(S, w, 50.0), axis=0)
    obs["lee_wmin50"] = float(np.nanmin(w50[lee]) / np.nanmean(SY.agl(S, sp, 50.0)[:, iu]))
    out = dict(runs=dict(ridge=meta(S)), obs=obs)
    free(S)
    return out


def case_saddle(fx):
    g = SY.grid3d(100.0, 12800, 3000)
    X, Y = SY.XY(g)
    hc = SY.saddle3d(X, Y)
    case = A.Case(U10=5.0, wdir=270.0, gam=SY.const_gam(SY.GAM_N))
    S = SY.run(g, hc, case, params(fx, 0.1, 0.14))
    u, v, w, th = S.centers()
    sp = SY.speed(u, v)
    j0 = int(np.argmin(np.abs(g.y)))
    i_sad = int(np.argmin(np.abs(g.x)))
    i_up = int(np.argmin(np.abs(g.x + 3000)))
    i_lee = int(np.argmin(np.abs(g.x - 1500)))
    obs = {}
    for h in (20, 50):
        obs[f"saddle_ratio{h}"] = float(SY.agl(S, sp, h)[j0, i_sad] / SY.agl(S, sp, h)[j0, i_up])
    obs["saddle_lee50"] = float(SY.agl(S, sp, 50)[j0, i_lee] / SY.agl(S, sp, 50)[j0, i_up])
    out = dict(runs=dict(saddle=meta(S)), obs=obs)
    free(S)
    return out


def case_oblique(fx):
    g = SY.grid3d(100.0, 12800, 3000)
    X, Y = SY.XY(g)
    hc = SY.ridge3d(X, Y, 300.0, 500.0, 3000.0)
    res, runs = {}, {}
    mid = np.abs(g.y) < 1000
    wind = g.x < 0
    for ang in (0.0, 45.0):
        case = A.Case(U10=5.0, wdir=(270.0 - ang) % 360, gam=SY.const_gam(0.0))
        S = SY.run(g, hc, case, params(fx, 0.1, 0.14))
        u, v, w, th = S.centers()
        sp = SY.speed(u, v)
        runs[f"a{int(ang)}"] = meta(S)
        for h in (50, 100):
            res[(ang, h)] = float(np.nanmax(SY.agl(S, w, h)[np.ix_(mid, wind)]))
        ic = int(np.argmin(np.abs(g.x)))
        up_i = int(np.argmin(np.abs(g.x + 4000)))
        res[(ang, "su20")] = float(np.nanmean(SY.agl(S, sp, 20)[mid, ic]) / np.nanmean(SY.agl(S, sp, 20)[mid, up_i]) - 1)
        free(S)
    obs = {f"obl_w45_w0_{h}": res[(45.0, h)] / res[(0.0, h)] for h in (50, 100)}
    obs["obl_w0_50"] = res[(0.0, 50)]
    obs["obl_su20_0"] = res[(0.0, "su20")]
    obs["obl_su20_45"] = res[(45.0, "su20")]
    return dict(runs=runs, obs=obs)


def case_heat(fx, U):
    import real as R
    import ref_study as RS
    hour = 12.0
    prm = params(fx, 0.1, 0.14)
    D = RS.domain(400.0, hour, U, prm=prm)
    rd = RS.solve(D)
    kd = R.key_numbers(D)
    W1 = RS.window(D, 100.0, hour, U, prm=prm)
    r1 = RS.solve(W1)
    W2 = RS.window(W1, 50.0, hour, U, prm=prm)
    r2 = RS.solve(W2)
    k2 = R.key_numbers(W2)
    runs = {}
    for name, r in (("d400", rd), ("w100", r1), ("w50", r2)):
        runs[name] = dict(status=r["status"], iters=int(r["iters"]), t=float(r["t_solve"]))
    tag = f"h{int(U)}"
    obs = {f"{tag}_w200_start": k2["start_w200_max"], f"{tag}_speed50": k2["start_speed50"],
           f"{tag}_w50": k2["start_w50"], f"{tag}_th50": k2["start_th50"],
           f"{tag}_d400_w200_p99": kd["w200_p99"], f"{tag}_d400_w200_p01": kd["w200_p01"],
           f"{tag}_saddle50": k2.get("saddle_speed50", float("nan")),
           f"{tag}_log_iters": math.log(sum(r["iters"] for r in runs.values()))}
    RS.free(W2, W1, D)
    return dict(runs=runs, obs={k: float(v) for k, v in obs.items()})


CASES = dict(askervein=case_askervein, ridge=case_ridge, saddle=case_saddle, oblique=case_oblique,
             heat0=lambda fx: case_heat(fx, 0.0), heat3=lambda fx: case_heat(fx, 3.0))
