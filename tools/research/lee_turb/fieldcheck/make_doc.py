#!/usr/bin/env python3
"""LT-8: docs/research/lee_turb/fieldcheck.md из out/fieldcheck.json (числа таблиц) + текст ниже. python3 -I make_doc.py"""
import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
d = json.load(open(os.path.join(HERE, "out", "fieldcheck.json")))
S, B, C = d["stats"], d["bubble"], d["centre"]
f3 = lambda x: "—" if x is None else ("%.4f" % x).replace(".", ",")
f2 = lambda x: "—" if x is None else ("%.2f" % x).replace(".", ",")
f1 = lambda x: "—" if x is None else ("%.1f" % x).replace(".", ",")
f0 = lambda x: "—" if x is None else ("%.0f" % x)


def times(f):
    t = [float(r[2]) for r in d["times"][f]]
    return sum(t) / len(t), min(t), max(t), len(t)


def rmse_table(lab):
    rows = ["| поле | место/случай | n | ТКЭ/u_ref² данные (ср.) | прежняя RMSE / смещ. | новая RMSE / смещ. | фон RMSE / смещ. |", "|---|---|---|---|---|---|---|"]
    for f in "ab":
        for sc in ("perdigao/NE", "perdigao/SW", "askervein/TU03B"):
            v = S.get("%s/%s/%s" % (f, sc, lab))
            if not v or not v.get("old"):
                continue
            rows.append("| %s | %s | %d | %s | %s / %s | %s / %s | %s / %s |" % (f, sc.replace("perdigao/", "Perdigão ").replace("askervein/TU03B", "Askervein TU03B"), v["n"], f3(v["obs_mean"]),
                        f3(v["old"]["rmse"]), f3(v["old"]["bias"]), f3(v["new"]["rmse"]), f3(v["new"]["bias"]), f3(v["bg"]["rmse"]), f3(v["bg"]["bias"])))
    return "\n".join(rows)


def max_table(lab):
    rows = ["| поле | место/случай | данные: станция (x/H; z/H) значение | прежняя | новая |", "|---|---|---|---|---|"]
    for f in "ab":
        for sc in ("perdigao/NE", "perdigao/SW", "askervein/TU03B"):
            v = S.get("%s/%s/%s" % (f, sc, lab))
            if not v:
                continue
            c = lambda k: "%s (%s; %s) %s" % (v[k]["station"], f1(v[k]["x_over_h"]), f2(v[k]["z_over_h"]), f3(v[k]["value"]))
            rows.append("| %s | %s | %s | %s | %s |" % (f, sc.replace("perdigao/", "Perdigão ").replace("askervein/TU03B", "Askervein TU03B"), c("max_obs"), c("max_old"), c("max_new")))
    return "\n".join(rows)


def valley_table():
    rows = ["| поле | случай | n | средняя скорость поля / измеренная (медиана) | ТКЭ прежняя / данные | новая / данные | фон / данные | линия слоя выше станции, м (медиана) |", "|---|---|---|---|---|---|---|---|"]
    for f in "ab":
        for sc in ("perdigao/NE", "perdigao/SW", "askervein/TU03B"):
            v = S.get("%s/%s/x1.5_7" % (f, sc))
            if not v or "ratio_mean_to_obs" not in v:
                continue
            r = v["ratio_mean_to_obs"]
            rows.append("| %s | %s | %d | %s | %s | %s | %s | %s |" % (f, sc.split("/")[1] if "perd" in sc else "TU03B", v["n"], f2(v["u_mean"]["ratio_median"]), f2(r["old"]), f2(r["new"]), f2(r["bg"]), f0(v["line_minus_station_m_median"])))
    return "\n".join(rows)


def bubble_table():
    rows = ["| поле/случай | H модели, м | x_r на 25 м над землёй (L; от x) | любые u<0: наибольший u<0 по модулю, м/с (медиана) | u < −0,5 м/с: клеток, протяжённость, глубина над подножием | глубина верха любых u<0, макс, м |", "|---|---|---|---|---|---|"]
    for k, v in B.items():
        xr = v["x_r_low"]
        m = v.get("menke_thr") or {}
        rows.append("| %s | %s | %s | %s (%s) | %s, %s м, %s м | %s |" % (k.replace("perdigao_", "Perdigão ").replace("askervein_tu03b", "Askervein"), f1(v["H_model"]),
                    "нет" if not xr else "%s м; %s–%s м" % (f0(xr["L"]), f0(xr["x_sep"]), f0(xr["x_att"])), f2(v["u_back_min"]), f2(v["u_back_median"]),
                    m.get("n_cells", 0), f0(m.get("x_extent")), f0(m.get("depth_max")), f0(v["depth_max"])))
    return "\n".join(rows)


def centre_table():
    rows = ["| поле/случай | колонок x/H 0,5–6 | доля с q > 0,5 | z½ − запасная линия, м (при q > 0,5) | z½ над землёй / H | запасная над землёй / H |", "|---|---|---|---|---|---|"]
    for k, v in C.items():
        if v is None:
            continue
        rows.append("| %s | %d | %s | %s | %s | %s |" % (k.replace("perdigao_", "Perdigão ").replace("askervein_tu03b", "Askervein"), v["n_cols"], f2(v["frac_q_gt_half"]),
                    f1(v["dz_field_minus_fallback_m"]), f2(v["zhalf_agl_over_H_mean"]), f2(v["fallback_agl_over_H_mean"])))
    return "\n".join(rows)


ta, tb = times("a"), times("b")
a_sw6, b_sw6 = S["a/perdigao/SW/x0_6"], S["b/perdigao/SW/x0_6"]
doc = open(os.path.join(HERE, "fieldcheck.tmpl.md"), encoding="utf-8").read()
doc = doc.replace("{{RMSE6}}", rmse_table("x0_6")).replace("{{RMSEALL}}", rmse_table("x0_all")).replace("{{MAX6}}", max_table("x0_6")).replace("{{VALLEY}}", valley_table())
doc = doc.replace("{{BUBBLE}}", bubble_table()).replace("{{CENTRE}}", centre_table())
doc = doc.replace("{{TA}}", "%s с (мин %s, макс %s, n %d)" % (f0(ta[0]), f0(ta[1]), f0(ta[2]), ta[3])).replace("{{TB}}", "%s с (мин %s, макс %s, n %d)" % (f0(tb[0]), f0(tb[1]), f0(tb[2]), tb[3]))
doc = doc.replace("{{NROWS}}", str(d["n_rows"]))
open(os.path.join(HERE, "..", "..", "..", "..", "docs", "research", "lee_turb", "fieldcheck.md"), "w", encoding="utf-8").write(doc)
print("ok")
