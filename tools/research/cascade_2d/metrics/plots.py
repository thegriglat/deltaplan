#!/usr/bin/env python3
"""Картинки «поле против эталона» (cascade-2d, M1).

  py metrics/plots.py --case C1 --field <F1> [--vs B400] [--ref <F1 P25>] [--out <каталог>]

Пишет png (≤ 300 КБ) в tools/research/cascade_2d/out/fig/<C>/:
  <имя>_fields.png   — |u| (с стрелками у эталона), поле, разность; w ref/поле/разность (общая шкала);
  <имя>_profiles.png — профили u(z_agl), w(z_agl) на x = x_c−L, x_c, x_c+2L для эталона, B_k и поля.
"""
import argparse
import os
import sys

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import metrics as M  # noqa: E402

io = M.io
MAX_BYTES = 300 * 1024
FIG_DIR = os.path.join(HERE, "..", "out", "fig")


def save_small(fig, path):
    """png ≤ 300 КБ: понижает dpi, пока не влезет."""
    for dpi in (90, 70, 55, 40, 30):
        fig.savefig(path, dpi=dpi)
        if os.path.getsize(path) <= MAX_BYTES:
            return dpi
    return dpi


def _grid(meta, arr):
    """Координаты для pcolormesh: x по граням, z_agl-независимо абсолютная z; земля маскируется."""
    return M._faces_x(meta), M._faces_z(meta)


def fields_figure(meta, arr, rmeta, rarr, xc, L, title, path):
    uc, wc = M.cell_vel(arr)
    ur, wr = M.cell_vel(rarr)
    air = rarr["cell"] > 0.5
    sp, sr = np.hypot(uc, wc), np.hypot(ur, wr)
    mask = ~air
    x, z = _grid(rmeta, rarr)
    xlim = (xc - 3 * L, xc + 6 * L)
    zmax = max(float(rarr["h"].max()) + 700.0, 900.0)
    fig, ax = plt.subplots(2, 3, figsize=(15, 7), sharex=True, sharey=True)
    smax = float(np.nanmax(np.where(air, sr, np.nan)))
    dmax = max(float(np.nanmax(np.abs(np.where(air, sp - sr, np.nan)))), 1e-9)
    wmax = max(float(np.nanmax(np.abs(np.where(air, wr, np.nan)))),
               float(np.nanmax(np.abs(np.where(air, wc, np.nan)))), 1e-9)
    dwmax = max(float(np.nanmax(np.abs(np.where(air, wc - wr, np.nan)))), 1e-9)

    def panel(a, data, cmap, vmin, vmax, ttl):
        pc = a.pcolormesh(x, z, np.ma.array(data, mask=mask), cmap=cmap, vmin=vmin, vmax=vmax, shading="flat")
        a.set_title(ttl, fontsize=9)
        a.set_xlim(*xlim)
        a.set_ylim(-rmeta["dz"], zmax)
        fig.colorbar(pc, ax=a, fraction=0.04)
        return pc
    panel(ax[0, 0], sr, "viridis", 0, smax, "|u| эталон (стрелки), м/с")
    xs, zc = M.centers(rmeta)
    sx, sz = max(1, int(round(100.0 / rmeta["dx"]))), max(1, int(round(75.0 / rmeta["dz"])))
    xi, zi = np.arange(0, rmeta["nx"], sx), np.arange(0, rmeta["nz"], sz)
    qm = np.ix_(zi, xi)
    ax[0, 0].quiver(xs[xi], zc[zi], np.where(air, ur, 0)[qm], np.where(air, wr, 0)[qm], color="w", scale=smax * 40,
                    width=0.002)
    panel(ax[0, 1], sp, "viridis", 0, smax, "|u| поле, м/с")
    panel(ax[0, 2], sp - sr, "RdBu_r", -dmax, dmax, "|u| поле − эталон")
    panel(ax[1, 0], wr, "RdBu_r", -wmax, wmax, "w эталон, м/с")
    panel(ax[1, 1], wc, "RdBu_r", -wmax, wmax, "w поле, м/с")
    panel(ax[1, 2], wc - wr, "RdBu_r", -dwmax, dwmax, "w поле − эталон")
    fig.suptitle(title, fontsize=10)
    fig.tight_layout()
    dpi = save_small(fig, path)
    plt.close(fig)
    return dpi


def profiles_figure(series, xc, L, zmax, title, path):
    """series — список (подпись, meta, arr) на сетке эталона."""
    xs = [xc - L, xc, xc + 2 * L]
    zq = np.linspace(5.0, zmax, 120)
    fig, ax = plt.subplots(2, 3, figsize=(12, 7), sharey=True)
    for j, x in enumerate(xs):
        for name, m, a in series:
            uc, wc = M.cell_vel(a)
            for r, v in ((0, uc), (1, wc)):
                ax[r, j].plot(M.col_interp(m, a, v, x, zq), zq, label=name, lw=1.2)
        ax[0, j].set_title(f"x = {x:.0f} м", fontsize=9)
        ax[1, j].set_xlabel("w, м/с")
        ax[0, j].set_xlabel("u, м/с")
    ax[0, 0].set_ylabel("z_agl, м")
    ax[1, 0].set_ylabel("z_agl, м")
    ax[0, 0].legend(fontsize=8)
    fig.suptitle(title, fontsize=10)
    fig.tight_layout()
    dpi = save_small(fig, path)
    plt.close(fig)
    return dpi


def make(case, field, vs, ref, out_dir=None, xc=None, L=None):
    xc0, L0 = M.case_xc_L(case) if (xc is None or L is None) else (xc, L)
    xc, L = (xc0 if xc is None else xc), (L0 if L is None else L)
    rmeta, rarr = io.read_f1(ref)
    meta, arr = io.read_f1(field)
    m, a = M.to_ref_grid(meta, arr, rmeta, rarr)
    series = [(f"эталон P{rmeta['dx']}", rmeta, rarr)]
    if vs:
        k = int(vs.lstrip("B"))
        bp = M.picard_path(case, k)
        bm, ba = io.read_f1(bp)
        series.append((f"B{k}",) + M.make_baseline(bm, ba, rmeta, rarr))
    label = meta["variant"] or meta["source"]
    series.append((f"{label} d{meta['dx']}", m, a))
    out_dir = out_dir or os.path.join(FIG_DIR, case)
    os.makedirs(out_dir, exist_ok=True)
    stem = os.path.splitext(os.path.basename(field))[0]
    p1 = os.path.join(out_dir, f"{stem}_fields.png")
    p2 = os.path.join(out_dir, f"{stem}_profiles.png")
    fields_figure(m, a, rmeta, rarr, xc, L, f"{case}: {stem} против эталона", p1)
    profiles_figure(series, xc, L, 600.0, f"{case}: профили, {stem}", p2)
    return [p1, p2]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--case", required=True)
    ap.add_argument("--field", required=True)
    ap.add_argument("--vs", default="B400")
    ap.add_argument("--ref")
    ap.add_argument("--out")
    ap.add_argument("--xc", type=float)
    ap.add_argument("--L", type=float)
    a = ap.parse_args(argv)
    ref = a.ref
    if ref is None:
        ref = M.picard_path(a.case, 25)
        if not os.path.exists(ref):
            ref = M.picard_path(a.case, 50)
    for p in make(a.case, a.field, a.vs, ref, a.out, a.xc, a.L):
        print(p, os.path.getsize(p))
    return 0


if __name__ == "__main__":
    sys.exit(main())
