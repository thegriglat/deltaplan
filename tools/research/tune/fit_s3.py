"""AM-09, масштаб 3: пороги признака отрыва (lee.field_deficit_attached/separated, field_descent_slope)
по ТКЭ на мачтах Askervein.

Наблюдаемая (то же определение в модели и данных): ТКЭ на 10 м (для CP — 5/10/16 м) над землёй,
отнесённая к ТКЭ на опорной мачте RS на 10 м; только трёхкомпонентные анемометры Gill UVW
(Taylor & Teunissen 1985; Zenodo 4095052). Отношение снимает общую недооценку дисперсии прибором.
σ данных — 15 % отношения (назн.: статистика 3-ч ряда ~10 %, разная частотная характеристика в
следе ~10 %). Модель — масштаб 3 игры (turb_askervein.gd: FieldTurbulence + WindField.turb_at) на
поле Askervein 12,5 м + 2-й порядок с найденными λ/h, z0 (fit_s1); σ сетки — |12,5 м − 25 м|.

  godot --headless --path . -s tools/research/tune/turb_askervein.gd -- \
      --points=tools/research/tune/out/tke_points.json --out=tools/research/tune/out/tke_model.json \
      tools/research/tune/fields/ask_12p5_best tools/research/tune/fields/ask_25_best \
      tools/research/tune/fields/ask_50a_best tools/research/tune/fields/ask_12p5_nom
  .venv/bin/python fit_s3.py → out/fit_s3.json, out/fig_s3_tke.png
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
SIG_REL = 0.15
NOMINAL = (0.3, 0.4, 0.05)          # AM-08: field_deficit_attached, separated − attached, field_descent_slope


def group(n):
    if n.startswith("ANE") or n.startswith("AANE"):
        return "подветренная сторона"
    if n.startswith("HT") or n.startswith("CP"):
        return "вершина"
    return "наветренная сторона"


def ratios(rows, names):
    out = {}
    for r in rows:
        key = (round(r["ex0"], 2), round(r["width"], 2), round(r["desc"], 3))
        ref = r["pts"]["RS_10"]["tke"]
        out[key] = np.array([r["pts"][n]["tke"] / ref for n in names])
    return out


def main():
    pts = json.loads((OUT / "tke_points.json").read_text())
    ref = next(p for p in pts if p["name"] == "RS_10")
    obs = [p for p in pts if p["name"] != "RS_10"]
    names = [p["name"] for p in obs]
    d = np.array([p["tke"] / ref["tke"] for p in obs])
    sd = SIG_REL * d
    M = json.loads((OUT / "tke_model.json").read_text())
    best = ratios(M["ask_12p5_best"], names)
    coarse = ratios(M["ask_25_best"], names)
    game = ratios(M["ask_50a_best"], names)
    nomf = ratios(M["ask_12p5_nom"], names)
    table = []
    for key, y in best.items():
        sg = np.abs(y - coarse[key])
        t = (y - d) ** 2 / (sd ** 2 + sg ** 2)
        table.append((float(t.sum()), key, t, y, sg))
    table.sort(key=lambda r: r[0])
    chi2, kbest, tbest, ybest, sgbest = table[0]
    # профиль по ex0
    prof = {}
    for c, key, *_ in table:
        prof[key[0]] = min(prof.get(key[0], 1e30), c)
    nom = next(r for r in table if r[1] == NOMINAL)
    groups = {}
    for n, t in zip(names, tbest):
        groups.setdefault(group(n), []).append(float(t))
    lee_only = min(((float(r[2][[group(n) == "подветренная сторона" for n in names]].sum()), r[1]) for r in table))
    raw = {p: M["ask_12p5_best"][0]["pts"][p] for p in ["RS_10"] + names}
    res = dict(best=dict(ex0=kbest[0], width=kbest[1], desc=kbest[2], chi2=chi2, ndf=len(names) - 3),
               nominal=dict(key=NOMINAL, chi2=nom[0]),
               profile_ex0=sorted(prof.items()),
               groups={g: dict(n=len(v), chi2=sum(v)) for g, v in groups.items()},
               lee_only_best=dict(chi2=lee_only[0], key=lee_only[1]),
               obs=[dict(name=n, grp=group(n), data=float(d[i]), sig_data=float(sd[i]), model=float(ybest[i]),
                         sig_grid=float(sgbest[i]), model_game50=float(game[kbest][i]), model_nom_field=float(nomf[kbest][i]),
                         chi2=float(tbest[i]), lee=raw[n]["lee"], su=raw[n]["su"], sw=raw[n]["sw"], ustar=raw[n]["ustar"],
                         u=raw[n]["u"]) for i, n in enumerate(names)],
               rs=raw["RS_10"], rs_data_tke=ref["tke"])
    (OUT / "fit_s3.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))
    print("лучшее", res["best"], "номинал χ²", round(nom[0], 1))
    print("по группам", {g: (v["n"], round(v["chi2"], 1)) for g, v in res["groups"].items()})
    print("профиль ex0", [(k, round(v, 1)) for k, v in res["profile_ex0"]])
    print("только подветренная", lee_only)
    for o in res["obs"]:
        print(f"  {o['name']:9s} данные {o['data']:.2f} модель {o['model']:.2f} ± {o['sig_grid']:.2f} (игра 50 м {o['model_game50']:.2f}) "
              f"lee {o['lee']:.2f} σu {o['su']:.2f} σw {o['sw']:.2f} u* {o['ustar']:.2f}")
    print("RS модель", raw["RS_10"], "данные ТКЭ", ref["tke"])
    fig(res)


def fig(res):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    o = res["obs"]
    x = np.arange(len(o))
    f, ax = plt.subplots(figsize=(8, 3.8))
    ax.errorbar(x, [p["data"] for p in o], yerr=[p["sig_data"] for p in o], fmt="ko", ms=4, label="Askervein (Gill UVW)")
    ax.errorbar(x + 0.15, [p["model"] for p in o], yerr=[p["sig_grid"] for p in o], fmt="s", color="#1f77b4", ms=4,
                label=f"модель, поле 12,5 м (ex0 {res['best']['ex0']:.2f}, ширина {res['best']['width']:.1f}, "
                      f"наклон {res['best']['desc']:.2f})")
    ax.plot(x + 0.3, [p["model_game50"] for p in o], "^", color="#ff7f0e", ms=4, label="то же, поле 50 м 1-й пор. (как в игре)")
    ax.set_xticks(x)
    ax.set_xticklabels([p["name"] for p in o], rotation=60)
    ax.set_ylabel("ТКЭ / ТКЭ(RS, 10 м)")
    ax.set_yscale("log")
    ax.grid(alpha=0.3)
    ax.legend(fontsize=8)
    f.tight_layout()
    f.savefig(OUT / "fig_s3_tke.png", dpi=110)
    plt.close(f)


if __name__ == "__main__":
    main()
