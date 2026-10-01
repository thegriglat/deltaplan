#!/usr/bin/env python3
"""WPC-2: итог профилей ветра у стартов (out/wind_profile.csv, К5) — сводная таблица, сравнение
с литературой (Taylor & Lee 1984), графики. Запуск: python3 wind_audit.py (из любого места).

Справочные формулы (только для сравнения, не модель игры):
- Taylor & Lee (1984), Boundary-Layer Meteorol. 29: разгон на вершине на высоте z над землёй
  ΔS(z) = B·(H/L)·exp(−A·z/L); 3D-холм B = 1,6, A = 4; 2D-гребень B = 2,0, A = 3;
  H — превышение над окружающей местностью, L — расстояние от вершины против ветра до
  половины высоты. Применимость — пологие склоны (H/L ≲ 0,3–0,5, без отрыва).
- Над вершиной при «ветер меню = U на 10 м над стартом» профиль, согласный с этим разгоном и с тем же
  набегающим степенным профилем: U_top(z)/U_menu = (z/10)^α·(1 + ΔS(z))/(1 + ΔS(10)).
- Динамический подъём в потенциальном обтекании у поверхности: w ≈ U·sinθ (θ — уклон склона).
"""
import csv
import json
import math
import os
from collections import defaultdict

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get("AUDIT_OUT", os.path.join(HERE, "out", "after"))
FIG = os.path.join(OUT, "fig")
os.makedirs(FIG, exist_ok=True)

TRIM_MS = (8.6, 10.8)  # трим мягких крыльев (31–39 км/ч), план WPC
C = {"analytic": "#2a78d6", "field": "#eb6834", "tl84": "#1baf7a", "grid": "#d9d8d4", "ink": "#52514e"}


def load():
    rows = defaultdict(dict)
    for r in csv.DictReader(open(os.path.join(OUT, "wind_profile.csv"))):
        k = (r["location"], r["start"], r["mode"], float(r["wind_set_ms"]))
        rows[k][(float(r["offset_m"]), float(r["agl_m"]))] = {
            c: float(r[c]) for c in ("u_h_ms", "u_along_ms", "w_ms", "u_profile_model_ms", "msl_m", "ground_msl_m")
        }
    meta = {}
    for line in open(os.path.join(OUT, "wind_profile_meta.jsonl")):
        m = json.loads(line)
        meta[(m["location"], m["start"], m["mode"], float(m["wind_set_ms"]))] = m
    terr = json.load(open(os.path.join(OUT, "terrain_lines.json")))
    return rows, meta, terr


def geometry(t):
    """H, L (Taylor & Lee) и уклоны по линии ветра через старт; старт считается вершиной."""
    xs, hs = t["offset"], t["h"]
    h = dict(zip(xs, hs))
    h0 = h[0.0] if 0.0 in h else h[0]
    up = [(x, y) for x, y in zip(xs, hs) if x <= 0]
    hmin = min(y for _, y in up)
    H = h0 - hmin
    L = None
    for x, y in sorted(up, key=lambda p: -p[0]):  # от старта против ветра
        if y <= h0 - H / 2:
            L = -x
            break
    crest = max(y for x, y in zip(xs, hs) if 0 <= x <= 500)

    def slope(a, b):
        return math.degrees(math.atan((h[b] - h[a]) / (b - a)))

    return {
        "H": H, "L": L, "h0": h0, "crest_above_start_500m": crest - h0,
        "theta_0_50": slope(-50.0, 0.0), "theta_50_150": slope(-150.0, -50.0),
        "theta_150_300": slope(-300.0, -150.0), "theta_0_30": slope(-25.0, 0.0),
    }


def tl84(z, H, L, B=1.6, A=4.0, phi_max=0.3):
    """Taylor & Lee 1984 (3D-холм); для крутых склонов H/L > 0,3 длина берётся L_e = H/0,3
    (ограничение действующего уклона, как в EN 1991-1-4, прил. A.3): линейная теория разгона
    применима к пологим склонам, у крутых разгон насыщается."""
    Le = max(L, H / phi_max)
    return B * H / Le * math.exp(-A * z / Le)


def main():
    rows, meta, terr = load()
    sites = sorted({(k[0], k[1]) for k in rows})
    geo = {s: geometry(terr["%s/%s" % s]) for s in sites if "%s/%s" % s in terr}
    agls = [10.0, 50.0, 100.0, 200.0, 300.0]
    summ = []
    for (loc, st, mode, wv), d in sorted(rows.items()):
        if wv == 0:
            continue
        g = geo[(loc, st)]
        m = meta[(loc, st, mode, wv)]
        rec = {"location": loc, "start": st, "mode": mode, "wind_set_ms": wv, "alpha": round(m["alpha"], 3),
               "class": m["stability_class"], "H_m": round(g["H"]), "L_m": g["L"],
               "theta_0_50": round(g["theta_0_50"], 1), "theta_50_150": round(g["theta_50_150"], 1)}
        for o, tag in ((0.0, "st"), (-150.0, "sl")):
            for a in agls:
                rec["U%s_%d" % (tag, a)] = round(d[(o, a)]["u_along_ms"], 2)
                rec["R%s_%d" % (tag, a)] = round(d[(o, a)]["u_along_ms"] / wv, 2)
        # разбег: встречный на высоте крыла 1,5 м (ground_run.gd:84) на старте и на 10–30 м перед ним
        rec["Urun15"] = round(sum(d[(o, 1.5)]["u_along_ms"] for o in (0.0, -10.0, -20.0, -30.0)) / 4, 2)
        rec["Urun3"] = round(sum(d[(o, 3.0)]["u_along_ms"] for o in (0.0, -10.0, -20.0, -30.0)) / 4, 2)
        # полоса динамика: перед стартом 30–300 м, 10–200 м над склоном
        band = [(o, a) for o in (-30.0, -50.0, -150.0, -300.0) for a in (10.0, 30.0, 50.0, 100.0, 200.0)]
        ws = [d[p]["w_ms"] for p in band]
        rec["w_max"] = round(max(ws), 2)
        best = max(band, key=lambda p: d[p]["w_ms"])
        rec["w_max_at"] = "%d/%d" % best
        rec["w_sl_50"] = round(d[(-150.0, 50.0)]["w_ms"], 2)
        rec["w_sl_100"] = round(d[(-150.0, 100.0)]["w_ms"], 2)
        rec["w_50_30"] = round(d[(-50.0, 30.0)]["w_ms"], 2)
        th = math.radians(g["theta_50_150"])
        rec["UsinT_10"] = round(d[(-150.0, 10.0)]["u_along_ms"] * math.sin(th), 2)
        # разгон к собственной опоре: аналитика — к той же высоте над землёй в 3 км против ветра,
        # поле — к профилю притока решателя U_menu·min((z/10)^α, max) (u_profile без множителя высоты)
        for a in (10.0, 50.0, 100.0):
            if mode == "field":
                ref = wv * min((max(a, 1.0) / 10) ** m["alpha"], m["max_profile"])
            else:
                # аналитика: разгона нет, только множитель высоты (wind_model.gd:139–143) — вершина
                # против подножия холма (на H ниже) на той же высоте над землёй
                ref = d[(0.0, a)]["u_along_ms"] * (1 + 0.6 * (a - g["H"]) / 1000) / (1 + 0.6 * a / 1000)
            rec["dS_%d" % a] = round(d[(0.0, a)]["u_along_ms"] / ref - 1, 2) if ref > 0.05 else None
        if g["L"]:
            rec["dS_TL84_10"] = round(tl84(10, g["H"], g["L"]), 2)
            rec["dS_TL84_100"] = round(tl84(100, g["H"], g["L"]), 2)
            a = m["alpha"]
            for z in (50.0, 100.0, 200.0):
                rec["Rtl_%d" % z] = round((z / 10) ** a * (1 + tl84(z, g["H"], g["L"])) / (1 + tl84(10, g["H"], g["L"])), 2)
        summ.append(rec)
    keys = list(summ[0].keys())
    for r in summ:
        for k in r:
            if k not in keys:
                keys.append(k)
    with open(os.path.join(OUT, "wind_summary.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, keys)
        w.writeheader()
        w.writerows(summ)
    json.dump({"%s/%s" % k: v for k, v in geo.items()}, open(os.path.join(OUT, "hill_geometry.json"), "w"), indent=1)
    write_md(summ)
    zero_check(rows)
    plots(rows, meta, geo, summ)
    plot_ratio(rows)


def write_md(summ):
    lines = ["| старт | ветер | режим | α (класс) | над стартом U10 / 50 / 100 / 200 м (U/U_меню) | над склоном −150 м: U 50 / 100 / 200 | разбег U на 1,5 м | w макс в полосе (offset/agl) | w −150/50, −150/100 | U·sinθ (−150, 10 м) | ΔS 10/100 модель | ΔS 10/100 TL84 | TL84: U/U_меню 50/100/200 |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in summ:
        lines.append(
            "| {location}/{start} | {wind_set_ms:g} | {mode} | {alpha} ({class}) | {Ust_10} / {Ust_50} / {Ust_100} / {Ust_200} ({Rst_10} / {Rst_50} / {Rst_100} / {Rst_200}) | {Usl_50} / {Usl_100} / {Usl_200} | {Urun15} | {w_max} ({w_max_at}) | {w_sl_50}, {w_sl_100} | {UsinT_10} | {dS_10} / {dS_100} | {tl10} / {tl100} | {rtl} |".format(
                tl10=r.get("dS_TL84_10"), tl100=r.get("dS_TL84_100"),
                rtl="%s / %s / %s" % (r.get("Rtl_50"), r.get("Rtl_100"), r.get("Rtl_200")), **r))
    open(os.path.join(OUT, "wind_summary.md"), "w").write("\n".join(lines) + "\n")


def zero_check(rows):
    mx = defaultdict(float)
    for (loc, st, mode, wv), d in rows.items():
        if wv == 0:
            for (o, a), v in d.items():
                mx[mode] = max(mx[mode], abs(v["u_h_ms"]))
    json.dump(mx, open(os.path.join(OUT, "calm_check.json"), "w"))
    print("штиль: max |U_h|", dict(mx))


def _ax(ax):
    ax.grid(True, color=C["grid"], lw=0.6)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    ax.tick_params(colors=C["ink"], labelsize=8)


def plots(rows, meta, geo, summ):
    agl = [1.0, 1.5, 2.0, 3.0, 5.0, 10.0, 30.0, 50.0, 100.0, 200.0, 300.0]
    sites = sorted({(k[0], k[1]) for k in rows})
    # 1. U/U_меню над стартом: аналитика, поле, TL84 — по ветрам 3, 6, 10
    fig, axs = plt.subplots(1, 3, figsize=(12, 4.6), sharey=True)
    for ax, wv in zip(axs, (3.0, 6.0, 10.0)):
        for mode in ("analytic", "field"):
            first = True
            for s in sites:
                d = rows.get((s[0], s[1], mode, wv))
                if not d:
                    continue
                ax.plot([d[(0.0, a)]["u_along_ms"] / wv for a in agl], agl, color=C[mode], lw=1.2 if mode == "field" else 1.0,
                        alpha=0.85, label=("аналитика" if mode == "analytic" else "поле (GPU)") if first else None)
                first = False
        first = True
        for s in sites:
            g = geo[s]
            m = meta.get((s[0], s[1], "analytic", wv))
            if not g["L"] or not m:
                continue
            z = [a for a in agl if a >= 10]
            ax.plot([(a / 10) ** m["alpha"] * (1 + tl84(a, g["H"], g["L"])) / (1 + tl84(10, g["H"], g["L"])) for a in z], z,
                    color=C["tl84"], lw=1.0, ls="--", label="Taylor & Lee 1984 (тот же α, U10 на старте)" if first else None)
            first = False
        ax.axvspan(TRIM_MS[0] / wv, TRIM_MS[1] / wv, color="#eda100", alpha=0.15, label="трим 8,6–10,8 м/с")
        ax.axvline(1.0, color=C["ink"], lw=0.6)
        ax.set_yscale("log")
        ax.set_xlim(0, max(3.0, TRIM_MS[1] / wv + 0.2))
        ax.set_title("ветер меню %g м/с" % wv, fontsize=10)
        ax.set_xlabel("встречный ветер над стартом / ветер меню", fontsize=9)
        _ax(ax)
    axs[0].set_ylabel("высота над землёй, м", fontsize=9)
    axs[0].legend(fontsize=7, loc="upper left", frameon=False)
    fig.suptitle("Профиль ветра над стартом: 10 стартов (поле — где посчитано)", fontsize=11)
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, "01_profile_over_start.png"), dpi=130)
    plt.close(fig)

    # 2. Абсолютный ветер над стартом при 6 м/с против трима
    fig, ax = plt.subplots(figsize=(6, 4.6))
    for mode in ("analytic", "field"):
        first = True
        for s in sites:
            d = rows.get((s[0], s[1], mode, 6.0))
            if d:
                ax.plot([d[(0.0, a)]["u_along_ms"] for a in agl], agl, color=C[mode], lw=1.1,
                        label=("аналитика" if mode == "analytic" else "поле (GPU)") if first else None)
                first = False
    ax.axvspan(*TRIM_MS, color="#eda100", alpha=0.2, label="трим мягких крыльев")
    ax.axvline(6.0, color=C["ink"], lw=0.6, ls=":")
    ax.set_yscale("log")
    ax.set_xlabel("встречный ветер над стартом, м/с", fontsize=9)
    ax.set_ylabel("высота над землёй, м", fontsize=9)
    ax.set_title("Ветер меню 6 м/с: где ветер сильнее трима", fontsize=10)
    ax.legend(fontsize=8, frameon=False, loc="lower right")
    _ax(ax)
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, "02_wind6_vs_trim.png"), dpi=130)
    plt.close(fig)

    # 3. Разбег: встречный на 1,5 м (высота крыла) от ветра меню
    fig, ax = plt.subplots(figsize=(6, 4.2))
    for mode, mk in (("analytic", "o"), ("field", "s")):
        for wv in (0.0, 3.0, 6.0, 10.0):
            vals = []
            for s in sites:
                d = rows.get((s[0], s[1], mode, wv))
                if d:
                    vals += [d[(o, 1.5)]["u_along_ms"] for o in (0.0, -10.0, -20.0, -30.0)]
            if vals:
                x = [wv + (-0.15 if mode == "analytic" else 0.15)] * len(vals)
                ax.scatter(x, vals, s=14, color=C[mode], marker=mk, alpha=0.6,
                           label=("аналитика" if mode == "analytic" else "поле (GPU)") if wv == 3.0 else None)
    ax.plot([0, 10], [0, 10], color=C["ink"], lw=0.6, ls=":", label="= ветру меню")
    ax.set_xlabel("ветер меню, м/с", fontsize=9)
    ax.set_ylabel("встречный на 1,5 м над землёй, м/с", fontsize=9)
    ax.set_title("Разбег: ветер у крыла на старте и 10–30 м перед ним", fontsize=10)
    ax.legend(fontsize=8, frameon=False)
    _ax(ax)
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, "03_takeoff_wind.png"), dpi=130)
    plt.close(fig)

    # 4. Динамический подъём: w над склоном (−150 и −50 м) по высоте, 3 и 6 м/с
    fig, axs = plt.subplots(1, 2, figsize=(10, 4.6), sharey=True)
    z = [10.0, 30.0, 50.0, 100.0, 200.0, 300.0]
    for ax, wv in zip(axs, (3.0, 6.0)):
        for mode in ("analytic", "field"):
            first = True
            for s in sites:
                d = rows.get((s[0], s[1], mode, wv))
                if d:
                    ax.plot([d[(-150.0, a)]["w_ms"] for a in z], z, color=C[mode], lw=1.0,
                            label=("аналитика, 150 м перед стартом" if mode == "analytic" else "поле, 150 м перед стартом") if first else None)
                    first = False
        ax.axvspan(0.8, 1.35, color="#e87ba4", alpha=0.2, label="мин. снижение крыльев 0,8–1,35 м/с")
        ax.axvline(0, color=C["ink"], lw=0.6)
        ax.set_title("ветер меню %g м/с" % wv, fontsize=10)
        ax.set_xlabel("вертикальный поток w, м/с", fontsize=9)
        _ax(ax)
    axs[0].set_ylabel("высота над склоном, м", fontsize=9)
    axs[0].legend(fontsize=7, frameon=False, loc="upper right")
    fig.suptitle("Динамический подъём над склоном перед стартом (термики выключены)", fontsize=11)
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, "04_ridge_lift.png"), dpi=130)
    plt.close(fig)

    # 5. Разрез у двух стартов с полем: рельеф и стрелки ветра (аналитика / поле), 6 м/с
    for s in [("ongudai", "kayancha_south"), ("aushkul", "aushtau_east"), ("altai", "sinyukha_east")]:
        if (s[0], s[1], "field", 6.0) not in rows:
            continue
        t = __import__("json").load(open(os.path.join(OUT, "terrain_lines.json")))["%s/%s" % s]
        fig, axs = plt.subplots(2, 1, figsize=(9, 6.5), sharex=True)
        for ax, mode in zip(axs, ("analytic", "field")):
            d = rows[(s[0], s[1], mode, 6.0)]
            ax.fill_between(t["offset"], [h - t["start_msl"] for h in t["h"]], -800, color="#cfcac0")
            for (o, a), v in d.items():
                if o < -1000 or a < 10:
                    continue
                y = v["ground_msl_m"] + a - t["start_msl"]
                ax.quiver(o, y, v["u_along_ms"], v["w_ms"], angles="xy", scale_units="xy", scale=0.06, width=0.003,
                          color=C[mode])
                if o in (0.0, -150.0) and a in (10.0, 100.0, 300.0):
                    ax.annotate("%.1f" % v["u_along_ms"], (o, y), fontsize=7, color=C["ink"], xytext=(3, 3), textcoords="offset points")
            ax.set_xlim(-1100, 400)
            ax.set_ylim(min(h - t["start_msl"] for h, x in zip(t["h"], t["offset"]) if -1100 <= x <= 400) - 50, 380)
            ax.set_title("%s/%s, ветер 6 м/с слева направо, %s (стрелки — u вдоль ветра и w, числа — U, м/с)" % (s[0], s[1], "аналитика" if mode == "analytic" else "поле"), fontsize=9)
            ax.set_ylabel("высота над стартом, м", fontsize=8)
            _ax(ax)
        axs[1].set_xlabel("расстояние от старта по линии ветра, м (− перед стартом, откуда дует)", fontsize=8)
        fig.tight_layout()
        fig.savefig(os.path.join(FIG, "05_section_%s_%s.png" % s), dpi=130)
        plt.close(fig)


def plot_ratio(rows):
    """U на 10 и 100 м над стартом / ветер меню по стартам (6 м/с), аналитика и поле."""
    sites = sorted({(k[0], k[1]) for k in rows if k[2] == "field"})
    fig, ax = plt.subplots(figsize=(9, 4.2))
    x = range(len(sites))
    for i, (mode, a, off) in enumerate((("analytic", 10.0, -0.3), ("field", 10.0, -0.1), ("analytic", 100.0, 0.1), ("field", 100.0, 0.3))):
        v = [rows[(s[0], s[1], mode, 6.0)][(0.0, a)]["u_along_ms"] / 6.0 for s in sites]
        ax.bar([j + off for j in x], v, width=0.18, color=C[mode], alpha=1.0 if a == 10 else 0.5,
               label="%s, %d м" % ("аналитика" if mode == "analytic" else "поле", a))
    ax.axhspan(8.6 / 6, 10.8 / 6, color="#eda100", alpha=0.18, label="трим / 6 м/с")
    ax.axhline(1.0, color=C["ink"], lw=0.6)
    ax.set_xticks(list(x))
    ax.set_xticklabels(["%s/%s" % s for s in sites], fontsize=7, rotation=25, ha="right")
    ax.set_ylabel("U над стартом / ветер меню", fontsize=9)
    ax.set_title("Ветер меню 6 м/с: сколько получается над стартом", fontsize=10)
    ax.legend(fontsize=7, frameon=False, ncol=3)
    _ax(ax)
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, "06_ratio_over_start_6ms.png"), dpi=130)
    plt.close(fig)


if __name__ == "__main__":
    main()
