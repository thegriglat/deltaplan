"""Сборка out/swg-4/ground.json (SWG2 v1) и tables.md из out/swg-4/raw/."""
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
                 "сетка — группы ≤ 40 (x, y) с фокусом ds_min 25 м (как SWG-1; пересчитано здесь, совпадает с out/swg-1)",
    "potential_jh": "SWD2 v5 потенциал + внутренний слой Jackson–Hunt (ground.model.jh_parts = velocity_jh), остальное как "
                    "potential; база SWG-1 (пересчитано, совпадает с out/swg-1)",
    "wake_jh": "potential_jh + заряды вытеснения следа (Lighthill 1958): выдув v_n = d(U_e·δ*)/ds на панелях за отрывом "
               "(новая правая часть, те же LU), JH с ΔS из полного внешнего поля (couple). Триггер «slope»: гребень "
               "crests_profile, подветренный уклон lee_slope > 0,27, x_r — rotor3d.profile_rule (подножие / середина "
               "долины); δ* = высота «натянутой нити» (верхняя выпуклая оболочка профиля) над землёй + δ_ω/2·(1 − ξ), "
               "δ_ω = 0,181·(s − x_s) (Brown & Roshko 1974); U_e — касательная скорость невязкого решения со следом, "
               "4 итерации; профили вдоль ветра шаг 12,5 м, поперёк 25 м",
    "wake_jh_head": "как wake_jh, но след ставится только за гребнями, у которых Хед (panels3d.separation3d, lee_only) по "
                    "скоростям потенциал + след wake_jh (сетка ds_min 50 м, фокус во всех точках) находит отрыв в "
                    "подветренном отрезке (≤ 100 м от точки отрыва в плане — порог SWG-1 head_cover)",
}
WAKE = {"wake_jh": "slope", "wake_jh_head": "head"}


def load(p):
    return json.load(open(p))


def fin(v):
    return v is not None and math.isfinite(v)


def main():
    refs = E.load_refs()
    pts = load(K.OUT_POINTS)
    rows, decomp = [], []
    base_check = {}
    grids = {}
    data = {}
    for case in K.CASES:
        pl = E.case_points(case, refs, pts)
        d = load(RAW / f"pts_{case}.json")
        assert d["ids"] == [p["id"] for p in pl]
        data[case] = (pl, d)
        grids[case] = load(RAW / f"grid_{case}.json")
        old = load(K.OUT_TASK / "raw" / f"base_{case}.json")
        oo = dict(zip(old["ids"], old["s_jh"]))
        dif = [abs(s - oo[i]) for i, s in zip(d["ids"], d["s_jh"]) if fin(s) and fin(oo.get(i))]
        base_check[case] = float(max(dif)) if dif else None
        for var, key in (("potential", "s_pot"), ("potential_jh", "s_jh"), ("wake_jh", "s_slope"),
                         ("wake_jh_head", "s_head")):
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
                       and all(fin(d[k][i]) for k in ("s_jh", "s_slope", "s_head"))]
                if not idx:
                    continue
                sref = np.array([pl[i]["s_ref"] for i in idx])
                g = lambda k: np.array([d[k][i] for i in idx])
                sjh, spot = g("s_jh"), g("s_pot")
                nn = f"n={len(idx)}; Пикар nom"
                add(case, typ, z, "total_jh", np.mean((sjh - sref) / sref), "rel", f"среднее rel_err potential_jh (до); {nn}")
                for var, v in WAKE.items():
                    sw, spw = g(f"s_{v}"), g(f"spw_{v}")
                    sfx = "" if v == "slope" else "_head"
                    add(case, typ, z, f"total{sfx}", np.mean((sw - sref) / sref), "rel", f"среднее rel_err {var} (после); {nn}")
                    add(case, typ, z, f"wake{sfx}", np.mean((sw - sjh) / sref), "rel",
                        f"вклад следа в {var}: mean((s_{var} − s_potential_jh)/s_ref) = total{sfx} − total_jh; {nn}")
                    add(case, typ, z, f"wake_outer{sfx}", np.mean((spw - spot) / sref), "rel",
                        f"изменение внешнего (потенциального) поля в точке от зарядов следа без JH: mean((s_pot+след − s_pot)/s_ref); {nn}")
                    add(case, typ, z, f"wake_dS{sfx}", np.mean(g(f"dSw_{v}")), "rel",
                        f"средняя добавка следа к ΔS внутреннего слоя (в долях U_ref) на max(z_agl, l); < 0 — торможение; {nn}")
                    ds_ = g(f"dstar_{v}")
                    add(case, typ, z, f"wake_cover{sfx}", np.mean(ds_ > 0), "rel", f"доля точек над следом (δ* > 0); {nn}")
                    add(case, typ, z, f"wake_inside{sfx}", np.mean(ds_ > z), "rel", f"доля точек внутри тела вытеснения (z_agl < δ*); {nn}")
                    add(case, typ, z, f"wake_conv{sfx}", np.max(np.abs(sw - g(f"s_{v}_prev"))), "s",
                        f"сходимость итераций U_e: max |s(итерация 4) − s(итерация 3)|; {nn}")
        for v, sfx in (("slope", ""), ("head", "_head")):
            st = grids[case][v]
            if st["frac_gated_picard_reverse"] is not None:
                add(case, "lee", 10.0, f"picard_reverse{sfx}", st["frac_gated_picard_reverse"], "rel",
                    f"доля подветренных отрезков со следом ({st['n_gated']} из {st['n_segs']} на {st['n_lines']} профилях), "
                    f"где у Пикара nom на 10 м есть обратное течение u∥ < 0; остальное — след без отрыва у Пикара")
        nr = [gr["slope"]["norm_ratio"] for gr in d["groups"]]
        add(case, "crest" if case != "ASK_TU03B" else "upstream", refs["norm"][case]["z_agl"], "norm_wake", float(np.mean(nr)),
            "rel", "отношение скорости wake_jh / potential_jh в опорной точке нормировки (среднее по группам): "
                   "s делится на неё — торможение опорной точки следом повышает все s")
    doc = dict(format="swg-ground", version=1, git=K.git_short(), created=K.now_iso(), task="swg-4",
               variants=VARIANTS, rows=rows, summary=summary, masts=masts, decomp=decomp, scan=[],
               base_check=dict(max_abs_ds_vs_swg1=base_check,
                               note="max |s_potential_jh (здесь) − s_potential_jh (out/swg-1)| по точкам"),
               grids={c: {k: grids[c][k] for k in ("n_sep_pot", "n_sep_wake", "N_head", "slope", "head", "head_iters")}
                      for c in K.CASES})
    K.dump_json(OUT / "ground.json", doc)
    (OUT / "tables.md").write_text(tables(doc))
    print("ground.json:", len(rows), "строк; base_check", base_check)


def tables(doc):
    S = {(s["case"], s["variant"], s["type"], s["z_agl"]): s for s in doc["summary"] if s["ref_kind"] == "picard_nom"}
    cs = {"ASK_TU03B": "ASK", "PERD_NE": "NE", "PERD_SW": "SW"}
    out = ["# SWG-4: таблицы (вывод `py -m wake.run assemble`)", ""]
    out.append("## До/после против Пикара nom: n / доля в ±15 % / среднее rel")
    out.append("")
    vs = ("potential_jh", "wake_jh", "wake_jh_head")
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
    terms = ("total_jh", "total", "wake", "wake_outer", "wake_dS", "wake_cover", "wake_inside", "wake_conv",
             "total_head", "wake_head", "wake_cover_head")
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
    out += ["", "## Следы по случаям", ""]
    out.append("| случай | триггер | профилей | отрезков | со следом | из них с u∥ < 0 у Пикара (10 м) | медиана δ*max, м | медиана уклона | отрывов Хеда |")
    out.append("|---|---|---|---|---|---|---|---|---|")
    for c in K.CASES:
        g = doc["grids"][c]
        for v in ("slope", "head"):
            st = g[v]
            f = lambda x, fmt: "–" if x is None else format(x, fmt)
            nh = f"{g['n_sep_pot']} (потенциал) / {g['n_sep_wake']} (со следом)" if v == "head" else "–"
            out.append(f"| {cs[c]} | {v} | {st['n_lines']} | {st['n_segs']} | {st['n_gated']} | "
                       f"{f(st['frac_gated_picard_reverse'], '.2f')} | {f(st['dmax_median'], '.0f')} | "
                       f"{f(st['slope_median_gated'], '.2f')} | {nh} |")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    main()
