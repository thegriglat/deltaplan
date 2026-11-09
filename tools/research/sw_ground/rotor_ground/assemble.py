"""Сборка out/swg-5/ground.json (SWG2 v1), ridges.json и tables.md из out/swg-5/raw/ и out/swg-1/."""
from __future__ import annotations

import json
import math
from collections import defaultdict

import h5py
import numpy as np

from ground import common as K
from ground import evaluate as E
from ground import tables as T

OUT = K.SG / "out" / "swg-5"
RAW = OUT / "raw"
SWG1 = K.SG / "out" / "swg-1" / "ground.json"
SWG2 = K.SG / "out" / "swg-2" / "rotor.json"
BAND, TYPES_Z = 200.0, (10.0, 50.0)
VARIANTS = {
    "potential_jh": "SWD2 v5 потенциал + внутренний слой Jackson–Hunt (velocity_jh) — база SWG-1: σ 40 м, ds_min 25 м, z0 — медиана растра "
                    "(Askervein 0,03 м; Perdigão 1,80 м), лог-фон; без отрыва и нитей; сетки панелей — группы ≤ 40 точек (SWG-1)",
    "rotor_jh": "potential_jh + нить ротора rotor3d v2 (SWD7: closure reattach, R_rule 0,25, gate slope, slope_min 0,27; те же панели/σ/z0/фон): "
                "нить (геометрия, Γ) — из прогона SWG-2 на сетке случая, на каждой групповой сетке панели решены с extra = induced(fil), "
                "поле velocity_jh(couple=True); корень Γ на групповых сетках не перебирался",
}


def main():
    refs = E.load_refs()
    pts = json.load(open(K.OUT_POINTS))
    g1 = json.load(open(SWG1))
    rows = [r for r in g1["rows"] if r["variant"] == "potential_jh"]
    key1 = {(r["case"], r["id"]): r for r in rows}
    base_ds = 0.0
    pls, raws = {}, {}
    for case in K.CASES:
        pl = E.case_points(case, refs, pts)
        raw = json.load(open(RAW / f"rot_{case}.json"))
        assert raw["ids"] == [p["id"] for p in pl]
        pls[case], raws[case] = pl, raw
        for p, sj, sr in zip(pl, raw["s_jh"], raw["s_rot"]):
            if sj is None or sr is None or not (p["s_ref"] > 0):
                continue
            r1 = key1.get((case, p["id"]))
            if r1 is not None:
                base_ds = max(base_ds, abs(r1["s_pan"] - sj))
            rows.append(T.rel_row(case, "rotor_jh", p["id"], p["type"], p["z_agl"], p["kind"], p["s_ref"], sr))
    rows = T.finite_rows(rows)
    summ, masts = T.summarize(rows), T.mast_stats(rows)

    # decomp: вклад нити по типам
    acc = defaultdict(lambda: defaultdict(list))
    for case in K.CASES:
        for p, sj, sr, sf in zip(pls[case], raws[case]["s_jh"], raws[case]["s_rot"], raws[case]["s_rot_fixnorm"]):
            if p["kind"] != "picard_nom" or sj is None or sr is None:
                continue
            a = acc[(case, p["type"], p["z_agl"])]
            a["rotfix"].append((sf - p["s_ref"]) / p["s_ref"])
            a["jh"].append((sj - p["s_ref"]) / p["s_ref"])
            a["rot"].append((sr - p["s_ref"]) / p["s_ref"])
            a["d"].append((sr - sj) / p["s_ref"])
            a["moved"].append(abs(sr - sj) > 0.03 * p["s_ref"])
    dec = []
    for (c, t, z), a in sorted(acc.items()):
        use = "справочно" if z < 50 else "эталон"
        n = len(a["d"])
        for term, val, unit, note in (
                ("total", np.mean(a["rot"]), "rel", f"среднее rel_err rotor_jh = jh_base + rotor; n={n}; Пикар nom, {use}"),
                ("jh_base", np.mean(a["jh"]), "rel", f"среднее rel_err potential_jh (SWG-1, без нити); n={n}"),
                ("rotor", np.mean(a["d"]), "rel", f"вклад нити: mean((s_rotor_jh − s_potential_jh)/s_ref); n={n}"),
                ("total_fixnorm", np.mean(a["rotfix"]), "rel", f"диагностика: mean rel_err rotor_jh при нормировке скоростью опорной точки БЕЗ нити; n={n}"),
                ("rotor_abs", np.mean(np.abs(a["d"])), "rel", f"mean|s_rotor_jh − s_potential_jh|/s_ref; n={n}"),
                ("rotor_moved", np.mean(a["moved"]), "rel", f"доля точек, где нить сдвинула s больше чем на 0,03·s_ref; n={n}")):
            dec.append(dict(case=c, type=t, z_agl=float(z), term=term, value=float(val), unit=unit, note=note))

    # scan: чувствительность к пересчёту корня Γ на групповой сетке
    scan = []
    for case in K.CASES:
        for k, s in enumerate(json.load(open(RAW / f"sens_{case}.json"))["groups"]):
            for m in ("rms_diff_case_vs_group", "max_abs_diff_case_vs_group", "rms_effect_case", "mean_rel_case", "mean_rel_group",
                      "mean_rel_jh"):
                scan.append(dict(case=case, variant="rotor_jh", param="Gamma_root_on_group_grid", value=float(k), metric=f"{m}_g{s['group']}",
                                 result=s[m]))
    doc = dict(format="swg-ground", version=1, git=K.git_short(), created=K.now_iso(), task="swg-5", variants=VARIANTS,
               rows=rows, summary=summ, masts=masts, decomp=dec, scan=scan,
               scan_codes={"note": "scan: value = номер группы в паре (0 — с наибольшим эффектом нити); метрики — _g<номер группы SWG-1>"},
               base_check=dict(max_abs_ds_potential_jh_vs_swg1=base_ds))
    K.dump_json(OUT / "ground.json", doc)
    print("ground.json", len(rows), "строк; макс |Δs| базы против SWG-1", base_ds)
    ridges(pls, raws, rows)
    tables(summ, masts, dec)


def wind_of(case):
    with h5py.File(K.REFS / f"{case}.h5", "r") as h:
        return np.array(h.attrs["wind_to"], float)


def ridges(pls, raws, rows):
    """Окна за хребтами SWG-2: ложный ротор / подтверждённый Пикаром / без нити; точки типа любого на 10, 50 м и мачты."""
    rot = json.load(open(SWG2))
    out, cat_pts = [], defaultdict(dict)
    for case in K.CASES:
        wt = wind_of(case)
        n_ = np.array([-wt[1], wt[0]])
        pl = pls[case]
        P = np.array([[p["x"], p["y"]] for p in pl])
        for r in [r for r in rot["ridges"] if r["case"] == case]:
            cat = ("не поставлена" if not r["placed"] else "ложный" if r["false_rotor"] else
                   "подтверждён Пикаром/Menke" if (r["picard_reverse"] or r["menke_rotor_nearby"]) else "прочие")
            c0 = np.array(r["x_y_c"])
            d = P - c0
            al, ac = d @ wt, np.abs(d @ n_)
            ins = (al >= 0) & (al <= r["window_m"]) & (ac <= BAND)
            for i in np.nonzero(ins)[0]:
                sj, sr = raws[case]["s_jh"][i], raws[case]["s_rot"][i]
                if sj is None or sr is None:
                    continue
                p = pl[i]
                if p["kind"] == "picard_nom" and p["z_agl"] not in TYPES_Z:
                    continue
                prio = {"ложный": 3, "подтверждён Пикаром/Menke": 2, "прочие": 1, "не поставлена": 0}[cat]
                old = cat_pts[(case, cat)].get(p["id"])
                cat_pts[(case, cat)][p["id"]] = dict(kind=p["kind"], type=p["type"], z=p["z_agl"], ref=p["s_ref"], sj=sj, sr=sr,
                                                     uj=raws[case]["upar_jh"][i], ur=raws[case]["upar_rot"][i])
            out.append(dict(case=case, ridge=r["ridge"], cat=cat, n_points=int(ins.sum()), window_m=r["window_m"],
                            slope_max=r["slope_max"], Gamma=r["Gamma"], R=r["R"]))
    agg = []
    for (case, cat), pp in sorted(cat_pts.items()):
        for kind, grp in (("picard_nom", [v for v in pp.values() if v["kind"] == "picard_nom"]),
                          ("mast", [v for v in pp.values() if v["kind"] == "mast"])):
            if not grp:
                continue
            ref = np.array([v["ref"] for v in grp])
            sj = np.array([v["sj"] for v in grp])
            sr = np.array([v["sr"] for v in grp])
            ej, er = (sj - ref) / ref, (sr - ref) / ref
            agg.append(dict(case=case, category=cat, ref_kind=kind, n=len(grp),
                            mean_rel_jh=float(ej.mean()), mean_rel_rotor=float(er.mean()),
                            mean_abs_rel_jh=float(abs(ej).mean()), mean_abs_rel_rotor=float(abs(er).mean()),
                            frac_tol_jh=float((abs(ej) <= K.TOL).mean()), frac_tol_rotor=float((abs(er) <= K.TOL).mean()),
                            rmse_s_jh=float(np.sqrt(np.mean((sj - ref) ** 2))), rmse_s_rotor=float(np.sqrt(np.mean((sr - ref) ** 2))),
                            frac_reverse_rotor=float(np.mean([(v["ur"] or 0) < 0 for v in grp])),
                            frac_reverse_jh=float(np.mean([(v["uj"] or 0) < 0 for v in grp]))))
    K.dump_json(OUT / "ridges.json", dict(format="swg5-ridges", version=1, git=K.git_short(), created=K.now_iso(),
                                          window="от гребня вниз по ветру на window_m (SWG-2), полоса ±200 м; точки SWG1 10 и 50 м и мачты",
                                          ridges=out, aggregate=agg))
    print("ridges.json", len(agg), "агрегатов")


def tables(summ, masts, dec):
    L = ["# SWG-5: нить ротора на плотных точках (до = potential_jh, после = rotor_jh)", ""]
    L += ["## Доля в ±15 % Пикара nom и средняя ошибка", "", "| случай | тип | z, м | n | до: доля | после: доля | до: mean | после: mean | вклад нити |", "|---|---|---|---|---|---|---|---|---|"]
    S = {(s["case"], s["variant"], s["type"], s["z_agl"]): s for s in summ if s["ref_kind"] == "picard_nom"}
    D = {(d["case"], d["type"], d["z_agl"]): d["value"] for d in dec if d["term"] == "rotor"}
    for case in K.CASES:
        for t in K.TYPES:
            for z in K.HEIGHTS:
                a, b = S.get((case, "potential_jh", t, z)), S.get((case, "rotor_jh", t, z))
                if a and b:
                    L.append(f"| {case} | {t} | {z:g} | {a['n']} | {a['frac_tol']:.3f} | {b['frac_tol']:.3f} | {a['mean_rel']:+.3f} | {b['mean_rel']:+.3f} | {D[(case, t, z)]:+.3f} |")
    F = {(d["case"], d["type"], d["z_agl"]): d["value"] for d in dec if d["term"] == "total_fixnorm"}
    L += ["", "## Диагностика: нормировка опорной точкой без нити (mean rel_err rotor_jh)", "", "| случай | тип | z, м | mean (norm с нитью) | mean (norm без нити) |", "|---|---|---|---|---|"]
    for case in K.CASES:
        for t in ("lee", "valley"):
            for z in (10.0, 50.0):
                b = S.get((case, "rotor_jh", t, z))
                if b:
                    L.append(f"| {case} | {t} | {z:g} | {b['mean_rel']:+.3f} | {F[(case, t, z)]:+.3f} |")
    L += ["", "## Мачты: RMSE s", "", "| случай | тип | n | до | после | доля ±15 % до | после |", "|---|---|---|---|---|---|---|"]
    M = {(m["case"], m["variant"], m["type"]): m for m in masts}
    for (case, v, t), m in sorted(M.items()):
        if v == "potential_jh":
            b = M[(case, "rotor_jh", t)]
            L.append(f"| {case} | {t} | {m['n']} | {m['rmse_s']:.3f} | {b['rmse_s']:.3f} | {m['frac_tol']:.2f} | {b['frac_tol']:.2f} |")
    (OUT / "tables.md").write_text("\n".join(L) + "\n")


if __name__ == "__main__":
    main()
