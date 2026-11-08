"""Сборка out/swg-7/ground.json (SWG2 v1) и tables.md из out/swg-7/raw/."""
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
_GEO = ("геометрия SWG-4 (wake.run.make_grid, gate «slope»: гребень crests_profile, lee_slope > 0,27, x_r — "
        "rotor3d.profile_rule, оболочка upper_hull от x_s до x_r; профили шаг 12,5 м, поперёк 25 м); лист — ряды поперёк "
        "ветра через 25 м по оболочке (высота над панелями, ≥ core/2), петли с ножками и возвратом под землёй, ядро 12,5 м; "
        "отражение панелями σ_ex (те же LU); поле — velocity_jh(extra = лист, couple = True)")
VARIANTS = {
    "potential": "SWD2 v5 потенциал: панели 3D + лог-фон, σ 40 м, ds_min 25 м, z0 — медиана растра, σ земли фона 250 м; "
                 "группы ≤ 40 (x, y) с фокусом ds_min 25 м (как SWG-1; пересчитано здесь)",
    "potential_jh": "SWD2 v5 потенциал + внутренний слой Jackson–Hunt (ground.model.jh_parts = velocity_jh); база SWG-1 "
                    "(пересчитано здесь, совпадает с out/swg-1)",
    "sheet_jh": "potential_jh + вихревой лист слоя сдвига над мёртвой зоной, замыкание «rest» (основное): u_d = 0, "
                "γ = U_e — касательная скорость внешнего поля (панели + лог-фон + лист) на внешней стороне листа, итерации "
                "γ ← U_ср + γ/2 до max|Δγ|/U_ref < 1e-3 (≤ 30); " + _GEO,
    "sheet_jh_cpb": "как sheet_jh, но γ = U_ref·√(1 − C_pb), C_pb = −0,2 (sheet3d v6; Tani 1964, Roshko & Lau 1965), "
                    "без итераций",
    "sheet_jh_zone": "как sheet_jh, но точки под листом (z_agl < высоты оболочки) берут скорость зоны вместо JH: |внешнее "
                     "поле (потенциал + лист) в точке|·ln(z/z0)/ln(h/z0) (лог-профиль от земли зоны); выше — sheet_jh",
    "sheet_jh_cpb_zone": "как sheet_jh_zone для замыкания cpb",
}
SRC = {"potential": "s_pot", "potential_jh": "s_jh", "sheet_jh": "s_rest", "sheet_jh_cpb": "s_cpb",
       "sheet_jh_zone": "s_rest_zone", "sheet_jh_cpb_zone": "s_cpb_zone"}
SHEETS = {"sheet_jh": ("rest", ""), "sheet_jh_cpb": ("cpb", "_cpb")}


def load(p):
    return json.load(open(p))


def fin(v):
    return v is not None and math.isfinite(v)


def main():
    refs = E.load_refs()
    pts = load(K.OUT_POINTS)
    rows, decomp = [], []
    base_check, data, sheet_info = {}, {}, {}
    for case in K.CASES:
        pl = E.case_points(case, refs, pts)
        d = load(RAW / f"pts_{case}.json")
        assert d["ids"] == [p["id"] for p in pl]
        data[case] = (pl, d)
        old = load(K.OUT_TASK / "raw" / f"base_{case}.json")
        oo = dict(zip(old["ids"], old["s_jh"]))
        dif = [abs(s - oo[i]) for i, s in zip(d["ids"], d["s_jh"]) if fin(s) and fin(oo.get(i))]
        base_check[case] = float(max(dif)) if dif else None
        for var, key in SRC.items():
            for p, s in zip(pl, d[key]):
                if not fin(s) or p["s_ref"] <= 0:
                    continue
                rows.append(T.rel_row(case, var, p["id"], p["type"], p["z_agl"], p["kind"], p["s_ref"], s))
        gi = {}
        for v in ("rest", "cpb"):
            gs = [g[v] for g in d["groups"]]
            gi[v] = dict(groups=len(gs), iters_max=max(g["iters"] for g in gs),
                         n_unconverged=int(sum(g["n_unconverged"] for g in gs)),
                         groups_unconverged=int(sum(not g["converged"] for g in gs)),
                         n_nodes=gs[0]["n_nodes"], gamma_over_Uref_mean=float(np.mean([g.get("gamma_over_Uref", 0) for g in gs])),
                         norm_ratio_mean=float(np.mean([g["norm_ratio"] for g in gs])),
                         norm_under=any(g["norm_under"] for g in gs),
                         imbalance_max=float(max(g["imbalance"] for g in gs)),
                         t_s=float(sum(g["t_s"] for g in gs)))
        gi["geom"] = d["geom"]
        sheet_info[case] = gi
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
                       and all(fin(d[k][i]) for k in SRC.values())]
                if not idx:
                    continue
                sref = np.array([pl[i]["s_ref"] for i in idx])
                g = lambda k: np.array([d[k][i] for i in idx])
                sjh, spot = g("s_jh"), g("s_pot")
                nn = f"n={len(idx)}; Пикар nom"
                add(case, typ, z, "total_jh", np.mean((sjh - sref) / sref), "rel", f"среднее rel_err potential_jh (до); {nn}")
                for var, (v, sfx) in SHEETS.items():
                    sw, spw = g(f"s_{v}"), g(f"spw_{v}")
                    add(case, typ, z, f"total{sfx}", np.mean((sw - sref) / sref), "rel", f"среднее rel_err {var} (после); {nn}")
                    add(case, typ, z, f"sheet{sfx}", np.mean((sw - sjh) / sref), "rel",
                        f"вклад листа в {var}: mean((s_{var} − s_potential_jh)/s_ref) = total{sfx} − total_jh; {nn}")
                    add(case, typ, z, f"sheet_outer{sfx}", np.mean((spw - spot) / sref), "rel",
                        f"изменение внешнего поля в точке от листа (+σ_ex) без JH: mean((s_pot+лист − s_pot)/s_ref); {nn}")
                    add(case, typ, z, f"sheet_dS{sfx}", np.mean(g(f"dSw_{v}")), "rel",
                        f"средняя добавка листа к ΔS внутреннего слоя (доли U_ref) на max(z_agl, l); < 0 — торможение; {nn}")
                    add(case, typ, z, f"jh_reverse{sfx}", np.mean(1.0 + g("A") * g(f"dS_{v}") < 0), "rel",
                        f"доля точек, где 1 + A·ΔS < 0 (JH даёт обратный поток, |u| растёт — «возвращает скорость»); {nn}")
                    add(case, typ, z, f"total_zone{sfx}", np.mean((g(f"s_{v}_zone") - sref) / sref), "rel",
                        f"среднее rel_err {var}_zone (под листом — скорость зоны); {nn}")
                add(case, typ, z, "sheet_cover", np.mean(g("zone_h") > 0), "rel", f"доля точек над мёртвой зоной (h_зоны > 0); {nn}")
                add(case, typ, z, "sheet_inside", np.mean(g("under") > 0.5), "rel", f"доля точек под листом (z_agl < h_зоны); {nn}")
        for var, (v, sfx) in SHEETS.items():
            st = sheet_info[case][v]
            add(case, "crest" if case != "ASK_TU03B" else "upstream", refs["norm"][case]["z_agl"], f"norm_sheet{sfx}",
                st["norm_ratio_mean"], "rel", f"отношение скорости {var} / potential_jh в опорной точке нормировки "
                "(среднее по группам): s делится на неё — торможение опорной точки повышает все s")
            add(case, "lee", 10.0, f"unconverged{sfx}", st["n_unconverged"], "s",
                f"{var}: число узлов листа (сумма по {st['groups']} группам), где max|Δγ|/U_ref ≥ 1e-3 после {st['iters_max']} "
                "итераций (unit «s» — счётчик)")
    doc = dict(format="swg-ground", version=1, git=K.git_short(), created=K.now_iso(), task="swg-7",
               variants=VARIANTS, rows=rows, summary=summary, masts=masts, decomp=decomp, scan=[],
               base_check=dict(max_abs_ds_vs_swg1=base_check,
                               note="max |s_potential_jh (здесь) − s_potential_jh (out/swg-1)| по точкам"),
               sheets=sheet_info)
    K.dump_json(OUT / "ground.json", doc)
    (OUT / "tables.md").write_text(tables(doc))
    print("ground.json:", len(rows), "строк; base_check", base_check)


def tables(doc):
    S = {(s["case"], s["variant"], s["type"], s["z_agl"]): s for s in doc["summary"] if s["ref_kind"] == "picard_nom"}
    cs = {"ASK_TU03B": "ASK", "PERD_NE": "NE", "PERD_SW": "SW"}
    out = ["# SWG-7: таблицы (вывод `py -m sheet.run assemble`)", ""]
    out.append("## До/после против Пикара nom: n / доля в ±15 % / среднее rel")
    out.append("")
    vs = ("potential_jh", "sheet_jh", "sheet_jh_cpb", "sheet_jh_zone", "sheet_jh_cpb_zone")
    out.append("| тип | z, м | случай | " + " | ".join(vs) + " |")
    out.append("|---|---|---|" + "---|" * len(vs))
    for t in K.MAIN_TYPES:
        for z in ZS:
            for c in K.CASES:
                cells = []
                for v in vs:
                    s = S.get((c, v, t, z))
                    cells.append("–" if s is None else f"{s['n']} / {s['frac_tol']:.2f} / {s['mean_rel']:+.2f}")
                out.append(f"| {t} | {z:g} | {cs[c]} | " + " | ".join(cells) + " |")
    out += ["", "## Мачты: RMSE s / доля в ±15 % / среднее rel к измерению по типам", ""]
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
    out += ["", "## Разложение (средние по точкам Пикара nom)", ""]
    terms = ("total_jh", "total", "sheet", "sheet_outer", "sheet_dS", "jh_reverse", "total_zone", "sheet_cover",
             "sheet_inside", "total_cpb", "sheet_cpb", "jh_reverse_cpb", "total_zone_cpb")
    D = {(d["case"], d["type"], d["z_agl"], d["term"]): d["value"] for d in doc["decomp"]}
    out.append("| случай | тип | z | " + " | ".join(terms) + " |")
    out.append("|---|---|---|" + "---|" * len(terms))
    for c in K.CASES:
        for t in K.TYPES:
            for z in ZS:
                if (c, t, z, "total") not in D:
                    continue
                out.append(f"| {cs[c]} | {t} | {z:g} | " + " | ".join(
                    f"{D[(c, t, z, k)]:+.3f}" if (c, t, z, k) in D else "–" for k in terms) + " |")
    out += ["", "## Лист по случаям", ""]
    out.append("| случай | замыкание | узлов | отрезков зоны | медиана h_max, м | медиана L, м | γ/U_ref | итераций max | "
               "несошедшихся узлов | опорная точка (лист/база) | время, с |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for c in K.CASES:
        g = doc["sheets"][c]
        for v in ("rest", "cpb"):
            st, ge = g[v], g["geom"]
            f = lambda x, fmt: "–" if x is None else format(x, fmt)
            out.append(f"| {cs[c]} | {v} | {st['n_nodes']} | {ge['n_segs']} | {f(ge['hmax_median'], '.0f')} | "
                       f"{f(ge['L_median'], '.0f')} | {st['gamma_over_Uref_mean']:.2f} | {st['iters_max']} | "
                       f"{st['n_unconverged']} | {st['norm_ratio_mean']:.3f} | {st['t_s']:.0f} |")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    main()
