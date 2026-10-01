"""Картинки А4: рельеф с мачтами и лесом, поле на разрезе (номинал), модель против данных.

  python figs.py        → out/fig_terrain.png, out/fig_section_<ne|sw>.png, out/fig_obs.png, out/section_<sub>.npz
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy import ndimage

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import perdigao as P                     # noqa: E402

OUT = HERE / "out"
PLOT_MASTS = ["tse04", "tse13", "tse09", "tse06", "tse11", "tse10", "tse01", "tse02", "rsw03", "tse12", "rne02"]


def fig_terrain():
    T = P._terrain10()
    x0, y0, n, hc = P.terrain(30.0)
    fig, ax = plt.subplots(1, 2, figsize=(14, 6.4))
    ext = [-3000, 3000, -3000, 3000]
    a = ax[0]
    ls = matplotlib.colors.LightSource(315, 45)
    z = hc + P.BASE
    a.imshow(ls.shade(z, plt.cm.terrain, vert_exag=2, dx=30, dy=30, blend_mode="overlay"), origin="lower", extent=ext)
    cs = a.contour(np.linspace(-3000 + 15, 3000 - 15, n), np.linspace(-3000 + 15, 3000 - 15, n), z, levels=range(150, 500, 50),
                   colors="k", linewidths=0.4)
    a.clabel(cs, fmt="%d", fontsize=6)
    for name, m in P.masts().items():
        if name.startswith(("tse", "rsw", "rne", "v")) and abs(m["x"]) < 3000 and abs(m["y"]) < 3000:
            a.plot(m["x"], m["y"], "o", ms=3, color="w", mec="k", mew=0.5)
            if name in PLOT_MASTS:
                a.text(m["x"] + 40, m["y"] + 40, name, fontsize=7, color="k", bbox=dict(fc="w", alpha=0.6, lw=0, pad=0.5))
    for sub, col in (("ne", "tab:red"), ("sw", "tab:blue")):
        inp = P.case_inputs(sub)
        ang = math.radians(inp["wdir"])
        ex, ey = -math.sin(ang), -math.cos(ang)
        for t in P.SECTION_OFFSETS:
            s = np.array([-1500, 1500.0])
            a.plot(t * ey + s * ex, -t * ex + s * ey, "-", color=col, lw=1 if t else 1.8, alpha=0.9,
                   label=f"разрезы {sub.upper()} (ветер с {inp['wdir']:.0f}°)" if t == P.SECTION_OFFSETS[0] else None)
    a.set_title("Рельеф (Copernicus GLO-30 − 100 м + d под пологом), dx 30 м; мачты; разрезы", fontsize=10)
    a.set_xlabel("x, м (восток от центра долины)")
    a.set_ylabel("y, м (север)")
    a.legend(loc="upper left", fontsize=8)
    b = ax[1]
    im = b.imshow(T["tree"], origin="lower", extent=ext, cmap="Greens", vmin=0, vmax=1)
    b.contour(np.linspace(-3000 + 15, 3000 - 15, n), np.linspace(-3000 + 15, 3000 - 15, n), z, levels=[300, 400, 450], colors="k", linewidths=0.4)
    plt.colorbar(im, ax=b, label="доля леса (WorldCover, класс «деревья»), 10 м", shrink=0.8)
    b.set_title(f"Лес: средняя доля {P.forest_fraction():.2f} → z0 = {P.z0_nominal():.2f} м, d = {P.D_DISP:.1f} м·доля")
    b.set_xlabel("x, м")
    fig.tight_layout()
    fig.savefig(OUT / "fig_terrain.png", dpi=130)
    plt.close(fig)


def section_field(S, sub, sp):
    u, v, w, th = S.centers()
    inp = P.case_inputs(sub)
    ang = math.radians(inp["wdir"])
    ex, ey = -math.sin(ang), -math.cos(ang)
    s = np.arange(-1500.0, 1500.0 + 1e-9, 10.0)
    px, py = s * ex, s * ey
    hs = P.surface_at(S, px, py)
    zl = np.arange(hs.min() - 10, hs.max() + 450.0, 10.0)
    Z = np.broadcast_to(zl[:, None], (len(zl), len(s)))
    U = np.full(Z.shape, np.nan)
    Wz = np.full(Z.shape, np.nan)
    for k, z in enumerate(zl):
        ok = z >= hs + 10
        if ok.any():
            U[k, ok] = (P.sample(S, u, px[ok], py[ok], z) * ex + P.sample(S, v, px[ok], py[ok], z) * ey)
            Wz[k, ok] = P.sample(S, w, px[ok], py[ok], z)
    return s, zl, hs, U, Wz, (ex, ey)


def fig_sections():
    res = {}
    for sub in P.SUBCASES:
        r = P.run_one({}, sub, 30.0, keep=True)
        S = r.pop("_S")
        u, v, w, th = S.centers()
        sp = np.sqrt(u ** 2 + v ** 2 + w ** 2)
        s, zl, hs, U, Wz, (ex, ey) = section_field(S, sub, sp)
        sref = r["inputs"]["sref_model"]
        np.savez_compressed(OUT / f"section_{sub}.npz", s=s, z=zl + P.BASE, hs=hs + P.BASE, u_par=U.astype(np.float32),
                            w=Wz.astype(np.float32), sref=sref, wdir=r["inputs"]["wdir"])
        fig, ax = plt.subplots(figsize=(13, 5.2))
        lim = 0.5 * sref
        pc = ax.pcolormesh(s, zl + P.BASE, U / sref, cmap="RdBu_r", vmin=-1.2, vmax=1.2, shading="nearest")
        ax.contour(s, zl + P.BASE, U, levels=[-P.ZONE_U], colors="k", linewidths=1.2)
        ax.fill_between(s, 0, hs + P.BASE, color="0.35")
        ax.set_ylim(hs.min() + P.BASE - 20, hs.max() + P.BASE + 400)
        # мачты вдоль линии: проекция на разрез (поперёк — до 1 км)
        for name in PLOT_MASTS:
            m = P.masts().get(name)
            if not m:
                continue
            sm = m["x"] * ex + m["y"] * ey
            tm = m["x"] * (-ey) + m["y"] * ex
            if abs(sm) < 1500 and abs(tm) < 700:
                ax.plot([sm, sm], [m["ground"], m["ground"] + 100], "-", color="k", lw=1.3)
                ax.text(sm, m["ground"] + 105, name, fontsize=7, ha="center")
        cb = plt.colorbar(pc, ax=ax, label="u_∥/U100(мачта)  (красный — по ветру, синий — против)", shrink=0.85)
        ax.set_xlabel("s, м вдоль ветра (0 — центр долины), ветер слева направо")
        ax.set_ylabel("высота над морем, м")
        z_ = r["obs"]
        ax.set_title(f"{sub.upper()}: номинал (λ/h 0,031, α 0,235, z0 {r['params']['z0']}) — u вдоль ветра на центральном разрезе; "
                     f"чёрный контур u = −0,5 м/с; зона L/D {z_[f'pd_{sub}_zoneL']:.2f}, depth/H {z_[f'pd_{sub}_zoneDepth']:.2f}, "
                     f"max(−u)/U {z_[f'pd_{sub}_zoneRev']:.2f}", fontsize=9)
        fig.tight_layout()
        fig.savefig(OUT / f"fig_section_{sub}.png", dpi=130)
        plt.close(fig)
        res[sub] = r
        import model as M
        M.free(S)
    return res


def fig_obs():
    rows = [json.loads(l) for l in (OUT / "trial_runs.jsonl").read_text().splitlines()]
    nom = {r["subcase"]: r for r in rows if r["tag"] == "nom30" and r["status"] == "ok"}
    obs = P.observations()
    fig, axs = plt.subplots(1, 2, figsize=(13, 5.6), sharey=False)
    for a, sub in zip(axs, P.SUBCASES):
        o = [q for q in obs if q["subcase"] == sub]
        ys = np.arange(len(o))
        d = np.array([q["data"] for q in o])
        sg = np.array([math.hypot(q["sig"], q["sig_grid"]) for q in o])
        mo = np.array([nom[sub]["obs"].get(q["name"], np.nan) for q in o], float)
        a.errorbar(d, ys, xerr=sg, fmt="o", color="k", label="данные ± σ", capsize=2)
        a.plot(mo, ys, "D", color="tab:red", label="модель, номинал")
        a.set_yticks(ys)
        a.set_yticklabels([q["name"].replace(f"pd_{sub}_", "") for q in o], fontsize=7)
        a.invert_yaxis()
        a.set_title(f"{sub.upper()}: наблюдаемые (S/S_ref; зона: L/D, depth/H, max(−u)/U100)")
        a.grid(alpha=0.3)
        a.legend()
    fig.tight_layout()
    fig.savefig(OUT / "fig_obs.png", dpi=130)
    plt.close(fig)


if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    fig_terrain()
    if (OUT / "trial_runs.jsonl").exists():
        fig_sections()
        fig_obs()
