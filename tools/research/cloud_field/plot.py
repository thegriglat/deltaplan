#!/usr/bin/env python3
"""CLF-1: карты поля облачности из слепков dump.gd (out/<место>_<погода>_h<час>.json) и сводка.

Лист на место × погоду: кадры 11, 13, 15 ч (отмывка рельефа, покрытие, изолинии мощности, источники
термиков, граница «рельеф выше LCL», стрелка ветра основания) + разрез поперёк хребта в 13 ч
(рельеф, LCL, облако) + ход доли облачности. Сводка out/summary.json для 13 ч:
{место: {погода: {cover_frac, n_clouds, largest_km, depth_p50_m, depth_p90_m, src_under_cloud_ratio,
ridge_share, valley_share, base_msl}}}; «облако» — столбцы с покрытием ≥ CLOUD_THR.
  plot.py [--out out] [--fig <папка png>] [--places ongudai,training_island,almaty] [--weathers weak,strong,windy]
CLF-9 (z_i по рельефу): --before <папка слепков с α = 0> → листы fig/<место>_<погода>_zi.png (карты покрытия
до/после, карта z_i столбцов, разрезы) + out/zi_tops.json (потолки источников до/после: p10/p50/p90, м MSL;
основание) + в summary.json cover_lowland (рельеф < LOWLAND_M), cover_ridge (> RIDGE_M), z_i столбцов.
CLF-10 (опускание): --subsidence <папка слепков с τ_s = 0> → листы fig/<место>_<погода>_sub.png (покрытие до/после,
карты W̄ столбцов и W̄_м по мезомасштабу, разрезы, W̄/W̄_м и покрытие вдоль разреза, потолки источников) + out/subsidence.json
({место: {погода: {W_lowland_mean, W_ridge_mean, Wm_*, cover_lowland/cover_ridge [до, после], tops before/after p10/p50/p90, cell …}}});
--cell <папка слепков первой редакции, σ = 0> — третий столбик потолков и блок cell.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
CLOUD_THR = 0.3
FRAMES = (11, 13, 15)
NAMES = {"ongudai": "Онгудай", "training_island": "учебный остров", "almaty": "Алматы (43,20; 76,90)", "askarovo": "Аскарово"}
LOWLAND_M = 1200.0  # низина (город и предгорья Алматы): рельеф ниже, м MSL
RIDGE_M = 3000.0  # хребет: рельеф выше, м MSL
WX = {"weak": "слабый день (+20 °C, 6 км/ч)", "strong": "сильный день (+31 °C, 18 км/ч)", "windy": "ветреный (+31 °C, 8 м/с)"}


def grid(d, key):
    a = np.array([np.nan if v is None else v for v in d[key]], float)
    return a.reshape(d["ny"], d["nx"])


def components(mask):
    ny, nx = mask.shape
    lab = np.zeros(mask.shape, np.int32)
    comps = []
    k = 0
    for j0 in range(ny):
        for i0 in range(nx):
            if not mask[j0, i0] or lab[j0, i0]:
                continue
            k += 1
            st = [(j0, i0)]
            lab[j0, i0] = k
            cells = []
            while st:
                j, i = st.pop()
                cells.append((j, i))
                for dj in (-1, 0, 1):
                    for di in (-1, 0, 1):
                        jj, ii = j + dj, i + di
                        if 0 <= jj < ny and 0 <= ii < nx and mask[jj, ii] and not lab[jj, ii]:
                            lab[jj, ii] = k
                            st.append((jj, ii))
            comps.append(cells)
    return lab, comps


def extent_km(cells, dx):
    """Длина и ширина облака по главным осям (PCA по центрам клеток), км."""
    p = np.array(cells, float) * dx
    if len(p) < 2:
        return [dx / 1e3, dx / 1e3]
    q = p - p.mean(0)
    w, v = np.linalg.eigh(q.T @ q)
    pr = q @ v[:, ::-1]
    ext = pr.max(0) - pr.min(0) + dx
    return [round(float(ext[0]) / 1e3, 1), round(float(ext[1]) / 1e3, 1)]


def tpi(h, r):
    """Topographic position index: высота минус среднее в окне (2r + 1)², м."""
    ny, nx = h.shape
    pad = np.pad(h, r, mode="edge")
    acc = np.zeros_like(h)
    n = (2 * r + 1) ** 2
    for dj in range(-r, r + 1):
        for di in range(-r, r + 1):
            acc += pad[r + dj:r + dj + ny, r + di:r + di + nx]
    return h - acc / n


def hillshade(h, dx, az=315.0, alt=45.0):
    gy, gx = np.gradient(h, dx)
    slope = np.arctan(np.hypot(gx, gy) * 2.0)
    aspect = np.arctan2(-gx, gy)
    azr = math.radians(360 - az + 90)
    altr = math.radians(alt)
    s = np.sin(altr) * np.cos(slope) + np.cos(altr) * np.sin(slope) * np.cos(azr - aspect)
    return np.clip(s, 0, 1)


def stats(d):
    cov = grid(d, "cover")
    dep = grid(d, "depth")
    hc = grid(d, "hc")
    dx = d["dx"]
    m = cov >= CLOUD_THR
    lab, comps = components(m)
    out = {
        "cover_frac": round(float(cov.mean()), 4),
        "cloud_area_frac": round(float(m.mean()), 4),
        "n_clouds": len(comps),
        "largest_km": [0.0, 0.0],
        "depth_p50_m": 0.0,
        "depth_p90_m": 0.0,
        "src_under_cloud_ratio": 0.0,
        "ridge_share": 0.0,
        "valley_share": 0.0,
        "base_msl": round(float(d["base_msl"]), 1),
        "z_i_msl": None if d.get("z_i") is None else round(float(d["z_i"]), 1),
        "cloud_thr": CLOUD_THR,
        "peaks_above_lcl_frac": round(float((hc >= d["base_msl"]).mean()), 4),
        "cover_lowland": None if not (hc < LOWLAND_M).any() else round(float(cov[hc < LOWLAND_M].mean()), 4),
        "cover_ridge": None if not (hc > RIDGE_M).any() else round(float(cov[hc > RIDGE_M].mean()), 4),
        "lowland_frac": round(float((hc < LOWLAND_M).mean()), 4),
        "zi_alpha": d.get("zi_alpha"),
    }
    if d.get("z_i_col"):
        zc = grid(d, "z_i_col")
        out["z_i_col_p10_p50_p90"] = [round(float(np.nanpercentile(zc, q)), 0) for q in (10, 50, 90)]
        if (hc < LOWLAND_M).any():
            out["z_i_lowland_p50"] = round(float(np.nanpercentile(zc[hc < LOWLAND_M], 50)), 0)
        if (hc > RIDGE_M).any():
            out["z_i_ridge_p50"] = round(float(np.nanpercentile(zc[hc > RIDGE_M], 50)), 0)
    tops = np.array([s[3] for s in d.get("sources", []) if s[3] is not None], float)
    if tops.size:
        out["src_top_p10_p50_p90"] = [round(float(np.percentile(tops, q)), 0) for q in (10, 50, 90)]
        out["n_sources"] = int(tops.size)
    if comps:
        big = max(comps, key=len)
        out["largest_km"] = extent_km(big, dx)
        out["largest_area_km2"] = round(len(big) * dx * dx / 1e6, 1)
        out["depth_p50_m"] = round(float(np.percentile(dep[m], 50)), 0)
        out["depth_p90_m"] = round(float(np.percentile(dep[m], 90)), 0)
        t = tpi(hc, max(1, int(round(1000 / dx))))
        out["ridge_share"] = round(float((t[m] > 15).mean()), 3)
        out["valley_share"] = round(float((t[m] < -15).mean()), 3)
        srcs = d.get("sources", [])
        if srcs and m.mean() > 0:
            ii = np.clip(((np.array([s[0] for s in srcs]) - d["x0"]) / dx).astype(int), 0, d["nx"] - 1)
            jj = np.clip(((-np.array([s[1] for s in srcs]) - d["y0"]) / dx).astype(int), 0, d["ny"] - 1)
            under = float(m[jj, ii].mean())
            out["src_under_cloud_frac"] = round(under, 3)
            out["src_under_cloud_ratio"] = round(under / float(m.mean()), 2)
    return out


def section_line(hc, dx):
    """Разрез поперёк хребта: главная ось высоких клеток (верхние 20 %) → перпендикуляр через их центр."""
    ny, nx = hc.shape
    thr = np.percentile(hc, 80)
    jj, ii = np.nonzero(hc >= thr)
    p = np.stack([ii, jj], 1).astype(float)
    c = p.mean(0)
    q = p - c
    w, v = np.linalg.eigh(q.T @ q)
    ridge = v[:, -1]
    perp = np.array([-ridge[1], ridge[0]])
    half = 0.5 * max(nx, ny)
    ts = np.linspace(-half, half, 200)
    pts = c[None, :] + ts[:, None] * perp[None, :]
    ok = (pts[:, 0] >= 0) & (pts[:, 0] <= nx - 1) & (pts[:, 1] >= 0) & (pts[:, 1] <= ny - 1)
    return pts[ok], (ts[ok] - ts[ok][0]) * dx / 1e3, ridge, perp


def bilin(a, pts):
    ny, nx = a.shape
    x = np.clip(pts[:, 0], 0, nx - 1.0001)
    y = np.clip(pts[:, 1], 0, ny - 1.0001)
    i0 = x.astype(int)
    j0 = y.astype(int)
    fx = x - i0
    fy = y - j0
    return (a[j0, i0] * (1 - fx) * (1 - fy) + a[j0, i0 + 1] * fx * (1 - fy)
            + a[j0 + 1, i0] * (1 - fx) * fy + a[j0 + 1, i0 + 1] * fx * fy)


def plot_sheet(place, wname, frames, series, fig_path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, axs = plt.subplots(2, 3, figsize=(19, 12))
    ref = frames[sorted(frames)[0]]
    rel = ref["relief"]
    hr = np.array(rel["height"], float).reshape(rel["ny"], rel["nx"])
    shade = hillshade(hr, rel["step"])
    ext = [rel["x0"] / 1e3, (rel["x0"] + rel["nx"] * rel["step"]) / 1e3, rel["y0"] / 1e3, (rel["y0"] + rel["ny"] * rel["step"]) / 1e3]
    for k, fh in enumerate(FRAMES):
        ax = axs[0, k]
        d = frames.get(fh)
        if d is None:
            ax.set_title(f"{fh}:00 — нет кадра")
            continue
        cov = grid(d, "cover")
        dep = grid(d, "depth")
        hc = grid(d, "hc")
        dx = d["dx"]
        lext = [d["x0"] / 1e3, (d["x0"] + d["nx"] * dx) / 1e3, d["y0"] / 1e3, (d["y0"] + d["ny"] * dx) / 1e3]
        ax.imshow(shade * 0.55, cmap="gray", extent=ext, origin="lower", vmin=0, vmax=1.0)
        rgba = np.zeros(cov.shape + (4,))
        rgba[..., :3] = (0.95, 0.97, 1.0)
        rgba[..., 3] = np.clip(0.15 + cov * 1.1, 0, 1) * (cov >= 0.03)
        ax.imshow(rgba, extent=lext, origin="lower", interpolation="nearest")
        xs = np.linspace(lext[0], lext[1], d["nx"]); ys = np.linspace(lext[2], lext[3], d["ny"])
        if (cov >= CLOUD_THR).any():
            ax.contour(xs, ys, cov, levels=[CLOUD_THR], colors="#1f77b4", linewidths=0.6)
        if (dep > 100).any():
            ax.contour(xs, ys, dep, levels=[300, 800, 1500], colors=["#ffd27f", "#ff9f1a", "#d62728"], linewidths=0.7)
        above = hc >= d["base_msl"]
        if above.any():
            ax.contourf(xs, ys, above.astype(float), levels=[0.5, 1.5], colors="none", hatches=["////"], alpha=0)
            ax.contour(xs, ys, above.astype(float), levels=[0.5], colors="#d62728", linewidths=0.8)
        srcs = d.get("sources", [])
        if srcs:
            ax.scatter([s[0] / 1e3 for s in srcs], [-s[1] / 1e3 for s in srcs], s=4, c="red", linewidths=0, alpha=0.6)
        wb = d.get("wind_base", [0, 0])
        spd = math.hypot(wb[0], wb[1])
        if spd > 0.1:
            ax.annotate("", xy=(lext[0] + 4 + wb[0] / spd * 3, lext[3] - 4 - wb[1] / spd * 3), xytext=(lext[0] + 4, lext[3] - 4),
                        arrowprops=dict(arrowstyle="->", color="k", lw=2))
            ax.text(lext[0] + 1, lext[3] - 8.5, f"ветер основания {spd:.1f} м/с", fontsize=8)
        st = stats(d)
        ax.set_title(f"{fh}:00 — покрытие {st['cover_frac']:.2f} (≥{CLOUD_THR}: {st['cloud_area_frac']:.2f}), облаков {st['n_clouds']}, "
                     f"LCL {d['base_msl']:.0f} м, z_i {d.get('z_i') or 0:.0f} м", fontsize=8)
        ax.set_xlabel("x, км"); ax.set_ylabel("y = −z, км (север ↑)")
        if k == 0:
            ax.text(lext[0] + 1, lext[2] + 1, "белое — покрытие (прозрачность = cover), синий контур — ≥ %.1f; жёлт./оранж./красн. — мощность 300/800/1500 м;\nкрасная штриховка — рельеф выше LCL; точки — источники термиков поля" % CLOUD_THR, fontsize=6)
        ax.set_xlim(lext[0], lext[1]); ax.set_ylim(lext[2], lext[3])
    # --- разрез 13 ч
    ax = axs[1, 0]
    d = frames.get(13) or ref
    hc = grid(d, "hc"); cov = grid(d, "cover"); dep = grid(d, "depth"); ctop = grid(d, "c_top") if d.get("c_top") else None
    pts, skm, ridge, perp = section_line(hc, d["dx"])
    hs = bilin(hc, pts); cs = bilin(cov, pts); ds = bilin(dep, pts)
    base = d["base_msl"]
    ax.fill_between(skm, 0, hs, color="#8c7853")
    ax.axhline(base, color="#1f77b4", ls="--", lw=1, label=f"LCL {base:.0f} м")
    if d.get("z_i") is not None:
        ax.axhline(d["z_i"], color="#888", ls=":", lw=1, label=f"z_i {d['z_i']:.0f} м")
    if ctop is not None:
        cts = bilin(np.nan_to_num(ctop, nan=np.nan), pts)
        ax.plot(skm, cts, color="#2ca02c", lw=0.8, label="потолок частицы")
    for s0, c0, d0 in zip(skm, cs, ds):
        if c0 >= 0.05 and d0 > 0:
            ax.bar(s0, d0, bottom=base, width=skm[1] - skm[0] if len(skm) > 1 else 0.2, color="white", edgecolor="#555", linewidth=0.2, alpha=min(1.0, 0.3 + c0))
    ax.set_ylim(max(0, hs.min() - 300), max(base + 2500, hs.max() + 500))
    ax.set_xlabel("вдоль разреза, км"); ax.set_ylabel("м над морем")
    ax.set_title(f"разрез поперёк хребта в 13:00 (ось хребта {math.degrees(math.atan2(ridge[1], ridge[0])):.0f}° от x)", fontsize=9)
    ax.legend(fontsize=7, loc="upper right")
    # линия разреза на карте 13 ч
    k13 = FRAMES.index(13)
    axs[0, k13].plot((d["x0"] + (pts[:, 0] + 0.5) * d["dx"]) / 1e3, (d["y0"] + (pts[:, 1] + 0.5) * d["dx"]) / 1e3, color="magenta", lw=1)
    # --- ход покрытия
    ax = axs[1, 1]
    if series:
        s = np.array(series, float)
        ax.plot(s[:, 0], s[:, 1], label="среднее покрытие")
        ax.plot(s[:, 0], s[:, 2], label=f"доля столбцов ≥ {CLOUD_THR}")
        ax2 = ax.twinx()
        ax2.plot(s[:, 0], s[:, 3], color="#d62728", lw=0.8, label="средняя мощность, м")
        ax2.set_ylabel("м")
        ax.set_xlabel("час"); ax.set_ylabel("доля"); ax.legend(fontsize=7, loc="upper left"); ax2.legend(fontsize=7, loc="upper right")
    ax.set_title("ход облачности 9:00 → 17:00", fontsize=9)
    # --- источник подъёма a_u и потолок в 13 ч
    ax = axs[1, 2]
    au = grid(d, "au")
    lext = [d["x0"] / 1e3, (d["x0"] + d["nx"] * d["dx"]) / 1e3, d["y0"] / 1e3, (d["y0"] + d["ny"] * d["dx"]) / 1e3]
    ax.imshow(shade, cmap="gray", extent=ext, origin="lower", vmin=0, vmax=1.2)
    im = ax.imshow(np.ma.masked_where(au < 0.005, au), cmap="magma", extent=lext, origin="lower", vmin=0, vmax=max(0.05, float(np.nanmax(au))), alpha=0.85)
    plt.colorbar(im, ax=ax, shrink=0.7, label="a_u — доля площади подъёма у основания")
    ax.set_title("источник 13:00: подъём, дошедший до LCL", fontsize=9)
    ax.set_xlabel("x, км"); ax.set_ylabel("y, км")
    fig.suptitle(f"{NAMES.get(place, place)} — {WX.get(wname, wname)}: поле облачности CloudField (CLF-1)", fontsize=12)
    fig.tight_layout()
    fig.savefig(fig_path, dpi=72)
    plt.close(fig)


def tops_of(d):
    """Потолки источников термиков кадра (м MSL): p10/p50/p90, число; основание."""
    tops = np.array([s[3] for s in d.get("sources", []) if s[3] is not None], float)
    if not tops.size:
        return {"n": 0, "base_msl": round(float(d["base_msl"]), 0)}
    return {
        "n": int(tops.size),
        "p10": round(float(np.percentile(tops, 10)), 0),
        "p50": round(float(np.percentile(tops, 50)), 0),
        "p90": round(float(np.percentile(tops, 90)), 0),
        "max": round(float(tops.max()), 0),
        "base_msl": round(float(d["base_msl"]), 0),
        "z_i_ref": None if d.get("z_i") is None else round(float(d["z_i"]), 0),
    }


def draw_cover(ax, d, shade, ext, title):
    cov = grid(d, "cover")
    hc = grid(d, "hc")
    dx = d["dx"]
    lext = [d["x0"] / 1e3, (d["x0"] + d["nx"] * dx) / 1e3, d["y0"] / 1e3, (d["y0"] + d["ny"] * dx) / 1e3]
    ax.imshow(shade * 0.55, cmap="gray", extent=ext, origin="lower", vmin=0, vmax=1.0)
    rgba = np.zeros(cov.shape + (4,))
    rgba[..., :3] = (0.95, 0.97, 1.0)
    rgba[..., 3] = np.clip(0.15 + cov * 1.1, 0, 1) * (cov >= 0.03)
    ax.imshow(rgba, extent=lext, origin="lower", interpolation="nearest")
    xs = np.linspace(lext[0], lext[1], d["nx"]); ys = np.linspace(lext[2], lext[3], d["ny"])
    if (cov >= CLOUD_THR).any():
        ax.contour(xs, ys, cov, levels=[CLOUD_THR], colors="#1f77b4", linewidths=0.6)
    if (hc < LOWLAND_M).any() and (hc >= LOWLAND_M).any():
        ax.contour(xs, ys, hc, levels=[LOWLAND_M], colors="#2ca02c", linewidths=0.7, linestyles="--")
    if (hc > RIDGE_M).any() and (hc <= RIDGE_M).any():
        ax.contour(xs, ys, hc, levels=[RIDGE_M], colors="#d62728", linewidths=0.7, linestyles="--")
    srcs = d.get("sources", [])
    if srcs:
        ax.scatter([s[0] / 1e3 for s in srcs], [-s[1] / 1e3 for s in srcs], s=4, c="red", linewidths=0, alpha=0.6)
    st = stats(d)
    low = "—" if st["cover_lowland"] is None else f"{st['cover_lowland']:.2f}"
    rid = "—" if st["cover_ridge"] is None else f"{st['cover_ridge']:.2f}"
    ax.set_title(f"{title}: покрытие {st['cover_frac']:.2f}, низина (<{LOWLAND_M:.0f} м) {low}, хребет (>{RIDGE_M:.0f} м) {rid}", fontsize=8)
    ax.set_xlim(lext[0], lext[1]); ax.set_ylim(lext[2], lext[3])
    ax.set_xlabel("x, км"); ax.set_ylabel("y = −z, км")
    return lext


def draw_section(ax, d, pts, skm, title):
    hc = grid(d, "hc"); cov = grid(d, "cover"); dep = grid(d, "depth")
    ctop = grid(d, "c_top") if d.get("c_top") else None
    zc = grid(d, "z_i_col") if d.get("z_i_col") else None
    hs = bilin(hc, pts); cs = bilin(cov, pts); ds = bilin(dep, pts)
    base = d["base_msl"]
    ax.fill_between(skm, 0, hs, color="#8c7853")
    ax.axhline(base, color="#1f77b4", ls="--", lw=1, label=f"LCL {base:.0f} м")
    if d.get("z_i") is not None:
        ax.axhline(d["z_i"], color="#888", ls=":", lw=1, label=f"z_i дня {d['z_i']:.0f} м")
    if zc is not None:
        ax.plot(skm, bilin(zc, pts), color="#9467bd", lw=1.2, label="z_i столбцов")
    if ctop is not None:
        ax.plot(skm, bilin(np.nan_to_num(ctop, nan=np.nan), pts), color="#2ca02c", lw=0.8, label="потолок частицы")
    for s0, c0, d0 in zip(skm, cs, ds):
        if c0 >= 0.05 and d0 > 0:
            ax.bar(s0, d0, bottom=base, width=skm[1] - skm[0] if len(skm) > 1 else 0.2, color="white", edgecolor="#555", linewidth=0.2, alpha=min(1.0, 0.3 + c0))
    ax.set_ylim(max(0, hs.min() - 300), max(base + 2500, hs.max() + 500, (0 if zc is None else float(np.nanmax(zc)) + 300)))
    ax.set_xlabel("вдоль разреза, км"); ax.set_ylabel("м над морем")
    ax.set_title(title, fontsize=9)
    ax.legend(fontsize=7, loc="upper right")


def plot_zi_sheet(place, wname, before, after, fig_path):
    """Лист CLF-9: покрытие до (α = 0) и после (α из конфига) рядом, карта z_i столбцов, разрезы."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, axs = plt.subplots(2, 3, figsize=(19, 12))
    rel = after["relief"]
    hr = np.array(rel["height"], float).reshape(rel["ny"], rel["nx"])
    shade = hillshade(hr, rel["step"])
    ext = [rel["x0"] / 1e3, (rel["x0"] + rel["nx"] * rel["step"]) / 1e3, rel["y0"] / 1e3, (rel["y0"] + rel["ny"] * rel["step"]) / 1e3]
    draw_cover(axs[0, 0], before, shade, ext, f"до (α = 0), {before['hour']}:00")
    lext = draw_cover(axs[0, 1], after, shade, ext, f"после (α = {after.get('zi_alpha', 0):.2f}), {after['hour']}:00")
    axs[0, 0].text(lext[0] + 1, lext[2] + 1, "белое — покрытие, синий контур ≥ %.1f; зелёный пунктир — рельеф %.0f м, красный — %.0f м; точки — источники" % (CLOUD_THR, LOWLAND_M, RIDGE_M), fontsize=6)
    ax = axs[0, 2]
    hc = grid(after, "hc")
    ax.imshow(shade, cmap="gray", extent=ext, origin="lower", vmin=0, vmax=1.2)
    if after.get("z_i_col"):
        zc = grid(after, "z_i_col")
        im = ax.imshow(zc, cmap="viridis", extent=lext, origin="lower", alpha=0.8)
        plt.colorbar(im, ax=ax, shrink=0.7, label="z_i столбца, м над морем")
        st = stats(after)
        ax.set_title(f"z_i столбцов: p10/p50/p90 {st['z_i_col_p10_p50_p90']}, день {after.get('z_i') or 0:.0f} м; LCL {after['base_msl']:.0f} м", fontsize=8)
    else:
        ax.set_title("z_i столбцов — нет в кадре")
    ax.set_xlim(lext[0], lext[1]); ax.set_ylim(lext[2], lext[3])
    pts, skm, ridge, perp = section_line(hc, after["dx"])
    draw_section(axs[1, 0], before, pts, skm, "разрез до (α = 0)")
    draw_section(axs[1, 1], after, pts, skm, "разрез после")
    for k in (0, 1):
        axs[0, k].plot((after["x0"] + (pts[:, 0] + 0.5) * after["dx"]) / 1e3, (after["y0"] + (pts[:, 1] + 0.5) * after["dx"]) / 1e3, color="magenta", lw=1)
    # потолки источников до/после
    ax = axs[1, 2]
    tb, ta = tops_of(before), tops_of(after)
    for k, (t, lab) in enumerate(((tb, "до"), (ta, "после"))):
        if t["n"]:
            ax.bar(k, t["p90"] - t["p10"], bottom=t["p10"], width=0.5, color="#aec7e8", edgecolor="#1f77b4")
            ax.plot([k - 0.25, k + 0.25], [t["p50"], t["p50"]], color="k", lw=2)
            ax.text(k, t["p90"] + 50, f"{lab}: p10 {t['p10']:.0f} / p50 {t['p50']:.0f} / p90 {t['p90']:.0f} м, n {t['n']}", ha="center", fontsize=7)
    ax.axhline(after["base_msl"], color="#1f77b4", ls="--", lw=1, label=f"LCL {after['base_msl']:.0f} м")
    if after.get("z_i") is not None:
        ax.axhline(after["z_i"], color="#888", ls=":", lw=1, label=f"z_i дня {after['z_i']:.0f} м")
    ax.set_xticks([0, 1]); ax.set_xticklabels(["до (α = 0)", "после"])
    ax.set_ylabel("м над морем"); ax.set_title("потолки источников термиков (p10–p90, медиана)", fontsize=9)
    ax.legend(fontsize=7, loc="lower right")
    fig.suptitle(f"{NAMES.get(place, place)} — {WX.get(wname, wname)}: z_i по рельефу (CLF-9), {after['hour']}:00", fontsize=12)
    fig.tight_layout()
    fig.savefig(fig_path, dpi=72)
    plt.close(fig)


def main_zi(a, out, fig):
    """CLF-9: листы до/после, zi_tops.json, числа в summary.json (слияние с прежними)."""
    before_dir = Path(a.before)
    sp = out / "summary.json"
    summary = json.loads(sp.read_text()) if sp.exists() else {}
    tops = {}
    fh = int(a.hour)
    for place in a.places.split(","):
        for wname in a.weathers.split(","):
            pa = out / f"{place}_{wname}_h{fh}.json"
            pb = before_dir / f"{place}_{wname}_h{fh}.json"
            if not pa.exists() or not pb.exists():
                print(f"{place} {wname}: нет кадра {fh} ч ({pa.exists()}, {pb.exists()})")
                continue
            after = json.loads(pa.read_text())
            before = json.loads(pb.read_text())
            png = fig / f"{place}_{wname}_zi.png"
            plot_zi_sheet(place, wname, before, after, png)
            st = stats(after)
            st["cond"] = after.get("cond", {})
            st["before"] = {k: stats(before)[k] for k in ("cover_frac", "cover_lowland", "cover_ridge", "cloud_area_frac", "n_clouds", "depth_p50_m")}
            summary.setdefault(place, {})[wname] = st
            tops.setdefault(place, {})[wname] = {"before": tops_of(before), "after": tops_of(after)}
            print(f"{place} {wname}: {png}")
    sp.write_text(json.dumps(summary, ensure_ascii=False, indent=1))
    (out / "zi_tops.json").write_text(json.dumps(tops, ensure_ascii=False, indent=1))
    print(json.dumps(tops, ensure_ascii=False, indent=1))


def band_stats(d, cov_key="cover"):
    """CLF-10: W̄ столбцов (col_w), W̄_м мезомасштабное (col_wm), Δz_s (z_i_col − col_zi), покрытие и потолок частицы по низине/хребту."""
    hc = grid(d, "hc")
    cov = grid(d, cov_key)
    out = {}
    w = grid(d, "col_w") if d.get("col_w") else None
    wmeso = grid(d, "col_wm") if d.get("col_wm") else None
    zc = grid(d, "z_i_col") if d.get("z_i_col") else None
    zs = grid(d, "col_zi") if d.get("col_zi") else None
    ct = grid(d, "c_top") if d.get("c_top") else None
    bands = {"lowland": hc < LOWLAND_M, "ridge": hc > RIDGE_M, "all": np.ones_like(hc, bool)}
    hi = np.nanpercentile(hc, 80)
    bands["upper20"] = hc >= hi
    for name, m in bands.items():
        if not m.any():
            continue
        b = {"n": int(m.sum()), "cover": round(float(cov[m].mean()), 4)}
        if w is not None:
            wm = w[m]
            b["W_mean"] = round(float(np.nanmean(wm)), 4)
            b["W_p10_p50_p90"] = [round(float(np.nanpercentile(wm, q)), 4) for q in (10, 50, 90)]
            b["W_neg_frac"] = round(float(np.mean(wm < 0)), 3)
        if wmeso is not None:
            v = wmeso[m]
            b["Wm_mean"] = round(float(np.nanmean(v)), 4)
            b["Wm_p10_p50_p90"] = [round(float(np.nanpercentile(v, q)), 4) for q in (10, 50, 90)]
            b["Wm_neg_frac"] = round(float(np.mean(v < 0)), 3)
        if zc is not None and zs is not None:
            dz = (zc - zs)[m]
            b["dz_s_mean"] = round(float(np.nanmean(dz)), 0)
            b["dz_s_p50_p90"] = [round(float(np.nanpercentile(dz, q)), 0) for q in (50, 90)]
            b["z_i_eff_p50"] = round(float(np.nanpercentile(zs[m], 50)), 0)
        if ct is not None:
            b["c_top_p10_p50_p90"] = [round(float(np.nanpercentile(ct[m], q)), 0) for q in (10, 50, 90)]
            b["c_top_above_lcl_frac"] = round(float(np.nanmean(ct[m] > d["base_msl"])), 3)
        out[name] = b
    return out


def plot_sub_sheet(place, wname, before, after, fig_path, cell=None):
    """Лист CLF-10: покрытие до (τ_s = 0) / после, карты W̄ столбцов и W̄_м (мезомасштаб; Δz_s = |W̄_м⁻|·τ_s),
    разрезы, потолки (cell — кадр первой редакции с ячейковым W̄, третий столбик потолков)."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, axs = plt.subplots(2, 4, figsize=(24, 12))
    rel = after["relief"]
    hr = np.array(rel["height"], float).reshape(rel["ny"], rel["nx"])
    shade = hillshade(hr, rel["step"])
    ext = [rel["x0"] / 1e3, (rel["x0"] + rel["nx"] * rel["step"]) / 1e3, rel["y0"] / 1e3, (rel["y0"] + rel["ny"] * rel["step"]) / 1e3]
    draw_cover(axs[0, 0], before, shade, ext, f"до (без опускания), {before['hour']}:00")
    lext = draw_cover(axs[0, 1], after, shade, ext, f"после (опускание по W̄_м), {after['hour']}:00")
    axs[0, 0].text(lext[0] + 1, lext[2] + 1, "белое — покрытие, синий контур ≥ %.1f; зелёный пунктир — рельеф %.0f м, красный — %.0f м; точки — источники" % (CLOUD_THR, LOWLAND_M, RIDGE_M), fontsize=6)
    hc = grid(after, "hc")
    xs = np.linspace(lext[0], lext[1], after["nx"]); ys = np.linspace(lext[2], lext[3], after["ny"])
    bs = band_stats(after)
    low = bs.get("lowland", {}); rid = bs.get("ridge", bs.get("upper20", {}))
    vw = float(np.nanpercentile(np.abs(grid(after, "col_w")), 95)) if after.get("col_w") else 0.1
    for ax, key, title, pre in ((axs[0, 2], "col_w", "W̄ столбца (средний w_conv слоя 0..h), м/с", "W"), (axs[0, 3], "col_wm", "W̄_м — W̄ по мезомасштабу (σ гаусса), м/с; Δz_s = |W̄_м⁻|·τ_s", "Wm")):
        ax.imshow(shade, cmap="gray", extent=ext, origin="lower", vmin=0, vmax=1.2)
        if not after.get(key):
            ax.set_title(title + " — нет в кадре", fontsize=8)
            continue
        a = grid(after, key)
        v = vw if key == "col_w" else max(float(np.nanmax(np.abs(a))), 1e-3)
        im = ax.imshow(a, cmap="RdBu", extent=lext, origin="lower", alpha=0.85, vmin=-v, vmax=v)
        plt.colorbar(im, ax=ax, shrink=0.7)
        if key == "col_wm":
            ax.contour(xs, ys, a, levels=[0.0], colors="k", linewidths=0.6)
        if (hc < LOWLAND_M).any() and (hc >= LOWLAND_M).any():
            ax.contour(xs, ys, hc, levels=[LOWLAND_M], colors="#2ca02c", linewidths=0.7, linestyles="--")
        if (hc > RIDGE_M).any() and (hc <= RIDGE_M).any():
            ax.contour(xs, ys, hc, levels=[RIDGE_M], colors="#d62728", linewidths=0.7, linestyles="--")
        extra = "" if key == "col_w" else f"; Δz_s низина p50 {low.get('dz_s_p50_p90', [0, 0])[0]:.0f} м, хребет/верх {rid.get('dz_s_p50_p90', [0, 0])[0]:.0f} м"
        ax.set_title(f"{title}\nнизина {low.get(pre + '_mean', float('nan')):.3f} ({pre}<0 у {low.get(pre + '_neg_frac', 0):.0%}), хребет/верх {rid.get(pre + '_mean', float('nan')):.3f}{extra}", fontsize=8)
        ax.set_xlim(lext[0], lext[1]); ax.set_ylim(lext[2], lext[3])
    pts, skm, ridge, perp = section_line(hc, after["dx"])
    draw_section(axs[1, 0], before, pts, skm, "разрез до (без опускания)")
    draw_section(axs[1, 1], after, pts, skm, "разрез после")
    if after.get("col_zi"):
        axs[1, 1].plot(skm, bilin(grid(after, "col_zi"), pts), color="#e377c2", lw=1.2, label="z_i столбца с опусканием")
        axs[1, 1].legend(fontsize=7, loc="upper right")
    for k in (0, 1, 2, 3):
        axs[0, k].plot((after["x0"] + (pts[:, 0] + 0.5) * after["dx"]) / 1e3, (after["y0"] + (pts[:, 1] + 0.5) * after["dx"]) / 1e3, color="magenta", lw=1)
    # W̄ и покрытие вдоль разреза
    ax = axs[1, 2]
    if after.get("col_w"):
        ax.plot(skm, bilin(grid(after, "col_w"), pts), color="#d62728", lw=0.8, ls=":", label="W̄ столбца")
        if after.get("col_wm"):
            ax.plot(skm, bilin(grid(after, "col_wm"), pts), color="#d62728", lw=1.4, label="W̄_м (мезомасштаб)")
        ax.axhline(0, color="#888", lw=0.5)
        ax.set_ylabel("W̄, м/с")
        ax2 = ax.twinx()
        ax2.plot(skm, bilin(grid(before, "cover"), pts), color="#1f77b4", lw=0.8, ls=":", label="покрытие до")
        ax2.plot(skm, bilin(grid(after, "cover"), pts), color="#1f77b4", lw=1, label="покрытие после")
        ax2.set_ylabel("покрытие"); ax2.set_ylim(0, 1)
        ax.legend(fontsize=7, loc="upper left"); ax2.legend(fontsize=7, loc="upper right")
    ax.set_xlabel("вдоль разреза, км"); ax.set_title("W̄ столбца и покрытие вдоль разреза", fontsize=9)
    # потолки источников до/после
    ax = axs[1, 3]
    cols = [(tops_of(before), "до (τ_s = 0)")]
    if cell is not None:
        cols.append((tops_of(cell), "ячейковое W̄"))
    cols.append((tops_of(after), "после (W̄_м)"))
    for k, (t, lab) in enumerate(cols):
        if t["n"]:
            ax.bar(k, t["p90"] - t["p10"], bottom=t["p10"], width=0.5, color="#aec7e8", edgecolor="#1f77b4")
            ax.plot([k - 0.25, k + 0.25], [t["p50"], t["p50"]], color="k", lw=2)
            ax.text(k, t["p90"] + 50, f"p10 {t['p10']:.0f} / p50 {t['p50']:.0f} / p90 {t['p90']:.0f} м, n {t['n']}", ha="center", fontsize=7)
    ax.axhline(after["base_msl"], color="#1f77b4", ls="--", lw=1, label=f"LCL {after['base_msl']:.0f} м")
    if after.get("z_i") is not None:
        ax.axhline(after["z_i"], color="#888", ls=":", lw=1, label=f"z_i дня {after['z_i']:.0f} м")
    ax.set_xticks(range(len(cols))); ax.set_xticklabels([c[1] for c in cols])
    ax.set_ylabel("м над морем"); ax.set_title("потолки источников термиков (p10–p90, медиана)", fontsize=9)
    ax.legend(fontsize=7, loc="lower right")
    fig.suptitle(f"{NAMES.get(place, place)} — {WX.get(wname, wname)}: опускание горно-равнинной циркуляции (CLF-10), {after['hour']}:00", fontsize=12)
    fig.tight_layout()
    fig.savefig(fig_path, dpi=72)
    plt.close(fig)


def main_sub(a, out, fig):
    """CLF-10: листы до/после, out/subsidence.json, числа в summary.json (слияние с прежними)."""
    before_dir = Path(a.subsidence)
    cell_dir = Path(a.cell) if a.cell else None
    sp = out / "summary.json"
    summary = json.loads(sp.read_text()) if sp.exists() else {}
    res = {}
    fh = int(a.hour)
    for place in a.places.split(","):
        for wname in a.weathers.split(","):
            pa = out / f"{place}_{wname}_h{fh}.json"
            pb = before_dir / f"{place}_{wname}_h{fh}.json"
            if not pa.exists() or not pb.exists():
                print(f"{place} {wname}: нет кадра {fh} ч ({pa.exists()}, {pb.exists()})")
                continue
            after = json.loads(pa.read_text())
            before = json.loads(pb.read_text())
            pc = cell_dir / f"{place}_{wname}_h{fh}.json" if cell_dir else None
            cell = json.loads(pc.read_text()) if pc and pc.exists() else None
            png = fig / f"{place}_{wname}_sub.png"
            plot_sub_sheet(place, wname, before, after, png, cell)
            sb, sa = stats(before), stats(after)
            bb, ba = band_stats(before), band_stats(after)
            e = {
                "hour": fh, "base_msl": sa["base_msl"], "z_i_msl": sa["z_i_msl"],
                "W_lowland_mean": bb.get("lowland", {}).get("W_mean"),
                "W_ridge_mean": bb.get("ridge", {}).get("W_mean"),
                "W_upper20_mean": bb.get("upper20", {}).get("W_mean"),
                "W_lowland_neg_frac": bb.get("lowland", {}).get("W_neg_frac"),
                "Wm_lowland_mean": ba.get("lowland", {}).get("Wm_mean"),
                "Wm_ridge_mean": ba.get("ridge", {}).get("Wm_mean"),
                "Wm_upper20_mean": ba.get("upper20", {}).get("Wm_mean"),
                "Wm_lowland_neg_frac": ba.get("lowland", {}).get("Wm_neg_frac"),
                "Wm_ridge_neg_frac": ba.get("ridge", {}).get("Wm_neg_frac"),
                "Wm_upper20_neg_frac": ba.get("upper20", {}).get("Wm_neg_frac"),
                "Wm_p10_p50_p90": {k: v.get("Wm_p10_p50_p90") for k, v in ba.items()},
                "cover_lowland": [sb["cover_lowland"], sa["cover_lowland"]],
                "cover_ridge": [sb["cover_ridge"], sa["cover_ridge"]],
                "cover_upper20": [bb.get("upper20", {}).get("cover"), ba.get("upper20", {}).get("cover")],
                "cover_frac": [sb["cover_frac"], sa["cover_frac"]],
                "cloud_area_frac": [sb["cloud_area_frac"], sa["cloud_area_frac"]],
                "tops": {"before": tops_of(before), "after": tops_of(after)},
                "dz_s": {k: v.get("dz_s_p50_p90") for k, v in ba.items()},
                "z_i_eff_p50": {k: v.get("z_i_eff_p50") for k, v in ba.items()},
                "c_top": {"before": {k: v.get("c_top_p10_p50_p90") for k, v in bb.items()}, "after": {k: v.get("c_top_p10_p50_p90") for k, v in ba.items()}},
                "c_top_above_lcl_frac": {"before": {k: v.get("c_top_above_lcl_frac") for k, v in bb.items()}, "after": {k: v.get("c_top_above_lcl_frac") for k, v in ba.items()}},
                "solver_errors": after.get("series") and None,
            }
            if cell is not None:
                sc, bc = stats(cell), band_stats(cell)
                e["cell"] = {
                    "cover_lowland": sc["cover_lowland"], "cover_ridge": sc["cover_ridge"],
                    "cover_upper20": bc.get("upper20", {}).get("cover"), "cover_frac": sc["cover_frac"],
                    "cloud_area_frac": sc["cloud_area_frac"], "tops": tops_of(cell),
                    "dz_s": {k: v.get("dz_s_p50_p90") for k, v in bc.items()},
                    "c_top_above_lcl_frac": {k: v.get("c_top_above_lcl_frac") for k, v in bc.items()},
                }
            res.setdefault(place, {})[wname] = e
            st = dict(sa)
            st["cond"] = after.get("cond", {})
            st["before_subsidence"] = {k: sb[k] for k in ("cover_frac", "cover_lowland", "cover_ridge", "cloud_area_frac", "n_clouds", "depth_p50_m")}
            summary.setdefault(place, {})[wname] = st
            print(f"{place} {wname}: {png}")
    sp.write_text(json.dumps(summary, ensure_ascii=False, indent=1))
    (out / "subsidence.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))
    print(json.dumps(res, ensure_ascii=False, indent=1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(HERE / "out"))
    ap.add_argument("--fig", default=str(HERE / "fig"))
    ap.add_argument("--places", default="ongudai,training_island,almaty")
    ap.add_argument("--weathers", default="weak,strong,windy")
    ap.add_argument("--before", default="", help="CLF-9: папка слепков с α = 0 → листы до/после и zi_tops.json")
    ap.add_argument("--hour", default="13", help="CLF-9/10: час кадра для сравнения")
    ap.add_argument("--subsidence", default="", help="CLF-10: папка слепков с τ_s = 0 → листы до/после и subsidence.json")
    ap.add_argument("--cell", default="", help="CLF-10: папка слепков первой редакции (ячейковое W̄, σ = 0) → блок cell и третий столбик потолков")
    a = ap.parse_args()
    out = Path(a.out)
    fig = Path(a.fig)
    fig.mkdir(parents=True, exist_ok=True)
    if a.subsidence:
        main_sub(a, out, fig)
        return
    if a.before:
        main_zi(a, out, fig)
        return
    summary = {}
    for place in a.places.split(","):
        for wname in a.weathers.split(","):
            frames = {}
            for fh in FRAMES:
                p = out / f"{place}_{wname}_h{fh}.json"
                if p.exists():
                    frames[fh] = json.loads(p.read_text())
            if not frames:
                print(f"{place} {wname}: нет кадров")
                continue
            sp = out / f"{place}_{wname}_series.json"
            series = json.loads(sp.read_text())["series"] if sp.exists() else frames[max(frames)]["series"]
            png = fig / f"{place}_{wname}.png"
            plot_sheet(place, wname, frames, series, png)
            if 13 in frames:
                summary.setdefault(place, {})[wname] = stats(frames[13])
                summary[place][wname]["cond"] = frames[13].get("cond", {})
            print(f"{place} {wname}: {png}")
    (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1))
    print(json.dumps(summary, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
