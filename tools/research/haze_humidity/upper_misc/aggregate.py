"""RAW/upper_misc/<год>/*.npz -> RAW/upper_misc_clim.npz: hcc (12,180,360) среднее, hcc_med, hcc_lt01 (доля дней < 0,1),
v10 (12,180,360) среднее |V10|, sem (σ/√n по дням), n; плюс v10_mean.npz (float16) рядом со скриптом. Запуск: python aggregate.py"""
import os, glob, numpy as np
from common import RAW
R = os.path.expanduser(RAW) + "/upper_misc"
H = {m: [] for m in range(12)}; S = {m: [] for m in range(12)}; years = set()
for f in sorted(glob.glob(f"{R}/[12]*/*.npz")):
    if f.endswith(".tmp.npz"): continue
    y, m = int(f.split("/")[-2]), int(os.path.basename(f)[:2]) - 1
    d = np.load(f); H[m].append(d["hcc"]); S[m].append(d["spd"]); years.add(y)
H = [np.array(h) for h in H.values()]; S = [np.array(s) for s in S.values()]
n = np.array([len(h) for h in H])
hcc = np.array([h.mean(0) for h in H]); v10 = np.array([s.mean(0) for s in S])
hmed = np.array([np.median(h, 0) for h in H]); hlt = np.array([(h < 0.1).mean(0) for h in H])
hsem = np.array([h.std(0, ddof=1) / np.sqrt(len(h)) for h in H])
np.savez(f"{os.path.expanduser(RAW)}/upper_misc_clim.npz", hcc=hcc, hcc_med=hmed, hcc_lt01=hlt, hcc_sem=hsem, v10=v10, n=n, years=np.array([min(years), max(years)]))
np.savez_compressed(os.path.join(os.path.dirname(os.path.abspath(__file__)), "v10_mean.npz"), v10=v10.astype(np.float16), years=np.array([min(years), max(years)]), n=n)
print("годы", min(years), max(years), "дней/мес", n.tolist(), "hcc", hcc.min(), hcc.max(), "v10", v10.min(), v10.max(), "sem hcc ср", hsem.mean())
