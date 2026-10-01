#!/usr/bin/env python3
"""air-start AS-1: ветер над стартом до/после подстройки притока поля под старт (два прохода).

«До» — out/before (WPC-2, 576550e: код = main 1.0.0), «после» — out/after (этот прогон wind_audit).
Над стартом (offset 0): горизонталь U (u_h) на 1,5/10/50/100/200 м над землёй и отношение к ветру
меню; направление на 10 м относительно меню (°): до — |угол| из u_along/u_h, после — со знаком
(+ — к правой руке пилота, смотрящего в ветер); k притока и U₁ (проход 1) — из meta solver_info.
Рядом аналитика (не должна меняться) и отношение поле/аналитика выше 10 м.
Запуск: python3 compare.py [папка «после», по умолчанию after] → out/compare_<папка>.md, .csv;
аналитика «после» — всегда из out/after.
"""
import csv
import json
import math
import os
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
AGLS = [1.5, 10.0, 50.0, 100.0, 200.0]
WINDS = [3.0, 6.0, 10.0]


def load(tag):
    d = os.path.join(OUT, tag)
    rows = defaultdict(dict)
    for r in csv.DictReader(open(os.path.join(d, "wind_profile.csv"))):
        if float(r["offset_m"]) != 0.0:
            continue
        k = (r["location"], r["start"], r["mode"], float(r["wind_set_ms"]))
        rows[k][float(r["agl_m"])] = r
    meta = {}
    for line in open(os.path.join(d, "wind_profile_meta.jsonl")):
        m = json.loads(line)
        meta[(m["location"], m["start"], m["mode"], float(m["wind_set_ms"]))] = m
    return rows, meta


def direction(r):
    uh, ua = float(r["u_h_ms"]), float(r["u_along_ms"])
    if r.get("u_cross_ms") not in (None, ""):
        return math.degrees(math.atan2(float(r["u_cross_ms"]), ua))
    return math.degrees(math.acos(max(-1.0, min(1.0, ua / uh)))) if uh > 1e-6 else float("nan")


def f2(x, n=2):
    return "—" if x is None or (isinstance(x, float) and math.isnan(x)) else ("%.*f" % (n, x))


def main():
    tag = sys.argv[1] if len(sys.argv) > 1 else "after"
    b_rows, b_meta = load("before")
    a_rows, a_meta = load(tag)
    if tag != "after":
        an_rows, an_meta = load("after")
        for k, v in an_rows.items():
            if k[2] == "analytic":
                a_rows[k] = v
    sites = sorted({(k[0], k[1]) for k in a_rows} | {(k[0], k[1]) for k in b_rows})
    recs = []
    for wv in WINDS:
        for loc, st in sites:
            rec = {"start": "%s/%s" % (loc, st), "wind_ms": wv}
            for side, rows, meta in (("before", b_rows, b_meta), ("after", a_rows, a_meta)):
                for mode in ("field", "analytic"):
                    d = rows.get((loc, st, mode, wv))
                    if not d:
                        continue
                    p = "%s_%s" % (mode[0], side)
                    for a in AGLS:
                        rec["%s_U%g" % (p, a)] = float(d[a]["u_h_ms"])
                    rec["%s_dir10" % p] = direction(d[10.0])
                    if mode == "field":
                        si = meta.get((loc, st, mode, wv), {}).get("solver_info", {})
                        rec["%s_k" % p] = si.get("inflow_k", 1.0)
                        rec["%s_U1" % p] = si.get("u_start10_first")
                        rec["%s_Urt" % p] = si.get("u_start10")
                        rec["%s_wall" % p] = si.get("wall_s")
            recs.append(rec)
    keys = sorted({k for r in recs for k in r}, key=lambda k: (k not in ("start", "wind_ms"), k))
    with open(os.path.join(OUT, "compare_%s.csv" % tag), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        for r in recs:
            w.writerow({k: (round(v, 4) if isinstance(v, float) else v) for k, v in r.items()})

    L = ["# AS-1: ветер над стартом до/после (поле: подстройка притока; «после» — out/%s)" % tag, ""]
    L.append("U — горизонталь на высоте над землёй старта, м/с; в скобках — ÷ ветер меню. «до» — 576550e (= main 1.0.0),")
    L.append("«после» — ветка air-start/as1. dir10 — направление на 10 м относительно меню, ° (до — модуль угла).")
    L.append("")
    for wv in WINDS:
        L.append("## %g м/с" % wv)
        L.append("")
        L.append("| старт | поле до: 1,5 / 10 / 50 / 100 / 200 м (÷ меню) | dir10 до | поле после: 1,5 / 10 / 50 / 100 / 200 м (÷ меню) | dir10 после | U₁ | k | остаток на 10 м | аналитика после: 1,5 / 10 / 50 / 100 / 200 (÷ меню) | поле/аналитика 50 / 100 / 200 | wall до / после, с |")
        L.append("|---|---|---|---|---|---|---|---|---|---|---|")
        for r in [r for r in recs if r["wind_ms"] == wv]:
            def prof(p):
                if "%s_U10" % p not in r:
                    return "—"
                us = [r["%s_U%g" % (p, a)] for a in AGLS]
                return " / ".join(f2(u, 1) for u in us) + " (" + " / ".join(f2(u / wv) for u in us) + ")"
            res = (r["f_after_U10"] / wv - 1.0) * 100 if "f_after_U10" in r else float("nan")
            ratio = " / ".join(
                f2(r["f_after_U%g" % a] / r["a_after_U%g" % a]) if "f_after_U%g" % a in r and "a_after_U%g" % a in r else "—"
                for a in (50.0, 100.0, 200.0)
            )
            L.append("| %s | %s | %s | %s | %s | %s | %s | %s %% | %s | %s | %s / %s |" % (
                r["start"], prof("f_before"), f2(r.get("f_before_dir10"), 0), prof("f_after"), f2(r.get("f_after_dir10"), 0),
                f2(r.get("f_after_U1")), f2(r.get("f_after_k"), 3), f2(res, 1), prof("a_after"), ratio,
                f2(r.get("f_before_wall"), 1), f2(r.get("f_after_wall"), 1)))
        L.append("")
    # сводка
    L.append("## Сводка")
    L.append("")
    for wv in WINDS:
        rs = [r for r in recs if r["wind_ms"] == wv and "f_after_U10" in r]
        if not rs:
            continue
        res = [abs(r["f_after_U10"] / wv - 1) * 100 for r in rs]
        rb = [r["f_before_U10"] / wv for r in rs if "f_before_U10" in r]
        ks = [r["f_after_k"] for r in rs]
        L.append("- %g м/с: U10 над стартом ÷ меню до %.2f…%.2f, после — остаток |U10/меню − 1| ≤ %.1f %% (медиана %.1f %%), в допуске ±10 %%: %d из %d; k %.3f…%.3f" % (
            wv, min(rb) if rb else float("nan"), max(rb) if rb else float("nan"), max(res), sorted(res)[len(res) // 2],
            sum(1 for x in res if x <= 10.0), len(res), min(ks), max(ks)))
        for a in (50.0, 100.0, 200.0):
            q = [r["f_after_U%g" % a] / r["a_after_U%g" % a] for r in rs if "a_after_U%g" % a in r]
            if q:
                L.append("  - поле/аналитика на %g м: %.2f…%.2f (медиана %.2f)" % (a, min(q), max(q), sorted(q)[len(q) // 2]))
    # аналитика не изменилась
    dmax = 0.0
    for k, d in a_rows.items():
        if k[2] != "analytic" or k not in b_rows:
            continue
        for a, r in d.items():
            dmax = max(dmax, abs(float(r["u_h_ms"]) - float(b_rows[k][a]["u_h_ms"])))
    L.append("- аналитика над стартом: max |после − до| = %.4f м/с" % dmax)
    walls = [(r.get("f_before_wall"), r.get("f_after_wall")) for r in recs if r.get("f_after_wall") is not None]
    if walls:
        wb = [x for x, _ in walls if x is not None]
        wa = [y for _, y in walls]
        L.append("- загрузка поля (wall_s AirRuntime): до %.1f…%.1f с (медиана %.1f), после %.1f…%.1f с (медиана %.1f)" % (
            min(wb), max(wb), sorted(wb)[len(wb) // 2], min(wa), max(wa), sorted(wa)[len(wa) // 2]))
    open(os.path.join(OUT, "compare_%s.md" % tag), "w").write("\n".join(L) + "\n")
    print("\n".join(L[-12:]))


if __name__ == "__main__":
    main()
