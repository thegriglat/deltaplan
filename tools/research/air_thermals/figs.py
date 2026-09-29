#!/usr/bin/env python3
"""Картинки AM-07 из out/sources_*.json (probe.gd): карта источников поверх потока тепла H и
рельефа; рядом — Φ (поток, который несут пузыри) и W̄ (средний w_conv слоя).

  PY=/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python
  $PY figs.py            → out/fig_sources_<поле>.png
  $PY figs.py --compare OLD.json NEW.json OUT.png   → было/стало: источники на Φ (AM-07 → AM-07б);
      OLD — out/sources_kayancha_w100_h12.json из git до AM-07б (git show <коммит>:путь > OLD.json)
"""
import sys
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


def compare(old, new, out):
    """Было/стало: те же Φ и рельеф, точки источников ∝ силе (общая шкала), подпись — числа."""
    ds = [json.loads(Path(p).read_text()) for p in (old, new)]
    wmax = max(max(s["w0"] for s in d["sources"]) for d in ds)
    fig, ax = plt.subplots(1, 2, figsize=(12, 5.6), constrained_layout=True)
    for a, d, lab in zip(ax, ds, ("было (AM-07): ядра несут весь Φ", "стало (AM-07б): Аллен")):
        nx, ny, dx = d["nx"], d["ny"], d["dx"]
        ext = [d["x0"], d["x0"] + nx * dx, d["y0"], d["y0"] + ny * dx]
        hc = np.array(d["hc"]).reshape(ny, nx)
        P = np.array(d["phi"]).reshape(ny, nx)
        S = d["sources"]
        w0 = np.array([s["w0"] for s in S])
        im = a.imshow(P, origin="lower", extent=ext, cmap="Blues", vmin=0)
        a.contour(hc, levels=12, colors="0.35", linewidths=0.5, extent=ext, origin="lower")
        a.scatter([s["x"] for s in S], [-s["z"] for s in S], s=4 + 60 * (w0 / wmax) ** 2,
                  c="k", edgecolors="w", linewidths=0.5)
        area = np.count_nonzero(np.array(d["owner"]) >= 0) * dx * dx * 1e-6  # столбцы водосборов
        a.set_title(f"{lab}\n{len(S)} источников ({len(S) / area:.1f}/км²), "
                    f"w0 {w0.mean():.1f} м/с ({w0.min():.1f}…{w0.max():.1f}), "
                    f"ядра несут {100 * d['carried_flux'] / d['total_flux']:.0f} % Φ", fontsize=10)
        a.set_xlabel("x (восток), м")
        fig.colorbar(im, ax=a, shrink=0.8, label="Φ, м/с")
    ax[0].set_ylabel("y (север), м")
    fig.suptitle(f"{ds[1]['name']}: источники термиков поверх Φ = F̄ + W̄⁺ (точка ∝ сила); "
                 "изолинии — рельеф", fontsize=11)
    fig.savefig(out, dpi=90)
    plt.close(fig)
    print(out)


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "--compare":
        compare(*sys.argv[2:])
        sys.exit(0)
    for f in sorted(OUT.glob("sources_*.json")):
        fig(f.stem[len("sources_"):])
