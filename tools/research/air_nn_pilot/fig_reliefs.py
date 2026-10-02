#!/usr/bin/env python3
"""Обзор процедурных рельефов p_000…: карта высот над базой (±14 км от центра, общая шкала), тень рельефа, старт (▲)
и окно 100 м (6,4 км, квадрат).

  .venv/bin/python fig_reliefs.py [--out figures/01_рельефы.png] [--copy /home/greg/deltaplan/build/screenshots/air-nn-p1/]
"""
from __future__ import annotations

import argparse
import shutil
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from matplotlib.colors import LightSource  # noqa: E402

import dataset as DS  # noqa: E402
import procedural as PR  # noqa: E402

HERE = Path(__file__).resolve().parent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(HERE / "figures/01_рельефы.png"))
    ap.add_argument("--copy", default="/home/greg/deltaplan/build/screenshots/air-nn-p1/")
    a = ap.parse_args()
    cfg = DS.load_cfg(HERE / "configs/dataset.yaml")
    pc = cfg["plan"]
    PR.configure(pc["proc_seed"])
    X, Y = PR.grid()
    lim = 14000.0
    s = slice(int((20000 - lim) / PR.SP), int((20000 + lim) / PR.SP) + 1, 2)
    Xs, Ys = X[s, s], Y[s, s]
    n = pc["n_proc"]
    nc = 8
    nr = (n + nc - 1) // nc
    fig, axs = plt.subplots(nr, nc, figsize=(2.2 * nc, 2.35 * nr + 0.6), constrained_layout=True)
    ls = LightSource(azdeg=315, altdeg=40)
    vmax = 1100.0
    cmap = plt.get_cmap("YlOrBr")
    for k, ax in enumerate(axs.flat):
        ax.set_xticks([]); ax.set_yticks([])
        if k >= n:
            ax.axis("off")
            continue
        p = PR.params(k)
        h = PR.height(p, Xs, Ys)
        rel = np.clip((h - p["base"]) / vmax, 0, 1)
        rgb = ls.shade_rgb(cmap(rel)[..., :3], h, vert_exag=2.0, dx=2 * PR.SP, dy=2 * PR.SP, blend_mode="soft")
        ax.imshow(rgb, origin="lower", extent=(-lim / 1e3, lim / 1e3, -lim / 1e3, lim / 1e3))
        sx, sy = p["start"]
        ax.plot([sx / 1e3], [sy / 1e3], marker="^", ms=6, mfc="black", mec="white", mew=0.8)
        w = 3.2
        ax.plot(np.array([-w, w, w, -w, -w]) + sx / 1e3, np.array([-w, -w, w, w, -w]) + sy / 1e3, color="black", lw=0.8)
        kinds = "+".join([p["forms"][0]["kind"]] + [f["kind"] for f in p["forms"][1:]])
        ax.set_title(f"{p['id']} · {kinds}\nбаза {p['base']:.0f} м, H {p['forms'][0]['H']:.0f} м", fontsize=7.5, color="#333")
    sm = plt.cm.ScalarMappable(cmap=cmap, norm=plt.Normalize(0, vmax))
    cb = fig.colorbar(sm, ax=axs, orientation="horizontal", fraction=0.02, aspect=60, pad=0.01)
    cb.set_label("высота над базой рельефа, м (поле ±14 км, ▲ — старт, квадрат — окно 100 м 6,4 км)", fontsize=9)
    fig.suptitle(f"Процедурные рельефы пилота: {n} шт., зерно {pc['proc_seed']}", fontsize=11)
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, dpi=110)
    if a.copy:
        Path(a.copy).mkdir(parents=True, exist_ok=True)
        shutil.copy(out, Path(a.copy) / out.name)
    print(out)


if __name__ == "__main__":
    main()
