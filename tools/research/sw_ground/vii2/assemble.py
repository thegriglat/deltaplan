"""Сборка out/swg-11/ground.json (SWG2 v1) и tables.md из out/swg-11/raw/ (+ строки vii из out/swg-10/ground.json)."""
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
SW7 = K.SG / "out" / "swg-7" / "raw"          # маска зоны: zone_h > 0 (SWG-7; геометрия wake.run.make_grid "slope")
SW10 = K.SG / "out" / "swg-10" / "ground.json"
VARIANTS = {
    "potential": "SWD2 v5 потенциал: панели 3D + лог-фон, σ 40 м, ds_min 25 м, z0 — медиана растра; группы ≤ 40 (x, y) "
                 "с фокусом ds_min 25 м (как SWG-1; пересчитано, сверено с out/swg-1)",
    "potential_jh": "SWD2 v5 потенциал + внутренний слой Jackson–Hunt (ground.model.jh_parts); база SWG-1 (пересчитано, "
                    "сверено с out/swg-1)",
    "vii": "SWG-10 (строки скопированы из out/swg-10/ground.json): VII, слой δ0 = 500 м (весь АПС), полуобратная связь "
           "Carter ω = 0,2 со сглаживанием δ* 50 м; на Perdigão НЕ СОШЛОСЬ (60 итераций, последняя итерация), на "
           "Askervein сошлось",
    "vii2": "SWG-11 (основной): тонкий интегральный слой — внутренний слой JH, δ0 = l (l·ln(l/z0) = 2κ²L, L — медиана "
            "полуширины старшего гребня по профилям вдоль ветра), профили Coles, Карман + вовлечение Head, стоки "
            "равновесия слоя (l, U_l = bg_log(l)); над слоем — невязкий сдвиговый поток (потенциал панелей с лог-фоном) "
            "+ вдув σ_d = A⁻¹Q·(U_e δ*); связь одновременная: глобальный Ньютон по (a, λ, U_e) во всех узлах (GMRES с "
            "точным линеаризованным оператором связи, предобусловливатель — блок профиля с матрицей влияния "
            "вдув-линии), демпфирование XFOIL UPDATE; сетка слоя ds_min 100 м с фокусом во всех точках, поле в точках — "
            "группы ds_min 25 м; u = |U_o(max(z, δ))|·f(z)",
    "vii2_nc": "как vii2, но слой без связи: одна прогонка (SWG-10 bl.march, при H > 2,5 — H = const) по невязкому U_e "
               "без вдува; поле без вдува",
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
    sw10 = load(SW10)
    for case in K.CASES:
        pl = E.case_points(case, refs, pts)
        d = load(RAW / f"pts_{case}.json")
        assert d["ids"] == [p["id"] for p in pl]
        s7 = load(SW7 / f"pts_{case}.json")
        zh7 = dict(zip(s7["ids"], s7["zone_h"]))
        zone = np.array([(zh7.get(p["id"]) or 0.0) > 0 for p in pl])
        data[case] = (pl, d, zone)
        li = load(RAW / f"layer_{case}.json")
        layer_info[case] = li
        old = load(K.OUT_TASK / "raw" / f"base_{case}.json")
        oo = dict(zip(old["ids"], old["s_jh"]))
        dif = [abs(s - oo[i]) for i, s in zip(d["ids"], d["s_jh"]) if fin(s) and fin(oo.get(i))]
        base_check[case] = float(max(dif)) if dif else None
        for var, key in (("potential", "s_pot"), ("potential_jh", "s_jh"), ("vii2", "s_vii2"), ("vii2_nc", "s_vii2_nc")):
            for p, s in zip(pl, d[key]):
                if not fin(s) or p["s_ref"] <= 0:
                    continue
                rows.append(T.rel_row(case, var, p["id"], p["type"], p["z_agl"], p["kind"], p["s_ref"], s))
    rows += [r for r in sw10["rows"] if r["variant"] == "vii"]
    summary = T.summarize(rows)
    masts = T.mast_stats(rows)

    def add(case, typ, z, term, val, unit, note):
        if val is not None and math.isfinite(val):
            decomp.append(dict(case=case, type=typ, z_agl=float(z), term=term, value=float(val), unit=unit, note=note))

    for case in K.CASES:
        pl, d, zone = data[case]
        kind = np.array([p["kind"] for p in pl])
        typ_a = np.array([p["type"] for p in pl])
        z_a = np.array([p["z_agl"] for p in pl])
        okall = np.array([all(fin(d[k][i]) for k in ("s_pot", "s_jh", "s_vii2", "s_vii2_nc", "s_vii2_noblow"))
                          for i in range(len(pl))])
        sref_a = np.array([p["s_ref"] for p in pl])
        g = lambda k: np.array([np.nan if v is None else v for v in d[k]], float)
        S = {k: g(k) for k in ("s_pot", "s_jh", "s_vii2", "s_vii2_nc", "s_vii2_noblow", "sign_vii2", "cf", "theta",
                                "dstar", "delta", "H", "f")}
        for typ in K.TYPES:
            for z in ZS:
                base = (kind == "picard_nom") & (typ_a == typ) & (z_a == z) & okall
                subs = [("", base)]
                if typ == "lee":
                    subs += [("outzone_", base & ~zone), ("inzone_", base & zone)]
                for sub, msk in subs:
                    if not msk.any():
                        continue
                    sref = sref_a[msk]
                    nn = f"n={int(msk.sum())}; Пикар nom" + {"": "", "outzone_": "; лее вне зоны (zone_h SWG-7 = 0)",
                                                              "inzone_": "; лее в зоне (zone_h SWG-7 > 0)"}[sub]
                    m_ = lambda k: S[k][msk]
                    add(case, typ, z, sub + "total_jh", np.mean((m_("s_jh") - sref) / sref), "rel", f"среднее rel potential_jh (до); {nn}")
                    add(case, typ, z, sub + "total_vii2", np.mean((m_("s_vii2") - sref) / sref), "rel", f"среднее rel vii2 (после); {nn}")
                    add(case, typ, z, sub + "pot", np.mean((m_("s_pot") - sref) / sref), "rel",
                        f"потенциал (без слоя и вдува): среднее rel; {nn}")
                    add(case, typ, z, sub + "layer", np.mean((m_("s_vii2_noblow") - m_("s_pot")) / sref), "rel",
                        f"вклад слоя vii2 без вдува: mean((s_noblow − s_pot)/s_ref); {nn}")
                    add(case, typ, z, sub + "blow", np.mean((m_("s_vii2") - m_("s_vii2_noblow")) / sref), "rel",
                        f"вклад вдува σ_d: mean((s_vii2 − s_noblow)/s_ref); total_vii2 = pot + layer + blow; {nn}")
                    add(case, typ, z, sub + "coupling", np.mean((m_("s_vii2") - m_("s_vii2_nc")) / sref), "rel",
                        f"vii2 − vii2_nc: эффект одновременной связи против слоя без связи; {nn}")
                    add(case, typ, z, sub + "reverse", np.mean(m_("sign_vii2") < 0), "rel", f"доля точек с u∥ < 0 (f < 0) в vii2; {nn}")
                    add(case, typ, z, sub + "sep", np.mean(m_("cf") <= 0), "rel", f"доля точек над слоем с C_f ≤ 0 в vii2; {nn}")
                    add(case, typ, z, sub + "frac_in_layer", np.mean(z < m_("delta")), "rel", f"доля точек внутри слоя (z < δ); {nn}")
                    if sub == "":
                        layer_rows.append(dict(case=case, type=typ, z_agl=z, n=int(msk.sum()),
                                               theta_m=float(np.mean(m_("theta"))), dstar_m=float(np.mean(m_("dstar"))),
                                               delta_m=float(np.mean(m_("delta"))), H=float(np.mean(m_("H"))),
                                               H_max=float(np.max(m_("H"))), cf=float(np.mean(m_("cf"))),
                                               frac_sep=float(np.mean(m_("cf") <= 0)),
                                               frac_rev=float(np.mean(m_("sign_vii2") < 0)), f_mean=float(np.mean(m_("f")))))
        nr = [gr["norm"] for gr in d["groups"]]
        add(case, "crest" if case != "ASK_TU03B" else "upstream", refs["norm"][case]["z_agl"], "norm_vii2_over_jh",
            float(np.mean([q["vii2"] / q["jh"] for q in nr])), "rel",
            "отношение скорости vii2 / potential_jh в опорной точке (среднее по группам): s делится на неё")
    li_short = {c: {k: v for k, v in li.items() if k != "hist"} | {"hist_last": li["hist"][-1], "iters": len(li["hist"]) - 1}
                for c, li in layer_info.items()}
    carter = load(RAW / "carter_ASK.json") if (RAW / "carter_ASK.json").exists() else None
    parts = []
    for c, li in layer_info.items():
        if li["converged"]:
            parts.append(f"{c}: сошлось, ε = 1")
        else:
            parts.append(f"{c}: НЕ СОШЛОСЬ до ε = 1 — строки при ε = {li['eps_result']:.2f} (доля ускорения рельефа)")
    eps_note = "; ".join(parts)
    variants = dict(VARIANTS)
    variants["vii2"] = VARIANTS["vii2"] + "; продолжение по рельефу ε: " + eps_note
    variants["vii2_nc"] = VARIANTS["vii2_nc"]
    doc = dict(format="swg-ground", version=1, git=K.git_short(), created=K.now_iso(), task="swg-11",
               variants=variants, rows=rows, summary=summary, masts=masts, decomp=decomp, scan=[],
               base_check=dict(max_abs_ds_vs_swg1=base_check,
                               note="max |s_potential_jh (здесь) − s_potential_jh (out/swg-1)| по точкам"),
               layer=dict(rows=layer_rows, note="состояние слоя vii2 в точках Пикара nom по типам (средние): θ, δ*, δ — м; "
                                                "H, C_f, доли — безразмерные"),
               layer_info=li_short, newton_hist={c: li["hist"] for c, li in layer_info.items()}, carter_ASK=carter)
    K.dump_json(OUT / "ground.json", doc)
    (OUT / "tables.md").write_text(tables(doc))
    print("ground.json:", len(rows), "строк; base_check", base_check)


def tables(doc):
    S = {(s["case"], s["variant"], s["type"], s["z_agl"]): s for s in doc["summary"] if s["ref_kind"] == "picard_nom"}
    cs = {"ASK_TU03B": "ASK", "PERD_NE": "NE", "PERD_SW": "SW"}
    vs = ("potential_jh", "vii", "vii2", "vii2_nc")
    out = ["# SWG-11: таблицы (вывод `py -m vii2.run assemble`)", "",
           "## Мачты (главная): RMSE s / доля в ±15 % / среднее rel к измерению", ""]
    rr = defaultdict(list)
    for r in doc["rows"]:
        if r["ref_kind"] == "mast":
            rr[(r["case"], r["variant"], r["type"])].append(r["rel_err"])
            rr[(r["case"], r["variant"], "all")].append(r["rel_err"])
    Mm = {(m["case"], m["variant"], m["type"]): m for m in doc["masts"]}
    out.append("| случай | тип | n | " + " | ".join(vs) + " |")
    out.append("|---|---|---|" + "---|" * len(vs))
    for c in K.CASES:
        for t in ("all",) + K.TYPES:
            if (c, "potential_jh", t) not in Mm:
                continue
            cells = []
            for v in vs:
                m = Mm.get((c, v, t))
                cells.append("–" if m is None else f"{m['rmse_s']:.3f} / {m['frac_tol']:.2f} / {np.mean(rr[(c, v, t)]):+.2f}")
            out.append(f"| {cs[c]} | {t} | {Mm[(c, 'potential_jh', t)]['n']} | " + " | ".join(cells) + " |")
    out += ["", "## До/после против Пикара nom (справочно): n / доля в ±15 % / среднее rel / медиана rel", ""]
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
    out += ["", "## Разложение vii2 (средние rel по точкам Пикара nom): total_vii2 = pot + layer + blow", ""]
    terms = ("total_jh", "total_vii2", "pot", "layer", "blow", "coupling", "reverse", "sep", "frac_in_layer")
    D = {(d["case"], d["type"], d["z_agl"], d["term"]): d["value"] for d in doc["decomp"]}
    out.append("| случай | тип | z | " + " | ".join(terms) + " |")
    out.append("|---|---|---|" + "---|" * len(terms))
    for c in K.CASES:
        for t in K.TYPES + ("lee вне зоны", "lee в зоне"):
            pre, tt = {"lee вне зоны": ("outzone_", "lee"), "lee в зоне": ("inzone_", "lee")}.get(t, ("", t))
            for z in ZS:
                if (c, tt, z, pre + "total_vii2") not in D:
                    continue
                out.append(f"| {cs[c]} | {t} | {z:g} | " + " | ".join(
                    f"{D[(c, tt, z, pre + k)]:+.3f}" if (c, tt, z, pre + k) in D else "–" for k in terms) + " |")
    out += ["", "## Слой в точках (средние): θ, δ*, δ (м), H (среднее/макс), C_f, доля C_f ≤ 0, доля u∥ < 0, f", ""]
    out.append("| случай | тип | z | n | θ | δ* | δ | H | H max | C_f | отрыв | обратный ток | f |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in doc["layer"]["rows"]:
        out.append(f"| {cs[r['case']]} | {r['type']} | {r['z_agl']:g} | {r['n']} | {r['theta_m']:.2f} | {r['dstar_m']:.2f} | "
                   f"{r['delta_m']:.1f} | {r['H']:.2f} | {r['H_max']:.2f} | {r['cf']:.4f} | {r['frac_sep']:.2f} | "
                   f"{r['frac_rev']:.2f} | {r['f_mean']:.3f} |")
    out += ["", "## Сходимость Ньютона (сетка слоя)", ""]
    out.append("| случай | N | δ0 = l, м | L, м | узлов | профилей | ε итога | сошлось при ε = 1 | итераций Ньютона всего | "
               "отказов шага дуги | узлов на пределе a / λ | C_f < 0 узлов | H max | время, с |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for c, li in doc["layer_info"].items():
        h = li["hist_last"]
        out.append(f"| {cs[c]} | {li['N']} | {li['delta0']:.1f} | {li['L_rule']:.0f} | {li['n_nodes']} | {li['n_lines']} | "
                   f"{li['eps_result']:.3f} | {'да' if li['converged'] else 'нет'} (max|R| {h['rmax']:.1e}) | "
                   f"{li['iters_total']} | {li['n_arc_fail']} | {li['n_active']} / {li['n_active_lam']} | {li['n_sep_nodes']} | "
                   f"{li['H_max']:.2f} | {li.get('t_s', 0):.0f} |")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    main()
