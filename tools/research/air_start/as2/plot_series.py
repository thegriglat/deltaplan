#!/usr/bin/env python3
"""AS-2: ряды ветра на 1,5 м у старта до/после (неподвижная точка, 20 с).

plot_series.py <каталог> <метка_до> <метка_после> <вывод_каталог>
На каждый случай (старт, ветер, сид 0) — картинка: направление от среднего (°), модуль горизонтали и w.
"""
import csv
import math
import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

BEFORE = "#eb6834"
AFTER = "#2a78d6"
CASES = [
    ("ongudai-kayancha_south-21.6-0", "Каянча, 6 м/с"),
    ("ongudai-kayancha_south-10.8-0", "Каянча, 3 м/с"),
    ("altai-sinyukha_west-21.6-0", "Синюха, 6 м/с"),
    ("askarovo-biyagoda_west-10.8-0", "Биягода, 3 м/с"),
    ("aushkul-aushtau_east-21.6-0", "Аушкуль, 6 м/с"),
]


def load(p):
    r = list(csv.DictReader(open(p)))
    t = np.array([float(x["t"]) for x in r])
    u = np.array([float(x["wu"]) for x in r])
    v = np.array([float(x["wv"]) for x in r])
    w = np.array([float(x["ww"]) for x in r])
    e = np.array([u.mean(), v.mean()])
    e /= np.linalg.norm(e)
    th = np.degrees(np.arctan2(-u * e[1] + v * e[0], u * e[0] + v * e[1]))
    return t, th, np.hypot(u, v), w


def main():
    d, tb, ta, out = sys.argv[1:5]
    os.makedirs(out, exist_ok=True)
    for i, (name, title) in enumerate(CASES, 1):
        fig, ax = plt.subplots(3, 1, figsize=(8, 6.5), sharex=True)
        for tag, col, lab in [(tb, BEFORE, "до (1.0.0)"), (ta, AFTER, "после AS-2")]:
            p = os.path.join(d, f"{tag}_{name}_fixed.csv")
            if not os.path.exists(p):
                continue
            t, th, sp, w = load(p)
            ax[0].plot(t, th, color=col, lw=1.6, label=lab)
            ax[1].plot(t, sp, color=col, lw=1.6, label=lab)
            ax[2].plot(t, w, color=col, lw=1.6, label=lab)
        ax[0].set_ylabel("направление\nот среднего, °")
        ax[0].set_ylim(-180, 180)
        ax[0].set_yticks([-180, -90, 0, 90, 180])
        ax[1].set_ylabel("|U| гориз., м/с")
        ax[2].set_ylabel("w, м/с")
        ax[2].set_xlabel("время, с (крыло стоит, 1,5 м над стартом, сид 0)")
        ax[0].legend(loc="upper right", frameon=False, ncol=2)
        ax[0].set_title(f"{title}: ветер у крыла до/после")
        for a in ax:
            a.grid(color="#dddddd", lw=0.6)
            for s in ("top", "right"):
                a.spines[s].set_visible(False)
        fig.tight_layout()
        fig.savefig(os.path.join(out, f"{i:02d}_ряд_{name}.png"), dpi=110)
        plt.close(fig)


if __name__ == "__main__":
    main()
