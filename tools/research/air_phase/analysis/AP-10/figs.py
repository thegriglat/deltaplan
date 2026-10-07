"""AP-10: рисунки (≤ 6) — вызываются из run.py. Агенты их не открывают; проверка — числами summary.json."""
from __future__ import annotations

import math

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

C = {"RIDGE": "#2a78d6", "STEP_DOWN": "#eb6834", "HILL": "#1baf7a"}
NAME = {"RIDGE": "хребет (2D)", "STEP_DOWN": "уступ вниз", "HILL": "холм (3D)"}
AGL = np.array([25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000], float)
plt.rcParams.update({"font.size": 9, "axes.spines.top": False, "axes.spines.right": False, "axes.grid": True,
                     "grid.color": "#e4e4e0", "grid.linewidth": 0.6, "lines.linewidth": 2})


def _save(fig, path):
    fig.tight_layout()
    fig.savefig(path, dpi=130)
    plt.close(fig)


def make(out, sres, eres, rres, meta, S):
    sl = S["slope_series"]
    # 1. пузырь против крутизны
    fig, ax = plt.subplots(1, 4, figsize=(13, 3.4))
    for shp in ("RIDGE", "STEP_DOWN", "HILL"):
        for dx, ls in ((100, "-"), (400, "--")):
            d = sl[f"{shp}_dx{dx}"]
            x = np.array(d["s"])
            lab = f"{NAME[shp]}, {dx} м"
            ax[0].plot(x, d["L_over_h"], ls, color=C[shp], marker="o", ms=4, label=lab)
            ax[1].plot(x, d["H_over_h"], ls, color=C[shp], marker="o", ms=4)
            ax[2].plot(x, d["urev_over_U"], ls, color=C[shp], marker="o", ms=4)
            sa = np.array(d["shadow_angle_deg"], float)
            ax[3].plot(x[sa > 0], sa[sa > 0], ls, color=C[shp], marker="o", ms=4)
    ax[0].plot([0.63], [3.5], "s", color="#444", ms=7, label="2D, лит. (Liu 2016)")
    ax[0].plot([0.63], [1.6], "^", color="#444", ms=7, label="3D, лит.")
    ax[0].axhline(2.8, color="#888", lw=1, ls=":", label="Perdigão 2,8 h")
    for a in ax[:3]:
        a.axvline(0.27, color="#888", lw=1, ls=":")
        a.axvline(0.36, color="#bbb", lw=1, ls=":")
    ax[2].axhspan(-0.2, -0.1, color="#ddd", alpha=0.6, lw=0)
    ax[3].axhline(12, color="#888", lw=1, ls=":")
    ax[0].set_ylabel("L/h (от бровки)"); ax[1].set_ylabel("H/h"); ax[2].set_ylabel("u_обр / U_sat"); ax[3].set_ylabel("угол тени, °")
    for a in ax:
        a.set_xlabel("крутизна s")
    ax[0].legend(fontsize=7, loc="upper left")
    _save(fig, out / "fig_sep_slope.png")

    # 2. Fr и нагрев
    fig, ax = plt.subplots(1, 3, figsize=(11, 3.4))
    for sv, col in ((0.3, "#2a78d6"), (0.5, "#eb6834")):
        for dx, ls in ((100, "-"), (400, "--")):
            d = S["fr_series"][f"RIDGE_s{sv}_dx{dx}"]
            fr = np.array(d["fr"]); st = np.array(d["status"]); ws = np.array([w if w is not None else 0 for w in d["win_status"]])
            bad = (st != 0) | (ws != 0) if dx == 100 else (st != 0)
            for k, (yk, a) in enumerate((("L_over_h", ax[0]), ("urev_over_U", ax[1]))):
                y = np.array(d[yk])
                a.plot(fr, y, ls, color=col, label=f"s = {sv}, {dx} м" if k == 0 else None)
                a.plot(fr[~bad], y[~bad], "o", color=col, ms=4)
                a.plot(fr[bad], y[bad], "o", mfc="white", color=col, ms=5)
            h = S["heat_series"][f"RIDGE_s{sv}_dx{dx}"]
            ax[2].plot(h["heat_wm2"], h["L_over_h"], ls, color=col, marker="o", ms=4)
    for a in ax[:2]:
        a.set_xscale("log"); a.set_xlabel("Fr = U_sat/(N h)")
    ax[0].set_ylabel("L/h"); ax[1].set_ylabel("u_обр / U_sat"); ax[2].set_xlabel("поток тепла H, Вт/м²"); ax[2].set_ylabel("L/h")
    ax[0].legend(fontsize=7)
    ax[0].set_title("пустые точки — не сошлось", fontsize=8)
    _save(fig, out / "fig_sep_fr_heat.png")

    # 3. сечения
    want = [("RIDGE", 0.6), ("RIDGE", 0.3), ("STEP_DOWN", 0.6)]
    fig, ax = plt.subplots(len(want), 1, figsize=(9, 2.6 * len(want)), sharex=True)
    for a, (shp, sv) in zip(ax, want):
        r = next((r for r in sres if r["dx_m"] == 100 and meta[r["case_id"]]["shape"] == shp
                  and meta[r["case_id"]]["slope"] == sv and meta[r["case_id"]]["variant"] == "slope"), None)
        if r is None or "sec" not in r:
            continue
        sec = r["sec"]
        s, zs, al = sec["s"].astype(float), sec["zs"].astype(float), sec["al"].astype(float)
        U = meta[r["case_id"]]["u_sat"]
        k = AGL <= 1100
        Sx = np.repeat(s[None], k.sum(), 0)
        Z = zs[None] + AGL[k][:, None] - 1000
        m = (s > -2000) & (s < 8000)
        cf = a.contourf(Sx[:, m], Z[:, m], al[k][:, m] / U, levels=np.linspace(-0.4, 1.2, 17), cmap="RdBu_r", extend="both")
        a.contour(Sx[:, m], Z[:, m], al[k][:, m], levels=[0], colors="k", linewidths=1.2)
        a.fill_between(s[m], 0, zs[m] - 1000, color="#8a7a66")
        ib = int(np.argmin(np.gradient(np.gradient(zs, s), s)[: int(np.argmin(np.gradient(zs, s))) + 1]))
        th = r["shadow_angle_deg"]
        if th > 0:
            xs = np.array([s[ib], s[ib] + r["L_over_h"] * 500])
            a.plot(xs, zs[ib] - 1000 - (xs - s[ib]) * math.tan(math.radians(th)), color="#eda100", lw=2,
                   label=f"линия тени {th:.1f}°")
            a.plot(xs, zs[ib] - 1000 - (xs - s[ib]) * math.tan(math.radians(12)), color="#eda100", lw=1.2, ls="--",
                   label="игра 12°")
        a.set_ylim(0, 1200); a.set_ylabel("z над базой, м")
        a.set_title(f"{NAME[shp]}, s = {sv}, Fr 3: u·e/U_sat, чёрная — u·e = 0", fontsize=8)
        a.legend(fontsize=7, loc="upper right")
    ax[-1].set_xlabel("по ветру от бровки, м")
    fig.colorbar(cf, ax=ax, shrink=0.8)
    fig.savefig(out / "fig_sections.png", dpi=130)
    plt.close(fig)

    # 4. рост слоя смешения
    fig, ax = plt.subplots(figsize=(5.5, 3.4))
    for shp in ("RIDGE", "STEP_DOWN", "HILL"):
        d = sl[f"{shp}_dx100"]
        x = np.array(d["s"], float); y = np.array([v if v is not None else np.nan for v in d["shear_S_pope"]], float)
        ax.plot(x, y, "-o", color=C[shp], ms=4, label=NAME[shp])
    ax.axhspan(0.06, 0.11, color="#ddd", lw=0, label="плоский слой смешения (Pope 2000)")
    ax.set_xlabel("крутизна s"); ax.set_ylabel("S = (U_c/U_s)·dδ/dx"); ax.legend(fontsize=7)
    _save(fig, out / "fig_shear_layer.png")

    # 5. огибающая против эталона
    E = S["envelope"]["by_config"]
    keys = list(E)
    fig, ax = plt.subplots(1, 2, figsize=(11, 3.4))
    xx = np.arange(len(keys))
    lab = [k.replace("_WALL_", "°, ").replace("GROUND", "земля").replace("LOW_Z0", "z0 1 мм") for k in keys]
    for a, q, tt in ((ax[0], "sp_rmse", "|U| (СКО / U_sat)"), (ax[1], "w_rmse", "w (СКО / U_sat)")):
        for off, zn, col in ((-0.3, "shadow", "#2a78d6"), (0.1, "behind", "#eb6834")):
            nm = {"shadow": "над огибающей (тень)", "behind": "за пузырём"}[zn]
            a.bar(xx + off, [E[k][f"rev_env_{zn}_{q}"] for k in keys], 0.19, color=col, label=f"{nm}: с огибающей")
            a.bar(xx + off + 0.2, [E[k][f"rev_base_{zn}_{q}"] for k in keys], 0.19, color=col, alpha=0.4,
                  label=f"{nm}: без (те же клетки)")
        a.set_xticks(xx); a.set_xticklabels(lab, rotation=30, ha="right", fontsize=7); a.set_ylabel(tt)
    ax[0].legend(fontsize=7)
    ax[0].set_title("против окна 100 м; 50–300 м над поверхностью, формы с пузырём", fontsize=8)
    _save(fig, out / "fig_envelope.png")

    # 6. ENVELOPE_REAL: доля сошедшихся
    R = S["envelope_real"]
    var = list(R)
    cfgs = sorted({c for v in var for c in R[v]}, key=lambda c: (float(c.split("_")[0]), c))
    fig, ax = plt.subplots(figsize=(8, 3.4))
    w = 0.8 / len(var)
    cols = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]
    for q, v in enumerate(var):
        vals = [R[v].get(c, {}).get("converged", np.nan) for c in cfgs]
        ax.bar(np.arange(len(cfgs)) + (q - (len(var) - 1) / 2) * w, vals, w, color=cols[q % 4],
               label=f"{v} (n = {R[v][cfgs[0]]['n'] if cfgs[0] in R[v] else '?'})")
    ax.set_xticks(np.arange(len(cfgs)))
    ax.set_xticklabels([c.replace("0_WALL_NONE", "без огибающей").replace("_WALL_", "°, ").replace("GROUND", "земля")
                        .replace("LOW_Z0", "z0 1 мм") for c in cfgs], rotation=20, ha="right", fontsize=7)
    ax.set_ylabel("доля сошедшихся"); ax.set_ylim(0, 1.05); ax.legend(fontsize=7)
    _save(fig, out / "fig_envreal.png")
