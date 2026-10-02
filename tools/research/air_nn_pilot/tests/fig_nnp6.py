#!/usr/bin/env python3
"""Рисунки NN-P6 из tests/out/maxcap.json и workers_bench.json → figures/nnp6_maxcap.png, figures/nnp6_workers.png.

  .venv/bin/python tests/fig_nnp6.py
"""
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

HERE = Path(__file__).resolve().parents[1]
m = json.loads((HERE / "tests/out/maxcap.json").read_text())
caps = m["caps"]
fig, ax = plt.subplots(1, 2, figsize=(10, 4))
for grp, c, lab in (("max", "#c0392b", "несошедшиеся (max)"), ("oklong", "#2471a3", "сошедшиеся, iters > 500")):
    ax[0].plot(caps, [m["by_cap"][str(k)][grp]["dV"]["p90"] for k in caps], "o-", color=c, label=lab)
    ax[0].plot(caps, [m["by_cap"][str(k)][grp]["dV"]["median"] for k in caps], "o--", color=c, alpha=0.6)
ax[0].axhline(m["noise_max"]["dV"]["p90"], color="#c0392b", ls=":", label="«шум» max: 1500 против 2000, p90")
ax[0].axhline(0.1, color="k", ls=":", lw=0.8, label="ориентир 0,1 м/с")
ax[0].axvline(m["chosen_cap"], color="gray", lw=0.8)
ax[0].set_xlabel("предел итераций"); ax[0].set_ylabel("|ΔV| на 60 м к решению 3000, м/с (p90 —, медиана --)")
ax[0].legend(fontsize=7); ax[0].set_title("предел против полного решения (main)")
t = m["time_model_main"]["by_cap"]
ax[1].plot(caps, [t[str(k)]["solver_h"] for k in caps], "o-", color="#117a65")
ax[1].axhline(m["time_model_main"]["solver_h_full"], color="#117a65", ls=":", label="без предела (3000)")
ax[1].set_xlabel("предел итераций"); ax[1].set_ylabel("время решателя области main, ч"); ax[1].legend(fontsize=7)
fig.tight_layout(); fig.savefig(HERE / "figures/nnp6_maxcap.png", dpi=120)

w = json.loads((HERE / "tests/out/workers_bench.json").read_text())
fig, ax = plt.subplots(figsize=(5, 3.5))
ns = [r["n"] for r in w["curve"]]
ax.plot(ns, [r["rate_per_h"] for r in w["curve"]], "o-", color="#2471a3")
ax2 = ax.twinx(); ax2.plot(ns, [r["gpu_util_mean"] for r in w["curve"]], "s--", color="#c0392b"); ax2.set_ylabel("загрузка GPU, %")
ax.set_xlabel("воркеров N"); ax.set_ylabel("случаев в час"); ax.set_xticks(ns); ax.set_title("bench12: 4 max + 8 ok, предел %d" % w["max_outer"])
fig.tight_layout(); fig.savefig(HERE / "figures/nnp6_workers.png", dpi=120)
print("figures/nnp6_maxcap.png, figures/nnp6_workers.png")
