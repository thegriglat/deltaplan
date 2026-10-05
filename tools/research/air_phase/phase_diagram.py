#!/usr/bin/env python3
"""air-phase: схематические фазовые диаграммы классов решений (по порогам из литературы, см. docs/research/air_phase.md §3).

  PY=/home/greg/deltaplan-air-synth-SY-11/tools/research/air_nn_pilot/.venv/bin/python
  $PY tools/research/air_phase/phase_diagram.py            # → out/fig_phase_schematic.png

Пороги (все — ориентиры с неопределённостью, не измерения): Fr = U/(N·h); блокирование/подветренные вихри Fr < ~0,5
(Hunt & Snyder 1980: обход при Fr < 0,4; Smolarkiewicz & Rotunno 1989; Lin & Wang 1996: блокирование первым при 0,3 ≤ F ≤ 0,6);
критическая зона 0,5…1,2 (опрокидывание волн Nh/U ≈ 0,85, Miles & Huppert 1969; Lin & Wang: без опрокидывания при F ≥ 1,12);
срыв при уклоне > ~0,3 (Wood 1995; Finnigan 1988: 15° для 2D, 20° для 3D); конвекция: −z_i/L > ~5 — свободная шкала
(Deardorff 1972, «4,5» — по памяти), валы → ячейки плавно около −z_i/L ≈ 15–25 (Salesky et al. 2017; Weckwerth et al. 1997);
охлаждение H < 0; штиль U10 < ~1,5 м/с (Anfossi et al. 2005 — меандрирование)."""
from __future__ import annotations

import os
from pathlib import Path

import matplotlib
import numpy as np

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

HERE = Path(__file__).resolve().parent
KAPPA, G, TH0, RHO_CP, Z0 = 0.4, 9.81, 300.0, 1206.0, 0.1


def H_of_U(U10, ziL, zi):
    """H (Вт/м²), при котором −z_i/L = ziL: u* = κU10/ln(10/z0); −z_i/L = κ g/θ0 · H/(ρc_p) · z_i / u*³."""
    us = KAPPA * U10 / np.log(10 / Z0)
    return ziL * us ** 3 * RHO_CP * TH0 / (KAPPA * G * zi)


def main():
    out = HERE / "out"
    out.mkdir(exist_ok=True)
    plt.rcParams.update({"font.size": 9})
    fig, ax = plt.subplots(2, 2, figsize=(12, 9.5))

    # (а) размерные оси (U10, H): границы по нагреву — H ∝ U³, по Fr — вертикали (N = 0,01 1/с, h = 500 м, U_sat ≈ 2·U10)
    a = ax[0, 0]
    U = np.linspace(0.3, 12, 300)
    zi = 1500.0
    for ziL, lab, ls in ((5, "−z_i/L = 5 (E: конвекция с ветром)", "--"), (25, "−z_i/L = 25 (F: свободная конвекция)", "-")):
        a.plot(U, H_of_U(U, ziL, zi), "k", ls=ls, lw=1, label=lab)
    N, h, k_sat = 0.01, 500.0, 2.0
    for fr, lab in ((0.5, "Fr = 0,5"), (1.2, "Fr ≈ 1,2")):
        u = fr * N * h / k_sat
        a.axvline(u, color="tab:blue", ls=":", lw=1)
        a.text(u, 350, lab, rotation=90, va="top", ha="right", fontsize=7, color="tab:blue")
    a.axvspan(0, 1.5, color="grey", alpha=0.2, label="H: около штиля (U10 < 1,5 м/с)")
    a.fill_between(U, -80, 0, color="tab:purple", alpha=0.15, label="G: охлаждение (H < 0)")
    a.text(8.5, 20, "A / B (срыв при s > 0,3)\nстационарно, единственно", fontsize=8, ha="center")
    a.text(1.9, 15, "D\nблокирование", fontsize=8, ha="center")
    a.text(4.0, 15, "C\nFr~1", fontsize=8, ha="center")
    a.text(6, 250, "F: ячейки — только статистика", fontsize=8, ha="center")
    a.text(10, 130, "E: валы — среднее + статистика", fontsize=8, ha="center")
    a.set_xlim(0, 12); a.set_ylim(-80, 400); a.set_xlabel("U10, м/с"); a.set_ylabel("H, Вт/м²")
    a.set_title("(а) Размерные оси: N = 0,01 1/с, h = 500 м, z_i = 1,5 км; границы нагрева H ∝ U³")
    a.legend(fontsize=6.5, loc="upper left")

    # (б) безразмерное сечение Fr × (−z_i/L) при s < 0,3, h/z_i < 1
    b = ax[0, 1]
    b.set_xscale("log"); b.set_yscale("log")
    b.set_xlim(0.05, 20); b.set_ylim(0.3, 1000)
    for x, lab in ((0.5, "0,5"), (1.2, "1,2")):
        b.axvline(x, color="tab:blue", ls=":", lw=1)
    for y in (5, 25):
        b.axhline(y, color="k", ls="--", lw=1)
    # наклон границы A↔D: при нагреве N внутри слоя → 0, эффективный Fr растёт (гипотеза: показана штриховкой)
    xx = np.logspace(np.log10(0.5), np.log10(2.0), 50)
    b.fill_betweenx(np.logspace(np.log10(5), 3, 50), 0.5, xx, color="tab:blue", alpha=0.12)
    b.text(0.07, 0.4, "D: блокирование, обход,\nподветренные вихри\n(срыв вихрей при Fr < ~0,3?)", fontsize=7)
    b.text(0.56, 2.2, "C: волны,\nпрыжок,\nмультистаб.", fontsize=7)
    b.text(4, 1, "A: вынужденное обтекание\n(линейная теория, сеть)", fontsize=7)
    b.text(4, 9, "E: + валы (статистика положений)", fontsize=7)
    b.text(4, 120, "F: ячейки; детерминирована\nтолько привязанная к рельефу часть", fontsize=7)
    b.text(0.55, 60, "граница A↔D\nнаклонна при\nнагреве (гипотеза)", fontsize=6.5, color="tab:blue")
    b.set_xlabel("Fr = U/(N·h)"); b.set_ylabel("−z_i/L")
    b.set_title("(б) Fr × (−z_i/L), пологие склоны, h < z_i")

    # (в) Fr × крутизна s (нагрев слабый)
    c = ax[1, 0]
    c.set_xscale("log"); c.set_xlim(0.05, 20); c.set_ylim(0, 0.8)
    for x in (0.5, 1.2):
        c.axvline(x, color="tab:blue", ls=":", lw=1)
    xs = np.logspace(np.log10(0.05), np.log10(20), 200)
    # порог срыва: 0,3 вдали от Fr~1; около Fr~1 подветренная волна снижает порог (гипотеза; форма — иллюстрация)
    s_crit = 0.3 - 0.15 * np.exp(-((np.log10(xs) - np.log10(0.9)) / 0.25) ** 2)
    c.plot(xs, s_crit, "tab:red", lw=1.2, label="порог срыва s_crit (0,3 вдали от Fr~1; провал у Fr~1 — гипотеза)")
    c.fill_between(xs, s_crit, 0.8, where=xs > 1.2, color="tab:red", alpha=0.12)
    c.text(4, 0.5, "B: срыв и ротор\n(среднее определено,\nколебания за гребнем)", fontsize=7)
    c.text(4, 0.1, "A", fontsize=9)
    c.text(0.1, 0.1, "D (обход; у устойчивого\nнижнего слоя срыва нет)", fontsize=7)
    c.text(0.1, 0.5, "D + срыв вихрей\nс боков", fontsize=7)
    c.text(0.6, 0.6, "C + ротор\nпод волной", fontsize=7)
    c.set_xlabel("Fr"); c.set_ylabel("крутизна подветренного склона s = tg α")
    c.set_title("(в) Fr × s, слабый нагрев, h < z_i"); c.legend(fontsize=6.5, loc="upper left")

    # (г) двухслойная ось: Fr_i = U/√(g′ z_i) × h/z_i (по Vosper 2004 — качественно)
    d = ax[1, 1]
    d.set_xlim(0, 1.4); d.set_ylim(0, 1.3)
    d.axvline(1.0, color="k", ls="--", lw=1)
    d.axhline(1.0, color="k", ls="--", lw=1)
    d.text(1.05, 0.4, "Fr_i > 1:\nволн на инверсии нет,\nработает Fr\nсвободной атмосферы", fontsize=7)
    d.text(0.1, 0.15, "Fr_i < 1, h ≪ z_i:\nподветренные волны\nна инверсии", fontsize=7)
    d.text(0.1, 0.6, "h/z_i → 1: роторы под волной,\nгидравлический прыжок\n(Vosper 2004, границы — по рисунку,\nне перенесены)", fontsize=7)
    d.text(0.1, 1.1, "h > z_i: рельеф пробивает инверсию — нижний слой блокирован,\nверх обтекает «эффективный рельеф» (пороги не известны)", fontsize=7)
    d.set_xlabel("Fr_i = U/√(g′ z_i), g′ = g Δθ/θ"); d.set_ylabel("h/z_i")
    d.set_title("(г) Инверсия: Fr_i × h/z_i (качественно)")
    fig.tight_layout()
    fig.savefig(out / "fig_phase_schematic.png", dpi=130)
    print(out / "fig_phase_schematic.png")


if __name__ == "__main__":
    main()
