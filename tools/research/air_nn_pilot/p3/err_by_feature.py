#!/usr/bin/env python3
"""П3-В (NN-P11): где сидят ошибки сети П-2 — ошибка ветра на 60 м по клеткам области (без 5 клеток у края) против признаков
рельефа и карт входа v5: V̂·∇h (400 м, 1,2, 3,2, 8 км), крутизна, подсеточные доли круче порога, маски отрыва и след,
кривизна (знаки по осям — седловины), устойчивость. Сеть — `runs/2026-10-03_p2b/main/model.onnx` через ORT на CPU
(вход — кеш подготовки П-2), цель — решатель (`d400_*` образца), группа — сошедшиеся по `h` (`data.case_groups`).

  collect — клетки → $AIR_NN_DATA/pilot/p3/NN-P11/cells_<набор>.npz   (под `dp lock cpu`)
  report  — таблицы → p3/err_by_feature.md и p3/err_by_feature.json

  cd tools/research/air_nn_pilot
  /home/greg/deltaplan/tools/dp lock cpu .venv/bin/python p3/err_by_feature.py collect
  .venv/bin/python p3/err_by_feature.py report
"""
from __future__ import annotations

import json
import math
import multiprocessing as mp
import os
import sys
import time
from pathlib import Path

import numpy as np
from scipy import ndimage

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import maps5 as M  # noqa: E402
from pilotnn import prep as P  # noqa: E402
from pilotnn.data import Datasets, case_groups  # noqa: E402

DATA = Path(os.environ.get("AIR_NN_DATA") or "/home/greg/air_nn_data")
RUN = DATA / "pilot/runs/2026-10-03_p2b"
OUT = DATA / "pilot/p3/NN-P11"
EDGE, A_KEY, N_TRAIN, SEED = 5, 60.0, 600, 0          # как config.yaml → eval (edge_cells, agl_key_m); обучение — подвыборка
WIND_OK_MS, WIND_OK_REL = 0.3, 0.1
CURV_DEAD = 1e-4                                       # мёртвая зона знака кривизны, 1/м (≈ 1,6 м перепада на 400 м)
CURV_SIGMA_M = 600.0
# сетки: (имя, шаг и значения варианта)
SWEEP_STEEP = (0.2, 0.45)
SWEEP_KW = (3.5, 14.0)
SWEEP_THR = (0.2, 0.4)
FEATS = (["sa400", "sa1k2", "sa3k2", "sa8k", "steep400", "steep1k2", "sub_p95", "sub_std", "sub_relief", "sub_lee",
          "sub_wind", "sep400", "sep1k2", "sep3k2", "wake", "curv_al", "curv_cr"]
         + [f"sub_lee_{t}" for t in SWEEP_STEEP] + [f"wake_k{k}" for k in SWEEP_KW]
         + [f"sep400_t{t}" for t in SWEEP_THR] + [f"wake_t{t}" for t in SWEEP_THR])
SUB_FEATS = {"sub_p95", "sub_std", "sub_relief", "sub_lee", "sub_wind"} | {f for f in FEATS if f.startswith("sub_lee_")}


def level_weights(agl, a_key):
    agl = list(agl)
    for i in range(len(agl) - 1):
        if agl[i] <= a_key <= agl[i + 1]:
            t = (a_key - agl[i]) / (agl[i + 1] - agl[i])
            return i, 1 - t, t
    raise ValueError(a_key)


def at_level(F, lw):
    i, w0, w1 = lw
    return w0 * F[..., i, :, :] + w1 * F[..., i + 1, :, :]


def case_file(dirs, cid):
    for d in dirs:
        p = Path(d) / "cases" / f"{cid}.npz"
        if p.exists():
            return p
    raise FileNotFoundError(cid)


def curvature(hr, r, dx=400.0):
    """Кривизна (∂²/∂s² вдоль ветра, ∂²/∂n² поперёк) рельефа, сглаженного σ = 600 м, 1/м."""
    g = ndimage.gaussian_filter(hr, CURV_SIGMA_M / dx, mode="nearest")
    gy, gx = np.gradient(g, dx)
    gyy, gyx = np.gradient(gy, dx)
    gxy, gxx = np.gradient(gx, dx)
    hxy = 0.5 * (gxy + gyx)
    c, s = math.cos(r), math.sin(r)
    return gxx * c * c + 2 * hxy * c * s + gyy * s * s, gxx * s * s - 2 * hxy * c * s + gyy * c * c


# ------------------------------------------------------------------------------------------------ worker
_W = {}


def _init(dirs):
    import onnxruntime as ort
    so = ort.SessionOptions()
    so.intra_op_num_threads = 1
    so.inter_op_num_threads = 1
    _W["sess"] = ort.InferenceSession(str(RUN / "main/model.onnx"), so, providers=["CPUExecutionProvider"])
    _W["dirs"] = dirs
    _W["tile"] = (None, None)


def _tile(loc):
    if _W["tile"][0] != loc:
        _W["tile"] = (loc, M.load_tile(loc))
    return _W["tile"][1]


def work(job):
    cid, row, root = job
    with np.load(case_file(_W["dirs"], cid)) as zc:
        X, F, meta = zc["X"], zc["F"], json.loads(str(zc["meta"]))
    Yp = _W["sess"].run(None, dict(maps=X[None], nums=F[None]))[0][0]
    pred = P.to_physical(Yp, meta, P.AGL)
    with np.load(root / "cases" / f"{cid}.npz") as zz:
        z = {k: zz[k] for k in zz.files if k.startswith("d400")}
    lw = level_weights(P.AGL, A_KEY)
    th, ph = at_level(z["d400_h"].astype(np.float64), lw), at_level(pred["h"], lw)
    err = np.hypot(ph[0] - th[0], ph[1] - th[1])
    elift = np.abs(ph[2] - th[2])
    vt = np.hypot(th[0], th[1])
    k, r = meta["k"], meta["r"]
    e = EDGE
    s = (slice(e, -e or None),) * 2
    R = lambda a: np.ascontiguousarray(P.rot_scalar(a, k))[s]  # noqa: E731    в повёрнутую систему, область без края
    tile = _tile(row["loc"])
    has_tile = tile is not None
    Xv = M.maps_v5(z, meta, row, tile=tile)
    nm = M.MAP_NAMES_V5
    ix = {n: i for i, n in enumerate(nm)}
    f = {}
    hr = np.ascontiguousarray(P.rot_scalar(z["d400_hc"].astype(np.float64), k))
    S = lambda n, c=1.0: (Xv[ix[n]] * c)[s]  # noqa: E731
    f["sa400"], f["sa1k2"], f["sa3k2"], f["sa8k"] = (S("slope_along", .3), S("slope_along_1k2", .3), S("slope_along_3k2", .3),
                                                     S("slope_along_8k", .3))
    f["steep400"] = np.hypot(S("slope_along", .3), S("slope_cross", .3))
    f["steep1k2"] = np.hypot(S("slope_along_1k2", .3), S("slope_cross_1k2", .3))
    f["sub_p95"], f["sub_std"], f["sub_relief"] = S("sub_slope_p95", .6), S("sub_slope_std", .3), S("sub_relief", 300.)
    f["sub_lee"], f["sub_wind"] = S("sub_steep_lee"), S("sub_steep_wind")
    f["sep400"], f["sep1k2"], f["sep3k2"], f["wake"] = S("sep_400"), S("sep_1k2"), S("sep_3k2"), S("sep_wake")
    f["curv_al"], f["curv_cr"] = [a[s] for a in curvature(hr, r)]
    for t in SWEEP_STEEP:
        f[f"sub_lee_{t}"] = M.sub_maps(z["d400_hc"], k, r, tile, steep=t)[2][s]
    sep0 = M.sep_of(P.slopes(hr, r)[0])
    for kw in SWEEP_KW:
        f[f"wake_k{kw}"] = M.sep_wake(hr, r, sep0, kw=kw)[s]
    for t in SWEEP_THR:
        st = M.sep_of(P.slopes(hr, r)[0], t)
        f[f"sep400_t{t}"] = st[s]
        f[f"wake_t{t}"] = M.sep_wake(hr, r, st)[s]
    gr = case_groups(row)
    n = err[s].size
    return dict(cid=cid, loc=row["loc"], U10=float(row["U10"]), stab=str(row["profile"].get("stab", "D")), has_tile=has_tile,
                gh=gr["gh"], err=R(err).ravel().astype(np.float16), elift=R(elift).ravel().astype(np.float16),
                vt=R(vt).ravel().astype(np.float16), n=n,
                feat=np.stack([f[x].ravel() for x in FEATS]).astype(np.float16))


def collect():
    info = json.loads((RUN / "run_info.json").read_text())
    split = json.loads((RUN / "split.json").read_text())
    dss = Datasets([(d["name"], d["root"]) for d in info["datasets"]])
    rows = {r["id"]: r for r in dss.case_rows()}
    roots = {cid: dss.ds_of(cid).root for cid in rows}
    rng = np.random.default_rng(SEED)
    tr = sorted(rng.choice(split["train_ids"], N_TRAIN, replace=False).tolist())
    sets = {"holdout_sys": sorted(split["holdout_sys_ids"]), "train": tr}
    OUT.mkdir(parents=True, exist_ok=True)
    dirs = info["prep_dirs"]
    nproc = int(os.environ.get("NN_P11_PROCS", "5"))
    for name, ids in sets.items():
        ids = sorted(ids, key=lambda c: (rows[c]["loc"], c))       # подряд по месту — кеш тайла
        t0 = time.time()
        res = []
        with mp.Pool(nproc, _init, (dirs,)) as pool:
            for i, r in enumerate(pool.imap(work, [(c, rows[c], roots[c]) for c in ids], chunksize=4)):
                res.append(r)
                if i % 100 == 0:
                    print(f"{name}: {i}/{len(ids)}  {time.time() - t0:.0f} с", flush=True)
        np.savez_compressed(
            OUT / f"cells_{name}.npz", cid=np.array([r["cid"] for r in res]), loc=np.array([r["loc"] for r in res]),
            U10=np.array([r["U10"] for r in res]), stab=np.array([r["stab"] for r in res]),
            has_tile=np.array([r["has_tile"] for r in res]), gh=np.array([r["gh"] for r in res]),
            n=np.array([r["n"] for r in res]), feats=np.array(FEATS),
            err=np.concatenate([r["err"] for r in res]), elift=np.concatenate([r["elift"] for r in res]),
            vt=np.concatenate([r["vt"] for r in res]), feat=np.concatenate([r["feat"] for r in res], axis=1))
        print(f"{name}: готово, {len(res)} случаев, {time.time() - t0:.0f} с", flush=True)


# ------------------------------------------------------------------------------------------------ report
BINS = dict(
    sa400=[-9, -.3, -.15, -.05, .05, .15, .3, 9], sa1k2=[-9, -.3, -.15, -.05, .05, .15, .3, 9],
    sa3k2=[-9, -.2, -.1, -.03, .03, .1, .2, 9], sa8k=[-9, -.1, -.05, -.02, .02, .05, .1, 9],
    steep400=[0, .05, .1, .2, .3, .45, 9], steep1k2=[0, .05, .1, .2, .3, 9], sub_p95=[0, .1, .2, .3, .5, .8, 99],
    sub_relief=[0, .1, .2, .4, .7, 1.2, 99], sub_lee=[-1, 0, .02, .1, .3, 1.01], sub_wind=[-1, 0, .02, .1, .3, 1.01],
    sep400=[-1, .01, .1, .5, .9, 1.1], sep1k2=[-1, .01, .1, .5, .9, 1.1], sep3k2=[-1, .01, .1, .5, .9, 1.1],
    wake=[-1, .01, .1, .3, .6, 1.1])
SHOW = ("sa400", "sa1k2", "sa3k2", "sa8k", "steep400", "steep1k2", "sub_lee", "sub_wind", "sub_p95", "sub_relief",
        "sep400", "sep1k2", "sep3k2", "wake")
NAMES = dict(
    sa400="V̂·∇h, 400 м (+ наветренный склон)", sa1k2="V̂·∇h, σ 600 м (1,2 км)", sa3k2="V̂·∇h, σ 1600 м (3,2 км)",
    sa8k="V̂·∇h, σ 4000 м (8 км)", steep400="крутизна ‖∇h‖, 400 м", steep1k2="крутизна ‖∇h‖, σ 600 м",
    sub_lee="sub_steep_lee (доля подклеток круче 0,3 вниз по ветру)", sub_wind="sub_steep_wind (доля круче 0,3 вверх по ветру)",
    sub_p95="sub_slope_p95 (p95 ‖∇h₂₅‖)", sub_relief="sub_relief (перепад в клетке, м/300)",
    sep400="sep_400", sep1k2="sep_1k2", sep3k2="sep_3k2", wake="sep_wake")


def load_set(name):
    z = np.load(OUT / f"cells_{name}.npz")
    n = z["n"]
    case = np.repeat(np.arange(len(n)), n)
    return dict(z=z, case=case, err=z["err"].astype(np.float32), elift=z["elift"].astype(np.float32),
                vt=z["vt"].astype(np.float32), feat={f: z["feat"][i].astype(np.float32) for i, f in enumerate(z["feats"])},
                tile=np.repeat(z["has_tile"], n), conv=np.repeat(z["gh"] == "conv", n), U10=np.repeat(z["U10"], n),
                stab=np.repeat(z["stab"], n), S=np.repeat(np.maximum(z["U10"], 1.0), n).astype(np.float32))


def r2_binned(x, y, nb=10):
    """Доля дисперсии ошибки, объяснённая корзинами признака (по квантилям, ≤ 10 корзин, повторы схлопнуты)."""
    q = np.unique(np.quantile(x, np.linspace(0, 1, nb + 1)[1:-1]))
    b = np.searchsorted(q, x, side="right")
    cnt = np.bincount(b).astype(np.float64)
    mean = np.bincount(b, weights=y) / np.maximum(cnt, 1)
    tot = ((y - y.mean()) ** 2).sum()
    return float(((cnt * (mean - y.mean()) ** 2).sum()) / tot) if tot > 0 else float("nan")


def stats(err, vt, S=None):
    ok = err <= np.maximum(WIND_OK_MS, WIND_OK_REL * vt)
    return dict(n=int(err.size), median=float(np.median(err)), p90=float(np.percentile(err, 90)), mean=float(err.mean()),
                sq=float((err.astype(np.float64) ** 2).sum()), bad=float(1 - ok.mean()),
                med_n=float(np.median(err / S)) if S is not None else float('nan'))


def bin_table(d, mask, f, edges):
    x, e, v, Sx = d["feat"][f][mask], d["err"][mask], d["vt"][mask], d["S"][mask]
    tot_sq = float((e.astype(np.float64) ** 2).sum())
    rows = []
    for lo, hi in zip(edges[:-1], edges[1:]):
        m = (x > lo) & (x <= hi)
        if not m.any():
            rows.append(dict(lo=lo, hi=hi, n=0))
            continue
        s = stats(e[m], v[m], Sx[m])
        s.update(lo=lo, hi=hi, share_cells=float(m.mean()), share_sq=s["sq"] / tot_sq)
        rows.append(s)
    return rows


def lab(lo, hi):
    if lo <= -1e8:
        return f"≤ {hi:g}"
    if hi >= 1e8 or hi >= 99:
        return f"> {lo:g}"
    return f"({lo:g}; {hi:g}]"


def md_table(rows, med_all):
    out = ["| корзина | клеток, % | медиана, м/с | p90, м/с | медиана ε/S | ε/S к общей | «не ок», % | доля Σε², % |", "|---|---|---|---|---|---|---|---|"]
    for r in rows:
        if r["n"] == 0:
            out.append(f"| {lab(r['lo'], r['hi'])} | 0 | – | – | – | – | – | – |")
            continue
        out.append(f"| {lab(r['lo'], r['hi'])} | {100 * r['share_cells']:.1f} | {r['median']:.2f} | {r['p90']:.2f} | "
                   f"{r['med_n']:.3f} | {r['med_n'] / med_all:.2f} | {100 * r['bad']:.0f} | {100 * r['share_sq']:.1f} |")
    return "\n".join(out)


def report():
    from scipy.stats import spearmanr
    res, lines = {}, []
    notes = HERE / "p3" / "err_by_feature_notes.md"
    if notes.exists():
        lines.append(notes.read_text().rstrip() + "\n")
    lines.append("## Таблицы (генерируются `p3/err_by_feature.py report`; числа — `p3/err_by_feature.json`)\n")
    lines.append("Ошибка — |Δ(u, v)| сети П-2 против решателя, с нагревом, на 60 м, клетки области без 5 клеток у края, только "
                 "сошедшиеся по `h`. «Не ок» — ошибка > max(0,3 м/с; 0,1·|V решателя|). «Доля Σε²» — вклад корзины в сумму "
                 "квадратов ошибки набора. Подсеточные признаки (`sub_*`) — только случаи с рельефом 25 м.\n")
    for name, title in (("holdout_sys", "(г) отложенные горные системы"), ("train", "обучающие (подвыборка)")):
        d = load_set(name)
        z = d["z"]
        nc_cases = int((z["gh"] != "conv").sum())
        n_cases = len(z["n"])
        n_notile = int((~z["has_tile"]).sum())
        base = d["conv"]
        lines.append(f"### {title}\n")
        lines.append(f"Случаев: {n_cases}, сошедшихся по `h`: {n_cases - nc_cases} (несошедшихся {nc_cases} — вне таблиц). "
                     f"без рельефа 25 м: {n_notile} случаев из {n_cases} (подстановка — билинейная `d400_hc`; их клетки "
                     f"исключены из таблиц `sub_*`, остальные таблицы — все).\n")
        st = stats(d["err"][base], d["vt"][base])
        med_all = st["median"]
        res[name] = dict(n_cases=n_cases, n_nonconv=nc_cases, n_no_tile=n_notile, overall=st, features={})
        lines.append(f"Общая: клеток {st['n']}, медиана {st['median']:.2f}, p90 {st['p90']:.2f}, среднее {st['mean']:.2f} м/с, "
                     f"«не ок» {100 * st['bad']:.0f} %.\n")
        # ранг признаков: R² корзин (ε, ε/S, ε/S внутри случая) и Спирмен
        en = d["err"] / d["S"]
        cs = np.bincount(d["case"], weights=en, minlength=n_cases) / np.maximum(np.bincount(d["case"], minlength=n_cases), 1)
        an = en - cs[d["case"]]
        tot = ((en[base] - en[base].mean()) ** 2).sum()
        icc = float(((cs[d["case"]][base] - en[base].mean()) ** 2).sum() / tot)
        res[name]["between_case_share_of_var_eps_over_S"] = icc
        rk = []
        for f in FEATS:
            m = base & (d["tile"] if f in SUB_FEATS else True)
            if m.sum() < 1000:
                continue
            idx = np.flatnonzero(m)
            sub = np.random.default_rng(1).choice(idx, min(len(idx), 400000), replace=False)
            rho = float(spearmanr(d["feat"][f][sub], en[sub]).statistic)
            rk.append((f, r2_binned(d["feat"][f][m], d["err"][m]), r2_binned(d["feat"][f][m], en[m]),
                       r2_binned(d["feat"][f][m], an[m]), rho, int(m.sum())))
        res[name]["rank"] = [dict(feat=f, r2_err=a, r2_eps_over_S=b, r2_within_case=c, spearman_eps_over_S=r, n=n)
                             for f, a, b, c, r, n in rk]
        lines.append("ε/S — ошибка в единицах S = max(U10; 1 м/с) (убирает разброс по силе ветра). Доля дисперсии ε/S между "
                     f"случаями (одно число на случай): **{100 * icc:.0f} %**; остальное — внутри поля случая.\n")
        lines.append("**Связь с признаками**: R² — доля дисперсии, объяснённая 10 квантильными корзинами признака, для ε (м/с), "
                     "ε/S и ε/S за вычетом среднего по случаю («внутри случая» — то, что карты могут объяснить в поле); ρ — "
                     "Спирмен ε/S–признак. Строки с суффиксом (`_0.2`, `_k3.5`, `_t0.4`…) — варианты констант (порог крутизны подклетки, k_w, порог отрыва):\n")
        lines.append("| признак | R² ε | R² ε/S | R² внутри случая | ρ | клеток |\n|---|---|---|---|---|---|")
        for f, a, b, c, r_, n in sorted(rk, key=lambda t: -t[3]):
            lines.append(f"| {f} | {a:.3f} | {b:.3f} | {c:.3f} | {r_:+.2f} | {n} |")
        lines.append("")
        for f in SHOW:
            m = base & (d["tile"] if f in SUB_FEATS else True)
            if m.sum() < 1000:
                continue
            rows = bin_table(d, m, f, BINS[f])
            res[name]["features"][f] = rows
            med_f = float(np.median(d["err"][m] / d["S"][m]))
            lines.append(f"#### {NAMES[f]}\n")
            lines.append(md_table(rows, med_f))
            lines.append("")
        # кривизна: знаки по осям, мёртвая зона
        ca, cc = d["feat"]["curv_al"][base], d["feat"]["curv_cr"][base]
        e, v, Sb = d["err"][base], d["vt"][base], d["S"][base]
        sg = lambda c: np.where(c > CURV_DEAD, 1, np.where(c < -CURV_DEAD, -1, 0))  # noqa: E731
        sa_, sc_ = sg(ca), sg(cc)
        names = {-1: "выпукло вверх (гребень, ∂²h < 0)", 0: "≈ плоско", 1: "вогнуто (лощина, ∂²h > 0)"}
        lines.append(f"#### Кривизна (σ = {CURV_SIGMA_M:g} м; мёртвая зона ±{CURV_DEAD:g} 1/м): вдоль ветра × поперёк\n")
        lines.append("| вдоль ветра | поперёк | тип | клеток, % | медиана, м/с | p90, м/с | медиана / общая | «не ок», % | доля Σε², % |\n"
                     "|---|---|---|---|---|---|---|---|---|")
        tot_sq = float((e.astype(np.float64) ** 2).sum())
        crv = []
        typ = {(-1, -1): "вершина", (1, 1): "котловина", (-1, 1): "седловина (вдоль выпукло, поперёк вогнуто)",
               (1, -1): "седловина (вдоль вогнуто, поперёк выпукло)"}
        for a in (-1, 0, 1):
            for b in (-1, 0, 1):
                m = (sa_ == a) & (sc_ == b)
                if m.sum() < 50:
                    continue
                s = stats(e[m], v[m], Sb[m])
                s.update(a=a, b=b, share_cells=float(m.mean()), share_sq=s["sq"] / tot_sq)
                crv.append(s)
                lines.append(f"| {names[a]} | {names[b]} | {typ.get((a, b), '')} | {100 * s['share_cells']:.1f} | {s['median']:.2f} | "
                             f"{s['p90']:.2f} | {s['median'] / med_all:.2f} | {100 * s['bad']:.0f} | {100 * s['share_sq']:.1f} |")
        res[name]["curvature"] = crv
        lines.append("")
        # устойчивость и U10
        lines.append("#### Класс устойчивости профиля притока (`stab`) и U10 (Fr: N в наборах нет — стратификация задана классом)\n")
        lines.append("| группа | клеток, % | медиана, м/с | p90, м/с | «не ок», % |\n|---|---|---|---|---|")
        for lbl, m in ([(f"stab {c}", base & (d["stab"] == c)) for c in sorted(set(d["stab"].tolist()))]
                       + [(f"U10 {a}–{b}", base & (d["U10"] >= a) & (d["U10"] < b)) for a, b in ((0, 2), (2, 4), (4, 6), (6, 99))]):
            if m.sum() < 500:
                continue
            s = stats(d["err"][m], d["vt"][m])
            lines.append(f"| {lbl} | {100 * m.sum() / base.sum():.1f} | {s['median']:.2f} | {s['p90']:.2f} | {100 * s['bad']:.0f} |")
        lines.append("")
        # подъём
        lines.append(f"Ошибка подъёма |Δw| (с нагревом, 60 м): медиана {np.median(d['elift'][base]):.2f}, "
                     f"p90 {np.percentile(d['elift'][base], 90):.2f} м/с.\n")
    lines.append("Воспроизведение:\n```\ncd tools/research/air_nn_pilot\n/home/greg/deltaplan/tools/dp lock cpu "
                 ".venv/bin/python p3/err_by_feature.py collect\n.venv/bin/python p3/err_by_feature.py report\n```\n")
    (HERE / "p3" / "err_by_feature.md").write_text("\n".join(lines))
    (HERE / "p3" / "err_by_feature.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))
    print("p3/err_by_feature.md, .json записаны")


if __name__ == "__main__":
    {"collect": collect, "report": report}[sys.argv[1]]()
