"""Стык уровней клипмапа (AM-04): профиль поля вдоль линии на восток от старта Каянча через края
окон 50 м и 100 м — выборка игры (AirFieldSet: смешение уровней с весом края) и каждый уровень
отдельно, на 50 и 300 м над землёй. Вход — CSV GPU-теста:

    AIR_CLIPMAP_DUMP=1 tools/gpu_tests.sh --filter=test_air_window_gpu
    ../heat_ca/.venv/bin/python seam_plot.py   # (из tools/research/air_clipmap) → out/seam_kayancha_h12_U3.png
"""
import csv
import math
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT = Path(__file__).resolve().parent / "out"
SRC = OUT / "seam_kayancha_h12_U3.csv"
EDGES = [(1600.0, "край окна 50 м"), (3200.0, "край окна 100 м")]
BANDS = [(1600.0 - 250.0, 1600.0), (3200.0 - 500.0, 3200.0)]
# уровень рисуется только внутри своего окна (вне — выборка отдаёт значение края)
LEVELS = [("s50", "w50", "окно 50 м", "#2a78d6", 1600.0), ("s100", "w100", "окно 100 м", "#eb6834", 3200.0),
          ("s400", "w400", "область 400 м", "#1baf7a", 1e9)]


def main():
    rows = list(csv.DictReader(SRC.open()))
    fig, axs = plt.subplots(2, 2, figsize=(12, 7), sharex=True, constrained_layout=True)
    for col, agl in enumerate(("50", "300")):
        r = [q for q in rows if q["agl"] == agl]
        x = [float(q["x_m"]) for q in r]
        sp = [math.hypot(float(q["u"]), float(q["v"])) for q in r]
        w = [float(q["w"]) for q in r]
        for row, (key, comb, name) in enumerate((("s", sp, "|u_h|, м/с"), ("w", w, "w_mech, м/с"))):
            ax = axs[row][col]
            for a, b in BANDS:
                ax.axvspan(a, b, color="#d9d8d3", alpha=0.5, lw=0)
            for xe, _ in EDGES:
                ax.axvline(xe, color="#8a8983", lw=1, ls="--")
            for ks, kw, lab, c, xmax in LEVELS:
                pts = [(xx, float(q[ks if key == "s" else kw])) for xx, q in zip(x, r) if xx <= xmax]
                ax.plot([p[0] for p in pts], [p[1] for p in pts], color=c, lw=1.2, alpha=0.8, label=lab)
            ax.plot(x, comb, color="#0b0b0b", lw=2, label="выборка игры (смешение)")
            ax.set_ylabel(name)
            ax.grid(color="#ecebe6", lw=0.6)
            for s in ("top", "right"):
                ax.spines[s].set_visible(False)
            if row == 0:
                ax.set_title(f"{agl} м над землёй")
            if row == 1:
                ax.set_xlabel("м к востоку от старта Каянча")
    axs[0][0].legend(loc="lower left", fontsize=8, frameon=False)
    fig.suptitle("Онгудай, 12:00, 3 м/с с 150°: стык уровней клипмапа (серое — полоса края 5 клеток)")
    out = OUT / "seam_kayancha_h12_U3.png"
    fig.savefig(out, dpi=110)
    print("→", out)


if __name__ == "__main__":
    main()
