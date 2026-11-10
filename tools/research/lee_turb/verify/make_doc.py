#!/usr/bin/env python3
"""LT-12: docs/research/lee_turb/verify.md из out/verify.json, out/ongudai.csv, out/w8_points.csv + текст ниже. python3 -I make_doc.py"""
import csv, json, os
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
d = json.load(open(os.path.join(HERE, "out", "verify.json")))
S = d["stats"]
OG = list(csv.DictReader(open(os.path.join(HERE, "out", "ongudai.csv"))))
W8 = list(csv.DictReader(open(os.path.join(HERE, "out", "w8_points.csv"))))
f = lambda x, n=4: "—" if x in (None, "") else ("%.*f" % (n, float(x))).replace(".", ",")
NAMES = (("perdigao/NE", "Perdigão NE"), ("perdigao/SW", "Perdigão SW"), ("askervein/TU03B", "Askervein TU03B"))


def rmse_tab(lab):
    rows = ["| случай | n | данные (ср.) | прежняя: ср. / RMSE / смещ. | новая: ср. / RMSE / смещ. | фон: RMSE / смещ. |", "|---|---|---|---|---|---|"]
    for k, nm in NAMES:
        v = S.get("%s/%s" % (k, lab))
        if v:
            rows.append("| %s | %d | %s | %s / %s / %s | %s / %s / %s | %s / %s |" % (nm, v["n"], f(v["obs_mean"]), f(v["old"]["mean"]), f(v["old"]["rmse"]), f(v["old"]["bias"]),
                        f(v["new"]["mean"]), f(v["new"]["rmse"]), f(v["new"]["bias"]), f(v["bg"]["rmse"]), f(v["bg"]["bias"])))
    return "\n".join(rows)


def max_tab(lab):
    rows = ["| случай | данные: станция (x/H; z/H) значение | прежняя | новая |", "|---|---|---|---|"]
    for k, nm in NAMES:
        v = S.get("%s/%s" % (k, lab))
        if v:
            c = lambda q: "%s (%s; %s) %s" % (v[q]["station"], f(v[q]["x_over_h"], 1), f(v[q]["z_over_h"], 2), f(v[q]["value"]))
            rows.append("| %s | %s | %s | %s |" % (nm, c("max_obs"), c("max_old"), c("max_new")))
    return "\n".join(rows)


def u_tab():
    rows = ["| случай (x/H 0–6) | n | средняя скорость, доля u_ref: данные | прежняя | новая |", "|---|---|---|---|---|"]
    for k, nm in NAMES:
        v = S.get("%s/x0_6" % k)
        if v and "u_mean" in v:
            u = v["u_mean"]
            rows.append("| %s | %d | %s | %s | %s |" % (nm, u["n"], f(u["obs"], 2), f(u["old"], 2), f(u["new"], 2)))
    return "\n".join(rows)


def og_tab():
    by = {(r["code"], r["ridge"]): r for r in OG}
    rows = ["| гребень (dx окна, H) | код | максимум σ_w: x/H; высота над гребнем, м; над землёй, м; σ_w, м/с; ветвь | то же, agl ≤ 150 м | σ_w на 30 м при x/H 0,5 / 1 / 2 / 4 | доля «mix» в x/H 0–6, agl ≤ 150 |", "|---|---|---|---|---|---|"]
    for r in OG:
        if r["code"] not in ("old", "new"):
            continue
        rows.append("| %s (%s м, %s м) | %s | %s; %s; %s; %s; %s | %s; %s; %s; %s; %s | %s / %s / %s / %s | %s |" % (
            r["ridge"], r["zone_dx"], f(r["H_m"], 0), r["code"], f(r["xh_max_all"], 2), f(r["zc_max_all"], 0), f(r["agl_max_all"], 0), f(r["sw_max_all"], 2), r["src_max_all"],
            f(r["xh_max_agl150"], 2), f(r["zc_max_agl150"], 0), f(r["agl_max_agl150"], 0), f(r["sw_max_agl150"], 2), r["src_max_agl150"],
            f(r["sw30_xh0.5"], 2), f(r["sw30_xh1"], 2), f(r["sw30_xh2"], 2), f(r["sw30_xh4"], 2), f(r["frac_mix_agl150_x0_6"], 3)))
    return "\n".join(rows)


def diff_tab():
    rows = ["| гребень | точек (x/H > 0, agl 5–150) | доля с \\|Δσ_w\\| > 0,05 | Δσ_w min / max, м/с | доля с \\|Δσ_u\\| > 0,05 | Δσ_u min / max | точек со сменой ветви |", "|---|---|---|---|---|---|---|"]
    for r in OG:
        if r["code"] == "new":
            rows.append("| %s | %s | %s | %s / %s | %s | %s / %s | %s |" % (r["ridge"], r["n_points"], f(r["dfrac_sigma_w"], 3), f(r["dmin_sigma_w"], 2), f(r["dmax_sigma_w"], 2),
                        f(r["dfrac_sigma_u"], 3), f(r["dmin_sigma_u"], 2), f(r["dmax_sigma_u"], 2), r["n_src_changed"]))
    return "\n".join(rows)


def w8_tab():
    rows = ["| случай | записей вне допуска | позиций | agl, м (мин–макс) | lee_f (мед.) | σ_u модель / эталон (мин–мед.–макс) |", "|---|---|---|---|---|---|"]
    import statistics as st
    for c in sorted({r["case"] for r in W8}):
        a = [r for r in W8 if r["case"] == c]
        ra = sorted(float(r["ratio"]) for r in a)
        rows.append("| %s | %d | %d | %s–%s | %s | %s–%s–%s |" % (c, len(a), len({(r["x"], r["z"], r["y_msl"]) for r in a}), f(min(float(r["agl"]) for r in a), 0), f(max(float(r["agl"]) for r in a), 0),
                    f(st.median(float(r["lee_f"]) for r in a), 2), f(ra[0], 2), f(st.median(ra), 2), f(ra[-1], 2)))
    return "\n".join(rows)


tmpl = open(os.path.join(HERE, "verify.tmpl.md"), encoding="utf-8").read()
s = [r for r in W8 if r["case"] == "ongudai_strong"]
tmpl = (tmpl.replace("@@RMSE06@@", rmse_tab("x0_6")).replace("@@RMSE01@@", rmse_tab("x0_1")).replace("@@RMSE157@@", rmse_tab("x1.5_7"))
        .replace("@@MAX06@@", max_tab("x0_6")).replace("@@MAX157@@", max_tab("x1.5_7")).replace("@@UTAB@@", u_tab())
        .replace("@@OG@@", og_tab()).replace("@@DIFF@@", diff_tab()).replace("@@W8@@", w8_tab())
        .replace("@@W8STRONG_MINCROSS@@", f(min(abs(float(r["cross_m"])) for r in s), 0)).replace("@@NROWS@@", str(d["n_rows"])))
out = os.path.join(ROOT, "docs", "research", "lee_turb", "verify.md")
open(out, "w", encoding="utf-8").write(tmpl)
print(out)
