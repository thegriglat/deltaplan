#!/usr/bin/env python3
"""Предел итераций несошедшихся решений (NN-P6): насколько решение с пределом отличается от сохранённого полного.

Набор main (П1 v1) посчитан с пределом ref_study.MAXIT = 3000 внешних итераций; статус «max» (12,7 % случаев,
374 из 3780 решений области) — решение не сошлось к допускам TOL за 3000 итераций, и ~75 % времени решателя
области уходит на них. Здесь каждое выбранное решение области пересчитывается тем же путём, что `solve_case`
(R.grid_domain → R.case → R.make → init_background → Solver.solve с TOL), а в обратном вызове `cb` (каждые
10 итераций; время cb решатель вычитает) снимаются срезы на 13 высотах в моменты предела — поле решения с пределом C
и есть состояние полного решения на итерации C (итерации детерминированы; проверяется прямым решением с
max_outer = C для одного случая и совпадением итога с файлом main).

Сравнение — на 60 м AGL (линейно между 50 и 75 м, как agl_key_m пилота), без 5 клеток у края, float16 как в файле:
|ΔV| = |Δ(u, v)|, |Δw|; медиана, p90, max по клеткам всех решений; доли клеток в порогах ШП-2 (ветер
≤ max(0,3 м/с; 10 % |V|), подъём < 0,1 м/с). Отдельно — сошедшиеся медленные решения (iters > 500, статус ok):
для них предел обрезает настоящее решение. Рядом — ошибка сети первого пилота на max- и ok-случаях
(pilot/reports/2026-10-02_pilot/metrics.json, per_point, «сеть»).

  .venv/bin/python tests/bench_maxcap.py [--n-max 12] [--n-oklong 6]    → tests/out/maxcap.json
Продолжается с места обрыва (кэш решений — $AIR_NN_DATA/pilot/tmp/nnp6_maxcap/). GPU — под замком пилота на
одно решение.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sqlite3
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import dataset as DS  # noqa: E402

CAPS = (300, 500, 750, 1000, 1500, 2000)
EDGE = 5
REPORT = "pilot/reports/2026-10-02_pilot/metrics.json"


def at60(sl):
    """(C, 13, ny, nx) float16 → (C, ny, nx) float32 на 60 м (между уровнями 50 и 75 м)."""
    a = sl.astype(np.float32)
    return a[:, 1] + (60.0 - 50.0) / 25.0 * (a[:, 2] - a[:, 1])


def solve_snap(c, tag, caps, direct_cap=None):
    """Решение области случая c (tag h/m) со снимками на пределах caps. → dict."""
    import airlite_gen as G
    import real as R
    import ref_study as RS
    import cupy as cp
    heat = tag == "h"
    g, hc = R.grid_domain(c["loc"], 400)
    cond = R.case(c["loc"], g, hc, c["hour"], c["U10"], c["wdir"], c["t_max"], c["sky"], heat)
    D = R.make(c["loc"], g, hc, cond)
    snaps, hist = {}, {}
    todo = sorted(caps)

    def cb(S, r):
        while todo and r["it"] >= todo[0]:
            k = todo.pop(0)
            sl = G.slices(S)
            snaps[k] = (sl if heat else sl[:3]).astype(np.float16)
            hist[k] = dict(it=r["it"], t=round(r["t"], 3), mom_rms=r["mom_rms"], th_rms=r["th_rms"], div_rms=r["div_rms"])

    cp.cuda.Device().synchronize()
    D.init_background()
    st = D.solve(max_outer=RS.MAXIT, cb=cb, **RS.TOL)
    sl = G.slices(D)
    full = (sl if heat else sl[:3]).astype(np.float16)
    out = dict(status=st, iters=D.outer, t_solve=round(D.wall - D.t_check, 3), snaps=snaps, hist=hist, full=full,
               last=D.hist[-1])
    RS.free(D)
    if direct_cap is not None:
        D = R.make(c["loc"], g, hc, cond)
        r = RS.solve(D, max_outer=direct_cap)
        sl = G.slices(D)
        out["direct"] = dict(cap=direct_cap, iters=r["iters"], status=r["status"], t_solve=r["t_solve"],
                             arr=(sl if heat else sl[:3]).astype(np.float16))
        RS.free(D)
    return out


def stats(x):
    x = np.asarray(x, np.float64)
    return dict(median=round(float(np.median(x)), 4), p90=round(float(np.percentile(x, 90)), 4),
                max=round(float(x.max()), 4))


def pick(con, n_max, n_oklong, seed=6):
    rng = np.random.default_rng(seed)
    rows = con.execute("SELECT id, kind, runs, cond FROM cases WHERE status='done' ORDER BY ord").fetchall()
    mx = {k: [] for k in ("real", "synth", "proc")}
    okl = []
    for cid, kind, runs, cond in rows:
        R = json.loads(runs)
        tags = [t for t in ("h", "m") if R[f"d400_{t}"]["status"] == "max"]
        if tags:
            mx[kind].append((cid, tags))
        for t in ("h", "m"):
            v = R[f"d400_{t}"]
            if v["status"] == "ok" and v["iters"] > 500:
                okl.append((cid, [t]))
    share = dict(real=0.4, synth=0.2, proc=0.4)   # real — главное для П-2 (места t_* реальные)
    sel = []
    for k, f in share.items():
        n = max(1, round(n_max * f))
        idx = rng.choice(len(mx[k]), size=min(n, len(mx[k])), replace=False)
        sel += [("max", *mx[k][i]) for i in sorted(idx)]
    idx = rng.choice(len(okl), size=min(n_oklong, len(okl)), replace=False)
    sel += [("oklong", *okl[i]) for i in sorted(idx)]
    return sel


def net_errors(root, con):
    p = Path(root) / REPORT
    if not p.exists():
        return None
    m = json.loads(p.read_text())
    st = dict(con.execute("SELECT id, solve_status FROM cases").fetchall())
    out = {}
    for grp in ("max", "ok"):
        pts = [r for r in m["per_point"] if r["pred"] == "net" and r["set"] != "train" and st.get(r["case"]) == grp]
        if not pts:
            continue
        out[grp] = dict(n_points=len(pts), n_cases=len({r["case"] for r in pts}),
                        wind=stats([r["wind"] for r in pts]), lift_m=stats([r["lift_m"] for r in pts]),
                        lift_h=stats([r["lift_h"] for r in pts]),
                        wind_ok_frac=round(float(np.mean([r["wind"] <= max(0.3, 0.1 * r["true_speed"]) for r in pts])), 3))
    out["note"] = ("ошибка сети первого пилота против решателя в точках оценки на 60 м (не обучающие наборы), "
                   "case-статус main: max — хотя бы одно решение области не сошлось")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n-max", type=int, default=12)
    ap.add_argument("--n-oklong", type=int, default=6)
    ap.add_argument("--out", default=str(HERE / "tests/out/maxcap.json"))
    a = ap.parse_args()
    cfg = DS.load_cfg(HERE / "configs/dataset.yaml")
    root = os.environ.get("AIR_NN_DATA") or cfg["data_root"]
    L = DS.Layout(cfg, root, "main")
    con = sqlite3.connect(f"file:{L.db}?mode=ro", uri=True)
    plan = json.loads(L.plan.read_text())
    proc_seed = plan["proc"]["seed"]
    import procedural as PR
    PR.configure(proc_seed)
    conds = {c["id"]: c for c in plan["cases"]}
    sel = pick(con, a.n_max, a.n_oklong)
    cache = Path(root) / "pilot/tmp/nnp6_maxcap"
    cache.mkdir(parents=True, exist_ok=True)
    stop = DS.Stopper(False)
    per = []
    t0 = time.time()
    for n, (grp, cid, tags) in enumerate(sel):
        z = np.load(L.case_file(cid))
        for tag in tags:
            f = cache / f"{cid}_{tag}.npz"
            if not f.exists():
                with DS.GpuLock(stop) as lk:
                    r = solve_snap(conds[cid], tag, CAPS, direct_cap=1000 if n == 0 else None)
                arrs = {f"cap{k}": v for k, v in r["snaps"].items()}
                arrs["full"] = r["full"]
                meta = {k: r[k] for k in ("status", "iters", "t_solve", "hist", "last")}
                meta["lock_wait_s"] = round(lk.wait, 1)
                if "direct" in r:
                    arrs["direct"] = r["direct"].pop("arr")
                    meta["direct"] = r["direct"]
                arrs["meta"] = np.array(json.dumps(meta, default=float))
                tmp = f.with_suffix(".part.npz")
                np.savez(tmp, **arrs)
                os.replace(tmp, f)
            c = np.load(f)
            meta = json.loads(str(c["meta"]))
            ref = z[f"d400_{tag}"]
            same = bool(np.array_equal(c["full"].view(np.uint16), ref.view(np.uint16)))
            rec = dict(group=grp, case=cid, tag=tag, kind=DS.kind_of(conds[cid]["loc"]), U10=conds[cid]["U10"],
                       hour=conds[cid]["hour"], sky=conds[cid]["sky"], iters_full=meta["iters"], status_full=meta["status"],
                       t_full=meta["t_solve"], full_equals_main=same, hist=meta["hist"], caps={})
            if "direct" in c.files:
                k = meta["direct"]["cap"]
                rec["direct_equals_snapshot"] = bool(np.array_equal(c["direct"].view(np.uint16), c[f"cap{k}"].view(np.uint16)))
                rec["direct"] = meta["direct"]
            F = at60(ref)[:, EDGE:-EDGE, EDGE:-EDGE]
            Vf = np.hypot(F[0], F[1])
            for k in CAPS:
                # сошлось раньше предела — решение с пределом = полное (снимка нет)
                X = at60(c[f"cap{k}"] if f"cap{k}" in c.files else c["full"])[:, EDGE:-EDGE, EDGE:-EDGE]
                dV = np.hypot(X[0] - F[0], X[1] - F[1])
                dw = np.abs(X[2] - F[2])
                rec["caps"][k] = dict(dV=dV.ravel(), dw=dw.ravel(), Vf=Vf.ravel(),
                                      t=meta["hist"].get(str(k), {}).get("t"))
            per.append(rec)
        print(f"[{(time.time() - t0) / 60:5.1f} мин] {n + 1}/{len(sel)} {grp} {cid} {tags}", flush=True)

    # сводка по пределам
    out = dict(what="решение области с пределом итераций против сохранённого полного (main, MAXIT 3000) на 60 м AGL",
               method=__doc__.split("\n\n")[1].replace("\n", " "), caps=list(CAPS), edge_cells=EDGE,
               thresholds=dict(wind_ms=0.3, wind_rel=0.1, lift_ms=0.1, maxcap_target_p90_dV=0.1),
               solver_version=DS.solver_version(), cases=[], by_cap={})
    for grp in ("max", "oklong"):
        rs = [r for r in per if r["group"] == grp]
        for k in CAPS:
            dV = np.concatenate([r["caps"][k]["dV"] for r in rs])
            dw = np.concatenate([r["caps"][k]["dw"] for r in rs])
            Vf = np.concatenate([r["caps"][k]["Vf"] for r in rs])
            hit = [r for r in rs if r["iters_full"] > k]
            out["by_cap"].setdefault(str(k), {})[grp] = dict(
                n_solutions=len(rs), n_cut=len(hit), dV=stats(dV), dw=stats(dw),
                frac_wind_ok=round(float(np.mean(dV <= np.maximum(0.3, 0.1 * Vf))), 4),
                frac_lift_ok=round(float(np.mean(dw < 0.1)), 4),
                per_solution_p90_dV=[round(float(np.percentile(r["caps"][k]["dV"], 90)), 3) for r in rs])
    for r in per:
        out["cases"].append({k: v for k, v in r.items() if k != "caps"} |
                            dict(p90_dV={k: round(float(np.percentile(v["dV"], 90)), 3) for k, v in r["caps"].items()},
                                 p90_dw={k: round(float(np.percentile(v["dw"], 90)), 3) for k, v in r["caps"].items()}))
    rs = [r for r in per if r["group"] == "max"]
    out["n_cases"] = len({r["case"] for r in rs})
    out["n_solutions_max"] = len(rs)
    out["full_equals_main"] = all(r["full_equals_main"] for r in per)
    out["direct_equals_snapshot"] = [r.get("direct_equals_snapshot") for r in per if "direct_equals_snapshot" in r]
    out["net_first_pilot"] = net_errors(root, con)
    # время решателя области по main при пределе C (t_init + t_solve·min(iters, C)/iters — линейно по итерациям)
    rows = con.execute("SELECT runs FROM cases WHERE status='done'").fetchall()
    sols = [v for (r,) in rows for t, v in json.loads(r).items() if t.startswith("d400")]
    t_full = sum(v["t_init"] + v["t_solve"] for v in sols)
    t_max = sum(v["t_init"] + v["t_solve"] for v in sols if v["status"] == "max")
    out["time_model_main"] = dict(
        n_solutions=len(sols), n_max=sum(v["status"] == "max" for v in sols), solver_h_full=round(t_full / 3600, 3),
        max_share_full=round(t_max / t_full, 3),
        by_cap={str(k): dict(solver_h=round(sum(v["t_init"] + v["t_solve"] * min(v["iters"], k) / v["iters"] for v in sols) / 3600, 3),
                             n_ok_cut=sum(v["status"] == "ok" and v["iters"] > k for v in sols)) for k in CAPS})
    for k in CAPS:
        out["time_model_main"]["by_cap"][str(k)]["saving"] = round(1 - out["time_model_main"]["by_cap"][str(k)]["solver_h"] * 3600 / t_full, 3)
    # выбор: наименьший предел, при котором на max-решениях p90 |ΔV| ≤ 0,1 и p90 |Δw| ≤ 0,03 и у обрезанных
    # сошедшихся (oklong) p90 |ΔV| ≤ 0,1
    choice = None
    for k in CAPS:
        b = out["by_cap"][str(k)]
        if b["max"]["dV"]["p90"] <= 0.1 and b["max"]["dw"]["p90"] <= 0.03 and b["oklong"]["dV"]["p90"] <= 0.1:
            choice = k
            break
    out["chosen_cap"] = choice
    ck = str(choice if choice else CAPS[-1])
    out["p90_dV_60m"] = out["by_cap"][ck]["max"]["dV"]["p90"]
    out["p90_dw_60m"] = out["by_cap"][ck]["max"]["dw"]["p90"]
    out["median_dV_60m"] = out["by_cap"][ck]["max"]["dV"]["median"]
    out["max_dV_60m"] = out["by_cap"][ck]["max"]["dV"]["max"]
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(out, ensure_ascii=False, indent=1, default=float) + "\n")
    print(json.dumps({k: out[k] for k in ("n_cases", "chosen_cap", "p90_dV_60m", "p90_dw_60m", "full_equals_main",
                                          "direct_equals_snapshot")}, ensure_ascii=False))
    for k in CAPS:
        b = out["by_cap"][str(k)]
        print(f"  предел {k:5d}: max dV {b['max']['dV']}  dw {b['max']['dw']} | oklong dV {b['oklong']['dV']} "
              f"| время решателя main {out['time_model_main']['by_cap'][str(k)]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
