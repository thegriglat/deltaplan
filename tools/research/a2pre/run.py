"""Разведка перед А2: сходимость и цена air.py (после А1) на параметрах игры и перекалибровки Askervein.

Одна пачка, по строке на сценарий (цепочку решений) в out/<пачка>.jsonl, продолжение с места; замок GPU
/tmp/heat_ca_gpu.lock берётся на сценарий. Решатель не правится: только A.Params.

  PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python
  $PY run.py matrix            # параметры × {400→100→50, 200 (только old/new)} × условия × heat_mode → out/matrix.jsonl
  $PY run.py morris [N]        # несошедшиеся точки Морриса heat0 (подвыборка N), old и new → out/morris_rerun.jsonl
  $PY run.py trial             # 2 пробные точки Морриса (оценка времени) → out/trial.jsonl
  $PY run.py all [N]           # matrix + morris
  $PY run.py a2 [варианты]     # А2: old/new × {kr25, hs8, kr25hs8, top3000} → out/matrix_a2.jsonl
  $PY run.py scan [варианты]   # А2, отбор: SCAN на двух трудных cbl-случаях → out/scan_a2.jsonl
  $PY run.py a2trial           # А2: одна цепочка (оценка времени) в тот же файл

Наборы параметров (прочее — Params() = AirCase.p игры: 1-й порядок, hb, local_k, Pr_t 0,85, k_relax 0,5,
heat_sweeps 4):
  old       — игра сейчас: λ/h 0,25, α 0,14, z0 0,1 м, max_profile 1,8;
  new       — перекалибровка Askervein (tools/research/recal, docs/research/air-model-tune.md): λ/h 0,031, α 0,235,
              z0 0,09 м, max_profile 2,0 (профиль Askervein подогнан при 2,0: пара α–max_profile задаёт
              высоту насыщения z_sat = 10·mp^(1/α) = 191 м; при 1,8 и α 0,235 было бы 122 м);
  lam       — только λ/h 0,031 (α, z0, mp — игры): вклад λ/h отдельно от профиля притока;
  new_z003  — new, но z0 = 0,03 м (литература для Askervein, Taylor & Teunissen 1987): влияние z0 = 0,09 (край).
"""
from __future__ import annotations

import dataclasses
import fcntl
import json
import math
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / "air3d"))
sys.path.insert(0, str(ROOT / "tune"))
import air as A          # noqa: E402
import real as R         # noqa: E402
import ref_study as RS   # noqa: E402

OUT = HERE / "out"
OUT.mkdir(exist_ok=True)
LOCK = "/tmp/heat_ca_gpu.lock"
MORRIS_RUNS = Path("/home/greg/deltaplan-wf-morris/tools/research/morris/out/runs")
HOUR = 12.0
TOL = RS.TOL
MAXIT = RS.MAXIT

# k_relax 0,5 — значение до А2 (разведка и база матрицы А2 считались с ним; после А2 в Params — 0,1)
PSETS = {
    "old": dict(lam_frac=0.25, alpha=0.14, z0=0.1, max_profile=1.8, k_relax=0.5),
    "new": dict(lam_frac=0.031, alpha=0.235, z0=0.09, max_profile=2.0, k_relax=0.5),
    "lam": dict(lam_frac=0.031, alpha=0.14, z0=0.1, max_profile=1.8, k_relax=0.5),
    "new_z003": dict(lam_frac=0.031, alpha=0.235, z0=0.03, max_profile=2.0, k_relax=0.5),
}


class GpuLock:
    def __enter__(self):
        self.f = open(LOCK, "w")
        t0 = time.perf_counter()
        fcntl.flock(self.f, fcntl.LOCK_EX)
        self.wait = time.perf_counter() - t0
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


# ------------------------------------------------------------------------------------------ диагностика
def plateau(hist):
    """Невязки по проверкам (каждые 10 итераций): итог, плато на второй половине истории, признак цикла."""
    it = np.array([h["it"] for h in hist], float)
    th = np.array([h["th_rms"] for h in hist], float)
    thd = np.array([h["thd_rms"] for h in hist], float)
    mom = np.array([h["mom_rms"] for h in hist], float)
    div = np.array([h["div_rms"] for h in hist], float)
    out = dict(final=dict(th=th[-1], thd=thd[-1], mom=mom[-1], div=div[-1]))
    n = len(th)
    if n >= 20:
        h2 = slice(n // 2, n)
        lt = np.log(th[h2])
        slope = float(np.polyfit(it[h2], lt, 1)[0]) * 1000.0      # d ln(th_rms) / 1000 итераций
        # период качания: главный пик спектра ln th_rms (без тренда) на второй половине
        x = lt - np.polyval(np.polyfit(it[h2], lt, 1), it[h2])
        sp = np.abs(np.fft.rfft(x)) ** 2
        k = int(np.argmax(sp[1:]) + 1) if len(sp) > 2 else 0
        period = float(10.0 * len(x) / k) if k > 0 else None
        out.update(th_min=float(th[h2].min()), th_max=float(th[h2].max()), th_med=float(np.median(th[h2])),
                   thd_med=float(np.median(thd[h2])),
                   mom_min=float(mom[h2].min()), mom_max=float(mom[h2].max()), mom_med=float(np.median(mom[h2])),
                   div_med=float(np.median(div[h2])),
                   slope_ln_th_per_1000=slope, swing=float(th[h2].max() / th[h2].min()),
                   period_it=period, spec_peak_frac=float(sp[k] / sp[1:].sum()) if k > 0 else None)
    # какой критерий держит: доля проверок второй половины, где критерий выше порога
    if n >= 2:
        h2 = slice(n // 2, n)
        out["above"] = dict(th=float(np.mean(th[h2] >= TOL["tol_th"])), mom=float(np.mean(mom[h2] >= TOL["tol_mom"])),
                            div=float(np.mean(div[h2] >= TOL["tol_div"])))
    return out


def resid_where(S):
    """Где живёт невязка θ′ (max из θ′ и θ′_d по клетке) и w в конце: доли Σr² у граней (3 клетки),
    в полосе верха слоя перемешивания, высота максимума; карты max по z."""
    cp = S.cp
    S.residuals()                                  # собрать шаблоны от текущего состояния
    S.lines.resid(S.Ct, S.th, S.bt, S.rr)
    rt = (cp.abs(S.rr) * S.fluid).get().astype(np.float64)
    S.lines.resid(S.Ctd, S.thd, S.btd, S.rr)
    rd = (cp.abs(S.rr) * S.fluid).get().astype(np.float64)
    r = np.maximum(rt, rd)
    S.lines.resid(S.Cw, S.w, S.bw, S.rr)
    rw = (cp.abs(S.rr) * S.mu_w).get().astype(np.float64)
    zc = S.zc
    zi = S.case.z_i
    NZ, NY, NX = r.shape
    ii = np.arange(NX)[None, None, :]
    jj = np.arange(NY)[None, :, None]
    b = 3
    masks = dict(W=(ii <= b) & np.ones_like(r, bool), E=(ii >= NX - 1 - b) & np.ones_like(r, bool),
                 S=(jj <= b) & np.ones_like(r, bool), N=(jj >= NY - 1 - b) & np.ones_like(r, bool))
    out = {}
    for nm, f in (("th", r), ("w", rw)):
        tot = float(np.sum(f ** 2)) + 1e-300
        d = {f"edge_{s}": float(np.sum((f * m) ** 2) / tot) for s, m in masks.items()}
        edge = masks["W"] | masks["E"] | masks["S"] | masks["N"]
        d["edge_any"] = float(np.sum((f * edge) ** 2) / tot)
        if zi is not None and math.isfinite(zi):
            band = ((zc >= 0.75 * zi) & (zc <= 1.1 * zi))[:, None, None]
            d["zi_band"] = float(np.sum((f * band) ** 2) / tot)
        k, j, i = np.unravel_index(int(f.argmax()), f.shape)
        d["argmax"] = [int(k), int(j), int(i)]
        d["z_argmax_asl"] = float(zc[k])
        hc = S.hc
        d["z_argmax_agl"] = float(zc[k] - hc[min(max(j - 1, 0), hc.shape[0] - 1), min(max(i - 1, 0), hc.shape[1] - 1)])
        d["max"] = float(f.max())
        out[nm] = d
    out["z_i"] = zi
    maps = dict(th_plan=r.max(axis=0).astype(np.float32), w_plan=rw.max(axis=0).astype(np.float32),
                th_prof=np.sqrt((r ** 2).sum(axis=(1, 2)) / np.maximum(S.fluid_np.sum(axis=(1, 2)), 1)).astype(np.float32))
    return out, maps


def one(S, name, key, res, maps, warm_parent=False):
    r = RS.solve(S)
    hist = S.hist
    d = dict(status=r["status"], iters=int(r["iters"]), t_solve=r["t_solve"], t_init=r["t_init"], t_check=round(S.t_check, 3),
             wall=round(S.wall, 3), it_ms=round(1000.0 * r["t_solve"] / max(r["iters"], 1), 3), mem_mb=r["mem_mb"],
             grid=[S.g.nx, S.g.ny, S.g.nz], dx=S.g.dx, n_fluid=int(S.n_fluid))
    d["plateau"] = plateau(hist)
    d["hist"] = [[h["it"], float(f"{h['th_rms']:.3e}"), float(f"{h['thd_rms']:.3e}"), float(f"{h['mom_rms']:.3e}"),
                  float(f"{h['div_rms']:.3e}")] for h in hist]
    try:
        d["budget"] = S.heat_budget()
    except Exception as e:                            # noqa: BLE001
        d["budget"] = dict(err=repr(e))
    try:
        d["key"] = R.key_numbers(S)
    except Exception as e:                            # noqa: BLE001
        d["key"] = dict(err=repr(e))
    d["closure"] = {k: (float(v) if isinstance(v, (int, float, np.floating)) else v) for k, v in S.closure_info.items()} \
        if isinstance(getattr(S, "closure_info", None), dict) else None
    if maps is not None:
        w, m = resid_where(S)
        d["where"] = w
        for k2, v in m.items():
            maps[f"{key}|{name}|{k2}"] = v
    res[name] = d
    return d


def chain(prm, U, heat, dom, maps, key, top_above=None):
    """dom = 400: область 400 → окно 100 → окно 50; dom = 200: только область 200 (эталон picard/).
    top_above — потолок окон над максимумом рельефа окна, м (None — как в игре, 2000; диагностика А2)."""
    if top_above is not None:
        import functools
        g0 = R.grid_window
        R.grid_window = functools.partial(g0, top_above=float(top_above))
        try:
            return chain(prm, U, heat, dom, maps, key)
        finally:
            R.grid_window = g0
    res = {}
    D = RS.domain(float(dom), HOUR, U, heat=heat, prm=prm)
    one(D, f"d{dom}", key, res, maps)
    objs = [D]
    if dom == 400:
        W1 = RS.window(D, 100.0, HOUR, U, heat=heat, prm=prm)
        one(W1, "w100", key, res, maps)
        W2 = RS.window(W1, 50.0, HOUR, U, heat=heat, prm=prm)
        one(W2, "w50", key, res, maps)
        objs = [W2, W1, D]
    RS.free(*objs)
    return res


def done_keys(f):
    s = set()
    if f.exists():
        for line in f.read_text().splitlines():
            if line.strip():
                s.add(json.loads(line)["key"])
    return s


def run_list(items, fname, maps_name=None):
    f = OUT / fname
    done = done_keys(f)
    maps = {} if maps_name else None
    t0 = time.perf_counter()
    for n, it in enumerate(items):
        if it["key"] in done:
            continue
        prm = A.Params(**it["params"])
        with GpuLock() as L:
            t1 = time.perf_counter()
            try:
                res = chain(prm, it["U"], it["heat"], it["dom"], maps, it["key"], it.get("top_above"))
                st = "ok"
            except Exception as e:                    # noqa: BLE001
                import traceback
                traceback.print_exc()
                res, st = dict(err=repr(e)), "error"
            t_run = time.perf_counter() - t1
        rec = dict(it, run_status=st, solves=res, t_run=round(t_run, 2), lock_wait=round(L.wait, 2))
        with open(f, "a") as fh:
            fh.write(json.dumps(rec, default=float) + "\n")
        if maps is not None and maps:
            mf = OUT / maps_name
            old = dict(np.load(mf)) if mf.exists() else {}
            old.update(maps)
            np.savez_compressed(mf, **old)
            maps.clear()
        sts = {k: (v["status"], v["iters"]) for k, v in res.items() if isinstance(v, dict) and "status" in v}
        print(f"{n + 1}/{len(items)} {it['key']} {sts} {t_run:.1f}s  (всего {time.perf_counter() - t0:.0f}s)", flush=True)


# ------------------------------------------------------------------------------------------ планы
def plan_matrix():
    items = []
    for ps, pv in PSETS.items():
        for dom in ((400, 200) if ps in ("old", "new") else (400,)):
            for U, heat, modes in ((0.0, True, ("cbl", "surface")), (3.0, True, ("cbl", "surface")),
                                   (3.0, False, ("cbl",)), (0.0, False, ("cbl",))):
                for hm in modes:
                    key = f"{ps}|d{dom}|U{U:g}|{'heat' if heat else 'noheat'}|{hm}"
                    items.append(dict(key=key, pset=ps, dom=dom, U=U, heat=heat, heat_mode=hm,
                                      params=dict(pv, heat_mode=hm)))
    return items


# А2: численные правки сходимости поверх old и new (порядок пачки — как в задании А2: k_relax 0,25, затем
# heat_sweeps 8, затем их сочетание; «потолок окна выше z_i» — только диагностика гипотезы, в игру не вносится)
A2_VARIANTS = (
    ("kr25", dict(k_relax=0.25), None),
    ("hs8", dict(heat_sweeps=8), None),
    ("kr25hs8", dict(k_relax=0.25, heat_sweeps=8), None),
    ("kr10", dict(k_relax=0.1), None),                # после отбора (scan): k_relax 0,1 сводит оба трудных случая
    ("kr15", dict(k_relax=0.15), None),
    ("top3000", dict(), 3000.0),
)


def plan_a2(only=None):
    items = []
    for vn, vp, top in A2_VARIANTS:
        if only and vn not in only:
            continue
        part = []
        for ps in ("old", "new"):
            pv = dict(PSETS[ps], **vp)
            for dom in (400, 200):
                if top is not None and dom == 200:
                    continue                           # потолок окна — только цепочка с окнами
                for U, heat, modes in ((0.0, True, ("cbl", "surface")), (3.0, True, ("cbl", "surface")),
                                       (3.0, False, ("cbl",)), (0.0, False, ("cbl",))):
                    for hm in modes:
                        key = f"{ps}+{vn}|d{dom}|U{U:g}|{'heat' if heat else 'noheat'}|{hm}"
                        part.append(dict(key=key, pset=f"{ps}+{vn}", base=ps, variant=vn, dom=dom, U=U, heat=heat,
                                         heat_mode=hm, top_above=top, params=dict(pv, heat_mode=hm)))
        part.sort(key=lambda r: r["heat_mode"] != "cbl")   # в варианте сначала cbl (приёмка), потом surface
        items += part
    return items


# А2, отбор: ещё дешёвые численные параметры (C1 «Границы А2»), только на двух трудных cbl-случаях — new, штиль,
# нагрев, цепочка 400→100→50 (не сходится w50) и old, область 200 м, 3 м/с, нагрев; прошедшие — в полную матрицу
SCAN = (
    ("kr10", dict(k_relax=0.1)),
    ("dth600", dict(dtau_th=600.0)),
    ("dth300", dict(dtau_th=300.0)),
    ("dtm02", dict(dtau_per_m=0.2)),
    ("dtm015", dict(dtau_per_m=0.15)),
    ("ms4", dict(mom_sweeps=4)),
    ("vc2", dict(vcycles=2)),
)


def plan_scan(only=None):
    items = []
    for vn, vp in SCAN:
        if only and vn not in only:
            continue
        for ps, dom, U in (("new", 400, 0.0), ("old", 200, 3.0)):
            key = f"{ps}+{vn}|d{dom}|U{U:g}|heat|cbl"
            items.append(dict(key=key, pset=f"{ps}+{vn}", base=ps, variant=vn, dom=dom, U=U, heat=True,
                              heat_mode="cbl", top_above=None, params=dict(PSETS[ps], **vp, heat_mode="cbl")))
    return items


MORRIS_KEYS = ("lam", "cs_h", "pr_t", "k_fa", "tau_cool", "zi_min", "k_smooth_m", "adv2", "closure", "nu_const",
               "local_k", "heat_mode", "limiter")


def morris_params(fx, pv):
    p = dict(lam=fx["lam"], cs_h=fx["cs_h"], pr_t=fx["pr_t"], k_fa=fx["k_fa"], tau_cool=fx["tau_cool"],
             zi_min=fx["zi_min"], k_smooth_m=fx["k_smooth_m"], adv2=bool(fx["adv2"]), closure=fx["closure"],
             nu_const=fx["nu_const"], local_k=bool(fx["local_k"]), heat_mode=fx["heat_mode"],
             limiter=int(fx["limiter"]) if fx["adv2"] else 0)
    p.update(pv)
    return p


def morris_bad():
    """Несошедшиеся точки Морриса heat0 (любое из d400/w100/w50 не ok), без трёх факторов перекалибровки —
    уникальные конфигурации (с записью исходных статусов)."""
    rows = [json.loads(l) for l in (MORRIS_RUNS / "heat0.jsonl").read_text().splitlines() if l.strip()]
    uniq = {}
    for r in rows:
        if all(v["status"] == "ok" for v in r["runs"].values()):
            continue
        k = json.dumps({n: r["fx"][n] for n in MORRIS_KEYS}, sort_keys=True, default=str)
        uniq.setdefault(k, []).append(dict(id=r["id"], runs=r["runs"], lam_frac=r["fx"]["lam_frac"],
                                           z0_mul=r["fx"]["z0_mul"], alpha_mul=r["fx"]["alpha_mul"]))
    return [(json.loads(k), v) for k, v in uniq.items()]


def unit(fx):
    """Конфигурация → [0,1]^13 (как в plan Морриса: лог/лин/уровни)."""
    sys.path.insert(0, str(ROOT / "morris"))
    import model as M   # noqa: E402
    out = []
    for f in M.FACTORS:
        if f["name"] not in MORRIS_KEYS:
            continue
        x = fx[f["name"]]
        if f["kind"] == "log":
            out.append((math.log(x) - math.log(f["lo"])) / (math.log(f["hi"]) - math.log(f["lo"])))
        elif f["kind"] == "lin":
            out.append((x - f["lo"]) / (f["hi"] - f["lo"]))
        else:
            out.append(f["levels"].index(x) / max(len(f["levels"]) - 1, 1))
    return np.array(out)


def subsample(bad, n):
    """Равномерно по факторам: жадный максимин в [0,1]^13 от точки, ближайшей к центру."""
    if n >= len(bad):
        return list(range(len(bad)))
    X = np.array([unit(fx) for fx, _ in bad])
    sel = [int(np.argmin(np.sum((X - 0.5) ** 2, axis=1)))]
    d = np.sum((X - X[sel[0]]) ** 2, axis=1)
    while len(sel) < n:
        k = int(np.argmax(d))
        sel.append(k)
        d = np.minimum(d, np.sum((X - X[k]) ** 2, axis=1))
    return sorted(sel)


def plan_morris(n):
    bad = morris_bad()
    idx = subsample(bad, n)
    items = []
    for ps in ("new", "old"):
        pv = PSETS[ps]
        for i in idx:
            fx, orig = bad[i]
            items.append(dict(key=f"{ps}|m{i:03d}", pset=ps, dom=400, U=0.0, heat=True, heat_mode=fx["heat_mode"],
                              morris_idx=i, morris_fx=fx, morris_orig=orig, params=morris_params(fx, pv)))
    # чередовать new/old по точкам, чтобы при прерывании пары были полными
    items.sort(key=lambda r: (r["morris_idx"], r["pset"]))
    return items, len(bad)


def plan_b1():
    """Б1: регрессия матрицы А2 на λ совместной калибровки (cases/b1/out/fit.json) в двух переводах в параметры игры:
    (а) lam = λ, lam_frac = 0; (б) lam = 40, lam_frac = λ/h_нейтр (h — средняя нейтральная толщина двух случаев);
    α, z0, max_profile Онгудая — номинал игры (0,14 / 0,1 / 1,8) и перекалибровки (0,235 / 0,09 / 2,0) — сами не выбираются.
    k_relax — Params() (0,1, А2)."""
    fit = json.loads((HERE.parent / "cases/b1/out/fit.json").read_text())["joint_lam"]
    lam = float(fit["values"]["lam"])
    hA = fit["h_by_sub"]["tu03b"]
    hP = 0.5 * (fit["h_by_sub"]["ne"] + fit["h_by_sub"]["sw"])
    lf = lam / (0.5 * (hA + hP))
    prof = dict(game=dict(alpha=0.14, z0=0.1, max_profile=1.8), recal=dict(alpha=0.235, z0=0.09, max_profile=2.0))
    tr = dict(a=dict(lam=lam, lam_frac=0.0), b=dict(lam=40.0, lam_frac=lf))
    items = []
    for tn, tv in tr.items():
        for pn, pv in prof.items():
            ps = f"b1{tn}_{pn}"
            for dom in (400, 200):
                for U, heat, modes in ((0.0, True, ("cbl", "surface")), (3.0, True, ("cbl", "surface")),
                                       (3.0, False, ("cbl",)), (0.0, False, ("cbl",))):
                    for hm in modes:
                        key = f"{ps}|d{dom}|U{U:g}|{'heat' if heat else 'noheat'}|{hm}"
                        items.append(dict(key=key, pset=ps, base=pn, variant=tn, dom=dom, U=U, heat=heat, heat_mode=hm,
                                          params=dict(pv, **tv, heat_mode=hm), b1=dict(lam_fit=lam, lf=lf, h_ask=hA, h_pd=hP)))
    items.sort(key=lambda r: r["heat_mode"] != "cbl")
    return items


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "matrix"
    n = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 40
    if what in ("matrix", "all"):
        run_list(plan_matrix(), "matrix.jsonl", maps_name="matrix_maps.npz")
    if what in ("morris", "all"):
        items, nb = plan_morris(n)
        print(f"Моррис heat0: несошедшихся уникальных конфигураций {nb}, берём {len(items) // 2}", flush=True)
        run_list(items, "morris_rerun.jsonl", maps_name="morris_maps.npz")
    if what == "a2":
        only = sys.argv[2].split(",") if len(sys.argv) > 2 else None
        run_list(plan_a2(only), "matrix_a2.jsonl", maps_name="matrix_a2_maps.npz")
    if what == "b1":
        run_list(plan_b1(), "matrix_b1.jsonl")
    if what == "scan":
        only = sys.argv[2].split(",") if len(sys.argv) > 2 else None
        run_list(plan_scan(only), "scan_a2.jsonl")
    if what == "a2trial":                              # оценка времени: самый долгий cbl случай (new, штиль, цепочка)
        run_list([r for r in plan_a2(["kr25"]) if r["key"] == "new+kr25|d400|U0|heat|cbl"], "matrix_a2.jsonl",
                 maps_name="matrix_a2_maps.npz")
    if what == "trial":
        items, nb = plan_morris(200)
        # самые тяжёлые исходно (max во всех трёх) — первая попавшаяся, и лёгкая (max только в w50)
        heavy = [r for r in items if all(v["status"] != "ok" for v in r["morris_orig"][0]["runs"].values())][:2]
        run_list(heavy, "trial.jsonl")


if __name__ == "__main__":
    main()
