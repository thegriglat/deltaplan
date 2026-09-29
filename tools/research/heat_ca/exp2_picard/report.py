#!/usr/bin/env python3
"""Картинки и таблицы опыта 2 по out/results.json и out/runs/*.npz.

  ../.venv/bin/python report.py      → out/fig_*.png, out/tables.md
"""
from __future__ import annotations

import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import plots  # noqa: E402
from plots import plt, TwoSlopeNorm, SERIES, MUTED, INK  # noqa: E402
from model import SCENARIOS, Params, HeatCA  # noqa: E402

OUT = os.path.join(HERE, "out")
NAMES = ["s1_sun_one_slope", "s2_both_slopes", "s3_wind", "s4_inversion"]
SHORT = {"s1_sun_one_slope": "1. солнце на крутой склон", "s2_both_slopes": "2. оба склона",
         "s3_wind": "3. ветер 3 м/с", "s4_inversion": "4. инверсия 1,5 км"}
CELLS = [200.0, 100.0, 50.0, 25.0]
CCOL = dict(zip(CELLS, SERIES))


def load():
    return json.load(open(os.path.join(OUT, "results.json")))


def fig_convergence(R):
    fig, axs = plt.subplots(2, 2, figsize=(13, 9), sharey=True)
    for ax, name in zip(axs.flat, NAMES):
        for cell in CELLS:
            r = R.get(f"{name}_{cell:g}")
            if r is None:
                continue
            c = CCOL[cell]
            ph = r["pic_hist"]
            t = np.array([h["gpu"] for h in ph])
            e = np.maximum([h["ew"] for h in ph], 1e-5)
            ax.loglog(t, e, color=c, lw=2, label=f"{cell:g} м — Пикар")
            ok = r["picard"]["outer_ok"]
            if ok is not None:
                j = [h["it"] for h in ph].index(ok)
                ax.plot(t[j], e[j], "o", color=c, ms=7, mec="k", zorder=5)
            th = r["ts_hist"]
            t2 = np.array([h["gpu"] for h in th])
            e2 = np.maximum([h["ew"] for h in th], 1e-5)
            ax.loglog(t2, e2, color=c, lw=1.5, ls="--", label=f"{cell:g} м — шаги по времени")
            mi = r["ts"]["mild_step"]
            if mi is not None:
                j = [h["step"] for h in th].index(mi)
                ax.plot(t2[j], e2[j], "X", color=c, ms=9, mec="k", zorder=5)
        ax.axhline(0.01, color=MUTED, lw=0.8, ls=":")
        ax.axhline(0.05, color=MUTED, lw=0.8, ls=":")
        ax.set_title(SHORT[name])
        ax.set_xlabel("время GPU, с (RTX 4070 SUPER)")
        ax.grid(True, which="major", color="#e6e6e6")
        ax.set_xlim(3e-3, 60)
        ax.set_ylim(1e-4, 2)
    for ax in axs[:, 0]:
        ax.set_ylabel("ошибка w: отн. L2 от точной\nнеподвижной точки автомата")
    h, l = axs[0, 0].get_legend_handles_labels()
    fig.legend(h, l, loc="lower center", ncol=4, frameon=False, bbox_to_anchor=(0.5, -0.03))
    fig.suptitle("Установление: итерации Пикара (сплошные) против шагов по времени (штрих)\n"
                 "● — Пикар остановился по своему критерию; ✕ — сработал бы критерий эталона "
                 "(0,02 м/с и 0,03 К за 10 мин)", y=1.0)
    fig.tight_layout(rect=(0, 0.05, 1, 0.97))
    fig.savefig(os.path.join(OUT, "fig_convergence.png"))
    plt.close(fig)


def fig_outer(R):
    fig, axs = plt.subplots(2, 2, figsize=(13, 8.5), sharey=True)
    for ax, name in zip(axs.flat, NAMES):
        for cell in CELLS:
            r = R.get(f"{name}_{cell:g}")
            if r is None:
                continue
            ph = r["pic_hist"]
            it = [h["it"] for h in ph]
            ax.semilogy(it, [h["ru"] for h in ph], color=CCOL[cell], lw=2, label=f"{cell:g} м: импульс, м/с²")
            ax.semilogy(it, [h["rt"] for h in ph], color=CCOL[cell], lw=1.2, ls="--",
                        label=f"{cell:g} м: тепло, К/с")
        ax.axhline(3.3e-6, color="#c00000", lw=0.8, ls=":")
        ax.text(2, 4e-6, "допуск (импульс)", color="#c00000", fontsize=8)
        ax.set_title(SHORT[name])
        ax.set_xlabel("внешняя итерация Пикара")
        ax.grid(True, color="#eeeeee")
    for ax in axs[:, 0]:
        ax.set_ylabel("невязка: насколько один шаг\nавтомата сдвигает решение (/dt)")
    h, l = axs[0, 0].get_legend_handles_labels()
    fig.legend(h, l, loc="lower center", ncol=4, frameon=False, bbox_to_anchor=(0.5, -0.04))
    fig.suptitle("Сходимость внешних итераций Пикара (невязка — шагом самого автомата)")
    fig.tight_layout(rect=(0, 0.06, 1, 0.97))
    fig.savefig(os.path.join(OUT, "fig_outer.png"))
    plt.close(fig)


def _panel(fig, ax, m, f, title, lim, cmap="RdBu_r", label=""):
    d = m.dx
    xe = np.arange(m.nx + 1) * d / 1000
    ze = np.arange(m.nz + 1) * d / 1000
    pm = ax.pcolormesh(xe, ze, f, cmap=cmap, norm=TwoSlopeNorm(0, -lim, lim), shading="flat")
    plots.draw_ground(ax, m)
    plots._inv_line(ax, m)
    ax.set_title(title, fontsize=10)
    cb = fig.colorbar(pm, ax=ax, shrink=0.85, pad=0.02)
    cb.set_label(label)


def fig_compare(R, name, cell=50.0):
    key = f"{name}_{cell:g}"
    if key not in R:
        return
    m = HeatCA(SCENARIOS[name], Params(cell=cell, device="cpu"))
    D = np.load(os.path.join(OUT, "runs", f"{key}.npz"))
    E = np.load(os.path.join(HERE, "..", "out", "refs", f"{key}.npz"))
    r = R[key]
    fig, axs = plt.subplots(3, 3, figsize=(17, 10.5))
    rows = [("wc", "w, м/с", "pic_wc", "ts8_wc"), ("uc", "u, м/с", "pic_uc", "ts8_uc"),
            ("th", "θ′, К", "pic_th", "ts8_th")]
    for (rk, lab, pk, tk), axr in zip(rows, axs):
        ref, pic, ts8 = E[rk], D[pk], D[tk]
        lim = np.nanpercentile(np.abs(ref), 99.5)
        _panel(fig, axr[0], m, ref, f"эталон: шаги по времени до мягкого критерия\n"
                                    f"({r['ref_saved']['steady_step']} шагов)", lim, label=lab)
        _panel(fig, axr[1], m, pic, f"итерации Пикара ({r['picard']['outer_ok']} внешних)", lim, label=lab)
        dif = pic - ref
        dl = max(np.nanpercentile(np.abs(dif), 99.5), 1e-6)
        _panel(fig, axr[2], m, dif, "разность: Пикар − эталон\n"
                                    f"(Пикар − 8 ч шагов: макс. {np.nanmax(np.abs(pic - ts8)):.3f})",
               dl, cmap="PuOr_r", label="разность, " + lab.split(", ")[1])
    fig.suptitle(f"{SCENARIOS[name].title}, клетка {cell:g} м: эталон и итерации Пикара рядом, карта разности",
                 y=0.995)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, f"fig_compare_{name}.png"))
    plt.close(fig)
    plots.fig_flow(m, D["pic_uc"], D["pic_wc"], D["pic_th"], os.path.join(OUT, f"fig_flow_picard_{name}.png"),
                   SCENARIOS[name].title + f" — итерации Пикара, клетка {cell:g} м")


def f2(v, nd=2):
    if v is None or (isinstance(v, float) and not np.isfinite(v)):
        return "—"
    return f"{v:.{nd}f}"


def tables(R):
    L = []
    L.append("### Время и точность: итерации Пикара против шагов по времени (GPU, только счёт)\n")
    L.append("Ошибка — относительная L2 по воздушным клеткам. «Точная» неподвижная точка X* — итерации Пикара "
             "до «пола» float32 (проверено: автомат, запущенный из X*, за 2 ч модели уходит на ≤ 10⁻³). "
             "Время Пикара — внешние итерации + проверки невязки шагом автомата раз в 10 итераций; "
             "время шагов — только шаги (CUDA Graph); компиляция/захват графа не в счёт ни там, ни там.\n")
    L.append("| Сценарий | Клетка | Сетка | Пикар: внешних итераций | внутр. на итерацию | мс/итер | Пикар, с | "
             "Шаги до мягкого критерия (эталон): шагов / с | Шаги до ошибки ≤ 1 %, с | Ускорение (к эталону / к 1 %) | "
             "Ошибка эталона от X*: w / u / θ′ | Пикар от эталона: w / u / θ′ | Пикар от 8 ч шагов: w / u / θ′ | Дрейф автомата из X* за 2 ч: w |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for name in NAMES:
        for cell in CELLS:
            r = R.get(f"{name}_{cell:g}")
            if r is None:
                continue
            p, t, e = r["picard"], r["ts"], r["err"]
            inn = p["inner"]
            innt = (f"тепло {inn['heat_sweeps']}×2 прогонки, импульс {inn['mom_sweeps']}×2, "
                    f"давление {inn['p_cycles']} V-цикл ({inn['mg_levels']} ур.)")
            sp1 = t["mild_gpu"] / p["t_total"] if t["mild_gpu"] else float("nan")
            sp2 = t["t_w1"] / p["t_total"]
            L.append(f"| {SHORT[name]} | {cell:g} м | {r['nx']}×{r['nz']} | {p['outer_ok']} | {innt} | "
                     f"{p['ms_iter']:.2f} | **{p['t_total']:.3f}** | {t['mild_step']} / {f2(t['mild_gpu'])} | "
                     f"{f2(t['t_w1'])} | ×{sp1:.0f} / ×{sp2:.0f} | "
                     + " / ".join(f"{x:.3f}" for x in e["ref_vs_exact"]) + " | "
                     + " / ".join(f"{x:.3f}" for x in e["sol_vs_ref"]) + " | "
                     + " / ".join(f"{x:.4f}" for x in e["sol_vs_8h"]) + f" | {e['drift2h'][0]:.1e} |")
    L.append("")
    L.append("### Ключевые числа (plots.metrics): Пикар / эталон / 8 ч шагов\n")
    L.append("| Сценарий | Клетка | Макс. подъём w, м/с (x, км; над землёй, м) | Приток у подножия слева, м/с | "
             "Вверх по склону слева, м/с | Ср. w в долине слева, м/с | Высота подъёма, м | Выше инверсии max|w|, м/с |")
    L.append("|---|---|---|---|---|---|---|---|")
    for name in NAMES:
        for cell in CELLS:
            r = R.get(f"{name}_{cell:g}")
            if r is None:
                continue
            ms = [r["metrics"][k] for k in ("picard", "ref", "ts8h")]
            wm = " / ".join(f"{q['w_max']:.2f} ({q['w_max_x']/1000:.2f}; {q['w_max_agl']:.0f})" for q in ms)
            g = lambda k, nd=2: " / ".join(f2(q.get(k), nd) for q in ms)
            L.append(f"| {SHORT[name]} | {cell:g} м | {wm} | {g('inflow_left')} | {g('upslope_left')} | "
                     f"{g('w_mean_valley_left', 3)} | {g('ascent_top_z', 0)} | "
                     f"{g('above_inv_wmax', 3) if name == 's4_inversion' else '—'} |")
    L.append("")
    return "\n".join(L)


def table_3d(R):
    """Оценка для 3D 40×40 км × 32 уровня (как в базе: время ∝ клеткам, пол накладных, ×1,5 за 3D)."""
    L = ["### Оценка для 3D (квадрат 40×40 км × 32 уровня, тот же GPU)\n"]
    T = json.load(open(os.path.join(OUT, "throughput.json")))
    ns_ts = T["3.125"]["ns_step"]                       # шаг автомата на 2 млн клеток — предел по памяти
    ratio = T["12.5"]["ms_iter"] / T["12.5"]["ms_step"]  # итерация Пикара / шаг, на самой большой сетке Пикара
    ns_pic = ratio * ns_ts
    ns_pic_hi = T["12.5"]["ns_iter"]                     # верхняя граница: замер на 12,5 м (ещё с накладными)
    floor_pic = min(R[k]["picard"]["ms_iter"] for k in R)
    floor_ts = min(R[k]["ts"]["ms_step"] for k in R)
    L.append(f"Шаг автомата: {ns_ts:.1f} нс на клетку·шаг (замер на 3,125 м, 2 млн клеток), пол {floor_ts:.2f} мс/шаг. "
             f"Итерация Пикара дороже шага в {ratio:.1f} раза (замер на 12,5 м — самой большой сетке, где прогонка "
             f"блоком на линию ещё помещается: линия ≤ 1024 точек) → ~{ns_pic:.1f} нс на клетку·итерацию "
             f"(верхняя граница — прямой замер на 12,5 м: {ns_pic_hi:.1f} нс), пол {floor_pic:.2f} мс/итерацию. "
             "×1,5 за 3D (третья компонента скорости, прогонки в трёх направлениях). Итераций/шагов — как в 2D при "
             "той же клетке (максимум по штилевым сценариям s1/s2/s4; с ветром — отдельно). Для Пикара это "
             "оптимистично: в 3D прогонки по линиям сглаживают хуже, итераций может стать в 1,5–2 раза больше; "
             "линии длиннее 1024 точек (40 км при 25 м) требуют прогонки в несколько проходов.\n")
    L.append("| Клетка | Ячеек 3D | Пикар: итераций (штиль / ветер) | мс/итер | Пикар, с (штиль / ветер) | "
             "Шаги до мягкого критерия: шагов | мс/шаг | Шаги, с | Шаги до 1 %, с |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    for cell in CELLS:
        n3 = (40000 / cell) ** 2 * 32
        calm = [R[f"{n}_{cell:g}"] for n in ("s1_sun_one_slope", "s2_both_slopes", "s4_inversion")
                if f"{n}_{cell:g}" in R]
        wind = R.get(f"s3_wind_{cell:g}")
        it_c = max(r["picard"]["outer_ok"] for r in calm)
        it_w = wind["picard"]["outer_ok"] if wind else float("nan")
        ms_it = max(floor_pic, ns_pic * 1e-6 * n3 * 1.5)
        st = max(r["ts"]["mild_step"] for r in calm)
        st1 = max(r["ts"]["t_w1"] / r["ts"]["ms_step"] * 1e3 for r in calm)
        ms_st = max(floor_ts, ns_ts * 1e-6 * n3 * 1.5)
        ms_hi = max(floor_pic, ns_pic_hi * 1e-6 * n3 * 1.5)
        L.append(f"| {cell:g} м | {n3/1e6:.2f} млн | {it_c} / {it_w} | {ms_it:.0f} (≤ {ms_hi:.0f}) | "
                 f"{it_c*ms_it/1e3:.1f} / {it_w*ms_it/1e3:.1f} (≤ {it_c*ms_hi/1e3:.0f} / {it_w*ms_hi/1e3:.0f}) | "
                 f"{st} | {ms_st:.1f} | {st*ms_st/1e3:.0f} | {st1*ms_st/1e3:.0f} |")
    L.append("")
    L.append("Память Пикара: u, w, θ′, p, φ, три 9-точечных шаблона (27 чисел), правые части, уровни многосеточного "
             "и временные массивы — ~45 чисел float32 на клетку ≈ 180 байт (в 3D ~ 60 чисел ≈ 240 байт): "
             "40×40 км × 32 при 100 м — ~1,2 ГБ, при 200 м — ~0,3 ГБ. Шаблоны можно не хранить, а считать "
             "на лету в ядрах прогонки (тогда ~15 чисел ≈ 60 байт на клетку, как у автомата).\n")
    return "\n".join(L)


def main():
    R = load()
    fig_convergence(R)
    fig_outer(R)
    for name in NAMES:
        fig_compare(R, name)
    with open(os.path.join(OUT, "tables.md"), "w") as fh:
        fh.write(tables(R) + "\n" + table_3d(R))
    print(open(os.path.join(OUT, "tables.md")).read())


if __name__ == "__main__":
    main()
