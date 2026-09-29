"""Ход среднего поля в точке через пересчёт поля в полёте (AM-06Б).

Вход — CSV из GPU-теста AirRuntime:
  AIR_RUNTIME_TRACE=$PWD/tools/research/air_runtime/out/blend_trace.csv \
    flock /tmp/heat_ca_gpu.lock tools/gpu_tests.sh --filter=test_air_runtime
  python tools/research/air_runtime/plot_blend.py
Выход — out/blend_trace.png: w_mech и w_conv поля в точке и доля нового поля по времени атмосферы.
"""
import csv
import pathlib

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

OUT = pathlib.Path(__file__).parent / "out"
rows = list(csv.DictReader(open(OUT / "blend_trace.csv", encoding="utf-8")))
t = [float(r["t_s"]) for r in rows]
ev = [(float(r["t_s"]), r["event"]) for r in rows if r["event"]]

BLUE, ORANGE, INK, MUTED = "#2a78d6", "#eb6834", "#52514e", "#b8b7b0"
fig, axes = plt.subplots(3, 1, figsize=(9, 7), sharex=True, facecolor="#fcfcfb")
series = [
    ("w_mech", "w_mech поля, м/с (обтекание рельефа)", BLUE),
    ("w_conv", "w_conv поля, м/с (от нагрева; пилоту — через термики)", ORANGE),
    ("frac", "доля нового поля в подмене", INK),
]
for ax, (key, title, color) in zip(axes, series):
    ax.set_facecolor("#fcfcfb")
    ax.plot(t, [float(r[key]) for r in rows], color=color, lw=2)
    ax.set_title(title, loc="left", fontsize=10, color=INK)
    ax.grid(color="#e6e5e0", lw=0.6)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for te, _ in ev:
        ax.axvline(te, color=MUTED, lw=1, ls="--")
for te, txt in ev:
    axes[0].annotate(txt, (te, 1.0), xycoords=("data", "axes fraction"), rotation=90,
                     fontsize=7, color=INK, va="top", ha="right")
axes[-1].set_xlabel("время атмосферы, с")
fig.suptitle("Онгудай, точка у старта (100 м над землёй): пересчёт по сроку 12:15, "
             "затем смена ветра 3 → 4 м/с посреди подмены", fontsize=10, color=INK)
fig.tight_layout()
fig.savefig(OUT / "blend_trace.png", dpi=110)
print(OUT / "blend_trace.png")
