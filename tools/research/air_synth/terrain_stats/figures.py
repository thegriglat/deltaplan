"""Картинки: out/fig_compare.png (реальный / 30 форм / Fastscape / сумма форм, затенённый рельеф 400 м) и out/fig_curves.png
(остаток от числа форм; CCDF prominence)."""
import json, os, numpy as np
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
import dem, stats

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")


def shade(z, dx):
    gy, gx = np.gradient(z, dx)
    az = np.radians(315); alt = np.radians(40)
    s = np.sin(alt) + np.cos(alt) * (-gx * np.sin(az) * -1 + gy * np.cos(az) * -1) / np.sqrt(1 + gx ** 2 + gy ** 2)
    return s


fig, ax = plt.subplots(2, 4, figsize=(15, 7.8))
for r, place in enumerate(("askarovo", "ongudai")):
    real = np.load(os.path.join(OUT, f"decomp_{place}_detail400_p.npz"))
    fs = np.load(os.path.join(OUT, f"fastscape_{place}.npz"))["z400"][0]
    fg = np.load(os.path.join(OUT, f"forms_gen_{place}.npz"))["z400"][0]
    items = [("реальный (Copernicus, 400 м)", real["h"]), ("30 форм (жадно)", real["model"]), ("Fastscape + диффузия + порог", fs), ("сумма форм по статистикам", fg)]
    vmax = max(real["h"].max() - real["h"].min(), 1) * 1.0
    for c, (t, z) in enumerate(items):
        a = ax[r, c]
        a.imshow(z - z.min(), cmap="terrain", vmin=0, vmax=vmax, origin="upper")
        a.imshow(shade(z, 400.0), cmap="gray", alpha=0.35, origin="upper")
        a.set_title(f"{place}: {t}", fontsize=9); a.axis("off")
plt.tight_layout(); plt.savefig(os.path.join(OUT, "fig_compare.png"), dpi=110); plt.close()

D = json.load(open(os.path.join(OUT, "decomp.json")))
fig, ax = plt.subplots(1, 2, figsize=(11, 4.2))
for place, col in zip(dem.PLACES, ("C0", "C1", "C2", "C3")):
    for d in D:
        if d["place"] == place and d["tag"] == "detail400" and not d["signed"]:
            c = np.array(d["curve"]); ax[0].plot(c[:, 0], 1 - c[:, 2], col, label=place)
ax[0].set_yscale("log"); ax[0].set_xlabel("число форм"); ax[0].set_ylabel("доля неописанной дисперсии (400 м)"); ax[0].legend(); ax[0].grid(alpha=.3)
for place, ls in (("askarovo", "-"), ("ongudai", "--")):
    real = np.load(os.path.join(OUT, f"decomp_{place}_detail400_p.npz"))["h"]
    fs = np.load(os.path.join(OUT, f"fastscape_{place}.npz"))["z400"]
    fg = np.load(os.path.join(OUT, f"forms_gen_{place}.npz"))["z400"]
    for name, arrs, col in (("реальный", [real], "k"), ("Fastscape", list(fs), "C1"), ("сумма форм", list(fg), "C0")):
        for i, z in enumerate(arrs):
            p = np.sort(stats.peaks(z, 400.0)["prom"])[::-1]; p = p[p >= 20]
            ax[1].loglog(p, np.arange(1, len(p) + 1), ls, color=col, alpha=1 if name == "реальный" else 0.25, lw=2 if name == "реальный" else 0.8,
                         label=f"{place} {name}" if i == 0 else None)
ax[1].set_xlabel("prominence, м"); ax[1].set_ylabel("N(≥P) на 38,4 км"); ax[1].grid(alpha=.3, which="both"); ax[1].legend(fontsize=7)
plt.tight_layout(); plt.savefig(os.path.join(OUT, "fig_curves.png"), dpi=110)
