"""Картинки эталона AM-01 → out/ref/fig_*.png (по данным synth.py, ref_study.py; поля из fields/).

  ../heat_ca/.venv/bin/python ref_figs.py
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent
OUT = HERE / "out" / "ref"
FIELDS = HERE / "fields"


def load(p):
    p = Path(p)
    return np.load(p) if p.exists() else None


def fig_pilot():
    fig, axs = plt.subplots(3, 1, figsize=(12, 11))
    for ax, name, title in ((axs[0], "sec_check3_L300_N0.npz", "Аньези H = 300, L = 300 м (круто), нейтрально, U10 = 5"),
                            (axs[1], "sec_check3_L800_N0.npz", "Аньези H = 300, L = 800 м (полого)"),
                            (axs[2], "sec_check4_N0.npz", "Хребет H = 500, L = 500 м: полоса 2 H / 2,5 H")):
        d = load(OUT / name)
        if d is None:
            continue
        x, z, w, u, h = d["x"], d["z"], d["w"], d["u"], d["h"]
        sel = np.abs(x) < 3500
        im = ax.pcolormesh(x[sel], z, w[:, sel], cmap="RdBu_r", vmin=-2, vmax=2, shading="auto")
        cs = ax.contour(x[sel], z, u[:, sel], levels=np.arange(2, 16, 1), colors="k", linewidths=0.4)
        ax.clabel(cs, fontsize=6, fmt="%g")
        if "pw" in d.files:
            ax.contour(x[sel], z, d["pw"][:, sel] * 9.0, levels=[-1, -0.5, 0.5, 1], colors="g", linewidths=0.6, linestyles="--")
        ax.fill_between(x[sel], 0, h[sel], color="0.4")
        H = h.max()
        for m in (2.0, 2.5):
            ax.axhline(m * H, color="m", lw=0.6, ls=":")
        ax.set_ylim(0, 2000 if "check3" in name else 2500)
        ax.set_title(title + " — w (цвет), |u| (изолинии), потенц. w×9 (зелёный пунктир)")
        fig.colorbar(im, ax=ax, label="w, м/с")
    fig.tight_layout()
    fig.savefig(OUT / "fig_pilot_sections.png", dpi=100)
    plt.close(fig)


def fig_saddle():
    fig, axs = plt.subplots(1, 2, figsize=(14, 6))
    for ax, a in zip(axs, (0, 15)):
        d = load(OUT / f"map_check5_a{a}.npz")
        if d is None:
            continue
        x, y, s = d["x"], d["y"], d["s20"]
        sel_x = np.abs(x) < 4000; sel_y = np.abs(y) < 4000
        im = ax.pcolormesh(x[sel_x], y[sel_y], s[np.ix_(sel_y, sel_x)], cmap="viridis", shading="auto")
        ax.contour(x[sel_x], y[sel_y], d["h"][np.ix_(sel_y, sel_x)], levels=np.arange(50, 550, 100), colors="w", linewidths=0.5)
        st = 3
        X, Y = np.meshgrid(x[sel_x][::st], y[sel_y][::st])
        ax.quiver(X, Y, d["u20"][np.ix_(sel_y, sel_x)][::st, ::st], d["v20"][np.ix_(sel_y, sel_x)][::st, ::st], color="w", scale=150)
        ax.set_aspect("equal"); ax.set_title(f"Седловина: скорость на 20 м над землёй, ветер под {a}° к оси")
        fig.colorbar(im, ax=ax, label="м/с")
    fig.tight_layout()
    fig.savefig(OUT / "fig_saddle.png", dpi=100)
    plt.close(fig)


def fig_heat():
    names = [("one_slope", "солнце на восточный склон, штиль"), ("both", "оба склона, штиль"),
             ("wind", "восточный склон + ветер 3 м/с с запада"), ("inversion", "инверсия на 1500 м")]
    fig, axs = plt.subplots(2, 2, figsize=(15, 9))
    for ax, (n, t) in zip(axs.ravel(), names):
        d = load(FIELDS / f"heat_{n}.npz")
        if d is None:
            continue
        dx, dz, z_bot, x0, y0 = (float(d[k]) for k in ("dx", "dz", "z_bot", "x0", "y0"))
        w, u, th, hc = d["w"], d["u"], d["th"], d["hc"]
        nz, ny, nx = w.shape
        x = x0 + (np.arange(nx) + 0.5) * dx; y = y0 + (np.arange(ny) + 0.5) * dx
        z = z_bot + (np.arange(nz) + 0.5) * dz
        mid = np.abs(y) < 1000
        W = np.nanmean(w[:, mid], axis=1); Uu = np.nanmean(u[:, mid], axis=1); T = np.nanmean(th[:, mid], axis=1)
        sel = np.abs(x) < 5000
        im = ax.pcolormesh(x[sel], z, W[:, sel], cmap="RdBu_r", vmin=-1.0, vmax=1.0, shading="auto")
        ax.contour(x[sel], z, T[:, sel], levels=[0.1, 0.3, 0.6, 1.0, 2.0], colors="orange", linewidths=0.7)
        sx, sz = 3, 3
        ax.quiver(x[sel][::sx], z[::sz], Uu[::sz, sel][:, ::sx], W[::sz, sel][:, ::sx], scale=30, width=0.002)
        ax.fill_between(x[sel], 0, hc[ny // 2][sel], color="0.4")
        ax.set_ylim(0, 3000); ax.set_title(t + " — w (цвет), θ′ (оранж.), стрелки u, w")
        fig.colorbar(im, ax=ax, label="w, м/с")
    fig.tight_layout()
    fig.savefig(OUT / "fig_heat.png", dpi=100)
    plt.close(fig)


def fig_cells():
    p = OUT / "cells.json"
    if not p.exists():
        return
    r = json.loads(p.read_text())
    fig, axs = plt.subplots(1, 3, figsize=(16, 5))
    lv = [("d400", 400), ("d200", 200), ("w100", 100), ("w50", 50)]
    for row in r["rows"]:
        if not row["heat"]:
            continue
        xs, it, up, sp = [], [], [], []
        for k, dx in lv:
            if k in row:
                xs.append(dx); it.append(row[k]["iters"] if row[k]["status"] == "ok" else np.nan)
                up.append(row[k]["key"]["start_w200_max"]); sp.append(row[k]["key"]["start_speed50"])
        lab = f"U10 = {row['U10']:g}"
        axs[0].plot(xs, it, "o-", label=lab); axs[1].plot(xs, up, "o-", label=lab); axs[2].plot(xs, sp, "o-", label=lab)
    for ax, t in zip(axs, ("итераций до критерия", "подъём у старта (max w, 200 м AGL, ≤1,5 км), м/с", "ветер на 50 м над стартом, м/с")):
        ax.set_xscale("log"); ax.invert_xaxis(); ax.set_xticks([400, 200, 100, 50]); ax.set_xticklabels(["400", "200", "100", "50"])
        ax.set_xlabel("клетка, м"); ax.set_title(t); ax.grid(alpha=0.3); ax.legend()
    fig.tight_layout()
    fig.savefig(OUT / "fig_cells.png", dpi=100)
    plt.close(fig)


def _agl(F, hc, z_bot, dz, h):
    nz = F.shape[0]
    z = z_bot + (np.arange(nz) + 0.5) * dz
    kf = (hc + h - z[0]) / dz
    k0 = np.clip(np.floor(kf).astype(int), 0, nz - 2)
    a = np.clip(kf - k0, 0, 1)
    jj, ii = np.indices(hc.shape)
    f0 = F[k0, jj, ii]; f1 = F[k0 + 1, jj, ii]
    f0 = np.where(np.isnan(f0), f1, f0); f1 = np.where(np.isnan(f1), f0, f1)
    return (1 - a) * f0 + a * f1


def fig_evening():
    items = [(FIELDS / "evening_w100_U0.npz", "Онгудай, окно 100 м, 20:00, штиль"),
             (FIELDS / "evening_w100_U3.npz", "Онгудай, окно 100 м, 20:00, 3 м/с с 150°"),
             (FIELDS / "aushkul_w50_U3.npz", "Аушкуль, окно 50 м, 12:00, 3 м/с с запада")]
    fig, axs = plt.subplots(1, 3, figsize=(19, 6))
    for ax, (p, t) in zip(axs, items):
        d = load(p)
        if d is None:
            continue
        dx, dz, z_bot, x0, y0 = (float(d[k]) for k in ("dx", "dz", "z_bot", "x0", "y0"))
        hc = d["hc"]; ny, nx = hc.shape
        x = x0 + (np.arange(nx) + 0.5) * dx; y = y0 + (np.arange(ny) + 0.5) * dx
        u, v, w = (_agl(d[k], hc, z_bot, dz, 50.0) for k in "uvw")
        im = ax.pcolormesh(x, y, w, cmap="RdBu_r", vmin=-1.5, vmax=1.5, shading="auto")
        ax.contour(x, y, hc, levels=15, colors="k", linewidths=0.3)
        st = 3
        ax.quiver(x[::st], y[::st], u[::st, ::st], v[::st, ::st], scale=60)
        ax.set_aspect("equal"); ax.set_title(t + ": w (цвет) и ветер на 50 м AGL")
        fig.colorbar(im, ax=ax, label="w, м/с")
    fig.tight_layout()
    fig.savefig(OUT / "fig_real_windows.png", dpi=100)
    plt.close(fig)


if __name__ == "__main__":
    for f in (fig_pilot, fig_saddle, fig_heat, fig_cells, fig_evening):
        try:
            f()
            print("ok", f.__name__)
        except Exception as e:  # noqa
            print("fail", f.__name__, e)
