#!/usr/bin/env python3
"""NN-P15: помогает ли гауссово размытие выхода сети П-2 (по горизонтали) — против неразмытого решателя.

(г) отложенные горные системы, 60 м; сошедшиеся (`h` ok) и несошедшиеся отдельно. Размываются предсказания ВСЕХ каналов
(h: u,v,w,θ′; m: u,v,w) на уровне 60 м (размытие линейно и перестановочно с интерполяцией по высоте), край — отражение
(`mode="reflect"`), клетки области без 5 клеток у края — как в отчёте. Подмножества: вся область, гребни (tpi_2k ≥ p90 по
области случая, как `evaluate.ridge_mask`), подветренные крутые (уклон вдоль ветра по d400_hc < −0,3; подсеточной карты
sub_steep_lee нет — тайлов в кеше нет). Спектр — радиальный спектр мощности ошибки ветра (u,v сеть−решатель, σ=0) и
поля решателя (u,v минус среднее по области случая), окно Ханна, область 86×86.

  predict — по случаям → <out>/cells/<id>.npz (продолжение после прерывания)
  report  — csv и summary.md в <out>;  all — оба

  cd tools/research/air_nn_pilot
  /home/greg/deltaplan/tools/dp lock cpu smooth -- env CUDA_VISIBLE_DEVICES= .venv/bin/python p3/smooth_eval.py all \
      --run $AIR_NN_DATA/pilot/runs/2026-10-03_p2b --out p3/out/smooth_p2b
Сеть П-3: `--run <каталог прогона П-3>` (main/model.onnx, run_info.json, split.json) или `--onnx <путь>/model.onnx`;
`--out p3/out/smooth_p3`. Другой вход сети — заменить `cond_eval.predict_case`.
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

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "p3"))
import cond_eval as C  # noqa: E402
from pilotnn import prep as P  # noqa: E402
from pilotnn.data import Datasets, case_groups  # noqa: E402

SIGMAS = (0.0, 0.5, 1.0, 1.5, 2.0)
E = C.EDGE
NB = 86 // 2 + 1                       # радиальные корзины n = 0..43 (k = n/86 цикл/клетку)
BANDS = (("λ 2–4 кл (0,8–1,6 км)", 22, 43), ("λ 4–8 кл (1,6–3,2 км)", 11, 21), ("λ 8–16 кл (3,2–6,4 км)", 6, 10),
         ("λ ≥ 16 кл (> 6,4 км)", 1, 5))
_W = {}


def blur(a, s):
    return a if s == 0 else ndimage.gaussian_filter(a, (0,) * (a.ndim - 2) + (s, s), mode="reflect")


def radial(fields):
    """Радиальный спектр мощности суммы по компонентам; fields — (n, 86, 86). → (NB,) сумма |F|²."""
    n = fields.shape[-1]
    w = np.outer(np.hanning(n), np.hanning(n))
    F = np.fft.fft2((fields - fields.mean((-2, -1), keepdims=True)) * w)
    p = (np.abs(F) ** 2).sum(0) / (w ** 2).sum()
    k = np.hypot(*np.meshgrid(np.fft.fftfreq(n) * n, np.fft.fftfreq(n) * n))
    idx = np.rint(k).astype(int)
    m = idx < NB
    return np.bincount(idx[m], weights=p[m], minlength=NB)


def _init(onnx, dirs):
    C._init(onnx, dirs)


def work(job):
    cid, row, root, out = job
    f = out / "cells" / f"{cid}.npz"
    if f.exists():
        return cid
    with np.load(C.case_file(C._W["dirs"], cid)) as zc:
        X, F, meta = zc["X"], zc["F"], json.loads(str(zc["meta"]))
    pred = C.predict_case(C._W["sess"], X, F, meta)
    with np.load(root / "cases" / f"{cid}.npz") as zz:
        th, tm, hc = zz["d400_h"].astype(np.float64), zz["d400_m"].astype(np.float64), zz["d400_hc"].astype(np.float64)
    lw = C.level_weights(P.AGL, C.A_KEY)
    Th, Tm = C.at_level(th, lw), C.at_level(tm, lw)
    Ph, Pm = C.at_level(pred["h"], lw), C.at_level(pred["m"], lw)
    s = (slice(E, -E),) * 2
    vt = np.hypot(Th[0], Th[1])[s]
    t = P.tpi(hc, P.TPI_SIGMAS_M[0])[s]
    ridge = t >= np.percentile(t, 90)
    wd = math.radians(float(row["wdir"]))
    gy, gx = np.gradient(hc, 400.0)
    sa = (gx * (-math.sin(wd)) + gy * (-math.cos(wd)))[s]
    rec = dict(vt=vt.ravel().astype(np.float16), ridge=ridge.ravel(), lee=(sa < -0.3).ravel())
    for i, sg in enumerate(SIGMAS):
        bh, bm = blur(Ph, sg), blur(Pm, sg)
        d = bh[:, s[0], s[1]] - Th[:, s[0], s[1]]
        rec[f"wind{i}"] = np.hypot(d[0], d[1]).ravel().astype(np.float16)
        rec[f"dw_h{i}"] = d[2].ravel().astype(np.float16)                       # знаковое
        rec[f"dw_m{i}"] = (bm[2] - Tm[2])[s].ravel().astype(np.float16)
        rec[f"dspd{i}"] = (np.hypot(bh[0], bh[1])[s] - vt).ravel().astype(np.float16)
        if i == 0:
            rec["spec_err"] = radial(d[:2])
            rec["spec_truth"] = radial(Th[:2, s[0], s[1]])
    tmp = f.with_suffix(".tmp.npz")
    np.savez_compressed(tmp, **rec)
    os.replace(tmp, f)
    return cid


def predict(a):
    run = Path(a.run)
    info = json.loads((run / "run_info.json").read_text())
    split = json.loads((run / "split.json").read_text())
    dss = Datasets([(d["name"], d["root"]) for d in info["datasets"]])
    rows = {r["id"]: r for r in dss.case_rows()}
    ids = sorted(split[C.SET])
    out = Path(a.out)
    (out / "cells").mkdir(parents=True, exist_ok=True)
    onnx = Path(a.onnx) if a.onnx else run / "main/model.onnx"
    todo = [(c, rows[c], dss.ds_of(c).root, out) for c in ids if not (out / "cells" / f"{c}.npz").exists()]
    print(f"predict: {len(ids)} случаев, осталось {len(todo)}", flush=True)
    t0 = time.time()
    if todo:
        with mp.Pool(a.procs, _init, (onnx, info["prep_dirs"])) as pool:
            for i, _ in enumerate(pool.imap_unordered(work, todo, chunksize=2)):
                if i % 100 == 0:
                    print(f"  {i}/{len(todo)} {time.time() - t0:.0f} с", flush=True)
    conv = {c: int(case_groups(rows[c])["gh"] == "conv") for c in ids}
    convm = {c: int(case_groups(rows[c])["gm"] == "conv") for c in ids}
    (out / "case_groups.json").write_text(json.dumps(dict(ids=ids, gh=[conv[c] for c in ids], gm=[convm[c] for c in ids],
                                                          run=str(run), onnx=str(onnx)), ensure_ascii=False))


def wr(path, rows):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(list(rows[0]))
        for r in rows:
            w.writerow([f"{v:.4g}" if isinstance(v, float) else v for v in r.values()])


def table(rows, heads):
    o = ["| " + " | ".join(heads) + " |", "|" + "---|" * len(heads)]
    for r in rows:
        o.append("| " + " | ".join(f"{v:.3g}" if isinstance(v, float) else str(v) for v in r.values()) + " |")
    return "\n".join(o)


def timing():
    rng = np.random.default_rng(0)
    a = rng.standard_normal((3, 91, 96, 96)).astype(np.float32)
    res = []
    for sg in SIGMAS[1:]:
        ts = []
        for _ in range(5):
            t0 = time.perf_counter()
            ndimage.gaussian_filter(a, (0, 0, sg, sg), mode="reflect")
            ts.append(time.perf_counter() - t0)
        res.append((sg, 1000 * min(ts), 1000 * float(np.median(ts))))
    return res


def report(a):
    out = Path(a.out)
    g = json.loads((out / "case_groups.json").read_text())
    ids = g["ids"]
    D = {}
    keys = None
    for cid in ids:
        with np.load(out / "cells" / f"{cid}.npz") as z:
            d = {k: z[k] for k in z.files}
        for k, v in d.items():
            D.setdefault(k, []).append(v)
    n = np.array([x.size for x in D["vt"]])
    cat = lambda k: np.concatenate(D[k]).astype(np.float32 if D[k][0].dtype == np.float16 else D[k][0].dtype)  # noqa: E731
    vt, ridge, lee = cat("vt"), cat("ridge").astype(bool), cat("lee").astype(bool)
    gh = np.repeat(np.array(g["gh"], bool), n)
    gm = np.repeat(np.array(g["gm"], bool), n)
    rows = []
    for gname, gsel, gselm in (("conv", gh, gm), ("nc", ~gh, ~gm)):
        for sub, ss in (("область", None), ("гребни", ridge), ("подветренные", lee)):
            for i, sg in enumerate(SIGMAS):
                m = gsel if ss is None else gsel & ss
                mm = gselm if ss is None else gselm & ss
                e = cat(f"wind{i}")[m]
                ok = e <= np.maximum(C.OK_MS, C.OK_REL * vt[m])
                lh = np.abs(cat(f"dw_h{i}")[m])
                lm = np.abs(cat(f"dw_m{i}")[mm])
                rows.append(dict(group=gname, subset=sub, sigma=sg, n_cells=int(m.sum()), w_med=float(np.median(e)),
                                 w_p90=float(np.percentile(e, 90)), w_ok=float(ok.mean()), lift_h_ok=float((lh < C.OK_LIFT).mean()),
                                 lift_m_ok=float((lm < C.OK_LIFT).mean()), speed_bias=float(cat(f"dspd{i}")[m].mean()),
                                 dw_bias=float(cat(f"dw_h{i}")[m].mean())))
    wr(out / "sigma_table.csv", rows)
    # спектры
    spec = []
    for gname, sel in (("conv", np.array(g["gh"], bool)), ("nc", ~np.array(g["gh"], bool))):
        se = np.sum([D["spec_err"][i] for i in np.flatnonzero(sel)], 0)
        st = np.sum([D["spec_truth"][i] for i in np.flatnonzero(sel)], 0)
        for nm, lo, hi in BANDS:
            spec.append(dict(group=gname, band=nm, err_share=float(se[lo:hi + 1].sum() / se[1:].sum()),
                             truth_share=float(st[lo:hi + 1].sum() / st[1:].sum()),
                             err_to_truth_power=float(se[lo:hi + 1].sum() / st[lo:hi + 1].sum())))
        spec.append(dict(group=gname, band="вся (n≥1)", err_share=1.0, truth_share=1.0,
                         err_to_truth_power=float(se[1:].sum() / st[1:].sum())))
        np.savetxt(out / f"spectrum_{gname}.csv", np.c_[np.arange(NB), se / se[1:].sum(), st / st[1:].sum()], delimiter=",",
                   header="n (k=n/86 цикл/клетку),err_frac,truth_frac", fmt="%.5g")
    wr(out / "spectrum_bands.csv", spec)
    tm = timing()
    wr(out / "timing.csv", [dict(sigma=s_, min_ms=a_, median_ms=b_) for s_, a_, b_ in tm])
    # оптимум
    best = []
    for gname in ("conv", "nc"):
        for sub in ("область", "гребни", "подветренные"):
            r = [x for x in rows if x["group"] == gname and x["subset"] == sub]
            b = min(r, key=lambda x: x["w_med"])
            r0 = r[0]
            best.append(dict(group=gname, subset=sub, best_sigma_by_median=b["sigma"],
                             med_gain_pct=100 * (1 - b["w_med"] / r0["w_med"]), p90_gain_pct=100 * (1 - b["w_p90"] / r0["w_p90"]),
                             ok_gain_pp=100 * (b["w_ok"] - r0["w_ok"])))
    wr(out / "best_sigma.csv", best)
    L = ["---", 'type: "research"', 'status: "active"', 'module: "air-nn"', f'updated: "{time.strftime("%F")}"',
         'summary: "Гауссово размытие выхода сети по горизонтали, σ 0–2 клетки: ошибка ветра и подъёма против неразмытого решателя (г), на гребнях и подветренных; спектр ошибки; цена на CPU."',
         "related: []", "---", "", f"# Размытие выхода сети ({Path(g['run']).name})", "",
         f"Сгенерировано `p3/smooth_eval.py report`; модель `{g['onnx']}`; набор (г), 60 м, область без {E} клеток у края, 720 случаев. "
         "Размыты все каналы предсказания (отражение на краю), цель — неразмытый решатель. «ок» ветра ≤ max(0,3; 10 % |V|), "
         "подъёма < 0,1 м/с (`lift_h` — с нагревом, `lift_m` — без). Смещения: speed — среднее |V_сети|−|V_решателя|, dw — среднее Δw с нагревом. "
         "Подветренные крутые — уклон вдоль ветра по d400_hc < −0,3 (подсеточной sub_steep_lee нет).", ""]
    nf = out / "notes.md"
    if nf.exists():
        L += [nf.read_text().rstrip(), ""]
    H = ["группа", "подмн.", "σ", "клеток", "ветер мед.", "p90", "ок", "w ок (нагрев)", "w ок (без)", "смещ. |V|", "смещ. w"]
    for gname in ("conv", "nc"):
        L += [f"## σ → ошибки, {gname}", "", table([r for r in rows if r["group"] == gname], H), ""]
    L += ["## Оптимальный σ и выигрыш (по медиане ветра; к σ = 0)", "", table(best, ["группа", "подмн.", "σ*", "медиана, %", "p90, %", "ок, п.п."]), "",
          "## Спектр ошибки ветра и поля решателя (радиальный, σ = 0)", "", table(spec, ["группа", "полоса", "доля энергии ошибки", "доля энергии поля решателя", "мощность ошибки / поля"]), "",
          "Полные спектры по корзинам — `spectrum_conv.csv`, `spectrum_nc.csv`.", "",
          "## Цена размытия (3 × 91 × 96², float32, scipy, 1 ядро CPU)", "", table([dict(s=s_, a=a_, b=b_) for s_, a_, b_ in tm], ["σ", "мин., мс", "медиана, мс"]), ""]
    (out / "summary.md").write_text("\n".join(L) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stage", choices=["predict", "report", "all"])
    ap.add_argument("--run", default=str(C.DATA / "pilot/runs/2026-10-03_p2b"))
    ap.add_argument("--onnx", default=None)
    ap.add_argument("--out", default=str(HERE / "p3/out/smooth_p2b"))
    ap.add_argument("--procs", type=int, default=int(os.environ.get("COND_PROCS", "10")))
    a = ap.parse_args()
    if a.stage in ("predict", "all"):
        predict(a)
    if a.stage in ("report", "all"):
        report(a)


if __name__ == "__main__":
    main()
