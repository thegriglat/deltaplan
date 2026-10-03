"""Картинка одного случая: скорость на 60 м WN (400 м) | решатель | разность. python fig.py [id]"""
import sys, json
import numpy as np
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from common import *
from wnlib import *
cid = sys.argv[1] if len(sys.argv) > 1 else "ongudai_007"
z = np.load(OUT / f"ref_{cid}.npz"); u, v = wn_uv("mass", "d400", "60", cid)
sw, ss = np.hypot(u, v), np.hypot(z["u60"], z["v60"])
fig, ax = plt.subplots(1, 4, figsize=(18, 4.2))
for a, (f, t, kw) in zip(ax, ((z["hc"], "рельеф, м", dict(cmap="terrain")), (sw, "WindNinja 60 м, м/с", dict(cmap="viridis", vmin=0, vmax=max(sw.max(), ss.max()))),
                              (ss, "решатель 60 м, м/с", dict(cmap="viridis", vmin=0, vmax=max(sw.max(), ss.max()))), (sw - ss, "WN − решатель, м/с", dict(cmap="RdBu_r", vmin=-8, vmax=8)))):
    im = a.imshow(f, origin="lower", **kw); a.set_title(t); plt.colorbar(im, ax=a, fraction=0.046)
fig.suptitle(cid); fig.tight_layout(); fig.savefig(OUT / f"fig_{cid}.png", dpi=90)
