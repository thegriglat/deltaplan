"""Сборка out/swg-10/ground.json (SWG2 v1) и tables.md из out/swg-10/raw/."""
from __future__ import annotations

import json
import math
from collections import defaultdict

import numpy as np

from ground import common as K
from ground import evaluate as E
from ground import tables as T

from .run import OUT, RAW

ZS = (10.0, 50.0, 300.0)
VARIANTS = {
    "potential": "SWD2 v5 потенциал: панели 3D + лог-фон, σ 40 м, ds_min 25 м, z0 — медиана растра, σ земли фона 250 м; "
                 "группы ≤ 40 (x, y) с фокусом ds_min 25 м (как SWG-1; пересчитано, сверено с out/swg-1)",
    "potential_jh": "SWD2 v5 потенциал + внутренний слой Jackson–Hunt (ground.model.jh_parts = velocity_jh); база SWG-1 "
                    "(пересчитано, сверено с out/swg-1)",
    "vii": "VII по образцу XFOIL: невязкое — панели 3D с однородным потоком U_∞ = bg_log(Z_SAT = 500 м) + заряды "
           "вытеснения σ_d (A σ_d = q, q = d(U_e·δ*)/ds — те же LU); слой — интегральный турбулентный (импульс Кармана + "
           "вовлечение Head 1958, профили Coles 1956 с законом стенки шероховатой стенки и следом, знак u_τ свободный), "
           "квазидвумерно на профилях вдоль ветра (шаг 12,5 м, поперёк 25 м), начало — край растра, равновесный слой фона "
           "(δ0 = 500 м, лог; стоки равновесия S_m = C_f0/2·U_∞², S_e = U_∞·F(H1_0)); прямая связь, обратный ход Carter при "
           "H > 2,5 (XFOIL HTMAX), δ*_{k+1} = δ*_k[1 + 0,5(U_visc/U_inv − 1)]; сетка слоя ds_min 50 м с фокусом во всех "
           "точках, поле в точках — группы ds_min 25 м; скорость у земли |U_o(z)|·f(z), f — профиль слоя в точке",
    "vii_nc": "как vii, но без связи: слой прогнан один раз по невязкому U_e без вдува (σ_d = 0; в отрыве — обратный ход "
              "с H = const); поле |U_o(z)|·f(z) без вдува — вклад слоя без взаимодействия",
}


def load(p):
    return json.load(open(p))


def fin(v):
    return v is not None and math.isfinite(v)


def main():
    refs = E.load_refs()
    pts = load(K.OUT_POINTS)
    rows, decomp, layer_rows = [], [], []
    base_check, layer_info, data = {}, {}, {}
    for case in K.CASES:
        pl = E.case_points(case, refs, pts)
        d = load(RAW / f"pts_{case}.json")
        assert d["ids"] == [p["id"] for p in pl]
        data[case] = (pl, d)
        li = load(RAW / f"layer_{case}.json")
        layer_info[case] = {k: li[k] for k in ("N", "backend", "z0", "U_inf", "delta0", "eq", "converged", "t_s", "strips")}
        layer_info[case]["hist"] = li["hist"]
        layer_info[case]["hist_nc"] = li["hist_nc"]
        old = load(K.OUT_TASK / "raw" / f"base_{case}.json")
        oo = dict(zip(old["ids"], old["s_jh"]))
        dif = [abs(s - oo[i]) for i, s in zip(d["ids"], d["s_jh"]) if fin(s) and fin(oo.get(i))]
        base_check[case] = float(max(dif)) if dif else None
        for var, key in (("potential", "s_pot"), ("potential_jh", "s_jh"), ("vii", "s_vii"), ("vii_nc", "s_vii_nc")):
            for p, s in zip(pl, d[key]):
                if not fin(s) or p["s_ref"] <= 0:
                    continue
                rows.append(T.rel_row(case, var, p["id"], p["type"], p["z_agl"], p["kind"], p["s_ref"], s))
    summary = T.summarize(rows)
    masts = T.mast_stats(rows)

    def add(case, typ, z, term, val, unit, note):
        if val is not None and math.isfinite(val):
            decomp.append(dict(case=case, type=typ, z_agl=float(z), term=term, value=float(val), unit=unit, note=note))

    for case in K.CASES:
        pl, d = data[case]
        for typ in K.TYPES:
            for z in ZS:
                idx = [i for i, p in enumerate(pl) if p["kind"] == "picard_nom" and p["type"] == typ and p["z_agl"] == z
                       and all(fin(d[k][i]) for k in ("s_jh", "s_vii", "s_vii_nc", "s_vii_noblow", "s_outer_eq"))]
                if not idx:
                    continue
                sref = np.array([pl[i]["s_ref"] for i in idx])
                g = lambda k: np.array([d[k][i] for i in idx], float)
                nn = f"n={len(idx)}; Пикар nom"
                sjh, sv, snb, so, snc = g("s_jh"), g("s_vii"), g("s_vii_noblow"), g("s_outer_eq"), g("s_vii_nc")
                add(case, typ, z, "total_jh", np.mean((sjh - sref) / sref), "rel", f"среднее rel_err potential_jh (до); {nn}")
                add(case, typ, z, "total_vii", np.mean((sv - sref) / sref), "rel", f"среднее rel_err vii (после); {nn}")
                add(case, typ, z, "outer_eq", np.mean((so - sref) / sref), "rel",
                    f"невязкое поле (U_∞ + панели) × равновесный лог фона, без слоя и вдува: среднее rel; {nn}")
                add(case, typ, z, "layer", np.mean((snb - so) / sref), "rel",
                    f"вклад профиля слоя VII (f вместо равновесного лога), без вдува: mean((s_noblow − s_outer_eq)/s_ref); {nn}")
                add(case, typ, z, "blow", np.mean((sv - snb) / sref), "rel",
                    f"вклад вдува σ_d во внешнее поле: mean((s_vii − s_noblow)/s_ref); total_vii = outer_eq + layer + blow; {nn}")
                add(case, typ, z, "coupling", np.mean((sv - snc) / sref), "rel",
                    f"vii − vii_nc: эффект взаимодействия (связь и полуобратный ход) против слоя без связи; {nn}")
                pv_ = np.array([np.nan if d["s_vii_prev"][i] is None else d["s_vii_prev"][i] for i in idx], float)
                if np.isfinite(pv_).any():
                    dd = np.abs(sv - pv_)[np.isfinite(pv_)]
                    add(case, typ, z, "conv_max", float(dd.max()), "s",
                        f"сходимость связи: max |s(последняя итерация) − s(предпоследняя)|; {nn}")
                    add(case, typ, z, "conv_mean", float(np.mean(dd / sref[np.isfinite(pv_)])), "rel",
                        f"сходимость связи: mean |Δs|/s_ref между двумя последними итерациями; {nn}")
                add(case, typ, z, "reverse", np.mean(g("sign_vii") < 0), "rel", f"доля точек с u∥ < 0 (f < 0) в vii; {nn}")
                add(case, typ, z, "sep", np.mean(g("cf") <= 0), "rel", f"доля точек над слоем с C_f ≤ 0 (отрыв) в vii; {nn}")
                add(case, typ, z, "inverse", np.mean(g("inv") > 0.5), "rel", f"доля точек в зоне обратного хода (H > 2,5); {nn}")
                layer_rows.append(dict(case=case, type=typ, z_agl=z, n=len(idx),
                                       theta_m=float(np.mean(g("theta"))), dstar_m=float(np.mean(g("dstar"))),
                                       delta_m=float(np.mean(g("delta"))), H=float(np.mean(g("H"))),
                                       H_max=float(np.max(g("H"))), cf=float(np.mean(g("cf"))),
                                       frac_sep=float(np.mean(g("cf") <= 0)), frac_inv=float(np.mean(g("inv") > 0.5)),
                                       f_mean=float(np.mean(g("f")))))
        nr = [gr["norm"] for gr in d["groups"]]
        add(case, "crest" if case != "ASK_TU03B" else "upstream", refs["norm"][case]["z_agl"], "norm_vii_over_jh",
            float(np.mean([q["vii"] / q["jh"] for q in nr])), "rel",
            "отношение скорости vii / potential_jh в опорной точке (м/с к м/с, среднее по группам): s делится на неё")
    doc = dict(format="swg-ground", version=1, git=K.git_short(), created=K.now_iso(), task="swg-10",
               variants=VARIANTS, rows=rows, summary=summary, masts=masts, decomp=decomp, scan=[],
               base_check=dict(max_abs_ds_vs_swg1=base_check,
                               note="max |s_potential_jh (здесь) − s_potential_jh (out/swg-1)| по точкам"),
               layer=dict(rows=layer_rows, note="состояние слоя vii в точках Пикара nom по типам (средние): θ, δ*, δ — м; "
                                                "H, C_f, доли — безразмерные (вне decomp: единицы decomp — s/rel/m/s)"),
               layer_info=layer_info)
    K.dump_json(OUT / "ground.json", doc)
    (OUT / "tables.md").write_text(tables(doc))
    print("ground.json:", len(rows), "строк; base_check", base_check)


def tables(doc):
    S = {(s["case"], s["variant"], s["type"], s["z_agl"]): s for s in doc["summary"] if s["ref_kind"] == "picard_nom"}
    cs = {"ASK_TU03B": "ASK", "PERD_NE": "NE", "PERD_SW": "SW"}
    vs = ("potential_jh", "vii", "vii_nc")
    out = ["# SWG-10: таблицы (вывод `py -m vii.run assemble`)", "",
           "## До/после против Пикара nom: n / доля в ±15 % / среднее rel / медиана rel", ""]
    out.append("| тип | z, м | случай | " + " | ".join(vs) + " |")
    out.append("|---|---|---|" + "---|" * len(vs))
    for t in K.MAIN_TYPES + ("upstream",):
        for z in ZS:
            for c in K.CASES:
                cells = []
                for v in vs:
                    s = S.get((c, v, t, z))
                    cells.append("–" if s is None else
                                 f"{s['n']} / {s['frac_tol']:.2f} / {s['mean_rel']:+.2f} / {s['median_rel']:+.2f}")
                if all(x == "–" for x in cells):
                    continue
                out.append(f"| {t} | {z:g} | {cs[c]} | " + " | ".join(cells) + " |")
    out += ["", "## Мачты: RMSE s / доля в ±15 % / среднее rel к измерению", ""]
    rr = defaultdict(list)
    for r in doc["rows"]:
        if r["ref_kind"] == "mast":
            rr[(r["case"], r["variant"], r["type"])].append(r["rel_err"])
            rr[(r["case"], r["variant"], "all")].append(r["rel_err"])
    M = {(m["case"], m["variant"], m["type"]): m for m in doc["masts"]}
    out.append("| случай | тип | n | " + " | ".join(vs) + " |")
    out.append("|---|---|---|" + "---|" * len(vs))
    for c in K.CASES:
        for t in ("all",) + K.TYPES:
            if (c, "potential_jh", t) not in M:
                continue
            cells = []
            for v in vs:
                m = M.get((c, v, t))
                cells.append("–" if m is None else f"{m['rmse_s']:.3f} / {m['frac_tol']:.2f} / {np.mean(rr[(c, v, t)]):+.2f}")
            out.append(f"| {cs[c]} | {t} | {M[(c, 'potential_jh', t)]['n']} | " + " | ".join(cells) + " |")
    out += ["", "## Разложение vii (средние rel по точкам Пикара nom): total_vii = outer_eq + layer + blow", ""]
    terms = ("total_jh", "total_vii", "outer_eq", "layer", "blow", "coupling", "reverse", "sep", "inverse", "conv_mean")
    D = {(d["case"], d["type"], d["z_agl"], d["term"]): d["value"] for d in doc["decomp"]}
    out.append("| случай | тип | z | " + " | ".join(terms) + " |")
    out.append("|---|---|---|" + "---|" * len(terms))
    for c in K.CASES:
        for t in K.TYPES:
            for z in ZS:
                if (c, t, z, "total_vii") not in D:
                    continue
                out.append(f"| {cs[c]} | {t} | {z:g} | " + " | ".join(
                    f"{D[(c, t, z, k)]:+.3f}" if (c, t, z, k) in D else "–" for k in terms) + " |")
    out += ["", "## Слой в точках (средние): θ, δ*, δ (м), H (среднее/макс), C_f, доля C_f ≤ 0, доля обратного хода, f", ""]
    out.append("| случай | тип | z | n | θ | δ* | δ | H | H max | C_f | отрыв | обратный | f |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in doc["layer"]["rows"]:
        out.append(f"| {cs[r['case']]} | {r['type']} | {r['z_agl']:g} | {r['n']} | {r['theta_m']:.1f} | {r['dstar_m']:.1f} | "
                   f"{r['delta_m']:.0f} | {r['H']:.2f} | {r['H_max']:.2f} | {r['cf']:.4f} | {r['frac_sep']:.2f} | "
                   f"{r['frac_inv']:.2f} | {r['f_mean']:.3f} |")
    out += ["", "## Сходимость связи (сетка слоя)", ""]
    out.append("| случай | N | итераций | max|Δδ*|/δ* в конце | узлов > 1e-3 | узлов | обратных | C_f ≤ 0 | H max | время, с |")
    out.append("|---|---|---|---|---|---|---|---|---|---|")
    for c, li in doc["layer_info"].items():
        h = li["hist"][-1]
        dm = "–" if h["dmax"] is None else f"{h['dmax']:.2e}"
        out.append(f"| {cs[c]} | {li['N']} | {len(li['hist'])} | {dm} | {h['n_bad']} | {h['n_nodes']} | "
                   f"{h['n_inv']} | {h['n_sep']} | {h['H_max']:.2f} | {li['t_s']:.0f} |")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    main()
