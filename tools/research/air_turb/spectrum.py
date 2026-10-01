#!/usr/bin/env python3
"""AM-08: спектр порывов на записи прямого полёта (turb_probe.gd --only=spectrum → out/flight_*.csv).

Welch, окно Ханна 4096 отсчётов (82 с при 50 Гц), половинное перекрытие. Наклон log S — log f МНК
в инерционном интервале; погрешность — 2σ наклона по разбросу оценок на 8 частях ряда
(независимые отрезки по 50 с). Картинка — out/spectrum.png, числа — out/spectrum.json.

  python3 tools/research/air_turb/spectrum.py [--fmin 0.15 --fmax 1.5]
"""
import argparse
import json
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT = Path(__file__).resolve().parent / "out"


def welch(x, fs, nper):
    x = x - x.mean()
    w = np.hanning(nper)
    step = nper // 2
    segs = [x[i:i + nper] for i in range(0, len(x) - nper + 1, step)]
    P = np.mean([np.abs(np.fft.rfft(s * w)) ** 2 for s in segs], axis=0) / (fs * (w ** 2).sum())
    return np.fft.rfftfreq(nper, 1 / fs), 2 * P


def slope(f, P, fmin, fmax):
    m = (f >= fmin) & (f <= fmax)
    return np.polyfit(np.log(f[m]), np.log(P[m]), 1)[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fmin", type=float, default=0.15)
    ap.add_argument("--fmax", type=float, default=1.5)
    a = ap.parse_args()
    res = {}
    fig, axs = plt.subplots(1, 2, figsize=(11, 4.5), sharey=True)
    colors = {"field_150": "#1f6fb4", "field_400": "#2a9d8f", "analytic_150": "#c0504d", "analytic_400": "#e39b3b"}
    for key, col in colors.items():
        p = OUT / f"flight_{key}.csv"
        if not p.exists():
            continue
        d = np.loadtxt(p, delimiter=",", skiprows=1)
        t, u, w = d[:, 0], d[:, 1], d[:, 3]
        fs = 1 / (t[1] - t[0])
        r = {}
        for ax, name, x in ((axs[0], "u", u), (axs[1], "w", w)):
            f, P = welch(x, fs, 4096)
            s = slope(f, P, a.fmin, a.fmax)
            parts = np.array_split(x, 8)
            ss = []
            for q in parts:
                fq, Pq = welch(q, fs, 1024)
                ss.append(slope(fq, Pq, a.fmin, a.fmax))
            err = 2 * np.std(ss) / np.sqrt(len(ss))
            r[name] = dict(slope=round(float(s), 3), err2sigma=round(float(err), 3), sigma=round(float(x.std()), 3))
            ax.loglog(f[1:], P[1:], color=col, lw=1.1,
                      label=f"{'поле' if key.startswith('field') else 'аналитика'}, {key.split('_')[1]} м над стартом: {s:.2f} ± {err:.2f}")
        res[key] = r
    for ax, name in zip(axs, ("u (вдоль ветра)", "w")):
        f0 = np.array([a.fmin, a.fmax])
        ax.loglog(f0, 0.3 * (f0 / a.fmin) ** (-5 / 3), "k--", lw=1, label="−5/3")
        ax.axvspan(a.fmin, a.fmax, color="0.9", zorder=0)
        ax.set_xlabel("частота, Гц")
        ax.set_title(f"спектр {name}, наклон в {a.fmin:g}–{a.fmax:g} Гц")
        ax.grid(True, which="both", alpha=0.3)
        ax.legend(fontsize=7.5, loc="lower left")
    axs[0].set_ylabel("S(f), (м/с)²/Гц")
    fig.suptitle("AM-08: порывы на прямом полёте 12 м/с поперёк ветра, Аушкуль (aushtau_east), 20 км/ч")
    fig.tight_layout()
    fig.savefig(OUT / "spectrum.png", dpi=110)
    (OUT / "spectrum.json").write_text(json.dumps(dict(fmin=a.fmin, fmax=a.fmax, runs=res), ensure_ascii=False, indent=1))
    print(json.dumps(res, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
