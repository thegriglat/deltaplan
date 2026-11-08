"""Сборка out/swg-12/ground.json (SWG2 v1) и tables.md из out/swg-12/raw/ (+ строки zone_jh из out/swg-8/ground.json)."""
from __future__ import annotations

import json
import math
from collections import defaultdict

import numpy as np

from ground import common as K
from ground import evaluate as E
from ground import tables as T

from . import core as FL
from .run import OUT, RAW

ZS = (10.0, 50.0, 300.0)
SWG8 = K.SG / "out" / "swg-8" / "ground.json"
_LINE = ("разделяющая линия тока — свободная линия тока с гребня (freeline.core.FreeGeom): сходит с гребня по касательной "
         "к наветренному склону, на ней u·n = 0 и постоянное давление (u' = u_b, линейная теория Гильберта на профиле вдоль "
         "ветра), присоединение — мост через долину (земля снова на высоте гребня до следующего гребня) или правило SWD7 v2 "
         "(подножие/середина долины); лист SWG-7 (ряды через 25 м, петли с ножками, ядро 12,5 м, σ_ex, γ «rest» до "
         "max|Δγ|/U_ref < 1e-3) на этой линии")
_ZONE = ("под линией (z_agl < h) — правило зоны SWG-8 с поправками ревью: u∥ = G·u_h − (1 − G)·u_r·ln(z/z0)/ln(h/z0), "
         "G = 1 + tanh(2(z − h)/δ), u_h — со знаком, u_r из ∫₀ʰ u∥ dz = 0, |u_r| ≤ 0,3·U_e (предохранитель), U_e — γ листа")
_MIX = ("слой смешения: Γ на 7 листов по толщине δ = min(max(0,181·(s − x_s), core), max(h − core/2, core)) (δ_ω Brown & "
        "Roshko 1974, ограничено сверху)")
VARIANTS = {
    "potential": "SWD2 v5 потенциал: панели 3D + лог-фон, σ 40 м, ds_min 25 м, z0 — медиана растра; группы ≤ 40 (x, y) "
                 "(как SWG-1; пересчитано здесь)",
    "potential_jh": "SWD2 v5 потенциал + внутренний слой Jackson–Hunt (ground.model.jh_parts); база SWG-1 (пересчитано, "
                    "совпадает с out/swg-1)",
    "zone_jh": "SWG-8 основной (оболочка «натянутая нить» + слой смешения + правило зоны); строки скопированы из "
               "out/swg-8/ground.json без пересчёта",
    "free_sheet_jh": "только лист: триггер Хед; " + _LINE + "; " + _MIX + "; внутренний слой JH всюду, без правила зоны",
    "free_jh_thin": "без слоя смешения: триггер Хед; " + _LINE + "; тонкий лист; " + _ZONE + ", δ = core = 12,5 м",
    "free_jh": "основной: триггер Хед (separation3d по полю SWG-4, точки отрыва ≤ 100 м от профиля); " + _LINE + "; " + _MIX
               + "; " + _ZONE + ", δ — как у слоя смешения",
    "free_jh_slope": "как free_jh, но триггер «slope» (подветренный уклон > 0,27, SWD7/SWD9) — для сравнения критериев",
    "free_jh_fixnorm": "диагностика: free_jh, нормированный на скорость potential_jh в опорной точке (s·r, r — отношение "
                       "free_jh/potential_jh в опорной точке своей группы): только местное действие зоны, без сдвига нормировки",
    "free_jh_slope_fixnorm": "диагностика: free_jh_slope с нормировкой potential_jh (как free_jh_fixnorm)",
}
FIX = {"free_jh_fixnorm": ("s_free_head", "head"), "free_jh_slope_fixnorm": ("s_free_slope", "slope")}
SRC = {"potential": "s_pot", "potential_jh": "s_jh", "free_sheet_jh": "s_smix_head", "free_jh_thin": "s_fthin_head",
       "free_jh": "s_free_head", "free_jh_slope": "s_free_slope"}
VS = ("potential_jh", "zone_jh", "free_sheet_jh", "free_jh_thin", "free_jh", "free_jh_slope", "free_jh_fixnorm",
      "free_jh_slope_fixnorm")
CS = {"ASK_TU03B": "ASK", "PERD_NE": "NE", "PERD_SW": "SW"}


def load(p):
    return json.load(open(p))


def fin(v):
    return v is not None and math.isfinite(v)


def main():
    refs = E.load_refs()
    pts = load(K.OUT_POINTS)
    rows, decomp = [], []
    base_check, data, info = {}, {}, {}
    z8 = [r for r in load(SWG8)["rows"] if r["variant"] == "zone_jh"]
    z8i = {(r["case"], r["id"], r["ref_kind"]): r for r in z8}
    rows += z8
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
        gs = d["groups"]
        _, gid = E.kd_groups(pl, 40)
        for var, (key, gate) in FIX.items():
            for i, (p, s) in enumerate(zip(pl, d[key])):
                if not fin(s) or p["s_ref"] <= 0:
                    continue
                rows.append(T.rel_row(case, var, p["id"], p["type"], p["z_agl"], p["kind"], p["s_ref"],
                                      s * gs[gid[i]][gate]["mix"]["norm_ratio_zone"]))
        info[case] = {}
        for gate in ("head", "slope"):
            th = [g[gate]["thin"] for g in gs]
            mx = [g[gate]["mix"] for g in gs]
            info[case][gate] = dict(
                groups=len(gs), iters_max=max(g["iters"] for g in th), n_unconverged=int(sum(g["n_unconverged"] for g in th)),
                n_nodes=th[0]["n_nodes"], gamma_over_Uref_mean=float(np.mean([g.get("gamma_over_Uref", 0) for g in th])),
                n_clip_sum=int(sum(g["n_clip"] for g in th)),
                dw_median=float(np.median([g["dw_median"] for g in mx if "dw_median" in g])) if any("dw_median" in g for g in mx) else None,
                lifted_frac_mean=float(np.mean([g["lifted_frac"] for g in mx if "lifted_frac" in g])) if any("lifted_frac" in g for g in mx) else None,
                dcap_frac_mean=float(np.mean([g["capped_frac"] for g in mx if "capped_frac" in g])) if any("capped_frac" in g for g in mx) else None,
                norm_ratio=dict(sheet=float(np.mean([g["norm_ratio_sheet"] for g in mx])),
                                thin=float(np.mean([g["norm_ratio_zone"] for g in th])),
                                zone=float(np.mean([g["norm_ratio_zone"] for g in mx]))),
                norm_under=any(g["norm_under"] for g in th + mx),
                imbalance_max=float(max(max(a["imbalance"], b["imbalance"]) for a, b in zip(th, mx))),
                t_thin_s=float(sum(g["t_s"] for g in th)), t_mix_s=float(sum(g["t_s"] for g in mx)),
                geom=d["geom"][gate])
        info[case]["t_total_s"] = d["t_s"]
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
                g = lambda k: np.array([np.nan if d[k][i] is None else d[k][i] for i in idx], float)
                nn = f"n={len(idx)}; Пикар nom"
                for var, key in SRC.items():
                    add(case, typ, z, f"total_{var}", np.mean((g(key) - sref) / sref), "rel", f"среднее rel_err {var}; {nn}")
                zr = [z8i.get((case, pl[i]["id"], "picard_nom")) for i in idx]
                if all(r is not None for r in zr):
                    add(case, typ, z, "total_zone_jh", np.mean([r["rel_err"] for r in zr]), "rel", f"SWG-8 zone_jh; {nn}")
                add(case, typ, z, "zone_vs_sheet", np.mean((g("s_free_head") - g("s_smix_head")) / sref), "rel",
                    f"вклад правила зоны: mean((s_free_jh − s_free_sheet_jh)/s_ref); {nn}")
                add(case, typ, z, "free_vs_jh", np.mean((g("s_free_head") - g("s_jh")) / sref), "rel",
                    f"полный вклад free_jh относительно potential_jh; {nn}")
                add(case, typ, z, "median_s_ref", np.median(sref), "s", f"медиана s Пикара; {nn}")
                add(case, typ, z, "median_s_free", np.median(g("s_free_head")), "s", f"медиана s free_jh; {nn}")
                for gate in ("head", "slope"):
                    tag = "" if gate == "head" else "_slope"
                    var = "free_jh" if gate == "head" else "free_jh_slope"
                    sf = g(f"s_free_{gate}")
                    hz = g(f"zone_h_{gate}")
                    und = g(f"under_{gate}") > 0.5
                    cov = hz > 0
                    add(case, typ, z, f"cover{tag}", np.mean(cov), "rel", f"{gate}: доля точек над зоной; {nn}")
                    add(case, typ, z, f"under{tag}", np.mean(und), "rel", f"{gate}: доля точек под линией (z_agl < h); {nn}")
                    if cov.any():
                        add(case, typ, z, f"zone_h_median{tag}", np.median(hz[cov]), "m/s",
                            f"{gate}: медиана высоты линии над землёй, м, в точках над зоной (unit m/s — по схеме; это м); "
                            f"n={int(cov.sum())}")
                    if und.any():
                        nu = f"n_under={int(und.sum())}"
                        add(case, typ, z, f"under_err{tag}", np.mean(((sf - sref) / sref)[und]), "rel",
                            f"{gate}: под линией: среднее rel {var}; {nu}")
                        add(case, typ, z, f"under_err_jh{tag}", np.mean(((g('s_jh') - sref) / sref)[und]), "rel",
                            f"{gate}: под линией: среднее rel potential_jh; {nu}")
                        add(case, typ, z, f"under_frac_tol{tag}", np.mean(np.abs((sf - sref) / sref)[und] <= K.TOL), "rel",
                            f"{gate}: под линией: доля в ±15 % {var}; {nu}")
                        add(case, typ, z, f"under_med_s{tag}", np.median(sf[und]), "s", f"{gate}: под линией: медиана s {var}; {nu}")
                        add(case, typ, z, f"under_med_ref{tag}", np.median(sref[und]), "s", f"{gate}: под линией: медиана s Пикара; {nu}")
                        add(case, typ, z, f"reverse{tag}", np.mean(g(f"u_free_{gate}")[und] < 0), "rel",
                            f"{gate}: доля точек под линией с u∥ < 0; {nu}")
                        add(case, typ, z, f"ur_over_Ue{tag}", np.nanmedian(g(f"ur_free_{gate}")[und]), "rel",
                            f"{gate}: медиана u_r/U_e под линией; {nu}")
                        add(case, typ, z, f"capped{tag}", np.mean(g(f"cap_free_{gate}")[und] > 0.5), "rel",
                            f"{gate}: доля точек под линией, где |u_r| упёрлось в 0,3·U_e (баланс ∫u dz = 0 не замкнут); {nu}")
                        add(case, typ, z, f"resid_abs_median{tag}", np.nanmedian(np.abs(g(f"resid_free_{gate}")[und])), "rel",
                            f"{gate}: медиана |∫u dz|/(max|u|·h) под линией; {nu}")
                        add(case, typ, z, f"delta_median{tag}", np.median(g(f"delta_{gate}")[und]), "m/s",
                            f"{gate}: медиана δ слоя смешения под линией, м (unit по схеме); {nu}")
                    ab = cov & ~und
                    if ab.any():
                        add(case, typ, z, f"above_err{tag}", np.mean(((sf - sref) / sref)[ab]), "rel",
                            f"{gate}: над зоной выше линии: среднее rel {var}; n={int(ab.sum())}")
                        add(case, typ, z, f"above_err_jh{tag}", np.mean(((g('s_jh') - sref) / sref)[ab]), "rel",
                            f"{gate}: над зоной выше линии: среднее rel potential_jh; n={int(ab.sum())}")
                    out_ = ~cov
                    if out_.any():
                        add(case, typ, z, f"outside_err{tag}", np.mean(((sf - sref) / sref)[out_]), "rel",
                            f"{gate}: вне зоны: среднее rel {var}; n={int(out_.sum())}")
        st = info[case]
        nz = refs["norm"][case]["z_agl"]
        nt = "crest" if case != "ASK_TU03B" else "upstream"
        for gate in ("head", "slope"):
            for k, r in st[gate]["norm_ratio"].items():
                add(case, nt, nz, f"norm_{gate}_{k}", r, "rel", f"{gate}: отношение ({k}) / potential_jh в опорной точке "
                    "нормировки (среднее по группам): s делится на неё")
            add(case, "lee", 10.0, f"unconverged_{gate}", st[gate]["n_unconverged"], "s",
                f"{gate}: узлов листа (сумма по {st[gate]['groups']} группам) с max|Δγ|/U_ref ≥ 1e-3 после "
                f"{st[gate]['iters_max']} итераций (unit «s» — счётчик)")
    doc = dict(format="swg-ground", version=1, git=K.git_short(), created=K.now_iso(), task="swg-12",
               variants=VARIANTS, rows=rows, summary=summary, masts=masts, decomp=decomp, scan=[],
               base_check=dict(max_abs_ds_vs_swg1=base_check, note="max |s_potential_jh − out/swg-1| по точкам"),
               sheets=info)
    rp = RAW / "rotor.json"
    if rp.exists():
        doc["rotor"] = load(rp)
    K.dump_json(OUT / "ground.json", doc)
    (OUT / "tables.md").write_text(tables(doc))
    print("ground.json:", len(rows), "строк; base_check", base_check)


def tables(doc):
    S = {(s["case"], s["variant"], s["type"], s["z_agl"]): s for s in doc["summary"] if s["ref_kind"] == "picard_nom"}
    out = ["# SWG-12: таблицы (вывод `py -m freeline.run assemble`)", ""]
    out.append("## До/после против Пикара nom (справочно): n / доля в ±15 % / среднее rel")
    out.append("")
    out.append("| тип | z, м | случай | " + " | ".join(VS) + " |")
    out.append("|---|---|---|" + "---|" * len(VS))
    for t in K.MAIN_TYPES + ("upstream",):
        for z in ZS:
            for c in K.CASES:
                if (c, "potential_jh", t, z) not in S:
                    continue
                cells = []
                for v in VS:
                    s = S.get((c, v, t, z))
                    cells.append("–" if s is None else f"{s['n']} / {s['frac_tol']:.2f} / {s['mean_rel']:+.2f}")
                out.append(f"| {t} | {z:g} | {CS[c]} | " + " | ".join(cells) + " |")
    out += ["", "## Мачты (эталон): RMSE s / доля в ±15 % / среднее rel к измерению", ""]
    rr = defaultdict(list)
    for r in doc["rows"]:
        if r["ref_kind"] == "mast":
            rr[(r["case"], r["variant"], r["type"])].append(r["rel_err"])
            rr[(r["case"], r["variant"], "all")].append(r["rel_err"])
    M = {(m["case"], m["variant"], m["type"]): m for m in doc["masts"]}
    out.append("| случай | тип | n | " + " | ".join(VS) + " |")
    out.append("|---|---|---|" + "---|" * len(VS))
    for c in K.CASES:
        for t in ("all",) + K.TYPES:
            if (c, "potential_jh", t) not in M:
                continue
            cells = []
            for v in VS:
                m = M.get((c, v, t))
                cells.append("–" if m is None else f"{m['rmse_s']:.3f} / {m['frac_tol']:.2f} / {np.mean(rr[(c, v, t)]):+.2f}")
            out.append(f"| {CS[c]} | {t} | {M[(c, 'potential_jh', t)]['n']} | " + " | ".join(cells) + " |")
    out += ["", "## Разложение (Пикар nom; under/above/outside — подмножества; триггер Хед, *_slope — уклон)", ""]
    terms = ("total_potential_jh", "total_zone_jh", "total_free_jh", "total_free_jh_slope", "zone_vs_sheet", "cover",
             "under", "zone_h_median", "under_err_jh", "under_err", "under_frac_tol", "under_med_s", "under_med_ref",
             "above_err_jh", "above_err", "outside_err", "reverse", "ur_over_Ue", "capped", "resid_abs_median",
             "delta_median", "cover_slope", "under_slope", "zone_h_median_slope", "under_err_slope", "above_err_slope")
    D = {(d["case"], d["type"], d["z_agl"], d["term"]): d["value"] for d in doc["decomp"]}
    out.append("| случай | тип | z | " + " | ".join(terms) + " |")
    out.append("|---|---|---|" + "---|" * len(terms))
    for c in K.CASES:
        for t in K.TYPES:
            for z in ZS:
                if (c, t, z, "total_free_jh") not in D:
                    continue
                out.append(f"| {CS[c]} | {t} | {z:g} | " + " | ".join(
                    f"{D[(c, t, z, k)]:+.3f}" if (c, t, z, k) in D else "–" for k in terms) + " |")
    out += ["", "## Линия и лист по случаям", ""]
    out.append("| случай | триггер | отрезков | мост | узлов | h_max медиана/p90, м | L медиана, м | η − z_гребня медиана/max, м | "
               "u_b / u_sep (лин.) | итераций max | несошедшихся | δ медиана, м | δ урезано | поднято слоёв | "
               "опорная точка free | время тонкий/слои, с |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for c in K.CASES:
        for gate in ("head", "slope"):
            g = doc["sheets"][c][gate]
            gm = g["geom"]
            if not gm.get("n_segs"):
                out.append(f"| {CS[c]} | {gate} | 0 | – | 0 | – | – | – | – | – | – | – | – | – | {g['norm_ratio']['zone']:.3f} | – |")
                continue
            f = lambda v, fm: "–" if v is None else format(v, fm)
            out.append(f"| {CS[c]} | {gate} | {gm['n_segs']} | {gm['n_bridge']} | {gm['n_nodes']} | {gm['hmax_median']:.0f}/"
                       f"{gm['hmax_p90']:.0f} | {gm['L_median']:.0f} | {gm['bulge_median']:.1f}/{gm['bulge_max']:.0f} | "
                       f"{gm['u_b_median']:.2f} / {gm['u_sep_median']:.2f} | {g['iters_max']} | {g['n_unconverged']} | "
                       f"{f(g['dw_median'], '.0f')} | {f(g['dcap_frac_mean'], '.2f')} | {f(g['lifted_frac_mean'], '.2f')} | "
                       f"{g['norm_ratio']['zone']:.3f} | {g['t_thin_s']:.0f}/{g['t_mix_s']:.0f} |")
    if "rotor" in doc:
        out += ["", "## Ротор по разрезам SWD1 (критерий SWD5: u∥ < −0,5 м/с на 15 м, > 50 м)", "",
                "| случай | разрез | вариант | есть | L, м | глубина, м | u_min 15 м, м/с | L Menke | L Пикар nom | глубина Пикар |",
                "|---|---|---|---|---|---|---|---|---|---|"]
        for r in doc["rotor"]["rows"]:
            out.append(f"| {CS[r['case']]} | {r['transect']} | {r['variant']} | {'да' if r['present'] else 'нет'} | "
                       f"{r['L_m']:.0f} | {r['depth_m']:.0f} | {r['u_min_15']:+.2f} | {r['L_menke']} | {r['L_picard_nom']} | "
                       f"{r['depth_picard_nom']} |")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    main()
