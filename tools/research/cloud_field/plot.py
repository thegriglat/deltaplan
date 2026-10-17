#!/usr/bin/env python3
"""CLF-1: карты поля облачности из слепков dump.gd (out/<место>_<погода>_h<час>.json) и сводка.

Лист на место × погоду: кадры 11, 13, 15 ч (отмывка рельефа, покрытие, изолинии мощности, источники
термиков, граница «рельеф выше LCL», стрелка ветра основания) + разрез поперёк хребта в 13 ч
(рельеф, LCL, облако) + ход доли облачности. Сводка out/summary.json для 13 ч:
{место: {погода: {cover_frac, n_clouds, largest_km, depth_p50_m, depth_p90_m, src_under_cloud_ratio,
ridge_share, valley_share, base_msl}}}; «облако» — столбцы с покрытием ≥ CLOUD_THR.
  plot.py [--out out] [--fig <папка png>] [--places ongudai,training_island,almaty] [--weathers weak,strong,windy]
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
NAMES = {"ongudai": "Онгудай", "training_island": "учебный остров", "almaty": "Алматы (43,20; 76,90)"}
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
    }
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(HERE / "out"))
    ap.add_argument("--fig", default=str(HERE / "fig"))
    ap.add_argument("--places", default="ongudai,training_island,almaty")
    ap.add_argument("--weathers", default="weak,strong,windy")
    a = ap.parse_args()
    out = Path(a.out)
    fig = Path(a.fig)
    fig.mkdir(parents=True, exist_ok=True)
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
