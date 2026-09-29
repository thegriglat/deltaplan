#!/usr/bin/env python3
"""Картинки и таблицы по итогам study.py.

  ../heat_ca/.venv/bin/python report.py interp   → out/interp.json (ошибка интерполяции по часам, CPU)
  ../heat_ca/.venv/bin/python report.py figs     → out/fig_*.png
  ../heat_ca/.venv/bin/python report.py tables   → out/tables.md
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

import common as C  # noqa: E402
import terrain as T  # noqa: E402

OUT = C.OUT
NAMES = ("u", "v", "w", "th")


def fpath(name):
    """Поле опыта cells: окна 100 м — out/fields (в git), остальное — fields/cells (локально)."""
    p = OUT / "fields" / name
    return p if p.exists() else C.FIELDS / "cells" / name


def load(dx, key):
    d = np.load(C.FIELDS / f"d{dx}" / f"{key}.npz")
    return [d[k].astype(np.float32) for k in NAMES], json.loads(str(d["meta"]))


def errs(F, R, mask):
    out = {}
    for n, f, r in zip(NAMES, F, R):
        e = (f - r)[mask]
        out[n] = dict(rel=float(np.sqrt(np.sum(e ** 2) / max(np.sum(r[mask] ** 2), 1e-30))),
                      max=float(np.max(np.abs(e))), rms=float(np.sqrt(np.mean(e ** 2))))
    return out


# ---------------------------------------------------------------------------- interp
def cmd_interp():
    """Поле часа h против линейной интерполяции соседних хранимых часов."""
    cases = [
        ("шаг 2 ч: 12 ← (11, 13)", 12, [(11, 0.5), (13, 0.5)]),
        ("шаг 3 ч: 12 ← (9, 15)", 12, [(9, 0.5), (15, 0.5)]),
        ("шаг 3 ч: 11 ← (9, 12)", 11, [(9, 1 / 3), (12, 2 / 3)]),
        ("шаг 3 ч: 13 ← (12, 15)", 13, [(12, 2 / 3), (15, 1 / 3)]),
        ("шаг 4 ч: 13 ← (11, 15)", 13, [(11, 0.5), (15, 0.5)]),
        ("шаг 4 ч: 11 ← (9, 13)", 11, [(9, 0.5), (13, 0.5)]),
        ("шаг 4 ч: 15 ← (13, 17)", 15, [(13, 0.5), (17, 0.5)]),
        ("без интерп.: 12 ← 13", 12, [(13, 1.0)]),
        ("без интерп.: 12 ← 11", 12, [(11, 1.0)]),
        ("без интерп.: 13 ← 11", 13, [(11, 1.0)]),
        ("без интерп.: 13 ← 15", 13, [(15, 1.0)]),
        ("без интерп.: 12 ← 9", 12, [(9, 1.0)]),
        ("без нагрева вместо 13", 13, [(None, 1.0)]),
    ]
    winds = [(0, 0), (3, 0), (3, 90), (3, 180), (3, 270), (6, 90), (6, 180)]
    res = []
    for dx in (400, 200):
        for U, d in winds:
            def key(h):
                hh = "noheat" if h is None else f"h{h}"
                return f"{hh}_U{U}_d{d if U > 0 else 0}"
            try:
                cache = {}
                def get(h):
                    if h not in cache:
                        cache[h] = load(dx, key(h))[0]
                    return cache[h]
                for name, tgt, src in cases:
                    R = get(tgt)
                    F = [sum(w * get(h)[i] for h, w in src) for i in range(4)]
                    mask = ~((R[0] == 0) & (R[1] == 0) & (R[2] == 0) & (R[3] == 0))
                    e = errs(F, R, mask)
                    res.append(dict(dx=dx, wind=U, wdir=d, case=name, **e))
            except FileNotFoundError as ex:
                print("нет поля", ex)
                continue
        # пол fp16: то же поле, округлённое в fp16 (поля и так fp16 → оценим от fp32 решения нет; пропуск)
    C.jdump(res, OUT / "interp.json")
    # короткая сводка
    import collections
    agg = collections.defaultdict(list)
    for r in res:
        agg[(r["dx"], r["case"])].append(r)
    for (dx, case), rs in agg.items():
        f = lambda n, k: max(r[n][k] for r in rs)
        print(f"{dx} м  {case:26s} w: отн {f('w','rel'):.3f} макс {f('w','max'):.2f} м/с | u: отн "
              f"{f('u','rel'):.3f} макс {f('u','max'):.2f} | θ′: отн {f('th','rel'):.3f} макс {f('th','max'):.2f} К")


# ---------------------------------------------------------------------------- figs
def fig_map():
    t = C.ter()
    h = t["h"]
    s = t["sites"]["start"]
    P = C.probes()
    fig, ax = plt.subplots(1, 3, figsize=(20, 6.8))
    ext = [-20000, 20000, -20000, 20000]
    ls = matplotlib.colors.LightSource(azdeg=315, altdeg=40)
    ax[0].imshow(ls.shade(h, cmap=plt.cm.terrain, vert_exag=2, blend_mode="soft", dx=25, dy=25), origin="lower",
                 extent=ext)
    L = C.DOMAIN_L / 2
    ax[0].plot([-L, L, L, -L, -L], [-L, -L, L, L, -L], "k--", lw=1, label="область 38,4 км")
    for dx, col in ((100.0, "r"), (50.0, "m")):
        g = C.grid_window(dx)
        ax[0].plot([g.x0, g.x0 + g.nx * dx, g.x0 + g.nx * dx, g.x0, g.x0],
                   [g.y0, g.y0, g.y0 + g.ny * dx, g.y0 + g.ny * dx, g.y0], col, lw=1.5,
                   label=f"окно {dx:.0f} м (64×64)")
    ax[0].plot(*P["start"], "r*", ms=14, label="старт Каянча")
    ax[0].plot(*P["saddle"], "bo", ms=7, label="седловина")
    ax[0].set_title("Рельеф Онгудая (слой detail, 25 м)")
    ax[0].legend(loc="lower left", fontsize=8)
    ax[0].set_xlabel("x, м (восток)")
    ax[0].set_ylabel("y, м (север)")
    # окно 6,4 км
    g = C.grid_window(100.0)
    hc = C.heights(g)
    X = g.x0 + (np.arange(g.nx) + 0.5) * g.dx
    Y = g.y0 + (np.arange(g.ny) + 0.5) * g.dx
    im = ax[1].contourf(X, Y, hc, levels=30, cmap="terrain")
    ax[1].contour(X, Y, hc, levels=range(900, 2000, 50), colors="k", linewidths=0.3)
    plt.colorbar(im, ax=ax[1], label="м")
    ax[1].plot(*P["start"], "r*", ms=14)
    ax[1].plot(*P["saddle"], "bo", ms=7)
    ax[1].set_title("Окно 100 м вокруг старта")
    # нагрев 13 ч
    import solver as S
    el, az = S.solar_position(50.79, 86.13, 196, 13 - 0.3, 7)
    e, a = math.radians(el), math.radians(az)
    sx, sy, sz = math.cos(e) * math.sin(a), math.cos(e) * math.cos(a), math.sin(e)
    g2 = C.grid_domain(200.0)
    hc2 = C.heights(g2)
    gy, gx = np.gradient(hc2, 200.0)
    Q = 330.0 * (np.clip(-gx * sx - gy * sy + sz, 0, None) + 0.1 * sz) * (1 - C.water(g2))
    im = ax[2].imshow(Q, origin="lower", extent=[g2.x0, g2.x0 + g2.nx * 200, g2.y0, g2.y0 + g2.ny * 200],
                      cmap="inferno", vmin=0)
    plt.colorbar(im, ax=ax[2], label="Вт/м² (на гориз. площадь)")
    ax[2].plot(*P["start"], "c*", ms=12)
    ax[2].set_title(f"Явный поток тепла 13:00 (солнце {el:.0f}°, азимут {az:.0f}°), сетка 200 м")
    for a_ in ax:
        a_.set_aspect("equal")
    plt.tight_layout()
    plt.savefig(OUT / "fig_map.png", dpi=90)
    plt.close()


class Field:
    """Поле из npz (центры клеток) + геометрия."""

    def __init__(self, path):
        d = np.load(path)
        self.F = [d[k].astype(np.float32) for k in NAMES]
        self.meta = json.loads(str(d["meta"]))
        m = self.meta
        self.hc = d["hc"]
        self.dx, self.dz = m["dx"], m["dz"]
        self.x0, self.y0, self.z_bot = m["x0"], m["y0"], m["z_bot"]
        self.nx, self.ny, self.nz = m["nx"], m["ny"], m["nz"]
        self.x = self.x0 + (np.arange(self.nx) + 0.5) * self.dx
        self.y = self.y0 + (np.arange(self.ny) + 0.5) * self.dx
        self.z = self.z_bot + (np.arange(self.nz) + 0.5) * self.dz
        solid = self.z[:, None, None] < self.hc[None]
        self.solid = solid
        for a in self.F:
            a[solid] = np.nan
        self.kb = np.argmax(~solid, axis=0)

    def agl(self, F, h):
        zt = self.hc + h
        kf = (zt - self.z[0]) / self.dz
        kf = np.maximum(kf, self.kb)
        k0 = np.clip(np.floor(kf).astype(int), 0, self.nz - 2)
        a = np.clip(kf - k0, 0, 1)
        jj, ii = np.indices(self.hc.shape)
        f0 = F[k0, jj, ii]
        f1 = F[k0 + 1, jj, ii]
        f1 = np.where(np.isnan(f1), f0, f1)
        return (1 - a) * f0 + a * f1

    @property
    def extent(self):
        return [self.x0, self.x0 + self.nx * self.dx, self.y0, self.y0 + self.ny * self.dx]


def _slice_panel(ax, fld, agl, what, title, vmax=None, quiver=True, sites=True):
    u, v, w, th = fld.F
    if what == "w":
        M = fld.agl(w, agl)
        vm = vmax or np.nanpercentile(np.abs(M), 99.5)
        im = ax.imshow(M, origin="lower", extent=fld.extent, cmap="RdBu_r", vmin=-vm, vmax=vm)
        lab = "w, м/с"
    elif what == "th":
        M = fld.agl(th, agl)
        im = ax.imshow(M, origin="lower", extent=fld.extent, cmap="inferno")
        lab = "θ′, К"
    else:
        M = np.hypot(fld.agl(u, agl), fld.agl(v, agl))
        im = ax.imshow(M, origin="lower", extent=fld.extent, cmap="viridis", vmin=0, vmax=vmax)
        lab = "|u_h|, м/с"
    ax.contour(fld.x, fld.y, fld.hc, levels=np.arange(500, 2600, 200 if fld.dx >= 200 else 50), colors="k",
               linewidths=0.25, alpha=0.6)
    if quiver:
        st = max(1, fld.nx // 24)
        U, V = fld.agl(u, agl), fld.agl(v, agl)
        X, Y = np.meshgrid(fld.x, fld.y)
        ax.quiver(X[::st, ::st], Y[::st, ::st], U[::st, ::st], V[::st, ::st], color="k", alpha=0.7,
                  scale=None, width=0.003)
    if sites:
        P = C.probes()
        ax.plot(*P["start"], "*", color="lime", ms=12, mec="k")
        ax.plot(*P["saddle"], "o", color="cyan", ms=5, mec="k")
    ax.set_xlim(fld.extent[:2])
    ax.set_ylim(fld.extent[2:])
    ax.set_title(title, fontsize=10)
    plt.colorbar(im, ax=ax, label=lab, shrink=0.8)


def fig_slices():
    cases = [("d200", "h13_U0_d0", "штиль, 13:00"), ("d200", "h13_U3_d180", "южный 3 м/с, 13:00"),
             ("d200", "noheat_U3_d180", "южный 3 м/с, без нагрева"), ("d200", "h13_U6_d270", "западный 6 м/с, 13:00")]
    fig, axs = plt.subplots(len(cases), 3, figsize=(19, 5.6 * len(cases)))
    for row, (lev, key, title) in zip(axs, cases):
        p = C.FIELDS / lev / f"{key}.npz"
        if not p.exists():
            continue
        f = Field(p)
        _slice_panel(row[0], f, 50, "w", f"w на 50 м над землёй — {title}", quiver=False)
        _slice_panel(row[1], f, 200, "w", f"w на 200 м — {title}", quiver=False)
        _slice_panel(row[2], f, 50, "s", f"ветер на 50 м — {title}")
    plt.tight_layout()
    plt.savefig(OUT / "fig_slices_200m.png", dpi=75)
    plt.close()


def fig_windows():
    cases = [("W100", "h13_U0_d0", "штиль"), ("W100", "h13_U3_d180", "южный 3 м/с"),
             ("W50", "h13_U0_d0", "штиль"), ("W50", "h13_U3_d180", "южный 3 м/с")]
    fig, axs = plt.subplots(len(cases), 3, figsize=(18, 5.4 * len(cases)))
    for row, (lev, key, title) in zip(axs, cases):
        p = fpath(f"{lev}_{key}.npz")
        if not p.exists():
            continue
        f = Field(p)
        t = f"окно {lev[1:]} м, 13:00, {title}"
        _slice_panel(row[0], f, 50, "w", f"w на 50 м — {t}", quiver=False)
        _slice_panel(row[1], f, 200, "w", f"w на 200 м — {t}", quiver=False)
        _slice_panel(row[2], f, 50, "s", f"ветер на 50 м — {t}")
    plt.tight_layout()
    plt.savefig(OUT / "fig_windows.png", dpi=75)
    plt.close()


def section(fld, F, x0, y0, x1, y1, n=300):
    """Вертикальный разрез по отрезку: значения F на (s, z), высота рельефа."""
    xs = np.linspace(x0, x1, n)
    ys = np.linspace(y0, y1, n)
    fi = (xs - fld.x0) / fld.dx - 0.5
    fj = (ys - fld.y0) / fld.dx - 0.5
    i0 = np.clip(np.floor(fi).astype(int), 0, fld.nx - 2)
    j0 = np.clip(np.floor(fj).astype(int), 0, fld.ny - 2)
    a = (fi - i0)[None]
    b = (fj - j0)[None]
    G = np.nan_to_num(F)
    V = ((1 - b) * ((1 - a) * G[:, j0, i0] + a * G[:, j0, i0 + 1]) + b * ((1 - a) * G[:, j0 + 1, i0] + a * G[:, j0 + 1, i0 + 1]))
    H = ((1 - b[0]) * ((1 - a[0]) * fld.hc[j0, i0] + a[0] * fld.hc[j0, i0 + 1])
         + b[0] * ((1 - a[0]) * fld.hc[j0 + 1, i0] + a[0] * fld.hc[j0 + 1, i0 + 1]))
    s = np.hypot(xs - x0, ys - y0)
    V = np.where(fld.z[:, None] < H[None], np.nan, V)
    inside = (fi >= 0) & (fi <= fld.nx - 1) & (fj >= 0) & (fj <= fld.ny - 1)
    V[:, ~inside] = np.nan
    H = np.where(inside, H, np.nan)
    return s, V, H


def fig_section():
    P = C.probes()
    sx, sy = P["start"]
    # разрез по склону старта (курс 151°) через старт и седловину: с юго-юго-востока на северо-северо-запад
    hd = math.radians(151)
    L0, L1 = 3000.0, 2500.0
    x0, y0 = sx + L0 * math.sin(hd), sy + L0 * math.cos(hd)
    x1, y1 = sx - L1 * math.sin(hd), sy - L1 * math.cos(hd)
    cases = [(fpath("W100_h13_U0_d0.npz"), "окно 100 м, штиль 13:00"),
             (fpath("W100_h13_U3_d180.npz"), "окно 100 м, южный 3 м/с 13:00"),
             (fpath("W50_h13_U3_d180.npz"), "окно 50 м, южный 3 м/с 13:00"),
             (C.FIELDS / "d200" / "h13_U3_d180.npz", "область 200 м, южный 3 м/с 13:00")]
    fig, axs = plt.subplots(len(cases), 2, figsize=(18, 4.2 * len(cases)))
    for row, (p, title) in zip(axs, cases):
        if not Path(p).exists():
            continue
        f = Field(p)
        u, v, w, th = f.F
        # компонента вдоль разреза (от x0,y0 к x1,y1)
        ex, ey = (x1 - x0), (y1 - y0)
        n_ = math.hypot(ex, ey)
        ex, ey = ex / n_, ey / n_
        s, Ua, H = section(f, u * ex + v * ey, x0, y0, x1, y1)
        _, W, _ = section(f, w, x0, y0, x1, y1)
        _, TH, _ = section(f, th, x0, y0, x1, y1)
        ds = math.hypot(sx - x0, sy - y0)
        for ax, M, cm, lab in ((row[0], W, "RdBu_r", "w, м/с"), (row[1], TH, "inferno", "θ′, К")):
            vm = np.nanpercentile(np.abs(M), 99.5) if cm == "RdBu_r" else None
            im = ax.pcolormesh(s, f.z, M, cmap=cm, vmin=-vm if vm else None, vmax=vm, shading="auto")
            ax.fill_between(s, 0, H, color="0.35")
            st = max(1, len(s) // 40)
            kz = max(1, f.nz // 25)
            ax.quiver(s[::st], f.z[::kz], np.nan_to_num(Ua[::kz, ::st]), np.nan_to_num(W[::kz, ::st]),
                      scale=60, width=0.002, alpha=0.8)
            ax.axvline(ds, color="lime", lw=1)
            ax.set_ylim(np.nanmin(H) - 50, np.nanmax(H) + 1500)
            ax.set_title(f"{title}: разрез ЮЮВ→ССЗ через старт (зелёная линия)", fontsize=10)
            ax.set_xlabel("м вдоль разреза")
            ax.set_ylabel("м над морем")
            plt.colorbar(im, ax=ax, label=lab)
    plt.tight_layout()
    plt.savefig(OUT / "fig_section.png", dpi=80)
    plt.close()


def fig_conv():
    d = json.loads((OUT / "conv.json").read_text())
    fig, axs = plt.subplots(1, 3, figsize=(19, 5.5))
    cols = dict(calm_h13="C0", U3w_h13="C1", U6w_h13="C3", U3w_noheat="C2")
    names = dict(calm_h13="штиль, 13:00", U3w_h13="западный 3 м/с, 13:00", U6w_h13="западный 6 м/с, 13:00",
                 U3w_noheat="западный 3 м/с, без нагрева")
    for c in d["cases"]:
        ls = "-" if c["dx"] == 200 else "--"
        it = [h["it"] for h in c["hist"]]
        axs[0].semilogy(it, [h["mom_rms"] for h in c["hist"]], ls, color=cols[c["name"]],
                        label=f"{c['dx']:.0f} м {names[c['name']]}")
        axs[1].semilogy(it, [h["th_rms"] for h in c["hist"]], ls, color=cols[c["name"]])
        e = c["errs"]
        axs[2].semilogy([x["it"] for x in e], [x["w"]["rel"] for x in e], ls, color=cols[c["name"]])
        axs[2].semilogy([x["it"] for x in e], [x["u"]["rel"] for x in e], ls, color=cols[c["name"]], alpha=0.35)
    axs[0].axhline(C.TOL["tol_mom"], color="k", lw=0.8)
    axs[1].axhline(C.TOL["tol_th"], color="k", lw=0.8)
    axs[2].axhline(0.01, color="k", lw=0.8)
    axs[0].set_title("Невязка импульса (СКО), м/с²")
    axs[1].set_title("Невязка тепла (СКО), К/с")
    axs[2].set_title("Ошибка против досчитанного решения: w (ярко), u (бледно), отн. L2")
    for a in axs:
        a.set_xlabel("итерация Пикара")
        a.grid(alpha=0.3)
    axs[0].legend(fontsize=8)
    plt.tight_layout()
    plt.savefig(OUT / "fig_convergence.png", dpi=85)
    plt.close()


def fig_warm():
    p = OUT / "warm.json"
    if not p.exists():
        return
    d = json.loads(p.read_text())
    rows = [r for r in d["pairs"] if r["dx"] == 200] or d["pairs"]
    fig, ax = plt.subplots(figsize=(13, 0.42 * len(rows) + 1.5))
    y = np.arange(len(rows))
    ax.barh(y + 0.27, [r["cold_iters"] for r in rows], 0.27, color="0.6", label="холодный старт")
    ax.barh(y, [r["warm_p_iters"] for r in rows], 0.27, color="C0", label="тёплый (u, v, w, θ′, p в fp16)")
    ax.barh(y - 0.27, [r["warm_nop_iters"] for r in rows], 0.27, color="C1", label="тёплый без p")
    ax.set_yticks(y)
    ax.set_yticklabels([f"{r['group']}: {r['desc']}" for r in rows], fontsize=8)
    ax.invert_yaxis()
    ax.set_xlabel(f"итераций до критерия (сетка {rows[0]['dx']:.0f} м)")
    ax.legend()
    ax.grid(axis="x", alpha=0.3)
    plt.tight_layout()
    plt.savefig(OUT / "fig_warm_start.png", dpi=90)
    plt.close()


def fig_interp():
    p = OUT / "interp.json"
    if not p.exists():
        return
    d = json.loads(p.read_text())
    cases = []
    for r in d:
        if r["case"] not in cases:
            cases.append(r["case"])
    fig, axs = plt.subplots(1, 2, figsize=(16, 6))
    for dx, mk in ((200, "o"), (400, "s")):
        for k, (n, col) in enumerate((("w", "C0"), ("u", "C1"), ("th", "C3"))):
            vals = [[r[n]["rel"] for r in d if r["dx"] == dx and r["case"] == c] for c in cases]
            mx = [max(v) if v else np.nan for v in vals]
            axs[0].plot(mx, range(len(cases)), mk, color=col, alpha=0.9 if dx == 200 else 0.4,
                        label=f"{n} ({dx} м)")
            vals = [[r[n]["max"] for r in d if r["dx"] == dx and r["case"] == c] for c in cases]
            mx = [max(v) if v else np.nan for v in vals]
            axs[1].plot(mx, range(len(cases)), mk, color=col, alpha=0.9 if dx == 200 else 0.4)
    for a in axs:
        a.set_yticks(range(len(cases)))
        a.set_yticklabels(cases, fontsize=9)
        a.invert_yaxis()
        a.set_xscale("log")
        a.grid(alpha=0.3)
    axs[0].set_title("Отн. ошибка L2 (худший из ветров)")
    axs[1].set_title("Макс. ошибка (м/с для u, w; К для θ′), худший из ветров")
    axs[0].axvline(0.01, color="k", lw=0.8)
    axs[0].axvline(0.05, color="k", lw=0.8, ls="--")
    axs[0].legend(fontsize=8)
    plt.tight_layout()
    plt.savefig(OUT / "fig_interp_hours.png", dpi=90)
    plt.close()


def fig_cells():
    p = OUT / "cells.json"
    if not p.exists():
        return
    d = json.loads(p.read_text())
    keys = []
    for r in d["runs"]:
        if r["key"] not in keys:
            keys.append(r["key"])
    fig, axs = plt.subplots(1, 3, figsize=(18, 5))
    lv = ["D400", "D200", "W100", "W50"]
    for key in keys:
        rs = {r["level"]: r for r in d["runs"] if r["key"] == key}
        xs = [rs[l]["dx"] for l in lv if l in rs]
        for ax, k in zip(axs, ("start_w200_max", "start_speed50", "saddle_speed50")):
            ax.plot(xs, [rs[l]["keys"][k] for l in lv if l in rs], "o-", label=key)
    for ax, t in zip(axs, ("макс. w на 200 м над землёй в 1,5 км от старта, м/с", "ветер на 50 м над стартом, м/с",
                           "ветер на 50 м в седловине, м/с")):
        ax.set_xscale("log")
        ax.set_xticks([400, 200, 100, 50])
        ax.set_xticklabels(["400", "200", "100", "50"])
        ax.invert_xaxis()
        ax.set_xlabel("клетка, м")
        ax.set_title(t, fontsize=10)
        ax.grid(alpha=0.3)
    axs[0].legend(fontsize=8)
    plt.tight_layout()
    plt.savefig(OUT / "fig_cells.png", dpi=90)
    plt.close()


def cmd_figs():
    for f in (fig_map, fig_conv, fig_slices, fig_windows, fig_section, fig_warm, fig_interp, fig_cells):
        try:
            f()
            print("ок", f.__name__)
        except Exception as ex:  # картинки независимы
            import traceback
            traceback.print_exc()
            print("не вышло", f.__name__, ex)




# ---------------------------------------------------------------------------- tables / library
def cmd_tables():
    import statistics as st
    L = []
    mx = json.loads((OUT / "matrix.json").read_text())
    # время на итерацию и решение по сеткам
    L.append("## Время решения (матрица: 6 часов + без нагрева × 13 ветров, холодный старт)\n")
    L.append("| Сетка | Клеток (с ореолом) / воздух | Случай | Итераций | Время, с | мс/итер. | Память пула, МБ |")
    L.append("|---|---|---|---|---|---|---|")
    per = {}
    for r in mx["runs"]:
        cat = ("штиль" if r["wind"] == 0 else f"{r['wind']:g} м/с") + (", без нагрева" if r["hour"] is None else ", с нагревом")
        per.setdefault((r["dx"], cat), []).append(r)
    for (dx, cat), rs in sorted(per.items(), key=lambda x: (-x[0][0], x[0][1])):
        it = [r["iters"] for r in rs]
        t = [r["t_solve"] for r in rs]
        ms = st.median([r["t_solve"] / r["iters"] * 1e3 for r in rs])
        L.append(f"| {dx:.0f} м | {rs[0]['cells'] / 1e6:.2f} M / {rs[0]['fluid'] / 1e6:.2f} M | {cat} ({len(rs)}) | "
                 f"{min(it)}–{max(it)} | {min(t):.2f}–{max(t):.2f} | {ms:.1f} | {max(r['mem_mb'] for r in rs):.0f} |")
    per_iter = {dx: st.median([r["t_solve"] / r["iters"] for r in mx["runs"] if r["dx"] == dx]) for dx in (400.0, 200.0)}
    ok = sum(r["status"] == "ok" for r in mx["runs"])
    L.append(f"\nСошлись {ok} из {len(mx['runs'])}. Баланс тепла (невязка / нагрев): "
             f"с ветром ≤ {max(abs(r['budget']['rel']) for r in mx['runs'] if r['wind'] > 0 and r['budget']['rel']):.1e}, "
             f"в штиль ≤ {max(abs(r['budget']['rel']) for r in mx['runs'] if r['wind'] == 0 and r['budget']['rel']):.1e}; "
             f"∇·u (СКО) ≤ {max(r['last']['div_rms'] for r in mx['runs']):.1e} 1/с.\n")
    # окна
    ce = json.loads((OUT / "cells.json").read_text())
    L.append("## Сходимость по клетке и окна\n")
    L.append("| Условия | Уровень | Сетка | Итераций | Время, с | Подъём у старта (макс. w на 200 м в 1,5 км), м/с | Ветер 50 м над стартом, м/с | Ветер 50 м в седловине, м/с | w макс / мин, м/с |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    for r in ce["runs"]:
        k = r["keys"]
        L.append(f"| {r['key']} | {r['level']} | {r['nx']}×{r['ny']}×{r['nz']} ({r['dx']:.0f}/{r['dz']:.0f} м) | {r['iters']} | "
                 f"{r['t_solve']:.2f} | {k['start_w200_max']:.2f} | {k['start_speed50']:.2f} | {k['saddle_speed50']:.2f} | "
                 f"{k['w_max']:.2f} / {k['w_min']:.2f} |")
    # тёплый старт
    wm = json.loads((OUT / "warm.json").read_text())
    L.append("\n## Тёплый старт (итераций до критерия; проверка раз в 10 итераций)\n")
    L.append("| Сетка | Что меняется | Цель ← опора | Холодный | Тёплый (с p) | Тёплый без p | Опора «как есть»: ошибка w |")
    L.append("|---|---|---|---|---|---|---|")
    for r in wm["pairs"]:
        L.append(f"| {r['dx']:.0f} м | {r['group']} | {r['desc']} | {r['cold_iters']} | {r['warm_p_iters']} | "
                 f"{r['warm_nop_iters']} | {r['src_as_is_err']['w']:.2f} |")
    # размер
    sz = json.loads((OUT / "size.json").read_text())
    L.append("\n## Размер одного поля (u, v, w, θ′), МБ\n")
    L.append("| Уровень | Сетка (клетки) | fp16 целиком | fp16 только воздух | zlib (npz) fp16 | zstd-19 fp16 воздух, байты по плоскостям | квант 0,02 + разность по z + zstd | p (fp16, zstd) |")
    L.append("|---|---|---|---|---|---|---|---|")
    agg = {}
    for r in sz["fields"]:
        agg.setdefault(r["level"], []).append(r)
    M = lambda v: v / 2 ** 20
    sizes = {}
    for lev, rs in agg.items():
        f = lambda k: f"{M(min(r[k] for r in rs)):.2f}–{M(max(r[k] for r in rs)):.2f}"
        sizes[lev] = dict(fp16=st.mean(M(r["zstd_fluid_shuffle"]) for r in rs), q=st.mean(M(r["zstd_q002_dz"]) for r in rs))
        pz = [M(r["p_zstd_fluid_shuffle"]) for r in rs if "p_zstd_fluid_shuffle" in r]
        L.append(f"| {lev} | {'×'.join(map(str, rs[0]['shape'][::-1]))} | {f('raw_fp16')} | {f('fluid_fp16')} | {f('zlib_fp16')} | "
                 f"{f('zstd_fluid_shuffle')} | {f('zstd_q002_dz')} | {('%.2f' % st.mean(pz)) if pz else '—'} |")
    # библиотеки
    t_d = {400: st.median([r["t_solve"] + r["t_init"] for r in mx["runs"] if r["dx"] == 400 and r["wind"] > 0]),
           200: st.median([r["t_solve"] + r["t_init"] for r in mx["runs"] if r["dx"] == 200 and r["wind"] > 0])}
    t_w = st.median([r["t_solve"] + r["t_init"] for r in ce["runs"] if r["level"] == "W100" and r["cond"]["wind"] > 0])
    t_w50 = st.median([r["t_solve"] + r["t_init"] for r in ce["runs"] if r["level"] == "W50" and r["cond"]["wind"] > 0])
    hour_warm = st.median([r["warm_p_iters"] / r["cold_iters"] for r in wm["pairs"] if r["group"] == "час"])
    libs = [
        ("а) опоры: 8 напр. × 2 силы × {без нагрева, 13 ч}", 32, 16),
        ("б1) все часы через 2 ч (9, 11, 13, 15, 17) × (8 × 2 + штиль)", 85, 17),
        ("б2) все часы через 3 ч (10, 13, 16) × (8 × 2 + штиль)", 51, 17),
        ("в) 3 часа старта (11, 13, 15) × (8 × 2 + штиль)", 51, 17),
        ("г) 16 напр. × 4 силы × 5 часов (через 2 ч) + штиль", 16 * 4 * 5 + 5, 16 * 4 + 1),
    ]
    L.append("\n## Библиотека на место (одно окно 100 м у старта; время — 4070 SUPER, холодные решения; "
             f"в скобках — с тёплым стартом по часам, ×{hour_warm:.2f} итераций)\n")
    L.append("| Вариант | Полей | Область 400 м + окно 100 м: МБ fp16-zstd / МБ квант | время | Область 200 м + окно 100 м: МБ fp16-zstd / МБ квант | время |")
    L.append("|---|---|---|---|---|---|")
    lib = []
    for name, n, chains in libs:
        row = dict(name=name, n=n)
        cells_ = []
        for dx in (400, 200):
            mb16 = n * (sizes[f"D{dx}"]["fp16"] + sizes["W100"]["fp16"])
            mbq = n * (sizes[f"D{dx}"]["q"] + sizes["W100"]["q"])
            t = n * (t_d[dx] + t_w)
            tw = chains * (t_d[dx] + t_w) + (n - chains) * hour_warm * (t_d[dx] + t_w)
            row[f"d{dx}"] = dict(mb_fp16=mb16, mb_q=mbq, t_cold=t, t_warm=tw)
            cells_.append(f"{mb16:.0f} / {mbq:.0f} | {t:.0f} с ({tw:.0f} с)")
        lib.append(row)
        L.append(f"| {name} | {n} | " + " | ".join(cells_) + " |")
    L.append(f"\nНа поле: область 400 м {t_d[400]:.2f} с, 200 м {t_d[200]:.2f} с, окно 100 м {t_w:.2f} с, окно 50 м {t_w50:.2f} с "
             f"(медианы с ветром). Размер: 400 м {sizes['D400']['fp16']:.2f}/{sizes['D400']['q']:.2f} МБ, "
             f"200 м {sizes['D200']['fp16']:.2f}/{sizes['D200']['q']:.2f}, окно 100 м {sizes['W100']['fp16']:.2f}/{sizes['W100']['q']:.2f}, "
             f"окно 50 м {sizes['W50']['fp16']:.2f}/{sizes['W50']['q']:.2f} (fp16-zstd / квант).")
    # Vulkan / AMD
    L.append("\n## Перенос на Vulkan / AMD (грубо: время ∝ 1 / пропускная способность памяти, та же доля от пика)\n")
    L.append("| Карта | ПСП, ГБ/с | ×к 4070 SUPER | Итерация 400 м / 200 м, мс | Решение 400 м / 200 м (ветер), с | Окно 100 м, с |")
    L.append("|---|---|---|---|---|---|")
    for name, bw in (("RTX 4070 SUPER (замер, CUDA)", 504), ("RX 7800 XT", 624), ("RX 6700 XT", 384), ("RX 7600", 288),
                     ("RX 6600", 224), ("RX 580", 256), ("Radeon 780M (встроенная, DDR5)", 90), ("Vega 8 (встроенная, DDR4)", 45)):
        k = 504 / bw
        L.append(f"| {name} | {bw} | {k:.1f} | {per_iter[400.0] * 1e3 * k:.0f} / {per_iter[200.0] * 1e3 * k:.0f} | "
                 f"{t_d[400] * k:.1f} / {t_d[200] * k:.1f} | {t_w * k:.1f} |")
    (OUT / "tables.md").write_text("\n".join(L) + "\n")
    C.jdump(dict(libraries=lib, sizes=sizes, t_domain=t_d, t_w100=t_w, t_w50=t_w50, per_iter=per_iter,
                 hour_warm_ratio=hour_warm), OUT / "library.json")
    print("\n".join(L))


if __name__ == "__main__":
    globals()["cmd_" + sys.argv[1]]()
