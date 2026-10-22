"""Запекание data/climate/upper_misc_1deg.bin (HH6 v2).
Есть RAW/upper_misc_cds_clim.npz (aggregate_cds.py) -> WR, TROP, HCC из данных CDS, stub_mask=0.
Иначе -> upper_misc_clim.npz (ARCO): WR = max(0.3, 1 + 0.6*(3000 - Z_ячейки)/1000), TROP = 11000 м — заглушки, stub_mask=3, HCC — ERA5.
Запуск: python bake.py [выход.bin]"""
import os, struct, sys, numpy as np, brotli
from common import RAW
R = os.path.expanduser(RAW)
CDS = os.path.exists(f"{R}/upper_misc_cds_clim.npz")
c = np.load(f"{R}/upper_misc_cds_clim.npz" if CDS else f"{R}/upper_misc_clim.npz"); z = np.load(f"{R}/climatology.npz")["z"]
out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../../data/climate/upper_misc_1deg.bin"))
WR_S, TR_S, HC_S = 0.001, 1.0, 0.0001
if CDS:
    WRSTUB = bool(np.isnan(c["wr"]).any())
    wr = np.clip(1 + 0.6 * (3000 - z) / 1000, 0.3, 10) * np.ones((12, 1, 1)) if WRSTUB else np.clip(c["wr"], 0.3, 10)
    trop = np.clip(c["trop"], 6000, 19000)
else:
    wr = np.broadcast_to(np.clip(1 + 0.6 * (3000 - z) / 1000, 0.3, 10), (12, 180, 360))
    trop = np.full((12, 180, 360), 11000.0)
hcc = np.clip(c["hcc"], 0, 1)
q = lambda a, s: np.round(a / s).astype("<i2")
raw = q(wr, WR_S).tobytes() + q(trop, TR_S).tobytes() + q(hcc, HC_S).tobytes()
assert len(raw) == 2 * 3 * 12 * 180 * 360
comp = brotli.compress(raw, quality=11, lgwin=24)
y0, y1 = (int(v) for v in c["years"])
hdr = b"HHUM" + struct.pack("<HHHHHH", 1, 1, 360, 180, 12, 700) + struct.pack("<ffffffff", -179.5, -89.5, 1.0, 1.0, WR_S, TR_S, HC_S, 0)[:-4]
hdr += struct.pack("<IIIII", (1 if WRSTUB else 0) if CDS else 3, len(raw), len(comp), y0, y1)
assert len(hdr) == 64, len(hdr)
tmp = out + ".tmp"; open(tmp, "wb").write(hdr + comp); os.replace(tmp, out)
print(out, 64 + len(comp), "байт")
