"""Удаляет суточные npz с NaN (сбой чтения чанка ARCO) для заданного набора: python repair_nan.py <каталог набора>; докачка — fetch_arco.py."""
import sys, os, numpy as np
d = sys.argv[1]
for f in sorted(os.listdir(d)):
    if f.endswith(".npz") and not f.endswith(".tmp.npz"):
        try: bad = any(np.isnan(np.load(f"{d}/{f}")[k]).any() for k in ("mean", "max", "min", "mean4", "mean2", "h12"))
        except Exception: bad = True
        if bad: print("удалён", f); os.remove(f"{d}/{f}")
