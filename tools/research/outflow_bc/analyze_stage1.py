#!/usr/bin/env python3
"""Анализ этапа 1 outflow-bc (OBC-4): жёсткий (hard) против мягкого (soft, soft_ns) выхода.

Вход: out/cases.jsonl.gz (OB2, 720 записей), резы OB3 (~/data/outflow_bc/slices, только для рисунков).
Выход: out/summary.csv (OB2) и out/stage1/ (таблицы csv+md, results.json, рисунки png, slices_sel.h5).
  --summary-only <путь> : только summary в указанный путь (детерминированно, без matplotlib/h5py).
Запуск: uv run --no-project --with numpy --with h5py --with matplotlib --with scipy python analyze_stage1.py
"""
import argparse
import gzip
import json
import math
import os
from collections import OrderedDict
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
VARIANTS = ["hard", "soft", "soft_ns"]
U10_BINS = ["<1", "1-1.5", "1.5-2", "2-2.5", "2.5-3", ">=6"]
FR_BINS = ["<0.15", "0.15-0.3", "0.3-0.5", "0.5-1", ">1"]
HEATS = ["m", "h", "all"]
HS = [10, 50, 300]
BOUNDARY_REL = 0.05  # порог «влияния границы на решение», доля U10


def u10_bin(u):
    if u < 1:
        return "<1"
    if u < 1.5:
        return "1-1.5"
    if u < 2:
        return "1.5-2"
    if u < 2.5:
        return "2-2.5"
    if u <= 3:
        return "2.5-3"
    if u >= 6:
        return ">=6"
    return None


def fr_bin(f):
    if f < 0.15:
        return "<0.15"
    if f < 0.3:
        return "0.15-0.3"
    if f < 0.5:
        return "0.3-0.5"
    if f < 1:
        return "0.5-1"
    return ">1"


def load(path):
    with gzip.open(path, "rt") as f:
        rows = [json.loads(l) for l in f if l.strip()]
    for r in rows:
        r["hk"] = "h" if r["heat"] else "m"
        r["ub"] = u10_bin(r["u10_in"])
        r["fb"] = fr_bin(r["fr"])
    return rows


def rint(x):
    return int(math.floor(float(x) + 0.5))


def summary_rows(rows):
    out = []
    for v in VARIANTS:
        for ub in U10_BINS:
            for fb in FR_BINS:
                for hk in HEATS:
                    g = [r for r in rows if r["variant"] == v and r["ub"] == ub and r["fb"] == fb
                         and (hk == "all" or r["hk"] == hk)]
                    if not g:
                        continue
                    ok = [r for r in g if r["status"] == "ok"]
                    mx = [r for r in g if r["status"] == "max"]
                    it = [r["iters"] for r in ok]
                    sp = [r["late_spread60_p90"] for r in mx if r["late_spread60_p90"] is not None]
                    out.append([
                        v, ub, fb, hk, str(len(g)), "%.3f" % (len(ok) / len(g)),
                        str(rint(np.median(it))) if it else "",
                        str(rint(np.percentile(it, 90))) if it else "",
                        "%.4f" % np.median(sp) if sp else "",
                        "%.4f" % np.percentile(sp, 90) if sp else "",
                    ])
    return out


def write_summary(rows, path):
    hdr = "variant,u10_bin,fr_bin,heat,n,conv_frac,iters_med,iters_p90,spread_med,spread_p90"
    lines = [hdr] + [",".join(x) for x in summary_rows(rows)]
    tmp = str(path) + ".tmp"
    with open(tmp, "w", newline="") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, path)


# ---------------------------------------------------------------- таблицы
class Tab:
    def __init__(self, name, title, cols, note=""):
        self.name, self.title, self.cols, self.note = name, title, cols, note
        self.rows = []

    def add(self, *r):
        self.rows.append(["" if x is None else x for x in r])

    def save(self, d):
        with open(d / (self.name + ".csv"), "w") as f:
            f.write(",".join(self.cols) + "\n")
            for r in self.rows:
                f.write(",".join(str(x) for x in r) + "\n")
        with open(d / (self.name + ".md"), "w") as f:
            f.write("### %s\n\n" % self.title)
            if self.note:
                f.write(self.note + "\n\n")
            f.write("| " + " | ".join(self.cols) + " |\n|" + "---|" * len(self.cols) + "\n")
            for r in self.rows:
                f.write("| " + " | ".join(str(x) for x in r) + " |\n")


def fmt(x, n=3):
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return ""
    return ("%." + str(n) + "f") % x


def q(a, p):
    return float(np.percentile(a, p)) if len(a) else None


def med(a):
    return float(np.median(a)) if len(a) else None


# группы по U10: отдельные корзины + агрегаты
GROUPS = [(b, lambda r, b=b: r["ub"] == b) for b in U10_BINS] + [
    ("слабый<=3", lambda r: r["u10_in"] <= 3),
    ("сильный>=6", lambda r: r["u10_in"] >= 6),
    ("все", lambda r: True),
]


def sel(rows, v, pred, hk):
    return [r for r in rows if r["variant"] == v and pred(r) and (hk == "all" or r["hk"] == hk)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", default=str(HERE / "out/cases.jsonl.gz"))
    ap.add_argument("--summary-only")
    ap.add_argument("--out", default=str(HERE / "out"))
    ap.add_argument("--slices", default=os.path.expanduser("~/data/outflow_bc/slices"))
    ap.add_argument("--no-figs", action="store_true")
    a = ap.parse_args()
    rows = load(a.cases)
    if a.summary_only:
        write_summary(rows, a.summary_only)
        return
    out = Path(a.out)
    st = out / "stage1"
    st.mkdir(parents=True, exist_ok=True)
    write_summary(rows, out / "summary.csv")
    res = OrderedDict()
    by = {(r["case_id"], r["variant"]): r for r in rows}
    cases = sorted({r["case_id"] for r in rows})
    res["n_records"] = len(rows)
    res["n_cases"] = len(cases)

    # ---- Q1: сходимость
    t = Tab("q1_conv_u10", "Q1. Доля сходимости (status=ok) по корзинам U10",
            ["u10_bin", "heat", "variant", "n", "n_ok", "conv_frac"])
    for g, pred in GROUPS:
        for hk in HEATS:
            for v in VARIANTS:
                s = sel(rows, v, pred, hk)
                if s:
                    k = sum(r["status"] == "ok" for r in s)
                    t.add(g, hk, v, len(s), k, fmt(k / len(s)))
    t.save(st)
    t = Tab("q1_conv_fr", "Q1. Доля сходимости по корзинам Fr (слабый ветер U10<=3 и все)",
            ["set", "fr_bin", "variant", "n", "n_ok", "conv_frac"])
    for nm, pr in (("слабый<=3", lambda r: r["u10_in"] <= 3), ("все", lambda r: True)):
        for fb in FR_BINS:
            for v in VARIANTS:
                s = sel(rows, v, lambda r: pr(r) and r["fb"] == fb, "all")
                if s:
                    k = sum(r["status"] == "ok" for r in s)
                    t.add(nm, fb, v, len(s), k, fmt(k / len(s)))
    t.save(st)

    def pair_class(v, case):
        h, s = by.get((case, "hard")), by.get((case, v))
        if not h or not s:
            return None
        ho, so = h["status"] == "ok", s["status"] == "ok"
        return ("both_ok" if ho and so else "ok_to_max" if ho else "max_to_ok" if so else "both_max")

    t = Tab("q1_paired", "Q1. Парное сравнение с hard по тем же случаям",
            ["pair", "u10_bin", "heat", "n", "both_ok", "ok_to_max", "max_to_ok", "both_max", "net"],
            "ok_to_max: hard ok, вариант max; max_to_ok: hard max, вариант ok; net = max_to_ok - ok_to_max.")
    pair_tot = {}
    for v in ["soft", "soft_ns"]:
        for g, pred in GROUPS:
            for hk in HEATS:
                cs = [r["case_id"] for r in sel(rows, v, pred, hk)]
                cl = [pair_class(v, c) for c in cs]
                if not cl:
                    continue
                cnt = {k: cl.count(k) for k in ["both_ok", "ok_to_max", "max_to_ok", "both_max"]}
                t.add("hard->" + v, g, hk, len(cl), cnt["both_ok"], cnt["ok_to_max"], cnt["max_to_ok"],
                      cnt["both_max"], cnt["max_to_ok"] - cnt["ok_to_max"])
                pair_tot[(v, g, hk)] = cnt
    t.save(st)
    # знаковый тест (двусторонний, точный) для слабого ветра
    from scipy.stats import binomtest
    res["q1"] = OrderedDict()
    for v in ["soft", "soft_ns"]:
        cnt = pair_tot[(v, "слабый<=3", "all")]
        nd = cnt["ok_to_max"] + cnt["max_to_ok"]
        p = binomtest(cnt["max_to_ok"], nd, 0.5).pvalue if nd else 1.0
        wk = [r for r in rows if r["u10_in"] <= 3]
        n_w = sum(r["variant"] == "hard" for r in wk)
        cf = {x: sum(r["status"] == "ok" for r in wk if r["variant"] == x) / n_w for x in VARIANTS}
        res["q1"][v] = dict(weak_pairs=cnt, sign_test_p=p, conv_weak=cf, n_weak=n_w,
                            delta_conv=cf[v] - cf["hard"], delta_cases=cnt["max_to_ok"] - cnt["ok_to_max"])

    # ---- Q2: итерации и разброс
    t = Tab("q2_iters", "Q2. Итерации сошедшихся (ok)",
            ["u10_bin", "heat", "variant", "n_ok", "iters_med", "iters_p90"])
    for g, pred in GROUPS:
        for hk in HEATS:
            for v in VARIANTS:
                ok = [r["iters"] for r in sel(rows, v, pred, hk) if r["status"] == "ok"]
                if ok:
                    t.add(g, hk, v, len(ok), rint(med(ok)), rint(q(ok, 90)))
    t.save(st)
    t = Tab("q2_iters_ratio", "Q2. Отношение итераций variant/hard на both_ok",
            ["variant", "u10_bin", "heat", "n_both_ok", "ratio_med", "ratio_p10", "ratio_p90", "iters_hard_med",
             "iters_var_med"])
    ratio_store = {}
    for v in ["soft", "soft_ns"]:
        for g, pred in GROUPS:
            for hk in HEATS:
                s = [r for r in sel(rows, v, pred, hk) if r["both_ok"]]
                if not s:
                    continue
                rt = [r["iters"] / by[(r["case_id"], "hard")]["iters"] for r in s]
                ratio_store[(v, g, hk)] = rt
                t.add(v, g, hk, len(s), fmt(med(rt)), fmt(q(rt, 10)), fmt(q(rt, 90)),
                      rint(med([by[(r["case_id"], "hard")]["iters"] for r in s])), rint(med([r["iters"] for r in s])))
    t.save(st)
    t = Tab("q2_spread", "Q2. late_spread60_p90 несошедшихся (status=max), м/с и доля U10",
            ["u10_bin", "heat", "variant", "n_max", "spread_med", "spread_p90", "spread_med_rel_u10",
             "spread_p90_rel_u10"])
    for g, pred in GROUPS:
        for hk in HEATS:
            for v in VARIANTS:
                s = [r for r in sel(rows, v, pred, hk) if r["status"] == "max" and r["late_spread60_p90"] is not None]
                if s:
                    sp = [r["late_spread60_p90"] for r in s]
                    rl = [r["late_spread60_p90"] / r["u10_in"] for r in s]
                    t.add(g, hk, v, len(s), fmt(med(sp), 4), fmt(q(sp, 90), 4), fmt(med(rl), 3), fmt(q(rl, 90), 3))
    t.save(st)
    # парно: на max_both разброс soft против hard
    t = Tab("q2_spread_paired", "Q2. Разброс на парах both_max (слабый ветер): variant против hard",
            ["variant", "n_both_max", "spread_hard_med", "spread_var_med", "ratio_med", "var_less_than_hard"])
    for v in ["soft", "soft_ns"]:
        s = [r for r in rows if r["variant"] == v and r["u10_in"] <= 3 and pair_class(v, r["case_id"]) == "both_max"]
        hh = [by[(r["case_id"], "hard")]["late_spread60_p90"] for r in s]
        vv = [r["late_spread60_p90"] for r in s]
        rr = [b / a for a, b in zip(hh, vv) if a]
        t.add(v, len(s), fmt(med(hh), 4), fmt(med(vv), 4), fmt(med(rr), 3), sum(b < a for a, b in zip(hh, vv)))
        res["q2_spread_paired_" + v] = dict(n=len(s), hard_med=med(hh), var_med=med(vv), ratio_med=med(rr),
                                            var_less=int(sum(b < a for a, b in zip(hh, vv))))
    t.save(st)

    # ---- Q3: поле внутри (both_ok)
    def dstats(vals):
        return [len(vals), fmt(med(vals), 4), fmt(q(vals, 90), 4), fmt(max(vals) if vals else None, 4)]

    t = Tab("q3_field", "Q3. |Δ(u,v)| variant−hard на both_ok, м/с: медиана / p90 / максимум по случаям",
            ["variant", "set", "h_m", "metric", "n", "med", "p90", "max"])
    bound = OrderedDict()
    for v in ["soft", "soft_ns"]:
        for nm, pr in (("слабый<=3", lambda r: r["u10_in"] <= 3), ("сильный>=6", lambda r: r["u10_in"] >= 6)):
            s = [r for r in rows if r["variant"] == v and r["both_ok"] and pr(r)]
            for h in HS:
                for m in ["d_start_%d_max", "d_int_%d_rms", "d_int_%d_p99", "d_int_%d_max", "d_band_%d_max",
                          "d_int_%d_max_rel"]:
                    key = m % h
                    vals = [r[key] for r in s if r[key] is not None]
                    t.add(v, nm, h, key, *dstats(vals))
        # влияние границы: d_int_h_max_rel > 0.05
        for h in HS:
            key = "d_int_%d_max_rel" % h
            s = [r for r in rows if r["variant"] == v and r["both_ok"] and r[key] is not None]
            hit = sorted(r["case_id"] for r in s if r[key] > BOUNDARY_REL)
            bound["%s_%d" % (v, h)] = dict(n_both_ok=len(s), n_over=len(hit), cases=hit,
                                            n_over_weak=sum(1 for r in s if r[key] > BOUNDARY_REL and r["u10_in"] <= 3),
                                            n_over_strong=sum(1 for r in s if r[key] > BOUNDARY_REL and r["u10_in"] >= 6))
    t.save(st)
    t = Tab("q3_by_u10", "Q3. d_int_50_max_rel и d_int_50_rms на both_ok по корзинам U10",
            ["variant", "u10_bin", "n_both_ok", "rel_med", "rel_p90", "rel_max", "rms_med", "n_rel_gt_0.05"])
    for v in ["soft", "soft_ns"]:
        for g, pred in GROUPS[:-1]:
            s = [r for r in sel(rows, v, pred, "all") if r["both_ok"]]
            if s:
                rl = [r["d_int_50_max_rel"] for r in s]
                t.add(v, g, len(s), fmt(med(rl), 4), fmt(q(rl, 90), 4), fmt(max(rl), 4),
                      fmt(med([r["d_int_50_rms"] for r in s]), 4), sum(x > BOUNDARY_REL for x in rl))
    t.save(st)
    t = Tab("q3_rel_places", "Q3. Относительные меры на 50 м (both_ok): rms/U10, p99/U10, start/U10; число случаев > 0,05",
            ["variant", "set", "place", "n_both_ok", "rms_rel_med", "p99_rel_med", "start_rel_med", "n_max_rel_gt",
             "n_rms_rel_gt", "n_p99_rel_gt", "n_start_rel_gt"])
    for v in ["soft", "soft_ns"]:
        for nm, pr in (("слабый<=3", lambda r: r["u10_in"] <= 3), ("сильный>=6", lambda r: r["u10_in"] >= 6)):
            for pl in ["все"] + sorted({r["place"] for r in rows}):
                s = [r for r in rows if r["variant"] == v and r["both_ok"] and pr(r) and (pl == "все" or r["place"] == pl)]
                if not s:
                    continue
                rms = [r["d_int_50_rms"] / r["u10_in"] for r in s]
                p99 = [r["d_int_50_p99"] / r["u10_in"] for r in s]
                stt = [r["d_start_50_max"] / r["u10_in"] for r in s]
                t.add(v, nm, pl, len(s), fmt(med(rms), 4), fmt(med(p99), 4), fmt(med(stt), 4),
                      sum(r["d_int_50_max_rel"] > BOUNDARY_REL for r in s), sum(x > BOUNDARY_REL for x in rms),
                      sum(x > BOUNDARY_REL for x in p99), sum(x > BOUNDARY_REL for x in stt))
    t.save(st)
    res["q3_boundary_influence"] = bound
    with open(st / "q3_boundary_cases.txt", "w") as f:
        for k, d in bound.items():
            f.write("%s: %d из %d (слабый %d, сильный %d)\n" % (k, d["n_over"], d["n_both_ok"], d["n_over_weak"],
                                                                d["n_over_strong"]))
            for c in d["cases"]:
                f.write("  " + c + "\n")

    # ---- Q4: сильный ветер
    t = Tab("q4_strong", "Q4. Сильный ветер (U10 = 6, 9): сходимость, итерации, d_int_max_rel",
            ["u10_in", "variant", "n", "n_ok", "iters_med", "iters_p90", "rel10_max", "rel50_max", "rel300_max",
             "rel50_med"])
    for u in [6.0, 9.0]:
        for v in VARIANTS:
            s = [r for r in rows if r["variant"] == v and r["u10_in"] == u]
            ok = [r for r in s if r["status"] == "ok"]
            bo = [r for r in s if r["both_ok"]]
            m = lambda k: fmt(max([r[k] for r in bo]), 4) if bo else ""
            t.add(u, v, len(s), len(ok), rint(med([r["iters"] for r in ok])) if ok else "",
                  rint(q([r["iters"] for r in ok], 90)) if ok else "", m("d_int_10_max_rel"), m("d_int_50_max_rel"),
                  m("d_int_300_max_rel"), fmt(med([r["d_int_50_max_rel"] for r in bo]), 4) if bo else "")
    t.save(st)
    ns_fail = sorted(r["case_id"] for r in rows if r["variant"] == "soft_ns" and r["u10_in"] >= 6
                     and r["status"] != "ok")
    t = Tab("q4_soft_ns_fail", "Q4. Несошедшиеся soft_ns на сильном ветре и те же случаи у hard/soft",
            ["case_id", "u10_in", "variant", "status", "iters", "late_spread60_p90", "spread_rel_u10", "fr"])
    for c in ns_fail:
        for v in VARIANTS:
            r = by[(c, v)]
            sp = r["late_spread60_p90"]
            t.add(c, r["u10_in"], v, r["status"], r["iters"], fmt(sp, 4), fmt(sp / r["u10_in"], 4) if sp is not None else "",
                  fmt(r["fr"], 3))
    t.save(st)
    res["q4"] = dict(soft_ns_fail=ns_fail,
                     strong_all_ok={v: all(r["status"] == "ok" for r in rows if r["variant"] == v and r["u10_in"] >= 6)
                                    for v in VARIANTS})

    # ---- Q5: у выхода
    t = Tab("q5_edge", "Q5. Поле у выхода (полоса 5 клеток у граней выхода)",
            ["u10_bin", "variant", "n", "un10_med", "un50_med", "un300_med", "back10_mean", "back50_mean",
             "back300_mean", "backflow_faces_med", "backflow_faces_max"])
    for g, pred in GROUPS:
        for v in VARIANTS:
            s = sel(rows, v, pred, "all")
            if not s:
                continue
            bf = [r["backflow_faces"] for r in s if r["backflow_faces"] is not None]
            t.add(g, v, len(s), *[fmt(med([r["edge_out_%d_un_mean" % h] for r in s if r["edge_out_%d_un_mean" % h] is not None]), 3) for h in HS],
                  *[fmt(float(np.mean([r["edge_out_%d_back_frac" % h] for r in s if r["edge_out_%d_back_frac" % h] is not None])), 4) for h in HS],
                  rint(med(bf)) if bf else "", max(bf) if bf else "")
    t.save(st)
    t = Tab("q5_edge_paired", "Q5. Парная разность variant−hard у выхода (both_ok, слабый ветер)",
            ["variant", "set", "n", "d_un10_med", "d_un50_med", "d_back10_med", "d_back50_med", "d_back300_med",
             "n_back50_less", "n_back50_more"])
    for v in ["soft", "soft_ns"]:
        for nm, cond in (("both_ok слабый", lambda r: r["both_ok"] and r["u10_in"] <= 3),
                         ("max_to_ok слабый", lambda r: r["u10_in"] <= 3 and pair_class(v, r["case_id"]) == "max_to_ok"),
                         ("both_ok сильный", lambda r: r["both_ok"] and r["u10_in"] >= 6)):
            s = [r for r in rows if r["variant"] == v and cond(r)]
            if not s:
                continue
            dd = lambda key: [r[key] - by[(r["case_id"], "hard")][key] for r in s]
            b50 = dd("edge_out_50_back_frac")
            t.add(v, nm, len(s), fmt(med(dd("edge_out_10_un_mean")), 4), fmt(med(dd("edge_out_50_un_mean")), 4),
                  fmt(med(dd("edge_out_10_back_frac")), 4), fmt(med(b50), 4), fmt(med(dd("edge_out_300_back_frac")), 4),
                  sum(x < -1e-9 for x in b50), sum(x > 1e-9 for x in b50))
    t.save(st)
    # корреляция: d_band и d_int (отражение от выхода), flux_net_max_rel
    t = Tab("q5_flux", "Q5. Невязка потока мягкого выхода (OutflowDiag)",
            ["variant", "n", "faces_out_med", "flux_net_max_rel_med", "flux_net_max_rel_max"])
    for v in ["soft", "soft_ns"]:
        s = [r for r in rows if r["variant"] == v and r["flux_net_max_rel"] is not None]
        t.add(v, len(s), rint(med([r["faces_out"] for r in s])), "%.2e" % med([r["flux_net_max_rel"] for r in s]),
              "%.2e" % max(r["flux_net_max_rel"] for r in s))
    t.save(st)

    # ---- время
    t = Tab("time", "Время решения t_solve_s (все случаи, включая несошедшиеся)",
            ["u10_bin", "variant", "n", "sum_h", "med_s", "med_ok_s", "med_max_s"])
    for g, pred in GROUPS:
        for v in VARIANTS:
            s = sel(rows, v, pred, "all")
            if s:
                t.add(g, v, len(s), fmt(sum(r["t_solve_s"] for r in s) / 3600, 2), fmt(med([r["t_solve_s"] for r in s]), 1),
                      fmt(med([r["t_solve_s"] for r in s if r["status"] == "ok"]), 1),
                      fmt(med([r["t_solve_s"] for r in s if r["status"] == "max"]), 1))
    t.save(st)

    # ---- правило рекомендации
    wk = {v: [r for r in rows if r["variant"] == v and r["u10_in"] <= 3] for v in VARIANTS}
    okw = {v: sum(r["status"] == "ok" for r in wk[v]) for v in VARIANTS}
    rule = OrderedDict()
    for v in ["soft", "soft_ns"]:
        bo = [r["d_int_50_max_rel"] for r in wk[v] if r["both_ok"]]
        c1 = (okw[v] - okw["hard"]) >= 9
        c2 = res["q4"]["strong_all_ok"][v]
        c3 = med(bo) <= 0.05
        rule[v] = dict(ok_weak=okw[v], ok_weak_hard=okw["hard"], n_weak=len(wk[v]), delta_cases=okw[v] - okw["hard"],
                       delta_frac=(okw[v] - okw["hard"]) / len(wk[v]), cond1_conv_plus_0p05=c1,
                       cond2_strong_all_ok=c2, d_int_50_max_rel_med_both_ok_weak=med(bo), cond3_median_le_0p05=c3,
                       passes=bool(c1 and c2 and c3))
    res["rule"] = rule
    res["recommendation"] = "soft" if rule["soft"]["passes"] else "hard"
    with open(st / "results.json", "w") as f:
        json.dump(res, f, ensure_ascii=False, indent=1, default=float)

    if not a.no_figs:
        figures(rows, by, st, a.slices, res)
    print("ok: рекомендация =", res["recommendation"])


def figures(rows, by, st, slices_dir, res):
    import h5py
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    col = {"hard": "#1f77b4", "soft": "#d95f02", "soft_ns": "#7570b3"}
    # 1. доля сходимости по корзинам U10
    fig, ax = plt.subplots(1, 2, figsize=(9, 3.6), sharey=True)
    for i, hk in enumerate(["m", "h"]):
        for j, v in enumerate(VARIANTS):
            ys = []
            for b in U10_BINS:
                s = [r for r in rows if r["variant"] == v and r["ub"] == b and r["hk"] == hk]
                ys.append(sum(r["status"] == "ok" for r in s) / len(s))
            ax[i].bar(np.arange(len(U10_BINS)) + (j - 1) * 0.27, ys, 0.27, label=v, color=col[v])
        ax[i].set_xticks(range(len(U10_BINS)))
        ax[i].set_xticklabels(U10_BINS)
        ax[i].set_title("механика" if hk == "m" else "с нагревом")
        ax[i].set_xlabel("U10, м/с")
    ax[0].set_ylabel("доля сходимости")
    ax[0].legend()
    fig.tight_layout()
    fig.savefig(st / "fig1_conv_u10.png", dpi=130)
    plt.close(fig)
    # 2. отношение итераций
    fig, ax = plt.subplots(figsize=(6, 3.6))
    data, lab = [], []
    for b in U10_BINS:
        d = [r["iters"] / by[(r["case_id"], "hard")]["iters"] for r in rows if r["variant"] == "soft" and r["ub"] == b and r["both_ok"]]
        if d:
            data.append(d)
            lab.append("%s\n(n=%d)" % (b, len(d)))
    ax.boxplot(data); ax.set_xticklabels(lab)
    ax.axhline(1, color="gray", lw=0.8)
    ax.set_ylabel("iters soft / hard (both_ok)")
    ax.set_xlabel("U10, м/с")
    fig.tight_layout()
    fig.savefig(st / "fig2_iters_ratio.png", dpi=130)
    plt.close(fig)
    # 3. распределение d_int_50_max_rel
    fig, ax = plt.subplots(figsize=(6, 3.6))
    bins = np.logspace(-4, 0.5, 40)
    for v in ["soft", "soft_ns"]:
        d = [r["d_int_50_max_rel"] for r in rows if r["variant"] == v and r["both_ok"] and r["d_int_50_max_rel"] and r["d_int_50_max_rel"] > 0]
        ax.hist(d, bins=bins, alpha=0.6, label="%s (n=%d)" % (v, len(d)), color=col[v])
    ax.axvline(BOUNDARY_REL, color="k", ls="--", lw=0.8)
    ax.set_xscale("log")
    ax.set_xlabel("d_int_50_max_rel = max|Δ(u,v)| внутри / U10")
    ax.set_ylabel("случаев")
    ax.legend()
    fig.tight_layout()
    fig.savefig(st / "fig3_d_int50_rel.png", dpi=130)
    plt.close(fig)
    # 4. карты |Δ(u,v)| soft − hard на 50 м
    bo = [r for r in rows if r["variant"] == "soft" and r["both_ok"] and r["d_int_50_max_rel"] is not None]
    weak = sorted([r for r in bo if r["u10_in"] <= 3], key=lambda r: (r["d_int_50_max_rel"], r["case_id"]))
    strong = sorted([r for r in bo if r["u10_in"] >= 6], key=lambda r: (r["d_int_50_max_rel"], r["case_id"]))
    picks = [("наибольший d_int_50_max_rel (слабый)", weak[-1]), ("типичный слабый (медиана)", weak[len(weak) // 2]),
             ("сильный (наибольший)", strong[-1])]
    sdir = Path(slices_dir)
    maps = []
    tmp = st / "slices_sel.h5.tmp"
    with h5py.File(tmp, "w") as hf:
        for _, r in picks:
            pair = []
            for v in ["hard", "soft"]:
                meta = json.load(open(sdir / ("%s__%s.json" % (r["case_id"], v))))
                nx, ny = meta["nx"], meta["ny"]
                arr = np.fromfile(sdir / ("%s__%s.bin" % (r["case_id"], v)), dtype="<f4").reshape(3, 3, ny, nx)
                pair.append(arr)
                key = "%s__%s" % (r["case_id"], v)
                if key not in hf:
                    ds = hf.create_dataset(key, data=arr.astype(np.float16), compression="gzip", chunks=(1, 3, ny, nx))
                    ds.attrs.update(nx=nx, ny=ny, dx_m=meta["dx_m"], agl_m=np.array(meta["agl_m"], dtype=np.float32),
                                    comps=np.array(meta["comps"], dtype="S1"), case_id=r["case_id"], variant=v)
            d = np.hypot(pair[1][1, 0] - pair[0][1, 0], pair[1][1, 1] - pair[0][1, 1])
            maps.append((r, d, meta["dx_m"]))
    os.replace(tmp, st / "slices_sel.h5")
    fig, ax = plt.subplots(1, 3, figsize=(13, 4))
    info = []
    for a_, (title, r), (_, d, dx) in zip(ax, picks, maps):
        im = a_.imshow(d, origin="lower", cmap="magma", extent=[0, d.shape[1] * dx / 1000, 0, d.shape[0] * dx / 1000])
        a_.set_title("%s\n%s U10=%g" % (title, r["case_id"], r["u10_in"]), fontsize=8)
        a_.set_xlabel("x, км")
        plt.colorbar(im, ax=a_, label="|Δ(u,v)|, м/с")
        info.append(dict(case_id=r["case_id"], u10_in=r["u10_in"], d_int_50_max_rel=r["d_int_50_max_rel"],
                         map_max=float(d.max()), map_med=float(np.median(d)), map_p99=float(np.percentile(d, 99))))
    fig.tight_layout()
    fig.savefig(st / "fig4_maps_dsoft_hard_50m.png", dpi=130)
    plt.close(fig)
    res["fig4_maps"] = info
    with open(st / "results.json", "w") as f:
        json.dump(res, f, ensure_ascii=False, indent=1, default=float)


if __name__ == "__main__":
    main()
