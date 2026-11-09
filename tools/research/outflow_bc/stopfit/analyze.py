#!/usr/bin/env python3
"""Таблицы по stop.csv + cases.jsonl.gz -> analysis.json, tables.md (детерминированно)."""
import argparse, csv, gzip, json, collections
import numpy as np

BINS = [("<1", 0, 1), ("1-1.5", 1, 1.5), ("1.5-2", 1.5, 2), ("2-2.5", 2, 2.5), ("2.5-3", 2.5, 3), (">=6", 6, 1e9)]
THR = {"mom": 1e-4, "th": 2.5e-6, "div": 5e-6}


def bin_of(u):
    for n, lo, hi in BINS:
        if lo <= u < hi:
            return n


def load(path):
    rows = list(csv.DictReader(open(path)))
    for r in rows:
        r["iters"] = int(r["iters"]); r["W"] = int(r["W"]); r["eps"] = float(r["eps"]); r["u10_in"] = float(r["u10_in"])
        r["k"] = int(r["k_stop"]) if r["k_stop"] else None
    return rows


def med(x):
    return float(np.median(x)) if len(x) else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", required=True); ap.add_argument("--stop", required=True)
    ap.add_argument("--aux", required=True); ap.add_argument("--W", type=int, default=100); ap.add_argument("--eps", type=float, default=0.1); ap.add_argument("--outdir", required=True)
    a = ap.parse_args()
    recs = {(r["case_id"], r["variant"]): r for r in (json.loads(l) for l in gzip.open(a.cases, "rt"))}
    S = load(a.stop)
    out = {}
    # сетка: по (W,eps): на ok - доля conv-остановок не позже/раньше фактической, ложные plateau; на max - доля остановок
    grid = []
    for W in (50, 100, 200):
        for eps in (0.05, 0.1, 0.2):
            sel = [r for r in S if r["W"] == W and r["eps"] == eps]
            ok = [r for r in sel if r["status"] == "ok"]; mx = [r for r in sel if r["status"] == "max"]
            okst = [r for r in ok if r["k"] is not None]
            early = [r for r in okst if r["k"] < r["iters"]]
            early_pl = [r for r in early if r["reason"] == "plateau"]
            early_cv = [r for r in early if r["reason"] == "conv"]
            mst = [r for r in mx if r["k"] is not None]
            g = dict(W=W, eps=eps, n_ok=len(ok), n_max=len(mx),
                     ok_early=len(early), ok_early_plateau=len(early_pl), ok_early_conv=len(early_cv),
                     ok_save_total=int(sum(r["iters"] - r["k"] for r in early)), ok_iters_total=int(sum(r["iters"] for r in ok)),
                     ok_early_med_frac=med([r["k"] / r["iters"] for r in early]),
                     max_stopped=len(mst), max_conv=sum(r["reason"] == "conv" for r in mst),
                     max_plateau=sum(r["reason"] == "plateau" for r in mst),
                     max_k_med=med([r["k"] for r in mst]), max_save_total=int(sum(1000 - r["k"] for r in mst)),
                     max_susp=sum(1 for r in mst if recs[(r["case_id"], r["variant"])]["late_spread60_p90"] > 0.1 * r["u10_in"]))
            grid.append(g)
    out["grid"] = grid
    A = load(a.aux)
    W0, E0 = a.W, a.eps
    sel = {(r["case_id"], r["variant"]): r for r in S if r["W"] == W0 and r["eps"] == E0}
    selaux = collections.defaultdict(dict)
    for r in A:
        if r["W"] == W0 and r["eps"] == E0:
            selaux[(r["case_id"], r["variant"])][r["res"]] = r
    # по корзинам U10 x вариант
    tab = []
    for b, _, _ in BINS:
        for v in ("hard", "soft", "soft_ns"):
            ks = [k for k, r in sel.items() if r["variant"] == v and bin_of(r["u10_in"]) == b]
            ok = [sel[k] for k in ks if sel[k]["status"] == "ok"]
            mx = [sel[k] for k in ks if sel[k]["status"] == "max"]
            e = [r for r in ok if r["k"] is not None and r["k"] < r["iters"]]
            m = [r for r in mx if r["k"] is not None]
            tab.append(dict(bin=b, variant=v, n_ok=len(ok), n_max=len(mx),
                            ok_early=len(e), ok_early_plateau=sum(r["reason"] == "plateau" for r in e),
                            ok_iters_med=med([r["iters"] for r in ok]), ok_k_med=med([r["k"] for r in e]),
                            ok_save_med=med([r["iters"] - r["k"] for r in e]),
                            ok_save_frac=(sum(r["iters"] - r["k"] for r in e) / sum(r["iters"] for r in ok)) if ok else None,
                            max_stopped=len(m), max_conv=sum(r["reason"] == "conv" for r in m),
                            max_k_med=med([r["k"] for r in m]), max_save_med=med([1000 - r["k"] for r in m]),
                            max_save_frac=(sum(1000 - r["k"] for r in m) / (1000 * len(mx))) if mx else None,
                            max_susp=sum(1 for r in m if recs[(r["case_id"], r["variant"])]["late_spread60_p90"] > 0.1 * r["u10_in"])))
    out["bins"] = tab
    # плато: на каком уровне над порогом, по max
    lv = [r["r_at_stop"] and float(r["r_at_stop"]) / THR["mom"] for r in sel.values() if r["status"] == "max" and r["k"] is not None]
    lv = [float(x) for x in lv if x]
    out["max_plateau_level_over_thr_pctl"] = [float(np.percentile(lv, q)) for q in (0, 25, 50, 75, 100)] if lv else None
    # по трём невязкам: стоп = все три остановились; k = max
    allst = []
    for k, r in sel.items():
        if r["status"] != "max":
            continue
        rs = [r] + list(selaux[k].values())
        if any(x["k"] is None for x in rs):
            allst.append((k, None, None)); continue
        allst.append((k, max(x["k"] for x in rs), "conv" if all(x["reason"] == "conv" for x in rs) else "plateau"))
    out["max_all3"] = dict(n=len(allst), stopped=sum(1 for x in allst if x[1] is not None),
                           conv=sum(1 for x in allst if x[2] == "conv"),
                           k_med=med([x[1] for x in allst if x[1] is not None]))
    okall = []
    for k, r in sel.items():
        if r["status"] != "ok":
            continue
        rs = [r] + list(selaux[k].values())
        okall.append((k, None if any(x["k"] is None for x in rs) else max(x["k"] for x in rs), r["iters"]))
    out["ok_all3"] = dict(n=len(okall), stopped=sum(1 for x in okall if x[1] is not None),
                          early=sum(1 for x in okall if x[1] is not None and x[1] < x[2]),
                          late_or_none=sum(1 for x in okall if x[1] is None or x[1] >= x[2]))
    # какая невязка держит стоп у max (не остановилась)
    hold = collections.Counter()
    for k, r in sel.items():
        if r["status"] == "max":
            hold[tuple(sorted(nm for nm, x in [("mom", r)] + list(selaux[k].items()) if x["k"] is None))] += 1
    out["max_unstopped_residuals"] = {"+".join(k) or "-": v for k, v in hold.items()}
    # PR-8-подобный класс: mom-остановка, а th/div выше порога и/или поле блуждает
    pr8 = []
    for k, r in sel.items():
        if r["status"] == "max" and r["k"] is not None:
            rec = recs[k]
            h = np.array(rec["res_hist"])
            last = h[-10:]
            pr8.append(dict(case=k[0], variant=k[1], reason=r["reason"], k=r["k"],
                            mom_over_thr=float(np.median(last[:, 1])) / THR["mom"],
                            th_over_thr=float(np.median(last[:, 3])) / THR["th"],
                            div_over_thr=float(np.median(last[:, 5])) / THR["div"],
                            spread_rel=rec["late_spread60_p90"] / r["u10_in"]))
    pr8.sort(key=lambda x: x["case"] + x["variant"])
    out["pr8_like_min_mom_over_thr_last100"] = min((x["mom_over_thr"] for x in pr8), default=None)
    out["max_stopped_list_n"] = len(pr8)
    # детали ok-ранних остановок
    eo = [r for r in sel.values() if r["status"] == "ok" and r["k"] is not None and r["k"] < r["iters"]]
    def q(x):
        return [float(np.percentile(x, t)) for t in (0, 25, 50, 75, 100)] if x else None
    out["ok_early_r_over_thr"] = q([float(r["r_at_stop"]) / THR["mom"] for r in eo])
    out["ok_early_k_over_iters"] = q([r["k"] / r["iters"] for r in eo])
    ep = [r for r in eo if r["reason"] == "plateau"]
    out["ok_early_plateau_detail"] = dict(n=len(ep), r_over_thr=q([float(r["r_at_stop"]) / THR["mom"] for r in ep]),
                                           lost_iters=q([r["iters"] - r["k"] for r in ep]))
    ec = [r for r in eo if r["reason"] == "conv"]
    out["ok_early_conv_detail"] = dict(n=len(ec), r_over_thr=q([float(r["r_at_stop"]) / THR["mom"] for r in ec]),
                                        saved=q([r["iters"] - r["k"] for r in ec]), k=q([r["k"] for r in ec]))
    out["ok_n_with_full_window"] = sum(1 for r in sel.values() if r["status"] == "ok" and r["iters"] >= W0 + 10)
    # max: когда-либо mom ниже порога?
    dip = [k for k, r in recs.items() if r["status"] == "max" and min(c[1] for c in r["res_hist"]) < THR["mom"]]
    out["max_mom_ever_below_thr"] = len(dip)
    out["max_mom_min_over_thr"] = float(min(min(c[1] for c in r["res_hist"]) for r in recs.values() if r["status"] == "max") / THR["mom"])
    mst = [r for r in sel.values() if r["status"] == "max" and r["k"] is not None]
    out["max_rho_pctl"] = q([float(r["rho"]) for r in mst if r["rho"]])
    out["max_susp_frac_by_reason"] = {rs: [sum(1 for r in mst if r["reason"] == rs and recs[(r["case_id"], r["variant"])]["late_spread60_p90"] > 0.1 * r["u10_in"]), sum(1 for r in mst if r["reason"] == rs)] for rs in ("conv", "plateau")}
    sp = [recs[(r["case_id"], r["variant"])]["late_spread60_p90"] / r["u10_in"] for r in mst]
    out["max_spread_over_u10"] = q(sp)
    def rk(v):
        o = np.argsort(np.argsort(np.array(v)))
        return o.astype(float)
    xr = [float(r["r_at_stop"]) for r in mst]
    out["max_spearman_rstop_vs_spread_rel"] = float(np.corrcoef(rk(xr), rk(sp))[0, 1])
    out["max_low_spread_stopped"] = sum(1 for v in sp if v <= 0.1)
    out["ok_slow_iters_total"] = sum(r["iters"] for r in sel.values() if r["status"] == "ok" and r["iters"] >= W0 + 10)
    mc = [r for r in mst if r["reason"] == "conv"]
    out["max_conv_detail"] = dict(n=len(mc), r_over_thr=q([float(r["r_at_stop"]) / THR["mom"] for r in mc]),
                                  rho_at_bound=sum(1 for r in mc if float(r["rho"]) >= 0.99),
                                  r_gt_3thr=sum(1 for r in mc if float(r["r_at_stop"]) > 3 * THR["mom"]),
                                  r_gt_10thr=sum(1 for r in mc if float(r["r_at_stop"]) > 10 * THR["mom"]))
    ec2 = [r for r in sel.values() if r["status"] == "ok" and r["k"] is not None and r["k"] < r["iters"] and r["reason"] == "conv"]
    out["ok_conv_guard3"] = sum(1 for r in ec2 if float(r["r_at_stop"]) <= 3 * THR["mom"])
    def fm(x, d=0):
        return "-" if x is None else (f"{x:.{d}f}")
    with open(a.outdir + "/tables.md", "w") as ft:
        ft.write("| W | eps | ok: ранних | из них plateau | ok: экономия, итер | max: остановлено из 259 | conv | plateau | k_stop мед | max: экономия, итер | max: стоп при spread>0,1 U10 |\n|--|--|--|--|--|--|--|--|--|--|--|\n")
        for g in grid:
            ft.write(f"| {g['W']} | {g['eps']:g} | {g['ok_early']} | {g['ok_early_plateau']} | {g['ok_save_total']} | {g['max_stopped']} | {g['max_conv']} | {g['max_plateau']} | {fm(g['max_k_med'])} | {g['max_save_total']} | {g['max_susp']} |\n")
        ft.write("\n| U10 | вариант | ok n | ok ранних (plateau) | ok k мед / экономия мед | ok экономия, доля итераций | max n | max остановлено (conv) | max k мед | max экономия мед (доля от 1000) | max susp |\n|--|--|--|--|--|--|--|--|--|--|--|\n")
        for t in tab:
            ft.write(f"| {t['bin']} | {t['variant']} | {t['n_ok']} | {t['ok_early']} ({t['ok_early_plateau']}) | {fm(t['ok_k_med'])} / {fm(t['ok_save_med'])} | {fm(100*(t['ok_save_frac'] or 0))} % | {t['n_max']} | {t['max_stopped']} ({t['max_conv']}) | {fm(t['max_k_med'])} | {fm(t['max_save_med'])} ({fm(100*t['max_save_frac']) if t['max_save_frac'] is not None else '-'} %) | {t['max_susp']} |\n")
    json.dump(out, open(a.outdir + "/analysis.json", "w"), indent=1, sort_keys=True)
    with open(a.outdir + "/max_stopped.csv", "w") as fo:
        fo.write("case_id,variant,reason,k_stop,mom_over_thr,th_over_thr,div_over_thr,spread60_p90_over_u10\n")
        for x in pr8:
            fo.write(f"{x['case']},{x['variant']},{x['reason']},{x['k']},{x['mom_over_thr']:.3f},{x['th_over_thr']:.3f},{x['div_over_thr']:.3f},{x['spread_rel']:.4f}\n")
    print(json.dumps(out, indent=0, sort_keys=True))


if __name__ == "__main__":
    main()
