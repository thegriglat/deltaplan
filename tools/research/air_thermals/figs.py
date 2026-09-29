#!/usr/bin/env python3
"""Картинки AM-07 из out/sources_*.json (probe.gd): карта источников поверх потока тепла H и
рельефа; рядом — Φ (поток, который несут пузыри) и W̄ (средний w_conv слоя).

  PY=/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python
  $PY figs.py            → out/fig_sources_<поле>.png
"""
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"


def fig(name):
    d = json.loads((OUT / f"sources_{name}.json").read_text())
    nx, ny, dx = d["nx"], d["ny"], d["dx"]
    ext = [d["x0"], d["x0"] + nx * dx, d["y0"], d["y0"] + ny * dx]  # x восток, y север
    hc = np.array(d["hc"]).reshape(ny, nx)
    H = np.array(d["heat"]).reshape(ny, nx)
    W = np.array(d["wbar"]).reshape(ny, nx)
    P = np.array(d["phi"]).reshape(ny, nx)
    S = d["sources"]
    sx = np.array([s["x"] for s in S])
    sy = np.array([-s["z"] for s in S])
    w0 = np.array([s["w0"] for s in S])
    fig, ax = plt.subplots(1, 3, figsize=(16, 5.4), constrained_layout=True)
    panels = [
        (H, "Поток тепла H, Вт/м²", "Oranges", None),
        (W, "W̄ — средний w_conv слоя, м/с", "RdBu_r", max(abs(np.nanmin(W)), abs(np.nanmax(W)))),
        (P, "Φ = F̄ + W̄⁺ — несут пузыри, м/с", "Blues", None),
    ]
    for a, (M, title, cmap, sym) in zip(ax, panels):
        kw = dict(vmin=-sym, vmax=sym) if sym else {}
        im = a.imshow(M, origin="lower", extent=ext, cmap=cmap, **kw)
        a.contour(hc, levels=12, colors="0.35", linewidths=0.5, extent=ext, origin="lower")
        a.set_title(title, fontsize=10)
        fig.colorbar(im, ax=a, shrink=0.8)
        a.set_xlabel("x (восток), м")
    ax[0].set_ylabel("y (север), м")
    sz = 6 + 10 * (w0 / max(w0.max(), 1e-6)) ** 2
    ax[0].scatter(sx, sy, s=sz * 3, c="k", edgecolors="w", linewidths=0.5)
    ax[2].scatter(sx, sy, s=sz * 3, c="k", edgecolors="w", linewidths=0.5)
    fig.suptitle(
        f"{name}: {len(S)} источников (точка ∝ сила w0: {w0.min():.1f}…{w0.max():.1f} м/с), "
        f"z_i {d['z_i']:.0f} м, кромка {d['z_lcl']:.0f} м; изолинии — рельеф",
        fontsize=11,
    )
    p = OUT / f"fig_sources_{name}.png"
    fig.savefig(p, dpi=90)
    plt.close(fig)
    print(p)


if __name__ == "__main__":
    for f in sorted(OUT.glob("sources_*.json")):
        fig(f.stem[len("sources_"):])
