"""AP-11: переносятся ли границы фаз с идеальных форм на рельеф с эрозией (серия ERODED = 5: 6 рельефов fs1_10k × 30 Fr,
H = 0, h/z_i = 1). Только CPU, данные только читаются.

    PY=/home/greg/deltaplan-air-synth/tools/research/air_nn_pilot/.venv/bin/python
    $PY tools/research/air_phase/analysis/AP-11/run.py [--n-boot 200]

Вход: `features_ap_v1.h5` (P6), рельеф на сетке решателя — `inputs/hc` в частях `ap_v1__s1-74644c4/part-*.h5` (P3),
границы идеальных форм — `analysis/AP-8/summary.json` (читается из копии AP-8, путь AP8 ниже).
Подгонки — те же, что в AP-8 (`sigmoid.fit_sigmoid`, критерий засчитывания, PARAMS и MIN_DY импортированы из AP-8/run.py).
Выход: summary.json, fig_*.png, fits_eroded.json (кэш подгонок).
"""
from __future__ import annotations

import argparse, importlib.util, json, os, sys
from pathlib import Path

import h5py
import numpy as np
from scipy import ndimage

HERE = Path(__file__).resolve().parent
AP = HERE.parents[1]
sys.path.insert(0, str(AP))
from sigmoid import fit_sigmoid  # noqa: E402

AP8 = Path(os.environ.get("AP8_DIR", str(AP / "analysis" / "AP-8")))
spec = importlib.util.spec_from_file_location("ap8run", AP8 / "run.py")
A8 = importlib.util.module_from_spec(spec)
sys.modules["ap8run"] = A8
spec.loader.exec_module(A8)  # PARAMS, derived, accept, klass, pre, line_ok, local_step

DATA = Path(os.environ.get("AIR_SYNTH_DATA", os.path.expanduser("~/air_synth_data"))) / "phase"
ERODED = 5
EDGE = 5
CALM = 0.45


def terrain_stats(t):
    """По каждому рельефу: перепад, p95 уклона (tg и градусы), число гребней, местные перепады h_loc(R, q)."""
    e = t[t["series"] == ERODED]
    cid = {int(l): int(e["case_id"][e["line_id"] == l][0]) for l in np.unique(e["line_id"])}
    want = dict(cid)
    out = {}
    for p in sorted((DATA / "ap_v1__s1-74644c4").glob("part-*.h5")):
        with h5py.File(p, "r") as h:
            ids = h["cases"]["case_id"][:]
            for L, c in list(want.items()):
                w = np.nonzero(ids == c)[0]
                if w.size:
                    out[L] = np.asarray(h["inputs/hc"][w[0]], np.float64)
                    want.pop(L)
        if not want:
            break
    res = {}
    dx = 400.0
    for L, z in out.items():
        z = z[EDGE:-EDGE, EDGE:-EDGE]
        gy, gx = np.gradient(z, dx)
        sl = np.hypot(gx, gy)
        d = dict(relief_m=float(z.max() - z.min()), slope_p95_tan=float(np.percentile(sl, 95)),
                 slope_p95_deg=float(np.degrees(np.arctan(np.percentile(sl, 95)))))
        for R in (1.5e3, 3e3, 6e3):                      # окно (радиус), м
            k = int(round(R / dx))
            win = 2 * k + 1
            zmin = ndimage.minimum_filter(z, size=win, mode="nearest")
            zmax = ndimage.maximum_filter(z, size=win, mode="nearest")
            hw = z - zmin
            crest = (z >= zmax - 1e-9) & (hw > 0.25 * hw.max())     # локальные гребни окна с заметным перепадом
            lab, n = ndimage.label(crest, structure=np.ones((3, 3)))
            hc_ = hw[crest]
            d[f"h_loc_R{int(R)}_p50"] = float(np.median(hc_)) if hc_.size else float("nan")
            d[f"h_loc_R{int(R)}_p90"] = float(np.percentile(hc_, 90)) if hc_.size else float("nan")
            d[f"n_crests_R{int(R)}"] = int(n)
        # многогребневость: компоненты областей z > z_min + 0.5 перепада отдельно по высоте — число вершин с проминенсом > 0,2 перепада
        zs = ndimage.gaussian_filter(z, 2)
        mx = (zs == ndimage.maximum_filter(zs, size=7))
        prom = []
        for (iy, ix) in zip(*np.nonzero(mx)):
            lvl = zs[iy, ix]
            # проминенс: спуск до уровня, при котором вершина ещё отделена от более высокой точки (приближённо через пороги)
            lo, hi_ = zs.min(), lvl
            if lvl >= zs.max() - 1e-9:
                prom.append(lvl - zs.min()); continue
            for _ in range(18):
                mid = 0.5 * (lo + hi_)
                lab, _ = ndimage.label(zs >= mid, structure=np.ones((3, 3)))
                if (lab == lab[iy, ix]).any() and (zs[lab == lab[iy, ix]] > lvl + 1e-9).any():
                    lo = mid
                else:
                    hi_ = mid
            prom.append(lvl - hi_)
        prom = np.array(prom)
        d["n_peaks_prom20"] = int((prom > 0.2 * d["relief_m"]).sum())
        res[L] = d
    return res


def fit_all(t, n_boot):
    D = A8.derived(t)
    e = t["series"] == ERODED
    fits = {}
    for L in np.unique(t["line_id"][e]):
        for p, (_, kind, _, _) in A8.PARAMS.items():
            if kind == "heat":
                continue
            m = e & (t["line_id"] == L)
            if p not in ("conv", "spread_rel"):
                m = m & (t["status"] == 0)
            r = fit_sigmoid(t["fr"][m], D[p][m], n_boot=n_boot, noise=None)
            r = {k: (list(v) if isinstance(v, tuple) else v) for k, v in r.items()}
            yy = D[p][m]
            var = float(np.var(yy)) if yy.size > 1 else 0.0
            r["r2"] = float(1 - r["resid_std"] ** 2 / var) if var > 0 and np.isfinite(r["resid_std"]) else float("nan")
            r["step_dec"] = A8.local_step(t["fr"][m], r["x_c"])
            r["noise"] = None
            fits[f"{L}|{p}"] = r
    return fits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n-boot", type=int, default=200)
    a = ap.parse_args()
    t = A8.load_table()
    ts = terrain_stats(t)
    cache = HERE / "fits_eroded.json"
    if cache.exists() and json.loads(cache.read_text()).get("n_boot") == a.n_boot:
        fits = json.loads(cache.read_text())["fits"]
    else:
        fits = fit_all(t, a.n_boot)
        cache.write_text(json.dumps({"n_boot": a.n_boot, "fits": fits}))
    S8 = json.loads((AP8 / "summary.json").read_text())
    ideal = [b for b in S8["boundaries"] if b["H"] == 0 and b["h_over_zi"] == 1.0]
    lines = sorted(ts)
    info = {L: ts[L] | {"line_id": L, "relief_name": A8.dec(t["relief_name"][(t["series"] == ERODED) & (t["line_id"] == L)][0])}
            for L in lines}
    for L in lines:
        m = (t["series"] == ERODED) & (t["line_id"] == L)
        info[L]["n_conv"] = int((t["status"][m] == 0).sum())
        info[L]["n_calm_conv"] = int(((t["status"][m] == 0) & (t["fr"][m] <= CALM)).sum())
        info[L]["fr_conv_min"] = float(t["fr"][m & (t["status"] == 0)].min()) if info[L]["n_conv"] else None
        info[L]["fr_nonconv_max"] = float(t["fr"][m & (t["status"] != 0)].max()) if (m & (t["status"] != 0)).any() else None
        # Fr относительно местного перепада
        for key in [k for k in ts[L] if k.startswith("h_loc")]:
            info[L]["frfac_" + key] = ts[L]["relief_m"] / ts[L][key]   # Fr_loc = Fr · relief/h_loc

    rows = []
    for L in lines:
        for p, (grp, kind, mindy, _) in A8.PARAMS.items():
            if kind == "heat":
                continue
            r = fits[f"{L}|{p}"]
            ok, why = A8.accept(r, p, 0.1, 5.0)
            rows.append(dict(line_id=L, param=p, ok=ok, why=why, fr_c=r["x_c"], ci=r["x_c_ci"], w_dec=r["w_dec"], dy=r["dy"],
                             r2=r["r2"], calm=bool(r["x_c"] <= CALM) if np.isfinite(r["x_c"]) else False,
                             step_dec=r["step_dec"]))
    # ---- сравнение по параметрам
    comp = {}
    for p, (grp, kind, mindy, _) in A8.PARAMS.items():
        if kind == "heat":
            continue
        idl = [b for b in ideal if b["param"] == p and not b["calm"]] if p != "conv" else [b for b in ideal if b["param"] == p]
        er = [r for r in rows if r["param"] == p and r["ok"]]
        c = dict(n_ideal=len(idl), n_eroded=len(er))
        if idl:
            fc = np.array([b["fr_c"] for b in idl]); w = np.array([b["w_dec"] for b in idl])
            lo_ = min(b["fr_c_ci"][0] for b in idl); hi_ = max(b["fr_c_ci"][1] for b in idl)
            c.update(ideal_fr_c=[round(float(fc.min()), 3), round(float(np.median(fc)), 3), round(float(fc.max()), 3)],
                     ideal_ci_union=[round(lo_, 3), round(hi_, 3)], ideal_w_median=round(float(np.median(w)), 3),
                     ideal_lines=[b["shape"] + str(b["s"]) for b in idl])
        if er:
            fc = np.array([r["fr_c"] for r in er]); w = np.array([r["w_dec"] for r in er])
            c.update(eroded_fr_c=[round(float(fc.min()), 3), round(float(np.median(fc)), 3), round(float(fc.max()), 3)],
                     eroded_w_median=round(float(np.median(w)), 3), eroded_lines=[r["line_id"] for r in er],
                     eroded_calm=int(sum(r["calm"] for r in er)))
            if idl:
                inside = [bool(c["ideal_ci_union"][0] <= r["fr_c"] <= c["ideal_ci_union"][1]) for r in er]
                c["n_eroded_inside_ideal_ci"] = int(sum(inside))
                c["median_shift_dec"] = round(float(np.log10(np.median(fc) / np.median([b["fr_c"] for b in idl]))), 3)
        comp[p] = c
    # ---- что объясняет разброс Fr_c между рельефами: ранговая корреляция с признаками рельефа
    from scipy.stats import spearmanr
    feats = ["relief_m", "slope_p95_deg", "n_peaks_prom20", "n_crests_R3000"]
    expl = {}
    for p in comp:
        er = [r for r in rows if r["param"] == p and r["ok"] and not r["calm"]]
        if len(er) < 4:
            continue
        lf = np.log10([r["fr_c"] for r in er])
        d = {}
        for f in feats:
            x = [info[r["line_id"]][f] for r in er]
            d[f] = None if np.ptp(x) == 0 else round(float(spearmanr(x, lf)[0]), 2)
        expl[p] = dict(n=len(er), **d)
    # ---- какой Fr упорядочивает лучше: разброс lg Fr_c между рельефами (std, декады) при Fr и при Fr_loc
    order = {}
    variants = ["all"] + [k for k in ts[lines[0]] if k.startswith("h_loc")]
    for p in comp:
        er = [r for r in rows if r["param"] == p and r["ok"] and not r["calm"]]
        if len(er) < 4:
            continue
        d = {}
        for v in variants:
            f = np.array([1.0 if v == "all" else info[r["line_id"]]["frfac_" + v] for r in er])
            lg = np.log10([r["fr_c"] for r in er]) + np.log10(f)
            d[v] = round(float(np.std(lg, ddof=1)), 3)
        order[p] = dict(n=len(er), **d)
    med = {v: round(float(np.median([o[v] for o in order.values()])), 3) for v in variants}
    wins = {v: int(sum(1 for o in order.values() if o[v] == min(o[x] for x in variants))) for v in variants}
    # ---- вердикт переноса: параметры, где порог на эрозии ≥ 4 из 6 рельефов засчитан и не штиль
    core = [p for p, c in comp.items() if c["n_ideal"] >= 3 and c["n_eroded"] >= 4]
    verdict = {p: dict(inside=comp[p]["n_eroded_inside_ideal_ci"], n=comp[p]["n_eroded"],
                       shift_dec=comp[p].get("median_shift_dec")) for p in core}
    frac_inside = (sum(v["inside"] for v in verdict.values()) / max(sum(v["n"] for v in verdict.values()), 1)) if verdict else 0
    n_params_ok = sum(1 for v in verdict.values() if v["inside"] / v["n"] >= 0.5)
    transfer = "yes" if frac_inside >= 0.7 else ("no" if frac_inside <= 0.3 else "partly")
    summ = dict(task="AP-11", transfer=transfer, frac_inside_ideal_ci=round(frac_inside, 2), n_core_params=len(core),
                n_core_params_majority_inside=n_params_ok, verdict=verdict, terrain=info, comparison=comp,
                explain_spearman=expl, ordering_std_dec=order, ordering_median_std_dec=med, ordering_wins=wins,
                rows=rows, n_boot=a.n_boot)
    (HERE / "summary.json").write_text(json.dumps(summ, ensure_ascii=False, indent=1, default=float))
    figs(t, info, comp, rows, order, ideal)
    print(json.dumps({k: summ[k] for k in ("transfer", "frac_inside_ideal_ci", "n_core_params", "n_core_params_majority_inside",
                                          "ordering_median_std_dec", "ordering_wins")}, ensure_ascii=False))


def figs(t, info, comp, rows, order, ideal):
    import matplotlib; matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    ps = [p for p, c in comp.items() if c["n_eroded"] and c["n_ideal"]]
    # 1: Fr_c ideal (диапазон) против эрозии (точки), по параметрам
    fig, ax = plt.subplots(figsize=(8, 0.35 * len(ps) + 1.5))
    for i, p in enumerate(ps):
        idl = [b for b in ideal if b["param"] == p and (p == "conv" or not b["calm"])]
        for b in idl:
            ax.plot(b["fr_c_ci"], [i, i], c="#9ab", lw=5, alpha=.5, solid_capstyle="butt")
            ax.plot(b["fr_c"], i, "|", c="#456", ms=10)
        for r in rows:
            if r["param"] == p and r["ok"]:
                ax.plot(r["fr_c"], i + 0.25, "o", c="#c52" if not r["calm"] else "#aaa", ms=4)
    ax.set_yticks(range(len(ps))); ax.set_yticklabels(ps, fontsize=7); ax.set_xscale("log"); ax.set_xlabel("Fr_c")
    ax.set_title("Fr_c: идеальные (серые полосы, ДИ) и эрозия (точки)"); fig.tight_layout(); fig.savefig(HERE / "fig_frc_ideal_vs_eroded.png", dpi=110); plt.close(fig)
    # 2: ширина
    fig, ax = plt.subplots(figsize=(6, 4))
    wi = [b["w_dec"] for b in ideal if b["param"] not in ("conv", "spread_rel") and not b["calm"]]
    we = [r["w_dec"] for r in rows if r["ok"] and not r["calm"] and r["param"] not in ("conv", "spread_rel")]
    ax.hist([wi, we], bins=np.linspace(0, 1, 21), label=["идеальные", "эрозия"], density=True)
    ax.set_xlabel("w, декады"); ax.legend(); fig.tight_layout(); fig.savefig(HERE / "fig_width.png", dpi=110); plt.close(fig)
    # 3: сходимость по Fr для 6 рельефов
    fig, ax = plt.subplots(figsize=(6, 4))
    e = t["series"] == ERODED
    for L in sorted(info):
        m = e & (t["line_id"] == L)
        ax.plot(t["fr"][m], t["status"][m] + 0.03 * (L - 431), ".-", label=f"{info[L]['relief_m']:.0f} м, {info[L]['slope_p95_deg']:.1f}°")
    ax.set_xscale("log"); ax.set_xlabel("Fr"); ax.set_ylabel("status (0 — сошёлся)"); ax.legend(fontsize=7); fig.tight_layout()
    fig.savefig(HERE / "fig_convergence.png", dpi=110); plt.close(fig)
    # 4: разброс при разном Fr
    fig, ax = plt.subplots(figsize=(6, 4))
    vs = list(next(iter(order.values())).keys())[1:]
    ax.boxplot([[o[v] for o in order.values()] for v in vs], tick_labels=[v.replace("h_loc_", "") for v in vs])
    ax.set_ylabel("std lg Fr_c между рельефами"); ax.tick_params(axis="x", labelsize=6, rotation=30); fig.tight_layout()
    fig.savefig(HERE / "fig_ordering.png", dpi=110); plt.close(fig)


if __name__ == "__main__":
    main()
