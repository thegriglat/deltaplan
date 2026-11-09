"""Сборка out/swg-8/ground.json (SWG2 v1) и tables.md из out/swg-8/raw/."""
from __future__ import annotations

import json
import math
from collections import defaultdict

import numpy as np

from ground import common as K
from ground import evaluate as E
from ground import tables as T

from . import core as Z
from .run import OUT, RAW

ZS = (10.0, 50.0, 300.0)
SWG7 = K.SG / "out" / "swg-7" / "raw"
_GEO = ("лист SWG-7 (sheet.core, геометрия SWG-4: оболочка upper_hull от x_s до x_r, ряды поперёк ветра через 25 м, "
        "петли с ножками и возвратом под землёй, ядро 12,5 м, отражение σ_ex), γ — «rest» SWG-7 (итерации до "
        "max|Δγ|/U_ref < 1e-3, обрезка γ ≥ 0)")
_MIX = (f"Γ узла распределена по {Z.N_LAYERS} параллельным листам по толщине слоя смешения δ_ω = {Z.C_DW}·(s − x_s) "
        "(Brown & Roshko 1974), доли по профилю tanh (∝ sech² завихренности) на ζ ∈ [−δ_ω, δ_ω] от оболочки, сумма Γ та же; "
        "листы ниже core/2 подняты до core/2")
_ZONE = ("под оболочкой (z_agl < h) — скорость зоны: u∥ = G·u_h − (1 − G)·u_r·ln(z/z0)/ln(h/z0), G = 1 + tanh(2(z − h)/δ), "
         "u_h — модель на оболочке (непрерывно при z = h), u_r — из ∫₀ʰ u∥ dz = 0 (ψ = 0 на полу и разделяющей линии тока), "
         f"не больше {Z.C_MAX}·U_e (U_e — модель на h + δ); s = |u∥|")
VARIANTS = {
    "potential": "SWD2 v5 потенциал: панели 3D + лог-фон, σ 40 м, ds_min 25 м, z0 — медиана растра; группы ≤ 40 (x, y) "
                 "с фокусом ds_min 25 м (как SWG-1; пересчитано здесь)",
    "potential_jh": "SWD2 v5 потенциал + внутренний слой Jackson–Hunt (ground.model.jh_parts); база SWG-1 (пересчитано, "
                    "совпадает с out/swg-1)",
    "sheet_jh": "база SWG-7: potential_jh + тонкий вихревой лист над мёртвой зоной; " + _GEO + " (пересчитано здесь)",
    "sheet_jh_mix": "п. 2 без п. 1: как sheet_jh, но " + _MIX + "; внутренний слой JH всюду",
    "zone_jh_thin": "п. 1 без п. 2: тонкий лист sheet_jh, " + _ZONE + ", δ = core = 12,5 м",
    "zone_jh": "основной (п. 1 + п. 2): лист sheet_jh_mix, " + _ZONE + ", δ = max(δ_ω, core)",
    "sheet_jh_noclip": "проверка обрезки: как sheet_jh, но итерации γ без обрезки γ ≥ 0 (пересчёт только в группах, где "
                       "обрезка действовала; иначе = sheet_jh)",
}
SRC = {"potential": "s_pot", "potential_jh": "s_jh", "sheet_jh": "s_thin", "sheet_jh_mix": "s_mix",
       "zone_jh_thin": "s_zthin", "zone_jh": "s_zone", "sheet_jh_noclip": "s_noclip"}
VS = ("potential_jh", "sheet_jh", "sheet_jh_mix", "zone_jh_thin", "zone_jh")
CS = {"ASK_TU03B": "ASK", "PERD_NE": "NE", "PERD_SW": "SW"}


def load(p):
    return json.load(open(p))


def fin(v):
    return v is not None and math.isfinite(v)


def main():
    refs = E.load_refs()
    pts = load(K.OUT_POINTS)
    rows, decomp = [], []
    base_check, swg7_check, data, info = {}, {}, {}, {}
    for case in K.CASES:
        pl = E.case_points(case, refs, pts)
        d = load(RAW / f"pts_{case}.json")
        assert d["ids"] == [p["id"] for p in pl]
        data[case] = (pl, d)
        old = load(K.OUT_TASK / "raw" / f"base_{case}.json")
        oo = dict(zip(old["ids"], old["s_jh"]))
        dif = [abs(s - oo[i]) for i, s in zip(d["ids"], d["s_jh"]) if fin(s) and fin(oo.get(i))]
        base_check[case] = float(max(dif)) if dif else None
        o7 = load(SWG7 / f"pts_{case}.json")
        o7 = dict(zip(o7["ids"], o7["s_rest"]))
        dif = [abs(s - o7[i]) for i, s in zip(d["ids"], d["s_thin"]) if fin(s) and fin(o7.get(i))]
        swg7_check[case] = float(max(dif)) if dif else None
        for var, key in SRC.items():
            for p, s in zip(pl, d[key]):
                if not fin(s) or p["s_ref"] <= 0:
                    continue
                rows.append(T.rel_row(case, var, p["id"], p["type"], p["z_agl"], p["kind"], p["s_ref"], s))
        gs = d["groups"]
        th = [g["thin"] for g in gs]
        mx = [g["mix"] for g in gs]
        info[case] = dict(
            groups=len(gs), iters_max=max(g["iters"] for g in th), n_unconverged=int(sum(g["n_unconverged"] for g in th)),
            groups_unconverged=int(sum(not g["converged"] for g in th)), n_nodes=th[0]["n_nodes"],
            gamma_over_Uref_mean=float(np.mean([g.get("gamma_over_Uref", 0) for g in th])),
            n_clip_sum=int(sum(g["n_clip"] for g in th)), groups_clip=int(sum(g["n_clip"] > 0 for g in th)),
            noclip_unconverged=int(sum(g["noclip"]["n_unconverged"] for g in gs if "noclip" in g)),
            noclip_n_neg=int(sum(g["noclip"]["n_neg"] for g in gs if "noclip" in g)),
            n_layers=mx[0].get("n_layers"), dw_median=float(np.median([g["dw_median"] for g in mx if "dw_median" in g])),
            dw_max=float(max(g["dw_max"] for g in mx if "dw_max" in g)),
            lifted_frac_mean=float(np.mean([g["lifted_frac"] for g in mx if "lifted_frac" in g])),
            norm_ratio={k: float(np.mean([g[s][r] for g in gs])) for k, (s, r) in
                        dict(sheet_jh=("thin", "norm_ratio_sheet"), sheet_jh_mix=("mix", "norm_ratio_sheet"),
                             zone_jh_thin=("thin", "norm_ratio_zone"), zone_jh=("mix", "norm_ratio_zone")).items()},
            norm_under=any(g["thin"]["norm_under"] or g["mix"]["norm_under"] for g in gs),
            imbalance_max=float(max(max(g["thin"]["imbalance"], g["mix"]["imbalance"]) for g in gs)),
            t_thin_s=float(sum(g["t_s"] for g in th)), t_mix_s=float(sum(g["t_s"] for g in mx)),
            t_total_s=d["t_s"], geom=d["geom"])
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
                sjh = g("s_jh")
                add(case, typ, z, "mix_vs_thin", np.mean((g("s_mix") - g("s_thin")) / sref), "rel",
                    f"вклад п. 2 (слой смешения) при JH: mean((s_sheet_jh_mix − s_sheet_jh)/s_ref); {nn}")
                add(case, typ, z, "zone_vs_mix", np.mean((g("s_zone") - g("s_mix")) / sref), "rel",
                    f"вклад п. 1 (скорость зоны) при слое смешения: mean((s_zone_jh − s_sheet_jh_mix)/s_ref); {nn}")
                add(case, typ, z, "zone_vs_jh", np.mean((g("s_zone") - sjh) / sref), "rel",
                    f"полный вклад zone_jh относительно potential_jh; {nn}")
                add(case, typ, z, "clip_effect", np.mean(np.abs(g("s_noclip") - g("s_thin")) / sref), "rel",
                    f"влияние обрезки γ ≥ 0: mean|s_sheet_jh_noclip − s_sheet_jh|/s_ref; {nn}")
                und = g("under") > 0.5
                add(case, typ, z, "cover", np.mean(g("zone_h") > 0), "rel", f"доля точек над мёртвой зоной; {nn}")
                add(case, typ, z, "under", np.mean(und), "rel", f"доля точек под оболочкой (z_agl < h); {nn}")
                if und.any():
                    add(case, typ, z, "reverse_zone", np.mean(g("u_zone")[und] < 0), "rel",
                        f"zone_jh: доля точек под оболочкой с u∥ < 0 (обратный поток); n_under={int(und.sum())}")
                    add(case, typ, z, "ur_over_Ue", np.median(g("ur_zone")[und]), "rel",
                        f"zone_jh: медиана u_r/U_e под оболочкой; n_under={int(und.sum())}")
                    add(case, typ, z, "capped", np.mean(g("cap_zone")[und] > 0.5), "rel",
                        f"zone_jh: доля точек под оболочкой, где u_r ограничено {Z.C_MAX}·U_e (баланс ∫u dz = 0 не "
                        f"замкнут); n_under={int(und.sum())}")
                    add(case, typ, z, "under_err_jh", np.mean(((sjh - sref) / sref)[und]), "rel",
                        f"под оболочкой: среднее rel potential_jh; n_under={int(und.sum())}")
                    for var in ("sheet_jh", "sheet_jh_mix", "zone_jh_thin", "zone_jh"):
                        add(case, typ, z, f"under_err_{var}", np.mean(((g(SRC[var]) - sref) / sref)[und]), "rel",
                            f"под оболочкой: среднее rel {var}; n_under={int(und.sum())}")
                cov = (g("zone_h") > 0) & ~und
                if cov.any():
                    for var in ("potential_jh", "sheet_jh", "sheet_jh_mix", "zone_jh"):
                        add(case, typ, z, f"above_err_{var}", np.mean(((g(SRC[var]) - sref) / sref)[cov]), "rel",
                            f"над зоной выше оболочки: среднее rel {var}; n={int(cov.sum())}")
                add(case, typ, z, "jh_reverse_mix", np.mean(1.0 + g("A") * g("dS_mix") < 0), "rel",
                    f"доля точек, где 1 + A·ΔS < 0 (JH даёт обратный поток) с листами слоя смешения; {nn}")
        st = info[case]
        nz = refs["norm"][case]["z_agl"]
        nt = "crest" if case != "ASK_TU03B" else "upstream"
        for var, r in st["norm_ratio"].items():
            add(case, nt, nz, f"norm_{var}", r, "rel", f"отношение {var} / potential_jh в опорной точке нормировки "
                "(среднее по группам): s делится на неё")
        add(case, "lee", 10.0, "unconverged", st["n_unconverged"], "s",
            f"узлов листа (сумма по {st['groups']} группам), где max|Δγ|/U_ref ≥ 1e-3 после {st['iters_max']} итераций "
            "(unit «s» — счётчик)")
        add(case, "lee", 10.0, "n_clip", st["n_clip_sum"], "s",
            f"узлов, где на итоговом γ действует обрезка γ ≥ 0 (сумма по группам; групп с обрезкой {st['groups_clip']})")
    doc = dict(format="swg-ground", version=1, git=K.git_short(), created=K.now_iso(), task="swg-8",
               variants=VARIANTS, rows=rows, summary=summary, masts=masts, decomp=decomp, scan=[],
               base_check=dict(max_abs_ds_vs_swg1=base_check, max_abs_ds_sheet_jh_vs_swg7=swg7_check,
                               note="max |s_potential_jh − out/swg-1| и |s_sheet_jh − out/swg-7 s_rest| по точкам"),
               sheets=info)
    K.dump_json(OUT / "ground.json", doc)
    (OUT / "tables.md").write_text(tables(doc))
    print("ground.json:", len(rows), "строк; base_check", base_check, "swg7", swg7_check)


def tables(doc):
    S = {(s["case"], s["variant"], s["type"], s["z_agl"]): s for s in doc["summary"] if s["ref_kind"] == "picard_nom"}
    out = ["# SWG-8: таблицы (вывод `py -m zone.run assemble`)", ""]
    out.append("## До/после против Пикара nom: n / доля в ±15 % / среднее rel")
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
    out += ["", "## Мачты: RMSE s / доля в ±15 % / среднее rel к измерению", ""]
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
    out += ["", "## Разложение (средние по точкам Пикара nom; under_*/above_* — подмножества)", ""]
    terms = ("total_potential_jh", "total_sheet_jh", "total_sheet_jh_mix", "total_zone_jh_thin", "total_zone_jh",
             "mix_vs_thin", "zone_vs_mix", "cover", "under", "under_err_jh", "under_err_sheet_jh", "under_err_zone_jh",
             "above_err_potential_jh", "above_err_sheet_jh_mix", "above_err_zone_jh", "reverse_zone", "ur_over_Ue",
             "capped", "jh_reverse_mix", "clip_effect")
    D = {(d["case"], d["type"], d["z_agl"], d["term"]): d["value"] for d in doc["decomp"]}
    out.append("| случай | тип | z | " + " | ".join(terms) + " |")
    out.append("|---|---|---|" + "---|" * len(terms))
    for c in K.CASES:
        for t in K.TYPES:
            for z in ZS:
                if (c, t, z, "total_zone_jh") not in D:
                    continue
                out.append(f"| {CS[c]} | {t} | {z:g} | " + " | ".join(
                    f"{D[(c, t, z, k)]:+.3f}" if (c, t, z, k) in D else "–" for k in terms) + " |")
    out += ["", "## Лист и слой смешения по случаям", ""]
    out.append("| случай | узлов | групп | γ/U_ref | итераций max | несошедшихся | обрезка (узлов/групп) | слоёв | "
               "δ_ω медиана/max, м | поднято слоёв | опорная точка zone_jh | время тонкий/слои/всего, с |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for c in K.CASES:
        g = doc["sheets"][c]
        out.append(f"| {CS[c]} | {g['n_nodes']} | {g['groups']} | {g['gamma_over_Uref_mean']:.2f} | {g['iters_max']} | "
                   f"{g['n_unconverged']} | {g['n_clip_sum']}/{g['groups_clip']} | {g['n_layers']} | "
                   f"{g['dw_median']:.0f}/{g['dw_max']:.0f} | {g['lifted_frac_mean']:.2f} | "
                   f"{g['norm_ratio']['zone_jh']:.3f} | {g['t_thin_s']:.0f}/{g['t_mix_s']:.0f}/{g['t_total_s']:.0f} |")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    main()
