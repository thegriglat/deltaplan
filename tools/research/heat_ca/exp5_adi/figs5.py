#!/usr/bin/env python3
"""Опыт 5 — картинки и таблицы из out/*.json (сначала exp5.py main/sweep/sweep2/timing, ref8h.py, fixedpoint.py).

  ../.venv/bin/python figs5.py      → out/*.png, out/tables.md, out/tables.json
"""
from __future__ import annotations

import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import plots  # noqa: E402  (стиль, рельеф)
from plots import draw_ground, SERIES, INK, MUTED, plt, TwoSlopeNorm  # noqa: E402
from exp5 import NAMES, CELLS, CONFIGS, config, HEAT_IT  # noqa: E402

OUT = os.path.join(HERE, "out")
TITLE = {"s1_sun_one_slope": "1. солнце на крутой склон", "s4_inversion": "4. инверсия на 1,5 км"}
CNAME = {"implicit_steps": "неявные шаги Δτ = 100 с (всё прогонками)",
         "lines_mg": "Δτ_θ = 4000 с, Δτ = 20 с, неявная плавучесть; давление — прогонки на уровнях",
         "lines_adi": "то же, давление — прогонки на одном уровне (Писмен–Рэчфорд)"}
CSHORT = {"implicit_steps": "неявные шаги Δτ=100 с", "lines_mg": "прогонки, давление многоуровн.",
          "lines_adi": "прогонки, давление 1 уровень (ПР)"}
CCOL = {200.0: SERIES[0], 100.0: SERIES[1], 50.0: SERIES[2], 25.0: SERIES[3]}


def load(p):
    return json.load(open(os.path.join(OUT, p)))


def automaton_curves():
    """Шаги по времени (эталон 10 ч, снимки каждые 10 мин): ошибка против неподвижной точки и 8 ч."""
    res = {}
    for name in NAMES:
        for cell in CELLS:
            r = np.load(os.path.join(OUT, "ref8h", f"{name}_{cell:g}.npz"))
            fx = np.load(os.path.join(OUT, "fixed", f"{name}_{cell:g}.npz"))["c"]
            ok = ~r["solid"]
            S = r["snaps"].astype(np.float32)
            c8 = r["c8"]

            def rel(a, b):
                return float(np.linalg.norm((a - b)[ok]) / np.linalg.norm(b[ok]))
            ef, e8 = [], []
            for s in S:
                ef.append([rel(s[1], fx[1]), rel(s[0], fx[0]), rel(s[2], fx[2])])
                e8.append([rel(s[1], c8[1]), rel(s[0], c8[0]), rel(s[2], c8[2])])
            steps = r["snap_steps"].tolist()
            info = json.loads(str(r["info"]))

            def first(e, thr, j=None):
                for st, x in zip(steps, e):
                    v = max(x) if j is None else x[j]
                    if v < thr:
                        return st
                return None
            res[f"{name}|{cell:g}"] = dict(steps=steps, ef=ef, e8=e8, dt=info["dt"], steps8=info["steps8"],
                                           hit_f={f"all<{t:g}": first(ef, t) for t in (0.05, 0.02, 0.01)},
                                           hit_8={f"all<{t:g}": first(e8, t) for t in (0.05, 0.02, 0.01)})
    return res


def fig_rounds(main):
    """Главная: ошибка против числа раундов по размерам клетки (lines_mg), s1 и s4."""
    for cname in CONFIGS:
        fig, axs = plt.subplots(1, 2, figsize=(12, 4.6), sharey=True)
        for ax, name in zip(axs, NAMES):
            for cell in CELLS:
                r = main.get(f"{cname}|{name}|{cell:g}")
                if not r:
                    continue
                n = [h[0] for h in r["hist"]]
                ef = [max(h[2]) for h in r["hist"]]
                e8 = [max(h[1]) for h in r["hist"]]
                ax.semilogy(n, ef, color=CCOL[cell], lw=1.8, label=f"{cell:g} м — к неподвижной точке")
                ax.semilogy(n, e8, color=CCOL[cell], lw=1.0, ls="--", label=f"{cell:g} м — к эталону «8 ч»")
            for t in (0.05, 0.01):
                ax.axhline(t, color=MUTED, lw=0.7, ls=":")
                ax.text(ax.get_xlim()[1] if False else 2, t * 1.08, f"{t:.0%}", color=MUTED, fontsize=8)
            ax.set_ylim(5e-4, 3)
            ax.set_title(TITLE[name])
            ax.grid(True, which="major", color="#e5e5e5", lw=0.6)
        axs[0].set_ylabel("ошибка max(w, u, θ′), отн. L2")
        fig.supxlabel("раундов (раунд = прогонки по столбцам и по слоям для тепла, u, w и давления)", fontsize=10)
        axs[1].legend(fontsize=7.5, ncol=2, loc="upper right", frameon=False)
        fig.suptitle(f"Опыт 5: {CNAME[cname]}", fontsize=11)
        fig.savefig(os.path.join(OUT, f"rounds_{cname}.png"))
        plt.close(fig)


def fig_time(main, auto, timing):
    """Ошибка против времени GPU: шаги по времени и три варианта прогонок, клетка 50 и 25 м."""
    for cell in (50.0, 25.0):
        fig, axs = plt.subplots(1, 2, figsize=(12, 4.6), sharey=True)
        ms_step = timing["automaton"][f"{cell:g}"]
        for ax, name in zip(axs, NAMES):
            a = auto[f"{name}|{cell:g}"]
            t = np.array(a["steps"]) * ms_step / 1e3
            ax.loglog(t, [max(e) for e in a["ef"]], color=INK, lw=2.0, label=f"шаги по времени ({ms_step:.2f} мс/шаг)")
            for j, cname in enumerate(CONFIGS):
                r = main.get(f"{cname}|{name}|{cell:g}")
                if not r:
                    continue
                ms = timing["rounds"][f"{cname}|{cell:g}"]["ms"]
                n = np.array([h[0] for h in r["hist"]])
                ax.loglog(n * ms / 1e3, [max(h[2]) for h in r["hist"]], color=SERIES[j + 1], lw=1.6,
                          label=f"{CSHORT[cname]} ({ms:.2f} мс/раунд)")
            for th in (0.05, 0.01):
                ax.axhline(th, color=MUTED, lw=0.7, ls=":")
            ax.set_ylim(5e-4, 3)
            ax.set_xlabel("время GPU, с (RTX 4070 SUPER, CuPy + CUDA Graph)")
            ax.set_title(f"{TITLE[name]}, клетка {cell:g} м")
            ax.grid(True, which="major", color="#e5e5e5", lw=0.6)
        axs[0].set_ylabel("ошибка к неподвижной точке max(w, u, θ′)")
        axs[0].legend(fontsize=8, frameon=False, loc="lower left")
        fig.savefig(os.path.join(OUT, f"time_{cell:g}.png"))
        plt.close(fig)


def fig_sweep(sw1, sw2):
    """Раундов до 1 % × псевдошаг: при общем Δτ раунды·Δτ ≈ const — итерации идут «физическим временем»."""
    fig, axs = plt.subplots(1, 2, figsize=(12, 4.4))
    ax = axs[0]
    for j, name in enumerate(NAMES):
        for cell, ls in ((100.0, "-"), (25.0, "--")):
            pts = sorted((r["cfg"]["dtau"], r["hit"]["fixed"].get("all<0.01")) for r in sw1
                         if r["name"] == name and r["cell"] == cell and r["cfg"].get("p_mode") == "lmg"
                         and not r["cfg"].get("schur") and r["cfg"]["heat_iters"] == 3 and r["cfg"]["p_iters"] == 2)
            x = [p[0] for p in pts]
            y = [p[1] if p[1] else np.nan for p in pts]
            ax.plot(x, y, ls, marker="o", color=SERIES[j], label=f"{TITLE[name]}, {cell:g} м")
            for xi, yi in zip(x, y):
                if not np.isfinite(yi):
                    ax.plot(xi, 800, "x", color=SERIES[j], ms=8)
    xx = np.linspace(80, 420, 50)
    ax.plot(xx, 30000 / xx, color=MUTED, lw=0.8, ls=":", label="30 000 с / Δτ (≈ 8 ч «физики»)")
    ax.set_xlabel("общий псевдошаг Δτ (тепло = импульс), с")
    ax.set_ylabel("раундов до ошибки < 1 % (× — разошлось)")
    ax.set_title("Стадия 1: один Δτ на всё")
    ax.set_ylim(0, 850)
    ax.legend(fontsize=7.5, frameon=False)
    ax = axs[1]
    pairs = [(100, 100), (120, 600), (120, 1200), (60, 1200), (40, 4000), (30, 4000), (20, 4000)]
    labels = [f"{a} / {b}" for a, b in pairs]
    for j, name in enumerate(NAMES):
        for k, cell in enumerate((100.0, 25.0)):
            look = {(r["cfg"]["dtau"], r["cfg"]["dtau_h"]): r["hit"]["fixed"].get("all<0.01") for r in sw2
                    if r["name"] == name and r["cell"] == cell and r["cfg"]["heat_iters"] == HEAT_IT[cell]}
            xs = np.arange(len(pairs)) + (j * 2 + k - 1.5) * 0.19
            y = [look.get((float(a), float(b))) for a, b in pairs]
            ax.bar(xs, [v or 0 for v in y], width=0.18, color=SERIES[j], alpha=1.0 if k == 0 else 0.45,
                   label=f"{TITLE[name]}, {cell:g} м (тепло ×{HEAT_IT[cell]})")
            for xi, v in zip(xs, y):
                if not v:
                    ax.text(xi, 6, "×", ha="center", color=SERIES[j], fontsize=10)
    ax.set_xticks(np.arange(len(labels)))
    ax.set_xticklabels(labels, rotation=25, fontsize=8)
    ax.set_xlabel("псевдошаг импульса Δτ / тепла Δτ_θ, с (неявная плавучесть)")
    ax.set_ylabel("раундов до < 1 % (× — не сошлось за 600)")
    ax.set_title("Стадия 2: крупный шаг тепла, мелкий — импульса")
    ax.legend(fontsize=7.5, frameon=False)
    fig.savefig(os.path.join(OUT, "sweep.png"))
    plt.close(fig)


def fig_fields():
    """Поле прогонок против эталона 8 ч: w и разность (s4, 50 м) — где сидит ошибка эталона."""
    from model import HeatCA, Params, SCENARIOS
    for name in NAMES:
        cell = 50.0
        m = HeatCA(SCENARIOS[name], Params(cell=cell))
        fx = np.load(os.path.join(OUT, "fixed", f"{name}_{cell:g}.npz"))["c"]
        r8 = np.load(os.path.join(OUT, "ref8h", f"{name}_{cell:g}.npz"))["c8"]
        d, xe, ze = plots.grid_info(m)
        fig, axs = plt.subplots(2, 2, figsize=(13, 6.6))
        for col, (j, lab, unit) in enumerate(((1, "w", "м/с"), (2, "θ′", "К"))):
            f = fx[j]
            lim = np.nanpercentile(np.abs(f), 99.5)
            ax = axs[0, col]
            pm = ax.pcolormesh(xe / 1000, ze / 1000, f, cmap="RdBu_r", norm=TwoSlopeNorm(0, -lim, lim))
            draw_ground(ax, m)
            fig.colorbar(pm, ax=ax, shrink=0.8, pad=0.01).set_label(f"{lab}, {unit}")
            ax.set_title(f"{lab}: неподвижная точка (прогонки)")
            ax = axs[1, col]
            dd = r8[j] - f
            l2 = np.nanpercentile(np.abs(dd), 99.5)
            pm = ax.pcolormesh(xe / 1000, ze / 1000, dd, cmap="PuOr_r", norm=TwoSlopeNorm(0, -l2, l2))
            draw_ground(ax, m)
            ok = np.isfinite(f)
            e = np.linalg.norm(dd[ok]) / np.linalg.norm(f[ok])
            fig.colorbar(pm, ax=ax, shrink=0.8, pad=0.01).set_label(f"Δ{lab}, {unit}")
            ax.set_title(f"эталон «8 ч шагов» минус неподвижная точка (отн. L2 = {e:.2%})")
        for ax in axs.ravel():
            ax.set_xlabel("x, км")
            ax.set_ylabel("z, км")
        fig.suptitle(f"{TITLE[name]}, клетка {cell:g} м: прогонки сходятся к полю автомата; "
                     f"эталон «8 ч» ещё не установился (медленная мода выхолаживания τ = 2 ч)", fontsize=10.5)
        fig.tight_layout()
        fig.savefig(os.path.join(OUT, f"fields_{name}.png"))
        plt.close(fig)


def fmt(x, nd=2):
    return "—" if x is None else (f"{x:.{nd}f}" if isinstance(x, float) else str(x))


def tables(main, auto, timing, fixed):
    L = []
    T = {}
    L.append("### Раунды прогонок до установившегося поля автомата (GPU RTX 4070 SUPER)\n")
    L.append("Ошибка — отн. L2 по воздушным клеткам, «все» = max(w, u, θ′). «К неподв.» — к точной неподвижной "
             "точке шага автомата (out/fixed, проверена автоматом: за 2 ч с неё поле уходит ≤ 4·10⁻⁴); "
             "«к 8 ч» — к эталону «8 ч шагов без остановки» (сам отстоит от неподвижной точки на 1,1–1,3 % по θ′, "
             "0,1–0,3 % по u, w). Время — раунды × мс/раунд (замер под замком GPU, CUDA Graph). Шаги по "
             "времени — тот же автомат с покоя, до той же ошибки к неподвижной точке.\n")
    L.append("| Сценарий | Клетка | Вариант | раундов до 5 % / 1 % (к неподв.) | до 5 % / 1 % к 8 ч: w, u / θ′ | мс/раунд | "
             "с до 5 % / 1 % | Шаги: шагов до 5 % / 1 % | мс/шаг | с до 5 % / 1 % | Выигрыш (1 %) |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for name in NAMES:
        for cell in CELLS:
            a = auto[f"{name}|{cell:g}"]
            mss = timing["automaton"][f"{cell:g}"]
            s5, s1 = a["hit_f"]["all<0.05"], a["hit_f"]["all<0.01"]
            for cname in CONFIGS:
                r = main.get(f"{cname}|{name}|{cell:g}")
                if not r:
                    continue
                ms = timing["rounds"][f"{cname}|{cell:g}"]["ms"]
                hf, h8 = r["hit"]["fixed"], r["hit"]["r8"]
                r5, r1 = hf.get("all<0.05"), hf.get("all<0.01")
                wu5 = max(h8.get("w<0.05") or 10**9, h8.get("u<0.05") or 10**9)
                wu1 = max(h8.get("w<0.01") or 10**9, h8.get("u<0.01") or 10**9)
                t5 = h8.get("th<0.05")
                t1 = h8.get("th<0.01")
                c8 = f"{fmt(wu5 if wu5 < 10**9 else None)} / {fmt(wu1 if wu1 < 10**9 else None)} ; {fmt(t5)} / {fmt(t1) if t1 else 'нет¹'}"
                g = (s1 * mss / 1e3) / (r1 * ms / 1e3) if (r1 and s1) else None
                row = dict(rounds5=r5, rounds1=r1, ms_round=ms, t5=r5 and r5 * ms / 1e3, t1=r1 and r1 * ms / 1e3,
                           steps5=s5, steps1=s1, ms_step=mss, ts5=s5 and s5 * mss / 1e3, ts1=s1 and s1 * mss / 1e3,
                           gain1=g, hit8=h8, cfg=r["cfg"])
                T[f"{cname}|{name}|{cell:g}"] = row
                L.append(f"| {TITLE[name]} | {cell:g} м | {CSHORT[cname]} | {fmt(r5)} / {fmt(r1)} | {c8} | {ms:.2f} | "
                         f"{fmt(row['t5'], 3)} / {fmt(row['t1'], 3)} | {fmt(s5)} / {fmt(s1)} | {mss:.2f} | "
                         f"{fmt(row['ts5'], 2)} / {fmt(row['ts1'], 2)} | {'×%.0f' % g if g else '—'} |")
    L.append("\n¹ θ′ к эталону «8 ч» < 1 % прогонки не дают и не должны: они сходятся к неподвижной точке, а эталон "
             "сам в 1,1–1,3 % от неё (шагам по времени нужно ~9–10 ч модели, чтобы войти в 1 %). Вариант «неявные "
             "шаги» проходит мимо эталона «8 ч» по пути (он и есть неявный счёт по времени с шагом 100 с), "
             "поэтому для него «до 1 % к 8 ч» — момент пролёта.\n")
    # проверка неподвижной точки
    L.append("### Неподвижная точка: проверка автоматом и отличие эталонов\n")
    L.append("| Сценарий | Клетка | Раундов (Δ < 2·10⁻⁶ м/с) | Невязка тепла / нагрев макс. | Дрейф автомата за 2 ч с неё: w, u, θ′ | "
             "Эталон 8 ч от неё: w, u, θ′ | 10 ч от неё | старый эталон out/refs от неё |")
    L.append("|---|---|---|---|---|---|---|---|")
    for name in NAMES:
        for cell in CELLS:
            f = fixed[f"{name}_{cell:g}"]
            r = np.load(os.path.join(OUT, "ref8h", f"{name}_{cell:g}.npz"))
            ok = ~r["solid"]
            fx = np.load(os.path.join(OUT, "fixed", f"{name}_{cell:g}.npz"))["c"]
            old = np.load(os.path.join(os.path.dirname(HERE), "out", "refs", f"{name}_{cell:g}.npz"))
            eo = [np.linalg.norm((old[k] - fx[j])[ok]) / np.linalg.norm(fx[j][ok]) for k, j in (("wc", 1), ("uc", 0), ("th", 2))]
            L.append(f"| {TITLE[name]} | {cell:g} м | {f['rounds']} | {f['res_heat'] / f['heat_src_max']:.1e} | "
                     + ", ".join(f"{x:.1e}" for x in f["drift_2h"]) + " | "
                     + ", ".join(f"{x:.2%}" for x in f["fixed_vs_8h"]) + " | "
                     + ", ".join(f"{x:.2%}" for x in f["fixed_vs_10h"]) + " | "
                     + ", ".join(f"{x:.1%}" for x in eo) + " |")
    return "\n".join(L), T


def estimate_3d(main, timing, T):
    """3D 40×40 км × 32 уровня. Две оценки мс/раунд:
    * «по замеру 2D» — нс на клетку·раунд самой большой 2D-сетки (1024×512) × 1,5 (6 проходов вместо 4,
      третья компонента скорости). В 2D там всего 512–1024 линии — ядро «поток на линию» упирается в
      задержку памяти, поэтому это ВЕРХНЯЯ граница;
    * «по пропускной способности» — точек-прогонок на клетку за раунд (bench_thomas.py) × 1,5 × 0,2 нс
      (замер ядра на массиве с десятками тысяч линий, как в 3D) + поэлементная часть ≈ 3 шага автомата.
    Раундов — как в 2D при той же клетке (максимум по s1/s4)."""
    bench = load("thomas_bench.json")
    ns_pt = max(bench["ns_per_point"]["12800x400|axis1"], bench["ns_per_point"]["32x160000|axis0"])
    L = ["### Оценка для 3D (квадрат 40×40 км × 32 уровня, тот же GPU)\n"]
    ms_auto_big = timing["automaton"]["6.25"]
    ns_auto = ms_auto_big * 1e6 / (1024 * 512)
    big = {}
    for cname in CONFIGS:
        ms_big = timing["rounds"][f"{cname}|6.25"]["ms"]
        pts = bench["per_round"].get(f"{cname}|25", bench["per_round"]["lines_mg|25"])["points_per_cell"]
        big[cname] = dict(ns_meas=ms_big * 1e6 / (1024 * 512), ns_bw=pts * ns_pt + 3 * ns_auto,
                          floor=min(v["ms"] for k, v in timing["rounds"].items() if k.startswith(cname + "|")))
    L.append("нс на клетку·раунд: по замеру 2D (1024×512, верхняя граница) — "
             + ", ".join(f"{CSHORT[c]} {big[c]['ns_meas']:.0f}" for c in CONFIGS if c != "implicit_steps")
             + f"; по пропускной способности (≈ {bench['per_round']['lines_mg|25']['points_per_cell']:.0f} точек-прогонок "
               f"на клетку за раунд × {ns_pt:.2f} нс + поэлементное ≈ 3 шага автомата) — "
             + ", ".join(f"{CSHORT[c]} {big[c]['ns_bw']:.0f}" for c in CONFIGS if c != "implicit_steps")
             + f". Шаг автомата — {ns_auto:.1f} нс на клетку·шаг. Всё × 1,5 за 3D. Раундов — как в 2D (макс. s1/s4), "
               "шагов автомата — до той же ошибки 1 % к неподвижной точке.\n")
    L.append("| Клетка | Ячеек 3D | Вариант | раундов (1 %) | мс/раунд (пропускн. … замер) | до 1 %, с | Шаги: шагов (1 %) | мс/шаг | до 1 %, с |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    rows = {}
    for cell in CELLS:
        n3 = (40000 / cell) ** 2 * 32
        s1 = max((T.get(f"lines_mg|{n}|{cell:g}", {}).get("steps1") or 0) for n in NAMES) or None
        msa = max(timing["automaton"]["200"], ns_auto * 1.5 * n3 / 1e6)
        for cname in CONFIGS:
            if cname == "implicit_steps":
                continue
            r1 = max((T.get(f"{cname}|{n}|{cell:g}", {}).get("rounds1") or 0) for n in NAMES) or None
            lo = max(big[cname]["floor"], big[cname]["ns_bw"] * 1.5 * n3 / 1e6)
            hi = max(big[cname]["floor"], big[cname]["ns_meas"] * 1.5 * n3 / 1e6)
            rows[f"{cname}|{cell:g}"] = dict(cells=n3, rounds=r1, ms_lo=lo, ms_hi=hi, t_lo=r1 and r1 * lo / 1e3,
                                             t_hi=r1 and r1 * hi / 1e3, steps=s1, ms_step=msa, ts=s1 and s1 * msa / 1e3)
            L.append(f"| {cell:g} м | {n3 / 1e6:.2f} млн | {CSHORT[cname]} | {fmt(r1)} | {lo:.0f} … {hi:.0f} | "
                     f"{fmt(r1 and r1 * lo / 1e3, 0)} … {fmt(r1 and r1 * hi / 1e3, 0)} | {fmt(s1)} | {msa:.0f} | "
                     f"{fmt(s1 and s1 * msa / 1e3, 0)} |")
    return "\n".join(L), rows


def compare_other():
    """Сравнение с опытами 2 и 4 — из их таблиц (как есть; эталоны у них свои, см. текст)."""
    L = ["### Сравнение с другими подходами (клетка 25/50/100/200 м, штиль; числа опытов 2 и 4 — из их out/tables.md)\n"]
    p2 = os.path.join(os.path.dirname(HERE), "exp2_picard", "out", "tables.md")
    p4 = os.path.join(os.path.dirname(HERE), "exp4_transfer_sweeps", "out", "tables.md")
    L.append(f"- опыт 2 (Пикар + линейные решения): {'есть' if os.path.exists(p2) else 'нет'} — `exp2_picard/out/tables.md`;")
    L.append(f"- опыт 4 (два прохода матриц перехода): {'есть' if os.path.exists(p4) else 'нет'} — `exp4_transfer_sweeps/out/tables.md`.")
    return "\n".join(L)


def main():
    main_r = load("main.json")
    timing = load("timing.json")
    fixed = load(os.path.join("fixed", "fixed.json"))
    auto = automaton_curves()
    json.dump(auto, open(os.path.join(OUT, "automaton_curves.json"), "w"))
    fig_rounds(main_r)
    fig_time(main_r, auto, timing)
    if os.path.exists(os.path.join(OUT, "sweep2.json")):
        fig_sweep(load("sweep.json"), load("sweep2.json"))
    fig_fields()
    t1, T = tables(main_r, auto, timing, fixed)
    t3, R3 = estimate_3d(main_r, timing, T)
    md = t1 + "\n\n" + t3 + "\n\n" + compare_other() + "\n"
    open(os.path.join(OUT, "tables.md"), "w").write(md)
    json.dump(dict(main=T, est3d=R3), open(os.path.join(OUT, "tables.json"), "w"), indent=1, default=float)
    print(md)


if __name__ == "__main__":
    main()
