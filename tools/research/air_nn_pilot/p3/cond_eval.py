#!/usr/bin/env python3
"""NN-P14: откуда хвосты ошибки сети пилота — от условий случая, шума целей решателя или ёмкости.

Ошибка ветра |Δ(u,v)| (с нагревом) и подъёма |Δw| на высоте 60 м, клетки области без 5 клеток у края, набор (г) —
отложенные горные системы; сошедшиеся (`h` = ok) и несошедшиеся (`max`, цель late_mean) — отдельно.
Сеть — `model.onnx` через ORT на CPU (вход — кеш подготовки П-2: `X`, `F` из `run_info.json → prep_dirs`).

Этапы (оба с продолжением: готовые случаи пропускаются):
  predict — по случаям → <out>/cells/<id>.npz (ошибки по клеткам float16 + условия случая)
  report  — таблицы csv + summary.md в <out>
  all     — оба

Сеть П-2:
  cd tools/research/air_nn_pilot
  /home/greg/deltaplan/tools/dp lock cpu cond -- env CUDA_VISIBLE_DEVICES= .venv/bin/python p3/cond_eval.py all \
      --run $AIR_NN_DATA/pilot/runs/2026-10-03_p2b --out p3/out/cond_p2b
Сеть П-3: тот же вызов с `--run <каталог прогона П-3>` (берутся `main/model.onnx`, `run_info.json`, `split.json`) или
`--onnx <путь>/model.onnx` с `--run` прогона, чьи данные/разбиение нужны; `--out p3/out/cond_p3`. Если вход П-3 иной
(карты v5), заменить `predict_case` — остальное (условия, таблицы) не зависит от сети.
Кеш клеток крупный (≈ 40 МБ на 720 случаев) — в `<out>/cells/` (в git не идёт, .gitignore).
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import multiprocessing as mp
import os
import sys
import time
from pathlib import Path

import numpy as np
from scipy import ndimage
from scipy.stats import spearmanr

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import prep as P  # noqa: E402
from pilotnn.data import Datasets, case_groups, solution_info  # noqa: E402

DATA = Path(os.environ.get("AIR_NN_DATA") or "/home/greg/air_nn_data")
EDGE, A_KEY = 5, 60.0
OK_MS, OK_REL, OK_LIFT = 0.3, 0.1, 0.1
SET = "holdout_sys_ids"
_W = {}


# ------------------------------------------------------------------------------------------------ predict
def level_weights(agl, a):
    agl = list(agl)
    for i in range(len(agl) - 1):
        if agl[i] <= a <= agl[i + 1]:
            t = (a - agl[i]) / (agl[i + 1] - agl[i])
            return i, 1 - t, t
    raise ValueError(a)


def at_level(F, lw):
    i, w0, w1 = lw
    return w0 * F[..., i, :, :] + w1 * F[..., i + 1, :, :]


def terrain_axis(hr, r, dx=400.0):
    """Ориентация рельефа относительно ветра по тензору уклонов. hr — рельеф в повёрнутой системе (ветер по (cos r, sin r)).
    cross — cos² угла между ветром и главным направлением уклона (1 — ветер поперёк гребней, 0 — вдоль);
    aniso — (λ1−λ2)/(λ1+λ2) тензора ∑∇h∇hᵀ (0 — изотропно, 1 — один хребет); slope — rms уклона."""
    g = ndimage.gaussian_filter(hr.astype(np.float64), 1.0, mode="nearest")
    gy, gx = np.gradient(g, dx)
    s = (slice(EDGE, -EDGE),) * 2
    gx, gy = gx[s], gy[s]
    txx, tyy, txy = (gx * gx).mean(), (gy * gy).mean(), (gx * gy).mean()
    tr = txx + tyy
    d = math.sqrt(max(((txx - tyy) / 2) ** 2 + txy ** 2, 0.0))
    l1, l2 = tr / 2 + d, tr / 2 - d
    th = 0.5 * math.atan2(2 * txy, txx - tyy)                       # направление наибольшего уклона
    cross = math.cos(r - th) ** 2
    return dict(cross=float(cross), aniso=float(d / tr) if tr > 0 else 0.0, slope=float(math.sqrt(tr)))


def bg_load(path):
    """P3E6: числа фона (film_bg.npz) → ({id: F (9,)}, {id: сырые}); None — пусто."""
    if not path:
        return {}, {}
    with np.load(path) as z:
        return dict(zip(z["ids"].tolist(), z["F"].astype(np.float32))), json.loads(str(z["raw"]))


def _init(onnx, dirs, bg=None):
    import onnxruntime as ort
    _W["bg"] = bg_load(bg)[0] if bg else None
    so = ort.SessionOptions()
    so.intra_op_num_threads = so.inter_op_num_threads = 1
    _W["sess"] = ort.InferenceSession(str(onnx), so, providers=["CPUExecutionProvider"])
    _W["dirs"] = dirs


def case_file(dirs, cid):
    for d in dirs:
        p = Path(d) / "cases" / f"{cid}.npz"
        if p.exists():
            return p
    raise FileNotFoundError(cid)


def predict_case(sess, X, F, meta):
    """→ физические предсказания {"h": (4, 13, ny, nx) …} (вход П-2: карты X и числа F из кеша подготовки)."""
    Yp = sess.run(None, dict(maps=X[None], nums=F[None]))[0][0]
    return P.to_physical(Yp, meta, P.AGL)


def work(job):
    cid, row, root, out = job
    f = out / "cells" / f"{cid}.npz"
    if f.exists():
        return cid
    with np.load(case_file(_W["dirs"], cid)) as zc:
        X, F, meta = zc["X"], zc["F"], json.loads(str(zc["meta"]))
    if _W.get("bg") is not None:                       # P3E6: + числа фона после 18 чисел П2
        F = np.concatenate([F, _W["bg"][cid]]).astype(np.float32)
    pred = predict_case(_W["sess"], X, F, meta)
    with np.load(root / "cases" / f"{cid}.npz") as zz:
        th4, hc, Hf = zz["d400_h"].astype(np.float64), zz["d400_hc"].astype(np.float64), zz["d400_H"].astype(np.float64)
    lw = level_weights(P.AGL, A_KEY)
    th, ph = at_level(th4, lw), at_level(pred["h"], lw)
    err = np.hypot(ph[0] - th[0], ph[1] - th[1])
    elift = np.abs(ph[2] - th[2])
    vt = np.hypot(th[0], th[1])
    k, r = meta["k"], meta["r"]
    s = (slice(EDGE, -EDGE),) * 2
    R = lambda a: np.ascontiguousarray(P.rot_scalar(a, k))[s].ravel().astype(np.float16)  # noqa: E731
    hr = np.ascontiguousarray(P.rot_scalar(hc, k))
    ax = terrain_axis(hr, r)
    ax.update(H_mean=float(Hf.mean()), H_p90=float(np.percentile(Hf, 90)), relief=float(np.ptp(hc)),
              tpi_std=float(hc.std()))
    tmp = f.with_suffix(".tmp.npz")
    np.savez_compressed(tmp, err=R(err), elift=R(elift), vt=R(vt), ax=json.dumps(ax))
    os.replace(tmp, f)
    return cid


def case_table(run, rows, bg_raw=None):
    """Условия случая и качество цели (из строки набора; невязка конца решения в наборах не хранится).
    bg_raw — сырые числа фона P3E6 (N_bl, Fr, gam_300: dθ̄/dz на 300 м над средней высотой рельефа, К/км)."""
    t = []
    for r in rows:
        day, pr, ctx = r.get("day") or {}, r["profile"], r.get("ctx") or {}
        h = (r.get("runs") or {}).get("d400_h") or {}
        si = solution_info(r, "d400_h")
        cap = day.get("cap_agl")
        capok = cap is not None and isinstance(cap, (int, float)) and math.isfinite(cap)
        zi, vm = day.get("z_i_msl"), day.get("valley_msl", ctx.get("valley_msl_m"))
        t.append(dict(
            id=r["id"], loc=r["loc"], system=(r.get("place") or {}).get("system", "?"), conv=int(si["converged"]),
            U10=float(r["U10"]), stab=str(pr.get("stab", "D")), heat=day.get("heat"), t_max=float(r["t_max"]),
            hour=float(r["hour"]), z_i=(zi - vm) if zi is not None and vm is not None else None,
            cap_flag=int(capok), cap_agl=float(cap) if capok else None, brk=day.get("brk"), sky=day.get("sky"),
            wdir=float(r["wdir"]), sun_el=pr.get("sun_el"), spread=si["spread"], iters=h.get("iters"),
            late_n=si["late_n"], t_solve=h.get("t_solve")))
        b = (bg_raw or {}).get(r["id"])
        if b:
            t[-1].update(N_bl=b["N_bl"], Fr=b["Fr"], gam_300=b["gam_kkm"][1], gam_1000=b["gam_kkm"][3])
    return t


def predict(a):
    run = Path(a.run)
    info = json.loads((run / "run_info.json").read_text())
    split = json.loads((run / "split.json").read_text())
    dss = Datasets([(d["name"], d["root"]) for d in info["datasets"]])
    rows = {r["id"]: r for r in dss.case_rows()}
    ids = sorted(split[SET])
    out = Path(a.out)
    (out / "cells").mkdir(parents=True, exist_ok=True)
    onnx = Path(a.onnx) if a.onnx else run / "main/model.onnx"
    jobs = [(c, rows[c], dss.ds_of(c).root, out) for c in ids]
    todo = [j for j in jobs if not (out / "cells" / f"{j[0]}.npz").exists()]
    print(f"predict: {len(jobs)} случаев, осталось {len(todo)}, модель {onnx}", flush=True)
    t0 = time.time()
    if todo:
        with mp.Pool(a.procs, _init, (onnx, info["prep_dirs"], a.film_bg if a.bg_input else None)) as pool:
            for i, _ in enumerate(pool.imap_unordered(work, todo, chunksize=2)):
                if i % 100 == 0:
                    print(f"  {i}/{len(todo)}  {time.time() - t0:.0f} с", flush=True)
    tab = case_table(run, [rows[c] for c in ids], bg_load(a.film_bg)[1] if a.film_bg else None)
    (out / "case_table.json").write_text(json.dumps(tab, ensure_ascii=False))
    (out / "source.json").write_text(json.dumps(dict(run=str(run), onnx=str(onnx), set=SET, a_key_m=A_KEY, edge=EDGE,
                                                    date=time.strftime("%F %T")), ensure_ascii=False, indent=1))


# ------------------------------------------------------------------------------------------------ report
def load(out):
    tab = json.loads((Path(out) / "case_table.json").read_text())
    err, el, vt, case = [], [], [], []
    for i, t in enumerate(tab):
        with np.load(Path(out) / "cells" / f"{t['id']}.npz") as z:
            err.append(z["err"].astype(np.float32))
            el.append(z["elift"].astype(np.float32))
            vt.append(z["vt"].astype(np.float32))
            t.update(json.loads(str(z["ax"])))
        case.append(np.full(err[-1].size, i))
    return tab, np.concatenate(err), np.concatenate(el), np.concatenate(vt), np.concatenate(case)


def col(tab, k):
    return np.array([np.nan if t.get(k) is None else t[k] for t in tab], float)


def stat(e, v, el):
    """Строка: клеток, случаев не считаем здесь. Ветер: медиана, p90, доля «ок»; подъём: медиана, p90, доля «ок»."""
    if e.size == 0:
        return dict(n_cells=0)
    ok = e <= np.maximum(OK_MS, OK_REL * v)
    return dict(n_cells=int(e.size), w_med=float(np.median(e)), w_p90=float(np.percentile(e, 90)), w_ok=float(ok.mean()),
                l_med=float(np.median(el)), l_p90=float(np.percentile(el, 90)), l_ok=float((el < OK_LIFT).mean()))


def eta2(g, y):
    """Доля дисперсии y, объяснённая группировкой g (целочисленные метки; -1 — пропуск, не берётся)."""
    m = g >= 0
    g, y = g[m], y[m].astype(np.float64)
    cnt = np.bincount(g).astype(np.float64)
    mean = np.bincount(g, weights=y) / np.maximum(cnt, 1)
    tot = ((y - y.mean()) ** 2).sum()
    return float((cnt * (mean - y.mean()) ** 2).sum() / tot) if tot > 0 else float("nan")


def groups_of(tab):
    """Условие → (метки по случаям или None, названия корзин). Числовые — фиксированные границы; метка -1 — нет значения."""
    G = {}

    def num(name, edges, fmt="{:g}"):
        x = col(tab, name)
        lab = np.full(len(tab), -1)
        m = np.isfinite(x)
        lab[m] = np.clip(np.searchsorted(edges, x[m], side="right") - 1, 0, len(edges) - 2)
        names = [f"[{fmt.format(lo)}; {fmt.format(hi)})" for lo, hi in zip(edges[:-1], edges[1:])]
        G[name] = (lab, names)

    def cat(name, vals=None):
        v = [str(t.get(name)) if t.get(name) is not None else "нет" for t in tab]
        u = vals or sorted(set(v))
        G[name] = (np.array([u.index(x) if x in u else -1 for x in v]), [f"{name}={x}" for x in u])

    num("U10", [0, 3, 5, 7, 9, 12, 40])
    cat("stab", list("ABCDEF"))
    num("heat", [-1e-9, 0.2, 0.4, 0.6, 0.8, 1.01])
    num("t_max", [-50, 10, 18, 24, 30, 60])
    num("H_mean", [-1e9, 50, 100, 150, 200, 1e9])
    num("z_i", [-1e9, 500, 1000, 1500, 2000, 1e9])
    num("hour", [0, 9, 11, 13, 15, 17, 24])
    cat("cap_flag")
    num("cap_agl", [0, 600, 1000, 1500, 1e9])
    num("cross", [0, .25, .5, .75, 1.0001], "{:.2f}")
    num("aniso", [0, .15, .3, .5, 1.0001], "{:.2f}")
    num("slope", [0, .05, .1, .15, .2, 1], "{:.2f}")
    num("relief", [0, 500, 1000, 1500, 2000, 1e9])
    cat("system")
    cat("sky")
    if any("N_bl" in t for t in tab):                  # P3E6: фон (N свободной атмосферы 0,01377 1/с)
        num("N_bl", [0, 0.005, 0.0137, 1], "{:.4f}")
        num("Fr", [0, 0.25, 0.5, 1, 2, 3.01], "{:.2f}")
        num("gam_300", [-1, 0.5, 5, 7, 100], "{:g}")
    return G


def write_csv(path, rows, cols=None):
    cols = cols or list(rows[0].keys())
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols)
        for r in rows:
            w.writerow([f"{r.get(c):.4g}" if isinstance(r.get(c), float) else r.get(c, "") for c in cols])


def md(rows, cols, heads, fmts=None):
    o = ["| " + " | ".join(heads) + " |", "|" + "---|" * len(cols)]
    for r in rows:
        o.append("| " + " | ".join((fmts or {}).get(c, lambda x: f"{x:.3g}" if isinstance(x, float) else str(x))(r.get(c, ""))
                                   for c in cols) + " |")
    return "\n".join(o)


PC = lambda x: f"{100 * x:.0f}" if isinstance(x, float) and np.isfinite(x) else "–"  # noqa: E731
F2 = lambda x: f"{x:.2f}" if isinstance(x, float) and np.isfinite(x) else "–"  # noqa: E731


def report(a):
    out = Path(a.out)
    tab, err, el, vt, case = load(out)
    nc_ = len(tab)
    conv = np.array([t["conv"] for t in tab], bool)
    cnt = np.bincount(case, minlength=nc_)
    S = np.maximum(col(tab, "U10"), 1.0)
    lines, J = [], {}
    # --- общие
    grp = {"conv": conv, "nc": ~conv, "all": np.ones(nc_, bool)}
    gen = []
    for g, m in grp.items():
        cm = m[case]
        r = stat(err[cm], vt[cm], el[cm])
        r.update(group=g, n_cases=int(m.sum()))
        gen.append(r)
    write_csv(out / "overall.csv", gen)
    J["overall"] = gen

    # --- 1. корзины
    G = groups_of(tab)
    brows = []
    for cond, (lab, names) in G.items():
        for gname in ("conv", "nc"):
            for b, nm in enumerate(names):
                mc = (lab == b) & grp[gname]
                if not mc.any():
                    continue
                cm = mc[case]
                r = stat(err[cm], vt[cm], el[cm])
                r.update(cond=cond, bin=nm, group=gname, n_cases=int(mc.sum()))
                brows.append(r)
    write_csv(out / "bins.csv", brows, ["cond", "group", "bin", "n_cases", "n_cells", "w_med", "w_p90", "w_ok", "l_med", "l_p90", "l_ok"])
    J["bins"] = brows

    # --- 2. качество цели
    qrows = []
    ce = np.bincount(case, weights=err, minlength=nc_) / cnt          # средняя ошибка ветра случая
    cl = np.bincount(case, weights=el, minlength=nc_) / cnt
    for gname, m in (("conv", conv), ("nc", ~conv)):
        for q in ("iters", "spread", "t_solve"):
            x = col(tab, q)
            ok = m & np.isfinite(x)
            if ok.sum() < 20 or np.nanstd(x[ok]) == 0:
                continue
            for y, yn in ((ce, "w_mean_err"), (cl, "l_mean_err"), (ce / S, "w_mean_err_over_S")):
                rho = spearmanr(x[ok], y[ok])
                qrows.append(dict(group=gname, quality=q, target=yn, n_cases=int(ok.sum()), spearman=float(rho.statistic),
                                  p=float(rho.pvalue)))
    write_csv(out / "target_quality_corr.csv", qrows)
    J["target_quality_corr"] = qrows
    sp = col(tab, "spread")
    sq = []
    ncm = ~conv & np.isfinite(sp)
    edges = np.quantile(sp[ncm], [0, .25, .5, .75, 1.0]) if ncm.sum() > 8 else []
    for lo, hi in zip(edges[:-1], edges[1:]):
        m = ncm & (sp >= lo) & (sp <= hi if hi == edges[-1] else sp < hi)
        cm = m[case]
        r = stat(err[cm], vt[cm], el[cm])
        r.update(spread_lo=float(lo), spread_hi=float(hi), n_cases=int(m.sum()),
                 err_over_spread_med=float(np.median(ce[m] / np.maximum(sp[m], 1e-3))),
                 spread_med=float(np.median(sp[m])))
        sq.append(r)
    if sq:
        write_csv(out / "nc_spread_quartiles.csv", sq)
    J["nc_spread_quartiles"] = sq
    itr = col(tab, "iters")
    iq = []
    for gname, m in (("conv", conv),):
        ok = m & np.isfinite(itr)
        e_ = np.quantile(itr[ok], [0, .25, .5, .75, 1.0])
        for lo, hi in zip(e_[:-1], e_[1:]):
            mm = ok & (itr >= lo) & (itr <= hi if hi == e_[-1] else itr < hi)
            cm = mm[case]
            r = stat(err[cm], vt[cm], el[cm])
            r.update(group=gname, iters_lo=float(lo), iters_hi=float(hi), n_cases=int(mm.sum()))
            iq.append(r)
    write_csv(out / "conv_iters_quartiles.csv", iq)
    J["conv_iters_quartiles"] = iq

    # --- 3. доля дисперсии
    vrows = []
    for gname in ("conv", "nc"):
        m = grp[gname]
        cm = m[case]
        for cond, (lab, names) in G.items():
            u = np.unique(lab[m & (lab >= 0)])
            if u.size < 2:
                continue
            r = dict(group=gname, cond=cond, n_bins=int(u.size))
            lm = np.where(m, lab, -1)                      # метки случаев группы (остальные — пропуск)
            lc = np.where(cm, lm[case], -1)
            for yn, y in (("w", err), ("w_over_S", err / S[case]), ("lift", el)):
                r[f"R2_cells_{yn}"] = eta2(lc, y)
            r["R2_cases_w"] = eta2(lm, ce)
            r["R2_cases_lift"] = eta2(lm, cl)
            vrows.append(r)
        # численные (непрерывные) условия: Спирмен с ошибкой случая
    # по Спирмену на уровне случаев (знак)
    srows = []
    for gname in ("conv", "nc"):
        m = grp[gname]
        for k in ("U10", "heat", "t_max", "H_mean", "z_i", "hour", "cap_agl", "cross", "aniso", "slope", "relief", "wdir", "sun_el", "N_bl", "Fr", "gam_300"):
            x = col(tab, k)
            ok = m & np.isfinite(x)
            if ok.sum() < 20:
                continue
            srows.append(dict(group=gname, cond=k, n_cases=int(ok.sum()),
                              rho_w=float(spearmanr(x[ok], ce[ok]).statistic), rho_w_over_S=float(spearmanr(x[ok], (ce / S)[ok]).statistic),
                              rho_lift=float(spearmanr(x[ok], cl[ok]).statistic)))
    write_csv(out / "variance_explained.csv", vrows)
    write_csv(out / "spearman_cases.csv", srows)
    J["variance_explained"], J["spearman_cases"] = vrows, srows
    # совместно: линейная регрессия по числовым условиям + one-hot stab на среднюю ошибку случая, R² и R² с отложенной системой
    jrows = []
    num_k = ["U10", "heat", "t_max", "H_mean", "z_i", "hour", "cap_flag", "cap_agl", "cross", "aniso", "slope", "relief"]
    sysn = np.array([t["system"] for t in tab])
    for gname in ("conv", "nc"):
        m = grp[gname]
        Xc = np.stack([np.nan_to_num(col(tab, k), nan=0.0) for k in num_k], 1)
        Xc = np.hstack([Xc, np.stack([[t["stab"] == s for t in tab] for s in "ABCDEF"], 1).astype(float)])
        mu, sd = Xc[m].mean(0), Xc[m].std(0) + 1e-9
        Z = np.hstack([(Xc - mu) / sd, np.ones((nc_, 1))])
        # квадратичные признаки по U10
        for yn, y in (("w_mean_err", ce), ("w_mean_err_over_S", ce / S), ("l_mean_err", cl)):
            ym = y[m]
            beta = np.linalg.lstsq(Z[m], ym, rcond=1e-6)[0]
            r2 = 1 - ((ym - Z[m] @ beta) ** 2).sum() / ((ym - ym.mean()) ** 2).sum()
            pred = np.zeros(m.sum())
            ids_m = np.flatnonzero(m)
            for s in np.unique(sysn[m]):
                te = sysn[ids_m] == s
                b = np.linalg.lstsq(Z[ids_m][~te], ym[~te], rcond=1e-6)[0]
                pred[te] = Z[ids_m][te] @ b
            r2cv = 1 - ((ym - pred) ** 2).sum() / ((ym - ym.mean()) ** 2).sum()
            jrows.append(dict(group=gname, target=yn, n_cases=int(m.sum()), n_feat=len(num_k) + 6, R2_fit=float(r2),
                              R2_leave_system_out=float(r2cv)))
    write_csv(out / "joint_linear.csv", jrows)
    J["joint_linear"] = jrows

    # --- 4. между случаями / внутри случая
    brow = []
    for gname in ("conv", "nc", "all"):
        m = grp[gname]
        cm = m[case]
        for yn, y in (("w", err), ("w_over_S", err / S[case]), ("lift", el)):
            yy = y[cm].astype(np.float64)
            cs = (np.bincount(case[cm], weights=yy, minlength=nc_)[m] / cnt[m])
            c_cell = np.repeat(cs, cnt[m])
            tot = ((yy - yy.mean()) ** 2).sum()
            brow.append(dict(group=gname, y=yn, between=float(((c_cell - yy.mean()) ** 2).sum() / tot),
                             within=float(((yy - c_cell) ** 2).sum() / tot)))
    write_csv(out / "between_within.csv", brow)
    J["between_within"] = brow
    # хвост: топ-10 % случаев по средней ошибке
    trows, comp = [], []
    for gname in ("conv", "nc", "all"):
        m = grp[gname]
        cm = m[case]
        idx = np.flatnonzero(m)
        nt = max(1, int(round(0.1 * idx.size)))
        for yn, y, yc in (("w", err, ce), ("w_over_S", err / S[case], ce / S), ("lift", el, cl)):
            top = idx[np.argsort(-yc[idx])[:nt]]
            tm = np.zeros(nc_, bool)
            tm[top] = True
            thr = np.percentile(y[cm], 90)
            tail = cm & (y > thr)
            share_cells = float((tail & tm[case]).sum() / tail.sum())
            sq = float((y[tail & tm[case]].astype(np.float64) ** 2).sum() / (y[tail].astype(np.float64) ** 2).sum())
            sq_all = float((y[cm & tm[case]].astype(np.float64) ** 2).sum() / (y[cm].astype(np.float64) ** 2).sum())
            # доля хвостовых клеток, лежащих в случаях, где хвост — большинство клеток
            frac_in_case = np.bincount(case[tail], minlength=nc_) / cnt
            conc = float(np.sort(frac_in_case[m])[::-1][:nt].sum() / max(frac_in_case[m].sum(), 1e-9))
            trows.append(dict(group=gname, y=yn, n_cases=int(idx.size), n_top=nt, p90_thr=float(thr),
                              tail_cells_in_top10pct_cases=share_cells, sumsq_all_in_top10pct_cases=sq_all,
                              sumsq_tail_in_top10pct_cases=sq, tail_in_top10pct_by_tailfrac=conc,
                              top_mean_err=float(yc[top].mean()), rest_mean_err=float(yc[idx[~np.isin(idx, top)]].mean())))
            if yn in ("w", "w_over_S"):
                comp.append((gname + ("" if yn == "w" else "/S"), tm, m))
    write_csv(out / "tail_share.csv", trows)
    J["tail_share"] = trows
    # чем отличаются худшие 10 % от остальных (по условиям), группы conv / nc / all
    drows = []
    keys = ["U10", "heat", "t_max", "H_mean", "z_i", "hour", "cap_flag", "cap_agl", "cross", "aniso", "slope", "relief",
            "wdir", "spread", "iters"]
    for gname, tm, m in comp:
        for k in keys:
            x = col(tab, k)
            a1, a0 = x[tm & m], x[~tm & m]
            a1, a0 = a1[np.isfinite(a1)], a0[np.isfinite(a0)]
            if a1.size < 3 or a0.size < 3:
                continue
            sdp = np.sqrt((a1.var() + a0.var()) / 2) + 1e-12
            drows.append(dict(group=gname, cond=k, top_med=float(np.median(a1)), rest_med=float(np.median(a0)),
                              top_mean=float(a1.mean()), rest_mean=float(a0.mean()), d_std=float((a1.mean() - a0.mean()) / sdp)))
        for k in ("stab", "system", "sky"):
            for v in sorted({t.get(k) for t in tab if t.get(k) is not None}, key=str):
                x = np.array([t.get(k) == v for t in tab], float)
                if (tm & m & (x > 0)).sum() == 0 and k == "system":
                    continue
                drows.append(dict(group=gname, cond=f"{k}={v}", top_med=float(x[tm & m].mean()), rest_med=float(x[~tm & m].mean()),
                                  top_mean=float(x[tm & m].mean()), rest_mean=float(x[~tm & m].mean()),
                                  d_std=float("nan")))
        drows.append(dict(group=gname, cond="share_nonconverged", top_mean=float((~conv)[tm & m].mean()),
                          rest_mean=float((~conv)[~tm & m].mean())))
    write_csv(out / "top10_vs_rest.csv", drows, ["group", "cond", "top_med", "rest_med", "top_mean", "rest_mean", "d_std"])
    J["top10_vs_rest"] = drows
    # лист случаев
    cr = []
    for i, t in enumerate(tab):
        cr.append(dict(id=t["id"], system=t["system"], conv=t["conv"], U10=t["U10"], stab=t["stab"], mean_err=float(ce[i]),
                       p90_err=float(np.percentile(err[case == i], 90)), mean_lift_err=float(cl[i]),
                       spread=t.get("spread"), iters=t.get("iters")))
    write_csv(out / "cases.csv", cr)
    (out / "results.json").write_text(json.dumps(J, ensure_ascii=False, indent=1, default=float))
    summary(out, tab, J, gen, a)


def summary(out, tab, J, gen, a):
    src = json.loads((out / "source.json").read_text())
    L = ["---", 'type: "research"', 'status: "active"', 'module: "air-nn"', f'updated: "{time.strftime("%F")}"',
         'summary: "Откуда хвосты ошибки сети: условия случая, шум целей решателя или ёмкость — разбивка ошибки на 60 м по условиям (г), доля дисперсии, межслучайная и внутрислучайная части, худшие 10 % случаев."',
         "related: []", "---", "", f"# Ошибка сети по условиям случая ({Path(src['run']).name})", "",
         f"Сгенерировано `p3/cond_eval.py report`; модель `{src['onnx']}`, набор `{src['set']}`, высота {src['a_key_m']:g} м, "
         f"клетки области без {src['edge']} клеток у края. Таблицы — csv рядом; кеш клеток — `{out}/cells/` (локально). "
         "Ошибка ветра — |Δ(u,v)| с нагревом, «ок» ≤ max(0,3 м/с; 10 % |V решателя|); подъём — |Δw| с нагревом, «ок» < 0,1 м/с. "
         "Невязка решения в конце в наборах не хранится — качество цели: статус, число итераций, `late_spread60_p90` (только у несошедшихся).", ""]
    nf = out / "notes.md"
    if nf.exists():                                   # выводы, написанные руками по таблицам ниже
        L += [nf.read_text().rstrip(), ""]
    L += ["## Общие", "", md(gen, ["group", "n_cases", "n_cells", "w_med", "w_p90", "w_ok", "l_med", "l_p90", "l_ok"],
                              ["группа", "случаев", "клеток", "ветер мед.", "ветер p90", "ветер ок", "w мед.", "w p90", "w ок"],
                              dict(w_ok=PC, l_ok=PC)), ""]
    L += ["## Доля дисперсии, объяснённая условием (R² по корзинам)", "",
          "R² по клеткам — корзины условия на случай, дисперсия по клеткам (как NN-P11); R² по случаям — дисперсия средней "
          "ошибки случая. ε/S — ошибка в единицах S = max(U10; 1).", ""]
    for g in ("conv", "nc"):
        v = sorted([r for r in J["variance_explained"] if r["group"] == g], key=lambda r: -r["R2_cases_w"])
        L += [f"**{g}**", "", md(v, ["cond", "n_bins", "R2_cells_w", "R2_cells_w_over_S", "R2_cells_lift", "R2_cases_w", "R2_cases_lift"],
                                ["условие", "корзин", "R² кл. ε", "R² кл. ε/S", "R² кл. w", "R² сл. ε", "R² сл. w"],
                                {k: PC for k in ("R2_cells_w", "R2_cells_w_over_S", "R2_cells_lift", "R2_cases_w", "R2_cases_lift")} | {}), ""]
    L += ["R² в процентах. **Совместно** (линейно по всем условиям, средняя ошибка случая):", "",
          md(J["joint_linear"], ["group", "target", "n_cases", "R2_fit", "R2_leave_system_out"],
             ["группа", "цель", "случаев", "R² подгонка", "R² без системы"], dict(R2_fit=F2, R2_leave_system_out=F2)), ""]
    L += ["## Между случаями и внутри случая", "", md(J["between_within"], ["group", "y", "between", "within"],
                                                    ["группа", "величина", "между", "внутри"], dict(between=F2, within=F2)), "",
          "## Худшие 10 % случаев и p90-хвост", "",
          md(J["tail_share"], ["group", "y", "n_top", "p90_thr", "tail_cells_in_top10pct_cases", "sumsq_all_in_top10pct_cases",
                               "sumsq_tail_in_top10pct_cases", "top_mean_err", "rest_mean_err"],
             ["группа", "вел.", "топ случаев", "порог p90", "доля хвостовых клеток в топ-10 %", "доля Σε² в топ-10 %",
              "доля Σε² хвоста в топ-10 %", "ср. ошибка топа", "ср. ошибка остальных"],
             dict(tail_cells_in_top10pct_cases=F2, sumsq_all_in_top10pct_cases=F2, sumsq_tail_in_top10pct_cases=F2)), "",
          "Топ-10 % против остальных по условиям — `top10_vs_rest.csv`; по группам:", ""]
    for g in ("all", "all/S"):
        d = [r for r in J["top10_vs_rest"] if r["group"] == g]
        L += [f"Группа `{g}` (`/S` — худшие 10 % по ошибке в единицах S = max(U10; 1), без амплитуды ветра):", "", md(d, ["cond", "top_med", "rest_med", "top_mean", "rest_mean", "d_std"],
                 ["условие", "топ мед.", "остальные мед.", "топ ср.", "остальные ср.", "d (в σ)"]), ""]
    L += ["## Качество цели", "", "Связь Спирмена признака качества цели с ошибкой случая:", "",
          md(J["target_quality_corr"], ["group", "quality", "target", "n_cases", "spearman", "p"],
             ["группа", "признак", "ошибка", "случаев", "ρ", "p"]), ""]
    if J["nc_spread_quartiles"]:
        L += ["Несошедшиеся по квартилям `late_spread60_p90`:", "",
              md(J["nc_spread_quartiles"], ["spread_lo", "spread_hi", "n_cases", "spread_med", "w_med", "w_p90", "w_ok",
                                           "err_over_spread_med"],
                 ["спред от", "до", "случаев", "спред мед.", "ветер мед.", "ветер p90", "ок", "ошибка / спред"], dict(w_ok=PC)), ""]
    L += ["Сошедшиеся по квартилям числа итераций:", "",
          md(J["conv_iters_quartiles"], ["iters_lo", "iters_hi", "n_cases", "w_med", "w_p90", "w_ok", "l_ok"],
             ["итераций от", "до", "случаев", "ветер мед.", "ветер p90", "ок", "w ок"], dict(w_ok=PC, l_ok=PC)), ""]
    L += ["## Корзины", "", "Полные таблицы — `bins.csv` (условие × группа × корзина: медиана, p90, доля «ок» для ветра и подъёма).", ""]
    for cond in ("U10", "stab", "heat", "z_i", "hour", "cap_flag", "cross", "system"):
        for g in ("conv", "nc"):
            d = [r for r in J["bins"] if r["cond"] == cond and r["group"] == g]
            if not d:
                continue
            if cond == "system" and len(d) > 12:
                d = sorted(d, key=lambda r: -r["w_med"])
            L += [f"**{cond}, {g}**", "", md(d, ["bin", "n_cases", "w_med", "w_p90", "w_ok", "l_med", "l_ok"],
                                           ["корзина", "случаев", "ветер мед.", "ветер p90", "ок", "w мед.", "w ок"], dict(w_ok=PC, l_ok=PC)), ""]
    (out / "summary.md").write_text("\n".join(L) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stage", choices=["predict", "report", "all"])
    ap.add_argument("--run", default=str(DATA / "pilot/runs/2026-10-03_p2b"))
    ap.add_argument("--onnx", default=None)
    ap.add_argument("--out", default=str(HERE / "p3/out/cond_p2b"))
    ap.add_argument("--procs", type=int, default=int(os.environ.get("COND_PROCS", "8")))
    ap.add_argument("--film-bg", default=None, help="P3E6: film_bg.npz — условия фона в таблицы")
    ap.add_argument("--bg-input", action="store_true", help="P3E6: числа фона — и во вход сети (сеть P3E6)")
    a = ap.parse_args()
    if a.stage in ("predict", "all"):
        predict(a)
    if a.stage in ("report", "all"):
        report(a)


if __name__ == "__main__":
    main()
