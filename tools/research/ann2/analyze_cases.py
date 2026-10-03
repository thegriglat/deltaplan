"""AN-1, шаг 3: таблицы по out/cells_cases.json → out/tables.json, out/tables.md."""
import json
import numpy as np
from common import OUT

C = json.load(open(OUT / "cells_cases.json"))
def q(a, p): return float(np.percentile(a, p)) if len(a) else float("nan")
def row(name, cs):
    if not cs: return None
    g = lambda k: np.array([c[k] for c in cs], float)
    sp = np.array([c["spread"] for c in cs if c["spread"]], float)
    return dict(group=name, n=len(cs), U10=float(np.median(g("U10"))), vt=float(np.median(g("vt_mean"))),
                err_med=q(g("dw_med"), 50), err_p90_of_med=q(g("dw_med"), 90), err_cellp90=q(g("dw_p90"), 50), err_mean=float(g("dw_mean").mean()),
                spread_med=q(sp, 50) if len(sp) else None, n_spread=int(len(sp)),
                rho_med=q(g("rho_med"), 50), rho_p90=q(g("rho_p90"), 50),
                rho0_med=q(g("rho0_med"), 50))
def cls(c):
    return "nc" if c["gh"] == "nc" else ("conv-conf" if c["conf"] else "conv-late")
T = {}
sets = ["holdout_sys", "newcond_p6", "train", "holdout_place", "holdout_proc", "newcond_old"]
T["by_set_class"] = [row(f"{s} / {k}", [c for c in C if c["set"] == s and (k == "all" or cls(c) == k)])
                     for s in sets for k in ("all", "conv-conf", "conv-late", "nc")]
terr = [c for c in C if c["target"] != "last" and c["spread"] is not None]   # terrain (П1 v3)
T["by_u10_class_terrain_holdout"] = []
bins = [(0, 2), (2, 4), (4, 6), (6, 99)]
for (a, b) in bins:
    for k in ("conv-conf", "conv-late", "nc"):
        T["by_u10_class_terrain_holdout"].append(row(f"U10 {a}-{b} / {k}", [c for c in C if c["set"] in ("holdout_sys", "newcond_p6") and a <= c["U10"] < b and cls(c) == k]))
T["by_place_holdout_sys"] = []
locs = sorted({c["loc"] for c in C if c["set"] == "holdout_sys"})
pl = []
for l in locs:
    cs = [c for c in C if c["set"] == "holdout_sys" and c["loc"] == l]
    pl.append(dict(loc=l, n=len(cs), err_med=q([c["dw_med"] for c in cs], 50), nc_frac=float(np.mean([c["gh"] == "nc" for c in cs])),
                   rho_med=q([c["rho_med"] for c in cs], 50)))
T["by_place_holdout_sys"] = pl
em = np.array([p["err_med"] for p in pl]); nf = np.array([p["nc_frac"] for p in pl])
T["place_corr_err_vs_ncfrac"] = float(np.corrcoef(em, nf)[0, 1])
# внутри класса — связь с числом итераций (признак «насколько у границы сходимости»)
conv = [c for c in C if c["set"] in ("holdout_sys", "newcond_p6") and c["gh"] == "conv" and c["iters"]]
it = np.array([c["iters"] for c in conv], float); e = np.array([c["dw_med"] for c in conv]); u = np.array([c["U10"] for c in conv])
T["conv_corr_err_iters"] = float(np.corrcoef(np.log(it), e)[0, 1]); T["conv_corr_err_U10"] = float(np.corrcoef(u, e)[0, 1])
T["conv_corr_err_iters_partial_U10"] = None
A = np.c_[np.ones_like(u), u, np.log(it)]
beta, *_ = np.linalg.lstsq(A, e, rcond=None); T["conv_ols_err_on_U10_logiters"] = beta.tolist()
bi = [(0, 150), (150, 300), (300, 600), (600, 5000)]
T["conv_by_iters"] = [row(f"iters {a}-{b}", [c for c in conv if a <= c["iters"] < b]) for a, b in bi]
# нc: связь ошибки с собственным разбросом
nc = [c for c in C if c["set"] in ("holdout_sys", "newcond_p6", "train") and c["gh"] == "nc" and c["spread"]]
sp = np.array([c["spread"] for c in nc]); e = np.array([c["dw_med"] for c in nc]); u = np.array([c["U10"] for c in nc])
T["nc_corr_err_spread"] = float(np.corrcoef(sp, e)[0, 1]); T["nc_corr_err_U10"] = float(np.corrcoef(u, e)[0, 1]); T["nc_corr_spread_U10"] = float(np.corrcoef(sp, u)[0, 1])
T["nc_ratio_dwmed_over_spread"] = dict(n=len(nc), q10=q(e / sp, 10), med=q(e / sp, 50), q90=q(e / sp, 90))
T["nc_spread_q"] = [q(sp, p) for p in (10, 25, 50, 75, 90)]; T["nc_err_q"] = [q(e, p) for p in (10, 25, 50, 75, 90)]
json.dump(T, open(OUT / "tables.json", "w"), ensure_ascii=False, indent=1)
f = lambda x: "—" if x is None else f"{x:.3f}"
L = ["| группа | n | U10 мед | |V| мед | ошибка ветра, мед. по случаям | p90 по случаям | p90 клеток (мед.) | разброс цели p90 (мед.) | ρ мед | ρ p90 | ρ мед без поправки на разброс |", "|" + "---|" * 11]
def add(rs):
    for r in rs:
        if r: L.append(f"| {r['group']} | {r['n']} | {r['U10']:.2f} | {r['vt']:.2f} | {f(r['err_med'])} | {f(r['err_p90_of_med'])} | {f(r['err_cellp90'])} | {f(r['spread_med'])} (n={r['n_spread']}) | {f(r['rho_med'])} | {f(r['rho_p90'])} | {f(r['rho0_med'])} |")
add(T["by_set_class"]); L += ["", "U10 × класс (отложенные горы + новые условия П6)", ""] + L[:2]; add(T["by_u10_class_terrain_holdout"])
L += ["", "по числу итераций (сошедшиеся, горные наборы)", ""] + L[:2]; add(T["conv_by_iters"])
open(OUT / "tables.md", "w").write("\n".join(L))
print("\n".join(L)); print({k: v for k, v in T.items() if k.startswith(("conv_corr", "conv_ols", "nc_", "place_"))})
