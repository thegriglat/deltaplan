#!/usr/bin/env python3
"""Проверка суррогатов на отложенных случаях: полные окна 100 м, ключевые числа пилота и ошибки
поля — полная модель (эталон) / суррогат (phys, lin, gbm; модели фолда, где случай вне обучения) /
прежняя аналитика игры (features.Analytic).

Фолд случая: встроенное место — «место <loc>» (место целиком вне обучения), синтетика — «синтетика»
(обучение только на встроенных). Дополнительно — «новые условия» (случаи из out/fit_metrics.json →
hold_cases, модели обучены на остальных случаях тех же мест).

Ключевые числа (окно, центр — старт / вершина синтетики):
  w50_c   — w_mech на 50 м над центром (подъём у старта), м/с
  w50_br  — наибольший w_mech на 50 м в 1 км от центра (бровка), м/с
  s50_c   — скорость горизонтального ветра на 50 м над центром (с нагревом — что чувствует пилот), м/с
  sink100 — 1-й перцентиль w_mech на 100 м в окне (опускание за гребнем), м/с
  saddle  — s50 в седловине / s50 на 2,5 км против ветра (синтетическая седловина), ×
  wc200   — наибольший w_conv на 200 м в 1,5 км от центра (организованный подъём), м/с
  ceil    — потолок частицы над центром, м над землёй (θ̄ погоды + θ′; без θ′ — аналитика: z_dry/кромка)
Ошибки поля (внутри окна, 25–600 м): RMSE w_mech, |Δ горизонтали|, w_conv, θ′.

  .venv/bin/python evaluate.py           # → out/eval.json, out/eval_rows.jsonl, out/eval_*.npz (карты)
"""
from __future__ import annotations

import json
import math
import time
from pathlib import Path

import numpy as np

import build as B
import features as F
import fit as FT

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
CFG = json.loads((HERE.parents[2] / "configs/atmosphere.json").read_text())
ANA = F.Analytic(CFG)
KINDS = ("phys", "lin", "gbm")
BAND = (25, 600)
G, THETA0, RHO_CP, KAPPA = 9.81, 300.0, 1200.0, 0.4


def fold_of(run, hold):
    if run["id"] in hold:
        return "новые условия"
    return "синтетика" if run["loc"].startswith("s_") else f"место {run['loc']}"


def flat(feats):
    return {k: v.ravel() for k, v in feats.items()}


def predict_window(feats, fold, models):
    """→ dict kind → dict target → (nA, ny, nx)."""
    d = flat(feats)
    sh = feats["a"].shape
    out = {}
    for kind in KINDS:
        out[kind] = {}
        for t in FT.TARGETS:
            key = (fold, t, kind)
            if key not in models:
                try:
                    models[key] = FT.load_fold(fold, t, kind)
                except FileNotFoundError:
                    models[key] = None
            m = models[key]
            out[kind][t] = None if m is None else m.predict(d).reshape(sh)
    return out


def compose(aux, pr, U10):
    """Поля в м/с из целей: (u_mech, v_mech, w_mech, u, v, w_conv, θ′)."""
    Ub = aux["Ub"][:, None, None]
    ex, ey = aux["ex"], aux["ey"]
    if U10 >= B.U_MIN and pr.get("t_mpar") is not None:
        par, per = pr["t_mpar"] * Ub, pr["t_mper"] * Ub
        um, vm = par * ex - per * ey, par * ey + per * ex
        wm = pr["t_mw"] * Ub
    else:
        um = vm = wm = np.zeros_like(pr["t_cw"])
    du = pr["t_cpar"] * ex - pr["t_cper"] * ey
    dv = pr["t_cpar"] * ey + pr["t_cper"] * ex
    return dict(um=um, vm=vm, wm=wm, u=um + du, v=vm + dv, wc=pr["t_cw"], th=pr["t_th"])


def truth(aux):
    hh, mm = aux["hh"], aux["mm"]
    return dict(um=mm[0], vm=mm[1], wm=mm[2], u=hh[0], v=hh[1], wc=hh[2] - mm[2], th=hh[3])


def analytic(run, aux, ref_msl):
    agl = aux["agl"]
    X, Y, hc = aux["X"], aux["Y"], aux["hc"]
    Z = hc[None] + agl[:, None, None]
    Xb, Yb = np.broadcast_to(X, Z.shape), np.broadcast_to(Y, Z.shape)
    pr = run["profile"]
    u, v, w = ANA.eval(run["loc"], Xb.ravel(), Yb.ravel(), Z.ravel(), run["U10"], run["wdir"], pr["alpha"],
                       pr["max_profile"], ref_msl)
    sh = Z.shape
    zero = np.zeros(sh)
    return dict(um=u.reshape(sh), vm=v.reshape(sh), wm=w.reshape(sh), u=u.reshape(sh), v=v.reshape(sh), wc=zero, th=zero)


def bil(M, fi, fj):
    i0, j0 = int(math.floor(fi)), int(math.floor(fj))
    a, b = fi - i0, fj - j0
    return float((1 - b) * ((1 - a) * M[j0, i0] + a * M[j0, i0 + 1]) + b * ((1 - a) * M[j0 + 1, i0] + a * M[j0 + 1, i0 + 1]))


def ceiling(f, aux, run, ic, jc):
    """Потолок частицы над столбцом (ic, jc), м над землёй сетки; θ̄ — погода часа, θ′ — поле."""
    D = aux["day"]
    zg = aux["hc"][jc, ic]
    H = aux["H"][jc, ic]
    if H <= 5:
        return None
    agl = aux["agl"]
    th = f["th"][:, jc, ic]
    U = math.hypot(f["u"][0, jc, ic], f["v"][0, jc, ic])
    ustar = KAPPA * U / math.log(agl[0] / 0.1)
    h = max(D.z_i - zg, 300.0)
    wstar = (G / THETA0 * H / RHO_CP * h) ** (1 / 3)
    wm = (ustar ** 3 + 0.28 * wstar ** 3) ** (1 / 3)
    dth = 6.5 * H / RHO_CP / max(wm, 0.1)
    env = D.theta(zg + agl) + th
    tp = env[0] + dth
    top = None
    for k in range(1, len(agl)):
        if env[k] > tp:
            a0, a1 = agl[k - 1], agl[k]
            e0, e1 = env[k - 1], env[k]
            top = a0 + (tp - e0) / max(e1 - e0, 1e-6) * (a1 - a0)
            break
    if top is None:
        top = float(agl[-1])   # выше 2000 м над землёй — предел среза
    return float(min(top, D.z_lcl - zg))


def keynums(f, aux, run, loc_center, is_saddle):
    X, Y = aux["X"], aux["Y"]
    agl = list(aux["agl"])
    i50, i100, i200 = agl.index(50.0), agl.index(100.0), agl.index(200.0)
    x0, y0, dx = X[0, 0] - 50.0, Y[0, 0] - 50.0, 100.0
    cx, cy = loc_center
    fi, fj = (cx - x0) / dx - 0.5, (cy - y0) / dx - 0.5
    ic, jc = int(round(fi)), int(round(fj))
    R = np.hypot(X - cx, Y - cy)
    inner = np.zeros_like(R, bool); inner[B.EDGE:-B.EDGE, B.EDGE:-B.EDGE] = True
    s50 = np.hypot(f["u"][i50], f["v"][i50])
    k = dict(w50_c=bil(f["wm"][i50], fi, fj), w50_br=float(np.max(f["wm"][i50][(R < 1000) & inner])),
             s50_c=bil(s50, fi, fj), sink100=float(np.percentile(f["wm"][i100][inner], 1)),
             wc200=float(np.max(f["wc"][i200][(R < 1500) & inner])))
    if is_saddle:
        ex, ey = aux["ex"], aux["ey"]
        ui, uj = (cx - 2500 * ex - x0) / dx - 0.5, (cy - 2500 * ey - y0) / dx - 0.5
        k["saddle"] = bil(s50, fi, fj) / max(bil(s50, ui, uj), 0.1)
    return k, ic, jc


def field_err(f, t, aux):
    agl = aux["agl"]
    lv = (agl >= BAND[0]) & (agl <= BAND[1])
    sl = (lv, slice(B.EDGE, -B.EDGE), slice(B.EDGE, -B.EDGE))
    r = lambda a, b: float(np.sqrt(np.mean((a[sl] - b[sl]) ** 2)))
    return dict(wm=r(f["wm"], t["wm"]), uh=float(np.sqrt(np.mean((f["u"][sl] - t["u"][sl]) ** 2 + (f["v"][sl] - t["v"][sl]) ** 2))),
                wc=r(f["wc"], t["wc"]), th=r(f["th"], t["th"]))


def main(maps_for=("askarovo", "s_saddle", "aushkul")):
    t0 = time.time()
    runs = B.load_runs()
    plan = json.loads((OUT / "plan.json").read_text())
    fm = json.loads((OUT / "fit_metrics.json").read_text())
    hold = set(fm["hold_cases"])
    models = {}
    rows = []
    maps_done = set()
    with (OUT / "eval_rows.jsonl").open("w") as fo:
        for ir, run in enumerate(runs):
            fold = fold_of(run, hold)
            Z = np.load(B.FIELDS / f"{run['id']}.npz")
            centers = plan["centers"][run["loc"]]
            for iw, ctr in enumerate(centers):
                if f"w{iw}" not in run:
                    continue
                feats, targ, aux = B.window_frame(run, iw, Z)
                L = F.P.location(run["loc"])
                ref = L.height_at(ctr[0], -ctr[1])
                T = truth(aux)
                prs = predict_window(feats, fold, models)
                res = dict(id=run["id"], loc=run["loc"], win=iw, fold=fold, U10=run["U10"], hour=run["hour"],
                           sky=run["sky"], t_max=run["t_max"], wdir=run["wdir"], N=aux["N"], H_c=None)
                fields = dict(full=T, ana=analytic(run, aux, ref))
                for kind in KINDS:
                    if all(prs[kind][t] is not None for t in FT.HEAT):
                        fields[kind] = compose(aux, prs[kind], run["U10"])
                is_saddle = run["loc"] == "s_saddle"
                for name, f in fields.items():
                    k, ic, jc = keynums(f, aux, run, ctr, is_saddle)
                    if name == "ana":
                        D = aux["day"]
                        zg = aux["hc"][jc, ic]
                        k["ceil"] = float(min(D.z_dry_game, D.z_lcl) - zg) if aux["H"][jc, ic] > 5 else None
                    else:
                        k["ceil"] = ceiling(f, aux, run, ic, jc)
                    res[f"k_{name}"] = k
                    if name != "full":
                        res[f"e_{name}"] = field_err(f, T, aux)
                res["H_c"] = float(aux["H"][jc, ic])
                rows.append(res)
                fo.write(json.dumps(res, ensure_ascii=False, default=float) + "\n")
                key = run["loc"]
                if (key in maps_for and key not in maps_done and iw == 0 and run["U10"] > 4 and run["hour"] == 12.0
                        and run["sky"] == "clear"):
                    maps_done.add(key)
                    np.savez_compressed(OUT / f"eval_map_{key}.npz", agl=aux["agl"], X=aux["X"], Y=aux["Y"], hc=aux["hc"],
                                        **{f"{n}_{c}": f[c].astype(np.float32) for n, f in fields.items()
                                           for c in ("wm", "u", "v", "wc", "th")},
                                        meta=json.dumps(dict(id=run["id"], U10=run["U10"], wdir=run["wdir"], fold=fold)))
            if ir % 50 == 0:
                print(f"[{time.time() - t0:5.0f} с] {ir}/{len(runs)}", flush=True)
    print("окон:", len(rows))


if __name__ == "__main__":
    main()
