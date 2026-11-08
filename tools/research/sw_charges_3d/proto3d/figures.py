"""Рисунки для статьи: out/proto3d/fig_a.png, fig_c.png."""
import json, os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT = os.path.join(os.path.dirname(__file__), "..", "out", "proto3d")
J = lambda n: json.load(open(os.path.join(OUT, n)))
blob, flux, neu, th, cl = J("a_blob.json"), J("a_flux.json"), J("c_neutral.json"), J("c_thresh.json"), J("c_closure.json")
fig, ax = plt.subplots(1, 2, figsize=(10, 4))
for r in blob:
    ax[0].plot(r["t"], r["dn"], label=f"{r['case']} U={r['U']}")
ax[0].set_xlabel("t, с"); ax[0].set_ylabel("d_n центра плавучести, м"); ax[0].legend(fontsize=6); ax[0].set_title("A: шар R = 100 м")
for r in flux:
    if r["T"] > 200:
        ax[1].plot(r["t"], r["dn"], label=f"{r['case']} noise={r['noise']}")
ax[1].set_xlabel("t, с"); ax[1].set_ylabel("d_n, м"); ax[1].legend(fontsize=6); ax[1].set_title("A: нагрев потоком 250 Вт/м²")
fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig_a.png"), dpi=130)
fig, ax = plt.subplots(1, 3, figsize=(13, 4))
ax[0].plot([r["z"] for r in neu], [r["ratio_sw"] for r in neu], "o-"); ax[0].axhline(1, c="k", lw=0.5)
ax[0].set_xlabel("z, м"); ax[0].set_ylabel("σ_w / 1,25u*"); ax[0].set_title("C: нейтральный слой")
for zc in (30.0, 60.0):
    for fk, ls in (("step", "-"), ("none", "--")):
        q = [r for r in th if r["z_c"] == zc and r["fkind"] == fk]
        ax[1].semilogx([r["Ri_z"] for r in q], [r["ratio_sw"] for r in q], ls, marker="o", label=f"z_c={zc:g}, {fk}")
ax[1].axvline(0.25, c="k", lw=0.5); ax[1].set_xlabel("Ri(z)"); ax[1].set_ylabel("σ_w / 1,25u*"); ax[1].legend(fontsize=6); ax[1].set_title("порог по Ri")
ax[2].plot([r["Ri"] for r in cl], [r["cK"] for r in cl], "o-", label="c_K"); ax[2].plot([r["Ri"] for r in cl], [r["c_sigma"] for r in cl], "s-", label="c_σ")
ax[2].set_xlabel("Ri"); ax[2].legend(); ax[2].set_title("замыкание из ансамбля")
fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig_c.png"), dpi=130)
